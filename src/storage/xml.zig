//! The little XML the XML API's multipart upload speaks: three small
//! documents to read (the start's `InitiateMultipartUploadResult`, the
//! finish's `CompleteMultipartUploadResult`, and `Error`), and one to write,
//! the finish's part list.
//!
//! The reader is strict and small. It keeps elements and their text, drops
//! attributes and namespace prefixes, and decodes the five named entities
//! and numeric references. It refuses a document type declaration outright,
//! so no entity is ever defined, let alone expanded, and it refuses
//! nesting past `max_depth`. Anything else it does not understand is
//! `error.InvalidResponse`, never a guess.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const core = @import("core");

pub const DecodeError = error{ InvalidResponse, OutOfMemory };

/// How many levels of elements a document may nest, root included: far
/// more than any document Cloud Storage sends.
pub const max_depth = 16;

/// One element: its local name, the text directly inside it, and its
/// child elements in order.
pub const Element = struct {
    /// Without any namespace prefix: `UploadId` for `s3:UploadId`.
    name: []const u8,
    /// Every piece of text directly inside, joined, entities decoded.
    text: []const u8,
    children: []const Element,

    /// The first child named `name`, or null.
    pub fn child(self: Element, name: []const u8) ?Element {
        for (self.children) |c| if (std.mem.eql(u8, c.name, name)) return c;
        return null;
    }

    /// The text of the first child named `name`, or null.
    pub fn childText(self: Element, name: []const u8) ?[]const u8 {
        return if (self.child(name)) |c| c.text else null;
    }
};

/// The document's root element. Everything returned lives in `arena`.
pub fn parse(arena: Allocator, body: []const u8) DecodeError!Element {
    var p: Parser = .{ .arena = arena, .body = body };
    return p.document();
}

/// Reads an `<Error>` body into the status and message `Diagnostics` keep:
/// its `Code` and `Message`. Null for a body that is not one, which then
/// becomes the message whole. Shaped for `core.rpc.StreamCall.decode_error`.
pub fn decodeError(arena: Allocator, body: []const u8) Allocator.Error!?core.errors.ErrorBody {
    const root = parse(arena, body) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidResponse => return null,
    };
    if (!std.mem.eql(u8, root.name, "Error")) return null;
    return .{
        .status = root.childText("Code") orelse "",
        .message = root.childText("Message") orelse "",
    };
}

/// One part as the finish names it.
pub const CompletedPart = struct {
    /// From 1.
    number: u32,
    /// As the part's response sent it, quotes and all.
    etag: []const u8,
};

/// The finish's body: every part, in the order given, which must be
/// ascending.
pub fn encodeComplete(arena: Allocator, parts: []const CompletedPart) Allocator.Error![]u8 {
    var out: Writer.Allocating = .init(arena);
    writeComplete(&out.writer, parts) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn writeComplete(w: *Writer, parts: []const CompletedPart) Writer.Error!void {
    try w.writeAll("<CompleteMultipartUpload>");
    for (parts) |part| {
        try w.print("<Part><PartNumber>{d}</PartNumber><ETag>", .{part.number});
        try writeEscaped(w, part.etag);
        try w.writeAll("</ETag></Part>");
    }
    try w.writeAll("</CompleteMultipartUpload>");
}

/// Text as element content: `&`, `<` and `>` escaped, the rest as is.
fn writeEscaped(w: *Writer, text: []const u8) Writer.Error!void {
    for (text) |c| switch (c) {
        '&' => try w.writeAll("&amp;"),
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        else => try w.writeByte(c),
    };
}

const Parser = struct {
    arena: Allocator,
    body: []const u8,
    pos: usize = 0,

    fn document(p: *Parser) DecodeError!Element {
        try p.skipMisc();
        if (!p.startsWith("<") or p.startsWith("</")) return error.InvalidResponse;
        const root = try p.element(0);
        // After the root only whitespace, comments and instructions.
        try p.skipMisc();
        if (p.pos != p.body.len) return error.InvalidResponse;
        return root;
    }

    /// Whitespace, the declaration, processing instructions and comments,
    /// in any order. A document type declaration is refused: it is the
    /// only way to define an entity, and nothing here needs one.
    fn skipMisc(p: *Parser) DecodeError!void {
        while (true) {
            p.skipSpace();
            if (p.startsWith("<?")) {
                p.pos = (std.mem.indexOfPos(u8, p.body, p.pos + 2, "?>") orelse return error.InvalidResponse) + 2;
            } else if (p.startsWith("<!--")) {
                try p.skipComment();
            } else if (p.startsWith("<!")) {
                return error.InvalidResponse;
            } else {
                return;
            }
        }
    }

    fn skipComment(p: *Parser) DecodeError!void {
        p.pos = (std.mem.indexOfPos(u8, p.body, p.pos + 4, "-->") orelse return error.InvalidResponse) + 3;
    }

    /// One element, from its `<` to the end of its closing tag.
    fn element(p: *Parser, depth: usize) DecodeError!Element {
        if (depth >= max_depth) return error.InvalidResponse;
        p.pos += 1; // '<'
        const qualified = p.name();
        if (qualified.len == 0) return error.InvalidResponse;
        const self_closing = try p.skipAttributes();
        const local = localName(qualified);
        if (self_closing) return .{ .name = local, .text = "", .children = &.{} };

        var text: std.ArrayList(u8) = .empty;
        var children: std.ArrayList(Element) = .empty;
        while (true) {
            if (p.pos >= p.body.len) return error.InvalidResponse;
            if (p.startsWith("</")) {
                p.pos += 2;
                if (!std.mem.eql(u8, p.name(), qualified)) return error.InvalidResponse;
                p.skipSpace();
                if (!p.startsWith(">")) return error.InvalidResponse;
                p.pos += 1;
                return .{
                    .name = local,
                    .text = try text.toOwnedSlice(p.arena),
                    .children = try children.toOwnedSlice(p.arena),
                };
            } else if (p.startsWith("<![CDATA[")) {
                const start = p.pos + "<![CDATA[".len;
                const end = std.mem.indexOfPos(u8, p.body, start, "]]>") orelse return error.InvalidResponse;
                try text.appendSlice(p.arena, p.body[start..end]);
                p.pos = end + 3;
            } else if (p.startsWith("<!--")) {
                try p.skipComment();
            } else if (p.startsWith("<?")) {
                p.pos = (std.mem.indexOfPos(u8, p.body, p.pos + 2, "?>") orelse return error.InvalidResponse) + 2;
            } else if (p.startsWith("<!")) {
                return error.InvalidResponse;
            } else if (p.startsWith("<")) {
                try children.append(p.arena, try p.element(depth + 1));
            } else {
                const end = std.mem.indexOfScalarPos(u8, p.body, p.pos, '<') orelse return error.InvalidResponse;
                try decodeText(p.arena, &text, p.body[p.pos..end]);
                p.pos = end;
            }
        }
    }

    /// A tag's name: everything up to space, `/`, `>` or the end.
    fn name(p: *Parser) []const u8 {
        const start = p.pos;
        while (p.pos < p.body.len) : (p.pos += 1) switch (p.body[p.pos]) {
            ' ', '\t', '\r', '\n', '/', '>', '<', '=', '"', '\'' => break,
            else => {},
        };
        return p.body[start..p.pos];
    }

    /// The rest of a start tag, attributes and all, which nothing here
    /// reads. Returns whether the tag closed itself.
    fn skipAttributes(p: *Parser) DecodeError!bool {
        while (p.pos < p.body.len) {
            switch (p.body[p.pos]) {
                '>' => {
                    p.pos += 1;
                    return false;
                },
                '/' => {
                    if (!p.startsWith("/>")) return error.InvalidResponse;
                    p.pos += 2;
                    return true;
                },
                // A quoted value may hold `>` and `/`.
                '"', '\'' => |quote| {
                    p.pos = (std.mem.indexOfScalarPos(u8, p.body, p.pos + 1, quote) orelse return error.InvalidResponse) + 1;
                },
                '<' => return error.InvalidResponse,
                else => p.pos += 1,
            }
        }
        return error.InvalidResponse;
    }

    fn skipSpace(p: *Parser) void {
        while (p.pos < p.body.len and std.ascii.isWhitespace(p.body[p.pos])) p.pos += 1;
    }

    fn startsWith(p: *const Parser, prefix: []const u8) bool {
        return std.mem.startsWith(u8, p.body[p.pos..], prefix);
    }
};

/// `UploadId` for `s3:UploadId`.
fn localName(qualified: []const u8) []const u8 {
    const colon = std.mem.lastIndexOfScalar(u8, qualified, ':') orelse return qualified;
    return qualified[colon + 1 ..];
}

/// Character data with its references decoded: `&lt;`, `&gt;`, `&amp;`,
/// `&quot;`, `&apos;`, and `&#N;` or `&#xH;` for any Unicode scalar value
/// XML allows. Anything else after `&` is refused.
fn decodeText(arena: Allocator, out: *std.ArrayList(u8), raw: []const u8) DecodeError!void {
    var i: usize = 0;
    while (i < raw.len) {
        const amp = std.mem.indexOfScalarPos(u8, raw, i, '&') orelse {
            try out.appendSlice(arena, raw[i..]);
            return;
        };
        try out.appendSlice(arena, raw[i..amp]);
        const semi = std.mem.indexOfScalarPos(u8, raw, amp, ';') orelse return error.InvalidResponse;
        const ref = raw[amp + 1 .. semi];
        const named = [_]struct { []const u8, u8 }{
            .{ "lt", '<' }, .{ "gt", '>' }, .{ "amp", '&' }, .{ "quot", '"' }, .{ "apos", '\'' },
        };
        const byte: ?u8 = for (named) |entry| {
            if (std.mem.eql(u8, ref, entry[0])) break entry[1];
        } else null;
        if (byte) |b| {
            try out.append(arena, b);
        } else {
            if (ref.len < 2 or ref[0] != '#') return error.InvalidResponse;
            const code: u21 = if (ref[1] == 'x')
                std.fmt.parseInt(u21, ref[2..], 16) catch return error.InvalidResponse
            else
                std.fmt.parseInt(u21, ref[1..], 10) catch return error.InvalidResponse;
            // A reference must name a character XML allows.
            const allowed = code == 0x9 or code == 0xa or code == 0xd or
                (code >= 0x20 and code <= 0xd7ff) or
                (code >= 0xe000 and code <= 0xfffd) or
                (code >= 0x10000 and code <= 0x10ffff);
            if (!allowed) return error.InvalidResponse;
            var buf: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(code, &buf) catch return error.InvalidResponse;
            try out.appendSlice(arena, buf[0..n]);
        }
        i = semi + 1;
    }
}

const testing = std.testing;
const test_util = @import("test_util.zig");

test "the start's answer, as Google's documentation shows it" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const root = try parse(arena.allocator(),
        \\<?xml version='1.0' encoding='UTF-8'?>
        \\<InitiateMultipartUploadResult xmlns='http://s3.amazonaws.com/doc/2006-03-01/'>
        \\  <Bucket>travel-maps</Bucket>
        \\  <Key>paris.jpg</Key>
        \\  <UploadId>VXBsb2FkIElEIGZvciBlbHZpbmcncyBteS1tb3ZpZS5tMnRzIHVwbG9hZA</UploadId>
        \\</InitiateMultipartUploadResult>
    );
    try testing.expectEqualStrings("InitiateMultipartUploadResult", root.name);
    try testing.expectEqualStrings("travel-maps", root.childText("Bucket").?);
    try testing.expectEqualStrings("paris.jpg", root.childText("Key").?);
    try testing.expectEqualStrings("VXBsb2FkIElEIGZvciBlbHZpbmcncyBteS1tb3ZpZS5tMnRzIHVwbG9hZA", root.childText("UploadId").?);
    try testing.expectEqual(null, root.childText("Missing"));
}

test "the finish's answer, and an error in its place" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const done = try parse(arena.allocator(),
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<CompleteMultipartUploadResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
        \\<Location>http://travel-maps.storage.googleapis.com/paris.jpg</Location>
        \\<Bucket>travel-maps</Bucket><Key>paris.jpg</Key>
        \\<ETag>"7fc8f92280ac3c975f300cb64412c16f-9"</ETag>
        \\</CompleteMultipartUploadResult>
    );
    try testing.expectEqualStrings("CompleteMultipartUploadResult", done.name);
    try testing.expectEqualStrings("\"7fc8f92280ac3c975f300cb64412c16f-9\"", done.childText("ETag").?);

    const failed = (try decodeError(arena.allocator(),
        \\<?xml version='1.0' encoding='UTF-8'?><Error><Code>NoSuchUpload</Code><Message>The requested upload was not found.</Message><Details>No such upload: x</Details></Error>
    )).?;
    try testing.expectEqualStrings("NoSuchUpload", failed.status);
    try testing.expectEqualStrings("The requested upload was not found.", failed.message);
    // Not an error document: the engine keeps the body whole.
    try testing.expectEqual(null, try decodeError(arena.allocator(), "<html>502</html>"));
    try testing.expectEqual(null, try decodeError(arena.allocator(), "{\"error\":{}}"));
    try testing.expectEqual(null, try decodeError(arena.allocator(), done_text));
}

const done_text = "<CompleteMultipartUploadResult><ETag>x</ETag></CompleteMultipartUploadResult>";

test "text: entities, character references, CDATA and comments" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const root = try parse(arena.allocator(),
        \\<r><a>1 &lt; 2 &amp;&amp; &quot;q&quot; &apos;s&apos; &gt;</a><b>&#233;&#x1F600;</b><c><![CDATA[<raw & kept>]]></c><d>x<!-- gone -->y</d><e/><s:f a="1/>2" b='>'>ns</s:f></r>
    );
    try testing.expectEqualStrings("1 < 2 && \"q\" 's' >", root.childText("a").?);
    try testing.expectEqualStrings("\xc3\xa9\xf0\x9f\x98\x80", root.childText("b").?);
    try testing.expectEqualStrings("<raw & kept>", root.childText("c").?);
    try testing.expectEqualStrings("xy", root.childText("d").?);
    try testing.expectEqualStrings("", root.childText("e").?);
    try testing.expectEqualStrings("ns", root.childText("f").?);
}

test "refused: everything that is not a plain, well-formed document" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const deep = "<a>" ** (max_depth + 1) ++ "</a>" ** (max_depth + 1);
    for ([_][]const u8{
        "",
        "   ",
        "just text",
        "<a>",
        "<a></b>",
        "<a></a><b></b>",
        "<a></a>trailing",
        "</a>",
        "<a>&unknown;</a>",
        "<a>&lt</a>",
        "<a>&#0;</a>",
        "<a>&#xD800;</a>",
        "<a>&#x110000;</a>",
        "<a>&#;</a>",
        "<a b=\"unterminated></a>",
        "<a/ >",
        "<a><![CDATA[never closed</a>",
        "<a><!-- never closed</a>",
        "<?xml version='1.0'",
        "<!DOCTYPE a [<!ENTITY x \"boom\">]><a>&x;</a>",
        // A declaration is refused for what it is, not for an entity it
        // happens to define: this one defines none.
        "<!DOCTYPE a><a/>",
        "<?xml version='1.0'?><!DOCTYPE a SYSTEM \"http://example.com/a.dtd\"><a/>",
        "<a><!ELEMENT b ANY></a>",
        "< a></a>",
        deep,
    }) |bad| {
        errdefer std.debug.print("accepted: {s}\n", .{bad});
        try testing.expectError(error.InvalidResponse, parse(arena.allocator(), bad));
    }
    // Exactly the limit is fine.
    const ok = "<a>" ** max_depth ++ "</a>" ** max_depth;
    _ = try parse(arena.allocator(), ok);
}

test "the finish body, written out by hand" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings(
        "<CompleteMultipartUpload>" ++
            "<Part><PartNumber>1</PartNumber><ETag>\"7778aef83f66abc1fa1e8477f296d394\"</ETag></Part>" ++
            "<Part><PartNumber>2</PartNumber><ETag>\"a&amp;b&lt;c&gt;\"</ETag></Part>" ++
            "</CompleteMultipartUpload>",
        try encodeComplete(arena.allocator(), &.{
            .{ .number = 1, .etag = "\"7778aef83f66abc1fa1e8477f296d394\"" },
            .{ .number = 2, .etag = "\"a&b<c>\"" },
        }),
    );
    try testing.expectEqualStrings("<CompleteMultipartUpload></CompleteMultipartUpload>", try encodeComplete(arena.allocator(), &.{}));
}

fn parseAnything(_: void, input: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    // Any bytes: a document or InvalidResponse, never a crash or a hang.
    if (parse(arena.allocator(), input)) |root| {
        try testing.expect(root.name.len > 0);
    } else |err| try testing.expectEqual(error.InvalidResponse, err);
    _ = try decodeError(arena.allocator(), input);
}

test "fuzz xml: any bytes parse or are refused cleanly" {
    try test_util.fuzzBytes({}, parseAnything, .{ .corpus = &.{
        "<a><b>t</b></a>",
        "<?xml version='1.0'?><Error><Code>NoSuchUpload</Code></Error>",
        "<a>&#x1F600;&amp;</a>",
        "<a><![CDATA[x]]><!--c--><b/></a>",
        "<!DOCTYPE a><a/>",
        "<a b='>'>",
    } });
}

fn completeRoundTrip(_: void, input: []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var g: test_util.ByteGen = .init(input);
    // Any ETag bytes a response header could carry, and ascending numbers.
    const parts = try arena.alloc(CompletedPart, g.intRange(usize, 0, 8));
    var number: u32 = 0;
    for (parts) |*part| {
        number += g.intRange(u32, 1, 1000);
        const etag = try arena.alloc(u8, g.intRange(usize, 0, 48));
        for (etag) |*c| c.* = g.intRange(u8, 0x20, 0x7e);
        part.* = .{ .number = number, .etag = etag };
    }
    const body = try encodeComplete(arena, parts);
    const root = try parse(arena, body);
    try testing.expectEqualStrings("CompleteMultipartUpload", root.name);
    try testing.expectEqual(parts.len, root.children.len);
    for (parts, root.children) |part, got| {
        try testing.expectEqualStrings("Part", got.name);
        var digits: [16]u8 = undefined;
        try testing.expectEqualStrings(try std.fmt.bufPrint(&digits, "{d}", .{part.number}), got.childText("PartNumber").?);
        try testing.expectEqualStrings(part.etag, got.childText("ETag").?);
    }
}

test "fuzz xml: the finish body reads back as the parts it was built from" {
    try test_util.fuzzBytes({}, completeRoundTrip, .{ .corpus = &.{
        "",
        "\x03\x00\x00\x00\x01\x05&<>\"'",
    } });
}
