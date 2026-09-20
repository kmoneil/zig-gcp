//! JSON and base64: request bodies out, response bodies in.
//!
//! Zig field names are snake_case and the wire uses the API's camelCase. The
//! private `Wire*` structs mirror the wire exactly and never leave this file.
//! Every response field is optional, `null` counts as absent (the proto3 JSON
//! rule), and unknown fields are ignored, so new server fields never break
//! old clients.
//!
//! Encoders assume validated input: `validate.zig` has already rejected
//! invalid UTF-8, which `std.json.Stringify` would otherwise copy through
//! as invalid JSON.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Stringify = std.json.Stringify;
const base64 = @import("core").base64;
const types = @import("types.zig");
const test_util = @import("test_util.zig");

pub const DecodeError = error{ InvalidResponse, OutOfMemory };

// Requests

/// The `topics.publish` body. An empty ordering key is left out.
pub fn encodePublish(
    arena: Allocator,
    messages: []const types.Message,
    ordering_key: ?[]const u8,
) Allocator.Error![]u8 {
    return render(arena, PublishBody{ .messages = messages, .ordering_key = ordering_key });
}

const PublishBody = struct {
    messages: []const types.Message,
    ordering_key: ?[]const u8,

    fn write(self: PublishBody, jw: *Stringify) Stringify.Error!void {
        try jw.beginObject();
        try jw.objectField("messages");
        try jw.beginArray();
        for (self.messages) |m| {
            try jw.beginObject();
            if (m.data.len > 0) {
                try jw.objectField("data");
                try base64.writeJsonString(jw, m.data);
            }
            if (m.attributes.len > 0) {
                try jw.objectField("attributes");
                try jw.beginObject();
                for (m.attributes) |a| {
                    try jw.objectField(a.key);
                    try jw.write(a.value);
                }
                try jw.endObject();
            }
            if (self.ordering_key) |key| if (key.len > 0) {
                try jw.objectField("orderingKey");
                try jw.write(key);
            };
            try jw.endObject();
        }
        try jw.endArray();
        try jw.endObject();
    }
};


/// The `subscriptions.pull` body. `max_messages` must already be clamped.
pub fn encodePull(arena: Allocator, max_messages: u32, return_immediately: bool) Allocator.Error![]u8 {
    return render(arena, PullBody{ .max_messages = max_messages, .return_immediately = return_immediately });
}

const PullBody = struct {
    max_messages: u32,
    return_immediately: bool,

    fn write(self: PullBody, jw: *Stringify) Stringify.Error!void {
        try jw.beginObject();
        try jw.objectField("maxMessages");
        try jw.write(self.max_messages);
        if (self.return_immediately) {
            try jw.objectField("returnImmediately");
            try jw.write(true);
        }
        try jw.endObject();
    }
};

/// The `acknowledge` body, or the `modifyAckDeadline` body when
/// `deadline_seconds` is set.
pub fn encodeAckIds(arena: Allocator, ack_ids: []const []const u8, deadline_seconds: ?u32) Allocator.Error![]u8 {
    return render(arena, AckBody{ .ack_ids = ack_ids, .deadline_seconds = deadline_seconds });
}

const AckBody = struct {
    ack_ids: []const []const u8,
    deadline_seconds: ?u32,

    fn write(self: AckBody, jw: *Stringify) Stringify.Error!void {
        try jw.beginObject();
        try jw.objectField("ackIds");
        try jw.write(self.ack_ids);
        if (self.deadline_seconds) |seconds| {
            try jw.objectField("ackDeadlineSeconds");
            try jw.write(seconds);
        }
        try jw.endObject();
    }
};

/// The `subscriptions.create` body. `topic_name` is the full resource name.
pub fn encodeSubscription(
    arena: Allocator,
    topic_name: []const u8,
    config: types.SubscriptionConfig,
) Allocator.Error![]u8 {
    return render(arena, SubscriptionBody{ .topic_name = topic_name, .config = config });
}

const SubscriptionBody = struct {
    topic_name: []const u8,
    config: types.SubscriptionConfig,

    fn write(self: SubscriptionBody, jw: *Stringify) Stringify.Error!void {
        try jw.beginObject();
        try jw.objectField("topic");
        try jw.write(self.topic_name);
        try jw.objectField("ackDeadlineSeconds");
        try jw.write(self.config.ack_deadline_seconds);
        try jw.objectField("enableMessageOrdering");
        try jw.write(self.config.enable_message_ordering);
        try jw.endObject();
    }
};

/// The `topics.create` body. `TopicConfig` has no fields yet.
pub fn encodeTopic(arena: Allocator, config: types.TopicConfig) Allocator.Error![]u8 {
    _ = config;
    return arena.dupe(u8, "{}");
}

/// Runs `body.write` into a fresh buffer. The only way an allocating writer
/// fails is running out of memory.
fn render(arena: Allocator, body: anytype) Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    var jw: Stringify = .{ .writer = &out.writer };
    body.write(&jw) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

/// The exact length of `encodePublish(messages, ordering_key)`, computed
/// without encoding anything.
pub fn publishBodyLen(messages: []const types.Message, ordering_key: ?[]const u8) usize {
    const key = ordering_key orelse "";
    // Parenthesized: `a + b -| 1` would parse as `(a + b) -| 1`.
    var n: usize = "{\"messages\":[]}".len + (messages.len -| 1); // commas between messages
    for (messages) |m| {
        var fields: usize = 0;
        n += "{}".len;
        if (m.data.len > 0) {
            n += "\"data\":\"\"".len + base64.encodedLen(m.data.len);
            fields += 1;
        }
        if (m.attributes.len > 0) {
            n += "\"attributes\":{}".len + m.attributes.len - 1; // commas between pairs
            for (m.attributes) |a| n += jsonStringLen(a.key) + ":".len + jsonStringLen(a.value);
            fields += 1;
        }
        if (key.len > 0) {
            n += "\"orderingKey\":".len + jsonStringLen(key);
            fields += 1;
        }
        n += fields -| 1; // commas between fields
    }
    return n;
}

/// The bytes `text` takes as a JSON string, quotes included, exactly as
/// `std.json.Stringify` writes it.
pub fn jsonStringLen(text: []const u8) usize {
    var n: usize = 2;
    for (text) |c| n += switch (c) {
        '"', '\\', 0x08, 0x0C, '\n', '\r', '\t' => 2,
        0x00...0x07, 0x0B, 0x0E...0x1F => 6,
        else => 1,
    };
    return n;
}

/// Splits ack ids into request-sized groups: each group's body is at most
/// `max_bytes` and holds at most `max_ids` ids. Groups are greedy and keep
/// the input order.
pub const AckChunks = struct {
    ids: []const []const u8,
    /// Body bytes besides the ids: `{"ackIds":[]}` plus any deadline field.
    fixed_bytes: usize,
    max_bytes: usize,
    max_ids: usize,
    pos: usize = 0,

    /// The next group, or null when done. `error.InvalidArgument` when a
    /// single id cannot fit in a request on its own.
    pub fn next(it: *AckChunks) error{InvalidArgument}!?[]const []const u8 {
        if (it.pos >= it.ids.len) return null;
        var size = it.fixed_bytes;
        var end = it.pos;
        while (end < it.ids.len and end - it.pos < it.max_ids) : (end += 1) {
            const comma: usize = @intFromBool(end > it.pos);
            const add = jsonStringLen(it.ids[end]) + comma;
            if (size + add > it.max_bytes) break;
            size += add;
        }
        if (end == it.pos) return error.InvalidArgument;
        defer it.pos = end;
        return it.ids[it.pos..end];
    }
};

// Responses

const parse_options: std.json.ParseOptions = .{
    .ignore_unknown_fields = true,
    // Proto3 JSON parsers keep the last duplicate rather than failing.
    .duplicate_field_behavior = .use_last,
    // Unescaped strings point into the body instead of being copied.
    .allocate = .alloc_if_needed,
};

const WireTopic = struct {
    name: ?[]const u8 = null,
};

const WireTopicList = struct {
    topics: ?[]const WireTopic = null,
    nextPageToken: ?[]const u8 = null,
};

const WireSubscription = struct {
    name: ?[]const u8 = null,
    topic: ?[]const u8 = null,
    ackDeadlineSeconds: ?u32 = null,
    enableMessageOrdering: ?bool = null,
};

const WireSubscriptionList = struct {
    subscriptions: ?[]const WireSubscription = null,
    nextPageToken: ?[]const u8 = null,
};

const WirePublishResponse = struct {
    messageIds: ?[]const []const u8 = null,
};

const WireMessage = struct {
    data: ?[]const u8 = null,
    attributes: ?std.json.ArrayHashMap(?[]const u8) = null,
    messageId: ?[]const u8 = null,
    publishTime: ?[]const u8 = null,
    orderingKey: ?[]const u8 = null,
};

const WireReceivedMessage = struct {
    ackId: ?[]const u8 = null,
    message: ?WireMessage = null,
    deliveryAttempt: ?u32 = null,
};

const WirePullResponse = struct {
    receivedMessages: ?[]const WireReceivedMessage = null,
};

/// Parses `body` into `T`. A blank body counts as `{}`: a pull with no
/// messages may return nothing at all.
fn parseWire(comptime T: type, arena: Allocator, body: []const u8) DecodeError!T {
    const trimmed = std.mem.trim(u8, body, " \t\r\n");
    const text = if (trimmed.len == 0) "{}" else trimmed;
    return std.json.parseFromSliceLeaky(T, arena, text, parse_options) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidResponse,
    };
}

fn nonEmpty(text: ?[]const u8) ?[]const u8 {
    const t = text orelse return null;
    return if (t.len == 0) null else t;
}

pub fn decodeTopic(arena: Allocator, body: []const u8) DecodeError!types.TopicInfo {
    const wire = try parseWire(WireTopic, arena, body);
    return .{ .name = wire.name orelse "" };
}

pub fn decodeTopicPage(arena: Allocator, body: []const u8) DecodeError!types.TopicPage {
    const wire = try parseWire(WireTopicList, arena, body);
    const list = wire.topics orelse &.{};
    const topics = try arena.alloc(types.TopicInfo, list.len);
    for (list, topics) |t, *out| out.* = .{ .name = t.name orelse "" };
    return .{ .topics = topics, .next_page_token = nonEmpty(wire.nextPageToken) };
}

fn subscriptionFromWire(w: WireSubscription) types.SubscriptionInfo {
    return .{
        .name = w.name orelse "",
        .topic = w.topic orelse "",
        .ack_deadline_seconds = w.ackDeadlineSeconds orelse 0,
        .enable_message_ordering = w.enableMessageOrdering orelse false,
    };
}

pub fn decodeSubscription(arena: Allocator, body: []const u8) DecodeError!types.SubscriptionInfo {
    return subscriptionFromWire(try parseWire(WireSubscription, arena, body));
}

pub fn decodeSubscriptionPage(arena: Allocator, body: []const u8) DecodeError!types.SubscriptionPage {
    const wire = try parseWire(WireSubscriptionList, arena, body);
    const list = wire.subscriptions orelse &.{};
    const subscriptions = try arena.alloc(types.SubscriptionInfo, list.len);
    for (list, subscriptions) |s, *out| out.* = subscriptionFromWire(s);
    return .{ .subscriptions = subscriptions, .next_page_token = nonEmpty(wire.nextPageToken) };
}

/// The publish response must hold one id per published message.
pub fn decodePublish(arena: Allocator, body: []const u8, message_count: usize) DecodeError!types.PublishResult {
    const wire = try parseWire(WirePublishResponse, arena, body);
    const ids = wire.messageIds orelse &.{};
    if (ids.len != message_count) return error.InvalidResponse;
    return .{ .message_ids = ids };
}

pub fn decodePull(arena: Allocator, body: []const u8) DecodeError!types.PullResult {
    const wire = try parseWire(WirePullResponse, arena, body);
    const list = wire.receivedMessages orelse &.{};
    const messages = try arena.alloc(types.ReceivedMessage, list.len);
    for (list, messages) |r, *out| {
        const m = r.message orelse WireMessage{};
        out.* = .{
            .ack_id = r.ackId orelse "",
            .message_id = m.messageId orelse "",
            .data = decodeBase64(arena, m.data orelse "") catch |err| switch (err) {
                error.InvalidBase64 => return error.InvalidResponse,
                error.OutOfMemory => return error.OutOfMemory,
            },
            .attributes = try attributesFromWire(arena, m.attributes),
            .publish_time = m.publishTime orelse "",
            .ordering_key = m.orderingKey orelse "",
            .delivery_attempt = r.deliveryAttempt orelse 0,
        };
    }
    return .{ .messages = messages };
}

fn attributesFromWire(
    arena: Allocator,
    wire: ?std.json.ArrayHashMap(?[]const u8),
) Allocator.Error![]const types.Attribute {
    const map = (wire orelse return &.{}).map;
    const out = try arena.alloc(types.Attribute, map.count());
    for (map.keys(), map.values(), out) |k, v, *a| a.* = .{ .key = k, .value = v orelse "" };
    return out;
}

/// Base64: the same rules for every Google JSON API, so core owns them.
pub const Base64Error = base64.Error;
pub const decodeBase64 = base64.decode;

// Tests

const testing = std.testing;
const ByteGen = test_util.ByteGen;

test "golden: publish body" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expectEqualStrings(
        \\{"messages":[{"data":"aGVsbG8=","attributes":{"origin":"zig"},"orderingKey":"user-42"}]}
    , try encodePublish(a, &.{
        .{ .data = "hello", .attributes = &.{.{ .key = "origin", .value = "zig" }} },
    }, "user-42"));

    // Empty data and empty attributes are left out; so is an empty key.
    try testing.expectEqualStrings(
        \\{"messages":[{"attributes":{"k":""}},{"data":"AA=="}]}
    , try encodePublish(a, &.{
        .{ .attributes = &.{.{ .key = "k", .value = "" }} },
        .{ .data = "\x00" },
    }, ""));

    // Strings are escaped; non-ASCII UTF-8 passes through unchanged.
    try testing.expectEqualStrings(
        \\{"messages":[{"data":"eA==","attributes":{"q\"b\\":"\n\u0001é"}}]}
    , try encodePublish(a, &.{
        .{ .data = "x", .attributes = &.{.{ .key = "q\"b\\", .value = "\n\x01é" }} },
    }, null));
}

test "golden: pull, ack, modifyAckDeadline, create bodies" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expectEqualStrings("{\"maxMessages\":10}", try encodePull(a, 10, false));
    try testing.expectEqualStrings(
        "{\"maxMessages\":1000,\"returnImmediately\":true}",
        try encodePull(a, 1000, true),
    );
    try testing.expectEqualStrings(
        "{\"ackIds\":[\"projects/p/subscriptions/s:1\",\"x\"]}",
        try encodeAckIds(a, &.{ "projects/p/subscriptions/s:1", "x" }, null),
    );
    try testing.expectEqualStrings(
        "{\"ackIds\":[\"a\"],\"ackDeadlineSeconds\":0}",
        try encodeAckIds(a, &.{"a"}, 0),
    );
    try testing.expectEqualStrings(
        "{\"topic\":\"projects/p/topics/t%41\",\"ackDeadlineSeconds\":30,\"enableMessageOrdering\":true}",
        try encodeSubscription(a, "projects/p/topics/t%41", .{
            .topic_id = "t%41",
            .ack_deadline_seconds = 30,
            .enable_message_ordering = true,
        }),
    );
    try testing.expectEqualStrings("{}", try encodeTopic(a, .{}));
}

test "decode pull: full emulator response" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    // Captured from the emulator, plus a deliveryAttempt.
    const body =
        \\{
        \\  "receivedMessages": [{
        \\    "ackId": "projects/test/subscriptions/smoke-sub:1",
        \\    "message": {
        \\      "data": "aGVsbG8=",
        \\      "attributes": {
        \\        "origin": "zig"
        \\      },
        \\      "messageId": "1",
        \\      "publishTime": "2026-09-18T23:12:18.388Z"
        \\    },
        \\    "deliveryAttempt": 2
        \\  }, {
        \\    "ackId": "projects/test/subscriptions/smoke-sub:2",
        \\    "message": {
        \\      "attributes": {
        \\        "only": "attr"
        \\      },
        \\      "messageId": "2",
        \\      "publishTime": "2026-09-18T23:12:18.388Z",
        \\      "orderingKey": "k1"
        \\    }
        \\  }]
        \\}
    ;
    const result = try decodePull(arena.allocator(), body);
    try testing.expectEqual(2, result.messages.len);
    const first = result.messages[0];
    try testing.expectEqualStrings("projects/test/subscriptions/smoke-sub:1", first.ack_id);
    try testing.expectEqualStrings("1", first.message_id);
    try testing.expectEqualStrings("hello", first.data);
    try testing.expectEqualStrings("zig", first.attribute("origin").?);
    try testing.expectEqualStrings("2026-09-18T23:12:18.388Z", first.publish_time);
    try testing.expectEqualStrings("", first.ordering_key);
    try testing.expectEqual(2, first.delivery_attempt);
    const second = result.messages[1];
    try testing.expectEqualStrings("", second.data);
    try testing.expectEqualStrings("attr", second.attribute("only").?);
    try testing.expectEqualStrings("k1", second.ordering_key);
    try testing.expectEqual(0, second.delivery_attempt);
}

test "decode pull: empty, blank, missing and null fields" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "", "  \n", "{}", "{\n}\n", "{\"receivedMessages\":[]}", "{\"receivedMessages\":null}" }) |body| {
        try testing.expectEqual(0, (try decodePull(a, body)).messages.len);
    }
    const sparse = try decodePull(a,
        \\{"receivedMessages":[{},{"message":null,"ackId":null},{"message":{"attributes":{"k":null}}}]}
    );
    try testing.expectEqual(3, sparse.messages.len);
    for (sparse.messages) |m| {
        try testing.expectEqualStrings("", m.ack_id);
        try testing.expectEqualStrings("", m.data);
    }
    try testing.expectEqualStrings("", sparse.messages[2].attribute("k").?);
}

test "decode pull: unknown fields are ignored" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const result = try decodePull(arena.allocator(),
        \\{"receivedMessages":[{"ackId":"a","futureField":{"x":[1,2,{"y":null}]},
        \\"message":{"data":"eA==","schemaRevision":"r1","nested":{"deep":true}}}],"extra":1}
    );
    try testing.expectEqualStrings("x", result.messages[0].data);
}

test "decode pull: base64 without padding and URL-safe" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const result = try decodePull(arena.allocator(),
        \\{"receivedMessages":[{"message":{"data":"aGk"}},{"message":{"data":"-_-_"}},{"message":{"data":"+/+/"}}]}
    );
    try testing.expectEqualStrings("hi", result.messages[0].data);
    try testing.expectEqualSlices(u8, "\xfb\xff\xbf", result.messages[1].data);
    try testing.expectEqualSlices(u8, "\xfb\xff\xbf", result.messages[2].data);
}

test "decode pull: escaped strings are unescaped" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const result = try decodePull(arena.allocator(),
        \\{"receivedMessages":[{"ackId":"a\/b\u0041","message":{"attributes":{"k\"":"v\n\u00e9"}}}]}
    );
    const m = result.messages[0];
    try testing.expectEqualStrings("a/bA", m.ack_id);
    try testing.expectEqualStrings("v\né", m.attribute("k\"").?);
}

test "decode pull: malformed bodies are InvalidResponse" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bad = [_][]const u8{
        "<html>502</html>",
        "{",
        "[]",
        "null",
        "{\"receivedMessages\":{}}",
        "{\"receivedMessages\":[{\"message\":{\"data\":\"!!!!\"}}]}",
        "{\"receivedMessages\":[{\"message\":{\"data\":\"a\"}}]}",
        "{\"receivedMessages\":[{\"deliveryAttempt\":-1}]}",
        "{\"receivedMessages\":[{\"deliveryAttempt\":4294967296}]}",
        "{} trailing",
    };
    for (bad) |body| {
        if (decodePull(a, body)) |_| {
            std.debug.print("accepted malformed body: {s}\n", .{body});
            return error.TestUnexpectedSuccess;
        } else |err| try testing.expectEqual(error.InvalidResponse, err);
    }
}

test "decode pull: deliveryAttempt as a string is accepted" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const result = try decodePull(arena.allocator(), "{\"receivedMessages\":[{\"deliveryAttempt\":\"5\"}]}");
    try testing.expectEqual(5, result.messages[0].delivery_attempt);
}

test "decode topics, subscriptions and pages" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expectEqualStrings("projects/test/topics/smoke", (try decodeTopic(a, "{\n  \"name\": \"projects/test/topics/smoke\"\n}\n")).name);

    const page = try decodeTopicPage(a,
        \\{"topics":[{"name":"projects/test/topics/page-1"},{"name":"projects/test/topics/page-2"}],
        \\"nextPageToken":"projects/test/topics/page-3"}
    );
    try testing.expectEqual(2, page.topics.len);
    try testing.expectEqualStrings("projects/test/topics/page-2", page.topics[1].name);
    try testing.expectEqualStrings("projects/test/topics/page-3", page.next_page_token.?);

    const last = try decodeTopicPage(a, "{\"topics\":[{\"name\":\"x\"}],\"nextPageToken\":\"\"}");
    try testing.expectEqual(null, last.next_page_token);
    try testing.expectEqual(0, (try decodeTopicPage(a, "{}")).topics.len);

    const sub = try decodeSubscription(a,
        \\{"name":"projects/test/subscriptions/smoke-sub","topic":"projects/test/topics/smoke",
        \\"pushConfig":{},"ackDeadlineSeconds":10,"messageRetentionDuration":"604800s"}
    );
    try testing.expectEqualStrings("projects/test/subscriptions/smoke-sub", sub.name);
    try testing.expectEqualStrings("projects/test/topics/smoke", sub.topic);
    try testing.expectEqual(10, sub.ack_deadline_seconds);
    try testing.expectEqual(false, sub.enable_message_ordering);

    const subs = try decodeSubscriptionPage(a,
        \\{"subscriptions":[{"name":"n","enableMessageOrdering":true}],"nextPageToken":"t"}
    );
    try testing.expect(subs.subscriptions[0].enable_message_ordering);
    try testing.expectEqualStrings("t", subs.next_page_token.?);
}

test "decode publish: ids must match the message count" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ok = try decodePublish(a, "{\n  \"messageIds\": [\"7\", \"8\"]\n}", 2);
    try testing.expectEqualStrings("8", ok.message_ids[1]);
    try testing.expectError(error.InvalidResponse, decodePublish(a, "{\"messageIds\":[\"7\"]}", 2));
    try testing.expectError(error.InvalidResponse, decodePublish(a, "{}", 1));
    try testing.expectError(error.InvalidResponse, decodePublish(a, "{\"messageIds\":[null]}", 1));
}


test "jsonStringLen matches Stringify" {
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const s = "a\"\\\x00\x08\x0c\n\r\t\x1f\x7fé/";
    try Stringify.encodeJsonString(s, .{}, &w);
    try testing.expectEqual(w.buffered().len, jsonStringLen(s));
}

test "AckChunks splits by size and count, in order" {
    const ids = [_][]const u8{ "aaaa", "bbbb", "cccc", "dd", "e" };
    // `{"ackIds":[]}` is 13 bytes; "aaaa" adds 6, each later id adds a comma.
    var it: AckChunks = .{ .ids = &ids, .fixed_bytes = 13, .max_bytes = 26, .max_ids = 10 };
    try testing.expectEqual(2, (try it.next()).?.len); // 13 + 6 + 7 = 26
    try testing.expectEqual(2, (try it.next()).?.len); // 13 + 6 + 5 = 24; + "e" = 28
    try testing.expectEqual(1, (try it.next()).?.len);
    try testing.expectEqual(null, try it.next());

    var by_count: AckChunks = .{ .ids = &ids, .fixed_bytes = 13, .max_bytes = 1000, .max_ids = 2 };
    try testing.expectEqual(2, (try by_count.next()).?.len);
    try testing.expectEqual(2, (try by_count.next()).?.len);
    try testing.expectEqual(1, (try by_count.next()).?.len);

    var too_big: AckChunks = .{ .ids = &ids, .fixed_bytes = 13, .max_bytes = 18, .max_ids = 10 };
    try testing.expectError(error.InvalidArgument, too_big.next());

    var none: AckChunks = .{ .ids = &.{}, .fixed_bytes = 13, .max_bytes = 18, .max_ids = 10 };
    try testing.expectEqual(null, try none.next());
}

// Fuzz properties


fn decodeArbitrary(_: void, input: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Every decoder either succeeds or reports InvalidResponse; none may crash.
    inline for (.{ decodePull, decodeTopic, decodeTopicPage, decodeSubscription, decodeSubscriptionPage }) |decode| {
        _ = decode(a, input) catch |err| switch (err) {
            error.InvalidResponse => {},
            else => return err,
        };
    }
    _ = decodePublish(a, input, 1) catch |err| switch (err) {
        error.InvalidResponse => {},
        else => return err,
    };
}

test "fuzz decoders: arbitrary bodies never crash" {
    try test_util.fuzzBytes({}, decodeArbitrary, .{ .corpus = &.{
        "{\"receivedMessages\":[{\"ackId\":\"a\",\"message\":{\"data\":\"aGk=\",\"attributes\":{\"k\":\"v\"},\"messageId\":\"1\",\"publishTime\":\"2026-09-18T23:12:18.388Z\",\"orderingKey\":\"o\"},\"deliveryAttempt\":1}]}",
        "{\"topics\":[{\"name\":\"projects/p/topics/t\"}],\"nextPageToken\":\"n\"}",
        "{\"subscriptions\":[{\"name\":\"s\",\"topic\":\"t\",\"ackDeadlineSeconds\":10,\"enableMessageOrdering\":true}]}",
        "{\"messageIds\":[\"1\"]}",
        "{\"error\":{\"code\":404,\"message\":\"m\",\"status\":\"NOT_FOUND\"}}",
        "{\"a\":[[[[[[[[[[[[[[[[[[[[1]]]]]]]]]]]]]]]]]]]}",
        "{\"receivedMessages\":[{\"message\":{\"attributes\":{\"k\":\"\\ud800\"}}}]}",
    } });
}

/// Random messages with valid, unique attribute keys, as the validator admits.
fn genMessages(g: *ByteGen, arena: Allocator) ![]types.Message {
    const count = g.intRange(usize, 1, 4);
    const messages = try arena.alloc(types.Message, count);
    for (messages) |*m| {
        const data = try arena.dupe(u8, g.slice(48));
        var attrs: std.ArrayList(types.Attribute) = .empty;
        for (0..g.intRange(usize, 0, 4)) |_| {
            var key_buf: [24]u8 = undefined;
            var value_buf: [32]u8 = undefined;
            const key = try arena.dupe(u8, g.utf8(&key_buf, 24));
            const value = try arena.dupe(u8, g.utf8(&value_buf, 32));
            for (attrs.items) |a| {
                if (std.mem.eql(u8, a.key, key)) break;
            } else try attrs.append(arena, .{ .key = key, .value = value });
        }
        m.* = .{ .data = data, .attributes = attrs.items };
    }
    return messages;
}

fn publishRoundTrip(_: void, input: []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var g: ByteGen = .init(input);
    var key_buf: [24]u8 = undefined;
    const ordering_key: ?[]const u8 = if (g.boolean()) g.utf8(&key_buf, 24) else null;
    const messages = try genMessages(&g, a);

    const body = try encodePublish(a, messages, ordering_key);
    // Whatever we send must be valid JSON that says exactly what we meant.
    const root = try std.json.parseFromSliceLeaky(std.json.Value, a, body, .{});
    const sent = root.object.get("messages").?.array.items;
    try testing.expectEqual(messages.len, sent.len);
    for (messages, sent) |m, value| {
        const obj = value.object;
        const data = if (obj.get("data")) |d| try decodeBase64(a, d.string) else "";
        try testing.expectEqualSlices(u8, m.data, data);
        const attrs = obj.get("attributes");
        try testing.expectEqual(m.attributes.len, if (attrs) |v| v.object.count() else 0);
        if (attrs) |v| for (m.attributes, v.object.keys(), v.object.values()) |want, key, got| {
            try testing.expectEqualStrings(want.key, key);
            try testing.expectEqualStrings(want.value, got.string);
        };
        const want_key = ordering_key orelse "";
        const got_key = if (obj.get("orderingKey")) |k| k.string else "";
        try testing.expectEqualStrings(want_key, got_key);
    }
}

test "fuzz publish encoding: arbitrary messages encode to the JSON we meant" {
    try test_util.fuzzBytes({}, publishRoundTrip, .{ .corpus = &.{
        "\x01\x08\x02\x10\x00\x00\x00\x00\x00\x00\x00\x03abc",
        "\x00\x00\x00\x00\x00\x00\x00\x00\x00",
        "\x01\x40\x07\xff\xff\xff\xff\x01\x02\x03",
    } });
}

/// Writes a pull response the way the server does, for decode round trips.
fn writePullResponse(arena: Allocator, messages: []const types.ReceivedMessage) ![]u8 {
    const Body = struct {
        messages: []const types.ReceivedMessage,
        fn write(self: @This(), jw: *Stringify) Stringify.Error!void {
            try jw.beginObject();
            try jw.objectField("receivedMessages");
            try jw.beginArray();
            for (self.messages) |m| {
                try jw.beginObject();
                try jw.objectField("ackId");
                try jw.write(m.ack_id);
                try jw.objectField("message");
                try jw.beginObject();
                if (m.data.len > 0) {
                    try jw.objectField("data");
                    try base64.writeJsonString(jw, m.data);
                }
                if (m.attributes.len > 0) {
                    try jw.objectField("attributes");
                    try jw.beginObject();
                    for (m.attributes) |attr| {
                        try jw.objectField(attr.key);
                        try jw.write(attr.value);
                    }
                    try jw.endObject();
                }
                try jw.objectField("messageId");
                try jw.write(m.message_id);
                try jw.objectField("publishTime");
                try jw.write(m.publish_time);
                if (m.ordering_key.len > 0) {
                    try jw.objectField("orderingKey");
                    try jw.write(m.ordering_key);
                }
                try jw.endObject();
                if (m.delivery_attempt != 0) {
                    try jw.objectField("deliveryAttempt");
                    try jw.write(m.delivery_attempt);
                }
                try jw.endObject();
            }
            try jw.endArray();
            try jw.endObject();
        }
    };
    return render(arena, Body{ .messages = messages });
}

fn pullRoundTrip(_: void, input: []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var g: ByteGen = .init(input);
    const published = try genMessages(&g, a);
    const want = try a.alloc(types.ReceivedMessage, published.len);
    for (published, want) |p, *w| {
        var ack_buf: [40]u8 = undefined;
        var key_buf: [16]u8 = undefined;
        w.* = .{
            .ack_id = try a.dupe(u8, g.utf8(&ack_buf, 40)),
            .message_id = try std.fmt.allocPrint(a, "{d}", .{g.int(u64)}),
            .data = p.data,
            .attributes = p.attributes,
            .publish_time = "2026-09-18T23:12:18.388Z",
            .ordering_key = try a.dupe(u8, g.utf8(&key_buf, 16)),
            .delivery_attempt = g.int(u32),
        };
    }
    const body = try writePullResponse(a, want);
    const got = (try decodePull(a, body)).messages;
    try testing.expectEqual(want.len, got.len);
    for (want, got) |w, r| {
        try testing.expectEqualStrings(w.ack_id, r.ack_id);
        try testing.expectEqualStrings(w.message_id, r.message_id);
        try testing.expectEqualSlices(u8, w.data, r.data);
        try testing.expectEqual(w.attributes.len, r.attributes.len);
        for (w.attributes, r.attributes) |wa, ra| {
            try testing.expectEqualStrings(wa.key, ra.key);
            try testing.expectEqualStrings(wa.value, ra.value);
        }
        try testing.expectEqualStrings(w.publish_time, r.publish_time);
        try testing.expectEqualStrings(w.ordering_key, r.ordering_key);
        try testing.expectEqual(w.delivery_attempt, r.delivery_attempt);
    }
}

test "fuzz pull decoding: server-shaped responses decode exactly" {
    try test_util.fuzzBytes({}, pullRoundTrip, .{ .corpus = &.{
        "\x02\x05hello\x01\x04key1\x03val",
        "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00",
    } });
}

test "decodePull: every allocation failure is OutOfMemory without leaks" {
    // 12 KiB of data, so decoding it needs an allocation of its own rather
    // than space left over in the arena.
    const body = "{\"receivedMessages\":[{\"ackId\":\"a1\",\"message\":{\"data\":\"" ++ ("QUFB" ** 4096) ++
        "\",\"attributes\":{\"k\":\"v\"},\"messageId\":\"1\",\"publishTime\":\"2026-09-19T00:00:00Z\"},\"deliveryAttempt\":1}]}";
    const Run = struct {
        fn decode(gpa: Allocator, text: []const u8) !void {
            var arena: std.heap.ArenaAllocator = .init(gpa);
            defer arena.deinit();
            const result = try decodePull(arena.allocator(), text);
            try testing.expectEqual(3 * 4096, result.messages[0].data.len);
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Run.decode, .{@as([]const u8, body)});
}

fn stringLenProperty(_: void, input: []const u8) !void {
    var buf: [6 * test_util.max_fuzz_input + 2]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try Stringify.encodeJsonString(input, .{}, &w);
    try testing.expectEqual(w.buffered().len, jsonStringLen(input));
}

fn publishLenProperty(_: void, input: []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var g: ByteGen = .init(input);
    var key_buf: [24]u8 = undefined;
    const ordering_key: ?[]const u8 = switch (g.intRange(u8, 0, 2)) {
        0 => null,
        1 => "",
        else => g.utf8(&key_buf, 24),
    };
    const all = try genMessages(&g, a);
    // Include the empty list: the precedence bug fixed above only showed there.
    const messages = all[0..g.intRange(usize, 0, all.len)];
    try testing.expectEqual((try encodePublish(a, messages, ordering_key)).len, publishBodyLen(messages, ordering_key));
}

test "fuzz publishBodyLen: always equals the encoded length" {
    try test_util.fuzzBytes({}, publishLenProperty, .{ .corpus = &.{
        "\x00\x01\x08\x02\x10\x00\x00\x00\x00\x00\x00\x00\x03abc",
        "\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00",
        "\x02\x05\x01\x40\x07\xff\xff\xff\xff\x01\x02\x03",
    } });
}

test "publishBodyLen: empty publish and each field" {
    try testing.expectEqual("{\"messages\":[]}".len, publishBodyLen(&.{}, null));
    try testing.expectEqual("{\"messages\":[{}]}".len, publishBodyLen(&.{.{}}, null));
    try testing.expectEqual(
        "{\"messages\":[{\"data\":\"aGk=\",\"orderingKey\":\"k\"},{\"orderingKey\":\"k\"}]}".len,
        publishBodyLen(&.{ .{ .data = "hi" }, .{} }, "k"),
    );
}

test "fuzz jsonStringLen: always equals Stringify's output length" {
    try test_util.fuzzBytes({}, stringLenProperty, .{ .corpus = &.{ "", "\x00\x1f\"\\", "é€😀" } });
}

fn ackChunksProperty(_: void, input: []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var g: ByteGen = .init(input);
    const deadline: ?u32 = if (g.boolean()) g.intRange(u32, 0, 600) else null;
    const max_bytes = g.intRange(usize, 20, 400);
    const max_ids = g.intRange(usize, 1, 8);
    const ids = try a.alloc([]const u8, g.intRange(usize, 0, 30));
    for (ids) |*id| {
        var buf: [40]u8 = undefined;
        id.* = try a.dupe(u8, g.utf8(&buf, 40));
    }
    const fixed_bytes = (try encodeAckIds(a, &.{}, deadline)).len;
    var it: AckChunks = .{ .ids = ids, .fixed_bytes = fixed_bytes, .max_bytes = max_bytes, .max_ids = max_ids };
    var covered: usize = 0;
    while (true) {
        const chunk = it.next() catch |err| {
            // Only when the next id cannot fit on its own.
            try testing.expectEqual(error.InvalidArgument, err);
            try testing.expect(fixed_bytes + jsonStringLen(ids[covered]) > max_bytes);
            return;
        } orelse break;
        // Chunks are contiguous, in order, within both limits...
        try testing.expect(chunk.ptr == ids[covered..].ptr);
        try testing.expect(chunk.len >= 1 and chunk.len <= max_ids);
        const body = try encodeAckIds(a, chunk, deadline);
        try testing.expect(body.len <= max_bytes);
        covered += chunk.len;
        // ...and greedy: one more id would break a limit.
        if (covered < ids.len and chunk.len < max_ids) {
            const bigger = try encodeAckIds(a, ids[covered - chunk.len .. covered + 1], deadline);
            try testing.expect(bigger.len > max_bytes);
        }
    }
    try testing.expectEqual(ids.len, covered);
}

test "fuzz AckChunks: covers every id, respects limits, stays greedy" {
    try test_util.fuzzBytes({}, ackChunksProperty, .{ .corpus = &.{
        "\x01\x00\x00\x00\x00\x00\x00\x00\x40\x00\x00\x00\x00\x00\x00\x00\x02\x00\x00\x00\x00\x00\x00\x00\x05",
        "\x00",
    } });
}
