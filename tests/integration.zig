//! Integration tests against a real Pub/Sub server.
//!
//! - Emulator: set PUBSUB_EMULATOR_HOST (and optionally PUBSUB_PROJECT_ID,
//!   default "test").
//! - Production: set PUBSUB_TEST_PROJECT and PUBSUB_TEST_TOKEN, for example
//!   `PUBSUB_TEST_TOKEN=$(gcloud auth print-access-token)`.
//!
//! With neither set, every test skips. Each test creates uniquely named
//! resources (prefix `zigps-`) and deletes them, even when it fails.

const std = @import("std");
const pubsub = @import("pubsub");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const Fixture = struct {
    env: std.process.Environ.Map,
    token: pubsub.StaticToken,
    diag: pubsub.Diagnostics,
    client: pubsub.Client,
    production: bool,
    /// "zigps-" plus 8 random hex digits, unique per test.
    prefix: [14]u8,
    arena: std.heap.ArenaAllocator,
    topics: std.ArrayList([]const u8),
    subscriptions: std.ArrayList([]const u8),

    /// Returns false when no server is configured; the test should skip.
    fn init(f: *Fixture) !bool {
        const gpa = testing.allocator;
        f.env = try testing.environ.createMap(gpa);
        errdefer f.env.deinit();
        f.diag = .{};
        f.arena = .init(gpa);
        errdefer f.arena.deinit();
        f.topics = .empty;
        f.subscriptions = .empty;

        var random: [4]u8 = undefined;
        testing.io.random(&random);
        _ = try std.fmt.bufPrint(&f.prefix, "zigps-{x}", .{random});

        const emulator = pubsub.Endpoint.fromEnv(&f.env);
        const project = if (emulator != null)
            f.env.get("PUBSUB_PROJECT_ID") orelse "test"
        else
            f.env.get("PUBSUB_TEST_PROJECT") orelse {
                f.arena.deinit();
                f.env.deinit();
                return false;
            };
        f.production = emulator == null;
        if (f.production) {
            const token = f.env.get("PUBSUB_TEST_TOKEN") orelse {
                f.arena.deinit();
                f.env.deinit();
                return false;
            };
            f.token = .{ .token = std.mem.trim(u8, token, &std.ascii.whitespace) };
        } else {
            f.token = .{ .token = "" };
        }
        f.client = try .init(gpa, testing.io, .{
            .project_id = project,
            .endpoint = emulator,
            .token_provider = if (f.production) f.token.provider() else null,
            .diagnostics = &f.diag,
            .user_agent = "zig-pubsub-integration/0.1",
        });
        return true;
    }

    /// Deletes everything the test created, subscriptions first.
    fn deinit(f: *Fixture) void {
        for (f.subscriptions.items) |sub_id| f.client.subscription(sub_id).delete() catch {};
        for (f.topics.items) |topic_id| f.client.topic(topic_id).delete() catch {};
        f.subscriptions.deinit(testing.allocator);
        f.topics.deinit(testing.allocator);
        f.client.deinit();
        f.arena.deinit();
        f.env.deinit();
    }

    /// A unique id: the prefix plus `suffix`.
    fn id(f: *Fixture, suffix: []const u8) []const u8 {
        return std.fmt.allocPrint(f.arena.allocator(), "{s}-{s}", .{ &f.prefix, suffix }) catch @panic("OOM");
    }

    // Resources are registered for cleanup before the create call: a call
    // can fail after the server created the resource.
    fn createTopic(f: *Fixture, suffix: []const u8) !pubsub.Topic {
        const topic = f.client.topic(f.id(suffix));
        try f.topics.append(testing.allocator, topic.id);
        var info = topic.create(.{}) catch |err| return f.fail(err);
        info.deinit();
        return topic;
    }

    fn createSubscription(f: *Fixture, suffix: []const u8, config: pubsub.SubscriptionConfig) !pubsub.Subscription {
        const sub = f.client.subscription(f.id(suffix));
        try f.subscriptions.append(testing.allocator, sub.id);
        var info = sub.create(config) catch |err| return f.fail(err);
        info.deinit();
        return sub;
    }

    fn fail(f: *Fixture, err: anyerror) anyerror {
        std.debug.print("{t}: HTTP {d} {s}: {s}\n", .{ err, f.diag.http_status, f.diag.status(), f.diag.message() });
        return err;
    }

    /// Seconds to wait for server-side effects: a new subscription starts
    /// receiving, a redelivery happens. Production needs longer.
    fn patience(f: *const Fixture) i64 {
        return if (f.production) 90 else 30;
    }
};

/// Messages copied out of pull results so they outlive them.
const Collector = struct {
    arena: std.heap.ArenaAllocator,
    messages: std.ArrayList(Received) = .empty,

    const Received = struct {
        ack_id: []const u8,
        message_id: []const u8,
        data: []const u8,
        attributes: []const pubsub.Attribute,
        ordering_key: []const u8,
        publish_time: []const u8,
    };

    fn init() Collector {
        return .{ .arena = .init(testing.allocator) };
    }

    fn deinit(c: *Collector) void {
        c.arena.deinit();
    }

    fn add(c: *Collector, m: pubsub.ReceivedMessage) !void {
        const a = c.arena.allocator();
        const attrs = try a.alloc(pubsub.Attribute, m.attributes.len);
        for (m.attributes, attrs) |src, *dst| dst.* = .{ .key = try a.dupe(u8, src.key), .value = try a.dupe(u8, src.value) };
        try c.messages.append(a, .{
            .ack_id = try a.dupe(u8, m.ack_id),
            .message_id = try a.dupe(u8, m.message_id),
            .data = try a.dupe(u8, m.data),
            .attributes = attrs,
            .ordering_key = try a.dupe(u8, m.ordering_key),
            .publish_time = try a.dupe(u8, m.publish_time),
        });
    }

    fn find(c: *const Collector, data: []const u8) ?Received {
        for (c.messages.items) |m| if (std.mem.eql(u8, m.data, data)) return m;
        return null;
    }
};

fn nowMs() i64 {
    return std.Io.Clock.awake.now(testing.io).toMilliseconds();
}

/// Pulls until at least `want` messages arrived, acking each batch when
/// `ack` is set. Fails after `timeout_s` seconds.
fn pullUntil(f: *Fixture, sub: pubsub.Subscription, want: usize, timeout_s: i64, into: *Collector, ack: bool) !void {
    const deadline = nowMs() + timeout_s * 1000;
    while (into.messages.items.len < want) {
        if (nowMs() > deadline) {
            std.debug.print("timed out with {d} of {d} messages\n", .{ into.messages.items.len, want });
            return error.TestTimedOut;
        }
        var batch = sub.pull(.{ .max_messages = 1000, .return_immediately = true }) catch |err| return f.fail(err);
        defer batch.deinit();
        for (batch.value.messages) |m| try into.add(m);
        if (ack and batch.value.messages.len > 0) {
            const ids = try testing.allocator.alloc([]const u8, batch.value.messages.len);
            defer testing.allocator.free(ids);
            for (batch.value.messages, ids) |m, *id| id.* = m.ack_id;
            sub.ack(ids) catch |err| return f.fail(err);
        }
        if (batch.value.messages.len == 0) try testing.io.sleep(.fromMilliseconds(250), .awake);
    }
}

/// Pulls briefly and fails if anything arrives.
fn expectNoMessages(f: *Fixture, sub: pubsub.Subscription) !void {
    for (0..3) |_| {
        var batch = sub.pull(.{ .return_immediately = true }) catch |err| return f.fail(err);
        defer batch.deinit();
        if (batch.value.messages.len != 0) {
            std.debug.print("unexpected message {s}\n", .{batch.value.messages[0].message_id});
            return error.TestUnexpectedMessage;
        }
        try testing.io.sleep(.fromMilliseconds(200), .awake);
    }
}

/// Retries `check` until it stops failing, for eventually consistent reads.
fn eventually(f: *Fixture, timeout_s: i64, context: anytype, comptime check: fn (@TypeOf(context)) anyerror!void) !void {
    const deadline = nowMs() + timeout_s * 1000;
    while (true) {
        check(context) catch |err| {
            if (nowMs() > deadline) return f.fail(err);
            try testing.io.sleep(.fromMilliseconds(500), .awake);
            continue;
        };
        return;
    }
}

fn publishOne(f: *Fixture, topic: pubsub.Topic, message: pubsub.Message, options: pubsub.PublishOptions) ![]const u8 {
    var sent = topic.publish(&.{message}, options) catch |err| return f.fail(err);
    defer sent.deinit();
    return f.arena.allocator().dupe(u8, sent.value.message_ids[0]);
}

// 1. Topic lifecycle.
test "topic: create, get, find in list, delete, then NotFound" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();

    const topic = f.client.topic(f.id("life"));
    try f.topics.append(testing.allocator, topic.id);
    var created = topic.create(.{}) catch |err| return f.fail(err);
    defer created.deinit();
    try testing.expect(std.mem.endsWith(u8, created.value.name, topic.id));

    var got = topic.get() catch |err| return f.fail(err);
    defer got.deinit();
    try testing.expectEqualStrings(created.value.name, got.value.name);

    // Find it in the list, following pages.
    var found = false;
    var token: ?[]const u8 = null;
    var token_arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer token_arena.deinit();
    for (0..1000) |_| {
        var page = f.client.listTopics(.{ .page_size = 100, .page_token = token }) catch |err| return f.fail(err);
        defer page.deinit();
        for (page.value.topics) |t| found = found or std.mem.eql(u8, t.name, created.value.name);
        token = if (page.value.next_page_token) |t| try token_arena.allocator().dupe(u8, t) else null;
        if (found or token == null) break;
    }
    try testing.expect(found);

    topic.delete() catch |err| return f.fail(err);
    const Check = struct {
        fn gone(t: pubsub.Topic) anyerror!void {
            var info = t.get() catch |err| switch (err) {
                error.NotFound => return,
                else => return err,
            };
            info.deinit();
            return error.TestStillExists;
        }
    };
    try eventually(&f, 30, topic, Check.gone);
    try testing.expectEqual(404, f.diag.http_status);
    try testing.expectEqualStrings("NOT_FOUND", f.diag.status());
}

// 2.
test "topic: creating the same topic twice is AlreadyExists" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    const topic = try f.createTopic("twice");
    try testing.expectError(error.AlreadyExists, topic.create(.{}));
    try testing.expectEqual(409, f.diag.http_status);
    try testing.expectEqualStrings("ALREADY_EXISTS", f.diag.status());
    try testing.expect(f.diag.message().len > 0);
}

// 3.
test "subscription: creating one on a missing topic is NotFound" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    const sub = f.client.subscription(f.id("orphan"));
    try testing.expectError(error.NotFound, sub.create(.{ .topic_id = f.id("no-such-topic") }));
    try testing.expectEqualStrings("NOT_FOUND", f.diag.status());
}

// 4.
test "round trip: publish 3, pull, compare exactly, ack, then nothing left" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    const topic = try f.createTopic("rt");
    const sub = try f.createSubscription("rt-sub", .{ .topic_id = topic.id });

    const messages = [_]pubsub.Message{
        .{ .data = "first message", .attributes = &.{.{ .key = "n", .value = "1" }} },
        .{ .data = "second, with ünïcödé and \"quotes\"", .attributes = &.{ .{ .key = "n", .value = "2" }, .{ .key = "kind", .value = "test" } } },
        .{ .data = "third\x00with\nbytes", .attributes = &.{.{ .key = "n", .value = "3" }} },
    };
    var sent = topic.publish(&messages, .{}) catch |err| return f.fail(err);
    defer sent.deinit();
    try testing.expectEqual(3, sent.value.message_ids.len);

    var got: Collector = .init();
    defer got.deinit();
    try pullUntil(&f, sub, 3, f.patience(), &got, true);
    try testing.expectEqual(3, got.messages.items.len);
    for (messages, sent.value.message_ids) |want, id| {
        const m = got.find(want.data) orelse return error.TestMessageMissing;
        try testing.expectEqualStrings(id, m.message_id);
        try testing.expectEqual(want.attributes.len, m.attributes.len);
        for (want.attributes) |attr| {
            var matched = false;
            for (m.attributes) |g| matched = matched or (std.mem.eql(u8, g.key, attr.key) and std.mem.eql(u8, g.value, attr.value));
            try testing.expect(matched);
        }
        _ = try pubsub.parseTimestamp(m.publish_time);
    }
    try expectNoMessages(&f, sub);
}

// 5.
test "binary safety: all 256 byte values survive the round trip" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    const topic = try f.createTopic("bin");
    const sub = try f.createSubscription("bin-sub", .{ .topic_id = topic.id });
    var all: [256]u8 = undefined;
    for (&all, 0..) |*b, i| b.* = @intCast(i);
    _ = try publishOne(&f, topic, .{ .data = &all }, .{});
    var got: Collector = .init();
    defer got.deinit();
    try pullUntil(&f, sub, 1, f.patience(), &got, true);
    try testing.expectEqualSlices(u8, &all, got.messages.items[0].data);
}

// 6.
test "attribute-only message with empty data" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    const topic = try f.createTopic("attr");
    const sub = try f.createSubscription("attr-sub", .{ .topic_id = topic.id });
    _ = try publishOne(&f, topic, .{ .attributes = &.{.{ .key = "only", .value = "attributes" }} }, .{});
    var got: Collector = .init();
    defer got.deinit();
    try pullUntil(&f, sub, 1, f.patience(), &got, true);
    const m = got.messages.items[0];
    try testing.expectEqual(0, m.data.len);
    try testing.expectEqual(1, m.attributes.len);
    try testing.expectEqualStrings("only", m.attributes[0].key);
    try testing.expectEqualStrings("attributes", m.attributes[0].value);
}

// 7.
test "nack: the same message comes back" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    const topic = try f.createTopic("nack");
    const sub = try f.createSubscription("nack-sub", .{ .topic_id = topic.id, .ack_deadline_seconds = 60 });
    const id = try publishOne(&f, topic, .{ .data = "nack me" }, .{});

    var first: Collector = .init();
    defer first.deinit();
    try pullUntil(&f, sub, 1, f.patience(), &first, false);
    try testing.expectEqualStrings(id, first.messages.items[0].message_id);
    sub.nack(&.{first.messages.items[0].ack_id}) catch |err| return f.fail(err);

    var again: Collector = .init();
    defer again.deinit();
    try pullUntil(&f, sub, 1, f.patience(), &again, true);
    try testing.expectEqualStrings(id, again.messages.items[0].message_id);
}

// 8.
test "deadline: an unacked message is redelivered after its deadline" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    const topic = try f.createTopic("dl");
    const sub = try f.createSubscription("dl-sub", .{ .topic_id = topic.id, .ack_deadline_seconds = 10 });
    const id = try publishOne(&f, topic, .{ .data = "let it expire" }, .{});

    var first: Collector = .init();
    defer first.deinit();
    try pullUntil(&f, sub, 1, f.patience(), &first, false);
    const pulled_at = nowMs();

    var again: Collector = .init();
    defer again.deinit();
    try pullUntil(&f, sub, 1, 10 + f.patience(), &again, true);
    try testing.expectEqualStrings(id, again.messages.items[0].message_id);
    // Not before the deadline (allowing a second of clock slack).
    try testing.expect(nowMs() - pulled_at >= 9_000);
}

// 9.
test "ordering key: messages arrive in publish order" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    const topic = try f.createTopic("ord");
    const sub = try f.createSubscription("ord-sub", .{ .topic_id = topic.id, .enable_message_ordering = true });

    const bodies = [_][]const u8{ "0", "1", "2", "3", "4" };
    for (bodies) |b| _ = try publishOne(&f, topic, .{ .data = b }, .{ .ordering_key = "user-42" });

    var got: Collector = .init();
    defer got.deinit();
    try pullUntil(&f, sub, bodies.len, f.patience(), &got, true);
    try testing.expectEqual(bodies.len, got.messages.items.len);
    for (bodies, got.messages.items) |want, m| {
        try testing.expectEqualStrings(want, m.data);
        try testing.expectEqualStrings("user-42", m.ordering_key);
    }
}

// 10.
test "pagination: list topics two at a time until the token runs out" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    var names: [5][]const u8 = undefined;
    for (&names, 0..) |*n, i| {
        var buf: [8]u8 = undefined;
        n.* = (try f.createTopic(try std.fmt.bufPrint(&buf, "page-{d}", .{i}))).id;
    }

    var seen: [5]bool = @splat(false);
    var pages: usize = 0;
    var token: ?[]const u8 = null;
    var token_arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer token_arena.deinit();
    while (true) : (pages += 1) {
        if (pages > 5000) return error.TestTooManyPages;
        var page = f.client.listTopics(.{ .page_size = 2, .page_token = token }) catch |err| return f.fail(err);
        defer page.deinit();
        try testing.expect(page.value.topics.len <= 2);
        for (page.value.topics) |t| {
            for (names, &seen) |n, *s| {
                if (std.mem.endsWith(u8, t.name, n)) s.* = true;
            }
        }
        token = if (page.value.next_page_token) |t| try token_arena.allocator().dupe(u8, t) else break;
    }
    for (seen) |s| try testing.expect(s);
    try testing.expect(pages >= 2);
}

test "pagination: list subscriptions two at a time" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    const topic = try f.createTopic("subpage");
    var names: [3][]const u8 = undefined;
    for (&names, 0..) |*n, i| {
        var buf: [8]u8 = undefined;
        n.* = (try f.createSubscription(try std.fmt.bufPrint(&buf, "s-{d}", .{i}), .{ .topic_id = topic.id })).id;
    }
    var seen: [3]bool = @splat(false);
    var token: ?[]const u8 = null;
    var token_arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer token_arena.deinit();
    for (0..5000) |_| {
        var page = f.client.listSubscriptions(.{ .page_size = 2, .page_token = token }) catch |err| return f.fail(err);
        defer page.deinit();
        for (page.value.subscriptions) |s| {
            for (names, &seen) |n, *hit| {
                if (std.mem.endsWith(u8, s.name, n)) hit.* = true;
            }
        }
        token = if (page.value.next_page_token) |t| try token_arena.allocator().dupe(u8, t) else break;
    }
    for (seen) |s| try testing.expect(s);
}

test "ids with literal % and + reach the server intact" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    // Unencoded, the server would decode %41 and create "...-aAb".
    const topic = try f.createTopic("a%41+b");
    var got = topic.get() catch |err| return f.fail(err);
    defer got.deinit();
    try testing.expect(std.mem.endsWith(u8, got.value.name, "-a%41+b"));
    // The emulator (0.8.35) decodes a literal "%25" twice, storing "%".
    // Production decodes once, like `%41` above.
    const sub_suffix = if (f.production) "s%25+x~y" else "s%7E+x~y";
    const sub = try f.createSubscription(sub_suffix, .{ .topic_id = topic.id });
    var info = sub.get() catch |err| return f.fail(err);
    defer info.deinit();
    try testing.expect(std.mem.endsWith(u8, info.value.name, sub_suffix));
    try testing.expect(std.mem.endsWith(u8, info.value.topic, "-a%41+b"));
}

test "subscription get reflects its configuration" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    const topic = try f.createTopic("cfg");
    const sub = try f.createSubscription("cfg-sub", .{ .topic_id = topic.id, .ack_deadline_seconds = 42, .enable_message_ordering = true });
    var info = sub.get() catch |err| return f.fail(err);
    defer info.deinit();
    try testing.expectEqual(42, info.value.ack_deadline_seconds);
    try testing.expect(info.value.enable_message_ordering);
    try testing.expect(std.mem.endsWith(u8, info.value.topic, topic.id));
}

test "limits: the largest attributes and a 1 MiB payload round-trip" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    const topic = try f.createTopic("big");
    const sub = try f.createSubscription("big-sub", .{ .topic_id = topic.id });

    const gpa = testing.allocator;
    const data = try gpa.alloc(u8, 1024 * 1024);
    defer gpa.free(data);
    var prng: std.Random.DefaultPrng = .init(42);
    prng.random().bytes(data);

    var attrs: [pubsub.limits.max_attributes]pubsub.Attribute = undefined;
    var keys: [pubsub.limits.max_attributes][pubsub.limits.max_attribute_key_bytes]u8 = undefined;
    const value: [pubsub.limits.max_attribute_value_bytes]u8 = @splat('v');
    for (&attrs, &keys, 0..) |*a, *k, i| {
        @memset(k, 'k');
        _ = std.fmt.bufPrint(k, "{d:0>3}", .{i}) catch unreachable;
        a.* = .{ .key = k, .value = &value };
    }
    _ = try publishOne(&f, topic, .{ .data = data, .attributes = &attrs }, .{});

    var got: Collector = .init();
    defer got.deinit();
    try pullUntil(&f, sub, 1, f.patience(), &got, true);
    const m = got.messages.items[0];
    try testing.expectEqualSlices(u8, data, m.data);
    try testing.expectEqual(attrs.len, m.attributes.len);
}

test "batch: 1000 messages in one publish, pulled and acked in bulk" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    const topic = try f.createTopic("batch");
    const sub = try f.createSubscription("batch-sub", .{ .topic_id = topic.id, .ack_deadline_seconds = 120 });

    var bodies: [1000][8]u8 = undefined;
    var messages: [1000]pubsub.Message = undefined;
    for (&bodies, &messages, 0..) |*b, *m, i| {
        _ = std.fmt.bufPrint(b, "{d:0>8}", .{i}) catch unreachable;
        m.* = .{ .data = b };
    }
    var sent = topic.publish(&messages, .{}) catch |err| return f.fail(err);
    defer sent.deinit();
    try testing.expectEqual(1000, sent.value.message_ids.len);

    // Collect everything first, then ack all ids in a single call.
    var got: Collector = .init();
    defer got.deinit();
    try pullUntil(&f, sub, 1000, 2 * f.patience(), &got, false);
    const ids = try testing.allocator.alloc([]const u8, got.messages.items.len);
    defer testing.allocator.free(ids);
    for (got.messages.items, ids) |m, *id| id.* = m.ack_id;
    sub.ack(ids) catch |err| return f.fail(err);

    var distinct: std.StringHashMapUnmanaged(void) = .empty;
    defer distinct.deinit(testing.allocator);
    for (got.messages.items) |m| try distinct.put(testing.allocator, m.data, {});
    try testing.expectEqual(1000, distinct.count());
    try expectNoMessages(&f, sub);
}

test "modifyAckDeadline extends the lease" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    const topic = try f.createTopic("lease");
    const sub = try f.createSubscription("lease-sub", .{ .topic_id = topic.id, .ack_deadline_seconds = 10 });
    _ = try publishOne(&f, topic, .{ .data = "hold" }, .{});

    var got: Collector = .init();
    defer got.deinit();
    try pullUntil(&f, sub, 1, f.patience(), &got, false);
    const ack_id = got.messages.items[0].ack_id;
    sub.modifyAckDeadline(&.{ack_id}, 120) catch |err| return f.fail(err);
    // Past the original 10 s deadline, the message is still leased to us.
    try testing.io.sleep(.fromSeconds(14), .awake);
    try expectNoMessages(&f, sub);
    sub.ack(&.{ack_id}) catch |err| return f.fail(err);
}

test "calls on deleted resources are NotFound" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    const topic = f.client.topic(f.id("never-created"));
    try testing.expectError(error.NotFound, topic.publish(&.{.{ .data = "x" }}, .{}));
    try testing.expectError(error.NotFound, topic.delete());
    const sub = f.client.subscription(f.id("never-created-sub"));
    try testing.expectError(error.NotFound, sub.pull(.{ .return_immediately = true }));
    try testing.expectError(error.NotFound, sub.get());
}

test "empty pull with return_immediately returns promptly" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    const topic = try f.createTopic("empty");
    const sub = try f.createSubscription("empty-sub", .{ .topic_id = topic.id });
    const started = nowMs();
    var batch = sub.pull(.{ .return_immediately = true }) catch |err| return f.fail(err);
    defer batch.deinit();
    try testing.expectEqual(0, batch.value.messages.len);
    try testing.expect(nowMs() - started < 10_000);
}

test "cancel: a held pull returns error.Canceled when its task is canceled" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    const topic = try f.createTopic("cancel");
    const sub = try f.createSubscription("cancel-sub", .{ .topic_id = topic.id });

    const Pull = struct {
        fn run(s: pubsub.Subscription) pubsub.Error!usize {
            var batch = try s.pull(.{});
            defer batch.deinit();
            return batch.value.messages.len;
        }
    };
    // Without return_immediately the server holds an empty pull open.
    var pending = try testing.io.concurrent(Pull.run, .{sub});
    try testing.io.sleep(.fromMilliseconds(500), .awake);
    const started = nowMs();
    try testing.expectError(error.Canceled, pending.cancel(testing.io));
    try testing.expect(nowMs() - started < 2_000);

    // The client still works after a canceled call.
    var info = sub.get() catch |err| return f.fail(err);
    info.deinit();
}

test "timeout: race a held pull against a sleep with Io.Select" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    const topic = try f.createTopic("race");
    const sub = try f.createSubscription("race-sub", .{ .topic_id = topic.id });

    // The pattern from the README: whichever finishes first wins, and the
    // other is canceled. An empty subscription holds the pull open, so the
    // timer wins here.
    const Race = union(enum) {
        pulled: pubsub.Error!pubsub.Owned(pubsub.PullResult),
        timed_out: std.Io.Cancelable!void,
    };
    var buffer: [2]Race = undefined;
    var select: std.Io.Select(Race) = .init(testing.io, &buffer);
    try select.concurrent(.pulled, pubsub.Subscription.pull, .{ sub, .{} });
    try select.concurrent(.timed_out, std.Io.sleep, .{ testing.io, .fromMilliseconds(500), .awake });
    const started = nowMs();
    const first = try select.await();
    // Cancel the loser. It may have finished first, so free what it returned.
    while (select.cancel()) |other| switch (other) {
        .pulled => |result| if (result) |owned| {
            var batch = owned;
            batch.deinit();
        } else |_| {},
        .timed_out => {},
    };
    try testing.expect(first == .timed_out);
    try testing.expect(nowMs() - started < 5_000);
}

/// A handler for the subscriber tests: counts distinct message bodies,
/// optionally failing each body's first delivery, and stops the
/// subscriber once `want` distinct bodies succeeded.
const Worker = struct {
    gpa: Allocator = undefined,
    subscriber: *pubsub.Subscriber = undefined,
    want: usize = 0,
    fail_first: bool = false,
    sleep_ms: i64 = 0,
    mutex: std.Io.Mutex = .init,
    /// Body -> deliveries seen (successes and failures).
    deliveries: std.StringHashMapUnmanaged(usize) = .empty,
    distinct_done: usize = 0,

    fn deinit(w: *Worker) void {
        var it = w.deliveries.keyIterator();
        while (it.next()) |key| w.gpa.free(key.*);
        w.deliveries.deinit(w.gpa);
    }

    fn handler(w: *Worker) pubsub.Subscriber.Handler {
        return .{ .ptr = w, .vtable = &.{ .handle = handle } };
    }

    fn handle(ptr: *anyopaque, io: std.Io, message: pubsub.ReceivedMessage) anyerror!void {
        const w: *Worker = @ptrCast(@alignCast(ptr));
        if (w.sleep_ms > 0) try io.sleep(.fromMilliseconds(w.sleep_ms), .awake);
        w.mutex.lockUncancelable(io);
        defer w.mutex.unlock(io);
        const entry = try w.deliveries.getOrPut(w.gpa, message.data);
        if (!entry.found_existing) {
            entry.key_ptr.* = try w.gpa.dupe(u8, message.data);
            entry.value_ptr.* = 0;
        }
        entry.value_ptr.* += 1;
        if (w.fail_first and entry.value_ptr.* == 1) return error.FirstDeliveryRefused;
        if (entry.value_ptr.* == @as(usize, if (w.fail_first) 2 else 1)) {
            w.distinct_done += 1;
            if (w.distinct_done >= w.want) w.subscriber.stop();
        }
    }

    fn done(w: *Worker) bool {
        w.mutex.lockUncancelable(testing.io);
        defer w.mutex.unlock(testing.io);
        return w.distinct_done >= w.want;
    }
};

/// Builds a subscriber against the fixture's server and runs it under
/// `worker`'s control, failing rather than hanging if it never finishes.
fn runSubscriber(f: *Fixture, sub: pubsub.Subscription, worker: *Worker, concurrency: u16, timeout_s: i64) !pubsub.Subscriber.Stats {
    const io = testing.io;
    var subscriber: pubsub.Subscriber = try .init(testing.allocator, io, .{
        .subscription_id = sub.id,
        .client = .{
            .project_id = f.client.project_id,
            .endpoint = .{ .url = f.client.base_url, .emulator = f.client.emulator },
            .token_provider = if (f.production) f.token.provider() else null,
        },
        .concurrency = concurrency,
    });
    defer subscriber.deinit();
    worker.subscriber = &subscriber;

    var running = try io.concurrent(pubsub.Subscriber.run, .{ &subscriber, worker.handler() });
    const deadline = nowMs() + timeout_s * 1000;
    while (!worker.done()) {
        if (nowMs() > deadline) {
            _ = running.cancel(io) catch {};
            std.debug.print("subscriber timed out with {d} of {d} done\n", .{ worker.distinct_done, worker.want });
            return error.TestTimedOut;
        }
        try io.sleep(.fromMilliseconds(100), .awake);
    }
    running.await(io) catch |err| return f.fail(err);
    return subscriber.stats();
}

test "subscriber: concurrent handlers process every message, then ack it away" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    const topic = try f.createTopic("subw");
    const sub = try f.createSubscription("subw-sub", .{ .topic_id = topic.id });

    var bodies: [40][8]u8 = undefined;
    var messages: [40]pubsub.Message = undefined;
    for (&bodies, &messages, 0..) |*b, *m, i| {
        _ = std.fmt.bufPrint(b, "{d:0>8}", .{i}) catch unreachable;
        m.* = .{ .data = b };
    }
    var sent = topic.publish(&messages, .{}) catch |err| return f.fail(err);
    sent.deinit();

    var worker: Worker = .{ .gpa = testing.allocator, .want = 40 };
    defer worker.deinit();
    const counts = try runSubscriber(&f, sub, &worker, 4, f.patience());
    try testing.expectEqual(40, worker.deliveries.count());
    try testing.expect(counts.acked >= 40);
    try testing.expectEqual(counts.received, counts.acked + counts.nacked);
    try expectNoMessages(&f, sub);
}

test "subscriber: a failing handler sees the message again, and nothing is lost" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    const topic = try f.createTopic("subr");
    const sub = try f.createSubscription("subr-sub", .{ .topic_id = topic.id });
    for (0..10) |i| {
        var buf: [8]u8 = undefined;
        _ = try publishOne(&f, topic, .{ .data = try std.fmt.bufPrint(&buf, "retry-{d}", .{i}) }, .{});
    }

    var worker: Worker = .{ .gpa = testing.allocator, .want = 10, .fail_first = true };
    defer worker.deinit();
    const counts = try runSubscriber(&f, sub, &worker, 2, 2 * f.patience());
    try testing.expectEqual(10, worker.deliveries.count());
    try testing.expect(counts.handler_failures >= 10);
    try testing.expect(counts.acked >= 10);
    try expectNoMessages(&f, sub);
}

test "subscriber: lease extension carries a handler past the ack deadline" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    const topic = try f.createTopic("sublease");
    const sub = try f.createSubscription("sublease-sub", .{ .topic_id = topic.id, .ack_deadline_seconds = 10 });
    _ = try publishOne(&f, topic, .{ .data = "hold me past the deadline" }, .{});

    // The handler outlives the 10 s deadline; the subscriber's extensions
    // must keep the message leased, so it is handled exactly once.
    var worker: Worker = .{ .gpa = testing.allocator, .want = 1, .sleep_ms = 15_000 };
    defer worker.deinit();
    const counts = try runSubscriber(&f, sub, &worker, 1, 30 + f.patience());
    try testing.expectEqual(1, worker.deliveries.count());
    try testing.expectEqual(1, worker.deliveries.get("hold me past the deadline").?);
    try testing.expect(counts.extended >= 1);
    try testing.expectEqual(1, counts.acked);
    try expectNoMessages(&f, sub);
}

// Publisher.

const Publisher = pubsub.Publisher;

const PublisherKnobs = struct {
    concurrency: u16 = 4,
    max_batch_messages: u16 = 100,
    max_batch_bytes: u32 = 1_000_000,
    max_batch_delay_ms: u32 = 10,
    enable_message_ordering: bool = false,
    max_outstanding_bytes: u64 = 10_000_000,
};

/// Options for a publisher on the fixture's server.
fn publisherOptions(f: *Fixture, topic_id: []const u8, knobs: PublisherKnobs) Publisher.Options {
    return .{
        .topic_id = topic_id,
        .client = .{
            .project_id = f.client.project_id,
            .endpoint = .{ .url = f.client.base_url, .emulator = f.client.emulator },
            .token_provider = if (f.production) f.token.provider() else null,
            .user_agent = "zig-pubsub-integration/0.1",
            // A publisher never holds a pull open: a stalled request should
            // be retried long before the default three minutes.
            .request_timeout_ms = 30_000,
        },
        .concurrency = knobs.concurrency,
        .max_batch_messages = knobs.max_batch_messages,
        .max_batch_bytes = knobs.max_batch_bytes,
        .max_batch_delay_ms = knobs.max_batch_delay_ms,
        .enable_message_ordering = knobs.enable_message_ordering,
        .max_outstanding_bytes = knobs.max_outstanding_bytes,
    };
}

/// A publisher running on a task of its own until `finish`.
const LivePublisher = struct {
    publisher: Publisher,
    running: ?std.Io.Future(Publisher.Error!void) = null,

    fn start(l: *LivePublisher, options: Publisher.Options) !void {
        l.* = .{ .publisher = try .init(testing.allocator, testing.io, options) };
        errdefer l.publisher.deinit();
        l.running = try testing.io.concurrent(Publisher.run, .{&l.publisher});
    }

    /// Stops the publisher and returns what `run` returns.
    fn finish(l: *LivePublisher) Publisher.Error!void {
        l.publisher.stop();
        var running = l.running orelse return;
        l.running = null;
        return running.await(testing.io);
    }

    fn deinit(l: *LivePublisher) void {
        if (l.running != null) l.finish() catch {};
        l.publisher.deinit();
    }
};

/// `receipt.wait()`, failing rather than hanging after `timeout_s`.
fn waitReceipt(receipt: Publisher.Receipt, timeout_s: i64) ![]const u8 {
    const deadline = nowMs() + timeout_s * 1000;
    while (!receipt.batch.resolved.isSet()) {
        if (nowMs() > deadline) return error.TestTimedOut;
        try testing.io.sleep(.fromMilliseconds(10), .awake);
    }
    return receipt.wait();
}

test "publisher: several tasks publish 1,000 messages in far fewer requests, and every one arrives" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    const topic = try f.createTopic("pubv");
    const sub = try f.createSubscription("pubv-sub", .{ .topic_id = topic.id });

    var live: LivePublisher = undefined;
    try live.start(publisherOptions(&f, topic.id, .{}));
    defer live.deinit();

    const per_task = 250;
    const Task = struct {
        fn publishMany(p: *Publisher, task: usize) anyerror!void {
            var receipts: [per_task]Publisher.Receipt = undefined;
            var made: usize = 0;
            defer for (receipts[0..made]) |r| r.release();
            for (&receipts, 0..) |*r, i| {
                var buf: [16]u8 = undefined;
                r.* = try p.publish(.{ .data = try std.fmt.bufPrint(&buf, "t{d}-{d:0>3}", .{ task, i }) }, .{});
                made += 1;
            }
            for (receipts) |r| _ = try waitReceipt(r, 60);
        }
    };
    var tasks: [4]std.Io.Future(anyerror!void) = undefined;
    var started: usize = 0;
    defer for (tasks[0..started]) |*task| task.cancel(testing.io) catch {};
    for (&tasks, 0..) |*task, i| {
        task.* = try testing.io.concurrent(Task.publishMany, .{ &live.publisher, i });
        started += 1;
    }
    for (tasks[0..started]) |*task| try task.await(testing.io);
    try live.finish();

    const counts = live.publisher.stats();
    try testing.expectEqual(4 * per_task, counts.succeeded);
    try testing.expect(counts.requests < 100);

    var got: Collector = .init();
    defer got.deinit();
    try pullUntil(&f, sub, 4 * per_task, f.patience(), &got, true);
    for (0..4) |t| for (0..per_task) |i| {
        var buf: [16]u8 = undefined;
        const data = try std.fmt.bufPrint(&buf, "t{d}-{d:0>3}", .{ t, i });
        if (got.find(data) == null) {
            std.debug.print("{s} never arrived\n", .{data});
            return error.TestMessageMissing;
        }
    };
}

test "publisher: each ordering key's messages arrive in publish order on an ordered subscription" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    const topic = try f.createTopic("pubord");
    const sub = try f.createSubscription("pubord-sub", .{ .topic_id = topic.id, .enable_message_ordering = true });

    var live: LivePublisher = undefined;
    try live.start(publisherOptions(&f, topic.id, .{ .max_batch_messages = 5, .enable_message_ordering = true }));
    defer live.deinit();

    // Three tasks, a key each, publishing at once: the keys' batches
    // interleave across the four connections.
    const per_key = 20;
    const Task = struct {
        fn publishKey(p: *Publisher, k: usize) anyerror!void {
            var key_buf: [8]u8 = undefined;
            const key = try std.fmt.bufPrint(&key_buf, "key-{d}", .{k});
            var receipts: [per_key]Publisher.Receipt = undefined;
            var made: usize = 0;
            defer for (receipts[0..made]) |r| r.release();
            for (&receipts, 0..) |*r, i| {
                var buf: [16]u8 = undefined;
                r.* = try p.publish(.{ .data = try std.fmt.bufPrint(&buf, "k{d}-{d:0>2}", .{ k, i }) }, .{ .ordering_key = key });
                made += 1;
            }
            for (receipts) |r| _ = try waitReceipt(r, 60);
        }
    };
    var tasks: [3]std.Io.Future(anyerror!void) = undefined;
    var started: usize = 0;
    defer for (tasks[0..started]) |*task| task.cancel(testing.io) catch {};
    for (&tasks, 0..) |*task, k| {
        task.* = try testing.io.concurrent(Task.publishKey, .{ &live.publisher, k });
        started += 1;
    }
    for (tasks[0..started]) |*task| try task.await(testing.io);
    try live.finish();

    var got: Collector = .init();
    defer got.deinit();
    try pullUntil(&f, sub, 3 * per_key, f.patience(), &got, true);
    // Each key's messages in order, counting a redelivered one once.
    for (0..3) |k| {
        var next: usize = 0;
        var key_buf: [8]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buf, "key-{d}", .{k});
        for (got.messages.items) |m| {
            if (!std.mem.eql(u8, m.ordering_key, key)) continue;
            var buf: [16]u8 = undefined;
            if (next < per_key and std.mem.eql(u8, m.data, try std.fmt.bufPrint(&buf, "k{d}-{d:0>2}", .{ k, next }))) {
                next += 1;
            } else {
                // Anything else must be a repeat of one already seen.
                const i = try std.fmt.parseInt(usize, m.data[m.data.len - 2 ..], 10);
                try testing.expect(i < next);
            }
        }
        try testing.expectEqual(per_key, next);
    }
}

test "publisher: a lone message goes out once its delay runs out" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    const topic = try f.createTopic("pubdelay");
    var live: LivePublisher = undefined;
    try live.start(publisherOptions(&f, topic.id, .{ .max_batch_delay_ms = 50 }));
    defer live.deinit();

    const started = nowMs();
    const receipt = try live.publisher.publish(.{ .data = "alone" }, .{});
    defer receipt.release();
    _ = try waitReceipt(receipt, 30);
    const elapsed = nowMs() - started;
    // Not before the delay, and not long after: no stop, only the timer.
    try testing.expect(elapsed >= 45);
    try testing.expect(elapsed < 10_000);
    try live.finish();
    try testing.expectEqual(1, live.publisher.stats().requests);
}

test "publisher: a batch at exactly the 10,485,760-byte limit is accepted, and a byte more splits it" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    const topic = try f.createTopic("publimit");
    const gpa = testing.allocator;
    const limit = pubsub.limits.max_publish_request_bytes;

    // Two messages that fill a request to the byte: one of plain data, and
    // one whose attribute takes up the last few bytes.
    const first_data = try gpa.alloc(u8, 3_900_000);
    defer gpa.free(first_data);
    @memset(first_data, 'a');
    const second_data = try gpa.alloc(u8, 3_964_600);
    defer gpa.free(second_data);
    @memset(second_data, 'b');
    const pad: [8]u8 = @splat('p');
    const first: pubsub.Message = .{ .data = first_data };
    // Base64 moves in steps of four bytes; the attribute fills the gap.
    var fit: ?struct { usize, usize } = null;
    search: for (0..600) |trim| for (0..pad.len - 1) |pad_len| {
        const second: pubsub.Message = .{
            .data = second_data[0 .. second_data.len - trim],
            .attributes = &.{.{ .key = "pad", .value = pad[0..pad_len] }},
        };
        if (pubsub.limits.publishRequestBytes(&.{ first, second }, null) == limit) {
            fit = .{ trim, pad_len };
            break :search;
        }
    };
    const trim, const pad_len = fit orelse return error.TestNoExactFit;
    const exact: pubsub.Message = .{
        .data = second_data[0 .. second_data.len - trim],
        .attributes = &.{.{ .key = "pad", .value = pad[0..pad_len] }},
    };
    const over: pubsub.Message = .{
        .data = second_data[0 .. second_data.len - trim],
        .attributes = &.{.{ .key = "pad", .value = pad[0 .. pad_len + 1] }},
    };
    try testing.expectEqual(limit + 1, pubsub.limits.publishRequestBytes(&.{ first, over }, null));

    var live: LivePublisher = undefined;
    try live.start(publisherOptions(&f, topic.id, .{
        .concurrency = 1,
        .max_batch_messages = 1000,
        .max_batch_bytes = limit,
        // The default cap is smaller than a batch this big.
        .max_outstanding_bytes = 3 * limit,
        // Encoding a 4 MB message outlasts a short delay, which would send
        // the first message alone. Only size or flush may close a batch.
        .max_batch_delay_ms = 30_000,
    }));
    defer live.deinit();
    for ([_]pubsub.Message{ exact, over }, [_]u64{ 1, 3 }) |second, requests| {
        const a = try live.publisher.publish(first, .{});
        defer a.release();
        const b = try live.publisher.publish(second, .{});
        defer b.release();
        try live.publisher.flush();
        _ = waitReceipt(a, 120) catch |err| return f.fail(err);
        _ = waitReceipt(b, 120) catch |err| return f.fail(err);
        // At the limit, one request; a byte over, two.
        try testing.expectEqual(requests, live.publisher.stats().requests);
    }
    try live.finish();
}

test "publisher: after its topic is deleted, receipts fail with NotFound and the publisher carries on" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    const topic = try f.createTopic("pubgone");
    var live: LivePublisher = undefined;
    try live.start(publisherOptions(&f, topic.id, .{}));
    defer live.deinit();

    const before = try live.publisher.publish(.{ .data = "before" }, .{});
    defer before.release();
    _ = try waitReceipt(before, 30);
    topic.delete() catch |err| return f.fail(err);

    // The deletion can take a moment to reach publishing.
    const deadline = nowMs() + f.patience() * 1000;
    var failures: usize = 0;
    while (failures < 2) {
        if (nowMs() > deadline) return error.TestTimedOut;
        const after = try live.publisher.publish(.{ .data = "after" }, .{});
        defer after.release();
        if (waitReceipt(after, 30)) |_| {
            try testing.io.sleep(.fromMilliseconds(500), .awake);
        } else |err| {
            try testing.expectEqual(error.NotFound, err);
            failures += 1;
        }
    }
    // Still running: stop drains and returns.
    try live.finish();
    try testing.expect(live.publisher.stats().failed >= 2);
}
