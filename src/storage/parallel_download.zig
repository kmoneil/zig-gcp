//! Parallel downloads: one object fetched as ranges, `concurrency` at a
//! time, each on a client and connection of its own, and written at its
//! offset in a file or a buffer.
//!
//! The flow: check the options; read the object's metadata, which names
//! its size, generation, CRC32C and content encoding; size the
//! destination; fetch every range with `Object.download`, pinned to that
//! generation, so a range resumes where a dropped connection left it and an
//! overwrite partway through fails with `error.NotFound` instead of
//! splicing two objects; fold the ranges' CRC32Cs into the whole object's,
//! and hold that to the metadata's.
//!
//! An empty object is not read at all, since an empty range is a 416. An
//! object stored gzip-compressed is fetched whole by one worker, as
//! `download` fetches it: Cloud Storage ignores a range while it
//! decompresses. A file is checked afterwards to be exactly the object's
//! length. Linux puts every write to a file opened for appending at its
//! end, whatever the offset, and the checksum, which covers the bytes as
//! they arrived, would never notice them landing out of place.

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("core");

const Client = @import("Client.zig");
const Object = @import("Object.zig");
const logging = @import("logging.zig");
const mp = @import("xml_multipart.zig");
const types = @import("types.zig");
const Error = @import("errors.zig").Error;
const Diagnostics = core.Diagnostics;

pub const max_concurrency = 64;

/// Google sets no floor for a range. Below this one, a range costs more in
/// its request than it gains.
pub const min_range_size: u64 = 1024 * 1024;

/// What each worker writes a file through.
const file_buffer_len = 64 * 1024;

/// Downloads `object` into `destination`. The caller has begun the call
/// and checked both names.
pub fn download(
    client: *Client,
    bucket: []const u8,
    object: []const u8,
    destination: types.ParallelDestination,
    options: types.ParallelDownloadOptions,
) Error!types.DownloadResult {
    try check(client, options);
    const source: Object = .{ .client = client, .bucket = bucket, .name = object };
    var info = try source.get(.{ .generation = options.generation, .preconditions = options.preconditions });
    defer info.deinit();
    const size = info.value.size;
    const generation = info.value.generation;
    if (size > mp.max_object_size or generation == 0) {
        if (client.diagnostics) |d| d.print(
            "the object's metadata names {d} bytes at generation {d}; Cloud Storage stores at most 5 TiB, and always names a generation",
            .{ size, generation },
        );
        return error.InvalidResponse;
    }
    if (info.value.content_encoding) |encoding| if (std.ascii.eqlIgnoreCase(encoding, "gzip")) {
        return whole(client, bucket, object, destination, generation, options);
    };

    switch (destination) {
        .buffer => |buffer| if (buffer.len < size) {
            if (client.diagnostics) |d| d.print("the object is {d} bytes, and the buffer holds {d}", .{ size, buffer.len });
            return error.ObjectTooLarge;
        },
        .file => |file| try setLength(client.io, client.diagnostics, file, size),
    }
    var crc: u32 = 0;
    if (size > 0) {
        const plan = mp.plan(size, options.part_size);
        logging.debug("parallel download of {s}: {d} bytes in {d} ranges of {d}", .{ object, size, plan.parts, plan.part_size });
        const crcs = try client.gpa.alloc(u32, plan.parts);
        defer client.gpa.free(crcs);
        var run: Run = .{
            .client = client,
            .bucket = bucket,
            .object = object,
            .generation = generation,
            .destination = destination,
            .plan = plan,
            .crcs = crcs,
        };
        try run.fetchRanges(options);
        // Every range is in. Their checksums fold into the whole's.
        for (crcs, 0..) |range_crc, i| crc = core.crc32c.combine(crc, range_crc, plan.len(@intCast(i)));
    }
    if (destination == .file) try checkLength(client.io, client.diagnostics, destination.file, size);

    const expected: ?u32 = if (client.verify_checksums) info.value.crc32c else null;
    if (expected) |wanted| if (wanted != crc) {
        if (client.diagnostics) |d| d.print(
            "checksum mismatch: the ranges hash to {d}, the object's metadata says {d}; discard what the destination holds",
            .{ crc, wanted },
        );
        return error.ChecksumMismatch;
    };
    if (client.verify_checksums and expected == null) {
        logging.warn("parallel download of {s} carried no crc32c to verify against", .{object});
    }
    return .{ .bytes_written = size, .generation = generation, .checksum_verified = expected != null, .crc32c = crc };
}

/// Refuses what no download could use, before anything is sent.
pub fn check(client: *const Client, options: types.ParallelDownloadOptions) Error!void {
    const d = client.diagnostics;
    const floor = client.multipart_test.min_part_size orelse min_range_size;
    if (options.part_size < floor) {
        return refuse(d, "part_size: at least {d} bytes, not {d}", .{ floor, options.part_size });
    }
    if (options.concurrency < 1 or options.concurrency > max_concurrency) {
        return refuse(d, "concurrency: 1 to {d}, not {d}", .{ max_concurrency, options.concurrency });
    }
}

fn refuse(d: ?*Diagnostics, comptime format: []const u8, args: anytype) Error {
    if (d) |diag| diag.print(format, args);
    return error.InvalidParallelDownloadOptions;
}

/// A gzip-stored object, fetched whole by one worker as `download` fetches
/// it: decompressed and unverified, since the stored checksum covers the
/// compressed bytes, and in one request, since offsets into the
/// decompressed bytes mean nothing to the server.
fn whole(
    client: *Client,
    bucket: []const u8,
    object: []const u8,
    destination: types.ParallelDestination,
    generation: u64,
    options: types.ParallelDownloadOptions,
) Error!types.DownloadResult {
    logging.debug("parallel download of {s}: stored gzip-compressed, so fetched whole", .{object});
    var w: Worker = undefined;
    try w.init(client, options.part_timeout_ms, destination == .file);
    defer w.deinit(client.gpa);
    return w.fetchWhole(client.io, bucket, object, destination, generation) catch |err| {
        if (client.diagnostics) |d| d.* = w.diag;
        return err;
    };
}

/// Sets a file destination's length, refusing a file that has none to set,
/// such as a pipe or a device.
fn setLength(io: std.Io, d: ?*Diagnostics, file: std.Io.File, len: u64) Error!void {
    file.setLength(io, len) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => {
            if (d) |diag| diag.print("the file could not be set to {d} bytes: {t}; a parallel download writes a regular file at offsets", .{ len, err });
            return error.WriteFailed;
        },
    };
}

/// Holds a file destination to the length it should have, which a file
/// opened for appending never keeps.
fn checkLength(io: std.Io, d: ?*Diagnostics, file: std.Io.File, wanted: u64) Error!void {
    const got = file.length(io) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => {
            if (d) |diag| diag.print("the file's length could not be read back: {t}", .{err});
            return error.WriteFailed;
        },
    };
    if (got != wanted) {
        if (d) |diag| diag.print(
            "the file is {d} bytes after the download, not {d}: it was opened for appending, or written by someone else, so its bytes are not where they belong",
            .{ got, wanted },
        );
        return error.WriteFailed;
    }
}

/// One download in flight: what every worker shares.
const Run = struct {
    client: *Client,
    bucket: []const u8,
    object: []const u8,
    generation: u64,
    destination: types.ParallelDestination,
    plan: mp.Plan,
    /// Each range's CRC32C, written by the worker that fetched it.
    crcs: []u32,
    mutex: std.Io.Mutex = .init,
    /// The next range to fetch, from 0.
    next: u32 = 0,
    /// The first failure, with the details of the worker that met it.
    failure: ?Failure = null,

    const Failure = struct {
        err: Error,
        diag: Diagnostics,
    };

    /// Fetches every range: `concurrency` workers, each with a client of
    /// its own, on tasks of their own, or one on this task when the
    /// `std.Io` cannot run tasks concurrently.
    fn fetchRanges(run: *Run, options: types.ParallelDownloadOptions) Error!void {
        const gpa = run.client.gpa;
        const io = run.client.io;
        const count: usize = @min(options.concurrency, run.plan.parts);
        const workers = try gpa.alloc(Worker, count);
        defer gpa.free(workers);
        var made: usize = 0;
        defer for (workers[0..made]) |*w| w.deinit(gpa);
        for (workers) |*w| {
            try w.init(run.client, options.part_timeout_ms, run.destination == .file);
            made += 1;
        }

        var group: std.Io.Group = .init;
        var spawned: usize = 0;
        for (workers) |*w| {
            group.concurrent(io, Worker.main, .{ w, run }) catch |err| switch (err) {
                error.ConcurrencyUnavailable => break,
            };
            spawned += 1;
        }
        if (spawned == 0) {
            // Slower, and otherwise the same.
            try Worker.main(&workers[0], run);
        } else {
            // A cancel while waiting reaches every worker too; when they
            // have all returned, so does this.
            try group.await(io);
        }
        if (run.failure) |failure| {
            if (run.client.diagnostics) |d| d.* = failure.diag;
            return failure.err;
        }
    }

    /// The next range to fetch, or null once there is none or one failed.
    fn take(run: *Run) ?u32 {
        const io = run.client.io;
        run.mutex.lockUncancelable(io);
        defer run.mutex.unlock(io);
        if (run.failure != null or run.next == run.plan.parts) return null;
        defer run.next += 1;
        return run.next;
    }

    /// Records the first failure; the other workers stop after the range
    /// they are fetching.
    fn fail(run: *Run, err: Error, diag: *const Diagnostics) void {
        const io = run.client.io;
        run.mutex.lockUncancelable(io);
        defer run.mutex.unlock(io);
        if (run.failure == null) run.failure = .{ .err = err, .diag = diag.* };
    }
};

/// One of the tasks fetching ranges, with a client and a connection of its
/// own.
const Worker = struct {
    client: Client,
    diag: Diagnostics,
    /// For a file: what the worker's ranges are written through.
    buffer: ?[]u8,

    fn init(w: *Worker, client: *Client, timeout_ms: u32, file: bool) Error!void {
        w.diag = .{};
        w.client = try client.sibling(&w.diag);
        errdefer w.client.deinit();
        w.client.request_timeout_ms = timeout_ms;
        w.buffer = if (file) try client.gpa.alloc(u8, file_buffer_len) else null;
    }

    fn deinit(w: *Worker, gpa: Allocator) void {
        if (w.buffer) |b| gpa.free(b);
        w.client.deinit();
    }

    /// Fetches ranges until there are none left or one has failed. Every
    /// failure goes to the run, a cancel included: a group swallows the
    /// `Canceled` its task returns, and a run that recorded nothing would
    /// fold checksums of ranges never fetched.
    fn main(w: *Worker, run: *Run) error{Canceled}!void {
        while (run.take()) |index| {
            w.fetch(run, index) catch |err| {
                run.fail(err, &w.diag);
                if (err == error.Canceled) return error.Canceled;
                return;
            };
        }
    }

    /// Fetches range `index` into its place, and keeps its CRC32C.
    fn fetch(w: *Worker, run: *Run, index: u32) Error!void {
        const offset = run.plan.offset(index);
        const len = run.plan.len(index);
        const source: Object = .{ .client = &w.client, .bucket = run.bucket, .name = run.object };
        const options: types.DownloadOptions = .{
            .generation = run.generation,
            .range = .{ .offset = offset, .length = len },
        };
        const result = switch (run.destination) {
            .buffer => |buffer| b: {
                var fixed: std.Io.Writer = .fixed(buffer[@intCast(offset)..][0..@intCast(len)]);
                var bounded: Bounded = .init(&fixed, len);
                break :b source.download(&bounded.writer, options) catch |err|
                    return w.rangeFailed(run, index, err, bounded.over, null);
            },
            .file => |file| f: {
                // Positional: this writer's offset is its own, whatever the
                // other workers write.
                var file_writer = file.writer(run.client.io, w.buffer.?);
                file_writer.pos = offset;
                var bounded: Bounded = .init(&file_writer.interface, len);
                const got = source.download(&bounded.writer, options) catch |err|
                    return w.rangeFailed(run, index, err, bounded.over, &file_writer);
                file_writer.interface.flush() catch return w.writeFailed(&file_writer);
                break :f got;
            },
        };
        if (result.bytes_written != len) {
            w.diag.print("range {d}: {d} bytes from byte {d} were asked for, and {d} arrived", .{ index + 1, len, offset, result.bytes_written });
            return error.InvalidResponse;
        }
        run.crcs[index] = result.crc32c;
    }

    /// A gzip-stored object, whole: into the buffer as far as it goes, or
    /// into the file from its start, emptied first, so a file opened for
    /// appending takes every byte where it belongs too.
    fn fetchWhole(
        w: *Worker,
        io: std.Io,
        bucket: []const u8,
        object: []const u8,
        destination: types.ParallelDestination,
        generation: u64,
    ) Error!types.DownloadResult {
        const source: Object = .{ .client = &w.client, .bucket = bucket, .name = object };
        const options: types.DownloadOptions = .{ .generation = generation };
        switch (destination) {
            .buffer => |buffer| {
                var fixed: std.Io.Writer = .fixed(buffer);
                return source.download(&fixed, options) catch |err| switch (err) {
                    error.WriteFailed => {
                        w.diag.print("the object decompresses to more than the buffer's {d} bytes", .{buffer.len});
                        return error.ObjectTooLarge;
                    },
                    error.NotFound => w.gone(generation),
                    else => |e| return e,
                };
            },
            .file => |file| {
                try setLength(io, &w.diag, file, 0);
                var file_writer = file.writer(io, w.buffer.?);
                const result = source.download(&file_writer.interface, options) catch |err| switch (err) {
                    error.WriteFailed => return w.writeFailed(&file_writer),
                    error.NotFound => return w.gone(generation),
                    else => |e| return e,
                };
                file_writer.interface.flush() catch return w.writeFailed(&file_writer);
                try checkLength(io, &w.diag, file, result.bytes_written);
                return result;
            },
        }
    }

    fn rangeFailed(w: *Worker, run: *const Run, index: u32, err: Error, over: bool, file_writer: ?*const std.Io.File.Writer) Error {
        switch (err) {
            error.WriteFailed => {
                if (!over) if (file_writer) |fw| return w.writeFailed(fw);
                w.diag.print("range {d}: the server sent more than the {d} bytes asked for", .{ index + 1, run.plan.len(index) });
                return error.InvalidResponse;
            },
            error.NotFound => return w.gone(run.generation),
            else => return err,
        }
    }

    /// The pinned generation answered 404: the object was overwritten or
    /// deleted after the metadata read.
    fn gone(w: *Worker, generation: u64) Error {
        w.diag.print("generation {d} is gone: the object was replaced or deleted during the download, and the destination holds part of it", .{generation});
        return error.NotFound;
    }

    /// The file refused a write, with the file's own error as the detail.
    fn writeFailed(w: *Worker, file_writer: *const std.Io.File.Writer) Error {
        const err = file_writer.err orelse {
            w.diag.print("the file could not be written", .{});
            return error.WriteFailed;
        };
        if (err == error.Canceled) return error.Canceled;
        w.diag.print("the file could not be written: {t}", .{err});
        return error.WriteFailed;
    }
};

/// Passes at most `remaining` bytes on to `out`. One more fails the write
/// and marks `over`, which tells a server that sent more than a range asked
/// for apart from a destination that failed.
const Bounded = struct {
    out: *std.Io.Writer,
    remaining: u64,
    over: bool = false,
    writer: std.Io.Writer,

    fn init(out: *std.Io.Writer, limit: u64) Bounded {
        return .{ .out = out, .remaining = limit, .writer = .{ .buffer = &.{}, .vtable = &.{ .drain = drain } } };
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *Bounded = @alignCast(@fieldParentPtr("writer", w));
        var offered: u64 = 0;
        for (data[0 .. data.len - 1]) |bytes| offered +|= bytes.len;
        offered +|= std.math.mul(u64, data[data.len - 1].len, splat) catch std.math.maxInt(u64);
        if (offered > self.remaining) {
            self.over = true;
            return error.WriteFailed;
        }
        const n = try self.out.writeSplat(data, splat);
        self.remaining -= n;
        return n;
    }
};

const testing = std.testing;
const builtin = @import("builtin");
const test_util = @import("test_util.zig");
const FakeMultipart = test_util.FakeMultipart;

fn fill(buf: []u8, seed: u64) void {
    var prng: std.Random.DefaultPrng = .init(seed);
    prng.random().bytes(buf);
}

/// Fault rules for the fake: the first `times` requests of `kind`, and of
/// the range starting at byte `at` when that is set, meet `fault`.
const Script = struct {
    rules: []Rule,

    const Rule = struct {
        kind: FakeMultipart.Kind = .media,
        at: ?u64 = null,
        times: u32 = 1,
        fault: FakeMultipart.Fault,
    };

    fn plan(self: *Script) FakeMultipart.FaultPlan {
        return .{ .ctx = self, .decide = decide };
    }

    fn decide(ctx: ?*anyopaque, kind: FakeMultipart.Kind, part: u32) FakeMultipart.Fault {
        const self: *Script = @ptrCast(@alignCast(ctx.?));
        for (self.rules) |*rule| {
            const here = rule.at == null or rule.at.? + 1 == part;
            if (rule.kind == kind and here and rule.times > 0) {
                rule.times -= 1;
                return rule.fault;
            }
        }
        return .none;
    }
};

/// A client on the fake, with the range floor lowered to 1 KiB.
const Setup = struct {
    fake: FakeMultipart,
    token: core.StaticToken,
    diag: Diagnostics,
    client: Client,

    const Options = struct {
        verify_checksums: bool = true,
        max_attempts: u8 = 4,
    };

    fn init(s: *Setup, io: std.Io, options: Options) !void {
        s.fake = .init(testing.allocator, io);
        s.token = .{ .token = "ya29.download-test" };
        s.diag = .{};
        s.client = try .init(testing.allocator, io, .{
            .token_provider = s.token.provider(),
            .transport = s.fake.transport(),
            .diagnostics = &s.diag,
            .verify_checksums = options.verify_checksums,
            .retry = .{ .max_attempts = options.max_attempts, .initial_backoff_ms = 1, .max_backoff_ms = 2 },
        });
        s.client.multipart_test = .{ .min_part_size = 1024 };
    }

    fn deinit(s: *Setup) void {
        s.client.deinit();
        s.fake.deinit();
    }

    fn object(s: *Setup, name: []const u8) Object {
        return s.client.bucket("b").object(name);
    }
};

/// A file in `tmp` holding `junk`, opened to be written and read back.
fn junkFile(tmp: *testing.TmpDir, junk: []const u8) !std.Io.File {
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "destination.bin", .data = junk });
    return tmp.dir.openFile(testing.io, "destination.bin", .{ .mode = .read_write });
}

fn readBack(tmp: *testing.TmpDir) ![]u8 {
    return tmp.dir.readFileAlloc(testing.io, "destination.bin", testing.allocator, .unlimited);
}

fn expectDiag(diag: *const Diagnostics, says: []const u8) !void {
    errdefer std.debug.print("diagnostics: {s}\n", .{diag.message()});
    try testing.expect(std.mem.indexOf(u8, diag.message(), says) != null);
}

/// The metadata a JSON read answers for `data`, as Cloud Storage words it.
fn metadataJson(arena: Allocator, size: u64, generation: u64, crc: ?u32, extra: []const u8) ![]const u8 {
    const hash: []const u8 = if (crc) |c| try std.fmt.allocPrint(arena, ",\"crc32c\":\"{s}\"", .{&core.crc32c.toBase64(c)}) else "";
    return std.fmt.allocPrint(arena, "{{\"name\":\"dir/o\",\"bucket\":\"b\",\"size\":\"{d}\",\"generation\":\"{d}\"{s}{s}}}", .{ size, generation, hash, extra });
}

test "downloadParallel: the metadata, then every range pinned to its generation, at its offset" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var data: [2500]u8 = undefined;
    fill(&data, 1);

    var h: test_util.Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = try metadataJson(arena, data.len, 42, core.crc32c.hash(&data), "") } },
        .{ .respond = .{ .status = 206, .body = data[0..1024], .headers = &.{.{ .name = "Content-Range", .value = "bytes 0-1023/2500" }} } },
        .{ .respond = .{ .status = 206, .body = data[1024..2048], .headers = &.{.{ .name = "Content-Range", .value = "bytes 1024-2047/2500" }} } },
        .{ .respond = .{ .status = 206, .body = data[2048..], .headers = &.{.{ .name = "Content-Range", .value = "bytes 2048-2499/2500" }} } },
    }, .{});
    defer h.deinit();
    h.client.multipart_test = .{ .min_part_size = 1024 };

    var out: [3000]u8 = @splat(0xaa);
    const result = try h.client.bucket("b").object("dir/o").downloadParallel(.{ .buffer = &out }, .{ .part_size = 1024, .concurrency = 4 });
    try testing.expectEqual(data.len, result.bytes_written);
    try testing.expectEqual(42, result.generation);
    try testing.expect(result.checksum_verified);
    try testing.expectEqual(core.crc32c.hash(&data), result.crc32c);
    try testing.expectEqualSlices(u8, &data, out[0..data.len]);
    // Past the object, the buffer is untouched.
    for (out[data.len..]) |byte| try testing.expectEqual(0xaa, byte);

    try h.expectRequest(0, .GET, "https://storage.googleapis.com/storage/v1/b/b/o/dir%2Fo", null);
    try testing.expectEqual(30_000, (try h.fake.request(0)).timeout_ms);
    const ranges = [_][]const u8{ "bytes=0-1023", "bytes=1024-2047", "bytes=2048-2499" };
    try testing.expectEqual(ranges.len, h.fake.stream_requests.items.len);
    for (ranges, 0..) |range, i| {
        const r = try h.fake.streamRequest(i);
        try testing.expectEqualStrings("https://storage.googleapis.com/storage/v1/b/b/o/dir%2Fo?alt=media&generation=42", r.url);
        try testing.expectEqualStrings(range, r.header("Range").?);
        // A range answers to the part timeout, the metadata read to the
        // client's.
        try testing.expectEqual(300_000, r.timeout_ms);
    }
}

test "downloadParallel: the caller's generation and conditions go on the metadata read" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var h: test_util.Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = try metadataJson(arena, 3, 7, core.crc32c.hash("abc"), "") } },
        .{ .respond = .{ .status = 206, .body = "abc", .headers = &.{.{ .name = "Content-Range", .value = "bytes 0-2/3" }} } },
    }, .{});
    defer h.deinit();
    var out: [3]u8 = undefined;
    const result = try h.client.bucket("b").object("dir/o").downloadParallel(.{ .buffer = &out }, .{
        .generation = 7,
        .preconditions = .{ .if_metageneration_match = 2 },
    });
    try testing.expectEqualStrings("abc", &out);
    try testing.expect(result.checksum_verified);
    try h.expectRequest(0, .GET, "https://storage.googleapis.com/storage/v1/b/b/o/dir%2Fo?generation=7&ifMetagenerationMatch=2", null);
    // An object of one part is one range, and the range carries no
    // conditions: the generation pins it.
    try testing.expectEqualStrings("https://storage.googleapis.com/storage/v1/b/b/o/dir%2Fo?alt=media&generation=7", (try h.fake.streamRequest(0)).url);
    try testing.expectEqualStrings("bytes=0-2", (try h.fake.streamRequest(0)).header("Range").?);
}

test "downloadParallel: an empty object is not read, and a file becomes empty" {
    var s: Setup = undefined;
    try s.init(testing.io, .{});
    defer s.deinit();
    try s.fake.put("empty", "");
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try junkFile(&tmp, "yesterday's bytes");
    defer file.close(testing.io);

    const result = try s.object("empty").downloadParallel(.{ .file = file }, .{});
    try testing.expectEqual(0, result.bytes_written);
    try testing.expect(result.checksum_verified);
    try testing.expectEqual(0, result.crc32c);
    try testing.expectEqual(0, try file.length(testing.io));

    // Into memory, even an empty buffer holds it.
    const empty = try s.object("empty").downloadParallel(.{ .buffer = &.{} }, .{});
    try testing.expectEqual(0, empty.bytes_written);
    try testing.expect(empty.checksum_verified);
    // Two metadata reads, and never a range: an empty one is a 416.
    try testing.expectEqual(2, s.fake.counts.reads);
    try testing.expectEqual(0, s.fake.counts.media);
}

test "downloadParallel: a gzip-stored object is fetched whole, decompressed and unverified" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const stored_crc = core.crc32c.hash("the compressed form");
    const decompressed = "what the object decompresses to, longer than its stored size";
    const transcoded: test_util.FakeTransport.Reply = .{ .respond = .{
        .body = decompressed,
        .headers = &.{.{ .name = "x-goog-stored-content-encoding", .value = "gzip" }},
    } };
    const meta = try metadataJson(arena, 19, 8, stored_crc, ",\"contentEncoding\":\"gzip\"");

    // Into memory: one request, no range, the client's checksum unused.
    {
        var h: test_util.Harness = undefined;
        try h.init(&.{ .{ .respond = .{ .body = meta } }, transcoded }, .{});
        defer h.deinit();
        var out: [100]u8 = undefined;
        const result = try h.client.bucket("b").object("dir/o").downloadParallel(.{ .buffer = &out }, .{ .part_timeout_ms = 1234 });
        try testing.expectEqualStrings(decompressed, out[0..result.bytes_written]);
        try testing.expect(!result.checksum_verified);
        try testing.expectEqual(core.crc32c.hash(decompressed), result.crc32c);
        try testing.expectEqual(8, result.generation);
        try testing.expectEqual(1, h.fake.stream_requests.items.len);
        const r = try h.fake.streamRequest(0);
        try testing.expectEqual(null, r.header("Range"));
        try testing.expectEqualStrings("https://storage.googleapis.com/storage/v1/b/b/o/dir%2Fo?alt=media&generation=8", r.url);
        try testing.expectEqual(1234, r.timeout_ms);
    }
    // A buffer the decompressed bytes overflow: its size was unknowable
    // until they arrived.
    {
        var h: test_util.Harness = undefined;
        try h.init(&.{ .{ .respond = .{ .body = meta } }, transcoded }, .{});
        defer h.deinit();
        var out: [30]u8 = undefined;
        try testing.expectError(error.ObjectTooLarge, h.client.bucket("b").object("dir/o").downloadParallel(.{ .buffer = &out }, .{}));
        try expectDiag(&h.diag, "decompresses to more than the buffer's 30 bytes");
    }
}

test "downloadParallel: an object with no CRC32C downloads unverified" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var h: test_util.Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = try metadataJson(arena_state.allocator(), 5, 3, null, "") } },
        .{ .respond = .{ .status = 206, .body = "hello", .headers = &.{.{ .name = "Content-Range", .value = "bytes 0-4/5" }} } },
    }, .{});
    defer h.deinit();
    var out: [5]u8 = undefined;
    const result = try h.client.bucket("b").object("dir/o").downloadParallel(.{ .buffer = &out }, .{});
    try testing.expectEqualStrings("hello", &out);
    try testing.expect(!result.checksum_verified);
    try testing.expectEqual(core.crc32c.hash("hello"), result.crc32c);
}

test "downloadParallel: metadata no object could have is InvalidResponse, before any range" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const bodies = [_][]const u8{
        try metadataJson(arena, 5 * 1024 * 1024 * 1024 * 1024 + 1, 3, 0, ""),
        "{\"name\":\"dir/o\",\"bucket\":\"b\",\"size\":\"10\"}",
    };
    for (bodies) |body| {
        var h: test_util.Harness = undefined;
        try h.init(&.{.{ .respond = .{ .body = body } }}, .{});
        defer h.deinit();
        var out: [16]u8 = undefined;
        try testing.expectError(error.InvalidResponse, h.client.bucket("b").object("dir/o").downloadParallel(.{ .buffer = &out }, .{}));
        try expectDiag(&h.diag, "Cloud Storage stores at most 5 TiB");
        try h.expectRequestCount(1);
        try testing.expectEqual(0, h.fake.stream_requests.items.len);
    }
}

test "downloadParallel: a buffer smaller than the object is ObjectTooLarge, before any range" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var h: test_util.Harness = undefined;
    try h.init(&.{.{ .respond = .{ .body = try metadataJson(arena_state.allocator(), 4096, 3, 0, "") } }}, .{});
    defer h.deinit();
    var out: [4095]u8 = undefined;
    try testing.expectError(error.ObjectTooLarge, h.client.bucket("b").object("dir/o").downloadParallel(.{ .buffer = &out }, .{}));
    try expectDiag(&h.diag, "the object is 4096 bytes, and the buffer holds 4095");
    try h.expectRequestCount(1);
    try testing.expectEqual(0, h.fake.stream_requests.items.len);
}

test "downloadParallel: ranges in parallel, into a buffer and into a longer file" {
    var s: Setup = undefined;
    try s.init(testing.io, .{});
    defer s.deinit();
    const data = try testing.allocator.alloc(u8, 100 * 1024 + 7);
    defer testing.allocator.free(data);
    fill(data, 2);
    try s.fake.put("dir/a b.bin", data);

    const out = try testing.allocator.alloc(u8, data.len);
    defer testing.allocator.free(out);
    const into_memory = try s.object("dir/a b.bin").downloadParallel(.{ .buffer = out }, .{ .part_size = 16 * 1024, .concurrency = 4 });
    try testing.expectEqualSlices(u8, data, out);
    try testing.expect(into_memory.checksum_verified);
    try testing.expectEqual(core.crc32c.hash(data), into_memory.crc32c);
    try testing.expectEqual(s.fake.object("dir/a b.bin").?.generation, into_memory.generation);
    // One metadata read, seven ranges, every byte served once.
    try testing.expectEqual(1, s.fake.counts.reads);
    try testing.expectEqual(7, s.fake.counts.media);
    try testing.expectEqual(data.len, s.fake.counts.media_bytes);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const junk = try testing.allocator.alloc(u8, 2 * data.len);
    defer testing.allocator.free(junk);
    @memset(junk, 'j');
    const file = try junkFile(&tmp, junk);
    defer file.close(testing.io);
    const into_file = try s.object("dir/a b.bin").downloadParallel(.{ .file = file }, .{ .part_size = 16 * 1024, .concurrency = 3 });
    try testing.expect(into_file.checksum_verified);
    const got = try readBack(&tmp);
    defer testing.allocator.free(got);
    // Cut to the object's length: nothing of the older file remains.
    try testing.expectEqualSlices(u8, data, got);
}

test "downloadParallel: a range cut partway resumes where it stopped, and no byte is fetched twice" {
    var rules = [_]Script.Rule{
        .{ .at = 16 * 1024, .fault = .cut },
        .{ .at = 48 * 1024, .fault = .cut },
    };
    var script: Script = .{ .rules = &rules };
    var s: Setup = undefined;
    try s.init(testing.io, .{ .max_attempts = 2 });
    defer s.deinit();
    s.fake.faults = script.plan();
    var data: [80 * 1024]u8 = undefined;
    fill(&data, 3);
    try s.fake.put("o", &data);
    var out: [data.len]u8 = undefined;
    const result = try s.object("o").downloadParallel(.{ .buffer = &out }, .{ .part_size = 16 * 1024, .concurrency = 3 });
    try testing.expectEqualSlices(u8, &data, &out);
    try testing.expect(result.checksum_verified);
    // Five ranges and two resumes, and exactly the object's bytes served.
    try testing.expectEqual(5 + 2, s.fake.counts.media);
    try testing.expectEqual(data.len, s.fake.counts.media_bytes);
}

test "downloadParallel: 503s and dropped connections are retried" {
    var rules = [_]Script.Rule{
        .{ .kind = .read, .fault = .unavailable },
        .{ .at = 0, .fault = .unavailable, .times = 2 },
        .{ .at = 8 * 1024, .fault = .reset },
        .{ .at = 16 * 1024, .fault = .lose_answer },
    };
    var script: Script = .{ .rules = &rules };
    var s: Setup = undefined;
    try s.init(testing.io, .{});
    defer s.deinit();
    s.fake.faults = script.plan();
    var data: [20 * 1024]u8 = undefined;
    fill(&data, 4);
    try s.fake.put("o", &data);
    var out: [data.len]u8 = undefined;
    const result = try s.object("o").downloadParallel(.{ .buffer = &out }, .{ .part_size = 8 * 1024, .concurrency = 2 });
    try testing.expectEqualSlices(u8, &data, &out);
    try testing.expect(result.checksum_verified);
}

test "downloadParallel: a generation that vanishes partway fails with NotFound" {
    var rules = [_]Script.Rule{.{ .at = 32 * 1024, .fault = .gone }};
    var script: Script = .{ .rules = &rules };
    var s: Setup = undefined;
    try s.init(testing.io, .{});
    defer s.deinit();
    s.fake.faults = script.plan();
    var data: [64 * 1024]u8 = undefined;
    fill(&data, 5);
    try s.fake.put("o", &data);
    const first_generation = s.fake.object("o").?.generation;
    var out: [data.len]u8 = undefined;
    try testing.expectError(error.NotFound, s.object("o").downloadParallel(.{ .buffer = &out }, .{ .part_size = 8 * 1024, .concurrency = 2 }));
    var says: [64]u8 = undefined;
    try expectDiag(&s.diag, try std.fmt.bufPrint(&says, "generation {d} is gone", .{first_generation}));
}

test "downloadParallel: a range a byte short or a byte long is InvalidResponse" {
    const cases = [_]struct { fault: FakeMultipart.Fault, says: []const u8 }{
        .{ .fault = .short, .says = "8192 bytes from byte 8192 were asked for, and 8191 arrived" },
        .{ .fault = .long, .says = "range 2: the server sent more than the 8192 bytes asked for" },
    };
    for (cases) |case| {
        for ([_]bool{ false, true }) |to_file| {
            var rules = [_]Script.Rule{.{ .at = 8 * 1024, .fault = case.fault }};
            var script: Script = .{ .rules = &rules };
            var s: Setup = undefined;
            try s.init(testing.io, .{});
            defer s.deinit();
            s.fake.faults = script.plan();
            var data: [24 * 1024]u8 = undefined;
            fill(&data, 6);
            try s.fake.put("o", &data);
            var tmp = testing.tmpDir(.{});
            defer tmp.cleanup();
            const file = try junkFile(&tmp, "");
            defer file.close(testing.io);
            var out: [data.len]u8 = undefined;
            const destination: types.ParallelDestination = if (to_file) .{ .file = file } else .{ .buffer = &out };
            try testing.expectError(error.InvalidResponse, s.object("o").downloadParallel(destination, .{ .part_size = 8 * 1024, .concurrency = 1 }));
            try expectDiag(&s.diag, case.says);
        }
    }
}

test "downloadParallel: a corrupted range is caught by the combined checksum" {
    for ([_]bool{ false, true }) |to_file| {
        var rules = [_]Script.Rule{.{ .at = 8 * 1024, .fault = .corrupt }};
        var script: Script = .{ .rules = &rules };
        var s: Setup = undefined;
        try s.init(testing.io, .{});
        defer s.deinit();
        s.fake.faults = script.plan();
        var data: [24 * 1024]u8 = undefined;
        fill(&data, 7);
        try s.fake.put("o", &data);
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        const file = try junkFile(&tmp, "");
        defer file.close(testing.io);
        var out: [data.len]u8 = undefined;
        const destination: types.ParallelDestination = if (to_file) .{ .file = file } else .{ .buffer = &out };
        try testing.expectError(error.ChecksumMismatch, s.object("o").downloadParallel(destination, .{ .part_size = 8 * 1024, .concurrency = 2 }));
        try expectDiag(&s.diag, "discard what the destination holds");
    }
}

test "downloadParallel: with checksums off, nothing is compared" {
    var rules = [_]Script.Rule{.{ .at = 0, .fault = .corrupt }};
    var script: Script = .{ .rules = &rules };
    var s: Setup = undefined;
    try s.init(testing.io, .{ .verify_checksums = false });
    defer s.deinit();
    s.fake.faults = script.plan();
    var data: [12 * 1024]u8 = undefined;
    fill(&data, 8);
    try s.fake.put("o", &data);
    var out: [data.len]u8 = undefined;
    const result = try s.object("o").downloadParallel(.{ .buffer = &out }, .{ .part_size = 4096 });
    try testing.expect(!result.checksum_verified);
    // What arrived, corruption and all, and the checksum of exactly that.
    try testing.expect(!std.mem.eql(u8, &data, &out));
    try testing.expectEqual(core.crc32c.hash(&out), result.crc32c);
}

test "downloadParallel: one worker on the caller's task when the Io cannot run more" {
    // FakeClock's Io has no concurrency: the same download goes range by range.
    var clock: test_util.FakeClock = .{};
    var s: Setup = undefined;
    try s.init(clock.io(), .{});
    defer s.deinit();
    var data: [10 * 1024]u8 = undefined;
    fill(&data, 9);
    try s.fake.put("o", &data);
    var out: [data.len]u8 = undefined;
    const result = try s.object("o").downloadParallel(.{ .buffer = &out }, .{ .part_size = 4096, .concurrency = 8 });
    try testing.expectEqualSlices(u8, &data, &out);
    try testing.expect(result.checksum_verified);
    try testing.expectEqual(3, s.fake.counts.media);
}

test "downloadParallel: a cancel stops the workers and returns Canceled" {
    var rules = [_]Script.Rule{.{ .at = 4096, .fault = .wait }};
    var script: Script = .{ .rules = &rules };
    var s: Setup = undefined;
    try s.init(testing.io, .{});
    defer s.deinit();
    s.fake.faults = script.plan();
    var data: [12 * 1024]u8 = undefined;
    fill(&data, 10);
    try s.fake.put("o", &data);
    var out: [data.len]u8 = undefined;

    const Running = struct {
        fn go(target: Object, buffer: []u8) Error!void {
            _ = try target.downloadParallel(.{ .buffer = buffer }, .{ .part_size = 4096, .concurrency = 2 });
        }
    };
    var task = try testing.io.concurrent(Running.go, .{ s.object("o"), &out });
    // The second range waits at the gate, uncounted until it is served;
    // wait until the other two are, so the cancel lands on a worker
    // mid-request.
    const deadline = std.Io.Clock.awake.now(testing.io).addDuration(.fromSeconds(10));
    while (true) {
        s.fake.mutex.lockUncancelable(testing.io);
        const served = s.fake.counts.media;
        s.fake.mutex.unlock(testing.io);
        if (served >= 2) break;
        if (std.Io.Clock.awake.now(testing.io).nanoseconds > deadline.nanoseconds) @panic("the download never fetched the two ranges not held back");
        try testing.io.sleep(.fromMilliseconds(1), .awake);
    }
    try testing.expectError(error.Canceled, task.cancel(testing.io));
}

test "downloadParallel: a file opened for appending is caught by its length" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var s: Setup = undefined;
    try s.init(testing.io, .{});
    defer s.deinit();
    var data: [12 * 1024]u8 = undefined;
    fill(&data, 11);
    try s.fake.put("o", &data);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "destination.bin", .data = "" });
    const fd = try std.posix.openat(tmp.dir.handle, "destination.bin", .{ .ACCMODE = .RDWR, .APPEND = true }, 0);
    const file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
    defer file.close(testing.io);

    const outcome = s.object("o").downloadParallel(.{ .file = file }, .{ .part_size = 4096, .concurrency = 2 });
    if (outcome) |_| {
        // A system that honors the offset: the bytes are where they belong.
        try testing.expect(builtin.os.tag != .linux);
        const got = try readBack(&tmp);
        defer testing.allocator.free(got);
        try testing.expectEqualSlices(u8, &data, got);
    } else |err| {
        // Linux appends whatever the offset: never a file scrambled under a
        // verified checksum.
        try testing.expectEqual(error.WriteFailed, err);
        try expectDiag(&s.diag, "opened for appending");
    }
}

/// `testing.io`, except that every positional file write fails with
/// `failure`: a full disk, or a cancel that lands mid-write.
fn FailingWrites(comptime failure: std.Io.File.WritePositionalError) type {
    return struct {
        var vtable: std.Io.VTable = undefined;

        fn io() std.Io {
            vtable = testing.io.vtable.*;
            vtable.fileWritePositional = write;
            return .{ .userdata = testing.io.userdata, .vtable = &vtable };
        }

        fn write(_: ?*anyopaque, _: std.Io.File, _: []const u8, _: []const []const u8, _: usize, _: u64) std.Io.File.WritePositionalError!usize {
            return failure;
        }
    };
}

test "downloadParallel: a file that refuses a write fails with its error, and a cancel mid-write is a cancel" {
    const cases = .{
        .{ error.NoSpaceLeft, error.WriteFailed, "the file could not be written: NoSpaceLeft" },
        .{ error.Canceled, error.Canceled, "" },
    };
    inline for (cases) |case| {
        var s: Setup = undefined;
        try s.init(FailingWrites(case[0]).io(), .{});
        defer s.deinit();
        var data: [12 * 1024]u8 = undefined;
        fill(&data, 16);
        try s.fake.put("o", &data);
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        const file = try junkFile(&tmp, "");
        defer file.close(testing.io);
        try testing.expectError(case[1], s.object("o").downloadParallel(.{ .file = file }, .{ .part_size = 4096, .concurrency = 2 }));
        try expectDiag(&s.diag, case[2]);
    }
}

test "downloadParallel: a pipe is refused when it is sized, before any range" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var s: Setup = undefined;
    try s.init(testing.io, .{});
    defer s.deinit();
    try s.fake.put("o", "some bytes");
    const fds = try std.Io.Threaded.pipe2(.{});
    const read_end: std.Io.File = .{ .handle = fds[0], .flags = .{ .nonblocking = false } };
    defer read_end.close(testing.io);
    const write_end: std.Io.File = .{ .handle = fds[1], .flags = .{ .nonblocking = false } };
    defer write_end.close(testing.io);
    try testing.expectError(error.WriteFailed, s.object("o").downloadParallel(.{ .file = write_end }, .{ .part_size = 4096 }));
    try expectDiag(&s.diag, "could not be set to 10 bytes");
    try testing.expectEqual(0, s.fake.counts.media);
}

test "downloadParallel: a gzip-stored object on the fake, into memory and into a file" {
    var s: Setup = undefined;
    try s.init(testing.io, .{});
    defer s.deinit();
    const decompressed = "hello, " ** 300;
    try s.fake.putGzip("page.html", "pretend this is gzip", decompressed);
    var out: [decompressed.len + 10]u8 = undefined;
    const result = try s.object("page.html").downloadParallel(.{ .buffer = &out }, .{ .part_size = 1024 });
    try testing.expectEqualStrings(decompressed, out[0..result.bytes_written]);
    try testing.expect(!result.checksum_verified);
    try testing.expectEqual(1, s.fake.counts.media);

    // Into a file with older, longer contents: emptied first, then exactly
    // the decompressed bytes.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try junkFile(&tmp, "x" ** 5000);
    defer file.close(testing.io);
    const into_file = try s.object("page.html").downloadParallel(.{ .file = file }, .{ .part_size = 1024 });
    try testing.expectEqual(decompressed.len, into_file.bytes_written);
    const got = try readBack(&tmp);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(decompressed, got);
    try testing.expectEqual(2, s.fake.counts.media);
}

test "check: what a parallel download refuses, before anything is sent" {
    var s: Setup = undefined;
    try s.init(testing.io, .{});
    defer s.deinit();
    s.client.multipart_test = .{};
    try s.fake.put("o", "x");
    const refused = [_]struct { options: types.ParallelDownloadOptions, says: []const u8 }{
        .{ .options = .{ .part_size = 1024 * 1024 - 1 }, .says = "part_size: at least 1048576 bytes, not 1048575" },
        .{ .options = .{ .part_size = 0 }, .says = "part_size" },
        .{ .options = .{ .concurrency = 0 }, .says = "concurrency: 1 to 64, not 0" },
        .{ .options = .{ .concurrency = 65 }, .says = "concurrency" },
    };
    var out: [1]u8 = undefined;
    for (refused) |case| {
        try testing.expectError(error.InvalidParallelDownloadOptions, s.object("o").downloadParallel(.{ .buffer = &out }, case.options));
        try expectDiag(&s.diag, case.says);
    }
    try testing.expectEqual(0, s.fake.counts.reads);
    // The edges that are allowed.
    try check(&s.client, .{ .part_size = 1024 * 1024, .concurrency = 1 });
    try check(&s.client, .{ .part_size = std.math.maxInt(u64), .concurrency = 64 });
}

fn checkProperty(_: void, input: []const u8) !void {
    var g: test_util.ByteGen = .init(input);
    const floor: u64 = g.pick(u64, &.{ 1024, 1024 * 1024 });
    const options: types.ParallelDownloadOptions = .{
        .part_size = g.pick(u64, &.{ 0, 1, floor - 1, floor, floor + 1, 32 * 1024 * 1024, std.math.maxInt(u64) }),
        .concurrency = g.pick(u16, &.{ 0, 1, 2, 63, 64, 65, std.math.maxInt(u16) }),
    };
    var token: core.StaticToken = .{ .token = "ya29.t" };
    var fake: test_util.FakeTransport = .init(testing.allocator, &.{});
    defer fake.deinit();
    var client: Client = try .init(testing.allocator, testing.io, .{ .token_provider = token.provider(), .transport = fake.transport() });
    defer client.deinit();
    client.multipart_test = .{ .min_part_size = floor };
    const allowed = options.part_size >= floor and options.concurrency >= 1 and options.concurrency <= 64;
    const result = check(&client, options);
    try testing.expectEqual(allowed, result != error.InvalidParallelDownloadOptions);
}

test "fuzz parallel download: check accepts exactly what the rules allow" {
    try test_util.fuzzBytes({}, checkProperty, .{ .corpus = &.{
        "",
        "\x00\x00\x00\x00\x00\x00\x00\x00\x03\x00\x00\x00\x00\x00\x00\x00\x04",
        "\x01\x00\x00\x00\x00\x00\x00\x00\x02\x00\x00\x00\x00\x00\x00\x00\x05",
    } });
}

test "Bounded: passes up to its limit, and fails the write that would cross it" {
    var buf: [16]u8 = undefined;
    var fixed: std.Io.Writer = .fixed(&buf);
    var bounded: Bounded = .init(&fixed, 10);
    try bounded.writer.writeAll("hello");
    try bounded.writer.splatByteAll('!', 5);
    try testing.expectEqualStrings("hello!!!!!", fixed.buffered());
    try testing.expect(!bounded.over);
    try testing.expectError(error.WriteFailed, bounded.writer.writeAll("x"));
    try testing.expect(bounded.over);
    try testing.expectEqualStrings("hello!!!!!", fixed.buffered());

    // A destination that fails on its own leaves `over` unset.
    var small: [4]u8 = undefined;
    var tight: std.Io.Writer = .fixed(&small);
    var roomy: Bounded = .init(&tight, 100);
    try testing.expectError(error.WriteFailed, roomy.writer.writeAll("too long"));
    try testing.expect(!roomy.over);

    // A zero limit takes only emptiness, however it is offered.
    var none: Bounded = .init(&fixed, 0);
    try none.writer.writeAll("");
    try testing.expectError(error.WriteFailed, none.writer.splatByteAll('z', 1));
    try testing.expect(none.over);
}

fn downloadEverything(gpa: Allocator) !void {
    var clock: test_util.FakeClock = .{};
    var fake: FakeMultipart = .init(gpa, clock.io());
    defer fake.deinit();
    var token: core.StaticToken = .{ .token = "ya29.t" };
    var client: Client = try .init(gpa, clock.io(), .{
        .token_provider = token.provider(),
        .transport = fake.transport(),
    });
    defer client.deinit();
    client.multipart_test = .{ .min_part_size = 1024 };
    var data: [3000]u8 = undefined;
    fill(&data, 12);
    try fake.put("o", &data);
    try fake.putGzip("z", "stored", "served");
    var out: [3000]u8 = undefined;
    _ = try client.bucket("b").object("o").downloadParallel(.{ .buffer = &out }, .{ .part_size = 1024 });
    _ = try client.bucket("b").object("z").downloadParallel(.{ .buffer = &out }, .{ .part_size = 1024 });
}

test "downloadParallel: every allocation failure is OutOfMemory, and nothing leaks" {
    try testing.checkAllAllocationFailures(testing.allocator, downloadEverything, .{});
}

/// Draws each request's fate from fuzz bytes, under the fake's lock: mostly
/// nothing, sometimes a fault that kind of request can meet.
const Chooser = struct {
    bytes: []const u8,
    pos: usize = 0,
    faulted: bool = false,

    fn plan(self: *Chooser) FakeMultipart.FaultPlan {
        return .{ .ctx = self, .decide = decide };
    }

    fn decide(ctx: ?*anyopaque, kind: FakeMultipart.Kind, part: u32) FakeMultipart.Fault {
        _ = part;
        const self: *Chooser = @ptrCast(@alignCast(ctx.?));
        if (self.pos >= self.bytes.len) return .none;
        const b = self.bytes[self.pos];
        self.pos += 1;
        const media = kind == .media;
        const fault: FakeMultipart.Fault = switch (b) {
            0...189 => .none,
            190...204 => .unavailable,
            205...214 => .reset,
            215...224 => .lose_answer,
            225...234 => if (media) .cut else .none,
            235...240 => if (media) .corrupt else .none,
            241...244 => if (media) .short else .none,
            245...248 => if (media) .long else .none,
            else => if (media) .gone else .none,
        };
        if (fault != .none) self.faulted = true;
        return fault;
    }
};

/// One download under a drawn fault schedule, held to what must hold
/// whatever the faults: a run that met no fault never fails; a run that
/// succeeds reports exactly what it wrote, its length and its checksum;
/// and with checksums on, a verified run wrote exactly the object. `files`
/// says whether `io` can write files, which the fake clock's cannot.
fn runUnderFaults(io: std.Io, files: bool, input: []const u8) !void {
    var g: test_util.ByteGen = .init(input);
    const size = g.intRange(usize, 0, 40 * 1024);
    const part_size = g.intRange(u64, 1024, 12 * 1024);
    const concurrency = g.intRange(u16, 1, 6);
    const verify = g.intRange(u8, 0, 7) != 0;
    const to_file = g.boolean() and files;
    const gzip = g.intRange(u8, 0, 15) == 0;
    const data = try testing.allocator.alloc(u8, size);
    defer testing.allocator.free(data);
    fill(data, g.int(u64));

    var s: Setup = undefined;
    try s.init(io, .{ .verify_checksums = verify });
    defer s.deinit();
    const decompressed = "decompressed " ** 40;
    if (gzip) try s.fake.putGzip("o", data, decompressed) else try s.fake.put("o", data);
    var chooser: Chooser = .{ .bytes = g.rest() };
    s.fake.faults = chooser.plan();

    const expected: []const u8 = if (gzip) decompressed else data;
    const buffer = try testing.allocator.alloc(u8, expected.len);
    defer testing.allocator.free(buffer);
    var tmp: ?testing.TmpDir = if (to_file) testing.tmpDir(.{}) else null;
    defer if (tmp) |*t| t.cleanup();
    const file: ?std.Io.File = if (tmp) |*t| try junkFile(t, "an older file's bytes") else null;
    defer if (file) |f| f.close(testing.io);
    const destination: types.ParallelDestination = if (file) |f| .{ .file = f } else .{ .buffer = buffer };

    const outcome = s.object("o").downloadParallel(destination, .{ .part_size = part_size, .concurrency = concurrency });
    if (outcome) |result| {
        const written = if (tmp) |*t| try readBack(t) else try testing.allocator.dupe(u8, buffer[0..result.bytes_written]);
        defer testing.allocator.free(written);
        try testing.expectEqual(expected.len, result.bytes_written);
        try testing.expectEqual(expected.len, written.len);
        try testing.expectEqual(core.crc32c.hash(written), result.crc32c);
        try testing.expectEqual(verify and !gzip, result.checksum_verified);
        if (result.checksum_verified or !chooser.faulted) try testing.expectEqualSlices(u8, expected, written);
    } else |err| {
        errdefer std.debug.print("{t}: {s}\n", .{ err, s.diag.message() });
        // Only a fault fails a run.
        try testing.expect(chooser.faulted);
    }
}

fn faultProperty(_: void, input: []const u8) !void {
    var clock: test_util.FakeClock = .{};
    try runUnderFaults(clock.io(), false, input);
}

// About 2.3 ms a run in Debug: named out of the nightly's "fuzz" and "slow
// property" filters, like the parallel upload's fault property, until a
// job of its own is sized for it.
test "fault property parallel download: every run under faults writes the object whole, or fails" {
    try test_util.fuzzBytes({}, faultProperty, .{
        .random_runs = 300,
        .max_len = 256,
        .corpus = &.{
            "",
            // 40 KiB in 1 KiB ranges, 6 at once, into a file, no faults.
            "\xff\xff\xff\xff\xff\xff\xff\xff\x00\x00\x00\x00\x00\x00\x00\x00\x00\x05\x01\x01",
            // A cut, then a corrupted range.
            "\x00\x00\x00\x00\x00\x00\x50\x00\x00\x00\x00\x00\x00\x00\x10\x00\x00\x02\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\xe6\xec",
        },
    });
}

test "downloadParallel: the same invariants on real threads, under a hundred fault schedules" {
    var prng: std.Random.DefaultPrng = .init(20260924);
    var input: [192]u8 = undefined;
    for (0..100) |_| {
        prng.random().bytes(&input);
        runUnderFaults(testing.io, true, &input) catch |err| {
            std.debug.print("input: {x}\n", .{&input});
            return err;
        };
    }
}

/// The fake behind a real HTTP server on the loopback interface, and a
/// client that reaches it through real connections: its built-in
/// transport, a new one per worker.
const OverSockets = struct {
    fake: FakeMultipart,
    server: test_util.MultipartServer,
    serving: std.Io.Future(std.Io.Cancelable!void),
    diag: Diagnostics,
    client: Client,
    url_buf: [64]u8,

    fn init(s: *OverSockets) !void {
        const io = testing.io;
        s.fake = .init(testing.allocator, io);
        errdefer s.fake.deinit();
        s.server = try .start(io, &s.fake);
        errdefer s.server.deinit(io);
        s.serving = try io.concurrent(test_util.MultipartServer.run, .{ &s.server, io });
        errdefer _ = s.serving.cancel(io) catch {};
        s.diag = .{};
        s.client = try .init(testing.allocator, io, .{
            .endpoint = .{ .url = s.server.url(&s.url_buf), .emulator = true },
            .diagnostics = &s.diag,
            .retry = .{ .max_attempts = 4, .initial_backoff_ms = 1, .max_backoff_ms = 2 },
        });
        s.client.multipart_test = .{ .min_part_size = 1024 };
    }

    fn deinit(s: *OverSockets) void {
        const io = testing.io;
        // The client's connections close first, so the server's tasks end.
        s.client.deinit();
        _ = s.serving.cancel(io) catch {};
        s.server.deinit(io);
        s.fake.deinit();
    }
};

test "downloadParallel over real sockets: a file, a connection per worker" {
    // The first four ranges wait at the gate, each holding a worker and its
    // connection, so the count below does not depend on how fast the
    // workers start.
    var rules = [_]Script.Rule{
        .{ .at = 0, .fault = .wait },
        .{ .at = 8 * 1024, .fault = .wait },
        .{ .at = 16 * 1024, .fault = .wait },
        .{ .at = 24 * 1024, .fault = .wait },
    };
    var script: Script = .{ .rules = &rules };
    var s: OverSockets = undefined;
    try s.init();
    defer s.deinit();
    s.fake.faults = script.plan();
    const data = try testing.allocator.alloc(u8, 200 * 1024 + 3);
    defer testing.allocator.free(data);
    fill(data, 13);
    try s.fake.put("dir/over sockets.bin", data);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try junkFile(&tmp, "");
    defer file.close(testing.io);

    const Running = struct {
        fn go(target: Object, destination: std.Io.File) Error!types.DownloadResult {
            return target.downloadParallel(.{ .file = destination }, .{ .part_size = 8 * 1024, .concurrency = 4 });
        }
    };
    var task = try testing.io.concurrent(Running.go, .{ s.client.bucket("b").object("dir/over sockets.bin"), file });
    // Four workers held at the gate, each on a connection of its own, and
    // the caller's, which read the metadata.
    const waiting = std.Io.Clock.awake.now(testing.io);
    while (s.server.connections.load(.monotonic) < 5) {
        if (waiting.durationTo(std.Io.Clock.awake.now(testing.io)).toMilliseconds() > 10_000) {
            @panic("four workers never held four connections of their own");
        }
        try testing.io.sleep(.fromMilliseconds(1), .awake);
    }
    s.fake.gate.set(testing.io);
    const result = try task.await(testing.io);
    try testing.expect(result.checksum_verified);
    const got = try readBack(&tmp);
    defer testing.allocator.free(got);
    try testing.expectEqualSlices(u8, data, got);
    try testing.expectEqual(26, s.fake.counts.media);
}

test "downloadParallel over real sockets: cut and dropped connections and a 503 are ridden out" {
    var rules = [_]Script.Rule{
        .{ .at = 8 * 1024, .fault = .cut },
        .{ .at = 16 * 1024, .fault = .reset },
        .{ .at = 32 * 1024, .fault = .unavailable },
        .{ .kind = .read, .fault = .lose_answer },
    };
    var script: Script = .{ .rules = &rules };
    var s: OverSockets = undefined;
    try s.init();
    defer s.deinit();
    s.fake.faults = script.plan();
    var data: [60 * 1024]u8 = undefined;
    fill(&data, 14);
    try s.fake.put("o", &data);
    var out: [data.len]u8 = undefined;
    const result = try s.client.bucket("b").object("o").downloadParallel(.{ .buffer = &out }, .{ .part_size = 8 * 1024, .concurrency = 3 });
    try testing.expectEqualSlices(u8, &data, &out);
    try testing.expect(result.checksum_verified);
}

test "downloadParallel over real sockets: a stalled range times out and is fetched again" {
    var rules = [_]Script.Rule{.{ .at = 8 * 1024, .fault = .stall }};
    var script: Script = .{ .rules = &rules };
    var s: OverSockets = undefined;
    try s.init();
    defer s.deinit();
    s.fake.faults = script.plan();
    s.fake.stall_ms = 1_500;
    var data: [24 * 1024]u8 = undefined;
    fill(&data, 15);
    try s.fake.put("o", &data);
    var out: [data.len]u8 = undefined;

    const started = std.Io.Clock.awake.now(testing.io);
    const result = try s.client.bucket("b").object("o").downloadParallel(.{ .buffer = &out }, .{
        .part_size = 8 * 1024,
        .concurrency = 2,
        .part_timeout_ms = 200,
    });
    const elapsed_ms = started.durationTo(std.Io.Clock.awake.now(testing.io)).toMilliseconds();
    try testing.expectEqualSlices(u8, &data, &out);
    try testing.expect(result.checksum_verified);
    // The timeout fired well before the stall ended.
    try testing.expect(elapsed_ms < 1_500);
}

test "Run: ranges are handed out once each, and none after a failure; the first failure is kept" {
    var s: Setup = undefined;
    try s.init(testing.io, .{});
    defer s.deinit();
    var crcs: [5]u32 = undefined;
    var run: Run = .{
        .client = &s.client,
        .bucket = "b",
        .object = "o",
        .generation = 1,
        .destination = .{ .buffer = &.{} },
        .plan = mp.plan(5 * 1024, 1024),
        .crcs = &crcs,
    };
    try testing.expectEqual(0, run.take().?);
    try testing.expectEqual(1, run.take().?);
    var first: Diagnostics = .{};
    first.print("range 2 failed", .{});
    run.fail(error.Unavailable, &first);
    try testing.expectEqual(null, run.take());
    var later: Diagnostics = .{};
    later.print("a later failure", .{});
    run.fail(error.Internal, &later);
    try testing.expectEqual(error.Unavailable, run.failure.?.err);
    try testing.expectEqualStrings("range 2 failed", run.failure.?.diag.message());

    // With no failure, every range once, then nothing.
    var clean: Run = run;
    clean.failure = null;
    clean.next = 0;
    for (0..5) |i| try testing.expectEqual(@as(u32, @intCast(i)), clean.take().?);
    try testing.expectEqual(null, clean.take());
}
