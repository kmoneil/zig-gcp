//! Runs one API call: core's request engine builds the URL, attaches
//! credentials, sends through the client's transport, maps failures to
//! errors, retries transient ones with jittered backoff, and keeps
//! `Diagnostics` and the log current. This file binds that engine to a
//! Pub/Sub client and holds the checks its public calls share.
//! `Client`, `Topic` and `Subscription` call into here.

const std = @import("std");
const core = @import("core");
const Allocator = std.mem.Allocator;

const Client = @import("Client.zig");
const codec = @import("codec.zig");
const errors = @import("errors.zig");
const logging = @import("logging.zig");
const validate = @import("validate.zig");
const Error = errors.Error;
const isRetryable = core.isRetryable;

/// The OAuth scope the client asks its token provider for.
pub const scope = "https://www.googleapis.com/auth/pubsub";

/// The shared engine, logging under this module's scope.
const Engine = core.rpc.Engine(.gcp_pubsub);

pub const Call = core.rpc.Call;

/// The engine, filled in from one client's settings.
fn engine(client: *Client) Engine {
    return .{
        .gpa = client.gpa,
        .io = client.io,
        .transport = client.transport,
        .base_url = client.base_url,
        .auth_scope = scope,
        .token_provider = client.token_provider,
        // The emulator speaks plain HTTP and never receives credentials.
        .unauthenticated = client.emulator,
        .send_quota_project = client.send_quota_project,
        .retry = client.retry,
        .request_timeout_ms = client.request_timeout_ms,
        .diagnostics = client.diagnostics,
    };
}

/// Starts a public call: `Diagnostics` describe only the latest call.
pub fn begin(client: *Client) void {
    engine(client).begin();
}

/// Sends `call`, retrying transient failures, and returns the body of the
/// first 2xx response. The body lives in `response`, which is reset between
/// attempts and so must hold nothing else.
pub fn execute(client: *Client, response: *std.heap.ArenaAllocator, call: Call) Error![]const u8 {
    return engine(client).execute(response, call);
}

/// `execute` for calls whose response body is not needed.
pub fn executeDiscard(client: *Client, call: Call) Error!void {
    return engine(client).executeDiscard(call);
}

/// Whether a failed publish attempt is worth another. Google's own clients
/// retry Publish on seven statuses (googleapis' service config): the four
/// `core.isRetryable` knows, plus ABORTED, CANCELLED and UNKNOWN. UNKNOWN
/// counts only on a 5xx answer: every HTTP status core does not know, 405
/// and 415 among them, also reads as `error.Unknown`, and those are
/// permanent. Go's REST client likewise retries 500 but no 4xx it cannot
/// place.
pub fn isPublishRetryable(err: anyerror, http_status: u16) bool {
    return switch (err) {
        error.Aborted, error.ServerCancelled => true,
        error.Unknown => http_status >= 500 and http_status < 600,
        else => isRetryable(err),
    };
}

/// Checks a topic or subscription id before any request.
pub fn checkId(client: *Client, kind: []const u8, id: []const u8) Error!void {
    if (validate.isResourceId(id)) return;
    if (client.diagnostics) |d| d.print(
        "invalid {s} id: ids are 3 to 255 characters from [A-Za-z0-9-_.~+%], start with a letter, and do not start with \"goog\"",
        .{kind},
    );
    return error.InvalidResourceId;
}

/// Reports a 2xx body that did not decode.
pub fn decodeFailed(client: *Client, err: codec.DecodeError, what: []const u8) Error {
    if (err == error.InvalidResponse) {
        if (client.diagnostics) |d| d.print("the {s} response could not be decoded", .{what});
    }
    return err;
}

// Tests drive the engine through public calls, with a fake transport and a
// fake clock.

const testing = std.testing;
const test_util = @import("test_util.zig");
const Harness = test_util.Harness;
const Reply = test_util.FakeTransport.Reply;
const FakeTokenProvider = test_util.FakeTokenProvider;

const unavailable: Reply = .{ .respond = .{
    .status = 503,
    .body = "{\"error\":{\"code\":503,\"message\":\"The service is currently unavailable.\",\"status\":\"UNAVAILABLE\"}}",
} };
const topic_ok: Reply = .{ .respond = .{ .body = "{\"name\":\"projects/p/topics/orders\"}" } };

test "retry: 503, 503, 200 succeeds on the third attempt within backoff bounds" {
    var h: Harness = undefined;
    try h.init(&.{ unavailable, unavailable, topic_ok }, .{});
    defer h.deinit();

    var info = try h.client.topic("orders").get();
    defer info.deinit();
    try testing.expectEqualStrings("projects/p/topics/orders", info.value.name);
    try h.expectRequestCount(3);
    try testing.expectEqual(2, h.clock.sleep_count);
    try testing.expect(h.clock.sleepMs(0) <= 100);
    try testing.expect(h.clock.sleepMs(1) <= 200);
    // Success clears the diagnostics left by the failed attempts.
    try testing.expectEqual(0, h.diag.http_status);
    try testing.expectEqualStrings("", h.diag.message());
}

test "retry: pinned randomness gives exact full-jitter delays" {
    var h: Harness = undefined;
    try h.init(&.{ unavailable, unavailable, unavailable, unavailable, topic_ok }, .{});
    defer h.deinit();
    // All-ones entropy: u64 max modulo (cap + 1) for caps 100, 200, 400, 800.
    h.clock.random_byte = 0xff;
    var info = try h.client.topic("orders").get();
    defer info.deinit();
    const max = std.math.maxInt(u64);
    try testing.expectEqual(4, h.clock.sleep_count);
    try testing.expectEqual(max % 101, h.clock.sleepMs(0));
    try testing.expectEqual(max % 201, h.clock.sleepMs(1));
    try testing.expectEqual(max % 401, h.clock.sleepMs(2));
    try testing.expectEqual(max % 801, h.clock.sleepMs(3));

    var zero: Harness = undefined;
    try zero.init(&.{ unavailable, topic_ok }, .{});
    defer zero.deinit();
    zero.clock.random_byte = 0;
    var again = try zero.client.topic("orders").get();
    defer again.deinit();
    try testing.expectEqual(0, zero.clock.sleepMs(0));
}

test "retry: gives up after max_attempts and reports the last failure" {
    var h: Harness = undefined;
    try h.init(&.{ unavailable, unavailable, unavailable }, .{ .retry = .{ .max_attempts = 3 } });
    defer h.deinit();
    try testing.expectError(error.Unavailable, h.client.topic("orders").get());
    try h.expectRequestCount(3);
    try testing.expectEqual(2, h.clock.sleep_count);
    try testing.expectEqual(503, h.diag.http_status);
    try testing.expectEqualStrings("UNAVAILABLE", h.diag.status());
    try testing.expectEqualStrings("The service is currently unavailable.", h.diag.message());
}

test "retry: max_attempts = 1 disables retries" {
    var h: Harness = undefined;
    try h.init(&.{unavailable}, .{ .retry = .{ .max_attempts = 1 } });
    defer h.deinit();
    try testing.expectError(error.Unavailable, h.client.topic("orders").get());
    try h.expectRequestCount(1);
    try testing.expectEqual(0, h.clock.sleep_count);
}

test "retry: non-retryable statuses return at once" {
    var h: Harness = undefined;
    try h.init(&.{.{ .respond = .{
        .status = 404,
        .body = "{\"error\":{\"code\":404,\"message\":\"Topic not found\",\"status\":\"NOT_FOUND\"}}",
    } }}, .{});
    defer h.deinit();
    try testing.expectError(error.NotFound, h.client.topic("orders").get());
    try h.expectRequestCount(1);
    try testing.expectEqual(0, h.clock.sleep_count);
    try testing.expectEqual(404, h.diag.http_status);
    try testing.expectEqualStrings("NOT_FOUND", h.diag.status());
    try testing.expectEqualStrings("Topic not found", h.diag.message());
}

test "retry: transient transport failures retry, permanent ones do not" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .fail = error.ConnectionResetByPeer },
        .{ .fail = error.ConnectionTimedOut },
        .{ .fail = error.ConnectionRefused },
        // A dropped handshake looks like a TLS failure (see `isRetryable`).
        .{ .fail = error.TlsFailure },
        topic_ok,
    }, .{});
    defer h.deinit();
    var info = try h.client.topic("orders").get();
    info.deinit();
    try h.expectRequestCount(5);

    var dns: Harness = undefined;
    try dns.init(&.{.{ .fail = error.UnknownHostName }}, .{});
    defer dns.deinit();
    try testing.expectError(error.UnknownHostName, dns.client.topic("orders").get());
    try dns.expectRequestCount(1);
    try testing.expectEqual(0, dns.diag.http_status);
    try testing.expectEqualStrings("UnknownHostName", dns.diag.message());
}

test "retry: a publish retries the seven statuses Google's clients retry, and UNKNOWN only on a 5xx" {
    const cases = [_]struct { anyerror, u16, bool }{
        // The service config's seven, as the server reports them.
        .{ error.Aborted, 409, true },
        .{ error.ServerCancelled, 499, true },
        .{ error.Internal, 500, true },
        .{ error.ResourceExhausted, 429, true },
        .{ error.Unknown, 500, true },
        .{ error.Unavailable, 503, true },
        .{ error.DeadlineExceeded, 504, true },
        // An HTTP status core cannot place also reads as Unknown.
        .{ error.Unknown, 505, true },
        .{ error.Unknown, 405, false },
        .{ error.Unknown, 415, false },
        .{ error.Unknown, 0, false },
        // Transport failures follow core.isRetryable.
        .{ error.ConnectionResetByPeer, 0, true },
        .{ error.TimedOut, 0, true },
        .{ error.UnknownHostName, 0, false },
        // Everything else is final.
        .{ error.InvalidArgument, 400, false },
        .{ error.FailedPrecondition, 400, false },
        .{ error.NotFound, 404, false },
        .{ error.PermissionDenied, 403, false },
        .{ error.Canceled, 0, false },
        .{ error.InvalidResponse, 200, false },
    };
    for (cases) |c| {
        const err, const status, const want = c;
        if (isPublishRetryable(err, status) != want) {
            std.debug.print("isPublishRetryable({t}, {d}) should be {}\n", .{ err, status, want });
            return error.TestUnexpectedResult;
        }
    }
    // Anything core retries, a publish retries too.
    for (cases) |c| if (isRetryable(c[0])) try testing.expect(isPublishRetryable(c[0], c[1]));
}

test "retry: a canceled backoff sleep returns error.Canceled" {
    var h: Harness = undefined;
    try h.init(&.{ unavailable, topic_ok }, .{});
    defer h.deinit();
    h.clock.cancel_sleep = true;
    try testing.expectError(error.Canceled, h.client.topic("orders").get());
    try h.expectRequestCount(1);
}

test "retry: cancellation from the transport is never retried" {
    var h: Harness = undefined;
    try h.init(&.{ .{ .fail = error.Canceled }, topic_ok }, .{});
    defer h.deinit();
    try testing.expectError(error.Canceled, h.client.topic("orders").get());
    try h.expectRequestCount(1);
}

test "retry: an undecodable success body is InvalidResponse, never retried" {
    var h: Harness = undefined;
    try h.init(&.{ .{ .respond = .{ .body = "<html>" } }, topic_ok }, .{});
    defer h.deinit();
    try testing.expectError(error.InvalidResponse, h.client.topic("orders").get());
    try h.expectRequestCount(1);
    try testing.expectEqualStrings("the topic response could not be decoded", h.diag.message());
}

test "error table end to end: every status through a real call" {
    const cases = [_]struct { u16, []const u8, anyerror }{
        .{ 400, "INVALID_ARGUMENT", error.InvalidArgument },
        .{ 400, "FAILED_PRECONDITION", error.FailedPrecondition },
        .{ 401, "UNAUTHENTICATED", error.Unauthenticated },
        .{ 403, "PERMISSION_DENIED", error.PermissionDenied },
        .{ 404, "NOT_FOUND", error.NotFound },
        .{ 409, "ALREADY_EXISTS", error.AlreadyExists },
        .{ 429, "RESOURCE_EXHAUSTED", error.ResourceExhausted },
        .{ 499, "CANCELLED", error.ServerCancelled },
        .{ 500, "INTERNAL", error.Internal },
        .{ 502, "BAD_GATEWAY", error.Unavailable },
        .{ 503, "UNAVAILABLE", error.Unavailable },
        .{ 504, "DEADLINE_EXCEEDED", error.DeadlineExceeded },
    };
    for (cases) |c| {
        var buf: [128]u8 = undefined;
        const body = try std.fmt.bufPrint(&buf, "{{\"error\":{{\"code\":{d},\"message\":\"m\",\"status\":\"{s}\"}}}}", .{ c[0], c[1] });
        var h: Harness = undefined;
        // One attempt, so retryable statuses surface too.
        try h.init(&.{.{ .respond = .{ .status = c[0], .body = body } }}, .{ .retry = .{ .max_attempts = 1 } });
        defer h.deinit();
        try testing.expectError(c[2], h.client.topic("orders").get());
        try testing.expectEqualStrings(c[1], h.diag.status());
    }
}

test "error bodies that are not JSON map by HTTP status and keep the text" {
    var h: Harness = undefined;
    // The emulator answers unknown routes with a plain-text 404.
    try h.init(&.{.{ .respond = .{ .status = 404, .body = "Not Found" } }}, .{});
    defer h.deinit();
    try testing.expectError(error.NotFound, h.client.topic("orders").get());
    try testing.expectEqualStrings("", h.diag.status());
    try testing.expectEqualStrings("Not Found", h.diag.message());

    var proxy: Harness = undefined;
    try proxy.init(&.{
        .{ .respond = .{ .status = 502, .body = "<html><body>Bad Gateway</body></html>" } },
        topic_ok,
    }, .{});
    defer proxy.deinit();
    var info = try proxy.client.topic("orders").get();
    info.deinit();
    try proxy.expectRequestCount(2);
}

test "credentials: production gets the bearer token, the emulator never does" {
    var prod: Harness = undefined;
    try prod.init(&.{topic_ok}, .{ .token = "ya29.token" });
    defer prod.deinit();
    var info = try prod.client.topic("orders").get();
    info.deinit();
    const sent = try prod.fake.request(0);
    try testing.expectEqualStrings("ya29.token", sent.bearer.?);
    try testing.expectEqualStrings("https://pubsub.googleapis.com/v1/projects/p/topics/orders", sent.url);

    var emu: Harness = undefined;
    try emu.init(&.{topic_ok}, .{});
    defer emu.deinit();
    // Even with a provider configured, the emulator gets no credentials.
    emu.client.token_provider = emu.token.provider();
    emu.token.token = "ya29.secret";
    var again = try emu.client.topic("orders").get();
    again.deinit();
    try testing.expectEqual(null, (try emu.fake.request(0)).bearer);
    try testing.expectEqualStrings("http://localhost:8085/v1/projects/p/topics/orders", (try emu.fake.request(0)).url);
}

test "credentials: an unusable token fails before sending" {
    var h: Harness = undefined;
    try h.init(&.{topic_ok}, .{ .token = "ya29.token\n" });
    defer h.deinit();
    try testing.expectError(error.TokenUnavailable, h.client.topic("orders").get());
    try h.expectRequestCount(0);
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "newlines") != null);
}

test "credentials: a failing provider's error is returned, not retried" {
    var failing: FakeTokenProvider = .{ .fail = error.TokenUnavailable };
    var h: Harness = undefined;
    try h.init(&.{topic_ok}, .{ .token = "unused" });
    defer h.deinit();
    h.client.token_provider = failing.provider();
    try testing.expectError(error.TokenUnavailable, h.client.topic("orders").get());
    try testing.expectEqual(1, failing.calls);
    // The client asks for exactly the Pub/Sub scope.
    try testing.expectEqual(1, failing.scope_count);
    try testing.expectEqualStrings(scope, failing.firstScope());
    try h.expectRequestCount(0);
    try testing.expectEqualStrings("the token provider failed: TokenUnavailable", h.diag.message());
}

test "credentials: token errors reach the caller by name" {
    // A caller can tell a dead login from a missing service account or a
    // network failure. None is retried here: providers retry their own
    // requests, and a failed token fetch would only fail again.
    inline for (.{ error.RefreshTokenInvalid, error.MetadataUnavailable, error.ConnectionRefused }) |e| {
        var failing: FakeTokenProvider = .{ .fail = e };
        var h: Harness = undefined;
        try h.init(&.{topic_ok}, .{ .token = "unused" });
        defer h.deinit();
        h.client.token_provider = failing.provider();
        try testing.expectError(e, h.client.topic("orders").get());
        try testing.expectEqual(1, failing.calls);
        try h.expectRequestCount(0);
        try testing.expectEqualStrings("the token provider failed: " ++ @errorName(e), h.diag.message());
    }
}

test "credentials: the provider is asked again on every attempt" {
    var counting: FakeTokenProvider = .{};
    var h: Harness = undefined;
    try h.init(&.{ unavailable, topic_ok }, .{ .token = "unused" });
    defer h.deinit();
    h.client.token_provider = counting.provider();
    var info = try h.client.topic("orders").get();
    info.deinit();
    try testing.expectEqual(2, counting.calls);
    // The provider's copy, in the call's scratch arena, reached the request.
    try testing.expectEqualStrings("ya29.fake-token", (try h.fake.request(1)).bearer.?);
    // A 503 is not a credentials problem: the cached token stays.
    try testing.expectEqual(0, counting.invalidations);
}

test "log hygiene: no token, payload or attribute value ever reaches the log" {
    logging.capture.reset();
    var h: Harness = undefined;
    const ok: Reply = .{ .respond = .{ .body = "{\"messageIds\":[\"1\"]}" } };
    try h.init(&.{ unavailable, unavailable, ok }, .{ .token = "SECRET-TOKEN-7f3a" });
    defer h.deinit();
    var result = try h.client.topic("orders").publish(&.{.{
        .data = "PAYLOAD-BYTES-91c2",
        .attributes = &.{.{ .key = "ATTR-KEY-5d", .value = "ATTR-VALUE-e8" }},
    }}, .{ .ordering_key = "ORDER-KEY-44" });
    result.deinit();

    const log = logging.capture.text();
    // The log was written: one debug line per attempt, one warning per retry.
    try testing.expectEqual(5, logging.capture.lines);
    try testing.expect(std.mem.indexOf(u8, log, "warn: POST /v1/projects/p/topics/orders:publish failed with Unavailable; retrying in") != null);
    try testing.expect(std.mem.indexOf(u8, log, "debug: POST /v1/projects/p/topics/orders:publish -> 200") != null);
    // And none of the secrets, raw or base64-encoded.
    var b64: [64]u8 = undefined;
    for ([_][]const u8{
        "SECRET-TOKEN-7f3a",
        "PAYLOAD-BYTES-91c2",
        std.base64.standard.Encoder.encode(&b64, "PAYLOAD-BYTES-91c2"),
        "ATTR-VALUE-e8",
        "ATTR-KEY-5d",
        "ORDER-KEY-44",
    }) |secret| {
        if (std.mem.indexOf(u8, log, secret) != null) {
            std.debug.print("log leaked {s}:\n{s}\n", .{ secret, log });
            return error.TestLogLeak;
        }
    }
}

test "log hygiene: page tokens stay out of the log" {
    logging.capture.reset();
    var h: Harness = undefined;
    try h.init(&.{.{ .respond = .{ .body = "{}" } }}, .{});
    defer h.deinit();
    var page = try h.client.listTopics(.{ .page_token = "PAGE-TOKEN-SECRET" });
    page.deinit();
    try testing.expect(std.mem.indexOf(u8, (try h.fake.request(0)).url, "PAGE-TOKEN-SECRET") != null);
    try testing.expect(std.mem.indexOf(u8, logging.capture.text(), "PAGE-TOKEN") == null);
    try testing.expect(std.mem.indexOf(u8, logging.capture.text(), "GET /v1/projects/p/topics -> 200") != null);
}

test "the response arena is reset between attempts" {
    var h: Harness = undefined;
    const big_error: Reply = .{ .respond = .{ .status = 503, .body = "x" ** 4096 } };
    try h.init(&.{ big_error, big_error, big_error, topic_ok }, .{});
    defer h.deinit();
    var info = try h.client.topic("orders").get();
    defer info.deinit();
    // The failed bodies were released; only the last body's pages remain.
    try testing.expect(info.arena.queryCapacity() < 3 * 4096);
}

fn anyResponseProperty(_: void, input: []const u8) !void {
    var g: test_util.ByteGen = .init(input);
    const status = g.pick(u16, &.{ 200, 200, 200, 204, 400, 404, 409, 429, 500, 503, 302, 0, 999 });
    const body = g.rest();
    const reply: Reply = .{ .respond = .{ .status = status, .body = body } };
    // Whatever the server says, every call returns a value or an error, and
    // leaks nothing.
    var h: Harness = undefined;
    try h.init(&(.{reply} ** 3), .{ .retry = .{ .max_attempts = 1 } });
    defer h.deinit();
    const c = &h.client;
    if (c.topic("orders").get()) |r| {
        var owned = r;
        owned.deinit();
    } else |_| {}
    if (c.subscription("work").pull(.{})) |r| {
        var owned = r;
        owned.deinit();
    } else |_| {}
    if (c.topic("orders").publish(&.{.{ .data = "x" }}, .{})) |r| {
        var owned = r;
        owned.deinit();
    } else |_| {}
}

test "fuzz: any server response yields a value or an error, never a crash or leak" {
    try test_util.fuzzBytes({}, anyResponseProperty, .{ .corpus = &.{
        "\x00{\"receivedMessages\":[{\"ackId\":\"a\",\"message\":{\"data\":\"aGk=\"}}]}",
        "\x00{\"messageIds\":[\"1\"]}",
        "\x05{\"error\":{\"code\":503,\"status\":\"UNAVAILABLE\"}}",
        "\x04<html>",
        "\x00",
    } });
}

fn tokenGateProperty(_: void, input: []const u8) !void {
    // Whatever a provider returns is sent verbatim or refused before
    // anything is sent. The marker shows up if the secret leaks anywhere.
    const marker = "zzSECRETzz";
    var buffer: [marker.len + 128]u8 = undefined;
    const tail = input[0..@min(input.len, 128)];
    @memcpy(buffer[0..marker.len], marker);
    @memcpy(buffer[marker.len..][0..tail.len], tail);
    const token = buffer[0 .. marker.len + tail.len];

    logging.capture.reset();
    var provider: FakeTokenProvider = .{ .token = token };
    var h: Harness = undefined;
    try h.init(&.{ unavailable, topic_ok }, .{ .token = "unused" });
    defer h.deinit();
    h.client.token_provider = provider.provider();
    if (h.client.topic("orders").get()) |result| {
        var owned = result;
        owned.deinit();
        try testing.expect(core.TokenProvider.isValidToken(token));
        try h.expectRequestCount(2);
        for (0..2) |i| try testing.expectEqualStrings(token, (try h.fake.request(i)).bearer.?);
    } else |err| {
        try testing.expectEqual(error.TokenUnavailable, err);
        try testing.expect(!core.TokenProvider.isValidToken(token));
        try h.expectRequestCount(0);
    }
    try testing.expect(std.mem.indexOf(u8, logging.capture.text(), marker) == null);
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), marker) == null);
}

test "fuzz: a provider's token reaches the request intact or not at all" {
    try test_util.fuzzBytes({}, tokenGateProperty, .{ .corpus = &.{
        "",
        ".a0AfB_byC-9x",
        " x",
        "\r\nX-Injected: 1",
        "\xc3\xa9",
        "\x7f",
    } });
}

/// Replies a server or network can give, retryable and not.
const retry_replies = [_]Reply{
    .{ .fail = error.ConnectionResetByPeer },
    .{ .fail = error.ConnectionRefused },
    .{ .fail = error.TlsFailure },
    .{ .fail = error.UnknownHostName },
    unavailable,
    .{ .respond = .{ .status = 429, .body = "{}" } },
    .{ .respond = .{ .status = 500, .body = "not json" } },
    .{ .respond = .{ .status = 404, .body = "{\"error\":{\"status\":\"NOT_FOUND\"}}" } },
    .{ .respond = .{ .status = 400, .body = "{\"error\":{\"status\":\"FAILED_PRECONDITION\"}}" } },
    topic_ok,
};

fn retrySequenceProperty(_: void, input: []const u8) !void {
    var g: test_util.ByteGen = .init(input);
    const max_attempts = g.intRange(u8, 1, 6);
    var script: [6]Reply = undefined;
    for (&script) |*reply| reply.* = g.pick(Reply, &retry_replies);

    // The model: walk the script as the policy says, one reply per attempt.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var expected_requests: usize = 0;
    const expected: Error!void = for (script[0..max_attempts], 1..) |reply, attempt| {
        expected_requests = attempt;
        const err: Error = switch (reply) {
            .fail => |e| e,
            .respond => |c| if (c.status >= 200 and c.status < 300) break {} else e: {
                const body = try core.errors.decodeErrorBody(arena.allocator(), c.body);
                break :e core.errors.fromResponse(c.status, if (body) |b| b.status else "");
            },
        };
        if (attempt == max_attempts or !isRetryable(err)) break err;
    } else unreachable;

    var h: Harness = undefined;
    try h.init(&script, .{ .token = "ya29.retry", .retry = .{ .max_attempts = max_attempts } });
    defer h.deinit();
    const got = h.client.topic("orders").get();
    if (expected) |_| {
        var owned = try got;
        owned.deinit();
    } else |expected_err| {
        try testing.expectError(expected_err, got);
    }
    try h.expectRequestCount(expected_requests);
    // Every attempt carried the token, and each retry waited within the
    // policy's cap for that retry.
    for (0..expected_requests) |i| try testing.expectEqualStrings("ya29.retry", (try h.fake.request(i)).bearer.?);
    try testing.expectEqual(expected_requests - 1, h.clock.sleep_count);
    for (0..h.clock.sleep_count) |i| try testing.expect(h.clock.sleepMs(i) <= h.client.retry.backoffCapMs(@intCast(i + 1)));
}

test "fuzz retry: attempts, waits and outcome follow the policy for any failure sequence" {
    try test_util.fuzzBytes({}, retrySequenceProperty, .{ .corpus = &.{
        "\x03\x04\x04\x09",
        "\x06\x00\x01\x02",
        "\x01\x04",
        "\x06\x05\x06\x04\x00\x02\x09",
        "\x02\x07",
        "\x05\x08",
        "",
    } });
}

test "credentials: every allocation failure on the token path is OutOfMemory without leaks" {
    const Run = struct {
        fn get(gpa: Allocator) !void {
            var fake: test_util.FakeTransport = .init(testing.allocator, &.{ unavailable, topic_ok });
            defer fake.deinit();
            var clock: test_util.FakeClock = .{};
            var token: core.StaticToken = .{ .token = "ya29.token" };
            var client = try Client.init(gpa, clock.io(), .{
                .project_id = "p",
                .token_provider = token.provider(),
                .transport = fake.transport(),
            });
            defer client.deinit();
            var info = try client.topic("orders").get();
            info.deinit();
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Run.get, .{});
}

const unauthenticated: Reply = .{ .respond = .{
    .status = 401,
    .body = "{\"error\":{\"code\":401,\"message\":\"Invalid Credentials\",\"status\":\"UNAUTHENTICATED\"}}",
} };

test "quota: the credentials' project goes out as x-goog-user-project" {
    var provider: FakeTokenProvider = .{ .quota_project = "billing-project" };
    var h: Harness = undefined;
    try h.init(&.{ topic_ok, topic_ok }, .{ .token = "ya29.token" });
    defer h.deinit();
    h.client.token_provider = provider.provider();

    var info = try h.client.topic("orders").get();
    info.deinit();
    try testing.expectEqualStrings("billing-project", (try h.fake.request(0)).header("x-goog-user-project").?);

    // Off by request: the project owning the resources pays instead.
    h.client.send_quota_project = false;
    var again = try h.client.topic("orders").get();
    again.deinit();
    try testing.expectEqual(null, (try h.fake.request(1)).header("x-goog-user-project"));
}

test "quota: credentials that name no project send no header" {
    // A service account bills its own project, so it reports none.
    var provider: FakeTokenProvider = .{};
    var h: Harness = undefined;
    try h.init(&.{topic_ok}, .{ .token = "ya29.token" });
    defer h.deinit();
    h.client.token_provider = provider.provider();
    var info = try h.client.topic("orders").get();
    info.deinit();
    try testing.expectEqual(null, (try h.fake.request(0)).header("x-goog-user-project"));
}

test "quota: the emulator never gets the project either" {
    var provider: FakeTokenProvider = .{ .quota_project = "billing-project" };
    var h: Harness = undefined;
    try h.init(&.{topic_ok}, .{});
    defer h.deinit();
    h.client.token_provider = provider.provider();
    var info = try h.client.topic("orders").get();
    info.deinit();
    try testing.expectEqual(null, (try h.fake.request(0)).header("x-goog-user-project"));
    try testing.expectEqual(null, (try h.fake.request(0)).bearer);
}

test "quota: a project id that is not one is refused before anything is sent" {
    for ([_][]const u8{ "bad project", "billing\r\nX-Injected: 1", "x" ** 101, "" }) |bad| {
        var provider: FakeTokenProvider = .{ .quota_project = bad };
        var h: Harness = undefined;
        try h.init(&.{topic_ok}, .{ .token = "ya29.token" });
        defer h.deinit();
        h.client.token_provider = provider.provider();
        try testing.expectError(error.InvalidResourceId, h.client.topic("orders").get());
        try h.expectRequestCount(0);
        try testing.expect(std.mem.startsWith(u8, h.diag.message(), "invalid quota project"));
    }
}

test "401: the cached token is dropped and the call retried once with a fresh one" {
    var provider: FakeTokenProvider = .{ .token = "ya29.stale", .next_token = "ya29.fresh" };
    var h: Harness = undefined;
    try h.init(&.{ unauthenticated, topic_ok }, .{ .token = "ya29.token" });
    defer h.deinit();
    h.client.token_provider = provider.provider();

    var info = try h.client.topic("orders").get();
    defer info.deinit();
    try h.expectRequestCount(2);
    try testing.expectEqual(1, provider.invalidations);
    try testing.expectEqualStrings("ya29.stale", (try h.fake.request(0)).bearer.?);
    try testing.expectEqualStrings("ya29.fresh", (try h.fake.request(1)).bearer.?);
    // A fresh token is not a transient failure: no backoff, no waiting.
    try testing.expectEqual(0, h.clock.sleep_count);
    try testing.expectEqual(0, h.diag.http_status);
}

test "401: a second one is Unauthenticated, with no third attempt" {
    var provider: FakeTokenProvider = .{ .token = "ya29.stale", .next_token = "ya29.fresh" };
    var h: Harness = undefined;
    try h.init(&.{ unauthenticated, unauthenticated }, .{ .token = "ya29.token" });
    defer h.deinit();
    h.client.token_provider = provider.provider();

    try testing.expectError(error.Unauthenticated, h.client.topic("orders").get());
    try h.expectRequestCount(2);
    try testing.expectEqual(1, provider.invalidations);
    try testing.expectEqual(401, h.diag.http_status);
    try testing.expectEqualStrings("UNAUTHENTICATED", h.diag.status());
}

test "401: a publish retries too, because the server refused it before storing anything" {
    var provider: FakeTokenProvider = .{ .token = "ya29.stale", .next_token = "ya29.fresh" };
    var h: Harness = undefined;
    const ok: Reply = .{ .respond = .{ .body = "{\"messageIds\":[\"1\"]}" } };
    try h.init(&.{ unauthenticated, ok }, .{ .token = "ya29.token", .retry_publish = false });
    defer h.deinit();
    h.client.token_provider = provider.provider();

    var result = try h.client.topic("orders").publish(&.{.{ .data = "x" }}, .{});
    defer result.deinit();
    try h.expectRequestCount(2);
    try testing.expectEqualStrings("ya29.fresh", (try h.fake.request(1)).bearer.?);
    // Still no retrying of anything else: a 503 ends the call.
    var again: Harness = undefined;
    try again.init(&.{unavailable}, .{ .token = "ya29.token", .retry_publish = false });
    defer again.deinit();
    try testing.expectError(error.Unavailable, again.client.topic("orders").publish(&.{.{ .data = "x" }}, .{}));
    try again.expectRequestCount(1);
}

test "401: with no provider to ask, there is nothing to retry with" {
    var h: Harness = undefined;
    try h.init(&.{unauthenticated}, .{});
    defer h.deinit();
    try testing.expectError(error.Unauthenticated, h.client.topic("orders").get());
    try h.expectRequestCount(1);
}

test "401: a call that fails twice over still reports the later failure" {
    var provider: FakeTokenProvider = .{};
    var h: Harness = undefined;
    // One 401, then the retry policy's own attempts for a transient error.
    try h.init(&.{ unauthenticated, unavailable, unavailable }, .{
        .token = "ya29.token",
        .retry = .{ .max_attempts = 2 },
    });
    defer h.deinit();
    h.client.token_provider = provider.provider();
    try testing.expectError(error.Unavailable, h.client.topic("orders").get());
    // The fresh token buys one extra attempt, and no more.
    try h.expectRequestCount(3);
    try testing.expectEqual(1, provider.invalidations);
    try testing.expectEqual(1, h.clock.sleep_count);
}

test "timeouts: every request carries the client's deadline" {
    var h: Harness = undefined;
    try h.init(&.{ topic_ok, topic_ok }, .{});
    defer h.deinit();
    var info = try h.client.topic("orders").get();
    info.deinit();
    // Generous by default: an empty pull is held open, up to about 90
    // seconds by the emulator.
    try testing.expectEqual(180_000, (try h.fake.request(0)).timeout_ms);
    try testing.expect(h.client.request_timeout_ms > 90_000);

    h.client.request_timeout_ms = 2_500;
    var again = try h.client.topic("orders").get();
    again.deinit();
    try testing.expectEqual(2_500, (try h.fake.request(1)).timeout_ms);
}

test "timeouts: a request that outlived its deadline is retried" {
    var h: Harness = undefined;
    try h.init(&.{ .{ .fail = error.TimedOut }, topic_ok }, .{});
    defer h.deinit();
    var info = try h.client.topic("orders").get();
    defer info.deinit();
    try h.expectRequestCount(2);
    try testing.expectEqual(1, h.clock.sleep_count);

    // Unless the caller turned retries off for this call.
    var publish: Harness = undefined;
    try publish.init(&.{.{ .fail = error.TimedOut }}, .{ .retry_publish = false });
    defer publish.deinit();
    try testing.expectError(error.TimedOut, publish.client.topic("orders").publish(&.{.{ .data = "x" }}, .{}));
    try publish.expectRequestCount(1);
}
