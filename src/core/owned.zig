//! `Owned(T)`: a call's result together with the memory that holds it.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// A result plus the arena that holds all of its memory, like `std.json.Parsed`.
/// One `deinit` frees everything; copy out anything needed after that.
pub fn Owned(comptime T: type) type {
    return struct {
        value: T,
        arena: *std.heap.ArenaAllocator,

        const Self = @This();

        /// An empty arena for a result. The caller sets `value`.
        pub fn init(gpa: Allocator) Allocator.Error!Self {
            const arena = try gpa.create(std.heap.ArenaAllocator);
            arena.* = .init(gpa);
            return .{ .value = undefined, .arena = arena };
        }

        pub fn deinit(self: *Self) void {
            const gpa = self.arena.child_allocator;
            self.arena.deinit();
            gpa.destroy(self.arena);
            self.* = undefined;
        }
    };
}

test "Owned frees everything with one deinit" {
    var owned: Owned([]const u8) = try .init(std.testing.allocator);
    owned.value = try owned.arena.allocator().dupe(u8, "hello");
    _ = try owned.arena.allocator().alloc(u8, 4096);
    try std.testing.expectEqualStrings("hello", owned.value);
    owned.deinit();
}
