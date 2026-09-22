//! Tokens for a service account key file, the JSON that `gcloud iam
//! service-accounts keys create` (or the console) hands out. Each fetch
//! signs a short-lived JWT with the file's RSA key and trades it at
//! Google's token endpoint for an access token, which the cache keeps
//! until shortly before it expires.
//!
//! The private key and every access token are secrets: they are never
//! logged or put in `Diagnostics`, the JWT goes only to the token
//! endpoint, and memory that held them is wiped before it is freed.
//!
//! A service account token is minted for particular scopes, so the first
//! `getToken` fixes this provider's scopes; a later call asking for
//! different ones fails rather than silently widening or narrowing what
//! the token can do. Use a second provider for a second scope set.

const ServiceAccount = @This();

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
const rsa = @import("rsa.zig");
const token_response = @import("token_response.zig");

gpa: Allocator,
/// All owned, and all wiped before they are freed.
client_email: []u8,
/// Sent as the JWT's `kid` header, so Google checks against the right key.
private_key_id: ?[]u8,
key: rsa.PrivateKey,
quota_project_id: ?[]u8,
project_id: ?[]u8,
token_url: []u8,
user_agent: []u8,
request_timeout_ms: u32,
retry: core.RetryPolicy,
diagnostics: ?*Diagnostics,
cache: Cache,
/// The scopes this provider's tokens are minted for, fixed by the first
/// `getToken`.
scopes: Cache.ScopeSet,
transport: Transport,
/// The built-in transport, when `Options.transport` was null.
http: ?*HttpTransport,

pub const default_token_url = "https://oauth2.googleapis.com/token";

pub const Options = struct {
    /// Overrides the token endpoint: null means the file's `token_uri`, or
    /// Google's. Plain http is accepted only to this machine (127.0.0.1,
    /// [::1] or localhost), as tests use.
    token_url: ?[]const u8 = null,
    /// A token fetch sits in front of every API call, so it gives up sooner
    /// than an API call would.
    retry: core.RetryPolicy = .{ .max_attempts = 3 },
    cache: Cache.Options = .{},
    /// How long one request to the token endpoint may take before it is
    /// `error.TimedOut`, which the retry policy treats as transient. 0
    /// removes the limit.
    request_timeout_ms: u32 = 30_000,
    /// Printable ASCII.
    user_agent: []const u8 = "zig-gcp-auth/0.14",
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

/// Reads the key file at `path`. Files over 64 KiB are refused.
pub fn initFromFile(gpa: Allocator, io: std.Io, path: []const u8, options: Options) InitError!ServiceAccount {
    if (options.diagnostics) |d| d.clear();
    // The file holds the private key: read it into memory that is wiped.
    var wiping: core.WipingAllocator = .init(gpa);
    var scratch: std.heap.ArenaAllocator = .init(wiping.allocator());
    defer scratch.deinit();
    const json = try adc_file.readFile(io, scratch.allocator(), path, options.diagnostics);
    return initFromJson(gpa, io, json, options);
}

/// Reads credentials from the contents of a key file. Copies what it
/// keeps; `json` can be wiped as soon as this returns.
pub fn initFromJson(gpa: Allocator, io: std.Io, json: []const u8, options: Options) InitError!ServiceAccount {
    const diag = options.diagnostics;
    if (diag) |d| d.clear();
    if (options.token_url) |url| if (!token_response.isAcceptableTokenUrl(url)) {
        if (diag) |d| d.print("invalid token_url: it must use https, or http to this machine", .{});
        return error.InvalidOptions;
    };
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
        .service_account => |account| account,
        .authorized_user => {
            if (diag) |d| d.print("the credentials file is an OAuth user login; use AuthorizedUser, or findDefault", .{});
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
    var key = rsa.parsePem(file.private_key) catch |err| switch (err) {
        error.InvalidPrivateKey => {
            if (diag) |d| d.print("the credentials file's \"private_key\" is not a PEM RSA private key", .{});
            return error.InvalidCredentialsFile;
        },
        error.UnsupportedKey => {
            if (diag) |d| d.print("the credentials file's \"private_key\" is a key this version cannot use: encrypted, not RSA, multi-prime, or an unsupported size", .{});
            return error.UnsupportedCredentialType;
        },
    };
    errdefer key.deinit();

    // Where the JWT will go. A URL from the file is the file's problem;
    // one from the options was already checked above.
    const token_url_source = options.token_url orelse file.token_uri orelse default_token_url;
    if (!token_response.isAcceptableTokenUrl(token_url_source)) {
        if (diag) |d| d.print("the credentials file's \"token_uri\" must use https, or http to this machine", .{});
        return error.InvalidCredentialsFile;
    }

    const client_email = try gpa.dupe(u8, file.client_email);
    errdefer wipeFree(gpa, client_email);
    const private_key_id = if (file.private_key_id) |kid| try gpa.dupe(u8, kid) else null;
    errdefer if (private_key_id) |kid| wipeFree(gpa, kid);
    const quota_project_id = if (file.quota_project_id) |q| try gpa.dupe(u8, q) else null;
    errdefer if (quota_project_id) |q| wipeFree(gpa, q);
    const project_id = if (file.project_id) |p| try gpa.dupe(u8, p) else null;
    errdefer if (project_id) |p| wipeFree(gpa, p);
    const token_url = try gpa.dupe(u8, token_url_source);
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
        .client_email = client_email,
        .private_key_id = private_key_id,
        .key = key,
        .quota_project_id = quota_project_id,
        .project_id = project_id,
        .token_url = token_url,
        .user_agent = user_agent,
        .request_timeout_ms = options.request_timeout_ms,
        .retry = options.retry,
        .diagnostics = diag,
        .cache = cache,
        .scopes = .{},
        .transport = transport,
        .http = http,
    };
}

/// Wipes the private key and the cached access token.
pub fn deinit(self: *ServiceAccount) void {
    self.cache.deinit();
    if (self.http) |h| {
        h.deinit();
        self.gpa.destroy(h);
    }
    self.key.deinit();
    wipeFree(self.gpa, self.client_email);
    if (self.private_key_id) |kid| wipeFree(self.gpa, kid);
    if (self.quota_project_id) |q| wipeFree(self.gpa, q);
    if (self.project_id) |p| wipeFree(self.gpa, p);
    self.scopes.deinit(self.gpa);
    wipeFree(self.gpa, self.token_url);
    wipeFree(self.gpa, self.user_agent);
    self.* = undefined;
}

/// The provider points at this struct, which must not move while the
/// provider is in use.
pub fn provider(self: *ServiceAccount) TokenProvider {
    return .{ .ptr = self, .vtable = &.{
        .getToken = getToken,
        .invalidate = invalidate,
        .quotaProject = quotaProject,
    } };
}

/// The project the key file names for quota, if any. A service account
/// usually bills its own project and names none.
pub fn quotaProjectId(self: *const ServiceAccount) ?[]const u8 {
    return self.quota_project_id;
}

/// The project the service account lives in, from the key file.
pub fn projectId(self: *const ServiceAccount) ?[]const u8 {
    return self.project_id;
}

fn fromPtr(ptr: *anyopaque) *ServiceAccount {
    return @ptrCast(@alignCast(ptr));
}

fn getToken(ptr: *anyopaque, io: std.Io, arena: Allocator, scopes: []const []const u8) TokenProvider.Error![]const u8 {
    const self = fromPtr(ptr);
    try self.scopes.bind(io, self.gpa, scopes, self.diagnostics, "ServiceAccount");
    return self.cache.getToken(io, arena, .{ .ptr = self, .fetchFn = fetch });
}

fn invalidate(ptr: *anyopaque) void {
    fromPtr(ptr).cache.invalidate();
}

fn quotaProject(ptr: *anyopaque) ?[]const u8 {
    return fromPtr(ptr).quota_project_id;
}

/// Fixes the scopes on the first call, and refuses different ones later:
/// the cached token was minted for the first set, and handing it out for
/// another would give a caller more or less than it asked for.
fn bindScopes(self: *ServiceAccount, io: std.Io, scopes: []const []const u8) TokenProvider.Error!void {
    try self.scopes_mutex.lock(io);
    defer self.scopes_mutex.unlock(io);
    if (self.scopes) |bound| {
        if (scopesMatch(bound, scopes)) return;
        if (self.diagnostics) |d| d.print("this provider's tokens are scoped to what its first call asked for; use a second ServiceAccount for a second scope set", .{});
        return error.TokenUnavailable;
    }
    if (scopes.len == 0) {
        if (self.diagnostics) |d| d.print("no scopes requested; a service account token is minted for particular scopes", .{});
        return error.TokenUnavailable;
    }
    // Each scope travels inside the JWT's space-joined `scope` claim.
    for (scopes) |scope| if (!TokenProvider.isValidToken(scope)) {
        if (self.diagnostics) |d| d.print("invalid scope: scopes are visible ASCII without spaces", .{});
        return error.TokenUnavailable;
    };
    self.scopes = try std.mem.join(self.gpa, " ", scopes);
}

/// Whether `scopes` joined with spaces is exactly `joined`, without
/// allocating.
fn scopesMatch(joined: []const u8, scopes: []const []const u8) bool {
    var rest = joined;
    for (scopes, 0..) |scope, i| {
        if (i > 0) {
            if (!std.mem.startsWith(u8, rest, " ")) return false;
            rest = rest[1..];
        }
        if (!std.mem.startsWith(u8, rest, scope)) return false;
        rest = rest[scope.len..];
    }
    return rest.len == 0;
}

/// Signs a JWT and trades it for an access token. `arena` is the cache's
/// scratch memory, which it wipes: everything built here is or touches a
/// secret.
fn fetch(ptr: *anyopaque, io: std.Io, arena: Allocator) TokenProvider.Error!Cache.Fetched {
    const self = fromPtr(ptr);
    const jwt = try self.assertion(io, arena);
    const body = try form.encode(arena, &.{
        .{ .name = "grant_type", .value = "urn:ietf:params:oauth:grant-type:jwt-bearer" },
        .{ .name = "assertion", .value = jwt },
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

/// How long the JWT, and so the token minted from it, asks to live: the
/// most Google allows.
const assertion_lifetime_s = 3600;

/// The signed JWT the token endpoint takes as proof: header and claims as
/// base64url, and an RSASSA-PKCS1-v1_5 signature over them.
fn assertion(self: *ServiceAccount, io: std.Io, arena: Allocator) TokenProvider.Error![]const u8 {
    // The claims carry wall-clock times: the endpoint checks them against
    // its own clock, and a machine far off gets invalid_grant.
    const now: i64 = @intCast(@divFloor(std.Io.Clock.real.now(io).nanoseconds, std.time.ns_per_s));

    var header: std.Io.Writer.Allocating = .init(arena);
    {
        var json: std.json.Stringify = .{ .writer = &header.writer };
        json.beginObject() catch return error.OutOfMemory;
        writeField(&json, "alg", "RS256") catch return error.OutOfMemory;
        writeField(&json, "typ", "JWT") catch return error.OutOfMemory;
        if (self.private_key_id) |kid| writeField(&json, "kid", kid) catch return error.OutOfMemory;
        json.endObject() catch return error.OutOfMemory;
    }
    var claims: std.Io.Writer.Allocating = .init(arena);
    {
        var json: std.json.Stringify = .{ .writer = &claims.writer };
        json.beginObject() catch return error.OutOfMemory;
        writeField(&json, "iss", self.client_email) catch return error.OutOfMemory;
        writeField(&json, "scope", self.scopes.joined.?) catch return error.OutOfMemory;
        writeField(&json, "aud", self.token_url) catch return error.OutOfMemory;
        writeField(&json, "iat", now) catch return error.OutOfMemory;
        writeField(&json, "exp", now + assertion_lifetime_s) catch return error.OutOfMemory;
        json.endObject() catch return error.OutOfMemory;
    }

    const signing_input = try std.mem.join(arena, ".", &.{
        try base64Url(arena, header.written()),
        try base64Url(arena, claims.written()),
    });
    var sig_buf: [rsa.max_modulus_bytes]u8 = undefined;
    const sig = self.key.sign(signing_input, &sig_buf) catch {
        // The self-check failed: the key is corrupt in a way parsing
        // could not see. Retrying would fail the same way.
        if (self.diagnostics) |d| d.print("signing the JWT failed: the private key does not verify against itself", .{});
        return error.TokenUnavailable;
    };
    return std.mem.join(arena, ".", &.{ signing_input, try base64Url(arena, sig) });
}

fn writeField(json: *std.json.Stringify, name: []const u8, value: anytype) !void {
    try json.objectField(name);
    try json.write(value);
}

fn base64Url(arena: Allocator, bytes: []const u8) Allocator.Error![]const u8 {
    const encoder = std.base64.url_safe_no_pad.Encoder;
    const out = try arena.alloc(u8, encoder.calcSize(bytes.len));
    return encoder.encode(out, bytes);
}

const Result = union(enum) {
    token: Cache.Fetched,
    /// Worth another attempt.
    retry: TokenProvider.Error,
    fail: TokenProvider.Error,
};

/// One request to the token endpoint, and what to make of the answer.
fn exchange(self: *ServiceAccount, arena: Allocator, body: []const u8) Result {
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
                // For a signed assertion this means the clock is off, or
                // the key or its account is gone or disabled.
                const fix = "Check this machine's clock, and that the key and its service account still exist and are enabled.";
                const generic = "The signed assertion was rejected. " ++ fix;
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

fn isPrintable(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text) |c| if (c < ' ' or c >= 0x7f) return false;
    return true;
}

const testing = std.testing;
const test_util = core.testing;
const Reply = test_util.FakeTransport.Reply;

/// A key file as Google writes one, with the PEM's newlines as JSON
/// escapes, built around one of rsa.zig's test keys.
fn keyFileJson(arena: Allocator, pem: []const u8, with_optionals: bool) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    var json: std.json.Stringify = .{ .writer = &out.writer };
    try json.beginObject();
    try writeField(&json, "type", "service_account");
    try writeField(&json, "client_email", "robot@my-project.iam.gserviceaccount.com");
    try writeField(&json, "private_key", pem);
    if (with_optionals) {
        try writeField(&json, "private_key_id", "kid-1b2f3a");
        try writeField(&json, "project_id", "my-project");
        try writeField(&json, "token_uri", "https://oauth2.googleapis.com/token");
        try writeField(&json, "universe_domain", "googleapis.com");
    }
    try json.endObject();
    return out.written();
}

const token_ok: Reply = .{ .respond = .{ .body = "{\"access_token\":\"ya29.SECRET-at\",\"expires_in\":3599,\"token_type\":\"Bearer\"}" } };
const unavailable: Reply = .{ .respond = .{ .status = 503, .body = "Service Unavailable" } };
const test_scopes: []const []const u8 = &.{"https://www.googleapis.com/auth/pubsub"};

/// A `ServiceAccount` wired to a fake transport and a fake clock, on the
/// fast 1024-bit test key.
const Harness = struct {
    fake: test_util.FakeTransport,
    clock: test_util.FakeClock,
    diag: Diagnostics,
    arena: std.heap.ArenaAllocator,
    account: ServiceAccount,

    /// Initializes in place: the account points into the harness.
    fn init(h: *Harness, script: []const Reply) !void {
        h.* = .{
            .fake = .init(testing.allocator, script),
            .clock = .{},
            .diag = .{},
            .arena = .init(testing.allocator),
            .account = undefined,
        };
        errdefer h.fake.deinit();
        errdefer h.arena.deinit();
        const json = try keyFileJson(h.arena.allocator(), rsa.test_key_1024, true);
        h.account = try .initFromJson(testing.allocator, h.clock.io(), json, .{
            .diagnostics = &h.diag,
            .transport = h.fake.transport(),
        });
    }

    fn deinit(h: *Harness) void {
        h.account.deinit();
        h.arena.deinit();
        h.fake.deinit();
    }

    fn get(h: *Harness) TokenProvider.Error![]const u8 {
        return h.account.provider().getToken(h.clock.io(), h.arena.allocator(), test_scopes);
    }
};

/// The `assertion=` value of a sent form body, still URL-encoded exactly
/// as the JWT was, since base64url and '.' need no escaping.
fn sentAssertion(body: []const u8) ![]const u8 {
    const marker = "assertion=";
    const start = (std.mem.indexOf(u8, body, marker) orelse return error.TestNoAssertion) + marker.len;
    const end = std.mem.indexOfScalarPos(u8, body, start, '&') orelse body.len;
    return body[start..end];
}

fn base64UrlDecode(arena: Allocator, text: []const u8) ![]const u8 {
    const decoder = std.base64.url_safe_no_pad.Decoder;
    const out = try arena.alloc(u8, try decoder.calcSizeForSlice(text));
    try decoder.decode(out, text);
    return out;
}

test "ServiceAccount: the exchange is a form POST with a signed, decodable JWT" {
    var h: Harness = undefined;
    try h.init(&.{token_ok});
    defer h.deinit();
    try testing.expectEqualStrings("ya29.SECRET-at", try h.get());

    const req = try h.fake.request(0);
    try testing.expectEqual(.POST, req.method);
    try testing.expectEqualStrings("https://oauth2.googleapis.com/token", req.url);
    try testing.expectEqual(.form, req.content_type);
    try testing.expectEqual(null, req.bearer);
    try testing.expect(std.mem.startsWith(u8, req.body.?, "grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer&assertion="));

    // The JWT decodes to exactly the header and claims this provider
    // promises, with the fake clock's time in them.
    const a = h.arena.allocator();
    const jwt = try sentAssertion(req.body.?);
    var parts = std.mem.splitScalar(u8, jwt, '.');
    const header = try base64UrlDecode(a, parts.next().?);
    const claims = try base64UrlDecode(a, parts.next().?);
    const signature = try base64UrlDecode(a, parts.next().?);
    try testing.expectEqual(null, parts.next());
    try testing.expectEqualStrings("{\"alg\":\"RS256\",\"typ\":\"JWT\",\"kid\":\"kid-1b2f3a\"}", header);
    try testing.expectEqualStrings(
        "{\"iss\":\"robot@my-project.iam.gserviceaccount.com\"," ++
            "\"scope\":\"https://www.googleapis.com/auth/pubsub\"," ++
            "\"aud\":\"https://oauth2.googleapis.com/token\",\"iat\":0,\"exp\":3600}",
        claims,
    );

    // The signature is our deterministic RSA over exactly `header.claims`.
    var key = try rsa.parsePem(rsa.test_key_1024);
    defer key.deinit();
    const dot = std.mem.lastIndexOfScalar(u8, jwt, '.').?;
    var expected: [rsa.max_modulus_bytes]u8 = undefined;
    try testing.expectEqualSlices(u8, try key.sign(jwt[0..dot], &expected), signature);
}

test "ServiceAccount: without a private_key_id there is no kid header" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var fake: test_util.FakeTransport = .init(testing.allocator, &.{token_ok});
    defer fake.deinit();
    var clock: test_util.FakeClock = .{};
    const json = try keyFileJson(arena.allocator(), rsa.test_key_1024, false);
    var account: ServiceAccount = try .initFromJson(testing.allocator, clock.io(), json, .{ .transport = fake.transport() });
    defer account.deinit();
    _ = try account.provider().getToken(clock.io(), arena.allocator(), test_scopes);
    const jwt = try sentAssertion((try fake.request(0)).body.?);
    var parts = std.mem.splitScalar(u8, jwt, '.');
    const header = try base64UrlDecode(arena.allocator(), parts.next().?);
    try testing.expectEqualStrings("{\"alg\":\"RS256\",\"typ\":\"JWT\"}", header);
}

test "ServiceAccount: the token is kept until it goes stale" {
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

test "ServiceAccount: the first call's scopes stick, and different ones are refused" {
    var h: Harness = undefined;
    try h.init(&.{token_ok});
    defer h.deinit();
    _ = try h.get();
    // The same scopes again: served from the cache.
    _ = try h.get();
    try testing.expectEqual(1, h.fake.requests.items.len);
    // Different scopes: refused, and the reason is in the diagnostics.
    const other: []const []const u8 = &.{"https://www.googleapis.com/auth/devstorage.read_only"};
    try testing.expectError(error.TokenUnavailable, h.account.provider().getToken(h.clock.io(), h.arena.allocator(), other));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "scoped") != null);
    // Supersets and subsets are different scope sets too.
    const wider: []const []const u8 = &.{ test_scopes[0], other[0] };
    try testing.expectError(error.TokenUnavailable, h.account.provider().getToken(h.clock.io(), h.arena.allocator(), wider));
    // The original scopes still work, from the cache.
    _ = try h.get();
    try testing.expectEqual(1, h.fake.requests.items.len);
}

test "ServiceAccount: no scopes, or one with a space, is refused before signing" {
    var h: Harness = undefined;
    try h.init(&.{});
    defer h.deinit();
    try testing.expectError(error.TokenUnavailable, h.account.provider().getToken(h.clock.io(), h.arena.allocator(), &.{}));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "no scopes") != null);
    try testing.expectError(error.TokenUnavailable, h.account.provider().getToken(h.clock.io(), h.arena.allocator(), &.{"two scopes"}));
    try testing.expectEqual(0, h.fake.requests.items.len);
    // The provider is not stuck on the refused scopes.
    _ = h.get() catch {};
}

test "ServiceAccount: invalid_grant is TokenEndpointRejected and says what to check" {
    var h: Harness = undefined;
    try h.init(&.{.{ .respond = .{
        .status = 400,
        .body = "{\"error\":\"invalid_grant\",\"error_description\":\"Invalid JWT Signature.\"}",
    } }});
    defer h.deinit();
    try testing.expectError(error.TokenEndpointRejected, h.get());
    try testing.expectEqual(1, h.fake.requests.items.len);
    try testing.expectEqual(400, h.diag.http_status);
    try testing.expectEqualStrings("invalid_grant", h.diag.status());
    try testing.expectEqualStrings("Invalid JWT Signature. Check this machine's clock, and that the key and its service account still exist and are enabled.", h.diag.message());
}

test "ServiceAccount: a busy token endpoint is retried with backoff" {
    var h: Harness = undefined;
    try h.init(&.{ unavailable, .{ .respond = .{ .status = 429, .body = "{}" } }, token_ok });
    defer h.deinit();
    try testing.expectEqualStrings("ya29.SECRET-at", try h.get());
    try testing.expectEqual(3, h.fake.requests.items.len);
    try testing.expectEqual(2, h.clock.sleep_count);
    try testing.expect(h.clock.sleepMs(0) <= 100 and h.clock.sleepMs(1) <= 200);
}

test "ServiceAccount: three busy answers are TokenUnavailable" {
    var h: Harness = undefined;
    try h.init(&.{ unavailable, unavailable, unavailable });
    defer h.deinit();
    try testing.expectError(error.TokenUnavailable, h.get());
    try testing.expectEqual(3, h.fake.requests.items.len);
    try testing.expectEqual(503, h.diag.http_status);
}

test "ServiceAccount: a dropped connection is retried; a rejected client is not" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .fail = error.ConnectionResetByPeer },
        token_ok,
        .{ .respond = .{ .status = 401, .body = "{\"error\":\"invalid_client\",\"error_description\":\"no such client\"}" } },
    });
    defer h.deinit();
    try testing.expectEqualStrings("ya29.SECRET-at", try h.get());
    try testing.expectEqual(2, h.fake.requests.items.len);
    h.account.provider().invalidate();
    try testing.expectError(error.TokenEndpointRejected, h.get());
    try testing.expectEqualStrings("invalid_client", h.diag.status());
}

test "ServiceAccount: init refuses what cannot work, and says why" {
    const io = testing.io;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diag: Diagnostics = .{};

    // A user login is the other provider's job.
    try testing.expectError(error.UnsupportedCredentialType, ServiceAccount.initFromJson(
        testing.allocator,
        io,
        "{\"type\":\"authorized_user\",\"client_id\":\"c\",\"client_secret\":\"s\",\"refresh_token\":\"r\"}",
        .{ .diagnostics = &diag },
    ));
    try testing.expect(std.mem.indexOf(u8, diag.message(), "AuthorizedUser") != null);

    // A private key that is not a usable PEM RSA key.
    try testing.expectError(error.InvalidCredentialsFile, ServiceAccount.initFromJson(
        testing.allocator,
        io,
        try keyFileJson(a, "not a pem at all", false),
        .{ .diagnostics = &diag },
    ));
    try testing.expect(std.mem.indexOf(u8, diag.message(), "private_key") != null);
    try testing.expectError(error.UnsupportedCredentialType, ServiceAccount.initFromJson(
        testing.allocator,
        io,
        try keyFileJson(a, rsa.test_key_ec, false),
        .{ .diagnostics = &diag },
    ));

    // Token endpoints that would carry the JWT in the clear.
    const json = try keyFileJson(a, rsa.test_key_1024, false);
    try testing.expectError(error.InvalidOptions, ServiceAccount.initFromJson(testing.allocator, io, json, .{
        .token_url = "http://oauth2.googleapis.com/token",
        .diagnostics = &diag,
    }));
    var bad_uri: std.Io.Writer.Allocating = .init(a);
    var bad_json: std.json.Stringify = .{ .writer = &bad_uri.writer };
    try bad_json.beginObject();
    try writeField(&bad_json, "type", "service_account");
    try writeField(&bad_json, "client_email", "e@p.iam.gserviceaccount.com");
    try writeField(&bad_json, "private_key", rsa.test_key_1024);
    try writeField(&bad_json, "token_uri", "http://elsewhere.example/token");
    try bad_json.endObject();
    try testing.expectError(error.InvalidCredentialsFile, ServiceAccount.initFromJson(testing.allocator, io, bad_uri.written(), .{
        .diagnostics = &diag,
    }));
    try testing.expect(std.mem.indexOf(u8, diag.message(), "token_uri") != null);

    // The usual option checks hold here too.
    try testing.expectError(error.InvalidOptions, ServiceAccount.initFromJson(testing.allocator, io, json, .{ .retry = .{ .max_attempts = 0 } }));
    try testing.expectError(error.InvalidOptions, ServiceAccount.initFromJson(testing.allocator, io, json, .{ .cache = .{ .refresh_margin_s = 300 } }));
    try testing.expectError(error.InvalidOptions, ServiceAccount.initFromJson(testing.allocator, io, json, .{ .user_agent = "a\r\nX: y" }));
}

test "ServiceAccount: an explicit token_url wins over the file's token_uri" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var fake: test_util.FakeTransport = .init(testing.allocator, &.{token_ok});
    defer fake.deinit();
    var clock: test_util.FakeClock = .{};
    const json = try keyFileJson(arena.allocator(), rsa.test_key_1024, true);
    var account: ServiceAccount = try .initFromJson(testing.allocator, clock.io(), json, .{
        .token_url = "https://token.example/exchange",
        .transport = fake.transport(),
    });
    defer account.deinit();
    _ = try account.provider().getToken(clock.io(), arena.allocator(), test_scopes);
    try testing.expectEqualStrings("https://token.example/exchange", (try fake.request(0)).url);
    // The override is also the JWT's audience.
    const jwt = try sentAssertion((try fake.request(0)).body.?);
    var parts = std.mem.splitScalar(u8, jwt, '.');
    _ = parts.next();
    const claims = try base64UrlDecode(arena.allocator(), parts.next().?);
    try testing.expect(std.mem.indexOf(u8, claims, "\"aud\":\"https://token.example/exchange\"") != null);
}

test "ServiceAccount: the file's projects are reported" {
    var h: Harness = undefined;
    try h.init(&.{});
    defer h.deinit();
    try testing.expectEqualStrings("my-project", h.account.projectId().?);
    try testing.expectEqual(null, h.account.quotaProjectId());
    try testing.expectEqual(null, h.account.provider().quotaProject());
}

test "ServiceAccount: secrets reach neither the log nor Diagnostics" {
    logging.capture.reset();
    var h: Harness = undefined;
    try h.init(&.{
        token_ok,
        unavailable,
        unavailable,
        unavailable,
    });
    defer h.deinit();
    _ = try h.get();
    h.account.provider().invalidate();
    try testing.expectError(error.TokenUnavailable, h.get());
    const log = logging.capture.text();
    try testing.expect(logging.capture.lines > 0);
    for ([_][]const u8{ "PRIVATE KEY", "ya29.SECRET", "MII" }) |secret| {
        try testing.expect(std.mem.indexOf(u8, log, secret) == null);
        try testing.expect(std.mem.indexOf(u8, h.diag.message(), secret) == null);
    }
}

test "ServiceAccount: every block it frees is wiped first" {
    var checker: test_util.WipeChecker = .{ .child = testing.allocator };
    var fake: test_util.FakeTransport = .init(testing.allocator, &.{ token_ok, token_ok });
    defer fake.deinit();
    var clock: test_util.FakeClock = .{};
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const json = try keyFileJson(arena.allocator(), rsa.test_key_1024, true);
    var account: ServiceAccount = try .initFromJson(checker.allocator(), clock.io(), json, .{ .transport = fake.transport() });
    _ = try account.provider().getToken(clock.io(), arena.allocator(), test_scopes);
    account.provider().invalidate();
    _ = try account.provider().getToken(clock.io(), arena.allocator(), test_scopes);
    account.deinit();
    try testing.expect(checker.frees >= 8);
    try testing.expectEqual(0, checker.unwiped);
}

test "ServiceAccount: every allocation failure is OutOfMemory without leaks" {
    const Run = struct {
        fn get(gpa: Allocator, reply: Reply) !void {
            var fixture: std.heap.ArenaAllocator = .init(testing.allocator);
            defer fixture.deinit();
            const json = try keyFileJson(fixture.allocator(), rsa.test_key_1024, true);
            var fake: test_util.FakeTransport = .init(testing.allocator, &.{reply});
            defer fake.deinit();
            var clock: test_util.FakeClock = .{};
            var arena: std.heap.ArenaAllocator = .init(gpa);
            defer arena.deinit();
            var account: ServiceAccount = try .initFromJson(gpa, clock.io(), json, .{ .transport = fake.transport() });
            defer account.deinit();
            _ = try account.provider().getToken(clock.io(), arena.allocator(), test_scopes);
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Run.get, .{token_ok});
}

test "ServiceAccount: initFromFile reads the file, and reports a missing one" {
    const io = testing.io;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const json = try keyFileJson(arena.allocator(), rsa.test_key_1024, true);
    try tmp.dir.writeFile(io, .{ .sub_path = "sa.json", .data = json });
    var buf: [256]u8 = undefined;

    const path = try std.fmt.bufPrint(&buf, ".zig-cache/tmp/{s}/sa.json", .{&tmp.sub_path});
    var account: ServiceAccount = try .initFromFile(testing.allocator, io, path, .{});
    try testing.expectEqualStrings("my-project", account.projectId().?);
    account.deinit();

    var diag: Diagnostics = .{};
    const missing = try std.fmt.bufPrint(&buf, ".zig-cache/tmp/{s}/missing.json", .{&tmp.sub_path});
    try testing.expectError(error.CredentialsFileNotFound, ServiceAccount.initFromFile(testing.allocator, io, missing, .{ .diagnostics = &diag }));
    try testing.expect(std.mem.endsWith(u8, diag.message(), "missing.json: FileNotFound"));
}

test "ServiceAccount: against a token endpoint on loopback" {
    const io = testing.io;
    var server: test_util.ScriptedServer = try .start(io, &.{
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 58\r\n\r\n{\"access_token\":\"ya29.loopback\",\"expires_in\":3599,\"x\":\"y\"}",
    });
    defer server.deinit(io);
    var serving = try io.concurrent(test_util.ScriptedServer.run, .{ &server, io });
    defer _ = serving.cancel(io) catch {};

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const json = try keyFileJson(arena.allocator(), rsa.test_key_1024, true);
    var url_buf: [64]u8 = undefined;
    var account: ServiceAccount = try .initFromJson(testing.allocator, io, json, .{ .token_url = server.url(&url_buf, "/token") });
    defer account.deinit();
    try testing.expectEqualStrings("ya29.loopback", try account.provider().getToken(io, arena.allocator(), test_scopes));
    try serving.await(io);

    const post = server.request(0);
    try testing.expect(std.mem.startsWith(u8, post, "POST /token HTTP/1.1\r\n"));
    try testing.expect(std.mem.indexOf(u8, post, "content-type: application/x-www-form-urlencoded\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, post, "authorization") == null);
    try testing.expect(std.mem.indexOf(u8, post, "grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer&assertion=eyJ") != null);
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

// Named "slow property", not "fuzz": each run signs a JWT with RSA, about
// 49 ms, so the nightly fuzz job for auth skips it and a job of its own
// fuzzes it fewer times. `zig build test` runs it like any other.
test "slow property ServiceAccount: any token endpoint reply yields a token or an error" {
    try test_util.fuzzBytes({}, anyReplyProperty, .{
        .corpus = &.{
            "\x00\x00\x00\x00\x00\x00\x00\x00{\"access_token\":\"ya29.x\",\"expires_in\":3599}",
            "\x00\x00\x00\x00\x00\x00\x00\x02{\"error\":\"invalid_grant\"}",
            "\x00\x00\x00\x00\x00\x00\x00\x05",
        },
        // Every run signs a JWT, which is milliseconds, not microseconds.
        .random_runs = 40,
    });
}
