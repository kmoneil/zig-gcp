//! Supplies OAuth bearer tokens, in the `std.mem.Allocator` interface shape:
//! a pointer plus a table of functions. A service module asks for a token
//! before each request. Where the token comes from (a pasted string, the
//! metadata server, gcloud's login) is the provider's business.

const TokenProvider = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const transport = @import("transport.zig");
const test_util = @import("testing.zig");

ptr: *anyopaque,
vtable: *const VTable,

/// Every way getting a token can fail. Closed, so that a service's own error
/// set can include it and callers can still switch on every case.
pub const Error = error{
    /// The provider could not produce a usable token, for a reason not
    /// listed here.
    TokenUnavailable,
    /// The refresh token was revoked or has expired. Nothing but logging in
    /// again fixes it, as with `gcloud auth application-default login`.
    RefreshTokenInvalid,
    /// The token endpoint refused the request for a reason other than a
    /// dead refresh token.
    TokenEndpointRejected,
    /// No metadata server answered, or no service account is attached to
    /// the workload.
    MetadataUnavailable,
    /// A token response lacked a usable token or lifetime.
    InvalidTokenResponse,
} || transport.Error;

pub const VTable = struct {
    /// Returns a bearer token valid for at least the next request, copied
    /// into `arena`: the copy cannot change under the caller, even when the
    /// provider replaces its cached token. The provider owns caching and
    /// refresh. `scopes` is advisory: most credentials fix their scopes when
    /// they are issued.
    getToken: *const fn (
        ptr: *anyopaque,
        io: std.Io,
        arena: Allocator,
        scopes: []const []const u8,
    ) Error![]const u8,
    /// Drops any cached token, so the next `getToken` fetches a new one.
    /// Services call this after an HTTP 401.
    invalidate: *const fn (ptr: *anyopaque) void,
    /// The project to charge for quota, sent as `x-goog-user-project`, or
    /// null. User credentials name one; service accounts do not need one.
    quotaProject: *const fn (ptr: *anyopaque) ?[]const u8,
};

pub fn getToken(self: TokenProvider, io: std.Io, arena: Allocator, scopes: []const []const u8) Error![]const u8 {
    return self.vtable.getToken(self.ptr, io, arena, scopes);
}

pub fn invalidate(self: TokenProvider) void {
    self.vtable.invalidate(self.ptr);
}

pub fn quotaProject(self: TokenProvider) ?[]const u8 {
    return self.vtable.quotaProject(self.ptr);
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

fn isValidTokenProperty(_: void, input: []const u8) !void {
    // The rule, stated independently: non-empty, every byte visible ASCII.
    var visible = input.len > 0;
    for (input) |c| visible = visible and c >= '!' and c <= '~';
    try std.testing.expectEqual(visible, isValidToken(input));
    // So an accepted token can never end the header line or start another.
    if (isValidToken(input)) try std.testing.expect(std.mem.indexOfAny(u8, input, "\r\n\x00 \t") == null);
}

test "fuzz isValidToken: accepts exactly non-empty visible ASCII" {
    try test_util.fuzzBytes({}, isValidTokenProperty, .{ .corpus = &.{
        "ya29.a0AfB_byC-9x",
        "",
        " ",
        "!",
        "~",
        "\x7f",
        "abc\r\nX-Injected: 1",
        "t\xc3\xa9",
        "tok\x00en",
    } });
}

test "the wrappers pass their arguments through" {
    const Recording = struct {
        arena_seen: ?Allocator = null,
        scopes_seen: []const []const u8 = &.{},
        invalidated: usize = 0,

        fn provider(self: *@This()) TokenProvider {
            return .{ .ptr = self, .vtable = &.{
                .getToken = getTokenFn,
                .invalidate = invalidateFn,
                .quotaProject = quotaProjectFn,
            } };
        }
        fn getTokenFn(ptr: *anyopaque, io: std.Io, arena: Allocator, scopes: []const []const u8) Error![]const u8 {
            _ = io;
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.arena_seen = arena;
            self.scopes_seen = scopes;
            return arena.dupe(u8, "ya29.recorded");
        }
        fn invalidateFn(ptr: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.invalidated += 1;
        }
        fn quotaProjectFn(ptr: *anyopaque) ?[]const u8 {
            _ = ptr;
            return "billing-project";
        }
    };

    var recording: Recording = .{};
    const p = recording.provider();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const scopes: []const []const u8 = &.{"https://www.googleapis.com/auth/cloud-platform"};

    try std.testing.expectEqualStrings("ya29.recorded", try p.getToken(std.testing.io, arena.allocator(), scopes));
    try std.testing.expectEqual(arena.allocator().ptr, recording.arena_seen.?.ptr);
    try std.testing.expectEqual(scopes.ptr, recording.scopes_seen.ptr);
    p.invalidate();
    p.invalidate();
    try std.testing.expectEqual(2, recording.invalidated);
    try std.testing.expectEqualStrings("billing-project", p.quotaProject().?);
}
