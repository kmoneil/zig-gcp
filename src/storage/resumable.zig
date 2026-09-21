//! The resumable upload state machine: open a session, send chunks, and
//! recover. Every chunk except the last is a multiple of 256 KiB; the
//! answer to a non-final chunk is a 308 whose `Range` header says how much
//! the server kept, which is never assumed to be everything sent. After a
//! transient failure a status query asks where the server is, and sending
//! resumes there. A dead session (404 or 410) restarts a `slice` source
//! from its bytes and fails a `reader` source with
//! `error.UploadSessionLost`, since its bytes are gone.
//!
//! The session URI is a credential: anyone holding it can write the
//! object. It is never logged and never placed in `Diagnostics`, and
//! requests to it carry no Authorization header; the URI itself is the
//! authorization.

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("core");

const Client = @import("Client.zig");
const codec = @import("codec.zig");
const errors = @import("errors.zig");
const logging = @import("logging.zig");
const names = @import("names.zig");
const rpc = @import("rpc.zig");
const types = @import("types.zig");
const Error = errors.Error;

/// Where the bytes come from.
pub const Source = union(enum) {
    /// The whole object in memory: chunks are slices of it, nothing is
    /// buffered, and a lost session starts over from the same bytes.
    slice: []const u8,
    /// A stream: one chunk lives in `buffer` until the server confirms it,
    /// so a resume never needs the reader to go backwards.
    reader: Reader,

    pub const Reader = struct {
        r: *std.Io.Reader,
        /// `chunk_size` bytes, owned by the caller.
        buffer: []u8,
        /// The declared total, or null when unknown.
        declared: ?u64,
        /// Fed every byte read, for the caller's post-upload verification.
        hasher: ?*core.crc32c.Hasher = null,
    };
};

/// Runs one upload to completion and decodes the final Object resource.
/// `metadata_crc` is the checksum the session's metadata claims, or null.
pub fn run(
    client: *Client,
    bucket_name: []const u8,
    object_name: []const u8,
    source: Source,
    options: types.UploadOptions,
    metadata_crc: ?[8]u8,
) Error!types.Owned(types.ObjectInfo) {
    var scratch: std.heap.ArenaAllocator = .init(client.gpa);
    defer scratch.deinit();

    var restarts: u32 = 0;
    while (true) {
        var machine: Machine = .{
            .client = client,
            .source = source,
            .total = switch (source) {
                .slice => |data| data.len,
                .reader => |r| r.declared,
            },
        };
        const outcome = machine.upload(&scratch, bucket_name, object_name, options, metadata_crc);
        const err = if (outcome) |result| return result else |err| err;
        if (err != error.UploadSessionLost or source != .slice) return err;
        // The bytes are still in memory: a lost session costs a restart,
        // not the upload. Bounded like any other retry.
        restarts += 1;
        if (restarts >= client.retry.max_attempts) return err;
        const delay_ms = rpc.backoffMs(client, restarts);
        logging.warn("resumable upload of {s}: the session was lost; starting over in {d} ms", .{ object_name, delay_ms });
        try client.io.sleep(.fromMilliseconds(delay_ms), .awake);
        _ = scratch.reset(.retain_capacity);
    }
}

const Machine = struct {
    client: *Client,
    source: Source,
    /// Bytes the server has confirmed.
    confirmed: u64 = 0,
    /// Known up front, or discovered when a reader ends.
    total: ?u64,
    /// The buffered chunk's first byte offset (reader sources).
    chunk_start: u64 = 0,
    /// Bytes of the buffered chunk (reader sources).
    chunk_len: usize = 0,
    /// Whether the reader has ended.
    eof: bool = false,

    /// One exchange with the session URI, classified.
    const Exchange = union(enum) {
        /// 200 or 201: the final Object resource.
        done: core.transport.StreamResponse,
        /// 308: bytes stored so far.
        stored: u64,
        /// 404 or 410: the session is gone.
        lost,
        /// Worth a status query and another attempt.
        transient: Error,
        /// Not worth another attempt.
        fatal: Error,
    };

    fn upload(
        self: *Machine,
        scratch: *std.heap.ArenaAllocator,
        bucket_name: []const u8,
        object_name: []const u8,
        options: types.UploadOptions,
        metadata_crc: ?[8]u8,
    ) Error!types.Owned(types.ObjectInfo) {
        const session_uri = try self.openSession(scratch, bucket_name, object_name, options, metadata_crc);
        var response: std.heap.ArenaAllocator = .init(self.client.gpa);
        defer response.deinit();

        var attempt: u32 = 1;
        var querying = false;
        while (true) {
            _ = response.reset(.retain_capacity);
            const outcome = if (querying)
                self.query(&response, session_uri)
            else
                self.sendNext(&response, session_uri) catch |err| {
                    // The reader failed or lied about its size; the session
                    // has no future.
                    self.cancel(&response, session_uri);
                    return err;
                };

            switch (outcome) {
                .done => |res| {
                    var result: types.Owned(types.ObjectInfo) = try .init(self.client.gpa);
                    errdefer result.deinit();
                    // The decode copies every string it keeps, so the
                    // response arena may go.
                    result.value = codec.decodeObject(result.arena.allocator(), res.body) catch |err|
                        return rpc.decodeFailed(self.client, err, "object");
                    if (self.client.diagnostics) |d| d.clear();
                    return result;
                },
                .stored => |stored| {
                    querying = false;
                    // A server cannot have stored bytes that were never
                    // sent; believing it would read past the source.
                    const sent_high: u64 = switch (self.source) {
                        .slice => |data| @min(self.confirmed + self.client.chunk_size, data.len),
                        .reader => self.chunk_start + self.chunk_len,
                    };
                    if (stored > sent_high) {
                        if (self.client.diagnostics) |d| d.print(
                            "the session claims {d} bytes stored, more than the {d} sent",
                            .{ stored, sent_high },
                        );
                        self.cancel(&response, session_uri);
                        return error.InvalidResponse;
                    }
                    if (self.source == .reader and stored < self.chunk_start) {
                        // The server forgot bytes the reader cannot supply
                        // again: as good as a lost session, but this one
                        // still exists, so cancel it.
                        self.cancel(&response, session_uri);
                        return error.UploadSessionLost;
                    }
                    if (stored > self.confirmed) {
                        self.confirmed = stored;
                        attempt = 1;
                    } else {
                        // A 308 that stored nothing new: resending is
                        // bounded like any other retry, or a server that
                        // keeps every answer at zero would spin forever.
                        attempt += 1;
                        if (attempt > self.client.retry.max_attempts) {
                            if (self.client.diagnostics) |d| d.print("the server keeps answering 308 without storing anything", .{});
                            self.cancel(&response, session_uri);
                            return error.Internal;
                        }
                    }
                },
                .lost => return error.UploadSessionLost,
                .transient => |err| {
                    attempt += 1;
                    if (attempt > self.client.retry.max_attempts) {
                        self.cancel(&response, session_uri);
                        return err;
                    }
                    querying = true;
                    const delay_ms = rpc.backoffMs(self.client, attempt - 1);
                    logging.warn("resumable chunk at byte {d} failed with {t}; querying the session in {d} ms (attempt {d} of {d})", .{
                        self.confirmed, err, delay_ms, attempt, self.client.retry.max_attempts,
                    });
                    try self.client.io.sleep(.fromMilliseconds(delay_ms), .awake);
                },
                .fatal => |err| {
                    self.cancel(&response, session_uri);
                    return err;
                },
            }
        }
    }

    /// Opens the session through the engine, which attaches credentials:
    /// only this request carries a token. The `Location` answer is the
    /// session URI.
    fn openSession(
        self: *Machine,
        scratch: *std.heap.ArenaAllocator,
        bucket_name: []const u8,
        object_name: []const u8,
        options: types.UploadOptions,
        metadata_crc: ?[8]u8,
    ) Error![]const u8 {
        const a = scratch.allocator();
        const path = try names.uploadResumablePath(a, bucket_name);
        const metadata = try codec.encodeUploadMetadata(a, object_name, options, metadata_crc);
        var length_buf: [20]u8 = undefined;
        var headers: std.ArrayList(core.transport.Header) = .empty;
        try headers.append(a, .{ .name = "X-Upload-Content-Type", .value = options.content_type });
        if (self.total) |total| {
            try headers.append(a, .{
                .name = "X-Upload-Content-Length",
                .value = std.fmt.bufPrint(&length_buf, "{d}", .{total}) catch unreachable,
            });
        }
        var response: std.heap.ArenaAllocator = .init(self.client.gpa);
        defer response.deinit();
        const res = rpc.executeStream(self.client, &response, .{
            .method = .POST,
            .path = path,
            .content_type = "application/json; charset=UTF-8",
            .headers = headers.items,
            .body = .{ .segments = &.{metadata} },
            // An unused session expires on its own; opening is harmless to
            // repeat.
            .retry = true,
        }) catch |err| switch (err) {
            error.WriteFailed => unreachable,
            else => |e| return e,
        };
        const location = res.header("Location") orelse {
            if (self.client.diagnostics) |d| d.print("the session-opening response carried no Location header", .{});
            return error.InvalidResponse;
        };
        return try a.dupe(u8, location);
    }

    /// Sends the next piece: the chunk at `confirmed`, or the empty
    /// finalize when a known total is fully stored. Reader trouble is
    /// returned raw for the caller to cancel on.
    fn sendNext(
        self: *Machine,
        response: *std.heap.ArenaAllocator,
        session_uri: []const u8,
    ) error{ ReadFailed, UnexpectedEndOfStream, StreamTooLong }!Exchange {
        const chunk = try self.nextChunk();
        var range_buf: [72]u8 = undefined;
        var header: [1]core.transport.Header = undefined;
        if (chunk.len == 0 and self.total != null and self.confirmed == self.total.?) {
            // The stream ended exactly on a chunk boundary, or was empty:
            // an empty PUT with `bytes */{total}` finishes the upload.
            header[0] = .{ .name = "Content-Range", .value = finalizeRange(&range_buf, self.total) };
            return self.exchange(response, session_uri, &header, &.{}, "finalize");
        }
        const end = self.confirmed + chunk.len - 1;
        header[0] = .{ .name = "Content-Range", .value = chunkRange(&range_buf, self.confirmed, end, self.total) };
        const segments = [_][]const u8{chunk};
        return self.exchange(response, session_uri, &header, &segments, "chunk");
    }

    /// The bytes to send from `confirmed`, filling the reader's buffer
    /// when it has all been confirmed. Empty means the source has ended.
    fn nextChunk(self: *Machine) error{ ReadFailed, UnexpectedEndOfStream, StreamTooLong }![]const u8 {
        switch (self.source) {
            .slice => |data| {
                const start: usize = @intCast(self.confirmed);
                const len = @min(self.client.chunk_size, data.len - start);
                return data[start .. start + len];
            },
            .reader => |source| {
                if (!self.eof and self.confirmed == self.chunk_start + self.chunk_len) {
                    try self.fill(source);
                }
                const within: usize = @intCast(self.confirmed - self.chunk_start);
                return source.buffer[within..self.chunk_len];
            },
        }
    }

    /// Reads the next chunk into the buffer, hashes it, and settles the
    /// total when the stream ends.
    fn fill(self: *Machine, source: Source.Reader) error{ ReadFailed, UnexpectedEndOfStream, StreamTooLong }!void {
        self.chunk_start = self.confirmed;
        self.chunk_len = 0;
        var want: usize = self.client.chunk_size;
        if (source.declared) |declared| {
            want = @intCast(@min(want, declared - self.chunk_start));
        }
        const n = source.r.readSliceShort(source.buffer[0..want]) catch return error.ReadFailed;
        self.chunk_len = n;
        if (source.hasher) |hasher| hasher.update(source.buffer[0..n]);
        if (source.declared) |declared| {
            if (n < want) return error.UnexpectedEndOfStream;
            if (self.chunk_start + n == declared) {
                // The declared size is reached: one more byte would be a lie.
                var probe: [1]u8 = undefined;
                const extra = source.r.readSliceShort(&probe) catch return error.ReadFailed;
                if (extra != 0) return error.StreamTooLong;
                self.eof = true;
            }
        } else if (n < want) {
            self.eof = true;
            self.total = self.chunk_start + n;
        }
    }

    /// Asks the server how much it has stored.
    fn query(self: *Machine, response: *std.heap.ArenaAllocator, session_uri: []const u8) Exchange {
        var range_buf: [72]u8 = undefined;
        var header = [_]core.transport.Header{
            .{ .name = "Content-Range", .value = finalizeRange(&range_buf, self.total) },
        };
        return self.exchange(response, session_uri, &header, &.{}, "status query");
    }

    /// One request to the session URI, which carries no credentials: the
    /// URI itself is the authorization.
    fn exchange(
        self: *Machine,
        response: *std.heap.ArenaAllocator,
        session_uri: []const u8,
        headers: []const core.transport.Header,
        segments: []const []const u8,
        what: []const u8,
    ) Exchange {
        const started = std.Io.Clock.awake.now(self.client.io);
        const outcome = self.client.transport.sendStream(.{
            .method = .PUT,
            .url = session_uri,
            .headers = headers,
            .body = .{ .segments = segments },
            .timeout_ms = self.client.request_timeout_ms,
        }, response.allocator());
        const elapsed_ms = started.durationTo(std.Io.Clock.awake.now(self.client.io)).toMilliseconds();

        if (outcome) |res| {
            logging.debug("resumable {s} at byte {d} -> {d} in {d} ms", .{ what, self.confirmed, res.status, elapsed_ms });
            return switch (res.status) {
                200, 201 => .{ .done = res },
                308 => .{ .stored = storedFromRange(res.header("Range")) },
                404, 410 => .lost,
                else => self.failure(res),
            };
        } else |err| {
            logging.debug("resumable {s} at byte {d} -> {t} in {d} ms", .{ what, self.confirmed, err, elapsed_ms });
            const mapped: Error = switch (err) {
                // Chunks are segments into a buffered sink; caller streams
                // are not involved.
                error.ReadFailed, error.WriteFailed, error.EndOfStream => unreachable,
                else => |e| e,
            };
            if (self.client.diagnostics) |d| d.print("{t}", .{mapped});
            return if (core.isRetryable(mapped)) .{ .transient = mapped } else .{ .fatal = mapped };
        }
    }

    /// Maps a status neither 308 nor final, with the server's words in the
    /// diagnostics. The session URI never goes there.
    fn failure(self: *Machine, res: core.transport.StreamResponse) Exchange {
        var scratch: std.heap.ArenaAllocator = .init(self.client.gpa);
        defer scratch.deinit();
        const body = core.errors.decodeErrorBody(scratch.allocator(), res.body) catch null;
        const status_text = if (body) |b| b.status else "";
        const message = if (body) |b| b.message else res.body;
        if (self.client.diagnostics) |d| d.set(res.status, status_text, message);
        const err = core.errors.fromResponse(res.status, status_text);
        return if (core.isRetryable(err)) .{ .transient = err } else .{ .fatal = err };
    }

    /// Best-effort DELETE of the session, so the server can drop its state.
    fn cancel(self: *Machine, response: *std.heap.ArenaAllocator, session_uri: []const u8) void {
        _ = response.reset(.retain_capacity);
        _ = self.client.transport.sendStream(.{
            .method = .DELETE,
            .url = session_uri,
            .timeout_ms = self.client.request_timeout_ms,
        }, response.allocator()) catch {};
    }
};

/// `bytes {start}-{end}/{total}`, with `*` for a total not yet known.
fn chunkRange(buf: []u8, start: u64, end: u64, total: ?u64) []const u8 {
    return if (total) |t|
        std.fmt.bufPrint(buf, "bytes {d}-{d}/{d}", .{ start, end, t }) catch unreachable
    else
        std.fmt.bufPrint(buf, "bytes {d}-{d}/*", .{ start, end }) catch unreachable;
}

/// `bytes */{total}`: the empty finalize, and also the status query.
fn finalizeRange(buf: []u8, total: ?u64) []const u8 {
    return if (total) |t|
        std.fmt.bufPrint(buf, "bytes */{d}", .{t}) catch unreachable
    else
        std.fmt.bufPrint(buf, "bytes */*", .{}) catch unreachable;
}

/// How many bytes a 308's `Range: bytes=0-N` confirms: N+1, or 0 when the
/// header is absent or unreadable, which the spec reads as "nothing stored".
fn storedFromRange(value: ?[]const u8) u64 {
    const text = value orelse return 0;
    const rest = std.mem.trim(u8, text, " \t");
    if (!std.ascii.startsWithIgnoreCase(rest, "bytes=")) return 0;
    const dash = std.mem.lastIndexOfScalar(u8, rest, '-') orelse return 0;
    const last = std.fmt.parseInt(u64, rest[dash + 1 ..], 10) catch return 0;
    return last +| 1;
}

const testing = std.testing;

test "Content-Range formatting: chunks, finals, finalize and query" {
    var buf: [72]u8 = undefined;
    try testing.expectEqualStrings("bytes 0-8388607/20000000", chunkRange(&buf, 0, 8388607, 20000000));
    try testing.expectEqualStrings("bytes 0-8388607/*", chunkRange(&buf, 0, 8388607, null));
    try testing.expectEqualStrings("bytes 8388608-19999999/20000000", chunkRange(&buf, 8388608, 19999999, 20000000));
    try testing.expectEqualStrings("bytes */20000000", finalizeRange(&buf, 20000000));
    try testing.expectEqualStrings("bytes */0", finalizeRange(&buf, 0));
    try testing.expectEqualStrings("bytes */*", finalizeRange(&buf, null));
}

test "308 Range parsing: present, absent, malformed" {
    try testing.expectEqual(8388608, storedFromRange("bytes=0-8388607"));
    try testing.expectEqual(1, storedFromRange("bytes=0-0"));
    try testing.expectEqual(5, storedFromRange(" bytes=0-4 "));
    // No Range header means nothing has been stored yet.
    try testing.expectEqual(0, storedFromRange(null));
    try testing.expectEqual(0, storedFromRange(""));
    try testing.expectEqual(0, storedFromRange("bytes=0-"));
    try testing.expectEqual(0, storedFromRange("items=0-5"));
    try testing.expectEqual(0, storedFromRange("bytes=x-y"));
}

const test_util = @import("test_util.zig");
const Harness = test_util.Harness;
const Reply = test_util.FakeTransport.Reply;

const test_session_uri = "https://storage.example.test/upload/session/SECRET-7f3a";
const opened: Reply = .{ .respond = .{
    .status = 200,
    .body = "",
    .headers = &.{.{ .name = "Location", .value = test_session_uri }},
} };
const chunk_size = 256 * 1024;

fn kept(comptime last: u64) Reply {
    return .{ .respond = .{
        .status = 308,
        .body = "",
        .headers = &.{.{ .name = "Range", .value = std.fmt.comptimePrint("bytes=0-{d}", .{last}) }},
    } };
}

const finished: Reply = .{ .respond = .{
    .status = 200,
    .body = "{\"name\":\"backup.tar\",\"bucket\":\"b\",\"size\":\"614400\",\"generation\":\"55\"}",
} };

fn testData(gpa: Allocator, n: usize) ![]u8 {
    const data = try gpa.alloc(u8, n);
    for (data, 0..) |*b, i| b.* = @intCast(i % 251);
    return data;
}

fn resumableOptions() Harness.Options {
    return .{
        .chunk_size = chunk_size,
        .single_request_limit = 1024,
        .retry = .{ .max_attempts = 3, .initial_backoff_ms = 1 },
    };
}

test "clean run: a large upload takes the resumable path, chunk by chunk" {
    var h: Harness = undefined;
    try h.init(&.{ opened, kept(chunk_size - 1), kept(2 * chunk_size - 1), finished }, resumableOptions());
    defer h.deinit();
    const data = try testData(testing.allocator, 600 * 1024);
    defer testing.allocator.free(data);

    var info = try h.client.bucket("b").object("backup.tar").upload(data, .{ .content_type = "application/x-tar" });
    defer info.deinit();
    try testing.expectEqual(55, info.value.generation);

    // The session opens through the front door, with credentials and the
    // upload's shape declared.
    const open = try h.fake.streamRequest(0);
    try testing.expectEqualStrings("https://storage.googleapis.com/upload/storage/v1/b/b/o?uploadType=resumable", open.url);
    try testing.expectEqualStrings("ya29.test-token", open.bearer.?);
    try testing.expectEqualStrings("application/x-tar", open.header("X-Upload-Content-Type").?);
    try testing.expectEqualStrings("614400", open.header("X-Upload-Content-Length").?);
    try testing.expect(std.mem.indexOf(u8, open.body_prefix, "\"name\":\"backup.tar\"") != null);
    try testing.expect(std.mem.indexOf(u8, open.body_prefix, "\"crc32c\":") != null);

    // Chunks go to the session URI, without credentials: the URI is the
    // authorization.
    const ranges = [_][]const u8{ "bytes 0-262143/614400", "bytes 262144-524287/614400", "bytes 524288-614399/614400" };
    for (ranges, 1..) |range, i| {
        const put = try h.fake.streamRequest(i);
        try testing.expectEqual(.PUT, put.method);
        try testing.expectEqualStrings(test_session_uri, put.url);
        try testing.expectEqual(null, put.bearer);
        try testing.expectEqualStrings(range, put.header("Content-Range").?);
    }
    // Each chunk carried exactly its slice of the data.
    try testing.expectEqual(core.crc32c.hash(data[0..chunk_size]), (try h.fake.streamRequest(1)).body_crc32c);
    try testing.expectEqual(core.crc32c.hash(data[chunk_size .. 2 * chunk_size]), (try h.fake.streamRequest(2)).body_crc32c);
    try testing.expectEqual(core.crc32c.hash(data[2 * chunk_size ..]), (try h.fake.streamRequest(3)).body_crc32c);
}

test "the server keeping less than was sent moves the resend point back" {
    var h: Harness = undefined;
    try h.init(&.{ opened, kept(128 * 1024 - 1), kept(chunk_size + 128 * 1024 - 1), finished }, resumableOptions());
    defer h.deinit();
    const data = try testData(testing.allocator, 600 * 1024);
    defer testing.allocator.free(data);

    var info = try h.client.bucket("b").object("backup.tar").upload(data, .{});
    defer info.deinit();
    // The second request starts at what the server kept, not at what was sent.
    try testing.expectEqualStrings("bytes 131072-393215/614400", (try h.fake.streamRequest(2)).header("Content-Range").?);
    try testing.expectEqual(core.crc32c.hash(data[128 * 1024 .. 128 * 1024 + chunk_size]), (try h.fake.streamRequest(2)).body_crc32c);
}

test "a 503 mid-chunk leads to a status query, then a resume" {
    var h: Harness = undefined;
    try h.init(&.{
        opened,
        .{ .respond = .{ .status = 503, .body = "{}" } },
        // The query learns the server kept the first 4 KiB.
        .{ .respond = .{ .status = 308, .body = "", .headers = &.{.{ .name = "Range", .value = "bytes=0-4095" }} } },
        kept(4096 + chunk_size - 1),
        kept(4096 + 2 * chunk_size - 1),
        finished,
    }, resumableOptions());
    defer h.deinit();
    const data = try testData(testing.allocator, 600 * 1024);
    defer testing.allocator.free(data);

    var info = try h.client.bucket("b").object("backup.tar").upload(data, .{});
    defer info.deinit();

    // The query is an empty PUT that names only the total.
    const query_req = try h.fake.streamRequest(2);
    try testing.expectEqualStrings("bytes */614400", query_req.header("Content-Range").?);
    try testing.expectEqual(0, query_req.body_len);
    // Sending resumed exactly where the query said.
    try testing.expectEqualStrings("bytes 4096-266239/614400", (try h.fake.streamRequest(3)).header("Content-Range").?);
    try testing.expectEqual(1, h.clock.sleep_count);
}

test "a status query can reveal the upload already completed" {
    var h: Harness = undefined;
    try h.init(&.{ opened, .{ .fail = error.ConnectionResetByPeer }, finished }, resumableOptions());
    defer h.deinit();
    const data = try testData(testing.allocator, 600 * 1024);
    defer testing.allocator.free(data);
    var info = try h.client.bucket("b").object("backup.tar").upload(data, .{});
    defer info.deinit();
    try testing.expectEqual(55, info.value.generation);
    try testing.expectEqual(3, h.fake.stream_requests.items.len);
}

test "a dead session restarts an in-memory upload from its bytes" {
    var h: Harness = undefined;
    try h.init(&.{
        opened,
        .{ .respond = .{ .status = 410, .body = "" } },
        opened,
        kept(chunk_size - 1),
        kept(2 * chunk_size - 1),
        finished,
    }, resumableOptions());
    defer h.deinit();
    const data = try testData(testing.allocator, 600 * 1024);
    defer testing.allocator.free(data);
    var info = try h.client.bucket("b").object("backup.tar").upload(data, .{});
    defer info.deinit();
    // Two session openings: the second run started from byte zero again.
    try testing.expectEqualStrings("bytes 0-262143/614400", (try h.fake.streamRequest(3)).header("Content-Range").?);
    try testing.expectEqual(6, h.fake.stream_requests.items.len);
}

test "a dead session fails a reader, whose bytes are gone" {
    var h: Harness = undefined;
    try h.init(&.{ opened, kept(chunk_size - 1), .{ .respond = .{ .status = 404, .body = "" } } }, resumableOptions());
    defer h.deinit();
    const data = try testData(testing.allocator, 600 * 1024);
    defer testing.allocator.free(data);
    var reader: std.Io.Reader = .fixed(data);
    try testing.expectError(
        error.UploadSessionLost,
        h.client.bucket("b").object("backup.tar").uploadFrom(&reader, .{}),
    );
}

test "unknown size: chunks say /*, and a boundary end finishes with an empty PUT" {
    var h: Harness = undefined;
    try h.init(&.{ opened, kept(chunk_size - 1), finished }, resumableOptions());
    defer h.deinit();
    const data = try testData(testing.allocator, chunk_size);
    defer testing.allocator.free(data);
    var reader: std.Io.Reader = .fixed(data);

    var info = try h.client.bucket("b").object("backup.tar").uploadFrom(&reader, .{});
    defer info.deinit();
    // No size was declared, so the opening claims no length.
    try testing.expectEqual(null, (try h.fake.streamRequest(0)).header("X-Upload-Content-Length"));
    try testing.expectEqualStrings("bytes 0-262143/*", (try h.fake.streamRequest(1)).header("Content-Range").?);
    // The stream ended exactly on the chunk boundary: an empty PUT names
    // the total.
    const finalize = try h.fake.streamRequest(2);
    try testing.expectEqualStrings("bytes */262144", finalize.header("Content-Range").?);
    try testing.expectEqual(0, finalize.body_len);
}

test "an empty stream finishes with bytes */0" {
    var h: Harness = undefined;
    try h.init(&.{ opened, finished }, resumableOptions());
    defer h.deinit();
    var reader: std.Io.Reader = .fixed("");
    var info = try h.client.bucket("b").object("empty").uploadFrom(&reader, .{});
    defer info.deinit();
    const finalize = try h.fake.streamRequest(1);
    try testing.expectEqualStrings("bytes */0", finalize.header("Content-Range").?);
    try testing.expectEqual(0, finalize.body_len);
}

test "a declared size polices the reader in both directions" {
    var h: Harness = undefined;
    // Each refusal cancels its session, which consumes a script slot.
    try h.init(&.{ opened, .{ .respond = .{ .body = "" } }, opened, .{ .respond = .{ .body = "" } } }, resumableOptions());
    defer h.deinit();
    const obj = h.client.bucket("b").object("sized");

    var short: std.Io.Reader = .fixed("only ten b");
    try testing.expectError(error.UnexpectedEndOfStream, obj.uploadFrom(&short, .{ .size = 100 }));
    // The session was cancelled with a best-effort DELETE.
    const cancel_req = try h.fake.streamRequest(1);
    try testing.expectEqual(.DELETE, cancel_req.method);
    try testing.expectEqualStrings(test_session_uri, cancel_req.url);

    var long: std.Io.Reader = .fixed("elevenbytes");
    try testing.expectError(error.StreamTooLong, obj.uploadFrom(&long, .{ .size = 10 }));
}

test "the session URI reaches neither the log nor the diagnostics" {
    logging.capture.reset();
    var h: Harness = undefined;
    try h.init(&.{
        opened,
        .{ .respond = .{ .status = 503, .body = "{\"error\":{\"code\":503,\"errors\":[{\"reason\":\"backendError\"}]}}" } },
        .{ .respond = .{ .status = 503, .body = "{}" } },
        .{ .respond = .{ .status = 503, .body = "{}" } },
    }, resumableOptions());
    defer h.deinit();
    const data = try testData(testing.allocator, 600 * 1024);
    defer testing.allocator.free(data);
    try testing.expectError(error.Unavailable, h.client.bucket("b").object("backup.tar").upload(data, .{}));

    try testing.expect(logging.capture.lines > 0);
    try testing.expect(std.mem.indexOf(u8, logging.capture.text(), "SECRET") == null);
    try testing.expect(std.mem.indexOf(u8, &h.diag.buffer, "SECRET") == null);
}

/// A reader that synthesizes its bytes, so a large upload test holds no
/// large buffer of its own.
const PatternReader = struct {
    remaining: usize,
    position: usize = 0,
    interface: std.Io.Reader,

    fn init(n: usize) PatternReader {
        return .{ .remaining = n, .interface = .{
            .vtable = &.{ .stream = stream },
            .buffer = &.{},
            .seek = 0,
            .end = 0,
        } };
    }

    fn stream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *PatternReader = @alignCast(@fieldParentPtr("interface", r));
        if (self.remaining == 0) return error.EndOfStream;
        var block: [4096]u8 = undefined;
        const want = @min(block.len, self.remaining);
        for (block[0..want], 0..) |*b, i| b.* = @intCast((self.position + i) % 251);
        const out = limit.sliceConst(block[0..want]);
        const n = try w.write(out);
        self.remaining -= n;
        self.position += n;
        return n;
    }
};

/// Counts live bytes through to a child allocator, so a test can assert on
/// peak memory.
const PeakAllocator = struct {
    child: Allocator,
    live: usize = 0,
    peak: usize = 0,

    fn allocator(self: *PeakAllocator) Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    fn note(self: *PeakAllocator, grown: usize, shrunk: usize) void {
        self.live = self.live + grown - shrunk;
        self.peak = @max(self.peak, self.live);
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *PeakAllocator = @ptrCast(@alignCast(ctx));
        const out = self.child.vtable.alloc(self.child.ptr, len, alignment, ret_addr) orelse return null;
        self.note(len, 0);
        return out;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *PeakAllocator = @ptrCast(@alignCast(ctx));
        if (!self.child.vtable.resize(self.child.ptr, memory, alignment, new_len, ret_addr)) return false;
        if (new_len > memory.len) self.note(new_len - memory.len, 0) else self.note(0, memory.len - new_len);
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *PeakAllocator = @ptrCast(@alignCast(ctx));
        const out = self.child.vtable.remap(self.child.ptr, memory, alignment, new_len, ret_addr) orelse return null;
        if (new_len > memory.len) self.note(new_len - memory.len, 0) else self.note(0, memory.len - new_len);
        return out;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *PeakAllocator = @ptrCast(@alignCast(ctx));
        self.child.vtable.free(self.child.ptr, memory, alignment, ret_addr);
        self.note(0, memory.len);
    }
};

test "uploadFrom holds one chunk buffer and little else" {
    var peak: PeakAllocator = .{ .child = testing.allocator };
    var fake: test_util.FakeTransport = .init(testing.allocator, &.{
        opened,
        kept(chunk_size - 1),
        kept(2 * chunk_size - 1),
        kept(3 * chunk_size - 1),
        finished,
    });
    defer fake.deinit();
    var clock: test_util.FakeClock = .{};
    var token: test_util.FakeTokenProvider = .{};
    var client: Client = try .init(peak.allocator(), clock.io(), .{
        .token_provider = token.provider(),
        .chunk_size = chunk_size,
        .single_request_limit = 1024,
        .transport = fake.transport(),
    });
    defer client.deinit();

    // 750 KiB streamed through a 256 KiB chunk buffer: the peak stays a
    // little over one chunk, never in proportion to the object.
    var source: PatternReader = .init(768 * 1024);
    var info = try client.bucket("b").object("big").uploadFrom(&source.interface, .{});
    info.deinit();
    try testing.expect(peak.peak >= chunk_size);
    try testing.expect(peak.peak < chunk_size + 96 * 1024);
}
