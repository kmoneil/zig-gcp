//! Compressing on upload: the caller's data gzip-compressed by std's
//! compressor on its way up, as `gcloud storage cp -z` does, and handed to
//! the resumable machine as a `std.Io.Reader` of compressed bytes.
//!
//! The compressed bytes are checked as they are made: core's decompressor
//! reads them back, and what comes out must hash to what went in, with the
//! length and the gzip trailer's CRC-32 to match, before the stream ends.
//! The machine sends a chunk only once it has it whole, and it knows the
//! last chunk is the last only once this stream has ended, so no upload
//! can finish before the check has passed. std's compressor passed an
//! audit (half a million fuzzed inputs, byte-identical output however the
//! input arrives), but std's decompressor was found wrong the same week,
//! and a check that runs on every upload also covers whatever a later Zig
//! changes.
//!
//! std's compressor has traps this wrapper stays clear of: it and its
//! window must not move once in use, so the stream lives on the heap; its
//! writer panics, and in `ReleaseFast` writes past its window, when asked
//! for a long writable slice, so it is only ever fed with `writeAll`, from
//! this stream's own staging buffer, never by a caller's reader; it asserts
//! an output buffer longer than 8 bytes; a mid-stream flush changes the
//! bytes, so it is never flushed; and a failed write leaves it unusable, so
//! a rewind makes a new one.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const flate = std.compress.flate;
const core = @import("core");

const Client = @import("Client.zig");
const resumable = @import("resumable.zig");
const types = @import("types.zig");
const Error = @import("errors.zig").Error;

/// Where the data comes from.
pub const Input = union(enum) {
    /// The whole data in memory, read in place.
    slice: []const u8,
    /// A stream, read into the staging buffer a piece at a time.
    reader: Reader,
    /// A regular file, read at offsets into the staging buffer, in the
    /// same pieces every time, so a lost session, or a later process
    /// holding a checkpoint, can make the same bytes again.
    file: File,

    pub const File = struct {
        f: std.Io.File,
        /// The file's length, measured before the upload. A file that
        /// ends short of it changed under the upload.
        size: u64,
    };

    pub const Reader = struct {
        r: *std.Io.Reader,
        /// The size the caller declared, or null when unknown. A stream
        /// that ends early is `error.UnexpectedEndOfStream`, and one with
        /// more is `error.StreamTooLong`, as for an uncompressed upload.
        declared: ?u64,
    };
};

/// Input fed to the compressor at once, and the size of each buffer the
/// stream reads through.
const step_len = 64 * 1024;

/// What std writes first: no file name, no time, so that the same data at
/// the same level always compresses to the same bytes.
const gzip_header = flate.Container.gzip.header();

/// The options the object is stored with: the caller's, marked gzip. The
/// caller's `crc32c` names the data before compression, so it is checked
/// here and never sent as the object's.
pub fn storedOptions(options: types.UploadOptions) types.UploadOptions {
    var stored = options;
    stored.content_encoding = "gzip";
    stored.crc32c = null;
    stored.gzip = null;
    return stored;
}

/// Whether `content_type` names gzip itself, which Google advises against
/// alongside `Content-Encoding: gzip`: a client that decompresses would be
/// told it still holds gzip.
pub fn namesGzip(content_type: []const u8) bool {
    const media = std.mem.trim(u8, content_type[0 .. std.mem.indexOfScalar(u8, content_type, ';') orelse content_type.len], " \t");
    return std.ascii.eqlIgnoreCase(media, "application/gzip") or
        std.ascii.eqlIgnoreCase(media, "application/x-gzip");
}

/// The data compressed, as a reader of compressed bytes: `interface`. It
/// must not move once made, so it lives on the heap.
pub const Stream = struct {
    gpa: Allocator,
    io: std.Io,
    diagnostics: ?*core.Diagnostics,
    input: Input,
    options: flate.Compress.Options,
    /// Decompress what is made and compare it with what went in.
    check: bool,
    /// The caller's checksum of the data, checked when the data ends.
    expected: ?u32,

    /// How far into a slice or file input the compressor has read.
    slice_pos: u64 = 0,
    /// Bytes of data fed to the compressor.
    consumed: u64 = 0,
    data_hash: core.crc32c.Hasher = .init(),
    /// Every compressed byte made, which is every byte the reader gives:
    /// the request that finishes the upload carries it.
    compressed_hash: core.crc32c.Hasher = .init(),
    /// Compressed bytes made.
    produced: u64 = 0,
    /// The first bytes made: the gzip header, which the check holds to
    /// std's, so that every byte of the stream is checked.
    head: [gzip_header.len]u8 = undefined,
    /// Tests only: the compressed byte to flip as it is made, before it is
    /// hashed, as a compressor that went wrong would make it.
    flip_at: if (builtin.is_test) ?u64 else void = if (builtin.is_test) null else {},
    /// Tests only: a data offset whose piece the compressor never gets, as
    /// a compressor that lost a write would leave it: its trailer then
    /// agrees with what it made, and only the comparison with the data
    /// itself can tell.
    drop_at: if (builtin.is_test) ?u64 else void = if (builtin.is_test) null else {},
    /// What the check's decompressor gave back.
    checked: u64 = 0,
    check_hash: core.crc32c.Hasher = .init(),
    check_crc32: std.hash.Crc32 = .init(),
    /// The compressor has written its trailer.
    compressed_done: bool = false,
    /// Every check has passed; once `interface` has handed out the rest of
    /// the queue, it ends.
    ended: bool = false,
    /// Why the stream failed, for whoever reads it, which can only say
    /// `ReadFailed`.
    failure: ?Error = null,

    /// The compressor and every buffer: large, so kept apart, where a
    /// copy of the stream never takes them along.
    work: *Work,
    /// Compressed bytes as the compressor makes them. `interface` hands
    /// them out from `out_pos`, and the check reads them from `tap_pos`;
    /// what both have passed is dropped now and then.
    queue: std.Io.Writer.Allocating,
    /// Where the next compressed byte to hash sits in `queue`.
    hashed_to: usize = 0,
    out_pos: usize = 0,
    tap_pos: usize = 0,
    /// The check's decompressor, reading `tap`.
    inflate: core.flate.Decompress = undefined,
    tap: std.Io.Reader,
    /// The compressed bytes, for the resumable machine.
    interface: std.Io.Reader,

    const Work = struct {
        /// About 225 KiB, and it must not move once in use.
        compress: flate.Compress,
        window: [flate.max_window_len]u8,
        inflate_window: [core.flate.max_window_len]u8,
        /// A caller's stream is read into this, never into the compressor.
        staging: [step_len]u8,
        /// What the check decompresses into.
        scratch: [step_len]u8,
        tap_buffer: [16 * 1024]u8,
        out_buffer: [step_len]u8,
    };

    /// Makes a stream over `input` at `level` (1 to 9, checked by the
    /// caller), with the compressor's gzip header already made.
    pub fn create(client: *Client, input: Input, level: u4, expected: ?u32) Error!*Stream {
        const work = try client.gpa.create(Work);
        errdefer client.gpa.destroy(work);
        // More than the compressor's 8 bytes, and room for a block.
        var queue: std.Io.Writer.Allocating = try .initCapacity(client.gpa, step_len);
        errdefer queue.deinit();
        const s = try client.gpa.create(Stream);
        errdefer client.gpa.destroy(s);
        s.* = .{
            .gpa = client.gpa,
            .io = client.io,
            .diagnostics = client.diagnostics,
            .input = input,
            .options = levelOptions(level),
            .check = client.verify_checksums,
            .expected = expected,
            .work = work,
            .queue = queue,
            .tap = .{
                .vtable = &.{ .stream = Tap.stream, .readVec = Tap.readVec, .discard = Tap.discard },
                .buffer = &.{},
                .seek = 0,
                .end = 0,
            },
            .interface = .{
                .vtable = &.{ .stream = Out.stream, .readVec = Out.readVec, .discard = Out.discard },
                .buffer = &.{},
                .seek = 0,
                .end = 0,
            },
        };
        s.tap.buffer = &work.tap_buffer;
        s.interface.buffer = &work.out_buffer;
        try s.start();
        return s;
    }

    pub fn destroy(s: *Stream) void {
        s.queue.deinit();
        s.gpa.destroy(s.work);
        s.gpa.destroy(s);
    }

    /// Starts over from the data's first byte, for a lost session: a slice
    /// or a file can be read again, a caller's stream cannot.
    pub fn rewind(s: *Stream) Error!void {
        std.debug.assert(s.input != .reader);
        s.slice_pos = 0;
        s.consumed = 0;
        s.data_hash = .init();
        s.compressed_hash = .init();
        s.produced = 0;
        s.checked = 0;
        s.check_hash = .init();
        s.check_crc32 = .init();
        s.compressed_done = false;
        s.ended = false;
        s.failure = null;
        s.queue.clearRetainingCapacity();
        s.hashed_to = 0;
        s.out_pos = 0;
        s.tap_pos = 0;
        s.tap.seek = 0;
        s.tap.end = 0;
        s.interface.seek = 0;
        s.interface.end = 0;
        try s.start();
    }

    fn rewindOpaque(ctx: *anyopaque) Error!void {
        const s: *Stream = @ptrCast(@alignCast(ctx));
        return s.rewind();
    }

    /// For the resumable machine: how a lost session starts over, when the
    /// input can be read again.
    pub fn restart(s: *Stream) ?resumable.Source.Restart {
        return if (s.input != .reader) .{ .ctx = s, .rewind = rewindOpaque } else null;
    }

    fn start(s: *Stream) Error!void {
        // The header goes straight into the queue.
        s.work.compress = flate.Compress.init(&s.queue.writer, &s.work.window, .gzip, s.options) catch
            return error.OutOfMemory;
        s.inflate = .init(&s.tap, .gzip, &s.work.inflate_window);
        s.hashNew();
    }

    /// Reads the whole compressed stream into memory, checked: for an
    /// upload small enough to go in one request.
    pub fn readAll(s: *Stream) Error![]u8 {
        var body: std.ArrayList(u8) = .empty;
        errdefer body.deinit(s.gpa);
        while (true) {
            try body.ensureUnusedCapacity(s.gpa, step_len);
            const room = body.unusedCapacitySlice();
            const n = s.interface.readSliceShort(room) catch return s.failure orelse error.ReadFailed;
            body.items.len += n;
            if (n < room.len) break;
        }
        return body.toOwnedSlice(s.gpa);
    }

    /// Records why the stream failed, the first time, with its diagnostic.
    fn fail(s: *Stream, err: Error, comptime format: []const u8, args: anytype) error{Failed} {
        if (s.failure == null) {
            s.failure = err;
            if (s.diagnostics) |d| d.print(format, args);
        }
        return error.Failed;
    }

    /// The next piece of data, or nothing once it has ended.
    fn nextInput(s: *Stream) error{Failed}![]const u8 {
        switch (s.input) {
            .slice => |data| {
                const at: usize = @intCast(s.slice_pos);
                const piece = data[at..][0..@min(step_len, data.len - at)];
                s.slice_pos += piece.len;
                return piece;
            },
            .reader => |in| {
                var want: usize = step_len;
                if (in.declared) |declared| {
                    want = @intCast(@min(want, declared - s.consumed));
                    if (want == 0) {
                        // The declared size is reached: one more byte would
                        // be a lie.
                        var probe: [1]u8 = undefined;
                        const extra = in.r.readSliceShort(&probe) catch
                            return s.fail(error.ReadFailed, "the reader failed", .{});
                        if (extra != 0) return s.fail(error.StreamTooLong, "the reader has more than the declared {d} bytes", .{declared});
                        return &.{};
                    }
                }
                const n = in.r.readSliceShort(s.work.staging[0..want]) catch
                    return s.fail(error.ReadFailed, "the reader failed after {d} bytes", .{s.consumed});
                if (in.declared) |declared| if (n < want) {
                    return s.fail(error.UnexpectedEndOfStream, "the reader ended after {d} of the declared {d} bytes", .{ s.consumed + n, declared });
                };
                return s.work.staging[0..n];
            },
            .file => |in| {
                const offset = s.slice_pos;
                const want: usize = @intCast(@min(step_len, in.size - offset));
                const got = in.f.readPositionalAll(s.io, s.work.staging[0..want], offset) catch |err| switch (err) {
                    error.Canceled => return s.fail(error.Canceled, "canceled", .{}),
                    else => return s.fail(error.ReadFailed, "the file could not be read at byte {d}: {t}", .{ offset, err }),
                };
                if (got < want) return s.fail(
                    error.ReadFailed,
                    "the file ends at byte {d}, short of the {d} it had: it changed under the upload",
                    .{ offset + got, in.size },
                );
                s.slice_pos += want;
                return s.work.staging[0..want];
            },
        }
    }

    /// Feeds the compressor its next piece of data, or finishes it once
    /// the data has ended. The compressed bytes land in `queue`.
    fn pumpCompressor(s: *Stream) error{Failed}!void {
        std.debug.assert(!s.compressed_done);
        const piece = try s.nextInput();
        if (piece.len == 0) {
            // The queue is the compressor's output, and growing it is the
            // only thing that can fail.
            s.work.compress.finish() catch return s.fail(error.OutOfMemory, "out of memory compressing", .{});
            s.compressed_done = true;
        } else {
            const before = s.consumed;
            s.data_hash.update(piece);
            s.consumed += piece.len;
            if (builtin.is_test) if (s.drop_at) |at| if (at >= before and at < s.consumed) return s.hashNew();
            s.work.compress.writer.writeAll(piece) catch return s.fail(error.OutOfMemory, "out of memory compressing", .{});
        }
        s.hashNew();
    }

    /// Hashes what the compressor has added to the queue.
    fn hashNew(s: *Stream) void {
        const made = s.queue.written()[s.hashed_to..];
        if (builtin.is_test) if (s.flip_at) |at| if (at >= s.produced and at < s.produced + made.len) {
            made[@intCast(at - s.produced)] ^= 0x01;
        };
        if (s.produced < gzip_header.len) {
            const n = @min(made.len, gzip_header.len - s.produced);
            @memcpy(s.head[@intCast(s.produced)..][0..n], made[0..n]);
        }
        s.compressed_hash.update(made);
        s.produced += made.len;
        s.hashed_to += made.len;
    }

    /// Makes more compressed bytes: through the check, which decompresses
    /// what it reads and asks the compressor for more, or straight from
    /// the compressor when there is no check. Settles the checks once
    /// everything is made.
    fn advance(s: *Stream) error{Failed}!void {
        std.debug.assert(!s.ended);
        if (!s.check) {
            if (!s.compressed_done) return s.pumpCompressor();
            try s.settle();
            return;
        }
        const n = s.inflate.reader.readSliceShort(&s.work.scratch) catch {
            if (s.failure != null) return error.Failed;
            return s.fail(error.ChecksumMismatch, "the compressed bytes do not decompress ({t}); nothing was stored", .{s.inflate.err orelse error.ReadFailed});
        };
        s.check_hash.update(s.work.scratch[0..n]);
        s.check_crc32.update(s.work.scratch[0..n]);
        s.checked += n;
        // Short of the scratch buffer: the gzip stream has ended.
        if (n < s.work.scratch.len) try s.settle();
    }

    /// The end of the stream: every check, before the last byte goes out.
    fn settle(s: *Stream) error{Failed}!void {
        if (s.check) {
            // A stream that ended before the data did has bytes after it.
            while (!s.compressed_done) try s.pumpCompressor();
            const left = (s.tap.end - s.tap.seek) + (s.queue.written().len - s.tap_pos);
            if (left != 0) return s.fail(error.ChecksumMismatch, "the compressed stream ends {d} bytes early; nothing was stored", .{left});
            const data_crc = s.data_hash.final();
            const back_crc = s.check_hash.final();
            if (s.checked != s.consumed or back_crc != data_crc) return s.fail(
                error.ChecksumMismatch,
                "the compressed bytes decompress to {d} bytes hashing to {d}, not the data's {d} bytes hashing to {d}; nothing was stored",
                .{ s.checked, back_crc, s.consumed, data_crc },
            );
            if (!std.mem.eql(u8, &s.head, gzip_header)) return s.fail(
                error.ChecksumMismatch,
                "the compressed stream's gzip header is not the one std writes; nothing was stored",
                .{},
            );
            const trailer = s.inflate.container_metadata.gzip;
            if (trailer.crc != s.check_crc32.final() or trailer.count != @as(u32, @truncate(s.checked))) return s.fail(
                error.ChecksumMismatch,
                "the compressed stream's gzip trailer does not match its data; nothing was stored",
                .{},
            );
        }
        if (s.expected) |expected| {
            const data_crc = s.data_hash.final();
            if (data_crc != expected) return s.fail(
                error.ChecksumMismatch,
                "checksum mismatch before the finish: the data hashes to {d}, options.crc32c says {d}",
                .{ data_crc, expected },
            );
        }
        s.ended = true;
    }

    /// Drops what both readers of the queue have passed, once there is
    /// enough of it to be worth the copy.
    fn compact(s: *Stream) void {
        const low = if (s.check) @min(s.out_pos, s.tap_pos) else s.out_pos;
        const len = s.queue.written().len;
        if (low < step_len and low < len) return;
        const bytes = s.queue.written();
        std.mem.copyForwards(u8, bytes[0 .. len - low], bytes[low..len]);
        s.queue.shrinkRetainingCapacity(len - low);
        s.out_pos -= low;
        s.tap_pos -= @min(s.tap_pos, low);
        s.hashed_to -= low;
    }

    /// Copies from the queue at `pos.*` into `r`'s buffer, behind what is
    /// unread there. Returns whether anything came.
    fn serve(s: *Stream, r: *std.Io.Reader, pos: *usize) bool {
        if (r.seek > 0) {
            const unread = r.end - r.seek;
            std.mem.copyForwards(u8, r.buffer[0..unread], r.buffer[r.seek..r.end]);
            r.seek = 0;
            r.end = unread;
        }
        const avail = s.queue.written()[pos.*..];
        const n = @min(avail.len, r.buffer.len - r.end);
        if (n == 0) return false;
        @memcpy(r.buffer[r.end..][0..n], avail[0..n]);
        r.end += n;
        pos.* += n;
        return true;
    }

    /// The machine's reader: every vtable function fills the buffer
    /// itself, as `std.Io.Reader` allows.
    const Out = struct {
        fn stream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
            _ = w;
            _ = limit;
            try refill(r);
            return 0;
        }

        fn readVec(r: *std.Io.Reader, data: [][]u8) std.Io.Reader.Error!usize {
            _ = data;
            try refill(r);
            return 0;
        }

        fn discard(r: *std.Io.Reader, limit: std.Io.Limit) std.Io.Reader.Error!usize {
            try refill(r);
            const n = limit.minInt(r.end - r.seek);
            r.seek += n;
            return n;
        }

        fn refill(r: *std.Io.Reader) std.Io.Reader.Error!void {
            const s: *Stream = @alignCast(@fieldParentPtr("interface", r));
            if (r.end - r.seek == r.buffer.len) return;
            while (true) {
                if (s.serve(r, &s.out_pos)) {
                    s.compact();
                    return;
                }
                if (s.ended) return error.EndOfStream;
                s.advance() catch return error.ReadFailed;
            }
        }
    };

    /// The check's input: the queue from `tap_pos`, asking the compressor
    /// for more when it runs dry.
    const Tap = struct {
        fn stream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
            _ = w;
            _ = limit;
            try refill(r);
            return 0;
        }

        fn readVec(r: *std.Io.Reader, data: [][]u8) std.Io.Reader.Error!usize {
            _ = data;
            try refill(r);
            return 0;
        }

        fn discard(r: *std.Io.Reader, limit: std.Io.Limit) std.Io.Reader.Error!usize {
            try refill(r);
            const n = limit.minInt(r.end - r.seek);
            r.seek += n;
            return n;
        }

        fn refill(r: *std.Io.Reader) std.Io.Reader.Error!void {
            const s: *Stream = @alignCast(@fieldParentPtr("tap", r));
            if (r.end - r.seek == r.buffer.len) return;
            while (true) {
                if (s.serve(r, &s.tap_pos)) return;
                if (s.compressed_done) return error.EndOfStream;
                s.pumpCompressor() catch return error.ReadFailed;
            }
        }
    };
};

fn levelOptions(level: u4) flate.Compress.Options {
    return switch (level) {
        1 => .level_1,
        2 => .level_2,
        3 => .level_3,
        4 => .level_4,
        5 => .level_5,
        6 => .level_6,
        7 => .level_7,
        8 => .level_8,
        9 => .level_9,
        else => unreachable,
    };
}

/// Uploads the stream through the resumable protocol, one chunk buffer of
/// memory, with the compressed bytes' checksum on the finishing request.
pub fn uploadResumable(
    s: *Stream,
    client: *Client,
    bucket: []const u8,
    object: []const u8,
    options: types.UploadOptions,
) Error!types.Owned(types.ObjectInfo) {
    const buffer = try client.gpa.alloc(u8, client.chunk_size);
    defer client.gpa.free(buffer);
    return resumable.run(client, bucket, object, .{ .reader = .{
        .r = &s.interface,
        .buffer = buffer,
        .declared = null,
        .final_hash = if (s.check) &s.compressed_hash else null,
        .restart = s.restart(),
        .failure = &s.failure,
    } }, storedOptions(options), null) catch |err| switch (err) {
        error.ReadFailed => return s.failure orelse err,
        else => return err,
    };
}

const testing = std.testing;
const test_util = @import("test_util.zig");
const FakeMultipart = test_util.FakeMultipart;
const Object = @import("Object.zig");
const Diagnostics = core.Diagnostics;

const Setup = struct {
    fake: FakeMultipart,
    token: core.StaticToken,
    diag: Diagnostics,
    client: Client,

    const Options = struct {
        verify_checksums: bool = true,
        max_attempts: u8 = 4,
        /// Small, so a test's objects span several chunks.
        chunk_size: usize = 256 * 1024,
        single_request_limit: usize = 256 * 1024,
        gpa: Allocator = testing.allocator,
    };

    fn init(s: *Setup, options: Options) !void {
        s.fake = .init(options.gpa, testing.io);
        errdefer s.fake.deinit();
        s.token = .{ .token = "ya29.gzip-upload-test" };
        s.diag = .{};
        s.client = try .init(options.gpa, testing.io, .{
            .token_provider = s.token.provider(),
            .transport = s.fake.transport(),
            .diagnostics = &s.diag,
            .verify_checksums = options.verify_checksums,
            .chunk_size = options.chunk_size,
            .single_request_limit = options.single_request_limit,
            .retry = .{ .max_attempts = options.max_attempts, .initial_backoff_ms = 1, .max_backoff_ms = 2 },
        });
    }

    fn deinit(s: *Setup) void {
        s.client.deinit();
        s.fake.deinit();
    }

    fn object(s: *Setup, name: []const u8) Object {
        return s.client.bucket("b").object(name);
    }

    /// The stored object: gzip that decompresses to `plain`, labelled so,
    /// under the content type given, and described by `info`.
    fn expectStored(s: *Setup, name: []const u8, plain: []const u8, content_type: []const u8, info: types.ObjectInfo) !void {
        const o = s.fake.object(name) orelse return error.TestExpectedObject;
        try testing.expectEqualSlices(u8, plain, o.served orelse return error.TestExpectedGzipLabel);
        try testing.expectEqualStrings(content_type, o.content_type);
        try testing.expectEqualSlices(u8, gzip_header, o.bytes[0..gzip_header.len]);
        try testing.expectEqual(o.bytes.len, info.size);
        try testing.expectEqual(core.crc32c.hash(o.bytes), info.crc32c.?);
        try testing.expectEqualStrings("gzip", info.content_encoding.?);
    }
};

/// Faults for the resumable session's PUTs and the one-request insert, in
/// the order they arrive; the rest pass.
const UploadFaults = struct {
    faults: []const FakeMultipart.Fault,
    seen: usize = 0,

    fn plan(self: *UploadFaults) FakeMultipart.FaultPlan {
        return .{ .ctx = self, .decide = decide };
    }

    fn decide(ctx: ?*anyopaque, kind: FakeMultipart.Kind, part: u32) FakeMultipart.Fault {
        _ = part;
        const self: *UploadFaults = @ptrCast(@alignCast(ctx.?));
        if (kind != .session_put and kind != .insert) return .none;
        defer self.seen += 1;
        return if (self.seen < self.faults.len) self.faults[self.seen] else .none;
    }
};

/// Gives `data` a few bytes at a time, as a pipe or a socket might.
const Trickle = struct {
    data: []const u8,
    pos: usize = 0,
    max: usize,
    prng: std.Random.DefaultPrng,
    interface: std.Io.Reader,

    fn init(data: []const u8, max: usize, seed: u64) Trickle {
        return .{
            .data = data,
            .max = max,
            .prng = .init(seed),
            .interface = .{ .vtable = &.{ .stream = stream, .readVec = readVec }, .buffer = &.{}, .seek = 0, .end = 0 },
        };
    }

    /// 1 to `max` bytes, or none once the data has ended.
    fn next(self: *Trickle) usize {
        const left = self.data.len - self.pos;
        return @min(left, 1 + self.prng.random().uintLessThan(usize, self.max));
    }

    fn stream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *Trickle = @alignCast(@fieldParentPtr("interface", r));
        const n = limit.minInt(self.next());
        if (n == 0) return error.EndOfStream;
        try w.writeAll(self.data[self.pos..][0..n]);
        self.pos += n;
        return n;
    }

    fn readVec(r: *std.Io.Reader, data: [][]u8) std.Io.Reader.Error!usize {
        const self: *Trickle = @alignCast(@fieldParentPtr("interface", r));
        for (data) |dest| {
            if (dest.len == 0) continue;
            const n = @min(dest.len, self.next());
            if (n == 0) return error.EndOfStream;
            @memcpy(dest[0..n], self.data[self.pos..][0..n]);
            self.pos += n;
            return n;
        }
        return 0;
    }
};

fn randomBytes(gpa: Allocator, n: usize, seed: u64) ![]u8 {
    const data = try gpa.alloc(u8, n);
    var prng: std.Random.DefaultPrng = .init(seed);
    prng.random().bytes(data);
    return data;
}

/// Text that compresses, varied enough that it does not compress to
/// nothing.
fn textBytes(gpa: Allocator, n: usize, seed: u64) ![]u8 {
    const data = try gpa.alloc(u8, n);
    var prng: std.Random.DefaultPrng = .init(seed);
    const words = [_][]const u8{ "storage ", "bucket ", "object ", "gzip ", "chunk ", "session\n", "zig ", "upload " };
    var i: usize = 0;
    while (i < n) {
        const w = words[prng.random().uintLessThan(usize, words.len)];
        const k = @min(w.len, n - i);
        @memcpy(data[i..][0..k], w[0..k]);
        i += k;
    }
    return data;
}

test "gzip upload: small data goes in one request, compressed, labelled, and gives the data back" {
    var s: Setup = undefined;
    try s.init(.{});
    defer s.deinit();
    const plain = "a line of text that repeats\n" ** 300;
    var info = try s.object("notes.txt").upload(plain, .{ .content_type = "text/plain", .gzip = .{} });
    defer info.deinit();
    try s.expectStored("notes.txt", plain, "text/plain", info.value);
    try testing.expect(info.value.size < plain.len / 10);
    try testing.expectEqual(1, s.fake.counts.inserts);
    try testing.expectEqual(0, s.fake.counts.session_starts);

    // A download decompresses it again, verified.
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const result = try s.object("notes.txt").download(&out.writer, .{});
    try testing.expectEqualStrings(plain, out.written());
    try testing.expect(result.checksum_verified);
}

test "gzip upload: larger data goes up resumable, a chunk at a time" {
    var s: Setup = undefined;
    try s.init(.{});
    defer s.deinit();
    // Noise does not compress, so it spans several 256 KiB chunks.
    const plain = try randomBytes(testing.allocator, 900 * 1024, 1);
    defer testing.allocator.free(plain);
    var info = try s.object("noise.bin").upload(plain, .{ .gzip = .{ .level = 1 } });
    defer info.deinit();
    try s.expectStored("noise.bin", plain, "application/octet-stream", info.value);
    try testing.expectEqual(0, s.fake.counts.inserts);
    try testing.expectEqual(1, s.fake.counts.session_starts);
    try testing.expect(s.fake.counts.session_puts >= 4);
    try testing.expectEqual(0, s.fake.counts.session_stale_bytes);
}

test "gzip uploadFrom: a stream goes up resumable, whatever its size" {
    var s: Setup = undefined;
    try s.init(.{});
    defer s.deinit();
    for ([_]usize{ 0, 1, 5000, 700 * 1024 }, 0..) |n, i| {
        const plain = try textBytes(testing.allocator, n, i);
        defer testing.allocator.free(plain);
        var reader: std.Io.Reader = .fixed(plain);
        var info = try s.object("stream.txt").uploadFrom(&reader, .{
            .content_type = "text/plain; charset=utf-8",
            .size = n,
            .gzip = .{ .level = 9 },
        });
        defer info.deinit();
        try s.expectStored("stream.txt", plain, "text/plain; charset=utf-8", info.value);
    }
    try testing.expectEqual(0, s.fake.counts.inserts);
    try testing.expectEqual(4, s.fake.counts.session_starts);
}

test "gzip upload: every level gives the data back, and none sends a Content-Encoding header" {
    var s: Setup = undefined;
    try s.init(.{});
    defer s.deinit();
    const plain = try textBytes(testing.allocator, 40 * 1024, 7);
    defer testing.allocator.free(plain);
    // The fake refuses any request that carries one, so each passing
    // upload also shows none was sent.
    for (1..10) |level| {
        var small = try s.object("l").upload(plain, .{ .gzip = .{ .level = @intCast(level) } });
        defer small.deinit();
        try s.expectStored("l", plain, "application/octet-stream", small.value);
        var reader: std.Io.Reader = .fixed(plain);
        var streamed = try s.object("l").uploadFrom(&reader, .{ .gzip = .{ .level = @intCast(level) } });
        defer streamed.deinit();
        try s.expectStored("l", plain, "application/octet-stream", streamed.value);
    }
}

test "gzip upload: the same data at the same level stores the same bytes, however it arrives" {
    var s: Setup = undefined;
    try s.init(.{});
    defer s.deinit();
    const plain = try textBytes(testing.allocator, 600 * 1024, 11);
    defer testing.allocator.free(plain);
    var whole = try s.object("a").upload(plain, .{ .gzip = .{} });
    defer whole.deinit();
    // A reader that gives 1 to 7 bytes at a time.
    var trickle: Trickle = .init(plain, 7, 1);
    var streamed = try s.object("b").uploadFrom(&trickle.interface, .{ .gzip = .{} });
    defer streamed.deinit();
    try testing.expectEqualSlices(u8, s.fake.object("a").?.bytes, s.fake.object("b").?.bytes);
}

test "gzip upload: a corrupted chunk is refused at the finish, and the upload compresses again" {
    var s: Setup = undefined;
    try s.init(.{});
    defer s.deinit();
    const plain = try randomBytes(testing.allocator, 600 * 1024, 2);
    defer testing.allocator.free(plain);
    var faults: UploadFaults = .{ .faults = &.{.corrupt} };
    s.fake.faults = faults.plan();
    var info = try s.object("o").upload(plain, .{ .gzip = .{} });
    defer info.deinit();
    try s.expectStored("o", plain, "application/octet-stream", info.value);
    // The finishing checksum caught it: the session was cancelled and a
    // new one carried the upload.
    try testing.expectEqual(2, s.fake.counts.session_starts);
    try testing.expectEqual(1, s.fake.counts.session_cancels);
}

test "gzip uploadFrom: a corrupted chunk cancels the session, and a stream cannot start over" {
    var s: Setup = undefined;
    try s.init(.{});
    defer s.deinit();
    const plain = try randomBytes(testing.allocator, 600 * 1024, 3);
    defer testing.allocator.free(plain);
    var faults: UploadFaults = .{ .faults = &.{.corrupt} };
    s.fake.faults = faults.plan();
    var reader: std.Io.Reader = .fixed(plain);
    try testing.expectError(error.UploadSessionLost, s.object("o").uploadFrom(&reader, .{ .gzip = .{} }));
    try testing.expect(s.fake.object("o") == null);
    try testing.expectEqual(1, s.fake.counts.session_cancels);
}

test "gzip upload: transient failures are ridden out in both protocols" {
    var s: Setup = undefined;
    // Enough attempts for the faults before the first chunk lands.
    try s.init(.{ .max_attempts = 8 });
    defer s.deinit();
    const noise = try randomBytes(testing.allocator, 700 * 1024, 4);
    defer testing.allocator.free(noise);
    var faults: UploadFaults = .{ .faults = &.{ .unavailable, .reset, .lose_answer, .none, .unavailable } };
    s.fake.faults = faults.plan();
    var info = try s.object("noise").upload(noise, .{ .gzip = .{} });
    defer info.deinit();
    try s.expectStored("noise", noise, "application/octet-stream", info.value);

    // A one-request upload retries only when a repeat is safe.
    faults = .{ .faults = &.{.unavailable} };
    try testing.expectError(error.Unavailable, s.object("small").upload("small", .{ .gzip = .{} }));
    faults = .{ .faults = &.{.unavailable} };
    var safe = try s.object("small").upload("small", .{ .gzip = .{}, .preconditions = .does_not_exist });
    defer safe.deinit();
    try s.expectStored("small", "small", "application/octet-stream", safe.value);
}

test "gzip upload: options.crc32c names the data before compression, and a wrong one stores nothing" {
    var s: Setup = undefined;
    try s.init(.{});
    defer s.deinit();
    const small = "hello world\n";
    const large = try textBytes(testing.allocator, 2 * 1024 * 1024, 5);
    defer testing.allocator.free(large);
    for ([_][]const u8{ small, large }) |plain| {
        var right = try s.object("o").upload(plain, .{ .gzip = .{}, .crc32c = core.crc32c.hash(plain) });
        right.deinit();
        try testing.expectError(error.ChecksumMismatch, s.object("wrong").upload(plain, .{ .gzip = .{}, .crc32c = 1 }));
        try testing.expect(std.mem.indexOf(u8, s.diag.message(), "options.crc32c says 1") != null);
        try testing.expect(s.fake.object("wrong") == null);

        var reader: std.Io.Reader = .fixed(plain);
        try testing.expectError(error.ChecksumMismatch, s.object("wrong").uploadFrom(&reader, .{ .gzip = .{}, .crc32c = 1 }));
        try testing.expect(s.fake.object("wrong") == null);
    }
    // The large upload's sessions were cancelled, and the small one never
    // reached the server.
    try testing.expectEqual(1, s.fake.counts.inserts);
    try testing.expectEqual(s.fake.counts.session_starts - 1, s.fake.counts.session_cancels);
}

test "gzip upload: with verification off, a checksum the caller asserts is still checked here" {
    var s: Setup = undefined;
    try s.init(.{ .verify_checksums = false });
    defer s.deinit();
    const plain = try textBytes(testing.allocator, 300 * 1024, 6);
    defer testing.allocator.free(plain);
    var info = try s.object("o").upload(plain, .{ .gzip = .{} });
    defer info.deinit();
    try s.expectStored("o", plain, "application/octet-stream", info.value);
    try testing.expectError(error.ChecksumMismatch, s.object("o").upload(plain, .{ .gzip = .{}, .crc32c = 1 }));
}

test "gzip uploadFrom: a stream that contradicts its declared size stores nothing" {
    var s: Setup = undefined;
    try s.init(.{});
    defer s.deinit();
    const plain = try textBytes(testing.allocator, 500 * 1024, 8);
    defer testing.allocator.free(plain);
    var short: std.Io.Reader = .fixed(plain);
    try testing.expectError(error.UnexpectedEndOfStream, s.object("o").uploadFrom(&short, .{ .gzip = .{}, .size = plain.len + 1 }));
    var long: std.Io.Reader = .fixed(plain);
    try testing.expectError(error.StreamTooLong, s.object("o").uploadFrom(&long, .{ .gzip = .{}, .size = plain.len - 1 }));
    try testing.expect(s.fake.object("o") == null);
    try testing.expectEqual(s.fake.counts.session_starts, s.fake.counts.session_cancels);
}

test "gzip upload: a failing reader stores nothing" {
    var s: Setup = undefined;
    try s.init(.{});
    defer s.deinit();
    var failing: std.Io.Reader = .failing;
    try testing.expectError(error.ReadFailed, s.object("o").uploadFrom(&failing, .{ .gzip = .{} }));
    try testing.expect(s.fake.object("o") == null);
}

test "gzip upload: options that cannot go with compression are refused before sending" {
    var s: Setup = undefined;
    try s.init(.{});
    defer s.deinit();
    const obj = s.object("o");
    try testing.expectError(error.InvalidArgument, obj.upload("x", .{ .gzip = .{ .level = 0 } }));
    try testing.expect(std.mem.indexOf(u8, s.diag.message(), "gzip level 0") != null);
    try testing.expectError(error.InvalidArgument, obj.upload("x", .{ .gzip = .{ .level = 10 } }));
    try testing.expectError(error.InvalidArgument, obj.upload("x", .{ .gzip = .{}, .content_encoding = "gzip" }));
    for ([_][]const u8{ "application/gzip", "application/x-gzip", "Application/GZIP; charset=binary" }) |content_type| {
        try testing.expectError(error.InvalidArgument, obj.upload("x", .{ .gzip = .{}, .content_type = content_type }));
    }
    var reader: std.Io.Reader = .fixed("x");
    try testing.expectError(error.InvalidArgument, obj.uploadFrom(&reader, .{ .gzip = .{ .level = 10 } }));
    try testing.expectEqual(0, s.fake.counts.inserts + s.fake.counts.session_starts);
    // A type that only mentions gzip is the data's own.
    var info = try obj.upload("x", .{ .gzip = .{}, .content_type = "application/gzip-notes" });
    info.deinit();
}

/// A stream over `data` whose compressor makes a byte wrong: the check
/// must refuse it before it ends.
fn expectFlipCaught(data: []const u8, at: u64, check: bool) !void {
    var s: Setup = undefined;
    try s.init(.{ .verify_checksums = check });
    defer s.deinit();
    const stream = try Stream.create(&s.client, .{ .slice = data }, 6, null);
    defer stream.destroy();
    // The header is made with the stream: start over to flip it too.
    stream.flip_at = at;
    try stream.rewind();
    if (stream.readAll()) |body| {
        defer testing.allocator.free(body);
        // Only a stream that is not checked, or a byte past its end, gets
        // through.
        try testing.expect(!check or at >= body.len);
    } else |err| {
        try testing.expect(check);
        try testing.expectEqual(error.ChecksumMismatch, err);
        try testing.expect(std.mem.indexOf(u8, s.diag.message(), "nothing was stored") != null);
    }
}

test "gzip upload: a wrong byte in the header, the deflate data or the trailer is caught" {
    const plain = try textBytes(testing.allocator, 100 * 1024, 9);
    defer testing.allocator.free(plain);
    var s: Setup = undefined;
    try s.init(.{});
    defer s.deinit();
    const stream = try Stream.create(&s.client, .{ .slice = plain }, 6, null);
    defer stream.destroy();
    const good = try stream.readAll();
    defer testing.allocator.free(good);
    // A rewound stream makes exactly the same bytes again.
    try stream.rewind();
    const again = try stream.readAll();
    defer testing.allocator.free(again);
    try testing.expectEqualSlices(u8, good, again);
    // The header, the first and last deflate bytes, the trailer, and a
    // byte in the middle.
    for ([_]u64{ 0, 3, 4, 9, 10, good.len / 2, good.len - 9, good.len - 8, good.len - 5, good.len - 1 }) |at| {
        try expectFlipCaught(plain, at, true);
    }
    // Without the check, nothing looks.
    try expectFlipCaught(plain, good.len / 2, false);
}

test "gzip upload: a compressor that loses a write is caught, though its trailer agrees with what it made" {
    const plain = try textBytes(testing.allocator, 200 * 1024, 13);
    defer testing.allocator.free(plain);
    var s: Setup = undefined;
    try s.init(.{});
    defer s.deinit();
    const stream = try Stream.create(&s.client, .{ .slice = plain }, 6, null);
    defer stream.destroy();
    stream.drop_at = 70 * 1024;
    try testing.expectError(error.ChecksumMismatch, stream.readAll());
    try testing.expect(std.mem.indexOf(u8, s.diag.message(), "decompress to 139264 bytes") != null);
}

test "gzip upload: a flipped byte through upload stores nothing" {
    var s: Setup = undefined;
    try s.init(.{});
    defer s.deinit();
    const plain = try textBytes(testing.allocator, 3 * 1024 * 1024, 10);
    defer testing.allocator.free(plain);
    // Large, so it goes resumable; the byte flips in the second chunk.
    const stream = try Stream.create(&s.client, .{ .slice = plain }, 6, null);
    defer stream.destroy();
    stream.flip_at = 300 * 1024;
    try testing.expectError(error.ChecksumMismatch, uploadResumable(stream, &s.client, "b", "o", .{ .gzip = .{} }));
    try testing.expect(s.fake.object("o") == null);
    try testing.expectEqual(1, s.fake.counts.session_cancels);
}

fn uploadBoth(gpa: Allocator, plain: []const u8) !void {
    var s: Setup = undefined;
    try s.init(.{ .gpa = gpa });
    defer s.deinit();
    var small = try s.object("small").upload(plain[0 .. 100 * 1024], .{ .gzip = .{} });
    small.deinit();
    var large = try s.object("large").upload(plain, .{ .gzip = .{} });
    large.deinit();
    var reader: std.Io.Reader = .fixed(plain);
    var streamed = try s.object("streamed").uploadFrom(&reader, .{ .gzip = .{} });
    streamed.deinit();
}

test "gzip upload: every allocation failure is OutOfMemory, and nothing leaks" {
    const plain = try randomBytes(testing.allocator, 300 * 1024, 12);
    defer testing.allocator.free(plain);
    try testing.checkAllAllocationFailures(testing.allocator, uploadBoth, .{plain});
}

/// Data drawn from the fuzz input: text that compresses, noise that does
/// not, or long runs, `size` bytes of it.
fn drawData(g: *test_util.ByteGen, size: usize) ![]u8 {
    const seed = g.int(u64);
    return switch (g.intRange(u8, 0, 2)) {
        0 => textBytes(testing.allocator, size, seed),
        1 => randomBytes(testing.allocator, size, seed),
        else => blk: {
            const data = try testing.allocator.alloc(u8, size);
            var prng: std.Random.DefaultPrng = .init(seed);
            var i: usize = 0;
            while (i < size) {
                const run = @min(size - i, 1 + prng.random().uintLessThan(usize, 2000));
                @memset(data[i..][0..run], prng.random().int(u8));
                i += run;
            }
            break :blk data;
        },
    };
}

/// std's compressor, fed the same data one write at a time or in drawn
/// pieces, makes the same bytes: what resuming a compressed upload from a
/// checkpoint depends on. A Zig whose compressor breaks this fails here,
/// not in a resume.
fn sameBytesHoweverSplit(_: void, input: []const u8) !void {
    var g: test_util.ByteGen = .init(input);
    const level = g.intRange(u4, 1, 9);
    // Around the 32 KiB distance and the 64 KiB window, now and then.
    const size = if (g.boolean()) g.intRange(usize, 0, 4096) else g.intRange(usize, 30 * 1024, 140 * 1024);
    const data = try drawData(&g, size);
    defer testing.allocator.free(data);

    const whole = try test_util.gzipAlloc(testing.allocator, data, levelOptions(level));
    defer testing.allocator.free(whole);

    var out: std.Io.Writer.Allocating = try .initCapacity(testing.allocator, 64);
    defer out.deinit();
    const window = try testing.allocator.alloc(u8, flate.max_window_len);
    defer testing.allocator.free(window);
    var compress: flate.Compress = try .init(&out.writer, window, .gzip, levelOptions(level));
    var at: usize = 0;
    const max_piece = g.intRange(usize, 1, 70_000);
    while (at < data.len) {
        const n = @min(data.len - at, g.intRange(usize, 1, max_piece));
        try compress.writer.writeAll(data[at..][0..n]);
        at += n;
    }
    try compress.finish();
    try testing.expectEqualSlices(u8, whole, out.written());
}

// Compressing up to 140 KiB twice a run: too slow for the nightly "fuzz"
// and "slow property" filters, whose counts run into millions, so it runs
// with every test run, under that run's seed.
test "property gzip compress: std compresses the same data to the same bytes however it is split" {
    try test_util.fuzzBytes({}, sameBytesHoweverSplit, .{
        .random_runs = 40,
        .corpus = &.{
            "",
            // Level 9, 140 KiB of runs, one byte at a time.
            "\xff\x00\xff\xff\xff\xff\xff\xff\xff\xff\x07\x00\x00\x00\x00\x00\x00\x00\x02\x00\x00\x00\x00\x00\x00\x00\x00",
        },
    });
}

/// A compressor that gets any one byte wrong is caught before the stream
/// ends, whatever the data and level, unless the byte it got wrong makes
/// another encoding of the same data: a match one byte further back in a
/// run of one byte, say. The check promises that the stored bytes
/// decompress to the data, and that still holds, as a decompressor of its
/// own confirms here.
fn flipCaught(_: void, input: []const u8) !void {
    var g: test_util.ByteGen = .init(input);
    const level = g.intRange(u4, 1, 9);
    const data = try drawData(&g, g.intRange(usize, 0, 20 * 1024));
    defer testing.allocator.free(data);
    var s: Setup = undefined;
    try s.init(.{});
    defer s.deinit();
    const stream = try Stream.create(&s.client, .{ .slice = data }, level, null);
    defer stream.destroy();
    const good = try stream.readAll();
    defer testing.allocator.free(good);
    stream.flip_at = g.intRange(u64, 0, good.len - 1);
    try stream.rewind();
    const body = stream.readAll() catch |err| return testing.expectEqual(error.ChecksumMismatch, err);
    defer testing.allocator.free(body);
    try testing.expect(!std.mem.eql(u8, good, body));
    try expectGzipOf(data, body);
}

/// `body` is one gzip member, with std's header, that decompresses to
/// `data` and whose trailer says so.
fn expectGzipOf(data: []const u8, body: []const u8) !void {
    try testing.expectEqualSlices(u8, gzip_header, body[0..gzip_header.len]);
    var in: std.Io.Reader = .fixed(body);
    var window: [core.flate.max_window_len]u8 = undefined;
    var inflate: core.flate.Decompress = .init(&in, .gzip, &window);
    const back = try inflate.reader.allocRemaining(testing.allocator, .unlimited);
    defer testing.allocator.free(back);
    try testing.expectEqualSlices(u8, data, back);
    try testing.expectEqual(std.hash.Crc32.hash(data), inflate.container_metadata.gzip.crc);
    try testing.expectEqual(@as(u32, @truncate(data.len)), inflate.container_metadata.gzip.count);
    try testing.expectEqual(body.len, in.seek);
}

// Compressing up to 20 KiB twice a run, named out of the nightly filters
// for the same reason.
test "fault property gzip upload: a wrong compressed byte anywhere is caught, or still decompresses to the data" {
    try test_util.fuzzBytes({}, flipCaught, .{
        .random_runs = 100,
        .corpus = &.{
            "",
            "\x05\x00\x00\x00\x00\x00\x00\x00\x00\x00",
            // Runs, where a flip in a match's distance made another
            // encoding of the same data: found 2026-09-26 by seed 0x7777.
            "\xe3\x63\xa8\x80\xb3\xd2\x1e\x3f\x71\xdb\x30\x62\x38\xdd\x78\x78\xbc\x4a\xad\x4d\xdd\x8e\xde\x59\xf6\x88\x6a\x99\xbe\x9c\x6a\xf1\x1b\xd0\xde\xef\x76\x30\x16\x81",
        },
    });
}

/// The fuzzer's own bytes as the data, at a level drawn from the first:
/// the stream gives one gzip member with std's header that decompresses to
/// them, and the check passes it.
fn anyDataRoundTrips(_: void, input: []const u8) !void {
    const level: u4 = if (input.len == 0) 6 else @intCast(input[0] % 9 + 1);
    var s: Setup = undefined;
    try s.init(.{});
    defer s.deinit();
    const stream = try Stream.create(&s.client, .{ .slice = input }, level, core.crc32c.hash(input));
    defer stream.destroy();
    const body = try stream.readAll();
    defer testing.allocator.free(body);
    try expectGzipOf(input, body);
    try testing.expectEqual(core.crc32c.hash(body), stream.compressed_hash.final());
}

// About 1.5 ms a run under the fuzz runner, so millions of nightly runs
// would take hours: named out of the nightly filters, and run with every
// test run under that run's seed.
test "property gzip upload: any bytes compress to gzip of themselves, checked" {
    try test_util.fuzzBytes({}, anyDataRoundTrips, .{
        .corpus = &.{ "", "\x00", "\x09aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "\x05the quick brown fox jumps over the lazy dog" },
    });
}

/// Any data, any level, chunk size and path, under drawn faults the
/// upload can ride out: the object stored is gzip that decompresses to
/// the data, and says so.
fn uploadUnderFaults(input: []const u8) !void {
    var g: test_util.ByteGen = .init(input);
    const level = g.intRange(u4, 1, 9);
    const size = g.intRange(usize, 0, 700 * 1024);
    const data = try drawData(&g, size);
    defer testing.allocator.free(data);
    const chunk = g.intRange(usize, 1, 2) * 256 * 1024;
    const from_stream = g.boolean();
    // Up to four faults, which a client with eight attempts rides out.
    var drawn: [4]FakeMultipart.Fault = undefined;
    const choices = [_]FakeMultipart.Fault{ .none, .unavailable, .reset, .lose_answer, .corrupt };
    for (&drawn) |*f| f.* = g.pick(FakeMultipart.Fault, &choices);

    var s: Setup = undefined;
    try s.init(.{ .chunk_size = chunk, .max_attempts = 8 });
    defer s.deinit();
    var faults: UploadFaults = .{ .faults = &drawn };
    s.fake.faults = faults.plan();
    // A one-request upload retries only when a repeat is safe.
    const options: types.UploadOptions = .{ .gzip = .{ .level = level }, .preconditions = .does_not_exist };
    var reader: std.Io.Reader = .fixed(data);
    const outcome = if (from_stream) s.object("o").uploadFrom(&reader, options) else s.object("o").upload(data, options);
    const corrupted = std.mem.indexOfScalar(FakeMultipart.Fault, &drawn, .corrupt) != null;
    var info = outcome catch |err| switch (err) {
        // A stream cannot start over after a corrupted chunk.
        error.UploadSessionLost => return testing.expect(from_stream and corrupted),
        // A corrupted chunk refused at the finish, and that answer lost:
        // the status query, which carries no checksum, finishes the
        // session, and the object is checked, found wrong and deleted.
        error.ChecksumMismatch => {
            try testing.expect(corrupted);
            try testing.expect(s.fake.object("o") == null);
            return;
        },
        // A lost answer to a create-only request can leave the object
        // behind for the repeat to find.
        error.FailedPrecondition => return testing.expect(std.mem.indexOfScalar(FakeMultipart.Fault, &drawn, .lose_answer) != null),
        else => {
            std.debug.print("{t}: {s}\n", .{ err, s.diag.message() });
            return err;
        },
    };
    defer info.deinit();
    try s.expectStored("o", data, "application/octet-stream", info.value);
}

fn uploadUnderFaultsProperty(_: void, input: []const u8) !void {
    try uploadUnderFaults(input);
}

// Compressing up to 700 KiB in Debug on every run: too slow for the nightly
// "fuzz" filters, like the other fault properties.
test "fault property gzip upload: any data, any level, under faults, is stored as gzip of the data" {
    try test_util.fuzzBytes({}, uploadUnderFaultsProperty, .{
        .random_runs = 40,
        .max_len = 64,
        .corpus = &.{
            "",
            // Noise at level 1, 700 KiB, from a stream, a corrupt chunk.
            "\x01\xff\xff\xff\xff\xff\xff\xff\xff\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x04\x04\x04\x04",
            // A corrupted chunk refused at the finish, the answer to the
            // repeat lost, and the hashless status query finishing the
            // corrupt session: found 2026-09-26.
            "\xb9\xd4\xbb\x89\x52\x27\x38\x19\xa5\x6d\x0f\x2e\x67\x74\xcf\xb5\x45\xc7\x99\xe3\xc5\xc6\x37\x5e\xeb\x59\xac\xeb\x7d\x82\x07\x12\x01\x54\x14\x50\xd3\xd6\x94\x2b\xa0\x08\xc8\xaa\x7b\x1c\x80\x3b\x0c\xdc\x95\xd5",
        },
    });
}
