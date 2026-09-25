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
const checkpoint = @import("checkpoint.zig");
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
    if (options.checkpoint != null and destination != .file) {
        return refuse(client.diagnostics, "checkpoint: only a file destination outlives a process, so a buffer takes none", .{});
    }
    const result = transfer(client, bucket, object, destination, options);
    if (options.checkpoint) |cp| {
        if (result) |_| {
            cp.clear();
        } else |err| switch (err) {
            // Resuming these would only repeat them: the destination must
            // be discarded, or the response can never be used. Everything
            // else keeps the state for a later run; a foreign checkpoint
            // especially is another transfer's to clear.
            error.ChecksumMismatch, error.InvalidResponse => cp.clear(),
            else => {},
        }
    }
    return result;
}

fn transfer(
    client: *Client,
    bucket: []const u8,
    object: []const u8,
    destination: types.ParallelDestination,
    options: types.ParallelDownloadOptions,
) Error!types.DownloadResult {
    // What the checkpoint holds outlives the metadata read that judges it.
    var resume_arena: std.heap.ArenaAllocator = .init(client.gpa);
    defer resume_arena.deinit();
    var saved: ?checkpoint.State.DownloadParallel = null;
    if (options.checkpoint) |cp| {
        saved = try loadState(client, cp, resume_arena.allocator(), bucket, object);
        if (saved) |s| if (options.generation) |wanted| if (wanted != s.generation) {
            logging.debug("parallel download of {s}: the checkpoint is for generation {d}, not the requested {d}; starting over", .{ object, s.generation, wanted });
            saved = null;
        };
    }

    const source: Object = .{ .client = client, .bucket = bucket, .name = object };
    var info = if (saved) |s|
        source.get(.{ .generation = s.generation, .preconditions = options.preconditions }) catch |err| blk: {
            // The checkpoint's generation is gone: the object changed. The
            // caller who asked for no particular generation gets the live
            // one, from the start.
            if (err != error.NotFound or options.generation != null) return err;
            logging.debug("parallel download of {s}: generation {d} is gone; starting over at the live object", .{ object, s.generation });
            saved = null;
            break :blk try source.get(.{ .preconditions = options.preconditions });
        }
    else
        try source.get(.{ .generation = options.generation, .preconditions = options.preconditions });
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
        .file => |file| {
            if (saved) |s| {
                if (s.size != size) {
                    // A generation never changes size: this state does not
                    // describe the object it names.
                    if (client.diagnostics) |d| d.print("the checkpoint says generation {d} has {d} bytes, and it has {d}; it is not this transfer's", .{ generation, s.size, size });
                    return error.CheckpointFailed;
                }
                // Only a file still shaped by the earlier run resumes.
                const held_length = file.length(client.io) catch |err| switch (err) {
                    error.Canceled => return error.Canceled,
                    else => {
                        if (client.diagnostics) |d| d.print("the file's length could not be read: {t}", .{err});
                        return error.WriteFailed;
                    },
                };
                if (held_length != size) {
                    logging.debug("parallel download of {s}: the file is {d} bytes, not {d}; starting over", .{ object, held_length, size });
                    saved = null;
                }
            }
            if (saved == null) try setLength(client.io, client.diagnostics, file, size);
        },
    }
    var crc: u32 = 0;
    if (size > 0) {
        const plan = mp.plan(size, if (saved) |s| s.part_size else options.part_size);
        logging.debug("parallel download of {s}: {d} bytes in {d} ranges of {d}", .{ object, size, plan.parts, plan.part_size });
        const crcs = try client.gpa.alloc(u32, plan.parts);
        defer client.gpa.free(crcs);
        var written: std.DynamicBitSetUnmanaged = if (saved) |s|
            try checkpoint.bitsFromHex(client.gpa, s.written, plan.parts)
        else
            try .initEmpty(client.gpa, plan.parts);
        defer written.deinit(client.gpa);
        const hex = try client.gpa.alloc(u8, checkpoint.digitsFor(plan.parts));
        defer client.gpa.free(hex);
        var run: Run = .{
            .client = client,
            .bucket = bucket,
            .object = object,
            .size = size,
            .generation = generation,
            .destination = destination,
            .plan = plan,
            .crcs = crcs,
            .checkpoint = options.checkpoint,
            .written = &written,
            .hex = hex,
        };
        // The state goes down before any data moves, so a store that
        // cannot save fails while starting over still costs nothing.
        if (options.checkpoint != null) try run.save(client.diagnostics);
        const held = written.count();
        if (held > 0) {
            logging.debug("parallel download of {s}: the file already holds {d} of {d} ranges; re-reading them", .{ object, held, plan.parts });
            try rereadWritten(client, destination.file, plan, &written, crcs);
        }
        if (held < plan.parts) try run.fetchRanges(options);
        // Every range is in. Their checksums fold into the whole's.
        for (crcs, 0..) |range_crc, i| crc = core.crc32c.combine(crc, range_crc, plan.len(@intCast(i)));
    } else if (options.checkpoint) |cp| {
        // An empty object has no ranges, but the started transfer is still
        // recorded, as every other is.
        try saveState(client.gpa, cp, client.diagnostics, .{ .download_parallel = .{
            .bucket = bucket,
            .object = object,
            .size = 0,
            .generation = generation,
            .part_size = options.part_size,
            .written = "",
        } });
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
    return .{ .bytes_written = size, .generation = generation, .checksum_verified = expected != null, .crc32c = crc, .stored_bytes = size };
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

/// What the checkpoint holds for this download, or null when it holds
/// nothing yet. A state that cannot be read or parsed, or that belongs to
/// another transfer, is `error.CheckpointFailed` before anything is sent.
fn loadState(
    client: *Client,
    cp: checkpoint.Checkpoint,
    arena: Allocator,
    bucket: []const u8,
    object: []const u8,
) Error!?checkpoint.State.DownloadParallel {
    const d = client.diagnostics;
    const bytes = cp.load(arena) catch |err| switch (err) {
        error.CheckpointFailed => {
            if (d) |diag| diag.print("the checkpoint could not be read", .{});
            return error.CheckpointFailed;
        },
        else => |e| return e,
    } orelse return null;
    const state = checkpoint.parse(arena, bytes) catch |err| switch (err) {
        error.CheckpointFailed => {
            if (d) |diag| diag.print("the checkpoint holds no state this library wrote; nothing was changed", .{});
            return error.CheckpointFailed;
        },
        error.OutOfMemory => return error.OutOfMemory,
    };
    const s = switch (state) {
        .download_parallel => |s| s,
        else => {
            if (d) |diag| diag.print("the checkpoint belongs to another transfer, not a parallel download; give each transfer a checkpoint of its own", .{});
            return error.CheckpointFailed;
        },
    };
    if (!std.mem.eql(u8, s.bucket, bucket) or !std.mem.eql(u8, s.object, object)) {
        if (d) |diag| diag.print("the checkpoint belongs to another transfer; overwriting it would orphan that one, so give each transfer a checkpoint of its own", .{});
        return error.CheckpointFailed;
    }
    return s;
}

/// Encodes and saves one state, with the failure the caller asked to be
/// told about: a transfer that cannot record itself must not pretend it
/// can be resumed.
fn saveState(gpa: Allocator, cp: checkpoint.Checkpoint, d: ?*Diagnostics, state: checkpoint.State) Error!void {
    const bytes = try checkpoint.encodeAlloc(gpa, state);
    defer gpa.free(bytes);
    cp.save(bytes) catch |err| switch (err) {
        error.CheckpointFailed => {
            if (d) |diag| diag.print("the checkpoint refused a save; the download fails rather than carry on unresumable", .{});
            return error.CheckpointFailed;
        },
        else => |e| return e,
    };
}

/// Rebuilds each held range's CRC32C by reading the file back: nothing
/// about the data is taken from the checkpoint, so a destination that
/// changed between runs fails the whole's checksum instead of standing
/// unread.
fn rereadWritten(
    client: *Client,
    file: std.Io.File,
    plan: mp.Plan,
    written: *const std.DynamicBitSetUnmanaged,
    crcs: []u32,
) Error!void {
    const buf = try client.gpa.alloc(u8, file_buffer_len);
    defer client.gpa.free(buf);
    var index: u32 = 0;
    while (index < plan.parts) : (index += 1) {
        if (!written.isSet(index)) continue;
        var hasher: core.crc32c.Hasher = .init();
        var offset = plan.offset(index);
        var remaining = plan.len(index);
        while (remaining > 0) {
            const want: usize = @intCast(@min(remaining, buf.len));
            const got = file.readPositionalAll(client.io, buf[0..want], offset) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => {
                    if (client.diagnostics) |d| d.print("range {d} could not be read back from the file to resume: {t}", .{ index + 1, err });
                    return error.ReadFailed;
                },
            };
            if (got < want) {
                if (client.diagnostics) |d| d.print("the file ends {d} bytes into range {d}, which the checkpoint says it holds", .{ plan.len(index) - remaining + got, index + 1 });
                return error.ReadFailed;
            }
            hasher.update(buf[0..got]);
            offset += got;
            remaining -= got;
        }
        crcs[index] = hasher.final();
    }
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
    size: u64,
    generation: u64,
    destination: types.ParallelDestination,
    plan: mp.Plan,
    /// Each range's CRC32C, written by the worker that fetched it, or
    /// rebuilt from the file for a range an earlier run fetched.
    crcs: []u32,
    /// Null when the caller keeps no state between processes.
    checkpoint: ?checkpoint.Checkpoint,
    /// Which ranges the destination holds: the resumed ones up front, and
    /// each fetched range as its save records it.
    written: *std.DynamicBitSetUnmanaged,
    /// Scratch for the state's hex form, `digitsFor(parts)` long.
    hex: []u8,
    mutex: std.Io.Mutex = .init,
    /// The next range to fetch, from 0.
    next: u32 = 0,
    /// The first failure, with the details of the worker that met it.
    failure: ?Failure = null,

    const Failure = struct {
        err: Error,
        diag: Diagnostics,
    };

    /// Saves the run's state. The caller holds the lock while workers run;
    /// the first save, before they start, needs none.
    fn save(run: *Run, d: ?*Diagnostics) Error!void {
        checkpoint.hexFromBits(run.written, run.plan.parts, run.hex);
        return saveState(run.client.gpa, run.checkpoint.?, d, .{ .download_parallel = .{
            .bucket = run.bucket,
            .object = run.object,
            .size = run.size,
            .generation = run.generation,
            .part_size = run.plan.part_size,
            .written = run.hex,
        } });
    }

    /// Range `index` is in the destination, hashing to `range_crc`: record
    /// it, and save the checkpoint so no later process fetches it again.
    fn complete(run: *Run, index: u32, range_crc: u32, d: ?*Diagnostics) Error!void {
        run.crcs[index] = range_crc;
        if (run.checkpoint == null) return;
        const io = run.client.io;
        run.mutex.lockUncancelable(io);
        defer run.mutex.unlock(io);
        run.written.set(index);
        try run.save(d);
    }

    /// Fetches every range not already held: `concurrency` workers, each
    /// with a client of its own, on tasks of their own, or one on this task
    /// when the `std.Io` cannot run tasks concurrently.
    fn fetchRanges(run: *Run, options: types.ParallelDownloadOptions) Error!void {
        const gpa = run.client.gpa;
        const io = run.client.io;
        const missing = run.plan.parts - run.written.count();
        const count: usize = @min(options.concurrency, missing);
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
    /// A range the destination already holds is never handed out: its
    /// bytes were re-read, not trusted, and re-fetching them would spend
    /// the transfer a resume is for.
    fn take(run: *Run) ?u32 {
        const io = run.client.io;
        run.mutex.lockUncancelable(io);
        defer run.mutex.unlock(io);
        if (run.failure != null) return null;
        while (run.next < run.plan.parts and run.written.isSet(run.next)) run.next += 1;
        if (run.next == run.plan.parts) return null;
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
        try run.complete(index, result.crc32c, &w.diag);
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

test "downloadParallel: a worker whose request meets Canceled stops the download, which returns Canceled" {
    // No cancel reached the task, so the group returns normally: only the
    // failure the worker recorded keeps unfetched ranges out of the fold.
    for ([_]bool{ true, false }) |verify| {
        var rules = [_]Script.Rule{.{ .at = 4096, .fault = .canceled }};
        var script: Script = .{ .rules = &rules };
        var s: Setup = undefined;
        try s.init(testing.io, .{ .verify_checksums = verify });
        defer s.deinit();
        s.fake.faults = script.plan();
        var data: [16 * 1024]u8 = undefined;
        fill(&data, 17);
        try s.fake.put("o", &data);
        var out: [data.len]u8 = undefined;
        try testing.expectError(error.Canceled, s.object("o").downloadParallel(.{ .buffer = &out }, .{ .part_size = 4096, .concurrency = 2 }));
    }
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
    try s.fake.putGzipped("page.html", decompressed);
    var out: [decompressed.len + 10]u8 = undefined;
    const result = try s.object("page.html").downloadParallel(.{ .buffer = &out }, .{ .part_size = 1024 });
    try testing.expectEqualStrings(decompressed, out[0..result.bytes_written]);
    // Its stored bytes came as stored, and met the stored checksum.
    try testing.expect(result.checksum_verified);
    try testing.expect(result.stored_bytes < result.bytes_written);
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

const MemoryCheckpoint = test_util.MemoryCheckpoint;

/// A client of its own on a shared fake, as each process of a resumed
/// download has, with the range floor lowered to 1 KiB.
fn clientOn(fake: *FakeMultipart, token: *core.StaticToken, diag: *Diagnostics, max_attempts: u8) !Client {
    var client: Client = try .init(testing.allocator, fake.io, .{
        .token_provider = token.provider(),
        .transport = fake.transport(),
        .diagnostics = diag,
        .retry = .{ .max_attempts = max_attempts, .initial_backoff_ms = 1, .max_backoff_ms = 2 },
    });
    client.multipart_test = .{ .min_part_size = 1024 };
    return client;
}

test "downloadParallel: a checkpoint on a buffer destination is refused before anything is sent" {
    var s: Setup = undefined;
    try s.init(testing.io, .{});
    defer s.deinit();
    try s.fake.put("o", "bytes");
    var saved: MemoryCheckpoint = .{ .gpa = testing.allocator };
    defer saved.deinit();
    var out: [16]u8 = undefined;
    try testing.expectError(
        error.InvalidParallelDownloadOptions,
        s.object("o").downloadParallel(.{ .buffer = &out }, .{ .checkpoint = saved.checkpoint() }),
    );
    try expectDiag(&s.diag, "only a file destination outlives a process");
    try testing.expectEqual(0, s.fake.counts.reads);
    try testing.expectEqual(0, saved.loads);
}

test "downloadParallel with a checkpoint: saved at the start and after every range, cleared at the end" {
    var s: Setup = undefined;
    try s.init(testing.io, .{});
    defer s.deinit();
    var data: [5 * 1024]u8 = undefined;
    fill(&data, 20);
    try s.fake.put("o", &data);
    var saved: MemoryCheckpoint = .{ .gpa = testing.allocator };
    defer saved.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try junkFile(&tmp, "");
    defer file.close(testing.io);

    const result = try s.object("o").downloadParallel(.{ .file = file }, .{
        .part_size = 1024,
        .concurrency = 2,
        .checkpoint = saved.checkpoint(),
    });
    try testing.expect(result.checksum_verified);
    const got = try readBack(&tmp);
    defer testing.allocator.free(got);
    try testing.expectEqualSlices(u8, &data, got);
    // One save when the download starts, one per range, one clear.
    try testing.expectEqual(1 + 5, saved.saves);
    try testing.expectEqual(1, saved.clears);
    try testing.expectEqual(null, saved.stored);
}

test "downloadParallel: a run that dies partway leaves a checkpoint file a second client resumes, fetching only what is missing" {
    var fake: FakeMultipart = .init(testing.allocator, testing.io);
    defer fake.deinit();
    var token: core.StaticToken = .{ .token = "ya29.t" };
    var data: [5 * 1024 + 7]u8 = undefined;
    fill(&data, 21);
    try fake.put("dir/o", &data);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try junkFile(&tmp, "an older file");
    defer file.close(testing.io);
    var store: checkpoint.CheckpointFile = .init(testing.io, tmp.dir, "o.download");
    const options: types.ParallelDownloadOptions = .{
        .part_size = 1024,
        .concurrency = 1,
        .checkpoint = store.checkpoint(),
    };

    // The first process: two ranges land, the third request dies with the
    // process, as it were.
    var rules = [_]Script.Rule{.{ .at = 2 * 1024, .fault = .canceled }};
    var script: Script = .{ .rules = &rules };
    fake.faults = script.plan();
    {
        var diag: Diagnostics = .{};
        var first = try clientOn(&fake, &token, &diag, 4);
        defer first.deinit();
        try testing.expectError(
            error.Canceled,
            first.bucket("b").object("dir/o").downloadParallel(.{ .file = file }, options),
        );
    }
    try testing.expectEqual(2, fake.counts.media);
    try testing.expectEqual(2 * 1024, fake.counts.media_bytes);

    // The second process fetches the four missing ranges and nothing it
    // already has, and the whole is verified.
    fake.faults = null;
    var diag: Diagnostics = .{};
    var second = try clientOn(&fake, &token, &diag, 4);
    defer second.deinit();
    const result = try second.bucket("b").object("dir/o").downloadParallel(.{ .file = file }, options);
    try testing.expect(result.checksum_verified);
    try testing.expectEqual(data.len, result.bytes_written);
    try testing.expectEqual(core.crc32c.hash(&data), result.crc32c);
    try testing.expectEqual(2 + 4, fake.counts.media);
    try testing.expectEqual(data.len, fake.counts.media_bytes);
    try testing.expectEqual(2, fake.counts.reads);
    const got = try readBack(&tmp);
    defer testing.allocator.free(got);
    try testing.expectEqualSlices(u8, &data, got);
    // The transfer is done: the checkpoint file is gone.
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(testing.io, "o.download", .{}));
}

test "downloadParallel: a resumed run re-reads the file, so bytes changed on disk fail the checksum and clear the checkpoint" {
    var fake: FakeMultipart = .init(testing.allocator, testing.io);
    defer fake.deinit();
    var token: core.StaticToken = .{ .token = "ya29.t" };
    var data: [4 * 1024]u8 = undefined;
    fill(&data, 22);
    try fake.put("o", &data);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try junkFile(&tmp, "");
    defer file.close(testing.io);
    var saved: MemoryCheckpoint = .{ .gpa = testing.allocator };
    defer saved.deinit();
    const options: types.ParallelDownloadOptions = .{
        .part_size = 1024,
        .concurrency = 1,
        .checkpoint = saved.checkpoint(),
    };

    var rules = [_]Script.Rule{.{ .at = 2 * 1024, .fault = .canceled }};
    var script: Script = .{ .rules = &rules };
    fake.faults = script.plan();
    var diag: Diagnostics = .{};
    var client = try clientOn(&fake, &token, &diag, 4);
    defer client.deinit();
    try testing.expectError(error.Canceled, client.bucket("b").object("o").downloadParallel(.{ .file = file }, options));
    try testing.expect(saved.stored != null);

    // Someone edits the partial file between the runs.
    try file.writePositionalAll(testing.io, &.{data[100] ^ 0x01}, 100);
    fake.faults = null;
    try testing.expectError(error.ChecksumMismatch, client.bucket("b").object("o").downloadParallel(.{ .file = file }, options));
    try expectDiag(&diag, "discard what the destination holds");
    // The state was cleared with the bytes discredited, so the next run is
    // whole, and right.
    try testing.expectEqual(null, saved.stored);
    const result = try client.bucket("b").object("o").downloadParallel(.{ .file = file }, options);
    try testing.expect(result.checksum_verified);
    const got = try readBack(&tmp);
    defer testing.allocator.free(got);
    try testing.expectEqualSlices(u8, &data, got);
}

test "downloadParallel: a file no longer the object's length starts over instead of resuming" {
    var fake: FakeMultipart = .init(testing.allocator, testing.io);
    defer fake.deinit();
    var token: core.StaticToken = .{ .token = "ya29.t" };
    var data: [4 * 1024]u8 = undefined;
    fill(&data, 34);
    try fake.put("o", &data);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try junkFile(&tmp, "");
    defer file.close(testing.io);
    var saved: MemoryCheckpoint = .{ .gpa = testing.allocator };
    defer saved.deinit();
    const options: types.ParallelDownloadOptions = .{
        .part_size = 1024,
        .concurrency = 1,
        .checkpoint = saved.checkpoint(),
    };

    var rules = [_]Script.Rule{.{ .at = 2 * 1024, .fault = .canceled }};
    var script: Script = .{ .rules = &rules };
    fake.faults = script.plan();
    var diag: Diagnostics = .{};
    var client = try clientOn(&fake, &token, &diag, 4);
    defer client.deinit();
    try testing.expectError(error.Canceled, client.bucket("b").object("o").downloadParallel(.{ .file = file }, options));
    fake.faults = null;

    // Someone truncated the file: what the checkpoint says it holds is
    // gone, so nothing of it is trusted.
    try file.setLength(testing.io, 5);
    const media_before = fake.counts.media;
    const result = try client.bucket("b").object("o").downloadParallel(.{ .file = file }, options);
    try testing.expect(result.checksum_verified);
    try testing.expectEqual(4, fake.counts.media - media_before);
    const got = try readBack(&tmp);
    defer testing.allocator.free(got);
    try testing.expectEqualSlices(u8, &data, got);
}

test "downloadParallel: a checkpoint of a finished download re-reads everything and fetches nothing" {
    var s: Setup = undefined;
    try s.init(testing.io, .{});
    defer s.deinit();
    var data: [4 * 1024]u8 = undefined;
    fill(&data, 23);
    try s.fake.put("o", &data);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try junkFile(&tmp, "");
    defer file.close(testing.io);
    // The process dies between the last range and the clear.
    var saved: MemoryCheckpoint = .{ .gpa = testing.allocator, .keep_on_clear = true };
    defer saved.deinit();
    const options: types.ParallelDownloadOptions = .{ .part_size = 1024, .checkpoint = saved.checkpoint() };
    _ = try s.object("o").downloadParallel(.{ .file = file }, options);
    try testing.expect(saved.stored != null);
    try testing.expectEqual(4, s.fake.counts.media);

    saved.keep_on_clear = false;
    const result = try s.object("o").downloadParallel(.{ .file = file }, options);
    try testing.expect(result.checksum_verified);
    try testing.expectEqual(data.len, result.bytes_written);
    try testing.expectEqual(core.crc32c.hash(&data), result.crc32c);
    // No range was fetched again; the file alone answered.
    try testing.expectEqual(4, s.fake.counts.media);
    try testing.expectEqual(null, saved.stored);
}

test "downloadParallel: a generation gone starts the checkpoint over at the live object, unless the caller pinned it" {
    var fake: FakeMultipart = .init(testing.allocator, testing.io);
    defer fake.deinit();
    var token: core.StaticToken = .{ .token = "ya29.t" };
    var data: [4 * 1024]u8 = undefined;
    fill(&data, 24);
    try fake.put("o", &data);
    const first_generation = fake.object("o").?.generation;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try junkFile(&tmp, "");
    defer file.close(testing.io);
    var saved: MemoryCheckpoint = .{ .gpa = testing.allocator };
    defer saved.deinit();
    const options: types.ParallelDownloadOptions = .{
        .part_size = 1024,
        .concurrency = 1,
        .checkpoint = saved.checkpoint(),
    };

    var rules = [_]Script.Rule{.{ .at = 2 * 1024, .fault = .canceled }};
    var script: Script = .{ .rules = &rules };
    fake.faults = script.plan();
    var diag: Diagnostics = .{};
    var client = try clientOn(&fake, &token, &diag, 4);
    defer client.deinit();
    try testing.expectError(error.Canceled, client.bucket("b").object("o").downloadParallel(.{ .file = file }, options));
    fake.faults = null;

    // The object is replaced. A caller pinned to the checkpoint's
    // generation learns it is gone; the state stays theirs to resume
    // against a versioned bucket.
    var replacement: [4 * 1024]u8 = undefined;
    fill(&replacement, 25);
    try fake.put("o", &replacement);
    var pinned = options;
    pinned.generation = first_generation;
    try testing.expectError(error.NotFound, client.bucket("b").object("o").downloadParallel(.{ .file = file }, pinned));
    try testing.expect(saved.stored != null);

    // A caller with no generation of their own starts over at the live
    // object, from the start.
    const media_before = fake.counts.media;
    const result = try client.bucket("b").object("o").downloadParallel(.{ .file = file }, options);
    try testing.expect(result.checksum_verified);
    try testing.expectEqual(4, fake.counts.media - media_before);
    const got = try readBack(&tmp);
    defer testing.allocator.free(got);
    try testing.expectEqualSlices(u8, &replacement, got);
    try testing.expectEqual(null, saved.stored);
}

test "downloadParallel: a caller generation different from the checkpoint's starts over at that generation" {
    var fake: FakeMultipart = .init(testing.allocator, testing.io);
    defer fake.deinit();
    var token: core.StaticToken = .{ .token = "ya29.t" };
    var data: [3 * 1024]u8 = undefined;
    fill(&data, 26);
    try fake.put("o", &data);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try junkFile(&tmp, "");
    defer file.close(testing.io);
    var saved: MemoryCheckpoint = .{ .gpa = testing.allocator };
    defer saved.deinit();
    const options: types.ParallelDownloadOptions = .{
        .part_size = 1024,
        .concurrency = 1,
        .checkpoint = saved.checkpoint(),
    };

    var rules = [_]Script.Rule{.{ .at = 1024, .fault = .canceled }};
    var script: Script = .{ .rules = &rules };
    fake.faults = script.plan();
    var diag: Diagnostics = .{};
    var client = try clientOn(&fake, &token, &diag, 4);
    defer client.deinit();
    try testing.expectError(error.Canceled, client.bucket("b").object("o").downloadParallel(.{ .file = file }, options));
    fake.faults = null;

    var replacement: [3 * 1024]u8 = undefined;
    fill(&replacement, 27);
    try fake.put("o", &replacement);
    var pinned = options;
    pinned.generation = fake.object("o").?.generation;
    const media_before = fake.counts.media;
    const result = try client.bucket("b").object("o").downloadParallel(.{ .file = file }, pinned);
    try testing.expect(result.checksum_verified);
    // Everything was fetched: the checkpoint described another generation.
    try testing.expectEqual(3, fake.counts.media - media_before);
    const got = try readBack(&tmp);
    defer testing.allocator.free(got);
    try testing.expectEqualSlices(u8, &replacement, got);
}

test "downloadParallel: a checkpoint of another transfer, or one unreadable, is refused before anything is sent and kept" {
    var s: Setup = undefined;
    try s.init(testing.io, .{});
    defer s.deinit();
    try s.fake.put("o", "bytes of o");
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try junkFile(&tmp, "");
    defer file.close(testing.io);

    // A state this library wrote, for another object.
    const foreign = try checkpoint.encodeAlloc(testing.allocator, .{ .download_parallel = .{
        .bucket = "b",
        .object = "someone-elses",
        .size = 5000,
        .generation = 42,
        .part_size = 1024,
        .written = "50",
    } });
    var saved: MemoryCheckpoint = .{ .gpa = testing.allocator, .stored = foreign };
    defer saved.deinit();
    const options: types.ParallelDownloadOptions = .{ .part_size = 1024, .checkpoint = saved.checkpoint() };
    try testing.expectError(error.CheckpointFailed, s.object("o").downloadParallel(.{ .file = file }, options));
    try expectDiag(&s.diag, "belongs to another transfer");
    try testing.expectEqualStrings(foreign, saved.stored.?);

    // Bytes that are no state at all.
    var garbage: MemoryCheckpoint = .{ .gpa = testing.allocator, .stored = try testing.allocator.dupe(u8, "tracker-v2?") };
    defer garbage.deinit();
    try testing.expectError(error.CheckpointFailed, s.object("o").downloadParallel(.{ .file = file }, .{
        .part_size = 1024,
        .checkpoint = garbage.checkpoint(),
    }));
    try expectDiag(&s.diag, "no state this library wrote");

    // A load that fails outright.
    var unreadable: MemoryCheckpoint = .{ .gpa = testing.allocator, .fail_loads = true };
    defer unreadable.deinit();
    try testing.expectError(error.CheckpointFailed, s.object("o").downloadParallel(.{ .file = file }, .{
        .part_size = 1024,
        .checkpoint = unreadable.checkpoint(),
    }));
    try expectDiag(&s.diag, "could not be read");

    // None of it reached the server.
    try testing.expectEqual(0, s.fake.counts.reads);
    try testing.expectEqual(0, s.fake.counts.media);
}

test "downloadParallel: a save that fails at the start moves no data; one that fails later fails the run and keeps the state" {
    var fake: FakeMultipart = .init(testing.allocator, testing.io);
    defer fake.deinit();
    var token: core.StaticToken = .{ .token = "ya29.t" };
    var data: [6 * 1024]u8 = undefined;
    fill(&data, 28);
    try fake.put("o", &data);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try junkFile(&tmp, "");
    defer file.close(testing.io);
    var diag: Diagnostics = .{};
    var client = try clientOn(&fake, &token, &diag, 4);
    defer client.deinit();

    // The very first save fails: the metadata was read, no byte moved.
    var saved: MemoryCheckpoint = .{ .gpa = testing.allocator, .saves_allowed = 0 };
    defer saved.deinit();
    const options: types.ParallelDownloadOptions = .{
        .part_size = 1024,
        .concurrency = 1,
        .checkpoint = saved.checkpoint(),
    };
    try testing.expectError(error.CheckpointFailed, client.bucket("b").object("o").downloadParallel(.{ .file = file }, options));
    try expectDiag(&diag, "refused a save");
    try testing.expectEqual(0, fake.counts.media);

    // Saves fail after the start and two ranges: the run fails, and what
    // was recorded resumes.
    saved.saves_allowed = 3;
    try testing.expectError(error.CheckpointFailed, client.bucket("b").object("o").downloadParallel(.{ .file = file }, options));
    try testing.expect(saved.stored != null);
    saved.saves_allowed = null;
    const media_before = fake.counts.media;
    const result = try client.bucket("b").object("o").downloadParallel(.{ .file = file }, options);
    try testing.expect(result.checksum_verified);
    // Ranges 1 and 2 were recorded; range 3 landed but its save failed, so
    // it alone is fetched again beside the three never fetched.
    try testing.expectEqual(4, fake.counts.media - media_before);
    const got = try readBack(&tmp);
    defer testing.allocator.free(got);
    try testing.expectEqualSlices(u8, &data, got);
}

test "downloadParallel: with a checkpoint, a cancel keeps the state for the next run" {
    var fake: FakeMultipart = .init(testing.allocator, testing.io);
    defer fake.deinit();
    var token: core.StaticToken = .{ .token = "ya29.t" };
    var rules = [_]Script.Rule{.{ .at = 1024, .fault = .wait }};
    var script: Script = .{ .rules = &rules };
    fake.faults = script.plan();
    var data: [3 * 1024]u8 = undefined;
    fill(&data, 29);
    try fake.put("o", &data);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try junkFile(&tmp, "");
    defer file.close(testing.io);
    var saved: MemoryCheckpoint = .{ .gpa = testing.allocator };
    defer saved.deinit();
    var diag: Diagnostics = .{};
    var client = try clientOn(&fake, &token, &diag, 4);
    defer client.deinit();
    const options: types.ParallelDownloadOptions = .{
        .part_size = 1024,
        .concurrency = 2,
        .checkpoint = saved.checkpoint(),
    };

    const Running = struct {
        fn go(target: Object, destination: std.Io.File, opts: types.ParallelDownloadOptions) Error!void {
            _ = try target.downloadParallel(.{ .file = destination }, opts);
        }
    };
    var task = try testing.io.concurrent(Running.go, .{ client.bucket("b").object("o"), file, options });
    const deadline = std.Io.Clock.awake.now(testing.io).addDuration(.fromSeconds(10));
    while (true) {
        fake.mutex.lockUncancelable(testing.io);
        const served = fake.counts.media;
        fake.mutex.unlock(testing.io);
        if (served >= 2) break;
        if (std.Io.Clock.awake.now(testing.io).nanoseconds > deadline.nanoseconds) @panic("the download never fetched the two ranges not held back");
        try testing.io.sleep(.fromMilliseconds(1), .awake);
    }
    try testing.expectError(error.Canceled, task.cancel(testing.io));
    // The cancel kept the state; the second run finishes the work.
    try testing.expect(saved.stored != null);
    try testing.expect(saved.clears == 0);
    fake.faults = null;
    fake.gate.set(testing.io);
    const result = try client.bucket("b").object("o").downloadParallel(.{ .file = file }, options);
    try testing.expect(result.checksum_verified);
    const got = try readBack(&tmp);
    defer testing.allocator.free(got);
    try testing.expectEqualSlices(u8, &data, got);
    try testing.expectEqual(null, saved.stored);
}

test "downloadParallel: a gzip-stored object with a checkpoint saves nothing and clears at the end" {
    var s: Setup = undefined;
    try s.init(testing.io, .{});
    defer s.deinit();
    const decompressed = "what the object decompresses to";
    try s.fake.putGzipped("page", decompressed);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try junkFile(&tmp, "old");
    defer file.close(testing.io);
    var saved: MemoryCheckpoint = .{ .gpa = testing.allocator };
    defer saved.deinit();
    const result = try s.object("page").downloadParallel(.{ .file = file }, .{
        .part_size = 1024,
        .checkpoint = saved.checkpoint(),
    });
    // A whole-object fetch cannot resume, so there is nothing to save, and
    // a finished one leaves no state behind.
    try testing.expectEqual(decompressed.len, result.bytes_written);
    try testing.expectEqual(0, saved.saves);
    try testing.expectEqual(1, saved.clears);
}

test "downloadParallel: an empty object with a checkpoint records the transfer and clears it" {
    var s: Setup = undefined;
    try s.init(testing.io, .{});
    defer s.deinit();
    try s.fake.put("empty", "");
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try junkFile(&tmp, "yesterday's bytes");
    defer file.close(testing.io);
    var saved: MemoryCheckpoint = .{ .gpa = testing.allocator };
    defer saved.deinit();
    const result = try s.object("empty").downloadParallel(.{ .file = file }, .{ .checkpoint = saved.checkpoint() });
    try testing.expectEqual(0, result.bytes_written);
    try testing.expectEqual(0, try file.length(testing.io));
    try testing.expectEqual(1, saved.saves);
    try testing.expectEqual(1, saved.clears);
    try testing.expectEqual(null, saved.stored);
}

test "the checkpoint's state reaches neither the log nor the diagnostics" {
    logging.capture.reset();
    var fake: FakeMultipart = .init(testing.allocator, testing.io);
    defer fake.deinit();
    var token: core.StaticToken = .{ .token = "ya29.t" };
    var data: [3 * 1024]u8 = undefined;
    fill(&data, 30);
    try fake.put("o", &data);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try junkFile(&tmp, "");
    defer file.close(testing.io);
    var saved: MemoryCheckpoint = .{ .gpa = testing.allocator };
    defer saved.deinit();
    var diag: Diagnostics = .{};
    var client = try clientOn(&fake, &token, &diag, 4);
    defer client.deinit();
    const options: types.ParallelDownloadOptions = .{
        .part_size = 1024,
        .concurrency = 1,
        .checkpoint = saved.checkpoint(),
    };

    // A run that dies and a resume, the paths that touch the state most.
    var rules = [_]Script.Rule{.{ .at = 1024, .fault = .canceled }};
    var script: Script = .{ .rules = &rules };
    fake.faults = script.plan();
    try testing.expectError(error.Canceled, client.bucket("b").object("o").downloadParallel(.{ .file = file }, options));
    fake.faults = null;
    _ = try client.bucket("b").object("o").downloadParallel(.{ .file = file }, options);

    try testing.expect(logging.capture.lines > 0);
    // The state's own shape never appears: not its keys, not its bitmap.
    try testing.expectEqual(null, std.mem.indexOf(u8, logging.capture.text(), "\"kind\""));
    try testing.expectEqual(null, std.mem.indexOf(u8, logging.capture.text(), "\"written\""));
    try testing.expectEqual(null, std.mem.indexOf(u8, diag.message(), "\"kind\""));
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
    try fake.putGzipped("z", "served");
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
    if (gzip) try s.fake.putGzipped("o", data) else try s.fake.put("o", data);
    var chooser: Chooser = .{ .bytes = g.rest() };
    s.fake.faults = chooser.plan();

    const expected: []const u8 = data;
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
        // A gzip object's stored bytes meet the stored checksum like any
        // other object's.
        try testing.expectEqual(verify, result.checksum_verified);
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

/// Lets every request through, recording each media read's first byte, so
/// a resume can prove it fetched nothing the file already held.
const MediaRecorder = struct {
    gpa: Allocator,
    starts: std.ArrayList(u64) = .empty,

    fn deinit(self: *MediaRecorder) void {
        self.starts.deinit(self.gpa);
    }

    fn plan(self: *MediaRecorder) FakeMultipart.FaultPlan {
        return .{ .ctx = self, .decide = decide };
    }

    fn decide(ctx: ?*anyopaque, kind: FakeMultipart.Kind, part: u32) FakeMultipart.Fault {
        const self: *MediaRecorder = @ptrCast(@alignCast(ctx.?));
        if (kind == .media) self.starts.append(self.gpa, part - 1) catch @panic("out of memory recording a range");
        return .none;
    }
};

/// One download under drawn faults, cut wherever they cut it, then a
/// second run with the same checkpoint and no faults: the file ends up
/// exactly the object, and a resume at the checkpoint's generation fetches
/// no range the file already holds. The one legitimate second-run failure
/// is a checksum mismatch over bytes the first run's fault corrupted,
/// which clears the state, so a third run is whole and right.
fn resumeUnderFaults(input: []const u8) !void {
    var g: test_util.ByteGen = .init(input);
    const size = g.intRange(usize, 0, 40 * 1024);
    const part_size = g.intRange(u64, 1024, 12 * 1024);
    const concurrency = g.intRange(u16, 1, 4);
    const data = try testing.allocator.alloc(u8, size);
    defer testing.allocator.free(data);
    fill(data, g.int(u64));

    var fake: FakeMultipart = .init(testing.allocator, testing.io);
    defer fake.deinit();
    try fake.put("o", data);
    var token: core.StaticToken = .{ .token = "ya29.t" };
    var saved: MemoryCheckpoint = .{ .gpa = testing.allocator };
    defer saved.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try junkFile(&tmp, "an older file's bytes");
    defer file.close(testing.io);
    const options: types.ParallelDownloadOptions = .{
        .part_size = part_size,
        .concurrency = concurrency,
        .checkpoint = saved.checkpoint(),
    };

    var chooser: Chooser = .{ .bytes = g.rest() };
    fake.faults = chooser.plan();
    var first_diag: Diagnostics = .{};
    var first = try clientOn(&fake, &token, &first_diag, 2);
    defer first.deinit();
    if (first.bucket("b").object("o").downloadParallel(.{ .file = file }, options)) |_| {} else |err| {
        errdefer std.debug.print("first run: {t}: {s}\n", .{ err, first_diag.message() });
        // Only a fault ends a first run.
        try testing.expect(chooser.faulted);
    }

    // What the state records, before the second run moves it on.
    var state_arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer state_arena.deinit();
    var held_offsets: std.ArrayList(u64) = .empty;
    defer held_offsets.deinit(testing.allocator);
    var recorded_generation: ?u64 = null;
    if (saved.stored) |bytes| {
        // Whatever the faults did, the state is one this library wrote.
        const state = try checkpoint.parse(state_arena.allocator(), bytes);
        const s = state.download_parallel;
        try testing.expectEqualStrings("o", s.object);
        try testing.expectEqual(data.len, s.size);
        const plan = mp.plan(s.size, s.part_size);
        var bits = try checkpoint.bitsFromHex(testing.allocator, s.written, plan.parts);
        defer bits.deinit(testing.allocator);
        var i: u32 = 0;
        while (i < plan.parts) : (i += 1) {
            if (bits.isSet(i)) try held_offsets.append(testing.allocator, plan.offset(i));
        }
        recorded_generation = s.generation;
    }

    var recorder: MediaRecorder = .{ .gpa = testing.allocator };
    defer recorder.deinit();
    fake.faults = recorder.plan();
    var diag: Diagnostics = .{};
    var second = try clientOn(&fake, &token, &diag, 4);
    defer second.deinit();
    const target = second.bucket("b").object("o");
    const result = target.downloadParallel(.{ .file = file }, options) catch |err| {
        errdefer std.debug.print("second run: {t}: {s}\n", .{ err, diag.message() });
        try testing.expectEqual(error.ChecksumMismatch, err);
        try testing.expect(chooser.faulted);
        try testing.expectEqual(null, saved.stored);
        const third = try target.downloadParallel(.{ .file = file }, options);
        try testing.expect(third.checksum_verified);
        const rewritten = try readBack(&tmp);
        defer testing.allocator.free(rewritten);
        try testing.expectEqualSlices(u8, data, rewritten);
        return;
    };

    try testing.expectEqual(data.len, result.bytes_written);
    try testing.expect(result.checksum_verified);
    try testing.expectEqual(core.crc32c.hash(data), result.crc32c);
    try testing.expectEqual(null, saved.stored);
    const written = try readBack(&tmp);
    defer testing.allocator.free(written);
    try testing.expectEqualSlices(u8, data, written);

    // A resume at the recorded generation never fetches a held range. (At
    // another generation the state was rightly discarded, and everything
    // is fetched.)
    if (recorded_generation == fake.object("o").?.generation) {
        for (recorder.starts.items) |start| {
            for (held_offsets.items) |held| try testing.expect(start != held);
        }
    }
}

fn resumeProperty(_: void, input: []const u8) !void {
    try resumeUnderFaults(input);
}

// About 9 ms a run in Debug, with two or three downloads over real
// threads and a real file: named out of the nightly's "fuzz" and "slow
// property" filters, like the other parallel fault properties, until a
// job of its own is sized for them.
test "fault property parallel resume: a second run completes the object, fetching nothing the file holds" {
    try test_util.fuzzBytes({}, resumeProperty, .{
        .random_runs = 100,
        .max_len = 256,
        .corpus = &.{
            "",
            // 40 KiB in 1 KiB ranges, 4 at once, a cut and a lost answer.
            "\xff\xff\xff\xff\xff\xff\xff\xff\x00\x00\x00\x00\x00\x00\x00\x00\x00\x03\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\xe0\xd8",
            // A corrupted range, then a connection cut: the second run
            // meets the mismatch and the third puts it right.
            "\x80\x00\x00\x00\x00\x00\x00\x00\x00\x10\x00\x00\x00\x00\x00\x00\x00\x02\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\xeb\xe6\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\xe6",
        },
    });
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

test "downloadParallel over real sockets: a download its connection keeps killing resumes on a second client" {
    // Four resets exhaust the first client's four attempts on one range:
    // that process is done, two ranges down.
    var rules = [_]Script.Rule{.{ .at = 16 * 1024, .times = 4, .fault = .reset }};
    var script: Script = .{ .rules = &rules };
    var s: OverSockets = undefined;
    try s.init();
    defer s.deinit();
    s.fake.faults = script.plan();
    var data: [40 * 1024 + 5]u8 = undefined;
    fill(&data, 32);
    try s.fake.put("dir/o", &data);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try junkFile(&tmp, "");
    defer file.close(testing.io);
    var store: checkpoint.CheckpointFile = .init(testing.io, tmp.dir, "o.download");
    const options: types.ParallelDownloadOptions = .{
        .part_size = 8 * 1024,
        .concurrency = 1,
        .checkpoint = store.checkpoint(),
    };
    try testing.expectError(
        error.ConnectionResetByPeer,
        s.client.bucket("b").object("dir/o").downloadParallel(.{ .file = file }, options),
    );
    try testing.expectEqual(2, s.fake.counts.media);

    // A second client, over connections of its own, finishes the object.
    var url_buf: [64]u8 = undefined;
    var diag: Diagnostics = .{};
    var second: Client = try .init(testing.allocator, testing.io, .{
        .endpoint = .{ .url = s.server.url(&url_buf), .emulator = true },
        .diagnostics = &diag,
        .retry = .{ .max_attempts = 4, .initial_backoff_ms = 1, .max_backoff_ms = 2 },
    });
    defer second.deinit();
    second.multipart_test = .{ .min_part_size = 1024 };
    const result = try second.bucket("b").object("dir/o").downloadParallel(.{ .file = file }, options);
    try testing.expect(result.checksum_verified);
    try testing.expectEqual(core.crc32c.hash(&data), result.crc32c);
    // The four missing ranges and nothing more, and the state is gone.
    try testing.expectEqual(2 + 4, s.fake.counts.media);
    try testing.expectEqual(data.len, s.fake.counts.media_bytes);
    const got = try readBack(&tmp);
    defer testing.allocator.free(got);
    try testing.expectEqualSlices(u8, &data, got);
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(testing.io, "o.download", .{}));
}

fn downloadWithCheckpoint(gpa: Allocator) !void {
    var fake: FakeMultipart = .init(gpa, testing.io);
    defer fake.deinit();
    var token: core.StaticToken = .{ .token = "ya29.t" };
    var client: Client = try .init(gpa, testing.io, .{
        .token_provider = token.provider(),
        .transport = fake.transport(),
    });
    defer client.deinit();
    client.multipart_test = .{ .min_part_size = 1024 };
    var data: [3000]u8 = undefined;
    fill(&data, 33);
    try fake.put("o", &data);
    var saved: MemoryCheckpoint = .{ .gpa = gpa };
    defer saved.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try junkFile(&tmp, "");
    defer file.close(testing.io);
    // One worker, so the allocation count is the same on every pass.
    _ = try client.bucket("b").object("o").downloadParallel(.{ .file = file }, .{
        .part_size = 1024,
        .concurrency = 1,
        .checkpoint = saved.checkpoint(),
    });
}

test "downloadParallel with a checkpoint: every allocation failure is OutOfMemory, and nothing leaks" {
    try testing.checkAllAllocationFailures(testing.allocator, downloadWithCheckpoint, .{});
}

test "Run: ranges are handed out once each, never a held one, and none after a failure; the first failure is kept" {
    var s: Setup = undefined;
    try s.init(testing.io, .{});
    defer s.deinit();
    var crcs: [5]u32 = undefined;
    var written: std.DynamicBitSetUnmanaged = try .initEmpty(testing.allocator, 5);
    defer written.deinit(testing.allocator);
    var hex: [2]u8 = undefined;
    var run: Run = .{
        .client = &s.client,
        .bucket = "b",
        .object = "o",
        .size = 5 * 1024,
        .generation = 1,
        .destination = .{ .buffer = &.{} },
        .plan = mp.plan(5 * 1024, 1024),
        .crcs = &crcs,
        .checkpoint = null,
        .written = &written,
        .hex = &hex,
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

    // Ranges the destination holds are stepped over, first, midway and
    // last.
    written.set(0);
    written.set(2);
    written.set(4);
    var resumed: Run = run;
    resumed.failure = null;
    resumed.next = 0;
    try testing.expectEqual(1, resumed.take().?);
    try testing.expectEqual(3, resumed.take().?);
    try testing.expectEqual(null, resumed.take());
}
