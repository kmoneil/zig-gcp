//! JSON and base64: request bodies out, response bodies in.
//!
//! Zig field names are snake_case and the wire uses the API's camelCase. The
//! private `Wire*` structs mirror the wire exactly and never leave this file.
//! Every response field is optional, `null` counts as absent (the proto3 JSON
//! rule), and unknown fields are ignored, so new server fields never break
//! old clients.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Stringify = std.json.Stringify;
const Writer = std.Io.Writer;
const core = @import("core");
const types = @import("types.zig");
const test_util = @import("test_util.zig");

pub const DecodeError = error{ InvalidResponse, OutOfMemory };

// Requests

/// The `secrets.addVersion` body. The checksum is computed over the raw
/// bytes, before base64, and travels as a decimal string beside them.
pub fn encodeAddVersion(arena: Allocator, data: []const u8, checksum: u32) Allocator.Error![]u8 {
    var out: Writer.Allocating = .init(arena);
    var jw: Stringify = .{ .writer = &out.writer };
    writeAddVersion(&jw, data, checksum) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn writeAddVersion(jw: *Stringify, data: []const u8, checksum: u32) Stringify.Error!void {
    try jw.beginObject();
    try jw.objectField("payload");
    try jw.beginObject();
    try jw.objectField("data");
    // Streamed, so the secret is never copied on its way to base64.
    try core.base64.writeJsonString(jw, data);
    try jw.objectField("dataCrc32c");
    var buf: [10]u8 = undefined;
    try jw.write(std.fmt.bufPrint(&buf, "{d}", .{checksum}) catch unreachable);
    try jw.endObject();
    try jw.endObject();
}

/// The `secrets.create` body. A global secret must name its replication and
/// a regional one must not: production refuses each the other way round,
/// with "Secret must be provided." and "Secret.replication should not be
/// provided."
pub fn encodeSecret(arena: Allocator, config: types.SecretConfig, regional: bool) Allocator.Error![]u8 {
    var out: Writer.Allocating = .init(arena);
    var jw: Stringify = .{ .writer = &out.writer };
    writeSecret(&jw, config, regional) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn writeSecret(jw: *Stringify, config: types.SecretConfig, regional: bool) Stringify.Error!void {
    try jw.beginObject();
    if (!regional) {
        try jw.objectField("replication");
        try jw.beginObject();
        switch (config.replication) {
            .automatic => {
                try jw.objectField("automatic");
                try jw.beginObject();
                try jw.endObject();
            },
            .user_managed => |locations| {
                try jw.objectField("userManaged");
                try jw.beginObject();
                try jw.objectField("replicas");
                try jw.beginArray();
                for (locations) |location| {
                    try jw.beginObject();
                    try jw.objectField("location");
                    try jw.write(location);
                    try jw.endObject();
                }
                try jw.endArray();
                try jw.endObject();
            },
        }
        try jw.endObject();
    }
    if (config.labels.len > 0) try writeLabels(jw, config.labels);
    if (config.annotations.len > 0) try writeAnnotations(jw, config.annotations);
    if (config.expiry) |expiry| try writeExpiry(jw, expiry);
    if (config.version_destroy_delay_s) |s| try writeSeconds(jw, "versionDestroyTtl", s);
    try jw.endObject();
}

fn writeLabels(jw: *Stringify, labels: []const types.Label) Stringify.Error!void {
    try jw.objectField("labels");
    try jw.beginObject();
    for (labels) |label| {
        try jw.objectField(label.key);
        try jw.write(label.value);
    }
    try jw.endObject();
}

fn writeAnnotations(jw: *Stringify, annotations: []const types.Annotation) Stringify.Error!void {
    try jw.objectField("annotations");
    try jw.beginObject();
    for (annotations) |a| {
        try jw.objectField(a.key);
        try jw.write(a.value);
    }
    try jw.endObject();
}

/// Aliases map to version numbers, which proto3 JSON writes as strings,
/// as production answers them.
fn writeAliases(jw: *Stringify, aliases: []const types.Alias) Stringify.Error!void {
    try jw.objectField("versionAliases");
    try jw.beginObject();
    for (aliases) |a| {
        try jw.objectField(a.name);
        var buf: [20]u8 = undefined;
        try jw.write(std.fmt.bufPrint(&buf, "{d}", .{a.version}) catch unreachable);
    }
    try jw.endObject();
}

fn writeExpiry(jw: *Stringify, expiry: types.Expiry) Stringify.Error!void {
    switch (expiry) {
        .at => |time| {
            try jw.objectField("expireTime");
            try jw.write(time);
        },
        .after_s => |s| try writeSeconds(jw, "ttl", s),
    }
}

/// A duration of whole seconds, as proto3 JSON writes one: `86400s`.
fn writeSeconds(jw: *Stringify, field: []const u8, seconds: u64) Stringify.Error!void {
    try jw.objectField(field);
    var buf: [24]u8 = undefined;
    try jw.write(std.fmt.bufPrint(&buf, "{d}s", .{seconds}) catch unreachable);
}

/// The `secrets.patch` body: each field the update sets, and the etag. A
/// field it clears is left out, which with its path in the mask is how
/// production clears it.
pub fn encodeUpdate(arena: Allocator, changes: types.SecretUpdate) Allocator.Error![]u8 {
    var out: Writer.Allocating = .init(arena);
    var jw: Stringify = .{ .writer = &out.writer };
    writeUpdate(&jw, changes) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn writeUpdate(jw: *Stringify, changes: types.SecretUpdate) Stringify.Error!void {
    try jw.beginObject();
    switch (changes.labels) {
        .set => |labels| try writeLabels(jw, labels),
        .keep, .clear => {},
    }
    switch (changes.annotations) {
        .set => |annotations| try writeAnnotations(jw, annotations),
        .keep, .clear => {},
    }
    switch (changes.aliases) {
        .set => |aliases| try writeAliases(jw, aliases),
        .keep, .clear => {},
    }
    switch (changes.expiry) {
        .set => |expiry| try writeExpiry(jw, expiry),
        .keep, .clear => {},
    }
    switch (changes.version_destroy_delay_s) {
        .set => |s| try writeSeconds(jw, "versionDestroyTtl", s),
        .keep, .clear => {},
    }
    if (changes.etag) |etag| {
        try jw.objectField("etag");
        try jw.write(etag);
    }
    try jw.endObject();
}

/// The `updateMask` for `changes`: a path for every field it sets or
/// clears, in snake_case as gcloud sends them. Production takes either
/// case. An expiry set as a duration is `ttl`; one set as a time, or
/// cleared, is `expire_time`, which clears it however it was set.
pub fn updateMask(arena: Allocator, changes: types.SecretUpdate) Allocator.Error![]u8 {
    var out: Writer.Allocating = .init(arena);
    writeMask(&out.writer, changes) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn writeMask(w: *Writer, changes: types.SecretUpdate) Writer.Error!void {
    var first = true;
    const paths = [_]struct { bool, []const u8 }{
        .{ changes.labels != .keep, "labels" },
        .{ changes.annotations != .keep, "annotations" },
        .{ changes.aliases != .keep, "version_aliases" },
        .{ changes.expiry != .keep, switch (changes.expiry) {
            .set => |e| if (e == .after_s) "ttl" else "expire_time",
            .keep, .clear => "expire_time",
        } },
        .{ changes.version_destroy_delay_s != .keep, "version_destroy_ttl" },
    };
    for (paths) |entry| {
        if (!entry[0]) continue;
        if (!first) try w.writeByte(',');
        try w.writeAll(entry[1]);
        first = false;
    }
}

/// The body of a version's enable, disable or destroy: `{}`, or the etag
/// the change is conditional on.
pub fn encodeEtag(arena: Allocator, etag: ?[]const u8) Allocator.Error![]u8 {
    const e = etag orelse return arena.dupe(u8, "{}");
    return Stringify.valueAlloc(arena, .{ .etag = e }, .{});
}

/// How long `encodeAddVersion` will be, so its buffer is allocated once and
/// never grown, copied and freed with the secret inside it.
pub fn addVersionBodyLen(data: []const u8, checksum: u32) usize {
    var digits: usize = 1;
    var rest = checksum;
    while (rest >= 10) : (rest /= 10) digits += 1;
    return "{\"payload\":{\"data\":\"\",\"dataCrc32c\":\"\"}}".len +
        core.base64.encodedLen(data.len) + digits;
}

const parse_options: std.json.ParseOptions = .{
    .ignore_unknown_fields = true,
    // Proto3 JSON parsers keep the last duplicate rather than failing.
    .duplicate_field_behavior = .use_last,
    .allocate = .alloc_if_needed,
};

/// What `versions.access` answered: the version that served the request, its
/// bytes still in base64, and the checksum stored beside them.
pub const Access = struct {
    /// The resolved version name, which says which number answered `latest`.
    name: []const u8,
    /// Base64, pointing into the response body.
    data: []const u8,
    /// Null when the version has no checksum at all.
    checksum: ?u32,
};

pub fn decodeAccess(arena: Allocator, body: []const u8) DecodeError!Access {
    const wire = try parseWire(WireAccess, arena, body);
    const payload = wire.payload orelse WirePayload{};
    return .{
        .name = wire.name orelse "",
        .data = payload.data orelse "",
        .checksum = try parseChecksum(payload.dataCrc32c),
    };
}

const WireAccess = struct {
    name: ?[]const u8 = null,
    payload: ?WirePayload = null,
};

const WirePayload = struct {
    data: ?[]const u8 = null,
    dataCrc32c: ?std.json.Value = null,
};

/// `dataCrc32c` is an int64 field, which proto3 JSON writes as a decimal
/// string; a number is accepted too, since the mapping allows it. A value
/// that is not a CRC-32C is a broken response, not a missing checksum:
/// treating it as missing would quietly skip the verification the caller
/// asked for.
fn parseChecksum(value: ?std.json.Value) DecodeError!?u32 {
    const v = value orelse return null;
    const wide: i65 = switch (v) {
        .null => return null,
        .integer => |n| n,
        .string, .number_string => |text| std.fmt.parseInt(i65, text, 10) catch return error.InvalidResponse,
        .float => return error.InvalidResponse,
        else => return error.InvalidResponse,
    };
    if (wide < 0 or wide > std.math.maxInt(u32)) return error.InvalidResponse;
    return @intCast(wide);
}

/// The `Secret` that create and get return.
pub fn decodeSecret(arena: Allocator, body: []const u8) DecodeError!types.SecretInfo {
    return secretFromWire(arena, try parseWire(WireSecret, arena, body));
}

/// One page of `secrets.list`.
pub fn decodeSecretPage(arena: Allocator, body: []const u8) DecodeError!types.SecretPage {
    const wire = try parseWire(WireSecretPage, arena, body);
    const listed = wire.secrets orelse &.{};
    const out = try arena.alloc(types.SecretInfo, listed.len);
    for (listed, out) |w, *info| info.* = try secretFromWire(arena, w);
    return .{
        .secrets = out,
        .next_page_token = nonEmpty(wire.nextPageToken),
        .total_size = count(wire.totalSize),
    };
}

const WireSecret = struct {
    name: ?[]const u8 = null,
    createTime: ?[]const u8 = null,
    etag: ?[]const u8 = null,
    labels: ?std.json.ArrayHashMap(?[]const u8) = null,
    annotations: ?std.json.ArrayHashMap(?[]const u8) = null,
    versionAliases: ?std.json.ArrayHashMap(std.json.Value) = null,
    expireTime: ?[]const u8 = null,
    versionDestroyTtl: ?[]const u8 = null,
};

const WireSecretPage = struct {
    secrets: ?[]const WireSecret = null,
    nextPageToken: ?[]const u8 = null,
    totalSize: ?i64 = null,
};

fn secretFromWire(arena: Allocator, wire: WireSecret) DecodeError!types.SecretInfo {
    return .{
        .name = wire.name orelse "",
        .create_time = wire.createTime orelse "",
        .etag = wire.etag orelse "",
        .labels = try pairsFromWire(types.Label, arena, wire.labels),
        .annotations = try pairsFromWire(types.Annotation, arena, wire.annotations),
        .aliases = try aliasesFromWire(arena, wire.versionAliases),
        .expire_time = wire.expireTime orelse "",
        .version_destroy_delay_s = try wholeSeconds(wire.versionDestroyTtl),
    };
}

/// Version numbers arrive as strings, as proto3 JSON writes an int64, or
/// as numbers, which the mapping also allows. One that is neither names
/// no version, and a secret read wrong could send `access` astray, so it
/// is a broken response.
fn aliasesFromWire(
    arena: Allocator,
    wire: ?std.json.ArrayHashMap(std.json.Value),
) DecodeError![]const types.Alias {
    const map = (wire orelse return &.{}).map;
    const out = try arena.alloc(types.Alias, map.count());
    for (map.keys(), map.values(), out) |name, value, *alias| {
        const version: u64 = switch (value) {
            .integer => |n| std.math.cast(u64, n) orelse return error.InvalidResponse,
            .string, .number_string => |text| std.fmt.parseInt(u64, text, 10) catch return error.InvalidResponse,
            else => return error.InvalidResponse,
        };
        alias.* = .{ .name = name, .version = version };
    }
    return out;
}

/// A duration such as `86400s` or `86400.500s`, in whole seconds.
fn wholeSeconds(text: ?[]const u8) DecodeError!?u64 {
    const t = text orelse return null;
    const d = core.duration.parse(t) catch return error.InvalidResponse;
    if (d.nanoseconds < 0) return error.InvalidResponse;
    return @intCast(@divFloor(d.nanoseconds, std.time.ns_per_s));
}

/// Labels and annotations: a map of strings on the wire, a list of
/// `key`-`value` pairs here, in the server's order.
fn pairsFromWire(
    comptime T: type,
    arena: Allocator,
    wire: ?std.json.ArrayHashMap(?[]const u8),
) Allocator.Error![]const T {
    const map = (wire orelse return &.{}).map;
    const out = try arena.alloc(T, map.count());
    for (map.keys(), map.values(), out) |k, v, *pair| pair.* = .{ .key = k, .value = v orelse "" };
    return out;
}

/// A count the server sends as a JSON number. Anything that is not a plain
/// count reads as none, which is also what an omitted `totalSize` means: it
/// is a hint for paging, never something to act on.
fn count(value: ?i64) u32 {
    const n = value orelse return 0;
    if (n < 0 or n > std.math.maxInt(u32)) return 0;
    return @intCast(n);
}

fn nonEmpty(text: ?[]const u8) ?[]const u8 {
    const t = text orelse return null;
    return if (t.len == 0) null else t;
}

/// One page of `versions.list`.
pub fn decodeVersionPage(arena: Allocator, body: []const u8) DecodeError!types.VersionPage {
    const wire = try parseWire(WireVersionPage, arena, body);
    const listed = wire.versions orelse &.{};
    const out = try arena.alloc(types.VersionInfo, listed.len);
    for (listed, out) |w, *info| info.* = versionFromWire(w);
    return .{
        .versions = out,
        .next_page_token = nonEmpty(wire.nextPageToken),
        .total_size = count(wire.totalSize),
    };
}

const WireVersionPage = struct {
    versions: ?[]const WireVersion = null,
    nextPageToken: ?[]const u8 = null,
    totalSize: ?i64 = null,
};

/// The `SecretVersion` that add, get, enable, disable and destroy return.
pub fn decodeVersion(arena: Allocator, body: []const u8) DecodeError!types.VersionInfo {
    return versionFromWire(try parseWire(WireVersion, arena, body));
}

const WireVersion = struct {
    name: ?[]const u8 = null,
    createTime: ?[]const u8 = null,
    destroyTime: ?[]const u8 = null,
    scheduledDestroyTime: ?[]const u8 = null,
    state: ?[]const u8 = null,
    etag: ?[]const u8 = null,
    clientSpecifiedPayloadChecksum: ?bool = null,
};

fn versionFromWire(wire: WireVersion) types.VersionInfo {
    return .{
        .name = wire.name orelse "",
        .create_time = wire.createTime orelse "",
        .destroy_time = wire.destroyTime orelse "",
        .scheduled_destroy_time = wire.scheduledDestroyTime orelse "",
        .state = state(wire.state),
        .etag = wire.etag orelse "",
        .client_specified_payload_checksum = wire.clientSpecifiedPayloadChecksum orelse false,
    };
}

const states = std.StaticStringMap(types.State).initComptime(.{
    .{ "ENABLED", types.State.enabled },
    .{ "DISABLED", types.State.disabled },
    .{ "DESTROYED", types.State.destroyed },
});

/// A state the server has not used before maps to `.unknown` rather than
/// failing, so a new one never breaks an old client.
fn state(text: ?[]const u8) types.State {
    return states.get(text orelse return .unknown) orelse .unknown;
}

/// Parses `body` into `T`. A blank body counts as `{}`.
fn parseWire(comptime T: type, arena: Allocator, body: []const u8) DecodeError!T {
    const trimmed = std.mem.trim(u8, body, " \t\r\n");
    const text = if (trimmed.len == 0) "{}" else trimmed;
    return std.json.parseFromSliceLeaky(T, arena, text, parse_options) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidResponse,
    };
}

const testing = std.testing;

test "golden: the addVersion body production accepts" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings(
        "{\"payload\":{\"data\":\"czNjcjN0\",\"dataCrc32c\":\"825573743\"}}",
        try encodeAddVersion(a, "s3cr3t", core.crc32c.hash("s3cr3t")),
    );
    // Bytes that are not text, and a checksum of a single digit.
    try testing.expectEqualStrings(
        "{\"payload\":{\"data\":\"AAECA/8=\",\"dataCrc32c\":\"0\"}}",
        try encodeAddVersion(a, "\x00\x01\x02\x03\xff", 0),
    );
    // The largest checksum takes ten digits.
    try testing.expectEqualStrings(
        "{\"payload\":{\"data\":\"aGk=\",\"dataCrc32c\":\"4294967295\"}}",
        try encodeAddVersion(a, "hi", std.math.maxInt(u32)),
    );
}

test "golden: the create body, global and regional" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const labels: []const types.Label = &.{
        .{ .key = "zig-gcp-test", .value = "1" },
        .{ .key = "team", .value = "payments" },
    };

    try testing.expectEqualStrings("{\"replication\":{\"automatic\":{}}}", try encodeSecret(a, .{}, false));
    try testing.expectEqualStrings(
        "{\"replication\":{\"automatic\":{}},\"labels\":{\"zig-gcp-test\":\"1\",\"team\":\"payments\"}}",
        try encodeSecret(a, .{ .labels = labels }, false),
    );
    try testing.expectEqualStrings(
        "{\"replication\":{\"userManaged\":{\"replicas\":[{\"location\":\"europe-west1\"},{\"location\":\"us-east1\"}]}}}",
        try encodeSecret(a, .{ .replication = .{ .user_managed = &.{ "europe-west1", "us-east1" } } }, false),
    );
    // A regional secret sends no replication: the location in the path
    // decides, and production refuses the field outright.
    try testing.expectEqualStrings("{}", try encodeSecret(a, .{}, true));
    try testing.expectEqualStrings(
        "{\"labels\":{\"zig-gcp-test\":\"1\",\"team\":\"payments\"}}",
        try encodeSecret(a, .{ .labels = labels, .replication = .{ .user_managed = &.{"ignored"} } }, true),
    );
}

test "decode secret: the shape production sends" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const got = try decodeSecret(arena.allocator(),
        \\{"name":"projects/82150720798/secrets/db-password",
        \\ "replication":{"automatic":{}},
        \\ "createTime":"2026-09-20T23:10:15.057958Z",
        \\ "labels":{"zig-gcp-test":"1","team":"payments"},
        \\ "etag":"\"165bf23c7b1c62\""}
    );
    try testing.expectEqualStrings("projects/82150720798/secrets/db-password", got.name);
    try testing.expectEqualStrings("db-password", got.id());
    try testing.expectEqualStrings("2026-09-20T23:10:15.057958Z", got.create_time);
    try testing.expectEqualStrings("\"165bf23c7b1c62\"", got.etag);
    try testing.expectEqual(2, got.labels.len);
    try testing.expectEqualStrings("1", got.label("zig-gcp-test").?);
    try testing.expectEqualStrings("payments", got.label("team").?);
    try testing.expectEqual(null, got.label("missing"));

    // A secret with no labels at all, as production sends it.
    const bare = try decodeSecret(arena.allocator(), "{\"name\":\"projects/1/secrets/db\"}");
    try testing.expectEqual(0, bare.labels.len);
    try testing.expectEqualStrings("", bare.etag);
}

test "golden: the create body with every setting milestone 1 adds" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings(
        "{\"replication\":{\"automatic\":{}},\"labels\":{\"team\":\"payments\"},\"annotations\":{\"owner\":\"Ann <ann@example.com>\",\"note\":\"line\\nbreak\"},\"ttl\":\"3600s\",\"versionDestroyTtl\":\"86400s\"}",
        try encodeSecret(a, .{
            .labels = &.{.{ .key = "team", .value = "payments" }},
            .annotations = &.{ .{ .key = "owner", .value = "Ann <ann@example.com>" }, .{ .key = "note", .value = "line\nbreak" } },
            .expiry = .{ .after_s = 3600 },
            .version_destroy_delay_s = 86_400,
        }, false),
    );
    try testing.expectEqualStrings(
        "{\"expireTime\":\"2027-01-01T00:00:00Z\"}",
        try encodeSecret(a, .{ .expiry = .{ .at = "2027-01-01T00:00:00Z" } }, true),
    );
}

test "golden: update bodies and masks, one field at a time and all at once" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Case = struct { types.SecretUpdate, []const u8, []const u8 };
    const cases = [_]Case{
        .{ .{ .labels = .{ .set = &.{.{ .key = "team", .value = "payments" }} } }, "labels", "{\"labels\":{\"team\":\"payments\"}}" },
        .{ .{ .labels = .clear }, "labels", "{}" },
        .{ .{ .labels = .{ .set = &.{} } }, "labels", "{\"labels\":{}}" },
        .{ .{ .annotations = .{ .set = &.{.{ .key = "k", .value = "v" }} } }, "annotations", "{\"annotations\":{\"k\":\"v\"}}" },
        .{ .{ .annotations = .clear }, "annotations", "{}" },
        .{ .{ .aliases = .{ .set = &.{ .{ .name = "prod", .version = 7 }, .{ .name = "Prod", .version = 18446744073709551615 } } } }, "version_aliases", "{\"versionAliases\":{\"prod\":\"7\",\"Prod\":\"18446744073709551615\"}}" },
        .{ .{ .aliases = .clear }, "version_aliases", "{}" },
        .{ .{ .expiry = .{ .set = .{ .at = "2027-01-01T00:00:00Z" } } }, "expire_time", "{\"expireTime\":\"2027-01-01T00:00:00Z\"}" },
        .{ .{ .expiry = .{ .set = .{ .after_s = 60 } } }, "ttl", "{\"ttl\":\"60s\"}" },
        // Production clears an expiry through expire_time however it was set.
        .{ .{ .expiry = .clear }, "expire_time", "{}" },
        .{ .{ .version_destroy_delay_s = .{ .set = 86_400_000 } }, "version_destroy_ttl", "{\"versionDestroyTtl\":\"86400000s\"}" },
        .{ .{ .version_destroy_delay_s = .clear }, "version_destroy_ttl", "{}" },
        .{ .{ .labels = .clear, .etag = "\"165cdb26b38bad\"" }, "labels", "{\"etag\":\"\\\"165cdb26b38bad\\\"\"}" },
        .{
            .{
                .labels = .{ .set = &.{.{ .key = "a", .value = "1" }} },
                .annotations = .clear,
                .aliases = .{ .set = &.{.{ .name = "prod", .version = 1 }} },
                .expiry = .{ .set = .{ .after_s = 86_400 } },
                .version_destroy_delay_s = .clear,
                .etag = "\"e\"",
            },
            "labels,annotations,version_aliases,ttl,version_destroy_ttl",
            "{\"labels\":{\"a\":\"1\"},\"versionAliases\":{\"prod\":\"1\"},\"ttl\":\"86400s\",\"etag\":\"\\\"e\\\"\"}",
        },
    };
    for (cases) |case| {
        try testing.expectEqualStrings(case[1], try updateMask(a, case[0]));
        try testing.expectEqualStrings(case[2], try encodeUpdate(a, case[0]));
        try testing.expect(!case[0].isEmpty());
    }
    const nothing: types.SecretUpdate = .{ .etag = "\"e\"" };
    try testing.expect(nothing.isEmpty());
    try testing.expectEqualStrings("", try updateMask(a, nothing));
}

test "golden: a version change's body, with and without an etag" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("{}", try encodeEtag(arena.allocator(), null));
    try testing.expectEqualStrings(
        "{\"etag\":\"\\\"165cdb272dd24f\\\"\"}",
        try encodeEtag(arena.allocator(), "\"165cdb272dd24f\""),
    );
}

test "decode secret: every field production sent on 2026-10-02" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const got = try decodeSecret(a,
        \\{"annotations":{"fk":"v"},"createTime":"2026-10-02T13:04:09.628841Z","etag":"\"165cdb2b1551bc\"",
        \\ "expireTime":"2026-10-04T13:04:09.503134Z","labels":{"zig-gcp-test":"1","zigps-run":"63c4814f"},
        \\ "name":"projects/82150720798/secrets/zigps-smf-63c4814f-f","replication":{"automatic":{}},
        \\ "versionAliases":{"prod":"1"},"versionDestroyTtl":"86400s"}
    );
    try testing.expectEqualStrings("v", got.annotation("fk").?);
    try testing.expectEqual(null, got.annotation("missing"));
    try testing.expectEqual(1, got.alias("prod").?);
    try testing.expectEqual(null, got.alias("Prod"));
    try testing.expectEqualStrings("2026-10-04T13:04:09.503134Z", got.expire_time);
    try testing.expectEqual(86_400, got.version_destroy_delay_s.?);
    try testing.expectEqualStrings("1", got.label("zig-gcp-test").?);

    // A fraction someone set is dropped; nothing set reads as null and "".
    const fraction = try decodeSecret(a, "{\"versionDestroyTtl\":\"86400.500s\"}");
    try testing.expectEqual(86_400, fraction.version_destroy_delay_s.?);
    const bare = try decodeSecret(a, "{\"name\":\"projects/1/secrets/db\"}");
    try testing.expectEqual(null, bare.version_destroy_delay_s);
    try testing.expectEqualStrings("", bare.expire_time);
    try testing.expectEqual(0, bare.annotations.len);
    try testing.expectEqual(0, bare.aliases.len);
    // A version number as a JSON number, as the mapping allows.
    try testing.expectEqual(7, (try decodeSecret(a, "{\"versionAliases\":{\"x\":7}}")).alias("x").?);
    // Aliases and durations that name nothing are a broken response.
    for ([_][]const u8{
        "{\"versionAliases\":{\"x\":\"seven\"}}",
        "{\"versionAliases\":{\"x\":-1}}",
        "{\"versionAliases\":{\"x\":true}}",
        "{\"versionAliases\":{\"x\":1.5}}",
        "{\"versionAliases\":[]}",
        "{\"versionDestroyTtl\":\"1 day\"}",
        "{\"versionDestroyTtl\":\"-1s\"}",
        "{\"versionDestroyTtl\":86400}",
        "{\"annotations\":{\"k\":1}}",
    }) |body| {
        try testing.expectError(error.InvalidResponse, decodeSecret(a, body));
    }
}

test "decode version: a destruction scheduled, as production sent it" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const got = try decodeVersion(arena.allocator(),
        \\{"createTime":"2026-10-02T13:04:00.785586Z","etag":"\"165cdb2aae0e82\"",
        \\ "name":"projects/82150720798/secrets/zigps-smf-63c4814f-dd/versions/1","replicationStatus":{"automatic":{}},
        \\ "scheduledDestroyTime":"2026-10-03T13:04:03.889502667Z","state":"DISABLED"}
    );
    try testing.expectEqual(.disabled, got.state);
    try testing.expectEqualStrings("2026-10-03T13:04:03.889502667Z", got.scheduled_destroy_time);
    try testing.expectEqualStrings("", got.destroy_time);
    try testing.expectEqualStrings("", (try decodeVersion(arena.allocator(), "{\"state\":\"ENABLED\"}")).scheduled_destroy_time);
}

test "decode secret page: tokens, counts and what is left out" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const page = try decodeSecretPage(a,
        \\{"secrets":[{"name":"projects/1/secrets/a"},{"name":"projects/1/secrets/b","labels":{"k":"v"}}],
        \\ "nextPageToken":"2Aeg8oI9ojTXZ","totalSize":2}
    );
    try testing.expectEqual(2, page.secrets.len);
    try testing.expectEqualStrings("a", page.secrets[0].id());
    try testing.expectEqualStrings("v", page.secrets[1].label("k").?);
    try testing.expectEqualStrings("2Aeg8oI9ojTXZ", page.next_page_token.?);
    try testing.expectEqual(2, page.total_size);

    // An empty project answers `{}`, and a filtered list sends no count.
    const empty = try decodeSecretPage(a, "{}");
    try testing.expectEqual(0, empty.secrets.len);
    try testing.expectEqual(null, empty.next_page_token);
    try testing.expectEqual(0, empty.total_size);
    // An empty token means the last page, as does a missing one.
    const last = try decodeSecretPage(a, "{\"secrets\":[],\"nextPageToken\":\"\"}");
    try testing.expectEqual(null, last.next_page_token);
    // A count that is not a plain one is a hint, never worth failing over.
    try testing.expectEqual(0, (try decodeSecretPage(a, "{\"totalSize\":-1}")).total_size);
    try testing.expectEqual(0, (try decodeSecretPage(a, "{\"totalSize\":99999999999}")).total_size);
    for ([_][]const u8{ "[]", "{\"secrets\":{}}", "{\"secrets\":[1]}" }) |body| {
        try testing.expectError(error.InvalidResponse, decodeSecretPage(a, body));
    }
}

test "decode version: the shape production sends" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const got = try decodeVersion(arena.allocator(),
        \\{"name":"projects/82150720798/secrets/db-password/versions/3",
        \\ "createTime":"2026-09-20T23:09:39.716394Z",
        \\ "state":"ENABLED",
        \\ "replicationStatus":{"automatic":{}},
        \\ "etag":"\"165bf23a79782f\"",
        \\ "clientSpecifiedPayloadChecksum":true}
    );
    try testing.expectEqualStrings("projects/82150720798/secrets/db-password/versions/3", got.name);
    try testing.expectEqualStrings("2026-09-20T23:09:39.716394Z", got.create_time);
    try testing.expectEqual(.enabled, got.state);
    try testing.expectEqualStrings("\"165bf23a79782f\"", got.etag);
    try testing.expect(got.client_specified_payload_checksum);
    try testing.expectEqualStrings("", got.destroy_time);
    try testing.expectEqual(3, got.number().?);
}

test "decode version: states, and what the server leaves out" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A destroyed version keeps its destroyTime, with nanosecond precision.
    const destroyed = try decodeVersion(a,
        \\{"name":"v/1","state":"DESTROYED","destroyTime":"2026-09-20T23:09:41.500615147Z"}
    );
    try testing.expectEqual(.destroyed, destroyed.state);
    try testing.expectEqualStrings("2026-09-20T23:09:41.500615147Z", destroyed.destroy_time);

    try testing.expectEqual(.disabled, (try decodeVersion(a, "{\"state\":\"DISABLED\"}")).state);
    // A state this client has never heard of is not an error.
    try testing.expectEqual(.unknown, (try decodeVersion(a, "{\"state\":\"SCHEDULED_FOR_DESTRUCTION\"}")).state);
    try testing.expectEqual(.unknown, (try decodeVersion(a, "{\"state\":\"enabled\"}")).state);
    try testing.expectEqual(.unknown, (try decodeVersion(a, "{}")).state);
    // proto3 JSON leaves out a false boolean, as production does for a
    // version whose checksum the server computed.
    try testing.expect(!(try decodeVersion(a, "{\"name\":\"v/2\"}")).client_specified_payload_checksum);
    for ([_][]const u8{ "[]", "<html>", "{\"state\":1}" }) |body| {
        try testing.expectError(error.InvalidResponse, decodeVersion(a, body));
    }
}

test "decode access: the shape production sends" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const got = try decodeAccess(arena.allocator(),
        \\{"name":"projects/82150720798/secrets/db-password/versions/3",
        \\ "payload":{"data":"czNjcjN0","dataCrc32c":"825573743"}}
    );
    try testing.expectEqualStrings("projects/82150720798/secrets/db-password/versions/3", got.name);
    try testing.expectEqualStrings("czNjcjN0", got.data);
    try testing.expectEqual(825_573_743, got.checksum.?);
    try testing.expectEqualStrings("s3cr3t", try core.base64.decode(arena.allocator(), got.data));
}

test "decode access: missing, null and unknown fields" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const empty = try decodeAccess(a, "{}");
    try testing.expectEqualStrings("", empty.name);
    try testing.expectEqualStrings("", empty.data);
    try testing.expectEqual(null, empty.checksum);

    const nulls = try decodeAccess(a, "{\"name\":null,\"payload\":{\"data\":null,\"dataCrc32c\":null}}");
    try testing.expectEqual(null, nulls.checksum);

    // A field the server adds later is ignored, not an error.
    const future = try decodeAccess(a, "{\"name\":\"v/1\",\"payload\":{\"data\":\"aGk=\",\"futureField\":{\"a\":[1]}},\"top\":1}");
    try testing.expectEqualStrings("aGk=", future.data);

    // Proto3 JSON keeps the last of a duplicated field.
    const dup = try decodeAccess(a, "{\"name\":\"a\",\"name\":\"b\"}");
    try testing.expectEqualStrings("b", dup.name);
}

test "decode access: a checksum that is not one is a broken response" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A number instead of a string is accepted: the JSON mapping allows it.
    try testing.expectEqual(825_573_743, (try decodeAccess(a, "{\"payload\":{\"dataCrc32c\":825573743}}")).checksum.?);
    try testing.expectEqual(0, (try decodeAccess(a, "{\"payload\":{\"dataCrc32c\":\"0\"}}")).checksum.?);
    try testing.expectEqual(
        4_294_967_295,
        (try decodeAccess(a, "{\"payload\":{\"dataCrc32c\":\"4294967295\"}}")).checksum.?,
    );
    for ([_][]const u8{
        "{\"payload\":{\"dataCrc32c\":\"4294967296\"}}", // one past 32 bits
        "{\"payload\":{\"dataCrc32c\":\"-1\"}}",
        "{\"payload\":{\"dataCrc32c\":-1}}",
        "{\"payload\":{\"dataCrc32c\":\"\"}}",
        "{\"payload\":{\"dataCrc32c\":\"825573743 \"}}",
        "{\"payload\":{\"dataCrc32c\":\"0x1234\"}}",
        "{\"payload\":{\"dataCrc32c\":\"abc\"}}",
        "{\"payload\":{\"dataCrc32c\":8.25e8}}",
        "{\"payload\":{\"dataCrc32c\":true}}",
        "{\"payload\":{\"dataCrc32c\":[825573743]}}",
        "{\"payload\":{\"dataCrc32c\":\"99999999999999999999999999\"}}",
    }) |body| {
        try testing.expectError(error.InvalidResponse, decodeAccess(a, body));
    }
}

test "a JSON null checksum means the version has none" {
    // std.json turns an explicit `null` into a missing optional, so this
    // arm is only reachable if that ever changes. A literal null means
    // absent in proto3 JSON, and absent is not the same as unreadable.
    try testing.expectEqual(null, try parseChecksum(std.json.Value{ .null = {} }));
    try testing.expectEqual(null, try parseChecksum(null));
}

test "decode access: bodies that are not the expected shape" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // A blank body is an empty object, as a JSON API may send for no content.
    _ = try decodeAccess(a, "");
    _ = try decodeAccess(a, "   \r\n");
    for ([_][]const u8{ "[]", "null", "<html>", "{\"payload\":\"text\"}", "{", "{\"name\":1}" }) |body| {
        try testing.expectError(error.InvalidResponse, decodeAccess(a, body));
    }
}

fn decodeProperty(_: void, input: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Every decoder either succeeds or reports InvalidResponse; none may
    // crash, and none may leak.
    inline for (.{ decodeSecret, decodeSecretPage, decodeVersion }) |decode| {
        _ = decode(a, input) catch |err| switch (err) {
            error.InvalidResponse => {},
            else => return err,
        };
    }
    const got = decodeAccess(a, input) catch |err| switch (err) {
        error.InvalidResponse => return,
        else => return err,
    };
    // A checksum that survived decoding is one a u32 can hold.
    if (got.checksum) |c| try testing.expect(c <= std.math.maxInt(u32));
}

fn addVersionProperty(_: void, input: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sum = core.crc32c.hash(input);
    const body = try encodeAddVersion(a, input, sum);

    // The length is known before the body is built, so its buffer is
    // allocated once: a grown buffer would leave a copy of the secret
    // behind until the arena was wiped.
    try testing.expectEqual(body.len, addVersionBodyLen(input, sum));
    // Any bytes at all survive the trip through the body.
    const parsed = try decodeAccess(a, body);
    try testing.expectEqual(sum, parsed.checksum.?);
    try testing.expectEqualSlices(u8, input, try core.base64.decode(a, parsed.data));
    // Whatever the payload, the body is printable ASCII JSON.
    for (body) |c| try testing.expect(c >= ' ' and c < 0x7f);
}

test "fuzz addVersion: any bytes round-trip, and the length is known first" {
    try test_util.fuzzBytes({}, addVersionProperty, .{ .corpus = &.{
        "s3cr3t",
        "",
        "\x00\x01\x02\x03\xff",
        "{\"json\":\"inside\"}",
        "line\nbreak\r\n",
    } });
}

test "fuzz decoders: arbitrary bodies never crash" {
    try test_util.fuzzBytes({}, decodeProperty, .{ .corpus = &.{
        "{\"name\":\"v/1\",\"payload\":{\"data\":\"czNjcjN0\",\"dataCrc32c\":\"825573743\"}}",
        "{\"payload\":{\"dataCrc32c\":\"99999999999999999999\"}}",
        "{\"payload\":{\"data\":\"\\ud800\"}}",
        "{\"secrets\":[{\"name\":\"projects/1/secrets/a\",\"labels\":{\"k\":\"v\"}}],\"totalSize\":1}",
        "{\"name\":\"v/1\",\"state\":\"DESTROYED\",\"destroyTime\":\"2026-09-20T23:09:41.5Z\"}",
        "{\"annotations\":{\"fk\":\"v\"},\"expireTime\":\"2026-10-04T13:04:09.503134Z\",\"versionAliases\":{\"prod\":\"1\"},\"versionDestroyTtl\":\"86400.500s\"}",
        "{\"name\":\"v/1\",\"state\":\"DISABLED\",\"scheduledDestroyTime\":\"2026-10-03T13:04:03.889502667Z\"}",
        "{\"a\":[[[[[[[[[[[[[[[[[[[[1]]]]]]]]]]]]]]]]]]]}",
        "",
        "null",
    } });
}
