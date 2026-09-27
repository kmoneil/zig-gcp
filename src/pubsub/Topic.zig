//! A topic handle: a client pointer and a short id such as "orders". Making
//! one sends nothing. It borrows both, so it must not outlive the client or
//! the memory behind `id`.

const Topic = @This();

const std = @import("std");

const Client = @import("Client.zig");
const codec = @import("codec.zig");
const rpc = @import("rpc.zig");
const types = @import("types.zig");
const url = @import("url.zig");
const validate = @import("validate.zig");
const Error = @import("errors.zig").Error;
const Owned = types.Owned;

client: *Client,
/// The client builds the full name, `projects/{project}/topics/{id}`.
id: []const u8,

/// Creates the topic. If a lost first attempt already created it, the retry
/// reports `error.AlreadyExists`. Every setting is checked first.
pub fn create(self: Topic, config: types.TopicConfig) Error!Owned(types.TopicInfo) {
    const c = self.client;
    rpc.begin(c);
    try rpc.checkId(c, "topic", self.id);
    try validate.topicConfig(config, c.diagnostics);
    var scratch: std.heap.ArenaAllocator = .init(c.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const path = try url.resourcePath(a, c.project_id, .topics, self.id, "");
    const body = try codec.encodeTopic(a, config);
    return fetch(c, .{ .method = .PUT, .path = path, .body = body });
}

/// Changes what `changes` names, and nothing else, and returns the topic as
/// it is then. A storage policy is replaced whole, and labels as a set.
pub fn update(self: Topic, changes: types.TopicUpdate) Error!Owned(types.TopicInfo) {
    const c = self.client;
    rpc.begin(c);
    try rpc.checkId(c, "topic", self.id);
    try validate.topicUpdate(changes, c.diagnostics);
    var scratch: std.heap.ArenaAllocator = .init(c.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const path = try url.resourcePath(a, c.project_id, .topics, self.id, "");
    const body = try codec.encodeTopicUpdate(a, changes);
    return fetch(c, .{ .method = .PATCH, .path = path, .body = body });
}

pub fn get(self: Topic) Error!Owned(types.TopicInfo) {
    const c = self.client;
    rpc.begin(c);
    try rpc.checkId(c, "topic", self.id);
    var scratch: std.heap.ArenaAllocator = .init(c.gpa);
    defer scratch.deinit();
    const path = try url.resourcePath(scratch.allocator(), c.project_id, .topics, self.id, "");
    return fetch(c, .{ .method = .GET, .path = path });
}

/// Deletes the topic. Its subscriptions stay, detached. If a lost first
/// attempt already deleted it, the retry reports `error.NotFound`.
pub fn delete(self: Topic) Error!void {
    const c = self.client;
    rpc.begin(c);
    try rpc.checkId(c, "topic", self.id);
    var scratch: std.heap.ArenaAllocator = .init(c.gpa);
    defer scratch.deinit();
    const path = try url.resourcePath(scratch.allocator(), c.project_id, .topics, self.id, "");
    return rpc.executeDiscard(c, .{ .method = .DELETE, .path = path });
}

/// Publishes `messages` in one HTTP request. The returned ids match the order
/// of `messages`. Limits are checked first (`error.InvalidMessage`), on the
/// request as it is before any compression.
/// A retried publish can store messages twice; see `Client.Options.retry_publish`.
pub fn publish(
    self: Topic,
    messages: []const types.Message,
    options: types.PublishOptions,
) Error!Owned(types.PublishResult) {
    const c = self.client;
    rpc.begin(c);
    try rpc.checkId(c, "topic", self.id);
    try validate.publish(messages, options.ordering_key, c.diagnostics);
    if (options.compression) |compression| try validate.compression(compression, c.diagnostics);
    var scratch: std.heap.ArenaAllocator = .init(c.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const path = try url.resourcePath(a, c.project_id, .topics, self.id, ":publish");
    const body = try codec.encodePublish(a, messages, options.ordering_key);
    // Compressed once: a retry sends the same bytes. Apart from the arena,
    // so the compressor's memory is back before the request goes.
    const compressed = try rpc.compressBody(c.gpa, body, options.compression);
    defer if (compressed) |bytes| c.gpa.free(bytes);

    var result: Owned(types.PublishResult) = try .init(c.gpa);
    errdefer result.deinit();
    const response = try rpc.execute(c, result.arena, .{
        .method = .POST,
        .path = path,
        .body = compressed orelse body,
        .headers = if (compressed != null) rpc.gzip_headers else &.{},
        .retry = c.retry_publish,
        .retryable = rpc.isPublishRetryable,
    });
    result.value = codec.decodePublish(result.arena.allocator(), response, messages.len) catch |err|
        return rpc.decodeFailed(c, err, "publish");
    return result;
}

fn fetch(c: *Client, call: rpc.Call) Error!Owned(types.TopicInfo) {
    var result: Owned(types.TopicInfo) = try .init(c.gpa);
    errdefer result.deinit();
    const body = try rpc.execute(c, result.arena, call);
    result.value = codec.decodeTopic(result.arena.allocator(), body) catch |err|
        return rpc.decodeFailed(c, err, "topic");
    return result;
}

const testing = std.testing;
const test_util = @import("test_util.zig");
const Harness = test_util.Harness;

test "golden: create, get, delete and publish send the right requests" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = "{\n  \"name\": \"projects/p/topics/orders\"\n}\n" } },
        .{ .respond = .{ .body = "{\"name\":\"projects/p/topics/orders\"}" } },
        .{ .respond = .{ .body = "{\n}\n" } },
        .{ .respond = .{ .body = "{\n  \"messageIds\": [\"11\", \"12\"]\n}\n" } },
    }, .{});
    defer h.deinit();
    const orders = h.client.topic("orders");

    var created = try orders.create(.{});
    defer created.deinit();
    try testing.expectEqualStrings("projects/p/topics/orders", created.value.name);
    try h.expectRequest(0, .PUT, "http://localhost:8085/v1/projects/p/topics/orders", "{}");

    var got = try orders.get();
    defer got.deinit();
    try h.expectRequest(1, .GET, "http://localhost:8085/v1/projects/p/topics/orders", null);

    try orders.delete();
    try h.expectRequest(2, .DELETE, "http://localhost:8085/v1/projects/p/topics/orders", null);

    var sent = try orders.publish(&.{
        .{ .data = "hello", .attributes = &.{.{ .key = "origin", .value = "zig" }} },
        .{ .attributes = &.{.{ .key = "only", .value = "attr" }} },
    }, .{ .ordering_key = "user-42" });
    defer sent.deinit();
    try h.expectRequest(
        3,
        .POST,
        "http://localhost:8085/v1/projects/p/topics/orders:publish",
        "{\"messages\":[{\"data\":\"aGVsbG8=\",\"attributes\":{\"origin\":\"zig\"},\"orderingKey\":\"user-42\"}," ++
            "{\"attributes\":{\"only\":\"attr\"},\"orderingKey\":\"user-42\"}]}",
    );
    try testing.expectEqual(2, sent.value.message_ids.len);
    try testing.expectEqualStrings("11", sent.value.message_ids[0]);
    try testing.expectEqualStrings("12", sent.value.message_ids[1]);
    try h.expectRequestCount(4);
}

test "ids with % and + reach the path the way the server decodes them" {
    var h: Harness = undefined;
    try h.init(&.{.{ .respond = .{ .body = "{\"name\":\"projects/p/topics/a%41+b\"}" } }}, .{});
    defer h.deinit();
    var got = try h.client.topic("a%41+b").get();
    defer got.deinit();
    try h.expectRequest(0, .GET, "http://localhost:8085/v1/projects/p/topics/a%2541+b", null);
    try testing.expectEqualStrings("projects/p/topics/a%41+b", got.value.name);
}

test "invalid ids and messages fail before any request" {
    var h: Harness = undefined;
    try h.init(&.{}, .{});
    defer h.deinit();

    try testing.expectError(error.InvalidResourceId, h.client.topic("go").get());
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "invalid topic id") != null);
    try testing.expectError(error.InvalidResourceId, h.client.topic("googthing").create(.{}));
    try testing.expectError(error.InvalidResourceId, h.client.topic("9lives").delete());
    try testing.expectError(error.InvalidResourceId, h.client.topic("a/b/c").publish(&.{.{ .data = "x" }}, .{}));

    const orders = h.client.topic("orders");
    try testing.expectError(error.InvalidMessage, orders.publish(&.{}, .{}));
    try testing.expectError(error.InvalidMessage, orders.publish(&.{.{}}, .{}));
    try testing.expectEqualStrings("message 0 has no data and no attributes", h.diag.message());
    try testing.expectError(error.InvalidMessage, orders.publish(&.{.{ .data = "x" }}, .{ .ordering_key = "\xff" }));
    try h.expectRequestCount(0);
}

test "publish: retry_publish = false makes exactly one attempt" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .status = 504, .body = "{\"error\":{\"status\":\"DEADLINE_EXCEEDED\"}}" } },
        .{ .respond = .{ .body = "{\"messageIds\":[\"1\"]}" } },
    }, .{ .retry_publish = false });
    defer h.deinit();
    try testing.expectError(error.DeadlineExceeded, h.client.topic("orders").publish(&.{.{ .data = "x" }}, .{}));
    try h.expectRequestCount(1);
}

test "publish: retried by default" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .status = 504, .body = "{\"error\":{\"status\":\"DEADLINE_EXCEEDED\"}}" } },
        .{ .respond = .{ .body = "{\"messageIds\":[\"1\"]}" } },
    }, .{});
    defer h.deinit();
    var sent = try h.client.topic("orders").publish(&.{.{ .data = "x" }}, .{});
    defer sent.deinit();
    try h.expectRequestCount(2);
}

test "publish: ABORTED, CANCELLED and a 5xx UNKNOWN are retried, as Google's clients retry Publish" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .status = 409, .body = "{\"error\":{\"code\":409,\"status\":\"ABORTED\"}}" } },
        .{ .respond = .{ .status = 499, .body = "{\"error\":{\"code\":499,\"status\":\"CANCELLED\"}}" } },
        .{ .respond = .{ .status = 500, .body = "{\"error\":{\"code\":500,\"status\":\"UNKNOWN\"}}" } },
        .{ .respond = .{ .body = "{\"messageIds\":[\"1\"]}" } },
    }, .{});
    defer h.deinit();
    var sent = try h.client.topic("orders").publish(&.{.{ .data = "x" }}, .{});
    defer sent.deinit();
    try h.expectRequestCount(4);
}

test "publish: an HTTP status the client cannot place is Unknown and not retried" {
    // A proxy's 405 page maps to error.Unknown, like the server's UNKNOWN
    // status, but nothing about it will change on a second attempt.
    var h: Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .status = 405, .body = "<html>Method Not Allowed</html>" } },
        .{ .respond = .{ .body = "{\"messageIds\":[\"1\"]}" } },
    }, .{});
    defer h.deinit();
    try testing.expectError(error.Unknown, h.client.topic("orders").publish(&.{.{ .data = "x" }}, .{}));
    try h.expectRequestCount(1);
    try testing.expectEqual(405, h.diag.http_status);
}

test "publish: the wider retry set is still off with retry_publish = false" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .status = 409, .body = "{\"error\":{\"status\":\"ABORTED\"}}" } },
        .{ .respond = .{ .body = "{\"messageIds\":[\"1\"]}" } },
    }, .{ .retry_publish = false });
    defer h.deinit();
    try testing.expectError(error.Aborted, h.client.topic("orders").publish(&.{.{ .data = "x" }}, .{}));
    try h.expectRequestCount(1);
}

test "publish: a response with the wrong number of ids is InvalidResponse" {
    var h: Harness = undefined;
    try h.init(&.{.{ .respond = .{ .body = "{\"messageIds\":[\"1\"]}" } }}, .{});
    defer h.deinit();
    try testing.expectError(
        error.InvalidResponse,
        h.client.topic("orders").publish(&.{ .{ .data = "x" }, .{ .data = "y" } }, .{}),
    );
    try testing.expectEqualStrings("the publish response could not be decoded", h.diag.message());
}

test "create reports AlreadyExists with the server's message" {
    var h: Harness = undefined;
    try h.init(&.{.{ .respond = .{
        .status = 409,
        .body = "{\"error\":{\"code\":409,\"message\":\"Topic already exists\",\"status\":\"ALREADY_EXISTS\"}}",
    } }}, .{});
    defer h.deinit();
    try testing.expectError(error.AlreadyExists, h.client.topic("orders").create(.{}));
    try testing.expectEqual(409, h.diag.http_status);
    try testing.expectEqualStrings("Topic already exists", h.diag.message());
}

test "Owned results survive later calls and free independently" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = "{\"messageIds\":[\"first\"]}" } },
        .{ .respond = .{ .body = "{\"messageIds\":[\"second\"]}" } },
    }, .{});
    defer h.deinit();
    const orders = h.client.topic("orders");
    var a = try orders.publish(&.{.{ .data = "1" }}, .{});
    var b = try orders.publish(&.{.{ .data = "2" }}, .{});
    a.deinit();
    try testing.expectEqualStrings("second", b.value.message_ids[0]);
    b.deinit();
}

test "every allocation failure is reported as OutOfMemory without leaks" {
    const Run = struct {
        fn publish(gpa: std.mem.Allocator) !void {
            var fake: test_util.FakeTransport = .init(testing.allocator, &.{
                .{ .respond = .{ .status = 503, .body = "{\"error\":{\"status\":\"UNAVAILABLE\"}}" } },
                .{ .respond = .{ .body = "{\"messageIds\":[\"1\",\"2\"]}" } },
            });
            defer fake.deinit();
            var clock: test_util.FakeClock = .{};
            var client = try Client.init(gpa, clock.io(), .{
                .project_id = "p",
                .endpoint = .{ .url = "localhost:8085", .emulator = true },
                .transport = fake.transport(),
            });
            defer client.deinit();
            var sent = try client.topic("orders").publish(&.{
                .{ .data = "hello", .attributes = &.{.{ .key = "k", .value = "v" }} },
                .{ .data = "world" },
            }, .{ .ordering_key = "key" });
            sent.deinit();
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Run.publish, .{});
}

test "golden: create a topic with settings, and update it" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = "{\"name\":\"projects/p/topics/orders\",\"labels\":{\"env\":\"test\"},\"messageRetentionDuration\":\"3600s\"}" } },
        .{ .respond = .{ .body = "{\"name\":\"projects/p/topics/orders\",\"labels\":{\"env\":\"prod\"}}" } },
    }, .{});
    defer h.deinit();
    const orders = h.client.topic("orders");
    var created = try orders.create(.{ .labels = &.{.{ .key = "env", .value = "test" }}, .message_retention = .fromSeconds(3600) });
    defer created.deinit();
    try h.expectRequest(0, .PUT, "http://localhost:8085/v1/projects/p/topics/orders", "{\"labels\":{\"env\":\"test\"},\"messageRetentionDuration\":\"3600s\"}");
    try testing.expectEqual(std.Io.Duration.fromSeconds(3600), created.value.message_retention.?);

    var updated = try orders.update(.{ .labels = &.{.{ .key = "env", .value = "prod" }}, .message_retention = .clear });
    defer updated.deinit();
    try h.expectRequest(1, .PATCH, "http://localhost:8085/v1/projects/p/topics/orders", "{\"topic\":{\"labels\":{\"env\":\"prod\"}},\"updateMask\":\"labels,messageRetentionDuration\"}");
    try testing.expectEqualStrings("prod", updated.value.label("env").?);
    try testing.expectEqual(null, updated.value.message_retention);

    try testing.expectError(error.InvalidArgument, orders.update(.{}));
    try testing.expectError(error.InvalidArgument, orders.create(.{ .kms_key_name = "not a key" }));
    try h.expectRequestCount(2);
}

const core = @import("core");
const logging = @import("logging.zig");
const FakeReply = test_util.FakeTransport.Reply;

/// The body a publish of `messages` sends before any compression.
fn plainBody(messages: []const types.Message) ![]u8 {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    return testing.allocator.dupe(u8, try codec.encodePublish(arena.allocator(), messages, null));
}

/// A gzip body decompressed, as Pub/Sub decompresses one.
fn gunzip(body: []const u8) ![]u8 {
    var in: std.Io.Reader = .fixed(body);
    var window: [core.flate.max_window_len]u8 = undefined;
    var inflate: core.flate.Decompress = .init(&in, .gzip, &window);
    return inflate.reader.allocRemaining(testing.allocator, .unlimited);
}

test "publish: compression gzips a body of min_bytes or more, marked Content-Encoding: gzip" {
    var h: Harness = undefined;
    try h.init(&(.{FakeReply{ .respond = .{ .body = "{\"messageIds\":[\"1\",\"2\",\"3\",\"4\",\"5\"]}" } }} ** 5), .{});
    defer h.deinit();
    const orders = h.client.topic("orders");
    const messages: []const types.Message = &.{
        .{ .data = "{\"order\":1001,\"customer\":\"c-0042\",\"items\":3,\"status\":\"paid\"}" },
        .{ .data = "{\"order\":1002,\"customer\":\"c-0977\",\"items\":1,\"status\":\"shipped\"}" },
        .{ .data = "{\"order\":1003,\"customer\":\"c-0042\",\"items\":12,\"status\":\"refunded\"}" },
        .{ .data = "{\"order\":1004,\"customer\":\"c-0513\",\"items\":2,\"status\":\"paid\"}" },
        .{ .data = "{\"order\":1005,\"customer\":\"c-0977\",\"items\":7,\"status\":\"pending\"}" },
    };
    const plain = try plainBody(messages);
    defer testing.allocator.free(plain);
    const len: u32 = @intCast(plain.len);
    try testing.expect(len >= 240);
    // Levels 1 and 6 make different bytes of it, so the golden shows which
    // level was used.
    const fast = try core.gzip.compress(testing.allocator, plain, 1);
    defer testing.allocator.free(fast);
    const default = try core.gzip.compress(testing.allocator, plain, 6);
    defer testing.allocator.free(default);
    try testing.expect(!std.mem.eql(u8, fast, default));

    // The defaults (level 6, from 240 bytes), a body of exactly
    // min_bytes, and another level.
    for ([_]types.Compression{ .{}, .{ .min_bytes = len }, .{ .level = 1, .min_bytes = len } }, 0..) |compression, i| {
        var sent = try orders.publish(messages, .{ .compression = compression });
        sent.deinit();
        const r = try h.fake.request(i);
        try testing.expectEqualStrings("gzip", r.header("content-encoding").?);
        const made = try core.gzip.compress(testing.allocator, plain, compression.level);
        defer testing.allocator.free(made);
        try testing.expectEqualSlices(u8, made, r.body.?);
        const back = try gunzip(r.body.?);
        defer testing.allocator.free(back);
        try testing.expectEqualStrings(plain, back);
    }
    // A byte short of min_bytes, and no compression at all: as it is.
    for ([_]?types.Compression{ .{ .min_bytes = len + 1 }, null }, 3..) |compression, i| {
        var sent = try orders.publish(messages, .{ .compression = compression });
        sent.deinit();
        const r = try h.fake.request(i);
        try testing.expectEqual(null, r.header("content-encoding"));
        try testing.expectEqualStrings(plain, r.body.?);
    }
    try h.expectRequestCount(5);
}

test "publish: a compression level outside 1 to 9 fails before any request" {
    var h: Harness = undefined;
    try h.init(&.{}, .{});
    defer h.deinit();
    const orders = h.client.topic("orders");
    // Even for a body too short to be compressed.
    for ([_]u4{ 0, 10, 15 }) |level| {
        try testing.expectError(error.InvalidArgument, orders.publish(&.{.{ .data = "x" }}, .{ .compression = .{ .level = level } }));
    }
    try testing.expectEqualStrings("compression level 15 is outside 1 to 9", h.diag.message());
    try h.expectRequestCount(0);
}

test "publish: a compressed body that fails its check goes uncompressed, with a warning" {
    var h: Harness = undefined;
    try h.init(&.{.{ .respond = .{ .body = "{\"messageIds\":[\"1\"]}" } }}, .{});
    defer h.deinit();
    const messages: []const types.Message = &.{.{ .data = "x" ** 300 }};
    const plain = try plainBody(messages);
    defer testing.allocator.free(plain);
    core.gzip.test_corrupt_trailer = true;
    defer core.gzip.test_corrupt_trailer = false;
    logging.capture.reset();
    var sent = try h.client.topic("orders").publish(messages, .{ .compression = .{} });
    sent.deinit();
    const r = try h.fake.request(0);
    try testing.expectEqual(null, r.header("content-encoding"));
    try testing.expectEqualStrings(plain, r.body.?);
    try testing.expect(std.mem.indexOf(u8, logging.capture.text(), "did not decompress to itself") != null);
}

test "publish: running out of memory while compressing fails the publish, rather than sending it uncompressed" {
    var fake: test_util.FakeTransport = .init(testing.allocator, &.{.{ .respond = .{ .body = "{\"messageIds\":[\"1\"]}" } }});
    defer fake.deinit();
    var clock: test_util.FakeClock = .{};
    // The compressor's state is over 200 KiB; nothing else here comes near.
    var refuse: core.testing.RefuseOver = .{ .child = testing.allocator, .limit = 128 * 1024 };
    var client = try Client.init(refuse.allocator(), clock.io(), .{
        .project_id = "p",
        .endpoint = .{ .url = "localhost:8085", .emulator = true },
        .transport = fake.transport(),
    });
    defer client.deinit();
    const orders = client.topic("orders");
    try testing.expectError(error.OutOfMemory, orders.publish(&.{.{ .data = "compress me " ** 40 }}, .{ .compression = .{} }));
    try testing.expect(refuse.refused > 0);
    try testing.expectEqual(0, fake.requests.items.len);
    // Uncompressed, the same publish needs no such block.
    var sent = try orders.publish(&.{.{ .data = "compress me " ** 40 }}, .{});
    sent.deinit();
}

test "publish: a compressed publish is retried with the same bytes and the same header" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .status = 503, .body = "{\"error\":{\"status\":\"UNAVAILABLE\"}}" } },
        .{ .fail = error.ConnectionResetByPeer },
        .{ .respond = .{ .body = "{\"messageIds\":[\"1\"]}" } },
    }, .{});
    defer h.deinit();
    var sent = try h.client.topic("orders").publish(&.{.{ .data = "retried " ** 50 }}, .{ .compression = .{} });
    sent.deinit();
    try h.expectRequestCount(3);
    const first = try h.fake.request(0);
    for (1..3) |i| {
        const again = try h.fake.request(i);
        try testing.expectEqualStrings("gzip", again.header("content-encoding").?);
        try testing.expectEqualSlices(u8, first.body.?, again.body.?);
    }
}

test "publish: every allocation failure with compression is OutOfMemory without leaks" {
    const Run = struct {
        fn publish(gpa: std.mem.Allocator) !void {
            var fake: test_util.FakeTransport = .init(testing.allocator, &.{
                .{ .respond = .{ .status = 503, .body = "{\"error\":{\"status\":\"UNAVAILABLE\"}}" } },
                .{ .respond = .{ .body = "{\"messageIds\":[\"1\"]}" } },
            });
            defer fake.deinit();
            var clock: test_util.FakeClock = .{};
            var client = try Client.init(gpa, clock.io(), .{
                .project_id = "p",
                .endpoint = .{ .url = "localhost:8085", .emulator = true },
                .transport = fake.transport(),
            });
            defer client.deinit();
            var sent = try client.topic("orders").publish(&.{.{ .data = "compress me " ** 40 }}, .{ .compression = .{} });
            sent.deinit();
            try testing.expectEqualStrings("gzip", (try fake.request(1)).header("content-encoding").?);
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Run.publish, .{});
}
