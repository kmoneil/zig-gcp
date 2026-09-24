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
//! No retry can write twice. Sending a part again replaces it. A finish
//! that landed before its answer was lost answers 200 again when repeated
//! soon after, naming the same generation, and 404 `NoSuchUpload` once
//! Cloud Storage has forgotten the upload, which reading the object back
//! resolves.
//!
//! The multipart upload takes no preconditions: a finish ignores them. So
//! an upload with conditions reads the object under them first, which
//! refuses a condition that already fails before a byte is sent; finishes
//! under a temporary name; and has `objects.move` rename it into place
//! only if the conditions still hold. The move is atomic, and pinned to
//! the temporary object's generation, so a retry never moves twice.
//!
//! Against an emulator the object goes up as one ordinary upload instead,
//! with the conditions applied to it: fake-gcs-server has no multipart
//! uploads, and no `objects.move`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("core");

const Client = @import("Client.zig");
const Object = @import("Object.zig");
const checkpoint = @import("checkpoint.zig");
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

/// Where an upload with conditions finishes before it moves into place:
/// one prefix a lifecycle rule can clean, apart from any name a caller
/// would choose.
pub const temp_prefix = "zig-gcp-tmp/";

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
    if (options.checkpoint != null and source != .file) {
        return refuse(client.diagnostics, "checkpoint: only a file source outlives a process, so memory takes none", .{});
    }
    const size = try sourceSize(client, source);
    if (size > mp.max_object_size) {
        if (client.diagnostics) |d| d.print("the source is {d} bytes, and an object holds at most 5 TiB", .{size});
        return error.InvalidParallelUploadOptions;
    }
    if (client.unauthenticated and !client.multipart_test.on_emulator) {
        if (options.checkpoint != null) {
            logging.warn("{s}: an emulator's one ordinary upload cannot resume, so the checkpoint is ignored", .{object});
        }
        return fallback(client, bucket, object, source, size, options);
    }
    if (options.checkpoint) |cp| {
        return persistent(client, bucket, object, source.file, size, options, cp);
    }
    if (std.meta.eql(options.preconditions, types.Preconditions{})) {
        return multipart(client, bucket, object, source, size, options, null);
    }
    return conditional(client, bucket, object, source, size, options, null);
}

/// Everything a checkpointed upload carries between its pieces.
const Persist = struct {
    cp: checkpoint.Checkpoint,
    bucket: []const u8,
    /// The name the object is to have, whatever name the parts go up
    /// under.
    object: []const u8,
    file: std.Io.File,
    size: u64,
    mtime: i128,
    preconditions: types.Preconditions,
    /// The temporary name the parts go up under, for an upload with
    /// conditions; set before `join`.
    temp: ?[]const u8 = null,
    /// The state an earlier process saved, until it is spent.
    resumed: ?checkpoint.State.UploadParallel,
};

/// With a checkpoint, which failures still abort the upload, drop the
/// temporary object and clear the state: those a resume could only
/// repeat. Everything else leaves the parts and the checkpoint for a
/// later process.
fn abandons(err: Error) bool {
    return switch (err) {
        error.ChecksumMismatch,
        error.InvalidResponse,
        error.ReadFailed,
        error.UnexpectedEndOfStream,
        error.StreamTooLong,
        error.FailedPrecondition,
        error.NotModified,
        error.UploadSessionLost,
        => true,
        else => false,
    };
}

fn persistent(
    client: *Client,
    bucket: []const u8,
    object: []const u8,
    file: std.Io.File,
    size: u64,
    options: types.ParallelUploadOptions,
    cp: checkpoint.Checkpoint,
) Error!types.Owned(types.ObjectInfo) {
    const result = resumeOrStart(client, bucket, object, file, size, options, cp);
    if (result) |_| {
        cp.clear();
    } else |err| if (abandons(err)) cp.clear();
    return result;
}

/// Picks the upload up where a checkpoint left it, or starts one and
/// records it. An upload that turns out to be gone either finished in the
/// dead process, which the object settles, or was aborted, and starts
/// over, bounded like a retry.
fn resumeOrStart(
    client: *Client,
    bucket: []const u8,
    object: []const u8,
    file: std.Io.File,
    size: u64,
    options: types.ParallelUploadOptions,
    cp: checkpoint.Checkpoint,
) Error!types.Owned(types.ObjectInfo) {
    var state_arena: std.heap.ArenaAllocator = .init(client.gpa);
    defer state_arena.deinit();
    var persist: Persist = .{
        .cp = cp,
        .bucket = bucket,
        .object = object,
        .file = file,
        .size = size,
        .mtime = try statMtime(client, file),
        .preconditions = options.preconditions,
        .resumed = try loadUploadState(client, cp, state_arena.allocator(), bucket, object),
    };
    if (persist.resumed) |s| {
        if (s.size != size or s.mtime != persist.mtime) {
            logging.warn("{s}: the source file changed under the checkpoint; abandoning the old upload and starting over", .{object});
            abandonResumed(client, bucket, s);
            persist.resumed = null;
        } else if (!sameConditions(s, options.preconditions)) {
            logging.warn("{s}: the conditions changed since the checkpoint; abandoning the old upload and starting over", .{object});
            abandonResumed(client, bucket, s);
            persist.resumed = null;
        }
    }
    const with_conditions = !std.meta.eql(options.preconditions, types.Preconditions{});
    var attempt: u32 = 0;
    while (true) : (attempt += 1) {
        const outcome = if (with_conditions)
            conditional(client, bucket, object, .{ .file = file }, size, options, &persist)
        else
            multipart(client, bucket, object, .{ .file = file }, size, options, &persist);
        if (outcome) |result| {
            return result;
        } else |err| {
            if (err != error.UploadSessionLost or attempt + 1 >= client.retry.max_attempts) return err;
            if (persist.resumed != null) {
                if (try finishedEarlier(client, &persist, options)) |result| return result;
            }
            logging.warn("{s}: the upload is gone; starting over", .{object});
            persist.resumed = null;
        }
    }
}

fn sameConditions(s: checkpoint.State.UploadParallel, preconditions: types.Preconditions) bool {
    return std.meta.eql(preconditions, types.Preconditions{
        .if_generation_match = s.if_generation_match,
        .if_generation_not_match = s.if_generation_not_match,
        .if_metageneration_match = s.if_metageneration_match,
        .if_metageneration_not_match = s.if_metageneration_not_match,
    });
}

/// What the checkpoint holds for this upload, or null when it holds
/// nothing yet. A state that cannot be read or parsed, or that belongs to
/// another transfer, is `error.CheckpointFailed` before anything is sent.
fn loadUploadState(
    client: *Client,
    cp: checkpoint.Checkpoint,
    arena: Allocator,
    bucket: []const u8,
    object: []const u8,
) Error!?checkpoint.State.UploadParallel {
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
        .upload_parallel => |s| s,
        else => {
            if (d) |diag| diag.print("the checkpoint belongs to another transfer, not a parallel upload; give each transfer a checkpoint of its own", .{});
            return error.CheckpointFailed;
        },
    };
    if (!std.mem.eql(u8, s.bucket, bucket) or !std.mem.eql(u8, s.object, object)) {
        if (d) |diag| diag.print("the checkpoint belongs to another transfer; overwriting it would orphan that one, so give each transfer a checkpoint of its own", .{});
        return error.CheckpointFailed;
    }
    return s;
}

/// Encodes and saves the upload's state, once, when the upload starts. A
/// store that cannot save fails the upload before any data moves.
fn saveUploadState(client: *Client, p: *const Persist, upload_id: []const u8, part_size: u64) Error!void {
    const state: checkpoint.State = .{ .upload_parallel = .{
        .bucket = p.bucket,
        .object = p.object,
        .size = p.size,
        .mtime = p.mtime,
        .upload_id = upload_id,
        .part_size = part_size,
        .temp = p.temp,
        .if_generation_match = p.preconditions.if_generation_match,
        .if_generation_not_match = p.preconditions.if_generation_not_match,
        .if_metageneration_match = p.preconditions.if_metageneration_match,
        .if_metageneration_not_match = p.preconditions.if_metageneration_not_match,
    } };
    const bytes = try checkpoint.encodeAlloc(client.gpa, state);
    defer client.gpa.free(bytes);
    p.cp.save(bytes) catch |err| switch (err) {
        error.CheckpointFailed => {
            if (client.diagnostics) |d| d.print("the checkpoint refused a save; the upload fails rather than carry on unresumable", .{});
            return error.CheckpointFailed;
        },
        else => |e| return e,
    };
}

fn statMtime(client: *Client, file: std.Io.File) Error!i128 {
    const stat = file.stat(client.io) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => {
            if (client.diagnostics) |d| d.print("the file's size and time could not be read: {t}", .{err});
            return error.ReadFailed;
        },
    };
    return stat.mtime.nanoseconds;
}

/// The CRC32C of `len` bytes of the file from `first`: how a resume
/// rebuilds what an earlier process sent, taking nothing about the data
/// from the checkpoint, so a file changed between runs is caught.
fn hashRange(client: *Client, file: std.Io.File, first: u64, len: u64) Error!u32 {
    const buf = try client.gpa.alloc(u8, file_buffer_len);
    defer client.gpa.free(buf);
    var hasher: core.crc32c.Hasher = .init();
    var offset = first;
    var remaining = len;
    while (remaining > 0) {
        const want: usize = @intCast(@min(remaining, buf.len));
        const got = file.readPositionalAll(client.io, buf[0..want], offset) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => {
                if (client.diagnostics) |d| d.print("the file could not be read back at byte {d} to resume: {t}", .{ offset, err });
                return error.ReadFailed;
            },
        };
        if (got < want) {
            if (client.diagnostics) |d| d.print("the file ends at byte {d}, before bytes the checkpoint says were sent", .{offset + got});
            return error.ReadFailed;
        }
        hasher.update(buf[0..got]);
        offset += got;
        remaining -= got;
    }
    return hasher.final();
}

/// Learns which parts the server holds, through ListParts, and re-reads
/// each from the file, so its checksum is rebuilt rather than trusted. A
/// part of another size than the plan's is left out, and sending it again
/// replaces it. Returns how many parts stand.
fn prefill(
    client: *Client,
    persist: *const Persist,
    bucket: []const u8,
    object: []const u8,
    upload_id: []const u8,
    plan: mp.Plan,
    slots: []Slot,
) Error!u32 {
    var arena_state: std.heap.ArenaAllocator = .init(client.gpa);
    defer arena_state.deinit();
    const listed = mp.listParts(client, arena_state.allocator(), bucket, object, upload_id, mp.list_page_size) catch |err| {
        if (mp.uploadIsGone(client, err)) return error.UploadSessionLost;
        return err;
    };
    var held: u32 = 0;
    for (listed) |part| {
        if (part.number < 1 or part.number > plan.parts) continue;
        const index: u32 = part.number - 1;
        if (part.size != plan.len(index)) continue;
        if (part.etag.len == 0 or part.etag.len > max_etag_len) continue;
        const slot = &slots[index];
        if (slot.etag_len != 0) continue;
        slot.crc32c = if (client.verify_checksums) try hashRange(client, persist.file, plan.offset(index), part.size) else 0;
        @memcpy(slot.etag_buffer[0..part.etag.len], part.etag);
        slot.etag_len = @intCast(part.etag.len);
        held += 1;
    }
    logging.debug("multipart upload of {s}: resuming; the server holds {d} of {d} parts", .{ persist.object, held, plan.parts });
    return held;
}

/// Drops an upload whose state could not be saved: unrecorded, it would
/// only linger and be billed. Best effort, protected from a cancel, and
/// the save failure's diagnostics stay.
fn abortUnrecorded(client: *Client, bucket: []const u8, object: []const u8, upload_id: []const u8) void {
    const saved: ?Diagnostics = if (client.diagnostics) |d| d.* else null;
    defer if (client.diagnostics) |d| {
        d.* = saved.?;
    };
    const protection = client.io.swapCancelProtection(.blocked);
    defer _ = client.io.swapCancelProtection(protection);
    mp.abort(client, bucket, object, upload_id) catch |err| {
        logging.warn("aborting the unrecorded multipart upload of {s} failed with {t}: abort upload id {s} by hand, or let a lifecycle rule", .{ object, err, upload_id });
    };
}

/// Drops what a checkpoint's upload left on the server, for a transfer
/// that cannot resume it: the upload and its parts, and the temporary
/// object where one got as far as existing. Best effort, protected from a
/// cancel.
fn abandonResumed(client: *Client, bucket: []const u8, s: checkpoint.State.UploadParallel) void {
    const saved: ?Diagnostics = if (client.diagnostics) |d| d.* else null;
    defer if (client.diagnostics) |d| {
        d.* = saved.?;
    };
    const protection = client.io.swapCancelProtection(.blocked);
    defer _ = client.io.swapCancelProtection(protection);
    mp.abort(client, bucket, s.temp orelse s.object, s.upload_id) catch |err| {
        logging.warn("aborting the old multipart upload of {s} failed with {t}: abort upload id {s} by hand, or let a lifecycle rule", .{ s.object, err, s.upload_id });
    };
    const temp = s.temp orelse return;
    const target: Object = .{ .client = client, .bucket = bucket, .name = temp };
    const generation: ?u64 = found: {
        var info = target.get(.{}) catch break :found null;
        defer info.deinit();
        break :found info.value.generation;
    };
    if (generation) |g| target.delete(.{ .generation = g }) catch |err| switch (err) {
        error.NotFound => {},
        else => logging.warn("deleting the old temporary object {s} failed with {t}: delete it by hand, or let a lifecycle rule", .{ temp, err }),
    };
}

/// The resumed upload is gone at the server. A finish that landed in the
/// dead process leaves the object, or the temporary object, holding
/// exactly the file's bytes, and the transfer carries on from there; null
/// means it was aborted instead, and starts over.
fn finishedEarlier(client: *Client, persist: *Persist, options: types.ParallelUploadOptions) Error!?types.Owned(types.ObjectInfo) {
    const s = persist.resumed.?;
    const whole: ?u32 = if (client.verify_checksums) try hashRange(client, persist.file, 0, persist.size) else null;
    if (s.temp) |temp| {
        found: {
            var read = readBack(client, persist.bucket, temp, null, persist.size, whole) catch |err| switch (err) {
                error.NotFound => break :found,
                else => |e| return e,
            };
            defer read.deinit();
            logging.debug("{s}: the dead process finished the temporary object; the move is still owed", .{persist.object});
            return try move(client, persist, persist.bucket, temp, persist.object, read.value.generation, persist.size, whole, options.preconditions);
        }
        // Or the move itself landed too.
        return readBack(client, persist.bucket, persist.object, null, persist.size, whole) catch |err| switch (err) {
            error.NotFound => null,
            else => |e| return e,
        };
    }
    return readBack(client, persist.bucket, persist.object, null, persist.size, whole) catch |err| switch (err) {
        error.NotFound => null,
        else => |e| return e,
    };
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
        .preconditions = options.preconditions,
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
    persist: ?*Persist,
) Error!types.Owned(types.ObjectInfo) {
    const joined = try join(client, bucket, object, source, size, options, persist);
    if (joined.read) |read| return read;
    return readBack(client, bucket, object, joined.generation, size, joined.whole);
}

/// What a finished multipart upload left.
const Joined = struct {
    /// The object's generation, when the finish's answer named one.
    generation: ?u64,
    /// The checksum of what was sent, when checking.
    whole: ?u32,
    /// The object read back, when a lost finish answer was resolved that
    /// way. The caller owns it.
    read: ?types.Owned(types.ObjectInfo) = null,
};

/// Sends every part and has Cloud Storage join them as `object`, checked
/// end to end. Every failure before the join aborts the upload.
fn join(
    client: *Client,
    bucket: []const u8,
    object: []const u8,
    source: types.ParallelSource,
    size: u64,
    options: types.ParallelUploadOptions,
    persist: ?*Persist,
) Error!Joined {
    var arena_state: std.heap.ArenaAllocator = .init(client.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // The parts already on the server fix a resumed plan, not the options.
    const resumed: ?checkpoint.State.UploadParallel = if (persist) |p| p.resumed else null;
    const plan = mp.plan(size, if (resumed) |s| s.part_size else options.part_size);
    const upload_id = if (resumed) |s| s.upload_id else blk: {
        const id = try mp.start(client, arena, bucket, object, .{
            .content_type = options.content_type,
            .cache_control = options.cache_control,
            .content_disposition = options.content_disposition,
            .content_encoding = options.content_encoding,
            .content_language = options.content_language,
            .metadata = options.metadata,
        });
        if (persist) |p| saveUploadState(client, p, id, plan.part_size) catch |err| {
            // An upload the checkpoint never recorded would only linger:
            // drop it again before any data moves.
            abortUnrecorded(client, bucket, object, id);
            return err;
        };
        break :blk id;
    };
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
        .persist = persist,
    };
    var held: u32 = 0;
    if (resumed != null) {
        held = prefill(client, persist.?, bucket, object, upload_id, plan, slots) catch |err| return run.giveUp(err);
    }
    if (held < plan.parts) run.sendParts() catch |err| return run.giveUp(err);

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

    const checked: ?u32 = if (verify) whole else null;
    const finished = mp.finish(client, bucket, object, upload_id, parts, options.finish_timeout_ms) catch |err| {
        // A repeated finish after one that landed finds no upload.
        if (mp.uploadIsGone(client, err)) {
            const read = try landedEarlier(client, bucket, object, size, checked);
            return .{ .generation = read.value.generation, .whole = checked, .read = read };
        }
        return run.giveUp(err);
    };
    if (verify) if (finished.crc32c) |stored| if (stored != whole) {
        return deleteMismatch(client, bucket, object, size, finished, whole);
    };
    return .{ .generation = finished.generation, .whole = checked };
}

/// An upload with conditions: checked before a byte is sent, finished
/// under a temporary name, and moved into place only if they still hold.
fn conditional(
    client: *Client,
    bucket: []const u8,
    object: []const u8,
    source: types.ParallelSource,
    size: u64,
    options: types.ParallelUploadOptions,
    persist: ?*Persist,
) Error!types.Owned(types.ObjectInfo) {
    checkEarly(client, bucket, object, options.preconditions) catch |err| {
        // A resumed upload whose conditions now fail can never move into
        // place: what it left on the server goes too.
        if (err == error.FailedPrecondition) if (persist) |p| if (p.resumed) |s| abandonResumed(client, bucket, s);
        return err;
    };
    var temp_buf: [temp_prefix.len + 32]u8 = undefined;
    const temp: []const u8 = if (persist) |p| t: {
        // The parts already sent live under the dead process's name.
        if (p.resumed) |s| break :t s.temp.?;
        break :t tempName(client.io, &temp_buf);
    } else tempName(client.io, &temp_buf);
    if (persist) |p| p.temp = temp;
    logging.debug("{s}: sent as {s}, to be moved into place under its conditions", .{ object, temp });
    var joined = join(client, bucket, temp, source, size, options, persist) catch |err| {
        // A finish can land before its answer is lost and every retry
        // fails, and then the temporary object is there after all.
        return dropTemp(client, persist, bucket, temp, null, err);
    };
    const generation = if (joined.read) |*read| g: {
        defer read.deinit();
        break :g read.value.generation;
    } else joined.generation orelse g: {
        var read = readBack(client, bucket, temp, null, size, joined.whole) catch |err|
            return dropTemp(client, persist, bucket, temp, null, err);
        defer read.deinit();
        break :g read.value.generation;
    };
    return move(client, persist, bucket, temp, object, generation, size, joined.whole, options.preconditions);
}

/// Reads the object under the caller's conditions before a byte is sent,
/// so an upload bound to be refused costs one request rather than the
/// whole transfer. Any other answer goes ahead: the move decides.
fn checkEarly(client: *Client, bucket: []const u8, object: []const u8, preconditions: types.Preconditions) Error!void {
    const target: Object = .{ .client = client, .bucket = bucket, .name = object };
    var info = target.get(.{ .preconditions = preconditions }) catch |err| switch (err) {
        // A 412, or the 304 a failing `…NotMatch` condition gets on a read.
        error.FailedPrecondition, error.NotModified => {
            if (client.diagnostics) |d| d.print("the object's conditions already fail, so nothing was sent", .{});
            return error.FailedPrecondition;
        },
        error.Canceled, error.OutOfMemory => |e| return e,
        else => {
            logging.debug("{s}: the early check answered {t}; the move decides", .{ object, err });
            if (client.diagnostics) |d| d.clear();
            return;
        },
    };
    info.deinit();
}

/// `zig-gcp-tmp/` and 32 random hex digits: a name nothing else writes.
fn tempName(io: std.Io, buf: *[temp_prefix.len + 32]u8) []const u8 {
    var random: [16]u8 = undefined;
    io.random(&random);
    return std.fmt.bufPrint(buf, temp_prefix ++ "{x}", .{&random}) catch unreachable;
}

/// Renames the temporary object into place under the caller's conditions,
/// pinned to its generation, and returns what the move made, held to the
/// size and checksum sent.
fn move(
    client: *Client,
    persist: ?*Persist,
    bucket: []const u8,
    temp: []const u8,
    object: []const u8,
    generation: u64,
    size: u64,
    whole: ?u32,
    preconditions: types.Preconditions,
) Error!types.Owned(types.ObjectInfo) {
    var scratch: std.heap.ArenaAllocator = .init(client.gpa);
    defer scratch.deinit();
    const path = names.movePath(scratch.allocator(), bucket, temp, object, generation, preconditions) catch |err|
        return dropTemp(client, persist, bucket, temp, generation, err);
    var result: types.Owned(types.ObjectInfo) = types.Owned(types.ObjectInfo).init(client.gpa) catch |err|
        return dropTemp(client, persist, bucket, temp, generation, err);
    const body = rpc.execute(client, result.arena, .{ .method = .POST, .path = path }) catch |err| {
        result.deinit();
        return settle(client, persist, bucket, temp, object, generation, size, whole, err);
    };
    errdefer result.deinit();
    result.value = codec.decodeObject(result.arena.allocator(), body) catch |err|
        return rpc.decodeFailed(client, err, "move");
    if (result.value.size != size or (whole != null and result.value.crc32c != whole.?)) {
        if (client.diagnostics) |d| d.print("the move answered an object of {d} bytes that is not the one sent", .{result.value.size});
        return error.InvalidResponse;
    }
    return result;
}

/// A move that failed with 404 or 412 may have met its own earlier attempt,
/// one that landed and lost its answer: the source gone, or the
/// destination's condition failing against the object the move itself
/// made. The temporary object says which. Every other failure deletes the
/// temporary object again.
fn settle(
    client: *Client,
    persist: ?*Persist,
    bucket: []const u8,
    temp: []const u8,
    object: []const u8,
    generation: u64,
    size: u64,
    whole: ?u32,
    err: Error,
) Error!types.Owned(types.ObjectInfo) {
    if (err != error.FailedPrecondition and err != error.NotFound) return dropTemp(client, persist, bucket, temp, generation, err);
    const saved: ?Diagnostics = if (client.diagnostics) |d| d.* else null;
    const still_there = tempIsThere(client, bucket, temp, generation) catch |read_err|
        return dropTemp(client, persist, bucket, temp, generation, read_err);
    if (still_there) {
        // The move never happened: the conditions failed.
        if (client.diagnostics) |d| {
            d.* = saved.?;
            if (err == error.FailedPrecondition) rpc.replace412(client, "the object's conditions failed at the move; the upload was undone, and nothing was written");
        }
        return dropTemp(client, persist, bucket, temp, generation, err);
    }
    // The move happened. The object at the name must hold these bytes.
    return readBack(client, bucket, object, null, size, whole) catch |read_err| switch (read_err) {
        error.NotFound => {
            if (client.diagnostics) |d| d.print("the temporary object is gone, and the object does not hold its bytes: it was replaced, or the temporary object was deleted", .{});
            return error.UploadSessionLost;
        },
        else => |e| return e,
    };
}

/// Whether the temporary object is still there at `generation`.
fn tempIsThere(client: *Client, bucket: []const u8, temp: []const u8, generation: u64) Error!bool {
    const target: Object = .{ .client = client, .bucket = bucket, .name = temp };
    var info = target.get(.{ .generation = generation }) catch |err| switch (err) {
        error.NotFound => return false,
        else => |e| return e,
    };
    info.deinit();
    return true;
}

/// Deletes the temporary object, when the upload got as far as making one,
/// and returns `err` with its own diagnostics. Pinned to `generation`, or
/// to whatever generation the name holds when that is unknown, since
/// nothing else writes there. With a checkpoint, a failure a resume could
/// get past deletes nothing: the temporary object stays for the move a
/// later process owes. A cancel was delivered once already, so this runs
/// protected from another.
fn dropTemp(client: *Client, persist: ?*const Persist, bucket: []const u8, temp: []const u8, generation: ?u64, err: Error) Error {
    // A gone upload is kept too: a finish that landed in a dead process
    // leaves exactly a temporary object and no upload, and the resume
    // still owes it the move.
    if (persist != null and (!abandons(err) or err == error.UploadSessionLost)) {
        logging.warn("the upload of {s} failed with {t} at its temporary object; whatever stands stays for a resume", .{ temp, err });
        return err;
    }
    const saved: ?Diagnostics = if (client.diagnostics) |d| d.* else null;
    defer if (client.diagnostics) |d| {
        d.* = saved.?;
    };
    const protection = client.io.swapCancelProtection(.blocked);
    defer _ = client.io.swapCancelProtection(protection);
    const target: Object = .{ .client = client, .bucket = bucket, .name = temp };
    const pinned = generation orelse found: {
        var info = target.get(.{}) catch break :found null;
        defer info.deinit();
        break :found info.value.generation;
    } orelse return err;
    target.delete(.{ .generation = pinned }) catch |delete_err| switch (delete_err) {
        error.NotFound => {},
        else => logging.warn("deleting the temporary object {s} failed with {t}: delete it by hand, or let a lifecycle rule", .{ temp, delete_err }),
    };
    return err;
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
    /// Null when the caller keeps no state between processes.
    persist: ?*Persist = null,
    mutex: std.Io.Mutex = .init,
    /// The next part to send, from 0.
    next: u32 = 0,
    /// The first failure, with the details of the worker that met it.
    failure: ?Failure = null,

    const Failure = struct {
        err: Error,
        diag: Diagnostics,
    };

    /// Sends every part not already on the server: `concurrency` workers,
    /// each with a client of its own, on tasks of their own, or one on
    /// this task when the `std.Io` cannot run tasks concurrently.
    fn sendParts(run: *Run) Error!void {
        const gpa = run.client.gpa;
        const io = run.client.io;
        var held: u32 = 0;
        for (run.slots) |slot| {
            if (slot.etag_len != 0) held += 1;
        }
        const count: usize = @min(run.options.concurrency, run.plan.parts - held);
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

    /// The next part to send, or null once there is none or one failed. A
    /// part the server already holds is never handed out: its bytes were
    /// re-read, not trusted, and sending it again would spend the transfer
    /// a resume is for.
    fn take(run: *Run) ?u32 {
        const io = run.client.io;
        run.mutex.lockUncancelable(io);
        defer run.mutex.unlock(io);
        if (run.failure != null) return null;
        while (run.next < run.plan.parts and run.slots[run.next].etag_len != 0) run.next += 1;
        if (run.next == run.plan.parts) return null;
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
    /// caused it, and returns that failure. With a checkpoint, a failure a
    /// resume could get past aborts nothing: the parts and the state stay
    /// for a later process. A cancel was delivered once already, so the
    /// abort runs protected from another and is bounded by the client's
    /// request timeout.
    fn giveUp(run: *Run, err: Error) Error {
        const client = run.client;
        if (run.persist != null and !abandons(err)) {
            logging.warn("the multipart upload of {s} failed with {t}; its parts and checkpoint stay for a resume", .{ run.object, err });
            return err;
        }
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

    /// Sends parts until there are none left or one has failed. Every
    /// failure goes to the run, a cancel included: a group swallows the
    /// `Canceled` its task returns, and a run that recorded nothing would
    /// go on to finish an upload missing parts.
    fn main(w: *Worker, run: *Run) error{Canceled}!void {
        while (run.take()) |index| {
            w.send(run, index) catch |err| {
                run.fail(err, &w.diag);
                if (err == error.Canceled) return error.Canceled;
                return;
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
    // Seven parts, one start, one finish, one read back, nothing left open,
    // and with no conditions, no move.
    try testing.expectEqual(7, s.fake.counts.parts);
    try testing.expectEqual(1, s.fake.counts.starts);
    try testing.expectEqual(1, s.fake.counts.finishes);
    try testing.expectEqual(1, s.fake.counts.reads);
    try testing.expectEqual(0, s.fake.counts.moves);
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

test "uploadParallel: the abort runs to its end under a cancel still pending" {
    // Every sleep not protected from cancellation reports it: a part's
    // retry meets it, and the abort, retried after a 503 of its own, must
    // not, or its parts would stay behind to be billed.
    var clock: test_util.FakeClock = .{ .cancel_sleep = true };
    var rules = [_]Script.Rule{
        .{ .kind = .part, .part = 1, .fault = .unavailable, .times = 99 },
        .{ .kind = .abort, .fault = .unavailable },
    };
    var script: Script = .{ .rules = &rules };
    var s: Setup = undefined;
    try s.init(clock.io(), .{ .max_attempts = 3 });
    defer s.deinit();
    s.fake.faults = script.plan();
    var data: [9000]u8 = undefined;
    fill(&data, 32);
    try testing.expectError(error.Canceled, s.object("o").uploadParallel(.{ .data = &data }, .{ .part_size = 4096 }));
    try testing.expectEqual(0, rules[1].times);
    try testing.expectEqual(1, s.fake.counts.aborts);
    try testing.expectEqual(0, s.fake.openUploads());
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
    var created = try client.bucket("b").object("c").uploadParallel(.{ .data = &data }, .{
        .part_size = 1024,
        .preconditions = .does_not_exist,
    });
    created.deinit();
}

test "uploadParallel: every allocation failure is OutOfMemory, and nothing leaks" {
    try testing.checkAllAllocationFailures(testing.allocator, parallelEverything, .{});
}

/// Draws each request's fate from fuzz bytes, under the fake's lock:
/// mostly nothing, sometimes a fault that kind of request can meet. The
/// cleanup requests, abort and delete, always go through; their failures
/// are tested on their own. With `clean_reads`, so do metadata reads,
/// which is how an upload with conditions finds a temporary object to
/// delete.
const Chooser = struct {
    bytes: []const u8,
    pos: usize = 0,
    faulted: bool = false,
    /// Another writer's object appeared before a move.
    clobbered: bool = false,
    clean_reads: bool = false,

    fn plan(self: *Chooser) FakeMultipart.FaultPlan {
        return .{ .ctx = self, .decide = decide };
    }

    fn decide(ctx: ?*anyopaque, kind: FakeMultipart.Kind, part: u32) FakeMultipart.Fault {
        _ = part;
        const self: *Chooser = @ptrCast(@alignCast(ctx.?));
        if (kind == .abort or kind == .delete or self.pos >= self.bytes.len) return .none;
        if (kind == .read and self.clean_reads) return .none;
        const b = self.bytes[self.pos];
        self.pos += 1;
        const fault: FakeMultipart.Fault = switch (b) {
            0...199 => .none,
            200...214 => .unavailable,
            215...229 => .reset,
            230...239 => .lose_answer,
            240...245 => if (kind == .part or kind == .finish) .corrupt else .none,
            246...249 => if (kind == .part or kind == .finish) .gone else .none,
            else => if (kind == .finish) .error_200 else if (kind == .move) .clobber else .none,
        };
        if (fault != .none) self.faulted = true;
        if (fault == .clobber) self.clobbered = true;
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

/// No temporary object left anywhere in the fake.
fn expectNoTemp(fake: *const FakeMultipart) !void {
    for (fake.objects.items) |o| {
        errdefer std.debug.print("left behind: {s}\n", .{o.name});
        try testing.expect(!std.mem.startsWith(u8, o.name, temp_prefix));
    }
}

test "uploadParallel with conditions: checked, sent under a temporary name, and moved into place" {
    var s: Setup = undefined;
    try s.init(testing.io, .{});
    defer s.deinit();
    var data: [20 * 1024 + 3]u8 = undefined;
    fill(&data, 20);
    var info = try s.object("dir/o").uploadParallel(.{ .data = &data }, .{
        .content_type = "application/x-test",
        .metadata = &.{.{ .key = "origin", .value = "zig" }},
        .part_size = 4096,
        .concurrency = 3,
        .preconditions = .does_not_exist,
    });
    defer info.deinit();
    try testing.expectEqualStrings("dir/o", info.value.name);
    try testing.expectEqual(data.len, info.value.size);
    try testing.expectEqual(core.crc32c.hash(&data), info.value.crc32c.?);
    try testing.expectEqual(1, info.value.metageneration);
    const stored = s.fake.object("dir/o").?;
    try testing.expectEqualSlices(u8, &data, stored.bytes);
    try testing.expectEqual(info.value.generation, stored.generation);
    try testing.expectEqualStrings("application/x-test", stored.content_type);
    try testing.expectEqualStrings("zig", stored.metadata[0].value);
    try expectNoTemp(&s.fake);
    // The early check, the upload under the temporary name, and the move,
    // whose answer is the object: no read back.
    try testing.expectEqual(1, s.fake.counts.reads);
    try testing.expectEqual(1, s.fake.counts.starts);
    try testing.expectEqual(6, s.fake.counts.parts);
    try testing.expectEqual(1, s.fake.counts.finishes);
    try testing.expectEqual(1, s.fake.counts.moves);
    try testing.expectEqual(0, s.fake.counts.deletes);
    try testing.expectEqual(0, s.fake.openUploads());

    // Replacing that very generation, and only it.
    var replaced = try s.object("dir/o").uploadParallel(.{ .data = "a newer, much shorter object" }, .{
        .part_size = 4096,
        .preconditions = .{ .if_generation_match = info.value.generation },
    });
    defer replaced.deinit();
    try testing.expectEqualStrings("a newer, much shorter object", s.fake.object("dir/o").?.bytes);
    try expectNoTemp(&s.fake);
}

test "uploadParallel with conditions: one that already fails refuses the upload before a byte is sent" {
    var s: Setup = undefined;
    try s.init(testing.io, .{});
    defer s.deinit();
    try s.fake.put("o", "already here");
    const generation = s.fake.object("o").?.generation;
    var data: [9000]u8 = undefined;
    fill(&data, 21);
    const refusals = [_]types.Preconditions{
        .does_not_exist,
        .{ .if_generation_match = generation + 1 },
        .{ .if_metageneration_match = 2 },
        // A read answers a failing `…NotMatch` condition with 304.
        .{ .if_generation_not_match = generation },
        .{ .if_metageneration_not_match = 1 },
    };
    for (refusals) |conditions| {
        try testing.expectError(error.FailedPrecondition, s.object("o").uploadParallel(.{ .data = &data }, .{
            .part_size = 4096,
            .preconditions = conditions,
        }));
        try testing.expect(std.mem.indexOf(u8, s.diag.message(), "already fail, so nothing was sent") != null);
    }
    try testing.expectEqual(refusals.len, s.fake.counts.reads);
    try testing.expectEqual(0, s.fake.counts.starts);
    try testing.expectEqualStrings("already here", s.fake.object("o").?.bytes);
}

test "uploadParallel with conditions: an object that appears before the move is kept, and the temporary object goes" {
    var rules = [_]Script.Rule{.{ .kind = .move, .fault = .clobber }};
    var script: Script = .{ .rules = &rules };
    var s: Setup = undefined;
    try s.init(testing.io, .{});
    defer s.deinit();
    s.fake.faults = script.plan();
    var data: [9000]u8 = undefined;
    fill(&data, 22);
    try testing.expectError(error.FailedPrecondition, s.object("o").uploadParallel(.{ .data = &data }, .{
        .part_size = 4096,
        .preconditions = .does_not_exist,
    }));
    try testing.expect(std.mem.indexOf(u8, s.diag.message(), "failed at the move; the upload was undone") != null);
    try testing.expectEqualStrings("another writer's bytes", s.fake.object("o").?.bytes);
    try expectNoTemp(&s.fake);
    // The refused move, then a read of the temporary object, still there,
    // then its deletion.
    try testing.expectEqual(1, s.fake.counts.moves);
    try testing.expectEqual(2, s.fake.counts.reads);
    try testing.expectEqual(1, s.fake.counts.deletes);
}

test "uploadParallel with conditions: a move whose answer was lost is found by reading, whichever condition its repeat meets" {
    for ([_]bool{ false, true }) |destination_first| {
        var rules = [_]Script.Rule{.{ .kind = .move, .fault = .lose_answer }};
        var script: Script = .{ .rules = &rules };
        var s: Setup = undefined;
        try s.init(testing.io, .{});
        defer s.deinit();
        s.fake.faults = script.plan();
        // Its repeat finds the source gone, a 404, or the destination
        // taken by the object it made itself, a 412.
        s.fake.move_checks_destination_first = destination_first;
        var data: [9000]u8 = undefined;
        fill(&data, 23);
        var info = try s.object("o").uploadParallel(.{ .data = &data }, .{
            .part_size = 4096,
            .preconditions = .does_not_exist,
        });
        defer info.deinit();
        try testing.expectEqualSlices(u8, &data, s.fake.object("o").?.bytes);
        try testing.expectEqual(core.crc32c.hash(&data), info.value.crc32c.?);
        try testing.expectEqual(2, s.fake.counts.moves);
        try testing.expectEqual(0, s.fake.counts.deletes);
        try expectNoTemp(&s.fake);
    }
}

test "uploadParallel with conditions: a lost move answer with another writer's object in its place is UploadSessionLost" {
    // The move lands and its answer is lost; before the repeat, another
    // writer replaces the object. The temporary object is gone, and the
    // object is not this upload's.
    var rules = [_]Script.Rule{
        .{ .kind = .move, .fault = .lose_answer },
        .{ .kind = .move, .fault = .clobber },
    };
    var script: Script = .{ .rules = &rules };
    var s: Setup = undefined;
    try s.init(testing.io, .{});
    defer s.deinit();
    s.fake.faults = script.plan();
    var data: [9000]u8 = undefined;
    fill(&data, 24);
    try testing.expectError(error.UploadSessionLost, s.object("o").uploadParallel(.{ .data = &data }, .{
        .part_size = 4096,
        .preconditions = .does_not_exist,
    }));
    try testing.expect(std.mem.indexOf(u8, s.diag.message(), "the object does not hold its bytes") != null);
    try testing.expectEqualStrings("another writer's bytes", s.fake.object("o").?.bytes);
    try expectNoTemp(&s.fake);
}

test "uploadParallel with conditions: a finish whose answer was lost is found by reading back, then moved" {
    var rules = [_]Script.Rule{.{ .kind = .finish, .fault = .lose_answer }};
    var script: Script = .{ .rules = &rules };
    var s: Setup = undefined;
    try s.init(testing.io, .{});
    defer s.deinit();
    s.fake.faults = script.plan();
    var data: [9000]u8 = undefined;
    fill(&data, 28);
    var info = try s.object("o").uploadParallel(.{ .data = &data }, .{ .part_size = 4096, .preconditions = .does_not_exist });
    defer info.deinit();
    try testing.expectEqualSlices(u8, &data, s.fake.object("o").?.bytes);
    // The early check, then the temporary object read back, which named
    // the generation the move pins.
    try testing.expectEqual(2, s.fake.counts.finishes);
    try testing.expectEqual(2, s.fake.counts.reads);
    try testing.expectEqual(1, s.fake.counts.moves);
    try expectNoTemp(&s.fake);
}

test "uploadParallel with conditions: a move that answers with another object is InvalidResponse" {
    var rules = [_]Script.Rule{.{ .kind = .move, .fault = .corrupt }};
    var script: Script = .{ .rules = &rules };
    var s: Setup = undefined;
    try s.init(testing.io, .{});
    defer s.deinit();
    s.fake.faults = script.plan();
    var data: [9000]u8 = undefined;
    fill(&data, 29);
    try testing.expectError(error.InvalidResponse, s.object("o").uploadParallel(.{ .data = &data }, .{
        .part_size = 4096,
        .preconditions = .does_not_exist,
    }));
    try testing.expect(std.mem.indexOf(u8, s.diag.message(), "is not the one sent") != null);
}

test "uploadParallel: a worker that meets Canceled stops the upload, which aborts and returns Canceled" {
    // No cancel reached the task, so the group returns normally: only the
    // failure the worker recorded says the upload did not finish.
    var rules = [_]Script.Rule{.{ .kind = .part, .part = 2, .fault = .canceled }};
    var script: Script = .{ .rules = &rules };
    var s: Setup = undefined;
    try s.init(testing.io, .{});
    defer s.deinit();
    s.fake.faults = script.plan();
    var data: [20 * 1024]u8 = undefined;
    fill(&data, 30);
    try testing.expectError(error.Canceled, s.object("o").uploadParallel(.{ .data = &data }, .{ .part_size = 4096, .concurrency = 2 }));
    try testing.expectEqual(0, s.fake.counts.finishes);
    try testing.expectEqual(1, s.fake.counts.aborts);
    try testing.expectEqual(0, s.fake.openUploads());
    try testing.expectEqual(null, s.fake.object("o"));
}

test "uploadParallel with conditions: a lost move answer and a same-sized object in its place is told apart by its checksum" {
    // As above, with this upload exactly as long as the other writer's
    // bytes: only the checksum says the object is not this upload's.
    var rules = [_]Script.Rule{
        .{ .kind = .move, .fault = .lose_answer },
        .{ .kind = .move, .fault = .clobber },
    };
    var script: Script = .{ .rules = &rules };
    var s: Setup = undefined;
    try s.init(testing.io, .{});
    defer s.deinit();
    s.fake.faults = script.plan();
    const data = "this upload's 22 bytes";
    try testing.expectEqual("another writer's bytes".len, data.len);
    try testing.expectError(error.UploadSessionLost, s.object("o").uploadParallel(.{ .data = data }, .{
        .part_size = 4096,
        .preconditions = .does_not_exist,
    }));
    try testing.expectEqualStrings("another writer's bytes", s.fake.object("o").?.bytes);
}

test "uploadParallel with conditions: the cleanup runs to its end under a cancel still pending" {
    // Every sleep not protected from cancellation reports it: the move's
    // retry meets it, and the cleanup's delete, retried after a 503 of its
    // own, must not.
    var clock: test_util.FakeClock = .{ .cancel_sleep = true };
    var rules = [_]Script.Rule{
        .{ .kind = .move, .fault = .unavailable, .times = 99 },
        .{ .kind = .delete, .fault = .unavailable },
    };
    var script: Script = .{ .rules = &rules };
    var s: Setup = undefined;
    try s.init(clock.io(), .{ .max_attempts = 3 });
    defer s.deinit();
    s.fake.faults = script.plan();
    var data: [9000]u8 = undefined;
    fill(&data, 31);
    try testing.expectError(error.Canceled, s.object("o").uploadParallel(.{ .data = &data }, .{
        .part_size = 4096,
        .preconditions = .does_not_exist,
    }));
    // The delete met its 503, slept, and was answered on its retry.
    try testing.expectEqual(0, rules[1].times);
    try testing.expectEqual(1, s.fake.counts.deletes);
    try expectNoTemp(&s.fake);
    try testing.expectEqual(null, s.fake.object("o"));
}

test "uploadParallel with conditions: a move that fails any other way deletes the temporary object" {
    var rules = [_]Script.Rule{.{ .kind = .move, .fault = .unavailable, .times = 99 }};
    var script: Script = .{ .rules = &rules };
    var s: Setup = undefined;
    try s.init(testing.io, .{ .max_attempts = 2 });
    defer s.deinit();
    s.fake.faults = script.plan();
    var data: [9000]u8 = undefined;
    fill(&data, 25);
    try testing.expectError(error.Unavailable, s.object("o").uploadParallel(.{ .data = &data }, .{
        .part_size = 4096,
        .preconditions = .does_not_exist,
    }));
    // The move's own diagnostics, not the cleanup's.
    try testing.expect(std.mem.indexOf(u8, s.diag.message(), "try again") != null);
    try testing.expectEqual(null, s.fake.object("o"));
    try expectNoTemp(&s.fake);
    try testing.expectEqual(1, s.fake.counts.deletes);
}

test "uploadParallel with conditions: a finish that landed before the upload failed leaves no temporary object" {
    // The finish lands and its answer is lost; every repeat meets a 503.
    var rules = [_]Script.Rule{
        .{ .kind = .finish, .fault = .lose_answer },
        .{ .kind = .finish, .fault = .unavailable, .times = 99 },
    };
    var script: Script = .{ .rules = &rules };
    var s: Setup = undefined;
    try s.init(testing.io, .{ .max_attempts = 2 });
    defer s.deinit();
    s.fake.faults = script.plan();
    var data: [9000]u8 = undefined;
    fill(&data, 26);
    try testing.expectError(error.Unavailable, s.object("o").uploadParallel(.{ .data = &data }, .{
        .part_size = 4096,
        .preconditions = .does_not_exist,
    }));
    try testing.expectEqual(null, s.fake.object("o"));
    try expectNoTemp(&s.fake);
    try testing.expectEqual(0, s.fake.counts.moves);
    try testing.expectEqual(1, s.fake.counts.deletes);
    try testing.expectEqual(0, s.fake.openUploads());
}

test "uploadParallel with conditions: a cancel at the move deletes the temporary object" {
    var rules = [_]Script.Rule{.{ .kind = .move, .fault = .wait }};
    var script: Script = .{ .rules = &rules };
    var s: Setup = undefined;
    try s.init(testing.io, .{});
    defer s.deinit();
    s.fake.faults = script.plan();
    var data: [9000]u8 = undefined;
    fill(&data, 27);

    const Running = struct {
        fn go(target: Object, bytes: []const u8) Error!void {
            var info = try target.uploadParallel(.{ .data = bytes }, .{ .part_size = 4096, .preconditions = .does_not_exist });
            info.deinit();
        }
    };
    var task = try testing.io.concurrent(Running.go, .{ s.object("o"), &data });
    // The move waits at the gate once the finish is in.
    const deadline = std.Io.Clock.awake.now(testing.io).addDuration(.fromSeconds(10));
    while (true) {
        s.fake.mutex.lockUncancelable(testing.io);
        const finished = s.fake.counts.finishes;
        s.fake.mutex.unlock(testing.io);
        if (finished >= 1) break;
        if (std.Io.Clock.awake.now(testing.io).nanoseconds > deadline.nanoseconds) @panic("the upload never finished its parts");
        try testing.io.sleep(.fromMilliseconds(1), .awake);
    }
    try testing.io.sleep(.fromMilliseconds(20), .awake);
    try testing.expectError(error.Canceled, task.cancel(testing.io));
    try testing.expectEqual(null, s.fake.object("o"));
    try expectNoTemp(&s.fake);
}

test "uploadParallel with conditions: an emulator gets one ordinary upload carrying them" {
    var fake: test_util.FakeTransport = .init(testing.allocator, &.{
        .{ .respond = .{ .body = "{\"name\":\"o\",\"bucket\":\"b\",\"size\":\"5\",\"generation\":\"1\",\"crc32c\":\"mnG7TA==\"}" } },
    });
    defer fake.deinit();
    var client: Client = try .init(testing.allocator, testing.io, .{
        .endpoint = .{ .url = "http://127.0.0.1:4443", .emulator = true },
        .transport = fake.transport(),
    });
    defer client.deinit();
    var info = try client.bucket("b").object("o").uploadParallel(.{ .data = "hello" }, .{ .preconditions = .does_not_exist });
    defer info.deinit();
    const sent = try fake.streamRequest(0);
    try testing.expect(std.mem.indexOf(u8, sent.url, "uploadType=multipart") != null);
    try testing.expect(std.mem.indexOf(u8, sent.url, "ifGenerationMatch=0") != null);
    try testing.expectEqual(1, fake.stream_requests.items.len);
    try testing.expectEqual(0, fake.requests.items.len);
}

test "tempName: the prefix and 32 hex digits, different every time" {
    var a_buf: [temp_prefix.len + 32]u8 = undefined;
    var b_buf: [temp_prefix.len + 32]u8 = undefined;
    const a = tempName(testing.io, &a_buf);
    const b = tempName(testing.io, &b_buf);
    try testing.expectEqual(temp_prefix.len + 32, a.len);
    try testing.expect(std.mem.startsWith(u8, a, temp_prefix));
    for (a[temp_prefix.len..]) |c| try testing.expect(std.ascii.isDigit(c) or (c >= 'a' and c <= 'f'));
    try testing.expect(!std.mem.eql(u8, a, b));
}

/// One upload with conditions under a drawn fault schedule, held to what
/// must hold whatever the faults: nothing is ever left under the temporary
/// prefix, and no part in an open upload; a success stored this upload's
/// bytes; conditions that cannot hold always fail, before a byte is sent
/// when the object is there to refuse them, and never touch it; and a run
/// whose conditions hold and that met no fault never fails.
fn runConditionalUnderFaults(io: std.Io, input: []const u8) !void {
    var g: test_util.ByteGen = .init(input);
    const size = g.intRange(usize, 0, 24 * 1024);
    const part_size = g.intRange(u64, 1024, 8 * 1024);
    const concurrency = g.intRange(u16, 1, 4);
    const verify = g.intRange(u8, 0, 7) != 0;
    const existing = g.boolean();
    const which = g.intRange(u8, 0, 4);
    const destination_first = g.boolean();
    const data = try testing.allocator.alloc(u8, size);
    defer testing.allocator.free(data);
    fill(data, g.int(u64));

    var s: Setup = undefined;
    try s.init(io, .{ .verify_checksums = verify });
    defer s.deinit();
    s.fake.move_checks_destination_first = destination_first;
    if (existing) try s.fake.put("o", "an older object");
    const old_generation: u64 = if (existing) s.fake.object("o").?.generation else 7;
    const conditions: types.Preconditions, const holds: bool = switch (which) {
        0 => .{ .does_not_exist, !existing },
        1 => .{ .{ .if_generation_match = old_generation }, existing },
        2 => .{ .{ .if_generation_not_match = old_generation + 1 }, existing },
        3 => .{ .{ .if_metageneration_match = 1 }, existing },
        else => .{ .{ .if_generation_match = old_generation + 1 }, false },
    };
    var chooser: Chooser = .{ .bytes = g.rest(), .clean_reads = true };
    s.fake.faults = chooser.plan();

    const outcome = s.object("o").uploadParallel(.{ .data = data }, .{
        .part_size = part_size,
        .concurrency = concurrency,
        .preconditions = conditions,
    });
    try expectNoTemp(&s.fake);
    try testing.expectEqual(0, s.fake.openParts());
    if (outcome) |info_const| {
        var info = info_const;
        defer info.deinit();
        // Another writer's object can make conditions hold that did not:
        // "not generation 8", say, where there was no object at all.
        try testing.expect(holds or chooser.clobbered);
        try testing.expectEqual(size, info.value.size);
        if (verify) try testing.expectEqualSlices(u8, data, s.fake.object("o").?.bytes);
    } else |err| {
        errdefer std.debug.print("{t}: {s}\n", .{ err, s.diag.message() });
        try testing.expect(chooser.faulted or !holds);
        if (!holds and !chooser.clobbered) {
            if (!chooser.faulted) {
                try testing.expectEqual(error.FailedPrecondition, err);
                // Refused early when the object is there to refuse them.
                if (existing) try testing.expectEqual(0, s.fake.counts.starts);
            }
            // Never replaced, whatever failed first.
            if (existing) {
                try testing.expectEqualStrings("an older object", s.fake.object("o").?.bytes);
                try testing.expectEqual(old_generation, s.fake.object("o").?.generation);
            } else try testing.expectEqual(null, s.fake.object("o"));
        }
    }
}

fn conditionalFaultProperty(_: void, input: []const u8) !void {
    var clock: test_util.FakeClock = .{};
    try runConditionalUnderFaults(clock.io(), input);
}

test "fault property parallel conditional: nothing left under the temporary prefix, and nothing replaced against its conditions" {
    try test_util.fuzzBytes({}, conditionalFaultProperty, .{
        .random_runs = 300,
        .max_len = 256,
        .corpus = &.{
            "",
            // 24 KiB, create-only, no faults.
            "\xff\xff\xff\xff\xff\xff\xff\xff\x00\x00\x00\x00\x00\x00\x00\x00\x00\x03\x01\x00\x00\x00",
            // A lost move answer, then another writer's object.
            "\x00\x00\x00\x00\x00\x00\x40\x00\x00\x00\x00\x00\x00\x00\x08\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\xe6\xff",
        },
    });
}

test "uploadParallel with conditions: the same invariants on real threads, under a hundred fault schedules" {
    var prng: std.Random.DefaultPrng = .init(20260925);
    var input: [192]u8 = undefined;
    for (0..100) |_| {
        prng.random().bytes(&input);
        runConditionalUnderFaults(testing.io, &input) catch |err| {
            std.debug.print("input: {x}\n", .{&input});
            return err;
        };
    }
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

const MemoryCheckpoint = test_util.MemoryCheckpoint;

/// A client of its own on a shared fake, as each process of a resumed
/// upload has, with the part floor lowered to 1 KiB.
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

/// The test's source file, opened to be rewritten between "processes".
fn sourceOn(tmp: *testing.TmpDir, data: []const u8) !std.Io.File {
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "source.bin", .data = data });
    return tmp.dir.openFile(testing.io, "source.bin", .{ .mode = .read_write });
}

test "uploadParallel: a checkpoint on a memory source is refused before anything is sent" {
    var s: Setup = undefined;
    try s.init(testing.io, .{});
    defer s.deinit();
    var saved: MemoryCheckpoint = .{ .gpa = testing.allocator };
    defer saved.deinit();
    try testing.expectError(error.InvalidParallelUploadOptions, s.object("o").uploadParallel(.{ .data = "bytes" }, .{
        .part_size = 1024,
        .checkpoint = saved.checkpoint(),
    }));
    try testing.expect(std.mem.indexOf(u8, s.diag.message(), "only a file source outlives a process") != null);
    try testing.expectEqual(0, s.fake.counts.starts);
    try testing.expectEqual(0, saved.loads);
}

test "uploadParallel with a checkpoint: saved once at the start, cleared at the end" {
    var s: Setup = undefined;
    try s.init(testing.io, .{});
    defer s.deinit();
    var data: [6 * 1024]u8 = undefined;
    fill(&data, 40);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try sourceOn(&tmp, &data);
    defer file.close(testing.io);
    var saved: MemoryCheckpoint = .{ .gpa = testing.allocator };
    defer saved.deinit();
    var info = try s.object("dir/o").uploadParallel(.{ .file = file }, .{
        .part_size = 1024,
        .concurrency = 2,
        .checkpoint = saved.checkpoint(),
    });
    defer info.deinit();
    try testing.expectEqual(data.len, info.value.size);
    try testing.expectEqualSlices(u8, &data, s.fake.object("dir/o").?.bytes);
    // One save when the upload starts: the server says which parts it
    // holds, so nothing more is recorded. One clear when it is done.
    try testing.expectEqual(1, saved.saves);
    try testing.expectEqual(1, saved.clears);
    try testing.expectEqual(null, saved.stored);
}

test "uploadParallel: a run that dies partway leaves a checkpoint a second client resumes, sending only what is missing" {
    var fake: FakeMultipart = .init(testing.allocator, testing.io);
    fake.min_part_size = 1024;
    defer fake.deinit();
    var token: core.StaticToken = .{ .token = "ya29.t" };
    var data: [6 * 1024]u8 = undefined;
    fill(&data, 41);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try sourceOn(&tmp, &data);
    defer file.close(testing.io);
    var store: checkpoint.CheckpointFile = .init(testing.io, tmp.dir, "o.upload");
    const options: types.ParallelUploadOptions = .{
        .part_size = 1024,
        .concurrency = 1,
        .checkpoint = store.checkpoint(),
    };

    // The first process sends two parts, and the third request dies with
    // it.
    var rules = [_]Script.Rule{.{ .kind = .part, .part = 3, .fault = .canceled }};
    var script: Script = .{ .rules = &rules };
    fake.faults = script.plan();
    {
        var diag: Diagnostics = .{};
        var first = try clientOn(&fake, &token, &diag, 4);
        defer first.deinit();
        try testing.expectError(error.Canceled, first.bucket("b").object("dir/o").uploadParallel(.{ .file = file }, options));
    }
    try testing.expectEqual(2, fake.counts.parts);
    try testing.expectEqual(0, fake.counts.aborts);
    try testing.expectEqual(1, fake.openUploads());
    try testing.expectEqual(2, fake.openParts());

    // The second process asks the server where the upload stands, re-reads
    // those parts locally, and sends only the other four.
    fake.faults = null;
    var diag: Diagnostics = .{};
    var second = try clientOn(&fake, &token, &diag, 4);
    defer second.deinit();
    var info = try second.bucket("b").object("dir/o").uploadParallel(.{ .file = file }, options);
    defer info.deinit();
    try testing.expectEqual(data.len, info.value.size);
    try testing.expectEqual(core.crc32c.hash(&data), info.value.crc32c.?);
    try testing.expectEqualSlices(u8, &data, fake.object("dir/o").?.bytes);
    try testing.expectEqual(1, fake.counts.starts);
    try testing.expectEqual(1, fake.counts.lists);
    try testing.expectEqual(2 + 4, fake.counts.parts);
    try testing.expectEqual(1, fake.counts.finishes);
    try testing.expectEqual(0, fake.openUploads());
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(testing.io, "o.upload", .{}));
}

test "uploadParallel: a source file that changed abandons the old upload and starts over" {
    var fake: FakeMultipart = .init(testing.allocator, testing.io);
    fake.min_part_size = 1024;
    defer fake.deinit();
    var token: core.StaticToken = .{ .token = "ya29.t" };
    var data: [6 * 1024]u8 = undefined;
    fill(&data, 42);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try sourceOn(&tmp, &data);
    defer file.close(testing.io);
    var saved: MemoryCheckpoint = .{ .gpa = testing.allocator };
    defer saved.deinit();
    const options: types.ParallelUploadOptions = .{
        .part_size = 1024,
        .concurrency = 1,
        .checkpoint = saved.checkpoint(),
    };

    var rules = [_]Script.Rule{.{ .kind = .part, .part = 3, .fault = .canceled }};
    var script: Script = .{ .rules = &rules };
    fake.faults = script.plan();
    var diag: Diagnostics = .{};
    var client = try clientOn(&fake, &token, &diag, 4);
    defer client.deinit();
    try testing.expectError(error.Canceled, client.bucket("b").object("o").uploadParallel(.{ .file = file }, options));
    fake.faults = null;

    // The file grows a byte: nothing the server holds describes it now.
    var grown: [6 * 1024 + 1]u8 = undefined;
    fill(&grown, 43);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "source.bin", .data = &grown });
    var info = try client.bucket("b").object("o").uploadParallel(.{ .file = file }, options);
    defer info.deinit();
    try testing.expectEqual(grown.len, info.value.size);
    try testing.expectEqualSlices(u8, &grown, fake.object("o").?.bytes);
    // The old upload was aborted, a new one started, and all seven parts
    // of the grown file sent.
    try testing.expectEqual(1, fake.counts.aborts);
    try testing.expectEqual(2, fake.counts.starts);
    try testing.expectEqual(0, fake.counts.lists);
    try testing.expectEqual(2 + 7, fake.counts.parts);
    try testing.expectEqual(0, fake.openUploads());
    try testing.expectEqual(null, saved.stored);
}

test "uploadParallel: conditions that changed abandon the old upload and start over" {
    var fake: FakeMultipart = .init(testing.allocator, testing.io);
    fake.min_part_size = 1024;
    defer fake.deinit();
    var token: core.StaticToken = .{ .token = "ya29.t" };
    var data: [4 * 1024]u8 = undefined;
    fill(&data, 44);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try sourceOn(&tmp, &data);
    defer file.close(testing.io);
    var saved: MemoryCheckpoint = .{ .gpa = testing.allocator };
    defer saved.deinit();

    // The first process uploads create-only, under a temporary name, and
    // dies at its second part.
    var rules = [_]Script.Rule{.{ .kind = .part, .part = 2, .fault = .canceled }};
    var script: Script = .{ .rules = &rules };
    fake.faults = script.plan();
    var diag: Diagnostics = .{};
    var client = try clientOn(&fake, &token, &diag, 4);
    defer client.deinit();
    try testing.expectError(error.Canceled, client.bucket("b").object("o").uploadParallel(.{ .file = file }, .{
        .part_size = 1024,
        .concurrency = 1,
        .preconditions = .does_not_exist,
        .checkpoint = saved.checkpoint(),
    }));
    try testing.expect(saved.stored != null);
    fake.faults = null;

    // The second asks for no conditions at all: not the same transfer.
    var info = try client.bucket("b").object("o").uploadParallel(.{ .file = file }, .{
        .part_size = 1024,
        .concurrency = 1,
        .checkpoint = saved.checkpoint(),
    });
    defer info.deinit();
    try testing.expectEqualSlices(u8, &data, fake.object("o").?.bytes);
    try testing.expectEqual(1, fake.counts.aborts);
    try testing.expectEqual(2, fake.counts.starts);
    try testing.expectEqual(1 + 4, fake.counts.parts);
    try testing.expectEqual(0, fake.counts.moves);
    try testing.expectEqual(0, fake.openUploads());
}

test "uploadParallel: a part of the wrong size is not trusted, and sending again replaces it" {
    var fake: FakeMultipart = .init(testing.allocator, testing.io);
    fake.min_part_size = 1024;
    defer fake.deinit();
    var token: core.StaticToken = .{ .token = "ya29.t" };
    var data: [6 * 1024]u8 = undefined;
    fill(&data, 45);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try sourceOn(&tmp, &data);
    defer file.close(testing.io);
    var saved: MemoryCheckpoint = .{ .gpa = testing.allocator };
    defer saved.deinit();

    var rules = [_]Script.Rule{.{ .kind = .part, .part = 3, .fault = .canceled }};
    var script: Script = .{ .rules = &rules };
    fake.faults = script.plan();
    var diag: Diagnostics = .{};
    var client = try clientOn(&fake, &token, &diag, 4);
    defer client.deinit();
    try testing.expectError(error.Canceled, client.bucket("b").object("o").uploadParallel(.{ .file = file }, .{
        .part_size = 1024,
        .concurrency = 1,
        .checkpoint = saved.checkpoint(),
    }));
    fake.faults = null;

    // A state naming another part size: the two 1 KiB parts the server
    // holds fit no slot of the 2 KiB plan, so everything goes up fresh
    // under the same upload.
    const forged = try checkpoint.encodeAlloc(testing.allocator, .{ .upload_parallel = .{
        .bucket = "b",
        .object = "o",
        .size = data.len,
        .mtime = (try file.stat(testing.io)).mtime.nanoseconds,
        .upload_id = fake.uploads.items[0].id,
        .part_size = 2048,
        .temp = null,
        .if_generation_match = null,
        .if_generation_not_match = null,
        .if_metageneration_match = null,
        .if_metageneration_not_match = null,
    } });
    testing.allocator.free(saved.stored.?);
    saved.stored = forged;
    var info = try client.bucket("b").object("o").uploadParallel(.{ .file = file }, .{
        .part_size = 1024,
        .concurrency = 1,
        .checkpoint = saved.checkpoint(),
    });
    defer info.deinit();
    try testing.expectEqualSlices(u8, &data, fake.object("o").?.bytes);
    try testing.expectEqual(1, fake.counts.lists);
    // Two parts before the crash, three of the resumed plan's size.
    try testing.expectEqual(2 + 3, fake.counts.parts);
    try testing.expectEqual(1, fake.counts.starts);
}

test "uploadParallel: a checkpoint of a finished upload finds the object and sends nothing" {
    var s: Setup = undefined;
    try s.init(testing.io, .{});
    defer s.deinit();
    var data: [4 * 1024]u8 = undefined;
    fill(&data, 46);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try sourceOn(&tmp, &data);
    defer file.close(testing.io);
    // The process dies between the finish and the clear.
    var saved: MemoryCheckpoint = .{ .gpa = testing.allocator, .keep_on_clear = true };
    defer saved.deinit();
    const options: types.ParallelUploadOptions = .{ .part_size = 1024, .checkpoint = saved.checkpoint() };
    var first = try s.object("o").uploadParallel(.{ .file = file }, options);
    first.deinit();
    try testing.expect(saved.stored != null);
    try testing.expectEqual(4, s.fake.counts.parts);

    saved.keep_on_clear = false;
    var info = try s.object("o").uploadParallel(.{ .file = file }, options);
    defer info.deinit();
    try testing.expectEqual(data.len, info.value.size);
    try testing.expectEqual(core.crc32c.hash(&data), info.value.crc32c.?);
    // The upload was gone; the object already held the file's bytes, so
    // nothing was sent again.
    try testing.expectEqual(4, s.fake.counts.parts);
    try testing.expectEqual(1, s.fake.counts.starts);
    try testing.expectEqual(1, s.fake.counts.finishes);
    try testing.expectEqual(null, saved.stored);
}

test "uploadParallel: a checkpoint of an aborted upload starts over" {
    var fake: FakeMultipart = .init(testing.allocator, testing.io);
    fake.min_part_size = 1024;
    defer fake.deinit();
    var token: core.StaticToken = .{ .token = "ya29.t" };
    var data: [4 * 1024]u8 = undefined;
    fill(&data, 47);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try sourceOn(&tmp, &data);
    defer file.close(testing.io);
    var saved: MemoryCheckpoint = .{ .gpa = testing.allocator };
    defer saved.deinit();
    const options: types.ParallelUploadOptions = .{
        .part_size = 1024,
        .concurrency = 1,
        .checkpoint = saved.checkpoint(),
    };

    var rules = [_]Script.Rule{
        .{ .kind = .part, .part = 3, .fault = .canceled },
        // A lifecycle rule, say, aborted the upload between the runs.
        .{ .kind = .list, .fault = .gone },
    };
    var script: Script = .{ .rules = &rules };
    fake.faults = script.plan();
    var diag: Diagnostics = .{};
    var client = try clientOn(&fake, &token, &diag, 4);
    defer client.deinit();
    try testing.expectError(error.Canceled, client.bucket("b").object("o").uploadParallel(.{ .file = file }, options));

    var info = try client.bucket("b").object("o").uploadParallel(.{ .file = file }, options);
    defer info.deinit();
    try testing.expectEqualSlices(u8, &data, fake.object("o").?.bytes);
    // The gone upload was read for its parts, found gone, no object held
    // the bytes, and everything went up fresh.
    try testing.expectEqual(1, fake.counts.lists);
    try testing.expectEqual(2, fake.counts.starts);
    try testing.expectEqual(2 + 4, fake.counts.parts);
    try testing.expectEqual(null, saved.stored);
}

test "uploadParallel with conditions: a crash between the finish and the move is settled by the resume" {
    var fake: FakeMultipart = .init(testing.allocator, testing.io);
    fake.min_part_size = 1024;
    defer fake.deinit();
    var token: core.StaticToken = .{ .token = "ya29.t" };
    var data: [4 * 1024]u8 = undefined;
    fill(&data, 48);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try sourceOn(&tmp, &data);
    defer file.close(testing.io);
    var saved: MemoryCheckpoint = .{ .gpa = testing.allocator };
    defer saved.deinit();
    const options: types.ParallelUploadOptions = .{
        .part_size = 1024,
        .concurrency = 1,
        .preconditions = .does_not_exist,
        .checkpoint = saved.checkpoint(),
    };

    var rules = [_]Script.Rule{.{ .kind = .move, .fault = .canceled }};
    var script: Script = .{ .rules = &rules };
    fake.faults = script.plan();
    var diag: Diagnostics = .{};
    var client = try clientOn(&fake, &token, &diag, 4);
    defer client.deinit();
    try testing.expectError(error.Canceled, client.bucket("b").object("o").uploadParallel(.{ .file = file }, options));
    // The finish landed under the temporary name; the move died.
    try testing.expectEqual(1, fake.counts.finishes);
    try testing.expect(saved.stored != null);
    try testing.expect(fake.object("o") == null);
    fake.faults = null;

    var info = try client.bucket("b").object("o").uploadParallel(.{ .file = file }, options);
    defer info.deinit();
    try testing.expectEqualStrings("o", info.value.name);
    try testing.expectEqualSlices(u8, &data, fake.object("o").?.bytes);
    // No part went up again, no new upload, no second finish: only the
    // move that was owed, after the file was re-read and held to the
    // temporary object.
    try testing.expectEqual(4, fake.counts.parts);
    try testing.expectEqual(1, fake.counts.starts);
    try testing.expectEqual(1, fake.counts.finishes);
    try testing.expectEqual(1, fake.counts.moves);
    try testing.expectEqual(null, saved.stored);
    // Nothing lingers under the temporary prefix.
    for (fake.objects.items) |o| try testing.expect(!std.mem.startsWith(u8, o.name, temp_prefix));
}

test "uploadParallel with conditions: a resume whose conditions now fail abandons everything" {
    var fake: FakeMultipart = .init(testing.allocator, testing.io);
    fake.min_part_size = 1024;
    defer fake.deinit();
    var token: core.StaticToken = .{ .token = "ya29.t" };
    var data: [4 * 1024]u8 = undefined;
    fill(&data, 49);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try sourceOn(&tmp, &data);
    defer file.close(testing.io);
    var saved: MemoryCheckpoint = .{ .gpa = testing.allocator };
    defer saved.deinit();
    const options: types.ParallelUploadOptions = .{
        .part_size = 1024,
        .concurrency = 1,
        .preconditions = .does_not_exist,
        .checkpoint = saved.checkpoint(),
    };

    var rules = [_]Script.Rule{.{ .kind = .part, .part = 3, .fault = .canceled }};
    var script: Script = .{ .rules = &rules };
    fake.faults = script.plan();
    var diag: Diagnostics = .{};
    var client = try clientOn(&fake, &token, &diag, 4);
    defer client.deinit();
    try testing.expectError(error.Canceled, client.bucket("b").object("o").uploadParallel(.{ .file = file }, options));
    fake.faults = null;

    // Another writer created the object: create-only can never move into
    // place, so the parts go too, before any are sent again.
    try fake.put("o", "another writer's bytes");
    try testing.expectError(error.FailedPrecondition, client.bucket("b").object("o").uploadParallel(.{ .file = file }, options));
    try testing.expect(std.mem.indexOf(u8, diag.message(), "conditions already fail") != null);
    try testing.expectEqual(1, fake.counts.aborts);
    try testing.expectEqual(2, fake.counts.parts);
    try testing.expectEqual(0, fake.openUploads());
    try testing.expectEqual(null, saved.stored);
    try testing.expectEqualStrings("another writer's bytes", fake.object("o").?.bytes);
}

test "uploadParallel: a save that fails at the start aborts the unrecorded upload; retries run out and everything stays" {
    var fake: FakeMultipart = .init(testing.allocator, testing.io);
    fake.min_part_size = 1024;
    defer fake.deinit();
    var token: core.StaticToken = .{ .token = "ya29.t" };
    var data: [6 * 1024]u8 = undefined;
    fill(&data, 50);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try sourceOn(&tmp, &data);
    defer file.close(testing.io);
    var diag: Diagnostics = .{};
    var client = try clientOn(&fake, &token, &diag, 4);
    defer client.deinit();

    // The very first save fails: the upload it would have recorded goes.
    var saved: MemoryCheckpoint = .{ .gpa = testing.allocator, .saves_allowed = 0 };
    defer saved.deinit();
    const options: types.ParallelUploadOptions = .{
        .part_size = 1024,
        .concurrency = 1,
        .checkpoint = saved.checkpoint(),
    };
    try testing.expectError(error.CheckpointFailed, client.bucket("b").object("o").uploadParallel(.{ .file = file }, options));
    try testing.expect(std.mem.indexOf(u8, diag.message(), "refused a save") != null);
    try testing.expectEqual(1, fake.counts.starts);
    try testing.expectEqual(1, fake.counts.aborts);
    try testing.expectEqual(0, fake.counts.parts);
    try testing.expectEqual(0, fake.openUploads());

    // Retries running out on a part keeps the upload and the state.
    saved.saves_allowed = null;
    var rules = [_]Script.Rule{.{ .kind = .part, .part = 2, .times = 4, .fault = .unavailable }};
    var script: Script = .{ .rules = &rules };
    fake.faults = script.plan();
    try testing.expectError(error.Unavailable, client.bucket("b").object("o").uploadParallel(.{ .file = file }, options));
    try testing.expect(saved.stored != null);
    try testing.expectEqual(1, fake.counts.aborts);
    try testing.expectEqual(1, fake.openUploads());

    // And the next run finishes from there.
    fake.faults = null;
    var info = try client.bucket("b").object("o").uploadParallel(.{ .file = file }, options);
    defer info.deinit();
    try testing.expectEqualSlices(u8, &data, fake.object("o").?.bytes);
    try testing.expectEqual(0, fake.openUploads());
    try testing.expectEqual(null, saved.stored);
}

test "uploadParallel: with a checkpoint, a cancel keeps the parts for the next run" {
    var fake: FakeMultipart = .init(testing.allocator, testing.io);
    fake.min_part_size = 1024;
    defer fake.deinit();
    var token: core.StaticToken = .{ .token = "ya29.t" };
    var rules = [_]Script.Rule{.{ .kind = .part, .part = 2, .fault = .wait }};
    var script: Script = .{ .rules = &rules };
    fake.faults = script.plan();
    var data: [6 * 1024]u8 = undefined;
    fill(&data, 51);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try sourceOn(&tmp, &data);
    defer file.close(testing.io);
    var saved: MemoryCheckpoint = .{ .gpa = testing.allocator };
    defer saved.deinit();
    var diag: Diagnostics = .{};
    var client = try clientOn(&fake, &token, &diag, 4);
    defer client.deinit();
    const options: types.ParallelUploadOptions = .{
        .part_size = 1024,
        .concurrency = 2,
        .checkpoint = saved.checkpoint(),
    };

    const Running = struct {
        fn go(target: Object, source: std.Io.File, opts: types.ParallelUploadOptions) Error!void {
            var info = try target.uploadParallel(.{ .file = source }, opts);
            info.deinit();
        }
    };
    var task = try testing.io.concurrent(Running.go, .{ client.bucket("b").object("o"), file, options });
    // One worker holds part 2 at the gate; the other sends the rest.
    const deadline = std.Io.Clock.awake.now(testing.io).addDuration(.fromSeconds(10));
    while (true) {
        fake.mutex.lockUncancelable(testing.io);
        const sent = fake.counts.parts;
        fake.mutex.unlock(testing.io);
        if (sent >= 5) break;
        if (std.Io.Clock.awake.now(testing.io).nanoseconds > deadline.nanoseconds) @panic("the upload never sent the five parts not held back");
        try testing.io.sleep(.fromMilliseconds(1), .awake);
    }
    try testing.expectError(error.Canceled, task.cancel(testing.io));
    // The cancel aborted nothing: the parts and the state stay.
    try testing.expect(saved.stored != null);
    try testing.expectEqual(0, fake.counts.aborts);
    try testing.expectEqual(1, fake.openUploads());

    fake.faults = null;
    fake.gate.set(testing.io);
    var info = try client.bucket("b").object("o").uploadParallel(.{ .file = file }, options);
    defer info.deinit();
    try testing.expectEqualSlices(u8, &data, fake.object("o").?.bytes);
    try testing.expectEqual(5 + 1, fake.counts.parts);
    try testing.expectEqual(null, saved.stored);
}

test "uploadParallel: a checksum mismatch aborts and clears even with a checkpoint" {
    var s: Setup = undefined;
    try s.init(testing.io, .{});
    defer s.deinit();
    var data: [4 * 1024]u8 = undefined;
    fill(&data, 52);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try sourceOn(&tmp, &data);
    defer file.close(testing.io);
    var saved: MemoryCheckpoint = .{ .gpa = testing.allocator };
    defer saved.deinit();
    try testing.expectError(error.ChecksumMismatch, s.object("o").uploadParallel(.{ .file = file }, .{
        .part_size = 1024,
        .crc32c = core.crc32c.hash(&data) ^ 1,
        .checkpoint = saved.checkpoint(),
    }));
    // Resuming would only repeat the mismatch: nothing stays.
    try testing.expectEqual(1, s.fake.counts.aborts);
    try testing.expectEqual(0, s.fake.openUploads());
    try testing.expectEqual(null, saved.stored);
    try testing.expectEqual(1, saved.clears);
}

test "the upload checkpoint's state reaches neither the log nor the diagnostics" {
    logging.capture.reset();
    var fake: FakeMultipart = .init(testing.allocator, testing.io);
    fake.min_part_size = 1024;
    defer fake.deinit();
    var token: core.StaticToken = .{ .token = "ya29.t" };
    var data: [4 * 1024]u8 = undefined;
    fill(&data, 53);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try sourceOn(&tmp, &data);
    defer file.close(testing.io);
    var saved: MemoryCheckpoint = .{ .gpa = testing.allocator };
    defer saved.deinit();
    var diag: Diagnostics = .{};
    var client = try clientOn(&fake, &token, &diag, 4);
    defer client.deinit();
    const options: types.ParallelUploadOptions = .{
        .part_size = 1024,
        .concurrency = 1,
        .checkpoint = saved.checkpoint(),
    };

    var rules = [_]Script.Rule{.{ .kind = .part, .part = 2, .fault = .canceled }};
    var script: Script = .{ .rules = &rules };
    fake.faults = script.plan();
    try testing.expectError(error.Canceled, client.bucket("b").object("o").uploadParallel(.{ .file = file }, options));
    fake.faults = null;
    var info = try client.bucket("b").object("o").uploadParallel(.{ .file = file }, options);
    info.deinit();

    try testing.expect(logging.capture.lines > 0);
    try testing.expectEqual(null, std.mem.indexOf(u8, logging.capture.text(), "\"kind\""));
    try testing.expectEqual(null, std.mem.indexOf(u8, logging.capture.text(), "\"upload_id\""));
    try testing.expectEqual(null, std.mem.indexOf(u8, diag.message(), "\"kind\""));
}

fn uploadWithCheckpoint(gpa: Allocator) !void {
    var fake: FakeMultipart = .init(gpa, testing.io);
    fake.min_part_size = 1024;
    defer fake.deinit();
    var token: core.StaticToken = .{ .token = "ya29.t" };
    var client: Client = try .init(gpa, testing.io, .{
        .token_provider = token.provider(),
        .transport = fake.transport(),
    });
    defer client.deinit();
    client.multipart_test = .{ .min_part_size = 1024 };
    var data: [3000]u8 = undefined;
    fill(&data, 54);
    var saved: MemoryCheckpoint = .{ .gpa = gpa };
    defer saved.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try sourceOn(&tmp, &data);
    defer file.close(testing.io);
    // One worker, so the allocation count is the same on every pass.
    var info = try client.bucket("b").object("o").uploadParallel(.{ .file = file }, .{
        .part_size = 1024,
        .concurrency = 1,
        .checkpoint = saved.checkpoint(),
    });
    info.deinit();
}

test "uploadParallel with a checkpoint: every allocation failure is OutOfMemory, and nothing leaks" {
    try testing.checkAllAllocationFailures(testing.allocator, uploadWithCheckpoint, .{});
}

/// Lets every request through, recording each part number sent, so a
/// resume can prove it sent nothing the server already held.
const PartRecorder = struct {
    gpa: Allocator,
    numbers: std.ArrayList(u32) = .empty,

    fn deinit(self: *PartRecorder) void {
        self.numbers.deinit(self.gpa);
    }

    fn plan(self: *PartRecorder) FakeMultipart.FaultPlan {
        return .{ .ctx = self, .decide = decide };
    }

    fn decide(ctx: ?*anyopaque, kind: FakeMultipart.Kind, part: u32) FakeMultipart.Fault {
        const self: *PartRecorder = @ptrCast(@alignCast(ctx.?));
        if (kind == .part) self.numbers.append(self.gpa, part) catch @panic("out of memory recording a part");
        return .none;
    }
};

/// One upload under drawn faults, cut wherever they cut it, then a second
/// run with the same checkpoint and no faults: the object is exactly the
/// file, no part the server already held is sent again, and nothing but
/// an empty upload a lost start answer left behind stays to be billed.
fn resumeUnderFaults(input: []const u8) !void {
    var g: test_util.ByteGen = .init(input);
    const size = g.intRange(usize, 0, 40 * 1024);
    const part_size = g.intRange(u64, 1024, 12 * 1024);
    const concurrency = g.intRange(u16, 1, 4);
    const data = try testing.allocator.alloc(u8, size);
    defer testing.allocator.free(data);
    fill(data, g.int(u64));

    var fake: FakeMultipart = .init(testing.allocator, testing.io);
    fake.min_part_size = 1024;
    defer fake.deinit();
    var token: core.StaticToken = .{ .token = "ya29.t" };
    var saved: MemoryCheckpoint = .{ .gpa = testing.allocator };
    defer saved.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try sourceOn(&tmp, data);
    defer file.close(testing.io);
    const options: types.ParallelUploadOptions = .{
        .part_size = part_size,
        .concurrency = concurrency,
        .checkpoint = saved.checkpoint(),
    };

    var chooser: Chooser = .{ .bytes = g.rest() };
    fake.faults = chooser.plan();
    var first_diag: Diagnostics = .{};
    var first = try clientOn(&fake, &token, &first_diag, 2);
    defer first.deinit();
    if (first.bucket("b").object("o").uploadParallel(.{ .file = file }, options)) |finished| {
        var owned = finished;
        owned.deinit();
    } else |err| {
        errdefer std.debug.print("first run: {t}: {s}\n", .{ err, first_diag.message() });
        // Only a fault ends a first run.
        try testing.expect(chooser.faulted);
    }

    // What the state records, and which of its parts the server holds.
    var state_arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer state_arena.deinit();
    var held_numbers: std.ArrayList(u32) = .empty;
    defer held_numbers.deinit(testing.allocator);
    var resumable_upload = false;
    if (saved.stored) |bytes| {
        // Whatever the faults did, the state is one this library wrote.
        const state = try checkpoint.parse(state_arena.allocator(), bytes);
        const s = state.upload_parallel;
        try testing.expectEqualStrings("o", s.object);
        try testing.expectEqual(data.len, s.size);
        const plan = mp.plan(s.size, s.part_size);
        for (fake.uploads.items) |u| {
            if (!std.mem.eql(u8, u.id, s.upload_id)) continue;
            resumable_upload = true;
            for (u.parts.keys(), u.parts.values()) |number, part| {
                if (number >= 1 and number <= plan.parts and part.bytes.len == plan.len(number - 1)) {
                    try held_numbers.append(testing.allocator, number);
                }
            }
        }
    }

    var recorder: PartRecorder = .{ .gpa = testing.allocator };
    defer recorder.deinit();
    fake.faults = recorder.plan();
    var diag: Diagnostics = .{};
    var second = try clientOn(&fake, &token, &diag, 4);
    defer second.deinit();
    var info = second.bucket("b").object("o").uploadParallel(.{ .file = file }, options) catch |err| {
        std.debug.print("second run: {t}: {s}\n", .{ err, diag.message() });
        return err;
    };
    defer info.deinit();

    try testing.expectEqual(data.len, info.value.size);
    try testing.expectEqual(core.crc32c.hash(data), info.value.crc32c.?);
    try testing.expectEqualSlices(u8, data, fake.object("o").?.bytes);
    try testing.expectEqual(null, saved.stored);
    // A resume of a live upload sent no part the server already held.
    if (resumable_upload) {
        for (recorder.numbers.items) |sent| {
            for (held_numbers.items) |held| try testing.expect(sent != held);
        }
    }
    // Nothing to be billed stays behind, but for an empty upload a lost
    // start answer left, whose id never reached the client.
    try testing.expectEqual(0, fake.openParts());
}

fn resumeProperty(_: void, input: []const u8) !void {
    try resumeUnderFaults(input);
}

// About 9 ms a run in Debug, with two uploads over real threads and a real
// file: named out of the nightly's "fuzz" and "slow property" filters,
// like the other parallel fault properties, until a job of its own is
// sized for them.
test "fault property parallel upload resume: a second run completes the object, sending nothing the server holds" {
    try test_util.fuzzBytes({}, resumeProperty, .{
        .random_runs = 100,
        .max_len = 256,
        .corpus = &.{
            "",
            // 40 KiB in 1 KiB parts, 4 at once, a reset and a lost answer.
            "\xff\xff\xff\xff\xff\xff\xff\xff\x00\x00\x00\x00\x00\x00\x00\x00\x00\x03\x01\x00\x00\x00\x00\x00\x00\xdc\xe6",
            // A corrupted part, which aborts and clears, then a clean pair
            // of runs.
            "\x80\x00\x00\x00\x00\x00\x00\x00\x00\x10\x00\x00\x00\x00\x00\x00\x00\x02\x01\x00\x00\x00\x00\x00\x00\xf2",
        },
    });
}

test "uploadParallel over real sockets: an upload its connection keeps killing resumes on a second client" {
    // Four resets exhaust the first client's four attempts on one part:
    // that process is done, two parts up.
    var rules = [_]Script.Rule{.{ .kind = .part, .part = 3, .times = 4, .fault = .reset }};
    var script: Script = .{ .rules = &rules };
    var s: OverSockets = undefined;
    try s.init();
    defer s.deinit();
    s.fake.faults = script.plan();
    var data: [40 * 1024 + 5]u8 = undefined;
    fill(&data, 55);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try sourceOn(&tmp, &data);
    defer file.close(testing.io);
    var store: checkpoint.CheckpointFile = .init(testing.io, tmp.dir, "o.upload");
    const options: types.ParallelUploadOptions = .{
        .part_size = 8 * 1024,
        .concurrency = 1,
        .checkpoint = store.checkpoint(),
    };
    try testing.expectError(
        error.ConnectionResetByPeer,
        s.client.bucket("b").object("dir/o").uploadParallel(.{ .file = file }, options),
    );
    try testing.expectEqual(2, s.fake.counts.parts);
    try testing.expectEqual(1, s.fake.openUploads());

    // A second client, over connections of its own, finishes the upload.
    var url_buf: [64]u8 = undefined;
    var diag: Diagnostics = .{};
    var second: Client = try .init(testing.allocator, testing.io, .{
        .endpoint = .{ .url = s.server.url(&url_buf), .emulator = true },
        .diagnostics = &diag,
        .retry = .{ .max_attempts = 4, .initial_backoff_ms = 1, .max_backoff_ms = 2 },
    });
    defer second.deinit();
    second.multipart_test = .{ .min_part_size = 1024, .on_emulator = true };
    var info = try second.bucket("b").object("dir/o").uploadParallel(.{ .file = file }, options);
    defer info.deinit();
    try testing.expectEqual(data.len, info.value.size);
    try testing.expectEqualSlices(u8, &data, s.fake.object("dir/o").?.bytes);
    // The four missing parts and nothing more, and the state is gone.
    try testing.expectEqual(2 + 4, s.fake.counts.parts);
    try testing.expectEqual(1, s.fake.counts.lists);
    try testing.expectEqual(1, s.fake.counts.starts);
    try testing.expectEqual(0, s.fake.openUploads());
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(testing.io, "o.upload", .{}));
}

test "uploadParallel: a checkpoint of another transfer, or one unreadable, is refused before anything is sent and kept" {
    var s: Setup = undefined;
    try s.init(testing.io, .{});
    defer s.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try sourceOn(&tmp, "the file's bytes");
    defer file.close(testing.io);

    // A download's state: not this transfer's, whatever its names say.
    const download_state = try checkpoint.encodeAlloc(testing.allocator, .{ .download_parallel = .{
        .bucket = "b",
        .object = "o",
        .size = 5000,
        .generation = 42,
        .part_size = 1024,
        .written = "50",
    } });
    var wrong_kind: MemoryCheckpoint = .{ .gpa = testing.allocator, .stored = download_state };
    defer wrong_kind.deinit();
    try testing.expectError(error.CheckpointFailed, s.object("o").uploadParallel(.{ .file = file }, .{
        .part_size = 1024,
        .checkpoint = wrong_kind.checkpoint(),
    }));
    try testing.expect(std.mem.indexOf(u8, s.diag.message(), "not a parallel upload") != null);
    try testing.expectEqualStrings(download_state, wrong_kind.stored.?);

    // An upload state for another object.
    const foreign = try checkpoint.encodeAlloc(testing.allocator, .{ .upload_parallel = .{
        .bucket = "b",
        .object = "someone-elses",
        .size = 5000,
        .mtime = 1,
        .upload_id = "u",
        .part_size = 1024,
        .temp = null,
        .if_generation_match = null,
        .if_generation_not_match = null,
        .if_metageneration_match = null,
        .if_metageneration_not_match = null,
    } });
    var other: MemoryCheckpoint = .{ .gpa = testing.allocator, .stored = foreign };
    defer other.deinit();
    try testing.expectError(error.CheckpointFailed, s.object("o").uploadParallel(.{ .file = file }, .{
        .part_size = 1024,
        .checkpoint = other.checkpoint(),
    }));
    try testing.expect(std.mem.indexOf(u8, s.diag.message(), "belongs to another transfer") != null);
    try testing.expectEqualStrings(foreign, other.stored.?);

    // Bytes that are no state at all.
    var garbage: MemoryCheckpoint = .{ .gpa = testing.allocator, .stored = try testing.allocator.dupe(u8, "gsutil tracker?") };
    defer garbage.deinit();
    try testing.expectError(error.CheckpointFailed, s.object("o").uploadParallel(.{ .file = file }, .{
        .part_size = 1024,
        .checkpoint = garbage.checkpoint(),
    }));

    // None of it reached the server, and nothing was aborted.
    try testing.expectEqual(0, s.fake.counts.starts);
    try testing.expectEqual(0, s.fake.counts.lists);
    try testing.expectEqual(0, s.fake.counts.aborts);
}

test "uploadParallel: an emulator's ordinary upload ignores the checkpoint" {
    var fake: test_util.FakeTransport = .init(testing.allocator, &.{
        // The ordinary upload's resumable session, opened and finished.
        .{ .respond = .{ .body = "", .headers = &.{.{ .name = "Location", .value = "http://localhost:4443/session/1" }} } },
        .{ .respond = .{ .body = "{\"name\":\"o\",\"bucket\":\"b\",\"size\":\"16\",\"generation\":\"1\"}" } },
    });
    defer fake.deinit();
    var client: Client = try .init(testing.allocator, testing.io, .{
        .endpoint = .{ .url = "localhost:4443", .emulator = true },
        .transport = fake.transport(),
    });
    defer client.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try sourceOn(&tmp, "the file's bytes");
    defer file.close(testing.io);
    var saved: MemoryCheckpoint = .{ .gpa = testing.allocator };
    defer saved.deinit();
    var info = try client.bucket("b").object("o").uploadParallel(.{ .file = file }, .{
        .checkpoint = saved.checkpoint(),
    });
    defer info.deinit();
    // One ordinary upload, which cannot resume: the checkpoint was never
    // touched.
    try testing.expectEqual(0, saved.loads);
    try testing.expectEqual(0, saved.saves);
    try testing.expectEqual(0, saved.clears);
}
