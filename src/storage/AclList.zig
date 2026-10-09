//! A cheap handle on one access control list: a bucket's, the default
//! list its new objects get, or an object's. Making one sends nothing.
//!
//! A list is changed whole, never one entry at a time: `grant` and
//! `revoke` read it with the metageneration it is at, change it, and write
//! it back under that metageneration, starting over when another change
//! came in between, as `addIamBinding` does. Cloud Storage's single-entry
//! writes take no condition at all, and an idempotency token does not
//! deduplicate them, as measured 2026-10-05, so nothing could make them
//! safe to repeat, and two at once on one bucket answer 409.
//!
//! What production does with a whole list, as measured 2026-10-05:
//!
//! - The owner always keeps OWNER: the account that wrote an object, or a
//!   bucket's project owners. A list without them comes back with them,
//!   so taking OWNER from them is refused here before sending.
//! - An empty list is ignored, not applied. `set` with none sends
//!   `predefinedAcl=private` instead, which leaves the owner alone: for a
//!   default object list, nobody at all, and new objects get their writer.
//! - Emails are kept in lower case, and a project named by ID is kept
//!   under its number, so entries are matched as the server keeps them.
//! - At most 100 entries; a bucket takes OWNER, WRITER and READER, an
//!   object and a default object list OWNER and READER.
//! - A bucket's list shows in its IAM policy as legacy bindings, and a
//!   change to it moves the policy's etag.
//! - A default object list change takes up to 30 seconds to reach new
//!   objects, Google documents.

const AclList = @This();

const std = @import("std");
const core = @import("core");

const Client = @import("Client.zig");
const acl = @import("acl.zig");
const codec = @import("codec.zig");
const idempotency = @import("idempotency.zig");
const names = @import("names.zig");
const rpc = @import("rpc.zig");
const types = @import("types.zig");
const Error = @import("errors.zig").Error;

/// Borrowed; the handle must not outlive it.
client: *Client,
/// Borrowed; the handle must not outlive it.
bucket: []const u8,
/// The object whose list this is; null for a bucket's two. Borrowed.
object: ?[]const u8 = null,
target: names.AclTarget,
/// As `Bucket.billing_project`: the project this handle's requests bill.
billing_project: ?[]const u8 = null,

/// The most entries a list holds.
pub const max_entries = 100;

/// This handle, billing `project` for every request it makes, as
/// `Bucket.withBillingProject` says.
pub fn withBillingProject(self: AclList, project: []const u8) AclList {
    var copy = self;
    copy.billing_project = project;
    return copy;
}

fn billing(self: AclList, copy: *Client) Error!AclList {
    rpc.begin(self.client);
    try rpc.checkBillingProject(self.client, self.billing_project);
    try rpc.checkBucketName(self.client, self.bucket);
    if (self.object) |name| try rpc.checkObjectName(self.client, name);
    copy.* = rpc.billed(self.client, self.billing_project orelse self.client.billing_project);
    var billed_self = self;
    billed_self.client = copy;
    return billed_self;
}

/// The whole list, its owner, and the metageneration a guarded `set`
/// takes. A bucket with uniform bucket-level access keeps none:
/// `error.UniformAccessEnabled`. Reading one needs
/// `storage.buckets.getIamPolicy` or `storage.objects.getIamPolicy`.
pub fn get(self: AclList) Error!types.Owned(types.Acl) {
    var copy: Client = undefined;
    return (try self.billing(&copy)).load();
}

/// One entry: `error.NotFound` when the list has none for `entity`.
pub fn entry(self: AclList, entity: types.AclEntity) Error!types.Owned(types.AclEntry) {
    var copy: Client = undefined;
    const billed = try self.billing(&copy);
    try billed.checkEntity(entity, 0);
    var scratch: std.heap.ArenaAllocator = .init(billed.client.gpa);
    defer scratch.deinit();
    const path = try names.aclEntryPath(scratch.allocator(), billed.bucket, billed.object, billed.target, try acl.entityText(scratch.allocator(), entity));
    var result: types.Owned(types.AclEntry) = try .init(billed.client.gpa);
    errdefer result.deinit();
    const body = try rpc.execute(billed.client, result.arena, .{ .method = .GET, .path = path });
    result.value = codec.decodeAclEntry(result.arena.allocator(), body) catch |err|
        return rpc.decodeFailed(billed.client, err, "access control entry");
    return result;
}

/// Gives `entity` exactly `role`, adding it or changing the role it has,
/// and answers the list as written, or as read when it already held. Safe
/// to retry, and retried when another change comes in between.
pub fn grant(self: AclList, entity: types.AclEntity, role: types.AclRole) Error!types.Owned(types.Acl) {
    var copy: Client = undefined;
    const billed = try self.billing(&copy);
    try billed.checkEntity(entity, 0);
    try billed.checkRole(role, 0);
    return billed.update(.{ .grant = .{ .entity = entity, .role = role } });
}

/// Takes `entity` off the list, and answers the list as written, or as
/// read when it was not there. The owner cannot be taken off.
pub fn revoke(self: AclList, entity: types.AclEntity) Error!types.Owned(types.Acl) {
    var copy: Client = undefined;
    const billed = try self.billing(&copy);
    try billed.checkEntity(entity, 0);
    return billed.update(.{ .revoke = entity });
}

/// Replaces the whole list with `entries`: an empty one leaves the owner
/// alone. Retried only under `guard.if_metageneration_match`, which a
/// list read by `get` names; a write it refuses, another change having
/// come in between, is `error.Aborted`. The owner, left out, keeps OWNER.
pub fn set(self: AclList, entries: []const types.AclEntry, guard: types.AclGuard) Error!types.Owned(types.Acl) {
    var copy: Client = undefined;
    const billed = try self.billing(&copy);
    try billed.checkEntries(entries);
    if (guard.if_generation_match != null and billed.target != .object) {
        return billed.refuse("if_generation_match guards an object's list only", .{});
    }
    return billed.write(entries, guard);
}

/// What `update` does to a list.
const Change = union(enum) {
    grant: struct { entity: types.AclEntity, role: types.AclRole },
    revoke: types.AclEntity,

    /// Whether `list` already says what the change would make it say.
    fn holds(c: Change, list: types.Acl) bool {
        return switch (c) {
            .grant => |g| for (list.entries) |e| {
                if (acl.sameEntity(e.entity, g.entity)) break e.role == g.role;
            } else false,
            .revoke => |entity| for (list.entries) |e| {
                if (acl.sameEntity(e.entity, entity)) break false;
            } else true,
        };
    }

    /// `entries` with the change made, the entries it leaves alone as the
    /// server spelled them. Memory from `arena`.
    fn apply(c: Change, arena: std.mem.Allocator, entries: []const types.AclEntry) std.mem.Allocator.Error![]const types.AclEntry {
        var next: std.ArrayList(types.AclEntry) = try .initCapacity(arena, entries.len + 1);
        var found = false;
        for (entries) |e| switch (c) {
            .grant => |g| if (acl.sameEntity(e.entity, g.entity)) {
                found = true;
                next.appendAssumeCapacity(.{ .entity = e.entity, .role = g.role });
            } else next.appendAssumeCapacity(e),
            .revoke => |entity| if (!acl.sameEntity(e.entity, entity)) next.appendAssumeCapacity(e),
        };
        if (c == .grant and !found) next.appendAssumeCapacity(.{ .entity = c.grant.entity, .role = c.grant.role });
        return next.items;
    }
};

/// Changes the list once: reads it, returns it when the change already
/// holds, and otherwise writes it changed under the metageneration read.
/// A write refused because another change came in between starts the
/// whole round over after a full-jitter wait, up to the retry policy's
/// attempts; any other error ends it.
fn update(self: AclList, change: Change) Error!types.Owned(types.Acl) {
    var round: u32 = 0;
    while (true) {
        round += 1;
        var read = try self.load();
        if (change.holds(read.value)) return read;
        defer read.deinit();
        try self.checkOwner(change, read.value.owner);
        var scratch: std.heap.ArenaAllocator = .init(self.client.gpa);
        defer scratch.deinit();
        const next = try change.apply(scratch.allocator(), read.value.entries);
        if (next.len > max_entries) {
            return self.refuse("{d} entries; a list holds at most {d}", .{ next.len, max_entries });
        }
        return self.write(next, .{
            .if_metageneration_match = read.value.metageneration,
            .if_generation_match = read.value.generation,
        }) catch |err| {
            if (err != error.Aborted or round >= self.client.retry.max_attempts) return err;
            const delay_ms = rpc.backoffMs(self.client, round);
            try self.client.io.sleep(.fromMilliseconds(delay_ms), .awake);
            continue;
        };
    }
}

/// Reads the list through its bucket or object, with what guards a write.
fn load(self: AclList) Error!types.Owned(types.Acl) {
    var scratch: std.heap.ArenaAllocator = .init(self.client.gpa);
    defer scratch.deinit();
    const path = try names.aclResourcePath(scratch.allocator(), self.bucket, self.object, .{});
    var result: types.Owned(types.Acl) = try .init(self.client.gpa);
    errdefer result.deinit();
    const body = try rpc.execute(self.client, result.arena, .{ .method = .GET, .path = path });
    result.value = try self.decoded(result.arena, body);
    return result;
}

/// Writes `entries` whole under `guard` and answers the list as written.
fn write(self: AclList, entries: []const types.AclEntry, guard: types.AclGuard) Error!types.Owned(types.Acl) {
    var scratch: std.heap.ArenaAllocator = .init(self.client.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const field = if (self.target == .default_object) "defaultObjectAcl" else "acl";
    const resource = try names.aclResourcePath(a, self.bucket, self.object, guard);
    // An empty list alone is ignored, so the owner alone is asked for by
    // its canned name, beside an empty list.
    const path = if (entries.len > 0)
        resource
    else
        try names.withParam(a, resource, if (self.target == .default_object) "predefinedDefaultObjectAcl" else "predefinedAcl", "private");
    const body = try codec.encodeAclBody(a, field, entries);

    var result: types.Owned(types.Acl) = try .init(self.client.gpa);
    errdefer result.deinit();
    var token: idempotency.Token = undefined;
    token.init(self.client);
    const safe = guard.if_metageneration_match != null or self.client.retry_unconditional_writes;
    // An object patch repeated under its token is answered with the first
    // result, as measured 2026-09-30; a bucket patch runs again, which its
    // metageneration guard makes safe.
    const retry: idempotency.Retry = if (self.target == .object)
        idempotency.writeRetry(self.client, safe)
    else
        .{ .retry = safe, .window_ms = null };
    const response = try rpc.executeIamWrite(self.client, result.arena, .{
        .method = .PATCH,
        .path = path,
        .body = body,
        .headers = token.slice(),
        .retry = retry.retry,
        .retry_window_ms = retry.window_ms,
    });
    result.value = try self.decoded(result.arena, response);
    return result;
}

/// The list a bucket or object answer carries.
fn decoded(self: AclList, arena: *std.heap.ArenaAllocator, body: []const u8) Error!types.Acl {
    const r = codec.decodeAclResource(arena.allocator(), body) catch |err|
        return rpc.decodeFailed(self.client, err, if (self.target == .object) "object" else "bucket");
    if (r.uniform_bucket_level_access) {
        if (self.client.diagnostics) |d| d.print("the bucket has uniform bucket-level access, which keeps no access control lists", .{});
        return error.UniformAccessEnabled;
    }
    const entries = switch (self.target) {
        .bucket, .object => r.acl orelse return self.unexplained(arena),
        // Left out when empty, but only for a caller who may read the
        // bucket's own list too.
        .default_object => r.default_object_acl orelse if (r.acl != null) &.{} else return self.unexplained(arena),
    };
    return .{
        .entries = entries,
        .owner = if (self.target == .default_object) null else r.owner,
        .metageneration = r.metageneration,
        .generation = if (self.target == .object) r.generation else null,
    };
}

/// A resource answered without the list, which says neither why nor
/// whether it is empty. The list's own endpoint says why: uniform access
/// (`error.UniformAccessEnabled`), or a caller who may not read it.
fn unexplained(self: AclList, arena: *std.heap.ArenaAllocator) Error {
    const path = try names.aclEntryPath(arena.allocator(), self.bucket, self.object, self.target, null);
    _ = try rpc.execute(self.client, arena, .{ .method = .GET, .path = path });
    if (self.client.diagnostics) |d| d.print("the answer carried no access control list, though the list can be read", .{});
    return error.InvalidResponse;
}

/// A list `set` may send: roles the target takes, entities that can be
/// spelled, none twice, at most 100.
fn checkEntries(self: AclList, entries: []const types.AclEntry) Error!void {
    if (entries.len > max_entries) return self.refuse("{d} entries; a list holds at most {d}", .{ entries.len, max_entries });
    for (entries, 0..) |e, i| {
        try self.checkEntity(e.entity, i);
        try self.checkRole(e.role, i);
        for (entries[0..i]) |earlier| if (acl.sameEntity(earlier.entity, e.entity)) {
            return self.refuse("entry {d} names an entity entry {d} names already", .{ i, i - 1 });
        };
    }
}

fn checkEntity(self: AclList, entity: types.AclEntity, index: usize) Error!void {
    const problem: ?[]const u8 = switch (entity) {
        .user, .group => |email| if (email.len == 0) "an email is empty" else null,
        .domain => |domain| if (domain.len == 0) "a domain is empty" else null,
        .project => |p| if (p.number.len == 0 or !isDigits(p.number))
            "a project is named by its number, which the server keeps an ID as, so an entry named by ID could never be found again"
        else
            null,
        .other => |text| if (text.len == 0) "an entity is empty" else null,
        .all_users, .all_authenticated_users => null,
    };
    if (problem) |p| return self.refuse("entry {d}: {s}", .{ index, p });
}

fn checkRole(self: AclList, role: types.AclRole, index: usize) Error!void {
    if (role == .unknown) return self.refuse("entry {d}: a role this library does not know is never sent", .{index});
    if (role == .writer and self.target != .bucket) {
        return self.refuse("entry {d}: WRITER is a bucket's role; an object's list takes OWNER and READER", .{index});
    }
}

/// The owner keeps OWNER: the server refuses less, 403 "The owner of the
/// resource is required to have OWNER access.", and a whole list that
/// leaves them out comes back with them, so the caller would believe a
/// change that never happened.
fn checkOwner(self: AclList, change: Change, owner: ?types.AclEntity) Error!void {
    const o = owner orelse return;
    switch (change) {
        .grant => |g| if (g.role != .owner and acl.sameEntity(g.entity, o)) {
            return self.refuse("the owner keeps OWNER; it cannot be given less", .{});
        },
        .revoke => |entity| if (acl.sameEntity(entity, o)) {
            return self.refuse("the owner keeps OWNER; it cannot be taken off the list", .{});
        },
    }
}

fn isDigits(text: []const u8) bool {
    for (text) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

fn refuse(self: AclList, comptime format: []const u8, args: anytype) Error {
    if (self.client.diagnostics) |d| d.print(format, args);
    return error.InvalidArgument;
}

const testing = std.testing;
const test_util = @import("test_util.zig");
const Reply = test_util.FakeTransport.Reply;

const bucket_read =
    \\{"kind":"storage#bucket","name":"b","metageneration":"3",
    \\ "owner":{"entity":"project-owners-82150720798"},
    \\ "acl":[{"kind":"storage#bucketAccessControl","entity":"project-owners-82150720798","role":"OWNER",
    \\  "projectTeam":{"projectNumber":"82150720798","team":"owners"},"etag":"CAM="},
    \\ {"entity":"project-viewers-82150720798","role":"READER"}],
    \\ "defaultObjectAcl":[{"entity":"project-owners-82150720798","role":"OWNER"}],
    \\ "iamConfiguration":{"uniformBucketLevelAccess":{"enabled":false},"publicAccessPrevention":"enforced"}}
;
const ubla_object_body =
    \\{"error":{"code":400,"message":"Cannot get legacy ACL for an object when uniform bucket-level access is enabled. Read more at https://cloud.google.com/storage/docs/uniform-bucket-level-access","errors":[{"domain":"global","reason":"invalid"}]}}
;
const stale_body =
    \\{"error":{"code":412,"message":"At least one of the pre-conditions you specified did not hold.","errors":[{"domain":"global","reason":"conditionNotMet","locationType":"header","location":"If-Match"}]}}
;
const pap_body =
    \\{"error":{"code":412,"message":"The member bindings allUsers and allAuthenticatedUsers are not allowed since public access prevention is enforced.","errors":[{"domain":"global","reason":"conditionNotMet"}]}}
;

fn ok(body: []const u8) Reply {
    return .{ .respond = .{ .body = body } };
}

test "golden: get reads each list through its bucket or object, with what guards a write" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        ok(bucket_read),
        ok("{\"metageneration\":\"3\",\"acl\":[{\"entity\":\"project-owners-1\",\"role\":\"OWNER\"}]}"),
        ok("{\"name\":\"a\",\"generation\":\"7\",\"metageneration\":\"2\",\"owner\":{\"entity\":\"user-w@x.com\"},\"acl\":[{\"entity\":\"user-w@x.com\",\"role\":\"OWNER\"}]}"),
    }, .{});
    defer h.deinit();
    const b = h.client.bucket("b");

    var list = try b.acl().get();
    defer list.deinit();
    try h.expectRequest(0, .GET, "https://storage.googleapis.com/storage/v1/b/b?projection=full", null);
    try testing.expectEqual(2, list.value.entries.len);
    try testing.expectEqual(.viewers, list.value.entries[1].entity.project.team);
    try testing.expectEqualStrings("82150720798", list.value.owner.?.project.number);
    try testing.expectEqual(3, list.value.metageneration);
    try testing.expectEqual(null, list.value.generation);

    // Cloud Storage leaves an empty default object list out, as measured,
    // while the bucket's own list shows the caller may read lists.
    var default = try b.defaultObjectAcl().get();
    defer default.deinit();
    try testing.expectEqual(0, default.value.entries.len);
    try testing.expectEqual(null, default.value.owner);

    var object = try b.object("a").acl().get();
    defer object.deinit();
    try h.expectRequest(2, .GET, "https://storage.googleapis.com/storage/v1/b/b/o/a?projection=full", null);
    try testing.expectEqual(7, object.value.generation.?);
    try testing.expectEqual(2, object.value.metageneration);
    try testing.expectEqualStrings("w@x.com", object.value.owner.?.user);
}

test "a list that is not there says why: uniform access on the bucket, or the list's own refusal" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        ok("{\"metageneration\":\"5\",\"iamConfiguration\":{\"uniformBucketLevelAccess\":{\"enabled\":true}}}"),
        ok("{\"name\":\"a\",\"generation\":\"7\",\"metageneration\":\"1\"}"),
        .{ .respond = .{ .status = 400, .body = ubla_object_body } },
        ok("{\"metageneration\":\"5\"}"),
        .{ .respond = .{ .status = 403, .body = "{\"error\":{\"code\":403,\"message\":\"no\",\"errors\":[{\"reason\":\"forbidden\"}]}}" } },
    }, .{});
    defer h.deinit();
    const b = h.client.bucket("b");
    try testing.expectError(error.UniformAccessEnabled, b.acl().get());
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "uniform bucket-level access") != null);
    // An object's answer says nothing of its bucket: the list's endpoint
    // answers for it.
    try testing.expectError(error.UniformAccessEnabled, b.object("a").acl().get());
    try h.expectRequest(2, .GET, "https://storage.googleapis.com/storage/v1/b/b/o/a/acl", null);
    // Neither list shown: a caller who may read neither.
    try testing.expectError(error.PermissionDenied, b.defaultObjectAcl().get());
    try h.expectRequest(4, .GET, "https://storage.googleapis.com/storage/v1/b/b/defaultObjectAcl", null);
}

test "golden: one entry, and NotFound for one the list does not have" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        ok("{\"kind\":\"storage#objectAccessControl\",\"entity\":\"user-w@x.com\",\"role\":\"READER\",\"email\":\"w@x.com\"}"),
        .{ .respond = .{ .status = 404, .body = "{\"error\":{\"code\":404,\"message\":\"The specified key does not exist.\",\"errors\":[{\"reason\":\"notFound\"}]}}" } },
    }, .{});
    defer h.deinit();
    const list = h.client.bucket("b").object("a b").acl();
    var one = try list.entry(.{ .user = "w@x.com" });
    defer one.deinit();
    try h.expectRequest(0, .GET, "https://storage.googleapis.com/storage/v1/b/b/o/a%20b/acl/user-w%40x.com", null);
    try testing.expectEqual(.reader, one.value.role);
    try testing.expectError(error.NotFound, list.entry(.all_users));
    try h.expectRequest(1, .GET, "https://storage.googleapis.com/storage/v1/b/b/o/a%20b/acl/allUsers", null);
}

test "golden: grant writes the whole list under the metageneration it read" {
    var h: test_util.Harness = undefined;
    try h.init(&.{ ok(bucket_read), ok(bucket_read) }, .{});
    defer h.deinit();
    var written = try h.client.bucket("b").acl().grant(.{ .user = "Ada@Example.com" }, .writer);
    defer written.deinit();
    try h.expectRequest(
        1,
        .PATCH,
        "https://storage.googleapis.com/storage/v1/b/b?projection=full&ifMetagenerationMatch=3",
        "{\"acl\":[{\"entity\":\"project-owners-82150720798\",\"role\":\"OWNER\"},{\"entity\":\"project-viewers-82150720798\",\"role\":\"READER\"}," ++
            "{\"entity\":\"user-Ada@Example.com\",\"role\":\"WRITER\"}]}",
    );
}

test "grant and revoke: nothing sent when the list already says so, and the owner kept" {
    var h: test_util.Harness = undefined;
    try h.init(&.{ ok(bucket_read), ok(bucket_read), ok(bucket_read), ok(bucket_read) }, .{});
    defer h.deinit();
    const list = h.client.bucket("b").acl();
    var held = try list.grant(.{ .project = .{ .team = .viewers, .number = "82150720798" } }, .reader);
    held.deinit();
    var absent = try list.revoke(.{ .group = "nobody@x.com" });
    absent.deinit();
    try h.expectRequestCount(2);
    // The owner keeps OWNER, which the server would answer 403 or quietly
    // put back.
    try testing.expectError(error.InvalidArgument, list.revoke(.{ .project = .{ .team = .owners, .number = "82150720798" } }));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "owner keeps OWNER") != null);
    try testing.expectError(error.InvalidArgument, list.grant(.{ .project = .{ .team = .owners, .number = "82150720798" } }, .reader));
    // Each of those read the list, and wrote nothing.
    try h.expectRequestCount(4);
}

test "grant starts over when another change came in between, and stops at a refusal" {
    {
        const revoked =
            \\{"metageneration":"4","owner":{"entity":"project-owners-1"},"acl":[{"entity":"project-owners-1","role":"OWNER"}]}
        ;
        var h: test_util.Harness = undefined;
        try h.init(&.{
            ok(bucket_read),
            .{ .respond = .{ .status = 412, .body = stale_body } },
            ok(revoked),
            ok(revoked),
        }, .{});
        defer h.deinit();
        var written = try h.client.bucket("b").acl().revoke(.{ .project = .{ .team = .viewers, .number = "82150720798" } });
        defer written.deinit();
        // The second round read a list without the entry: nothing to write.
        try h.expectRequestCount(3);
        try testing.expectEqual(1, h.clock.sleep_count);
    }
    {
        var h: test_util.Harness = undefined;
        try h.init(&.{ ok(bucket_read), .{ .respond = .{ .status = 412, .body = pap_body } } }, .{});
        defer h.deinit();
        try testing.expectError(error.PublicAccessPrevented, h.client.bucket("b").acl().grant(.all_users, .reader));
        try h.expectRequestCount(2);
    }
    {
        // Every round stale: the retry policy's attempts, then Aborted.
        var h: test_util.Harness = undefined;
        try h.init(&.{
            ok(bucket_read), .{ .respond = .{ .status = 412, .body = stale_body } },
            ok(bucket_read), .{ .respond = .{ .status = 412, .body = stale_body } },
        }, .{ .retry = .{ .max_attempts = 2, .initial_backoff_ms = 1, .max_backoff_ms = 1 } });
        defer h.deinit();
        try testing.expectError(error.Aborted, h.client.bucket("b").acl().grant(.all_authenticated_users, .reader));
        try h.expectRequestCount(4);
    }
}

test "golden: set, an empty list as the owner alone, and an object's list held to its generation" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        // As production answered `predefinedDefaultObjectAcl=private`: the
        // emptied default list left out, the bucket's own there.
        ok("{\"metageneration\":\"6\",\"acl\":[{\"entity\":\"project-owners-1\",\"role\":\"OWNER\"}]}"),
        ok("{\"metageneration\":\"6\",\"acl\":[{\"entity\":\"project-owners-1\",\"role\":\"OWNER\"}]}"),
        ok("{\"name\":\"a\",\"generation\":\"7\",\"metageneration\":\"3\",\"acl\":[{\"entity\":\"user-w@x.com\",\"role\":\"OWNER\"}]}"),
    }, .{});
    defer h.deinit();
    const b = h.client.bucket("b");
    var none = try b.defaultObjectAcl().set(&.{}, .{ .if_metageneration_match = 5 });
    try testing.expectEqual(0, none.value.entries.len);
    none.deinit();
    try h.expectRequest(0, .PATCH, "https://storage.googleapis.com/storage/v1/b/b?projection=full&ifMetagenerationMatch=5&predefinedDefaultObjectAcl=private", "{\"defaultObjectAcl\":[]}");
    var bucket_none = try b.acl().set(&.{}, .{});
    bucket_none.deinit();
    try h.expectRequest(1, .PATCH, "https://storage.googleapis.com/storage/v1/b/b?projection=full&predefinedAcl=private", "{\"acl\":[]}");
    var object = try b.object("a").acl().set(&.{.{ .entity = .{ .group = "g@x.com" }, .role = .reader }}, .{ .if_generation_match = 7, .if_metageneration_match = 2 });
    defer object.deinit();
    try h.expectRequest(
        2,
        .PATCH,
        "https://storage.googleapis.com/storage/v1/b/b/o/a?projection=full&ifGenerationMatch=7&ifMetagenerationMatch=2",
        "{\"acl\":[{\"entity\":\"group-g@x.com\",\"role\":\"READER\"}]}",
    );
    try testing.expectEqual(7, object.value.generation.?);
}

test "golden: a grant on an object is held to the generation it read, and the default list has no owner" {
    var h: test_util.Harness = undefined;
    const object_read = "{\"name\":\"a\",\"generation\":\"7\",\"metageneration\":\"2\",\"owner\":{\"entity\":\"user-w@x.com\"},\"acl\":[{\"entity\":\"user-w@x.com\",\"role\":\"OWNER\"}]}";
    // A bucket answer carries the bucket's owner, which a default object
    // list does not have: its objects are owned by their writers.
    const bucket_with_owner = "{\"metageneration\":\"3\",\"owner\":{\"entity\":\"project-owners-1\"},\"acl\":[{\"entity\":\"project-owners-1\",\"role\":\"OWNER\"}],\"defaultObjectAcl\":[{\"entity\":\"project-owners-1\",\"role\":\"OWNER\"}]}";
    try h.init(&.{ ok(object_read), ok(object_read), ok(bucket_with_owner), ok(bucket_with_owner) }, .{});
    defer h.deinit();
    var granted = try h.client.bucket("b").object("a").acl().grant(.{ .group = "g@x.com" }, .reader);
    granted.deinit();
    try h.expectRequest(
        1,
        .PATCH,
        "https://storage.googleapis.com/storage/v1/b/b/o/a?projection=full&ifGenerationMatch=7&ifMetagenerationMatch=2",
        "{\"acl\":[{\"entity\":\"user-w@x.com\",\"role\":\"OWNER\"},{\"entity\":\"group-g@x.com\",\"role\":\"READER\"}]}",
    );
    // The project owners may leave a default list: nobody is its owner.
    var revoked = try h.client.bucket("b").defaultObjectAcl().revoke(.{ .project = .{ .team = .owners, .number = "1" } });
    defer revoked.deinit();
    try testing.expectEqual(null, revoked.value.owner);
    try h.expectRequest(3, .PATCH, "https://storage.googleapis.com/storage/v1/b/b?projection=full&ifMetagenerationMatch=3&predefinedDefaultObjectAcl=private", "{\"defaultObjectAcl\":[]}");
}

test "an answer without a metageneration is InvalidResponse: no write could be guarded by it" {
    var h: test_util.Harness = undefined;
    try h.init(&.{ok("{\"acl\":[{\"entity\":\"project-owners-1\",\"role\":\"OWNER\"}]}")}, .{});
    defer h.deinit();
    try testing.expectError(error.InvalidResponse, h.client.bucket("b").acl().get());
}

test "set: an unguarded bucket list is sent once, never again after a failure" {
    var h: test_util.Harness = undefined;
    try h.init(&.{.{ .respond = .{ .status = 503, .body = "{}" } }}, .{});
    defer h.deinit();
    try testing.expectError(error.Unavailable, h.client.bucket("b").acl().set(&.{.{ .entity = .all_authenticated_users, .role = .reader }}, .{}));
    try h.expectRequestCount(1);
}

test "set and grant refuse before sending what the server would refuse or keep differently" {
    var h: test_util.Harness = undefined;
    try h.init(&.{}, .{});
    defer h.deinit();
    const b = h.client.bucket("b");
    const object = b.object("a").acl();
    const cases = [_]struct { list: AclList, entries: []const types.AclEntry, words: []const u8 }{
        .{ .list = object, .entries = &.{.{ .entity = .all_users, .role = .writer }}, .words = "WRITER is a bucket's role" },
        .{ .list = b.defaultObjectAcl(), .entries = &.{.{ .entity = .all_users, .role = .writer }}, .words = "WRITER is a bucket's role" },
        .{ .list = b.acl(), .entries = &.{.{ .entity = .all_users, .role = .unknown }}, .words = "does not know" },
        .{ .list = b.acl(), .entries = &.{ .{ .entity = .{ .user = "A@x.com" }, .role = .reader }, .{ .entity = .{ .user = "a@X.com" }, .role = .owner } }, .words = "names an entity" },
        .{ .list = b.acl(), .entries = &.{.{ .entity = .{ .project = .{ .team = .viewers, .number = "extractctl" } }, .role = .reader }}, .words = "by its number" },
        .{ .list = b.acl(), .entries = &.{.{ .entity = .{ .user = "" }, .role = .reader }}, .words = "empty" },
        .{ .list = b.acl(), .entries = &.{.{ .entity = .{ .other = "" }, .role = .reader }}, .words = "an entity is empty" },
    };
    for (cases) |case| {
        errdefer std.debug.print("{s}: {s}\n", .{ case.words, h.diag.message() });
        try testing.expectError(error.InvalidArgument, case.list.set(case.entries, .{}));
        try testing.expect(std.mem.indexOf(u8, h.diag.message(), case.words) != null);
    }
    var many: [max_entries + 1]types.AclEntry = undefined;
    var names_buf: [max_entries + 1][16]u8 = undefined;
    for (&many, &names_buf, 0..) |*e, *buf, i| e.* = .{ .entity = .{ .domain = std.fmt.bufPrint(buf, "d{d}.example", .{i}) catch unreachable }, .role = .reader };
    try testing.expectError(error.InvalidArgument, b.acl().set(&many, .{}));
    try testing.expectError(error.InvalidArgument, b.acl().set(many[0..1], .{ .if_generation_match = 1 }));
    try testing.expectError(error.InvalidArgument, object.grant(.all_users, .writer));
    try testing.expectError(error.InvalidArgument, object.entry(.{ .group = "" }));
    try h.expectRequestCount(0);
}

test "an entity this library cannot spell is still sent as given" {
    var h: test_util.Harness = undefined;
    try h.init(&.{ ok(bucket_read), ok(bucket_read) }, .{});
    defer h.deinit();
    var written = try h.client.bucket("b").acl().grant(.{ .other = "serviceAccount-sa@p.iam.gserviceaccount.com" }, .reader);
    written.deinit();
    try testing.expect(std.mem.indexOf(u8, (try h.fake.request(1)).body.?, "serviceAccount-sa@p.iam.gserviceaccount.com") != null);
}

test "a resource without a list, though the list reads fine, is an invalid answer" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        ok("{\"metageneration\":\"3\"}"),
        ok("{\"items\":[]}"),
    }, .{});
    defer h.deinit();
    try testing.expectError(error.InvalidResponse, h.client.bucket("b").acl().get());
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "though the list can be read") != null);
}

test "a grant onto a full list is refused with the limit, not sent" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var body: std.Io.Writer.Allocating = .init(arena.allocator());
    try body.writer.writeAll("{\"metageneration\":\"3\",\"owner\":{\"entity\":\"project-owners-1\"},\"acl\":[{\"entity\":\"project-owners-1\",\"role\":\"OWNER\"}");
    for (1..max_entries) |i| try body.writer.print(",{{\"entity\":\"domain-d{d}.example\",\"role\":\"READER\"}}", .{i});
    try body.writer.writeAll("]}");
    var h: test_util.Harness = undefined;
    try h.init(&.{ok(body.written())}, .{});
    defer h.deinit();
    try testing.expectError(error.InvalidArgument, h.client.bucket("b").acl().grant(.{ .user = "new@x.com" }, .reader));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "at most 100") != null);
    try h.expectRequestCount(1);
}

// Against `FakeMultipart`, which keeps lists by the rules production was
// measured to keep them by.

const FakeFixture = struct {
    fake: test_util.FakeMultipart,
    token: core.StaticToken,
    diag: core.Diagnostics,
    client: Client,

    fn init(f: *FakeFixture) !void {
        f.fake = .init(testing.allocator, testing.io);
        errdefer f.fake.deinit();
        f.token = .{ .token = "ya29.t" };
        f.diag = .{};
        f.client = try .init(testing.allocator, f.fake.io, .{
            .project_id = "extractctl",
            .token_provider = f.token.provider(),
            .transport = f.fake.transport(),
            .diagnostics = &f.diag,
            .retry = .{ .max_attempts = 3, .initial_backoff_ms = 1, .max_backoff_ms = 2 },
        });
    }

    fn deinit(f: *FakeFixture) void {
        f.client.deinit();
        f.fake.deinit();
    }
};

/// The list spelled out, `entity role` per entry, in the server's order.
fn spelled(gpa: std.mem.Allocator, entries: []const types.AclEntry) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    for (entries, 0..) |e, i| {
        if (i > 0) try out.writer.writeAll(", ");
        try acl.writeEntity(&out.writer, e.entity);
        try out.writer.print(" {t}", .{e.role});
    }
    return out.toOwnedSlice();
}

fn expectSpelled(expected: []const u8, entries: []const types.AclEntry) !void {
    const got = try spelled(testing.allocator, entries);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(expected, got);
}

test "against the fake: each list granted, revoked and set as production keeps it" {
    var f: FakeFixture = undefined;
    try f.init();
    defer f.deinit();
    const b = f.client.bucket("b");
    var created = try b.create(.{ .location = "us-central1" });
    created.deinit();

    // A new bucket's lists are projectPrivate.
    var fresh = try b.acl().grant(.{ .user = "Ada@Example.com" }, .writer);
    defer fresh.deinit();
    try expectSpelled("project-owners-82150720798 owner, project-editors-82150720798 owner, project-viewers-82150720798 reader, user-ada@example.com writer", fresh.value.entries);
    var demoted = try b.acl().grant(.{ .user = "ada@example.com" }, .reader);
    demoted.deinit();
    var revoked = try b.acl().revoke(.{ .project = .{ .team = .editors, .number = "82150720798" } });
    defer revoked.deinit();
    try expectSpelled("project-owners-82150720798 owner, project-viewers-82150720798 reader, user-ada@example.com reader", revoked.value.entries);

    // The default list: emptied, then given one entry; a new object gets
    // it, then its writer as OWNER.
    var none = try b.defaultObjectAcl().set(&.{}, .{});
    defer none.deinit();
    try testing.expectEqual(0, none.value.entries.len);
    var one = try b.defaultObjectAcl().grant(.{ .group = "team@example.com" }, .reader);
    one.deinit();
    var upload = try b.object("a").upload("x", .{});
    upload.deinit();
    var object = try b.object("a").acl().get();
    defer object.deinit();
    try expectSpelled("group-team@example.com reader, user-zig-gcp@extractctl.iam.gserviceaccount.com owner", object.value.entries);
    try testing.expectEqualStrings("zig-gcp@extractctl.iam.gserviceaccount.com", object.value.owner.?.user);

    // The object's list: set whole without its owner, who comes back.
    var set_list = try b.object("a").acl().set(&.{.{ .entity = .all_authenticated_users, .role = .reader }}, .{ .if_metageneration_match = object.value.metageneration });
    defer set_list.deinit();
    try expectSpelled("allAuthenticatedUsers reader, user-zig-gcp@extractctl.iam.gserviceaccount.com owner", set_list.value.entries);
    // Under the metageneration read before it, a second set is refused.
    try testing.expectError(error.Aborted, b.object("a").acl().set(&.{}, .{ .if_metageneration_match = object.value.metageneration }));
    var entry_read = try b.object("a").acl().entry(.all_authenticated_users);
    defer entry_read.deinit();
    try testing.expectEqual(.reader, entry_read.value.role);
    try testing.expectError(error.NotFound, b.object("a").acl().entry(.all_users));
    var owner_only = try b.object("a").acl().set(&.{}, .{});
    defer owner_only.deinit();
    try expectSpelled("user-zig-gcp@extractctl.iam.gserviceaccount.com owner", owner_only.value.entries);

    // Uniform access keeps none, and refuses every change.
    var uniform = try b.update(.{ .uniform_bucket_level_access = true });
    uniform.deinit();
    try testing.expectError(error.UniformAccessEnabled, b.acl().get());
    try testing.expectError(error.UniformAccessEnabled, b.defaultObjectAcl().grant(.all_users, .reader));
    try testing.expectError(error.UniformAccessEnabled, b.object("a").acl().get());
    try testing.expectError(error.UniformAccessEnabled, b.object("a").acl().set(&.{}, .{}));
}

test "against the fake: public access prevention refuses a public grant, and the list stays" {
    var f: FakeFixture = undefined;
    try f.init();
    defer f.deinit();
    const b = f.client.bucket("b");
    var created = try b.create(.{ .public_access_prevention = .enforced });
    created.deinit();
    try testing.expectError(error.PublicAccessPrevented, b.acl().grant(.all_users, .reader));
    try testing.expectError(error.PublicAccessPrevented, b.defaultObjectAcl().set(&.{.{ .entity = .all_authenticated_users, .role = .reader }}, .{}));
    var list = try b.acl().get();
    defer list.deinit();
    try testing.expectEqual(3, list.value.entries.len);
}

/// A model of a list: entity text to role, the owner pinned.
const Model = struct {
    entities: [8][]const u8 = undefined,
    roles: [8]?types.AclRole = @splat(null),
};

const fuzz_entities = [_]types.AclEntity{
    .all_users,
    .all_authenticated_users,
    .{ .user = "a@example.com" },
    .{ .user = "B@Example.com" },
    .{ .group = "g@example.com" },
    .{ .domain = "example.org" },
    .{ .project = .{ .team = .viewers, .number = "82150720798" } },
    .{ .project = .{ .team = .owners, .number = "82150720798" } },
};

fn modelProperty(_: void, input: []const u8) anyerror!void {
    var g: test_util.ByteGen = .init(input);
    var f: FakeFixture = undefined;
    try f.init();
    defer f.deinit();
    const b = f.client.bucket("b");
    const prevented = g.boolean();
    var created = try b.create(.{ .public_access_prevention = if (prevented) .enforced else .inherited });
    created.deinit();
    var upload = try b.object("o").upload("x", .{});
    upload.deinit();
    const lists = [_]AclList{ b.acl(), b.defaultObjectAcl(), b.object("o").acl() };
    for (0..g.intRange(u8, 1, 12)) |_| {
        const list = lists[g.intRange(u8, 0, 2)];
        const entity = fuzz_entities[g.intRange(u8, 0, fuzz_entities.len - 1)];
        const role = g.pick(types.AclRole, &.{ .owner, .writer, .reader });
        var before = try list.get();
        defer before.deinit();
        const granting = g.boolean();
        const outcome = if (granting) list.grant(entity, role) else list.revoke(entity);
        if (outcome) |written| {
            var w = written;
            defer w.deinit();
            // At most 100 entries, each entity once, and the owner keeps
            // OWNER.
            try testing.expect(w.value.entries.len <= max_entries);
            for (w.value.entries, 0..) |e, i| for (w.value.entries[0..i]) |earlier| try testing.expect(!acl.sameEntity(e.entity, earlier.entity));
            if (w.value.owner) |owner| {
                const kept = for (w.value.entries) |e| {
                    if (acl.sameEntity(e.entity, owner)) break e.role;
                } else null;
                try testing.expectEqual(.owner, kept.?);
            }
            // The change holds, and nothing else changed.
            const after = try list.get();
            var after_owned = after;
            defer after_owned.deinit();
            const now = for (after.value.entries) |e| {
                if (acl.sameEntity(e.entity, entity)) break e.role;
            } else null;
            if (granting) {
                try testing.expectEqual(role, now.?);
            } else {
                try testing.expectEqual(null, now);
            }
            for (before.value.entries) |e| {
                if (acl.sameEntity(e.entity, entity)) continue;
                const still = for (after.value.entries) |x| {
                    if (acl.sameEntity(x.entity, e.entity)) break x.role;
                } else null;
                try testing.expectEqual(e.role, still.?);
            }
        } else |err| switch (err) {
            // WRITER beyond a bucket's list, the owner's OWNER, and the
            // public under prevention: refused, and the list as it was.
            error.InvalidArgument => try testing.expect(role == .writer and list.target != .bucket or
                (before.value.owner != null and acl.sameEntity(before.value.owner.?, entity))),
            error.PublicAccessPrevented => try testing.expect(prevented and (entity == .all_users or entity == .all_authenticated_users)),
            else => return err,
        }
    }
}

test "heavy property AclList against the fake: every grant and revoke holds, the rest stays, the owner keeps OWNER" {
    try test_util.fuzzBytes({}, modelProperty, .{ .corpus = &.{ "", "\x00\x05\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a", "\x01\xff\x00\x01\x02\x00\x00\x07\x01\x02\x00" } });
}
