//! Google API errors: the error body every Google REST API returns, one Zig
//! error per canonical status, and `Diagnostics` for the details a Zig error
//! cannot carry.

const std = @import("std");
const Allocator = std.mem.Allocator;
const test_util = @import("testing.zig");

/// One error per canonical Google API status, except OK. Client-side
/// argument checks also return `InvalidArgument`, as the server would.
pub const ApiError = error{
    /// The request was malformed: a bad name, a value out of range.
    InvalidArgument,
    /// The resource is not in a state that allows the call.
    FailedPrecondition,
    OutOfRange,
    /// Credentials were missing, expired or invalid.
    Unauthenticated,
    PermissionDenied,
    NotFound,
    AlreadyExists,
    Aborted,
    /// Quota or rate limit exceeded. Retried.
    ResourceExhausted,
    /// The server reports the request as cancelled: status CANCELLED, HTTP
    /// 499. Not to be confused with `error.Canceled`, which means this task's
    /// `std.Io` operation was canceled.
    ServerCancelled,
    /// Retried.
    Internal,
    DataLoss,
    Unknown,
    Unimplemented,
    /// Also returned for HTTP 502. Retried.
    Unavailable,
    /// Retried.
    DeadlineExceeded,
    /// HTTP 304: an `if...NotMatch` condition sent with the request was
    /// met by the current resource, so there is nothing new to return. An
    /// answer, not a failure; never retried.
    NotModified,
};

const by_status = std.StaticStringMap(ApiError).initComptime(.{
    .{ "INVALID_ARGUMENT", error.InvalidArgument },
    .{ "FAILED_PRECONDITION", error.FailedPrecondition },
    .{ "OUT_OF_RANGE", error.OutOfRange },
    .{ "UNAUTHENTICATED", error.Unauthenticated },
    .{ "PERMISSION_DENIED", error.PermissionDenied },
    .{ "NOT_FOUND", error.NotFound },
    .{ "ALREADY_EXISTS", error.AlreadyExists },
    .{ "ABORTED", error.Aborted },
    .{ "RESOURCE_EXHAUSTED", error.ResourceExhausted },
    .{ "CANCELLED", error.ServerCancelled },
    .{ "INTERNAL", error.Internal },
    .{ "DATA_LOSS", error.DataLoss },
    .{ "UNKNOWN", error.Unknown },
    .{ "UNIMPLEMENTED", error.Unimplemented },
    .{ "UNAVAILABLE", error.Unavailable },
    .{ "DEADLINE_EXCEEDED", error.DeadlineExceeded },
    // Not a canonical status, but Google's front ends report it for HTTP 502.
    .{ "BAD_GATEWAY", error.Unavailable },
});

/// Maps a failed response. The `status` string from the error body decides,
/// because two statuses share HTTP 400; when it is missing or unknown, the
/// HTTP status decides.
pub fn fromResponse(http_status: u16, status: []const u8) ApiError {
    return by_status.get(status) orelse fromHttpStatus(http_status);
}

/// Maps an HTTP status alone, for error bodies that are not JSON, such as a
/// proxy's HTML page.
pub fn fromHttpStatus(http_status: u16) ApiError {
    return switch (http_status) {
        304 => error.NotModified,
        400, 413 => error.InvalidArgument,
        401 => error.Unauthenticated,
        403 => error.PermissionDenied,
        404 => error.NotFound,
        408, 504 => error.DeadlineExceeded,
        409 => error.AlreadyExists,
        412 => error.FailedPrecondition,
        416 => error.OutOfRange,
        429 => error.ResourceExhausted,
        499 => error.ServerCancelled,
        500 => error.Internal,
        501 => error.Unimplemented,
        502, 503 => error.Unavailable,
        else => error.Unknown,
    };
}

/// The parts of a Google API error body that `fromResponse` and
/// `Diagnostics` use.
pub const ErrorBody = struct {
    /// Such as "NOT_FOUND"; "" when absent.
    status: []const u8,
    message: []const u8,
};

const WireErrorBody = struct {
    @"error": ?struct {
        status: ?[]const u8 = null,
        message: ?[]const u8 = null,
        // The older shape, which Cloud Storage still uses: no status, and
        // a list of errors whose `reason` is a camelCase word.
        errors: ?[]const struct {
            reason: ?[]const u8 = null,
        } = null,
    } = null,
};

/// The standard Google error body, `{"error": {"status": ..., "message":
/// ...}}`, or null when `body` is not one (a proxy's HTML page, say), in
/// which case the caller falls back to the HTTP status. Running out of
/// memory is an error, not a body that failed to decode: the fallback could
/// report the wrong error, since statuses share HTTP codes. The strings may
/// point into `body`.
///
/// Cloud Storage sends an older shape with no `status`; there the first
/// error's `reason`, such as "notFound", stands in as the status. No reason
/// is a canonical status name, so mapping still falls back to the HTTP code
/// while diagnostics keep the server's word.
pub fn decodeErrorBody(arena: Allocator, body: []const u8) Allocator.Error!?ErrorBody {
    const wire = std.json.parseFromSliceLeaky(WireErrorBody, arena, body, .{
        .ignore_unknown_fields = true,
        // Proto3 JSON parsers keep the last duplicate rather than failing.
        .duplicate_field_behavior = .use_last,
        .allocate = .alloc_if_needed,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    const e = wire.@"error" orelse return null;
    const reason: ?[]const u8 = if (e.errors) |list|
        if (list.len > 0) list[0].reason else null
    else
        null;
    return .{ .status = e.status orelse reason orelse "", .message = e.message orelse "" };
}

/// Details of the most recent failed call. Zig errors carry no payload, so
/// pass `&diagnostics` in a client's options, such as Pub/Sub's
/// `Client.Options`, and read it after a call fails. A call that succeeds
/// clears it. Not safe to share across concurrent tasks.
pub const Diagnostics = struct {
    /// HTTP status of the failed response, or 0 when the call failed without
    /// one: client-side validation, a connection error, cancellation.
    http_status: u16 = 0,
    status_len: u8 = 0,
    message_len: u16 = 0,
    buffer: [512]u8 = undefined,

    /// Longest status kept. Real statuses are short, like "FAILED_PRECONDITION".
    pub const max_status_len = 64;

    /// The API status, such as "NOT_FOUND", or "" when there is none.
    pub fn status(d: *const Diagnostics) []const u8 {
        return d.buffer[0..d.status_len];
    }

    /// The server's message, or a client-side description of the failure,
    /// truncated to the buffer at a UTF-8 boundary.
    pub fn message(d: *const Diagnostics) []const u8 {
        return d.buffer[d.status_len..][0..d.message_len];
    }

    pub fn clear(d: *Diagnostics) void {
        d.* = .{};
    }

    /// Records a failure, copying `status_text` and `message_text`, which must
    /// not point into `d.buffer`.
    pub fn set(d: *Diagnostics, http_status: u16, status_text: []const u8, message_text: []const u8) void {
        d.http_status = http_status;
        const s = truncateUtf8(status_text, max_status_len);
        @memcpy(d.buffer[0..s.len], s);
        d.status_len = @intCast(s.len);
        const m = truncateUtf8(message_text, d.buffer.len - s.len);
        @memcpy(d.buffer[s.len..][0..m.len], m);
        d.message_len = @intCast(m.len);
    }

    /// Records a failure that has no HTTP response, with a formatted message.
    pub fn print(d: *Diagnostics, comptime format: []const u8, args: anytype) void {
        d.http_status = 0;
        d.status_len = 0;
        var w: std.Io.Writer = .fixed(&d.buffer);
        w.print(format, args) catch {}; // Keeps whatever fit.
        d.message_len = @intCast(truncateUtf8(w.buffered(), d.buffer.len).len);
    }
};

/// The longest prefix of `text` that fits in `max` bytes without splitting a
/// UTF-8 sequence. Invalid UTF-8 is cut at `max` bytes or up to 3 before it.
pub fn truncateUtf8(text: []const u8, max: usize) []const u8 {
    if (text.len <= max) return text;
    var cut = max;
    var steps: usize = 0;
    // A continuation byte at the cut means a sequence started before it.
    while (cut > 0 and steps < 3 and text[cut] & 0xC0 == 0x80) : (steps += 1) cut -= 1;
    return text[0..cut];
}

const testing = std.testing;

test "error table: each API status maps to its error" {
    // One case per row of the spec's error table.
    const cases = [_]struct { []const u8, u16, ApiError }{
        .{ "INVALID_ARGUMENT", 400, error.InvalidArgument },
        .{ "FAILED_PRECONDITION", 400, error.FailedPrecondition },
        .{ "UNAUTHENTICATED", 401, error.Unauthenticated },
        .{ "PERMISSION_DENIED", 403, error.PermissionDenied },
        .{ "NOT_FOUND", 404, error.NotFound },
        .{ "ALREADY_EXISTS", 409, error.AlreadyExists },
        .{ "RESOURCE_EXHAUSTED", 429, error.ResourceExhausted },
        .{ "CANCELLED", 499, error.ServerCancelled },
        .{ "INTERNAL", 500, error.Internal },
        .{ "BAD_GATEWAY", 502, error.Unavailable },
        .{ "UNAVAILABLE", 503, error.Unavailable },
        .{ "DEADLINE_EXCEEDED", 504, error.DeadlineExceeded },
    };
    for (cases) |c| {
        try testing.expectEqual(c[2], fromResponse(c[1], c[0]));
        // With the body missing, the HTTP code alone gives the same answer,
        // except where statuses share a code.
        if (!std.mem.eql(u8, c[0], "FAILED_PRECONDITION")) {
            try testing.expectEqual(c[2], fromHttpStatus(c[1]));
        }
    }
}

test "error mapping: the other canonical statuses" {
    try testing.expectEqual(error.OutOfRange, fromResponse(400, "OUT_OF_RANGE"));
    try testing.expectEqual(error.Aborted, fromResponse(409, "ABORTED"));
    try testing.expectEqual(error.DataLoss, fromResponse(500, "DATA_LOSS"));
    try testing.expectEqual(error.Unknown, fromResponse(500, "UNKNOWN"));
    try testing.expectEqual(error.Unimplemented, fromResponse(501, "UNIMPLEMENTED"));
}

test "error mapping: status wins over HTTP code; unknown status falls back" {
    try testing.expectEqual(error.FailedPrecondition, fromResponse(400, "FAILED_PRECONDITION"));
    try testing.expectEqual(error.NotFound, fromResponse(404, "SOMETHING_NEW"));
    try testing.expectEqual(error.NotFound, fromResponse(404, ""));
    try testing.expectEqual(error.NotFound, fromResponse(404, "not_found"));
    try testing.expectEqual(error.Unknown, fromResponse(418, ""));
    try testing.expectEqual(error.Unknown, fromResponse(302, ""));
    try testing.expectEqual(error.DeadlineExceeded, fromHttpStatus(408));
    try testing.expectEqual(error.InvalidArgument, fromHttpStatus(413));
    // The statuses Cloud Storage's preconditions and ranges answer with.
    try testing.expectEqual(error.FailedPrecondition, fromHttpStatus(412));
    try testing.expectEqual(error.OutOfRange, fromHttpStatus(416));
    // 304 is an answer to a conditional read, not a failure.
    try testing.expectEqual(error.NotModified, fromHttpStatus(304));
    try testing.expectEqual(error.NotModified, fromResponse(304, ""));
}

test "decode the older error shape Cloud Storage sends" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // No `status` string; the first error's `reason` stands in.
    const e = (try decodeErrorBody(a,
        \\{"error":{"code":404,"message":"No such object: my-bucket/missing.txt",
        \\"errors":[{"message":"No such object: my-bucket/missing.txt","domain":"global","reason":"notFound"}]}}
    )).?;
    try testing.expectEqualStrings("notFound", e.status);
    try testing.expectEqualStrings("No such object: my-bucket/missing.txt", e.message);
    // A camelCase reason is not a canonical status: the HTTP code decides.
    try testing.expectEqual(error.NotFound, fromResponse(404, e.status));
    try testing.expectEqual(error.FailedPrecondition, fromResponse(412, "conditionNotMet"));

    // A `status` string still wins over a reason.
    const both = (try decodeErrorBody(a,
        \\{"error":{"status":"NOT_FOUND","errors":[{"reason":"somethingElse"}]}}
    )).?;
    try testing.expectEqualStrings("NOT_FOUND", both.status);

    // An empty error list, and a reason-less entry.
    const empty = (try decodeErrorBody(a, "{\"error\":{\"code\":500,\"errors\":[]}}")).?;
    try testing.expectEqualStrings("", empty.status);
    const bare = (try decodeErrorBody(a, "{\"error\":{\"code\":500,\"errors\":[{\"domain\":\"global\"}]}}")).?;
    try testing.expectEqualStrings("", bare.status);
    // `errors` that is not a list makes the body unreadable, not a crash.
    try testing.expectEqual(null, try decodeErrorBody(a, "{\"error\":{\"errors\":42}}"));
}

test "Diagnostics.set copies and truncates" {
    var d: Diagnostics = .{};
    try testing.expectEqualStrings("", d.status());
    try testing.expectEqualStrings("", d.message());

    d.set(404, "NOT_FOUND", "Resource not found (resource=orders).");
    try testing.expectEqual(404, d.http_status);
    try testing.expectEqualStrings("NOT_FOUND", d.status());
    try testing.expectEqualStrings("Resource not found (resource=orders).", d.message());

    // A copy stays valid: accessors index the copy's own buffer.
    const copy = d;
    d.clear();
    try testing.expectEqualStrings("NOT_FOUND", copy.status());
    try testing.expectEqualStrings("", d.status());

    const long: [2000]u8 = @splat('m');
    d.set(500, &@as([100]u8, @splat('S')), &long);
    try testing.expectEqual(Diagnostics.max_status_len, d.status().len);
    try testing.expectEqual(d.buffer.len - Diagnostics.max_status_len, d.message().len);
}

test "Diagnostics.set never splits a UTF-8 sequence" {
    var d: Diagnostics = .{};
    // 170 three-byte characters are 510 bytes; the 171st straddles the end.
    const text = "€" ** 171;
    d.set(400, "", text);
    try testing.expect(std.unicode.utf8ValidateSlice(d.message()));
    try testing.expectEqual(510, d.message().len);
}

test "Diagnostics.print formats client-side failures" {
    var d: Diagnostics = .{};
    d.set(503, "UNAVAILABLE", "x");
    d.print("message {d}: attribute key is {d} bytes", .{ 3, 300 });
    try testing.expectEqual(0, d.http_status);
    try testing.expectEqualStrings("", d.status());
    try testing.expectEqualStrings("message 3: attribute key is 300 bytes", d.message());

    const long: [600]u8 = @splat('x');
    d.print("{s}", .{&long});
    try testing.expectEqual(d.buffer.len, d.message().len);
}

fn truncateProperty(_: void, input: []const u8) !void {
    var g: test_util.ByteGen = .init(input);
    const max = g.intRange(usize, 0, 64);
    const text = g.rest();
    const out = truncateUtf8(text, max);
    try testing.expect(out.len <= max or out.len == text.len);
    try testing.expect(std.mem.startsWith(u8, text, out));
    if (text.len > max) try testing.expect(out.len + 3 >= max);
    if (std.unicode.utf8ValidateSlice(text)) try testing.expect(std.unicode.utf8ValidateSlice(out));
}

test "fuzz truncateUtf8: prefix, bounded, keeps valid UTF-8 valid" {
    try test_util.fuzzBytes({}, truncateProperty, .{ .corpus = &.{
        "\x05€€€€",
        "\x04\xf0\x9f\x98\x80\xf0\x9f\x98\x80",
        "\x02\x80\x80\x80\x80\x80",
        "\x00abc",
    } });
}

fn mappingProperty(_: void, input: []const u8) !void {
    var g: test_util.ByteGen = .init(input);
    const code = g.int(u16);
    const status = g.rest();
    // Total: every input maps to some error without panicking, and a known
    // status always wins over the HTTP code.
    const err = fromResponse(code, status);
    if (by_status.get(status)) |expected| try testing.expectEqual(expected, err);
}

test "fuzz error mapping is total" {
    try test_util.fuzzBytes({}, mappingProperty, .{ .corpus = &.{
        "\x01\x90NOT_FOUND",
        "\x01\x90",
        "\xff\xffBAD_GATEWAY",
    } });
}

test "decode error bodies" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const e = (try decodeErrorBody(a, "{\"error\":{\"code\":404,\"message\":\"Topic not found\",\"status\":\"NOT_FOUND\"}}")).?;
    try testing.expectEqualStrings("NOT_FOUND", e.status);
    try testing.expectEqualStrings("Topic not found", e.message);

    const detailed = (try decodeErrorBody(a,
        \\{"error":{"code":400,"message":"bad","status":"INVALID_ARGUMENT",
        \\"details":[{"@type":"type.googleapis.com/google.rpc.ErrorInfo","reason":"X"}]}}
    )).?;
    try testing.expectEqualStrings("INVALID_ARGUMENT", detailed.status);

    try testing.expectEqual(null, try decodeErrorBody(a, "Not Found"));
    try testing.expectEqual(null, try decodeErrorBody(a, ""));
    try testing.expectEqual(null, try decodeErrorBody(a, "{}"));
    try testing.expectEqual(null, try decodeErrorBody(a, "{\"error\":\"string\"}"));
    const partial = try decodeErrorBody(a, "{\"error\":{\"code\":\"weird\"}}");
    try testing.expectEqualStrings("", partial.?.status);
}

test "decodeErrorBody reports running out of memory, not an unreadable body" {
    // Regression: it returned null, so the caller fell back to the HTTP
    // status, which can name the wrong error, and the out-of-memory error
    // never surfaced. An allocation-failure sweep of the token path found it.
    try testing.expectError(
        error.OutOfMemory,
        decodeErrorBody(testing.failing_allocator, "{\"error\":{\"status\":\"FAILED_PRECONDITION\"}}"),
    );
}

fn decodeErrorBodyArbitrary(_: void, input: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    // Total: any body decodes to an error body or to null, never a crash.
    const body = (try decodeErrorBody(arena.allocator(), input)) orelse return;
    // A status the mapping knows always decides the error.
    if (by_status.get(body.status)) |expected| try testing.expectEqual(expected, fromResponse(500, body.status));
}

test "fuzz decodeErrorBody: arbitrary bodies never crash" {
    try test_util.fuzzBytes({}, decodeErrorBodyArbitrary, .{ .corpus = &.{
        "{\"error\":{\"code\":404,\"message\":\"m\",\"status\":\"NOT_FOUND\"}}",
        "{\"error\":{\"status\":\"UNAVAILABLE\",\"status\":\"INTERNAL\"}}",
        "{\"error\":{\"message\":\"\\ud800\"}}",
        "{\"error\":null}",
        "<html>502 Bad Gateway</html>",
    } });
}
