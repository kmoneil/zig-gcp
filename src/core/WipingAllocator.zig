//! An allocator that zeroes memory before giving it back to the allocator
//! beneath it, for buffers that hold secrets: tokens, refresh tokens,
//! client secrets, and bodies that carry them. Put an arena on top, and
//! every chunk the arena frees is wiped.
//!
//! It never shrinks or moves an allocation in place, since either would
//! hand bytes back unwiped. A caller that shrinks or moves falls back to
//! allocating, copying and freeing, and the free wipes.

const WipingAllocator = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;
const test_util = @import("testing.zig");

child: Allocator,

pub fn init(child: Allocator) WipingAllocator {
    return .{ .child = child };
}

/// The allocator points at this struct, which must not move while in use.
pub fn allocator(self: *WipingAllocator) Allocator {
    return .{ .ptr = self, .vtable = &.{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    } };
}

fn fromPtr(ptr: *anyopaque) *WipingAllocator {
    return @ptrCast(@alignCast(ptr));
}

fn alloc(ptr: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
    return fromPtr(ptr).child.rawAlloc(len, alignment, ret_addr);
}

fn resize(ptr: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
    // A shrink would return the tail unwiped, and wiping it first would
    // destroy bytes the caller still owns if the child then refused.
    if (new_len < memory.len) return false;
    return fromPtr(ptr).child.rawResize(memory, alignment, new_len, ret_addr);
}

fn remap(ptr: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
    // A move would leave the old copy behind unwiped: grow in place or not at all.
    return if (resize(ptr, memory, alignment, new_len, ret_addr)) memory.ptr else null;
}

fn free(ptr: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
    std.crypto.secureZero(u8, memory);
    fromPtr(ptr).child.rawFree(memory, alignment, ret_addr);
}

const testing = std.testing;

test "WipingAllocator: freed memory is zeroed before the child gets it back" {
    // A fixed buffer underneath keeps freed memory where the test can read it.
    var backing: [256]u8 = @splat(0xAA);
    var fba: std.heap.FixedBufferAllocator = .init(&backing);
    var wiping: WipingAllocator = .init(fba.allocator());
    const a = wiping.allocator();

    const secret = try a.dupe(u8, "ya29.secret-token");
    const at = @intFromPtr(secret.ptr) - @intFromPtr(&backing);
    a.free(secret);
    try testing.expect(std.mem.allEqual(u8, backing[at..][0.."ya29.secret-token".len], 0));
}

test "WipingAllocator: a shrink is refused, so the smaller copy is new and the old one wiped" {
    var backing: [256]u8 = @splat(0);
    var fba: std.heap.FixedBufferAllocator = .init(&backing);
    var wiping: WipingAllocator = .init(fba.allocator());
    const a = wiping.allocator();

    const secret = "0123456789abcdefghijklmnopqrstuv";
    const buf = try a.dupe(u8, secret);
    const at = @intFromPtr(buf.ptr) - @intFromPtr(&backing);
    try testing.expect(!a.resize(buf, 8));
    const smaller = try a.realloc(buf, 8);
    defer a.free(smaller);
    try testing.expectEqualStrings(secret[0..8], smaller);
    // Zero, not just changed: in safe builds std itself overwrites freed
    // memory with a debug pattern, which would hide a missing wipe.
    try testing.expect(std.mem.allEqual(u8, backing[at..][0..secret.len], 0));
}

test "WipingAllocator: growing in place keeps the data" {
    var backing: [256]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&backing);
    var wiping: WipingAllocator = .init(fba.allocator());
    const a = wiping.allocator();

    const buf = try a.dupe(u8, "abcdefgh");
    // The fixed buffer can grow its last allocation in place.
    try testing.expect(a.resize(buf, 16));
    const grown: []u8 = buf.ptr[0..16];
    try testing.expectEqualStrings("abcdefgh", grown[0..8]);
    a.free(grown);
}

test "WipingAllocator: an arena on top wipes every chunk when it is freed" {
    var backing: [64 * 1024]u8 = @splat(0);
    var fba: std.heap.FixedBufferAllocator = .init(&backing);
    var wiping: WipingAllocator = .init(fba.allocator());
    var arena: std.heap.ArenaAllocator = .init(wiping.allocator());
    for (0..40) |i| {
        // Sizes that outgrow the first chunk, so the arena takes several.
        const buf = try arena.allocator().alloc(u8, 64 + i * 37);
        @memset(buf, 'S');
    }
    const used = fba.end_index;
    arena.deinit();
    try testing.expect(std.mem.allEqual(u8, backing[0..used], 0));
}

fn nothingSurvivesProperty(_: void, input: []const u8) !void {
    var backing: [4096]u8 = @splat(0);
    var fba: std.heap.FixedBufferAllocator = .init(&backing);
    var wiping: WipingAllocator = .init(fba.allocator());
    const a = wiping.allocator();
    var g: test_util.ByteGen = .init(input);
    var live: [8][]u8 = @splat(&.{});
    // The fixed buffer hands out memory from the front, so everything ever
    // allocated lies below the high-water mark.
    var high_water: usize = 0;
    while (g.pos < g.bytes.len) {
        const slot = g.intRange(usize, 0, live.len - 1);
        const len = g.intRange(usize, 0, 300);
        switch (g.intRange(u8, 0, 2)) {
            0 => {
                a.free(live[slot]);
                live[slot] = a.alloc(u8, len) catch &.{};
            },
            1 => live[slot] = a.realloc(live[slot], len) catch live[slot],
            else => {
                a.free(live[slot]);
                live[slot] = &.{};
            },
        }
        // Every byte written is nonzero, so a leftover one would show.
        @memset(live[slot], 0x5A);
        high_water = @max(high_water, fba.end_index);
    }
    for (live) |buf| a.free(buf);
    // Zero, not just changed: in safe builds std itself overwrites freed
    // memory with a debug pattern, which would hide a missing wipe.
    try testing.expect(std.mem.allEqual(u8, backing[0..high_water], 0));
}

test "fuzz WipingAllocator: nothing written survives a free" {
    try test_util.fuzzBytes({}, nothingSurvivesProperty, .{ .corpus = &.{
        "\x00\x00\x00\x40\x00\x00\x00\x00\x01\x00\x00\x08",
        "\x03\x00\x00\xff\x00\x01\x03\x00\x00\x10\x02\x03\x00\x00\x00",
    } });
}
