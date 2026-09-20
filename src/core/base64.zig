//! Base64 as Google's JSON APIs use it: `bytes` fields travel as base64
//! strings, a Pub/Sub message's data and a secret's payload alike.
//!
//! Encoding is standard and padded, which is what proto3 JSON emits.
//! Decoding accepts what a proto3 JSON parser must: padded or not, standard
//! or URL-safe.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Stringify = std.json.Stringify;
const test_util = @import("testing.zig");

pub const Error = error{ InvalidBase64, OutOfMemory };

/// Decodes base64 with or without padding. Accepts the URL-safe alphabet too,
/// as proto3 JSON parsers must, but not a mix of the two alphabets.
pub fn decode(arena: Allocator, text: []const u8) Error![]u8 {
    const url_safe = std.mem.indexOfAny(u8, text, "-_") != null;
    const padded = text.len % 4 == 0 and std.mem.endsWith(u8, text, "=");
    const codecs = if (url_safe)
        if (padded) std.base64.url_safe else std.base64.url_safe_no_pad
    else if (padded) std.base64.standard else std.base64.standard_no_pad;
    const size = codecs.Decoder.calcSizeForSlice(text) catch return error.InvalidBase64;
    const out = try arena.alloc(u8, size);
    codecs.Decoder.decode(out, text) catch return error.InvalidBase64;
    return out;
}

/// How many bytes `data` takes as a padded base64 string, without the quotes.
pub fn encodedLen(byte_count: usize) usize {
    return std.base64.standard.Encoder.calcSize(byte_count);
}

/// Streams `data` into a JSON document as a base64 string, with no
/// intermediate copy. Secret bytes pass straight from the caller's slice to
/// the writer's buffer.
pub fn writeJsonString(jw: *Stringify, data: []const u8) Stringify.Error!void {
    try jw.beginWriteRaw();
    try jw.writer.writeByte('"');
    try std.base64.standard.Encoder.encodeWriter(jw.writer, data);
    try jw.writer.writeByte('"');
    jw.endWriteRaw();
}

const testing = std.testing;

test "padding, alphabets and rejects" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("", try decode(a, ""));
    try testing.expectEqualStrings("hi", try decode(a, "aGk="));
    try testing.expectEqualStrings("hi", try decode(a, "aGk"));
    try testing.expectEqualStrings("h", try decode(a, "aA=="));
    try testing.expectEqualStrings("h", try decode(a, "aA"));
    // The payload Google's own data-integrity guide uses.
    try testing.expectEqualStrings("s3cr3t", try decode(a, "czNjcjN0"));
    for ([_][]const u8{ "a", "aGk==", "a=Gk", "+-", "aGk=\n", " aGk", "====", "aGk*" }) |bad| {
        try testing.expectError(error.InvalidBase64, decode(a, bad));
    }
}

test "encodedLen matches the encoder" {
    for ([_]usize{ 0, 1, 2, 3, 4, 63, 64, 65, 65_536 }) |n| {
        try testing.expectEqual(std.base64.standard.Encoder.calcSize(n), encodedLen(n));
    }
}

test "writeJsonString emits a quoted base64 string" {
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var jw: Stringify = .{ .writer = &w, .options = .{} };
    try jw.beginObject();
    try jw.objectField("data");
    try writeJsonString(&jw, "s3cr3t");
    try jw.endObject();
    try testing.expectEqualStrings("{\"data\":\"czNjcjN0\"}", w.buffered());
}

const base64_variants = [_]std.base64.Codecs{
    std.base64.standard,
    std.base64.standard_no_pad,
    std.base64.url_safe,
    std.base64.url_safe_no_pad,
};

fn roundTripProperty(_: void, input: []const u8) !void {
    var g: test_util.ByteGen = .init(input);
    const codecs = base64_variants[g.intRange(usize, 0, 3)];
    const data = g.rest();
    var encoded_buf: [std.base64.standard.Encoder.calcSize(test_util.max_fuzz_input)]u8 = undefined;
    const encoded = codecs.Encoder.encode(&encoded_buf, data);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualSlices(u8, data, try decode(arena.allocator(), encoded));
    try testing.expectEqual(std.base64.standard.Encoder.calcSize(data.len), encodedLen(data.len));
}

test "fuzz base64: every encoding variant decodes back" {
    try test_util.fuzzBytes({}, roundTripProperty, .{ .corpus = &.{
        "\x00\x00\x00\x00\x00\x00\x00\x00",
        "\x00\x00\x00\x00\x00\x00\x00\x01\xfb\xff",
        "\x00\x00\x00\x00\x00\x00\x00\x02hello",
        "\x00\x00\x00\x00\x00\x00\x00\x03\x00\x00",
    } });
}

fn arbitraryProperty(_: void, input: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const decoded = decode(a, input) catch |err| switch (err) {
        error.InvalidBase64 => return,
        else => return err,
    };
    // Whatever it accepts is consistent: re-encode and decode again.
    const again = try a.alloc(u8, encodedLen(decoded.len));
    try testing.expectEqualSlices(u8, decoded, try decode(a, std.base64.standard.Encoder.encode(again, decoded)));
}

test "fuzz base64: arbitrary input never crashes" {
    try test_util.fuzzBytes({}, arbitraryProperty, .{ .corpus = &.{ "aGk=", "aGk", "-_", "a===", "=", "aGk*", "AAAA", "czNjcjN0" } });
}
