//! Integration tests against real Cloud Storage: what an emulator cannot be
//! trusted on. They need a bucket and a token:
//!
//!     GCP_TEST_BUCKET=my-test-bucket \
//!     GCP_TEST_TOKEN=$(gcloud auth application-default print-access-token) \
//!     zig build test-integration-gcp
//!
//! Without both, every test skips. Each test keeps its objects under a
//! prefix of its own, `zig-gcp-test/<random>/`, and deletes that prefix when
//! it ends, even when it fails; the last test sweeps up anything under
//! `zig-gcp-test/` that a crashed run left more than a day ago. The
//! principal needs Storage Object Admin on the bucket and nothing more. The
//! bucket must not keep noncurrent versions (object versioning off), or an
//! overwritten generation stays readable and the pinning test cannot see
//! the overwrite.
//!
//! An upload with conditions finishes under the bucket's `zig-gcp-tmp/`
//! before it moves into place; the tests check that nothing is left
//! there, and the sweep clears anything a crashed run left more than a day
//! ago.
//!
//! The largest tests move 1 GiB up twice, and 1 GiB up and twice down,
//! and print the throughput; the suite as a whole moves about 5.4 GiB over
//! the wire, and its copies are server-side. One copy is stored as
//! NEARLINE, whose 30-day minimum is billed on delete: about a tenth of a
//! cent.
//!
//! Faults come from `core.testing.FaultTransport` around the real HTTP
//! transport: it closes real connections partway through real bodies, so
//! every recovery here is a recovery against Google.

const std = @import("std");
const core = @import("core");
const storage = @import("storage");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const FaultTransport = core.testing.FaultTransport;

const Fixture = struct {
    env: std.process.Environ.Map,
    token: storage.StaticToken,
    diag: storage.Diagnostics,
    http: core.transport.HttpTransport,
    faults: FaultTransport,
    client: storage.Client,
    arena: std.heap.ArenaAllocator,
    /// Borrowed from `env`.
    bucket_name: []const u8,
    /// "zig-gcp-test/" plus 8 random hex digits and a slash, unique per test.
    prefix: [22]u8,

    const Options = struct {
        chunk_size: usize = 8 * 1024 * 1024,
        single_request_limit: usize = 8 * 1024 * 1024,
        verify_checksums: bool = true,
        /// Faults for the client's transport to inject.
        plan: []FaultTransport.Fault = &.{},
        /// Record every exchange in `faults.exchanges`.
        record: bool = false,
        /// Everything the client and its transport allocate, which a test
        /// can measure. The fixture's own bookkeeping stays out of it.
        gpa: ?Allocator = null,
    };

    /// Returns false when no bucket is configured; the test should skip.
    fn init(f: *Fixture, options: Options) !bool {
        const gpa = testing.allocator;
        f.env = try testing.environ.createMap(gpa);
        errdefer f.env.deinit();
        const bucket_name = f.env.get("GCP_TEST_BUCKET") orelse return f.skip();
        const token = f.env.get("GCP_TEST_TOKEN") orelse return f.skip();
        f.bucket_name = std.mem.trim(u8, bucket_name, &std.ascii.whitespace);
        f.token = .{ .token = std.mem.trim(u8, token, &std.ascii.whitespace) };
        f.diag = .{};
        f.arena = .init(gpa);
        errdefer f.arena.deinit();
        var random: [4]u8 = undefined;
        testing.io.random(&random);
        _ = try std.fmt.bufPrint(&f.prefix, "zig-gcp-test/{x}/", .{random});

        const client_gpa = options.gpa orelse gpa;
        f.http = .init(client_gpa, testing.io, user_agent);
        errdefer f.http.deinit();
        f.faults = .{
            .inner = f.http.transport(),
            .plan = options.plan,
            .record = if (options.record) gpa else null,
        };
        errdefer f.faults.deinit();
        f.client = try .init(client_gpa, testing.io, .{
            .token_provider = f.token.provider(),
            .transport = f.faults.transport(),
            .diagnostics = &f.diag,
            .chunk_size = options.chunk_size,
            .single_request_limit = options.single_request_limit,
            .verify_checksums = options.verify_checksums,
            // A slow link moves an 8 MiB chunk slowly; a hang still ends.
            .request_timeout_ms = 120_000,
            .user_agent = user_agent,
        });
        return true;
    }

    const user_agent = "zig-gcp-storage-gcp-integration/0.1";

    fn skip(f: *Fixture) bool {
        f.env.deinit();
        return false;
    }

    /// Deletes everything under the test's prefix, then frees the fixture.
    fn deinit(f: *Fixture) void {
        // Cleanup must not trip over a fault a failed test never reached.
        f.faults.plan = &.{};
        const b = f.bucket();
        var token: ?[]const u8 = null;
        for (0..100) |_| {
            var page = b.listObjects(.{ .prefix = &f.prefix, .page_token = token }) catch break;
            defer page.deinit();
            for (page.value.objects) |info| {
                b.object(info.name).delete(.{ .generation = info.generation }) catch |err| {
                    std.debug.print("cleanup: could not delete {s}: {t}\n", .{ info.name, err });
                };
            }
            const next = page.value.next_page_token orelse break;
            token = f.arena.allocator().dupe(u8, next) catch break;
        }
        f.client.deinit();
        f.faults.deinit();
        f.http.deinit();
        f.arena.deinit();
        f.env.deinit();
    }

    fn bucket(f: *Fixture) storage.Bucket {
        return f.client.bucket(f.bucket_name);
    }

    /// A handle on `what` under the test's prefix.
    fn object(f: *Fixture, what: []const u8) !storage.Object {
        const name = try std.fmt.allocPrint(f.arena.allocator(), "{s}{s}", .{ &f.prefix, what });
        return f.bucket().object(name);
    }

    /// Prints the server's own words when a call fails unexpectedly.
    fn report(f: *const Fixture, err: anyerror) anyerror {
        std.debug.print("error.{t}", .{err});
        if (f.diag.http_status != 0) std.debug.print(" (HTTP {d} {s})", .{ f.diag.http_status, f.diag.status() });
        if (f.diag.message().len != 0) std.debug.print(": {s}", .{f.diag.message()});
        std.debug.print("\n", .{});
        return err;
    }

    /// The object holds exactly `expected`, and the download verified it.
    fn expectContent(f: *Fixture, obj: storage.Object, expected: []const u8) !void {
        var got = obj.downloadAlloc(expected.len + 1, .{}) catch |err| return f.report(err);
        defer got.deinit();
        try testing.expectEqualSlices(u8, expected, got.value.data);
        try testing.expect(got.value.result.checksum_verified);
    }

    /// The index of the exchange the plan's fault `index` fired on.
    fn faulted(f: *const Fixture, index: usize) !usize {
        for (f.faults.exchanges.items, 0..) |e, i| {
            if (e.fault == index) return i;
        }
        std.debug.print("fault {d} never fired\n", .{index});
        return error.TestExpectedFault;
    }

    /// The exchange after `index`, failing the test when there is none.
    fn after(f: *const Fixture, index: usize) !FaultTransport.Exchange {
        if (index + 1 >= f.faults.exchanges.items.len) {
            std.debug.print("expected an exchange after {d}, saw {d} in all\n", .{ index, f.faults.exchanges.items.len });
            return error.TestExpectedExchange;
        }
        return f.faults.exchanges.items[index + 1];
    }
};

/// Deterministic bytes that never repeat with a short period, so a resume
/// at the wrong offset changes the checksum instead of hiding in a cycle.
fn patternByte(seed: u64, i: u64) u8 {
    return @truncate((i +% seed *% 0x1_0000_0001) *% 0x9e37_79b9_7f4a_7c15 >> 56);
}

fn pattern(gpa: Allocator, seed: u64, n: usize) ![]u8 {
    const data = try gpa.alloc(u8, n);
    for (data, 0..) |*b, i| b.* = patternByte(seed, i);
    return data;
}

fn patternCrc(seed: u64, n: u64) u32 {
    var hasher: core.crc32c.Hasher = .init();
    var block: [4096]u8 = undefined;
    var i: u64 = 0;
    while (i < n) {
        const len: usize = @intCast(@min(block.len, n - i));
        for (block[0..len], 0..) |*b, k| b.* = patternByte(seed, i + k);
        hasher.update(block[0..len]);
        i += len;
    }
    return hasher.final();
}

/// A reader that makes up its bytes as they are read, so a test can upload
/// 100 MiB without holding 100 MiB.
const PatternReader = struct {
    seed: u64,
    size: u64,
    position: u64 = 0,
    interface: std.Io.Reader,

    fn init(seed: u64, size: u64) PatternReader {
        return .{ .seed = seed, .size = size, .interface = .{
            .vtable = &.{ .stream = stream },
            .buffer = &.{},
            .seek = 0,
            .end = 0,
        } };
    }

    fn stream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *PatternReader = @alignCast(@fieldParentPtr("interface", r));
        if (self.position == self.size) return error.EndOfStream;
        var block: [4096]u8 = undefined;
        const want: usize = @intCast(@min(block.len, self.size - self.position));
        for (block[0..want], 0..) |*b, k| b.* = patternByte(self.seed, self.position + k);
        const n = try w.write(limit.sliceConst(block[0..want]));
        self.position += n;
        return n;
    }
};

/// A writer that keeps nothing: it hashes what it is given, unbuffered.
fn hashingSink() std.Io.Writer.Hashing(core.crc32c.Hasher) {
    return .initHasher(.init(), &.{});
}

/// Counts live bytes through to a child allocator, so a test can assert that
/// memory stays flat while an object streams. Atomic, because a request with
/// a timeout runs on a task of its own.
const PeakAllocator = struct {
    child: Allocator,
    live: std.atomic.Value(usize) = .init(0),
    peak: std.atomic.Value(usize) = .init(0),
    /// What was live when the current measurement began.
    base: usize = 0,

    fn allocator(self: *PeakAllocator) Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    /// Starts a new measurement from what is held now.
    fn reset(self: *PeakAllocator) void {
        self.base = self.live.load(.monotonic);
        self.peak.store(self.base, .monotonic);
    }

    /// The most held at once since `reset`, beyond what was held then.
    fn growth(self: *const PeakAllocator) usize {
        return self.peak.load(.monotonic) -| self.base;
    }

    fn grew(self: *PeakAllocator, n: usize) void {
        const now = self.live.fetchAdd(n, .monotonic) + n;
        var seen = self.peak.load(.monotonic);
        while (now > seen) seen = self.peak.cmpxchgWeak(seen, now, .monotonic, .monotonic) orelse break;
    }

    fn shrank(self: *PeakAllocator, n: usize) void {
        _ = self.live.fetchSub(n, .monotonic);
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *PeakAllocator = @ptrCast(@alignCast(ctx));
        const out = self.child.vtable.alloc(self.child.ptr, len, alignment, ret_addr) orelse return null;
        self.grew(len);
        return out;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *PeakAllocator = @ptrCast(@alignCast(ctx));
        if (!self.child.vtable.resize(self.child.ptr, memory, alignment, new_len, ret_addr)) return false;
        if (new_len > memory.len) self.grew(new_len - memory.len) else self.shrank(memory.len - new_len);
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *PeakAllocator = @ptrCast(@alignCast(ctx));
        const out = self.child.vtable.remap(self.child.ptr, memory, alignment, new_len, ret_addr) orelse return null;
        if (new_len > memory.len) self.grew(new_len - memory.len) else self.shrank(memory.len - new_len);
        return out;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *PeakAllocator = @ptrCast(@alignCast(ctx));
        self.child.vtable.free(self.child.ptr, memory, alignment, ret_addr);
        self.shrank(memory.len);
    }
};

/// Milliseconds since `started`, on the monotonic clock.
fn msSince(started: std.Io.Timestamp) i64 {
    return started.durationTo(std.Io.Clock.awake.now(testing.io)).toMilliseconds();
}

fn mibPerSecond(bytes: u64, ms: i64) f64 {
    const seconds = @as(f64, @floatFromInt(@max(ms, 1))) / 1000.0;
    return @as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0) / seconds;
}

/// How many bytes a 308's `Range: bytes=0-N` says were kept: N+1, or 0
/// without the header.
fn keptFromRange(value: ?[]const u8) !u64 {
    const text = value orelse return 0;
    const dash = std.mem.lastIndexOfScalar(u8, text, '-') orelse return error.TestUnexpectedRange;
    return 1 + try std.fmt.parseInt(u64, text[dash + 1 ..], 10);
}

test "1. preconditions: create-only once, a stale generation refused, the current one accepted" {
    var f: Fixture = undefined;
    if (!try f.init(.{})) return error.SkipZigTest;
    defer f.deinit();
    const obj = try f.object("preconditions.txt");

    // Create-only succeeds once, then fails its precondition.
    var first = obj.upload("one", .{ .content_type = "text/plain", .preconditions = .does_not_exist }) catch |err| return f.report(err);
    defer first.deinit();
    const gen1 = first.value.generation;
    try testing.expectError(error.FailedPrecondition, obj.upload("two", .{ .preconditions = .does_not_exist }));
    try testing.expectEqual(412, f.diag.http_status);

    // The current generation is what a conditional overwrite needs.
    var second = obj.upload("two", .{ .preconditions = .{ .if_generation_match = gen1 } }) catch |err| return f.report(err);
    defer second.deinit();
    const gen2 = second.value.generation;
    try testing.expect(gen2 != gen1);
    // A stale one is refused, on both upload protocols, and nothing lands.
    try testing.expectError(error.FailedPrecondition, obj.upload("three", .{ .preconditions = .{ .if_generation_match = gen1 } }));
    try testing.expectEqual(412, f.diag.http_status);
    var stale_reader: std.Io.Reader = .fixed("four");
    try testing.expectError(error.FailedPrecondition, obj.uploadFrom(&stale_reader, .{ .preconditions = .{ .if_generation_match = gen1 } }));
    try f.expectContent(obj, "two");

    // Reads: a stale match is 412 with the JSON API's reason; a not-match
    // against what is live is 304, an answer rather than a failure.
    try testing.expectError(error.FailedPrecondition, obj.get(.{ .preconditions = .{ .if_generation_match = gen1 } }));
    try testing.expectEqual(412, f.diag.http_status);
    try testing.expectEqualStrings("conditionNotMet", f.diag.status());
    try testing.expectError(error.NotModified, obj.get(.{ .preconditions = .{ .if_generation_not_match = gen2 } }));
    try testing.expectEqual(304, f.diag.http_status);
    try testing.expectError(error.NotModified, obj.get(.{ .preconditions = .{ .if_metageneration_not_match = second.value.metageneration } }));
    var info = obj.get(.{ .preconditions = .{ .if_metageneration_match = second.value.metageneration } }) catch |err| return f.report(err);
    info.deinit();

    // Downloads answer the same way; a 304 leaves the writer untouched.
    var out_buf: [16]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    try testing.expectError(error.NotModified, obj.download(&out, .{ .preconditions = .{ .if_generation_not_match = gen2 } }));
    try testing.expectEqual(0, out.buffered().len);
    try testing.expectError(error.FailedPrecondition, obj.download(&out, .{ .preconditions = .{ .if_generation_match = gen1 } }));
    try testing.expectEqual(0, out.buffered().len);

    // Deletes, which the emulator does not police: a stale generation is
    // refused, an overwritten one is simply gone, the current one goes.
    try testing.expectError(error.FailedPrecondition, obj.delete(.{ .preconditions = .{ .if_generation_match = gen1 } }));
    try testing.expectEqual(412, f.diag.http_status);
    try testing.expectError(error.NotFound, obj.delete(.{ .generation = gen1 }));
    obj.delete(.{ .preconditions = .{ .if_generation_match = gen2 } }) catch |err| return f.report(err);
    try testing.expect(!try obj.exists());
}

test "a lost answer: a create-only upload retries into its own precondition; an unconditional one never retries" {
    var plan = [_]FaultTransport.Fault{.{
        .method = .POST,
        .url_contains = "uploadType=multipart",
        .action = .lose_response,
    }};
    var f: Fixture = undefined;
    if (!try f.init(.{ .plan = &plan, .record = true })) return error.SkipZigTest;
    defer f.deinit();
    const obj = try f.object("lost-answer.txt");

    // The first attempt lands and its answer is lost. The condition makes a
    // retry safe, and the retry fails it against the object the first
    // attempt created: the ambiguity the diagnostics spell out.
    try testing.expectError(error.FailedPrecondition, obj.upload("landed", .{ .preconditions = .does_not_exist }));
    try testing.expect(plan[0].fired);
    try testing.expectEqual(412, f.diag.http_status);
    try testing.expect(std.mem.indexOf(u8, f.diag.message(), "an earlier attempt may have succeeded") != null);
    try testing.expectEqual(2, f.faults.exchanges.items.len);
    // It had.
    try f.expectContent(obj, "landed");

    // Without a condition the lost answer is final: one attempt, and the
    // caller hears of the dropped connection while the write stands.
    var plan2 = [_]FaultTransport.Fault{.{
        .method = .POST,
        .url_contains = "uploadType=multipart",
        .action = .lose_response,
    }};
    var g: Fixture = undefined;
    if (!try g.init(.{ .plan = &plan2, .record = true })) return error.SkipZigTest;
    defer g.deinit();
    const once = try g.object("once.txt");
    try testing.expectError(error.ConnectionResetByPeer, once.upload("once", .{}));
    try testing.expect(plan2[0].fired);
    try testing.expectEqual(1, g.faults.exchanges.items.len);
    try g.expectContent(once, "once");
}

test "2. server-side validation: a wrong declared crc32c is refused with 400, and nothing is stored" {
    // The test-only hook is verification turned off: the client then sends
    // a checksum it was told without checking it first, and only the server
    // can catch the lie. uploadFrom never checks a declared checksum.
    var f: Fixture = undefined;
    if (!try f.init(.{
        .verify_checksums = false,
        .chunk_size = 256 * 1024,
        .single_request_limit = 256 * 1024,
    })) return error.SkipZigTest;
    defer f.deinit();
    const gpa = testing.allocator;
    const data = "hello world\n";

    // One multipart request.
    const small = try f.object("wrong-crc-multipart.txt");
    try testing.expectError(error.InvalidArgument, small.upload(data, .{ .crc32c = core.crc32c.hash(data) ^ 1 }));
    try testing.expectEqual(400, f.diag.http_status);
    std.debug.print("multipart, wrong crc32c: HTTP 400 \"{s}\"\n", .{f.diag.message()});
    try testing.expect(!try small.exists());

    // The resumable protocol, from memory: the server checks once the last
    // chunk is in.
    const payload = try pattern(gpa, 2, 600 * 1024);
    defer gpa.free(payload);
    const large = try f.object("wrong-crc-resumable.bin");
    try testing.expectError(error.InvalidArgument, large.upload(payload, .{ .crc32c = core.crc32c.hash(payload) ^ 1 }));
    try testing.expectEqual(400, f.diag.http_status);
    std.debug.print("resumable, wrong crc32c: HTTP 400 \"{s}\"\n", .{f.diag.message()});
    try testing.expect(!try large.exists());

    // And from a reader.
    const streamed = try f.object("wrong-crc-reader.bin");
    var reader: std.Io.Reader = .fixed(payload);
    try testing.expectError(error.InvalidArgument, streamed.uploadFrom(&reader, .{ .crc32c = core.crc32c.hash(payload) ^ 1 }));
    try testing.expectEqual(400, f.diag.http_status);
    try testing.expect(!try streamed.exists());

    // The right checksum passes on every path.
    var ok_small = small.upload(data, .{ .crc32c = core.crc32c.hash(data) }) catch |err| return f.report(err);
    ok_small.deinit();
    var ok_large = large.upload(payload, .{ .crc32c = core.crc32c.hash(payload) }) catch |err| return f.report(err);
    ok_large.deinit();
    reader = .fixed(payload);
    var ok_streamed = streamed.uploadFrom(&reader, .{ .crc32c = core.crc32c.hash(payload) }) catch |err| return f.report(err);
    defer ok_streamed.deinit();
    try testing.expectEqual(core.crc32c.hash(payload), ok_streamed.value.crc32c.?);
}

test "3. downloads carry x-goog-hash and x-goog-generation, and verify against them" {
    var f: Fixture = undefined;
    if (!try f.init(.{ .record = true })) return error.SkipZigTest;
    defer f.deinit();
    const gpa = testing.allocator;
    const data = try pattern(gpa, 3, 1024 * 1024);
    defer gpa.free(data);
    const obj = try f.object("hashed.bin");
    var info = obj.upload(data, .{}) catch |err| return f.report(err);
    defer info.deinit();
    try testing.expectEqual(core.crc32c.hash(data), info.value.crc32c.?);

    const whole = f.faults.exchanges.items.len;
    var got = obj.downloadAlloc(data.len, .{}) catch |err| return f.report(err);
    defer got.deinit();
    try testing.expectEqualSlices(u8, data, got.value.data);
    try testing.expect(got.value.result.checksum_verified);
    try testing.expectEqual(info.value.generation, got.value.result.generation);

    // What the server sent, as it came over the wire.
    const exchange = f.faults.exchanges.items[whole];
    try testing.expectEqual(200, exchange.status.?);
    const crc_text = core.crc32c.toBase64(info.value.crc32c.?);
    const hash = exchange.responseHeader("x-goog-hash") orelse return error.TestExpectedHashHeader;
    try testing.expect(std.mem.indexOf(u8, hash, &crc_text) != null);
    var generation_buf: [24]u8 = undefined;
    const generation_text = try std.fmt.bufPrint(&generation_buf, "{d}", .{info.value.generation});
    try testing.expectEqualStrings(generation_text, exchange.responseHeader("x-goog-generation").?);

    // A range names the object's checksum only when it spans the whole
    // object; any shorter range, from byte 0 or later, names none. That is
    // why a resumed download is held to the checksum of the response its
    // bytes began with.
    const ranges = f.faults.exchanges.items.len;
    var head = obj.downloadAlloc(16, .{ .range = .{ .offset = 0, .length = 10 } }) catch |err| return f.report(err);
    head.deinit();
    var tail = obj.downloadAlloc(16, .{ .range = .{ .offset = 1000, .length = 10 } }) catch |err| return f.report(err);
    tail.deinit();
    var all = obj.downloadAlloc(data.len, .{ .range = .{ .offset = 0 } }) catch |err| return f.report(err);
    all.deinit();
    for (f.faults.exchanges.items[ranges..][0..3]) |e| try testing.expectEqual(206, e.status.?);
    try testing.expectEqual(null, f.faults.exchanges.items[ranges].responseHeader("x-goog-hash"));
    try testing.expectEqual(null, f.faults.exchanges.items[ranges + 1].responseHeader("x-goog-hash"));
    const whole_range_hash = f.faults.exchanges.items[ranges + 2].responseHeader("x-goog-hash") orelse return error.TestExpectedHashHeader;
    try testing.expect(std.mem.indexOf(u8, whole_range_hash, &crc_text) != null);

    // A zero-byte object verifies against the empty checksum.
    const empty = try f.object("empty.bin");
    var nothing = empty.upload("", .{}) catch |err| return f.report(err);
    nothing.deinit();
    try f.expectContent(empty, "");
}

test "4. a gzip-encoded object is decompressed in transit and reports checksum_verified = false" {
    var f: Fixture = undefined;
    if (!try f.init(.{ .record = true })) return error.SkipZigTest;
    defer f.deinit();
    const gpa = testing.allocator;

    // Text that compresses, so the stored bytes and the served bytes differ.
    var text: std.Io.Writer.Allocating = .init(gpa);
    defer text.deinit();
    for (0..2000) |i| try text.writer.print("line {d}: the quick brown fox jumps over the lazy dog\n", .{i});
    const plain = text.written();
    const gz = try gzip(gpa, plain);
    defer gpa.free(gz);
    try testing.expect(gz.len < plain.len);
    // The fixture itself is sound: it decompresses to the text.
    const check = try gunzip(gpa, gz);
    defer gpa.free(check);
    try testing.expectEqualStrings(plain, check);

    const obj = try f.object("transcoded.txt");
    var info = obj.upload(gz, .{ .content_type = "text/plain", .content_encoding = "gzip" }) catch |err| return f.report(err);
    defer info.deinit();
    try testing.expectEqual(gz.len, info.value.size);
    try testing.expectEqual(core.crc32c.hash(gz), info.value.crc32c.?);

    const served = f.faults.exchanges.items.len;
    var got = obj.downloadAlloc(plain.len + 1, .{}) catch |err| return f.report(err);
    defer got.deinit();
    // The client asked for plain bytes, so Cloud Storage decompressed them,
    // and the stored checksum, over the compressed bytes, cannot apply.
    try testing.expectEqualStrings(plain, got.value.data);
    try testing.expect(!got.value.result.checksum_verified);
    const exchange = f.faults.exchanges.items[served];
    try testing.expectEqualStrings("gzip", exchange.responseHeader("x-goog-stored-content-encoding").?);
    if (exchange.responseHeader("content-encoding")) |sent| try testing.expectEqualStrings("identity", sent);
    std.debug.print("transcoded: {d} bytes stored, {d} served\n", .{ gz.len, got.value.data.len });
}

fn gzip(gpa: Allocator, data: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = try .initCapacity(gpa, 4096);
    errdefer out.deinit();
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var compress: std.compress.flate.Compress = try .init(&out.writer, &window, .gzip, .default);
    try compress.writer.writeAll(data);
    try compress.finish();
    return out.toOwnedSlice();
}

fn gunzip(gpa: Allocator, data: []const u8) ![]u8 {
    var in: std.Io.Reader = .fixed(data);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var decompress: std.compress.flate.Decompress = .init(&in, .gzip, &window);
    return decompress.reader.allocRemaining(gpa, .unlimited);
}

test "5. resume for real: an upload cut mid-chunk and a download cut mid-body both recover and verify" {
    const size = 3 * 1024 * 1024 + 512 * 1024;
    const chunk = 1024 * 1024;
    const expected_crc = patternCrc(5, size);
    var plan = [_]FaultTransport.Fault{
        // The second chunk stops 600 KiB in.
        .{ .method = .PUT, .url_contains = "upload_id=", .skip = 1, .action = .{ .cut_request_body = 600 * 1024 } },
        // The download stops just short of a megabyte, at no boundary.
        .{ .method = .GET, .url_contains = "alt=media", .action = .{ .cut_response_body = 1_000_003 } },
    };
    var f: Fixture = undefined;
    if (!try f.init(.{ .chunk_size = chunk, .single_request_limit = 256 * 1024, .plan = &plan, .record = true })) return error.SkipZigTest;
    defer f.deinit();
    const obj = try f.object("resumed.bin");

    var source: PatternReader = .init(5, size);
    var info = obj.uploadFrom(&source.interface, .{ .size = size }) catch |err| return f.report(err);
    defer info.deinit();
    try testing.expect(plan[0].fired);
    try testing.expectEqual(size, info.value.size);
    try testing.expectEqual(expected_crc, info.value.crc32c.?);

    // After the cut a status query asked what the server kept, and the next
    // chunk began exactly there.
    const cut = try f.faulted(0);
    const query = try f.after(cut);
    try testing.expectEqual(.PUT, query.method);
    try testing.expectEqual(0, query.body_len);
    try testing.expectEqualStrings("bytes */3670016", query.header("Content-Range").?);
    try testing.expectEqual(308, query.status.?);
    const kept = try keptFromRange(query.responseHeader("Range"));
    try testing.expect(kept >= chunk and kept < 2 * chunk);
    const resumed = try f.after(cut + 1);
    var range_buf: [64]u8 = undefined;
    const resumed_from = try std.fmt.bufPrint(&range_buf, "bytes {d}-", .{kept});
    try testing.expect(std.mem.startsWith(u8, resumed.header("Content-Range").?, resumed_from));
    std.debug.print("upload: cut 600 KiB into the second chunk; the server had kept {d} bytes, and sending resumed there\n", .{kept});

    // The download: cut, resumed from the byte it stopped at, pinned to the
    // generation the first response named, and verified end to end.
    var sink = hashingSink();
    const result = obj.download(&sink.writer, .{}) catch |err| return f.report(err);
    try testing.expect(plan[1].fired);
    try testing.expectEqual(size, result.bytes_written);
    try testing.expectEqual(expected_crc, sink.hasher.final());
    try testing.expect(result.checksum_verified);
    try testing.expectEqual(info.value.generation, result.generation);
    const resumed_get = try f.after(try f.faulted(1));
    try testing.expectEqualStrings("bytes=1000003-", resumed_get.header("Range").?);
    var generation_buf: [48]u8 = undefined;
    const pinned = try std.fmt.bufPrint(&generation_buf, "generation={d}", .{info.value.generation});
    try testing.expect(std.mem.indexOf(u8, resumed_get.url, pinned) != null);
    try testing.expectEqual(206, resumed_get.status.?);
    std.debug.print("download: cut at byte 1000003, resumed with a 206 that {s} x-goog-hash\n", .{
        if (resumed_get.responseHeader("x-goog-hash") != null) "carried" else "carried no",
    });

    // The same cut in an upload of unknown size, whose status query cannot
    // name a total.
    var plan2 = [_]FaultTransport.Fault{
        .{ .method = .PUT, .url_contains = "upload_id=", .skip = 2, .action = .{ .cut_request_body = 300 * 1024 } },
    };
    var g: Fixture = undefined;
    if (!try g.init(.{ .chunk_size = chunk, .single_request_limit = 256 * 1024, .plan = &plan2, .record = true })) return error.SkipZigTest;
    defer g.deinit();
    var unsized_source: PatternReader = .init(5, size);
    var unsized = (try g.object("resumed-unsized.bin")).uploadFrom(&unsized_source.interface, .{}) catch |err| return g.report(err);
    defer unsized.deinit();
    try testing.expect(plan2[0].fired);
    try testing.expectEqual(size, unsized.value.size);
    try testing.expectEqual(expected_crc, unsized.value.crc32c.?);
    const unsized_query = try g.after(try g.faulted(0));
    try testing.expectEqualStrings("bytes */*", unsized_query.header("Content-Range").?);
    try testing.expectEqual(308, unsized_query.status.?);
}

test "6 and 7. 100 MiB up and down in flat memory, then copied through the rewrite loop" {
    const size = 100 * 1024 * 1024;
    const expected_crc = patternCrc(6, size);
    var peak: PeakAllocator = .{ .child = testing.allocator };
    var f: Fixture = undefined;
    if (!try f.init(.{ .gpa = peak.allocator(), .record = true })) return error.SkipZigTest;
    defer f.deinit();
    const obj = try f.object("big.bin");

    // A first request opens the connection and loads the CA bundle, which
    // are held from then on whatever the transfer, so the measurements
    // below start after them.
    try testing.expect(!(obj.exists() catch |err| return f.report(err)));

    // 6. Up from a reader that holds nothing, through the default 8 MiB
    // chunks: one chunk buffer, plus what a connection needs.
    var source: PatternReader = .init(6, size);
    peak.reset();
    const up_started = std.Io.Clock.awake.now(testing.io);
    var info = obj.uploadFrom(&source.interface, .{ .size = size }) catch |err| return f.report(err);
    defer info.deinit();
    const up_ms = msSince(up_started);
    const up_growth = peak.growth();
    try testing.expectEqual(size, info.value.size);
    try testing.expectEqual(expected_crc, info.value.crc32c.?);
    std.debug.print("uploadFrom: 100 MiB in {d} ms, {d:.1} MiB/s, at most {d} KiB held beyond the start\n", .{
        up_ms, mibPerSecond(size, up_ms), up_growth / 1024,
    });
    try testing.expect(up_growth < f.client.chunk_size + 1024 * 1024);

    // Down into a writer that keeps nothing: memory stays flat.
    var sink = hashingSink();
    peak.reset();
    const down_started = std.Io.Clock.awake.now(testing.io);
    const result = obj.download(&sink.writer, .{}) catch |err| return f.report(err);
    const down_ms = msSince(down_started);
    const down_growth = peak.growth();
    try testing.expectEqual(size, result.bytes_written);
    try testing.expect(result.checksum_verified);
    try testing.expectEqual(expected_crc, sink.hasher.final());
    std.debug.print("download: 100 MiB in {d} ms, {d:.1} MiB/s, at most {d} KiB held beyond the start\n", .{
        down_ms, mibPerSecond(size, down_ms), down_growth / 1024,
    });
    try testing.expect(down_growth < 1024 * 1024);

    // 7. A copy within one bucket and storage class moves no bytes: one
    // rewrite call, whatever the size.
    const plain_start = f.faults.exchanges.items.len;
    var copied = obj.copyTo(try f.object("big-copy.bin"), .{}) catch |err| return f.report(err);
    defer copied.deinit();
    try testing.expectEqual(size, copied.value.size);
    try testing.expectEqual(expected_crc, copied.value.crc32c.?);
    const plain_calls = rewriteCalls(f.faults.exchanges.items[plain_start..]);
    std.debug.print("copyTo, same storage class: {d} rewrite call(s)\n", .{plain_calls});
    try testing.expect(plain_calls >= 1);

    // A copy into another storage class rewrites the bytes, and with each
    // call capped at 16 MiB it takes several: the loop, token and all.
    var capper: RewriteCapper = .{
        .inner = f.faults.transport(),
        .max_bytes_per_call = 16 * 1024 * 1024,
        .storage_class = "NEARLINE",
    };
    var capped: storage.Client = try .init(testing.allocator, testing.io, .{
        .token_provider = f.token.provider(),
        .transport = capper.transport(),
        .diagnostics = &f.diag,
        .request_timeout_ms = 120_000,
        .user_agent = Fixture.user_agent,
    });
    defer capped.deinit();
    const src = capped.bucket(f.bucket_name).object(obj.name);
    const dest = capped.bucket(f.bucket_name).object((try f.object("big-nearline.bin")).name);
    const looped_start = f.faults.exchanges.items.len;
    const copy_started = std.Io.Clock.awake.now(testing.io);
    var moved = src.copyTo(dest, .{}) catch |err| return f.report(err);
    defer moved.deinit();
    const copy_ms = msSince(copy_started);
    const calls = f.faults.exchanges.items[looped_start..];
    const looped = rewriteCalls(calls);
    std.debug.print("copyTo, into NEARLINE at 16 MiB per call: {d} rewrite calls in {d} ms\n", .{ looped, copy_ms });
    try testing.expect(looped >= 2);
    // Every call after the first carried the token the one before returned.
    var seen: usize = 0;
    for (calls) |e| {
        if (!isRewrite(e)) continue;
        try testing.expectEqual(seen != 0, std.mem.indexOf(u8, e.url, "rewriteToken=") != null);
        seen += 1;
    }
    try testing.expectEqual(size, moved.value.size);
    try testing.expectEqual(expected_crc, moved.value.crc32c.?);
    try testing.expectEqualStrings("NEARLINE", moved.value.storage_class);
}

fn isRewrite(e: FaultTransport.Exchange) bool {
    return e.method == .POST and std.mem.indexOf(u8, e.url, "/rewriteTo/") != null;
}

fn rewriteCalls(exchanges: []const FaultTransport.Exchange) usize {
    var n: usize = 0;
    for (exchanges) |e| {
        if (isRewrite(e)) n += 1;
    }
    return n;
}

/// Turns each rewrite call into one that changes the destination's storage
/// class and moves at most `max_bytes_per_call`: the testing knob Google's
/// own clients keep for this, since a copy within one location and storage
/// class is a metadata operation that finishes in one call. Every call of a
/// rewrite must carry the same parameters, and each does.
const RewriteCapper = struct {
    inner: core.transport.Transport,
    max_bytes_per_call: u64,
    storage_class: []const u8,

    fn transport(self: *RewriteCapper) core.transport.Transport {
        return .{ .ptr = self, .vtable = &.{ .send = send, .sendStream = sendStream } };
    }

    fn send(ptr: *anyopaque, req: core.transport.Request, arena: Allocator) core.transport.Error!core.transport.Response {
        const self: *RewriteCapper = @ptrCast(@alignCast(ptr));
        if (req.method != .POST or std.mem.indexOf(u8, req.url, "/rewriteTo/") == null) return self.inner.send(req, arena);
        var capped = req;
        const separator: u8 = if (std.mem.indexOfScalar(u8, req.url, '?') == null) '?' else '&';
        capped.url = try std.fmt.allocPrint(arena, "{s}{c}maxBytesRewrittenPerCall={d}", .{ req.url, separator, self.max_bytes_per_call });
        capped.body = try std.fmt.allocPrint(arena, "{{\"storageClass\":\"{s}\"}}", .{self.storage_class});
        return self.inner.send(capped, arena);
    }

    fn sendStream(ptr: *anyopaque, req: core.transport.StreamRequest, arena: Allocator) core.transport.StreamError!core.transport.StreamResponse {
        const self: *RewriteCapper = @ptrCast(@alignCast(ptr));
        return self.inner.sendStream(req, arena);
    }
};

test "8. generation pinning: an overwrite between the halves of a resumed download is a clean NotFound" {
    const gpa = testing.allocator;
    const size = 1024 * 1024;
    const cut_at = 300_000;
    var plan = [_]FaultTransport.Fault{
        .{ .method = .GET, .url_contains = "alt=media", .action = .{ .cut_response_body = cut_at } },
    };
    var f: Fixture = undefined;
    if (!try f.init(.{ .plan = &plan, .record = true })) return error.SkipZigTest;
    defer f.deinit();
    const original = try pattern(gpa, 81, size);
    defer gpa.free(original);
    const replacement = try pattern(gpa, 82, size);
    defer gpa.free(replacement);
    const obj = try f.object("pinned.bin");
    var first = obj.upload(original, .{}) catch |err| return f.report(err);
    defer first.deinit();

    // Between the two halves, another writer, on a client of its own,
    // replaces the object.
    var other: storage.Client = try .init(gpa, testing.io, .{
        .token_provider = f.token.provider(),
        .user_agent = Fixture.user_agent,
    });
    defer other.deinit();
    var overwrite: Overwrite = .{ .object = other.bucket(f.bucket_name).object(obj.name), .data = replacement };
    f.faults.after_fault = .{ .context = &overwrite, .run = Overwrite.run };

    const got = try gpa.alloc(u8, size);
    defer gpa.free(got);
    var out: std.Io.Writer = .fixed(got);
    try testing.expectError(error.NotFound, obj.download(&out, .{}));
    try testing.expect(plan[0].fired);
    if (overwrite.err) |err| return err;
    try testing.expect(overwrite.generation != first.value.generation);
    try testing.expectEqual(404, f.diag.http_status);
    std.debug.print("resume after an overwrite: HTTP 404 \"{s}\"\n", .{f.diag.message()});
    // The writer holds the original's first bytes and nothing of the
    // replacement: two objects were never spliced.
    try testing.expectEqualSlices(u8, original[0..cut_at], out.buffered());
    // The resume asked for the old generation by number.
    const resumed = try f.after(try f.faulted(0));
    var pinned_buf: [48]u8 = undefined;
    const pinned = try std.fmt.bufPrint(&pinned_buf, "generation={d}", .{first.value.generation});
    try testing.expect(std.mem.indexOf(u8, resumed.url, pinned) != null);
    try testing.expectEqual(404, resumed.status.?);

    // A fresh download gets the replacement, whole and verified.
    var fresh = obj.downloadAlloc(size, .{}) catch |err| return f.report(err);
    defer fresh.deinit();
    try testing.expectEqualSlices(u8, replacement, fresh.value.data);
    try testing.expect(fresh.value.result.checksum_verified);
    try testing.expectEqual(overwrite.generation, fresh.value.result.generation);
}

/// Replaces an object from inside the fault transport's hook, on a client
/// of its own, between the two halves of a download.
const Overwrite = struct {
    object: storage.Object,
    data: []const u8,
    generation: u64 = 0,
    err: ?anyerror = null,

    fn run(context: *anyopaque, _: *const FaultTransport.Fault) void {
        const self: *Overwrite = @ptrCast(@alignCast(context));
        var info = self.object.upload(self.data, .{}) catch |err| {
            self.err = err;
            return;
        };
        defer info.deinit();
        self.generation = info.value.generation;
    }
};

test "9. patch: the fields come back, and only the keys it names change" {
    var f: Fixture = undefined;
    if (!try f.init(.{})) return error.SkipZigTest;
    defer f.deinit();
    const obj = try f.object("patched.txt");
    var first = obj.upload("hello\n", .{
        .content_type = "text/plain",
        .metadata = &.{ .{ .key = "reviewer", .value = "kim" }, .{ .key = "draft", .value = "yes" } },
    }) catch |err| return f.report(err);
    defer first.deinit();

    // A patch sets what it names and leaves the rest, which no
    // documentation states: measured here.
    var patched = obj.updateMetadata(.{
        .content_type = "text/markdown",
        .cache_control = "public, max-age=60",
        .edit = .{ .change = &.{.{ .key = "reviewer", .value = "sam" }} },
    }) catch |err| return f.report(err);
    defer patched.deinit();
    try testing.expectEqualStrings("text/markdown", patched.value.content_type);
    try testing.expectEqualStrings("public, max-age=60", patched.value.cache_control.?);
    try testing.expectEqualStrings("sam", patched.value.metadataValue("reviewer").?);
    try testing.expectEqualStrings("yes", patched.value.metadataValue("draft").?);

    // A patch writes metadata, not data: the generation stands still and
    // the metageneration moves.
    try testing.expectEqual(first.value.generation, patched.value.generation);
    try testing.expect(patched.value.metageneration > first.value.metageneration);
    try f.expectContent(obj, "hello\n");

    // A null value removes that key and only that key.
    var removed = obj.updateMetadata(.{
        .edit = .{ .change = &.{.{ .key = "draft", .value = null }} },
    }) catch |err| return f.report(err);
    defer removed.deinit();
    try testing.expectEqual(null, removed.value.metadataValue("draft"));
    try testing.expectEqualStrings("sam", removed.value.metadataValue("reviewer").?);

    // And clear removes the lot, which no documentation states either.
    var cleared = obj.updateMetadata(.{ .edit = .clear }) catch |err| return f.report(err);
    defer cleared.deinit();
    try testing.expectEqual(0, cleared.value.metadata.len);
    // The fixed fields are untouched by a metadata clear.
    try testing.expectEqualStrings("text/markdown", cleared.value.content_type);
}

test "10. patch: a stale metageneration is refused, and one generation is patched without the live one" {
    var f: Fixture = undefined;
    if (!try f.init(.{})) return error.SkipZigTest;
    defer f.deinit();
    const obj = try f.object("generations.txt");
    var first = obj.upload("one\n", .{ .content_type = "text/plain" }) catch |err| return f.report(err);
    defer first.deinit();
    const old_generation = first.value.generation;

    // A stale metageneration is refused, and the object is untouched.
    try testing.expectError(error.FailedPrecondition, obj.updateMetadata(.{
        .content_type = "text/x-nope",
        .preconditions = .{ .if_metageneration_match = first.value.metageneration + 7 },
    }));
    try testing.expectEqual(412, f.diag.http_status);
    var unchanged = obj.get(.{}) catch |err| return f.report(err);
    defer unchanged.deinit();
    try testing.expectEqualStrings("text/plain", unchanged.value.content_type);

    // The current one is accepted.
    var conditional = obj.updateMetadata(.{
        .cache_control = "no-store",
        .preconditions = .{ .if_metageneration_match = first.value.metageneration },
    }) catch |err| return f.report(err);
    defer conditional.deinit();
    try testing.expectEqualStrings("no-store", conditional.value.cache_control.?);

    // `generation` addresses one generation rather than whatever is live.
    // Naming the current one works; naming the one an overwrite replaced
    // is a clean NotFound, because this bucket keeps no noncurrent
    // versions, as the suite's header requires. Patching a noncurrent
    // generation needs a versioned bucket, which is why it is not here.
    var second = obj.upload("two\n", .{ .content_type = "text/plain" }) catch |err| return f.report(err);
    defer second.deinit();
    try testing.expect(second.value.generation != old_generation);
    var named = obj.updateMetadata(.{
        .generation = second.value.generation,
        .edit = .{ .change = &.{.{ .key = "era", .value = "second" }} },
    }) catch |err| return f.report(err);
    defer named.deinit();
    try testing.expectEqual(second.value.generation, named.value.generation);
    try testing.expectEqualStrings("second", named.value.metadataValue("era").?);
    try testing.expectError(error.NotFound, obj.updateMetadata(.{
        .generation = old_generation,
        .edit = .{ .change = &.{.{ .key = "era", .value = "first" }} },
    }));
}

test "11. compose: three parts join, the composite has no md5, and its crc32c verifies" {
    var f: Fixture = undefined;
    if (!try f.init(.{})) return error.SkipZigTest;
    defer f.deinit();
    const parts = [_][]const u8{ "alpha\n", "beta\n", "gamma\n" };
    var sources: [3]storage.ComposeSource = undefined;
    for (parts, &sources, 0..) |data, *source, i| {
        const name = try std.fmt.allocPrint(f.arena.allocator(), "part-{d}", .{i});
        const part = try f.object(name);
        var info = part.upload(data, .{ .content_type = "text/plain" }) catch |err| return f.report(err);
        defer info.deinit();
        source.* = .{ .name = part.name, .generation = info.value.generation };
    }

    const joined = try f.object("joined.txt");
    var composite = joined.composeFrom(&sources, .{
        .content_type = "text/plain",
        .metadata = &.{.{ .key = "origin", .value = "compose" }},
    }) catch |err| return f.report(err);
    defer composite.deinit();

    // The bytes are the parts in order, and the download verifies the
    // composite's own crc32c through the path every download uses.
    try f.expectContent(joined, "alpha\nbeta\ngamma\n");
    try testing.expectEqual(3, composite.value.component_count.?);
    try testing.expectEqual(null, composite.value.md5);
    try testing.expectEqual(patternCrcOf("alpha\nbeta\ngamma\n"), composite.value.crc32c.?);
    try testing.expectEqualStrings("compose", composite.value.metadataValue("origin").?);

    // The destination as its own first source is an append, and the
    // component count grows with it.
    var appended = joined.composeFrom(&.{
        .{ .name = joined.name },
        .{ .name = sources[0].name },
    }, .{ .content_type = "text/plain" }) catch |err| return f.report(err);
    defer appended.deinit();
    try f.expectContent(joined, "alpha\nbeta\ngamma\nalpha\n");
    try testing.expectEqual(4, appended.value.component_count.?);

    // A source pinned to a generation that has moved on is refused.
    try testing.expectError(error.FailedPrecondition, joined.composeFrom(&.{
        .{ .name = sources[0].name, .if_generation_match = sources[0].generation.? + 7 },
    }, .{}));
}

test "12. compose: deleting the sources leaves the composite and removes the parts" {
    var f: Fixture = undefined;
    if (!try f.init(.{})) return error.SkipZigTest;
    defer f.deinit();
    var sources: [2]storage.ComposeSource = undefined;
    for (&sources, 0..) |*source, i| {
        const name = try std.fmt.allocPrint(f.arena.allocator(), "temp-{d}", .{i});
        const part = try f.object(name);
        var info = part.upload("chunk\n", .{ .content_type = "text/plain" }) catch |err| return f.report(err);
        info.deinit();
        source.* = .{ .name = part.name };
    }
    const joined = try f.object("deleted-sources.txt");
    var composite = joined.composeFrom(&sources, .{
        .content_type = "text/plain",
        .delete_sources = true,
    }) catch |err| return f.report(err);
    defer composite.deinit();
    try f.expectContent(joined, "chunk\nchunk\n");
    for (sources) |source| {
        try testing.expectEqual(false, try f.bucket().object(source.name).exists());
    }
}

test "13. compose: 32 sources work, and 33 is this library's limit, not a request" {
    var f: Fixture = undefined;
    if (!try f.init(.{})) return error.SkipZigTest;
    defer f.deinit();
    const one = try f.object("unit.txt");
    var info = one.upload("x", .{ .content_type = "text/plain" }) catch |err| return f.report(err);
    info.deinit();

    // Thirty-two of the same object at different generations would be
    // refused by this library's own repeat rule, so each source is pinned
    // to the one generation and named through a distinct copy.
    var sources: [33]storage.ComposeSource = undefined;
    for (&sources, 0..) |*source, i| {
        const name = try std.fmt.allocPrint(f.arena.allocator(), "unit-{d}.txt", .{i});
        const copy = try f.object(name);
        var copied = one.copyTo(copy, .{}) catch |err| return f.report(err);
        copied.deinit();
        source.* = .{ .name = copy.name };
    }
    const joined = try f.object("thirty-two.txt");
    var composite = joined.composeFrom(sources[0..32], .{ .content_type = "text/plain" }) catch |err| return f.report(err);
    defer composite.deinit();
    try testing.expectEqual(32, composite.value.size);
    try testing.expectEqual(32, composite.value.component_count.?);

    // Thirty-three never reaches Google: the client's bound matches the
    // server's documented one.
    try testing.expectError(error.InvalidComposeSources, joined.composeFrom(&sources, .{}));
}

/// The CRC-32C of a literal, for the composite whose checksum Cloud
/// Storage derives from its components' rather than from the bytes.
fn patternCrcOf(text: []const u8) u32 {
    return core.crc32c.hash(text);
}

test "sweep: delete anything a crashed run left under zig-gcp-test/ or zig-gcp-tmp/ more than a day ago" {
    var f: Fixture = undefined;
    if (!try f.init(.{})) return error.SkipZigTest;
    defer f.deinit();

    const now = std.Io.Clock.real.now(testing.io).nanoseconds;
    const day: i96 = 24 * 60 * 60 * std.time.ns_per_s;
    var deleted: usize = 0;
    for ([_][]const u8{ "zig-gcp-test/", "zig-gcp-tmp/" }) |prefix| {
        var token: ?[]const u8 = null;
        for (0..100) |_| {
            var page = f.bucket().listObjects(.{ .prefix = prefix, .page_token = token }) catch |err| return f.report(err);
            defer page.deinit();
            for (page.value.objects) |info| {
                // Only this suite's objects, and only old ones: a run going
                // on right now elsewhere keeps its own.
                const created = storage.parseTimestamp(info.time_created) catch continue;
                if (now - created.nanoseconds < day) continue;
                f.bucket().object(info.name).delete(.{ .generation = info.generation }) catch continue;
                deleted += 1;
            }
            const next = page.value.next_page_token orelse break;
            token = try f.arena.allocator().dupe(u8, next);
        }
    }
    if (deleted > 0) std.debug.print("swept {d} leftover test object(s)\n", .{deleted});
}

// Parallel uploads and copies with changes: the parallel-uploads-and-copy
// spec's section 9, cases 1 to 16, which is where the undocumented parts
// are settled.

const Header = core.transport.Header;

/// A raw request through the fixture's transport, carrying its token: for
/// what no call of the library asks. Lives in the fixture's arena.
fn raw(
    f: *Fixture,
    method: core.transport.Method,
    path: []const u8,
    headers: []const Header,
    content_type: ?[]const u8,
    body: ?[]const u8,
) !core.transport.StreamResponse {
    const arena = f.arena.allocator();
    const url = try std.fmt.allocPrint(arena, "https://storage.googleapis.com{s}", .{path});
    const segments = [_][]const u8{body orelse ""};
    return f.faults.transport().sendStream(.{
        .method = method,
        .url = url,
        .bearer = f.token.token,
        .content_type = content_type,
        .headers = headers,
        .body = if (body != null) .{ .segments = &segments } else .none,
    }, arena);
}

/// `/storage/v1/b/{bucket}/o/{name}`, the name one strict segment.
fn jsonPath(f: *Fixture, name: []const u8, suffix: []const u8) ![]const u8 {
    return std.fmt.allocPrint(f.arena.allocator(), "/storage/v1/b/{s}/o/{s}{s}", .{ f.bucket_name, try segment(f, name), suffix });
}

/// A name as one strict segment of a JSON API path.
fn segment(f: *Fixture, name: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(f.arena.allocator());
    try core.query.writeStrictSegment(&out.writer, name);
    return out.written();
}

/// The rewrite call a copy makes, raw, with `resource` as its body.
fn rewriteRaw(f: *Fixture, source: []const u8, dest: []const u8, resource: []const u8) !core.transport.StreamResponse {
    const path = try std.fmt.allocPrint(f.arena.allocator(), "{s}/rewriteTo/b/{s}/o/{s}", .{ try jsonPath(f, source, ""), f.bucket_name, try segment(f, dest) });
    return raw(f, .POST, path, &.{}, "application/json", resource);
}

/// `/{bucket}/{name}{query}`: the suite's names need no escaping.
fn xmlPath(f: *Fixture, name: []const u8, query: []const u8) ![]const u8 {
    return std.fmt.allocPrint(f.arena.allocator(), "/{s}/{s}{s}", .{ f.bucket_name, name, query });
}

fn expectStatus(expected: u16, res: core.transport.StreamResponse) !void {
    if (res.status != expected) std.debug.print("HTTP {d}: {s}\n", .{ res.status, res.body });
    try testing.expectEqual(expected, res.status);
}

/// The text of the first `<tag>` in `body`, or null.
fn xmlText(body: []const u8, comptime tag: []const u8) ?[]const u8 {
    const start = (std.mem.indexOf(u8, body, "<" ++ tag ++ ">") orelse return null) + tag.len + 2;
    const end = std.mem.indexOfPos(u8, body, start, "</" ++ tag ++ ">") orelse return null;
    return body[start..end];
}

/// A field of an object's JSON resource, read raw, for what `ObjectInfo`
/// does not report.
fn rawField(f: *Fixture, name: []const u8, field: []const u8) !?[]const u8 {
    const res = try raw(f, .GET, try jsonPath(f, name, ""), &.{}, null, null);
    try expectStatus(200, res);
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, f.arena.allocator(), res.body, .{});
    const value = parsed.object.get(field) orelse return null;
    return switch (value) {
        .string => |s| s,
        else => null,
    };
}

/// Multipart uploads still open for names under the test's prefix.
fn openUploads(f: *Fixture) !usize {
    const path = try std.fmt.allocPrint(f.arena.allocator(), "/{s}?uploads&prefix={s}", .{ f.bucket_name, &f.prefix });
    const res = try raw(f, .GET, path, &.{}, null, null);
    try expectStatus(200, res);
    return std.mem.count(u8, res.body, "<Upload>");
}

/// Several real transports behind one that several tasks may share: each
/// request takes a transport from the pool and gives it back, so a parallel
/// upload's workers each get a connection, as the built-in transport gives
/// them. It also counts stored parts and times finishes.
const PoolTransport = struct {
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    transports: [16]core.transport.HttpTransport,
    free: [16]u8,
    free_count: usize,
    parts_stored: u32 = 0,
    finish_ms: [8]i64 = @splat(0),
    finishes: usize = 0,

    fn init(p: *PoolTransport, gpa: Allocator, io: std.Io) void {
        p.* = .{ .io = io, .transports = undefined, .free = undefined, .free_count = 16 };
        for (&p.transports, 0..) |*t, i| {
            t.* = .init(gpa, io, Fixture.user_agent);
            p.free[i] = @intCast(i);
        }
    }

    fn deinit(p: *PoolTransport) void {
        for (&p.transports) |*t| t.deinit();
    }

    fn transport(p: *PoolTransport) core.transport.Transport {
        return .{ .ptr = p, .vtable = &.{ .send = send, .sendStream = sendStream } };
    }

    fn take(p: *PoolTransport) *core.transport.HttpTransport {
        p.mutex.lockUncancelable(p.io);
        defer p.mutex.unlock(p.io);
        if (p.free_count == 0) @panic("the transport pool ran dry");
        p.free_count -= 1;
        return &p.transports[p.free[p.free_count]];
    }

    fn give(p: *PoolTransport, t: *core.transport.HttpTransport) void {
        p.mutex.lockUncancelable(p.io);
        defer p.mutex.unlock(p.io);
        p.free[p.free_count] = @intCast(t - &p.transports[0]);
        p.free_count += 1;
    }

    fn send(ptr: *anyopaque, req: core.transport.Request, arena: Allocator) core.transport.Error!core.transport.Response {
        const p: *PoolTransport = @ptrCast(@alignCast(ptr));
        const t = p.take();
        defer p.give(t);
        return t.transport().send(req, arena);
    }

    fn sendStream(ptr: *anyopaque, req: core.transport.StreamRequest, arena: Allocator) core.transport.StreamError!core.transport.StreamResponse {
        const p: *PoolTransport = @ptrCast(@alignCast(ptr));
        const t = p.take();
        defer p.give(t);
        const started = std.Io.Clock.awake.now(p.io);
        const outcome = t.transport().sendStream(req, arena);
        const ms = started.durationTo(std.Io.Clock.awake.now(p.io)).toMilliseconds();
        const ok = if (outcome) |res| res.status >= 200 and res.status < 300 else |_| false;
        p.mutex.lockUncancelable(p.io);
        defer p.mutex.unlock(p.io);
        if (ok and req.method == .PUT and std.mem.indexOf(u8, req.url, "partNumber=") != null) p.parts_stored += 1;
        if (req.method == .POST and std.mem.indexOf(u8, req.url, "uploadId=") != null and p.finishes < p.finish_ms.len) {
            p.finish_ms[p.finishes] = ms;
            p.finishes += 1;
        }
        return outcome;
    }
};

/// A client on a `PoolTransport`, with the fixture's token.
fn pooledClient(f: *Fixture, pool: *PoolTransport) !storage.Client {
    pool.init(testing.allocator, testing.io);
    return storage.Client.init(testing.allocator, testing.io, .{
        .token_provider = f.token.provider(),
        .transport = pool.transport(),
        .diagnostics = &f.diag,
        .request_timeout_ms = 120_000,
        .user_agent = Fixture.user_agent,
    });
}

test "14. copy: a rewrite keeps only what it names, so copyTo sends everything back" {
    var f: Fixture = undefined;
    if (!try f.init(.{})) return error.SkipZigTest;
    defer f.deinit();
    const src = try f.object("copy-src.txt");
    var up = src.upload("hello\n", .{
        .content_type = "text/plain",
        .cache_control = "no-cache",
        .content_language = "en",
        .metadata = &.{ .{ .key = "reviewer", .value = "kim" }, .{ .key = "stage", .value = "draft" } },
    }) catch |err| return f.report(err);
    up.deinit();
    // customTime can be set only by a raw patch: no call of the library sets it.
    const custom_time = "2026-09-24T00:00:00Z";
    try expectStatus(200, try raw(&f, .PATCH, try jsonPath(&f, src.name, ""), &.{}, "application/json", "{\"customTime\":\"" ++ custom_time ++ "\"}"));

    // 1. A rewrite whose resource names only contentType.
    const only_type = try f.object("only-type.txt");
    try expectStatus(200, try rewriteRaw(&f, src.name, only_type.name, "{\"contentType\":\"text/csv\"}"));
    var typed = only_type.get(.{}) catch |err| return f.report(err);
    defer typed.deinit();
    std.debug.print("a rewrite naming only contentType: cacheControl {?s}, contentLanguage {?s}, {d} custom keys, customTime {?s}\n", .{
        typed.value.cache_control, typed.value.content_language, typed.value.metadata.len, try rawField(&f, only_type.name, "customTime"),
    });
    try testing.expectEqualStrings("text/csv", typed.value.content_type);
    try testing.expectEqual(null, typed.value.cache_control);
    try testing.expectEqual(0, typed.value.metadata.len);

    // 2. One naming only storageClass, which Google's own samples send.
    const only_class = try f.object("only-class.txt");
    try expectStatus(200, try rewriteRaw(&f, src.name, only_class.name, "{\"storageClass\":\"NEARLINE\"}"));
    var classed = only_class.get(.{}) catch |err| return f.report(err);
    defer classed.deinit();
    std.debug.print("a rewrite naming only storageClass: contentType \"{s}\", cacheControl {?s}, {d} custom keys, class {s}\n", .{
        classed.value.content_type, classed.value.cache_control, classed.value.metadata.len, classed.value.storage_class,
    });
    try testing.expectEqualStrings("NEARLINE", classed.value.storage_class);
    try testing.expectEqual(0, classed.value.metadata.len);

    // 3. copyTo with a change keeps every field it did not change.
    const changed = try f.object("changed.txt");
    var copied = src.copyTo(changed, .{ .content_type = "text/csv" }) catch |err| return f.report(err);
    defer copied.deinit();
    try testing.expectEqualStrings("text/csv", copied.value.content_type);
    try testing.expectEqualStrings("no-cache", copied.value.cache_control.?);
    try testing.expectEqualStrings("en", copied.value.content_language.?);
    try testing.expectEqualStrings("kim", copied.value.metadataValue("reviewer").?);
    try testing.expectEqualStrings("draft", copied.value.metadataValue("stage").?);
    const carried = (try rawField(&f, changed.name, "customTime")) orelse return error.TestCustomTimeLost;
    try testing.expectEqual((try storage.parseTimestamp(custom_time)).nanoseconds, (try storage.parseTimestamp(carried)).nanoseconds);
    try f.expectContent(changed, "hello\n");
}

test "15. copy: a class changes in place, and what an empty resource does with one" {
    var f: Fixture = undefined;
    if (!try f.init(.{})) return error.SkipZigTest;
    defer f.deinit();
    const obj = try f.object("class.txt");
    var up = obj.upload("bytes that stay\n", .{
        .content_type = "text/plain",
        .metadata = &.{.{ .key = "reviewer", .value = "kim" }},
    }) catch |err| return f.report(err);
    defer up.deinit();

    // 4. Onto itself with a new class: a new generation, the same bytes
    // and metadata. NEARLINE bills 30 days on delete: a fraction of a cent.
    var moved = obj.copyTo(obj, .{ .storage_class = "NEARLINE" }) catch |err| return f.report(err);
    defer moved.deinit();
    try testing.expectEqualStrings("NEARLINE", moved.value.storage_class);
    try testing.expect(moved.value.generation != up.value.generation);
    try testing.expectEqualStrings("text/plain", moved.value.content_type);
    try testing.expectEqualStrings("kim", moved.value.metadataValue("reviewer").?);
    try f.expectContent(obj, "bytes that stay\n");

    // What an empty resource does with a class: the source's, or the
    // bucket's default, STANDARD here. Nothing documents it.
    const plain = try f.object("plain-copy.txt");
    var copied = obj.copyTo(plain, .{}) catch |err| return f.report(err);
    defer copied.deinit();
    std.debug.print("a copy with an empty resource of a NEARLINE object, in a STANDARD bucket: {s}\n", .{copied.value.storage_class});
    // And a changed copy that names no class.
    const changed = try f.object("changed-copy.txt");
    var changed_copy = obj.copyTo(changed, .{ .cache_control = "no-store" }) catch |err| return f.report(err);
    defer changed_copy.deinit();
    std.debug.print("a changed copy naming no class, of the same object: {s}\n", .{changed_copy.value.storage_class});
}

/// Patches the source's metadata just before the first rewrite call goes
/// out: the moment between a copy's read and its write.
const PatchBeforeRewrite = struct {
    inner: core.transport.Transport,
    f: *Fixture,
    source: []const u8,
    patched: bool = false,

    fn transport(self: *PatchBeforeRewrite) core.transport.Transport {
        return .{ .ptr = self, .vtable = &.{ .send = send, .sendStream = sendStream } };
    }

    fn send(ptr: *anyopaque, req: core.transport.Request, arena: Allocator) core.transport.Error!core.transport.Response {
        const self: *PatchBeforeRewrite = @ptrCast(@alignCast(ptr));
        if (!self.patched and req.method == .POST and std.mem.indexOf(u8, req.url, "/rewriteTo/") != null) {
            self.patched = true;
            const res = raw(self.f, .PATCH, jsonPath(self.f, self.source, "") catch return error.OutOfMemory, &.{}, "application/json", "{\"metadata\":{\"moved\":\"yes\"}}") catch return error.NetworkFailure;
            if (res.status != 200) return error.NetworkFailure;
        }
        return self.inner.send(req, arena);
    }

    fn sendStream(ptr: *anyopaque, req: core.transport.StreamRequest, arena: Allocator) core.transport.StreamError!core.transport.StreamResponse {
        const self: *PatchBeforeRewrite = @ptrCast(@alignCast(ptr));
        return self.inner.sendStream(req, arena);
    }
};

test "16. copy: a source that changes between the read and the write fails with 412, and nothing is written" {
    var f: Fixture = undefined;
    if (!try f.init(.{})) return error.SkipZigTest;
    defer f.deinit();
    const src = try f.object("moving-source.txt");
    var up = src.upload("x", .{ .content_type = "text/plain" }) catch |err| return f.report(err);
    up.deinit();

    // 5. A second client, whose transport changes the source in between.
    var patcher: PatchBeforeRewrite = .{ .inner = f.faults.transport(), .f = &f, .source = src.name };
    var client: storage.Client = try .init(testing.allocator, testing.io, .{
        .token_provider = f.token.provider(),
        .transport = patcher.transport(),
        .diagnostics = &f.diag,
        .user_agent = Fixture.user_agent,
    });
    defer client.deinit();
    const dest = client.bucket(f.bucket_name).object((try f.object("never-written.txt")).name);
    try testing.expectError(error.FailedPrecondition, client.bucket(f.bucket_name).object(src.name).copyTo(dest, .{ .content_type = "text/csv" }));
    try testing.expect(patcher.patched);
    try testing.expect(std.mem.indexOf(u8, f.diag.message(), "metageneration") != null);
    try testing.expect(!(try (try f.object("never-written.txt")).exists()));
}

test "17. parallel: 100 MiB in 8 MiB parts, 8 at a time" {
    var f: Fixture = undefined;
    if (!try f.init(.{})) return error.SkipZigTest;
    defer f.deinit();
    var pool: PoolTransport = undefined;
    var client = try pooledClient(&f, &pool);
    defer pool.deinit();
    defer client.deinit();
    const size = 100 * 1024 * 1024;
    const data = try pattern(testing.allocator, 17, size);
    defer testing.allocator.free(data);
    const obj = client.bucket(f.bucket_name).object((try f.object("parallel-100m.bin")).name);

    // 6. The parts, their checksums, the whole object's.
    const started = std.Io.Clock.awake.now(testing.io);
    var info = obj.uploadParallel(.{ .data = data }, .{
        .content_type = "application/octet-stream",
        .part_size = 8 * 1024 * 1024,
        .concurrency = 8,
        .crc32c = core.crc32c.hash(data),
    }) catch |err| return f.report(err);
    defer info.deinit();
    const ms = msSince(started);
    std.debug.print("100 MiB in 8 MiB parts, 8 at a time: {d} ms ({d} MiB/s); the finish took {d} ms\n", .{
        ms, @divTrunc(100 * 1000, @max(ms, 1)), pool.finish_ms[0],
    });
    std.debug.print("a multipart object: md5 {s}, component_count {?d}\n", .{ if (info.value.md5 == null) "none" else "present", info.value.component_count });
    try testing.expectEqual(size, info.value.size);
    try testing.expectEqual(core.crc32c.hash(data), info.value.crc32c.?);
    try testing.expectEqual(null, info.value.md5);
    try testing.expectEqual(13, pool.parts_stored);
    try f.expectContent(f.bucket().object(obj.name), data);
}

test "18. parallel: what the XML API answers, asked raw" {
    var f: Fixture = undefined;
    if (!try f.init(.{})) return error.SkipZigTest;
    defer f.deinit();
    const a = arena: {
        break :arena f.arena.allocator();
    };
    const name = (try f.object("raw-mpu.txt")).name;

    // 7. A finish's headers, and whether a metadata key keeps its case.
    const started = try raw(&f, .POST, try xmlPath(&f, name, "?uploads"), &.{.{ .name = "x-goog-meta-Reviewer", .value = "kim" }}, "text/plain", "");
    try expectStatus(200, started);
    const id = try a.dupe(u8, xmlText(started.body, "UploadId") orelse return error.TestNoUploadId);
    var query_buf: std.Io.Writer.Allocating = .init(a);
    try query_buf.writer.writeAll("?partNumber=1&uploadId=");
    try core.query.writeValue(&query_buf.writer, id);
    const part = try raw(&f, .PUT, try xmlPath(&f, name, query_buf.written()), &.{}, null, "one part\n");
    try expectStatus(200, part);
    const etag = part.header("ETag") orelse return error.TestNoETag;
    var id_query: std.Io.Writer.Allocating = .init(a);
    try id_query.writer.writeAll("?uploadId=");
    try core.query.writeValue(&id_query.writer, id);
    const body = try std.fmt.allocPrint(a, "<CompleteMultipartUpload><Part><PartNumber>1</PartNumber><ETag>{s}</ETag></Part></CompleteMultipartUpload>", .{etag});
    const finished = try raw(&f, .POST, try xmlPath(&f, name, id_query.written()), &.{}, "application/xml", body);
    try expectStatus(200, finished);
    std.debug.print("a finish answers x-goog-generation {?s}, x-goog-hash {?s}, ETag {?s}\n", .{
        finished.header("x-goog-generation"), finished.header("x-goog-hash"), xmlText(finished.body, "ETag"),
    });
    var info = f.bucket().object(name).get(.{}) catch |err| return f.report(err);
    defer info.deinit();
    for (info.value.metadata) |entry| std.debug.print("x-goog-meta-Reviewer came back as key \"{s}\"\n", .{entry.key});
    std.debug.print("a multipart object: md5 {s}, component_count {?d}\n", .{ if (info.value.md5 == null) "none" else "present", info.value.component_count });
    try testing.expectEqual(null, info.value.md5);

    // 10. The same finish again. Google documents 404 NoSuchUpload for an
    // upload that "might have been aborted or completed"; measured, a
    // repeat soon after answers 200 again. What matters is that it does
    // not write again: the same generation, not a new one.
    const first_generation = try std.fmt.parseInt(u64, finished.header("x-goog-generation").?, 10);
    const again = try raw(&f, .POST, try xmlPath(&f, name, id_query.written()), &.{}, "application/xml", body);
    var after_again = f.bucket().object(name).get(.{}) catch |err| return f.report(err);
    defer after_again.deinit();
    std.debug.print("the same finish again: HTTP {d}, x-goog-generation {?s}; the object's generation {d}, the first finish's {d}\n", .{
        again.status, again.header("x-goog-generation"), after_again.value.generation, first_generation,
    });
    if (again.status == 200) {
        try testing.expectEqual(first_generation, try std.fmt.parseInt(u64, again.header("x-goog-generation").?, 10));
    } else {
        try expectStatus(404, again);
        try testing.expectEqualStrings("NoSuchUpload", xmlText(again.body, "Code").?);
    }
    try testing.expectEqual(first_generation, after_again.value.generation);

    // 8. An empty object: one part of no bytes.
    const empty_name = (try f.object("raw-empty.txt")).name;
    const empty_start = try raw(&f, .POST, try xmlPath(&f, empty_name, "?uploads"), &.{}, "text/plain", "");
    try expectStatus(200, empty_start);
    const empty_id = try a.dupe(u8, xmlText(empty_start.body, "UploadId").?);
    var q2: std.Io.Writer.Allocating = .init(a);
    try q2.writer.writeAll("?partNumber=1&uploadId=");
    try core.query.writeValue(&q2.writer, empty_id);
    const empty_part = try raw(&f, .PUT, try xmlPath(&f, empty_name, q2.written()), &.{}, null, "");
    try expectStatus(200, empty_part);
    var q3: std.Io.Writer.Allocating = .init(a);
    try q3.writer.writeAll("?uploadId=");
    try core.query.writeValue(&q3.writer, empty_id);
    const empty_finish = try raw(&f, .POST, try xmlPath(&f, empty_name, q3.written()), &.{}, "application/xml", try std.fmt.allocPrint(a, "<CompleteMultipartUpload><Part><PartNumber>1</PartNumber><ETag>{s}</ETag></Part></CompleteMultipartUpload>", .{empty_part.header("ETag").?}));
    std.debug.print("a multipart upload of one empty part finishes with HTTP {d}\n", .{empty_finish.status});
    if (empty_finish.status != 200) _ = try raw(&f, .DELETE, try xmlPath(&f, empty_name, q3.written()), &.{}, null, null);

    // 9. x-goog-if-generation-match: 0 on a finish over an existing object.
    const cond_start = try raw(&f, .POST, try xmlPath(&f, name, "?uploads"), &.{}, "text/plain", "");
    try expectStatus(200, cond_start);
    const cond_id = try a.dupe(u8, xmlText(cond_start.body, "UploadId").?);
    var q4: std.Io.Writer.Allocating = .init(a);
    try q4.writer.writeAll("?partNumber=1&uploadId=");
    try core.query.writeValue(&q4.writer, cond_id);
    const cond_part = try raw(&f, .PUT, try xmlPath(&f, name, q4.written()), &.{}, null, "replacement\n");
    try expectStatus(200, cond_part);
    var q5: std.Io.Writer.Allocating = .init(a);
    try q5.writer.writeAll("?uploadId=");
    try core.query.writeValue(&q5.writer, cond_id);
    const cond_finish = try raw(&f, .POST, try xmlPath(&f, name, q5.written()), &.{.{ .name = "x-goog-if-generation-match", .value = "0" }}, "application/xml", try std.fmt.allocPrint(a, "<CompleteMultipartUpload><Part><PartNumber>1</PartNumber><ETag>{s}</ETag></Part></CompleteMultipartUpload>", .{cond_part.header("ETag").?}));
    std.debug.print("a finish with x-goog-if-generation-match: 0 over an existing object answers HTTP {d}\n", .{cond_finish.status});
    if (cond_finish.status != 200) _ = try raw(&f, .DELETE, try xmlPath(&f, name, q5.written()), &.{}, null, null);

    // 10, the other half. A part sent after an abort.
    const gone_name = (try f.object("raw-aborted.txt")).name;
    const gone_start = try raw(&f, .POST, try xmlPath(&f, gone_name, "?uploads"), &.{}, "text/plain", "");
    try expectStatus(200, gone_start);
    const gone_id = try a.dupe(u8, xmlText(gone_start.body, "UploadId").?);
    var q6: std.Io.Writer.Allocating = .init(a);
    try q6.writer.writeAll("?uploadId=");
    try core.query.writeValue(&q6.writer, gone_id);
    try expectStatus(204, try raw(&f, .DELETE, try xmlPath(&f, gone_name, q6.written()), &.{}, null, null));
    var q7: std.Io.Writer.Allocating = .init(a);
    try q7.writer.writeAll("?partNumber=1&uploadId=");
    try core.query.writeValue(&q7.writer, gone_id);
    const late = try raw(&f, .PUT, try xmlPath(&f, gone_name, q7.written()), &.{}, null, "late\n");
    try expectStatus(404, late);
    try testing.expectEqualStrings("NoSuchUpload", xmlText(late.body, "Code").?);

    // 11. A part under 5 MiB that is not the last is refused at the finish.
    const small_name = (try f.object("raw-small.txt")).name;
    const small_start = try raw(&f, .POST, try xmlPath(&f, small_name, "?uploads"), &.{}, "text/plain", "");
    try expectStatus(200, small_start);
    const small_id = try a.dupe(u8, xmlText(small_start.body, "UploadId").?);
    var etags: [2][]const u8 = undefined;
    for (&etags, 1..) |*e, n| {
        var q: std.Io.Writer.Allocating = .init(a);
        try q.writer.print("?partNumber={d}&uploadId=", .{n});
        try core.query.writeValue(&q.writer, small_id);
        const p = try raw(&f, .PUT, try xmlPath(&f, small_name, q.written()), &.{}, null, "a small part\n");
        try expectStatus(200, p);
        e.* = try a.dupe(u8, p.header("ETag").?);
    }
    var q8: std.Io.Writer.Allocating = .init(a);
    try q8.writer.writeAll("?uploadId=");
    try core.query.writeValue(&q8.writer, small_id);
    const small_finish = try raw(&f, .POST, try xmlPath(&f, small_name, q8.written()), &.{}, "application/xml", try std.fmt.allocPrint(
        a,
        "<CompleteMultipartUpload><Part><PartNumber>1</PartNumber><ETag>{s}</ETag></Part><Part><PartNumber>2</PartNumber><ETag>{s}</ETag></Part></CompleteMultipartUpload>",
        .{ etags[0], etags[1] },
    ));
    std.debug.print("a non-final part under 5 MiB: HTTP {d} {?s}: {?s}\n", .{ small_finish.status, xmlText(small_finish.body, "Code"), xmlText(small_finish.body, "Message") });
    try testing.expectEqual(400, small_finish.status);
    _ = try raw(&f, .DELETE, try xmlPath(&f, small_name, q8.written()), &.{}, null, null);
    try testing.expectEqual(0, try openUploads(&f));
}

test "19. parallel: a cut part, a lost part answer and a lost finish answer are all ridden out" {
    var plan = [_]FaultTransport.Fault{
        .{ .method = .PUT, .url_contains = "partNumber=2", .action = .{ .cut_request_body = 3 * 1024 * 1024 } },
        .{ .method = .PUT, .url_contains = "partNumber=3", .action = .lose_response },
        .{ .method = .POST, .url_contains = "uploadId=", .action = .lose_response },
    };
    var f: Fixture = undefined;
    if (!try f.init(.{ .plan = &plan, .record = true })) return error.SkipZigTest;
    defer f.deinit();
    const size = 5 * 5 * 1024 * 1024 + 12345;
    const data = try pattern(testing.allocator, 19, size);
    defer testing.allocator.free(data);
    const obj = try f.object("parallel-faults.bin");

    // 12. One worker, on the fixture's fault transport, which is not for
    // sharing between tasks.
    var info = obj.uploadParallel(.{ .data = data }, .{ .part_size = 5 * 1024 * 1024, .concurrency = 1 }) catch |err| return f.report(err);
    defer info.deinit();
    for (plan, 0..) |fault, i| {
        errdefer std.debug.print("fault {d} ({s}) did not fire\n", .{ i, fault.url_contains });
        try testing.expect(fault.fired);
    }
    try testing.expectEqual(core.crc32c.hash(data), info.value.crc32c.?);
    try f.expectContent(obj, data);
    try testing.expectEqual(0, try openUploads(&f));
}

test "20. parallel: a failure and a cancel both leave no multipart upload open" {
    var f: Fixture = undefined;
    if (!try f.init(.{})) return error.SkipZigTest;
    defer f.deinit();
    var pool: PoolTransport = undefined;
    var client = try pooledClient(&f, &pool);
    defer pool.deinit();
    defer client.deinit();
    const size = 8 * 5 * 1024 * 1024;
    const data = try pattern(testing.allocator, 20, size);
    defer testing.allocator.free(data);

    // 13. A failure: a checksum that does not match, found before the finish.
    const failed = client.bucket(f.bucket_name).object((try f.object("failed.bin")).name);
    try testing.expectError(error.ChecksumMismatch, failed.uploadParallel(.{ .data = data }, .{
        .part_size = 5 * 1024 * 1024,
        .crc32c = core.crc32c.hash(data) ^ 1,
    }));
    try testing.expectEqual(0, try openUploads(&f));
    try testing.expect(!(try f.bucket().object(failed.name).exists()));

    // And a cancel, once some parts are in.
    const canceled = client.bucket(f.bucket_name).object((try f.object("canceled.bin")).name);
    const Running = struct {
        fn go(target: storage.Object, bytes: []const u8) storage.Error!void {
            var info = try target.uploadParallel(.{ .data = bytes }, .{ .part_size = 5 * 1024 * 1024, .concurrency = 2 });
            info.deinit();
        }
    };
    const before = pool.parts_stored;
    var task = try testing.io.concurrent(Running.go, .{ canceled, data });
    const deadline_ms: i64 = 120_000;
    const waiting = std.Io.Clock.awake.now(testing.io);
    while (true) {
        pool.mutex.lockUncancelable(testing.io);
        const stored = pool.parts_stored - before;
        pool.mutex.unlock(testing.io);
        if (stored >= 2) break;
        if (msSince(waiting) > deadline_ms) @panic("no part was stored within two minutes");
        try testing.io.sleep(.fromMilliseconds(50), .awake);
    }
    try testing.expectError(error.Canceled, task.cancel(testing.io));
    try testing.expectEqual(0, try openUploads(&f));
    try testing.expect(!(try f.bucket().object(canceled.name).exists()));
}

test "21. parallel: 1 GiB from a file, one connection against eight, timed" {
    var f: Fixture = undefined;
    if (!try f.init(.{})) return error.SkipZigTest;
    defer f.deinit();
    var pool: PoolTransport = undefined;
    var client = try pooledClient(&f, &pool);
    defer pool.deinit();
    defer client.deinit();

    const size: u64 = 1024 * 1024 * 1024;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        const out = try tmp.dir.createFile(testing.io, "gib.bin", .{});
        defer out.close(testing.io);
        var buf: [64 * 1024]u8 = undefined;
        var writer = out.writer(testing.io, &buf);
        var block: [64 * 1024]u8 = undefined;
        var i: u64 = 0;
        while (i < size) : (i += block.len) {
            for (&block, 0..) |*b, k| b.* = patternByte(21, i + k);
            try writer.interface.writeAll(&block);
        }
        try writer.interface.flush();
    }
    const file = try tmp.dir.openFile(testing.io, "gib.bin", .{});
    defer file.close(testing.io);
    const expected = patternCrc(21, size);

    // 14. The same file, one worker and then eight. 15. The finish of 103
    // parts, timed.
    var ms: [2]i64 = undefined;
    for ([_]u16{ 1, 8 }, 0..) |concurrency, i| {
        const obj = client.bucket(f.bucket_name).object(try std.fmt.allocPrint(f.arena.allocator(), "{s}gib-{d}.bin", .{ &f.prefix, concurrency }));
        const started = std.Io.Clock.awake.now(testing.io);
        var info = obj.uploadParallel(.{ .file = file }, .{
            .part_size = 10 * 1024 * 1024,
            .concurrency = concurrency,
            .crc32c = expected,
        }) catch |err| return f.report(err);
        defer info.deinit();
        ms[i] = msSince(started);
        try testing.expectEqual(size, info.value.size);
        try testing.expectEqual(expected, info.value.crc32c.?);
        std.debug.print("1 GiB in 103 parts, {d} at a time: {d} ms ({d} MiB/s); the finish took {d} ms\n", .{
            concurrency, ms[i], @divTrunc(1024 * 1000, @max(ms[i], 1)), pool.finish_ms[pool.finishes - 1],
        });
    }
    std.debug.print("eight at a time was {d:.2} times as fast as one\n", .{@as(f64, @floatFromInt(ms[0])) / @as(f64, @floatFromInt(@max(ms[1], 1)))});
}

test "22. move: whether objects.move works in a bucket without hierarchical namespace" {
    var f: Fixture = undefined;
    if (!try f.init(.{})) return error.SkipZigTest;
    defer f.deinit();
    const src = try f.object("move-src.txt");
    var up = src.upload("moving\n", .{}) catch |err| return f.report(err);
    up.deinit();
    const dest_name = (try f.object("move-dest.txt")).name;
    // 16. For the follow-up that would make parallel uploads create-only.
    const path = try std.fmt.allocPrint(f.arena.allocator(), "{s}/moveTo/o/{s}", .{ try jsonPath(&f, src.name, ""), try segment(&f, dest_name) });
    const moved = try raw(&f, .POST, try std.fmt.allocPrint(f.arena.allocator(), "{s}?ifGenerationMatch=0", .{path}), &.{}, "application/json", "");
    std.debug.print("objects.move in a flat bucket: HTTP {d} {s}\n", .{ moved.status, moved.body[0..@min(moved.body.len, 300)] });
    if (moved.status == 200) {
        try testing.expect(!(try src.exists()));
        try f.expectContent(f.bucket().object(dest_name), "moving\n");
    }
}

// Parallel downloads and create-only parallel uploads: the parallel
// downloads spec's section 8, real-bucket cases 1 to 8.

/// Objects under the bucket's `zig-gcp-tmp/`, where an upload with
/// conditions finishes before it moves into place: anything there was left
/// behind.
fn tempObjects(f: *Fixture) !usize {
    var page = f.bucket().listObjects(.{ .prefix = "zig-gcp-tmp/" }) catch |err| return f.report(err);
    defer page.deinit();
    for (page.value.objects) |o| std.debug.print("left under zig-gcp-tmp/: {s}\n", .{o.name});
    return page.value.objects.len;
}

/// Multipart uploads still open under `zig-gcp-tmp/`.
fn openTempUploads(f: *Fixture) !usize {
    const path = try std.fmt.allocPrint(f.arena.allocator(), "/{s}?uploads&prefix=zig-gcp-tmp/", .{f.bucket_name});
    const res = try raw(f, .GET, path, &.{}, null, null);
    try expectStatus(200, res);
    return std.mem.count(u8, res.body, "<Upload>");
}

/// The CRC-32C of a file, read back from disk.
fn fileCrc(file: std.Io.File) !u32 {
    var buffer: [64 * 1024]u8 = undefined;
    var reader = file.reader(testing.io, &buffer);
    var hasher: core.crc32c.Hasher = .init();
    while (true) {
        const chunk = reader.interface.peekGreedy(1) catch |err| switch (err) {
            error.EndOfStream => break,
            else => |e| return e,
        };
        hasher.update(chunk);
        reader.interface.toss(chunk.len);
    }
    return hasher.final();
}

test "23. parallel download: 1 GiB in 32 MiB ranges, one at a time and eight at a time, timed" {
    var f: Fixture = undefined;
    if (!try f.init(.{})) return error.SkipZigTest;
    defer f.deinit();
    var pool: PoolTransport = undefined;
    var client = try pooledClient(&f, &pool);
    defer pool.deinit();
    defer client.deinit();

    const size: u64 = 1024 * 1024 * 1024;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        const out = try tmp.dir.createFile(testing.io, "gib.bin", .{});
        defer out.close(testing.io);
        var buf: [64 * 1024]u8 = undefined;
        var writer = out.writer(testing.io, &buf);
        var block: [64 * 1024]u8 = undefined;
        var i: u64 = 0;
        while (i < size) : (i += block.len) {
            for (&block, 0..) |*b, k| b.* = patternByte(23, i + k);
            try writer.interface.writeAll(&block);
        }
        try writer.interface.flush();
    }
    const source = try tmp.dir.openFile(testing.io, "gib.bin", .{});
    defer source.close(testing.io);
    const expected = patternCrc(23, size);
    const obj = client.bucket(f.bucket_name).object((try f.object("gib-down.bin")).name);
    var up = obj.uploadParallel(.{ .file = source }, .{ .part_size = 32 * 1024 * 1024, .crc32c = expected }) catch |err| return f.report(err);
    defer up.deinit();

    // 1. Down in 32 MiB ranges, one at a time, then eight, into a file.
    var ms: [2]i64 = undefined;
    for ([_]u16{ 1, 8 }, 0..) |concurrency, i| {
        const out = try tmp.dir.createFile(testing.io, "down.bin", .{ .read = true });
        defer out.close(testing.io);
        const started = std.Io.Clock.awake.now(testing.io);
        const result = obj.downloadParallel(.{ .file = out }, .{ .concurrency = concurrency }) catch |err| return f.report(err);
        ms[i] = msSince(started);
        try testing.expect(result.checksum_verified);
        try testing.expectEqual(expected, result.crc32c);
        try testing.expectEqual(size, try out.length(testing.io));
        // The ranges' checksum covers the bytes as they arrived; the file
        // read back says they landed where they belong.
        try testing.expectEqual(expected, try fileCrc(out));
        std.debug.print("1 GiB down in 32 MiB ranges, {d} at a time: {d} ms ({d} MiB/s)\n", .{
            concurrency, ms[i], @divTrunc(1024 * 1000, @max(ms[i], 1)),
        });
    }
    std.debug.print("eight at a time was {d:.2} times as fast as one\n", .{@as(f64, @floatFromInt(ms[0])) / @as(f64, @floatFromInt(@max(ms[1], 1)))});
}

test "24. parallel download: what a range of a private object carries, and ranges verified anyway" {
    var f: Fixture = undefined;
    if (!try f.init(.{})) return error.SkipZigTest;
    defer f.deinit();
    const size = 3 * 1024 * 1024 + 7;
    const data = try pattern(testing.allocator, 24, size);
    defer testing.allocator.free(data);
    const obj = try f.object("ranges.bin");
    var up = obj.upload(data, .{}) catch |err| return f.report(err);
    up.deinit();

    // 2. A range short of the whole object, and one that is all of it.
    const media = try jsonPath(&f, obj.name, "?alt=media");
    const whole = try std.fmt.allocPrint(f.arena.allocator(), "bytes=0-{d}", .{size - 1});
    for ([_][]const u8{ "bytes=0-1048575", whole }) |range| {
        const res = try raw(&f, .GET, media, &.{.{ .name = "Range", .value = range }}, null, null);
        try expectStatus(206, res);
        std.debug.print("{s} of a private object: x-goog-hash {s}\n", .{ range, res.header("x-goog-hash") orelse "(none)" });
    }

    // Each range hashed as it arrives, the hashes combined: one worker on
    // the fixture's transport, which is not for sharing between tasks.
    const out = try testing.allocator.alloc(u8, size);
    defer testing.allocator.free(out);
    const result = obj.downloadParallel(.{ .buffer = out }, .{ .part_size = 1024 * 1024, .concurrency = 1 }) catch |err| return f.report(err);
    try testing.expectEqualSlices(u8, data, out);
    try testing.expect(result.checksum_verified);
}

test "25. parallel download: an overwrite partway through fails with NotFound, never a spliced file" {
    const gpa = testing.allocator;
    const size = 3 * 1024 * 1024;
    const mib = 1024 * 1024;
    var plan = [_]FaultTransport.Fault{
        // The second range, cut partway: between its halves, another
        // writer replaces the object.
        .{ .method = .GET, .url_contains = "alt=media", .skip = 1, .action = .{ .cut_response_body = 300_000 } },
    };
    var f: Fixture = undefined;
    if (!try f.init(.{ .plan = &plan, .record = true })) return error.SkipZigTest;
    defer f.deinit();
    const original = try pattern(gpa, 251, size);
    defer gpa.free(original);
    const replacement = try pattern(gpa, 252, size);
    defer gpa.free(replacement);
    const obj = try f.object("overwritten.bin");
    var first = obj.upload(original, .{}) catch |err| return f.report(err);
    defer first.deinit();

    var other: storage.Client = try .init(gpa, testing.io, .{
        .token_provider = f.token.provider(),
        .user_agent = Fixture.user_agent,
    });
    defer other.deinit();
    var overwrite: Overwrite = .{ .object = other.bucket(f.bucket_name).object(obj.name), .data = replacement };
    f.faults.after_fault = .{ .context = &overwrite, .run = Overwrite.run };

    // 3.
    const out = try gpa.alloc(u8, size);
    defer gpa.free(out);
    try testing.expectError(error.NotFound, obj.downloadParallel(.{ .buffer = out }, .{ .part_size = mib, .concurrency = 1 }));
    try testing.expect(plan[0].fired);
    if (overwrite.err) |err| return err;
    std.debug.print("a parallel download meeting an overwrite: \"{s}\"\n", .{f.diag.message()});
    // The first range, and the second's first half, are the original's:
    // nothing of the replacement was spliced in.
    try testing.expectEqualSlices(u8, original[0 .. mib + 300_000], out[0 .. mib + 300_000]);
    // The resume asked for the old generation by number, and got a 404.
    const resumed = try f.after(try f.faulted(0));
    var pinned_buf: [48]u8 = undefined;
    const pinned = try std.fmt.bufPrint(&pinned_buf, "generation={d}", .{first.value.generation});
    try testing.expect(std.mem.indexOf(u8, resumed.url, pinned) != null);
    try testing.expectEqual(404, resumed.status.?);

    // A fresh parallel download gets the replacement, verified.
    f.faults.after_fault = null;
    const fresh = obj.downloadParallel(.{ .buffer = out }, .{ .part_size = mib, .concurrency = 1 }) catch |err| return f.report(err);
    try testing.expectEqualSlices(u8, replacement, out);
    try testing.expect(fresh.checksum_verified);
    try testing.expectEqual(overwrite.generation, fresh.generation);
}

test "26. parallel download: a gzip-stored object is fetched whole, in one request, decompressed" {
    var f: Fixture = undefined;
    if (!try f.init(.{ .record = true })) return error.SkipZigTest;
    defer f.deinit();
    const gpa = testing.allocator;
    var text: std.Io.Writer.Allocating = .init(gpa);
    defer text.deinit();
    for (0..2000) |i| try text.writer.print("line {d}: the quick brown fox jumps over the lazy dog\n", .{i});
    const plain = text.written();
    const gz = try gzip(gpa, plain);
    defer gpa.free(gz);
    const obj = try f.object("transcoded-parallel.txt");
    var info = obj.upload(gz, .{ .content_type = "text/plain", .content_encoding = "gzip" }) catch |err| return f.report(err);
    info.deinit();

    // 4.
    const before = f.faults.exchanges.items.len;
    const out = try gpa.alloc(u8, plain.len + 100);
    defer gpa.free(out);
    const result = obj.downloadParallel(.{ .buffer = out }, .{ .part_size = 1024 * 1024 }) catch |err| return f.report(err);
    try testing.expectEqualStrings(plain, out[0..result.bytes_written]);
    try testing.expect(!result.checksum_verified);
    try testing.expectEqual(core.crc32c.hash(plain), result.crc32c);
    // The metadata read, then one read of the object, with no range.
    const exchanges = f.faults.exchanges.items[before..];
    try testing.expectEqual(2, exchanges.len);
    try testing.expectEqual(null, exchanges[1].header("Range"));
    try testing.expectEqualStrings("gzip", exchanges[1].responseHeader("x-goog-stored-content-encoding").?);
}

test "27. create-only parallel upload: over an existing object, refused before a byte is sent" {
    var f: Fixture = undefined;
    if (!try f.init(.{ .record = true })) return error.SkipZigTest;
    defer f.deinit();
    const obj = try f.object("exists.bin");
    var first = obj.upload("already here\n", .{}) catch |err| return f.report(err);
    defer first.deinit();
    const data = try pattern(testing.allocator, 27, 6 * 1024 * 1024);
    defer testing.allocator.free(data);

    // 5. Create-only, and a `…NotMatch` condition that already fails.
    const refusals = [_]storage.Preconditions{
        .does_not_exist,
        .{ .if_generation_not_match = first.value.generation },
    };
    for (refusals) |conditions| {
        const before = f.faults.exchanges.items.len;
        try testing.expectError(error.FailedPrecondition, obj.uploadParallel(.{ .data = data }, .{
            .part_size = 5 * 1024 * 1024,
            .concurrency = 1,
            .preconditions = conditions,
        }));
        // One request, the early check, and no part sent.
        const exchanges = f.faults.exchanges.items[before..];
        try testing.expectEqual(1, exchanges.len);
        std.debug.print("refused before a byte was sent: the early read answered HTTP {?d}\n", .{exchanges[0].status});
    }
    try testing.expectEqual(0, try openTempUploads(&f));
    try testing.expectEqual(0, try tempObjects(&f));
    try f.expectContent(obj, "already here\n");
}

/// Puts another writer's object under `name` just before the first move
/// is sent, on a client of its own.
const CreateBeforeMove = struct {
    inner: core.transport.Transport,
    other: storage.Object,
    created: bool = false,

    fn transport(self: *CreateBeforeMove) core.transport.Transport {
        return .{ .ptr = self, .vtable = &.{ .send = send, .sendStream = sendStream } };
    }

    fn send(ptr: *anyopaque, req: core.transport.Request, arena: Allocator) core.transport.Error!core.transport.Response {
        const self: *CreateBeforeMove = @ptrCast(@alignCast(ptr));
        if (!self.created and req.method == .POST and std.mem.indexOf(u8, req.url, "/moveTo/") != null) {
            self.created = true;
            var info = self.other.upload("another writer's bytes\n", .{}) catch return error.NetworkFailure;
            info.deinit();
        }
        return self.inner.send(req, arena);
    }

    fn sendStream(ptr: *anyopaque, req: core.transport.StreamRequest, arena: Allocator) core.transport.StreamError!core.transport.StreamResponse {
        const self: *CreateBeforeMove = @ptrCast(@alignCast(ptr));
        return self.inner.sendStream(req, arena);
    }
};

test "28. create-only parallel upload: an object that appears before the move is kept, and the temporary object goes" {
    var f: Fixture = undefined;
    if (!try f.init(.{})) return error.SkipZigTest;
    defer f.deinit();
    const name = (try f.object("raced.bin")).name;
    var other: storage.Client = try .init(testing.allocator, testing.io, .{
        .token_provider = f.token.provider(),
        .user_agent = Fixture.user_agent,
    });
    defer other.deinit();
    var creator: CreateBeforeMove = .{ .inner = f.faults.transport(), .other = other.bucket(f.bucket_name).object(name) };
    var diag: storage.Diagnostics = .{};
    var client: storage.Client = try .init(testing.allocator, testing.io, .{
        .token_provider = f.token.provider(),
        .transport = creator.transport(),
        .diagnostics = &diag,
        .user_agent = Fixture.user_agent,
    });
    defer client.deinit();
    const data = try pattern(testing.allocator, 28, 6 * 1024 * 1024);
    defer testing.allocator.free(data);

    // 6.
    try testing.expectError(error.FailedPrecondition, client.bucket(f.bucket_name).object(name).uploadParallel(.{ .data = data }, .{
        .part_size = 5 * 1024 * 1024,
        .concurrency = 1,
        .preconditions = .does_not_exist,
    }));
    try testing.expect(creator.created);
    std.debug.print("the move, refused: HTTP {d} {s}: {s}\n", .{ diag.http_status, diag.status(), diag.message() });
    try f.expectContent(f.bucket().object(name), "another writer's bytes\n");
    try testing.expectEqual(0, try tempObjects(&f));
    try testing.expectEqual(0, try openTempUploads(&f));
}

test "29. create-only parallel upload: a new name, with its metadata and metageneration 1, and nothing left behind" {
    var f: Fixture = undefined;
    if (!try f.init(.{ .record = true })) return error.SkipZigTest;
    defer f.deinit();
    const size = 2 * 5 * 1024 * 1024 + 4321;
    const data = try pattern(testing.allocator, 29, size);
    defer testing.allocator.free(data);
    const obj = try f.object("created.bin");

    // 7.
    const before = f.faults.exchanges.items.len;
    const started = std.Io.Clock.awake.now(testing.io);
    var info = obj.uploadParallel(.{ .data = data }, .{
        .content_type = "application/x-test",
        .metadata = &.{.{ .key = "origin", .value = "zig" }},
        .part_size = 5 * 1024 * 1024,
        .concurrency = 1,
        .crc32c = core.crc32c.hash(data),
        .preconditions = .does_not_exist,
    }) catch |err| return f.report(err);
    defer info.deinit();
    const ms = msSince(started);
    try testing.expectEqualStrings(obj.name, info.value.name);
    try testing.expectEqual(1, info.value.metageneration);
    try testing.expectEqual(size, info.value.size);
    try testing.expectEqual(core.crc32c.hash(data), info.value.crc32c.?);
    try testing.expectEqualStrings("application/x-test", info.value.content_type);
    try testing.expectEqualStrings("zig", info.value.metadataValue("origin").?);
    // The early check, the start, three parts, the finish and the move,
    // whose answer is the object: no read back.
    const exchanges = f.faults.exchanges.items[before..];
    for (exchanges) |e| std.debug.print("  {t} {?d} {s}\n", .{ e.method, e.status, e.url[0..@min(e.url.len, 110)] });
    try testing.expectEqual(7, exchanges.len);
    try testing.expect(std.mem.indexOf(u8, exchanges[6].url, "/moveTo/") != null);
    std.debug.print("create-only, {d} bytes in 3 parts: {d} ms\n", .{ size, ms });
    try testing.expectEqual(0, try tempObjects(&f));
    try testing.expectEqual(0, try openTempUploads(&f));
    try f.expectContent(obj, data);
}

test "30. create-only parallel upload: a lost move answer is settled by reading, and what the repeat met" {
    var plan = [_]FaultTransport.Fault{
        .{ .method = .POST, .url_contains = "/moveTo/", .action = .lose_response },
    };
    var f: Fixture = undefined;
    if (!try f.init(.{ .plan = &plan, .record = true })) return error.SkipZigTest;
    defer f.deinit();
    const data = try pattern(testing.allocator, 30, 6 * 1024 * 1024);
    defer testing.allocator.free(data);
    const obj = try f.object("moved-twice.bin");

    // 8.
    var info = obj.uploadParallel(.{ .data = data }, .{
        .part_size = 5 * 1024 * 1024,
        .concurrency = 1,
        .preconditions = .does_not_exist,
    }) catch |err| return f.report(err);
    defer info.deinit();
    try testing.expect(plan[0].fired);
    const repeat = try f.after(try f.faulted(0));
    std.debug.print("a move repeated after one that landed: HTTP {?d}\n", .{repeat.status});
    try testing.expect(std.mem.indexOf(u8, repeat.url, "/moveTo/") != null);
    try testing.expect(repeat.status.? == 404 or repeat.status.? == 412);
    try testing.expectEqual(core.crc32c.hash(data), info.value.crc32c.?);
    try f.expectContent(obj, data);
    try testing.expectEqual(0, try tempObjects(&f));
}
