//! A Secret Manager client: configuration, the HTTP connection pool, and the
//! entry point for `Secret` and `Version` handles.
//!
//! Every call blocks the calling task until it completes, using the `std.Io`
//! and allocator passed to `init`. A client must not be used from two tasks
//! at once; give each task its own. A client is global or regional for its
//! whole life: the two are separate namespaces, so an application that needs
//! both creates two clients.

const Client = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("core");

const Secret = @import("Secret.zig");
const codec = @import("codec.zig");
const errors = @import("errors.zig");
const names = @import("names.zig");
const rpc = @import("rpc.zig");
const types = @import("types.zig");
const validate = @import("validate.zig");
const Diagnostics = core.Diagnostics;
const Error = errors.Error;
const HttpTransport = core.transport.HttpTransport;
const RetryPolicy = core.RetryPolicy;
const TokenProvider = core.TokenProvider;
const Transport = core.transport.Transport;

gpa: Allocator,
io: std.Io,
/// Owned copy of `Options.project_id`.
project_id: []const u8,
/// Owned copy of `Options.location`, or null for global secrets.
location: ?[]const u8,
/// Owned. Scheme, host and port, such as `https://secretmanager.googleapis.com`.
base_url: []const u8,
token_provider: TokenProvider,
verify_checksum: types.ChecksumMode,
retry: RetryPolicy,
retry_add_version: bool,
send_quota_project: bool,
request_timeout_ms: u32,
diagnostics: ?*Diagnostics,
transport: Transport,
/// The built-in transport, when `Options.transport` was null.
http: ?*HttpTransport,
/// Owned copy of `Options.user_agent`.
user_agent: []const u8,

pub const Options = struct {
    /// Project id or number, such as `my-project`.
    project_id: []const u8,
    /// Null means global secrets. A location such as `europe-west3` means
    /// regional ones, which live in their own namespace on their own host.
    location: ?[]const u8 = null,
    /// Required. Secret Manager has no emulator, so there is no
    /// unauthenticated mode.
    token_provider: TokenProvider,
    /// Overrides the host, for tests. Must be `https` when it receives
    /// credentials, which here is always.
    endpoint: ?[]const u8 = null,
    /// What to do about the checksum stored with a secret's bytes.
    verify_checksum: types.ChecksumMode = .if_present,
    retry: RetryPolicy = .{},
    /// A retried `addVersion` can store the same bytes twice: after a 504,
    /// say, the server may have stored them already. A duplicate version is
    /// harmless where a missing one is not, so retries are on by default.
    /// Callers who count versions can turn them off.
    retry_add_version: bool = true,
    /// How long one request may take before it is `error.TimedOut`, which is
    /// retried like any other transient failure. 0 removes the limit, and
    /// nothing bounds a call then but the caller's own `std.Io`.
    request_timeout_ms: u32 = 30_000,
    /// Sends `x-goog-user-project` when the credentials name a project to
    /// charge for quota, as a user's own credentials do.
    send_quota_project: bool = true,
    /// Printable ASCII.
    user_agent: []const u8 = "zig-gcp-secret-manager/0.14",
    /// Filled with details of every failed call; cleared by each new call.
    diagnostics: ?*Diagnostics = null,
    /// Sends requests through this instead of `std.http.Client`. Useful for
    /// tests, including tests of code that uses this library.
    transport: ?Transport = null,
};

/// Copies what it keeps from `options`; nothing borrowed outlives the call
/// except `diagnostics`, the token provider and the transport.
pub fn init(gpa: Allocator, io: std.Io, options: Options) Error!Client {
    const diag = options.diagnostics;
    if (diag) |d| d.clear();
    if (!core.names.isProjectId(options.project_id)) {
        if (diag) |d| d.print("invalid project id: expected 1 to 100 letters, digits, '-', '.', ':' or '_'", .{});
        return error.InvalidResourceId;
    }
    if (options.location) |location| if (!validate.isLocation(location)) {
        // The location becomes part of a host name, so a bad one could send
        // requests, and their credentials, somewhere else entirely.
        if (diag) |d| d.print("invalid location: expected a location id such as \"europe-west3\"", .{});
        return error.InvalidLocation;
    };
    if (!options.retry.isValid()) {
        if (diag) |d| d.print("invalid retry policy: max_attempts must be at least 1, multiplier finite and at least 1", .{});
        return error.InvalidOptions;
    }
    if (!validate.isUserAgent(options.user_agent)) {
        if (diag) |d| d.print("invalid user agent: expected printable ASCII", .{});
        return error.InvalidOptions;
    }

    const base_url = try baseUrl(gpa, options, diag);
    errdefer gpa.free(base_url);
    // Every request carries a bearer token, which must not travel in cleartext.
    if (!std.mem.startsWith(u8, base_url, "https://")) {
        if (diag) |d| d.print("invalid endpoint: endpoints that receive credentials must use https", .{});
        return error.InvalidEndpoint;
    }
    const project_id = try gpa.dupe(u8, options.project_id);
    errdefer gpa.free(project_id);
    const location = if (options.location) |l| try gpa.dupe(u8, l) else null;
    errdefer if (location) |l| gpa.free(l);
    const user_agent = try gpa.dupe(u8, options.user_agent);
    errdefer gpa.free(user_agent);

    var http: ?*HttpTransport = null;
    const transport = options.transport orelse t: {
        const h = try gpa.create(HttpTransport);
        h.* = .init(gpa, io, user_agent);
        http = h;
        break :t h.transport();
    };
    return .{
        .gpa = gpa,
        .io = io,
        .project_id = project_id,
        .location = location,
        .base_url = base_url,
        .token_provider = options.token_provider,
        .verify_checksum = options.verify_checksum,
        .retry = options.retry,
        .retry_add_version = options.retry_add_version,
        .send_quota_project = options.send_quota_project,
        .request_timeout_ms = options.request_timeout_ms,
        .diagnostics = diag,
        .transport = transport,
        .http = http,
        .user_agent = user_agent,
    };
}

/// The override, or the production host for this client's location.
fn baseUrl(gpa: Allocator, options: Options, diag: ?*Diagnostics) Error![]u8 {
    if (options.endpoint) |endpoint| {
        return core.endpoint.baseUrl(gpa, endpoint, .https) catch |err| {
            if (err == error.InvalidEndpoint) {
                if (diag) |d| d.print("invalid endpoint: expected https://host[:port]", .{});
            }
            return err;
        };
    }
    // The location has been checked, so this host name is well formed.
    const host = try names.host(gpa, options.location);
    defer gpa.free(host);
    return std.mem.concat(gpa, u8, &.{ "https://", host });
}

pub fn deinit(self: *Client) void {
    if (self.http) |h| {
        h.deinit();
        self.gpa.destroy(h);
    }
    self.gpa.free(self.user_agent);
    if (self.location) |l| self.gpa.free(l);
    self.gpa.free(self.project_id);
    self.gpa.free(self.base_url);
    self.* = undefined;
}

/// Which project, and which location's namespace, this client's paths
/// address.
pub fn parent(self: *const Client) names.Parent {
    return .{ .project = self.project_id, .location = self.location };
}

/// A handle for the secret `id`, such as "db-password". Sends nothing. The
/// handle borrows the client and `id`, and must not outlive either.
pub fn secret(self: *Client, id: []const u8) Secret {
    return .{ .client = self, .id = id };
}

/// One page of this project's secrets, in this client's namespace: a global
/// client never sees a regional secret, or the other way round.
pub fn listSecrets(self: *Client, options: types.ListOptions) Error!types.Owned(types.SecretPage) {
    rpc.begin(self);
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const path = try names.secretsPath(scratch.allocator(), self.parent(), options);

    var result: types.Owned(types.SecretPage) = try .init(self.gpa);
    errdefer result.deinit();
    const body = try rpc.execute(self, result.arena, .{ .method = .GET, .path = path });
    result.value = codec.decodeSecretPage(result.arena.allocator(), body) catch |err|
        return rpc.decodeFailed(self, err, "secret list");
    return result;
}

const testing = std.testing;
const test_util = @import("test_util.zig");

fn testOptions(token: *test_util.FakeTokenProvider) Options {
    return .{ .project_id = "extractctl", .token_provider = token.provider() };
}

test "init rejects bad options before allocating" {
    const gpa = testing.failing_allocator;
    var token: test_util.FakeTokenProvider = .{};
    var diag: Diagnostics = .{};
    var options = testOptions(&token);
    options.diagnostics = &diag;

    options.project_id = "a/b";
    try testing.expectError(error.InvalidResourceId, Client.init(gpa, testing.io, options));
    try testing.expect(std.mem.indexOf(u8, diag.message(), "invalid project id") != null);

    options.project_id = "extractctl";
    options.location = "Europe-West3";
    try testing.expectError(error.InvalidLocation, Client.init(gpa, testing.io, options));
    try testing.expect(std.mem.indexOf(u8, diag.message(), "invalid location") != null);
    options.location = "evil.example.com";
    try testing.expectError(error.InvalidLocation, Client.init(gpa, testing.io, options));

    options.location = null;
    options.retry = .{ .max_attempts = 0 };
    try testing.expectError(error.InvalidOptions, Client.init(gpa, testing.io, options));
    options.retry = .{};
    options.user_agent = "agent\r\nX: y";
    try testing.expectError(error.InvalidOptions, Client.init(gpa, testing.io, options));
}

test "init: the endpoint is the host for the location, or the override" {
    var token: test_util.FakeTokenProvider = .{};
    var global: Client = try .init(testing.allocator, testing.io, testOptions(&token));
    defer global.deinit();
    try testing.expectEqualStrings("https://secretmanager.googleapis.com", global.base_url);
    try testing.expectEqual(null, global.parent().location);

    var options = testOptions(&token);
    options.location = "europe-west3";
    var regional: Client = try .init(testing.allocator, testing.io, options);
    defer regional.deinit();
    try testing.expectEqualStrings("https://secretmanager.europe-west3.rep.googleapis.com", regional.base_url);
    try testing.expectEqualStrings("europe-west3", regional.parent().location.?);

    options = testOptions(&token);
    options.endpoint = "https://secretmanager.example.test:8443/";
    var overridden: Client = try .init(testing.allocator, testing.io, options);
    defer overridden.deinit();
    try testing.expectEqualStrings("https://secretmanager.example.test:8443", overridden.base_url);
}

test "credentials never go to a plain-http endpoint" {
    var token: test_util.FakeTokenProvider = .{};
    var diag: Diagnostics = .{};
    var options = testOptions(&token);
    options.diagnostics = &diag;
    options.endpoint = "http://proxy.internal:8080";
    try testing.expectError(error.InvalidEndpoint, Client.init(testing.allocator, testing.io, options));
    try testing.expect(std.mem.indexOf(u8, diag.message(), "must use https") != null);

    options.endpoint = "ftp://host";
    try testing.expectError(error.InvalidEndpoint, Client.init(testing.allocator, testing.io, options));
    try testing.expect(std.mem.indexOf(u8, diag.message(), "invalid endpoint") != null);
}

test "init copies the strings it keeps" {
    var token: test_util.FakeTokenProvider = .{};
    var project = "project-1".*;
    var location = "europe-west3".*;
    var agent = "agent/1".*;
    var client: Client = try .init(testing.allocator, testing.io, .{
        .project_id = &project,
        .location = &location,
        .user_agent = &agent,
        .token_provider = token.provider(),
    });
    defer client.deinit();
    @memset(&project, 'x');
    @memset(&location, 'x');
    @memset(&agent, 'x');
    try testing.expectEqualStrings("project-1", client.project_id);
    try testing.expectEqualStrings("europe-west3", client.location.?);
    try testing.expectEqualStrings("agent/1", client.user_agent);
    // The base URL was built before the location was overwritten.
    try testing.expectEqualStrings("https://secretmanager.europe-west3.rep.googleapis.com", client.base_url);
}

test "init: every allocation failure is OutOfMemory without leaks" {
    const Run = struct {
        fn run(gpa: Allocator) !void {
            var token: test_util.FakeTokenProvider = .{};
            var client: Client = try .init(gpa, testing.io, .{
                .project_id = "extractctl",
                .location = "europe-west3",
                .token_provider = token.provider(),
            });
            client.deinit();
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Run.run, .{});
}

test "golden: listSecrets pages, filters and stops" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body =
        \\{"secrets":[{"name":"projects/82150720798/secrets/zigps-a","labels":{"zig-gcp-test":"1"}},
        \\ {"name":"projects/82150720798/secrets/zigps-b"}],
        \\ "nextPageToken":"2Aeg8oI9ojTXZ","totalSize":3}
        } },
        .{ .respond = .{ .body = "{\"secrets\":[{\"name\":\"projects/82150720798/secrets/zigps-c\"}]}" } },
        .{ .respond = .{ .body = "{}" } },
    }, .{});
    defer h.deinit();

    var first = try h.client.listSecrets(.{ .page_size = 2, .filter = "labels.zig-gcp-test=1" });
    defer first.deinit();
    try h.expectRequest(
        0,
        .GET,
        "https://secretmanager.googleapis.com/v1/projects/extractctl/secrets?pageSize=2&filter=labels.zig-gcp-test%3D1",
        null,
    );
    try testing.expectEqual(2, first.value.secrets.len);
    try testing.expectEqualStrings("zigps-a", first.value.secrets[0].id());
    try testing.expectEqual(3, first.value.total_size);

    var second = try h.client.listSecrets(.{ .page_size = 2, .page_token = first.value.next_page_token });
    defer second.deinit();
    try h.expectRequest(
        1,
        .GET,
        "https://secretmanager.googleapis.com/v1/projects/extractctl/secrets?pageSize=2&pageToken=2Aeg8oI9ojTXZ",
        null,
    );
    // The last page has no token, so a loop over pages ends here.
    try testing.expectEqual(null, second.value.next_page_token);

    // An empty project answers `{}`, and the defaults send no query at all.
    var none = try h.client.listSecrets(.{});
    defer none.deinit();
    try h.expectRequest(2, .GET, "https://secretmanager.googleapis.com/v1/projects/extractctl/secrets", null);
    try testing.expectEqual(0, none.value.secrets.len);
}

test "golden: listSecrets in a regional namespace" {
    var h: test_util.Harness = undefined;
    try h.init(&.{.{ .respond = .{ .body = "{}" } }}, .{ .location = "europe-west3" });
    defer h.deinit();
    var page = try h.client.listSecrets(.{});
    defer page.deinit();
    try h.expectRequest(
        0,
        .GET,
        "https://secretmanager.europe-west3.rep.googleapis.com/v1/projects/extractctl/locations/europe-west3/secrets",
        null,
    );
}
