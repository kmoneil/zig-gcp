//! gzip for request bodies held whole in memory: std's compressor, kept
//! clear of its traps, and a check that reads the result back.
//!
//! Zig 0.16's `std.compress.flate.Compress` was audited for storage's
//! compressing uploads (v0.23.0): correct and deterministic, with traps
//! this stays clear of. Its state must not move once in use, so it lives on
//! the heap; its output buffer must be longer than 8 bytes; a mid-stream
//! flush changes the bytes, so it is never flushed; and it is only fed
//! through `writeAll`. The result is decompressed again with core's own
//! decompressor and must give back exactly the input, and the gzip
//! trailer's CRC-32 and length must agree with it, since std's
//! decompressor checks neither.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const flate = std.compress.flate;
const crc32c = @import("crc32c.zig");
const Decompress = @import("flate.zig").Decompress;

pub const Error = error{
    OutOfMemory,
    /// What was made does not decompress to the input: a compressor bug.
    CheckFailed,
};

/// `data` gzip-compressed at `level`, 1 (fastest) to 9 (smallest), with a
/// fixed header (no name, no time), so the same data at the same level
/// always compresses to the same bytes. The caller frees the result with
/// `gpa`.
pub fn compress(gpa: Allocator, data: []const u8, level: u4) Error![]u8 {
    std.debug.assert(level >= 1 and level <= 9);
    const Work = struct {
        compress: flate.Compress,
        window: [flate.max_window_len]u8,
    };
    const work = try gpa.create(Work);
    defer gpa.destroy(work);
    var out: std.Io.Writer.Allocating = try .initCapacity(gpa, @max(64, data.len / 4));
    errdefer out.deinit();
    work.compress = flate.Compress.init(&out.writer, &work.window, .gzip, levelOptions(level)) catch return error.OutOfMemory;
    work.compress.writer.writeAll(data) catch return error.OutOfMemory;
    work.compress.finish() catch return error.OutOfMemory;
    const made = try out.toOwnedSlice();
    errdefer gpa.free(made);
    if (builtin.is_test and test_corrupt_trailer) made[made.len - 1] +%= 1;
    try check(gpa, made, data);
    return made;
}

/// Tests only: turn a byte of the trailer wrong after compressing, as a
/// compressor bug would, so that callers can show what a failed check
/// does. Reset it after use.
pub var test_corrupt_trailer: bool = false;

/// Whether `made` is one gzip member with std's header, whose content is
/// exactly `data`, and whose trailer names `data`'s CRC-32 and length.
pub fn check(gpa: Allocator, made: []const u8, data: []const u8) Error!void {
    const header = flate.Container.gzip.header();
    if (made.len < header.len + 8 or !std.mem.eql(u8, made[0..header.len], header)) return error.CheckFailed;
    const trailer = made[made.len - 8 ..];
    if (std.mem.readInt(u32, trailer[0..4], .little) != std.hash.Crc32.hash(data)) return error.CheckFailed;
    if (std.mem.readInt(u32, trailer[4..8], .little) != @as(u32, @truncate(data.len))) return error.CheckFailed;

    const window = try gpa.alloc(u8, flate.max_window_len);
    defer gpa.free(window);
    var in: std.Io.Reader = .fixed(made);
    var inflate: Decompress = .init(&in, .gzip, window);
    var hasher: crc32c.Hasher = .init();
    var total: usize = 0;
    var buf: [16 * 1024]u8 = undefined;
    while (true) {
        const n = inflate.reader.readSliceShort(&buf) catch return error.CheckFailed;
        hasher.update(buf[0..n]);
        total += n;
        if (n < buf.len) break;
    }
    if (total != data.len or hasher.final() != crc32c.hash(data)) return error.CheckFailed;
}

/// std's options for `level`, 1 to 9.
pub fn levelOptions(level: u4) flate.Compress.Options {
    return switch (level) {
        1 => .level_1,
        2 => .level_2,
        3 => .level_3,
        4 => .level_4,
        5 => .level_5,
        6 => .level_6,
        7 => .level_7,
        8 => .level_8,
        9 => .level_9,
        else => unreachable,
    };
}

const testing = std.testing;
const test_util = @import("testing.zig");

fn gunzip(made: []const u8) ![]u8 {
    var in: std.Io.Reader = .fixed(made);
    var window: [flate.max_window_len]u8 = undefined;
    var inflate: Decompress = .init(&in, .gzip, &window);
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    _ = try inflate.reader.streamRemaining(&out.writer);
    return out.toOwnedSlice();
}

test "compress: every level gives back the data, with std's fixed header" {
    var text: std.Io.Writer.Allocating = .init(testing.allocator);
    defer text.deinit();
    for (0..2000) |i| try text.writer.print("{{\"data\":\"bWVzc2FnZSB7ZH0=\",\"attributes\":{{\"n\":\"{d}\"}}}},", .{i});
    for (1..10) |level| {
        const made = try compress(testing.allocator, text.written(), @intCast(level));
        defer testing.allocator.free(made);
        try testing.expect(made.len < text.written().len / 4);
        try testing.expect(std.mem.startsWith(u8, made, flate.Container.gzip.header()));
        const back = try gunzip(made);
        defer testing.allocator.free(back);
        try testing.expectEqualSlices(u8, text.written(), back);
    }
    // Nothing at all is still a whole gzip stream.
    const empty = try compress(testing.allocator, "", 6);
    defer testing.allocator.free(empty);
    try check(testing.allocator, empty, "");
}

test "levelOptions: each level is std's of the same number" {
    inline for (1..10) |level| {
        const name = std.fmt.comptimePrint("level_{d}", .{level});
        try testing.expectEqual(@field(flate.Compress.Options, name), levelOptions(level));
    }
}

test "compress: the same data at the same level gives the same bytes" {
    const data = "the same publish body, compressed twice" ** 50;
    const a = try compress(testing.allocator, data, 6);
    defer testing.allocator.free(a);
    const b = try compress(testing.allocator, data, 6);
    defer testing.allocator.free(b);
    try testing.expectEqualSlices(u8, a, b);
}

test "check: refuses a header, trailer or content that does not match" {
    const data = "check me" ** 100;
    const made = try compress(testing.allocator, data, 6);
    defer testing.allocator.free(made);
    try check(testing.allocator, made, data);
    // Another input, another length, a truncated stream, a changed header
    // byte, each trailer field.
    try testing.expectError(error.CheckFailed, check(testing.allocator, made, "check me"));
    try testing.expectError(error.CheckFailed, check(testing.allocator, made[0 .. made.len - 1], data));
    try testing.expectError(error.CheckFailed, check(testing.allocator, made[0..10], data));
    const copy = try testing.allocator.dupe(u8, made);
    defer testing.allocator.free(copy);
    for ([_]usize{ 3, made.len - 8, made.len - 1 }) |at| {
        copy[at] +%= 1;
        try testing.expectError(error.CheckFailed, check(testing.allocator, copy, data));
        copy[at] -%= 1;
    }
    // The test hook makes compress itself fail its check.
    test_corrupt_trailer = true;
    defer test_corrupt_trailer = false;
    try testing.expectError(error.CheckFailed, compress(testing.allocator, data, 6));
}

fn compressWith(gpa: Allocator) !void {
    const made = try compress(gpa, "a body to compress, " ** 30, 6);
    gpa.free(made);
}

test "compress: every allocation failure is OutOfMemory without leaks" {
    try testing.checkAllAllocationFailures(testing.allocator, compressWith, .{});
}

fn roundTripProperty(_: void, input: []const u8) !void {
    var g: test_util.ByteGen = .init(input);
    const level = g.intRange(u4, 1, 9);
    // Whatever the rest holds: text that compresses, or bytes that do not.
    const data = g.rest();
    const made = try compress(testing.allocator, data, level);
    defer testing.allocator.free(made);
    const back = try gunzip(made);
    defer testing.allocator.free(back);
    try testing.expectEqualSlices(u8, data, back);
}

test "fuzz gzip compress: any bytes at any level decompress to themselves" {
    try test_util.fuzzBytes({}, roundTripProperty, .{ .corpus = &.{
        "",
        "\x05aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "\x08\x00\xff\x10\x80\x7f\x01\xfe",
    } });
}

/// One byte of a compressed body changed: the check refuses it, unless the
/// change only touched bits no decompressor reads (the padding after a
/// stored block's header, or after the last block) and the body still
/// decompresses to the data.
fn changedByteProperty(_: void, input: []const u8) !void {
    var g: test_util.ByteGen = .init(input);
    const level = g.intRange(u4, 1, 9);
    const mask = g.intRange(u8, 1, 255);
    const at = g.int(u16);
    const data = g.rest();
    const made = try compress(testing.allocator, data, level);
    defer testing.allocator.free(made);
    made[at % made.len] ^= mask;
    check(testing.allocator, made, data) catch |err| return testing.expectEqual(error.CheckFailed, err);
    const back = try gunzip(made);
    defer testing.allocator.free(back);
    try testing.expectEqualSlices(u8, data, back);
}

const random_64 = "\x49\xd5\x7f\xd4\x68\xb0\xc6\x27\x27\xf6\x7f\x99\xb8\x04\x6d\xe2\x4d\xe9\x27\xa6\x90\x05\xbf\xbf\xd4\x0f\x6c\x21\xc2\xe8\x88\xd9" ++
    "\xf8\x15\x6d\xc3\x36\x86\x7e\x2f\x54\x31\x23\xf4\xe8\xf2\x50\x64\x8c\x3c\xe3\x84\xf1\x30\x10\xbb\x9a\xac\xbf\x1a\xa0\x6b\xc7\xa9";

test "fuzz gzip check: a changed byte is refused, unless the body still gives back the data" {
    try test_util.fuzzBytes({}, changedByteProperty, .{
        .corpus = &.{
            // 54 bytes of a run, 23 compressed: the header's flags, a byte of
            // the compressed data, the trailer's last byte.
            "\x05\x01\x00\x03" ++ "a" ** 54,
            "\x05\x80\x00\x0c" ++ "a" ** 54,
            "\x05\xff\x00\x16" ++ "a" ** 54,
            // 64 random bytes, which go in a stored block: padding after its
            // header, which no decompressor reads, and its length.
            "\x00\x7f\x00\x0a" ++ random_64,
            "\x00\x00\x00\x0b" ++ random_64,
        },
    });
}
