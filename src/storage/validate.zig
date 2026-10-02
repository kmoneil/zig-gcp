//! Client-side checks, deliberately light: the server is the authority and
//! its messages are clear, so only what is checked here is what would build
//! a broken request or address the wrong resource.

const std = @import("std");
const test_util = @import("test_util.zig");
const types = @import("types.zig");

/// The documented ceiling on an object name's length, in bytes of UTF-8.
pub const max_object_name_len = 1024;

// Bucket settings, as Cloud Storage enforced them on 2026-09-29. The
// emulator enforces none of them, so they are checked before sending.

/// Labels on a bucket.
pub const max_labels = 64;
/// Characters in a label key or value, and bytes of UTF-8.
pub const max_label_chars = 63;
pub const max_label_bytes = 128;
/// A soft delete retention other than 0, which turns soft delete off: 7 to
/// 90 days, both included.
pub const min_soft_delete_retention_s = 604_800;
pub const max_soft_delete_retention_s = 7_776_000;
/// A retention policy's period, both included: 3,155,760,000 is taken and
/// 3,155,760,001 refused, as measured, though Cloud Storage's message says
/// "less than 100 years".
pub const min_retention_period_s = 1;
pub const max_retention_period_s = 3_155_760_000;
/// Prefixes and suffixes across all of a bucket's lifecycle rules, and
/// bytes in each. The documented limit of 100 rules is not enforced.
pub const max_lifecycle_affixes = 1000;
pub const max_lifecycle_affix_bytes = 1024;
/// Days, ages and version counts in a lifecycle condition: a signed
/// 32-bit integer.
pub const max_lifecycle_days = std.math.maxInt(i32);
/// Sizes in a lifecycle condition: the largest object, 5 TiB.
pub const max_lifecycle_size_bytes = 5 * 1024 * 1024 * 1024 * 1024;

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

/// What is wrong with a set of custom metadata entries, and where.
pub const MetadataFault = struct {
    index: usize,
    /// True when the key repeats an earlier one, false when it is empty.
    repeated: bool,
};

/// The first entry that has no key, or whose key repeats an earlier one,
/// or null when the set is unambiguous. Cloud Storage stores custom
/// metadata as one JSON object, so a repeated key makes a body carrying
/// two entries of one name, which the server resolves however it pleases
/// and a strict JSON reader refuses outright.
pub fn metadataFault(entries: []const types.Metadata) ?MetadataFault {
    for (entries, 0..) |entry, i| {
        if (entry.key.len == 0) return .{ .index = i, .repeated = false };
        for (entries[0..i]) |earlier| {
            if (std.mem.eql(u8, earlier.key, entry.key)) return .{ .index = i, .repeated = true };
        }
    }
    return null;
}

/// The ceiling on a folder path in a hierarchical-namespace bucket, in
/// bytes of UTF-8, slashes and the trailing slash included: the documented
/// 512 bytes. Cloud Storage's own refusal says characters, and counted
/// ASCII when measured (2026-10-02), so which it counts for multibyte
/// names only the server knows.
pub const max_folder_path_bytes = 512;
/// Folders nest at most 50 levels deep.
pub const max_folder_depth = 50;

/// What is wrong with a folder path, or null. `path` ends with the
/// trailing slash the handle appends when it is missing. Cloud Storage
/// itself takes `./`, `../` and `/` verbatim, as measured, which no caller
/// can want: a folder literally named `..` reads like a path traversal
/// everywhere it is printed. So dot segments and empty segments are
/// refused here, beside the documented limits.
pub fn folderPathProblem(path: []const u8) ?[]const u8 {
    if (path.len == 0) return "the path is empty";
    if (path.len > max_folder_path_bytes) return "the path is over 512 bytes, slashes included";
    if (!std.unicode.utf8ValidateSlice(path)) return "the path is not UTF-8";
    if (std.mem.indexOfAny(u8, path, "\r\n") != null) return "the path holds a carriage return or line feed";
    var depth: usize = 0;
    const trimmed = if (path[path.len - 1] == '/') path[0 .. path.len - 1] else path;
    var segments = std.mem.splitScalar(u8, trimmed, '/');
    while (segments.next()) |segment| {
        depth += 1;
        if (segment.len == 0) return "a segment is empty, which Cloud Storage reads as a parent that cannot exist";
        if (std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, ".."))
            return "a segment is \".\" or \"..\", which Cloud Storage takes verbatim and nothing can address safely";
    }
    if (depth > max_folder_depth) return "the path is over 50 levels deep";
    return null;
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
    if (folderPathProblem(input) == null) {
        try testing.expect(input.len >= 1 and input.len <= max_folder_path_bytes);
        try testing.expect(std.mem.indexOfAny(u8, input, "\r\n") == null);
        try testing.expect(std.mem.indexOf(u8, input, "//") == null);
        try testing.expect(input[0] != '/');
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
        "a/b/",
        "../",
        "a//b/",
    } });
}

test "folder paths: the measured limits, and the names the server takes that no caller can want" {
    try testing.expect(folderPathProblem("a/") == null);
    try testing.expect(folderPathProblem("a/b/c/") == null);
    try testing.expect(folderPathProblem("caf\xc3\xa9/") == null);
    try testing.expect(folderPathProblem("...a/") == null);
    try testing.expect(folderPathProblem("s" ** 511 ++ "/") == null);
    const deep50 = "d/" ** 50;
    try testing.expect(folderPathProblem(deep50) == null);

    try testing.expect(folderPathProblem("") != null);
    try testing.expect(folderPathProblem("/") != null);
    try testing.expect(folderPathProblem("./") != null);
    try testing.expect(folderPathProblem("../") != null);
    try testing.expect(folderPathProblem("a/./b/") != null);
    try testing.expect(folderPathProblem("a/../") != null);
    try testing.expect(folderPathProblem("/a/") != null);
    try testing.expect(folderPathProblem("a//b/") != null);
    try testing.expect(folderPathProblem("s" ** 512 ++ "/") != null);
    try testing.expect(folderPathProblem(deep50 ++ "x/") != null);
    try testing.expect(folderPathProblem("a\rb/") != null);
    try testing.expect(folderPathProblem("a\nb/") != null);
    try testing.expect(folderPathProblem("bad\xffutf8/") != null);
}

test "metadataFault finds an empty key and a repeated one" {
    try std.testing.expectEqual(null, metadataFault(&.{}));
    try std.testing.expectEqual(null, metadataFault(&.{
        .{ .key = "a", .value = "1" },
        .{ .key = "b", .value = "2" },
    }));
    // Case matters: Cloud Storage's custom metadata keys are not headers.
    try std.testing.expectEqual(null, metadataFault(&.{
        .{ .key = "a", .value = "1" },
        .{ .key = "A", .value = "2" },
    }));
    const empty = metadataFault(&.{.{ .key = "", .value = "1" }}).?;
    try std.testing.expectEqual(0, empty.index);
    try std.testing.expectEqual(false, empty.repeated);
    const repeated = metadataFault(&.{
        .{ .key = "a", .value = "1" },
        .{ .key = "b", .value = "2" },
        .{ .key = "a", .value = "3" },
    }).?;
    try std.testing.expectEqual(2, repeated.index);
    try std.testing.expectEqual(true, repeated.repeated);
}
