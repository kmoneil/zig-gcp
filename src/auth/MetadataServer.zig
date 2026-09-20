//! Tokens for the service account attached to a workload on Google Cloud.
//! Cloud Run, GKE, GCE and Cloud Functions all answer on a link-local
//! metadata server, which hands out access tokens for the attached account.
//! No key file is involved, so nothing has to be stored or rotated.
//!
//! The traffic is plain HTTP by design: the address never leaves the host.
//! Two rules keep another local service from impersonating it: every request
//! carries `Metadata-Flavor: Google`, which a browser cannot be tricked into
//! sending, and every answer must carry the same header back. Redirects are
//! refused rather than followed.

const MetadataServer = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("core");
const TokenProvider = core.TokenProvider;
const Diagnostics = core.Diagnostics;
const HttpTransport = core.transport.HttpTransport;
const Transport = core.transport.Transport;
const Response = core.transport.Response;
const Cache = @import("Cache.zig");
const logging = @import("logging.zig");
const token_response = @import("token_response.zig");

gpa: Allocator,
/// All built once from the options, all owned.
token_url: []u8,
project_url: []u8,
root_url: []u8,
user_agent: []u8,
probe_timeout_ms: u32,
request_timeout_ms: u32,
retry: core.RetryPolicy,
diagnostics: ?*Diagnostics,
cache: Cache,
transport: Transport,
/// The built-in transport, when `Options.transport` was null.
http: ?*HttpTransport,

pub const Options = struct {
    /// The metadata host, with an optional `:port`. `GCE_METADATA_HOST`
    /// names it in some environments, and `169.254.169.254` is the address
    /// behind the name, for hosts whose DNS does not resolve it.
    host: []const u8 = "metadata.google.internal",
    /// Which of the workload's service accounts to ask for. `default` is
    /// the attached one.
    service_account: []const u8 = "default",
    /// How long `probe` waits for an answer. A laptop must not stall on a
    /// name that resolves to a black hole.
    probe_timeout_ms: u32 = 500,
    /// A token fetch sits in front of every API call, so it gives up sooner
    /// than an API call would.
    retry: core.RetryPolicy = .{ .max_attempts = 3 },
    cache: Cache.Options = .{},
    /// How long one request may take before it is `error.TimedOut`. The
    /// metadata server is on this machine's own network, so a request that
    /// takes seconds is already wrong. 0 removes the limit.
    request_timeout_ms: u32 = 10_000,
    /// Printable ASCII.
    user_agent: []const u8 = "zig-gcp-auth/0.6",
    /// Filled with the details of the last failure. Never holds a token.
    diagnostics: ?*Diagnostics = null,
    /// Sends requests through this instead of `std.http.Client`.
    transport: ?Transport = null,
};

pub const InitError = error{
    /// A host, service account, user agent, retry policy or cache setting
    /// the metadata server could never be asked with.
    InvalidOptions,
    OutOfMemory,
};

/// What every request to the metadata server can fail with.
pub const Error = error{
    /// Nothing answered, the answer was not the metadata server's, or no
    /// service account is attached to this workload.
    MetadataUnavailable,
    /// The server stayed busy or broken for every attempt.
    TokenUnavailable,
    /// The metadata server refused the request.
    TokenEndpointRejected,
} || core.transport.Error;

/// `projectId` either reads the project or finds no metadata server; the
/// token errors above cannot come from it.
pub const ProjectIdError = error{MetadataUnavailable} || core.transport.Error;

/// What a probe can report instead of an answer. Everything else, from a
/// refused connection to a reply from something that is not a metadata
/// server, is the answer "no".
pub const ProbeError = error{ OutOfMemory, Canceled };

/// Required on every request. Without it the metadata server answers 403,
/// which is what keeps a browser or a confused service from reaching it.
const request_headers: []const core.transport.Header = &.{
    .{ .name = "Metadata-Flavor", .value = "Google" },
};

/// The metadata server's answers are small. A local service pretending to
/// be one does not get to hand this client 32 MiB.
const max_response_bytes = 64 * 1024;

pub fn init(gpa: Allocator, io: std.Io, options: Options) InitError!MetadataServer {
    const diag = options.diagnostics;
    if (diag) |d| d.clear();
    if (!isValidHost(options.host)) {
        if (diag) |d| d.print("invalid metadata host: expected a host with an optional port, such as 169.254.169.254", .{});
        return error.InvalidOptions;
    }
    if (!isValidServiceAccount(options.service_account)) {
        if (diag) |d| d.print("invalid service account: expected a name or an email address", .{});
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

    const token_url = try allocUrl(gpa, "http://{s}/computeMetadata/v1/instance/service-accounts/{s}/token", .{
        options.host, options.service_account,
    });
    errdefer wipeFree(gpa, token_url);
    const project_url = try allocUrl(gpa, "http://{s}/computeMetadata/v1/project/project-id", .{options.host});
    errdefer wipeFree(gpa, project_url);
    const root_url = try allocUrl(gpa, "http://{s}/", .{options.host});
    errdefer wipeFree(gpa, root_url);
    const user_agent = try gpa.dupe(u8, options.user_agent);
    errdefer wipeFree(gpa, user_agent);

    var http: ?*HttpTransport = null;
    const transport = options.transport orelse t: {
        const h = try gpa.create(HttpTransport);
        h.* = .init(gpa, io, user_agent);
        h.max_response_bytes = max_response_bytes;
        http = h;
        break :t h.transport();
    };
    return .{
        .gpa = gpa,
        .token_url = token_url,
        .project_url = project_url,
        .root_url = root_url,
        .user_agent = user_agent,
        .probe_timeout_ms = options.probe_timeout_ms,
        .request_timeout_ms = options.request_timeout_ms,
        .retry = options.retry,
        .diagnostics = diag,
        .cache = cache,
        .transport = transport,
        .http = http,
    };
}

/// Wipes the cached access token.
pub fn deinit(self: *MetadataServer) void {
    self.cache.deinit();
    if (self.http) |h| {
        h.deinit();
        self.gpa.destroy(h);
    }
    wipeFree(self.gpa, self.token_url);
    wipeFree(self.gpa, self.project_url);
    wipeFree(self.gpa, self.root_url);
    wipeFree(self.gpa, self.user_agent);
    self.* = undefined;
}

/// The provider points at this struct, which must not move while the
/// provider is in use.
pub fn provider(self: *MetadataServer) TokenProvider {
    return .{ .ptr = self, .vtable = &.{
        .getToken = getToken,
        .invalidate = invalidate,
        .quotaProject = quotaProject,
    } };
}

/// True when a metadata server answers within `probe_timeout_ms`. This is
/// the question "am I running on Google Cloud?", and the answer is trusted
/// only because of the response header. Anything that is not an answer,
/// including running out of memory, counts as "no".
pub fn probe(self: *MetadataServer, io: std.Io) bool {
    return self.probeChecked(io) catch false;
}

/// `probe`, keeping apart the two failures that are not answers about
/// Google Cloud. A caller choosing between credentials needs them: neither
/// means "there is no metadata server here".
pub fn probeChecked(self: *MetadataServer, io: std.Io) ProbeError!bool {
    const Winner = union(enum) { probe: ProbeError!bool, timer: void };
    var slots: [2]Winner = undefined;
    var race: std.Io.Select(Winner) = .init(io, &slots);
    // The probe runs elsewhere, so a server that accepts the connection and
    // then says nothing cannot hang this task. Without a second thread
    // there is no timeout to be had, and the probe runs here instead.
    race.concurrent(.probe, probeOnce, .{self}) catch return self.probeOnce();
    defer race.cancelDiscard();
    // A failed timer leaves the probe to finish on its own.
    race.concurrent(.timer, expire, .{ io, self.probe_timeout_ms }) catch {};
    return switch (race.await() catch |err| return err) {
        .probe => |answered| answered,
        .timer => {
            logging.debug("no metadata server answered on {s} within {d} ms", .{ self.root_url, self.probe_timeout_ms });
            return false;
        },
    };
}

/// The project this workload runs in, copied into `arena`. It saves a
/// caller on Google Cloud from naming its own project.
pub fn projectId(self: *MetadataServer, io: std.Io, arena: Allocator) ProjectIdError![]const u8 {
    const res = self.getRetrying(io, arena, self.project_url) catch |err| switch (err) {
        // Any refusal means no metadata server this code can use.
        error.TokenUnavailable, error.TokenEndpointRejected => return error.MetadataUnavailable,
        else => |e| return e,
    };
    // Plain text, and short. Anything else did not come from the project
    // endpoint, whatever the headers claimed.
    const id = std.mem.trim(u8, res.body, " \t\r\n");
    if (!isProjectId(id)) {
        if (self.diagnostics) |d| d.set(res.status, "", "the metadata server's project id is not one");
        return error.MetadataUnavailable;
    }
    logging.debug("metadata server: project {s}", .{id});
    return arena.dupe(u8, id);
}

fn fromPtr(ptr: *anyopaque) *MetadataServer {
    return @ptrCast(@alignCast(ptr));
}

fn getToken(ptr: *anyopaque, io: std.Io, arena: Allocator, scopes: []const []const u8) TokenProvider.Error![]const u8 {
    // The workload's configuration fixes the scopes; asking cannot widen them.
    _ = scopes;
    const self = fromPtr(ptr);
    return self.cache.getToken(io, arena, .{ .ptr = self, .fetchFn = fetch });
}

fn invalidate(ptr: *anyopaque) void {
    fromPtr(ptr).cache.invalidate();
}

fn quotaProject(ptr: *anyopaque) ?[]const u8 {
    // A service account bills its own project; there is nothing to send.
    _ = ptr;
    return null;
}

/// Asks the metadata server for the attached account's token. `arena` is
/// the cache's scratch memory, which it wipes.
fn fetch(ptr: *anyopaque, io: std.Io, arena: Allocator) TokenProvider.Error!Cache.Fetched {
    const self = fromPtr(ptr);
    const res = try self.getRetrying(io, arena, self.token_url);
    return token_response.parse(arena, res.body) catch |err| {
        if (err == error.InvalidTokenResponse) {
            if (self.diagnostics) |d| d.set(res.status, "", "the metadata server's answer has no usable access_token and expires_in");
        }
        return err;
    };
}

/// One GET, retried while the answer says "later".
fn getRetrying(self: *MetadataServer, io: std.Io, arena: Allocator, url: []const u8) Error!Response {
    const max_attempts = self.retry.max_attempts;
    var attempt: u32 = 1;
    while (true) : (attempt += 1) {
        const started = std.Io.Clock.awake.now(io);
        const result = self.get(arena, url);
        const elapsed_ms = started.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds();
        switch (result) {
            .ok => |res| {
                logging.debug("GET {s} -> {d} in {d} ms (attempt {d} of {d})", .{ url, res.status, elapsed_ms, attempt, max_attempts });
                return res;
            },
            .fail => |err| {
                logging.debug("GET {s} -> {t} in {d} ms (attempt {d} of {d})", .{ url, err, elapsed_ms, attempt, max_attempts });
                return err;
            },
            .retry => |err| {
                logging.debug("GET {s} -> {t} in {d} ms (attempt {d} of {d})", .{ url, err, elapsed_ms, attempt, max_attempts });
                if (attempt >= max_attempts) return err;
                const delay_ms = self.retry.backoffMs(attempt, entropy(io));
                logging.warn("the metadata server failed with {t}; retrying in {d} ms (attempt {d} of {d})", .{
                    err, delay_ms, attempt + 1, max_attempts,
                });
                try io.sleep(.fromMilliseconds(delay_ms), .awake);
            },
        }
    }
}

const Attempt = union(enum) {
    ok: Response,
    /// Worth another attempt.
    retry: Error,
    fail: Error,
};

/// One GET, and what to make of the answer. The body is never copied into
/// `Diagnostics`: the metadata server answers in plain text, and whatever
/// answered may not be the metadata server at all.
fn get(self: *MetadataServer, arena: Allocator, url: []const u8) Attempt {
    const res = self.transport.send(.{
        .method = .GET,
        .url = url,
        .headers = request_headers,
        .timeout_ms = self.request_timeout_ms,
    }, arena) catch |err| {
        if (self.diagnostics) |d| d.print("the metadata server could not be reached: {t}", .{err});
        return if (core.isRetryable(err)) .{ .retry = err } else .{ .fail = err };
    };
    if (!isFromMetadataServer(res)) {
        if (self.diagnostics) |d| d.set(res.status, "", "the answer carries no Metadata-Flavor header, so it is not the metadata server's");
        return .{ .fail = error.MetadataUnavailable };
    }
    if (res.status == 200) return .{ .ok = res };
    if (res.status == 404) {
        if (self.diagnostics) |d| d.set(res.status, "", "no service account is attached to this workload");
        return .{ .fail = error.MetadataUnavailable };
    }
    if (res.status >= 300 and res.status < 400) {
        if (self.diagnostics) |d| d.set(res.status, "", "the metadata server answered with a redirect, which is never followed");
        return .{ .fail = error.MetadataUnavailable };
    }
    if (res.status == 429 or res.status >= 500) {
        if (self.diagnostics) |d| d.set(res.status, "", "the metadata server is busy or broken");
        return .{ .retry = error.TokenUnavailable };
    }
    if (self.diagnostics) |d| d.set(res.status, "", "the metadata server refused the request");
    return .{ .fail = error.TokenEndpointRejected };
}

/// One probe request. Every failure but the two above answers "no
/// metadata server here".
fn probeOnce(self: *MetadataServer) ProbeError!bool {
    var arena: std.heap.ArenaAllocator = .init(self.gpa);
    defer arena.deinit();
    const res = self.transport.send(.{
        .method = .GET,
        .url = self.root_url,
        .headers = request_headers,
        // The race in `probeChecked` is this request's real limit.
        .timeout_ms = self.probe_timeout_ms,
    }, arena.allocator()) catch |err| switch (err) {
        // Neither says anything about where this code is running.
        error.OutOfMemory, error.Canceled => |e| return e,
        else => {
            logging.debug("metadata probe on {s}: {t}", .{ self.root_url, err });
            return false;
        },
    };
    const answered = res.status == 200 and isFromMetadataServer(res);
    logging.debug("metadata probe on {s}: {d}, {s}", .{ self.root_url, res.status, if (answered) "on Google Cloud" else "not the metadata server" });
    return answered;
}

fn expire(io: std.Io, ms: u32) void {
    io.sleep(.fromMilliseconds(ms), .awake) catch {};
}

/// The answer must carry `Metadata-Flavor: Google` too. Another service
/// listening on the metadata address cannot pass for the real one without
/// deliberately claiming to be it.
fn isFromMetadataServer(res: Response) bool {
    const value = res.header("Metadata-Flavor") orelse return false;
    return std.ascii.eqlIgnoreCase(std.mem.trim(u8, value, " \t"), "Google");
}

/// A host, with an optional `:port`, that can go into a URL as it stands.
fn isValidHost(host: []const u8) bool {
    if (host.len == 0 or host.len > 255) return false;
    for (host) |c| switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '.', ':' => {},
        else => return false,
    };
    // A leading or trailing separator would build a URL with an empty host.
    return host[0] != ':' and host[0] != '.' and host[host.len - 1] != ':';
}

/// `default`, or a service account email address.
fn isValidServiceAccount(name: []const u8) bool {
    if (name.len == 0 or name.len > 255) return false;
    for (name) |c| switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '@' => {},
        else => return false,
    };
    return true;
}

/// Project ids and numbers, including legacy domain-scoped ids such as
/// `example.com:my-project`.
fn isProjectId(id: []const u8) bool {
    if (id.len == 0 or id.len > 100) return false;
    for (id) |c| switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '.', ':', '_' => {},
        else => return false,
    };
    return true;
}

fn isPrintable(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text) |c| if (c < ' ' or c >= 0x7f) return false;
    return true;
}

/// One URL, in an allocation of exactly its size: a growing buffer would
/// hand back the copies it outgrew without wiping them.
fn allocUrl(gpa: Allocator, comptime fmt: []const u8, args: anytype) Allocator.Error![]u8 {
    const buf = try gpa.alloc(u8, std.fmt.count(fmt, args));
    return std.fmt.bufPrint(buf, fmt, args) catch unreachable;
}

/// Wipes `buf` and frees it with `rawFree`, so the wipe is the last write.
/// None of what this type owns is secret, but one rule for the whole type
/// is easier to keep than an exception.
fn wipeFree(gpa: Allocator, buf: []u8) void {
    if (buf.len == 0) return;
    std.crypto.secureZero(u8, buf);
    gpa.rawFree(buf, .of(u8), @returnAddress());
}

fn entropy(io: std.Io) u64 {
    var bytes: [8]u8 = undefined;
    io.random(&bytes);
    return std.mem.readInt(u64, &bytes, .little);
}

const testing = std.testing;
const test_util = core.testing;
const Reply = test_util.FakeTransport.Reply;
const ScriptedServer = test_util.ScriptedServer;

const flavor: []const core.transport.Header = &.{.{ .name = "Metadata-Flavor", .value = "Google" }};
const token_ok: Reply = .{ .respond = .{
    .body = "{\"access_token\":\"ya29.SECRET-metadata\",\"expires_in\":3599,\"token_type\":\"Bearer\"}",
    .headers = flavor,
} };
const busy: Reply = .{ .respond = .{ .status = 503, .body = "Service Unavailable", .headers = flavor } };
const metadata_listing: Reply = .{ .respond = .{ .body = "computeMetadata/\n", .headers = flavor } };
const test_scopes: []const []const u8 = &.{"https://www.googleapis.com/auth/cloud-platform"};

/// A `MetadataServer` wired to a fake transport and a fake clock.
const Harness = struct {
    fake: test_util.FakeTransport,
    clock: test_util.FakeClock,
    diag: Diagnostics,
    arena: std.heap.ArenaAllocator,
    metadata: MetadataServer,

    /// Initializes in place: the provider points into the harness.
    fn init(h: *Harness, script: []const Reply) !void {
        h.* = .{
            .fake = .init(testing.allocator, script),
            .clock = .{},
            .diag = .{},
            .arena = .init(testing.allocator),
            .metadata = undefined,
        };
        errdefer h.fake.deinit();
        errdefer h.arena.deinit();
        h.metadata = try .init(testing.allocator, h.clock.io(), .{
            .diagnostics = &h.diag,
            .transport = h.fake.transport(),
        });
    }

    fn deinit(h: *Harness) void {
        h.metadata.deinit();
        h.arena.deinit();
        h.fake.deinit();
    }

    fn get(h: *Harness) TokenProvider.Error![]const u8 {
        return h.metadata.provider().getToken(h.clock.io(), h.arena.allocator(), test_scopes);
    }
};

test "MetadataServer: the token request carries Metadata-Flavor and no token of its own" {
    var h: Harness = undefined;
    try h.init(&.{token_ok});
    defer h.deinit();
    try testing.expectEqualStrings("ya29.SECRET-metadata", try h.get());

    const req = try h.fake.request(0);
    try testing.expectEqual(.GET, req.method);
    try testing.expectEqualStrings(
        "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token",
        req.url,
    );
    try testing.expectEqualStrings("Google", req.header("metadata-flavor").?);
    try testing.expectEqual(null, req.bearer);
    try testing.expectEqual(null, req.body);
    // A service account bills its own project.
    try testing.expectEqual(null, h.metadata.provider().quotaProject());
}

test "MetadataServer: requests carry a deadline, and the probe a shorter one" {
    var h: Harness = undefined;
    try h.init(&.{ token_ok, metadata_listing });
    defer h.deinit();
    _ = try h.get();
    // The metadata server is on this machine's own network.
    try testing.expectEqual(10_000, (try h.fake.request(0)).timeout_ms);
    // The probe answers "is this Google Cloud?", so it gives up sooner.
    try testing.expect(h.metadata.probe(h.clock.io()));
    try testing.expectEqual(500, (try h.fake.request(1)).timeout_ms);
}

test "MetadataServer: an answer without Metadata-Flavor is not the metadata server's" {
    // Some other service on this host, answering with a token of its own.
    var h: Harness = undefined;
    try h.init(&.{.{ .respond = .{ .body = "{\"access_token\":\"ya29.imposter\",\"expires_in\":3599}" } }});
    defer h.deinit();
    try testing.expectError(error.MetadataUnavailable, h.get());
    // Not retried: the answer was prompt, it was just not the right server.
    try testing.expectEqual(1, h.fake.requests.items.len);
    try testing.expectEqualStrings(
        "the answer carries no Metadata-Flavor header, so it is not the metadata server's",
        h.diag.message(),
    );
}

test "MetadataServer: a wrong Metadata-Flavor value is refused, any case is accepted" {
    for ([_][]const core.transport.Header{
        &.{.{ .name = "Metadata-Flavor", .value = "Chrome" }},
        &.{.{ .name = "X-Metadata-Flavor", .value = "Google" }},
        &.{.{ .name = "Metadata-Flavor", .value = "" }},
    }) |headers| {
        var h: Harness = undefined;
        try h.init(&.{.{ .respond = .{ .body = "{\"access_token\":\"t\",\"expires_in\":1}", .headers = headers } }});
        defer h.deinit();
        try testing.expectError(error.MetadataUnavailable, h.get());
    }
    var h: Harness = undefined;
    try h.init(&.{.{ .respond = .{
        .body = "{\"access_token\":\"ya29.ok\",\"expires_in\":3599}",
        .headers = &.{.{ .name = "metadata-flavor", .value = "google" }},
    } }});
    defer h.deinit();
    try testing.expectEqualStrings("ya29.ok", try h.get());
}

test "MetadataServer: 404 means no service account is attached" {
    var h: Harness = undefined;
    try h.init(&.{.{ .respond = .{ .status = 404, .body = "Not Found", .headers = flavor } }});
    defer h.deinit();
    try testing.expectError(error.MetadataUnavailable, h.get());
    try testing.expectEqual(1, h.fake.requests.items.len);
    try testing.expectEqual(404, h.diag.http_status);
    try testing.expectEqualStrings("no service account is attached to this workload", h.diag.message());
}

test "MetadataServer: a redirect is refused, not followed" {
    var h: Harness = undefined;
    try h.init(&.{.{ .respond = .{
        .status = 302,
        .body = "",
        .headers = &.{ .{ .name = "Metadata-Flavor", .value = "Google" }, .{ .name = "Location", .value = "http://evil.example/" } },
    } }});
    defer h.deinit();
    try testing.expectError(error.MetadataUnavailable, h.get());
    try testing.expectEqual(1, h.fake.requests.items.len);
    try testing.expectEqualStrings("the metadata server answered with a redirect, which is never followed", h.diag.message());
}

test "MetadataServer: a busy server is retried, then TokenUnavailable" {
    var h: Harness = undefined;
    try h.init(&.{ busy, .{ .respond = .{ .status = 429, .body = "", .headers = flavor } }, token_ok });
    defer h.deinit();
    try testing.expectEqualStrings("ya29.SECRET-metadata", try h.get());
    try testing.expectEqual(3, h.fake.requests.items.len);
    try testing.expectEqual(2, h.clock.sleep_count);

    var gone: Harness = undefined;
    try gone.init(&.{ busy, busy, busy });
    defer gone.deinit();
    try testing.expectError(error.TokenUnavailable, gone.get());
    try testing.expectEqual(3, gone.fake.requests.items.len);
    try testing.expectEqualStrings("the metadata server is busy or broken", gone.diag.message());
}

test "MetadataServer: another refusal is TokenEndpointRejected, not retried" {
    var h: Harness = undefined;
    try h.init(&.{.{ .respond = .{ .status = 403, .body = "Forbidden", .headers = flavor } }});
    defer h.deinit();
    try testing.expectError(error.TokenEndpointRejected, h.get());
    try testing.expectEqual(1, h.fake.requests.items.len);
    try testing.expectEqualStrings("the metadata server refused the request", h.diag.message());
}

test "MetadataServer: an answer without a usable token is InvalidTokenResponse" {
    var h: Harness = undefined;
    try h.init(&.{.{ .respond = .{ .body = "<html>hello</html>", .headers = flavor } }});
    defer h.deinit();
    try testing.expectError(error.InvalidTokenResponse, h.get());
    try testing.expectEqualStrings("the metadata server's answer has no usable access_token and expires_in", h.diag.message());
}

test "MetadataServer: the token is kept until it goes stale, and invalidate refetches" {
    var h: Harness = undefined;
    try h.init(&.{ token_ok, token_ok, token_ok });
    defer h.deinit();
    _ = try h.get();
    _ = try h.get();
    try testing.expectEqual(1, h.fake.requests.items.len);
    // Still fresh a minute later; stale once the refresh margin is reached.
    h.clock.now_ns += 60 * std.time.ns_per_s;
    _ = try h.get();
    try testing.expectEqual(1, h.fake.requests.items.len);
    h.clock.now_ns += 3400 * std.time.ns_per_s;
    _ = try h.get();
    try testing.expectEqual(2, h.fake.requests.items.len);
    // And on demand, after a 401 from an API.
    h.metadata.provider().invalidate();
    _ = try h.get();
    try testing.expectEqual(3, h.fake.requests.items.len);
}

test "MetadataServer: projectId reads the project id, and refuses what is not one" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = "my-project-123\n", .headers = flavor } },
        .{ .respond = .{ .body = "<html>not a project</html>", .headers = flavor } },
        .{ .respond = .{ .status = 404, .body = "Not Found", .headers = flavor } },
        .{ .respond = .{ .status = 403, .body = "Forbidden", .headers = flavor } },
    });
    defer h.deinit();
    const a = h.arena.allocator();
    const io = h.clock.io();
    // A trailing newline is not part of the id.
    try testing.expectEqualStrings("my-project-123", try h.metadata.projectId(io, a));
    try testing.expectEqualStrings(
        "http://metadata.google.internal/computeMetadata/v1/project/project-id",
        (try h.fake.request(0)).url,
    );
    try testing.expectError(error.MetadataUnavailable, h.metadata.projectId(io, a));
    try testing.expectEqualStrings("the metadata server's project id is not one", h.diag.message());
    try testing.expectError(error.MetadataUnavailable, h.metadata.projectId(io, a));
    // Even a refusal is only ever "no metadata server to read this from".
    try testing.expectError(error.MetadataUnavailable, h.metadata.projectId(io, a));
}

test "MetadataServer: probe answers only for a metadata server" {
    const listing: Reply = .{ .respond = .{ .body = "computeMetadata/\n", .headers = flavor } };
    var h: Harness = undefined;
    try h.init(&.{
        listing,
        .{ .respond = .{ .body = "hello from some other service", .headers = &.{} } },
        .{ .fail = error.ConnectionRefused },
        .{ .respond = .{ .status = 500, .body = "", .headers = flavor } },
    });
    defer h.deinit();
    try testing.expect(h.metadata.probe(h.clock.io()));
    try testing.expectEqualStrings("http://metadata.google.internal/", (try h.fake.request(0)).url);
    try testing.expectEqualStrings("Google", (try h.fake.request(0)).header("Metadata-Flavor").?);
    // Another service, no server at all, and a broken one: all "not here".
    try testing.expect(!h.metadata.probe(h.clock.io()));
    try testing.expect(!h.metadata.probe(h.clock.io()));
    try testing.expect(!h.metadata.probe(h.clock.io()));
}

test "MetadataServer: the probe keeps running out of memory apart from a no" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .fail = error.OutOfMemory },
        .{ .fail = error.Canceled },
        .{ .fail = error.ConnectionRefused },
        .{ .fail = error.OutOfMemory },
    });
    defer h.deinit();
    const io = h.clock.io();
    // Neither says anything about whether this is Google Cloud.
    try testing.expectError(error.OutOfMemory, h.metadata.probeChecked(io));
    try testing.expectError(error.Canceled, h.metadata.probeChecked(io));
    // A refused connection is an answer, and it is "no".
    try testing.expect(!try h.metadata.probeChecked(io));
    // The bool form still answers, because a caller asked for a bool.
    try testing.expect(!h.metadata.probe(io));
}

test "MetadataServer: init refuses what it could never ask with" {
    const io = testing.io;
    for ([_][]const u8{
        "",
        "metadata.google.internal/../evil",
        "http://metadata.google.internal",
        "metadata.google.internal:",
        ":8080",
        ".internal",
        "metadata google internal",
        "metadata\r\nX-Injected: 1",
        "[::1]",
    }) |host| {
        var diag: Diagnostics = .{};
        try testing.expectError(error.InvalidOptions, MetadataServer.init(testing.allocator, io, .{
            .host = host,
            .diagnostics = &diag,
        }));
        try testing.expect(std.mem.startsWith(u8, diag.message(), "invalid metadata host"));
    }
    try testing.expectError(error.InvalidOptions, MetadataServer.init(testing.allocator, io, .{ .service_account = "a/../b" }));
    try testing.expectError(error.InvalidOptions, MetadataServer.init(testing.allocator, io, .{ .retry = .{ .max_attempts = 0 } }));
    try testing.expectError(error.InvalidOptions, MetadataServer.init(testing.allocator, io, .{ .cache = .{ .refresh_margin_s = 300 } }));
    try testing.expectError(error.InvalidOptions, MetadataServer.init(testing.allocator, io, .{ .user_agent = "a\r\nX: y" }));
}

test "MetadataServer: a host with a port and another service account are asked as given" {
    var fake: test_util.FakeTransport = .init(testing.allocator, &.{token_ok});
    defer fake.deinit();
    var clock: test_util.FakeClock = .{};
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var metadata: MetadataServer = try .init(testing.allocator, clock.io(), .{
        .host = "169.254.169.254:8080",
        .service_account = "worker@my-project.iam.gserviceaccount.com",
        .transport = fake.transport(),
    });
    defer metadata.deinit();
    _ = try metadata.provider().getToken(clock.io(), arena.allocator(), test_scopes);
    try testing.expectEqualStrings(
        "http://169.254.169.254:8080/computeMetadata/v1/instance/service-accounts/worker@my-project.iam.gserviceaccount.com/token",
        (try fake.request(0)).url,
    );
}

test "MetadataServer: its own transport reads at most 64 KiB from the answer" {
    var metadata: MetadataServer = try .init(testing.allocator, testing.io, .{});
    defer metadata.deinit();
    // Whatever answers on the metadata address does not get to send 32 MiB.
    try testing.expectEqual(64 * 1024, metadata.http.?.max_response_bytes);
    try testing.expect(max_response_bytes < core.transport.default_max_response_bytes);
}

test "MetadataServer: the token reaches neither the log nor Diagnostics" {
    logging.capture.reset();
    var h: Harness = undefined;
    try h.init(&.{
        token_ok,
        .{ .respond = .{ .status = 500, .body = "echo: ya29.SECRET-metadata", .headers = flavor } },
        .{ .respond = .{ .status = 500, .body = "echo: ya29.SECRET-metadata", .headers = flavor } },
        .{ .respond = .{ .status = 500, .body = "echo: ya29.SECRET-metadata", .headers = flavor } },
        .{ .respond = .{ .status = 400, .body = "echo: ya29.SECRET-metadata", .headers = flavor } },
    });
    defer h.deinit();
    _ = try h.get();
    h.metadata.provider().invalidate();
    try testing.expectError(error.TokenUnavailable, h.get());
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "SECRET") == null);
    h.metadata.provider().invalidate();
    try testing.expectError(error.TokenEndpointRejected, h.get());
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "SECRET") == null);
    try testing.expect(std.mem.indexOf(u8, logging.capture.text(), "SECRET") == null);
    try testing.expect(logging.capture.lines > 0);
}

test "MetadataServer: every block it frees is wiped first" {
    var checker: test_util.WipeChecker = .{ .child = testing.allocator };
    var fake: test_util.FakeTransport = .init(testing.allocator, &.{ token_ok, token_ok });
    defer fake.deinit();
    var clock: test_util.FakeClock = .{};
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var metadata: MetadataServer = try .init(checker.allocator(), clock.io(), .{ .transport = fake.transport() });
    _ = try metadata.provider().getToken(clock.io(), arena.allocator(), test_scopes);
    metadata.provider().invalidate();
    _ = try metadata.provider().getToken(clock.io(), arena.allocator(), test_scopes);
    metadata.deinit();
    try testing.expect(checker.frees >= 4);
    try testing.expectEqual(0, checker.unwiped);
}

test "MetadataServer: every allocation failure is OutOfMemory without leaks" {
    const Run = struct {
        fn token(gpa: Allocator, reply: Reply) !void {
            var fake: test_util.FakeTransport = .init(testing.allocator, &.{reply});
            defer fake.deinit();
            var clock: test_util.FakeClock = .{};
            var arena: std.heap.ArenaAllocator = .init(gpa);
            defer arena.deinit();
            var metadata: MetadataServer = try .init(gpa, clock.io(), .{ .transport = fake.transport() });
            defer metadata.deinit();
            _ = try metadata.provider().getToken(clock.io(), arena.allocator(), test_scopes);
        }

        fn project(gpa: Allocator) !void {
            var fake: test_util.FakeTransport = .init(testing.allocator, &.{
                .{ .respond = .{ .body = "my-project-123", .headers = flavor } },
            });
            defer fake.deinit();
            var clock: test_util.FakeClock = .{};
            var arena: std.heap.ArenaAllocator = .init(gpa);
            defer arena.deinit();
            // With the built-in transport, which init allocates too.
            var metadata: MetadataServer = try .init(gpa, clock.io(), .{ .transport = fake.transport() });
            defer metadata.deinit();
            _ = try metadata.projectId(clock.io(), arena.allocator());
        }

        fn withOwnTransport(gpa: Allocator) !void {
            var metadata: MetadataServer = try .init(gpa, testing.io, .{});
            metadata.deinit();
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Run.token, .{token_ok});
    // Escapes make std.json allocate; without them it points into the body.
    try testing.checkAllAllocationFailures(testing.allocator, Run.token, .{Reply{ .respond = .{
        .body = "{\"access_token\":\"ya29.\\u0053ECRET\",\"expires_in\":3599}",
        .headers = flavor,
    } }});
    try testing.checkAllAllocationFailures(testing.allocator, Run.project, .{});
    try testing.checkAllAllocationFailures(testing.allocator, Run.withOwnTransport, .{});
}

test "MetadataServer: against a metadata server on loopback" {
    const io = testing.io;
    const reply = "HTTP/1.1 200 OK\r\nMetadata-Flavor: Google\r\nContent-Type: application/json\r\n" ++
        "Content-Length: 72\r\n\r\n" ++
        "{\"access_token\":\"ya29.loopback\",\"expires_in\":3599,\"token_type\":\"Bearer\"}";
    var server: ScriptedServer = try .start(io, &.{ reply, reply });
    defer server.deinit(io);
    server.per_connection = 2;
    var serving = try io.concurrent(ScriptedServer.run, .{ &server, io });
    defer _ = serving.cancel(io) catch {};

    var host_buf: [64]u8 = undefined;
    const host = try std.fmt.bufPrint(&host_buf, "127.0.0.1:{d}", .{server.port});
    var metadata: MetadataServer = try .init(testing.allocator, io, .{ .host = host });
    defer metadata.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    // Fetched once, then served from the cache, then fetched again.
    try testing.expectEqualStrings("ya29.loopback", try metadata.provider().getToken(io, arena.allocator(), test_scopes));
    try testing.expectEqualStrings("ya29.loopback", try metadata.provider().getToken(io, arena.allocator(), test_scopes));
    metadata.provider().invalidate();
    try testing.expectEqualStrings("ya29.loopback", try metadata.provider().getToken(io, arena.allocator(), test_scopes));
    try serving.await(io);

    const sent = server.request(0);
    try testing.expect(std.mem.startsWith(u8, sent, "GET /computeMetadata/v1/instance/service-accounts/default/token HTTP/1.1\r\n"));
    try testing.expect(std.mem.indexOf(u8, sent, "Metadata-Flavor: Google\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, sent, "authorization") == null);
    // Two fetches over one kept-alive connection.
    try testing.expectEqual(2, server.seen_count);
    try testing.expectEqual(1, server.connections);
}

test "MetadataServer: probe gives up on a server that never answers" {
    const io = testing.io;
    var server: ScriptedServer = try .start(io, &.{"HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"});
    defer server.deinit(io);
    server.hang = true;
    var serving = try io.concurrent(ScriptedServer.run, .{ &server, io });
    defer _ = serving.cancel(io) catch {};

    var host_buf: [64]u8 = undefined;
    const host = try std.fmt.bufPrint(&host_buf, "127.0.0.1:{d}", .{server.port});
    var metadata: MetadataServer = try .init(testing.allocator, io, .{ .host = host, .probe_timeout_ms = 150 });
    defer metadata.deinit();

    const started = std.Io.Clock.awake.now(io);
    try testing.expect(!metadata.probe(io));
    const elapsed_ms = started.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds();
    // It waited for the timeout, and not much longer.
    try testing.expect(elapsed_ms >= 150);
    try testing.expect(elapsed_ms < 5_000);
}

test "MetadataServer: probe says no when nothing listens" {
    const io = testing.io;
    var metadata: MetadataServer = try .init(testing.allocator, io, .{ .host = "127.0.0.1:1", .probe_timeout_ms = 500 });
    defer metadata.deinit();
    try testing.expect(!metadata.probe(io));
}

fn anyAnswerProperty(_: void, input: []const u8) !void {
    var g: test_util.ByteGen = .init(input);
    const status = g.pick(u16, &.{ 200, 200, 403, 404, 429, 500, 503, 302 });
    const headers: []const core.transport.Header = if (g.boolean()) flavor else &.{};
    const reply: Reply = .{ .respond = .{ .status = status, .body = g.rest(), .headers = headers } };
    var h: Harness = undefined;
    try h.init(&(.{reply} ** 3));
    defer h.deinit();
    // Whatever answers on the metadata address: a usable token or an error.
    const token = h.get() catch return;
    try testing.expect(TokenProvider.isValidToken(token));
}

test "fuzz MetadataServer: any answer yields a token or an error" {
    try test_util.fuzzBytes({}, anyAnswerProperty, .{ .corpus = &.{
        "\x00\x00\x00\x00\x00\x00\x00\x00\x01{\"access_token\":\"ya29.x\",\"expires_in\":3599}",
        "\x00\x00\x00\x00\x00\x00\x00\x00\x00{\"access_token\":\"ya29.x\",\"expires_in\":3599}",
        "\x00\x00\x00\x00\x00\x00\x00\x03\x01Not Found",
        "\x00\x00\x00\x00\x00\x00\x00\x07\x01",
    } });
}

test "MetadataServer: hosts, service accounts and project ids" {
    try testing.expect(isValidHost("metadata.google.internal"));
    try testing.expect(isValidHost("169.254.169.254"));
    try testing.expect(isValidHost("127.0.0.1:8080"));
    try testing.expect(!isValidHost("host/path"));
    try testing.expect(!isValidHost("host:"));
    try testing.expect(!isValidHost("[::1]:80"));
    try testing.expect(isValidServiceAccount("default"));
    try testing.expect(isValidServiceAccount("worker@p.iam.gserviceaccount.com"));
    try testing.expect(!isValidServiceAccount("../../instance"));
    try testing.expect(isProjectId("my-project-123"));
    try testing.expect(!isProjectId("my project"));
}

fn hostProperty(_: void, input: []const u8) !void {
    // Whatever is accepted goes into a URL whose host is the one given.
    if (!isValidHost(input)) return;
    var buf: [512]u8 = undefined;
    const url = try std.fmt.bufPrint(&buf, "http://{s}/computeMetadata/v1/", .{input});
    const uri = try std.Uri.parse(url);
    try testing.expectEqualStrings("http", uri.scheme);
    try testing.expectEqualStrings("/computeMetadata/v1/", uri.path.percent_encoded);
    var host_buf: [256]u8 = undefined;
    const host = try (uri.host orelse return error.TestExpectedHost).toRaw(&host_buf);
    try testing.expect(host.len > 0);
    try testing.expect(std.mem.startsWith(u8, input, host));
}

test "fuzz MetadataServer: an accepted host cannot reshape the URL" {
    try test_util.fuzzBytes({}, hostProperty, .{ .corpus = &.{
        "metadata.google.internal",
        "127.0.0.1:8085",
        "evil/../..",
        "a@b",
        "a?b",
        "a#b",
    } });
}
