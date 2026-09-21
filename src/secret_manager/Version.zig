//! A handle for one version of one secret. Cheap: a client pointer, the
//! secret's id and the reference. Creating one sends nothing.

const Version = @This();

const std = @import("std");
const core = @import("core");

const Client = @import("Client.zig");
const SecretValue = @import("SecretValue.zig");
const codec = @import("codec.zig");
const errors = @import("errors.zig");
const logging = @import("logging.zig");
const names = @import("names.zig");
const rpc = @import("rpc.zig");
const types = @import("types.zig");
const Error = errors.Error;

client: *Client,
/// The secret's id, borrowed from the caller.
secret_id: []const u8,
ref: types.VersionRef,

/// Fetches this version's bytes and hands them back in memory that `deinit`
/// wipes. The checksum is verified according to the client's
/// `verify_checksum`; bytes that fail it are never returned.
///
/// The caller owns the result: `defer value.deinit()`.
pub fn access(self: Version) Error!SecretValue {
    const c = self.client;
    rpc.begin(c);
    try rpc.checkSecretId(c, self.secret_id);
    try rpc.checkRef(c, self.ref);

    // The path names the secret, not its bytes, but it costs nothing to
    // wipe it along with the token the engine fetches beside it.
    var wiping: core.WipingAllocator = .init(c.gpa);
    var scratch: std.heap.ArenaAllocator = .init(wiping.allocator());
    defer scratch.deinit();
    const path = try names.versionPath(scratch.allocator(), c.parent(), self.secret_id, self.ref, ":access");

    var value: SecretValue = try .init(c.gpa);
    errdefer value.deinit();

    var attempt: u32 = 1;
    while (true) : (attempt += 1) {
        const body = try rpc.execute(c, value.arena(), .{ .method = .GET, .path = path, .wipe = true });
        const got = codec.decodeAccess(value.allocator(), body) catch |err|
            return rpc.decodeFailed(c, err, "access");
        const data = core.base64.decode(value.allocator(), got.data) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidBase64 => {
                if (c.diagnostics) |d| d.print("the access response held payload data that is not base64", .{});
                return error.InvalidResponse;
            },
        };

        if (self.verify(got.checksum, data)) |verified| {
            value.data = .init(data);
            value.version_name = got.name;
            value.checksum_verified = verified;
            return value;
        } else |err| {
            // A mismatch means the bytes changed between Google's storage
            // and this process. Access is idempotent, so ask again; the bad
            // bytes are wiped before the next attempt.
            if (err != error.ChecksumMismatch or attempt >= c.retry.max_attempts) return err;
            const delay_ms = rpc.backoffMs(c, attempt);
            logging.warn(
                "the bytes of {s} did not match their checksum; fetching again in {d} ms (attempt {d} of {d})",
                .{ path, delay_ms, attempt + 1, c.retry.max_attempts },
            );
            value.clear();
            try c.io.sleep(.fromMilliseconds(delay_ms), .awake);
        }
    }
}

/// This version's metadata: its state, when it was created, and whether the
/// checksum stored with it came from the client. None of its bytes.
pub fn get(self: Version) Error!types.Owned(types.VersionInfo) {
    const c = self.client;
    rpc.begin(c);
    try rpc.checkSecretId(c, self.secret_id);
    try rpc.checkRef(c, self.ref);

    var scratch: std.heap.ArenaAllocator = .init(c.gpa);
    defer scratch.deinit();
    const path = try names.versionPath(scratch.allocator(), c.parent(), self.secret_id, self.ref, "");

    var result: types.Owned(types.VersionInfo) = try .init(c.gpa);
    errdefer result.deinit();
    const body = try rpc.execute(c, result.arena, .{ .method = .GET, .path = path });
    result.value = codec.decodeVersion(result.arena.allocator(), body) catch |err|
        return rpc.decodeFailed(c, err, "version");
    return result;
}

/// Makes a disabled version accessible again. Takes a version number.
pub fn enable(self: Version) Error!types.Owned(types.VersionInfo) {
    return self.change("enable", ":enable");
}

/// Keeps the version and its bytes, but refuses to serve them: accessing a
/// disabled version answers `error.FailedPrecondition`. Takes a version
/// number.
pub fn disable(self: Version) Error!types.Owned(types.VersionInfo) {
    return self.change("disable", ":disable");
}

/// Destroys the bytes. The version stays, with its state and the time it
/// was destroyed, but what it held is gone for good. Takes a version
/// number.
///
/// Unlike `enable` and `disable`, this one is not idempotent: a second
/// destroy answers `error.FailedPrecondition`, with "SecretVersion.state is
/// already DESTROYED". A destroy whose answer was lost and then retried
/// reports that, which means the first attempt worked.
pub fn destroy(self: Version) Error!types.Owned(types.VersionInfo) {
    return self.change("destroy", ":destroy");
}

/// The three calls that change a version's state. Each takes an explicit
/// number: "whatever is latest right now" is the wrong target for a change
/// that lasts, and production refuses `latest` for these three anyway.
fn change(self: Version, what: []const u8, suffix: []const u8) Error!types.Owned(types.VersionInfo) {
    const c = self.client;
    rpc.begin(c);
    try rpc.checkSecretId(c, self.secret_id);
    const number = try rpc.requireNumber(c, self.ref, what);

    var scratch: std.heap.ArenaAllocator = .init(c.gpa);
    defer scratch.deinit();
    const path = try names.versionPath(scratch.allocator(), c.parent(), self.secret_id, .{ .number = number }, suffix);

    var result: types.Owned(types.VersionInfo) = try .init(c.gpa);
    errdefer result.deinit();
    // Enabling an enabled version and disabling a disabled one are both
    // answered with 200 and the same state, so a lost answer costs nothing
    // to ask again. Destroying twice is not; `destroy` says so.
    const body = try rpc.execute(c, result.arena, .{ .method = .POST, .path = path, .body = "{}" });
    result.value = codec.decodeVersion(result.arena.allocator(), body) catch |err|
        return rpc.decodeFailed(c, err, "version");
    return result;
}

/// Checks the bytes against the checksum the server sent, as far as the
/// client's mode asks. Neither the checksum nor the length of the bytes
/// reaches the log or the diagnostics.
fn verify(self: Version, sent: ?u32, data: []const u8) Error!bool {
    const c = self.client;
    if (c.verify_checksum == .off) return false;
    const expected = sent orelse {
        if (c.verify_checksum == .required) {
            if (c.diagnostics) |d| d.print(
                "the version has no checksum, and verify_checksum is .required",
                .{},
            );
            return error.MissingChecksum;
        }
        return false;
    };
    if (core.crc32c.hash(data) != expected) {
        if (c.diagnostics) |d| d.print(
            "the bytes received do not match the checksum received with them",
            .{},
        );
        return error.ChecksumMismatch;
    }
    return true;
}

const testing = std.testing;
const test_util = @import("test_util.zig");
const Harness = test_util.Harness;
const Reply = test_util.FakeTransport.Reply;

/// `s3cr3t`, with the checksum production sends for it.
const secret_access: Reply = .{ .respond = .{ .body =
    \\{"name":"projects/82150720798/secrets/db-password/versions/3",
    \\ "payload":{"data":"czNjcjN0","dataCrc32c":"825573743"}}
} };

test "golden: access latest, global" {
    var h: Harness = undefined;
    try h.init(&.{secret_access}, .{});
    defer h.deinit();

    var value = try h.client.secret("db-password").access(.latest);
    defer value.deinit();
    try h.expectRequest(
        0,
        .GET,
        "https://secretmanager.googleapis.com/v1/projects/extractctl/secrets/db-password/versions/latest:access",
        null,
    );
    try testing.expectEqualStrings("s3cr3t", value.bytes());
    try testing.expectEqualStrings("projects/82150720798/secrets/db-password/versions/3", value.version_name);
    try testing.expect(value.checksum_verified);
    // Accessing `latest` tells the caller which version answered.
    try testing.expectEqual(3, value.versionNumber().?);
    try testing.expectEqualStrings("ya29.test-token", (try h.fake.request(0)).bearer.?);
}

test "golden: access by number and by alias, regional" {
    var h: Harness = undefined;
    try h.init(&.{ secret_access, secret_access }, .{ .location = "europe-west3" });
    defer h.deinit();

    var by_number = try h.client.secret("db-password").access(.{ .number = 3 });
    by_number.deinit();
    try h.expectRequest(
        0,
        .GET,
        "https://secretmanager.europe-west3.rep.googleapis.com/v1/projects/extractctl/locations/europe-west3/secrets/db-password/versions/3:access",
        null,
    );

    var by_alias = try h.client.secret("db-password").version(.{ .alias = "prod" }).access();
    by_alias.deinit();
    try h.expectRequest(
        1,
        .GET,
        "https://secretmanager.europe-west3.rep.googleapis.com/v1/projects/extractctl/locations/europe-west3/secrets/db-password/versions/prod:access",
        null,
    );
}

test "checksum modes: every cell of the table" {
    const no_checksum: Reply = .{ .respond = .{ .body = "{\"name\":\"v/1\",\"payload\":{\"data\":\"czNjcjN0\"}}" } };
    const wrong_checksum: Reply = .{ .respond = .{ .body = "{\"name\":\"v/1\",\"payload\":{\"data\":\"czNjcjN0\",\"dataCrc32c\":\"1\"}}" } };

    // A checksum that is there is verified in both checking modes.
    for ([_]types.ChecksumMode{ .required, .if_present }) |mode| {
        var h: Harness = undefined;
        try h.init(&.{secret_access}, .{ .verify_checksum = mode });
        defer h.deinit();
        var value = try h.client.secret("db-password").access(.latest);
        defer value.deinit();
        try testing.expect(value.checksum_verified);
    }

    // Missing: .required refuses, .if_present returns the bytes unverified.
    {
        var h: Harness = undefined;
        try h.init(&.{no_checksum}, .{ .verify_checksum = .required });
        defer h.deinit();
        try testing.expectError(error.MissingChecksum, h.client.secret("db-password").access(.latest));
        try testing.expect(std.mem.indexOf(u8, h.diag.message(), "no checksum") != null);
    }
    {
        var h: Harness = undefined;
        try h.init(&.{no_checksum}, .{});
        defer h.deinit();
        var value = try h.client.secret("db-password").access(.latest);
        defer value.deinit();
        try testing.expectEqualStrings("s3cr3t", value.bytes());
        try testing.expect(!value.checksum_verified);
    }

    // Off: even a wrong checksum is ignored, and nothing claims verification.
    {
        var h: Harness = undefined;
        try h.init(&.{wrong_checksum}, .{ .verify_checksum = .off });
        defer h.deinit();
        var value = try h.client.secret("db-password").access(.latest);
        defer value.deinit();
        try testing.expectEqualStrings("s3cr3t", value.bytes());
        try testing.expect(!value.checksum_verified);
    }
}

test "a mismatch is fetched again, and a good answer ends it" {
    const mismatch: Reply = .{ .respond = .{ .body = "{\"name\":\"v/1\",\"payload\":{\"data\":\"czNjcjN0\",\"dataCrc32c\":\"1\"}}" } };
    var h: Harness = undefined;
    try h.init(&.{ mismatch, secret_access }, .{});
    defer h.deinit();

    var value = try h.client.secret("db-password").access(.latest);
    defer value.deinit();
    try testing.expectEqualStrings("s3cr3t", value.bytes());
    try testing.expect(value.checksum_verified);
    try h.expectRequestCount(2);
    // It waited between attempts, as the retry policy says.
    try testing.expectEqual(1, h.clock.sleep_count);
    try testing.expect(h.clock.sleepMs(0) <= 100);
}

test "a mismatch that never clears is an error, and the bytes are never handed over" {
    const mismatch: Reply = .{ .respond = .{ .body = "{\"name\":\"v/1\",\"payload\":{\"data\":\"czNjcjN0\",\"dataCrc32c\":\"1\"}}" } };
    var h: Harness = undefined;
    try h.init(&.{ mismatch, mismatch, mismatch }, .{ .retry = .{ .max_attempts = 3 } });
    defer h.deinit();

    try testing.expectError(error.ChecksumMismatch, h.client.secret("db-password").access(.latest));
    try h.expectRequestCount(3);
    try testing.expectEqual(2, h.clock.sleep_count);
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "do not match the checksum") != null);
}

test "a response that is not an access response" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = "{\"payload\":{\"data\":\"not base64!\"}}" } },
        .{ .respond = .{ .body = "<html>" } },
        .{ .respond = .{ .body = "{\"payload\":{\"data\":\"aGk=\",\"dataCrc32c\":\"-7\"}}" } },
    }, .{ .verify_checksum = .off });
    defer h.deinit();

    try testing.expectError(error.InvalidResponse, h.client.secret("db-password").access(.latest));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "not base64") != null);
    try testing.expectError(error.InvalidResponse, h.client.secret("db-password").access(.latest));
    try testing.expectError(error.InvalidResponse, h.client.secret("db-password").access(.latest));
    // A broken body is never retried: it would break the same way again.
    try h.expectRequestCount(3);
}

test "bad ids and references are refused before anything is sent" {
    var h: Harness = undefined;
    try h.init(&.{}, .{});
    defer h.deinit();

    try testing.expectError(error.InvalidResourceId, h.client.secret("").access(.latest));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "invalid secret id") != null);
    try testing.expectError(error.InvalidResourceId, h.client.secret("db password").access(.latest));
    try testing.expectError(error.InvalidResourceId, h.client.secret("projects/p/secrets/db").access(.latest));
    try testing.expectError(error.InvalidResourceId, h.client.secret("db").access(.{ .number = 0 }));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "versions count from 1") != null);
    try testing.expectError(error.InvalidResourceId, h.client.secret("db").access(.{ .alias = "latest" }));
    try testing.expectError(error.InvalidResourceId, h.client.secret("db").access(.{ .alias = "3" }));
    try testing.expectError(error.InvalidResourceId, h.client.secret("db").access(.{ .alias = "a/b" }));
    try h.expectRequestCount(0);
}

test "the API's errors reach the caller" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .status = 404, .body = "{\"error\":{\"status\":\"NOT_FOUND\",\"message\":\"Secret [projects/1/secrets/db] not found.\"}}" } },
        .{ .respond = .{ .status = 400, .body = "{\"error\":{\"status\":\"FAILED_PRECONDITION\",\"message\":\"Secret Version [1] is in DESTROYED state.\"}}" } },
        .{ .respond = .{ .status = 403, .body = "{\"error\":{\"status\":\"PERMISSION_DENIED\",\"message\":\"denied\"}}" } },
    }, .{});
    defer h.deinit();

    try testing.expectError(error.NotFound, h.client.secret("db").access(.latest));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "not found") != null);
    // Production answers FAILED_PRECONDITION for a disabled or destroyed
    // version, with HTTP 400.
    try testing.expectError(error.FailedPrecondition, h.client.secret("db").access(.{ .number = 1 }));
    try testing.expectEqual(400, h.diag.http_status);
    try testing.expectError(error.PermissionDenied, h.client.secret("db").access(.latest));
}

test "nothing of the secret survives deinit, or a failed call" {
    const marker = "S3CR3T-payload";
    const encoded = test_util.encoded(marker);
    const good: Reply = .{ .respond = .{ .body = test_util.accessBody("v/1", marker) } };
    const mismatch: Reply = .{ .respond = .{ .body = test_util.accessBodyChecksum("v/1", marker, "1") } };

    // The client allocates from a fixed buffer, so the test can read every
    // byte it ever used, base64 and decoded alike.
    var backing: [512 * 1024]u8 = @splat(0);
    var fba: std.heap.FixedBufferAllocator = .init(&backing);
    var fake: test_util.FakeTransport = .init(testing.allocator, &.{ good, mismatch, mismatch });
    defer fake.deinit();
    var clock: test_util.FakeClock = .{};
    var token: test_util.FakeTokenProvider = .{ .token = "ya29.token-that-must-not-linger" };
    var client = try Client.init(fba.allocator(), clock.io(), .{
        .project_id = "extractctl",
        .token_provider = token.provider(),
        .retry = .{ .max_attempts = 2 },
        .transport = fake.transport(),
    });
    defer client.deinit();

    var value = try client.secret("db-password").access(.latest);
    try testing.expectEqualStrings(marker, value.bytes());
    try testing.expect(std.mem.indexOf(u8, &backing, marker) != null);
    try testing.expect(std.mem.indexOf(u8, &backing, encoded) != null);
    value.deinit();
    // Neither the bytes nor the base64 they arrived in are left anywhere.
    try testing.expectEqual(null, std.mem.indexOf(u8, &backing, marker));
    try testing.expectEqual(null, std.mem.indexOf(u8, &backing, encoded));

    // The same holds for a call that fails: two attempts, both wiped.
    try testing.expectError(error.ChecksumMismatch, client.secret("db-password").access(.latest));
    try testing.expectEqual(null, std.mem.indexOf(u8, &backing, marker));
    try testing.expectEqual(null, std.mem.indexOf(u8, &backing, encoded));
    // Nor does the bearer token the call fetched to ask with, which is what
    // marking the call as carrying secrets buys.
    try testing.expectEqual(null, std.mem.indexOf(u8, &backing, token.token));
}

test "a retried access wipes the attempt that failed, not just the last one" {
    const marker = "S3CR3T-payload";
    var backing: [512 * 1024]u8 = @splat(0);
    var fba: std.heap.FixedBufferAllocator = .init(&backing);
    var fake: test_util.FakeTransport = .init(testing.allocator, &.{
        .{ .respond = .{ .body = test_util.accessBodyChecksum("v/1", marker, "1") } },
        .{ .respond = .{ .body = test_util.accessBody("v/1", marker) } },
    });
    defer fake.deinit();
    var clock: test_util.FakeClock = .{};
    var token: test_util.FakeTokenProvider = .{};
    var client = try Client.init(fba.allocator(), clock.io(), .{
        .project_id = "extractctl",
        .token_provider = token.provider(),
        .transport = fake.transport(),
    });
    defer client.deinit();

    var value = try client.secret("db-password").access(.latest);
    defer value.deinit();
    try testing.expectEqualStrings(marker, value.bytes());
    // One copy in memory, the one being returned. The mismatched attempt's
    // bytes were wiped before the next attempt was made, rather than kept
    // until the call ended.
    try testing.expectEqual(1, std.mem.count(u8, &backing, marker));
}

test "log hygiene: no secret, no length, no checksum, no token" {
    logging.capture.reset();
    var h: Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .status = 503, .body = "{\"error\":{\"status\":\"UNAVAILABLE\"}}" } },
        secret_access,
    }, .{});
    defer h.deinit();

    var value = try h.client.secret("db-password").access(.latest);
    defer value.deinit();

    const log = logging.capture.text();
    try testing.expect(log.len > 0);
    // The bytes, the base64 they arrived in, their length, their checksum,
    // and the bearer token: none of them.
    for ([_][]const u8{ "s3cr3t", "czNjcjN0", "825573743", "ya29" }) |forbidden| {
        if (std.mem.indexOf(u8, log, forbidden) != null) {
            std.debug.print("log leaked \"{s}\":\n{s}\n", .{ forbidden, log });
            return error.TestLeakedSecret;
        }
    }
    // The length of a secret is information too: "6" appears in the log only
    // as part of a timing or an attempt count, never as a size.
    try testing.expect(std.mem.indexOf(u8, log, "bytes") == null);
    // What it does say is which call was made, and that it was retried.
    try testing.expect(std.mem.indexOf(u8, log, "/versions/latest:access") != null);
    try testing.expect(std.mem.indexOf(u8, log, "retrying") != null);
}

test "access: every allocation failure is OutOfMemory without leaks" {
    const Run = struct {
        fn run(gpa: std.mem.Allocator) !void {
            var fake: test_util.FakeTransport = .init(testing.allocator, &.{ secret_access, secret_access });
            defer fake.deinit();
            var clock: test_util.FakeClock = .{};
            var token: test_util.FakeTokenProvider = .{ .quota_project = "billing-project" };
            var client = try Client.init(gpa, clock.io(), .{
                .project_id = "extractctl",
                .token_provider = token.provider(),
                .transport = fake.transport(),
            });
            defer client.deinit();
            var value = try client.secret("db-password").access(.latest);
            value.deinit();
            var again = try client.secret("db-password").version(.{ .alias = "prod" }).access();
            again.deinit();
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Run.run, .{});
}

const destroyed_version: Reply = .{ .respond = .{ .body =
    \\{"name":"projects/82150720798/secrets/db-password/versions/1",
    \\ "createTime":"2026-09-20T23:09:39.716394Z",
    \\ "destroyTime":"2026-09-20T23:09:41.500615147Z",
    \\ "state":"DESTROYED","etag":"\"165bf23a79782f\"",
    \\ "clientSpecifiedPayloadChecksum":true}
} };

test "golden: get, enable, disable and destroy" {
    const enabled: Reply = .{ .respond = .{ .body = "{\"name\":\"projects/1/secrets/db-password/versions/1\",\"state\":\"ENABLED\"}" } };
    const disabled: Reply = .{ .respond = .{ .body = "{\"name\":\"projects/1/secrets/db-password/versions/1\",\"state\":\"DISABLED\"}" } };
    var h: Harness = undefined;
    try h.init(&.{ enabled, disabled, enabled, destroyed_version }, .{});
    defer h.deinit();
    const base = "https://secretmanager.googleapis.com/v1/projects/extractctl/secrets/db-password/versions/1";

    var got = try h.client.secret("db-password").version(.{ .number = 1 }).get();
    defer got.deinit();
    try h.expectRequest(0, .GET, base, null);
    try testing.expectEqual(.enabled, got.value.state);

    var off = try h.client.secret("db-password").version(.{ .number = 1 }).disable();
    defer off.deinit();
    try h.expectRequest(1, .POST, base ++ ":disable", "{}");
    try testing.expectEqual(.disabled, off.value.state);

    var on = try h.client.secret("db-password").version(.{ .number = 1 }).enable();
    defer on.deinit();
    try h.expectRequest(2, .POST, base ++ ":enable", "{}");
    try testing.expectEqual(.enabled, on.value.state);

    var gone = try h.client.secret("db-password").version(.{ .number = 1 }).destroy();
    defer gone.deinit();
    try h.expectRequest(3, .POST, base ++ ":destroy", "{}");
    try testing.expectEqual(.destroyed, gone.value.state);
    try testing.expectEqualStrings("2026-09-20T23:09:41.500615147Z", gone.value.destroy_time);
}

test "the guard: a lasting change needs a version number" {
    var h: Harness = undefined;
    try h.init(&.{secret_access}, .{});
    defer h.deinit();
    const secret = h.client.secret("db-password");

    for ([_]types.VersionRef{ .latest, .{ .alias = "prod" } }) |ref| {
        try testing.expectError(error.ExplicitVersionRequired, secret.version(ref).destroy());
        try testing.expectError(error.ExplicitVersionRequired, secret.version(ref).disable());
        try testing.expectError(error.ExplicitVersionRequired, secret.version(ref).enable());
    }
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "explicit version number") != null);
    // Production refuses `latest` for these three as well, so nothing was
    // lost by refusing here: no request went out at all.
    try h.expectRequestCount(0);

    // A number is what they take, and 0 is not one.
    try testing.expectError(error.InvalidResourceId, secret.version(.{ .number = 0 }).destroy());
    // Reading is different: any reference will do.
    var value = try secret.access(.latest);
    value.deinit();
    try h.expectRequestCount(1);
}

test "a version that cannot serve its bytes says so" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .status = 400, .body = "{\"error\":{\"status\":\"FAILED_PRECONDITION\",\"message\":\"Secret Version [projects/1/secrets/db/versions/1] is in DESTROYED state.\"}}" } },
        destroyed_version,
    }, .{});
    defer h.deinit();

    try testing.expectError(error.FailedPrecondition, h.client.secret("db-password").access(.{ .number = 1 }));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "DESTROYED state") != null);
    // The version itself is still there to look at, destroy time and all.
    var got = try h.client.secret("db-password").version(.{ .number = 1 }).get();
    defer got.deinit();
    try testing.expectEqual(.destroyed, got.value.state);
}

test "version administration: every allocation failure is OutOfMemory without leaks" {
    const Run = struct {
        fn run(gpa: std.mem.Allocator) !void {
            var fake: test_util.FakeTransport = .init(testing.allocator, &.{
                destroyed_version,
                destroyed_version,
                destroyed_version,
                destroyed_version,
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

            const version = client.secret("db-password").version(.{ .number = 1 });
            var got = try version.get();
            got.deinit();
            var off = try version.disable();
            off.deinit();
            var on = try version.enable();
            on.deinit();
            var gone = try version.destroy();
            gone.deinit();
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Run.run, .{});
}
