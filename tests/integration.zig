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
