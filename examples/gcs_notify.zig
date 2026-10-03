//! Sets up a bucket's Pub/Sub notifications, and watches the changes come
//! in, decoded.
//!
//!     zig build example-gcs_notify -- setup my-bucket my-project uploads
//!     ... -- setup my-bucket my-project uploads --prefix incoming/ --events finalize,delete
//!     ... -- watch my-project uploads-watch
//!     ... -- watch my-project uploads-watch --count 5
//!     ... -- list my-bucket
//!     ... -- delete my-bucket 3
//!
//! `setup` makes the topic if it is missing, and a subscription named
//! after it with `-watch` for `watch` to read; grants the project's Cloud
//! Storage service agent `roles/pubsub.publisher` on the topic, without
//! which Cloud Storage may not publish there; and creates the bucket's
//! notification configuration, trying again for a minute while a fresh
//! grant takes effect (a few seconds when measured). The bucket must be in
//! the project named. `watch` prints each change a `Subscriber` receives,
//! once: a change can be delivered more than once, and `ObjectEvent.key`
//! tells a repeat. `--count N` stops after N changes.
//!
//! Credentials come from `auth.findDefault`, as for gcs_cp. Against the
//! emulators (STORAGE_EMULATOR_HOST and PUBSUB_EMULATOR_HOST) none are
//! needed and no grant is made: start fake-gcs-server with
//! PUBSUB_EMULATOR_HOST in its own environment, so it publishes to the
//! Pub/Sub emulator.

const std = @import("std");
const auth = @import("auth");
const pubsub = @import("pubsub");
const storage = @import("storage");

pub const std_options: std.Options = .{
    .log_scope_levels = &.{
        .{ .scope = .gcp_pubsub, .level = .warn },
        .{ .scope = .gcp_storage, .level = .warn },
    },
};

const usage =
    \\usage: gcs_notify setup BUCKET PROJECT TOPIC [--prefix P] [--events finalize,metadata_update,delete,archive] [--no-payload]
    \\       gcs_notify watch PROJECT SUBSCRIPTION [--count N]
    \\       gcs_notify list BUCKET
    \\       gcs_notify delete BUCKET ID
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
    var prefix: ?[]const u8 = null;
    var events: ?[]const storage.EventType = null;
    var payload: storage.PayloadFormat = .json;
    var count: ?usize = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--prefix") and i + 1 < args.len) {
            i += 1;
            prefix = args[i];
        } else if (std.mem.eql(u8, arg, "--events") and i + 1 < args.len) {
            i += 1;
            events = try parseEvents(arena, args[i]) orelse return badUsage(out);
        } else if (std.mem.eql(u8, arg, "--no-payload")) {
            payload = .none;
        } else if (std.mem.eql(u8, arg, "--count") and i + 1 < args.len) {
            i += 1;
            count = std.fmt.parseInt(usize, args[i], 10) catch return badUsage(out);
        } else try positional.append(arena, arg);
    }
    const p = positional.items;
    if (p.len == 0) return badUsage(out);

    const gcs_endpoint = storage.Endpoint.fromEnv(init.environ_map);
    const ps_endpoint = pubsub.Endpoint.fromEnv(init.environ_map);
    const emulated = gcs_endpoint != null and ps_endpoint != null;
    var gcs_diag: storage.Diagnostics = .{};
    var ps_diag: pubsub.Diagnostics = .{};
    var creds: ?auth.Credentials = null;
    defer if (creds) |*c| c.deinit();
    if (!emulated) {
        var lookup = try auth.Lookup.fromEnv(init.environ_map, arena);
        lookup.diagnostics = &gcs_diag;
        creds = auth.findDefault(init.gpa, init.io, lookup, .{}) catch |err| return failGcs(err, &gcs_diag);
    }
    const provider = if (creds) |c| c.provider() else null;

    if (std.mem.eql(u8, p[0], "setup") and p.len == 4) {
        const bucket_name, const project, const topic_id = .{ p[1], p[2], p[3] };
        var gcs = storage.Client.init(init.gpa, init.io, .{ .project_id = project, .endpoint = gcs_endpoint, .token_provider = provider, .diagnostics = &gcs_diag }) catch |err| return failGcs(err, &gcs_diag);
        defer gcs.deinit();
        var ps = pubsub.Client.init(init.gpa, init.io, .{ .project_id = project, .endpoint = ps_endpoint, .token_provider = provider, .diagnostics = &ps_diag }) catch |err| return failPubsub(err, &ps_diag);
        defer ps.deinit();

        if (ps.topic(topic_id).create(.{})) |created| {
            var info = created;
            info.deinit();
            try out.print("created topic {s}\n", .{topic_id});
        } else |err| if (err != error.AlreadyExists) return failPubsub(err, &ps_diag);
        const watch_id = try arena.print("{s}-watch", .{topic_id});
        if (ps.subscription(watch_id).create(.{ .topic_id = topic_id })) |created| {
            var info = created;
            info.deinit();
            try out.print("created subscription {s}\n", .{watch_id});
        } else |err| if (err != error.AlreadyExists) return failPubsub(err, &ps_diag);

        if (!emulated) {
            var agent = gcs.serviceAgent() catch |err| return failGcs(err, &gcs_diag);
            defer agent.deinit();
            const member = try arena.print("serviceAccount:{s}", .{agent.value});
            var policy = ps.topic(topic_id).addIamBinding("roles/pubsub.publisher", member) catch |err| return failPubsub(err, &ps_diag);
            policy.deinit();
            try out.print("{s} may publish to {s}\n", .{ agent.value, topic_id });
        }
        try out.flush();

        const config: storage.NotificationConfig = .{
            .topic = .{ .project = project, .topic = topic_id },
            .payload = payload,
            .events = events,
            .object_name_prefix = prefix,
        };
        // A fresh grant takes a few seconds to reach Cloud Storage.
        var waited_s: u32 = 0;
        var made = while (true) {
            break gcs.bucket(bucket_name).createNotification(config) catch |err| {
                if (err == error.TopicNotPublishable and waited_s < 60) {
                    try init.io.sleep(.fromSeconds(5), .awake);
                    waited_s += 5;
                    continue;
                }
                return failGcs(err, &gcs_diag);
            };
        };
        defer made.deinit();
        try out.print("notification {s}: changes in {s} go to {s}\n", .{ made.value.id, bucket_name, made.value.topic });
    } else if (std.mem.eql(u8, p[0], "watch") and p.len == 3) {
        try watch(init, p[1], p[2], ps_endpoint, provider, count, out);
    } else if (std.mem.eql(u8, p[0], "list") and p.len == 2) {
        var gcs = storage.Client.init(init.gpa, init.io, .{ .endpoint = gcs_endpoint, .token_provider = provider, .diagnostics = &gcs_diag }) catch |err| return failGcs(err, &gcs_diag);
        defer gcs.deinit();
        var all = gcs.bucket(p[1]).listNotifications() catch |err| return failGcs(err, &gcs_diag);
        defer all.deinit();
        for (all.value) |n| {
            try out.print("{s}\t{s}\t{t}", .{ n.id, n.topic, n.payload });
            if (n.object_name_prefix) |pre| try out.print("\tprefix {s}", .{pre});
            for (n.events) |e| try out.print("\t{t}", .{e});
            try out.writeByte('\n');
        }
    } else if (std.mem.eql(u8, p[0], "delete") and p.len == 3) {
        var gcs = storage.Client.init(init.gpa, init.io, .{ .endpoint = gcs_endpoint, .token_provider = provider, .diagnostics = &gcs_diag }) catch |err| return failGcs(err, &gcs_diag);
        defer gcs.deinit();
        gcs.bucket(p[1]).deleteNotification(p[2]) catch |err| return failGcs(err, &gcs_diag);
        try out.print("deleted notification {s}\n", .{p[2]});
    } else return badUsage(out);
}

/// Prints each change once, by its key. Called from several tasks at once,
/// so it locks.
const Watcher = struct {
    gpa: std.mem.Allocator,
    out: *std.Io.Writer,
    mutex: std.Io.Mutex = .init,
    seen: std.StringHashMapUnmanaged(void) = .empty,
    count: ?usize,
    subscriber: *pubsub.Subscriber,

    fn handle(ptr: *anyopaque, io: std.Io, message: pubsub.ReceivedMessage) anyerror!void {
        const self: *Watcher = @ptrCast(@alignCast(ptr));
        var diag: storage.Diagnostics = .{};
        var event = storage.decodeEvent(self.gpa, message, .{ .diagnostics = &diag }) catch |err| switch (err) {
            // Not a notification: acknowledged and skipped.
            error.NotAnObjectEvent => {
                self.mutex.lockUncancelable(io);
                defer self.mutex.unlock(io);
                try self.out.print("skipped message {s}: {s}\n", .{ message.message_id, diag.message() });
                return self.out.flush();
            },
            error.OutOfMemory => return err,
        };
        defer event.deinit();
        const e = event.value;
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const gop = try self.seen.getOrPut(self.gpa, e.key);
        if (gop.found_existing) return;
        gop.key_ptr.* = try self.gpa.dupe(u8, e.key);
        try self.out.print("{t} gs://{s}/{s} generation {d}", .{ e.kind, e.bucket, e.object, e.generation });
        if (e.overwrote_generation) |g| try self.out.print(", replacing {d}", .{g});
        if (e.overwritten_by_generation) |g| try self.out.print(", replaced by {d}", .{g});
        if (e.info) |info| try self.out.print(", {d} bytes", .{info.size});
        try self.out.print(", at {s}\n", .{e.time});
        try self.out.flush();
        if (self.count) |n| if (self.seen.count() >= n) self.subscriber.stop();
    }
};

fn watch(
    init: std.process.Init,
    project: []const u8,
    subscription_id: []const u8,
    endpoint: ?pubsub.Endpoint,
    provider: ?pubsub.TokenProvider,
    count: ?usize,
    out: *std.Io.Writer,
) !void {
    var diag: pubsub.Diagnostics = .{};
    var subscriber = pubsub.Subscriber.init(init.gpa, init.io, .{
        .subscription_id = subscription_id,
        .client = .{ .project_id = project, .endpoint = endpoint, .token_provider = provider, .diagnostics = &diag },
        .concurrency = 2,
    }) catch |err| return failPubsub(err, &diag);
    defer subscriber.deinit();
    var watcher: Watcher = .{ .gpa = init.gpa, .out = out, .count = count, .subscriber = &subscriber };
    defer {
        var it = watcher.seen.keyIterator();
        while (it.next()) |k| init.gpa.free(k.*);
        watcher.seen.deinit(init.gpa);
    }
    subscriber.run(.{ .ptr = &watcher, .vtable = &.{ .handle = Watcher.handle } }) catch |err| return failPubsub(err, &diag);
}

fn parseEvents(arena: std.mem.Allocator, list: []const u8) !?[]const storage.EventType {
    var out: std.ArrayList(storage.EventType) = .empty;
    var it = std.mem.splitScalar(u8, list, ',');
    while (it.next()) |name| {
        const event = std.meta.stringToEnum(storage.EventType, name) orelse return null;
        if (event == .unknown) return null;
        try out.append(arena, event);
    }
    return out.items;
}

fn badUsage(out: *std.Io.Writer) !void {
    try out.writeAll(usage);
    try out.flush();
    std.process.exit(2);
}

fn failGcs(err: anyerror, diag: *const storage.Diagnostics) anyerror {
    std.debug.print("gcs_notify: {t}: {s}\n", .{ err, diag.message() });
    return err;
}

fn failPubsub(err: anyerror, diag: *const pubsub.Diagnostics) anyerror {
    std.debug.print("gcs_notify: {t}: {s}\n", .{ err, diag.message() });
    return err;
}
