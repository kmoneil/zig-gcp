//! Where requests go: production, `fake-gcs-server`, or a custom URL. What
//! makes a URL usable, and the host rules behind that, live in
//! `core.endpoint`.

const Endpoint = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const endpoint = @import("core").endpoint;

/// `scheme://host[:port]`. For the emulator a bare `host:port` works too,
/// and means plain HTTP.
url: []const u8,
/// Emulator endpoints never receive credentials and need no token provider.
emulator: bool = false,

pub const production: Endpoint = .{ .url = "https://storage.googleapis.com" };

/// The emulator named by `STORAGE_EMULATOR_HOST`, or null when that is
/// unset or blank. Other tools write the variable as `host:port`, as a full
/// URL, or with `/storage/v1` appended; all three name the same server, so
/// the path suffix is dropped here. The library never reads the environment
/// itself; pass `init.environ_map` from `main`.
pub fn fromEnv(environ: *const std.process.Environ.Map) ?Endpoint {
    const value = environ.get("STORAGE_EMULATOR_HOST") orelse return null;
    var host = std.mem.trim(u8, value, &std.ascii.whitespace);
    host = std.mem.trimEnd(u8, host, "/");
    if (std.ascii.endsWithIgnoreCase(host, "/storage/v1")) {
        host = host[0 .. host.len - "/storage/v1".len];
    }
    if (host.len == 0) return null;
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
    try expectBase("https://storage.googleapis.com", production);
    try expectBase("http://127.0.0.1:4443", .{ .url = "127.0.0.1:4443", .emulator = true });
    try expectBase("http://localhost:4443", .{ .url = "http://localhost:4443/", .emulator = true });
    try expectBase("http://[::1]:4443", .{ .url = "[::1]:4443", .emulator = true });
    // Only an emulator, which receives no credentials, defaults to http.
    try expectBase("https://localhost:4443", .{ .url = "localhost:4443" });
    try testing.expectError(error.InvalidEndpoint, (Endpoint{ .url = "ftp://host", .emulator = true }).baseUrl(testing.allocator));
}

test "fromEnv reads STORAGE_EMULATOR_HOST in all three community forms" {
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    try testing.expectEqual(null, fromEnv(&env));
    try env.put("STORAGE_EMULATOR_HOST", "  ");
    try testing.expectEqual(null, fromEnv(&env));

    try env.put("STORAGE_EMULATOR_HOST", "localhost:4443");
    try testing.expectEqualStrings("localhost:4443", fromEnv(&env).?.url);
    try testing.expect(fromEnv(&env).?.emulator);

    try env.put("STORAGE_EMULATOR_HOST", "http://localhost:4443");
    try testing.expectEqualStrings("http://localhost:4443", fromEnv(&env).?.url);

    // Some tools append the API prefix; the server is the same either way.
    try env.put("STORAGE_EMULATOR_HOST", "http://localhost:4443/storage/v1");
    try testing.expectEqualStrings("http://localhost:4443", fromEnv(&env).?.url);
    try env.put("STORAGE_EMULATOR_HOST", "localhost:4443/storage/v1/");
    try testing.expectEqualStrings("localhost:4443", fromEnv(&env).?.url);
    try env.put("STORAGE_EMULATOR_HOST", "/storage/v1");
    try testing.expectEqual(null, fromEnv(&env));
}
