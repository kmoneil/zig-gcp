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
pub fn objectPath(
    arena: Allocator,
    bucket: []const u8,
    object: []const u8,
    generation: ?u64,
    preconditions: types.Preconditions,
) Allocator.Error![]u8 {
    var out: Writer.Allocating = .init(arena);
    write(&out.writer, .{
        .bucket = bucket,
        .object = object,
        .generation = generation,
        .preconditions = preconditions,
    }) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

/// `/storage/v1/b/{bucket}/o/{object}/compose`: writes the destination
/// from its sources. Compose has no `generation`; it always writes the
/// live object.
pub fn composePath(
    arena: Allocator,
    bucket: []const u8,
    object: []const u8,
    preconditions: types.Preconditions,
) Allocator.Error![]u8 {
    var out: Writer.Allocating = .init(arena);
    write(&out.writer, .{
        .bucket = bucket,
        .object = object,
        .compose = true,
        .preconditions = preconditions,
    }) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

/// `/storage/v1/b/{bucket}/o/{object}?alt=media`: the object's bytes.
pub fn objectMediaPath(
    arena: Allocator,
    bucket: []const u8,
    object: []const u8,
    generation: ?u64,
    preconditions: types.Preconditions,
) Allocator.Error![]u8 {
    var out: Writer.Allocating = .init(arena);
    write(&out.writer, .{
        .bucket = bucket,
        .object = object,
        .alt_media = true,
        .generation = generation,
        .preconditions = preconditions,
    }) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

/// `/storage/v1/b/{src}/o/{srcObj}/rewriteTo/b/{dst}/o/{dstObj}`: one call
/// of the server-side copy loop. The preconditions apply to the
/// destination; `rewrite_token` continues an earlier call's work.
pub fn rewritePath(
    arena: Allocator,
    source_bucket: []const u8,
    source_object: []const u8,
    dest_bucket: []const u8,
    dest_object: []const u8,
    options: types.CopyOptions,
    rewrite_token: ?[]const u8,
) Allocator.Error![]u8 {
    var out: Writer.Allocating = .init(arena);
    writeRewrite(&out.writer, source_bucket, source_object, dest_bucket, dest_object, options, rewrite_token) catch
        return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn writeRewrite(
    w: *Writer,
    source_bucket: []const u8,
    source_object: []const u8,
    dest_bucket: []const u8,
    dest_object: []const u8,
    options: types.CopyOptions,
    rewrite_token: ?[]const u8,
) Writer.Error!void {
    try w.writeAll("/storage/v1/b/");
    try query.writeStrictSegment(w, source_bucket);
    try w.writeAll("/o/");
    try query.writeStrictSegment(w, source_object);
    try w.writeAll("/rewriteTo/b/");
    try query.writeStrictSegment(w, dest_bucket);
    try w.writeAll("/o/");
    try query.writeStrictSegment(w, dest_object);
    var params: query.Params = .init(w);
    if (options.source_generation) |g| try params.addInt("sourceGeneration", g);
    try writePreconditions(&params, options.preconditions);
    try params.addOptional("rewriteToken", rewrite_token);
}

/// `/upload/storage/v1/b/{bucket}/o?uploadType=multipart`. The object name
/// travels in the metadata part, not here.
pub fn uploadMultipartPath(arena: Allocator, bucket: []const u8, preconditions: types.Preconditions) Allocator.Error![]u8 {
    var out: Writer.Allocating = .init(arena);
    writeUpload(&out.writer, bucket, preconditions) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn writeUpload(w: *Writer, bucket: []const u8, preconditions: types.Preconditions) Writer.Error!void {
    try w.writeAll("/upload/storage/v1/b/");
    try query.writeStrictSegment(w, bucket);
    try w.writeAll("/o?uploadType=multipart");
    var params: query.Params = .init(w);
    params.separator = '&';
    try writePreconditions(&params, preconditions);
}

/// `/upload/storage/v1/b/{bucket}/o?uploadType=resumable`, which opens a
/// session. The object name travels in the metadata body.
pub fn uploadResumablePath(arena: Allocator, bucket: []const u8, preconditions: types.Preconditions) Allocator.Error![]u8 {
    var out: Writer.Allocating = .init(arena);
    writeResumable(&out.writer, bucket, preconditions) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn writeResumable(w: *Writer, bucket: []const u8, preconditions: types.Preconditions) Writer.Error!void {
    try w.writeAll("/upload/storage/v1/b/");
    try query.writeStrictSegment(w, bucket);
    try w.writeAll("/o?uploadType=resumable");
    var params: query.Params = .init(w);
    params.separator = '&';
    try writePreconditions(&params, preconditions);
}

const Parts = struct {
    bucket: ?[]const u8 = null,
    object: ?[]const u8 = null,
    list_objects: bool = false,
    alt_media: bool = false,
    project: ?[]const u8 = null,
    generation: ?u64 = null,
    preconditions: types.Preconditions = .{},
    /// Appends `/compose` after the object, before the query.
    compose: bool = false,
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
        if (parts.compose) try w.writeAll("/compose");
    }
    var params: query.Params = .init(w);
    if (parts.alt_media) try params.add("alt", "media");
    try params.addOptional("project", parts.project);
    if (parts.generation) |g| try params.addInt("generation", g);
    try writePreconditions(&params, parts.preconditions);
    try params.addOptional("prefix", parts.prefix);
    try params.addOptional("delimiter", parts.delimiter);
    try params.addNonZero("maxResults", parts.page_size);
    try params.addOptional("pageToken", parts.page_token);
}

fn writePreconditions(params: *query.Params, preconditions: types.Preconditions) Writer.Error!void {
    if (preconditions.if_generation_match) |g| try params.addInt("ifGenerationMatch", g);
    if (preconditions.if_generation_not_match) |g| try params.addInt("ifGenerationNotMatch", g);
    if (preconditions.if_metageneration_match) |g| try params.addInt("ifMetagenerationMatch", g);
    if (preconditions.if_metageneration_not_match) |g| try params.addInt("ifMetagenerationNotMatch", g);
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
        try objectPath(gpa, "my-bucket", "reports/2026/q3.txt", null, .{}),
    );
    try expectPath(
        "/storage/v1/b/my-bucket/o/a%20b%2Bc%3F%23?generation=1758448800123456",
        try objectPath(gpa, "my-bucket", "a b+c?#", 1758448800123456, .{}),
    );
    try expectPath("/storage/v1/b/b/o/caf%C3%A9", try objectPath(gpa, "b", "caf\xc3\xa9", null, .{}));
    // A name that is only slashes stays addressable.
    try expectPath("/storage/v1/b/b/o/%2F%2F%2F", try objectPath(gpa, "b", "///", null, .{}));
}

test "media and upload paths" {
    const gpa = testing.allocator;
    try expectPath(
        "/storage/v1/b/my-bucket/o/backup.tar?alt=media",
        try objectMediaPath(gpa, "my-bucket", "backup.tar", null, .{}),
    );
    try expectPath(
        "/storage/v1/b/my-bucket/o/a%2Fb?alt=media&generation=7",
        try objectMediaPath(gpa, "my-bucket", "a/b", 7, .{}),
    );
    try expectPath(
        "/upload/storage/v1/b/my-bucket/o?uploadType=multipart",
        try uploadMultipartPath(gpa, "my-bucket", .{}),
    );
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

test "preconditions become their query parameters, in every position" {
    const gpa = testing.allocator;
    try expectPath(
        "/storage/v1/b/b/o/a?ifGenerationMatch=0",
        try objectPath(gpa, "b", "a", null, .does_not_exist),
    );
    try expectPath(
        "/storage/v1/b/b/o/a?generation=7&ifGenerationMatch=7&ifGenerationNotMatch=6&ifMetagenerationMatch=1&ifMetagenerationNotMatch=2",
        try objectPath(gpa, "b", "a", 7, .{
            .if_generation_match = 7,
            .if_generation_not_match = 6,
            .if_metageneration_match = 1,
            .if_metageneration_not_match = 2,
        }),
    );
    try expectPath(
        "/storage/v1/b/b/o/a?alt=media&ifGenerationNotMatch=9",
        try objectMediaPath(gpa, "b", "a", null, .{ .if_generation_not_match = 9 }),
    );
    // Upload paths already carry a query; conditions append to it.
    try expectPath(
        "/upload/storage/v1/b/b/o?uploadType=multipart&ifGenerationMatch=0",
        try uploadMultipartPath(gpa, "b", .does_not_exist),
    );
    try expectPath(
        "/upload/storage/v1/b/b/o?uploadType=resumable&ifGenerationMatch=12",
        try uploadResumablePath(gpa, "b", .{ .if_generation_match = 12 }),
    );
    try expectPath("/upload/storage/v1/b/b/o?uploadType=resumable", try uploadResumablePath(gpa, "b", .{}));
}

test "rewrite paths name both objects and carry the loop's state" {
    const gpa = testing.allocator;
    try expectPath(
        "/storage/v1/b/src-b/o/reports%2Fq3.txt/rewriteTo/b/dst-b/o/copy%2Fq3.txt",
        try rewritePath(gpa, "src-b", "reports/q3.txt", "dst-b", "copy/q3.txt", .{}, null),
    );
    try expectPath(
        "/storage/v1/b/s/o/a/rewriteTo/b/d/o/b?sourceGeneration=5&ifGenerationMatch=0&rewriteToken=t%2B1",
        try rewritePath(gpa, "s", "a", "d", "b", .{
            .source_generation = 5,
            .preconditions = .does_not_exist,
        }, "t+1"),
    );
}
