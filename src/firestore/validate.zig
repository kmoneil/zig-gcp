//! Firestore's limits, checked before anything is sent. Each was measured
//! against the emulator on 2026-10-04 where it has one, and the refusals
//! here say what the server would.

const std = @import("std");
const Writer = std.Io.Writer;

const names = @import("names.zig");
const types = @import("types.zig");
const Field = types.Field;
const Value = types.Value;

/// Longest collection or document id, in bytes. The emulator takes 1,500
/// and refuses 1,501: "The key path element name is longer than 1500
/// bytes."
pub const max_id_bytes = 1500;
/// Most segments in a path, collections and documents together.
pub const max_path_segments = 100;
/// Longest full document name, `projects/.../documents/...`, in bytes.
pub const max_name_bytes = 6 * 1024;
/// Longest field name, in bytes: "The property.name is longer than 1500
/// bytes." A nested name counts against the longer path it ends, which
/// the server checks.
pub const max_field_name_bytes = 1500;
/// Longest field path, in bytes. The documentation says 1,500, but
/// production and the emulator both refuse a path of exactly 1,500 bytes,
/// "property path is longer than 1500 bytes." (measured 2026-10-05).
pub const max_field_path_bytes = 1499;
/// Longest string or bytes value: 1 MiB less 89 bytes. "The value of
/// property \"s\" is longer than 1048487 bytes."
pub const max_value_bytes = 1_048_487;
/// Most maps and arrays nested in one field's value. The emulator takes
/// 20 and refuses 21: "Property f contains an invalid nested entity."
pub const max_value_depth = 20;
/// Most field transforms on one document in one commit, as documented.
/// The emulator took 501.
pub const max_transforms_per_document = 500;
/// Largest document, as `documentSize` counts it: production takes
/// 1,048,576 bytes and refuses one more, "Document '...' cannot be written
/// because its size (1,048,577 bytes) exceeds the maximum allowed size of
/// 1,048,576 bytes." (measured 2026-10-05).
pub const max_document_bytes = 1_048_576;
/// Largest request body production takes: 11 MiB, though the
/// documentation says 10. A body of 11,534,336 bytes is taken and one more
/// refused, "Request payload size exceeds the limit: 11534336 bytes."
/// (measured 2026-10-05).
pub const max_request_bytes = 11 * 1024 * 1024;

/// A document's size as Firestore counts it, to the byte: production
/// reports the same number for every kind of value, in its refusal of a
/// document too large (measured 2026-10-05). The path, each collection and
/// document id counted as a string, plus 16; each field, its name as a
/// string and its value; plus 32. A string is its UTF-8 bytes plus one;
/// bytes their length; a boolean or null 1; an integer, a double or a
/// timestamp 8; a geo point 16; a reference its document's path, counted
/// as a document's is; an array its values, a map its entries, each name
/// and value; and an empty array or map 1, where Google's documentation
/// says 0. Fields as checked by `fieldsProblem`, so bounded in depth.
pub fn documentSize(path: []const u8, fields: []const Field) u64 {
    return pathSize(path) +| fieldsSize(fields) +| 32;
}

fn pathSize(path: []const u8) u64 {
    var size: u64 = 16;
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |id| size +|= id.len + 1;
    return size;
}

fn fieldsSize(fields: []const Field) u64 {
    var size: u64 = 0;
    for (fields) |f| size +|= (f.name.len + 1) +| valueSize(f.value);
    return size;
}

fn valueSize(v: Value) u64 {
    return switch (v) {
        .null, .boolean => 1,
        .integer, .double, .timestamp => 8,
        .geo_point => 16,
        .string => |s| s.len + 1,
        .bytes => |b| b.len,
        .reference => |r| pathSize(names.relativePath(r) orelse r),
        .array => |items| if (items.len == 0) 1 else sum: {
            var size: u64 = 0;
            for (items) |item| size +|= valueSize(item);
            break :sum size;
        },
        .map => |entries| if (entries.len == 0) 1 else fieldsSize(entries),
    };
}

/// Why `id` is not a collection or document id, or null when it is: valid
/// UTF-8 of 1 to 1,500 bytes, no `/`, not `.` or `..`, and no reserved
/// `__x__` name ("Resource id \"__x__\" is invalid because it is
/// reserved.").
pub fn idProblem(id: []const u8) ?[]const u8 {
    if (id.len == 0) return "an id is empty: the path has an empty segment";
    if (id.len > max_id_bytes) return "an id is over 1,500 bytes";
    if (std.mem.indexOfScalar(u8, id, '/') != null) return "an id contains '/'";
    if (std.mem.eql(u8, id, ".") or std.mem.eql(u8, id, "..")) return "an id is \".\" or \"..\"";
    if (isReservedName(id)) return "an id is reserved: it starts and ends with __";
    if (!std.unicode.utf8ValidateSlice(id)) return "an id is not valid UTF-8";
    return null;
}

/// Whether `id` is a collection or document id; see `idProblem`.
pub fn isId(id: []const u8) bool {
    return idProblem(id) == null;
}

/// `__x__`: a name that starts and ends with two underscores, reserved
/// for the server, at least five bytes long.
pub fn isReservedName(name: []const u8) bool {
    return name.len >= 5 and std.mem.startsWith(u8, name, "__") and std.mem.endsWith(u8, name, "__");
}

/// `(default)`, or 4 to 63 lowercase letters, digits and `-`, starting with
/// a letter and ending with a letter or digit, and not shaped like a UUID.
pub fn isDatabaseId(id: []const u8) bool {
    if (std.mem.eql(u8, id, "(default)")) return true;
    if (id.len < 4 or id.len > 63) return false;
    for (id) |c| switch (c) {
        'a'...'z', '0'...'9', '-' => {},
        else => return false,
    };
    if (!std.ascii.isLower(id[0])) return false;
    if (id[id.len - 1] == '-') return false;
    return !isUuidLike(id);
}

fn isUuidLike(id: []const u8) bool {
    if (id.len != 36) return false;
    for (id, 0..) |c, i| {
        const dash = i == 8 or i == 13 or i == 18 or i == 23;
        if (dash != (c == '-')) return false;
        if (!dash and !std.ascii.isHex(c)) return false;
    }
    return true;
}

/// A transaction's id as it travels: base64 text, which the server makes.
pub fn isTransactionId(id: []const u8) bool {
    if (id.len == 0 or id.len > 4096) return false;
    for (id) |c| switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '+', '/', '=', '-', '_' => {},
        else => return false,
    };
    return true;
}

/// User agents become a header value: printable ASCII.
pub fn isUserAgent(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text) |c| if (c < ' ' or c >= 0x7f) return false;
    return true;
}

/// What is wrong with a document's fields, and where.
pub const Problem = struct {
    /// The field path where it is, quoted as a request would; shortened
    /// with "..." when long.
    where: []const u8,
    what: []const u8,
};

/// Checks a document's fields as the server would before storing them:
/// names, sizes, nesting, and the values each kind allows. Null when they
/// are fine. `where_buf` holds the returned `Problem.where`.
pub fn fieldsProblem(fields: []const Field, where_buf: []u8) ?Problem {
    var checker: Checker = .{ .where = .fixed(where_buf) };
    if (checker.fields(fields, 0)) |what| return .{ .where = checker.whereText(), .what = what };
    return null;
}

/// Checks the values an array transform adds or removes, as elements of
/// an array: none an array itself (the emulator took one, which no stored
/// array may hold), and each as `fieldsProblem` checks a value.
pub fn arrayElementsProblem(values: []const Value, where_buf: []u8) ?Problem {
    var checker: Checker = .{ .where = .fixed(where_buf) };
    for (values) |v| {
        if (v == .array) return .{ .where = "", .what = "an array transform's value is an array, which no array may hold" };
        if (checker.value(v, 1)) |what| return .{ .where = checker.whereText(), .what = what };
    }
    return null;
}

const Checker = struct {
    where: Writer,
    truncated: bool = false,

    fn whereText(self: *Checker) []const u8 {
        return self.where.buffered();
    }

    /// Appends a segment to the path being checked, or marks it truncated.
    fn push(self: *Checker, name: []const u8, top: bool) usize {
        const mark = self.where.end;
        if (self.truncated) return mark;
        const room = self.where.buffer.len - self.where.end;
        // Room for the segment, a dot and the quoting of a short name.
        if (name.len + 8 > room) {
            self.where.writeAll("...") catch {};
            self.truncated = true;
            return mark;
        }
        if (!top) self.where.writeByte('.') catch unreachable;
        names.writeFieldSegment(&self.where, name) catch {
            self.truncated = true;
        };
        return mark;
    }

    fn pop(self: *Checker, mark: usize) void {
        self.where.end = mark;
        self.truncated = false;
    }

    fn fields(self: *Checker, list: []const Field, depth: usize) ?[]const u8 {
        for (list, 0..) |field, i| {
            const mark = self.push(field.name, depth == 0);
            if (field.name.len == 0) return "a field name is empty";
            if (field.name.len > max_field_name_bytes) return "a field name is over 1,500 bytes";
            if (!std.unicode.utf8ValidateSlice(field.name)) return "a field name is not valid UTF-8";
            if (isReservedName(field.name)) return "a field name is reserved: it starts and ends with __";
            for (list[0..i]) |earlier| {
                if (std.mem.eql(u8, earlier.name, field.name)) return "a field name appears twice in one map";
            }
            if (self.value(field.value, depth)) |what| return what;
            self.pop(mark);
        }
        return null;
    }

    fn value(self: *Checker, v: Value, depth: usize) ?[]const u8 {
        switch (v) {
            .null, .boolean, .integer, .double => {},
            .timestamp => |ts| if (!@import("core").timestamp.inRange(ts))
                return "a timestamp is outside the years 1 to 9999",
            .string => |s| {
                if (s.len > max_value_bytes) return "a string is over 1,048,487 bytes";
                if (!std.unicode.utf8ValidateSlice(s)) return "a string is not valid UTF-8";
            },
            .bytes => |b| if (b.len > max_value_bytes) return "a bytes value is over 1,048,487 bytes",
            .reference => |r| if (names.referenceProblem(r)) |what| return what,
            .geo_point => |g| {
                if (!(g.latitude >= -90 and g.latitude <= 90)) return "a latitude is outside -90 to 90";
                if (!(g.longitude >= -180 and g.longitude <= 180)) return "a longitude is outside -180 to 180";
            },
            .array => |items| {
                if (depth + 1 > max_value_depth) return "maps and arrays nest over 20 deep";
                for (items) |item| {
                    if (item == .array) return "an array holds an array, which Firestore refuses: \"Nested arrays are not allowed\"";
                    if (self.value(item, depth + 1)) |what| return what;
                }
            },
            .map => |map_fields| {
                if (depth + 1 > max_value_depth) return "maps and arrays nest over 20 deep";
                return self.fields(map_fields, depth + 1);
            },
        }
        return null;
    }
};

const testing = std.testing;
const test_util = @import("test_util.zig");

test "ids: what the emulator took and refused" {
    try testing.expect(isId("LA"));
    try testing.expect(isId("a b%c+d"));
    try testing.expect(isId("a:b"));
    try testing.expect(isId("été"));
    try testing.expect(isId("_x_"));
    try testing.expect(isId("__x"));
    try testing.expect(isId("__"));
    try testing.expect(isId("___"));
    try testing.expect(isId("____"));
    try testing.expect(isId(test_util.repeat("i", 1500)));
    try testing.expect(!isId(test_util.repeat("i", 1501)));
    try testing.expect(!isId(""));
    try testing.expect(!isId("a/b"));
    try testing.expect(!isId("."));
    try testing.expect(!isId(".."));
    try testing.expect(!isId("__x__"));
    try testing.expect(!isId("_____"));
    try testing.expect(!isId("\xff"));
}

test "database ids" {
    try testing.expect(isDatabaseId("(default)"));
    try testing.expect(isDatabaseId("zigps-fs-1a2b"));
    try testing.expect(isDatabaseId("abcd"));
    try testing.expect(isDatabaseId("a" ++ test_util.repeat("b", 62)));
    try testing.expect(!isDatabaseId("abc"));
    try testing.expect(!isDatabaseId("a" ++ test_util.repeat("b", 63)));
    try testing.expect(!isDatabaseId("1abc"));
    try testing.expect(!isDatabaseId("abc-"));
    try testing.expect(!isDatabaseId("Abcd"));
    try testing.expect(!isDatabaseId("ab_cd"));
    try testing.expect(!isDatabaseId("default"[0..3]));
    try testing.expect(!isDatabaseId("(Default)"));
    try testing.expect(!isDatabaseId("a2345678-1234-1234-1234-123456789abc"));
    try testing.expect(isDatabaseId("a2345678-1234-1234-1234-123456789abz"));
}

fn expectProblem(fields: []const Field, where: []const u8, what_part: []const u8) !void {
    var buf: [128]u8 = undefined;
    const problem = fieldsProblem(fields, &buf) orelse return error.TestExpectedProblem;
    try testing.expectEqualStrings(where, problem.where);
    if (std.mem.indexOf(u8, problem.what, what_part) == null) {
        std.debug.print("problem: {s}\n", .{problem.what});
        return error.TestUnexpectedProblem;
    }
}

fn nestedMaps(comptime n: usize) Value {
    comptime var v: Value = .{ .integer = 1 };
    inline for (0..n) |_| {
        const inner = v;
        v = .{ .map = &.{.{ .name = "k", .value = inner }} };
    }
    return v;
}

test "fieldsProblem: the server's refusals, with where they are" {
    var buf: [128]u8 = undefined;
    try testing.expectEqual(null, fieldsProblem(&.{
        .{ .name = "a", .value = .null },
        .{ .name = "a.b", .value = .{ .string = "fine: dots are allowed in names" } },
        .{ .name = "g", .value = .{ .geo_point = .{ .latitude = -90, .longitude = 180 } } },
        .{ .name = "r", .value = .{ .reference = "projects/p/databases/(default)/documents/c/x" } },
        .{ .name = "arr", .value = .{ .array = &.{ .{ .map = &.{.{ .name = "in", .value = .{ .array = &.{} } }} }, .{ .integer = 2 } } } },
        .{ .name = "deep", .value = nestedMaps(20) },
    }, &buf));

    try expectProblem(&.{.{ .name = "", .value = .null }}, "``", "empty");
    try expectProblem(&.{.{ .name = "__x__", .value = .null }}, "__x__", "reserved");
    try expectProblem(&.{.{ .name = "m", .value = .{ .map = &.{.{ .name = "__y__", .value = .null }} } }}, "m.__y__", "reserved");
    try expectProblem(&.{ .{ .name = "a", .value = .null }, .{ .name = "a", .value = .null } }, "a", "twice");
    try expectProblem(&.{.{ .name = "a", .value = .{ .array = &.{.{ .array = &.{} }} } }}, "a", "Nested arrays");
    try expectProblem(&.{.{ .name = "deep", .value = nestedMaps(21) }}, "deep" ++ test_util.repeat(".k", 20), "20 deep");
    try expectProblem(&.{.{ .name = "g", .value = .{ .geo_point = .{ .latitude = 91, .longitude = 0 } } }}, "g", "latitude");
    try expectProblem(&.{.{ .name = "g", .value = .{ .geo_point = .{ .latitude = std.math.nan(f64), .longitude = 0 } } }}, "g", "latitude");
    try expectProblem(&.{.{ .name = "g", .value = .{ .geo_point = .{ .latitude = 0, .longitude = -180.5 } } }}, "g", "longitude");
    try expectProblem(&.{.{ .name = "t", .value = .{ .timestamp = .{ .nanoseconds = -62_135_596_801 * std.time.ns_per_s } } }}, "t", "years 1 to 9999");
    try expectProblem(&.{.{ .name = "s", .value = .{ .string = "\xc3" } }}, "s", "UTF-8");
    try expectProblem(&.{.{ .name = "r", .value = .{ .reference = "projects/p/databases/(default)/documents/c" } }}, "r", "even number");
    try expectProblem(&.{.{ .name = "a-b", .value = .{ .map = &.{.{ .name = "\xff", .value = .null }} } }}, "`a-b`.`\xff`", "UTF-8");
    try expectProblem(&.{.{ .name = test_util.repeat("k", 1501), .value = .null }}, "...", "1,500 bytes");

    const big = try testing.allocator.alloc(u8, max_value_bytes + 1);
    defer testing.allocator.free(big);
    @memset(big, 'x');
    try expectProblem(&.{.{ .name = "s", .value = .{ .string = big } }}, "s", "1,048,487");
    try expectProblem(&.{.{ .name = "b", .value = .{ .bytes = big } }}, "b", "1,048,487");
    try testing.expectEqual(null, fieldsProblem(&.{.{ .name = "s", .value = .{ .string = big[0..max_value_bytes] } }}, &buf));
}

test "arrayElementsProblem: what an array may hold" {
    var buf: [64]u8 = undefined;
    try testing.expectEqual(null, arrayElementsProblem(&.{ .null, .{ .integer = 3 }, .{ .map = &.{.{ .name = "a", .value = .{ .array = &.{} } }} } }, &buf));
    try testing.expect(std.mem.indexOf(u8, arrayElementsProblem(&.{.{ .array = &.{} }}, &buf).?.what, "array") != null);
    try testing.expect(arrayElementsProblem(&.{.{ .string = "\xff" }}, &buf) != null);
    try testing.expect(arrayElementsProblem(&.{.{ .map = &.{.{ .name = "__x__", .value = .null }} }}, &buf) != null);
}

test "fieldsProblem: a long path is shortened, never overflows" {
    var tiny: [16]u8 = undefined;
    const problem = fieldsProblem(&.{.{ .name = "abcdefghij", .value = .{ .map = &.{.{ .name = "klmnopqrst", .value = .{ .string = "\xff" } }} } }}, &tiny).?;
    try testing.expect(std.mem.endsWith(u8, problem.where, "..."));
    // A name whose raw length fits the room but whose backtick quoting
    // does not: the path stops where the room ends, and the problem is
    // still found.
    const quoted = fieldsProblem(&.{.{ .name = "\\\\\\\\\\\\\\\\", .value = .{ .string = "\xff" } }}, &tiny).?;
    try testing.expect(quoted.where.len <= tiny.len);
    try testing.expect(std.mem.indexOf(u8, quoted.what, "UTF-8") != null);
}

test "golden: documentSize is production's count, to the byte, for every kind of value" {
    // Each case as production reported it, refusing the document as too
    // large (_tmp/fs-hardening/probe_m3.py, 2026-10-05): two strings of
    // 600,000 bytes, `a` and `b`, and a field `v` of each kind, at two paths.
    const pad_a = try testing.allocator.alloc(u8, 600_000);
    defer testing.allocator.free(pad_a);
    @memset(pad_a, 'y');
    const pad_b = try testing.allocator.alloc(u8, 600_000);
    defer testing.allocator.free(pad_b);
    @memset(pad_b, 'z');
    const cases = [_]struct { Value, u64 }{
        .{ .null, 1_200_061 },
        .{ .{ .boolean = true }, 1_200_061 },
        .{ .{ .integer = 42 }, 1_200_068 },
        .{ .{ .double = 1.5 }, 1_200_068 },
        .{ .{ .timestamp = .{ .nanoseconds = 1_791_201_600_123_456_000 } }, 1_200_068 },
        .{ .{ .geo_point = .{ .latitude = 1, .longitude = 2 } }, 1_200_076 },
        .{ .{ .string = "abc" }, 1_200_064 },
        .{ .{ .string = "été🔥" }, 1_200_070 },
        .{ .{ .bytes = "\x01\x02\x03" }, 1_200_063 },
        .{ .{ .reference = "projects/extractctl/databases/zigps-fs-9620b6bd/documents/cities/LA/landmarks/tower" }, 1_200_102 },
        .{ .{ .array = &.{ .{ .integer = 1 }, .{ .string = "ab" }, .null } }, 1_200_072 },
        // An empty array or map is 1 byte, not the 0 the documentation gives.
        .{ .{ .array = &.{} }, 1_200_061 },
        .{ .{ .map = &.{ .{ .name = "k", .value = .{ .integer = 1 } }, .{ .name = "kk", .value = .{ .string = "ab" } } } }, 1_200_076 },
        .{ .{ .map = &.{} }, 1_200_061 },
        .{ .{ .map = &.{.{ .name = "m", .value = .{ .map = &.{.{ .name = "a", .value = .{ .array = &.{.{ .boolean = false }} } }} } }} }, 1_200_065 },
    };
    for (cases) |case| {
        const fields: []const Field = &.{ .{ .name = "a", .value = .{ .string = pad_a } }, .{ .name = "b", .value = .{ .string = pad_b } }, .{ .name = "v", .value = case[0] } };
        try testing.expectEqual(case[1], documentSize("s/x", fields));
        // Each id a string: the deeper, unicode path counts 15 bytes more.
        try testing.expectEqual(case[1] + 15, documentSize("deep/é/sub/🔥id", fields));
    }
    const named: []const Field = &.{ .{ .name = "a", .value = .{ .string = pad_a } }, .{ .name = "b", .value = .{ .string = pad_b } }, .{ .name = "ñame🔥", .value = .{ .integer = 1 } } };
    try testing.expectEqual(1_200_076, documentSize("s/x", named));
    // The boundary production holds to: 1,048,576 taken, one more refused.
    const at_limit: []const Field = &.{ .{ .name = "a", .value = .{ .string = pad_a } }, .{ .name = "b", .value = .{ .string = pad_b[0..448_518] } } };
    try testing.expectEqual(max_document_bytes, documentSize("s/x", at_limit));
}
