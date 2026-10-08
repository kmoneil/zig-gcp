//! Managed folders: prefixes that carry IAM policies of their own, on any
//! bucket with uniform bucket-level access, as measured in production on
//! 2026-10-02 (the folders spec; `_tmp/folders/production-f.md`). The
//! calls behind `ManagedFolder.create`, `get` and `delete` and
//! `Bucket.listManagedFolders`; the IAM calls live in iam.zig, on the same
//! `Resource` buckets use.
//!
//! The idempotency token dedupes none of these writes, as measured, so a
//! create whose answer was lost is read back rather than sent again, as
//! folder creates are; a delete is retried as sent, and a lost first
//! success shows up as `error.NotFound`. A bucket without uniform access
//! refuses every managed folder with the same 412 `conditionNotMet` a
//! stale precondition gets, told apart only by its message, which
//! `Diagnostics` keeps; it stays `error.FailedPrecondition`. In a
//! hierarchical bucket, creating a managed folder creates its folders too,
//! and deleting it leaves them standing, as measured.

const std = @import("std");
const Stringify = std.json.Stringify;
const core = @import("core");

const Client = @import("Client.zig");
const codec = @import("codec.zig");
const logging = @import("logging.zig");
const names = @import("names.zig");
const rpc = @import("rpc.zig");
const types = @import("types.zig");
const validate = @import("validate.zig");
const Error = @import("errors.zig").Error;

/// `path` with its trailing slash, normalized as the server normalizes,
/// then held to the measured rules. The result lives in `arena`.
pub fn normalizedChecked(client: *Client, arena: std.mem.Allocator, path: []const u8) Error![]const u8 {
    const folder = if (path.len > 0 and path[path.len - 1] == '/')
        path
    else
        try std.mem.concat(arena, u8, &.{ path, "/" });
    if (validate.managedFolderPathProblem(folder)) |problem| {
        if (client.diagnostics) |d| d.print("invalid managed folder path: {s}", .{problem});
        return error.InvalidFolderName;
    }
    return folder;
}

/// Creates the managed folder. The caller has begun the call and checked
/// the bucket name.
pub fn create(client: *Client, bucket: []const u8, path: []const u8) Error!types.Owned(types.ManagedFolderInfo) {
    var scratch: std.heap.ArenaAllocator = .init(client.gpa);
    defer scratch.deinit();
    const folder = try normalizedChecked(client, scratch.allocator(), path);
    const insert_path = try names.managedFoldersPath(scratch.allocator(), bucket, .insert);
    var body: std.Io.Writer.Allocating = .init(scratch.allocator());
    var jw: Stringify = .{ .writer = &body.writer };
    jw.beginObject() catch return error.OutOfMemory;
    jw.objectField("name") catch return error.OutOfMemory;
    jw.write(folder) catch return error.OutOfMemory;
    jw.endObject() catch return error.OutOfMemory;

    var attempt: u32 = 0;
    while (true) {
        attempt += 1;
        var result: types.Owned(types.ManagedFolderInfo) = try .init(client.gpa);
        const sent = rpc.execute(client, result.arena, .{
            .method = .POST,
            .path = insert_path,
            .body = body.written(),
            // A repeat of a create that landed is 409 exists: this loop
            // decides what a failure means.
            .retry = false,
        });
        if (sent) |response| {
            result.value = codec.decodeManagedFolder(result.arena.allocator(), response) catch |err| {
                result.deinit();
                return rpc.decodeFailed(client, err, "managed folder");
            };
            return result;
        } else |err| {
            result.deinit();
            if (!core.isRetryable(err)) return err;
            const delay_ms = rpc.backoffMs(client, attempt);
            logging.warn("creating managed folder {s} in {s} failed with {t}; reading it in {d} ms", .{ folder, bucket, err, delay_ms });
            try client.io.sleep(.fromMilliseconds(delay_ms), .awake);
            if (get(client, bucket, folder)) |found| {
                if (client.diagnostics) |d| d.clear();
                return found;
            } else |get_err| switch (get_err) {
                error.NotFound => {},
                error.OutOfMemory, error.Canceled => return get_err,
                else => {
                    if (client.diagnostics) |d| d.print(
                        "creating managed folder {s} failed with {t}, and reading it to see whether it landed failed with {t}: it may exist",
                        .{ folder, err, get_err },
                    );
                    return err;
                },
            }
            if (attempt >= client.retry.max_attempts) return err;
        }
    }
}

/// One managed folder. The caller has begun the call and checked the
/// bucket name.
pub fn get(client: *Client, bucket: []const u8, path: []const u8) Error!types.Owned(types.ManagedFolderInfo) {
    var scratch: std.heap.ArenaAllocator = .init(client.gpa);
    defer scratch.deinit();
    const folder = try normalizedChecked(client, scratch.allocator(), path);
    const get_path = try names.managedFoldersPath(scratch.allocator(), bucket, .{ .item = .{ .folder = folder } });

    var result: types.Owned(types.ManagedFolderInfo) = try .init(client.gpa);
    errdefer result.deinit();
    const response = try rpc.execute(client, result.arena, .{ .method = .GET, .path = get_path });
    result.value = codec.decodeManagedFolder(result.arena.allocator(), response) catch |err|
        return rpc.decodeFailed(client, err, "managed folder");
    return result;
}

/// Deletes one managed folder. Retried as sent: a lost first success shows
/// up as `error.NotFound`. The caller has begun the call and checked the
/// bucket name.
pub fn delete(client: *Client, bucket: []const u8, path: []const u8, allow_non_empty: bool, preconditions: types.Preconditions) Error!void {
    var scratch: std.heap.ArenaAllocator = .init(client.gpa);
    defer scratch.deinit();
    const folder = try normalizedChecked(client, scratch.allocator(), path);
    const delete_path = try names.managedFoldersPath(scratch.allocator(), bucket, .{ .item = .{
        .folder = folder,
        .allow_non_empty = allow_non_empty,
        .preconditions = preconditions,
    } });
    try rpc.executeDiscard(client, .{ .method = .DELETE, .path = delete_path });
}

/// One page of the bucket's managed folders. The caller has begun the call
/// and checked the bucket name.
pub fn list(client: *Client, bucket: []const u8, options: types.ManagedFolderListOptions) Error!types.Owned(types.ManagedFolderPage) {
    var scratch: std.heap.ArenaAllocator = .init(client.gpa);
    defer scratch.deinit();
    const path = try names.managedFoldersPath(scratch.allocator(), bucket, .{ .list = options });

    var result: types.Owned(types.ManagedFolderPage) = try .init(client.gpa);
    errdefer result.deinit();
    const response = try rpc.execute(client, result.arena, .{ .method = .GET, .path = path });
    result.value = codec.decodeManagedFolderPage(result.arena.allocator(), response) catch |err|
        return rpc.decodeFailed(client, err, "managed folder list");
    return result;
}

const testing = std.testing;
const test_util = @import("test_util.zig");

// Production's answers, measured on 2026-10-02 (`_tmp/folders`, run
// a81e0b49), the bucket names shortened.
const managed_answer =
    \\{"bucket":"zigps-mf","createTime":"2026-10-02T19:13:41.557Z","id":"zigps-mf/m1/","kind":"storage#managedFolder","metageneration":"1","name":"m1/","selfLink":"https://www.googleapis.com/storage/v1/b/zigps-mf/managedFolders/m1%2F","updateTime":"2026-10-02T19:13:41.557Z"}
;
const managed_page =
    \\{"items":[{"bucket":"zigps-mf","createTime":"2026-10-02T19:13:42.958Z","id":"zigps-mf/a/","kind":"storage#managedFolder","metageneration":"1","name":"a/","selfLink":"https://www.googleapis.com/storage/v1/b/zigps-mf/managedFolders/a%2F","updateTime":"2026-10-02T19:13:42.958Z"}],"kind":"storage#managedFolders","nextPageToken":"CgIuLw"}
;
/// A fresh policy: no bindings and no version at all, etag CAA=.
const fresh_policy =
    \\{"etag":"CAA=","kind":"storage#policy","resourceId":"projects/_/buckets/zigps-mf/managedFolders/m1/"}
;
const not_empty_managed =
    \\{"error":{"code":409,"errors":[{"domain":"global","message":"The managed folder you tried to delete is not empty.","reason":"conflict"}],"message":"The managed folder you tried to delete is not empty."}}
;
const no_uniform_access =
    \\{"error":{"code":412,"errors":[{"domain":"global","location":"If-Match","locationType":"header","message":"Uniform bucket-level access is required to be enabled on the bucket in order to perform this operation. Read more at https://cloud.google.com/storage/docs/uniform-bucket-level-access","reason":"conditionNotMet"}],"message":"Uniform bucket-level access is required to be enabled on the bucket in order to perform this operation. Read more at https://cloud.google.com/storage/docs/uniform-bucket-level-access"}}
;

test "decode: production's managed folders, a page, and the bare fresh policy" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const one = try codec.decodeManagedFolder(arena, managed_answer);
    try testing.expectEqualStrings("m1/", one.name);
    try testing.expectEqualStrings("zigps-mf", one.bucket);
    try testing.expectEqual(1, one.metageneration);
    try testing.expectEqualStrings("2026-10-02T19:13:41.557Z", one.create_time);
    const page = try codec.decodeManagedFolderPage(arena, managed_page);
    try testing.expectEqual(1, page.managed_folders.len);
    try testing.expectEqualStrings("CgIuLw", page.next_page_token.?);
    const none = try codec.decodeManagedFolderPage(arena, "{\"kind\":\"storage#managedFolders\"}");
    try testing.expectEqual(0, none.managed_folders.len);
    const policy = try core.iam.decode(arena, fresh_policy);
    try testing.expectEqualStrings("CAA=", policy.etag.?);
    try testing.expectEqual(0, policy.bindings.len);
    try testing.expectError(error.InvalidResponse, codec.decodeManagedFolder(arena, "{\"bucket\":\"b\"}"));
}

test "golden: create, get, list, delete and the IAM paths, as sent" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = managed_answer } },
        .{ .respond = .{ .body = managed_answer } },
        .{ .respond = .{ .body = managed_page } },
        .{ .respond = .{ .status = 204, .body = "" } },
        .{ .respond = .{ .body = fresh_policy } },
        .{ .respond = .{ .body =
        \\{"bindings":[{"members":["user:a@example.com"],"role":"roles/storage.objectViewer"}],"etag":"CAE=","kind":"storage#policy","resourceId":"projects/_/buckets/zigps-mf/managedFolders/m1/","version":1}
        } },
        .{ .respond = .{ .body = "{\"kind\":\"storage#testIamPermissionsResponse\",\"permissions\":[\"storage.objects.get\"]}" } },
    }, .{});
    defer h.deinit();
    const b = h.client.bucket("zigps-mf");

    var made = try b.managedFolder("m1").create();
    defer made.deinit();
    try testing.expectEqualStrings("m1/", made.value.name);
    try h.expectRequest(0, .POST, "https://storage.googleapis.com/storage/v1/b/zigps-mf/managedFolders", "{\"name\":\"m1/\"}");
    var got = try b.managedFolder("m1/").get();
    defer got.deinit();
    try h.expectRequest(1, .GET, "https://storage.googleapis.com/storage/v1/b/zigps-mf/managedFolders/m1%2F", null);
    var page = try b.listManagedFolders(.{ .prefix = "m", .page_size = 2 });
    defer page.deinit();
    try h.expectRequest(2, .GET, "https://storage.googleapis.com/storage/v1/b/zigps-mf/managedFolders?prefix=m&pageSize=2", null);
    try b.managedFolder("m1/").delete(.{ .allow_non_empty = true, .if_metageneration_match = 1 });
    try h.expectRequest(3, .DELETE, "https://storage.googleapis.com/storage/v1/b/zigps-mf/managedFolders/m1%2F?allowNonEmpty=true&ifMetagenerationMatch=1", null);

    var policy = try b.managedFolder("m1/").iamPolicy();
    defer policy.deinit();
    try testing.expectEqual(0, policy.value.bindings.len);
    try h.expectRequest(4, .GET, "https://storage.googleapis.com/storage/v1/b/zigps-mf/managedFolders/m1%2F/iam?optionsRequestedPolicyVersion=3", null);
    var written = try b.managedFolder("m1").setIamPolicy(.{ .etag = "CAA=", .bindings = &.{.{ .role = "roles/storage.objectViewer", .members = &.{"user:a@example.com"} }} });
    defer written.deinit();
    try h.expectRequest(5, .PUT, "https://storage.googleapis.com/storage/v1/b/zigps-mf/managedFolders/m1%2F/iam",
        \\{"version":1,"etag":"CAA=","bindings":[{"role":"roles/storage.objectViewer","members":["user:a@example.com"]}]}
    );
    try testing.expect((try h.fake.request(5)).header("x-goog-gcs-idempotency-token") != null);
    var held = try b.managedFolder("m1/").testIamPermissions(&.{"storage.objects.get"});
    defer held.deinit();
    try h.expectRequest(6, .GET, "https://storage.googleapis.com/storage/v1/b/zigps-mf/managedFolders/m1%2F/iam/testPermissions?permissions=storage.objects.get", null);
}

test "refused before sending: the rules Cloud Storage holds managed folders to, and the shared stances" {
    var h: test_util.Harness = undefined;
    try h.init(&.{}, .{});
    defer h.deinit();
    const b = h.client.bucket("zigps-mf");
    try testing.expectError(error.InvalidFolderName, b.managedFolder("").create());
    try testing.expectError(error.InvalidFolderName, b.managedFolder(test_util.repeat("m", 1024) ++ "/").create());
    try testing.expectError(error.InvalidFolderName, b.managedFolder(test_util.repeat("d/", 16)).create());
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "15 levels") != null);
    try testing.expectError(error.InvalidFolderName, b.managedFolder("a\rb/").create());
    try testing.expectError(error.InvalidFolderName, b.managedFolder(".well-known/acme-challenge/x/").get());
    try testing.expectError(error.InvalidFolderName, b.managedFolder("../").delete(.{}));
    try testing.expectError(error.InvalidFolderName, b.managedFolder("./").iamPolicy());
    try testing.expectError(error.InvalidArgument, b.managedFolder("m1/").testIamPermissions(&.{"storage.buckets.list"}));
    try testing.expectError(error.InvalidArgument, b.managedFolder("m1/").testIamPermissions(&.{ "storage.objects.get", "storage.objects.get" }));
    try testing.expectError(error.InvalidArgument, b.managedFolder("m1/").addIamBinding("storage.objectViewer", "user:a@example.com"));
    try testing.expectError(error.InvalidBucketName, h.client.bucket("").managedFolder("m1/").get());
    try h.expectRequestCount(0);
}

test "the refusals production answered: exists, not empty, no uniform access, and a stale policy etag" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .status = 409, .body =
        \\{"error":{"code":409,"errors":[{"domain":"global","message":"The specified managed folder already exists.","reason":"conflict"}],"message":"The specified managed folder already exists."}}
        } },
        .{ .respond = .{ .status = 409, .body = not_empty_managed } },
        .{ .respond = .{ .status = 412, .body = no_uniform_access } },
        .{ .respond = .{ .status = 412, .body =
        \\{"error":{"code":412,"message":"At least one of the pre-conditions you specified did not hold.","errors":[{"message":"At least one of the pre-conditions you specified did not hold.","domain":"global","reason":"conditionNotMet"}]}}
        } },
    }, .{ .retry = .{ .max_attempts = 1 } });
    defer h.deinit();
    const b = h.client.bucket("zigps-mf");
    try testing.expectError(error.AlreadyExists, b.managedFolder("m1/").create());
    try testing.expectError(error.FolderNotEmpty, b.managedFolder("m1/").delete(.{}));
    try testing.expectEqualStrings("The managed folder you tried to delete is not empty.", h.diag.message());
    try testing.expectError(error.FailedPrecondition, b.managedFolder("m1/").create());
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "Uniform bucket-level access is required") != null);
    // The policy write under a stale etag is a concurrent change.
    try testing.expectError(error.Aborted, b.managedFolder("m1/").setIamPolicy(.{ .etag = "CAE=" }));
}

test "a create whose answer was lost is read back, not sent again" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        .{ .fail = error.ConnectionResetByPeer },
        .{ .respond = .{ .body = managed_answer } },
    }, .{ .retry = .{ .max_attempts = 3, .initial_backoff_ms = 1, .max_backoff_ms = 2 } });
    defer h.deinit();
    var made = try h.client.bucket("zigps-mf").managedFolder("m1/").create();
    defer made.deinit();
    try testing.expectEqualStrings("m1/", made.value.name);
    try h.expectRequest(0, .POST, "https://storage.googleapis.com/storage/v1/b/zigps-mf/managedFolders", "{\"name\":\"m1/\"}");
    try h.expectRequest(1, .GET, "https://storage.googleapis.com/storage/v1/b/zigps-mf/managedFolders/m1%2F", null);
    try h.expectRequestCount(2);
    try testing.expectEqual(0, h.diag.message().len);
}

test "a lost create whose read-back fails says it may exist, and NotFound tries again" {
    // The read-back fails with neither NotFound nor a reason to stop:
    // the create's own error comes back, with both failures named.
    var h: test_util.Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .status = 503, .body = "{}" } },
        .{ .respond = .{ .status = 403, .body = "{\"error\":{\"code\":403,\"message\":\"no\",\"errors\":[{\"reason\":\"forbidden\"}]}}" } },
    }, .{ .retry = .{ .max_attempts = 3, .initial_backoff_ms = 1, .max_backoff_ms = 2 } });
    defer h.deinit();
    try testing.expectError(error.Unavailable, h.client.bucket("zigps-mf").managedFolder("m1/").create());
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "it may exist") != null);
    try h.expectRequestCount(2);

    // NotFound from the read-back means it never landed: the create goes
    // out again, and the attempts run out on the create's error.
    var again: test_util.Harness = undefined;
    try again.init(&.{
        .{ .respond = .{ .status = 503, .body = "{}" } },
        .{ .respond = .{ .status = 404, .body = "{\"error\":{\"code\":404,\"message\":\"x\",\"errors\":[{\"reason\":\"notFound\"}]}}" } },
        .{ .respond = .{ .body = managed_answer } },
    }, .{ .retry = .{ .max_attempts = 2, .initial_backoff_ms = 1, .max_backoff_ms = 2 } });
    defer again.deinit();
    var made = try again.client.bucket("zigps-mf").managedFolder("m1/").create();
    made.deinit();
    try again.expectRequestCount(3);

    // With one attempt allowed, the NotFound read-back is the end of it.
    var once: test_util.Harness = undefined;
    try once.init(&.{
        .{ .respond = .{ .status = 503, .body = "{}" } },
        .{ .respond = .{ .status = 404, .body = "{\"error\":{\"code\":404,\"message\":\"x\",\"errors\":[{\"reason\":\"notFound\"}]}}" } },
    }, .{ .retry = .{ .max_attempts = 1, .initial_backoff_ms = 1, .max_backoff_ms = 2 } });
    defer once.deinit();
    try testing.expectError(error.Unavailable, once.client.bucket("zigps-mf").managedFolder("m1/").create());
    try once.expectRequestCount(2);
}

const FakeBuckets = @import("fake_buckets.zig").FakeBuckets;

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
        f.client = try .init(testing.allocator, f.fake.io, .{
            .project_id = "extractctl",
            .token_provider = f.token.provider(),
            .transport = f.fake.transport(),
            .diagnostics = &f.diag,
            .retry = .{ .max_attempts = 3, .initial_backoff_ms = 1, .max_backoff_ms = 2 },
        });
        errdefer f.client.deinit();
        var uniform = try f.client.bucket("zigps-mf").create(.{ .uniform_bucket_level_access = true });
        uniform.deinit();
        var fine = try f.client.bucket("zigps-fine").create(.{});
        fine.deinit();
        var hns = try f.client.bucket("zigps-hns").create(.{ .hierarchical_namespace = true });
        hns.deinit();
    }

    fn deinit(f: *Fixture) void {
        f.client.deinit();
        f.fake.deinit();
    }
};

const agent = "serviceAccount:service-82150720798@gs-project-accounts.iam.gserviceaccount.com";

test "against production's rules: creates, children first, deletes and what non-empty means" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const b = f.client.bucket("zigps-mf");

    var made = try b.managedFolder("m1").create();
    defer made.deinit();
    try testing.expectEqualStrings("m1/", made.value.name);
    try testing.expectError(error.AlreadyExists, b.managedFolder("m1/").create());
    // A child before its parents is fine, as measured.
    var child = try b.managedFolder("child/of/missing/").create();
    defer child.deinit();
    // No uniform access, no managed folders: told apart by the message.
    try testing.expectError(error.FailedPrecondition, f.client.bucket("zigps-fine").managedFolder("m1/").create());
    try testing.expect(std.mem.indexOf(u8, f.diag.message(), "Uniform bucket-level access is required") != null);

    var up = try b.object("m1/inside.txt").upload("x", .{});
    defer up.deinit();
    try testing.expectError(error.FolderNotEmpty, b.managedFolder("m1/").delete(.{}));
    try testing.expectError(error.FailedPrecondition, b.managedFolder("m1/").delete(.{ .allow_non_empty = true, .if_metageneration_match = 999 }));
    try b.managedFolder("m1/").delete(.{ .allow_non_empty = true });
    try testing.expectError(error.NotFound, b.managedFolder("m1/").get());
    var nested = try b.managedFolder("child/").create();
    defer nested.deinit();
    try testing.expectError(error.FolderNotEmpty, b.managedFolder("child/").delete(.{}));

    var page = try b.listManagedFolders(.{ .prefix = "child/" });
    defer page.deinit();
    try testing.expectEqual(2, page.value.managed_folders.len);
    try testing.expectEqualStrings("child/", page.value.managed_folders[0].name);

    // In a hierarchical bucket the folders come along, and stay.
    const hb = f.client.bucket("zigps-hns");
    var hm = try hb.managedFolder("hm1/hm2/").create();
    defer hm.deinit();
    var folder = try hb.folder("hm1/hm2/").get();
    defer folder.deinit();
    try hb.managedFolder("hm1/hm2/").delete(.{});
    var still = try hb.folder("hm1/hm2/").get();
    defer still.deinit();
}

test "against production's rules: a policy of its own, from bare to conditional, stale writes told apart" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const b = f.client.bucket("zigps-mf");
    var made = try b.managedFolder("scope/").create();
    defer made.deinit();
    const mf = b.managedFolder("scope/");

    // Fresh: no bindings at all, etag CAA=, not the bucket's legacy set.
    var fresh = try mf.iamPolicy();
    defer fresh.deinit();
    try testing.expectEqualStrings("CAA=", fresh.value.etag.?);
    try testing.expectEqual(0, fresh.value.bindings.len);

    var granted = try mf.addIamBinding("roles/storage.objectViewer", agent);
    defer granted.deinit();
    try testing.expect(granted.value.grants("roles/storage.objectViewer", agent));
    try testing.expectEqualStrings("CAE=", granted.value.etag.?);

    // The bucket moving does NOT move this etag, unlike a bucket's own.
    var labelled = try b.update(.{ .labels = .{ .change = &.{.{ .key = "k", .value = "v" }} } });
    labelled.deinit();
    var after = try mf.iamPolicy();
    defer after.deinit();
    try testing.expectEqualStrings("CAE=", after.value.etag.?);

    // A write under the pre-write etag is a concurrent change.
    try testing.expectError(error.Aborted, mf.setIamPolicy(.{ .etag = "CAA=", .bindings = &.{} }));
    // A grant reads first, so it lands over the change.
    var second = try mf.addIamBinding("roles/storage.objectCreator", agent);
    defer second.deinit();
    try testing.expect(second.value.grants("roles/storage.objectViewer", agent));

    // Conditions are taken, answered as version 3.
    var conditional_policy = second.value;
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    conditional_policy.bindings = try std.mem.concat(scratch.allocator(), core.iam.Binding, &.{ second.value.bindings, &.{.{
        .role = "roles/storage.objectViewer",
        .members = &.{"user:a@example.com"},
        .condition = "{\"title\":\"t\",\"expression\":\"request.time < timestamp(\\\"2030-01-01T00:00:00Z\\\")\"}",
    }} });
    var conditioned = try mf.setIamPolicy(conditional_policy);
    defer conditioned.deinit();
    try testing.expectEqual(3, conditioned.value.version);
    try testing.expect(conditioned.value.hasConditions());

    // Only Cloud Storage's roles, in production's words.
    try testing.expectError(error.InvalidArgument, mf.addIamBinding("roles/pubsub.viewer", agent));
    try testing.expectEqualStrings("Role roles/pubsub.viewer is not supported for this resource.", f.diag.message());

    // Bucket permissions: production's bare refusal.
    var held = try mf.testIamPermissions(&.{ "storage.objects.get", "storage.managedFolders.get" });
    defer held.deinit();
    try testing.expectEqual(2, held.value.len);
    try testing.expectError(error.InvalidArgument, mf.testIamPermissions(&.{"storage.buckets.get"}));
    try testing.expectEqualStrings("Invalid argument.", f.diag.message());

    try testing.expectError(error.NotFound, b.managedFolder("gone/").iamPolicy());
}

fn everyCall(gpa: std.mem.Allocator) !void {
    var fake: test_util.FakeTransport = .init(gpa, &.{
        .{ .respond = .{ .body = managed_answer } },
        .{ .fail = error.ConnectionResetByPeer },
        .{ .respond = .{ .body = managed_answer } },
        .{ .respond = .{ .body = managed_page } },
        .{ .respond = .{ .body = fresh_policy } },
        .{ .respond = .{ .body =
        \\{"bindings":[{"members":["user:a@example.com"],"role":"roles/storage.objectViewer"}],"etag":"CAE=","kind":"storage#policy","resourceId":"projects/_/buckets/zigps-mf/managedFolders/m1/","version":1}
        } },
        .{ .respond = .{ .body = "{\"kind\":\"storage#testIamPermissionsResponse\",\"permissions\":[\"storage.objects.get\"]}" } },
        .{ .respond = .{ .status = 204, .body = "" } },
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
    const b = client.bucket("zigps-mf");
    var made = try b.managedFolder("m1").create();
    made.deinit();
    // A lost answer, found by the read after it.
    var found = try b.managedFolder("m1/").create();
    found.deinit();
    var page = try b.listManagedFolders(.{});
    page.deinit();
    var granted = try b.managedFolder("m1/").addIamBinding("roles/storage.objectViewer", "user:a@example.com");
    granted.deinit();
    var held = try b.managedFolder("m1/").testIamPermissions(&.{"storage.objects.get"});
    held.deinit();
    try b.managedFolder("m1/").delete(.{});
}

test "managed folders: every allocation failure is OutOfMemory, and nothing leaks" {
    try testing.checkAllAllocationFailures(test_util.no_grow_allocator, everyCall, .{});
}
