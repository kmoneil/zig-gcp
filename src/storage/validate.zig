//! Client-side checks, deliberately light: the server is the authority and
//! its messages are clear, so only what is checked here is what would build
//! a broken request or address the wrong resource.

const std = @import("std");
const test_util = @import("test_util.zig");

/// The documented ceiling on an object name's length, in bytes of UTF-8.
pub const max_object_name_len = 1024;

/// Object names are 1 to 1,024 bytes of valid UTF-8, without carriage
/// return or line feed, and are not `.` or `..`, which the XML API reserves
/// and Google's guidance rules out. Everything else, slashes included, is
/// the server's business.
pub fn isObjectName(name: []const u8) bool {
    if (name.len == 0 or name.len > max_object_name_len) return false;
    if (!std.unicode.utf8ValidateSlice(name)) return false;
    if (std.mem.indexOfAny(u8, name, "\r\n") != null) return false;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return false;
    return true;
}

/// Bucket names are not empty and carry no slash and no whitespace, so the
/// name stays one path segment. The server enforces the rest of its naming
/// rules itself.
pub fn isBucketName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |c| {
        if (c == '/') return false;
        if (c <= ' ' or c == 0x7f) return false;
    }
    return true;
}

/// User agents become a header value: printable ASCII.
pub fn isUserAgent(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text) |c| if (c < ' ' or c >= 0x7f) return false;
    return true;
}

const testing = std.testing;

test "object names: the documented rules, nothing more" {
    try testing.expect(isObjectName("a"));
    try testing.expect(isObjectName("reports/2026/q3.txt"));
    try testing.expect(isObjectName("with space and % and #?"));
    try testing.expect(isObjectName("caf\xc3\xa9"));
    try testing.expect(isObjectName("..."));
    try testing.expect(isObjectName("./relative"));
    try testing.expect(isObjectName("a" ** max_object_name_len));

    try testing.expect(!isObjectName(""));
    try testing.expect(!isObjectName("a" ** (max_object_name_len + 1)));
    try testing.expect(!isObjectName("."));
    try testing.expect(!isObjectName(".."));
    try testing.expect(!isObjectName("line\nbreak"));
    try testing.expect(!isObjectName("carriage\rreturn"));
    try testing.expect(!isObjectName("bad\xffutf8"));
}

test "bucket names: one path segment, or nothing" {
    try testing.expect(isBucketName("my-bucket"));
    try testing.expect(isBucketName("bucket.example.com"));
    try testing.expect(isBucketName("under_score"));
    try testing.expect(!isBucketName(""));
    try testing.expect(!isBucketName("a/b"));
    try testing.expect(!isBucketName("a b"));
    try testing.expect(!isBucketName("a\tb"));
    try testing.expect(!isBucketName("a\nb"));
    try testing.expect(!isBucketName("\x01"));
}

test "user agents are printable ASCII" {
    try testing.expect(isUserAgent("zig-gcp-storage/0.13"));
    try testing.expect(!isUserAgent(""));
    try testing.expect(!isUserAgent("agent\r\nX: y"));
    try testing.expect(!isUserAgent("caf\xc3\xa9"));
}

fn namesProperty(_: void, input: []const u8) !void {
    // Total on any bytes, and an accepted name can never break the request
    // line: no CR or LF in object names, no separator bytes in bucket names.
    if (isObjectName(input)) {
        try testing.expect(input.len >= 1 and input.len <= max_object_name_len);
        try testing.expect(std.mem.indexOfAny(u8, input, "\r\n") == null);
    }
    if (isBucketName(input)) {
        try testing.expect(std.mem.indexOfAny(u8, input, "/ \t\r\n") == null);
    }
}

test "fuzz name validation is total and safe" {
    try test_util.fuzzBytes({}, namesProperty, .{ .corpus = &.{
        "reports/2026/q3.txt",
        ".",
        "..",
        "a\rb",
        "my-bucket",
        "a b",
        "\xff\xfe",
    } });
}
