//! Publishes from several tasks through one `pubsub.Publisher`, which
//! batches the messages into requests, and says how few it took. Creates
//! the topic first if needed.
//!
//!     PUBSUB_EMULATOR_HOST=localhost:8085 zig build example-publisher -- orders 1000 4
//!
//! Arguments: topic id (default "orders"), message count (default 1000),
//! publishing tasks (default 4). Configuration is as for the publish
//! example: PUBSUB_PROJECT_ID picks the project (default "test"), and
//! without PUBSUB_EMULATOR_HOST the example talks to production and needs
//! PUBSUB_ACCESS_TOKEN, such as `$(gcloud auth print-access-token)`.

const std = @import("std");
const pubsub = @import("pubsub");

/// The library logs under the `.gcp_pubsub` scope; show only its warnings
/// (each retry) and hide the per-request debug lines.
pub const std_options: std.Options = .{
    .log_scope_levels = &.{.{ .scope = .gcp_pubsub, .level = .warn }},
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const topic_id = if (args.len > 1) args[1] else "orders";
    const count = if (args.len > 2) try std.fmt.parseInt(usize, args[2], 10) else 1000;
    const tasks = if (args.len > 3) try std.fmt.parseInt(usize, args[3], 10) else 4;
    if (tasks == 0) return error.NeedAtLeastOneTask;

    var stdout_buffer: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buffer);
    const out = &stdout.interface;

    var token: pubsub.StaticToken = .{
        .token = std.mem.trim(u8, init.environ_map.get("PUBSUB_ACCESS_TOKEN") orelse "", &std.ascii.whitespace),
    };
    var diag: pubsub.Diagnostics = .{};
    const client: pubsub.Client.Options = .{
        .project_id = init.environ_map.get("PUBSUB_PROJECT_ID") orelse "test",
        .endpoint = pubsub.Endpoint.fromEnv(init.environ_map),
        .token_provider = if (token.token.len > 0) token.provider() else null,
        .diagnostics = &diag,
        // A publisher never holds a pull open, so a stalled request is
        // better retried after 30 s than after the default 3 minutes.
        .request_timeout_ms = 30_000,
    };

    // The topic, made with a plain client when it is missing.
    {
        var admin = pubsub.Client.init(gpa, io, client) catch |err| return fail(err, &diag);
        defer admin.deinit();
        if (admin.topic(topic_id).create(.{})) |created| {
            var info = created;
            defer info.deinit();
            try out.print("created {s}\n", .{info.value.name});
        } else |err| switch (err) {
            error.AlreadyExists => {},
            else => return fail(err, &diag),
        }
    }

    var publisher = pubsub.Publisher.init(gpa, io, .{
        .topic_id = topic_id,
        .client = client,
    }) catch |err| return fail(err, &diag);
    defer publisher.deinit();
    var running = try io.concurrent(pubsub.Publisher.run, .{&publisher});
    const started = std.Io.Clock.awake.now(io);

    var failures: std.atomic.Value(usize) = .init(0);
    var group: std.Io.Group = .init;
    defer group.cancel(io);
    for (0..tasks) |task| {
        const share = count / tasks + @intFromBool(task < count % tasks);
        try group.concurrent(io, publishShare, .{ &publisher, task, share, &failures });
    }
    try group.await(io);
    publisher.stop(); // nothing is left to send, but this is how run returns
    running.await(io) catch |err| return fail(err, &diag);

    const elapsed_ms = started.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds();
    const stats = publisher.stats();
    try out.print("published {d} messages in {d} requests, {d} ms", .{ stats.succeeded, stats.requests, elapsed_ms });
    if (stats.failed > 0) try out.print("; {d} failed", .{stats.failed});
    try out.print("\n", .{});
    try out.flush();
    if (failures.load(.monotonic) > 0) return error.PublishFailed;
}

/// Publishes `share` messages, a few hundred at a time, and waits for each
/// receipt. A group's tasks can return nothing but a cancel, so failures
/// are counted instead.
fn publishShare(
    publisher: *pubsub.Publisher,
    task: usize,
    share: usize,
    failures: *std.atomic.Value(usize),
) std.Io.Cancelable!void {
    var i: usize = 0;
    while (i < share) {
        var receipts: [256]pubsub.Publisher.Receipt = undefined;
        var made: usize = 0;
        defer for (receipts[0..made]) |r| r.release();
        while (made < receipts.len and i < share) : (i += 1) {
            var buf: [48]u8 = undefined;
            const data = std.fmt.bufPrint(&buf, "task {d}, message {d}", .{ task, i }) catch unreachable;
            receipts[made] = publisher.publish(.{
                .data = data,
                .attributes = &.{.{ .key = "origin", .value = "zig-pubsub publisher example" }},
            }, .{}) catch |err| {
                if (err == error.Canceled) return error.Canceled;
                _ = failures.fetchAdd(1, .monotonic);
                continue;
            };
            made += 1;
        }
        for (receipts[0..made]) |r| {
            if (r.wait()) |_| {} else |err| {
                if (err == error.Canceled) return error.Canceled;
                _ = failures.fetchAdd(1, .monotonic);
            }
        }
    }
}

fn fail(err: anyerror, diag: *const pubsub.Diagnostics) anyerror {
    std.debug.print("error.{t}", .{err});
    if (diag.http_status != 0) std.debug.print(" (HTTP {d} {s})", .{ diag.http_status, diag.status() });
    if (diag.message().len != 0) std.debug.print(": {s}", .{diag.message()});
    std.debug.print("\n", .{});
    return err;
}
