//! What becomes of a secret when a call goes wrong.
//!
//! Pub/Sub's fault suite drives the real HTTP stack through a proxy that
//! drops, cuts, trickles and rewrites responses. Secret Manager cannot be
//! driven that way: it has no emulator, every call carries a bearer token,
//! so the client refuses a cleartext endpoint, and std has no TLS server to
//! put behind one. The HTTP layer is shared, and covered there.
//!
//! What is this module's own is what happens to the secret when the answer
//! is wrong, so the faults go in at the `Transport` seam. Whatever the
//! sequence: a call returns bytes that match their checksum or it returns an
//! error, it leaks nothing, and it leaves no copy of the secret in memory.

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("core");

const Client = @import("Client.zig");
const test_util = @import("test_util.zig");
const testing = std.testing;

/// One way an answer can be wrong.
const Fault = enum {
    /// The payload, with the checksum that belongs to it.
    good,
    /// The payload, with a checksum that does not match.
    wrong_checksum,
    /// The payload, with no checksum at all.
    no_checksum,
    /// Base64 that stops in the middle of the payload.
    truncated_base64,
    /// Base64 with a byte that is not in the alphabet.
    corrupt_base64,
    /// A body that is not JSON.
    garbage_body,
    /// A body that stops mid-object.
    half_json,
    /// No body at all.
    empty_body,
    /// The right shape, with a checksum that is not a number.
    checksum_not_a_number,
    unauthorized,
    unavailable,
    too_many_requests,
    forbidden,
    not_found,
    server_error,
    dropped,
    timed_out,
    tls_failure,

    fn isTransportFailure(f: Fault) bool {
        return switch (f) {
            .dropped, .timed_out, .tls_failure => true,
            else => false,
        };
    }
};

/// A `Transport` that answers from a script of faults, building each body in
/// the arena it is handed, exactly as the real one does.
const FaultyTransport = struct {
    faults: []const Fault,
    payload: []const u8,
    next: usize = 0,
    requests: usize = 0,

    fn transport(self: *FaultyTransport) core.transport.Transport {
        return .{ .ptr = self, .vtable = &.{ .send = send } };
    }

    fn send(ptr: *anyopaque, req: core.transport.Request, arena: Allocator) core.transport.Error!core.transport.Response {
        const self: *FaultyTransport = @ptrCast(@alignCast(ptr));
        self.requests += 1;
        // A script that runs out repeats its last fault, so a retry policy
        // can never outrun it.
        const fault = if (self.faults.len == 0) .good else self.faults[@min(self.next, self.faults.len - 1)];
        self.next += 1;
        _ = req;

        return switch (fault) {
            .dropped => error.ConnectionResetByPeer,
            .timed_out => error.TimedOut,
            .tls_failure => error.TlsFailure,
            .unauthorized => canned(401),
            .unavailable => canned(503),
            .too_many_requests => canned(429),
            .forbidden => canned(403),
            .not_found => canned(404),
            .server_error => canned(500),
            .garbage_body => .{ .status = 200, .body = "<html>not json</html>" },
            .half_json => .{ .status = 200, .body = "{\"name\":\"v/1\",\"payload\":{\"data\":" },
            .empty_body => .{ .status = 200, .body = "" },
            .good, .wrong_checksum, .no_checksum, .truncated_base64, .corrupt_base64, .checksum_not_a_number => b: {
                const encoded = try arena.alloc(u8, core.base64.encodedLen(self.payload.len));
                _ = std.base64.standard.Encoder.encode(encoded, self.payload);
                const data = switch (fault) {
                    // Half the base64, which decodes to half a payload, or
                    // to nothing at all.
                    .truncated_base64 => encoded[0 .. encoded.len / 2],
                    .corrupt_base64 => c: {
                        if (encoded.len > 0) encoded[encoded.len / 2] = '*';
                        break :c encoded;
                    },
                    else => encoded,
                };
                const checksum: []const u8 = switch (fault) {
                    .wrong_checksum => ",\"dataCrc32c\":\"1\"",
                    .no_checksum => "",
                    .checksum_not_a_number => ",\"dataCrc32c\":\"not-a-number\"",
                    else => try std.fmt.allocPrint(arena, ",\"dataCrc32c\":\"{d}\"", .{core.crc32c.hash(self.payload)}),
                };
                break :b .{ .status = 200, .body = try std.fmt.allocPrint(
                    arena,
                    "{{\"name\":\"projects/1/secrets/db/versions/1\",\"payload\":{{\"data\":\"{s}\"{s}}}}}",
                    .{ data, checksum },
                ) };
            },
        };
    }

    /// A failure in the shape Google sends it. The body is static, so it
    /// needs no arena.
    fn canned(status: u16) core.transport.Response {
        return .{ .status = status, .body = switch (status) {
            401 => "{\"error\":{\"code\":401,\"status\":\"UNAUTHENTICATED\",\"message\":\"Invalid Credentials\"}}",
            403 => "{\"error\":{\"code\":403,\"status\":\"PERMISSION_DENIED\",\"message\":\"denied\"}}",
            404 => "{\"error\":{\"code\":404,\"status\":\"NOT_FOUND\",\"message\":\"no such secret\"}}",
            429 => "{\"error\":{\"code\":429,\"status\":\"RESOURCE_EXHAUSTED\",\"message\":\"quota\"}}",
            500 => "{\"error\":{\"code\":500,\"status\":\"INTERNAL\",\"message\":\"fault\"}}",
            else => "{\"error\":{\"code\":503,\"status\":\"UNAVAILABLE\",\"message\":\"try later\"}}",
        } };
    }
};

/// The payload the properties move around. Long enough to span more than one
/// allocation, and recognizable in a memory dump.
const payload = "S3CR3T-payload-" ** 20;

const Outcome = struct {
    /// Null when the call failed.
    verified: ?bool = null,
    /// How many bytes came back, when any did.
    bytes_len: usize = 0,
    err: ?anyerror = null,
    requests: usize,
};

/// Runs one `access` against `faults`, with `gpa` underneath the client, and
/// checks what the caller is handed.
fn runAccess(gpa: Allocator, faults: []const Fault, mode: @import("types.zig").ChecksumMode) !Outcome {
    var faulty: FaultyTransport = .{ .faults = faults, .payload = payload };
    var clock: test_util.FakeClock = .{};
    var token: test_util.FakeTokenProvider = .{ .token = "ya29.token-that-must-not-linger" };
    var diag: core.Diagnostics = .{};
    var client = try Client.init(gpa, clock.io(), .{
        .project_id = "extractctl",
        .token_provider = token.provider(),
        .verify_checksum = mode,
        .retry = .{ .max_attempts = 3 },
        .diagnostics = &diag,
        .transport = faulty.transport(),
    });
    defer client.deinit();

    if (client.secret("db-password").access(.latest)) |result| {
        var value = result;
        defer value.deinit();
        if (value.checksum_verified) {
            // Verified means verified: these are the bytes that were stored.
            try testing.expectEqualSlices(u8, payload, value.bytes());
        } else {
            // Unverified bytes can only come from a mode that allows them.
            try testing.expect(mode != .required);
        }
        // A success says nothing about an earlier failure.
        try testing.expectEqual(0, diag.http_status);
        return .{
            .verified = value.checksum_verified,
            .bytes_len = value.bytes().len,
            .requests = faulty.requests,
        };
    } else |err| {
        // A failure always leaves something to report.
        try testing.expect(diag.http_status != 0 or diag.message().len > 0);
        return .{ .err = err, .requests = faulty.requests };
    }
}

fn accessProperty(_: void, input: []const u8) !void {
    var g: test_util.ByteGen = .init(input);
    const mode = g.pick(@import("types.zig").ChecksumMode, &.{ .required, .if_present, .off });
    var faults: [6]Fault = undefined;
    const count = g.intRange(usize, 1, faults.len);
    for (faults[0..count]) |*fault| fault.* = g.pick(Fault, std.enums.values(Fault));

    // Leak-checked: the testing allocator fails the test if anything is left.
    const outcome = try runAccess(testing.allocator, faults[0..count], mode);
    try testing.expect(outcome.requests >= 1);
    // The worst case is every attempt of the retry policy (3 here), each
    // fetched again after a checksum mismatch, and each of those allowed
    // one extra request by the 401 re-authentication.
    try testing.expect(outcome.requests <= 3 * (3 + 1));
    if (outcome.verified) |verified| {
        // `.off` never claims verification; `.required` never returns
        // without it.
        if (mode == .off) try testing.expect(!verified);
        if (mode == .required) try testing.expect(verified);
    }

    // Memory-scanned: the same run on a buffer the test can read afterwards.
    var backing: [512 * 1024]u8 = @splat(0);
    var fba: std.heap.FixedBufferAllocator = .init(&backing);
    const again = runAccess(fba.allocator(), faults[0..count], mode) catch |err| switch (err) {
        // The buffer is generous; if it ever runs out, the scan below would
        // be meaningless.
        error.OutOfMemory => return,
        else => return err,
    };
    try testing.expectEqual(outcome.err != null, again.err != null);
    // Whatever happened, nothing of the secret is left: not the bytes, not
    // the base64 they travelled in, not the token they were asked for with.
    try testing.expectEqual(null, std.mem.indexOf(u8, &backing, payload));
    try testing.expectEqual(null, std.mem.indexOf(u8, &backing, "ya29.token-that-must-not-linger"));
    var encoded: [core.base64.encodedLen(payload.len)]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&encoded, payload);
    try testing.expectEqual(null, std.mem.indexOf(u8, &backing, encoded[0 .. encoded.len / 2]));
}

test "fuzz faults: access returns verified bytes or an error, and keeps nothing" {
    try test_util.fuzzBytes({}, accessProperty, .{
        .corpus = &.{
            // Generated to the shape ByteGen reads: an 8-byte pick, an 8-byte
            // count, then one 8-byte pick per fault.
            "\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00",
            "\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x02\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00",
            "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x00\x00\x00\x00\x00\x00\x02\x00\x00\x00\x00\x00\x00\x00\x00",
            "\x00\x00\x00\x00\x00\x00\x00\x02\x00\x00\x00\x00\x00\x00\x00\x03\x00\x00\x00\x00\x00\x00\x00\x03\x00\x00\x00\x00\x00\x00\x00\x04\x00\x00\x00\x00\x00\x00\x00\x00",
            "\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x04\x00\x00\x00\x00\x00\x00\x00\x0f\x00\x00\x00\x00\x00\x00\x00\x10\x00\x00\x00\x00\x00\x00\x00\x11\x00\x00\x00\x00\x00\x00\x00\x00",
        },
    });
}

test "faults: a checksum that never matches is an error, whatever else happens" {
    const outcome = try runAccess(testing.allocator, &.{ .unavailable, .wrong_checksum, .wrong_checksum, .wrong_checksum }, .if_present);
    try testing.expectEqual(error.ChecksumMismatch, outcome.err.?);
}

test "faults: a dropped connection is retried, and a good answer still arrives" {
    const outcome = try runAccess(testing.allocator, &.{ .dropped, .timed_out, .good }, .required);
    try testing.expect(outcome.verified.?);
    try testing.expectEqual(3, outcome.requests);
}

test "faults: a body that is not an answer is never retried" {
    for ([_]Fault{ .garbage_body, .half_json, .corrupt_base64, .checksum_not_a_number }) |fault| {
        const outcome = try runAccess(testing.allocator, &.{fault}, .if_present);
        try testing.expectEqual(error.InvalidResponse, outcome.err.?);
        try testing.expectEqual(1, outcome.requests);
    }
    // Truncated base64 decodes to bytes that are not the payload, so the
    // checksum catches it instead.
    const truncated = try runAccess(testing.allocator, &.{.truncated_base64}, .if_present);
    try testing.expectEqual(error.ChecksumMismatch, truncated.err.?);
}

test "faults: an empty body is an answer with nothing in it" {
    // A 200 with no body decodes to a value with no bytes and no checksum:
    // `.required` refuses it, `.if_present` hands back what there was.
    try testing.expectEqual(error.MissingChecksum, (try runAccess(testing.allocator, &.{.empty_body}, .required)).err.?);
    const outcome = try runAccess(testing.allocator, &.{.empty_body}, .if_present);
    try testing.expectEqual(0, outcome.bytes_len);
    try testing.expect(!outcome.verified.?);
}

test "faults: with checking off, a truncated answer is the caller's problem" {
    // Half the base64 decodes to half a payload. With `.required` or
    // `.if_present` the checksum catches it; with `.off` nothing does, and
    // the short bytes come back as if they were whole. That is what `.off`
    // means, and why it is not the default.
    const outcome = try runAccess(testing.allocator, &.{.truncated_base64}, .off);
    try testing.expect(outcome.bytes_len > 0);
    try testing.expect(outcome.bytes_len < payload.len);
    try testing.expect(!outcome.verified.?);
    for ([_]@import("types.zig").ChecksumMode{ .required, .if_present }) |mode| {
        const caught = try runAccess(testing.allocator, &.{.truncated_base64}, mode);
        try testing.expectEqual(error.ChecksumMismatch, caught.err.?);
    }
}

test "faults: the 401 retry happens once, then the error is the caller's" {
    const once = try runAccess(testing.allocator, &.{ .unauthorized, .good }, .required);
    try testing.expect(once.verified.?);
    try testing.expectEqual(2, once.requests);

    const twice = try runAccess(testing.allocator, &.{ .unauthorized, .unauthorized, .good }, .required);
    try testing.expectEqual(error.Unauthenticated, twice.err.?);
    try testing.expectEqual(2, twice.requests);
}
