//! Test helpers: a scripted fake transport, a fake clock, and a runner for
//! byte-driven property tests that also feeds `zig build test --fuzz`.
//! The modules' own tests use them, and so can tests of code that uses the
//! modules. Nothing here is referenced by a normal build.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

const Transport = @import("transport.zig").Transport;
const TransportError = @import("transport.zig").Error;
const Method = @import("transport.zig").Method;
const Request = @import("transport.zig").Request;
const Response = @import("transport.zig").Response;
const StreamRequest = @import("transport.zig").StreamRequest;
const StreamResponse = @import("transport.zig").StreamResponse;
const StreamError = @import("transport.zig").StreamError;
const ContentType = @import("transport.zig").ContentType;
const Header = @import("transport.zig").Header;
const TokenProvider = @import("TokenProvider.zig");
const Crc32c = @import("crc32c.zig").Hasher;

/// A `TokenProvider` that returns one token, or fails with one error, and
/// counts how it is used.
pub const FakeTokenProvider = struct {
    /// Returned, copied into the caller's arena, while `fail` is null.
    token: []const u8 = "ya29.fake-token",
    /// When set, `getToken` fails with it.
    fail: ?TokenProvider.Error = null,
    /// When set, `invalidate` makes this the token from then on, so a test
    /// can tell a freshly fetched token from the cached one.
    next_token: ?[]const u8 = null,
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
        const self = fromPtr(ptr);
        self.invalidations += 1;
        if (self.next_token) |token| {
            self.token = token;
            self.next_token = null;
        }
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
    stream_requests: std.ArrayList(RecordedStream) = .empty,
    /// How much of a streamed request body is kept verbatim. The whole body
    /// is always drained, counted and checksummed, so a test of a large
    /// upload asserts on `body_len` and `body_crc32c` instead.
    max_recorded_body: usize = 64 * 1024,

    pub const Reply = union(enum) {
        respond: Canned,
        fail: TransportError,
    };

    pub const Canned = struct {
        status: u16 = 200,
        body: []const u8 = "{}",
        headers: []const Header = &.{},
        /// For a streamed sink: deliver only this many body bytes, then fail
        /// with `cut_error`, like a connection dropped mid-body. A buffered
        /// reply fails without delivering anything, as the real transport
        /// never returns a partial buffer.
        cut_after: ?usize = null,
        cut_error: TransportError = error.ConnectionResetByPeer,
    };

    /// A deep copy of one request, owned by the fake.
    pub const Recorded = struct {
        method: Method,
        url: []u8,
        bearer: ?[]u8,
        body: ?[]u8,
        content_type: ContentType,
        headers: []Header,
        timeout_ms: u32,

        /// The value sent for `name`, matched as HTTP matches names, or null.
        pub fn header(self: Recorded, name: []const u8) ?[]const u8 {
            for (self.headers) |h| if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
            return null;
        }
    };

    /// A deep copy of one streaming request. The body was drained from its
    /// source: `body_prefix` holds the first `max_recorded_body` bytes, and
    /// `body_len` with `body_crc32c` describe all of it.
    pub const RecordedStream = struct {
        method: Method,
        url: []u8,
        bearer: ?[]u8,
        content_type: ?[]u8,
        headers: []Header,
        body_prefix: []u8,
        body_len: u64,
        body_crc32c: u32,
        body_tag: std.meta.Tag(StreamRequest.Body),
        sink: std.meta.Tag(StreamRequest.Sink),
        accept_encoding: StreamRequest.AcceptEncoding,
        timeout_ms: u32,

        /// The value sent for `name`, matched as HTTP matches names, or null.
        pub fn header(self: RecordedStream, name: []const u8) ?[]const u8 {
            for (self.headers) |h| if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
            return null;
        }
    };

    pub fn init(gpa: Allocator, script: []const Reply) FakeTransport {
        return .{ .gpa = gpa, .script = script };
    }

    pub fn deinit(self: *FakeTransport) void {
        for (self.requests.items) |r| {
            self.gpa.free(r.url);
            if (r.bearer) |b| self.gpa.free(b);
            if (r.body) |b| self.gpa.free(b);
            freeHeaders(self.gpa, r.headers);
            self.gpa.free(r.headers);
        }
        self.requests.deinit(self.gpa);
        for (self.stream_requests.items) |r| {
            self.gpa.free(r.url);
            if (r.bearer) |b| self.gpa.free(b);
            if (r.content_type) |c| self.gpa.free(c);
            self.gpa.free(r.body_prefix);
            freeHeaders(self.gpa, r.headers);
            self.gpa.free(r.headers);
        }
        self.stream_requests.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn transport(self: *FakeTransport) Transport {
        return .{ .ptr = self, .vtable = &.{ .send = send, .sendStream = sendStream } };
    }

    /// The request at `index`, failing the test when there is none.
    pub fn request(self: *const FakeTransport, index: usize) !Recorded {
        if (index >= self.requests.items.len) {
            std.debug.print("expected request {d}, saw {d}\n", .{ index, self.requests.items.len });
            return error.TestExpectedRequest;
        }
        return self.requests.items[index];
    }

    /// The streaming request at `index`, failing the test when there is none.
    pub fn streamRequest(self: *const FakeTransport, index: usize) !RecordedStream {
        if (index >= self.stream_requests.items.len) {
            std.debug.print("expected stream request {d}, saw {d}\n", .{ index, self.stream_requests.items.len });
            return error.TestExpectedRequest;
        }
        return self.stream_requests.items[index];
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
                .headers = try copyHeaders(arena, canned.headers),
            },
        };
    }

    fn sendStream(ptr: *anyopaque, req: StreamRequest, arena: Allocator) StreamError!StreamResponse {
        const self: *FakeTransport = @ptrCast(@alignCast(ptr));
        // The body is drained even when the script has run out, as the real
        // transport writes it before it can read any response.
        try self.recordStream(req);
        if (self.next >= self.script.len) return error.HttpProtocolError;
        const reply = self.script[self.next];
        self.next += 1;
        const canned = switch (reply) {
            .fail => |err| return err,
            .respond => |canned| canned,
        };
        if (canned.status < 300) if (req.sink == .writer) {
            const w = req.sink.writer;
            if (canned.cut_after) |cut| {
                w.writeAll(canned.body[0..@min(cut, canned.body.len)]) catch return error.WriteFailed;
                return canned.cut_error;
            }
            // In two pieces, so code that assumes one delivery shows itself.
            const half = canned.body.len / 2;
            w.writeAll(canned.body[0..half]) catch return error.WriteFailed;
            w.writeAll(canned.body[half..]) catch return error.WriteFailed;
            return .{
                .status = canned.status,
                .headers = try copyHeaders(arena, canned.headers),
                .bytes_streamed = canned.body.len,
            };
        };
        if (canned.cut_after != null) return canned.cut_error;
        return .{
            .status = canned.status,
            .body = try arena.dupe(u8, canned.body),
            .headers = try copyHeaders(arena, canned.headers),
        };
    }

    fn copyHeaders(arena: Allocator, headers: []const Header) Allocator.Error![]const Header {
        const out = try arena.alloc(Header, headers.len);
        for (headers, out) |from, *to| to.* = .{
            .name = try arena.dupe(u8, from.name),
            .value = try arena.dupe(u8, from.value),
        };
        return out;
    }

    /// A deep copy of `headers`, whole or not at all.
    fn dupeHeaders(gpa: Allocator, headers: []const Header) Allocator.Error![]Header {
        const out = try gpa.alloc(Header, headers.len);
        var copied: usize = 0;
        errdefer {
            freeHeaders(gpa, out[0..copied]);
            gpa.free(out);
        }
        for (headers, out) |from, *to| {
            const name = try gpa.dupe(u8, from.name);
            errdefer gpa.free(name);
            to.* = .{ .name = name, .value = try gpa.dupe(u8, from.value) };
            copied += 1;
        }
        return out;
    }

    fn freeHeaders(gpa: Allocator, headers: []const Header) void {
        for (headers) |h| {
            gpa.free(h.name);
            gpa.free(h.value);
        }
    }

    fn record(self: *FakeTransport, req: Request) Allocator.Error!void {
        const url = try self.gpa.dupe(u8, req.url);
        errdefer self.gpa.free(url);
        const bearer = if (req.bearer) |b| try self.gpa.dupe(u8, b) else null;
        errdefer if (bearer) |b| self.gpa.free(b);
        const body = if (req.body) |b| try self.gpa.dupe(u8, b) else null;
        errdefer if (body) |b| self.gpa.free(b);
        const headers = try dupeHeaders(self.gpa, req.headers);
        errdefer {
            freeHeaders(self.gpa, headers);
            self.gpa.free(headers);
        }
        try self.requests.append(self.gpa, .{
            .method = req.method,
            .url = url,
            .bearer = bearer,
            .body = body,
            .content_type = req.content_type,
            .headers = headers,
            .timeout_ms = req.timeout_ms,
        });
    }

    fn recordStream(self: *FakeTransport, req: StreamRequest) error{ OutOfMemory, ReadFailed, EndOfStream }!void {
        const gpa = self.gpa;
        const url = try gpa.dupe(u8, req.url);
        errdefer gpa.free(url);
        const bearer = if (req.bearer) |b| try gpa.dupe(u8, b) else null;
        errdefer if (bearer) |b| gpa.free(b);
        const content_type = if (req.content_type) |c| try gpa.dupe(u8, c) else null;
        errdefer if (content_type) |c| gpa.free(c);
        const headers = try dupeHeaders(gpa, req.headers);
        errdefer {
            freeHeaders(gpa, headers);
            gpa.free(headers);
        }

        var prefix: std.ArrayList(u8) = .empty;
        errdefer prefix.deinit(gpa);
        var crc: Crc32c = .init();
        var body_len: u64 = 0;
        switch (req.body) {
            .none => {},
            .segments => |segments| for (segments) |s| {
                crc.update(s);
                body_len += s.len;
                if (prefix.items.len < self.max_recorded_body) {
                    const keep = @min(s.len, self.max_recorded_body - prefix.items.len);
                    try prefix.appendSlice(gpa, s[0..keep]);
                }
            },
            .stream => |source| {
                // Drain exactly the declared length, as the real transport
                // sends it; a short reader fails the same way.
                var buf: [4096]u8 = undefined;
                var left = source.len;
                while (left > 0) {
                    const want: usize = @intCast(@min(left, buf.len));
                    const n = source.reader.readSliceShort(buf[0..want]) catch return error.ReadFailed;
                    if (n == 0) return error.EndOfStream;
                    crc.update(buf[0..n]);
                    if (prefix.items.len < self.max_recorded_body) {
                        const keep = @min(n, self.max_recorded_body - prefix.items.len);
                        try prefix.appendSlice(gpa, buf[0..keep]);
                    }
                    body_len += n;
                    left -= n;
                }
            },
        }

        const body_prefix = try prefix.toOwnedSlice(gpa);
        errdefer gpa.free(body_prefix);
        try self.stream_requests.append(gpa, .{
            .method = req.method,
            .url = url,
            .bearer = bearer,
            .content_type = content_type,
            .headers = headers,
            .body_prefix = body_prefix,
            .body_len = body_len,
            .body_crc32c = crc.final(),
            .body_tag = req.body,
            .sink = req.sink,
            .accept_encoding = req.accept_encoding,
            .timeout_ms = req.timeout_ms,
        });
    }
};

/// Accepts connections on 127.0.0.1 and answers each request with the next
/// scripted raw HTTP response. Records the raw requests it saw.
pub const ScriptedServer = struct {
    server: std.Io.net.Server,
    port: u16,
    /// Raw bytes to write per request; a connection closes after its last reply.
    replies: []const []const u8,
    /// Replies per connection before the server closes it.
    per_connection: usize = 1,
    /// When set, the server reads the request and never answers.
    hang: bool = false,
    /// When set, the server closes its first connection without reading.
    close_on_accept: bool = false,
    /// How long to hold a connection open after its last reply.
    linger_ms: i64 = 0,
    seen: [8][2048]u8 = undefined,
    seen_len: [8]usize = @splat(0),
    /// Per request: the length and CRC-32C of the whole body, however much
    /// of it fit in `seen`. Streaming uploads are asserted through these.
    seen_body_len: [8]u64 = @splat(0),
    seen_body_crc: [8]u32 = @splat(0),
    seen_count: usize = 0,
    connections: usize = 0,

    pub fn start(io: std.Io, replies: []const []const u8) !ScriptedServer {
        return startOn(io, .{ .ip4 = .loopback(0) }, replies);
    }

    pub fn startOn(io: std.Io, address: std.Io.net.IpAddress, replies: []const []const u8) !ScriptedServer {
        const server = try address.listen(io, .{ .reuse_address = true });
        return .{
            .server = server,
            .port = server.socket.address.getPort(),
            .replies = replies,
        };
    }

    pub fn deinit(s: *ScriptedServer, io: std.Io) void {
        s.server.deinit(io);
    }

    pub fn url(s: *const ScriptedServer, buf: []u8, path: []const u8) []const u8 {
        return std.fmt.bufPrint(buf, "http://127.0.0.1:{d}{s}", .{ s.port, path }) catch unreachable;
    }

    pub fn request(s: *const ScriptedServer, index: usize) []const u8 {
        return s.seen[index][0..s.seen_len[index]];
    }

    /// Serves every scripted reply, then returns.
    pub fn run(s: *ScriptedServer, io: std.Io) !void {
        if (s.close_on_accept) {
            const stream = try s.server.accept(io);
            s.connections += 1;
            stream.close(io);
            return;
        }
        var next: usize = 0;
        while (next < s.replies.len or s.hang) {
            const stream = try s.server.accept(io);
            defer stream.close(io);
            defer if (s.linger_ms > 0) io.sleep(.fromMilliseconds(s.linger_ms), .awake) catch {};
            s.connections += 1;
            var read_buf: [4096]u8 = undefined;
            var reader = stream.reader(io, &read_buf);
            var write_buf: [256]u8 = undefined;
            var writer = stream.writer(io, &write_buf);
            var served: usize = 0;
            while (served < s.per_connection and (next < s.replies.len or s.hang)) : (served += 1) {
                try s.readRequest(&reader.interface);
                if (s.hang) {
                    // Wait until the client gives up; the read fails or ends then.
                    _ = reader.interface.discardRemaining() catch {};
                    return;
                }
                try writer.interface.writeAll(s.replies[next]);
                try writer.interface.flush();
                next += 1;
            }
        }
    }

    fn readRequest(s: *ScriptedServer, r: *std.Io.Reader) !void {
        const slot = s.seen_count % s.seen.len;
        var len: usize = 0;
        var content_length: u64 = 0;
        while (true) {
            const line = try r.takeDelimiterInclusive('\n');
            @memcpy(s.seen[slot][len..][0..line.len], line);
            len += line.len;
            if (std.ascii.startsWithIgnoreCase(line, "content-length:")) {
                const value = std.mem.trim(u8, line["content-length:".len..], " \r\n");
                content_length = try std.fmt.parseInt(u64, value, 10);
            }
            if (std.mem.eql(u8, line, "\r\n")) break;
        }
        // A body larger than the slot is still read whole; what does not fit
        // is captured by the running length and checksum instead.
        var crc: Crc32c = .init();
        var left = content_length;
        while (left > 0) {
            const take: usize = @intCast(@min(left, 1024));
            const bytes = try r.take(take);
            crc.update(bytes);
            const keep = @min(bytes.len, s.seen[slot].len - len);
            @memcpy(s.seen[slot][len..][0..keep], bytes[0..keep]);
            len += keep;
            left -= bytes.len;
        }
        s.seen_len[slot] = len;
        s.seen_body_len[slot] = content_length;
        s.seen_body_crc[slot] = crc.final();
        s.seen_count += 1;
    }
};

/// An allocator that counts the blocks that were not all zeros when freed,
/// to test code that must wipe secrets. Such code should free with `rawFree`
/// after wiping: `Allocator.free` overwrites memory with a debug pattern in
/// safe builds, which would hide a missing wipe.
pub const WipeChecker = struct {
    child: Allocator,
    frees: usize = 0,
    unwiped: usize = 0,

    pub fn allocator(self: *WipeChecker) Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    fn fromPtr(ptr: *anyopaque) *WipeChecker {
        return @ptrCast(@alignCast(ptr));
    }

    fn alloc(ptr: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
        return fromPtr(ptr).child.rawAlloc(len, alignment, ret_addr);
    }

    fn resize(ptr: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
        return fromPtr(ptr).child.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(ptr: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        return fromPtr(ptr).child.rawRemap(memory, alignment, new_len, ret_addr);
    }

    fn free(ptr: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
        const self = fromPtr(ptr);
        self.frees += 1;
        if (!std.mem.allEqual(u8, memory, 0)) self.unwiped += 1;
        self.child.rawFree(memory, alignment, ret_addr);
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

test "FakeTransport records the headers a request carried" {
    var fake: FakeTransport = .init(std.testing.allocator, &.{.{ .respond = .{} }});
    defer fake.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    // The caller's headers may be gone by the time the test looks.
    var name: [15]u8 = "Metadata-Flavor".*;
    var value: [6]u8 = "Google".*;
    _ = try fake.transport().send(.{
        .method = .GET,
        .url = "http://x/computeMetadata/v1/",
        .headers = &.{.{ .name = &name, .value = &value }},
    }, arena.allocator());
    @memset(&name, 'x');
    @memset(&value, 'x');

    const sent = try fake.request(0);
    try std.testing.expectEqualStrings("Google", sent.header("metadata-flavor").?);
    try std.testing.expectEqual(null, sent.header("x-goog-user-project"));
}

test "FakeTransport records streaming requests, prefix and checksum" {
    var fake: FakeTransport = .init(std.testing.allocator, &.{
        .{ .respond = .{ .status = 200, .body = "{\"name\":\"o\"}" } },
        .{ .respond = .{ .status = 308, .headers = &.{.{ .name = "Range", .value = "bytes=0-99" }} } },
    });
    defer fake.deinit();
    fake.max_recorded_body = 16;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const t = fake.transport();

    // A reader body longer than the recorded prefix.
    var data: [100]u8 = undefined;
    for (&data, 0..) |*b, i| b.* = @intCast(i);
    var reader: std.Io.Reader = .fixed(&data);
    const first = try t.sendStream(.{
        .method = .PUT,
        .url = "http://x/upload",
        .content_type = "application/octet-stream",
        .body = .{ .stream = .{ .reader = &reader, .len = data.len } },
    }, arena.allocator());
    try std.testing.expectEqual(200, first.status);
    try std.testing.expectEqualStrings("{\"name\":\"o\"}", first.body);

    const put = try fake.streamRequest(0);
    try std.testing.expectEqualStrings("http://x/upload", put.url);
    try std.testing.expectEqualStrings("application/octet-stream", put.content_type.?);
    try std.testing.expectEqual(.stream, put.body_tag);
    try std.testing.expectEqualSlices(u8, data[0..16], put.body_prefix);
    try std.testing.expectEqual(100, put.body_len);
    try std.testing.expectEqual(Crc32c.hash(&data), put.body_crc32c);

    // Segments are assembled the same way, and reply headers come through.
    const second = try t.sendStream(.{
        .method = .PUT,
        .url = "http://x/session",
        .headers = &.{.{ .name = "Content-Range", .value = "bytes */100" }},
        .body = .{ .segments = &.{ "ab", "cd" } },
    }, arena.allocator());
    try std.testing.expectEqual(308, second.status);
    try std.testing.expectEqualStrings("bytes=0-99", second.header("range").?);
    const query = try fake.streamRequest(1);
    try std.testing.expectEqual(.segments, query.body_tag);
    try std.testing.expectEqualStrings("abcd", query.body_prefix);
    try std.testing.expectEqualStrings("bytes */100", query.header("content-range").?);
}

test "FakeTransport writes a success into the sink writer, and can cut it short" {
    var fake: FakeTransport = .init(std.testing.allocator, &.{
        .{ .respond = .{ .status = 200, .body = "hello world\n", .headers = &.{.{ .name = "x-goog-generation", .value = "9" }} } },
        .{ .respond = .{ .status = 200, .body = "hello world\n", .cut_after = 5 } },
        .{ .respond = .{ .status = 404, .body = "{\"error\":{}}" } },
    });
    defer fake.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const t = fake.transport();

    var out_buf: [64]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    const whole = try t.sendStream(.{ .method = .GET, .url = "http://x/o", .sink = .{ .writer = &out } }, arena.allocator());
    try std.testing.expectEqualStrings("hello world\n", out.buffered());
    try std.testing.expectEqual(12, whole.bytes_streamed);
    try std.testing.expectEqualStrings("", whole.body);
    try std.testing.expectEqualStrings("9", whole.header("x-goog-generation").?);

    // A cut delivers a prefix and then fails, like a dropped connection.
    out = .fixed(&out_buf);
    try std.testing.expectError(
        error.ConnectionResetByPeer,
        t.sendStream(.{ .method = .GET, .url = "http://x/o", .sink = .{ .writer = &out } }, arena.allocator()),
    );
    try std.testing.expectEqualStrings("hello", out.buffered());

    // An error body never reaches the writer.
    out = .fixed(&out_buf);
    const failed = try t.sendStream(.{ .method = .GET, .url = "http://x/o", .sink = .{ .writer = &out } }, arena.allocator());
    try std.testing.expectEqual(404, failed.status);
    try std.testing.expectEqualStrings("{\"error\":{}}", failed.body);
    try std.testing.expectEqualStrings("", out.buffered());
}

fn segmentsProperty(_: void, input: []const u8) !void {
    var g: ByteGen = .init(input);
    // Any split of a body into segments records the same length and
    // checksum as the whole, whether it arrives as segments or as a reader.
    var segments: [5][]const u8 = undefined;
    const count = g.intRange(usize, 0, segments.len);
    var whole: std.ArrayList(u8) = .empty;
    defer whole.deinit(std.testing.allocator);
    for (segments[0..count]) |*s| {
        s.* = g.slice(48);
        try whole.appendSlice(std.testing.allocator, s.*);
    }

    var fake: FakeTransport = .init(std.testing.allocator, &.{ .{ .respond = .{} }, .{ .respond = .{} } });
    defer fake.deinit();
    fake.max_recorded_body = 8;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    _ = try fake.transport().sendStream(.{
        .method = .POST,
        .url = "http://x/upload",
        .body = .{ .segments = segments[0..count] },
    }, arena.allocator());
    var reader: std.Io.Reader = .fixed(whole.items);
    _ = try fake.transport().sendStream(.{
        .method = .PUT,
        .url = "http://x/upload",
        .body = .{ .stream = .{ .reader = &reader, .len = whole.items.len } },
    }, arena.allocator());

    const expected_crc = Crc32c.hash(whole.items);
    const cap = @min(whole.items.len, fake.max_recorded_body);
    for (0..2) |i| {
        const rec = try fake.streamRequest(i);
        try std.testing.expectEqual(whole.items.len, rec.body_len);
        try std.testing.expectEqual(expected_crc, rec.body_crc32c);
        try std.testing.expectEqualSlices(u8, whole.items[0..cap], rec.body_prefix);
    }
}

test "fuzz FakeTransport: segment splits never change the recorded body" {
    try fuzzBytes({}, segmentsProperty, .{ .corpus = &.{
        "\x00\x00\x00\x00\x00\x00\x00\x03\x00\x00\x00\x00\x00\x00\x00\x05hello\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x06world!",
        "\x00\x00\x00\x00\x00\x00\x00\x00",
    } });
}

test "FakeTransport: a short reader is EndOfStream, and a spent script fails loudly" {
    var fake: FakeTransport = .init(std.testing.allocator, &.{});
    defer fake.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var reader: std.Io.Reader = .fixed("short");
    try std.testing.expectError(error.EndOfStream, fake.transport().sendStream(.{
        .method = .PUT,
        .url = "http://x/upload",
        .body = .{ .stream = .{ .reader = &reader, .len = 100 } },
    }, arena.allocator()));
    // A short body means the request never completed, so nothing is kept.
    try std.testing.expectEqual(0, fake.stream_requests.items.len);
    var empty: std.Io.Reader = .fixed("ab");
    try std.testing.expectError(error.HttpProtocolError, fake.transport().sendStream(.{
        .method = .PUT,
        .url = "http://x/upload",
        .body = .{ .stream = .{ .reader = &empty, .len = 2 } },
    }, arena.allocator()));
    try std.testing.expectEqual(1, fake.stream_requests.items.len);
}
