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
//! The largest test moves 100 MiB each way and prints the throughput; the
//! suite as a whole moves about 230 MiB over the wire, and its copies are
//! server-side. One copy is stored as NEARLINE, whose 30-day minimum is
//! billed on delete: about a tenth of a cent.
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

    // A range from byte 0 still names the whole object's checksum; a range
    // from anywhere later names none. That is why a resumed download is
    // held to its first response's checksum.
    const from_zero = f.faults.exchanges.items.len;
    var head = obj.downloadAlloc(16, .{ .range = .{ .offset = 0, .length = 10 } }) catch |err| return f.report(err);
    head.deinit();
    var tail = obj.downloadAlloc(16, .{ .range = .{ .offset = 1000, .length = 10 } }) catch |err| return f.report(err);
    tail.deinit();
    try testing.expectEqual(206, f.faults.exchanges.items[from_zero].status.?);
    try testing.expect(f.faults.exchanges.items[from_zero].responseHeader("x-goog-hash") != null);
    try testing.expectEqual(null, f.faults.exchanges.items[from_zero + 1].responseHeader("x-goog-hash"));

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

test "sweep: delete anything a crashed run left under zig-gcp-test/ more than a day ago" {
    var f: Fixture = undefined;
    if (!try f.init(.{})) return error.SkipZigTest;
    defer f.deinit();

    const now = std.Io.Clock.real.now(testing.io).nanoseconds;
    const day: i96 = 24 * 60 * 60 * std.time.ns_per_s;
    var deleted: usize = 0;
    var token: ?[]const u8 = null;
    for (0..100) |_| {
        var page = f.bucket().listObjects(.{ .prefix = "zig-gcp-test/", .page_token = token }) catch |err| return f.report(err);
        defer page.deinit();
        for (page.value.objects) |info| {
            // Only this suite's objects, and only old ones: a run going on
            // right now elsewhere keeps its own.
            const created = storage.parseTimestamp(info.time_created) catch continue;
            if (now - created.nanoseconds < day) continue;
            f.bucket().object(info.name).delete(.{ .generation = info.generation }) catch continue;
            deleted += 1;
        }
        const next = page.value.next_page_token orelse break;
        token = try f.arena.allocator().dupe(u8, next);
    }
    if (deleted > 0) std.debug.print("swept {d} leftover test object(s)\n", .{deleted});
}
