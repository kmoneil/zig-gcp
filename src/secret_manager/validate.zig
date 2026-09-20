//! Client-side checks, run before any request: the API's fixed limits and
//! the naming rules. Only cheap, fixed rules are checked; the server has the
//! final word on everything else, and its messages are good.
//!
//! The rules are from Google's documentation and were measured against
//! production on 2026-09-20: a 65,536-byte payload is stored and one byte
//! more is refused, an empty payload is refused, an id with a `.` is
//! refused, and 260 characters are refused.

const std = @import("std");
const test_util = @import("test_util.zig");

/// The most a secret version can hold, counted before base64.
pub const max_payload_bytes = 64 * 1024;

/// The longest secret id or version alias.
pub const max_id_len = 255;

/// Secret ids: 1 to 255 characters from `[A-Za-z0-9_-]`. Production's error
/// message quotes `[a-zA-Z_0-9]+`, but hyphens are accepted, and Google's
/// documentation lists them.
pub fn isSecretId(id: []const u8) bool {
    if (id.len == 0 or id.len > max_id_len) return false;
    for (id) |c| switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '_' => {},
        else => return false,
    };
    return true;
}

/// Version aliases follow the same rule as ids, and may not be a number,
/// which would name a version, or the word `latest`.
pub fn isAlias(alias: []const u8) bool {
    if (!isSecretId(alias)) return false;
    if (std.mem.eql(u8, alias, "latest")) return false;
    for (alias) |c| if (!std.ascii.isDigit(c)) return true;
    return false;
}

/// Location ids such as `europe-west3`: a lowercase letter, then lowercase
/// letters, digits and hyphens, ending in a letter or digit. The value goes
/// into a host name, so anything else could send requests elsewhere.
pub fn isLocation(location: []const u8) bool {
    if (location.len == 0 or location.len > 63) return false;
    if (!std.ascii.isLower(location[0])) return false;
    if (location[location.len - 1] == '-') return false;
    for (location) |c| switch (c) {
        'a'...'z', '0'...'9', '-' => {},
        else => return false,
    };
    return true;
}

/// Printable ASCII, so the value can go in a header.
pub fn isUserAgent(user_agent: []const u8) bool {
    if (user_agent.len == 0) return false;
    for (user_agent) |c| if (c < ' ' or c >= 0x7f) return false;
    return true;
}

const testing = std.testing;

test "secret ids" {
    try testing.expect(isSecretId("db-password"));
    try testing.expect(isSecretId("DB_PASSWORD_2"));
    try testing.expect(isSecretId("a"));
    try testing.expect(isSecretId("x" ** 255));
    // Production refuses each of these.
    try testing.expect(!isSecretId(""));
    try testing.expect(!isSecretId("x" ** 256));
    try testing.expect(!isSecretId("with.dot"));
    try testing.expect(!isSecretId("with space"));
    try testing.expect(!isSecretId("with/slash"));
    try testing.expect(!isSecretId("projects/p/secrets/s"));
    try testing.expect(!isSecretId("caf\xc3\xa9"));
    try testing.expect(!isSecretId("new\nline"));
}

test "aliases are ids that are neither a number nor latest" {
    try testing.expect(isAlias("prod"));
    try testing.expect(isAlias("prod-2"));
    try testing.expect(isAlias("v2"));
    try testing.expect(!isAlias("latest"));
    try testing.expect(!isAlias("3"));
    try testing.expect(!isAlias("0000"));
    try testing.expect(!isAlias(""));
    try testing.expect(!isAlias("a b"));
}

test "locations are host-name safe" {
    try testing.expect(isLocation("europe-west3"));
    try testing.expect(isLocation("us-central1"));
    try testing.expect(isLocation("a"));
    try testing.expect(!isLocation(""));
    try testing.expect(!isLocation("US-CENTRAL1"));
    try testing.expect(!isLocation("europe.west3"));
    try testing.expect(!isLocation("europe-west3/"));
    try testing.expect(!isLocation("europe-west3."));
    try testing.expect(!isLocation("-west3"));
    try testing.expect(!isLocation("west3-"));
    try testing.expect(!isLocation("3west"));
    try testing.expect(!isLocation("a" ** 64));
    // The reason for the rule: neither of these may reach a host name.
    try testing.expect(!isLocation("evil.example.com"));
    try testing.expect(!isLocation("x\r\nHost: evil"));
}

fn idProperty(_: void, input: []const u8) !void {
    // The rules, stated independently of the implementations.
    var id_ok = input.len > 0 and input.len <= max_id_len;
    for (input) |c| id_ok = id_ok and (std.ascii.isAlphanumeric(c) or c == '-' or c == '_');
    try testing.expectEqual(id_ok, isSecretId(input));

    var digits_only = input.len > 0;
    for (input) |c| digits_only = digits_only and std.ascii.isDigit(c);
    try testing.expectEqual(id_ok and !digits_only and !std.mem.eql(u8, input, "latest"), isAlias(input));

    // An accepted id or location is safe in a path segment, and a location
    // is safe in a host name too.
    if (isSecretId(input)) {
        try testing.expect(std.mem.indexOfAny(u8, input, "/?#:@%.") == null);
        for (input) |c| try testing.expect(c > ' ' and c < 0x7f);
    }
    if (isLocation(input)) {
        try testing.expect(std.mem.indexOfAny(u8, input, "/?#:@%._\r\n") == null);
        try testing.expect(@import("core").endpoint.isValidHost(input));
    }
}

test "fuzz ids, aliases and locations: exactly the safe ones are accepted" {
    try test_util.fuzzBytes({}, idProperty, .{ .corpus = &.{
        "db-password",
        "latest",
        "3",
        "europe-west3",
        "",
        "x" ** 256,
        "with.dot",
        "x\r\nHost: evil",
        "caf\xc3\xa9",
    } });
}
