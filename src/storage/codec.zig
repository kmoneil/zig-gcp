//! JSON: request bodies out, response bodies in.
//!
//! The wire format has quirks every binding trips over: `size`,
//! `generation` and `metageneration` are decimal integers in JSON strings,
//! though emulators also send plain numbers; `crc32c` is base64 of the four
//! checksum bytes in big-endian order; `md5Hash` is base64 of the digest
//! and missing for composite objects. The private `Wire*` structs mirror
//! the wire exactly and never leave this file. Unknown fields are ignored,
//! so new server fields never break old clients.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Stringify = std.json.Stringify;
const Writer = std.Io.Writer;
const core = @import("core");
const types = @import("types.zig");

pub const DecodeError = error{ InvalidResponse, OutOfMemory };

// Requests

/// The object metadata an upload declares: the multipart metadata part and
/// the resumable session's opening body are this same JSON. `crc32c` is
/// the checksum's base64 form, or null to claim none.
pub fn encodeUploadMetadata(
    arena: Allocator,
    object_name: []const u8,
    options: types.UploadOptions,
    crc32c: ?[8]u8,
) Allocator.Error![]u8 {
    var out: Writer.Allocating = .init(arena);
    var jw: Stringify = .{ .writer = &out.writer };
    writeUploadMetadata(&jw, object_name, options, crc32c) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn writeUploadMetadata(
    jw: *Stringify,
    object_name: []const u8,
    options: types.UploadOptions,
    crc32c: ?[8]u8,
) Stringify.Error!void {
    try jw.beginObject();
    try jw.objectField("name");
    try jw.write(object_name);
    try jw.objectField("contentType");
    try jw.write(options.content_type);
    if (options.cache_control) |value| {
        try jw.objectField("cacheControl");
        try jw.write(value);
    }
    if (options.content_encoding) |value| {
        try jw.objectField("contentEncoding");
        try jw.write(value);
    }
    if (options.metadata.len > 0) {
        try jw.objectField("metadata");
        try jw.beginObject();
        for (options.metadata) |entry| {
            try jw.objectField(entry.key);
            try jw.write(entry.value);
        }
        try jw.endObject();
    }
    if (crc32c) |checksum| {
        try jw.objectField("crc32c");
        try jw.write(&checksum);
    }
    try jw.endObject();
}

/// The `buckets.insert` body.
pub fn encodeBucket(arena: Allocator, name: []const u8, config: types.BucketConfig) Allocator.Error![]u8 {
    var out: Writer.Allocating = .init(arena);
    var jw: Stringify = .{ .writer = &out.writer };
    writeBucket(&jw, name, config) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn writeBucket(jw: *Stringify, name: []const u8, config: types.BucketConfig) Stringify.Error!void {
    try jw.beginObject();
    try jw.objectField("name");
    try jw.write(name);
    try jw.objectField("location");
    try jw.write(config.location);
    try jw.objectField("storageClass");
    try jw.write(config.storage_class);
    try jw.endObject();
}

// Responses

/// One Object resource.
pub fn decodeObject(arena: Allocator, body: []const u8) DecodeError!types.ObjectInfo {
    return objectFromWire(arena, try parseWire(WireObject, arena, body));
}

/// The `size` an Object resource names, or null when it names none, which
/// `ObjectInfo` cannot tell from an empty object.
pub fn decodeObjectSize(arena: Allocator, body: []const u8) DecodeError!?u64 {
    const wire = try parseWire(struct { size: ?std.json.Value = null }, arena, body);
    return if (wire.size == null) null else try u64FromValue(wire.size);
}

/// What a copy with changes carries from its source: the generation and
/// metageneration it pins the copy to, and the editable fields as the
/// server sent them. An empty field reads as absent.
pub const CopySource = struct {
    generation: u64,
    metageneration: u64,
    content_type: ?[]const u8,
    cache_control: ?[]const u8,
    content_disposition: ?[]const u8,
    content_encoding: ?[]const u8,
    content_language: ?[]const u8,
    /// RFC 3339. `ObjectInfo` does not report it, but lifecycle rules read
    /// it, so a copy must not drop it.
    custom_time: ?[]const u8,
    metadata: []const types.Metadata,
};

/// The source of a copy with changes. A resource that names no generation
/// or metageneration is `InvalidResponse`: there would be nothing to pin
/// the copy to.
pub fn decodeCopySource(arena: Allocator, body: []const u8) DecodeError!CopySource {
    const wire = try parseWire(WireCopySource, arena, body);
    const generation = try u64FromValue(wire.generation);
    const metageneration = try u64FromValue(wire.metageneration);
    if (generation == 0 or metageneration == 0) return error.InvalidResponse;
    return .{
        .generation = generation,
        .metageneration = metageneration,
        .content_type = nonEmpty(wire.contentType),
        .cache_control = nonEmpty(wire.cacheControl),
        .content_disposition = nonEmpty(wire.contentDisposition),
        .content_encoding = nonEmpty(wire.contentEncoding),
        .content_language = nonEmpty(wire.contentLanguage),
        .custom_time = nonEmpty(wire.customTime),
        .metadata = try metadataFromWire(arena, wire.metadata),
    };
}

const WireCopySource = struct {
    generation: ?std.json.Value = null,
    metageneration: ?std.json.Value = null,
    contentType: ?[]const u8 = null,
    cacheControl: ?[]const u8 = null,
    contentDisposition: ?[]const u8 = null,
    contentEncoding: ?[]const u8 = null,
    contentLanguage: ?[]const u8 = null,
    customTime: ?[]const u8 = null,
    metadata: ?std.json.ArrayHashMap(?[]const u8) = null,
};

/// One page of `objects.list`.
pub fn decodeObjectPage(arena: Allocator, body: []const u8) DecodeError!types.ObjectPage {
    const wire = try parseWire(WireObjectPage, arena, body);
    const listed = wire.items orelse &.{};
    const objects = try arena.alloc(types.ObjectInfo, listed.len);
    for (listed, objects) |w, *info| info.* = try objectFromWire(arena, w);
    const wire_prefixes = wire.prefixes orelse &.{};
    const prefixes = try arena.alloc([]const u8, wire_prefixes.len);
    for (wire_prefixes, prefixes) |w, *p| p.* = w orelse "";
    return .{
        .objects = objects,
        .prefixes = prefixes,
        .next_page_token = nonEmpty(wire.nextPageToken),
    };
}

/// One answer of the rewrite loop behind `copyTo`.
pub const Rewrite = struct {
    done: bool,
    /// Continues an unfinished rewrite. Null once done, or when the server
    /// sent none.
    rewrite_token: ?[]const u8,
    /// The finished object, on the final answer.
    resource: ?types.ObjectInfo,
    total_bytes_rewritten: u64,
    object_size: u64,
};

pub fn decodeRewrite(arena: Allocator, body: []const u8) DecodeError!Rewrite {
    const wire = try parseWire(WireRewrite, arena, body);
    return .{
        .done = wire.done orelse false,
        .rewrite_token = nonEmpty(wire.rewriteToken),
        .resource = if (wire.resource) |w| try objectFromWire(arena, w) else null,
        .total_bytes_rewritten = try u64FromValue(wire.totalBytesRewritten),
        .object_size = try u64FromValue(wire.objectSize),
    };
}

const WireRewrite = struct {
    done: ?bool = null,
    rewriteToken: ?[]const u8 = null,
    totalBytesRewritten: ?std.json.Value = null,
    objectSize: ?std.json.Value = null,
    resource: ?WireObject = null,
};

/// One Bucket resource.
pub fn decodeBucket(arena: Allocator, body: []const u8) DecodeError!types.BucketInfo {
    return bucketFromWire(try parseWire(WireBucket, arena, body));
}

/// One page of `buckets.list`.
pub fn decodeBucketPage(arena: Allocator, body: []const u8) DecodeError!types.BucketPage {
    const wire = try parseWire(WireBucketPage, arena, body);
    const listed = wire.items orelse &.{};
    const buckets = try arena.alloc(types.BucketInfo, listed.len);
    for (listed, buckets) |w, *info| info.* = bucketFromWire(w);
    return .{
        .buckets = buckets,
        .next_page_token = nonEmpty(wire.nextPageToken),
    };
}

const WireObject = struct {
    name: ?[]const u8 = null,
    bucket: ?[]const u8 = null,
    size: ?std.json.Value = null,
    generation: ?std.json.Value = null,
    metageneration: ?std.json.Value = null,
    contentType: ?[]const u8 = null,
    cacheControl: ?[]const u8 = null,
    contentDisposition: ?[]const u8 = null,
    contentEncoding: ?[]const u8 = null,
    contentLanguage: ?[]const u8 = null,
    crc32c: ?[]const u8 = null,
    md5Hash: ?[]const u8 = null,
    componentCount: ?std.json.Value = null,
    etag: ?[]const u8 = null,
    storageClass: ?[]const u8 = null,
    timeCreated: ?[]const u8 = null,
    updated: ?[]const u8 = null,
    metadata: ?std.json.ArrayHashMap(?[]const u8) = null,
};

const WireObjectPage = struct {
    items: ?[]const WireObject = null,
    prefixes: ?[]const ?[]const u8 = null,
    nextPageToken: ?[]const u8 = null,
};

const WireBucket = struct {
    name: ?[]const u8 = null,
    location: ?[]const u8 = null,
    storageClass: ?[]const u8 = null,
    timeCreated: ?[]const u8 = null,
};

const WireBucketPage = struct {
    items: ?[]const WireBucket = null,
    nextPageToken: ?[]const u8 = null,
};

fn objectFromWire(arena: Allocator, wire: WireObject) DecodeError!types.ObjectInfo {
    return .{
        .name = wire.name orelse "",
        .bucket = wire.bucket orelse "",
        .size = try u64FromValue(wire.size),
        .generation = try u64FromValue(wire.generation),
        .metageneration = try u64FromValue(wire.metageneration),
        .content_type = wire.contentType orelse "",
        .cache_control = nonEmpty(wire.cacheControl),
        .content_disposition = nonEmpty(wire.contentDisposition),
        .content_encoding = nonEmpty(wire.contentEncoding),
        .content_language = nonEmpty(wire.contentLanguage),
        .crc32c = try crc32cFromWire(wire.crc32c),
        .md5 = try md5FromWire(wire.md5Hash),
        .component_count = if (wire.componentCount == null) null else std.math.cast(
            u32,
            try u64FromValue(wire.componentCount),
        ) orelse return error.InvalidResponse,
        .etag = wire.etag orelse "",
        .storage_class = wire.storageClass orelse "",
        .time_created = wire.timeCreated orelse "",
        .updated = wire.updated orelse "",
        .metadata = try metadataFromWire(arena, wire.metadata),
    };
}

fn bucketFromWire(wire: WireBucket) types.BucketInfo {
    return .{
        .name = wire.name orelse "",
        .location = wire.location orelse "",
        .storage_class = wire.storageClass orelse "",
        .time_created = wire.timeCreated orelse "",
    };
}

fn metadataFromWire(
    arena: Allocator,
    wire: ?std.json.ArrayHashMap(?[]const u8),
) Allocator.Error![]const types.Metadata {
    const map = (wire orelse return &.{}).map;
    const out = try arena.alloc(types.Metadata, map.count());
    for (map.keys(), map.values(), out) |k, v, *entry| entry.* = .{ .key = k, .value = v orelse "" };
    return out;
}

/// A `u64` the API sends as a decimal string, though emulators also send a
/// plain number. Absent reads as 0.
fn u64FromValue(value: ?std.json.Value) DecodeError!u64 {
    return switch (value orelse return 0) {
        .string, .number_string => |text| std.fmt.parseInt(u64, text, 10) catch error.InvalidResponse,
        .integer => |n| if (n >= 0) @intCast(n) else error.InvalidResponse,
        else => error.InvalidResponse,
    };
}

fn crc32cFromWire(text: ?[]const u8) DecodeError!?u32 {
    const t = text orelse return null;
    return core.crc32c.fromBase64(t) catch error.InvalidResponse;
}

fn md5FromWire(text: ?[]const u8) DecodeError!?[16]u8 {
    const t = text orelse return null;
    const decoder = std.base64.standard.Decoder;
    const len = decoder.calcSizeForSlice(t) catch return error.InvalidResponse;
    if (len != 16) return error.InvalidResponse;
    var digest: [16]u8 = undefined;
    decoder.decode(&digest, t) catch return error.InvalidResponse;
    return digest;
}

fn nonEmpty(text: ?[]const u8) ?[]const u8 {
    const t = text orelse return null;
    return if (t.len == 0) null else t;
}

fn parseWire(comptime T: type, arena: Allocator, body: []const u8) DecodeError!T {
    return std.json.parseFromSliceLeaky(T, arena, body, .{
        .ignore_unknown_fields = true,
        // Proto3 JSON parsers keep the last duplicate rather than failing.
        .duplicate_field_behavior = .use_last,
        .allocate = .alloc_always,
    }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidResponse,
    };
}

const testing = std.testing;
const test_util = @import("test_util.zig");

/// The spec's fixture: the object `hello world\n`, whose real CRC-32C is
/// 0xF0FF7292, "8P9ykg==" in the API's encoding.
const fixture_object =
    \\{
    \\  "kind": "storage#object",
    \\  "name": "reports/2026/q3.txt",
    \\  "bucket": "my-bucket",
    \\  "generation": "1758448800123456",
    \\  "metageneration": "1",
    \\  "size": "12",
    \\  "contentType": "text/plain",
    \\  "crc32c": "8P9ykg==",
    \\  "md5Hash": "b1kCrCNwJL3QwXbLkwY9xA==",
    \\  "etag": "CMDQ9t7q4o8DEAE=",
    \\  "storageClass": "STANDARD",
    \\  "timeCreated": "2026-09-21T10:00:00.123Z",
    \\  "updated": "2026-09-21T10:00:00.123Z",
    \\  "metadata": { "origin": "zig" }
    \\}
;

test "decode the spec's object fixture" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const info = try decodeObject(arena.allocator(), fixture_object);
    try testing.expectEqualStrings("reports/2026/q3.txt", info.name);
    try testing.expectEqualStrings("my-bucket", info.bucket);
    try testing.expectEqual(12, info.size);
    try testing.expectEqual(1758448800123456, info.generation);
    try testing.expectEqual(1, info.metageneration);
    try testing.expectEqualStrings("text/plain", info.content_type);
    try testing.expectEqual(0xf0ff7292, info.crc32c.?);
    try testing.expectEqual(core.crc32c.hash("hello world\n"), info.crc32c.?);
    var md5: [16]u8 = undefined;
    std.crypto.hash.Md5.hash("hello world\n", &md5, .{});
    try testing.expectEqualSlices(u8, &md5, &info.md5.?);
    try testing.expectEqualStrings("CMDQ9t7q4o8DEAE=", info.etag);
    try testing.expectEqualStrings("STANDARD", info.storage_class);
    try testing.expectEqualStrings("2026-09-21T10:00:00.123Z", info.time_created);
    try testing.expectEqualStrings("zig", info.metadataValue("origin").?);
}

test "string integers: string, number, above 32 bits, negative, garbage" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Emulators are not consistent: accept a JSON number too.
    const number = try decodeObject(a, "{\"size\": 12, \"generation\": 1758448800123456}");
    try testing.expectEqual(12, number.size);
    try testing.expectEqual(1758448800123456, number.generation);
    // Absent means zero, never a parse failure.
    const absent = try decodeObject(a, "{\"name\":\"x\"}");
    try testing.expectEqual(0, absent.size);
    try testing.expectEqual(null, absent.crc32c);
    try testing.expectEqual(null, absent.md5);
    // A value above 32 bits survives.
    const big = try decodeObject(a, "{\"size\":\"5497558138880\"}");
    try testing.expectEqual(5_497_558_138_880, big.size);
    for ([_][]const u8{
        "{\"size\":\"-1\"}",
        "{\"size\": -1}",
        "{\"size\":\"12abc\"}",
        "{\"size\":\"\"}",
        "{\"size\": true}",
        "{\"size\": 1.5}",
        "{\"size\":\"18446744073709551616\"}",
    }) |body| {
        try testing.expectError(error.InvalidResponse, decodeObject(a, body));
    }
}

test "decodeObjectSize tells an absent size from an empty object" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqual(12, (try decodeObjectSize(a, "{\"name\":\"x\",\"size\":\"12\"}")).?);
    try testing.expectEqual(0, (try decodeObjectSize(a, "{\"size\":\"0\"}")).?);
    try testing.expectEqual(7, (try decodeObjectSize(a, "{\"size\": 7}")).?);
    try testing.expectEqual(null, try decodeObjectSize(a, "{\"name\":\"x\"}"));
    try testing.expectEqual(null, try decodeObjectSize(a, "{\"size\": null}"));
    try testing.expectError(error.InvalidResponse, decodeObjectSize(a, "{\"size\":\"-1\"}"));
    try testing.expectError(error.InvalidResponse, decodeObjectSize(a, "not json"));
}

test "decodeCopySource: what a copy carries, and what it pins" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = try decodeCopySource(a,
        \\{"name":"a","generation":"1758448800123456","metageneration":"3",
        \\ "contentType":"text/plain","cacheControl":"no-cache","contentDisposition":"",
        \\ "contentLanguage":"en","customTime":"2026-09-23T00:00:00Z",
        \\ "storageClass":"NEARLINE","metadata":{"b":"2","a":"1"}}
    );
    try testing.expectEqual(1758448800123456, source.generation);
    try testing.expectEqual(3, source.metageneration);
    try testing.expectEqualStrings("text/plain", source.content_type.?);
    try testing.expectEqualStrings("no-cache", source.cache_control.?);
    // Empty reads as absent, and absent stays absent.
    try testing.expectEqual(null, source.content_disposition);
    try testing.expectEqual(null, source.content_encoding);
    try testing.expectEqualStrings("en", source.content_language.?);
    try testing.expectEqualStrings("2026-09-23T00:00:00Z", source.custom_time.?);
    // The server's order, which the copy keeps.
    try testing.expectEqual(2, source.metadata.len);
    try testing.expectEqualStrings("b", source.metadata[0].key);
    try testing.expectEqualStrings("a", source.metadata[1].key);

    // Emulators send plain numbers.
    const plain = try decodeCopySource(a, "{\"generation\":5,\"metageneration\":1}");
    try testing.expectEqual(5, plain.generation);
    try testing.expectEqual(0, plain.metadata.len);

    // Nothing to pin a copy to is not a source a copy can use.
    try testing.expectError(error.InvalidResponse, decodeCopySource(a, "{\"metageneration\":\"1\"}"));
    try testing.expectError(error.InvalidResponse, decodeCopySource(a, "{\"generation\":\"5\"}"));
    try testing.expectError(error.InvalidResponse, decodeCopySource(a, "{\"generation\":\"x\",\"metageneration\":\"1\"}"));
}

test "checksums: malformed base64 is InvalidResponse, not a wrong value" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectError(error.InvalidResponse, decodeObject(a, "{\"crc32c\":\"nope\"}"));
    try testing.expectError(error.InvalidResponse, decodeObject(a, "{\"crc32c\":\"AAAAAAAA\"}"));
    try testing.expectError(error.InvalidResponse, decodeObject(a, "{\"md5Hash\":\"8P9ykg==\"}"));
    const ok = try decodeObject(a, "{\"crc32c\":\"4waSgw==\"}");
    try testing.expectEqual(0xe3069283, ok.crc32c.?);
}

test "decode listings: items and prefixes are both optional" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // An empty listing can be nothing but its kind.
    const empty = try decodeObjectPage(a, "{ \"kind\": \"storage#objects\" }");
    try testing.expectEqual(0, empty.objects.len);
    try testing.expectEqual(0, empty.prefixes.len);
    try testing.expectEqual(null, empty.next_page_token);

    const page = try decodeObjectPage(a,
        \\{
        \\  "kind": "storage#objects",
        \\  "items": [ { "name": "reports/2026/q3.txt", "size": "12" } ],
        \\  "prefixes": [ "reports/2026/archive/" ],
        \\  "nextPageToken": "CgtyZXBvcnRzLzIwMjY="
        \\}
    );
    try testing.expectEqual(1, page.objects.len);
    try testing.expectEqualStrings("reports/2026/q3.txt", page.objects[0].name);
    try testing.expectEqual(12, page.objects[0].size);
    try testing.expectEqual(1, page.prefixes.len);
    try testing.expectEqualStrings("reports/2026/archive/", page.prefixes[0]);
    try testing.expectEqualStrings("CgtyZXBvcnRzLzIwMjY=", page.next_page_token.?);
}

test "decode buckets" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bucket = try decodeBucket(a,
        \\{"kind":"storage#bucket","name":"my-bucket","location":"US",
        \\ "storageClass":"STANDARD","timeCreated":"2026-09-21T10:00:00.000Z"}
    );
    try testing.expectEqualStrings("my-bucket", bucket.name);
    try testing.expectEqualStrings("US", bucket.location);
    try testing.expectEqualStrings("STANDARD", bucket.storage_class);

    const page = try decodeBucketPage(a,
        \\{"items":[{"name":"a"},{"name":"b"}],"nextPageToken":"t"}
    );
    try testing.expectEqual(2, page.buckets.len);
    try testing.expectEqualStrings("b", page.buckets[1].name);
    try testing.expectEqualStrings("t", page.next_page_token.?);
    const empty = try decodeBucketPage(a, "{}");
    try testing.expectEqual(0, empty.buckets.len);
    try testing.expectEqual(null, empty.next_page_token);
}

test "encode the bucket create body" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const body = try encodeBucket(arena.allocator(), "my-bucket", .{});
    try testing.expectEqualStrings(
        "{\"name\":\"my-bucket\",\"location\":\"US\",\"storageClass\":\"STANDARD\"}",
        body,
    );
    const custom = try encodeBucket(arena.allocator(), "eu-logs", .{ .location = "europe-west3", .storage_class = "NEARLINE" });
    try testing.expectEqualStrings(
        "{\"name\":\"eu-logs\",\"location\":\"europe-west3\",\"storageClass\":\"NEARLINE\"}",
        custom,
    );
}

fn decodeArbitrary(_: void, input: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Total: any body decodes or fails with InvalidResponse, never a crash.
    _ = decodeObject(a, input) catch |err| try testing.expectEqual(error.InvalidResponse, err);
    _ = decodeObjectPage(a, input) catch |err| try testing.expectEqual(error.InvalidResponse, err);
    _ = decodeBucketPage(a, input) catch |err| try testing.expectEqual(error.InvalidResponse, err);
    _ = decodeCopySource(a, input) catch |err| try testing.expectEqual(error.InvalidResponse, err);
}

test "fuzz decoding: arbitrary bodies never crash" {
    try test_util.fuzzBytes({}, decodeArbitrary, .{ .corpus = &.{
        fixture_object,
        "{ \"kind\": \"storage#objects\" }",
        "{\"items\":[{\"size\":\"-1\"}]}",
        "{\"prefixes\":[null]}",
        "{\"metadata\":{\"k\":null}}",
        "<html>502</html>",
        "{\"crc32c\":\"\\u0000\"}",
    } });
}

test "decode rewrite answers: unfinished, finished, and odd ones" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const unfinished = try decodeRewrite(a,
        \\{"kind":"storage#rewriteResponse","totalBytesRewritten":"1048576",
        \\ "objectSize":"20971520","done":false,"rewriteToken":"abc"}
    );
    try testing.expect(!unfinished.done);
    try testing.expectEqualStrings("abc", unfinished.rewrite_token.?);
    try testing.expectEqual(1048576, unfinished.total_bytes_rewritten);
    try testing.expectEqual(null, unfinished.resource);

    const finished = try decodeRewrite(a,
        \\{"done":true,"totalBytesRewritten":20971520,"objectSize":20971520,
        \\ "resource":{"name":"copy.bin","generation":"9","size":"20971520"}}
    );
    try testing.expect(finished.done);
    try testing.expectEqual(null, finished.rewrite_token);
    try testing.expectEqual(9, finished.resource.?.generation);

    const bare = try decodeRewrite(a, "{}");
    try testing.expect(!bare.done);
    try testing.expectEqual(null, bare.rewrite_token);
    try testing.expectError(error.InvalidResponse, decodeRewrite(a, "{\"totalBytesRewritten\":\"x\"}"));
}
