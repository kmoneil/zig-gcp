//! CRC-32C (Castagnoli): the checksum Google puts beside payload bytes.
//! Secret Manager stores one with every secret version, and Cloud Storage
//! reports one for every object.
//!
//! The answers are the standard library's CRC-32/ISCSI, which is the same
//! polynomial, initial value, reflection and final xor under the name the
//! API docs use, at many times its speed. Where the build's CPU has CRC32C
//! instructions, aarch64's `crc32cx` or x86_64's SSE4.2 `crc32q`, they run
//! three streams at once; everywhere else eight tables do, eight bytes at a
//! time. The build chooses, at compile time, and Zig has no per-function
//! target, so a baseline build cannot carry the instructions: aarch64's
//! assembler and the self-hosted x86_64 backend refuse them for a CPU
//! without them, and LLVM's x86_64 assembler takes them, for a CPU that
//! would fault on them. Measured on an Apple M5 Max on
//! 2026-09-25, in ReleaseFast: std's one table 570 MiB/s, the eight tables
//! 3.0 GiB/s, the instructions 27 GiB/s.

const std = @import("std");
const builtin = @import("builtin");
const test_util = @import("testing.zig");

/// How this build computes a CRC-32C.
pub const Implementation = enum {
    /// The CPU's CRC32C instructions, three streams at once.
    hardware,
    /// Eight tables, eight bytes at a time, on any target.
    software,
};

/// Decided by the build's target CPU. `zig build` for the machine at hand
/// takes the instructions where it has them, as does any `-Dcpu` that
/// names them, such as `x86_64_v2`; a baseline build takes the tables.
pub const implementation: Implementation = if (has_instructions) .hardware else .software;

const has_instructions = switch (builtin.cpu.arch) {
    .aarch64 => std.Target.aarch64.featureSetHas(builtin.cpu.features, .crc),
    .x86_64 => std.Target.x86.featureSetHas(builtin.cpu.features, .crc32),
    else => false,
};

/// The incremental form, for data that arrives in pieces.
pub const Hasher = struct {
    /// The CRC register, which starts inverted and is inverted again at the
    /// end.
    register: u32 = 0xffff_ffff,

    pub fn init() Hasher {
        return .{};
    }

    pub fn update(self: *Hasher, bytes: []const u8) void {
        // Instructions cannot run at comptime, where std's CRC could, and
        // callers compute checksums of fixed bytes there.
        self.register = if (has_instructions and !@inComptime()) hardware(self.register, bytes) else software(self.register, bytes);
    }

    pub fn final(self: Hasher) u32 {
        return ~self.register;
    }

    pub fn hash(bytes: []const u8) u32 {
        var hasher: Hasher = .init();
        hasher.update(bytes);
        return hasher.final();
    }
};

/// The CRC-32C of `data`. Google sends this value as a decimal string.
pub fn hash(data: []const u8) u32 {
    return Hasher.hash(data);
}

/// The CRC-32C of `data` by the tables, whatever this build's CPU: the same
/// answer as `hash`, for tests and benchmarks that hold the two apart.
pub fn hashSoftware(data: []const u8) u32 {
    return ~software(0xffff_ffff, data);
}

/// The form Cloud Storage sends: standard base64, with padding, of the four
/// checksum bytes in big-endian order. `0xE3069283` is "4waSgw==".
pub fn toBase64(value: u32) [8]u8 {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .big);
    var out: [8]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&out, &bytes);
    return out;
}

/// The checksum behind its base64 form. Anything that is not exactly four
/// big-endian bytes in standard base64 is `error.InvalidCrc32c`.
pub fn fromBase64(text: []const u8) error{InvalidCrc32c}!u32 {
    const decoder = std.base64.standard.Decoder;
    const len = decoder.calcSizeForSlice(text) catch return error.InvalidCrc32c;
    if (len != 4) return error.InvalidCrc32c;
    var bytes: [4]u8 = undefined;
    decoder.decode(&bytes, text) catch return error.InvalidCrc32c;
    return std.mem.readInt(u32, &bytes, .big);
}

/// The CRC-32C of `a ++ b`, from the CRC-32C of each and the length of `b`:
/// how the checksums of parts hashed apart, on different tasks and in any
/// order, become the whole's with no second pass over the bytes. The CRC of
/// nothing is 0, so folding the parts' CRCs into 0, in order, gives the
/// whole.
///
/// zlib's `crc32_combine` on this polynomial, with one difference: zlib's
/// polynomial comes back to x after 32 squarings, and this one after 31, so
/// the table below has 31 entries and wraps at 31. With zlib's wrap, every
/// `len_b` of 512 MiB or more gave a wrong answer.
pub fn combine(crc_a: u32, crc_b: u32, len_b: u64) u32 {
    // Appending n bytes multiplies a CRC by x^(8n); x2nModP(n, 3) is that.
    return multModP(x2nModP(len_b, 3), crc_a) ^ crc_b;
}

/// The polynomial, reflected: bit 31 is x^0.
const poly: u32 = 0x82f6_3b78;

/// a(x) times b(x) modulo the polynomial, both reflected (zlib's `multmodp`).
fn multModP(a: u32, b_start: u32) u32 {
    var b = b_start;
    var m: u32 = 1 << 31;
    var p: u32 = 0;
    while (true) {
        if (a & m != 0) {
            p ^= b;
            if (a & (m - 1) == 0) break;
        }
        m >>= 1;
        b = if (b & 1 != 0) (b >> 1) ^ poly else b >> 1;
    }
    return p;
}

/// x^(2^k) modulo the polynomial, for k from 0 to 30. Squaring x 31 times
/// gives x again, so x^(2^k) is x^(2^(k mod 31)) and 31 entries serve every k.
const x2n_table: [31]u32 = table: {
    @setEvalBranchQuota(100_000);
    var table: [31]u32 = undefined;
    var p: u32 = 1 << 30; // x^1
    table[0] = p;
    for (1..31) |k| {
        p = multModP(p, p);
        table[k] = p;
    }
    break :table table;
};

/// x^(n * 2^k) modulo the polynomial (zlib's `x2nmodp`), for k below 31.
fn x2nModP(n_start: u64, k_start: u32) u32 {
    var n = n_start;
    var k = k_start;
    var p: u32 = 1 << 31; // x^0
    while (n != 0) : (n >>= 1) {
        if (n & 1 != 0) p = multModP(x2n_table[k], p);
        k = (k + 1) % 31;
    }
    return p;
}

/// Slicing-by-8: the classic byte table, and seven more, each a byte
/// further along, so eight bytes fold into the register with eight lookups.
const tables: [8][256]u32 = tables: {
    @setEvalBranchQuota(20_000);
    var t: [8][256]u32 = undefined;
    for (0..256) |i| {
        var c: u32 = i;
        for (0..8) |_| c = if (c & 1 != 0) (c >> 1) ^ poly else c >> 1;
        t[0][i] = c;
    }
    for (1..8) |k| {
        for (0..256) |i| t[k][i] = (t[k - 1][i] >> 8) ^ t[0][t[k - 1][i] & 0xff];
    }
    break :tables t;
};

/// Bytes into the register, one at a time.
fn bytewise(register: u32, bytes: []const u8) u32 {
    var crc = register;
    for (bytes) |b| crc = tables[0][(crc ^ b) & 0xff] ^ (crc >> 8);
    return crc;
}

/// Bytes into the register, eight at a time through the tables.
fn software(register: u32, bytes: []const u8) u32 {
    var crc = register;
    var rest = bytes;
    while (rest.len >= 8) : (rest = rest[8..]) {
        const lo = std.mem.readInt(u32, rest[0..4], .little) ^ crc;
        const hi = std.mem.readInt(u32, rest[4..8], .little);
        crc = tables[7][lo & 0xff] ^ tables[6][(lo >> 8) & 0xff] ^ tables[5][(lo >> 16) & 0xff] ^ tables[4][lo >> 24] ^
            tables[3][hi & 0xff] ^ tables[2][(hi >> 8) & 0xff] ^ tables[1][(hi >> 16) & 0xff] ^ tables[0][hi >> 24];
    }
    return bytewise(crc, rest);
}

/// What each of the three streams takes per block.
const lane = 4096;

/// Appending `lane` bytes multiplies a register by this: `combine`'s shift,
/// for the one length the streams need.
const lane_shift: u32 = shift: {
    @setEvalBranchQuota(20_000);
    break :shift x2nModP(lane, 3);
};

/// Bytes into the register by the CPU's instructions. Each instruction waits
/// on the one before it, so whole blocks go as three streams over three
/// neighbouring lanes, joined as `combine` joins parts; the rest goes eight
/// bytes at a time, and the last few through the table, since the
/// self-hosted x86_64 backend cannot encode the one-byte instruction.
fn hardware(register: u32, bytes: []const u8) u32 {
    var crc = register;
    var rest = bytes;
    while (rest.len >= 3 * lane) : (rest = rest[3 * lane ..]) {
        var a = crc;
        var b: u32 = 0;
        var c: u32 = 0;
        var i: usize = 0;
        while (i < lane) : (i += 8) {
            a = word(a, std.mem.readInt(u64, rest[i..][0..8], .little));
            b = word(b, std.mem.readInt(u64, rest[lane + i ..][0..8], .little));
            c = word(c, std.mem.readInt(u64, rest[2 * lane + i ..][0..8], .little));
        }
        crc = multModP(lane_shift, multModP(lane_shift, a) ^ b) ^ c;
    }
    while (rest.len >= 8) : (rest = rest[8..]) crc = word(crc, std.mem.readInt(u64, rest[0..8], .little));
    return bytewise(crc, rest);
}

/// Eight bytes, little-endian in `value`, into the register.
inline fn word(register: u32, value: u64) u32 {
    return switch (builtin.cpu.arch) {
        .aarch64 => asm ("crc32cx %[out:w], %[crc:w], %[value:x]"
            : [out] "=r" (-> u32),
            : [crc] "r" (register),
              [value] "r" (value),
        ),
        .x86_64 => @truncate(asm ("crc32q %[value], %[out]"
            : [out] "=r" (-> u64),
            : [value] "r" (value),
              [in] "0" (@as(u64, register)),
        )),
        else => @compileError("no CRC32C instruction on this architecture"),
    };
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

/// std's CRC-32/ISCSI: one table, a byte at a time, and none of the code
/// above. The oracle at lengths the bit-at-a-time `reference` is too slow
/// for.
const Oracle = std.hash.crc.Crc32Iscsi;

fn expectBothPaths(data: []const u8) !void {
    errdefer std.debug.print("{d} bytes at address {x}\n", .{ data.len, @intFromPtr(data.ptr) });
    const want = Oracle.hash(data);
    try testing.expectEqual(want, hash(data));
    try testing.expectEqual(want, hashSoftware(data));
}

test "both paths give std's answer at every length to 64, at every alignment, and around each block" {
    var buf: [12 * lane + 128]u8 = undefined;
    var prng: std.Random.DefaultPrng = .init(0x6372_6333_3263);
    prng.random().bytes(&buf);
    const edges = [_]usize{ lane - 1, lane, lane + 1, 3 * lane - 8, 3 * lane - 1, 3 * lane, 3 * lane + 1, 3 * lane + 7, 3 * lane + 8, 6 * lane, 6 * lane + 13, 12 * lane + 63 };
    for (0..8) |offset| {
        for (0..65) |len| try expectBothPaths(buf[offset..][0..len]);
        for (edges) |len| try expectBothPaths(buf[offset..][0..len]);
    }
}

test "a checksum at comptime, as std's could be" {
    const at_comptime = comptime hash("123456789");
    try testing.expectEqual(0xe306_9283, at_comptime);
    const long = comptime blk: {
        @setEvalBranchQuota(200_000);
        const bytes: [3 * lane + 5]u8 = @splat(0x5a);
        break :blk hash(&bytes);
    };
    const bytes: [3 * lane + 5]u8 = @splat(0x5a);
    try testing.expectEqual(hash(&bytes), long);
}

test "the build's CPU picks the path" {
    const expected: Implementation = switch (builtin.cpu.arch) {
        .aarch64 => if (std.Target.aarch64.featureSetHas(builtin.cpu.features, .crc)) .hardware else .software,
        .x86_64 => if (std.Target.x86.featureSetHas(builtin.cpu.features, .crc32)) .hardware else .software,
        else => .software,
    };
    try testing.expectEqual(expected, implementation);
}

/// Past one block of three streams and well into the next, at any
/// alignment, split into up to four updates anywhere.
fn pathsProperty(_: void, input: []const u8) !void {
    var g: test_util.ByteGen = .init(input);
    var buf: [5 * lane + 8]u8 = undefined;
    const offset = g.intRange(u8, 0, 7);
    const len = g.intRange(u16, 0, 5 * lane);
    var prng: std.Random.DefaultPrng = .init(g.int(u64));
    const data = buf[offset..][0..len];
    prng.random().bytes(data);
    try expectBothPaths(data);
    var hasher: Hasher = .init();
    var at: u16 = 0;
    for (0..3) |_| {
        const end = g.intRange(u16, at, len);
        hasher.update(data[at..end]);
        at = end;
    }
    hasher.update(data[at..]);
    try testing.expectEqual(Oracle.hash(data), hasher.final());
}

test "fuzz crc32c paths: both, at any length, alignment and split, give std's answer" {
    try test_util.fuzzBytes({}, pathsProperty, .{
        .corpus = &.{
            // One block of three streams exactly, whole.
            "\x00\x30\x00\x00\x00\x00\x00\x00\x00\x00\x01",
            // A block and a 7-byte tail, split inside the second lane and the tail.
            "\x05\x30\x07\x00\x00\x00\x00\x00\x00\x00\x02\x10\x01\x20\x02\x00\x00",
            // The longest, at the last alignment, split on the block's edges.
            "\x07\x50\x00\x00\x00\x00\x00\x00\x00\x00\x03\x00\x01\x2f\xff\x00\x01",
        },
    });
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

test "base64 form: the documented values, both directions" {
    // The check value, from Google's hashes-and-etags guide.
    try testing.expectEqualStrings("4waSgw==", &toBase64(0xe306_9283));
    try testing.expectEqual(0xe306_9283, try fromBase64("4waSgw=="));
    // "hello world\n", the storage spec's fixture object.
    try testing.expectEqual(0xf0ff_7292, hash("hello world\n"));
    try testing.expectEqualStrings("8P9ykg==", &toBase64(hash("hello world\n")));
    // The empty input.
    try testing.expectEqualStrings("AAAAAA==", &toBase64(hash("")));
    try testing.expectEqual(0, try fromBase64("AAAAAA=="));
}

test "fromBase64 rejects what is not a checksum" {
    for ([_][]const u8{
        "", "=", "====", "4waSg", "4waSgw", "4waSgw==x", "4waSgw=", "!!!!!!==",
        "AAAAAAAA", // Six bytes, not four.
        "AAA=", // Two bytes.
        "4waSgw==\n",
    }) |bad| {
        try testing.expectError(error.InvalidCrc32c, fromBase64(bad));
    }
}

fn base64RoundTrip(_: void, input: []const u8) !void {
    var g: test_util.ByteGen = .init(input);
    const value = g.int(u32);
    try testing.expectEqual(value, try fromBase64(&toBase64(value)));
    // Arbitrary text never crashes the decoder.
    _ = fromBase64(g.rest()) catch {};
}

test "fuzz crc32c base64 round-trips" {
    try test_util.fuzzBytes({}, base64RoundTrip, .{ .corpus = &.{
        "\xe3\x06\x92\x834waSgw==",
        "\x00\x00\x00\x00AAAAAA==",
        "\xff\xff\xff\xff@@@@@@==",
    } });
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

/// zlib 1.2.11's `crc32_combine`: a 32 by 32 matrix over GF(2), squared
/// once per bit of the length. Slower, and it assumes nothing about the
/// period `combine`'s table relies on, which makes it the oracle for
/// lengths no test can hash. With `len_b` 0 it returns `crc_a`, which is
/// `combine`'s answer too whenever `crc_b` is the CRC of nothing, 0.
fn matrixCombine(crc_a: u32, crc_b: u32, len_b: u64) u32 {
    const Matrix = [32]u32;
    const times = struct {
        fn apply(mat: *const Matrix, vec_start: u32) u32 {
            var vec = vec_start;
            var sum: u32 = 0;
            var i: usize = 0;
            while (vec != 0) : (i += 1) {
                if (vec & 1 != 0) sum ^= mat[i];
                vec >>= 1;
            }
            return sum;
        }
        fn square(out: *Matrix, mat: *const Matrix) void {
            for (out, mat) |*row, m| row.* = apply(mat, m);
        }
    };
    if (len_b == 0) return crc_a;
    var crc = crc_a;
    var len = len_b;
    // The operator for one zero bit, then two, then four: squared up to a
    // byte before the loop starts.
    var even: Matrix = undefined;
    var odd: Matrix = undefined;
    odd[0] = poly;
    var row: u32 = 1;
    for (odd[1..]) |*r| {
        r.* = row;
        row <<= 1;
    }
    times.square(&even, &odd);
    times.square(&odd, &even);
    while (true) {
        times.square(&even, &odd);
        if (len & 1 != 0) crc = times.apply(&even, crc);
        len >>= 1;
        if (len == 0) break;
        times.square(&odd, &even);
        if (len & 1 != 0) crc = times.apply(&odd, crc);
        len >>= 1;
        if (len == 0) break;
    }
    return crc ^ crc_b;
}

/// The CRC-32C of `n` zero bytes, by doubling from one zero byte with
/// `combineFn`.
fn zeroRun(n: u64, combineFn: *const fn (u32, u32, u64) u32) u32 {
    var result: u32 = 0;
    var piece = hash(&.{0});
    var piece_len: u64 = 1;
    var left = n;
    while (left != 0) {
        if (left & 1 != 0) result = combineFn(result, piece, piece_len);
        left >>= 1;
        if (left == 0) break;
        piece = combineFn(piece, piece, piece_len);
        piece_len *= 2;
    }
    return result;
}

test "combine: every split, and parts folded into nothing" {
    for ([_][]const u8{ "123456789", "hello world\n", "" }) |data| {
        for (0..data.len + 1) |split| {
            try testing.expectEqual(hash(data), combine(hash(data[0..split]), hash(data[split..]), data.len - split));
        }
    }
    // Three parts, folded in order into the CRC of nothing.
    const data = "the quick brown fox jumps over the lazy dog";
    var acc: u32 = 0;
    for ([_][]const u8{ data[0..10], data[10..11], data[11..] }) |part| acc = combine(acc, hash(part), part.len);
    try testing.expectEqual(hash(data), acc);
    // Appending nothing, and nothing before.
    try testing.expectEqual(0xe306_9283, combine(0xe306_9283, 0, 0));
    try testing.expectEqual(0xe306_9283, combine(0, 0xe306_9283, 9));
}

test "combine: runs of zeros up to 5 GiB, against std hashing real zeros" {
    // Each CRC was measured on 2026-09-24 by feeding that many real zero
    // bytes through std's Crc32Iscsi, which knows nothing of `combine`.
    // Doubling from one byte reaches every table index and lengths past
    // 32 bits. With zlib's wrap at 32, every run from 512 MiB was wrong.
    const runs = [_]struct { len: u64, crc: u32 }{
        .{ .len = 1 << 28, .crc = 0x02f6_3b78 },
        .{ .len = 1 << 29, .crc = 0x038d_26c4 },
        .{ .len = 1 << 30, .crc = 0x036e_6f75 },
        .{ .len = 1 << 31, .crc = 0x527d_5351 },
        .{ .len = 1 << 32, .crc = 0xf161_77d2 },
        .{ .len = 5 << 30, .crc = 0x2cc5_f6d6 },
    };
    for (runs) |run| {
        errdefer std.debug.print("{d} zero bytes\n", .{run.len});
        try testing.expectEqual(run.crc, zeroRun(run.len, combine));
        try testing.expectEqual(run.crc, zeroRun(run.len, matrixCombine));
    }
    // A run short enough to hash here.
    const zeros: [5000]u8 = @splat(0);
    try testing.expectEqual(hash(&zeros), zeroRun(zeros.len, combine));
}

test "combine: squaring x comes back to x after 31 steps, not zlib's 32" {
    var p: u32 = 1 << 30; // x
    for (1..32) |step| {
        p = multModP(p, p);
        // Not before the 31st: the table would then be shorter still.
        try testing.expectEqual(step == 31, p == 1 << 30);
    }
}

fn combineProperty(_: void, input: []const u8) !void {
    var g: test_util.ByteGen = .init(input);
    // Against the matrix oracle, at lengths up to 2^64 - 1. The CRC of no
    // bytes is 0, so only that `crc_b` goes with a zero length.
    const crc_a = g.int(u32);
    const len = g.int(u64) >> g.int(u6);
    const crc_b = if (len == 0) 0 else g.int(u32);
    try testing.expectEqual(matrixCombine(crc_a, crc_b, len), combine(crc_a, crc_b, len));

    // Against hashing the whole, for the rest of the input split anywhere.
    const data = g.rest();
    const split = crc_a % (data.len + 1);
    try testing.expectEqual(hash(data), combine(hash(data[0..split]), hash(data[split..]), data.len - split));
}

test "fuzz crc32c combine: splits, and the matrix method, agree" {
    try test_util.fuzzBytes({}, combineProperty, .{
        .corpus = &.{
            "",
            // A length of 2^29, the first zlib's wrap got wrong.
            "\x00\x00\x00\x07\x00\x00\x00\x00\x20\x00\x00\x00\x00\x12\x34\x56\x78hello world\n",
            "\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\x00\xde\xad\xbe\xef",
        },
    });
}
