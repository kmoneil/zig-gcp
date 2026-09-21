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
    const response = try rpc.execute(c, result.arena, .{ .method = .POST, .path = path, .body = body });
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
/// with them, so the server refuses anything that arrives changed.
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
    const response = try rpc.execute(c, result.arena, .{
        .method = .POST,
        .path = path,
        .body = body,
        // A retry can store the same bytes twice; the client's option says
        // whether that is better than losing them.
        .retry = c.retry_add_version,
        .wipe = true,
    });
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
        .replication = .{ .user_managed = &.{ "europe-west1", "us-east1" } },
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
        .replication = .{ .user_managed = &.{"europe-west1"} },
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
        .replication = .{ .user_managed = &.{"Europe-West1"} },
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
