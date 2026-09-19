//! `application/x-www-form-urlencoded` bodies, as the OAuth token endpoint
//! takes. Every byte outside RFC 3986's unreserved set is percent-encoded,
//! space included. Refresh tokens contain `/`, so skipping the encoding
//! breaks real tokens while passing naive tests.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const test_util = @import("core").testing;

pub const Field = struct {
    name: []const u8,
    value: []const u8,
};

/// Writes `name=value` pairs joined by `&`.
pub fn write(w: *Writer, fields: []const Field) Writer.Error!void {
    for (fields, 0..) |field, i| {
        if (i != 0) try w.writeByte('&');
        try writeEncoded(w, field.name);
        try w.writeByte('=');
        try writeEncoded(w, field.value);
    }
}

/// The encoded body, allocated in `arena`.
pub fn encode(arena: Allocator, fields: []const Field) Allocator.Error![]const u8 {
    var out: Writer.Allocating = .init(arena);
    write(&out.writer, fields) catch return error.OutOfMemory;
    return out.written();
}

fn writeEncoded(w: *Writer, text: []const u8) Writer.Error!void {
    for (text) |c| {
        if (isUnreserved(c)) {
            try w.writeByte(c);
        } else {
            try w.print("%{X:0>2}", .{c});
        }
    }
}

fn isUnreserved(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == '_' or c == '~';
}

const testing = std.testing;

/// The inverse of `encode`, for tests: the token endpoint does this part.
fn decode(arena: Allocator, body: []const u8) ![]Field {
    var fields: std.ArrayList(Field) = .empty;
    if (body.len == 0) return fields.items;
    var pairs = std.mem.splitScalar(u8, body, '&');
    while (pairs.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse return error.TestMalformedForm;
        try fields.append(arena, .{
            .name = try percentDecode(arena, pair[0..eq]),
            .value = try percentDecode(arena, pair[eq + 1 ..]),
        });
    }
    return fields.items;
}

fn percentDecode(arena: Allocator, text: []const u8) ![]u8 {
    const out = try arena.alloc(u8, text.len);
    var n: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (n += 1) {
        if (text[i] == '%') {
            if (i + 3 > text.len) return error.TestMalformedForm;
            out[n] = try std.fmt.parseInt(u8, text[i + 1 ..][0..2], 16);
            i += 3;
        } else {
            out[n] = text[i];
            i += 1;
        }
    }
    return out[0..n];
}

test "form: a realistic refresh token survives" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const body = try encode(arena.allocator(), &.{
        .{ .name = "grant_type", .value = "refresh_token" },
        .{ .name = "refresh_token", .value = "1//0gExample-refresh_token.value~x" },
    });
    try testing.expectEqualStrings("grant_type=refresh_token&refresh_token=1%2F%2F0gExample-refresh_token.value~x", body);
}

test "form: separators and spaces in values are encoded" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const body = try encode(arena.allocator(), &.{.{ .name = "k", .value = "a/b+c=d&e f%\xff" }});
    try testing.expectEqualStrings("k=a%2Fb%2Bc%3Dd%26e%20f%25%FF", body);
    const back = try decode(arena.allocator(), body);
    try testing.expectEqual(1, back.len);
    try testing.expectEqualStrings("a/b+c=d&e f%\xff", back[0].value);
}

test "form: no fields is an empty body" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("", try encode(arena.allocator(), &.{}));
}

fn roundTripProperty(_: void, input: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var g: test_util.ByteGen = .init(input);
    var fields: [4]Field = undefined;
    const n = g.intRange(usize, 0, fields.len);
    for (fields[0..n]) |*f| f.* = .{ .name = g.slice(16), .value = g.slice(64) };

    const body = try encode(a, fields[0..n]);
    // Only unreserved bytes, percent escapes and the two separators.
    for (body) |c| try testing.expect(isUnreserved(c) or c == '%' or c == '&' or c == '=');
    // Every field comes back: even an empty one leaves its `=`.
    const back = try decode(a, body);
    try testing.expectEqual(n, back.len);
    for (fields[0..n], back) |want, got| {
        try testing.expectEqualStrings(want.name, got.name);
        try testing.expectEqualStrings(want.value, got.value);
    }
}

test "fuzz form: every field round-trips, and only safe bytes are written" {
    try test_util.fuzzBytes({}, roundTripProperty, .{ .corpus = &.{
        "\x00\x00\x00\x00\x00\x00\x00\x02",
        "\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x03key\x00\x00\x00\x00\x00\x00\x00\x051//a+",
    } });
}
