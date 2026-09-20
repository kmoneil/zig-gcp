//! Tokens for workload identity federation, the `external_account` file
//! that lets a workload authenticate with a third-party identity instead
//! of a stored Google key: GitHub Actions with its OIDC token, GKE with a
//! projected service account token, Azure with its metadata service.
//!
//! Each fetch reads the subject token from the file's credential source (a
//! file or a URL), trades it at Google's STS for an access token, and,
//! when the file names a service account to impersonate, trades that once
//! more at the IAM Credentials API. The cache keeps the result until
//! shortly before it expires. Subject tokens and access tokens are
//! secrets: never logged, and memory that held them is wiped.
//!
//! Like a service account's, this provider's tokens are minted for
//! particular scopes, so the first `getToken` fixes them; use a second
//! provider for a second scope set. AWS credential sources (which need
//! request signing) and executable sources (which run a subprocess) are
//! refused by name when the file is parsed.

const ExternalAccount = @This();

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
/// All owned, and all wiped before they are freed.
audience: []u8,
subject_token_type: []u8,
token_url: []u8,
source: Source,
impersonation_url: ?[]u8,
impersonation_lifetime_s: u32,
quota_project_id: ?[]u8,
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

pub const default_token_url = "https://sts.googleapis.com/v1/token";

/// RFC 8693, which is what Google's STS speaks.
const exchange_grant_type = "urn:ietf:params:oauth:grant-type:token-exchange";
const requested_token_type = "urn:ietf:params:oauth:token-type:access_token";
/// The scope the STS token gets when it exists only to impersonate: it
/// must reach the IAM Credentials API and nothing else is asked of it.
const impersonation_scope = "https://www.googleapis.com/auth/cloud-platform";

/// An owned copy of the file's credential source.
const Source = struct {
    kind: enum { file, url },
    where: []u8,
    headers: []core.transport.Header,
    /// Empty means the document is the token; otherwise the document is
    /// JSON and this names the field holding it.
    json_field: []u8,

    fn deinit(source: *Source, gpa: Allocator) void {
        for (source.headers) |h| {
            wipeFree(gpa, @constCast(h.name));
            wipeFree(gpa, @constCast(h.value));
        }
        wipeFree(gpa, source.headers);
        wipeFree(gpa, source.where);
        wipeFree(gpa, source.json_field);
        source.* = undefined;
    }
};

pub const Options = struct {
    /// Overrides the STS endpoint: null means the file's `token_url`, or
    /// Google's. Plain http is accepted only to this machine (127.0.0.1,
    /// [::1] or localhost), as tests use.
    token_url: ?[]const u8 = null,
    /// A token fetch sits in front of every API call, so it gives up sooner
    /// than an API call would.
    retry: core.RetryPolicy = .{ .max_attempts = 3 },
    cache: Cache.Options = .{},
    /// How long one request may take before it is `error.TimedOut`, which
    /// the retry policy treats as transient. 0 removes the limit.
    request_timeout_ms: u32 = 30_000,
    /// Printable ASCII.
    user_agent: []const u8 = "zig-gcp-auth/0.9",
    /// Filled with the details of the last failure, while reading the file
    /// or from the endpoints. Never holds a secret.
    diagnostics: ?*Diagnostics = null,
    /// Sends requests through this instead of `std.http.Client`.
    transport: ?Transport = null,
};

pub const InitError = error{
    /// The file is missing or cannot be read.
    CredentialsFileNotFound,
    InvalidCredentialsFile,
    UnsupportedCredentialType,
    /// An endpoint that is neither https nor on this machine, or an
    /// invalid retry policy, cache setting or user agent.
    InvalidOptions,
    Canceled,
    OutOfMemory,
};

/// Reads the credentials file at `path`. Files over 64 KiB are refused.
pub fn initFromFile(gpa: Allocator, io: std.Io, path: []const u8, options: Options) InitError!ExternalAccount {
    if (options.diagnostics) |d| d.clear();
    var wiping: core.WipingAllocator = .init(gpa);
    var scratch: std.heap.ArenaAllocator = .init(wiping.allocator());
    defer scratch.deinit();
    const json = try adc_file.readFile(io, scratch.allocator(), path, options.diagnostics);
    return initFromJson(gpa, io, json, options);
}

/// Reads credentials from the contents of a credentials file. Copies what
/// it keeps; `json` can be wiped as soon as this returns.
pub fn initFromJson(gpa: Allocator, io: std.Io, json: []const u8, options: Options) InitError!ExternalAccount {
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
        .external_account => |account| account,
        .authorized_user => {
            if (diag) |d| d.print("the credentials file is an OAuth user login; use AuthorizedUser, or findDefault", .{});
            return error.UnsupportedCredentialType;
        },
        .service_account => {
            if (diag) |d| d.print("the credentials file is a service account key; use ServiceAccount, or findDefault", .{});
            return error.UnsupportedCredentialType;
        },
    };

    const token_url_source = options.token_url orelse file.token_url orelse default_token_url;
    if (!token_response.isAcceptableTokenUrl(token_url_source)) {
        if (diag) |d| d.print("the credentials file's \"token_url\" must use https, or http to this machine", .{});
        return error.InvalidCredentialsFile;
    }
    if (file.impersonation_url) |url| if (!token_response.isAcceptableTokenUrl(url)) {
        if (diag) |d| d.print("the credentials file's \"service_account_impersonation_url\" must use https, or http to this machine", .{});
        return error.InvalidCredentialsFile;
    };
    // The IAM Credentials API's own bounds.
    const lifetime = file.impersonation_lifetime_s orelse 3600;
    if (lifetime < 600 or lifetime > 43_200) {
        if (diag) |d| d.print("the credentials file's \"token_lifetime_seconds\" must be 600 to 43200", .{});
        return error.InvalidCredentialsFile;
    }
    const target = switch (file.credential_source) {
        inline else => |t| t,
    };
    if (file.credential_source == .url) {
        const uri = std.Uri.parse(target.where) catch {
            if (diag) |d| d.print("the credential_source url cannot be parsed", .{});
            return error.InvalidCredentialsFile;
        };
        // Plain http is allowed: metadata services answer on link-local
        // addresses, as Azure's does. The token then leaves only over the
        // STS connection, which its own check bounds.
        if (!std.ascii.eqlIgnoreCase(uri.scheme, "http") and !std.ascii.eqlIgnoreCase(uri.scheme, "https")) {
            if (diag) |d| d.print("the credential_source url must use http or https", .{});
            return error.InvalidCredentialsFile;
        }
    }

    const audience = try gpa.dupe(u8, file.audience);
    errdefer wipeFree(gpa, audience);
    const subject_token_type = try gpa.dupe(u8, file.subject_token_type);
    errdefer wipeFree(gpa, subject_token_type);
    const token_url = try gpa.dupe(u8, token_url_source);
    errdefer wipeFree(gpa, token_url);
    const impersonation_url = if (file.impersonation_url) |url| try gpa.dupe(u8, url) else null;
    errdefer if (impersonation_url) |url| wipeFree(gpa, url);
    const quota_project_id = if (file.quota_project_id) |q| try gpa.dupe(u8, q) else null;
    errdefer if (quota_project_id) |q| wipeFree(gpa, q);
    const user_agent = try gpa.dupe(u8, options.user_agent);
    errdefer wipeFree(gpa, user_agent);
    var source = try copySource(gpa, file.credential_source);
    errdefer source.deinit(gpa);

    var http: ?*HttpTransport = null;
    const transport = options.transport orelse t: {
        const h = try gpa.create(HttpTransport);
        h.* = .init(gpa, io, user_agent);
        http = h;
        break :t h.transport();
    };
    return .{
        .gpa = gpa,
        .audience = audience,
        .subject_token_type = subject_token_type,
        .token_url = token_url,
        .source = source,
        .impersonation_url = impersonation_url,
        .impersonation_lifetime_s = lifetime,
        .quota_project_id = quota_project_id,
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

fn copySource(gpa: Allocator, parsed: adc_file.CredentialSource) Allocator.Error!Source {
    const target = switch (parsed) {
        inline else => |t| t,
    };
    const where = try gpa.dupe(u8, target.where);
    errdefer wipeFree(gpa, where);
    const json_field = try gpa.dupe(u8, switch (target.format) {
        .text => "",
        .json_field => |field| field,
    });
    errdefer wipeFree(gpa, json_field);
    const headers = try gpa.alloc(core.transport.Header, target.headers.len);
    var copied: usize = 0;
    errdefer {
        for (headers[0..copied]) |h| {
            wipeFree(gpa, @constCast(h.name));
            wipeFree(gpa, @constCast(h.value));
        }
        wipeFree(gpa, headers);
    }
    for (target.headers, headers) |from, *to| {
        const name = try gpa.dupe(u8, from.name);
        errdefer wipeFree(gpa, name);
        to.* = .{ .name = name, .value = try gpa.dupe(u8, from.value) };
        copied += 1;
    }
    return .{
        .kind = switch (parsed) {
            .file => .file,
            .url => .url,
        },
        .where = where,
        .headers = headers,
        .json_field = json_field,
    };
}

/// Wipes everything, the cached access token included.
pub fn deinit(self: *ExternalAccount) void {
    self.cache.deinit();
    if (self.http) |h| {
        h.deinit();
        self.gpa.destroy(h);
    }
    self.scopes.deinit(self.gpa);
    self.source.deinit(self.gpa);
    wipeFree(self.gpa, self.audience);
    wipeFree(self.gpa, self.subject_token_type);
    wipeFree(self.gpa, self.token_url);
    if (self.impersonation_url) |url| wipeFree(self.gpa, url);
    if (self.quota_project_id) |q| wipeFree(self.gpa, q);
    wipeFree(self.gpa, self.user_agent);
    self.* = undefined;
}

/// The provider points at this struct, which must not move while the
/// provider is in use.
pub fn provider(self: *ExternalAccount) TokenProvider {
    return .{ .ptr = self, .vtable = &.{
        .getToken = getToken,
        .invalidate = invalidate,
        .quotaProject = quotaProject,
    } };
}

/// The project the file names for quota, if any.
pub fn quotaProjectId(self: *const ExternalAccount) ?[]const u8 {
    return self.quota_project_id;
}

fn fromPtr(ptr: *anyopaque) *ExternalAccount {
    return @ptrCast(@alignCast(ptr));
}

fn getToken(ptr: *anyopaque, io: std.Io, arena: Allocator, scopes: []const []const u8) TokenProvider.Error![]const u8 {
    const self = fromPtr(ptr);
    try self.scopes.bind(io, self.gpa, scopes, self.diagnostics, "ExternalAccount");
    return self.cache.getToken(io, arena, .{ .ptr = self, .fetchFn = fetch });
}

fn invalidate(ptr: *anyopaque) void {
    fromPtr(ptr).cache.invalidate();
}

fn quotaProject(ptr: *anyopaque) ?[]const u8 {
    return fromPtr(ptr).quota_project_id;
}

/// One whole fetch: subject token, STS exchange, and impersonation when
/// the file asks for it. `arena` is the cache's scratch memory, which it
/// wipes: everything here is or touches a secret.
fn fetch(ptr: *anyopaque, io: std.Io, arena: Allocator) TokenProvider.Error!Cache.Fetched {
    const self = fromPtr(ptr);
    const max_attempts = self.retry.max_attempts;
    var attempt: u32 = 1;
    while (true) : (attempt += 1) {
        const started = std.Io.Clock.awake.now(io);
        // The subject token is read anew each attempt: they rotate, and a
        // stale one is the likeliest thing a retry fixes.
        const result = self.exchange(io, arena);
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
                logging.warn("the token exchange failed with {t}; retrying in {d} ms (attempt {d} of {d})", .{
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

/// One whole attempt, each step feeding the next.
fn exchange(self: *ExternalAccount, io: std.Io, arena: Allocator) Result {
    const subject = switch (self.subjectToken(io, arena)) {
        .ok => |token| token,
        .retry => |err| return .{ .retry = err },
        .fail => |err| return .{ .fail = err },
    };
    const sts = switch (self.stsExchange(arena, subject)) {
        .token => |fetched| fetched,
        .retry => |err| return .{ .retry = err },
        .fail => |err| return .{ .fail = err },
    };
    if (self.impersonation_url == null) return .{ .token = sts };
    return self.impersonate(io, arena, sts.token);
}

const SubjectResult = union(enum) {
    ok: []const u8,
    retry: TokenProvider.Error,
    fail: TokenProvider.Error,
};

/// The third-party token, from the file or the URL the credentials name.
fn subjectToken(self: *ExternalAccount, io: std.Io, arena: Allocator) SubjectResult {
    const document: []const u8 = switch (self.source.kind) {
        .file => std.Io.Dir.cwd().readFileAlloc(io, self.source.where, arena, .limited(adc_file.max_file_bytes)) catch |err| {
            if (err == error.Canceled) return .{ .fail = error.Canceled };
            if (err == error.OutOfMemory) return .{ .fail = error.OutOfMemory };
            if (self.diagnostics) |d| d.print("cannot read the credential_source file {s}: {t}", .{ self.source.where, err });
            // The token file may not be written yet; a retry can find it.
            return .{ .retry = error.TokenUnavailable };
        },
        .url => document: {
            const res = self.transport.send(.{
                .method = .GET,
                .url = self.source.where,
                .headers = self.source.headers,
                .timeout_ms = self.request_timeout_ms,
            }, arena) catch |err| {
                if (self.diagnostics) |d| d.print("the credential_source url could not be reached: {t}", .{err});
                return if (core.isRetryable(err)) .{ .retry = err } else .{ .fail = err };
            };
            if (res.status != 200) {
                if (self.diagnostics) |d| d.print("the credential_source url answered HTTP {d}", .{res.status});
                const err: TokenProvider.Error = error.TokenUnavailable;
                return if (res.status == 429 or res.status >= 500) .{ .retry = err } else .{ .fail = err };
            }
            break :document res.body;
        },
    };

    const token = if (self.source.json_field.len == 0)
        std.mem.trim(u8, document, &std.ascii.whitespace)
    else token: {
        const Wire = std.json.ArrayHashMap([]const u8);
        const wire = std.json.parseFromSliceLeaky(Wire, arena, document, .{
            .ignore_unknown_fields = true,
        }) catch {
            if (self.diagnostics) |d| d.print("the credential_source document is not a JSON object of strings", .{});
            return .{ .fail = error.InvalidTokenResponse };
        };
        break :token wire.map.get(self.source.json_field) orelse {
            if (self.diagnostics) |d| d.print("the credential_source document has no \"{s}\"", .{self.source.json_field});
            return .{ .fail = error.InvalidTokenResponse };
        };
    };
    if (!TokenProvider.isValidToken(token)) {
        if (self.diagnostics) |d| d.print("the credential_source held no usable token", .{});
        return .{ .fail = error.TokenUnavailable };
    }
    return .{ .ok = token };
}

/// Trades the subject token at the STS for a Google access token.
fn stsExchange(self: *ExternalAccount, arena: Allocator, subject: []const u8) Result {
    // With impersonation, the STS token exists only to reach the IAM
    // Credentials API; without it, it is the token the caller gets.
    const scope = if (self.impersonation_url != null) impersonation_scope else self.scopes.joined.?;
    const body = form.encode(arena, &.{
        .{ .name = "grant_type", .value = exchange_grant_type },
        .{ .name = "audience", .value = self.audience },
        .{ .name = "scope", .value = scope },
        .{ .name = "requested_token_type", .value = requested_token_type },
        .{ .name = "subject_token_type", .value = self.subject_token_type },
        .{ .name = "subject_token", .value = subject },
    }) catch return .{ .fail = error.OutOfMemory };

    const res = self.transport.send(.{
        .method = .POST,
        .url = self.token_url,
        .body = body,
        .content_type = .form,
        .timeout_ms = self.request_timeout_ms,
    }, arena) catch |err| {
        if (self.diagnostics) |d| d.print("the STS endpoint could not be reached: {t}", .{err});
        return if (core.isRetryable(err)) .{ .retry = err } else .{ .fail = err };
    };
    if (res.status == 200) {
        const fetched = token_response.parse(arena, res.body) catch |err| {
            if (err == error.InvalidTokenResponse) {
                if (self.diagnostics) |d| d.print("the STS answer has no usable access_token and expires_in", .{});
            }
            return .{ .fail = err };
        };
        return .{ .token = fetched };
    }
    const oauth = token_response.parseError(arena, res.body) catch |err| return .{ .fail = err };
    if (self.diagnostics) |d| {
        if (oauth) |e| {
            if (std.mem.eql(u8, e.code, "invalid_grant")) {
                const fix = "Check the workload identity pool, its provider, and the subject token's issuer and audience claims.";
                const generic = "The subject token was rejected. " ++ fix;
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
            d.set(res.status, "", "the STS endpoint refused the request");
        }
    }
    if (res.status == 429 or res.status >= 500) return .{ .retry = error.TokenUnavailable };
    return .{ .fail = error.TokenEndpointRejected };
}

/// Trades the STS token for one that acts as the service account.
fn impersonate(self: *ExternalAccount, io: std.Io, arena: Allocator, sts_token: []const u8) Result {
    var out: std.Io.Writer.Allocating = .init(arena);
    {
        var json: std.json.Stringify = .{ .writer = &out.writer };
        const write = struct {
            fn f(j: *std.json.Stringify, self_: *ExternalAccount) !void {
                try j.beginObject();
                try j.objectField("scope");
                try j.beginArray();
                var scopes = std.mem.splitScalar(u8, self_.scopes.joined.?, ' ');
                while (scopes.next()) |scope| try j.write(scope);
                try j.endArray();
                try j.objectField("lifetime");
                var buf: [16]u8 = undefined;
                try j.write(std.fmt.bufPrint(&buf, "{d}s", .{self_.impersonation_lifetime_s}) catch unreachable);
                try j.endObject();
            }
        }.f;
        write(&json, self) catch return .{ .fail = error.OutOfMemory };
    }

    const res = self.transport.send(.{
        .method = .POST,
        .url = self.impersonation_url.?,
        .bearer = sts_token,
        .body = out.written(),
        .content_type = .json,
        .timeout_ms = self.request_timeout_ms,
    }, arena) catch |err| {
        if (self.diagnostics) |d| d.print("the IAM Credentials endpoint could not be reached: {t}", .{err});
        return if (core.isRetryable(err)) .{ .retry = err } else .{ .fail = err };
    };
    if (res.status != 200) {
        const body = core.errors.decodeErrorBody(arena, res.body) catch |err| return .{ .fail = err };
        if (self.diagnostics) |d| {
            const status = if (body) |b| b.status else "";
            if (res.status == 403) {
                d.set(res.status, status, "impersonation was refused: grant roles/iam.workloadIdentityUser on the service account to the pool identity");
            } else {
                d.set(res.status, status, if (body) |b| b.message else res.body);
            }
        }
        if (res.status == 429 or res.status >= 500) return .{ .retry = error.TokenUnavailable };
        return .{ .fail = error.TokenEndpointRejected };
    }

    const Wire = struct {
        accessToken: ?[]const u8 = null,
        expireTime: ?[]const u8 = null,
    };
    const wire = std.json.parseFromSliceLeaky(Wire, arena, res.body, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => return .{ .fail = error.OutOfMemory },
        else => return invalidImpersonation(self),
    };
    const token = wire.accessToken orelse return invalidImpersonation(self);
    const expire_text = wire.expireTime orelse return invalidImpersonation(self);
    const expires_at = core.timestamp.parse(expire_text) catch return invalidImpersonation(self);
    const now = std.Io.Clock.real.now(io);
    const expires_in = @divFloor(expires_at.nanoseconds - now.nanoseconds, std.time.ns_per_s);
    if (expires_in <= 0) return invalidImpersonation(self);
    return .{ .token = .{ .token = token, .expires_in = @intCast(@min(expires_in, std.math.maxInt(i64))) } };
}

fn invalidImpersonation(self: *ExternalAccount) Result {
    if (self.diagnostics) |d| d.print("the IAM Credentials answer has no usable accessToken and expireTime", .{});
    return .{ .fail = error.InvalidTokenResponse };
}

fn entropy(io: std.Io) u64 {
    var bytes: [8]u8 = undefined;
    io.random(&bytes);
    return std.mem.readInt(u64, &bytes, .little);
}

/// Wipes `buf` and frees it with `rawFree`, so the wipe is the last write.
/// `buf` may be another type's bytes, whose alignment `rawFree` needs.
fn wipeFree(gpa: Allocator, buf: anytype) void {
    const bytes = std.mem.sliceAsBytes(buf);
    if (bytes.len == 0) return;
    std.crypto.secureZero(u8, bytes);
    gpa.rawFree(bytes, .fromByteUnits(@alignOf(std.meta.Elem(@TypeOf(buf)))), @returnAddress());
}

fn isPrintable(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text) |c| if (c < ' ' or c >= 0x7f) return false;
    return true;
}

const testing = std.testing;
const test_util = core.testing;
const Reply = test_util.FakeTransport.Reply;

const test_audience = "//iam.googleapis.com/projects/1/locations/global/workloadIdentityPools/pool/providers/gha";
const test_scopes: []const []const u8 = &.{"https://www.googleapis.com/auth/pubsub"};
const sts_ok: Reply = .{ .respond = .{ .body = "{\"access_token\":\"ya29.STS-SECRET\",\"expires_in\":3599,\"token_type\":\"Bearer\"}" } };
const unavailable: Reply = .{ .respond = .{ .status = 503, .body = "Service Unavailable" } };

/// A credentials file around `source`, optionally impersonating.
fn credJson(arena: Allocator, source: []const u8, impersonated: bool) ![]const u8 {
    return std.fmt.allocPrint(arena,
        \\{{"type": "external_account", "audience": "{s}",
        \\ "subject_token_type": "urn:ietf:params:oauth:token-type:jwt",
        \\ "token_url": "https://sts.googleapis.com/v1/token",
        \\ "credential_source": {s}{s}}}
    , .{
        test_audience,
        source,
        if (impersonated)
            \\, "service_account_impersonation_url": "https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/sa@p.iam.gserviceaccount.com:generateAccessToken"
        else
            "",
    });
}

/// An `ExternalAccount` wired to a fake transport, its subject token in a
/// temporary file unless a url source is given.
const Harness = struct {
    tmp: testing.TmpDir,
    arena: std.heap.ArenaAllocator,
    fake: test_util.FakeTransport,
    diag: Diagnostics,
    account: ExternalAccount,

    fn init(h: *Harness, script: []const Reply, options: struct {
        subject: []const u8 = "subject-token-abc",
        source: ?[]const u8 = null,
        impersonate: bool = false,
    }) !void {
        h.tmp = testing.tmpDir(.{});
        errdefer h.tmp.cleanup();
        h.arena = .init(testing.allocator);
        errdefer h.arena.deinit();
        h.fake = .init(testing.allocator, script);
        errdefer h.fake.deinit();
        h.diag = .{};

        const a = h.arena.allocator();
        const source = options.source orelse source: {
            try h.tmp.dir.writeFile(testing.io, .{ .sub_path = "subject", .data = options.subject });
            break :source try std.fmt.allocPrint(a, "{{\"file\": \".zig-cache/tmp/{s}/subject\"}}", .{&h.tmp.sub_path});
        };
        h.account = try .initFromJson(testing.allocator, testing.io, try credJson(a, source, options.impersonate), .{
            .diagnostics = &h.diag,
            .transport = h.fake.transport(),
            .retry = .{ .max_attempts = 2, .initial_backoff_ms = 1, .max_backoff_ms = 5 },
        });
    }

    fn deinit(h: *Harness) void {
        h.account.deinit();
        h.fake.deinit();
        h.arena.deinit();
        h.tmp.cleanup();
    }

    fn get(h: *Harness) TokenProvider.Error![]const u8 {
        return h.account.provider().getToken(testing.io, h.arena.allocator(), test_scopes);
    }
};

test "ExternalAccount: a file-sourced token is traded at the STS, with every RFC 8693 field" {
    var h: Harness = undefined;
    try h.init(&.{sts_ok}, .{});
    defer h.deinit();
    try testing.expectEqualStrings("ya29.STS-SECRET", try h.get());

    const req = try h.fake.request(0);
    try testing.expectEqual(.POST, req.method);
    try testing.expectEqualStrings("https://sts.googleapis.com/v1/token", req.url);
    try testing.expectEqual(.form, req.content_type);
    try testing.expectEqual(null, req.bearer);
    const body = req.body.?;
    try testing.expect(std.mem.startsWith(u8, body, "grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Atoken-exchange"));
    try testing.expect(std.mem.indexOf(u8, body, "&audience=%2F%2Fiam.googleapis.com%2Fprojects%2F1%2F") != null);
    try testing.expect(std.mem.indexOf(u8, body, "&scope=https%3A%2F%2Fwww.googleapis.com%2Fauth%2Fpubsub") != null);
    try testing.expect(std.mem.indexOf(u8, body, "&requested_token_type=urn%3Aietf%3Aparams%3Aoauth%3Atoken-type%3Aaccess_token") != null);
    try testing.expect(std.mem.indexOf(u8, body, "&subject_token_type=urn%3Aietf%3Aparams%3Aoauth%3Atoken-type%3Ajwt") != null);
    try testing.expect(std.mem.endsWith(u8, body, "&subject_token=subject-token-abc"));

    // The second call is served from the cache.
    _ = try h.get();
    try testing.expectEqual(1, h.fake.requests.items.len);
}

test "ExternalAccount: the subject token is read anew after invalidate, because they rotate" {
    var h: Harness = undefined;
    try h.init(&.{ sts_ok, sts_ok }, .{});
    defer h.deinit();
    _ = try h.get();
    try h.tmp.dir.writeFile(testing.io, .{ .sub_path = "subject", .data = "rotated-token" });
    h.account.provider().invalidate();
    _ = try h.get();
    try testing.expect(std.mem.endsWith(u8, (try h.fake.request(1)).body.?, "&subject_token=rotated-token"));
}

test "ExternalAccount: a url source sends its headers and reads the json field" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = "{\"token_type\":\"x\",\"access_token\":\"url-subject-token\"}" } },
        sts_ok,
    }, .{ .source =
        \\{"url": "http://169.254.169.254/identity", "headers": {"Metadata": "True"},
        \\ "format": {"type": "json", "subject_token_field_name": "access_token"}}
    });
    defer h.deinit();
    try testing.expectEqualStrings("ya29.STS-SECRET", try h.get());

    const fetch_req = try h.fake.request(0);
    try testing.expectEqual(.GET, fetch_req.method);
    try testing.expectEqualStrings("http://169.254.169.254/identity", fetch_req.url);
    try testing.expectEqualStrings("True", fetch_req.header("Metadata").?);
    try testing.expect(std.mem.endsWith(u8, (try h.fake.request(1)).body.?, "&subject_token=url-subject-token"));
}

test "ExternalAccount: impersonation trades the STS token once more, scoped down" {
    var h: Harness = undefined;
    try h.init(&.{
        sts_ok,
        .{ .respond = .{ .body = "{\"accessToken\":\"ya29.IMPERSONATED\",\"expireTime\":\"2100-01-01T00:00:00Z\"}" } },
    }, .{ .impersonate = true });
    defer h.deinit();
    try testing.expectEqualStrings("ya29.IMPERSONATED", try h.get());

    // The STS token asks only for what impersonation needs.
    try testing.expect(std.mem.indexOf(u8, (try h.fake.request(0)).body.?, "&scope=https%3A%2F%2Fwww.googleapis.com%2Fauth%2Fcloud-platform") != null);
    const grant = try h.fake.request(1);
    try testing.expectEqualStrings("https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/sa@p.iam.gserviceaccount.com:generateAccessToken", grant.url);
    try testing.expectEqualStrings("ya29.STS-SECRET", grant.bearer.?);
    try testing.expectEqual(.json, grant.content_type);
    try testing.expectEqualStrings("{\"scope\":[\"https://www.googleapis.com/auth/pubsub\"],\"lifetime\":\"3600s\"}", grant.body.?);
}

test "ExternalAccount: impersonation refused is TokenEndpointRejected and names the missing role" {
    var h: Harness = undefined;
    try h.init(&.{
        sts_ok,
        .{ .respond = .{ .status = 403, .body = "{\"error\":{\"code\":403,\"message\":\"denied\",\"status\":\"PERMISSION_DENIED\"}}" } },
    }, .{ .impersonate = true });
    defer h.deinit();
    try testing.expectError(error.TokenEndpointRejected, h.get());
    try testing.expectEqual(403, h.diag.http_status);
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "workloadIdentityUser") != null);
}

test "ExternalAccount: an unusable impersonation answer is InvalidTokenResponse" {
    for ([_][]const u8{
        "{\"accessToken\":\"t\"}",
        "{\"expireTime\":\"2100-01-01T00:00:00Z\"}",
        "{\"accessToken\":\"t\",\"expireTime\":\"not a time\"}",
        // Already expired when it arrived.
        "{\"accessToken\":\"t\",\"expireTime\":\"2000-01-01T00:00:00Z\"}",
        "<html>",
    }) |body| {
        var h: Harness = undefined;
        try h.init(&.{ sts_ok, .{ .respond = .{ .body = body } } }, .{ .impersonate = true });
        defer h.deinit();
        try testing.expectError(error.InvalidTokenResponse, h.get());
    }
}

test "ExternalAccount: the STS rejecting the subject token says what to check" {
    var h: Harness = undefined;
    try h.init(&.{.{ .respond = .{
        .status = 400,
        .body = "{\"error\":\"invalid_grant\",\"error_description\":\"The audience in the token does not match.\"}",
    } }}, .{});
    defer h.deinit();
    try testing.expectError(error.TokenEndpointRejected, h.get());
    try testing.expectEqual(1, h.fake.requests.items.len);
    try testing.expectEqualStrings("invalid_grant", h.diag.status());
    try testing.expectEqualStrings("The audience in the token does not match. Check the workload identity pool, its provider, and the subject token's issuer and audience claims.", h.diag.message());
}

test "ExternalAccount: a busy STS is retried with a fresh subject read" {
    var h: Harness = undefined;
    try h.init(&.{ unavailable, sts_ok }, .{});
    defer h.deinit();
    try testing.expectEqualStrings("ya29.STS-SECRET", try h.get());
    try testing.expectEqual(2, h.fake.requests.items.len);
}

test "ExternalAccount: a missing subject file is retried, then TokenUnavailable" {
    var h: Harness = undefined;
    try h.init(&.{}, .{});
    defer h.deinit();
    try h.tmp.dir.deleteFile(testing.io, "subject");
    try testing.expectError(error.TokenUnavailable, h.get());
    try testing.expectEqual(0, h.fake.requests.items.len);
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "cannot read the credential_source file") != null);
}

test "ExternalAccount: a subject document without the named field is not retried" {
    var h: Harness = undefined;
    try h.init(&.{.{ .respond = .{ .body = "{\"wrong_field\":\"x\"}" } }}, .{ .source =
        \\{"url": "http://127.0.0.1:1/t", "format": {"type": "json", "subject_token_field_name": "access_token"}}
    });
    defer h.deinit();
    try testing.expectError(error.InvalidTokenResponse, h.get());
    try testing.expectEqual(1, h.fake.requests.items.len);
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "access_token") != null);
}

test "ExternalAccount: init refuses what cannot work, and says why" {
    const io = testing.io;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diag: Diagnostics = .{};

    try testing.expectError(error.UnsupportedCredentialType, ExternalAccount.initFromJson(
        testing.allocator,
        io,
        "{\"type\":\"authorized_user\",\"client_id\":\"c\",\"client_secret\":\"s\",\"refresh_token\":\"r\"}",
        .{ .diagnostics = &diag },
    ));
    try testing.expect(std.mem.indexOf(u8, diag.message(), "AuthorizedUser") != null);

    const good = try credJson(a, "{\"file\": \"/token\"}", false);
    try testing.expectError(error.InvalidOptions, ExternalAccount.initFromJson(testing.allocator, io, good, .{
        .token_url = "http://sts.elsewhere.example/token",
        .diagnostics = &diag,
    }));

    // Endpoints from the file that would carry secrets in the clear.
    const bad_sts = try std.fmt.allocPrint(a, "{{\"type\":\"external_account\",\"audience\":\"{s}\",\"subject_token_type\":\"t\",\"token_url\":\"http://elsewhere.example/token\",\"credential_source\":{{\"file\":\"/t\"}}}}", .{test_audience});
    try testing.expectError(error.InvalidCredentialsFile, ExternalAccount.initFromJson(testing.allocator, io, bad_sts, .{ .diagnostics = &diag }));
    try testing.expect(std.mem.indexOf(u8, diag.message(), "token_url") != null);

    const bad_lifetime = try std.fmt.allocPrint(a, "{{\"type\":\"external_account\",\"audience\":\"{s}\",\"subject_token_type\":\"t\",\"credential_source\":{{\"file\":\"/t\"}},\"service_account_impersonation\":{{\"token_lifetime_seconds\":100}}}}", .{test_audience});
    try testing.expectError(error.InvalidCredentialsFile, ExternalAccount.initFromJson(testing.allocator, io, bad_lifetime, .{ .diagnostics = &diag }));
    try testing.expect(std.mem.indexOf(u8, diag.message(), "token_lifetime_seconds") != null);

    const bad_source = try credJson(a, "{\"url\": \"ftp://host/t\"}", false);
    try testing.expectError(error.InvalidCredentialsFile, ExternalAccount.initFromJson(testing.allocator, io, bad_source, .{ .diagnostics = &diag }));
    try testing.expect(std.mem.indexOf(u8, diag.message(), "http or https") != null);

    // The kinds adc_file refuses arrive here with their own messages.
    const aws = try credJson(a, "{\"environment_id\": \"aws1\", \"url\": \"u\"}", false);
    try testing.expectError(error.UnsupportedCredentialType, ExternalAccount.initFromJson(testing.allocator, io, aws, .{ .diagnostics = &diag }));
    try testing.expect(std.mem.indexOf(u8, diag.message(), "AWS") != null);
}

test "ExternalAccount: the first call's scopes stick" {
    var h: Harness = undefined;
    try h.init(&.{sts_ok}, .{});
    defer h.deinit();
    _ = try h.get();
    const other: []const []const u8 = &.{"https://www.googleapis.com/auth/devstorage.read_only"};
    try testing.expectError(error.TokenUnavailable, h.account.provider().getToken(testing.io, h.arena.allocator(), other));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "scoped") != null);
}

test "ExternalAccount: secrets reach neither the log nor Diagnostics" {
    logging.capture.reset();
    var h: Harness = undefined;
    try h.init(&.{
        sts_ok,
        unavailable,
        unavailable,
    }, .{ .subject = "SECRET-subject-9f2e" });
    defer h.deinit();
    _ = try h.get();
    h.account.provider().invalidate();
    try testing.expectError(error.TokenUnavailable, h.get());
    const log = logging.capture.text();
    try testing.expect(logging.capture.lines > 0);
    for ([_][]const u8{ "SECRET-subject-9f2e", "ya29.STS-SECRET" }) |secret| {
        try testing.expect(std.mem.indexOf(u8, log, secret) == null);
        try testing.expect(std.mem.indexOf(u8, h.diag.message(), secret) == null);
    }
}

test "ExternalAccount: every block it frees is wiped first" {
    var checker: test_util.WipeChecker = .{ .child = testing.allocator };
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "subject", .data = "wipe-subject" });
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const with_headers = try std.fmt.allocPrint(arena.allocator(),
        \\{{"url": "http://127.0.0.1:1/t", "headers": {{"Metadata": "True"}}}}
    , .{});
    var fake: test_util.FakeTransport = .init(testing.allocator, &.{
        .{ .respond = .{ .body = "sub-token" } },
        sts_ok,
        sts_ok,
    });
    defer fake.deinit();
    var account: ExternalAccount = try .initFromJson(checker.allocator(), testing.io, try credJson(arena.allocator(), with_headers, false), .{
        .transport = fake.transport(),
    });
    _ = try account.provider().getToken(testing.io, arena.allocator(), test_scopes);
    account.deinit();
    try testing.expect(checker.frees >= 8);
    try testing.expectEqual(0, checker.unwiped);
}

test "ExternalAccount: every allocation failure is OutOfMemory without leaks" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "subject", .data = "alloc-subject" });
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const source = try std.fmt.allocPrint(arena.allocator(), "{{\"file\": \".zig-cache/tmp/{s}/subject\"}}", .{&tmp.sub_path});
    const json = try credJson(arena.allocator(), source, false);
    const Run = struct {
        fn get(gpa: Allocator, cred: []const u8) !void {
            var fake: test_util.FakeTransport = .init(testing.allocator, &.{sts_ok});
            defer fake.deinit();
            var scratch: std.heap.ArenaAllocator = .init(gpa);
            defer scratch.deinit();
            var account: ExternalAccount = try .initFromJson(gpa, testing.io, cred, .{ .transport = fake.transport() });
            defer account.deinit();
            _ = try account.provider().getToken(testing.io, scratch.allocator(), test_scopes);
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Run.get, .{json});
}

test "ExternalAccount: against an STS on loopback" {
    const io = testing.io;
    var server: test_util.ScriptedServer = try .start(io, &.{
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 61\r\n\r\n{\"access_token\":\"ya29.loopback\",\"expires_in\":3599,\"x\":\"look\"}",
    });
    defer server.deinit(io);
    var serving = try io.concurrent(test_util.ScriptedServer.run, .{ &server, io });
    defer _ = serving.cancel(io) catch {};

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "subject", .data = "loopback-subject\n" });
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const source = try std.fmt.allocPrint(arena.allocator(), "{{\"file\": \".zig-cache/tmp/{s}/subject\"}}", .{&tmp.sub_path});
    var url_buf: [64]u8 = undefined;
    var account: ExternalAccount = try .initFromJson(testing.allocator, io, try credJson(arena.allocator(), source, false), .{
        .token_url = server.url(&url_buf, "/v1/token"),
    });
    defer account.deinit();
    try testing.expectEqualStrings("ya29.loopback", try account.provider().getToken(io, arena.allocator(), test_scopes));
    try serving.await(io);

    const post = server.request(0);
    try testing.expect(std.mem.startsWith(u8, post, "POST /v1/token HTTP/1.1\r\n"));
    try testing.expect(std.mem.indexOf(u8, post, "content-type: application/x-www-form-urlencoded\r\n") != null);
    // The file's trailing newline was trimmed before the trade.
    try testing.expect(std.mem.endsWith(u8, post, "&subject_token=loopback-subject"));
}

fn anyStsReplyProperty(_: void, input: []const u8) !void {
    var g: test_util.ByteGen = .init(input);
    const status = g.pick(u16, &.{ 200, 200, 400, 403, 429, 500, 503, 302, 0 });
    const reply: Reply = .{ .respond = .{ .status = status, .body = g.rest() } };
    var h: Harness = undefined;
    try h.init(&(.{reply} ** 2), .{});
    defer h.deinit();
    const token = h.get() catch return;
    try testing.expect(TokenProvider.isValidToken(token));
}

test "fuzz ExternalAccount: any STS reply yields a token or an error" {
    try test_util.fuzzBytes({}, anyStsReplyProperty, .{
        .corpus = &.{
            "\x00\x00\x00\x00\x00\x00\x00\x00{\"access_token\":\"ya29.x\",\"expires_in\":3599}",
            "\x00\x00\x00\x00\x00\x00\x00\x02{\"error\":\"invalid_grant\"}",
            "\x00\x00\x00\x00\x00\x00\x00\x06",
        },
        // Every run builds a tmp dir and real files.
        .random_runs = 40,
    });
}

fn anySubjectDocumentProperty(_: void, input: []const u8) !void {
    // Whatever the url source answers, a token goes out or an error comes
    // back, and nothing crashes or leaks.
    var h: Harness = undefined;
    try h.init(&.{ .{ .respond = .{ .body = input } }, sts_ok }, .{ .source =
        \\{"url": "http://127.0.0.1:1/t", "format": {"type": "json", "subject_token_field_name": "token"}}
    });
    defer h.deinit();
    _ = h.get() catch return;
}

test "fuzz ExternalAccount: any subject document never crashes" {
    try test_util.fuzzBytes({}, anySubjectDocumentProperty, .{
        .corpus = &.{
            "{\"token\":\"ok\"}",
            "{\"token\":42}",
            "{\"token\":\"two words\"}",
            "not json",
            "",
        },
        .random_runs = 40,
    });
}
