//! Prints which credentials this machine offers, then lists the project's
//! topics with them. No token is pasted anywhere.
//!
//!     GOOGLE_CLOUD_PROJECT=my-project zig build example-whoami
//!
//! `auth.findDefault` tries the file `GOOGLE_APPLICATION_CREDENTIALS`
//! names, then the one `gcloud auth application-default login` writes, then
//! the metadata server. On Google Cloud the last one answers and nothing
//! has to be configured; on a laptop, log in with gcloud once.

const std = @import("std");
const auth = @import("auth");
const pubsub = @import("pubsub");

/// Show the library's warnings, and its per-request debug lines with
/// `--debug`, which is the quickest way to see where a token came from.
pub const std_options: std.Options = .{
    .log_scope_levels = &.{
        .{ .scope = .gcp_auth, .level = .warn },
        .{ .scope = .gcp_pubsub, .level = .warn },
    },
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    var stdout_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &stdout_buffer);
    const out = &stdout.interface;
    var diag: pubsub.Diagnostics = .{};

    var lookup = try auth.Lookup.fromEnv(init.environ_map, arena);
    lookup.diagnostics = &diag;
    var creds = auth.findDefault(init.gpa, init.io, lookup, .{}) catch |err| return fail(err, &diag);
    defer creds.deinit();
    try out.print("credentials: {t}\n", .{creds.source});
    if (creds.quotaProjectId()) |project| try out.print("quota project: {s}\n", .{project});

    // On Google Cloud the credentials know which project this runs in.
    // Everywhere else the caller picks.
    const detected = creds.projectId(init.io, arena) catch |err| return fail(err, &diag);
    if (detected) |project| try out.print("running in: {s}\n", .{project});
    const project = init.environ_map.get("GOOGLE_CLOUD_PROJECT") orelse
        init.environ_map.get("PUBSUB_PROJECT_ID") orelse
        detected orelse
        creds.quotaProjectId() orelse
        {
            try out.print("set GOOGLE_CLOUD_PROJECT to list topics\n", .{});
            return out.flush();
        };

    var client = pubsub.Client.init(init.gpa, init.io, .{
        .project_id = project,
        .endpoint = pubsub.Endpoint.fromEnv(init.environ_map),
        .token_provider = creds.provider(),
        .diagnostics = &diag,
    }) catch |err| return fail(err, &diag);
    defer client.deinit();

    var page = client.listTopics(.{ .page_size = 25 }) catch |err| return fail(err, &diag);
    defer page.deinit();
    try out.print("topics in {s}:\n", .{project});
    for (page.value.topics) |topic| try out.print("  {s}\n", .{topic.name});
    if (page.value.topics.len == 0) try out.print("  (none)\n", .{});
    if (page.value.next_page_token != null) try out.print("  ... and more\n", .{});
    try out.flush();
}

fn fail(err: anyerror, diag: *const pubsub.Diagnostics) anyerror {
    std.debug.print("error.{t}", .{err});
    if (diag.http_status != 0) std.debug.print(" (HTTP {d} {s})", .{ diag.http_status, diag.status() });
    if (diag.message().len != 0) std.debug.print(": {s}", .{diag.message()});
    std.debug.print("\n", .{});
    return err;
}
