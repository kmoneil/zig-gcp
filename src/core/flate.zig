//! gzip, zlib and raw deflate decompression: `std.compress.flate.Decompress`
//! from Zig 0.16.0, fixed for input that ends partway, which std's panics
//! on in a safe build and reads past in `ReleaseFast`. See `Decompress.zig`
//! for what changed. The transport decompresses response bodies with it,
//! and `storage` the objects it stores gzip-compressed.

const std = @import("std");
const test_util = @import("testing.zig");

pub const Decompress = @import("flate/Decompress.zig");
pub const Container = std.compress.flate.Container;
/// What `Decompress.init` needs as its buffer.
pub const max_window_len = std.compress.flate.max_window_len;

const testing = std.testing;

/// Decompresses `input` whole, into `out`: the bytes, or the error the
/// decompressor recorded.
fn decompressAll(container: Container, input: []const u8, out: *std.Io.Writer.Allocating) !void {
    var in: std.Io.Reader = .fixed(input);
    var window: [max_window_len]u8 = undefined;
    var inflate: Decompress = .init(&in, container, &window);
    _ = inflate.reader.streamRemaining(&out.writer) catch |err| switch (err) {
        error.ReadFailed => return inflate.err orelse error.ReadFailed,
        error.WriteFailed => return error.WriteFailed,
    };
}

fn gzipAlloc(data: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = try .initCapacity(testing.allocator, 64);
    defer out.deinit();
    var window: [max_window_len]u8 = undefined;
    var compress: std.compress.flate.Compress = try .init(&out.writer, &window, .gzip, .default);
    try compress.writer.writeAll(data);
    try compress.finish();
    return out.toOwnedSlice();
}

test "the nightly's input, 19 bytes of gzip that end partway, is EndOfStream, where std panics" {
    // std.compress.flate.Decompress on these bytes: "panic: integer
    // overflow" in peekBitsEnding (nightly run 36230092734, 2026-09-26).
    const input = "\x1f\x8b\x08\x00\x00\x00\x00\xb5\x33\x8e\x2d\x00\x02\x29\xbd\xfb\x54\x0f\xcc";
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try testing.expectError(error.EndOfStream, decompressAll(.gzip, input, &out));
}

test "every prefix of a gzip stream is refused, or is the whole stream" {
    var text: std.Io.Writer.Allocating = .init(testing.allocator);
    defer text.deinit();
    for (0..400) |i| try text.writer.print("line {d}: a gzip stream cut at every byte\n", .{i});
    // Compressible text, and bytes that are not, so dynamic, fixed and
    // stored blocks all end somewhere in the middle.
    var noise: [3000]u8 = undefined;
    var prng: std.Random.DefaultPrng = .init(20260926);
    prng.random().bytes(&noise);
    for ([_][]const u8{ text.written(), &noise, "x", "" }) |plain| {
        const whole = try gzipAlloc(plain);
        defer testing.allocator.free(whole);
        for (0..whole.len + 1) |len| {
            var out: std.Io.Writer.Allocating = .init(testing.allocator);
            defer out.deinit();
            if (decompressAll(.gzip, whole[0..len], &out)) |_| {
                errdefer std.debug.print("a prefix of {d} of {d} bytes decompressed\n", .{ len, whole.len });
                try testing.expectEqual(whole.len, len);
                try testing.expectEqualSlices(u8, plain, out.written());
            } else |err| {
                errdefer std.debug.print("a prefix of {d} of {d} bytes: {t}\n", .{ len, whole.len, err });
                try testing.expect(len < whole.len);
            }
        }
    }
}

/// Any bytes, as any container: decompressed, or refused with an error,
/// never a panic, whatever the bytes and wherever they end.
fn anyInput(_: void, input: []const u8) !void {
    for ([_]Container{ .gzip, .zlib, .raw }) |container| {
        var out: std.Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        decompressAll(container, input, &out) catch {};
    }
}

test "fuzz flate: any bytes, as gzip, zlib or raw deflate, decompress or are refused" {
    try test_util.fuzzBytes({}, anyInput, .{
        .corpus = &.{
            "",
            "\x1f\x8b",
            // The nightly's input.
            "\x1f\x8b\x08\x00\x00\x00\x00\xb5\x33\x8e\x2d\x00\x02\x29\xbd\xfb\x54\x0f\xcc",
            // gzip -n of "hello world\n", whole and cut.
            "\x1f\x8b\x08\x00\x00\x00\x00\x00\x02\xff\xcb\x48\xcd\xc9\xc9\x57\x28\xcf\x2f\xca\x49\xe1\x02\x00\x2d\x3b\x08\xaf\x0c\x00\x00\x00",
            "\x1f\x8b\x08\x00\x00\x00\x00\x00\x02\xff\xcb\x48\xcd\xc9\xc9\x57\x28",
        },
    });
}

test {
    _ = Decompress;
}
