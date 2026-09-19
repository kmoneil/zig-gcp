//! Supplies OAuth bearer tokens, in the `std.mem.Allocator` interface shape:
//! a pointer plus a table of functions. A service module asks for a token
//! before each request. Where the token comes from (a pasted string, the
//! metadata server, gcloud's login) is the provider's business.

const TokenProvider = @This();

const std = @import("std");

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

/// Whether `token` can go into an HTTP header: non-empty, visible ASCII.
/// A token read from a command's output often ends in a newline.
pub fn isValidToken(token: []const u8) bool {
    if (token.len == 0) return false;
    for (token) |c| if (c <= ' ' or c >= 0x7f) return false;
    return true;
}

test "isValidToken rejects what would break the header" {
    try std.testing.expect(isValidToken("ya29.a0AfB_byC-9x"));
    try std.testing.expect(!isValidToken(""));
    try std.testing.expect(!isValidToken("ya29.abc\n"));
    try std.testing.expect(!isValidToken("a b"));
    try std.testing.expect(!isValidToken("abc\r\nX-Injected: 1"));
    try std.testing.expect(!isValidToken("t\xc3\xa9"));
}
