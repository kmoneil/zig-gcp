//! Consumes a subscription with `pubsub.Subscriber`: messages are pulled,
//! printed and acknowledged, with leases extended for as long as a handler
//! runs. Creates the topic and the subscription first if needed. A
//! subscription only receives messages published after it exists, so run
//! this once before the publish example.
//!
//!     PUBSUB_EMULATOR_HOST=localhost:8085 zig build example-worker -- orders orders-worker
//!
//! Arguments: topic id (default "orders"), subscription id (default
//! "orders-worker"), and `--follow` to keep waiting for messages instead
//! of stopping once the backlog is drained. Configuration is as for the
//! publish example.

const std = @import("std");
const pubsub = @import("pubsub");

/// The library logs under the `.gcp_pubsub` scope; show only its warnings
/// (each retry) and hide the per-request debug lines.
pub const std_options: std.Options = .{
    .log_scope_levels = &.{.{ .scope = .gcp_pubsub, .level = .warn }},
};

/// Prints each message. Called from `concurrency` tasks at once, so the
/// printing is locked.
const Printer = struct {
    mutex: std.Io.Mutex = .init,
    out: *std.Io.Writer,

    fn handler(self: *Printer) pubsub.Subscriber.Handler {
        return .{ .ptr = self, .vtable = &.{ .handle = handle } };
    }

    fn handle(ptr: *anyopaque, io: std.Io, message: pubsub.ReceivedMessage) anyerror!void {
        const self: *Printer = @ptrCast(@alignCast(ptr));
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        try self.out.print("{s} {s} ({d} bytes): {s}\n", .{
            message.message_id, message.publish_time, message.data.len, message.data,
        });
        for (message.attributes) |a| try self.out.print("    {s} = {s}\n", .{ a.key, a.value });
        try self.out.flush();
    }
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
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &stdout_buffer);
    const out = &stdout.interface;

    var token: pubsub.StaticToken = .{
        .token = std.mem.trim(u8, init.environ_map.get("PUBSUB_ACCESS_TOKEN") orelse "", &std.ascii.whitespace),
    };
    const client_options: pubsub.Client.Options = .{
        .project_id = init.environ_map.get("PUBSUB_PROJECT_ID") orelse "test",
        .endpoint = pubsub.Endpoint.fromEnv(init.environ_map),
        .token_provider = if (token.token.len > 0) token.provider() else null,
    };
    var diag: pubsub.Diagnostics = .{};
    var setup_options = client_options;
    setup_options.diagnostics = &diag;
    var client = pubsub.Client.init(init.gpa, init.io, setup_options) catch |err| return fail(err, &diag);
    defer client.deinit();

    // Make sure the topic and the subscription exist, so the examples run
    // in any order.
    if (client.topic(topic_id).create(.{})) |created| {
        var info = created;
        info.deinit();
    } else |err| switch (err) {
        error.AlreadyExists => {},
        else => return fail(err, &diag),
    }
    if (client.subscription(subscription_id).create(.{ .topic_id = topic_id })) |created| {
        var info = created;
        defer info.deinit();
        try out.print("created {s} on {s}\n", .{ info.value.name, info.value.topic });
        try out.flush();
    } else |err| switch (err) {
        error.AlreadyExists => {},
        else => return fail(err, &diag),
    }

    var printer: Printer = .{ .out = out };
    var subscriber = pubsub.Subscriber.init(init.gpa, init.io, .{
        .subscription_id = subscription_id,
        .client = setup_options,
        .concurrency = 4,
    }) catch |err| return fail(err, &diag);
    defer subscriber.deinit();

    var running = try init.io.concurrent(pubsub.Subscriber.run, .{ &subscriber, printer.handler() });
    if (!follow) {
        // Stop once the backlog is drained: everything received resolved,
        // and five quiet seconds passed. The window is generous because
        // delivery can lag a fresh pull by a second or two.
        var idle_ms: i64 = 0;
        var last = subscriber.stats();
        while (idle_ms < 5_000) {
            try init.io.sleep(.fromMilliseconds(250), .awake);
            const now = subscriber.stats();
            const drained = now.received == now.acked + now.nacked;
            idle_ms = if (drained and now.received == last.received) idle_ms + 250 else 0;
            last = now;
        }
        subscriber.stop();
    }
    running.await(init.io) catch |err| return fail(err, &diag);
    const counts = subscriber.stats();
    try out.print("handled {d} messages ({d} acknowledged, {d} released)\n", .{
        counts.received, counts.acked, counts.nacked,
    });
    try out.flush();
}

fn fail(err: pubsub.Error, diag: *const pubsub.Diagnostics) pubsub.Error {
    std.debug.print("error.{t}", .{err});
    if (diag.http_status != 0) std.debug.print(" (HTTP {d} {s})", .{ diag.http_status, diag.status() });
    if (diag.message().len != 0) std.debug.print(": {s}", .{diag.message()});
    std.debug.print("\n", .{});
    return err;
}
