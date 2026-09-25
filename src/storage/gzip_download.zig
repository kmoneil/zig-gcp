//! Objects stored gzip-compressed (`Content-Encoding: gzip`), downloaded as
//! Cloud Storage stores them and decompressed here. Cloud Storage would
//! decompress them on the way instead, and then there is nothing to verify,
//! since the stored CRC32C covers the compressed bytes, and nothing to
//! resume, since it ignores a range while it decompresses.
//!
//! The transport pushes a response into a writer, and std's decompressor
//! pulls from a reader, and a decompressor must outlive any one request to
//! carry on across a resume. So the stored bytes are pulled: `Tap` takes the
//! first response's head, and for a gzip object its first chunk of stored
//! bytes; `Pull` serves them and then the rest in ranges of `chunk_size`,
//! pinned to the generation; `finish` decompresses them into the caller's
//! writer, and holds the stored bytes to the checksum the first head named.

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("core");

const Client = @import("Client.zig");
const dl = @import("download.zig");
const logging = @import("logging.zig");
const names = @import("names.zig");
const rpc = @import("rpc.zig");
const types = @import("types.zig");
const Error = @import("errors.zig").Error;
const Head = core.transport.StreamRequest.Head;

/// The writer a download's first response goes to: at the first byte it
/// reads the head, and passes a plain body on, collects a gzip object's
/// stored bytes, or refuses a body it must not take.
pub const Tap = struct {
    /// Where a body to pass on goes.
    forward: *std.Io.Writer,
    /// The response head, which the transport fills before any body byte.
    head: *const ?Head,
    gpa: Allocator,
    chunk_size: usize,
    decompress: bool,
    /// The caller asked for a range.
    ranged: bool,
    mode: Mode = .undecided,
    /// A gzip object's stored bytes from byte 0, once `mode` is `.gzip`:
    /// `chunk_size` long, and owned.
    buffer: []u8 = &.{},
    collected: usize = 0,
    /// The buffer filled before the body ended; the rest comes in ranges.
    full: bool = false,
    out_of_memory: bool = false,
    writer: std.Io.Writer,

    pub const Mode = enum {
        undecided,
        /// Bytes to pass on as they come: a plain object, a gzip object's
        /// stored bytes kept as they are, or a body decompressed on the way.
        plain,
        /// A gzip object's stored bytes, to decompress here.
        gzip,
        /// A plain object that came gzip-compressed on its way: asked for
        /// again, plainly.
        compressed_in_transit,
        /// A range of a gzip object, which no decompressor can start from.
        ranged_gzip,
    };

    pub fn init(forward: *std.Io.Writer, head: *const ?Head, gpa: Allocator, chunk_size: usize, decompress: bool, ranged: bool) Tap {
        return .{
            .forward = forward,
            .head = head,
            .gpa = gpa,
            .chunk_size = chunk_size,
            .decompress = decompress,
            .ranged = ranged,
            .writer = .{ .buffer = &.{}, .vtable = &.{ .drain = drain } },
        };
    }

    pub fn deinit(self: *Tap) void {
        if (self.buffer.len > 0) self.gpa.free(self.buffer);
    }

    /// Settles `mode` from the head, once. A body that never wrote a byte
    /// is settled after the response.
    pub fn decide(self: *Tap) void {
        if (self.mode != .undecided) return;
        const h = self.head.* orelse {
            self.mode = .plain;
            return;
        };
        if (!headerIs(h, "content-encoding", "gzip")) {
            self.mode = .plain;
            return;
        }
        self.mode = if (!headerIs(h, "x-goog-stored-content-encoding", "gzip"))
            .compressed_in_transit
        else if (!self.decompress)
            .plain
        else if (self.ranged)
            .ranged_gzip
        else
            .gzip;
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *Tap = @alignCast(@fieldParentPtr("writer", w));
        self.decide();
        switch (self.mode) {
            .plain => return self.forward.writeSplatHeader(w.buffered(), data, splat),
            .gzip => {
                if (self.buffer.len == 0) {
                    self.buffer = self.gpa.alloc(u8, self.chunk_size) catch {
                        self.out_of_memory = true;
                        return error.WriteFailed;
                    };
                }
                var consumed: usize = 0;
                for (data, 0..) |bytes, i| {
                    const repeats = if (i == data.len - 1) splat else 1;
                    for (0..repeats) |_| {
                        const n = @min(bytes.len, self.buffer.len - self.collected);
                        @memcpy(self.buffer[self.collected..][0..n], bytes[0..n]);
                        self.collected += n;
                        consumed += n;
                        if (n < bytes.len) {
                            // One chunk is all this holds; the rest comes in
                            // ranges, and this connection is abandoned.
                            self.full = true;
                            if (consumed > 0) return consumed;
                            return error.WriteFailed;
                        }
                    }
                }
                return consumed;
            },
            .compressed_in_transit, .ranged_gzip => return error.WriteFailed,
            .undecided => unreachable,
        }
    }
};

fn headerIs(h: Head, name: []const u8, value: []const u8) bool {
    const got = h.header(name) orelse return false;
    return std.ascii.eqlIgnoreCase(std.mem.trim(u8, got, " \t"), value);
}

/// The stored bytes of a gzip object as a `std.Io.Reader`: the first chunk
/// the tap collected, then ranges of a buffer's length, each fetched when
/// the buffer runs dry and hashed as it arrives. Every vtable function fills
/// the buffer itself, as `std.Io.Reader` allows.
const Pull = struct {
    client: *Client,
    bucket: []const u8,
    name: []const u8,
    generation: ?u64,
    /// The stored length, when a head said.
    total: ?u64,
    /// Stored bytes in the buffer or already read: the next range starts here.
    fetched: u64,
    hasher: core.crc32c.Hasher = .init(),
    /// Why the last fetch failed, for whoever reads through the
    /// decompressor, which can only say `ReadFailed`.
    failure: ?Error = null,
    interface: std.Io.Reader,

    fn init(client: *Client, bucket: []const u8, name: []const u8, generation: ?u64, total: ?u64, buffer: []u8, collected: usize) Pull {
        var pull: Pull = .{
            .client = client,
            .bucket = bucket,
            .name = name,
            .generation = generation,
            .total = total,
            .fetched = collected,
            .interface = .{
                .vtable = &.{ .stream = stream, .readVec = readVec, .discard = discard },
                .buffer = buffer,
                .seek = 0,
                .end = collected,
            },
        };
        pull.hasher.update(buffer[0..collected]);
        return pull;
    }

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

    /// Moves what is unread to the front, and fetches the next range behind
    /// it.
    fn refill(r: *std.Io.Reader) std.Io.Reader.Error!void {
        const self: *Pull = @alignCast(@fieldParentPtr("interface", r));
        if (self.total) |t| if (self.fetched >= t) return error.EndOfStream;
        if (r.seek > 0) {
            const unread = r.end - r.seek;
            std.mem.copyForwards(u8, r.buffer[0..unread], r.buffer[r.seek..r.end]);
            r.seek = 0;
            r.end = unread;
        }
        const room = r.buffer.len - r.end;
        if (room == 0) return;
        const want: usize = if (self.total) |t| @intCast(@min(room, t - self.fetched)) else room;
        const got = self.fetchInto(r.buffer[r.end..][0..want]) catch |err| {
            self.failure = err;
            return error.ReadFailed;
        };
        if (got == 0) return error.EndOfStream;
        self.hasher.update(r.buffer[r.end..][0..got]);
        r.end += got;
        self.fetched += got;
    }

    /// The stored bytes from `fetched` on into `dest`, as one range pinned to
    /// the generation. A dropped connection keeps what arrived and asks for
    /// the rest; the attempts run down only while nothing arrives. Fewer
    /// bytes than asked means the object ended there.
    fn fetchInto(self: *Pull, dest: []u8) Error!usize {
        const client = self.client;
        var response: std.heap.ArenaAllocator = .init(client.gpa);
        defer response.deinit();
        var got: usize = 0;
        var attempt: u32 = 1;
        while (got < dest.len) : (attempt += 1) {
            _ = response.reset(.retain_capacity);
            const start = self.fetched + got;
            const path = try names.objectMediaPath(response.allocator(), self.bucket, self.name, self.generation, .{});
            var range_buf: [64]u8 = undefined;
            const headers = [_]core.transport.Header{.{ .name = "Range", .value = dl.formatRange(&range_buf, start, start + (dest.len - got) - 1) }};
            var sink: std.Io.Writer = .fixed(dest[got..]);
            const before = got;
            const outcome = rpc.executeStream(client, &response, .{
                .method = .GET,
                .path = path,
                .headers = &headers,
                .sink = .{ .writer = &sink },
                .accept_encoding = .gzip_as_sent,
                // Resuming is this loop's business.
                .retry = false,
            });
            got += sink.end;
            if (outcome) |res| {
                if (res.status != 206) {
                    if (client.diagnostics) |d| d.print("the server ignored the range request and answered {d}", .{res.status});
                    return error.InvalidResponse;
                }
                if (res.header("Content-Range")) |value| {
                    if (dl.contentRangeStart(value)) |at| if (at != start) {
                        if (client.diagnostics) |d| d.print("the range starts at byte {d}, not the requested {d}", .{ at, start });
                        return error.InvalidResponse;
                    };
                }
                if (!std.ascii.eqlIgnoreCase(res.header("content-encoding") orelse "", "gzip")) {
                    if (client.diagnostics) |d| d.print("a range of {s} came decompressed, not as stored", .{self.name});
                    return error.InvalidResponse;
                }
                // Short of what was asked: the object ends here.
                if (got < dest.len) return got;
                continue;
            } else |err| switch (err) {
                // A range starting past the end: the object ended before it.
                error.OutOfRange => {
                    if (client.diagnostics) |d| d.clear();
                    return got;
                },
                // More bytes than the range holds.
                error.WriteFailed => {
                    if (client.diagnostics) |d| d.print("a range of {s} was longer than asked for", .{self.name});
                    return error.InvalidResponse;
                },
                else => |e| {
                    if (got > before) attempt = 0;
                    if (!core.isRetryable(e) or attempt >= client.retry.max_attempts) return e;
                    const delay_ms = rpc.backoffMs(client, attempt);
                    logging.warn("GET {s} (stored gzip bytes) failed with {t}; resuming at byte {d} in {d} ms", .{ self.name, e, self.fetched + got, delay_ms });
                    try client.io.sleep(.fromMilliseconds(delay_ms), .awake);
                },
            }
        }
        return got;
    }
};

/// The rest of a gzip object's download, once the tap has its first chunk
/// of stored bytes. `first_error` is how the first response ended, if it
/// did not end whole: it is returned when nothing more can be fetched.
pub fn finish(
    client: *Client,
    bucket: []const u8,
    name: []const u8,
    writer: *std.Io.Writer,
    tap: *Tap,
    first_error: ?Error,
    generation: ?u64,
    whole_crc: ?u32,
) Error!types.DownloadResult {
    if (tap.out_of_memory) return error.OutOfMemory;
    const head = tap.head.*.?;
    // A first response that ended whole holds every stored byte.
    const total: ?u64 = if (first_error == null and !tap.full) tap.collected else if (head.header("x-goog-stored-content-length")) |text|
        std.fmt.parseInt(u64, text, 10) catch null
    else if (head.header("content-length")) |text|
        std.fmt.parseInt(u64, text, 10) catch null
    else
        null;
    const more = if (total) |t| tap.collected < t else true;
    if (more and generation == null) {
        if (client.diagnostics) |d| d.print("cannot fetch the rest of {s}: the server named no generation to pin it to", .{name});
        return first_error orelse error.InvalidResponse;
    }
    if (tap.buffer.len == 0) tap.buffer = try tap.gpa.alloc(u8, tap.chunk_size);

    var pull: Pull = .init(client, bucket, name, generation, total, tap.buffer, tap.collected);
    const window = try client.gpa.alloc(u8, std.compress.flate.max_window_len);
    defer client.gpa.free(window);
    var counting: core.CountingWriter = .init(writer);
    var hashing: std.Io.Writer.Hashed(core.crc32c.Hasher) = .initHasher(&counting.writer, .init(), &.{});

    // Every member, as `gzip -d` decompresses them; bytes after the last
    // that start no member are ignored, as `gzip -d` ignores them.
    var decompress_error: ?anyerror = null;
    while (true) {
        var inflate: std.compress.flate.Decompress = .init(&pull.interface, .gzip, window);
        // std reads each member's trailer, its CRC-32 and length, and checks
        // neither (Zig 0.16.0), so they are checked here, as `gzip -d` does:
        // with verification off, they are all that stands between a flipped
        // byte and the caller.
        var member_count: core.CountingWriter = .init(&hashing.writer);
        var member_crc: std.Io.Writer.Hashed(std.hash.Crc32) = .initHasher(&member_count.writer, .init(), &.{});
        _ = inflate.reader.streamRemaining(&member_crc.writer) catch |err| switch (err) {
            error.WriteFailed => return error.WriteFailed,
            error.ReadFailed => {
                if (pull.failure) |f| return f;
                decompress_error = inflate.err orelse error.ReadFailed;
                break;
            },
        };
        const trailer = inflate.container_metadata.gzip;
        if (trailer.crc != member_crc.hasher.final()) {
            decompress_error = error.WrongGzipChecksum;
            break;
        }
        if (trailer.count != @as(u32, @truncate(member_count.count))) {
            decompress_error = error.WrongGzipSize;
            break;
        }
        const next = pull.interface.peek(2) catch |err| switch (err) {
            error.EndOfStream => break,
            error.ReadFailed => return pull.failure orelse error.ReadFailed,
        };
        if (next[0] != 0x1f or next[1] != 0x8b) {
            logging.warn("{s}: bytes after its last gzip member ignored, as gzip -d ignores them", .{name});
            break;
        }
    }
    // The rest of the stored bytes is hashed too, so the check covers every
    // one of them.
    while (true) {
        pull.interface.tossBuffered();
        pull.interface.fillMore() catch |err| switch (err) {
            error.EndOfStream => break,
            error.ReadFailed => return pull.failure orelse error.ReadFailed,
        };
    }

    var verified = false;
    if (client.verify_checksums) {
        if (whole_crc) |expected| {
            const got = pull.hasher.final();
            if (got != expected) {
                if (client.diagnostics) |d| d.print(
                    "checksum mismatch: {d} stored bytes hash to {d}, the server said {d}; discard what the writer holds",
                    .{ pull.fetched, got, expected },
                );
                return error.ChecksumMismatch;
            }
            verified = true;
        } else logging.warn("download of {s} carried no crc32c to verify against", .{name});
    }
    if (decompress_error) |err| {
        if (client.diagnostics) |d| d.print(
            "{s} says Content-Encoding: gzip, and its stored bytes do not decompress ({t}); decompress = false downloads them as they are",
            .{ name, err },
        );
        return error.DecompressionFailed;
    }
    if (total) |t| if (pull.fetched < t) {
        if (client.diagnostics) |d| d.print("{s} ended at stored byte {d}, short of its length {d}", .{ name, pull.fetched, t });
        return error.InvalidResponse;
    };
    return .{
        .bytes_written = counting.count,
        .generation = generation orelse 0,
        .checksum_verified = verified,
        .crc32c = hashing.hasher.final(),
        .stored_bytes = pull.fetched,
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
        gpa: std.mem.Allocator = testing.allocator,
    };

    fn init(s: *Setup, options: Options) !void {
        s.fake = .init(options.gpa, testing.io);
        errdefer s.fake.deinit();
        s.token = .{ .token = "ya29.gzip-test" };
        s.diag = .{};
        s.client = try .init(options.gpa, testing.io, .{
            .token_provider = s.token.provider(),
            .transport = s.fake.transport(),
            .diagnostics = &s.diag,
            .verify_checksums = options.verify_checksums,
            .chunk_size = options.chunk_size,
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
};

/// Faults for media reads, in the order the reads arrive; the rest pass.
const MediaFaults = struct {
    faults: []const FakeMultipart.Fault,
    seen: usize = 0,

    fn plan(self: *MediaFaults) FakeMultipart.FaultPlan {
        return .{ .ctx = self, .decide = decide };
    }

    fn decide(ctx: ?*anyopaque, kind: FakeMultipart.Kind, part: u32) FakeMultipart.Fault {
        _ = part;
        const self: *MediaFaults = @ptrCast(@alignCast(ctx.?));
        if (kind != .media) return .none;
        defer self.seen += 1;
        return if (self.seen < self.faults.len) self.faults[self.seen] else .none;
    }
};

fn randomBytes(gpa: Allocator, n: usize, seed: u64) ![]u8 {
    const data = try gpa.alloc(u8, n);
    var prng: std.Random.DefaultPrng = .init(seed);
    prng.random().bytes(data);
    return data;
}

test "gzip: an object stored gzip-compressed comes as stored, is verified, and is decompressed here" {
    var s: Setup = undefined;
    try s.init(.{});
    defer s.deinit();
    const plain = "a line of text that repeats\n" ** 200;
    try s.fake.putGzipped("page.txt", plain);
    const stored = s.fake.object("page.txt").?.bytes;
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const result = try s.object("page.txt").download(&out.writer, .{});
    try testing.expectEqualStrings(plain, out.written());
    try testing.expect(result.checksum_verified);
    try testing.expectEqual(plain.len, result.bytes_written);
    try testing.expectEqual(stored.len, result.stored_bytes);
    try testing.expectEqual(core.crc32c.hash(plain), result.crc32c);
    // It fit in one chunk: one request.
    try testing.expectEqual(1, s.fake.counts.media);
}

test "gzip: decompress = false writes the stored bytes, verified" {
    var s: Setup = undefined;
    try s.init(.{});
    defer s.deinit();
    try s.fake.putGzipped("page.txt", "kept compressed\n" ** 100);
    const stored = s.fake.object("page.txt").?.bytes;
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const result = try s.object("page.txt").download(&out.writer, .{ .decompress = false });
    try testing.expectEqualSlices(u8, stored, out.written());
    try testing.expect(result.checksum_verified);
    try testing.expectEqual(stored.len, result.bytes_written);
    try testing.expectEqual(stored.len, result.stored_bytes);
    try testing.expectEqual(core.crc32c.hash(stored), result.crc32c);
}

test "gzip: past one chunk, the rest comes in ranges pinned to the generation" {
    var s: Setup = undefined;
    try s.init(.{});
    defer s.deinit();
    // Random bytes do not compress: the stored object is about as long.
    const plain = try randomBytes(testing.allocator, 700 * 1024, 1);
    defer testing.allocator.free(plain);
    try s.fake.putGzipped("big.bin", plain);
    const stored_len = s.fake.object("big.bin").?.bytes.len;
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const result = try s.object("big.bin").download(&out.writer, .{});
    try testing.expectEqualSlices(u8, plain, out.written());
    try testing.expect(result.checksum_verified);
    try testing.expectEqual(stored_len, result.stored_bytes);
    // The first request's first chunk, then two ranges of a chunk or less.
    try testing.expectEqual(3, s.fake.counts.media);
}

test "gzip: cut connections resume at a stored offset, and the decompressor never sees them" {
    const plain = try randomBytes(testing.allocator, 1536 * 1024, 2);
    defer testing.allocator.free(plain);
    // A range cut halfway, asked for again from where it stopped; then a
    // first response cut before its chunk was full.
    for ([_]struct { chunk: usize, faults: []const FakeMultipart.Fault }{
        .{ .chunk = 256 * 1024, .faults = &.{ .none, .cut } },
        .{ .chunk = 1024 * 1024, .faults = &.{ .cut, .cut } },
    }) |case| {
        var s: Setup = undefined;
        try s.init(.{ .chunk_size = case.chunk });
        defer s.deinit();
        try s.fake.putGzipped("big.bin", plain);
        var faults: MediaFaults = .{ .faults = case.faults };
        s.fake.faults = faults.plan();
        var out: std.Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        const result = s.object("big.bin").download(&out.writer, .{}) catch |err| {
            std.debug.print("{t}: {s}\n", .{ err, s.diag.message() });
            return err;
        };
        try testing.expectEqualSlices(u8, plain, out.written());
        try testing.expect(result.checksum_verified);
        try testing.expect(faults.seen > case.faults.len);
    }
}

test "gzip: a stored byte flipped on the way is caught, with checking on or off" {
    const plain = "the object's text, compressed\n" ** 50;
    // On, the stored bytes miss the stored checksum; off, gzip's own
    // checksum of what it decompressed misses, and the bytes do not pass.
    for ([_]struct { verify: bool, want: Error }{
        .{ .verify = true, .want = error.ChecksumMismatch },
        .{ .verify = false, .want = error.DecompressionFailed },
    }) |case| {
        var s: Setup = undefined;
        try s.init(.{ .verify_checksums = case.verify });
        defer s.deinit();
        try s.fake.putGzipped("page.txt", plain);
        var faults: MediaFaults = .{ .faults = &.{.corrupt} };
        s.fake.faults = faults.plan();
        var out: std.Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        try testing.expectError(case.want, s.object("page.txt").download(&out.writer, .{}));
    }
}

test "gzip: a member whose trailer lies is DecompressionFailed, checking on or off, though std's decompressor would pass it" {
    // Valid deflate for "hello world\n", with the trailer's CRC-32, then its
    // length, one off. The stored bytes are what is stored, so the stored
    // checksum holds; only the trailer says anything is wrong.
    const good = "\x1f\x8b\x08\x00\x00\x00\x00\x00\x02\xff\xcb\x48\xcd\xc9\xc9\x57\x28\xcf\x2f\xca\x49\xe1\x02\x00\x2d\x3b\x08\xaf\x0c\x00\x00\x00";
    var bad_crc = good.*;
    bad_crc[good.len - 8] ^= 0x01;
    var bad_size = good.*;
    bad_size[good.len - 4] ^= 0x01;
    for ([_][]const u8{ &bad_crc, &bad_size }) |stored| {
        for ([_]bool{ true, false }) |verify| {
            var s: Setup = undefined;
            try s.init(.{ .verify_checksums = verify });
            defer s.deinit();
            try s.fake.putGzip("lying", stored, "hello world\n");
            var out: std.Io.Writer.Allocating = .init(testing.allocator);
            defer out.deinit();
            try testing.expectError(error.DecompressionFailed, s.object("lying").download(&out.writer, .{}));
        }
    }
    // std's own decompressor, asked directly, takes the lie.
    var in: std.Io.Reader = .fixed(&bad_crc);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var inflate: std.compress.flate.Decompress = .init(&in, .gzip, &window);
    var buf: [32]u8 = undefined;
    const n = try inflate.reader.readSliceShort(&buf);
    try testing.expectEqualStrings("hello world\n", buf[0..n]);
}

test "gzip: an object that says gzip and is not fails with DecompressionFailed, and decompress = false downloads it" {
    var s: Setup = undefined;
    try s.init(.{});
    defer s.deinit();
    try s.fake.putGzip("mislabelled", "these bytes were never gzip", "what a transcoder would make of them");
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try testing.expectError(error.DecompressionFailed, s.object("mislabelled").download(&out.writer, .{}));
    try testing.expect(std.mem.indexOf(u8, s.diag.message(), "do not decompress") != null);
    try testing.expect(std.mem.indexOf(u8, s.diag.message(), "decompress = false") != null);

    var raw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer raw.deinit();
    const result = try s.object("mislabelled").download(&raw.writer, .{ .decompress = false });
    try testing.expectEqualStrings("these bytes were never gzip", raw.written());
    try testing.expect(result.checksum_verified);
}

test "gzip: a range decompresses nothing, so it is refused; decompress = false serves the stored bytes" {
    var s: Setup = undefined;
    try s.init(.{});
    defer s.deinit();
    try s.fake.putGzipped("page.txt", "ranged text\n" ** 100);
    const stored = s.fake.object("page.txt").?.bytes;
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try testing.expectError(error.InvalidArgument, s.object("page.txt").download(&out.writer, .{ .range = .{ .offset = 10, .length = 20 } }));
    try testing.expect(std.mem.indexOf(u8, s.diag.message(), "decompress = false") != null);
    try testing.expectEqual(0, out.written().len);

    const result = try s.object("page.txt").download(&out.writer, .{ .range = .{ .offset = 10, .length = 20 }, .decompress = false });
    try testing.expectEqualSlices(u8, stored[10..30], out.written());
    try testing.expect(!result.checksum_verified);
}

test "gzip: a bomb stops at downloadAlloc's cap, which counts decompressed bytes" {
    var s: Setup = undefined;
    try s.init(.{});
    defer s.deinit();
    const zeros = try testing.allocator.alloc(u8, 10 * 1024 * 1024);
    defer testing.allocator.free(zeros);
    @memset(zeros, 0);
    try s.fake.putGzipped("bomb", zeros);
    try testing.expect(s.fake.object("bomb").?.bytes.len < 64 * 1024);
    try testing.expectError(error.ObjectTooLarge, s.object("bomb").downloadAlloc(1024 * 1024, .{}));
}

test "gzip: every member decompresses, as gzip -d does, and bytes after the last are ignored" {
    var s: Setup = undefined;
    try s.init(.{});
    defer s.deinit();
    const first = try test_util.gzipAlloc(testing.allocator, "first member, ", .default);
    defer testing.allocator.free(first);
    const second = try test_util.gzipAlloc(testing.allocator, "second member\n", .best);
    defer testing.allocator.free(second);
    const stored = try std.mem.concat(testing.allocator, u8, &.{ first, second, "\x00\x00\x00" });
    defer testing.allocator.free(stored);
    try s.fake.putGzip("members.txt", stored, "first member, second member\n");
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const result = try s.object("members.txt").download(&out.writer, .{});
    try testing.expectEqualStrings("first member, second member\n", out.written());
    try testing.expect(result.checksum_verified);
    try testing.expectEqual(stored.len, result.stored_bytes);
}

test "gzip: a plain object compressed on its way is asked for again, plainly" {
    const plain = "hello world\n";
    const compressed = "\x1f\x8b\x08\x00\x00\x00\x00\x00\x02\xff\xcb\x48\xcd\xc9\xc9\x57\x28\xcf\x2f\xca\x49\xe1\x02\x00\x2d\x3b\x08\xaf\x0c\x00\x00\x00";
    var h: test_util.Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .status = 200, .body = compressed, .headers = &.{
            .{ .name = "Content-Encoding", .value = "gzip" },
            .{ .name = "x-goog-generation", .value = "4" },
        } } },
        .{ .respond = .{ .status = 200, .body = plain, .headers = &.{
            .{ .name = "x-goog-generation", .value = "4" },
            .{ .name = "x-goog-hash", .value = "crc32c=8P9ykg==" },
        } } },
    }, .{});
    defer h.deinit();
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const result = try h.client.bucket("b").object("o").download(&out.writer, .{});
    try testing.expectEqualStrings(plain, out.written());
    try testing.expect(result.checksum_verified);
    try testing.expectEqual(.gzip_as_sent, (try h.fake.streamRequest(0)).accept_encoding);
    try testing.expectEqual(.identity, (try h.fake.streamRequest(1)).accept_encoding);
}

test "gzip: a range that comes decompressed, or whole, is refused rather than decompressed" {
    const compressed = "\x1f\x8b\x08\x00\x00\x00\x00\x00\x02\xff\xcb\x48\xcd\xc9\xc9\x57\x28\xcf\x2f\xca\x49\xe1\x02\x00\x2d\x3b\x08\xaf\x0c\x00\x00\x00";
    const first: test_util.FakeTransport.Reply = .{ .respond = .{
        .status = 200,
        .body = compressed,
        .cut_after = 10,
        .headers = &.{
            .{ .name = "Content-Encoding", .value = "gzip" },
            .{ .name = "x-goog-stored-content-encoding", .value = "gzip" },
            .{ .name = "x-goog-stored-content-length", .value = "32" },
            .{ .name = "x-goog-generation", .value = "4" },
        },
    } };
    // The first response is cut ten stored bytes in; the rest is asked for
    // as a range, and the answer is not one this can decompress from.
    for ([_]test_util.FakeTransport.Reply{
        .{ .respond = .{ .status = 206, .body = "llo world\n", .headers = &.{.{ .name = "Content-Range", .value = "bytes 10-31/32" }} } },
        .{ .respond = .{ .status = 200, .body = compressed, .headers = &.{.{ .name = "Content-Encoding", .value = "gzip" }} } },
    }) |second| {
        var h: test_util.Harness = undefined;
        try h.init(&.{ first, second }, .{});
        defer h.deinit();
        var out: std.Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        try testing.expectError(error.InvalidResponse, h.client.bucket("b").object("o").download(&out.writer, .{}));
        try testing.expectEqualStrings("bytes=10-31", (try h.fake.streamRequest(1)).header("Range").?);
        try testing.expect(std.mem.indexOf(u8, (try h.fake.streamRequest(1)).url, "generation=4") != null);
    }
}

fn downloadGzip(gpa: Allocator, stored: []const u8, plain: []const u8) !void {
    var s: Setup = undefined;
    try s.init(.{ .gpa = gpa });
    defer s.deinit();
    try s.fake.putGzip("big.bin", stored, plain);
    // A writer that only fails when the download misbehaves: a growing one
    // could only report its own allocations failing as WriteFailed.
    const out_buf = try gpa.alloc(u8, plain.len);
    defer gpa.free(out_buf);
    var out: std.Io.Writer = .fixed(out_buf);
    const result = try s.object("big.bin").download(&out, .{});
    try testing.expect(result.checksum_verified);
    try testing.expectEqualSlices(u8, plain, out.buffered());
}

test "gzip: every allocation failure is OutOfMemory, and nothing leaks" {
    const plain = try randomBytes(testing.allocator, 300 * 1024, 3);
    defer testing.allocator.free(plain);
    const stored = try test_util.gzipAlloc(testing.allocator, plain, .fastest);
    defer testing.allocator.free(stored);
    try testing.checkAllAllocationFailures(testing.allocator, downloadGzip, .{ stored, plain });
}

/// Any bytes, compressible or not, gzipped at any level, served under drawn
/// transient faults and chunk sizes: they come back exactly, verified.
fn roundTripUnderFaults(input: []const u8) !void {
    var g: test_util.ByteGen = .init(input);
    const size = g.intRange(usize, 0, 600 * 1024);
    const chunk = g.intRange(usize, 1, 3) * 256 * 1024;
    const levels = [_]std.compress.flate.Compress.Options{ .level_1, .level_4, .level_6, .level_9 };
    const level = levels[g.intRange(usize, 0, levels.len - 1)];
    const compressible = g.boolean();
    const plain = try testing.allocator.alloc(u8, size);
    defer testing.allocator.free(plain);
    var prng: std.Random.DefaultPrng = .init(g.int(u64));
    if (compressible) {
        for (plain, 0..) |*b, i| b.* = "the quick brown fox "[i % 20] +% @as(u8, @intFromBool(prng.random().uintLessThan(u8, 16) == 0));
    } else prng.random().bytes(plain);
    const stored = try test_util.gzipAlloc(testing.allocator, plain, level);
    defer testing.allocator.free(stored);
    // Up to three faults a download rides out: they deliver progress or
    // spend at most three of the four attempts.
    var drawn: [3]FakeMultipart.Fault = undefined;
    const choices = [_]FakeMultipart.Fault{ .none, .cut, .reset, .unavailable };
    for (&drawn) |*f| f.* = choices[g.intRange(usize, 0, choices.len - 1)];

    var s: Setup = undefined;
    try s.init(.{ .chunk_size = chunk });
    defer s.deinit();
    try s.fake.putGzip("o", stored, plain);
    var faults: MediaFaults = .{ .faults = &drawn };
    s.fake.faults = faults.plan();
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const result = s.object("o").download(&out.writer, .{}) catch |err| {
        std.debug.print("{t}: {s}\n", .{ err, s.diag.message() });
        return err;
    };
    try testing.expectEqualSlices(u8, plain, out.written());
    try testing.expect(result.checksum_verified);
    try testing.expectEqual(stored.len, result.stored_bytes);
}

fn roundTripProperty(_: void, input: []const u8) !void {
    try roundTripUnderFaults(input);
}

// Compressing up to 600 KiB in Debug on every run: too slow for the nightly
// "fuzz" filters, like the other fault properties.
test "fault property gzip download: any bytes, any level, cut anywhere, come back exact and verified" {
    try test_util.fuzzBytes({}, roundTripProperty, .{
        .random_runs = 40,
        .max_len = 64,
        .corpus = &.{
            "",
            // 600 KiB of text at level 9, a range cut, 256 KiB chunks.
            "\xff\xff\xff\xff\xff\xff\xff\xff\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x03\x01",
        },
    });
}

/// Any stored bytes under a gzip label: they decompress, or the download
/// fails with DecompressionFailed; never a crash, and never another error.
fn anyStoredBytes(_: void, input: []const u8) !void {
    var s: Setup = undefined;
    try s.init(.{});
    defer s.deinit();
    try s.fake.putGzip("o", input, "unused");
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    if (s.object("o").download(&out.writer, .{})) |result| {
        try testing.expect(result.checksum_verified);
        try testing.expectEqual(input.len, result.stored_bytes);
    } else |err| try testing.expectEqual(error.DecompressionFailed, err);
}

test "fuzz gzip: any stored bytes decompress or fail with DecompressionFailed" {
    try test_util.fuzzBytes({}, anyStoredBytes, .{
        .corpus = &.{
            "",
            "\x1f\x8b",
            "not gzip at all",
            // gzip -n of "hello world\n".
            "\x1f\x8b\x08\x00\x00\x00\x00\x00\x02\xff\xcb\x48\xcd\xc9\xc9\x57\x28\xcf\x2f\xca\x49\xe1\x02\x00\x2d\x3b\x08\xaf\x0c\x00\x00\x00",
            // Two members.
            "\x1f\x8b\x08\x00\x00\x00\x00\x00\x02\xff\x4b\xcb\x2c\x2a\x2e\x51\x00\x00\xfc\x7a\xf1\x1c\x06\x00\x00\x00\x1f\x8b\x08\x00\x00\x00\x00\x00\x02\xff\x2b\x4e\x4d\xce\xcf\x4b\xe1\x02\x00\x7e\xc0\x0f\x06\x07\x00\x00\x00",
        },
    });
}

test "gzip over real sockets: a gzip object in ranges, through the built-in transport" {
    const io = testing.io;
    var fake: FakeMultipart = .init(testing.allocator, io);
    defer fake.deinit();
    var server: test_util.MultipartServer = try .start(io, &fake);
    defer server.deinit(io);
    var serving = try io.concurrent(test_util.MultipartServer.run, .{ &server, io });
    defer _ = serving.cancel(io) catch {};
    var diag: Diagnostics = .{};
    var url_buf: [64]u8 = undefined;
    var client: Client = try .init(testing.allocator, io, .{
        .endpoint = .{ .url = server.url(&url_buf), .emulator = true },
        .diagnostics = &diag,
        .chunk_size = 256 * 1024,
        .retry = .{ .max_attempts = 4, .initial_backoff_ms = 1, .max_backoff_ms = 2 },
    });
    defer client.deinit();
    const plain = try randomBytes(testing.allocator, 700 * 1024, 4);
    defer testing.allocator.free(plain);
    try fake.putGzipped("dir/over sockets.bin", plain);
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const result = client.bucket("b").object("dir/over sockets.bin").download(&out.writer, .{}) catch |err| {
        std.debug.print("{t}: {s}\n", .{ err, diag.message() });
        return err;
    };
    try testing.expectEqualSlices(u8, plain, out.written());
    try testing.expect(result.checksum_verified);
    try testing.expectEqual(3, fake.counts.media);
}
