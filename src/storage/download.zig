//! Downloading into memory: a capped collecting writer, and the response
//! headers a download reads. The streaming download to a caller's writer
//! builds on the same pieces in the next milestone.

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("core");

/// A `std.Io.Writer` that collects into an allocator-backed buffer, up to a
/// cap. Exceeding the cap fails the write and marks `over`, which is how a
/// download tells "the object is larger than `max_bytes`" apart from the
/// allocator failing.
pub const CappedAllocating = struct {
    alloc: Allocator,
    cap: usize,
    list: std.ArrayList(u8) = .empty,
    /// True when a write ran past the cap.
    over: bool = false,
    /// True when the allocator refused, which the writer can only report as
    /// a failed write.
    out_of_memory: bool = false,
    writer: std.Io.Writer,

    pub fn init(alloc: Allocator, cap: usize) CappedAllocating {
        return .{
            .alloc = alloc,
            .cap = cap,
            .writer = .{ .buffer = &.{}, .vtable = &.{ .drain = drain } },
        };
    }

    pub fn written(self: *const CappedAllocating) []const u8 {
        return self.list.items;
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *CappedAllocating = @alignCast(@fieldParentPtr("writer", w));
        var consumed: usize = 0;
        for (data[0 .. data.len - 1]) |slice| {
            try self.append(slice);
            consumed += slice.len;
        }
        const pattern = data[data.len - 1];
        for (0..splat) |_| {
            try self.append(pattern);
            consumed += pattern.len;
        }
        return consumed;
    }

    fn append(self: *CappedAllocating, bytes: []const u8) std.Io.Writer.Error!void {
        if (bytes.len > self.cap - self.list.items.len) {
            self.over = true;
            return error.WriteFailed;
        }
        self.list.appendSlice(self.alloc, bytes) catch {
            self.out_of_memory = true;
            return error.WriteFailed;
        };
    }
};

/// The `Range` header for bytes `start` through `end` inclusive, or
/// everything from `start` when `end` is null.
pub fn formatRange(buf: []u8, start: u64, end: ?u64) []const u8 {
    return if (end) |e|
        std.fmt.bufPrint(buf, "bytes={d}-{d}", .{ start, e }) catch unreachable
    else
        std.fmt.bufPrint(buf, "bytes={d}-", .{start}) catch unreachable;
}

/// The first byte offset a `Content-Range` header claims, from
/// `bytes {start}-{end}/{total}`, or null when it cannot be read.
pub fn contentRangeStart(value: []const u8) ?u64 {
    const rest = std.mem.trimStart(u8, value, " \t");
    if (!std.ascii.startsWithIgnoreCase(rest, "bytes")) return null;
    const numbers = std.mem.trimStart(u8, rest["bytes".len..], " \t");
    const dash = std.mem.indexOfScalar(u8, numbers, '-') orelse return null;
    return std.fmt.parseInt(u64, numbers[0..dash], 10) catch null;
}

/// Whether the body was decompressed on its way here. The stored checksum
/// covers the compressed bytes, so there is nothing to verify against, and
/// byte offsets mean nothing to the server, so there is no resuming either.
/// `headed` is anything with a `header(name) ?[]const u8`.
pub fn isTranscoded(headed: anytype) bool {
    const stored = headed.header("x-goog-stored-content-encoding") orelse return false;
    if (!std.ascii.eqlIgnoreCase(stored, "gzip")) return false;
    const sent = headed.header("content-encoding") orelse "identity";
    return std.ascii.eqlIgnoreCase(sent, "identity");
}

/// The crc32c value inside an `x-goog-hash` header, whose value is a
/// comma-separated list such as `crc32c=8P9ykg==,md5=...`, in either order.
/// Null when the list has no readable crc32c entry.
pub fn crc32cFromHashHeader(value: []const u8) ?u32 {
    var it = std.mem.splitScalar(u8, value, ',');
    while (it.next()) |raw| {
        const part = std.mem.trim(u8, raw, " \t");
        if (std.mem.startsWith(u8, part, "crc32c=")) {
            return core.crc32c.fromBase64(part["crc32c=".len..]) catch null;
        }
    }
    return null;
}

const testing = std.testing;
const test_util = @import("test_util.zig");

test "CappedAllocating collects up to its cap and tells why it stopped" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var sink: CappedAllocating = .init(arena.allocator(), 12);
    try sink.writer.writeAll("hello ");
    try sink.writer.writeAll("world\n");
    try testing.expectEqualStrings("hello world\n", sink.written());
    try testing.expect(!sink.over);

    // One more byte is one too many.
    try testing.expectError(error.WriteFailed, sink.writer.writeAll("!"));
    try testing.expect(sink.over);
    try testing.expect(!sink.out_of_memory);

    // A zero cap accepts only emptiness.
    var empty: CappedAllocating = .init(arena.allocator(), 0);
    try empty.writer.writeAll("");
    try testing.expectError(error.WriteFailed, empty.writer.writeAll("x"));
    try testing.expect(empty.over);
}

test "CappedAllocating reports the allocator failing as such" {
    var sink: CappedAllocating = .init(testing.failing_allocator, 100);
    try testing.expectError(error.WriteFailed, sink.writer.writeAll("data"));
    try testing.expect(sink.out_of_memory);
    try testing.expect(!sink.over);
}

test "formatRange writes both forms" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("bytes=0-9", formatRange(&buf, 0, 9));
    try testing.expectEqualStrings("bytes=5-", formatRange(&buf, 5, null));
    try testing.expectEqualStrings("bytes=18446744073709551615-", formatRange(&buf, std.math.maxInt(u64), null));
}

test "contentRangeStart reads what servers send" {
    try testing.expectEqual(5, contentRangeStart("bytes 5-14/100").?);
    try testing.expectEqual(0, contentRangeStart("bytes 0-0/1").?);
    try testing.expectEqual(7, contentRangeStart(" bytes  7-11/12").?);
    try testing.expectEqual(null, contentRangeStart(""));
    try testing.expectEqual(null, contentRangeStart("bytes */100"));
    try testing.expectEqual(null, contentRangeStart("items 5-14/100"));
    try testing.expectEqual(null, contentRangeStart("bytes x-14/100"));
}

const FakeHeaders = struct {
    stored: ?[]const u8 = null,
    sent: ?[]const u8 = null,
    fn header(self: FakeHeaders, name: []const u8) ?[]const u8 {
        if (std.ascii.eqlIgnoreCase(name, "x-goog-stored-content-encoding")) return self.stored;
        if (std.ascii.eqlIgnoreCase(name, "content-encoding")) return self.sent;
        return null;
    }
};

test "isTranscoded: only a gzip-stored object arriving plain" {
    try testing.expect(isTranscoded(FakeHeaders{ .stored = "gzip" }));
    try testing.expect(isTranscoded(FakeHeaders{ .stored = "GZIP", .sent = "identity" }));
    // Sent compressed as stored: the checksum covers exactly what arrived.
    try testing.expect(!isTranscoded(FakeHeaders{ .stored = "gzip", .sent = "gzip" }));
    try testing.expect(!isTranscoded(FakeHeaders{ .stored = "identity" }));
    try testing.expect(!isTranscoded(FakeHeaders{}));
}

test "crc32cFromHashHeader reads production's forms" {
    try testing.expectEqual(0xf0ff7292, crc32cFromHashHeader("crc32c=8P9ykg==,md5=b1kCrCNwJL3QwXbLkwY9xA==").?);
    try testing.expectEqual(0xf0ff7292, crc32cFromHashHeader("md5=b1kCrCNwJL3QwXbLkwY9xA==, crc32c=8P9ykg==").?);
    try testing.expectEqual(0xe3069283, crc32cFromHashHeader("crc32c=4waSgw==").?);
    try testing.expectEqual(null, crc32cFromHashHeader(""));
    try testing.expectEqual(null, crc32cFromHashHeader("md5=b1kCrCNwJL3QwXbLkwY9xA=="));
    try testing.expectEqual(null, crc32cFromHashHeader("crc32c=!!!"));
    try testing.expectEqual(null, crc32cFromHashHeader("crc32c="));
}

fn hashHeaderProperty(_: void, input: []const u8) !void {
    // Total on arbitrary header values, and round-trips a planted value.
    _ = crc32cFromHashHeader(input);
    var g: test_util.ByteGen = .init(input);
    const value = g.int(u32);
    var buf: [64]u8 = undefined;
    const header = try std.fmt.bufPrint(&buf, "md5=xx, crc32c={s}", .{&core.crc32c.toBase64(value)});
    try testing.expectEqual(value, crc32cFromHashHeader(header).?);
}

test "fuzz x-goog-hash parsing" {
    try test_util.fuzzBytes({}, hashHeaderProperty, .{ .corpus = &.{
        "crc32c=8P9ykg==",
        ",,,crc32c=",
        "crc32c = 8P9ykg==",
    } });
}
