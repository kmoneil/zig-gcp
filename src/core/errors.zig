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

/// Maps a numeric `google.rpc.Code`, as a long-running operation's `error`
/// carries one. The numbering is canonical and fixed; anything unlisted is
/// `Unknown`, as a status string this library does not know would be.
pub fn fromRpcCode(code: i64) ApiError {
    return switch (code) {
        1 => error.ServerCancelled,
        2 => error.Unknown,
        3 => error.InvalidArgument,
        4 => error.DeadlineExceeded,
        5 => error.NotFound,
        6 => error.AlreadyExists,
        7 => error.PermissionDenied,
        8 => error.ResourceExhausted,
        9 => error.FailedPrecondition,
        10 => error.Aborted,
        11 => error.OutOfRange,
        12 => error.Unimplemented,
        13 => error.Internal,
        14 => error.Unavailable,
        15 => error.DataLoss,
        16 => error.Unauthenticated,
        else => error.Unknown,
    };
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

/// One `google.rpc.ErrorInfo` from an error body's `details`: why a call
/// failed, in words a program can match, with facts about it in
/// `metadata`, such as which ack ids Pub/Sub refused.
pub const ErrorInfo = struct {
    /// Such as "EXACTLY_ONCE_ACKID_FAILURE"; "" when absent.
    reason: []const u8,
    /// Such as "pubsub.googleapis.com"; "" when absent.
    domain: []const u8,
    /// The entries of `metadata` whose values are strings, as sent.
    metadata: []const Entry,

    pub const Entry = struct {
        key: []const u8,
        value: []const u8,
    };
};

const error_info_type = "type.googleapis.com/google.rpc.ErrorInfo";

const WireDetails = struct {
    @"error": ?struct {
        details: ?[]const std.json.Value = null,
    } = null,
};

/// Every `google.rpc.ErrorInfo` in an error body's `details`, in order,
/// skipping every other kind of detail. Empty when there is none, or when
/// `body` is not Google's JSON error shape. Running out of memory is an
/// error, as it is for `decodeErrorBody`.
pub fn decodeErrorInfos(arena: Allocator, body: []const u8) Allocator.Error![]const ErrorInfo {
    const wire = std.json.parseFromSliceLeaky(WireDetails, arena, body, .{
        .ignore_unknown_fields = true,
        // Proto3 JSON parsers keep the last duplicate rather than failing.
        .duplicate_field_behavior = .use_last,
        .allocate = .alloc_if_needed,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return &.{},
    };
    const e = wire.@"error" orelse return &.{};
    const details = e.details orelse return &.{};
    var infos: std.ArrayList(ErrorInfo) = .empty;
    for (details) |detail| {
        const fields = switch (detail) {
            .object => |o| o,
            else => continue,
        };
        const type_url = stringOf(fields.get("@type")) orelse continue;
        if (!std.mem.eql(u8, type_url, error_info_type)) continue;
        var metadata: std.ArrayList(ErrorInfo.Entry) = .empty;
        if (fields.get("metadata")) |value| switch (value) {
            .object => |entries| {
                try metadata.ensureTotalCapacity(arena, entries.count());
                var it = entries.iterator();
                while (it.next()) |entry| {
                    const text = stringOf(entry.value_ptr.*) orelse continue;
                    metadata.appendAssumeCapacity(.{ .key = entry.key_ptr.*, .value = text });
                }
            },
            else => {},
        };
        try infos.append(arena, .{
            .reason = stringOf(fields.get("reason")) orelse "",
            .domain = stringOf(fields.get("domain")) orelse "",
            .metadata = metadata.items,
        });
    }
    return infos.items;
}

fn stringOf(value: ?std.json.Value) ?[]const u8 {
    return switch (value orelse return null) {
        .string => |text| text,
        else => null,
    };
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

test "error mapping: every canonical rpc code, and the unlisted ones" {
    try std.testing.expectEqual(error.ServerCancelled, fromRpcCode(1));
    try std.testing.expectEqual(error.InvalidArgument, fromRpcCode(3));
    try std.testing.expectEqual(error.NotFound, fromRpcCode(5));
    try std.testing.expectEqual(error.AlreadyExists, fromRpcCode(6));
    try std.testing.expectEqual(error.PermissionDenied, fromRpcCode(7));
    try std.testing.expectEqual(error.ResourceExhausted, fromRpcCode(8));
    try std.testing.expectEqual(error.FailedPrecondition, fromRpcCode(9));
    try std.testing.expectEqual(error.Aborted, fromRpcCode(10));
    try std.testing.expectEqual(error.Unavailable, fromRpcCode(14));
    try std.testing.expectEqual(error.Unauthenticated, fromRpcCode(16));
    try std.testing.expectEqual(error.Unknown, fromRpcCode(0));
    try std.testing.expectEqual(error.Unknown, fromRpcCode(2));
    try std.testing.expectEqual(error.Unknown, fromRpcCode(17));
    try std.testing.expectEqual(error.Unknown, fromRpcCode(-1));
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

test "decodeErrorInfos: Pub/Sub's refusal of late acks, as production sent it" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Captured from an exactly-once subscription on 2026-09-27, with the
    // ack ids shortened and a second entry added.
    const body =
        \\{"error":{"code":400,"message":"Some acknowledgement ids in the request were invalid. This could be because the acknowledgement ids have expired or the acknowledgement ids were malformed.","status":"INVALID_ARGUMENT",
        \\"details":[{"@type":"type.googleapis.com/google.rpc.ErrorInfo","reason":"EXACTLY_ONCE_ACKID_FAILURE","domain":"pubsub.googleapis.com",
        \\"metadata":{"NkIDDwQhIT4w":"PERMANENT_FAILURE_INVALID_ACK_ID","QgMPBCEhPjA-":"TRANSIENT_FAILURE_ACK_ID"}}]}}
    ;
    const infos = try decodeErrorInfos(a, body);
    try testing.expectEqual(1, infos.len);
    try testing.expectEqualStrings("EXACTLY_ONCE_ACKID_FAILURE", infos[0].reason);
    try testing.expectEqualStrings("pubsub.googleapis.com", infos[0].domain);
    try testing.expectEqual(2, infos[0].metadata.len);
    try testing.expectEqualStrings("NkIDDwQhIT4w", infos[0].metadata[0].key);
    try testing.expectEqualStrings("PERMANENT_FAILURE_INVALID_ACK_ID", infos[0].metadata[0].value);
    try testing.expectEqualStrings("QgMPBCEhPjA-", infos[0].metadata[1].key);
    try testing.expectEqualStrings("TRANSIENT_FAILURE_ACK_ID", infos[0].metadata[1].value);
    // The status and the message read as they always did.
    const e = (try decodeErrorBody(a, body)).?;
    try testing.expectEqualStrings("INVALID_ARGUMENT", e.status);
}

test "decodeErrorInfos: other details are skipped, and every ErrorInfo is kept in order" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const infos = try decodeErrorInfos(arena.allocator(),
        \\{"error":{"code":403,"details":[
        \\{"@type":"type.googleapis.com/google.rpc.DebugInfo","detail":"x","reason":"NOT_THIS"},
        \\{"@type":"type.googleapis.com/google.rpc.ErrorInfo","domain":"iam.googleapis.com","reason":"IAM_PERMISSION_DENIED",
        \\"metadata":{"permission":"pubsub.subscriptions.get","count":3,"nothing":null,"list":["a"],"nested":{"k":"v"},"esc\"aped":"line\nbreak \u00e9"}},
        \\"a string, not an object",
        \\{"@type":"type.googleapis.com/google.rpc.Help","links":[]},
        \\{"reason":"no type at all"},
        \\{"@type":"type.googleapis.com/google.rpc.ErrorInfo"}
        \\]}}
    );
    try testing.expectEqual(2, infos.len);
    try testing.expectEqualStrings("IAM_PERMISSION_DENIED", infos[0].reason);
    try testing.expectEqualStrings("iam.googleapis.com", infos[0].domain);
    // Only the string entries, unescaped.
    try testing.expectEqual(2, infos[0].metadata.len);
    try testing.expectEqualStrings("permission", infos[0].metadata[0].key);
    try testing.expectEqualStrings("pubsub.subscriptions.get", infos[0].metadata[0].value);
    try testing.expectEqualStrings("esc\"aped", infos[0].metadata[1].key);
    try testing.expectEqualStrings("line\nbreak \u{e9}", infos[0].metadata[1].value);
    // An ErrorInfo with nothing in it still counts, with empty fields.
    try testing.expectEqualStrings("", infos[1].reason);
    try testing.expectEqualStrings("", infos[1].domain);
    try testing.expectEqual(0, infos[1].metadata.len);
}

test "decodeErrorInfos: a body without one gives none" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{
        "",
        "Not Found",
        "<html>502 Bad Gateway</html>",
        "{}",
        "{\"error\":null}",
        "{\"error\":\"string\"}",
        "{\"error\":{\"code\":400,\"message\":\"no details\"}}",
        "{\"error\":{\"details\":null}}",
        "{\"error\":{\"details\":[]}}",
        "{\"error\":{\"details\":\"not a list\"}}",
        "{\"error\":{\"details\":[{\"@type\":7}]}}",
        "{\"error\":{\"details\":[{\"@type\":\"type.googleapis.com/google.rpc.ErrorInfoX\"}]}}",
    }) |body| try testing.expectEqual(0, (try decodeErrorInfos(a, body)).len);
}

fn decodeErrorInfosWith(gpa: Allocator, body: []const u8) !void {
    // An arena per call: one that an earlier call grew would serve this
    // one from spare room, and the sweep would miss allocations.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const infos = try decodeErrorInfos(arena.allocator(), body);
    try testing.expectEqual(2, infos.len);
}

test "decodeErrorInfos: every allocation failure is OutOfMemory without leaks" {
    try testing.checkAllAllocationFailures(testing.allocator, decodeErrorInfosWith, .{
        \\{"error":{"code":400,"status":"INVALID_ARGUMENT","details":[
        \\{"@type":"type.googleapis.com/google.rpc.ErrorInfo","reason":"R\u00e9","domain":"d",
        \\"metadata":{"a\"1":"PERMANENT_FAILURE_INVALID_ACK_ID","b":"TRANSIENT_FAILURE_ACK_ID","c":5}},
        \\{"@type":"type.googleapis.com/google.rpc.DebugInfo"},
        \\{"@type":"type.googleapis.com/google.rpc.ErrorInfo","metadata":{}}]}}
        ,
    });
}

fn decodeErrorInfosArbitrary(_: void, input: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    // Total: any body decodes to some list, never a crash, and the error
    // body decoder agrees that a body with an ErrorInfo is an error body.
    const infos = try decodeErrorInfos(arena.allocator(), input);
    if (infos.len > 0) try testing.expect((try decodeErrorBody(arena.allocator(), input)) != null);
}

test "fuzz decodeErrorInfos: arbitrary bodies never crash" {
    try test_util.fuzzBytes({}, decodeErrorInfosArbitrary, .{ .corpus = &.{
        "{\"error\":{\"details\":[{\"@type\":\"type.googleapis.com/google.rpc.ErrorInfo\",\"metadata\":{\"a\":\"b\"}}]}}",
        "{\"error\":{\"details\":[{\"@type\":\"type.googleapis.com/google.rpc.ErrorInfo\",\"metadata\":[1]}]}}",
        "{\"error\":{\"details\":[[],{},null,1,\"x\"]}}",
        "{\"error\":{\"details\":[{\"@type\":\"type.googleapis.com/google.rpc.ErrorInfo\",\"metadata\":{\"\\ud800\":\"x\"}}]}}",
    } });
}

/// Writes a Google error body whose `details` mix drawn ErrorInfos with
/// other kinds of detail, and checks that exactly the ErrorInfos come
/// back, each field and each string entry as written.
fn errorInfoRoundTrip(_: void, input: []const u8) !void {
    var g: test_util.ByteGen = .init(input);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var expected: std.ArrayList(ErrorInfo) = .empty;
    var out: std.Io.Writer.Allocating = .init(a);
    var jw: std.json.Stringify = .{ .writer = &out.writer };
    try jw.beginObject();
    try jw.objectField("error");
    try jw.beginObject();
    try jw.objectField("code");
    try jw.write(@as(u16, 400));
    try jw.objectField("details");
    try jw.beginArray();
    for (0..g.intRange(u8, 0, 5)) |_| switch (g.intRange(u8, 0, 3)) {
        0 => try jw.write(@as(u16, 7)),
        1 => {
            // Shaped like an ErrorInfo, but of another type.
            try jw.beginObject();
            try jw.objectField("@type");
            try jw.write("type.googleapis.com/google.rpc.DebugInfo");
            try jw.objectField("reason");
            try jw.write("NOT_THIS");
            try jw.endObject();
        },
        else => {
            var reason_buf: [40]u8 = undefined;
            var domain_buf: [40]u8 = undefined;
            const reason = try a.dupe(u8, g.utf8(&reason_buf, reason_buf.len));
            const has_domain = g.boolean();
            const domain = try a.dupe(u8, g.utf8(&domain_buf, domain_buf.len));
            var entries: std.ArrayList(ErrorInfo.Entry) = .empty;
            try jw.beginObject();
            try jw.objectField("reason");
            try jw.write(reason);
            try jw.objectField("@type");
            try jw.write(error_info_type);
            if (has_domain) {
                try jw.objectField("domain");
                try jw.write(domain);
            }
            if (g.boolean()) {
                try jw.objectField("metadata");
                try jw.beginObject();
                for (0..g.intRange(u8, 0, 4)) |k| {
                    var key_buf: [32]u8 = undefined;
                    var value_buf: [48]u8 = undefined;
                    // The digit keeps every key distinct.
                    const key = try std.fmt.allocPrint(a, "{d}{s}", .{ k, g.utf8(&key_buf, key_buf.len) });
                    try jw.objectField(key);
                    if (g.intRange(u8, 0, 3) == 0) {
                        try jw.write(null);
                    } else {
                        const value = try a.dupe(u8, g.utf8(&value_buf, value_buf.len));
                        try jw.write(value);
                        try entries.append(a, .{ .key = key, .value = value });
                    }
                }
                try jw.endObject();
            }
            try jw.endObject();
            try expected.append(a, .{ .reason = reason, .domain = if (has_domain) domain else "", .metadata = entries.items });
        },
    };
    try jw.endArray();
    try jw.endObject();
    try jw.endObject();

    const got = try decodeErrorInfos(a, out.written());
    try testing.expectEqual(expected.items.len, got.len);
    for (expected.items, got) |want, have| {
        try testing.expectEqualStrings(want.reason, have.reason);
        try testing.expectEqualStrings(want.domain, have.domain);
        try testing.expectEqual(want.metadata.len, have.metadata.len);
        for (want.metadata, have.metadata) |w, h| {
            try testing.expectEqualStrings(w.key, h.key);
            try testing.expectEqualStrings(w.value, h.value);
        }
    }
}

test "fuzz decodeErrorInfos: ErrorInfos written with std's JSON come back exactly" {
    try test_util.fuzzBytes({}, errorInfoRoundTrip, .{ .corpus = &.{
        "",
        "\x03\x02\x02\x05R\x01\x03d\x01\x02\x00\x02\x01k\x05\x04value",
        "\x05\x00\x01\x02\x00\x00\x00\x02\x01\x01\x7f\x00\x00\x00\x03",
    } });
}
