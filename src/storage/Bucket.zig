//! A cheap handle on one bucket: create, get, delete and list its objects,
//! and hand out `Object` handles. Making one sends nothing.

const Bucket = @This();

const std = @import("std");
const core = @import("core");

const Client = @import("Client.zig");
const Object = @import("Object.zig");
const codec = @import("codec.zig");
const errors = @import("errors.zig");
const names = @import("names.zig");
const rpc = @import("rpc.zig");
const types = @import("types.zig");
const Error = errors.Error;

/// Borrowed; the handle must not outlive it.
client: *Client,
/// Borrowed; the handle must not outlive it.
name: []const u8,

/// Creates the bucket in the client's project, which `Options.project_id`
/// must name. Safe to retry: a lost first success shows up as
/// `error.AlreadyExists`.
pub fn create(self: Bucket, config: types.BucketConfig) Error!types.Owned(types.BucketInfo) {
    rpc.begin(self.client);
    try rpc.checkBucketName(self.client, self.name);
    const project = try rpc.requireProject(self.client);
    var scratch: std.heap.ArenaAllocator = .init(self.client.gpa);
    defer scratch.deinit();
    const path = try names.bucketsPath(scratch.allocator(), project, .{});
    const body = try codec.encodeBucket(scratch.allocator(), self.name, config);

    var result: types.Owned(types.BucketInfo) = try .init(self.client.gpa);
    errdefer result.deinit();
    const response = try rpc.execute(self.client, result.arena, .{ .method = .POST, .path = path, .body = body });
    result.value = codec.decodeBucket(result.arena.allocator(), response) catch |err|
        return rpc.decodeFailed(self.client, err, "bucket");
    return result;
}

/// The bucket's metadata.
pub fn get(self: Bucket) Error!types.Owned(types.BucketInfo) {
    rpc.begin(self.client);
    try rpc.checkBucketName(self.client, self.name);
    var scratch: std.heap.ArenaAllocator = .init(self.client.gpa);
    defer scratch.deinit();
    const path = try names.bucketPath(scratch.allocator(), self.name);

    var result: types.Owned(types.BucketInfo) = try .init(self.client.gpa);
    errdefer result.deinit();
    const response = try rpc.execute(self.client, result.arena, .{ .method = .GET, .path = path });
    result.value = codec.decodeBucket(result.arena.allocator(), response) catch |err|
        return rpc.decodeFailed(self.client, err, "bucket");
    return result;
}

/// Deletes the bucket, which must be empty. Safe to retry: a lost first
/// success shows up as `error.NotFound`.
pub fn delete(self: Bucket) Error!void {
    rpc.begin(self.client);
    try rpc.checkBucketName(self.client, self.name);
    var scratch: std.heap.ArenaAllocator = .init(self.client.gpa);
    defer scratch.deinit();
    const path = try names.bucketPath(scratch.allocator(), self.name);
    try rpc.executeDiscard(self.client, .{ .method = .DELETE, .path = path });
}

/// A handle for the object `name` in this bucket. Sends nothing. The handle
/// borrows the client and both names, and must not outlive them.
pub fn object(self: Bucket, name: []const u8) Object {
    return .{ .client = self.client, .bucket = self.name, .name = name };
}

/// One page of the bucket's objects, filtered and grouped by the options.
pub fn listObjects(self: Bucket, options: types.ListOptions) Error!types.Owned(types.ObjectPage) {
    rpc.begin(self.client);
    try rpc.checkBucketName(self.client, self.name);
    var scratch: std.heap.ArenaAllocator = .init(self.client.gpa);
    defer scratch.deinit();
    const path = try names.objectsPath(scratch.allocator(), self.name, options);

    var result: types.Owned(types.ObjectPage) = try .init(self.client.gpa);
    errdefer result.deinit();
    const response = try rpc.execute(self.client, result.arena, .{ .method = .GET, .path = path });
    result.value = codec.decodeObjectPage(result.arena.allocator(), response) catch |err|
        return rpc.decodeFailed(self.client, err, "object list");
    return result;
}

const testing = std.testing;
const test_util = @import("test_util.zig");

test "golden: bucket create, get, delete" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = "{\"name\":\"zigps-b\",\"location\":\"US\",\"storageClass\":\"STANDARD\"}" } },
        .{ .respond = .{ .body = "{\"name\":\"zigps-b\",\"location\":\"US\"}" } },
        .{ .respond = .{ .status = 204, .body = "" } },
    }, .{});
    defer h.deinit();

    var created = try h.client.bucket("zigps-b").create(.{});
    defer created.deinit();
    try h.expectRequest(
        0,
        .POST,
        "https://storage.googleapis.com/storage/v1/b?project=extractctl",
        "{\"name\":\"zigps-b\",\"location\":\"US\",\"storageClass\":\"STANDARD\"}",
    );
    try testing.expectEqualStrings("zigps-b", created.value.name);
    try testing.expectEqualStrings("US", created.value.location);

    var got = try h.client.bucket("zigps-b").get();
    defer got.deinit();
    try h.expectRequest(1, .GET, "https://storage.googleapis.com/storage/v1/b/zigps-b", null);

    try h.client.bucket("zigps-b").delete();
    try h.expectRequest(2, .DELETE, "https://storage.googleapis.com/storage/v1/b/zigps-b", null);
}

test "golden: listObjects with prefix, delimiter and paging" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body =
        \\{"items":[{"name":"reports/2026/q3.txt","size":"12"}],
        \\ "prefixes":["reports/2026/archive/"],"nextPageToken":"t"}
        } },
    }, .{});
    defer h.deinit();

    var page = try h.client.bucket("my-bucket").listObjects(.{
        .prefix = "reports/",
        .delimiter = "/",
        .page_size = 2,
    });
    defer page.deinit();
    try h.expectRequest(
        0,
        .GET,
        "https://storage.googleapis.com/storage/v1/b/my-bucket/o?prefix=reports%2F&delimiter=%2F&maxResults=2",
        null,
    );
    try testing.expectEqual(1, page.value.objects.len);
    try testing.expectEqual(12, page.value.objects[0].size);
    try testing.expectEqualStrings("reports/2026/archive/", page.value.prefixes[0]);
    try testing.expectEqualStrings("t", page.value.next_page_token.?);
}

test "create without a project, and bad bucket names, fail before sending" {
    var h: test_util.Harness = undefined;
    try h.init(&.{}, .{ .project_id = null });
    defer h.deinit();
    try testing.expectError(error.MissingProject, h.client.bucket("b").create(.{}));
    try testing.expectError(error.InvalidBucketName, h.client.bucket("a/b").get());
    try testing.expectError(error.InvalidBucketName, h.client.bucket("").delete());
    try testing.expectError(error.InvalidBucketName, h.client.bucket("a b").listObjects(.{}));
    try h.expectRequestCount(0);
}

test "an error body maps by HTTP code and keeps the reason" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .status = 404, .body =
        \\{"error":{"code":404,"message":"No such bucket: zigps-missing",
        \\ "errors":[{"message":"No such bucket: zigps-missing","domain":"global","reason":"notFound"}]}}
        } },
        .{ .respond = .{ .status = 409, .body =
        \\{"error":{"code":409,"message":"You already own this bucket.",
        \\ "errors":[{"reason":"conflict"}]}}
        } },
    }, .{ .retry = .{ .max_attempts = 1 } });
    defer h.deinit();

    try testing.expectError(error.NotFound, h.client.bucket("zigps-missing").get());
    try testing.expectEqual(404, h.diag.http_status);
    try testing.expectEqualStrings("notFound", h.diag.status());
    try testing.expectEqualStrings("No such bucket: zigps-missing", h.diag.message());

    try testing.expectError(error.AlreadyExists, h.client.bucket("zigps-b").create(.{}));
    try testing.expectEqualStrings("conflict", h.diag.status());
}
