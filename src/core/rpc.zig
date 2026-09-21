//! One API call, from URL to body: attach credentials, send it through the
//! transport, map a failure to an error, retry the transient ones with
//! jittered backoff, and keep `Diagnostics` and the log current.
//!
//! Every service module runs this same loop. `Engine(scope)` binds it to the
//! module's log scope; the struct it returns holds the settings the loop
//! reads, and a client fills one in for each call it makes.

const std = @import("std");
const Allocator = std.mem.Allocator;

const WipingAllocator = @import("WipingAllocator.zig");
const errors = @import("errors.zig");
const logging = @import("logging.zig");
const names = @import("names.zig");
const retry = @import("retry.zig");
const transport = @import("transport.zig");
const Diagnostics = errors.Diagnostics;
const Response = transport.Response;
const RetryPolicy = retry.RetryPolicy;
const TokenProvider = @import("TokenProvider.zig");
const Transport = transport.Transport;
const isRetryable = retry.isRetryable;

/// Every error the loop itself returns. A service module's error set adds
/// what its own validation and decoding raise.
pub const Error = errors.ApiError || transport.Error || TokenProvider.Error || error{
    /// The credentials name a quota project that is not a project id.
    InvalidResourceId,
};

/// One request, as a service module describes it.
pub const Call = struct {
    method: transport.Method,
    /// Path and query, starting with `/v1/`. Appended to the base URL.
    path: []const u8,
    body: ?[]const u8 = null,
    /// False where the caller opted out of retries, as a publish does.
    retry: bool = true,
    /// Whether a failed attempt is worth another. `http_status` is the
    /// response's status, or 0 when the attempt got no response. The
    /// default is `isRetryable`; a call can widen it, as a publish does.
    retryable: *const fn (err: anyerror, http_status: u16) bool = retryableByDefault,
    /// This call carries secrets. What the loop allocates for it, the URL
    /// and the bearer token, is wiped when the call returns, and a failed
    /// attempt's response memory is freed at once rather than kept for the
    /// next attempt, so an arena over a `WipingAllocator` wipes it then.
    wipe: bool = false,
};

/// One streaming request, as a service module describes it: the body from
/// replayable segments, the response buffered or streamed into a writer,
/// response headers included in the result. A reader-backed body cannot be
/// replayed for a retry, so it has no place in this loop; a module that
/// streams an upload from a reader runs its own.
pub const StreamCall = struct {
    method: transport.Method,
    /// Path and query, appended to the base URL.
    path: []const u8,
    /// The Content-Type sent with the body, verbatim.
    content_type: ?[]const u8 = null,
    headers: []const transport.Header = &.{},
    body: Body = .none,
    sink: transport.StreamRequest.Sink = .buffer,
    accept_encoding: transport.StreamRequest.AcceptEncoding = .identity,
    /// A writer sink narrows what a retry may repeat: a non-2xx response is
    /// buffered and leaves the writer untouched, so it retries as usual,
    /// but a transport failure may have delivered part of the body, which
    /// cannot be taken back, so it is returned instead. Resuming is the
    /// caller's business.
    retry: bool = true,
    retryable: *const fn (err: anyerror, http_status: u16) bool = retryableByDefault,

    pub const Body = union(enum) {
        none,
        /// Sent back to back with an exact Content-Length; replayable.
        segments: []const []const u8,
    };
};

/// `Error`, plus the caller's sink writer failing, with the detail wherever
/// that concrete writer keeps it.
pub const StreamCallError = Error || error{WriteFailed};

pub fn Engine(comptime log_scope: @EnumLiteral()) type {
    return struct {
        gpa: Allocator,
        io: std.Io,
        transport: Transport,
        /// Scheme, host and port, with no trailing slash.
        base_url: []const u8,
        /// The OAuth scope asked of the token provider.
        auth_scope: []const u8,
        /// Null where there is nothing to ask.
        token_provider: ?TokenProvider = null,
        /// This endpoint must never receive credentials: an emulator speaks
        /// plain HTTP and needs none.
        unauthenticated: bool = false,
        send_quota_project: bool = true,
        retry: RetryPolicy = .{},
        request_timeout_ms: u32 = 0,
        diagnostics: ?*Diagnostics = null,

        const Self = @This();
        const log = logging.Scoped(log_scope);

        /// Starts a public call: `Diagnostics` describe only the latest one.
        pub fn begin(self: Self) void {
            if (self.diagnostics) |d| d.clear();
        }

        /// Sends `call`, retrying transient failures, and returns the body of
        /// the first 2xx response. The body lives in `response`, which is
        /// reset between attempts and so must hold nothing else.
        pub fn execute(self: Self, response: *std.heap.ArenaAllocator, call: Call) Error![]const u8 {
            var wiping: WipingAllocator = .init(self.gpa);
            var scratch: std.heap.ArenaAllocator = .init(if (call.wipe) wiping.allocator() else self.gpa);
            defer scratch.deinit();
            const url = try std.mem.concat(scratch.allocator(), u8, &.{ self.base_url, call.path });
            // Query strings carry page tokens and filters; they stay out of the log.
            const log_path = call.path[0 .. std.mem.indexOfScalar(u8, call.path, '?') orelse call.path.len];
            var max_attempts: u32 = if (call.retry) self.retry.max_attempts else 1;

            var header_buf: [1]transport.Header = undefined;
            var headers: []const transport.Header = &.{};
            if (try self.quotaProject()) |project| {
                header_buf[0] = .{ .name = "x-goog-user-project", .value = project };
                headers = header_buf[0..1];
            }

            var reauthenticated = false;
            var attempt: u32 = 1;
            while (true) : (attempt += 1) {
                const bearer = try self.bearerToken(scratch.allocator());
                const started = std.Io.Clock.awake.now(self.io);
                const outcome = self.transport.send(.{
                    .method = call.method,
                    .url = url,
                    .bearer = bearer,
                    .body = call.body,
                    .headers = headers,
                    .timeout_ms = self.request_timeout_ms,
                }, response.allocator());
                const elapsed_ms = started.durationTo(std.Io.Clock.awake.now(self.io)).toMilliseconds();

                var http_status: u16 = 0;
                const err: Error = if (outcome) |res| e: {
                    http_status = res.status;
                    log.debug("{t} {s} -> {d} in {d} ms (attempt {d} of {d})", .{
                        call.method, log_path, res.status, elapsed_ms, attempt, max_attempts,
                    });
                    if (res.status >= 200 and res.status < 300) {
                        if (self.diagnostics) |d| d.clear();
                        return res.body;
                    }
                    break :e self.failure(scratch.allocator(), res);
                } else |err| e: {
                    log.debug("{t} {s} -> {t} in {d} ms (attempt {d} of {d})", .{
                        call.method, log_path, err, elapsed_ms, attempt, max_attempts,
                    });
                    if (self.diagnostics) |d| d.print("{t}", .{err});
                    break :e err;
                };

                // A 401 usually means the token died between being fetched
                // and being used. The server refused the request before
                // acting on it, so trying again with a fresh token is safe
                // even for a call that otherwise never retries.
                if (err == error.Unauthenticated and !reauthenticated and self.dropCachedToken()) {
                    reauthenticated = true;
                    max_attempts += 1;
                    log.warn("{t} {s} was refused as unauthenticated; retrying once with a fresh token", .{ call.method, log_path });
                    self.resetResponse(response, call);
                    continue;
                }

                if (attempt >= max_attempts or !call.retryable(err, http_status)) return err;
                const delay_ms = self.retry.backoffMs(attempt, entropy(self.io));
                log.warn("{t} {s} failed with {t}; retrying in {d} ms (attempt {d} of {d})", .{
                    call.method, log_path, err, delay_ms, attempt + 1, max_attempts,
                });
                self.resetResponse(response, call);
                try self.io.sleep(.fromMilliseconds(delay_ms), .awake);
            }
        }

        /// Sends `call` through the transport's streaming entry, retrying
        /// transient failures, and returns the first 2xx response whole:
        /// status, headers, and the body, buffered or already delivered to
        /// the sink writer. Everything returned lives in `response`, which
        /// is reset between attempts and so must hold nothing else.
        pub fn executeStream(
            self: Self,
            response: *std.heap.ArenaAllocator,
            call: StreamCall,
        ) StreamCallError!transport.StreamResponse {
            var scratch: std.heap.ArenaAllocator = .init(self.gpa);
            defer scratch.deinit();
            const url = try std.mem.concat(scratch.allocator(), u8, &.{ self.base_url, call.path });
            // Query strings carry page tokens and object names; they stay
            // out of the log.
            const log_path = call.path[0 .. std.mem.indexOfScalar(u8, call.path, '?') orelse call.path.len];
            var max_attempts: u32 = if (call.retry) self.retry.max_attempts else 1;

            // The caller's headers, plus the quota project when there is one.
            var headers = try scratch.allocator().alloc(transport.Header, call.headers.len + 1);
            @memcpy(headers[0..call.headers.len], call.headers);
            var header_count = call.headers.len;
            if (try self.quotaProject()) |project| {
                headers[header_count] = .{ .name = "x-goog-user-project", .value = project };
                header_count += 1;
            }

            var reauthenticated = false;
            var attempt: u32 = 1;
            while (true) : (attempt += 1) {
                const bearer = try self.bearerToken(scratch.allocator());
                const started = std.Io.Clock.awake.now(self.io);
                const outcome = self.transport.sendStream(.{
                    .method = call.method,
                    .url = url,
                    .bearer = bearer,
                    .content_type = call.content_type,
                    .headers = headers[0..header_count],
                    .body = switch (call.body) {
                        .none => .none,
                        .segments => |segments| .{ .segments = segments },
                    },
                    .sink = call.sink,
                    .accept_encoding = call.accept_encoding,
                    .timeout_ms = self.request_timeout_ms,
                }, response.allocator());
                const elapsed_ms = started.durationTo(std.Io.Clock.awake.now(self.io)).toMilliseconds();

                var http_status: u16 = 0;
                var mid_body = false;
                const err: StreamCallError = if (outcome) |res| e: {
                    http_status = res.status;
                    log.debug("{t} {s} -> {d} in {d} ms (attempt {d} of {d})", .{
                        call.method, log_path, res.status, elapsed_ms, attempt, max_attempts,
                    });
                    if (res.status >= 200 and res.status < 300) {
                        if (self.diagnostics) |d| d.clear();
                        return res;
                    }
                    break :e self.failure(scratch.allocator(), .{
                        .status = res.status,
                        .body = res.body,
                        .headers = res.headers,
                    });
                } else |err| e: {
                    log.debug("{t} {s} -> {t} in {d} ms (attempt {d} of {d})", .{
                        call.method, log_path, err, elapsed_ms, attempt, max_attempts,
                    });
                    if (self.diagnostics) |d| d.print("{t}", .{err});
                    break :e switch (err) {
                        // The caller's sink writer failed; nothing to retry.
                        error.WriteFailed => return error.WriteFailed,
                        // No reader-backed body ever goes through this loop.
                        error.ReadFailed, error.EndOfStream => unreachable,
                        else => |e| b: {
                            // A transport failure may have delivered part of
                            // the body to a writer sink already.
                            mid_body = call.sink == .writer;
                            break :b e;
                        },
                    };
                };

                // A 401 response is buffered whatever the sink, so retrying
                // it once with a fresh token is safe even there.
                if (err == error.Unauthenticated and !reauthenticated and self.dropCachedToken()) {
                    reauthenticated = true;
                    max_attempts += 1;
                    log.warn("{t} {s} was refused as unauthenticated; retrying once with a fresh token", .{ call.method, log_path });
                    _ = response.reset(.retain_capacity);
                    continue;
                }

                if (mid_body or attempt >= max_attempts or !call.retryable(err, http_status)) return err;
                const delay_ms = self.retry.backoffMs(attempt, entropy(self.io));
                log.warn("{t} {s} failed with {t}; retrying in {d} ms (attempt {d} of {d})", .{
                    call.method, log_path, err, delay_ms, attempt + 1, max_attempts,
                });
                _ = response.reset(.retain_capacity);
                try self.io.sleep(.fromMilliseconds(delay_ms), .awake);
            }
        }

        /// `execute` for calls whose response body is not needed.
        pub fn executeDiscard(self: Self, call: Call) Error!void {
            var wiping: WipingAllocator = .init(self.gpa);
            var response: std.heap.ArenaAllocator = .init(if (call.wipe) wiping.allocator() else self.gpa);
            defer response.deinit();
            _ = try self.execute(&response, call);
        }

        /// Clears the failed attempt's body. A call that carries secrets
        /// gives the memory back, so the wrapping allocator wipes it now;
        /// every other call keeps it for the next attempt.
        fn resetResponse(self: Self, response: *std.heap.ArenaAllocator, call: Call) void {
            _ = self;
            _ = response.reset(if (call.wipe) .free_all else .retain_capacity);
        }

        /// Maps a non-2xx response and records its details.
        fn failure(self: Self, scratch: Allocator, res: Response) Error {
            const body = errors.decodeErrorBody(scratch, res.body) catch |err| return err;
            const status = if (body) |b| b.status else "";
            // A body that is not the standard error shape, such as a proxy's
            // page, is the best message there is.
            const message = if (body) |b| b.message else res.body;
            if (self.diagnostics) |d| d.set(res.status, status, message);
            return errors.fromResponse(res.status, status);
        }

        /// The token for one attempt, copied into `scratch`, which outlives
        /// the request and is freed when the call returns.
        fn bearerToken(self: Self, scratch: Allocator) Error!?[]const u8 {
            // Never send credentials to an endpoint that speaks plain HTTP.
            if (self.unauthenticated) return null;
            const provider = self.token_provider orelse return null;
            // A provider given these same diagnostics explains its own
            // failures better than this loop can, such as which role an
            // impersonation lacks. Start clean, so that if it fails, what
            // is left is what it said about this attempt.
            if (self.diagnostics) |d| d.clear();
            const token = provider.getToken(self.io, scratch, &.{self.auth_scope}) catch |err| {
                if (self.diagnostics) |d| if (d.message().len == 0) d.print("the token provider failed: {t}", .{err});
                return err;
            };
            if (!TokenProvider.isValidToken(token)) {
                if (self.diagnostics) |d| d.print("the token provider returned an empty token, or one with spaces, newlines or non-ASCII bytes", .{});
                return error.TokenUnavailable;
            }
            return token;
        }

        /// The project to charge for quota, sent as `x-goog-user-project`.
        /// User credentials name one; a service account bills its own
        /// project. An unauthenticated endpoint never sees it, and
        /// `send_quota_project` turns it off.
        fn quotaProject(self: Self) Error!?[]const u8 {
            if (self.unauthenticated or !self.send_quota_project) return null;
            const provider = self.token_provider orelse return null;
            const project = provider.quotaProject() orelse return null;
            if (!names.isProjectId(project)) {
                if (self.diagnostics) |d| d.print(
                    "invalid quota project: expected a project id, from the credentials or GOOGLE_CLOUD_QUOTA_PROJECT",
                    .{},
                );
                return error.InvalidResourceId;
            }
            return project;
        }

        /// Drops the cached token after a 401, so the next attempt fetches a
        /// new one. False when there is no provider to ask, which makes a
        /// second attempt pointless.
        fn dropCachedToken(self: Self) bool {
            if (self.unauthenticated) return false;
            const provider = self.token_provider orelse return false;
            provider.invalidate();
            return true;
        }
    };
}

fn retryableByDefault(err: anyerror, http_status: u16) bool {
    _ = http_status;
    return isRetryable(err);
}

/// Randomness for a jittered backoff. Public so a module that retries a call
/// of its own, as Secret Manager does after a checksum mismatch, waits the
/// same way the loop does.
pub fn entropy(io: std.Io) u64 {
    var bytes: [8]u8 = undefined;
    io.random(&bytes);
    return std.mem.readInt(u64, &bytes, .little);
}

// The service modules drive this loop through their own public calls, and
// their tests cover it end to end. These tests drive it directly, so its
// contract is stated where the code lives.

const testing = std.testing;
const test_util = @import("testing.zig");
const FakeTransport = test_util.FakeTransport;
const Reply = FakeTransport.Reply;

const TestEngine = Engine(.gcp_core_rpc_test);

const unavailable: Reply = .{ .respond = .{
    .status = 503,
    .body = "{\"error\":{\"code\":503,\"message\":\"The service is currently unavailable.\",\"status\":\"UNAVAILABLE\"}}",
} };
const unauthorized: Reply = .{ .respond = .{
    .status = 401,
    .body = "{\"error\":{\"code\":401,\"message\":\"Invalid Credentials\",\"status\":\"UNAUTHENTICATED\"}}",
} };
const ok: Reply = .{ .respond = .{ .body = "{\"name\":\"projects/p/things/1\"}" } };

/// A fake transport, clock and token provider, with an engine on them.
const Harness = struct {
    fake: FakeTransport,
    clock: test_util.FakeClock = .{},
    token: test_util.FakeTokenProvider = .{},
    diag: Diagnostics = .{},
    arena: std.heap.ArenaAllocator = undefined,

    fn init(h: *Harness, script: []const Reply) void {
        h.* = .{ .fake = .init(testing.allocator, script) };
        h.arena = .init(testing.allocator);
    }

    fn deinit(h: *Harness) void {
        h.arena.deinit();
        h.fake.deinit();
    }

    fn engine(h: *Harness) TestEngine {
        return .{
            .gpa = testing.allocator,
            .io = h.clock.io(),
            .transport = h.fake.transport(),
            .base_url = "https://service.googleapis.com",
            .auth_scope = "https://www.googleapis.com/auth/cloud-platform",
            .token_provider = h.token.provider(),
            .diagnostics = &h.diag,
        };
    }

    /// `GET /v1/things` through the engine.
    fn get(h: *Harness) Error![]const u8 {
        const e = h.engine();
        e.begin();
        return e.execute(&h.arena, .{ .method = .GET, .path = "/v1/things" });
    }
};

test "a success returns the body and clears the diagnostics" {
    var h: Harness = undefined;
    h.init(&.{ok});
    defer h.deinit();
    h.diag.set(500, "INTERNAL", "an earlier call failed");

    try testing.expectEqualStrings("{\"name\":\"projects/p/things/1\"}", try h.get());
    const sent = try h.fake.request(0);
    try testing.expectEqualStrings("https://service.googleapis.com/v1/things", sent.url);
    try testing.expectEqualStrings("ya29.fake-token", sent.bearer.?);
    try testing.expectEqual(.GET, sent.method);
    try testing.expectEqual(0, h.diag.http_status);
    try testing.expectEqualStrings("", h.diag.message());
    try testing.expectEqualStrings("https://www.googleapis.com/auth/cloud-platform", h.token.firstScope());
}

test "retry: 503, 503, 200 succeeds on the third attempt within the backoff bounds" {
    var h: Harness = undefined;
    h.init(&.{ unavailable, unavailable, ok });
    defer h.deinit();

    _ = try h.get();
    try testing.expectEqual(3, h.fake.requests.items.len);
    try testing.expectEqual(2, h.clock.sleep_count);
    try testing.expect(h.clock.sleepMs(0) <= 100);
    try testing.expect(h.clock.sleepMs(1) <= 200);
    // Every attempt asked for a token; none of them invalidated one.
    try testing.expectEqual(3, h.token.calls);
    try testing.expectEqual(0, h.token.invalidations);
}

test "retry: gives up after max_attempts and reports the last failure" {
    var h: Harness = undefined;
    h.init(&.{ unavailable, unavailable, unavailable, unavailable, unavailable });
    defer h.deinit();
    var e = h.engine();
    e.retry = .{ .max_attempts = 3 };
    try testing.expectError(error.Unavailable, e.execute(&h.arena, .{ .method = .GET, .path = "/v1/things" }));
    try testing.expectEqual(3, h.fake.requests.items.len);
    try testing.expectEqual(2, h.clock.sleep_count);
    try testing.expectEqual(503, h.diag.http_status);
    try testing.expectEqualStrings("UNAVAILABLE", h.diag.status());
    try testing.expectEqualStrings("The service is currently unavailable.", h.diag.message());
}

test "retry: a non-retryable status returns at once, and an opted-out call never retries" {
    var h: Harness = undefined;
    h.init(&.{
        .{ .respond = .{ .status = 404, .body = "{\"error\":{\"status\":\"NOT_FOUND\",\"message\":\"no such thing\"}}" } },
        unavailable,
    });
    defer h.deinit();
    try testing.expectError(error.NotFound, h.get());
    try testing.expectEqual(1, h.fake.requests.items.len);
    try testing.expectEqualStrings("no such thing", h.diag.message());

    const e = h.engine();
    try testing.expectError(error.Unavailable, e.execute(&h.arena, .{ .method = .POST, .path = "/v1/things", .retry = false }));
    try testing.expectEqual(2, h.fake.requests.items.len);
    try testing.expectEqual(0, h.clock.sleep_count);
}

test "retry: a call can widen what is retried, and sees the HTTP status it decides on" {
    const Widened = struct {
        var seen: [4]u16 = undefined;
        var calls: usize = 0;

        fn retryable(err: anyerror, http_status: u16) bool {
            seen[calls] = http_status;
            calls += 1;
            return err == error.Aborted or isRetryable(err);
        }
    };
    var h: Harness = undefined;
    h.init(&.{
        .{ .respond = .{ .status = 409, .body = "{\"error\":{\"status\":\"ABORTED\"}}" } },
        .{ .fail = error.ConnectionResetByPeer },
        ok,
        .{ .respond = .{ .status = 409, .body = "{\"error\":{\"status\":\"ABORTED\"}}" } },
    });
    defer h.deinit();
    const e = h.engine();
    Widened.calls = 0;
    _ = try e.execute(&h.arena, .{ .method = .POST, .path = "/v1/things", .retryable = Widened.retryable });
    try testing.expectEqual(3, h.fake.requests.items.len);
    // A response's status, and 0 for an attempt that got none.
    try testing.expectEqualSlices(u16, &.{ 409, 0 }, Widened.seen[0..Widened.calls]);

    // The default leaves ABORTED alone.
    try testing.expectError(error.Aborted, h.get());
    try testing.expectEqual(4, h.fake.requests.items.len);
}

test "a body that is not the standard error shape maps by HTTP status and keeps its text" {
    var h: Harness = undefined;
    h.init(&.{.{ .respond = .{ .status = 502, .body = "<html>Bad Gateway</html>" } }});
    defer h.deinit();
    var e = h.engine();
    e.retry = .{ .max_attempts = 1 };
    try testing.expectError(error.Unavailable, e.execute(&h.arena, .{ .method = .GET, .path = "/v1/things" }));
    try testing.expectEqual(502, h.diag.http_status);
    try testing.expectEqualStrings("", h.diag.status());
    try testing.expectEqualStrings("<html>Bad Gateway</html>", h.diag.message());
}

test "401: the cached token is dropped and the call retried once with a fresh one" {
    var h: Harness = undefined;
    h.init(&.{ unauthorized, ok });
    defer h.deinit();
    h.token.next_token = "ya29.fresh";

    _ = try h.get();
    try testing.expectEqual(2, h.fake.requests.items.len);
    try testing.expectEqual(1, h.token.invalidations);
    try testing.expectEqualStrings("ya29.fake-token", (try h.fake.request(0)).bearer.?);
    try testing.expectEqualStrings("ya29.fresh", (try h.fake.request(1)).bearer.?);
    // Re-authentication is not a retry: no backoff was waited.
    try testing.expectEqual(0, h.clock.sleep_count);
}

test "401: a second one is returned, with no third attempt" {
    var h: Harness = undefined;
    h.init(&.{ unauthorized, unauthorized, ok });
    defer h.deinit();
    try testing.expectError(error.Unauthenticated, h.get());
    try testing.expectEqual(2, h.fake.requests.items.len);
    try testing.expectEqual(1, h.token.invalidations);
    try testing.expectEqualStrings("Invalid Credentials", h.diag.message());
}

test "401: an opted-out call still retries once, because the server refused before acting" {
    var h: Harness = undefined;
    h.init(&.{ unauthorized, ok });
    defer h.deinit();
    const e = h.engine();
    _ = try e.execute(&h.arena, .{ .method = .POST, .path = "/v1/things:publish", .retry = false });
    try testing.expectEqual(2, h.fake.requests.items.len);
}

test "credentials: an unauthenticated endpoint gets no token and nothing to invalidate" {
    var h: Harness = undefined;
    h.init(&.{ unauthorized, ok });
    defer h.deinit();
    var e = h.engine();
    e.unauthenticated = true;
    e.token_provider = h.token.provider();
    h.token.quota_project = "billing-project";

    try testing.expectError(error.Unauthenticated, e.execute(&h.arena, .{ .method = .GET, .path = "/v1/things" }));
    try testing.expectEqual(1, h.fake.requests.items.len);
    const sent = try h.fake.request(0);
    try testing.expectEqual(null, sent.bearer);
    try testing.expectEqual(null, sent.header("x-goog-user-project"));
    try testing.expectEqual(0, h.token.calls);
    try testing.expectEqual(0, h.token.invalidations);
}

test "credentials: a token that cannot go in a header fails before sending" {
    var h: Harness = undefined;
    h.init(&.{ok});
    defer h.deinit();
    h.token.token = "ya29.trailing-newline\n";
    try testing.expectError(error.TokenUnavailable, h.get());
    try testing.expectEqual(0, h.fake.requests.items.len);
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "newlines") != null);
}

test "credentials: a provider's own explanation survives in shared diagnostics" {
    const Explaining = struct {
        diag: *Diagnostics,

        fn provider(self: *@This()) TokenProvider {
            return .{ .ptr = self, .vtable = &.{
                .getToken = getTokenFn,
                .invalidate = invalidateFn,
                .quotaProject = quotaProjectFn,
            } };
        }
        fn getTokenFn(ptr: *anyopaque, io: std.Io, arena: Allocator, scopes: []const []const u8) TokenProvider.Error![]const u8 {
            _ = io;
            _ = arena;
            _ = scopes;
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.diag.set(403, "PERMISSION_DENIED", "impersonation was refused: grant the role");
            return error.TokenEndpointRejected;
        }
        fn invalidateFn(_: *anyopaque) void {}
        fn quotaProjectFn(_: *anyopaque) ?[]const u8 {
            return null;
        }
    };
    var h: Harness = undefined;
    h.init(&.{ok});
    defer h.deinit();
    // What an application does: one Diagnostics, given to the credentials
    // and to the client alike.
    var explaining: Explaining = .{ .diag = &h.diag };
    var e = h.engine();
    e.token_provider = explaining.provider();
    try testing.expectError(error.TokenEndpointRejected, e.execute(&h.arena, .{ .method = .GET, .path = "/v1/things" }));
    try testing.expectEqualStrings("impersonation was refused: grant the role", h.diag.message());
    try testing.expectEqual(403, h.diag.http_status);
}

test "credentials: the provider's own failure is returned, not retried" {
    var h: Harness = undefined;
    h.init(&.{ok});
    defer h.deinit();
    h.token.fail = error.RefreshTokenInvalid;
    try testing.expectError(error.RefreshTokenInvalid, h.get());
    try testing.expectEqual(0, h.fake.requests.items.len);
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "token provider failed") != null);
}

test "quota: the credentials' project rides along, and one that is not a project id is refused" {
    var h: Harness = undefined;
    h.init(&.{ ok, ok });
    defer h.deinit();
    h.token.quota_project = "billing-project";
    _ = try h.get();
    try testing.expectEqualStrings("billing-project", (try h.fake.request(0)).header("x-goog-user-project").?);

    // Turned off, the header stays behind.
    var e = h.engine();
    e.send_quota_project = false;
    _ = try e.execute(&h.arena, .{ .method = .GET, .path = "/v1/things" });
    try testing.expectEqual(null, (try h.fake.request(1)).header("x-goog-user-project"));

    // A project that is not one never reaches the wire.
    h.token.quota_project = "not a project\r\nX-Injected: 1";
    try testing.expectError(error.InvalidResourceId, h.get());
    try testing.expectEqual(2, h.fake.requests.items.len);
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "invalid quota project") != null);
}

test "timeouts: every attempt carries the caller's deadline" {
    var h: Harness = undefined;
    h.init(&.{ unavailable, ok });
    defer h.deinit();
    var e = h.engine();
    e.request_timeout_ms = 4_500;
    _ = try e.execute(&h.arena, .{ .method = .GET, .path = "/v1/things" });
    try testing.expectEqual(4_500, (try h.fake.request(0)).timeout_ms);
    try testing.expectEqual(4_500, (try h.fake.request(1)).timeout_ms);
}

test "executeDiscard sends the call and keeps nothing" {
    var h: Harness = undefined;
    h.init(&.{ unavailable, .{ .respond = .{ .body = "{}" } } });
    defer h.deinit();
    const e = h.engine();
    try e.executeDiscard(.{ .method = .DELETE, .path = "/v1/things/1" });
    try testing.expectEqual(2, h.fake.requests.items.len);
    try testing.expectEqual(.DELETE, (try h.fake.request(0)).method);
}

/// Runs a retry through an arena over a wiping allocator on a fixed buffer,
/// and reports whether the failed attempt's body is still readable after.
fn failedBodySurvives(wipe: bool) !bool {
    const marker = "S3CR3T" ** 40;
    var h: Harness = undefined;
    h.init(&.{
        .{ .respond = .{ .status = 503, .body = "{\"error\":{\"status\":\"UNAVAILABLE\",\"message\":\"" ++ marker ++ "\"}}" } },
        .{ .respond = .{ .body = "{}" } },
    });
    defer h.deinit();

    var backing: [64 * 1024]u8 = @splat(0);
    var fba: std.heap.FixedBufferAllocator = .init(&backing);
    var wiping: WipingAllocator = .init(fba.allocator());
    var arena: std.heap.ArenaAllocator = .init(wiping.allocator());
    defer arena.deinit();
    const e = h.engine();
    _ = try e.execute(&arena, .{ .method = .GET, .path = "/v1/things", .wipe = wipe });
    return std.mem.indexOf(u8, &backing, marker) != null;
}

test "wipe: a failed attempt's body is wiped before the next attempt" {
    try testing.expect(!try failedBodySurvives(true));
    // Without the flag the failed body is kept for the next attempt to write
    // over, and what the shorter body does not cover stays readable. That is
    // the leak the flag closes, and it is what makes the check above real.
    try testing.expect(try failedBodySurvives(false));
}

test "wipe: the bearer token does not outlive the call" {
    const token = "ya29.a0-wiped-token-0123456789";
    var h: Harness = undefined;
    h.init(&.{ok});
    defer h.deinit();
    h.token.token = token;

    // The engine's own scratch memory comes from this allocator.
    var backing: [64 * 1024]u8 = @splat(0);
    var fba: std.heap.FixedBufferAllocator = .init(&backing);
    var e = h.engine();
    e.gpa = fba.allocator();
    _ = try e.execute(&h.arena, .{ .method = .GET, .path = "/v1/things", .wipe = true });
    try testing.expectEqual(null, std.mem.indexOf(u8, &backing, token));
    // The request really did carry it.
    try testing.expectEqualStrings(token, (try h.fake.request(0)).bearer.?);
}

fn retryPolicyProperty(_: void, input: []const u8) !void {
    var g: test_util.ByteGen = .init(input);
    const policy: RetryPolicy = .{
        .max_attempts = g.intRange(u8, 1, 6),
        .initial_backoff_ms = g.intRange(u32, 0, 1_000),
        .max_backoff_ms = g.intRange(u32, 0, 10_000),
    };
    var script: [8]Reply = undefined;
    for (&script) |*reply| reply.* = switch (g.intRange(u8, 0, 3)) {
        0 => ok,
        1 => unavailable,
        2 => .{ .respond = .{ .status = 404, .body = "{}" } },
        else => .{ .fail = error.ConnectionResetByPeer },
    };

    var h: Harness = undefined;
    h.init(&script);
    defer h.deinit();
    var e = h.engine();
    e.retry = policy;
    const outcome = e.execute(&h.arena, .{ .method = .GET, .path = "/v1/things" });

    const requests = h.fake.requests.items.len;
    try testing.expect(requests >= 1 and requests <= policy.max_attempts);
    // One wait between attempts, none before the first or after the last.
    try testing.expectEqual(requests - 1, h.clock.sleep_count);
    for (0..h.clock.sleep_count) |i| {
        try testing.expect(h.clock.sleepMs(i) <= policy.backoffCapMs(@intCast(i + 1)));
    }
    // A run stops at the first reply that is not retryable, and a success is
    // always the last thing that happened.
    if (outcome) |_| {
        try testing.expectEqual(Reply.respond, std.meta.activeTag(script[requests - 1]));
        try testing.expectEqual(200, script[requests - 1].respond.status);
    } else |err| {
        if (requests < policy.max_attempts) try testing.expect(!isRetryable(err));
    }
}

test "fuzz retry: attempts and waits follow the policy for any sequence of failures" {
    try test_util.fuzzBytes({}, retryPolicyProperty, .{ .corpus = &.{
        "\x05\x00\x00\x00\x64\x00\x00\x27\x10\x01\x01\x01\x00\x00\x00\x00",
        "\x01\x00\x00\x00\x00\x00\x00\x00\x00\x03\x03\x03\x03\x03\x03\x03\x03",
        "\x06\x00\x00\x03\xe8\x00\x00\x27\x10\x02\x00\x01\x02\x03\x00\x01",
    } });
}

// The streaming loop, driven the same way.

test "executeStream: a success returns status, headers and body, and sends segments" {
    var h: Harness = undefined;
    h.init(&.{.{ .respond = .{
        .status = 200,
        .body = "{\"name\":\"o\"}",
        .headers = &.{.{ .name = "x-goog-generation", .value = "7" }},
    } }});
    defer h.deinit();
    const e = h.engine();
    e.begin();
    const res = try e.executeStream(&h.arena, .{
        .method = .POST,
        .path = "/upload/v1/b/b/o?uploadType=multipart",
        .content_type = "multipart/related; boundary=b",
        .body = .{ .segments = &.{ "--b\r\n", "data", "\r\n--b--\r\n" } },
    });
    try testing.expectEqual(200, res.status);
    try testing.expectEqualStrings("{\"name\":\"o\"}", res.body);
    try testing.expectEqualStrings("7", res.header("x-goog-generation").?);

    const sent = try h.fake.streamRequest(0);
    try testing.expectEqualStrings("https://service.googleapis.com/upload/v1/b/b/o?uploadType=multipart", sent.url);
    try testing.expectEqualStrings("multipart/related; boundary=b", sent.content_type.?);
    try testing.expectEqualStrings("--b\r\ndata\r\n--b--\r\n", sent.body_prefix);
    try testing.expectEqualStrings("ya29.fake-token", sent.bearer.?);
}

test "executeStream: a non-2xx maps by status and fills the diagnostics" {
    var h: Harness = undefined;
    h.init(&.{.{ .respond = .{
        .status = 404,
        .body = "{\"error\":{\"code\":404,\"message\":\"No such object\",\"errors\":[{\"reason\":\"notFound\"}]}}",
    } }});
    defer h.deinit();
    const e = h.engine();
    e.begin();
    try testing.expectError(error.NotFound, e.executeStream(&h.arena, .{ .method = .GET, .path = "/v1/o" }));
    try testing.expectEqual(404, h.diag.http_status);
    try testing.expectEqualStrings("notFound", h.diag.status());
    try testing.expectEqualStrings("No such object", h.diag.message());
}

test "executeStream: a buffered sink retries statuses and transport failures alike" {
    var h: Harness = undefined;
    h.init(&.{ unavailable, .{ .fail = error.ConnectionResetByPeer }, ok });
    defer h.deinit();
    const res = try h.engine().executeStream(&h.arena, .{ .method = .GET, .path = "/v1/things" });
    try testing.expectEqual(200, res.status);
    try testing.expectEqual(3, h.fake.stream_requests.items.len);
    try testing.expectEqual(2, h.clock.sleep_count);
}

test "executeStream: a writer sink retries a status but never a mid-body failure" {
    var h: Harness = undefined;
    h.init(&.{
        // A 503 is buffered, the writer untouched: safe to retry.
        unavailable,
        // Then the connection drops after five bytes reached the writer.
        .{ .respond = .{ .status = 200, .body = "hello world\n", .cut_after = 5 } },
    });
    defer h.deinit();
    var out_buf: [64]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    try testing.expectError(error.ConnectionResetByPeer, h.engine().executeStream(&h.arena, .{
        .method = .GET,
        .path = "/v1/o?alt=media",
        .sink = .{ .writer = &out },
    }));
    // Both requests went out: the 503 was retried, the cut was not.
    try testing.expectEqual(2, h.fake.stream_requests.items.len);
    try testing.expectEqualStrings("hello", out.buffered());
}

test "executeStream: the caller's writer failing is final" {
    var h: Harness = undefined;
    h.init(&.{.{ .respond = .{ .status = 200, .body = "hello world\n" } }});
    defer h.deinit();
    var out_buf: [4]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    try testing.expectError(error.WriteFailed, h.engine().executeStream(&h.arena, .{
        .method = .GET,
        .path = "/v1/o?alt=media",
        .sink = .{ .writer = &out },
    }));
    try testing.expectEqual(1, h.fake.stream_requests.items.len);
}

test "executeStream: a 401 is retried once with a fresh token, whatever the sink" {
    var h: Harness = undefined;
    h.init(&.{ unauthorized, ok });
    defer h.deinit();
    var out_buf: [64]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    const res = try h.engine().executeStream(&h.arena, .{
        .method = .GET,
        .path = "/v1/o?alt=media",
        .sink = .{ .writer = &out },
        .retry = false,
    });
    try testing.expectEqual(200, res.status);
    try testing.expectEqual(1, h.token.invalidations);
    try testing.expectEqual(2, h.fake.stream_requests.items.len);
}

test "executeStream: retry off means one attempt" {
    var h: Harness = undefined;
    h.init(&.{unavailable});
    defer h.deinit();
    try testing.expectError(error.Unavailable, h.engine().executeStream(&h.arena, .{
        .method = .POST,
        .path = "/v1/upload",
        .body = .{ .segments = &.{"data"} },
        .retry = false,
    }));
    try testing.expectEqual(1, h.fake.stream_requests.items.len);
    try testing.expectEqual(0, h.clock.sleep_count);
}
