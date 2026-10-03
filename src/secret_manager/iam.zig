//! IAM on secrets, global and regional: `GET ...:getIamPolicy`, `POST
//! ...:setIamPolicy` with `{"policy": ...}`, and `POST
//! ...:testIamPermissions`, through `core.iam`, on the secret's own path
//! and host. A version's permissions follow its secret's policy.
//!
//! Measured in production on 2026-10-01, global and regional alike: a
//! fresh secret's policy is `{"etag": "ACAB"}`; every write moves the etag;
//! a write under an older one is 409 `ABORTED`, `error.Aborted`; a
//! conditional binding is taken at version 3, which a policy with a
//! condition is written as, and a version 1 read renames its role
//! `ROLE_withcond_HASH`; Secret Manager's roles and the basic roles are
//! taken, another service's are not; `auditConfigs` stay as they are when
//! a write leaves them out and sends no `updateMask`, which this library
//! never sends; `testIamPermissions` takes at most 100 of Secret Manager's
//! own permissions, and on a secret that does not exist answers that none
//! is held, where a missing topic or bucket is `error.NotFound`.

const std = @import("std");
const core = @import("core");

const Client = @import("Client.zig");
const names = @import("names.zig");
const rpc = @import("rpc.zig");
const types = @import("types.zig");
const Error = @import("errors.zig").Error;
const Policy = core.iam.Policy;

/// A secret, as `core.iam.update` reads and writes its policy.
pub const Resource = struct {
    client: *Client,
    id: []const u8,

    pub fn readPolicy(r: Resource) Error!types.Owned(Policy) {
        var scratch: std.heap.ArenaAllocator = .init(r.client.gpa);
        defer scratch.deinit();
        const path = try names.secretPath(scratch.allocator(), r.client.parent(), r.id, ":getIamPolicy?options.requestedPolicyVersion=3");
        return fetch(r.client, .{ .method = .GET, .path = path });
    }

    /// Writes `policy` whole, with no `updateMask`, so the secret's audit
    /// configuration stays as it is. Retried only under an etag: a retry
    /// then fails cleanly, as `error.Aborted`, when the first attempt
    /// landed.
    pub fn writePolicy(r: Resource, policy: Policy) Error!types.Owned(Policy) {
        var scratch: std.heap.ArenaAllocator = .init(r.client.gpa);
        defer scratch.deinit();
        const a = scratch.allocator();
        const path = try names.secretPath(a, r.client.parent(), r.id, ":setIamPolicy");
        const conditional = if (policy.etag) |etag| etag.len > 0 else false;
        return fetch(r.client, .{ .method = .POST, .path = path, .body = try core.iam.encodeSet(a, policy), .retry = conditional });
    }
};

/// `setIamPolicy`, after the check every service shares: roles of a known
/// form.
pub fn set(r: Resource, policy: Policy) Error!types.Owned(Policy) {
    for (policy.bindings) |b| {
        if (core.iam.roleProblem(b.role)) |problem| {
            if (r.client.diagnostics) |d| d.print("role \"{s}\": {s}", .{ b.role, problem });
            return error.InvalidArgument;
        }
    }
    return r.writePolicy(policy);
}

/// `addIamBinding` and `removeIamBinding`, after the checks.
pub fn change(r: Resource, what: core.iam.Change) Error!types.Owned(Policy) {
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
pub fn testPermissions(r: Resource, permissions: []const []const u8) Error!types.Owned([]const []const u8) {
    const c = r.client;
    if (core.iam.permissionsProblem(permissions)) |problem| {
        if (c.diagnostics) |d| d.print("{s}", .{problem});
        return error.InvalidArgument;
    }
    var scratch: std.heap.ArenaAllocator = .init(c.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const path = try names.secretPath(a, c.parent(), r.id, ":testIamPermissions");
    var result: types.Owned([]const []const u8) = try .init(c.gpa);
    errdefer result.deinit();
    const body = try rpc.execute(c, result.arena, .{ .method = .POST, .path = path, .body = try core.iam.encodePermissions(a, permissions) });
    result.value = core.iam.decodePermissions(result.arena.allocator(), body) catch |err|
        return rpc.decodeFailed(c, err, "testIamPermissions answer");
    return result;
}

fn fetch(c: *Client, call: rpc.Call) Error!types.Owned(Policy) {
    var result: types.Owned(Policy) = try .init(c.gpa);
    errdefer result.deinit();
    const body = try rpc.execute(c, result.arena, call);
    result.value = core.iam.decode(result.arena.allocator(), body) catch |err|
        return rpc.decodeFailed(c, err, "IAM policy");
    return result;
}

const testing = std.testing;
const test_util = @import("test_util.zig");
const Harness = test_util.Harness;

const agent = "serviceAccount:service-82150720798@gs-project-accounts.iam.gserviceaccount.com";
const aborted =
    \\{"error":{"code":409,"message":"There were concurrent policy changes. Please retry the whole read-modify-write with exponential backoff.","status":"ABORTED"}}
;

test "IAM on a secret: read, write, grant, revoke and test, global and regional, on the paths Secret Manager serves them" {
    inline for (.{ .{ null, "https://secretmanager.googleapis.com/v1/projects/extractctl/secrets/db" }, .{ "europe-west3", "https://secretmanager.europe-west3.rep.googleapis.com/v1/projects/extractctl/locations/europe-west3/secrets/db" } }) |where| {
        var h: Harness = undefined;
        try h.init(&.{
            .{ .respond = .{ .body = "{\"etag\":\"ACAB\"}" } },
            .{ .respond = .{ .body = "{\"version\":1,\"etag\":\"BwX1\",\"bindings\":[{\"role\":\"roles/secretmanager.viewer\",\"members\":[\"user:a@x.com\"]}]}" } },
            .{ .respond = .{ .body = "{\"version\":1,\"etag\":\"BwX1\",\"bindings\":[{\"role\":\"roles/secretmanager.viewer\",\"members\":[\"user:a@x.com\"]}]}" } },
            .{ .respond = .{ .body = "{\"version\":1,\"etag\":\"BwX2\",\"bindings\":[{\"role\":\"roles/secretmanager.viewer\",\"members\":[\"user:a@x.com\"]},{\"role\":\"roles/secretmanager.secretAccessor\",\"members\":[\"" ++ agent ++ "\"]}]}" } },
            .{ .respond = .{ .body = "{\"version\":1,\"etag\":\"BwX2\",\"bindings\":[{\"role\":\"roles/secretmanager.viewer\",\"members\":[\"user:a@x.com\"]},{\"role\":\"roles/secretmanager.secretAccessor\",\"members\":[\"" ++ agent ++ "\"]}]}" } },
            .{ .respond = .{ .body = "{\"version\":1,\"etag\":\"BwX3\",\"bindings\":[{\"role\":\"roles/secretmanager.viewer\",\"members\":[\"user:a@x.com\"]}]}" } },
            .{ .respond = .{ .body = "{\"permissions\":[\"secretmanager.versions.access\"]}" } },
        }, .{ .location = where[0] });
        defer h.deinit();
        const db = h.client.secret("db");
        const base = where[1];

        var empty = try db.iamPolicy();
        defer empty.deinit();
        try testing.expectEqualStrings("ACAB", empty.value.etag.?);
        try h.expectRequest(0, .GET, base ++ ":getIamPolicy?options.requestedPolicyVersion=3", null);

        var written = try db.setIamPolicy(.{ .etag = "ACAB", .bindings = &.{.{ .role = "roles/secretmanager.viewer", .members = &.{"user:a@x.com"} }} });
        defer written.deinit();
        // No updateMask: the secret's audit configuration stays as it is.
        try h.expectRequest(1, .POST, base ++ ":setIamPolicy",
            \\{"policy":{"version":1,"etag":"ACAB","bindings":[{"role":"roles/secretmanager.viewer","members":["user:a@x.com"]}]}}
        );

        var granted = try db.addIamBinding("roles/secretmanager.secretAccessor", agent);
        defer granted.deinit();
        try testing.expect(granted.value.grants("roles/secretmanager.secretAccessor", agent));
        try h.expectRequest(3, .POST, base ++ ":setIamPolicy",
            \\{"policy":{"version":1,"etag":"BwX1","bindings":[{"role":"roles/secretmanager.viewer","members":["user:a@x.com"]},{"role":"roles/secretmanager.secretAccessor","members":["serviceAccount:service-82150720798@gs-project-accounts.iam.gserviceaccount.com"]}]}}
        );

        var revoked = try db.removeIamBinding("roles/secretmanager.secretAccessor", agent);
        defer revoked.deinit();
        try testing.expect(!revoked.value.grants("roles/secretmanager.secretAccessor", agent));
        try h.expectRequest(5, .POST, base ++ ":setIamPolicy",
            \\{"policy":{"version":1,"etag":"BwX2","bindings":[{"role":"roles/secretmanager.viewer","members":["user:a@x.com"]}]}}
        );

        var held = try db.testIamPermissions(&.{ "secretmanager.versions.access", "secretmanager.secrets.delete" });
        defer held.deinit();
        try testing.expectEqual(1, held.value.len);
        try h.expectRequest(6, .POST, base ++ ":testIamPermissions",
            \\{"permissions":["secretmanager.versions.access","secretmanager.secrets.delete"]}
        );
        try h.expectRequestCount(7);
    }
}

test "IAM on a secret: a condition is written as version 3, and a missing secret holds nothing" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = "{\"version\":3,\"etag\":\"BwX2\",\"bindings\":[{\"role\":\"roles/secretmanager.viewer\",\"members\":[\"user:a@x.com\"],\"condition\":{\"title\":\"t\",\"expression\":\"true\"}}]}" } },
        // Measured: a secret that does not exist answers {}.
        .{ .respond = .{ .body = "{}" } },
    }, .{});
    defer h.deinit();
    const db = h.client.secret("db");
    var written = try db.setIamPolicy(.{ .etag = "BwX1", .bindings = &.{.{ .role = "roles/secretmanager.viewer", .members = &.{"user:a@x.com"}, .condition = "{\"title\":\"t\",\"expression\":\"true\"}" }} });
    defer written.deinit();
    try testing.expectEqual(3, written.value.version);
    try h.expectRequest(0, .POST, "https://secretmanager.googleapis.com/v1/projects/extractctl/secrets/db:setIamPolicy",
        \\{"policy":{"version":3,"etag":"BwX1","bindings":[{"role":"roles/secretmanager.viewer","members":["user:a@x.com"],"condition":{"title":"t","expression":"true"}}]}}
    );
    var none = try h.client.secret("gone").testIamPermissions(&.{"secretmanager.secrets.get"});
    defer none.deinit();
    try testing.expectEqual(0, none.value.len);
}

test "IAM on a secret: refused before sending, and a grant that meets another change starts over after a wait" {
    {
        var h: Harness = undefined;
        try h.init(&.{}, .{});
        defer h.deinit();
        const db = h.client.secret("db");
        try testing.expectError(error.InvalidArgument, db.addIamBinding("secretmanager.secretAccessor", agent));
        try testing.expectError(error.InvalidArgument, db.addIamBinding("roles/secretmanager.secretAccessor", "serviceaccount:a@x.iam.gserviceaccount.com"));
        try testing.expectError(error.InvalidArgument, db.addIamBinding("roles/secretmanager.secretAccessor", "projectViewer:extractctl"));
        try testing.expectError(error.InvalidArgument, db.addIamBinding("roles/secretmanager.secretAccessor", "deleted:user:a@x.com?uid=1"));
        try testing.expectError(error.InvalidArgument, db.setIamPolicy(.{ .bindings = &.{.{ .role = "Roles/viewer", .members = &.{agent} }} }));
        try testing.expectError(error.InvalidArgument, db.testIamPermissions(&.{"secretmanager.*"}));
        try testing.expectError(error.InvalidArgument, db.testIamPermissions(&.{}));
        try testing.expectError(error.InvalidResourceId, h.client.secret("a/b").iamPolicy());
        try h.expectRequestCount(0);
    }
    {
        var h: Harness = undefined;
        try h.init(&.{
            .{ .respond = .{ .body = "{\"etag\":\"E1\"}" } },
            .{ .respond = .{ .status = 409, .body = aborted } },
            .{ .respond = .{ .body = "{\"etag\":\"E2\"}" } },
            .{ .respond = .{ .body = "{\"version\":1,\"etag\":\"E3\",\"bindings\":[{\"role\":\"roles/secretmanager.secretAccessor\",\"members\":[\"" ++ agent ++ "\"]}]}" } },
        }, .{});
        defer h.deinit();
        var granted = try h.client.secret("db").addIamBinding("roles/secretmanager.secretAccessor", agent);
        defer granted.deinit();
        try h.expectRequestCount(4);
        try testing.expectEqual(1, h.clock.sleep_count);
    }
    // A write without an etag, or with an empty one, is sent once.
    for ([_]?[]const u8{ null, "" }) |etag| {
        var h: Harness = undefined;
        try h.init(&.{.{ .respond = .{ .status = 503, .body = "{\"error\":{\"code\":503,\"status\":\"UNAVAILABLE\"}}" } }}, .{});
        defer h.deinit();
        try testing.expectError(error.Unavailable, h.client.secret("db").setIamPolicy(.{ .etag = etag }));
        try h.expectRequestCount(1);
    }
}

fn iamAllocations(gpa: std.mem.Allocator) !void {
    var fake: test_util.FakeTransport = .init(testing.allocator, &.{
        .{ .respond = .{ .body = "{\"etag\":\"ACAB\"}" } },
        .{ .respond = .{ .body = "{\"etag\":\"E1\"}" } },
        .{ .respond = .{ .status = 409, .body = aborted } },
        .{ .respond = .{ .body = "{\"etag\":\"E2\"}" } },
        .{ .respond = .{ .body = "{\"version\":1,\"etag\":\"E3\",\"bindings\":[{\"role\":\"roles/secretmanager.secretAccessor\",\"members\":[\"" ++ agent ++ "\"]}]}" } },
        .{ .respond = .{ .body = "{\"version\":1,\"etag\":\"E3\",\"bindings\":[{\"role\":\"roles/secretmanager.secretAccessor\",\"members\":[\"" ++ agent ++ "\"]}]}" } },
        .{ .respond = .{ .body = "{\"version\":1,\"etag\":\"E4\"}" } },
        .{ .respond = .{ .body = "{\"permissions\":[\"secretmanager.secrets.get\"]}" } },
    });
    defer fake.deinit();
    var clock: test_util.FakeClock = .{};
    var tokens: test_util.FakeTokenProvider = .{};
    var client = try Client.init(gpa, clock.io(), .{ .project_id = "extractctl", .location = "europe-west3", .token_provider = tokens.provider(), .transport = fake.transport() });
    defer client.deinit();
    const db = client.secret("db");
    var read = try db.iamPolicy();
    read.deinit();
    var granted = try db.addIamBinding("roles/secretmanager.secretAccessor", agent);
    granted.deinit();
    var revoked = try db.removeIamBinding("roles/secretmanager.secretAccessor", agent);
    revoked.deinit();
    var held = try db.testIamPermissions(&.{"secretmanager.secrets.get"});
    held.deinit();
}

test "IAM on a secret: every allocation failure is OutOfMemory without leaks" {
    try testing.checkAllAllocationFailures(test_util.no_grow_allocator, iamAllocations, .{});
}
