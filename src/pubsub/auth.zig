//! The token-provider seam. Loading credentials (metadata server, key files,
//! refresh tokens) belongs to a separate auth package; this client only asks
//! a provider for a bearer token before each request.

const std = @import("std");

/// Supplies OAuth bearer tokens, in the `std.mem.Allocator` interface shape.
pub const TokenProvider = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const Error = error{
        /// The provider could not produce a usable token.
        TokenUnavailable,
        Canceled,
        OutOfMemory,
    };

    pub const VTable = struct {
        /// Returns a bearer token valid for at least the next request. The
        /// provider owns caching and refresh. The token must stay valid until
        /// the next call on the same provider.
        getToken: *const fn (ptr: *anyopaque, io: std.Io, scopes: []const []const u8) Error![]const u8,
    };

    pub fn getToken(self: TokenProvider, io: std.Io, scopes: []const []const u8) Error![]const u8 {
        return self.vtable.getToken(self.ptr, io, scopes);
    }
};

/// The OAuth scope the client asks for.
pub const scope = "https://www.googleapis.com/auth/pubsub";

/// A provider that always returns one token, such as the output of
/// `gcloud auth print-access-token`. Such tokens expire after about an hour.
pub const StaticToken = struct {
    /// Borrowed. Trim any trailing newline first.
    token: []const u8,

    pub fn provider(self: *StaticToken) TokenProvider {
        return .{ .ptr = self, .vtable = &.{ .getToken = getToken } };
    }

    fn getToken(ptr: *anyopaque, io: std.Io, scopes: []const []const u8) TokenProvider.Error![]const u8 {
        _ = io;
        _ = scopes;
        const self: *StaticToken = @ptrCast(@alignCast(ptr));
        return self.token;
    }
};

/// Whether `token` can go into an HTTP header: non-empty, visible ASCII.
/// A token read from a command's output often ends in a newline.
pub fn isValidToken(token: []const u8) bool {
    if (token.len == 0) return false;
    for (token) |c| if (c <= ' ' or c >= 0x7f) return false;
    return true;
}

test "StaticToken returns its token" {
    var static: StaticToken = .{ .token = "ya29.abc" };
    const p = static.provider();
    try std.testing.expectEqualStrings("ya29.abc", try p.getToken(std.testing.io, &.{scope}));
}

test "isValidToken rejects what would break the header" {
    try std.testing.expect(isValidToken("ya29.a0AfB_byC-9x"));
    try std.testing.expect(!isValidToken(""));
    try std.testing.expect(!isValidToken("ya29.abc\n"));
    try std.testing.expect(!isValidToken("a b"));
    try std.testing.expect(!isValidToken("abc\r\nX-Injected: 1"));
    try std.testing.expect(!isValidToken("t\xc3\xa9"));
}
