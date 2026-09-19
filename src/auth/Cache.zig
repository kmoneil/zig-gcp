//! One access token, refreshed before it expires. Every provider in this
//! module embeds a `Cache` and hands it a `Source` that fetches a token. The
//! cache decides when to fetch, lets one fetch run at a time, and copies the
//! token out for each caller.
//!
//! By the token's remaining life when `getToken` is called:
//!
//! - fresh, more than the refresh margin: the cached token, with no I/O;
//! - stale, within the margin: a fetch. If it fails, the cached token, which
//!   is still valid, a warning in the log, and another try 10 s later;
//! - expired, missing or invalidated: a fetch. If it fails, the error.

const Cache = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("core");
const TokenProvider = core.TokenProvider;
const logging = @import("logging.zig");

gpa: Allocator,
options: Options,
mutex: std.Io.Mutex = .init,
/// Set by `invalidate`, which cannot wait for the mutex. The next
/// `getToken` drops the token.
invalidated: std.atomic.Value(bool) = .init(false),
/// Owned by the cache, and wiped before it is freed. Empty when there is none.
token: []u8 = &.{},
/// Both on the boot clock, which keeps counting while the machine sleeps.
refresh_at: std.Io.Timestamp = .zero,
expires_at: std.Io.Timestamp = .zero,

/// How long to wait after a failed early refresh before trying again.
pub const retry_delay_s = 10;

pub const Options = struct {
    /// Fetch a new token when less than this much of its life remains. Must
    /// be below 300: the metadata server hands out the same token until
    /// about five minutes before it expires, so a larger margin would fetch
    /// that same token on every call. A token that lives less than twice
    /// the margin is refreshed at half its life instead.
    refresh_margin_s: u32 = 240,
    /// A token that claims to live longer is treated as living this long.
    max_lifetime_s: u32 = 12 * 60 * 60,
};

/// A token from a `Source`.
pub const Fetched = struct {
    /// May point into the arena passed to the fetch. The cache copies it,
    /// then wipes and frees the arena.
    token: []const u8,
    /// Seconds until the token expires, as the server said: `expires_in`.
    expires_in: i64,
};

/// How a provider fetches a token.
pub const Source = struct {
    ptr: *anyopaque,
    fetchFn: *const fn (ptr: *anyopaque, io: std.Io, arena: Allocator) TokenProvider.Error!Fetched,

    pub fn fetch(source: Source, io: std.Io, arena: Allocator) TokenProvider.Error!Fetched {
        return source.fetchFn(source.ptr, io, arena);
    }
};

pub const InitError = error{
    /// `refresh_margin_s` is 300 or more, or `max_lifetime_s` is 0.
    InvalidOptions,
};

pub fn init(gpa: Allocator, options: Options) InitError!Cache {
    if (options.refresh_margin_s >= 300 or options.max_lifetime_s == 0) return error.InvalidOptions;
    return .{ .gpa = gpa, .options = options };
}

/// Wipes and frees the token. Nothing may be using the cache.
pub fn deinit(self: *Cache) void {
    self.drop();
    self.* = undefined;
}

/// A token valid for at least the next request, copied into `arena`.
/// Callers that arrive during a fetch wait for it and share its token.
pub fn getToken(self: *Cache, io: std.Io, arena: Allocator, source: Source) TokenProvider.Error![]const u8 {
    try self.mutex.lock(io);
    defer self.mutex.unlock(io);
    if (self.invalidated.swap(false, .acq_rel)) self.drop();
    const now = std.Io.Timestamp.now(io, .boot);
    if (self.token.len != 0 and now.nanoseconds < self.refresh_at.nanoseconds) {
        return arena.dupe(u8, self.token);
    }
    self.refresh(io, source, now) catch |err| {
        // A stale token is still valid, and a failed early refresh is no
        // reason to fail the call. Cancellation and lack of memory are.
        const valid = self.token.len != 0 and now.nanoseconds < self.expires_at.nanoseconds;
        if (!valid or err == error.Canceled or err == error.OutOfMemory) return err;
        // Try again soon, not on every call until the token expires.
        const retry_at = now.addDuration(.fromSeconds(retry_delay_s));
        self.refresh_at = if (retry_at.nanoseconds < self.expires_at.nanoseconds) retry_at else self.expires_at;
        logging.warn("refreshing the token failed with {t}; the cached one is good for {d} s more", .{
            err, now.durationTo(self.expires_at).toSeconds(),
        });
    };
    return arena.dupe(u8, self.token);
}

/// Drops the token, so the next `getToken` fetches a new one. If that fetch
/// fails, the call fails: a token the server refused is not reused. Does
/// not block.
pub fn invalidate(self: *Cache) void {
    self.invalidated.store(true, .release);
}

fn refresh(self: *Cache, io: std.Io, source: Source, now: std.Io.Timestamp) TokenProvider.Error!void {
    // Whatever the source kept in its scratch memory held the token too.
    var wiping: core.WipingAllocator = .init(self.gpa);
    var scratch: std.heap.ArenaAllocator = .init(wiping.allocator());
    defer scratch.deinit();
    const fetched = try source.fetch(io, scratch.allocator());
    if (!TokenProvider.isValidToken(fetched.token) or fetched.expires_in <= 0) return error.InvalidTokenResponse;
    const lifetime_s: u32 = @intCast(@min(fetched.expires_in, self.options.max_lifetime_s));
    const margin_s = @min(self.options.refresh_margin_s, lifetime_s / 2);
    const copy = try self.gpa.dupe(u8, fetched.token);
    self.drop();
    self.token = copy;
    self.expires_at = now.addDuration(.fromSeconds(lifetime_s));
    self.refresh_at = self.expires_at.subDuration(.fromSeconds(margin_s));
    logging.debug("fetched a token of {d} bytes, good for {d} s", .{ copy.len, lifetime_s });
}

/// Wipes the token and frees it with `rawFree`, so the wipe is the last
/// write: `Allocator.free` would overwrite it with a debug pattern first.
fn drop(self: *Cache) void {
    if (self.token.len == 0) return;
    std.crypto.secureZero(u8, self.token);
    self.gpa.rawFree(self.token, .fromByteUnits(@alignOf(u8)), @returnAddress());
    self.token = &.{};
}

const testing = std.testing;
const FakeClock = core.testing.FakeClock;
const ByteGen = core.testing.ByteGen;
const WipeChecker = core.testing.WipeChecker;

/// A `Source` that answers each fetch with the next scripted reply.
const FakeSource = struct {
    replies: []const Reply,
    next: usize = 0,
    fetches: usize = 0,

    const Reply = union(enum) {
        token: struct { []const u8, i64 },
        fail: TokenProvider.Error,
    };

    fn source(self: *FakeSource) Source {
        return .{ .ptr = self, .fetchFn = fetch };
    }

    fn fetch(ptr: *anyopaque, io: std.Io, arena: Allocator) TokenProvider.Error!Fetched {
        _ = io;
        const self: *FakeSource = @ptrCast(@alignCast(ptr));
        self.fetches += 1;
        if (self.next >= self.replies.len) return error.TokenUnavailable;
        const reply = self.replies[self.next];
        self.next += 1;
        return switch (reply) {
            .fail => |err| err,
            // In the arena, as a parsed response would be.
            .token => |t| .{ .token = try arena.dupe(u8, t[0]), .expires_in = t[1] },
        };
    }
};

/// A cache on a fake clock, and an arena for the copies it hands out.
const Setup = struct {
    clock: FakeClock,
    arena: std.heap.ArenaAllocator,
    cache: Cache,

    fn init(options: Options) !Setup {
        return .{ .clock = .{}, .arena = .init(testing.allocator), .cache = try .init(testing.allocator, options) };
    }

    fn deinit(s: *Setup) void {
        s.cache.deinit();
        s.arena.deinit();
    }

    /// `source` is a `*FakeSource` or a `*CountingSource`.
    fn get(s: *Setup, source: anytype) TokenProvider.Error![]const u8 {
        return s.cache.getToken(s.clock.io(), s.arena.allocator(), source.source());
    }

    fn advance(s: *Setup, seconds: i64) void {
        s.clock.now_ns += @as(i96, seconds) * std.time.ns_per_s;
    }
};

test "Cache: a fresh token is returned without fetching again" {
    var s: Setup = try .init(.{});
    defer s.deinit();
    var source: FakeSource = .{ .replies = &.{.{ .token = .{ "ya29.one", 3600 } }} };
    try testing.expectEqualStrings("ya29.one", try s.get(&source));
    // Just inside the margin: 3600 - 240 - 1 seconds later.
    s.advance(3359);
    try testing.expectEqualStrings("ya29.one", try s.get(&source));
    try testing.expectEqual(1, source.fetches);
}

test "Cache: a stale token is replaced before it expires" {
    var s: Setup = try .init(.{});
    defer s.deinit();
    var source: FakeSource = .{ .replies = &.{
        .{ .token = .{ "ya29.one", 3600 } },
        .{ .token = .{ "ya29.two", 3600 } },
    } };
    _ = try s.get(&source);
    s.advance(3360);
    try testing.expectEqualStrings("ya29.two", try s.get(&source));
    try testing.expectEqual(2, source.fetches);
}

test "Cache: a failed early refresh returns the cached token, warns, and retries 10 s later" {
    logging.capture.reset();
    var s: Setup = try .init(.{});
    defer s.deinit();
    var source: FakeSource = .{ .replies = &.{
        .{ .token = .{ "ya29.SECRET-one", 3600 } },
        .{ .fail = error.ConnectionRefused },
        .{ .token = .{ "ya29.two", 3600 } },
    } };
    _ = try s.get(&source);
    s.advance(3400);
    try testing.expectEqualStrings("ya29.SECRET-one", try s.get(&source));
    try testing.expectEqual(2, source.fetches);
    // Within the retry delay: no fetch, the same token.
    s.advance(retry_delay_s - 1);
    try testing.expectEqualStrings("ya29.SECRET-one", try s.get(&source));
    try testing.expectEqual(2, source.fetches);
    s.advance(1);
    try testing.expectEqualStrings("ya29.two", try s.get(&source));
    try testing.expectEqual(3, source.fetches);

    const log = logging.capture.text();
    try testing.expect(std.mem.indexOf(u8, log, "warn: refreshing the token failed with ConnectionRefused; the cached one is good for 200 s more") != null);
    try testing.expect(std.mem.indexOf(u8, log, "SECRET") == null);
}

test "Cache: an expired token is not returned when the refresh fails" {
    var s: Setup = try .init(.{});
    defer s.deinit();
    var source: FakeSource = .{ .replies = &.{
        .{ .token = .{ "ya29.one", 3600 } },
        .{ .fail = error.RefreshTokenInvalid },
    } };
    _ = try s.get(&source);
    s.advance(3600);
    try testing.expectError(error.RefreshTokenInvalid, s.get(&source));
}

test "Cache: after invalidate, the token is fetched again and never reused" {
    var s: Setup = try .init(.{});
    defer s.deinit();
    var source: FakeSource = .{ .replies = &.{
        .{ .token = .{ "ya29.one", 3600 } },
        .{ .fail = error.ConnectionRefused },
        .{ .token = .{ "ya29.two", 3600 } },
    } };
    _ = try s.get(&source);
    s.cache.invalidate();
    // The old token is still within its life, but the server refused it.
    try testing.expectError(error.ConnectionRefused, s.get(&source));
    try testing.expectEqualStrings("ya29.two", try s.get(&source));
    try testing.expectEqual(3, source.fetches);
}

test "Cache: a response without a usable token or lifetime is InvalidTokenResponse" {
    var s: Setup = try .init(.{});
    defer s.deinit();
    var source: FakeSource = .{ .replies = &.{
        .{ .token = .{ "ya29.one", 0 } },
        .{ .token = .{ "ya29.one", -5 } },
        .{ .token = .{ "", 3600 } },
        .{ .token = .{ "ya29.one\r\nX-Injected: 1", 3600 } },
    } };
    for (0..4) |_| try testing.expectError(error.InvalidTokenResponse, s.get(&source));
}

test "Cache: a lifetime beyond max_lifetime_s is clamped" {
    var s: Setup = try .init(.{ .max_lifetime_s = 3600 });
    defer s.deinit();
    var source: FakeSource = .{ .replies = &.{
        .{ .token = .{ "ya29.forever", 10 * 365 * 24 * 3600 } },
        .{ .token = .{ "ya29.next", 3600 } },
    } };
    _ = try s.get(&source);
    s.advance(3600 - 240);
    try testing.expectEqualStrings("ya29.next", try s.get(&source));
}

test "Cache: a short-lived token is refreshed at half its life, not on every call" {
    var s: Setup = try .init(.{});
    defer s.deinit();
    var source: FakeSource = .{ .replies = &.{
        .{ .token = .{ "ya29.brief", 100 } },
        .{ .token = .{ "ya29.next", 100 } },
    } };
    _ = try s.get(&source);
    s.advance(49);
    try testing.expectEqualStrings("ya29.brief", try s.get(&source));
    s.advance(1);
    try testing.expectEqualStrings("ya29.next", try s.get(&source));
}

test "Cache: cancellation and running out of memory are never covered by the cached token" {
    var s: Setup = try .init(.{});
    defer s.deinit();
    var source: FakeSource = .{ .replies = &.{
        .{ .token = .{ "ya29.one", 3600 } },
        .{ .fail = error.Canceled },
        .{ .fail = error.OutOfMemory },
    } };
    _ = try s.get(&source);
    s.advance(3400);
    try testing.expectError(error.Canceled, s.get(&source));
    try testing.expectError(error.OutOfMemory, s.get(&source));
}

test "Cache: init rejects a margin of 300 s or more, and no lifetime" {
    try testing.expectError(error.InvalidOptions, Cache.init(testing.allocator, .{ .refresh_margin_s = 300 }));
    try testing.expectError(error.InvalidOptions, Cache.init(testing.allocator, .{ .max_lifetime_s = 0 }));
}

test "Cache: each caller gets its own copy" {
    var s: Setup = try .init(.{});
    defer s.deinit();
    var source: FakeSource = .{ .replies = &.{
        .{ .token = .{ "ya29.one", 3600 } },
        .{ .token = .{ "ya29.two", 3600 } },
    } };
    const first = try s.get(&source);
    try testing.expect(first.ptr != s.cache.token.ptr);
    s.cache.invalidate();
    _ = try s.get(&source);
    // Replacing the token did not change the copy handed out before.
    try testing.expectEqualStrings("ya29.one", first);
}

test "Cache: every block the cache frees is wiped first" {
    var checker: WipeChecker = .{ .child = testing.allocator };
    var clock: FakeClock = .{};
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var source: FakeSource = .{ .replies = &.{
        .{ .token = .{ "ya29.one", 3600 } },
        .{ .token = .{ "ya29.two", 3600 } },
        .{ .token = .{ "ya29.three", 3600 } },
    } };
    var cache: Cache = try .init(checker.allocator(), .{});
    // A fetch, a refresh that replaces the token, and a fetch after invalidate.
    _ = try cache.getToken(clock.io(), arena.allocator(), source.source());
    clock.now_ns += 3400 * std.time.ns_per_s;
    _ = try cache.getToken(clock.io(), arena.allocator(), source.source());
    cache.invalidate();
    _ = try cache.getToken(clock.io(), arena.allocator(), source.source());
    cache.deinit();
    // Three token copies, and at least one arena chunk per fetch.
    try testing.expect(checker.frees >= 6);
    try testing.expectEqual(0, checker.unwiped);
}

test "Cache: every allocation failure is OutOfMemory without leaks" {
    const Run = struct {
        fn run(gpa: Allocator) !void {
            var clock: FakeClock = .{};
            var arena: std.heap.ArenaAllocator = .init(gpa);
            defer arena.deinit();
            var source: FakeSource = .{ .replies = &.{
                .{ .token = .{ "ya29.one", 3600 } },
                .{ .token = .{ "ya29.two", 3600 } },
                .{ .token = .{ "ya29.three", 3600 } },
            } };
            var cache: Cache = try .init(gpa, .{});
            defer cache.deinit();
            _ = try cache.getToken(clock.io(), arena.allocator(), source.source());
            clock.now_ns += 3400 * std.time.ns_per_s;
            _ = try cache.getToken(clock.io(), arena.allocator(), source.source());
            cache.invalidate();
            _ = try cache.getToken(clock.io(), arena.allocator(), source.source());
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Run.run, .{});
}

test "Cache: callers that arrive during a fetch wait for it and share its token" {
    const io = testing.io;
    const Blocking = struct {
        started: std.Io.Event = .unset,
        release: std.Io.Event = .unset,
        fetches: std.atomic.Value(u32) = .init(0),

        fn source(self: *@This()) Source {
            return .{ .ptr = self, .fetchFn = fetch };
        }

        fn fetch(ptr: *anyopaque, fetch_io: std.Io, arena: Allocator) TokenProvider.Error!Fetched {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            _ = self.fetches.fetchAdd(1, .monotonic);
            self.started.set(fetch_io);
            try self.release.wait(fetch_io);
            return .{ .token = try arena.dupe(u8, "ya29.shared"), .expires_in = 3600 };
        }
    };
    var blocking: Blocking = .{};
    var cache: Cache = try .init(testing.allocator, .{});
    defer cache.deinit();
    var arena_a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_a.deinit();
    var arena_b: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_b.deinit();

    var first = try io.concurrent(Cache.getToken, .{ &cache, io, arena_a.allocator(), blocking.source() });
    defer _ = first.cancel(io) catch "";
    try blocking.started.wait(io);
    // The first caller holds the lock and is fetching. The second arrives.
    var second = try io.concurrent(Cache.getToken, .{ &cache, io, arena_b.allocator(), blocking.source() });
    defer _ = second.cancel(io) catch "";
    try io.sleep(.fromMilliseconds(20), .awake);
    blocking.release.set(io);
    try testing.expectEqualStrings("ya29.shared", try first.await(io));
    try testing.expectEqualStrings("ya29.shared", try second.await(io));
    try testing.expectEqual(1, blocking.fetches.load(.monotonic));
}

/// The outcome the model and the fake source agree on for the next fetch.
const Outcome = union(enum) {
    token: i64,
    fail: TokenProvider.Error,
};

const outcomes = [_]Outcome{
    .{ .token = 3600 },
    .{ .token = 480 },
    .{ .token = 100 },
    .{ .token = 7 },
    .{ .token = 1 },
    .{ .token = 0 },
    .{ .token = -5 },
    .{ .token = 1_000_000_000 },
    .{ .fail = error.ConnectionRefused },
    .{ .fail = error.RefreshTokenInvalid },
    .{ .fail = error.Canceled },
    .{ .fail = error.OutOfMemory },
};

/// A source that gives each fetch a fresh token named by its number.
const CountingSource = struct {
    outcome: Outcome = .{ .token = 3600 },
    fetches: u32 = 0,

    fn source(self: *CountingSource) Source {
        return .{ .ptr = self, .fetchFn = fetch };
    }

    fn fetch(ptr: *anyopaque, io: std.Io, arena: Allocator) TokenProvider.Error!Fetched {
        _ = io;
        const self: *CountingSource = @ptrCast(@alignCast(ptr));
        self.fetches += 1;
        return switch (self.outcome) {
            .fail => |err| err,
            .token => |expires_in| .{
                .token = try std.fmt.allocPrint(arena, "ya29.t{d}", .{self.fetches}),
                .expires_in = expires_in,
            },
        };
    }
};

fn modelProperty(_: void, input: []const u8) !void {
    var g: ByteGen = .init(input);
    var s: Setup = try .init(.{});
    defer s.deinit();
    var source: CountingSource = .{};

    // The spec's table, restated: the token by its fetch number, and when
    // it goes stale and expires, in seconds.
    var token: ?u32 = null;
    var refresh_at: i64 = 0;
    var expires_at: i64 = 0;
    var now: i64 = 0;
    var invalidated = false;

    while (g.pos < g.bytes.len) switch (g.intRange(u8, 0, 3)) {
        0 => {
            const step = g.intRange(u16, 0, 4000);
            now += step;
            s.advance(step);
        },
        1 => {
            s.cache.invalidate();
            invalidated = true;
        },
        else => {
            source.outcome = g.pick(Outcome, &outcomes);
            const fetches_before = source.fetches;
            const got = s.get(&source);

            if (invalidated) token = null;
            invalidated = false;
            const expected: TokenProvider.Error!?u32 = if (token != null and now < refresh_at) token else fetched: {
                const fetch_number = fetches_before + 1;
                const err: TokenProvider.Error = switch (source.outcome) {
                    .fail => |err| err,
                    .token => |expires_in| if (expires_in <= 0) error.InvalidTokenResponse else {
                        const lifetime: i64 = @min(expires_in, 12 * 60 * 60);
                        token = fetch_number;
                        expires_at = now + lifetime;
                        refresh_at = expires_at - @min(240, @divFloor(lifetime, 2));
                        break :fetched token;
                    },
                };
                const valid = token != null and now < expires_at;
                if (!valid or err == error.Canceled or err == error.OutOfMemory) break :fetched err;
                refresh_at = @min(now + retry_delay_s, expires_at);
                break :fetched token;
            };

            if (expected) |number| {
                var name: [32]u8 = undefined;
                try testing.expectEqualStrings(try std.fmt.bufPrint(&name, "ya29.t{d}", .{number.?}), try got);
            } else |err| {
                try testing.expectError(err, got);
            }
        },
    };
}

test "fuzz Cache: every call matches the spec's table" {
    // Seeds, as the property reads them: one byte picks the step (0 advance,
    // 1 invalidate, 2 or 3 getToken); an advance takes a big-endian u16 of
    // seconds; a getToken takes an 8-byte index into `outcomes`.
    try core.testing.fuzzBytes({}, modelProperty, .{
        .corpus = &.{
            // Stale, a failed refresh falls back; the retry waits 10 s.
            "\x02\x00\x00\x00\x00\x00\x00\x00\x00\x00\x0d\x48\x02\x00\x00\x00\x00\x00\x00\x00\x08\x00\x00\x09\x02\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01\x02\x00\x00\x00\x00\x00\x00\x00\x00",
            // A short-lived token is refreshed at half its life.
            "\x02\x00\x00\x00\x00\x00\x00\x00\x02\x00\x00\x31\x02\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01\x02\x00\x00\x00\x00\x00\x00\x00\x00",
            // After invalidate, a failed fetch is not covered by the old token.
            "\x02\x00\x00\x00\x00\x00\x00\x00\x00\x01\x02\x00\x00\x00\x00\x00\x00\x00\x08\x02\x00\x00\x00\x00\x00\x00\x00\x00",
            // A claimed lifetime of 1e9 s is clamped to 12 h.
            "\x02\x00\x00\x00\x00\x00\x00\x00\x07\x00\x0f\xa0\x00\x0f\xa0\x00\x0f\xa0\x00\x0f\xa0\x00\x0f\xa0\x00\x0f\xa0\x00\x0f\xa0\x00\x0f\xa0\x00\x0f\xa0\x00\x0f\xa0\x00\x0b\x90\x02\x00\x00\x00\x00\x00\x00\x00\x00",
            // Cancellation during a stale refresh is not covered.
            "\x02\x00\x00\x00\x00\x00\x00\x00\x00\x00\x0d\x48\x02\x00\x00\x00\x00\x00\x00\x00\x0a\x02\x00\x00\x00\x00\x00\x00\x00\x00",
        },
    });
}
