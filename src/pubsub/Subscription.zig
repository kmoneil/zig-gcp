//! A subscription handle: a client pointer and a short id. Making one sends
//! nothing. It borrows both, so it must not outlive the client or the memory
//! behind `id`.

const Subscription = @This();

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
/// The client builds the full name, `projects/{project}/subscriptions/{id}`.
id: []const u8,

/// Creates the subscription on `config.topic_id` in the same project.
/// Messages published before this call are not delivered to it.
pub fn create(self: Subscription, config: types.SubscriptionConfig) Error!Owned(types.SubscriptionInfo) {
    const c = self.client;
    rpc.begin(c);
    try rpc.checkId(c, "subscription", self.id);
    try rpc.checkId(c, "topic", config.topic_id);
    try validate.subscriptionDeadline(config.ack_deadline_seconds, c.diagnostics);
    var scratch: std.heap.ArenaAllocator = .init(c.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const path = try url.resourcePath(a, c.project_id, .subscriptions, self.id, "");
    const topic_name = try url.resourceName(a, c.project_id, .topics, config.topic_id);
    const body = try codec.encodeSubscription(a, topic_name, config);
    return fetch(c, .{ .method = .PUT, .path = path, .body = body });
}

pub fn get(self: Subscription) Error!Owned(types.SubscriptionInfo) {
    const c = self.client;
    rpc.begin(c);
    try rpc.checkId(c, "subscription", self.id);
    var scratch: std.heap.ArenaAllocator = .init(c.gpa);
    defer scratch.deinit();
    const path = try url.resourcePath(scratch.allocator(), c.project_id, .subscriptions, self.id, "");
    return fetch(c, .{ .method = .GET, .path = path });
}

pub fn delete(self: Subscription) Error!void {
    const c = self.client;
    rpc.begin(c);
    try rpc.checkId(c, "subscription", self.id);
    var scratch: std.heap.ArenaAllocator = .init(c.gpa);
    defer scratch.deinit();
    const path = try url.resourcePath(scratch.allocator(), c.project_id, .subscriptions, self.id, "");
    return rpc.executeDiscard(c, .{ .method = .DELETE, .path = path });
}

/// Pulls up to `options.max_messages` messages. With no messages available
/// the server may hold the request open for a while before returning none,
/// unless `options.return_immediately` is set.
pub fn pull(self: Subscription, options: types.PullOptions) Error!Owned(types.PullResult) {
    const c = self.client;
    rpc.begin(c);
    try rpc.checkId(c, "subscription", self.id);
    var scratch: std.heap.ArenaAllocator = .init(c.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const path = try url.resourcePath(a, c.project_id, .subscriptions, self.id, ":pull");
    const body = try codec.encodePull(a, validate.clampPullMessages(options.max_messages), options.return_immediately);

    var result: Owned(types.PullResult) = try .init(c.gpa);
    errdefer result.deinit();
    const response = try rpc.execute(c, result.arena, .{ .method = .POST, .path = path, .body = body });
    result.value = codec.decodePull(result.arena.allocator(), response) catch |err|
        return rpc.decodeFailed(c, err, "pull");
    return result;
}

/// Acknowledges messages. Ids that do not fit in one 512 KB request go in
/// several; if a later request fails, earlier ones stay acknowledged and the
/// error is returned. An empty list sends nothing.
pub fn ack(self: Subscription, ack_ids: []const []const u8) Error!void {
    return self.sendAckIds(ack_ids, null);
}

/// Sets the ack deadline of the messages to `seconds` from now, 0 to 600.
/// Splits requests like `ack`.
pub fn modifyAckDeadline(self: Subscription, ack_ids: []const []const u8, seconds: u32) Error!void {
    rpc.begin(self.client);
    try validate.modifyDeadline(seconds, self.client.diagnostics);
    return self.sendAckIds(ack_ids, seconds);
}

/// Makes the messages available for redelivery now: `modifyAckDeadline(ack_ids, 0)`.
pub fn nack(self: Subscription, ack_ids: []const []const u8) Error!void {
    return self.modifyAckDeadline(ack_ids, 0);
}

fn sendAckIds(self: Subscription, ack_ids: []const []const u8, deadline_seconds: ?u32) Error!void {
    const c = self.client;
    rpc.begin(c);
    try rpc.checkId(c, "subscription", self.id);
    // The server rejects an empty list, and there is nothing to do.
    if (ack_ids.len == 0) return;
    try validate.ackIds(ack_ids, c.diagnostics);

    var scratch: std.heap.ArenaAllocator = .init(c.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const suffix = if (deadline_seconds == null) ":acknowledge" else ":modifyAckDeadline";
    const path = try url.resourcePath(a, c.project_id, .subscriptions, self.id, suffix);
    const fixed_bytes = (try codec.encodeAckIds(a, &.{}, deadline_seconds)).len;
    // Check every id before sending anything, so a bad id cannot leave the
    // call half done.
    for (ack_ids, 0..) |id, i| {
        if (fixed_bytes + codec.jsonStringLen(id) > validate.max_ack_request_bytes) {
            if (c.diagnostics) |d| d.print("ack id {d} is too long to fit in a request", .{i});
            return error.InvalidArgument;
        }
    }
    var chunks: codec.AckChunks = .{
        .ids = ack_ids,
        .fixed_bytes = fixed_bytes,
        .max_bytes = validate.max_ack_request_bytes,
        .max_ids = validate.max_ack_ids_per_request,
    };
    var chunk_arena: std.heap.ArenaAllocator = .init(c.gpa);
    defer chunk_arena.deinit();
    while (true) {
        const chunk = chunks.next() catch |err| {
            if (c.diagnostics) |d| d.print("ack id {d} is too long to fit in a request", .{chunks.pos});
            return err;
        } orelse break;
        _ = chunk_arena.reset(.retain_capacity);
        const body = try codec.encodeAckIds(chunk_arena.allocator(), chunk, deadline_seconds);
        try rpc.executeDiscard(c, .{ .method = .POST, .path = path, .body = body });
    }
}

fn fetch(c: *Client, call: rpc.Call) Error!Owned(types.SubscriptionInfo) {
    var result: Owned(types.SubscriptionInfo) = try .init(c.gpa);
    errdefer result.deinit();
    const body = try rpc.execute(c, result.arena, call);
    result.value = codec.decodeSubscription(result.arena.allocator(), body) catch |err|
        return rpc.decodeFailed(c, err, "subscription");
    return result;
}

const testing = std.testing;
const test_util = @import("test_util.zig");
const Harness = test_util.Harness;

const empty_ok: test_util.FakeTransport.Reply = .{ .respond = .{ .body = "{\n}\n" } };

test "golden: create, get, delete, pull, ack, modifyAckDeadline and nack" {
    const subscription_body =
        \\{"name":"projects/p/subscriptions/work","topic":"projects/p/topics/orders",
        \\"pushConfig":{},"ackDeadlineSeconds":30,"enableMessageOrdering":true,"messageRetentionDuration":"604800s"}
    ;
    var h: Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = subscription_body } },
        .{ .respond = .{ .body = subscription_body } },
        empty_ok,
        .{ .respond = .{ .body =
        \\{"receivedMessages":[{"ackId":"projects/p/subscriptions/work:7","message":{"data":"aGVsbG8=",
        \\"attributes":{"origin":"zig"},"messageId":"42","publishTime":"2026-09-18T10:00:00.123Z"},"deliveryAttempt":1}]}
        } },
        empty_ok,
        empty_ok,
        empty_ok,
    }, .{});
    defer h.deinit();
    const work = h.client.subscription("work");
    const base = "http://localhost:8085/v1/projects/p/subscriptions/work";

    var created = try work.create(.{ .topic_id = "orders", .ack_deadline_seconds = 30, .enable_message_ordering = true });
    defer created.deinit();
    try h.expectRequest(0, .PUT, base, "{\"topic\":\"projects/p/topics/orders\",\"ackDeadlineSeconds\":30,\"enableMessageOrdering\":true}");
    try testing.expectEqualStrings("projects/p/subscriptions/work", created.value.name);
    try testing.expectEqualStrings("projects/p/topics/orders", created.value.topic);
    try testing.expectEqual(30, created.value.ack_deadline_seconds);
    try testing.expect(created.value.enable_message_ordering);

    var got = try work.get();
    defer got.deinit();
    try h.expectRequest(1, .GET, base, null);

    try work.delete();
    try h.expectRequest(2, .DELETE, base, null);

    var batch = try work.pull(.{ .max_messages = 10 });
    defer batch.deinit();
    try h.expectRequest(3, .POST, base ++ ":pull", "{\"maxMessages\":10}");
    const m = batch.value.messages[0];
    try testing.expectEqualStrings("projects/p/subscriptions/work:7", m.ack_id);
    try testing.expectEqualStrings("hello", m.data);
    try testing.expectEqualStrings("zig", m.attribute("origin").?);
    try testing.expectEqualStrings("42", m.message_id);
    try testing.expectEqual(1, m.delivery_attempt);

    try work.ack(&.{m.ack_id});
    try h.expectRequest(4, .POST, base ++ ":acknowledge", "{\"ackIds\":[\"projects/p/subscriptions/work:7\"]}");

    try work.modifyAckDeadline(&.{m.ack_id}, 600);
    try h.expectRequest(5, .POST, base ++ ":modifyAckDeadline", "{\"ackIds\":[\"projects/p/subscriptions/work:7\"],\"ackDeadlineSeconds\":600}");

    try work.nack(&.{m.ack_id});
    try h.expectRequest(6, .POST, base ++ ":modifyAckDeadline", "{\"ackIds\":[\"projects/p/subscriptions/work:7\"],\"ackDeadlineSeconds\":0}");
    try h.expectRequestCount(7);
}

test "pull clamps max_messages and passes return_immediately" {
    var h: Harness = undefined;
    try h.init(&.{ empty_ok, .{ .respond = .{ .body = "" } } }, .{});
    defer h.deinit();
    const work = h.client.subscription("work");
    var none = try work.pull(.{ .max_messages = 0, .return_immediately = true });
    defer none.deinit();
    try testing.expectEqual(0, none.value.messages.len);
    try h.expectRequest(0, .POST, "http://localhost:8085/v1/projects/p/subscriptions/work:pull", "{\"maxMessages\":1,\"returnImmediately\":true}");
    // An entirely empty body is a pull with no messages.
    var blank = try work.pull(.{ .max_messages = 5000 });
    defer blank.deinit();
    try testing.expectEqual(0, blank.value.messages.len);
    try h.expectRequest(1, .POST, "http://localhost:8085/v1/projects/p/subscriptions/work:pull", "{\"maxMessages\":1000}");
}

test "ack with no ids sends nothing" {
    var h: Harness = undefined;
    try h.init(&.{}, .{});
    defer h.deinit();
    try h.client.subscription("work").ack(&.{});
    try h.client.subscription("work").nack(&.{});
    try h.expectRequestCount(0);
}

test "ack chunking: ids crossing 512 KB go in several requests, in order" {
    const gpa = testing.allocator;
    // 1200 ids of 1000 bytes: 1003 bytes each on the wire with quotes and a
    // comma, so 522 fit under 512 KiB with the 13-byte envelope.
    const id_count = 1200;
    const storage = try gpa.alloc(u8, id_count * 1000);
    defer gpa.free(storage);
    const ids = try gpa.alloc([]const u8, id_count);
    defer gpa.free(ids);
    for (ids, 0..) |*id, i| {
        const s = storage[i * 1000 ..][0..1000];
        @memset(s, 'a' + @as(u8, @intCast(i % 26)));
        _ = std.fmt.bufPrint(s, "{d:0>6}", .{i}) catch unreachable;
        id.* = s;
    }
    var h: Harness = undefined;
    try h.init(&.{ empty_ok, empty_ok, empty_ok }, .{});
    defer h.deinit();
    try h.client.subscription("work").ack(ids);
    try h.expectRequestCount(3);

    var seen: usize = 0;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    for (h.fake.requests.items, [_]usize{ 522, 522, 156 }) |r, expected| {
        try testing.expect(r.body.?.len <= 512 * 1024);
        const Body = struct { ackIds: []const []const u8 };
        const body = try std.json.parseFromSliceLeaky(Body, arena.allocator(), r.body.?, .{});
        try testing.expectEqual(expected, body.ackIds.len);
        for (body.ackIds) |id| {
            try testing.expectEqualStrings(ids[seen], id);
            seen += 1;
        }
    }
    try testing.expectEqual(id_count, seen);
}

test "ack chunking: many short ids are capped at 2500 per request" {
    const gpa = testing.allocator;
    const ids = try gpa.alloc([]const u8, 6000);
    defer gpa.free(ids);
    @memset(ids, "projects/p/subscriptions/work:1");
    var h: Harness = undefined;
    try h.init(&.{ empty_ok, empty_ok, empty_ok }, .{});
    defer h.deinit();
    try h.client.subscription("work").modifyAckDeadline(ids, 60);
    try h.expectRequestCount(3);
}

test "ack chunking: a failed chunk stops the call; earlier chunks stay acked" {
    const gpa = testing.allocator;
    const ids = try gpa.alloc([]const u8, 5001);
    defer gpa.free(ids);
    @memset(ids, "x");
    var h: Harness = undefined;
    try h.init(&.{
        empty_ok,
        .{ .respond = .{ .status = 400, .body = "{\"error\":{\"status\":\"INVALID_ARGUMENT\",\"message\":\"Invalid ack id\"}}" } },
        empty_ok,
    }, .{});
    defer h.deinit();
    try testing.expectError(error.InvalidArgument, h.client.subscription("work").ack(ids));
    try h.expectRequestCount(2);
    try testing.expectEqualStrings("Invalid ack id", h.diag.message());
}

test "ack: a too-long id anywhere in the list fails before any request" {
    // Regression: the check ran chunk by chunk, so earlier chunks were acked
    // before the call failed.
    const gpa = testing.allocator;
    const huge = try gpa.alloc(u8, 600 * 1024);
    defer gpa.free(huge);
    @memset(huge, 'z');
    const ids = try gpa.alloc([]const u8, 3001);
    defer gpa.free(ids);
    @memset(ids[0..3000], "projects/p/subscriptions/work:1");
    ids[3000] = huge;
    var h: Harness = undefined;
    try h.init(&.{ empty_ok, empty_ok }, .{});
    defer h.deinit();
    try testing.expectError(error.InvalidArgument, h.client.subscription("work").ack(ids));
    try h.expectRequestCount(0);
    try testing.expectEqualStrings("ack id 3000 is too long to fit in a request", h.diag.message());
}

test "ack: an id too long for any request is InvalidArgument before sending" {
    const gpa = testing.allocator;
    const huge = try gpa.alloc(u8, 512 * 1024);
    defer gpa.free(huge);
    @memset(huge, 'z');
    var h: Harness = undefined;
    try h.init(&.{}, .{});
    defer h.deinit();
    try testing.expectError(error.InvalidArgument, h.client.subscription("work").ack(&.{huge}));
    try h.expectRequestCount(0);
    try testing.expectEqualStrings("ack id 0 is too long to fit in a request", h.diag.message());
}

test "invalid arguments fail before any request" {
    var h: Harness = undefined;
    try h.init(&.{}, .{});
    defer h.deinit();
    const work = h.client.subscription("work");
    try testing.expectError(error.InvalidArgument, work.modifyAckDeadline(&.{"a"}, 601));
    try testing.expectError(error.InvalidArgument, work.ack(&.{ "a", "\xc0" }));
    try testing.expectError(error.InvalidArgument, work.create(.{ .topic_id = "orders", .ack_deadline_seconds = 9 }));
    try testing.expectError(error.InvalidResourceId, work.create(.{ .topic_id = "x" }));
    try testing.expectError(error.InvalidResourceId, h.client.subscription("s").pull(.{}));
    try testing.expectError(error.InvalidResourceId, h.client.subscription("goog-sub").ack(&.{"a"}));
    try h.expectRequestCount(0);
}

test "a subscription whose topic was deleted" {
    var h: Harness = undefined;
    try h.init(&.{.{ .respond = .{ .body = "{\"name\":\"projects/p/subscriptions/work\",\"topic\":\"_deleted-topic_\"}" } }}, .{});
    defer h.deinit();
    var got = try h.client.subscription("work").get();
    defer got.deinit();
    try testing.expectEqualStrings("_deleted-topic_", got.value.topic);
    try testing.expectEqual(0, got.value.ack_deadline_seconds);
}
