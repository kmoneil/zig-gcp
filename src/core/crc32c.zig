//! CRC-32C (Castagnoli): the checksum Google puts beside payload bytes.
//! Secret Manager stores one with every secret version, and Cloud Storage
//! reports one for every object.
//!
//! It is the standard library's CRC-32/ISCSI, which is the same polynomial,
//! initial value, reflection and final xor, under the name the API docs use.

const std = @import("std");
const test_util = @import("testing.zig");

/// The incremental form, for data that arrives in pieces.
pub const Hasher = std.hash.crc.Crc32Iscsi;

/// The CRC-32C of `data`. Google sends this value as a decimal string.
pub fn hash(data: []const u8) u32 {
    return Hasher.hash(data);
}

const testing = std.testing;

/// The definition, one bit at a time, with no table: the reflected form of
/// polynomial 0x1EDC6F41. Tests compare it against the implementation above,
/// so a change in std cannot quietly change what this module computes.
fn reference(data: []const u8) u32 {
    var crc: u32 = 0xffff_ffff;
    for (data) |byte| {
        crc ^= byte;
        for (0..8) |_| {
            crc = if (crc & 1 != 0) (crc >> 1) ^ 0x82f6_3b78 else crc >> 1;
        }
    }
    return ~crc;
}

test "the published check value and the RFC 3720 vectors" {
    // The check value every CRC-32C implementation states.
    try testing.expectEqual(0xe306_9283, hash("123456789"));
    try testing.expectEqual(0, hash(""));
    // RFC 3720 B.4, the iSCSI CRC test vectors.
    try testing.expectEqual(0x8a91_36aa, hash(&@as([32]u8, @splat(0))));
    try testing.expectEqual(0x62a8_ab43, hash(&@as([32]u8, @splat(0xff))));
    var ascending: [32]u8 = undefined;
    for (&ascending, 0..) |*b, i| b.* = @intCast(i);
    try testing.expectEqual(0x46dd_794e, hash(&ascending));
    var descending: [32]u8 = undefined;
    for (&descending, 0..) |*b, i| b.* = @intCast(31 - i);
    try testing.expectEqual(0x113f_db5c, hash(&descending));
}

test "the value Secret Manager's documentation uses" {
    // Google's data-integrity guide pairs the payload `s3cr3t` with the
    // checksum 825573743, which production confirms on every access.
    try testing.expectEqual(825_573_743, hash("s3cr3t"));
    // Sent on the wire as a decimal string.
    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("825573743", try std.fmt.bufPrint(&buf, "{d}", .{hash("s3cr3t")}));
}

test "every byte value, one at a time" {
    for (0..256) |i| {
        const byte: [1]u8 = .{@intCast(i)};
        try testing.expectEqual(reference(&byte), hash(&byte));
    }
    var all: [256]u8 = undefined;
    for (&all, 0..) |*b, i| b.* = @intCast(i);
    try testing.expectEqual(0x9c44_184b, hash(&all));
    try testing.expectEqual(reference(&all), hash(&all));
}

test "hashing in pieces matches hashing at once" {
    const data = "the quick brown fox jumps over the lazy dog";
    for (0..data.len + 1) |split| {
        var hasher: Hasher = .init();
        hasher.update(data[0..split]);
        hasher.update(data[split..]);
        try testing.expectEqual(hash(data), hasher.final());
    }
}

fn matchesReferenceProperty(_: void, input: []const u8) !void {
    const table_driven = hash(input);
    try testing.expectEqual(reference(input), table_driven);

    // Any split of the input hashes to the same value.
    var g: test_util.ByteGen = .init(input);
    const split = g.intRange(usize, 0, input.len);
    var hasher: Hasher = .init();
    hasher.update(input[0..split]);
    hasher.update(input[split..]);
    try testing.expectEqual(table_driven, hasher.final());

    // A checksum appended little-endian leaves the fixed residue, the
    // property that lets a receiver check data and checksum in one pass.
    var with_checksum: [test_util.max_fuzz_input + 4]u8 = undefined;
    @memcpy(with_checksum[0..input.len], input);
    std.mem.writeInt(u32, with_checksum[input.len..][0..4], table_driven, .little);
    try testing.expectEqual(0x48674bc7, hash(with_checksum[0 .. input.len + 4]));
}

test "fuzz crc32c: the table matches the definition, and splits do not matter" {
    try test_util.fuzzBytes({}, matchesReferenceProperty, .{ .corpus = &.{
        "",
        "123456789",
        "s3cr3t",
        "\x00\x00\x00\x00",
        "\xff\xff\xff\xff\xff\xff\xff\xff",
    } });
}
