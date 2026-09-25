//! A Cloud Storage client: configuration, the HTTP connection pool, and the
//! entry point for `Bucket` and `Object` handles.
//!
//! Every call blocks the calling task until it completes, using the
//! `std.Io` and allocator passed to `init`. A client must not be used from
//! two tasks at once; give each task its own.

const Client = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("core");

const Bucket = @import("Bucket.zig");
const Endpoint = @import("Endpoint.zig");
const checkpoint = @import("checkpoint.zig");
const codec = @import("codec.zig");
const errors = @import("errors.zig");
const names = @import("names.zig");
const parallel = @import("parallel.zig");
const resumable = @import("resumable.zig");
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
/// Owned copy of `Options.project_id`, or null.
project_id: ?[]const u8,
/// Owned. Scheme, host and port, such as `https://storage.googleapis.com`.
base_url: []const u8,
token_provider: ?TokenProvider,
/// True against an emulator, which never receives credentials.
unauthenticated: bool,
scope: rpc.Scope,
retry: RetryPolicy,
retry_unconditional_writes: bool,
verify_checksums: bool,
chunk_size: usize,
single_request_limit: usize,
send_quota_project: bool,
request_timeout_ms: u32,
diagnostics: ?*Diagnostics,
transport: Transport,
/// The built-in transport, when `Options.transport` was null.
http: ?*HttpTransport,
/// Owned copy of `Options.user_agent`.
user_agent: []const u8,
/// Tests only: lowers the multipart upload's 5 MiB part floor and a
/// parallel download's 1 MiB range floor, and lets an emulator endpoint
/// take the multipart path instead of the ordinary upload `uploadParallel`
/// falls back to there, so a test can send a few KiB in dozens of parts to
/// a fake that speaks the XML API, and read them back in dozens of ranges.
multipart_test: MultipartTest = .{},

pub const MultipartTest = struct {
    min_part_size: ?u64 = null,
    on_emulator: bool = false,
};

pub const Options = struct {
    /// Needed only to create or list buckets, which address no bucket yet.
    project_id: ?[]const u8 = null,
    /// Null means production. Use `Endpoint.fromEnv(environ)` to honor
    /// `STORAGE_EMULATOR_HOST`.
    endpoint: ?Endpoint = null,
    /// Null is only valid against an emulator.
    token_provider: ?TokenProvider = null,
    /// The OAuth scope asked of the token provider.
    scope: rpc.Scope = .read_write,
    retry: RetryPolicy = .{},
    /// A delete without a `generation` may repeat a delete that already
    /// happened, and by then remove someone else's newer object. It is not
    /// retried unless this opts in; a delete with a `generation` always is,
    /// because a repeat fails cleanly instead.
    retry_unconditional_writes: bool = false,
    /// Compute and check CRC-32C checksums on uploads and downloads. Off,
    /// nothing is computed, checked, or sent beyond what the caller passed.
    verify_checksums: bool = true,
    /// How much of a resumable upload travels per request, and the buffer
    /// `uploadFrom` holds one chunk in. A multiple of 256 KiB; 8 MiB is
    /// Google's recommended minimum.
    chunk_size: usize = 8 * 1024 * 1024,
    /// `upload` calls at or below this size go out as one multipart
    /// request; larger ones take the resumable protocol.
    single_request_limit: usize = 8 * 1024 * 1024,
    /// How long one request may take before it is `error.TimedOut`, which
    /// is retried like any other transient failure. 0 removes the limit,
    /// and nothing bounds a call then but the caller's own `std.Io`.
    request_timeout_ms: u32 = 30_000,
    /// Sends `x-goog-user-project` when the credentials name a project to
    /// charge for quota, as a user's own credentials do.
    send_quota_project: bool = true,
    /// Printable ASCII.
    user_agent: []const u8 = "zig-gcp-storage/0.19",
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
    if (options.project_id) |project| if (!core.names.isProjectId(project)) {
        if (diag) |d| d.print("invalid project id: expected 1 to 100 letters, digits, '-', '.', ':' or '_'", .{});
        return error.InvalidResourceId;
    };
    if (!options.retry.isValid()) {
        if (diag) |d| d.print("invalid retry policy: max_attempts must be at least 1, multiplier finite and at least 1", .{});
        return error.InvalidOptions;
    }
    if (!validate.isUserAgent(options.user_agent)) {
        if (diag) |d| d.print("invalid user agent: expected printable ASCII", .{});
        return error.InvalidOptions;
    }
    if (options.chunk_size == 0 or options.chunk_size % (256 * 1024) != 0) {
        if (diag) |d| d.print("invalid chunk size: resumable chunks are a positive multiple of 256 KiB", .{});
        return error.InvalidChunkSize;
    }

    const endpoint = options.endpoint orelse Endpoint.production;
    // An emulator speaks plain HTTP and must never see credentials, so it
    // works without a token provider; everything else needs one.
    const unauthenticated = endpoint.emulator;
    if (!unauthenticated and options.token_provider == null) {
        if (diag) |d| d.print("no credentials: only an emulator endpoint works without Options.token_provider", .{});
        return error.MissingCredentials;
    }

    const base_url = endpoint.baseUrl(gpa) catch |err| {
        if (err == error.InvalidEndpoint) {
            if (diag) |d| d.print("invalid endpoint: expected scheme://host[:port]", .{});
        }
        return err;
    };
    errdefer gpa.free(base_url);
    // Every credentialed request carries a bearer token, which must not
    // travel in cleartext.
    if (!unauthenticated and !std.mem.startsWith(u8, base_url, "https://")) {
        if (diag) |d| d.print("invalid endpoint: endpoints that receive credentials must use https", .{});
        return error.InvalidEndpoint;
    }
    const project_id = if (options.project_id) |p| try gpa.dupe(u8, p) else null;
    errdefer if (project_id) |p| gpa.free(p);
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
        .base_url = base_url,
        .token_provider = if (unauthenticated) null else options.token_provider,
        .unauthenticated = unauthenticated,
        .scope = options.scope,
        .retry = options.retry,
        .retry_unconditional_writes = options.retry_unconditional_writes,
        .verify_checksums = options.verify_checksums,
        .chunk_size = options.chunk_size,
        .single_request_limit = options.single_request_limit,
        .send_quota_project = options.send_quota_project,
        .request_timeout_ms = options.request_timeout_ms,
        .diagnostics = diag,
        .transport = transport,
        .http = http,
        .user_agent = user_agent,
    };
}

/// A client with this one's settings and a connection of its own, for a
/// task that runs beside this one's: a client must not be used from two
/// tasks at once, and the built-in transport is not safe to share. A custom
/// `Options.transport` is shared, so it must tolerate use from several
/// tasks at once, as `pubsub.Publisher` asks of its senders' too. The token
/// provider is shared; it is asked for tokens from every task. The sibling
/// reports into `diagnostics`, and is freed with its own `deinit`.
pub fn sibling(self: *const Client, diagnostics: ?*Diagnostics) Error!Client {
    const base_url = try self.gpa.dupe(u8, self.base_url);
    errdefer self.gpa.free(base_url);
    const project_id = if (self.project_id) |p| try self.gpa.dupe(u8, p) else null;
    errdefer if (project_id) |p| self.gpa.free(p);
    const user_agent = try self.gpa.dupe(u8, self.user_agent);
    errdefer self.gpa.free(user_agent);

    var http: ?*HttpTransport = null;
    const transport = if (self.http == null) self.transport else t: {
        const h = try self.gpa.create(HttpTransport);
        h.* = .init(self.gpa, self.io, user_agent);
        http = h;
        break :t h.transport();
    };
    var copy = self.*;
    copy.project_id = project_id;
    copy.base_url = base_url;
    copy.user_agent = user_agent;
    copy.transport = transport;
    copy.http = http;
    copy.diagnostics = diagnostics;
    return copy;
}

pub fn deinit(self: *Client) void {
    if (self.http) |h| {
        h.deinit();
        self.gpa.destroy(h);
    }
    self.gpa.free(self.user_agent);
    if (self.project_id) |p| self.gpa.free(p);
    self.gpa.free(self.base_url);
    self.* = undefined;
}

/// A handle for the bucket `name`. Sends nothing. The handle borrows the
/// client and `name`, and must not outlive either.
pub fn bucket(self: *Client, name: []const u8) Bucket {
    return .{ .client = self, .name = name };
}

/// Drops what a checkpoint's transfer left on the server, for a caller
/// who decides not to resume it: cancels a resumable session, or aborts a
/// multipart upload and deletes its temporary object; a download left
/// nothing there, its file being the caller's to remove. Then clears the
/// checkpoint. One that holds nothing is nothing to do; one holding bytes
/// this library did not write is `error.CheckpointFailed`, and kept.
/// Without this, a session expires on its own within a week, and a
/// multipart upload's parts stay billed until a lifecycle rule aborts it.
pub fn abandonTransfer(self: *Client, cp: types.Checkpoint) Error!void {
    rpc.begin(self);
    var arena: std.heap.ArenaAllocator = .init(self.gpa);
    defer arena.deinit();
    const bytes = cp.load(arena.allocator()) catch |err| switch (err) {
        error.CheckpointFailed => {
            if (self.diagnostics) |d| d.print("the checkpoint could not be read", .{});
            return error.CheckpointFailed;
        },
        else => |e| return e,
    } orelse return;
    const state = checkpoint.parse(arena.allocator(), bytes) catch |err| switch (err) {
        error.CheckpointFailed => {
            if (self.diagnostics) |d| d.print("the checkpoint holds no state this library wrote; nothing was changed", .{});
            return error.CheckpointFailed;
        },
        error.OutOfMemory => return error.OutOfMemory,
    };
    switch (state) {
        .download_parallel => {},
        .upload_file => |s| try resumable.cancelSession(self, s.session),
        .upload_parallel => |s| try parallel.abandon(self, s),
    }
    cp.clear();
}

/// One page of the project's buckets. Needs `Options.project_id`.
pub fn listBuckets(self: *Client, page: types.PageOptions) Error!types.Owned(types.BucketPage) {
    rpc.begin(self);
    const project = try rpc.requireProject(self);
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const path = try names.bucketsPath(scratch.allocator(), project, page);

    var result: types.Owned(types.BucketPage) = try .init(self.gpa);
    errdefer result.deinit();
    const body = try rpc.execute(self, result.arena, .{ .method = .GET, .path = path });
    result.value = codec.decodeBucketPage(result.arena.allocator(), body) catch |err|
        return rpc.decodeFailed(self, err, "bucket list");
    return result;
}

const testing = std.testing;
const test_util = @import("test_util.zig");

test "init rejects bad options before allocating" {
    const gpa = testing.failing_allocator;
    var diag: Diagnostics = .{};
    var token: test_util.FakeTokenProvider = .{};

    try testing.expectError(error.InvalidResourceId, Client.init(gpa, testing.io, .{
        .project_id = "a/b",
        .token_provider = token.provider(),
        .diagnostics = &diag,
    }));
    try testing.expect(std.mem.indexOf(u8, diag.message(), "invalid project id") != null);

    try testing.expectError(error.InvalidOptions, Client.init(gpa, testing.io, .{
        .token_provider = token.provider(),
        .retry = .{ .max_attempts = 0 },
        .diagnostics = &diag,
    }));
    try testing.expectError(error.InvalidOptions, Client.init(gpa, testing.io, .{
        .token_provider = token.provider(),
        .user_agent = "agent\r\nX: y",
        .diagnostics = &diag,
    }));
}

test "init: production needs credentials; an emulator refuses to see them" {
    var diag: Diagnostics = .{};
    try testing.expectError(error.MissingCredentials, Client.init(testing.allocator, testing.io, .{
        .diagnostics = &diag,
    }));
    try testing.expect(std.mem.indexOf(u8, diag.message(), "only an emulator") != null);

    // An emulator endpoint works without a provider, over plain HTTP.
    var bare: Client = try .init(testing.allocator, testing.io, .{
        .endpoint = .{ .url = "localhost:4443", .emulator = true },
    });
    defer bare.deinit();
    try testing.expectEqualStrings("http://localhost:4443", bare.base_url);
    try testing.expect(bare.unauthenticated);

    // A provider given anyway is dropped: plain HTTP never carries a token.
    var token: test_util.FakeTokenProvider = .{};
    var both: Client = try .init(testing.allocator, testing.io, .{
        .endpoint = .{ .url = "localhost:4443", .emulator = true },
        .token_provider = token.provider(),
    });
    defer both.deinit();
    try testing.expectEqual(null, both.token_provider);
}

test "credentials never go to a plain-http endpoint" {
    var diag: Diagnostics = .{};
    var token: test_util.FakeTokenProvider = .{};
    try testing.expectError(error.InvalidEndpoint, Client.init(testing.allocator, testing.io, .{
        .endpoint = .{ .url = "http://proxy.internal:8080" },
        .token_provider = token.provider(),
        .diagnostics = &diag,
    }));
    try testing.expect(std.mem.indexOf(u8, diag.message(), "must use https") != null);
}

test "init: the endpoint is production, or the override" {
    var token: test_util.FakeTokenProvider = .{};
    var production: Client = try .init(testing.allocator, testing.io, .{ .token_provider = token.provider() });
    defer production.deinit();
    try testing.expectEqualStrings("https://storage.googleapis.com", production.base_url);
    try testing.expect(!production.unauthenticated);

    var overridden: Client = try .init(testing.allocator, testing.io, .{
        .endpoint = .{ .url = "https://storage.example.test:8443/" },
        .token_provider = token.provider(),
    });
    defer overridden.deinit();
    try testing.expectEqualStrings("https://storage.example.test:8443", overridden.base_url);
}

test "init copies the strings it keeps" {
    var project = "project-1".*;
    var agent = "agent/1".*;
    var client: Client = try .init(testing.allocator, testing.io, .{
        .project_id = &project,
        .user_agent = &agent,
        .endpoint = .{ .url = "localhost:4443", .emulator = true },
    });
    defer client.deinit();
    @memset(&project, 'x');
    @memset(&agent, 'x');
    try testing.expectEqualStrings("project-1", client.project_id.?);
    try testing.expectEqualStrings("agent/1", client.user_agent);
}

test "init: every allocation failure is OutOfMemory without leaks" {
    const Run = struct {
        fn run(gpa: Allocator) !void {
            var client: Client = try .init(gpa, testing.io, .{
                .project_id = "extractctl",
                .endpoint = .{ .url = "localhost:4443", .emulator = true },
            });
            client.deinit();
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Run.run, .{});
}

test "golden: listBuckets needs a project and pages" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = "{\"items\":[{\"name\":\"zigps-a\"},{\"name\":\"zigps-b\"}],\"nextPageToken\":\"t\"}" } },
        .{ .respond = .{ .body = "{}" } },
    }, .{});
    defer h.deinit();

    var first = try h.client.listBuckets(.{ .page_size = 2 });
    defer first.deinit();
    try h.expectRequest(0, .GET, "https://storage.googleapis.com/storage/v1/b?project=extractctl&maxResults=2", null);
    try testing.expectEqual(2, first.value.buckets.len);
    try testing.expectEqualStrings("zigps-a", first.value.buckets[0].name);

    var second = try h.client.listBuckets(.{ .page_token = first.value.next_page_token });
    defer second.deinit();
    try h.expectRequest(1, .GET, "https://storage.googleapis.com/storage/v1/b?project=extractctl&pageToken=t", null);
    try testing.expectEqual(null, second.value.next_page_token);
}

test "listBuckets without a project is MissingProject" {
    var h: test_util.Harness = undefined;
    try h.init(&.{}, .{ .project_id = null });
    defer h.deinit();
    try testing.expectError(error.MissingProject, h.client.listBuckets(.{}));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "project_id") != null);
    try h.expectRequestCount(0);
}

test "sibling: the same settings, a connection of its own, and diagnostics of its own" {
    var token: core.StaticToken = .{ .token = "ya29.t" };
    var diag: Diagnostics = .{};
    var client: Client = try .init(testing.allocator, testing.io, .{
        .project_id = "extractctl",
        .token_provider = token.provider(),
        .retry = .{ .max_attempts = 7 },
        .request_timeout_ms = 1234,
        .user_agent = "zig-gcp-test/1",
        .diagnostics = &diag,
    });
    defer client.deinit();
    var sibling_diag: Diagnostics = .{};
    var s = try client.sibling(&sibling_diag);
    defer s.deinit();
    // A built-in transport is never shared: one per task.
    try testing.expect(s.http != null and s.http != client.http);
    try testing.expect(s.transport.ptr != client.transport.ptr);
    try testing.expectEqual(&sibling_diag, s.diagnostics.?);
    // Its own copies of the strings, equal to the original's.
    try testing.expect(s.base_url.ptr != client.base_url.ptr);
    try testing.expectEqualStrings(client.base_url, s.base_url);
    try testing.expectEqualStrings("extractctl", s.project_id.?);
    try testing.expectEqualStrings("zig-gcp-test/1", s.user_agent);
    try testing.expectEqual(7, s.retry.max_attempts);
    try testing.expectEqual(1234, s.request_timeout_ms);
    try testing.expectEqual(client.token_provider.?.ptr, s.token_provider.?.ptr);

    // A custom transport is shared, as documented.
    var h: test_util.Harness = undefined;
    try h.init(&.{}, .{});
    defer h.deinit();
    var shared = try h.client.sibling(null);
    defer shared.deinit();
    try testing.expectEqual(null, shared.http);
    try testing.expectEqual(h.client.transport.ptr, shared.transport.ptr);
    try testing.expectEqual(null, shared.diagnostics);
}

fn siblingOf(gpa: Allocator) !void {
    var token: core.StaticToken = .{ .token = "ya29.t" };
    var client: Client = try .init(gpa, testing.io, .{
        .project_id = "extractctl",
        .token_provider = token.provider(),
    });
    defer client.deinit();
    var s = try client.sibling(null);
    s.deinit();
}

test "sibling: every allocation failure is OutOfMemory without leaks" {
    try testing.checkAllAllocationFailures(testing.allocator, siblingOf, .{});
}
