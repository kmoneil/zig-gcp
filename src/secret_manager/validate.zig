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

/// The longest secret id.
pub const max_id_len = 255;

/// The longest version alias, and the most a secret holds; measured
/// 2026-10-02, as the API documents them.
pub const max_alias_len = 63;
pub const max_aliases = 50;

/// The most labels a secret holds, and the longest label key or value in
/// characters and in bytes.
pub const max_labels = 64;
pub const max_label_chars = 63;
pub const max_label_bytes = 128;

/// The longest annotation key, and the most bytes a secret's annotations
/// hold, keys and values together. Measured 2026-10-02: a 64-character
/// key is taken, though the docs and production's own refusal say "less
/// than 64"; the total counts bytes, not characters.
pub const max_annotation_key_len = 64;
pub const max_annotation_bytes = 16 * 1024;

/// Expiry, counted from now: production refuses less than a minute and
/// more than 876,000 hours.
pub const min_expiry_s = 60;
pub const max_expiry_s = 876_000 * 3600;

/// The delay before a destroyed version goes: 1 to 1,000 days.
pub const min_destroy_delay_s = 86_400;
pub const max_destroy_delay_s = 86_400_000;

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

/// Version aliases: 1 to 63 characters, an ASCII letter and then letters,
/// digits, `-` and `_`, and neither `latest` nor `NEW`. Production refuses
/// exactly those two words, case and all: `Latest` and `new` are taken.
/// A letter first means no alias is a number, which would name a version.
pub fn isAlias(alias: []const u8) bool {
    if (alias.len == 0 or alias.len > max_alias_len) return false;
    if (!std.ascii.isAlphabetic(alias[0])) return false;
    for (alias) |c| switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '_' => {},
        else => return false,
    };
    return !std.mem.eql(u8, alias, "latest") and !std.mem.eql(u8, alias, "NEW");
}

/// Why `key` cannot be a label key, or null when it can. Production holds
/// keys to `[\p{Ll}\p{Lo}][\p{Ll}\p{Lo}\p{N}_-]{0,62}` and 128 bytes. ASCII
/// is checked exactly; beyond ASCII the Unicode classes are the server's
/// to judge, so any such character passes here.
pub fn labelKeyProblem(key: []const u8) ?[]const u8 {
    if (key.len == 0) return "a label key is at least one character";
    if (labelTextProblem(key)) |p| return p;
    if (key[0] < 0x80 and !std.ascii.isLower(key[0])) {
        return "a label key starts with a lowercase letter";
    }
    return null;
}

/// Why `value` cannot be a label value, or null when it can: 0 to 63
/// characters of the key's alphabet, any of them first.
pub fn labelValueProblem(value: []const u8) ?[]const u8 {
    return labelTextProblem(value);
}

fn labelTextProblem(text: []const u8) ?[]const u8 {
    if (text.len > max_label_bytes) return "a label key or value holds at most 128 bytes";
    const view = std.unicode.Utf8View.init(text) catch return "labels must be valid UTF-8";
    var it = view.iterator();
    var chars: usize = 0;
    while (it.nextCodepoint()) |cp| : (chars += 1) {
        if (cp >= 0x80) continue;
        switch (cp) {
            'a'...'z', '0'...'9', '_', '-' => {},
            else => return "labels hold lowercase letters, digits, '_' and '-'",
        }
    }
    if (chars > max_label_chars) return "a label key or value is at most 63 characters";
    return null;
}

/// Annotation keys: 1 to 64 ASCII letters and digits, with `.`, `_` and
/// `-` between them, never first or last.
pub fn isAnnotationKey(key: []const u8) bool {
    if (key.len == 0 or key.len > max_annotation_key_len) return false;
    if (!std.ascii.isAlphanumeric(key[0]) or !std.ascii.isAlphanumeric(key[key.len - 1])) return false;
    for (key) |c| switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '.', '_', '-' => {},
        else => return false,
    };
    return true;
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
    try testing.expect(isAlias("a-b_C9"));
    try testing.expect(isAlias("a" ** 63));
    // Production takes these, refusing only the two exact words.
    try testing.expect(isAlias("Latest"));
    try testing.expect(isAlias("LATEST"));
    try testing.expect(isAlias("new"));
    try testing.expect(isAlias("New"));
    // And refuses each of these.
    try testing.expect(!isAlias("latest"));
    try testing.expect(!isAlias("NEW"));
    try testing.expect(!isAlias("a" ** 64));
    try testing.expect(!isAlias("1a"));
    try testing.expect(!isAlias("_a"));
    try testing.expect(!isAlias("-a"));
    try testing.expect(!isAlias("a.b"));
    try testing.expect(!isAlias("3"));
    try testing.expect(!isAlias("0000"));
    try testing.expect(!isAlias(""));
    try testing.expect(!isAlias("a b"));
}

test "label keys and values, as production judged them" {
    // Taken by production on 2026-10-02.
    for ([_][]const u8{ "a", "a" ** 63, "\xc3\xa9", "\xe3\x82\xa2" ** 42, "team", "k-1_x" }) |key| {
        try testing.expectEqual(null, labelKeyProblem(key));
    }
    for ([_][]const u8{ "", "v", "a" ** 63, "1abc", "_x", "-x" }) |value| {
        try testing.expectEqual(null, labelValueProblem(value));
    }
    // Refused by production.
    for ([_][]const u8{ "", "a" ** 64, "Abc", "1abc", "_abc", "a.b", "\xe3\x82\xa2" ** 43, "a b", "caf\xff" }) |key| {
        try testing.expect(labelKeyProblem(key) != null);
    }
    for ([_][]const u8{ "a" ** 64, "ABC", "a.b", "x/y" }) |value| {
        try testing.expect(labelValueProblem(value) != null);
    }
}

test "annotation keys, as production judged them" {
    for ([_][]const u8{ "a", "a" ** 63, "a" ** 64, "Owner", "a.b-c_d", "k1" }) |key| {
        try testing.expect(isAnnotationKey(key));
    }
    for ([_][]const u8{ "", "a" ** 65, "-a", "a.", "example.com/owner", "\xc3\xa9", "a b", "_a" }) |key| {
        try testing.expect(!isAnnotationKey(key));
    }
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

    const alias_ok = id_ok and input.len <= max_alias_len and std.ascii.isAlphabetic(input[0]) and
        !std.mem.eql(u8, input, "latest") and !std.mem.eql(u8, input, "NEW");
    try testing.expectEqual(alias_ok, isAlias(input));
    // An alias is never a number, which would name a version instead.
    if (isAlias(input)) try testing.expect(std.fmt.parseInt(u64, input, 10) == error.InvalidCharacter);

    // A label key or annotation key that passes is safe in a JSON key.
    if (labelKeyProblem(input) == null) try testing.expect(std.unicode.utf8ValidateSlice(input));
    if (isAnnotationKey(input)) for (input) |c| try testing.expect(c > ' ' and c < 0x7f and c != '"' and c != '\\');

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
        "NEW",
        "Latest",
        "3",
        "europe-west3",
        "",
        "x" ** 256,
        "with.dot",
        "x\r\nHost: evil",
        "caf\xc3\xa9",
    } });
}
