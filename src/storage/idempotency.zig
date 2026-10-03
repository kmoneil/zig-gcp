//! Idempotency tokens: one value per call, the same on every retry of it,
//! in the `X-Goog-Gcs-Idempotency-Token` header of every JSON API write,
//! and the retries they make safe.
//!
//! Measured against Cloud Storage on 2026-09-30, sending a request with a
//! token and then the same request with the same token:
//!
//! - Uploads of one request, object metadata patches, `objects.move` and
//!   object deletes answer the repeat with the first result, byte for byte,
//!   and do not act again: with versioning off, an upload repeated after
//!   another writer replaced the object left that writer's object, a
//!   delete repeated after the name was created again left the new object,
//!   and a patch repeated after another writer's patch kept that writer's
//!   value. A create-only upload that landed answers its repeat 200, where
//!   a new token gets 412.
//! - Compose, rewrite, restore, a resumable session's start, an XML
//!   multipart start, and bucket create, patch and delete run again.
//! - A failed attempt is not replayed: a request refused 412, its cause
//!   removed, succeeds when sent again with the same token.
//! - The same token with another body is answered with the first result
//!   and the body is dropped, so a token belongs to one call alone.
//! - A repeat was recognised after 115 s, and not after 130 s. The
//!   documentation says to retry "within a minute".
//!
//! So every write carries a token, and the four that answer a repeat with
//! their first result retry without a condition for `window_ms` after
//! their first attempt: past it, a repeat might act again.

const std = @import("std");
const core = @import("core");

const Client = @import("Client.zig");
const Header = core.transport.Header;

pub const header_name = "X-Goog-Gcs-Idempotency-Token";

/// How long after a call's first attempt a retry may still lean on its
/// token: the documented minute, well inside the 115 s measured.
pub const window_ms: u32 = 60_000;

/// One call's token, made on its stack, where nothing moves it: the header
/// points into it.
pub const Token = struct {
    text: [32]u8 = undefined,
    list: [1]Header = undefined,
    len: usize = 0,

    /// A fresh token, or none when the client sends none.
    pub fn init(self: *Token, client: *const Client) void {
        self.* = .{};
        if (!client.idempotency_tokens) return;
        make(client.io, &self.text);
        self.list = .{.{ .name = header_name, .value = &self.text }};
        self.len = 1;
    }

    pub fn slice(self: *const Token) []const Header {
        return self.list[0..self.len];
    }
};

/// 16 random bytes, in lowercase hex.
pub fn make(io: std.Io, out: *[32]u8) void {
    var bytes: [16]u8 = undefined;
    io.random(&bytes);
    out.* = std.fmt.bytesToHex(bytes, .lower);
}

/// A request's headers: `fixed`, then the token's, in `buffer`.
pub fn withToken(buffer: []Header, fixed: []const Header, token: *const Token) []const Header {
    const extra = token.slice();
    std.debug.assert(buffer.len >= fixed.len + extra.len);
    @memcpy(buffer[0..fixed.len], fixed);
    @memcpy(buffer[fixed.len..][0..extra.len], extra);
    return buffer[0 .. fixed.len + extra.len];
}

/// How a write that answers a repeat with its first result retries: always
/// when a condition or the caller's opt-in makes it `safe`; else, with a
/// token, within the window; else not at all.
pub const Retry = struct {
    retry: bool,
    window_ms: ?u32,
};

pub fn writeRetry(client: *const Client, safe: bool) Retry {
    if (safe) return .{ .retry = true, .window_ms = null };
    if (client.idempotency_tokens) return .{ .retry = true, .window_ms = window_ms };
    return .{ .retry = false, .window_ms = null };
}

const testing = std.testing;
const test_util = @import("test_util.zig");
const types = @import("types.zig");
const FakeMultipart = test_util.FakeMultipart;
const Harness = test_util.Harness;
const Reply = test_util.FakeTransport.Reply;

test "make: 32 lowercase hex digits, and no two alike" {
    var tokens: [4096][32]u8 = undefined;
    for (&tokens) |*t| {
        make(testing.io, t);
        for (t) |c| try testing.expect(std.ascii.isDigit(c) or (c >= 'a' and c <= 'f'));
    }
    std.mem.sortUnstable([32]u8, &tokens, {}, struct {
        fn lessThan(_: void, a: [32]u8, b: [32]u8) bool {
            return std.mem.order(u8, &a, &b) == .lt;
        }
    }.lessThan);
    for (tokens[1..], tokens[0 .. tokens.len - 1]) |a, b| try testing.expect(!std.mem.eql(u8, &a, &b));
}

const object_json = "{\"name\":\"a\",\"bucket\":\"b\",\"generation\":\"7\",\"metageneration\":\"1\"}";
const bucket_json = "{\"name\":\"b\",\"metageneration\":\"2\"}";
const operation_json = "{\"name\":\"projects/_/buckets/b/operations/op1\",\"done\":false}";
const session_uri = "https://storage.example.test/upload/session/s1";
const unavailable: Reply = .{ .respond = .{ .status = 503, .body = "{}" } };
const no_content: Reply = .{ .respond = .{ .status = 204, .body = "" } };
const opened: Reply = .{ .respond = .{ .body = "", .headers = &.{.{ .name = "Location", .value = session_uri }} } };

fn answer(comptime body: []const u8) Reply {
    return .{ .respond = .{ .body = body } };
}

/// One public call, and the answers it needs from a harness.
const Call = struct {
    what: []const u8,
    replies: []const Reply,
    run: *const fn (*Client) anyerror!void,
};

fn object(c: *Client) Object {
    return c.bucket("b").object("a");
}

const Object = @import("Object.zig");

/// Every public call that writes, and the requests it makes.
const writes = [_]Call{
    .{ .what = "upload, one request", .replies = &.{answer(object_json)}, .run = struct {
        fn run(c: *Client) !void {
            var r = try object(c).upload("0123456789", .{});
            r.deinit();
        }
    }.run },
    .{ .what = "upload, resumable: the start alone", .replies = &.{ opened, answer(object_json) }, .run = struct {
        fn run(c: *Client) !void {
            var r = try object(c).upload("0123456789abcdefghijklmnopqrstuvwxyz", .{});
            r.deinit();
        }
    }.run },
    .{ .what = "delete", .replies = &.{no_content}, .run = struct {
        fn run(c: *Client) !void {
            try object(c).delete(.{});
        }
    }.run },
    .{ .what = "delete of a generation", .replies = &.{no_content}, .run = struct {
        fn run(c: *Client) !void {
            try object(c).delete(.{ .generation = 7 });
        }
    }.run },
    .{ .what = "updateMetadata", .replies = &.{answer(object_json)}, .run = struct {
        fn run(c: *Client) !void {
            var r = try object(c).updateMetadata(.{ .content_type = "text/plain" });
            r.deinit();
        }
    }.run },
    .{ .what = "composeFrom", .replies = &.{answer(object_json)}, .run = struct {
        fn run(c: *Client) !void {
            var r = try object(c).composeFrom(&.{ .{ .name = "x" }, .{ .name = "y" } }, .{});
            r.deinit();
        }
    }.run },
    .{ .what = "copyTo, over two rewrite calls", .replies = &.{
        answer("{\"done\":false,\"rewriteToken\":\"t+1\"}"),
        answer("{\"done\":true,\"resource\":" ++ object_json ++ "}"),
    }, .run = struct {
        fn run(c: *Client) !void {
            var r = try object(c).copyTo(c.bucket("d").object("copy"), .{});
            r.deinit();
        }
    }.run },
    .{ .what = "restore", .replies = &.{answer(object_json)}, .run = struct {
        fn run(c: *Client) !void {
            var r = try object(c).restore(.{ .generation = 7 });
            r.deinit();
        }
    }.run },
    .{ .what = "bulkRestore", .replies = &.{answer(operation_json)}, .run = struct {
        fn run(c: *Client) !void {
            var r = try c.bucket("b").bulkRestore(.{});
            r.deinit();
        }
    }.run },
    .{ .what = "cancelOperation", .replies = &.{no_content}, .run = struct {
        fn run(c: *Client) !void {
            try c.bucket("b").cancelOperation("op1");
        }
    }.run },
    .{ .what = "bucket create", .replies = &.{answer(bucket_json)}, .run = struct {
        fn run(c: *Client) !void {
            var r = try c.bucket("b").create(.{});
            r.deinit();
        }
    }.run },
    .{ .what = "bucket update", .replies = &.{answer(bucket_json)}, .run = struct {
        fn run(c: *Client) !void {
            var r = try c.bucket("b").update(.{ .versioning = true });
            r.deinit();
        }
    }.run },
    .{ .what = "bucket restore", .replies = &.{answer(bucket_json)}, .run = struct {
        fn run(c: *Client) !void {
            var r = try c.bucket("b").restore(7);
            r.deinit();
        }
    }.run },
    .{ .what = "bucket delete", .replies = &.{no_content}, .run = struct {
        fn run(c: *Client) !void {
            try c.bucket("b").delete();
        }
    }.run },
};

/// Every public call that only reads.
const reads = [_]Call{
    .{ .what = "get", .replies = &.{answer(object_json)}, .run = struct {
        fn run(c: *Client) !void {
            var r = try object(c).get(.{});
            r.deinit();
        }
    }.run },
    .{ .what = "exists", .replies = &.{answer(object_json)}, .run = struct {
        fn run(c: *Client) !void {
            _ = try object(c).exists();
        }
    }.run },
    .{ .what = "downloadAlloc", .replies = &.{answer("data")}, .run = struct {
        fn run(c: *Client) !void {
            var r = try object(c).downloadAlloc(64, .{});
            r.deinit();
        }
    }.run },
    .{ .what = "listObjects", .replies = &.{answer("{}")}, .run = struct {
        fn run(c: *Client) !void {
            var r = try c.bucket("b").listObjects(.{});
            r.deinit();
        }
    }.run },
    .{ .what = "bucket get", .replies = &.{answer(bucket_json)}, .run = struct {
        fn run(c: *Client) !void {
            var r = try c.bucket("b").get();
            r.deinit();
        }
    }.run },
    .{ .what = "listBuckets", .replies = &.{answer("{}")}, .run = struct {
        fn run(c: *Client) !void {
            var r = try c.listBuckets(.{});
            r.deinit();
        }
    }.run },
    .{ .what = "operation", .replies = &.{answer(operation_json)}, .run = struct {
        fn run(c: *Client) !void {
            var r = try c.bucket("b").operation("op1");
            r.deinit();
        }
    }.run },
    .{ .what = "listOperations", .replies = &.{answer("{}")}, .run = struct {
        fn run(c: *Client) !void {
            var r = try c.bucket("b").listOperations(.{});
            r.deinit();
        }
    }.run },
};

/// The replies of `calls`, in order.
fn scriptOf(comptime calls: []const Call) []const Reply {
    comptime {
        var replies: []const Reply = &.{};
        for (calls) |call| replies = replies ++ call.replies;
        return replies;
    }
}

/// The token each request since `from` carried, or null, in the order
/// of the fake's two lists; a resumable session's requests report "chunk"
/// when they carry none.
const Sent = struct {
    requests: usize = 0,
    streams: usize = 0,

    fn now(h: *const Harness) Sent {
        return .{ .requests = h.fake.requests.items.len, .streams = h.fake.stream_requests.items.len };
    }
};

fn tokensSince(h: *const Harness, from: Sent, out: *[8]?[]const u8, chunks: *usize) ![]?[]const u8 {
    var n: usize = 0;
    for (h.fake.requests.items[from.requests..]) |r| {
        out[n] = r.header(header_name);
        n += 1;
    }
    for (h.fake.stream_requests.items[from.streams..]) |r| {
        if (std.mem.startsWith(u8, r.url, session_uri)) {
            try testing.expectEqual(null, r.header(header_name));
            chunks.* += 1;
            continue;
        }
        out[n] = r.header(header_name);
        n += 1;
    }
    return out[0..n];
}

test "golden: every JSON write carries a token of its own, and no read or session chunk does" {
    var h: Harness = undefined;
    try h.init(comptime scriptOf(&writes) ++ scriptOf(&reads), .{ .single_request_limit = 16 });
    defer h.deinit();
    var seen: [writes.len + 1][]const u8 = undefined;
    var seen_len: usize = 0;
    var chunks: usize = 0;
    for (writes) |w| {
        errdefer std.debug.print("while calling {s}\n", .{w.what});
        const from: Sent = .now(&h);
        try w.run(&h.client);
        var buf: [8]?[]const u8 = undefined;
        const sent = try tokensSince(&h, from, &buf, &chunks);
        try testing.expect(sent.len >= 1);
        for (sent) |token| {
            const t = token orelse return error.TestExpectedToken;
            try testing.expectEqual(32, t.len);
            // A new token per call, and per request of a rewrite loop.
            for (seen[0..seen_len]) |earlier| try testing.expect(!std.mem.eql(u8, earlier, t));
            seen[seen_len] = t;
            seen_len += 1;
        }
    }
    try testing.expectEqual(writes.len + 1, seen_len);
    try testing.expectEqual(1, chunks);
    for (reads) |r| {
        errdefer std.debug.print("while calling {s}\n", .{r.what});
        const from: Sent = .now(&h);
        try r.run(&h.client);
        var buf: [8]?[]const u8 = undefined;
        const sent = try tokensSince(&h, from, &buf, &chunks);
        try testing.expectEqual(1, sent.len);
        try testing.expectEqual(null, sent[0]);
    }
}

test "golden: with the option off, no request carries a token" {
    var h: Harness = undefined;
    try h.init(comptime scriptOf(&writes), .{ .single_request_limit = 16, .idempotency_tokens = false });
    defer h.deinit();
    var chunks: usize = 0;
    for (writes) |w| {
        errdefer std.debug.print("while calling {s}\n", .{w.what});
        const from: Sent = .now(&h);
        try w.run(&h.client);
        var buf: [8]?[]const u8 = undefined;
        const sent = try tokensSince(&h, from, &buf, &chunks);
        // A bulk restore's retries depend on its token, so it keeps one.
        if (std.mem.eql(u8, w.what, "bulkRestore")) {
            try testing.expectEqual(32, sent[0].?.len);
            continue;
        }
        for (sent) |token| try testing.expectEqual(null, token);
    }
}

/// The token of every request `h` was sent, buffered then streamed.
fn allTokens(h: *const Harness, out: *[8]?[]const u8) []?[]const u8 {
    var n: usize = 0;
    for (h.fake.requests.items) |r| {
        out[n] = r.header(header_name);
        n += 1;
    }
    for (h.fake.stream_requests.items) |r| {
        out[n] = r.header(header_name);
        n += 1;
    }
    return out[0..n];
}

/// A write that answers a repeat with its first result, as an
/// unconditional call and as a conditional one.
const Repeatable = struct {
    what: []const u8,
    ok: Reply,
    unconditional: *const fn (*Client) anyerror!void,
    conditional: *const fn (*Client) anyerror!void,
};

const repeatables = [_]Repeatable{
    .{ .what = "upload", .ok = answer(object_json), .unconditional = struct {
        fn run(c: *Client) !void {
            var r = try object(c).upload("data", .{});
            r.deinit();
        }
    }.run, .conditional = struct {
        fn run(c: *Client) !void {
            var r = try object(c).upload("data", .{ .preconditions = .{ .if_generation_match = 7 } });
            r.deinit();
        }
    }.run },
    .{ .what = "updateMetadata", .ok = answer(object_json), .unconditional = struct {
        fn run(c: *Client) !void {
            var r = try object(c).updateMetadata(.{ .cache_control = "no-store" });
            r.deinit();
        }
    }.run, .conditional = struct {
        fn run(c: *Client) !void {
            var r = try object(c).updateMetadata(.{ .cache_control = "no-store", .preconditions = .{ .if_metageneration_match = 1 } });
            r.deinit();
        }
    }.run },
    .{ .what = "delete", .ok = no_content, .unconditional = struct {
        fn run(c: *Client) !void {
            try object(c).delete(.{});
        }
    }.run, .conditional = struct {
        fn run(c: *Client) !void {
            try object(c).delete(.{ .generation = 7 });
        }
    }.run },
};

test "retries: an upload, metadata update or delete without a condition retries to success, one token on every attempt" {
    for (repeatables) |w| {
        errdefer std.debug.print("while calling {s}\n", .{w.what});
        var h: Harness = undefined;
        try h.init(&.{ unavailable, .{ .fail = error.ConnectionResetByPeer }, w.ok }, .{
            .retry = .{ .max_attempts = 4, .initial_backoff_ms = 1 },
        });
        defer h.deinit();
        try w.unconditional(&h.client);
        var buf: [8]?[]const u8 = undefined;
        const sent = allTokens(&h, &buf);
        try testing.expectEqual(3, sent.len);
        for (sent[1..]) |t| try testing.expectEqualStrings(sent[0].?, t.?);
    }
}

test "retries: the writes that act again on a repeat carry one token on every attempt, and retry only as before" {
    // Under their conditions, retried, with one token.
    const Case = struct { what: []const u8, ok: Reply, run: *const fn (*Client) anyerror!void };
    const conditional = [_]Case{
        .{ .what = "composeFrom", .ok = answer(object_json), .run = struct {
            fn run(c: *Client) !void {
                var r = try object(c).composeFrom(&.{.{ .name = "x" }}, .{ .preconditions = .{ .if_generation_match = 7 } });
                r.deinit();
            }
        }.run },
        .{ .what = "restore", .ok = answer(object_json), .run = struct {
            fn run(c: *Client) !void {
                var r = try object(c).restore(.{ .generation = 7, .preconditions = .{ .if_generation_match = 0 } });
                r.deinit();
            }
        }.run },
        .{ .what = "bucket update", .ok = answer(bucket_json), .run = struct {
            fn run(c: *Client) !void {
                var r = try c.bucket("b").update(.{ .versioning = true, .if_metageneration_match = 1 });
                r.deinit();
            }
        }.run },
    };
    for (conditional) |w| {
        errdefer std.debug.print("while calling {s}\n", .{w.what});
        var h: Harness = undefined;
        try h.init(&.{ unavailable, w.ok }, .{ .retry = .{ .max_attempts = 4, .initial_backoff_ms = 1 } });
        defer h.deinit();
        try w.run(&h.client);
        var buf: [8]?[]const u8 = undefined;
        const sent = allTokens(&h, &buf);
        try testing.expectEqual(2, sent.len);
        try testing.expectEqualStrings(sent[0].?, sent[1].?);
    }

    // Without them, one attempt: the token does not stop a repeat acting.
    const unconditional = [_]Case{
        .{ .what = "composeFrom", .ok = answer(object_json), .run = struct {
            fn run(c: *Client) !void {
                var r = try object(c).composeFrom(&.{.{ .name = "x" }}, .{});
                r.deinit();
            }
        }.run },
        .{ .what = "restore", .ok = answer(object_json), .run = struct {
            fn run(c: *Client) !void {
                var r = try object(c).restore(.{ .generation = 7 });
                r.deinit();
            }
        }.run },
        .{ .what = "bucket update", .ok = answer(bucket_json), .run = struct {
            fn run(c: *Client) !void {
                var r = try c.bucket("b").update(.{ .versioning = true });
                r.deinit();
            }
        }.run },
    };
    for (unconditional) |w| {
        errdefer std.debug.print("while calling {s}\n", .{w.what});
        var h: Harness = undefined;
        try h.init(&.{ unavailable, w.ok }, .{ .retry = .{ .max_attempts = 4, .initial_backoff_ms = 1 } });
        defer h.deinit();
        try testing.expectError(error.Unavailable, w.run(&h.client));
        var buf: [8]?[]const u8 = undefined;
        try testing.expectEqual(1, allTokens(&h, &buf).len);
    }
}

test "retries: no retry without a condition begins more than 60 s after the first attempt; one with a condition goes on" {
    for (repeatables) |w| {
        errdefer std.debug.print("while calling {s}\n", .{w.what});
        // Every byte 0xff, and a cap of 32767 ms: each full-jitter wait is
        // the whole cap. Retries begin at 32.8 s, then 65.5 s.
        const retry: core.RetryPolicy = .{ .max_attempts = 5, .initial_backoff_ms = 32767, .max_backoff_ms = 32767, .multiplier = 1 };

        var h: Harness = undefined;
        try h.init(&.{ unavailable, unavailable, unavailable, w.ok }, .{ .retry = retry });
        defer h.deinit();
        h.clock.random_byte = 0xff;
        try testing.expectError(error.Unavailable, w.unconditional(&h.client));
        var buf: [8]?[]const u8 = undefined;
        try testing.expectEqual(2, allTokens(&h, &buf).len);
        try testing.expectEqual(32767, h.clock.sleepMs(0));

        var conditional: Harness = undefined;
        try conditional.init(&.{ unavailable, unavailable, unavailable, w.ok }, .{ .retry = retry });
        defer conditional.deinit();
        conditional.clock.random_byte = 0xff;
        try w.conditional(&conditional.client);
        try testing.expectEqual(4, allTokens(&conditional, &buf).len);

        // Opted in, past the window too.
        var opted: Harness = undefined;
        try opted.init(&.{ unavailable, unavailable, unavailable, w.ok }, .{ .retry = retry, .retry_unconditional_writes = true });
        defer opted.deinit();
        opted.clock.random_byte = 0xff;
        try w.unconditional(&opted.client);
        try testing.expectEqual(4, allTokens(&opted, &buf).len);
    }
}

/// A client on the in-memory fake, which answers a repeat with the kept
/// answer as Cloud Storage does, under a simulated clock: retries wait
/// 1 to 2 s, taking no time.
const Served = struct {
    clock: test_util.FakeClock,
    fake: FakeMultipart,
    faults: Faults,
    token: core.StaticToken,
    diag: core.Diagnostics,
    client: Client,

    fn init(s: *Served, tokens: bool, faults: Faults) !void {
        s.clock = .{};
        s.fake = .init(testing.allocator, s.clock.io());
        errdefer s.fake.deinit();
        s.faults = faults;
        s.fake.faults = s.faults.plan();
        s.token = .{ .token = "ya29.idempotency-test" };
        s.diag = .{};
        s.client = try .init(testing.allocator, s.clock.io(), .{
            .token_provider = s.token.provider(),
            .transport = s.fake.transport(),
            .diagnostics = &s.diag,
            .idempotency_tokens = tokens,
            .retry = .{ .max_attempts = 4, .initial_backoff_ms = 1000, .max_backoff_ms = 2000 },
        });
    }

    fn deinit(s: *Served) void {
        s.client.deinit();
        s.fake.deinit();
    }

    fn object(s: *Served, name: []const u8) Object {
        return s.client.bucket("b").object(name);
    }
};

/// The faults the fake's writes meet: `queue` in order, else drawn from
/// `gen`, else none. Reads meet none.
const Faults = struct {
    queue: []const FakeMultipart.Fault = &.{},
    next: usize = 0,
    gen: ?*test_util.ByteGen = null,

    fn plan(self: *Faults) FakeMultipart.FaultPlan {
        return .{ .ctx = self, .decide = decide };
    }

    fn decide(ctx: ?*anyopaque, kind: FakeMultipart.Kind, _: u32) FakeMultipart.Fault {
        const self: *Faults = @ptrCast(@alignCast(ctx.?));
        if (kind != .insert and kind != .delete) return .none;
        if (self.next < self.queue.len) {
            defer self.next += 1;
            return self.queue[self.next];
        }
        const g = self.gen orelse return .none;
        // 0, what a spent input reads as, is no fault.
        return switch (g.byte() % 8) {
            1 => .unavailable,
            2 => .reset,
            3, 4 => .lose_answer,
            else => .none,
        };
    }
};

test "lost answers: each repeatable write's repeat is answered with its first result, under any condition" {
    const Case = struct {
        what: []const u8,
        run: *const fn (*Served) anyerror!void,
        /// What the fake holds afterwards, or null for nothing.
        holds: ?[]const u8,
    };
    const cases = [_]Case{
        .{ .what = "upload", .holds = "new", .run = struct {
            fn run(s: *Served) !void {
                var r = try s.object("o").upload("new", .{});
                defer r.deinit();
                try testing.expectEqual(s.fake.object("o").?.generation, r.value.generation);
            }
        }.run },
        .{ .what = "upload of the generation there", .holds = "new", .run = struct {
            fn run(s: *Served) !void {
                var r = try s.object("o").upload("new", .{ .preconditions = .{ .if_generation_match = s.fake.object("o").?.generation } });
                r.deinit();
            }
        }.run },
        .{ .what = "delete", .holds = null, .run = struct {
            fn run(s: *Served) !void {
                try s.object("o").delete(.{});
            }
        }.run },
        .{ .what = "delete of a generation", .holds = null, .run = struct {
            fn run(s: *Served) !void {
                try s.object("o").delete(.{ .generation = s.fake.object("o").?.generation });
            }
        }.run },
    };
    for (cases) |case| {
        errdefer std.debug.print("while calling {s}\n", .{case.what});
        var s: Served = undefined;
        try s.init(true, .{ .queue = &.{.lose_answer} });
        defer s.deinit();
        try s.fake.put("o", "old");
        try case.run(&s);
        try testing.expectEqual(1, s.fake.counts.deduplicated);
        try testing.expectEqual(1, s.fake.counts.inserts + s.fake.counts.deletes);
        if (case.holds) |bytes| {
            try testing.expectEqualStrings(bytes, s.fake.object("o").?.bytes);
        } else {
            try testing.expectEqual(null, s.fake.object("o"));
        }
    }

    // A create-only upload that landed is answered 200 with its own object,
    // where a new request would fail its condition: its first attempt lost
    // its answer, its second met a 503, and its third got the kept answer.
    var s: Served = undefined;
    try s.init(true, .{ .queue = &.{ .lose_answer, .unavailable } });
    defer s.deinit();
    var created = try s.object("o").upload("mine", .{ .preconditions = .does_not_exist });
    defer created.deinit();
    try testing.expectEqual(s.fake.object("o").?.generation, created.value.generation);
    try testing.expectEqual(1, s.fake.counts.inserts);
    try testing.expectEqual(1, s.fake.counts.deduplicated);
    try testing.expectEqual(2, s.faults.next);
}

test "lost answers: a repeat after another writer's change is answered, not run, and leaves that writer's work" {
    // An upload lands and loses its answer; another writer replaces the
    // object; the repeat names the upload's own generation.
    var upload: Served = undefined;
    try upload.init(true, .{ .queue = &.{ .lose_answer, .clobber } });
    defer upload.deinit();
    var info = try upload.object("o").upload("mine", .{});
    defer info.deinit();
    try testing.expectEqual(1000, info.value.generation);
    try testing.expectEqualStrings("another writer's bytes", upload.fake.object("o").?.bytes);
    try testing.expectEqual(1001, upload.fake.object("o").?.generation);

    // A delete lands and loses its answer; another writer creates the name
    // again; the repeat is answered 204, and the new object stays.
    var delete: Served = undefined;
    try delete.init(true, .{ .queue = &.{ .lose_answer, .clobber } });
    defer delete.deinit();
    try delete.fake.put("o", "old");
    try delete.object("o").delete(.{});
    try testing.expectEqualStrings("another writer's bytes", delete.fake.object("o").?.bytes);
    try testing.expectEqual(1, delete.fake.counts.deletes);

    // A refusal is not kept: an upload refused 412 loses its answer, its
    // cause goes, and its repeat, with the same token, succeeds.
    var refused: Served = undefined;
    try refused.init(true, .{ .queue = &.{ .lose_answer, .clobber } });
    defer refused.deinit();
    try refused.fake.put("o", "old");
    // The generation the other writer's object will have.
    const next = refused.fake.next_generation;
    var landed = try refused.object("o").upload("mine", .{ .preconditions = .{ .if_generation_match = next } });
    defer landed.deinit();
    try testing.expectEqualStrings("mine", refused.fake.object("o").?.bytes);
    try testing.expectEqual(0, refused.fake.counts.deduplicated);
    try testing.expectEqual(2, refused.fake.counts.inserts);
}

test "the fake: a token is kept with its request's resource, as production keeps it" {
    // Measured: the same token on another object name runs normally. The
    // library never sends one twice, so this is the fake's own fidelity.
    var s: Served = undefined;
    try s.init(true, .{});
    defer s.deinit();
    try s.fake.put("x", "x");
    try s.fake.put("y", "y");
    const t = s.fake.transport();
    const same: []const Header = &.{.{ .name = header_name, .value = "one-token" }};
    for ([_][]const u8{ "x", "y" }) |name| {
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const url = try arena.allocator().print("https://storage.googleapis.com/storage/v1/b/b/o/{s}", .{name});
        const res = try t.send(.{ .method = .DELETE, .url = url, .headers = same }, arena.allocator());
        try testing.expectEqual(204, res.status);
    }
    try testing.expectEqual(null, s.fake.object("x"));
    try testing.expectEqual(null, s.fake.object("y"));
    try testing.expectEqual(0, s.fake.counts.deduplicated);
}

test "lost answers: without tokens, or once Cloud Storage forgets one, the repeat acts again and the ambiguity is reported" {
    // An upload without a condition is not retried.
    var plain: Served = undefined;
    try plain.init(false, .{ .queue = &.{.lose_answer} });
    defer plain.deinit();
    try testing.expectError(error.ConnectionResetByPeer, plain.object("o").upload("new", .{}));
    try testing.expectEqualStrings("new", plain.fake.object("o").?.bytes);

    for ([_]bool{ false, true }) |tokens| {
        var s: Served = undefined;
        try s.init(tokens, .{ .queue = &.{.lose_answer} });
        defer s.deinit();
        // Forgotten before the backoff ends.
        s.fake.dedup_ns = 1;
        try testing.expectError(error.FailedPrecondition, s.object("o").upload("mine", .{ .preconditions = .does_not_exist }));
        try testing.expect(std.mem.indexOf(u8, s.diag.message(), "an earlier attempt may have succeeded") != null);
        try testing.expectEqualStrings("mine", s.fake.object("o").?.bytes);
        try testing.expectEqual(0, s.fake.counts.deduplicated);
    }
}

/// What one object name held before a call.
const Snapshot = struct {
    generation: ?u64,
    bytes: [32]u8 = undefined,
    len: usize = 0,

    fn of(fake: *const FakeMultipart, name: []const u8) Snapshot {
        const o = fake.object(name) orelse return .{ .generation = null };
        var s: Snapshot = .{ .generation = o.generation, .len = o.bytes.len };
        @memcpy(s.bytes[0..o.bytes.len], o.bytes);
        return s;
    }

    fn expectNow(s: *const Snapshot, fake: *const FakeMultipart, name: []const u8) !void {
        const now: Snapshot = .of(fake, name);
        try testing.expectEqual(s.generation, now.generation);
        try testing.expectEqualStrings(s.bytes[0..s.len], now.bytes[0..now.len]);
    }
};

/// Uploads and deletes of two names, with and without conditions, under
/// drawn 503s, resets and lost answers, and retries a second or up to
/// 30 s apart, so the 60 s window cuts some short. Every call that
/// succeeds landed exactly once and answers with that landing; one that
/// fails a condition or finds nothing did so because the model says it
/// must, and changed nothing; one that runs out of attempts landed at
/// most once. The name not written is never touched.
fn landsOnceProperty(_: void, input: []const u8) !void {
    var g: test_util.ByteGen = .init(input);
    var s: Served = undefined;
    try s.init(true, .{ .gen = &g });
    defer s.deinit();
    // Past the fake's 120 s: every repeat a call sends is recognised.
    if (g.boolean()) s.client.retry = .{ .max_attempts = 4, .initial_backoff_ms = 20_000, .max_backoff_ms = 30_000 };

    const names = [_][]const u8{ "a", "b" };
    var op: usize = 0;
    while (g.pos < g.bytes.len and op < 16) : (op += 1) {
        const which = g.byte() % 2;
        const name = names[which];
        const other: Snapshot = .of(&s.fake, names[1 - which]);
        const before: Snapshot = .of(&s.fake, name);
        const next_before = s.fake.next_generation;
        var payload_buf: [16]u8 = undefined;
        const payload = std.fmt.bufPrint(&payload_buf, "v{d}", .{op}) catch unreachable;
        // A condition on the generation there, or on one that is not.
        const aimed: u64 = if (g.boolean()) before.generation orelse 1 else 1;

        switch (g.byte() % 5) {
            0, 1, 2 => |form| {
                const preconditions: types.Preconditions = switch (form) {
                    0 => .{},
                    1 => .does_not_exist,
                    else => .{ .if_generation_match = aimed },
                };
                const holds = switch (form) {
                    0 => true,
                    1 => before.generation == null,
                    else => before.generation == aimed,
                };
                if (s.object(name).upload(payload, .{ .preconditions = preconditions })) |info| {
                    var owned = info;
                    defer owned.deinit();
                    try testing.expect(holds);
                    try testing.expectEqual(next_before + 1, s.fake.next_generation);
                    try testing.expectEqual(next_before, owned.value.generation);
                    try testing.expectEqual(owned.value.generation, s.fake.object(name).?.generation);
                    try testing.expectEqualStrings(payload, s.fake.object(name).?.bytes);
                } else |err| switch (err) {
                    error.FailedPrecondition => {
                        try testing.expect(!holds);
                        try testing.expectEqual(next_before, s.fake.next_generation);
                        try before.expectNow(&s.fake, name);
                    },
                    error.Unavailable, error.ConnectionResetByPeer => if (s.fake.next_generation == next_before) {
                        try before.expectNow(&s.fake, name);
                    } else {
                        try testing.expect(holds);
                        try testing.expectEqual(next_before + 1, s.fake.next_generation);
                        try testing.expectEqualStrings(payload, s.fake.object(name).?.bytes);
                    },
                    else => return err,
                }
            },
            else => |form| {
                const pinned: ?u64 = if (form == 3) null else aimed;
                const there = before.generation != null and (pinned == null or pinned == before.generation);
                if (s.object(name).delete(.{ .generation = pinned })) {
                    try testing.expect(there);
                    try testing.expectEqual(null, s.fake.object(name));
                } else |err| switch (err) {
                    error.NotFound => {
                        try testing.expect(!there);
                        try before.expectNow(&s.fake, name);
                    },
                    // Gone only if it was there to delete.
                    error.Unavailable, error.ConnectionResetByPeer => if (before.generation != null and s.fake.object(name) == null) {
                        try testing.expect(there);
                    } else {
                        try before.expectNow(&s.fake, name);
                    },
                    else => return err,
                }
                try testing.expectEqual(next_before, s.fake.next_generation);
            },
        }
        try other.expectNow(&s.fake, names[1 - which]);
    }
}

test "heavy property idempotency: every write lands once and answers with its landing, under lost answers and faults, as a model says" {
    try test_util.fuzzBytes({}, landsOnceProperty, .{
        .corpus = &.{
            "",
            // Retries a second or two apart. Each write of "a" loses its
            // first answer: an upload, one of the generation there, a
            // create-only one refused, a delete of the generation there, a
            // create-only upload, a delete; then an upload of "b".
            "\x00" ++ "\x00\x00\x00\x03\x00" ++ "\x00\x01\x02\x03\x00" ++ "\x00\x00\x01\x00" ++
                "\x00\x01\x04\x03\x00" ++ "\x00\x00\x01\x03\x00" ++ "\x00\x00\x03\x03\x00" ++ "\x01\x00\x00\x03\x00",
            // Retries up to 30 s apart, so the window may cut the ones
            // without a condition short. Each write loses its first answer
            // and meets a 503 on its second attempt: an upload, a delete, a
            // create-only upload, a delete of the generation there.
            "\x01" ++ "\x00\x00\x00\x03\x01\x00" ++ "\x00\x00\x03\x03\x01\x00" ++
                "\x00\x00\x01\x03\x01\x00" ++ "\x00\x01\x04\x03\x01\x00",
        },
    });
}
