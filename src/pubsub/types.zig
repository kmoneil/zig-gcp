//! Public data types: messages, call options, results, configs, and `Owned`.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// A result plus the arena that holds all of its memory, like `std.json.Parsed`.
/// One `deinit` frees everything; copy out anything needed after that.
pub fn Owned(comptime T: type) type {
    return struct {
        value: T,
        arena: *std.heap.ArenaAllocator,

        const Self = @This();

        /// An empty arena for a result. The caller sets `value`.
        pub fn init(gpa: Allocator) Allocator.Error!Self {
            const arena = try gpa.create(std.heap.ArenaAllocator);
            arena.* = .init(gpa);
            return .{ .value = undefined, .arena = arena };
        }

        pub fn deinit(self: *Self) void {
            const gpa = self.arena.child_allocator;
            self.arena.deinit();
            gpa.destroy(self.arena);
            self.* = undefined;
        }
    };
}

pub const Attribute = struct {
    key: []const u8,
    value: []const u8,
};

/// A message to publish. It needs non-empty `data` or at least one attribute.
pub const Message = struct {
    /// Raw bytes. The library does the base64.
    data: []const u8 = "",
    /// Keys must be unique. Keys and values must be valid UTF-8.
    attributes: []const Attribute = &.{},
};

pub const PublishOptions = struct {
    /// Messages with the same key reach subscriptions that enable message
    /// ordering in publish order. Every message in one call shares the key.
    ordering_key: ?[]const u8 = null,
};

pub const PublishResult = struct {
    /// Server-assigned ids, in the order of the published messages.
    message_ids: []const []const u8,
};

pub const PageOptions = struct {
    /// Results per page. 0 lets the server choose.
    page_size: u32 = 100,
    /// `next_page_token` from the previous page; null for the first page.
    page_token: ?[]const u8 = null,
};

pub const PullOptions = struct {
    /// Clamped to 1..1000.
    max_messages: u32 = 100,
    /// Return at once when no messages are available. Otherwise the server may
    /// hold an empty pull open for a while (about 90 seconds on the emulator).
    /// Google discourages setting this in production because it hurts
    /// delivery throughput.
    return_immediately: bool = false,
};

pub const PullResult = struct {
    messages: []const ReceivedMessage,
};

pub const ReceivedMessage = struct {
    /// Opaque. Pass it to `ack`, `nack` or `modifyAckDeadline` byte for byte.
    ack_id: []const u8,
    message_id: []const u8,
    /// Already decoded from base64.
    data: []const u8,
    /// In the order the server sent them.
    attributes: []const Attribute,
    /// RFC 3339, as sent by the server. `pubsub.parseTimestamp` converts it.
    publish_time: []const u8,
    /// "" when the message has none.
    ordering_key: []const u8,
    /// 0 when the server omits it, which it does unless the subscription has
    /// a dead-letter policy.
    delivery_attempt: u32,

    /// The value of the attribute named `key`, or null.
    pub fn attribute(self: ReceivedMessage, key: []const u8) ?[]const u8 {
        for (self.attributes) |a| {
            if (std.mem.eql(u8, a.key, key)) return a.value;
        }
        return null;
    }
};

/// Topic settings. Empty in v1; fields arrive when someone needs them.
pub const TopicConfig = struct {};

pub const TopicInfo = struct {
    /// Full resource name: `projects/{project}/topics/{id}`.
    name: []const u8,
};

pub const TopicPage = struct {
    topics: []const TopicInfo,
    /// Pass as `page_token` to get the next page. Null on the last page.
    next_page_token: ?[]const u8,
};

pub const SubscriptionConfig = struct {
    /// Id of a topic in the same project.
    topic_id: []const u8,
    /// 10 to 600 seconds, or 0 for the server default (10).
    ack_deadline_seconds: u32 = 10,
    enable_message_ordering: bool = false,
};

pub const SubscriptionInfo = struct {
    /// Full resource name: `projects/{project}/subscriptions/{id}`.
    name: []const u8,
    /// Full topic name, or `_deleted-topic_` after the topic was deleted.
    topic: []const u8,
    ack_deadline_seconds: u32,
    enable_message_ordering: bool,
};

pub const SubscriptionPage = struct {
    subscriptions: []const SubscriptionInfo,
    /// Pass as `page_token` to get the next page. Null on the last page.
    next_page_token: ?[]const u8,
};

test "Owned frees everything with one deinit" {
    var owned: Owned([]const u8) = try .init(std.testing.allocator);
    owned.value = try owned.arena.allocator().dupe(u8, "hello");
    _ = try owned.arena.allocator().alloc(u8, 4096);
    try std.testing.expectEqualStrings("hello", owned.value);
    owned.deinit();
}

test "ReceivedMessage.attribute finds the first match" {
    const m: ReceivedMessage = .{
        .ack_id = "a",
        .message_id = "1",
        .data = "",
        .attributes = &.{
            .{ .key = "origin", .value = "zig" },
            .{ .key = "", .value = "empty key" },
            .{ .key = "origin", .value = "second" },
        },
        .publish_time = "",
        .ordering_key = "",
        .delivery_attempt = 0,
    };
    try std.testing.expectEqualStrings("zig", m.attribute("origin").?);
    try std.testing.expectEqualStrings("empty key", m.attribute("").?);
    try std.testing.expectEqual(null, m.attribute("missing"));
}
