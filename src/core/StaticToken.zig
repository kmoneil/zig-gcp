//! A token provider that always returns one token, such as the output of
//! `gcloud auth print-access-token`. Such tokens expire after about an hour.

const StaticToken = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const TokenProvider = @import("TokenProvider.zig");

/// Borrowed. Trim any trailing newline first.
token: []const u8,

/// The provider points at this struct, which must not move while the
/// provider is in use.
pub fn provider(self: *StaticToken) TokenProvider {
    return .{ .ptr = self, .vtable = &.{
        .getToken = getToken,
        .invalidate = invalidate,
        .quotaProject = quotaProject,
    } };
}

fn getToken(ptr: *anyopaque, io: std.Io, arena: Allocator, scopes: []const []const u8) TokenProvider.Error![]const u8 {
    _ = io;
    _ = scopes;
    const self: *StaticToken = @ptrCast(@alignCast(ptr));
    return arena.dupe(u8, self.token);
}

/// Nothing to drop: there is no cache, and no way to get a newer token.
fn invalidate(ptr: *anyopaque) void {
    _ = ptr;
}

fn quotaProject(ptr: *anyopaque) ?[]const u8 {
    _ = ptr;
    return null;
}

test "StaticToken returns a copy of its token in the arena" {
    var static: StaticToken = .{ .token = "ya29.abc" };
    const p = static.provider();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const scope = "https://www.googleapis.com/auth/cloud-platform";

    const token = try p.getToken(std.testing.io, arena.allocator(), &.{scope});
    try std.testing.expectEqualStrings("ya29.abc", token);
    try std.testing.expect(token.ptr != static.token.ptr);

    // invalidate changes nothing, and there is no quota project.
    p.invalidate();
    try std.testing.expectEqualStrings("ya29.abc", try p.getToken(std.testing.io, arena.allocator(), &.{scope}));
    try std.testing.expectEqual(null, p.quotaProject());
}

test "StaticToken reports a full arena" {
    var static: StaticToken = .{ .token = "ya29.abc" };
    try std.testing.expectError(
        error.OutOfMemory,
        static.provider().getToken(std.testing.io, std.testing.failing_allocator, &.{}),
    );
}
