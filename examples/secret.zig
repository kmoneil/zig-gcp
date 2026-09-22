//! Reads one secret and reports which version answered. The bytes go to
//! standard output only when `--print` asks for them.
//!
//!     GOOGLE_CLOUD_PROJECT=my-project zig build example-secret -- db-password
//!     ... -- db-password 3            # a version number, or an alias
//!     ... -- db-password latest --print
//!     ... -- db-password --location=europe-west3
//!
//! Credentials come from `auth.findDefault`: the file
//! `GOOGLE_APPLICATION_CREDENTIALS` names, then the one `gcloud auth
//! application-default login` writes, then the metadata server. The
//! principal needs `secretmanager.versions.access` on the secret.

const std = @import("std");
const auth = @import("auth");
const secret_manager = @import("secret_manager");

/// Show the library's warnings. `--debug` is the quickest way to see each
/// request, though never a secret: the module logs no payload, no size and
/// no checksum.
pub const std_options: std.Options = .{
    .log_scope_levels = &.{
        .{ .scope = .gcp_auth, .level = .warn },
        .{ .scope = .gcp_secret_manager, .level = .warn },
    },
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    var stdout_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &stdout_buffer);
    const out = &stdout.interface;
    var diag: secret_manager.Diagnostics = .{};

    var id: ?[]const u8 = null;
    var version: ?[]const u8 = null;
    var location: ?[]const u8 = null;
    var print_bytes = false;
    const args = try init.minimal.args.toSlice(arena);
    for (args[@min(1, args.len)..]) |arg| {
        if (std.mem.eql(u8, arg, "--print")) {
            print_bytes = true;
        } else if (std.mem.startsWith(u8, arg, "--location=")) {
            location = arg["--location=".len..];
        } else if (std.mem.eql(u8, arg, "--debug")) {
            // Handled by std_options; listed here so it is not read as an id.
        } else if (id == null) {
            id = arg;
        } else {
            version = arg;
        }
    }
    const secret_id = id orelse {
        try out.print("usage: secret <id> [version] [--location=<id>] [--print]\n", .{});
        return out.flush();
    };

    var lookup = try auth.Lookup.fromEnv(init.environ_map, arena);
    lookup.diagnostics = &diag;
    var creds = auth.findDefault(init.gpa, init.io, lookup, .{}) catch |err| return fail(err, &diag);
    defer creds.deinit();

    const detected = creds.projectId(init.io, arena) catch |err| return fail(err, &diag);
    const project = init.environ_map.get("GOOGLE_CLOUD_PROJECT") orelse
        detected orelse
        creds.quotaProjectId() orelse
        {
            try out.print("set GOOGLE_CLOUD_PROJECT to name the project\n", .{});
            return out.flush();
        };

    var client = secret_manager.Client.init(init.gpa, init.io, .{
        .project_id = project,
        .location = location,
        .token_provider = creds.provider(),
        .diagnostics = &diag,
    }) catch |err| return fail(err, &diag);
    defer client.deinit();

    var value = client.secret(secret_id).access(parseRef(version)) catch |err| return fail(err, &diag);
    // Wipes the bytes, whatever happens next.
    defer value.deinit();

    try out.print("read {s}\n", .{value.version_name});
    try out.print("checksum verified: {}\n", .{value.checksum_verified});
    if (print_bytes) {
        // The library never trims: a secret written with `echo` ends in a
        // newline of its own.
        try out.writeAll(value.bytes());
        if (!std.mem.endsWith(u8, value.bytes(), "\n")) try out.writeAll("\n");
    } else {
        // Printing the value itself gives `[REDACTED]`, never the bytes.
        try out.print("value: {f} (pass --print for the bytes)\n", .{value});
    }
    try out.flush();
}

/// `latest`, a number, or an alias.
fn parseRef(version: ?[]const u8) secret_manager.VersionRef {
    const text = version orelse return .latest;
    if (std.mem.eql(u8, text, "latest")) return .latest;
    if (std.fmt.parseInt(u64, text, 10)) |number| return .{ .number = number } else |_| {}
    return .{ .alias = text };
}

fn fail(err: anyerror, diag: *const secret_manager.Diagnostics) anyerror {
    std.debug.print("error.{t}", .{err});
    if (diag.http_status != 0) std.debug.print(" (HTTP {d} {s})", .{ diag.http_status, diag.status() });
    if (diag.message().len != 0) std.debug.print(": {s}", .{diag.message()});
    std.debug.print("\n", .{});
    return err;
}
