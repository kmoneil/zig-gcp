//! The HTTP seam. Every request goes through a `Transport`, so the standard
//! library's HTTP churn stays in this file and tests can substitute a fake.
//! `HttpTransport` is the `std.http.Client` implementation.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const http = std.http;

pub const Method = enum { GET, PUT, POST, DELETE };

pub const Request = struct {
    method: Method,
    /// Absolute URL.
    url: []const u8,
    /// Token for `Authorization: Bearer <token>`; null sends no Authorization header.
    bearer: ?[]const u8 = null,
    /// Sent with the `Content-Type` that `content_type` names. GET and
    /// DELETE never carry a body.
    body: ?[]const u8 = null,
    content_type: ContentType = .json,
    /// Sent after the headers above, in order. A name or value that could
    /// end the header line is `error.InvalidRequestHeader`, never a second
    /// request smuggled into this one.
    headers: []const Header = &.{},
};

/// One header, as `std.http` writes it.
pub const Header = http.Header;

/// RFC 9110 field names: at least one character, all of them token
/// characters, so the name cannot carry a separator or end the line.
pub fn isValidHeaderName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |c| {
        if (std.ascii.isAlphanumeric(c)) continue;
        if (std.mem.indexOfScalar(u8, "!#$%&'*+-.^_`|~", c) == null) return false;
    }
    return true;
}

/// RFC 9110 field values: visible ASCII, space and tab, with no space or
/// tab at either end, where the receiver would strip it anyway. An empty
/// value is legal.
pub fn isValidHeaderValue(value: []const u8) bool {
    for (value) |c| if (c != '\t' and (c < ' ' or c >= 0x7f)) return false;
    if (value.len == 0) return true;
    return !isSpaceOrTab(value[0]) and !isSpaceOrTab(value[value.len - 1]);
}

fn isSpaceOrTab(c: u8) bool {
    return c == ' ' or c == '\t';
}

/// How a request body is encoded.
pub const ContentType = enum {
    json,
    /// `application/x-www-form-urlencoded`, as OAuth token endpoints take.
    form,

    pub fn mediaType(ct: ContentType) []const u8 {
        return switch (ct) {
            .json => "application/json",
            .form => "application/x-www-form-urlencoded",
        };
    }
};

pub const Response = struct {
    /// HTTP status code. Non-2xx statuses are responses, not transport errors.
    status: u16,
    /// The complete body, allocated in the arena passed to `send`.
    body: []const u8,
};

/// Failures below HTTP: no response arrived, or none that can be used.
pub const Error = error{
    /// Nothing is listening at the endpoint.
    ConnectionRefused,
    /// The connection dropped before a complete response arrived.
    ConnectionResetByPeer,
    ConnectionTimedOut,
    /// No route to the network or host.
    NetworkUnreachable,
    /// DNS has no such host.
    UnknownHostName,
    /// The DNS lookup itself failed, possibly temporarily.
    NameServerFailure,
    /// The TLS handshake or certificate validation failed.
    TlsFailure,
    /// The response broke HTTP framing rules.
    HttpProtocolError,
    /// The response body exceeded the read limit.
    ResponseTooLarge,
    /// The URL has an unsupported scheme or no host.
    InvalidEndpoint,
    /// A header on the request has a name or value that HTTP cannot carry.
    InvalidRequestHeader,
    /// Any other operating-system network failure.
    NetworkFailure,
    /// The surrounding `std.Io` task was canceled.
    Canceled,
    OutOfMemory,
};

/// A way to send one HTTP request, in the `std.mem.Allocator` interface shape.
pub const Transport = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Sends `req` and reads the whole response. The response body is
        /// allocated in `arena`.
        send: *const fn (ptr: *anyopaque, req: Request, arena: Allocator) Error!Response,
    };

    pub fn send(self: Transport, req: Request, arena: Allocator) Error!Response {
        return self.vtable.send(self.ptr, req, arena);
    }
};

/// The largest response body read. A 10 MB pull response grows by a third as
/// base64, plus JSON framing, so this leaves headroom above 10 MB.
pub const default_max_response_bytes = 32 * 1024 * 1024;

/// How long std.http's TLS clock reading is trusted before it is reloaded.
pub const tls_clock_max_age: std.Io.Duration = .fromSeconds(60 * 60);

/// A `Transport` over `std.http.Client`: HTTP/1.1, keep-alive, one connection
/// pool. Not safe to share across concurrent tasks.
pub const HttpTransport = struct {
    client: http.Client,
    /// Borrowed; must outlive the transport.
    user_agent: []const u8,
    max_response_bytes: usize = default_max_response_bytes,

    pub fn init(gpa: Allocator, io: std.Io, user_agent: []const u8) HttpTransport {
        return .{ .client = .{ .allocator = gpa, .io = io }, .user_agent = user_agent };
    }

    pub fn deinit(self: *HttpTransport) void {
        self.client.deinit();
        self.* = undefined;
    }

    pub fn transport(self: *HttpTransport) Transport {
        return .{ .ptr = self, .vtable = &.{ .send = send } };
    }

    fn send(ptr: *anyopaque, req: Request, arena: Allocator) Error!Response {
        const self: *HttpTransport = @ptrCast(@alignCast(ptr));
        const uri = std.Uri.parse(req.url) catch return error.InvalidEndpoint;
        const protocol = http.Client.Protocol.fromUri(uri) orelse return error.InvalidEndpoint;
        if (protocol == .tls) self.expireTlsClock(.when_stale);
        return self.exchange(uri, protocol, req, arena) catch |err| {
            // A handshake can fail on a stale clock or CA bundle; the next
            // attempt reloads both.
            if (err == error.TlsFailure) self.expireTlsClock(.now);
            return err;
        };
    }

    /// std.http reads the clock once, at the first HTTPS request, and checks
    /// every later certificate against that reading. Forgetting the reading
    /// makes the next HTTPS request reload the clock and the CA bundle, so a
    /// long-lived client accepts rotated certificates and rejects expired ones.
    fn expireTlsClock(self: *HttpTransport, when: enum { now, when_stale }) void {
        if (http.Client.disable_tls) return;
        const io = self.client.io;
        self.client.ca_bundle_lock.lockUncancelable(io);
        defer self.client.ca_bundle_lock.unlock(io);
        const then = self.client.now orelse return;
        const age = then.durationTo(std.Io.Clock.real.now(io)).nanoseconds;
        if (when == .now or age < 0 or age > tls_clock_max_age.nanoseconds) self.client.now = null;
    }

    fn exchange(
        self: *HttpTransport,
        uri: std.Uri,
        protocol: http.Client.Protocol,
        req: Request,
        arena: Allocator,
    ) Error!Response {
        for (req.headers) |h| {
            if (!isValidHeaderName(h.name) or !isValidHeaderValue(h.value)) return error.InvalidRequestHeader;
        }
        const authorization: ?[]const u8 = if (req.bearer) |token|
            try std.fmt.allocPrint(arena, "Bearer {s}", .{token})
        else
            null;
        const has_body = switch (req.method) {
            .GET, .DELETE => false,
            .PUT, .POST => true,
        };

        // std.http hands an IPv6 literal to the resolver with its brackets
        // ("[::1]"), which finds nothing. The emulator binds [::1] by default,
        // so connect to the bare address and let the request use that
        // connection. Plain HTTP only: std's TLS setup expects its own path.
        const preconnected: ?*http.Client.Connection = if (ipv6Literal(uri)) |address|
            if (protocol == .plain)
                self.client.connectTcp(.{ .bytes = address }, uri.port orelse 80, .plain) catch |err|
                    return mapError(err, null)
            else
                null
        else
            null;

        var request = self.client.request(switch (req.method) {
            .GET => .GET,
            .PUT => .PUT,
            .POST => .POST,
            .DELETE => .DELETE,
        }, uri, .{
            .connection = preconnected,
            .redirect_behavior = .unhandled,
            .headers = .{
                .user_agent = .{ .override = self.user_agent },
                .content_type = if (has_body) .{ .override = req.content_type.mediaType() } else .omit,
                .authorization = if (authorization) |v| .{ .override = v } else .omit,
            },
            .extra_headers = req.headers,
        }) catch |err| return mapError(err, null);
        defer request.deinit();
        const connection = request.connection.?;

        sendRequest(&request, if (has_body) req.body orelse "" else null) catch |err| {
            // A failed write leaves the connection in an unknown state.
            connection.closing = true;
            return mapError(err, connection);
        };

        const response = request.receiveHead(&.{}) catch |err| {
            // The rest of a rejected response is unread. Never reuse the
            // connection: std would read to the end of the stream to do so.
            connection.closing = true;
            return mapError(err, connection);
        };
        const head = response.head;
        const status: u16 = @intFromEnum(head.status);
        if (status == 204 or status == 304) {
            // These end at the head; the connection is ready for the next request.
            request.reader.state = .ready;
            return .{ .status = status, .body = "" };
        }
        if (status < 200) {
            // An informational response precedes the real one, which this
            // client does not wait for. The connection cannot be reused.
            connection.closing = true;
            return .{ .status = status, .body = "" };
        }

        const encoding = head.content_encoding;
        const decompress_buffer: []u8 = switch (encoding) {
            .identity => &.{},
            .gzip, .deflate => try arena.alloc(u8, std.compress.flate.max_window_len),
            // std refuses an encoding the request did not accept, and it
            // accepts only gzip and deflate, so these arrive only if std
            // changes. Refuse them here too: zstd would need a larger buffer
            // than std's own table gives, and a smaller one fails an assertion.
            .zstd, .compress => {
                connection.closing = true;
                return error.HttpProtocolError;
            },
        };
        var transfer_buffer: [64]u8 = undefined;
        var dechunker: Dechunker = undefined;
        const chunked = head.transfer_encoding == .chunked;
        const transfer: *std.Io.Reader = if (chunked) t: {
            dechunker = .init(request.reader.in, &transfer_buffer, self.max_response_bytes *| 2 +| 1024);
            break :t &dechunker.interface;
        } else request.reader.bodyReader(&transfer_buffer, head.transfer_encoding, head.content_length);
        var decompress: http.Decompress = undefined;
        const reader = decompress.init(transfer, decompress_buffer, encoding);

        // The limit is exclusive: `allocRemaining` fails when it is reached.
        const limit: std.Io.Limit = .limited(self.max_response_bytes +| 1);
        const body = reader.allocRemaining(arena, limit) catch |err| {
            connection.closing = true;
            return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.StreamTooLong => error.ResponseTooLarge,
                error.ReadFailed => bodyError(&request, if (chunked) &dechunker else null, transfer, encoding),
            };
        };
        // A decompressor stops at the end of its own stream, which can leave
        // the last chunk unread (Google's front end sends gzip in chunks).
        // Consume the rest of the framing, so the connection can be reused and
        // a truncated body still shows.
        if (encoding != .identity) {
            _ = transfer.discardRemaining() catch {
                connection.closing = true;
                return bodyError(&request, if (chunked) &dechunker else null, transfer, .identity);
            };
        }
        if (chunked) {
            if (!dechunker.done()) {
                connection.closing = true;
                return error.ConnectionResetByPeer;
            }
            // Framing ended exactly at the terminating chunk; the next
            // response starts here.
            request.reader.state = .ready;
        } else if (head.content_length != null and request.reader.state != .ready) {
            // std.http reports a connection that closes before Content-Length
            // bytes arrive as a normal end of stream. A body that did not
            // reach its length is a dropped connection, not a short success.
            connection.closing = true;
            return error.ConnectionResetByPeer;
        }
        return .{ .status = status, .body = body };
    }
};

/// The address inside `[...]` when the URI's host is an IPv6 literal.
fn ipv6Literal(uri: std.Uri) ?[]const u8 {
    const host = switch (uri.host orelse return null) {
        .raw, .percent_encoded => |h| h,
    };
    if (host.len < 3 or host[0] != '[' or host[host.len - 1] != ']') return null;
    return host[1 .. host.len - 1];
}

fn sendRequest(request: *http.Client.Request, body: ?[]const u8) std.Io.Writer.Error!void {
    const payload = body orelse return request.sendBodiless();
    request.transfer_encoding = .{ .content_length = payload.len };
    var body_writer = try request.sendBodyUnflushed(&.{});
    try body_writer.writer.writeAll(payload);
    try body_writer.end();
    try request.connection.?.flush();
}

/// Maps a failed body read. A body cut short by a dropped connection is
/// retryable; one that arrived whole but would not decode is not.
fn bodyError(
    request: *http.Client.Request,
    dechunker: ?*Dechunker,
    transfer: *std.Io.Reader,
    encoding: http.ContentEncoding,
) Error {
    const connection = request.connection.?;
    if (dechunker) |d| if (d.err) |err| return err;
    if (connection.stream_reader.err) |err| return mapError(err, null);
    if (encoding == .identity) return socketOk(connection);
    // The decoder failed. If the framing ends early too, the connection
    // dropped mid-body; if the framing is whole, the body itself is bad.
    _ = transfer.discardRemaining() catch {};
    const framing_complete = if (dechunker) |d|
        d.done()
    else
        request.reader.state == .ready or request.reader.state == .body_none;
    return if (framing_complete) error.HttpProtocolError else error.ConnectionResetByPeer;
}

/// Decodes `Transfer-Encoding: chunked` straight from the connection. It
/// replaces std.http's decoder, which panics with an integer overflow on a
/// chunk size near 2^64 and reads any letter as a hex digit. Sizes are
/// bounded before use, and reading stops exactly after the terminating chunk
/// and trailers, where the next response on the connection begins.
pub const Dechunker = struct {
    in: *std.Io.Reader,
    interface: std.Io.Reader,
    /// Larger chunks fail with `error.ResponseTooLarge`.
    max_chunk: u64,
    state: union(enum) {
        size,
        /// Chunk bytes still to read.
        data: u64,
        data_end,
        /// Trailer bytes read so far.
        trailers: usize,
        done,
    } = .size,
    /// Why reading failed, when the framing was at fault. Socket failures are
    /// recorded on the connection instead.
    err: ?Error = null,

    const max_trailer_bytes = 16 * 1024;

    /// `in` must start at the first chunk. `buffer` backs `interface`.
    pub fn init(in: *std.Io.Reader, buffer: []u8, max_chunk: u64) Dechunker {
        return .{
            .in = in,
            .max_chunk = max_chunk,
            .interface = .{ .vtable = &.{ .stream = stream }, .buffer = buffer, .seek = 0, .end = 0 },
        };
    }

    /// Whether the terminating chunk and trailers were read.
    pub fn done(d: *const Dechunker) bool {
        return d.state == .done;
    }

    fn stream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const d: *Dechunker = @alignCast(@fieldParentPtr("interface", r));
        while (true) switch (d.state) {
            .size => try d.readSize(),
            .data => |left| {
                const n = d.in.stream(w, limit.min(.limited64(left))) catch |err| switch (err) {
                    error.EndOfStream => return d.fail(error.ConnectionResetByPeer),
                    error.ReadFailed, error.WriteFailed => |e| return e,
                };
                d.state = if (n == left) .data_end else .{ .data = left - n };
                return n;
            },
            .data_end => {
                const crlf = d.in.takeArray(2) catch |err| return d.readError(err);
                if (!std.mem.eql(u8, crlf, "\r\n")) return d.fail(error.HttpProtocolError);
                d.state = .size;
            },
            .trailers => |seen| try d.readTrailer(seen),
            .done => return error.EndOfStream,
        };
    }

    /// `chunk-size [ chunk-ext ] CRLF`
    fn readSize(d: *Dechunker) error{ReadFailed}!void {
        const line = d.in.takeDelimiterInclusive('\n') catch |err| return d.readError(err);
        var size: u64 = 0;
        var digits: usize = 0;
        for (line) |c| {
            const digit = std.fmt.charToDigit(c, 16) catch break;
            const shifted = std.math.mul(u64, size, 16) catch return d.fail(error.ResponseTooLarge);
            size = shifted + digit;
            if (size > d.max_chunk) return d.fail(error.ResponseTooLarge);
            digits += 1;
        }
        // The line ends in '\n', which is not a digit, so `rest` is not empty.
        const rest = line[digits..];
        if (digits == 0) return d.fail(error.HttpProtocolError);
        switch (rest[0]) {
            ';', ' ', '\t', '\r', '\n' => {},
            else => return d.fail(error.HttpProtocolError),
        }
        d.state = if (size == 0) .{ .trailers = 0 } else .{ .data = size };
    }

    fn readTrailer(d: *Dechunker, seen: usize) error{ReadFailed}!void {
        const line = d.in.takeDelimiterInclusive('\n') catch |err| return d.readError(err);
        if (std.mem.eql(u8, line, "\r\n") or std.mem.eql(u8, line, "\n")) {
            d.state = .done;
            return;
        }
        if (seen + line.len > max_trailer_bytes) return d.fail(error.HttpProtocolError);
        d.state = .{ .trailers = seen + line.len };
    }

    fn readError(d: *Dechunker, err: anyerror) error{ReadFailed} {
        return switch (err) {
            // The socket's own error is on the connection.
            error.ReadFailed => error.ReadFailed,
            error.EndOfStream => d.fail(error.ConnectionResetByPeer),
            // A line longer than the connection's buffer.
            else => d.fail(error.HttpProtocolError),
        };
    }

    fn fail(d: *Dechunker, err: Error) error{ReadFailed} {
        d.err = err;
        return error.ReadFailed;
    }
};

/// Maps a `std.http` or `std.Io.net` failure to `Error`. `ReadFailed` and
/// `WriteFailed` carry no detail, so the connection's recorded error is used.
fn mapError(err: anyerror, connection: ?*http.Client.Connection) Error {
    return switch (err) {
        error.ReadFailed => if (connection) |c|
            if (c.stream_reader.err) |e| mapError(e, null) else socketOk(c)
        else
            error.ConnectionResetByPeer,
        error.WriteFailed => if (connection) |c|
            if (c.stream_writer.err) |e| mapError(e, null) else socketOk(c)
        else
            error.ConnectionResetByPeer,

        error.Canceled => error.Canceled,
        error.OutOfMemory => error.OutOfMemory,

        error.ConnectionRefused => error.ConnectionRefused,
        error.ConnectionResetByPeer,
        error.SocketUnconnected,
        error.BrokenPipe,
        error.EndOfStream,
        error.HttpConnectionClosing,
        error.HttpRequestTruncated,
        error.HttpChunkTruncated,
        => error.ConnectionResetByPeer,
        error.Timeout, error.ConnectionTimedOut => error.ConnectionTimedOut,
        error.NetworkUnreachable,
        error.HostUnreachable,
        error.NetworkDown,
        error.AddressUnavailable,
        => error.NetworkUnreachable,

        error.UnknownHostName, error.NoAddressReturned => error.UnknownHostName,
        error.NameServerFailure,
        error.ResolvConfParseFailed,
        error.DetectingNetworkConfigurationFailed,
        error.InvalidDnsARecord,
        error.InvalidDnsAAAARecord,
        error.InvalidDnsCnameRecord,
        => error.NameServerFailure,

        error.TlsInitializationFailed,
        error.CertificateBundleLoadFailure,
        => error.TlsFailure,

        error.UnsupportedUriScheme, error.UriMissingHost => error.InvalidEndpoint,

        // std 0.16 on Windows returns Unexpected for socket statuses it does
        // not map, among them a refused connection (STATUS_CONNECTION_REFUSED)
        // and a peer that hangs up (STATUS_LOCAL_DISCONNECT). Which one it
        // was is lost by now; both are worth retrying, so call it a dropped
        // connection. Elsewhere std maps every socket error it expects.
        error.Unexpected => if (builtin.os.tag == .windows) error.ConnectionResetByPeer else error.NetworkFailure,

        error.HttpHeadersOversize,
        error.HttpHeadersInvalid,
        error.HttpChunkInvalid,
        error.HttpContentEncodingUnsupported,
        error.HttpTransferEncodingUnsupported,
        error.HttpConnectionHeaderUnsupported,
        error.HttpHeaderContinuationsUnsupported,
        error.InvalidContentLength,
        error.TooManyHttpRedirects,
        error.RedirectRequiresResend,
        error.HttpRedirectLocationMissing,
        error.HttpRedirectLocationOversize,
        error.HttpRedirectLocationInvalid,
        => error.HttpProtocolError,

        else => error.NetworkFailure,
    };
}

/// A read or write failed but the socket recorded no error, so the TLS layer
/// (or a peer that closed cleanly) caused it.
fn socketOk(connection: *const http.Client.Connection) Error {
    return if (connection.protocol == .tls) error.TlsFailure else error.ConnectionResetByPeer;
}

// Tests use a real `std.http.Client` against a scripted server on the loopback
// interface. Nothing leaves the machine.

const testing = std.testing;
const net = std.Io.net;
const test_util = @import("testing.zig");

const ScriptedServer = test_util.ScriptedServer;

fn expectHeader(raw: []const u8, header_line: []const u8) !void {
    if (std.mem.indexOf(u8, raw, header_line) == null) {
        std.debug.print("missing header {s} in request:\n{s}\n", .{ header_line, raw });
        return error.TestExpectedHeader;
    }
}

test "HttpTransport sends headers and body and reads the response" {
    const io = testing.io;
    var server: ScriptedServer = try .start(io, &.{
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 17\r\n\r\n{\"messageIds\":[]}",
        "HTTP/1.1 404 Not Found\r\nContent-Length: 9\r\n\r\nNot Found",
    });
    defer server.deinit(io);
    server.per_connection = 2;
    var serving = try io.concurrent(ScriptedServer.run, .{ &server, io });
    defer _ = serving.cancel(io) catch {};

    var ht: HttpTransport = .init(testing.allocator, io, "zig-pubsub-test/1");
    defer ht.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var buf: [128]u8 = undefined;

    const first = try ht.transport().send(.{
        .method = .POST,
        .url = server.url(&buf, "/v1/projects/p/topics/t:publish"),
        .bearer = "tok-123",
        .body = "{\"messages\":[]}",
    }, arena.allocator());
    try testing.expectEqual(200, first.status);
    try testing.expectEqualStrings("{\"messageIds\":[]}", first.body);

    // The second request reuses the kept-alive connection.
    const second = try ht.transport().send(.{
        .method = .GET,
        .url = server.url(&buf, "/v1/projects/p/topics/t"),
    }, arena.allocator());
    try testing.expectEqual(404, second.status);
    try testing.expectEqualStrings("Not Found", second.body);

    try serving.await(io);
    try testing.expectEqual(1, server.connections);

    const post = server.request(0);
    try testing.expect(std.mem.startsWith(u8, post, "POST /v1/projects/p/topics/t:publish HTTP/1.1\r\n"));
    try expectHeader(post, "user-agent: zig-pubsub-test/1\r\n");
    try expectHeader(post, "content-type: application/json\r\n");
    try expectHeader(post, "authorization: Bearer tok-123\r\n");
    try expectHeader(post, "content-length: 15\r\n");
    try testing.expect(std.mem.endsWith(u8, post, "\r\n\r\n{\"messages\":[]}"));

    const get = server.request(1);
    try testing.expect(std.mem.startsWith(u8, get, "GET /v1/projects/p/topics/t HTTP/1.1\r\n"));
    try testing.expect(std.mem.indexOf(u8, get, "authorization") == null);
    try testing.expect(std.mem.indexOf(u8, get, "content-type") == null);
}

test "HttpTransport sends a form body with its content type" {
    const io = testing.io;
    var server: ScriptedServer = try .start(io, &.{
        "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}",
    });
    defer server.deinit(io);
    var serving = try io.concurrent(ScriptedServer.run, .{ &server, io });
    defer _ = serving.cancel(io) catch {};

    var ht: HttpTransport = .init(testing.allocator, io, "t");
    defer ht.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var buf: [128]u8 = undefined;
    _ = try ht.transport().send(.{
        .method = .POST,
        .url = server.url(&buf, "/token"),
        .body = "grant_type=refresh_token&refresh_token=1%2F%2Fabc",
        .content_type = .form,
    }, arena.allocator());
    try serving.await(io);

    const post = server.request(0);
    try expectHeader(post, "content-type: application/x-www-form-urlencoded\r\n");
    try testing.expect(std.mem.endsWith(u8, post, "\r\n\r\ngrant_type=refresh_token&refresh_token=1%2F%2Fabc"));
}

test "HttpTransport sends extra headers, in order, after its own" {
    const io = testing.io;
    var server: ScriptedServer = try .start(io, &.{
        "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}",
    });
    defer server.deinit(io);
    var serving = try io.concurrent(ScriptedServer.run, .{ &server, io });
    defer _ = serving.cancel(io) catch {};

    var ht: HttpTransport = .init(testing.allocator, io, "t");
    defer ht.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var buf: [128]u8 = undefined;
    _ = try ht.transport().send(.{
        .method = .GET,
        .url = server.url(&buf, "/computeMetadata/v1/"),
        .headers = &.{
            .{ .name = "Metadata-Flavor", .value = "Google" },
            .{ .name = "x-goog-user-project", .value = "billing-project" },
        },
    }, arena.allocator());
    try serving.await(io);

    const get = server.request(0);
    try expectHeader(get, "Metadata-Flavor: Google\r\n");
    try expectHeader(get, "x-goog-user-project: billing-project\r\n");
    // After the ones the transport writes itself, so neither can be replaced.
    try testing.expect(std.mem.indexOf(u8, get, "user-agent: t\r\n").? < std.mem.indexOf(u8, get, "Metadata-Flavor").?);
}

test "HttpTransport refuses a header that would end the line, before it connects" {
    var ht: HttpTransport = .init(testing.allocator, testing.io, "t");
    defer ht.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    for ([_]Header{
        .{ .name = "X-Evil", .value = "1\r\nX-Injected: 2" },
        .{ .name = "X-Evil", .value = "1\n" },
        .{ .name = "X-Evil", .value = " 1" },
        .{ .name = "X-Evil", .value = "1\t" },
        .{ .name = "X-Evil", .value = "caf\xc3\xa9" },
        .{ .name = "X-Evil\r\nX-Injected", .value = "1" },
        .{ .name = "X Evil", .value = "1" },
        .{ .name = "", .value = "1" },
    }) |h| {
        // Nothing listens on port 1: a connection attempt would be refused,
        // so InvalidRequestHeader proves the check runs first.
        try testing.expectError(error.InvalidRequestHeader, ht.transport().send(.{
            .method = .GET,
            .url = "http://127.0.0.1:1/",
            .headers = &.{h},
        }, arena.allocator()));
    }
}

test "header names and values follow RFC 9110" {
    try testing.expect(isValidHeaderName("Metadata-Flavor"));
    try testing.expect(isValidHeaderName("x-goog-user-project"));
    try testing.expect(!isValidHeaderName("X:Y"));
    try testing.expect(!isValidHeaderName("X Y"));
    try testing.expect(!isValidHeaderName(""));
    try testing.expect(isValidHeaderValue("Google"));
    try testing.expect(isValidHeaderValue("a b"));
    try testing.expect(isValidHeaderValue(""));
    try testing.expect(!isValidHeaderValue("a\x00b"));
    try testing.expect(!isValidHeaderValue("a\r\nb"));
    try testing.expect(!isValidHeaderValue(" a"));
    try testing.expect(!isValidHeaderValue("a "));
}

fn headerProperty(_: void, input: []const u8) !void {
    // An accepted header can never end its line or start another one.
    if (isValidHeaderName(input)) {
        try testing.expect(std.mem.indexOfAny(u8, input, "\r\n\x00 \t:") == null);
        try testing.expect(input.len > 0);
    }
    if (isValidHeaderValue(input)) {
        try testing.expect(std.mem.indexOfAny(u8, input, "\r\n\x00") == null);
        if (input.len > 0) try testing.expect(input[0] != ' ' and input[input.len - 1] != ' ');
    }
}

test "fuzz headers: nothing accepted can break the request" {
    try test_util.fuzzBytes({}, headerProperty, .{ .corpus = &.{
        "Metadata-Flavor",
        "Google",
        "a\r\nX-Injected: 1",
        " lead",
        "trail\t",
        "caf\xc3\xa9",
        "",
    } });
}

test "HttpTransport reaches IPv6 literal hosts, as PUBSUB_EMULATOR_HOST=[::1]:8085" {
    const io = testing.io;
    // Regression: std.http looked up "[::1]" by name and failed.
    var server = ScriptedServer.startOn(io, .{ .ip6 = .loopback(0) }, &.{
        "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}",
        "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n[]",
    }) catch return error.SkipZigTest; // No IPv6 loopback here.
    defer server.deinit(io);
    server.per_connection = 2;
    var serving = try io.concurrent(ScriptedServer.run, .{ &server, io });
    defer _ = serving.cancel(io) catch {};

    var ht: HttpTransport = .init(testing.allocator, io, "t");
    defer ht.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&buf, "http://[::1]:{d}/v1/x", .{server.port});
    try testing.expectEqualStrings("{}", (try ht.transport().send(.{ .method = .GET, .url = url }, arena.allocator())).body);
    try testing.expectEqualStrings("[]", (try ht.transport().send(.{ .method = .GET, .url = url }, arena.allocator())).body);
    try serving.await(io);
    // The pooled connection was reused, and the Host header keeps the brackets.
    try testing.expectEqual(1, server.connections);
    var host_line: [64]u8 = undefined;
    try expectHeader(server.request(0), try std.fmt.bufPrint(&host_line, "host: [::1]:{d}\r\n", .{server.port}));
}

test "ipv6Literal" {
    try testing.expectEqualStrings("::1", ipv6Literal(try std.Uri.parse("http://[::1]:8085")).?);
    try testing.expectEqualStrings("fe80::1", ipv6Literal(try std.Uri.parse("http://[fe80::1]/v1")).?);
    try testing.expectEqual(null, ipv6Literal(try std.Uri.parse("http://localhost:8085")));
    try testing.expectEqual(null, ipv6Literal(try std.Uri.parse("http://127.0.0.1:8085")));
}

test "HttpTransport reports a truncated body as a dropped connection" {
    const io = testing.io;
    // Regression: std.http returns a short Content-Length body as success.
    var server: ScriptedServer = try .start(io, &.{
        "HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\n{\"receivedMessages\":[",
    });
    defer server.deinit(io);
    var serving = try io.concurrent(ScriptedServer.run, .{ &server, io });
    defer _ = serving.cancel(io) catch {};

    var ht: HttpTransport = .init(testing.allocator, io, "t");
    defer ht.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var buf: [128]u8 = undefined;

    try testing.expectError(error.ConnectionResetByPeer, ht.transport().send(.{
        .method = .POST,
        .url = server.url(&buf, "/v1/projects/p/subscriptions/s:pull"),
        .body = "{}",
    }, arena.allocator()));
}

test "HttpTransport reads chunked bodies and rejects bad chunk framing" {
    const io = testing.io;
    var server: ScriptedServer = try .start(io, &.{
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n4\r\n{\"a\"\r\n3\r\n:1}\r\n0\r\n\r\n",
        // Chunk data must end in CRLF. (std.http accepts any letter as a size
        // digit, so a size like "zz" is not a framing error to it.)
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabcXY0\r\n\r\n",
    });
    defer server.deinit(io);
    server.per_connection = 2;
    var serving = try io.concurrent(ScriptedServer.run, .{ &server, io });
    defer _ = serving.cancel(io) catch {};

    var ht: HttpTransport = .init(testing.allocator, io, "t");
    defer ht.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var buf: [128]u8 = undefined;

    const ok = try ht.transport().send(.{ .method = .GET, .url = server.url(&buf, "/a") }, arena.allocator());
    try testing.expectEqualStrings("{\"a\":1}", ok.body);
    try testing.expectError(
        error.HttpProtocolError,
        ht.transport().send(.{ .method = .GET, .url = server.url(&buf, "/b") }, arena.allocator()),
    );
}

test "HttpTransport reports a truncated chunked body as a dropped connection" {
    const io = testing.io;
    var server: ScriptedServer = try .start(io, &.{
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n10\r\n{\"receivedMe",
    });
    defer server.deinit(io);
    var serving = try io.concurrent(ScriptedServer.run, .{ &server, io });
    defer _ = serving.cancel(io) catch {};

    var ht: HttpTransport = .init(testing.allocator, io, "t");
    defer ht.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var buf: [128]u8 = undefined;
    try testing.expectError(
        error.ConnectionResetByPeer,
        ht.transport().send(.{ .method = .GET, .url = server.url(&buf, "/a") }, arena.allocator()),
    );
}

test "HttpTransport decodes gzip in chunks and keeps the connection" {
    const io = testing.io;
    // Regression: the gzip decoder stops before the final chunk, which once
    // made every production response look truncated.
    var server: ScriptedServer = try .start(io, &.{
        "HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nTransfer-Encoding: chunked\r\n\r\n" ++
            "14\x0d\x0a\x1f\x8b\x08\x00\x00\x00\x00\x00\x02\xff\xabV*\xc9/\xc8L.V\xb2\x0d\x0a2c\x0d\x0a\x8a\xaeV\xcaK\xccMU\xb2R*(\xca\xcfJM.)\xd6/\xd0\x87H\xeaWe\x16\x14\xa4\xa6(\xd5\xc6\xd6\x02\x00\x80\xdd\xe810\x00\x00\x00\x0d\x0a0\x0d\x0a\x0d\x0a",
        "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}",
    });
    defer server.deinit(io);
    server.per_connection = 2;
    var serving = try io.concurrent(ScriptedServer.run, .{ &server, io });
    defer _ = serving.cancel(io) catch {};

    var ht: HttpTransport = .init(testing.allocator, io, "t");
    defer ht.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var buf: [128]u8 = undefined;

    const zipped = try ht.transport().send(.{ .method = .GET, .url = server.url(&buf, "/a") }, arena.allocator());
    try testing.expectEqualStrings("{\"topics\":[{\"name\":\"projects/p/topics/zipped\"}]}", zipped.body);
    const plain = try ht.transport().send(.{ .method = .GET, .url = server.url(&buf, "/b") }, arena.allocator());
    try testing.expectEqualStrings("{}", plain.body);
    try serving.await(io);
    // Both requests went over one connection.
    try testing.expectEqual(1, server.connections);
    try expectHeader(server.request(0), "accept-encoding: gzip, deflate\r\n");
}

test "HttpTransport rejects a gzip stream cut short" {
    const io = testing.io;
    var server: ScriptedServer = try .start(io, &.{
        "HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nTransfer-Encoding: chunked\r\n\r\n" ++
            "1e\x0d\x0a\x1f\x8b\x08\x00\x00\x00\x00\x00\x02\xff\xabV*\xc9/\xc8L.V\xb2\x8a\xaeV\xcaK\xccMU\xb2R\x0d\x0a0\x0d\x0a\x0d\x0a",
    });
    defer server.deinit(io);
    var serving = try io.concurrent(ScriptedServer.run, .{ &server, io });
    defer _ = serving.cancel(io) catch {};

    var ht: HttpTransport = .init(testing.allocator, io, "t");
    defer ht.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var buf: [128]u8 = undefined;
    try testing.expectError(
        error.HttpProtocolError,
        ht.transport().send(.{ .method = .GET, .url = server.url(&buf, "/a") }, arena.allocator()),
    );
}

test "Dechunker: a chunk size near 2^64 is an error, not a panic" {
    const io = testing.io;
    // Regression: std.http's decoder overflows on `chunk_len + 2` and panics.
    var server: ScriptedServer = try .start(io, &.{
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nffffffffffffffff\r\nx",
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n00000000000000000000000000000002\r\n{}\r\n0\r\n\r\n",
    });
    defer server.deinit(io);
    var serving = try io.concurrent(ScriptedServer.run, .{ &server, io });
    defer _ = serving.cancel(io) catch {};

    var ht: HttpTransport = .init(testing.allocator, io, "t");
    defer ht.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var buf: [128]u8 = undefined;
    try testing.expectError(
        error.ResponseTooLarge,
        ht.transport().send(.{ .method = .GET, .url = server.url(&buf, "/a") }, arena.allocator()),
    );
    // Leading zeros are fine however many there are.
    const ok = try ht.transport().send(.{ .method = .GET, .url = server.url(&buf, "/b") }, arena.allocator());
    try testing.expectEqualStrings("{}", ok.body);
}

test "HttpTransport: 204 ends at the head instead of waiting for the connection to close" {
    const io = testing.io;
    var server: ScriptedServer = try .start(io, &.{"HTTP/1.1 204 No Content\r\n\r\n"});
    defer server.deinit(io);
    server.linger_ms = 3000;
    var serving = try io.concurrent(ScriptedServer.run, .{ &server, io });
    defer _ = serving.cancel(io) catch {};

    var ht: HttpTransport = .init(testing.allocator, io, "t");
    defer ht.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var buf: [128]u8 = undefined;
    const started = std.Io.Clock.awake.now(io);
    const res = try ht.transport().send(.{ .method = .DELETE, .url = server.url(&buf, "/a") }, arena.allocator());
    try testing.expectEqual(204, res.status);
    try testing.expectEqualStrings("", res.body);
    try testing.expect(started.untilNow(io, .awake).toMilliseconds() < 1500);
}

test "HttpTransport: a rejected response head returns at once" {
    const io = testing.io;
    // Regression: std.http read the rest of the stream before giving the
    // connection back, blocking until the server closed it.
    var server: ScriptedServer = try .start(io, &.{"HTTP/1.1 200 OK\r\nContent-Encoding: br\r\n\r\nbrotli..."});
    defer server.deinit(io);
    server.linger_ms = 3000;
    var serving = try io.concurrent(ScriptedServer.run, .{ &server, io });
    defer _ = serving.cancel(io) catch {};

    var ht: HttpTransport = .init(testing.allocator, io, "t");
    defer ht.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var buf: [128]u8 = undefined;
    const started = std.Io.Clock.awake.now(io);
    try testing.expectError(
        error.HttpProtocolError,
        ht.transport().send(.{ .method = .GET, .url = server.url(&buf, "/a") }, arena.allocator()),
    );
    try testing.expect(started.untilNow(io, .awake).toMilliseconds() < 1500);
}

test "HttpTransport: a gzip body cut short is a dropped connection; a corrupt one is not" {
    const io = testing.io;
    const gzip_head = "\x1f\x8b\x08\x00\x00\x00\x00\x00\x02\xff\xabV*\xc9/\xc8L.V\xb2\x8a\xaeV\xcaK\xccMU\xb2R";
    var server: ScriptedServer = try .start(io, &.{
        // Content-Length promises more than arrives before the close.
        "HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Length: 200\r\n\r\n" ++ gzip_head,
        // Complete framing, but not a gzip stream.
        "HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Length: 10\r\n\r\nnot gzip!!",
    });
    defer server.deinit(io);
    var serving = try io.concurrent(ScriptedServer.run, .{ &server, io });
    defer _ = serving.cancel(io) catch {};

    var ht: HttpTransport = .init(testing.allocator, io, "t");
    defer ht.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var buf: [128]u8 = undefined;
    try testing.expectError(
        error.ConnectionResetByPeer,
        ht.transport().send(.{ .method = .GET, .url = server.url(&buf, "/a") }, arena.allocator()),
    );
    try testing.expectError(
        error.HttpProtocolError,
        ht.transport().send(.{ .method = .GET, .url = server.url(&buf, "/b") }, arena.allocator()),
    );
}

test "HttpTransport: an informational response is returned as it is" {
    const io = testing.io;
    // A 1xx precedes the real response. This client does not wait for it,
    // and does not reuse the connection; the next request still works.
    var server: ScriptedServer = try .start(io, &.{
        "HTTP/1.1 103 Early Hints\r\nLink: </a.css>; rel=preload\r\n\r\n",
        "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}",
    });
    defer server.deinit(io);
    var serving = try io.concurrent(ScriptedServer.run, .{ &server, io });
    defer _ = serving.cancel(io) catch {};

    var ht: HttpTransport = .init(testing.allocator, io, "t");
    defer ht.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var buf: [128]u8 = undefined;
    const early = try ht.transport().send(.{ .method = .GET, .url = server.url(&buf, "/a") }, arena.allocator());
    try testing.expectEqual(103, early.status);
    try testing.expectEqualStrings("", early.body);
    const next = try ht.transport().send(.{ .method = .GET, .url = server.url(&buf, "/b") }, arena.allocator());
    try testing.expectEqual(200, next.status);
    try testing.expectEqualStrings("{}", next.body);
    try serving.await(io);
}

test "HttpTransport decodes deflate, and refuses encodings it did not ask for" {
    const io = testing.io;
    // std sends `accept-encoding: gzip, deflate`, but a proxy may send
    // anything. HTTP's deflate is zlib-wrapped.
    const deflate = "\x78\xda\xab\x56\xca\xcf\x56\xb2\x2a\x29\x2a\x4d\xad\x05\x00\x16\xe3\x04\x11";
    const zstd = "\x28\xb5\x2f\xfd\x20\x0b\x59\x00\x00\x7b\x22\x6f\x6b\x22\x3a\x74\x72\x75\x65\x7d";
    var server: ScriptedServer = try .start(io, &.{
        std.fmt.comptimePrint("HTTP/1.1 200 OK\r\nContent-Encoding: deflate\r\nContent-Length: {d}\r\n\r\n", .{deflate.len}) ++ deflate,
        std.fmt.comptimePrint("HTTP/1.1 200 OK\r\nContent-Encoding: zstd\r\nContent-Length: {d}\r\n\r\n", .{zstd.len}) ++ zstd,
        "HTTP/1.1 200 OK\r\nContent-Encoding: compress\r\nContent-Length: 4\r\n\r\nabcd",
    });
    // deflate and zstd share the first connection, which the client keeps
    // after a whole body. A refused encoding leaves its body unread, so the
    // client closes that connection and compress needs a new one.
    server.per_connection = 2;
    defer server.deinit(io);
    var serving = try io.concurrent(ScriptedServer.run, .{ &server, io });
    defer _ = serving.cancel(io) catch {};

    var ht: HttpTransport = .init(testing.allocator, io, "t");
    defer ht.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var buf: [128]u8 = undefined;
    const res = try ht.transport().send(.{ .method = .GET, .url = server.url(&buf, "/deflate") }, arena.allocator());
    try testing.expectEqualStrings("{\"ok\":true}", res.body);
    for ([_][]const u8{ "/zstd", "/compress" }) |path| {
        try testing.expectError(
            error.HttpProtocolError,
            ht.transport().send(.{ .method = .GET, .url = server.url(&buf, path) }, arena.allocator()),
        );
    }
    try serving.await(io);
}

test "HttpTransport: chunked framing cut after a whole gzip stream is a dropped connection" {
    const io = testing.io;
    // The gzip stream decodes completely, but the terminating chunk never
    // arrives: the body cannot be known to be whole.
    const gzip = "\x1f\x8b\x08\x00\x00\x00\x00\x00\x02\x03\xab\x56\xca\xcf\x56\xb2\x2a\x29\x2a\x4d\xad\x05\x00\x90\x5f\xd4\xa7\x0b\x00\x00\x00";
    var server: ScriptedServer = try .start(io, &.{
        "HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nTransfer-Encoding: chunked\r\n\r\n1f\r\n" ++ gzip ++ "\r\n",
    });
    defer server.deinit(io);
    var serving = try io.concurrent(ScriptedServer.run, .{ &server, io });
    defer _ = serving.cancel(io) catch {};

    var ht: HttpTransport = .init(testing.allocator, io, "t");
    defer ht.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var buf: [128]u8 = undefined;
    try testing.expectError(
        error.ConnectionResetByPeer,
        ht.transport().send(.{ .method = .GET, .url = server.url(&buf, "/") }, arena.allocator()),
    );
    try serving.await(io);
}

test "HttpTransport: a chunk-size line longer than the read buffer is a protocol error" {
    const io = testing.io;
    var server: ScriptedServer = try .start(io, &.{
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5;" ++ ("x" ** 16384) ++ "\r\nhello\r\n0\r\n\r\n",
    });
    defer server.deinit(io);
    var serving = try io.concurrent(ScriptedServer.run, .{ &server, io });
    defer _ = serving.cancel(io) catch {};

    var ht: HttpTransport = .init(testing.allocator, io, "t");
    defer ht.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var buf: [128]u8 = undefined;
    try testing.expectError(
        error.HttpProtocolError,
        ht.transport().send(.{ .method = .GET, .url = server.url(&buf, "/") }, arena.allocator()),
    );
}

test "HttpTransport: a failed TLS handshake forgets the TLS clock" {
    if (http.Client.disable_tls) return error.SkipZigTest;
    const io = testing.io;
    var server: ScriptedServer = try .start(io, &.{});
    defer server.deinit(io);
    server.close_on_accept = true;
    var serving = try io.concurrent(ScriptedServer.run, .{ &server, io });
    defer _ = serving.cancel(io) catch {};

    var ht: HttpTransport = .init(testing.allocator, io, "t");
    defer ht.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    // A fresh clock reading, so the request skips the CA bundle scan.
    ht.client.now = std.Io.Clock.real.now(io);
    var buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&buf, "https://127.0.0.1:{d}/v1/x", .{server.port});
    // The server hangs up mid-handshake: a failure worth retrying. std 0.16
    // on Windows reports that as a socket error rather than a TLS failure
    // (see mapError), and only a TLS failure forgets the clock.
    if (builtin.os.tag == .windows) {
        try testing.expectError(error.ConnectionResetByPeer, ht.transport().send(.{ .method = .GET, .url = url }, arena.allocator()));
        return;
    }
    try testing.expectError(error.TlsFailure, ht.transport().send(.{ .method = .GET, .url = url }, arena.allocator()));
    try testing.expectEqual(null, ht.client.now);
}

test "HttpTransport: a TLS clock older than an hour is reloaded" {
    if (http.Client.disable_tls) return error.SkipZigTest;
    var ht: HttpTransport = .init(testing.allocator, testing.io, "t");
    defer ht.deinit();
    const now = std.Io.Clock.real.now(testing.io);
    ht.client.now = now;
    ht.expireTlsClock(.when_stale);
    try testing.expectEqual(now, ht.client.now.?);
    ht.client.now = now.subDuration(.fromSeconds(2 * 60 * 60));
    ht.expireTlsClock(.when_stale);
    try testing.expectEqual(null, ht.client.now);
    // A clock that ran backwards is not trusted either.
    ht.client.now = now.addDuration(.fromSeconds(60));
    ht.expireTlsClock(.when_stale);
    try testing.expectEqual(null, ht.client.now);
}

fn dechunk(gpa: Allocator, input: []const u8, max_chunk: u64) !struct { []u8, []const u8 } {
    var in: std.Io.Reader = .fixed(input);
    var buffer: [64]u8 = undefined;
    var d: Dechunker = .init(&in, &buffer, max_chunk);
    const out = d.interface.allocRemaining(gpa, .unlimited) catch |err| switch (err) {
        error.ReadFailed => return d.err orelse error.TestUnexpectedReadFailure,
        else => |e| return e,
    };
    if (!d.done()) {
        gpa.free(out);
        return error.TestNotDone;
    }
    return .{ out, in.buffered() };
}

test "Dechunker: chunks, extensions, trailers, and nothing read past the end" {
    const gpa = testing.allocator;
    const out, const rest = try dechunk(gpa, "4;name=value\r\nWiki\r\n5 \r\npedia\r\nE\r\n in\r\n\r\nchunks.\r\n0\r\nExpires: never\r\n\r\nHTTP/1.1 200 OK", 1024);
    defer gpa.free(out);
    try testing.expectEqualStrings("Wikipedia in\r\n\r\nchunks.", out);
    // The next response on the connection is untouched.
    try testing.expectEqualStrings("HTTP/1.1 200 OK", rest);

    const empty, _ = try dechunk(gpa, "0\r\n\r\n", 1024);
    defer gpa.free(empty);
    try testing.expectEqualStrings("", empty);
    const bare_lf, _ = try dechunk(gpa, "2\nhi\r\n0\n\n", 1024);
    defer gpa.free(bare_lf);
    try testing.expectEqualStrings("hi", bare_lf);
}

test "Dechunker: framing errors" {
    const gpa = testing.allocator;
    const cases = [_]struct { []const u8, anyerror }{
        .{ "zz\r\nnope", error.HttpProtocolError },
        .{ "\r\n", error.HttpProtocolError },
        .{ "-1\r\n", error.HttpProtocolError },
        .{ "4x\r\nabcd\r\n0\r\n\r\n", error.HttpProtocolError },
        .{ "3\r\nabcXY0\r\n\r\n", error.HttpProtocolError },
        .{ "401\r\n", error.ResponseTooLarge },
        .{ "ffffffffffffffff\r\nx", error.ResponseTooLarge },
        .{ "fffffffffffffffffffff\r\n", error.ResponseTooLarge },
        .{ "", error.ConnectionResetByPeer },
        .{ "5\r\nab", error.ConnectionResetByPeer },
        .{ "2\r\nab", error.ConnectionResetByPeer },
        .{ "2\r\nab\r\n0\r\n", error.ConnectionResetByPeer },
        .{ "2\r\nab\r\n0\r\nTrailer: x\r\n", error.ConnectionResetByPeer },
    };
    for (cases) |c| {
        if (dechunk(gpa, c[0], 1024)) |result| {
            gpa.free(result[0]);
            std.debug.print("accepted {s}\n", .{c[0]});
            return error.TestUnexpectedSuccess;
        } else |err| try testing.expectEqual(c[1], err);
    }
    // Endless trailers are cut off.
    const trailers = "0\r\n" ++ ("X-Trailer: yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy\r\n" ** 400) ++ "\r\n";
    try testing.expectError(error.HttpProtocolError, dechunk(gpa, trailers, 1024));
}

fn dechunkRoundTrip(_: void, input: []const u8) !void {
    const gpa = testing.allocator;
    var g: test_util.ByteGen = .init(input);
    const data = g.slice(600);
    // Encode `data` in random-sized chunks with random extensions, hex case,
    // leading zeros and trailers, followed by the next response's bytes.
    var encoded: std.Io.Writer.Allocating = .init(gpa);
    defer encoded.deinit();
    const w = &encoded.writer;
    var pos: usize = 0;
    while (pos < data.len) {
        const n = @min(data.len - pos, g.intRange(usize, 1, 64));
        for (0..g.intRange(usize, 0, 2)) |_| try w.writeByte('0');
        if (g.boolean()) try w.print("{x}", .{n}) else try w.print("{X}", .{n});
        if (g.boolean()) try w.writeAll(";ext=\"v\"");
        try w.writeAll("\r\n");
        try w.writeAll(data[pos..][0..n]);
        try w.writeAll("\r\n");
        pos += n;
    }
    try w.writeAll("0\r\n");
    if (g.boolean()) try w.writeAll("Trailer: value\r\n");
    try w.writeAll("\r\n");
    const whole = encoded.written().len;
    try w.writeAll("NEXT");

    const out, const rest = try dechunk(gpa, encoded.written(), 1024);
    defer gpa.free(out);
    try testing.expectEqualSlices(u8, data, out);
    try testing.expectEqualStrings("NEXT", rest);

    // Every strict prefix is a dropped connection, never a short success.
    const cut = g.intRange(usize, 0, whole - 1);
    try testing.expectError(error.ConnectionResetByPeer, dechunk(gpa, encoded.written()[0..cut], 1024));
}

test "fuzz Dechunker: encoded data decodes exactly; every prefix is a dropped connection" {
    try test_util.fuzzBytes({}, dechunkRoundTrip, .{ .corpus = &.{
        "\x00\x05hello\x00\x03\x01",
        "",
        "\x00\x40" ++ "0123456789abcdef" ** 4 ++ "\x07\x01\x00\x01",
    } });
}

fn dechunkArbitrary(_: void, input: []const u8) !void {
    const gpa = testing.allocator;
    const out, _ = dechunk(gpa, input, 256) catch |err| switch (err) {
        error.HttpProtocolError, error.ResponseTooLarge, error.ConnectionResetByPeer => return,
        else => return err,
    };
    gpa.free(out);
}

test "fuzz Dechunker: arbitrary input never crashes" {
    try test_util.fuzzBytes({}, dechunkArbitrary, .{ .corpus = &.{
        "ffffffffffffffff\r\nx",
        "1;\r\na\r\n0\r\n\r\n",
        "10\r\n0123456789abcdef\r\n0\r\nA: b\r\n\r\n",
        "0\n\n",
    } });
}

test "HttpTransport does not follow redirects" {
    const io = testing.io;
    // A redirect could carry the request, Authorization header and all, to
    // another host. The response comes back as it is and nothing follows it.
    var server: ScriptedServer = try .start(io, &.{
        "HTTP/1.1 302 Found\r\nLocation: http://attacker.invalid/steal\r\nContent-Length: 0\r\n\r\n",
    });
    defer server.deinit(io);
    var serving = try io.concurrent(ScriptedServer.run, .{ &server, io });
    defer _ = serving.cancel(io) catch {};

    var ht: HttpTransport = .init(testing.allocator, io, "t");
    defer ht.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var buf: [128]u8 = undefined;
    const res = try ht.transport().send(.{
        .method = .GET,
        .url = server.url(&buf, "/v1/projects/p/topics/t"),
        .bearer = "secret-token",
    }, arena.allocator());
    try testing.expectEqual(302, res.status);
    try serving.await(io);
    try testing.expectEqual(1, server.connections);
}

test "HttpTransport enforces the response size limit" {
    const io = testing.io;
    var server: ScriptedServer = try .start(io, &.{
        "HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\n0123456789",
        "HTTP/1.1 200 OK\r\nContent-Length: 11\r\n\r\n0123456789A",
    });
    defer server.deinit(io);
    server.per_connection = 2;
    var serving = try io.concurrent(ScriptedServer.run, .{ &server, io });
    defer _ = serving.cancel(io) catch {};

    var ht: HttpTransport = .init(testing.allocator, io, "t");
    defer ht.deinit();
    ht.max_response_bytes = 10;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var buf: [128]u8 = undefined;

    const at_limit = try ht.transport().send(.{ .method = .GET, .url = server.url(&buf, "/a") }, arena.allocator());
    try testing.expectEqualStrings("0123456789", at_limit.body);
    try testing.expectError(
        error.ResponseTooLarge,
        ht.transport().send(.{ .method = .GET, .url = server.url(&buf, "/b") }, arena.allocator()),
    );
}

test "HttpTransport maps a refused connection" {
    const io = testing.io;
    // Bind a port, then close it so nothing listens there.
    var server: ScriptedServer = try .start(io, &.{});
    const port = server.port;
    server.deinit(io);

    var ht: HttpTransport = .init(testing.allocator, io, "t");
    defer ht.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&buf, "http://127.0.0.1:{d}/v1/x", .{port});
    // std 0.16 on Windows cannot tell a refused connection from a dropped
    // one (see mapError). Either way the call is retried.
    const expected: Error = if (builtin.os.tag == .windows) error.ConnectionResetByPeer else error.ConnectionRefused;
    try testing.expectError(expected, ht.transport().send(.{ .method = .GET, .url = url }, arena.allocator()));
}

test "mapError: an unmapped socket status on Windows is a dropped connection" {
    // Regression: CI on Windows showed a refused connection and a hang-up
    // arriving as error.Unexpected, which was a permanent NetworkFailure, so
    // neither was retried.
    const expected: Error = if (builtin.os.tag == .windows) error.ConnectionResetByPeer else error.NetworkFailure;
    try testing.expectEqual(expected, mapError(error.Unexpected, null));
}

test "HttpTransport rejects unusable URLs without panicking" {
    var ht: HttpTransport = .init(testing.allocator, testing.io, "t");
    defer ht.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const t = ht.transport();
    try testing.expectError(error.InvalidEndpoint, t.send(.{ .method = .GET, .url = "not a url" }, arena.allocator()));
    try testing.expectError(error.InvalidEndpoint, t.send(.{ .method = .GET, .url = "ftp://h/x" }, arena.allocator()));
    // A PUT with no body still sends a well-formed request line; it fails at connect here.
    try testing.expectError(error.InvalidEndpoint, t.send(.{ .method = .PUT, .url = "gopher://h" }, arena.allocator()));
}

test "HttpTransport returns error.Canceled when its task is canceled" {
    const io = testing.io;
    var server: ScriptedServer = try .start(io, &.{});
    defer server.deinit(io);
    server.hang = true;
    var serving = try io.concurrent(ScriptedServer.run, .{ &server, io });
    defer _ = serving.cancel(io) catch {};

    var ht: HttpTransport = .init(testing.allocator, io, "t");
    defer ht.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var buf: [128]u8 = undefined;
    const url = server.url(&buf, "/v1/projects/p/subscriptions/s:pull");

    const Call = struct {
        fn run(t: Transport, u: []const u8, a: Allocator) Error!Response {
            return t.send(.{ .method = .POST, .url = u, .body = "{}" }, a);
        }
    };
    var pending = try io.concurrent(Call.run, .{ ht.transport(), url, arena.allocator() });
    // Give the request time to reach the server, then cancel it.
    try io.sleep(.fromMilliseconds(100), .awake);
    try testing.expectError(error.Canceled, pending.cancel(io));
}
