//! Where requests go: turning a configured endpoint into the base URL a
//! client builds every path on.
//!
//! The host is checked against what std's resolver can actually use. A host
//! it cannot, such as a 64-character label, trips assertions deep inside std
//! on the first call instead of failing here.

const std = @import("std");
const Allocator = std.mem.Allocator;
const test_util = @import("testing.zig");

/// What to assume when the configured endpoint names no scheme. Credentials
/// never travel in cleartext, so only an endpoint that receives none, such
/// as an emulator, defaults to `http`.
pub const Scheme = enum { https, http };

/// The base URL requests are built on: scheme, host and port, with no
/// trailing slash. Caller owns the result. `error.InvalidEndpoint` unless
/// the result is plain `http` or `https` with a host and nothing else.
pub fn baseUrl(gpa: Allocator, endpoint: []const u8, default_scheme: Scheme) error{ InvalidEndpoint, OutOfMemory }![]u8 {
    const trimmed = std.mem.trim(u8, endpoint, &std.ascii.whitespace);
    const url = std.mem.trimEnd(u8, trimmed, "/");
    // The host ends up in the request line and Host header.
    for (url) |c| if (c <= ' ' or c >= 0x7f) return error.InvalidEndpoint;

    const has_scheme = std.mem.indexOf(u8, url, "://") != null;
    const scheme = if (has_scheme) "" else switch (default_scheme) {
        .https => "https://",
        .http => "http://",
    };
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
/// IPv6 literal.
pub fn isValidHost(host: []const u8) bool {
    if (host.len > 2 and host[0] == '[' and host[host.len - 1] == ']') {
        _ = std.Io.net.Ip6Address.parse(host[1 .. host.len - 1], 0) catch return false;
        return true;
    }
    std.Io.net.HostName.validate(host) catch return false;
    return true;
}

const testing = std.testing;

fn expectBase(expected: []const u8, endpoint: []const u8, default_scheme: Scheme) !void {
    const got = try baseUrl(testing.allocator, endpoint, default_scheme);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(expected, got);
}

test "baseUrl: hosts, ports, schemes and trailing slashes" {
    try expectBase("https://secretmanager.googleapis.com", "secretmanager.googleapis.com", .https);
    try expectBase("https://pubsub.googleapis.com", "https://pubsub.googleapis.com", .https);
    try expectBase("http://127.0.0.1:8085", "127.0.0.1:8085", .http);
    try expectBase("http://localhost:8085", "http://localhost:8085/", .http);
    try expectBase("http://[::1]:8085", "[::1]:8085", .http);
    try expectBase("http://localhost:8085", " localhost:8085\n", .http);
    try expectBase("https://proxy:8443", "https://proxy:8443", .https);
    // A scheme in the endpoint wins over the default, either way.
    try expectBase("http://proxy.internal", "http://proxy.internal", .https);
    try expectBase("https://secure.internal", "https://secure.internal", .http);
    // Schemes are case-insensitive, but std.http needs them lowercase.
    try expectBase("http://127.0.0.1:8085", "HTTP://127.0.0.1:8085", .http);
    try expectBase("https://pubsub.googleapis.com", "HtTpS://pubsub.googleapis.com", .https);
}

test "baseUrl: rejects what cannot be a base URL" {
    for ([_][]const u8{
        "",
        "ftp://host",
        "http://",
        "http://host/v1",
        "http://host?q=1",
        "http://host#f",
        "http://user:pw@host",
        "host:notaport",
        "host\r\nX-Injected: 1",
        "ho st:8085",
        "host:8085\x00",
        // Regressions: these once passed and then tripped assertions in std's
        // resolver on the first call.
        "a" ** 64 ++ ":8085",
        ("abcdefgh." ** 29) ++ "x:8085",
        "%61%61%61:8085",
        "[::1:8085",
        "[not-ipv6]:8085",
        "host_name:8085",
    }) |endpoint| {
        if (baseUrl(testing.allocator, endpoint, .http)) |got| {
            defer testing.allocator.free(got);
            std.debug.print("accepted {s} as {s}\n", .{ endpoint, got });
            return error.TestUnexpectedSuccess;
        } else |err| try testing.expectEqual(error.InvalidEndpoint, err);
    }
}

fn baseUrlProperty(_: void, input: []const u8) !void {
    var g: test_util.ByteGen = .init(input);
    const scheme: Scheme = if (g.boolean()) .http else .https;
    const url = baseUrl(testing.allocator, g.rest(), scheme) catch |err| {
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
    const again = try baseUrl(testing.allocator, url, scheme);
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
        "\x00secretmanager.europe-west3.rep.googleapis.com",
    } });
}
