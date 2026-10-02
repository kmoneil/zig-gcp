//! IAM on topics and subscriptions: the calls both handles make, on
//! `v1/projects/{project}/{topics,subscriptions}/{id}:getIamPolicy` and its
//! siblings, through `core.iam`.
//!
//! Measured in production on 2026-10-01: a fresh resource's policy is
//! `{"etag": "ACAB"}`; every write moves the etag; a write under an older
//! one is 409 `ABORTED`, `error.Aborted`; a conditional binding is 400
//! "Can't set conditional policy on this resource", so it is refused here
//! first; a missing resource is 404, testIamPermissions included, although
//! its documentation promises an empty set. The emulator answers every IAM
//! call 501, `error.Unimplemented`.

const std = @import("std");
const core = @import("core");

const Client = @import("Client.zig");
const rpc = @import("rpc.zig");
const types = @import("types.zig");
const url = @import("url.zig");
const Error = @import("errors.zig").Error;
const Owned = types.Owned;
const Policy = core.iam.Policy;

/// A topic or a subscription, as `core.iam.update` reads and writes it.
pub const Resource = struct {
    client: *Client,
    collection: url.Collection,
    id: []const u8,

    pub fn readPolicy(r: Resource) Error!Owned(Policy) {
        var scratch: std.heap.ArenaAllocator = .init(r.client.gpa);
        defer scratch.deinit();
        const path = try url.resourcePath(scratch.allocator(), r.client.project_id, r.collection, r.id, ":getIamPolicy?options.requestedPolicyVersion=3");
        return fetch(r.client, .{ .method = .GET, .path = path });
    }

    /// Writes `policy` whole. Retried only under an etag, as a retry then
    /// fails cleanly when the first attempt landed: written again blindly,
    /// a policy could undo a change made in between.
    pub fn writePolicy(r: Resource, policy: Policy) Error!Owned(Policy) {
        var scratch: std.heap.ArenaAllocator = .init(r.client.gpa);
        defer scratch.deinit();
        const a = scratch.allocator();
        const path = try url.resourcePath(a, r.client.project_id, r.collection, r.id, ":setIamPolicy");
        const conditional = if (policy.etag) |etag| etag.len > 0 else false;
        return fetch(r.client, .{ .method = .POST, .path = path, .body = try core.iam.encodeSet(a, policy), .retry = conditional });
    }
};

/// `setIamPolicy`, after the checks: no condition, which Pub/Sub refuses,
/// and roles of a form every service takes.
pub fn set(r: Resource, policy: Policy) Error!Owned(Policy) {
    const c = r.client;
    if (policy.hasConditions()) {
        if (c.diagnostics) |d| d.print("Pub/Sub takes no conditional bindings: production refuses them with \"Can't set conditional policy on this resource\"", .{});
        return error.InvalidArgument;
    }
    for (policy.bindings) |b| {
        if (core.iam.roleProblem(b.role)) |problem| {
            if (c.diagnostics) |d| d.print("role \"{s}\": {s}", .{ b.role, problem });
            return error.InvalidArgument;
        }
    }
    return r.writePolicy(policy);
}

/// `addIamBinding` and `removeIamBinding`, after the checks.
pub fn change(r: Resource, what: core.iam.Change) Error!Owned(Policy) {
    const c = r.client;
    const grant = switch (what) {
        inline else => |g| g,
    };
    if (core.iam.roleProblem(grant.role)) |problem| {
        if (c.diagnostics) |d| d.print("role \"{s}\": {s}", .{ grant.role, problem });
        return error.InvalidArgument;
    }
    if (core.iam.memberProblem(grant.member, .{ .deleted = what == .revoke })) |problem| {
        if (c.diagnostics) |d| d.print("member \"{s}\": {s}", .{ grant.member, problem });
        return error.InvalidArgument;
    }
    return core.iam.update(c.gpa, c.io, c.retry, r, what);
}

/// `testIamPermissions`: the permissions the caller holds, of those asked.
pub fn testPermissions(r: Resource, permissions: []const []const u8) Error!Owned([]const []const u8) {
    const c = r.client;
    if (core.iam.permissionsProblem(permissions)) |problem| {
        if (c.diagnostics) |d| d.print("{s}", .{problem});
        return error.InvalidArgument;
    }
    var scratch: std.heap.ArenaAllocator = .init(c.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const path = try url.resourcePath(a, c.project_id, r.collection, r.id, ":testIamPermissions");
    var result: Owned([]const []const u8) = try .init(c.gpa);
    errdefer result.deinit();
    const body = try rpc.execute(c, result.arena, .{ .method = .POST, .path = path, .body = try core.iam.encodePermissions(a, permissions) });
    result.value = core.iam.decodePermissions(result.arena.allocator(), body) catch |err|
        return rpc.decodeFailed(c, err, "testIamPermissions answer");
    return result;
}

fn fetch(c: *Client, call: rpc.Call) Error!Owned(Policy) {
    var result: Owned(Policy) = try .init(c.gpa);
    errdefer result.deinit();
    const body = try rpc.execute(c, result.arena, call);
    result.value = core.iam.decode(result.arena.allocator(), body) catch |err|
        return rpc.decodeFailed(c, err, "IAM policy");
    return result;
}

const testing = std.testing;
const test_util = @import("test_util.zig");
const Harness = test_util.Harness;

const agent = "serviceAccount:service-82150720798@gcp-sa-pubsub.iam.gserviceaccount.com";
const aborted =
    \\{"error":{"code":409,"message":"There were concurrent policy changes. Please retry the whole read-modify-write with exponential backoff.","status":"ABORTED"}}
;

test "IAM on a subscription: read, write, grant, revoke and test, on the paths Pub/Sub serves them" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = "{\"etag\":\"ACAB\"}" } },
        .{ .respond = .{ .body = "{\"version\":1,\"etag\":\"BwX1\",\"bindings\":[{\"role\":\"roles/pubsub.viewer\",\"members\":[\"user:a@x.com\"]}]}" } },
        .{ .respond = .{ .body = "{\"version\":1,\"etag\":\"BwX1\",\"bindings\":[{\"role\":\"roles/pubsub.viewer\",\"members\":[\"user:a@x.com\"]}]}" } },
        .{ .respond = .{ .body = "{\"version\":1,\"etag\":\"BwX2\",\"bindings\":[{\"role\":\"roles/pubsub.viewer\",\"members\":[\"user:a@x.com\"]},{\"role\":\"roles/pubsub.subscriber\",\"members\":[\"" ++ agent ++ "\"]}]}" } },
        .{ .respond = .{ .body = "{\"version\":1,\"etag\":\"BwX2\",\"bindings\":[{\"role\":\"roles/pubsub.viewer\",\"members\":[\"user:a@x.com\"]},{\"role\":\"roles/pubsub.subscriber\",\"members\":[\"" ++ agent ++ "\"]}]}" } },
        .{ .respond = .{ .body = "{\"version\":1,\"etag\":\"BwX3\",\"bindings\":[{\"role\":\"roles/pubsub.viewer\",\"members\":[\"user:a@x.com\"]}]}" } },
        .{ .respond = .{ .body = "{\"permissions\":[\"pubsub.subscriptions.consume\"]}" } },
    }, .{});
    defer h.deinit();
    const worker = h.client.subscription("orders-worker");
    const base = "http://localhost:8085/v1/projects/p/subscriptions/orders-worker";

    var empty = try worker.iamPolicy();
    defer empty.deinit();
    try testing.expectEqualStrings("ACAB", empty.value.etag.?);
    try h.expectRequest(0, .GET, base ++ ":getIamPolicy?options.requestedPolicyVersion=3", null);

    var written = try worker.setIamPolicy(.{ .etag = "ACAB", .bindings = &.{.{ .role = "roles/pubsub.viewer", .members = &.{"user:a@x.com"} }} });
    defer written.deinit();
    try h.expectRequest(1, .POST, base ++ ":setIamPolicy",
        \\{"policy":{"version":1,"etag":"ACAB","bindings":[{"role":"roles/pubsub.viewer","members":["user:a@x.com"]}]}}
    );

    var granted = try worker.addIamBinding("roles/pubsub.subscriber", agent);
    defer granted.deinit();
    try testing.expect(granted.value.grants("roles/pubsub.subscriber", agent));
    try h.expectRequest(3, .POST, base ++ ":setIamPolicy",
        \\{"policy":{"version":1,"etag":"BwX1","bindings":[{"role":"roles/pubsub.viewer","members":["user:a@x.com"]},{"role":"roles/pubsub.subscriber","members":["serviceAccount:service-82150720798@gcp-sa-pubsub.iam.gserviceaccount.com"]}]}}
    );

    var revoked = try worker.removeIamBinding("roles/pubsub.subscriber", agent);
    defer revoked.deinit();
    try testing.expect(!revoked.value.grants("roles/pubsub.subscriber", agent));
    // The emptied binding goes, as the server drops it.
    try h.expectRequest(5, .POST, base ++ ":setIamPolicy",
        \\{"policy":{"version":1,"etag":"BwX2","bindings":[{"role":"roles/pubsub.viewer","members":["user:a@x.com"]}]}}
    );

    var held = try worker.testIamPermissions(&.{ "pubsub.subscriptions.consume", "pubsub.subscriptions.update" });
    defer held.deinit();
    try testing.expectEqual(1, held.value.len);
    try testing.expectEqualStrings("pubsub.subscriptions.consume", held.value[0]);
    try h.expectRequest(6, .POST, base ++ ":testIamPermissions",
        \\{"permissions":["pubsub.subscriptions.consume","pubsub.subscriptions.update"]}
    );
    try h.expectRequestCount(7);
}

test "IAM on a topic: revoke once, and test permissions" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = "{\"version\":1,\"etag\":\"BwX1\",\"bindings\":[{\"role\":\"roles/pubsub.publisher\",\"members\":[\"" ++ agent ++ "\"]}]}" } },
        .{ .respond = .{ .body = "{\"version\":1,\"etag\":\"BwX2\"}" } },
        // Gone already: read, nothing written.
        .{ .respond = .{ .body = "{\"version\":1,\"etag\":\"BwX2\"}" } },
        // Measured: a secret holding nothing answers {}; Pub/Sub may too.
        .{ .respond = .{ .body = "{}" } },
    }, .{});
    defer h.deinit();
    const orders = h.client.topic("orders");
    var revoked = try orders.removeIamBinding("roles/pubsub.publisher", agent);
    defer revoked.deinit();
    try h.expectRequest(1, .POST, "http://localhost:8085/v1/projects/p/topics/orders:setIamPolicy",
        \\{"policy":{"version":1,"etag":"BwX1","bindings":[]}}
    );
    var again = try orders.removeIamBinding("roles/pubsub.publisher", agent);
    defer again.deinit();
    try h.expectRequestCount(3);
    var none = try orders.testIamPermissions(&.{"pubsub.topics.publish"});
    defer none.deinit();
    try testing.expectEqual(0, none.value.len);
    try h.expectRequest(3, .POST, "http://localhost:8085/v1/projects/p/topics/orders:testIamPermissions",
        \\{"permissions":["pubsub.topics.publish"]}
    );
}

test "IAM: refused before sending: a condition, a role or member of no known form, a deleted principal granted, permissions out of bounds" {
    var h: Harness = undefined;
    try h.init(&.{}, .{});
    defer h.deinit();
    const worker = h.client.subscription("orders-worker");
    const orders = h.client.topic("orders");

    try testing.expectError(error.InvalidArgument, worker.setIamPolicy(.{ .bindings = &.{.{ .role = "roles/pubsub.viewer", .members = &.{"user:a@x.com"}, .condition = "{\"title\":\"t\",\"expression\":\"true\"}" }} }));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "conditional") != null);
    try testing.expectError(error.InvalidArgument, orders.setIamPolicy(.{ .bindings = &.{.{ .role = "viewer", .members = &.{"user:a@x.com"} }} }));
    try testing.expectError(error.InvalidArgument, worker.addIamBinding("", agent));
    try testing.expectError(error.InvalidArgument, worker.addIamBinding("pubsub.viewer", agent));
    try testing.expectError(error.InvalidArgument, worker.addIamBinding("roles/pubsub.viewer", ""));
    try testing.expectError(error.InvalidArgument, worker.addIamBinding("roles/pubsub.viewer", "ServiceAccount:a@x.iam.gserviceaccount.com"));
    try testing.expectError(error.InvalidArgument, worker.addIamBinding("roles/pubsub.viewer", "projectViewer:my-project"));
    try testing.expectError(error.InvalidArgument, orders.addIamBinding("roles/pubsub.viewer", "deleted:user:a@x.com?uid=1"));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "deleted:user:a@x.com?uid=1") != null);
    try testing.expectError(error.InvalidArgument, orders.testIamPermissions(&.{}));
    try testing.expectError(error.InvalidArgument, orders.testIamPermissions(&.{ "pubsub.topics.get", "pubsub.topics.get" }));
    try testing.expectError(error.InvalidArgument, worker.testIamPermissions(&.{"pubsub.*"}));
    try testing.expectError(error.InvalidResourceId, h.client.subscription("a/b").addIamBinding("roles/pubsub.viewer", agent));
    try h.expectRequestCount(0);
}

test "IAM: a deleted principal can be revoked, and a member stored lowercased is held already in any case" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = "{\"version\":1,\"etag\":\"E1\",\"bindings\":[{\"role\":\"roles/pubsub.viewer\",\"members\":[\"deleted:user:a@x.com?uid=1\",\"user:kevin@example.com\"]}]}" } },
        .{ .respond = .{ .body = "{\"version\":1,\"etag\":\"E2\",\"bindings\":[{\"role\":\"roles/pubsub.viewer\",\"members\":[\"user:kevin@example.com\"]}]}" } },
        .{ .respond = .{ .body = "{\"version\":1,\"etag\":\"E2\",\"bindings\":[{\"role\":\"roles/pubsub.viewer\",\"members\":[\"user:kevin@example.com\"]}]}" } },
    }, .{});
    defer h.deinit();
    const orders = h.client.topic("orders");
    var revoked = try orders.removeIamBinding("roles/pubsub.viewer", "deleted:user:a@x.com?uid=1");
    defer revoked.deinit();
    try h.expectRequest(1, .POST, "http://localhost:8085/v1/projects/p/topics/orders:setIamPolicy",
        \\{"policy":{"version":1,"etag":"E1","bindings":[{"role":"roles/pubsub.viewer","members":["user:kevin@example.com"]}]}}
    );
    // Measured: the server lowercases the address. Asked in capitals, held.
    var held = try orders.addIamBinding("roles/pubsub.viewer", "user:KEVIN@EXAMPLE.COM");
    defer held.deinit();
    try h.expectRequestCount(3);
}

test "IAM: a write under an etag is retried, one without is sent once, and a grant starts over after a wait" {
    {
        var h: Harness = undefined;
        try h.init(&.{
            .{ .respond = .{ .status = 503, .body = "{\"error\":{\"code\":503,\"status\":\"UNAVAILABLE\"}}" } },
            .{ .respond = .{ .body = "{\"version\":1,\"etag\":\"E2\"}" } },
        }, .{});
        defer h.deinit();
        var written = try h.client.topic("orders").setIamPolicy(.{ .etag = "E1" });
        defer written.deinit();
        try h.expectRequestCount(2);
    }
    for ([_]?[]const u8{ null, "" }) |etag| {
        var h: Harness = undefined;
        try h.init(&.{
            .{ .respond = .{ .status = 503, .body = "{\"error\":{\"code\":503,\"status\":\"UNAVAILABLE\"}}" } },
        }, .{});
        defer h.deinit();
        try testing.expectError(error.Unavailable, h.client.subscription("sub").setIamPolicy(.{ .etag = etag }));
        try h.expectRequestCount(1);
    }
    {
        var h: Harness = undefined;
        try h.init(&.{
            .{ .respond = .{ .body = "{\"etag\":\"E1\"}" } },
            .{ .respond = .{ .status = 409, .body = aborted } },
            .{ .respond = .{ .body = "{\"etag\":\"E2\"}" } },
            .{ .respond = .{ .body = "{\"version\":1,\"etag\":\"E3\",\"bindings\":[{\"role\":\"roles/pubsub.subscriber\",\"members\":[\"" ++ agent ++ "\"]}]}" } },
        }, .{ .retry = .{ .initial_backoff_ms = 400, .max_backoff_ms = 400 } });
        defer h.deinit();
        h.clock.random_byte = 0xff;
        var granted = try h.client.subscription("sub").addIamBinding("roles/pubsub.subscriber", agent);
        defer granted.deinit();
        try h.expectRequestCount(4);
        // The second round waited once, the full-jitter backoff its entropy picks.
        const policy: core.RetryPolicy = .{ .initial_backoff_ms = 400, .max_backoff_ms = 400 };
        try testing.expectEqual(1, h.clock.sleep_count);
        try testing.expectEqual(@as(i64, policy.backoffMs(1, std.math.maxInt(u64))), h.clock.sleepMs(0));
        try testing.expect(h.clock.sleepMs(0) > 0);
    }
}

test "IAM: the emulator's 501 is Unimplemented, and a missing resource's test is NotFound" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .status = 501, .body = "{\"error\":{\"code\":501,\"status\":\"UNIMPLEMENTED\"}}" } },
        .{ .respond = .{ .status = 404, .body = "{\"error\":{\"code\":404,\"message\":\"Resource not found (resource=gone).\",\"status\":\"NOT_FOUND\"}}" } },
    }, .{});
    defer h.deinit();
    try testing.expectError(error.Unimplemented, h.client.topic("orders").iamPolicy());
    try testing.expectError(error.NotFound, h.client.subscription("gone").testIamPermissions(&.{"pubsub.subscriptions.get"}));
    try testing.expectEqualStrings("Resource not found (resource=gone).", h.diag.message());
}

fn iamAllocations(gpa: std.mem.Allocator) !void {
    var fake: test_util.FakeTransport = .init(testing.allocator, &.{
        .{ .respond = .{ .body = "{\"etag\":\"ACAB\"}" } },
        .{ .respond = .{ .body = "{\"etag\":\"E1\"}" } },
        .{ .respond = .{ .status = 409, .body = aborted } },
        .{ .respond = .{ .body = "{\"etag\":\"E2\"}" } },
        .{ .respond = .{ .body = "{\"version\":1,\"etag\":\"E3\",\"bindings\":[{\"role\":\"roles/pubsub.subscriber\",\"members\":[\"" ++ agent ++ "\"]}]}" } },
        .{ .respond = .{ .body = "{\"version\":1,\"etag\":\"E3\",\"bindings\":[{\"role\":\"roles/pubsub.subscriber\",\"members\":[\"" ++ agent ++ "\"]}]}" } },
        .{ .respond = .{ .body = "{\"version\":1,\"etag\":\"E4\"}" } },
        .{ .respond = .{ .body = "{\"permissions\":[\"pubsub.subscriptions.get\"]}" } },
    });
    defer fake.deinit();
    var clock: test_util.FakeClock = .{};
    var client = try Client.init(gpa, clock.io(), .{
        .project_id = "p",
        .endpoint = .{ .url = "localhost:8085", .emulator = true },
        .transport = fake.transport(),
    });
    defer client.deinit();
    const s = client.subscription("sub");
    var read = try s.iamPolicy();
    read.deinit();
    var granted = try s.addIamBinding("roles/pubsub.subscriber", agent);
    granted.deinit();
    var revoked = try s.removeIamBinding("roles/pubsub.subscriber", agent);
    revoked.deinit();
    var held = try s.testIamPermissions(&.{"pubsub.subscriptions.get"});
    held.deinit();
}

test "IAM: every allocation failure is OutOfMemory without leaks" {
    try testing.checkAllAllocationFailures(testing.allocator, iamAllocations, .{});
}
