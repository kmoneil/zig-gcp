//! Google resource names: the id rules more than one service needs. A rule
//! only one service has (a secret id) stays with that module.

const std = @import("std");
const test_util = @import("testing.zig");

/// Project ids and numbers, including legacy domain-scoped ids such as
/// `example.com:my-project`. Checked loosely, only so the id is safe in a
/// URL and a JSON string; the server decides whether it exists.
pub fn isProjectId(id: []const u8) bool {
    if (id.len == 0 or id.len > 100) return false;
    for (id) |c| switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '.', ':', '_' => {},
        else => return false,
    };
    return true;
}

/// Pub/Sub topic and subscription ids: 3 to 255 characters from
/// `[A-Za-z0-9-_.~+%]`, starting with a letter, and not starting with
/// "goog" in any case (the emulator allows "GOOG"; production does not).
/// Pub/Sub names its own; Cloud Storage's notifications name a topic.
pub fn isPubSubId(id: []const u8) bool {
    if (id.len < 3 or id.len > 255) return false;
    if (!std.ascii.isAlphabetic(id[0])) return false;
    if (std.ascii.startsWithIgnoreCase(id, "goog")) return false;
    for (id) |c| switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '~', '+', '%' => {},
        else => return false,
    };
    return true;
}

const testing = std.testing;

test "Pub/Sub ids: the documented rules at their boundaries" {
    try testing.expect(isPubSubId("abc"));
    try testing.expect(!isPubSubId("ab"));
    try testing.expect(isPubSubId("a" ** 255));
    try testing.expect(!isPubSubId("a" ** 256));
    try testing.expect(isPubSubId("a.b~c_d-e+f%41"));
    try testing.expect(isPubSubId("gooXfoo"));
    try testing.expect(isPubSubId("xgoog"));
    try testing.expect(!isPubSubId("googfoo"));
    try testing.expect(!isPubSubId("goog"));
    // Production rejects any case; the emulator accepts this one.
    try testing.expect(!isPubSubId("GOOGfoo"));
    try testing.expect(!isPubSubId("GoOgle-topic"));
    try testing.expect(!isPubSubId("1abc"));
    try testing.expect(!isPubSubId("-abc"));
    try testing.expect(!isPubSubId("ab/c"));
    try testing.expect(!isPubSubId("ab c"));
    try testing.expect(!isPubSubId("mi-t\xc3\xb3pico"));
    try testing.expect(!isPubSubId(""));
}

test "project ids" {
    try testing.expect(isProjectId("test"));
    try testing.expect(isProjectId("my-project-123"));
    try testing.expect(isProjectId("123456789123"));
    try testing.expect(isProjectId("example.com:my-project"));
    try testing.expect(!isProjectId(""));
    try testing.expect(!isProjectId("a/b"));
    try testing.expect(!isProjectId("a b"));
    try testing.expect(!isProjectId("a\"b"));
    try testing.expect(!isProjectId("x" ** 101));
}

fn projectIdProperty(_: void, input: []const u8) !void {
    // The rule, stated independently of the implementation.
    var allowed = input.len > 0 and input.len <= 100;
    for (input) |c| allowed = allowed and (std.ascii.isAlphanumeric(c) or
        c == '-' or c == '.' or c == ':' or c == '_');
    try testing.expectEqual(allowed, isProjectId(input));
    // So an accepted id cannot redirect a URL or break out of a JSON string.
    if (isProjectId(input)) {
        try testing.expect(std.mem.indexOfAny(u8, input, "/?#\\\"") == null);
        for (input) |c| try testing.expect(c > ' ' and c < 0x7f);
    }
}

test "fuzz project ids: accepts exactly what is safe in a path and a body" {
    try test_util.fuzzBytes({}, projectIdProperty, .{ .corpus = &.{
        "my-project-123",
        "example.com:my-project",
        "",
        "a/b",
        "x" ** 101,
        "pro\xc3\xa9ject",
    } });
}
