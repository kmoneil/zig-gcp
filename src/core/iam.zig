//! IAM policies, as Google's resource-level `getIamPolicy` and
//! `setIamPolicy` methods read and write them: bindings of a role to its
//! members, perhaps under a condition, and the etag that makes a write fail
//! rather than undo another made since the read. Every module whose
//! resources carry a policy shares this: the policy, how members compare,
//! the checks before sending, and the read-modify-write that grants or
//! revokes once.
//!
//! Measured in production on 2026-10-01, on buckets, topics, subscriptions
//! and secrets alike: every write moves the etag, one that changes nothing
//! included; the server drops a binding with no members, stores a member
//! named twice once, merges two unconditioned bindings of one role, and
//! lowercases the address of a `user:`, `serviceAccount:`, `group:` or
//! `domain:` member, while the prefix itself is case-sensitive.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Stringify = std.json.Stringify;
const Owned = @import("owned.zig").Owned;
const RetryPolicy = @import("retry.zig").RetryPolicy;

pub const Policy = struct {
    /// 1, or 3 for a policy whose bindings carry conditions. Written back,
    /// a policy with a condition always says 3, which the servers require.
    version: u32 = 1,
    /// As read: written back, it makes the write fail if the policy
    /// changed since. Null writes over whatever is there.
    etag: ?[]const u8 = null,
    bindings: []const Binding = &.{},

    /// Whether `member` holds `role` with no condition, comparing members
    /// as the servers store them (`sameMember`).
    pub fn grants(self: Policy, role: []const u8, member: []const u8) bool {
        for (self.bindings) |b| {
            if (b.condition != null or !std.mem.eql(u8, b.role, role)) continue;
            for (b.members) |m| if (sameMember(m, member)) return true;
        }
        return false;
    }

    /// Whether any binding carries a condition.
    pub fn hasConditions(self: Policy) bool {
        for (self.bindings) |b| if (b.condition != null) return true;
        return false;
    }
};

pub const Binding = struct {
    /// Such as `roles/pubsub.publisher`.
    role: []const u8,
    /// Such as `serviceAccount:name@project.iam.gserviceaccount.com`,
    /// `user:...`, `group:...`, `domain:...`.
    members: []const []const u8,
    /// The binding's condition, JSON as read, written back as it is.
    condition: ?[]const u8 = null,
};

/// Whether two members name the same principal as the servers store them:
/// the prefix exactly, and for `user:`, `serviceAccount:`, `group:` and
/// `domain:` the address in any case, which the servers lowercase. Every
/// other form compares exactly.
pub fn sameMember(a: []const u8, b: []const u8) bool {
    if (std.mem.eql(u8, a, b)) return true;
    const colon = std.mem.indexOfScalar(u8, a, ':') orelse return false;
    if (b.len <= colon or b[colon] != ':' or !std.mem.eql(u8, a[0..colon], b[0..colon])) return false;
    for ([_][]const u8{ "user", "serviceAccount", "group", "domain" }) |prefix| {
        if (std.mem.eql(u8, a[0..colon], prefix)) return std.ascii.eqlIgnoreCase(a[colon + 1 ..], b[colon + 1 ..]);
    }
    return false;
}

pub const DecodeError = error{ InvalidResponse, OutOfMemory };

/// A policy as `getIamPolicy` and `setIamPolicy` answer it, Cloud Storage's
/// `kind` and `resourceId` and Secret Manager's `auditConfigs` ignored. An
/// empty policy is `{}` or `{"etag": ...}`.
pub fn decode(arena: Allocator, body: []const u8) DecodeError!Policy {
    const Wire = struct {
        version: ?u32 = null,
        etag: ?[]const u8 = null,
        bindings: ?[]const struct {
            role: ?[]const u8 = null,
            members: ?[]const []const u8 = null,
            condition: ?std.json.Value = null,
        } = null,
    };
    const wire = std.json.parseFromSliceLeaky(Wire, arena, body, .{
        .ignore_unknown_fields = true,
        .duplicate_field_behavior = .use_last,
        .allocate = .alloc_always,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidResponse,
    };
    const listed = wire.bindings orelse &.{};
    const bindings = try arena.alloc(Binding, listed.len);
    for (listed, bindings) |w, *b| {
        b.* = .{
            .role = w.role orelse return error.InvalidResponse,
            .members = w.members orelse &.{},
            .condition = if (w.condition) |c| try Stringify.valueAlloc(arena, c, .{}) else null,
        };
    }
    return .{ .version = wire.version orelse 1, .etag = wire.etag, .bindings = bindings };
}

/// The body of a Pub/Sub or Secret Manager `setIamPolicy`:
/// `{"policy": ...}`, as `encodePolicy` writes the policy. No
/// `updateMask` is sent, so Secret Manager keeps a secret's audit
/// configuration as it is, which this type does not hold.
pub fn encodeSet(arena: Allocator, policy: Policy) Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    var jw: Stringify = .{ .writer = &out.writer };
    writeSet(&jw, policy) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

/// The policy itself, as Cloud Storage's `PUT b/{bucket}/iam` takes it:
/// the version (3 whenever a binding has a condition), the etag when there
/// is one, and every binding with its condition as read. `bindings` is
/// always written, since a bucket write without it removes every binding.
pub fn encodePolicy(arena: Allocator, policy: Policy) Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    var jw: Stringify = .{ .writer = &out.writer };
    writePolicy(&jw, policy) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn writeSet(jw: *Stringify, policy: Policy) !void {
    try jw.beginObject();
    try jw.objectField("policy");
    try writePolicy(jw, policy);
    try jw.endObject();
}

fn writePolicy(jw: *Stringify, policy: Policy) !void {
    try jw.beginObject();
    try jw.objectField("version");
    try jw.write(if (policy.hasConditions()) @max(policy.version, 3) else policy.version);
    if (policy.etag) |etag| {
        try jw.objectField("etag");
        try jw.write(etag);
    }
    try jw.objectField("bindings");
    try jw.beginArray();
    for (policy.bindings) |b| {
        try jw.beginObject();
        try jw.objectField("role");
        try jw.write(b.role);
        try jw.objectField("members");
        try jw.write(b.members);
        if (b.condition) |condition| {
            try jw.objectField("condition");
            try jw.beginWriteRaw();
            try jw.writer.writeAll(condition);
            jw.endWriteRaw();
        }
        try jw.endObject();
    }
    try jw.endArray();
    try jw.endObject();
}

/// `policy` with `member` added to the binding of `role` that has no
/// condition, or to a new one; the etag and every other binding as they
/// were. A member already there, in any case its address may take, is not
/// added again. Memory from `arena`.
pub fn withMember(arena: Allocator, policy: Policy, role: []const u8, member: []const u8) Allocator.Error!Policy {
    if (policy.grants(role, member)) return policy;
    var bindings: std.ArrayList(Binding) = .empty;
    var added = false;
    for (policy.bindings) |b| {
        if (!added and b.condition == null and std.mem.eql(u8, b.role, role)) {
            var members: std.ArrayList([]const u8) = .empty;
            try members.appendSlice(arena, b.members);
            try members.append(arena, member);
            try bindings.append(arena, .{ .role = b.role, .members = members.items });
            added = true;
        } else try bindings.append(arena, b);
    }
    if (!added) {
        const members = try arena.alloc([]const u8, 1);
        members[0] = member;
        try bindings.append(arena, .{ .role = role, .members = members });
    }
    return .{ .version = policy.version, .etag = policy.etag, .bindings = bindings.items };
}

/// `policy` with `member` taken out of every binding of `role` that has no
/// condition, a binding left with no members dropped, as the servers drop
/// it; conditional bindings, the etag and every other binding as they
/// were. Memory from `arena`.
pub fn withoutMember(arena: Allocator, policy: Policy, role: []const u8, member: []const u8) Allocator.Error!Policy {
    var bindings: std.ArrayList(Binding) = .empty;
    for (policy.bindings) |b| {
        if (b.condition != null or !std.mem.eql(u8, b.role, role)) {
            try bindings.append(arena, b);
            continue;
        }
        var members: std.ArrayList([]const u8) = .empty;
        for (b.members) |m| if (!sameMember(m, member)) try members.append(arena, m);
        if (members.items.len > 0) try bindings.append(arena, .{ .role = b.role, .members = members.items });
    }
    return .{ .version = policy.version, .etag = policy.etag, .bindings = bindings.items };
}

/// What `update` does to a policy.
pub const Change = union(enum) {
    /// The member joins the role's binding that has no condition.
    grant: Grant,
    /// The member leaves every binding of the role that has no condition.
    revoke: Grant,

    pub const Grant = struct { role: []const u8, member: []const u8 };

    /// Whether `policy` already says what the change would make it say.
    pub fn holds(c: Change, policy: Policy) bool {
        return switch (c) {
            .grant => |g| policy.grants(g.role, g.member),
            .revoke => |g| !policy.grants(g.role, g.member),
        };
    }

    /// `policy` with the change made. Memory from `arena`.
    pub fn apply(c: Change, arena: Allocator, policy: Policy) Allocator.Error!Policy {
        return switch (c) {
            .grant => |g| withMember(arena, policy, g.role, g.member),
            .revoke => |g| withoutMember(arena, policy, g.role, g.member),
        };
    }
};

/// Grants or revokes once: reads the policy with `resource.readPolicy()`,
/// returns it when `change` already holds, and otherwise writes it changed
/// with `resource.writePolicy(policy)`, under the read's etag. A write
/// refused with `error.Aborted`, another change having come in between,
/// starts the whole round over after a full-jitter wait from `retry`, up to
/// `retry.max_attempts` rounds, as IAM asks; any other error ends it. The
/// answer is the policy as written, or as read when nothing had to change.
pub fn update(gpa: Allocator, io: std.Io, retry: RetryPolicy, resource: anytype, change: Change) !Owned(Policy) {
    var round: u32 = 0;
    while (true) {
        round += 1;
        var read = try resource.readPolicy();
        if (change.holds(read.value)) return read;
        defer read.deinit();
        var scratch: std.heap.ArenaAllocator = .init(gpa);
        defer scratch.deinit();
        const next = try change.apply(scratch.allocator(), read.value);
        return resource.writePolicy(next) catch |err| {
            if (err != error.Aborted or round >= retry.max_attempts) return err;
            var bytes: [8]u8 = undefined;
            io.random(&bytes);
            const delay_ms = retry.backoffMs(round, std.mem.readInt(u64, &bytes, .little));
            try io.sleep(.fromMilliseconds(delay_ms), .awake);
            continue;
        };
    }
}

/// Why `role` is no role, or null when it is one: `roles/NAME`,
/// `projects/PROJECT/roles/NAME` or `organizations/ORG/roles/NAME`, the
/// forms every service named when refusing another.
pub fn roleProblem(role: []const u8) ?[]const u8 {
    const usage = "a role is roles/NAME, projects/PROJECT/roles/NAME or organizations/ORGANIZATION/roles/NAME";
    if (std.mem.startsWith(u8, role, "roles/")) return if (role.len > "roles/".len) null else usage;
    for ([_][]const u8{ "projects/", "organizations/" }) |prefix| {
        if (!std.mem.startsWith(u8, role, prefix)) continue;
        const rest = role[prefix.len..];
        const cut = std.mem.indexOf(u8, rest, "/roles/") orelse return usage;
        const name = rest[cut + "/roles/".len ..];
        if (cut == 0 or name.len == 0 or std.mem.indexOfScalar(u8, rest[0..cut], '/') != null) return usage;
        return null;
    }
    return usage;
}

/// Which members a call may name, beyond the principals every service takes.
pub const MemberRules = struct {
    /// Cloud Storage's `projectOwner:`, `projectEditor:` and
    /// `projectViewer:` values, which only buckets take.
    project_values: bool = false,
    /// `deleted:` members, which IAM writes when a principal is deleted:
    /// one may be revoked, never granted.
    deleted: bool = false,
};

/// Why `member` cannot be granted or revoked, or null when it can: a
/// principal every service took in production, with its prefix cased as
/// they require. Whether the principal exists is the server's to say.
pub fn memberProblem(member: []const u8, rules: MemberRules) ?[]const u8 {
    if (std.mem.eql(u8, member, "allUsers") or std.mem.eql(u8, member, "allAuthenticatedUsers")) return null;
    for ([_][]const u8{ "user:", "serviceAccount:", "group:", "domain:", "principal://", "principalSet://" }) |prefix| {
        if (!std.mem.startsWith(u8, member, prefix)) continue;
        return if (member.len > prefix.len) null else "a member names its principal after the prefix, such as serviceAccount:name@project.iam.gserviceaccount.com";
    }
    for ([_][]const u8{ "projectOwner:", "projectEditor:", "projectViewer:" }) |prefix| {
        if (!std.mem.startsWith(u8, member, prefix)) continue;
        if (!rules.project_values) return "only Cloud Storage buckets take projectOwner:, projectEditor: and projectViewer: members";
        const project = member[prefix.len..];
        if (project.len == 0) return "a projectOwner:, projectEditor: or projectViewer: member names a project's ID";
        for (project) |ch| {
            if (!std.ascii.isDigit(ch)) return null;
        }
        return "Cloud Storage takes a project's ID after projectOwner:, projectEditor: and projectViewer:, not its number";
    }
    if (std.mem.startsWith(u8, member, "deleted:")) {
        return if (rules.deleted) null else "a deleted: member is IAM's record of a principal that was deleted, and can only be revoked";
    }
    return "a member is user:, serviceAccount:, group: or domain: and an address, principal:// or principalSet:// and a name, allUsers or allAuthenticatedUsers, its prefix cased so";
}

/// Why `permissions` cannot be tested, or null when they can: 1 to 100 of
/// them, the most any service took, none empty, none twice (a bucket
/// refuses a repeat) and no wildcard.
pub fn permissionsProblem(permissions: []const []const u8) ?[]const u8 {
    if (permissions.len == 0) return "name at least one permission to test";
    if (permissions.len > 100) return "at most 100 permissions in one test";
    for (permissions, 0..) |p, i| {
        if (p.len == 0) return "a permission to test is not empty";
        if (std.mem.indexOfScalar(u8, p, '*') != null) return "a permission to test is one permission: wildcards are refused";
        for (permissions[0..i]) |q| if (std.mem.eql(u8, p, q)) return "a permission to test is named once";
    }
    return null;
}

/// The body of a Pub/Sub or Secret Manager `testIamPermissions`.
pub fn encodePermissions(arena: Allocator, permissions: []const []const u8) Allocator.Error![]u8 {
    return Stringify.valueAlloc(arena, .{ .permissions = permissions }, .{});
}

/// The permissions a `testIamPermissions` answer says the caller holds:
/// `{"permissions": [...]}`, with Cloud Storage's `kind` beside it, or `{}`
/// when none, as Secret Manager answers.
pub fn decodePermissions(arena: Allocator, body: []const u8) DecodeError![]const []const u8 {
    const Wire = struct { permissions: ?[]const []const u8 = null };
    const wire = std.json.parseFromSliceLeaky(Wire, arena, body, .{
        .ignore_unknown_fields = true,
        .duplicate_field_behavior = .use_last,
        .allocate = .alloc_always,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidResponse,
    };
    return wire.permissions orelse &.{};
}

const testing = std.testing;
const test_util = @import("testing.zig");

test "decode: an empty policy, a policy with members, and a condition kept as read" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const empty = try decode(arena, "{\"etag\":\"ACAB\"}");
    try testing.expectEqual(1, empty.version);
    try testing.expectEqualStrings("ACAB", empty.etag.?);
    try testing.expectEqual(0, empty.bindings.len);
    try testing.expectEqual(0, (try decode(arena, "{}")).bindings.len);

    const policy = try decode(arena,
        \\{"version":3,"etag":"BwYa","bindings":[{"role":"roles/pubsub.publisher","members":["serviceAccount:a@x.iam.gserviceaccount.com"]},{"role":"roles/pubsub.subscriber","members":["user:b@x.com"],"condition":{"title":"t","expression":"request.time < timestamp(\"2030-01-01T00:00:00Z\")"}}],"auditConfigs":[]}
    );
    try testing.expectEqual(3, policy.version);
    try testing.expect(policy.grants("roles/pubsub.publisher", "serviceAccount:a@x.iam.gserviceaccount.com"));
    // A conditional grant is not one to rely on.
    try testing.expect(!policy.grants("roles/pubsub.subscriber", "user:b@x.com"));
    try testing.expect(!policy.grants("roles/pubsub.publisher", "user:b@x.com"));
    // Holding one role grants no other.
    try testing.expect(!policy.grants("roles/pubsub.subscriber", "serviceAccount:a@x.iam.gserviceaccount.com"));
    try testing.expectEqualStrings(
        \\{"title":"t","expression":"request.time < timestamp(\"2030-01-01T00:00:00Z\")"}
    , policy.bindings[1].condition.?);

    try testing.expectError(error.InvalidResponse, decode(arena, "{\"bindings\":[{\"members\":[]}]}"));
    try testing.expectError(error.InvalidResponse, decode(arena, "[]"));
}

test "encodeSet and withMember: the etag kept, a member joined to its role's binding, conditions untouched" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const read = try decode(arena,
        \\{"version":3,"etag":"BwYa","bindings":[{"role":"roles/pubsub.publisher","members":["serviceAccount:a@x.iam.gserviceaccount.com"],"condition":{"title":"t"}},{"role":"roles/pubsub.publisher","members":["user:c@x.com"]}]}
    );
    const agent = "serviceAccount:service-1@gs-project-accounts.iam.gserviceaccount.com";
    const next = try withMember(arena, read, "roles/pubsub.publisher", agent);
    try testing.expect(next.grants("roles/pubsub.publisher", agent));
    try testing.expectEqualStrings(
        \\{"policy":{"version":3,"etag":"BwYa","bindings":[{"role":"roles/pubsub.publisher","members":["serviceAccount:a@x.iam.gserviceaccount.com"],"condition":{"title":"t"}},{"role":"roles/pubsub.publisher","members":["user:c@x.com","serviceAccount:service-1@gs-project-accounts.iam.gserviceaccount.com"]}]}}
    , try encodeSet(arena, next));
    // No binding of the role: a new one, the policy's version as it was.
    const fresh = try withMember(arena, .{ .etag = "ACAB" }, "roles/pubsub.publisher", agent);
    try testing.expectEqualStrings(
        \\{"policy":{"version":1,"etag":"ACAB","bindings":[{"role":"roles/pubsub.publisher","members":["serviceAccount:service-1@gs-project-accounts.iam.gserviceaccount.com"]}]}}
    , try encodeSet(arena, fresh));
    // What was read stays as it was.
    try testing.expectEqual(1, read.bindings[1].members.len);
}

fn roundTripProperty(_: void, bytes: []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var g: test_util.ByteGen = .init(bytes);
    const bindings = try arena.alloc(Binding, g.intRange(usize, 0, 4));
    for (bindings) |*b| {
        const members = try arena.alloc([]const u8, g.intRange(usize, 0, 3));
        for (members) |*m| m.* = g.utf8(try arena.alloc(u8, 40), 40);
        b.* = .{
            .role = g.pick([]const u8, &.{ "roles/pubsub.publisher", "roles/pubsub.subscriber", "roles/owner" }),
            .members = members,
            .condition = if (g.boolean()) try Stringify.valueAlloc(arena, .{ .title = g.utf8(try arena.alloc(u8, 16), 16) }, .{}) else null,
        };
    }
    const policy: Policy = .{ .version = g.pick(u32, &.{ 1, 3 }), .etag = if (g.boolean()) g.utf8(try arena.alloc(u8, 12), 12) else null, .bindings = bindings };
    const member = g.utf8(try arena.alloc(u8, 30), 30);
    const role = g.pick([]const u8, &.{ "roles/pubsub.publisher", "roles/owner" });
    const next = try withMember(arena, policy, role, member);
    try testing.expect(next.grants(role, member));
    // Every other role held as before, by a binding with no condition.
    for ([_][]const u8{ "roles/pubsub.publisher", "roles/pubsub.subscriber", "roles/owner" }) |other| {
        if (std.mem.eql(u8, other, role)) continue;
        var held = false;
        for (policy.bindings) |b| {
            if (b.condition != null or !std.mem.eql(u8, b.role, other)) continue;
            for (b.members) |m| held = held or sameMember(m, member);
        }
        try testing.expectEqual(held, next.grants(other, member));
    }
    // What setIamPolicy answers, written as sent, reads back the same.
    const body = try encodeSet(arena, next);
    const sent = try std.json.parseFromSliceLeaky(struct { policy: std.json.Value }, arena, body, .{});
    const back = try decode(arena, try Stringify.valueAlloc(arena, sent.policy, .{}));
    // Written as 3 whenever a binding has a condition, as the servers require.
    try testing.expectEqual(if (next.hasConditions()) @max(next.version, 3) else next.version, back.version);
    try testing.expectEqual(next.bindings.len, back.bindings.len);
    for (next.bindings, back.bindings) |a, b| {
        try testing.expectEqualStrings(a.role, b.role);
        try testing.expectEqual(a.members.len, b.members.len);
        for (a.members, b.members) |x, y| try testing.expectEqualStrings(x, y);
        try testing.expectEqual(a.condition == null, b.condition == null);
    }
    try testing.expect(back.grants(role, member));
}

test "fuzz iam policies: a member added is granted, and the written policy reads back the same" {
    try test_util.fuzzBytes({}, roundTripProperty, .{ .corpus = &.{ "", test_util.repeat("\x01", 64), test_util.repeat("\x07\x02\x09", 30) } });
}

test "sameMember: the prefix exactly, the address of the four address forms in any case, the rest exactly" {
    const agent = "serviceAccount:service-1@gs-project-accounts.iam.gserviceaccount.com";
    try testing.expect(sameMember(agent, agent));
    // Measured: the servers store these addresses lowercased.
    try testing.expect(sameMember(agent, "serviceAccount:SERVICE-1@GS-PROJECT-ACCOUNTS.IAM.GSERVICEACCOUNT.COM"));
    try testing.expect(sameMember("user:Kevin@Example.com", "user:kevin@example.com"));
    try testing.expect(sameMember("group:Team@Example.com", "group:team@example.com"));
    try testing.expect(sameMember("domain:Example.COM", "domain:example.com"));
    // And refuse a prefix in another case: never the same principal.
    try testing.expect(!sameMember(agent, "ServiceAccount:service-1@gs-project-accounts.iam.gserviceaccount.com"));
    try testing.expect(!sameMember("allUsers", "allusers"));
    try testing.expect(!sameMember("user:a@example.com", "group:a@example.com"));
    try testing.expect(!sameMember("user:a@example.com", "user:b@example.com"));
    try testing.expect(!sameMember("user:a@example.com", "user:a@example.co"));
    // Every other form compares exactly: a workforce subject may be cased.
    try testing.expect(!sameMember("principal://iam.googleapis.com/locations/global/workforcePools/p/subject/Alice", "principal://iam.googleapis.com/locations/global/workforcePools/p/subject/alice"));
    try testing.expect(!sameMember("projectViewer:Proj", "projectViewer:proj"));
    try testing.expect(!sameMember("deleted:user:A@example.com?uid=1", "deleted:user:a@example.com?uid=1"));
    try testing.expect(!sameMember("user:", "user"));
    try testing.expect(!sameMember("", "user:a@example.com"));
    try testing.expect(sameMember("", ""));
}

test "withMember and withoutMember: once, in any case, and conditional bindings left alone" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const read = try decode(arena,
        \\{"version":3,"etag":"BwYa","bindings":[{"role":"roles/r","members":["user:a@x.com","serviceAccount:b@x.com"]},{"role":"roles/r","members":["user:a@x.com"],"condition":{"title":"t"}},{"role":"roles/other","members":["user:a@x.com"]}]}
    );
    // Held already, in another case: nothing changes.
    const same = try withMember(arena, read, "roles/r", "user:A@X.COM");
    try testing.expectEqual(read.bindings.ptr, same.bindings.ptr);

    const without = try withoutMember(arena, read, "roles/r", "user:A@x.com");
    try testing.expectEqualStrings(
        \\{"policy":{"version":3,"etag":"BwYa","bindings":[{"role":"roles/r","members":["serviceAccount:b@x.com"]},{"role":"roles/r","members":["user:a@x.com"],"condition":{"title":"t"}},{"role":"roles/other","members":["user:a@x.com"]}]}}
    , try encodeSet(arena, without));
    try testing.expect(!without.grants("roles/r", "user:a@x.com"));
    try testing.expect(without.grants("roles/other", "user:a@x.com"));

    // The binding's last member leaves: the binding goes, as the servers drop it.
    const emptied = try withoutMember(arena, without, "roles/r", "serviceAccount:B@X.com");
    try testing.expectEqual(2, emptied.bindings.len);
    try testing.expect(emptied.bindings[0].condition != null);
    // Not there: the same bindings.
    const untouched = try withoutMember(arena, emptied, "roles/r", "user:nobody@x.com");
    try testing.expectEqual(2, untouched.bindings.len);

    // Every unconditioned binding of the role loses the member, as a policy
    // written with two of them would be merged by the server anyway.
    const twice = try decode(arena,
        \\{"bindings":[{"role":"roles/r","members":["user:a@x.com"]},{"role":"roles/r","members":["user:a@x.com","user:c@x.com"]}]}
    );
    const out = try withoutMember(arena, twice, "roles/r", "user:a@x.com");
    try testing.expectEqual(1, out.bindings.len);
    try testing.expectEqualStrings("user:c@x.com", out.bindings[0].members[0]);
}

test "encodePolicy: bare, bindings always written, version 3 whenever a binding has a condition" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // A bucket write without bindings removes every binding: always written.
    try testing.expectEqualStrings("{\"version\":1,\"bindings\":[]}", try encodePolicy(arena, .{}));
    try testing.expectEqualStrings("{\"version\":1,\"etag\":\"CAE=\",\"bindings\":[]}", try encodePolicy(arena, .{ .etag = "CAE=" }));
    // A condition at version 1 is refused 400 "at least 3": written as 3.
    const conditional: Policy = .{ .version = 1, .bindings = &.{.{ .role = "roles/r", .members = &.{"user:a@x.com"}, .condition = "{\"title\":\"t\",\"expression\":\"true\"}" }} };
    try testing.expectEqualStrings(
        \\{"version":3,"bindings":[{"role":"roles/r","members":["user:a@x.com"],"condition":{"title":"t","expression":"true"}}]}
    , try encodePolicy(arena, conditional));
    try testing.expectEqualStrings(
        \\{"policy":{"version":3,"bindings":[{"role":"roles/r","members":["user:a@x.com"],"condition":{"title":"t","expression":"true"}}]}}
    , try encodeSet(arena, conditional));
    // Without one, the version as given.
    try testing.expectEqualStrings("{\"version\":3,\"bindings\":[]}", try encodePolicy(arena, .{ .version = 3 }));
}

test "roleProblem: the three forms every service named" {
    for ([_][]const u8{ "roles/pubsub.publisher", "roles/storage.legacyBucketOwner", "projects/my-project/roles/custom", "organizations/123/roles/custom" }) |role| {
        try testing.expectEqual(@as(?[]const u8, null), roleProblem(role));
    }
    for ([_][]const u8{ "", "roles/", "viewer", "Roles/viewer", "projects//roles/r", "projects/p/roles/", "projects/a/b/roles/r", "projects/p", "organizations/1/role/r", "folders/1/roles/r" }) |role| {
        try testing.expect(roleProblem(role) != null);
    }
}

test "memberProblem: what production took, cased as it requires" {
    const taken = [_][]const u8{
        "user:kevin@example.com",
        "serviceAccount:service-1@gs-project-accounts.iam.gserviceaccount.com",
        "group:team@example.com",
        "domain:example.com",
        "principal://iam.googleapis.com/locations/global/workforcePools/pool/subject/x",
        "principalSet://cloudresourcemanager.googleapis.com/projects/1/type/ServiceAccount",
        "allUsers",
        "allAuthenticatedUsers",
    };
    for (taken) |member| try testing.expectEqual(@as(?[]const u8, null), memberProblem(member, .{}));
    // Each refused 400 by every service, as measured.
    const refused = [_][]const u8{ "", "alice@example.com", "user:", "serviceAccount:", "foo:bar", "ServiceAccount:a@x.com", "allusers", "principal://" };
    for (refused) |member| try testing.expect(memberProblem(member, .{}) != null);

    // Buckets take a project's ID after the three convenience prefixes; the
    // others refuse them, and so does a bucket the project's number.
    try testing.expectEqual(@as(?[]const u8, null), memberProblem("projectViewer:my-project", .{ .project_values = true }));
    try testing.expectEqual(@as(?[]const u8, null), memberProblem("projectOwner:example.com:proj", .{ .project_values = true }));
    try testing.expect(memberProblem("projectViewer:my-project", .{}) != null);
    try testing.expect(memberProblem("projectViewer:82150720798", .{ .project_values = true }) != null);
    try testing.expect(memberProblem("projectEditor:", .{ .project_values = true }) != null);

    // A deleted principal can be revoked, never granted.
    try testing.expect(memberProblem("deleted:user:a@example.com?uid=1", .{}) != null);
    try testing.expectEqual(@as(?[]const u8, null), memberProblem("deleted:user:a@example.com?uid=1", .{ .deleted = true }));
}

test "permissionsProblem: 1 to 100, none empty, none twice, no wildcard" {
    try testing.expect(permissionsProblem(&.{}) != null);
    try testing.expectEqual(@as(?[]const u8, null), permissionsProblem(&.{"pubsub.topics.get"}));
    try testing.expectEqual(@as(?[]const u8, null), permissionsProblem(&.{ "pubsub.topics.get", "pubsub.topics.update" }));
    try testing.expect(permissionsProblem(&.{ "pubsub.topics.get", "pubsub.topics.get" }) != null);
    try testing.expect(permissionsProblem(&.{"pubsub.*"}) != null);
    try testing.expect(permissionsProblem(&.{""}) != null);
    var names: [101][]const u8 = undefined;
    var bufs: [101][16]u8 = undefined;
    for (&names, &bufs, 0..) |*n, *b, i| n.* = std.fmt.bufPrint(b, "a.b.c{d}", .{i}) catch unreachable;
    try testing.expectEqual(@as(?[]const u8, null), permissionsProblem(names[0..100]));
    try testing.expect(permissionsProblem(names[0..101]) != null);
}

test "encodePermissions and decodePermissions: every answer's shape, none held included" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqualStrings("{\"permissions\":[\"a.b.c\",\"d.e.f\"]}", try encodePermissions(arena, &.{ "a.b.c", "d.e.f" }));
    const held = try decodePermissions(arena, "{\"permissions\":[\"pubsub.topics.get\"]}");
    try testing.expectEqual(1, held.len);
    try testing.expectEqualStrings("pubsub.topics.get", held[0]);
    // Cloud Storage's answer carries its kind beside them.
    const bucket = try decodePermissions(arena, "{\"kind\":\"storage#testIamPermissionsResponse\",\"permissions\":[\"storage.buckets.get\"]}");
    try testing.expectEqualStrings("storage.buckets.get", bucket[0]);
    // Measured: a secret that holds nothing, or is missing, answers {}.
    try testing.expectEqual(0, (try decodePermissions(arena, "{}")).len);
    try testing.expectError(error.InvalidResponse, decodePermissions(arena, "[]"));
    try testing.expectError(error.InvalidResponse, decodePermissions(arena, "{\"permissions\":\"x\"}"));
}

/// A resource whose policy `update` reads and writes, holding it as the
/// servers do: every write moves the etag, and a write under an older one
/// is `error.Aborted`. It can refuse the next writes as another writer's
/// change would, making `interference` first, and fail every write.
const FakeResource = struct {
    gpa: Allocator,
    store: std.heap.ArenaAllocator,
    policy: Policy = .{},
    etag_counter: u32 = 1,
    etag_buf: [16]u8 = undefined,
    aborts: u32 = 0,
    interference: ?Change = null,
    fail: ?anyerror = null,
    reads: u32 = 0,
    writes: u32 = 0,

    fn init(gpa: Allocator) FakeResource {
        var r: FakeResource = .{ .gpa = gpa, .store = .init(gpa) };
        r.policy.etag = r.etag();
        return r;
    }

    fn deinit(r: *FakeResource) void {
        r.store.deinit();
    }

    fn etag(r: *FakeResource) []const u8 {
        return std.fmt.bufPrint(&r.etag_buf, "E{d}", .{r.etag_counter}) catch unreachable;
    }

    fn copy(arena: Allocator, p: Policy) Allocator.Error!Policy {
        const bindings = try arena.alloc(Binding, p.bindings.len);
        for (p.bindings, bindings) |b, *out| {
            const members = try arena.alloc([]const u8, b.members.len);
            for (b.members, members) |m, *o| o.* = try arena.dupe(u8, m);
            out.* = .{ .role = try arena.dupe(u8, b.role), .members = members, .condition = if (b.condition) |c| try arena.dupe(u8, c) else null };
        }
        return .{ .version = p.version, .etag = if (p.etag) |e| try arena.dupe(u8, e) else null, .bindings = bindings };
    }

    fn keep(r: *FakeResource, p: Policy) Allocator.Error!void {
        r.etag_counter += 1;
        var next = try copy(r.store.allocator(), p);
        next.etag = try r.store.allocator().dupe(u8, r.etag());
        r.policy = next;
    }

    fn answer(r: *FakeResource) !Owned(Policy) {
        var result: Owned(Policy) = try .init(r.gpa);
        errdefer result.deinit();
        result.value = try copy(result.arena.allocator(), r.policy);
        return result;
    }

    pub fn readPolicy(r: *FakeResource) !Owned(Policy) {
        r.reads += 1;
        return r.answer();
    }

    pub fn writePolicy(r: *FakeResource, p: Policy) !Owned(Policy) {
        r.writes += 1;
        if (r.fail) |err| return err;
        if (r.aborts > 0) {
            // Another writer got there first.
            r.aborts -= 1;
            const theirs = if (r.interference) |c| try c.apply(r.store.allocator(), r.policy) else r.policy;
            try r.keep(theirs);
            return error.Aborted;
        }
        if (!std.mem.eql(u8, p.etag orelse "", r.policy.etag.?)) return error.Aborted;
        try r.keep(p);
        return r.answer();
    }
};

const quick: RetryPolicy = .{ .max_attempts = 4, .initial_backoff_ms = 0 };

test "update: a grant or revoke writes once, and nothing when it already holds" {
    var r: FakeResource = .init(testing.allocator);
    defer r.deinit();
    const grant: Change = .{ .grant = .{ .role = "roles/r", .member = "user:a@x.com" } };
    var granted = try update(testing.allocator, testing.io, quick, &r, grant);
    defer granted.deinit();
    try testing.expect(granted.value.grants("roles/r", "user:a@x.com"));
    try testing.expectEqual(1, r.writes);
    // Held already, in another case: read, nothing written.
    var again = try update(testing.allocator, testing.io, quick, &r, .{ .grant = .{ .role = "roles/r", .member = "user:A@X.COM" } });
    defer again.deinit();
    try testing.expectEqual(1, r.writes);
    try testing.expectEqual(2, r.reads);

    var revoked = try update(testing.allocator, testing.io, quick, &r, .{ .revoke = grant.grant });
    defer revoked.deinit();
    try testing.expect(!revoked.value.grants("roles/r", "user:a@x.com"));
    try testing.expectEqual(0, revoked.value.bindings.len);
    try testing.expectEqual(2, r.writes);
    var none = try update(testing.allocator, testing.io, quick, &r, .{ .revoke = grant.grant });
    defer none.deinit();
    try testing.expectEqual(2, r.writes);
}

test "update: another change in between starts the round over; the retry policy's attempts bound it; other errors end it" {
    {
        var r: FakeResource = .init(testing.allocator);
        defer r.deinit();
        r.aborts = 2;
        r.interference = .{ .grant = .{ .role = "roles/theirs", .member = "user:b@x.com" } };
        var granted = try update(testing.allocator, testing.io, quick, &r, .{ .grant = .{ .role = "roles/mine", .member = "user:a@x.com" } });
        defer granted.deinit();
        // Theirs kept, mine added on top, in the third round.
        try testing.expect(granted.value.grants("roles/mine", "user:a@x.com"));
        try testing.expect(granted.value.grants("roles/theirs", "user:b@x.com"));
        try testing.expectEqual(3, r.writes);
        try testing.expectEqual(3, r.reads);
    }
    {
        // The other change was this very grant: read again, found, done.
        var r: FakeResource = .init(testing.allocator);
        defer r.deinit();
        r.aborts = 1;
        r.interference = .{ .grant = .{ .role = "roles/mine", .member = "user:a@x.com" } };
        var granted = try update(testing.allocator, testing.io, quick, &r, .{ .grant = .{ .role = "roles/mine", .member = "user:A@x.com" } });
        defer granted.deinit();
        try testing.expectEqual(1, r.writes);
        try testing.expectEqual(2, r.reads);
    }
    {
        var r: FakeResource = .init(testing.allocator);
        defer r.deinit();
        r.aborts = 10;
        try testing.expectError(error.Aborted, update(testing.allocator, testing.io, quick, &r, .{ .grant = .{ .role = "roles/r", .member = "user:a@x.com" } }));
        try testing.expectEqual(quick.max_attempts, r.writes);
    }
    {
        var r: FakeResource = .init(testing.allocator);
        defer r.deinit();
        r.fail = error.PermissionDenied;
        try testing.expectError(error.PermissionDenied, update(testing.allocator, testing.io, quick, &r, .{ .grant = .{ .role = "roles/r", .member = "user:a@x.com" } }));
        try testing.expectEqual(1, r.writes);
    }
}

fn updateAllocations(gpa: Allocator) !void {
    var r: FakeResource = .init(gpa);
    defer r.deinit();
    r.aborts = 1;
    r.interference = .{ .grant = .{ .role = "roles/theirs", .member = "user:b@x.com" } };
    var granted = try update(gpa, testing.io, quick, &r, .{ .grant = .{ .role = "roles/mine", .member = "user:a@x.com" } });
    granted.deinit();
    var revoked = try update(gpa, testing.io, quick, &r, .{ .revoke = .{ .role = "roles/theirs", .member = "user:b@x.com" } });
    revoked.deinit();
}

test "update: every allocation failure is OutOfMemory, and nothing leaks" {
    try std.testing.checkAllAllocationFailures(test_util.no_grow_allocator, updateAllocations, .{});
}

fn updateProperty(_: void, bytes: []const u8) !void {
    var g: test_util.ByteGen = .init(bytes);
    // One arena per run, and a simulated clock: what is under test is the
    // loop's logic, run as often as the fuzzer can, while leaks and every
    // allocation failure are the sweep's to find.
    var run_arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer run_arena.deinit();
    const gpa = run_arena.allocator();
    var clock: test_util.FakeClock = .{};
    const io = clock.io();
    const policy: RetryPolicy = .{ .max_attempts = 4 };
    var r: FakeResource = .init(gpa);
    defer r.deinit();
    const roles = [_][]const u8{ "roles/a", "roles/b" };
    const members = [_][]const u8{ "user:x@e.com", "user:X@E.COM", "serviceAccount:s@e.com", "group:g@e.com" };
    const steps = g.intRange(usize, 1, 12);
    for (0..steps) |_| {
        const grant: Change.Grant = .{ .role = g.pick([]const u8, &roles), .member = g.pick([]const u8, &members) };
        const change: Change = if (g.boolean()) .{ .grant = grant } else .{ .revoke = grant };
        r.aborts = g.intRange(u32, 0, 5);
        r.interference = if (g.boolean()) null else blk: {
            const other: Change.Grant = .{ .role = g.pick([]const u8, &roles), .member = g.pick([]const u8, &members) };
            break :blk if (g.boolean()) Change{ .grant = other } else Change{ .revoke = other };
        };
        const writes_before = r.writes;
        const reads_before = r.reads;
        const sleeps_before = clock.sleep_count;
        if (update(gpa, io, policy, &r, change)) |result| {
            var owned = result;
            defer owned.deinit();
            // Done means the change holds, in what came back and what is stored.
            try testing.expect(change.holds(owned.value));
            try testing.expect(change.holds(r.policy));
        } else |err| {
            try testing.expectEqual(error.Aborted, err);
            // Given up only after every round met another change.
            try testing.expectEqual(policy.max_attempts, r.writes - writes_before);
        }
        try testing.expect(r.reads - reads_before <= policy.max_attempts);
        // One wait before each round after the first, none after the last.
        try testing.expectEqual(r.reads - reads_before - 1, clock.sleep_count - sleeps_before);
        try testing.expect(r.writes - writes_before <= r.reads - reads_before);
        // Never a binding with no members, nor a member twice in one.
        for (r.policy.bindings) |b| {
            try testing.expect(b.members.len > 0);
            for (b.members, 0..) |m, i| for (b.members[0..i]) |o| try testing.expect(!sameMember(m, o));
        }
    }
}

test "fuzz iam update: a finished grant or revoke holds, attempts stay bounded, and no binding is left empty or doubled" {
    try test_util.fuzzBytes({}, updateProperty, .{ .corpus = &.{ "", test_util.repeat("\x01", 40), test_util.repeat("\x05\x00\x01\x03\x01\x00", 12), test_util.repeat("\x02\xff\x00\x04\x01\x01\x02\x00", 10) } });
}
