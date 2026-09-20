//! Google resource names: the id rules more than one service needs. A rule
//! only one service has (a topic id, a secret id) stays with that module.

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

const testing = std.testing;

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
