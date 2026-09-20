//! Fault injection: the whole client stack against a real Pub/Sub server,
//! with a misbehaving proxy in between. The proxy forwards each request to
//! the server named by PUBSUB_EMULATOR_HOST and then drops, cuts, delays or
//! rewrites the response, the way a failing network or middlebox would. The
//! unit tests script these failures against fakes; here the same behaviors
//! must hold over real sockets, real HTTP framing and a real server.
//!
//! Set PUBSUB_EMULATOR_HOST to run these tests; without it every test
//! skips. They never target production: a production round trip proves
//! nothing extra here, and the faults would only add noise to a shared
//! service.

const std = @import("std");
const pubsub = @import("pubsub");
const core = @import("core");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const net = std.Io.net;

/// A TCP proxy on the loopback interface. It reads whole HTTP requests,
/// forwards them to the emulator, reads whole responses, and then delivers
/// each response the way its fault says to. Faults apply one per request in
/// plan order; requests past the end of the plan pass through. Connections
/// are served one at a time, which fits a client that sends one request at
/// a time.
const FaultProxy = struct {
    gpa: Allocator,
    server: net.Server,
    port: u16,
    upstream: net.IpAddress,
    plan: []const Fault,
    /// Requests read from clients so far, which is also the plan index.
    requests: usize = 0,
    /// Requests that reached the emulator. `close_before_response` is the
    /// one fault that never forwards.
    forwarded: usize = 0,
    connections: usize = 0,

    const Fault = union(enum) {
        /// Forward the request and the whole response.
        pass,
        /// Read the request, forward nothing, close. The server never saw
        /// the request.
        close_before_response,
        /// Forward the request and read the whole response, then close
        /// without sending a byte of it. The server acted; the client
        /// cannot know.
        swallow_response,
        /// Send only the first N bytes of the response, then close.
        truncate_head: usize,
        /// Send the response minus its last N bytes, then close.
        cut_tail: usize,
        /// Send the whole response in small pieces with a pause between
        /// them, then keep the connection open for the next request.
        trickle: struct { chunk: usize = 16, delay_ms: u32 = 5 },
        /// Send the first N bytes, then nothing more until the client
        /// hangs up.
        stall_after: usize,
        /// Discard the response and send these bytes instead, then close.
        replace: []const u8,
    };

    /// Bigger upstream bodies than this mean the test is broken.
    const max_body_bytes = 8 * 1024 * 1024;

    fn start(io: std.Io, gpa: Allocator, upstream: net.IpAddress, plan: []const Fault) !FaultProxy {
        const address: net.IpAddress = .{ .ip4 = .loopback(0) };
        const server = try address.listen(io, .{ .reuse_address = true });
        return .{
            .gpa = gpa,
            .server = server,
            .port = server.socket.address.getPort(),
            .upstream = upstream,
            .plan = plan,
        };
    }

    fn deinit(p: *FaultProxy, io: std.Io) void {
        p.server.deinit(io);
    }

    /// Serves until canceled. A connection the client abandons is normal
    /// here, not an error; the loop moves on to the next one.
    ///
    /// Cancellation must land in `accept`: a canceled read surfaces as
    /// `ReadFailed` and consumes the request, so a cancel during `serve`
    /// would leave the next `accept` blocking forever. `Fixture.deinit`
    /// closes the client first, which parks this loop in `accept`, and
    /// cancels then.
    fn run(p: *FaultProxy, io: std.Io) std.Io.Cancelable!void {
        while (true) {
            const stream = p.server.accept(io) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => {
                    std.debug.print("proxy accept failed: {t}\n", .{err});
                    return;
                },
            };
            p.connections += 1;
            p.serve(io, stream) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => {},
            };
        }
    }

    fn serve(p: *FaultProxy, io: std.Io, stream: net.Stream) !void {
        defer stream.close(io);
        var read_buf: [16 * 1024]u8 = undefined;
        var reader = stream.reader(io, &read_buf);
        var write_buf: [4096]u8 = undefined;
        var writer = stream.writer(io, &write_buf);
        const out = &writer.interface;
        while (true) {
            var request: std.Io.Writer.Allocating = .init(p.gpa);
            defer request.deinit();
            if (!try readRequest(&reader.interface, &request)) return;
            const fault = f: {
                defer p.requests += 1;
                break :f if (p.requests < p.plan.len) p.plan[p.requests] else .pass;
            };
            if (fault == .close_before_response) return;

            var response: std.Io.Writer.Allocating = .init(p.gpa);
            defer response.deinit();
            try p.fetch(io, request.written(), &response);
            const bytes = response.written();

            switch (fault) {
                .close_before_response => unreachable,
                .pass => {
                    try out.writeAll(bytes);
                    try out.flush();
                },
                .swallow_response => return,
                .truncate_head => |n| {
                    try out.writeAll(bytes[0..@min(n, bytes.len)]);
                    try out.flush();
                    return;
                },
                .cut_tail => |n| {
                    try out.writeAll(bytes[0 .. bytes.len - @min(n, bytes.len)]);
                    try out.flush();
                    return;
                },
                .trickle => |t| {
                    var i: usize = 0;
                    while (i < bytes.len) {
                        const end = @min(i + @max(t.chunk, 1), bytes.len);
                        try out.writeAll(bytes[i..end]);
                        try out.flush();
                        try io.sleep(.fromMilliseconds(t.delay_ms), .awake);
                        i = end;
                    }
                },
                .stall_after => |n| {
                    try out.writeAll(bytes[0..@min(n, bytes.len)]);
                    try out.flush();
                    holdUntilHangup(io, &reader.interface);
                    return;
                },
                .replace => |canned| {
                    try out.writeAll(canned);
                    try out.flush();
                    return;
                },
            }
        }
    }

    /// Reads one whole request, head and Content-Length body, appending the
    /// raw bytes to `out`. False when the connection ended before one began,
    /// as a kept-alive connection does when the client is done with it.
    fn readRequest(r: *std.Io.Reader, out: *std.Io.Writer.Allocating) !bool {
        var content_length: u64 = 0;
        var first = true;
        while (true) {
            const line = r.takeDelimiterInclusive('\n') catch |err| {
                if (first and err == error.EndOfStream) return false;
                return err;
            };
            first = false;
            try out.writer.writeAll(line);
            if (std.ascii.startsWithIgnoreCase(line, "content-length:")) {
                const value = std.mem.trim(u8, line["content-length:".len..], " \r\n");
                content_length = try std.fmt.parseInt(u64, value, 10);
            }
            if (std.mem.eql(u8, line, "\r\n") or std.mem.eql(u8, line, "\n")) break;
        }
        if (content_length > max_body_bytes) return error.RequestTooLarge;
        try r.streamExact64(&out.writer, content_length);
        return true;
    }

    /// Sends the raw request to the emulator on a fresh connection and reads
    /// one whole response, as its framing defines it, into `out`.
    fn fetch(p: *FaultProxy, io: std.Io, request: []const u8, out: *std.Io.Writer.Allocating) !void {
        var upstream = try p.upstream.connect(io, .{ .mode = .stream });
        defer upstream.close(io);
        var write_buf: [4096]u8 = undefined;
        var writer = upstream.writer(io, &write_buf);
        try writer.interface.writeAll(request);
        try writer.interface.flush();
        p.forwarded += 1;

        var read_buf: [16 * 1024]u8 = undefined;
        var reader = upstream.reader(io, &read_buf);
        const r = &reader.interface;

        var status: u16 = 0;
        var content_length: ?u64 = null;
        var chunked = false;
        var first = true;
        while (true) {
            const line = try r.takeDelimiterInclusive('\n');
            try out.writer.writeAll(line);
            if (first) {
                status = statusOf(line);
                first = false;
            } else if (std.ascii.startsWithIgnoreCase(line, "content-length:")) {
                const value = std.mem.trim(u8, line["content-length:".len..], " \r\n");
                content_length = try std.fmt.parseInt(u64, value, 10);
            } else if (std.ascii.startsWithIgnoreCase(line, "transfer-encoding:")) {
                const value = std.mem.trim(u8, line["transfer-encoding:".len..], " \r\n");
                chunked = std.ascii.eqlIgnoreCase(value, "chunked");
            }
            if (std.mem.eql(u8, line, "\r\n") or std.mem.eql(u8, line, "\n")) break;
        }

        if (status == 204 or status == 304) return;
        if (chunked) {
            while (true) {
                const line = try r.takeDelimiterInclusive('\n');
                try out.writer.writeAll(line);
                const size = chunkSize(line) orelse return error.BadUpstreamFraming;
                if (size == 0) break;
                try r.streamExact64(&out.writer, size + 2);
            }
            while (true) {
                const line = try r.takeDelimiterInclusive('\n');
                try out.writer.writeAll(line);
                if (std.mem.eql(u8, line, "\r\n") or std.mem.eql(u8, line, "\n")) return;
            }
        }
        if (content_length) |n| {
            if (n > max_body_bytes) return error.BadUpstreamFraming;
            try r.streamExact64(&out.writer, n);
            return;
        }
        // No framing: the server ends the body by closing the connection.
        _ = try r.streamRemaining(&out.writer);
    }

    fn statusOf(line: []const u8) u16 {
        const space = std.mem.indexOfScalar(u8, line, ' ') orelse return 0;
        const rest = line[space + 1 ..];
        if (rest.len < 3) return 0;
        return std.fmt.parseInt(u16, rest[0..3], 10) catch 0;
    }

    fn chunkSize(line: []const u8) ?u64 {
        var size: u64 = 0;
        var digits: usize = 0;
        for (line) |c| {
            const digit = std.fmt.charToDigit(c, 16) catch break;
            size = size * 16 + digit;
            if (size > max_body_bytes) return null;
            digits += 1;
        }
        if (digits == 0) return null;
        return size;
    }

    /// Blocks until the client closes its end of the connection, which a
    /// timed-out client does promptly, with a generous timer under it in
    /// case one never does.
    fn holdUntilHangup(io: std.Io, r: *std.Io.Reader) void {
        const Winner = union(enum) { hung_up: void, gave_up: void };
        var slots: [2]Winner = undefined;
        var race: std.Io.Select(Winner) = .init(io, &slots);
        race.concurrent(.hung_up, drain, .{r}) catch {
            drain(r);
            return;
        };
        defer race.cancelDiscard();
        race.concurrent(.gave_up, patience, .{io}) catch {};
        _ = race.await() catch {};
    }

    fn drain(r: *std.Io.Reader) void {
        _ = r.discardRemaining() catch {};
    }

    fn patience(io: std.Io) void {
        io.sleep(.fromSeconds(30), .awake) catch {};
    }
};

/// The emulator's address from PUBSUB_EMULATOR_HOST: `host:port`, with
/// `localhost` accepted for its loopback address. Null for anything the
/// proxy cannot dial as an address, which skips the test.
fn parseUpstream(host_port: []const u8) ?net.IpAddress {
    const trimmed = std.mem.trim(u8, host_port, &std.ascii.whitespace);
    var host: []const u8 = undefined;
    var port_text: []const u8 = undefined;
    if (std.mem.startsWith(u8, trimmed, "[")) {
        const close = std.mem.indexOfScalar(u8, trimmed, ']') orelse return null;
        host = trimmed[1..close];
        if (close + 1 >= trimmed.len or trimmed[close + 1] != ':') return null;
        port_text = trimmed[close + 2 ..];
    } else {
        const colon = std.mem.lastIndexOfScalar(u8, trimmed, ':') orelse return null;
        host = trimmed[0..colon];
        port_text = trimmed[colon + 1 ..];
    }
    const port = std.fmt.parseInt(u16, port_text, 10) catch return null;
    if (std.mem.eql(u8, host, "localhost")) return .{ .ip4 = .loopback(port) };
    return net.IpAddress.parse(host, port) catch null;
}

const Fixture = struct {
    env: std.process.Environ.Map,
    arena: std.heap.ArenaAllocator,
    /// "zigps-" plus 8 random hex digits, unique per test.
    prefix: [14]u8,
    proxy: FaultProxy,
    serving: ?std.Io.Future(std.Io.Cancelable!void),
    proxy_host: [24]u8,
    direct_diag: pubsub.Diagnostics,
    diag: pubsub.Diagnostics,
    /// Talks to the emulator itself, for setup, verification and cleanup.
    direct: pubsub.Client,
    /// The client under test. Every request crosses the proxy.
    proxied: pubsub.Client,
    topics: std.ArrayList([]const u8),
    subscriptions: std.ArrayList([]const u8),

    const Options = struct {
        max_attempts: u8 = 5,
        request_timeout_ms: u32 = 30_000,
    };

    /// Returns false when no emulator is configured; the test should skip.
    fn init(f: *Fixture, plan: []const FaultProxy.Fault, options: Options) !bool {
        const gpa = testing.allocator;
        const io = testing.io;
        f.env = try testing.environ.createMap(gpa);
        errdefer f.env.deinit();
        const emulator = pubsub.Endpoint.fromEnv(&f.env) orelse {
            f.env.deinit();
            return false;
        };
        const upstream = parseUpstream(emulator.url) orelse {
            f.env.deinit();
            return false;
        };
        const project = f.env.get("PUBSUB_PROJECT_ID") orelse "test";

        f.arena = .init(gpa);
        errdefer f.arena.deinit();
        f.topics = .empty;
        f.subscriptions = .empty;
        var random: [4]u8 = undefined;
        io.random(&random);
        _ = try std.fmt.bufPrint(&f.prefix, "zigps-{x}", .{random});

        f.proxy = try FaultProxy.start(io, gpa, upstream, plan);
        errdefer f.proxy.deinit(io);
        f.serving = null;

        f.direct_diag = .{};
        f.diag = .{};
        f.direct = try .init(gpa, io, .{
            .project_id = project,
            .endpoint = emulator,
            .diagnostics = &f.direct_diag,
            .user_agent = "zig-pubsub-faults-direct/0.1",
        });
        errdefer f.direct.deinit();

        const host = try std.fmt.bufPrint(&f.proxy_host, "127.0.0.1:{d}", .{f.proxy.port});
        f.proxied = try .init(gpa, io, .{
            .project_id = project,
            .endpoint = .{ .url = host, .emulator = true },
            // Fast backoff: these tests provoke retries on purpose.
            .retry = .{ .max_attempts = options.max_attempts, .initial_backoff_ms = 10, .max_backoff_ms = 100 },
            .request_timeout_ms = options.request_timeout_ms,
            .diagnostics = &f.diag,
            .user_agent = "zig-pubsub-faults/0.1",
        });
        return true;
    }

    /// Starts the proxy serving in its own task; `deinit` stops it.
    fn startProxy(f: *Fixture) !void {
        f.serving = try testing.io.concurrent(FaultProxy.run, .{ &f.proxy, testing.io });
    }

    /// Stops the proxy and deletes everything the test created,
    /// subscriptions first, without crossing the proxy.
    fn deinit(f: *Fixture) void {
        const io = testing.io;
        // Closing the client's pooled connections first parks the proxy in
        // `accept`, where the cancel can reach it (see `FaultProxy.run`).
        f.proxied.deinit();
        if (f.serving) |*serving| serving.cancel(io) catch {};
        for (f.subscriptions.items) |sub_id| f.direct.subscription(sub_id).delete() catch {};
        for (f.topics.items) |topic_id| f.direct.topic(topic_id).delete() catch {};
        f.subscriptions.deinit(testing.allocator);
        f.topics.deinit(testing.allocator);
        f.direct.deinit();
        f.proxy.deinit(io);
        f.arena.deinit();
        f.env.deinit();
    }

    /// A unique id: the prefix plus `suffix`.
    fn id(f: *Fixture, suffix: []const u8) []const u8 {
        return std.fmt.allocPrint(f.arena.allocator(), "{s}-{s}", .{ &f.prefix, suffix }) catch @panic("OOM");
    }

    /// Creates a topic directly, bypassing the proxy, registered for cleanup.
    fn directTopic(f: *Fixture, suffix: []const u8) !pubsub.Topic {
        const topic = f.direct.topic(f.id(suffix));
        try f.topics.append(testing.allocator, topic.id);
        var info = topic.create(.{}) catch |err| return f.fail(err);
        info.deinit();
        return topic;
    }

    fn directSubscription(f: *Fixture, suffix: []const u8, config: pubsub.SubscriptionConfig) !pubsub.Subscription {
        const sub = f.direct.subscription(f.id(suffix));
        try f.subscriptions.append(testing.allocator, sub.id);
        var info = sub.create(config) catch |err| return f.fail(err);
        info.deinit();
        return sub;
    }

    fn fail(f: *Fixture, err: anyerror) anyerror {
        std.debug.print("{t}: proxied HTTP {d} {s}: {s}; direct HTTP {d} {s}: {s}\n", .{
            err,
            f.diag.http_status,
            f.diag.status(),
            f.diag.message(),
            f.direct_diag.http_status,
            f.direct_diag.status(),
            f.direct_diag.message(),
        });
        return err;
    }

    /// Pulls from `sub` until `want` messages arrived or `timeout_s` passed,
    /// acking everything. Returns the data of each message, in the fixture's
    /// arena.
    fn pullData(f: *Fixture, sub: pubsub.Subscription, want: usize, timeout_s: i64) ![][]const u8 {
        const a = f.arena.allocator();
        var out: std.ArrayList([]const u8) = .empty;
        const deadline = nowMs() + timeout_s * 1000;
        while (out.items.len < want and nowMs() <= deadline) {
            var batch = sub.pull(.{ .max_messages = 100, .return_immediately = true }) catch |err| return f.fail(err);
            defer batch.deinit();
            if (batch.value.messages.len > 0) {
                const ids = try testing.allocator.alloc([]const u8, batch.value.messages.len);
                defer testing.allocator.free(ids);
                for (batch.value.messages, ids) |m, *ack| ack.* = m.ack_id;
                sub.ack(ids) catch |err| return f.fail(err);
                for (batch.value.messages) |m| try out.append(a, try a.dupe(u8, m.data));
            } else {
                try testing.io.sleep(.fromMilliseconds(200), .awake);
            }
        }
        return out.items;
    }

    /// Pulls briefly and fails if anything arrives.
    fn expectNoMessages(f: *Fixture, sub: pubsub.Subscription) !void {
        for (0..3) |_| {
            var batch = sub.pull(.{ .return_immediately = true }) catch |err| return f.fail(err);
            defer batch.deinit();
            if (batch.value.messages.len != 0) return error.TestUnexpectedMessage;
            try testing.io.sleep(.fromMilliseconds(200), .awake);
        }
    }
};

fn nowMs() i64 {
    return std.Io.Clock.awake.now(testing.io).toMilliseconds();
}

test "sanity: a clean proxy forwards the whole round trip untouched" {
    var f: Fixture = undefined;
    if (!try f.init(&.{}, .{})) return error.SkipZigTest;
    defer f.deinit();
    try f.startProxy();

    // Everything through the proxy: create, publish, pull, ack.
    const topic = f.proxied.topic(f.id("clean"));
    try f.topics.append(testing.allocator, topic.id);
    var created = topic.create(.{}) catch |err| return f.fail(err);
    created.deinit();
    const sub = f.proxied.subscription(f.id("clean-sub"));
    try f.subscriptions.append(testing.allocator, sub.id);
    var sub_info = sub.create(.{ .topic_id = topic.id }) catch |err| return f.fail(err);
    sub_info.deinit();

    var sent = topic.publish(&.{
        .{ .data = "one" },
        .{ .data = "two, with ünïcödé and \x00 bytes" },
    }, .{}) catch |err| return f.fail(err);
    defer sent.deinit();
    try testing.expectEqual(2, sent.value.message_ids.len);

    const got = try f.pullData(sub, 2, 30);
    try testing.expectEqual(2, got.len);
    var matched: usize = 0;
    for (got) |data| {
        if (std.mem.eql(u8, data, "one")) matched += 1;
        if (std.mem.eql(u8, data, "two, with ünïcödé and \x00 bytes")) matched += 1;
    }
    try testing.expectEqual(2, matched);
    // The proxy carried every request, and no fault fired.
    try testing.expect(f.proxy.forwarded >= 4);
    try testing.expectEqual(f.proxy.requests, f.proxy.forwarded);
}

test "a connection cut mid-status-line costs one retry" {
    var f: Fixture = undefined;
    // 12 bytes is "HTTP/1.1 200", cut before the line ends.
    if (!try f.init(&.{ .{ .truncate_head = 12 }, .pass }, .{})) return error.SkipZigTest;
    defer f.deinit();
    try f.startProxy();

    const topic = try f.directTopic("cut-head");
    var got = f.proxied.topic(topic.id).get() catch |err| return f.fail(err);
    defer got.deinit();
    try testing.expect(std.mem.endsWith(u8, got.value.name, topic.id));
    try testing.expectEqual(2, f.proxy.requests);
    // Success cleared the diagnostics the failed attempt left.
    try testing.expectEqual(0, f.diag.http_status);
    try testing.expectEqualStrings("", f.diag.message());
}

test "a body cut short of its Content-Length surfaces as ConnectionResetByPeer" {
    var f: Fixture = undefined;
    if (!try f.init(&.{.{ .cut_tail = 5 }}, .{ .max_attempts = 1 })) return error.SkipZigTest;
    defer f.deinit();
    try f.startProxy();

    // Regression, end to end: std.http reports a short Content-Length body
    // as a normal end of stream, which once turned truncated pulls into
    // short successes.
    const topic = try f.directTopic("cut-tail");
    try testing.expectError(error.ConnectionResetByPeer, f.proxied.topic(topic.id).get());
    try testing.expectEqual(1, f.proxy.requests);
    try testing.expectEqual(0, f.diag.http_status);
    try testing.expectEqualStrings("ConnectionResetByPeer", f.diag.message());
}

test "a body cut short heals through the retry" {
    var f: Fixture = undefined;
    if (!try f.init(&.{ .{ .cut_tail = 5 }, .pass }, .{})) return error.SkipZigTest;
    defer f.deinit();
    try f.startProxy();

    const topic = try f.directTopic("heal");
    var got = f.proxied.topic(topic.id).get() catch |err| return f.fail(err);
    defer got.deinit();
    try testing.expect(std.mem.endsWith(u8, got.value.name, topic.id));
    try testing.expectEqual(2, f.proxy.requests);
}

test "a connection closed before any response byte is retried" {
    var f: Fixture = undefined;
    if (!try f.init(&.{ .close_before_response, .pass }, .{})) return error.SkipZigTest;
    defer f.deinit();
    try f.startProxy();

    const topic = try f.directTopic("dropped");
    var got = f.proxied.topic(topic.id).get() catch |err| return f.fail(err);
    defer got.deinit();
    try testing.expectEqual(2, f.proxy.requests);
    // The dropped request never reached the server; only the retry did.
    try testing.expectEqual(1, f.proxy.forwarded);
}

test "create: a response lost after the server acted is AlreadyExists on the retry" {
    var f: Fixture = undefined;
    if (!try f.init(&.{ .{ .cut_tail = 5 }, .pass }, .{})) return error.SkipZigTest;
    defer f.deinit();
    try f.startProxy();

    // Create is not idempotent: the first attempt created the topic and the
    // response died on the way back, so the retry finds it already there.
    // The caller learns the true server state, not a fabricated success.
    const topic = f.proxied.topic(f.id("acted"));
    try f.topics.append(testing.allocator, topic.id);
    try testing.expectError(error.AlreadyExists, topic.create(.{}));
    try testing.expectEqual(409, f.diag.http_status);
    try testing.expectEqual(2, f.proxy.forwarded);
    var got = f.direct.topic(topic.id).get() catch |err| return f.fail(err);
    got.deinit();
}

test "publish: a swallowed response is retried, and the message is stored twice" {
    var f: Fixture = undefined;
    if (!try f.init(&.{ .swallow_response, .pass }, .{})) return error.SkipZigTest;
    defer f.deinit();
    try f.startProxy();

    const topic = try f.directTopic("dup");
    const sub = try f.directSubscription("dup-sub", .{ .topic_id = topic.id });

    // The first attempt reached the server and the response was lost, so
    // the retry stores a second copy: what Client.Options.retry_publish
    // warns about, played out for real.
    const data = "at-least-once means possibly twice";
    var sent = f.proxied.topic(topic.id).publish(&.{.{ .data = data }}, .{}) catch |err| return f.fail(err);
    defer sent.deinit();
    try testing.expectEqual(1, sent.value.message_ids.len);
    try testing.expectEqual(2, f.proxy.forwarded);

    const got = try f.pullData(sub, 2, 30);
    try testing.expectEqual(2, got.len);
    for (got) |copy| try testing.expectEqualStrings(data, copy);
}

test "publish: with retry_publish off, the ack is lost but the message is not duplicated" {
    var f: Fixture = undefined;
    if (!try f.init(&.{.swallow_response}, .{})) return error.SkipZigTest;
    defer f.deinit();
    try f.startProxy();

    const topic = try f.directTopic("once");
    const sub = try f.directSubscription("once-sub", .{ .topic_id = topic.id });

    f.proxied.retry_publish = false;
    try testing.expectError(
        error.ConnectionResetByPeer,
        f.proxied.topic(topic.id).publish(&.{.{ .data = "stored anyway" }}, .{}),
    );
    try testing.expectEqual(1, f.proxy.forwarded);

    // The publish failed at the caller, yet the server stored it: exactly
    // one copy, and nothing more.
    const got = try f.pullData(sub, 1, 30);
    try testing.expectEqual(1, got.len);
    try testing.expectEqualStrings("stored anyway", got[0]);
    try f.expectNoMessages(sub);
}

test "trickled bytes: a slow but complete response succeeds without a retry" {
    var f: Fixture = undefined;
    if (!try f.init(&.{.{ .trickle = .{ .chunk = 7, .delay_ms = 2 } }}, .{})) return error.SkipZigTest;
    defer f.deinit();
    try f.startProxy();

    const topic = try f.directTopic("slow");
    var got = f.proxied.topic(topic.id).get() catch |err| return f.fail(err);
    defer got.deinit();
    try testing.expect(std.mem.endsWith(u8, got.value.name, topic.id));
    try testing.expectEqual(1, f.proxy.requests);

    // The dribbled response did not poison the connection: the next request
    // reuses it.
    var again = f.proxied.topic(topic.id).get() catch |err| return f.fail(err);
    again.deinit();
    try testing.expectEqual(2, f.proxy.requests);
    try testing.expectEqual(1, f.proxy.connections);
}

test "a response stalled mid-body trips the deadline, and the retry succeeds" {
    var f: Fixture = undefined;
    if (!try f.init(&.{ .{ .stall_after = 20 }, .pass }, .{ .request_timeout_ms = 1000 })) return error.SkipZigTest;
    defer f.deinit();
    try f.startProxy();

    const topic = try f.directTopic("stall");
    const started = nowMs();
    var got = f.proxied.topic(topic.id).get() catch |err| return f.fail(err);
    defer got.deinit();
    const elapsed = nowMs() - started;
    try testing.expect(std.mem.endsWith(u8, got.value.name, topic.id));
    try testing.expectEqual(2, f.proxy.requests);
    // The first attempt burned its deadline; the whole call still finished
    // promptly instead of waiting on the stalled connection forever.
    try testing.expect(elapsed >= 900);
    try testing.expect(elapsed < 25_000);
}

test "a stalled response with retries off is TimedOut, and the client recovers" {
    var f: Fixture = undefined;
    if (!try f.init(&.{.{ .stall_after = 20 }}, .{ .max_attempts = 1, .request_timeout_ms = 750 })) return error.SkipZigTest;
    defer f.deinit();
    try f.startProxy();

    const topic = try f.directTopic("timeout");
    try testing.expectError(error.TimedOut, f.proxied.topic(topic.id).get());
    try testing.expectEqualStrings("TimedOut", f.diag.message());

    // The timed-out attempt closed its socket, which is what frees the
    // proxy; a client that leaked the stalled connection would leave the
    // next call waiting behind it.
    f.proxied.request_timeout_ms = 30_000;
    const started = nowMs();
    var got = f.proxied.topic(topic.id).get() catch |err| return f.fail(err);
    got.deinit();
    try testing.expect(nowMs() - started < 10_000);
}

test "malformed frames surface as their exact errors, with no retry wasted" {
    const cases = [_]struct { []const u8, anyerror }{
        // Not HTTP at all.
        .{ "who needs headers\r\n\r\n", error.HttpProtocolError },
        // A chunk size that is not one.
        .{ "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\nab\r\n0\r\n\r\n", error.HttpProtocolError },
        // Valid HTTP whose body is not the API's JSON.
        .{ "HTTP/1.1 200 OK\r\nContent-Length: 6\r\n\r\n<html>", error.InvalidResponse },
    };
    for (cases) |case| {
        var f: Fixture = undefined;
        if (!try f.init(&.{ .{ .replace = case[0] }, .pass }, .{})) return error.SkipZigTest;
        defer f.deinit();
        try f.startProxy();

        const topic = try f.directTopic("frame");
        try testing.expectError(case[1], f.proxied.topic(topic.id).get());
        // Retries were available and none was spent: garbage that arrived
        // whole is not a transient failure.
        try testing.expectEqual(1, f.proxy.requests);

        // The client survives and the next call works.
        var got = f.proxied.topic(topic.id).get() catch |err| return f.fail(err);
        got.deinit();
    }
}

test "an injected 502 error page is retried through to success" {
    var f: Fixture = undefined;
    const page = "HTTP/1.1 502 Bad Gateway\r\nContent-Type: text/html\r\nContent-Length: 17\r\n\r\n<html>oops</html>";
    if (!try f.init(&.{ .{ .replace = page }, .pass }, .{})) return error.SkipZigTest;
    defer f.deinit();
    try f.startProxy();

    // A middlebox answering for a healthy server: the 502 maps to
    // Unavailable, which is transient, and the retry gets through.
    const topic = try f.directTopic("gateway");
    var got = f.proxied.topic(topic.id).get() catch |err| return f.fail(err);
    defer got.deinit();
    try testing.expect(std.mem.endsWith(u8, got.value.name, topic.id));
    try testing.expectEqual(2, f.proxy.requests);
    try testing.expectEqual(0, f.diag.http_status);
}

test "a fault on a kept-alive connection only costs a retry" {
    var f: Fixture = undefined;
    if (!try f.init(&.{ .pass, .{ .cut_tail = 4 }, .pass }, .{})) return error.SkipZigTest;
    defer f.deinit();
    try f.startProxy();

    // A healthy exchange, then the pooled connection betrays the client
    // mid-response. The client must not trust the poisoned connection and
    // must not need a new client either.
    const topic = try f.directTopic("pool");
    var first = f.proxied.topic(topic.id).get() catch |err| return f.fail(err);
    first.deinit();
    var second = f.proxied.topic(topic.id).get() catch |err| return f.fail(err);
    second.deinit();
    try testing.expectEqual(3, f.proxy.requests);
    try testing.expectEqual(2, f.proxy.connections);
}

fn faultPlanProperty(_: void, input: []const u8) !void {
    var g: core.testing.ByteGen = .init(input);
    const fault: FaultProxy.Fault = switch (g.intRange(u8, 0, 7)) {
        0 => .pass,
        1 => .close_before_response,
        2 => .swallow_response,
        3 => .{ .truncate_head = g.intRange(u16, 0, 500) },
        4 => .{ .cut_tail = g.intRange(u16, 0, 500) },
        5 => .{ .trickle = .{ .chunk = g.intRange(u8, 8, 64), .delay_ms = g.intRange(u8, 0, 3) } },
        6 => .{ .replace = g.pick([]const u8, &.{
            "who needs headers\r\n\r\n",
            "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\n0\r\n\r\n",
            "HTTP/1.1 200 OK\r\nContent-Length: 999\r\n\r\n{",
            "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\n\r\n",
            "HTTP/1.1 099 Wat\r\n\r\n",
            "\r\n\r\n",
        }) },
        else => .{ .replace = g.take(48) },
    };

    var f: Fixture = undefined;
    if (!try f.init(&.{ fault, .pass }, .{ .max_attempts = 3, .request_timeout_ms = 10_000 })) return error.SkipZigTest;
    defer f.deinit();
    try f.startProxy();

    const topic = try f.directTopic("fuzz");
    // Whatever the misdelivery, the call returns a value or an error from
    // the closed set (the return type guarantees that much), without
    // crashing, leaking or hanging past its deadline.
    if (f.proxied.topic(topic.id).get()) |result| {
        var owned = result;
        owned.deinit();
    } else |_| {}
    // And the client is usable afterwards.
    var after = f.proxied.topic(topic.id).get() catch |err| return f.fail(err);
    after.deinit();
}

test "fuzz faults: any misdelivery yields a clean outcome and a usable client" {
    // Check the emulator is there once, so the property never has to skip.
    var probe: Fixture = undefined;
    if (!try probe.init(&.{}, .{})) return error.SkipZigTest;
    probe.deinit();

    // Each run talks to a real server, so far fewer runs than a unit
    // property gets; the corpus pins one input per fault kind.
    try core.testing.fuzzBytes({}, faultPlanProperty, .{
        .corpus = &.{
            "\x00",
            "\x01",
            "\x02",
            "\x03\x00\x00", // truncate_head 0: the response vanishes entirely
            "\x04\x01\xf4", // cut_tail 500: likewise, from the other end
            "\x05\x10\x01", // trickle in 16-byte pieces
            "\x06\x00",
            "\x07HTTP/1.1 200 OK", // raw junk that starts plausibly
        },
        .random_runs = 25,
        .max_len = 16,
    });
}
