//! What Google's OAuth token endpoint and the metadata server send back:
//! `{"access_token", "expires_in", "token_type"}` with a token, and
//! `{"error", "error_description"}` when the token endpoint refuses. The
//! error shape differs from the Google API one: `error` is a string here.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Cache = @import("Cache.zig");

pub const ParseError = error{ InvalidTokenResponse, OutOfMemory };

const parse_options: std.json.ParseOptions = .{
    .ignore_unknown_fields = true,
    .duplicate_field_behavior = .use_last,
    .allocate = .alloc_if_needed,
};

/// The token and its lifetime from a success body. The cache checks that
/// both are usable. The token may point into `body`.
pub fn parse(arena: Allocator, body: []const u8) ParseError!Cache.Fetched {
    const Wire = struct {
        access_token: ?[]const u8 = null,
        expires_in: ?i64 = null,
        token_type: ?[]const u8 = null,
    };
    const wire = std.json.parseFromSliceLeaky(Wire, arena, body, parse_options) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidTokenResponse,
    };
    const token = wire.access_token orelse return error.InvalidTokenResponse;
    const expires_in = wire.expires_in orelse return error.InvalidTokenResponse;
    // A token of another type would not work as a bearer token.
    if (wire.token_type) |t| if (!std.ascii.eqlIgnoreCase(t, "Bearer")) return error.InvalidTokenResponse;
    return .{ .token = token, .expires_in = expires_in };
}

/// An OAuth error, such as `invalid_grant`.
pub const OAuthError = struct {
    code: []const u8,
    /// "" when the server sent none.
    description: []const u8,
};

/// The OAuth error in `body`, or null when the body is not one.
pub fn parseError(arena: Allocator, body: []const u8) Allocator.Error!?OAuthError {
    const Wire = struct {
        @"error": ?[]const u8 = null,
        error_description: ?[]const u8 = null,
    };
    const wire = std.json.parseFromSliceLeaky(Wire, arena, body, parse_options) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    const code = wire.@"error" orelse return null;
    return .{ .code = code, .description = wire.error_description orelse "" };
}

const testing = std.testing;
const test_util = @import("core").testing;

test "token_response: a token and its lifetime" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const got = try parse(a,
        \\{"access_token": "ya29.a0-token", "expires_in": 3599,
        \\ "scope": "https://www.googleapis.com/auth/cloud-platform", "token_type": "Bearer"}
    );
    try testing.expectEqualStrings("ya29.a0-token", got.token);
    try testing.expectEqual(3599, got.expires_in);
    // The metadata server sends no scope; either may leave out the type.
    _ = try parse(a, "{\"access_token\":\"t\",\"expires_in\":1}");
    _ = try parse(a, "{\"access_token\":\"t\",\"expires_in\":1,\"token_type\":\"bearer\"}");
    // std.json reads an integral number however it is written.
    try testing.expectEqual(3599, (try parse(a, "{\"access_token\":\"t\",\"expires_in\":\"3599\"}")).expires_in);
    try testing.expectEqual(3599, (try parse(a, "{\"access_token\":\"t\",\"expires_in\":3599.0}")).expires_in);
}

test "token_response: a body without a usable token is InvalidTokenResponse" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{
        "{\"expires_in\":3599}",
        "{\"access_token\":\"t\"}",
        "{\"access_token\":\"t\",\"expires_in\":3599.5}",
        "{\"access_token\":\"t\",\"expires_in\":99999999999999999999}",
        "{\"access_token\":\"t\",\"expires_in\":3599,\"token_type\":\"mac\"}",
        "{\"access_token\":42,\"expires_in\":3599}",
        "<html>Bad Gateway</html>",
        "",
    }) |body| try testing.expectError(error.InvalidTokenResponse, parse(a, body));
}

test "token_response: OAuth errors" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const e = (try parseError(a, "{\"error\":\"invalid_grant\",\"error_description\":\"Token has been expired or revoked.\"}")).?;
    try testing.expectEqualStrings("invalid_grant", e.code);
    try testing.expectEqualStrings("Token has been expired or revoked.", e.description);
    try testing.expectEqualStrings("", (try parseError(a, "{\"error\":\"invalid_client\"}")).?.description);
    // The Google API shape, and bodies that are no error at all.
    try testing.expectEqual(null, try parseError(a, "{\"error\":{\"code\":400,\"status\":\"INVALID_ARGUMENT\"}}"));
    try testing.expectEqual(null, try parseError(a, "{}"));
    try testing.expectEqual(null, try parseError(a, "<html></html>"));
}

fn arbitraryProperty(_: void, input: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    // Total: every body yields a value, null or InvalidTokenResponse.
    _ = parse(arena.allocator(), input) catch |err| try testing.expectEqual(error.InvalidTokenResponse, err);
    _ = try parseError(arena.allocator(), input);
}

test "fuzz token_response: arbitrary bodies never crash" {
    try test_util.fuzzBytes({}, arbitraryProperty, .{ .corpus = &.{
        "{\"access_token\":\"t\",\"expires_in\":3599,\"token_type\":\"Bearer\"}",
        "{\"error\":\"invalid_grant\",\"error_description\":\"x\"}",
        "{\"access_token\":\"\\ud800\",\"expires_in\":-1}",
    } });
}
