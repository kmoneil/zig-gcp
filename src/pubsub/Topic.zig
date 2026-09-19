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
/// reports `error.AlreadyExists`.
pub fn create(self: Topic, config: types.TopicConfig) Error!Owned(types.TopicInfo) {
    const c = self.client;
    rpc.begin(c);
    try rpc.checkId(c, "topic", self.id);
    var scratch: std.heap.ArenaAllocator = .init(c.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const path = try url.resourcePath(a, c.project_id, .topics, self.id, "");
    const body = try codec.encodeTopic(a, config);
    return fetch(c, .{ .method = .PUT, .path = path, .body = body });
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
/// of `messages`. Limits are checked first (`error.InvalidMessage`).
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
    var scratch: std.heap.ArenaAllocator = .init(c.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const path = try url.resourcePath(a, c.project_id, .topics, self.id, ":publish");
    const body = try codec.encodePublish(a, messages, options.ordering_key);

    var result: Owned(types.PublishResult) = try .init(c.gpa);
    errdefer result.deinit();
    const response = try rpc.execute(c, result.arena, .{
        .method = .POST,
        .path = path,
        .body = body,
        .retry = c.retry_publish,
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
