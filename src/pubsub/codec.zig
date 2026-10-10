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
const duration = @import("core").duration;
const timestamp = @import("core").timestamp;
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
        for (self.messages) |m| try writeMessage(jw, m, self.ordering_key);
        try jw.endArray();
        try jw.endObject();
    }
};

/// What a publish body holds before its first message and after its last.
/// A body is `publish_body_head`, then the messages `encodeMessage` writes,
/// joined by commas, then `publish_body_tail`: byte for byte what
/// `encodePublish` writes for the same messages.
pub const publish_body_head = "{\"messages\":[";
pub const publish_body_tail = "]}";

/// One message of a publish body, as `encodePublish` writes it. A publisher
/// builds a request from these one message at a time. Caller owns the result.
pub fn encodeMessage(gpa: Allocator, message: types.Message, ordering_key: ?[]const u8) Allocator.Error![]u8 {
    return render(gpa, MessageBody{ .message = message, .ordering_key = ordering_key });
}

const MessageBody = struct {
    message: types.Message,
    ordering_key: ?[]const u8,

    fn write(self: MessageBody, jw: *Stringify) Stringify.Error!void {
        try writeMessage(jw, self.message, self.ordering_key);
    }
};

fn writeMessage(jw: *Stringify, m: types.Message, ordering_key: ?[]const u8) Stringify.Error!void {
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
    if (ordering_key) |key| if (key.len > 0) {
        try jw.objectField("orderingKey");
        try jw.write(key);
    };
    try jw.endObject();
}

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

/// The `subscriptions.create` body. `topic_name` is the full resource name,
/// and so is `dead_letter_topic`, which the caller resolves from the
/// policy's id or name.
pub fn encodeSubscription(
    arena: Allocator,
    topic_name: []const u8,
    config: types.SubscriptionConfig,
    dead_letter_topic: ?[]const u8,
) Allocator.Error![]u8 {
    return render(arena, SubscriptionBody{ .topic_name = topic_name, .config = config, .dead_letter_topic = dead_letter_topic });
}

const SubscriptionBody = struct {
    topic_name: []const u8,
    config: types.SubscriptionConfig,
    dead_letter_topic: ?[]const u8,

    fn write(self: SubscriptionBody, jw: *Stringify) Stringify.Error!void {
        const c = self.config;
        try jw.beginObject();
        try jw.objectField("topic");
        try jw.write(self.topic_name);
        // Left out, 0 lets Pub/Sub choose: 10 s, or 60 s with exactly-once
        // delivery, which a 10 sent here would override.
        if (c.ack_deadline_seconds != 0) {
            try jw.objectField("ackDeadlineSeconds");
            try jw.write(c.ack_deadline_seconds);
        }
        try jw.objectField("enableMessageOrdering");
        try jw.write(c.enable_message_ordering);
        if (c.enable_exactly_once_delivery) {
            try jw.objectField("enableExactlyOnceDelivery");
            try jw.write(true);
        }
        if (c.filter.len > 0) {
            try jw.objectField("filter");
            try jw.write(c.filter);
        }
        if (c.dead_letter_policy) |policy| {
            try jw.objectField("deadLetterPolicy");
            try writeDeadLetter(jw, self.dead_letter_topic.?, policy.max_delivery_attempts);
        }
        if (c.retry_policy) |b| {
            try jw.objectField("retryPolicy");
            try writeBackoff(jw, b);
        }
        if (c.message_retention) |r| {
            try jw.objectField("messageRetentionDuration");
            try writeDuration(jw, r);
        }
        if (c.retain_acked_messages) {
            try jw.objectField("retainAckedMessages");
            try jw.write(true);
        }
        if (c.expiration != .default) {
            try jw.objectField("expirationPolicy");
            try writeExpiration(jw, c.expiration);
        }
        if (c.labels.len > 0) {
            try jw.objectField("labels");
            try writeLabels(jw, c.labels);
        }
        try jw.endObject();
    }
};

/// The `subscriptions.patch` body: the fields `update` sets, and a mask
/// naming them, and the ones it clears, which the body leaves out. Only
/// top-level fields are named; a policy is replaced whole.
pub fn encodeSubscriptionUpdate(
    arena: Allocator,
    update: types.SubscriptionUpdate,
    dead_letter_topic: ?[]const u8,
) Allocator.Error![]u8 {
    return render(arena, SubscriptionUpdateBody{ .update = update, .dead_letter_topic = dead_letter_topic });
}

const SubscriptionUpdateBody = struct {
    update: types.SubscriptionUpdate,
    dead_letter_topic: ?[]const u8,

    fn write(self: SubscriptionUpdateBody, jw: *Stringify) Stringify.Error!void {
        const u = self.update;
        var mask: Mask = .{};
        try jw.beginObject();
        try jw.objectField("subscription");
        try jw.beginObject();
        if (u.ack_deadline_seconds) |s| {
            mask.add("ackDeadlineSeconds");
            try jw.objectField("ackDeadlineSeconds");
            try jw.write(s);
        }
        if (u.enable_exactly_once_delivery) |on| {
            mask.add("enableExactlyOnceDelivery");
            try jw.objectField("enableExactlyOnceDelivery");
            try jw.write(on);
        }
        switch (u.dead_letter_policy) {
            .keep => {},
            .clear => mask.add("deadLetterPolicy"),
            .set => |policy| {
                mask.add("deadLetterPolicy");
                try jw.objectField("deadLetterPolicy");
                try writeDeadLetter(jw, self.dead_letter_topic.?, policy.max_delivery_attempts);
            },
        }
        switch (u.retry_policy) {
            .keep => {},
            .clear => mask.add("retryPolicy"),
            .set => |b| {
                mask.add("retryPolicy");
                try jw.objectField("retryPolicy");
                try writeBackoff(jw, b);
            },
        }
        switch (u.message_retention) {
            .keep => {},
            .clear => mask.add("messageRetentionDuration"),
            .set => |r| {
                mask.add("messageRetentionDuration");
                try jw.objectField("messageRetentionDuration");
                try writeDuration(jw, r);
            },
        }
        if (u.retain_acked_messages) |on| {
            mask.add("retainAckedMessages");
            try jw.objectField("retainAckedMessages");
            try jw.write(on);
        }
        if (u.expiration) |e| {
            mask.add("expirationPolicy");
            // The default is named and left out, which restores it.
            if (e != .default) {
                try jw.objectField("expirationPolicy");
                try writeExpiration(jw, e);
            }
        }
        if (u.labels) |labels| {
            mask.add("labels");
            try jw.objectField("labels");
            try writeLabels(jw, labels);
        }
        try jw.endObject();
        try jw.objectField("updateMask");
        try mask.write(jw);
        try jw.endObject();
    }
};

/// The `topics.create` body: `{}` when nothing is set.
pub fn encodeTopic(arena: Allocator, config: types.TopicConfig) Allocator.Error![]u8 {
    return render(arena, TopicBody{ .config = config });
}

const TopicBody = struct {
    config: types.TopicConfig,

    fn write(self: TopicBody, jw: *Stringify) Stringify.Error!void {
        const c = self.config;
        try jw.beginObject();
        if (c.labels.len > 0) {
            try jw.objectField("labels");
            try writeLabels(jw, c.labels);
        }
        if (c.message_retention) |r| {
            try jw.objectField("messageRetentionDuration");
            try writeDuration(jw, r);
        }
        if (c.kms_key_name) |k| {
            try jw.objectField("kmsKeyName");
            try jw.write(k);
        }
        if (c.message_storage_policy) |policy| {
            try jw.objectField("messageStoragePolicy");
            try writeStoragePolicy(jw, policy);
        }
        try jw.endObject();
    }
};

/// The `topics.patch` body, as for subscriptions.
pub fn encodeTopicUpdate(arena: Allocator, update: types.TopicUpdate) Allocator.Error![]u8 {
    return render(arena, TopicUpdateBody{ .update = update });
}

const TopicUpdateBody = struct {
    update: types.TopicUpdate,

    fn write(self: TopicUpdateBody, jw: *Stringify) Stringify.Error!void {
        const u = self.update;
        var mask: Mask = .{};
        try jw.beginObject();
        try jw.objectField("topic");
        try jw.beginObject();
        if (u.labels) |labels| {
            mask.add("labels");
            try jw.objectField("labels");
            try writeLabels(jw, labels);
        }
        switch (u.message_retention) {
            .keep => {},
            .clear => mask.add("messageRetentionDuration"),
            .set => |r| {
                mask.add("messageRetentionDuration");
                try jw.objectField("messageRetentionDuration");
                try writeDuration(jw, r);
            },
        }
        switch (u.kms_key_name) {
            .keep => {},
            .clear => mask.add("kmsKeyName"),
            .set => |k| {
                mask.add("kmsKeyName");
                try jw.objectField("kmsKeyName");
                try jw.write(k);
            },
        }
        switch (u.message_storage_policy) {
            .keep => {},
            .clear => mask.add("messageStoragePolicy"),
            .set => |policy| {
                mask.add("messageStoragePolicy");
                try jw.objectField("messageStoragePolicy");
                try writeStoragePolicy(jw, policy);
            },
        }
        try jw.endObject();
        try jw.objectField("updateMask");
        try mask.write(jw);
        try jw.endObject();
    }
};

/// The `snapshots.create` body: the subscription by its full name, and the
/// labels when there are any.
pub fn encodeSnapshot(arena: Allocator, subscription_name: []const u8, config: types.SnapshotConfig) Allocator.Error![]u8 {
    return render(arena, SnapshotBody{ .subscription_name = subscription_name, .config = config });
}

const SnapshotBody = struct {
    subscription_name: []const u8,
    config: types.SnapshotConfig,

    fn write(self: SnapshotBody, jw: *Stringify) Stringify.Error!void {
        try jw.beginObject();
        try jw.objectField("subscription");
        try jw.write(self.subscription_name);
        if (self.config.labels.len > 0) {
            try jw.objectField("labels");
            try writeLabels(jw, self.config.labels);
        }
        try jw.endObject();
    }
};

/// The `snapshots.patch` body, as for topics. Production takes labels and
/// refuses every other field as "not mutable" (measured 2026-10-10).
pub fn encodeSnapshotUpdate(arena: Allocator, update: types.SnapshotUpdate) Allocator.Error![]u8 {
    return render(arena, SnapshotUpdateBody{ .update = update });
}

const SnapshotUpdateBody = struct {
    update: types.SnapshotUpdate,

    fn write(self: SnapshotUpdateBody, jw: *Stringify) Stringify.Error!void {
        var mask: Mask = .{};
        try jw.beginObject();
        try jw.objectField("snapshot");
        try jw.beginObject();
        if (self.update.labels) |labels| {
            mask.add("labels");
            try jw.objectField("labels");
            try writeLabels(jw, labels);
        }
        try jw.endObject();
        try jw.objectField("updateMask");
        try mask.write(jw);
        try jw.endObject();
    }
};

/// An update mask: the camelCase paths an update names, comma-separated in
/// one JSON string, as the REST API takes a `FieldMask`.
const Mask = struct {
    paths: [8][]const u8 = undefined,
    len: usize = 0,

    fn add(m: *Mask, path: []const u8) void {
        m.paths[m.len] = path;
        m.len += 1;
    }

    fn write(m: *const Mask, jw: *Stringify) Stringify.Error!void {
        // Paths are fixed ASCII names, so the string needs no escaping.
        try jw.beginWriteRaw();
        try jw.writer.writeByte('"');
        for (m.paths[0..m.len], 0..) |path, i| {
            if (i > 0) try jw.writer.writeByte(',');
            try jw.writer.writeAll(path);
        }
        try jw.writer.writeByte('"');
        jw.endWriteRaw();
    }
};

fn writeDuration(jw: *Stringify, d: std.Io.Duration) Stringify.Error!void {
    var buf: [duration.max_len]u8 = undefined;
    try jw.write(duration.format(&buf, d));
}

fn writeLabels(jw: *Stringify, labels: []const types.Label) Stringify.Error!void {
    try jw.beginObject();
    for (labels) |l| {
        try jw.objectField(l.key);
        try jw.write(l.value);
    }
    try jw.endObject();
}

fn writeDeadLetter(jw: *Stringify, topic_name: []const u8, attempts: u8) Stringify.Error!void {
    try jw.beginObject();
    try jw.objectField("deadLetterTopic");
    try jw.write(topic_name);
    try jw.objectField("maxDeliveryAttempts");
    try jw.write(attempts);
    try jw.endObject();
}

fn writeBackoff(jw: *Stringify, b: types.Backoff) Stringify.Error!void {
    try jw.beginObject();
    try jw.objectField("minimumBackoff");
    try writeDuration(jw, b.minimum);
    try jw.objectField("maximumBackoff");
    try writeDuration(jw, b.maximum);
    try jw.endObject();
}

/// `{}` never expires; a ttl expires after it. The default is left out
/// entirely by the caller: absent and `{}` differ on the wire.
fn writeExpiration(jw: *Stringify, e: types.Expiration) Stringify.Error!void {
    try jw.beginObject();
    switch (e) {
        .default, .never => {},
        .after => |ttl| {
            try jw.objectField("ttl");
            try writeDuration(jw, ttl);
        },
    }
    try jw.endObject();
}

fn writeStoragePolicy(jw: *Stringify, policy: types.MessageStoragePolicy) Stringify.Error!void {
    try jw.beginObject();
    try jw.objectField("allowedPersistenceRegions");
    try jw.write(policy.allowed_persistence_regions);
    if (policy.enforce_in_transit) {
        try jw.objectField("enforceInTransit");
        try jw.write(true);
    }
    try jw.endObject();
}

/// Runs `body.write` into a fresh buffer. The only way an allocating writer
/// fails is running out of memory, and then nothing is left behind, so a
/// general-purpose allocator is as safe here as an arena.
fn render(allocator: Allocator, body: anytype) Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
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

const WireStoragePolicy = struct {
    allowedPersistenceRegions: ?[]const []const u8 = null,
    enforceInTransit: ?bool = null,
};

const WireTopic = struct {
    name: ?[]const u8 = null,
    labels: ?std.json.ArrayHashMap(?[]const u8) = null,
    messageRetentionDuration: ?[]const u8 = null,
    kmsKeyName: ?[]const u8 = null,
    messageStoragePolicy: ?WireStoragePolicy = null,
    state: ?[]const u8 = null,
};

const WireTopicList = struct {
    topics: ?[]const WireTopic = null,
    nextPageToken: ?[]const u8 = null,
};

const WireDeadLetter = struct {
    deadLetterTopic: ?[]const u8 = null,
    maxDeliveryAttempts: ?u32 = null,
};

const WireBackoff = struct {
    minimumBackoff: ?[]const u8 = null,
    maximumBackoff: ?[]const u8 = null,
};

const WireExpiration = struct {
    ttl: ?[]const u8 = null,
};

const WireSubscription = struct {
    name: ?[]const u8 = null,
    topic: ?[]const u8 = null,
    ackDeadlineSeconds: ?u32 = null,
    enableMessageOrdering: ?bool = null,
    enableExactlyOnceDelivery: ?bool = null,
    filter: ?[]const u8 = null,
    deadLetterPolicy: ?WireDeadLetter = null,
    retryPolicy: ?WireBackoff = null,
    messageRetentionDuration: ?[]const u8 = null,
    retainAckedMessages: ?bool = null,
    expirationPolicy: ?WireExpiration = null,
    labels: ?std.json.ArrayHashMap(?[]const u8) = null,
    detached: ?bool = null,
    state: ?[]const u8 = null,
    topicMessageRetentionDuration: ?[]const u8 = null,
};

const WireSubscriptionList = struct {
    subscriptions: ?[]const WireSubscription = null,
    nextPageToken: ?[]const u8 = null,
};

const WireSnapshot = struct {
    name: ?[]const u8 = null,
    topic: ?[]const u8 = null,
    expireTime: ?[]const u8 = null,
    labels: ?std.json.ArrayHashMap(?[]const u8) = null,
};

const WireSnapshotList = struct {
    snapshots: ?[]const WireSnapshot = null,
    nextPageToken: ?[]const u8 = null,
};

/// What is attached to a topic: names alone, under the key of their kind.
const WireNameList = struct {
    subscriptions: ?[]const []const u8 = null,
    snapshots: ?[]const []const u8 = null,
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

fn topicFromWire(arena: Allocator, w: WireTopic) DecodeError!types.TopicInfo {
    return .{
        .name = w.name orelse "",
        .labels = try labelsFromWire(arena, w.labels),
        .message_retention = try optionalDuration(w.messageRetentionDuration),
        .kms_key_name = nonEmpty(w.kmsKeyName),
        .message_storage_policy = if (w.messageStoragePolicy) |policy| .{
            .allowed_persistence_regions = policy.allowedPersistenceRegions orelse &.{},
            .enforce_in_transit = policy.enforceInTransit orelse false,
        } else null,
        .state = topicState(w.state),
    };
}

pub fn decodeTopic(arena: Allocator, body: []const u8) DecodeError!types.TopicInfo {
    return topicFromWire(arena, try parseWire(WireTopic, arena, body));
}

pub fn decodeTopicPage(arena: Allocator, body: []const u8) DecodeError!types.TopicPage {
    const wire = try parseWire(WireTopicList, arena, body);
    const list = wire.topics orelse &.{};
    const topics = try arena.alloc(types.TopicInfo, list.len);
    for (list, topics) |t, *out| out.* = try topicFromWire(arena, t);
    return .{ .topics = topics, .next_page_token = nonEmpty(wire.nextPageToken) };
}

fn subscriptionFromWire(arena: Allocator, w: WireSubscription) DecodeError!types.SubscriptionInfo {
    return .{
        .name = w.name orelse "",
        .topic = w.topic orelse "",
        .ack_deadline_seconds = w.ackDeadlineSeconds orelse 0,
        .enable_message_ordering = w.enableMessageOrdering orelse false,
        .enable_exactly_once_delivery = w.enableExactlyOnceDelivery orelse false,
        .filter = w.filter orelse "",
        .dead_letter_policy = if (w.deadLetterPolicy) |policy| .{
            .topic = policy.deadLetterTopic orelse "",
            // 0 means Pub/Sub's default, which is 5.
            .max_delivery_attempts = switch (policy.maxDeliveryAttempts orelse 0) {
                0 => 5,
                1...std.math.maxInt(u8) => |n| @intCast(n),
                else => return error.InvalidResponse,
            },
        } else null,
        // Each bound the server leaves out is its default.
        .retry_policy = if (w.retryPolicy) |b| .{
            .minimum = if (b.minimumBackoff) |text| try parseDuration(text) else .fromSeconds(10),
            .maximum = if (b.maximumBackoff) |text| try parseDuration(text) else .fromSeconds(600),
        } else null,
        .message_retention = try optionalDuration(w.messageRetentionDuration),
        .retain_acked_messages = w.retainAckedMessages orelse false,
        // Absent is the 31-day default; `{}` never expires.
        .expiration = if (w.expirationPolicy) |e|
            (if (e.ttl) |ttl| .{ .after = try parseDuration(ttl) } else .never)
        else
            .default,
        .labels = try labelsFromWire(arena, w.labels),
        .detached = w.detached orelse false,
        .state = subscriptionState(w.state),
        .topic_message_retention = try optionalDuration(w.topicMessageRetentionDuration),
    };
}

pub fn decodeSubscription(arena: Allocator, body: []const u8) DecodeError!types.SubscriptionInfo {
    return subscriptionFromWire(arena, try parseWire(WireSubscription, arena, body));
}

pub fn decodeSubscriptionPage(arena: Allocator, body: []const u8) DecodeError!types.SubscriptionPage {
    const wire = try parseWire(WireSubscriptionList, arena, body);
    const list = wire.subscriptions orelse &.{};
    const subscriptions = try arena.alloc(types.SubscriptionInfo, list.len);
    for (list, subscriptions) |s, *out| out.* = try subscriptionFromWire(arena, s);
    return .{ .subscriptions = subscriptions, .next_page_token = nonEmpty(wire.nextPageToken) };
}

fn snapshotFromWire(arena: Allocator, w: WireSnapshot) DecodeError!types.SnapshotInfo {
    return .{
        .name = w.name orelse "",
        .topic = w.topic orelse "",
        // Production and the emulator send one for every snapshot. Without
        // it there is no true time to give, so the answer is no snapshot.
        .expire_time = timestamp.parse(w.expireTime orelse return error.InvalidResponse) catch return error.InvalidResponse,
        .labels = try labelsFromWire(arena, w.labels),
    };
}

pub fn decodeSnapshot(arena: Allocator, body: []const u8) DecodeError!types.SnapshotInfo {
    return snapshotFromWire(arena, try parseWire(WireSnapshot, arena, body));
}

pub fn decodeSnapshotPage(arena: Allocator, body: []const u8) DecodeError!types.SnapshotPage {
    const wire = try parseWire(WireSnapshotList, arena, body);
    const list = wire.snapshots orelse &.{};
    const snapshots = try arena.alloc(types.SnapshotInfo, list.len);
    for (list, snapshots) |s, *out| out.* = try snapshotFromWire(arena, s);
    return .{ .snapshots = snapshots, .next_page_token = nonEmpty(wire.nextPageToken) };
}

/// Which of a topic's two lists of names an answer holds.
pub const NameList = enum { subscriptions, snapshots };

pub fn decodeNamePage(arena: Allocator, body: []const u8, list: NameList) DecodeError!types.NamePage {
    const wire = try parseWire(WireNameList, arena, body);
    const names = switch (list) {
        .subscriptions => wire.subscriptions,
        .snapshots => wire.snapshots,
    };
    return .{ .names = names orelse &.{}, .next_page_token = nonEmpty(wire.nextPageToken) };
}

fn parseDuration(text: []const u8) DecodeError!std.Io.Duration {
    return duration.parse(text) catch error.InvalidResponse;
}

fn optionalDuration(text: ?[]const u8) DecodeError!?std.Io.Duration {
    return if (text) |t| try parseDuration(t) else null;
}

fn labelsFromWire(arena: Allocator, wire: ?std.json.ArrayHashMap(?[]const u8)) Allocator.Error![]const types.Label {
    const map = (wire orelse return &.{}).map;
    const out = try arena.alloc(types.Label, map.count());
    for (map.keys(), map.values(), out) |k, v, *l| l.* = .{ .key = k, .value = v orelse "" };
    return out;
}

fn topicState(text: ?[]const u8) types.TopicInfo.State {
    const s = text orelse return .active;
    if (std.mem.eql(u8, s, "ACTIVE") or std.mem.eql(u8, s, "STATE_UNSPECIFIED")) return .active;
    if (std.mem.eql(u8, s, "INGESTION_RESOURCE_ERROR")) return .ingestion_resource_error;
    return .unknown;
}

fn subscriptionState(text: ?[]const u8) types.SubscriptionInfo.State {
    const s = text orelse return .active;
    if (std.mem.eql(u8, s, "ACTIVE") or std.mem.eql(u8, s, "STATE_UNSPECIFIED")) return .active;
    if (std.mem.eql(u8, s, "RESOURCE_ERROR")) return .resource_error;
    return .unknown;
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
        }, null),
    );
    // The defaults leave the deadline to Pub/Sub; exactly-once is sent only when on.
    try testing.expectEqualStrings(
        "{\"topic\":\"projects/p/topics/t\",\"enableMessageOrdering\":false}",
        try encodeSubscription(a, "projects/p/topics/t", .{ .topic_id = "t" }, null),
    );
    try testing.expectEqualStrings(
        "{\"topic\":\"projects/p/topics/t\",\"enableMessageOrdering\":false,\"enableExactlyOnceDelivery\":true}",
        try encodeSubscription(a, "projects/p/topics/t", .{ .topic_id = "t", .enable_exactly_once_delivery = true }, null),
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
    try testing.expectEqual(false, sub.enable_exactly_once_delivery);

    // As production answers for an exactly-once subscription made without
    // a deadline: 60 s, its default.
    const exactly_once = try decodeSubscription(a,
        \\{"name":"projects/p/subscriptions/eod","topic":"projects/p/topics/t","pushConfig":{},
        \\"ackDeadlineSeconds":60,"messageRetentionDuration":"604800s","enableExactlyOnceDelivery":true,"state":"ACTIVE"}
    );
    try testing.expect(exactly_once.enable_exactly_once_delivery);
    try testing.expectEqual(60, exactly_once.ack_deadline_seconds);

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
            .message_id = try a.print("{d}", .{g.int(u64)}),
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
    const body = "{\"receivedMessages\":[{\"ackId\":\"a1\",\"message\":{\"data\":\"" ++ test_util.repeat("QUFB", 4096) ++
        "\",\"attributes\":{\"k\":\"v\"},\"messageId\":\"1\",\"publishTime\":\"2026-09-19T00:00:00Z\"},\"deliveryAttempt\":1}]}";
    const Run = struct {
        fn decode(gpa: Allocator, text: []const u8) !void {
            var arena: std.heap.ArenaAllocator = .init(gpa);
            defer arena.deinit();
            const result = try decodePull(arena.allocator(), text);
            try testing.expectEqual(3 * 4096, result.messages[0].data.len);
        }
    };
    try testing.checkAllAllocationFailures(test_util.no_grow_allocator, Run.decode, .{@as([]const u8, body)});
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

fn assembledBodyProperty(_: void, input: []const u8) !void {
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
    const messages = all[0..g.intRange(usize, 0, all.len)];

    // A publisher's body, one message at a time.
    var assembled: std.ArrayList(u8) = .empty;
    try assembled.appendSlice(a, publish_body_head);
    for (messages, 0..) |m, i| {
        if (i > 0) try assembled.append(a, ',');
        const one = try encodeMessage(testing.allocator, m, ordering_key);
        defer testing.allocator.free(one);
        try assembled.appendSlice(a, one);
    }
    try assembled.appendSlice(a, publish_body_tail);

    try testing.expectEqualStrings(try encodePublish(a, messages, ordering_key), assembled.items);
    try testing.expectEqual(publishBodyLen(messages, ordering_key), assembled.items.len);
}

test "fuzz encodeMessage: a body built one message at a time is the body encodePublish writes" {
    try test_util.fuzzBytes({}, assembledBodyProperty, .{ .corpus = &.{
        "\x00\x01\x08\x02\x10\x00\x00\x00\x00\x00\x00\x00\x03abc",
        "\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00",
        "\x02\x05\x01\x40\x07\xff\xff\xff\xff\x01\x02\x03",
    } });
}

test "encodeMessage: each field, and an empty key left out" {
    const gpa = testing.allocator;
    const cases = [_]struct { types.Message, ?[]const u8, []const u8 }{
        .{ .{ .data = "hi" }, null, "{\"data\":\"aGk=\"}" },
        .{ .{ .data = "hi" }, "", "{\"data\":\"aGk=\"}" },
        .{ .{ .attributes = &.{.{ .key = "k", .value = "v\"" }} }, "user-42", "{\"attributes\":{\"k\":\"v\\\"\"},\"orderingKey\":\"user-42\"}" },
    };
    for (cases) |c| {
        const got = try encodeMessage(gpa, c[0], c[1]);
        defer gpa.free(got);
        try testing.expectEqualStrings(c[2], got);
    }
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

test "golden: subscription create body with every setting" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings(
        "{\"topic\":\"projects/p/topics/orders\",\"ackDeadlineSeconds\":20,\"enableMessageOrdering\":true," ++
            "\"enableExactlyOnceDelivery\":true,\"filter\":\"attributes.kind = \\\"a\\\"\"," ++
            "\"deadLetterPolicy\":{\"deadLetterTopic\":\"projects/p/topics/dead\",\"maxDeliveryAttempts\":7}," ++
            "\"retryPolicy\":{\"minimumBackoff\":\"1.500s\",\"maximumBackoff\":\"600s\"}," ++
            "\"messageRetentionDuration\":\"1200s\",\"retainAckedMessages\":true," ++
            "\"expirationPolicy\":{\"ttl\":\"86400s\"},\"labels\":{\"team\":\"zig\",\"env\":\"prod\"}}",
        try encodeSubscription(a, "projects/p/topics/orders", .{
            .topic_id = "orders",
            .ack_deadline_seconds = 20,
            .enable_message_ordering = true,
            .enable_exactly_once_delivery = true,
            .filter = "attributes.kind = \"a\"",
            .dead_letter_policy = .{ .topic = "dead", .max_delivery_attempts = 7 },
            .retry_policy = .{ .minimum = .fromMilliseconds(1500) },
            .message_retention = .fromSeconds(1200),
            .retain_acked_messages = true,
            .expiration = .{ .after = .fromSeconds(86400) },
            .labels = &.{ .{ .key = "team", .value = "zig" }, .{ .key = "env", .value = "prod" } },
        }, "projects/p/topics/dead"),
    );
    // Never expiring is `{}`, where the default is left out.
    try testing.expectEqualStrings(
        "{\"topic\":\"t\",\"enableMessageOrdering\":false,\"expirationPolicy\":{}}",
        try encodeSubscription(a, "t", .{ .topic_id = "t", .expiration = .never }, null),
    );
}

test "golden: subscription update bodies name what they set and what they clear" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings(
        "{\"subscription\":{\"ackDeadlineSeconds\":30,\"enableExactlyOnceDelivery\":false," ++
            "\"deadLetterPolicy\":{\"deadLetterTopic\":\"projects/o/topics/dead\",\"maxDeliveryAttempts\":5}," ++
            "\"retainAckedMessages\":true,\"expirationPolicy\":{},\"labels\":{}}," ++
            "\"updateMask\":\"ackDeadlineSeconds,enableExactlyOnceDelivery,deadLetterPolicy,retryPolicy,messageRetentionDuration,retainAckedMessages,expirationPolicy,labels\"}",
        try encodeSubscriptionUpdate(a, .{
            .ack_deadline_seconds = 30,
            .enable_exactly_once_delivery = false,
            .dead_letter_policy = .{ .set = .{ .topic = "projects/o/topics/dead" } },
            .retry_policy = .clear,
            .message_retention = .clear,
            .retain_acked_messages = true,
            .expiration = .never,
            .labels = &.{},
        }, "projects/o/topics/dead"),
    );
    // Back to the default expiration: named, and left out.
    try testing.expectEqualStrings(
        "{\"subscription\":{\"retryPolicy\":{\"minimumBackoff\":\"0s\",\"maximumBackoff\":\"2s\"}},\"updateMask\":\"retryPolicy,expirationPolicy\"}",
        try encodeSubscriptionUpdate(a, .{
            .retry_policy = .{ .set = .{ .minimum = .zero, .maximum = .fromSeconds(2) } },
            .expiration = .default,
        }, null),
    );
}

test "golden: topic create and update bodies" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings(
        "{\"labels\":{\"env\":\"test\"},\"messageRetentionDuration\":\"3600s\"," ++
            "\"kmsKeyName\":\"projects/p/locations/l/keyRings/r/cryptoKeys/k\"," ++
            "\"messageStoragePolicy\":{\"allowedPersistenceRegions\":[\"europe-west1\",\"europe-west4\"],\"enforceInTransit\":true}}",
        try encodeTopic(a, .{
            .labels = &.{.{ .key = "env", .value = "test" }},
            .message_retention = .fromSeconds(3600),
            .kms_key_name = "projects/p/locations/l/keyRings/r/cryptoKeys/k",
            .message_storage_policy = .{ .allowed_persistence_regions = &.{ "europe-west1", "europe-west4" }, .enforce_in_transit = true },
        }),
    );
    try testing.expectEqualStrings(
        "{\"topic\":{\"labels\":{\"env\":\"prod\"},\"messageStoragePolicy\":{\"allowedPersistenceRegions\":[\"us-east1\"]}}," ++
            "\"updateMask\":\"labels,messageRetentionDuration,kmsKeyName,messageStoragePolicy\"}",
        try encodeTopicUpdate(a, .{
            .labels = &.{.{ .key = "env", .value = "prod" }},
            .message_retention = .clear,
            .kms_key_name = .clear,
            .message_storage_policy = .{ .set = .{ .allowed_persistence_regions = &.{"us-east1"} } },
        }),
    );
    // The arms the update above leaves out: retention and key set, the
    // storage policy cleared, which is mask-only.
    try testing.expectEqualStrings(
        "{\"topic\":{\"messageRetentionDuration\":\"3600s\"," ++
            "\"kmsKeyName\":\"projects/p/locations/l/keyRings/r/cryptoKeys/k\"}," ++
            "\"updateMask\":\"messageRetentionDuration,kmsKeyName,messageStoragePolicy\"}",
        try encodeTopicUpdate(a, .{
            .message_retention = .{ .set = .fromSeconds(3600) },
            .kms_key_name = .{ .set = "projects/p/locations/l/keyRings/r/cryptoKeys/k" },
            .message_storage_policy = .clear,
        }),
    );
}

test "decode a subscription with every setting, as the emulator echoes it" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const s = try decodeSubscription(arena.allocator(),
        \\{"name":"projects/test/subscriptions/full","topic":"projects/test/topics/t","pushConfig":{},
        \\"ackDeadlineSeconds":20,"retainAckedMessages":true,"messageRetentionDuration":"1200s",
        \\"labels":{"team":"zig"},"enableMessageOrdering":true,"expirationPolicy":{"ttl":"86400s"},
        \\"filter":"attributes.kind = \"a\"","deadLetterPolicy":{"deadLetterTopic":"projects/test/topics/dlt","maxDeliveryAttempts":5},
        \\"retryPolicy":{"minimumBackoff":"1.500s","maximumBackoff":"2s"},"enableExactlyOnceDelivery":true,
        \\"state":"ACTIVE","detached":false,"topicMessageRetentionDuration":"3600s"}
    );
    try testing.expectEqual(20, s.ack_deadline_seconds);
    try testing.expect(s.retain_acked_messages);
    try testing.expectEqual(std.Io.Duration.fromSeconds(1200), s.message_retention.?);
    try testing.expectEqualStrings("zig", s.label("team").?);
    try testing.expectEqual(null, s.label("absent"));
    try testing.expect(s.enable_message_ordering and s.enable_exactly_once_delivery);
    try testing.expectEqual(std.Io.Duration.fromSeconds(86400), s.expiration.after);
    try testing.expectEqualStrings("attributes.kind = \"a\"", s.filter);
    try testing.expectEqualStrings("projects/test/topics/dlt", s.dead_letter_policy.?.topic);
    try testing.expectEqual(5, s.dead_letter_policy.?.max_delivery_attempts);
    try testing.expectEqual(std.Io.Duration.fromMilliseconds(1500), s.retry_policy.?.minimum);
    try testing.expectEqual(std.Io.Duration.fromSeconds(2), s.retry_policy.?.maximum);
    try testing.expectEqual(.active, s.state);
    try testing.expectEqual(std.Io.Duration.fromSeconds(3600), s.topic_message_retention.?);
}

test "decode subscription settings: absent, empty and odd values" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Absent: the defaults. The expiration default and `{}` differ.
    const bare = try decodeSubscription(a, "{\"name\":\"n\"}");
    try testing.expectEqual(.default, std.meta.activeTag(bare.expiration));
    try testing.expectEqual(null, bare.retry_policy);
    try testing.expectEqual(null, bare.dead_letter_policy);
    try testing.expectEqual(null, bare.message_retention);
    try testing.expectEqualStrings("", bare.filter);
    try testing.expectEqual(0, bare.labels.len);
    const never = try decodeSubscription(a, "{\"expirationPolicy\":{},\"retryPolicy\":{},\"deadLetterPolicy\":{\"deadLetterTopic\":\"d\"}}");
    try testing.expectEqual(.never, std.meta.activeTag(never.expiration));
    // Bounds left out are Pub/Sub's defaults, 10 s and 600 s; attempts 5.
    try testing.expectEqual(std.Io.Duration.fromSeconds(10), never.retry_policy.?.minimum);
    try testing.expectEqual(std.Io.Duration.fromSeconds(600), never.retry_policy.?.maximum);
    try testing.expectEqual(5, never.dead_letter_policy.?.max_delivery_attempts);
    // A state this client does not know, and one it does.
    try testing.expectEqual(.unknown, (try decodeSubscription(a, "{\"state\":\"SOMETHING_NEW\"}")).state);
    try testing.expectEqual(.resource_error, (try decodeSubscription(a, "{\"state\":\"RESOURCE_ERROR\"}")).state);
    try testing.expect((try decodeSubscription(a, "{\"detached\":true}")).detached);
    // What cannot be a duration, or attempts, is an invalid response.
    try testing.expectError(error.InvalidResponse, decodeSubscription(a, "{\"messageRetentionDuration\":\"7 days\"}"));
    try testing.expectError(error.InvalidResponse, decodeSubscription(a, "{\"expirationPolicy\":{\"ttl\":\"1\"}}"));
    try testing.expectError(error.InvalidResponse, decodeSubscription(a, "{\"retryPolicy\":{\"minimumBackoff\":10}}"));
    try testing.expectError(error.InvalidResponse, decodeSubscription(a, "{\"deadLetterPolicy\":{\"maxDeliveryAttempts\":256}}"));
}

test "decode a topic with every setting" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const t = try decodeTopic(a,
        \\{"name":"projects/p/topics/t","labels":{"env":"test","empty":""},"messageRetentionDuration":"3600s",
        \\"kmsKeyName":"projects/p/locations/l/keyRings/r/cryptoKeys/k",
        \\"messageStoragePolicy":{"allowedPersistenceRegions":["europe-west1"],"enforceInTransit":true},
        \\"state":"INGESTION_RESOURCE_ERROR","satisfiesPzs":false}
    );
    try testing.expectEqualStrings("test", t.label("env").?);
    try testing.expectEqualStrings("", t.label("empty").?);
    try testing.expectEqual(std.Io.Duration.fromSeconds(3600), t.message_retention.?);
    try testing.expectEqualStrings("projects/p/locations/l/keyRings/r/cryptoKeys/k", t.kms_key_name.?);
    try testing.expectEqualStrings("europe-west1", t.message_storage_policy.?.allowed_persistence_regions[0]);
    try testing.expect(t.message_storage_policy.?.enforce_in_transit);
    try testing.expectEqual(.ingestion_resource_error, t.state);
    const bare = try decodeTopic(a, "{\"name\":\"n\",\"kmsKeyName\":\"\"}");
    try testing.expectEqual(null, bare.kms_key_name);
    try testing.expectEqual(null, bare.message_storage_policy);
    try testing.expectEqual(.active, bare.state);
    // A state this client does not know, like the subscription twin.
    try testing.expectEqual(.unknown, (try decodeTopic(a, "{\"state\":\"SOMETHING_NEW\"}")).state);
}

/// Draws settings the checks accept, as a caller might write them.
fn genSubscriptionConfig(g: *ByteGen, arena: Allocator) !types.SubscriptionConfig {
    var config: types.SubscriptionConfig = .{ .topic_id = "t" };
    config.ack_deadline_seconds = if (g.boolean()) 0 else g.intRange(u32, 10, 600);
    config.enable_message_ordering = g.boolean();
    config.enable_exactly_once_delivery = g.boolean();
    if (g.boolean()) {
        var buf: [256]u8 = undefined;
        config.filter = try arena.dupe(u8, g.utf8(&buf, 256));
    }
    if (g.boolean()) config.dead_letter_policy = .{ .topic = "projects/p/topics/dead", .max_delivery_attempts = g.intRange(u8, 5, 100) };
    if (g.boolean()) {
        const lo: i64 = g.intRange(u16, 0, 600);
        config.retry_policy = .{
            .minimum = .fromMilliseconds(lo * 1000 - @as(i64, if (lo > 0) g.intRange(u16, 0, 999) else 0)),
            .maximum = .fromSeconds(g.intRange(u16, @intCast(lo), 600)),
        };
    }
    const retention_s: ?i64 = if (g.boolean()) g.intRange(u32, 600, 31 * 24 * 3600) else null;
    if (retention_s) |r| config.message_retention = .fromSeconds(r);
    config.expiration = switch (g.intRange(u8, 0, 2)) {
        0 => .default,
        1 => .never,
        else => .{ .after = .fromSeconds(@max(retention_s orelse 0, 86400) + g.intRange(u32, 0, 1_000_000)) },
    };
    const labels = try arena.alloc(types.Label, g.intRange(u8, 0, 4));
    for (labels, 0..) |*l, i| l.* = .{
        .key = try arena.print("k{d}{s}", .{ i, g.pick([]const u8, &.{ "", "_x", "-y", "z9" }) }),
        .value = g.pick([]const u8, &.{ "", "v", "prod", "a-b_c" }),
    };
    config.labels = labels;
    return config;
}

fn subscriptionRoundTrip(_: void, input: []const u8) !void {
    var g: ByteGen = .init(input);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const config = try genSubscriptionConfig(&g, a);
    try @import("validate.zig").subscriptionConfig(config, null);
    // The create body is a subscription resource: read back as one, it
    // says what was asked.
    const dead: ?[]const u8 = if (config.dead_letter_policy) |p| p.topic else null;
    const info = try decodeSubscription(a, try encodeSubscription(a, "projects/p/topics/t", config, dead));
    try testing.expectEqualStrings("projects/p/topics/t", info.topic);
    try testing.expectEqual(config.ack_deadline_seconds, info.ack_deadline_seconds);
    try testing.expectEqual(config.enable_message_ordering, info.enable_message_ordering);
    try testing.expectEqual(config.enable_exactly_once_delivery, info.enable_exactly_once_delivery);
    try testing.expectEqualStrings(config.filter, info.filter);
    try testing.expectEqual(config.dead_letter_policy == null, info.dead_letter_policy == null);
    if (config.dead_letter_policy) |p| {
        try testing.expectEqualStrings(p.topic, info.dead_letter_policy.?.topic);
        try testing.expectEqual(p.max_delivery_attempts, info.dead_letter_policy.?.max_delivery_attempts);
    }
    try testing.expectEqual(config.retry_policy, info.retry_policy);
    try testing.expectEqual(config.message_retention, info.message_retention);
    try testing.expectEqual(config.retain_acked_messages, info.retain_acked_messages);
    try testing.expectEqual(config.expiration, info.expiration);
    try testing.expectEqual(config.labels.len, info.labels.len);
    for (config.labels, info.labels) |want, have| {
        try testing.expectEqualStrings(want.key, have.key);
        try testing.expectEqualStrings(want.value, have.value);
    }
}

test "fuzz subscription settings: a create body reads back as the settings it was made from" {
    try test_util.fuzzBytes({}, subscriptionRoundTrip, .{ .corpus = &.{ "", "\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff" } });
}

fn updateMaskProperty(_: void, input: []const u8) !void {
    var g: ByteGen = .init(input);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var u: types.SubscriptionUpdate = .{};
    var want: std.ArrayList([]const u8) = .empty;
    var body_fields: std.ArrayList([]const u8) = .empty;
    if (g.boolean()) {
        u.ack_deadline_seconds = g.intRange(u32, 10, 600);
        try want.append(a, "ackDeadlineSeconds");
        try body_fields.append(a, "ackDeadlineSeconds");
    }
    if (g.boolean()) {
        u.enable_exactly_once_delivery = g.boolean();
        try want.append(a, "enableExactlyOnceDelivery");
        try body_fields.append(a, "enableExactlyOnceDelivery");
    }
    switch (g.intRange(u8, 0, 2)) {
        0 => {},
        1 => {
            u.dead_letter_policy = .clear;
            try want.append(a, "deadLetterPolicy");
        },
        else => {
            u.dead_letter_policy = .{ .set = .{ .topic = "d" } };
            try want.append(a, "deadLetterPolicy");
            try body_fields.append(a, "deadLetterPolicy");
        },
    }
    switch (g.intRange(u8, 0, 2)) {
        0 => {},
        1 => {
            u.retry_policy = .clear;
            try want.append(a, "retryPolicy");
        },
        else => {
            u.retry_policy = .{ .set = .{} };
            try want.append(a, "retryPolicy");
            try body_fields.append(a, "retryPolicy");
        },
    }
    switch (g.intRange(u8, 0, 2)) {
        0 => {},
        1 => {
            u.message_retention = .clear;
            try want.append(a, "messageRetentionDuration");
        },
        else => {
            u.message_retention = .{ .set = .fromSeconds(3600) };
            try want.append(a, "messageRetentionDuration");
            try body_fields.append(a, "messageRetentionDuration");
        },
    }
    if (g.boolean()) {
        u.retain_acked_messages = g.boolean();
        try want.append(a, "retainAckedMessages");
        try body_fields.append(a, "retainAckedMessages");
    }
    switch (g.intRange(u8, 0, 3)) {
        0 => {},
        1 => {
            u.expiration = .default;
            try want.append(a, "expirationPolicy");
        },
        2 => {
            u.expiration = .never;
            try want.append(a, "expirationPolicy");
            try body_fields.append(a, "expirationPolicy");
        },
        else => {
            u.expiration = .{ .after = .fromSeconds(86400) };
            try want.append(a, "expirationPolicy");
            try body_fields.append(a, "expirationPolicy");
        },
    }
    if (g.boolean()) {
        u.labels = if (g.boolean()) &.{} else &.{.{ .key = "k", .value = "v" }};
        try want.append(a, "labels");
        try body_fields.append(a, "labels");
    }
    const body = try encodeSubscriptionUpdate(a, u, "projects/p/topics/d");
    const Parsed = struct { subscription: std.json.ArrayHashMap(std.json.Value), updateMask: []const u8 };
    const parsed = try std.json.parseFromSliceLeaky(Parsed, a, body, .{});
    // The mask names exactly what the update sets or clears, and the body
    // carries exactly what it sets.
    var mask: std.ArrayList([]const u8) = .empty;
    if (parsed.updateMask.len > 0) {
        var it = std.mem.splitScalar(u8, parsed.updateMask, ',');
        while (it.next()) |path| try mask.append(a, path);
    }
    try testing.expectEqual(want.items.len, mask.items.len);
    for (want.items, mask.items) |w, m| try testing.expectEqualStrings(w, m);
    try testing.expectEqual(body_fields.items.len, parsed.subscription.map.count());
    for (body_fields.items) |field| try testing.expect(parsed.subscription.map.contains(field));
}

test "fuzz subscription update: the mask names what the update sets or clears, and the body carries what it sets" {
    try test_util.fuzzBytes({}, updateMaskProperty, .{ .corpus = &.{ "", "\x01\x1f\x01\x01\x02\x02\x02\x01\x01\x03\x01\x00" } });
}

test "decode snapshots, their pages, and a topic's lists of names" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Production's answer to a create, 2026-10-10.
    const s = try decodeSnapshot(a,
        \\{"name":"projects/extractctl/snapshots/zigps-snap","topic":"projects/extractctl/topics/zigps-t","expireTime":"2026-10-17T13:46:36.836Z","labels":{"k":"v"}}
    );
    try testing.expectEqualStrings("projects/extractctl/snapshots/zigps-snap", s.name);
    try testing.expectEqualStrings("projects/extractctl/topics/zigps-t", s.topic);
    try testing.expectEqual(try timestamp.parse("2026-10-17T13:46:36.836Z"), s.expire_time);
    try testing.expectEqualStrings("v", s.label("k").?);
    try testing.expectEqual(null, s.label("missing"));
    // And to a read after its topic was deleted.
    const orphan = try decodeSnapshot(a, "{\"name\":\"projects/p/snapshots/s\",\"topic\":\"_deleted-topic_\",\"expireTime\":\"2026-10-17T13:46:36Z\"}");
    try testing.expectEqualStrings("_deleted-topic_", orphan.topic);
    try testing.expectEqual(0, orphan.labels.len);
    // An expiry in any form a timestamp takes: nine digits, or an offset.
    const fine = try decodeSnapshot(a, "{\"expireTime\":\"2026-10-17T13:46:36.123456789Z\"}");
    try testing.expectEqual(123_456_789, @mod(fine.expire_time.nanoseconds, std.time.ns_per_s));
    try testing.expectEqual(fine.expire_time, (try decodeSnapshot(a, "{\"expireTime\":\"2026-10-17T15:46:36.123456789+02:00\"}")).expire_time);
    // A snapshot has an expiry: without one, or with one that is no time,
    // the answer is no snapshot.
    try testing.expectError(error.InvalidResponse, decodeSnapshot(a, "{\"name\":\"projects/p/snapshots/s\"}"));
    try testing.expectError(error.InvalidResponse, decodeSnapshot(a, "{\"expireTime\":\"next week\"}"));
    try testing.expectError(error.InvalidResponse, decodeSnapshot(a, "{\"expireTime\":17}"));

    const page = try decodeSnapshotPage(a,
        \\{"snapshots":[{"name":"projects/p/snapshots/a","topic":"projects/p/topics/t","expireTime":"2026-10-17T13:46:36.836Z"},
        \\{"name":"projects/p/snapshots/b","topic":"projects/p/topics/t","expireTime":"2026-10-17T13:46:36.839Z"}],"nextPageToken":"n"}
    );
    try testing.expectEqual(2, page.snapshots.len);
    try testing.expectEqualStrings("projects/p/snapshots/b", page.snapshots[1].name);
    try testing.expectEqualStrings("n", page.next_page_token.?);
    try testing.expectEqual(0, (try decodeSnapshotPage(a, "{}")).snapshots.len);
    try testing.expectEqual(null, (try decodeSnapshotPage(a, "{\"nextPageToken\":\"\"}")).next_page_token);
    // One that is no snapshot spoils its page.
    try testing.expectError(error.InvalidResponse, decodeSnapshotPage(a, "{\"snapshots\":[{\"name\":\"x\"}]}"));

    // A topic's lists hold names alone, under the key of what was asked for,
    // and production's page token is no name.
    const body =
        \\{"subscriptions":["projects/p/subscriptions/s","projects/other/subscriptions/far"],"nextPageToken":"enhhcGpTGwQLRFJ7VwwbBVEOGA"}
    ;
    const subs = try decodeNamePage(a, body, .subscriptions);
    try testing.expectEqual(2, subs.names.len);
    try testing.expectEqualStrings("projects/other/subscriptions/far", subs.names[1]);
    try testing.expectEqualStrings("enhhcGpTGwQLRFJ7VwwbBVEOGA", subs.next_page_token.?);
    try testing.expectEqual(0, (try decodeNamePage(a, body, .snapshots)).names.len);
    const snaps = try decodeNamePage(a, "{\"snapshots\":[\"projects/p/snapshots/a\"]}", .snapshots);
    try testing.expectEqualStrings("projects/p/snapshots/a", snaps.names[0]);
    try testing.expectEqual(null, snaps.next_page_token);
    try testing.expectEqual(0, (try decodeNamePage(a, "", .subscriptions)).names.len);
    try testing.expectError(error.InvalidResponse, decodeNamePage(a, "{\"subscriptions\":[{\"name\":\"x\"}]}", .subscriptions));
}

test "golden: snapshot create and update bodies" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings(
        "{\"subscription\":\"projects/p/subscriptions/orders\"}",
        try encodeSnapshot(a, "projects/p/subscriptions/orders", .{ .subscription = "orders" }),
    );
    try testing.expectEqualStrings(
        "{\"subscription\":\"projects/p/subscriptions/orders\",\"labels\":{\"env\":\"test\",\"team\":\"\"}}",
        try encodeSnapshot(a, "projects/p/subscriptions/orders", .{
            .subscription = "orders",
            .labels = &.{ .{ .key = "env", .value = "test" }, .{ .key = "team", .value = "" } },
        }),
    );
    try testing.expectEqualStrings(
        "{\"snapshot\":{\"labels\":{\"env\":\"prod\"}},\"updateMask\":\"labels\"}",
        try encodeSnapshotUpdate(a, .{ .labels = &.{.{ .key = "env", .value = "prod" }} }),
    );
    // An empty set clears: the mask names the labels, and the body holds none.
    try testing.expectEqualStrings(
        "{\"snapshot\":{\"labels\":{}},\"updateMask\":\"labels\"}",
        try encodeSnapshotUpdate(a, .{ .labels = &.{} }),
    );
}

fn snapshotRoundTrip(_: void, input: []const u8) !void {
    var g: ByteGen = .init(input);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const labels = try a.alloc(types.Label, g.intRange(u8, 0, 4));
    for (labels, 0..) |*l, i| l.* = .{
        .key = try a.print("k{d}{s}", .{ i, g.pick([]const u8, &.{ "", "_x", "-y", "z9" }) }),
        .value = g.pick([]const u8, &.{ "", "v", "prod", "a-b_c" }),
    };
    const config: types.SnapshotConfig = .{
        .subscription = g.pick([]const u8, &.{ "orders", "a%41+b", "projects/other/subscriptions/far" }),
        .labels = labels,
    };
    try @import("validate.zig").snapshotConfig(config, null);

    // The create body names the subscription it is given, and labels only
    // when there are some.
    const body = try encodeSnapshot(a, "projects/p/subscriptions/s", config);
    const sent = try std.json.parseFromSliceLeaky(struct {
        subscription: []const u8,
        labels: ?std.json.ArrayHashMap([]const u8) = null,
    }, a, body, .{});
    try testing.expectEqualStrings("projects/p/subscriptions/s", sent.subscription);
    try testing.expectEqual(labels.len == 0, sent.labels == null);
    // With the name and expiry the server adds, it reads back as the
    // snapshot that was asked for.
    const info = try decodeSnapshot(a, try a.print("{{\"name\":\"projects/p/snapshots/x\",\"expireTime\":\"2026-10-17T13:46:36.836Z\",{s}", .{body[1..]}));
    try testing.expectEqual(labels.len, info.labels.len);
    for (labels, info.labels) |want, have| {
        try testing.expectEqualStrings(want.key, have.key);
        try testing.expectEqualStrings(want.value, have.value);
    }
    // An update to the same labels names them in its mask, and carries them.
    const update = try std.json.parseFromSliceLeaky(struct {
        snapshot: struct { labels: std.json.ArrayHashMap([]const u8) },
        updateMask: []const u8,
    }, a, try encodeSnapshotUpdate(a, .{ .labels = labels }), .{});
    try testing.expectEqualStrings("labels", update.updateMask);
    try testing.expectEqual(labels.len, update.snapshot.labels.map.count());
    for (labels) |want| try testing.expectEqualStrings(want.value, update.snapshot.labels.map.get(want.key).?);
}

test "fuzz snapshot settings: a create body reads back as the snapshot asked for, and an update names its labels" {
    try test_util.fuzzBytes({}, snapshotRoundTrip, .{ .corpus = &.{ "", "\x04\x01\x02\x03\x00\x01\x02\x03\x02", "\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff" } });
}
