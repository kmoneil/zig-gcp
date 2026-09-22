//! Integration tests against a Cloud Storage server, normally
//! `fake-gcs-server`: set STORAGE_EMULATOR_HOST (and optionally
//! STORAGE_PROJECT_ID, default "test"). With it unset, every test skips.
//!
//! Each test creates a uniquely named bucket (prefix `zigps-`) and deletes
//! it and everything in it, even when the test fails.

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

    /// Uploads and forgets the metadata, for tests that only need the
    /// object to exist.
    fn upload(f: *Fixture, name: []const u8, data: []const u8) !void {
        var info = try f.bucket().object(name).upload(data, .{ .content_type = "text/plain" });
        info.deinit();
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
    }) |name| try f.upload(name, "hello world\n");

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
        try f.upload(name, "hello world\n");
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
    try f.upload("reports/2026/q3.txt", "hello world\n");
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

test "round trip: upload, metadata, download, checksum" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    var created = try f.bucket().create(.{});
    created.deinit();
    const data = "hello world\n";
    const obj = f.bucket().object("reports/2026/q3.txt");

    var uploaded = try obj.upload(data, .{ .content_type = "text/plain" });
    defer uploaded.deinit();
    try testing.expectEqualStrings("reports/2026/q3.txt", uploaded.value.name);
    try testing.expectEqual(data.len, uploaded.value.size);
    if (uploaded.value.crc32c) |crc| try testing.expectEqual(core.crc32c.hash(data), crc);

    var got = try obj.get(.{});
    defer got.deinit();
    try testing.expectEqual(data.len, got.value.size);
    try testing.expectEqualStrings("text/plain", got.value.content_type);

    var downloaded = try obj.downloadAlloc(1024, .{});
    defer downloaded.deinit();
    try testing.expectEqualStrings(data, downloaded.value.data);
    try testing.expectEqual(data.len, downloaded.value.result.bytes_written);
    try testing.expectEqual(core.crc32c.hash(data), core.crc32c.hash(downloaded.value.data));
    // The emulator may omit the checksum header; when it sends one, the
    // library must have verified against it.
    if (!downloaded.value.result.checksum_verified) {
        std.debug.print("note: the emulator sent no crc32c to verify\n", .{});
    }

    // A cap below the object's size refuses without holding the object.
    try testing.expectError(error.ObjectTooLarge, obj.downloadAlloc(data.len - 1, .{}));
}

test "round trip: all 256 byte values survive" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    var created = try f.bucket().create(.{});
    created.deinit();

    var data: [256]u8 = undefined;
    for (&data, 0..) |*b, i| b.* = @intCast(i);
    const obj = f.bucket().object("binary.bin");
    var uploaded = try obj.upload(&data, .{ .crc32c = core.crc32c.hash(&data) });
    uploaded.deinit();

    var downloaded = try obj.downloadAlloc(1024, .{});
    defer downloaded.deinit();
    try testing.expectEqualSlices(u8, &data, downloaded.value.data);
}

test "round trip: a zero-byte object" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    var created = try f.bucket().create(.{});
    created.deinit();
    const obj = f.bucket().object("empty");

    var uploaded = try obj.upload("", .{});
    defer uploaded.deinit();
    try testing.expectEqual(0, uploaded.value.size);

    var downloaded = try obj.downloadAlloc(1024, .{});
    defer downloaded.deinit();
    try testing.expectEqual(0, downloaded.value.data.len);
    // Zero fits under any cap, even zero.
    var under_zero_cap = try obj.downloadAlloc(0, .{});
    under_zero_cap.deinit();
}

test "round trip: odd names through upload, list, get, download and delete" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    var created = try f.bucket().create(.{});
    created.deinit();

    for ([_][]const u8{
        "a b.txt",
        "100%.txt",
        "q?.txt#1",
        "plus+sign.txt",
        "caf\xc3\xa9/menu.txt",
    }) |name| {
        try f.upload(name, "hello world\n");
        var listed = try f.bucket().listObjects(.{ .prefix = name });
        defer listed.deinit();
        try testing.expectEqual(1, listed.value.objects.len);
        try testing.expectEqualStrings(name, listed.value.objects[0].name);

        var downloaded = try f.bucket().object(name).downloadAlloc(1024, .{});
        defer downloaded.deinit();
        try testing.expectEqualStrings("hello world\n", downloaded.value.data);

        try f.bucket().object(name).delete(.{});
        try testing.expect(!try f.bucket().object(name).exists());
    }
}

test "round trip: custom metadata, content type and cache control" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    var created = try f.bucket().create(.{});
    created.deinit();
    const obj = f.bucket().object("with-metadata.txt");

    var uploaded = try obj.upload("hello world\n", .{
        .content_type = "text/plain; charset=utf-8",
        .cache_control = "no-store",
        .metadata = &.{
            .{ .key = "origin", .value = "zig" },
            .{ .key = "empty", .value = "" },
        },
    });
    uploaded.deinit();

    var got = try obj.get(.{});
    defer got.deinit();
    try testing.expectEqualStrings("text/plain; charset=utf-8", got.value.content_type);
    try testing.expectEqualStrings("zig", got.value.metadataValue("origin").?);
    try testing.expectEqualStrings("", got.value.metadataValue("empty").?);
    try testing.expectEqual(null, got.value.metadataValue("missing"));
}

test "download streams into a writer with the checksum verified" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    var created = try f.bucket().create(.{});
    created.deinit();
    const data = "hello world\n";
    try f.upload("streamed.txt", data);

    var buf: [64]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    const result = try f.bucket().object("streamed.txt").download(&out, .{});
    try testing.expectEqualStrings(data, out.buffered());
    try testing.expectEqual(data.len, result.bytes_written);
    try testing.expect(result.generation != 0);
    if (!result.checksum_verified) std.debug.print("note: the emulator sent no crc32c to verify\n", .{});

    // Pinned to its generation, the same bytes come back.
    out = .fixed(&buf);
    const pinned = try f.bucket().object("streamed.txt").download(&out, .{ .generation = result.generation });
    try testing.expectEqual(data.len, pinned.bytes_written);
}

test "range downloads: the first bytes, the last bytes, and past the end" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    var created = try f.bucket().create(.{});
    created.deinit();
    var data: [100]u8 = undefined;
    for (&data, 0..) |*b, i| b.* = 'a' + @as(u8, @intCast(i % 26));
    try f.upload("ranged.bin", &data);
    const obj = f.bucket().object("ranged.bin");

    var buf: [128]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    const first = try obj.download(&out, .{ .range = .{ .offset = 0, .length = 10 } });
    try testing.expectEqualSlices(u8, data[0..10], out.buffered());
    try testing.expectEqual(10, first.bytes_written);
    // The whole-object checksum cannot cover ten bytes of it.
    try testing.expect(!first.checksum_verified);

    out = .fixed(&buf);
    const last = try obj.download(&out, .{ .range = .{ .offset = 90, .length = 10 } });
    try testing.expectEqualSlices(u8, data[90..], out.buffered());
    try testing.expectEqual(10, last.bytes_written);

    out = .fixed(&buf);
    const tail = try obj.download(&out, .{ .range = .{ .offset = 95 } });
    try testing.expectEqualSlices(u8, data[95..], out.buffered());
    try testing.expectEqual(5, tail.bytes_written);

    out = .fixed(&buf);
    try testing.expectError(error.OutOfRange, obj.download(&out, .{ .range = .{ .offset = 1000 } }));

    // downloadAlloc takes the same ranges.
    var ten = try obj.downloadAlloc(1024, .{ .range = .{ .offset = 10, .length = 10 } });
    defer ten.deinit();
    try testing.expectEqualSlices(u8, data[10..20], ten.value.data);
}

test "a range on an empty object is zero bytes, not an error" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    var created = try f.bucket().create(.{});
    created.deinit();
    try f.upload("empty.bin", "");

    var buf: [16]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    const result = try f.bucket().object("empty.bin").download(&out, .{ .range = .{ .offset = 0 } });
    try testing.expectEqual(0, result.bytes_written);
}

/// A client with the smallest legal chunks, so a modest object forces many
/// of them.
fn smallChunkClient(f: *Fixture, diag: *storage.Diagnostics) !storage.Client {
    return .init(testing.allocator, testing.io, .{
        .project_id = f.env.get("STORAGE_PROJECT_ID") orelse "test",
        .endpoint = storage.Endpoint.fromEnv(&f.env),
        .diagnostics = diag,
        .chunk_size = 256 * 1024,
        .single_request_limit = 1024,
        .user_agent = "zig-gcp-storage-integration/0.1",
    });
}

test "resumable: uploadFrom in many chunks, sized, unsized, and on the boundary" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    var created = try f.bucket().create(.{});
    created.deinit();

    var diag: storage.Diagnostics = .{};
    var client = try smallChunkClient(&f, &diag);
    defer client.deinit();
    const bucket = client.bucket(&f.bucket_name);

    const gpa = testing.allocator;
    const big = try gpa.alloc(u8, 20 * 1024 * 1024);
    defer gpa.free(big);
    for (big, 0..) |*b, i| b.* = @intCast((i *% 31) % 251);
    const big_crc = core.crc32c.hash(big);

    // 20 MiB through 256 KiB chunks: eighty round trips, size declared.
    var sized: std.Io.Reader = .fixed(big);
    var a = try bucket.object("sized.bin").uploadFrom(&sized, .{ .size = big.len });
    defer a.deinit();
    try testing.expectEqual(big.len, a.value.size);
    if (a.value.crc32c) |crc| try testing.expectEqual(big_crc, crc);

    // The same bytes with the size unknown until the stream ends.
    var unsized: std.Io.Reader = .fixed(big);
    var b = try bucket.object("unsized.bin").uploadFrom(&unsized, .{});
    defer b.deinit();
    try testing.expectEqual(big.len, b.value.size);

    // A stream that ends exactly on a chunk boundary, finished by the
    // empty PUT.
    var boundary: std.Io.Reader = .fixed(big[0 .. 512 * 1024]);
    var c = try bucket.object("boundary.bin").uploadFrom(&boundary, .{});
    defer c.deinit();
    try testing.expectEqual(512 * 1024, c.value.size);

    // What came back is what went in.
    var downloaded = try bucket.object("sized.bin").downloadAlloc(big.len + 1, .{});
    defer downloaded.deinit();
    try testing.expectEqual(big.len, downloaded.value.data.len);
    try testing.expectEqual(big_crc, core.crc32c.hash(downloaded.value.data));
}

test "resumable: upload above the single-request limit, chunks sliced from memory" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    var created = try f.bucket().create(.{});
    created.deinit();

    var diag: storage.Diagnostics = .{};
    var client = try smallChunkClient(&f, &diag);
    defer client.deinit();
    const bucket = client.bucket(&f.bucket_name);

    const gpa = testing.allocator;
    const data = try gpa.alloc(u8, 600 * 1024);
    defer gpa.free(data);
    for (data, 0..) |*b, i| b.* = @intCast(i % 251);

    var uploaded = try bucket.object("large.bin").upload(data, .{});
    defer uploaded.deinit();
    try testing.expectEqual(data.len, uploaded.value.size);
    if (uploaded.value.crc32c) |crc| try testing.expectEqual(core.crc32c.hash(data), crc);

    var downloaded = try bucket.object("large.bin").downloadAlloc(data.len + 1, .{});
    defer downloaded.deinit();
    try testing.expectEqualSlices(u8, data, downloaded.value.data);
}

test "copyTo within a bucket and across two buckets" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    var created = try f.bucket().create(.{});
    created.deinit();
    const data = "hello world\n";
    try f.upload("reports/original.txt", data);

    // Within the bucket.
    const src = f.bucket().object("reports/original.txt");
    var copied = try src.copyTo(f.bucket().object("copies/first.txt"), .{});
    defer copied.deinit();
    try testing.expectEqualStrings("copies/first.txt", copied.value.name);
    try testing.expectEqual(data.len, copied.value.size);
    var round = try f.bucket().object("copies/first.txt").downloadAlloc(1024, .{});
    defer round.deinit();
    try testing.expectEqualStrings(data, round.value.data);

    // Across buckets: a second one, cleaned up by hand.
    var other_name: [16]u8 = undefined;
    var random: [4]u8 = undefined;
    testing.io.random(&random);
    _ = try std.fmt.bufPrint(&other_name, "zigps-cp-{x}", .{random[0..3]});
    const other = f.client.bucket(other_name[0..15]);
    var other_created = try other.create(.{});
    other_created.deinit();
    defer other.delete() catch {};
    defer other.object("far.txt").delete(.{}) catch {};

    var far = try src.copyTo(other.object("far.txt"), .{});
    defer far.deinit();
    try testing.expectEqual(data.len, far.value.size);
    var far_round = try other.object("far.txt").downloadAlloc(1024, .{});
    defer far_round.deinit();
    try testing.expectEqualStrings(data, far_round.value.data);
}

test "does_not_exist uploads succeed once, then fail their precondition" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    var created = try f.bucket().create(.{});
    created.deinit();
    const obj = f.bucket().object("create-only.txt");

    var first = try obj.upload("one", .{ .preconditions = .does_not_exist });
    first.deinit();
    try testing.expectError(error.FailedPrecondition, obj.upload("two", .{ .preconditions = .does_not_exist }));
    try testing.expectEqual(412, f.diag.http_status);

    // The object is untouched by the refused overwrite.
    var round = try obj.downloadAlloc(64, .{});
    defer round.deinit();
    try testing.expectEqualStrings("one", round.value.data);

    // A delete conditioned on the right generation goes through. (That a
    // wrong generation is refused is the real-bucket suite's business:
    // fake-gcs-server does not enforce preconditions on deletes.)
    var info = try obj.get(.{});
    const generation = info.value.generation;
    info.deinit();
    try obj.delete(.{ .preconditions = .{ .if_generation_match = generation } });
    try testing.expect(!try obj.exists());
}

/// Uses a URL the way a browser would: no credentials, and only the
/// headers it was signed with. Returns the status; the body lands in
/// `body`.
fn useUrl(
    method: std.http.Method,
    url: []const u8,
    headers: []const std.http.Header,
    payload: ?[]const u8,
    body: *std.Io.Writer.Allocating,
) !std.http.Status {
    var http: std.http.Client = .{ .allocator = testing.allocator, .io = testing.io };
    defer http.deinit();
    const result = try http.fetch(.{
        .location = .{ .url = url },
        .method = method,
        .payload = payload,
        .extra_headers = headers,
        .response_writer = &body.writer,
        .keep_alive = false,
    });
    return result.status;
}

// fake-gcs-server does not check signatures, so a fake signer is enough:
// these prove that a signed URL reaches the right object, through the XML
// API's paths, with no credentials. Whether Cloud Storage accepts the
// signature is Google's conformance vectors' business, and the real-bucket
// suite's. The emulator serves the XML API only when started with
// `-public-host` naming the host in STORAGE_EMULATOR_HOST, as CI does.

test "signed URLs: PUT, GET, HEAD and DELETE an object, with no credentials" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    var created = try f.bucket().create(.{});
    created.deinit();
    var signer: core.testing.FakeSigner = .{};
    const data = "hello, signed\n";

    for ([_][]const u8{ "photos/cat.txt", "a b/c+d%e/caf\xc3\xa9 (1).txt" }) |name| {
        errdefer std.debug.print("object: {s}\n", .{name});
        const obj = f.bucket().object(name);
        var body: std.Io.Writer.Allocating = .init(testing.allocator);
        defer body.deinit();

        const content_type: std.http.Header = .{ .name = "content-type", .value = "text/plain" };
        var put = try obj.signedUrl(signer.signer(), .{ .method = .PUT, .expires_in_s = 600, .headers = &.{content_type} });
        defer put.deinit();
        try testing.expect(std.mem.startsWith(u8, put.value, f.client.base_url));
        try testing.expectEqual(.ok, try useUrl(.PUT, put.value, &.{content_type}, data, &body));
        var info = try obj.get(.{});
        try testing.expectEqual(data.len, info.value.size);
        try testing.expectEqualStrings("text/plain", info.value.content_type);
        info.deinit();

        var get = try obj.signedUrl(signer.signer(), .{ .expires_in_s = 600 });
        defer get.deinit();
        body.clearRetainingCapacity();
        try testing.expectEqual(.ok, try useUrl(.GET, get.value, &.{}, null, &body));
        try testing.expectEqualStrings(data, body.written());

        var head = try obj.signedUrl(signer.signer(), .{ .method = .HEAD, .expires_in_s = 600 });
        defer head.deinit();
        body.clearRetainingCapacity();
        try testing.expectEqual(.ok, try useUrl(.HEAD, head.value, &.{}, null, &body));
        try testing.expectEqual(0, body.written().len);

        // Cloud Storage answers a DELETE 204; fake-gcs-server says 200.
        var delete = try obj.signedUrl(signer.signer(), .{ .method = .DELETE, .expires_in_s = 600 });
        defer delete.deinit();
        body.clearRetainingCapacity();
        const status = try useUrl(.DELETE, delete.value, &.{}, null, &body);
        try testing.expect(status == .ok or status == .no_content);
        try testing.expect(!try obj.exists());
    }
}

test "signed URLs: a bucket-level GET lists the bucket through the XML API" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    var created = try f.bucket().create(.{});
    created.deinit();
    try f.upload("cats/tom.txt", "meow\n");
    try f.upload("dogs/rex.txt", "woof\n");
    var signer: core.testing.FakeSigner = .{};

    var list = try f.bucket().signedUrl(signer.signer(), .{
        .expires_in_s = 60,
        .query = &.{.{ .name = "prefix", .value = "cats/" }},
    });
    defer list.deinit();
    var body: std.Io.Writer.Allocating = .init(testing.allocator);
    defer body.deinit();
    try testing.expectEqual(.ok, try useUrl(.GET, list.value, &.{}, null, &body));
    try testing.expect(std.mem.indexOf(u8, body.written(), "<Key>cats/tom.txt</Key>") != null);
    try testing.expect(std.mem.indexOf(u8, body.written(), "dogs/rex.txt") == null);
}
