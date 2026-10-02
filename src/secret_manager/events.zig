//! `decodeEvent`: a Pub/Sub message Secret Manager published to a secret's
//! topic, read into a `SecretEvent`. It takes any value with `data` and
//! `attributes`, as `pubsub.ReceivedMessage` has, so neither module
//! imports the other. What the messages carry was measured in production
//! on 2026-10-02 (`_tmp/secrets-fill/production-s.md`):
//!
//! - `TOPIC_CONFIGURED` carries `eventType` alone and no data.
//! - Every other message carries `eventType`, `dataFormat` `JSON_API_V1`,
//!   `secretId` (the full name, with the project number) and `timestamp`
//!   (Pacific time with an offset, up to six fraction digits); version
//!   events add `versionId` (the version's full name), a delete adds
//!   `deleteType`. The data is the Secret or the SecretVersion as JSON.

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("core");

const codec = @import("codec.zig");
const names = @import("names.zig");
const types = @import("types.zig");

pub const DecodeEventError = error{
    /// The message is not one Secret Manager published to a secret's
    /// topic, or says something no such message could: `Diagnostics` says
    /// which.
    NotASecretEvent,
    OutOfMemory,
};

pub const DecodeEventOptions = struct {
    /// Where a refusal says why.
    diagnostics: ?*core.Diagnostics = null,
};

const kinds = std.StaticStringMap(types.EventKind).initComptime(.{
    .{ "TOPIC_CONFIGURED", .topic_configured },
    .{ "SECRET_CREATE", .secret_create },
    .{ "SECRET_UPDATE", .secret_update },
    .{ "SECRET_DELETE", .secret_delete },
    .{ "SECRET_ROTATE", .secret_rotate },
    .{ "SECRET_VERSION_ADD", .version_add },
    .{ "SECRET_VERSION_ENABLE", .version_enable },
    .{ "SECRET_VERSION_DISABLE", .version_disable },
    .{ "SECRET_VERSION_DESTROY", .version_destroy },
    .{ "SECRET_VERSION_DESTROY_SCHEDULED", .version_destroy_scheduled },
});

const delete_types = std.StaticStringMap(types.DeleteType).initComptime(.{
    .{ "REQUESTED", .requested },
    .{ "EXPIRATION", .expiration },
});

/// Reads the change `message` reports, copying everything it keeps, so the
/// event outlives the message, which a `Subscriber` handler's does not.
/// `message` is any value with `data: []const u8` and `attributes`, a slice
/// of values with `key` and `value`.
///
/// A message without `eventType` is `error.NotASecretEvent`, and so is one
/// of a known kind without the attributes that kind carries, with a time
/// that is not RFC 3339, or with data that is not the secret or version it
/// names. An event type or data format this library does not know is kept
/// as `.unknown` or left undecoded, never refused: Secret Manager adds
/// them.
pub fn decodeEvent(gpa: Allocator, message: anytype, options: DecodeEventOptions) DecodeEventError!types.Owned(types.SecretEvent) {
    const diag = options.diagnostics;
    var found: Attributes = .{};
    for (message.attributes) |a| found.take(a.key, a.value);

    const event_type = found.eventType orelse return refuse(diag, "the message has no eventType attribute: it is not a Secret Manager event", .{});
    const kind = kinds.get(event_type) orelse .unknown;

    var result: types.Owned(types.SecretEvent) = try .init(gpa);
    errdefer result.deinit();
    const a = result.arena.allocator();

    if (kind == .topic_configured) {
        result.value = .{
            .kind = kind,
            .event_type = try a.dupe(u8, event_type),
            .secret = "",
            .location = null,
            .version = null,
            .delete_type = null,
            .time = "",
            .info = null,
            .version_info = null,
            .key = try a.dupe(u8, event_type),
        };
        return result;
    }

    const known = kind != .unknown;
    const secret = found.secretId orelse if (known)
        return refuse(diag, "the message has no secretId attribute", .{})
    else
        "";
    const location = if (secret.len > 0) try locationOf(diag, secret) else null;
    const time = found.timestamp orelse if (known)
        return refuse(diag, "the message has no timestamp attribute", .{})
    else
        "";
    if (time.len > 0) _ = core.timestamp.parse(time) catch
        return refuse(diag, "the timestamp attribute is not an RFC 3339 time: {s}", .{time});

    const is_version = switch (kind) {
        .version_add, .version_enable, .version_disable, .version_destroy, .version_destroy_scheduled => true,
        else => false,
    };
    var version: ?u64 = null;
    if (found.versionId) |id| {
        version = versionOf(secret, id) orelse
            return refuse(diag, "versionId names no version of the secret: {s}", .{id});
    } else if (is_version) {
        return refuse(diag, "a version event has no versionId attribute", .{});
    }

    const delete_type: ?types.DeleteType = if (kind == .secret_delete)
        if (found.deleteType) |t| delete_types.get(t) orelse .unknown else .unknown
    else
        null;

    // Data in a format this library knows is decoded, and must be what the
    // attributes name; any other format is left alone.
    const json = if (found.dataFormat) |f| std.mem.eql(u8, f, "JSON_API_V1") else false;
    var info: ?types.SecretInfo = null;
    var version_info: ?types.VersionInfo = null;
    if (json and message.data.len > 0 and known) {
        // The decoders point into what they decode where they can, and the
        // event must outlive the message.
        const data = try a.dupe(u8, message.data);
        if (is_version) {
            const v = codec.decodeVersion(a, data) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidResponse => return refuse(diag, "the data is not the version the message names", .{}),
            };
            if (!std.mem.eql(u8, v.name, found.versionId.?)) return refuse(diag, "the data names another version than versionId", .{});
            version_info = v;
        } else {
            const sec = codec.decodeSecret(a, data) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidResponse => return refuse(diag, "the data is not the secret the message names", .{}),
            };
            if (!std.mem.eql(u8, sec.name, secret)) return refuse(diag, "the data names another secret than secretId", .{});
            info = sec;
        }
    }

    const owned_secret = try a.dupe(u8, secret);
    const owned_time = try a.dupe(u8, time);
    result.value = .{
        .kind = kind,
        .event_type = try a.dupe(u8, event_type),
        .secret = owned_secret,
        .location = if (location) |l| try a.dupe(u8, l) else null,
        .version = version,
        .delete_type = delete_type,
        .time = owned_time,
        .info = info,
        .version_info = version_info,
        .key = try key(a, event_type, owned_secret, version, owned_time),
    };
    return result;
}

/// The attributes Secret Manager puts on its messages, as one message has
/// them. A name sent twice is taken at its first; any other is ignored.
const Attributes = struct {
    eventType: ?[]const u8 = null,
    dataFormat: ?[]const u8 = null,
    secretId: ?[]const u8 = null,
    versionId: ?[]const u8 = null,
    timestamp: ?[]const u8 = null,
    deleteType: ?[]const u8 = null,

    fn take(self: *Attributes, name: []const u8, value: []const u8) void {
        inline for (@typeInfo(Attributes).@"struct".fields) |field| {
            if (std.mem.eql(u8, name, field.name)) {
                if (@field(self, field.name) == null) @field(self, field.name) = value;
                return;
            }
        }
    }
};

/// The location of `projects/P/locations/L/secrets/ID`, null for
/// `projects/P/secrets/ID`; anything else is no secret's name.
fn locationOf(diag: ?*core.Diagnostics, secret: []const u8) DecodeEventError!?[]const u8 {
    var parts = std.mem.splitScalar(u8, secret, '/');
    const p = parts.next() orelse "";
    const project = parts.next() orelse "";
    const third = parts.next() orelse "";
    if (!std.mem.eql(u8, p, "projects") or project.len == 0) return refuse(diag, "secretId is not a secret's name: {s}", .{secret});
    var location: ?[]const u8 = null;
    var collection = third;
    if (std.mem.eql(u8, third, "locations")) {
        location = parts.next() orelse "";
        if (location.?.len == 0) return refuse(diag, "secretId is not a secret's name: {s}", .{secret});
        collection = parts.next() orelse "";
    }
    const id = parts.next() orelse "";
    if (!std.mem.eql(u8, collection, "secrets") or id.len == 0 or parts.next() != null) {
        return refuse(diag, "secretId is not a secret's name: {s}", .{secret});
    }
    return location;
}

/// The number of `SECRET/versions/N`, or null when the name is not one of
/// `secret`'s versions.
fn versionOf(secret: []const u8, name: []const u8) ?u64 {
    if (!std.mem.startsWith(u8, name, secret)) return null;
    const rest = name[secret.len..];
    const prefix = "/versions/";
    if (!std.mem.startsWith(u8, rest, prefix)) return null;
    const n = std.fmt.parseInt(u64, rest[prefix.len..], 10) catch return null;
    return if (n == 0) null else n;
}

/// `TYPE NAME[/versions/N] TIME`: no type, name or time holds a space, and
/// one change to one resource has one time.
fn key(a: Allocator, event_type: []const u8, secret: []const u8, version: ?u64, time: []const u8) Allocator.Error![]const u8 {
    if (version) |v| return std.fmt.allocPrint(a, "{s} {s}/versions/{d} {s}", .{ event_type, secret, v, time });
    return std.fmt.allocPrint(a, "{s} {s} {s}", .{ event_type, secret, time });
}

fn refuse(diag: ?*core.Diagnostics, comptime format: []const u8, args: anytype) error{NotASecretEvent} {
    if (diag) |d| d.print(format, args);
    return error.NotASecretEvent;
}

const testing = std.testing;
const test_util = @import("test_util.zig");

/// A message as a `Subscriber` hands one over, for these tests.
const Message = struct {
    data: []const u8 = "",
    attributes: []const types.Label,
};

// Production's messages, received on 2026-10-02 (`_tmp/secrets-fill/b`,
// run 54e2ea98), as sent.
const topic_configured: Message = .{ .attributes = &.{.{ .key = "eventType", .value = "TOPIC_CONFIGURED" }} };

const global_create: Message = .{
    .attributes = &.{
        .{ .key = "dataFormat", .value = "JSON_API_V1" },
        .{ .key = "eventType", .value = "SECRET_CREATE" },
        .{ .key = "secretId", .value = "projects/82150720798/secrets/zigps-smf-54e2ea98-b15top" },
        .{ .key = "timestamp", .value = "2026-10-02T06:02:50.882009-07:00" },
    },
    .data =
    \\{"createTime":"2026-10-02T13:02:50.882009Z","etag":"\"165cdb2653c7d9\"","labels":{"zig-gcp-test":"1","zigps-run":"54e2ea98"},"name":"projects/82150720798/secrets/zigps-smf-54e2ea98-b15top","replication":{"automatic":{}},"topics":[{"name":"projects/extractctl/topics/zigps-smf-54e2ea98-t1"}]}
    ,
};

const expired: Message = .{
    .attributes = &.{
        .{ .key = "dataFormat", .value = "JSON_API_V1" },
        .{ .key = "deleteType", .value = "EXPIRATION" },
        .{ .key = "eventType", .value = "SECRET_DELETE" },
        .{ .key = "secretId", .value = "projects/82150720798/secrets/zigps-smf-54e2ea98-evx" },
        .{ .key = "timestamp", .value = "2026-10-02T06:05:12.919644-07:00" },
    },
    .data =
    \\{"createTime":"2026-10-02T13:03:42.890635Z","etag":"\"165cdb296ef0e2\"","expireTime":"2026-10-02T13:05:12.795840164Z","labels":{"zig-gcp-test":"1","zigps-run":"54e2ea98"},"name":"projects/82150720798/secrets/zigps-smf-54e2ea98-evx","replication":{"automatic":{}},"topics":[{"name":"projects/extractctl/topics/zigps-smf-54e2ea98-t1"}]}
    ,
};

const destroy_scheduled: Message = .{
    .attributes = &.{
        .{ .key = "dataFormat", .value = "JSON_API_V1" },
        .{ .key = "eventType", .value = "SECRET_VERSION_DESTROY_SCHEDULED" },
        .{ .key = "secretId", .value = "projects/82150720798/secrets/zigps-smf-54e2ea98-evd" },
        .{ .key = "timestamp", .value = "2026-10-02T06:03:41.140807-07:00" },
        .{ .key = "versionId", .value = "projects/82150720798/secrets/zigps-smf-54e2ea98-evd/versions/1" },
    },
    .data =
    \\{"createTime":"2026-10-02T13:03:39.696999Z","etag":"\"165cdb2952ab47\"","name":"projects/82150720798/secrets/zigps-smf-54e2ea98-evd/versions/1","replicationStatus":{"automatic":{}},"scheduledDestroyTime":"2026-10-03T13:03:41.104347702Z","state":"DISABLED"}
    ,
};

const destroyed: Message = .{
    .attributes = &.{
        .{ .key = "dataFormat", .value = "JSON_API_V1" },
        .{ .key = "eventType", .value = "SECRET_VERSION_DESTROY" },
        .{ .key = "secretId", .value = "projects/82150720798/secrets/zigps-smf-54e2ea98-ev" },
        .{ .key = "timestamp", .value = "2026-10-02T06:03:33.65825-07:00" },
        .{ .key = "versionId", .value = "projects/82150720798/secrets/zigps-smf-54e2ea98-ev/versions/1" },
    },
    .data =
    \\{"createTime":"2026-10-02T13:03:28.891929Z","destroyTime":"2026-10-02T13:03:33.630736902Z","etag":"\"165cdb28e07e8a\"","name":"projects/82150720798/secrets/zigps-smf-54e2ea98-ev/versions/1","replicationStatus":{"automatic":{}},"state":"DESTROYED"}
    ,
};

const rotate_periodic: Message = .{
    .attributes = &.{
        .{ .key = "dataFormat", .value = "JSON_API_V1" },
        .{ .key = "eventType", .value = "SECRET_ROTATE" },
        .{ .key = "secretId", .value = "projects/82150720798/secrets/zigps-smf-54e2ea98-rp" },
        .{ .key = "timestamp", .value = "2026-10-02T06:11:21.055625-07:00" },
    },
    .data =
    \\{"createTime":"2026-10-02T13:05:21.072187Z","etag":"\"165cdb44bc6989\"","labels":{"zig-gcp-test":"1","zigps-run":"54e2ea98"},"name":"projects/82150720798/secrets/zigps-smf-54e2ea98-rp","replication":{"automatic":{}},"rotation":{"nextRotationTime":"2026-10-02T14:11:20.929450Z","rotationPeriod":"3600s"},"topics":[{"name":"projects/extractctl/topics/zigps-smf-54e2ea98-t1"}]}
    ,
};

const regional_add: Message = .{
    .attributes = &.{
        .{ .key = "dataFormat", .value = "JSON_API_V1" },
        .{ .key = "eventType", .value = "SECRET_VERSION_ADD" },
        .{ .key = "secretId", .value = "projects/82150720798/locations/us-central1/secrets/zigps-smf-54e2ea98-evr" },
        .{ .key = "timestamp", .value = "2026-10-02T06:03:43.549786-07:00" },
        .{ .key = "versionId", .value = "projects/82150720798/locations/us-central1/secrets/zigps-smf-54e2ea98-evr/versions/1" },
    },
    .data =
    \\{"createTime":"2026-10-02T13:03:43.549786Z","etag":"\"165cdb29776d5a\"","name":"projects/82150720798/locations/us-central1/secrets/zigps-smf-54e2ea98-evr/versions/1","state":"ENABLED"}
    ,
};

test "decode: every kind production sent, as it sent it" {
    {
        var e = try decodeEvent(testing.allocator, topic_configured, .{});
        defer e.deinit();
        try testing.expectEqual(.topic_configured, e.value.kind);
        try testing.expectEqualStrings("", e.value.secret);
        try testing.expectEqual(null, e.value.info);
    }
    {
        var e = try decodeEvent(testing.allocator, global_create, .{});
        defer e.deinit();
        try testing.expectEqual(.secret_create, e.value.kind);
        try testing.expectEqualStrings("zigps-smf-54e2ea98-b15top", e.value.secretId());
        try testing.expectEqual(null, e.value.location);
        try testing.expectEqual(null, e.value.version);
        try testing.expectEqualStrings("2026-10-02T06:02:50.882009-07:00", e.value.time);
        try testing.expectEqualStrings("projects/extractctl/topics/zigps-smf-54e2ea98-t1", e.value.info.?.topics[0]);
        try testing.expectEqualStrings(
            "SECRET_CREATE projects/82150720798/secrets/zigps-smf-54e2ea98-b15top 2026-10-02T06:02:50.882009-07:00",
            e.value.key,
        );
        // The time is the change's, in Pacific time: 13:02:50 UTC.
        const t = try core.timestamp.parse(e.value.time);
        try testing.expectEqual(try core.timestamp.parse("2026-10-02T13:02:50.882009Z"), t);
    }
    {
        var e = try decodeEvent(testing.allocator, expired, .{});
        defer e.deinit();
        try testing.expectEqual(.secret_delete, e.value.kind);
        try testing.expectEqual(.expiration, e.value.delete_type.?);
        try testing.expectEqualStrings("2026-10-02T13:05:12.795840164Z", e.value.info.?.expire_time);
    }
    {
        var e = try decodeEvent(testing.allocator, destroy_scheduled, .{});
        defer e.deinit();
        try testing.expectEqual(.version_destroy_scheduled, e.value.kind);
        try testing.expectEqual(1, e.value.version.?);
        try testing.expectEqual(.disabled, e.value.version_info.?.state);
        try testing.expectEqualStrings("2026-10-03T13:03:41.104347702Z", e.value.version_info.?.scheduled_destroy_time);
        try testing.expectEqual(null, e.value.info);
    }
    {
        var e = try decodeEvent(testing.allocator, destroyed, .{});
        defer e.deinit();
        try testing.expectEqual(.version_destroy, e.value.kind);
        // Five fraction digits, as sent: production drops trailing zeros.
        try testing.expectEqualStrings("2026-10-02T06:03:33.65825-07:00", e.value.time);
        try testing.expectEqual(.destroyed, e.value.version_info.?.state);
        try testing.expect(std.mem.endsWith(u8, e.value.key, "/versions/1 2026-10-02T06:03:33.65825-07:00"));
    }
    {
        var e = try decodeEvent(testing.allocator, rotate_periodic, .{});
        defer e.deinit();
        try testing.expectEqual(.secret_rotate, e.value.kind);
        // The next rotation, already advanced by the period.
        try testing.expectEqualStrings("2026-10-02T14:11:20.929450Z", e.value.info.?.rotation.?.next_time);
        try testing.expectEqual(3600, e.value.info.?.rotation.?.period_s.?);
    }
    {
        var e = try decodeEvent(testing.allocator, regional_add, .{});
        defer e.deinit();
        try testing.expectEqual(.version_add, e.value.kind);
        try testing.expectEqualStrings("us-central1", e.value.location.?);
        try testing.expectEqualStrings("zigps-smf-54e2ea98-evr", e.value.secretId());
        try testing.expectEqual(1, e.value.version.?);
    }
}

test "decode: what is no Secret Manager event, and what is merely new" {
    var diag: core.Diagnostics = .{};
    const Case = struct { Message, []const u8 };
    const name = "projects/1/secrets/db";
    for ([_]Case{
        .{ .{ .attributes = &.{} }, "no eventType" },
        .{ .{ .attributes = &.{ .{ .key = "eventType", .value = "SECRET_CREATE" }, .{ .key = "timestamp", .value = "2026-10-02T06:00:00-07:00" } } }, "no secretId" },
        .{ .{ .attributes = &.{ .{ .key = "eventType", .value = "SECRET_CREATE" }, .{ .key = "secretId", .value = name } } }, "no timestamp" },
        .{ .{ .attributes = &.{ .{ .key = "eventType", .value = "SECRET_CREATE" }, .{ .key = "secretId", .value = name }, .{ .key = "timestamp", .value = "yesterday" } } }, "RFC 3339" },
        .{ .{ .attributes = &.{ .{ .key = "eventType", .value = "SECRET_CREATE" }, .{ .key = "secretId", .value = "db" }, .{ .key = "timestamp", .value = "2026-10-02T06:00:00-07:00" } } }, "not a secret's name" },
        .{ .{ .attributes = &.{ .{ .key = "eventType", .value = "SECRET_CREATE" }, .{ .key = "secretId", .value = "projects/1/secrets/db/versions/1" }, .{ .key = "timestamp", .value = "2026-10-02T06:00:00-07:00" } } }, "not a secret's name" },
        .{ .{ .attributes = &.{ .{ .key = "eventType", .value = "SECRET_VERSION_ADD" }, .{ .key = "secretId", .value = name }, .{ .key = "timestamp", .value = "2026-10-02T06:00:00-07:00" } } }, "no versionId" },
        .{ .{ .attributes = &.{ .{ .key = "eventType", .value = "SECRET_VERSION_ADD" }, .{ .key = "secretId", .value = name }, .{ .key = "timestamp", .value = "2026-10-02T06:00:00-07:00" }, .{ .key = "versionId", .value = "projects/1/secrets/other/versions/1" } } }, "names no version" },
        .{ .{ .attributes = &.{ .{ .key = "eventType", .value = "SECRET_CREATE" }, .{ .key = "secretId", .value = name }, .{ .key = "timestamp", .value = "2026-10-02T06:00:00-07:00" }, .{ .key = "dataFormat", .value = "JSON_API_V1" } }, .data = "{\"name\":\"projects/1/secrets/other\"}" }, "another secret" },
        .{ .{ .attributes = &.{ .{ .key = "eventType", .value = "SECRET_CREATE" }, .{ .key = "secretId", .value = name }, .{ .key = "timestamp", .value = "2026-10-02T06:00:00-07:00" }, .{ .key = "dataFormat", .value = "JSON_API_V1" } }, .data = "[1]" }, "not the secret" },
    }) |case| {
        try testing.expectError(error.NotASecretEvent, decodeEvent(testing.allocator, case[0], .{ .diagnostics = &diag }));
        if (std.mem.indexOf(u8, diag.message(), case[1]) == null) {
            std.debug.print("diagnostics \"{s}\" lack \"{s}\"\n", .{ diag.message(), case[1] });
            return error.TestUnexpectedDiagnostics;
        }
    }
    // A kind or a format this library does not know is kept, not refused.
    var later = try decodeEvent(testing.allocator, Message{ .attributes = &.{.{ .key = "eventType", .value = "SECRET_TAG_ADD" }} }, .{});
    defer later.deinit();
    try testing.expectEqual(.unknown, later.value.kind);
    try testing.expectEqualStrings("SECRET_TAG_ADD", later.value.event_type);
    var other_format = try decodeEvent(testing.allocator, Message{
        .attributes = &.{ .{ .key = "eventType", .value = "SECRET_CREATE" }, .{ .key = "secretId", .value = name }, .{ .key = "timestamp", .value = "2026-10-02T06:00:00-07:00" }, .{ .key = "dataFormat", .value = "PROTOBUF" } },
        .data = "\x08\x01",
    }, .{});
    defer other_format.deinit();
    try testing.expectEqual(null, other_format.value.info);
    // A delete without its type says it is unknown, not requested.
    var untyped = try decodeEvent(testing.allocator, Message{
        .attributes = &.{ .{ .key = "eventType", .value = "SECRET_DELETE" }, .{ .key = "secretId", .value = name }, .{ .key = "timestamp", .value = "2026-10-02T06:00:00-07:00" }, .{ .key = "deleteType", .value = "PURGED" } },
    }, .{});
    defer untyped.deinit();
    try testing.expectEqual(.unknown, untyped.value.delete_type.?);
}

test "decode: the event outlives the message, and every allocation failure is clean" {
    var copy = try testing.allocator.dupe(u8, global_create.data);
    var event = try decodeEvent(testing.allocator, Message{ .attributes = global_create.attributes, .data = copy }, .{});
    @memset(copy, 'x');
    testing.allocator.free(copy);
    copy = undefined;
    defer event.deinit();
    try testing.expectEqualStrings("zigps-smf-54e2ea98-b15top", event.value.info.?.id());

    const Run = struct {
        fn run(gpa: Allocator) !void {
            inline for (.{ global_create, destroy_scheduled, rotate_periodic, regional_add, topic_configured }) |m| {
                var e = try decodeEvent(gpa, m, .{});
                e.deinit();
            }
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Run.run, .{});
}

fn decodeProperty(_: void, input: []const u8) !void {
    var g: test_util.ByteGen = .init(input);
    const event_types = [_][]const u8{ "SECRET_CREATE", "SECRET_VERSION_ADD", "SECRET_DELETE", "TOPIC_CONFIGURED", "X" };
    const secrets = [_][]const u8{ "projects/1/secrets/db", "projects/1/locations/us-central1/secrets/db", "db", "" };
    var attributes: [6]types.Label = undefined;
    var n: usize = 0;
    const names_ = [_][]const u8{ "eventType", "secretId", "versionId", "timestamp", "dataFormat", "deleteType" };
    for (names_) |attr| {
        if (!g.boolean()) continue;
        const value: []const u8 = switch (attr[0]) {
            'e' => event_types[g.intRange(u8, 0, event_types.len - 1)],
            's' => secrets[g.intRange(u8, 0, secrets.len - 1)],
            'v' => if (g.boolean()) "projects/1/secrets/db/versions/2" else g.slice(40),
            't' => if (g.boolean()) "2026-10-02T06:03:33.65825-07:00" else g.slice(30),
            'd' => if (attr[1] == 'a') "JSON_API_V1" else "REQUESTED",
            else => unreachable,
        };
        attributes[n] = .{ .key = attr, .value = value };
        n += 1;
    }
    const data = g.slice(256);
    var diag: core.Diagnostics = .{};
    var e = decodeEvent(testing.allocator, Message{ .attributes = attributes[0..n], .data = data }, .{ .diagnostics = &diag }) catch |err| switch (err) {
        error.NotASecretEvent => {
            try testing.expect(diag.message().len > 0);
            return;
        },
        else => return err,
    };
    defer e.deinit();
    // What decoded is consistent with itself.
    if (e.value.version) |v| try testing.expect(v > 0);
    if (e.value.info) |info| try testing.expectEqualStrings(e.value.secret, info.name);
    if (e.value.version_info) |info| try testing.expect(std.mem.startsWith(u8, info.name, e.value.secret));
    if (e.value.time.len > 0) _ = try core.timestamp.parse(e.value.time);
    try testing.expect(std.mem.startsWith(u8, e.value.key, e.value.event_type));
}

test "fuzz decodeEvent: any message decodes consistently or is refused with a reason" {
    try test_util.fuzzBytes({}, decodeProperty, .{ .corpus = &.{
        "",
        "\x01\x00\x01\x00\x00\x01\x01\x01\x01\x01",
        "\x01\x01\x01\x00\x01\x01\x01\x01\x01\x01\x01\x01\x01{\"name\":\"projects/1/secrets/db\"}",
    } });
}
