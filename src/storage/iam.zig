//! IAM on buckets: `GET b/{bucket}/iam`, `PUT b/{bucket}/iam`, which takes
//! the policy bare, and `GET b/{bucket}/iam/testPermissions`, through
//! `core.iam`. A billed handle's calls name its project, as every call
//! does.
//!
//! Measured in production on 2026-10-01:
//!
//! - A new bucket's policy holds four legacy bindings to `projectOwner:`,
//!   `projectEditor:` and `projectViewer:` the project's ID, at etag
//!   `CAE=`. The etag is the bucket's metageneration, so any bucket
//!   update, a label included, makes a policy read before it stale, and an
//!   IAM write moves the metageneration.
//! - A write under a stale etag is 412 `conditionNotMet`, "At least one of
//!   the pre-conditions you specified did not hold.", reported here as
//!   `error.Aborted`. The other two 412s an IAM write met stay
//!   `error.FailedPrecondition`: a condition on a bucket without uniform
//!   access, and `allUsers` or `allAuthenticatedUsers` under public access
//!   prevention. `If-Match` is ignored.
//! - A write without `bindings` removes every binding, the legacy ones too.
//! - A bucket takes only Cloud Storage's roles, and no basic role.
//! - `testIamPermissions` takes at most 84 permissions, none twice, only
//!   Cloud Storage's own, and not `storage.buckets.list` or
//!   `storage.buckets.create`, which belong to projects.
//! - fake-gcs-server has no IAM routes: every call is `error.NotFound`.

const std = @import("std");
const core = @import("core");

const Client = @import("Client.zig");
const idempotency = @import("idempotency.zig");
const names = @import("names.zig");
const rpc = @import("rpc.zig");
const types = @import("types.zig");
const Error = @import("errors.zig").Error;
const Policy = core.iam.Policy;

const mismatch = "At least one of the pre-conditions you specified did not hold.";

/// Whether a failed bucket IAM write was refused because the policy changed
/// since it was read: the one 412 of three whose message says so.
pub fn isConcurrentChange(err: anyerror, diag: *const core.Diagnostics) bool {
    return err == error.FailedPrecondition and std.mem.startsWith(u8, diag.message(), mismatch);
}

/// A bucket, as `core.iam.update` reads and writes its policy.
pub const Resource = struct {
    client: *Client,
    bucket: []const u8,

    pub fn readPolicy(r: Resource) Error!types.Owned(Policy) {
        var scratch: std.heap.ArenaAllocator = .init(r.client.gpa);
        defer scratch.deinit();
        const path = try names.bucketIamPath(scratch.allocator(), r.bucket, true);
        var result: types.Owned(Policy) = try .init(r.client.gpa);
        errdefer result.deinit();
        const body = try rpc.execute(r.client, result.arena, .{ .method = .GET, .path = path });
        return decoded(r.client, &result, body);
    }

    /// Writes `policy` whole. Retried only under an etag: a retry then
    /// fails cleanly, as `error.Aborted`, when the first attempt landed,
    /// where a policy written again blindly could undo a change made in
    /// between.
    pub fn writePolicy(r: Resource, policy: Policy) Error!types.Owned(Policy) {
        var scratch: std.heap.ArenaAllocator = .init(r.client.gpa);
        defer scratch.deinit();
        const a = scratch.allocator();
        const path = try names.bucketIamPath(a, r.bucket, false);
        const conditional = if (policy.etag) |etag| etag.len > 0 else false;
        var token: idempotency.Token = undefined;
        token.init(r.client);
        var result: types.Owned(Policy) = try .init(r.client.gpa);
        errdefer result.deinit();
        const body = try rpc.executeIamWrite(r.client, result.arena, .{
            .method = .PUT,
            .path = path,
            .body = try core.iam.encodePolicy(a, policy),
            .headers = token.slice(),
            .retry = conditional,
        });
        return decoded(r.client, &result, body);
    }
};

fn decoded(client: *Client, result: *types.Owned(Policy), body: []const u8) Error!types.Owned(Policy) {
    result.value = core.iam.decode(result.arena.allocator(), body) catch |err|
        return rpc.decodeFailed(client, err, "IAM policy");
    return result.*;
}

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

/// `addIamBinding` and `removeIamBinding`, after the checks: buckets alone
/// take `projectOwner:`, `projectEditor:` and `projectViewer:` members.
pub fn change(r: Resource, what: core.iam.Change) Error!types.Owned(Policy) {
    const c = r.client;
    const grant = switch (what) {
        inline else => |g| g,
    };
    if (core.iam.roleProblem(grant.role)) |problem| {
        if (c.diagnostics) |d| d.print("role \"{s}\": {s}", .{ grant.role, problem });
        return error.InvalidArgument;
    }
    if (core.iam.memberProblem(grant.member, .{ .project_values = true, .deleted = what == .revoke })) |problem| {
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
    for (permissions) |p| {
        if (std.mem.eql(u8, p, "storage.buckets.list") or std.mem.eql(u8, p, "storage.buckets.create")) {
            if (c.diagnostics) |d| d.print("{s} belongs to a project, not a bucket: Cloud Storage refuses it here", .{p});
            return error.InvalidArgument;
        }
    }
    var scratch: std.heap.ArenaAllocator = .init(c.gpa);
    defer scratch.deinit();
    const path = try names.bucketTestPermissionsPath(scratch.allocator(), r.bucket, permissions);
    var result: types.Owned([]const []const u8) = try .init(c.gpa);
    errdefer result.deinit();
    const body = try rpc.execute(c, result.arena, .{ .method = .GET, .path = path });
    result.value = core.iam.decodePermissions(result.arena.allocator(), body) catch |err|
        return rpc.decodeFailed(c, err, "testIamPermissions answer");
    return result;
}

const testing = std.testing;
const test_util = @import("test_util.zig");

const agent = "serviceAccount:service-82150720798@gs-project-accounts.iam.gserviceaccount.com";
const fresh =
    \\{"kind":"storage#policy","resourceId":"projects/_/buckets/b","version":1,"etag":"CAE=","bindings":[{"role":"roles/storage.legacyBucketOwner","members":["projectEditor:extractctl","projectOwner:extractctl"]},{"role":"roles/storage.legacyBucketReader","members":["projectViewer:extractctl"]},{"role":"roles/storage.legacyObjectOwner","members":["projectEditor:extractctl","projectOwner:extractctl"]},{"role":"roles/storage.legacyObjectReader","members":["projectViewer:extractctl"]}]}
;
const stale_body =
    \\{"error":{"code":412,"message":"At least one of the pre-conditions you specified did not hold.","errors":[{"message":"At least one of the pre-conditions you specified did not hold.","domain":"global","reason":"conditionNotMet"}]}}
;
const ubla_body =
    \\{"error":{"code":412,"message":"To set IAM conditions in this bucket, enable uniform bucket-level access.","errors":[{"message":"To set IAM conditions in this bucket, enable uniform bucket-level access.","domain":"global","reason":"conditionNotMet"}]}}
;
const pap_body =
    \\{"error":{"code":412,"message":"The member bindings allUsers and allAuthenticatedUsers are not allowed since public access prevention is enforced.","errors":[{"message":"The member bindings allUsers and allAuthenticatedUsers are not allowed since public access prevention is enforced.","domain":"global","reason":"conditionNotMet"}]}}
;

test "bucket IAM: the paths, the bare body with its token, and a billed handle's project" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = fresh } },
        .{ .respond = .{ .body = "{\"kind\":\"storage#policy\",\"version\":1,\"etag\":\"CAI=\",\"bindings\":[{\"role\":\"roles/storage.objectViewer\",\"members\":[\"" ++ agent ++ "\"]}]}" } },
        .{ .respond = .{ .body = "{\"kind\":\"storage#testIamPermissionsResponse\",\"permissions\":[\"storage.buckets.get\"]}" } },
        .{ .respond = .{ .body = fresh } },
        .{ .respond = .{ .body = fresh } },
    }, .{});
    defer h.deinit();
    const b = h.client.bucket("b");

    var read = try b.iamPolicy();
    defer read.deinit();
    try testing.expectEqual(4, read.value.bindings.len);
    try testing.expect(read.value.grants("roles/storage.legacyBucketOwner", "projectOwner:extractctl"));
    try h.expectRequest(0, .GET, "https://storage.googleapis.com/storage/v1/b/b/iam?optionsRequestedPolicyVersion=3", null);

    var written = try b.setIamPolicy(.{ .etag = "CAE=", .bindings = &.{.{ .role = "roles/storage.objectViewer", .members = &.{agent} }} });
    defer written.deinit();
    try testing.expectEqualStrings("CAI=", written.value.etag.?);
    try h.expectRequest(1, .PUT, "https://storage.googleapis.com/storage/v1/b/b/iam",
        \\{"version":1,"etag":"CAE=","bindings":[{"role":"roles/storage.objectViewer","members":["serviceAccount:service-82150720798@gs-project-accounts.iam.gserviceaccount.com"]}]}
    );
    // Every JSON API write carries its token.
    try testing.expect((try h.fake.request(1)).header("x-goog-gcs-idempotency-token") != null);

    var held = try b.testIamPermissions(&.{ "storage.buckets.get", "storage.objects.list" });
    defer held.deinit();
    try testing.expectEqual(1, held.value.len);
    try h.expectRequest(2, .GET, "https://storage.googleapis.com/storage/v1/b/b/iam/testPermissions?permissions=storage.buckets.get&permissions=storage.objects.list", null);

    var billed = try b.withBillingProject("payer").iamPolicy();
    defer billed.deinit();
    try h.expectRequest(3, .GET, "https://storage.googleapis.com/storage/v1/b/b/iam?optionsRequestedPolicyVersion=3&userProject=payer", null);
    try testing.expectEqualStrings("payer", (try h.fake.request(3)).header("x-goog-user-project").?);
    var billed_write = try b.withBillingProject("payer").setIamPolicy(.{ .etag = "CAE=" });
    defer billed_write.deinit();
    try h.expectRequest(4, .PUT, "https://storage.googleapis.com/storage/v1/b/b/iam?userProject=payer", "{\"version\":1,\"etag\":\"CAE=\",\"bindings\":[]}");
    try testing.expectEqualStrings("payer", (try h.fake.request(4)).header("x-goog-user-project").?);
}

test "bucket IAM: a client made for full control asks its token provider for that scope" {
    try testing.expectEqualStrings("https://www.googleapis.com/auth/devstorage.full_control", rpc.Scope.full_control.url());
    var fake: test_util.FakeTransport = .init(testing.allocator, &.{.{ .respond = .{ .body = fresh } }});
    defer fake.deinit();
    var clock: test_util.FakeClock = .{};
    var tokens: test_util.FakeTokenProvider = .{};
    var client = try Client.init(testing.allocator, clock.io(), .{ .token_provider = tokens.provider(), .transport = fake.transport(), .scope = .full_control });
    defer client.deinit();
    var read = try client.bucket("b").iamPolicy();
    defer read.deinit();
    try testing.expectEqualStrings("https://www.googleapis.com/auth/devstorage.full_control", tokens.firstScope());
}

test "bucket IAM: refused before sending: a role or member of no known form, a project's number, a deleted member granted, a project's permissions" {
    var h: test_util.Harness = undefined;
    try h.init(&.{}, .{});
    defer h.deinit();
    const b = h.client.bucket("b");
    try testing.expectError(error.InvalidArgument, b.addIamBinding("storage.objectViewer", agent));
    try testing.expectError(error.InvalidArgument, b.addIamBinding("roles/storage.objectViewer", "ServiceAccount:a@x.iam.gserviceaccount.com"));
    try testing.expectError(error.InvalidArgument, b.addIamBinding("roles/storage.objectViewer", "projectViewer:82150720798"));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "not its number") != null);
    try testing.expectError(error.InvalidArgument, b.addIamBinding("roles/storage.objectViewer", "deleted:user:a@x.com?uid=1"));
    try testing.expectError(error.InvalidArgument, b.setIamPolicy(.{ .bindings = &.{.{ .role = "", .members = &.{agent} }} }));
    try testing.expectError(error.InvalidArgument, b.testIamPermissions(&.{"storage.buckets.list"}));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "belongs to a project") != null);
    try testing.expectError(error.InvalidArgument, b.testIamPermissions(&.{"storage.buckets.create"}));
    try testing.expectError(error.InvalidArgument, b.testIamPermissions(&.{ "storage.buckets.get", "storage.buckets.get" }));
    try testing.expectError(error.InvalidArgument, b.testIamPermissions(&.{}));
    try testing.expectError(error.InvalidBucketName, h.client.bucket("").iamPolicy());
    try h.expectRequestCount(0);
}

test "bucket IAM: the stale etag's 412 is Aborted, and a grant starts over on it; the other two 412s are not" {
    {
        var h: test_util.Harness = undefined;
        try h.init(&.{
            .{ .respond = .{ .body = fresh } },
            .{ .respond = .{ .status = 412, .body = stale_body } },
            .{ .respond = .{ .body = fresh } },
            .{ .respond = .{ .body = "{\"version\":1,\"etag\":\"CAM=\",\"bindings\":[{\"role\":\"roles/storage.objectViewer\",\"members\":[\"" ++ agent ++ "\"]}]}" } },
        }, .{});
        defer h.deinit();
        var granted = try h.client.bucket("b").addIamBinding("roles/storage.objectViewer", agent);
        defer granted.deinit();
        try h.expectRequestCount(4);
        try testing.expectEqual(1, h.clock.sleep_count);
    }
    {
        var h: test_util.Harness = undefined;
        try h.init(&.{.{ .respond = .{ .status = 412, .body = stale_body } }}, .{});
        defer h.deinit();
        try testing.expectError(error.Aborted, h.client.bucket("b").setIamPolicy(.{ .etag = "CAE=" }));
        try h.expectRequestCount(1);
    }
    inline for (.{ ubla_body, pap_body }) |body| {
        var h: test_util.Harness = undefined;
        try h.init(&.{
            .{ .respond = .{ .body = fresh } },
            .{ .respond = .{ .status = 412, .body = body } },
        }, .{});
        defer h.deinit();
        try testing.expectError(error.FailedPrecondition, h.client.bucket("b").addIamBinding("roles/storage.objectViewer", "allUsers"));
        // Not a concurrent change: no second round.
        try h.expectRequestCount(2);
        try testing.expectEqualStrings("conditionNotMet", h.diag.status());
    }
    {
        // The same 412 on an object write stays a failed precondition.
        var h: test_util.Harness = undefined;
        try h.init(&.{.{ .respond = .{ .status = 412, .body = stale_body } }}, .{});
        defer h.deinit();
        try testing.expectError(error.FailedPrecondition, h.client.bucket("b").object("o").delete(.{ .generation = 1 }));
    }
    {
        // A write without an etag is sent once.
        var h: test_util.Harness = undefined;
        try h.init(&.{.{ .respond = .{ .status = 503, .body = "{\"error\":{\"code\":503,\"message\":\"x\"}}" } }}, .{});
        defer h.deinit();
        try testing.expectError(error.Unavailable, h.client.bucket("b").setIamPolicy(.{}));
        try h.expectRequestCount(1);
    }
}

const Fixture = struct {
    fake: test_util.FakeMultipart,
    token: core.StaticToken,
    diag: core.Diagnostics,
    client: Client,

    fn init(f: *Fixture) !void {
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
        errdefer f.client.deinit();
        var uniform = try f.client.bucket("zigps-iam").create(.{ .uniform_bucket_level_access = true, .public_access_prevention = .enforced });
        uniform.deinit();
        var fine = try f.client.bucket("zigps-iam-fine").create(.{});
        fine.deinit();
    }

    fn deinit(f: *Fixture) void {
        f.client.deinit();
        f.fake.deinit();
    }
};

test "bucket IAM against production's rules: legacy bindings, a grant once in any case, a revoke, conditions, and a bucket update in between" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const b = f.client.bucket("zigps-iam");

    var first = try b.iamPolicy();
    defer first.deinit();
    try testing.expectEqualStrings("CAE=", first.value.etag.?);
    try testing.expectEqual(4, first.value.bindings.len);
    // Without uniform access, two.
    var fine_first = try f.client.bucket("zigps-iam-fine").iamPolicy();
    defer fine_first.deinit();
    try testing.expectEqual(2, fine_first.value.bindings.len);

    var granted = try b.addIamBinding("roles/storage.objectViewer", agent);
    defer granted.deinit();
    try testing.expect(granted.value.grants("roles/storage.objectViewer", agent));
    const writes = f.fake.buckets.counts.iam_writes;
    // Asked in capitals: held already, nothing written.
    var again = try b.addIamBinding("roles/storage.objectViewer", "serviceAccount:SERVICE-82150720798@GS-PROJECT-ACCOUNTS.IAM.GSERVICEACCOUNT.COM");
    defer again.deinit();
    try testing.expectEqual(writes, f.fake.buckets.counts.iam_writes);
    var viewers = try b.addIamBinding("roles/storage.objectViewer", "projectViewer:extractctl");
    defer viewers.deinit();

    var held = try b.testIamPermissions(&.{ "storage.buckets.get", "storage.objects.list" });
    defer held.deinit();
    try testing.expectEqual(2, held.value.len);

    var revoked = try b.removeIamBinding("roles/storage.objectViewer", agent);
    defer revoked.deinit();
    try testing.expect(!revoked.value.grants("roles/storage.objectViewer", agent));
    try testing.expect(revoked.value.grants("roles/storage.objectViewer", "projectViewer:extractctl"));

    // A condition, written as version 3 by itself, kept as written.
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    var current = try b.iamPolicy();
    defer current.deinit();
    var with_condition = current.value;
    with_condition.bindings = try std.mem.concat(a, core.iam.Binding, &.{ current.value.bindings, &.{.{
        .role = "roles/storage.objectViewer",
        .members = &.{agent},
        .condition = "{\"title\":\"until 2030\",\"expression\":\"request.time < timestamp(\\\"2030-01-01T00:00:00Z\\\")\"}",
    }} });
    var conditioned = try b.setIamPolicy(with_condition);
    defer conditioned.deinit();
    try testing.expectEqual(3, conditioned.value.version);
    try testing.expect(conditioned.value.hasConditions());
    // A conditional grant is no grant to rely on.
    try testing.expect(!conditioned.value.grants("roles/storage.objectViewer", agent));

    // Any bucket update moves the etag: a policy read before it is stale.
    var before = try b.iamPolicy();
    defer before.deinit();
    var labelled = try b.update(.{ .labels = .{ .change = &.{.{ .key = "k", .value = "v" }} } });
    labelled.deinit();
    try testing.expectError(error.Aborted, b.setIamPolicy(before.value));
    // A grant reads again, so it lands.
    var after = try b.addIamBinding("roles/storage.objectCreator", agent);
    defer after.deinit();

    // Public access prevention, and a condition without uniform access:
    // each refused in its own words, and neither a concurrent change.
    try testing.expectError(error.FailedPrecondition, b.addIamBinding("roles/storage.objectViewer", "allUsers"));
    try testing.expect(std.mem.indexOf(u8, f.diag.message(), "public access prevention") != null);
    const fine = f.client.bucket("zigps-iam-fine");
    var fine_policy = try fine.iamPolicy();
    defer fine_policy.deinit();
    var fine_conditional = fine_policy.value;
    fine_conditional.bindings = try std.mem.concat(a, core.iam.Binding, &.{ fine_policy.value.bindings, &.{.{ .role = "roles/storage.objectViewer", .members = &.{agent}, .condition = "{\"title\":\"t\",\"expression\":\"true\"}" }} });
    try testing.expectError(error.FailedPrecondition, fine.setIamPolicy(fine_conditional));
    try testing.expect(std.mem.indexOf(u8, f.diag.message(), "uniform bucket-level access") != null);

    // Only Cloud Storage's roles.
    try testing.expectError(error.InvalidArgument, b.addIamBinding("roles/pubsub.publisher", agent));
    try testing.expectEqualStrings("Role roles/pubsub.publisher is not supported for this resource.", f.diag.message());

    // A write with no bindings removes every one, the legacy ones too.
    var last = try b.iamPolicy();
    defer last.deinit();
    var emptied = try b.setIamPolicy(.{ .etag = last.value.etag, .bindings = &.{} });
    defer emptied.deinit();
    try testing.expectEqual(0, emptied.value.bindings.len);

    try testing.expectError(error.NotFound, f.client.bucket("zigps-gone").iamPolicy());
    try testing.expectError(error.NotFound, f.client.bucket("zigps-gone").testIamPermissions(&.{"storage.buckets.get"}));
}

fn iamAllocations(gpa: std.mem.Allocator) !void {
    var fake: test_util.FakeTransport = .init(testing.allocator, &.{
        .{ .respond = .{ .body = fresh } },
        .{ .respond = .{ .body = fresh } },
        .{ .respond = .{ .status = 412, .body = stale_body } },
        .{ .respond = .{ .body = fresh } },
        .{ .respond = .{ .body = "{\"version\":1,\"etag\":\"CAM=\",\"bindings\":[{\"role\":\"roles/storage.objectViewer\",\"members\":[\"" ++ agent ++ "\"]}]}" } },
        .{ .respond = .{ .body = "{\"version\":1,\"etag\":\"CAM=\",\"bindings\":[{\"role\":\"roles/storage.objectViewer\",\"members\":[\"" ++ agent ++ "\"]}]}" } },
        .{ .respond = .{ .body = "{\"version\":1,\"etag\":\"CAQ=\"}" } },
        .{ .respond = .{ .body = "{\"kind\":\"storage#testIamPermissionsResponse\",\"permissions\":[\"storage.buckets.get\"]}" } },
    });
    defer fake.deinit();
    var clock: test_util.FakeClock = .{};
    var token: core.StaticToken = .{ .token = "ya29.t" };
    var client = try Client.init(gpa, clock.io(), .{ .token_provider = token.provider(), .transport = fake.transport() });
    defer client.deinit();
    const b = client.bucket("b").withBillingProject("payer");
    var read = try b.iamPolicy();
    read.deinit();
    var granted = try b.addIamBinding("roles/storage.objectViewer", agent);
    granted.deinit();
    var revoked = try b.removeIamBinding("roles/storage.objectViewer", agent);
    revoked.deinit();
    var held = try b.testIamPermissions(&.{"storage.buckets.get"});
    held.deinit();
}

test "bucket IAM: every allocation failure is OutOfMemory without leaks" {
    try testing.checkAllAllocationFailures(testing.allocator, iamAllocations, .{});
}

fn iamModelProperty(_: void, bytes: []const u8) !void {
    var g: test_util.ByteGen = .init(bytes);
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const b = f.client.bucket("zigps-iam");
    const roles = [_][]const u8{ "roles/storage.objectViewer", "roles/storage.objectCreator", "roles/storage.legacyBucketReader" };
    const members = [_][]const u8{ agent, "serviceAccount:SERVICE-82150720798@gs-project-accounts.iam.gserviceaccount.com", "user:a@example.com", "group:Team@example.com", "projectViewer:extractctl" };
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    for (0..g.intRange(u8, 1, 8)) |_| {
        const role = g.pick([]const u8, &roles);
        const member = g.pick([]const u8, &members);
        switch (g.intRange(u8, 0, 3)) {
            0 => {
                var p = try b.addIamBinding(role, member);
                defer p.deinit();
                try testing.expect(p.value.grants(role, member));
            },
            1 => {
                var p = try b.removeIamBinding(role, member);
                defer p.deinit();
                try testing.expect(!p.value.grants(role, member));
            },
            2 => {
                // Another writer's bucket update between a read and a write.
                var read = try b.iamPolicy();
                defer read.deinit();
                var labelled = try b.update(.{ .labels = .{ .change = &.{.{ .key = "n", .value = "1" }} } });
                labelled.deinit();
                const next = try core.iam.withMember(scratch.allocator(), read.value, role, member);
                if (b.setIamPolicy(next)) |written| {
                    var w = written;
                    w.deinit();
                    // Only a write that changes nothing... is still refused: the etag moved.
                    return error.TestExpectedAborted;
                } else |err| try testing.expectEqual(error.Aborted, err);
            },
            else => {
                var held = try b.testIamPermissions(&.{"storage.objects.get"});
                held.deinit();
            },
        }
        // Never an empty binding, nor a member twice in one, and the
        // legacy owners kept by every grant and revoke of other roles.
        var now = try b.iamPolicy();
        defer now.deinit();
        try testing.expect(now.value.grants("roles/storage.legacyBucketOwner", "projectOwner:extractctl"));
        for (now.value.bindings) |binding| {
            try testing.expect(binding.members.len > 0);
            for (binding.members, 0..) |m, i| for (binding.members[0..i]) |o| try testing.expect(!core.iam.sameMember(m, o));
        }
    }
}

test "heavy property iam on buckets: grants and revokes land as asked, a stale write is Aborted, and the legacy owners stay" {
    try test_util.fuzzBytes({}, iamModelProperty, .{ .corpus = &.{ "", "\x01" ** 64, "\x00\x01\x02\x03\x04" ** 20 } });
}
