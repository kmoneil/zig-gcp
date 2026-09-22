//! Tokens that act as a service account, from credentials allowed to: the
//! `impersonated_service_account` file that
//! `gcloud auth application-default login --impersonate-service-account=SA`
//! writes. Google recommends this over service account keys: nothing of the
//! service account is stored, only a login that may act as it.
//!
//! Each fetch takes a token from the file's source credentials, a user login
//! or a service account key, and trades it at the IAM Credentials API for
//! one that acts as the target account. The source keeps its own cached
//! token, so most fetches cost one request. Only the account's email is read
//! from the file's URL; the request always goes to Google's endpoint, as
//! Google's own libraries do, so a crafted file cannot send the source token
//! anywhere else. Tokens are never logged, and memory that held them is
//! wiped.
//!
//! Like a service account's, these tokens are minted for particular scopes,
//! so the first `getToken` fixes them; use a second provider for a second
//! scope set.

const ImpersonatedServiceAccount = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("core");
const TokenProvider = core.TokenProvider;
const Diagnostics = core.Diagnostics;
const HttpTransport = core.transport.HttpTransport;
const Transport = core.transport.Transport;
const AuthorizedUser = @import("AuthorizedUser.zig");
const Cache = @import("Cache.zig");
const ServiceAccount = @import("ServiceAccount.zig");
const adc_file = @import("adc_file.zig");
const iam_credentials = @import("iam_credentials.zig");
const logging = @import("logging.zig");
const token_response = @import("token_response.zig");

gpa: Allocator,
/// On the heap: its provider points into it, so it must not move.
source: *Source,
/// The service account these tokens act as. Owned.
target: []u8,
/// Owned, each as `projects/-/serviceAccounts/EMAIL`.
delegates: [][]u8,
/// The `...:generateAccessToken` URL on `Options.iam_endpoint`. Owned.
url: []u8,
/// What a refusal says, naming the account and the role. Owned.
refused: []u8,
lifetime_s: u32,
quota_project_id: ?[]u8,
request_timeout_ms: u32,
retry: core.RetryPolicy,
diagnostics: ?*Diagnostics,
cache: Cache,
/// The scopes this provider's tokens are minted for, fixed by the first
/// `getToken`.
scopes: Cache.ScopeSet,
transport: Transport,
/// The built-in transport, when `Options.transport` was null. The source
/// sends through it too.
http: ?*HttpTransport,
/// Owned copy of `Options.user_agent`, which the built-in transport uses.
user_agent: []u8,

/// The credentials that may act as the service account.
const Source = union(enum) {
    user: AuthorizedUser,
    service_account: ServiceAccount,

    fn provider(source: *Source) TokenProvider {
        return switch (source.*) {
            .user => |*u| u.provider(),
            .service_account => |*s| s.provider(),
        };
    }

    fn deinit(source: *Source) void {
        switch (source.*) {
            .user => |*u| u.deinit(),
            .service_account => |*s| s.deinit(),
        }
        source.* = undefined;
    }
};

pub const Options = struct {
    /// Google's IAM Credentials endpoint, scheme and host. Plain http is
    /// accepted only to this machine (127.0.0.1, [::1] or localhost), as
    /// tests use.
    iam_endpoint: []const u8 = iam_credentials.default_endpoint,
    /// Seconds each token asks to live: at most an hour, unless an
    /// organization policy allows up to twelve.
    lifetime_s: u32 = 3600,
    /// A token fetch sits in front of every API call, so it gives up sooner
    /// than an API call would.
    retry: core.RetryPolicy = .{ .max_attempts = 3 },
    cache: Cache.Options = .{},
    /// How long one request may take before it is `error.TimedOut`, which
    /// the retry policy treats as transient. 0 removes the limit.
    request_timeout_ms: u32 = 30_000,
    /// Printable ASCII.
    user_agent: []const u8 = "zig-gcp-auth/0.14",
    /// Filled with the details of the last failure, while reading the file,
    /// from the source's token endpoint, or from IAM. Never holds a secret.
    diagnostics: ?*Diagnostics = null,
    /// Sends requests through this instead of `std.http.Client`, the
    /// source's included.
    transport: ?Transport = null,
};

pub const InitError = error{
    /// The file is missing or cannot be read.
    CredentialsFileNotFound,
    InvalidCredentialsFile,
    UnsupportedCredentialType,
    /// An endpoint that is neither https nor on this machine, a lifetime
    /// out of range, or an invalid retry policy, cache setting or user agent.
    InvalidOptions,
    Canceled,
    OutOfMemory,
};

/// The longest lifetime Google grants, with an organization policy that
/// allows it.
pub const max_lifetime_s = 12 * 60 * 60;

/// Reads the credentials file at `path`. Files over 64 KiB are refused.
pub fn initFromFile(gpa: Allocator, io: std.Io, path: []const u8, options: Options) InitError!ImpersonatedServiceAccount {
    if (options.diagnostics) |d| d.clear();
    // The file holds the source's refresh token or private key.
    var wiping: core.WipingAllocator = .init(gpa);
    var scratch: std.heap.ArenaAllocator = .init(wiping.allocator());
    defer scratch.deinit();
    const json = try adc_file.readFile(io, scratch.allocator(), path, options.diagnostics);
    return initFromJson(gpa, io, json, options);
}

/// Reads credentials from the contents of a credentials file. Copies what
/// it keeps; `json` can be wiped as soon as this returns.
pub fn initFromJson(gpa: Allocator, io: std.Io, json: []const u8, options: Options) InitError!ImpersonatedServiceAccount {
    const diag = options.diagnostics;
    if (diag) |d| d.clear();
    if (!token_response.isAcceptableTokenUrl(options.iam_endpoint)) {
        if (diag) |d| d.print("invalid iam_endpoint: it must use https, or http to this machine", .{});
        return error.InvalidOptions;
    }
    if (options.lifetime_s == 0 or options.lifetime_s > max_lifetime_s) {
        if (diag) |d| d.print("invalid lifetime_s: expected 1 to {d} seconds", .{max_lifetime_s});
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
        .impersonated_service_account => |impersonated| impersonated,
        .authorized_user => {
            if (diag) |d| d.print("the credentials file is an OAuth user login; use AuthorizedUser, or findDefault", .{});
            return error.UnsupportedCredentialType;
        },
        .service_account => {
            if (diag) |d| d.print("the credentials file is a service account key; use ServiceAccount, or findDefault", .{});
            return error.UnsupportedCredentialType;
        },
        .external_account => {
            if (diag) |d| d.print("the credentials file is a workload identity federation file; use ExternalAccount, or findDefault", .{});
            return error.UnsupportedCredentialType;
        },
    };

    var http: ?*HttpTransport = null;
    errdefer if (http) |h| {
        h.deinit();
        gpa.destroy(h);
    };
    const user_agent = try gpa.dupe(u8, options.user_agent);
    // The transport keeps pointing at the agent, so it lives as long as
    // the transport does: freed in deinit.
    errdefer wipeFree(gpa, user_agent);
    const transport = options.transport orelse t: {
        const h = try gpa.create(HttpTransport);
        h.* = .init(gpa, io, user_agent);
        http = h;
        break :t h.transport();
    };

    const source = try gpa.create(Source);
    errdefer wipeDestroy(gpa, source);
    source.* = switch (file.source_type) {
        .authorized_user => .{ .user = try AuthorizedUser.initFromJson(gpa, io, file.source_json, .{
            .retry = options.retry,
            .cache = options.cache,
            .request_timeout_ms = options.request_timeout_ms,
            .user_agent = options.user_agent,
            .diagnostics = diag,
            .transport = transport,
        }) },
        .service_account => .{ .service_account = try ServiceAccount.initFromJson(gpa, io, file.source_json, .{
            .retry = options.retry,
            .cache = options.cache,
            .request_timeout_ms = options.request_timeout_ms,
            .user_agent = options.user_agent,
            .diagnostics = diag,
            .transport = transport,
        }) },
    };
    errdefer source.deinit();

    const target = try gpa.dupe(u8, file.target);
    errdefer wipeFree(gpa, target);
    const url = try iam_credentials.url(gpa, options.iam_endpoint, file.target);
    errdefer wipeFree(gpa, url);
    const refused_format = "impersonation was refused: the source credentials need roles/iam.serviceAccountTokenCreator on {s}";
    const refused = try gpa.alloc(u8, std.fmt.count(refused_format, .{file.target}));
    _ = std.fmt.bufPrint(refused, refused_format, .{file.target}) catch unreachable;
    errdefer wipeFree(gpa, refused);
    const delegates = try copyAll(gpa, file.delegates);
    errdefer freeAll(gpa, delegates);
    const quota = if (file.quota_project_id) |q| try gpa.dupe(u8, q) else null;
    errdefer if (quota) |q| wipeFree(gpa, q);

    return .{
        .gpa = gpa,
        .source = source,
        .target = target,
        .delegates = delegates,
        .url = url,
        .refused = refused,
        .lifetime_s = options.lifetime_s,
        .quota_project_id = quota,
        .request_timeout_ms = options.request_timeout_ms,
        .retry = options.retry,
        .diagnostics = diag,
        .cache = cache,
        .scopes = .{},
        .transport = transport,
        .http = http,
        .user_agent = user_agent,
    };
}

pub fn deinit(self: *ImpersonatedServiceAccount) void {
    self.cache.deinit();
    // The source sends through the transport, so it goes first.
    self.source.deinit();
    wipeDestroy(self.gpa, self.source);
    if (self.http) |h| {
        h.deinit();
        self.gpa.destroy(h);
    }
    self.scopes.deinit(self.gpa);
    freeAll(self.gpa, self.delegates);
    wipeFree(self.gpa, self.target);
    wipeFree(self.gpa, self.url);
    wipeFree(self.gpa, self.refused);
    if (self.quota_project_id) |q| wipeFree(self.gpa, q);
    wipeFree(self.gpa, self.user_agent);
    self.* = undefined;
}

/// The provider points at this struct, which must not move while the
/// provider is in use.
pub fn provider(self: *ImpersonatedServiceAccount) TokenProvider {
    return .{ .ptr = self, .vtable = &.{
        .getToken = getToken,
        .invalidate = invalidate,
        .quotaProject = quotaProject,
    } };
}

/// The project the file names for quota, if any.
pub fn quotaProjectId(self: *const ImpersonatedServiceAccount) ?[]const u8 {
    return self.quota_project_id;
}

/// The service account these tokens act as: its email, or its unique id.
pub fn targetPrincipal(self: *const ImpersonatedServiceAccount) []const u8 {
    return self.target;
}

fn fromPtr(ptr: *anyopaque) *ImpersonatedServiceAccount {
    return @ptrCast(@alignCast(ptr));
}

fn getToken(ptr: *anyopaque, io: std.Io, arena: Allocator, scopes: []const []const u8) TokenProvider.Error![]const u8 {
    const self = fromPtr(ptr);
    try self.scopes.bind(io, self.gpa, scopes, self.diagnostics, "ImpersonatedServiceAccount");
    return self.cache.getToken(io, arena, .{ .ptr = self, .fetchFn = fetch });
}

fn invalidate(ptr: *anyopaque) void {
    // A refused impersonated token says nothing about the source's, which
    // stays cached; a refused source token is handled in `fetch`.
    fromPtr(ptr).cache.invalidate();
}

fn quotaProject(ptr: *anyopaque) ?[]const u8 {
    return fromPtr(ptr).quota_project_id;
}

/// One whole fetch: a source token, then the trade at IAM. `arena` is the
/// cache's scratch memory, which it wipes.
fn fetch(ptr: *anyopaque, io: std.Io, arena: Allocator) TokenProvider.Error!Cache.Fetched {
    const self = fromPtr(ptr);
    var max_attempts: u32 = self.retry.max_attempts;
    var reauthenticated = false;
    var attempt: u32 = 1;
    while (true) : (attempt += 1) {
        // The source's provider caches its token and did its own retries.
        const source_token = try self.source.provider().getToken(io, arena, &.{iam_credentials.scope});
        const started = std.Io.Clock.awake.now(io);
        const outcome = iam_credentials.generateAccessToken(self.transport, io, arena, .{
            .url = self.url,
            .bearer = source_token,
            .scopes = self.scopes.joined.?,
            .lifetime_s = self.lifetime_s,
            .delegates = self.delegates,
            .timeout_ms = self.request_timeout_ms,
        }, self.diagnostics, self.refused);
        const elapsed_ms = started.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds();
        switch (outcome) {
            .token => |fetched| {
                logging.debug("POST {s} -> a token in {d} ms (attempt {d} of {d})", .{ self.url, elapsed_ms, attempt, max_attempts });
                return fetched;
            },
            .unauthorized => {
                logging.debug("POST {s} -> 401 in {d} ms (attempt {d} of {d})", .{ self.url, elapsed_ms, attempt, max_attempts });
                // The source token died between its fetch and its use. A
                // fresh one fixes that, and costs one more try, not a retry.
                if (reauthenticated) return error.TokenEndpointRejected;
                reauthenticated = true;
                max_attempts += 1;
                logging.warn("IAM refused the source token as unauthenticated; fetching a fresh one", .{});
                self.source.provider().invalidate();
            },
            .fail => |err| {
                logging.debug("POST {s} -> {t} in {d} ms (attempt {d} of {d})", .{ self.url, err, elapsed_ms, attempt, max_attempts });
                return err;
            },
            .retry => |err| {
                logging.debug("POST {s} -> {t} in {d} ms (attempt {d} of {d})", .{ self.url, err, elapsed_ms, attempt, max_attempts });
                if (attempt >= max_attempts) return err;
                const delay_ms = self.retry.backoffMs(attempt, entropy(io));
                logging.warn("impersonation failed with {t}; retrying in {d} ms (attempt {d} of {d})", .{
                    err, delay_ms, attempt + 1, max_attempts,
                });
                try io.sleep(.fromMilliseconds(delay_ms), .awake);
            },
        }
    }
}

fn entropy(io: std.Io) u64 {
    var bytes: [8]u8 = undefined;
    io.random(&bytes);
    return std.mem.readInt(u64, &bytes, .little);
}

fn copyAll(gpa: Allocator, items: []const []const u8) Allocator.Error![][]u8 {
    const out = try gpa.alloc([]u8, items.len);
    var copied: usize = 0;
    errdefer {
        for (out[0..copied]) |item| wipeFree(gpa, item);
        wipeFree(gpa, out);
    }
    for (items, out) |item, *slot| {
        slot.* = try gpa.dupe(u8, item);
        copied += 1;
    }
    return out;
}

fn freeAll(gpa: Allocator, items: [][]u8) void {
    for (items) |item| wipeFree(gpa, item);
    wipeFree(gpa, items);
}

/// Wipes `buf` and frees it with `rawFree`, so the wipe is the last write.
/// `buf` may be a slice of anything; its bytes are what is wiped.
fn wipeFree(gpa: Allocator, buf: anytype) void {
    const bytes = std.mem.sliceAsBytes(buf);
    if (bytes.len == 0) return;
    std.crypto.secureZero(u8, bytes);
    gpa.rawFree(bytes, .fromByteUnits(@alignOf(std.meta.Elem(@TypeOf(buf)))), @returnAddress());
}

/// `wipeFree` for a single item made with `create`.
fn wipeDestroy(gpa: Allocator, item: anytype) void {
    const bytes = std.mem.asBytes(item);
    std.crypto.secureZero(u8, bytes);
    gpa.rawFree(bytes, .of(@TypeOf(item.*)), @returnAddress());
}

fn isPrintable(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text) |c| if (c < ' ' or c >= 0x7f) return false;
    return true;
}

const testing = std.testing;
const test_util = core.testing;
const Reply = test_util.FakeTransport.Reply;
const rsa = @import("rsa.zig");

const test_target = "sa@p.iam.gserviceaccount.com";
const google_url = "https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/" ++ test_target ++ ":generateAccessToken";
const test_scopes: []const []const u8 = &.{"https://www.googleapis.com/auth/pubsub"};
const user_source =
    \\{"type": "authorized_user", "client_id": "c.apps.googleusercontent.com",
    \\ "client_secret": "SECRET-client", "refresh_token": "1//SECRET-refresh"}
;

/// An impersonated file, as gcloud writes one, around `source`.
fn fileJson(comptime url: []const u8, comptime source: []const u8, comptime extra: []const u8) []const u8 {
    return "{\"type\": \"impersonated_service_account\", \"service_account_impersonation_url\": \"" ++ url ++
        "\", \"source_credentials\": " ++ source ++ extra ++ "}";
}
const user_file = fileJson(google_url, user_source, ", \"delegates\": []");

const source_ok: Reply = .{ .respond = .{ .body = "{\"access_token\":\"ya29.SOURCE-SECRET\",\"expires_in\":3599,\"token_type\":\"Bearer\"}" } };
const source_ok_again: Reply = .{ .respond = .{ .body = "{\"access_token\":\"ya29.SOURCE-SECRET-2\",\"expires_in\":3599,\"token_type\":\"Bearer\"}" } };
const iam_ok: Reply = .{ .respond = .{ .body = "{\"accessToken\":\"ya29.IMPERSONATED-SECRET\",\"expireTime\":\"2100-01-01T00:00:00Z\"}" } };
const iam_unauthorized: Reply = .{ .respond = .{ .status = 401, .body = "{\"error\":{\"code\":401,\"status\":\"UNAUTHENTICATED\",\"message\":\"Request had invalid authentication credentials.\"}}" } };
const iam_denied: Reply = .{ .respond = .{ .status = 403, .body = "{\"error\":{\"code\":403,\"status\":\"PERMISSION_DENIED\",\"message\":\"Permission 'iam.serviceAccounts.getAccessToken' denied\"}}" } };
const iam_unavailable: Reply = .{ .respond = .{ .status = 503, .body = "Service Unavailable" } };

const Harness = struct {
    arena: std.heap.ArenaAllocator,
    fake: test_util.FakeTransport,
    diag: Diagnostics,
    account: ImpersonatedServiceAccount,

    fn init(h: *Harness, script: []const Reply, json: []const u8) !void {
        h.arena = .init(testing.allocator);
        errdefer h.arena.deinit();
        h.fake = .init(testing.allocator, script);
        errdefer h.fake.deinit();
        h.diag = .{};
        h.account = try .initFromJson(testing.allocator, testing.io, json, .{
            .diagnostics = &h.diag,
            .transport = h.fake.transport(),
            .retry = .{ .max_attempts = 2, .initial_backoff_ms = 1, .max_backoff_ms = 5 },
        });
    }

    fn deinit(h: *Harness) void {
        h.account.deinit();
        h.fake.deinit();
        h.arena.deinit();
    }

    fn get(h: *Harness) TokenProvider.Error![]const u8 {
        return h.account.provider().getToken(testing.io, h.arena.allocator(), test_scopes);
    }
};

test "ImpersonatedServiceAccount: a user login acts as the service account" {
    var h: Harness = undefined;
    try h.init(&.{ source_ok, iam_ok }, user_file);
    defer h.deinit();

    try testing.expectEqualStrings("ya29.IMPERSONATED-SECRET", try h.get());
    try testing.expectEqualStrings(test_target, h.account.targetPrincipal());

    // First the source's own refresh, as its provider always makes it...
    const refresh = try h.fake.request(0);
    try testing.expectEqualStrings("https://oauth2.googleapis.com/token", refresh.url);
    try testing.expect(std.mem.indexOf(u8, refresh.body.?, "grant_type=refresh_token") != null);
    // ...then the trade, with the source token as the bearer.
    const trade = try h.fake.request(1);
    try testing.expectEqual(.POST, trade.method);
    try testing.expectEqualStrings(google_url, trade.url);
    try testing.expectEqualStrings("ya29.SOURCE-SECRET", trade.bearer.?);
    try testing.expectEqualStrings("{\"scope\":[\"https://www.googleapis.com/auth/pubsub\"],\"lifetime\":\"3600s\"}", trade.body.?);

    // Cached from here on.
    try testing.expectEqualStrings("ya29.IMPERSONATED-SECRET", try h.get());
    try testing.expectEqual(2, h.fake.requests.items.len);
}

test "ImpersonatedServiceAccount: the file's URL names the account, never the host" {
    // Google's libraries take only the account from this URL, and so does
    // this one: a crafted file cannot send a user's token anywhere else.
    var h: Harness = undefined;
    try h.init(&.{ source_ok, iam_ok }, fileJson("https://evil.example.com/steal/" ++ test_target ++ ":generateAccessToken", user_source, ""));
    defer h.deinit();
    _ = try h.get();
    for (h.fake.requests.items) |sent| {
        try testing.expect(std.mem.indexOf(u8, sent.url, "evil.example.com") == null);
    }
    try testing.expectEqualStrings(google_url, (try h.fake.request(1)).url);
}

test "ImpersonatedServiceAccount: a refreshed token reuses the source's" {
    var h: Harness = undefined;
    try h.init(&.{ source_ok, iam_ok, iam_ok }, user_file);
    defer h.deinit();
    _ = try h.get();
    // An API refused the impersonated token: only it is fetched again.
    h.account.provider().invalidate();
    _ = try h.get();
    try testing.expectEqual(3, h.fake.requests.items.len);
    try testing.expectEqualStrings(google_url, (try h.fake.request(2)).url);
    try testing.expectEqualStrings("ya29.SOURCE-SECRET", (try h.fake.request(2)).bearer.?);
}

test "ImpersonatedServiceAccount: a 401 from IAM fetches a fresh source token, once" {
    {
        var h: Harness = undefined;
        try h.init(&.{ source_ok, iam_unauthorized, source_ok_again, iam_ok }, user_file);
        defer h.deinit();
        try testing.expectEqualStrings("ya29.IMPERSONATED-SECRET", try h.get());
        try testing.expectEqual(4, h.fake.requests.items.len);
        try testing.expectEqualStrings("ya29.SOURCE-SECRET-2", (try h.fake.request(3)).bearer.?);
    }
    {
        var h: Harness = undefined;
        try h.init(&.{ source_ok, iam_unauthorized, source_ok_again, iam_unauthorized, source_ok, iam_ok }, user_file);
        defer h.deinit();
        try testing.expectError(error.TokenEndpointRejected, h.get());
        try testing.expectEqual(4, h.fake.requests.items.len);
        try testing.expectEqual(401, h.diag.http_status);
    }
}

test "ImpersonatedServiceAccount: a refusal names the role and the account" {
    var h: Harness = undefined;
    try h.init(&.{ source_ok, iam_denied }, user_file);
    defer h.deinit();
    try testing.expectError(error.TokenEndpointRejected, h.get());
    try testing.expectEqual(403, h.diag.http_status);
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "roles/iam.serviceAccountTokenCreator") != null);
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), test_target) != null);
    try testing.expectEqual(2, h.fake.requests.items.len);
}

test "ImpersonatedServiceAccount: transient failures are retried" {
    var h: Harness = undefined;
    try h.init(&.{ source_ok, iam_unavailable, iam_ok }, user_file);
    defer h.deinit();
    try testing.expectEqualStrings("ya29.IMPERSONATED-SECRET", try h.get());
    // One source fetch, cached across both tries.
    try testing.expectEqual(3, h.fake.requests.items.len);

    var gives_up: Harness = undefined;
    try gives_up.init(&.{ source_ok, iam_unavailable, iam_unavailable, iam_ok }, user_file);
    defer gives_up.deinit();
    try testing.expectError(error.TokenUnavailable, gives_up.get());
    try testing.expectEqual(3, gives_up.fake.requests.items.len);
}

test "ImpersonatedServiceAccount: the source's own failure is the caller's" {
    var h: Harness = undefined;
    try h.init(&.{.{ .respond = .{
        .status = 400,
        .body = "{\"error\":\"invalid_grant\",\"error_description\":\"Token has been expired or revoked.\"}",
    } }}, user_file);
    defer h.deinit();
    try testing.expectError(error.RefreshTokenInvalid, h.get());
    // Nothing went to IAM without a source token.
    try testing.expectEqual(1, h.fake.requests.items.len);
}

test "ImpersonatedServiceAccount: a service account key as the source" {
    const File = struct {
        type: []const u8 = "impersonated_service_account",
        service_account_impersonation_url: []const u8 = google_url,
        source_credentials: struct {
            type: []const u8 = "service_account",
            client_email: []const u8 = "source@p.iam.gserviceaccount.com",
            private_key: []const u8 = rsa.test_key_1024,
        } = .{},
    };
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const json = try std.json.Stringify.valueAlloc(arena.allocator(), File{}, .{});

    var h: Harness = undefined;
    try h.init(&.{ source_ok, iam_ok }, json);
    defer h.deinit();
    try testing.expectEqualStrings("ya29.IMPERSONATED-SECRET", try h.get());
    // The source signed a JWT for the grant, then its token did the trade.
    try testing.expect(std.mem.indexOf(u8, (try h.fake.request(0)).body.?, "jwt-bearer") != null);
    try testing.expectEqualStrings("ya29.SOURCE-SECRET", (try h.fake.request(1)).bearer.?);
}

test "ImpersonatedServiceAccount: delegates go through as the file gives them" {
    var h: Harness = undefined;
    try h.init(&.{ source_ok, iam_ok }, fileJson(google_url, user_source, ", \"delegates\": [\"projects/-/serviceAccounts/middle@p.iam.gserviceaccount.com\"]"));
    defer h.deinit();
    _ = try h.get();
    try testing.expectEqualStrings(
        "{\"delegates\":[\"projects/-/serviceAccounts/middle@p.iam.gserviceaccount.com\"],\"scope\":[\"https://www.googleapis.com/auth/pubsub\"],\"lifetime\":\"3600s\"}",
        (try h.fake.request(1)).body.?,
    );
}

test "ImpersonatedServiceAccount: the first call fixes the scopes" {
    var h: Harness = undefined;
    try h.init(&.{ source_ok, iam_ok }, user_file);
    defer h.deinit();
    _ = try h.get();
    try testing.expectError(error.TokenUnavailable, h.account.provider().getToken(testing.io, h.arena.allocator(), &.{"https://www.googleapis.com/auth/cloud-platform"}));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "second ImpersonatedServiceAccount") != null);
}

test "ImpersonatedServiceAccount: quota project, and the file types it refuses" {
    var diag: Diagnostics = .{};
    var fake: test_util.FakeTransport = .init(testing.allocator, &.{});
    defer fake.deinit();
    const options: Options = .{ .diagnostics = &diag, .transport = fake.transport() };

    var with_quota: ImpersonatedServiceAccount = try .initFromJson(testing.allocator, testing.io, fileJson(google_url, user_source, ", \"quota_project_id\": \"billing-project\""), options);
    defer with_quota.deinit();
    try testing.expectEqualStrings("billing-project", with_quota.quotaProjectId().?);
    try testing.expectEqualStrings("billing-project", with_quota.provider().quotaProject().?);

    try testing.expectError(error.UnsupportedCredentialType, ImpersonatedServiceAccount.initFromJson(testing.allocator, testing.io, user_source, options));
    try testing.expect(std.mem.indexOf(u8, diag.message(), "use AuthorizedUser") != null);
    try testing.expectError(error.InvalidCredentialsFile, ImpersonatedServiceAccount.initFromJson(testing.allocator, testing.io, fileJson("https://x/sa:generateToken", user_source, ""), options));
    try testing.expectError(error.UnsupportedCredentialType, ImpersonatedServiceAccount.initFromJson(testing.allocator, testing.io, fileJson(google_url, "{\"type\": \"external_account\"}", ""), options));
    try testing.expect(std.mem.indexOf(u8, diag.message(), "only authorized_user and service_account") != null);

    var bad = options;
    bad.iam_endpoint = "http://iamcredentials.example.com";
    try testing.expectError(error.InvalidOptions, ImpersonatedServiceAccount.initFromJson(testing.allocator, testing.io, user_file, bad));
    bad = options;
    bad.lifetime_s = 0;
    try testing.expectError(error.InvalidOptions, ImpersonatedServiceAccount.initFromJson(testing.allocator, testing.io, user_file, bad));
    bad.lifetime_s = max_lifetime_s + 1;
    try testing.expectError(error.InvalidOptions, ImpersonatedServiceAccount.initFromJson(testing.allocator, testing.io, user_file, bad));
    // A test endpoint on this machine is fine, and the account goes on it.
    var local = options;
    local.iam_endpoint = "http://127.0.0.1:8080";
    var on_loopback: ImpersonatedServiceAccount = try .initFromJson(testing.allocator, testing.io, user_file, local);
    defer on_loopback.deinit();
    try testing.expectEqualStrings("http://127.0.0.1:8080/v1/projects/-/serviceAccounts/" ++ test_target ++ ":generateAccessToken", on_loopback.url);
}

test "ImpersonatedServiceAccount: secrets reach neither the log nor Diagnostics" {
    logging.capture.reset();
    var h: Harness = undefined;
    try h.init(&.{ source_ok, iam_unauthorized, source_ok_again, iam_unavailable, iam_ok, iam_denied }, user_file);
    defer h.deinit();
    _ = try h.get();
    h.account.provider().invalidate();
    try testing.expectError(error.TokenEndpointRejected, h.get());
    const log = logging.capture.text();
    try testing.expect(logging.capture.lines > 0);
    for ([_][]const u8{ "SECRET-client", "1//SECRET-refresh", "ya29.SOURCE-SECRET", "ya29.IMPERSONATED-SECRET" }) |secret| {
        try testing.expect(std.mem.indexOf(u8, log, secret) == null);
        try testing.expect(std.mem.indexOf(u8, h.diag.message(), secret) == null);
    }
}

test "ImpersonatedServiceAccount: every block it frees is wiped first" {
    var checker: test_util.WipeChecker = .{ .child = testing.allocator };
    var fake: test_util.FakeTransport = .init(testing.allocator, &.{ source_ok, iam_ok });
    defer fake.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    var account: ImpersonatedServiceAccount = try .initFromJson(checker.allocator(), testing.io, fileJson(
        google_url,
        user_source,
        ", \"delegates\": [\"projects/-/serviceAccounts/middle@p.iam.gserviceaccount.com\"], \"quota_project_id\": \"q\"",
    ), .{ .transport = fake.transport() });
    _ = try account.provider().getToken(testing.io, scratch.allocator(), test_scopes);
    account.deinit();
    try testing.expect(checker.frees > 0);
    try testing.expectEqual(0, checker.unwiped);
}

test "ImpersonatedServiceAccount: every allocation failure is OutOfMemory without leaks" {
    const Run = struct {
        fn get(gpa: Allocator) !void {
            var fake: test_util.FakeTransport = .init(testing.allocator, &.{ source_ok, iam_ok });
            defer fake.deinit();
            var scratch: std.heap.ArenaAllocator = .init(gpa);
            defer scratch.deinit();
            var account: ImpersonatedServiceAccount = try .initFromJson(gpa, testing.io, fileJson(
                google_url,
                user_source,
                ", \"delegates\": [\"projects/-/serviceAccounts/m@p.iam.gserviceaccount.com\"], \"quota_project_id\": \"q\"",
            ), .{ .transport = fake.transport() });
            defer account.deinit();
            _ = try account.provider().getToken(testing.io, scratch.allocator(), test_scopes);
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Run.get, .{});
}

fn anyIamReplyProperty(_: void, input: []const u8) !void {
    var g: test_util.ByteGen = .init(input);
    const status = g.pick(u16, &.{ 200, 200, 400, 401, 403, 404, 429, 500, 503, 302, 0 });
    const reply: Reply = .{ .respond = .{ .status = status, .body = g.rest() } };
    var h: Harness = undefined;
    // Enough source tokens and replies for every retry the policy allows.
    try h.init(&.{ source_ok, reply, source_ok_again, reply, reply }, user_file);
    defer h.deinit();
    // Whatever IAM says: a usable token or an error, and no leak.
    const token = h.get() catch return;
    try testing.expect(TokenProvider.isValidToken(token));
}

test "fuzz ImpersonatedServiceAccount: any IAM reply yields a token or an error" {
    try test_util.fuzzBytes({}, anyIamReplyProperty, .{ .corpus = &.{
        "\x00\x00\x00\x00\x00\x00\x00\x00{\"accessToken\":\"ya29.x\",\"expireTime\":\"2100-01-01T00:00:00Z\"}",
        "\x00\x00\x00\x00\x00\x00\x00\x00{\"accessToken\":\"ya29 x\",\"expireTime\":\"2100-01-01T00:00:00Z\"}",
        "\x00\x00\x00\x00\x00\x00\x00\x00{\"accessToken\":\"t\",\"expireTime\":\"not a time\"}",
        "\x00\x00\x00\x00\x00\x00\x00\x03{\"error\":{\"status\":\"UNAUTHENTICATED\"}}",
    } });
}
