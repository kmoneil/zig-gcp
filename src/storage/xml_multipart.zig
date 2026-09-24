//! The XML API's multipart upload, one request at a time: start an upload
//! and get its id, send numbered parts in any order, finish by listing
//! them, or abort. The parts are never objects: nothing is visible until
//! the finish, the finish or an abort drops every part, and none of them is
//! kept by soft delete.
//!
//! What Google documents, and this file relies on:
//! - 1 to 10,000 parts of 5 MiB to 5 GiB, the last exempt from the minimum,
//!   for objects up to 5 TiB. The minimum is enforced only at the finish.
//! - Sending a part number again replaces that part.
//! - "Preconditions are not supported in the requests."
//! - The finish's answer carries `x-goog-hash` with the whole object's
//!   CRC32C, and the object has no MD5. Finishing "can take several
//!   minutes".
//! - A finish or part for an upload that is gone, finished or aborted,
//!   answers 404 `NoSuchUpload`.
//! - Errors are XML: `<Error><Code/><Message/></Error>`.
//!
//! The upload id is not a credential: every request that names it still
//! carries the client's token.

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("core");

const Client = @import("Client.zig");
const dl = @import("download.zig");
const names = @import("names.zig");
const rpc = @import("rpc.zig");
const types = @import("types.zig");
const xml = @import("xml.zig");
const Error = @import("errors.zig").Error;

pub const max_parts = 10_000;
pub const min_part_size: u64 = 5 * 1024 * 1024;
pub const max_part_size: u64 = 5 * 1024 * 1024 * 1024;
pub const max_object_size: u64 = 5 * 1024 * 1024 * 1024 * 1024;

/// How an object splits into parts: every part `part_size` bytes but the
/// last, which holds the rest.
pub const Plan = struct {
    part_size: u64,
    parts: u32,
    size: u64,

    /// Where part `index`, from 0, starts.
    pub fn offset(self: Plan, index: u32) u64 {
        return @as(u64, index) * self.part_size;
    }

    /// How many bytes part `index`, from 0, holds.
    pub fn len(self: Plan, index: u32) u64 {
        return @min(self.part_size, self.size - self.offset(index));
    }
};

/// The parts `size` bytes split into at `part_size`, which grows as needed
/// so there are never more than 10,000. An empty object is one empty part,
/// which the last part's exemption allows. `size` is at most 5 TiB and
/// `part_size` at least 1.
pub fn plan(size: u64, part_size: u64) Plan {
    std.debug.assert(part_size > 0 and size <= max_object_size);
    const each = @max(part_size, std.math.divCeil(u64, size, max_parts) catch unreachable);
    const parts = if (size == 0) 1 else std.math.divCeil(u64, size, each) catch unreachable;
    return .{ .part_size = each, .parts = @intCast(parts), .size = size };
}

/// What the start sets on the object to be, as headers: this is the one
/// request that can. Every value is already a valid header value, and every
/// key a valid header name after `x-goog-meta-`.
pub const Start = struct {
    content_type: []const u8,
    cache_control: ?[]const u8 = null,
    content_disposition: ?[]const u8 = null,
    content_encoding: ?[]const u8 = null,
    content_language: ?[]const u8 = null,
    metadata: []const types.Metadata = &.{},
};

/// Starts an upload of `object` and returns its id, which lives in
/// `arena`. Retried like a read: a repeat after a lost answer leaves behind
/// an empty upload, which holds no part and costs nothing.
pub fn start(client: *Client, arena: Allocator, bucket: []const u8, object: []const u8, meta: Start) Error![]const u8 {
    var scratch: std.heap.ArenaAllocator = .init(client.gpa);
    defer scratch.deinit();
    const path = try names.xmlPath(scratch.allocator(), bucket, object, .uploads);
    const headers = try startHeaders(scratch.allocator(), meta);
    // Reset between attempts, so it holds nothing but the answer.
    var response: std.heap.ArenaAllocator = .init(client.gpa);
    defer response.deinit();
    const res = rpc.executeStream(client, &response, .{
        .method = .POST,
        .path = path,
        .content_type = meta.content_type,
        .headers = headers,
        // Content-Length: 0, which the start needs.
        .body = .{ .segments = &.{} },
        .decode_error = xml.decodeError,
    }) catch |err| switch (err) {
        // The sink is a buffer; there is no caller writer to fail.
        error.WriteFailed => unreachable,
        else => |e| return e,
    };
    const root = xml.parse(arena, res.body) catch |err| return decodeFailed(client, err, "start");
    if (!std.mem.eql(u8, root.name, "InitiateMultipartUploadResult")) return decodeFailed(client, error.InvalidResponse, "start");
    const id = root.childText("UploadId") orelse "";
    if (id.len == 0) {
        if (client.diagnostics) |d| d.print("the start's answer named no upload id", .{});
        return error.InvalidResponse;
    }
    return id;
}

fn startHeaders(arena: Allocator, meta: Start) Allocator.Error![]const core.transport.Header {
    var headers: std.ArrayList(core.transport.Header) = .empty;
    const fixed = [_]struct { []const u8, ?[]const u8 }{
        .{ "Cache-Control", meta.cache_control },
        .{ "Content-Disposition", meta.content_disposition },
        .{ "Content-Encoding", meta.content_encoding },
        .{ "Content-Language", meta.content_language },
    };
    for (fixed) |field| if (field[1]) |value| try headers.append(arena, .{ .name = field[0], .value = value });
    for (meta.metadata) |entry| try headers.append(arena, .{
        .name = try std.fmt.allocPrint(arena, "x-goog-meta-{s}", .{entry.key}),
        .value = entry.value,
    });
    return headers.items;
}

/// Where a part's bytes come from.
pub const PartBody = union(enum) {
    /// In memory, so a transient failure is retried from the same bytes.
    bytes: []const u8,
    /// Read once from a stream: a transient failure comes back, for the
    /// caller to send the part again with a fresh reader.
    stream: core.rpc.StreamBody,
};

/// What Cloud Storage said about a part it stored.
pub const SentPart = struct {
    /// As the answer sent it, quotes and all, in the caller's arena: the
    /// finish names the part by it.
    etag: []const u8,
    /// The CRC32C stored for the part, from `x-goog-hash`, or null when the
    /// answer named none.
    crc32c: ?u32,
};

/// Sends part `number`, from 1, of an upload.
pub fn sendPart(
    client: *Client,
    arena: Allocator,
    bucket: []const u8,
    object: []const u8,
    upload_id: []const u8,
    number: u32,
    body: PartBody,
) Error!SentPart {
    var scratch: std.heap.ArenaAllocator = .init(client.gpa);
    defer scratch.deinit();
    const path = try names.xmlPath(scratch.allocator(), bucket, object, .{ .part = .{ .number = number, .upload_id = upload_id } });
    const call: rpc.StreamCall = .{ .method = .PUT, .path = path, .decode_error = xml.decodeError };
    var response: std.heap.ArenaAllocator = .init(client.gpa);
    defer response.deinit();
    const res = switch (body) {
        .bytes => |bytes| rpc.executeStream(client, &response, s: {
            var with_body = call;
            with_body.body = .{ .segments = &.{bytes} };
            break :s with_body;
        }) catch |err| switch (err) {
            error.WriteFailed => unreachable,
            else => |e| return e,
        },
        .stream => |source| rpc.executeStreamBody(client, &response, call, source) catch |err| switch (err) {
            error.WriteFailed => unreachable,
            error.EndOfStream => {
                if (client.diagnostics) |d| d.print("the source ended before part {d} did", .{number});
                return error.UnexpectedEndOfStream;
            },
            else => |e| return e,
        },
    };
    const etag = res.header("ETag") orelse {
        if (client.diagnostics) |d| d.print("the answer to part {d} named no ETag", .{number});
        return error.InvalidResponse;
    };
    return .{
        .etag = try arena.dupe(u8, etag),
        .crc32c = if (res.header("x-goog-hash")) |value| dl.crc32cFromHashHeader(value) else null,
    };
}

/// What the finish's answer said about the object it made.
pub const Finished = struct {
    /// The whole object's CRC32C, from `x-goog-hash`, or null when the
    /// answer named none.
    crc32c: ?u32,
    /// The object's generation, when the answer names one in
    /// `x-goog-generation`, which Google does not document.
    generation: ?u64,
};

/// Finishes an upload from `parts`, which must be every part, ascending.
/// `timeout_ms` bounds each attempt: Google says finishing "can take
/// several minutes". Retried: a finish that landed and lost its answer
/// cannot land twice, since the repeat finds no upload and answers 404
/// `NoSuchUpload`, which the caller resolves by reading the object back.
pub fn finish(
    client: *Client,
    bucket: []const u8,
    object: []const u8,
    upload_id: []const u8,
    parts: []const xml.CompletedPart,
    timeout_ms: u32,
) Error!Finished {
    var scratch: std.heap.ArenaAllocator = .init(client.gpa);
    defer scratch.deinit();
    const path = try names.xmlPath(scratch.allocator(), bucket, object, .{ .upload = upload_id });
    const body = try xml.encodeComplete(scratch.allocator(), parts);
    var response: std.heap.ArenaAllocator = .init(client.gpa);
    defer response.deinit();
    const res = rpc.executeStream(client, &response, .{
        .method = .POST,
        .path = path,
        .content_type = "application/xml",
        .body = .{ .segments = &.{body} },
        .timeout_ms = timeout_ms,
        .decode_error = xml.decodeError,
    }) catch |err| switch (err) {
        error.WriteFailed => unreachable,
        else => |e| return e,
    };
    const root = xml.parse(scratch.allocator(), res.body) catch |err| return decodeFailed(client, err, "finish");
    // A long request can answer 200 before it is done and report failure
    // in the body, as Amazon S3 documents for this same request.
    if (std.mem.eql(u8, root.name, "Error")) {
        const code = root.childText("Code") orelse "";
        if (client.diagnostics) |d| d.set(res.status, code, root.childText("Message") orelse "");
        return errorForCode(code);
    }
    if (!std.mem.eql(u8, root.name, "CompleteMultipartUploadResult")) return decodeFailed(client, error.InvalidResponse, "finish");
    return .{
        .crc32c = if (res.header("x-goog-hash")) |value| dl.crc32cFromHashHeader(value) else null,
        .generation = if (res.header("x-goog-generation")) |text| std.fmt.parseInt(u64, text, 10) catch null else null,
    };
}

/// The error an `<Error>` in a 200 names, by its code: a code that says
/// try again becomes an error `core.isRetryable` agrees with.
fn errorForCode(code: []const u8) Error {
    const table = [_]struct { []const u8, Error }{
        .{ "InternalError", error.Internal },
        .{ "ServiceUnavailable", error.Unavailable },
        .{ "SlowDown", error.ResourceExhausted },
        .{ "RequestTimeout", error.DeadlineExceeded },
        .{ "NoSuchUpload", error.NotFound },
        .{ "NoSuchKey", error.NotFound },
        .{ "AccessDenied", error.PermissionDenied },
        .{ "InvalidPart", error.InvalidArgument },
        .{ "InvalidPartOrder", error.InvalidArgument },
        .{ "InvalidArgument", error.InvalidArgument },
        .{ "EntityTooSmall", error.InvalidArgument },
        .{ "EntityTooLarge", error.InvalidArgument },
        .{ "PreconditionFailed", error.FailedPrecondition },
    };
    for (table) |entry| if (std.mem.eql(u8, code, entry[0])) return entry[1];
    return error.Unknown;
}

/// Aborts an upload, which drops every part it holds. An upload that is
/// already gone, finished, aborted or never started, counts as aborted.
pub fn abort(client: *Client, bucket: []const u8, object: []const u8, upload_id: []const u8) Error!void {
    var scratch: std.heap.ArenaAllocator = .init(client.gpa);
    defer scratch.deinit();
    const path = try names.xmlPath(scratch.allocator(), bucket, object, .{ .upload = upload_id });
    var response: std.heap.ArenaAllocator = .init(client.gpa);
    defer response.deinit();
    _ = rpc.executeStream(client, &response, .{
        .method = .DELETE,
        .path = path,
        .decode_error = xml.decodeError,
    }) catch |err| switch (err) {
        error.WriteFailed => unreachable,
        error.NotFound => {
            if (client.diagnostics) |d| d.clear();
            return;
        },
        else => |e| return e,
    };
}

/// Whether the last failure was Cloud Storage saying the upload is gone.
pub fn uploadIsGone(client: *const Client, err: Error) bool {
    if (err != error.NotFound) return false;
    const d = client.diagnostics orelse return false;
    return std.mem.eql(u8, d.status(), "NoSuchUpload");
}

fn decodeFailed(client: *Client, err: xml.DecodeError, what: []const u8) Error {
    if (err == error.InvalidResponse) {
        if (client.diagnostics) |d| d.print("the {s}'s answer could not be decoded", .{what});
    }
    return err;
}

const testing = std.testing;
const test_util = @import("test_util.zig");

const start_answer =
    \\<?xml version='1.0' encoding='UTF-8'?>
    \\<InitiateMultipartUploadResult xmlns='http://s3.amazonaws.com/doc/2006-03-01/'>
    \\<Bucket>b</Bucket><Key>dir/a b.bin</Key><UploadId>VXBs+b2Fk=</UploadId>
    \\</InitiateMultipartUploadResult>
;

const no_such_upload: test_util.FakeTransport.Reply = .{ .respond = .{
    .status = 404,
    .body = "<?xml version='1.0' encoding='UTF-8'?><Error><Code>NoSuchUpload</Code><Message>The requested upload was not found.</Message></Error>",
} };

test "plan: every boundary, and the part size grown to fit 10,000 parts" {
    const mib: u64 = 1024 * 1024;
    const cases = [_]struct { size: u64, part_size: u64, want_size: u64, want_parts: u32, last: u64 }{
        .{ .size = 0, .part_size = 32 * mib, .want_size = 32 * mib, .want_parts = 1, .last = 0 },
        .{ .size = 1, .part_size = 32 * mib, .want_size = 32 * mib, .want_parts = 1, .last = 1 },
        .{ .size = 32 * mib, .part_size = 32 * mib, .want_size = 32 * mib, .want_parts = 1, .last = 32 * mib },
        .{ .size = 32 * mib + 1, .part_size = 32 * mib, .want_size = 32 * mib, .want_parts = 2, .last = 1 },
        .{ .size = 5 * 1024 * mib, .part_size = 32 * mib, .want_size = 32 * mib, .want_parts = 160, .last = 32 * mib },
        // 10,000 parts exactly, then one byte more grows every part by one.
        .{ .size = 10_000 * 5 * mib, .part_size = 5 * mib, .want_size = 5 * mib, .want_parts = 10_000, .last = 5 * mib },
        .{ .size = 10_000 * 5 * mib + 1, .part_size = 5 * mib, .want_size = 5 * mib + 1, .want_parts = 10_000, .last = 5 * mib - 9_998 },
        // The largest object: just over 524 MiB a part.
        .{ .size = max_object_size, .part_size = 32 * mib, .want_size = 549_755_814, .want_parts = 10_000, .last = 549_755_814 - 1_120 },
    };
    for (cases) |case| {
        errdefer std.debug.print("size {d}, part size {d}\n", .{ case.size, case.part_size });
        const p = plan(case.size, case.part_size);
        try testing.expectEqual(case.want_size, p.part_size);
        try testing.expectEqual(case.want_parts, p.parts);
        try testing.expectEqual(case.last, p.len(p.parts - 1));
    }
}

fn planProperty(_: void, input: []const u8) !void {
    var g: test_util.ByteGen = .init(input);
    const size = g.intRange(u64, 0, max_object_size);
    const part_size = g.intRange(u64, min_part_size, max_part_size);
    const p = plan(size, part_size);
    // At most 10,000 parts, never smaller than asked, every one within the
    // limits, together exactly the object, and no empty part but an empty
    // object's.
    try testing.expect(p.parts >= 1 and p.parts <= max_parts);
    try testing.expect(p.part_size >= part_size and p.part_size <= max_part_size);
    // Parts are back to back from 0, so they cover the object exactly, with
    // every one but the last whole, when the last starts inside the object
    // and ends at its end.
    const last = p.parts - 1;
    try testing.expectEqual(@as(u64, last) * p.part_size, p.offset(last));
    try testing.expect(p.offset(last) < size or size == 0);
    try testing.expectEqual(size, p.offset(last) + p.len(last));
    try testing.expect(p.len(last) <= p.part_size);
    try testing.expect(p.len(last) > 0 or size == 0);
    if (p.parts > 1) try testing.expectEqual(p.part_size, p.len(last - 1));
}

test "fuzz multipart: a plan covers the object exactly, within Google's limits" {
    try test_util.fuzzBytes({}, planProperty, .{ .corpus = &.{
        "",
        "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00",
        "\xff\xff\xff\xff\xff\xff\xff\xff\x00\x00\x00\x00\x00\x00\x00\x00",
    } });
}

test "start: the metadata as headers, and the id from the answer" {
    var h: test_util.Harness = undefined;
    try h.init(&.{.{ .respond = .{ .body = start_answer } }}, .{});
    defer h.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const id = try start(&h.client, arena.allocator(), "b", "dir/a b.bin", .{
        .content_type = "application/x-tar",
        .cache_control = "no-cache",
        .content_language = "en",
        .metadata = &.{ .{ .key = "origin", .value = "zig" }, .{ .key = "run", .value = "7" } },
    });
    try testing.expectEqualStrings("VXBs+b2Fk=", id);

    const sent = try h.fake.streamRequest(0);
    try testing.expectEqual(.POST, sent.method);
    try testing.expectEqualStrings("https://storage.googleapis.com/b/dir/a%20b.bin?uploads", sent.url);
    try testing.expectEqualStrings("application/x-tar", sent.content_type.?);
    try testing.expectEqual(.segments, sent.body_tag);
    try testing.expectEqual(0, sent.body_len);
    try testing.expectEqualStrings("no-cache", sent.header("Cache-Control").?);
    try testing.expectEqualStrings("en", sent.header("Content-Language").?);
    try testing.expectEqual(null, sent.header("Content-Disposition"));
    try testing.expectEqualStrings("zig", sent.header("x-goog-meta-origin").?);
    try testing.expectEqualStrings("7", sent.header("x-goog-meta-run").?);
    try testing.expectEqualStrings("ya29.test-token", sent.bearer.?);
}

test "start: answers that name no upload" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = "<InitiateMultipartUploadResult><Bucket>b</Bucket></InitiateMultipartUploadResult>" } },
        .{ .respond = .{ .body = "<Other><UploadId>x</UploadId></Other>" } },
        .{ .respond = .{ .body = "{\"not\":\"xml\"}" } },
        .{ .respond = .{ .status = 403, .body = "<Error><Code>AccessDenied</Code><Message>no storage.multipartUploads.create</Message></Error>" } },
    }, .{});
    defer h.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.InvalidResponse, start(&h.client, arena.allocator(), "b", "o", .{ .content_type = "x/y" }));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "no upload id") != null);
    try testing.expectError(error.InvalidResponse, start(&h.client, arena.allocator(), "b", "o", .{ .content_type = "x/y" }));
    try testing.expectError(error.InvalidResponse, start(&h.client, arena.allocator(), "b", "o", .{ .content_type = "x/y" }));
    // An XML error fills the diagnostics as a JSON one would.
    try testing.expectError(error.PermissionDenied, start(&h.client, arena.allocator(), "b", "o", .{ .content_type = "x/y" }));
    try testing.expectEqualStrings("AccessDenied", h.diag.status());
    try testing.expectEqualStrings("no storage.multipartUploads.create", h.diag.message());
}

test "sendPart: bytes, their ETag and their checksum" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .status = 503, .body = "<Error><Code>ServiceUnavailable</Code></Error>" } },
        .{ .respond = .{ .body = "", .headers = &.{
            .{ .name = "ETag", .value = "\"b1946ac92492d2347c6235b4d2611184\"" },
            .{ .name = "x-goog-hash", .value = "crc32c=8P9ykg==,md5=sT05+MdkzfuP6t2scCrajg==" },
        } } },
    }, .{ .retry = .{ .max_attempts = 3, .initial_backoff_ms = 1 } });
    defer h.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const sent = try sendPart(&h.client, arena.allocator(), "b", "dir/a b.bin", "VXBs+b2Fk=", 3, .{ .bytes = "hello world\n" });
    try testing.expectEqualStrings("\"b1946ac92492d2347c6235b4d2611184\"", sent.etag);
    try testing.expectEqual(0xf0ff_7292, sent.crc32c.?);
    // Bytes in memory are retried from the same bytes.
    try testing.expectEqual(2, h.fake.stream_requests.items.len);
    const req = try h.fake.streamRequest(1);
    try testing.expectEqual(.PUT, req.method);
    try testing.expectEqualStrings("https://storage.googleapis.com/b/dir/a%20b.bin?partNumber=3&uploadId=VXBs%2Bb2Fk%3D", req.url);
    try testing.expectEqualStrings("hello world\n", req.body_prefix);
    try testing.expectEqual(null, req.content_type);
}

test "sendPart: a stream goes once, and a short one is UnexpectedEndOfStream" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .status = 503, .body = "" } },
        .{ .respond = .{ .body = "", .headers = &.{.{ .name = "ETag", .value = "\"e\"" }} } },
    }, .{ .retry = .{ .max_attempts = 3, .initial_backoff_ms = 1 } });
    defer h.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var first: std.Io.Reader = .fixed("abcd");
    // One attempt: the reader cannot go back, so the caller retries.
    try testing.expectError(error.Unavailable, sendPart(&h.client, arena.allocator(), "b", "o", "u", 1, .{ .stream = .{ .reader = &first, .len = 4 } }));
    try testing.expectEqual(1, h.fake.stream_requests.items.len);
    var second: std.Io.Reader = .fixed("abcd");
    const sent = try sendPart(&h.client, arena.allocator(), "b", "o", "u", 1, .{ .stream = .{ .reader = &second, .len = 4 } });
    try testing.expectEqualStrings("\"e\"", sent.etag);
    // No x-goog-hash, no checksum.
    try testing.expectEqual(null, sent.crc32c);
    var short: std.Io.Reader = .fixed("ab");
    try testing.expectError(error.UnexpectedEndOfStream, sendPart(&h.client, arena.allocator(), "b", "o", "u", 2, .{ .stream = .{ .reader = &short, .len = 4 } }));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "part 2") != null);
}

test "sendPart: an answer with no ETag, and an upload that is gone" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = "" } },
        .{ .respond = .{ .status = 404, .body = "<Error><Code>NoSuchBucket</Code></Error>" } },
        no_such_upload,
    }, .{});
    defer h.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.InvalidResponse, sendPart(&h.client, arena.allocator(), "b", "o", "u", 1, .{ .bytes = "x" }));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "no ETag") != null);
    // A 404 about something else is not the upload going away.
    try testing.expectError(error.NotFound, sendPart(&h.client, arena.allocator(), "b", "o", "u", 1, .{ .bytes = "x" }));
    try testing.expect(!uploadIsGone(&h.client, error.NotFound));
    const err = sendPart(&h.client, arena.allocator(), "b", "o", "u", 1, .{ .bytes = "x" });
    try testing.expectError(error.NotFound, err);
    try testing.expect(uploadIsGone(&h.client, error.NotFound));
    try testing.expect(!uploadIsGone(&h.client, error.Unavailable));
}

test "finish: the part list, its own timeout, and what the answer says" {
    var h: test_util.Harness = undefined;
    try h.init(&.{.{ .respond = .{
        .body = "<?xml version='1.0' encoding='UTF-8'?><CompleteMultipartUploadResult><Location>l</Location><ETag>\"x-2\"</ETag></CompleteMultipartUploadResult>",
        .headers = &.{
            .{ .name = "x-goog-hash", .value = "crc32c=8P9ykg==" },
            .{ .name = "x-goog-generation", .value = "1758448800123456" },
        },
    } }}, .{});
    defer h.deinit();
    const done = try finish(&h.client, "b", "o", "u+1", &.{
        .{ .number = 1, .etag = "\"a\"" },
        .{ .number = 2, .etag = "\"b\"" },
    }, 600_000);
    try testing.expectEqual(0xf0ff_7292, done.crc32c.?);
    try testing.expectEqual(1758448800123456, done.generation.?);
    const req = try h.fake.streamRequest(0);
    try testing.expectEqual(.POST, req.method);
    try testing.expectEqualStrings("https://storage.googleapis.com/b/o?uploadId=u%2B1", req.url);
    try testing.expectEqualStrings("application/xml", req.content_type.?);
    try testing.expectEqualStrings(
        "<CompleteMultipartUpload><Part><PartNumber>1</PartNumber><ETag>\"a\"</ETag></Part>" ++
            "<Part><PartNumber>2</PartNumber><ETag>\"b\"</ETag></Part></CompleteMultipartUpload>",
        req.body_prefix,
    );
    try testing.expectEqual(600_000, req.timeout_ms);
}

test "finish: a 200 that carries an error, one that carries nothing, and a gone upload" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = "<Error><Code>InternalError</Code><Message>We encountered an internal error. Please try again.</Message></Error>" } },
        .{ .respond = .{ .body = "<Error><Code>SomethingNew</Code></Error>" } },
        .{ .respond = .{ .body = "<CompleteMultipartUploadResult/>" } },
        .{ .respond = .{ .body = "" } },
        no_such_upload,
    }, .{});
    defer h.deinit();
    const parts = [_]xml.CompletedPart{.{ .number = 1, .etag = "\"a\"" }};
    try testing.expectError(error.Internal, finish(&h.client, "b", "o", "u", &parts, 0));
    try testing.expectEqualStrings("InternalError", h.diag.status());
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "try again") != null);
    try testing.expectError(error.Unknown, finish(&h.client, "b", "o", "u", &parts, 0));
    // No checksum and no generation named: both null, for the caller to judge.
    const bare = try finish(&h.client, "b", "o", "u", &parts, 0);
    try testing.expectEqual(null, bare.crc32c);
    try testing.expectEqual(null, bare.generation);
    try testing.expectError(error.InvalidResponse, finish(&h.client, "b", "o", "u", &parts, 0));
    try testing.expectError(error.NotFound, finish(&h.client, "b", "o", "u", &parts, 0));
    try testing.expect(uploadIsGone(&h.client, error.NotFound));
}

test "abort: DELETE, and an upload already gone counts as aborted" {
    var h: test_util.Harness = undefined;
    try h.init(&.{ .{ .respond = .{ .status = 204, .body = "" } }, no_such_upload, .{ .respond = .{ .status = 403, .body = "<Error><Code>AccessDenied</Code></Error>" } } }, .{});
    defer h.deinit();
    try abort(&h.client, "b", "dir/o", "u");
    const req = try h.fake.streamRequest(0);
    try testing.expectEqual(.DELETE, req.method);
    try testing.expectEqualStrings("https://storage.googleapis.com/b/dir/o?uploadId=u", req.url);
    try abort(&h.client, "b", "dir/o", "u");
    try testing.expectEqual(0, h.diag.http_status);
    try testing.expectError(error.PermissionDenied, abort(&h.client, "b", "dir/o", "u"));
}

fn everyRequest(gpa: Allocator) !void {
    // Built by hand rather than through `Harness`, whose `deinit` frees
    // both halves: here the transport must outlive a client that may
    // never have been built.
    var fake: test_util.FakeTransport = .init(gpa, &.{
        .{ .respond = .{ .body = start_answer } },
        .{ .respond = .{ .body = "", .headers = &.{
            .{ .name = "ETag", .value = "\"e\"" },
            .{ .name = "x-goog-hash", .value = "crc32c=8P9ykg==" },
        } } },
        .{ .respond = .{ .body = "<CompleteMultipartUploadResult><ETag>x</ETag></CompleteMultipartUploadResult>" } },
        .{ .respond = .{ .status = 204, .body = "" } },
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
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const id = try start(&client, arena.allocator(), "b", "o", .{
        .content_type = "x/y",
        .metadata = &.{.{ .key = "k", .value = "v" }},
    });
    const part = try sendPart(&client, arena.allocator(), "b", "o", id, 1, .{ .bytes = "hello world\n" });
    _ = try finish(&client, "b", "o", id, &.{.{ .number = 1, .etag = part.etag }}, 0);
    try abort(&client, "b", "o", id);
}

test "multipart requests: every allocation failure is OutOfMemory, and nothing leaks" {
    try testing.checkAllAllocationFailures(testing.allocator, everyRequest, .{});
}
