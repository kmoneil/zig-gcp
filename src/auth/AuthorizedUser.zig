//! Tokens for a person's Google account. `gcloud auth application-default
//! login` saves a refresh token in a credentials file. This provider trades
//! it for an access token at Google's OAuth token endpoint, and its cache
//! keeps that token until shortly before it expires.
//!
//! The refresh token, the client secret and every access token are secrets:
//! they are never logged or put in `Diagnostics`, they go only to the token
//! endpoint, and memory that held them is wiped before it is freed.

const AuthorizedUser = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("core");
const TokenProvider = core.TokenProvider;
const Diagnostics = core.Diagnostics;
const HttpTransport = core.transport.HttpTransport;
const Transport = core.transport.Transport;
const Cache = @import("Cache.zig");
const adc_file = @import("adc_file.zig");
const form = @import("form.zig");
const logging = @import("logging.zig");
const token_response = @import("token_response.zig");

gpa: Allocator,
/// All owned, and all wiped before they are freed: only the client secret
/// and the refresh token are secret, but wiping costs nothing.
client_id: []u8,
client_secret: []u8,
refresh_token: []u8,
quota_project_id: ?[]u8,
token_url: []u8,
user_agent: []u8,
request_timeout_ms: u32,
retry: core.RetryPolicy,
diagnostics: ?*Diagnostics,
cache: Cache,
transport: Transport,
/// The built-in transport, when `Options.transport` was null.
http: ?*HttpTransport,

pub const Options = struct {
    /// Google's OAuth token endpoint. Plain http is accepted only to this
    /// machine (127.0.0.1, [::1] or localhost), as tests use.
    token_url: []const u8 = "https://oauth2.googleapis.com/token",
    /// A token fetch sits in front of every API call, so it gives up sooner
    /// than an API call would.
    retry: core.RetryPolicy = .{ .max_attempts = 3 },
    cache: Cache.Options = .{},
    /// How long one request to the token endpoint may take before it is
    /// `error.TimedOut`, which the retry policy treats as transient. 0
    /// removes the limit.
    request_timeout_ms: u32 = 30_000,
    /// Printable ASCII.
    user_agent: []const u8 = "zig-gcp-auth/0.16",
    /// Filled with the details of the last failure, while reading the file
    /// or from the token endpoint. Never holds a secret.
    diagnostics: ?*Diagnostics = null,
    /// Sends requests through this instead of `std.http.Client`.
    transport: ?Transport = null,
};

pub const InitError = error{
    /// The file is missing or cannot be read.
    CredentialsFileNotFound,
    InvalidCredentialsFile,
    UnsupportedCredentialType,
    /// A token URL that is neither https nor on this machine, or an invalid
    /// retry policy, cache setting or user agent.
    InvalidOptions,
    Canceled,
    OutOfMemory,
};

/// Reads the credentials file at `path`, such as
/// `~/.config/gcloud/application_default_credentials.json`. Files over
/// 64 KiB are refused.
pub fn initFromFile(gpa: Allocator, io: std.Io, path: []const u8, options: Options) InitError!AuthorizedUser {
    if (options.diagnostics) |d| d.clear();
    // The file holds the refresh token: read it into memory that is wiped.
    var wiping: core.WipingAllocator = .init(gpa);
    var scratch: std.heap.ArenaAllocator = .init(wiping.allocator());
    defer scratch.deinit();
    const json = try adc_file.readFile(io, scratch.allocator(), path, options.diagnostics);
    return initFromJson(gpa, io, json, options);
}

/// Reads credentials from the contents of a credentials file. Copies what
/// it keeps; `json` can be wiped as soon as this returns.
pub fn initFromJson(gpa: Allocator, io: std.Io, json: []const u8, options: Options) InitError!AuthorizedUser {
    const diag = options.diagnostics;
    if (diag) |d| d.clear();
    if (!isAcceptableTokenUrl(options.token_url)) {
        if (diag) |d| d.print("invalid token_url: it must use https, or http to this machine", .{});
        return error.InvalidOptions;
    }
    if (!options.retry.isValid()) {
        if (diag) |d| d.print("invalid retry policy: max_attempts must be at least 1, multiplier finite and at least 1", .{});
        return error.InvalidOptions;
    }
    if (!isPrintable(options.user_agent)) {
        if (diag) |d| d.print("invalid user agent: expected printable ASCII", .{});
        return error.InvalidOptions;
    }
    var cache = Cache.init(gpa, options.cache) catch {
        if (diag) |d| d.print("invalid cache options: refresh_margin_s must be below 300, and max_lifetime_s above 0", .{});
        return error.InvalidOptions;
    };
    errdefer cache.deinit();

    var wiping: core.WipingAllocator = .init(gpa);
    var scratch: std.heap.ArenaAllocator = .init(wiping.allocator());
    defer scratch.deinit();
    const file = switch (try adc_file.parse(scratch.allocator(), json, diag)) {
        .authorized_user => |user| user,
        .service_account => {
            if (diag) |d| d.print("the credentials file is a service account key; use ServiceAccount, or findDefault", .{});
            return error.UnsupportedCredentialType;
        },
        .external_account => {
            if (diag) |d| d.print("the credentials file is a workload identity federation file; use ExternalAccount, or findDefault", .{});
            return error.UnsupportedCredentialType;
        },
        .impersonated_service_account => {
            if (diag) |d| d.print("the credentials file impersonates a service account; use ImpersonatedServiceAccount, or findDefault", .{});
            return error.UnsupportedCredentialType;
        },
    };

    const client_id = try gpa.dupe(u8, file.client_id);
    errdefer wipeFree(gpa, client_id);
    const client_secret = try gpa.dupe(u8, file.client_secret);
    errdefer wipeFree(gpa, client_secret);
    const refresh_token = try gpa.dupe(u8, file.refresh_token);
    errdefer wipeFree(gpa, refresh_token);
    const quota_project_id = if (file.quota_project_id) |q| try gpa.dupe(u8, q) else null;
    errdefer if (quota_project_id) |q| wipeFree(gpa, q);
    const token_url = try gpa.dupe(u8, options.token_url);
    errdefer wipeFree(gpa, token_url);
    const user_agent = try gpa.dupe(u8, options.user_agent);
    errdefer wipeFree(gpa, user_agent);

    var http: ?*HttpTransport = null;
    const transport = options.transport orelse t: {
        const h = try gpa.create(HttpTransport);
        h.* = .init(gpa, io, user_agent);
        http = h;
        break :t h.transport();
    };
    return .{
        .gpa = gpa,
        .client_id = client_id,
        .client_secret = client_secret,
        .refresh_token = refresh_token,
        .quota_project_id = quota_project_id,
        .token_url = token_url,
        .user_agent = user_agent,
        .request_timeout_ms = options.request_timeout_ms,
        .retry = options.retry,
        .diagnostics = diag,
        .cache = cache,
        .transport = transport,
        .http = http,
    };
}

/// Wipes the refresh token, the client secret and the cached access token.
pub fn deinit(self: *AuthorizedUser) void {
    self.cache.deinit();
    if (self.http) |h| {
        h.deinit();
        self.gpa.destroy(h);
    }
    wipeFree(self.gpa, self.client_id);
    wipeFree(self.gpa, self.client_secret);
    wipeFree(self.gpa, self.refresh_token);
    if (self.quota_project_id) |q| wipeFree(self.gpa, q);
    wipeFree(self.gpa, self.token_url);
    wipeFree(self.gpa, self.user_agent);
    self.* = undefined;
}

/// The provider points at this struct, which must not move while the
/// provider is in use.
pub fn provider(self: *AuthorizedUser) TokenProvider {
    return .{ .ptr = self, .vtable = &.{
        .getToken = getToken,
        .invalidate = invalidate,
        .quotaProject = quotaProject,
    } };
}

/// The project the credentials file names for quota, if any.
pub fn quotaProjectId(self: *const AuthorizedUser) ?[]const u8 {
    return self.quota_project_id;
}

fn fromPtr(ptr: *anyopaque) *AuthorizedUser {
    return @ptrCast(@alignCast(ptr));
}

fn getToken(ptr: *anyopaque, io: std.Io, arena: Allocator, scopes: []const []const u8) TokenProvider.Error![]const u8 {
    // The scopes were fixed when the user logged in; a refresh cannot widen them.
    _ = scopes;
    const self = fromPtr(ptr);
    return self.cache.getToken(io, arena, .{ .ptr = self, .fetchFn = fetch });
}

fn invalidate(ptr: *anyopaque) void {
    fromPtr(ptr).cache.invalidate();
}

fn quotaProject(ptr: *anyopaque) ?[]const u8 {
    return fromPtr(ptr).quota_project_id;
}

/// Trades the refresh token for an access token. `arena` is the cache's
/// scratch memory, which it wipes: the body built here carries secrets.
fn fetch(ptr: *anyopaque, io: std.Io, arena: Allocator) TokenProvider.Error!Cache.Fetched {
    const self = fromPtr(ptr);
    const body = try form.encode(arena, &.{
        .{ .name = "grant_type", .value = "refresh_token" },
        .{ .name = "client_id", .value = self.client_id },
        .{ .name = "client_secret", .value = self.client_secret },
        .{ .name = "refresh_token", .value = self.refresh_token },
    });
    const max_attempts = self.retry.max_attempts;
    var attempt: u32 = 1;
    while (true) : (attempt += 1) {
        const started = std.Io.Clock.awake.now(io);
        const result = self.exchange(arena, body);
        const elapsed_ms = started.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds();
        switch (result) {
            .token => |fetched| {
                logging.debug("POST {s} -> a token in {d} ms (attempt {d} of {d})", .{ self.token_url, elapsed_ms, attempt, max_attempts });
                return fetched;
            },
            .fail => |err| {
                logging.debug("POST {s} -> {t} in {d} ms (attempt {d} of {d})", .{ self.token_url, err, elapsed_ms, attempt, max_attempts });
                return err;
            },
            .retry => |err| {
                logging.debug("POST {s} -> {t} in {d} ms (attempt {d} of {d})", .{ self.token_url, err, elapsed_ms, attempt, max_attempts });
                if (attempt >= max_attempts) return err;
                const delay_ms = self.retry.backoffMs(attempt, entropy(io));
                logging.warn("the token endpoint failed with {t}; retrying in {d} ms (attempt {d} of {d})", .{
                    err, delay_ms, attempt + 1, max_attempts,
                });
                try io.sleep(.fromMilliseconds(delay_ms), .awake);
            },
        }
    }
}

const Result = union(enum) {
    token: Cache.Fetched,
    /// Worth another attempt.
    retry: TokenProvider.Error,
    fail: TokenProvider.Error,
};

/// One request to the token endpoint, and what to make of the answer.
fn exchange(self: *AuthorizedUser, arena: Allocator, body: []const u8) Result {
    const res = self.transport.send(.{
        .method = .POST,
        .url = self.token_url,
        .body = body,
        .content_type = .form,
        .timeout_ms = self.request_timeout_ms,
    }, arena) catch |err| {
        if (self.diagnostics) |d| d.print("the token endpoint could not be reached: {t}", .{err});
        return if (core.isRetryable(err)) .{ .retry = err } else .{ .fail = err };
    };
    if (res.status == 200) {
        const fetched = token_response.parse(arena, res.body) catch |err| {
            if (err == error.InvalidTokenResponse) {
                if (self.diagnostics) |d| d.print("the token endpoint's answer has no usable access_token and expires_in", .{});
            }
            return .{ .fail = err };
        };
        return .{ .token = fetched };
    }
    const oauth = token_response.parseError(arena, res.body) catch |err| return .{ .fail = err };
    if (self.diagnostics) |d| {
        if (oauth) |e| {
            if (std.mem.eql(u8, e.code, "invalid_grant")) {
                const fix = "Run `gcloud auth application-default login` again.";
                const generic = "The refresh token no longer works. " ++ fix;
                var buf: [400]u8 = undefined;
                const message = if (e.description.len == 0)
                    generic
                else
                    std.fmt.bufPrint(&buf, "{s} " ++ fix, .{e.description}) catch generic;
                d.set(res.status, e.code, message);
            } else {
                d.set(res.status, e.code, e.description);
            }
        } else {
            // Not an OAuth error, so not a message this code can vouch for.
            d.set(res.status, "", "the token endpoint refused the request");
        }
    }
    if (res.status == 429 or res.status >= 500) return .{ .retry = error.TokenUnavailable };
    if (oauth) |e| if (std.mem.eql(u8, e.code, "invalid_grant")) return .{ .fail = error.RefreshTokenInvalid };
    return .{ .fail = error.TokenEndpointRejected };
}

fn entropy(io: std.Io) u64 {
    var bytes: [8]u8 = undefined;
    io.random(&bytes);
    return std.mem.readInt(u64, &bytes, .little);
}

/// Wipes `buf` and frees it with `rawFree`, so the wipe is the last write.
fn wipeFree(gpa: Allocator, buf: []u8) void {
    if (buf.len == 0) return;
    std.crypto.secureZero(u8, buf);
    gpa.rawFree(buf, .of(u8), @returnAddress());
}

const isAcceptableTokenUrl = token_response.isAcceptableTokenUrl;

fn isPrintable(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text) |c| if (c < ' ' or c >= 0x7f) return false;
    return true;
}

const testing = std.testing;
const test_util = core.testing;
const Reply = test_util.FakeTransport.Reply;

const file_json =
    \\{"type": "authorized_user", "client_id": "id.apps.googleusercontent.com",
    \\ "client_secret": "SECRET-cs", "refresh_token": "1//SECRET-rt/x+y=z",
    \\ "quota_project_id": "billing-project"}
;
const token_ok: Reply = .{ .respond = .{ .body = "{\"access_token\":\"ya29.SECRET-at\",\"expires_in\":3599,\"token_type\":\"Bearer\"}" } };
const unavailable: Reply = .{ .respond = .{ .status = 503, .body = "Service Unavailable" } };
const expected_body = "grant_type=refresh_token&client_id=id.apps.googleusercontent.com&client_secret=SECRET-cs&refresh_token=1%2F%2FSECRET-rt%2Fx%2By%3Dz";
const test_scopes: []const []const u8 = &.{"https://www.googleapis.com/auth/cloud-platform"};

/// An `AuthorizedUser` wired to a fake transport and a fake clock.
const Harness = struct {
    fake: test_util.FakeTransport,
    clock: test_util.FakeClock,
    diag: Diagnostics,
    arena: std.heap.ArenaAllocator,
    user: AuthorizedUser,

    /// Initializes in place: the user points into the harness.
    fn init(h: *Harness, script: []const Reply) !void {
        h.* = .{
            .fake = .init(testing.allocator, script),
            .clock = .{},
            .diag = .{},
            .arena = .init(testing.allocator),
            .user = undefined,
        };
        errdefer h.fake.deinit();
        errdefer h.arena.deinit();
        h.user = try .initFromJson(testing.allocator, h.clock.io(), file_json, .{
            .diagnostics = &h.diag,
            .transport = h.fake.transport(),
        });
    }

    fn deinit(h: *Harness) void {
        h.user.deinit();
        h.arena.deinit();
        h.fake.deinit();
    }

    fn get(h: *Harness) TokenProvider.Error![]const u8 {
        return h.user.provider().getToken(h.clock.io(), h.arena.allocator(), test_scopes);
    }
};

test "AuthorizedUser: the refresh is a form POST with every value encoded" {
    var h: Harness = undefined;
    try h.init(&.{token_ok});
    defer h.deinit();
    try testing.expectEqualStrings("ya29.SECRET-at", try h.get());
    const req = try h.fake.request(0);
    try testing.expectEqual(.POST, req.method);
    try testing.expectEqualStrings("https://oauth2.googleapis.com/token", req.url);
    try testing.expectEqual(.form, req.content_type);
    try testing.expectEqual(null, req.bearer);
    try testing.expectEqualStrings(expected_body, req.body.?);
}

test "AuthorizedUser: the refresh carries a deadline of its own" {
    var h: Harness = undefined;
    try h.init(&.{token_ok});
    defer h.deinit();
    _ = try h.get();
    // The token endpoint is on the internet, and a fetch sits in front of
    // every API call, so it gives up well before one would.
    try testing.expectEqual(30_000, (try h.fake.request(0)).timeout_ms);
}

test "AuthorizedUser: the token is kept until it goes stale" {
    var h: Harness = undefined;
    try h.init(&.{ token_ok, token_ok });
    defer h.deinit();
    _ = try h.get();
    _ = try h.get();
    try testing.expectEqual(1, h.fake.requests.items.len);
    h.clock.now_ns += 3400 * std.time.ns_per_s;
    _ = try h.get();
    try testing.expectEqual(2, h.fake.requests.items.len);
}

test "AuthorizedUser: invalid_grant is RefreshTokenInvalid, not retried, and says how to fix it" {
    var h: Harness = undefined;
    try h.init(&.{.{ .respond = .{
        .status = 400,
        .body = "{\"error\":\"invalid_grant\",\"error_description\":\"Token has been expired or revoked.\"}",
    } }});
    defer h.deinit();
    try testing.expectError(error.RefreshTokenInvalid, h.get());
    try testing.expectEqual(1, h.fake.requests.items.len);
    try testing.expectEqual(400, h.diag.http_status);
    try testing.expectEqualStrings("invalid_grant", h.diag.status());
    try testing.expectEqualStrings("Token has been expired or revoked. Run `gcloud auth application-default login` again.", h.diag.message());
}

test "AuthorizedUser: invalid_grant without a usable description still says how to fix it" {
    for ([_][]const u8{
        "{\"error\":\"invalid_grant\"}",
        "{\"error\":\"invalid_grant\",\"error_description\":\"\"}",
        // Too long to fit in front of the fix.
        "{\"error\":\"invalid_grant\",\"error_description\":\"" ++ "x" ** 400 ++ "\"}",
    }) |body| {
        var h: Harness = undefined;
        try h.init(&.{.{ .respond = .{ .status = 400, .body = body } }});
        defer h.deinit();
        try testing.expectError(error.RefreshTokenInvalid, h.get());
        try testing.expectEqualStrings("The refresh token no longer works. Run `gcloud auth application-default login` again.", h.diag.message());
    }
}

test "AuthorizedUser: another refusal is TokenEndpointRejected, not retried" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .status = 401, .body = "{\"error\":\"invalid_client\",\"error_description\":\"The OAuth client was not found.\"}" } },
        // A redirect is a refusal too: it is never followed.
        .{ .respond = .{ .status = 302, .body = "" } },
    });
    defer h.deinit();
    try testing.expectError(error.TokenEndpointRejected, h.get());
    try testing.expectEqualStrings("invalid_client", h.diag.status());
    try testing.expectEqualStrings("The OAuth client was not found.", h.diag.message());
    try testing.expectError(error.TokenEndpointRejected, h.get());
    try testing.expectEqualStrings("the token endpoint refused the request", h.diag.message());
    try testing.expectEqual(2, h.fake.requests.items.len);
}

test "AuthorizedUser: a busy token endpoint is retried with backoff" {
    var h: Harness = undefined;
    try h.init(&.{ unavailable, .{ .respond = .{ .status = 429, .body = "{}" } }, token_ok });
    defer h.deinit();
    try testing.expectEqualStrings("ya29.SECRET-at", try h.get());
    try testing.expectEqual(3, h.fake.requests.items.len);
    try testing.expectEqual(2, h.clock.sleep_count);
    try testing.expect(h.clock.sleepMs(0) <= 100 and h.clock.sleepMs(1) <= 200);
}

test "AuthorizedUser: three busy answers are TokenUnavailable" {
    var h: Harness = undefined;
    try h.init(&.{ unavailable, unavailable, unavailable });
    defer h.deinit();
    try testing.expectError(error.TokenUnavailable, h.get());
    try testing.expectEqual(3, h.fake.requests.items.len);
    try testing.expectEqual(503, h.diag.http_status);
}

test "AuthorizedUser: a dropped connection is retried; a bad endpoint is not" {
    var h: Harness = undefined;
    try h.init(&.{ .{ .fail = error.ConnectionResetByPeer }, token_ok, .{ .fail = error.InvalidEndpoint } });
    defer h.deinit();
    try testing.expectEqualStrings("ya29.SECRET-at", try h.get());
    try testing.expectEqual(2, h.fake.requests.items.len);
    h.user.provider().invalidate();
    try testing.expectError(error.InvalidEndpoint, h.get());
    try testing.expectEqual(3, h.fake.requests.items.len);
    try testing.expectEqualStrings("the token endpoint could not be reached: InvalidEndpoint", h.diag.message());
}

test "AuthorizedUser: a success without a usable token is InvalidTokenResponse" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = "{\"expires_in\":3599}" } },
        .{ .respond = .{ .body = "{\"access_token\":\"ya29.x\"}" } },
        .{ .respond = .{ .body = "{\"access_token\":\"ya29.x\",\"expires_in\":0}" } },
        .{ .respond = .{ .body = "<html></html>" } },
    });
    defer h.deinit();
    for (0..4) |_| try testing.expectError(error.InvalidTokenResponse, h.get());
    try testing.expectEqual(4, h.fake.requests.items.len);
}

test "AuthorizedUser: the quota project is the file's" {
    var h: Harness = undefined;
    try h.init(&.{});
    defer h.deinit();
    try testing.expectEqualStrings("billing-project", h.user.provider().quotaProject().?);
    try testing.expectEqualStrings("billing-project", h.user.quotaProjectId().?);
}

test "AuthorizedUser: the token URL must use https, or http to this machine" {
    for ([_][]const u8{
        "https://oauth2.googleapis.com/token",
        "https://example.com:8443/token",
        "http://127.0.0.1:9/token",
        "http://[::1]:9/token",
        "http://LOCALHOST/token",
    }) |url| {
        var user: AuthorizedUser = try .initFromJson(testing.allocator, testing.io, file_json, .{ .token_url = url });
        user.deinit();
    }
    for ([_][]const u8{
        "http://oauth2.googleapis.com/token",
        "http://127.0.0.2/token",
        "ftp://example.com/token",
        "https:///token",
        "not a url",
        "",
    }) |url| {
        var diag: Diagnostics = .{};
        try testing.expectError(error.InvalidOptions, AuthorizedUser.initFromJson(testing.allocator, testing.io, file_json, .{
            .token_url = url,
            .diagnostics = &diag,
        }));
        try testing.expectEqualStrings("invalid token_url: it must use https, or http to this machine", diag.message());
    }
}

test "AuthorizedUser: init refuses a bad retry policy, cache setting or user agent" {
    const io = testing.io;
    try testing.expectError(error.InvalidOptions, AuthorizedUser.initFromJson(testing.allocator, io, file_json, .{ .retry = .{ .max_attempts = 0 } }));
    try testing.expectError(error.InvalidOptions, AuthorizedUser.initFromJson(testing.allocator, io, file_json, .{ .cache = .{ .refresh_margin_s = 300 } }));
    try testing.expectError(error.InvalidOptions, AuthorizedUser.initFromJson(testing.allocator, io, file_json, .{ .user_agent = "a\r\nX: y" }));
    // A bad file is reported as such, even with good options.
    try testing.expectError(error.UnsupportedCredentialType, AuthorizedUser.initFromJson(
        testing.allocator,
        io,
        "{\"type\":\"service_account\",\"client_email\":\"e@p\",\"private_key\":\"SECRET\"}",
        .{},
    ));
}

test "AuthorizedUser: secrets reach neither the log nor Diagnostics" {
    logging.capture.reset();
    var h: Harness = undefined;
    try h.init(&.{
        token_ok,
        unavailable,
        .{ .fail = error.ConnectionResetByPeer },
        .{ .respond = .{ .status = 400, .body = "{\"error\":\"invalid_grant\",\"error_description\":\"Token has been expired or revoked.\"}" } },
        .{ .respond = .{ .status = 500, .body = "echo: SECRET-rt" } },
        .{ .respond = .{ .status = 500, .body = "echo: SECRET-rt" } },
        .{ .respond = .{ .status = 500, .body = "echo: SECRET-rt" } },
    });
    defer h.deinit();
    _ = try h.get();
    h.user.provider().invalidate();
    try testing.expectError(error.RefreshTokenInvalid, h.get());
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "SECRET") == null);
    h.user.provider().invalidate();
    try testing.expectError(error.TokenUnavailable, h.get());
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "SECRET") == null);
    try testing.expect(std.mem.indexOf(u8, logging.capture.text(), "SECRET") == null);
    try testing.expect(logging.capture.lines > 0);
}

test "AuthorizedUser: every block it frees is wiped first" {
    var checker: test_util.WipeChecker = .{ .child = testing.allocator };
    var fake: test_util.FakeTransport = .init(testing.allocator, &.{ token_ok, token_ok });
    defer fake.deinit();
    var clock: test_util.FakeClock = .{};
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var user: AuthorizedUser = try .initFromJson(checker.allocator(), clock.io(), file_json, .{ .transport = fake.transport() });
    _ = try user.provider().getToken(clock.io(), arena.allocator(), test_scopes);
    user.provider().invalidate();
    _ = try user.provider().getToken(clock.io(), arena.allocator(), test_scopes);
    user.deinit();
    try testing.expect(checker.frees >= 8);
    try testing.expectEqual(0, checker.unwiped);
}

test "AuthorizedUser: every allocation failure is OutOfMemory without leaks" {
    const Run = struct {
        fn get(gpa: Allocator, reply: Reply) !void {
            var fake: test_util.FakeTransport = .init(testing.allocator, &.{reply});
            defer fake.deinit();
            var clock: test_util.FakeClock = .{};
            var arena: std.heap.ArenaAllocator = .init(gpa);
            defer arena.deinit();
            var user: AuthorizedUser = try .initFromJson(gpa, clock.io(), file_json, .{ .transport = fake.transport() });
            defer user.deinit();
            _ = try user.provider().getToken(clock.io(), arena.allocator(), test_scopes);
        }

        fn refused(gpa: Allocator, reply: Reply) !void {
            get(gpa, reply) catch |err| switch (err) {
                error.RefreshTokenInvalid => return,
                else => return err,
            };
            return error.TestExpectedRefusal;
        }

        fn fromFile(gpa: Allocator, path: []const u8) !void {
            // With the built-in transport, which init allocates too.
            var user: AuthorizedUser = try .initFromFile(gpa, testing.io, path, .{});
            user.deinit();
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Run.get, .{token_ok});
    // Escapes make std.json allocate; without them it points into the body.
    try testing.checkAllAllocationFailures(testing.allocator, Run.get, .{Reply{ .respond = .{
        .body = "{\"access_token\":\"ya29.\\u0053ECRET-at\",\"expires_in\":3599}",
    } }});
    try testing.checkAllAllocationFailures(testing.allocator, Run.refused, .{Reply{ .respond = .{
        .status = 400,
        .body = "{\"error\":\"invalid_grant\",\"error_description\":\"Token has been \\\"revoked\\\".\"}",
    } }});

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "adc.json", .data = file_json });
    var buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, ".zig-cache/tmp/{s}/adc.json", .{&tmp.sub_path});
    try testing.checkAllAllocationFailures(testing.allocator, Run.fromFile, .{path});
}

test "AuthorizedUser: initFromFile reads the file, and reports a missing or oversized one" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "adc.json", .data = file_json });
    const huge: [adc_file.max_file_bytes + 1]u8 = @splat(' ');
    try tmp.dir.writeFile(io, .{ .sub_path = "huge.json", .data = &huge });
    var buf: [256]u8 = undefined;

    const path = try std.fmt.bufPrint(&buf, ".zig-cache/tmp/{s}/adc.json", .{&tmp.sub_path});
    var user: AuthorizedUser = try .initFromFile(testing.allocator, io, path, .{});
    try testing.expectEqualStrings("billing-project", user.quotaProjectId().?);
    user.deinit();

    var diag: Diagnostics = .{};
    const missing = try std.fmt.bufPrint(&buf, ".zig-cache/tmp/{s}/missing.json", .{&tmp.sub_path});
    try testing.expectError(error.CredentialsFileNotFound, AuthorizedUser.initFromFile(testing.allocator, io, missing, .{ .diagnostics = &diag }));
    try testing.expect(std.mem.endsWith(u8, diag.message(), "missing.json: FileNotFound"));

    const oversized = try std.fmt.bufPrint(&buf, ".zig-cache/tmp/{s}/huge.json", .{&tmp.sub_path});
    try testing.expectError(error.InvalidCredentialsFile, AuthorizedUser.initFromFile(testing.allocator, io, oversized, .{ .diagnostics = &diag }));
    try testing.expectEqualStrings("the credentials file is larger than 64 KiB", diag.message());
}

test "AuthorizedUser: against a token endpoint on loopback" {
    const io = testing.io;
    var server: test_util.ScriptedServer = try .start(io, &.{
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 58\r\n\r\n{\"access_token\":\"ya29.loopback\",\"expires_in\":3599,\"x\":\"y\"}",
        "HTTP/1.1 302 Found\r\nLocation: http://attacker.invalid/token\r\nContent-Length: 0\r\n\r\n",
    });
    defer server.deinit(io);
    var serving = try io.concurrent(test_util.ScriptedServer.run, .{ &server, io });
    defer _ = serving.cancel(io) catch {};

    var url_buf: [64]u8 = undefined;
    var user: AuthorizedUser = try .initFromJson(testing.allocator, io, file_json, .{ .token_url = server.url(&url_buf, "/token") });
    defer user.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("ya29.loopback", try user.provider().getToken(io, arena.allocator(), test_scopes));
    // A redirect is not followed: the refresh token goes nowhere else.
    user.provider().invalidate();
    try testing.expectError(error.TokenEndpointRejected, user.provider().getToken(io, arena.allocator(), test_scopes));
    try serving.await(io);
    try testing.expectEqual(2, server.connections);

    const post = server.request(0);
    try testing.expect(std.mem.startsWith(u8, post, "POST /token HTTP/1.1\r\n"));
    try testing.expect(std.mem.indexOf(u8, post, "content-type: application/x-www-form-urlencoded\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, post, "authorization") == null);
    try testing.expect(std.mem.endsWith(u8, post, "\r\n\r\n" ++ expected_body));
}

fn anyReplyProperty(_: void, input: []const u8) !void {
    var g: test_util.ByteGen = .init(input);
    const status = g.pick(u16, &.{ 200, 200, 400, 401, 403, 429, 500, 503, 302, 0 });
    const reply: Reply = .{ .respond = .{ .status = status, .body = g.rest() } };
    var h: Harness = undefined;
    try h.init(&(.{reply} ** 3));
    defer h.deinit();
    // Whatever the token endpoint says, a usable token or an error, and no leak.
    const token = h.get() catch return;
    try testing.expect(TokenProvider.isValidToken(token));
}

test "fuzz AuthorizedUser: any token endpoint reply yields a token or an error" {
    try test_util.fuzzBytes({}, anyReplyProperty, .{ .corpus = &.{
        "\x00\x00\x00\x00\x00\x00\x00\x00{\"access_token\":\"ya29.x\",\"expires_in\":3599}",
        "\x00\x00\x00\x00\x00\x00\x00\x02{\"error\":\"invalid_grant\"}",
        "\x00\x00\x00\x00\x00\x00\x00\x05",
    } });
}
