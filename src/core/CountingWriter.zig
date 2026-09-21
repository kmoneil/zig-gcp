//! A `std.Io.Writer` that counts the bytes passing through it to another
//! writer. A streaming download wraps the caller's writer in one, so that
//! when a connection drops mid-body the resume request knows which offset
//! was reached.

const std = @import("std");
const CountingWriter = @This();

/// Borrowed; must outlive this writer.
out: *std.Io.Writer,
/// Bytes handed to `out`, buffered there or not.
count: u64 = 0,
/// The interface. Unbuffered: every write passes straight through and is
/// counted at once, and flushing this writer does not flush `out`, whose
/// buffer belongs to whoever owns it.
writer: std.Io.Writer,

pub fn init(out: *std.Io.Writer) CountingWriter {
    return .{ .out = out, .writer = .{ .buffer = &.{}, .vtable = &.{ .drain = drain } } };
}

fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
    const self: *CountingWriter = @alignCast(@fieldParentPtr("writer", w));
    const n = try self.out.writeSplatHeader(w.buffered(), data, splat);
    self.count += n;
    return n;
}

const testing = std.testing;
const test_util = @import("testing.zig");

test "counts what reaches the writer behind it" {
    var buf: [64]u8 = undefined;
    var fixed: std.Io.Writer = .fixed(&buf);
    var counting: CountingWriter = .init(&fixed);
    const w = &counting.writer;

    try w.writeAll("hello ");
    try testing.expectEqual(6, counting.count);
    try w.print("{s}{d}", .{ "world", 7 });
    try w.writeByte('!');
    try w.splatByteAll('x', 3);
    try testing.expectEqualStrings("hello world7!xxx", fixed.buffered());
    try testing.expectEqual(fixed.buffered().len, counting.count);
}

test "a failed write is not counted" {
    var buf: [4]u8 = undefined;
    var fixed: std.Io.Writer = .fixed(&buf);
    var counting: CountingWriter = .init(&fixed);
    try testing.expectError(error.WriteFailed, counting.writer.writeAll("too much"));
    // The inner writer kept what fit, but the failed write confirmed none
    // of it, so the count stays behind what the buffer shows. That is the
    // safe direction where downloads use the count: a failed sink ends the
    // transfer, and only confirmed bytes could ever justify a resume offset.
    try testing.expectEqualStrings("too ", fixed.buffered());
    try testing.expectEqual(0, counting.count);
}

fn countingProperty(_: void, input: []const u8) !void {
    var g: test_util.ByteGen = .init(input);
    var buf: [2 * test_util.max_fuzz_input]u8 = undefined;
    var fixed: std.Io.Writer = .fixed(&buf);
    var counting: CountingWriter = .init(&fixed);
    // Any mix of writes: the count always equals what the inner writer got,
    // and the bytes arrive unchanged.
    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    for (0..8) |_| {
        const piece = g.slice(64);
        try counting.writer.writeAll(piece);
        try expected.appendSlice(testing.allocator, piece);
    }
    try testing.expectEqualSlices(u8, expected.items, fixed.buffered());
    try testing.expectEqual(expected.items.len, counting.count);
}

test "fuzz CountingWriter: count matches delivery for any write mix" {
    try test_util.fuzzBytes({}, countingProperty, .{ .corpus = &.{
        "",
        "\x00\x00\x00\x00\x00\x00\x00\x05hello\x00\x00\x00\x00\x00\x00\x00\x03abc",
    } });
}
