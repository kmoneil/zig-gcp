//! A token provider that always returns one token, such as the output of
//! `gcloud auth print-access-token`. Such tokens expire after about an hour.

const StaticToken = @This();

const std = @import("std");
const TokenProvider = @import("TokenProvider.zig");

/// Borrowed. Trim any trailing newline first.
token: []const u8,

/// The provider points at this struct, which must not move while the
/// provider is in use.
pub fn provider(self: *StaticToken) TokenProvider {
    return .{ .ptr = self, .vtable = &.{ .getToken = getToken } };
}

fn getToken(ptr: *anyopaque, io: std.Io, scopes: []const []const u8) TokenProvider.Error![]const u8 {
    _ = io;
    _ = scopes;
    const self: *StaticToken = @ptrCast(@alignCast(ptr));
    return self.token;
}

test "StaticToken returns its token" {
    var static: StaticToken = .{ .token = "ya29.abc" };
    const p = static.provider();
    const scope = "https://www.googleapis.com/auth/cloud-platform";
    try std.testing.expectEqualStrings("ya29.abc", try p.getToken(std.testing.io, &.{scope}));
}
