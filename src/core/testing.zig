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
        // The head is visible before any body byte, as the real transport
        // delivers it, so a cut mid-body still leaves the headers readable.
        if (req.head_out) |out| out.* = .{
            .status = canned.status,
            .headers = try copyHeaders(arena, canned.headers),
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

/// Wraps another `Transport` and breaks the requests its plan names, the way
/// a failing network does: a request body cut off partway, a response body
/// cut off partway, or a response lost after the server acted on it. Every
/// other request passes through untouched. Each fault reaches the caller as
/// a dropped connection, `error.ConnectionResetByPeer`, just as the real
/// thing would. Over `HttpTransport` the faults are real: the connection
/// closes with the body unfinished, so the server sees what a failed network
/// would show it, and a test proves recovery against a real server rather
/// than a fake's idea of one. It can also record every exchange, so a test
/// can check what went over the wire.
pub const FaultTransport = struct {
    inner: Transport,
    /// The faults to inject. Each applies to one request at most.
    plan: []Fault = &.{},
    /// Runs after a fault fires, before the failure reaches the caller: the
    /// moment between the two halves of a transfer that will resume.
    after_fault: ?Hook = null,
    /// When set, every exchange is copied into `exchanges` with this
    /// allocator, and `deinit` frees them.
    record: ?Allocator = null,
    exchanges: std.ArrayList(Exchange) = .empty,

    /// One request to break: the `skip`+1th that matches. When two faults
    /// match the same request, the earlier one in the plan applies to it.
    pub const Fault = struct {
        method: Method,
        /// Only requests whose URL contains this; empty matches any URL.
        url_contains: []const u8 = "",
        /// Matching requests to let through before this one applies.
        skip: u32 = 0,
        action: Action,
        /// Matching requests seen so far.
        seen: u32 = 0,
        /// Whether the fault broke the request it applied to. A response
        /// that ends before the cut, or a response that is not a success
        /// and so never reaches a writer, arrives whole, and the fault is
        /// spent without firing.
        fired: bool = false,
    };

    pub const Action = union(enum) {
        /// Send the first N bytes of a streaming request's body, then close
        /// the connection. Only a request whose body is longer than N
        /// matches. The transport may still hold the last few kilobytes
        /// before N in its buffers, so the server can see fewer.
        cut_request_body: u64,
        /// Deliver the first N bytes of a streamed response body to the
        /// sink, then close the connection. Only a request with a writer
        /// sink matches. The head arrives as usual.
        cut_response_body: u64,
        /// Send the request and read the whole response, then report the
        /// connection dropped before any of it arrived: the server acted,
        /// and the caller cannot know it.
        lose_response,
    };

    pub const Hook = struct {
        context: *anyopaque,
        run: *const fn (context: *anyopaque, fault: *const Fault) void,
    };

    /// One request and what came of it, deep-copied.
    pub const Exchange = struct {
        method: Method,
        url: []u8,
        /// The headers the caller passed, not the ones the transport adds.
        headers: []Header,
        /// The whole body's length, however much of it a fault let through.
        body_len: u64,
        /// What the server answered, when a head arrived, even where a
        /// fault kept it from the caller.
        status: ?u16,
        response_headers: []Header,
        /// What the caller got instead of a response, if anything.
        err: ?StreamError,
        /// The plan index of the fault that fired on this exchange.
        fault: ?usize,

        /// The value the request sent for `name`, matched as HTTP matches
        /// names, or null.
        pub fn header(self: Exchange, name: []const u8) ?[]const u8 {
            for (self.headers) |h| if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
            return null;
        }

        /// The value the response sent for `name`, or null.
        pub fn responseHeader(self: Exchange, name: []const u8) ?[]const u8 {
            for (self.response_headers) |h| if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
            return null;
        }
    };

    pub fn deinit(self: *FaultTransport) void {
        if (self.record) |gpa| {
            for (self.exchanges.items) |e| {
                gpa.free(e.url);
                FakeTransport.freeHeaders(gpa, e.headers);
                gpa.free(e.headers);
                FakeTransport.freeHeaders(gpa, e.response_headers);
                gpa.free(e.response_headers);
            }
            self.exchanges.deinit(gpa);
        }
        self.* = undefined;
    }

    pub fn transport(self: *FaultTransport) Transport {
        return .{ .ptr = self, .vtable = &.{ .send = send, .sendStream = sendStream } };
    }

    /// A buffered request can only lose its response: its bodies never
    /// stream.
    fn send(ptr: *anyopaque, req: Request, arena: Allocator) TransportError!Response {
        const self: *FaultTransport = @ptrCast(@alignCast(ptr));
        const body_len: u64 = if (req.body) |b| b.len else 0;
        const claimed = self.claim(req.method, req.url, body_len, .buffered);
        const loses = if (claimed) |i| self.plan[i].action == .lose_response else false;
        const outcome = self.inner.send(req, arena);
        const fired = loses and !std.meta.isError(outcome);
        const res: ?Response = outcome catch null;
        const result: TransportError!Response = if (fired) error.ConnectionResetByPeer else outcome;
        try self.remember(.{
            .method = req.method,
            .url = req.url,
            .headers = req.headers,
            .body_len = body_len,
            .status = if (res) |r| r.status else null,
            .response_headers = if (res) |r| r.headers else &.{},
            .err = if (result) |_| null else |err| err,
            .fault = if (fired) claimed else null,
        });
        if (fired) self.fire(claimed.?);
        return result;
    }

    fn sendStream(ptr: *anyopaque, req: StreamRequest, arena: Allocator) StreamError!StreamResponse {
        const self: *FaultTransport = @ptrCast(@alignCast(ptr));
        const body_len = bodyLength(req.body);
        const claimed = self.claim(req.method, req.url, body_len, if (req.sink == .writer) .streamed else .stream_buffered);
        const action: ?Action = if (claimed) |i| self.plan[i].action else null;

        // The head is taken here first, so it is recorded even when the
        // body then fails.
        var head: ?StreamRequest.Head = null;
        var sent = req;
        sent.head_out = &head;
        var cut_reader: CutReader = undefined;
        var cut_writer: CutWriter = undefined;
        var discard_buf: [4096]u8 = undefined;
        var discarding: std.Io.Writer.Discarding = .init(&discard_buf);
        if (action) |a| switch (a) {
            .cut_request_body => |n| {
                cut_reader = .init(req.body, n);
                sent.body = .{ .stream = .{ .reader = &cut_reader.interface, .len = body_len } };
            },
            .cut_response_body => |n| {
                cut_writer = .init(req.sink.writer, n);
                sent.sink = .{ .writer = &cut_writer.writer };
            },
            .lose_response => if (req.sink == .writer) {
                sent.sink = .{ .writer = &discarding.writer };
            },
        };

        const outcome = self.inner.sendStream(sent, arena);
        const fired = if (action) |a| switch (a) {
            .cut_request_body => cut_reader.tripped,
            .cut_response_body => cut_writer.tripped,
            .lose_response => !std.meta.isError(outcome),
        } else false;
        const result: StreamError!StreamResponse = if (fired) error.ConnectionResetByPeer else outcome;
        // A lost response never showed the caller its head.
        const lost = fired and action.? == .lose_response;
        if (!lost) if (req.head_out) |out| if (head) |h| {
            out.* = h;
        };

        try self.remember(.{
            .method = req.method,
            .url = req.url,
            .headers = req.headers,
            .body_len = body_len,
            .status = if (head) |h| h.status else null,
            .response_headers = if (head) |h| h.headers else &.{},
            .err = if (result) |_| null else |err| err,
            .fault = if (fired) claimed else null,
        });
        if (fired) self.fire(claimed.?);
        return result;
    }

    /// How a request's response is delivered, which decides what can match.
    const Delivery = enum { buffered, stream_buffered, streamed };

    /// The plan index of the fault this request is the turn of, counting
    /// the request against every fault it matches.
    fn claim(self: *FaultTransport, method: Method, url: []const u8, body_len: u64, delivery: Delivery) ?usize {
        var claimed: ?usize = null;
        for (self.plan, 0..) |*fault, i| {
            if (fault.method != method) continue;
            if (std.mem.indexOf(u8, url, fault.url_contains) == null) continue;
            const matches = switch (fault.action) {
                .cut_request_body => |n| delivery != .buffered and body_len > n,
                .cut_response_body => delivery == .streamed,
                .lose_response => true,
            };
            if (!matches) continue;
            const turn = fault.seen;
            fault.seen += 1;
            if (turn == fault.skip and claimed == null) claimed = i;
        }
        return claimed;
    }

    fn fire(self: *FaultTransport, index: usize) void {
        self.plan[index].fired = true;
        if (self.after_fault) |hook| hook.run(hook.context, &self.plan[index]);
    }

    const Seen = struct {
        method: Method,
        url: []const u8,
        headers: []const Header,
        body_len: u64,
        status: ?u16,
        response_headers: []const Header,
        err: ?StreamError,
        fault: ?usize,
    };

    fn remember(self: *FaultTransport, seen: Seen) Allocator.Error!void {
        const gpa = self.record orelse return;
        const url = try gpa.dupe(u8, seen.url);
        errdefer gpa.free(url);
        const headers = try FakeTransport.dupeHeaders(gpa, seen.headers);
        errdefer {
            FakeTransport.freeHeaders(gpa, headers);
            gpa.free(headers);
        }
        const response_headers = try FakeTransport.dupeHeaders(gpa, seen.response_headers);
        errdefer {
            FakeTransport.freeHeaders(gpa, response_headers);
            gpa.free(response_headers);
        }
        try self.exchanges.append(gpa, .{
            .method = seen.method,
            .url = url,
            .headers = headers,
            .body_len = seen.body_len,
            .status = seen.status,
            .response_headers = response_headers,
            .err = seen.err,
            .fault = seen.fault,
        });
    }

    fn bodyLength(body: StreamRequest.Body) u64 {
        return switch (body) {
            .none => 0,
            .segments => |segments| n: {
                var total: u64 = 0;
                for (segments) |s| total += s.len;
                break :n total;
            },
            .stream => |source| source.len,
        };
    }

    /// Replays a request body and fails once `left` bytes have gone out,
    /// the way a connection that drops partway through an upload stops it.
    const CutReader = struct {
        body: StreamRequest.Body,
        /// Where the next segment byte comes from.
        segment: usize = 0,
        offset: usize = 0,
        /// Bytes still allowed out.
        left: u64,
        tripped: bool = false,
        interface: std.Io.Reader,

        fn init(body: StreamRequest.Body, cut_after: u64) CutReader {
            return .{
                .body = body,
                .left = cut_after,
                .interface = .{ .vtable = &.{ .stream = stream }, .buffer = &.{}, .seek = 0, .end = 0 },
            };
        }

        fn stream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
            const self: *CutReader = @alignCast(@fieldParentPtr("interface", r));
            if (self.left == 0) {
                self.tripped = true;
                return error.ReadFailed;
            }
            const allowed = limit.min(.limited64(self.left));
            const n = switch (self.body) {
                .none => return error.EndOfStream,
                .segments => |segments| n: {
                    while (self.segment < segments.len and self.offset == segments[self.segment].len) {
                        self.segment += 1;
                        self.offset = 0;
                    }
                    if (self.segment == segments.len) return error.EndOfStream;
                    const written = try w.write(allowed.sliceConst(segments[self.segment][self.offset..]));
                    self.offset += written;
                    break :n written;
                },
                // The caller's own reader failing is theirs, not a cut.
                .stream => |source| try source.reader.stream(w, allowed),
            };
            self.left -= n;
            return n;
        }
    };

    /// Passes a response body on to the caller's writer and fails once
    /// `left` bytes have gone through, the way a connection that drops
    /// partway through a download stops it. It has no buffer, so whatever
    /// it accepted has reached the caller's writer.
    const CutWriter = struct {
        out: *std.Io.Writer,
        left: u64,
        tripped: bool = false,
        writer: std.Io.Writer,

        fn init(out: *std.Io.Writer, cut_after: u64) CutWriter {
            return .{
                .out = out,
                .left = cut_after,
                .writer = .{ .buffer = &.{}, .vtable = &.{ .drain = drain } },
            };
        }

        fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
            const self: *CutWriter = @alignCast(@fieldParentPtr("writer", w));
            var consumed: usize = 0;
            for (data, 0..) |bytes, i| {
                const repeats = if (i == data.len - 1) splat else 1;
                for (0..repeats) |_| {
                    const n: usize = @intCast(@min(bytes.len, self.left));
                    // The caller's own writer failing is theirs, not a cut.
                    try self.out.writeAll(bytes[0..n]);
                    consumed += n;
                    self.left -= n;
                    if (n < bytes.len) {
                        if (consumed > 0) return consumed;
                        self.tripped = true;
                        return error.WriteFailed;
                    }
                }
            }
            return consumed;
        }
    };
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

test "FakeTransport delivers the head before the body, cut or not" {
    var fake: FakeTransport = .init(std.testing.allocator, &.{
        .{ .respond = .{
            .status = 200,
            .body = "hello world\n",
            .headers = &.{.{ .name = "x-goog-generation", .value = "7" }},
            .cut_after = 5,
        } },
        .{ .fail = error.ConnectionRefused },
    });
    defer fake.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var out_buf: [64]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    var head: ?StreamRequest.Head = null;
    _ = fake.transport().sendStream(.{
        .method = .GET,
        .url = "http://x/o",
        .sink = .{ .writer = &out },
        .head_out = &head,
    }, arena.allocator()) catch {};
    try std.testing.expectEqual(200, head.?.status);
    try std.testing.expectEqualStrings("7", head.?.header("x-goog-generation").?);
    try std.testing.expectEqualStrings("hello", out.buffered());

    // A transport failure leaves it null.
    var none: ?StreamRequest.Head = null;
    _ = fake.transport().sendStream(.{
        .method = .GET,
        .url = "http://x/o",
        .head_out = &none,
    }, arena.allocator()) catch {};
    try std.testing.expectEqual(null, none);
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

test "FaultTransport passes requests through and records both sides" {
    const gpa = std.testing.allocator;
    var fake: FakeTransport = .init(gpa, &.{
        .{ .respond = .{ .status = 200, .body = "{\"a\":1}", .headers = &.{.{ .name = "x-goog-generation", .value = "5" }} } },
        .{ .respond = .{ .status = 404, .body = "{}" } },
    });
    defer fake.deinit();
    var faults: FaultTransport = .{ .inner = fake.transport(), .record = gpa };
    defer faults.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const t = faults.transport();

    const got = try t.send(.{
        .method = .GET,
        .url = "http://x/a",
        .headers = &.{.{ .name = "X-Test", .value = "1" }},
    }, arena.allocator());
    try std.testing.expectEqual(200, got.status);
    try std.testing.expectEqualStrings("{\"a\":1}", got.body);
    const put = try t.sendStream(.{
        .method = .PUT,
        .url = "http://x/b",
        .body = .{ .segments = &.{ "ab", "cd" } },
    }, arena.allocator());
    try std.testing.expectEqual(404, put.status);

    // The inner transport saw both exactly as they were sent.
    try std.testing.expectEqualStrings("http://x/a", (try fake.request(0)).url);
    try std.testing.expectEqualStrings("abcd", (try fake.streamRequest(0)).body_prefix);

    try std.testing.expectEqual(2, faults.exchanges.items.len);
    const first = faults.exchanges.items[0];
    try std.testing.expectEqual(.GET, first.method);
    try std.testing.expectEqualStrings("http://x/a", first.url);
    try std.testing.expectEqualStrings("1", first.header("x-test").?);
    try std.testing.expectEqual(200, first.status.?);
    try std.testing.expectEqualStrings("5", first.responseHeader("X-Goog-Generation").?);
    try std.testing.expectEqual(null, first.err);
    try std.testing.expectEqual(null, first.fault);
    const second = faults.exchanges.items[1];
    try std.testing.expectEqual(4, second.body_len);
    try std.testing.expectEqual(404, second.status.?);
}

test "FaultTransport cuts the request body it names, and only that one" {
    const gpa = std.testing.allocator;
    var fake: FakeTransport = .init(gpa, &.{
        .{ .respond = .{ .status = 308 } },
        .{ .respond = .{ .status = 308 } },
        .{ .respond = .{ .status = 200 } },
        .{ .respond = .{ .status = 200 } },
    });
    defer fake.deinit();
    var plan = [_]FaultTransport.Fault{.{
        .method = .PUT,
        .url_contains = "upload_id=",
        .skip = 1,
        .action = .{ .cut_request_body = 5 },
    }};
    var faults: FaultTransport = .{ .inner = fake.transport(), .plan = &plan, .record = gpa };
    defer faults.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const t = faults.transport();
    const session = "http://x/s?upload_id=1";

    // The first chunk is the turn skipped.
    _ = try t.sendStream(.{ .method = .PUT, .url = session, .body = .{ .segments = &.{"0123456789"} } }, a);
    // Another URL is not a turn, and neither is a status query, whose
    // empty body is no longer than the cut.
    _ = try t.sendStream(.{ .method = .PUT, .url = "http://x/other", .body = .{ .segments = &.{"0123456789"} } }, a);
    _ = try t.sendStream(.{ .method = .PUT, .url = session, .body = .{ .segments = &.{} } }, a);
    try std.testing.expect(!plan[0].fired);

    // The second chunk stops after five bytes, across a segment boundary,
    // and the caller sees a dropped connection.
    try std.testing.expectError(error.ConnectionResetByPeer, t.sendStream(.{
        .method = .PUT,
        .url = session,
        .body = .{ .segments = &.{ "0123", "456789" } },
    }, a));
    try std.testing.expect(plan[0].fired);
    // A body that stops short is no request: the fake never recorded it.
    try std.testing.expectEqual(3, fake.stream_requests.items.len);

    // The fault is spent: the resend goes through.
    _ = try t.sendStream(.{ .method = .PUT, .url = session, .body = .{ .segments = &.{"0123456789"} } }, a);
    try std.testing.expectEqual(4, fake.stream_requests.items.len);
    try std.testing.expectEqualStrings("0123456789", (try fake.streamRequest(3)).body_prefix);

    const cut = faults.exchanges.items[3];
    try std.testing.expectEqual(10, cut.body_len);
    try std.testing.expectEqual(error.ConnectionResetByPeer, cut.err.?);
    try std.testing.expectEqual(0, cut.fault.?);
    try std.testing.expectEqual(null, cut.status);
}

test "FaultTransport cuts a reader-backed body; the reader's own failure stays its own" {
    const gpa = std.testing.allocator;
    var fake: FakeTransport = .init(gpa, &.{});
    defer fake.deinit();
    var plan = [_]FaultTransport.Fault{
        .{ .method = .PUT, .action = .{ .cut_request_body = 3 } },
        .{ .method = .POST, .action = .{ .cut_request_body = 3 } },
    };
    var faults: FaultTransport = .{ .inner = fake.transport(), .plan = &plan };
    defer faults.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const t = faults.transport();

    var reader: std.Io.Reader = .fixed("abcdefgh");
    try std.testing.expectError(error.ConnectionResetByPeer, t.sendStream(.{
        .method = .PUT,
        .url = "http://x/u",
        .body = .{ .stream = .{ .reader = &reader, .len = 8 } },
    }, arena.allocator()));
    try std.testing.expect(plan[0].fired);
    // Exactly the three bytes the cut allowed left the reader.
    try std.testing.expectEqualStrings("defgh", reader.buffered());

    // A reader that fails by itself is the caller's failure, as it would be
    // without the wrapper.
    var failing = std.Io.Reader.failing;
    try std.testing.expectError(error.ReadFailed, t.sendStream(.{
        .method = .POST,
        .url = "http://x/u",
        .body = .{ .stream = .{ .reader = &failing, .len = 8 } },
    }, arena.allocator()));
    try std.testing.expect(!plan[1].fired);
}

test "FaultTransport cuts a download partway: the head arrives, the hook runs between the halves" {
    const gpa = std.testing.allocator;
    var fake: FakeTransport = .init(gpa, &.{
        .{ .respond = .{ .body = "buffered" } },
        .{ .respond = .{ .body = "buffered too" } },
        .{ .respond = .{ .body = "hello world\n", .headers = &.{.{ .name = "x-goog-generation", .value = "7" }} } },
        .{ .respond = .{ .status = 206, .body = " world\n" } },
    });
    defer fake.deinit();
    var plan = [_]FaultTransport.Fault{.{
        .method = .GET,
        .url_contains = "alt=media",
        .action = .{ .cut_response_body = 5 },
    }};
    const Between = struct {
        runs: u32 = 0,
        fired_when_run: bool = false,

        fn run(context: *anyopaque, fault: *const FaultTransport.Fault) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.runs += 1;
            self.fired_when_run = fault.fired;
        }
    };
    var between: Between = .{};
    var faults: FaultTransport = .{
        .inner = fake.transport(),
        .plan = &plan,
        .after_fault = .{ .context = &between, .run = Between.run },
        .record = gpa,
    };
    defer faults.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const t = faults.transport();

    // A response cut needs a writer to cut: requests to the same URL whose
    // bodies are buffered pass untouched, and are not turns.
    const buffered = try t.send(.{ .method = .GET, .url = "http://x/o?alt=media" }, arena.allocator());
    try std.testing.expectEqualStrings("buffered", buffered.body);
    const stream_buffered = try t.sendStream(.{ .method = .GET, .url = "http://x/o?alt=media" }, arena.allocator());
    try std.testing.expectEqualStrings("buffered too", stream_buffered.body);
    try std.testing.expect(!plan[0].fired);

    var out_buf: [64]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    var head: ?StreamRequest.Head = null;
    try std.testing.expectError(error.ConnectionResetByPeer, t.sendStream(.{
        .method = .GET,
        .url = "http://x/o?alt=media",
        .sink = .{ .writer = &out },
        .head_out = &head,
    }, arena.allocator()));
    // Exactly the bytes before the cut reached the caller's writer, and
    // the head had arrived before the body failed, as on a real cut.
    try std.testing.expectEqualStrings("hello", out.buffered());
    try std.testing.expectEqual(200, head.?.status);
    try std.testing.expectEqualStrings("7", head.?.header("x-goog-generation").?);
    try std.testing.expectEqual(1, between.runs);
    try std.testing.expect(between.fired_when_run);

    // The resume passes through: the fault is spent, the hook stays quiet.
    const rest = try t.sendStream(.{
        .method = .GET,
        .url = "http://x/o?alt=media",
        .sink = .{ .writer = &out },
    }, arena.allocator());
    try std.testing.expectEqual(206, rest.status);
    try std.testing.expectEqualStrings("hello world\n", out.buffered());
    try std.testing.expectEqual(1, between.runs);

    const cut = faults.exchanges.items[2];
    try std.testing.expectEqual(200, cut.status.?);
    try std.testing.expectEqualStrings("7", cut.responseHeader("x-goog-generation").?);
    try std.testing.expectEqual(error.ConnectionResetByPeer, cut.err.?);
    try std.testing.expectEqual(null, faults.exchanges.items[3].err);
}

test "FaultTransport: a short body, an error body, or the caller's own writer failing is no cut" {
    const gpa = std.testing.allocator;
    var fake: FakeTransport = .init(gpa, &.{
        .{ .respond = .{ .body = "hi" } },
        .{ .respond = .{ .status = 404, .body = "{\"error\":{}}" } },
        .{ .respond = .{ .body = "hello world\n" } },
    });
    defer fake.deinit();
    var plan = [_]FaultTransport.Fault{
        .{ .method = .GET, .url_contains = "/short", .action = .{ .cut_response_body = 5 } },
        .{ .method = .GET, .url_contains = "/missing", .action = .{ .cut_response_body = 0 } },
        .{ .method = .GET, .url_contains = "/big", .action = .{ .cut_response_body = 100 } },
    };
    var faults: FaultTransport = .{ .inner = fake.transport(), .plan = &plan };
    defer faults.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const t = faults.transport();

    // A body that ends before the cut arrives whole, and the fault is spent.
    var out_buf: [64]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    _ = try t.sendStream(.{ .method = .GET, .url = "http://x/short", .sink = .{ .writer = &out } }, arena.allocator());
    try std.testing.expectEqualStrings("hi", out.buffered());
    try std.testing.expect(!plan[0].fired);

    // An error body is buffered and never reaches the writer: nothing to cut.
    const missing = try t.sendStream(.{ .method = .GET, .url = "http://x/missing", .sink = .{ .writer = &out } }, arena.allocator());
    try std.testing.expectEqual(404, missing.status);
    try std.testing.expect(!plan[1].fired);

    // The caller's own writer failing is WriteFailed, as without the wrapper.
    var small_buf: [4]u8 = undefined;
    var small: std.Io.Writer = .fixed(&small_buf);
    try std.testing.expectError(
        error.WriteFailed,
        t.sendStream(.{ .method = .GET, .url = "http://x/big", .sink = .{ .writer = &small } }, arena.allocator()),
    );
    try std.testing.expect(!plan[2].fired);
}

test "FaultTransport loses a response the server sent" {
    const gpa = std.testing.allocator;
    var fake: FakeTransport = .init(gpa, &.{
        .{ .respond = .{ .body = "{\"name\":\"a\",\"generation\":\"3\"}" } },
        .{ .respond = .{ .status = 204, .body = "" } },
        .{ .respond = .{ .body = "hello world\n", .headers = &.{.{ .name = "x-goog-generation", .value = "3" }} } },
    });
    defer fake.deinit();
    var plan = [_]FaultTransport.Fault{
        .{ .method = .POST, .url_contains = "uploadType=multipart", .action = .lose_response },
        .{ .method = .DELETE, .action = .lose_response },
        .{ .method = .GET, .action = .lose_response },
    };
    var faults: FaultTransport = .{ .inner = fake.transport(), .plan = &plan, .record = gpa };
    defer faults.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const t = faults.transport();

    // The upload reached the server, and the caller heard nothing back,
    // not even the head.
    var head: ?StreamRequest.Head = null;
    try std.testing.expectError(error.ConnectionResetByPeer, t.sendStream(.{
        .method = .POST,
        .url = "http://x/upload?uploadType=multipart",
        .body = .{ .segments = &.{"data"} },
        .head_out = &head,
    }, arena.allocator()));
    try std.testing.expectEqual(null, head);
    try std.testing.expectEqual(1, fake.stream_requests.items.len);

    // A buffered call loses its answer the same way.
    try std.testing.expectError(error.ConnectionResetByPeer, t.send(.{ .method = .DELETE, .url = "http://x/o" }, arena.allocator()));
    try std.testing.expectEqual(1, fake.requests.items.len);

    // A download's body never reaches the caller's writer.
    var out_buf: [64]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    try std.testing.expectError(error.ConnectionResetByPeer, t.sendStream(.{
        .method = .GET,
        .url = "http://x/o?alt=media",
        .sink = .{ .writer = &out },
    }, arena.allocator()));
    try std.testing.expectEqualStrings("", out.buffered());

    // The record keeps both what the server said and what the caller got.
    for (faults.exchanges.items, plan, 0..) |e, fault, i| {
        try std.testing.expect(fault.fired);
        try std.testing.expectEqual(i, e.fault.?);
        try std.testing.expectEqual(error.ConnectionResetByPeer, e.err.?);
    }
    try std.testing.expectEqual(200, faults.exchanges.items[0].status.?);
    try std.testing.expectEqual(204, faults.exchanges.items[1].status.?);
    try std.testing.expectEqualStrings("3", faults.exchanges.items[2].responseHeader("x-goog-generation").?);
}

const HttpTransport = @import("transport.zig").HttpTransport;

test "FaultTransport over HttpTransport: the server sees an upload stop partway" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var server: ScriptedServer = try .start(io, &.{"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}"});
    defer server.deinit(io);
    var serving = try io.concurrent(ScriptedServer.run, .{ &server, io });
    defer _ = serving.cancel(io) catch {};

    var ht: HttpTransport = .init(gpa, io, "t");
    defer ht.deinit();
    var plan = [_]FaultTransport.Fault{.{ .method = .PUT, .action = .{ .cut_request_body = 20_000 } }};
    var faults: FaultTransport = .{ .inner = ht.transport(), .plan = &plan };
    defer faults.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var buf: [128]u8 = undefined;
    const data = try gpa.alloc(u8, 64 * 1024);
    defer gpa.free(data);
    @memset(data, 'z');

    // With a timeout, as clients always send one, so the body is read on
    // the transport's own task.
    try std.testing.expectError(error.ConnectionResetByPeer, faults.transport().sendStream(.{
        .method = .PUT,
        .url = server.url(&buf, "/upload"),
        .body = .{ .segments = &.{data} },
        .timeout_ms = 10_000,
    }, arena.allocator()));
    try std.testing.expect(plan[0].fired);
    // The connection ended short of the Content-Length the server was
    // promised, so the server never saw a whole request.
    if (serving.await(io)) |_| {
        return error.TestExpectedServerToSeeACut;
    } else |err| try std.testing.expect(err == error.EndOfStream or err == error.ReadFailed);
    try std.testing.expectEqual(0, server.seen_count);
}

test "FaultTransport over HttpTransport: a download stops partway with the head in hand" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const body_len = 300 * 1024;
    const reply = try gpa.alloc(u8, 128 + body_len);
    defer gpa.free(reply);
    const head_text = try std.fmt.bufPrint(reply, "HTTP/1.1 200 OK\r\nx-goog-generation: 9\r\nContent-Length: {d}\r\n\r\n", .{body_len});
    const payload = reply[head_text.len .. head_text.len + body_len];
    for (payload, 0..) |*b, i| b.* = @intCast(i % 251);

    var server: ScriptedServer = try .start(io, &.{reply[0 .. head_text.len + body_len]});
    defer server.deinit(io);
    // The server may fail writing what the client no longer reads.
    var serving = try io.concurrent(ScriptedServer.run, .{ &server, io });
    defer _ = serving.cancel(io) catch {};

    var ht: HttpTransport = .init(gpa, io, "t");
    defer ht.deinit();
    var plan = [_]FaultTransport.Fault{.{ .method = .GET, .action = .{ .cut_response_body = 100_000 } }};
    var faults: FaultTransport = .{ .inner = ht.transport(), .plan = &plan, .record = gpa };
    defer faults.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var buf: [128]u8 = undefined;
    const got = try gpa.alloc(u8, body_len);
    defer gpa.free(got);
    var out: std.Io.Writer = .fixed(got);
    var head: ?StreamRequest.Head = null;

    try std.testing.expectError(error.ConnectionResetByPeer, faults.transport().sendStream(.{
        .method = .GET,
        .url = server.url(&buf, "/o?alt=media"),
        .sink = .{ .writer = &out },
        .head_out = &head,
        .timeout_ms = 10_000,
    }, arena.allocator()));
    try std.testing.expect(plan[0].fired);
    // Exactly the bytes before the cut, and the right ones.
    try std.testing.expectEqual(100_000, out.buffered().len);
    try std.testing.expectEqualSlices(u8, payload[0..100_000], out.buffered());
    try std.testing.expectEqual(200, head.?.status);
    try std.testing.expectEqualStrings("9", head.?.header("x-goog-generation").?);
    try std.testing.expectEqual(200, faults.exchanges.items[0].status.?);
}

test "FaultTransport over HttpTransport: a lost response still reached the server" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var server: ScriptedServer = try .start(io, &.{"HTTP/1.1 200 OK\r\nContent-Length: 12\r\n\r\n{\"name\":\"a\"}"});
    defer server.deinit(io);
    var serving = try io.concurrent(ScriptedServer.run, .{ &server, io });
    defer _ = serving.cancel(io) catch {};

    var ht: HttpTransport = .init(gpa, io, "t");
    defer ht.deinit();
    var plan = [_]FaultTransport.Fault{.{ .method = .POST, .action = .lose_response }};
    var faults: FaultTransport = .{ .inner = ht.transport(), .plan = &plan };
    defer faults.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var buf: [128]u8 = undefined;

    try std.testing.expectError(error.ConnectionResetByPeer, faults.transport().sendStream(.{
        .method = .POST,
        .url = server.url(&buf, "/upload"),
        .body = .{ .segments = &.{"data"} },
        .timeout_ms = 10_000,
    }, arena.allocator()));
    try std.testing.expect(plan[0].fired);
    // The server read the whole request and answered it.
    try serving.await(io);
    try std.testing.expectEqual(1, server.seen_count);
    try std.testing.expectEqual(4, server.seen_body_len[0]);
}
