//! Request paths and query strings: percent-encoding for path segments and
//! query values, and a builder that appends parameters to a path.
//!
//! Path segments are encoded minimally: every character RFC 3986 allows in a
//! segment stays literal, the rest becomes `%XX`. Measured against
//! production, Google's front end decodes escapes like `%25` but leaves
//! escapes of reserved characters alone, so an encoded `+` (`%2B`) would
//! name a different resource than a literal `+`. For valid ids only `%` is
//! encoded; without that, a raw `orders%41` would address `ordersA`.
//!
//! Query values are encoded strictly: everything outside the unreserved set,
//! so `+`, `=` and `&` survive form-style decoding on the server. Values
//! that carry them are common here: page tokens, and filters such as
//! `labels.team=payments`.

const std = @import("std");
const Writer = std.Io.Writer;
const test_util = @import("testing.zig");

/// The RFC 3986 unreserved set, which never needs encoding anywhere.
pub fn isUnreserved(c: u8) bool {
    return switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~' => true,
        else => false,
    };
}

/// RFC 3986 `pchar` without `pct-encoded`: what may appear literally in a
/// path segment.
pub fn isPathChar(c: u8) bool {
    return isUnreserved(c) or switch (c) {
        '!', '$', '&', '\'', '(', ')', '*', '+', ',', ';', '=', ':', '@' => true,
        else => false,
    };
}

/// Writes `text` as one path segment: bytes outside `isPathChar` become `%XX`.
pub fn writeSegment(w: *Writer, text: []const u8) Writer.Error!void {
    return std.Uri.Component.percentEncode(w, text, isPathChar);
}

/// Writes `text` as a query name or value: bytes outside the unreserved set
/// become `%XX`.
pub fn writeValue(w: *Writer, text: []const u8) Writer.Error!void {
    return std.Uri.Component.percentEncode(w, text, isUnreserved);
}

/// Appends query parameters to a path a writer already holds: `?a=1` for the
/// first, `&b=2` for the rest. Names and values are both percent-encoded, so
/// the separators in the result are only ever the ones it wrote.
pub const Params = struct {
    w: *Writer,
    /// `?` until the first parameter is written, `&` after it.
    separator: u8 = '?',

    pub fn init(w: *Writer) Params {
        return .{ .w = w };
    }

    /// Whether anything has been written yet.
    pub fn isEmpty(self: Params) bool {
        return self.separator == '?';
    }

    pub fn add(self: *Params, name: []const u8, value: []const u8) Writer.Error!void {
        try self.w.writeByte(self.separator);
        self.separator = '&';
        try writeValue(self.w, name);
        try self.w.writeByte('=');
        try writeValue(self.w, value);
    }

    /// `add`, unless the value is null or empty: absent and blank mean the
    /// same thing to Google's front end, and leaving it out is clearer in a
    /// log or a packet capture.
    pub fn addOptional(self: *Params, name: []const u8, value: ?[]const u8) Writer.Error!void {
        const text = value orelse return;
        if (text.len == 0) return;
        return self.add(name, text);
    }

    pub fn addInt(self: *Params, name: []const u8, value: u64) Writer.Error!void {
        var buf: [20]u8 = undefined;
        return self.add(name, std.fmt.bufPrint(&buf, "{d}", .{value}) catch unreachable);
    }

    /// `addInt`, unless the value is 0, which every API here reads as "let
    /// the server choose".
    pub fn addNonZero(self: *Params, name: []const u8, value: u64) Writer.Error!void {
        if (value == 0) return;
        return self.addInt(name, value);
    }
};

const testing = std.testing;

fn expectBuilt(expected: []const u8, build: fn (*Params) Writer.Error!void) !void {
    var buf: [512]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try w.writeAll("/v1/secrets");
    var params: Params = .init(&w);
    try build(&params);
    try testing.expectEqualStrings(expected, w.buffered());
}

test "Params writes ? once and & after it" {
    try expectBuilt("/v1/secrets", struct {
        fn build(_: *Params) Writer.Error!void {}
    }.build);
    try expectBuilt("/v1/secrets?secretId=db-password", struct {
        fn build(p: *Params) Writer.Error!void {
            try p.add("secretId", "db-password");
        }
    }.build);
    try expectBuilt("/v1/secrets?pageSize=2&pageToken=abc&filter=name%3Aprod", struct {
        fn build(p: *Params) Writer.Error!void {
            try p.addNonZero("pageSize", 2);
            try p.addOptional("pageToken", "abc");
            try p.addOptional("filter", "name:prod");
        }
    }.build);
}

test "Params leaves out what the server would default anyway" {
    try expectBuilt("/v1/secrets?pageToken=t", struct {
        fn build(p: *Params) Writer.Error!void {
            try p.addNonZero("pageSize", 0);
            try p.addOptional("filter", null);
            try p.addOptional("filter", "");
            try p.addOptional("pageToken", "t");
        }
    }.build);
    // `add` writes what it is given, empty or not.
    try expectBuilt("/v1/secrets?filter=", struct {
        fn build(p: *Params) Writer.Error!void {
            try p.add("filter", "");
        }
    }.build);
}

test "Params encodes what would otherwise split the query" {
    // A Secret Manager filter holds spaces, colons, quotes and equals signs.
    try expectBuilt(
        "/v1/secrets?filter=labels.team%3Dpayments%20AND%20name%3A%22db%22",
        struct {
            fn build(p: *Params) Writer.Error!void {
                try p.add("filter", "labels.team=payments AND name:\"db\"");
            }
        }.build,
    );
    // Page tokens are opaque base64 with `+`, `/` and `=`.
    try expectBuilt("/v1/secrets?pageToken=a%2Bb%2Fc%3D%3D", struct {
        fn build(p: *Params) Writer.Error!void {
            try p.add("pageToken", "a+b/c==");
        }
    }.build);
    // A name that tried to smuggle in a second parameter cannot.
    try expectBuilt("/v1/secrets?a%26b%3Dc=1", struct {
        fn build(p: *Params) Writer.Error!void {
            try p.add("a&b=c", "1");
        }
    }.build);
}

test "addInt spans the range" {
    try expectBuilt("/v1/secrets?pageSize=0&max=18446744073709551615", struct {
        fn build(p: *Params) Writer.Error!void {
            try p.addInt("pageSize", 0);
            try p.addInt("max", std.math.maxInt(u64));
        }
    }.build);
}

test "isEmpty reports whether a query was started" {
    var buf: [64]u8 = undefined;
    var w: Writer = .fixed(&buf);
    var params: Params = .init(&w);
    try testing.expect(params.isEmpty());
    try params.addNonZero("pageSize", 0);
    try testing.expect(params.isEmpty());
    try params.add("pageSize", "1");
    try testing.expect(!params.isEmpty());
}

fn expectEncoding(encoded: []const u8, input: []const u8, comptime isAllowed: fn (u8) bool) !void {
    // Only allowed bytes and well-formed %XX escapes...
    var i: usize = 0;
    while (i < encoded.len) : (i += 1) {
        if (encoded[i] == '%') {
            try testing.expect(i + 2 < encoded.len);
            try testing.expect(std.ascii.isHex(encoded[i + 1]) and std.ascii.isHex(encoded[i + 2]));
            i += 2;
        } else {
            try testing.expect(isAllowed(encoded[i]));
        }
    }
    // ...and decoding gives the input back.
    var copy: [3 * test_util.max_fuzz_input]u8 = undefined;
    @memcpy(copy[0..encoded.len], encoded);
    try testing.expectEqualSlices(u8, input, std.Uri.percentDecodeInPlace(copy[0..encoded.len]));
}

fn encodeProperty(_: void, input: []const u8) !void {
    var buf: [3 * test_util.max_fuzz_input]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try writeSegment(&w, input);
    try expectEncoding(w.buffered(), input, isPathChar);
    // A segment never contains a separator the server would split on.
    try testing.expect(std.mem.indexOfAny(u8, w.buffered(), "/?#") == null);

    w = .fixed(&buf);
    try writeValue(&w, input);
    try expectEncoding(w.buffered(), input, isUnreserved);
}

test "fuzz percent-encoding round-trips and emits only safe bytes" {
    try test_util.fuzzBytes({}, encodeProperty, .{ .corpus = &.{
        "db-password",
        "a%41b+c",
        "labels.team=payments AND name:\"db\"",
        "\x00\xff /?#[]@!$&'()*,;=",
        "mi-secr\xc3\xa9to",
    } });
}

fn paramsProperty(_: void, input: []const u8) !void {
    var g: test_util.ByteGen = .init(input);
    const count = g.intRange(usize, 0, 6);
    var names: [6][]const u8 = undefined;
    var values: [6][]const u8 = undefined;

    var buf: [8 * test_util.max_fuzz_input]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try w.writeAll("/v1/x");
    var params: Params = .init(&w);
    for (0..count) |i| {
        names[i] = g.slice(24);
        values[i] = g.slice(24);
        try params.add(names[i], values[i]);
    }
    const built = w.buffered();
    try testing.expectEqual(count == 0, params.isEmpty());

    // The query is exactly the parameters that were added: split on the
    // separators the builder wrote, and every part decodes to its input.
    const query_at = std.mem.indexOfScalar(u8, built, '?');
    try testing.expectEqualStrings("/v1/x", built[0 .. query_at orelse built.len]);
    if (count == 0) {
        try testing.expectEqual(null, query_at);
        return;
    }
    var copy: [buf.len]u8 = undefined;
    @memcpy(copy[0..built.len], built);
    var parts = std.mem.splitScalar(u8, copy[query_at.? + 1 .. built.len], '&');
    for (0..count) |i| {
        const part = parts.next() orelse return error.TestMissingParameter;
        const equals = std.mem.indexOfScalar(u8, part, '=') orelse return error.TestMissingValue;
        try testing.expectEqualStrings(names[i], std.Uri.percentDecodeInPlace(@constCast(part[0..equals])));
        try testing.expectEqualStrings(values[i], std.Uri.percentDecodeInPlace(@constCast(part[equals + 1 ..])));
    }
    try testing.expectEqual(null, parts.next());
}

test "fuzz Params: the query parses back to exactly what was added" {
    // Seeds are shaped the way `ByteGen` reads them: an 8-byte count, then
    // an 8-byte length and that many bytes for each name and value.
    try test_util.fuzzBytes({}, paramsProperty, .{ .corpus = &.{
        "\x00\x00\x00\x00\x00\x00\x00\x00",
        "\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x08\x73\x65\x63\x72\x65\x74\x49\x64\x00\x00\x00\x00\x00\x00\x00\x0b\x64\x62\x2d\x70\x61\x73\x73\x77\x6f\x72\x64",
        "\x00\x00\x00\x00\x00\x00\x00\x02\x00\x00\x00\x00\x00\x00\x00\x05\x61\x26\x62\x3d\x63\x00\x00\x00\x00\x00\x00\x00\x01\x31\x00\x00\x00\x00\x00\x00\x00\x09\x70\x61\x67\x65\x54\x6f\x6b\x65\x6e\x00\x00\x00\x00\x00\x00\x00\x07\x61\x2b\x62\x2f\x63\x3d\x3d",
        "\x00\x00\x00\x00\x00\x00\x00\x02\x00\x00\x00\x00\x00\x00\x00\x06\x66\x69\x6c\x74\x65\x72\x00\x00\x00\x00\x00\x00\x00\x22\x6c\x61\x62\x65\x6c\x73\x2e\x74\x65\x61\x6d\x3d\x70\x61\x79\x6d\x65\x6e\x74\x73\x20\x41\x4e\x44\x20\x6e\x61\x6d\x65\x3a\x22\x64\x62\x22\x00\x00\x00\x00\x00\x00\x00\x08\x70\x61\x67\x65\x53\x69\x7a\x65\x00\x00\x00\x00\x00\x00\x00\x01\x32",
        "\x00\x00\x00\x00\x00\x00\x00\x03\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01\x25\x00\x00\x00\x00\x00\x00\x00\x03\x25\x34\x31\x00\x00\x00\x00\x00\x00\x00\x02\x00\xff\x00\x00\x00\x00\x00\x00\x00\x03\x20\x3f\x23",
        "\x00\x00\x00\x00\x00\x00\x00\x06\x00\x00\x00\x00\x00\x00\x00\x01\x70\x00\x00\x00\x00\x00\x00\x00\x01\x76\x00\x00\x00\x00\x00\x00\x00\x01\x70\x00\x00\x00\x00\x00\x00\x00\x01\x76\x00\x00\x00\x00\x00\x00\x00\x01\x70\x00\x00\x00\x00\x00\x00\x00\x01\x76\x00\x00\x00\x00\x00\x00\x00\x01\x70\x00\x00\x00\x00\x00\x00\x00\x01\x76\x00\x00\x00\x00\x00\x00\x00\x01\x70\x00\x00\x00\x00\x00\x00\x00\x01\x76\x00\x00\x00\x00\x00\x00\x00\x01\x70\x00\x00\x00\x00\x00\x00\x00\x01\x76",
    } });
}
