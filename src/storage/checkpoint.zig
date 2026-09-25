//! Where a transfer keeps the little a later process needs to carry it on:
//! the `Checkpoint` interface, its built-in file store, and the saved
//! state's encoding.
//!
//! The state is compact JSON with a version number. It is readable for
//! debugging, but it is not an API: a caller stores the bytes and hands
//! them back. Only the canonical encoding parses, so every state either
//! came from this library or is refused whole. Nothing about the data is
//! taken from it: a resume re-reads locally whatever the earlier run moved,
//! which rebuilds the checksums and catches a file that changed between
//! runs.
//!
//! An upload's state can hold a resumable session URL, which lets anyone
//! holding it write that object for up to a week. So the built-in file is
//! readable by its owner only, a custom store should keep the state as it
//! keeps credentials, and nothing here is ever logged.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const mp = @import("xml_multipart.zig");

/// Where a transfer keeps its state between processes. `CheckpointFile` is
/// the built-in implementation; a caller who keeps state elsewhere, a
/// database say, implements the three functions.
pub const Checkpoint = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const Error = error{ CheckpointFailed, OutOfMemory, Canceled };

    pub const VTable = struct {
        /// What an earlier run saved, or null when there is nothing. The
        /// bytes live in `arena`.
        load: *const fn (ptr: *anyopaque, arena: Allocator) Error!?[]const u8,
        /// Replaces what is saved, whole. Never called by two tasks at
        /// once.
        save: *const fn (ptr: *anyopaque, state: []const u8) Error!void,
        /// The transfer finished, or can no longer be resumed.
        clear: *const fn (ptr: *anyopaque) void,
    };

    pub fn load(self: Checkpoint, arena: Allocator) Error!?[]const u8 {
        return self.vtable.load(self.ptr, arena);
    }

    pub fn save(self: Checkpoint, state: []const u8) Error!void {
        return self.vtable.save(self.ptr, state);
    }

    pub fn clear(self: Checkpoint) void {
        self.vtable.clear(self.ptr);
    }
};

/// A state larger than this could not have been written here, and is
/// refused unread.
pub const max_state_len: usize = 64 * 1024;

/// With a checkpoint, which upload failures still clean up on the server
/// and clear the state: those a resume could only repeat. Everything
/// else, cancels and exhausted retries included, leaves the session or
/// parts and the checkpoint for a later process.
pub fn uploadAbandons(err: @import("errors.zig").Error) bool {
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

/// A checkpoint kept in one file: replaced atomically, so a crash mid-save
/// leaves the old state and never half of a new one, and readable by its
/// owner only where the system can say so. The directory and path are
/// borrowed, not owned.
pub const CheckpointFile = struct {
    io: std.Io,
    dir: std.Io.Dir,
    sub_path: []const u8,

    pub fn init(io: std.Io, dir: std.Io.Dir, sub_path: []const u8) CheckpointFile {
        return .{ .io = io, .dir = dir, .sub_path = sub_path };
    }

    pub fn checkpoint(self: *CheckpointFile) Checkpoint {
        return .{ .ptr = self, .vtable = &.{ .load = load, .save = save, .clear = clear } };
    }

    fn load(ptr: *anyopaque, arena: Allocator) Checkpoint.Error!?[]const u8 {
        const self: *CheckpointFile = @ptrCast(@alignCast(ptr));
        return self.dir.readFileAlloc(self.io, self.sub_path, arena, .limited(max_state_len)) catch |err| switch (err) {
            error.FileNotFound => null,
            error.OutOfMemory => error.OutOfMemory,
            error.Canceled => error.Canceled,
            else => error.CheckpointFailed,
        };
    }

    /// The state a session URL may sit in is no one else's to read.
    const owner_only: std.Io.File.Permissions = if (@hasDecl(std.Io.File.Permissions, "fromMode"))
        .fromMode(0o600)
    else
        .default_file;

    fn save(ptr: *anyopaque, state: []const u8) Checkpoint.Error!void {
        const self: *CheckpointFile = @ptrCast(@alignCast(ptr));
        var atomic = self.dir.createFileAtomic(self.io, self.sub_path, .{
            .permissions = owner_only,
            .replace = true,
        }) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => return error.CheckpointFailed,
        };
        defer atomic.deinit(self.io);
        var buffer: [1024]u8 = undefined;
        var writer = atomic.file.writer(self.io, &buffer);
        writer.interface.writeAll(state) catch return writeFailed(&writer);
        writer.interface.flush() catch return writeFailed(&writer);
        atomic.replace(self.io) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => return error.CheckpointFailed,
        };
    }

    /// A cancel that landed in the write stays a cancel; anything else
    /// about the file is the one opaque failure.
    fn writeFailed(writer: *const std.Io.File.Writer) Checkpoint.Error {
        if (writer.err) |err| if (err == error.Canceled) return error.Canceled;
        return error.CheckpointFailed;
    }

    fn clear(ptr: *anyopaque) void {
        const self: *CheckpointFile = @ptrCast(@alignCast(ptr));
        self.dir.deleteFile(self.io, self.sub_path) catch {};
    }
};

/// What a transfer saves, by kind. The slices are borrowed.
pub const State = union(enum) {
    download_parallel: DownloadParallel,
    upload_file: UploadFile,
    upload_parallel: UploadParallel,

    pub const DownloadParallel = struct {
        bucket: []const u8,
        object: []const u8,
        /// The object's size at `generation`, which fixes the range plan.
        size: u64,
        /// Every written range is pinned to this generation.
        generation: u64,
        /// The plan's own part size, so re-planning reproduces the ranges.
        part_size: u64,
        /// Which ranges the file holds, as hex digits: four ranges per
        /// digit, range `4j` the low bit of digit `j`, exactly
        /// `digitsFor(parts)` digits. At most 2,500 at the 10,000-range
        /// limit.
        written: []const u8,
    };

    pub const UploadFile = struct {
        bucket: []const u8,
        object: []const u8,
        /// The source file's size and modification time. A file that
        /// changed cannot resume: the bytes the session holds are not its.
        size: u64,
        mtime: i128,
        /// The session URL, which is a credential: anyone holding it can
        /// write the object for up to a week. Never logged.
        session: []const u8,
    };

    pub const UploadParallel = struct {
        bucket: []const u8,
        /// The name the object is to have; a conditional upload's parts go
        /// up under `temp` until the move.
        object: []const u8,
        /// The source file's size and modification time. A file that
        /// changed cannot resume: the parts already sent hold other bytes.
        size: u64,
        mtime: i128,
        upload_id: []const u8,
        /// The plan's own part size, so re-planning reproduces the parts.
        part_size: u64,
        /// The temporary name of an upload with conditions, or null. Which
        /// parts the server holds is the server's to say, through
        /// ListParts, so nothing more is saved.
        temp: ?[]const u8,
        if_generation_match: ?u64,
        if_generation_not_match: ?u64,
        if_metageneration_match: ?u64,
        if_metageneration_not_match: ?u64,
    };
};

/// The state's canonical bytes, which are the only bytes `parse` accepts.
pub fn encodeAlloc(gpa: Allocator, state: State) Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    var jw: std.json.Stringify = .{ .writer = &out.writer, .options = .{ .emit_null_optional_fields = false } };
    switch (state) {
        .download_parallel => |s| jw.write(.{
            .version = 1,
            .kind = "downloadParallel",
            .bucket = s.bucket,
            .object = s.object,
            .size = s.size,
            .generation = s.generation,
            .part_size = s.part_size,
            .written = s.written,
        }) catch return error.OutOfMemory,
        .upload_file => |s| jw.write(.{
            .version = 1,
            .kind = "uploadFile",
            .bucket = s.bucket,
            .object = s.object,
            .size = s.size,
            .mtime = s.mtime,
            .session = s.session,
        }) catch return error.OutOfMemory,
        .upload_parallel => |s| jw.write(.{
            .version = 1,
            .kind = "uploadParallel",
            .bucket = s.bucket,
            .object = s.object,
            .size = s.size,
            .mtime = s.mtime,
            .upload_id = s.upload_id,
            .part_size = s.part_size,
            .temp = s.temp,
            .if_generation_match = s.if_generation_match,
            .if_generation_not_match = s.if_generation_not_match,
            .if_metageneration_match = s.if_metageneration_match,
            .if_metageneration_not_match = s.if_metageneration_not_match,
        }) catch return error.OutOfMemory,
    }
    return out.toOwnedSlice();
}

/// Reads a state back. Everything else is `error.CheckpointFailed`: bytes
/// this library did not write, a version or kind it does not know, or
/// fields no transfer could have saved. The returned slices point into
/// `arena` or `bytes`.
pub fn parse(arena: Allocator, bytes: []const u8) error{ CheckpointFailed, OutOfMemory }!State {
    const Wire = struct {
        version: u64,
        kind: []const u8,
        bucket: []const u8,
        object: []const u8,
        size: u64,
        generation: ?u64 = null,
        part_size: ?u64 = null,
        written: ?[]const u8 = null,
        mtime: ?i128 = null,
        session: ?[]const u8 = null,
        upload_id: ?[]const u8 = null,
        temp: ?[]const u8 = null,
        if_generation_match: ?u64 = null,
        if_generation_not_match: ?u64 = null,
        if_metageneration_match: ?u64 = null,
        if_metageneration_not_match: ?u64 = null,
    };
    const wire = std.json.parseFromSliceLeaky(Wire, arena, bytes, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.CheckpointFailed,
    };
    if (wire.version != 1) return error.CheckpointFailed;
    if (wire.size > mp.max_object_size) return error.CheckpointFailed;
    // Where a state names a part size, the plan must reproduce exactly the
    // pieces the earlier run saved: a part size `plan` would grow named a
    // plan that never was.
    const plan: ?mp.Plan = if (wire.part_size) |part_size| p: {
        if (part_size == 0) return error.CheckpointFailed;
        const plan = mp.plan(wire.size, part_size);
        if (plan.part_size != part_size) return error.CheckpointFailed;
        break :p plan;
    } else null;

    const state: State = if (std.mem.eql(u8, wire.kind, "downloadParallel")) blk: {
        const generation = wire.generation orelse return error.CheckpointFailed;
        const written = wire.written orelse return error.CheckpointFailed;
        const ranges = plan orelse return error.CheckpointFailed;
        if (generation == 0) return error.CheckpointFailed;
        // An empty object downloads as no ranges at all, where an upload's
        // plan would call it one empty part.
        try checkWritten(written, if (wire.size == 0) 0 else ranges.parts);
        break :blk .{ .download_parallel = .{
            .bucket = wire.bucket,
            .object = wire.object,
            .size = wire.size,
            .generation = generation,
            .part_size = ranges.part_size,
            .written = written,
        } };
    } else if (std.mem.eql(u8, wire.kind, "uploadFile")) blk: {
        const mtime = wire.mtime orelse return error.CheckpointFailed;
        const session = wire.session orelse return error.CheckpointFailed;
        if (session.len == 0) return error.CheckpointFailed;
        break :blk .{ .upload_file = .{
            .bucket = wire.bucket,
            .object = wire.object,
            .size = wire.size,
            .mtime = mtime,
            .session = session,
        } };
    } else if (std.mem.eql(u8, wire.kind, "uploadParallel")) blk: {
        const mtime = wire.mtime orelse return error.CheckpointFailed;
        const upload_id = wire.upload_id orelse return error.CheckpointFailed;
        const parts = plan orelse return error.CheckpointFailed;
        if (upload_id.len == 0) return error.CheckpointFailed;
        if (wire.temp) |temp| if (temp.len == 0) return error.CheckpointFailed;
        // A temporary name exists exactly when the upload has conditions
        // to move under.
        const has_condition = wire.if_generation_match != null or wire.if_generation_not_match != null or
            wire.if_metageneration_match != null or wire.if_metageneration_not_match != null;
        if ((wire.temp != null) != has_condition) return error.CheckpointFailed;
        break :blk .{ .upload_parallel = .{
            .bucket = wire.bucket,
            .object = wire.object,
            .size = wire.size,
            .mtime = mtime,
            .upload_id = upload_id,
            .part_size = parts.part_size,
            .temp = wire.temp,
            .if_generation_match = wire.if_generation_match,
            .if_generation_not_match = wire.if_generation_not_match,
            .if_metageneration_match = wire.if_metageneration_match,
            .if_metageneration_not_match = wire.if_metageneration_not_match,
        } };
    } else return error.CheckpointFailed;

    // Only the canonical encoding is a state. This also refuses what the
    // field checks cannot see: reordered keys, whitespace, escape
    // variants, numbers written another way, fields of the other kind.
    const canonical = try encodeAlloc(arena, state);
    if (!std.mem.eql(u8, canonical, bytes)) return error.CheckpointFailed;
    return state;
}

/// How many hex digits describe `parts` ranges.
pub fn digitsFor(parts: u32) u32 {
    return (parts + 3) / 4;
}

fn hexValue(c: u8) ?u4 {
    return switch (c) {
        '0'...'9' => @intCast(c - '0'),
        'a'...'f' => @intCast(c - 'a' + 10),
        else => null,
    };
}

/// Holds `written` to its rules: lowercase hex, exactly `digitsFor(parts)`
/// digits, and no bit for a range past the last.
fn checkWritten(written: []const u8, parts: u32) error{CheckpointFailed}!void {
    if (written.len != digitsFor(parts)) return error.CheckpointFailed;
    for (written, 0..) |c, j| {
        const value = hexValue(c) orelse return error.CheckpointFailed;
        const first: u32 = @intCast(4 * j);
        const beyond = parts - first;
        if (beyond < 4 and (value >> @intCast(beyond)) != 0) return error.CheckpointFailed;
    }
}

/// Renders `bits`, one per range, into `out`, which is `digitsFor(parts)`
/// long.
pub fn hexFromBits(bits: *const std.DynamicBitSetUnmanaged, parts: u32, out: []u8) void {
    std.debug.assert(out.len == digitsFor(parts));
    for (out, 0..) |*c, j| {
        var value: u4 = 0;
        const first = 4 * j;
        var k: usize = 0;
        while (k < 4 and first + k < parts) : (k += 1) {
            if (bits.isSet(first + k)) value |= @as(u4, 1) << @intCast(k);
        }
        c.* = "0123456789abcdef"[value];
    }
}

/// The bit set behind a state's `written`, which `parse` already held to
/// its rules.
pub fn bitsFromHex(gpa: Allocator, written: []const u8, parts: u32) Allocator.Error!std.DynamicBitSetUnmanaged {
    std.debug.assert(written.len == digitsFor(parts));
    var bits: std.DynamicBitSetUnmanaged = try .initEmpty(gpa, parts);
    errdefer bits.deinit(gpa);
    for (written, 0..) |c, j| {
        const value = hexValue(c).?;
        for (0..4) |k| {
            if ((value >> @intCast(k)) & 1 != 0) bits.set(4 * j + k);
        }
    }
    return bits;
}

const testing = std.testing;

fn exampleState() State {
    return .{ .download_parallel = .{
        .bucket = "b",
        .object = "dir/o",
        .size = 5000,
        .generation = 42,
        .part_size = 1024,
        .written = "50",
    } };
}

test "state: the canonical encoding, pinned byte for byte" {
    const encoded = try encodeAlloc(testing.allocator, exampleState());
    defer testing.allocator.free(encoded);
    try testing.expectEqualStrings(
        "{\"version\":1,\"kind\":\"downloadParallel\",\"bucket\":\"b\",\"object\":\"dir/o\"," ++
            "\"size\":5000,\"generation\":42,\"part_size\":1024,\"written\":\"50\"}",
        encoded,
    );
}

test "state: encode and parse round-trip, escapes and edges included" {
    const states = [_]State{
        exampleState(),
        // A name with a quote, a backslash and a control character, all of
        // which the encoding escapes.
        .{ .download_parallel = .{
            .bucket = "bucket-name",
            .object = "a \"b\"\\c\x01",
            .size = 1,
            .generation = std.math.maxInt(u64),
            .part_size = std.math.maxInt(u64),
            .written = "1",
        } },
        // An empty object has no ranges and no digits.
        .{ .download_parallel = .{
            .bucket = "b",
            .object = "empty",
            .size = 0,
            .generation = 7,
            .part_size = 1024 * 1024,
            .written = "",
        } },
        // The largest object at the 10,000-range limit: 2,500 digits.
        .{ .download_parallel = .{
            .bucket = "b",
            .object = "big",
            .size = mp.max_object_size,
            .generation = 1,
            .part_size = 549_755_814,
            .written = "f" ** 2_500,
        } },
    };
    for (states) |state| {
        var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const encoded = try encodeAlloc(arena, state);
        const back = try parse(arena, encoded);
        const want = state.download_parallel;
        const got = back.download_parallel;
        try testing.expectEqualStrings(want.bucket, got.bucket);
        try testing.expectEqualStrings(want.object, got.object);
        try testing.expectEqual(want.size, got.size);
        try testing.expectEqual(want.generation, got.generation);
        try testing.expectEqual(want.part_size, got.part_size);
        try testing.expectEqualStrings(want.written, got.written);
    }
}

test "state: everything that is not a canonical state is CheckpointFailed" {
    const good = "{\"version\":1,\"kind\":\"downloadParallel\",\"bucket\":\"b\",\"object\":\"dir/o\"," ++
        "\"size\":5000,\"generation\":42,\"part_size\":1024,\"written\":\"50\"}";
    const refused = [_][]const u8{
        "",
        "not json",
        "{}",
        // A trailing space, and a reordered pair: valid JSON, not canonical.
        good ++ " ",
        "{\"kind\":\"downloadParallel\",\"version\":1,\"bucket\":\"b\",\"object\":\"dir/o\",\"size\":5000,\"generation\":42,\"part_size\":1024,\"written\":\"50\"}",
        // An escape variant of the same state.
        "{\"version\":1,\"kind\":\"downloadParallel\",\"bucket\":\"\\u0062\",\"object\":\"dir/o\",\"size\":5000,\"generation\":42,\"part_size\":1024,\"written\":\"50\"}",
        // A version or kind this library does not know.
        "{\"version\":2,\"kind\":\"downloadParallel\",\"bucket\":\"b\",\"object\":\"dir/o\",\"size\":5000,\"generation\":42,\"part_size\":1024,\"written\":\"50\"}",
        "{\"version\":1,\"kind\":\"uploadSideways\",\"bucket\":\"b\",\"object\":\"dir/o\",\"size\":5000,\"generation\":42,\"part_size\":1024,\"written\":\"50\"}",
        // A field beyond the schema, and one missing.
        "{\"version\":1,\"kind\":\"downloadParallel\",\"bucket\":\"b\",\"object\":\"dir/o\",\"size\":5000,\"generation\":42,\"part_size\":1024,\"written\":\"50\",\"extra\":1}",
        "{\"version\":1,\"kind\":\"downloadParallel\",\"bucket\":\"b\",\"object\":\"dir/o\",\"size\":5000,\"generation\":42,\"part_size\":1024}",
        // Values no transfer could have saved: generation 0, part size 0,
        // a size past 5 TiB, a part size the plan would have grown.
        "{\"version\":1,\"kind\":\"downloadParallel\",\"bucket\":\"b\",\"object\":\"dir/o\",\"size\":5000,\"generation\":0,\"part_size\":1024,\"written\":\"50\"}",
        "{\"version\":1,\"kind\":\"downloadParallel\",\"bucket\":\"b\",\"object\":\"dir/o\",\"size\":5000,\"generation\":42,\"part_size\":0,\"written\":\"50\"}",
        "{\"version\":1,\"kind\":\"downloadParallel\",\"bucket\":\"b\",\"object\":\"dir/o\",\"size\":5497558138881,\"generation\":42,\"part_size\":1024,\"written\":\"50\"}",
        "{\"version\":1,\"kind\":\"downloadParallel\",\"bucket\":\"b\",\"object\":\"dir/o\",\"size\":50000000,\"generation\":42,\"part_size\":1024,\"written\":\"50\"}",
        // A bitmap of the wrong length, with an uppercase digit, or with a
        // bit for a range past the last (5000/1024 is five ranges).
        "{\"version\":1,\"kind\":\"downloadParallel\",\"bucket\":\"b\",\"object\":\"dir/o\",\"size\":5000,\"generation\":42,\"part_size\":1024,\"written\":\"500\"}",
        "{\"version\":1,\"kind\":\"downloadParallel\",\"bucket\":\"b\",\"object\":\"dir/o\",\"size\":5000,\"generation\":42,\"part_size\":1024,\"written\":\"5A\"}",
        "{\"version\":1,\"kind\":\"downloadParallel\",\"bucket\":\"b\",\"object\":\"dir/o\",\"size\":5000,\"generation\":42,\"part_size\":1024,\"written\":\"52\"}",
    };
    for (refused) |bytes| {
        var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena_state.deinit();
        try testing.expectError(error.CheckpointFailed, parse(arena_state.allocator(), bytes));
    }
    // And the state they vary from parses.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    _ = try parse(arena_state.allocator(), good);
}

test "uploadFile state: the canonical encoding, round trip, and what is refused" {
    const state: State = .{ .upload_file = .{
        .bucket = "b",
        .object = "backups/db.tar",
        .size = 123_456_789,
        .mtime = 1_758_700_000_123_456_789,
        .session = "https://storage.googleapis.com/upload/storage/v1/b/b/o?uploadType=resumable&upload_id=SECRET",
    } };
    const encoded = try encodeAlloc(testing.allocator, state);
    defer testing.allocator.free(encoded);
    try testing.expectEqualStrings(
        "{\"version\":1,\"kind\":\"uploadFile\",\"bucket\":\"b\",\"object\":\"backups/db.tar\"," ++
            "\"size\":123456789,\"mtime\":1758700000123456789," ++
            "\"session\":\"https://storage.googleapis.com/upload/storage/v1/b/b/o?uploadType=resumable&upload_id=SECRET\"}",
        encoded,
    );
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const back = try parse(arena_state.allocator(), encoded);
    try testing.expectEqualStrings(state.upload_file.session, back.upload_file.session);
    try testing.expectEqual(state.upload_file.mtime, back.upload_file.mtime);

    const refused = [_][]const u8{
        // Missing what an uploadFile state must have, or an empty session.
        "{\"version\":1,\"kind\":\"uploadFile\",\"bucket\":\"b\",\"object\":\"o\",\"size\":1,\"session\":\"s\"}",
        "{\"version\":1,\"kind\":\"uploadFile\",\"bucket\":\"b\",\"object\":\"o\",\"size\":1,\"mtime\":1}",
        "{\"version\":1,\"kind\":\"uploadFile\",\"bucket\":\"b\",\"object\":\"o\",\"size\":1,\"mtime\":1,\"session\":\"\"}",
        // Another kind's fields alongside.
        "{\"version\":1,\"kind\":\"uploadFile\",\"bucket\":\"b\",\"object\":\"o\",\"size\":1,\"mtime\":1,\"session\":\"s\",\"part_size\":1024}",
    };
    for (refused) |bytes| {
        var arena2: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena2.deinit();
        try testing.expectError(error.CheckpointFailed, parse(arena2.allocator(), bytes));
    }
}

test "upload state: the canonical encoding, both shapes, pinned byte for byte" {
    const plain: State = .{ .upload_parallel = .{
        .bucket = "b",
        .object = "dir/o",
        .size = 5000,
        .mtime = 1_758_700_000_123_456_789,
        .upload_id = "VXBs+1=",
        .part_size = 1024,
        .temp = null,
        .if_generation_match = null,
        .if_generation_not_match = null,
        .if_metageneration_match = null,
        .if_metageneration_not_match = null,
    } };
    const encoded = try encodeAlloc(testing.allocator, plain);
    defer testing.allocator.free(encoded);
    try testing.expectEqualStrings(
        "{\"version\":1,\"kind\":\"uploadParallel\",\"bucket\":\"b\",\"object\":\"dir/o\"," ++
            "\"size\":5000,\"mtime\":1758700000123456789,\"upload_id\":\"VXBs+1=\",\"part_size\":1024}",
        encoded,
    );

    var conditional = plain;
    conditional.upload_parallel.temp = "zig-gcp-tmp/0011";
    conditional.upload_parallel.if_generation_match = 0;
    const with_temp = try encodeAlloc(testing.allocator, conditional);
    defer testing.allocator.free(with_temp);
    try testing.expectEqualStrings(
        "{\"version\":1,\"kind\":\"uploadParallel\",\"bucket\":\"b\",\"object\":\"dir/o\"," ++
            "\"size\":5000,\"mtime\":1758700000123456789,\"upload_id\":\"VXBs+1=\",\"part_size\":1024," ++
            "\"temp\":\"zig-gcp-tmp/0011\",\"if_generation_match\":0}",
        with_temp,
    );

    // Both round-trip, negative mtime included: filesystems can be odd.
    var negative = conditional;
    negative.upload_parallel.mtime = -1;
    negative.upload_parallel.if_generation_match = null;
    negative.upload_parallel.if_metageneration_not_match = 7;
    for ([_]State{ plain, conditional, negative }) |state| {
        var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const bytes = try encodeAlloc(arena, state);
        const back = try parse(arena, bytes);
        const want = state.upload_parallel;
        const got = back.upload_parallel;
        try testing.expectEqualStrings(want.upload_id, got.upload_id);
        try testing.expectEqual(want.mtime, got.mtime);
        try testing.expectEqual(want.size, got.size);
        try testing.expectEqual(want.if_generation_match, got.if_generation_match);
        try testing.expectEqual(want.if_metageneration_not_match, got.if_metageneration_not_match);
        try testing.expectEqual(want.temp == null, got.temp == null);
        if (want.temp) |temp| try testing.expectEqualStrings(temp, got.temp.?);
    }
}

test "upload state: everything that is not a canonical upload state is CheckpointFailed" {
    const good = "{\"version\":1,\"kind\":\"uploadParallel\",\"bucket\":\"b\",\"object\":\"dir/o\"," ++
        "\"size\":5000,\"mtime\":1758700000123456789,\"upload_id\":\"VXBs+1=\",\"part_size\":1024}";
    const refused = [_][]const u8{
        // A download's fields on an upload state, and the other way round.
        "{\"version\":1,\"kind\":\"uploadParallel\",\"bucket\":\"b\",\"object\":\"dir/o\",\"size\":5000,\"mtime\":1,\"upload_id\":\"u\",\"part_size\":1024,\"written\":\"50\"}",
        "{\"version\":1,\"kind\":\"downloadParallel\",\"bucket\":\"b\",\"object\":\"dir/o\",\"size\":5000,\"generation\":42,\"part_size\":1024,\"written\":\"50\",\"mtime\":1}",
        // Missing what an upload must have.
        "{\"version\":1,\"kind\":\"uploadParallel\",\"bucket\":\"b\",\"object\":\"dir/o\",\"size\":5000,\"upload_id\":\"u\",\"part_size\":1024}",
        "{\"version\":1,\"kind\":\"uploadParallel\",\"bucket\":\"b\",\"object\":\"dir/o\",\"size\":5000,\"mtime\":1,\"part_size\":1024}",
        "{\"version\":1,\"kind\":\"uploadParallel\",\"bucket\":\"b\",\"object\":\"dir/o\",\"size\":5000,\"mtime\":1,\"upload_id\":\"\",\"part_size\":1024}",
        // A temporary name without conditions, conditions without one, and
        // an empty one.
        "{\"version\":1,\"kind\":\"uploadParallel\",\"bucket\":\"b\",\"object\":\"dir/o\",\"size\":5000,\"mtime\":1,\"upload_id\":\"u\",\"part_size\":1024,\"temp\":\"zig-gcp-tmp/aa\"}",
        "{\"version\":1,\"kind\":\"uploadParallel\",\"bucket\":\"b\",\"object\":\"dir/o\",\"size\":5000,\"mtime\":1,\"upload_id\":\"u\",\"part_size\":1024,\"if_generation_match\":0}",
        "{\"version\":1,\"kind\":\"uploadParallel\",\"bucket\":\"b\",\"object\":\"dir/o\",\"size\":5000,\"mtime\":1,\"upload_id\":\"u\",\"part_size\":1024,\"temp\":\"\",\"if_generation_match\":0}",
        // A part size the plan would have grown.
        "{\"version\":1,\"kind\":\"uploadParallel\",\"bucket\":\"b\",\"object\":\"dir/o\",\"size\":50000000,\"mtime\":1,\"upload_id\":\"u\",\"part_size\":1024}",
    };
    for (refused) |bytes| {
        var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena_state.deinit();
        try testing.expectError(error.CheckpointFailed, parse(arena_state.allocator(), bytes));
    }
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    _ = try parse(arena_state.allocator(), good);
}

test "bitmap: bits to hex and back, at every width mod 4" {
    for ([_]u32{ 1, 2, 3, 4, 5, 7, 8, 9, 100 }) |parts| {
        var bits: std.DynamicBitSetUnmanaged = try .initEmpty(testing.allocator, parts);
        defer bits.deinit(testing.allocator);
        // Every third range, and always the last.
        var i: u32 = 0;
        while (i < parts) : (i += 3) bits.set(i);
        bits.set(parts - 1);
        const hex = try testing.allocator.alloc(u8, digitsFor(parts));
        defer testing.allocator.free(hex);
        hexFromBits(&bits, parts, hex);
        try checkWritten(hex, parts);
        var back = try bitsFromHex(testing.allocator, hex, parts);
        defer back.deinit(testing.allocator);
        i = 0;
        while (i < parts) : (i += 1) try testing.expectEqual(bits.isSet(i), back.isSet(i));
    }

    // The digit order is little-endian in ranges: range 0 is the low bit
    // of the first digit.
    var bits: std.DynamicBitSetUnmanaged = try .initEmpty(testing.allocator, 6);
    defer bits.deinit(testing.allocator);
    bits.set(0);
    bits.set(5);
    var hex: [2]u8 = undefined;
    hexFromBits(&bits, 6, &hex);
    try testing.expectEqualStrings("12", &hex);
}

fn parseProperty(_: void, input: []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const state = parse(arena, input) catch |err| switch (err) {
        error.CheckpointFailed => return,
        error.OutOfMemory => return err,
    };
    // Parsed means canonical: the state re-encodes to its own input, and
    // its pieces hold together well enough to resume with.
    const encoded = try encodeAlloc(arena, state);
    try testing.expectEqualSlices(u8, input, encoded);
    switch (state) {
        .download_parallel => |s| {
            const plan = mp.plan(s.size, s.part_size);
            try testing.expectEqual(s.part_size, plan.part_size);
            const parts: u32 = if (s.size == 0) 0 else plan.parts;
            var bits = try bitsFromHex(testing.allocator, s.written, parts);
            defer bits.deinit(testing.allocator);
            try testing.expect(bits.count() <= parts);
        },
        .upload_file => |s| {
            try testing.expect(s.session.len > 0);
        },
        .upload_parallel => |s| {
            try testing.expectEqual(s.part_size, mp.plan(s.size, s.part_size).part_size);
            try testing.expect(s.upload_id.len > 0);
            if (s.temp) |temp| try testing.expect(temp.len > 0);
        },
    }
}

test "fuzz checkpoint state: every input parses to a state that re-encodes to itself, or fails" {
    const test_util = @import("test_util.zig");
    try test_util.fuzzBytes({}, parseProperty, .{ .corpus = &.{
        "{\"version\":1,\"kind\":\"downloadParallel\",\"bucket\":\"b\",\"object\":\"dir/o\",\"size\":5000,\"generation\":42,\"part_size\":1024,\"written\":\"50\"}",
        "{\"version\":1,\"kind\":\"downloadParallel\",\"bucket\":\"b\",\"object\":\"empty\",\"size\":0,\"generation\":7,\"part_size\":1048576,\"written\":\"\"}",
        "{\"version\":1,\"kind\":\"downloadParallel\",\"bucket\":\"b\",\"object\":\"o\",\"size\":5000,\"generation\":42,\"part_size\":1024,\"written\":\"1f\"}",
        "{\"version\":1,\"kind\":\"uploadParallel\",\"bucket\":\"b\",\"object\":\"dir/o\",\"size\":5000,\"mtime\":1758700000123456789,\"upload_id\":\"VXBs+1=\",\"part_size\":1024}",
        "{\"version\":1,\"kind\":\"uploadParallel\",\"bucket\":\"b\",\"object\":\"o\",\"size\":1,\"mtime\":-1,\"upload_id\":\"u\",\"part_size\":1024,\"temp\":\"zig-gcp-tmp/00\",\"if_generation_match\":0}",
        "{\"version\":1,\"kind\":\"uploadFile\",\"bucket\":\"b\",\"object\":\"backups/db.tar\",\"size\":123456789,\"mtime\":1758700000123456789,\"session\":\"https://s.example/u1\"}",
    } });
}

test "CheckpointFile: nothing, then a state, then a replacement, then nothing again" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var file: CheckpointFile = .init(testing.io, tmp.dir, "db.tar.download");
    const cp = file.checkpoint();
    try testing.expectEqual(null, try cp.load(arena));
    try cp.save("first state");
    try testing.expectEqualStrings("first state", (try cp.load(arena)).?);
    // A save replaces the state whole, shorter included.
    try cp.save("second");
    try testing.expectEqualStrings("second", (try cp.load(arena)).?);
    cp.clear();
    try testing.expectEqual(null, try cp.load(arena));
    // Clearing what is already gone is nothing.
    cp.clear();
}

test "CheckpointFile: the state is its owner's only" {
    if (!@hasDecl(std.Io.File.Permissions, "fromMode")) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var file: CheckpointFile = .init(testing.io, tmp.dir, "state");
    const cp = file.checkpoint();
    try cp.save("{}");
    const stat = try tmp.dir.statFile(testing.io, "state", .{});
    try testing.expectEqual(0, stat.permissions.toMode() & 0o077);
}

test "CheckpointFile: what cannot be read or written is CheckpointFailed" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A file too large to be a state.
    const big = try testing.allocator.alloc(u8, max_state_len + 1);
    defer testing.allocator.free(big);
    @memset(big, 'x');
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "oversized", .data = big });
    var oversized: CheckpointFile = .init(testing.io, tmp.dir, "oversized");
    try testing.expectError(error.CheckpointFailed, oversized.checkpoint().load(arena));

    // A path that is a directory.
    try tmp.dir.createDir(testing.io, "taken", .default_dir);
    var taken: CheckpointFile = .init(testing.io, tmp.dir, "taken");
    try testing.expectError(error.CheckpointFailed, taken.checkpoint().load(arena));
    try testing.expectError(error.CheckpointFailed, taken.checkpoint().save("state"));
}

test "CheckpointFile: a crash mid-save leaves the old state" {
    // The write goes to an unnamed or temporary file and lands whole with
    // `replace`; a save abandoned before that, as a crash abandons it,
    // leaves the old bytes.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var file: CheckpointFile = .init(testing.io, tmp.dir, "state");
    const cp = file.checkpoint();
    try cp.save("the old state");
    var atomic = try tmp.dir.createFileAtomic(testing.io, "state", .{
        .permissions = CheckpointFile.owner_only,
        .replace = true,
    });
    var buffer: [64]u8 = undefined;
    var writer = atomic.file.writer(testing.io, &buffer);
    try writer.interface.writeAll("half of a new");
    try writer.interface.flush();
    // No `replace`: the process died here.
    atomic.deinit(testing.io);
    try testing.expectEqualStrings("the old state", (try cp.load(arena_state.allocator())).?);
}
