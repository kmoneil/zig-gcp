//! Where requests go: production, the emulator, or a custom URL. What
//! makes a URL usable, and the host rules behind that, live in
//! `core.endpoint`.

const Endpoint = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const endpoint = @import("core").endpoint;

/// `scheme://host[:port]`. For the emulator a bare `host:port` works too,
/// and means plain HTTP.
url: []const u8,
/// An emulator endpoint never receives the caller's credentials. It gets
/// `Bearer owner` instead, the emulator's administrator, which listing
/// collection ids needs: without it the emulator answers 403 "Metadata
/// operations require admin authentication."
emulator: bool = false,

pub const production: Endpoint = .{ .url = "https://firestore.googleapis.com" };

/// The emulator named by `FIRESTORE_EMULATOR_HOST`, `host:port` by
/// Google's convention, or null when that is unset or blank. The library
/// never reads the environment itself; pass `init.environ_map` from
/// `main`.
pub fn fromEnv(environ: *const std.process.Environ.Map) ?Endpoint {
    const host = environ.get("FIRESTORE_EMULATOR_HOST") orelse return null;
    if (std.mem.trim(u8, host, &std.ascii.whitespace).len == 0) return null;
    return .{ .url = host, .emulator = true };
}

/// The base URL requests are built on: scheme, host and port, with no
/// trailing slash. Caller owns the result. `error.InvalidEndpoint` when the
/// URL is not plain `http` or `https` with a host and nothing else.
pub fn baseUrl(self: Endpoint, gpa: Allocator) error{ InvalidEndpoint, OutOfMemory }![]u8 {
    return endpoint.baseUrl(gpa, self.url, if (self.emulator) .http else .https);
}

const testing = std.testing;

fn expectBase(expected: []const u8, ep: Endpoint) !void {
    const got = try ep.baseUrl(testing.allocator);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(expected, got);
}

test "baseUrl: production, emulator forms, custom endpoints" {
    try expectBase("https://firestore.googleapis.com", production);
    try expectBase("http://127.0.0.1:8087", .{ .url = "127.0.0.1:8087", .emulator = true });
    try expectBase("http://localhost:8087", .{ .url = "http://localhost:8087/", .emulator = true });
    try expectBase("http://[::1]:8087", .{ .url = "[::1]:8087", .emulator = true });
    // Only an emulator defaults to http.
    try expectBase("https://localhost:8087", .{ .url = "localhost:8087" });
    try testing.expectError(error.InvalidEndpoint, (Endpoint{ .url = "ftp://host", .emulator = true }).baseUrl(testing.allocator));
}

test "fromEnv reads FIRESTORE_EMULATOR_HOST" {
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    try testing.expectEqual(null, fromEnv(&env));
    try env.put("FIRESTORE_EMULATOR_HOST", "  ");
    try testing.expectEqual(null, fromEnv(&env));
    try env.put("FIRESTORE_EMULATOR_HOST", "127.0.0.1:8087");
    const ep = fromEnv(&env).?;
    try testing.expectEqualStrings("127.0.0.1:8087", ep.url);
    try testing.expect(ep.emulator);
}
