//! `Change(T)`: what an update does to a setting that can be taken away.

/// What an update does to a setting that can be taken away.
pub fn Change(comptime T: type) type {
    return union(enum) {
        /// Not part of the update: stays as it is.
        keep,
        set: T,
        /// Taken away, or back to the service's default: each field says
        /// which.
        clear,
    };
}

test "Change is keep, set or clear, and keep is the default a field names" {
    const std = @import("std");
    const Settings = struct { key: Change([]const u8) = .keep };
    const unchanged: Settings = .{};
    try std.testing.expect(unchanged.key == .keep);
    const set: Settings = .{ .key = .{ .set = "k" } };
    try std.testing.expectEqualStrings("k", set.key.set);
    const cleared: Settings = .{ .key = .clear };
    try std.testing.expect(cleared.key == .clear);
}
