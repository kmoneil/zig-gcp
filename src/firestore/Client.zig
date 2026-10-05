//! A Firestore client: configuration, the HTTP connection pool, and the
//! entry point for `Collection` and `Document` handles.
//!
//! Every call blocks the calling task until it completes, using the
//! `std.Io` and allocator passed to `init`. A client must not be used from
//! two tasks at once; give each task its own. A client reads and writes
//! one database, `(default)` unless `Options.database_id` names another.

const Client = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("core");

const Collection = @import("Collection.zig");
const Document = @import("Document.zig");
const Endpoint = @import("Endpoint.zig");
const Transaction = @import("Transaction.zig");
const batch_get = @import("batch_get.zig");
const query_ = @import("query.zig");
const errors = @import("errors.zig");
const names = @import("names.zig");
const rpc = @import("rpc.zig");
const types = @import("types.zig");
const validate = @import("validate.zig");
const writes_ = @import("writes.zig");
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
/// Owned copy of `Options.database_id`.
database_id: []const u8,
/// Owned. Scheme, host and port, such as `https://firestore.googleapis.com`.
base_url: []const u8,
/// The caller's, or the emulator's administrator.
token_provider: TokenProvider,
/// True against an emulator, which never receives the caller's credentials.
emulator: bool,
retry: RetryPolicy,
retry_unconditional_writes: bool,
send_quota_project: bool,
request_timeout_ms: u32,
diagnostics: ?*Diagnostics,
transport: Transport,
/// The built-in transport, when `Options.transport` was null.
http: ?*HttpTransport,
/// Owned copy of `Options.user_agent`.
user_agent: []const u8,
/// The length of `projects/P/databases/D/documents/`, which every full
/// name starts with and which counts against its 6 KiB.
name_prefix_len: usize,

pub const Options = struct {
    /// Project id or number, such as `my-project`.
    project_id: []const u8,
    /// `(default)`, or a named database's id, such as `orders-eu`.
    database_id: []const u8 = "(default)",
    /// Null means production. Use `Endpoint.fromEnv(environ)` to honor
    /// `FIRESTORE_EMULATOR_HOST`.
    endpoint: ?Endpoint = null,
    /// Null is only valid against an emulator, which never receives it
    /// either way.
    token_provider: ?TokenProvider = null,
    retry: RetryPolicy = .{},
    /// A write with transforms whose answer was lost may have landed, and
    /// sent again it applies them twice: an increment counts twice. Such a
    /// write is therefore retried only under a precondition a repeat
    /// fails, an update time or `exists == false`. This retries it anyway,
    /// as Google's own clients do. Writes without transforms are retried
    /// either way: writing the same fields twice changes nothing a reader
    /// can tell apart.
    retry_unconditional_writes: bool = false,
    /// How long one request may take before it is `error.TimedOut`, which
    /// is retried like any other transient failure. 0 removes the limit,
    /// and nothing bounds a call then but the caller's own `std.Io`.
    request_timeout_ms: u32 = 30_000,
    /// Sends `x-goog-user-project` when the credentials name a project to
    /// charge for quota, as a user's own credentials do.
    send_quota_project: bool = true,
    /// Printable ASCII.
    user_agent: []const u8 = "zig-gcp-firestore/0.32",
    /// Filled with details of every failed call; cleared by each new call.
    diagnostics: ?*Diagnostics = null,
    /// Sends requests through this instead of `std.http.Client`. Useful for
    /// tests, including tests of code that uses this library.
    transport: ?Transport = null,
};

/// The emulator's administrator. Its token is no secret; the emulator
/// takes it as admin, and production would refuse it.
var emulator_owner: core.StaticToken = .{ .token = "owner" };

/// Copies what it keeps from `options`; nothing borrowed outlives the call
/// except `diagnostics`, the token provider and the transport.
pub fn init(gpa: Allocator, io: std.Io, options: Options) Error!Client {
    const diag = options.diagnostics;
    if (diag) |d| d.clear();
    if (!core.names.isProjectId(options.project_id)) {
        if (diag) |d| d.print("invalid project id: expected 1 to 100 letters, digits, '-', '.', ':' or '_'", .{});
        return error.InvalidResourceId;
    }
    if (!validate.isDatabaseId(options.database_id)) {
        if (diag) |d| d.print("invalid database id: expected (default), or 4 to 63 lowercase letters, digits and '-', starting with a letter and ending with a letter or digit", .{});
        return error.InvalidResourceId;
    }
    if (!options.retry.isValid()) {
        if (diag) |d| d.print("invalid retry policy: max_attempts must be at least 1, multiplier finite and at least 1", .{});
        return error.InvalidOptions;
    }
    if (!validate.isUserAgent(options.user_agent)) {
        if (diag) |d| d.print("invalid user agent: expected printable ASCII", .{});
        return error.InvalidOptions;
    }

    const endpoint = options.endpoint orelse Endpoint.production;
    const emulator = endpoint.emulator;
    const token_provider = if (emulator) emulator_owner.provider() else options.token_provider orelse {
        if (diag) |d| d.print("no credentials: only an emulator endpoint works without Options.token_provider", .{});
        return error.MissingCredentials;
    };

    const base_url = endpoint.baseUrl(gpa) catch |err| {
        if (err == error.InvalidEndpoint) {
            if (diag) |d| d.print("invalid endpoint: expected scheme://host[:port]", .{});
        }
        return err;
    };
    errdefer gpa.free(base_url);
    // The caller's bearer token must not travel in cleartext.
    if (!emulator and !std.mem.startsWith(u8, base_url, "https://")) {
        if (diag) |d| d.print("invalid endpoint: endpoints that receive credentials must use https", .{});
        return error.InvalidEndpoint;
    }
    const project_id = try gpa.dupe(u8, options.project_id);
    errdefer gpa.free(project_id);
    const database_id = try gpa.dupe(u8, options.database_id);
    errdefer gpa.free(database_id);
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
        .database_id = database_id,
        .base_url = base_url,
        .token_provider = token_provider,
        .emulator = emulator,
        .retry = options.retry,
        .retry_unconditional_writes = options.retry_unconditional_writes,
        // The emulator's administrator bills nobody.
        .send_quota_project = options.send_quota_project and !emulator,
        .request_timeout_ms = options.request_timeout_ms,
        .diagnostics = diag,
        .transport = transport,
        .http = http,
        .user_agent = user_agent,
        .name_prefix_len = "projects//databases//documents/".len + project_id.len + database_id.len,
    };
}

pub fn deinit(self: *Client) void {
    if (self.http) |h| {
        h.deinit();
        self.gpa.destroy(h);
    }
    self.gpa.free(self.user_agent);
    self.gpa.free(self.database_id);
    self.gpa.free(self.project_id);
    self.gpa.free(self.base_url);
    self.* = undefined;
}

/// A handle for the collection at `path`, such as `cities`, or
/// `cities/LA/landmarks` for a subcollection. Sends nothing; the path is
/// checked by each call. The handle borrows the client and `path`, and
/// must not outlive either.
pub fn collection(self: *Client, path: []const u8) Collection {
    return .{ .client = self, .path = .init(path) };
}

/// A handle for the document at `path`, such as `cities/LA`. Sends
/// nothing; the path is checked by each call. The handle borrows the
/// client and `path`, and must not outlive either.
pub fn doc(self: *Client, path: []const u8) Document {
    return .{ .client = self, .path = .init(path) };
}

/// The full name of the document at `path`, as a `Value.reference` takes
/// it: `projects/P/databases/D/documents/PATH`, in `allocator`'s memory.
/// `path` is not checked here; the write that carries the reference
/// checks it.
pub fn documentName(self: *const Client, allocator: Allocator, path: []const u8) Allocator.Error![]u8 {
    return names.fullName(allocator, self.project_id, self.database_id, path);
}

/// Applies `writes` in order, atomically: all of them, or none when one is
/// refused. Each write is checked before anything is sent, as the server
/// would check it; in a commit of several, the diagnostics name the write
/// by its index. A document may be written more than once, each write
/// seeing the one before, and takes at most 500 transforms in all. When
/// the commit may be sent again after a lost answer is said at the top of
/// `retry_unconditional_writes`.
pub fn commit(self: *Client, writes: []const types.Write, options: types.CommitOptions) Error!types.Owned(types.CommitResult) {
    rpc.begin(self);
    var result: types.Owned(types.CommitResult) = try .init(self.gpa);
    errdefer result.deinit();
    result.value = try writes_.commit(self, writes, options.transaction, result.arena);
    return result;
}

/// Reads the documents at `paths` in one request: each, in the order
/// asked, or null where it does not exist. A path asked twice is answered
/// twice; no paths sends nothing.
pub fn batchGet(self: *Client, paths: []const []const u8, options: types.BatchGetOptions) Error!types.Owned(types.BatchGetResult) {
    rpc.begin(self);
    var result: types.Owned(types.BatchGetResult) = try .init(self.gpa);
    errdefer result.deinit();
    result.value = try batch_get.batchGet(self, paths, options, result.arena);
    return result;
}

/// Runs `handler` in a transaction: its reads join the transaction and its
/// writes are committed together when it returns, all or none. When the
/// server answers ABORTED, from the commit or a read, as it does when
/// another transaction holds what this one needs, the handler runs again
/// in a new transaction, up to `options.max_attempts` times in all, the
/// client's retry policy spacing the attempts. Any other error, the
/// handler's own included, rolls the transaction back and is returned.
/// A transaction lasts at most 270 s, and expires after 60 s idle.
pub fn runTransaction(self: *Client, handler: Transaction.Handler, options: types.RunTransactionOptions) anyerror!void {
    return Transaction.run(self, handler, options);
}

/// Begins a transaction and returns its id, for reads and a commit that
/// name it; `runTransaction` is the usual way. End it with a commit or
/// `rollback`, or it holds its locks until it expires.
pub fn beginTransaction(self: *Client, options: types.TransactionOptions) Error!types.Owned([]const u8) {
    rpc.begin(self);
    return Transaction.begin(self, options, null);
}

/// Ends a transaction without writing anything, freeing what it holds.
/// One already committed answers success; an unknown id
/// `error.InvalidArgument`.
pub fn rollback(self: *Client, transaction: []const u8) Error!void {
    rpc.begin(self);
    return Transaction.rollback(self, transaction);
}

/// Runs `query` and returns every result, as one answer. Checked first as
/// the server would check it; see `Query` and `Operator`.
pub fn runQuery(self: *Client, query: types.Query, options: types.QueryOptions) Error!types.Owned(types.QueryResult) {
    rpc.begin(self);
    var result: types.Owned(types.QueryResult) = try .init(self.gpa);
    errdefer result.deinit();
    result.value = try query_.run(self, query, options, result.arena);
    return result;
}

/// Counts, sums or averages `query`'s results on the server, without
/// reading them: 1 to 5 aggregations, answered in the order given. The
/// query's limit, offset and cursors apply first; its order matters only
/// to its cursors, and its select is not sent. With a sum or an average
/// among them, the emulator counts only documents that hold each field
/// summed or averaged, a count included.
pub fn runAggregationQuery(
    self: *Client,
    query: types.Query,
    aggregations: []const types.Aggregation,
    options: types.QueryOptions,
) Error!types.Owned(types.AggregationResult) {
    rpc.begin(self);
    var result: types.Owned(types.AggregationResult) = try .init(self.gpa);
    errdefer result.deinit();
    result.value = try query_.aggregate(self, query, aggregations, options, result.arena);
    return result;
}

/// One page of the ids of the database's top-level collections, in
/// ascending order. A collection exists while any document lies below
/// it.
pub fn listCollectionIds(self: *Client, options: types.ListCollectionIdsOptions) Error!types.Owned(types.CollectionIdPage) {
    rpc.begin(self);
    return rpc.listCollectionIds(self, "", options);
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
    for ([_][]const u8{ "Orders", "abc", "(default", "a2345678-1234-1234-1234-123456789abc" }) |db| {
        options.database_id = db;
        try testing.expectError(error.InvalidResourceId, Client.init(gpa, testing.io, options));
        try testing.expect(std.mem.indexOf(u8, diag.message(), "invalid database id") != null);
    }

    options.database_id = "(default)";
    options.retry = .{ .max_attempts = 0 };
    try testing.expectError(error.InvalidOptions, Client.init(gpa, testing.io, options));
    options.retry = .{};
    options.user_agent = "agent\r\nX: y";
    try testing.expectError(error.InvalidOptions, Client.init(gpa, testing.io, options));

    options.user_agent = "a";
    options.token_provider = null;
    try testing.expectError(error.MissingCredentials, Client.init(gpa, testing.io, options));
    try testing.expect(std.mem.indexOf(u8, diag.message(), "no credentials") != null);
}

test "init: production, a named database, the emulator" {
    var token: test_util.FakeTokenProvider = .{};
    var prod: Client = try .init(testing.allocator, testing.io, testOptions(&token));
    defer prod.deinit();
    try testing.expectEqualStrings("https://firestore.googleapis.com", prod.base_url);
    try testing.expectEqualStrings("(default)", prod.database_id);
    try testing.expect(!prod.emulator);
    try testing.expect(prod.send_quota_project);

    var options = testOptions(&token);
    options.database_id = "zigps-fs-1a2b";
    var named: Client = try .init(testing.allocator, testing.io, options);
    defer named.deinit();
    const n = try named.documentName(testing.allocator, "c/x");
    defer testing.allocator.free(n);
    try testing.expectEqualStrings("projects/extractctl/databases/zigps-fs-1a2b/documents/c/x", n);
    try testing.expectEqual("projects/extractctl/databases/zigps-fs-1a2b/documents/".len, named.name_prefix_len);

    // The emulator needs no token provider, and never gets the caller's.
    var emu: Client = try .init(testing.allocator, testing.io, .{
        .project_id = "test",
        .endpoint = .{ .url = "127.0.0.1:8087", .emulator = true },
        .token_provider = token.provider(),
    });
    defer emu.deinit();
    try testing.expectEqualStrings("http://127.0.0.1:8087", emu.base_url);
    try testing.expect(emu.emulator);
    try testing.expect(!emu.send_quota_project);
    try testing.expect(emu.token_provider.ptr != token.provider().ptr);
}

test "credentials never go to a plain-http endpoint" {
    var token: test_util.FakeTokenProvider = .{};
    var diag: Diagnostics = .{};
    var options = testOptions(&token);
    options.diagnostics = &diag;
    options.endpoint = .{ .url = "http://proxy.internal:8080" };
    try testing.expectError(error.InvalidEndpoint, Client.init(testing.allocator, testing.io, options));
    try testing.expect(std.mem.indexOf(u8, diag.message(), "must use https") != null);
    options.endpoint = .{ .url = "ftp://host" };
    try testing.expectError(error.InvalidEndpoint, Client.init(testing.allocator, testing.io, options));
}

test "init copies the strings it keeps" {
    var token: test_util.FakeTokenProvider = .{};
    var project = "project-1".*;
    var database = "orders-eu".*;
    var agent = "agent/1".*;
    var client: Client = try .init(testing.allocator, testing.io, .{
        .project_id = &project,
        .database_id = &database,
        .user_agent = &agent,
        .token_provider = token.provider(),
    });
    defer client.deinit();
    @memset(&project, 'x');
    @memset(&database, 'x');
    @memset(&agent, 'x');
    try testing.expectEqualStrings("project-1", client.project_id);
    try testing.expectEqualStrings("orders-eu", client.database_id);
    try testing.expectEqualStrings("agent/1", client.user_agent);
}

test "init: every allocation failure is OutOfMemory without leaks" {
    const Run = struct {
        fn run(gpa: Allocator) !void {
            var token: test_util.FakeTokenProvider = .{};
            var client: Client = try .init(gpa, testing.io, .{
                .project_id = "extractctl",
                .database_id = "orders-eu",
                .token_provider = token.provider(),
            });
            client.deinit();
        }
    };
    try testing.checkAllAllocationFailures(test_util.no_grow_allocator, Run.run, .{});
}

test "golden: listCollectionIds at the root, paged" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = "{\"collectionIds\":[\"cities\",\"users\"],\"nextPageToken\":\"tok+/=\"}" } },
        .{ .respond = .{ .body = "{}" } },
    }, .{});
    defer h.deinit();
    var first = try h.client.listCollectionIds(.{ .page_size = 2 });
    defer first.deinit();
    try h.expectRequest(0, .POST, "https://firestore.googleapis.com/v1/projects/extractctl/databases/(default)/documents:listCollectionIds", "{\"pageSize\":2}");
    try testing.expectEqual(2, first.value.collection_ids.len);
    try testing.expectEqualStrings("tok+/=", first.value.next_page_token.?);

    var second = try h.client.listCollectionIds(.{ .page_token = first.value.next_page_token, .read_time = .{ .nanoseconds = 1_791_153_779_000_000_000 } });
    defer second.deinit();
    try h.expectRequest(1, .POST, "https://firestore.googleapis.com/v1/projects/extractctl/databases/(default)/documents:listCollectionIds", "{\"pageToken\":\"tok+/=\",\"readTime\":\"2026-10-04T22:42:59Z\"}");
    try testing.expectEqual(0, second.value.collection_ids.len);
    try testing.expectEqual(null, second.value.next_page_token);
}

test "golden: the emulator gets the administrator's token, production the caller's" {
    var h: test_util.Harness = undefined;
    try h.init(&.{.{ .respond = .{ .body = "{}" } }}, .{ .emulator = true });
    defer h.deinit();
    var page = try h.client.listCollectionIds(.{});
    defer page.deinit();
    const r = try h.fake.request(0);
    try testing.expectEqualStrings("http://127.0.0.1:8087/v1/projects/extractctl/databases/(default)/documents:listCollectionIds", r.url);
    try testing.expectEqualStrings("owner", r.bearer.?);
    try testing.expectEqual(0, h.token.calls);
}
