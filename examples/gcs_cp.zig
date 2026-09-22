//! Copies a file into Cloud Storage, or an object out of it, streaming both
//! ways in constant memory: one upload chunk going up, a few kilobytes
//! coming down, whatever the size.
//!
//!     zig build example-gcs_cp -- backup.tar gs://my-bucket/backups/backup.tar
//!     zig build example-gcs_cp -- gs://my-bucket/backups/backup.tar restored.tar
//!     ... -- backup.tar gs://my-bucket/backup.tar --no-clobber
//!
//! Both directions are checksummed end to end. An upload hashes the file as
//! it streams and compares the result with the finished object; a download
//! is checked against the checksum Cloud Storage keeps, and goes to
//! `<file>.part` first, renamed into place only once it has verified.
//! `--no-clobber` refuses to replace an existing object, with a
//! precondition the server enforces.
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

const usage = "usage: gcs_cp <file> gs://<bucket>/<object> [--no-clobber]\n" ++
    "       gcs_cp gs://<bucket>/<object> <file>\n";

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    var stdout_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &stdout_buffer);
    const out = &stdout.interface;

    var paths: [2][]const u8 = undefined;
    var count: usize = 0;
    var no_clobber = false;
    const args = try init.minimal.args.toSlice(arena);
    for (args[@min(1, args.len)..]) |arg| {
        if (std.mem.eql(u8, arg, "--no-clobber")) {
            no_clobber = true;
        } else if (count < paths.len) {
            paths[count] = arg;
            count += 1;
        } else {
            count += 1;
        }
    }
    const from_remote = if (count == 2) Remote.parse(paths[0]) else null;
    const to_remote = if (count == 2) Remote.parse(paths[1]) else null;
    // Exactly one side is in Cloud Storage.
    if (count != 2 or (from_remote == null) == (to_remote == null)) {
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
        try upload(&client, init.io, paths[0], remote, no_clobber, out, &diag, started);
    } else {
        try download(&client, init.io, arena, from_remote.?, paths[1], out, &diag, started);
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
    out: *std.Io.Writer,
    diag: *const storage.Diagnostics,
    started: std.Io.Timestamp,
) !void {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    // A declared size lets the server check the upload is whole, and the
    // library that the file neither shrank nor grew while it was read.
    const size = (try file.stat(io)).size;
    var buffer: [64 * 1024]u8 = undefined;
    var reader = file.reader(io, &buffer);

    var info = client.bucket(remote.bucket).object(remote.name).uploadFrom(&reader.interface, .{
        .size = size,
        .preconditions = if (no_clobber) .does_not_exist else .{},
    }) catch |err| switch (err) {
        error.FailedPrecondition => if (no_clobber) {
            std.debug.print("gs://{s}/{s} exists, and --no-clobber keeps it\n", .{ remote.bucket, remote.name });
            return err;
        } else return fail(err, diag),
        else => return fail(err, diag),
    };
    defer info.deinit();
    const ms = elapsedMs(io, started);
    try out.print("{s} -> gs://{s}/{s}: {d} bytes in {d} ms ({d:.1} MiB/s), generation {d}, crc32c {?x:0>8}\n", .{
        path, remote.bucket, remote.name, info.value.size, ms, mibPerSecond(info.value.size, ms), info.value.generation, info.value.crc32c,
    });
}

fn download(
    client: *storage.Client,
    io: std.Io,
    arena: std.mem.Allocator,
    remote: Remote,
    path: []const u8,
    out: *std.Io.Writer,
    diag: *const storage.Diagnostics,
    started: std.Io.Timestamp,
) !void {
    // The bytes land in a file of their own until they have verified, so a
    // failed or corrupted download never leaves a file that looks finished.
    const cwd = std.Io.Dir.cwd();
    const part = try std.fmt.allocPrint(arena, "{s}.part", .{path});
    var finished = false;
    defer if (!finished) cwd.deleteFile(io, part) catch {};

    const result = r: {
        const file = try cwd.createFile(io, part, .{});
        defer file.close(io);
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
    try out.print("gs://{s}/{s} -> {s}: {d} bytes in {d} ms ({d:.1} MiB/s), generation {d}, checksum {s}\n", .{
        remote.bucket,
        remote.name,
        path,
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
