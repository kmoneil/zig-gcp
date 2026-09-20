//! Pub/Sub request paths: the resource path every call builds on, the list
//! query, and the resource name that goes inside bodies. The percent-encoding
//! rules, and the measurements behind them, live in `core.query`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const query = @import("core").query;

pub const Collection = enum {
    topics,
    subscriptions,
};

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
    try query.writeSegment(w, project);
    try w.print("/{t}/", .{collection});
    try query.writeSegment(w, id);
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
    try query.writeSegment(w, project);
    try w.print("/{t}", .{collection});
    var params: query.Params = .init(w);
    try params.addNonZero("pageSize", page_size);
    try params.addOptional("pageToken", page_token);
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
