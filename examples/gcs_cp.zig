//! Copies a file into Cloud Storage, or an object out of it, streaming both
//! ways in constant memory: one upload chunk going up, a few kilobytes
//! coming down, whatever the size.
//!
//!     zig build example-gcs_cp -- backup.tar gs://my-bucket/backups/backup.tar
//!     zig build example-gcs_cp -- gs://my-bucket/backups/backup.tar restored.tar
//!     ... -- backup.tar gs://my-bucket/backup.tar --no-clobber
//!     ... -- backup.tar gs://my-bucket/backup.tar --parallel 8
//!     ... -- gs://my-bucket/backup.tar restored.tar --parallel 8
//!     ... -- backup.tar gs://my-bucket/backup.tar --resume backup.tar.state
//!
//! Both directions are checksummed end to end. An upload reads the file at
//! offsets, a chunk at a time, and its last request carries the file's
//! CRC32C, so Cloud Storage refuses an object whose bytes differ; a
//! download is checked against the checksum Cloud Storage keeps, and goes
//! to `<file>.part` first, renamed into place only once it has verified.
//! `--no-clobber` refuses to replace an existing object, with a
//! precondition the server enforces. `--parallel N` moves the file in
//! parts, N at a time on connections of their own, for a large file on a
//! fast link: an upload in parts Cloud Storage joins, a download in ranges
//! written at their offsets. With `--no-clobber` too, a parallel upload
//! finishes under a temporary name and moves into place only if nothing
//! took the name meanwhile.
//!
//! `--resume STATE` keeps what a later run needs in the file STATE, so a
//! copy that failed, or whose process was killed, carries on where it
//! stopped when the same command runs again: an upload in the session or
//! the parts Cloud Storage already holds, a download in the ranges
//! `<file>.part` already holds. A download that resumes goes in ranges,
//! one at a time unless `--parallel` says more. The state is removed once
//! the copy is done, and holds an upload's session URL, which lets anyone
//! who has it write the object: keep it as private as a credential.
//!
//! Credentials come from `auth.findDefault`: the file
//! `GOOGLE_APPLICATION_CREDENTIALS` names, then the one `gcloud auth
//! application-default login` writes, then the metadata server. With
//! `STORAGE_EMULATOR_HOST` set, the copy goes to that emulator instead,
//! without credentials.

const std = @import("std");
const auth = @import("auth");
const storage = @import("storage");

/// Show the library's warnings, such as a resumed transfer.
pub const std_options: std.Options = .{
    .log_scope_levels = &.{
        .{ .scope = .gcp_auth, .level = .warn },
        .{ .scope = .gcp_storage, .level = .warn },
    },
};

const usage = "usage: gcs_cp <file> gs://<bucket>/<object> [--no-clobber] [--parallel N] [--resume STATE]\n" ++
    "       gcs_cp gs://<bucket>/<object> <file> [--parallel N] [--resume STATE]\n";

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    var stdout_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &stdout_buffer);
    const out = &stdout.interface;

    var paths: [2][]const u8 = undefined;
    var count: usize = 0;
    var no_clobber = false;
    var parallel: ?u16 = null;
    var state: ?[]const u8 = null;
    var bad = false;
    const args = try init.minimal.args.toSlice(arena);
    var i: usize = @min(1, args.len);
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--no-clobber")) {
            no_clobber = true;
        } else if (std.mem.eql(u8, arg, "--parallel")) {
            i += 1;
            parallel = if (i < args.len) std.fmt.parseInt(u16, args[i], 10) catch null else null;
            if (parallel == null) bad = true;
        } else if (std.mem.eql(u8, arg, "--resume")) {
            i += 1;
            state = if (i < args.len) args[i] else null;
            if (state == null) bad = true;
        } else if (count < paths.len) {
            paths[count] = arg;
            count += 1;
        } else {
            count += 1;
        }
    }
    const from_remote = if (count == 2) Remote.parse(paths[0]) else null;
    const to_remote = if (count == 2) Remote.parse(paths[1]) else null;
    // Exactly one side is in Cloud Storage, and only an upload can refuse
    // to replace what is there.
    if (bad or count != 2 or (from_remote == null) == (to_remote == null) or
        (no_clobber and to_remote == null))
    {
        try out.writeAll(usage);
        return out.flush();
    }

    var diag: storage.Diagnostics = .{};
    const endpoint = storage.Endpoint.fromEnv(init.environ_map);
    // An emulator never sees credentials; production always needs them.
    var creds: ?auth.Credentials = null;
    defer if (creds) |*c| c.deinit();
    if (endpoint == null) {
        var lookup = try auth.Lookup.fromEnv(init.environ_map, arena);
        lookup.diagnostics = &diag;
        creds = auth.findDefault(init.gpa, init.io, lookup, .{}) catch |err| return fail(err, &diag);
    }

    var client = storage.Client.init(init.gpa, init.io, .{
        .endpoint = endpoint,
        .token_provider = if (creds) |c| c.provider() else null,
        .diagnostics = &diag,
    }) catch |err| return fail(err, &diag);
    defer client.deinit();

    const started = std.Io.Clock.awake.now(init.io);
    if (to_remote) |remote| {
        try upload(&client, init.io, paths[0], remote, no_clobber, parallel, state, out, &diag, started);
    } else {
        try download(&client, init.io, arena, from_remote.?, paths[1], parallel, state, out, &diag, started);
    }
    try out.flush();
}

/// `gs://bucket/object`, split. The object name is everything after the
/// bucket's slash, slashes and all.
const Remote = struct {
    bucket: []const u8,
    name: []const u8,

    fn parse(text: []const u8) ?Remote {
        const rest = if (std.mem.startsWith(u8, text, "gs://")) text["gs://".len..] else return null;
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
        if (slash == 0 or slash + 1 == rest.len) return null;
        return .{ .bucket = rest[0..slash], .name = rest[slash + 1 ..] };
    }
};

fn upload(
    client: *storage.Client,
    io: std.Io,
    path: []const u8,
    remote: Remote,
    no_clobber: bool,
    parallel: ?u16,
    state: ?[]const u8,
    out: *std.Io.Writer,
    diag: *const storage.Diagnostics,
    started: std.Io.Timestamp,
) !void {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const preconditions: storage.Preconditions = if (no_clobber) .does_not_exist else .{};
    var saved: storage.CheckpointFile = .init(io, std.Io.Dir.cwd(), state orelse "");
    const checkpoint: ?storage.Checkpoint = if (state != null) saved.checkpoint() else null;
    if (parallel) |concurrency| {
        // Each part is read at its own offset, and checked on its own.
        var info = client.bucket(remote.bucket).object(remote.name).uploadParallel(.{ .file = file }, .{
            .concurrency = concurrency,
            .preconditions = preconditions,
            .checkpoint = checkpoint,
        }) catch |err| return refused(err, no_clobber, remote, diag, io, state);
        defer info.deinit();
        const ms = elapsedMs(io, started);
        try out.print("{s} -> gs://{s}/{s} through uploadParallel, concurrency {d}: {d} bytes in {d} ms ({d:.1} MiB/s), generation {d}, crc32c {?x:0>8}\n", .{
            path, remote.bucket, remote.name, concurrency, info.value.size, ms, mibPerSecond(info.value.size, ms), info.value.generation, info.value.crc32c,
        });
        return;
    }
    // The file is read at offsets, so a lost session starts over from it,
    // and a later run can carry on from what the server holds.
    var info = client.bucket(remote.bucket).object(remote.name).uploadFile(file, .{
        .preconditions = preconditions,
        .checkpoint = checkpoint,
    }) catch |err| return refused(err, no_clobber, remote, diag, io, state);
    defer info.deinit();
    const ms = elapsedMs(io, started);
    try out.print("{s} -> gs://{s}/{s}: {d} bytes in {d} ms ({d:.1} MiB/s), generation {d}, crc32c {?x:0>8}\n", .{
        path, remote.bucket, remote.name, info.value.size, ms, mibPerSecond(info.value.size, ms), info.value.generation, info.value.crc32c,
    });
}

/// An upload's failure, told as `--no-clobber`'s refusal where it is one.
fn refused(err: anyerror, no_clobber: bool, remote: Remote, diag: *const storage.Diagnostics, io: std.Io, state: ?[]const u8) anyerror {
    if (err == error.FailedPrecondition and no_clobber) {
        std.debug.print("gs://{s}/{s} exists, and --no-clobber keeps it\n", .{ remote.bucket, remote.name });
        return err;
    }
    return failResumable(err, diag, io, state);
}

/// A failure, and whether running the command again carries the copy on:
/// the library keeps the state only for a transfer that can resume.
fn failResumable(err: anyerror, diag: *const storage.Diagnostics, io: std.Io, state: ?[]const u8) anyerror {
    const failed = fail(err, diag);
    if (state) |path| if (stateKept(io, path)) {
        std.debug.print("{s} holds where the copy stopped: run the same command again to carry it on\n", .{path});
    };
    return failed;
}

fn stateKept(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

fn download(
    client: *storage.Client,
    io: std.Io,
    arena: std.mem.Allocator,
    remote: Remote,
    path: []const u8,
    parallel: ?u16,
    state: ?[]const u8,
    out: *std.Io.Writer,
    diag: *const storage.Diagnostics,
    started: std.Io.Timestamp,
) !void {
    // The bytes land in a file of their own until they have verified, so a
    // failed or corrupted download never leaves a file that looks finished.
    // One a later run can carry on stays, with the state that says which
    // ranges it holds.
    const cwd = std.Io.Dir.cwd();
    const part = try std.fmt.allocPrint(arena, "{s}.part", .{path});
    var finished = false;
    defer if (!finished and !(state != null and stateKept(io, state.?))) cwd.deleteFile(io, part) catch {};
    var saved: storage.CheckpointFile = .init(io, cwd, state orelse "");

    const result = r: {
        // A resumed download reads back the ranges the file holds, so it
        // opens the file as it is.
        const file = try cwd.createFile(io, part, .{ .read = state != null, .truncate = state == null });
        defer file.close(io);
        if (parallel != null or state != null) {
            // Each range is written at its own offset, and the ranges'
            // checksums combine into the whole object's.
            break :r client.bucket(remote.bucket).object(remote.name).downloadParallel(.{ .file = file }, .{
                .concurrency = parallel orelse 1,
                .checkpoint = if (state != null) saved.checkpoint() else null,
            }) catch |err| return failResumable(err, diag, io, state);
        }
        var buffer: [64 * 1024]u8 = undefined;
        var writer = file.writer(io, &buffer);
        const got = client.bucket(remote.bucket).object(remote.name).download(&writer.interface, .{}) catch |err|
            return fail(err, diag);
        // The library never flushes a caller's writer: the buffer is ours.
        try writer.interface.flush();
        break :r got;
    };
    try std.Io.Dir.rename(cwd, part, cwd, path, io);
    finished = true;

    const ms = elapsedMs(io, started);
    try out.print("gs://{s}/{s} -> {s}{s}: {d} bytes in {d} ms ({d:.1} MiB/s), generation {d}, checksum {s}\n", .{
        remote.bucket,
        remote.name,
        path,
        if (parallel != null or state != null) " through downloadParallel" else "",
        result.bytes_written,
        ms,
        mibPerSecond(result.bytes_written, ms),
        result.generation,
        if (result.checksum_verified) "verified" else "not verifiable (decompressed in transit, or none sent)",
    });
}

fn elapsedMs(io: std.Io, started: std.Io.Timestamp) i64 {
    return started.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds();
}

fn mibPerSecond(bytes: u64, ms: i64) f64 {
    const seconds = @as(f64, @floatFromInt(@max(ms, 1))) / 1000.0;
    return @as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0) / seconds;
}

fn fail(err: anyerror, diag: *const storage.Diagnostics) anyerror {
    std.debug.print("error.{t}", .{err});
    if (diag.http_status != 0) std.debug.print(" (HTTP {d} {s})", .{ diag.http_status, diag.status() });
    if (diag.message().len != 0) std.debug.print(": {s}", .{diag.message()});
    std.debug.print("\n", .{});
    return err;
}
