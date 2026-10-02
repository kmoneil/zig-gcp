//! A handle for one secret. Cheap: a client pointer and an id. Creating one
//! sends nothing, and the handle borrows both, so it must outlive neither.

const Secret = @This();

const std = @import("std");
const core = @import("core");

const Client = @import("Client.zig");
const SecretValue = @import("SecretValue.zig");
const Version = @import("Version.zig");
const codec = @import("codec.zig");
const errors = @import("errors.zig");
const iam = @import("iam.zig");
const logging = @import("logging.zig");
const names = @import("names.zig");
const rpc = @import("rpc.zig");
const types = @import("types.zig");
const validate = @import("validate.zig");
const Error = errors.Error;

client: *Client,
/// The secret's id, such as `db-password`. The library builds the full
/// resource name, with or without the client's location.
id: []const u8,

/// A handle for one of this secret's versions. Sends nothing.
pub fn version(self: Secret, ref: types.VersionRef) Version {
    return .{ .client = self.client, .secret_id = self.id, .ref = ref };
}

/// Fetches the bytes of one version. Shorthand for
/// `self.version(ref).access()`; the caller owns the result and must
/// `deinit` it, which wipes the bytes.
pub fn access(self: Secret, ref: types.VersionRef) Error!SecretValue {
    return self.version(ref).access();
}

/// Creates this secret, which holds no versions until `addVersion` adds one.
///
/// A global secret names its replication, which is immutable afterwards. A
/// regional client sends none: the client's location decides, and `config`'s
/// replication is ignored.
///
/// Topics are checked by publishing to each, before anything else: one
/// Secret Manager's service agent cannot publish to is
/// `error.TopicNotPublishable`, and nothing is created.
pub fn create(self: Secret, config: types.SecretConfig) Error!types.Owned(types.SecretInfo) {
    const c = self.client;
    rpc.begin(c);
    try rpc.checkSecretId(c, self.id);
    try rpc.checkConfig(c, config);

    var scratch: std.heap.ArenaAllocator = .init(c.gpa);
    defer scratch.deinit();
    const path = try names.createPath(scratch.allocator(), c.parent(), self.id);
    const body = try codec.encodeSecret(scratch.allocator(), config, c.location != null);

    var result: types.Owned(types.SecretInfo) = try .init(c.gpa);
    errdefer result.deinit();
    const response = try rpc.executeMapped(c, result.arena, .{ .method = .POST, .path = path, .body = body }, .{
        .topics = config.topics.len > 0,
        // Secret Manager checks a key, and its grant, before it creates
        // anything.
        .keys = config.kms_key != null or switch (config.replication) {
            .automatic => false,
            .user_managed => |replicas| replicas.len > 0 and replicas[0].kms_key != null,
        },
    });
    result.value = codec.decodeSecret(result.arena.allocator(), response) catch |err|
        return rpc.decodeFailed(c, err, "secret");
    return result;
}

/// Changes this secret's settings and returns it as it then is.
///
/// Every field of `changes` left at `.keep` stays as it is, and at least
/// one must change. A list is replaced whole, since the server keeps
/// nothing of the old one: to change one label, read the secret, change
/// the list, and set it, with the etag the read returned so that a change
/// made in between is `error.Aborted` rather than lost. With no etag the
/// update is plain, and safe to retry. With one, a retry whose first
/// attempt landed reports `error.Aborted` too: read the secret again.
///
/// Refused before sending, as `error.InvalidArgument`: an update that
/// changes nothing (the server would move the etag and publish an event
/// for it), and labels, annotations, aliases, an expiry, a delay, topics or
/// a rotation outside the rules on their types, a rotation set beside no
/// topics included. An alias naming a version the secret does not have,
/// and a rotation left without topics, are the server's
/// `error.InvalidArgument`; a topic Secret Manager cannot publish to, when
/// the update names topics, is `error.TopicNotPublishable`.
pub fn update(self: Secret, changes: types.SecretUpdate) Error!types.Owned(types.SecretInfo) {
    const c = self.client;
    rpc.begin(c);
    try rpc.checkSecretId(c, self.id);
    try rpc.checkUpdate(c, changes);

    var scratch: std.heap.ArenaAllocator = .init(c.gpa);
    defer scratch.deinit();
    const regional = c.location != null;
    const mask = try codec.updateMask(scratch.allocator(), changes, regional);
    const path = try names.updatePath(scratch.allocator(), c.parent(), self.id, mask);
    const body = try codec.encodeUpdate(scratch.allocator(), changes, regional);

    var result: types.Owned(types.SecretInfo) = try .init(c.gpa);
    errdefer result.deinit();
    const response = try rpc.executeMapped(c, result.arena, .{ .method = .PATCH, .path = path, .body = body }, .{
        .stale_etag = changes.etag != null,
        // Secret Manager checks every topic an update names, by publishing
        // to it, and only then; and a key it names, likewise.
        .topics = changes.topics == .set,
        .keys = changes.kms_key == .set or changes.replica_keys != null,
    });
    result.value = codec.decodeSecret(result.arena.allocator(), response) catch |err|
        return rpc.decodeFailed(c, err, "secret");
    return result;
}

/// This secret's metadata: when it was created, its labels and its etag.
/// Nothing about its versions, and none of its bytes.
pub fn get(self: Secret) Error!types.Owned(types.SecretInfo) {
    const c = self.client;
    rpc.begin(c);
    try rpc.checkSecretId(c, self.id);

    var scratch: std.heap.ArenaAllocator = .init(c.gpa);
    defer scratch.deinit();
    const path = try names.secretPath(scratch.allocator(), c.parent(), self.id, "");

    var result: types.Owned(types.SecretInfo) = try .init(c.gpa);
    errdefer result.deinit();
    const body = try rpc.execute(c, result.arena, .{ .method = .GET, .path = path });
    result.value = codec.decodeSecret(result.arena.allocator(), body) catch |err|
        return rpc.decodeFailed(c, err, "secret");
    return result;
}

/// Deletes this secret and every version of it. There is no undo.
///
/// A delete whose answer was lost and then retried reports `NotFound`, since
/// the first attempt had already succeeded.
pub fn delete(self: Secret) Error!void {
    const c = self.client;
    rpc.begin(c);
    try rpc.checkSecretId(c, self.id);

    var scratch: std.heap.ArenaAllocator = .init(c.gpa);
    defer scratch.deinit();
    const path = try names.secretPath(scratch.allocator(), c.parent(), self.id, "");
    return rpc.executeDiscard(c, .{ .method = .DELETE, .path = path });
}

/// Deletes this secret and every version of it, only if its etag is still
/// `etag`, as a read returned it: a secret changed since is
/// `error.Aborted`, and stays. A retry whose first attempt landed reports
/// `error.NotFound`.
pub fn deleteIf(self: Secret, etag: []const u8) Error!void {
    const c = self.client;
    rpc.begin(c);
    try rpc.checkSecretId(c, self.id);
    try rpc.checkEtag(c, etag);

    var scratch: std.heap.ArenaAllocator = .init(c.gpa);
    defer scratch.deinit();
    const path = try names.deletePath(scratch.allocator(), c.parent(), self.id, etag);
    return rpc.executeDiscardConditional(c, .{ .method = .DELETE, .path = path });
}

/// The secret's IAM policy, asked for as version 3, conditional bindings
/// included. A fresh secret's is empty, with the etag "ACAB". Its
/// versions' permissions follow it. Needs
/// `secretmanager.secrets.getIamPolicy`.
pub fn iamPolicy(self: Secret) Error!types.Owned(core.iam.Policy) {
    const r = try self.iamResource();
    return r.readPolicy();
}

/// Writes `policy` as the secret's, whole, and returns it as stored. Pass
/// a policy `iamPolicy` read, changed: its etag makes the write fail with
/// `error.Aborted` if the policy changed since, rather than undo that
/// change. A write that carries an etag is retried; one whose first answer
/// was lost then reports `error.Aborted` although it landed, so read the
/// policy again. One without an etag is sent once. No `updateMask` is
/// sent, so the secret's audit configuration, which `core.iam.Policy`
/// does not hold, stays as it is. A policy with a condition is written as
/// version 3. Needs `secretmanager.secrets.setIamPolicy`.
pub fn setIamPolicy(self: Secret, policy: core.iam.Policy) Error!types.Owned(core.iam.Policy) {
    const r = try self.iamResource();
    return iam.set(r, policy);
}

/// Grants `member` the role `role` on the secret, such as
/// `roles/secretmanager.secretAccessor`, which reads its versions' bytes,
/// unless it holds it already without a condition, and returns the policy
/// as it then is. It reads the policy, adds the member, and writes it back
/// under the read's etag, starting over after a jittered wait when another
/// change came in between, up to the retry policy's attempts. Members
/// compare as Secret Manager stores them, the address of a `user:`,
/// `serviceAccount:`, `group:` or `domain:` member in any case. Needs
/// `secretmanager.secrets.getIamPolicy` and `setIamPolicy`.
pub fn addIamBinding(self: Secret, role: []const u8, member: []const u8) Error!types.Owned(core.iam.Policy) {
    const r = try self.iamResource();
    return iam.change(r, .{ .grant = .{ .role = role, .member = member } });
}

/// Takes `member` out of the secret's binding of `role` without a
/// condition, unless it is not there, and returns the policy as it then
/// is, the same way `addIamBinding` grants.
pub fn removeIamBinding(self: Secret, role: []const u8, member: []const u8) Error!types.Owned(core.iam.Policy) {
    const r = try self.iamResource();
    return iam.change(r, .{ .revoke = .{ .role = role, .member = member } });
}

/// The permissions the caller holds on the secret, of `permissions`: 1 to
/// 100 of Secret Manager's own, such as `secretmanager.versions.access`.
/// On a secret that does not exist, none is held: an empty list, where a
/// missing topic or bucket is `error.NotFound`. Meant for building
/// permission-aware tools, not for authorization checks.
pub fn testIamPermissions(self: Secret, permissions: []const []const u8) Error!types.Owned([]const []const u8) {
    const r = try self.iamResource();
    return iam.testPermissions(r, permissions);
}

fn iamResource(self: Secret) Error!iam.Resource {
    const c = self.client;
    rpc.begin(c);
    try rpc.checkSecretId(c, self.id);
    return .{ .client = c, .id = self.id };
}

/// One page of this secret's versions, newest first.
pub fn listVersions(self: Secret, options: types.ListOptions) Error!types.Owned(types.VersionPage) {
    const c = self.client;
    rpc.begin(c);
    try rpc.checkSecretId(c, self.id);

    var scratch: std.heap.ArenaAllocator = .init(c.gpa);
    defer scratch.deinit();
    const path = try names.versionsPath(scratch.allocator(), c.parent(), self.id, options);

    var result: types.Owned(types.VersionPage) = try .init(c.gpa);
    errdefer result.deinit();
    const body = try rpc.execute(c, result.arena, .{ .method = .GET, .path = path });
    result.value = codec.decodeVersionPage(result.arena.allocator(), body) catch |err|
        return rpc.decodeFailed(c, err, "version list");
    return result;
}

/// Stores `data` as a new version and returns what the server made of it.
///
/// `data` is borrowed: the only copy this library makes is the base64 in the
/// request body, which is wiped before the call returns. Wiping the caller's
/// own copy is the caller's business. A CRC-32C of the raw bytes travels
/// with them, so the server refuses anything that arrives changed. On a
/// secret with a Cloud KMS key whose primary version is disabled, or that
/// the service agent may not use, it is `error.KeyUnavailable`.
pub fn addVersion(self: Secret, data: []const u8) Error!types.Owned(types.VersionInfo) {
    const c = self.client;
    rpc.begin(c);
    try rpc.checkSecretId(c, self.id);
    if (data.len == 0) {
        // The server refuses this too; refusing here saves a round trip.
        if (c.diagnostics) |d| d.print("a version needs at least one byte", .{});
        return error.EmptyPayload;
    }
    if (data.len > validate.max_payload_bytes) {
        if (c.diagnostics) |d| d.print(
            "a version holds at most {d} bytes, counted before base64",
            .{validate.max_payload_bytes},
        );
        return error.PayloadTooLarge;
    }

    // The body carries the secret in base64, so it is built in a wiping
    // arena that is released before this call returns, on every path.
    var wiping: core.WipingAllocator = .init(c.gpa);
    var scratch: std.heap.ArenaAllocator = .init(wiping.allocator());
    defer scratch.deinit();
    const path = try names.secretPath(scratch.allocator(), c.parent(), self.id, ":addVersion");
    const body = try codec.encodeAddVersion(scratch.allocator(), data, core.crc32c.hash(data));

    var result: types.Owned(types.VersionInfo) = try .init(c.gpa);
    errdefer result.deinit();
    const response = try rpc.executeMapped(c, result.arena, .{
        .method = .POST,
        .path = path,
        .body = body,
        // A retry can store the same bytes twice; the client's option says
        // whether that is better than losing them.
        .retry = c.retry_add_version,
        .wipe = true,
    }, .{ .keys = true });
    result.value = codec.decodeVersion(result.arena.allocator(), response) catch |err|
        return rpc.decodeFailed(c, err, "version");
    if (!result.value.client_specified_payload_checksum) {
        logging.warn("{s} stored the version without the checksum sent with it", .{path});
    }
    return result;
}

const testing = std.testing;
const test_util = @import("test_util.zig");
const Harness = test_util.Harness;
const Reply = test_util.FakeTransport.Reply;

const version_1: Reply = .{ .respond = .{ .body =
    \\{"name":"projects/82150720798/secrets/db-password/versions/1",
    \\ "createTime":"2026-09-20T23:09:39.716394Z","state":"ENABLED",
    \\ "etag":"\"165bf23a79782f\"","clientSpecifiedPayloadChecksum":true}
} };

test "golden: addVersion sends the payload and its checksum" {
    var h: Harness = undefined;
    try h.init(&.{version_1}, .{});
    defer h.deinit();

    var added = try h.client.secret("db-password").addVersion("s3cr3t");
    defer added.deinit();
    try h.expectRequest(
        0,
        .POST,
        "https://secretmanager.googleapis.com/v1/projects/extractctl/secrets/db-password:addVersion",
        "{\"payload\":{\"data\":\"czNjcjN0\",\"dataCrc32c\":\"825573743\"}}",
    );
    try testing.expectEqual(1, added.value.number().?);
    try testing.expectEqual(.enabled, added.value.state);
    try testing.expect(added.value.client_specified_payload_checksum);
}

test "golden: addVersion on a regional secret" {
    var h: Harness = undefined;
    try h.init(&.{version_1}, .{ .location = "europe-west3" });
    defer h.deinit();
    var added = try h.client.secret("db-password").addVersion("s3cr3t");
    defer added.deinit();
    try h.expectRequest(
        0,
        .POST,
        "https://secretmanager.europe-west3.rep.googleapis.com/v1/projects/extractctl/locations/europe-west3/secrets/db-password:addVersion",
        "{\"payload\":{\"data\":\"czNjcjN0\",\"dataCrc32c\":\"825573743\"}}",
    );
}

test "limits: an empty payload and one byte too many are refused before sending" {
    var h: Harness = undefined;
    try h.init(&.{version_1}, .{});
    defer h.deinit();

    try testing.expectError(error.EmptyPayload, h.client.secret("db-password").addVersion(""));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "at least one byte") != null);

    const too_big = try testing.allocator.alloc(u8, validate.max_payload_bytes + 1);
    defer testing.allocator.free(too_big);
    @memset(too_big, 'x');
    try testing.expectError(error.PayloadTooLarge, h.client.secret("db-password").addVersion(too_big));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "65536") != null);
    try h.expectRequestCount(0);

    // Production stores exactly 65,536 bytes and refuses one more, so the
    // limit itself goes out.
    const at_limit = too_big[0..validate.max_payload_bytes];
    var added = try h.client.secret("db-password").addVersion(at_limit);
    defer added.deinit();
    const sent = try h.fake.request(0);
    try testing.expectEqual(codec.addVersionBodyLen(at_limit, core.crc32c.hash(at_limit)), sent.body.?.len);
}

test "a bad secret id is refused, and the server's refusals come back" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .status = 400, .body = "{\"error\":{\"status\":\"INVALID_ARGUMENT\",\"message\":\"Provided SecretPayload.data crc32c does not match calculated crc32c.\"}}" } },
    }, .{});
    defer h.deinit();

    try testing.expectError(error.InvalidResourceId, h.client.secret("db.password").addVersion("s3cr3t"));
    try h.expectRequestCount(0);
    // The server checks the checksum too, and says so when it does not match.
    try testing.expectError(error.InvalidArgument, h.client.secret("db-password").addVersion("s3cr3t"));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "crc32c does not match") != null);
}

test "retry_add_version decides whether a lost answer is asked again" {
    const unavailable: Reply = .{ .respond = .{ .status = 503, .body = "{\"error\":{\"status\":\"UNAVAILABLE\"}}" } };
    {
        var h: Harness = undefined;
        try h.init(&.{ unavailable, version_1 }, .{});
        defer h.deinit();
        var added = try h.client.secret("db-password").addVersion("s3cr3t");
        defer added.deinit();
        try h.expectRequestCount(2);
    }
    {
        var h: Harness = undefined;
        try h.init(&.{ unavailable, version_1 }, .{});
        defer h.deinit();
        h.client.retry_add_version = false;
        try testing.expectError(error.Unavailable, h.client.secret("db-password").addVersion("s3cr3t"));
        try h.expectRequestCount(1);
    }
}

test "the server ignoring the checksum is worth a warning" {
    logging.capture.reset();
    var h: Harness = undefined;
    try h.init(&.{.{ .respond = .{ .body = "{\"name\":\"v/1\",\"state\":\"ENABLED\"}" } }}, .{});
    defer h.deinit();
    var added = try h.client.secret("db-password").addVersion("s3cr3t");
    defer added.deinit();
    try testing.expect(!added.value.client_specified_payload_checksum);
    try testing.expect(std.mem.indexOf(u8, logging.capture.text(), "without the checksum sent with it") != null);
}

test "no copy of the payload outlives the call" {
    const marker = "S3CR3T-payload";
    const encoded = test_util.encoded(marker);
    var backing: [256 * 1024]u8 = @splat(0);
    var fba: std.heap.FixedBufferAllocator = .init(&backing);
    var fake: test_util.FakeTransport = .init(testing.allocator, &.{
        version_1,
        .{ .respond = .{ .status = 403, .body = "{\"error\":{\"status\":\"PERMISSION_DENIED\"}}" } },
        .{ .fail = error.ConnectionResetByPeer },
    });
    defer fake.deinit();
    var clock: test_util.FakeClock = .{};
    var token: test_util.FakeTokenProvider = .{ .token = "ya29.token-that-must-not-linger" };
    var client = try Client.init(fba.allocator(), clock.io(), .{
        .project_id = "extractctl",
        .token_provider = token.provider(),
        .retry = .{ .max_attempts = 1 },
        .transport = fake.transport(),
    });
    defer client.deinit();

    // After a success, after an HTTP error and after a transport error: the
    // base64 the body carried is gone every time, and so is the token.
    var added = try client.secret("db-password").addVersion(marker);
    added.deinit();
    try testing.expectEqual(null, std.mem.indexOf(u8, &backing, encoded));
    try testing.expectEqual(null, std.mem.indexOf(u8, &backing, token.token));

    try testing.expectError(error.PermissionDenied, client.secret("db-password").addVersion(marker));
    try testing.expectEqual(null, std.mem.indexOf(u8, &backing, encoded));

    try testing.expectError(error.ConnectionResetByPeer, client.secret("db-password").addVersion(marker));
    try testing.expectEqual(null, std.mem.indexOf(u8, &backing, encoded));
    try testing.expectEqual(null, std.mem.indexOf(u8, &backing, token.token));
}

test "log hygiene: addVersion logs no payload, size or checksum" {
    logging.capture.reset();
    var h: Harness = undefined;
    try h.init(&.{version_1}, .{});
    defer h.deinit();
    var added = try h.client.secret("db-password").addVersion("s3cr3t");
    defer added.deinit();

    const log = logging.capture.text();
    for ([_][]const u8{ "s3cr3t", "czNjcjN0", "825573743", "ya29" }) |forbidden| {
        if (std.mem.indexOf(u8, log, forbidden) != null) {
            std.debug.print("log leaked \"{s}\":\n{s}\n", .{ forbidden, log });
            return error.TestLeakedSecret;
        }
    }
    try testing.expect(std.mem.indexOf(u8, log, ":addVersion -> 200") != null);
}

test "addVersion: every allocation failure is OutOfMemory without leaks" {
    const Run = struct {
        fn run(gpa: std.mem.Allocator) !void {
            var fake: test_util.FakeTransport = .init(testing.allocator, &.{version_1});
            defer fake.deinit();
            var clock: test_util.FakeClock = .{};
            var token: test_util.FakeTokenProvider = .{ .quota_project = "billing-project" };
            var client = try Client.init(gpa, clock.io(), .{
                .project_id = "extractctl",
                .token_provider = token.provider(),
                .transport = fake.transport(),
            });
            defer client.deinit();
            var added = try client.secret("db-password").addVersion("s3cr3t");
            added.deinit();
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Run.run, .{});
}

const created_secret: Reply = .{ .respond = .{ .body =
    \\{"name":"projects/82150720798/secrets/db-password",
    \\ "replication":{"automatic":{}},
    \\ "createTime":"2026-09-20T23:10:15.057958Z",
    \\ "labels":{"zig-gcp-test":"1"},
    \\ "etag":"\"165bf23c7b1c62\""}
} };

test "golden: create, global and regional" {
    var h: Harness = undefined;
    try h.init(&.{ created_secret, created_secret, created_secret }, .{});
    defer h.deinit();

    var created = try h.client.secret("db-password").create(.{});
    defer created.deinit();
    try h.expectRequest(
        0,
        .POST,
        "https://secretmanager.googleapis.com/v1/projects/extractctl/secrets?secretId=db-password",
        "{\"replication\":{\"automatic\":{}}}",
    );
    try testing.expectEqualStrings("db-password", created.value.id());
    try testing.expectEqualStrings("1", created.value.label("zig-gcp-test").?);

    var labelled = try h.client.secret("db-password").create(.{
        .labels = &.{.{ .key = "zig-gcp-test", .value = "1" }},
        .replication = .{ .user_managed = &.{ .{ .location = "europe-west1" }, .{ .location = "us-east1" } } },
    });
    defer labelled.deinit();
    try h.expectRequest(
        1,
        .POST,
        "https://secretmanager.googleapis.com/v1/projects/extractctl/secrets?secretId=db-password",
        "{\"replication\":{\"userManaged\":{\"replicas\":[{\"location\":\"europe-west1\"},{\"location\":\"us-east1\"}]}},\"labels\":{\"zig-gcp-test\":\"1\"}}",
    );

    var regional: Harness = undefined;
    try regional.init(&.{created_secret}, .{ .location = "europe-west3" });
    defer regional.deinit();
    // A regional create sends no replication, whatever the config says.
    var there = try regional.client.secret("db-password").create(.{
        .replication = .{ .user_managed = &.{.{ .location = "europe-west1" }} },
    });
    defer there.deinit();
    try regional.expectRequest(
        0,
        .POST,
        "https://secretmanager.europe-west3.rep.googleapis.com/v1/projects/extractctl/locations/europe-west3/secrets?secretId=db-password",
        "{}",
    );
}

test "golden: get, delete and listVersions" {
    var h: Harness = undefined;
    try h.init(&.{
        created_secret,
        .{ .respond = .{ .body = "{}" } },
        .{ .respond = .{ .body =
        \\{"versions":[{"name":"projects/1/secrets/db-password/versions/2","state":"ENABLED"},
        \\ {"name":"projects/1/secrets/db-password/versions/1","state":"DESTROYED","destroyTime":"2026-09-20T23:09:41.5Z"}],
        \\ "nextPageToken":"tok","totalSize":2}
        } },
    }, .{});
    defer h.deinit();

    var got = try h.client.secret("db-password").get();
    defer got.deinit();
    try h.expectRequest(0, .GET, "https://secretmanager.googleapis.com/v1/projects/extractctl/secrets/db-password", null);

    try h.client.secret("db-password").delete();
    try h.expectRequest(1, .DELETE, "https://secretmanager.googleapis.com/v1/projects/extractctl/secrets/db-password", null);

    var versions = try h.client.secret("db-password").listVersions(.{ .page_size = 2 });
    defer versions.deinit();
    try h.expectRequest(
        2,
        .GET,
        "https://secretmanager.googleapis.com/v1/projects/extractctl/secrets/db-password/versions?pageSize=2",
        null,
    );
    try testing.expectEqual(2, versions.value.versions.len);
    try testing.expectEqual(2, versions.value.versions[0].number().?);
    try testing.expectEqual(.destroyed, versions.value.versions[1].state);
    try testing.expectEqualStrings("2026-09-20T23:09:41.5Z", versions.value.versions[1].destroy_time);
    try testing.expectEqualStrings("tok", versions.value.next_page_token.?);
    try testing.expectEqual(2, versions.value.total_size);
}

test "create: what the server refuses, and what never reaches it" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .status = 409, .body = "{\"error\":{\"status\":\"ALREADY_EXISTS\",\"message\":\"Secret [projects/1/secrets/db-password] already exists.\"}}" } },
        .{ .respond = .{ .status = 404, .body = "{\"error\":{\"status\":\"NOT_FOUND\",\"message\":\"Secret [projects/1/secrets/gone] not found.\"}}" } },
    }, .{});
    defer h.deinit();

    try testing.expectError(error.AlreadyExists, h.client.secret("db-password").create(.{}));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "already exists") != null);
    // A delete whose first attempt got through reports NotFound on the retry.
    try testing.expectError(error.NotFound, h.client.secret("gone").delete());

    // A label that is not UTF-8 would be copied into the body as broken
    // JSON, so it never gets that far.
    try testing.expectError(error.InvalidArgument, h.client.secret("db-password").create(.{
        .labels = &.{.{ .key = "team", .value = "pay\xffments" }},
    }));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "valid UTF-8") != null);
    try testing.expectError(error.InvalidArgument, h.client.secret("db-password").create(.{
        .replication = .{ .user_managed = &.{} },
    }));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "at least one location") != null);
    try testing.expectError(error.InvalidLocation, h.client.secret("db-password").create(.{
        .replication = .{ .user_managed = &.{.{ .location = "Europe-West1" }} },
    }));
    try testing.expectError(error.InvalidResourceId, h.client.secret("db.password").create(.{}));
    try testing.expectError(error.InvalidResourceId, h.client.secret("").get());
    try testing.expectError(error.InvalidResourceId, h.client.secret("a/b").delete());
    try h.expectRequestCount(2);
}

test "secret administration: every allocation failure is OutOfMemory without leaks" {
    const Run = struct {
        fn run(gpa: std.mem.Allocator) !void {
            var fake: test_util.FakeTransport = .init(testing.allocator, &.{
                created_secret,
                created_secret,
                .{ .respond = .{ .body = "{\"secrets\":[{\"name\":\"projects/1/secrets/a\",\"labels\":{\"k\":\"v\"}}],\"nextPageToken\":\"t\"}" } },
                .{ .respond = .{ .body = "{\"versions\":[{\"name\":\"projects/1/secrets/a/versions/1\",\"state\":\"ENABLED\"}]}" } },
                .{ .respond = .{ .body = "{}" } },
            });
            defer fake.deinit();
            var clock: test_util.FakeClock = .{};
            var token: test_util.FakeTokenProvider = .{ .quota_project = "billing-project" };
            var client = try Client.init(gpa, clock.io(), .{
                .project_id = "extractctl",
                .token_provider = token.provider(),
                .transport = fake.transport(),
            });
            defer client.deinit();

            const secret = client.secret("db-password");
            var created = try secret.create(.{ .labels = &.{.{ .key = "zig-gcp-test", .value = "1" }} });
            created.deinit();
            var got = try secret.get();
            got.deinit();
            var listed = try client.listSecrets(.{ .page_size = 2, .filter = "labels.zig-gcp-test=1" });
            listed.deinit();
            var versions = try secret.listVersions(.{});
            versions.deinit();
            try secret.delete();
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Run.run, .{});
}

/// Production's refusal of a write under a stale etag, word for word.
const stale_etag_reply: Reply = .{ .respond = .{ .status = 400, .body =
    \\{"error":{"code":400,"message":"The etag provided in the request does not match the resource's current etag. Please retry the whole read-modify-write with exponential backoff.","status":"FAILED_PRECONDITION"}}
} };

const updated_secret: Reply = .{ .respond = .{ .body =
    \\{"annotations":{"fk":"v"},"createTime":"2026-10-02T13:04:09.628841Z","etag":"\"165cdb2b1551bc\"",
    \\ "expireTime":"2026-10-04T13:04:09.503134Z","labels":{"team":"payments"},
    \\ "name":"projects/82150720798/secrets/db-password","replication":{"automatic":{}},
    \\ "versionAliases":{"prod":"1"},"versionDestroyTtl":"86400s"}
} };

test "golden: update, global and regional, with and without an etag" {
    var h: Harness = undefined;
    try h.init(&.{ updated_secret, updated_secret }, .{});
    defer h.deinit();

    var got = try h.client.secret("db-password").update(.{
        .labels = .{ .set = &.{.{ .key = "team", .value = "payments" }} },
        .aliases = .{ .set = &.{.{ .name = "prod", .version = 1 }} },
        .expiry = .clear,
    });
    defer got.deinit();
    try h.expectRequest(
        0,
        .PATCH,
        "https://secretmanager.googleapis.com/v1/projects/extractctl/secrets/db-password?updateMask=labels%2Cversion_aliases%2Cexpire_time",
        "{\"labels\":{\"team\":\"payments\"},\"versionAliases\":{\"prod\":\"1\"}}",
    );
    try testing.expectEqual(1, got.value.alias("prod").?);
    try testing.expectEqualStrings("v", got.value.annotation("fk").?);
    try testing.expectEqual(86_400, got.value.version_destroy_delay_s.?);

    var conditional = try h.client.secret("db-password").update(.{
        .annotations = .clear,
        .etag = "\"165cdb26afa951\"",
    });
    defer conditional.deinit();
    try h.expectRequest(
        1,
        .PATCH,
        "https://secretmanager.googleapis.com/v1/projects/extractctl/secrets/db-password?updateMask=annotations",
        "{\"etag\":\"\\\"165cdb26afa951\\\"\"}",
    );

    var regional: Harness = undefined;
    try regional.init(&.{updated_secret}, .{ .location = "europe-west3" });
    defer regional.deinit();
    var there = try regional.client.secret("db-password").update(.{ .version_destroy_delay_s = .{ .set = 86_400 } });
    defer there.deinit();
    try regional.expectRequest(
        0,
        .PATCH,
        "https://secretmanager.europe-west3.rep.googleapis.com/v1/projects/extractctl/locations/europe-west3/secrets/db-password?updateMask=version_destroy_ttl",
        "{\"versionDestroyTtl\":\"86400s\"}",
    );
}

test "a stale etag is Aborted; every other failed precondition stays one" {
    const disabled: Reply = .{ .respond = .{ .status = 400, .body =
        \\{"error":{"code":400,"message":"Secret Version [projects/1/secrets/db-password/versions/2] is in DISABLED state.","status":"FAILED_PRECONDITION"}}
    } };
    var h: Harness = undefined;
    try h.init(&.{ stale_etag_reply, stale_etag_reply, disabled }, .{});
    defer h.deinit();

    try testing.expectError(error.Aborted, h.client.secret("db-password").update(.{ .labels = .clear, .etag = "\"old\"" }));
    // The caller still sees production's words.
    try testing.expect(std.mem.startsWith(u8, h.diag.message(), "The etag provided"));
    try testing.expectError(error.Aborted, h.client.secret("db-password").deleteIf("\"old\""));
    // Without an etag the same status is what it says.
    try testing.expectError(error.FailedPrecondition, h.client.secret("db-password").update(.{ .labels = .clear }));
    // A stale etag is never retried: retrying cannot make it current.
    try h.expectRequestCount(3);
}

test "a stale etag is Aborted even for a client with no diagnostics" {
    var fake: test_util.FakeTransport = .init(testing.allocator, &.{ stale_etag_reply, stale_etag_reply });
    defer fake.deinit();
    var clock: test_util.FakeClock = .{};
    var token: test_util.FakeTokenProvider = .{};
    var client = try Client.init(testing.allocator, clock.io(), .{
        .project_id = "extractctl",
        .token_provider = token.provider(),
        .transport = fake.transport(),
    });
    defer client.deinit();
    try testing.expectError(error.Aborted, client.secret("db-password").update(.{ .labels = .clear, .etag = "\"old\"" }));
    try testing.expectError(error.Aborted, client.secret("db-password").version(.{ .number = 1 }).destroyIf("\"old\""));
}

test "golden: deleteIf sends the etag as read, and what comes back" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = "{}" } },
        .{ .respond = .{ .status = 404, .body = "{\"error\":{\"status\":\"NOT_FOUND\",\"message\":\"Secret [projects/1/secrets/gone] not found.\"}}" } },
    }, .{ .location = "europe-west3" });
    defer h.deinit();
    try h.client.secret("db-password").deleteIf("\"165cdb26afa951\"");
    try h.expectRequest(
        0,
        .DELETE,
        "https://secretmanager.europe-west3.rep.googleapis.com/v1/projects/extractctl/locations/europe-west3/secrets/db-password?etag=%22165cdb26afa951%22",
        null,
    );
    // A missing secret is NotFound before any etag is compared.
    try testing.expectError(error.NotFound, h.client.secret("gone").deleteIf("\"165cdb26afa951\""));
    try testing.expectError(error.InvalidArgument, h.client.secret("db-password").deleteIf(""));
    try testing.expectError(error.InvalidResourceId, h.client.secret("a/b").deleteIf("\"e\""));
    try h.expectRequestCount(2);
}

test "update: what never reaches the server" {
    var h: Harness = undefined;
    try h.init(&.{updated_secret}, .{});
    defer h.deinit();
    const secret = h.client.secret("db-password");

    const Case = struct { types.SecretUpdate, []const u8 };
    const many_labels = comptime blk: {
        @setEvalBranchQuota(100_000);
        var labels: [65]types.Label = undefined;
        for (&labels, 0..) |*l, i| l.* = .{ .key = std.fmt.comptimePrint("k{d}", .{i}), .value = "v" };
        break :blk labels;
    };
    const many_aliases = comptime blk: {
        @setEvalBranchQuota(100_000);
        var aliases: [51]types.Alias = undefined;
        for (&aliases, 0..) |*a, i| a.* = .{ .name = std.fmt.comptimePrint("a{d}", .{i}), .version = 1 };
        break :blk aliases;
    };
    const big = "x" ** (validate.max_annotation_bytes);
    const cases = [_]Case{
        .{ .{}, "at least one change" },
        .{ .{ .etag = "\"e\"" }, "at least one change" },
        .{ .{ .labels = .{ .set = &.{.{ .key = "Team", .value = "v" }} } }, "lowercase letter" },
        .{ .{ .labels = .{ .set = &.{.{ .key = "team", .value = "A" }} } }, "lowercase letters" },
        .{ .{ .labels = .{ .set = &.{.{ .key = "a" ** 64, .value = "v" }} } }, "63 characters" },
        .{ .{ .labels = .{ .set = &.{ .{ .key = "a", .value = "1" }, .{ .key = "a", .value = "2" } } } }, "same key" },
        .{ .{ .labels = .{ .set = &many_labels } }, "at most 64 labels" },
        .{ .{ .annotations = .{ .set = &.{.{ .key = "example.com/owner", .value = "v" }} } }, "annotation 1" },
        .{ .{ .annotations = .{ .set = &.{.{ .key = "k", .value = big }} } }, "16384 bytes" },
        .{ .{ .annotations = .{ .set = &.{ .{ .key = "k", .value = "1" }, .{ .key = "k", .value = "2" } } } }, "same key" },
        .{ .{ .annotations = .{ .set = &.{.{ .key = "k", .value = "\xff" }} } }, "valid UTF-8" },
        .{ .{ .aliases = .{ .set = &.{.{ .name = "latest", .version = 1 }} } }, "neither" },
        .{ .{ .aliases = .{ .set = &.{.{ .name = "NEW", .version = 1 }} } }, "neither" },
        .{ .{ .aliases = .{ .set = &.{.{ .name = "1a", .version = 1 }} } }, "a letter" },
        .{ .{ .aliases = .{ .set = &.{.{ .name = "prod", .version = 0 }} } }, "count from 1" },
        .{ .{ .aliases = .{ .set = &.{ .{ .name = "prod", .version = 1 }, .{ .name = "prod", .version = 2 } } } }, "same name" },
        .{ .{ .aliases = .{ .set = &many_aliases } }, "at most 50 aliases" },
        .{ .{ .expiry = .{ .set = .{ .after_s = 59 } } }, "seconds from now" },
        .{ .{ .expiry = .{ .set = .{ .after_s = validate.max_expiry_s + 1 } } }, "seconds from now" },
        .{ .{ .expiry = .{ .set = .{ .at = "tomorrow" } } }, "RFC 3339" },
        .{ .{ .version_destroy_delay_s = .{ .set = 86_399 } }, "1,000 days" },
        .{ .{ .version_destroy_delay_s = .{ .set = 86_400_001 } }, "1,000 days" },
        .{ .{ .labels = .clear, .etag = "" }, "never empty" },
    };
    for (cases) |case| {
        try testing.expectError(error.InvalidArgument, secret.update(case[0]));
        if (std.mem.indexOf(u8, h.diag.message(), case[1]) == null) {
            std.debug.print("diagnostics \"{s}\" lack \"{s}\"\n", .{ h.diag.message(), case[1] });
            return error.TestUnexpectedDiagnostics;
        }
    }
    try h.expectRequestCount(0);

    // The edges themselves go out: Latest and new are names production takes.
    var edges = try secret.update(.{
        .aliases = .{ .set = &.{ .{ .name = "Latest", .version = 1 }, .{ .name = "new", .version = 1 }, .{ .name = "a" ** 63, .version = 1 } } },
        .annotations = .{ .set = &.{.{ .key = "a" ** 64, .value = "x" ** (validate.max_annotation_bytes - 64) }} },
        .expiry = .{ .set = .{ .after_s = 60 } },
    });
    edges.deinit();
    try h.expectRequestCount(1);
}

test "golden: create with annotations, expiry and a destruction delay" {
    var h: Harness = undefined;
    try h.init(&.{created_secret}, .{});
    defer h.deinit();
    var created = try h.client.secret("db-password").create(.{
        .annotations = &.{.{ .key = "owner", .value = "payments" }},
        .expiry = .{ .at = "2027-01-01T00:00:00Z" },
        .version_destroy_delay_s = 86_400,
    });
    defer created.deinit();
    try h.expectRequest(
        0,
        .POST,
        "https://secretmanager.googleapis.com/v1/projects/extractctl/secrets?secretId=db-password",
        "{\"replication\":{\"automatic\":{}},\"annotations\":{\"owner\":\"payments\"},\"expireTime\":\"2027-01-01T00:00:00Z\",\"versionDestroyTtl\":\"86400s\"}",
    );
    try testing.expectError(error.InvalidArgument, h.client.secret("db-password").create(.{ .expiry = .{ .after_s = 1 } }));
    try testing.expectError(error.InvalidArgument, h.client.secret("db-password").create(.{ .version_destroy_delay_s = 0 }));
    try testing.expectError(error.InvalidArgument, h.client.secret("db-password").create(.{ .annotations = &.{.{ .key = "", .value = "v" }} }));
    try h.expectRequestCount(1);
}

test "update and deleteIf: every allocation failure is OutOfMemory without leaks" {
    const Run = struct {
        fn run(gpa: std.mem.Allocator) !void {
            var fake: test_util.FakeTransport = .init(testing.allocator, &.{ updated_secret, stale_etag_reply, .{ .respond = .{ .body = "{}" } } });
            defer fake.deinit();
            var clock: test_util.FakeClock = .{};
            var token: test_util.FakeTokenProvider = .{ .quota_project = "billing-project" };
            var client = try Client.init(gpa, clock.io(), .{
                .project_id = "extractctl",
                .token_provider = token.provider(),
                .transport = fake.transport(),
            });
            defer client.deinit();
            const secret = client.secret("db-password");
            var got = try secret.update(.{
                .labels = .{ .set = &.{.{ .key = "team", .value = "payments" }} },
                .annotations = .{ .set = &.{.{ .key = "k", .value = "v" }} },
                .aliases = .{ .set = &.{.{ .name = "prod", .version = 1 }} },
                .expiry = .{ .set = .{ .after_s = 3600 } },
                .version_destroy_delay_s = .clear,
                .etag = "\"e\"",
            });
            got.deinit();
            if (secret.update(.{ .labels = .clear, .etag = "\"old\"" })) |unexpected| {
                var u = unexpected;
                u.deinit();
                return error.TestExpectedAborted;
            } else |err| switch (err) {
                error.Aborted => {},
                else => return err,
            }
            try secret.deleteIf("\"e\"");
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Run.run, .{});
}

test "golden: topics and rotation, on create and update" {
    var h: Harness = undefined;
    try h.init(&.{ created_secret, updated_secret, updated_secret }, .{});
    defer h.deinit();
    const secret = h.client.secret("db-password");

    var created = try secret.create(.{
        .topics = &.{"projects/extractctl/topics/rotations"},
        .rotation = .{ .next_time = "2027-01-01T00:00:00Z", .period_s = 2_592_000 },
    });
    defer created.deinit();
    try h.expectRequest(
        0,
        .POST,
        "https://secretmanager.googleapis.com/v1/projects/extractctl/secrets?secretId=db-password",
        "{\"replication\":{\"automatic\":{}},\"topics\":[{\"name\":\"projects/extractctl/topics/rotations\"}],\"rotation\":{\"nextRotationTime\":\"2027-01-01T00:00:00Z\",\"rotationPeriod\":\"2592000s\"}}",
    );

    var moved = try secret.update(.{
        .topics = .{ .set = &.{ "projects/extractctl/topics/rotations", "projects/other-project/topics/audit" } },
        .rotation = .{ .set = .{ .next_time = "2027-02-01T00:00:00Z" } },
    });
    defer moved.deinit();
    try h.expectRequest(
        1,
        .PATCH,
        "https://secretmanager.googleapis.com/v1/projects/extractctl/secrets/db-password?updateMask=topics%2Crotation",
        "{\"topics\":[{\"name\":\"projects/extractctl/topics/rotations\"},{\"name\":\"projects/other-project/topics/audit\"}],\"rotation\":{\"nextRotationTime\":\"2027-02-01T00:00:00Z\"}}",
    );

    var cleared = try secret.update(.{ .rotation = .clear, .topics = .clear });
    defer cleared.deinit();
    try h.expectRequest(
        2,
        .PATCH,
        "https://secretmanager.googleapis.com/v1/projects/extractctl/secrets/db-password?updateMask=topics%2Crotation",
        "{}",
    );
}

test "a topic Secret Manager cannot publish to is TopicNotPublishable, wherever topics are named" {
    const denied: Reply = .{ .respond = .{ .status = 400, .body =
        \\{"error":{"code":400,"message":"Permission 'pubsub.topics.publish' denied for service-82150720798@gcp-sa-secretmanager.iam.gserviceaccount.com for pubsub topic: projects/extractctl/topics/zigps-t2 or the topic doesn't exist. Grant the 'pubsub.topic.publish' permission (or 'roles/pubsub.publisher') on this topic to service-82150720798@gcp-sa-secretmanager.iam.gserviceaccount.com.","status":"FAILED_PRECONDITION"}}
    } };
    const missing: Reply = .{ .respond = .{ .status = 404, .body =
        \\{"error":{"code":404,"message":"Topic [projects/extractctl/topics/zigps-nosuch] not found.","status":"NOT_FOUND"}}
    } };
    const in_transit: Reply = .{ .respond = .{ .status = 400, .body =
        \\{"error":{"code":400,"message":"The topic's message storage policy requires enforcement in transit, but the Publish request was received by a Pub/Sub server in a non-allowed region. Please either publish via a regional Pub/Sub endpoint corresponding to an allowed region, or update the topic's message storage policy.","status":"FAILED_PRECONDITION"}}
    } };
    const secret_missing: Reply = .{ .respond = .{ .status = 404, .body =
        \\{"error":{"code":404,"message":"Secret [projects/82150720798/secrets/db-password] not found.","status":"NOT_FOUND"}}
    } };
    var h: Harness = undefined;
    try h.init(&.{ denied, missing, in_transit, secret_missing, denied }, .{});
    defer h.deinit();
    const secret = h.client.secret("db-password");
    const topics: []const []const u8 = &.{"projects/extractctl/topics/zigps-t2"};

    try testing.expectError(error.TopicNotPublishable, secret.create(.{ .topics = topics }));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "roles/pubsub.publisher") != null);
    try testing.expectError(error.TopicNotPublishable, secret.update(.{ .topics = .{ .set = topics } }));
    try testing.expectError(error.TopicNotPublishable, secret.update(.{ .topics = .{ .set = topics }, .etag = "\"e\"" }));
    // A missing secret is what it says, topics or not.
    try testing.expectError(error.NotFound, secret.update(.{ .topics = .{ .set = topics } }));
    // An update that names no topics never meets this refusal; if it
    // did, it would be what production said.
    try testing.expectError(error.FailedPrecondition, secret.update(.{ .labels = .clear }));
    // Never retried: a grant is the caller's to make.
    try h.expectRequestCount(5);
}

test "topics and rotation: what never reaches the server" {
    var h: Harness = undefined;
    try h.init(&.{}, .{});
    defer h.deinit();
    const secret = h.client.secret("db-password");
    const eleven: []const []const u8 = &.{
        "projects/p/topics/t01", "projects/p/topics/t02", "projects/p/topics/t03", "projects/p/topics/t04",
        "projects/p/topics/t05", "projects/p/topics/t06", "projects/p/topics/t07", "projects/p/topics/t08",
        "projects/p/topics/t09", "projects/p/topics/t10", "projects/p/topics/t11",
    };
    const Case = struct { types.SecretUpdate, []const u8 };
    for ([_]Case{
        .{ .{ .topics = .{ .set = eleven } }, "at most 10 topics" },
        .{ .{ .topics = .{ .set = &.{"rotations"} } }, "named in full" },
        .{ .{ .topics = .{ .set = &.{"projects/p/topics/goog-x"} } }, "named in full" },
        .{ .{ .topics = .{ .set = &.{ "projects/p/topics/abc", "projects/p/topics/abc" } } }, "are the same" },
        .{ .{ .rotation = .{ .set = .{ .next_time = "soon" } }, .topics = .{ .set = &.{"projects/p/topics/abc"} } }, "RFC 3339" },
        .{ .{ .rotation = .{ .set = .{ .next_time = "2027-01-01T00:00:00Z", .period_s = 3599 } }, .topics = .{ .set = &.{"projects/p/topics/abc"} } }, "1 hour" },
        .{ .{ .rotation = .{ .set = .{ .next_time = "2027-01-01T00:00:00Z" } }, .topics = .clear }, "needs topics" },
        .{ .{ .rotation = .{ .set = .{ .next_time = "2027-01-01T00:00:00Z" } }, .topics = .{ .set = &.{} } }, "needs topics" },
    }) |case| {
        try testing.expectError(error.InvalidArgument, secret.update(case[0]));
        if (std.mem.indexOf(u8, h.diag.message(), case[1]) == null) {
            std.debug.print("diagnostics \"{s}\" lack \"{s}\"\n", .{ h.diag.message(), case[1] });
            return error.TestUnexpectedDiagnostics;
        }
    }
    try testing.expectError(error.InvalidArgument, secret.create(.{ .rotation = .{ .next_time = "2027-01-01T00:00:00Z" } }));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "needs topics") != null);
    try h.expectRequestCount(0);
}

test "keys: what never reaches the server" {
    var h: Harness = undefined;
    try h.init(&.{}, .{});
    defer h.deinit();
    var regional: Harness = undefined;
    try regional.init(&.{}, .{ .location = "us-central1" });
    defer regional.deinit();
    const g = "projects/p/locations/global/keyRings/r/cryptoKeys/g";
    const east = "projects/p/locations/us-east1/keyRings/r/cryptoKeys/e";
    const central = "projects/p/locations/us-central1/keyRings/r/cryptoKeys/c";

    const Create = struct { *Harness, types.SecretConfig, []const u8 };
    for ([_]Create{
        .{ &h, .{ .kms_key = central }, "must be there too" },
        .{ &h, .{ .kms_key = "projects/p/keyRings/r/cryptoKeys/g" }, "named in full" },
        .{ &h, .{ .kms_key = g ++ "/cryptoKeyVersions/1" }, "named in full" },
        .{ &h, .{ .replication = .{ .user_managed = &.{.{ .location = "us-east1" }} }, .kms_key = east }, "per replica" },
        .{ &h, .{ .replication = .{ .user_managed = &.{.{ .location = "us-east1", .kms_key = central }} } }, "must be there too" },
        .{ &h, .{ .replication = .{ .user_managed = &.{ .{ .location = "us-east1", .kms_key = east }, .{ .location = "us-central1" } } } }, "or none does" },
        .{ &regional, .{ .kms_key = g }, "must be there too" },
    }) |case| {
        try testing.expectError(error.InvalidArgument, case[0].client.secret("db-password").create(case[1]));
        if (std.mem.indexOf(u8, case[0].diag.message(), case[2]) == null) {
            std.debug.print("diagnostics \"{s}\" lack \"{s}\"\n", .{ case[0].diag.message(), case[2] });
            return error.TestUnexpectedDiagnostics;
        }
    }
    const Update = struct { *Harness, types.SecretUpdate, []const u8 };
    for ([_]Update{
        .{ &h, .{ .kms_key = .{ .set = central } }, "must be there too" },
        .{ &regional, .{ .kms_key = .{ .set = g } }, "must be there too" },
        .{ &regional, .{ .replica_keys = &.{.{ .location = "us-central1", .kms_key = central }} }, "no replicas" },
        .{ &h, .{ .replica_keys = &.{.{ .location = "us-east1", .kms_key = east }}, .kms_key = .clear }, "not both" },
        .{ &h, .{ .replica_keys = &.{} }, "every replica" },
        .{ &h, .{ .replica_keys = &.{.{ .location = "US-EAST1" }} }, "location id" },
        .{ &h, .{ .replica_keys = &.{ .{ .location = "us-east1", .kms_key = east }, .{ .location = "us-central1" } } }, "or none does" },
    }) |case| {
        try testing.expectError(error.InvalidArgument, case[0].client.secret("db-password").update(case[1]));
        if (std.mem.indexOf(u8, case[0].diag.message(), case[2]) == null) {
            std.debug.print("diagnostics \"{s}\" lack \"{s}\"\n", .{ case[0].diag.message(), case[2] });
            return error.TestUnexpectedDiagnostics;
        }
    }
    try h.expectRequestCount(0);
    try regional.expectRequestCount(0);
}

test "a key Cloud KMS refuses is KeyUnavailable, where a key is used" {
    const ungranted: Reply = .{ .respond = .{ .status = 400, .body =
        \\{"error":{"code":400,"message":"Permission denied on Cloud KMS resource [projects/extractctl/locations/us-central1/keyRings/zigps-smf-2b9e3c6d/cryptoKeys/zigps-smf-2b9e3c6d-r2] (or it does not exist). Please grant cloudkms.cryptoKeyVersions.useToDecrypt and cloudkms.cryptoKeyVersions.useToEncrypt permissions (roles/cloudkms.cryptoKeyEncrypterDecrypter) to the Secret Manager service identity. See https://cloud.google.com/secret-manager/docs/cmek for more information.","status":"FAILED_PRECONDITION"}}
    } };
    const disabled: Reply = .{ .respond = .{ .status = 400, .body =
        \\{"error":{"code":400,"message":"Failed precondition on Cloud KMS resource [projects/extractctl/locations/global/keyRings/zigps-smf-2b9e3c6d/cryptoKeys/zigps-smf-2b9e3c6d-g/cryptoKeyVersions/1]. KMS error message: [projects/extractctl/locations/global/keyRings/zigps-smf-2b9e3c6d/cryptoKeys/zigps-smf-2b9e3c6d-g/cryptoKeyVersions/1 is not enabled, current state is: DISABLED.]","status":"FAILED_PRECONDITION"}}
    } };
    const primary_disabled: Reply = .{ .respond = .{ .status = 400, .body =
        \\{"error":{"code":400,"message":"Failed precondition on Cloud KMS resource []. KMS error message: [projects/extractctl/locations/global/keyRings/zigps-smf-2b9e3c6d/cryptoKeys/zigps-smf-2b9e3c6d-g/cryptoKeyVersions/2 is not enabled, current state is: DISABLED.]","status":"FAILED_PRECONDITION"}}
    } };
    const version_disabled: Reply = .{ .respond = .{ .status = 400, .body =
        \\{"error":{"code":400,"message":"Secret Version [projects/82150720798/secrets/db-password/versions/2] is in DISABLED state.","status":"FAILED_PRECONDITION"}}
    } };
    var h: Harness = undefined;
    try h.init(&.{ ungranted, ungranted, disabled, primary_disabled, version_disabled, disabled }, .{ .location = "us-central1" });
    defer h.deinit();
    const secret = h.client.secret("db-password");
    const key = "projects/extractctl/locations/us-central1/keyRings/zigps-smf-2b9e3c6d/cryptoKeys/zigps-smf-2b9e3c6d-r2";

    try testing.expectError(error.KeyUnavailable, secret.create(.{ .kms_key = key }));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "cryptoKeyEncrypterDecrypter") != null);
    try testing.expectError(error.KeyUnavailable, secret.update(.{ .kms_key = .{ .set = key } }));
    try testing.expectError(error.KeyUnavailable, secret.access(.{ .number = 1 }));
    try testing.expectError(error.KeyUnavailable, secret.addVersion("s3cr3t"));
    // A disabled secret version is what it was.
    try testing.expectError(error.FailedPrecondition, secret.access(.{ .number = 2 }));
    // A call that names no key never maps one.
    try testing.expectError(error.FailedPrecondition, secret.update(.{ .labels = .clear }));
    try h.expectRequestCount(6);
}
