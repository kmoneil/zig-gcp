//! Test helpers: a scripted fake transport, a fake clock, and a runner for
//! byte-driven property tests that also feeds `zig build test --fuzz`.
//! The modules' own tests use them, and so can tests of code that uses the
//! modules. Nothing here is referenced by a normal build.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Transport = @import("transport.zig").Transport;
const TransportError = @import("transport.zig").Error;
const Method = @import("transport.zig").Method;
const Request = @import("transport.zig").Request;
const Response = @import("transport.zig").Response;
const ContentType = @import("transport.zig").ContentType;
const TokenProvider = @import("TokenProvider.zig");

/// A `TokenProvider` that returns one token, or fails with one error, and
/// counts how it is used.
pub const FakeTokenProvider = struct {
    /// Returned, copied into the caller's arena, while `fail` is null.
    token: []const u8 = "ya29.fake-token",
    /// When set, `getToken` fails with it.
    fail: ?TokenProvider.Error = null,
    /// What `quotaProject` returns.
    quota_project: ?[]const u8 = null,
    /// `getToken` calls so far, failed ones included.
    calls: usize = 0,
    invalidations: usize = 0,
    /// How many scopes the latest `getToken` call asked for.
    scope_count: usize = 0,
    first_scope_buffer: [128]u8 = undefined,
    first_scope_len: usize = 0,

    pub fn provider(self: *FakeTokenProvider) TokenProvider {
        return .{ .ptr = self, .vtable = &.{
            .getToken = getToken,
            .invalidate = invalidate,
            .quotaProject = quotaProject,
        } };
    }

    /// The first scope of the latest `getToken` call, truncated to 128 bytes.
    pub fn firstScope(self: *const FakeTokenProvider) []const u8 {
        return self.first_scope_buffer[0..self.first_scope_len];
    }

    fn fromPtr(ptr: *anyopaque) *FakeTokenProvider {
        return @ptrCast(@alignCast(ptr));
    }

    fn getToken(ptr: *anyopaque, io: std.Io, arena: Allocator, scopes: []const []const u8) TokenProvider.Error![]const u8 {
        _ = io;
        const self = fromPtr(ptr);
        self.calls += 1;
        self.scope_count = scopes.len;
        const first = if (scopes.len > 0) scopes[0] else "";
        self.first_scope_len = @min(first.len, self.first_scope_buffer.len);
        @memcpy(self.first_scope_buffer[0..self.first_scope_len], first[0..self.first_scope_len]);
        if (self.fail) |err| return err;
        return arena.dupe(u8, self.token);
    }

    fn invalidate(ptr: *anyopaque) void {
        fromPtr(ptr).invalidations += 1;
    }

    fn quotaProject(ptr: *anyopaque) ?[]const u8 {
        return fromPtr(ptr).quota_project;
    }
};

/// A `Transport` that records every request and answers from a script.
pub const FakeTransport = struct {
    gpa: Allocator,
    script: []const Reply,
    next: usize = 0,
    requests: std.ArrayList(Recorded) = .empty,

    pub const Reply = union(enum) {
        respond: Canned,
        fail: TransportError,
    };

    pub const Canned = struct {
        status: u16 = 200,
        body: []const u8 = "{}",
    };

    /// A deep copy of one request, owned by the fake.
    pub const Recorded = struct {
        method: Method,
        url: []u8,
        bearer: ?[]u8,
        body: ?[]u8,
        content_type: ContentType,
    };

    pub fn init(gpa: Allocator, script: []const Reply) FakeTransport {
        return .{ .gpa = gpa, .script = script };
    }

    pub fn deinit(self: *FakeTransport) void {
        for (self.requests.items) |r| {
            self.gpa.free(r.url);
            if (r.bearer) |b| self.gpa.free(b);
            if (r.body) |b| self.gpa.free(b);
        }
        self.requests.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn transport(self: *FakeTransport) Transport {
        return .{ .ptr = self, .vtable = &.{ .send = send } };
    }

    /// The request at `index`, failing the test when there is none.
    pub fn request(self: *const FakeTransport, index: usize) !Recorded {
        if (index >= self.requests.items.len) {
            std.debug.print("expected request {d}, saw {d}\n", .{ index, self.requests.items.len });
            return error.TestExpectedRequest;
        }
        return self.requests.items[index];
    }

    fn send(ptr: *anyopaque, req: Request, arena: Allocator) TransportError!Response {
        const self: *FakeTransport = @ptrCast(@alignCast(ptr));
        try self.record(req);
        // A script that runs out means the code under test sent more requests
        // than the test expected; the request count assertions catch it.
        if (self.next >= self.script.len) return error.HttpProtocolError;
        const reply = self.script[self.next];
        self.next += 1;
        return switch (reply) {
            .fail => |err| err,
            // Copy into the arena, as the real transport does, so ownership bugs show up.
            .respond => |canned| .{
                .status = canned.status,
                .body = try arena.dupe(u8, canned.body),
            },
        };
    }

    fn record(self: *FakeTransport, req: Request) Allocator.Error!void {
        const url = try self.gpa.dupe(u8, req.url);
        errdefer self.gpa.free(url);
        const bearer = if (req.bearer) |b| try self.gpa.dupe(u8, b) else null;
        errdefer if (bearer) |b| self.gpa.free(b);
        const body = if (req.body) |b| try self.gpa.dupe(u8, b) else null;
        errdefer if (body) |b| self.gpa.free(b);
        try self.requests.append(self.gpa, .{
            .method = req.method,
            .url = url,
            .bearer = bearer,
            .body = body,
            .content_type = req.content_type,
        });
    }
};

/// An `Io` whose clock, sleep and randomness are simulated. Every other
/// operation fails, as in `std.Io.failing`, so a test cannot touch the network.
pub const FakeClock = struct {
    now_ns: i96 = 0,
    /// Every sleep requested, in nanoseconds, up to the array length.
    sleeps: [64]i96 = undefined,
    sleep_count: usize = 0,
    /// When set, `random` fills every byte with this value instead of the PRNG.
    random_byte: ?u8 = null,
    prng: std.Random.DefaultPrng = .init(0x9e37_79b9_7f4a_7c15),
    /// When set, `sleep` reports cancellation, as a canceled task would see it.
    cancel_sleep: bool = false,

    pub fn io(self: *FakeClock) std.Io {
        return .{ .userdata = self, .vtable = &vtable };
    }

    /// The recorded sleeps, in milliseconds.
    pub fn sleepMs(self: *const FakeClock, index: usize) i64 {
        return @intCast(@divTrunc(self.sleeps[index], std.time.ns_per_ms));
    }

    const vtable: std.Io.VTable = v: {
        var v = std.Io.failing.vtable.*;
        v.now = now;
        v.sleep = sleep;
        v.random = random;
        break :v v;
    };

    fn fromUserdata(userdata: ?*anyopaque) *FakeClock {
        return @ptrCast(@alignCast(userdata.?));
    }

    fn now(userdata: ?*anyopaque, clock: std.Io.Clock) std.Io.Timestamp {
        _ = clock;
        return .{ .nanoseconds = fromUserdata(userdata).now_ns };
    }

    fn sleep(userdata: ?*anyopaque, timeout: std.Io.Timeout) std.Io.Cancelable!void {
        const self = fromUserdata(userdata);
        if (self.cancel_sleep) return error.Canceled;
        const ns: i96 = switch (timeout) {
            .none => 0,
            .duration => |d| d.raw.nanoseconds,
            .deadline => |d| d.raw.nanoseconds - self.now_ns,
        };
        if (self.sleep_count < self.sleeps.len) self.sleeps[self.sleep_count] = ns;
        self.sleep_count += 1;
        self.now_ns += ns;
    }

    fn random(userdata: ?*anyopaque, buffer: []u8) void {
        const self = fromUserdata(userdata);
        if (self.random_byte) |b| {
            @memset(buffer, b);
        } else {
            self.prng.random().bytes(buffer);
        }
    }
};

/// Derives structured values from arbitrary bytes. Reads past the end yield
/// zeros, so every input, including the empty one, is valid.
pub const ByteGen = struct {
    bytes: []const u8,
    pos: usize = 0,

    pub fn init(bytes: []const u8) ByteGen {
        return .{ .bytes = bytes };
    }

    pub fn byte(g: *ByteGen) u8 {
        if (g.pos >= g.bytes.len) return 0;
        defer g.pos += 1;
        return g.bytes[g.pos];
    }

    pub fn boolean(g: *ByteGen) bool {
        return g.byte() & 1 == 1;
    }

    /// An unsigned integer built from the next `@sizeOf(T)` bytes.
    pub fn int(g: *ByteGen, comptime T: type) T {
        comptime std.debug.assert(@typeInfo(T).int.signedness == .unsigned);
        var v: u128 = 0;
        for (0..@sizeOf(T)) |_| v = (v << 8) | g.byte();
        return @truncate(v);
    }

    /// An unsigned integer in `[lo, hi]`.
    pub fn intRange(g: *ByteGen, comptime T: type, lo: T, hi: T) T {
        std.debug.assert(lo <= hi);
        const span: u128 = @as(u128, hi - lo) + 1;
        return lo + @as(T, @intCast(@as(u128, g.int(T)) % span));
    }

    /// Up to `n` of the remaining bytes, fewer at the end of input.
    pub fn take(g: *ByteGen, n: usize) []const u8 {
        const start = @min(g.pos, g.bytes.len);
        const end = start + @min(n, g.bytes.len - start);
        g.pos = end;
        return g.bytes[start..end];
    }

    /// A slice whose length is drawn from `[0, max_len]`.
    pub fn slice(g: *ByteGen, max_len: usize) []const u8 {
        return g.take(g.intRange(usize, 0, max_len));
    }

    /// One of `options`.
    pub fn pick(g: *ByteGen, comptime T: type, options: []const T) T {
        return options[g.intRange(usize, 0, options.len - 1)];
    }

    pub fn rest(g: *ByteGen) []const u8 {
        return g.take(g.bytes.len);
    }

    /// Valid UTF-8 of at most `@min(max_len, out.len)` bytes, weighted toward
    /// what JSON must escape and toward every sequence length.
    pub fn utf8(g: *ByteGen, out: []u8, max_len: usize) []const u8 {
        const target = g.intRange(usize, 0, @min(max_len, out.len));
        var len: usize = 0;
        while (len < target) {
            const cp: u21 = switch (g.intRange(u8, 0, 7)) {
                0 => g.intRange(u21, 0, 0x1f),
                1 => g.pick(u21, &.{ '"', '\\', '/', 0x7f }),
                2, 3 => g.intRange(u21, 0x20, 0x7e),
                4 => g.intRange(u21, 0x80, 0x7ff),
                5 => g.intRange(u21, 0x800, 0xd7ff),
                6 => g.intRange(u21, 0xe000, 0xffff),
                else => g.intRange(u21, 0x10000, 0x10ffff),
            };
            const n = std.unicode.utf8CodepointSequenceLength(cp) catch unreachable;
            if (len + n > target) break;
            _ = std.unicode.utf8Encode(cp, out[len..]) catch unreachable;
            len += n;
        }
        return out[0..len];
    }
};

/// The longest input a property sees under the coverage-guided fuzzer.
pub const max_fuzz_input = 4096;

pub const FuzzOptions = struct {
    /// Inputs that always run. Add every input the fuzzer finds a bug with,
    /// so the fix stays covered.
    corpus: []const []const u8 = &.{},
    /// Pseudo-random inputs per run, from a fixed seed mixed with `--seed`.
    random_runs: u32 = 300,
    /// Longest pseudo-random input.
    max_len: u32 = 512,
};

/// Checks `property` against the corpus, then pseudo-random inputs, then hands
/// it to `std.testing.fuzz`. Under `zig build test --fuzz` that last step is
/// coverage-guided fuzzing; under `zig build test` it is one more smoke run.
pub fn fuzzBytes(
    context: anytype,
    comptime property: fn (@TypeOf(context), []const u8) anyerror!void,
    comptime options: FuzzOptions,
) !void {
    for (options.corpus) |input| {
        property(context, input) catch |err| {
            std.debug.print("property failed on corpus input {x}\n", .{input});
            return err;
        };
    }

    var prng: std.Random.DefaultPrng = .init(0x7075_6273_7562 ^ @as(u64, std.testing.random_seed));
    const random = prng.random();
    var buf: [max_fuzz_input]u8 = undefined;
    for (0..options.random_runs) |_| {
        const input = buf[0..random.uintAtMost(usize, @min(options.max_len, buf.len))];
        random.bytes(input);
        property(context, input) catch |err| {
            std.debug.print("property failed on input {x}\n", .{input});
            return err;
        };
    }

    const Adapter = struct {
        fn testOne(ctx: @TypeOf(context), smith: *std.testing.Smith) anyerror!void {
            var input: [max_fuzz_input]u8 = undefined;
            const n = smith.slice(&input);
            try property(ctx, input[0..n]);
        }
    };
    // The fuzzer reads slices as a little-endian u32 length and then the bytes.
    const seeds = comptime s: {
        var list: [options.corpus.len][]const u8 = undefined;
        for (options.corpus, &list) |input, *seed| {
            const len_le = std.mem.toBytes(std.mem.nativeToLittle(u32, input.len));
            const joined = len_le ++ input[0..input.len].*;
            seed.* = &joined;
        }
        const final = list;
        break :s final;
    };
    try std.testing.fuzz(context, Adapter.testOne, .{ .corpus = &seeds });
}

test "FakeClock records sleeps and advances time" {
    var clock: FakeClock = .{};
    const io = clock.io();
    try io.sleep(.fromMilliseconds(150), .awake);
    try io.sleep(.fromMilliseconds(20), .awake);
    try std.testing.expectEqual(2, clock.sleep_count);
    try std.testing.expectEqual(150, clock.sleepMs(0));
    try std.testing.expectEqual(170 * std.time.ns_per_ms, std.Io.Clock.awake.now(io).nanoseconds);

    clock.cancel_sleep = true;
    try std.testing.expectError(error.Canceled, io.sleep(.fromMilliseconds(1), .awake));
}

test "FakeClock random is deterministic or pinned" {
    var a: FakeClock = .{};
    var b: FakeClock = .{};
    var x: [16]u8 = undefined;
    var y: [16]u8 = undefined;
    a.io().random(&x);
    b.io().random(&y);
    try std.testing.expectEqualSlices(u8, &x, &y);

    a.random_byte = 0xff;
    a.io().random(&x);
    try std.testing.expectEqualSlices(u8, &@as([16]u8, @splat(0xff)), &x);
}

test "ByteGen is total and in range" {
    var g: ByteGen = .init(&.{ 0xff, 0x01, 7 });
    try std.testing.expect(g.intRange(u8, 3, 5) >= 3);
    try std.testing.expectEqual(@as(u16, 0x0107), g.int(u16));
    try std.testing.expectEqual(@as(u32, 0), g.int(u32));
    try std.testing.expectEqualStrings("", g.slice(10));
    try std.testing.expectEqual(@as(u64, 9), g.intRange(u64, 9, 9));

    var full: ByteGen = .init(&.{ 1, 2, 3, 4, 5, 6, 7, 8 });
    _ = full.intRange(u64, 0, std.math.maxInt(u64));
}

fn utf8Property(_: void, input: []const u8) !void {
    var g: ByteGen = .init(input);
    var buf: [64]u8 = undefined;
    const max = g.intRange(usize, 0, 80);
    const s = g.utf8(&buf, max);
    try std.testing.expect(s.len <= @min(max, buf.len));
    try std.testing.expect(std.unicode.utf8ValidateSlice(s));
}

test "fuzz ByteGen.utf8 always yields valid UTF-8" {
    try fuzzBytes({}, utf8Property, .{ .corpus = &.{ "\x40\x07\xff\xff\xff\xff", "" } });
}

test "FakeTokenProvider returns its token or its error, and counts" {
    var fake: FakeTokenProvider = .{ .quota_project = "billing-project" };
    const p = fake.provider();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const token = try p.getToken(std.testing.io, arena.allocator(), &.{ "scope-a", "scope-b" });
    try std.testing.expectEqualStrings("ya29.fake-token", token);
    try std.testing.expect(token.ptr != fake.token.ptr);
    try std.testing.expectEqual(2, fake.scope_count);
    try std.testing.expectEqualStrings("scope-a", fake.firstScope());

    fake.fail = error.RefreshTokenInvalid;
    try std.testing.expectError(error.RefreshTokenInvalid, p.getToken(std.testing.io, arena.allocator(), &.{}));
    try std.testing.expectEqual(0, fake.scope_count);
    try std.testing.expectEqualStrings("", fake.firstScope());

    p.invalidate();
    try std.testing.expectEqual(2, fake.calls);
    try std.testing.expectEqual(1, fake.invalidations);
    try std.testing.expectEqualStrings("billing-project", p.quotaProject().?);

    // A scope longer than the buffer is truncated, not overflowed.
    const long: [200]u8 = @splat('s');
    _ = p.getToken(std.testing.io, arena.allocator(), &.{&long}) catch {};
    try std.testing.expectEqual(128, fake.firstScope().len);
}

test "FakeTransport records requests and replays the script" {
    var fake: FakeTransport = .init(std.testing.allocator, &.{
        .{ .respond = .{ .status = 503, .body = "{}" } },
        .{ .fail = error.ConnectionResetByPeer },
    });
    defer fake.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const t = fake.transport();
    const first = try t.send(.{ .method = .GET, .url = "http://x/v1/a" }, arena.allocator());
    try std.testing.expectEqual(503, first.status);
    try std.testing.expectError(
        error.ConnectionResetByPeer,
        t.send(.{ .method = .POST, .url = "http://x/v1/b", .body = "{}" }, arena.allocator()),
    );
    // The script is exhausted: extra requests fail loudly.
    try std.testing.expectError(
        error.HttpProtocolError,
        t.send(.{ .method = .DELETE, .url = "http://x/v1/c" }, arena.allocator()),
    );
    try std.testing.expectEqual(3, fake.requests.items.len);
    try std.testing.expectEqualStrings("{}", (try fake.request(1)).body.?);
}
