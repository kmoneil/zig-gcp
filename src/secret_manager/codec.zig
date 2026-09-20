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

/// The `SecretVersion` that add, get, enable, disable and destroy return.
pub fn decodeVersion(arena: Allocator, body: []const u8) DecodeError!types.VersionInfo {
    return versionFromWire(try parseWire(WireVersion, arena, body));
}

const WireVersion = struct {
    name: ?[]const u8 = null,
    createTime: ?[]const u8 = null,
    destroyTime: ?[]const u8 = null,
    state: ?[]const u8 = null,
    etag: ?[]const u8 = null,
    clientSpecifiedPayloadChecksum: ?bool = null,
};

fn versionFromWire(wire: WireVersion) types.VersionInfo {
    return .{
        .name = wire.name orelse "",
        .create_time = wire.createTime orelse "",
        .destroy_time = wire.destroyTime orelse "",
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
    // Any body at all yields a value or InvalidResponse, never a crash.
    const got = decodeAccess(arena.allocator(), input) catch |err| switch (err) {
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

test "fuzz decode access: arbitrary bodies never crash" {
    try test_util.fuzzBytes({}, decodeProperty, .{ .corpus = &.{
        "{\"name\":\"v/1\",\"payload\":{\"data\":\"czNjcjN0\",\"dataCrc32c\":\"825573743\"}}",
        "{\"payload\":{\"dataCrc32c\":\"99999999999999999999\"}}",
        "{\"payload\":{\"data\":\"\\ud800\"}}",
        "{\"a\":[[[[[[[[[[[[[[[[[[[[1]]]]]]]]]]]]]]]]]]]}",
        "",
        "null",
    } });
}
