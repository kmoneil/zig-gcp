//! A snapshot handle: a client pointer and a short id such as
//! "before-deploy". Making one sends nothing. It borrows both, so it must
//! not outlive the client or the memory behind `id`.
//!
//! A snapshot keeps a subscription's backlog as it stood when the snapshot
//! was made, and every message published to the topic since, for up to 7
//! days. Any subscription of that topic can go back to it, one made
//! afterwards included. It outlives the subscription it was made of, and
//! the topic too.

const Snapshot = @This();

const std = @import("std");
const core = @import("core");

const Client = @import("Client.zig");
const codec = @import("codec.zig");
const iam = @import("iam.zig");
const rpc = @import("rpc.zig");
const types = @import("types.zig");
const url = @import("url.zig");
const validate = @import("validate.zig");
const Error = @import("errors.zig").Error;
const Owned = types.Owned;

client: *Client,
/// The client builds the full name, `projects/{project}/snapshots/{id}`.
id: []const u8,

/// Keeps the backlog of `config.subscription` as it stands: the messages
/// it has not had acknowledged, and every message published to its topic
/// from now on. A backlog so old that the snapshot would expire within the
/// hour is `error.FailedPrecondition`. If a lost first attempt already
/// created it, the retry reports `error.AlreadyExists`. The id, the
/// subscription and the labels are checked first; the emulator keeps no
/// labels, so only that check holds one to the rules before production
/// does. Needs `pubsub.snapshots.create` on the project and
/// `pubsub.subscriptions.consume` on the subscription.
pub fn create(self: Snapshot, config: types.SnapshotConfig) Error!Owned(types.SnapshotInfo) {
    const c = self.client;
    rpc.begin(c);
    try rpc.checkId(c, "snapshot", self.id);
    try validate.snapshotConfig(config, c.diagnostics);
    var scratch: std.heap.ArenaAllocator = .init(c.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const path = try url.resourcePath(a, c.project_id, .snapshots, self.id, "");
    // A full name as given, or an id in the client's project.
    const subscription = if (validate.isSubscriptionName(config.subscription))
        config.subscription
    else
        try url.resourceName(a, c.project_id, .subscriptions, config.subscription);
    const body = try codec.encodeSnapshot(a, subscription, config);
    return fetch(c, .{ .method = .PUT, .path = path, .body = body });
}

pub fn get(self: Snapshot) Error!Owned(types.SnapshotInfo) {
    const c = self.client;
    rpc.begin(c);
    try rpc.checkId(c, "snapshot", self.id);
    var scratch: std.heap.ArenaAllocator = .init(c.gpa);
    defer scratch.deinit();
    const path = try url.resourcePath(scratch.allocator(), c.project_id, .snapshots, self.id, "");
    return fetch(c, .{ .method = .GET, .path = path });
}

/// Replaces the snapshot's labels, as a set, and returns it as it is then.
/// Labels are all a snapshot lets change: production refuses a new expiry
/// or topic as "not mutable". The emulator answers
/// `error.Unimplemented`. Needs `pubsub.snapshots.update`.
pub fn update(self: Snapshot, changes: types.SnapshotUpdate) Error!Owned(types.SnapshotInfo) {
    const c = self.client;
    rpc.begin(c);
    try rpc.checkId(c, "snapshot", self.id);
    try validate.snapshotUpdate(changes, c.diagnostics);
    var scratch: std.heap.ArenaAllocator = .init(c.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const path = try url.resourcePath(a, c.project_id, .snapshots, self.id, "");
    const body = try codec.encodeSnapshotUpdate(a, changes);
    return fetch(c, .{ .method = .PATCH, .path = path, .body = body });
}

/// Deletes the snapshot, and the messages only it was keeping. Its name can
/// be used again at once. If a lost first attempt already deleted it, the
/// retry reports `error.NotFound`.
pub fn delete(self: Snapshot) Error!void {
    const c = self.client;
    rpc.begin(c);
    try rpc.checkId(c, "snapshot", self.id);
    var scratch: std.heap.ArenaAllocator = .init(c.gpa);
    defer scratch.deinit();
    const path = try url.resourcePath(scratch.allocator(), c.project_id, .snapshots, self.id, "");
    return rpc.executeDiscard(c, .{ .method = .DELETE, .path = path });
}

/// The snapshot's IAM policy, asked for as version 3. A fresh snapshot's
/// is empty, with the etag "ACAB". Needs `pubsub.snapshots.getIamPolicy`.
/// The emulator serves no IAM call on a snapshot, and answers this one
/// `error.InvalidArgument`.
pub fn iamPolicy(self: Snapshot) Error!Owned(core.iam.Policy) {
    const r = try self.iamResource();
    return r.readPolicy();
}

/// Writes `policy` as the snapshot's, whole, and returns it as stored, as
/// `Topic.setIamPolicy` does. Needs `pubsub.snapshots.setIamPolicy`.
pub fn setIamPolicy(self: Snapshot, policy: core.iam.Policy) Error!Owned(core.iam.Policy) {
    const r = try self.iamResource();
    return iam.set(r, policy);
}

/// Grants `member` the role `role` on the snapshot, unless it holds it
/// already without a condition, as `Topic.addIamBinding` does. Seeking a
/// subscription to a snapshot needs `pubsub.snapshots.seek` on it, which
/// `roles/pubsub.subscriber` carries. Needs
/// `pubsub.snapshots.getIamPolicy` and `setIamPolicy`.
pub fn addIamBinding(self: Snapshot, role: []const u8, member: []const u8) Error!Owned(core.iam.Policy) {
    const r = try self.iamResource();
    return iam.change(r, .{ .grant = .{ .role = role, .member = member } });
}

/// Takes `member` out of the snapshot's binding of `role` without a
/// condition, unless it is not there, as `Topic.removeIamBinding` does.
pub fn removeIamBinding(self: Snapshot, role: []const u8, member: []const u8) Error!Owned(core.iam.Policy) {
    const r = try self.iamResource();
    return iam.change(r, .{ .revoke = .{ .role = role, .member = member } });
}

/// The permissions the caller holds on the snapshot, of `permissions`, as
/// `Topic.testIamPermissions` answers them: such as
/// `pubsub.snapshots.seek`.
pub fn testIamPermissions(self: Snapshot, permissions: []const []const u8) Error!Owned([]const []const u8) {
    const r = try self.iamResource();
    return iam.testPermissions(r, permissions);
}

fn iamResource(self: Snapshot) Error!iam.Resource {
    const c = self.client;
    rpc.begin(c);
    try rpc.checkId(c, "snapshot", self.id);
    return .{ .client = c, .collection = .snapshots, .id = self.id };
}

fn fetch(c: *Client, call: rpc.Call) Error!Owned(types.SnapshotInfo) {
    var result: Owned(types.SnapshotInfo) = try .init(c.gpa);
    errdefer result.deinit();
    const body = try rpc.execute(c, result.arena, call);
    result.value = codec.decodeSnapshot(result.arena.allocator(), body) catch |err|
        return rpc.decodeFailed(c, err, "snapshot");
    return result;
}

const testing = std.testing;
const test_util = @import("test_util.zig");
const Harness = test_util.Harness;

/// A snapshot as production answered one on 2026-10-10.
const kept =
    \\{"name":"projects/p/snapshots/before","topic":"projects/p/topics/orders","expireTime":"2026-10-17T13:46:36.836Z","labels":{"env":"test"}}
;

test "golden: create, get, update and delete send the right requests" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = kept } },
        .{ .respond = .{ .body = kept } },
        .{ .respond = .{ .body = "{\"name\":\"projects/p/snapshots/before\",\"topic\":\"projects/p/topics/orders\",\"expireTime\":\"2026-10-17T13:46:36.836Z\"}" } },
        .{ .respond = .{ .body = "{}" } },
    }, .{});
    defer h.deinit();
    const before = h.client.snapshot("before");
    const path = "http://localhost:8085/v1/projects/p/snapshots/before";

    var created = try before.create(.{ .subscription = "orders-worker", .labels = &.{.{ .key = "env", .value = "test" }} });
    defer created.deinit();
    try h.expectRequest(0, .PUT, path, "{\"subscription\":\"projects/p/subscriptions/orders-worker\",\"labels\":{\"env\":\"test\"}}");
    try testing.expectEqualStrings("projects/p/snapshots/before", created.value.name);
    try testing.expectEqualStrings("projects/p/topics/orders", created.value.topic);
    try testing.expectEqual(try core.timestamp.parse("2026-10-17T13:46:36.836Z"), created.value.expire_time);
    try testing.expectEqualStrings("test", created.value.label("env").?);

    var got = try before.get();
    defer got.deinit();
    try h.expectRequest(1, .GET, path, null);
    try testing.expectEqualStrings("projects/p/snapshots/before", got.value.name);

    // An empty set clears the labels, and the answer then carries none.
    var cleared = try before.update(.{ .labels = &.{} });
    defer cleared.deinit();
    try h.expectRequest(2, .PATCH, path, "{\"snapshot\":{\"labels\":{}},\"updateMask\":\"labels\"}");
    try testing.expectEqual(0, cleared.value.labels.len);

    try before.delete();
    try h.expectRequest(3, .DELETE, path, null);
    try h.expectRequestCount(4);
}

test "create names a subscription of another project in full, as given" {
    var h: Harness = undefined;
    try h.init(&.{.{ .respond = .{ .body = kept } }}, .{});
    defer h.deinit();
    var created = try h.client.snapshot("before").create(.{ .subscription = "projects/other-project/subscriptions/far" });
    defer created.deinit();
    try h.expectRequest(
        0,
        .PUT,
        "http://localhost:8085/v1/projects/p/snapshots/before",
        "{\"subscription\":\"projects/other-project/subscriptions/far\"}",
    );
}

test "a bad id, subscription or label, and an update of nothing, fail before any request" {
    var h: Harness = undefined;
    try h.init(&.{}, .{});
    defer h.deinit();

    try testing.expectError(error.InvalidResourceId, h.client.snapshot("go").get());
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "invalid snapshot id") != null);
    try testing.expectError(error.InvalidResourceId, h.client.snapshot("googsnap").create(.{ .subscription = "orders" }));
    try testing.expectError(error.InvalidResourceId, h.client.snapshot("a/b").delete());
    try testing.expectError(error.InvalidResourceId, h.client.snapshot("1st").update(.{ .labels = &.{} }));
    try testing.expectError(error.InvalidResourceId, h.client.snapshot("x y z").iamPolicy());

    const before = h.client.snapshot("before");
    try testing.expectError(error.InvalidArgument, before.create(.{ .subscription = "projects/p/topics/orders" }));
    try testing.expectEqualStrings("the subscription is neither a subscription id nor projects/{project}/subscriptions/{id}", h.diag.message());
    // The emulator keeps no labels, so this check is all that holds one to
    // the rules before production does.
    try testing.expectError(error.InvalidArgument, before.create(.{ .subscription = "orders", .labels = &.{.{ .key = "UPPER", .value = "v" }} }));
    try testing.expectError(error.InvalidArgument, before.update(.{}));
    try testing.expectEqualStrings("the update changes nothing", h.diag.message());
    try testing.expectError(error.InvalidArgument, before.update(.{ .labels = &.{.{ .key = "Bad Key", .value = "v" }} }));
    try h.expectRequestCount(0);
}

test "refusals: a name taken, a subscription or snapshot that is not there, a backlog too old, and what the emulator has not got" {
    var h: Harness = undefined;
    try h.init(&.{
        // Production's words, 2026-10-10.
        .{ .respond = .{ .status = 409, .body = "{\"error\":{\"code\":409,\"message\":\"Resource already exists in the project (resource=before).\",\"status\":\"ALREADY_EXISTS\"}}" } },
        .{ .respond = .{ .status = 404, .body = "{\"error\":{\"code\":404,\"message\":\"Resource not found (resource=orders).\",\"status\":\"NOT_FOUND\"}}" } },
        // The proto's status for a snapshot that would expire within the
        // hour; its message went unmeasured, so this one is made up.
        .{ .respond = .{ .status = 400, .body = "{\"error\":{\"code\":400,\"message\":\"too old\",\"status\":\"FAILED_PRECONDITION\"}}" } },
        // The emulator's words.
        .{ .respond = .{ .status = 501, .body = "{\"error\":{\"code\":501,\"message\":\"Method google.pubsub.v1.Subscriber/UpdateSnapshot is unimplemented\",\"status\":\"UNIMPLEMENTED\"}}" } },
        .{ .respond = .{ .status = 404, .body = "{\"error\":{\"code\":404,\"message\":\"Resource not found (resource=before).\",\"status\":\"NOT_FOUND\"}}" } },
    }, .{});
    defer h.deinit();
    const before = h.client.snapshot("before");

    try testing.expectError(error.AlreadyExists, before.create(.{ .subscription = "orders" }));
    try testing.expectEqual(409, h.diag.http_status);
    try testing.expectEqualStrings("Resource already exists in the project (resource=before).", h.diag.message());
    try testing.expectError(error.NotFound, before.create(.{ .subscription = "orders" }));
    try testing.expectEqualStrings("Resource not found (resource=orders).", h.diag.message());
    try testing.expectError(error.FailedPrecondition, before.create(.{ .subscription = "orders" }));
    try testing.expectError(error.Unimplemented, before.update(.{ .labels = &.{} }));
    try testing.expectError(error.NotFound, before.delete());
    // None of them is an answer a second attempt would change.
    try h.expectRequestCount(5);
}

test "an answer that is no snapshot is InvalidResponse, and says what it was not" {
    var h: Harness = undefined;
    try h.init(&.{.{ .respond = .{ .body = "{\"name\":\"projects/p/snapshots/before\"}" } }}, .{});
    defer h.deinit();
    try testing.expectError(error.InvalidResponse, h.client.snapshot("before").get());
    try testing.expectEqualStrings("the snapshot response could not be decoded", h.diag.message());
}

test "IAM on a snapshot: read, grant, revoke and test, on the paths Pub/Sub serves them" {
    const member = "user:ada@example.com";
    const granted_body = "{\"version\":1,\"etag\":\"BwX1\",\"bindings\":[{\"role\":\"roles/pubsub.subscriber\",\"members\":[\"" ++ member ++ "\"]}]}";
    var h: Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = "{\"etag\":\"ACAB\"}" } },
        .{ .respond = .{ .body = "{\"etag\":\"ACAB\"}" } },
        .{ .respond = .{ .body = granted_body } },
        .{ .respond = .{ .body = granted_body } },
        .{ .respond = .{ .body = "{\"version\":1,\"etag\":\"BwX2\"}" } },
        .{ .respond = .{ .body = "{\"permissions\":[\"pubsub.snapshots.seek\"]}" } },
        .{ .respond = .{ .body = "{\"version\":1,\"etag\":\"BwX3\"}" } },
    }, .{});
    defer h.deinit();
    const before = h.client.snapshot("before");
    const base = "http://localhost:8085/v1/projects/p/snapshots/before";

    var fresh = try before.iamPolicy();
    defer fresh.deinit();
    try testing.expectEqualStrings("ACAB", fresh.value.etag.?);
    try h.expectRequest(0, .GET, base ++ ":getIamPolicy?options.requestedPolicyVersion=3", null);

    // Who may seek a subscription to it.
    var granted = try before.addIamBinding("roles/pubsub.subscriber", member);
    defer granted.deinit();
    try testing.expect(granted.value.grants("roles/pubsub.subscriber", member));
    try h.expectRequest(2, .POST, base ++ ":setIamPolicy",
        \\{"policy":{"version":1,"etag":"ACAB","bindings":[{"role":"roles/pubsub.subscriber","members":["user:ada@example.com"]}]}}
    );

    var revoked = try before.removeIamBinding("roles/pubsub.subscriber", member);
    defer revoked.deinit();
    try testing.expect(!revoked.value.grants("roles/pubsub.subscriber", member));
    try h.expectRequest(4, .POST, base ++ ":setIamPolicy",
        \\{"policy":{"version":1,"etag":"BwX1","bindings":[]}}
    );

    var held = try before.testIamPermissions(&.{ "pubsub.snapshots.seek", "pubsub.snapshots.delete" });
    defer held.deinit();
    try testing.expectEqual(1, held.value.len);
    try testing.expectEqualStrings("pubsub.snapshots.seek", held.value[0]);
    try h.expectRequest(5, .POST, base ++ ":testIamPermissions",
        \\{"permissions":["pubsub.snapshots.seek","pubsub.snapshots.delete"]}
    );

    var written = try before.setIamPolicy(.{ .etag = "BwX2", .bindings = &.{} });
    defer written.deinit();
    try testing.expectEqualStrings("BwX3", written.value.etag.?);
    try h.expectRequest(6, .POST, base ++ ":setIamPolicy",
        \\{"policy":{"version":1,"etag":"BwX2","bindings":[]}}
    );
    try h.expectRequestCount(7);
}
