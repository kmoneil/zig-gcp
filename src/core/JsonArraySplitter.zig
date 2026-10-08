//! A `std.Io.Writer` that splits one JSON array into its elements as the
//! bytes arrive: each top-level element goes to a handler the moment its
//! last byte is written, so an answer of any length is read holding one
//! element at a time. Google's streamed REST answers travel this way:
//! Firestore's `runQuery` sends one element per document, each flushed as
//! the server finds it (measured on production 2026-10-05: 50,000
//! documents, 22 MB, the first after 0.2 s).
//!
//! It checks the array's framing, brackets, commas and whitespace, and
//! finds where each element ends, minding strings and their escapes; it
//! does not check what is inside an element, which the handler parses.
//! Together they accept exactly what parsing the whole array accepts, cut
//! into writes anywhere (fuzzed below).
//!
//! Unbuffered: every write is scanned as it comes, so an element is handed
//! over without waiting for more bytes behind it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const JsonArraySplitter = @This();

gpa: Allocator,
handler: Handler,
/// The longest element held; a longer one fails the write with
/// `error.ResponseTooLarge`.
max_element_bytes: usize,
/// The element being gathered, when it spans writes.
element: std.ArrayList(u8) = .empty,
state: State = .start,
/// Open brackets inside the element being gathered.
depth: usize = 0,
in_string: bool = false,
escaped: bool = false,
/// Elements handed to the handler.
count: u64 = 0,
/// Why a write failed, once one has: `error.InvalidResponse` for bytes
/// that are no JSON array, `error.ResponseTooLarge` for an element over
/// `max_element_bytes`, `error.OutOfMemory`, or the handler's own error.
/// Every later write fails too.
failure: ?anyerror = null,
/// The interface.
writer: Writer,

/// What each element is handed to.
pub const Handler = struct {
    ptr: *anyopaque,
    /// Called once per element, in order, with its bytes, which last only
    /// for the call. An error stops the stream: the write fails, and
    /// `failure` holds the error.
    element: *const fn (ptr: *anyopaque, bytes: []const u8) anyerror!void,
};

const State = enum {
    /// Before `[`.
    start,
    /// After `[`: an element or `]`.
    first,
    /// After a comma: an element.
    next,
    /// Inside an object, an array or a string.
    nested,
    /// Inside a number, `true`, `false` or `null`, which ends at whitespace,
    /// a comma or `]`.
    scalar,
    /// After an element: a comma or `]`.
    after,
    /// After `]`: whitespace only.
    end,
};

pub fn init(gpa: Allocator, handler: Handler, max_element_bytes: usize) JsonArraySplitter {
    return .{
        .gpa = gpa,
        .handler = handler,
        .max_element_bytes = max_element_bytes,
        .writer = .{ .buffer = &.{}, .vtable = &.{ .drain = drain } },
    };
}

pub fn deinit(self: *JsonArraySplitter) void {
    self.element.deinit(self.gpa);
    self.* = undefined;
}

/// Whether the array was whole: closed, with nothing after it but
/// whitespace. Returns the failure of a write that failed, or
/// `error.InvalidResponse` for an array cut short.
pub fn finish(self: *const JsonArraySplitter) anyerror!void {
    if (self.failure) |err| return err;
    if (self.state != .end) return error.InvalidResponse;
}

/// Makes ready to take an answer again from its first byte, as a retry
/// after a connection dropped mid-answer sends it, when no element has been
/// handed over yet; returns whether it did. One that has handed some over
/// cannot start over: the handler would see them twice.
pub fn restart(self: *JsonArraySplitter) bool {
    if (self.count > 0) return false;
    self.reset();
    return true;
}

/// Makes ready to take an answer again from its first byte, whatever was
/// handed over, for a handler that has taken back what it was handed.
pub fn reset(self: *JsonArraySplitter) void {
    self.element.clearRetainingCapacity();
    self.state = .start;
    self.depth = 0;
    self.in_string = false;
    self.escaped = false;
    self.count = 0;
    self.failure = null;
}

fn drain(w: *Writer, data: []const []const u8, splat: usize) Writer.Error!usize {
    const self: *JsonArraySplitter = @alignCast(@fieldParentPtr("writer", w));
    var n: usize = 0;
    for (data[0 .. data.len - 1]) |bytes| {
        try self.feed(bytes);
        n += bytes.len;
    }
    const pattern = data[data.len - 1];
    for (0..splat) |_| {
        try self.feed(pattern);
        n += pattern.len;
    }
    return n;
}

fn feed(self: *JsonArraySplitter, bytes: []const u8) Writer.Error!void {
    if (self.failure != null) return error.WriteFailed;
    self.scan(bytes) catch |err| {
        self.failure = err;
        return error.WriteFailed;
    };
}

fn scan(self: *JsonArraySplitter, bytes: []const u8) anyerror!void {
    var i: usize = 0;
    while (i < bytes.len) {
        const c = bytes[i];
        switch (self.state) {
            .start => {
                if (c == '[') {
                    self.state = .first;
                } else if (!isSpace(c)) return error.InvalidResponse;
                i += 1;
            },
            .first, .next => {
                if (isSpace(c)) {
                    i += 1;
                } else if (c == ']' and self.state == .first) {
                    self.state = .end;
                    i += 1;
                } else {
                    // The element's first byte is gathered with the rest.
                    self.state = switch (c) {
                        '{', '[', '"' => .nested,
                        '-', '0'...'9', 't', 'f', 'n' => .scalar,
                        else => return error.InvalidResponse,
                    };
                }
            },
            .nested => i = try self.gatherNested(bytes, i),
            .scalar => i = try self.gatherScalar(bytes, i),
            .after => {
                if (c == ',') {
                    self.state = .next;
                } else if (c == ']') {
                    self.state = .end;
                } else if (!isSpace(c)) return error.InvalidResponse;
                i += 1;
            },
            .end => {
                if (!isSpace(c)) return error.InvalidResponse;
                i += 1;
            },
        }
    }
}

/// Gathers an object, an array or a string from `bytes[from..]`, handing
/// it over if it ends there. Returns where scanning goes on.
fn gatherNested(self: *JsonArraySplitter, bytes: []const u8, from: usize) anyerror!usize {
    var i = from;
    while (i < bytes.len) : (i += 1) {
        const c = bytes[i];
        if (self.in_string) {
            if (self.escaped) {
                self.escaped = false;
            } else if (c == '\\') {
                self.escaped = true;
            } else if (c == '"') {
                self.in_string = false;
                // A string element ends with its closing quote.
                if (self.depth == 0) return self.complete(bytes[from .. i + 1], i + 1);
            }
            continue;
        }
        switch (c) {
            '"' => self.in_string = true,
            '{', '[' => self.depth += 1,
            '}', ']' => {
                self.depth -= 1;
                if (self.depth == 0) return self.complete(bytes[from .. i + 1], i + 1);
            },
            else => {},
        }
    }
    try self.append(bytes[from..]);
    return bytes.len;
}

/// Gathers a number, `true`, `false` or `null` from `bytes[from..]`. What
/// ends it, whitespace, a comma or `]`, is left for the `after` state.
fn gatherScalar(self: *JsonArraySplitter, bytes: []const u8, from: usize) anyerror!usize {
    for (bytes[from..], from..) |c, i| {
        if (isSpace(c) or c == ',' or c == ']') return self.complete(bytes[from..i], i);
    }
    try self.append(bytes[from..]);
    return bytes.len;
}

/// Hands over the element whose last bytes are `tail`, and returns `next`.
fn complete(self: *JsonArraySplitter, tail: []const u8, next: usize) anyerror!usize {
    self.state = .after;
    if (self.element.items.len == 0) {
        // Whole within one write: handed over where it lies.
        if (tail.len > self.max_element_bytes) return error.ResponseTooLarge;
        self.count += 1;
        try self.handler.element(self.handler.ptr, tail);
    } else {
        try self.append(tail);
        self.count += 1;
        try self.handler.element(self.handler.ptr, self.element.items);
        self.element.clearRetainingCapacity();
    }
    return next;
}

fn append(self: *JsonArraySplitter, bytes: []const u8) anyerror!void {
    if (self.element.items.len + bytes.len > self.max_element_bytes) return error.ResponseTooLarge;
    try self.element.appendSlice(self.gpa, bytes);
}

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

const testing = std.testing;
const test_util = @import("testing.zig");

/// Keeps each element it is handed.
const Collect = struct {
    arena: std.heap.ArenaAllocator,
    elements: std.ArrayList([]const u8) = .empty,
    /// Fails the element at this index, when set.
    fail_at: ?usize = null,

    fn init(gpa: Allocator) Collect {
        return .{ .arena = .init(gpa) };
    }

    fn deinit(c: *Collect) void {
        c.arena.deinit();
    }

    fn handler(c: *Collect) Handler {
        return .{ .ptr = c, .element = element };
    }

    fn element(ptr: *anyopaque, bytes: []const u8) anyerror!void {
        const c: *Collect = @ptrCast(@alignCast(ptr));
        if (c.fail_at == c.elements.items.len) return error.HandlerSaidNo;
        const a = c.arena.allocator();
        try c.elements.append(a, try a.dupe(u8, bytes));
    }
};

/// Splits `text` written in pieces of `piece` bytes, then finishes.
fn split(c: *Collect, text: []const u8, piece: usize, max: usize) anyerror!void {
    var s: JsonArraySplitter = .init(testing.allocator, c.handler(), max);
    defer s.deinit();
    var i: usize = 0;
    while (i < text.len) : (i += piece) {
        s.writer.writeAll(text[i..@min(i + piece, text.len)]) catch return s.failure.?;
    }
    try s.finish();
}

fn expectElements(text: []const u8, expected: []const []const u8) !void {
    for ([_]usize{ 1, 2, 3, 7, text.len + 1 }) |piece| {
        var c: Collect = .init(testing.allocator);
        defer c.deinit();
        try split(&c, text, piece, 1 << 20);
        try testing.expectEqual(expected.len, c.elements.items.len);
        for (expected, c.elements.items) |e, got| try testing.expectEqualStrings(e, got);
    }
}

test "splits an array into its elements, however it is cut into writes" {
    try expectElements("[]", &.{});
    try expectElements(" \r\n[ \t]\n", &.{});
    try expectElements("[{\"a\":1}]", &.{"{\"a\":1}"});
    // As production frames a query's answer: pretty-printed, `\n,\r\n`
    // between elements.
    try expectElements("[{\n  \"document\": {\"x\": [1, {\"y\": \"]}\"}]}\n}\n,\r\n{\n  \"error\": {}\n}\n]", &.{
        "{\n  \"document\": {\"x\": [1, {\"y\": \"]}\"}]}\n}",
        "{\n  \"error\": {}\n}",
    });
    // Strings with brackets, quotes and escapes inside; escaped backslashes.
    try expectElements("[\"a]\",\"b\\\"]\",\"c\\\\\",\"\\u005d\"]", &.{ "\"a]\"", "\"b\\\"]\"", "\"c\\\\\"", "\"\\u005d\"" });
    // Scalars, which end at whitespace, a comma or the bracket.
    try expectElements("[1,-2.5e3 , true,false\n,null]", &.{ "1", "-2.5e3", "true", "false", "null" });
    try expectElements("[[],[[]],{}]", &.{ "[]", "[[]]", "{}" });
}

test "a vectored write is scanned segment by segment, its pattern as often as splatted" {
    var c: Collect = .init(testing.allocator);
    defer c.deinit();
    var s: JsonArraySplitter = .init(testing.allocator, c.handler(), 1 << 20);
    defer s.deinit();
    var pieces = [_][]const u8{ "[{\"a\":[1,", "2]}", ",\"b]\"" };
    try s.writer.writeVecAll(&pieces);
    var pattern = [_][]const u8{",null"};
    try s.writer.writeSplatAll(&pattern, 2);
    try s.writer.writeAll("]");
    try s.finish();
    try testing.expectEqual(4, c.elements.items.len);
    for ([_][]const u8{ "{\"a\":[1,2]}", "\"b]\"", "null", "null" }, c.elements.items) |e, got|
        try testing.expectEqualStrings(e, got);
}

test "framing that is no array is refused, and the failure stays" {
    for ([_][]const u8{
        "", "{}", "x", "[", "[1", "[1,", "[1,]", "[,1]", "[1 2]", "[{}{}]", "[{}", "[\"a", "[{\"a\":\"}", "[]]", "[] x", "[}]", "[:]", "[1]2",
    }) |text| {
        for ([_]usize{ 1, 3, text.len + 1 }) |piece| {
            var c: Collect = .init(testing.allocator);
            defer c.deinit();
            testing.expectError(error.InvalidResponse, split(&c, text, piece, 1 << 20)) catch |err| {
                std.debug.print("accepted: {s}\n", .{text});
                return err;
            };
        }
    }
    var c: Collect = .init(testing.allocator);
    defer c.deinit();
    var s: JsonArraySplitter = .init(testing.allocator, c.handler(), 64);
    defer s.deinit();
    try testing.expectError(error.WriteFailed, s.writer.writeAll("x"));
    try testing.expectError(error.WriteFailed, s.writer.writeAll("[]"));
    try testing.expectError(error.InvalidResponse, s.finish());
}

test "an element over the limit fails, whether it came whole or in pieces" {
    for ([_]usize{ 1, 4, 100 }) |piece| {
        var c: Collect = .init(testing.allocator);
        defer c.deinit();
        try testing.expectError(error.ResponseTooLarge, split(&c, "[\"12345\",\"123456\"]", piece, 7));
        try testing.expectEqual(1, c.elements.items.len);
        var exact: Collect = .init(testing.allocator);
        defer exact.deinit();
        try split(&exact, "[\"12345\",1234567]", piece, 7);
        try testing.expectEqual(2, exact.elements.items.len);
    }
}

test "the handler's error stops the stream, after the elements before it" {
    var c: Collect = .init(testing.allocator);
    defer c.deinit();
    c.fail_at = 1;
    try testing.expectError(error.HandlerSaidNo, split(&c, "[1,2,3]", 1, 64));
    try testing.expectEqual(1, c.elements.items.len);
}

test "an element is handed over as its last byte arrives" {
    var c: Collect = .init(testing.allocator);
    defer c.deinit();
    var s: JsonArraySplitter = .init(testing.allocator, c.handler(), 64);
    defer s.deinit();
    try s.writer.writeAll("[{\"a\":");
    try testing.expectEqual(0, c.elements.items.len);
    try s.writer.writeAll("1}");
    try testing.expectEqual(1, c.elements.items.len);
    // A scalar cannot know it has ended until what follows it arrives.
    try s.writer.writeAll(",12");
    try testing.expectEqual(1, c.elements.items.len);
    try s.writer.writeAll("]");
    try testing.expectEqual(2, c.elements.items.len);
    try testing.expectEqual(2, s.count);
    try s.finish();
}

test "restart: from the first byte again, until an element has been handed over" {
    var c: Collect = .init(testing.allocator);
    defer c.deinit();
    var s: JsonArraySplitter = .init(testing.allocator, c.handler(), 64);
    defer s.deinit();
    try s.writer.writeAll("[{\"a\":\"x");
    try testing.expect(s.restart());
    try s.writer.writeAll("[{\"b\":1}");
    try testing.expectEqualStrings("{\"b\":1}", c.elements.items[0]);
    try testing.expect(!s.restart());
    try s.writer.writeAll("]");
    try s.finish();
    // A failure is forgotten by a restart, too.
    var empty: Collect = .init(testing.allocator);
    defer empty.deinit();
    var t: JsonArraySplitter = .init(testing.allocator, empty.handler(), 64);
    defer t.deinit();
    try testing.expectError(error.WriteFailed, t.writer.writeAll("[}"));
    try testing.expect(t.restart());
    try t.writer.writeAll("[]");
    try t.finish();
}

test "reset: from the first byte again, whatever was handed over" {
    var c: Collect = .init(testing.allocator);
    defer c.deinit();
    var s: JsonArraySplitter = .init(testing.allocator, c.handler(), 64);
    defer s.deinit();
    try s.writer.writeAll("[1,{\"a\":\"x");
    try testing.expectEqual(1, s.count);
    s.reset();
    try testing.expectEqual(0, s.count);
    try testing.expect(s.restart());
    try s.writer.writeAll("[2]");
    try s.finish();
    try testing.expectEqualStrings("2", c.elements.items[1]);
}

test "splat writes are scanned like any other" {
    var c: Collect = .init(testing.allocator);
    defer c.deinit();
    var s: JsonArraySplitter = .init(testing.allocator, c.handler(), 64);
    defer s.deinit();
    try s.writer.writeAll("[1");
    try s.writer.splatBytesAll("0", 3);
    try s.writer.writeAll(",2]");
    try s.finish();
    try testing.expectEqualStrings("1000", c.elements.items[0]);
}

test "every allocation failure is OutOfMemory without leaks" {
    const Run = struct {
        fn run(gpa: Allocator) !void {
            var c: Collect = .init(testing.allocator);
            defer c.deinit();
            var s: JsonArraySplitter = .init(gpa, c.handler(), 1 << 10);
            defer s.deinit();
            for ("[{\"a\":[1,2]},\"xyz\",3]") |byte| s.writer.writeByte(byte) catch return s.failure.?;
            try s.finish();
        }
    };
    try testing.checkAllAllocationFailures(test_util.no_grow_allocator, Run.run, .{});
}

/// Parses `text` whole, the reference: its elements re-written in one
/// canonical form, or null when it is no JSON array.
fn reference(a: Allocator, text: []const u8) !?[]const []const u8 {
    const tree = std.json.parseFromSliceLeaky(std.json.Value, a, text, .{ .parse_numbers = false }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return null,
    };
    if (tree != .array) return null;
    const out = try a.alloc([]const u8, tree.array.items.len);
    for (tree.array.items, out) |item, *o| o.* = try std.json.Stringify.valueAlloc(a, item, .{});
    return out;
}

fn splitProperty(_: void, input: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var g: test_util.ByteGen = .init(input);
    // A JSON-ish text from a small alphabet, so arrays, strings and escapes
    // are common, then cut into writes at random.
    const alphabet = "[]{},:\"\\ \n\r1-e.tn0xa";
    const len = g.intRange(usize, 0, 48);
    const text = try a.alloc(u8, len);
    for (text) |*t| t.* = alphabet[g.intRange(usize, 0, alphabet.len - 1)];
    // Sometimes a well-formed array, so the accepting side is reached too.
    const chosen: []const u8 = if (g.intRange(u8, 0, 2) == 0)
        try std.fmt.allocPrint(a, "[{{\"k\":\"{s}\"}},[{s}],\"\\\\\"]", .{ "a]\\\"}", "1,2" })
    else
        text;

    const want = try reference(a, chosen);
    var c: Collect = .init(testing.allocator);
    defer c.deinit();
    var s: JsonArraySplitter = .init(testing.allocator, c.handler(), 1 << 10);
    defer s.deinit();
    var i: usize = 0;
    const written: bool = while (i < chosen.len) {
        const n = g.intRange(usize, 1, 6);
        s.writer.writeAll(chosen[i..@min(i + n, chosen.len)]) catch break false;
        i += n;
    } else true;
    const framed = written and if (s.finish()) |_| true else |_| false;
    // Each element parsed alone, as a handler parses it.
    var got: std.ArrayList([]const u8) = .empty;
    var parsed = framed;
    if (framed) for (c.elements.items) |e| {
        const v = std.json.parseFromSliceLeaky(std.json.Value, a, e, .{ .parse_numbers = false }) catch {
            parsed = false;
            break;
        };
        try got.append(a, try std.json.Stringify.valueAlloc(a, v, .{}));
    };
    if (want) |elements| {
        // A whole array: split into the same elements.
        try testing.expect(parsed);
        try testing.expectEqual(elements.len, got.items.len);
        for (elements, got.items) |e, o| try testing.expectEqualStrings(e, o);
    } else {
        // No array: the framing or an element fails.
        try testing.expect(!parsed);
    }
}

test "fuzz JsonArraySplitter: the elements of a whole parse, cut anywhere, or a failure" {
    try test_util.fuzzBytes({}, splitProperty, .{ .corpus = &.{
        "",
        "\x00\x00\x00\x00",
        "\x10\x00\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c\x0d\x0e\x0f\x10\x11",
        "\x05\x07\x01\x08\x01\x00\x01",
        // Drawn as the four bytes "[tx]": framing that holds while the
        // element fails to parse alone.
        "\x00\x00\x00\x00\x00\x00\x00\x04" ++
            "\x00\x00\x00\x00\x00\x00\x00\x00" ++
            "\x00\x00\x00\x00\x00\x00\x00\x0f" ++
            "\x00\x00\x00\x00\x00\x00\x00\x12" ++
            "\x00\x00\x00\x00\x00\x00\x00\x01" ++
            "\x01",
    } });
}

test "reference reports running out of memory instead of refusing the text" {
    try testing.expectError(error.OutOfMemory, reference(testing.failing_allocator, "[1]"));
}
