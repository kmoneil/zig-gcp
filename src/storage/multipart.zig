//! `multipart/related` framing for single-request uploads: one part of JSON
//! metadata, one part of object bytes. The body travels as three segments,
//! opening framing, the caller's data, closing framing, so the data is
//! never copied. The boundary is a fixed prefix plus 16 random hex digits;
//! the data is not scanned for it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const core = @import("core");
const codec = @import("codec.zig");
const types = @import("types.zig");

const boundary_prefix = "zig_gcp_";

/// The framing around one upload's data, allocated in the caller's arena.
pub const Parts = struct {
    /// The request's Content-Type: `multipart/related; boundary=...`.
    content_type: []const u8,
    /// Up to and including the blank line before the data.
    opening: []const u8,
    /// From after the data to the end of the body.
    closing: []const u8,
};

/// Builds the framing. `crc32c` is the base64 form to place in the
/// metadata, or null to send none.
pub fn build(
    arena: Allocator,
    io: std.Io,
    object_name: []const u8,
    options: types.UploadOptions,
    crc32c: ?[8]u8,
) Allocator.Error!Parts {
    var random: [8]u8 = undefined;
    io.random(&random);
    var boundary: [boundary_prefix.len + 16]u8 = undefined;
    _ = std.fmt.bufPrint(&boundary, "{s}{x:016}", .{
        boundary_prefix, std.mem.readInt(u64, &random, .big),
    }) catch unreachable;

    const content_type = try std.mem.concat(arena, u8, &.{ "multipart/related; boundary=", &boundary });
    const metadata = try codec.encodeUploadMetadata(arena, object_name, options, crc32c);

    var opening: Writer.Allocating = .init(arena);
    opening.writer.print(
        "--{s}\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n{s}" ++
            "\r\n--{s}\r\nContent-Type: {s}\r\n\r\n",
        .{ &boundary, metadata, &boundary, options.content_type },
    ) catch return error.OutOfMemory;

    const closing = try std.mem.concat(arena, u8, &.{ "\r\n--", &boundary, "--\r\n" });
    return .{
        .content_type = content_type,
        .opening = try opening.toOwnedSlice(),
        .closing = closing,
    };
}

const testing = std.testing;
const test_util = @import("test_util.zig");

test "the framing matches the spec's shape, with an exact Content-Length" {
    var clock: test_util.FakeClock = .{ .random_byte = 0xab };
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const data = "hello world\n";
    const parts = try build(arena.allocator(), clock.io(), "reports/2026/q3.txt", .{
        .content_type = "text/plain",
    }, core.crc32c.toBase64(core.crc32c.hash(data)));

    try testing.expectEqualStrings("multipart/related; boundary=zig_gcp_abababababababab", parts.content_type);
    try testing.expectEqualStrings("--zig_gcp_abababababababab\r\n" ++
        "Content-Type: application/json; charset=UTF-8\r\n\r\n" ++
        "{\"name\":\"reports/2026/q3.txt\",\"contentType\":\"text/plain\",\"crc32c\":\"8P9ykg==\"}" ++
        "\r\n--zig_gcp_abababababababab\r\nContent-Type: text/plain\r\n\r\n", parts.opening);
    try testing.expectEqualStrings("\r\n--zig_gcp_abababababababab--\r\n", parts.closing);
}

test "every option lands in the metadata part" {
    var clock: test_util.FakeClock = .{ .random_byte = 0x01 };
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const parts = try build(arena.allocator(), clock.io(), "a", .{
        .cache_control = "no-store",
        .content_encoding = "gzip",
        .metadata = &.{ .{ .key = "origin", .value = "zig" }, .{ .key = "k", .value = "" } },
    }, null);
    const expected_json = "{\"name\":\"a\",\"contentType\":\"application/octet-stream\"," ++
        "\"cacheControl\":\"no-store\",\"contentEncoding\":\"gzip\"," ++
        "\"metadata\":{\"origin\":\"zig\",\"k\":\"\"}}";
    try testing.expect(std.mem.indexOf(u8, parts.opening, expected_json) != null);
    // No checksum was given, so none is claimed.
    try testing.expect(std.mem.indexOf(u8, parts.opening, "crc32c") == null);
}

fn framingProperty(_: void, input: []const u8) !void {
    var g: test_util.ByteGen = .init(input);
    var clock: test_util.FakeClock = .{};
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var name_buf: [64]u8 = undefined;
    const name = g.utf8(&name_buf, 48);
    if (name.len == 0) return;
    const data = g.rest();
    const parts = try build(arena.allocator(), clock.io(), name, .{}, null);

    // The framing parses back: the body splits on the boundary into exactly
    // the metadata part and the data part, whatever the name and data.
    const boundary_eq = std.mem.indexOf(u8, parts.content_type, "boundary=").?;
    const boundary = parts.content_type[boundary_eq + "boundary=".len ..];
    var body: Writer.Allocating = .init(testing.allocator);
    defer body.deinit();
    try body.writer.writeAll(parts.opening);
    try body.writer.writeAll(data);
    try body.writer.writeAll(parts.closing);

    var delimiter_buf: [64]u8 = undefined;
    const delimiter = try std.fmt.bufPrint(&delimiter_buf, "\r\n--{s}", .{boundary});
    // The data is deliberately not scanned for the boundary; data that
    // happens to contain it is outside this property.
    if (std.mem.indexOf(u8, data, delimiter) != null) return;
    var it = std.mem.splitSequence(u8, body.written(), delimiter);
    const first = it.next().?;
    var dash_buf: [64]u8 = undefined;
    try testing.expect(std.mem.startsWith(u8, first, try std.fmt.bufPrint(&dash_buf, "--{s}", .{boundary})));
    const data_part = it.next() orelse return error.TestMissingDataPart;
    const blank = std.mem.indexOf(u8, data_part, "\r\n\r\n") orelse return error.TestMissingBlankLine;
    try testing.expectEqualSlices(u8, data, data_part[blank + 4 ..]);
    try testing.expectEqualStrings("--\r\n", it.next() orelse return error.TestMissingClose);
    try testing.expectEqual(null, it.next());
}

test "fuzz multipart framing parses back for any name and data" {
    try test_util.fuzzBytes({}, framingProperty, .{ .corpus = &.{
        "\x0breports/q3\x00hello world\n",
        "\x01a",
        "\x04a b%\xff\x00\x01\x02",
    } });
}
