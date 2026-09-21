//! A Pub/Sub client: configuration, the HTTP connection pool, and the entry
//! point for `Topic` and `Subscription` handles.
//!
//! Every call blocks the calling task until it completes, using the `std.Io`
//! and allocator passed to `init`. A client must not be used from two tasks
//! at once; give each task its own. Time limits come from the caller: run a
//! call in `io.async` or `io.concurrent` and cancel it, and it returns
//! `error.Canceled`.

const Client = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const Endpoint = @import("Endpoint.zig");
const Subscription = @import("Subscription.zig");
const Topic = @import("Topic.zig");
const codec = @import("codec.zig");
const errors = @import("errors.zig");
const rpc = @import("rpc.zig");
const types = @import("types.zig");
const url = @import("url.zig");
const validate = @import("validate.zig");
const Diagnostics = @import("core").Diagnostics;
const Error = errors.Error;
const HttpTransport = @import("core").transport.HttpTransport;
const RetryPolicy = @import("core").RetryPolicy;
const TokenProvider = @import("core").TokenProvider;
const Transport = @import("core").transport.Transport;

gpa: Allocator,
io: std.Io,
/// Owned copy of `Options.project_id`.
project_id: []const u8,
/// Owned. Scheme, host and port, such as `https://pubsub.googleapis.com`.
base_url: []const u8,
emulator: bool,
token_provider: ?TokenProvider,
retry: RetryPolicy,
retry_publish: bool,
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
    /// Null means production. `Endpoint.fromEnv(environ)` honors
    /// `PUBSUB_EMULATOR_HOST`.
    endpoint: ?Endpoint = null,
    /// Required, except for the emulator, which never receives credentials.
    token_provider: ?TokenProvider = null,
    retry: RetryPolicy = .{},
    /// A retried publish can store messages twice: after a 504, say, the
    /// server may already have them. Subscribers must tolerate duplicates
    /// anyway; set false to never retry a publish.
    retry_publish: bool = true,
    /// How long one request may take before it is `error.TimedOut`, which
    /// is retried like any other transient failure. Generous by default,
    /// because a pull with nothing to return is held open: about 20
    /// seconds in production and 90 by the emulator. 0 removes the limit,
    /// and nothing bounds a call then but the caller's own `std.Io`.
    request_timeout_ms: u32 = 180_000,
    /// Sends `x-goog-user-project` when the credentials name a project to
    /// charge for quota, as a user's own credentials do. Set false where
    /// the project owning the resources should pay instead.
    send_quota_project: bool = true,
    /// Printable ASCII.
    user_agent: []const u8 = "zig-gcp-pubsub/0.13",
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
    if (!validate.isProjectId(options.project_id)) {
        if (diag) |d| d.print("invalid project id: expected 1 to 100 letters, digits, '-', '.', ':' or '_'", .{});
        return error.InvalidResourceId;
    }
    if (!options.retry.isValid()) {
        if (diag) |d| d.print("invalid retry policy: max_attempts must be at least 1, multiplier finite and at least 1", .{});
        return error.InvalidOptions;
    }
    if (!isValidUserAgent(options.user_agent)) {
        if (diag) |d| d.print("invalid user agent: expected printable ASCII", .{});
        return error.InvalidOptions;
    }
    const endpoint = options.endpoint orelse Endpoint.production;
    if (!endpoint.emulator and options.token_provider == null) {
        if (diag) |d| d.print("this endpoint needs credentials: set token_provider, or use the emulator", .{});
        return error.MissingCredentials;
    }
    const base_url = endpoint.baseUrl(gpa) catch |err| {
        if (err == error.InvalidEndpoint) {
            if (diag) |d| d.print("invalid endpoint: expected http(s)://host[:port], or host:port for the emulator", .{});
        }
        return err;
    };
    errdefer gpa.free(base_url);
    // Everything but the emulator gets a bearer token, which must not travel
    // in cleartext.
    if (!endpoint.emulator and !std.mem.startsWith(u8, base_url, "https://")) {
        if (diag) |d| d.print("invalid endpoint: endpoints that receive credentials must use https", .{});
        return error.InvalidEndpoint;
    }
    const project_id = try gpa.dupe(u8, options.project_id);
    errdefer gpa.free(project_id);
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
        .emulator = endpoint.emulator,
        .token_provider = options.token_provider,
        .retry = options.retry,
        .retry_publish = options.retry_publish,
        .send_quota_project = options.send_quota_project,
        .request_timeout_ms = options.request_timeout_ms,
        .diagnostics = diag,
        .transport = transport,
        .http = http,
        .user_agent = user_agent,
    };
}

pub fn deinit(self: *Client) void {
    if (self.http) |h| {
        h.deinit();
        self.gpa.destroy(h);
    }
    self.gpa.free(self.user_agent);
    self.gpa.free(self.project_id);
    self.gpa.free(self.base_url);
    self.* = undefined;
}

/// A handle for the topic `id`, such as "orders". Sends nothing. The handle
/// borrows the client and `id`, and must not outlive either.
pub fn topic(self: *Client, id: []const u8) Topic {
    return .{ .client = self, .id = id };
}

/// A handle for the subscription `id`. Sends nothing. The handle borrows the
/// client and `id`, and must not outlive either.
pub fn subscription(self: *Client, id: []const u8) Subscription {
    return .{ .client = self, .id = id };
}

/// One page of the project's topics.
pub fn listTopics(self: *Client, page: types.PageOptions) Error!types.Owned(types.TopicPage) {
    rpc.begin(self);
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const path = try url.listPath(scratch.allocator(), self.project_id, .topics, page.page_size, page.page_token);
    var result: types.Owned(types.TopicPage) = try .init(self.gpa);
    errdefer result.deinit();
    const body = try rpc.execute(self, result.arena, .{ .method = .GET, .path = path });
    result.value = codec.decodeTopicPage(result.arena.allocator(), body) catch |err|
        return rpc.decodeFailed(self, err, "topic list");
    return result;
}

/// One page of the project's subscriptions.
pub fn listSubscriptions(self: *Client, page: types.PageOptions) Error!types.Owned(types.SubscriptionPage) {
    rpc.begin(self);
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const path = try url.listPath(scratch.allocator(), self.project_id, .subscriptions, page.page_size, page.page_token);
    var result: types.Owned(types.SubscriptionPage) = try .init(self.gpa);
    errdefer result.deinit();
    const body = try rpc.execute(self, result.arena, .{ .method = .GET, .path = path });
    result.value = codec.decodeSubscriptionPage(result.arena.allocator(), body) catch |err|
        return rpc.decodeFailed(self, err, "subscription list");
    return result;
}

fn isValidUserAgent(user_agent: []const u8) bool {
    if (user_agent.len == 0) return false;
    for (user_agent) |c| if (c < ' ' or c >= 0x7f) return false;
    return true;
}

const testing = std.testing;
const test_util = @import("test_util.zig");
const StaticToken = @import("core").StaticToken;

const local_emulator: Endpoint = .{ .url = "localhost:8085", .emulator = true };

test "init rejects bad options before allocating" {
    const gpa = testing.failing_allocator;
    const io = testing.io;
    var diag: Diagnostics = .{};
    try testing.expectError(error.MissingCredentials, Client.init(gpa, io, .{ .project_id = "p", .diagnostics = &diag }));
    try testing.expect(std.mem.indexOf(u8, diag.message(), "needs credentials") != null);
    try testing.expectError(error.InvalidResourceId, Client.init(gpa, io, .{ .project_id = "", .endpoint = local_emulator }));
    try testing.expectError(error.InvalidResourceId, Client.init(gpa, io, .{ .project_id = "a/b", .endpoint = local_emulator }));
    try testing.expectError(error.InvalidOptions, Client.init(gpa, io, .{ .project_id = "p", .endpoint = local_emulator, .retry = .{ .max_attempts = 0 } }));
    try testing.expectError(error.InvalidOptions, Client.init(gpa, io, .{ .project_id = "p", .endpoint = local_emulator, .retry = .{ .multiplier = 0.5 } }));
    try testing.expectError(error.InvalidOptions, Client.init(gpa, io, .{ .project_id = "p", .endpoint = local_emulator, .user_agent = "" }));
    try testing.expectError(error.InvalidOptions, Client.init(gpa, io, .{ .project_id = "p", .endpoint = local_emulator, .user_agent = "ua\r\nX: y" }));
}

test "init reports a bad endpoint" {
    var diag: Diagnostics = .{};
    try testing.expectError(error.InvalidEndpoint, Client.init(testing.allocator, testing.io, .{
        .project_id = "p",
        .endpoint = .{ .url = "ftp://host", .emulator = true },
        .diagnostics = &diag,
    }));
    try testing.expect(std.mem.indexOf(u8, diag.message(), "invalid endpoint") != null);
}

test "init and deinit with the built-in transport" {
    var client: Client = try .init(testing.allocator, testing.io, .{ .project_id = "p", .endpoint = local_emulator });
    defer client.deinit();
    try testing.expectEqualStrings("http://localhost:8085", client.base_url);
    try testing.expect(client.http != null);
    try testing.expect(client.emulator);
}

test "credentials never go to a plain-http endpoint" {
    var static: StaticToken = .{ .token = "t" };
    var diag: Diagnostics = .{};
    try testing.expectError(error.InvalidEndpoint, Client.init(testing.allocator, testing.io, .{
        .project_id = "p",
        .endpoint = .{ .url = "http://proxy.internal:8080" },
        .token_provider = static.provider(),
        .diagnostics = &diag,
    }));
    try testing.expect(std.mem.indexOf(u8, diag.message(), "must use https") != null);
}

test "production needs a token provider and uses https" {
    var static: StaticToken = .{ .token = "t" };
    var client: Client = try .init(testing.allocator, testing.io, .{ .project_id = "p", .token_provider = static.provider() });
    defer client.deinit();
    try testing.expectEqualStrings("https://pubsub.googleapis.com", client.base_url);
    try testing.expect(!client.emulator);
}

test "init copies the strings it keeps" {
    var project = "project-1".*;
    var agent = "agent/1".*;
    var host = "localhost:9999".*;
    var client: Client = try .init(testing.allocator, testing.io, .{
        .project_id = &project,
        .user_agent = &agent,
        .endpoint = .{ .url = &host, .emulator = true },
    });
    defer client.deinit();
    @memset(&project, 'x');
    @memset(&agent, 'x');
    @memset(&host, 'x');
    try testing.expectEqualStrings("project-1", client.project_id);
    try testing.expectEqualStrings("agent/1", client.user_agent);
    try testing.expectEqualStrings("http://localhost:9999", client.base_url);
}

test "init: every allocation failure is OutOfMemory without leaks" {
    const Run = struct {
        fn run(gpa: Allocator) !void {
            var client: Client = try .init(gpa, testing.io, .{ .project_id = "p", .endpoint = local_emulator });
            client.deinit();
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Run.run, .{});
}

test "every public call: every allocation failure is OutOfMemory without leaks" {
    const Reply = test_util.FakeTransport.Reply;
    const topic_body = "{\"name\":\"projects/p/topics/orders\"}";
    const sub_body = "{\"name\":\"projects/p/subscriptions/orders-worker\",\"topic\":\"projects/p/topics/orders\",\"ackDeadlineSeconds\":10}";
    const ok: Reply = .{ .respond = .{ .body = "{}" } };
    // One reply per request, in the order the calls below make them.
    const script = [_]Reply{
        .{ .respond = .{ .status = 503, .body = "{\"error\":{\"status\":\"UNAVAILABLE\"}}" } },
        .{ .respond = .{ .body = topic_body } },
        .{ .respond = .{ .body = topic_body } },
        .{ .respond = .{ .body = "{\"messageIds\":[\"1\"]}" } },
        .{ .respond = .{ .body = "{\"topics\":[" ++ topic_body ++ "],\"nextPageToken\":\"n\"}" } },
        .{ .respond = .{ .body = sub_body } },
        .{ .respond = .{ .body = sub_body } },
        .{ .respond = .{ .body = "{\"subscriptions\":[" ++ sub_body ++ "]}" } },
        .{ .respond = .{ .body = "{\"receivedMessages\":[{\"ackId\":\"a1\",\"message\":{\"data\":\"aGk=\",\"attributes\":{\"k\":\"v\"},\"messageId\":\"1\",\"publishTime\":\"2026-09-19T00:00:00Z\",\"orderingKey\":\"o\"},\"deliveryAttempt\":1}]}" } },
        ok, ok, // ack takes two requests
        ok, ok, // modifyAckDeadline, nack
        ok, ok, // the two deletes
    };
    const Run = struct {
        /// One more id than a request may carry.
        const many_ids: [validate.max_ack_ids_per_request + 1][]const u8 = @splat("a1");

        fn all(gpa: Allocator, replies: []const Reply) !void {
            var fake: test_util.FakeTransport = .init(testing.allocator, replies);
            defer fake.deinit();
            var clock: test_util.FakeClock = .{};
            var token: StaticToken = .{ .token = "ya29.token" };
            var client: Client = try .init(gpa, clock.io(), .{
                .project_id = "p",
                .token_provider = token.provider(),
                .transport = fake.transport(),
            });
            defer client.deinit();

            const t = client.topic("orders");
            var created = try t.create(.{}); // after one retry
            created.deinit();
            var got = try t.get();
            got.deinit();
            var sent = try t.publish(&.{.{ .data = "hi", .attributes = &.{.{ .key = "k", .value = "v" }} }}, .{ .ordering_key = "o" });
            sent.deinit();
            var topics = try client.listTopics(.{ .page_size = 1 });
            topics.deinit();

            const s = client.subscription("orders-worker");
            var sub = try s.create(.{ .topic_id = "orders" });
            sub.deinit();
            var sub_got = try s.get();
            sub_got.deinit();
            var subs = try client.listSubscriptions(.{ .page_token = "n" });
            subs.deinit();
            var batch = try s.pull(.{ .max_messages = 10 });
            batch.deinit();
            try s.ack(&many_ids);
            try s.modifyAckDeadline(&.{"a1"}, 30);
            try s.nack(&.{"a1"});
            try s.delete();
            try t.delete();
            // The calls above used the whole script, so none was skipped.
            try testing.expectEqual(replies.len, fake.requests.items.len);
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Run.all, .{@as([]const Reply, &script)});
}

test "golden: listTopics and listSubscriptions pass page options" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body =
        \\{"topics":[{"name":"projects/p/topics/page-1"},{"name":"projects/p/topics/page-2"}],
        \\"nextPageToken":"projects/p/topics/page-3"}
        } },
        .{ .respond = .{ .body = "{\"topics\":[{\"name\":\"projects/p/topics/page-3\"}]}" } },
        .{ .respond = .{ .body = "{\"subscriptions\":[{\"name\":\"projects/p/subscriptions/s\",\"topic\":\"projects/p/topics/t\",\"ackDeadlineSeconds\":10}]}" } },
        .{ .respond = .{ .body = "{}" } },
    }, .{});
    defer h.deinit();

    var first = try h.client.listTopics(.{ .page_size = 2 });
    defer first.deinit();
    try h.expectRequest(0, .GET, "http://localhost:8085/v1/projects/p/topics?pageSize=2", null);
    try testing.expectEqual(2, first.value.topics.len);
    try testing.expectEqualStrings("projects/p/topics/page-3", first.value.next_page_token.?);

    var second = try h.client.listTopics(.{ .page_size = 2, .page_token = first.value.next_page_token });
    defer second.deinit();
    try h.expectRequest(1, .GET, "http://localhost:8085/v1/projects/p/topics?pageSize=2&pageToken=projects%2Fp%2Ftopics%2Fpage-3", null);
    try testing.expectEqual(null, second.value.next_page_token);

    var subs = try h.client.listSubscriptions(.{});
    defer subs.deinit();
    try h.expectRequest(2, .GET, "http://localhost:8085/v1/projects/p/subscriptions?pageSize=100", null);
    try testing.expectEqual(10, subs.value.subscriptions[0].ack_deadline_seconds);

    // An empty project lists as `{}`.
    var none = try h.client.listSubscriptions(.{ .page_size = 0 });
    defer none.deinit();
    try h.expectRequest(3, .GET, "http://localhost:8085/v1/projects/p/subscriptions", null);
    try testing.expectEqual(0, none.value.subscriptions.len);
}

test "domain-scoped project ids keep their colon in paths and bodies" {
    var h: test_util.Harness = undefined;
    try h.init(&.{.{ .respond = .{ .body = "{}" } }}, .{ .project_id = "example.com:proj" });
    defer h.deinit();
    var created = try h.client.subscription("work").create(.{ .topic_id = "orders" });
    defer created.deinit();
    try h.expectRequest(
        0,
        .PUT,
        "http://localhost:8085/v1/projects/example.com:proj/subscriptions/work",
        "{\"topic\":\"projects/example.com:proj/topics/orders\",\"ackDeadlineSeconds\":10,\"enableMessageOrdering\":false}",
    );
}
