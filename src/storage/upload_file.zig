//! `Object.uploadFile`: a resumable upload that reads its file at
//! offsets, so a lost session, or a later process holding a checkpoint,
//! carries on from whatever the server holds rather than start over. The
//! request that finishes the upload carries the whole file's CRC32C,
//! which Cloud Storage checks before the object exists: no read back, and
//! no delete afterwards.
//!
//! The checkpoint state holds the session URL, which is a credential:
//! anyone holding it can write the object for up to a week. It is never
//! logged, and the built-in file store keeps it readable by its owner
//! only.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const core = @import("core");

const Client = @import("Client.zig");
const checkpoint = @import("checkpoint.zig");
const gzip_upload = @import("gzip_upload.zig");
const logging = @import("logging.zig");
const mp = @import("xml_multipart.zig");
const resumable = @import("resumable.zig");
const rpc = @import("rpc.zig");
const types = @import("types.zig");
const Error = @import("errors.zig").Error;
const Diagnostics = core.Diagnostics;

/// Uploads `file` as `object`. The caller has begun the call and checked
/// the names and options.
pub fn upload(
    client: *Client,
    bucket: []const u8,
    object: []const u8,
    file: std.Io.File,
    options: types.UploadOptions,
) Error!types.Owned(types.ObjectInfo) {
    const size = file.length(client.io) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => {
            if (client.diagnostics) |d| d.print("the file's length could not be read: {t}", .{err});
            return error.ReadFailed;
        },
    };
    if (size > mp.max_object_size) {
        if (client.diagnostics) |d| d.print("the file is {d} bytes, and an object holds at most 5 TiB", .{size});
        return error.InvalidArgument;
    }
    if (options.gzip) |gzip| return uploadCompressed(client, bucket, object, file, size, options, gzip);
    const metadata_crc: ?[8]u8 = if (options.crc32c) |given| core.crc32c.toBase64(given) else null;
    const buffer = try client.gpa.alloc(u8, client.chunk_size);
    defer client.gpa.free(buffer);
    const source: resumable.Source = .{ .file = .{ .f = file, .buffer = buffer, .size = size } };
    const cp = options.checkpoint orelse {
        return resumable.run(client, bucket, object, source, options, metadata_crc);
    };
    return finish(cp, resumeOrStart(client, bucket, object, file, source, .{ .size = size }, options, metadata_crc, cp));
}

/// `uploadFile` with `options.gzip`: the file compressed on its way up.
/// The session holds compressed bytes, whose count only the end of the
/// file settles, so it opens with no length. A later process holding the
/// checkpoint compresses the file again from its first byte, passes over
/// what the session holds, and sends the rest: the same file at the same
/// level, on the same Zig, compresses to the same bytes, and the finishing
/// checksum covers the whole stream in case it did not.
fn uploadCompressed(
    client: *Client,
    bucket: []const u8,
    object: []const u8,
    file: std.Io.File,
    size: u64,
    options: types.UploadOptions,
    gzip: types.Gzip,
) Error!types.Owned(types.ObjectInfo) {
    const stream = try gzip_upload.Stream.create(client, .{ .file = .{ .f = file, .size = size } }, gzip.level, options.crc32c);
    defer stream.destroy();
    const cp = options.checkpoint orelse
        return gzip_upload.uploadResumable(stream, client, bucket, object, options);
    const buffer = try client.gpa.alloc(u8, client.chunk_size);
    defer client.gpa.free(buffer);
    const source: resumable.Source = .{ .reader = .{
        .r = &stream.interface,
        .buffer = buffer,
        .declared = null,
        .final_hash = if (client.verify_checksums) &stream.compressed_hash else null,
        .restart = stream.restart(),
        .failure = &stream.failure,
    } };
    const shape: Shape = .{ .size = size, .gzip = .{ .level = gzip.level, .zig = builtin.zig_version_string } };
    return finish(cp, resumeOrStart(client, bucket, object, file, source, shape, gzip_upload.storedOptions(options), null, cp));
}

/// Clears the checkpoint once the upload is done, or failed in a way a
/// resume could only repeat.
fn finish(cp: checkpoint.Checkpoint, result: Error!types.Owned(types.ObjectInfo)) Error!types.Owned(types.ObjectInfo) {
    if (result) |_| {
        cp.clear();
    } else |err| if (checkpoint.uploadAbandons(err)) cp.clear();
    return result;
}

/// What makes a checkpoint's session this upload's: the file's size, and
/// how the upload compresses it.
const Shape = struct {
    size: u64,
    gzip: ?checkpoint.State.UploadFile.Gzip = null,

    fn matches(shape: Shape, saved: checkpoint.State.UploadFile) bool {
        if (saved.size != shape.size) return false;
        const a = shape.gzip orelse return saved.gzip == null;
        const b = saved.gzip orelse return false;
        return a.level == b.level and std.mem.eql(u8, a.zig, b.zig);
    }
};

/// Picks the upload up at whatever its session holds, or opens one and
/// records it. A session that is gone, expired or cancelled starts over,
/// bounded like a retry; so does a source file that changed, whose old
/// session is cancelled first.
fn resumeOrStart(
    client: *Client,
    bucket: []const u8,
    object: []const u8,
    file: std.Io.File,
    source: resumable.Source,
    shape: Shape,
    options: types.UploadOptions,
    metadata_crc: ?[8]u8,
    cp: checkpoint.Checkpoint,
) Error!types.Owned(types.ObjectInfo) {
    var state_arena: std.heap.ArenaAllocator = .init(client.gpa);
    defer state_arena.deinit();
    const mtime = try statMtime(client, file);
    var saved = try loadState(client, cp, state_arena.allocator(), bucket, object);
    if (saved) |s| if (!shape.matches(s) or s.mtime != mtime) {
        if (s.size != shape.size or s.mtime != mtime) {
            logging.warn("{s}: the source file changed under the checkpoint; cancelling the old session and starting over", .{object});
        } else {
            logging.warn("{s}: the checkpoint's upload was compressed another way, or by another Zig; cancelling the old session and starting over", .{object});
        }
        resumable.dropSession(client, s.session);
        saved = null;
    };
    // A compressed upload's session opens with no length: the end of the
    // file settles how many compressed bytes there are.
    const declared: ?u64 = if (shape.gzip == null) shape.size else null;
    var attempt: u32 = 0;
    while (true) : (attempt += 1) {
        var session_arena: std.heap.ArenaAllocator = .init(client.gpa);
        defer session_arena.deinit();
        // A stream starts every session from its first byte; the file
        // source reads at whatever offset the session names.
        if (attempt > 0) switch (source) {
            .reader => |r| try r.restart.?.rewind(r.restart.?.ctx),
            else => {},
        };
        const resuming = saved != null;
        const session = if (saved) |s| s.session else blk: {
            const uri = try resumable.startSession(client, session_arena.allocator(), bucket, object, options, metadata_crc, declared);
            saveState(client, cp, .{ .upload_file = .{
                .bucket = bucket,
                .object = object,
                .size = shape.size,
                .mtime = mtime,
                .session = uri,
                .gzip = shape.gzip,
            } }) catch |err| {
                // A session the checkpoint never recorded would only take
                // writes for a week: drop it again before any data moves.
                resumable.dropSession(client, uri);
                return err;
            };
            break :blk uri;
        };
        const outcome = resumable.runSession(client, bucket, object, source, options, metadata_crc, session, resuming, false);
        if (outcome) |result| {
            return result;
        } else |err| {
            if (err != error.UploadSessionLost or attempt + 1 >= client.retry.max_attempts) return err;
            logging.warn("{s}: the session is gone; starting over", .{object});
            saved = null;
        }
    }
}

/// What the checkpoint holds for this upload, or null when it holds
/// nothing yet. A state that cannot be read or parsed, or that belongs to
/// another transfer, is `error.CheckpointFailed` before anything is sent.
fn loadState(
    client: *Client,
    cp: checkpoint.Checkpoint,
    arena: Allocator,
    bucket: []const u8,
    object: []const u8,
) Error!?checkpoint.State.UploadFile {
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
        .upload_file => |s| s,
        else => {
            if (d) |diag| diag.print("the checkpoint belongs to another transfer, not an uploadFile; give each transfer a checkpoint of its own", .{});
            return error.CheckpointFailed;
        },
    };
    if (!std.mem.eql(u8, s.bucket, bucket) or !std.mem.eql(u8, s.object, object)) {
        if (d) |diag| diag.print("the checkpoint belongs to another transfer; overwriting it would orphan that one, so give each transfer a checkpoint of its own", .{});
        return error.CheckpointFailed;
    }
    return s;
}

/// Encodes and saves the upload's state, once, when the session opens. A
/// store that cannot save fails the upload before any data moves.
fn saveState(client: *Client, cp: checkpoint.Checkpoint, state: checkpoint.State) Error!void {
    const bytes = try checkpoint.encodeAlloc(client.gpa, state);
    defer client.gpa.free(bytes);
    cp.save(bytes) catch |err| switch (err) {
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

const testing = std.testing;
const test_util = @import("test_util.zig");
const Object = @import("Object.zig");
const FakeMultipart = test_util.FakeMultipart;
const MemoryCheckpoint = test_util.MemoryCheckpoint;

const chunk_size = 256 * 1024;

fn fill(buf: []u8, seed: u64) void {
    var prng: std.Random.DefaultPrng = .init(seed);
    prng.random().bytes(buf);
}

/// The test's source file, opened to be rewritten between "processes".
fn sourceOn(tmp: *testing.TmpDir, data: []const u8) !std.Io.File {
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "source.bin", .data = data });
    return tmp.dir.openFile(testing.io, "source.bin", .{ .mode = .read_write });
}

/// A client on the stateful fake, with 256 KiB chunks and real file IO.
fn clientOn(fake: *FakeMultipart, token: *core.StaticToken, diag: *Diagnostics, max_attempts: u8) !Client {
    return Client.init(testing.allocator, testing.io, .{
        .token_provider = token.provider(),
        .transport = fake.transport(),
        .diagnostics = diag,
        .chunk_size = chunk_size,
        .retry = .{ .max_attempts = max_attempts, .initial_backoff_ms = 1, .max_backoff_ms = 2 },
    });
}

/// Fault rules for the fake: the first `times` requests of `kind` (and
/// the chunk starting at byte `at`, when set) meet `fault`.
const Script = struct {
    rules: []Rule,

    const Rule = struct {
        kind: FakeMultipart.Kind = .session_put,
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

test "golden: uploadFile reads at offsets, and the final chunk carries the whole file's checksum" {
    const data = try testing.allocator.alloc(u8, 600 * 1024);
    defer testing.allocator.free(data);
    fill(data, 60);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try sourceOn(&tmp, data);
    defer file.close(testing.io);

    const session_uri = "https://storage.example.test/upload/session/SECRET-7f3a";
    const crc_b64 = core.crc32c.toBase64(core.crc32c.hash(data));
    var done_buf: [160]u8 = undefined;
    const done = try std.fmt.bufPrint(&done_buf, "{{\"name\":\"backup.tar\",\"bucket\":\"b\",\"size\":\"614400\",\"generation\":\"55\",\"crc32c\":\"{s}\"}}", .{&crc_b64});
    var fake: test_util.FakeTransport = .init(testing.allocator, &.{
        .{ .respond = .{ .body = "", .headers = &.{.{ .name = "Location", .value = session_uri }} } },
        .{ .respond = .{ .status = 308, .body = "", .headers = &.{.{ .name = "Range", .value = "bytes=0-262143" }} } },
        .{ .respond = .{ .status = 308, .body = "", .headers = &.{.{ .name = "Range", .value = "bytes=0-524287" }} } },
        .{ .respond = .{ .status = 200, .body = done } },
    });
    defer fake.deinit();
    var token: core.StaticToken = .{ .token = "ya29.t" };
    var diag: Diagnostics = .{};
    var client = try clientOn2(&fake, &token, &diag);
    defer client.deinit();

    var info = try client.bucket("b").object("backup.tar").uploadFile(file, .{ .content_type = "application/x-tar" });
    defer info.deinit();
    try testing.expectEqual(614400, info.value.size);
    try testing.expectEqual(55, info.value.generation);

    // The session opens with credentials and the file's shape declared;
    // no fifth request follows: the server checked the checksum, so there
    // is no read back.
    try testing.expectEqual(4, fake.stream_requests.items.len);
    const open = try fake.streamRequest(0);
    try testing.expectEqualStrings("https://storage.googleapis.com/upload/storage/v1/b/b/o?uploadType=resumable", open.url);
    try testing.expectEqualStrings("614400", open.header("X-Upload-Content-Length").?);

    // Each chunk is the file at its own offset; only the one that
    // finishes the upload carries the whole file's checksum.
    const ranges = [_][]const u8{ "bytes 0-262143/614400", "bytes 262144-524287/614400", "bytes 524288-614399/614400" };
    for (ranges, 1..) |range, i| {
        const put = try fake.streamRequest(i);
        try testing.expectEqualStrings(session_uri, put.url);
        try testing.expectEqual(null, put.bearer);
        try testing.expectEqualStrings(range, put.header("Content-Range").?);
        try testing.expectEqual(core.crc32c.hash(data[(i - 1) * chunk_size .. @min(i * chunk_size, data.len)]), put.body_crc32c);
        if (i < 3) {
            try testing.expectEqual(null, put.header("X-Goog-Hash"));
        } else {
            var want_buf: [16]u8 = undefined;
            const want = try std.fmt.bufPrint(&want_buf, "crc32c={s}", .{&crc_b64});
            try testing.expectEqualStrings(want, put.header("X-Goog-Hash").?);
        }
    }
}

/// Like `clientOn`, over core's scripted fake transport.
fn clientOn2(fake: *test_util.FakeTransport, token: *core.StaticToken, diag: *Diagnostics) !Client {
    return Client.init(testing.allocator, testing.io, .{
        .token_provider = token.provider(),
        .transport = fake.transport(),
        .diagnostics = diag,
        .chunk_size = chunk_size,
        .retry = .{ .max_attempts = 3, .initial_backoff_ms = 1, .max_backoff_ms = 2 },
    });
}

test "uploadFile: refusals before anything is sent" {
    var fake: test_util.FakeTransport = .init(testing.allocator, &.{});
    defer fake.deinit();
    var token: core.StaticToken = .{ .token = "ya29.t" };
    var diag: Diagnostics = .{};
    var client = try clientOn2(&fake, &token, &diag);
    defer client.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try sourceOn(&tmp, "bytes");
    defer file.close(testing.io);

    // The size comes from the file.
    try testing.expectError(error.InvalidArgument, client.bucket("b").object("o").uploadFile(file, .{ .size = 5 }));
    try testing.expect(std.mem.indexOf(u8, diag.message(), "takes its size from the file") != null);

    // Only uploadFile takes a checkpoint: memory and streams cannot
    // resume in a later process.
    var saved: MemoryCheckpoint = .{ .gpa = testing.allocator };
    defer saved.deinit();
    try testing.expectError(error.InvalidArgument, client.bucket("b").object("o").upload("bytes", .{ .checkpoint = saved.checkpoint() }));
    var reader: std.Io.Reader = .fixed("bytes");
    try testing.expectError(error.InvalidArgument, client.bucket("b").object("o").uploadFrom(&reader, .{ .checkpoint = saved.checkpoint() }));
    try testing.expect(std.mem.indexOf(u8, diag.message(), "uploadFile takes one") != null);
    try testing.expectEqual(0, fake.stream_requests.items.len);
    try testing.expectEqual(0, saved.loads);
}

test "uploadFile against the fake: whole, empty, and a wrong options.crc32c refused before the finish" {
    var fake: FakeMultipart = .init(testing.allocator, testing.io);
    defer fake.deinit();
    var token: core.StaticToken = .{ .token = "ya29.t" };
    var diag: Diagnostics = .{};
    var client = try clientOn(&fake, &token, &diag, 3);
    defer client.deinit();
    const data = try testing.allocator.alloc(u8, 600 * 1024 + 17);
    defer testing.allocator.free(data);
    fill(data, 61);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try sourceOn(&tmp, data);
    defer file.close(testing.io);

    var info = try client.bucket("b").object("dir/o").uploadFile(file, .{ .content_type = "application/x-test" });
    defer info.deinit();
    try testing.expectEqual(data.len, info.value.size);
    try testing.expectEqual(core.crc32c.hash(data), info.value.crc32c.?);
    try testing.expectEqualSlices(u8, data, fake.object("dir/o").?.bytes);
    try testing.expectEqual(1, fake.counts.session_starts);
    try testing.expectEqual(3, fake.counts.session_puts);
    try testing.expectEqual(data.len, fake.counts.session_bytes);
    try testing.expectEqual(0, fake.counts.session_stale_bytes);
    try testing.expectEqual(0, fake.openSessions());

    // An empty file finishes with `bytes */0` and the empty checksum.
    const empty = try sourceOn(&tmp, "");
    defer empty.close(testing.io);
    var nothing = try client.bucket("b").object("empty").uploadFile(empty, .{});
    defer nothing.deinit();
    try testing.expectEqual(0, nothing.value.size);
    try testing.expectEqual(0, nothing.value.crc32c.?);

    // A caller's crc32c that contradicts the file is refused before the
    // finishing request goes out, and the session is cancelled.
    const cancels_before = fake.counts.session_cancels;
    try testing.expectError(error.ChecksumMismatch, client.bucket("b").object("dir/o").uploadFile(file, .{
        .crc32c = core.crc32c.hash(data) ^ 1,
    }));
    try testing.expect(std.mem.indexOf(u8, diag.message(), "checksum mismatch before the finish") != null);
    try testing.expectEqual(cancels_before + 1, fake.counts.session_cancels);
    try testing.expectEqual(0, fake.openSessions());
}

test "uploadFile: a chunk corrupted in transit poisons the session, which is cancelled and started over" {
    var fake: FakeMultipart = .init(testing.allocator, testing.io);
    defer fake.deinit();
    var rules = [_]Script.Rule{.{ .at = 0, .fault = .corrupt }};
    var script: Script = .{ .rules = &rules };
    fake.faults = script.plan();
    var token: core.StaticToken = .{ .token = "ya29.t" };
    var diag: Diagnostics = .{};
    var client = try clientOn(&fake, &token, &diag, 3);
    defer client.deinit();
    const data = try testing.allocator.alloc(u8, 300 * 1024);
    defer testing.allocator.free(data);
    fill(data, 62);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try sourceOn(&tmp, data);
    defer file.close(testing.io);

    var info = try client.bucket("b").object("o").uploadFile(file, .{});
    defer info.deinit();
    // The finish's checksum caught the corruption; the poisoned session
    // was cancelled, a fresh one carried the file whole, and no corrupted
    // object ever stood.
    try testing.expectEqual(core.crc32c.hash(data), info.value.crc32c.?);
    try testing.expectEqualSlices(u8, data, fake.object("o").?.bytes);
    try testing.expectEqual(2, fake.counts.session_starts);
    try testing.expectEqual(1, fake.counts.session_cancels);
    try testing.expectEqual(0, fake.openSessions());
}

test "uploadFile with a checkpoint: saved once when the session opens, cleared at the end" {
    var fake: FakeMultipart = .init(testing.allocator, testing.io);
    defer fake.deinit();
    var token: core.StaticToken = .{ .token = "ya29.t" };
    var diag: Diagnostics = .{};
    var client = try clientOn(&fake, &token, &diag, 3);
    defer client.deinit();
    const data = try testing.allocator.alloc(u8, 300 * 1024);
    defer testing.allocator.free(data);
    fill(data, 63);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try sourceOn(&tmp, data);
    defer file.close(testing.io);
    var saved: MemoryCheckpoint = .{ .gpa = testing.allocator };
    defer saved.deinit();

    var info = try client.bucket("b").object("o").uploadFile(file, .{ .checkpoint = saved.checkpoint() });
    defer info.deinit();
    try testing.expectEqualSlices(u8, data, fake.object("o").?.bytes);
    try testing.expectEqual(1, saved.saves);
    try testing.expectEqual(1, saved.clears);
    try testing.expectEqual(null, saved.stored);
}

test "uploadFile: a run that dies partway leaves a checkpoint a second client resumes, sending only what is missing" {
    var fake: FakeMultipart = .init(testing.allocator, testing.io);
    defer fake.deinit();
    var token: core.StaticToken = .{ .token = "ya29.t" };
    const data = try testing.allocator.alloc(u8, 600 * 1024 + 17);
    defer testing.allocator.free(data);
    fill(data, 64);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try sourceOn(&tmp, data);
    defer file.close(testing.io);
    var store: checkpoint.CheckpointFile = .init(testing.io, tmp.dir, "o.upload");
    const options: types.UploadOptions = .{ .checkpoint = store.checkpoint() };

    // The first process stores one chunk; the request for the second dies
    // with it. Nothing is cancelled: the session is the checkpoint's.
    var rules = [_]Script.Rule{.{ .at = chunk_size, .fault = .canceled }};
    var script: Script = .{ .rules = &rules };
    fake.faults = script.plan();
    {
        var diag: Diagnostics = .{};
        var first = try clientOn(&fake, &token, &diag, 3);
        defer first.deinit();
        try testing.expectError(error.Canceled, first.bucket("b").object("dir/o").uploadFile(file, options));
    }
    try testing.expectEqual(1, fake.openSessions());
    try testing.expectEqual(0, fake.counts.session_cancels);
    try testing.expectEqual(chunk_size, fake.counts.session_bytes);
    fake.faults = null;

    // The second process asks the session where it stands, re-reads the
    // stored prefix locally to rebuild the checksum, and sends the rest:
    // not one byte twice, and the finish still carries the whole file's
    // checksum, which the server verified against what it holds.
    var diag: Diagnostics = .{};
    var second = try clientOn(&fake, &token, &diag, 3);
    defer second.deinit();
    var info = try second.bucket("b").object("dir/o").uploadFile(file, options);
    defer info.deinit();
    try testing.expectEqual(data.len, info.value.size);
    try testing.expectEqual(core.crc32c.hash(data), info.value.crc32c.?);
    try testing.expectEqualSlices(u8, data, fake.object("dir/o").?.bytes);
    try testing.expectEqual(1, fake.counts.session_starts);
    try testing.expectEqual(data.len, fake.counts.session_bytes);
    try testing.expectEqual(0, fake.counts.session_stale_bytes);
    try testing.expectEqual(0, fake.openSessions());
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(testing.io, "o.upload", .{}));
}

test "uploadFile: a checkpoint of a finished upload finds the object through its session, and sends nothing" {
    var fake: FakeMultipart = .init(testing.allocator, testing.io);
    defer fake.deinit();
    var token: core.StaticToken = .{ .token = "ya29.t" };
    var diag: Diagnostics = .{};
    var client = try clientOn(&fake, &token, &diag, 3);
    defer client.deinit();
    const data = try testing.allocator.alloc(u8, 300 * 1024);
    defer testing.allocator.free(data);
    fill(data, 65);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try sourceOn(&tmp, data);
    defer file.close(testing.io);
    // The process dies between the finish and the clear.
    var saved: MemoryCheckpoint = .{ .gpa = testing.allocator, .keep_on_clear = true };
    defer saved.deinit();
    const options: types.UploadOptions = .{ .checkpoint = saved.checkpoint() };
    var first = try client.bucket("b").object("o").uploadFile(file, options);
    first.deinit();
    try testing.expect(saved.stored != null);
    const bytes_before = fake.counts.session_bytes;

    saved.keep_on_clear = false;
    var info = try client.bucket("b").object("o").uploadFile(file, options);
    defer info.deinit();
    try testing.expectEqual(data.len, info.value.size);
    try testing.expectEqual(core.crc32c.hash(data), info.value.crc32c.?);
    // One status query, which answered with the finished object; the
    // whole file was re-read locally to verify it, and nothing was sent.
    try testing.expectEqual(bytes_before, fake.counts.session_bytes);
    try testing.expectEqual(1, fake.counts.session_starts);
    try testing.expectEqual(null, saved.stored);
}

test "uploadFile: a finished session whose file changed under a forged mtime is caught and deleted" {
    var fake: FakeMultipart = .init(testing.allocator, testing.io);
    defer fake.deinit();
    var token: core.StaticToken = .{ .token = "ya29.t" };
    var diag: Diagnostics = .{};
    var client = try clientOn(&fake, &token, &diag, 3);
    defer client.deinit();
    const data = try testing.allocator.alloc(u8, 300 * 1024);
    defer testing.allocator.free(data);
    fill(data, 66);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try sourceOn(&tmp, data);
    defer file.close(testing.io);
    var saved: MemoryCheckpoint = .{ .gpa = testing.allocator, .keep_on_clear = true };
    defer saved.deinit();
    var first = try client.bucket("b").object("o").uploadFile(file, .{ .checkpoint = saved.checkpoint() });
    first.deinit();

    // The file's bytes change; the state's mtime is forged to match, as
    // only re-reading the data could catch.
    fill(data, 67);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "source.bin", .data = data });
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var state = (try checkpoint.parse(arena.allocator(), saved.stored.?)).upload_file;
    state.mtime = (try file.stat(testing.io)).mtime.nanoseconds;
    const forged = try checkpoint.encodeAlloc(testing.allocator, .{ .upload_file = state });
    testing.allocator.free(saved.stored.?);
    saved.stored = forged;
    saved.keep_on_clear = false;

    try testing.expectError(error.ChecksumMismatch, client.bucket("b").object("o").uploadFile(file, .{ .checkpoint = saved.checkpoint() }));
    try testing.expect(std.mem.indexOf(u8, diag.message(), "checksum mismatch after the upload finished") != null);
    // The mismatched object went, pinned to its generation, and the state
    // was discredited too.
    try testing.expect(fake.object("o") == null);
    try testing.expectEqual(null, saved.stored);
}

test "uploadFile: a gone session starts over; a changed source cancels the old session first" {
    var fake: FakeMultipart = .init(testing.allocator, testing.io);
    defer fake.deinit();
    var token: core.StaticToken = .{ .token = "ya29.t" };
    var diag: Diagnostics = .{};
    var client = try clientOn(&fake, &token, &diag, 3);
    defer client.deinit();
    const data = try testing.allocator.alloc(u8, 400 * 1024);
    defer testing.allocator.free(data);
    fill(data, 68);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try sourceOn(&tmp, data);
    defer file.close(testing.io);
    var saved: MemoryCheckpoint = .{ .gpa = testing.allocator };
    defer saved.deinit();
    const options: types.UploadOptions = .{ .checkpoint = saved.checkpoint() };

    // Run 1 dies after a chunk; the session is then aborted behind its
    // back, a lifecycle of its own week, say.
    var rules = [_]Script.Rule{
        .{ .at = chunk_size, .fault = .canceled },
        .{ .at = null, .times = 1, .fault = .gone },
    };
    var script: Script = .{ .rules = &rules };
    fake.faults = script.plan();
    try testing.expectError(error.Canceled, client.bucket("b").object("o").uploadFile(file, options));
    // Run 2 finds it gone at the status query, and starts over whole.
    var info = try client.bucket("b").object("o").uploadFile(file, options);
    defer info.deinit();
    try testing.expectEqualSlices(u8, data, fake.object("o").?.bytes);
    try testing.expectEqual(2, fake.counts.session_starts);
    try testing.expectEqual(null, saved.stored);
    fake.faults = null;

    // Run 3 dies too; the file then changes: the old session is cancelled
    // before a fresh upload of the new bytes.
    var rules2 = [_]Script.Rule{.{ .at = chunk_size, .fault = .canceled }};
    var script2: Script = .{ .rules = &rules2 };
    fake.faults = script2.plan();
    try testing.expectError(error.Canceled, client.bucket("b").object("o").uploadFile(file, options));
    fake.faults = null;
    const cancels_before = fake.counts.session_cancels;
    const puts_before = fake.counts.session_puts;
    fill(data, 69);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "source.bin", .data = data[0 .. data.len - 1] });
    var replaced = try client.bucket("b").object("o").uploadFile(file, options);
    defer replaced.deinit();
    try testing.expectEqual(cancels_before + 1, fake.counts.session_cancels);
    // The old session was never even asked where it stands: the mtime
    // told the story, and the fresh upload is exactly two chunks.
    try testing.expectEqual(puts_before + 2, fake.counts.session_puts);
    try testing.expectEqualSlices(u8, data[0 .. data.len - 1], fake.object("o").?.bytes);
    try testing.expectEqual(0, fake.openSessions());
}

test "uploadFile: a session cancelled behind the checkpoint's back answers 499, and the upload starts over" {
    var fake: FakeMultipart = .init(testing.allocator, testing.io);
    defer fake.deinit();
    var token: core.StaticToken = .{ .token = "ya29.t" };
    var diag: Diagnostics = .{};
    var client = try clientOn(&fake, &token, &diag, 3);
    defer client.deinit();
    const data = try testing.allocator.alloc(u8, 400 * 1024);
    defer testing.allocator.free(data);
    fill(data, 70);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try sourceOn(&tmp, data);
    defer file.close(testing.io);
    var saved: MemoryCheckpoint = .{ .gpa = testing.allocator };
    defer saved.deinit();
    const options: types.UploadOptions = .{ .checkpoint = saved.checkpoint() };

    // Run 1 dies after a chunk, and someone cancels its session: Cloud
    // Storage answers every later request to it with 499, measured on
    // 2026-09-25, where an expired one would answer 404 or 410.
    var rules = [_]Script.Rule{.{ .at = chunk_size, .fault = .canceled }};
    var script: Script = .{ .rules = &rules };
    fake.faults = script.plan();
    try testing.expectError(error.Canceled, client.bucket("b").object("o").uploadFile(file, options));
    fake.faults = null;
    var state_arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer state_arena.deinit();
    const state = try checkpoint.parse(state_arena.allocator(), saved.stored.?);
    try resumable.cancelSession(&client, state.upload_file.session);

    // Run 2's status query meets the 499, and the upload starts over.
    var info = try client.bucket("b").object("o").uploadFile(file, options);
    defer info.deinit();
    try testing.expectEqualSlices(u8, data, fake.object("o").?.bytes);
    try testing.expectEqual(2, fake.counts.session_starts);
    try testing.expectEqual(null, saved.stored);
    try testing.expectEqual(0, fake.openSessions());
}

test "uploadFile: a checkpoint of another transfer, or one unreadable, is refused before anything is sent and kept" {
    var fake: FakeMultipart = .init(testing.allocator, testing.io);
    defer fake.deinit();
    var token: core.StaticToken = .{ .token = "ya29.t" };
    var diag: Diagnostics = .{};
    var client = try clientOn(&fake, &token, &diag, 3);
    defer client.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try sourceOn(&tmp, "the file's bytes");
    defer file.close(testing.io);

    const foreign = try checkpoint.encodeAlloc(testing.allocator, .{ .upload_file = .{
        .bucket = "b",
        .object = "someone-elses",
        .size = 16,
        .mtime = 1,
        .session = "https://s.example/u1",
    } });
    var other: MemoryCheckpoint = .{ .gpa = testing.allocator, .stored = foreign };
    defer other.deinit();
    try testing.expectError(error.CheckpointFailed, client.bucket("b").object("o").uploadFile(file, .{ .checkpoint = other.checkpoint() }));
    try testing.expect(std.mem.indexOf(u8, diag.message(), "belongs to another transfer") != null);
    try testing.expectEqualStrings(foreign, other.stored.?);

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
    try testing.expectError(error.CheckpointFailed, client.bucket("b").object("o").uploadFile(file, .{ .checkpoint = wrong_kind.checkpoint() }));
    try testing.expect(std.mem.indexOf(u8, diag.message(), "not an uploadFile") != null);

    var garbage: MemoryCheckpoint = .{ .gpa = testing.allocator, .stored = try testing.allocator.dupe(u8, "~/.gsutil/tracker") };
    defer garbage.deinit();
    try testing.expectError(error.CheckpointFailed, client.bucket("b").object("o").uploadFile(file, .{ .checkpoint = garbage.checkpoint() }));
    try testing.expectEqual(0, fake.counts.session_starts);
    try testing.expectEqual(0, fake.counts.session_puts);
}

test "uploadFile: a save that fails at the start drops the unrecorded session; retries running out keep everything" {
    var fake: FakeMultipart = .init(testing.allocator, testing.io);
    defer fake.deinit();
    var token: core.StaticToken = .{ .token = "ya29.t" };
    var diag: Diagnostics = .{};
    var client = try clientOn(&fake, &token, &diag, 3);
    defer client.deinit();
    const data = try testing.allocator.alloc(u8, 400 * 1024);
    defer testing.allocator.free(data);
    fill(data, 70);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try sourceOn(&tmp, data);
    defer file.close(testing.io);

    var saved: MemoryCheckpoint = .{ .gpa = testing.allocator, .saves_allowed = 0 };
    defer saved.deinit();
    const options: types.UploadOptions = .{ .checkpoint = saved.checkpoint() };
    try testing.expectError(error.CheckpointFailed, client.bucket("b").object("o").uploadFile(file, options));
    try testing.expect(std.mem.indexOf(u8, diag.message(), "refused a save") != null);
    try testing.expectEqual(1, fake.counts.session_cancels);
    try testing.expectEqual(0, fake.counts.session_bytes);
    try testing.expectEqual(0, fake.openSessions());

    // Retries running out on a chunk keeps the session and the state.
    saved.saves_allowed = null;
    var rules = [_]Script.Rule{.{ .at = chunk_size, .times = 2, .fault = .unavailable }};
    var script: Script = .{ .rules = &rules };
    fake.faults = script.plan();
    try testing.expectError(error.Unavailable, client.bucket("b").object("o").uploadFile(file, options));
    try testing.expect(saved.stored != null);
    try testing.expectEqual(1, fake.counts.session_cancels);
    try testing.expectEqual(1, fake.openSessions());

    fake.faults = null;
    var info = try client.bucket("b").object("o").uploadFile(file, options);
    defer info.deinit();
    try testing.expectEqualSlices(u8, data, fake.object("o").?.bytes);
    try testing.expectEqual(data.len, fake.counts.session_bytes);
    try testing.expectEqual(0, fake.counts.session_stale_bytes);
    try testing.expectEqual(0, fake.openSessions());
    try testing.expectEqual(null, saved.stored);
}

test "abandonTransfer: each kind of checkpoint, an empty one, and garbage" {
    var fake: FakeMultipart = .init(testing.allocator, testing.io);
    fake.min_part_size = 1024;
    defer fake.deinit();
    var token: core.StaticToken = .{ .token = "ya29.t" };
    var diag: Diagnostics = .{};
    var client = try clientOn(&fake, &token, &diag, 3);
    defer client.deinit();
    client.multipart_test = .{ .min_part_size = 1024 };
    const data = try testing.allocator.alloc(u8, 300 * 1024);
    defer testing.allocator.free(data);
    fill(data, 71);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try sourceOn(&tmp, data);
    defer file.close(testing.io);

    // An uploadFile checkpoint: its session is cancelled.
    var saved: MemoryCheckpoint = .{ .gpa = testing.allocator };
    defer saved.deinit();
    var rules = [_]Script.Rule{.{ .at = chunk_size, .fault = .canceled }};
    var script: Script = .{ .rules = &rules };
    fake.faults = script.plan();
    try testing.expectError(error.Canceled, client.bucket("b").object("o").uploadFile(file, .{ .checkpoint = saved.checkpoint() }));
    fake.faults = null;
    try testing.expectEqual(1, fake.openSessions());
    try client.abandonTransfer(saved.checkpoint());
    try testing.expectEqual(1, fake.counts.session_cancels);
    try testing.expectEqual(0, fake.openSessions());
    try testing.expectEqual(null, saved.stored);

    // A parallel upload's checkpoint: the upload is aborted.
    var rules2 = [_]Script.Rule{.{ .kind = .part, .at = 1, .fault = .canceled }};
    _ = &rules2;
    var script2: Script = .{ .rules = &rules2 };
    fake.faults = script2.plan();
    try testing.expectError(error.Canceled, client.bucket("b").object("o").uploadParallel(.{ .file = file }, .{
        .part_size = 1024,
        .concurrency = 1,
        .checkpoint = saved.checkpoint(),
    }));
    fake.faults = null;
    try testing.expectEqual(1, fake.openUploads());
    try client.abandonTransfer(saved.checkpoint());
    try testing.expectEqual(1, fake.counts.aborts);
    try testing.expectEqual(0, fake.openUploads());
    try testing.expectEqual(null, saved.stored);

    // A download's checkpoint left nothing on the server: only cleared.
    const download_state = try checkpoint.encodeAlloc(testing.allocator, .{ .download_parallel = .{
        .bucket = "b",
        .object = "o",
        .size = 5000,
        .generation = 42,
        .part_size = 1024,
        .written = "50",
    } });
    saved.stored = download_state;
    const requests_before = fake.counts;
    try client.abandonTransfer(saved.checkpoint());
    try testing.expectEqual(null, saved.stored);
    try testing.expectEqual(requests_before.session_cancels, fake.counts.session_cancels);
    try testing.expectEqual(requests_before.aborts, fake.counts.aborts);

    // Nothing saved is nothing to do; garbage is refused and kept.
    try client.abandonTransfer(saved.checkpoint());
    saved.stored = try testing.allocator.dupe(u8, "not a state");
    try testing.expectError(error.CheckpointFailed, client.abandonTransfer(saved.checkpoint()));
    try testing.expect(saved.stored != null);
}

test "the uploadFile checkpoint's session URL reaches neither the log nor the diagnostics" {
    logging.capture.reset();
    var fake: FakeMultipart = .init(testing.allocator, testing.io);
    defer fake.deinit();
    var token: core.StaticToken = .{ .token = "ya29.t" };
    var diag: Diagnostics = .{};
    var client = try clientOn(&fake, &token, &diag, 3);
    defer client.deinit();
    const data = try testing.allocator.alloc(u8, 300 * 1024);
    defer testing.allocator.free(data);
    fill(data, 72);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try sourceOn(&tmp, data);
    defer file.close(testing.io);
    var saved: MemoryCheckpoint = .{ .gpa = testing.allocator };
    defer saved.deinit();
    const options: types.UploadOptions = .{ .checkpoint = saved.checkpoint() };

    var rules = [_]Script.Rule{.{ .at = chunk_size, .fault = .canceled }};
    var script: Script = .{ .rules = &rules };
    fake.faults = script.plan();
    try testing.expectError(error.Canceled, client.bucket("b").object("o").uploadFile(file, options));
    fake.faults = null;
    // The state on disk names the session; the logs never do.
    try testing.expect(std.mem.indexOf(u8, saved.stored.?, "/upload/session/") != null);
    var info = try client.bucket("b").object("o").uploadFile(file, options);
    info.deinit();

    try testing.expect(logging.capture.lines > 0);
    try testing.expectEqual(null, std.mem.indexOf(u8, logging.capture.text(), "/upload/session/"));
    try testing.expectEqual(null, std.mem.indexOf(u8, logging.capture.text(), "\"kind\""));
    try testing.expectEqual(null, std.mem.indexOf(u8, diag.message(), "/upload/session/"));
}

fn uploadFileWithCheckpoint(gpa: Allocator) !void {
    var fake: FakeMultipart = .init(gpa, testing.io);
    defer fake.deinit();
    var token: core.StaticToken = .{ .token = "ya29.t" };
    var client: Client = try .init(gpa, testing.io, .{
        .token_provider = token.provider(),
        .transport = fake.transport(),
        .chunk_size = chunk_size,
    });
    defer client.deinit();
    var data: [3000]u8 = undefined;
    fill(&data, 73);
    var saved: MemoryCheckpoint = .{ .gpa = gpa };
    defer saved.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try sourceOn(&tmp, &data);
    defer file.close(testing.io);
    var info = try client.bucket("b").object("o").uploadFile(file, .{ .checkpoint = saved.checkpoint() });
    info.deinit();
}

test "uploadFile with a checkpoint: every allocation failure is OutOfMemory, and nothing leaks" {
    try testing.checkAllAllocationFailures(testing.allocator, uploadFileWithCheckpoint, .{});
}

/// Draws each session request's fate from fuzz bytes: mostly nothing,
/// sometimes a fault that kind of request can meet.
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
        // Cancels are best-effort cleanup, as the parallel properties
        // treat aborts and deletes.
        if (kind == .session_cancel or self.pos >= self.bytes.len) return .none;
        const b = self.bytes[self.pos];
        self.pos += 1;
        const put = kind == .session_put;
        const fault: FakeMultipart.Fault = switch (b) {
            0...179 => .none,
            180...199 => .unavailable,
            200...214 => .reset,
            215...229 => .lose_answer,
            230...239 => .canceled,
            240...247 => if (put) .corrupt else .none,
            else => if (put) .gone else .none,
        };
        if (fault != .none) self.faulted = true;
        return fault;
    }
};

/// One upload under drawn faults, cut wherever they cut it, then a second
/// run with the same checkpoint and no faults: the second run succeeds
/// with exactly the file's bytes, a resume of a live session sends no
/// byte the server already holds, the state is cleared, and no session
/// with bytes in it stays behind (an empty one whose opening answer was
/// lost may, its URL never having reached the client). The one
/// legitimate second-run failure is the checksum backstop: a first-run
/// fault corrupted a stored chunk and the run died with every byte in,
/// so the second run's status query finalizes the session, hashless, and
/// the whole-file verification refuses the object, deletes it, and
/// clears the state; a third run is then whole and right.
fn resumeUnderFaults(input: []const u8) !void {
    var g: test_util.ByteGen = .init(input);
    const size = g.intRange(usize, 0, 600 * 1024);
    const data = try testing.allocator.alloc(u8, size);
    defer testing.allocator.free(data);
    fill(data, g.int(u64));

    var fake: FakeMultipart = .init(testing.allocator, testing.io);
    defer fake.deinit();
    var token: core.StaticToken = .{ .token = "ya29.t" };
    var saved: MemoryCheckpoint = .{ .gpa = testing.allocator };
    defer saved.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try sourceOn(&tmp, data);
    defer file.close(testing.io);
    const options: types.UploadOptions = .{ .checkpoint = saved.checkpoint() };

    var chooser: Chooser = .{ .bytes = g.rest() };
    fake.faults = chooser.plan();
    var first_diag: Diagnostics = .{};
    var first = try clientOn(&fake, &token, &first_diag, 2);
    defer first.deinit();
    if (first.bucket("b").object("o").uploadFile(file, options)) |finished| {
        var owned = finished;
        owned.deinit();
    } else |err| {
        errdefer std.debug.print("first run: {t}: {s}\n", .{ err, first_diag.message() });
        // Only a fault ends a first run.
        try testing.expect(chooser.faulted);
    }

    // What the state records, and what its session already holds.
    var held_before: u64 = 0;
    var resumed_session = false;
    if (saved.stored) |bytes| {
        var state_arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer state_arena.deinit();
        // Whatever the faults did, the state is one this library wrote.
        const state = try checkpoint.parse(state_arena.allocator(), bytes);
        const s = state.upload_file;
        try testing.expectEqualStrings("o", s.object);
        try testing.expectEqual(data.len, s.size);
        for (fake.sessions.items) |session| {
            if (!std.mem.endsWith(u8, s.session, session.id)) continue;
            // A session that finished before the first run died answers
            // with its object: nothing is sent, so nothing is counted.
            if (session.done == null) {
                resumed_session = true;
                held_before = session.bytes.items.len;
            }
        }
    }
    const bytes_before = fake.counts.session_bytes;
    const starts_before = fake.counts.session_starts;

    fake.faults = null;
    var diag: Diagnostics = .{};
    var second = try clientOn(&fake, &token, &diag, 4);
    defer second.deinit();
    const target = second.bucket("b").object("o");
    var info = target.uploadFile(file, options) catch |err| {
        errdefer std.debug.print("second run: {t}: {s}\n", .{ err, diag.message() });
        try testing.expectEqual(error.ChecksumMismatch, err);
        try testing.expect(chooser.faulted);
        // The mismatched object went, the state went, and a third run is
        // whole and right.
        try testing.expectEqual(null, saved.stored);
        try testing.expect(fake.object("o") == null);
        var third = try target.uploadFile(file, options);
        defer third.deinit();
        try testing.expectEqual(core.crc32c.hash(data), third.value.crc32c.?);
        try testing.expectEqualSlices(u8, data, fake.object("o").?.bytes);
        for (fake.sessions.items) |session| {
            if (session.done == null) try testing.expectEqual(0, session.bytes.items.len);
        }
        return;
    };
    defer info.deinit();

    try testing.expectEqual(data.len, info.value.size);
    try testing.expectEqual(core.crc32c.hash(data), info.value.crc32c.?);
    try testing.expectEqualSlices(u8, data, fake.object("o").?.bytes);
    try testing.expectEqual(null, saved.stored);
    // A clean resume of a live session sent exactly what was missing.
    if (resumed_session and fake.counts.session_starts == starts_before) {
        try testing.expectEqual(data.len - held_before, fake.counts.session_bytes - bytes_before);
        try testing.expectEqual(0, fake.counts.session_stale_bytes);
    }
    // Nothing with bytes in it stays behind to take writes for a week.
    for (fake.sessions.items) |s| {
        if (s.done == null) try testing.expectEqual(0, s.bytes.items.len);
    }
}

fn resumeProperty(_: void, input: []const u8) !void {
    try resumeUnderFaults(input);
}

// About 15 ms a run in Debug, with two uploads of up to 600 KiB over a
// real file: named out of the nightly's "fuzz" and "slow property"
// filters, like the parallel fault properties, until a job of its own is
// sized for them.
test "fault property uploadFile resume: a second run completes the object, sending nothing the session holds" {
    try test_util.fuzzBytes({}, resumeProperty, .{
        .random_runs = 100,
        .max_len = 256,
        .corpus = &.{
            "",
            // 600 KiB, a reset and a lost answer.
            "\xff\xff\xff\xff\xff\xff\xff\xff\x00\x00\x00\x00\x00\x00\x00\x00\xdc\xe6",
            // A corrupted chunk: the finish's checksum refuses it, the
            // session is cancelled, and the restart carries it whole.
            "\xff\xff\xff\xff\xff\xff\xff\xff\x00\x00\x00\x00\x00\x00\x00\x00\xf0\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00",
            // A session dropped behind the checkpoint's back.
            "\x80\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\xe6\x00\x00\xff",
        },
    });
}

test "uploadFile over real sockets: an upload its connection keeps killing resumes on a second client" {
    var fake: FakeMultipart = .init(testing.allocator, testing.io);
    defer fake.deinit();
    var server: test_util.MultipartServer = try .start(testing.io, &fake);
    var serving = try testing.io.concurrent(test_util.MultipartServer.run, .{ &server, testing.io });
    defer {
        _ = serving.cancel(testing.io) catch {};
        server.deinit(testing.io);
    }
    // Four resets exhaust the first client's four attempts on the second
    // chunk: that process is done, one chunk stored.
    var rules = [_]Script.Rule{.{ .at = chunk_size, .times = 6, .fault = .reset }};
    var script: Script = .{ .rules = &rules };
    fake.faults = script.plan();
    const data = try testing.allocator.alloc(u8, 600 * 1024 + 5);
    defer testing.allocator.free(data);
    fill(data, 74);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try sourceOn(&tmp, data);
    defer file.close(testing.io);
    var store: checkpoint.CheckpointFile = .init(testing.io, tmp.dir, "o.upload");
    const options: types.UploadOptions = .{ .checkpoint = store.checkpoint() };

    var url_buf: [64]u8 = undefined;
    var diag: Diagnostics = .{};
    var first: Client = try .init(testing.allocator, testing.io, .{
        .endpoint = .{ .url = server.url(&url_buf), .emulator = true },
        .diagnostics = &diag,
        .chunk_size = chunk_size,
        .retry = .{ .max_attempts = 3, .initial_backoff_ms = 1, .max_backoff_ms = 2 },
    });
    defer first.deinit();
    try testing.expectError(error.ConnectionResetByPeer, first.bucket("b").object("dir/o").uploadFile(file, options));
    try testing.expectEqual(1, fake.openSessions());
    try testing.expectEqual(chunk_size, fake.counts.session_bytes);

    var url_buf2: [64]u8 = undefined;
    var diag2: Diagnostics = .{};
    var second: Client = try .init(testing.allocator, testing.io, .{
        .endpoint = .{ .url = server.url(&url_buf2), .emulator = true },
        .diagnostics = &diag2,
        .chunk_size = chunk_size,
        .retry = .{ .max_attempts = 4, .initial_backoff_ms = 1, .max_backoff_ms = 2 },
    });
    defer second.deinit();
    var rules2 = [_]Script.Rule{};
    _ = &rules2;
    fake.faults = null;
    var info = try second.bucket("b").object("dir/o").uploadFile(file, options);
    defer info.deinit();
    try testing.expectEqual(data.len, info.value.size);
    try testing.expectEqual(core.crc32c.hash(data), info.value.crc32c.?);
    try testing.expectEqualSlices(u8, data, fake.object("dir/o").?.bytes);
    // Not one byte went twice, and the state is gone.
    try testing.expectEqual(data.len, fake.counts.session_bytes);
    try testing.expectEqual(0, fake.counts.session_stale_bytes);
    try testing.expectEqual(1, fake.counts.session_starts);
    try testing.expectEqual(0, fake.openSessions());
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(testing.io, "o.upload", .{}));
}

/// What std makes of `data` at `level`, which a compressed upload must
/// store byte for byte however it got there.
fn gzipOf(data: []const u8, level: u4) ![]u8 {
    const levels = [_]std.compress.flate.Compress.Options{ .level_1, .level_2, .level_3, .level_4, .level_5, .level_6, .level_7, .level_8, .level_9 };
    return test_util.gzipAlloc(testing.allocator, data, levels[level - 1]);
}

/// The fake's object: exactly `gzipOf(data, level)`, labelled gzip, and
/// described by `info`.
fn expectCompressed(fake: *const FakeMultipart, name: []const u8, data: []const u8, level: u4, info: types.ObjectInfo) !void {
    const want = try gzipOf(data, level);
    defer testing.allocator.free(want);
    const o = fake.object(name) orelse return error.TestExpectedObject;
    try testing.expectEqualSlices(u8, want, o.bytes);
    try testing.expectEqualSlices(u8, data, o.served orelse return error.TestExpectedGzipLabel);
    try testing.expectEqual(want.len, info.size);
    try testing.expectEqual(core.crc32c.hash(want), info.crc32c.?);
    try testing.expectEqualStrings("gzip", info.content_encoding.?);
}

test "compressed uploadFile: whole and empty, stored as std's gzip of the file" {
    var fake: FakeMultipart = .init(testing.allocator, testing.io);
    defer fake.deinit();
    var token: core.StaticToken = .{ .token = "ya29.t" };
    var diag: Diagnostics = .{};
    var client = try clientOn(&fake, &token, &diag, 3);
    defer client.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    for ([_]usize{ 0, 600 * 1024 }) |size| {
        const data = try testing.allocator.alloc(u8, size);
        defer testing.allocator.free(data);
        fill(data, 70);
        const file = try sourceOn(&tmp, data);
        defer file.close(testing.io);
        var info = try client.bucket("b").object("o").uploadFile(file, .{ .gzip = .{ .level = 3 }, .content_type = "text/csv" });
        defer info.deinit();
        try expectCompressed(&fake, "o", data, 3, info.value);
        try testing.expectEqualStrings("text/csv", fake.object("o").?.content_type);
    }
    try testing.expectEqual(2, fake.counts.session_starts);
}

test "compressed uploadFile: a corrupted chunk poisons the session, and the file is compressed again" {
    var fake: FakeMultipart = .init(testing.allocator, testing.io);
    defer fake.deinit();
    var token: core.StaticToken = .{ .token = "ya29.t" };
    var diag: Diagnostics = .{};
    var client = try clientOn(&fake, &token, &diag, 3);
    defer client.deinit();
    const data = try testing.allocator.alloc(u8, 600 * 1024);
    defer testing.allocator.free(data);
    fill(data, 71);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try sourceOn(&tmp, data);
    defer file.close(testing.io);
    var rules = [_]Script.Rule{.{ .fault = .corrupt }};
    var script: Script = .{ .rules = &rules };
    fake.faults = script.plan();
    var info = try client.bucket("b").object("o").uploadFile(file, .{ .gzip = .{} });
    defer info.deinit();
    try expectCompressed(&fake, "o", data, 6, info.value);
    try testing.expectEqual(2, fake.counts.session_starts);
    try testing.expectEqual(1, fake.counts.session_cancels);
}

test "compressed uploadFile: a run that dies partway resumes on a second client, passing over what the session holds" {
    var fake: FakeMultipart = .init(testing.allocator, testing.io);
    defer fake.deinit();
    var token: core.StaticToken = .{ .token = "ya29.t" };
    // Noise, so the compressed stream spans three chunks.
    const data = try testing.allocator.alloc(u8, 600 * 1024);
    defer testing.allocator.free(data);
    fill(data, 72);
    const compressed = try gzipOf(data, 6);
    defer testing.allocator.free(compressed);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try sourceOn(&tmp, data);
    defer file.close(testing.io);
    var store: checkpoint.CheckpointFile = .init(testing.io, tmp.dir, "o.upload");
    const options: types.UploadOptions = .{ .checkpoint = store.checkpoint(), .gzip = .{} };

    // The first process stores two chunks; the request for the third is
    // canceled with it, which leaves the session for the checkpoint.
    var rules = [_]Script.Rule{.{ .at = 2 * chunk_size, .fault = .canceled }};
    var script: Script = .{ .rules = &rules };
    fake.faults = script.plan();
    {
        var diag: Diagnostics = .{};
        var first = try clientOn(&fake, &token, &diag, 3);
        defer first.deinit();
        try testing.expectError(error.Canceled, first.bucket("b").object("dir/o").uploadFile(file, options));
    }
    try testing.expectEqual(1, fake.openSessions());
    try testing.expectEqual(0, fake.counts.session_cancels);
    try testing.expectEqual(2 * chunk_size, fake.counts.session_bytes);
    fake.faults = null;

    // The second process compresses the file again, passes over the two
    // chunks the session holds, and sends only the rest.
    var diag: Diagnostics = .{};
    var second = try clientOn(&fake, &token, &diag, 3);
    defer second.deinit();
    var info = try second.bucket("b").object("dir/o").uploadFile(file, options);
    defer info.deinit();
    try expectCompressed(&fake, "dir/o", data, 6, info.value);
    try testing.expectEqual(1, fake.counts.session_starts);
    try testing.expectEqual(compressed.len, fake.counts.session_bytes);
    try testing.expectEqual(0, fake.counts.session_stale_bytes);
    try testing.expectEqual(0, fake.openSessions());
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(testing.io, "o.upload", .{}));
}

test "compressed uploadFile: a checkpoint of a finished upload compresses the file again to check it, and sends nothing" {
    var fake: FakeMultipart = .init(testing.allocator, testing.io);
    defer fake.deinit();
    var token: core.StaticToken = .{ .token = "ya29.t" };
    var diag: Diagnostics = .{};
    var client = try clientOn(&fake, &token, &diag, 3);
    defer client.deinit();
    const data = try testing.allocator.alloc(u8, 400 * 1024);
    defer testing.allocator.free(data);
    fill(data, 73);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try sourceOn(&tmp, data);
    defer file.close(testing.io);
    // The process dies between the finish and the clear.
    var saved: MemoryCheckpoint = .{ .gpa = testing.allocator, .keep_on_clear = true };
    defer saved.deinit();
    const options: types.UploadOptions = .{ .checkpoint = saved.checkpoint(), .gzip = .{ .level = 2 } };
    var first = try client.bucket("b").object("o").uploadFile(file, options);
    first.deinit();
    const bytes_before = fake.counts.session_bytes;

    saved.keep_on_clear = false;
    var info = try client.bucket("b").object("o").uploadFile(file, options);
    defer info.deinit();
    try expectCompressed(&fake, "o", data, 2, info.value);
    try testing.expectEqual(bytes_before, fake.counts.session_bytes);
    try testing.expectEqual(1, fake.counts.session_starts);
    try testing.expectEqual(null, saved.stored);
}

/// Replaces the saved state's fields as `edit` says, as another process,
/// another version or a forger might have written it.
fn forgeState(saved: *MemoryCheckpoint, edit: anytype) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var state = (try checkpoint.parse(arena.allocator(), saved.stored.?)).upload_file;
    inline for (std.meta.fields(@TypeOf(edit))) |field| @field(state, field.name) = @field(edit, field.name);
    const forged = try checkpoint.encodeAlloc(testing.allocator, .{ .upload_file = state });
    testing.allocator.free(saved.stored.?);
    saved.stored = forged;
}

/// A first run that stores two chunks of the file compressed at `level`
/// and dies, leaving its checkpoint.
fn dieAfterTwoChunks(fake: *FakeMultipart, token: *core.StaticToken, file: std.Io.File, saved: *MemoryCheckpoint, level: u4) !void {
    var rules = [_]Script.Rule{.{ .at = 2 * chunk_size, .fault = .canceled }};
    var script: Script = .{ .rules = &rules };
    fake.faults = script.plan();
    defer fake.faults = null;
    var diag: Diagnostics = .{};
    var first = try clientOn(fake, token, &diag, 3);
    defer first.deinit();
    const options: types.UploadOptions = .{ .checkpoint = saved.checkpoint(), .gzip = .{ .level = level } };
    try testing.expectError(error.Canceled, first.bucket("b").object("o").uploadFile(file, options));
    try testing.expectEqual(2 * chunk_size, fake.sessions.items[fake.sessions.items.len - 1].bytes.items.len);
}

test "compressed uploadFile: a checkpoint at another level, or from another Zig, cancels its session and starts over" {
    const data = try testing.allocator.alloc(u8, 700 * 1024);
    defer testing.allocator.free(data);
    fill(data, 74);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try sourceOn(&tmp, data);
    defer file.close(testing.io);
    var token: core.StaticToken = .{ .token = "ya29.t" };

    for ([_]bool{ false, true }) |other_zig| {
        var fake: FakeMultipart = .init(testing.allocator, testing.io);
        defer fake.deinit();
        var saved: MemoryCheckpoint = .{ .gpa = testing.allocator };
        defer saved.deinit();
        try dieAfterTwoChunks(&fake, &token, file, &saved, 1);
        if (other_zig) try forgeState(&saved, .{ .gzip = checkpoint.State.UploadFile.Gzip{ .level = 1, .zig = "0.15.1" } });

        var diag: Diagnostics = .{};
        var client = try clientOn(&fake, &token, &diag, 3);
        defer client.deinit();
        const level: u4 = if (other_zig) 1 else 9;
        const bytes_before = fake.counts.session_bytes;
        var info = try client.bucket("b").object("o").uploadFile(file, .{ .checkpoint = saved.checkpoint(), .gzip = .{ .level = level } });
        defer info.deinit();
        try expectCompressed(&fake, "o", data, level, info.value);
        try testing.expectEqual(2, fake.counts.session_starts);
        try testing.expectEqual(1, fake.counts.session_cancels);
        try testing.expectEqual(null, saved.stored);
        // The old session was cancelled before a byte moved: only the new
        // one got any.
        try testing.expectEqual(info.value.size, fake.counts.session_bytes - bytes_before);
    }
}

test "compressed uploadFile: a session holding other bytes is refused at the finish, or holds more than the file makes, and the upload starts over" {
    const data = try testing.allocator.alloc(u8, 700 * 1024);
    defer testing.allocator.free(data);
    fill(data, 75);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try sourceOn(&tmp, data);
    defer file.close(testing.io);
    var token: core.StaticToken = .{ .token = "ya29.t" };

    // Level 1's bytes in the session, a state forged to say level 9: the
    // file at level 9 makes other bytes of about the same length, which
    // the finishing checksum refuses.
    {
        var fake: FakeMultipart = .init(testing.allocator, testing.io);
        defer fake.deinit();
        var saved: MemoryCheckpoint = .{ .gpa = testing.allocator };
        defer saved.deinit();
        try dieAfterTwoChunks(&fake, &token, file, &saved, 1);
        try forgeState(&saved, .{ .gzip = checkpoint.State.UploadFile.Gzip{ .level = 9, .zig = builtin.zig_version_string } });
        var diag: Diagnostics = .{};
        var client = try clientOn(&fake, &token, &diag, 3);
        defer client.deinit();
        var info = try client.bucket("b").object("o").uploadFile(file, .{ .checkpoint = saved.checkpoint(), .gzip = .{ .level = 9 } });
        defer info.deinit();
        try expectCompressed(&fake, "o", data, 9, info.value);
        try testing.expectEqual(2, fake.counts.session_starts);
        try testing.expectEqual(1, fake.counts.session_cancels);
    }

    // Another file's session, 512 KiB of it, under a state forged to name
    // this small file, which compresses to less than that.
    {
        var fake: FakeMultipart = .init(testing.allocator, testing.io);
        defer fake.deinit();
        var saved: MemoryCheckpoint = .{ .gpa = testing.allocator };
        defer saved.deinit();
        try dieAfterTwoChunks(&fake, &token, file, &saved, 6);
        const small = "a small file\n" ** 1000;
        var tmp2 = testing.tmpDir(.{});
        defer tmp2.cleanup();
        const small_file = try sourceOn(&tmp2, small);
        defer small_file.close(testing.io);
        try forgeState(&saved, .{ .size = @as(u64, small.len), .mtime = (try small_file.stat(testing.io)).mtime.nanoseconds });
        var diag: Diagnostics = .{};
        var client = try clientOn(&fake, &token, &diag, 3);
        defer client.deinit();
        var info = try client.bucket("b").object("o").uploadFile(small_file, .{ .checkpoint = saved.checkpoint(), .gzip = .{} });
        defer info.deinit();
        try expectCompressed(&fake, "o", small, 6, info.value);
        try testing.expectEqual(2, fake.counts.session_starts);
        try testing.expectEqual(1, fake.counts.session_cancels);
    }
}

fn compressedUploadWithCheckpoint(gpa: Allocator) !void {
    var fake: FakeMultipart = .init(gpa, testing.io);
    defer fake.deinit();
    var token: core.StaticToken = .{ .token = "ya29.t" };
    var diag: Diagnostics = .{};
    var client = try Client.init(gpa, testing.io, .{
        .token_provider = token.provider(),
        .transport = fake.transport(),
        .diagnostics = &diag,
        .chunk_size = chunk_size,
        .retry = .{ .max_attempts = 2, .initial_backoff_ms = 1, .max_backoff_ms = 2 },
    });
    defer client.deinit();
    var data: [300 * 1024]u8 = undefined;
    fill(&data, 76);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try sourceOn(&tmp, &data);
    defer file.close(testing.io);
    var saved: MemoryCheckpoint = .{ .gpa = gpa };
    defer saved.deinit();
    var info = try client.bucket("b").object("o").uploadFile(file, .{ .checkpoint = saved.checkpoint(), .gzip = .{} });
    info.deinit();
}

test "compressed uploadFile with a checkpoint: every allocation failure is OutOfMemory, and nothing leaks" {
    try testing.checkAllAllocationFailures(testing.allocator, compressedUploadWithCheckpoint, .{});
}

/// `resumeUnderFaults` for a compressed upload: whatever the faults cut,
/// the second run ends with exactly std's compression of the file, which
/// shows a resume makes the same bytes as the run that began it, and a
/// clean resume of a live session sends none the session holds.
fn compressedResumeUnderFaults(input: []const u8) !void {
    var g: test_util.ByteGen = .init(input);
    const level = g.intRange(u4, 1, 9);
    const size = g.intRange(usize, 0, 700 * 1024);
    const data = try testing.allocator.alloc(u8, size);
    defer testing.allocator.free(data);
    // Noise, or noise diluted with runs, so the compressed stream is
    // anywhere from a few bytes to three chunks.
    fill(data, g.int(u64));
    const runs = g.intRange(u8, 0, 3);
    if (runs > 0) for (data, 0..) |*b, i| {
        if ((i / 64) % 4 < runs) b.* = 'x';
    };
    const compressed = try gzipOf(data, level);
    defer testing.allocator.free(compressed);

    var fake: FakeMultipart = .init(testing.allocator, testing.io);
    defer fake.deinit();
    var token: core.StaticToken = .{ .token = "ya29.t" };
    var saved: MemoryCheckpoint = .{ .gpa = testing.allocator };
    defer saved.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try sourceOn(&tmp, data);
    defer file.close(testing.io);
    const options: types.UploadOptions = .{ .checkpoint = saved.checkpoint(), .gzip = .{ .level = level } };

    var chooser: Chooser = .{ .bytes = g.rest() };
    fake.faults = chooser.plan();
    var first_diag: Diagnostics = .{};
    var first = try clientOn(&fake, &token, &first_diag, 2);
    defer first.deinit();
    if (first.bucket("b").object("o").uploadFile(file, options)) |finished| {
        var owned = finished;
        owned.deinit();
    } else |err| {
        errdefer std.debug.print("first run: {t}: {s}\n", .{ err, first_diag.message() });
        try testing.expect(chooser.faulted);
    }

    var held_before: u64 = 0;
    var resumed_session = false;
    if (saved.stored) |bytes| {
        var state_arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer state_arena.deinit();
        const s = (try checkpoint.parse(state_arena.allocator(), bytes)).upload_file;
        try testing.expectEqual(level, s.gzip.?.level);
        for (fake.sessions.items) |session| {
            if (!std.mem.endsWith(u8, s.session, session.id)) continue;
            if (session.done == null) {
                resumed_session = true;
                held_before = session.bytes.items.len;
            }
        }
    }
    const bytes_before = fake.counts.session_bytes;
    const starts_before = fake.counts.session_starts;

    fake.faults = null;
    var diag: Diagnostics = .{};
    var second = try clientOn(&fake, &token, &diag, 4);
    defer second.deinit();
    const target = second.bucket("b").object("o");
    var info = target.uploadFile(file, options) catch |err| {
        errdefer std.debug.print("second run: {t}: {s}\n", .{ err, diag.message() });
        // The checksum backstop, as for an uncompressed file: a corrupted
        // chunk stored with every byte in, finished by the second run's
        // hashless status query, found wrong and deleted.
        try testing.expectEqual(error.ChecksumMismatch, err);
        try testing.expect(chooser.faulted);
        try testing.expectEqual(null, saved.stored);
        try testing.expect(fake.object("o") == null);
        var third = try target.uploadFile(file, options);
        defer third.deinit();
        try expectCompressed(&fake, "o", data, level, third.value);
        return;
    };
    defer info.deinit();
    try expectCompressed(&fake, "o", data, level, info.value);
    try testing.expectEqual(null, saved.stored);
    if (resumed_session and fake.counts.session_starts == starts_before) {
        try testing.expectEqual(compressed.len - held_before, fake.counts.session_bytes - bytes_before);
        try testing.expectEqual(0, fake.counts.session_stale_bytes);
    }
    for (fake.sessions.items) |s| {
        if (s.done == null) try testing.expectEqual(0, s.bytes.items.len);
    }
}

fn compressedResumeProperty(_: void, input: []const u8) !void {
    try compressedResumeUnderFaults(input);
}

// Compressing up to 700 KiB several times a run in Debug, over a real
// file: named out of the nightly filters, like the uncompressed resume
// property.
test "fault property compressed uploadFile resume: a second run ends with std's bytes, sending nothing the session holds" {
    try test_util.fuzzBytes({}, compressedResumeProperty, .{
        .random_runs = 60,
        .max_len = 256,
        .corpus = &.{
            "",
            // 700 KiB of noise at level 9, a reset and a lost answer.
            "\x09\xff\xff\xff\xff\xff\xff\xff\xff\x00\x00\x00\x00\x00\x00\x00\x00\x00\xdc\xe6",
            // A corrupted chunk: refused at the finish, started over.
            "\x06\xff\xff\xff\xff\xff\xff\xff\xff\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\xf0\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00",
            // Canceled partway: the second run passes over what it holds.
            "\x01\xff\xff\xff\xff\xff\xff\xff\xff\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\xe6",
        },
    });
}

test "compressed uploadFile: a file shorter than it measured is caught, and nothing is stored" {
    var fake: FakeMultipart = .init(testing.allocator, testing.io);
    defer fake.deinit();
    var token: core.StaticToken = .{ .token = "ya29.t" };
    var diag: Diagnostics = .{};
    var client = try clientOn(&fake, &token, &diag, 3);
    defer client.deinit();
    const data = "a line that repeats\n" ** 5000;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try sourceOn(&tmp, data);
    defer file.close(testing.io);
    // A stream told the file is longer than it is, as one that shrank
    // after it was measured would read.
    const stream = try gzip_upload.Stream.create(&client, .{ .file = .{ .f = file, .size = data.len + 100 } }, 6, null);
    defer stream.destroy();
    try testing.expectError(error.ReadFailed, gzip_upload.uploadResumable(stream, &client, "b", "o", .{ .gzip = .{} }));
    try testing.expect(std.mem.indexOf(u8, diag.message(), "it changed under the upload") != null);
    try testing.expect(fake.object("o") == null);
}
