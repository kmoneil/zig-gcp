//! `decodeEvent`: a Pub/Sub message Cloud Storage published for a bucket's
//! notification configuration, read into an `ObjectEvent`. It takes any
//! value with `data` and `attributes`, as `pubsub.ReceivedMessage` has, so
//! neither module imports the other. What the messages carry was measured
//! in production on 2026-10-01 (the notifications spec, section 2).

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("core");

const codec = @import("codec.zig");
const notifications = @import("notifications.zig");
const types = @import("types.zig");

pub const DecodeEventError = error{
    /// The message is not one Cloud Storage published for a notification
    /// configuration, or says something no such message could:
    /// `Diagnostics` says which.
    NotAnObjectEvent,
    OutOfMemory,
};

pub const DecodeEventOptions = struct {
    /// Where a refusal says why.
    diagnostics: ?*core.Diagnostics = null,
};

/// Reads the change `message` reports, copying everything it keeps, so the
/// event outlives the message, which a `Subscriber` handler's does not.
/// `message` is any value with `data: []const u8` and `attributes`, a slice
/// of values with `key` and `value`. A message without the attributes
/// every notification carries is `error.NotAnObjectEvent`, and so is one
/// whose payload is not the object it names. An event type, payload format
/// or configuration name this library does not know is kept as unknown,
/// never refused: Cloud Storage adds event types.
pub fn decodeEvent(gpa: Allocator, message: anytype, options: DecodeEventOptions) DecodeEventError!types.Owned(types.ObjectEvent) {
    const diag = options.diagnostics;
    var found: Builtins = .{};
    var customs: usize = 0;
    for (message.attributes) |a| {
        if (found.take(a.key, a.value)) continue;
        customs += 1;
    }
    const event_type = found.eventType orelse return refuse(diag, "the message has no eventType attribute: it is not a Cloud Storage notification", .{});
    const bucket = found.bucketId orelse return refuse(diag, "the message has no bucketId attribute", .{});
    const object = found.objectId orelse return refuse(diag, "the message has no objectId attribute", .{});
    const generation_text = found.objectGeneration orelse return refuse(diag, "the message has no objectGeneration attribute", .{});
    const time = found.eventTime orelse return refuse(diag, "the message has no eventTime attribute", .{});
    if (bucket.len == 0 or object.len == 0) return refuse(diag, "the message names no bucket or no object", .{});
    const generation = std.fmt.parseInt(u64, generation_text, 10) catch
        return refuse(diag, "objectGeneration is not a generation: {s}", .{generation_text});
    _ = core.timestamp.parse(time) catch return refuse(diag, "eventTime is not an RFC 3339 time: {s}", .{time});
    const overwrote = try optionalGeneration(diag, "overwroteGeneration", found.overwroteGeneration);
    const overwritten_by = try optionalGeneration(diag, "overwrittenByGeneration", found.overwrittenByGeneration);
    const payload = codec.payloadFormatOf(found.payloadFormat orelse "");

    var result: types.Owned(types.ObjectEvent) = try .init(gpa);
    errdefer result.deinit();
    const a = result.arena.allocator();

    var info: ?types.ObjectInfo = null;
    if (payload == .json and message.data.len > 0) {
        const read = codec.decodeObject(a, message.data) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidResponse => return refuse(diag, "the payload is not an object's metadata", .{}),
        };
        if (!std.mem.eql(u8, read.bucket, bucket) or !std.mem.eql(u8, read.name, object) or read.generation != generation) {
            return refuse(diag, "the payload names another object than the attributes do", .{});
        }
        info = read;
    }

    const custom_attributes = try a.alloc(types.Attribute, customs);
    var i: usize = 0;
    for (message.attributes) |attribute| {
        if (isBuiltin(attribute.key)) continue;
        custom_attributes[i] = .{ .key = try a.dupe(u8, attribute.key), .value = try a.dupe(u8, attribute.value) };
        i += 1;
    }

    const kind = codec.eventTypeOf(event_type);
    const owned_bucket = try a.dupe(u8, bucket);
    const owned_object = try a.dupe(u8, object);
    const owned_time = try a.dupe(u8, time);
    result.value = .{
        .kind = kind,
        .bucket = owned_bucket,
        .object = owned_object,
        .generation = generation,
        .time = owned_time,
        .config = try configOf(a, found.notificationConfig),
        .overwrote_generation = overwrote,
        .overwritten_by_generation = overwritten_by,
        .payload = payload,
        .info = info,
        .custom_attributes = custom_attributes,
        .key = try key(a, event_type, generation, kind, info, owned_time, owned_bucket, owned_object),
    };
    return result;
}

/// The attributes Cloud Storage puts on its messages, as one message has
/// them. A name sent twice is taken at its first.
const Builtins = struct {
    notificationConfig: ?[]const u8 = null,
    eventType: ?[]const u8 = null,
    payloadFormat: ?[]const u8 = null,
    bucketId: ?[]const u8 = null,
    objectId: ?[]const u8 = null,
    objectGeneration: ?[]const u8 = null,
    eventTime: ?[]const u8 = null,
    overwroteGeneration: ?[]const u8 = null,
    overwrittenByGeneration: ?[]const u8 = null,

    /// Keeps `value` if `name` is one of Cloud Storage's attributes.
    fn take(self: *Builtins, name: []const u8, value: []const u8) bool {
        inline for (@typeInfo(Builtins).@"struct".fields) |field| {
            if (std.mem.eql(u8, name, field.name)) {
                if (@field(self, field.name) == null) @field(self, field.name) = value;
                return true;
            }
        }
        return false;
    }
};

comptime {
    // The attributes a configuration may not name are the ones read here.
    std.debug.assert(@typeInfo(Builtins).@"struct".fields.len == notifications.builtin_attributes.len);
    for (notifications.builtin_attributes) |name| std.debug.assert(@hasField(Builtins, name));
}

fn isBuiltin(name: []const u8) bool {
    for (notifications.builtin_attributes) |builtin| if (std.mem.eql(u8, name, builtin)) return true;
    return false;
}

fn optionalGeneration(diag: ?*core.Diagnostics, comptime name: []const u8, text: ?[]const u8) DecodeEventError!?u64 {
    const t = text orelse return null;
    return std.fmt.parseInt(u64, t, 10) catch return refuse(diag, name ++ " is not a generation: {s}", .{t});
}

/// `projects/_/buckets/B/notificationConfigs/ID` taken apart, or null for
/// any other form.
fn configOf(a: Allocator, name: ?[]const u8) Allocator.Error!?types.ObjectEvent.ConfigRef {
    const n = name orelse return null;
    const prefix = "projects/_/buckets/";
    if (!std.mem.startsWith(u8, n, prefix)) return null;
    const rest = n[prefix.len..];
    const cut = std.mem.indexOf(u8, rest, "/notificationConfigs/") orelse return null;
    const bucket = rest[0..cut];
    const id = rest[cut + "/notificationConfigs/".len ..];
    if (bucket.len == 0 or id.len == 0 or std.mem.indexOfScalar(u8, id, '/') != null) return null;
    return .{ .bucket = try a.dupe(u8, bucket), .id = try a.dupe(u8, id) };
}

/// `TYPE GENERATION PART BUCKET/OBJECT`: unambiguous, since no type,
/// generation, part or bucket name holds a space or the bucket a slash,
/// and the object, which may hold anything, comes last. PART tells apart
/// the metadata updates of one generation: the metageneration, or without
/// a payload the time; any other change happens once to a generation.
fn key(
    a: Allocator,
    event_type: []const u8,
    generation: u64,
    kind: types.EventType,
    info: ?types.ObjectInfo,
    time: []const u8,
    bucket: []const u8,
    object: []const u8,
) Allocator.Error![]const u8 {
    if (kind == .metadata_update) {
        if (info) |i| return std.fmt.allocPrint(a, "{s} {d} m{d} {s}/{s}", .{ event_type, generation, i.metageneration, bucket, object });
        return std.fmt.allocPrint(a, "{s} {d} t{s} {s}/{s}", .{ event_type, generation, time, bucket, object });
    }
    return std.fmt.allocPrint(a, "{s} {d} - {s}/{s}", .{ event_type, generation, bucket, object });
}

fn refuse(diag: ?*core.Diagnostics, comptime format: []const u8, args: anytype) error{NotAnObjectEvent} {
    if (diag) |d| d.print(format, args);
    return error.NotAnObjectEvent;
}

const testing = std.testing;
const test_util = @import("test_util.zig");

/// A message as a `Subscriber` hands one over, for these tests.
const Message = struct {
    data: []const u8 = "",
    attributes: []const types.Attribute,
};

// Production's messages, received on 2026-10-01 (`_tmp/notifications/e1`,
// run 6468ae), as sent; `cfg` is the test configuration's own attribute.
const media_none: Message = .{
    .attributes = &.{
        .{ .key = "bucketId", .value = "zigps-ntf-6468ae-pl" },
        .{ .key = "cfg", .value = "none" },
        .{ .key = "eventTime", .value = "2026-10-01T14:45:19.319871Z" },
        .{ .key = "eventType", .value = "OBJECT_FINALIZE" },
        .{ .key = "notificationConfig", .value = "projects/_/buckets/zigps-ntf-6468ae-pl/notificationConfigs/2" },
        .{ .key = "objectGeneration", .value = "1790865919311410" },
        .{ .key = "objectId", .value = "e1-media" },
        .{ .key = "payloadFormat", .value = "NONE" },
    },
};

const overwrite_finalize: Message = .{
    .data =
    \\{"kind":"storage#object","id":"zigps-ntf-6468ae-pl/e2-pl/1790865920189020","selfLink":"https://www.googleapis.com/storage/v1/b/zigps-ntf-6468ae-pl/o/e2-pl","name":"e2-pl","bucket":"zigps-ntf-6468ae-pl","generation":"1790865920189020","metageneration":"1","contentType":"text/plain","timeCreated":"2026-10-01T14:45:20.195Z","updated":"2026-10-01T14:45:20.195Z","storageClass":"STANDARD","timeStorageClassUpdated":"2026-10-01T14:45:20.195Z","size":"3","md5Hash":"+XxdKZQb+xsv2rCHSQargg==","mediaLink":"https://storage.googleapis.com/download/storage/v1/b/zigps-ntf-6468ae-pl/o/e2-pl?generation=1790865920189020&alt=media","crc32c":"KpSy6Q==","etag":"CNzEjbiHmZcDEAE="}
    ,
    .attributes = &.{
        .{ .key = "bucketId", .value = "zigps-ntf-6468ae-pl" },
        .{ .key = "cfg", .value = "all" },
        .{ .key = "eventTime", .value = "2026-10-01T14:45:20.195535Z" },
        .{ .key = "eventType", .value = "OBJECT_FINALIZE" },
        .{ .key = "notificationConfig", .value = "projects/_/buckets/zigps-ntf-6468ae-pl/notificationConfigs/1" },
        .{ .key = "objectGeneration", .value = "1790865920189020" },
        .{ .key = "objectId", .value = "e2-pl" },
        .{ .key = "payloadFormat", .value = "JSON_API_V1" },
    },
};

const overwrite_delete: Message = .{
    .data =
    \\{"kind":"storage#object","id":"zigps-ntf-6468ae-pl/e2-pl/1790865920189020","selfLink":"https://www.googleapis.com/storage/v1/b/zigps-ntf-6468ae-pl/o/e2-pl","name":"e2-pl","bucket":"zigps-ntf-6468ae-pl","generation":"1790865920189020","metageneration":"1","contentType":"text/plain","timeCreated":"2026-10-01T14:45:20.195Z","updated":"2026-10-01T14:45:20.195Z","storageClass":"STANDARD","timeStorageClassUpdated":"2026-10-01T14:45:20.195Z","size":"3","md5Hash":"+XxdKZQb+xsv2rCHSQargg==","mediaLink":"https://storage.googleapis.com/download/storage/v1/b/zigps-ntf-6468ae-pl/o/e2-pl?generation=1790865920189020&alt=media","crc32c":"KpSy6Q==","etag":"CNzEjbiHmZcDEAE="}
    ,
    .attributes = &.{
        .{ .key = "bucketId", .value = "zigps-ntf-6468ae-pl" },
        .{ .key = "cfg", .value = "all" },
        .{ .key = "eventTime", .value = "2026-10-01T14:45:20.374951Z" },
        .{ .key = "eventType", .value = "OBJECT_DELETE" },
        .{ .key = "notificationConfig", .value = "projects/_/buckets/zigps-ntf-6468ae-pl/notificationConfigs/1" },
        .{ .key = "objectGeneration", .value = "1790865920189020" },
        .{ .key = "objectId", .value = "e2-pl" },
        .{ .key = "overwrittenByGeneration", .value = "1790865920355888" },
        .{ .key = "payloadFormat", .value = "JSON_API_V1" },
    },
};

const versioned_archive: Message = .{
    .data =
    \\{"kind":"storage#object","id":"zigps-ntf-6468ae-ver/e4/1790865923383368","selfLink":"https://www.googleapis.com/storage/v1/b/zigps-ntf-6468ae-ver/o/e4","name":"e4","bucket":"zigps-ntf-6468ae-ver","generation":"1790865923383368","metageneration":"1","contentType":"text/plain","timeCreated":"2026-10-01T14:45:23.390Z","updated":"2026-10-01T14:45:23.390Z","timeDeleted":"2026-10-01T14:45:23.579Z","storageClass":"STANDARD","timeStorageClassUpdated":"2026-10-01T14:45:23.390Z","size":"3","md5Hash":"+XxdKZQb+xsv2rCHSQargg==","mediaLink":"https://storage.googleapis.com/download/storage/v1/b/zigps-ntf-6468ae-ver/o/e4?generation=1790865923383368&alt=media","crc32c":"KpSy6Q==","etag":"CMjA0LmHmZcDEAE="}
    ,
    .attributes = &.{
        .{ .key = "bucketId", .value = "zigps-ntf-6468ae-ver" },
        .{ .key = "cfg", .value = "ver" },
        .{ .key = "eventTime", .value = "2026-10-01T14:45:23.579228Z" },
        .{ .key = "eventType", .value = "OBJECT_ARCHIVE" },
        .{ .key = "notificationConfig", .value = "projects/_/buckets/zigps-ntf-6468ae-ver/notificationConfigs/1" },
        .{ .key = "objectGeneration", .value = "1790865923383368" },
        .{ .key = "objectId", .value = "e4" },
        .{ .key = "overwrittenByGeneration", .value = "1790865923563650" },
        .{ .key = "payloadFormat", .value = "JSON_API_V1" },
    },
};

const compose_over: Message = .{
    .data =
    \\{"kind":"storage#object","id":"zigps-ntf-6468ae-pl/e6-composed/1790865925011964","selfLink":"https://www.googleapis.com/storage/v1/b/zigps-ntf-6468ae-pl/o/e6-composed","name":"e6-composed","bucket":"zigps-ntf-6468ae-pl","generation":"1790865925011964","metageneration":"1","timeCreated":"2026-10-01T14:45:25.028Z","updated":"2026-10-01T14:45:25.028Z","storageClass":"STANDARD","timeStorageClassUpdated":"2026-10-01T14:45:25.028Z","size":"6","mediaLink":"https://storage.googleapis.com/download/storage/v1/b/zigps-ntf-6468ae-pl/o/e6-composed?generation=1790865925011964&alt=media","crc32c":"yK7UyQ==","componentCount":2,"etag":"CPzzs7qHmZcDEAE="}
    ,
    .attributes = &.{
        .{ .key = "bucketId", .value = "zigps-ntf-6468ae-pl" },
        .{ .key = "cfg", .value = "all" },
        .{ .key = "eventTime", .value = "2026-10-01T14:45:25.028269Z" },
        .{ .key = "eventType", .value = "OBJECT_FINALIZE" },
        .{ .key = "notificationConfig", .value = "projects/_/buckets/zigps-ntf-6468ae-pl/notificationConfigs/1" },
        .{ .key = "objectGeneration", .value = "1790865925011964" },
        .{ .key = "objectId", .value = "e6-composed" },
        .{ .key = "overwroteGeneration", .value = "1790865924808604" },
        .{ .key = "payloadFormat", .value = "JSON_API_V1" },
    },
};

const metadata_update: Message = .{
    .data =
    \\{"kind":"storage#object","id":"zigps-ntf-6468ae-pl/e7/1790865925703921","selfLink":"https://www.googleapis.com/storage/v1/b/zigps-ntf-6468ae-pl/o/e7","name":"e7","bucket":"zigps-ntf-6468ae-pl","generation":"1790865925703921","metageneration":"2","contentType":"text/plain","timeCreated":"2026-10-01T14:45:25.712Z","updated":"2026-10-01T14:45:25.839Z","storageClass":"STANDARD","timeStorageClassUpdated":"2026-10-01T14:45:25.712Z","size":"4","md5Hash":"6aI8vEVRWJUXFrRAw9Fl4A==","mediaLink":"https://storage.googleapis.com/download/storage/v1/b/zigps-ntf-6468ae-pl/o/e7?generation=1790865925703921&alt=media","metadata":{"k":"v"},"crc32c":"GwcQlQ==","etag":"CPGR3rqHmZcDEAI="}
    ,
    .attributes = &.{
        .{ .key = "bucketId", .value = "zigps-ntf-6468ae-pl" },
        .{ .key = "cfg", .value = "all" },
        .{ .key = "eventTime", .value = "2026-10-01T14:45:25.839071Z" },
        .{ .key = "eventType", .value = "OBJECT_METADATA_UPDATE" },
        .{ .key = "notificationConfig", .value = "projects/_/buckets/zigps-ntf-6468ae-pl/notificationConfigs/1" },
        .{ .key = "objectGeneration", .value = "1790865925703921" },
        .{ .key = "objectId", .value = "e7" },
        .{ .key = "payloadFormat", .value = "JSON_API_V1" },
    },
};

/// fake-gcs-server 1.56.1's shape: no `notificationConfig`, whole seconds
/// in the server's own zone, a thin payload whose `id` ends `#generation`.
const emulator_finalize: Message = .{
    .data =
    \\{"kind":"storage#object","id":"zigps-test/in/a.txt#1759329919000000","name":"in/a.txt","bucket":"zigps-test","generation":"1759329919000000","contentType":"text/plain","size":"5","crc32c":"mnG7TA==","md5Hash":"XUFAKrxLKna5cZ2REBfFkg==","storageClass":"STANDARD","timeCreated":"2026-10-01T09:45:19-05:00","updated":"2026-10-01T09:45:19-05:00"}
    ,
    .attributes = &.{
        .{ .key = "team", .value = "data" },
        .{ .key = "bucketId", .value = "zigps-test" },
        .{ .key = "eventTime", .value = "2026-10-01T09:45:19-05:00" },
        .{ .key = "eventType", .value = "OBJECT_FINALIZE" },
        .{ .key = "objectGeneration", .value = "1759329919000000" },
        .{ .key = "objectId", .value = "in/a.txt" },
        .{ .key = "payloadFormat", .value = "JSON_API_V1" },
    },
};

fn decoded(message: Message) !types.Owned(types.ObjectEvent) {
    return decodeEvent(testing.allocator, message, .{});
}

test "decode: production's messages, one of each kind" {
    {
        var e = try decoded(overwrite_finalize);
        defer e.deinit();
        try testing.expectEqual(.finalize, e.value.kind);
        try testing.expectEqualStrings("zigps-ntf-6468ae-pl", e.value.bucket);
        try testing.expectEqualStrings("e2-pl", e.value.object);
        try testing.expectEqual(1790865920189020, e.value.generation);
        try testing.expectEqualStrings("2026-10-01T14:45:20.195535Z", e.value.time);
        try testing.expectEqualStrings("zigps-ntf-6468ae-pl", e.value.config.?.bucket);
        try testing.expectEqualStrings("1", e.value.config.?.id);
        try testing.expectEqual(null, e.value.overwrote_generation);
        try testing.expectEqual(.json, e.value.payload);
        try testing.expectEqual(3, e.value.info.?.size);
        try testing.expectEqual(1, e.value.info.?.metageneration);
        try testing.expectEqualStrings("text/plain", e.value.info.?.content_type);
        try testing.expectEqual(1, e.value.custom_attributes.len);
        try testing.expectEqualStrings("cfg", e.value.custom_attributes[0].key);
        try testing.expectEqualStrings("all", e.value.custom_attributes[0].value);
        try testing.expectEqualStrings("OBJECT_FINALIZE 1790865920189020 - zigps-ntf-6468ae-pl/e2-pl", e.value.key);
    }
    {
        // The other half of the overwrite.
        var e = try decoded(overwrite_delete);
        defer e.deinit();
        try testing.expectEqual(.delete, e.value.kind);
        try testing.expectEqual(1790865920355888, e.value.overwritten_by_generation.?);
        // As it was before the delete; a plain bucket's delete carries no
        // timeDeleted, whatever the documentation says.
        try testing.expectEqual(null, e.value.info.?.time_deleted);
    }
    {
        var e = try decoded(versioned_archive);
        defer e.deinit();
        try testing.expectEqual(.archive, e.value.kind);
        try testing.expectEqual(1790865923563650, e.value.overwritten_by_generation.?);
        try testing.expectEqualStrings("2026-10-01T14:45:23.579Z", e.value.info.?.time_deleted.?);
        try testing.expectEqualStrings("1", e.value.config.?.id);
    }
    {
        var e = try decoded(compose_over);
        defer e.deinit();
        try testing.expectEqual(.finalize, e.value.kind);
        try testing.expectEqual(1790865924808604, e.value.overwrote_generation.?);
        try testing.expectEqual(2, e.value.info.?.component_count.?);
        try testing.expectEqual(null, e.value.info.?.md5);
    }
    {
        var e = try decoded(metadata_update);
        defer e.deinit();
        try testing.expectEqual(.metadata_update, e.value.kind);
        try testing.expectEqual(2, e.value.info.?.metageneration);
        try testing.expectEqualStrings("v", e.value.info.?.metadata[0].value);
        try testing.expectEqualStrings("OBJECT_METADATA_UPDATE 1790865925703921 m2 zigps-ntf-6468ae-pl/e7", e.value.key);
    }
    {
        var e = try decoded(media_none);
        defer e.deinit();
        try testing.expectEqual(.none, e.value.payload);
        try testing.expectEqual(null, e.value.info);
        try testing.expectEqualStrings("2", e.value.config.?.id);
    }
}

test "decode: the emulator's messages, which leave the configuration out" {
    var e = try decoded(emulator_finalize);
    defer e.deinit();
    try testing.expectEqual(.finalize, e.value.kind);
    try testing.expectEqual(null, e.value.config);
    try testing.expectEqualStrings("in/a.txt", e.value.object);
    try testing.expectEqualStrings("2026-10-01T09:45:19-05:00", e.value.time);
    try testing.expectEqual(5, e.value.info.?.size);
    try testing.expectEqualStrings("team", e.value.custom_attributes[0].key);
}

fn withAttribute(arena: Allocator, base: Message, name: []const u8, value: ?[]const u8) !Message {
    var out: std.ArrayList(types.Attribute) = .empty;
    for (base.attributes) |a| if (!std.mem.eql(u8, a.key, name)) try out.append(arena, a);
    if (value) |v| try out.append(arena, .{ .key = name, .value = v });
    return .{ .data = base.data, .attributes = out.items };
}

test "decode: what is not a notification is refused, and says why" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const Case = struct { message: Message, says: []const u8 };
    const cases = [_]Case{
        .{ .message = .{ .data = "hello", .attributes = &.{.{ .key = "origin", .value = "elsewhere" }} }, .says = "no eventType" },
        .{ .message = try withAttribute(arena, overwrite_finalize, "bucketId", null), .says = "no bucketId" },
        .{ .message = try withAttribute(arena, overwrite_finalize, "objectId", null), .says = "no objectId" },
        .{ .message = try withAttribute(arena, overwrite_finalize, "objectGeneration", null), .says = "no objectGeneration" },
        .{ .message = try withAttribute(arena, overwrite_finalize, "eventTime", null), .says = "no eventTime" },
        .{ .message = try withAttribute(arena, overwrite_finalize, "objectId", ""), .says = "names no bucket or no object" },
        .{ .message = try withAttribute(arena, overwrite_finalize, "objectGeneration", "-1"), .says = "objectGeneration is not a generation" },
        .{ .message = try withAttribute(arena, overwrite_finalize, "eventTime", "yesterday"), .says = "eventTime is not an RFC 3339 time" },
        .{ .message = try withAttribute(arena, overwrite_delete, "overwrittenByGeneration", "x"), .says = "overwrittenByGeneration is not a generation" },
        .{ .message = try withAttribute(arena, compose_over, "overwroteGeneration", ""), .says = "overwroteGeneration is not a generation" },
        .{ .message = .{ .data = "{not json", .attributes = overwrite_finalize.attributes }, .says = "payload is not an object's metadata" },
        .{ .message = try withAttribute(arena, overwrite_finalize, "objectId", "e2-other"), .says = "names another object" },
        .{ .message = try withAttribute(arena, overwrite_finalize, "objectGeneration", "1790865920189021"), .says = "names another object" },
        .{ .message = try withAttribute(arena, overwrite_finalize, "bucketId", "zigps-other"), .says = "names another object" },
    };
    for (cases) |case| {
        var diag: core.Diagnostics = .{};
        try testing.expectError(error.NotAnObjectEvent, decodeEvent(testing.allocator, case.message, .{ .diagnostics = &diag }));
        if (std.mem.indexOf(u8, diag.message(), case.says) == null) {
            std.debug.print("diagnostics \"{s}\" lack \"{s}\"\n", .{ diag.message(), case.says });
            return error.TestUnexpectedDiagnostics;
        }
    }
}

test "decode: what this library does not know is kept, never refused" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    {
        var e = try decoded(try withAttribute(arena, media_none, "eventType", "OBJECT_TELEPORTED"));
        defer e.deinit();
        try testing.expectEqual(.unknown, e.value.kind);
        try testing.expectEqualStrings("OBJECT_TELEPORTED 1790865919311410 - zigps-ntf-6468ae-pl/e1-media", e.value.key);
    }
    {
        var e = try decoded(try withAttribute(arena, media_none, "eventType", "OBJECT_INITIALIZE"));
        defer e.deinit();
        try testing.expectEqual(.initialize, e.value.kind);
    }
    {
        // A format it cannot read: the payload is not read either.
        var e = try decoded(.{ .data = "\x08\x01", .attributes = (try withAttribute(arena, overwrite_finalize, "payloadFormat", "PROTOBUF")).attributes });
        defer e.deinit();
        try testing.expectEqual(.unknown, e.value.payload);
        try testing.expectEqual(null, e.value.info);
    }
    for ([_][]const u8{ "projects/_/buckets//notificationConfigs/1", "projects/_/buckets/b/notificationConfigs/", "projects/_/buckets/b/notificationConfigs/1/x", "buckets/b/notificationConfigs/1" }) |name| {
        var e = try decoded(try withAttribute(arena, media_none, "notificationConfig", name));
        defer e.deinit();
        try testing.expectEqual(null, e.value.config);
    }
    {
        // A name sent twice counts at its first.
        var twice = try withAttribute(arena, media_none, "objectId", null);
        var list: std.ArrayList(types.Attribute) = .empty;
        try list.appendSlice(arena, twice.attributes);
        try list.append(arena, .{ .key = "objectId", .value = "first" });
        try list.append(arena, .{ .key = "objectId", .value = "second" });
        twice.attributes = list.items;
        var e = try decoded(twice);
        defer e.deinit();
        try testing.expectEqualStrings("first", e.value.object);
        try testing.expectEqual(1, e.value.custom_attributes.len);
    }
}

test "decode: the event outlives the message it came in" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const data = try arena.dupe(u8, metadata_update.data);
    const attributes = try arena.alloc(types.Attribute, metadata_update.attributes.len);
    for (metadata_update.attributes, attributes) |from, *to| to.* = .{ .key = try arena.dupe(u8, from.key), .value = try arena.dupe(u8, from.value) };
    var e = try decoded(.{ .data = data, .attributes = attributes });
    defer e.deinit();
    @memset(data, 'x');
    for (attributes) |a| {
        @memset(@constCast(a.key), 'x');
        @memset(@constCast(a.value), 'x');
    }
    try testing.expectEqualStrings("e7", e.value.object);
    try testing.expectEqualStrings("zigps-ntf-6468ae-pl", e.value.info.?.bucket);
    try testing.expectEqualStrings("v", e.value.info.?.metadata[0].value);
    try testing.expectEqualStrings("all", e.value.custom_attributes[0].value);
    try testing.expectEqualStrings("1", e.value.config.?.id);
    try testing.expectEqualStrings("OBJECT_METADATA_UPDATE 1790865925703921 m2 zigps-ntf-6468ae-pl/e7", e.value.key);
}

test "decode: a retention's time as text, or as a protocol buffer Timestamp" {
    const base =
        \\{"kind":"storage#object","name":"e7","bucket":"zigps-ntf-6468ae-pl","generation":"1790865925703921","metageneration":"3","size":"4","retention":
    ;
    const Case = struct { retention: []const u8, until: ?[]const u8 };
    for ([_]Case{
        .{ .retention = "{\"mode\":\"Unlocked\",\"retainUntilTime\":\"2027-01-01T00:00:00Z\"}}", .until = "2027-01-01T00:00:00Z" },
        .{ .retention = "{\"mode\":\"Locked\",\"retainUntilTime\":{\"seconds\":\"1798761600\",\"nanos\":500}}}", .until = "2027-01-01T00:00:00.000000500Z" },
        .{ .retention = "{\"mode\":\"Locked\",\"retainUntilTime\":{\"seconds\":1798761600}}}", .until = "2027-01-01T00:00:00Z" },
        .{ .retention = "{\"mode\":\"Locked\",\"retainUntilTime\":{\"seconds\":\"x\"}}}", .until = null },
        .{ .retention = "{\"mode\":\"Locked\",\"retainUntilTime\":{\"seconds\":1,\"nanos\":1000000000}}}", .until = null },
        .{ .retention = "{\"mode\":\"Locked\",\"retainUntilTime\":[1]}}", .until = null },
    }) |case| {
        var data: std.ArrayList(u8) = .empty;
        defer data.deinit(testing.allocator);
        try data.appendSlice(testing.allocator, base);
        try data.appendSlice(testing.allocator, case.retention);
        const message: Message = .{ .data = data.items, .attributes = metadata_update.attributes };
        if (case.until) |until| {
            var e = try decoded(message);
            defer e.deinit();
            try testing.expectEqualStrings(until, e.value.info.?.retention.?.retain_until);
        } else {
            try testing.expectError(error.NotAnObjectEvent, decoded(message));
        }
    }
}

test "decode: keys tell a repeat from a new change" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var once = try decoded(metadata_update);
    defer once.deinit();
    var again = try decoded(metadata_update);
    defer again.deinit();
    try testing.expectEqualStrings(once.value.key, again.value.key);

    // The next update of the generation, with and without a payload.
    const next_data = try std.mem.replaceOwned(u8, arena, metadata_update.data, "\"metageneration\":\"2\"", "\"metageneration\":\"3\"");
    var next = try decoded(.{ .data = next_data, .attributes = metadata_update.attributes });
    defer next.deinit();
    try testing.expect(!std.mem.eql(u8, once.value.key, next.value.key));
    const bare = try withAttribute(arena, metadata_update, "payloadFormat", "NONE");
    var first = try decoded(.{ .attributes = bare.attributes });
    defer first.deinit();
    try testing.expectEqualStrings("OBJECT_METADATA_UPDATE 1790865925703921 t2026-10-01T14:45:25.839071Z zigps-ntf-6468ae-pl/e7", first.value.key);
    var later = try decoded(.{ .attributes = (try withAttribute(arena, bare, "eventTime", "2026-10-01T14:45:25.970239Z")).attributes });
    defer later.deinit();
    try testing.expect(!std.mem.eql(u8, first.value.key, later.value.key));

    // The two halves of one overwrite are two changes.
    var finalize = try decoded(overwrite_finalize);
    defer finalize.deinit();
    var delete = try decoded(overwrite_delete);
    defer delete.deinit();
    try testing.expect(!std.mem.eql(u8, finalize.value.key, delete.value.key));

    // The object comes last, whatever it holds.
    var odd = try decoded(.{ .attributes = (try withAttribute(arena, media_none, "objectId", "a b/c 1 - x")).attributes });
    defer odd.deinit();
    try testing.expectEqualStrings("OBJECT_FINALIZE 1790865919311410 - zigps-ntf-6468ae-pl/a b/c 1 - x", odd.value.key);
}

fn decodeEverything(gpa: Allocator) !void {
    for ([_]Message{ media_none, overwrite_finalize, overwrite_delete, versioned_archive, compose_over, metadata_update, emulator_finalize }) |message| {
        var e = try decodeEvent(gpa, message, .{});
        e.deinit();
    }
}

test "decode: every allocation failure is OutOfMemory, and nothing leaks" {
    try testing.checkAllAllocationFailures(testing.allocator, decodeEverything, .{});
}

/// Attributes drawn from `bytes`: Cloud Storage's names, sometimes twice or
/// missing, with values near what it sends, and custom ones; the data one
/// of the production payloads, a mangled one, or noise.
fn eventProperty(_: void, bytes: []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var g: test_util.ByteGen = .init(bytes);
    const base = g.pick(Message, &.{ media_none, overwrite_finalize, overwrite_delete, versioned_archive, compose_over, metadata_update, emulator_finalize });
    var attributes: std.ArrayList(types.Attribute) = .empty;
    for (base.attributes) |a| {
        switch (g.intRange(u8, 0, 7)) {
            0 => {},
            1 => try attributes.append(arena, .{ .key = a.key, .value = g.utf8(try arena.alloc(u8, 24), 24) }),
            2 => {
                try attributes.append(arena, a);
                try attributes.append(arena, .{ .key = a.key, .value = g.utf8(try arena.alloc(u8, 24), 24) });
            },
            else => try attributes.append(arena, a),
        }
    }
    for (0..g.intRange(u8, 0, 3)) |_| {
        try attributes.append(arena, .{ .key = g.utf8(try arena.alloc(u8, 12), 12), .value = g.utf8(try arena.alloc(u8, 12), 12) });
    }
    const data: []const u8 = switch (g.intRange(u8, 0, 3)) {
        0 => base.data,
        1 => base.data[0..g.intRange(usize, 0, base.data.len)],
        2 => g.slice(64),
        else => "",
    };
    const message: Message = .{ .data = data, .attributes = attributes.items };
    var e = decodeEvent(testing.allocator, message, .{}) catch |err| switch (err) {
        error.NotAnObjectEvent => return,
        error.OutOfMemory => return err,
    };
    defer e.deinit();
    // Decoded: the attributes as sent, each at its first, and every other
    // one kept as the configuration's own.
    var first: Builtins = .{};
    var customs: usize = 0;
    for (message.attributes) |a| {
        if (!first.take(a.key, a.value)) customs += 1;
    }
    try testing.expectEqualStrings(first.bucketId.?, e.value.bucket);
    try testing.expectEqualStrings(first.objectId.?, e.value.object);
    try testing.expectEqualStrings(first.eventTime.?, e.value.time);
    try testing.expectEqual(try std.fmt.parseInt(u64, first.objectGeneration.?, 10), e.value.generation);
    try testing.expectEqual(customs, e.value.custom_attributes.len);
    try testing.expect(std.mem.endsWith(u8, e.value.key, first.objectId.?));
    try testing.expect(std.mem.startsWith(u8, e.value.key, first.eventType.?));
    if (e.value.info) |info| {
        try testing.expectEqualStrings(e.value.object, info.name);
        try testing.expectEqual(e.value.generation, info.generation);
    }
}

test "fuzz object events: any message decodes as sent, or is refused" {
    try test_util.fuzzBytes({}, eventProperty, .{ .corpus = &.{ "", "\x00" ** 32, "\x03" ** 48, "\x05\x07" ** 40 } });
}
