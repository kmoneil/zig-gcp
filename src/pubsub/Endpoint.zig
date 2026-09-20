//! Where requests go: production, the emulator, or a custom URL such as a
//! regional endpoint. What makes a URL usable, and the host rules behind
//! that, live in `core.endpoint`.

const Endpoint = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const endpoint = @import("core").endpoint;

/// `scheme://host[:port]`. For the emulator a bare `host:port` works too,
/// and means plain HTTP.
url: []const u8,
/// Emulator endpoints never receive credentials and need no token provider.
emulator: bool = false,

pub const production: Endpoint = .{ .url = "https://pubsub.googleapis.com" };

/// The emulator named by `PUBSUB_EMULATOR_HOST`, or null when that is unset
/// or blank. The library never reads the environment itself; pass
/// `init.environ_map` from `main`.
pub fn fromEnv(environ: *const std.process.Environ.Map) ?Endpoint {
    const host = environ.get("PUBSUB_EMULATOR_HOST") orelse return null;
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
    try expectBase("https://pubsub.googleapis.com", production);
    try expectBase("http://127.0.0.1:8085", .{ .url = "127.0.0.1:8085", .emulator = true });
    try expectBase("http://localhost:8085", .{ .url = "http://localhost:8085/", .emulator = true });
    try expectBase("http://[::1]:8085", .{ .url = "[::1]:8085", .emulator = true });
    try expectBase("https://us-east1-pubsub.googleapis.com", .{ .url = "us-east1-pubsub.googleapis.com" });
    // Only an emulator, which receives no credentials, defaults to http.
    try expectBase("https://localhost:8085", .{ .url = "localhost:8085" });
    try testing.expectError(error.InvalidEndpoint, (Endpoint{ .url = "ftp://host", .emulator = true }).baseUrl(testing.allocator));
}

test "fromEnv reads PUBSUB_EMULATOR_HOST" {
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    try testing.expectEqual(null, fromEnv(&env));
    try env.put("PUBSUB_EMULATOR_HOST", "  ");
    try testing.expectEqual(null, fromEnv(&env));
    try env.put("PUBSUB_EMULATOR_HOST", "localhost:8085");
    const ep = fromEnv(&env).?;
    try testing.expect(ep.emulator);
    try testing.expectEqualStrings("localhost:8085", ep.url);
}
