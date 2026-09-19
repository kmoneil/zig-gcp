//! Pulls messages from a subscription, prints them, and acknowledges them.
//! Creates the topic and the subscription first if needed. A subscription only
//! receives messages published after it exists, so run this once before the
//! publish example.
//!
//!     PUBSUB_EMULATOR_HOST=localhost:8085 zig build example-worker -- orders orders-worker
//!
//! Arguments: topic id (default "orders"), subscription id (default
//! "orders-worker"), and `--follow` to keep waiting for messages instead of
//! stopping at the first empty pull. Configuration is as for the publish
//! example.

const std = @import("std");
const pubsub = @import("pubsub");

/// The library logs under the `.pubsub` scope; show only its warnings (each
/// retry) and hide the per-request debug lines.
pub const std_options: std.Options = .{
    .log_scope_levels = &.{.{ .scope = .gcp_pubsub, .level = .warn }},
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    var positional: [2][]const u8 = .{ "orders", "orders-worker" };
    var follow = false;
    var n: usize = 0;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--follow")) {
            follow = true;
        } else if (n < positional.len) {
            positional[n] = arg;
            n += 1;
        }
    }
    const topic_id, const subscription_id = positional;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const out = &stdout.interface;

    var token: pubsub.StaticToken = .{
        .token = std.mem.trim(u8, init.environ_map.get("PUBSUB_ACCESS_TOKEN") orelse "", &std.ascii.whitespace),
    };
    var diag: pubsub.Diagnostics = .{};
    var client = pubsub.Client.init(init.gpa, init.io, .{
        .project_id = init.environ_map.get("PUBSUB_PROJECT_ID") orelse "test",
        .endpoint = pubsub.Endpoint.fromEnv(init.environ_map),
        .token_provider = if (token.token.len > 0) token.provider() else null,
        .diagnostics = &diag,
    }) catch |err| return fail(err, &diag);
    defer client.deinit();

    // Make sure the topic exists, so the examples run in any order.
    if (client.topic(topic_id).create(.{})) |created| {
        var info = created;
        info.deinit();
    } else |err| switch (err) {
        error.AlreadyExists => {},
        else => return fail(err, &diag),
    }

    const worker = client.subscription(subscription_id);
    if (worker.create(.{ .topic_id = topic_id })) |created| {
        var info = created;
        defer info.deinit();
        try out.print("created {s} on {s}\n", .{ info.value.name, info.value.topic });
        try out.flush();
    } else |err| switch (err) {
        error.AlreadyExists => {},
        else => return fail(err, &diag),
    }

    var handled: usize = 0;
    while (true) {
        // Without `return_immediately` the server holds an empty pull open,
        // which is what a long-running worker wants.
        var batch = worker.pull(.{ .max_messages = 100, .return_immediately = !follow }) catch |err|
            return fail(err, &diag);
        defer batch.deinit();
        if (batch.value.messages.len == 0 and !follow) break;

        const ack_ids = try init.gpa.alloc([]const u8, batch.value.messages.len);
        defer init.gpa.free(ack_ids);
        for (batch.value.messages, ack_ids) |m, *ack_id| {
            try out.print("{s} {s} ({d} bytes): {s}\n", .{ m.message_id, m.publish_time, m.data.len, m.data });
            for (m.attributes) |a| try out.print("    {s} = {s}\n", .{ a.key, a.value });
            ack_id.* = m.ack_id;
        }
        try out.flush();
        worker.ack(ack_ids) catch |err| return fail(err, &diag);
        handled += ack_ids.len;
    }
    try out.print("handled {d} messages\n", .{handled});
    try out.flush();
}

fn fail(err: pubsub.Error, diag: *const pubsub.Diagnostics) pubsub.Error {
    std.debug.print("error.{t}", .{err});
    if (diag.http_status != 0) std.debug.print(" (HTTP {d} {s})", .{ diag.http_status, diag.status() });
    if (diag.message().len != 0) std.debug.print(": {s}", .{diag.message()});
    std.debug.print("\n", .{});
    return err;
}
