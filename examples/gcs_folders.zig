//! Works a hierarchical bucket's folders, and any uniform bucket's managed
//! folders, from the command line.
//!
//!     zig build example-gcs_folders -- layout my-bucket
//!     ... -- mkdir my-bucket reports/2026/ --recursive
//!     ... -- ls my-bucket [reports/] [--one-level]
//!     ... -- mv my-bucket reports/ archive/
//!     ... -- rm my-bucket archive/2026/
//!     ... -- grant my-bucket teams/data/ roles/storage.objectViewer user:ada@example.com
//!     ... -- revoke my-bucket teams/data/ roles/storage.objectViewer user:ada@example.com
//!     ... -- policy my-bucket teams/data/
//!
//! `mv` waits the rename operation out and prints the folder as it lands;
//! writes under either path meanwhile answer a retryable 429 Cloud Storage
//! asks clients to wait out, which this library's retries do. `grant`
//! scopes the role to every object under the managed folder, additively
//! with the bucket's own policy; the managed folder is created first when
//! it is missing.
//!
//! Credentials come from `auth.findDefault`, as for gcs_cp. Granting needs
//! a token for the full-control scope, so this example asks for
//! `.cloud_platform`. fake-gcs-server has no folders: against the emulator
//! only `layout` answers, calling every bucket flat.

const std = @import("std");
const auth = @import("auth");
const storage = @import("storage");

pub const std_options: std.Options = .{
    .log_scope_levels = &.{.{ .scope = .gcp_storage, .level = .warn }},
};

const usage =
    \\usage: gcs_folders layout BUCKET
    \\       gcs_folders mkdir BUCKET FOLDER [--recursive]
    \\       gcs_folders ls BUCKET [PREFIX] [--one-level]
    \\       gcs_folders mv BUCKET SOURCE DESTINATION
    \\       gcs_folders rm BUCKET FOLDER
    \\       gcs_folders grant BUCKET MANAGED_FOLDER ROLE MEMBER
    \\       gcs_folders revoke BUCKET MANAGED_FOLDER ROLE MEMBER
    \\       gcs_folders policy BUCKET MANAGED_FOLDER
    \\
;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    var stdout_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &stdout_buffer);
    const out = &stdout.interface;
    defer out.flush() catch {};

    var positional: std.ArrayList([]const u8) = .empty;
    var recursive = false;
    var one_level = false;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--recursive")) {
            recursive = true;
        } else if (std.mem.eql(u8, arg, "--one-level")) {
            one_level = true;
        } else try positional.append(arena, arg);
    }
    const p = positional.items;
    if (p.len < 2) return badUsage(out);

    const endpoint = storage.Endpoint.fromEnv(init.environ_map);
    var diag: storage.Diagnostics = .{};
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
        // Reading and writing IAM policies needs the broad scope.
        .scope = .cloud_platform,
    }) catch |err| return fail(err, &diag);
    defer client.deinit();
    const bucket = client.bucket(p[1]);

    if (std.mem.eql(u8, p[0], "layout") and p.len == 2) {
        var layout = bucket.storageLayout() catch |err| return fail(err, &diag);
        defer layout.deinit();
        try out.print("{s}: {s} ({s}), folders are {s}\n", .{
            p[1],
            layout.value.location,
            layout.value.location_type,
            if (layout.value.hierarchical_namespace) "real resources" else "prefixes only",
        });
    } else if (std.mem.eql(u8, p[0], "mkdir") and p.len == 3) {
        var made = bucket.folder(p[2]).create(.{ .recursive = recursive }) catch |err| return fail(err, &diag);
        defer made.deinit();
        try out.print("created {s}\n", .{made.value.name});
    } else if (std.mem.eql(u8, p[0], "ls") and (p.len == 2 or p.len == 3)) {
        var token: ?[]const u8 = null;
        var token_buffer: [512]u8 = undefined;
        while (true) {
            var page = bucket.listFolders(.{
                .prefix = if (p.len == 3) p[2] else null,
                .directory_mode = one_level,
                .page_token = token,
            }) catch |err| return fail(err, &diag);
            defer page.deinit();
            for (page.value.folders) |folder| try out.print("{s}\n", .{folder.name});
            const next = page.value.next_page_token orelse break;
            @memcpy(token_buffer[0..next.len], next);
            token = token_buffer[0..next.len];
        }
    } else if (std.mem.eql(u8, p[0], "mv") and p.len == 4) {
        var renamed = bucket.folder(p[2]).renameTo(p[3], .{}) catch |err| return fail(err, &diag);
        defer renamed.deinit();
        try out.print("renamed {s} to {s}, create time kept: {s}\n", .{ p[2], renamed.value.name, renamed.value.create_time });
    } else if (std.mem.eql(u8, p[0], "rm") and p.len == 3) {
        bucket.folder(p[2]).delete(.{}) catch |err| return fail(err, &diag);
        try out.print("deleted {s}\n", .{p[2]});
    } else if ((std.mem.eql(u8, p[0], "grant") or std.mem.eql(u8, p[0], "revoke")) and p.len == 5) {
        const managed = bucket.managedFolder(p[2]);
        if (std.mem.eql(u8, p[0], "grant")) {
            if (managed.create()) |created| {
                var made = created;
                made.deinit();
                try out.print("created managed folder {s}\n", .{p[2]});
            } else |err| if (err != error.AlreadyExists) return fail(err, &diag);
            var policy = managed.addIamBinding(p[3], p[4]) catch |err| return fail(err, &diag);
            defer policy.deinit();
            try out.print("{s} holds {s} under {s}\n", .{ p[4], p[3], p[2] });
        } else {
            var policy = managed.removeIamBinding(p[3], p[4]) catch |err| return fail(err, &diag);
            defer policy.deinit();
            try out.print("{s} no longer holds {s} under {s}\n", .{ p[4], p[3], p[2] });
        }
    } else if (std.mem.eql(u8, p[0], "policy") and p.len == 3) {
        var policy = bucket.managedFolder(p[2]).iamPolicy() catch |err| return fail(err, &diag);
        defer policy.deinit();
        if (policy.value.bindings.len == 0) try out.print("{s}: no bindings of its own\n", .{p[2]});
        for (policy.value.bindings) |binding| {
            for (binding.members) |member| {
                try out.print("{s}\t{s}{s}\n", .{ binding.role, member, if (binding.condition != null) " (conditional)" else "" });
            }
        }
    } else return badUsage(out);
}

fn badUsage(out: *std.Io.Writer) !void {
    try out.writeAll(usage);
    try out.flush();
    return error.BadUsage;
}

fn fail(err: anyerror, diag: *const storage.Diagnostics) anyerror {
    if (diag.message().len > 0) {
        std.debug.print("error: {t}: {s}\n", .{ err, diag.message() });
    } else {
        std.debug.print("error: {t}\n", .{err});
    }
    return err;
}
