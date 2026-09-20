//! JSON and base64: request bodies out, response bodies in.
//!
//! Zig field names are snake_case and the wire uses the API's camelCase. The
//! private `Wire*` structs mirror the wire exactly and never leave this file.
//! Every response field is optional, `null` counts as absent (the proto3 JSON
//! rule), and unknown fields are ignored, so new server fields never break
//! old clients.

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("core");
const types = @import("types.zig");
const test_util = @import("test_util.zig");

pub const DecodeError = error{ InvalidResponse, OutOfMemory };

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
        .checksum = try checksum(payload.dataCrc32c),
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
fn checksum(value: ?std.json.Value) DecodeError!?u32 {
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
