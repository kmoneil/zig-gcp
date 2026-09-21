//! A cheap handle on one object: metadata, existence, deletion, uploading
//! bytes from memory and downloading them back, checksummed both ways.
//! Making one sends nothing. Streaming uploads and downloads arrive in
//! later milestones.

const Object = @This();

const std = @import("std");
const core = @import("core");

const Client = @import("Client.zig");
const codec = @import("codec.zig");
const download = @import("download.zig");
const errors = @import("errors.zig");
const logging = @import("logging.zig");
const multipart = @import("multipart.zig");
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

/// Uploads bytes already in memory as one `multipart/related` request: the
/// metadata part carries the name and the data's CRC-32C, which the server
/// verifies before the object exists, and the data travels beside it
/// without being copied. Peak extra memory: a few kilobytes of framing.
///
/// Not retried unless `retry_unconditional_writes` opted in: the first
/// attempt may have landed before its response was lost, and a blind
/// repeat would overwrite whatever is there by then.
pub fn upload(self: Object, data: []const u8, options: types.UploadOptions) Error!types.Owned(types.ObjectInfo) {
    rpc.begin(self.client);
    try rpc.checkBucketName(self.client, self.bucket);
    try rpc.checkObjectName(self.client, self.name);
    try checkUploadOptions(self.client, options);

    var checksum: ?[8]u8 = null;
    if (self.client.verify_checksums) {
        const computed = core.crc32c.hash(data);
        if (options.crc32c) |given| if (given != computed) {
            if (self.client.diagnostics) |d| d.print(
                "checksum mismatch before sending: the data hashes to {d}, options.crc32c says {d}",
                .{ computed, given },
            );
            return error.ChecksumMismatch;
        };
        checksum = core.crc32c.toBase64(computed);
    } else if (options.crc32c) |given| {
        // Verification is off, but a checksum the caller asserts still
        // travels, for the server to check.
        checksum = core.crc32c.toBase64(given);
    }

    var scratch: std.heap.ArenaAllocator = .init(self.client.gpa);
    defer scratch.deinit();
    const path = try names.uploadMultipartPath(scratch.allocator(), self.bucket);
    const parts = try multipart.build(scratch.allocator(), self.client.io, self.name, options, checksum);

    var result: types.Owned(types.ObjectInfo) = try .init(self.client.gpa);
    errdefer result.deinit();
    const res = rpc.executeStream(self.client, result.arena, .{
        .method = .POST,
        .path = path,
        .content_type = parts.content_type,
        .body = .{ .segments = &.{ parts.opening, data, parts.closing } },
        .retry = self.client.retry_unconditional_writes,
    }) catch |err| switch (err) {
        // The sink is a buffer; there is no caller writer to fail.
        error.WriteFailed => unreachable,
        else => |e| return e,
    };
    result.value = codec.decodeObject(result.arena.allocator(), res.body) catch |err|
        return rpc.decodeFailed(self.client, err, "object");
    return result;
}

fn checkUploadOptions(client: *Client, options: types.UploadOptions) Error!void {
    // The content type becomes a header line inside the multipart body.
    if (!core.transport.isValidHeaderValue(options.content_type)) {
        if (client.diagnostics) |d| d.print("invalid content type: expected a header value", .{});
        return error.InvalidArgument;
    }
    for (options.metadata) |entry| if (entry.key.len == 0) {
        if (client.diagnostics) |d| d.print("invalid metadata: keys must not be empty", .{});
        return error.InvalidArgument;
    };
}

/// Downloads the whole object into memory, at most `max_bytes` of it;
/// anything larger fails with `error.ObjectTooLarge` without being held.
/// The bytes are checked against the checksum the server sent beside them.
/// A transient failure restarts the download from the beginning.
pub fn downloadAlloc(self: Object, max_bytes: usize, options: types.DownloadOptions) Error!types.Owned(types.Downloaded) {
    rpc.begin(self.client);
    try rpc.checkBucketName(self.client, self.bucket);
    try rpc.checkObjectName(self.client, self.name);
    var scratch: std.heap.ArenaAllocator = .init(self.client.gpa);
    defer scratch.deinit();
    const path = try names.objectMediaPath(scratch.allocator(), self.bucket, self.name, options.generation);

    var result: types.Owned(types.Downloaded) = try .init(self.client.gpa);
    errdefer result.deinit();

    var attempt: u32 = 1;
    while (true) : (attempt += 1) {
        var sink: download.CappedAllocating = .init(result.arena.allocator(), max_bytes);
        const outcome = rpc.executeStream(self.client, result.arena, .{
            .method = .GET,
            .path = path,
            .sink = .{ .writer = &sink.writer },
            // This loop retries with the sink reset; the engine must not
            // repeat a request whose bytes it cannot take back.
            .retry = false,
        });
        const err: Error = if (outcome) |res| {
            result.value = try self.finishDownload(res, sink.written());
            return result;
        } else |err| switch (err) {
            error.WriteFailed => {
                if (sink.out_of_memory) return error.OutOfMemory;
                if (self.client.diagnostics) |d| d.print(
                    "the object is larger than max_bytes ({d})",
                    .{max_bytes},
                );
                return error.ObjectTooLarge;
            },
            else => |e| e,
        };
        if (attempt >= self.client.retry.max_attempts or !core.isRetryable(err)) return err;
        const delay_ms = rpc.backoffMs(self.client, attempt);
        logging.warn("GET {s} (alt=media) failed with {t}; restarting in {d} ms (attempt {d} of {d})", .{
            self.name, err, delay_ms, attempt + 1, self.client.retry.max_attempts,
        });
        _ = result.arena.reset(.retain_capacity);
        try self.client.io.sleep(.fromMilliseconds(delay_ms), .awake);
    }
}

/// Reads the headers beside a finished body and verifies the checksum.
fn finishDownload(self: Object, res: core.transport.StreamResponse, data: []const u8) Error!types.Downloaded {
    const generation: u64 = if (res.header("x-goog-generation")) |text|
        std.fmt.parseInt(u64, text, 10) catch 0
    else
        0;

    var verified = false;
    if (self.client.verify_checksums and !isTranscoded(res)) {
        if (res.header("x-goog-hash")) |value| {
            if (download.crc32cFromHashHeader(value)) |expected| {
                if (core.crc32c.hash(data) != expected) {
                    if (self.client.diagnostics) |d| d.print(
                        "checksum mismatch: {d} bytes hash to {d}, the server said {d}",
                        .{ data.len, core.crc32c.hash(data), expected },
                    );
                    return error.ChecksumMismatch;
                }
                verified = true;
            }
        }
        if (!verified) logging.warn("download of {s} carried no crc32c to verify against", .{self.name});
    }
    return .{
        .data = data,
        .result = .{
            .bytes_written = data.len,
            .generation = generation,
            .checksum_verified = verified,
        },
    };
}

/// Whether the body was decompressed on its way here. The stored checksum
/// covers the compressed bytes, so there is nothing to verify it against.
fn isTranscoded(res: core.transport.StreamResponse) bool {
    const stored = res.header("x-goog-stored-content-encoding") orelse return false;
    if (!std.ascii.eqlIgnoreCase(stored, "gzip")) return false;
    const sent = res.header("content-encoding") orelse "identity";
    return std.ascii.eqlIgnoreCase(sent, "identity");
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

test "golden: upload sends one multipart request, checksum included" {
    var h: test_util.Harness = undefined;
    try h.init(&.{.{ .respond = .{ .body =
        \\{"name":"reports/2026/q3.txt","bucket":"my-bucket","size":"12",
        \\ "generation":"7","crc32c":"8P9ykg=="}
    } }}, .{});
    defer h.deinit();
    h.clock.random_byte = 0xab;
    const data = "hello world\n";

    var info = try h.client.bucket("my-bucket").object("reports/2026/q3.txt").upload(data, .{
        .content_type = "text/plain",
    });
    defer info.deinit();
    try testing.expectEqual(12, info.value.size);
    try testing.expectEqual(0xf0ff7292, info.value.crc32c.?);

    const sent = try h.fake.streamRequest(0);
    try testing.expectEqual(.POST, sent.method);
    try testing.expectEqualStrings(
        "https://storage.googleapis.com/upload/storage/v1/b/my-bucket/o?uploadType=multipart",
        sent.url,
    );
    try testing.expectEqualStrings("multipart/related; boundary=zig_gcp_abababababababab", sent.content_type.?);
    try testing.expectEqualStrings("ya29.test-token", sent.bearer.?);
    const expected_body = "--zig_gcp_abababababababab\r\n" ++
        "Content-Type: application/json; charset=UTF-8\r\n\r\n" ++
        "{\"name\":\"reports/2026/q3.txt\",\"contentType\":\"text/plain\",\"crc32c\":\"8P9ykg==\"}" ++
        "\r\n--zig_gcp_abababababababab\r\nContent-Type: text/plain\r\n\r\n" ++
        data ++
        "\r\n--zig_gcp_abababababababab--\r\n";
    try testing.expectEqualStrings(expected_body, sent.body_prefix);
    try testing.expectEqual(expected_body.len, sent.body_len);
}

test "upload: a wrong caller checksum fails before anything is sent" {
    var h: test_util.Harness = undefined;
    try h.init(&.{.{ .respond = .{ .body = "{}" } }}, .{});
    defer h.deinit();
    const obj = h.client.bucket("my-bucket").object("a");
    try testing.expectError(error.ChecksumMismatch, obj.upload("hello world\n", .{ .crc32c = 1 }));
    try testing.expectEqual(0, h.fake.stream_requests.items.len);
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "checksum mismatch") != null);

    // The right one is simply confirmed.
    var info = try obj.upload("hello world\n", .{ .crc32c = 0xf0ff7292 });
    info.deinit();
}

test "upload: verification off sends nothing computed, but forwards an asserted checksum" {
    var h: test_util.Harness = undefined;
    try h.init(&.{ .{ .respond = .{ .body = "{}" } }, .{ .respond = .{ .body = "{}" } } }, .{
        .verify_checksums = false,
    });
    defer h.deinit();
    const obj = h.client.bucket("my-bucket").object("a");

    var plain = try obj.upload("data", .{});
    plain.deinit();
    try testing.expect(std.mem.indexOf(u8, (try h.fake.streamRequest(0)).body_prefix, "crc32c") == null);

    // An asserted checksum travels unchecked: the server is the verifier.
    var asserted = try obj.upload("data", .{ .crc32c = 1 });
    asserted.deinit();
    try testing.expect(std.mem.indexOf(u8, (try h.fake.streamRequest(1)).body_prefix, "\"crc32c\":\"AAAAAQ==\"") != null);
}

test "upload retries only when the client opted in" {
    const unavailable: test_util.FakeTransport.Reply = .{ .respond = .{ .status = 503, .body = "{}" } };
    var h: test_util.Harness = undefined;
    try h.init(&.{unavailable}, .{ .retry = .{ .max_attempts = 3, .initial_backoff_ms = 1 } });
    defer h.deinit();
    try testing.expectError(error.Unavailable, h.client.bucket("b").object("a").upload("data", .{}));
    try testing.expectEqual(1, h.fake.stream_requests.items.len);

    var opted: test_util.Harness = undefined;
    try opted.init(&.{ unavailable, .{ .respond = .{ .body = "{}" } } }, .{
        .retry = .{ .max_attempts = 3, .initial_backoff_ms = 1 },
        .retry_unconditional_writes = true,
    });
    defer opted.deinit();
    var info = try opted.client.bucket("b").object("a").upload("data", .{});
    info.deinit();
    try testing.expectEqual(2, opted.fake.stream_requests.items.len);
}

test "upload refuses options that cannot travel" {
    var h: test_util.Harness = undefined;
    try h.init(&.{}, .{});
    defer h.deinit();
    const obj = h.client.bucket("b").object("a");
    try testing.expectError(error.InvalidArgument, obj.upload("d", .{ .content_type = "text/plain\r\nX: y" }));
    try testing.expectError(error.InvalidArgument, obj.upload("d", .{ .metadata = &.{.{ .key = "", .value = "v" }} }));
    try testing.expectEqual(0, h.fake.stream_requests.items.len);
}

test "golden: downloadAlloc verifies the checksum and reads the headers" {
    var h: test_util.Harness = undefined;
    try h.init(&.{.{ .respond = .{
        .body = "hello world\n",
        .headers = &.{
            .{ .name = "x-goog-hash", .value = "crc32c=8P9ykg==,md5=b1kCrCNwJL3QwXbLkwY9xA==" },
            .{ .name = "x-goog-generation", .value = "1758448800123456" },
        },
    } }}, .{});
    defer h.deinit();

    var got = try h.client.bucket("my-bucket").object("reports/2026/q3.txt").downloadAlloc(1024, .{});
    defer got.deinit();
    try testing.expectEqualStrings("hello world\n", got.value.data);
    try testing.expectEqual(12, got.value.result.bytes_written);
    try testing.expectEqual(1758448800123456, got.value.result.generation);
    try testing.expect(got.value.result.checksum_verified);

    const sent = try h.fake.streamRequest(0);
    try testing.expectEqual(.GET, sent.method);
    try testing.expectEqualStrings(
        "https://storage.googleapis.com/storage/v1/b/my-bucket/o/reports%2F2026%2Fq3.txt?alt=media",
        sent.url,
    );
    try testing.expectEqual(.writer, sent.sink);
}

test "downloadAlloc: a checksum mismatch discards the data" {
    var h: test_util.Harness = undefined;
    try h.init(&.{.{ .respond = .{
        .body = "hello worls\n",
        .headers = &.{.{ .name = "x-goog-hash", .value = "crc32c=8P9ykg==" }},
    } }}, .{});
    defer h.deinit();
    try testing.expectError(
        error.ChecksumMismatch,
        h.client.bucket("b").object("a").downloadAlloc(1024, .{}),
    );
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "checksum mismatch") != null);
}

test "downloadAlloc: no checksum to check, or checking turned off, is not verified" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = "hello world\n" } },
        // The transcoded case: the stored checksum covers compressed bytes
        // that are not what arrived, so even a header is not verifiable.
        .{ .respond = .{ .body = "hello world\n", .headers = &.{
            .{ .name = "x-goog-hash", .value = "crc32c=AAAAAQ==" },
            .{ .name = "x-goog-stored-content-encoding", .value = "gzip" },
        } } },
    }, .{});
    defer h.deinit();
    const obj = h.client.bucket("b").object("a");

    var bare = try obj.downloadAlloc(1024, .{});
    defer bare.deinit();
    try testing.expect(!bare.value.result.checksum_verified);
    try testing.expectEqual(0, bare.value.result.generation);

    var transcoded = try obj.downloadAlloc(1024, .{});
    defer transcoded.deinit();
    try testing.expect(!transcoded.value.result.checksum_verified);
    try testing.expectEqualStrings("hello world\n", transcoded.value.data);
}

test "downloadAlloc: an object above max_bytes is ObjectTooLarge" {
    var h: test_util.Harness = undefined;
    try h.init(&.{.{ .respond = .{ .body = "hello world\n" } }}, .{});
    defer h.deinit();
    try testing.expectError(
        error.ObjectTooLarge,
        h.client.bucket("b").object("a").downloadAlloc(11, .{}),
    );
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "larger than max_bytes") != null);

    // At the boundary it fits exactly.
    var at_cap: test_util.Harness = undefined;
    try at_cap.init(&.{.{ .respond = .{ .body = "hello world\n" } }}, .{});
    defer at_cap.deinit();
    var got = try at_cap.client.bucket("b").object("a").downloadAlloc(12, .{});
    defer got.deinit();
    try testing.expectEqualStrings("hello world\n", got.value.data);
}

test "downloadAlloc restarts cleanly after a cut connection and after a 503" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        // Five bytes arrive, then the connection drops.
        .{ .respond = .{ .body = "hello world\n", .cut_after = 5 } },
        // The retry runs into a 503.
        .{ .respond = .{ .status = 503, .body = "{}" } },
        // The third attempt delivers the whole object.
        .{ .respond = .{
            .body = "hello world\n",
            .headers = &.{.{ .name = "x-goog-hash", .value = "crc32c=8P9ykg==" }},
        } },
    }, .{ .retry = .{ .max_attempts = 3, .initial_backoff_ms = 1 } });
    defer h.deinit();

    var got = try h.client.bucket("b").object("a").downloadAlloc(1024, .{});
    defer got.deinit();
    // No bytes from the failed attempts leaked into the result.
    try testing.expectEqualStrings("hello world\n", got.value.data);
    try testing.expect(got.value.result.checksum_verified);
    try testing.expectEqual(3, h.fake.stream_requests.items.len);
    try testing.expectEqual(2, h.clock.sleep_count);
}

test "downloadAlloc: a zero-byte object verifies against the empty checksum" {
    var h: test_util.Harness = undefined;
    try h.init(&.{.{ .respond = .{
        .body = "",
        .headers = &.{.{ .name = "x-goog-hash", .value = "crc32c=AAAAAA==" }},
    } }}, .{});
    defer h.deinit();
    var got = try h.client.bucket("b").object("empty").downloadAlloc(1024, .{});
    defer got.deinit();
    try testing.expectEqual(0, got.value.data.len);
    try testing.expect(got.value.result.checksum_verified);
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
