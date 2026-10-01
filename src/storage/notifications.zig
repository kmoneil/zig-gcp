//! Notification configurations: a bucket's instruction to Cloud Storage to
//! publish a Pub/Sub message for every change to its objects. The calls
//! behind `Bucket.createNotification`, `getNotification`,
//! `listNotifications` and `deleteNotification`, the checks before
//! sending, and the reading of the refusals, as measured in production on
//! 2026-10-01 (the notifications spec, section 2).
//!
//! A create is never simply sent again: a repeat makes a second
//! configuration, idempotency token or not, as measured. The bucket's
//! configurations are listed first instead. After a failure that may have
//! landed, they are listed again, and one that matches and was not there
//! before is this create's, since an ID is never reused; none means the
//! create did not land, and it is sent again.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Stringify = std.json.Stringify;
const core = @import("core");

const Client = @import("Client.zig");
const codec = @import("codec.zig");
const idempotency = @import("idempotency.zig");
const logging = @import("logging.zig");
const names = @import("names.zig");
const rpc = @import("rpc.zig");
const types = @import("types.zig");
const Error = @import("errors.zig").Error;

/// Custom attributes Cloud Storage takes on one configuration, as
/// measured. Its documentation says 10.
pub const max_custom_attributes = 5;
/// The longest custom attribute key and value Cloud Storage takes, in
/// bytes: its refusal says characters, and counts bytes, as measured.
pub const max_attribute_key_bytes = 256;
pub const max_attribute_value_bytes = 1024;

/// The attributes Cloud Storage puts on its messages. A custom attribute of
/// one of these names is taken, and every message carries Cloud Storage's
/// own value instead, as measured, so it is refused before sending.
pub const builtin_attributes = [_][]const u8{
    "notificationConfig",
    "eventType",
    "payloadFormat",
    "bucketId",
    "objectId",
    "objectGeneration",
    "eventTime",
    "overwroteGeneration",
    "overwrittenByGeneration",
};

pub const CheckError = error{InvalidNotificationConfig};

/// Whether `config` can be sent, saying why not in `diag`.
pub fn check(diag: ?*core.Diagnostics, config: types.NotificationConfig) CheckError!void {
    if (!core.names.isProjectId(config.topic.project)) return refuse(diag, "the topic's project is not a project id or number", .{});
    if (!core.names.isPubSubId(config.topic.topic)) return refuse(
        diag,
        "the topic id breaks Pub/Sub's rules: 3 to 255 characters of letters, digits and -_.~+%, starting with a letter and not with goog",
        .{},
    );
    if (config.payload == .unknown) return refuse(diag, "a payload format this library does not know is never sent", .{});
    if (config.events) |events| {
        if (events.len == 0) return refuse(
            diag,
            "an empty list of event types, which Cloud Storage would read as every type: events = null asks for every type",
            .{},
        );
        for (events, 0..) |event, i| {
            if (event == .unknown) return refuse(
                diag,
                "an event type this library does not know is never sent: Cloud Storage drops one it does not know, and the configuration then publishes every type",
                .{},
            );
            for (events[0..i]) |earlier| if (earlier == event) return refuse(diag, "the event type {t} is named twice", .{event});
        }
    }
    const attributes = config.custom_attributes;
    if (attributes.len > max_custom_attributes) {
        return refuse(diag, "{d} custom attributes, and Cloud Storage takes at most {d}", .{ attributes.len, max_custom_attributes });
    }
    for (attributes, 0..) |a, i| {
        if (a.key.len == 0) return refuse(diag, "a custom attribute key is empty", .{});
        if (!std.unicode.utf8ValidateSlice(a.key)) return refuse(diag, "a custom attribute key is not UTF-8", .{});
        if (a.key.len > max_attribute_key_bytes) {
            return refuse(diag, "a custom attribute key of {d} bytes, and Cloud Storage takes at most {d}", .{ a.key.len, max_attribute_key_bytes });
        }
        if (!std.unicode.utf8ValidateSlice(a.value)) return refuse(diag, "the value of custom attribute {s} is not UTF-8", .{a.key});
        if (a.value.len > max_attribute_value_bytes) {
            return refuse(diag, "custom attribute {s} has a value of {d} bytes, and Cloud Storage takes at most {d}", .{ a.key, a.value.len, max_attribute_value_bytes });
        }
        // Measured: Cloud Storage takes the configuration, and none of its
        // messages ever arrives, since Pub/Sub keeps the prefix for itself;
        // meanwhile the bucket's other configurations got each event
        // several times over.
        if (std.ascii.startsWithIgnoreCase(a.key, "goog")) return refuse(
            diag,
            "custom attribute {s} begins with goog, which Pub/Sub keeps for itself: Cloud Storage would take the configuration and deliver none of its messages",
            .{a.key},
        );
        for (builtin_attributes) |builtin| if (std.mem.eql(u8, a.key, builtin)) return refuse(
            diag,
            "custom attribute {s} is named like an attribute every message carries: Cloud Storage would take it and send its own value",
            .{a.key},
        );
        for (attributes[0..i]) |earlier| if (std.mem.eql(u8, earlier.key, a.key)) return refuse(diag, "custom attribute {s} is named twice", .{a.key});
    }
    if (config.object_name_prefix) |prefix| {
        if (!std.unicode.utf8ValidateSlice(prefix)) return refuse(diag, "the object name prefix is not UTF-8, so no object name could begin with it", .{});
    }
}

fn refuse(diag: ?*core.Diagnostics, comptime format: []const u8, args: anytype) CheckError {
    if (diag) |d| d.print(format, args);
    return error.InvalidNotificationConfig;
}

/// The body of a create: the topic in its documented form, the payload
/// format always (Cloud Storage requires it), and nothing empty.
pub fn encode(arena: Allocator, config: types.NotificationConfig) Allocator.Error![]u8 {
    const topic = try std.fmt.allocPrint(arena, "//pubsub.googleapis.com/projects/{s}/topics/{s}", .{ config.topic.project, config.topic.topic });
    var out: std.Io.Writer.Allocating = .init(arena);
    var jw: Stringify = .{ .writer = &out.writer };
    write(&jw, config, topic) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn write(jw: *Stringify, config: types.NotificationConfig, topic: []const u8) Stringify.Error!void {
    try jw.beginObject();
    try jw.objectField("topic");
    try jw.write(topic);
    try jw.objectField("payload_format");
    try jw.write(codec.payloadFormatName(config.payload).?);
    if (config.events) |events| {
        try jw.objectField("event_types");
        try jw.beginArray();
        for (events) |event| try jw.write(codec.eventTypeName(event).?);
        try jw.endArray();
    }
    if (config.custom_attributes.len > 0) {
        try jw.objectField("custom_attributes");
        try jw.beginObject();
        for (config.custom_attributes) |a| {
            try jw.objectField(a.key);
            try jw.write(a.value);
        }
        try jw.endObject();
    }
    if (config.object_name_prefix) |prefix| if (prefix.len > 0) {
        try jw.objectField("object_name_prefix");
        try jw.write(prefix);
    };
    try jw.endObject();
}

/// Whether a failed create was refused because Cloud Storage cannot publish
/// to the topic, read from the reason and message, as measured: 403
/// `forbidden` when the service agent lacks the publisher role, 400
/// `invalid` when the topic does not exist.
pub fn isNotPublishable(err: anyerror, diag: *const core.Diagnostics) bool {
    const message = diag.message();
    return switch (err) {
        error.PermissionDenied => std.mem.eql(u8, diag.status(), "forbidden") and
            std.mem.indexOf(u8, message, "does not have permission to publish messages to") != null,
        error.InvalidArgument => std.mem.startsWith(u8, message, "Cloud Pub/Sub topic '") and
            std.mem.indexOf(u8, message, "' not found") != null,
        else => false,
    };
}

/// Creates the configuration `config` describes. The caller has begun the
/// call and checked the bucket name.
pub fn create(client: *Client, bucket: []const u8, config: types.NotificationConfig) Error!types.Owned(types.Notification) {
    try check(client.diagnostics, config);
    var scratch: std.heap.ArenaAllocator = .init(client.gpa);
    defer scratch.deinit();
    const path = try names.notificationsPath(scratch.allocator(), bucket, null);
    const body = try encode(scratch.allocator(), config);

    // What was there before: an ID is never reused, so one that appears
    // later was made in between.
    var before = try list(client, bucket);
    defer before.deinit();

    var attempt: u32 = 0;
    while (true) {
        attempt += 1;
        var token: idempotency.Token = undefined;
        token.init(client);
        var result: types.Owned(types.Notification) = try .init(client.gpa);
        const sent = rpc.execute(client, result.arena, .{
            .method = .POST,
            .path = path,
            .body = body,
            .headers = token.slice(),
            // A repeat makes a second configuration: this loop decides.
            .retry = false,
        });
        if (sent) |response| {
            result.value = codec.decodeNotification(result.arena.allocator(), response) catch |err| {
                result.deinit();
                return rpc.decodeFailed(client, err, "notification");
            };
            return result;
        } else |err| {
            result.deinit();
            if (!core.isRetryable(err)) return err;
            // It may have landed with its answer lost. Give it time to,
            // then look for it.
            const delay_ms = rpc.backoffMs(client, attempt);
            logging.warn("creating a notification configuration on {s} failed with {t}; looking for it in {d} ms", .{ bucket, err, delay_ms });
            try client.io.sleep(.fromMilliseconds(delay_ms), .awake);
            var after = list(client, bucket) catch |list_err| {
                // Running out of memory, or being canceled, says nothing
                // about the create: it is the answer.
                if (list_err == error.OutOfMemory or list_err == error.Canceled) return list_err;
                if (client.diagnostics) |d| d.print(
                    "creating a notification configuration failed with {t}, and listing the bucket's to see whether it landed failed with {t}: it may exist",
                    .{ err, list_err },
                );
                return err;
            };
            defer after.deinit();
            if (landed(before.value, after.value, config)) |found| {
                if (client.diagnostics) |d| d.clear();
                return copy(client.gpa, found);
            }
            if (attempt >= client.retry.max_attempts) return err;
        }
    }
}

/// The configuration in `after` that `config` made: one that matches and
/// is not in `before`.
fn landed(before: []const types.Notification, after: []const types.Notification, config: types.NotificationConfig) ?types.Notification {
    outer: for (after) |n| {
        for (before) |b| if (std.mem.eql(u8, b.id, n.id)) continue :outer;
        if (matches(n, config)) return n;
    }
    return null;
}

/// Whether `n` is what `config` creates, as Cloud Storage keeps it: the
/// event types in an order of its own, and none of the empty fields.
pub fn matches(n: types.Notification, config: types.NotificationConfig) bool {
    const topic = n.topic_name orelse return false;
    if (!std.mem.eql(u8, topic.project, config.topic.project) or !std.mem.eql(u8, topic.topic, config.topic.topic)) return false;
    if (n.payload != config.payload) return false;
    const events = config.events orelse &.{};
    if (n.events.len != events.len) return false;
    for (events) |event| if (std.mem.indexOfScalar(types.EventType, n.events, event) == null) return false;
    if (n.custom_attributes.len != config.custom_attributes.len) return false;
    for (config.custom_attributes) |a| {
        const kept = for (n.custom_attributes) |k| {
            if (std.mem.eql(u8, k.key, a.key)) break k;
        } else return false;
        if (!std.mem.eql(u8, kept.value, a.value)) return false;
    }
    return std.mem.eql(u8, n.object_name_prefix orelse "", config.object_name_prefix orelse "");
}

/// `n`, in memory of its own.
fn copy(gpa: Allocator, n: types.Notification) Allocator.Error!types.Owned(types.Notification) {
    var result: types.Owned(types.Notification) = try .init(gpa);
    errdefer result.deinit();
    const a = result.arena.allocator();
    const attributes = try a.alloc(types.Attribute, n.custom_attributes.len);
    for (n.custom_attributes, attributes) |from, *to| to.* = .{ .key = try a.dupe(u8, from.key), .value = try a.dupe(u8, from.value) };
    const topic = try a.dupe(u8, n.topic);
    result.value = .{
        .id = try a.dupe(u8, n.id),
        .topic = topic,
        .topic_name = codec.topicNameOf(topic),
        .payload = n.payload,
        .events = try a.dupe(types.EventType, n.events),
        .custom_attributes = attributes,
        .object_name_prefix = if (n.object_name_prefix) |p| try a.dupe(u8, p) else null,
        .etag = if (n.etag) |e| try a.dupe(u8, e) else null,
    };
    return result;
}

/// One configuration, by its ID. The caller has begun the call and
/// checked the bucket name.
pub fn get(client: *Client, bucket: []const u8, id: []const u8) Error!types.Owned(types.Notification) {
    try checkId(client, id);
    var scratch: std.heap.ArenaAllocator = .init(client.gpa);
    defer scratch.deinit();
    const path = try names.notificationsPath(scratch.allocator(), bucket, id);

    var result: types.Owned(types.Notification) = try .init(client.gpa);
    errdefer result.deinit();
    const response = try rpc.execute(client, result.arena, .{ .method = .GET, .path = path });
    result.value = codec.decodeNotification(result.arena.allocator(), response) catch |err|
        return rpc.decodeFailed(client, err, "notification");
    return result;
}

/// Every configuration of the bucket, at most 100 and never paged.
pub fn list(client: *Client, bucket: []const u8) Error!types.Owned([]const types.Notification) {
    var scratch: std.heap.ArenaAllocator = .init(client.gpa);
    defer scratch.deinit();
    const path = try names.notificationsPath(scratch.allocator(), bucket, null);

    var result: types.Owned([]const types.Notification) = try .init(client.gpa);
    errdefer result.deinit();
    const response = try rpc.execute(client, result.arena, .{ .method = .GET, .path = path });
    result.value = codec.decodeNotificationList(result.arena.allocator(), response) catch |err|
        return rpc.decodeFailed(client, err, "notification list");
    return result;
}

/// Deletes one configuration. Its messages stopped at once when measured.
/// Retried: a lost first success shows up as `error.NotFound`, since a
/// repeat is not recognised by its idempotency token. The caller has begun
/// the call and checked the bucket name.
pub fn delete(client: *Client, bucket: []const u8, id: []const u8) Error!void {
    try checkId(client, id);
    var scratch: std.heap.ArenaAllocator = .init(client.gpa);
    defer scratch.deinit();
    const path = try names.notificationsPath(scratch.allocator(), bucket, id);
    var token: idempotency.Token = undefined;
    token.init(client);
    try rpc.executeDiscard(client, .{ .method = .DELETE, .path = path, .headers = token.slice() });
}

fn checkId(client: *Client, id: []const u8) Error!void {
    if (id.len != 0) return;
    if (client.diagnostics) |d| d.print("a notification id is not empty: Notification.id names one", .{});
    return error.InvalidArgument;
}

const testing = std.testing;
const test_util = @import("test_util.zig");
const FakeBuckets = @import("fake_buckets.zig").FakeBuckets;

// Production's answers, measured on 2026-10-01 (`_tmp/notifications`,
// run 8673f7), the bucket and topic names shortened.
const minimal_answer =
    \\{"kind":"storage#notification","selfLink":"https://www.googleapis.com/storage/v1/b/zigps-ntf/notificationConfigs/1","id":"1","topic":"//pubsub.googleapis.com/projects/extractctl/topics/zigps-t1","etag":"1","payload_format":"JSON_API_V1"}
;
const full_answer =
    \\{"kind":"storage#notification","selfLink":"https://www.googleapis.com/storage/v1/b/zigps-ntf/notificationConfigs/2","id":"2","topic":"//pubsub.googleapis.com/projects/extractctl/topics/zigps-t1","custom_attributes":{"alpha":"2","zeta":"1"},"etag":"2","event_types":["OBJECT_FINALIZE","OBJECT_DELETE"],"object_name_prefix":"p/","payload_format":"NONE"}
;
/// A list of none: no `items` at all.
const empty_list =
    \\{"kind":"storage#notifications"}
;
/// fake-gcs-server 1.56.1: no etag, no selfLink, the topic as sent.
const emulator_answer =
    \\{"kind":"storage#notification","id":"7","topic":"projects/test/topics/t1","event_types":["OBJECT_FINALIZE"],"object_name_prefix":"","payload_format":"JSON_API_V1","custom_attributes":{"team":"data"}}
;

const minimal: types.NotificationConfig = .{ .topic = .{ .project = "extractctl", .topic = "zigps-t1" } };

test "decode: production's answers, a list of none, and the emulator's" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const one = try codec.decodeNotification(arena, minimal_answer);
    try testing.expectEqualStrings("1", one.id);
    try testing.expectEqualStrings("//pubsub.googleapis.com/projects/extractctl/topics/zigps-t1", one.topic);
    try testing.expectEqualStrings("extractctl", one.topic_name.?.project);
    try testing.expectEqualStrings("zigps-t1", one.topic_name.?.topic);
    try testing.expectEqual(.json, one.payload);
    try testing.expectEqual(0, one.events.len);
    try testing.expectEqual(0, one.custom_attributes.len);
    try testing.expectEqual(null, one.object_name_prefix);
    try testing.expectEqualStrings("1", one.etag.?);
    try testing.expect(matches(one, minimal));

    const full = try codec.decodeNotification(arena, full_answer);
    try testing.expectEqualSlices(types.EventType, &.{ .finalize, .delete }, full.events);
    try testing.expectEqual(.none, full.payload);
    try testing.expectEqualStrings("p/", full.object_name_prefix.?);
    try testing.expectEqualStrings("alpha", full.custom_attributes[0].key);
    try testing.expectEqualStrings("2", full.custom_attributes[0].value);
    // Sent in another order, kept in Cloud Storage's: still this create.
    try testing.expect(matches(full, .{
        .topic = minimal.topic,
        .payload = .none,
        .events = &.{ .delete, .finalize },
        .custom_attributes = &.{ .{ .key = "zeta", .value = "1" }, .{ .key = "alpha", .value = "2" } },
        .object_name_prefix = "p/",
    }));
    try testing.expect(!matches(full, minimal));

    try testing.expectEqual(0, (try codec.decodeNotificationList(arena, empty_list)).len);
    const listed = try codec.decodeNotificationList(arena, "{\"kind\":\"storage#notifications\",\"items\":[" ++ minimal_answer ++ "," ++ full_answer ++ "]}");
    try testing.expectEqual(2, listed.len);
    try testing.expectEqualStrings("2", listed[1].id);

    const emulator = try codec.decodeNotification(arena, emulator_answer);
    try testing.expectEqual(null, emulator.etag);
    try testing.expectEqual(null, emulator.topic_name);
    try testing.expectEqualStrings("", emulator.object_name_prefix.?);
}

test "decode: what this library does not know is kept, and an answer without an id or topic is refused" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const odd = try codec.decodeNotification(arena,
        \\{"id":"3","topic":"//pubsub.googleapis.com/projects/p/topics/a/b","event_types":["OBJECT_EXPLODED","OBJECT_INITIALIZE"],"payload_format":"XML","custom_attributes":{"k":null}}
    );
    try testing.expectEqualSlices(types.EventType, &.{ .unknown, .initialize }, odd.events);
    try testing.expectEqual(.unknown, odd.payload);
    try testing.expectEqual(null, odd.topic_name);
    try testing.expectEqualStrings("", odd.custom_attributes[0].value);
    try testing.expectError(error.InvalidResponse, codec.decodeNotification(arena, "{\"topic\":\"t\"}"));
    try testing.expectError(error.InvalidResponse, codec.decodeNotification(arena, "{\"id\":\"1\"}"));
    try testing.expectError(error.InvalidResponse, codec.decodeNotification(arena, "[]"));
    for ([_][]const u8{
        "//pubsub.googleapis.com/projects//topics/t",
        "//pubsub.googleapis.com/projects/p/topics/",
        "projects/p/topics/t",
        "//pubsub.googleapis.com/projects/p/topic/t",
    }) |topic| try testing.expectEqual(null, codec.topicNameOf(topic));
}

test "encode: the topic in its documented form, the format always, and nothing empty" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqualStrings(
        \\{"topic":"//pubsub.googleapis.com/projects/extractctl/topics/zigps-t1","payload_format":"JSON_API_V1"}
    , try encode(arena, minimal));
    try testing.expectEqualStrings(
        \\{"topic":"//pubsub.googleapis.com/projects/82150720798/topics/zigps-t1","payload_format":"NONE","event_types":["OBJECT_DELETE","OBJECT_INITIALIZE"],"custom_attributes":{"team":"data","note":"\"quoted\" ü"},"object_name_prefix":"incoming/"}
    , try encode(arena, .{
        .topic = .{ .project = "82150720798", .topic = "zigps-t1" },
        .payload = .none,
        .events = &.{ .delete, .initialize },
        .custom_attributes = &.{ .{ .key = "team", .value = "data" }, .{ .key = "note", .value = "\"quoted\" ü" } },
        .object_name_prefix = "incoming/",
    }));
    // An empty prefix is no prefix.
    try testing.expectEqualStrings(
        \\{"topic":"//pubsub.googleapis.com/projects/extractctl/topics/zigps-t1","payload_format":"JSON_API_V1"}
    , try encode(arena, .{ .topic = minimal.topic, .object_name_prefix = "" }));
}

test "check: each refusal alone, and what production took" {
    const Case = struct { config: types.NotificationConfig, says: []const u8 };
    const k257 = "k" ** 257;
    const v1025 = "v" ** 1025;
    const six = [_]types.Attribute{ .{ .key = "a", .value = "" }, .{ .key = "b", .value = "" }, .{ .key = "c", .value = "" }, .{ .key = "d", .value = "" }, .{ .key = "e", .value = "" }, .{ .key = "f", .value = "" } };
    const cases = [_]Case{
        .{ .config = .{ .topic = .{ .project = "", .topic = "zigps-t1" } }, .says = "project" },
        .{ .config = .{ .topic = .{ .project = "a/b", .topic = "zigps-t1" } }, .says = "project" },
        .{ .config = .{ .topic = .{ .project = "p", .topic = "t" } }, .says = "topic id" },
        .{ .config = .{ .topic = .{ .project = "p", .topic = "goog-t1" } }, .says = "topic id" },
        .{ .config = .{ .topic = .{ .project = "p", .topic = "zigps/t1" } }, .says = "topic id" },
        .{ .config = .{ .topic = minimal.topic, .payload = .unknown }, .says = "payload format" },
        .{ .config = .{ .topic = minimal.topic, .events = &.{} }, .says = "empty list of event types" },
        .{ .config = .{ .topic = minimal.topic, .events = &.{.unknown} }, .says = "does not know" },
        .{ .config = .{ .topic = minimal.topic, .events = &.{ .finalize, .delete, .finalize } }, .says = "finalize is named twice" },
        .{ .config = .{ .topic = minimal.topic, .custom_attributes = &six }, .says = "6 custom attributes" },
        .{ .config = .{ .topic = minimal.topic, .custom_attributes = &.{.{ .key = "", .value = "v" }} }, .says = "key is empty" },
        .{ .config = .{ .topic = minimal.topic, .custom_attributes = &.{.{ .key = k257, .value = "v" }} }, .says = "257 bytes" },
        .{ .config = .{ .topic = minimal.topic, .custom_attributes = &.{.{ .key = "k", .value = v1025 }} }, .says = "1025 bytes" },
        // Characters to the eye, bytes to Cloud Storage, as measured.
        .{ .config = .{ .topic = minimal.topic, .custom_attributes = &.{.{ .key = "é" ** 129, .value = "v" }} }, .says = "258 bytes" },
        .{ .config = .{ .topic = minimal.topic, .custom_attributes = &.{.{ .key = "k", .value = "é" ** 513 }} }, .says = "1026 bytes" },
        .{ .config = .{ .topic = minimal.topic, .custom_attributes = &.{.{ .key = "goog-x", .value = "1" }} }, .says = "begins with goog" },
        .{ .config = .{ .topic = minimal.topic, .custom_attributes = &.{.{ .key = "GOOGy", .value = "1" }} }, .says = "begins with goog" },
        .{ .config = .{ .topic = minimal.topic, .custom_attributes = &.{.{ .key = "eventType", .value = "x" }} }, .says = "named like an attribute every message carries" },
        .{ .config = .{ .topic = minimal.topic, .custom_attributes = &.{ .{ .key = "a", .value = "1" }, .{ .key = "a", .value = "2" } } }, .says = "a is named twice" },
        .{ .config = .{ .topic = minimal.topic, .custom_attributes = &.{.{ .key = "\xff", .value = "v" }} }, .says = "not UTF-8" },
        .{ .config = .{ .topic = minimal.topic, .object_name_prefix = "a\xff" }, .says = "prefix is not UTF-8" },
    };
    for (cases) |case| {
        var diag: core.Diagnostics = .{};
        try testing.expectError(error.InvalidNotificationConfig, check(&diag, case.config));
        if (std.mem.indexOf(u8, diag.message(), case.says) == null) {
            std.debug.print("diagnostics \"{s}\" lack \"{s}\"\n", .{ diag.message(), case.says });
            return error.TestUnexpectedDiagnostics;
        }
    }
    // Each taken by production as asked, at the limits.
    const k256 = "k" ** 256;
    const v1024 = "v" ** 1024;
    const five = six[0..5];
    for ([_]types.NotificationConfig{
        minimal,
        .{ .topic = .{ .project = "82150720798", .topic = "zigps-t1" } },
        .{ .topic = minimal.topic, .custom_attributes = five },
        .{ .topic = minimal.topic, .custom_attributes = &.{.{ .key = k256, .value = v1024 }} },
        .{ .topic = minimal.topic, .custom_attributes = &.{ .{ .key = "xgoog", .value = "" }, .{ .key = "ключ", .value = "значение" } } },
        .{ .topic = minimal.topic, .custom_attributes = &.{.{ .key = "é" ** 128, .value = "é" ** 512 }} },
        .{ .topic = minimal.topic, .events = &.{ .initialize, .archive, .metadata_update } },
        .{ .topic = minimal.topic, .object_name_prefix = "" },
    }) |config| try check(null, config);
}

test "matches: a configuration that differs in any one field is another create's" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const full = try codec.decodeNotification(arena_state.allocator(), full_answer);
    const asked: types.NotificationConfig = .{
        .topic = minimal.topic,
        .payload = .none,
        .events = &.{ .finalize, .delete },
        .custom_attributes = &.{ .{ .key = "alpha", .value = "2" }, .{ .key = "zeta", .value = "1" } },
        .object_name_prefix = "p/",
    };
    try testing.expect(matches(full, asked));
    var other = asked;
    other.topic.project = "other";
    try testing.expect(!matches(full, other));
    other = asked;
    other.topic.topic = "zigps-t2";
    try testing.expect(!matches(full, other));
    other = asked;
    other.payload = .json;
    try testing.expect(!matches(full, other));
    other = asked;
    other.events = &.{.finalize};
    try testing.expect(!matches(full, other));
    other.events = &.{ .finalize, .archive };
    try testing.expect(!matches(full, other));
    other.events = null;
    try testing.expect(!matches(full, other));
    other = asked;
    other.custom_attributes = &.{.{ .key = "alpha", .value = "2" }};
    try testing.expect(!matches(full, other));
    other.custom_attributes = &.{ .{ .key = "alpha", .value = "2" }, .{ .key = "zeta", .value = "9" } };
    try testing.expect(!matches(full, other));
    other.custom_attributes = &.{ .{ .key = "alpha", .value = "2" }, .{ .key = "beta", .value = "1" } };
    try testing.expect(!matches(full, other));
    other = asked;
    other.object_name_prefix = "q/";
    try testing.expect(!matches(full, other));
    other.object_name_prefix = null;
    try testing.expect(!matches(full, other));
}

test "isNotPublishable: production's two refusals of a topic, and nothing else" {
    var diag: core.Diagnostics = .{};
    diag.set(403, "forbidden", "The service account 'service-82150720798@gs-project-accounts.iam.gserviceaccount.com' does not have permission to publish messages to to the Cloud Pub/Sub topic '//pubsub.googleapis.com/projects/extractctl/topics/zigps-t2', or that topic does not exist.");
    try testing.expect(isNotPublishable(error.PermissionDenied, &diag));
    try testing.expect(!isNotPublishable(error.InvalidArgument, &diag));
    diag.set(400, "invalid", "Cloud Pub/Sub topic '//pubsub.googleapis.com/projects/extractctl/topics/missing' not found, or user 'service-82150720798@gs-project-accounts.iam.gserviceaccount.com' does not have permission to it.");
    try testing.expect(isNotPublishable(error.InvalidArgument, &diag));
    // The caller's own missing permission, and the other refusals of a create.
    diag.set(403, "forbidden", "kevin@example.com does not have storage.buckets.update access to the Google Cloud Storage bucket.");
    try testing.expect(!isNotPublishable(error.PermissionDenied, &diag));
    diag.set(400, "invalid", "Invalid Google Cloud Pub/Sub topic. It should look like '//pubsub.googleapis.com/projects/*/topics/*.'");
    try testing.expect(!isNotPublishable(error.InvalidArgument, &diag));
    diag.set(400, "invalid", "Too many overlapping notifications. The maximum is 10.");
    try testing.expect(!isNotPublishable(error.InvalidArgument, &diag));
}

test "requests: a list first, then the body and its token, each billed when the handle bills" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = empty_list } },
        .{ .respond = .{ .body = minimal_answer } },
        .{ .respond = .{ .body = "{\"items\":[" ++ minimal_answer ++ "]}" } },
        .{ .respond = .{ .body = minimal_answer } },
        .{ .respond = .{ .status = 204, .body = "" } },
        .{ .respond = .{ .status = 404, .body =
        \\{"error":{"code":404,"message":"The requested resource was not found.","errors":[{"message":"The requested resource was not found.","domain":"global","reason":"notFound"}]}}
        } },
    }, .{});
    defer h.deinit();
    const b = h.client.bucket("zigps-ntf").withBillingProject("my-project");
    var made = try b.createNotification(minimal);
    defer made.deinit();
    try testing.expectEqualStrings("1", made.value.id);
    try h.expectRequest(0, .GET, "https://storage.googleapis.com/storage/v1/b/zigps-ntf/notificationConfigs?userProject=my-project", null);
    try h.expectRequest(1, .POST, "https://storage.googleapis.com/storage/v1/b/zigps-ntf/notificationConfigs?userProject=my-project",
        \\{"topic":"//pubsub.googleapis.com/projects/extractctl/topics/zigps-t1","payload_format":"JSON_API_V1"}
    );
    const post = try h.fake.request(1);
    try testing.expect(post.header("X-Goog-Gcs-Idempotency-Token") != null);
    try testing.expectEqualStrings("my-project", post.header("x-goog-user-project").?);

    var all = try b.listNotifications();
    defer all.deinit();
    try testing.expectEqual(1, all.value.len);
    var one = try b.getNotification("1");
    defer one.deinit();
    try b.deleteNotification("1");
    try h.expectRequest(3, .GET, "https://storage.googleapis.com/storage/v1/b/zigps-ntf/notificationConfigs/1?userProject=my-project", null);
    try h.expectRequest(4, .DELETE, "https://storage.googleapis.com/storage/v1/b/zigps-ntf/notificationConfigs/1?userProject=my-project", null);
    try testing.expect((try h.fake.request(4)).header("X-Goog-Gcs-Idempotency-Token") != null);
    try h.expectRequestCount(5);

    // An id is one segment of the path, whatever it holds.
    try testing.expectError(error.NotFound, b.getNotification("a/b?c"));
    try testing.expectEqualStrings("https://storage.googleapis.com/storage/v1/b/zigps-ntf/notificationConfigs/a%2Fb%3Fc?userProject=my-project", (try h.fake.request(5)).url);

    // Refused before any request.
    try testing.expectError(error.InvalidArgument, b.getNotification(""));
    try testing.expectError(error.InvalidArgument, b.deleteNotification(""));
    try testing.expectError(error.InvalidNotificationConfig, b.createNotification(.{ .topic = minimal.topic, .events = &.{} }));
    try testing.expectError(error.InvalidBucketName, h.client.bucket("").listNotifications());
    try h.expectRequestCount(6);
}

fn clientOnFake(fake: *test_util.FakeMultipart, token: *core.StaticToken, diag: *core.Diagnostics) !Client {
    return .init(testing.allocator, fake.io, .{
        .project_id = "extractctl",
        .token_provider = token.provider(),
        .transport = fake.transport(),
        .diagnostics = diag,
        .retry = .{ .max_attempts = 3, .initial_backoff_ms = 1, .max_backoff_ms = 2 },
    });
}

/// The faults of the notification requests in order, then none: a create
/// is a list, a post, and after a failure a list again.
const Faults = struct {
    plan_faults: []const test_util.FakeMultipart.Fault,
    seen: usize = 0,

    fn plan(self: *Faults) test_util.FakeMultipart.FaultPlan {
        return .{ .ctx = self, .decide = decide };
    }

    fn decide(ctx: ?*anyopaque, kind: test_util.FakeMultipart.Kind, _: u32) test_util.FakeMultipart.Fault {
        const self: *Faults = @ptrCast(@alignCast(ctx.?));
        if (kind != .notification) return .none;
        defer self.seen += 1;
        return if (self.seen < self.plan_faults.len) self.plan_faults[self.seen] else .none;
    }
};

const Fixture = struct {
    fake: test_util.FakeMultipart,
    token: core.StaticToken,
    diag: core.Diagnostics,
    client: Client,

    fn init(f: *Fixture) !void {
        f.fake = .init(testing.allocator, testing.io);
        errdefer f.fake.deinit();
        f.token = .{ .token = "ya29.t" };
        f.diag = .{};
        f.client = try clientOnFake(&f.fake, &f.token, &f.diag);
        errdefer f.client.deinit();
        var made = try f.client.bucket("zigps-ntf").create(.{});
        made.deinit();
    }

    fn deinit(f: *Fixture) void {
        f.client.deinit();
        f.fake.deinit();
    }

    fn kept(f: *const Fixture) usize {
        return f.fake.buckets.notifications("zigps-ntf").len;
    }
};

test "against production's rules: IDs from the metageneration, each call, and what is missing" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const b = f.client.bucket("zigps-ntf");

    var none = try b.listNotifications();
    try testing.expectEqual(0, none.value.len);
    none.deinit();
    var first = try b.createNotification(minimal);
    defer first.deinit();
    try testing.expectEqualStrings("1", first.value.id);
    try testing.expectEqualStrings("1", first.value.etag.?);
    var second = try b.createNotification(.{ .topic = minimal.topic, .payload = .none, .events = &.{ .delete, .finalize } });
    defer second.deinit();
    try testing.expectEqualStrings("2", second.value.id);
    // Kept in Cloud Storage's order.
    try testing.expectEqualSlices(types.EventType, &.{ .finalize, .delete }, second.value.events);
    try b.deleteNotification("1");
    var third = try b.createNotification(minimal);
    defer third.deinit();
    // A delete moved the metageneration too: the IDs skip, as measured.
    try testing.expectEqualStrings("4", third.value.id);

    var got = try b.getNotification("2");
    defer got.deinit();
    try testing.expect(matches(got.value, .{ .topic = minimal.topic, .payload = .none, .events = &.{ .finalize, .delete } }));
    var all = try b.listNotifications();
    defer all.deinit();
    try testing.expectEqual(2, all.value.len);

    try testing.expectError(error.NotFound, b.getNotification("1"));
    try testing.expectEqualStrings("The requested resource was not found.", f.diag.message());
    try testing.expectError(error.NotFound, b.deleteNotification("1"));
    try testing.expectError(error.NotFound, f.client.bucket("zigps-gone").getNotification("1"));
    try testing.expectEqualStrings("The specified bucket does not exist.", f.diag.message());

    var bucket = try b.get();
    defer bucket.deinit();
    try testing.expectEqual(5, bucket.value.metageneration);
}

test "against production's rules: a topic Cloud Storage cannot publish to, and the limit per event" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const b = f.client.bucket("zigps-ntf");
    try f.fake.buckets.setTopic("//pubsub.googleapis.com/projects/extractctl/topics/zigps-missing", .missing);
    try f.fake.buckets.setTopic("//pubsub.googleapis.com/projects/extractctl/topics/zigps-ungranted", .ungranted);

    try testing.expectError(error.TopicNotPublishable, b.createNotification(.{ .topic = .{ .project = "extractctl", .topic = "zigps-missing" } }));
    try testing.expect(std.mem.indexOf(u8, f.diag.message(), "not found") != null);
    try testing.expectError(error.TopicNotPublishable, b.createNotification(.{ .topic = .{ .project = "extractctl", .topic = "zigps-ungranted" } }));
    try testing.expectEqualStrings("forbidden", f.diag.status());
    try testing.expect(std.mem.indexOf(u8, f.diag.message(), "service-82150720798@gs-project-accounts.iam.gserviceaccount.com") != null);
    // Refused, not sent twice.
    try testing.expectEqual(2, f.fake.buckets.counts.notification_creates);

    for (0..10) |_| {
        var made = try b.createNotification(.{ .topic = minimal.topic, .events = &.{.finalize} });
        made.deinit();
    }
    try testing.expectError(error.InvalidArgument, b.createNotification(.{ .topic = minimal.topic, .events = &.{.finalize} }));
    try testing.expectEqualStrings("Too many overlapping notifications. The maximum is 10.", f.diag.message());
    // One for every type overlaps the ten; one for deletes does not.
    try testing.expectError(error.InvalidArgument, b.createNotification(minimal));
    var deletes = try b.createNotification(.{ .topic = minimal.topic, .events = &.{.delete} });
    deletes.deinit();
    try testing.expectEqual(11, f.kept());

    // Refused before sending: nothing reached the bucket.
    const sent = f.fake.buckets.counts.notification_creates;
    try testing.expectError(error.InvalidNotificationConfig, b.createNotification(.{ .topic = minimal.topic, .custom_attributes = &.{.{ .key = "bucketId", .value = "x" }} }));
    try testing.expectEqual(sent, f.fake.buckets.counts.notification_creates);
}

test "a create whose answer was lost is found, not made twice" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var faults: Faults = .{ .plan_faults = &.{ .none, .lose_answer } };
    f.fake.faults = faults.plan();
    var made = try f.client.bucket("zigps-ntf").createNotification(minimal);
    defer made.deinit();
    try testing.expectEqualStrings("1", made.value.id);
    try testing.expect(matches(made.value, minimal));
    try testing.expectEqual(1, f.kept());
    try testing.expectEqual(1, f.fake.buckets.counts.notification_creates);
    // A list before, the create, and a list after.
    try testing.expectEqual(2, f.fake.buckets.counts.notification_reads);
    try testing.expectEqual(0, f.diag.message().len);
}

test "a create that did not land is sent again, and an identical one made before is not taken for it" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const b = f.client.bucket("zigps-ntf");
    var earlier = try b.createNotification(minimal);
    defer earlier.deinit();

    var faults: Faults = .{ .plan_faults = &.{ .none, .unavailable, .none, .reset } };
    f.fake.faults = faults.plan();
    var made = try b.createNotification(minimal);
    defer made.deinit();
    try testing.expectEqualStrings("2", made.value.id);
    try testing.expectEqual(2, f.kept());
    // Two failed attempts that did nothing, then the one that landed.
    try testing.expectEqual(2, f.fake.buckets.counts.notification_creates);
}

test "a create that never lands stops at the retry policy's attempts" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var faults: Faults = .{ .plan_faults = &.{ .none, .unavailable, .none, .unavailable, .none, .unavailable } };
    f.fake.faults = faults.plan();
    try testing.expectError(error.Unavailable, f.client.bucket("zigps-ntf").createNotification(minimal));
    try testing.expectEqual(0, f.kept());
    // A list, then three attempts, each looked for after: the last too,
    // since it may have landed as well.
    try testing.expectEqual(7, faults.seen);
}

test "a create whose answer was lost, and whose look for it fails, says it may exist" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var faults: Faults = .{ .plan_faults = &.{ .none, .lose_answer, .reset, .reset, .reset } };
    f.fake.faults = faults.plan();
    try testing.expectError(error.ConnectionResetByPeer, f.client.bucket("zigps-ntf").createNotification(minimal));
    try testing.expect(std.mem.indexOf(u8, f.diag.message(), "it may exist") != null);
    try testing.expectEqual(1, f.kept());
}

test "a deleted configuration whose answer was lost shows up as NotFound, as documented" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const b = f.client.bucket("zigps-ntf");
    var made = try b.createNotification(minimal);
    made.deinit();
    var faults: Faults = .{ .plan_faults = &.{.lose_answer} };
    f.fake.faults = faults.plan();
    try testing.expectError(error.NotFound, b.deleteNotification("1"));
    try testing.expectEqual(0, f.kept());
}

fn everyCall(gpa: Allocator) !void {
    var fake: test_util.FakeTransport = .init(gpa, &.{
        .{ .respond = .{ .body = empty_list } },
        .{ .fail = error.ConnectionResetByPeer },
        .{ .respond = .{ .body = "{\"items\":[" ++ full_answer ++ "]}" } },
        .{ .respond = .{ .body = full_answer } },
        .{ .respond = .{ .body = "{\"items\":[" ++ minimal_answer ++ "," ++ full_answer ++ "]}" } },
        .{ .respond = .{ .status = 204, .body = "" } },
    });
    defer fake.deinit();
    var clock: test_util.FakeClock = .{};
    var token: test_util.FakeTokenProvider = .{ .token = "ya29.test-token" };
    var client: Client = try .init(gpa, clock.io(), .{
        .project_id = "extractctl",
        .token_provider = token.provider(),
        .transport = fake.transport(),
        .retry = .{ .max_attempts = 2, .initial_backoff_ms = 1, .max_backoff_ms = 1 },
    });
    defer client.deinit();
    const b = client.bucket("zigps-ntf");
    // A lost answer, found by the list after it.
    var made = try b.createNotification(.{
        .topic = minimal.topic,
        .payload = .none,
        .events = &.{ .finalize, .delete },
        .custom_attributes = &.{ .{ .key = "alpha", .value = "2" }, .{ .key = "zeta", .value = "1" } },
        .object_name_prefix = "p/",
    });
    made.deinit();
    var one = try b.getNotification("2");
    one.deinit();
    var all = try b.listNotifications();
    all.deinit();
    try b.deleteNotification("2");
}

test "notifications: every allocation failure is OutOfMemory, and nothing leaks" {
    try testing.checkAllAllocationFailures(testing.allocator, everyCall, .{});
}

/// A configuration drawn from `bytes`, near the bounds production holds it
/// to: stray characters in topics, up to 7 custom attributes with keys and
/// values around their limits, built-in names and repeats, and event lists
/// empty, repeated or unknown.
fn drawConfig(g: *test_util.ByteGen, arena: Allocator) !types.NotificationConfig {
    const project = g.pick([]const u8, &.{ "extractctl", "82150720798", "example.com:p", "", "a/b", "p q" });
    const topic = g.pick([]const u8, &.{ "zigps-t1", "t", "goog-t", "1abc", "a" ** 255, "a" ** 256, "ab/c", "t%ópico" });
    const payload = g.pick(types.PayloadFormat, &.{ .json, .none, .unknown });
    const events: ?[]const types.EventType = if (g.boolean()) null else events: {
        const out = try arena.alloc(types.EventType, g.intRange(usize, 0, 6));
        for (out) |*e| e.* = g.pick(types.EventType, &.{ .finalize, .metadata_update, .delete, .archive, .initialize, .unknown });
        break :events out;
    };
    const attributes = try arena.alloc(types.Attribute, g.intRange(usize, 0, 7));
    for (attributes) |*a| {
        const key: []const u8 = switch (g.intRange(u8, 0, 5)) {
            0 => "",
            1 => g.pick([]const u8, &builtin_attributes),
            2 => g.pick([]const u8, &.{ "team", "goog-x", "GoOg", "xgoog" }),
            3 => try arena.alloc(u8, g.intRange(usize, 254, 258)),
            4 => try std.fmt.allocPrint(arena, "{s}", .{g.utf8(try arena.alloc(u8, 600), 600)}),
            else => try std.fmt.allocPrint(arena, "k{d}", .{g.int(u8)}),
        };
        if (key.len > 0 and key[0] == 0xaa) @memset(@constCast(key), 'k');
        const value: []const u8 = switch (g.intRange(u8, 0, 2)) {
            0 => "",
            1 => vs: {
                const v = try arena.alloc(u8, g.intRange(usize, 1022, 1026));
                @memset(v, 'v');
                break :vs v;
            },
            else => g.utf8(try arena.alloc(u8, 64), 64),
        };
        a.* = .{ .key = key, .value = value };
    }
    const prefix = g.pick(?[]const u8, &.{ null, "", "a/", "\xff" });
    return .{ .topic = .{ .project = project, .topic = topic }, .payload = payload, .events = events, .custom_attributes = attributes, .object_name_prefix = prefix };
}

/// Whether production takes `config` and keeps exactly what it asks, from
/// what was measured, written apart from `check`.
fn takenAsAsked(config: types.NotificationConfig) bool {
    // A topic must exist to be taken, so it has Pub/Sub's form.
    const p = config.topic.project;
    if (p.len == 0 or p.len > 100) return false;
    for (p) |c| if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == ':' or c == '_')) return false;
    const t = config.topic.topic;
    if (t.len < 3 or t.len > 255 or !std.ascii.isAlphabetic(t[0]) or std.ascii.startsWithIgnoreCase(t, "goog")) return false;
    for (t) |c| if (!(std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "-_.~+%", c) != null)) return false;
    if (config.payload == .unknown) return false;
    // An empty or unknown list is dropped, a repeat kept once.
    if (config.events) |events| {
        if (events.len == 0) return false;
        var seen = std.EnumSet(types.EventType).initEmpty();
        for (events) |e| {
            if (e == .unknown or seen.contains(e)) return false;
            seen.insert(e);
        }
    }
    if (config.custom_attributes.len > 5) return false;
    for (config.custom_attributes, 0..) |a, i| {
        if (!std.unicode.utf8ValidateSlice(a.key) or !std.unicode.utf8ValidateSlice(a.value)) return false;
        if (a.key.len == 0 or a.key.len > 256 or a.value.len > 1024) return false;
        // Taken, and then no message arrives.
        if (a.key.len >= 4 and std.ascii.eqlIgnoreCase(a.key[0..4], "goog")) return false;
        // Taken, and overridden on every message.
        for (builtin_attributes) |name| if (std.mem.eql(u8, a.key, name)) return false;
        // A JSON object keeps one of two.
        for (config.custom_attributes[0..i]) |earlier| if (std.mem.eql(u8, earlier.key, a.key)) return false;
    }
    if (config.object_name_prefix) |prefix| if (!std.unicode.utf8ValidateSlice(prefix)) return false;
    return true;
}

fn checksProperty(_: void, bytes: []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var g: test_util.ByteGen = .init(bytes);
    const config = try drawConfig(&g, arena);
    check(null, config) catch {
        try testing.expect(!takenAsAsked(config));
        return;
    };
    try testing.expect(takenAsAsked(config));
    // Taken: production's rules take the body, and keep what it asks.
    var fake: FakeBuckets = .init(testing.allocator);
    defer fake.deinit();
    _ = try fake.serve(.POST, .{ .name = null, .project = "extractctl" }, "{\"name\":\"zigps-ntf\"}", arena);
    const reply = try fake.serve(.POST, .{ .name = "zigps-ntf", .notification = .collection }, try encode(arena, config), arena);
    try testing.expectEqual(200, reply.status);
    try testing.expect(matches(try codec.decodeNotification(arena, reply.body), config));
}

test "fuzz notification checks: taken exactly when production takes the configuration as asked" {
    try test_util.fuzzBytes({}, checksProperty, .{ .corpus = &.{ "", "\x00" ** 64, "\x01\x02\x03\x04" ** 32, "\xff" ** 128 } });
}
