//! Rotates a secret when Secret Manager says it is time: a rotation
//! schedule on the secret, a topic it publishes to, and a watcher that
//! answers each `SECRET_ROTATE` with a new version.
//!
//!     zig build example-secret_rotation -- setup my-project db-password rotations
//!     ... -- setup my-project db-password rotations --first 360 --every 86400
//!     ... -- watch my-project db-password rotations-watch
//!     ... -- watch my-project db-password rotations-watch --count 1
//!     ... -- teardown my-project db-password rotations
//!
//! `setup` makes the topic if it is missing, and a subscription named after
//! it with `-watch`; grants the project's Secret Manager service agent
//! `roles/pubsub.publisher` on the topic, which it needs before any secret
//! may name the topic (asking for the agent creates it, if the project has
//! none: using Secret Manager does not); then creates the secret, or
//! updates it, with the topic and a rotation `--first` seconds from now
//! (at least 300; 360 by default) and every `--every` seconds after (at
//! least 3600; once only if left out). Secret Manager changes nothing at
//! rotation time: it only publishes.
//!
//! `watch` answers each `SECRET_ROTATE` for the secret by adding a version
//! of 32 random bytes, as hex, and pointing the alias `current` at it, so
//! readers who access `.{ .alias = "current" }` move with it. The new value
//! is never printed. Other events are printed, once each: a change can be
//! delivered more than once, and a global secret's events arrive up to a
//! few minutes late and out of order. `--count N` stops after N rotations.
//!
//! `teardown` removes the secret's rotation and topics, then the
//! subscription and the topic. The secret and its versions stay.
//!
//! Credentials come from `auth.findDefault`. Secret Manager has no
//! emulator, so this needs a real project.

const std = @import("std");
const auth = @import("auth");
const pubsub = @import("pubsub");
const secret_manager = @import("secret_manager");

pub const std_options: std.Options = .{
    .log_scope_levels = &.{
        .{ .scope = .gcp_pubsub, .level = .warn },
        .{ .scope = .gcp_secret_manager, .level = .warn },
    },
};

const usage =
    \\usage: secret_rotation setup PROJECT SECRET TOPIC [--first SECONDS] [--every SECONDS]
    \\       secret_rotation watch PROJECT SECRET SUBSCRIPTION [--count N]
    \\       secret_rotation teardown PROJECT SECRET TOPIC
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
    var first_s: u64 = 360;
    var every_s: ?u64 = null;
    var count: ?usize = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (i + 1 < args.len and std.mem.eql(u8, arg, "--first")) {
            i += 1;
            first_s = std.fmt.parseInt(u64, args[i], 10) catch return badUsage(out);
        } else if (i + 1 < args.len and std.mem.eql(u8, arg, "--every")) {
            i += 1;
            every_s = std.fmt.parseInt(u64, args[i], 10) catch return badUsage(out);
        } else if (i + 1 < args.len and std.mem.eql(u8, arg, "--count")) {
            i += 1;
            count = std.fmt.parseInt(usize, args[i], 10) catch return badUsage(out);
        } else try positional.append(arena, arg);
    }
    const p = positional.items;
    if (p.len != 4) return badUsage(out);
    const project, const secret_id, const third = .{ p[1], p[2], p[3] };

    var sm_diag: secret_manager.Diagnostics = .{};
    var ps_diag: pubsub.Diagnostics = .{};
    var lookup = try auth.Lookup.fromEnv(init.environ_map, arena);
    lookup.diagnostics = &sm_diag;
    var creds = auth.findDefault(init.gpa, init.io, lookup, .{}) catch |err| return fail(err, &sm_diag);
    defer creds.deinit();

    var secrets = secret_manager.Client.init(init.gpa, init.io, .{
        .project_id = project,
        .token_provider = creds.provider(),
        .diagnostics = &sm_diag,
    }) catch |err| return fail(err, &sm_diag);
    defer secrets.deinit();

    if (std.mem.eql(u8, p[0], "setup")) {
        const topic_id = third;
        var ps = pubsub.Client.init(init.gpa, init.io, .{ .project_id = project, .token_provider = creds.provider(), .diagnostics = &ps_diag }) catch |err| return fail(err, &ps_diag);
        defer ps.deinit();
        if (ps.topic(topic_id).create(.{})) |created| {
            var info = created;
            info.deinit();
            try out.print("created topic {s}\n", .{topic_id});
        } else |err| if (err != error.AlreadyExists) return fail(err, &ps_diag);
        const watch_id = try std.fmt.allocPrint(arena, "{s}-watch", .{topic_id});
        if (ps.subscription(watch_id).create(.{ .topic_id = topic_id })) |created| {
            var info = created;
            info.deinit();
            try out.print("created subscription {s}\n", .{watch_id});
        } else |err| if (err != error.AlreadyExists) return fail(err, &ps_diag);

        var agent = secrets.serviceAgent() catch |err| return fail(err, &sm_diag);
        defer agent.deinit();
        const member = try std.fmt.allocPrint(arena, "serviceAccount:{s}", .{agent.value});
        var policy = ps.topic(topic_id).addIamBinding("roles/pubsub.publisher", member) catch |err| return fail(err, &ps_diag);
        policy.deinit();
        try out.print("{s} may publish to {s}\n", .{ agent.value, topic_id });
        try out.flush();

        const topic_name = try std.fmt.allocPrint(arena, "projects/{s}/topics/{s}", .{ project, topic_id });
        const topics: []const []const u8 = &.{topic_name};
        const rotation: secret_manager.Rotation = .{
            .next_time = try timeFromNow(init.io, arena, first_s),
            .period_s = every_s,
        };
        const secret = secrets.secret(secret_id);
        // A fresh grant reached Secret Manager within a second when
        // measured; allow a minute.
        var waited_s: u32 = 0;
        var info = while (true) {
            const result = if (secret.get()) |existing| blk: {
                var e = existing;
                e.deinit();
                break :blk secret.update(.{ .topics = .{ .set = topics }, .rotation = .{ .set = rotation } });
            } else |err| switch (err) {
                error.NotFound => secret.create(.{ .topics = topics, .rotation = rotation }),
                else => return fail(err, &sm_diag),
            };
            break result catch |err| {
                if (err == error.TopicNotPublishable and waited_s < 60) {
                    try init.io.sleep(.fromSeconds(5), .awake);
                    waited_s += 5;
                    continue;
                }
                return fail(err, &sm_diag);
            };
        };
        defer info.deinit();
        try out.print("{s} rotates at {s}", .{ secret_id, info.value.rotation.?.next_time });
        if (info.value.rotation.?.period_s) |s| try out.print(", then every {d} s", .{s});
        try out.print("; Secret Manager tells {s}\n", .{topic_name});
    } else if (std.mem.eql(u8, p[0], "watch")) {
        try watch(init, project, secrets.secret(secret_id), third, creds.provider(), count, out);
    } else if (std.mem.eql(u8, p[0], "teardown")) {
        const topic_id = third;
        var cleared = secrets.secret(secret_id).update(.{ .rotation = .clear, .topics = .clear }) catch |err| return fail(err, &sm_diag);
        cleared.deinit();
        try out.print("{s} no longer rotates or publishes\n", .{secret_id});
        var ps = pubsub.Client.init(init.gpa, init.io, .{ .project_id = project, .token_provider = creds.provider(), .diagnostics = &ps_diag }) catch |err| return fail(err, &ps_diag);
        defer ps.deinit();
        const watch_id = try std.fmt.allocPrint(arena, "{s}-watch", .{topic_id});
        ps.subscription(watch_id).delete() catch |err| if (err != error.NotFound) return fail(err, &ps_diag);
        ps.topic(topic_id).delete() catch |err| if (err != error.NotFound) return fail(err, &ps_diag);
        try out.print("deleted {s} and {s}\n", .{ watch_id, topic_id });
    } else return badUsage(out);
}

/// Answers each rotation of one secret, and prints every other event of
/// it once. The Subscriber runs one handler at a time here, so a rotation
/// and its alias move never race another.
const Rotator = struct {
    gpa: std.mem.Allocator,
    out: *std.Io.Writer,
    secret: secret_manager.Secret,
    seen: std.StringHashMapUnmanaged(void) = .empty,
    rotations: usize = 0,
    count: ?usize,
    subscriber: *pubsub.Subscriber,

    fn handle(ptr: *anyopaque, io: std.Io, message: pubsub.ReceivedMessage) anyerror!void {
        const self: *Rotator = @ptrCast(@alignCast(ptr));
        var diag: secret_manager.Diagnostics = .{};
        var event = secret_manager.decodeEvent(self.gpa, message, .{ .diagnostics = &diag }) catch |err| switch (err) {
            error.NotASecretEvent => {
                try self.out.print("skipped message {s}: {s}\n", .{ message.message_id, diag.message() });
                return self.out.flush();
            },
            error.OutOfMemory => return err,
        };
        defer event.deinit();
        const e = event.value;
        if (e.kind == .topic_configured) return;
        if (!std.mem.eql(u8, e.secretId(), self.secret.id)) return;
        const gop = try self.seen.getOrPut(self.gpa, e.key);
        if (gop.found_existing) return;
        gop.key_ptr.* = try self.gpa.dupe(u8, e.key);

        if (e.kind != .secret_rotate) {
            try self.out.print("{t} at {s}", .{ e.kind, e.time });
            if (e.version) |v| try self.out.print(", version {d}", .{v});
            try self.out.writeByte('\n');
            return self.out.flush();
        }
        const number = try self.rotate(io);
        self.rotations += 1;
        try self.out.print("rotated at {s}: version {d} is current", .{ e.time, number });
        if (e.info) |info| if (info.rotation) |r| try self.out.print("; next at {s}", .{r.next_time});
        try self.out.writeByte('\n');
        try self.out.flush();
        if (self.count) |n| if (self.rotations >= n) self.subscriber.stop();
    }

    /// Adds a version of fresh random bytes and points `current` at it,
    /// keeping the secret's other aliases: under the etag read, starting
    /// over if another change came in between.
    fn rotate(self: *Rotator, io: std.Io) !u64 {
        var raw: [32]u8 = undefined;
        io.random(&raw);
        var hex = std.fmt.bytesToHex(raw, .lower);
        defer std.crypto.secureZero(u8, &hex);
        std.crypto.secureZero(u8, &raw);
        var added = try self.secret.addVersion(&hex);
        defer added.deinit();
        const number = added.value.number().?;

        while (true) {
            var read = try self.secret.get();
            defer read.deinit();
            var aliases: std.ArrayList(secret_manager.Alias) = .empty;
            defer aliases.deinit(self.gpa);
            for (read.value.aliases) |a| {
                if (!std.mem.eql(u8, a.name, "current")) try aliases.append(self.gpa, a);
            }
            try aliases.append(self.gpa, .{ .name = "current", .version = number });
            var moved = self.secret.update(.{ .aliases = .{ .set = aliases.items }, .etag = read.value.etag }) catch |err| switch (err) {
                error.Aborted => continue,
                else => return err,
            };
            moved.deinit();
            return number;
        }
    }
};

fn watch(
    init: std.process.Init,
    project: []const u8,
    secret: secret_manager.Secret,
    subscription_id: []const u8,
    provider: pubsub.TokenProvider,
    count: ?usize,
    out: *std.Io.Writer,
) !void {
    var diag: pubsub.Diagnostics = .{};
    var subscriber = pubsub.Subscriber.init(init.gpa, init.io, .{
        .subscription_id = subscription_id,
        .client = .{ .project_id = project, .token_provider = provider, .diagnostics = &diag },
        .concurrency = 1,
    }) catch |err| return fail(err, &diag);
    defer subscriber.deinit();
    var rotator: Rotator = .{ .gpa = init.gpa, .out = out, .secret = secret, .count = count, .subscriber = &subscriber };
    defer {
        var it = rotator.seen.keyIterator();
        while (it.next()) |k| init.gpa.free(k.*);
        rotator.seen.deinit(init.gpa);
    }
    try out.print("watching {s} for {s}\n", .{ subscription_id, secret.id });
    try out.flush();
    subscriber.run(.{ .ptr = &rotator, .vtable = &.{ .handle = Rotator.handle } }) catch |err| return fail(err, &diag);
}

/// RFC 3339, in UTC, `seconds` from now.
fn timeFromNow(io: std.Io, arena: std.mem.Allocator, seconds: u64) ![]const u8 {
    const now = std.Io.Clock.real.now(io);
    const at: u64 = @intCast(@divFloor(now.nanoseconds, std.time.ns_per_s) + @as(i96, seconds));
    const es: std.time.epoch.EpochSeconds = .{ .secs = at };
    const day = es.getEpochDay().calculateYearDay();
    const md = day.calculateMonthDay();
    const ds = es.getDaySeconds();
    return std.fmt.allocPrint(arena, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        day.year,             md.month.numeric(),      md.day_index + 1,
        ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute(),
    });
}

fn badUsage(out: *std.Io.Writer) !void {
    try out.writeAll(usage);
    try out.flush();
    std.process.exit(2);
}

fn fail(err: anyerror, diag: anytype) anyerror {
    std.debug.print("secret_rotation: {t}: {s}\n", .{ err, diag.message() });
    return err;
}
