//! Public data types: messages, call options, results and configs. Results
//! come wrapped in core's `Owned`, re-exported here.

const std = @import("std");

pub const Owned = @import("core").Owned;

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
    /// Null sends the request body as it is.
    compression: ?Compression = null,
};

/// gzip for publish requests, as Google's own clients offer it. Pub/Sub
/// bills the messages uncompressed, so this saves bandwidth between the
/// publisher and Google, not Pub/Sub's charges, at some CPU: about 10 ms
/// per MB of JSON body at level 6 in ReleaseFast, the check included.
pub const Compression = struct {
    /// 1 (fastest) to 9 (smallest).
    level: u4 = 6,
    /// Request bodies shorter than this go as they are. Google's libraries
    /// compress from 240 bytes of messages; this counts the JSON body,
    /// which base64 makes a third bigger.
    min_bytes: u32 = 240,
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

/// A label on a topic or subscription.
pub const Label = struct {
    key: []const u8,
    value: []const u8,
};

/// What an update does to a setting that can be taken away: `.keep`,
/// `.set`, or `.clear`, which takes it away or puts back Pub/Sub's
/// default, as each field says. Core's, shared with the other modules.
pub const Change = @import("core").Change;

/// Where a topic's messages may be stored.
pub const MessageStoragePolicy = struct {
    /// Region ids, such as `europe-west1`. At least one.
    allowed_persistence_regions: []const []const u8,
    /// Refuse publishes and pulls in other regions instead of routing them.
    enforce_in_transit: bool = false,
};

/// Topic settings.
pub const TopicConfig = struct {
    /// At most 64. Keys: 1 to 63 characters, lowercase letters, digits,
    /// `_`, `-` or international characters, starting with a letter or an
    /// international character. Values: up to 63 of the same.
    labels: []const Label = &.{},
    /// Keep every message, acknowledged or not, for 10 minutes to 31 days,
    /// so subscriptions can replay them. Null: none.
    message_retention: ?std.Io.Duration = null,
    /// `projects/{p}/locations/{l}/keyRings/{r}/cryptoKeys/{k}`: encrypt
    /// messages with this Cloud KMS key. Null: Google's own keys.
    kms_key_name: ?[]const u8 = null,
    /// Null: the organization's policy.
    message_storage_policy: ?MessageStoragePolicy = null,
};

pub const TopicInfo = struct {
    /// Full resource name: `projects/{project}/topics/{id}`.
    name: []const u8,
    labels: []const Label = &.{},
    message_retention: ?std.Io.Duration = null,
    kms_key_name: ?[]const u8 = null,
    message_storage_policy: ?MessageStoragePolicy = null,
    state: State = .active,

    /// An unrecognized value from the server is `.unknown`.
    pub const State = enum { active, ingestion_resource_error, unknown };

    /// The value of the label named `key`, or null.
    pub fn label(self: TopicInfo, key: []const u8) ?[]const u8 {
        return findLabel(self.labels, key);
    }
};

/// What `Topic.update` changes. A field left at its default stays as it is.
pub const TopicUpdate = struct {
    /// Replaces every label; `&.{}` removes them all.
    labels: ?[]const Label = null,
    /// `.clear`: the topic keeps nothing itself.
    message_retention: Change(std.Io.Duration) = .keep,
    /// `.clear`: back to Google's own keys. Messages already stored keep
    /// the key they were written with.
    kms_key_name: Change([]const u8) = .keep,
    /// `.clear`: back to the organization's policy.
    message_storage_policy: Change(MessageStoragePolicy) = .keep,
};

pub const TopicPage = struct {
    topics: []const TopicInfo,
    /// Pass as `page_token` to get the next page. Null on the last page.
    next_page_token: ?[]const u8,
};

/// Where a message goes after too many deliveries.
pub const DeadLetterPolicy = struct {
    /// A topic id in this project, or `projects/{project}/topics/{id}` for
    /// another project's. It must exist, and Pub/Sub's service agent must
    /// be allowed to publish to it and to acknowledge on this subscription,
    /// or nothing is forwarded (see the README).
    topic: []const u8,
    /// 5 to 100.
    max_delivery_attempts: u8 = 5,
};

/// Pub/Sub's retry policy, named apart from `pubsub.RetryPolicy`, which is
/// this client's own: how long Pub/Sub waits before delivering a message
/// again after a release or a lapsed deadline.
pub const Backoff = struct {
    /// 0 to 600 seconds.
    minimum: std.Io.Duration = .fromSeconds(10),
    /// `minimum` to 600 seconds.
    maximum: std.Io.Duration = .fromSeconds(600),
};

/// When a subscription nobody uses is deleted.
pub const Expiration = union(enum) {
    /// After 31 days, Pub/Sub's default.
    default,
    never,
    /// At least a day, and at least the subscription's message retention.
    after: std.Io.Duration,
};

pub const SubscriptionConfig = struct {
    /// Id of a topic in the same project.
    topic_id: []const u8,
    /// 10 to 600 seconds, or 0 for Pub/Sub's default: 10, or 60 with
    /// exactly-once delivery.
    ack_deadline_seconds: u32 = 0,
    enable_message_ordering: bool = false,
    /// A message acknowledged before its deadline is never delivered
    /// again, and an acknowledgement that comes too late is refused rather
    /// than taken, so a subscriber can tell which of its acks held. Pull
    /// subscriptions only.
    enable_exactly_once_delivery: bool = false,
    /// Delivers only messages whose attributes match, such as
    /// `attributes.kind = "order"`; the rest are acknowledged unseen. At
    /// most 256 bytes; "" delivers everything. Fixed once created.
    filter: []const u8 = "",
    dead_letter_policy: ?DeadLetterPolicy = null,
    /// Null delivers again as soon as possible.
    retry_policy: ?Backoff = null,
    /// How long unacknowledged messages are kept: 10 minutes to 31 days.
    /// Null means Pub/Sub's default, 7 days.
    message_retention: ?std.Io.Duration = null,
    /// Keep acknowledged messages for the retention too, for replay.
    retain_acked_messages: bool = false,
    expiration: Expiration = .default,
    /// As for `TopicConfig.labels`.
    labels: []const Label = &.{},
};

pub const SubscriptionInfo = struct {
    /// Full resource name: `projects/{project}/subscriptions/{id}`.
    name: []const u8,
    /// Full topic name, or `_deleted-topic_` after the topic was deleted.
    topic: []const u8,
    ack_deadline_seconds: u32,
    enable_message_ordering: bool,
    enable_exactly_once_delivery: bool = false,
    /// "" when there is none.
    filter: []const u8 = "",
    /// Its topic is a full name.
    dead_letter_policy: ?DeadLetterPolicy = null,
    retry_policy: ?Backoff = null,
    /// Null when the server says nothing, as the emulator may not.
    message_retention: ?std.Io.Duration = null,
    retain_acked_messages: bool = false,
    expiration: Expiration = .default,
    labels: []const Label = &.{},
    /// Detached from its topic: pulls fail and nothing more is delivered.
    detached: bool = false,
    state: State = .active,
    /// Set when the topic keeps messages itself.
    topic_message_retention: ?std.Io.Duration = null,

    /// An unrecognized value from the server is `.unknown`.
    pub const State = enum { active, resource_error, unknown };

    /// The value of the label named `key`, or null.
    pub fn label(self: SubscriptionInfo, key: []const u8) ?[]const u8 {
        return findLabel(self.labels, key);
    }
};

/// What `Subscription.update` changes. A field left at its default stays as
/// it is. The topic, the ordering and the filter cannot be changed.
pub const SubscriptionUpdate = struct {
    /// 10 to 600.
    ack_deadline_seconds: ?u32 = null,
    enable_exactly_once_delivery: ?bool = null,
    /// `.clear`: no dead-lettering.
    dead_letter_policy: Change(DeadLetterPolicy) = .keep,
    /// `.clear`: deliver again as soon as possible.
    retry_policy: Change(Backoff) = .keep,
    /// `.clear`: back to 7 days.
    message_retention: Change(std.Io.Duration) = .keep,
    retain_acked_messages: ?bool = null,
    expiration: ?Expiration = null,
    /// Replaces every label; `&.{}` removes them all.
    labels: ?[]const Label = null,
};

fn findLabel(labels: []const Label, key: []const u8) ?[]const u8 {
    for (labels) |l| {
        if (std.mem.eql(u8, l.key, key)) return l.value;
    }
    return null;
}

/// What became of one ack id sent to `acknowledge` or `modifyAckDeadline`.
pub const AckResult = enum {
    /// The server took it.
    ok,
    /// Refused for good: the lease had lapsed, the message was already
    /// acknowledged, or the id is not one this subscription gave. Only a
    /// subscription with exactly-once delivery refuses these; the message
    /// may be delivered again.
    invalid_ack_id,
    /// Refused for now, and still refused when the call's retries ran out.
    /// Sending it again later may succeed.
    transient,
    /// Refused for another reason, or its request failed as a whole with an
    /// answer that says nothing about single ids. `Diagnostics` has the
    /// server's words.
    other,
};

pub const SubscriptionPage = struct {
    subscriptions: []const SubscriptionInfo,
    /// Pass as `page_token` to get the next page. Null on the last page.
    next_page_token: ?[]const u8,
};

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

test "compression is off unless asked for, and asks for level 6 from 240 bytes" {
    try std.testing.expectEqual(null, (PublishOptions{}).compression);
    const c: Compression = .{};
    try std.testing.expectEqual(6, c.level);
    try std.testing.expectEqual(240, c.min_bytes);
}
