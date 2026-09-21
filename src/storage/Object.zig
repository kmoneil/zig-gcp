//! A cheap handle on one object: metadata, existence and deletion. Making
//! one sends nothing. Uploads and downloads arrive in later milestones.

const Object = @This();

const std = @import("std");
const core = @import("core");

const Client = @import("Client.zig");
const codec = @import("codec.zig");
const errors = @import("errors.zig");
const names = @import("names.zig");
const rpc = @import("rpc.zig");
const types = @import("types.zig");
const Error = errors.Error;

/// Borrowed; the handle must not outlive it.
client: *Client,
/// Borrowed; the handle must not outlive it.
bucket: []const u8,
/// Borrowed; the handle must not outlive it.
name: []const u8,

/// The object's metadata: the live generation, or the one `options` names.
pub fn get(self: Object, options: types.GetOptions) Error!types.Owned(types.ObjectInfo) {
    rpc.begin(self.client);
    try rpc.checkBucketName(self.client, self.bucket);
    try rpc.checkObjectName(self.client, self.name);
    var scratch: std.heap.ArenaAllocator = .init(self.client.gpa);
    defer scratch.deinit();
    const path = try names.objectPath(scratch.allocator(), self.bucket, self.name, options.generation);

    var result: types.Owned(types.ObjectInfo) = try .init(self.client.gpa);
    errdefer result.deinit();
    const response = try rpc.execute(self.client, result.arena, .{ .method = .GET, .path = path });
    result.value = codec.decodeObject(result.arena.allocator(), response) catch |err|
        return rpc.decodeFailed(self.client, err, "object");
    return result;
}

/// Sugar over `get`: whether a live object has this name. `NotFound`
/// becomes false; every other failure stays an error.
pub fn exists(self: Object) Error!bool {
    var info = self.get(.{}) catch |err| switch (err) {
        error.NotFound => return false,
        else => |e| return e,
    };
    info.deinit();
    return true;
}

/// Deletes the object: the live generation, or the one `options` names.
/// Without a `generation` the delete is not retried, unless
/// `retry_unconditional_writes` opted in: the first attempt may have
/// succeeded before the connection dropped, and a blind repeat could then
/// remove someone else's newer object.
pub fn delete(self: Object, options: types.DeleteOptions) Error!void {
    rpc.begin(self.client);
    try rpc.checkBucketName(self.client, self.bucket);
    try rpc.checkObjectName(self.client, self.name);
    var scratch: std.heap.ArenaAllocator = .init(self.client.gpa);
    defer scratch.deinit();
    const path = try names.objectPath(scratch.allocator(), self.bucket, self.name, options.generation);
    try rpc.executeDiscard(self.client, .{
        .method = .DELETE,
        .path = path,
        .retry = options.generation != null or self.client.retry_unconditional_writes,
    });
}

const testing = std.testing;
const test_util = @import("test_util.zig");

test "golden: get, a pinned generation, and delete" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = "{\"name\":\"reports/2026/q3.txt\",\"bucket\":\"my-bucket\",\"size\":\"12\",\"generation\":\"7\"}" } },
        .{ .respond = .{ .body = "{\"name\":\"reports/2026/q3.txt\",\"generation\":\"6\"}" } },
        .{ .respond = .{ .status = 204, .body = "" } },
    }, .{});
    defer h.deinit();
    const obj = h.client.bucket("my-bucket").object("reports/2026/q3.txt");

    var live = try obj.get(.{});
    defer live.deinit();
    try h.expectRequest(
        0,
        .GET,
        "https://storage.googleapis.com/storage/v1/b/my-bucket/o/reports%2F2026%2Fq3.txt",
        null,
    );
    try testing.expectEqual(12, live.value.size);
    try testing.expectEqual(7, live.value.generation);

    var pinned = try obj.get(.{ .generation = 6 });
    defer pinned.deinit();
    try h.expectRequest(
        1,
        .GET,
        "https://storage.googleapis.com/storage/v1/b/my-bucket/o/reports%2F2026%2Fq3.txt?generation=6",
        null,
    );

    try obj.delete(.{ .generation = 7 });
    try h.expectRequest(
        2,
        .DELETE,
        "https://storage.googleapis.com/storage/v1/b/my-bucket/o/reports%2F2026%2Fq3.txt?generation=7",
        null,
    );
}

test "exists: found, missing, and a failure that is neither" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = "{\"name\":\"a\"}" } },
        .{ .respond = .{ .status = 404, .body = "{\"error\":{\"code\":404,\"errors\":[{\"reason\":\"notFound\"}]}}" } },
        .{ .respond = .{ .status = 403, .body = "{\"error\":{\"code\":403,\"errors\":[{\"reason\":\"forbidden\"}]}}" } },
    }, .{});
    defer h.deinit();
    const obj = h.client.bucket("my-bucket").object("a");
    try testing.expect(try obj.exists());
    try testing.expect(!try obj.exists());
    try testing.expectError(error.PermissionDenied, obj.exists());
}

test "delete retries only when it can do so safely" {
    var h: test_util.Harness = undefined;
    const unavailable: test_util.FakeTransport.Reply = .{ .respond = .{
        .status = 503,
        .body = "{\"error\":{\"code\":503,\"errors\":[{\"reason\":\"backendError\"}]}}",
    } };
    try h.init(&.{
        // Without a generation: one attempt, no retry.
        unavailable,
        // With a generation: retried to success.
        unavailable,
        .{ .respond = .{ .status = 204, .body = "" } },
    }, .{ .retry = .{ .max_attempts = 3, .initial_backoff_ms = 1 } });
    defer h.deinit();
    const obj = h.client.bucket("my-bucket").object("a");

    try testing.expectError(error.Unavailable, obj.delete(.{}));
    try h.expectRequestCount(1);
    try obj.delete(.{ .generation = 7 });
    try h.expectRequestCount(3);
}

test "delete without a generation retries when the client opted in" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .status = 503, .body = "{}" } },
        .{ .respond = .{ .status = 204, .body = "" } },
    }, .{ .retry = .{ .max_attempts = 2, .initial_backoff_ms = 1 }, .retry_unconditional_writes = true });
    defer h.deinit();
    try h.client.bucket("my-bucket").object("a").delete(.{});
    try h.expectRequestCount(2);
}

test "bad object names fail before sending" {
    var h: test_util.Harness = undefined;
    try h.init(&.{}, .{});
    defer h.deinit();
    const bucket = h.client.bucket("my-bucket");
    try testing.expectError(error.InvalidObjectName, bucket.object("").get(.{}));
    try testing.expectError(error.InvalidObjectName, bucket.object(".").delete(.{}));
    try testing.expectError(error.InvalidObjectName, bucket.object("..").exists());
    try testing.expectError(error.InvalidObjectName, bucket.object("a\nb").get(.{}));
    try h.expectRequestCount(0);
}
