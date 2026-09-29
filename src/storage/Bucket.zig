//! A cheap handle on one bucket: create it, read and change its settings,
//! delete it, list its objects, and hand out `Object` handles. Making one
//! sends nothing.

const Bucket = @This();

const std = @import("std");
const core = @import("core");

const Client = @import("Client.zig");
const Object = @import("Object.zig");
const bucket_settings = @import("bucket_settings.zig");
const codec = @import("codec.zig");
const errors = @import("errors.zig");
const names = @import("names.zig");
const post_policy = @import("post_policy.zig");
const restore_impl = @import("restore.zig");
const rpc = @import("rpc.zig");
const signing = @import("signing.zig");
const types = @import("types.zig");
const Error = errors.Error;

/// Borrowed; the handle must not outlive it.
client: *Client,
/// Borrowed; the handle must not outlive it.
name: []const u8,
/// The project this handle's requests bill, and its objects' too, as a
/// requester pays bucket needs of anyone but its owners: a project id or
/// number. Null bills as the credentials do. Borrowed; the handle must
/// not outlive it.
billing_project: ?[]const u8 = null,

/// This handle, billing `project` for every request it and the object
/// handles it hands out make: the `userProject` parameter and the
/// `x-goog-user-project` header, one value in both. A requester pays
/// bucket refuses anyone but its owners without one. Checked before any
/// request; `create` bills nothing, since no bucket exists yet.
pub fn withBillingProject(self: Bucket, project: []const u8) Bucket {
    var copy = self;
    copy.billing_project = project;
    return copy;
}

/// This handle on `copy`, a copy of its client that bills this handle's
/// project for the call now beginning. A handle that names none keeps what
/// its client bills already.
fn billing(self: Bucket, copy: *Client) Error!Bucket {
    rpc.begin(self.client);
    try rpc.checkBillingProject(self.client, self.billing_project);
    copy.* = rpc.billed(self.client, self.billing_project orelse self.client.billing_project);
    var billed_self = self;
    billed_self.client = copy;
    return billed_self;
}

/// Creates the bucket in the client's project, which `Options.project_id`
/// must name, with the settings `config` gives. Every setting Cloud
/// Storage would refuse is refused here first, with
/// `error.InvalidBucketSettings`. Safe to retry: a lost first success
/// shows up as `error.AlreadyExists`.
pub fn create(self: Bucket, config: types.BucketConfig) Error!types.Owned(types.BucketInfo) {
    rpc.begin(self.client);
    try rpc.checkBucketName(self.client, self.name);
    try bucket_settings.checkConfig(self.client.diagnostics, config);
    const project = try rpc.requireProject(self.client);
    var scratch: std.heap.ArenaAllocator = .init(self.client.gpa);
    defer scratch.deinit();
    const path = try names.bucketsPath(scratch.allocator(), project, .{});
    const body = try bucket_settings.encodeConfig(scratch.allocator(), self.name, config);

    var result: types.Owned(types.BucketInfo) = try .init(self.client.gpa);
    errdefer result.deinit();
    const response = try rpc.execute(self.client, result.arena, .{ .method = .POST, .path = path, .body = body });
    result.value = codec.decodeBucket(result.arena.allocator(), response) catch |err|
        return rpc.decodeFailed(self.client, err, "bucket");
    return result;
}

/// The bucket's metadata.
pub fn get(self: Bucket) Error!types.Owned(types.BucketInfo) {
    var client: Client = undefined;
    return (try self.billing(&client)).getBilled();
}

fn getBilled(self: Bucket) Error!types.Owned(types.BucketInfo) {
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

/// Changes the settings `changes` names, and nothing else, and returns the
/// bucket as it now is. Labels merge as `changes.labels` says, lifecycle
/// rules are replaced as a whole, and every other setting is replaced
/// alone. Every value Cloud Storage would refuse, and an update that
/// changes nothing, is refused here first, with
/// `error.InvalidBucketSettings`. A bucket takes about one update a
/// second, and a change can take 30 seconds to apply everywhere.
///
/// Retried only under `changes.if_metageneration_match`, or with
/// `Options.retry_unconditional_writes`: a repeat of an update that
/// landed and lost its answer would undo whatever another writer changed
/// in between. Under the condition, such a repeat fails with
/// `error.FailedPrecondition` instead: `get` the bucket to see which.
pub fn update(self: Bucket, changes: types.BucketUpdate) Error!types.Owned(types.BucketInfo) {
    var client: Client = undefined;
    return (try self.billing(&client)).updateBilled(changes);
}

fn updateBilled(self: Bucket, changes: types.BucketUpdate) Error!types.Owned(types.BucketInfo) {
    rpc.begin(self.client);
    try rpc.checkBucketName(self.client, self.name);
    return bucket_settings.update(self.client, self.name, changes);
}

/// Deletes the bucket, which must be empty. Safe to retry: a lost first
/// success shows up as `error.NotFound`. A bucket that ever had soft
/// delete on is kept, restorable, for the longest retention it had, even
/// one turned off since.
pub fn delete(self: Bucket) Error!void {
    var client: Client = undefined;
    return (try self.billing(&client)).deleteBilled();
}

fn deleteBilled(self: Bucket) Error!void {
    rpc.begin(self.client);
    try rpc.checkBucketName(self.client, self.name);
    var scratch: std.heap.ArenaAllocator = .init(self.client.gpa);
    defer scratch.deinit();
    const path = try names.bucketPath(scratch.allocator(), self.name);
    try rpc.executeDiscard(self.client, .{ .method = .DELETE, .path = path });
}

/// Brings back the soft-deleted bucket of this name and `generation`, as
/// `Client.listSoftDeletedBuckets` gives it: its settings, not its objects,
/// which stay soft-deleted for `Object.restore` or `bulkRestore`. Refused
/// while a live bucket has the name, which anyone may take. Needs
/// `storage.buckets.restore` on the project.
pub fn restore(self: Bucket, generation: u64) Error!types.Owned(types.BucketInfo) {
    var client: Client = undefined;
    return (try self.billing(&client)).restoreBilled(generation);
}

fn restoreBilled(self: Bucket, generation: u64) Error!types.Owned(types.BucketInfo) {
    rpc.begin(self.client);
    try rpc.checkBucketName(self.client, self.name);
    return restore_impl.restoreBucket(self.client, self.name, generation);
}

/// Starts restoring many soft-deleted objects at once, the newest
/// soft-deleted generation of each name that matches, and returns the
/// long-running operation doing it: follow it with `operation`. It can take
/// minutes to begin, reports counts but no percentage, and blocks the
/// bucket's delete until it ends. A bucket runs one at a time: another
/// start meanwhile is `error.ResourceExhausted`. Each start carries a fresh
/// idempotency token, the same on its retries, so a start whose answer was
/// lost is not started twice. Needs `storage.buckets.restore` besides the
/// object permissions. Time bounds that are not RFC 3339 are refused
/// before sending, with `error.InvalidArgument`.
pub fn bulkRestore(self: Bucket, options: types.BulkRestoreOptions) Error!types.Owned(types.Operation) {
    var client: Client = undefined;
    return (try self.billing(&client)).bulkRestoreBilled(options);
}

fn bulkRestoreBilled(self: Bucket, options: types.BulkRestoreOptions) Error!types.Owned(types.Operation) {
    rpc.begin(self.client);
    try rpc.checkBucketName(self.client, self.name);
    return restore_impl.bulkRestore(self.client, self.name, options);
}

/// One of the bucket's long-running operations, by `Operation.id`.
pub fn operation(self: Bucket, id: []const u8) Error!types.Owned(types.Operation) {
    var client: Client = undefined;
    return (try self.billing(&client)).operationBilled(id);
}

fn operationBilled(self: Bucket, id: []const u8) Error!types.Owned(types.Operation) {
    rpc.begin(self.client);
    try rpc.checkBucketName(self.client, self.name);
    return restore_impl.operation(self.client, self.name, id);
}

/// Asks the server to stop an operation, which then ends with
/// `failure.code` 1. What it restored stays restored.
pub fn cancelOperation(self: Bucket, id: []const u8) Error!void {
    var client: Client = undefined;
    return (try self.billing(&client)).cancelOperationBilled(id);
}

fn cancelOperationBilled(self: Bucket, id: []const u8) Error!void {
    rpc.begin(self.client);
    try rpc.checkBucketName(self.client, self.name);
    return restore_impl.cancelOperation(self.client, self.name, id);
}

/// One page of the bucket's operations, finished ones included.
pub fn listOperations(self: Bucket, page: types.PageOptions) Error!types.Owned(types.OperationPage) {
    var client: Client = undefined;
    return (try self.billing(&client)).listOperationsBilled(page);
}

fn listOperationsBilled(self: Bucket, page: types.PageOptions) Error!types.Owned(types.OperationPage) {
    rpc.begin(self.client);
    try rpc.checkBucketName(self.client, self.name);
    return restore_impl.listOperations(self.client, self.name, page);
}

/// A handle for the object `name` in this bucket. Sends nothing. The handle
/// borrows the client and both names, and must not outlive them.
pub fn object(self: Bucket, name: []const u8) Object {
    return .{ .client = self.client, .bucket = self.name, .name = name, .billing_project = self.billing_project };
}

/// A V4 signed URL for the bucket itself, through the XML API: a GET lists
/// its objects as XML, with `prefix` and `delimiter` as signed query
/// parameters. Everything else is as `Object.signedUrl` says.
pub fn signedUrl(self: Bucket, signer: core.Signer, options: types.SignedUrlOptions) Error!types.Owned([]const u8) {
    var client: Client = undefined;
    return (try self.billing(&client)).signedUrlBilled(signer, options);
}

fn signedUrlBilled(self: Bucket, signer: core.Signer, options: types.SignedUrlOptions) Error!types.Owned([]const u8) {
    rpc.begin(self.client);
    try rpc.checkBucketName(self.client, self.name);
    return signing.signUrl(self.client, signer, self.name, null, options);
}

/// A V4 POST policy for this bucket: what a plain HTML form may upload
/// into it, stated in advance and signed. `options.key` says which names
/// the form may store, one exactly or any under a prefix, and is required:
/// `.{ .starts_with = "" }` allows any name in the bucket. Everything else
/// is as `Object.postPolicy` says.
pub fn postPolicy(self: Bucket, signer: core.Signer, options: types.PostPolicyOptions) Error!types.Owned(types.PostPolicy) {
    var client: Client = undefined;
    const this = try self.billing(&client);
    if (this.billing_project != null) {
        if (this.client.diagnostics) |d| d.print("a POST policy cannot bill a project: an HTML form has no way to name one", .{});
        return error.InvalidPostPolicyOptions;
    }
    return this.postPolicyBilled(signer, options);
}

fn postPolicyBilled(self: Bucket, signer: core.Signer, options: types.PostPolicyOptions) Error!types.Owned(types.PostPolicy) {
    rpc.begin(self.client);
    try rpc.checkBucketName(self.client, self.name);
    const key = options.key orelse {
        if (self.client.diagnostics) |d| d.print(
            "a bucket's POST policy needs a key: one name, or a prefix the browser completes; .{{ .starts_with = \"\" }} allows any name in the bucket",
            .{},
        );
        return error.InvalidPostPolicyOptions;
    };
    return post_policy.signPolicy(self.client, signer, self.name, key, options);
}

/// One page of the bucket's objects, filtered and grouped by the options:
/// live objects, every version, or the soft-deleted ones. A page can come
/// back empty with a `next_page_token` still to follow. `versions` and
/// `soft_deleted` together are refused before sending, with
/// `error.InvalidArgument`, as Cloud Storage refuses them.
pub fn listObjects(self: Bucket, options: types.ListOptions) Error!types.Owned(types.ObjectPage) {
    var client: Client = undefined;
    return (try self.billing(&client)).listObjectsBilled(options);
}

fn listObjectsBilled(self: Bucket, options: types.ListOptions) Error!types.Owned(types.ObjectPage) {
    rpc.begin(self.client);
    try rpc.checkBucketName(self.client, self.name);
    if (options.versions and options.soft_deleted) {
        if (self.client.diagnostics) |d| d.print("versions and soft_deleted cannot be listed together: soft-deleted objects are no versions", .{});
        return error.InvalidArgument;
    }
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

/// Captured from Cloud Storage on 2026-09-29, two of the entries: a
/// versioned bucket listed with `versions=true` and a `/` delimiter, where
/// a folder that holds only noncurrent versions still gives a prefix.
const versions_page =
    \\{
    \\  "kind": "storage#objects",
    \\  "prefixes": [
    \\    "dir/",
    \\    "only-gone/"
    \\  ],
    \\  "items": [
    \\    {
    \\      "kind": "storage#object",
    \\      "id": "zigps-p2-26fbba/a/1790696413690506",
    \\      "name": "a",
    \\      "bucket": "zigps-p2-26fbba",
    \\      "generation": "1790696413690506",
    \\      "metageneration": "1",
    \\      "contentType": "application/octet-stream",
    \\      "storageClass": "STANDARD",
    \\      "size": "2",
    \\      "md5Hash": "aTqf3Uwv0HAJaPug0H/zwA==",
    \\      "crc32c": "s4fz5Q==",
    \\      "etag": "CIr1jf2PlJcDEAE=",
    \\      "timeCreated": "2026-09-29T15:40:13.710Z",
    \\      "updated": "2026-09-29T15:40:13.710Z",
    \\      "timeStorageClassUpdated": "2026-09-29T15:40:13.710Z",
    \\      "timeFinalized": "2026-09-29T15:40:13.710Z"
    \\    },
    \\    {
    \\      "kind": "storage#object",
    \\      "id": "zigps-p2-26fbba/b/1790696413932275",
    \\      "name": "b",
    \\      "bucket": "zigps-p2-26fbba",
    \\      "generation": "1790696413932275",
    \\      "metageneration": "1",
    \\      "contentType": "application/octet-stream",
    \\      "storageClass": "STANDARD",
    \\      "size": "2",
    \\      "md5Hash": "+FH1W6GoTjfE4DQ5lU3LCQ==",
    \\      "crc32c": "Zlsriw==",
    \\      "etag": "CPPVnP2PlJcDEAE=",
    \\      "timeCreated": "2026-09-29T15:40:13.938Z",
    \\      "updated": "2026-09-29T15:40:13.938Z",
    \\      "timeDeleted": "2026-09-29T15:40:14.128Z",
    \\      "timeStorageClassUpdated": "2026-09-29T15:40:13.938Z",
    \\      "timeFinalized": "2026-09-29T15:40:13.938Z"
    \\    }
    \\  ]
    \\}
;

/// Captured the same day: a bucket's soft-deleted objects, listed with a
/// `/` delimiter, which groups them into prefixes as it groups live ones.
const soft_deleted_page =
    \\{
    \\  "kind": "storage#objects",
    \\  "prefixes": [
    \\    "s/",
    \\    "t/"
    \\  ],
    \\  "items": [
    \\    {
    \\      "kind": "storage#object",
    \\      "id": "zigps-p3-3f1672/u/1790696465415283",
    \\      "name": "u",
    \\      "bucket": "zigps-p3-3f1672",
    \\      "generation": "1790696465415283",
    \\      "metageneration": "1",
    \\      "contentType": "application/octet-stream",
    \\      "storageClass": "STANDARD",
    \\      "size": "2",
    \\      "md5Hash": "PjNOhZh5ryVtOCfWUbeASg==",
    \\      "crc32c": "I/MTTw==",
    \\      "etag": "CPP44pWQlJcDEAE=",
    \\      "timeCreated": "2026-09-29T15:41:05.422Z",
    \\      "updated": "2026-09-29T15:41:05.422Z",
    \\      "softDeleteTime": "2026-09-29T15:41:06.151Z",
    \\      "hardDeleteTime": "2026-10-06T15:41:06.151Z",
    \\      "timeStorageClassUpdated": "2026-09-29T15:41:05.422Z",
    \\      "timeFinalized": "2026-09-29T15:41:05.422Z"
    \\    }
    \\  ]
    \\}
;

test "golden: listObjects of every version, and of soft-deleted objects" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = versions_page } },
        .{ .respond = .{ .body = soft_deleted_page } },
    }, .{});
    defer h.deinit();
    const b = h.client.bucket("zigps-p2-26fbba");

    var versions = try b.listObjects(.{ .versions = true, .delimiter = "/" });
    defer versions.deinit();
    try h.expectRequest(0, .GET, "https://storage.googleapis.com/storage/v1/b/zigps-p2-26fbba/o?delimiter=%2F&versions=true", null);
    try testing.expectEqual(2, versions.value.objects.len);
    // The live version has no time_deleted; the noncurrent one does.
    try testing.expectEqual(null, versions.value.objects[0].time_deleted);
    try testing.expectEqualStrings("2026-09-29T15:40:14.128Z", versions.value.objects[1].time_deleted.?);
    try testing.expectEqual(1790696413932275, versions.value.objects[1].generation);
    try testing.expectEqualStrings("only-gone/", versions.value.prefixes[1]);

    var soft = try b.listObjects(.{ .soft_deleted = true, .match_glob = "s/**", .delimiter = "/", .page_size = 1 });
    defer soft.deinit();
    try h.expectRequest(1, .GET, "https://storage.googleapis.com/storage/v1/b/zigps-p2-26fbba/o?delimiter=%2F&matchGlob=s%2F%2A%2A&softDeleted=true&maxResults=1", null);
    const u = soft.value.objects[0];
    try testing.expectEqualStrings("2026-09-29T15:41:06.151Z", u.soft_delete_time.?);
    try testing.expectEqualStrings("2026-10-06T15:41:06.151Z", u.hard_delete_time.?);
    try testing.expectEqual(null, u.time_deleted);
    try testing.expectEqual(null, u.restore_token);
    try testing.expectEqual(2, soft.value.prefixes.len);
}

test "listObjects: versions and soft_deleted together are refused before sending" {
    var h: test_util.Harness = undefined;
    try h.init(&.{}, .{});
    defer h.deinit();
    try testing.expectError(error.InvalidArgument, h.client.bucket("b").listObjects(.{ .versions = true, .soft_deleted = true }));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "cannot be listed together") != null);
    try h.expectRequestCount(0);
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
