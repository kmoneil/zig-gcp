//! Request paths and query strings.
//!
//! Path segments are encoded minimally: every character RFC 3986 allows in a
//! segment stays literal, the rest is percent-encoded. Measured against
//! production, Google's front end decodes escapes like `%25` but leaves
//! escapes of reserved characters alone, so an encoded `+` (`%2B`) would name
//! a different topic than a literal `+`. For valid ids, only `%` is encoded;
//! without that, a raw `orders%41` would address the topic `ordersA`.
//!
//! Query values (page tokens) are encoded strictly: everything outside the
//! unreserved set, so `+` and `=` survive form-style decoding.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const test_util = @import("test_util.zig");

pub const Collection = enum {
    topics,
    subscriptions,
};

pub fn isUnreserved(c: u8) bool {
    return switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~' => true,
        else => false,
    };
}

/// RFC 3986 `pchar` without `pct-encoded`: what may appear literally in a
/// path segment.
pub fn isPathChar(c: u8) bool {
    return isUnreserved(c) or switch (c) {
        '!', '$', '&', '\'', '(', ')', '*', '+', ',', ';', '=', ':', '@' => true,
        else => false,
    };
}

/// Writes `text` as one path segment: bytes outside `isPathChar` become `%XX`.
pub fn writeSegment(w: *Writer, text: []const u8) Writer.Error!void {
    return std.Uri.Component.percentEncode(w, text, isPathChar);
}

/// Writes `text` as a query value: bytes outside the unreserved set become `%XX`.
pub fn writeQueryValue(w: *Writer, text: []const u8) Writer.Error!void {
    return std.Uri.Component.percentEncode(w, text, isUnreserved);
}

/// `/v1/projects/{project}/{collection}/{id}{suffix}`, with `project` and `id`
/// encoded. `suffix` is a literal method such as `:publish`, or "".
pub fn resourcePath(
    arena: Allocator,
    project: []const u8,
    collection: Collection,
    id: []const u8,
    suffix: []const u8,
) Allocator.Error![]u8 {
    var out: Writer.Allocating = .init(arena);
    const w = &out.writer;
    writeResourcePath(w, project, collection, id, suffix) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn writeResourcePath(
    w: *Writer,
    project: []const u8,
    collection: Collection,
    id: []const u8,
    suffix: []const u8,
) Writer.Error!void {
    try w.writeAll("/v1/projects/");
    try writeSegment(w, project);
    try w.print("/{t}/", .{collection});
    try writeSegment(w, id);
    try w.writeAll(suffix);
}

/// `/v1/projects/{project}/{collection}?pageSize=N&pageToken=T` for list calls.
/// A zero `page_size` and a null or empty token are left out.
pub fn listPath(
    arena: Allocator,
    project: []const u8,
    collection: Collection,
    page_size: u32,
    page_token: ?[]const u8,
) Allocator.Error![]u8 {
    var out: Writer.Allocating = .init(arena);
    writeListPath(&out.writer, project, collection, page_size, page_token) catch
        return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn writeListPath(
    w: *Writer,
    project: []const u8,
    collection: Collection,
    page_size: u32,
    page_token: ?[]const u8,
) Writer.Error!void {
    try w.writeAll("/v1/projects/");
    try writeSegment(w, project);
    try w.print("/{t}", .{collection});
    var separator: u8 = '?';
    if (page_size != 0) {
        try w.print("{c}pageSize={d}", .{ separator, page_size });
        separator = '&';
    }
    if (page_token) |token| if (token.len != 0) {
        try w.print("{c}pageToken=", .{separator});
        try writeQueryValue(w, token);
    };
}

/// The unencoded resource name, `projects/{project}/{collection}/{id}`, as it
/// appears inside JSON bodies.
pub fn resourceName(
    arena: Allocator,
    project: []const u8,
    collection: Collection,
    id: []const u8,
) Allocator.Error![]u8 {
    return std.fmt.allocPrint(arena, "projects/{s}/{t}/{s}", .{ project, collection, id });
}

const testing = std.testing;

test "resourcePath encodes ids and keeps the method suffix" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings(
        "/v1/projects/test/topics/orders:publish",
        try resourcePath(a, "test", .topics, "orders", ":publish"),
    );
    // Regressions: `%` is encoded so the server's decoding restores it, and
    // `+` stays literal, because production does not decode `%2B`.
    try testing.expectEqualStrings(
        "/v1/projects/test/subscriptions/a%2541b+c~d.e_f-g",
        try resourcePath(a, "test", .subscriptions, "a%41b+c~d.e_f-g", ""),
    );
    // Domain-scoped project ids keep their colon, as Google's clients send it.
    try testing.expectEqualStrings(
        "/v1/projects/example.com:proj/topics/t",
        try resourcePath(a, "example.com:proj", .topics, "t", ""),
    );
    // Bytes that can never be in a valid id are still encoded, never passed raw.
    try testing.expectEqualStrings(
        "/v1/projects/p/topics/a%2Fb%20c%3Fd%23e%C3%A9",
        try resourcePath(a, "p", .topics, "a/b c?d#e\xc3\xa9", ""),
    );
}

test "listPath builds the query" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("/v1/projects/p/topics", try listPath(a, "p", .topics, 0, null));
    try testing.expectEqualStrings("/v1/projects/p/topics?pageSize=100", try listPath(a, "p", .topics, 100, null));
    try testing.expectEqualStrings("/v1/projects/p/topics?pageSize=2", try listPath(a, "p", .topics, 2, ""));
    // Page tokens are opaque and may hold `/`, `+` and `=`.
    try testing.expectEqualStrings(
        "/v1/projects/p/subscriptions?pageSize=2&pageToken=projects%2Fp%2Ftopics%2Fx%2B%3D",
        try listPath(a, "p", .subscriptions, 2, "projects/p/topics/x+="),
    );
    try testing.expectEqualStrings(
        "/v1/projects/p/topics?pageToken=abc",
        try listPath(a, "p", .topics, 0, "abc"),
    );
}

test "resourceName is not encoded" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings(
        "projects/test/topics/a%41",
        try resourceName(arena.allocator(), "test", .topics, "a%41"),
    );
}

fn expectEncoding(encoded: []const u8, input: []const u8, comptime isAllowed: fn (u8) bool) !void {
    // Only allowed bytes and well-formed %XX escapes...
    var i: usize = 0;
    while (i < encoded.len) : (i += 1) {
        if (encoded[i] == '%') {
            try testing.expect(i + 2 < encoded.len);
            try testing.expect(std.ascii.isHex(encoded[i + 1]) and std.ascii.isHex(encoded[i + 2]));
            i += 2;
        } else {
            try testing.expect(isAllowed(encoded[i]));
        }
    }
    // ...and decoding gives the input back.
    var copy: [3 * test_util.max_fuzz_input]u8 = undefined;
    @memcpy(copy[0..encoded.len], encoded);
    try testing.expectEqualSlices(u8, input, std.Uri.percentDecodeInPlace(copy[0..encoded.len]));
}

fn encodeProperty(_: void, input: []const u8) !void {
    var buf: [3 * test_util.max_fuzz_input]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try writeSegment(&w, input);
    try expectEncoding(w.buffered(), input, isPathChar);
    // A segment never contains a separator the server would split on.
    try testing.expect(std.mem.indexOfAny(u8, w.buffered(), "/?#") == null);

    w = .fixed(&buf);
    try writeQueryValue(&w, input);
    try expectEncoding(w.buffered(), input, isUnreserved);
}

test "fuzz percent-encoding round-trips and emits only safe bytes" {
    try test_util.fuzzBytes({}, encodeProperty, .{ .corpus = &.{
        "orders",
        "a%41b+c",
        "projects/p/topics/x+=",
        "\x00\xff /?#[]@!$&'()*,;=",
        "mi-t\xc3\xb3pico",
    } });
}
