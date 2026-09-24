//! Parallel uploads: one object sent as parts, `concurrency` at a time,
//! each on a client and connection of its own, through the XML API's
//! multipart upload, and joined by Cloud Storage.
//!
//! The flow: check the options; start an upload; send every part, hashing
//! each as it goes and holding it to the CRC32C Cloud Storage stored for
//! it; fold the parts' CRC32Cs into the whole object's, and hold that to
//! the caller's checksum before anything is joined; finish; hold the
//! finished object to the same checksum; read its metadata back. Every
//! failure after the start aborts the upload, so no part stays behind to be
//! billed.
//!
//! No retry can write twice. Sending a part again replaces it, and a finish
//! that landed before its answer was lost finds no upload the second time:
//! it answers 404 `NoSuchUpload`, which reading the object back resolves.
//!
//! Against an emulator the object goes up as one ordinary upload instead:
//! fake-gcs-server has no multipart uploads.

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("core");

const Client = @import("Client.zig");
const Object = @import("Object.zig");
const codec = @import("codec.zig");
const logging = @import("logging.zig");
const mp = @import("xml_multipart.zig");
const names = @import("names.zig");
const rpc = @import("rpc.zig");
const hasDotSegment = @import("signing.zig").hasDotSegment;
const types = @import("types.zig");
const xml = @import("xml.zig");
const Error = @import("errors.zig").Error;
const Diagnostics = core.Diagnostics;

pub const max_concurrency = 64;

/// Custom metadata's limit as headers: "Any valid header name and value,
/// with a maximum combined size of 8 KiB."
pub const max_metadata_bytes = 8 * 1024;
const meta_prefix = "x-goog-meta-";

/// Cloud Storage's part ETags are 34 bytes: an MD5 in hex, in quotes.
const max_etag_len = 128;

/// What each worker reads a file through.
const file_buffer_len = 64 * 1024;

/// Uploads `source` as `object`. The caller has begun the call and checked
/// both names.
pub fn upload(
    client: *Client,
    bucket: []const u8,
    object: []const u8,
    source: types.ParallelSource,
    options: types.ParallelUploadOptions,
) Error!types.Owned(types.ObjectInfo) {
    try check(client, object, options);
    const size = try sourceSize(client, source);
    if (size > mp.max_object_size) {
        if (client.diagnostics) |d| d.print("the source is {d} bytes, and an object holds at most 5 TiB", .{size});
        return error.InvalidParallelUploadOptions;
    }
    if (client.unauthenticated and !client.multipart_test.on_emulator) {
        return fallback(client, bucket, object, source, size, options);
    }
    return multipart(client, bucket, object, source, size, options);
}

/// Refuses what the XML API could not carry faithfully, and what Cloud
/// Storage would refuse only after every part had gone up.
pub fn check(client: *const Client, object: []const u8, options: types.ParallelUploadOptions) Error!void {
    const d = client.diagnostics;
    const floor = client.multipart_test.min_part_size orelse mp.min_part_size;
    if (options.part_size < floor or options.part_size > mp.max_part_size) {
        return refuse(d, "part_size: {d} bytes, where Cloud Storage takes 5 MiB to 5 GiB", .{options.part_size});
    }
    if (options.concurrency < 1 or options.concurrency > max_concurrency) {
        return refuse(d, "concurrency: 1 to {d}, not {d}", .{ max_concurrency, options.concurrency });
    }
    const fixed = [_]struct { []const u8, ?[]const u8 }{
        .{ "content_type", options.content_type },
        .{ "cache_control", options.cache_control },
        .{ "content_disposition", options.content_disposition },
        .{ "content_encoding", options.content_encoding },
        .{ "content_language", options.content_language },
    };
    for (fixed) |field| {
        const value = field[1] orelse continue;
        if (value.len == 0 or !core.transport.isValidHeaderValue(value) or !isAscii(value)) {
            return refuse(d, "{s}: a header value, not empty, printable ASCII without a space at either end; leave it null to send none", .{field[0]});
        }
    }
    var total: usize = 0;
    for (options.metadata, 0..) |entry, i| {
        if (!isMetadataKey(entry.key)) {
            return refuse(d, "metadata {d}: a key is lowercase letters, digits and !#$%&'*+-.^_`|~, since it travels as a header name", .{i});
        }
        if (!core.transport.isValidHeaderValue(entry.value) or !isAscii(entry.value)) {
            return refuse(d, "metadata key {s}: a value is printable ASCII without a space at either end, since it travels as a header", .{entry.key});
        }
        for (options.metadata[0..i]) |earlier| if (std.mem.eql(u8, earlier.key, entry.key)) {
            return refuse(d, "metadata key {s} appears twice; one object gives a key one value", .{entry.key});
        };
        total += meta_prefix.len + entry.key.len + entry.value.len;
    }
    if (total > max_metadata_bytes) {
        return refuse(d, "custom metadata takes {d} bytes as headers, and Cloud Storage takes at most {d}", .{ total, max_metadata_bytes });
    }
    if (hasDotSegment(object)) {
        return refuse(d, "the object name has a \".\" or \"..\" segment, which HTTP clients remove from a URL's path before sending it", .{});
    }
}

fn refuse(d: ?*Diagnostics, comptime format: []const u8, args: anytype) Error {
    if (d) |diag| diag.print(format, args);
    return error.InvalidParallelUploadOptions;
}

/// A custom metadata key as a header name can carry it, lowercase, since
/// header names are case-insensitive and the JSON API keeps a key's case.
fn isMetadataKey(key: []const u8) bool {
    if (key.len == 0) return false;
    for (key) |c| {
        if ((c >= 'a' and c <= 'z') or (c >= '0' and c <= '9')) continue;
        if (std.mem.indexOfScalar(u8, "!#$%&'*+-.^_`|~", c) == null) return false;
    }
    return true;
}

/// Google: "you should generally avoid non-ascii characters, because they
/// are not permitted in HTTP headers, which the XML API uses".
fn isAscii(text: []const u8) bool {
    for (text) |c| if (c >= 0x80) return false;
    return true;
}

fn sourceSize(client: *Client, source: types.ParallelSource) Error!u64 {
    return switch (source) {
        .data => |data| data.len,
        .file => |file| file.length(client.io) catch |err| switch (err) {
            error.Canceled => error.Canceled,
            else => {
                if (client.diagnostics) |d| d.print("the file's length could not be read: {t}", .{err});
                return error.ReadFailed;
            },
        },
    };
}

/// One ordinary upload, for an emulator, which has no multipart uploads.
fn fallback(
    client: *Client,
    bucket: []const u8,
    object: []const u8,
    source: types.ParallelSource,
    size: u64,
    options: types.ParallelUploadOptions,
) Error!types.Owned(types.ObjectInfo) {
    logging.debug("{s}: an emulator has no multipart uploads; sending one ordinary upload", .{object});
    const target: Object = .{ .client = client, .bucket = bucket, .name = object };
    const upload_options: types.UploadOptions = .{
        .content_type = options.content_type,
        .cache_control = options.cache_control,
        .content_disposition = options.content_disposition,
        .content_encoding = options.content_encoding,
        .content_language = options.content_language,
        .metadata = options.metadata,
        .crc32c = options.crc32c,
        .size = size,
    };
    switch (source) {
        .data => |data| return target.upload(data, upload_options),
        .file => |file| {
            const buffer = try client.gpa.alloc(u8, file_buffer_len);
            defer client.gpa.free(buffer);
            var reader = file.reader(client.io, buffer);
            return target.uploadFrom(&reader.interface, upload_options);
        },
    }
}

fn multipart(
    client: *Client,
    bucket: []const u8,
    object: []const u8,
    source: types.ParallelSource,
    size: u64,
    options: types.ParallelUploadOptions,
) Error!types.Owned(types.ObjectInfo) {
    var arena_state: std.heap.ArenaAllocator = .init(client.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const plan = mp.plan(size, options.part_size);
    const upload_id = try mp.start(client, arena, bucket, object, .{
        .content_type = options.content_type,
        .cache_control = options.cache_control,
        .content_disposition = options.content_disposition,
        .content_encoding = options.content_encoding,
        .content_language = options.content_language,
        .metadata = options.metadata,
    });
    logging.debug("multipart upload of {s}: {d} bytes in {d} parts of {d}", .{ object, size, plan.parts, plan.part_size });

    const slots = try arena.alloc(Slot, plan.parts);
    for (slots) |*slot| slot.* = .{};
    var run: Run = .{
        .client = client,
        .bucket = bucket,
        .object = object,
        .upload_id = upload_id,
        .source = source,
        .plan = plan,
        .options = options,
        .slots = slots,
    };
    run.sendParts() catch |err| return run.giveUp(err);

    // Every part is in. The parts' checksums fold into the whole's.
    const verify = client.verify_checksums;
    const parts = arena.alloc(xml.CompletedPart, plan.parts) catch |err| return run.giveUp(err);
    var whole: u32 = 0;
    for (slots, parts, 0..) |*slot, *part, i| {
        part.* = .{ .number = @intCast(i + 1), .etag = slot.etag() };
        if (verify) whole = core.crc32c.combine(whole, slot.crc32c, plan.len(@intCast(i)));
    }
    if (verify) if (options.crc32c) |wanted| if (wanted != whole) {
        const err = run.giveUp(error.ChecksumMismatch);
        if (client.diagnostics) |d| d.print(
            "checksum mismatch before the finish: the parts hash to {d}, options.crc32c says {d}; the upload was aborted and nothing was written",
            .{ whole, wanted },
        );
        return err;
    };

    const finished = mp.finish(client, bucket, object, upload_id, parts, options.finish_timeout_ms) catch |err| {
        // A repeated finish after one that landed finds no upload.
        if (mp.uploadIsGone(client, err)) return landedEarlier(client, bucket, object, size, if (verify) whole else null);
        return run.giveUp(err);
    };
    if (verify) if (finished.crc32c) |stored| if (stored != whole) {
        return deleteMismatch(client, bucket, object, size, finished, whole);
    };
    return readBack(client, bucket, object, finished.generation, size, if (verify) whole else null);
}

/// What one part left behind for the finish.
const Slot = struct {
    etag_buffer: [max_etag_len]u8 = undefined,
    etag_len: u8 = 0,
    /// Of the bytes sent; 0 when checksums are off.
    crc32c: u32 = 0,

    fn etag(slot: *const Slot) []const u8 {
        return slot.etag_buffer[0..slot.etag_len];
    }
};

/// One upload in flight: what every worker shares.
const Run = struct {
    client: *Client,
    bucket: []const u8,
    object: []const u8,
    upload_id: []const u8,
    source: types.ParallelSource,
    plan: mp.Plan,
    options: types.ParallelUploadOptions,
    slots: []Slot,
    mutex: std.Io.Mutex = .init,
    /// The next part to send, from 0.
    next: u32 = 0,
    /// The first failure, with the details of the worker that met it.
    failure: ?Failure = null,

    const Failure = struct {
        err: Error,
        diag: Diagnostics,
    };

    /// Sends every part: `concurrency` workers, each with a client of its
    /// own, on tasks of their own, or one on this task when the `std.Io`
    /// cannot run tasks concurrently.
    fn sendParts(run: *Run) Error!void {
        const gpa = run.client.gpa;
        const io = run.client.io;
        const count: usize = @min(run.options.concurrency, run.plan.parts);
        const workers = try gpa.alloc(Worker, count);
        defer gpa.free(workers);
        var made: usize = 0;
        defer for (workers[0..made]) |*w| w.deinit(gpa);
        for (workers) |*w| {
            try w.init(run);
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

    /// The next part to send, or null once there is none or one failed.
    fn take(run: *Run) ?u32 {
        const io = run.client.io;
        run.mutex.lockUncancelable(io);
        defer run.mutex.unlock(io);
        if (run.failure != null or run.next == run.plan.parts) return null;
        defer run.next += 1;
        return run.next;
    }

    /// Records the first failure; the other workers stop after the part
    /// they are sending.
    fn fail(run: *Run, err: Error, diag: *const Diagnostics) void {
        const io = run.client.io;
        run.mutex.lockUncancelable(io);
        defer run.mutex.unlock(io);
        if (run.failure == null) run.failure = .{ .err = err, .diag = diag.* };
    }

    /// Aborts the upload, keeping the diagnostics of the failure that
    /// caused it, and returns that failure. A cancel was delivered once
    /// already, so the abort runs protected from another and is bounded by
    /// the client's request timeout.
    fn giveUp(run: *Run, err: Error) Error {
        const client = run.client;
        const saved: ?Diagnostics = if (client.diagnostics) |d| d.* else null;
        const protection = client.io.swapCancelProtection(.blocked);
        defer _ = client.io.swapCancelProtection(protection);
        mp.abort(client, run.bucket, run.object, run.upload_id) catch |abort_err| {
            logging.warn("aborting the multipart upload of {s} failed with {t}: abort upload id {s} by hand, or let a lifecycle rule", .{
                run.object, abort_err, run.upload_id,
            });
        };
        if (client.diagnostics) |d| d.* = saved.?;
        return err;
    }
};

/// One of the tasks sending parts, with a client and a connection of its
/// own.
const Worker = struct {
    client: Client,
    diag: Diagnostics,
    /// Holds each part's answer, reset between parts.
    arena: std.heap.ArenaAllocator,
    /// For a file source: what a part is read, limited and hashed through.
    buffers: ?[]u8,

    fn init(w: *Worker, run: *Run) Error!void {
        const gpa = run.client.gpa;
        w.diag = .{};
        w.client = try run.client.sibling(&w.diag);
        errdefer w.client.deinit();
        w.client.request_timeout_ms = run.options.part_timeout_ms;
        w.arena = .init(gpa);
        w.buffers = if (run.source == .file) try gpa.alloc(u8, 3 * file_buffer_len) else null;
    }

    fn deinit(w: *Worker, gpa: Allocator) void {
        if (w.buffers) |b| gpa.free(b);
        w.arena.deinit();
        w.client.deinit();
    }

    /// Sends parts until there are none left or one has failed. Returns
    /// only `Canceled`: every other failure goes to the run, never lost.
    fn main(w: *Worker, run: *Run) error{Canceled}!void {
        while (run.take()) |index| {
            w.send(run, index) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => {
                    run.fail(err, &w.diag);
                    return;
                },
            };
        }
    }

    fn send(w: *Worker, run: *Run, index: u32) Error!void {
        _ = w.arena.reset(.retain_capacity);
        const verify = run.client.verify_checksums;
        const number = index + 1;
        const offset = run.plan.offset(index);
        const len = run.plan.len(index);
        switch (run.source) {
            .data => |data| {
                const bytes = data[@intCast(offset)..][0..@intCast(len)];
                const crc: u32 = if (verify) core.crc32c.hash(bytes) else 0;
                // In memory, so the engine retries it from the same bytes.
                const sent = mp.sendPart(&w.client, w.arena.allocator(), run.bucket, run.object, run.upload_id, number, .{ .bytes = bytes }) catch |err|
                    return w.partFailed(err, number);
                try w.keep(run, index, sent, crc, len, verify);
            },
            .file => |file| {
                const buffers = w.buffers.?;
                var attempt: u32 = 1;
                while (true) : (attempt += 1) {
                    // Read from the part's offset, never past its end,
                    // hashed as the bytes go: what is hashed is what is
                    // sent, and a failed attempt reads the part again.
                    var file_reader = file.reader(run.client.io, buffers[0..file_buffer_len]);
                    file_reader.seekTo(offset) catch |err| switch (err) {
                        error.Canceled => return error.Canceled,
                        else => {
                            w.diag.print("part {d}: the file cannot be read from byte {d}: {t}", .{ number, offset, err });
                            return error.ReadFailed;
                        },
                    };
                    var limited = file_reader.interface.limited(.limited(@intCast(len)), buffers[file_buffer_len..][0..file_buffer_len]);
                    var hashed = limited.interface.hashed(core.crc32c.Hasher.init(), buffers[2 * file_buffer_len ..][0..file_buffer_len]);
                    const sent = mp.sendPart(&w.client, w.arena.allocator(), run.bucket, run.object, run.upload_id, number, .{
                        .stream = .{ .reader = &hashed.reader, .len = len },
                    }) catch |err| {
                        const again = err != error.Canceled and err != error.ReadFailed and
                            core.isRetryable(err) and attempt < w.client.retry.max_attempts and
                            !mp.uploadIsGone(&w.client, err);
                        if (!again) return w.partFailed(err, number);
                        const delay_ms = rpc.backoffMs(&w.client, attempt);
                        logging.warn("part {d} of {s} failed with {t}; sending it again in {d} ms", .{ number, run.object, err, delay_ms });
                        try run.client.io.sleep(.fromMilliseconds(delay_ms), .awake);
                        continue;
                    };
                    try w.keep(run, index, sent, hashed.hasher.final(), len, verify);
                    return;
                }
            },
        }
    }

    /// Holds the part to the checksum Cloud Storage stored for it, and
    /// keeps what the finish needs.
    fn keep(w: *Worker, run: *Run, index: u32, sent: mp.SentPart, crc: u32, len: u64, verify: bool) Error!void {
        if (sent.etag.len > max_etag_len) {
            w.diag.print("part {d}: an ETag of {d} bytes, longer than any Cloud Storage sends", .{ index + 1, sent.etag.len });
            return error.InvalidResponse;
        }
        if (verify) if (sent.crc32c) |stored| if (stored != crc) {
            w.diag.print("checksum mismatch on part {d}: its {d} bytes hash to {d}, Cloud Storage stored {d}", .{ index + 1, len, crc, stored });
            return error.ChecksumMismatch;
        };
        const slot = &run.slots[index];
        @memcpy(slot.etag_buffer[0..sent.etag.len], sent.etag);
        slot.etag_len = @intCast(sent.etag.len);
        slot.crc32c = crc;
    }

    fn partFailed(w: *Worker, err: Error, number: u32) Error {
        if (mp.uploadIsGone(&w.client, err)) {
            w.diag.print("part {d}: the upload is gone, perhaps aborted by a lifecycle rule", .{number});
            return error.UploadSessionLost;
        }
        return err;
    }
};

/// The finish found no upload. A finish that landed and lost its answer
/// leaves exactly that behind, so the object decides: if it holds these
/// bytes, the upload succeeded.
fn landedEarlier(
    client: *Client,
    bucket: []const u8,
    object: []const u8,
    size: u64,
    whole: ?u32,
) Error!types.Owned(types.ObjectInfo) {
    return readBack(client, bucket, object, null, size, whole) catch |err| switch (err) {
        error.NotFound => {
            if (client.diagnostics) |d| d.print("the upload was gone at the finish, and no object holds its bytes: it was aborted, perhaps by a lifecycle rule, or replaced", .{});
            return error.UploadSessionLost;
        },
        else => |e| return e,
    };
}

/// The object as it now stands: pinned to `generation` when the finish
/// named one, and in any case held to the size and checksum sent, so the
/// answer never describes another writer's object.
fn readBack(
    client: *Client,
    bucket: []const u8,
    object: []const u8,
    generation: ?u64,
    size: u64,
    crc: ?u32,
) Error!types.Owned(types.ObjectInfo) {
    var scratch: std.heap.ArenaAllocator = .init(client.gpa);
    defer scratch.deinit();
    const path = try names.objectPath(scratch.allocator(), bucket, object, generation, .{});
    var result: types.Owned(types.ObjectInfo) = try .init(client.gpa);
    errdefer result.deinit();
    const body = rpc.execute(client, result.arena, .{ .method = .GET, .path = path }) catch |err| {
        if (err == error.NotFound and generation != null) {
            if (client.diagnostics) |d| d.print("the object was written, and replaced before its metadata could be read back", .{});
        }
        return err;
    };
    result.value = codec.decodeObject(result.arena.allocator(), body) catch |err|
        return rpc.decodeFailed(client, err, "object");
    const same = result.value.size == size and (crc == null or result.value.crc32c == crc.?);
    if (!same) {
        if (client.diagnostics) |d| d.print("another object replaced this one before its metadata could be read back", .{});
        return error.NotFound;
    }
    return result;
}

/// The finished object holds other bytes than were sent. It is deleted
/// again, pinned to its generation, so nobody's newer object can go.
fn deleteMismatch(
    client: *Client,
    bucket: []const u8,
    object: []const u8,
    size: u64,
    finished: mp.Finished,
    whole: u32,
) Error {
    const stored = finished.crc32c.?;
    const generation = finished.generation orelse g: {
        var found = readBack(client, bucket, object, null, size, stored) catch break :g null;
        defer found.deinit();
        break :g found.value.generation;
    };
    var deleted = false;
    if (generation) |g| {
        var scratch: std.heap.ArenaAllocator = .init(client.gpa);
        defer scratch.deinit();
        if (names.objectPath(scratch.allocator(), bucket, object, g, .{})) |path| {
            rpc.executeDiscard(client, .{ .method = .DELETE, .path = path }) catch |err| {
                logging.warn("deleting the mismatched upload of {s} failed with {t}", .{ object, err });
            };
            deleted = true;
        } else |_| {}
    }
    if (client.diagnostics) |d| d.print(
        "checksum mismatch after the finish: the parts hash to {d}, the object stores {d}; the object {s}",
        .{ whole, stored, if (deleted) "was deleted again" else "could not be pinned to a generation, and was left alone" },
    );
    return error.ChecksumMismatch;
}

const testing = std.testing;
const test_util = @import("test_util.zig");
const FakeMultipart = test_util.FakeMultipart;

/// Fault rules for the fake: the first `times` requests of `kind` (and
/// `part`, when set) meet `fault`. Decided under the fake's lock.
const Script = struct {
    rules: []Rule,

    const Rule = struct {
        kind: FakeMultipart.Kind,
        part: u32 = 0,
        times: u32 = 1,
        fault: FakeMultipart.Fault,
    };

    fn plan(self: *Script) FakeMultipart.FaultPlan {
        return .{ .ctx = self, .decide = decide };
    }

    fn decide(ctx: ?*anyopaque, kind: FakeMultipart.Kind, part: u32) FakeMultipart.Fault {
        const self: *Script = @ptrCast(@alignCast(ctx.?));
        for (self.rules) |*rule| {
            if (rule.kind == kind and (rule.part == 0 or rule.part == part) and rule.times > 0) {
                rule.times -= 1;
                return rule.fault;
            }
        }
        return .none;
    }
};

/// A client on the fake, with the part floor lowered to 1 KiB.
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
        s.fake.min_part_size = 1024;
        s.token = .{ .token = "ya29.parallel-test" };
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

fn fill(buf: []u8, seed: u64) void {
    var prng: std.Random.DefaultPrng = .init(seed);
    prng.random().bytes(buf);
}

test "uploadParallel: the parts in order, checked, joined, and read back" {
    var s: Setup = undefined;
    try s.init(testing.io, .{});
    defer s.deinit();
    var data: [100 * 1024 + 7]u8 = undefined;
    fill(&data, 1);
    var info = try s.object("dir/a b.bin").uploadParallel(.{ .data = &data }, .{
        .content_type = "application/x-test",
        .cache_control = "no-cache",
        .metadata = &.{ .{ .key = "origin", .value = "zig" }, .{ .key = "run", .value = "7" } },
        .crc32c = core.crc32c.hash(&data),
        .part_size = 16 * 1024,
        .concurrency = 4,
    });
    defer info.deinit();
    try testing.expectEqual(data.len, info.value.size);
    try testing.expectEqual(core.crc32c.hash(&data), info.value.crc32c.?);
    try testing.expectEqualStrings("dir/a b.bin", info.value.name);

    const stored = s.fake.object("dir/a b.bin").?;
    try testing.expectEqualSlices(u8, &data, stored.bytes);
    try testing.expectEqualStrings("application/x-test", stored.content_type);
    try testing.expectEqual(2, stored.metadata.len);
    try testing.expectEqualStrings("origin", stored.metadata[0].name);
    try testing.expectEqualStrings("zig", stored.metadata[0].value);
    // Seven parts, one start, one finish, one read back, nothing left open.
    try testing.expectEqual(7, s.fake.counts.parts);
    try testing.expectEqual(1, s.fake.counts.starts);
    try testing.expectEqual(1, s.fake.counts.finishes);
    try testing.expectEqual(1, s.fake.counts.reads);
    try testing.expectEqual(0, s.fake.openUploads());
}

test "uploadParallel: a file, every part read at its own offset" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var data: [70 * 1024 + 1]u8 = undefined;
    fill(&data, 2);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "source.bin", .data = &data });
    const file = try tmp.dir.openFile(testing.io, "source.bin", .{});
    defer file.close(testing.io);

    var s: Setup = undefined;
    try s.init(testing.io, .{});
    defer s.deinit();
    var info = try s.object("from-file.bin").uploadParallel(.{ .file = file }, .{
        .part_size = 16 * 1024,
        .concurrency = 3,
    });
    defer info.deinit();
    try testing.expectEqual(data.len, info.value.size);
    try testing.expectEqualSlices(u8, &data, s.fake.object("from-file.bin").?.bytes);
    try testing.expectEqual(5, s.fake.counts.parts);
}

test "uploadParallel: one worker on the caller's task when the Io cannot run more" {
    // FakeClock's Io has no concurrency: the same upload goes part by part.
    var clock: test_util.FakeClock = .{};
    var s: Setup = undefined;
    try s.init(clock.io(), .{});
    defer s.deinit();
    var data: [10 * 1024]u8 = undefined;
    fill(&data, 3);
    var info = try s.object("o").uploadParallel(.{ .data = &data }, .{ .part_size = 4096, .concurrency = 8 });
    defer info.deinit();
    try testing.expectEqualSlices(u8, &data, s.fake.object("o").?.bytes);
    try testing.expectEqual(3, s.fake.counts.parts);
}

test "uploadParallel: an empty object is one empty part" {
    var s: Setup = undefined;
    try s.init(testing.io, .{});
    defer s.deinit();
    var info = try s.object("empty").uploadParallel(.{ .data = "" }, .{ .part_size = 4096 });
    defer info.deinit();
    try testing.expectEqual(0, info.value.size);
    try testing.expectEqual(1, s.fake.counts.parts);
    try testing.expectEqual(0, s.fake.object("empty").?.bytes.len);
}

test "uploadParallel: transient failures are sent again, never written twice" {
    var rules = [_]Script.Rule{
        .{ .kind = .start, .fault = .unavailable },
        .{ .kind = .part, .part = 2, .fault = .lose_answer },
        .{ .kind = .part, .part = 3, .fault = .reset },
        .{ .kind = .part, .part = 4, .fault = .unavailable, .times = 2 },
    };
    var script: Script = .{ .rules = &rules };
    for ([_]bool{ false, true }) |from_file| {
        var s: Setup = undefined;
        try s.init(testing.io, .{});
        defer s.deinit();
        for (&rules) |*rule| rule.times = if (rule.part == 4) 2 else 1;
        s.fake.faults = script.plan();
        var data: [40 * 1024]u8 = undefined;
        fill(&data, 4);

        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "f", .data = &data });
        const file = try tmp.dir.openFile(testing.io, "f", .{});
        defer file.close(testing.io);
        const source: types.ParallelSource = if (from_file) .{ .file = file } else .{ .data = &data };

        var info = try s.object("o").uploadParallel(source, .{ .part_size = 8 * 1024, .concurrency = 3 });
        defer info.deinit();
        try testing.expectEqualSlices(u8, &data, s.fake.object("o").?.bytes);
        // Five parts stored, and the one whose answer was lost stored
        // again, replacing itself. The 503s and the reset never reached
        // the store, the start's 503 included.
        try testing.expectEqual(5 + 1, s.fake.counts.parts);
        try testing.expectEqual(1, s.fake.counts.starts);
        try testing.expectEqual(0, s.fake.openUploads());
    }
}

test "uploadParallel: a finish whose answer was lost is found by reading back" {
    var rules = [_]Script.Rule{.{ .kind = .finish, .fault = .lose_answer }};
    var script: Script = .{ .rules = &rules };
    var s: Setup = undefined;
    try s.init(testing.io, .{});
    defer s.deinit();
    s.fake.faults = script.plan();
    var data: [9000]u8 = undefined;
    fill(&data, 5);
    var info = try s.object("o").uploadParallel(.{ .data = &data }, .{ .part_size = 4096 });
    defer info.deinit();
    // The repeat found no upload; the object held these bytes.
    try testing.expectEqual(2, s.fake.counts.finishes);
    try testing.expectEqual(core.crc32c.hash(&data), info.value.crc32c.?);
    try testing.expectEqual(0, s.fake.counts.aborts);
}

/// Every failure after the start aborts, keeps the failure's own details,
/// and leaves no object and no open upload behind.
fn expectAbortedFailure(rule: Script.Rule, expected: Error, diag_says: []const u8) !void {
    var rules = [_]Script.Rule{rule};
    var script: Script = .{ .rules = &rules };
    var s: Setup = undefined;
    try s.init(testing.io, .{ .max_attempts = 2 });
    defer s.deinit();
    s.fake.faults = script.plan();
    var data: [20 * 1024]u8 = undefined;
    fill(&data, 6);
    try testing.expectError(expected, s.object("o").uploadParallel(.{ .data = &data }, .{ .part_size = 4096, .concurrency = 2 }));
    errdefer std.debug.print("diagnostics: {s}\n", .{s.diag.message()});
    try testing.expect(std.mem.indexOf(u8, s.diag.message(), diag_says) != null);
    try testing.expectEqual(null, s.fake.object("o"));
    try testing.expectEqual(0, s.fake.openUploads());
}

test "uploadParallel: every failure aborts, and says what failed" {
    try expectAbortedFailure(.{ .kind = .part, .part = 3, .fault = .corrupt }, error.ChecksumMismatch, "part 3");
    try expectAbortedFailure(.{ .kind = .part, .part = 2, .fault = .unavailable, .times = 99 }, error.Unavailable, "try again");
    try expectAbortedFailure(.{ .kind = .part, .part = 4, .fault = .gone }, error.UploadSessionLost, "gone");
    try expectAbortedFailure(.{ .kind = .finish, .fault = .error_200 }, error.Internal, "internal error");
}

test "uploadParallel: a checksum the caller knows is held to the parts before anything is joined" {
    var s: Setup = undefined;
    try s.init(testing.io, .{});
    defer s.deinit();
    var data: [12 * 1024]u8 = undefined;
    fill(&data, 7);
    try testing.expectError(error.ChecksumMismatch, s.object("o").uploadParallel(.{ .data = &data }, .{
        .part_size = 4096,
        .crc32c = core.crc32c.hash(&data) ^ 1,
    }));
    try testing.expect(std.mem.indexOf(u8, s.diag.message(), "nothing was written") != null);
    try testing.expectEqual(0, s.fake.counts.finishes);
    try testing.expectEqual(1, s.fake.counts.aborts);
    try testing.expectEqual(0, s.fake.openUploads());
}

test "uploadParallel: a finished object with other bytes is deleted again" {
    var rules = [_]Script.Rule{.{ .kind = .finish, .fault = .corrupt }};
    var script: Script = .{ .rules = &rules };
    var s: Setup = undefined;
    try s.init(testing.io, .{});
    defer s.deinit();
    s.fake.faults = script.plan();
    var data: [9000]u8 = undefined;
    fill(&data, 8);
    try testing.expectError(error.ChecksumMismatch, s.object("o").uploadParallel(.{ .data = &data }, .{ .part_size = 4096 }));
    try testing.expect(std.mem.indexOf(u8, s.diag.message(), "deleted again") != null);
    try testing.expectEqual(null, s.fake.object("o"));
    try testing.expectEqual(1, s.fake.counts.deletes);
}

test "uploadParallel: with checksums off, nothing is hashed or compared" {
    var rules = [_]Script.Rule{.{ .kind = .part, .part = 1, .fault = .corrupt }};
    var script: Script = .{ .rules = &rules };
    var s: Setup = undefined;
    try s.init(testing.io, .{ .verify_checksums = false });
    defer s.deinit();
    s.fake.faults = script.plan();
    var data: [9000]u8 = undefined;
    fill(&data, 9);
    var info = try s.object("o").uploadParallel(.{ .data = &data }, .{ .part_size = 4096, .crc32c = 12345 });
    defer info.deinit();
    // What the fake stored, corruption and all: the caller turned checking off.
    try testing.expect(!std.mem.eql(u8, &data, s.fake.object("o").?.bytes));
}

test "uploadParallel: a cancel stops the workers, aborts, and returns Canceled" {
    var rules = [_]Script.Rule{.{ .kind = .part, .part = 2, .fault = .wait }};
    var script: Script = .{ .rules = &rules };
    var s: Setup = undefined;
    try s.init(testing.io, .{});
    defer s.deinit();
    s.fake.faults = script.plan();
    var data: [20 * 1024]u8 = undefined;
    fill(&data, 10);

    const Running = struct {
        fn go(target: Object, bytes: []const u8) Error!void {
            var info = try target.uploadParallel(.{ .data = bytes }, .{ .part_size = 4096, .concurrency = 2 });
            info.deinit();
        }
    };
    var task = try testing.io.concurrent(Running.go, .{ s.object("o"), &data });
    // Part 2 waits at the gate, uncounted until it is stored; wait until
    // the other four are in, so the cancel lands on a worker mid-request.
    const deadline = std.Io.Clock.awake.now(testing.io).addDuration(.fromSeconds(10));
    while (true) {
        s.fake.mutex.lockUncancelable(testing.io);
        const parts = s.fake.counts.parts;
        s.fake.mutex.unlock(testing.io);
        if (parts >= 4) break;
        if (std.Io.Clock.awake.now(testing.io).nanoseconds > deadline.nanoseconds) @panic("the upload never stored the four parts not held back");
        try testing.io.sleep(.fromMilliseconds(1), .awake);
    }
    try testing.expectError(error.Canceled, task.cancel(testing.io));
    try testing.expectEqual(1, s.fake.counts.aborts);
    try testing.expectEqual(0, s.fake.openUploads());
    try testing.expectEqual(null, s.fake.object("o"));
}

test "check: what a parallel upload refuses, before anything is sent" {
    var s: Setup = undefined;
    try s.init(testing.io, .{});
    defer s.deinit();
    s.client.multipart_test = .{};
    const refused = [_]struct { name: []const u8 = "o", options: types.ParallelUploadOptions, says: []const u8 }{
        .{ .options = .{ .part_size = 5 * 1024 * 1024 - 1 }, .says = "part_size" },
        .{ .options = .{ .part_size = 5 * 1024 * 1024 * 1024 + 1 }, .says = "part_size" },
        .{ .options = .{ .concurrency = 0 }, .says = "concurrency" },
        .{ .options = .{ .concurrency = 65 }, .says = "concurrency" },
        .{ .options = .{ .content_type = "" }, .says = "content_type" },
        .{ .options = .{ .content_type = "text/plain\r\nx-evil: 1" }, .says = "content_type" },
        .{ .options = .{ .cache_control = " no-cache" }, .says = "cache_control" },
        .{ .options = .{ .content_language = "caf\xc3\xa9" }, .says = "content_language" },
        .{ .options = .{ .content_disposition = "" }, .says = "content_disposition" },
        .{ .options = .{ .metadata = &.{.{ .key = "Upper", .value = "v" }} }, .says = "lowercase" },
        .{ .options = .{ .metadata = &.{.{ .key = "has space", .value = "v" }} }, .says = "lowercase" },
        .{ .options = .{ .metadata = &.{.{ .key = "", .value = "v" }} }, .says = "lowercase" },
        .{ .options = .{ .metadata = &.{.{ .key = "k", .value = "caf\xc3\xa9" }} }, .says = "printable ASCII" },
        .{ .options = .{ .metadata = &.{.{ .key = "k", .value = "trailing " }} }, .says = "printable ASCII" },
        .{ .options = .{ .metadata = &.{ .{ .key = "k", .value = "1" }, .{ .key = "k", .value = "2" } } }, .says = "twice" },
        .{ .options = .{ .metadata = &.{.{ .key = "k", .value = "v" ** (8 * 1024) }} }, .says = "8192" },
        .{ .name = "a/../b", .options = .{}, .says = "segment" },
        .{ .name = "./x", .options = .{}, .says = "segment" },
    };
    for (refused) |case| {
        errdefer std.debug.print("expected refusal: {s}\n", .{case.says});
        try testing.expectError(error.InvalidParallelUploadOptions, s.object(case.name).uploadParallel(.{ .data = "x" }, case.options));
        try testing.expect(std.mem.indexOf(u8, s.diag.message(), case.says) != null);
    }
    try testing.expectEqual(0, s.fake.counts.starts);
    // The edges that are allowed.
    try check(&s.client, "o", .{ .part_size = 5 * 1024 * 1024 });
    try check(&s.client, "o", .{ .part_size = 5 * 1024 * 1024 * 1024, .concurrency = 64 });
    try check(&s.client, "o", .{ .metadata = &.{.{ .key = "a-b_c.d~1", .value = "" }} });
    try check(&s.client, "a/.b/..c", .{});
}

test "uploadParallel: an emulator gets one ordinary upload, every field kept" {
    var fake: test_util.FakeTransport = .init(testing.allocator, &.{
        .{ .respond = .{ .body = "{\"name\":\"o\",\"bucket\":\"b\",\"size\":\"5\",\"generation\":\"1\",\"crc32c\":\"mnG7TA==\"}" } },
    });
    defer fake.deinit();
    var client: Client = try .init(testing.allocator, testing.io, .{
        .endpoint = .{ .url = "http://127.0.0.1:4443", .emulator = true },
        .transport = fake.transport(),
    });
    defer client.deinit();
    var info = try client.bucket("b").object("o").uploadParallel(.{ .data = "hello" }, .{
        .content_type = "text/plain",
        .content_disposition = "attachment",
        .content_language = "en",
    });
    defer info.deinit();
    const sent = try fake.streamRequest(0);
    try testing.expect(std.mem.indexOf(u8, sent.url, "uploadType=multipart") != null);
    try testing.expect(std.mem.indexOf(u8, sent.body_prefix, "\"contentDisposition\":\"attachment\"") != null);
    try testing.expect(std.mem.indexOf(u8, sent.body_prefix, "\"contentLanguage\":\"en\"") != null);
    try testing.expectEqual(1, fake.stream_requests.items.len);
}

fn parallelEverything(gpa: Allocator) !void {
    var clock: test_util.FakeClock = .{};
    var fake: FakeMultipart = .init(gpa, clock.io());
    defer fake.deinit();
    fake.min_part_size = 1024;
    var token: core.StaticToken = .{ .token = "ya29.t" };
    var client: Client = try .init(gpa, clock.io(), .{
        .token_provider = token.provider(),
        .transport = fake.transport(),
    });
    defer client.deinit();
    client.multipart_test = .{ .min_part_size = 1024 };
    var data: [3000]u8 = undefined;
    fill(&data, 11);
    var info = try client.bucket("b").object("o").uploadParallel(.{ .data = &data }, .{
        .part_size = 1024,
        .metadata = &.{.{ .key = "k", .value = "v" }},
    });
    info.deinit();
}

test "uploadParallel: every allocation failure is OutOfMemory, and nothing leaks" {
    try testing.checkAllAllocationFailures(testing.allocator, parallelEverything, .{});
}

/// Draws each request's fate from fuzz bytes, under the fake's lock:
/// mostly nothing, sometimes a fault that kind of request can meet. The
/// cleanup requests, abort and delete, always go through; their failures
/// are tested on their own.
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
        if (kind == .abort or kind == .delete or self.pos >= self.bytes.len) return .none;
        const b = self.bytes[self.pos];
        self.pos += 1;
        const fault: FakeMultipart.Fault = switch (b) {
            0...199 => .none,
            200...214 => .unavailable,
            215...229 => .reset,
            230...239 => .lose_answer,
            240...245 => if (kind == .part or kind == .finish) .corrupt else .none,
            246...249 => if (kind == .part or kind == .finish) .gone else .none,
            else => if (kind == .finish) .error_200 else .none,
        };
        if (fault != .none) self.faulted = true;
        return fault;
    }
};

/// One upload under a drawn fault schedule, held to what must hold
/// whatever the faults: a run succeeds with the source's bytes stored, or
/// fails, and either way leaves no part behind to be billed; a run that met
/// no fault never fails; and with checksums on, no object ever holds other
/// bytes. An upload a lost start answer left behind may stay open: it holds
/// no part, and its id never reached the client.
fn runUnderFaults(io: std.Io, input: []const u8) !void {
    var g: test_util.ByteGen = .init(input);
    const size = g.intRange(usize, 0, 40 * 1024);
    const part_size = g.intRange(u64, 1024, 12 * 1024);
    const concurrency = g.intRange(u16, 1, 6);
    const verify = g.intRange(u8, 0, 7) != 0;
    const data = try testing.allocator.alloc(u8, size);
    defer testing.allocator.free(data);
    fill(data, g.int(u64));

    var s: Setup = undefined;
    try s.init(io, .{ .verify_checksums = verify });
    defer s.deinit();
    var chooser: Chooser = .{ .bytes = g.rest() };
    s.fake.faults = chooser.plan();

    const outcome = s.object("o").uploadParallel(.{ .data = data }, .{
        .part_size = part_size,
        .concurrency = concurrency,
    });
    // Every run ends with no part left in an open upload: finished, or
    // aborted.
    try testing.expectEqual(0, s.fake.openParts());
    if (outcome) |info_const| {
        var info = info_const;
        defer info.deinit();
        try testing.expectEqual(size, info.value.size);
        if (verify) {
            try testing.expectEqualSlices(u8, data, s.fake.object("o").?.bytes);
            try testing.expectEqual(core.crc32c.hash(data), info.value.crc32c.?);
        }
    } else |err| {
        errdefer std.debug.print("{t}: {s}\n", .{ err, s.diag.message() });
        // Only a fault fails a run.
        try testing.expect(chooser.faulted);
        // A finish can land before the read back fails, but never with
        // other bytes while checking is on.
        if (verify) if (s.fake.object("o")) |stored| try testing.expectEqualSlices(u8, data, stored.bytes);
    }
}

fn faultProperty(_: void, input: []const u8) !void {
    var clock: test_util.FakeClock = .{};
    try runUnderFaults(clock.io(), input);
}

// About 0.87 ms a run, far more than the other storage properties: named
// out of the nightly's "fuzz" and "slow property" filters, which would run
// it millions of times, until a job of its own is sized for it.
test "fault property parallel: every run under faults succeeds whole, or fails and cleans up" {
    try test_util.fuzzBytes({}, faultProperty, .{
        .random_runs = 300,
        .max_len = 256,
        .corpus = &.{
            "",
            // 40 KiB in 1 KiB parts, 6 at once, no faults.
            "\xff\xff\xff\xff\xff\xff\xff\xff\x00\x00\x00\x00\x00\x00\x00\x00\x00\x05\x01",
            // A lost finish answer, then a gone upload.
            "\x00\x00\x00\x00\x00\x00\x50\x00\x00\x00\x00\x00\x00\x00\x10\x00\x00\x02\x01\x00\x00\x00\x00\x00\x00\x00\x00\xe6\xf6",
        },
    });
}

test "uploadParallel: the same invariants on real threads, under a hundred fault schedules" {
    var prng: std.Random.DefaultPrng = .init(20260924);
    var input: [192]u8 = undefined;
    for (0..100) |_| {
        prng.random().bytes(&input);
        runUnderFaults(testing.io, &input) catch |err| {
            std.debug.print("input: {x}\n", .{&input});
            return err;
        };
    }
}

/// The fake behind a real HTTP server on the loopback interface, and a
/// client that reaches it through real connections: its built-in
/// transport, a new one per worker. Plain HTTP needs an emulator endpoint,
/// so the test field lets that endpoint take the multipart path.
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
        s.fake.min_part_size = 1024;
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
        s.client.multipart_test = .{ .min_part_size = 1024, .on_emulator = true };
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

fn tempFile(tmp: *testing.TmpDir, data: []const u8) !std.Io.File {
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "source.bin", .data = data });
    return tmp.dir.openFile(testing.io, "source.bin", .{});
}

test "uploadParallel over real sockets: a file, a connection per worker" {
    // The first four parts wait at the gate, each holding a worker and its
    // connection. Without that the count below would depend on how fast
    // the workers start: on a quick loopback one worker can take every
    // part before the others are running, as it did on macOS.
    var rules = [_]Script.Rule{
        .{ .kind = .part, .part = 1, .fault = .wait },
        .{ .kind = .part, .part = 2, .fault = .wait },
        .{ .kind = .part, .part = 3, .fault = .wait },
        .{ .kind = .part, .part = 4, .fault = .wait },
    };
    var script: Script = .{ .rules = &rules };
    var s: OverSockets = undefined;
    try s.init();
    defer s.deinit();
    s.fake.faults = script.plan();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data = try testing.allocator.alloc(u8, 200 * 1024 + 3);
    defer testing.allocator.free(data);
    fill(data, 12);
    const file = try tempFile(&tmp, data);
    defer file.close(testing.io);

    const Running = struct {
        fn go(target: Object, source: std.Io.File) Error!types.Owned(types.ObjectInfo) {
            return target.uploadParallel(.{ .file = source }, .{
                .part_size = 8 * 1024,
                .concurrency = 4,
                .metadata = &.{.{ .key = "origin", .value = "zig" }},
            });
        }
    };
    var task = try testing.io.concurrent(Running.go, .{ s.client.bucket("b").object("dir/over sockets.bin"), file });
    // Four workers held at the gate, each on a connection of its own, and
    // the caller's, which started the upload.
    const waiting = std.Io.Clock.awake.now(testing.io);
    while (s.server.connections.load(.monotonic) < 5) {
        if (waiting.durationTo(std.Io.Clock.awake.now(testing.io)).toMilliseconds() > 10_000) {
            @panic("four workers never held four connections of their own");
        }
        try testing.io.sleep(.fromMilliseconds(1), .awake);
    }
    s.fake.gate.set(testing.io);
    var info = try task.await(testing.io);
    defer info.deinit();
    try testing.expectEqualSlices(u8, data, s.fake.object("dir/over sockets.bin").?.bytes);
    try testing.expectEqual(26, s.fake.counts.parts);
    try testing.expectEqualStrings("zig", s.fake.object("dir/over sockets.bin").?.metadata[0].value);
}

test "uploadParallel over real sockets: dropped connections and a 503 are ridden out" {
    var rules = [_]Script.Rule{
        .{ .kind = .part, .part = 3, .fault = .lose_answer },
        .{ .kind = .part, .part = 5, .fault = .reset },
        .{ .kind = .finish, .fault = .unavailable },
    };
    var script: Script = .{ .rules = &rules };
    var s: OverSockets = undefined;
    try s.init();
    defer s.deinit();
    s.fake.faults = script.plan();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var data: [60 * 1024]u8 = undefined;
    fill(&data, 13);
    const file = try tempFile(&tmp, &data);
    defer file.close(testing.io);

    var info = try s.client.bucket("b").object("o").uploadParallel(.{ .file = file }, .{ .part_size = 8 * 1024, .concurrency = 3 });
    defer info.deinit();
    try testing.expectEqualSlices(u8, &data, s.fake.object("o").?.bytes);
    try testing.expectEqual(0, s.fake.openParts());
}

test "uploadParallel over real sockets: a stalled part times out and is sent again" {
    var rules = [_]Script.Rule{.{ .kind = .part, .part = 2, .fault = .stall }};
    var script: Script = .{ .rules = &rules };
    var s: OverSockets = undefined;
    try s.init();
    defer s.deinit();
    s.fake.faults = script.plan();
    s.fake.stall_ms = 1_500;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var data: [24 * 1024]u8 = undefined;
    fill(&data, 14);
    const file = try tempFile(&tmp, &data);
    defer file.close(testing.io);

    const started = std.Io.Clock.awake.now(testing.io);
    var info = try s.client.bucket("b").object("o").uploadParallel(.{ .file = file }, .{
        .part_size = 8 * 1024,
        .concurrency = 2,
        .part_timeout_ms = 200,
    });
    defer info.deinit();
    const elapsed_ms = started.durationTo(std.Io.Clock.awake.now(testing.io)).toMilliseconds();
    try testing.expectEqualSlices(u8, &data, s.fake.object("o").?.bytes);
    // The timeout fired well before the stall ended.
    try testing.expect(elapsed_ms < 1_500);
}

/// Section 7's rules for a parallel upload, stated again.
fn allowedByRules(name: []const u8, options: types.ParallelUploadOptions, floor: u64) bool {
    if (options.part_size < floor or options.part_size > 5 * 1024 * 1024 * 1024) return false;
    if (options.concurrency < 1 or options.concurrency > 64) return false;
    const fixed = [_]?[]const u8{ options.content_type, options.cache_control, options.content_disposition, options.content_encoding, options.content_language };
    for (fixed) |maybe| {
        const value = maybe orelse continue;
        if (!headerSafe(value) or value.len == 0) return false;
    }
    var total: usize = 0;
    for (options.metadata, 0..) |entry, i| {
        if (entry.key.len == 0) return false;
        for (entry.key) |c| {
            const ok = (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or std.mem.indexOfScalar(u8, "!#$%&'*+-.^_`|~", c) != null;
            if (!ok) return false;
        }
        if (!headerSafe(entry.value)) return false;
        for (options.metadata[0..i]) |earlier| if (std.mem.eql(u8, earlier.key, entry.key)) return false;
        total += "x-goog-meta-".len + entry.key.len + entry.value.len;
    }
    if (total > 8 * 1024) return false;
    var segments = std.mem.splitScalar(u8, name, '/');
    while (segments.next()) |segment| if (std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return false;
    return true;
}

/// Printable ASCII or tab, with no space or tab at either end.
fn headerSafe(value: []const u8) bool {
    for (value) |c| if (c != '\t' and (c < 0x20 or c > 0x7e)) return false;
    if (value.len == 0) return true;
    const edge = [_]u8{ value[0], value[value.len - 1] };
    for (edge) |c| if (c == ' ' or c == '\t') return false;
    return true;
}

fn checkProperty(_: void, input: []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var g: test_util.ByteGen = .init(input);
    const floor: u64 = g.pick(u64, &.{ 1024, 5 * 1024 * 1024 });
    var options: types.ParallelUploadOptions = .{
        .part_size = g.pick(u64, &.{ floor - 1, floor, 32 * 1024 * 1024, 5 * 1024 * 1024 * 1024, 5 * 1024 * 1024 * 1024 + 1 }),
        .concurrency = g.pick(u16, &.{ 0, 1, 8, 64, 65 }),
    };
    const pieces = [_][]const u8{ "", "a", "text/plain", " lead", "trail ", "caf\xc3\xa9", "tab\there", "cr\r\nlf", "UP", "k-1_2.3~", "\x7f" };
    const slots = [_]*?[]const u8{ &options.cache_control, &options.content_disposition, &options.content_encoding, &options.content_language };
    options.content_type = g.pick([]const u8, &pieces);
    for (slots) |slot| slot.* = if (g.boolean()) g.pick([]const u8, &pieces) else null;
    const entries = try arena.alloc(types.Metadata, g.intRange(usize, 0, 3));
    for (entries) |*entry| entry.* = .{
        .key = g.pick([]const u8, &pieces),
        .value = if (g.intRange(u8, 0, 9) == 0) try arena.alloc(u8, 8 * 1024) else g.pick([]const u8, &pieces),
    };
    for (entries) |entry| if (entry.value.len == 8 * 1024) @memset(@constCast(entry.value), 'v');
    options.metadata = entries;
    const name = g.pick([]const u8, &.{ "o", "a/b", "a/../b", "./x", "x/.", "..y", "a/.b" });

    var clock: test_util.FakeClock = .{};
    var fake: FakeMultipart = .init(testing.allocator, clock.io());
    defer fake.deinit();
    var token: core.StaticToken = .{ .token = "ya29.t" };
    var client: Client = try .init(testing.allocator, clock.io(), .{ .token_provider = token.provider(), .transport = fake.transport() });
    defer client.deinit();
    client.multipart_test = .{ .min_part_size = floor };

    const allowed = allowedByRules(name, options, floor);
    const result = check(&client, name, options);
    try testing.expectEqual(allowed, result != error.InvalidParallelUploadOptions);
}

test "fuzz parallel: check accepts exactly what the rules allow" {
    try test_util.fuzzBytes({}, checkProperty, .{ .corpus = &.{
        "",
        "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x02",
        "\x01\x00\x00\x00\x00\x00\x00\x00\x02\x00\x00\x00\x00\x00\x00\x00\x02",
    } });
}

test "uploadParallel: a finish found gone, with another writer's object in its place, is UploadSessionLost" {
    var rules = [_]Script.Rule{.{ .kind = .finish, .fault = .gone }};
    var script: Script = .{ .rules = &rules };
    var s: Setup = undefined;
    try s.init(testing.io, .{});
    defer s.deinit();
    try s.fake.put("o", "another writer's bytes");
    s.fake.faults = script.plan();
    var data: [9000]u8 = undefined;
    fill(&data, 15);
    try testing.expectError(error.UploadSessionLost, s.object("o").uploadParallel(.{ .data = &data }, .{ .part_size = 4096 }));
    try testing.expect(std.mem.indexOf(u8, s.diag.message(), "no object holds its bytes") != null);
    // Read, never touched.
    try testing.expectEqualStrings("another writer's bytes", s.fake.object("o").?.bytes);
    try testing.expectEqual(0, s.fake.counts.deletes);
}

test "Run: parts are handed out once each, and none after a failure; the first failure is kept" {
    var s: Setup = undefined;
    try s.init(testing.io, .{});
    defer s.deinit();
    var slots: [5]Slot = @splat(.{});
    var run: Run = .{
        .client = &s.client,
        .bucket = "b",
        .object = "o",
        .upload_id = "u",
        .source = .{ .data = "" },
        .plan = mp.plan(5 * 1024, 1024),
        .options = .{},
        .slots = &slots,
    };
    try testing.expectEqual(0, run.take().?);
    try testing.expectEqual(1, run.take().?);
    var first: Diagnostics = .{};
    first.print("part 2 failed", .{});
    run.fail(error.Unavailable, &first);
    try testing.expectEqual(null, run.take());
    var later: Diagnostics = .{};
    later.print("a later failure", .{});
    run.fail(error.Internal, &later);
    try testing.expectEqual(error.Unavailable, run.failure.?.err);
    try testing.expectEqualStrings("part 2 failed", run.failure.?.diag.message());

    // With no failure, every part once, then nothing.
    var clean: Run = run;
    clean.failure = null;
    clean.next = 0;
    for (0..5) |i| try testing.expectEqual(@as(u32, @intCast(i)), clean.take().?);
    try testing.expectEqual(null, clean.take());
}
