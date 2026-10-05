//! Names on the wire: database and document names, the request paths built
//! from them, and field paths with their backtick quoting.
//!
//! A path here is relative to a database's documents, such as `cities/LA`
//! or `cities/LA/landmarks`. Its segments alternate collection and document
//! ids, so a document's path has an even number of them and a collection's
//! an odd one. Every segment travels percent-encoded strictly, everything
//! outside the unreserved characters as `%XX`, as Google's own REST clients
//! encode path parameters: measured in production (2026-10-05), a literal
//! `+` in a path reads as a space, so `a%20b%25c+d` named the document
//! `a b%c d`, another document, though the emulator read it as `a b%c+d`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const core = @import("core");

const validate = @import("validate.zig");

/// The most parts a handle's path is built from. `Client.doc` and
/// `Client.collection` take a whole path as one part, however deep, and
/// each `Collection.doc` or `Document.collection` adds one.
pub const max_path_parts = 8;

/// A path below a database's documents as a handle keeps it: the borrowed
/// parts it was built from, each one or more segments, joined with `/`
/// when a call sends it.
pub const Path = struct {
    parts: [max_path_parts][]const u8 = undefined,
    len: u8 = 0,
    /// A handle was derived past `max_path_parts`; every call on it fails
    /// with `error.InvalidResourceId`.
    overflow: bool = false,

    pub fn init(path: []const u8) Path {
        var p: Path = .{ .len = 1 };
        p.parts[0] = path;
        return p;
    }

    /// This path with `id` appended as a segment of its own.
    pub fn child(self: Path, id: []const u8) Path {
        var p = self;
        if (p.len == max_path_parts) {
            p.overflow = true;
            return p;
        }
        p.parts[p.len] = id;
        p.len += 1;
        return p;
    }

    /// The last segment: a handle's own id.
    pub fn last(self: Path) []const u8 {
        if (self.len == 0) return "";
        const part = self.parts[self.len - 1];
        const slash = std.mem.lastIndexOfScalar(u8, part, '/') orelse return part;
        return part[slash + 1 ..];
    }

    /// The parts joined with `/`.
    pub fn write(self: Path, w: *Writer) Writer.Error!void {
        for (self.parts[0..self.len], 0..) |part, i| {
            if (i > 0) try w.writeByte('/');
            try w.writeAll(part);
        }
    }

    /// The parts joined, in `arena`.
    pub fn join(self: Path, arena: Allocator) Allocator.Error![]u8 {
        var out: Writer.Allocating = .init(arena);
        self.write(&out.writer) catch return error.OutOfMemory;
        return out.toOwnedSlice();
    }
};

pub const Kind = enum {
    document,
    collection,

    pub fn noun(self: Kind) []const u8 {
        return switch (self) {
            .document => "document",
            .collection => "collection",
        };
    }
};

/// Why `path` is not the path of a `kind`, or null when it is: ids
/// separated by single slashes, as many as the kind needs, within the
/// depth and length limits.
pub fn pathProblem(path: []const u8, kind: Kind) ?[]const u8 {
    if (path.len == 0) return "the path is empty";
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |segment| {
        count += 1;
        if (validate.idProblem(segment)) |problem| return problem;
    }
    if (count > validate.max_path_segments) return "the path is over 100 segments deep";
    switch (kind) {
        .document => if (count % 2 != 0) return "a document path has an even number of segments, collection then document, such as \"cities/LA\"",
        .collection => if (count % 2 != 1) return "a collection path has an odd number of segments, such as \"cities\" or \"cities/LA/landmarks\"",
    }
    return null;
}

/// `projects/P/databases/D`.
pub fn writeDatabase(w: *Writer, project_id: []const u8, database_id: []const u8) Writer.Error!void {
    try w.print("projects/{s}/databases/{s}", .{ project_id, database_id });
}

/// The full name of the document or collection at `path`:
/// `projects/P/databases/D/documents/PATH`, unencoded, as references and
/// response names carry it.
pub fn fullName(arena: Allocator, project_id: []const u8, database_id: []const u8, path: []const u8) Allocator.Error![]u8 {
    return std.fmt.allocPrint(arena, "projects/{s}/databases/{s}/documents/{s}", .{ project_id, database_id, path });
}

/// Writes the request path for `path`, `/v1/projects/P/databases/D/documents`
/// and then each segment percent-encoded; an empty `path` is the root.
/// Project and database ids are checked before any path is built, and need
/// no encoding: `(default)`'s parentheses are legal in a segment.
pub fn writeDocumentsPath(w: *Writer, project_id: []const u8, database_id: []const u8, path: []const u8) Writer.Error!void {
    try w.writeAll("/v1/");
    try writeDatabase(w, project_id, database_id);
    try w.writeAll("/documents");
    if (path.len == 0) return;
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |segment| {
        try w.writeByte('/');
        try core.query.writeStrictSegment(w, segment);
    }
}

/// The path below the database's documents in a full document name, or
/// null when `name` is not one: `cities/LA` from
/// `projects/p/databases/(default)/documents/cities/LA`.
pub fn relativePath(name: []const u8) ?[]const u8 {
    const marker = "/documents/";
    const at = std.mem.indexOf(u8, name, marker) orelse return null;
    if (!std.mem.startsWith(u8, name, "projects/")) return null;
    const rest = name[at + marker.len ..];
    if (rest.len == 0) return null;
    return rest;
}

/// Why `name` is not a full document name, for a `reference` value, or
/// null when it is.
pub fn referenceProblem(name: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, name, '/');
    if (!std.mem.eql(u8, it.next() orelse "", "projects")) return "a reference is a full document name, projects/P/databases/D/documents/PATH";
    const project = it.next() orelse "";
    if (!core.names.isProjectId(project)) return "a reference names no valid project";
    if (!std.mem.eql(u8, it.next() orelse "", "databases")) return "a reference is a full document name, projects/P/databases/D/documents/PATH";
    if (!validate.isDatabaseId(it.next() orelse "")) return "a reference names no valid database";
    if (!std.mem.eql(u8, it.next() orelse "", "documents")) return "a reference is a full document name, projects/P/databases/D/documents/PATH";
    if (name.len > validate.max_name_bytes) return "a reference is over 6 KiB";
    return pathProblem(it.rest(), .document);
}

// Field paths

/// Whether `segment` can be written in a field path as it is: a letter or
/// `_`, then letters, digits and `_`. Anything else is quoted.
pub fn isSimpleSegment(segment: []const u8) bool {
    if (segment.len == 0) return false;
    for (segment, 0..) |c, i| switch (c) {
        'a'...'z', 'A'...'Z', '_' => {},
        '0'...'9' => if (i == 0) return false,
        else => return false,
    };
    return true;
}

/// Writes the field name `name` as one field path segment: as it is when
/// simple, else in backticks with `` ` `` and `\` escaped by a backslash.
pub fn writeFieldSegment(w: *Writer, name: []const u8) Writer.Error!void {
    if (isSimpleSegment(name)) return w.writeAll(name);
    try w.writeByte('`');
    for (name) |c| {
        if (c == '`' or c == '\\') try w.writeByte('\\');
        try w.writeByte(c);
    }
    try w.writeByte('`');
}

/// The field path of the single field `name`, quoted as needed, in `arena`.
pub fn fieldPathOf(arena: Allocator, name: []const u8) Allocator.Error![]u8 {
    var out: Writer.Allocating = .init(arena);
    writeFieldSegment(&out.writer, name) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

/// Steps through a field path's segments, unquoting each. The grammar is
/// the server's own, as its refusals state it: a simple segment matches
/// `[a-zA-Z_][a-zA-Z_0-9]*`, a quoted one `` `(?:[^`\\]|(?:\\.))+` ``, and
/// dots separate them.
pub const FieldPathIterator = struct {
    text: []const u8,
    index: usize = 0,
    done: bool = false,

    pub const Segment = struct {
        /// As written, quotes and escapes included.
        raw: []const u8,
        quoted: bool,

        /// The field name, unescaped, into `buf`, which needs `raw.len`
        /// bytes.
        pub fn name(self: Segment, buf: []u8) []const u8 {
            if (!self.quoted) {
                @memcpy(buf[0..self.raw.len], self.raw);
                return buf[0..self.raw.len];
            }
            var n: usize = 0;
            var i: usize = 1;
            while (i < self.raw.len - 1) : (i += 1) {
                if (self.raw[i] == '\\') i += 1;
                buf[n] = self.raw[i];
                n += 1;
            }
            return buf[0..n];
        }

        /// Whether this segment names `name`.
        pub fn eql(self: Segment, name_text: []const u8) bool {
            if (!self.quoted) return std.mem.eql(u8, self.raw, name_text);
            var j: usize = 0;
            var i: usize = 1;
            while (i < self.raw.len - 1) : (i += 1) {
                if (self.raw[i] == '\\') i += 1;
                if (j >= name_text.len or name_text[j] != self.raw[i]) return false;
                j += 1;
            }
            return j == name_text.len;
        }
    };

    pub fn init(text: []const u8) FieldPathIterator {
        return .{ .text = text };
    }

    /// The next segment, null after the last, or `error.InvalidFieldPath`
    /// where the text breaks the grammar.
    pub fn next(self: *FieldPathIterator) error{InvalidFieldPath}!?Segment {
        if (self.done) return null;
        const t = self.text;
        const start = self.index;
        if (start >= t.len) return error.InvalidFieldPath;
        var end = start;
        var quoted = false;
        if (t[start] == '`') {
            quoted = true;
            end += 1;
            while (true) {
                if (end >= t.len) return error.InvalidFieldPath;
                switch (t[end]) {
                    '\\' => {
                        if (end + 1 >= t.len) return error.InvalidFieldPath;
                        end += 2;
                    },
                    '`' => break,
                    else => end += 1,
                }
            }
            if (end == start + 1) return error.InvalidFieldPath;
            end += 1;
        } else {
            while (end < t.len and t[end] != '.') end += 1;
            if (!isSimpleSegment(t[start..end])) return error.InvalidFieldPath;
        }
        if (end == t.len) {
            self.done = true;
        } else {
            if (t[end] != '.') return error.InvalidFieldPath;
            // A trailing dot leaves an empty last segment.
            if (end + 1 == t.len) return error.InvalidFieldPath;
            self.index = end + 1;
        }
        return .{ .raw = t[start..end], .quoted = quoted };
    }
};

/// Why `path` is not a field path a request may carry, or null when it is:
/// the grammar, at most 1,499 bytes (production refuses 1,500, though the
/// documentation allows it), and no reserved `__x__` name but a lone
/// `__name__`.
pub fn fieldPathProblem(path: []const u8) ?[]const u8 {
    if (path.len == 0) return "a field path is empty";
    if (path.len > validate.max_field_path_bytes) return "a field path is 1,500 bytes or longer: \"property path is longer than 1500 bytes.\"";
    if (std.mem.eql(u8, path, "__name__")) return null;
    var it: FieldPathIterator = .init(path);
    while (it.next() catch return "a field path breaks the grammar: segments are letters, digits and _ not starting with a digit, or quoted in backticks, separated by dots") |segment| {
        if (segment.raw.len >= 4 and isReservedQuotedOrNot(segment)) return "a field path names a reserved field, __x__";
    }
    return null;
}

fn isReservedQuotedOrNot(segment: FieldPathIterator.Segment) bool {
    var buf: [validate.max_field_path_bytes]u8 = undefined;
    return validate.isReservedName(segment.name(&buf));
}

/// Whether one of two field paths, both valid, is the other or names a
/// field inside it: `a` and `a.b` overlap, `a.b` and `a.c` do not.
pub fn fieldPathsOverlap(a: []const u8, b: []const u8) bool {
    var ia: FieldPathIterator = .init(a);
    var ib: FieldPathIterator = .init(b);
    var buf: [validate.max_field_path_bytes]u8 = undefined;
    while (true) {
        const sa = (ia.next() catch return false) orelse return true;
        const sb = (ib.next() catch return false) orelse return true;
        if (!sb.eql(sa.name(&buf))) return false;
    }
}

/// Whether two valid field paths name the same field, however quoted:
/// `a.b` and `` `a`.b ``.
pub fn fieldPathsEqual(a: []const u8, b: []const u8) bool {
    var ia: FieldPathIterator = .init(a);
    var ib: FieldPathIterator = .init(b);
    var buf: [validate.max_field_path_bytes]u8 = undefined;
    while (true) {
        const sa = (ia.next() catch return false) orelse return (ib.next() catch return false) == null;
        const sb = (ib.next() catch return false) orelse return false;
        if (!sb.eql(sa.name(&buf))) return false;
    }
}

/// The first segment of a valid field path, unquoted, into `buf`.
pub fn firstFieldName(path: []const u8, buf: []u8) []const u8 {
    var it: FieldPathIterator = .init(path);
    const segment = (it.next() catch return path) orelse return path;
    return segment.name(buf);
}

const testing = std.testing;
const test_util = @import("test_util.zig");

test "Path joins its parts, and knows its last segment" {
    var buf: [128]u8 = undefined;
    var w: Writer = .fixed(&buf);
    const p = Path.init("cities/LA").child("landmarks").child("tower");
    try p.write(&w);
    try testing.expectEqualStrings("cities/LA/landmarks/tower", w.buffered());
    try testing.expectEqualStrings("tower", p.last());
    try testing.expectEqualStrings("LA", Path.init("cities/LA").last());
    try testing.expectEqualStrings("cities", Path.init("cities").last());
    try testing.expect(!p.overflow);
}

test "Path: deriving past max_path_parts marks it, never writes past the array" {
    var p = Path.init("a");
    for (1..max_path_parts) |_| p = p.child("x");
    try testing.expect(!p.overflow);
    try testing.expectEqual(max_path_parts, p.len);
    p = p.child("y");
    try testing.expect(p.overflow);
    try testing.expectEqual(max_path_parts, p.len);
    // Deriving further from an overflowed path keeps it overflowed.
    try testing.expect(p.child("z").overflow);
}

test "pathProblem: parity, ids, depth" {
    try testing.expectEqual(null, pathProblem("cities/LA", .document));
    try testing.expectEqual(null, pathProblem("cities", .collection));
    try testing.expectEqual(null, pathProblem("cities/LA/landmarks", .collection));
    try testing.expectEqual(null, pathProblem("c/a b%c+d", .document));
    try testing.expectEqual(null, pathProblem("c/a:b", .document));
    try testing.expectEqual(null, pathProblem("c/été", .document));
    try testing.expect(pathProblem("cities", .document) != null);
    try testing.expect(pathProblem("cities/LA", .collection) != null);
    try testing.expect(pathProblem("", .collection) != null);
    try testing.expect(pathProblem("/cities", .collection) != null);
    try testing.expect(pathProblem("cities/", .document) != null);
    try testing.expect(pathProblem("cities//LA", .document) != null);
    try testing.expect(pathProblem("cities/..", .document) != null);
    try testing.expect(pathProblem("cities/__x__", .document) != null);

    var deep: [200 * 2]u8 = undefined;
    for (0..200) |i| {
        deep[i * 2] = 'a';
        deep[i * 2 + 1] = '/';
    }
    try testing.expectEqual(null, pathProblem(deep[0 .. 100 * 2 - 1], .document));
    try testing.expect(pathProblem(deep[0 .. 102 * 2 - 1], .document) != null);
}

test "regression: writeDocumentsPath encodes every segment strictly, `+` and `:` included; (default) kept" {
    // Until 0.34.0 a `+` went literal, which production reads as a space:
    // a read of `a b%c+d` asked for `a b%c d`.
    var buf: [256]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try writeDocumentsPath(&w, "p", "(default)", "c/a b%c+d/sub/a:b");
    try testing.expectEqualStrings("/v1/projects/p/databases/(default)/documents/c/a%20b%25c%2Bd/sub/a%3Ab", w.buffered());
    w = .fixed(&buf);
    try writeDocumentsPath(&w, "p", "(default)", "c/x?y#z/s/[b]~é");
    try testing.expectEqualStrings("/v1/projects/p/databases/(default)/documents/c/x%3Fy%23z/s/%5Bb%5D~%C3%A9", w.buffered());
    w = .fixed(&buf);
    try writeDocumentsPath(&w, "p", "zigps-fs-1", "");
    try testing.expectEqualStrings("/v1/projects/p/databases/zigps-fs-1/documents", w.buffered());
    w = .fixed(&buf);
    try writeDocumentsPath(&w, "p", "(default)", "c/\xc3\xa9t\xc3\xa9");
    try testing.expectEqualStrings("/v1/projects/p/databases/(default)/documents/c/%C3%A9t%C3%A9", w.buffered());
}

test "relativePath and referenceProblem" {
    try testing.expectEqualStrings("cities/LA", relativePath("projects/p/databases/(default)/documents/cities/LA").?);
    try testing.expectEqual(null, relativePath("projects/p/databases/(default)/documents/"));
    try testing.expectEqual(null, relativePath("cities/LA"));

    try testing.expectEqual(null, referenceProblem("projects/p/databases/(default)/documents/cities/LA"));
    try testing.expectEqual(null, referenceProblem("projects/q/databases/other-db/documents/c/x/d/y"));
    try testing.expect(referenceProblem("projects/p/databases/(default)/documents/cities") != null);
    try testing.expect(referenceProblem("cities/LA") != null);
    try testing.expect(referenceProblem("projects/p/databases/BAD/documents/c/x") != null);
    try testing.expect(referenceProblem("projects/p/databases/(default)/docs/c/x") != null);
    try testing.expect(referenceProblem("projects/p/databases/(default)/documents") != null);
    try testing.expect(referenceProblem("projects/a b/databases/(default)/documents/c/x") != null);
}

fn expectSegments(path: []const u8, expected: []const []const u8) !void {
    var it: FieldPathIterator = .init(path);
    var buf: [64]u8 = undefined;
    for (expected) |e| {
        const s = (try it.next()) orelse return error.TestExpectedSegment;
        try testing.expectEqualStrings(e, s.name(&buf));
        try testing.expect(s.eql(e));
    }
    try testing.expectEqual(null, try it.next());
}

test "field paths: simple and quoted segments, the server's grammar" {
    try expectSegments("a", &.{"a"});
    try expectSegments("a.b_2._c", &.{ "a", "b_2", "_c" });
    try expectSegments("`a-b`.c", &.{ "a-b", "c" });
    try expectSegments("`c\\`d`", &.{"c`d"});
    try expectSegments("`a\\\\b`", &.{"a\\b"});
    // A backslash escapes any character, as the server's regex allows.
    try expectSegments("`a\\b`", &.{"ab"});
    try expectSegments("`a.b`.` `", &.{ "a.b", " " });
    try expectSegments("`1a`", &.{"1a"});

    for ([_][]const u8{ "", ".", "a.", ".a", "a..b", "1a", "a-b", "``", "`a", "`a\\`", "`a`b", "a`b`", "`a`.", "a b" }) |bad| {
        var it: FieldPathIterator = .init(bad);
        const result: anyerror!void = while (true) {
            if ((it.next() catch |err| break err) == null) break {};
        };
        testing.expectError(error.InvalidFieldPath, result) catch |err| {
            std.debug.print("accepted {s}\n", .{bad});
            return err;
        };
    }
}

test "fieldPathProblem: grammar, reserved names, size" {
    try testing.expectEqual(null, fieldPathProblem("a.b"));
    try testing.expectEqual(null, fieldPathProblem("__name__"));
    try testing.expectEqual(null, fieldPathProblem("`a-b`.`c\\`d`"));
    try testing.expect(fieldPathProblem("") != null);
    try testing.expect(fieldPathProblem("__x__") != null);
    try testing.expect(fieldPathProblem("a.__x__") != null);
    try testing.expect(fieldPathProblem("`__x__`") != null);
    try testing.expect(fieldPathProblem("a.__name__") != null);
    try testing.expect(fieldPathProblem("a-b") != null);
    // Production and the emulator take 1,499 bytes and refuse 1,500.
    try testing.expectEqual(null, fieldPathProblem(test_util.repeat("k", 1499)));
    try testing.expect(fieldPathProblem(test_util.repeat("k", 1500)) != null);
}

test "writeFieldSegment quotes what is not simple" {
    var buf: [64]u8 = undefined;
    for ([_][2][]const u8{
        .{ "a", "a" },
        .{ "_b9", "_b9" },
        .{ "a-b", "`a-b`" },
        .{ "a.b", "`a.b`" },
        .{ "9", "`9`" },
        .{ "c`d", "`c\\`d`" },
        .{ "e\\f", "`e\\\\f`" },
        .{ "été", "`été`" },
        .{ "", "``" },
    }) |pair| {
        var w: Writer = .fixed(&buf);
        try writeFieldSegment(&w, pair[0]);
        try testing.expectEqualStrings(pair[1], w.buffered());
    }
}

test "fieldPathsEqual: one field however quoted" {
    try testing.expect(fieldPathsEqual("a.b", "a.b"));
    try testing.expect(fieldPathsEqual("a.b", "`a`.`b`"));
    try testing.expect(fieldPathsEqual("`c\\`d`", "`c\\`d`"));
    try testing.expect(!fieldPathsEqual("a", "a.b"));
    try testing.expect(!fieldPathsEqual("a.b", "a"));
    try testing.expect(!fieldPathsEqual("a.b", "a.c"));
    try testing.expect(!fieldPathsEqual("`a.b`", "a.b"));
}

test "fieldPathsOverlap: a path and the fields inside it" {
    try testing.expect(fieldPathsOverlap("a", "a"));
    try testing.expect(fieldPathsOverlap("a", "a.b"));
    try testing.expect(fieldPathsOverlap("a.b", "a"));
    try testing.expect(fieldPathsOverlap("`a`.b", "a.b.c"));
    try testing.expect(!fieldPathsOverlap("a.b", "a.c"));
    try testing.expect(!fieldPathsOverlap("a", "b"));
    try testing.expect(!fieldPathsOverlap("ab", "a"));
    try testing.expect(!fieldPathsOverlap("`a.b`", "a.b"));
}

fn segmentRoundTrip(_: void, input: []const u8) !void {
    // Any field name, quoted, parses back to itself as one segment.
    if (input.len == 0) return;
    var buf: [2 * test_util.max_fuzz_input + 2]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try writeFieldSegment(&w, input);
    var it: FieldPathIterator = .init(w.buffered());
    const segment = (try it.next()).?;
    var name_buf: [2 * test_util.max_fuzz_input + 2]u8 = undefined;
    try testing.expectEqualStrings(input, segment.name(&name_buf));
    try testing.expect(segment.eql(input));
    try testing.expectEqual(null, try it.next());
}

test "fuzz field paths: any name quotes and parses back" {
    try test_util.fuzzBytes({}, segmentRoundTrip, .{ .corpus = &.{ "a", "a-b", "`", "\\", "a.b", "\xff", "9" } });
}

fn pathRoundTrip(_: void, input: []const u8) !void {
    // Random names joined into a path split back into the same names.
    var g: test_util.ByteGen = .init(input);
    var names_buf: [8][]const u8 = undefined;
    var n: usize = 0;
    while (n < names_buf.len and g.pos < g.bytes.len) : (n += 1) {
        names_buf[n] = g.take(g.intRange(u8, 1, 6));
        if (names_buf[n].len == 0) break;
    }
    if (n == 0) return;
    var buf: [1024]u8 = undefined;
    var w: Writer = .fixed(&buf);
    for (names_buf[0..n], 0..) |name, i| {
        if (i > 0) try w.writeByte('.');
        try writeFieldSegment(&w, name);
    }
    var it: FieldPathIterator = .init(w.buffered());
    var name_buf: [64]u8 = undefined;
    for (names_buf[0..n]) |name| {
        const segment = (try it.next()) orelse return error.TestExpectedSegment;
        try testing.expectEqualStrings(name, segment.name(&name_buf));
    }
    try testing.expectEqual(null, try it.next());
}

test "fuzz field paths: joined names split back" {
    try test_util.fuzzBytes({}, pathRoundTrip, .{ .corpus = &.{ "\x03abc\x02.`", "\x01\\\x01`" } });
}

fn parseNeverCrashes(_: void, input: []const u8) !void {
    // Arbitrary text either parses into segments that re-render to a path
    // naming the same fields, or is refused; it never crashes.
    var it: FieldPathIterator = .init(input);
    var buf: [2 * test_util.max_fuzz_input + 2]u8 = undefined;
    var w: Writer = .fixed(&buf);
    var name_buf: [test_util.max_fuzz_input]u8 = undefined;
    var first = true;
    while (it.next() catch return) |segment| {
        if (!first) try w.writeByte('.');
        first = false;
        try writeFieldSegment(&w, segment.name(&name_buf));
    }
    var again: FieldPathIterator = .init(w.buffered());
    var original: FieldPathIterator = .init(input);
    while (try original.next()) |segment| {
        const other = (try again.next()).?;
        try testing.expect(other.eql(segment.name(&name_buf)));
    }
    try testing.expectEqual(null, try again.next());
}

test "fuzz field paths: arbitrary text never crashes" {
    try test_util.fuzzBytes({}, parseNeverCrashes, .{ .corpus = &.{ "a.b", "`a\\`b`.c", "`", "a..b", "``" } });
}
