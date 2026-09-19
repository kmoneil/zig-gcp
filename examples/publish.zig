//! Publishes messages to a topic, creating the topic first if needed.
//!
//!     PUBSUB_EMULATOR_HOST=localhost:8085 zig build example-publish -- orders 5
//!
//! Arguments: topic id (default "orders"), message count (default 3).
//! PUBSUB_PROJECT_ID picks the project (default "test"). Without
//! PUBSUB_EMULATOR_HOST the example talks to production and needs
//! PUBSUB_ACCESS_TOKEN, such as `$(gcloud auth print-access-token)`.

const std = @import("std");
const pubsub = @import("pubsub");

/// The library logs under the `.pubsub` scope; show only its warnings (each
/// retry) and hide the per-request debug lines.
pub const std_options: std.Options = .{
    .log_scope_levels = &.{.{ .scope = .pubsub, .level = .warn }},
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const topic_id = if (args.len > 1) args[1] else "orders";
    const count = if (args.len > 2) try std.fmt.parseInt(u32, args[2], 10) else 3;

    var stdout_buffer: [1024]u8 = undefined;
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

    const topic = client.topic(topic_id);
    if (topic.create(.{})) |created| {
        var info = created;
        defer info.deinit();
        try out.print("created {s}\n", .{info.value.name});
    } else |err| switch (err) {
        error.AlreadyExists => {},
        else => return fail(err, &diag),
    }

    const messages = try arena.alloc(pubsub.Message, count);
    for (messages, 0..) |*m, i| {
        m.* = .{
            .data = try std.fmt.allocPrint(arena, "message {d} of {d}", .{ i + 1, count }),
            .attributes = &.{.{ .key = "origin", .value = "zig-pubsub example" }},
        };
    }
    var sent = topic.publish(messages, .{}) catch |err| return fail(err, &diag);
    defer sent.deinit();
    for (sent.value.message_ids) |id| try out.print("published message {s}\n", .{id});
    try out.flush();
}

fn fail(err: pubsub.Error, diag: *const pubsub.Diagnostics) pubsub.Error {
    std.debug.print("error.{t}", .{err});
    if (diag.http_status != 0) std.debug.print(" (HTTP {d} {s})", .{ diag.http_status, diag.status() });
    if (diag.message().len != 0) std.debug.print(": {s}", .{diag.message()});
    std.debug.print("\n", .{});
    return err;
}
