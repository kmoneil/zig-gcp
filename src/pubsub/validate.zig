//! Client-side checks, run before any request: the API's fixed limits, the
//! resource-name rules, and UTF-8 validity (JSON strings must be UTF-8, and
//! `std.json.Stringify` does not check). Only cheap, fixed rules are checked;
//! the server has the final word on everything else. A failed check fills
//! `Diagnostics` with the reason.
//!
//! Limits are from https://docs.cloud.google.com/pubsub/quotas and were
//! measured against production on 2026-09-18: several are stricter or more
//! precise than the documentation says, as noted below. They are fixed
//! limits, not adjustable quotas.

const std = @import("std");
const codec = @import("codec.zig");
const types = @import("types.zig");
const Diagnostics = @import("core").Diagnostics;
const timestamp = @import("core").timestamp;
const test_util = @import("test_util.zig");

pub const max_messages_per_publish = 1000;
/// The documented "10 MB" is the size of the HTTP request body, JSON and
/// base64 included (production: "Request payload size exceeds the limit:
/// 10485760 bytes"). Base64 grows data by a third, so over REST a single
/// message holds at most 7,864,299 bytes of raw data.
pub const max_publish_request_bytes = 10 * 1024 * 1024;
/// The documented per-message limit. Over REST the request limit is stricter.
pub const max_data_bytes = 10 * 1024 * 1024;
pub const max_attributes = 100;
pub const max_attribute_key_bytes = 256;
pub const max_attribute_value_bytes = 1024;
/// Undocumented; production rejects longer keys. Counted in UTF-8 bytes.
pub const max_ordering_key_bytes = 1024;
pub const max_pull_messages = 1000;
/// "512 KB" is 524,288 bytes of HTTP request body per acknowledge or
/// modifyAckDeadline call.
pub const max_ack_request_bytes = 512 * 1024;
/// Google's own clients send at most 2500 ack ids per request.
pub const max_ack_ids_per_request = 2500;
pub const min_ack_deadline_seconds = 10;
pub const max_ack_deadline_seconds = 600;
/// A subscription's filter, in bytes ("the maximum length of a filter
/// expression is 256 bytes"). The emulator takes longer ones.
pub const max_filter_bytes = 256;
/// Labels per topic or subscription, and characters per key or value.
pub const max_labels = 64;
pub const max_label_chars = 63;
/// A subscription's or a topic's message retention.
pub const min_message_retention: std.Io.Duration = .fromSeconds(10 * 60);
pub const max_message_retention: std.Io.Duration = .fromSeconds(31 * 24 * 60 * 60);
/// The shortest expiration ttl. The emulator takes shorter ones.
pub const min_expiration: std.Io.Duration = .fromSeconds(24 * 60 * 60);
/// Each bound of a retry policy's backoff.
pub const max_backoff: std.Io.Duration = .fromSeconds(600);
/// A dead-letter policy's deliveries before a message is forwarded.
pub const min_delivery_attempts = 5;
pub const max_delivery_attempts = 100;

/// The exact size of the body `Topic.publish` would send, without encoding
/// anything. Callers splitting large batches can compare it with
/// `max_publish_request_bytes`.
pub fn publishRequestBytes(messages: []const types.Message, ordering_key: ?[]const u8) usize {
    return codec.publishBodyLen(messages, ordering_key);
}

/// Topic and subscription ids: 3 to 255 characters from `[A-Za-z0-9-_.~+%]`,
/// starting with a letter, and not starting with "goog" in any case.
/// Storage names topics too, so the rule lives in core with its tests.
pub const isResourceId = @import("core").names.isPubSubId;

/// Project ids and numbers, including legacy domain-scoped ids such as
/// `example.com:my-project`. Shared with the other service modules, so it
/// lives in core; the tests for it are there too.
pub const isProjectId = @import("core").names.isProjectId;

/// Checks a publish call: message count, per-message rules, UTF-8, and the
/// size of the encoded request.
pub fn publish(
    messages: []const types.Message,
    ordering_key: ?[]const u8,
    diag: ?*Diagnostics,
) error{InvalidMessage}!void {
    if (messages.len == 0) return reject(diag, "publish needs at least one message", .{});
    if (messages.len > max_messages_per_publish) {
        return reject(diag, "publish has {d} messages; the limit is {d}", .{ messages.len, max_messages_per_publish });
    }
    const key = ordering_key orelse "";
    if (!std.unicode.utf8ValidateSlice(key)) return reject(diag, "the ordering key is not valid UTF-8", .{});
    if (key.len > max_ordering_key_bytes) {
        return reject(diag, "the ordering key has {d} bytes; the limit is {d}", .{ key.len, max_ordering_key_bytes });
    }

    for (messages, 0..) |m, i| {
        if (m.data.len == 0 and m.attributes.len == 0) {
            return reject(diag, "message {d} has no data and no attributes", .{i});
        }
        if (m.data.len > max_data_bytes) {
            return reject(diag, "message {d} has {d} bytes of data; the limit is {d}", .{ i, m.data.len, max_data_bytes });
        }
        if (m.attributes.len > max_attributes) {
            return reject(diag, "message {d} has {d} attributes; the limit is {d}", .{ i, m.attributes.len, max_attributes });
        }
        for (m.attributes, 0..) |a, j| {
            // Production rejects these; the emulator does not.
            if (a.key.len == 0 or std.ascii.startsWithIgnoreCase(a.key, "goog")) {
                return reject(diag, "message {d}, attribute {d}: keys must be non-empty and not start with \"goog\"", .{ i, j });
            }
            if (a.key.len > max_attribute_key_bytes) {
                return reject(diag, "message {d}, attribute {d}: the key has {d} bytes; the limit is {d}", .{ i, j, a.key.len, max_attribute_key_bytes });
            }
            if (a.value.len > max_attribute_value_bytes) {
                return reject(diag, "message {d}, attribute {d}: the value has {d} bytes; the limit is {d}", .{ i, j, a.value.len, max_attribute_value_bytes });
            }
            if (!std.unicode.utf8ValidateSlice(a.key) or !std.unicode.utf8ValidateSlice(a.value)) {
                return reject(diag, "message {d}, attribute {d}: keys and values must be valid UTF-8", .{ i, j });
            }
            for (m.attributes[0..j]) |earlier| {
                if (std.mem.eql(u8, earlier.key, a.key)) {
                    return reject(diag, "message {d}, attribute {d}: the key repeats an earlier attribute", .{ i, j });
                }
            }
        }
    }
    const body_bytes = publishRequestBytes(messages, ordering_key);
    if (body_bytes > max_publish_request_bytes) {
        return reject(diag, "the publish request would be {d} bytes; the limit is {d}, and base64 grows data by a third", .{ body_bytes, max_publish_request_bytes });
    }
}

/// Ack ids are opaque, but they travel as JSON strings, so they must be UTF-8.
pub fn ackIds(ack_ids: []const []const u8, diag: ?*Diagnostics) error{InvalidArgument}!void {
    for (ack_ids, 0..) |id, i| {
        if (!std.unicode.utf8ValidateSlice(id)) {
            if (diag) |d| d.print("ack id {d} is not valid UTF-8", .{i});
            return error.InvalidArgument;
        }
    }
}

/// `modifyAckDeadline` accepts 0 (nack) to 600 seconds.
pub fn modifyDeadline(seconds: u32, diag: ?*Diagnostics) error{InvalidArgument}!void {
    if (seconds > max_ack_deadline_seconds) {
        if (diag) |d| d.print("ack deadline {d} s is over the {d} s limit", .{ seconds, max_ack_deadline_seconds });
        return error.InvalidArgument;
    }
}

/// A subscription's ack deadline is 10 to 600 seconds, or 0 for the default.
pub fn subscriptionDeadline(seconds: u32, diag: ?*Diagnostics) error{InvalidArgument}!void {
    if (seconds != 0 and (seconds < min_ack_deadline_seconds or seconds > max_ack_deadline_seconds)) {
        if (diag) |d| d.print("ack deadline {d} s is outside {d}..{d} s", .{ seconds, min_ack_deadline_seconds, max_ack_deadline_seconds });
        return error.InvalidArgument;
    }
}

pub fn clampPullMessages(max_messages: u32) u32 {
    return std.math.clamp(max_messages, 1, max_pull_messages);
}

/// Labels: at most 64, each key 1 to 63 characters and each value up to 63,
/// of lowercase ASCII letters, digits, `_` and `-`, with a key starting
/// with a lowercase letter. Non-ASCII characters, which Google allows as
/// "international characters", are passed through for the server to judge.
/// Keys must not repeat.
pub fn labels(list: []const types.Label, diag: ?*Diagnostics) error{InvalidArgument}!void {
    if (list.len > max_labels) return refuse(diag, "{d} labels; the limit is {d}", .{ list.len, max_labels });
    for (list, 0..) |l, i| {
        try labelText(l.key, true, i, diag);
        try labelText(l.value, false, i, diag);
        for (list[0..i]) |earlier| {
            if (std.mem.eql(u8, earlier.key, l.key)) return refuse(diag, "label {d}: the key repeats an earlier label's", .{i});
        }
    }
}

fn labelText(text: []const u8, is_key: bool, index: usize, diag: ?*Diagnostics) error{InvalidArgument}!void {
    const what = if (is_key) "key" else "value";
    const chars = std.unicode.utf8CountCodepoints(text) catch
        return refuse(diag, "label {d}: the {s} is not valid UTF-8", .{ index, what });
    if (is_key and chars == 0) return refuse(diag, "label {d}: the key is empty", .{index});
    if (chars > max_label_chars) return refuse(diag, "label {d}: the {s} has {d} characters; the limit is {d}", .{ index, what, chars, max_label_chars });
    for (text, 0..) |c, j| switch (c) {
        'a'...'z', 0x80...0xff => {},
        '0'...'9', '_', '-' => if (is_key and j == 0)
            return refuse(diag, "label {d}: a key starts with a lowercase letter", .{index}),
        else => return refuse(diag, "label {d}: the {s} holds byte 0x{x:0>2}; labels take lowercase letters, digits, '_' and '-'", .{ index, what, c }),
    };
}

/// A compression level: 1 to 9.
pub fn compression(c: types.Compression, diag: ?*Diagnostics) error{InvalidArgument}!void {
    if (c.level < 1 or c.level > 9) return refuse(diag, "compression level {d} is outside 1 to 9", .{c.level});
}

/// A subscription's filter: at most 256 bytes of UTF-8. Its grammar is the
/// server's to check.
pub fn filter(text: []const u8, diag: ?*Diagnostics) error{InvalidArgument}!void {
    if (text.len > max_filter_bytes) return refuse(diag, "the filter has {d} bytes; the limit is {d}", .{ text.len, max_filter_bytes });
    if (!std.unicode.utf8ValidateSlice(text)) return refuse(diag, "the filter is not valid UTF-8", .{});
}

/// A dead-letter policy: 5 to 100 attempts, and a topic id or a full topic
/// name.
pub fn deadLetterPolicy(policy: types.DeadLetterPolicy, diag: ?*Diagnostics) error{InvalidArgument}!void {
    if (policy.max_delivery_attempts < min_delivery_attempts or policy.max_delivery_attempts > max_delivery_attempts) {
        return refuse(diag, "max_delivery_attempts {d} is outside {d} to {d}", .{ policy.max_delivery_attempts, min_delivery_attempts, max_delivery_attempts });
    }
    if (isResourceId(policy.topic) or isTopicName(policy.topic)) return;
    return refuse(diag, "the dead-letter topic is neither a topic id nor projects/{{project}}/topics/{{id}}", .{});
}

/// `projects/{project}/topics/{id}`, with a valid project and topic id.
pub fn isTopicName(name: []const u8) bool {
    return isNameIn(name, "/topics/");
}

/// `projects/{project}/subscriptions/{id}`, with a valid project and
/// subscription id.
pub fn isSubscriptionName(name: []const u8) bool {
    return isNameIn(name, "/subscriptions/");
}

/// `projects/{project}/snapshots/{id}`, with a valid project and snapshot
/// id.
pub fn isSnapshotName(name: []const u8) bool {
    return isNameIn(name, "/snapshots/");
}

fn isNameIn(name: []const u8, comptime collection: []const u8) bool {
    const prefix = "projects/";
    if (!std.mem.startsWith(u8, name, prefix)) return false;
    const rest = name[prefix.len..];
    const cut = std.mem.indexOf(u8, rest, collection) orelse return false;
    return isProjectId(rest[0..cut]) and isResourceId(rest[cut + collection.len ..]);
}

/// A retry policy: each bound 0 to 600 seconds, the minimum no more than the
/// maximum.
pub fn backoff(b: types.Backoff, diag: ?*Diagnostics) error{InvalidArgument}!void {
    inline for (.{ .{ "minimum", b.minimum }, .{ "maximum", b.maximum } }) |bound| {
        const d: std.Io.Duration = bound[1];
        if (d.nanoseconds < 0 or d.nanoseconds > max_backoff.nanoseconds) {
            return refuse(diag, "the retry policy's " ++ bound[0] ++ " backoff is outside 0 to 600 s", .{});
        }
    }
    if (b.minimum.nanoseconds > b.maximum.nanoseconds) return refuse(diag, "the retry policy's minimum backoff is over its maximum", .{});
}

/// Message retention: 10 minutes to 31 days.
pub fn messageRetention(d: std.Io.Duration, diag: ?*Diagnostics) error{InvalidArgument}!void {
    if (d.nanoseconds < min_message_retention.nanoseconds or d.nanoseconds > max_message_retention.nanoseconds) {
        return refuse(diag, "message retention is outside 10 minutes to 31 days", .{});
    }
}

/// An expiration: a ttl of at least a day, and at least the retention.
pub fn expiration(e: types.Expiration, retention: ?std.Io.Duration, diag: ?*Diagnostics) error{InvalidArgument}!void {
    const ttl = switch (e) {
        .default, .never => return,
        .after => |ttl| ttl,
    };
    if (ttl.nanoseconds < min_expiration.nanoseconds) return refuse(diag, "the expiration ttl is under a day", .{});
    if (ttl.nanoseconds > @as(i96, @import("core").duration.max_seconds) * std.time.ns_per_s) {
        return refuse(diag, "the expiration ttl is out of range", .{});
    }
    if (retention) |r| if (ttl.nanoseconds < r.nanoseconds) return refuse(diag, "the expiration ttl is shorter than the message retention", .{});
}

/// A Cloud KMS key: `projects/{p}/locations/{l}/keyRings/{r}/cryptoKeys/{k}`,
/// each part non-empty.
pub fn kmsKeyName(name: []const u8, diag: ?*Diagnostics) error{InvalidArgument}!void {
    var parts = std.mem.splitScalar(u8, name, '/');
    for ([_][]const u8{ "projects", "", "locations", "", "keyRings", "", "cryptoKeys", "" }) |want| {
        const part = parts.next() orelse break;
        if (part.len == 0 or (want.len > 0 and !std.mem.eql(u8, part, want))) break;
    } else if (parts.next() == null and std.unicode.utf8ValidateSlice(name)) return;
    return refuse(diag, "the KMS key is not projects/{{p}}/locations/{{l}}/keyRings/{{r}}/cryptoKeys/{{k}}", .{});
}

/// A message storage policy: at least one region, none empty.
pub fn storagePolicy(policy: types.MessageStoragePolicy, diag: ?*Diagnostics) error{InvalidArgument}!void {
    if (policy.allowed_persistence_regions.len == 0) return refuse(diag, "a message storage policy needs at least one region", .{});
    for (policy.allowed_persistence_regions, 0..) |region, i| {
        if (region.len == 0 or !std.unicode.utf8ValidateSlice(region)) return refuse(diag, "region {d} is empty or not valid UTF-8", .{i});
    }
}

/// Every setting of a new subscription, before anything is sent.
pub fn subscriptionConfig(config: types.SubscriptionConfig, diag: ?*Diagnostics) error{InvalidArgument}!void {
    try subscriptionDeadline(config.ack_deadline_seconds, diag);
    try filter(config.filter, diag);
    if (config.dead_letter_policy) |p| try deadLetterPolicy(p, diag);
    if (config.retry_policy) |b| try backoff(b, diag);
    if (config.message_retention) |r| try messageRetention(r, diag);
    try expiration(config.expiration, config.message_retention, diag);
    try labels(config.labels, diag);
}

/// Every setting of a new topic, before anything is sent.
pub fn topicConfig(config: types.TopicConfig, diag: ?*Diagnostics) error{InvalidArgument}!void {
    try labels(config.labels, diag);
    if (config.message_retention) |r| try messageRetention(r, diag);
    if (config.kms_key_name) |k| try kmsKeyName(k, diag);
    if (config.message_storage_policy) |p| try storagePolicy(p, diag);
}

/// A subscription update: something to change, and every new value valid.
pub fn subscriptionUpdate(u: types.SubscriptionUpdate, diag: ?*Diagnostics) error{InvalidArgument}!void {
    if (u.ack_deadline_seconds) |s| {
        if (s < min_ack_deadline_seconds or s > max_ack_deadline_seconds) {
            return refuse(diag, "ack deadline {d} s is outside {d}..{d} s", .{ s, min_ack_deadline_seconds, max_ack_deadline_seconds });
        }
    }
    switch (u.dead_letter_policy) {
        .set => |p| try deadLetterPolicy(p, diag),
        else => {},
    }
    switch (u.retry_policy) {
        .set => |b| try backoff(b, diag),
        else => {},
    }
    const retention: ?std.Io.Duration = switch (u.message_retention) {
        .set => |r| r,
        else => null,
    };
    if (retention) |r| try messageRetention(r, diag);
    if (u.expiration) |e| try expiration(e, retention, diag);
    if (u.labels) |l| try labels(l, diag);
    const changes_something = u.ack_deadline_seconds != null or u.enable_exactly_once_delivery != null or
        u.dead_letter_policy != .keep or u.retry_policy != .keep or u.message_retention != .keep or
        u.retain_acked_messages != null or u.expiration != null or u.labels != null;
    if (!changes_something) return refuse(diag, "the update changes nothing", .{});
}

/// A topic update: something to change, and every new value valid.
pub fn topicUpdate(u: types.TopicUpdate, diag: ?*Diagnostics) error{InvalidArgument}!void {
    if (u.labels) |l| try labels(l, diag);
    switch (u.message_retention) {
        .set => |r| try messageRetention(r, diag),
        else => {},
    }
    switch (u.kms_key_name) {
        .set => |k| try kmsKeyName(k, diag),
        else => {},
    }
    switch (u.message_storage_policy) {
        .set => |p| try storagePolicy(p, diag),
        else => {},
    }
    if (u.labels == null and u.message_retention == .keep and u.kms_key_name == .keep and u.message_storage_policy == .keep) {
        return refuse(diag, "the update changes nothing", .{});
    }
}

/// A snapshot's settings: a subscription id or a full subscription name,
/// and labels by the rules for every label. The emulator keeps no labels,
/// so it cannot hold one to them.
pub fn snapshotConfig(config: types.SnapshotConfig, diag: ?*Diagnostics) error{InvalidArgument}!void {
    if (!isResourceId(config.subscription) and !isSubscriptionName(config.subscription)) {
        return refuse(diag, "the subscription is neither a subscription id nor projects/{{project}}/subscriptions/{{id}}", .{});
    }
    try labels(config.labels, diag);
}

/// A snapshot update: something to change, and the new labels valid.
pub fn snapshotUpdate(u: types.SnapshotUpdate, diag: ?*Diagnostics) error{InvalidArgument}!void {
    const l = u.labels orelse return refuse(diag, "the update changes nothing", .{});
    try labels(l, diag);
}

/// A seek's target: a time a `google.protobuf.Timestamp` can hold, or a
/// snapshot id or full snapshot name.
pub fn seekTarget(target: types.SeekTarget, diag: ?*Diagnostics) error{InvalidArgument}!void {
    switch (target) {
        .time => |t| if (!timestamp.inRange(t)) {
            return refuse(diag, "the seek time is outside 0001-01-01T00:00:00Z to 9999-12-31T23:59:59.999999999Z", .{});
        },
        .snapshot => |s| if (!isResourceId(s) and !isSnapshotName(s)) {
            return refuse(diag, "the snapshot is neither a snapshot id nor projects/{{project}}/snapshots/{{id}}", .{});
        },
    }
}

fn refuse(diag: ?*Diagnostics, comptime format: []const u8, args: anytype) error{InvalidArgument} {
    if (diag) |d| d.print(format, args);
    return error.InvalidArgument;
}

fn reject(diag: ?*Diagnostics, comptime format: []const u8, args: anytype) error{InvalidMessage} {
    if (diag) |d| d.print(format, args);
    return error.InvalidMessage;
}

const testing = std.testing;

fn expectRejected(messages: []const types.Message, ordering_key: ?[]const u8, want: []const u8) !void {
    var d: Diagnostics = .{};
    try testing.expectError(error.InvalidMessage, publish(messages, ordering_key, &d));
    if (std.mem.indexOf(u8, d.message(), want) == null) {
        std.debug.print("diagnostics \"{s}\" lacks \"{s}\"\n", .{ d.message(), want });
        return error.TestUnexpectedDiagnostics;
    }
}

test "publish limits: each at its boundary and one past it" {
    const gpa = testing.allocator;

    // Message count.
    const many = try gpa.alloc(types.Message, max_messages_per_publish + 1);
    defer gpa.free(many);
    @memset(many, .{ .data = "x" });
    try publish(many[0..max_messages_per_publish], null, null);
    try expectRejected(many, null, "1001 messages");
    try expectRejected(&.{}, null, "at least one");

    // Data size: the documented per-message limit is checked first...
    const big = try gpa.alloc(u8, max_data_bytes + 1);
    defer gpa.free(big);
    @memset(big, 'd');
    try expectRejected(&.{.{ .data = big }}, null, "bytes of data");
    // ...but over REST the encoded request is the real limit. Measured in
    // production: a 10,485,760-byte body is accepted, one more byte is not.
    // `{"messages":[{"data":""}]}` is 26 bytes; 7,864,299 bytes of data
    // encode to 10,485,732 bytes of base64.
    try testing.expectEqual(10_485_758, publishRequestBytes(&.{.{ .data = big[0..7_864_299] }}, null));
    try publish(&.{.{ .data = big[0..7_864_299] }}, null, null);
    try expectRejected(&.{.{ .data = big[0..7_864_300] }}, null, "the publish request would be 10485762 bytes");
    // The exact boundary: 7,864,284 bytes of data make a 10,485,738-byte
    // body, and `,"orderingKey":"abcde"` adds the last 22.
    try testing.expectEqual(10_485_760, publishRequestBytes(&.{.{ .data = big[0..7_864_284] }}, "abcde"));
    try publish(&.{.{ .data = big[0..7_864_284] }}, "abcde", null);
    try expectRejected(&.{.{ .data = big[0..7_864_284] }}, "abcdef", "10485761 bytes");

    // Attribute count, key size, value size.
    var attrs: [max_attributes + 1]types.Attribute = undefined;
    var names: [max_attributes + 1][4]u8 = undefined;
    for (&attrs, &names, 0..) |*a, *n, i| {
        n.* = .{ 'k', @intCast('0' + i / 100), @intCast('0' + i / 10 % 10), @intCast('0' + i % 10) };
        a.* = .{ .key = n, .value = "v" };
    }
    try publish(&.{.{ .attributes = attrs[0..max_attributes] }}, null, null);
    try expectRejected(&.{.{ .attributes = &attrs }}, null, "101 attributes");

    const key: [max_attribute_key_bytes + 1]u8 = @splat('k');
    try publish(&.{.{ .attributes = &.{.{ .key = key[0..max_attribute_key_bytes], .value = "" }} }}, null, null);
    try expectRejected(&.{.{ .attributes = &.{.{ .key = &key, .value = "" }} }}, null, "the key has 257 bytes");

    const value: [max_attribute_value_bytes + 1]u8 = @splat('v');
    try publish(&.{.{ .attributes = &.{.{ .key = "k", .value = value[0..max_attribute_value_bytes] }} }}, null, null);
    try expectRejected(&.{.{ .attributes = &.{.{ .key = "k", .value = &value }} }}, null, "the value has 1025 bytes");

    // Several messages share the request limit.
    try expectRejected(&.{ .{ .data = big[0..5_000_000] }, .{ .data = big[0..5_000_000] } }, null, "the publish request would be");

    // Ordering keys: at most 1024 UTF-8 bytes, measured in production.
    const long_key: [max_ordering_key_bytes + 1]u8 = @splat('o');
    try publish(&.{.{ .data = "x" }}, long_key[0..max_ordering_key_bytes], null);
    try expectRejected(&.{.{ .data = "x" }}, &long_key, "the ordering key has 1025 bytes");
    try publish(&.{.{ .data = "x" }}, test_util.repeat("é", 512), null);
    try expectRejected(&.{.{ .data = "x" }}, test_util.repeat("é", 513), "the ordering key has 1026 bytes");
}

test "publish rules: empty messages, duplicate keys, UTF-8" {
    try expectRejected(&.{ .{ .data = "x" }, .{} }, null, "message 1 has no data and no attributes");
    try publish(&.{.{ .attributes = &.{.{ .key = "k", .value = "" }} }}, null, null);
    try publish(&.{.{ .data = "\xff\xfe binary is fine" }}, "", null);
    try expectRejected(&.{.{ .attributes = &.{
        .{ .key = "a", .value = "1" },
        .{ .key = "b", .value = "2" },
        .{ .key = "a", .value = "3" },
    } }}, null, "attribute 2: the key repeats");
    try expectRejected(&.{.{ .attributes = &.{.{ .key = "\xff", .value = "" }} }}, null, "valid UTF-8");
    try expectRejected(&.{.{ .attributes = &.{.{ .key = "k", .value = "\xc3" }} }}, null, "valid UTF-8");
    try expectRejected(&.{.{ .data = "x" }}, "\xed\xa0\x80", "ordering key");
    try publish(&.{.{ .data = "x", .attributes = &.{.{ .key = "é", .value = "😀" }} }}, "ключ", null);
}

test "publish rules: attribute keys production rejects" {
    // The emulator accepts all of these; production answers INVALID_ARGUMENT.
    try expectRejected(&.{.{ .attributes = &.{.{ .key = "", .value = "v" }} }}, null, "keys must be non-empty");
    try expectRejected(&.{.{ .attributes = &.{.{ .key = "googfoo", .value = "v" }} }}, null, "not start with \"goog\"");
    try expectRejected(&.{.{ .attributes = &.{.{ .key = "GooGle", .value = "v" }} }}, null, "not start with \"goog\"");
    try expectRejected(&.{.{ .data = "x", .attributes = &.{ .{ .key = "ok", .value = "" }, .{ .key = "GOOG", .value = "" } } }}, null, "attribute 1");
    try publish(&.{.{ .attributes = &.{.{ .key = "xgoog", .value = "v" }} }}, null, null);
    try publish(&.{.{ .attributes = &.{.{ .key = "goo", .value = "v" }} }}, null, null);
}

test "ack ids and deadlines" {
    var d: Diagnostics = .{};
    try ackIds(&.{ "projects/p/subscriptions/s:1", "" }, &d);
    try testing.expectError(error.InvalidArgument, ackIds(&.{ "ok", "\x80" }, &d));
    try testing.expectEqualStrings("ack id 1 is not valid UTF-8", d.message());

    try modifyDeadline(0, null);
    try modifyDeadline(600, null);
    try testing.expectError(error.InvalidArgument, modifyDeadline(601, null));

    try subscriptionDeadline(0, null);
    try testing.expectError(error.InvalidArgument, subscriptionDeadline(9, null));
    try subscriptionDeadline(10, null);
    try subscriptionDeadline(600, null);
    try testing.expectError(error.InvalidArgument, subscriptionDeadline(601, null));

    try testing.expectEqual(1, clampPullMessages(0));
    try testing.expectEqual(10, clampPullMessages(10));
    try testing.expectEqual(1000, clampPullMessages(1000));
    try testing.expectEqual(1000, clampPullMessages(std.math.maxInt(u32)));
}

fn validatedIsEncodable(_: void, input: []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var g: test_util.ByteGen = .init(input);
    // Arbitrary bytes everywhere, including invalid UTF-8 and repeated keys.
    const messages = try a.alloc(types.Message, g.intRange(usize, 0, 3));
    for (messages) |*m| {
        const attrs = try a.alloc(types.Attribute, g.intRange(usize, 0, 3));
        for (attrs) |*attr| attr.* = .{ .key = g.slice(8), .value = g.slice(8) };
        m.* = .{ .data = g.slice(16), .attributes = attrs };
    }
    const ordering_key: ?[]const u8 = if (g.boolean()) g.slice(8) else null;

    publish(messages, ordering_key, null) catch return;
    // Whatever passes validation must encode to valid JSON within the limit.
    const body = try codec.encodePublish(a, messages, ordering_key);
    try testing.expect(std.unicode.utf8ValidateSlice(body));
    try testing.expect(body.len <= max_publish_request_bytes);
    _ = try std.json.parseFromSliceLeaky(std.json.Value, a, body, .{});
}

test "fuzz publish validation: what passes always encodes to valid JSON" {
    try test_util.fuzzBytes({}, validatedIsEncodable, .{ .corpus = &.{
        "\x01\x01\x02\xff\xfe\x01v\x03abc\x00",
        "\x01\x02\x01a\x01b\x01a\x01c\x00\x00",
        "\x00",
    } });
}

fn resourceIdProperty(_: void, input: []const u8) !void {
    // Accepted ids never need anything but the documented characters, so
    // they are safe in URLs once `%` and `+` are encoded.
    if (!isResourceId(input)) return;
    try testing.expect(input.len >= 3 and input.len <= 255);
    try testing.expect(std.ascii.isAlphabetic(input[0]));
    for (input) |c| try testing.expect(std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "-_.~+%", c) != null);
}

test "fuzz resource ids" {
    try test_util.fuzzBytes({}, resourceIdProperty, .{ .corpus = &.{ "abc", "googx", "a%41", "Zz9" } });
}

test "labels: the rules at their boundaries" {
    var d: Diagnostics = .{};
    const ok = [_][]const types.Label{
        &.{},
        &.{.{ .key = "a", .value = "" }},
        &.{.{ .key = "team", .value = "zig-gcp_1" }},
        &.{.{ .key = "k" ++ test_util.repeat("x", 62), .value = test_util.repeat("v", 63) }},
        // International characters go to the server to judge.
        &.{.{ .key = "équipe", .value = "zürich" }},
        &.{.{ .key = "日本", .value = "東京" }},
    };
    for (ok) |list| try labels(list, &d);
    const refused = [_]struct { []const types.Label, []const u8 }{
        .{ &.{.{ .key = "", .value = "v" }}, "the key is empty" },
        .{ &.{.{ .key = "Team", .value = "v" }}, "byte 0x54" },
        .{ &.{.{ .key = "team", .value = "Prod" }}, "byte 0x50" },
        .{ &.{.{ .key = "1team", .value = "v" }}, "starts with a lowercase letter" },
        .{ &.{.{ .key = "_team", .value = "v" }}, "starts with a lowercase letter" },
        .{ &.{.{ .key = "a b", .value = "v" }}, "byte 0x20" },
        .{ &.{.{ .key = "k" ++ test_util.repeat("x", 63), .value = "v" }}, "64 characters" },
        .{ &.{.{ .key = "k", .value = test_util.repeat("v", 64) }}, "64 characters" },
        .{ &.{.{ .key = "k", .value = "\xc0" }}, "not valid UTF-8" },
        .{ &.{ .{ .key = "k", .value = "1" }, .{ .key = "k", .value = "2" } }, "repeats" },
    };
    for (refused) |case| {
        try testing.expectError(error.InvalidArgument, labels(case[0], &d));
        try testing.expect(std.mem.indexOf(u8, d.message(), case[1]) != null);
    }
    var many: [max_labels + 1]types.Label = undefined;
    var keys: [max_labels + 1][4]u8 = undefined;
    for (&many, &keys, 0..) |*l, *k, i| l.* = .{ .key = std.fmt.bufPrint(k, "k{d}", .{i}) catch unreachable, .value = "" };
    try labels(many[0..max_labels], &d);
    try testing.expectError(error.InvalidArgument, labels(&many, &d));
}

test "subscription settings: each rule at its boundary" {
    var d: Diagnostics = .{};
    const base: types.SubscriptionConfig = .{ .topic_id = "t" };
    try subscriptionConfig(base, &d);

    var c = base;
    c.filter = test_util.repeat("x", max_filter_bytes);
    try subscriptionConfig(c, &d);
    c.filter = test_util.repeat("x", max_filter_bytes + 1);
    try testing.expectError(error.InvalidArgument, subscriptionConfig(c, &d));

    for ([_]u8{ 5, 100 }) |n| try deadLetterPolicy(.{ .topic = "dead", .max_delivery_attempts = n }, &d);
    for ([_]u8{ 0, 4, 101 }) |n| try testing.expectError(error.InvalidArgument, deadLetterPolicy(.{ .topic = "dead", .max_delivery_attempts = n }, &d));
    try deadLetterPolicy(.{ .topic = "projects/other-project/topics/dead" }, &d);
    for ([_][]const u8{ "de", "projects//topics/dead", "projects/p/topics/", "projects/p/subscriptions/dead", "goog-dead" }) |topic| {
        try testing.expectError(error.InvalidArgument, deadLetterPolicy(.{ .topic = topic }, &d));
    }

    try backoff(.{ .minimum = .zero, .maximum = .zero }, &d);
    try backoff(.{ .minimum = .fromSeconds(600), .maximum = .fromSeconds(600) }, &d);
    try testing.expectError(error.InvalidArgument, backoff(.{ .minimum = .fromMilliseconds(600_001) }, &d));
    try testing.expectError(error.InvalidArgument, backoff(.{ .minimum = .fromSeconds(20), .maximum = .fromSeconds(10) }, &d));
    try testing.expectError(error.InvalidArgument, backoff(.{ .minimum = .fromNanoseconds(-1) }, &d));

    try messageRetention(min_message_retention, &d);
    try messageRetention(max_message_retention, &d);
    try testing.expectError(error.InvalidArgument, messageRetention(.fromSeconds(599), &d));
    try testing.expectError(error.InvalidArgument, messageRetention(.fromSeconds(31 * 24 * 3600 + 1), &d));

    try expiration(.{ .after = min_expiration }, null, &d);
    try expiration(.never, .fromSeconds(99 * 24 * 3600), &d);
    try testing.expectError(error.InvalidArgument, expiration(.{ .after = .fromSeconds(24 * 3600 - 1) }, null, &d));
    // A ttl the wire format itself cannot carry.
    try testing.expectError(error.InvalidArgument, expiration(.{ .after = .fromSeconds(@as(i64, @import("core").duration.max_seconds) + 1) }, null, &d));
    try testing.expectEqualStrings("the expiration ttl is out of range", d.message());
    // No shorter than the retention it would outlive.
    try expiration(.{ .after = .fromSeconds(2 * 24 * 3600) }, .fromSeconds(2 * 24 * 3600), &d);
    try testing.expectError(error.InvalidArgument, expiration(.{ .after = .fromSeconds(2 * 24 * 3600) }, .fromSeconds(3 * 24 * 3600), &d));
    c = base;
    c.message_retention = .fromSeconds(3 * 24 * 3600);
    c.expiration = .{ .after = .fromSeconds(2 * 24 * 3600) };
    try testing.expectError(error.InvalidArgument, subscriptionConfig(c, &d));
    c = base;
    c.ack_deadline_seconds = 9;
    try testing.expectError(error.InvalidArgument, subscriptionConfig(c, &d));
}

test "topic settings: the KMS key's shape and the storage policy" {
    var d: Diagnostics = .{};
    try kmsKeyName("projects/p/locations/europe-west1/keyRings/ring/cryptoKeys/key", &d);
    for ([_][]const u8{
        "",
        "projects/p/locations/l/keyRings/r/cryptoKeys",
        "projects/p/locations/l/keyRings/r/cryptoKeys/",
        "projects/p/locations/l/keyRings/r/cryptoKeys/k/cryptoKeyVersions/1",
        "projects//locations/l/keyRings/r/cryptoKeys/k",
        "project/p/locations/l/keyRings/r/cryptoKeys/k",
        "projects/p/locations/l/keyrings/r/cryptoKeys/k",
    }) |name| try testing.expectError(error.InvalidArgument, kmsKeyName(name, &d));
    try storagePolicy(.{ .allowed_persistence_regions = &.{"europe-west1"} }, &d);
    try testing.expectError(error.InvalidArgument, storagePolicy(.{ .allowed_persistence_regions = &.{} }, &d));
    try testing.expectError(error.InvalidArgument, storagePolicy(.{ .allowed_persistence_regions = &.{""} }, &d));
    try testing.expectError(error.InvalidArgument, topicConfig(.{ .message_retention = .fromSeconds(60) }, &d));
    try topicConfig(.{}, &d);
}

test "updates: something must change, and what changes must be valid" {
    var d: Diagnostics = .{};
    try testing.expectError(error.InvalidArgument, subscriptionUpdate(.{}, &d));
    try testing.expectEqualStrings("the update changes nothing", d.message());
    try testing.expectError(error.InvalidArgument, topicUpdate(.{}, &d));
    try subscriptionUpdate(.{ .labels = &.{} }, &d);
    // Everything at once.
    try subscriptionUpdate(.{
        .ack_deadline_seconds = 10,
        .enable_exactly_once_delivery = true,
        .dead_letter_policy = .clear,
        .retry_policy = .{ .set = .{} },
        .message_retention = .clear,
        .retain_acked_messages = false,
        .expiration = .never,
        .labels = &.{},
    }, &d);
    try topicUpdate(.{ .labels = &.{}, .message_retention = .clear, .kms_key_name = .clear, .message_storage_policy = .clear }, &d);
    try subscriptionUpdate(.{ .retry_policy = .clear }, &d);
    try subscriptionUpdate(.{ .expiration = .default }, &d);
    try testing.expectError(error.InvalidArgument, subscriptionUpdate(.{ .ack_deadline_seconds = 0 }, &d));
    try testing.expectError(error.InvalidArgument, subscriptionUpdate(.{ .ack_deadline_seconds = 601 }, &d));
    try testing.expectError(error.InvalidArgument, subscriptionUpdate(.{ .dead_letter_policy = .{ .set = .{ .topic = "t", .max_delivery_attempts = 4 } } }, &d));
    try testing.expectError(error.InvalidArgument, subscriptionUpdate(.{
        .message_retention = .{ .set = .fromSeconds(5 * 24 * 3600) },
        .expiration = .{ .after = .fromSeconds(4 * 24 * 3600) },
    }, &d));
    try topicUpdate(.{ .kms_key_name = .clear }, &d);
    try testing.expectError(error.InvalidArgument, topicUpdate(.{ .kms_key_name = .{ .set = "nope" } }, &d));
    // The set arms of the other two topic fields, valid and not.
    try topicUpdate(.{ .message_retention = .{ .set = .fromSeconds(3600) } }, &d);
    try testing.expectError(error.InvalidArgument, topicUpdate(.{ .message_retention = .{ .set = .fromSeconds(1) } }, &d));
    try topicUpdate(.{ .message_storage_policy = .{ .set = .{ .allowed_persistence_regions = &.{"us-east1"} } } }, &d);
    try testing.expectError(error.InvalidArgument, topicUpdate(.{ .message_storage_policy = .{ .set = .{ .allowed_persistence_regions = &.{} } } }, &d));
}

test "snapshot settings: the subscription's two forms, labels, and an update that changes something" {
    var d: Diagnostics = .{};
    try snapshotConfig(.{ .subscription = "orders" }, &d);
    try snapshotConfig(.{ .subscription = "projects/other-project/subscriptions/orders", .labels = &.{.{ .key = "env", .value = "test" }} }, &d);
    try testing.expect(isSubscriptionName("projects/example.com:proj/subscriptions/a%41+b"));
    try testing.expectError(error.InvalidArgument, snapshotConfig(.{ .subscription = "" }, &d));
    try testing.expectEqualStrings("the subscription is neither a subscription id nor projects/{project}/subscriptions/{id}", d.message());
    // A topic's name, a snapshot's, half a name, and a bad id or project
    // inside a whole one are none.
    for ([_][]const u8{
        "projects/p/topics/orders",
        "projects/p/snapshots/orders",
        "subscriptions/orders",
        "projects/p/subscriptions/go",
        "projects//subscriptions/orders",
        "projects/p/subscriptions/orders/x",
    }) |bad| {
        try testing.expect(!isSubscriptionName(bad));
        try testing.expectError(error.InvalidArgument, snapshotConfig(.{ .subscription = bad }, &d));
    }
    // The split did not change what a topic's name is.
    try testing.expect(isTopicName("projects/p/topics/orders"));
    try testing.expect(!isTopicName("projects/p/subscriptions/orders"));

    try testing.expectError(error.InvalidArgument, snapshotConfig(.{ .subscription = "orders", .labels = &.{.{ .key = "UPPER", .value = "v" }} }, &d));
    try testing.expectError(error.InvalidArgument, snapshotUpdate(.{}, &d));
    try testing.expectEqualStrings("the update changes nothing", d.message());
    try snapshotUpdate(.{ .labels = &.{} }, &d);
    try snapshotUpdate(.{ .labels = &.{.{ .key = "env", .value = "prod" }} }, &d);
    try testing.expectError(error.InvalidArgument, snapshotUpdate(.{ .labels = &.{.{ .key = "Bad Key", .value = "v" }} }, &d));
}

test "a seek's target: a time a timestamp can hold, or a snapshot's id or full name" {
    var d: Diagnostics = .{};
    try seekTarget(.{ .time = .{ .nanoseconds = 0 } }, &d);
    try seekTarget(.{ .time = timestamp.min }, &d);
    try seekTarget(.{ .time = timestamp.max }, &d);
    try testing.expectError(error.InvalidArgument, seekTarget(.{ .time = .{ .nanoseconds = timestamp.max.nanoseconds + 1 } }, &d));
    try testing.expectEqualStrings("the seek time is outside 0001-01-01T00:00:00Z to 9999-12-31T23:59:59.999999999Z", d.message());
    try testing.expectError(error.InvalidArgument, seekTarget(.{ .time = .{ .nanoseconds = timestamp.min.nanoseconds - 1 } }, &d));

    try seekTarget(.{ .snapshot = "before-deploy" }, &d);
    try seekTarget(.{ .snapshot = "projects/other-project/snapshots/before-deploy" }, &d);
    try testing.expect(isSnapshotName("projects/example.com:proj/snapshots/a%41+b"));
    for ([_][]const u8{ "", "go", "projects/p/subscriptions/orders", "snapshots/before", "projects/p/snapshots/go", "projects/p/snapshots/a/b" }) |bad| {
        try testing.expect(!isSnapshotName(bad));
        try testing.expectError(error.InvalidArgument, seekTarget(.{ .snapshot = bad }, &d));
    }
    try testing.expectEqualStrings("the snapshot is neither a snapshot id nor projects/{project}/snapshots/{id}", d.message());
}
