//! `Owned(T)`: a call's result together with the memory that holds it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const WipingAllocator = @import("WipingAllocator.zig");

/// A result plus the arena that holds all of its memory, like `std.json.Parsed`.
/// One `deinit` frees everything; copy out anything needed after that.
pub fn Owned(comptime T: type) type {
    return struct {
        value: T,
        arena: *std.heap.ArenaAllocator,
        /// Set by `initWiping`: the arena and its wiping allocator, made
        /// together and freed together.
        wiping: ?*Wiping = null,

        const Self = @This();

        /// An empty arena for a result. The caller sets `value`.
        pub fn init(gpa: Allocator) Allocator.Error!Self {
            const arena = try gpa.create(std.heap.ArenaAllocator);
            arena.* = .init(gpa);
            return .{ .value = undefined, .arena = arena };
        }

        /// An empty arena for a result that holds a secret, such as a key:
        /// `deinit` zeroes every byte the arena held, the response it was
        /// decoded from included, before giving it back.
        pub fn initWiping(gpa: Allocator) Allocator.Error!Self {
            const w = try gpa.create(Wiping);
            w.wiping = .init(gpa);
            w.arena = .init(w.wiping.allocator());
            return .{ .value = undefined, .arena = &w.arena, .wiping = w };
        }

        pub fn deinit(self: *Self) void {
            if (self.wiping) |w| {
                const gpa = w.wiping.child;
                w.arena.deinit();
                gpa.destroy(w);
            } else {
                const gpa = self.arena.child_allocator;
                self.arena.deinit();
                gpa.destroy(self.arena);
            }
            self.* = undefined;
        }
    };
}

/// What `initWiping` makes in one allocation: the arena points at the
/// wiping allocator beside it, so neither may move.
pub const Wiping = struct {
    wiping: WipingAllocator,
    arena: std.heap.ArenaAllocator,
};

test "Owned frees everything with one deinit" {
    var owned: Owned([]const u8) = try .init(std.testing.allocator);
    owned.value = try owned.arena.allocator().dupe(u8, "hello");
    _ = try owned.arena.allocator().alloc(u8, 4096);
    try std.testing.expectEqualStrings("hello", owned.value);
    owned.deinit();
}

/// Fails the test when it is handed back a byte that is not zero.
const ZeroChecked = struct {
    child: Allocator,
    nonzero: usize = 0,

    fn allocator(self: *ZeroChecked) Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = Allocator.noResize,
            .remap = Allocator.noRemap,
            .free = free,
        } };
    }

    fn alloc(ptr: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *ZeroChecked = @ptrCast(@alignCast(ptr));
        return self.child.rawAlloc(len, alignment, ret_addr);
    }

    fn free(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *ZeroChecked = @ptrCast(@alignCast(ptr));
        for (memory) |b| if (b != 0) {
            self.nonzero += 1;
        };
        self.child.rawFree(memory, alignment, ret_addr);
    }
};

test "Owned.initWiping zeroes every byte the arena held, and frees it all" {
    var checked: ZeroChecked = .{ .child = std.testing.allocator };
    var owned: Owned([]const u8) = try .initWiping(checked.allocator());
    owned.value = try owned.arena.allocator().dupe(u8, "the secret");
    _ = try owned.arena.allocator().alloc(u8, 4096);
    try std.testing.expectEqualStrings("the secret", owned.value);
    owned.deinit();
    // The arena's chunks came back zeroed. The struct that held the
    // arena and its allocator holds no secret: its own bytes are not.
    var plain: ZeroChecked = .{ .child = std.testing.allocator };
    var unwiped: Owned([]const u8) = try .init(plain.allocator());
    unwiped.value = try unwiped.arena.allocator().dupe(u8, "the secret");
    unwiped.deinit();
    try std.testing.expect(plain.nonzero > checked.nonzero);
    try std.testing.expect(checked.nonzero <= @sizeOf(Wiping));
}

test "Owned.initWiping: every allocation failure is OutOfMemory, and nothing leaks" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(gpa: Allocator) !void {
            var owned: Owned([]const u8) = try .initWiping(gpa);
            defer owned.deinit();
            owned.value = try owned.arena.allocator().dupe(u8, "the secret");
        }
    }.run, .{});
}
