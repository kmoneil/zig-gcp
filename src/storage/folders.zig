//! Folders in hierarchical-namespace buckets: real resources that exist
//! while empty, carry metagenerations, and are created, read, listed and
//! deleted here, as measured in production on 2026-10-02 (the folders
//! spec, section 2; `_tmp/folders/production-f.md`). The calls behind
//! `Folder.create`, `get` and `delete` and `Bucket.listFolders` and
//! `storageLayout`.
//!
//! The idempotency token dedupes none of these writes, as measured, so a
//! create is never simply sent again: a repeat that landed answers 409
//! exists. After a failure that may have landed, the folder is read
//! instead; one that is there is taken as this create's, since an
//! identical concurrent create is indistinguishable and leaves exactly
//! what was asked for. A delete is retried as sent: a repeat of one that
//! landed answers 404, so a lost first success shows up as
//! `error.NotFound`, as notification deletes do.
//!
//! Cloud Storage answers every folder conflict 409 `conflict`, told apart
//! only by its message: exists, a missing parent, a non-empty delete, and
//! a flat bucket. The last three become `ParentFolderMissing`,
//! `FolderNotEmpty` and `HierarchicalNamespaceRequired` here.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Stringify = std.json.Stringify;
const core = @import("core");

const Client = @import("Client.zig");
const codec = @import("codec.zig");
const logging = @import("logging.zig");
const names = @import("names.zig");
const restore_impl = @import("restore.zig");
const rpc = @import("rpc.zig");
const types = @import("types.zig");
const validate = @import("validate.zig");
const Error = @import("errors.zig").Error;

/// A 409 whose message says more than "it exists": the three refusals
/// measured on 2026-10-02, each mapped to its own error. Anything else is
/// left as it came.
pub fn refinedConflict(err: anyerror, diag: *const core.Diagnostics) ?Error {
    if (err != error.AlreadyExists) return null;
    const message = diag.message();
    if (std.mem.startsWith(u8, message, "The folder you tried to delete is not empty")) return error.FolderNotEmpty;
    if (std.mem.startsWith(u8, message, "The parent folder does not exist")) return error.ParentFolderMissing;
    if (std.mem.startsWith(u8, message, "The bucket does not support hierarchical namespace")) return error.HierarchicalNamespaceRequired;
    return null;
}

/// `path` with its trailing slash, as the server stores every folder: one
/// without is normalized, as the server itself normalizes, then held to
/// the rules. The result lives in `arena`.
fn normalizedChecked(client: *Client, arena: Allocator, path: []const u8) Error![]const u8 {
    const folder = if (path.len > 0 and path[path.len - 1] == '/')
        path
    else
        try std.mem.concat(arena, u8, &.{ path, "/" });
    if (validate.folderPathProblem(folder)) |problem| {
        if (client.diagnostics) |d| d.print("invalid folder path: {s}", .{problem});
        return error.InvalidFolderName;
    }
    return folder;
}

/// The body of a create: the path, and nothing else is settable.
fn encodeName(arena: Allocator, folder: []const u8) Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    var jw: Stringify = .{ .writer = &out.writer };
    jw.beginObject() catch return error.OutOfMemory;
    jw.objectField("name") catch return error.OutOfMemory;
    jw.write(folder) catch return error.OutOfMemory;
    jw.endObject() catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

/// Creates the folder, and with `recursive` its missing parents too. The
/// caller has begun the call and checked the bucket name.
pub fn create(client: *Client, bucket: []const u8, path: []const u8, recursive: bool) Error!types.Owned(types.FolderInfo) {
    var scratch: std.heap.ArenaAllocator = .init(client.gpa);
    defer scratch.deinit();
    const folder = try normalizedChecked(client, scratch.allocator(), path);
    const insert_path = try names.foldersPath(scratch.allocator(), bucket, .{ .insert = recursive });
    const body = try encodeName(scratch.allocator(), folder);

    var attempt: u32 = 0;
    while (true) {
        attempt += 1;
        var result: types.Owned(types.FolderInfo) = try .init(client.gpa);
        const sent = rpc.execute(client, result.arena, .{
            .method = .POST,
            .path = insert_path,
            .body = body,
            // A repeat of a create that landed is 409 exists: this loop
            // decides what a failure means.
            .retry = false,
        });
        if (sent) |response| {
            result.value = codec.decodeFolder(result.arena.allocator(), response) catch |err| {
                result.deinit();
                return rpc.decodeFailed(client, err, "folder");
            };
            return result;
        } else |err| {
            result.deinit();
            if (!core.isRetryable(err)) return err;
            // It may have landed with its answer lost. Give it time to,
            // then read it: a folder that is there is this create's, since
            // an identical concurrent create leaves the same thing.
            const delay_ms = rpc.backoffMs(client, attempt);
            logging.warn("creating folder {s} in {s} failed with {t}; reading it in {d} ms", .{ folder, bucket, err, delay_ms });
            try client.io.sleep(.fromMilliseconds(delay_ms), .awake);
            if (get(client, bucket, folder)) |found| {
                if (client.diagnostics) |d| d.clear();
                return found;
            } else |get_err| switch (get_err) {
                // Nothing landed: send the create again.
                error.NotFound => {},
                // Running out of memory, or being canceled, says nothing
                // about the create: it is the answer.
                error.OutOfMemory, error.Canceled => return get_err,
                else => {
                    if (client.diagnostics) |d| d.print(
                        "creating folder {s} failed with {t}, and reading it to see whether it landed failed with {t}: it may exist",
                        .{ folder, err, get_err },
                    );
                    return err;
                },
            }
            if (attempt >= client.retry.max_attempts) return err;
        }
    }
}

/// One folder. The caller has begun the call and checked the bucket name.
pub fn get(client: *Client, bucket: []const u8, path: []const u8) Error!types.Owned(types.FolderInfo) {
    var scratch: std.heap.ArenaAllocator = .init(client.gpa);
    defer scratch.deinit();
    const folder = try normalizedChecked(client, scratch.allocator(), path);
    const get_path = try names.foldersPath(scratch.allocator(), bucket, .{ .item = .{ .folder = folder } });

    var result: types.Owned(types.FolderInfo) = try .init(client.gpa);
    errdefer result.deinit();
    const response = try rpc.execute(client, result.arena, .{ .method = .GET, .path = get_path });
    result.value = codec.decodeFolder(result.arena.allocator(), response) catch |err|
        return rpc.decodeFailed(client, err, "folder");
    return result;
}

/// Deletes one empty folder. Retried as sent: a lost first success shows
/// up as `error.NotFound`. The caller has begun the call and checked the
/// bucket name.
pub fn delete(client: *Client, bucket: []const u8, path: []const u8, preconditions: types.Preconditions) Error!void {
    var scratch: std.heap.ArenaAllocator = .init(client.gpa);
    defer scratch.deinit();
    const folder = try normalizedChecked(client, scratch.allocator(), path);
    const delete_path = try names.foldersPath(scratch.allocator(), bucket, .{ .item = .{
        .folder = folder,
        .preconditions = preconditions,
    } });
    try rpc.executeDiscard(client, .{ .method = .DELETE, .path = delete_path });
}

/// Starts a rename and answers its operation, which for a small tree is
/// already done in the first response, as measured. Never blindly retried:
/// a repeat of a rename that landed answers 404 for the gone source, which
/// nothing can tell from a source that never existed. The caller has begun
/// the call and checked the bucket name.
pub fn startRename(
    client: *Client,
    bucket: []const u8,
    source: []const u8,
    destination: []const u8,
    if_source_metageneration_match: ?u64,
) Error!types.Owned(types.OperationInfo) {
    var scratch: std.heap.ArenaAllocator = .init(client.gpa);
    defer scratch.deinit();
    const src = try normalizedChecked(client, scratch.allocator(), source);
    const dst = try normalizedChecked(client, scratch.allocator(), destination);
    const path = try names.renameFolderPath(scratch.allocator(), bucket, src, dst, if_source_metageneration_match);

    var result: types.Owned(types.OperationInfo) = try .init(client.gpa);
    errdefer result.deinit();
    const response = rpc.execute(client, result.arena, .{ .method = .POST, .path = path, .retry = false }) catch |err| {
        if (core.isRetryable(err)) {
            if (client.diagnostics) |d| d.print(
                "renaming {s} to {s} failed with {t}, and a rename is never sent twice: Bucket.listOperations says whether it started",
                .{ src, dst, err },
            );
        }
        return err;
    };
    result.value = codec.decodeOperation(result.arena.allocator(), response) catch |err|
        return rpc.decodeFailed(client, err, "rename operation");
    return result;
}

/// `startRename`, waited to its end: polls the operation under the
/// client's backoff until it is done, up to the retry policy's attempts,
/// and returns the destination folder. A rename cannot be canceled, so an
/// exhausted wait leaves it running: `error.DeadlineExceeded`, with the
/// operation's id in the diagnostics for `Bucket.operation` to follow.
pub fn rename(
    client: *Client,
    bucket: []const u8,
    source: []const u8,
    destination: []const u8,
    if_source_metageneration_match: ?u64,
) Error!types.Owned(types.FolderInfo) {
    var op = try startRename(client, bucket, source, destination, if_source_metageneration_match);
    var op_live = true;
    defer if (op_live) op.deinit();
    var attempt: u32 = 0;
    while (true) {
        if (op.value.done) {
            if (op.value.failure) |failure| {
                const err = core.errors.fromRpcCode(failure.code);
                if (client.diagnostics) |d| d.print("the rename failed after starting: {s}", .{failure.message});
                return err;
            }
            if (op.value.folder) |folder| return copyFolder(client.gpa, folder);
            // Done without the folder: read it, as it now is.
            op.deinit();
            op_live = false;
            return get(client, bucket, destination);
        }
        attempt += 1;
        if (attempt > client.retry.max_attempts) {
            if (client.diagnostics) |d| d.print(
                "the rename is still running as operation {s}, which cannot be canceled: Bucket.operation follows it",
                .{op.value.id},
            );
            return error.DeadlineExceeded;
        }
        try client.io.sleep(.fromMilliseconds(rpc.backoffMs(client, attempt)), .awake);
        const next = try restore_impl.operation(client, bucket, op.value.id);
        op.deinit();
        op = next;
    }
}

/// `folder`, in memory of its own.
fn copyFolder(gpa: Allocator, folder: types.FolderInfo) Error!types.Owned(types.FolderInfo) {
    var result: types.Owned(types.FolderInfo) = try .init(gpa);
    errdefer result.deinit();
    const a = result.arena.allocator();
    result.value = .{
        .name = try a.dupe(u8, folder.name),
        .bucket = try a.dupe(u8, folder.bucket),
        .metageneration = folder.metageneration,
        .create_time = try a.dupe(u8, folder.create_time),
        .update_time = try a.dupe(u8, folder.update_time),
    };
    return result;
}

/// One page of the bucket's folders. The caller has begun the call and
/// checked the bucket name.
pub fn list(client: *Client, bucket: []const u8, options: types.FolderListOptions) Error!types.Owned(types.FolderPage) {
    if (options.prefix) |prefix| if (prefix.len > 0 and prefix[prefix.len - 1] != '/') {
        if (client.diagnostics) |d| d.print("a folders prefix is an empty string or ends with '/', as Cloud Storage requires", .{});
        return error.InvalidArgument;
    };
    var scratch: std.heap.ArenaAllocator = .init(client.gpa);
    defer scratch.deinit();
    const path = try names.foldersPath(scratch.allocator(), bucket, .{ .list = options });

    var result: types.Owned(types.FolderPage) = try .init(client.gpa);
    errdefer result.deinit();
    const response = try rpc.execute(client, result.arena, .{ .method = .GET, .path = path });
    result.value = codec.decodeFolderPage(result.arena.allocator(), response) catch |err|
        return rpc.decodeFailed(client, err, "folder list");
    return result;
}

/// How the bucket stores names, which `storage.objects.list` permission is
/// enough to ask. The caller has begun the call and checked the bucket
/// name.
pub fn layout(client: *Client, bucket: []const u8) Error!types.Owned(types.StorageLayout) {
    var scratch: std.heap.ArenaAllocator = .init(client.gpa);
    defer scratch.deinit();
    const path = try names.storageLayoutPath(scratch.allocator(), bucket);

    var result: types.Owned(types.StorageLayout) = try .init(client.gpa);
    errdefer result.deinit();
    const response = try rpc.execute(client, result.arena, .{ .method = .GET, .path = path });
    result.value = codec.decodeStorageLayout(result.arena.allocator(), response) catch |err|
        return rpc.decodeFailed(client, err, "storage layout");
    return result;
}

const testing = std.testing;
const test_util = @import("test_util.zig");
const FakeBuckets = @import("fake_buckets.zig").FakeBuckets;

// Production's answers, measured on 2026-10-02 (`_tmp/folders`, run
// 8d3fe5fa), the bucket names shortened.
const folder_answer =
    \\{"bucket":"zigps-h","createTime":"2026-10-02T19:10:28.854Z","id":"zigps-h/a/b/","kind":"storage#folder","metageneration":"1","name":"a/b/","selfLink":"https://www.googleapis.com/storage/v1/b/zigps-h/folders/a%2Fb%2F","updateTime":"2026-10-02T19:10:28.854Z"}
;
const folder_page =
    \\{"items":[{"bucket":"zigps-h","createTime":"2026-10-02T19:10:28.285Z","id":"zigps-h/a/","kind":"storage#folder","metageneration":"1","name":"a/","selfLink":"https://www.googleapis.com/storage/v1/b/zigps-h/folders/a%2F","updateTime":"2026-10-02T19:10:28.285Z"},{"bucket":"zigps-h","createTime":"2026-10-02T19:10:28.854Z","id":"zigps-h/a/b/","kind":"storage#folder","metageneration":"1","name":"a/b/","selfLink":"https://www.googleapis.com/storage/v1/b/zigps-h/folders/a%2Fb%2F","updateTime":"2026-10-02T19:10:28.854Z"}],"kind":"storage#folders","nextPageToken":"CgRhL2Iv"}
;
/// A list of none: no `items` at all.
const empty_page =
    \\{"kind":"storage#folders"}
;
const layout_hns =
    \\{"bucket":"zigps-h","hierarchicalNamespace":{"enabled":true},"kind":"storage#storageLayout","location":"US-CENTRAL1","locationType":"region"}
;
/// A flat bucket's layout leaves the namespace out entirely.
const layout_flat =
    \\{"bucket":"zigps-f","kind":"storage#storageLayout","location":"US-CENTRAL1","locationType":"region"}
;
/// fake-gcs-server 1.56.1 sends the field for every bucket, enabled false,
/// a bucket created hierarchical included
/// (`_tmp/folders/emulator-layout-1.56.1.json`).
const layout_emulator =
    \\{"kind":"storage#storageLayout","bucket":"zigps-layout-probe","location":"US-CENTRAL1","locationType":"region","hierarchicalNamespace":{"enabled":false}}
;

// The rename operation, verbatim from production (run 2fcd21d0): pending
// at the start of a 300-folder tree, done 925 ms later, and done in the
// very FIRST answer for a small tree (run 8d3fe5fa). The response is the
// control-plane Folder, not storage#folder.
const rename_pending_answer =
    \\{"done":false,"kind":"storage#operation","metadata":{"@type":"type.googleapis.com/google.storage.control.v2.RenameFolderMetadata","commonMetadata":{"createTime":"2026-10-02T19:27:56.736Z","progressPercent":1,"requestedCancellation":false,"type":"rename-folder","updateTime":"2026-10-02T19:27:56.736Z"},"destinationFolderId":"rb/","sourceFolderId":"ra/"},"name":"projects/_/buckets/zigps-h/operations/CiQzMmQ2ZDU2OTQAQ","selfLink":"https://www.googleapis.com/storage/v1/b/zigps-h/operations/CiQzMmQ2ZDU2OTQAQ"}
;
const rename_done_answer =
    \\{"done":true,"kind":"storage#operation","metadata":{"@type":"type.googleapis.com/google.storage.control.v2.RenameFolderMetadata","commonMetadata":{"createTime":"2026-10-02T19:27:56.736Z","endTime":"2026-10-02T19:27:57.326Z","progressPercent":100,"requestedCancellation":false,"type":"rename-folder","updateTime":"2026-10-02T19:27:57.326Z"},"destinationFolderId":"rb/","sourceFolderId":"ra/"},"name":"projects/_/buckets/zigps-h/operations/CiQzMmQ2ZDU2OTQAQ","response":{"@type":"type.googleapis.com/google.storage.control.v2.Folder","createTime":"2026-10-02T19:26:49.637Z","metageneration":"1","name":"projects/_/buckets/zigps-h/folders/rb/","updateTime":"2026-10-02T19:27:57.256Z"},"selfLink":"https://www.googleapis.com/storage/v1/b/zigps-h/operations/CiQzMmQ2ZDU2OTQAQ"}
;

test "decode: the rename operation pending, done, and what the response folder keeps" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const pending = try codec.decodeOperation(arena, rename_pending_answer);
    try testing.expectEqual(.rename_folder, pending.kind);
    try testing.expect(!pending.done);
    try testing.expectEqualStrings("ra/", pending.source_folder.?);
    try testing.expectEqualStrings("rb/", pending.destination_folder.?);
    try testing.expectEqual(1, pending.progress_percent.?);
    try testing.expectEqual(null, pending.folder);
    try testing.expectEqual(null, pending.end_time);
    try testing.expectEqualStrings("CiQzMmQ2ZDU2OTQAQ", pending.id);

    const done = try codec.decodeOperation(arena, rename_done_answer);
    try testing.expect(done.done);
    try testing.expectEqual(100, done.progress_percent.?);
    const folder = done.folder.?;
    // The control-plane shape, read back into this library's: the folder
    // keeps its create time and metageneration from before the rename.
    try testing.expectEqualStrings("rb/", folder.name);
    try testing.expectEqualStrings("zigps-h", folder.bucket);
    try testing.expectEqual(1, folder.metageneration);
    try testing.expectEqualStrings("2026-10-02T19:26:49.637Z", folder.create_time);

    // A kind this library does not know is kept, never an error; a bulk
    // restore keeps its own.
    const unknown = try codec.decodeOperation(arena,
        \\{"done":true,"name":"projects/_/buckets/b/operations/X","metadata":{"@type":"type.googleapis.com/google.storage.control.v2.SomethingNew"}}
    );
    try testing.expectEqual(.unknown, unknown.kind);
    const restore = try codec.decodeOperation(arena,
        \\{"done":false,"name":"projects/_/buckets/b/operations/Y","metadata":{"@type":"type.googleapis.com/google.storage.control.v2.BulkRestoreObjectsMetadata","succeededCount":"3"}}
    );
    try testing.expectEqual(.bulk_restore, restore.kind);
    try testing.expectEqual(3, restore.succeeded);

    // A folder mid-rename names its operation.
    const locked = try codec.decodeFolder(arena,
        \\{"name":"ra/","bucket":"b","metageneration":"1","pendingRenameInfo":{"operationId":"CiQz"}}
    );
    try testing.expectEqualStrings("CiQz", locked.pending_rename_operation_id.?);
}

test "golden: a rename waits its operation out, and a small one is done at once" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = rename_pending_answer } },
        .{ .respond = .{ .body = rename_pending_answer } },
        .{ .respond = .{ .body = rename_done_answer } },
        .{ .respond = .{ .body = rename_done_answer } },
    }, .{ .retry = .{ .max_attempts = 3, .initial_backoff_ms = 1, .max_backoff_ms = 2 } });
    defer h.deinit();
    const b = h.client.bucket("zigps-h");

    var renamed = try b.folder("ra/").renameTo("rb", .{ .if_source_metageneration_match = 1 });
    defer renamed.deinit();
    try testing.expectEqualStrings("rb/", renamed.value.name);
    try testing.expectEqual(1, renamed.value.metageneration);
    try h.expectRequest(0, .POST, "https://storage.googleapis.com/storage/v1/b/zigps-h/folders/ra%2F/renameTo/folders/rb%2F?ifSourceMetagenerationMatch=1", null);
    try h.expectRequest(1, .GET, "https://storage.googleapis.com/storage/v1/b/zigps-h/operations/CiQzMmQ2ZDU2OTQAQ", null);
    try h.expectRequest(2, .GET, "https://storage.googleapis.com/storage/v1/b/zigps-h/operations/CiQzMmQ2ZDU2OTQAQ", null);

    // Done in the first answer: no poll at all.
    var at_once = try b.folder("ra/").renameTo("rb/", .{});
    defer at_once.deinit();
    try h.expectRequest(3, .POST, "https://storage.googleapis.com/storage/v1/b/zigps-h/folders/ra%2F/renameTo/folders/rb%2F", null);
    try h.expectRequestCount(4);
}

test "a rename that fails after starting, and one that outlives the wait" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body =
        \\{"done":true,"kind":"storage#operation","name":"projects/_/buckets/zigps-h/operations/X","metadata":{"@type":"type.googleapis.com/google.storage.control.v2.RenameFolderMetadata"},"error":{"code":9,"message":"The source folder changed underneath the rename."}}
        } },
        .{ .respond = .{ .body = rename_pending_answer } },
        .{ .respond = .{ .body = rename_pending_answer } },
        .{ .respond = .{ .body = rename_pending_answer } },
    }, .{ .retry = .{ .max_attempts = 2, .initial_backoff_ms = 1, .max_backoff_ms = 2 } });
    defer h.deinit();
    const b = h.client.bucket("zigps-h");

    try testing.expectError(error.FailedPrecondition, b.folder("ra/").renameTo("rb/", .{}));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "The source folder changed") != null);

    // Never done within the attempts: the wait ends, the rename does not.
    try testing.expectError(error.DeadlineExceeded, b.folder("ra/").renameTo("rb/", .{}));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "CiQzMmQ2ZDU2OTQAQ") != null);
    try h.expectRequestCount(4);
}

test "a rename start that fails transiently is never sent twice, and says so" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        .{ .fail = error.ConnectionResetByPeer },
    }, .{ .retry = .{ .max_attempts = 3, .initial_backoff_ms = 1, .max_backoff_ms = 2 } });
    defer h.deinit();
    try testing.expectError(error.ConnectionResetByPeer, h.client.bucket("zigps-h").folder("ra/").renameTo("rb/", .{}));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "never sent twice") != null);
    try h.expectRequestCount(1);
}

test "a rename done without its folder reads the destination back" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body =
        \\{"done":true,"kind":"storage#operation","name":"projects/_/buckets/zigps-h/operations/X","metadata":{"@type":"type.googleapis.com/google.storage.control.v2.RenameFolderMetadata","sourceFolderId":"a/b/","destinationFolderId":"rb/"}}
        } },
        .{ .respond = .{ .body = folder_answer } },
    }, .{});
    defer h.deinit();
    var renamed = try h.client.bucket("zigps-h").folder("a/b/").renameTo("rb/", .{});
    defer renamed.deinit();
    try testing.expectEqualStrings("a/b/", renamed.value.name);
    try h.expectRequest(1, .GET, "https://storage.googleapis.com/storage/v1/b/zigps-h/folders/rb%2F", null);
    try h.expectRequestCount(2);
}

test "golden: the rename refusals production answered" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .status = 404, .body = missing_body } },
        .{ .respond = .{ .status = 409, .body = exists_body } },
        .{ .respond = .{ .status = 412, .body =
        \\{"error":{"code":412,"errors":[{"domain":"global","location":"If-Match","locationType":"header","message":"At least one of the pre-conditions you specified did not hold.","reason":"conditionNotMet"}],"message":"At least one of the pre-conditions you specified did not hold."}}
        } },
    }, .{ .retry = .{ .max_attempts = 1 } });
    defer h.deinit();
    const b = h.client.bucket("zigps-h");
    try testing.expectError(error.NotFound, b.folder("missing/").renameTo("elsewhere/", .{}));
    try testing.expectError(error.AlreadyExists, b.folder("ra/").renameTo("exists/", .{}));
    try testing.expectError(error.FailedPrecondition, b.folder("ra/").renameTo("rb/", .{ .if_source_metageneration_match = 999 }));
    try testing.expectError(error.InvalidFolderName, b.folder("ra/").renameTo("../", .{}));
}

test "against production's rules: a rename moves the tree, blocks writes while it runs, and its operation is followed" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    f.fake.rename_pending = 2;
    const b = f.client.bucket("zigps-h");
    var made = try b.folder("ra/c0/").create(.{ .recursive = true });
    made.deinit();
    var up = try b.object("ra/c0/one.txt").upload("x", .{});
    defer up.deinit();

    // The waiting rename polls it to done; the tree and its object moved,
    // and the folder kept its state.
    var renamed = try b.folder("ra/").renameTo("rb/", .{ .if_source_metageneration_match = 1 });
    defer renamed.deinit();
    try testing.expectEqualStrings("rb/", renamed.value.name);
    try testing.expectError(error.NotFound, b.folder("ra/").get());
    var child = try b.folder("rb/c0/").get();
    defer child.deinit();
    var moved = try b.object("rb/c0/one.txt").get(.{});
    defer moved.deinit();

    // A write under a renaming tree answers 429 until the rename ends,
    // and this library's own retries wait it out.
    f.fake.rename_pending = 2;
    var started = try b.folder("rb/").startRenameTo("rc/", .{});
    defer started.deinit();
    try testing.expect(!started.value.done);
    var blocked = try b.object("rb/c0/two.txt").upload("y", .{});
    defer blocked.deinit();
    try testing.expectEqual(1, f.fake.counts.folder_renames - 1);

    // The operation reads done now, listed with the first one; a cancel is
    // taken and changes nothing.
    var op = try b.operation(started.value.id);
    defer op.deinit();
    try testing.expect(op.value.done);
    try testing.expectEqual(.rename_folder, op.value.kind);
    try testing.expectEqualStrings("rc/", op.value.folder.?.name);
    var page = try b.listOperations(.{});
    defer page.deinit();
    try testing.expectEqual(2, page.value.operations.len);
    try b.cancelOperation(started.value.id);
    try testing.expectError(error.NotFound, b.operation("CiRtaXNzaW5n"));

    // The sync refusals: a taken destination, a missing source, a stale
    // source metageneration.
    var taken = try b.folder("blocker/").create(.{});
    taken.deinit();
    try testing.expectError(error.AlreadyExists, b.folder("rc/").renameTo("blocker/", .{}));
    try testing.expectError(error.NotFound, b.folder("gone/").renameTo("anywhere/", .{}));
    try testing.expectError(error.FailedPrecondition, b.folder("rc/").renameTo("rd/", .{ .if_source_metageneration_match = 999 }));
}

fn conflict(comptime message: []const u8) []const u8 {
    return "{\"error\":{\"code\":409,\"errors\":[{\"domain\":\"global\",\"message\":\"" ++ message ++
        "\",\"reason\":\"conflict\"}],\"message\":\"" ++ message ++ "\"}}";
}

const exists_body = conflict("The folder you tried to create already exists.");
const parent_body = conflict("The parent folder does not exist.");
const not_empty_body = conflict("The folder you tried to delete is not empty.");
const flat_body = conflict("The bucket does not support hierarchical namespace.");
const missing_body =
    \\{"error":{"code":404,"errors":[{"domain":"global","message":"The folder does not exist.","reason":"notFound"}],"message":"The folder does not exist."}}
;

test "decode: production's folders, pages and layouts, and the emulator's" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const one = try codec.decodeFolder(arena, folder_answer);
    try testing.expectEqualStrings("a/b/", one.name);
    try testing.expectEqualStrings("zigps-h", one.bucket);
    try testing.expectEqual(1, one.metageneration);
    try testing.expectEqualStrings("2026-10-02T19:10:28.854Z", one.create_time);
    try testing.expectEqualStrings("2026-10-02T19:10:28.854Z", one.update_time);

    const page = try codec.decodeFolderPage(arena, folder_page);
    try testing.expectEqual(2, page.folders.len);
    try testing.expectEqualStrings("a/", page.folders[0].name);
    try testing.expectEqualStrings("CgRhL2Iv", page.next_page_token.?);
    const none = try codec.decodeFolderPage(arena, empty_page);
    try testing.expectEqual(0, none.folders.len);
    try testing.expectEqual(null, none.next_page_token);

    const hns = try codec.decodeStorageLayout(arena, layout_hns);
    try testing.expect(hns.hierarchical_namespace);
    try testing.expectEqualStrings("US-CENTRAL1", hns.location);
    try testing.expectEqualStrings("region", hns.location_type);
    const flat = try codec.decodeStorageLayout(arena, layout_flat);
    try testing.expect(!flat.hierarchical_namespace);
    const emulator = try codec.decodeStorageLayout(arena, layout_emulator);
    try testing.expect(!emulator.hierarchical_namespace);

    // A folder that names no path cannot be addressed.
    try testing.expectError(error.InvalidResponse, codec.decodeFolder(arena, "{\"bucket\":\"b\"}"));
    try testing.expectError(error.InvalidResponse, codec.decodeFolder(arena, "[]"));
}

test "golden: create, get, list and delete, with the paths and bodies as sent" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = folder_answer } },
        .{ .respond = .{ .body = folder_answer } },
        .{ .respond = .{ .body = folder_page } },
        .{ .respond = .{ .status = 204, .body = "" } },
        .{ .respond = .{ .body = layout_hns } },
    }, .{});
    defer h.deinit();
    const b = h.client.bucket("zigps-h");

    var made = try b.folder("a/b/").create(.{ .recursive = true });
    defer made.deinit();
    try testing.expectEqualStrings("a/b/", made.value.name);
    try h.expectRequest(0, .POST, "https://storage.googleapis.com/storage/v1/b/zigps-h/folders?recursive=true", "{\"name\":\"a/b/\"}");

    // A missing trailing slash is appended, as the server itself appends it.
    var got = try b.folder("a/b").get();
    defer got.deinit();
    try h.expectRequest(1, .GET, "https://storage.googleapis.com/storage/v1/b/zigps-h/folders/a%2Fb%2F", null);

    var page = try b.listFolders(.{ .prefix = "a/", .directory_mode = true, .page_size = 2 });
    defer page.deinit();
    try testing.expectEqual(2, page.value.folders.len);
    try h.expectRequest(2, .GET, "https://storage.googleapis.com/storage/v1/b/zigps-h/folders?prefix=a%2F&delimiter=%2F&pageSize=2", null);

    try b.folder("a/b/").delete(.{ .if_metageneration_match = 1 });
    try h.expectRequest(3, .DELETE, "https://storage.googleapis.com/storage/v1/b/zigps-h/folders/a%2Fb%2F?ifMetagenerationMatch=1", null);

    var l = try b.storageLayout();
    defer l.deinit();
    try testing.expect(l.value.hierarchical_namespace);
    try h.expectRequest(4, .GET, "https://storage.googleapis.com/storage/v1/b/zigps-h/storageLayout", null);
    try h.expectRequestCount(5);
}

test "every 409 is told apart by its message, as production answers them" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .status = 409, .body = exists_body } },
        .{ .respond = .{ .status = 409, .body = parent_body } },
        .{ .respond = .{ .status = 409, .body = flat_body } },
        .{ .respond = .{ .status = 409, .body = not_empty_body } },
        .{ .respond = .{ .status = 404, .body = missing_body } },
        .{ .respond = .{ .status = 412, .body =
        \\{"error":{"code":412,"errors":[{"domain":"global","location":"If-Match","locationType":"header","message":"At least one of the pre-conditions you specified did not hold.","reason":"conditionNotMet"}],"message":"At least one of the pre-conditions you specified did not hold."}}
        } },
    }, .{ .retry = .{ .max_attempts = 1 } });
    defer h.deinit();
    const b = h.client.bucket("zigps-h");

    try testing.expectError(error.AlreadyExists, b.folder("a/").create(.{}));
    try testing.expectError(error.ParentFolderMissing, b.folder("a/b/c/").create(.{}));
    try testing.expectEqualStrings("The parent folder does not exist.", h.diag.message());
    try testing.expectError(error.HierarchicalNamespaceRequired, b.folder("a/").create(.{}));
    try testing.expectError(error.FolderNotEmpty, b.folder("a/").delete(.{}));
    try testing.expectEqualStrings("The folder you tried to delete is not empty.", h.diag.message());
    try testing.expectError(error.NotFound, b.folder("a/b/c/").delete(.{}));
    try testing.expectError(error.FailedPrecondition, b.folder("a/").delete(.{ .if_metageneration_match = 999999 }));
}

test "refused before sending: the paths production takes that nothing can address safely" {
    var h: test_util.Harness = undefined;
    try h.init(&.{}, .{});
    defer h.deinit();
    const b = h.client.bucket("zigps-h");
    try testing.expectError(error.InvalidFolderName, b.folder("").create(.{}));
    try testing.expectError(error.InvalidFolderName, b.folder("/").get());
    try testing.expectError(error.InvalidFolderName, b.folder("../").delete(.{}));
    try testing.expectError(error.InvalidFolderName, b.folder("a/./b/").create(.{}));
    try testing.expectError(error.InvalidFolderName, b.folder("a//b/").get());
    try testing.expectError(error.InvalidFolderName, b.folder("s" ** 512 ++ "/").create(.{}));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "512 bytes") != null);
    try testing.expectError(error.InvalidArgument, b.listFolders(.{ .prefix = "a" }));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "ends with '/'") != null);
    try testing.expectError(error.InvalidBucketName, h.client.bucket("a b").listFolders(.{}));
    try testing.expectError(error.InvalidBucketName, h.client.bucket("").storageLayout());
    try h.expectRequestCount(0);
}

test "an HNS bucket config is held to what production refuses, before sending" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = "{\"name\":\"zigps-h\",\"location\":\"US\",\"storageClass\":\"STANDARD\",\"hierarchicalNamespace\":{\"enabled\":true}}" } },
    }, .{});
    defer h.deinit();
    const b = h.client.bucket("zigps-h");
    try testing.expectError(error.InvalidBucketSettings, b.create(.{ .hierarchical_namespace = true, .versioning = true }));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "Versioning is not supported") != null);
    try testing.expectError(error.InvalidBucketSettings, b.create(.{ .hierarchical_namespace = true, .retention_period_s = 60 }));
    try testing.expectError(error.InvalidBucketSettings, b.create(.{ .hierarchical_namespace = true, .object_retention = true }));
    try testing.expectError(error.InvalidBucketSettings, b.create(.{ .hierarchical_namespace = true, .uniform_bucket_level_access = false }));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "uniform bucket-level access") != null);
    try h.expectRequestCount(0);

    // Taken: the namespace rides with uniform access sent along, and the
    // bucket reads back hierarchical.
    var made = try b.create(.{ .hierarchical_namespace = true });
    defer made.deinit();
    try testing.expect(made.value.hierarchical_namespace);
    try h.expectRequest(0, .POST, "https://storage.googleapis.com/storage/v1/b?project=extractctl",
        \\{"name":"zigps-h","location":"US","storageClass":"STANDARD","iamConfiguration":{"uniformBucketLevelAccess":{"enabled":true}},"hierarchicalNamespace":{"enabled":true}}
    );
}

test "folders as prefixes ride the object listing, only beside the / delimiter" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = "{\"kind\":\"storage#objects\",\"prefixes\":[\"empty-folder/\",\"x/\"]}" } },
    }, .{});
    defer h.deinit();
    const b = h.client.bucket("zigps-h");
    try testing.expectError(error.InvalidArgument, b.listObjects(.{ .include_folders_as_prefixes = true }));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "delimiter") != null);
    try h.expectRequestCount(0);
    var page = try b.listObjects(.{ .delimiter = "/", .include_folders_as_prefixes = true });
    defer page.deinit();
    try testing.expectEqual(2, page.value.prefixes.len);
    try h.expectRequest(0, .GET, "https://storage.googleapis.com/storage/v1/b/zigps-h/o?delimiter=%2F&includeFoldersAsPrefixes=true", null);
}

test "a create whose answer was lost is read back, not sent again" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        .{ .fail = error.ConnectionResetByPeer },
        .{ .respond = .{ .body = folder_answer } },
    }, .{ .retry = .{ .max_attempts = 3, .initial_backoff_ms = 1, .max_backoff_ms = 2 } });
    defer h.deinit();
    var made = try h.client.bucket("zigps-h").folder("a/b/").create(.{});
    defer made.deinit();
    try testing.expectEqualStrings("a/b/", made.value.name);
    try h.expectRequest(0, .POST, "https://storage.googleapis.com/storage/v1/b/zigps-h/folders", "{\"name\":\"a/b/\"}");
    try h.expectRequest(1, .GET, "https://storage.googleapis.com/storage/v1/b/zigps-h/folders/a%2Fb%2F", null);
    try h.expectRequestCount(2);
    try testing.expectEqual(0, h.diag.message().len);
}

test "a create that did not land is sent again, up to the retry policy's attempts" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        .{ .fail = error.ConnectionResetByPeer },
        .{ .respond = .{ .status = 404, .body = missing_body } },
        .{ .fail = error.ConnectionResetByPeer },
        .{ .respond = .{ .status = 404, .body = missing_body } },
    }, .{ .retry = .{ .max_attempts = 2, .initial_backoff_ms = 1, .max_backoff_ms = 2 } });
    defer h.deinit();
    try testing.expectError(
        error.ConnectionResetByPeer,
        h.client.bucket("zigps-h").folder("a/b/").create(.{}),
    );
    try h.expectRequestCount(4);
}

test "a create whose answer was lost, and whose read fails, says it may exist" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        .{ .fail = error.ConnectionResetByPeer },
        .{ .respond = .{ .status = 403, .body =
        \\{"error":{"code":403,"message":"caller does not have storage.folders.get access","errors":[{"reason":"forbidden"}]}}
        } },
    }, .{ .retry = .{ .max_attempts = 3, .initial_backoff_ms = 1, .max_backoff_ms = 2 } });
    defer h.deinit();
    try testing.expectError(
        error.ConnectionResetByPeer,
        h.client.bucket("zigps-h").folder("a/b/").create(.{}),
    );
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "it may exist") != null);
}

fn clientOnFake(fake: *test_util.FakeMultipart, token: *core.StaticToken, diag: *core.Diagnostics) !Client {
    return .init(testing.allocator, fake.io, .{
        .project_id = "extractctl",
        .token_provider = token.provider(),
        .transport = fake.transport(),
        .diagnostics = diag,
        .retry = .{ .max_attempts = 3, .initial_backoff_ms = 1, .max_backoff_ms = 2 },
    });
}

const Fixture = struct {
    fake: test_util.FakeMultipart,
    token: core.StaticToken,
    diag: core.Diagnostics,
    client: Client,

    fn init(f: *Fixture) !void {
        f.fake = .init(testing.allocator, testing.io);
        errdefer f.fake.deinit();
        f.token = .{ .token = "ya29.t" };
        f.diag = .{};
        f.client = try clientOnFake(&f.fake, &f.token, &f.diag);
        errdefer f.client.deinit();
        var hns = try f.client.bucket("zigps-h").create(.{ .hierarchical_namespace = true });
        defer hns.deinit();
        try testing.expect(hns.value.hierarchical_namespace);
        var flat = try f.client.bucket("zigps-f").create(.{});
        defer flat.deinit();
        try testing.expect(!flat.value.hierarchical_namespace);
    }

    fn deinit(f: *Fixture) void {
        f.client.deinit();
        f.fake.deinit();
    }
};

test "against production's rules: creates, their conflicts, and a flat bucket" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const b = f.client.bucket("zigps-h");

    var made = try b.folder("a").create(.{});
    defer made.deinit();
    try testing.expectEqualStrings("a/", made.value.name);
    try testing.expectEqual(1, made.value.metageneration);
    try testing.expectError(error.AlreadyExists, b.folder("a/").create(.{}));
    try testing.expectError(error.ParentFolderMissing, b.folder("a/b/c/").create(.{}));
    var deep = try b.folder("a/b/c/").create(.{ .recursive = true });
    defer deep.deinit();
    // A recursive create of folders that all exist is still a conflict.
    try testing.expectError(error.AlreadyExists, b.folder("a/b/c/").create(.{ .recursive = true }));
    var parent = try b.folder("a/b/").get();
    defer parent.deinit();

    // An object of the exact name blocks a folder, as measured.
    var o = try b.object("obj1/").upload("x", .{});
    defer o.deinit();
    try testing.expectError(error.AlreadyExists, b.folder("obj1/").create(.{}));

    try testing.expectError(error.HierarchicalNamespaceRequired, f.client.bucket("zigps-f").folder("a/").create(.{}));
    try testing.expectError(error.HierarchicalNamespaceRequired, f.client.bucket("zigps-f").listFolders(.{}));
    try testing.expectEqualStrings("The bucket does not support hierarchical namespace.", f.diag.message());
    try testing.expectError(error.NotFound, f.client.bucket("zigps-gone").folder("a/").get());
}

test "against production's rules: implicit folders from an upload outlive its object" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const b = f.client.bucket("zigps-h");

    var up = try b.object("ia/ib/ic.txt").upload("payload", .{});
    defer up.deinit();
    var ia = try b.folder("ia/").get();
    defer ia.deinit();
    var ib = try b.folder("ia/ib/").get();
    defer ib.deinit();
    try testing.expectEqual(1, ib.value.metageneration);
    try b.object("ia/ib/ic.txt").delete(.{ .generation = up.value.generation });
    var still = try b.folder("ia/ib/").get();
    defer still.deinit();

    // Now empty of objects, the leaf deletes; its parent has a child until
    // then.
    try testing.expectError(error.FolderNotEmpty, b.folder("ia/").delete(.{}));
    try b.folder("ia/ib/").delete(.{});
    try b.folder("ia/").delete(.{});
}

test "against production's rules: listing pages, directory mode and offsets" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const b = f.client.bucket("zigps-h");
    var made = try b.folder("n1/n2/n3/").create(.{ .recursive = true });
    made.deinit();
    made = try b.folder("m1/").create(.{});
    made.deinit();

    // Pages of one, walked by token, sorted.
    var walked: std.ArrayList([]u8) = .empty;
    defer {
        for (walked.items) |w| testing.allocator.free(w);
        walked.deinit(testing.allocator);
    }
    var token: ?[]const u8 = null;
    var token_buf: [64]u8 = undefined;
    while (true) {
        var page = try b.listFolders(.{ .page_size = 1, .page_token = token });
        defer page.deinit();
        try testing.expect(page.value.folders.len <= 1);
        if (page.value.folders.len == 1) try walked.append(testing.allocator, try testing.allocator.dupe(u8, page.value.folders[0].name));
        const next = page.value.next_page_token orelse break;
        @memcpy(token_buf[0..next.len], next);
        token = token_buf[0..next.len];
    }
    try testing.expectEqual(4, walked.items.len);
    try testing.expectEqualStrings("m1/", walked.items[0]);
    try testing.expectEqualStrings("n1/", walked.items[1]);
    try testing.expectEqualStrings("n1/n2/", walked.items[2]);
    try testing.expectEqualStrings("n1/n2/n3/", walked.items[3]);

    // Directory mode: the prefix folder itself and one level below.
    var dir = try b.listFolders(.{ .prefix = "n1/", .directory_mode = true });
    defer dir.deinit();
    try testing.expectEqual(2, dir.value.folders.len);
    try testing.expectEqualStrings("n1/", dir.value.folders[0].name);
    try testing.expectEqualStrings("n1/n2/", dir.value.folders[1].name);

    var bounded = try b.listFolders(.{ .start_offset = "n", .end_offset = "n1/n2/" });
    defer bounded.deinit();
    try testing.expectEqual(1, bounded.value.folders.len);
    try testing.expectEqualStrings("n1/", bounded.value.folders[0].name);

    var none = try b.listFolders(.{ .start_offset = "z", .end_offset = "a" });
    defer none.deinit();
    try testing.expectEqual(0, none.value.folders.len);
    try testing.expectEqual(null, none.value.next_page_token);
}

test "against production's rules: deletes, preconditions and repeats" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const b = f.client.bucket("zigps-h");
    var made = try b.folder("d1/d2/").create(.{ .recursive = true });
    made.deinit();

    try testing.expectError(error.FolderNotEmpty, b.folder("d1/").delete(.{}));
    try testing.expectError(error.FailedPrecondition, b.folder("d1/d2/").delete(.{ .if_metageneration_match = 999 }));
    try b.folder("d1/d2/").delete(.{ .if_metageneration_match = 1 });
    try testing.expectError(error.NotFound, b.folder("d1/d2/").delete(.{}));
    try b.folder("d1/").delete(.{});
    // Two landed, and three answered a refusal: not empty, stale, repeat.
    try testing.expectEqual(5, f.fake.counts.folder_deletes);
}

test "the layout of a hierarchical bucket, a flat one, and a missing one" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var hns = try f.client.bucket("zigps-h").storageLayout();
    defer hns.deinit();
    try testing.expect(hns.value.hierarchical_namespace);
    try testing.expectEqualStrings("US", hns.value.location);
    var flat = try f.client.bucket("zigps-f").storageLayout();
    defer flat.deinit();
    try testing.expect(!flat.value.hierarchical_namespace);
    try testing.expectError(error.NotFound, f.client.bucket("zigps-gone").storageLayout());
}

test "the fake refuses an HNS create as production does, and drops the field a patch names" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fake: FakeBuckets = .init(testing.allocator);
    defer fake.deinit();
    const collection: FakeBuckets.Target = .{ .name = null, .project = "extractctl" };

    // The four create refusals, each in production's words.
    var reply = try fake.serve(.POST, collection, "{\"name\":\"h1\",\"hierarchicalNamespace\":{\"enabled\":true}}", arena);
    try testing.expectEqual(400, reply.status);
    try testing.expect(std.mem.indexOf(u8, reply.body, "must use uniform bucket-level access") != null);
    reply = try fake.serve(.POST, collection,
        \\{"name":"h1","hierarchicalNamespace":{"enabled":true},"iamConfiguration":{"uniformBucketLevelAccess":{"enabled":true}},"versioning":{"enabled":true}}
    , arena);
    try testing.expect(std.mem.indexOf(u8, reply.body, "Versioning is not supported") != null);
    reply = try fake.serve(.POST, collection,
        \\{"name":"h1","hierarchicalNamespace":{"enabled":true},"iamConfiguration":{"uniformBucketLevelAccess":{"enabled":true}},"retentionPolicy":{"retentionPeriod":"60"}}
    , arena);
    try testing.expect(std.mem.indexOf(u8, reply.body, "Retention policy is not supported") != null);
    var retention_target = collection;
    retention_target.object_retention = true;
    reply = try fake.serve(.POST, retention_target,
        \\{"name":"h1","hierarchicalNamespace":{"enabled":true},"iamConfiguration":{"uniformBucketLevelAccess":{"enabled":true}}}
    , arena);
    try testing.expect(std.mem.indexOf(u8, reply.body, "Object retention config is not supported") != null);

    // Taken with uniform access; a patch naming the field answers 200,
    // drops it, and still moves the metageneration, as measured.
    reply = try fake.serve(.POST, collection,
        \\{"name":"f1","iamConfiguration":{"uniformBucketLevelAccess":{"enabled":true}}}
    , arena);
    try testing.expectEqual(200, reply.status);
    reply = try fake.serve(.PATCH, .{ .name = "f1" }, "{\"hierarchicalNamespace\":{\"enabled\":true}}", arena);
    try testing.expectEqual(200, reply.status);
    try testing.expect(std.mem.indexOf(u8, reply.body, "hierarchicalNamespace") == null);
    try testing.expect(std.mem.indexOf(u8, reply.body, "\"metageneration\":\"2\"") != null);
    try testing.expect(!fake.isHns("f1"));
}

/// A folder path drawn from `bytes`, near the bounds: valid segments, dot
/// and empty ones, oversized ones, bad bytes, and depths around 50.
fn drawPath(g: *test_util.ByteGen, arena: Allocator) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    const depth = g.intRange(usize, 1, 52);
    for (0..depth) |_| {
        const segment = g.pick([]const u8, &.{ "a", "b0", "caf\xc3\xa9", "...", ".", "..", "", "s" ** 300, "x\ry", "\xff" });
        w.writeAll(segment) catch return error.OutOfMemory;
        w.writeByte('/') catch return error.OutOfMemory;
    }
    // Sometimes without the trailing slash, which normalization appends.
    const text = out.written();
    return if (g.boolean()) text else text[0 .. text.len - 1];
}

fn pathsProperty(_: void, bytes: []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var g: test_util.ByteGen = .init(bytes);
    const path = try drawPath(&g, arena);

    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const b = f.client.bucket("zigps-h");
    if (b.folder(path).create(.{ .recursive = true })) |created| {
        // Taken: the fake's rules took the same path, and it reads back
        // normalized, listed under itself, and deletes.
        var made = created;
        defer made.deinit();
        try testing.expect(made.value.name.len >= path.len);
        var read = try b.folder(path).get();
        defer read.deinit();
        try testing.expectEqualStrings(made.value.name, read.value.name);
        var page = try b.listFolders(.{ .prefix = made.value.name });
        defer page.deinit();
        try testing.expectEqualStrings(made.value.name, page.value.folders[0].name);
        // A rename to a fresh top-level name moves it, whatever it was.
        var renamed = try b.folder(path).renameTo("renamed-leg", .{});
        defer renamed.deinit();
        try testing.expectEqualStrings("renamed-leg/", renamed.value.name);
        try testing.expectError(error.NotFound, b.folder(made.value.name).get());
        try b.folder("renamed-leg/").delete(.{});
        try testing.expectError(error.NotFound, b.folder("renamed-leg/").get());
    } else |err| {
        // Refused: only for the reason the checks give, before sending.
        try testing.expectEqual(error.InvalidFolderName, err);
        const normalized = if (path.len > 0 and path[path.len - 1] == '/') path else try std.mem.concat(arena, u8, &.{ path, "/" });
        try testing.expect(validate.folderPathProblem(normalized) != null);
        try testing.expectEqual(0, f.fake.counts.folder_creates);
    }
}

// A heavy property: each run builds a client, a fake and two buckets,
// about 2.2 ms on a Mac, so it runs in the nightly heavy-storage job, not
// the storage one.
test "heavy property folder paths: whatever the checks accept round-trips through production's rules" {
    try test_util.fuzzBytes({}, pathsProperty, .{ .corpus = &.{ "", "\x00" ** 32, "\x07\x01\x02\x03" ** 16, "\xff" ** 64 } });
}

fn everyCall(gpa: Allocator) !void {
    var fake: test_util.FakeTransport = .init(gpa, &.{
        .{ .respond = .{ .body = folder_answer } },
        .{ .fail = error.ConnectionResetByPeer },
        .{ .respond = .{ .body = folder_answer } },
        .{ .respond = .{ .body = folder_page } },
        .{ .respond = .{ .status = 204, .body = "" } },
        .{ .respond = .{ .body = layout_hns } },
        .{ .respond = .{ .body = rename_pending_answer } },
        .{ .respond = .{ .body = rename_done_answer } },
    });
    defer fake.deinit();
    var clock: test_util.FakeClock = .{};
    var token: test_util.FakeTokenProvider = .{ .token = "ya29.test-token" };
    var client: Client = try .init(gpa, clock.io(), .{
        .project_id = "extractctl",
        .token_provider = token.provider(),
        .transport = fake.transport(),
        .retry = .{ .max_attempts = 2, .initial_backoff_ms = 1, .max_backoff_ms = 1 },
    });
    defer client.deinit();
    const b = client.bucket("zigps-h");
    var made = try b.folder("a/b").create(.{ .recursive = true });
    made.deinit();
    // A lost answer, found by the read after it.
    var found = try b.folder("a/b/").create(.{});
    found.deinit();
    var page = try b.listFolders(.{ .prefix = "a/" });
    page.deinit();
    try b.folder("a/b/").delete(.{});
    var l = try b.storageLayout();
    l.deinit();
    var renamed = try b.folder("ra/").renameTo("rb/", .{ .if_source_metageneration_match = 1 });
    renamed.deinit();
}

test "folders: every allocation failure is OutOfMemory, and nothing leaks" {
    try testing.checkAllAllocationFailures(testing.allocator, everyCall, .{});
}
