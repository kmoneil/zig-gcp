//! Reads and changes the IAM policy of a bucket, a topic, a subscription or
//! a secret, with whatever credentials this machine has.
//!
//!     zig build example-iam -- get gs://my-bucket
//!     zig build example-iam -- add gs://my-bucket roles/storage.objectViewer user:alice@example.com
//!     zig build example-iam -- remove projects/my-project/topics/orders roles/pubsub.publisher serviceAccount:svc@my-project.iam.gserviceaccount.com
//!     zig build example-iam -- test projects/my-project/secrets/db secretmanager.versions.access secretmanager.secrets.get
//!
//! A resource is `gs://BUCKET`, `projects/P/topics/T`,
//! `projects/P/subscriptions/S`, `projects/P/secrets/S` or
//! `projects/P/locations/L/secrets/S`. `add` grants once and `remove`
//! revokes once: each reads the policy, changes it and writes it back under
//! the read's etag, starting over when another change came in between.
//! Members compare as the services store them, so granting `user:Alice@...`
//! where `user:alice@...` holds the role writes nothing.
//!
//! Credentials come from `auth.findDefault`, as for gcs_cp. Reading and
//! changing a bucket's policy needs the cloud-platform scope or Cloud
//! Storage's full control, which gcloud's login carries; the Pub/Sub
//! emulator answers every IAM call `Unimplemented`, and fake-gcs-server
//! has no IAM at all.

const std = @import("std");
const auth = @import("auth");
const pubsub = @import("pubsub");
const secret_manager = @import("secret_manager");
const storage = @import("storage");

const usage =
    \\usage: iam get RESOURCE
    \\       iam add RESOURCE ROLE MEMBER
    \\       iam remove RESOURCE ROLE MEMBER
    \\       iam test RESOURCE PERMISSION...
    \\RESOURCE: gs://BUCKET, projects/P/topics/T, projects/P/subscriptions/S,
    \\          projects/P/secrets/S or projects/P/locations/L/secrets/S
    \\
;

const Command = enum { get, add, remove, @"test" };

const Resource = union(enum) {
    bucket: []const u8,
    topic: struct { project: []const u8, id: []const u8 },
    subscription: struct { project: []const u8, id: []const u8 },
    secret: struct { project: []const u8, location: ?[]const u8, id: []const u8 },

    fn parse(text: []const u8) ?Resource {
        if (std.mem.startsWith(u8, text, "gs://")) {
            const name = std.mem.trimEnd(u8, text["gs://".len..], "/");
            return if (name.len == 0 or std.mem.indexOfScalar(u8, name, '/') != null) null else .{ .bucket = name };
        }
        var parts: [6][]const u8 = undefined;
        var n: usize = 0;
        var it = std.mem.splitScalar(u8, text, '/');
        while (it.next()) |part| {
            if (n == parts.len or part.len == 0) return null;
            parts[n] = part;
            n += 1;
        }
        if (n < 4 or !std.mem.eql(u8, parts[0], "projects")) return null;
        if (n == 4 and std.mem.eql(u8, parts[2], "topics")) return .{ .topic = .{ .project = parts[1], .id = parts[3] } };
        if (n == 4 and std.mem.eql(u8, parts[2], "subscriptions")) return .{ .subscription = .{ .project = parts[1], .id = parts[3] } };
        if (n == 4 and std.mem.eql(u8, parts[2], "secrets")) return .{ .secret = .{ .project = parts[1], .location = null, .id = parts[3] } };
        if (n == 6 and std.mem.eql(u8, parts[2], "locations") and std.mem.eql(u8, parts[4], "secrets")) {
            return .{ .secret = .{ .project = parts[1], .location = parts[3], .id = parts[5] } };
        }
        return null;
    }
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    var out_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &out_buf);
    const w = &stdout.interface;
    defer w.flush() catch {};

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 3) return fail(w, usage);
    const command = std.meta.stringToEnum(Command, args[1]) orelse return fail(w, usage);
    const resource = Resource.parse(args[2]) orelse return fail(w, usage);
    const rest = try init.arena.allocator().alloc([]const u8, args.len - 3);
    for (args[3..], rest) |arg, *r| r.* = arg;
    switch (command) {
        .get => if (rest.len != 0) return fail(w, usage),
        .add, .remove => if (rest.len != 2) return fail(w, usage),
        .@"test" => if (rest.len == 0) return fail(w, usage),
    }

    const lookup = try auth.Lookup.fromEnv(init.environ_map, init.arena.allocator());
    var creds = auth.findDefault(gpa, io, lookup, .{}) catch |err| {
        try w.print("no credentials: {t}\n", .{err});
        return error.NoCredentials;
    };
    defer creds.deinit();

    switch (resource) {
        .bucket => |name| {
            var diag: storage.Diagnostics = .{};
            var client = try storage.Client.init(gpa, io, .{
                .token_provider = creds.provider(),
                // A bucket's IAM policy needs one of the two: gcloud's login
                // and the metadata server's tokens carry cloud-platform.
                .scope = .cloud_platform,
                .diagnostics = &diag,
            });
            defer client.deinit();
            return run(w, client.bucket(name), command, rest, &diag);
        },
        .topic => |t| {
            var diag: pubsub.Diagnostics = .{};
            var client = try pubsub.Client.init(gpa, io, .{ .project_id = t.project, .token_provider = creds.provider(), .diagnostics = &diag });
            defer client.deinit();
            return run(w, client.topic(t.id), command, rest, &diag);
        },
        .subscription => |s| {
            var diag: pubsub.Diagnostics = .{};
            var client = try pubsub.Client.init(gpa, io, .{ .project_id = s.project, .token_provider = creds.provider(), .diagnostics = &diag });
            defer client.deinit();
            return run(w, client.subscription(s.id), command, rest, &diag);
        },
        .secret => |s| {
            var diag: secret_manager.Diagnostics = .{};
            var client = try secret_manager.Client.init(gpa, io, .{
                .project_id = s.project,
                .location = s.location,
                .token_provider = creds.provider(),
                .diagnostics = &diag,
            });
            defer client.deinit();
            return run(w, client.secret(s.id), command, rest, &diag);
        },
    }
}

/// The command on any handle: buckets, topics, subscriptions and secrets
/// take the same five calls.
fn run(w: *std.Io.Writer, handle: anytype, command: Command, rest: []const []const u8, diag: anytype) !void {
    if (command == .@"test") {
        var held = handle.testIamPermissions(rest) catch |err| return refused(w, err, diag);
        defer held.deinit();
        for (rest) |asked| {
            const has = for (held.value) |p| {
                if (std.mem.eql(u8, p, asked)) break true;
            } else false;
            try w.print("{s} {s}\n", .{ if (has) "held    " else "not held", asked });
        }
        return;
    }
    var policy = switch (command) {
        .get => handle.iamPolicy(),
        .add => handle.addIamBinding(rest[0], rest[1]),
        .remove => handle.removeIamBinding(rest[0], rest[1]),
        .@"test" => unreachable,
    } catch |err| return refused(w, err, diag);
    defer policy.deinit();
    const p = policy.value;
    try w.print("version {d}, etag {s}\n", .{ p.version, p.etag orelse "(none)" });
    if (p.bindings.len == 0) try w.writeAll("no bindings\n");
    for (p.bindings) |b| {
        try w.print("{s}\n", .{b.role});
        if (b.condition) |condition| try w.print("  when {s}\n", .{condition});
        for (b.members) |m| try w.print("  {s}\n", .{m});
    }
}

fn refused(w: *std.Io.Writer, err: anyerror, diag: anytype) anyerror {
    try w.print("error.{t}", .{err});
    if (diag.http_status != 0) try w.print(" (HTTP {d} {s})", .{ diag.http_status, diag.status() });
    if (diag.message().len != 0) try w.print(": {s}", .{diag.message()});
    try w.writeAll("\n");
    return err;
}

fn fail(w: *std.Io.Writer, message: []const u8) !void {
    try w.writeAll(message);
    return error.Usage;
}
