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
const checkpoint = @import("checkpoint.zig");
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
    /// A regular file read at offsets: every chunk is re-read from where
    /// the server stands, so a lost session, or a later process resuming
    /// this one's session, starts exactly there. The bytes are hashed as
    /// they are first read, and the request that finishes the upload
    /// carries the whole file's CRC32C, which Cloud Storage checks before
    /// the object exists: no read back, and no delete afterwards.
    file: File,

    pub const Reader = struct {
        r: *std.Io.Reader,
        /// `chunk_size` bytes, owned by the caller.
        buffer: []u8,
        /// The declared total, or null when unknown.
        declared: ?u64,
        /// Fed every byte read, for the caller's post-upload verification.
        hasher: ?*core.crc32c.Hasher = null,
    };

    pub const File = struct {
        f: std.Io.File,
        /// `chunk_size` bytes, owned by the caller.
        buffer: []u8,
        /// The file's length, measured before the upload.
        size: u64,
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
            .total = sourceTotal(source),
            .hash_final = client.verify_checksums and source == .file,
        };
        const outcome = machine.upload(&scratch, bucket_name, object_name, options, metadata_crc);
        const err = if (outcome) |result| return result else |err| err;
        if (err != error.UploadSessionLost or source == .reader) return err;
        // The bytes can be read again: a lost session costs a restart,
        // not the upload. Bounded like any other retry.
        restarts += 1;
        if (restarts >= client.retry.max_attempts) return err;
        const delay_ms = rpc.backoffMs(client, restarts);
        logging.warn("resumable upload of {s}: the session was lost; starting over in {d} ms", .{ object_name, delay_ms });
        try client.io.sleep(.fromMilliseconds(delay_ms), .awake);
        _ = scratch.reset(.retain_capacity);
    }
}

fn sourceTotal(source: Source) ?u64 {
    return switch (source) {
        .slice => |data| data.len,
        .reader => |r| r.declared,
        .file => |f| f.size,
    };
}

/// Runs one pass over an already-open session, asking it first where it
/// stands when `resuming`, so a later process carries an upload on from
/// what the server holds. A session that is gone is
/// `error.UploadSessionLost`, the caller's to start over. With
/// `cancel_on_failure` false, a failure a resume could get past leaves
/// the session standing, for a checkpoint to come back to.
pub fn runSession(
    client: *Client,
    bucket_name: []const u8,
    object_name: []const u8,
    source: Source,
    options: types.UploadOptions,
    metadata_crc: ?[8]u8,
    session_uri: []const u8,
    resuming: bool,
    cancel_on_failure: bool,
) Error!types.Owned(types.ObjectInfo) {
    var scratch: std.heap.ArenaAllocator = .init(client.gpa);
    defer scratch.deinit();
    const total = sourceTotal(source);
    var machine: Machine = .{
        .client = client,
        .source = source,
        .total = total,
        .session_uri = session_uri,
        .query_first = resuming,
        .cancel_on_failure = cancel_on_failure,
        .hash_final = client.verify_checksums and source == .file,
        // A dead process may have sent everything before this one began.
        .sent_high = if (resuming) total orelse 0 else 0,
    };
    return machine.upload(&scratch, bucket_name, object_name, options, metadata_crc);
}

/// Opens a resumable session for `object_name` and returns its URI, in
/// `arena`. The URI is a credential: anyone holding it can write the
/// object for up to a week. Retried like a read: an unused session
/// expires on its own.
pub fn startSession(
    client: *Client,
    arena: Allocator,
    bucket_name: []const u8,
    object_name: []const u8,
    options: types.UploadOptions,
    metadata_crc: ?[8]u8,
    total: ?u64,
) Error![]const u8 {
    var scratch: std.heap.ArenaAllocator = .init(client.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const path = try names.uploadResumablePath(a, bucket_name, options.preconditions);
    const metadata = try codec.encodeUploadMetadata(a, object_name, options, metadata_crc);
    var length_buf: [20]u8 = undefined;
    var headers: std.ArrayList(core.transport.Header) = .empty;
    try headers.append(a, .{ .name = "X-Upload-Content-Type", .value = options.content_type });
    if (total) |declared| {
        try headers.append(a, .{
            .name = "X-Upload-Content-Length",
            .value = std.fmt.bufPrint(&length_buf, "{d}", .{declared}) catch unreachable,
        });
    }
    var response: std.heap.ArenaAllocator = .init(client.gpa);
    defer response.deinit();
    const res = rpc.executeStream(client, &response, .{
        .method = .POST,
        .path = path,
        .content_type = "application/json; charset=UTF-8",
        .headers = headers.items,
        .body = .{ .segments = &.{metadata} },
        .retry = true,
    }) catch |err| switch (err) {
        error.WriteFailed => unreachable,
        else => |e| return e,
    };
    const location = res.header("Location") orelse {
        if (client.diagnostics) |d| d.print("the session-opening response carried no Location header", .{});
        return error.InvalidResponse;
    };
    return try arena.dupe(u8, location);
}

/// Best-effort DELETE of a session another run opened, so the server can
/// drop its state: for a source that changed under a checkpoint.
pub fn dropSession(client: *Client, session_uri: []const u8) void {
    var response: std.heap.ArenaAllocator = .init(client.gpa);
    defer response.deinit();
    _ = client.transport.sendStream(.{
        .method = .DELETE,
        .url = session_uri,
        .timeout_ms = client.request_timeout_ms,
    }, response.allocator()) catch {};
}

/// Cancels a session for a caller who will not resume it, as
/// `Client.abandonTransfer` asks: any answer means the server heard, a
/// cancelled session answering 499. Only a transport that could not carry
/// the request fails.
pub fn cancelSession(client: *Client, session_uri: []const u8) Error!void {
    var response: std.heap.ArenaAllocator = .init(client.gpa);
    defer response.deinit();
    _ = client.transport.sendStream(.{
        .method = .DELETE,
        .url = session_uri,
        .timeout_ms = client.request_timeout_ms,
    }, response.allocator()) catch |err| switch (err) {
        // No body travels and the sink is a buffer.
        error.ReadFailed, error.WriteFailed, error.EndOfStream => unreachable,
        else => |e| return e,
    };
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
    /// An already-open session to use, or null to open one.
    session_uri: ?[]const u8 = null,
    /// Ask the session where it stands before sending anything: how a
    /// resumed session learns what a dead process got stored.
    query_first: bool = false,
    /// False leaves the session standing after failures a resume could
    /// get past, for a checkpoint to come back to.
    cancel_on_failure: bool = true,
    /// For a file source with checksums on: the whole file's running
    /// CRC32C, hashed as bytes are first read, and rebuilt from the file
    /// for bytes a dead process sent. The finishing request carries it.
    hash_final: bool = false,
    hasher: core.crc32c.Hasher = .init(),
    /// How far `hasher` has consumed the file.
    hashed: u64 = 0,
    /// The highest byte offset ever sent, which a 308 cannot exceed.
    sent_high: u64 = 0,

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
        const session_uri = self.session_uri orelse
            try startSession(self.client, scratch.allocator(), bucket_name, object_name, options, metadata_crc, self.total);
        var response: std.heap.ArenaAllocator = .init(self.client.gpa);
        defer response.deinit();

        var attempt: u32 = 1;
        var querying = self.query_first;
        while (true) {
            _ = response.reset(.retain_capacity);
            const outcome = if (querying)
                self.query(&response, session_uri)
            else
                self.sendNext(&response, session_uri, metadata_crc) catch |err| {
                    // The source failed or lied about its size; the session
                    // has no future a resume could reach either.
                    self.maybeCancel(&response, session_uri, err);
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
                    // A finished upload holds every byte, and cannot finish
                    // before the source has. A server that says done short
                    // of that has finished a truncated object, as an
                    // emulator does when it takes a status query for a
                    // finalize: no success, and the object goes again.
                    const named = codec.decodeObjectSize(response.allocator(), res.body) catch null;
                    const complete = if (self.total) |total| (named orelse total) == total else false;
                    if (!complete) {
                        const deleted = self.discard(bucket_name, object_name, result.value.generation);
                        // After the delete, whose success cleared them.
                        if (self.client.diagnostics) |d| {
                            const fate = if (deleted) "; the truncated object was deleted again" else "";
                            if (self.total) |total| d.print(
                                "the server finished the upload holding {d} of its {d} bytes{s}",
                                .{ named.?, total, fate },
                            ) else d.print("the server finished the upload before the stream ended{s}", .{fate});
                        }
                        return error.InvalidResponse;
                    }
                    if (self.hash_final) {
                        // The whole file, hashed: the finishing request
                        // already carried this, unless a query finished a
                        // resumed session that held everything, so a
                        // mismatch here means the file changed under a
                        // checkpoint.
                        self.advanceHashTo(self.total.?) catch |err| return err;
                        const whole = self.hasher.final();
                        if (result.value.crc32c) |stored_crc| {
                            if (stored_crc != whole) {
                                const deleted = self.discard(bucket_name, object_name, result.value.generation);
                                if (self.client.diagnostics) |d| d.print(
                                    "checksum mismatch after the upload finished: the file hashes to {d}, the object stores {d}{s}",
                                    .{ whole, stored_crc, if (deleted) "; the object was deleted again" else "" },
                                );
                                return error.ChecksumMismatch;
                            }
                        } else {
                            logging.warn("upload of {s} finished, but the server named no crc32c to verify against", .{object_name});
                        }
                    }
                    if (self.client.diagnostics) |d| d.clear();
                    return result;
                },
                .stored => |stored| {
                    querying = false;
                    // A server cannot have stored bytes that were never
                    // sent, by this process or the dead one; believing it
                    // would read past the source.
                    if (stored > self.sent_high) {
                        if (self.client.diagnostics) |d| d.print(
                            "the session claims {d} bytes stored, more than the {d} sent",
                            .{ stored, self.sent_high },
                        );
                        self.maybeCancel(&response, session_uri, error.InvalidResponse);
                        return error.InvalidResponse;
                    }
                    if (self.source == .reader and stored < self.chunk_start) {
                        // The server forgot bytes the reader cannot supply
                        // again: as good as a lost session, but this one
                        // still exists, so cancel it.
                        self.maybeCancel(&response, session_uri, error.UploadSessionLost);
                        return error.UploadSessionLost;
                    }
                    // Bytes a dead process sent are re-read from the file,
                    // so the running hash still spans everything.
                    if (self.hash_final and stored > self.hashed) {
                        self.advanceHashTo(stored) catch |err| {
                            self.maybeCancel(&response, session_uri, err);
                            return err;
                        };
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
                            self.maybeCancel(&response, session_uri, error.Internal);
                            return error.Internal;
                        }
                    }
                },
                .lost => return error.UploadSessionLost,
                .transient => |err| {
                    attempt += 1;
                    if (attempt > self.client.retry.max_attempts) {
                        self.maybeCancel(&response, session_uri, err);
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
                    self.maybeCancel(&response, session_uri, err);
                    return err;
                },
            }
        }
    }

    /// Sends the next piece: the chunk at `confirmed`, or the empty
    /// finalize when a known total is fully stored. Source trouble is
    /// returned raw for the caller to cancel on.
    fn sendNext(
        self: *Machine,
        response: *std.heap.ArenaAllocator,
        session_uri: []const u8,
        metadata_crc: ?[8]u8,
    ) error{ ReadFailed, UnexpectedEndOfStream, StreamTooLong, Canceled, ChecksumMismatch }!Exchange {
        const chunk = try self.nextChunk();
        var range_buf: [72]u8 = undefined;
        var hash_buf: [16]u8 = undefined;
        var headers: [2]core.transport.Header = undefined;
        var count: usize = 1;
        var final = false;
        if (chunk.len == 0 and self.total != null and self.confirmed == self.total.?) {
            // The stream ended exactly on a chunk boundary, or was empty:
            // an empty PUT with `bytes */{total}` finishes the upload.
            headers[0] = .{ .name = "Content-Range", .value = finalizeRange(&range_buf, self.total) };
            if (try self.finalHash(&hash_buf, metadata_crc)) |value| {
                headers[count] = .{ .name = "X-Goog-Hash", .value = value };
                count += 1;
            }
            self.sent_high = @max(self.sent_high, self.confirmed);
            return self.finishing(self.exchange(response, session_uri, headers[0..count], &.{}, "finalize"), response, session_uri);
        }
        const end = self.confirmed + chunk.len - 1;
        headers[0] = .{ .name = "Content-Range", .value = chunkRange(&range_buf, self.confirmed, end, self.total) };
        if (self.total != null and end + 1 == self.total.?) {
            final = true;
            if (try self.finalHash(&hash_buf, metadata_crc)) |value| {
                headers[count] = .{ .name = "X-Goog-Hash", .value = value };
                count += 1;
            }
        }
        self.sent_high = @max(self.sent_high, end + 1);
        const segments = [_][]const u8{chunk};
        const outcome = self.exchange(response, session_uri, headers[0..count], &segments, "chunk");
        return if (final) self.finishing(outcome, response, session_uri) else outcome;
    }

    /// A 400 to the request that carried the file's checksum means the
    /// bytes the session holds are not the file's: stored bytes cannot be
    /// overwritten, so the session can never recover, but a new one can.
    /// It is cancelled and treated as lost, which starts the upload over.
    fn finishing(self: *Machine, outcome: Exchange, response: *std.heap.ArenaAllocator, session_uri: []const u8) Exchange {
        if (!self.hash_final) return outcome;
        if (outcome != .fatal or outcome.fatal != error.InvalidArgument) return outcome;
        logging.warn("the server refused the finishing checksum: the session's bytes are not the file's, so it is cancelled and the upload starts over", .{});
        self.cancel(response, session_uri);
        return .lost;
    }

    /// The whole file's checksum, for the request that finishes the
    /// upload: Cloud Storage then refuses a mismatched object before it
    /// ever exists. A caller's `options.crc32c` that contradicts it is
    /// refused here instead, before the request goes out at all.
    fn finalHash(self: *const Machine, buf: *[16]u8, metadata_crc: ?[8]u8) error{ChecksumMismatch}!?[]const u8 {
        if (!self.hash_final) return null;
        std.debug.assert(self.hashed == self.total.?);
        const whole = self.hasher.final();
        if (metadata_crc) |claimed| {
            const wanted = core.crc32c.fromBase64(&claimed) catch whole;
            if (wanted != whole) {
                if (self.client.diagnostics) |d| d.print(
                    "checksum mismatch before the finish: the file hashes to {d}, options.crc32c says {d}",
                    .{ whole, wanted },
                );
                return error.ChecksumMismatch;
            }
        }
        const encoded = core.crc32c.toBase64(whole);
        return std.fmt.bufPrint(buf, "crc32c={s}", .{&encoded}) catch unreachable;
    }

    /// Hashes the file up to `upto`, re-reading what a dead process sent:
    /// nothing about the data is taken from a checkpoint, so a file that
    /// changed between runs fails the finishing checksum.
    fn advanceHashTo(self: *Machine, upto: u64) error{ ReadFailed, Canceled }!void {
        const source = self.source.file;
        while (self.hashed < upto) {
            const want: usize = @intCast(@min(upto - self.hashed, source.buffer.len));
            const got = source.f.readPositionalAll(self.client.io, source.buffer[0..want], self.hashed) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => {
                    if (self.client.diagnostics) |d| d.print("the file could not be read back at byte {d} to resume: {t}", .{ self.hashed, err });
                    return error.ReadFailed;
                },
            };
            if (got < want) {
                if (self.client.diagnostics) |d| d.print("the file ends at byte {d}, before bytes the session already holds", .{self.hashed + got});
                return error.ReadFailed;
            }
            self.hasher.update(source.buffer[0..got]);
            self.hashed += got;
        }
    }

    /// The bytes to send from `confirmed`, filling the reader's buffer
    /// when it has all been confirmed. Empty means the source has ended.
    fn nextChunk(self: *Machine) error{ ReadFailed, UnexpectedEndOfStream, StreamTooLong, Canceled }![]const u8 {
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
            .file => |source| {
                const start = self.confirmed;
                const len: usize = @intCast(@min(self.client.chunk_size, source.size - start));
                const got = source.f.readPositionalAll(self.client.io, source.buffer[0..len], start) catch |err| switch (err) {
                    error.Canceled => return error.Canceled,
                    else => {
                        if (self.client.diagnostics) |d| d.print("the file could not be read at byte {d}: {t}", .{ start, err });
                        return error.ReadFailed;
                    },
                };
                if (got < len) {
                    if (self.client.diagnostics) |d| d.print("the file ends at byte {d}, short of the {d} it had: it changed under the upload", .{ start + got, source.size });
                    return error.ReadFailed;
                }
                // Hashed on first read: resends re-read at lower offsets
                // and never advance this.
                if (self.hash_final and start + len > self.hashed) {
                    const from: usize = @intCast(self.hashed - start);
                    self.hasher.update(source.buffer[from..len]);
                    self.hashed = start + len;
                }
                return source.buffer[0..len];
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

    /// Best-effort delete of an object the upload must not leave behind,
    /// pinned to its generation, so nothing newer can go with it. Without a
    /// generation nothing is deleted. Returns whether the object went.
    fn discard(self: *Machine, bucket_name: []const u8, object_name: []const u8, generation: u64) bool {
        if (generation == 0) return false;
        var scratch: std.heap.ArenaAllocator = .init(self.client.gpa);
        defer scratch.deinit();
        const path = names.objectPath(scratch.allocator(), bucket_name, object_name, generation, .{}) catch return false;
        rpc.executeDiscard(self.client, .{ .method = .DELETE, .path = path }) catch |err| {
            logging.warn("deleting the truncated upload of {s} failed with {t}", .{ object_name, err });
            return false;
        };
        return true;
    }

    /// Cancels the session, unless the caller keeps failed sessions for a
    /// checkpoint and this failure is one a resume could get past.
    fn maybeCancel(self: *Machine, response: *std.heap.ArenaAllocator, session_uri: []const u8, err: Error) void {
        if (!self.cancel_on_failure and !checkpoint.uploadAbandons(err)) {
            logging.warn("the resumable upload failed with {t}; the session and checkpoint stay for a resume", .{err});
            return;
        }
        self.cancel(response, session_uri);
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

/// The final answer for an object of `size` bytes.
fn finishedAt(comptime size: u64) Reply {
    return .{ .respond = .{
        .status = 200,
        .body = std.fmt.comptimePrint("{{\"name\":\"backup.tar\",\"bucket\":\"b\",\"size\":\"{d}\",\"generation\":\"55\"}}", .{size}),
    } };
}

/// The final answer for the 600 KiB most tests upload.
const finished = finishedAt(600 * 1024);

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

test "a status query answered as a finalize is a truncated object, not a success" {
    // fake-gcs-server takes the empty PUT of a status query for a finalize
    // and finishes the object with what it holds: here the first chunk.
    var h: Harness = undefined;
    try h.init(&.{
        opened,
        kept(chunk_size - 1),
        .{ .fail = error.ConnectionResetByPeer },
        .{ .respond = .{ .status = 200, .body = "{\"name\":\"backup.tar\",\"size\":\"262144\",\"generation\":\"61\"}" } },
        // The cleanup delete.
        .{ .respond = .{ .status = 204, .body = "" } },
    }, resumableOptions());
    defer h.deinit();
    const data = try testData(testing.allocator, 600 * 1024);
    defer testing.allocator.free(data);

    try testing.expectError(error.InvalidResponse, h.client.bucket("b").object("backup.tar").upload(data, .{}));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "holding 262144 of its 614400 bytes; the truncated object was deleted again") != null);
    // The truncated object went again, pinned to the generation it got.
    const cleanup = try h.fake.request(0);
    try testing.expectEqual(.DELETE, cleanup.method);
    try testing.expectEqualStrings("https://storage.googleapis.com/storage/v1/b/b/o/backup.tar?generation=61", cleanup.url);
}

test "a finish before the stream has ended is not believed either" {
    // A reader of unknown size is still mid-stream when the server says
    // done, with a declared checksum, so no verification afterwards would
    // have caught it. The answer names no generation: nothing is safe to
    // delete, and nothing is.
    var h: Harness = undefined;
    try h.init(&.{
        opened,
        kept(chunk_size - 1),
        .{ .fail = error.ConnectionResetByPeer },
        .{ .respond = .{ .status = 200, .body = "{\"name\":\"backup.tar\"}" } },
    }, resumableOptions());
    defer h.deinit();
    const data = try testData(testing.allocator, 600 * 1024);
    defer testing.allocator.free(data);
    var reader: std.Io.Reader = .fixed(data);

    try testing.expectError(
        error.InvalidResponse,
        h.client.bucket("b").object("backup.tar").uploadFrom(&reader, .{ .crc32c = core.crc32c.hash(data) }),
    );
    try testing.expectEqualStrings("the server finished the upload before the stream ended", h.diag.message());
    try h.expectRequestCount(0);
    // The query that got the premature answer named no total.
    try testing.expectEqualStrings("bytes */*", (try h.fake.streamRequest(3)).header("Content-Range").?);
}

test "a finished object whose answer names no size is taken as whole" {
    // Emulators may leave fields out; a missing size is no evidence of a
    // truncated object, and a sound upload must not be deleted for it.
    var h: Harness = undefined;
    try h.init(&.{
        opened,
        kept(chunk_size - 1),
        kept(2 * chunk_size - 1),
        .{ .respond = .{ .status = 200, .body = "{\"name\":\"backup.tar\",\"generation\":\"62\"}" } },
    }, resumableOptions());
    defer h.deinit();
    const data = try testData(testing.allocator, 600 * 1024);
    defer testing.allocator.free(data);
    var info = try h.client.bucket("b").object("backup.tar").upload(data, .{});
    defer info.deinit();
    try testing.expectEqual(62, info.value.generation);
    try h.expectRequestCount(0);
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
    try h.init(&.{ opened, kept(chunk_size - 1), finishedAt(chunk_size) }, resumableOptions());
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
    try h.init(&.{ opened, finishedAt(0) }, resumableOptions());
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
        finishedAt(768 * 1024),
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
