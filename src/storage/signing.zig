//! V4 signed URLs, which Cloud Storage calls `GOOG4-RSA-SHA256`: the
//! canonical request, the string to sign, and the URL around the
//! signature. The signer and the clock come from the caller. Google
//! publishes the expected output for 29 requests, and
//! tests/storage_signing.zig holds this code to every byte of it.
//!
//! The rules those vectors pin:
//! - The path keeps `/` and the RFC 3986 unreserved characters; every
//!   other byte becomes `%XX`, in uppercase hex.
//! - Query names and values are encoded the same way, `/` included, and
//!   sorted by encoded name, byte by byte. `X-Goog-Signature` goes on the
//!   end, outside what is signed.
//! - Header names are lowercased. Values lose leading and trailing spaces
//!   and tabs, and each run of them inside becomes one space. Lines are
//!   sorted by name, and `host`, always among them, is the URL's host
//!   without its port.
//! - The payload is `UNSIGNED-PAYLOAD`, unless an `x-goog-content-sha256`
//!   header is signed, whose value takes its place.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Sha256 = std.crypto.hash.sha2.Sha256;
const core = @import("core");

const Client = @import("Client.zig");
const logging = @import("logging.zig");
const types = @import("types.zig");
const Error = @import("errors.zig").Error;

pub const algorithm = "GOOG4-RSA-SHA256";

/// The longest a signed URL may work: seven days, Cloud Storage's limit.
pub const max_expires_s: u32 = 604_800;

const unsigned_payload = "UNSIGNED-PAYLOAD";

/// The query parameters the signature is made of. A caller's parameter may
/// not take one of these names in any case: the URL would carry two, and
/// which one the server reads is anyone's guess.
const reserved_params = [_][]const u8{
    "X-Goog-Algorithm",
    "X-Goog-Credential",
    "X-Goog-Date",
    "X-Goog-Expires",
    "X-Goog-SignedHeaders",
    "X-Goog-Signature",
};

/// Signs a URL for `object` in `bucket`, or for the bucket itself when
/// `object` is null. The caller has begun the call and checked both names.
pub fn signUrl(
    client: *Client,
    signer: core.Signer,
    bucket: []const u8,
    object: ?[]const u8,
    options: types.SignedUrlOptions,
) Error!types.Owned([]const u8) {
    const diag = client.diagnostics;
    try check(diag, client.base_url, bucket, object, options, signer.lifetimeS());
    const signed_at = timestamp(std.Io.Clock.real.now(client.io)) orelse {
        if (diag) |d| d.print("the clock reads a time a signed URL cannot carry: before 1970, or after 9999", .{});
        return error.InvalidSignedUrlOptions;
    };

    // The signature is a credential until the URL expires. The scratch
    // memory that held it is wiped; only the returned URL keeps a copy.
    var wiping: core.WipingAllocator = .init(client.gpa);
    var scratch: std.heap.ArenaAllocator = .init(wiping.allocator());
    defer scratch.deinit();
    const arena = scratch.allocator();

    const email = try signer.email(client.io, arena);
    if (email.len == 0) {
        if (diag) |d| d.print("the signer named no service account", .{});
        return error.SigningFailed;
    }
    const prepared = try prepare(arena, .{
        .method = options.method,
        .target = try target(arena, client.base_url, bucket, object, options.style),
        .email = email,
        .signed_at = signed_at,
        .expires_in_s = options.expires_in_s,
        .headers = options.headers,
        .query = options.query,
    });
    const signature = try signer.sign(client.io, arena, prepared.string_to_sign);
    if (signature.len == 0) {
        if (diag) |d| d.print("the signer returned an empty signature", .{});
        return error.SigningFailed;
    }

    var result: types.Owned([]const u8) = try .init(client.gpa);
    errdefer result.deinit();
    result.value = try finish(result.arena.allocator(), prepared.unsigned_url, signature);
    // Never the URL: it works for whoever holds it.
    logging.debug("signed a {t} URL for {s}/{s}, valid {d} s, signed headers {s}", .{
        options.method, bucket, object orelse "", options.expires_in_s, prepared.signed_headers,
    });
    return result;
}

/// Refuses what cannot be signed into a URL that works, and says why in
/// `diag`. Header values never reach it: they can be secrets, such as a
/// customer-supplied encryption key.
pub fn check(
    diag: ?*core.Diagnostics,
    base_url: []const u8,
    bucket: []const u8,
    object: ?[]const u8,
    options: types.SignedUrlOptions,
    lifetime_s: ?u32,
) error{InvalidSignedUrlOptions}!void {
    if (options.expires_in_s == 0 or options.expires_in_s > max_expires_s) {
        if (diag) |d| d.print("invalid expiry: a signed URL works for 1 to {d} seconds, not {d}", .{ max_expires_s, options.expires_in_s });
        return error.InvalidSignedUrlOptions;
    }
    if (lifetime_s) |limit| if (options.expires_in_s > limit) {
        if (diag) |d| d.print(
            "invalid expiry: this signer's signatures are sure to verify for {d} seconds, not {d}; IAM rotates the keys it signs with, and only a key file lasts longer",
            .{ limit, options.expires_in_s },
        );
        return error.InvalidSignedUrlOptions;
    };
    if (object) |name| if (hasDotSegment(name)) {
        if (diag) |d| d.print("the object name has a \".\" or \"..\" segment, which browsers and HTTP clients remove from a URL's path before sending it", .{});
        return error.InvalidSignedUrlOptions;
    };
    for (options.headers, 0..) |header, i| {
        if (!isSignableHeaderName(header.name)) {
            if (diag) |d| d.print("header {d}: a name is visible ASCII without ':', ';' or ','", .{i});
            return error.InvalidSignedUrlOptions;
        }
        if (std.ascii.eqlIgnoreCase(header.name, "host")) {
            if (diag) |d| d.print("header {d}: host is signed from the URL, and cannot be set", .{i});
            return error.InvalidSignedUrlOptions;
        }
        for (options.headers[0..i]) |earlier| if (std.ascii.eqlIgnoreCase(earlier.name, header.name)) {
            if (diag) |d| d.print("header {s} appears twice; a signed header has one value", .{header.name});
            return error.InvalidSignedUrlOptions;
        };
        if (!isSignableHeaderValue(header.value)) {
            if (diag) |d| d.print("header {s}: a value is printable ASCII, spaces and tabs", .{header.name});
            return error.InvalidSignedUrlOptions;
        }
    }
    for (options.query, 0..) |param, i| {
        if (param.name.len == 0) {
            if (diag) |d| d.print("query parameter {d} has no name", .{i});
            return error.InvalidSignedUrlOptions;
        }
        for (reserved_params) |reserved| if (std.ascii.eqlIgnoreCase(param.name, reserved)) {
            if (diag) |d| d.print("query parameter {d} is named {s}, which the signature itself uses", .{ i, reserved });
            return error.InvalidSignedUrlOptions;
        };
        for (options.query[0..i]) |earlier| if (std.mem.eql(u8, earlier.name, param.name)) {
            if (diag) |d| d.print("query parameter {d} repeats an earlier name", .{i});
            return error.InvalidSignedUrlOptions;
        };
    }
    checkStyle(diag, base_url, bucket, options.style) catch return error.InvalidSignedUrlOptions;
}

/// Refuses a style this bucket and this endpoint cannot carry, and says why
/// in `diag`. Shared with POST policies, whose URL has the same host rules.
pub fn checkStyle(
    diag: ?*core.Diagnostics,
    base_url: []const u8,
    bucket: []const u8,
    style: types.UrlStyle,
) error{InvalidStyle}!void {
    switch (style) {
        .path => {},
        .virtual_hosted => {
            const endpoint = splitBaseUrl(base_url);
            const endpoint_host = withoutPort(endpoint.authority);
            if (isIpLiteral(endpoint_host)) {
                if (diag) |d| d.print("virtual-hosted style puts the bucket in front of the endpoint's host name, and this endpoint is an IP address", .{});
                return error.InvalidStyle;
            }
            if (std.mem.eql(u8, endpoint.scheme, "https") and
                std.mem.indexOfScalar(u8, bucket, '.') != null and !isAppspotBucket(bucket))
            {
                if (diag) |d| d.print("a bucket name with dots cannot be virtual-hosted over https: the certificate covers one label; use path style", .{});
                return error.InvalidStyle;
            }
            var buffer: [512]u8 = undefined;
            const host = std.fmt.bufPrint(&buffer, "{s}.{s}", .{ bucket, endpoint_host }) catch "";
            if (!core.endpoint.isValidHost(host)) {
                if (diag) |d| d.print("virtual-hosted style needs a bucket name that is a host label: letters, digits and hyphens", .{});
                return error.InvalidStyle;
            }
        },
        .bucket_bound => |bound| if (!isHostAndPort(bound.host)) {
            if (diag) |d| d.print("a bucket-bound host is a host name, with an optional port, and nothing else", .{});
            return error.InvalidStyle;
        },
    }
}

/// Where a URL points: worked out from the client's endpoint and the style.
pub const Target = struct {
    /// `https` or `http`.
    scheme: []const u8,
    /// Host and port, as the URL carries them.
    authority: []const u8,
    /// Encoded: `/bucket/object`, `/bucket`, `/object` or `/`.
    path: []const u8,
};

pub fn target(
    arena: Allocator,
    base_url: []const u8,
    bucket: []const u8,
    object: ?[]const u8,
    style: types.UrlStyle,
) Allocator.Error!Target {
    const endpoint = splitBaseUrl(base_url);
    var path: Writer.Allocating = .init(arena);
    const w = &path.writer;
    w.writeByte('/') catch return error.OutOfMemory;
    if (style == .path) {
        writePath(w, bucket) catch return error.OutOfMemory;
        if (object != null) w.writeByte('/') catch return error.OutOfMemory;
    }
    if (object) |name| writePath(w, name) catch return error.OutOfMemory;
    return switch (style) {
        .path => .{ .scheme = endpoint.scheme, .authority = endpoint.authority, .path = path.written() },
        .virtual_hosted => .{
            .scheme = endpoint.scheme,
            .authority = try std.mem.concat(arena, u8, &.{ bucket, ".", endpoint.authority }),
            .path = path.written(),
        },
        .bucket_bound => |bound| .{ .scheme = @tagName(bound.scheme), .authority = bound.host, .path = path.written() },
    };
}

/// What a signed URL says, before it is signed.
pub const Request = struct {
    method: types.SignedMethod,
    target: Target,
    email: []const u8,
    /// `YYYYMMDDTHHMMSSZ`, in UTC.
    signed_at: [16]u8,
    expires_in_s: u32,
    headers: []const types.Header,
    query: []const types.QueryParam,
};

pub const Prepared = struct {
    canonical_request: []const u8,
    string_to_sign: []const u8,
    /// The lowercase names, sorted and joined by `;`, as `X-Goog-SignedHeaders` carries them.
    signed_headers: []const u8,
    /// The URL up to its signature: scheme, host, path, `?` and the
    /// canonical query.
    unsigned_url: []const u8,
};

pub fn prepare(arena: Allocator, request: Request) Allocator.Error!Prepared {
    return prepareInner(arena, request) catch return error.OutOfMemory;
}

fn prepareInner(arena: Allocator, request: Request) (Allocator.Error || Writer.Error)!Prepared {
    const lines = try arena.alloc(HeaderLine, request.headers.len + 1);
    lines[0] = .{ .name = "host", .value = withoutPort(request.target.authority) };
    for (request.headers, lines[1..]) |header, *line| {
        line.* = .{
            .name = try std.ascii.allocLowerString(arena, header.name),
            .value = try canonicalValue(arena, header.value),
        };
    }
    std.mem.sort(HeaderLine, lines, {}, HeaderLine.lessThan);
    var payload: []const u8 = unsigned_payload;
    for (lines) |line| {
        if (std.mem.eql(u8, line.name, "x-goog-content-sha256")) payload = line.value;
    }
    var names: Writer.Allocating = .init(arena);
    for (lines, 0..) |line, i| {
        if (i > 0) try names.writer.writeByte(';');
        try names.writer.writeAll(line.name);
    }
    const signed_headers = names.written();

    const date = request.signed_at[0..8];
    const scope = try std.mem.concat(arena, u8, &.{ date, "/auto/storage/goog4_request" });
    var expires: [10]u8 = undefined;
    // The five parameters the signature is made of, then the caller's.
    const pairs = try arena.alloc(Pair, 5 + request.query.len);
    pairs[0] = try .encode(arena, "X-Goog-Algorithm", algorithm);
    pairs[1] = try .encode(arena, "X-Goog-Credential", try std.mem.concat(arena, u8, &.{ request.email, "/", scope }));
    pairs[2] = try .encode(arena, "X-Goog-Date", &request.signed_at);
    pairs[3] = try .encode(arena, "X-Goog-Expires", std.fmt.bufPrint(&expires, "{d}", .{request.expires_in_s}) catch unreachable);
    pairs[4] = try .encode(arena, "X-Goog-SignedHeaders", signed_headers);
    for (request.query, pairs[5..]) |param, *pair| pair.* = try .encode(arena, param.name, param.value);
    std.mem.sort(Pair, pairs, {}, Pair.lessThan);
    var query: Writer.Allocating = .init(arena);
    for (pairs, 0..) |pair, i| {
        if (i > 0) try query.writer.writeByte('&');
        try query.writer.print("{s}={s}", .{ pair.name, pair.value });
    }
    const canonical_query = query.written();

    var canonical: Writer.Allocating = .init(arena);
    const c = &canonical.writer;
    try c.print("{t}\n{s}\n{s}\n", .{ request.method, request.target.path, canonical_query });
    for (lines) |line| try c.print("{s}:{s}\n", .{ line.name, line.value });
    try c.print("\n{s}\n{s}", .{ signed_headers, payload });
    const canonical_request = canonical.written();

    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(canonical_request, &digest, .{});
    const string_to_sign = try std.mem.concat(arena, u8, &.{
        algorithm,                           "\n",
        &request.signed_at,                  "\n",
        scope,                               "\n",
        &std.fmt.bytesToHex(digest, .lower),
    });
    const unsigned_url = try std.mem.concat(arena, u8, &.{
        request.target.scheme, "://", request.target.authority, request.target.path, "?", canonical_query,
    });
    return .{
        .canonical_request = canonical_request,
        .string_to_sign = string_to_sign,
        .signed_headers = signed_headers,
        .unsigned_url = unsigned_url,
    };
}

/// The finished URL: the signature, in lowercase hex, goes on the end.
pub fn finish(arena: Allocator, unsigned_url: []const u8, signature: []const u8) Allocator.Error![]const u8 {
    var url: Writer.Allocating = .init(arena);
    url.writer.writeAll(unsigned_url) catch return error.OutOfMemory;
    url.writer.writeAll("&X-Goog-Signature=") catch return error.OutOfMemory;
    url.writer.printHex(signature, .lower) catch return error.OutOfMemory;
    return url.written();
}

const HeaderLine = struct {
    name: []const u8,
    value: []const u8,

    fn lessThan(_: void, a: HeaderLine, b: HeaderLine) bool {
        return std.mem.lessThan(u8, a.name, b.name);
    }
};

/// A query parameter, percent-encoded.
const Pair = struct {
    name: []const u8,
    value: []const u8,

    fn encode(arena: Allocator, name: []const u8, value: []const u8) Allocator.Error!Pair {
        return .{ .name = try encodeQuery(arena, name), .value = try encodeQuery(arena, value) };
    }

    fn lessThan(_: void, a: Pair, b: Pair) bool {
        return std.mem.lessThan(u8, a.name, b.name);
    }
};

fn encodeQuery(arena: Allocator, text: []const u8) Allocator.Error![]const u8 {
    var out: Writer.Allocating = .init(arena);
    core.query.writeValue(&out.writer, text) catch return error.OutOfMemory;
    return out.written();
}

/// Signed URLs name objects the XML API's way.
const writePath = @import("names.zig").writeXmlPath;

/// Leading and trailing spaces and tabs go, and each run of them inside
/// becomes one space.
fn canonicalValue(arena: Allocator, value: []const u8) Allocator.Error![]const u8 {
    const out = try arena.alloc(u8, value.len);
    var len: usize = 0;
    var gap = false;
    for (value) |c| {
        if (c == ' ' or c == '\t') {
            gap = len > 0;
            continue;
        }
        if (gap) {
            out[len] = ' ';
            len += 1;
            gap = false;
        }
        out[len] = c;
        len += 1;
    }
    return out[0..len];
}

/// A moment in UTC, to the second.
pub const Civil = struct {
    year: u16,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,
};

/// `now` in UTC, or null outside the years 1970 to 9999: a signature can
/// carry no other year, in either of the two formats that spell one out.
pub fn civil(now: std.Io.Timestamp) ?Civil {
    const seconds = @divFloor(now.nanoseconds, std.time.ns_per_s);
    if (seconds < 0) return null;
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = std.math.cast(u64, seconds) orelse return null };
    const year_day = epoch.getEpochDay().calculateYearDay();
    if (year_day.year > 9999) return null;
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch.getDaySeconds();
    return .{
        .year = year_day.year,
        .month = month_day.month.numeric(),
        .day = @as(u8, month_day.day_index) + 1,
        .hour = day_seconds.getHoursIntoDay(),
        .minute = day_seconds.getMinutesIntoHour(),
        .second = day_seconds.getSecondsIntoMinute(),
    };
}

/// `YYYYMMDDTHHMMSSZ` for `now`, or null outside the years 1970 to 9999.
pub fn timestamp(now: std.Io.Timestamp) ?[16]u8 {
    const c = civil(now) orelse return null;
    var out: [16]u8 = undefined;
    _ = std.fmt.bufPrint(&out, "{d:0>4}{d:0>2}{d:0>2}T{d:0>2}{d:0>2}{d:0>2}Z", .{
        c.year, c.month, c.day, c.hour, c.minute, c.second,
    }) catch unreachable;
    return out;
}

const BaseUrl = struct { scheme: []const u8, authority: []const u8 };

/// A client's base URL is `scheme://host[:port]`, checked by `Client.init`.
fn splitBaseUrl(base_url: []const u8) BaseUrl {
    const at = std.mem.indexOf(u8, base_url, "://").?;
    return .{ .scheme = base_url[0..at], .authority = base_url[at + 3 ..] };
}

/// The host of `host[:port]`, brackets kept on an IPv6 literal.
fn withoutPort(authority: []const u8) []const u8 {
    if (std.mem.startsWith(u8, authority, "[")) {
        const close = std.mem.indexOfScalar(u8, authority, ']') orelse return authority;
        return authority[0 .. close + 1];
    }
    const colon = std.mem.lastIndexOfScalar(u8, authority, ':') orelse return authority;
    return authority[0..colon];
}

fn isIpLiteral(host: []const u8) bool {
    if (std.mem.startsWith(u8, host, "[")) return true;
    _ = std.Io.net.Ip4Address.parse(host, 0) catch return false;
    return true;
}

/// `PROJECT.appspot.com`: the one dotted name the certificate for
/// `*.appspot.com.storage.googleapis.com` covers.
fn isAppspotBucket(bucket: []const u8) bool {
    const suffix = ".appspot.com";
    if (!std.mem.endsWith(u8, bucket, suffix)) return false;
    const project = bucket[0 .. bucket.len - suffix.len];
    return project.len > 0 and std.mem.indexOfScalar(u8, project, '.') == null;
}

/// `host`, or `host:port`, or `[v6]` with an optional port. Nothing else:
/// no scheme, path, query or user.
fn isHostAndPort(text: []const u8) bool {
    var host = text;
    if (std.mem.startsWith(u8, text, "[")) {
        const close = std.mem.indexOfScalar(u8, text, ']') orelse return false;
        host = text[0 .. close + 1];
        if (close + 1 < text.len and !isPort(text[close + 1 ..])) return false;
    } else if (std.mem.lastIndexOfScalar(u8, text, ':')) |colon| {
        host = text[0..colon];
        if (!isPort(text[colon..])) return false;
    }
    return core.endpoint.isValidHost(host);
}

/// `:` and 1 to 5 digits of a port number.
fn isPort(text: []const u8) bool {
    if (text.len < 2 or text.len > 6 or text[0] != ':') return false;
    for (text[1..]) |c| if (!std.ascii.isDigit(c)) return false;
    _ = std.fmt.parseInt(u16, text[1..], 10) catch return false;
    return true;
}

/// Whether some `/`-separated segment is `.` or `..`. Browsers, curl and
/// WHATWG URL parsers resolve those before a request leaves, percent-encoded
/// or not, so the request would name another object.
pub fn hasDotSegment(name: []const u8) bool {
    var segments = std.mem.splitScalar(u8, name, '/');
    while (segments.next()) |segment| {
        if (std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return true;
    }
    return false;
}

/// Visible ASCII, but none of the separators the canonical request is
/// built with: `:` ends a header line's name, and `;` and `,` would split
/// `X-Goog-SignedHeaders`. Looser than an HTTP token on purpose: Google's
/// conformance vectors sign a name holding `/`.
fn isSignableHeaderName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |c| switch (c) {
        '!'...'~' => if (c == ':' or c == ';' or c == ',') return false,
        else => return false,
    };
    return true;
}

/// Printable ASCII, spaces and tabs: nothing that could end a header line
/// or reach the canonical request as anything but itself.
fn isSignableHeaderValue(value: []const u8) bool {
    for (value) |c| switch (c) {
        '\t', ' '...'~' => {},
        else => return false,
    };
    return true;
}

// Tests. Google's own vectors run in tests/storage_signing.zig, against a
// real key; these use a `FakeSigner`, so no RSA runs here.

const testing = std.testing;
const test_util = @import("test_util.zig");
const Object = @import("Object.zig");
const Bucket = @import("Bucket.zig");

const fixed_time_ns: i96 = 1_758_556_800 * std.time.ns_per_s; // 2025-09-22T16:00:00Z

test "timestamp: UTC to the second, within the years a URL can carry" {
    const at = struct {
        fn s(seconds: i64) std.Io.Timestamp {
            return .{ .nanoseconds = @as(i96, seconds) * std.time.ns_per_s };
        }
    }.s;
    try testing.expectEqualStrings("19700101T000000Z", &timestamp(at(0)).?);
    try testing.expectEqualStrings("20190201T090000Z", &timestamp(at(1_549_011_600)).?);
    try testing.expectEqualStrings("20240229T235959Z", &timestamp(at(1_709_251_199)).?);
    try testing.expectEqualStrings("20251231T235959Z", &timestamp(at(1_767_225_599)).?);
    try testing.expectEqualStrings("99991231T235959Z", &timestamp(at(253_402_300_799)).?);
    try testing.expectEqual(null, timestamp(at(253_402_300_800)));
    try testing.expectEqual(null, timestamp(at(-1)));
    // Nanoseconds are dropped, not rounded.
    try testing.expectEqualStrings("19700101T000000Z", &timestamp(.{ .nanoseconds = std.time.ns_per_s - 1 }).?);
}

test "canonicalValue: trimmed, with each run of spaces and tabs one space" {
    const cases = [_][2][]const u8{
        .{ "abc    def", "abc def" },
        .{ "    xyz", "xyz" },
        .{ "abc    ", "abc" },
        .{ "\tabc\t\t\t\tdef\t", "abc def" },
        .{ " xyz ,  abc, def  , xyz   ", "xyz , abc, def , xyz" },
        .{ "", "" },
        .{ " \t ", "" },
        .{ "a", "a" },
        .{ "2023-02-10T03:", "2023-02-10T03:" },
    };
    for (cases) |case| {
        const got = try canonicalValue(testing.allocator, case[0]);
        defer testing.allocator.free(got.ptr[0..case[0].len]);
        try testing.expectEqualStrings(case[1], got);
    }
}

test "writePath keeps / and the unreserved set, and encodes every other byte in uppercase" {
    var buffer: [256]u8 = undefined;
    const cases = [_][2][]const u8{
        .{ "path/with/slashes/under_score/amper&sand/file.ext", "path/with/slashes/under_score/amper%26sand/file.ext" },
        .{ "/leading//double/", "/leading//double/" },
        .{ "caf\xc3\xa9 menu+1%.txt", "caf%C3%A9%20menu%2B1%25.txt" },
        .{ "~-._AZaz09", "~-._AZaz09" },
        .{ "?=!#$&'()*+,:;@[]\"", "%3F%3D%21%23%24%26%27%28%29%2A%2B%2C%3A%3B%40%5B%5D%22" },
    };
    for (cases) |case| {
        var w: Writer = .fixed(&buffer);
        try writePath(&w, case[0]);
        try testing.expectEqualStrings(case[1], w.buffered());
    }
}

test "isSignableHeaderName and isSignableHeaderValue" {
    try testing.expect(isSignableHeaderName("content-type"));
    try testing.expect(isSignableHeaderName("X-Goog-Meta-Reviewer"));
    try testing.expect(isSignableHeaderName("header/name/with/slash"));
    try testing.expect(!isSignableHeaderName(""));
    try testing.expect(!isSignableHeaderName("a:b"));
    try testing.expect(!isSignableHeaderName("a;b"));
    try testing.expect(!isSignableHeaderName("a,b"));
    try testing.expect(!isSignableHeaderName("a b"));
    try testing.expect(!isSignableHeaderName("a\tb"));
    try testing.expect(!isSignableHeaderName("caf\xc3\xa9"));
    try testing.expect(!isSignableHeaderName("a\x7f"));

    try testing.expect(isSignableHeaderValue(""));
    try testing.expect(isSignableHeaderValue("\tabc  def\t"));
    try testing.expect(isSignableHeaderValue("attachment; filename=\"a:b,c\""));
    try testing.expect(!isSignableHeaderValue("1\nhost:evil"));
    try testing.expect(!isSignableHeaderValue("a\rb"));
    try testing.expect(!isSignableHeaderValue("a\x00"));
    try testing.expect(!isSignableHeaderValue("caf\xc3\xa9"));
    try testing.expect(!isSignableHeaderValue("a\x7f"));
}

test "hasDotSegment finds . and .. anywhere, and nothing else" {
    for ([_][]const u8{ ".", "..", "a/../b", "./a", "a/.", "a/..", "../a", "a/./b" }) |name| {
        try testing.expect(hasDotSegment(name));
    }
    for ([_][]const u8{ "a.b", "...", ".hidden", "a/.b", "a/b.", "/", "a//b", "..a", "a..", "%2e%2e" }) |name| {
        try testing.expect(!hasDotSegment(name));
    }
}

test "isHostAndPort: a host and an optional port, and nothing else" {
    for ([_][]const u8{ "mydomain.tld", "media.example.com:8443", "localhost", "127.0.0.1:80", "[::1]", "[::1]:4443" }) |host| {
        try testing.expect(isHostAndPort(host));
    }
    for ([_][]const u8{ "", "https://mydomain.tld", "mydomain.tld/", "mydomain.tld/path", "user@mydomain.tld", "mydomain.tld:", "mydomain.tld:99999", "mydomain.tld:+80", "my domain", "[::1", "[::1]x", "[::1]:", "mydomain.tld?q" }) |host| {
        try testing.expect(!isHostAndPort(host));
    }
}

test "withoutPort and splitBaseUrl" {
    try testing.expectEqualStrings("storage.googleapis.com", withoutPort("storage.googleapis.com"));
    try testing.expectEqualStrings("storage.googleapis.com", withoutPort("storage.googleapis.com:443"));
    try testing.expectEqualStrings("localhost", withoutPort("localhost:8080"));
    try testing.expectEqualStrings("[::1]", withoutPort("[::1]:4443"));
    try testing.expectEqualStrings("[::1]", withoutPort("[::1]"));
    const base = splitBaseUrl("http://127.0.0.1:4443");
    try testing.expectEqualStrings("http", base.scheme);
    try testing.expectEqualStrings("127.0.0.1:4443", base.authority);
}

/// A client on a fake transport, a fake clock at `fixed_time_ns` and a
/// fake signer. Initialize it in place: the client points into it.
const Harness = struct {
    fake: test_util.FakeTransport,
    clock: test_util.FakeClock,
    diag: core.Diagnostics,
    token: test_util.FakeTokenProvider,
    signer: core.testing.FakeSigner,
    client: Client,

    fn init(h: *Harness, gpa: Allocator, endpoint: ?@import("Endpoint.zig")) !void {
        h.* = .{
            .fake = .init(gpa, &.{}),
            .clock = .{ .now_ns = fixed_time_ns },
            .diag = .{},
            .token = .{},
            .signer = .{ .signature = "\xde\xad\xbe\xef" },
            .client = undefined,
        };
        errdefer h.fake.deinit();
        h.client = try .init(gpa, h.clock.io(), .{
            .endpoint = endpoint,
            .token_provider = h.token.provider(),
            .diagnostics = &h.diag,
            .transport = h.fake.transport(),
        });
    }

    fn deinit(h: *Harness) void {
        h.client.deinit();
        h.fake.deinit();
    }

    fn object(h: *Harness, bucket: []const u8, name: []const u8) Object {
        return h.client.bucket(bucket).object(name);
    }
};

const Endpoint = @import("Endpoint.zig");
const max_object_name_len = @import("validate.zig").max_object_name_len;

/// A signed URL and its string to sign, computed outside this code: by
/// Google's google-cloud-storage 3.14.1 where it agrees with the
/// conformance vectors, and by the rules alone where it does not (a port in
/// the host, a query name that is a prefix of another).
const Golden = struct {
    label: []const u8,
    endpoint: ?Endpoint = null,
    bucket: []const u8 = "photos",
    /// Null signs the bucket itself.
    object: ?[]const u8,
    options: types.SignedUrlOptions,
    /// Everything before `&X-Goog-Signature=`.
    url: []const u8,
    /// The last line of the string to sign: the canonical request's SHA-256.
    hash: []const u8,
};

const credential = "&X-Goog-Credential=signer%40test-project.iam.gserviceaccount.com%2F20250922%2Fauto%2Fstorage%2Fgoog4_request&X-Goog-Date=20250922T160000Z";

const goldens = [_]Golden{
    .{
        .label = "a GET, path style, in production",
        .object = "cats/tom.jpg",
        .options = .{ .expires_in_s = 900 },
        .url = "https://storage.googleapis.com/photos/cats/tom.jpg?X-Goog-Algorithm=GOOG4-RSA-SHA256" ++ credential ++
            "&X-Goog-Expires=900&X-Goog-SignedHeaders=host",
        .hash = "6b6fbd4237d591267a5a40f8f9ffd28eddaf14e5e5a05262508cd9f7db403046",
    },
    .{
        .label = "a PUT pinned by three headers, named in any case",
        .object = "uploads/avatar.png",
        .options = .{ .method = .PUT, .expires_in_s = 600, .headers = &.{
            .{ .name = "Content-Type", .value = "image/png" },
            .{ .name = "X-Goog-Content-Length-Range", .value = "0,5242880" },
            .{ .name = "x-goog-if-generation-match", .value = "0" },
        } },
        .url = "https://storage.googleapis.com/photos/uploads/avatar.png?X-Goog-Algorithm=GOOG4-RSA-SHA256" ++ credential ++
            "&X-Goog-Expires=600&X-Goog-SignedHeaders=content-type%3Bhost%3Bx-goog-content-length-range%3Bx-goog-if-generation-match",
        .hash = "ceac7fd982718d27f659cc769a892004149a26b34d497ddb59ef9962c019cef1",
    },
    .{
        .label = "virtual-hosted, with a response-content-disposition",
        .object = "cats/tom.jpg",
        .options = .{
            .expires_in_s = 900,
            .style = .virtual_hosted,
            .query = &.{.{ .name = "response-content-disposition", .value = "attachment; filename=\"tom.jpg\"" }},
        },
        .url = "https://photos.storage.googleapis.com/cats/tom.jpg?X-Goog-Algorithm=GOOG4-RSA-SHA256" ++ credential ++
            "&X-Goog-Expires=900&X-Goog-SignedHeaders=host&response-content-disposition=attachment%3B%20filename%3D%22tom.jpg%22",
        .hash = "a15a828ee375d54e21515ee4a153a756c093fd98a0af1cd4557cd57470063597",
    },
    .{
        .label = "a bucket-bound hostname over http",
        .object = "cats/tom.jpg",
        .options = .{ .expires_in_s = 60, .style = .{ .bucket_bound = .{ .host = "media.example.com", .scheme = .http } } },
        .url = "http://media.example.com/cats/tom.jpg?X-Goog-Algorithm=GOOG4-RSA-SHA256" ++ credential ++
            "&X-Goog-Expires=60&X-Goog-SignedHeaders=host",
        .hash = "905d7176fc760e1e80d4c8102f10ce0cd739eb310d3cbbb4797cdb374d3bacde",
    },
    .{
        .label = "a DELETE on the emulator: the port stays in the URL, not in the signed host",
        .endpoint = .{ .url = "127.0.0.1:4443", .emulator = true },
        .object = "caf\xc3\xa9 menu+1%.txt",
        .options = .{ .method = .DELETE, .expires_in_s = 1 },
        .url = "http://127.0.0.1:4443/photos/caf%C3%A9%20menu%2B1%25.txt?X-Goog-Algorithm=GOOG4-RSA-SHA256" ++ credential ++
            "&X-Goog-Expires=1&X-Goog-SignedHeaders=host",
        .hash = "8e7019c76466bb047f5e89f1e2a2e0be56491e2f6d398310bd70b7f268c19143",
    },
    .{
        .label = "the bucket itself, listed for seven days",
        .object = null,
        .options = .{ .expires_in_s = 604_800, .query = &.{
            .{ .name = "prefix", .value = "cats/" },
            .{ .name = "delimiter", .value = "/" },
        } },
        .url = "https://storage.googleapis.com/photos?X-Goog-Algorithm=GOOG4-RSA-SHA256" ++ credential ++
            "&X-Goog-Expires=604800&X-Goog-SignedHeaders=host&delimiter=%2F&prefix=cats%2F",
        .hash = "d9a4745afdb29ee265cdf718878603473e6f7c6bcacb01f5cdbe5d270b0d2686",
    },
    .{
        .label = "a signed payload hash in place of UNSIGNED-PAYLOAD",
        .object = "hello.txt",
        .options = .{ .method = .PUT, .expires_in_s = 300, .headers = &.{
            .{ .name = "x-goog-content-sha256", .value = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824" },
        } },
        .url = "https://storage.googleapis.com/photos/hello.txt?X-Goog-Algorithm=GOOG4-RSA-SHA256" ++ credential ++
            "&X-Goog-Expires=300&X-Goog-SignedHeaders=host%3Bx-goog-content-sha256",
        .hash = "0d09dcf1bd6f9569a2ff2bb78b9e105a7bb682e27eec2709c52f3e931d316c88",
    },
    .{
        .label = "a resumable start, with a header value to trim",
        .object = "big.bin",
        .options = .{ .method = .POST, .expires_in_s = 3600, .headers = &.{
            .{ .name = "x-goog-resumable", .value = "start" },
            .{ .name = "content-type", .value = "\tapplication/octet-stream  " },
        } },
        .url = "https://storage.googleapis.com/photos/big.bin?X-Goog-Algorithm=GOOG4-RSA-SHA256" ++ credential ++
            "&X-Goog-Expires=3600&X-Goog-SignedHeaders=content-type%3Bhost%3Bx-goog-resumable",
        .hash = "c34dc67e058d4cb605013951010e5a7caca05240fd48aaac97fc0c0ba0e3cbb6",
    },
    .{
        .label = "query names sorted by name, where one is a prefix of another",
        .object = "a",
        .options = .{ .expires_in_s = 10, .query = &.{
            .{ .name = "a0", .value = "3" },
            .{ .name = "a", .value = "1" },
            .{ .name = "a-b", .value = "2" },
        } },
        .url = "https://storage.googleapis.com/photos/a?X-Goog-Algorithm=GOOG4-RSA-SHA256" ++ credential ++
            "&X-Goog-Expires=10&X-Goog-SignedHeaders=host&a=1&a-b=2&a0=3",
        .hash = "1c0455e639970ea9b5d7696dca4487c43ab266b3dac5a0ea8b9798b363aad656",
    },
};

fn signGolden(h: *Harness, golden: Golden) Error!types.Owned([]const u8) {
    const bucket = h.client.bucket(golden.bucket);
    if (golden.object) |name| return bucket.object(name).signedUrl(h.signer.signer(), golden.options);
    return bucket.signedUrl(h.signer.signer(), golden.options);
}

test "golden: URLs and strings to sign that another implementation computed" {
    for (goldens) |golden| {
        errdefer std.debug.print("golden: {s}\n", .{golden.label});
        var h: Harness = undefined;
        try h.init(testing.allocator, golden.endpoint);
        defer h.deinit();
        var url = try signGolden(&h, golden);
        defer url.deinit();
        const want_url = try std.mem.concat(testing.allocator, u8, &.{ golden.url, "&X-Goog-Signature=deadbeef" });
        defer testing.allocator.free(want_url);
        try testing.expectEqualStrings(want_url, url.value);
        const want_sts = try std.mem.concat(testing.allocator, u8, &.{
            "GOOG4-RSA-SHA256\n20250922T160000Z\n20250922/auto/storage/goog4_request\n", golden.hash,
        });
        defer testing.allocator.free(want_sts);
        try testing.expectEqualStrings(want_sts, h.signer.lastMessage());
        // Nothing goes to Cloud Storage.
        try testing.expectEqual(0, h.fake.requests.items.len);
    }
}

test "prepare: the canonical request, line by line" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const prepared = try prepare(arena.allocator(), .{
        .method = .POST,
        .target = .{ .scheme = "https", .authority = "storage.googleapis.com", .path = "/photos/big.bin" },
        .email = "signer@test-project.iam.gserviceaccount.com",
        .signed_at = "20250922T160000Z".*,
        .expires_in_s = 3600,
        .headers = &.{
            .{ .name = "x-goog-resumable", .value = "start" },
            .{ .name = "content-type", .value = "\tapplication/octet-stream  " },
        },
        .query = &.{},
    });
    try testing.expectEqualStrings(
        "POST\n/photos/big.bin\nX-Goog-Algorithm=GOOG4-RSA-SHA256" ++ credential ++
            "&X-Goog-Expires=3600&X-Goog-SignedHeaders=content-type%3Bhost%3Bx-goog-resumable\n" ++
            "content-type:application/octet-stream\nhost:storage.googleapis.com\nx-goog-resumable:start\n\n" ++
            "content-type;host;x-goog-resumable\nUNSIGNED-PAYLOAD",
        prepared.canonical_request,
    );
    try testing.expectEqualStrings("content-type;host;x-goog-resumable", prepared.signed_headers);
}

test "target: every style against production, a port, and an IPv6 emulator" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const path = try target(a, "https://storage.googleapis.com:443", "b", "o/p", .path);
    try testing.expectEqualStrings("https", path.scheme);
    try testing.expectEqualStrings("storage.googleapis.com:443", path.authority);
    try testing.expectEqualStrings("/b/o/p", path.path);
    const virtual = try target(a, "https://storage.googleapis.com", "b", "o/p", .virtual_hosted);
    try testing.expectEqualStrings("b.storage.googleapis.com", virtual.authority);
    try testing.expectEqualStrings("/o/p", virtual.path);
    const bound = try target(a, "https://storage.googleapis.com", "b", null, .{ .bucket_bound = .{ .host = "[::1]:80", .scheme = .http } });
    try testing.expectEqualStrings("http", bound.scheme);
    try testing.expectEqualStrings("[::1]:80", bound.authority);
    try testing.expectEqualStrings("/", bound.path);
    const bucket_level = try target(a, "http://[::1]:4443", "b", null, .path);
    try testing.expectEqualStrings("/b", bucket_level.path);
    const prepared = try prepare(a, .{
        .method = .GET,
        .target = bucket_level,
        .email = "e",
        .signed_at = "20250922T160000Z".*,
        .expires_in_s = 1,
        .headers = &.{},
        .query = &.{},
    });
    try testing.expect(std.mem.indexOf(u8, prepared.canonical_request, "\nhost:[::1]\n") != null);
    try testing.expect(std.mem.startsWith(u8, prepared.unsigned_url, "http://[::1]:4443/b?"));
}

/// Signs `object` with `options` and expects `InvalidSignedUrlOptions`, a
/// `Diagnostics` message containing `says`, and no signature asked for.
fn expectRefused(h: *Harness, object: ?[]const u8, options: types.SignedUrlOptions, says: []const u8) !void {
    const bucket = h.client.bucket("photos");
    const calls = h.signer.calls;
    const result = if (object) |name| bucket.object(name).signedUrl(h.signer.signer(), options) else bucket.signedUrl(h.signer.signer(), options);
    try testing.expectError(error.InvalidSignedUrlOptions, result);
    if (std.mem.indexOf(u8, h.diag.message(), says) == null) {
        std.debug.print("diagnostics: {s}\nexpected to contain: {s}\n", .{ h.diag.message(), says });
        return error.TestUnexpectedDiagnostics;
    }
    try testing.expectEqual(calls, h.signer.calls);
}

fn expectSigned(h: *Harness, object: ?[]const u8, options: types.SignedUrlOptions) !void {
    const bucket = h.client.bucket("photos");
    var url = if (object) |name| try bucket.object(name).signedUrl(h.signer.signer(), options) else try bucket.signedUrl(h.signer.signer(), options);
    url.deinit();
}

test "check: expiry from 1 second to 7 days, and no longer than the signer's keys last" {
    var h: Harness = undefined;
    try h.init(testing.allocator, null);
    defer h.deinit();
    try expectRefused(&h, "o", .{ .expires_in_s = 0 }, "1 to 604800 seconds, not 0");
    try expectRefused(&h, "o", .{ .expires_in_s = 604_801 }, "not 604801");
    try expectSigned(&h, "o", .{ .expires_in_s = 1 });
    try expectSigned(&h, "o", .{ .expires_in_s = 604_800 });
    // Through IAM, Google only promises its key for 12 hours.
    h.signer.lifetime_s = 43_200;
    try expectRefused(&h, "o", .{ .expires_in_s = 43_201 }, "sure to verify for 43200 seconds, not 43201");
    try expectSigned(&h, "o", .{ .expires_in_s = 43_200 });
}

test "check: object names a browser would rewrite" {
    var h: Harness = undefined;
    try h.init(testing.allocator, null);
    defer h.deinit();
    for ([_][]const u8{ "a/../b", "./a", "a/.", "..", "a/./b/c" }) |name| {
        // "." and ".." alone fail the name check every call makes.
        const bucket = h.client.bucket("photos");
        const result = bucket.object(name).signedUrl(h.signer.signer(), .{ .expires_in_s = 60 });
        if (std.mem.eql(u8, name, "..")) {
            try testing.expectError(error.InvalidObjectName, result);
        } else {
            try testing.expectError(error.InvalidSignedUrlOptions, result);
            try testing.expect(std.mem.indexOf(u8, h.diag.message(), "segment") != null);
        }
    }
    try expectSigned(&h, "a..b/.hidden/...", .{ .expires_in_s = 60 });
}

test "check: headers that cannot be signed, and whose values never reach Diagnostics" {
    var h: Harness = undefined;
    try h.init(testing.allocator, null);
    defer h.deinit();
    const secret = "k3y-B4se64-SECRET";
    try expectRefused(&h, "o", .{ .expires_in_s = 60, .headers = &.{.{ .name = "a:b", .value = secret }} }, "header 0: a name");
    try expectRefused(&h, "o", .{ .expires_in_s = 60, .headers = &.{.{ .name = "", .value = secret }} }, "header 0: a name");
    try expectRefused(&h, "o", .{ .expires_in_s = 60, .headers = &.{.{ .name = "HOST", .value = "evil.example.com" }} }, "host is signed from the URL");
    try expectRefused(&h, "o", .{ .expires_in_s = 60, .headers = &.{
        .{ .name = "x-goog-meta-a", .value = "1" },
        .{ .name = "X-Goog-Meta-A", .value = "2" },
    } }, "header X-Goog-Meta-A appears twice");
    try expectRefused(&h, "o", .{ .expires_in_s = 60, .headers = &.{
        .{ .name = "x-goog-encryption-key", .value = secret ++ "\nhost:evil" },
    } }, "header x-goog-encryption-key: a value");
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "SECRET") == null);
    try expectRefused(&h, "o", .{ .expires_in_s = 60, .headers = &.{.{ .name = "x", .value = "caf\xc3\xa9" }} }, "header x: a value");
}

test "check: query parameters that cannot be signed" {
    var h: Harness = undefined;
    try h.init(testing.allocator, null);
    defer h.deinit();
    try expectRefused(&h, "o", .{ .expires_in_s = 60, .query = &.{.{ .name = "", .value = "v" }} }, "query parameter 0 has no name");
    for (reserved_params) |reserved| {
        const upper = try std.ascii.allocUpperString(testing.allocator, reserved);
        defer testing.allocator.free(upper);
        try expectRefused(&h, "o", .{ .expires_in_s = 60, .query = &.{.{ .name = upper, .value = "v" }} }, "which the signature itself uses");
    }
    try expectRefused(&h, "o", .{ .expires_in_s = 60, .query = &.{
        .{ .name = "prefix", .value = "a" },
        .{ .name = "prefix", .value = "b" },
    } }, "query parameter 1 repeats");
    // Names differing in case are different parameters, and any bytes go.
    try expectSigned(&h, "o", .{ .expires_in_s = 60, .query = &.{
        .{ .name = "prefix", .value = "a" },
        .{ .name = "Prefix", .value = "\x00\xff&=+" },
        .{ .name = "X-Goog-Meta-Foo", .value = "bar" },
    } });
}

test "check: virtual-hosted needs a host label for the bucket, and a host name for the endpoint" {
    var h: Harness = undefined;
    try h.init(testing.allocator, null);
    defer h.deinit();
    const virtual: types.SignedUrlOptions = .{ .expires_in_s = 60, .style = .virtual_hosted };
    try expectSigned(&h, "o", virtual);
    for ([_][]const u8{ "a.b", "www.example.com" }) |name| {
        const url = h.client.bucket(name).object("o").signedUrl(h.signer.signer(), virtual);
        try testing.expectError(error.InvalidSignedUrlOptions, url);
        try testing.expect(std.mem.indexOf(u8, h.diag.message(), "certificate covers one label") != null);
    }
    // App Engine's default bucket is the one dotted name the certificate covers.
    var appspot = try h.client.bucket("my-project.appspot.com").object("o").signedUrl(h.signer.signer(), virtual);
    appspot.deinit();
    try testing.expectError(error.InvalidSignedUrlOptions, h.client.bucket("my_bucket").object("o").signedUrl(h.signer.signer(), virtual));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "host label") != null);
    try testing.expectError(error.InvalidSignedUrlOptions, h.client.bucket("-bucket").object("o").signedUrl(h.signer.signer(), virtual));

    var ip: Harness = undefined;
    try ip.init(testing.allocator, .{ .url = "127.0.0.1:4443", .emulator = true });
    defer ip.deinit();
    try testing.expectError(error.InvalidSignedUrlOptions, ip.client.bucket("photos").object("o").signedUrl(ip.signer.signer(), virtual));
    try testing.expect(std.mem.indexOf(u8, ip.diag.message(), "IP address") != null);

    // Over plain http there is no certificate, so dots are fine.
    var named: Harness = undefined;
    try named.init(testing.allocator, .{ .url = "localhost:4443", .emulator = true });
    defer named.deinit();
    var dotted = try named.client.bucket("a.b").object("o").signedUrl(named.signer.signer(), virtual);
    defer dotted.deinit();
    try testing.expect(std.mem.startsWith(u8, dotted.value, "http://a.b.localhost:4443/o?"));
}

test "check: a bucket-bound host is a host and an optional port" {
    var h: Harness = undefined;
    try h.init(testing.allocator, null);
    defer h.deinit();
    for ([_][]const u8{ "https://media.example.com", "media.example.com/", "media.example.com:0x50", "" }) |host| {
        try expectRefused(&h, "o", .{ .expires_in_s = 60, .style = .{ .bucket_bound = .{ .host = host } } }, "bucket-bound host");
    }
    try expectSigned(&h, "o", .{ .expires_in_s = 60, .style = .{ .bucket_bound = .{ .host = "media.example.com:8443" } } });
}

test "signedUrl: names are checked like every other call" {
    var h: Harness = undefined;
    try h.init(testing.allocator, null);
    defer h.deinit();
    try testing.expectError(error.InvalidBucketName, h.client.bucket("a/b").object("o").signedUrl(h.signer.signer(), .{ .expires_in_s = 60 }));
    try testing.expectError(error.InvalidBucketName, h.client.bucket("").signedUrl(h.signer.signer(), .{ .expires_in_s = 60 }));
    try testing.expectError(error.InvalidObjectName, h.client.bucket("b").object("").signedUrl(h.signer.signer(), .{ .expires_in_s = 60 }));
    try testing.expectEqual(0, h.signer.calls);
}

test "signedUrl: a signer's failure is the call's, and an empty answer is SigningFailed" {
    var h: Harness = undefined;
    try h.init(testing.allocator, null);
    defer h.deinit();
    const object = h.object("photos", "o");
    h.signer.fail = error.SigningRejected;
    try testing.expectError(error.SigningRejected, object.signedUrl(h.signer.signer(), .{ .expires_in_s = 60 }));
    h.signer.fail = error.MetadataUnavailable;
    try testing.expectError(error.MetadataUnavailable, object.signedUrl(h.signer.signer(), .{ .expires_in_s = 60 }));
    h.signer.fail = null;
    h.signer.account = "";
    try testing.expectError(error.SigningFailed, object.signedUrl(h.signer.signer(), .{ .expires_in_s = 60 }));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "no service account") != null);
    h.signer.account = "signer@test-project.iam.gserviceaccount.com";
    h.signer.signature = "";
    try testing.expectError(error.SigningFailed, object.signedUrl(h.signer.signer(), .{ .expires_in_s = 60 }));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "empty signature") != null);
}

test "signedUrl: a clock before 1970 is refused" {
    var h: Harness = undefined;
    try h.init(testing.allocator, null);
    defer h.deinit();
    h.clock.now_ns = -std.time.ns_per_s;
    try testing.expectError(error.InvalidSignedUrlOptions, h.object("photos", "o").signedUrl(h.signer.signer(), .{ .expires_in_s = 60 }));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "clock") != null);
    try testing.expectEqual(0, h.signer.calls);
}

test "signedUrl: the log names the request, never the URL or its signature" {
    var h: Harness = undefined;
    try h.init(testing.allocator, null);
    defer h.deinit();
    logging.capture.reset();
    var url = try h.object("photos", "uploads/avatar.png").signedUrl(h.signer.signer(), goldens[1].options);
    defer url.deinit();
    try testing.expectEqualStrings(
        "debug: signed a PUT URL for photos/uploads/avatar.png, valid 600 s, signed headers content-type;host;x-goog-content-length-range;x-goog-if-generation-match\n",
        logging.capture.text(),
    );
    try testing.expect(std.mem.indexOf(u8, logging.capture.text(), "deadbeef") == null);
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "deadbeef") == null);
}

test "signedUrl: the scratch memory that held the signature is wiped" {
    var checker: core.testing.WipeChecker = .{ .child = testing.allocator };
    var h: Harness = undefined;
    try h.init(checker.allocator(), null);
    defer h.deinit();
    var url = try h.object("photos", "cats/tom.jpg").signedUrl(h.signer.signer(), .{ .expires_in_s = 60 });
    // Only the result is left to free, and it is the caller's to keep.
    try testing.expectEqual(0, checker.unwiped);
    url.deinit();
}

fn signEverything(gpa: Allocator) !void {
    var h: Harness = undefined;
    try h.init(gpa, null);
    defer h.deinit();
    for (goldens) |golden| {
        var url = try signGolden(&h, golden);
        url.deinit();
    }
}

test "signedUrl: every allocation failure is OutOfMemory, and nothing leaks" {
    try testing.checkAllAllocationFailures(testing.allocator, signEverything, .{});
}

// Properties. Each states a rule of the module comment independently of
// the code above, and holds it to arbitrary input.

fn isUpperHex(c: u8) bool {
    return (c >= '0' and c <= '9') or (c >= 'A' and c <= 'F');
}

fn pathProperty(_: void, bytes: []const u8) !void {
    // No object name is longer, and the fuzzer's longer inputs only cost time.
    const input = bytes[0..@min(bytes.len, max_object_name_len)];
    var buffer: [3 * max_object_name_len]u8 = undefined;
    var w: Writer = .fixed(&buffer);
    try writePath(&w, input);
    const encoded = w.buffered();
    // Only '/', the unreserved set, and '%' before two uppercase hex digits.
    var i: usize = 0;
    while (i < encoded.len) : (i += 1) {
        const c = encoded[i];
        if (c == '%') {
            try testing.expect(i + 2 < encoded.len);
            try testing.expect(isUpperHex(encoded[i + 1]) and isUpperHex(encoded[i + 2]));
            i += 2;
            continue;
        }
        try testing.expect(c == '/' or std.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == '_' or c == '~');
    }
    // And it decodes back to the name, byte for byte.
    var decoded: [3 * max_object_name_len]u8 = undefined;
    @memcpy(decoded[0..encoded.len], encoded);
    try testing.expectEqualSlices(u8, input, std.Uri.percentDecodeInPlace(decoded[0..encoded.len]));
}

test "fuzz signing: a path keeps / and the unreserved set, and decodes back to the name" {
    try test_util.fuzzBytes({}, pathProperty, .{ .corpus = &.{
        "",
        "/",
        "path/with/slashes/under_score/amper&sand/file.ext",
        "caf\xc3\xa9 menu+1%.txt",
        "%2F%25",
        "\x00\xff",
    } });
}

fn headerValueProperty(_: void, bytes: []const u8) !void {
    // Header values are short; 512 bytes exercise every rule.
    const input = bytes[0..@min(bytes.len, 512)];
    var buffer: [1024]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buffer);
    const once = try canonicalValue(fba.allocator(), input);
    // No tab, no space at either end, no two spaces in a row.
    try testing.expect(std.mem.indexOfScalar(u8, once, '\t') == null);
    try testing.expect(!std.mem.startsWith(u8, once, " ") and !std.mem.endsWith(u8, once, " "));
    try testing.expect(std.mem.indexOf(u8, once, "  ") == null);
    // The same words in the same order: spaces and tabs are all it changes.
    var original = std.mem.tokenizeAny(u8, input, " \t");
    var canonical = std.mem.tokenizeScalar(u8, once, ' ');
    while (original.next()) |word| try testing.expectEqualStrings(word, canonical.next() orelse return error.TestWordLost);
    try testing.expectEqual(null, canonical.next());
    // And canonicalizing again changes nothing.
    try testing.expectEqualStrings(once, try canonicalValue(fba.allocator(), once));
}

test "fuzz signing: header values canonicalize to their words, one space apart" {
    try test_util.fuzzBytes({}, headerValueProperty, .{ .corpus = &.{
        "",
        " ",
        "\t",
        "abc    def",
        "\tabc\t\t\t\tdef\t",
        " xyz ,  abc, def  , xyz   ",
    } });
}

/// Options drawn from fuzz input, and the pieces the model needs to
/// predict the canonical request without the code under test.
const Drawn = struct {
    base_url: []const u8,
    bucket: []const u8,
    object: ?[]const u8,
    options: types.SignedUrlOptions,
    email: []const u8,
    signed_at: [16]u8,
    lifetime_s: ?u32,
    headers: [4]types.Header,
    query: [4]types.QueryParam,
    name_buffers: [4][16]u8,
    value_buffers: [4][32]u8,

    /// Draws options from `g`. `valid_only` keeps to what `check` should
    /// accept, as far as the draw can tell.
    fn draw(d: *Drawn, g: *test_util.ByteGen, valid_only: bool) void {
        d.base_url = g.pick([]const u8, &.{
            "https://storage.googleapis.com",
            "https://storage.googleapis.com:443",
            "http://127.0.0.1:4443",
            "http://localhost:8080",
            "http://[::1]:9000",
        });
        d.bucket = g.pick([]const u8, &.{ "b", "test-bucket", "my-project.appspot.com", "a.b", "my_bucket" });
        d.object = if (g.intRange(u8, 0, 7) == 0) null else g.slice(40);
        d.email = g.pick([]const u8, &.{ "signer@p.iam.gserviceaccount.com", "a+b@c", "x" });
        d.signed_at = timestamp(.{ .nanoseconds = @as(i96, g.intRange(u64, 0, 253_402_300_799)) * std.time.ns_per_s }).?;
        d.lifetime_s = if (g.boolean()) null else 43_200;
        const expires = if (valid_only) g.intRange(u32, 1, max_expires_s) else g.int(u32);
        const style: types.UrlStyle = switch (g.intRange(u8, 0, 2)) {
            0 => .path,
            1 => .virtual_hosted,
            else => .{ .bucket_bound = .{
                .host = g.pick([]const u8, &.{ "media.example.com", "cdn.example.org:8443", "[::1]:80", "bad host" }),
                .scheme = if (g.boolean()) .https else .http,
            } },
        };
        const header_names = [_][]const u8{ "Content-Type", "x-goog-meta-a", "X-GOOG-META-B", "x-goog-content-sha256", "x-goog-resumable", "header/name", "Host", "a:b" };
        var header_count: usize = g.intRange(usize, 0, 4);
        var i: usize = 0;
        while (i < header_count) : (i += 1) {
            const name = g.pick([]const u8, if (valid_only) header_names[0..6] else &header_names);
            if (valid_only) for (d.headers[0..i]) |h| if (std.ascii.eqlIgnoreCase(h.name, name)) {
                header_count = i;
                break;
            };
            if (i == header_count) break;
            const raw = g.slice(d.value_buffers[i].len);
            for (raw, 0..) |c, j| {
                // Valid values keep to printable ASCII, spaces and tabs.
                d.value_buffers[i][j] = if (!valid_only) c else switch (c % 96) {
                    0 => '\t',
                    else => |k| @as(u8, @intCast(k)) + 0x1f,
                };
            }
            d.headers[i] = .{ .name = name, .value = d.value_buffers[i][0..raw.len] };
        }
        var query_count: usize = g.intRange(usize, 0, 4);
        i = 0;
        while (i < query_count) : (i += 1) {
            var name = g.slice(d.name_buffers[i].len);
            if (g.intRange(u8, 0, 7) == 0) name = g.pick([]const u8, &.{ "x-goog-date", "X-Goog-Signature", "prefix" });
            @memcpy(d.name_buffers[i][0..name.len], name);
            const own = d.name_buffers[i][0..name.len];
            if (valid_only) {
                var bad = own.len == 0;
                for (reserved_params) |r| bad = bad or std.ascii.eqlIgnoreCase(own, r);
                for (d.query[0..i]) |q| bad = bad or std.mem.eql(u8, q.name, own);
                if (bad) {
                    query_count = i;
                    break;
                }
            }
            d.query[i] = .{ .name = own, .value = g.slice(64) };
        }
        d.options = .{
            .method = g.pick(types.SignedMethod, &.{ .GET, .HEAD, .PUT, .POST, .DELETE }),
            .expires_in_s = expires,
            .headers = d.headers[0..header_count],
            .query = d.query[0..query_count],
            .style = style,
        };
    }
};

/// The canonical request, built from the rules by the plainest code that
/// states them: a lookup table, token splitting and an insertion sort.
fn modelCanonicalRequest(arena: Allocator, d: *const Drawn) ![]const u8 {
    const hex = "0123456789ABCDEF";
    const Encode = struct {
        fn run(a: Allocator, text: []const u8, keep_slash: bool) ![]const u8 {
            var out: std.ArrayList(u8) = .empty;
            for (text) |c| {
                const plain = (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or
                    c == '-' or c == '.' or c == '_' or c == '~' or (keep_slash and c == '/');
                if (plain) {
                    try out.append(a, c);
                } else {
                    try out.appendSlice(a, &.{ '%', hex[c >> 4], hex[c & 15] });
                }
            }
            return out.items;
        }
    };
    const scheme_end = std.mem.indexOf(u8, d.base_url, "://").?;
    const endpoint_authority = d.base_url[scheme_end + 3 ..];
    const authority = switch (d.options.style) {
        .path => endpoint_authority,
        .virtual_hosted => try std.fmt.allocPrint(arena, "{s}.{s}", .{ d.bucket, endpoint_authority }),
        .bucket_bound => |bound| bound.host,
    };
    // The host without its port: an IPv6 literal keeps its brackets.
    const host = if (authority[0] == '[')
        authority[0 .. std.mem.indexOfScalar(u8, authority, ']').? + 1]
    else if (std.mem.indexOfScalar(u8, authority, ':')) |colon| authority[0..colon] else authority;
    const object_path = if (d.object) |o| try Encode.run(arena, o, true) else "";
    const path = switch (d.options.style) {
        .path => if (d.object == null)
            try std.fmt.allocPrint(arena, "/{s}", .{try Encode.run(arena, d.bucket, true)})
        else
            try std.fmt.allocPrint(arena, "/{s}/{s}", .{ try Encode.run(arena, d.bucket, true), object_path }),
        else => try std.fmt.allocPrint(arena, "/{s}", .{object_path}),
    };

    const Line = struct { name: []const u8, value: []const u8 };
    var lines: std.ArrayList(Line) = .empty;
    try lines.append(arena, .{ .name = "host", .value = host });
    for (d.options.headers) |h| {
        var words: std.ArrayList([]const u8) = .empty;
        var it = std.mem.tokenizeAny(u8, h.value, " \t");
        while (it.next()) |word| try words.append(arena, word);
        try lines.append(arena, .{
            .name = try std.ascii.allocLowerString(arena, h.name),
            .value = try std.mem.join(arena, " ", words.items),
        });
    }
    insertionSort(Line, lines.items, struct {
        fn key(line: Line) []const u8 {
            return line.name;
        }
    }.key);
    var names: std.ArrayList([]const u8) = .empty;
    var payload: []const u8 = "UNSIGNED-PAYLOAD";
    for (lines.items) |line| {
        try names.append(arena, line.name);
        if (std.mem.eql(u8, line.name, "x-goog-content-sha256")) payload = line.value;
    }
    const signed_headers = try std.mem.join(arena, ";", names.items);

    const date = d.signed_at[0..8];
    const Param = struct { name: []const u8, value: []const u8 };
    var params: std.ArrayList(Param) = .empty;
    const credential_value = try std.fmt.allocPrint(arena, "{s}/{s}/auto/storage/goog4_request", .{ d.email, date });
    const expires = try std.fmt.allocPrint(arena, "{d}", .{d.options.expires_in_s});
    for ([_][2][]const u8{
        .{ "X-Goog-Algorithm", "GOOG4-RSA-SHA256" },
        .{ "X-Goog-Credential", credential_value },
        .{ "X-Goog-Date", &d.signed_at },
        .{ "X-Goog-Expires", expires },
        .{ "X-Goog-SignedHeaders", signed_headers },
    }) |pair| try params.append(arena, .{ .name = try Encode.run(arena, pair[0], false), .value = try Encode.run(arena, pair[1], false) });
    for (d.options.query) |q| try params.append(arena, .{ .name = try Encode.run(arena, q.name, false), .value = try Encode.run(arena, q.value, false) });
    insertionSort(Param, params.items, struct {
        fn key(p: Param) []const u8 {
            return p.name;
        }
    }.key);
    var query: std.ArrayList(u8) = .empty;
    for (params.items, 0..) |p, i| {
        if (i > 0) try query.append(arena, '&');
        try query.print(arena, "{s}={s}", .{ p.name, p.value });
    }

    var out: std.ArrayList(u8) = .empty;
    try out.print(arena, "{s}\n{s}\n{s}\n", .{ @tagName(d.options.method), path, query.items });
    for (lines.items) |line| try out.print(arena, "{s}:{s}\n", .{ line.name, line.value });
    try out.print(arena, "\n{s}\n{s}", .{ signed_headers, payload });
    return out.items;
}

fn insertionSort(comptime T: type, items: []T, comptime key: fn (T) []const u8) void {
    var i: usize = 1;
    while (i < items.len) : (i += 1) {
        var j = i;
        while (j > 0 and bytesBefore(key(items[j]), key(items[j - 1]))) : (j -= 1) {
            std.mem.swap(T, &items[j], &items[j - 1]);
        }
    }
}

/// Byte-by-byte order, a prefix first.
fn bytesBefore(a: []const u8, b: []const u8) bool {
    var i: usize = 0;
    while (i < a.len and i < b.len) : (i += 1) {
        if (a[i] != b[i]) return a[i] < b[i];
    }
    return a.len < b.len;
}

fn modelProperty(_: void, input: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var g: test_util.ByteGen = .init(input);
    var d: Drawn = undefined;
    d.draw(&g, true);
    // `prepare` only ever sees what `check` let through.
    check(null, d.base_url, d.bucket, d.object, d.options, d.lifetime_s) catch return;
    const prepared = try prepare(a, .{
        .method = d.options.method,
        .target = try target(a, d.base_url, d.bucket, d.object, d.options.style),
        .email = d.email,
        .signed_at = d.signed_at,
        .expires_in_s = d.options.expires_in_s,
        .headers = d.options.headers,
        .query = d.options.query,
    });
    const want = try modelCanonicalRequest(a, &d);
    try testing.expectEqualStrings(want, prepared.canonical_request);
    // The string to sign carries the canonical request's hash, and the URL
    // its path and query.
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(want, &digest, .{});
    try testing.expect(std.mem.endsWith(u8, prepared.string_to_sign, &std.fmt.bytesToHex(digest, .lower)));
    var lines = std.mem.splitScalar(u8, want, '\n');
    _ = lines.next();
    const path_line = lines.next().?;
    const query_line = lines.next().?;
    try testing.expect(std.mem.endsWith(u8, prepared.unsigned_url, try std.fmt.allocPrint(a, "{s}?{s}", .{ path_line, query_line })));
}

// Building whole requests costs about a third of a millisecond a run under
// the fuzzer, so these two are slow properties, with a nightly job of their
// own, and the storage job keeps its count.
test "slow property signing: the canonical request matches a model written from the rules" {
    try test_util.fuzzBytes({}, modelProperty, .{ .random_runs = 500, .max_len = 1024 });
}

/// `check`'s rules, stated again from section 7 of the spec, without its
/// code: true when the options should be signed.
fn allowedByRules(d: *const Drawn) bool {
    const expires = d.options.expires_in_s;
    if (expires < 1 or expires > 604_800) return false;
    if (d.lifetime_s) |limit| if (expires > limit) return false;
    if (d.object) |o| {
        var it = std.mem.splitScalar(u8, o, '/');
        while (it.next()) |segment| if (std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return false;
    }
    for (d.options.headers, 0..) |h, i| {
        if (h.name.len == 0) return false;
        for (h.name) |c| if (c < 0x21 or c > 0x7e or c == ':' or c == ';' or c == ',') return false;
        if (std.ascii.eqlIgnoreCase(h.name, "host")) return false;
        for (d.options.headers[0..i]) |earlier| if (std.ascii.eqlIgnoreCase(earlier.name, h.name)) return false;
        for (h.value) |c| if (c != '\t' and (c < 0x20 or c > 0x7e)) return false;
    }
    for (d.options.query, 0..) |q, i| {
        if (q.name.len == 0) return false;
        for ([_][]const u8{ "x-goog-algorithm", "x-goog-credential", "x-goog-date", "x-goog-expires", "x-goog-signedheaders", "x-goog-signature" }) |r| {
            if (std.ascii.eqlIgnoreCase(q.name, r)) return false;
        }
        for (d.options.query[0..i]) |earlier| if (std.mem.eql(u8, earlier.name, q.name)) return false;
    }
    switch (d.options.style) {
        .path => {},
        .virtual_hosted => {
            if (std.mem.indexOf(u8, d.base_url, "127.0.0.1") != null or std.mem.indexOf(u8, d.base_url, "[") != null) return false;
            if (std.mem.indexOfScalar(u8, d.bucket, '_') != null) return false;
            const https = std.mem.startsWith(u8, d.base_url, "https:");
            if (https and std.mem.indexOfScalar(u8, d.bucket, '.') != null and !std.mem.eql(u8, d.bucket, "my-project.appspot.com")) return false;
        },
        .bucket_bound => |bound| if (std.mem.eql(u8, bound.host, "bad host")) return false,
    }
    return true;
}

fn checkProperty(_: void, input: []const u8) !void {
    var g: test_util.ByteGen = .init(input);
    var d: Drawn = undefined;
    d.draw(&g, false);
    var diag: core.Diagnostics = .{};
    const accepted = if (check(&diag, d.base_url, d.bucket, d.object, d.options, d.lifetime_s)) true else |_| false;
    try testing.expectEqual(allowedByRules(&d), accepted);
    // A refusal always says why.
    if (!accepted) try testing.expect(diag.message().len > 0);
}

test "fuzz signing: check accepts exactly what the rules allow" {
    try test_util.fuzzBytes({}, checkProperty, .{ .random_runs = 500, .max_len = 1024 });
}

fn urlProperty(_: void, input: []const u8) !void {
    var g: test_util.ByteGen = .init(input);
    var d: Drawn = undefined;
    d.draw(&g, true);
    var h: Harness = undefined;
    const emulator = !std.mem.startsWith(u8, d.base_url, "https:");
    try h.init(testing.allocator, .{ .url = d.base_url, .emulator = emulator });
    defer h.deinit();
    h.signer.account = d.email;
    h.signer.lifetime_s = d.lifetime_s;
    const bucket = h.client.bucket(d.bucket);
    const result = if (d.object) |o| bucket.object(o).signedUrl(h.signer.signer(), d.options) else bucket.signedUrl(h.signer.signer(), d.options);
    var url = result catch |err| switch (err) {
        // The draw cannot tell every name the client refuses.
        error.InvalidSignedUrlOptions, error.InvalidObjectName => return,
        else => return err,
    };
    defer url.deinit();
    // Printable ASCII with no spaces: nothing a client could split or mangle.
    for (url.value) |c| try testing.expect(c > ' ' and c < 0x7f);
    const uri = try std.Uri.parse(url.value);
    try testing.expectEqualStrings(switch (d.options.style) {
        .bucket_bound => |bound| @tagName(bound.scheme),
        else => d.base_url[0..std.mem.indexOf(u8, d.base_url, ":").?],
    }, uri.scheme);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The path decodes to the names.
    // `parse` leaves components encoded; decode the path once, here.
    const decoded_path = std.Uri.percentDecodeInPlace(try a.dupe(u8, uri.path.percent_encoded));
    const want_path = switch (d.options.style) {
        .path => if (d.object) |o| try std.fmt.allocPrint(a, "/{s}/{s}", .{ d.bucket, o }) else try std.fmt.allocPrint(a, "/{s}", .{d.bucket}),
        else => try std.fmt.allocPrint(a, "/{s}", .{d.object orelse ""}),
    };
    try testing.expectEqualStrings(want_path, decoded_path);
    // The query: the caller's parameters and the five, then the signature.
    const query = (uri.query orelse return error.TestNoQuery).percent_encoded;
    var parts = std.mem.splitScalar(u8, query, '&');
    var seen: usize = 0;
    var last: []const u8 = "";
    while (parts.next()) |part| {
        seen += 1;
        last = part;
    }
    try testing.expectEqualStrings("X-Goog-Signature=deadbeef", last);
    try testing.expectEqual(5 + d.options.query.len + 1, seen);
    for (d.options.query) |q| {
        // First in the query when it sorts before every X-Goog- name.
        const name = try encodeQuery(a, q.name);
        const after = try std.fmt.allocPrint(a, "&{s}=", .{name});
        const first = try std.fmt.allocPrint(a, "?{s}=", .{name});
        try testing.expect(std.mem.indexOf(u8, url.value, after) != null or std.mem.indexOf(u8, url.value, first) != null);
    }
    const expires = try std.fmt.allocPrint(a, "X-Goog-Expires={d}&", .{d.options.expires_in_s});
    try testing.expect(std.mem.indexOf(u8, query, expires) != null);
}

test "slow property signing: a signed URL parses, and decodes back to what was signed" {
    try test_util.fuzzBytes({}, urlProperty, .{ .random_runs = 300, .max_len = 1024 });
}
