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

/// The exact size of the body `Topic.publish` would send, without encoding
/// anything. Callers splitting large batches can compare it with
/// `max_publish_request_bytes`.
pub fn publishRequestBytes(messages: []const types.Message, ordering_key: ?[]const u8) usize {
    return codec.publishBodyLen(messages, ordering_key);
}

/// Topic and subscription ids: 3 to 255 characters from `[A-Za-z0-9-_.~+%]`,
/// starting with a letter, and not starting with "goog" in any case (the
/// emulator allows "GOOG"; production does not).
pub fn isResourceId(id: []const u8) bool {
    if (id.len < 3 or id.len > 255) return false;
    if (!std.ascii.isAlphabetic(id[0])) return false;
    if (std.ascii.startsWithIgnoreCase(id, "goog")) return false;
    for (id) |c| switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '~', '+', '%' => {},
        else => return false,
    };
    return true;
}

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

fn reject(diag: ?*Diagnostics, comptime format: []const u8, args: anytype) error{InvalidMessage} {
    if (diag) |d| d.print(format, args);
    return error.InvalidMessage;
}

const testing = std.testing;

test "resource ids: the documented rules at their boundaries" {
    try testing.expect(isResourceId("abc"));
    try testing.expect(!isResourceId("ab"));
    try testing.expect(isResourceId("a" ** 255));
    try testing.expect(!isResourceId("a" ** 256));
    try testing.expect(isResourceId("a.b~c_d-e+f%41"));
    try testing.expect(isResourceId("gooXfoo"));
    try testing.expect(isResourceId("xgoog"));
    try testing.expect(!isResourceId("googfoo"));
    try testing.expect(!isResourceId("goog"));
    // Production rejects any case; the emulator accepts this one.
    try testing.expect(!isResourceId("GOOGfoo"));
    try testing.expect(!isResourceId("GoOgle-topic"));
    try testing.expect(!isResourceId("1abc"));
    try testing.expect(!isResourceId("-abc"));
    try testing.expect(!isResourceId("ab/c"));
    try testing.expect(!isResourceId("ab c"));
    try testing.expect(!isResourceId("mi-t\xc3\xb3pico"));
    try testing.expect(!isResourceId(""));
}

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
    try publish(&.{.{ .data = "x" }}, "é" ** 512, null);
    try expectRejected(&.{.{ .data = "x" }}, "é" ** 513, "the ordering key has 1026 bytes");
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
