//! The IAM Credentials API's `generateAccessToken`: trades a token that is
//! allowed to act as a service account for one that acts as it. Workload
//! identity federation calls it after the STS exchange, and impersonated
//! service account credentials after the source login.

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("core");
const TokenProvider = core.TokenProvider;
const Transport = core.transport.Transport;
const Cache = @import("Cache.zig");

/// Google's endpoint: scheme and host.
pub const default_endpoint = "https://iamcredentials.googleapis.com";

/// A scope that lets a token call this API. gcloud's logins carry it.
pub const scope = "https://www.googleapis.com/auth/cloud-platform";

/// The longest service account email.
pub const max_principal_len = 254;

pub const Request = struct {
    /// The full `...:generateAccessToken` URL.
    url: []const u8,
    /// The caller's token: the one allowed to act as the service account.
    bearer: []const u8,
    /// The scopes the new token is for, space-joined.
    scopes: []const u8,
    /// Seconds the new token should live.
    lifetime_s: u32,
    /// The chain of accounts between the caller and the target, each as
    /// `projects/-/serviceAccounts/EMAIL`, passed through as given. Usually
    /// there are none.
    delegates: []const []const u8 = &.{},
    timeout_ms: u32,
};

pub const Outcome = union(enum) {
    token: Cache.Fetched,
    /// A transient failure, worth another attempt.
    retry: TokenProvider.Error,
    /// The bearer token was refused with HTTP 401: a fresh one may do.
    unauthorized,
    fail: TokenProvider.Error,
};

/// Makes the call. The token and everything else that touches it are in
/// `arena`, which the caller wipes. `refused` is the diagnostics message
/// for HTTP 403, which should name the missing role: it differs by who is
/// asking.
pub fn generateAccessToken(
    transport: Transport,
    io: std.Io,
    arena: Allocator,
    request: Request,
    diag: ?*core.Diagnostics,
    refused: []const u8,
) Outcome {
    const body = encodeBody(arena, request) catch return .{ .fail = error.OutOfMemory };
    const res = transport.send(.{
        .method = .POST,
        .url = request.url,
        .bearer = request.bearer,
        .body = body,
        .content_type = .json,
        .timeout_ms = request.timeout_ms,
    }, arena) catch |err| {
        if (diag) |d| d.print("the IAM Credentials endpoint could not be reached: {t}", .{err});
        return if (core.isRetryable(err)) .{ .retry = err } else .{ .fail = err };
    };
    if (res.status != 200) {
        const error_body = core.errors.decodeErrorBody(arena, res.body) catch |err| return .{ .fail = err };
        if (diag) |d| {
            const status = if (error_body) |b| b.status else "";
            if (res.status == 403) {
                d.set(res.status, status, refused);
            } else {
                d.set(res.status, status, if (error_body) |b| b.message else res.body);
            }
        }
        if (res.status == 401) return .unauthorized;
        if (res.status == 429 or res.status >= 500) return .{ .retry = error.TokenUnavailable };
        return .{ .fail = error.TokenEndpointRejected };
    }
    return decodeToken(io, arena, res.body, diag);
}

/// `{"delegates":[...],"scope":[...],"lifetime":"3600s"}`, with `delegates`
/// left out when there are none.
pub fn encodeBody(arena: Allocator, request: Request) Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    var json: std.json.Stringify = .{ .writer = &out.writer };
    writeBody(&json, request) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn writeBody(json: *std.json.Stringify, request: Request) std.json.Stringify.Error!void {
    try json.beginObject();
    if (request.delegates.len > 0) {
        try json.objectField("delegates");
        try json.write(request.delegates);
    }
    try json.objectField("scope");
    try json.beginArray();
    var scopes = std.mem.splitScalar(u8, request.scopes, ' ');
    while (scopes.next()) |one| try json.write(one);
    try json.endArray();
    try json.objectField("lifetime");
    var buf: [16]u8 = undefined;
    try json.write(std.fmt.bufPrint(&buf, "{d}s", .{request.lifetime_s}) catch unreachable);
    try json.endObject();
}

/// The token and its expiry, from a 200 answer.
fn decodeToken(io: std.Io, arena: Allocator, body: []const u8, diag: ?*core.Diagnostics) Outcome {
    const Wire = struct {
        accessToken: ?[]const u8 = null,
        expireTime: ?[]const u8 = null,
    };
    const wire = std.json.parseFromSliceLeaky(Wire, arena, body, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => return .{ .fail = error.OutOfMemory },
        else => return invalid(diag),
    };
    const token = wire.accessToken orelse return invalid(diag);
    const expire_text = wire.expireTime orelse return invalid(diag);
    const expires_at = core.timestamp.parse(expire_text) catch return invalid(diag);
    const now = std.Io.Clock.real.now(io);
    const expires_in = @divFloor(expires_at.nanoseconds - now.nanoseconds, std.time.ns_per_s);
    if (expires_in <= 0) return invalid(diag);
    return .{ .token = .{ .token = token, .expires_in = @intCast(@min(expires_in, std.math.maxInt(i64))) } };
}

fn invalid(diag: ?*core.Diagnostics) Outcome {
    if (diag) |d| d.print("the IAM Credentials answer has no usable accessToken and expireTime", .{});
    return .{ .fail = error.InvalidTokenResponse };
}

/// `{endpoint}/v1/projects/-/serviceAccounts/{principal}:generateAccessToken`.
/// `principal` has passed `isPrincipal`, so it needs no encoding. Sized
/// exactly and allocated once, so no half-built copy is ever freed.
pub fn url(gpa: Allocator, endpoint: []const u8, principal: []const u8) Allocator.Error![]u8 {
    const format = "{s}/v1/projects/-/serviceAccounts/{s}:generateAccessToken";
    const args = .{ std.mem.trimEnd(u8, endpoint, "/"), principal };
    const out = try gpa.alloc(u8, std.fmt.count(format, args));
    return std.fmt.bufPrint(out, format, args) catch unreachable;
}

/// The service account a `...:generateAccessToken` URL names, found the way
/// Google's own libraries find it: between the last `/` and
/// `:generateAccessToken`. Null when the URL has another shape, or when
/// what it names is not an email or a numeric id.
pub fn principalFromUrl(text: []const u8) ?[]const u8 {
    const suffix = ":generateAccessToken";
    const end = std.mem.indexOf(u8, text, suffix) orelse return null;
    // Nothing may follow the method: no query, no second suffix.
    if (end + suffix.len != text.len) return null;
    const start = (std.mem.lastIndexOfScalar(u8, text[0..end], '/') orelse return null) + 1;
    const principal = text[start..end];
    return if (isPrincipal(principal)) principal else null;
}

/// A service account's email or numeric unique id: 1 to 254 characters from
/// `[A-Za-z0-9@._-]`. Anything else could reshape the URL it goes into.
pub fn isPrincipal(text: []const u8) bool {
    if (text.len == 0 or text.len > max_principal_len) return false;
    for (text) |c| switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '@', '.', '_', '-' => {},
        else => return false,
    };
    return true;
}

const testing = std.testing;
const test_util = core.testing;
const Reply = test_util.FakeTransport.Reply;

const target = "sa@p.iam.gserviceaccount.com";
const target_url = "https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/" ++ target ++ ":generateAccessToken";

fn call(fake: *test_util.FakeTransport, arena: Allocator, diag: *core.Diagnostics, delegates: []const []const u8) Outcome {
    return generateAccessToken(fake.transport(), testing.io, arena, .{
        .url = target_url,
        .bearer = "ya29.SOURCE",
        .scopes = "https://www.googleapis.com/auth/pubsub https://www.googleapis.com/auth/cloud-platform",
        .lifetime_s = 3600,
        .delegates = delegates,
        .timeout_ms = 5_000,
    }, diag, "refused: grant the role");
}

test "golden: the request, with and without delegates" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const ok: Reply = .{ .respond = .{ .body = "{\"accessToken\":\"ya29.IMPERSONATED\",\"expireTime\":\"2100-01-01T00:00:00Z\"}" } };
    var fake: test_util.FakeTransport = .init(testing.allocator, &.{ ok, ok });
    defer fake.deinit();
    var diag: core.Diagnostics = .{};

    const plain = call(&fake, arena.allocator(), &diag, &.{});
    try testing.expectEqualStrings("ya29.IMPERSONATED", plain.token.token);
    try testing.expect(plain.token.expires_in > 0);
    const sent = try fake.request(0);
    try testing.expectEqual(.POST, sent.method);
    try testing.expectEqualStrings(target_url, sent.url);
    try testing.expectEqualStrings("ya29.SOURCE", sent.bearer.?);
    try testing.expectEqual(.json, sent.content_type);
    try testing.expectEqualStrings(
        "{\"scope\":[\"https://www.googleapis.com/auth/pubsub\",\"https://www.googleapis.com/auth/cloud-platform\"],\"lifetime\":\"3600s\"}",
        sent.body.?,
    );

    _ = call(&fake, arena.allocator(), &diag, &.{"projects/-/serviceAccounts/middle@p.iam.gserviceaccount.com"});
    try testing.expectEqualStrings(
        "{\"delegates\":[\"projects/-/serviceAccounts/middle@p.iam.gserviceaccount.com\"],\"scope\":[\"https://www.googleapis.com/auth/pubsub\",\"https://www.googleapis.com/auth/cloud-platform\"],\"lifetime\":\"3600s\"}",
        (try fake.request(1)).body.?,
    );
}

test "outcomes: each status says what to do next" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diag: core.Diagnostics = .{};
    const cases = [_]struct { Reply, std.meta.Tag(Outcome) }{
        .{ .{ .respond = .{ .status = 401, .body = "{\"error\":{\"status\":\"UNAUTHENTICATED\",\"message\":\"expired\"}}" } }, .unauthorized },
        .{ .{ .respond = .{ .status = 403, .body = "{\"error\":{\"status\":\"PERMISSION_DENIED\",\"message\":\"denied\"}}" } }, .fail },
        .{ .{ .respond = .{ .status = 404, .body = "{\"error\":{\"status\":\"NOT_FOUND\",\"message\":\"no such account\"}}" } }, .fail },
        .{ .{ .respond = .{ .status = 429, .body = "{}" } }, .retry },
        .{ .{ .respond = .{ .status = 503, .body = "unavailable" } }, .retry },
        .{ .{ .fail = error.ConnectionResetByPeer }, .retry },
        .{ .{ .fail = error.Canceled }, .fail },
        .{ .{ .respond = .{ .body = "{\"accessToken\":\"t\"}" } }, .fail },
        .{ .{ .respond = .{ .body = "{\"accessToken\":\"t\",\"expireTime\":\"2000-01-01T00:00:00Z\"}" } }, .fail },
        .{ .{ .respond = .{ .body = "<html>" } }, .fail },
    };
    for (cases) |case| {
        var fake: test_util.FakeTransport = .init(testing.allocator, &.{case[0]});
        defer fake.deinit();
        const outcome = call(&fake, arena.allocator(), &diag, &.{});
        try testing.expectEqual(case[1], std.meta.activeTag(outcome));
    }
}

test "a 403 names the missing role, and other failures keep the server's words" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diag: core.Diagnostics = .{};
    var fake: test_util.FakeTransport = .init(testing.allocator, &.{
        .{ .respond = .{ .status = 403, .body = "{\"error\":{\"status\":\"PERMISSION_DENIED\",\"message\":\"denied\"}}" } },
        .{ .respond = .{ .status = 404, .body = "{\"error\":{\"status\":\"NOT_FOUND\",\"message\":\"no such account\"}}" } },
    });
    defer fake.deinit();
    try testing.expectEqual(error.TokenEndpointRejected, call(&fake, arena.allocator(), &diag, &.{}).fail);
    try testing.expectEqualStrings("refused: grant the role", diag.message());
    try testing.expectEqual(403, diag.http_status);
    try testing.expectEqual(error.TokenEndpointRejected, call(&fake, arena.allocator(), &diag, &.{}).fail);
    try testing.expectEqualStrings("no such account", diag.message());
}

test "principalFromUrl finds the account the way Google's libraries do" {
    try testing.expectEqualStrings(target, principalFromUrl(target_url).?);
    try testing.expectEqualStrings("123456789", principalFromUrl("https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/123456789:generateAccessToken").?);
    // Whatever host the file names, only the account is taken from it.
    try testing.expectEqualStrings(target, principalFromUrl("https://evil.example.com/x/" ++ target ++ ":generateAccessToken").?);
    for ([_][]const u8{
        "",
        "https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/sa@p.iam.gserviceaccount.com",
        "https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/:generateAccessToken",
        "https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/sa@p:generateAccessToken?x=1",
        "https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/sa@p:generateAccessToken:generateAccessToken",
        "https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/sa%40p:generateAccessToken",
        "https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/s a@p:generateAccessToken",
        "sa@p:generateAccessToken",
    }) |bad| {
        if (principalFromUrl(bad)) |got| {
            std.debug.print("accepted {s} from {s}\n", .{ got, bad });
            return error.TestUnexpectedPrincipal;
        }
    }
}

test "url builds Google's endpoint around the account" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings(target_url, try url(arena.allocator(), default_endpoint, target));
    try testing.expectEqualStrings(
        "http://127.0.0.1:8080/v1/projects/-/serviceAccounts/" ++ target ++ ":generateAccessToken",
        try url(arena.allocator(), "http://127.0.0.1:8080/", target),
    );
}

fn principalProperty(_: void, input: []const u8) !void {
    const found = principalFromUrl(input) orelse return;
    // What comes out is always a plain account name: safe in a path segment,
    // and exactly what sat before the method.
    try testing.expect(isPrincipal(found));
    try testing.expect(std.mem.indexOfAny(u8, found, "/?#:% \r\n") == null);
    try testing.expect(std.mem.endsWith(u8, input, ":generateAccessToken"));
    const before = input[0 .. input.len - ":generateAccessToken".len];
    try testing.expect(std.mem.endsWith(u8, before, found));
    // Rebuilt around Google's endpoint, it names that account and nothing more.
    var buf: [512]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buf);
    const rebuilt = try url(fba.allocator(), default_endpoint, found);
    try testing.expectEqualStrings(found, principalFromUrl(rebuilt).?);
    try testing.expect(std.mem.startsWith(u8, rebuilt, default_endpoint ++ "/v1/projects/-/serviceAccounts/"));
}

test "fuzz principalFromUrl: only a plain account name ever comes out" {
    try test_util.fuzzBytes({}, principalProperty, .{ .corpus = &.{
        target_url,
        "https://evil.example.com/x/" ++ target ++ ":generateAccessToken",
        "a/b:generateAccessToken",
        "/:generateAccessToken",
        "x/sa%40p:generateAccessToken",
    } });
}
