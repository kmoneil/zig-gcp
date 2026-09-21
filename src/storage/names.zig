//! Request paths. Bucket and object names travel as single path segments in
//! the strict percent-encoded form, so a name with slashes, spaces or `%`
//! addresses exactly the object it names. Query values go through the same
//! builder every module uses.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const query = @import("core").query;
const types = @import("types.zig");

/// `/storage/v1/b?project=...` with paging, for bucket create and list.
pub fn bucketsPath(arena: Allocator, project: []const u8, page: types.PageOptions) Allocator.Error![]u8 {
    var out: Writer.Allocating = .init(arena);
    write(&out.writer, .{ .project = project, .page_size = page.page_size, .page_token = page.page_token }) catch
        return error.OutOfMemory;
    return out.toOwnedSlice();
}

/// `/storage/v1/b/{bucket}`.
pub fn bucketPath(arena: Allocator, bucket: []const u8) Allocator.Error![]u8 {
    var out: Writer.Allocating = .init(arena);
    write(&out.writer, .{ .bucket = bucket }) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

/// `/storage/v1/b/{bucket}/o` with listing options.
pub fn objectsPath(arena: Allocator, bucket: []const u8, options: types.ListOptions) Allocator.Error![]u8 {
    var out: Writer.Allocating = .init(arena);
    write(&out.writer, .{
        .bucket = bucket,
        .list_objects = true,
        .prefix = options.prefix,
        .delimiter = options.delimiter,
        .page_size = options.page_size,
        .page_token = options.page_token,
    }) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

/// `/storage/v1/b/{bucket}/o/{object}`, optionally pinned to a generation.
pub fn objectPath(arena: Allocator, bucket: []const u8, object: []const u8, generation: ?u64) Allocator.Error![]u8 {
    var out: Writer.Allocating = .init(arena);
    write(&out.writer, .{ .bucket = bucket, .object = object, .generation = generation }) catch
        return error.OutOfMemory;
    return out.toOwnedSlice();
}

const Parts = struct {
    bucket: ?[]const u8 = null,
    object: ?[]const u8 = null,
    list_objects: bool = false,
    project: ?[]const u8 = null,
    generation: ?u64 = null,
    prefix: ?[]const u8 = null,
    delimiter: ?[]const u8 = null,
    page_size: u32 = 0,
    page_token: ?[]const u8 = null,
};

fn write(w: *Writer, parts: Parts) Writer.Error!void {
    try w.writeAll("/storage/v1/b");
    if (parts.bucket) |bucket| {
        try w.writeByte('/');
        try query.writeStrictSegment(w, bucket);
    }
    if (parts.list_objects) try w.writeAll("/o");
    if (parts.object) |object| {
        try w.writeAll("/o/");
        try query.writeStrictSegment(w, object);
    }
    var params: query.Params = .init(w);
    try params.addOptional("project", parts.project);
    if (parts.generation) |g| try params.addInt("generation", g);
    try params.addOptional("prefix", parts.prefix);
    try params.addOptional("delimiter", parts.delimiter);
    try params.addNonZero("maxResults", parts.page_size);
    try params.addOptional("pageToken", parts.page_token);
}

const testing = std.testing;

fn expectPath(expected: []const u8, actual: []u8) !void {
    defer testing.allocator.free(actual);
    try testing.expectEqualStrings(expected, actual);
}

test "bucket paths" {
    const gpa = testing.allocator;
    try expectPath("/storage/v1/b?project=extractctl", try bucketsPath(gpa, "extractctl", .{}));
    try expectPath(
        "/storage/v1/b?project=extractctl&maxResults=2&pageToken=a%2Bb%3D",
        try bucketsPath(gpa, "extractctl", .{ .page_size = 2, .page_token = "a+b=" }),
    );
    try expectPath("/storage/v1/b/my-bucket", try bucketPath(gpa, "my-bucket"));
    try expectPath("/storage/v1/b/b%25c", try bucketPath(gpa, "b%c"));
}

test "object paths encode the name as one segment" {
    const gpa = testing.allocator;
    try expectPath(
        "/storage/v1/b/my-bucket/o/reports%2F2026%2Fq3.txt",
        try objectPath(gpa, "my-bucket", "reports/2026/q3.txt", null),
    );
    try expectPath(
        "/storage/v1/b/my-bucket/o/a%20b%2Bc%3F%23?generation=1758448800123456",
        try objectPath(gpa, "my-bucket", "a b+c?#", 1758448800123456),
    );
    try expectPath("/storage/v1/b/b/o/caf%C3%A9", try objectPath(gpa, "b", "caf\xc3\xa9", null));
    // A name that is only slashes stays addressable.
    try expectPath("/storage/v1/b/b/o/%2F%2F%2F", try objectPath(gpa, "b", "///", null));
}

test "object listing paths" {
    const gpa = testing.allocator;
    try expectPath("/storage/v1/b/my-bucket/o", try objectsPath(gpa, "my-bucket", .{}));
    try expectPath(
        "/storage/v1/b/my-bucket/o?prefix=reports%2F&delimiter=%2F&maxResults=2&pageToken=t",
        try objectsPath(gpa, "my-bucket", .{
            .prefix = "reports/",
            .delimiter = "/",
            .page_size = 2,
            .page_token = "t",
        }),
    );
}
