//! Bringing back what soft delete keeps: one object's generation, many
//! objects at once through a bulk restore, and a deleted bucket, and
//! following the long-running operations a bulk restore starts.
//!
//! Measured against Cloud Storage on 2026-09-29:
//!
//! - A restore makes a new generation, metageneration 1, with the
//!   soft-deleted object's metadata, custom time and storage class, and
//!   leaves the soft-deleted generation where it was: restoring it again
//!   makes a second copy and pushes the first into soft delete. An
//!   `X-Goog-Gcs-Idempotency-Token` changes nothing there, so a restore is
//!   retried only under `if_generation_match`, whose repeat fails instead.
//! - A restore under `ifGenerationMatch=0` over a live object is 412. A
//!   live generation, or one that never was, is 404. A bucket without soft
//!   delete refuses restores, and soft-deleted listings, with 400.
//! - A bulk restore start that repeats an `X-Goog-Gcs-Idempotency-Token`
//!   gets the operation the first start began, so a start is retried with
//!   its token. A bucket runs one bulk restore at a time: another start
//!   meanwhile is 429, and the bucket cannot be deleted until it ends
//!   (409). One took three minutes to restore three objects, reporting no
//!   progress, only counts; a cancel ends one with code 1.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Stringify = std.json.Stringify;
const core = @import("core");

const Client = @import("Client.zig");
const codec = @import("codec.zig");
const idempotency = @import("idempotency.zig");
const names = @import("names.zig");
const rpc = @import("rpc.zig");
const types = @import("types.zig");
const Error = @import("errors.zig").Error;

/// Restores one soft-deleted generation. The caller has begun the call and
/// checked both names.
pub fn restoreObject(
    client: *Client,
    bucket: []const u8,
    object: []const u8,
    options: types.RestoreOptions,
) Error!types.Owned(types.ObjectInfo) {
    var scratch: std.heap.ArenaAllocator = .init(client.gpa);
    defer scratch.deinit();
    const path = try names.objectRestorePath(scratch.allocator(), bucket, object, options);
    const repeatable = options.preconditions.makesWriteSafe() or client.retry_unconditional_writes;
    // A repeated restore makes another copy, token or not, as measured.
    var token: idempotency.Token = undefined;
    token.init(client);

    var result: types.Owned(types.ObjectInfo) = try .init(client.gpa);
    errdefer result.deinit();
    const response = rpc.execute(client, result.arena, .{ .method = .POST, .path = path, .headers = token.slice(), .retry = repeatable }) catch |err| switch (err) {
        error.FailedPrecondition => {
            if (repeatable) rpc.replace412(client, "the precondition failed; if this call was a retry, an earlier attempt may have restored the object: get it to see");
            return error.FailedPrecondition;
        },
        else => |e| return e,
    };
    result.value = codec.decodeObject(result.arena.allocator(), response) catch |err|
        return rpc.decodeFailed(client, err, "object");
    return result;
}

/// Starts a bulk restore. Its idempotency token is fresh per call and the
/// same on every retry of it, so a start whose answer was lost is not
/// started twice. It carries one whatever `Options.idempotency_tokens`
/// says: its retries depend on it.
pub fn bulkRestore(client: *Client, bucket: []const u8, options: types.BulkRestoreOptions) Error!types.Owned(types.OperationInfo) {
    try checkBulkRestore(client.diagnostics, options);
    var scratch: std.heap.ArenaAllocator = .init(client.gpa);
    defer scratch.deinit();
    const path = try names.bulkRestorePath(scratch.allocator(), bucket);
    const body = try encodeBulkRestore(scratch.allocator(), options);
    var token: [32]u8 = undefined;
    idempotency.make(client.io, &token);
    const headers = [_]core.transport.Header{.{ .name = idempotency.header_name, .value = &token }};

    var result: types.Owned(types.OperationInfo) = try .init(client.gpa);
    errdefer result.deinit();
    const response = try rpc.execute(client, result.arena, .{ .method = .POST, .path = path, .body = body, .headers = &headers });
    result.value = codec.decodeOperation(result.arena.allocator(), response) catch |err|
        return rpc.decodeFailed(client, err, "operation");
    return result;
}

/// One operation of the bucket's.
pub fn operation(client: *Client, bucket: []const u8, id: []const u8) Error!types.Owned(types.OperationInfo) {
    try checkOperationId(client, id);
    var scratch: std.heap.ArenaAllocator = .init(client.gpa);
    defer scratch.deinit();
    const path = try names.operationsPath(scratch.allocator(), bucket, .{ .get = id });

    var result: types.Owned(types.OperationInfo) = try .init(client.gpa);
    errdefer result.deinit();
    const response = try rpc.execute(client, result.arena, .{ .method = .GET, .path = path });
    result.value = codec.decodeOperation(result.arena.allocator(), response) catch |err|
        return rpc.decodeFailed(client, err, "operation");
    return result;
}

/// Asks the server to stop an operation, which ends it with code 1. A
/// repeat asks again, so it is retried.
pub fn cancelOperation(client: *Client, bucket: []const u8, id: []const u8) Error!void {
    try checkOperationId(client, id);
    var scratch: std.heap.ArenaAllocator = .init(client.gpa);
    defer scratch.deinit();
    const path = try names.operationsPath(scratch.allocator(), bucket, .{ .cancel = id });
    var token: idempotency.Token = undefined;
    token.init(client);
    try rpc.executeDiscard(client, .{ .method = .POST, .path = path, .headers = token.slice() });
}

/// One page of the bucket's operations, finished ones included.
pub fn listOperations(client: *Client, bucket: []const u8, page: types.PageOptions) Error!types.Owned(types.OperationPage) {
    var scratch: std.heap.ArenaAllocator = .init(client.gpa);
    defer scratch.deinit();
    const path = try names.operationsPath(scratch.allocator(), bucket, .{ .list = page });

    var result: types.Owned(types.OperationPage) = try .init(client.gpa);
    errdefer result.deinit();
    const response = try rpc.execute(client, result.arena, .{ .method = .GET, .path = path });
    result.value = codec.decodeOperationPage(result.arena.allocator(), response) catch |err|
        return rpc.decodeFailed(client, err, "operation list");
    return result;
}

/// One page of the project's soft-deleted buckets.
pub fn listSoftDeletedBuckets(client: *Client, page: types.PageOptions) Error!types.Owned(types.BucketPage) {
    const project = try rpc.requireProject(client);
    var scratch: std.heap.ArenaAllocator = .init(client.gpa);
    defer scratch.deinit();
    const path = try names.softDeletedBucketsPath(scratch.allocator(), project, page);

    var result: types.Owned(types.BucketPage) = try .init(client.gpa);
    errdefer result.deinit();
    const response = try rpc.execute(client, result.arena, .{ .method = .GET, .path = path });
    result.value = codec.decodeBucketPage(result.arena.allocator(), response) catch |err|
        return rpc.decodeFailed(client, err, "bucket list");
    return result;
}

/// Restores a soft-deleted bucket: its settings, not its objects. The
/// caller has begun the call and checked the name.
pub fn restoreBucket(client: *Client, bucket: []const u8, generation: u64) Error!types.Owned(types.BucketInfo) {
    var scratch: std.heap.ArenaAllocator = .init(client.gpa);
    defer scratch.deinit();
    const path = try names.bucketRestorePath(scratch.allocator(), bucket, generation);
    var token: idempotency.Token = undefined;
    token.init(client);

    var result: types.Owned(types.BucketInfo) = try .init(client.gpa);
    errdefer result.deinit();
    const response = try rpc.execute(client, result.arena, .{ .method = .POST, .path = path, .headers = token.slice() });
    result.value = codec.decodeBucket(result.arena.allocator(), response) catch |err|
        return rpc.decodeFailed(client, err, "bucket");
    return result;
}

fn checkOperationId(client: *Client, id: []const u8) Error!void {
    if (id.len != 0) return;
    if (client.diagnostics) |d| d.print("an operation id is not empty: Operation.id names one", .{});
    return error.InvalidArgument;
}

/// The time bounds are RFC 3339, which the server alone would otherwise
/// judge after the operation was queued.
pub fn checkBulkRestore(diag: ?*core.Diagnostics, options: types.BulkRestoreOptions) error{InvalidArgument}!void {
    const bounds = [_]struct { []const u8, ?[]const u8 }{
        .{ "soft_deleted_after", options.soft_deleted_after },
        .{ "soft_deleted_before", options.soft_deleted_before },
        .{ "created_after", options.created_after },
        .{ "created_before", options.created_before },
    };
    for (bounds) |bound| if (bound[1]) |text| {
        _ = core.timestamp.parse(text) catch {
            if (diag) |d| d.print("{s} is not an RFC 3339 time, such as 2026-09-29T15:00:00Z", .{bound[0]});
            return error.InvalidArgument;
        };
    };
}

/// The `objects.bulkRestore` body. `allowOverwrite` always goes, since it
/// decides what happens to live objects; the rest only when set.
pub fn encodeBulkRestore(arena: Allocator, options: types.BulkRestoreOptions) Allocator.Error![]u8 {
    var out: Writer.Allocating = .init(arena);
    var jw: Stringify = .{ .writer = &out.writer };
    writeBulkRestore(&jw, options) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn writeBulkRestore(jw: *Stringify, options: types.BulkRestoreOptions) Stringify.Error!void {
    try jw.beginObject();
    if (options.match_globs.len > 0) {
        try jw.objectField("matchGlobs");
        try jw.beginArray();
        for (options.match_globs) |glob| try jw.write(glob);
        try jw.endArray();
    }
    const times = [_]struct { []const u8, ?[]const u8 }{
        .{ "softDeletedAfterTime", options.soft_deleted_after },
        .{ "softDeletedBeforeTime", options.soft_deleted_before },
        .{ "createdAfterTime", options.created_after },
        .{ "createdBeforeTime", options.created_before },
    };
    for (times) |field| if (field[1]) |text| {
        try jw.objectField(field[0]);
        try jw.write(text);
    };
    try jw.objectField("allowOverwrite");
    try jw.write(options.allow_overwrite);
    if (options.copy_source_acl) {
        try jw.objectField("copySourceAcl");
        try jw.write(true);
    }
    try jw.endObject();
}

const testing = std.testing;
const test_util = @import("test_util.zig");

/// Captured from Cloud Storage on 2026-09-29: a restore's answer. The new
/// generation carries the soft-deleted one's custom time and metadata.
const restored =
    \\{
    \\  "kind": "storage#object",
    \\  "id": "zigps-p3-3f1672/s/a/1790696692171179",
    \\  "name": "s/a",
    \\  "bucket": "zigps-p3-3f1672",
    \\  "generation": "1790696692171179",
    \\  "metageneration": "1",
    \\  "contentType": "application/octet-stream",
    \\  "storageClass": "STANDARD",
    \\  "size": "2",
    \\  "md5Hash": "VkBIbapogNZnt2yViCA2Gg==",
    \\  "crc32c": "UryDEg==",
    \\  "etag": "CKuD84GRlJcDEAE=",
    \\  "timeCreated": "2026-09-29T15:44:52.181Z",
    \\  "updated": "2026-09-29T15:44:52.181Z",
    \\  "customTime": "2026-01-01T00:00:00Z",
    \\  "metadata": {
    \\    "k": "v"
    \\  }
    \\}
;

/// Captured the same day: the answer to a restore under ifGenerationMatch=0
/// over a live object.
const condition_not_met =
    \\{"error":{"code":412,"message":"At least one of the pre-conditions you specified did not hold.",
    \\ "errors":[{"message":"At least one of the pre-conditions you specified did not hold.","domain":"global",
    \\ "reason":"conditionNotMet","locationType":"header","location":"If-Match"}]}}
;

test "golden: restore sends the generation and no body, and answers the new generation" {
    var h: test_util.Harness = undefined;
    try h.init(&.{.{ .respond = .{ .body = restored } }}, .{});
    defer h.deinit();
    var info = try h.client.bucket("zigps-p3-3f1672").object("s/a").restore(.{
        .generation = 1790696691452101,
        .preconditions = .does_not_exist,
    });
    defer info.deinit();
    try h.expectRequest(
        0,
        .POST,
        "https://storage.googleapis.com/storage/v1/b/zigps-p3-3f1672/o/s%2Fa/restore?projection=noAcl&generation=1790696691452101&ifGenerationMatch=0",
        null,
    );
    try testing.expectEqual(1790696692171179, info.value.generation);
    try testing.expectEqual(1, info.value.metageneration);
    try testing.expectEqualStrings("v", info.value.metadataValue("k").?);
}

test "restore: retried only under if_generation_match, and a repeat that meets its own copy says so" {
    // Unconditional: one 503 ends it, since a repeat would make a copy.
    var h: test_util.Harness = undefined;
    try h.init(&.{.{ .respond = .{ .status = 503, .body = "{}" } }}, .{});
    defer h.deinit();
    try testing.expectError(error.Unavailable, h.client.bucket("b").object("a").restore(.{ .generation = 7 }));
    try h.expectRequestCount(1);

    // A metageneration condition does not make it safe: the new copy is at
    // metageneration 1 too.
    var meta: test_util.Harness = undefined;
    try meta.init(&.{.{ .respond = .{ .status = 503, .body = "{}" } }}, .{});
    defer meta.deinit();
    try testing.expectError(error.Unavailable, meta.client.bucket("b").object("a").restore(.{
        .generation = 7,
        .preconditions = .{ .if_metageneration_match = 1 },
    }));
    try meta.expectRequestCount(1);

    // Under if_generation_match, the first attempt landed and lost its
    // answer; the repeat meets the copy it made.
    var conditional: test_util.Harness = undefined;
    try conditional.init(&.{
        .{ .fail = error.ConnectionResetByPeer },
        .{ .respond = .{ .status = 412, .body = condition_not_met } },
    }, .{});
    defer conditional.deinit();
    try testing.expectError(error.FailedPrecondition, conditional.client.bucket("b").object("a").restore(.{
        .generation = 7,
        .preconditions = .does_not_exist,
    }));
    try conditional.expectRequestCount(2);
    try testing.expect(std.mem.indexOf(u8, conditional.diag.message(), "may have restored the object") != null);
    try testing.expectEqualStrings("conditionNotMet", conditional.diag.status());

    var opted_in: test_util.Harness = undefined;
    try opted_in.init(&.{
        .{ .respond = .{ .status = 503, .body = "{}" } },
        .{ .respond = .{ .body = restored } },
    }, .{ .retry_unconditional_writes = true });
    defer opted_in.deinit();
    var info = try opted_in.client.bucket("b").object("a").restore(.{ .generation = 7 });
    info.deinit();
    try opted_in.expectRequestCount(2);
}

test "restore: what Cloud Storage refuses, as it answered" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .status = 400, .body =
        \\{"error":{"code":400,"message":"bucket soft delete policy must be set.",
        \\ "errors":[{"message":"bucket soft delete policy must be set.","domain":"global","reason":"invalid"}]}}
        } },
        .{ .respond = .{ .status = 404, .body =
        \\{"error":{"code":404,"message":"No such object: zigps-p3-3f1672/s/a",
        \\ "errors":[{"message":"No such object: zigps-p3-3f1672/s/a","domain":"global","reason":"notFound"}]}}
        } },
    }, .{ .retry = .{ .max_attempts = 1 } });
    defer h.deinit();
    const obj = h.client.bucket("b").object("s/a");
    try testing.expectError(error.InvalidArgument, obj.restore(.{ .generation = 7 }));
    try testing.expectEqualStrings("bucket soft delete policy must be set.", h.diag.message());
    // A live generation, as a generation that never was.
    try testing.expectError(error.NotFound, obj.restore(.{ .generation = 8 }));
    // Names are checked like every call's.
    try testing.expectError(error.InvalidObjectName, h.client.bucket("b").object("").restore(.{ .generation = 1 }));
    try h.expectRequestCount(2);
}

/// Captured the same day: a bulk restore just started, with its counts.
const bulk_started =
    \\{"kind":"storage#operation",
    \\ "name":"projects/_/buckets/zigps-p3-3f1672/operations/CiQ4ZTQwNWQ4NS04Y2FkLTQ0ZmUtYTMwOC1mNTI5ODZmMGJhMGQQAg",
    \\ "done":false,"metadata":{"@type":"type.googleapis.com/google.storage.control.v2.BulkRestoreObjectsMetadata",
    \\ "commonMetadata":{"createTime":"2026-09-29T15:44:54.236Z","updateTime":"2026-09-29T15:44:54.236Z",
    \\ "type":"bulk-restore-objects","requestedCancellation":false,"progressPercent":-1},
    \\ "matchGlobs":["bulk/**"],"allowOverwrite":false,"copySourceAcl":false,
    \\ "succeededCount":"0","skippedCount":"0","failedCount":"0"}}
;

/// The same operation, finished.
const bulk_done =
    \\{"kind":"storage#operation",
    \\ "name":"projects/_/buckets/zigps-p3-3f1672/operations/CiQ4ZTQwNWQ4NS04Y2FkLTQ0ZmUtYTMwOC1mNTI5ODZmMGJhMGQQAg",
    \\ "done":true,"response":{"@type":"type.googleapis.com/google.storage.control.v2.BulkRestoreObjectsResponse"},
    \\ "metadata":{"@type":"type.googleapis.com/google.storage.control.v2.BulkRestoreObjectsMetadata",
    \\ "commonMetadata":{"createTime":"2026-09-29T15:44:54.236Z","endTime":"2026-09-29T15:48:30.692Z",
    \\ "updateTime":"2026-09-29T15:48:30.692Z","type":"bulk-restore-objects","requestedCancellation":false,
    \\ "progressPercent":-1},"matchGlobs":["bulk/**"],"allowOverwrite":false,"copySourceAcl":false,
    \\ "succeededCount":"3","skippedCount":"13","failedCount":"0"}}
;

/// Another, cancelled before it began.
const bulk_cancelled =
    \\{"kind":"storage#operation",
    \\ "name":"projects/_/buckets/zigps-p3-3f1672/operations/CiRlMjJlNjBmZC04ZDI3LTQ0MDgtOGI2ZC0xMjJmNDNmYjhlODgQAg",
    \\ "done":true,"error":{"code":1,"message":"The long-running operation has been cancelled by the user."},
    \\ "metadata":{"@type":"type.googleapis.com/google.storage.control.v2.BulkRestoreObjectsMetadata",
    \\ "commonMetadata":{"createTime":"2026-09-29T15:41:10.930Z","endTime":"2026-09-29T15:44:37.630Z",
    \\ "updateTime":"2026-09-29T15:44:37.630Z","type":"bulk-restore-objects","requestedCancellation":true,
    \\ "progressPercent":-1},"allowOverwrite":false,"copySourceAcl":false,
    \\ "succeededCount":"0","skippedCount":"0","failedCount":"0"}}
;

fn tokenOf(h: *const test_util.Harness, index: usize) ![]const u8 {
    const r = try h.fake.request(index);
    for (r.headers) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "X-Goog-Gcs-Idempotency-Token")) return header.value;
    }
    return error.TestNoToken;
}

test "golden: bulk restore sends its body and a token, the same token on its retry" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .status = 503, .body = "{}" } },
        .{ .respond = .{ .body = bulk_started } },
        .{ .respond = .{ .body = bulk_started } },
    }, .{});
    defer h.deinit();
    const b = h.client.bucket("zigps-p3-3f1672");
    var op = try b.bulkRestore(.{
        .match_globs = &.{ "bulk/**", "logs/*.gz" },
        .soft_deleted_after = "2026-09-29T00:00:00Z",
        .created_before = "2026-09-30T00:00:00.5+02:00",
        .copy_source_acl = true,
    });
    defer op.deinit();
    try h.expectRequest(
        0,
        .POST,
        "https://storage.googleapis.com/storage/v1/b/zigps-p3-3f1672/o/bulkRestore",
        "{\"matchGlobs\":[\"bulk/**\",\"logs/*.gz\"],\"softDeletedAfterTime\":\"2026-09-29T00:00:00Z\"," ++
            "\"createdBeforeTime\":\"2026-09-30T00:00:00.5+02:00\",\"allowOverwrite\":false,\"copySourceAcl\":true}",
    );
    // A retry carries the token the first attempt did.
    const first = try tokenOf(&h, 0);
    try testing.expectEqual(32, first.len);
    for (first) |c| try testing.expect(std.ascii.isHex(c));
    try testing.expectEqualStrings(first, try tokenOf(&h, 1));
    try testing.expectEqualStrings("CiQ4ZTQwNWQ4NS04Y2FkLTQ0ZmUtYTMwOC1mNTI5ODZmMGJhMGQQAg", op.value.id);
    try testing.expect(!op.value.done);
    try testing.expectEqual(null, op.value.progress_percent);

    // Every default: everything restorable, and nothing live replaced.
    var all = try b.bulkRestore(.{});
    defer all.deinit();
    try h.expectRequest(2, .POST, "https://storage.googleapis.com/storage/v1/b/zigps-p3-3f1672/o/bulkRestore", "{\"allowOverwrite\":false}");
    // A new call, a new token.
    try testing.expect(!std.mem.eql(u8, first, try tokenOf(&h, 2)));
}

test "bulk restore: bounds that are not RFC 3339 are refused before sending" {
    var h: test_util.Harness = undefined;
    try h.init(&.{}, .{});
    defer h.deinit();
    const b = h.client.bucket("b");
    for ([_]types.BulkRestoreOptions{
        .{ .soft_deleted_after = "2026-09-29" },
        .{ .soft_deleted_before = "yesterday" },
        .{ .created_after = "" },
        .{ .created_before = "2026-09-29T25:00:00Z" },
    }) |options| {
        try testing.expectError(error.InvalidArgument, b.bulkRestore(options));
        try testing.expect(std.mem.indexOf(u8, h.diag.message(), "is not an RFC 3339 time") != null);
    }
    try h.expectRequestCount(0);
}

test "golden: an operation followed to its end, cancelled, listed, and not found" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = bulk_done } },
        .{ .respond = .{ .status = 204, .body = "" } },
        .{ .respond = .{ .status = 412, .body =
        \\{"error":{"code":412,"message":"The long-running operation is already done.",
        \\ "errors":[{"message":"The long-running operation is already done.","domain":"global","reason":"conditionNotMet"}]}}
        } },
        .{ .respond = .{ .body = "{\"kind\":\"storage#operations\",\"operations\":[" ++ bulk_done ++ "," ++ bulk_cancelled ++ "]}" } },
        .{ .respond = .{ .status = 404, .body =
        \\{"error":{"code":404,"message":"The specified long-running operation does not exist.",
        \\ "errors":[{"message":"The specified long-running operation does not exist.","domain":"global","reason":"notFound"}]}}
        } },
    }, .{});
    defer h.deinit();
    const b = h.client.bucket("zigps-p3-3f1672");
    const id = "CiQ4ZTQwNWQ4NS04Y2FkLTQ0ZmUtYTMwOC1mNTI5ODZmMGJhMGQQAg";

    var done = try b.operation(id);
    defer done.deinit();
    try h.expectRequest(0, .GET, "https://storage.googleapis.com/storage/v1/b/zigps-p3-3f1672/operations/" ++ id, null);
    try testing.expect(done.value.done);
    try testing.expectEqual(null, done.value.failure);
    try testing.expectEqual(3, done.value.succeeded);
    try testing.expectEqual(13, done.value.skipped);
    try testing.expectEqual(0, done.value.failed);
    try testing.expectEqualStrings("2026-09-29T15:48:30.692Z", done.value.end_time.?);

    try b.cancelOperation("CiRlMjJl");
    try h.expectRequest(1, .POST, "https://storage.googleapis.com/storage/v1/b/zigps-p3-3f1672/operations/CiRlMjJl/cancel", null);
    // A finished operation cannot be cancelled.
    try testing.expectError(error.FailedPrecondition, b.cancelOperation(id));

    var page = try b.listOperations(.{ .page_size = 10 });
    defer page.deinit();
    try h.expectRequest(3, .GET, "https://storage.googleapis.com/storage/v1/b/zigps-p3-3f1672/operations?maxResults=10", null);
    try testing.expectEqual(2, page.value.operations.len);
    const cancelled = page.value.operations[1];
    try testing.expect(cancelled.requested_cancellation);
    try testing.expectEqual(1, cancelled.failure.?.code);
    try testing.expectEqualStrings("The long-running operation has been cancelled by the user.", cancelled.failure.?.message);
    try testing.expectEqual(null, page.value.next_page_token);

    try testing.expectError(error.NotFound, b.operation("nosuchoperation"));
    try testing.expectError(error.InvalidArgument, b.operation(""));
    try testing.expectError(error.InvalidArgument, b.cancelOperation(""));
    try h.expectRequestCount(5);
}

test "golden: soft-deleted buckets listed, one restored, and what a restore can meet" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body =
        \\{"kind":"storage#buckets","items":[{"kind":"storage#bucket","name":"zigps-p3-3f1672",
        \\ "projectNumber":"82150720798","generation":"1790696464558417531","metageneration":"1",
        \\ "location":"US-CENTRAL1","storageClass":"STANDARD","timeCreated":"2026-09-29T15:41:04.784Z",
        \\ "updated":"2026-09-29T15:41:04.784Z","softDeleteTime":"2026-09-29T15:48:45.463Z",
        \\ "hardDeleteTime":"2026-10-06T15:49:45.290Z",
        \\ "softDeletePolicy":{"retentionDurationSeconds":"604800","effectiveTime":"2026-09-29T15:41:04.784Z"}}]}
        } },
        .{ .respond = .{ .status = 409, .body =
        \\{"error":{"code":409,"message":"A live bucket with this name already exists. The live bucket must be deleted before this bucket can be restored.",
        \\ "errors":[{"domain":"global","reason":"conflict"}]}}
        } },
        .{ .respond = .{ .body =
        \\{"kind":"storage#bucket","name":"zigps-p3-3f1672","generation":"1790696464558417531",
        \\ "metageneration":"1","location":"US-CENTRAL1","storageClass":"STANDARD",
        \\ "timeCreated":"2026-09-29T15:41:04.784Z","updated":"2026-09-29T15:48:52.073Z",
        \\ "softDeletePolicy":{"retentionDurationSeconds":"604800","effectiveTime":"2026-09-29T15:41:04.784Z"}}
        } },
        .{ .respond = .{ .status = 404, .body =
        \\{"error":{"code":404,"message":"The specified bucket does not exist.","errors":[{"reason":"notFound"}]}}
        } },
    }, .{});
    defer h.deinit();
    var page = try h.client.listSoftDeletedBuckets(.{ .page_size = 50 });
    defer page.deinit();
    try h.expectRequest(0, .GET, "https://storage.googleapis.com/storage/v1/b?project=extractctl&softDeleted=true&maxResults=50", null);
    const gone = page.value.buckets[0];
    try testing.expectEqual(1790696464558417531, gone.generation.?);
    try testing.expectEqualStrings("2026-09-29T15:48:45.463Z", gone.soft_delete_time.?);
    try testing.expectEqualStrings("2026-10-06T15:49:45.290Z", gone.hard_delete_time.?);

    const b = h.client.bucket("zigps-p3-3f1672");
    // While a live bucket has the name.
    try testing.expectError(error.AlreadyExists, b.restore(gone.generation.?));
    var back = try b.restore(gone.generation.?);
    defer back.deinit();
    try h.expectRequest(2, .POST, "https://storage.googleapis.com/storage/v1/b/zigps-p3-3f1672/restore?projection=noAcl&generation=1790696464558417531", null);
    try testing.expectEqual(null, back.value.soft_delete_time);
    try testing.expectEqual(604_800, back.value.soft_delete.?.retention_s);
    // Once restored, the soft-deleted bucket is gone: a repeat is NotFound.
    try testing.expectError(error.NotFound, b.restore(gone.generation.?));

    var no_project: test_util.Harness = undefined;
    try no_project.init(&.{}, .{ .project_id = null });
    defer no_project.deinit();
    try testing.expectError(error.MissingProject, no_project.client.listSoftDeletedBuckets(.{}));
}

fn restoreEverything(gpa: Allocator) !void {
    var fake: test_util.FakeTransport = .init(gpa, &.{
        .{ .respond = .{ .body = restored } },
        .{ .respond = .{ .body = bulk_started } },
        .{ .respond = .{ .body = "{\"operations\":[" ++ bulk_done ++ "," ++ bulk_cancelled ++ "]}" } },
        .{ .respond = .{ .body = "{\"items\":[{\"name\":\"b\",\"generation\":\"1\",\"softDeleteTime\":\"t\"}]}" } },
    });
    defer fake.deinit();
    var clock: test_util.FakeClock = .{};
    var token: test_util.FakeTokenProvider = .{ .token = "ya29.test-token" };
    var client: Client = try .init(gpa, clock.io(), .{
        .project_id = "extractctl",
        .token_provider = token.provider(),
        .transport = fake.transport(),
    });
    defer client.deinit();
    var one = try client.bucket("b").object("s/a").restore(.{ .generation = 1, .preconditions = .does_not_exist });
    one.deinit();
    var op = try client.bucket("b").bulkRestore(.{ .match_globs = &.{"bulk/**"}, .soft_deleted_after = "2026-09-29T00:00:00Z" });
    op.deinit();
    var ops = try client.bucket("b").listOperations(.{});
    ops.deinit();
    var gone = try client.listSoftDeletedBuckets(.{});
    gone.deinit();
}

test "restores: every allocation failure is OutOfMemory, and nothing leaks" {
    try testing.checkAllAllocationFailures(test_util.no_grow_allocator, restoreEverything, .{});
}

fn bulkBodyProperty(_: void, bytes: []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var g: test_util.ByteGen = .init(bytes);
    var buffer: [64]u8 = undefined;
    const globs = try arena.alloc([]const u8, g.intRange(usize, 0, 3));
    for (globs) |*glob| glob.* = try arena.dupe(u8, g.utf8(&buffer, 24));
    const times = [_]?[]const u8{ null, "2026-09-29T00:00:00Z", "2026-09-29T00:00:00.123456789-05:30" };
    const options: types.BulkRestoreOptions = .{
        .match_globs = globs,
        .soft_deleted_after = g.pick(?[]const u8, &times),
        .soft_deleted_before = g.pick(?[]const u8, &times),
        .created_after = g.pick(?[]const u8, &times),
        .created_before = g.pick(?[]const u8, &times),
        .allow_overwrite = g.boolean(),
        .copy_source_acl = g.boolean(),
    };
    try checkBulkRestore(null, options);
    const root = (try std.json.parseFromSliceLeaky(std.json.Value, arena, try encodeBulkRestore(arena, options), .{})).object;
    // Every field the options name, and no key they do not.
    var expected: usize = 1;
    try testing.expectEqual(options.allow_overwrite, root.get("allowOverwrite").?.bool);
    if (globs.len > 0) {
        expected += 1;
        const sent = root.get("matchGlobs").?.array.items;
        try testing.expectEqual(globs.len, sent.len);
        for (globs, sent) |want, got| try testing.expectEqualStrings(want, got.string);
    } else try testing.expectEqual(null, root.get("matchGlobs"));
    const fields = [_]struct { []const u8, ?[]const u8 }{
        .{ "softDeletedAfterTime", options.soft_deleted_after },
        .{ "softDeletedBeforeTime", options.soft_deleted_before },
        .{ "createdAfterTime", options.created_after },
        .{ "createdBeforeTime", options.created_before },
    };
    for (fields) |field| {
        if (field[1]) |want| {
            expected += 1;
            try testing.expectEqualStrings(want, root.get(field[0]).?.string);
        } else try testing.expectEqual(null, root.get(field[0]));
    }
    if (options.copy_source_acl) {
        expected += 1;
        try testing.expect(root.get("copySourceAcl").?.bool);
    } else try testing.expectEqual(null, root.get("copySourceAcl"));
    try testing.expectEqual(expected, root.count());
}

test "fuzz bulk restore: the body says what the options said, and no more" {
    try test_util.fuzzBytes({}, bulkBodyProperty, .{ .corpus = &.{ "", test_util.repeat("\x03", 40) } });
}

// Against `FakeMultipart` with soft delete on, which restores as Cloud
// Storage did.

fn clientOnFake(fake: *test_util.FakeMultipart, token: *core.StaticToken, diag: *core.Diagnostics) !Client {
    return .init(testing.allocator, fake.io, .{
        .project_id = "extractctl",
        .token_provider = token.provider(),
        .transport = fake.transport(),
        .diagnostics = diag,
        .retry = .{ .max_attempts = 3, .initial_backoff_ms = 1, .max_backoff_ms = 2 },
    });
}

/// Loses the answer of the next restore once armed: the copy is made, and
/// the client never hears.
const LoseRestore = struct {
    armed: bool = false,

    fn plan(self: *LoseRestore) test_util.FakeMultipart.FaultPlan {
        return .{ .ctx = self, .decide = decide };
    }

    fn decide(ctx: ?*anyopaque, kind: test_util.FakeMultipart.Kind, _: u32) test_util.FakeMultipart.Fault {
        const self: *LoseRestore = @ptrCast(@alignCast(ctx.?));
        if (kind != .restore or !self.armed) return .none;
        self.armed = false;
        return .lose_answer;
    }
};

test "against the fake: a delete soft-deletes, each restore makes a copy, and what it replaces goes soft-deleted" {
    var fake: test_util.FakeMultipart = .init(testing.allocator, testing.io);
    defer fake.deinit();
    fake.soft_delete = true;
    var token: core.StaticToken = .{ .token = "ya29.t" };
    var diag: core.Diagnostics = .{};
    var client = try clientOnFake(&fake, &token, &diag);
    defer client.deinit();
    const obj = client.bucket("b").object("s/a");

    try fake.put("s/a", "a0");
    var live = try obj.get(.{});
    const original = live.value.generation;
    live.deinit();
    try obj.delete(.{});
    try testing.expectError(error.NotFound, obj.get(.{}));
    var gone = try obj.get(.{ .generation = original, .soft_deleted = true });
    gone.deinit();

    var first = try obj.restore(.{ .generation = original, .preconditions = .does_not_exist });
    defer first.deinit();
    try testing.expect(first.value.generation != original);
    var second = try obj.restore(.{ .generation = original });
    defer second.deinit();
    try testing.expect(second.value.generation != first.value.generation);
    // The copy the second restore replaced is soft-deleted now, and the
    // original is still there to restore.
    var replaced = try obj.get(.{ .generation = first.value.generation, .soft_deleted = true });
    replaced.deinit();
    var again = try obj.get(.{ .generation = original, .soft_deleted = true });
    again.deinit();

    // Over a live object, under does_not_exist: refused, and nothing made.
    const restores = fake.counts.restores;
    try testing.expectError(error.FailedPrecondition, obj.restore(.{ .generation = original, .preconditions = .does_not_exist }));
    try testing.expectEqual(restores + 1, fake.counts.restores);
    // The live generation is no soft-deleted one.
    try testing.expectError(error.NotFound, obj.restore(.{ .generation = second.value.generation }));
    var bytes = try obj.downloadAlloc(16, .{});
    defer bytes.deinit();
    try testing.expectEqualStrings("a0", bytes.value.data);

    fake.soft_delete = false;
    try testing.expectError(error.InvalidArgument, obj.restore(.{ .generation = original }));
    try testing.expectEqualStrings("bucket soft delete policy must be set.", diag.message());
}

test "against the fake: a restore whose answer is lost is repeated only under a generation condition" {
    var fake: test_util.FakeMultipart = .init(testing.allocator, testing.io);
    defer fake.deinit();
    fake.soft_delete = true;
    var lose: LoseRestore = .{};
    fake.faults = lose.plan();
    var token: core.StaticToken = .{ .token = "ya29.t" };
    var diag: core.Diagnostics = .{};
    var client = try clientOnFake(&fake, &token, &diag);
    defer client.deinit();
    const obj = client.bucket("b").object("a");
    try fake.put("a", "a0");
    const original = fake.objects.items[0].generation;
    try obj.delete(.{});

    // Under does_not_exist, the repeat meets the copy the first made, and
    // one copy stands.
    lose.armed = true;
    try testing.expectError(error.FailedPrecondition, obj.restore(.{ .generation = original, .preconditions = .does_not_exist }));
    try testing.expectEqual(2, fake.counts.restores);
    try testing.expectEqual(1, fake.objects.items.len);
    try testing.expectEqual(1, fake.soft_deleted.items.len);
    try testing.expect(std.mem.indexOf(u8, diag.message(), "may have restored the object") != null);

    // Without it, never repeated: one attempt, one copy, and the error.
    lose.armed = true;
    if (obj.restore(.{ .generation = original })) |ok| {
        var owned = ok;
        owned.deinit();
        return error.TestExpectedError;
    } else |_| {}
    try testing.expectEqual(3, fake.counts.restores);
    // The copy the lost restore made replaced the first, which went into
    // soft delete: two copies ever, one live.
    try testing.expectEqual(1, fake.objects.items.len);
    try testing.expectEqual(2, fake.soft_deleted.items.len);
}
