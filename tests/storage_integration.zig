//! Integration tests against a Cloud Storage server, normally
//! `fake-gcs-server`: set STORAGE_EMULATOR_HOST (and optionally
//! STORAGE_PROJECT_ID, default "test"). With it unset, every test skips.
//!
//! The library cannot upload yet, so tests that need objects create them
//! the way curl would: one raw media-upload request straight through the
//! transport. Each test creates a uniquely named bucket (prefix `zigps-`)
//! and deletes it and everything in it, even when the test fails.

const std = @import("std");
const core = @import("core");
const storage = @import("storage");
const testing = std.testing;

const Fixture = struct {
    env: std.process.Environ.Map,
    diag: storage.Diagnostics,
    client: storage.Client,
    /// "zigps-" plus 8 random hex digits, unique per test.
    bucket_name: [14]u8,

    /// Returns false when no server is configured; the test should skip.
    fn init(f: *Fixture) !bool {
        const gpa = testing.allocator;
        f.env = try testing.environ.createMap(gpa);
        errdefer f.env.deinit();
        const emulator = storage.Endpoint.fromEnv(&f.env) orelse {
            f.env.deinit();
            return false;
        };
        f.diag = .{};
        var random: [4]u8 = undefined;
        testing.io.random(&random);
        _ = try std.fmt.bufPrint(&f.bucket_name, "zigps-{x}", .{random});
        f.client = try .init(gpa, testing.io, .{
            .project_id = f.env.get("STORAGE_PROJECT_ID") orelse "test",
            .endpoint = emulator,
            .diagnostics = &f.diag,
            .user_agent = "zig-gcp-storage-integration/0.1",
        });
        return true;
    }

    /// Deletes every object in the test's bucket, then the bucket.
    fn deinit(f: *Fixture) void {
        const b = f.client.bucket(&f.bucket_name);
        while (true) {
            var page = b.listObjects(.{}) catch break;
            defer page.deinit();
            if (page.value.objects.len == 0) break;
            for (page.value.objects) |info| {
                b.object(info.name).delete(.{}) catch {};
            }
        }
        b.delete() catch {};
        f.client.deinit();
        f.env.deinit();
    }

    fn bucket(f: *Fixture) storage.Bucket {
        return f.client.bucket(&f.bucket_name);
    }

    /// What `curl -X POST --data-binary` would do: one raw media-upload
    /// request, bypassing the library's (not yet written) upload path.
    fn uploadRaw(f: *Fixture, name: []const u8, data: []const u8) !void {
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        var url: std.Io.Writer.Allocating = .init(arena.allocator());
        try url.writer.print("{s}/upload/storage/v1/b/{s}/o?uploadType=media&name=", .{
            f.client.base_url, &f.bucket_name,
        });
        try core.query.writeValue(&url.writer, name);
        const res = try f.client.transport.sendStream(.{
            .method = .POST,
            .url = url.written(),
            .content_type = "text/plain",
            .body = .{ .segments = &.{data} },
        }, arena.allocator());
        if (res.status != 200) {
            std.debug.print("raw upload of {s} answered {d}: {s}\n", .{ name, res.status, res.body });
            return error.TestUploadFailed;
        }
    }
};

test "buckets: create, get, find in the list, delete" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();

    var created = try f.bucket().create(.{});
    defer created.deinit();
    try testing.expectEqualStrings(&f.bucket_name, created.value.name);

    var got = try f.bucket().get();
    defer got.deinit();
    try testing.expectEqualStrings(&f.bucket_name, got.value.name);

    // Find it in the list, paging in case other tests left buckets around.
    var token: ?[]const u8 = null;
    var token_buf: [512]u8 = undefined;
    var found = false;
    while (!found) {
        var page = try f.client.listBuckets(.{ .page_token = token });
        defer page.deinit();
        for (page.value.buckets) |info| {
            if (std.mem.eql(u8, info.name, &f.bucket_name)) found = true;
        }
        const next = page.value.next_page_token orelse break;
        token = token_buf[0..next.len];
        @memcpy(token_buf[0..next.len], next);
    }
    try testing.expect(found);

    try f.bucket().delete();
    try testing.expectError(error.NotFound, f.bucket().get());
    // Deleting a bucket that is already gone is NotFound too.
    try testing.expectError(error.NotFound, f.bucket().delete());
}

test "objects: listing with a prefix, a delimiter, and paging" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    var created = try f.bucket().create(.{});
    created.deinit();

    for ([_][]const u8{
        "reports/2026/q3.txt",
        "reports/2026/archive/old.txt",
        "reports/intro.txt",
        "top.txt",
    }) |name| try f.uploadRaw(name, "hello world\n");

    // A prefix narrows the listing.
    var under_reports = try f.bucket().listObjects(.{ .prefix = "reports/" });
    defer under_reports.deinit();
    try testing.expectEqual(3, under_reports.value.objects.len);
    try testing.expectEqual(0, under_reports.value.prefixes.len);
    for (under_reports.value.objects) |info| {
        try testing.expect(std.mem.startsWith(u8, info.name, "reports/"));
        try testing.expectEqual(12, info.size);
    }

    // A delimiter groups deeper names into prefixes, how "folders" show up.
    var folders = try f.bucket().listObjects(.{ .prefix = "reports/", .delimiter = "/" });
    defer folders.deinit();
    try testing.expectEqual(1, folders.value.objects.len);
    try testing.expectEqualStrings("reports/intro.txt", folders.value.objects[0].name);
    try testing.expectEqual(1, folders.value.prefixes.len);
    try testing.expectEqualStrings("reports/2026/", folders.value.prefixes[0]);

    // Paging with page_size = 2 walks all four in name order.
    var seen: usize = 0;
    var token: ?[]const u8 = null;
    var token_buf: [512]u8 = undefined;
    var pages: usize = 0;
    while (true) {
        var page = try f.bucket().listObjects(.{ .page_size = 2, .page_token = token });
        defer page.deinit();
        pages += 1;
        try testing.expect(page.value.objects.len <= 2);
        seen += page.value.objects.len;
        const next = page.value.next_page_token orelse break;
        token = token_buf[0..next.len];
        @memcpy(token_buf[0..next.len], next);
        try testing.expect(pages < 10);
    }
    try testing.expectEqual(4, seen);
    try testing.expect(pages >= 2);
}

test "objects: names with slashes, spaces and percent round-trip through get" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    var created = try f.bucket().create(.{});
    created.deinit();

    for ([_][]const u8{
        "a b.txt",
        "100%.txt",
        "q?.txt#1",
        "caf\xc3\xa9/menu.txt",
    }) |name| {
        try f.uploadRaw(name, "hello world\n");
        var info = try f.bucket().object(name).get(.{});
        defer info.deinit();
        try testing.expectEqualStrings(name, info.value.name);
        try testing.expectEqual(12, info.value.size);
        if (info.value.crc32c) |crc| try testing.expectEqual(core.crc32c.hash("hello world\n"), crc);
    }
}

test "objects: delete, then NotFound from get and delete" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    var created = try f.bucket().create(.{});
    created.deinit();

    const obj = f.bucket().object("reports/2026/q3.txt");
    try f.uploadRaw("reports/2026/q3.txt", "hello world\n");
    try testing.expect(try obj.exists());

    var info = try obj.get(.{});
    try testing.expect(info.value.generation != 0);
    const generation = info.value.generation;
    info.deinit();

    try obj.delete(.{ .generation = generation });
    try testing.expect(!try obj.exists());
    try testing.expectError(error.NotFound, obj.get(.{}));
    try testing.expectError(error.NotFound, obj.delete(.{}));
    try testing.expectEqual(404, f.diag.http_status);
}
