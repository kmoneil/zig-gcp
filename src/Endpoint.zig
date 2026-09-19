//! Where requests go: production, the emulator, or a custom URL such as a
//! regional endpoint.

const Endpoint = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const test_util = @import("test_util.zig");

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
    const trimmed = std.mem.trim(u8, self.url, &std.ascii.whitespace);
    const url = std.mem.trimEnd(u8, trimmed, "/");
    // The host ends up in the request line and Host header.
    for (url) |c| if (c <= ' ' or c >= 0x7f) return error.InvalidEndpoint;

    const has_scheme = std.mem.indexOf(u8, url, "://") != null;
    const scheme = if (has_scheme) "" else if (self.emulator) "http://" else "https://";
    const full = try std.mem.concat(gpa, u8, &.{ scheme, url });
    errdefer gpa.free(full);

    const uri = std.Uri.parse(full) catch return error.InvalidEndpoint;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "http") and !std.ascii.eqlIgnoreCase(uri.scheme, "https")) {
        return error.InvalidEndpoint;
    }
    // std.http matches schemes case-sensitively; schemes are case-insensitive.
    _ = std.ascii.lowerString(full[0..uri.scheme.len], full[0..uri.scheme.len]);
    const host = switch (uri.host orelse return error.InvalidEndpoint) {
        .raw, .percent_encoded => |h| h,
    };
    if (!isValidHost(host)) return error.InvalidEndpoint;
    if (!uri.path.isEmpty() or uri.query != null or uri.fragment != null or
        uri.user != null or uri.password != null)
    {
        return error.InvalidEndpoint;
    }
    return full;
}

/// A DNS name or IPv4 address that std's resolver accepts, or a bracketed
/// IPv6 literal. Anything else, such as a 64-character label, trips
/// assertions deep in std's resolver instead of failing cleanly.
fn isValidHost(host: []const u8) bool {
    if (host.len > 2 and host[0] == '[' and host[host.len - 1] == ']') {
        _ = std.Io.net.Ip6Address.parse(host[1 .. host.len - 1], 0) catch return false;
        return true;
    }
    std.Io.net.HostName.validate(host) catch return false;
    return true;
}

const testing = std.testing;

fn expectBase(expected: []const u8, endpoint: Endpoint) !void {
    const got = try endpoint.baseUrl(testing.allocator);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(expected, got);
}

test "baseUrl: production, emulator forms, custom endpoints" {
    try expectBase("https://pubsub.googleapis.com", production);
    try expectBase("http://127.0.0.1:8085", .{ .url = "127.0.0.1:8085", .emulator = true });
    try expectBase("http://localhost:8085", .{ .url = "http://localhost:8085/", .emulator = true });
    try expectBase("http://[::1]:8085", .{ .url = "[::1]:8085", .emulator = true });
    try expectBase("http://localhost:8085", .{ .url = " localhost:8085\n", .emulator = true });
    try expectBase("https://us-east1-pubsub.googleapis.com", .{ .url = "us-east1-pubsub.googleapis.com" });
    try expectBase("https://proxy:8443", .{ .url = "https://proxy:8443" });
    // Schemes are case-insensitive, but std.http needs them lowercase.
    try expectBase("http://127.0.0.1:8085", .{ .url = "HTTP://127.0.0.1:8085", .emulator = true });
    try expectBase("https://pubsub.googleapis.com", .{ .url = "HtTpS://pubsub.googleapis.com" });
}

test "baseUrl: rejects what cannot be a base URL" {
    for ([_]Endpoint{
        .{ .url = "", .emulator = true },
        .{ .url = "ftp://host", .emulator = true },
        .{ .url = "http://", .emulator = true },
        .{ .url = "http://host/v1", .emulator = true },
        .{ .url = "http://host?q=1", .emulator = true },
        .{ .url = "http://host#f", .emulator = true },
        .{ .url = "http://user:pw@host", .emulator = true },
        .{ .url = "host:notaport", .emulator = true },
        .{ .url = "host\r\nX-Injected: 1", .emulator = true },
        .{ .url = "ho st:8085", .emulator = true },
        .{ .url = "host:8085\x00", .emulator = true },
        // Regressions: these once passed and then tripped assertions in std's
        // resolver on the first call.
        .{ .url = "a" ** 64 ++ ":8085", .emulator = true },
        .{ .url = ("abcdefgh." ** 29) ++ "x:8085", .emulator = true },
        .{ .url = "%61%61%61:8085", .emulator = true },
        .{ .url = "[::1:8085", .emulator = true },
        .{ .url = "[not-ipv6]:8085", .emulator = true },
        .{ .url = "host_name:8085", .emulator = true },
    }) |endpoint| {
        if (endpoint.baseUrl(testing.allocator)) |got| {
            defer testing.allocator.free(got);
            std.debug.print("accepted {s} as {s}\n", .{ endpoint.url, got });
            return error.TestUnexpectedSuccess;
        } else |err| try testing.expectEqual(error.InvalidEndpoint, err);
    }
}

test "fromEnv reads PUBSUB_EMULATOR_HOST" {
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    try testing.expectEqual(null, fromEnv(&env));
    try env.put("PUBSUB_EMULATOR_HOST", "  ");
    try testing.expectEqual(null, fromEnv(&env));
    try env.put("PUBSUB_EMULATOR_HOST", "localhost:8085");
    const endpoint = fromEnv(&env).?;
    try testing.expect(endpoint.emulator);
    try testing.expectEqualStrings("localhost:8085", endpoint.url);
}

fn baseUrlProperty(_: void, input: []const u8) !void {
    var g: test_util.ByteGen = .init(input);
    const endpoint: Endpoint = .{ .emulator = g.boolean(), .url = g.rest() };
    const url = endpoint.baseUrl(testing.allocator) catch |err| {
        try testing.expectEqual(error.InvalidEndpoint, err);
        return;
    };
    defer testing.allocator.free(url);
    // A result is printable, parses back with a host std can resolve, and
    // is its own normal form.
    for (url) |c| try testing.expect(c > ' ' and c < 0x7f);
    try testing.expect(!std.mem.endsWith(u8, url, "/"));
    const uri = try std.Uri.parse(url);
    try testing.expect(std.mem.eql(u8, uri.scheme, "http") or std.mem.eql(u8, uri.scheme, "https"));
    var host_buf: [std.Io.net.HostName.max_len]u8 = undefined;
    _ = try uri.getHost(&host_buf);
    const again = try (Endpoint{ .url = url, .emulator = endpoint.emulator }).baseUrl(testing.allocator);
    defer testing.allocator.free(again);
    try testing.expectEqualStrings(url, again);
}

test "fuzz baseUrl: never crashes; results are stable and printable" {
    try test_util.fuzzBytes({}, baseUrlProperty, .{ .corpus = &.{
        "\x01127.0.0.1:8085",
        "\x01http://localhost:8085/",
        "\x00https://pubsub.googleapis.com",
        "\x01[::1]:8085",
        "\x01http://h:8085//",
        "\x00a://b",
    } });
}
