//! IAM policies, as Google's resource-level `getIamPolicy` and
//! `setIamPolicy` methods read and write them: bindings of a role to its
//! members, perhaps under a condition, and the etag that makes a write fail
//! rather than undo another made since the read. Every module whose
//! resources carry a policy shares this.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Stringify = std.json.Stringify;

pub const Policy = struct {
    /// 1, or 3 for a policy whose bindings carry conditions, which must be
    /// written back as 3.
    version: u32 = 1,
    /// As read: written back, it makes the write fail if the policy
    /// changed since. Null writes over whatever is there.
    etag: ?[]const u8 = null,
    bindings: []const Binding = &.{},

    /// Whether `member` holds `role` with no condition.
    pub fn grants(self: Policy, role: []const u8, member: []const u8) bool {
        for (self.bindings) |b| {
            if (b.condition != null or !std.mem.eql(u8, b.role, role)) continue;
            for (b.members) |m| if (std.mem.eql(u8, m, member)) return true;
        }
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

pub const DecodeError = error{ InvalidResponse, OutOfMemory };

/// A policy as `getIamPolicy` and `setIamPolicy` answer it. An empty policy
/// is `{}` or `{"etag": ...}`.
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

/// The body of a `setIamPolicy`: `{"policy": ...}`, conditions as read.
pub fn encodeSet(arena: Allocator, policy: Policy) Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    var jw: Stringify = .{ .writer = &out.writer };
    writeSet(&jw, policy) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn writeSet(jw: *Stringify, policy: Policy) !void {
    try jw.beginObject();
    try jw.objectField("policy");
    try jw.beginObject();
    try jw.objectField("version");
    try jw.write(policy.version);
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
    try jw.endObject();
}

/// `policy` with `member` added to the binding of `role` that has no
/// condition, or to a new one; the etag and every other binding as they
/// were. Memory from `arena`.
pub fn withMember(arena: Allocator, policy: Policy, role: []const u8, member: []const u8) Allocator.Error!Policy {
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
            for (b.members) |m| held = held or std.mem.eql(u8, m, member);
        }
        try testing.expectEqual(held, next.grants(other, member));
    }
    // What setIamPolicy answers, written as sent, reads back the same.
    const body = try encodeSet(arena, next);
    const sent = try std.json.parseFromSliceLeaky(struct { policy: std.json.Value }, arena, body, .{});
    const back = try decode(arena, try Stringify.valueAlloc(arena, sent.policy, .{}));
    try testing.expectEqual(next.version, back.version);
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
    try test_util.fuzzBytes({}, roundTripProperty, .{ .corpus = &.{ "", "\x01" ** 64, "\x07\x02\x09" ** 30 } });
}
