//! JSON: request bodies out, response bodies in.
//!
//! A Firestore value is an object with exactly one key naming its kind,
//! such as `{"integerValue": "42"}`. Decoding is strict about that object,
//! since a kind this library does not know cannot be handed on, and
//! lenient about everything around it: unknown response fields are
//! ignored, and `null` counts as absent (the proto3 rule), except as the
//! value of `nullValue`, where it is the value. Numbers are parsed here,
//! not by std.json, so integers stay exact and doubles take the strings
//! `NaN`, `Infinity` and `-Infinity`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Stringify = std.json.Stringify;
const Writer = std.Io.Writer;
const core = @import("core");

const types = @import("types.zig");
const Field = types.Field;
const Value = types.Value;

pub const DecodeError = error{ InvalidResponse, OutOfMemory };

/// What decoding a streamed answer fails with: `error.Streamed` is an error
/// the server sent inside the answer, filled into the caller's
/// `StreamedError`.
pub const StreamDecodeError = DecodeError || error{Streamed};

/// An error the server sent as an element of a streamed answer, after the
/// messages before it, in a 200 response. Measured on production
/// (2026-10-05): a query past its deadline answers the documents it found
/// and then `{"error": {"code": 504, "message": ..., "status":
/// "DEADLINE_EXCEEDED", "details": [...]}}`. The strings live where the
/// answer was decoded.
pub const StreamedError = struct {
    /// The HTTP status it carries; 0 when it carries none.
    code: u16 = 0,
    status: []const u8 = "",
    message: []const u8 = "",
};

/// Deepest nesting of maps and arrays a response may hold. The server
/// stores at most 20; this leaves room without letting a broken response
/// recurse without end.
pub const max_decode_depth = 64;

// Requests

/// `{"fields": {...}}`: a document body, as create takes it.
pub fn encodeDocument(arena: Allocator, fields: []const Field) Allocator.Error![]u8 {
    var out: Writer.Allocating = .init(arena);
    var jw: Stringify = .{ .writer = &out.writer };
    writeDocument(&jw, fields) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn writeDocument(jw: *Stringify, fields: []const Field) Stringify.Error!void {
    try jw.beginObject();
    try jw.objectField("fields");
    try writeFields(jw, fields);
    try jw.endObject();
}

/// One write in a commit, as this module builds it.
pub const Write = struct {
    /// The document's full name.
    name: []const u8,
    op: Op,
    precondition: ?types.Precondition = null,

    pub const Op = union(enum) {
        /// The fields, and the mask of those to change; without a mask the
        /// fields replace the document's. The transforms follow.
        update: struct {
            fields: []const Field,
            mask: ?[]const []const u8 = null,
            transforms: []const types.Transform = &.{},
        },
        delete,
    };

    /// How many transforms this write carries.
    pub fn transformCount(self: Write) usize {
        return switch (self.op) {
            .update => |u| u.transforms.len,
            .delete => 0,
        };
    }
};

/// `{"writes": [...]}`: the `commit` body. Preconditions travel here, in
/// the body, rather than as query parameters: measured on the emulator
/// (2026-10-04), `currentDocument.updateTime` in RFC 3339 as a query
/// parameter reads as 0, which demands that the document not exist, and
/// in the body it is honored. Google's clients send every write this way.
pub fn encodeCommit(arena: Allocator, writes: []const Write, transaction: ?[]const u8) Allocator.Error![]u8 {
    var out: Writer.Allocating = .init(arena);
    var jw: Stringify = .{ .writer = &out.writer };
    writeCommit(&jw, writes, transaction) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn writeCommit(jw: *Stringify, writes: []const Write, transaction: ?[]const u8) Stringify.Error!void {
    try jw.beginObject();
    try jw.objectField("writes");
    try jw.beginArray();
    for (writes) |w| try writeWrite(jw, w);
    try jw.endArray();
    if (transaction) |t| {
        try jw.objectField("transaction");
        try jw.write(t);
    }
    try jw.endObject();
}

/// The `beginTransaction` body: read-write, again after `retry` when set,
/// or read-only, as of a time when set.
pub fn encodeBeginTransaction(arena: Allocator, options: types.TransactionOptions, retry: ?[]const u8) Allocator.Error![]u8 {
    var out: Writer.Allocating = .init(arena);
    var jw: Stringify = .{ .writer = &out.writer };
    writeBeginTransaction(&jw, options, retry) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn writeBeginTransaction(jw: *Stringify, options: types.TransactionOptions, retry: ?[]const u8) Stringify.Error!void {
    try jw.beginObject();
    try jw.objectField("options");
    try jw.beginObject();
    switch (options) {
        .read_write => {
            try jw.objectField("readWrite");
            try jw.beginObject();
            if (retry) |r| {
                try jw.objectField("retryTransaction");
                try jw.write(r);
            }
            try jw.endObject();
        },
        .read_only => |ro| {
            try jw.objectField("readOnly");
            try jw.beginObject();
            if (ro.read_time) |t| {
                try jw.objectField("readTime");
                try writeTimestamp(jw, t);
            }
            try jw.endObject();
        },
    }
    try jw.endObject();
    try jw.endObject();
}

/// `{"transaction": id}`: the `rollback` body.
pub fn encodeRollback(arena: Allocator, transaction: []const u8) Allocator.Error![]u8 {
    return Stringify.valueAlloc(arena, .{ .transaction = transaction }, .{});
}

/// The id `beginTransaction` answers, as the base64 text it travels as.
pub fn decodeBeginTransaction(arena: Allocator, body: []const u8) DecodeError![]const u8 {
    const obj = objectOf(try parseTree(arena, body)) orelse return error.InvalidResponse;
    const t = present(obj, "transaction") orelse return error.InvalidResponse;
    if (t != .string or t.string.len == 0) return error.InvalidResponse;
    return t.string;
}

fn writeWrite(jw: *Stringify, w: Write) Stringify.Error!void {
    try jw.beginObject();
    switch (w.op) {
        .update => |u| {
            try jw.objectField("update");
            try jw.beginObject();
            try jw.objectField("name");
            try jw.write(w.name);
            try jw.objectField("fields");
            try writeFields(jw, u.fields);
            try jw.endObject();
            // An empty mask is sent too: without one, a write of transforms
            // alone would first replace the document with no fields.
            if (u.mask) |mask| {
                try jw.objectField("updateMask");
                try jw.beginObject();
                try jw.objectField("fieldPaths");
                try jw.beginArray();
                for (mask) |p| try jw.write(p);
                try jw.endArray();
                try jw.endObject();
            }
            if (u.transforms.len > 0) {
                try jw.objectField("updateTransforms");
                try jw.beginArray();
                for (u.transforms) |t| try writeTransform(jw, t);
                try jw.endArray();
            }
        },
        .delete => {
            try jw.objectField("delete");
            try jw.write(w.name);
        },
    }
    if (w.precondition) |p| {
        try jw.objectField("currentDocument");
        try jw.beginObject();
        switch (p) {
            .exists => |e| {
                try jw.objectField("exists");
                try jw.write(e);
            },
            .update_time => |t| {
                try jw.objectField("updateTime");
                try writeTimestamp(jw, t);
            },
        }
        try jw.endObject();
    }
    try jw.endObject();
}

fn writeTransform(jw: *Stringify, t: types.Transform) Stringify.Error!void {
    try jw.beginObject();
    try jw.objectField("fieldPath");
    try jw.write(t.field_path);
    switch (t.op) {
        .server_time => {
            try jw.objectField("setToServerValue");
            try jw.write("REQUEST_TIME");
        },
        .increment => |n| try writeNumeric(jw, "increment", n),
        .maximum => |n| try writeNumeric(jw, "maximum", n),
        .minimum => |n| try writeNumeric(jw, "minimum", n),
        .append_missing => |values| try writeValues(jw, "appendMissingElements", values),
        .remove_all => |values| try writeValues(jw, "removeAllFromArray", values),
    }
    try jw.endObject();
}

fn writeNumeric(jw: *Stringify, field: []const u8, n: types.Numeric) Stringify.Error!void {
    try jw.objectField(field);
    try writeValue(jw, switch (n) {
        .integer => |i| .{ .integer = i },
        .double => |d| .{ .double = d },
    });
}

fn writeValues(jw: *Stringify, field: []const u8, values: []const Value) Stringify.Error!void {
    try jw.objectField(field);
    try jw.beginObject();
    try jw.objectField("values");
    try jw.beginArray();
    for (values) |v| try writeValue(jw, v);
    try jw.endArray();
    try jw.endObject();
}

/// `{"documents": [...], "mask": ..., "readTime": ...}`: the `batchGet`
/// body, with full names.
pub fn encodeBatchGet(arena: Allocator, document_names: []const []const u8, options: types.BatchGetOptions) Allocator.Error![]u8 {
    var out: Writer.Allocating = .init(arena);
    var jw: Stringify = .{ .writer = &out.writer };
    writeBatchGet(&jw, document_names, options) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn writeBatchGet(jw: *Stringify, document_names: []const []const u8, options: types.BatchGetOptions) Stringify.Error!void {
    const mask = options.mask;
    const read_time = options.read_time;
    try jw.beginObject();
    try jw.objectField("documents");
    try jw.write(document_names);
    if (mask) |m| {
        try jw.objectField("mask");
        try jw.beginObject();
        try jw.objectField("fieldPaths");
        try jw.write(m);
        try jw.endObject();
    }
    if (read_time) |t| {
        try jw.objectField("readTime");
        try writeTimestamp(jw, t);
    }
    if (options.transaction) |t| {
        try jw.objectField("transaction");
        try jw.write(t);
    }
    try jw.endObject();
}

/// `{"name": Value, ...}`. The fields have been checked, so nesting is
/// bounded and every name is valid UTF-8.
pub fn writeFields(jw: *Stringify, fields: []const Field) Stringify.Error!void {
    try jw.beginObject();
    for (fields) |f| {
        try jw.objectField(f.name);
        try writeValue(jw, f.value);
    }
    try jw.endObject();
}

pub fn writeValue(jw: *Stringify, value: Value) Stringify.Error!void {
    try jw.beginObject();
    switch (value) {
        .null => {
            try jw.objectField("nullValue");
            try jw.write("NULL_VALUE");
        },
        .boolean => |b| {
            try jw.objectField("booleanValue");
            try jw.write(b);
        },
        .integer => |i| {
            try jw.objectField("integerValue");
            var buf: [20]u8 = undefined;
            try jw.write(std.fmt.bufPrint(&buf, "{d}", .{i}) catch unreachable);
        },
        .double => |d| {
            try jw.objectField("doubleValue");
            try writeDouble(jw, d);
        },
        .timestamp => |ts| {
            try jw.objectField("timestampValue");
            try writeTimestamp(jw, ts);
        },
        .string => |s| {
            try jw.objectField("stringValue");
            try jw.write(s);
        },
        .bytes => |b| {
            try jw.objectField("bytesValue");
            try core.base64.writeJsonString(jw, b);
        },
        .reference => |r| {
            try jw.objectField("referenceValue");
            try jw.write(r);
        },
        .geo_point => |g| {
            try jw.objectField("geoPointValue");
            try jw.beginObject();
            try jw.objectField("latitude");
            try writeDouble(jw, g.latitude);
            try jw.objectField("longitude");
            try writeDouble(jw, g.longitude);
            try jw.endObject();
        },
        .array => |items| {
            try jw.objectField("arrayValue");
            try jw.beginObject();
            try jw.objectField("values");
            try jw.beginArray();
            for (items) |item| try writeValue(jw, item);
            try jw.endArray();
            try jw.endObject();
        },
        .map => |fields| {
            try jw.objectField("mapValue");
            try jw.beginObject();
            try jw.objectField("fields");
            try writeFields(jw, fields);
            try jw.endObject();
        },
    }
    try jw.endObject();
}

/// A double as JSON allows: a number, exact, in plain decimal where that
/// stays short and in exponent form elsewhere, or one of the three
/// strings proto3 JSON uses for what JSON has no number for.
pub fn writeDouble(jw: *Stringify, d: f64) Stringify.Error!void {
    if (std.math.isNan(d)) return jw.write("NaN");
    if (std.math.isInf(d)) return jw.write(if (d > 0) "Infinity" else "-Infinity");
    const magnitude = @abs(d);
    if (magnitude == 0 or (magnitude >= 1e-6 and magnitude < 1e21)) {
        try jw.print("{d}", .{d});
    } else {
        try jw.print("{e}", .{d});
    }
}

/// RFC 3339 in UTC. The timestamp has been checked to be in range.
pub fn writeTimestamp(jw: *Stringify, ts: std.Io.Timestamp) Stringify.Error!void {
    var buf: [core.timestamp.max_len]u8 = undefined;
    try jw.write(core.timestamp.format(&buf, ts));
}

// Responses

/// A document, as get, create and patch return it.
pub fn decodeSnapshot(arena: Allocator, body: []const u8) DecodeError!types.Snapshot {
    return snapshotFrom(arena, try parseTree(arena, body));
}

/// What a commit returns: each write's update time, absent for a delete,
/// and transform results, and the commit's own time, which the emulator
/// leaves out of the answer to a commit of no writes.
pub const CommitResult = struct {
    writes: []const types.CommittedWrite,
    commit_time: ?std.Io.Timestamp,
};

pub fn decodeCommit(arena: Allocator, body: []const u8) DecodeError!CommitResult {
    const obj = objectOf(try parseTree(arena, body)) orelse return error.InvalidResponse;
    var writes: []types.CommittedWrite = &.{};
    if (present(obj, "writeResults")) |results| {
        if (results != .array) return error.InvalidResponse;
        writes = try arena.alloc(types.CommittedWrite, results.array.items.len);
        for (results.array.items, writes) |r, *w| {
            const result = objectOf(r) orelse return error.InvalidResponse;
            // Measured: a delete's result is `{}`.
            w.* = .{ .update_time = if (present(result, "updateTime")) |_| try requiredTime(result, "updateTime") else null };
            if (present(result, "transformResults")) |values| {
                if (values != .array) return error.InvalidResponse;
                const out = try arena.alloc(Value, values.array.items.len);
                for (values.array.items, out) |v, *o| o.* = try valueFrom(arena, v, 0);
                w.transform_results = out;
            }
        }
    }
    const commit_time: ?std.Io.Timestamp = if (present(obj, "commitTime")) |_| try requiredTime(obj, "commitTime") else null;
    if (commit_time == null and writes.len > 0) return error.InvalidResponse;
    return .{ .writes = writes, .commit_time = commit_time };
}

/// One message of a `batchGet` answer: a document found, a name missing,
/// or neither, and the time it was read.
pub const BatchGetElement = struct {
    found: ?types.Snapshot = null,
    missing: ?[]const u8 = null,
    read_time: ?std.Io.Timestamp = null,
};

/// The `batchGet` answer: one JSON array of stream messages, measured on
/// the emulator, in no particular order and with a name asked twice
/// answered once; production sorts them by name, the missing last. An
/// error inside it is `error.Streamed`, told in `streamed`.
pub fn decodeBatchGet(arena: Allocator, body: []const u8, streamed: *?StreamedError) StreamDecodeError![]const BatchGetElement {
    const tree = try parseTree(arena, body);
    if (tree != .array) return error.InvalidResponse;
    const out = try arena.alloc(BatchGetElement, tree.array.items.len);
    for (tree.array.items, out) |item, *e| {
        const obj = objectOf(item) orelse return error.InvalidResponse;
        try checkStreamed(obj, streamed);
        e.* = .{};
        if (present(obj, "found")) |f| e.found = try snapshotFrom(arena, f);
        if (present(obj, "missing")) |m| {
            if (m != .string or m.string.len == 0) return error.InvalidResponse;
            e.missing = m.string;
        }
        if (e.found != null and e.missing != null) return error.InvalidResponse;
        if (present(obj, "readTime")) |_| e.read_time = try requiredTime(obj, "readTime");
    }
    return out;
}

/// The `runQuery` answer: one JSON array of stream messages, measured on
/// the emulator: a document with its read time each, a lone read time for
/// an empty result, `done` riding on the last, and, from production,
/// `skippedResults` counting what an offset passed over. An error inside
/// it, after documents or not, is `error.Streamed`, told in `streamed`:
/// the documents before it are not the whole result.
pub fn decodeRunQuery(arena: Allocator, body: []const u8, streamed: *?StreamedError) StreamDecodeError!types.QueryResult {
    const tree = try parseTree(arena, body);
    if (tree != .array) return error.InvalidResponse;
    var documents: std.ArrayList(types.Snapshot) = .empty;
    var read_time: ?std.Io.Timestamp = null;
    var skipped: u64 = 0;
    for (tree.array.items) |item| {
        const obj = objectOf(item) orelse return error.InvalidResponse;
        try checkStreamed(obj, streamed);
        if (present(obj, "document")) |d| try documents.append(arena, try snapshotFrom(arena, d));
        if (present(obj, "readTime")) |_| read_time = try requiredTime(obj, "readTime");
        if (present(obj, "skippedResults")) |n| {
            const text = numberText(n) orelse return error.InvalidResponse;
            skipped +|= std.fmt.parseInt(u64, text, 10) catch return error.InvalidResponse;
        }
    }
    return .{
        .documents = documents.items,
        .read_time = read_time orelse return error.InvalidResponse,
        .skipped_results = skipped,
    };
}

/// The `runAggregationQuery` answer: one JSON array whose result message
/// holds each aggregation under the alias it was sent with, `a0` to
/// `a{count - 1}`. An error inside it is `error.Streamed`, told in
/// `streamed`.
pub fn decodeAggregation(arena: Allocator, body: []const u8, count: usize, streamed: *?StreamedError) StreamDecodeError!types.AggregationResult {
    const tree = try parseTree(arena, body);
    if (tree != .array) return error.InvalidResponse;
    var values: ?[]Value = null;
    var read_time: ?std.Io.Timestamp = null;
    for (tree.array.items) |item| {
        const obj = objectOf(item) orelse return error.InvalidResponse;
        try checkStreamed(obj, streamed);
        if (present(obj, "readTime")) |_| read_time = try requiredTime(obj, "readTime");
        const result = objectOf(present(obj, "result") orelse continue) orelse return error.InvalidResponse;
        if (values != null) return error.InvalidResponse;
        const fields = objectOf(present(result, "aggregateFields") orelse return error.InvalidResponse) orelse return error.InvalidResponse;
        const out = try arena.alloc(Value, count);
        for (out, 0..) |*v, i| {
            var buf: [8]u8 = undefined;
            v.* = try valueFrom(arena, fields.get(@import("query.zig").alias(&buf, i)) orelse return error.InvalidResponse, 0);
        }
        values = out;
    }
    return .{
        .values = values orelse return error.InvalidResponse,
        .read_time = read_time orelse return error.InvalidResponse,
    };
}

/// One page of `listDocuments`.
pub fn decodeSnapshotPage(arena: Allocator, body: []const u8) DecodeError!types.SnapshotPage {
    const obj = objectOf(try parseTree(arena, body)) orelse return error.InvalidResponse;
    var page: types.SnapshotPage = .{ .next_page_token = try pageToken(obj) };
    if (present(obj, "documents")) |docs| {
        if (docs != .array) return error.InvalidResponse;
        const out = try arena.alloc(types.Snapshot, docs.array.items.len);
        for (docs.array.items, out) |d, *s| s.* = try snapshotFrom(arena, d);
        page.documents = out;
    }
    return page;
}

/// One page of `listCollectionIds`.
pub fn decodeCollectionIdPage(arena: Allocator, body: []const u8) DecodeError!types.CollectionIdPage {
    const obj = objectOf(try parseTree(arena, body)) orelse return error.InvalidResponse;
    var page: types.CollectionIdPage = .{ .next_page_token = try pageToken(obj) };
    if (present(obj, "collectionIds")) |ids| {
        if (ids != .array) return error.InvalidResponse;
        const out = try arena.alloc([]const u8, ids.array.items.len);
        for (ids.array.items, out) |id, *o| o.* = switch (id) {
            .string => |s| s,
            else => return error.InvalidResponse,
        };
        page.collection_ids = out;
    }
    return page;
}

/// Parses `body` into a tree whose numbers are left as text. A blank body
/// counts as `{}`.
fn parseTree(arena: Allocator, body: []const u8) DecodeError!std.json.Value {
    const trimmed = std.mem.trim(u8, body, " \t\r\n");
    const text = if (trimmed.len == 0) "{}" else trimmed;
    return std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{ .parse_numbers = false }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidResponse,
    };
}

fn objectOf(v: std.json.Value) ?std.json.ObjectMap {
    return switch (v) {
        .object => |o| o,
        else => null,
    };
}

/// `error.Streamed` when the stream message `obj` is an error, with what
/// it says in `out`. Read leniently: whatever its shape, an error ends the
/// answer.
fn checkStreamed(obj: std.json.ObjectMap, out: *?StreamedError) error{Streamed}!void {
    const e = present(obj, "error") orelse return;
    var streamed: StreamedError = .{};
    if (objectOf(e)) |fields| {
        if (present(fields, "code")) |code| {
            if (numberText(code)) |text| streamed.code = std.fmt.parseInt(u16, text, 10) catch 0;
        }
        if (present(fields, "status")) |status| if (status == .string) {
            streamed.status = status.string;
        };
        if (present(fields, "message")) |message| if (message == .string) {
            streamed.message = message.string;
        };
    }
    out.* = streamed;
    return error.Streamed;
}

/// The member `key` of `obj`, unless it is missing or `null`.
fn present(obj: std.json.ObjectMap, key: []const u8) ?std.json.Value {
    const v = obj.get(key) orelse return null;
    return if (v == .null) null else v;
}

fn pageToken(obj: std.json.ObjectMap) DecodeError!?[]const u8 {
    const v = present(obj, "nextPageToken") orelse return null;
    if (v != .string) return error.InvalidResponse;
    return if (v.string.len == 0) null else v.string;
}

fn requiredTime(obj: std.json.ObjectMap, key: []const u8) DecodeError!std.Io.Timestamp {
    const v = present(obj, key) orelse return error.InvalidResponse;
    if (v != .string) return error.InvalidResponse;
    return timeFrom(v.string);
}

/// A time this library can send back, as a precondition or a value: one
/// outside the years 1 to 9999 is no `google.protobuf.Timestamp`.
fn timeFrom(text: []const u8) DecodeError!std.Io.Timestamp {
    const ts = core.timestamp.parse(text) catch return error.InvalidResponse;
    if (!core.timestamp.inRange(ts)) return error.InvalidResponse;
    return ts;
}

fn snapshotFrom(arena: Allocator, v: std.json.Value) DecodeError!types.Snapshot {
    const obj = objectOf(v) orelse return error.InvalidResponse;
    const name = present(obj, "name") orelse return error.InvalidResponse;
    if (name != .string or name.string.len == 0) return error.InvalidResponse;
    return .{
        .name = name.string,
        // Measured: a read mask that matches nothing leaves out `fields`.
        .fields = if (present(obj, "fields")) |f| try fieldsFrom(arena, f, 0) else &.{},
        .create_time = try requiredTime(obj, "createTime"),
        .update_time = try requiredTime(obj, "updateTime"),
    };
}

fn fieldsFrom(arena: Allocator, v: std.json.Value, depth: usize) DecodeError![]const Field {
    const obj = objectOf(v) orelse return error.InvalidResponse;
    const out = try arena.alloc(Field, obj.count());
    var it = obj.iterator();
    var i: usize = 0;
    while (it.next()) |entry| : (i += 1) {
        out[i] = .{ .name = entry.key_ptr.*, .value = try valueFrom(arena, entry.value_ptr.*, depth) };
    }
    return out;
}

/// One value: an object with exactly one known kind.
fn valueFrom(arena: Allocator, v: std.json.Value, depth: usize) DecodeError!Value {
    if (depth > max_decode_depth) return error.InvalidResponse;
    const obj = objectOf(v) orelse return error.InvalidResponse;
    if (obj.count() != 1) return error.InvalidResponse;
    const kind = obj.keys()[0];
    const inner = obj.values()[0];
    const k = kinds.get(kind) orelse return error.InvalidResponse;
    switch (k) {
        .null => return switch (inner) {
            .null => .null,
            .string => |s| if (std.mem.eql(u8, s, "NULL_VALUE")) .null else error.InvalidResponse,
            else => error.InvalidResponse,
        },
        .boolean => return switch (inner) {
            .bool => |b| .{ .boolean = b },
            else => error.InvalidResponse,
        },
        .integer => {
            const text = numberText(inner) orelse return error.InvalidResponse;
            return .{ .integer = std.fmt.parseInt(i64, text, 10) catch return error.InvalidResponse };
        },
        .double => return .{ .double = try doubleFrom(inner) },
        .timestamp => {
            if (inner != .string) return error.InvalidResponse;
            return .{ .timestamp = try timeFrom(inner.string) };
        },
        .string => {
            if (inner != .string) return error.InvalidResponse;
            return .{ .string = inner.string };
        },
        .bytes => {
            if (inner != .string) return error.InvalidResponse;
            return .{ .bytes = core.base64.decode(arena, inner.string) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidBase64 => return error.InvalidResponse,
            } };
        },
        .reference => {
            if (inner != .string) return error.InvalidResponse;
            return .{ .reference = inner.string };
        },
        .geo_point => {
            const g = objectOf(inner) orelse return error.InvalidResponse;
            // proto3 JSON leaves out a coordinate that is 0.
            return .{ .geo_point = .{
                .latitude = if (present(g, "latitude")) |lat| try doubleFrom(lat) else 0,
                .longitude = if (present(g, "longitude")) |lon| try doubleFrom(lon) else 0,
            } };
        },
        .array => {
            const a = objectOf(inner) orelse return error.InvalidResponse;
            const values = present(a, "values") orelse return .{ .array = &.{} };
            if (values != .array) return error.InvalidResponse;
            const out = try arena.alloc(Value, values.array.items.len);
            for (values.array.items, out) |item, *o| o.* = try valueFrom(arena, item, depth + 1);
            return .{ .array = out };
        },
        .map => {
            const m = objectOf(inner) orelse return error.InvalidResponse;
            const fields = present(m, "fields") orelse return .{ .map = &.{} };
            return .{ .map = try fieldsFrom(arena, fields, depth + 1) };
        },
    }
}

const kinds = std.StaticStringMap(std.meta.Tag(Value)).initComptime(.{
    .{ "nullValue", .null },
    .{ "booleanValue", .boolean },
    .{ "integerValue", .integer },
    .{ "doubleValue", .double },
    .{ "timestampValue", .timestamp },
    .{ "stringValue", .string },
    .{ "bytesValue", .bytes },
    .{ "referenceValue", .reference },
    .{ "geoPointValue", .geo_point },
    .{ "arrayValue", .array },
    .{ "mapValue", .map },
});

/// A number's text: a JSON number, or a string holding one, as proto3 JSON
/// writes 64-bit integers.
fn numberText(v: std.json.Value) ?[]const u8 {
    return switch (v) {
        .number_string, .string => |s| if (s.len == 0) null else s,
        else => null,
    };
}

fn doubleFrom(v: std.json.Value) DecodeError!f64 {
    const text = numberText(v) orelse return error.InvalidResponse;
    if (v == .string) {
        if (std.mem.eql(u8, text, "NaN")) return std.math.nan(f64);
        if (std.mem.eql(u8, text, "Infinity")) return std.math.inf(f64);
        if (std.mem.eql(u8, text, "-Infinity")) return -std.math.inf(f64);
    }
    // Only a number's own characters: parseFloat also takes "inf" and hex.
    for (text) |c| switch (c) {
        '0'...'9', '-', '+', '.', 'e', 'E' => {},
        else => return error.InvalidResponse,
    };
    return std.fmt.parseFloat(f64, text) catch error.InvalidResponse;
}

const testing = std.testing;
const test_util = @import("test_util.zig");

fn encodeOne(a: Allocator, v: Value) ![]u8 {
    var out: Writer.Allocating = .init(a);
    var jw: Stringify = .{ .writer = &out.writer };
    try writeValue(&jw, v);
    return out.toOwnedSlice();
}

fn decodeOne(a: Allocator, text: []const u8) DecodeError!Value {
    return valueFrom(a, try parseTree(a, text), 0);
}

/// Equality as the wire sees it: NaN equals NaN, and 0 and -0 differ.
pub fn expectValueEqual(expected: Value, actual: Value) anyerror!void {
    try testing.expectEqual(std.meta.activeTag(expected), std.meta.activeTag(actual));
    switch (expected) {
        .null => {},
        .boolean => |b| try testing.expectEqual(b, actual.boolean),
        .integer => |i| try testing.expectEqual(i, actual.integer),
        .double => |d| try testing.expectEqual(@as(u64, @bitCast(d)) | nanBits(d), @as(u64, @bitCast(actual.double)) | nanBits(actual.double)),
        .timestamp => |t| try testing.expectEqual(t.nanoseconds, actual.timestamp.nanoseconds),
        .string => |s| try testing.expectEqualStrings(s, actual.string),
        .bytes => |b| try testing.expectEqualSlices(u8, b, actual.bytes),
        .reference => |r| try testing.expectEqualStrings(r, actual.reference),
        .geo_point => |g| {
            try testing.expectEqual(g.latitude, actual.geo_point.latitude);
            try testing.expectEqual(g.longitude, actual.geo_point.longitude);
        },
        .array => |items| {
            try testing.expectEqual(items.len, actual.array.len);
            for (items, actual.array) |e, a| try expectValueEqual(e, a);
        },
        .map => |fields| try expectFieldsEqual(fields, actual.map),
    }
}

/// Every NaN compares as the one quiet NaN.
fn nanBits(d: f64) u64 {
    return if (std.math.isNan(d)) ~@as(u64, 0) else 0;
}

pub fn expectFieldsEqual(expected: []const Field, actual: []const Field) anyerror!void {
    try testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |e, a| {
        try testing.expectEqualStrings(e.name, a.name);
        try expectValueEqual(e.value, a.value);
    }
}

test "golden: every kind, as the server writes and reads it" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { Value, []const u8 }{
        .{ .null, "{\"nullValue\":\"NULL_VALUE\"}" },
        .{ .{ .boolean = false }, "{\"booleanValue\":false}" },
        .{ .{ .integer = 0 }, "{\"integerValue\":\"0\"}" },
        .{ .{ .integer = std.math.maxInt(i64) }, "{\"integerValue\":\"9223372036854775807\"}" },
        .{ .{ .integer = std.math.minInt(i64) }, "{\"integerValue\":\"-9223372036854775808\"}" },
        .{ .{ .double = 1.5 }, "{\"doubleValue\":1.5}" },
        .{ .{ .double = 3 }, "{\"doubleValue\":3}" },
        .{ .{ .double = -0.0 }, "{\"doubleValue\":-0}" },
        .{ .{ .double = 0.1 }, "{\"doubleValue\":0.1}" },
        .{ .{ .double = 1e300 }, "{\"doubleValue\":1e300}" },
        .{ .{ .double = 5e-324 }, "{\"doubleValue\":5e-324}" },
        .{ .{ .double = 1e21 }, "{\"doubleValue\":1e21}" },
        .{ .{ .double = 123456789012345680 }, "{\"doubleValue\":123456789012345680}" },
        .{ .{ .double = std.math.nan(f64) }, "{\"doubleValue\":\"NaN\"}" },
        .{ .{ .double = std.math.inf(f64) }, "{\"doubleValue\":\"Infinity\"}" },
        .{ .{ .double = -std.math.inf(f64) }, "{\"doubleValue\":\"-Infinity\"}" },
        .{ .{ .timestamp = .{ .nanoseconds = 1_791_153_779_335_637_000 } }, "{\"timestampValue\":\"2026-10-04T22:42:59.335637Z\"}" },
        .{ .{ .timestamp = .{ .nanoseconds = 0 } }, "{\"timestampValue\":\"1970-01-01T00:00:00Z\"}" },
        .{ .{ .string = "é\"\\\n" }, "{\"stringValue\":\"é\\\"\\\\\\n\"}" },
        .{ .{ .bytes = "\x00\xff\xfe" }, "{\"bytesValue\":\"AP/+\"}" },
        .{ .{ .bytes = "" }, "{\"bytesValue\":\"\"}" },
        .{ .{ .reference = "projects/p/databases/(default)/documents/c/x" }, "{\"referenceValue\":\"projects/p/databases/(default)/documents/c/x\"}" },
        .{ .{ .geo_point = .{ .latitude = 34.05, .longitude = -118.25 } }, "{\"geoPointValue\":{\"latitude\":34.05,\"longitude\":-118.25}}" },
        .{ .{ .array = &.{} }, "{\"arrayValue\":{\"values\":[]}}" },
        .{ .{ .array = &.{ .{ .integer = 1 }, .{ .string = "two" } } }, "{\"arrayValue\":{\"values\":[{\"integerValue\":\"1\"},{\"stringValue\":\"two\"}]}}" },
        .{ .{ .map = &.{} }, "{\"mapValue\":{\"fields\":{}}}" },
        .{ .{ .map = &.{ .{ .name = "b", .value = .{ .boolean = true } }, .{ .name = "a-b", .value = .null } } }, "{\"mapValue\":{\"fields\":{\"b\":{\"booleanValue\":true},\"a-b\":{\"nullValue\":\"NULL_VALUE\"}}}}" },
    };
    for (cases) |case| {
        const text = try encodeOne(a, case[0]);
        testing.expectEqualStrings(case[1], text) catch |err| {
            std.debug.print("encoding {any}\n", .{case[0]});
            return err;
        };
        try expectValueEqual(case[0], try decodeOne(a, text));
    }
}

test "decode: what the server sends beside what this library writes" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Measured: the emulator answers nullValue as JSON null.
    try expectValueEqual(.null, try decodeOne(a, "{\"nullValue\":null}"));
    // A bare number for an integer, as the emulator also takes.
    try expectValueEqual(.{ .integer = 5 }, try decodeOne(a, "{\"integerValue\":5}"));
    try expectValueEqual(.{ .integer = -5 }, try decodeOne(a, "{\"integerValue\":\"-5\"}"));
    // Doubles as numbers in any JSON form, or as strings holding one.
    try expectValueEqual(.{ .double = 3 }, try decodeOne(a, "{\"doubleValue\":3}"));
    try expectValueEqual(.{ .double = 1e300 }, try decodeOne(a, "{\"doubleValue\":1E+300}"));
    try expectValueEqual(.{ .double = 2.5 }, try decodeOne(a, "{\"doubleValue\":\"2.5\"}"));
    // An integer too long for i64's digits still decodes as a double.
    try expectValueEqual(.{ .double = 1e20 }, try decodeOne(a, "{\"doubleValue\":100000000000000000000}"));
    // Every fractional-digit form of a timestamp, and offsets.
    try expectValueEqual(.{ .timestamp = .{ .nanoseconds = 1_791_153_779_000_000_000 } }, try decodeOne(a, "{\"timestampValue\":\"2026-10-04T22:42:59Z\"}"));
    try expectValueEqual(.{ .timestamp = .{ .nanoseconds = 1_791_153_779_100_000_000 } }, try decodeOne(a, "{\"timestampValue\":\"2026-10-04T22:42:59.1Z\"}"));
    try expectValueEqual(.{ .timestamp = .{ .nanoseconds = 1_791_153_779_123_456_789 } }, try decodeOne(a, "{\"timestampValue\":\"2026-10-04T22:42:59.123456789Z\"}"));
    try expectValueEqual(.{ .timestamp = .{ .nanoseconds = 1_791_153_779_000_000_000 } }, try decodeOne(a, "{\"timestampValue\":\"2026-10-05T00:42:59+02:00\"}"));
    // Base64 in all four forms proto3 JSON allows.
    for ([_][]const u8{ "AP/+", "AP_-", "AP/+", "AP_-" }) |b64| {
        const text = try std.fmt.allocPrint(a, "{{\"bytesValue\":\"{s}\"}}", .{b64});
        try expectValueEqual(.{ .bytes = "\x00\xff\xfe" }, try decodeOne(a, text));
    }
    try expectValueEqual(.{ .bytes = "ab" }, try decodeOne(a, "{\"bytesValue\":\"YWI=\"}"));
    try expectValueEqual(.{ .bytes = "ab" }, try decodeOne(a, "{\"bytesValue\":\"YWI\"}"));
    // proto3 JSON leaves out what is zero or empty.
    try expectValueEqual(.{ .geo_point = .{ .latitude = 0, .longitude = 10 } }, try decodeOne(a, "{\"geoPointValue\":{\"longitude\":10}}"));
    try expectValueEqual(.{ .geo_point = .{ .latitude = 0, .longitude = 0 } }, try decodeOne(a, "{\"geoPointValue\":{}}"));
    try expectValueEqual(.{ .array = &.{} }, try decodeOne(a, "{\"arrayValue\":{}}"));
    try expectValueEqual(.{ .map = &.{} }, try decodeOne(a, "{\"mapValue\":{}}"));
    // Measured: an emptied map comes back as `{"mapValue": {}}`, spaced.
    try expectValueEqual(.{ .map = &.{} }, try decodeOne(a, "{\"mapValue\":{\n      }}"));
    try expectValueEqual(.{ .array = &.{} }, try decodeOne(a, "{\"arrayValue\":{\"values\":null}}"));
}

test "decode refuses what is no value" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{
        "{}",
        "[]",
        "1",
        "{\"integerValue\":\"1\",\"stringValue\":\"x\"}",
        // The pipeline-only kinds, which the server refuses on write.
        "{\"fieldReferenceValue\":\"a\"}",
        "{\"functionValue\":{}}",
        "{\"pipelineValue\":{}}",
        "{\"variableReferenceValue\":\"x\"}",
        "{\"unknownValue\":1}",
        "{\"nullValue\":\"NULL\"}",
        "{\"nullValue\":0}",
        "{\"booleanValue\":\"true\"}",
        "{\"integerValue\":\"9223372036854775808\"}",
        "{\"integerValue\":\"1.5\"}",
        "{\"integerValue\":\"\"}",
        "{\"integerValue\":null}",
        "{\"integerValue\":true}",
        "{\"doubleValue\":\"nan\"}",
        "{\"doubleValue\":\"inf\"}",
        "{\"doubleValue\":\"0x1p3\"}",
        "{\"doubleValue\":\"\"}",
        "{\"doubleValue\":{}}",
        "{\"timestampValue\":\"2026-10-04\"}",
        "{\"timestampValue\":1}",
        "{\"timestampValue\":\"0000-12-31T00:00:00Z\"}",
        "{\"timestampValue\":\"0001-01-01T00:00:00+00:01\"}",
        "{\"stringValue\":1}",
        "{\"bytesValue\":\"!!!!\"}",
        "{\"bytesValue\":\"AP/-\"}",
        "{\"referenceValue\":{}}",
        "{\"geoPointValue\":[]}",
        "{\"geoPointValue\":{\"latitude\":\"x\"}}",
        "{\"arrayValue\":[]}",
        "{\"arrayValue\":{\"values\":{}}}",
        "{\"arrayValue\":{\"values\":[1]}}",
        "{\"mapValue\":[]}",
        "{\"mapValue\":{\"fields\":[]}}",
        "{\"mapValue\":{\"fields\":{\"a\":1}}}",
    }) |text| {
        if (decodeOne(a, text)) |v| {
            std.debug.print("decoded {s} as {any}\n", .{ text, v });
            return error.TestUnexpectedSuccess;
        } else |err| try testing.expectEqual(error.InvalidResponse, err);
    }
}

test "decode: nesting is bounded" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out: Writer.Allocating = .init(a);
    const w = &out.writer;
    const depth = max_decode_depth + 2;
    for (0..depth) |_| try w.writeAll("{\"arrayValue\":{\"values\":[");
    try w.writeAll("{\"integerValue\":\"1\"}");
    for (0..depth) |_| try w.writeAll("]}}");
    try testing.expectError(error.InvalidResponse, decodeOne(a, out.written()));
}

test "decodeSnapshot: fields, times, and what may be left out" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // As the emulator answered a patch, 2026-10-04.
    const s = try decodeSnapshot(a,
        \\{
        \\  "name": "projects/p/databases/(default)/documents/c/d1",
        \\  "fields": {
        \\    "a": { "mapValue": { "fields": { "b": { "integerValue": "1" } } } },
        \\    "s": { "stringValue": "x" }
        \\  },
        \\  "createTime": "2026-10-04T22:42:59.233365Z",
        \\  "updateTime": "2026-10-04T22:42:59.269778Z",
        \\  "someFutureField": [1, 2, 3]
        \\}
    );
    try testing.expectEqualStrings("d1", s.id());
    try testing.expectEqualStrings("c/d1", s.path());
    try testing.expectEqual(2, s.fields.len);
    try testing.expectEqualStrings("a", s.fields[0].name);
    try testing.expectEqual(1, s.get("a").?.get("b").?.integer);
    try testing.expectEqual(1_791_153_779_233_365_000, s.create_time.nanoseconds);
    try testing.expectEqual(1_791_153_779_269_778_000, s.update_time.nanoseconds);

    // A mask that matched nothing: no fields key at all.
    const bare = try decodeSnapshot(a,
        \\{"name":"projects/p/databases/(default)/documents/d/r3","createTime":"2026-10-04T22:43:54.452591Z","updateTime":"2026-10-04T22:43:54.452591Z"}
    );
    try testing.expectEqual(0, bare.fields.len);

    for ([_][]const u8{
        "",
        "{}",
        "[]",
        "{\"name\":\"n\",\"updateTime\":\"2026-10-04T22:43:54Z\"}",
        "{\"name\":\"n\",\"createTime\":\"2026-10-04T22:43:54Z\"}",
        "{\"name\":\"\",\"createTime\":\"2026-10-04T22:43:54Z\",\"updateTime\":\"2026-10-04T22:43:54Z\"}",
        "{\"name\":1,\"createTime\":\"2026-10-04T22:43:54Z\",\"updateTime\":\"2026-10-04T22:43:54Z\"}",
        "{\"name\":\"n\",\"createTime\":\"x\",\"updateTime\":\"2026-10-04T22:43:54Z\"}",
        "{\"name\":\"n\",\"fields\":[],\"createTime\":\"2026-10-04T22:43:54Z\",\"updateTime\":\"2026-10-04T22:43:54Z\"}",
        "{\"name\":\"n\",\"fields\":{\"a\":{}},\"createTime\":\"2026-10-04T22:43:54Z\",\"updateTime\":\"2026-10-04T22:43:54Z\"}",
        "{\"name\":",
    }) |text| try testing.expectError(error.InvalidResponse, decodeSnapshot(a, text));
}

test "decode pages" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const page = try decodeSnapshotPage(a,
        \\{"documents":[{"name":"projects/p/databases/(default)/documents/c/a","createTime":"2026-10-04T22:42:59.495496Z","updateTime":"2026-10-04T22:42:59.495496Z"},
        \\ {"name":"projects/p/databases/(default)/documents/c/b","fields":{"v":{"integerValue":"1"}},"createTime":"2026-10-04T22:42:59.599473Z","updateTime":"2026-10-04T22:42:59.599473Z"}],
        \\ "nextPageToken":"Ci5wcm9qZWN0cw=="}
    );
    try testing.expectEqual(2, page.documents.len);
    try testing.expectEqualStrings("b", page.documents[1].id());
    try testing.expectEqualStrings("Ci5wcm9qZWN0cw==", page.next_page_token.?);
    const empty = try decodeSnapshotPage(a, "{}");
    try testing.expectEqual(0, empty.documents.len);
    try testing.expectEqual(null, empty.next_page_token);
    try testing.expectEqual(null, (try decodeSnapshotPage(a, "{\"nextPageToken\":\"\"}")).next_page_token);
    try testing.expectError(error.InvalidResponse, decodeSnapshotPage(a, "{\"documents\":{}}"));
    try testing.expectError(error.InvalidResponse, decodeSnapshotPage(a, "{\"nextPageToken\":1}"));

    const ids = try decodeCollectionIdPage(a, "{\"collectionIds\":[\"c\",\"d\"],\"nextPageToken\":\"t\"}");
    try testing.expectEqual(2, ids.collection_ids.len);
    try testing.expectEqualStrings("d", ids.collection_ids[1]);
    try testing.expectEqualStrings("t", ids.next_page_token.?);
    try testing.expectEqual(0, (try decodeCollectionIdPage(a, "")).collection_ids.len);
    try testing.expectError(error.InvalidResponse, decodeCollectionIdPage(a, "{\"collectionIds\":[1]}"));
}

test "golden: commit bodies, and what commit answers" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const name = "projects/p/databases/(default)/documents/c/u2";
    try testing.expectEqualStrings(
        "{\"writes\":[{\"update\":{\"name\":\"projects/p/databases/(default)/documents/c/u2\",\"fields\":{\"v\":{\"integerValue\":\"4\"}}},\"updateMask\":{\"fieldPaths\":[\"v\",\"`a-b`\"]},\"currentDocument\":{\"updateTime\":\"2026-10-04T22:57:15.556285Z\"}}]}",
        try encodeCommit(a, &.{.{
            .name = name,
            .op = .{ .update = .{ .fields = &.{.{ .name = "v", .value = .{ .integer = 4 } }}, .mask = &.{ "v", "`a-b`" } } },
            .precondition = .{ .update_time = .{ .nanoseconds = 1_791_154_635_556_285_000 } },
        }}, null),
    );
    try testing.expectEqualStrings(
        "{\"writes\":[{\"update\":{\"name\":\"projects/p/databases/(default)/documents/c/u2\",\"fields\":{}}},{\"delete\":\"projects/p/databases/(default)/documents/c/u2\",\"currentDocument\":{\"exists\":true}}],\"transaction\":\"EQIAAAAAAAAA\"}",
        try encodeCommit(a, &.{
            .{ .name = name, .op = .{ .update = .{ .fields = &.{} } } },
            .{ .name = name, .op = .delete, .precondition = .{ .exists = true } },
        }, "EQIAAAAAAAAA"),
    );
    // The transaction bodies, in the emulator's ids.
    try testing.expectEqualStrings("{\"options\":{\"readWrite\":{}}}", try encodeBeginTransaction(a, .read_write, null));
    try testing.expectEqualStrings("{\"options\":{\"readWrite\":{\"retryTransaction\":\"EQIAAAAAAAAA\"}}}", try encodeBeginTransaction(a, .read_write, "EQIAAAAAAAAA"));
    try testing.expectEqualStrings("{\"options\":{\"readOnly\":{}}}", try encodeBeginTransaction(a, .{ .read_only = .{} }, null));
    try testing.expectEqualStrings("{\"options\":{\"readOnly\":{\"readTime\":\"2026-10-05T00:00:00Z\"}}}", try encodeBeginTransaction(a, .{ .read_only = .{ .read_time = .{ .nanoseconds = 1_791_158_400_000_000_000 } } }, null));
    try testing.expectEqualStrings("{\"transaction\":\"EQIAAAAAAAAA\"}", try encodeRollback(a, "EQIAAAAAAAAA"));
    try testing.expectEqualStrings("EQIAAAAAAAAA", try decodeBeginTransaction(a, "{\n  \"transaction\": \"EQIAAAAAAAAA\"\n}\n"));
    for ([_][]const u8{ "{}", "{\"transaction\":\"\"}", "{\"transaction\":1}", "[]" }) |text| {
        try testing.expectError(error.InvalidResponse, decodeBeginTransaction(a, text));
    }

    // As the emulator answered, 2026-10-04.
    const r = try decodeCommit(a, "{ \"writeResults\": [{ \"updateTime\": \"2026-10-04T22:57:15.592244Z\" }, { }], \"commitTime\": \"2026-10-04T22:57:15.592244Z\"}");
    try testing.expectEqual(2, r.writes.len);
    try testing.expectEqual(1_791_154_635_592_244_000, r.writes[0].update_time.?.nanoseconds);
    try testing.expectEqual(null, r.writes[1].update_time);
    try testing.expectEqual(0, r.writes[1].transform_results.len);
    try testing.expectEqual(1_791_154_635_592_244_000, r.commit_time.?.nanoseconds);
    try testing.expectEqual(0, (try decodeCommit(a, "{\"commitTime\":\"2026-10-04T22:57:15Z\"}")).writes.len);
    // Measured: the emulator answers a commit of no writes with `{}`.
    try testing.expectEqual(null, (try decodeCommit(a, "{}")).commit_time);
    // Transform results, as the emulator answered them, 2026-10-05.
    const t = try decodeCommit(a,
        \\{"writeResults": [{"updateTime": "2026-10-05T12:15:13.233173Z", "transformResults": [{"timestampValue": "2026-10-05T12:15:13.232Z"}, {"doubleValue": 5.5}, {"nullValue": null}]}], "commitTime": "2026-10-05T12:15:13.233173Z"}
    );
    try testing.expectEqual(3, t.writes[0].transform_results.len);
    try testing.expectEqual(1_791_202_513_232_000_000, t.writes[0].transform_results[0].timestamp.nanoseconds);
    try testing.expectEqual(5.5, t.writes[0].transform_results[1].double);
    try testing.expectEqual(Value.null, t.writes[0].transform_results[2]);
    for ([_][]const u8{
        "{\"writeResults\":[{}]}",
        "{\"writeResults\":[{\"transformResults\":{}}],\"commitTime\":\"2026-10-04T22:57:15Z\"}",
        "{\"writeResults\":[{\"transformResults\":[{}]}],\"commitTime\":\"2026-10-04T22:57:15Z\"}",
        "{\"writeResults\":{},\"commitTime\":\"2026-10-04T22:57:15Z\"}",
        "{\"writeResults\":[1],\"commitTime\":\"2026-10-04T22:57:15Z\"}",
        "{\"writeResults\":[{\"updateTime\":\"x\"}],\"commitTime\":\"2026-10-04T22:57:15Z\"}",
    }) |text| try testing.expectError(error.InvalidResponse, decodeCommit(a, text));
}

test "encodeDocument" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("{\"fields\":{}}", try encodeDocument(arena.allocator(), &.{}));
    try testing.expectEqualStrings(
        "{\"fields\":{\"name\":{\"stringValue\":\"Los Angeles\"},\"population\":{\"integerValue\":\"3900000\"}}}",
        try encodeDocument(arena.allocator(), &.{
            .{ .name = "name", .value = .{ .string = "Los Angeles" } },
            .{ .name = "population", .value = .{ .integer = 3_900_000 } },
        }),
    );
}

/// A random value tree, at most `depth` maps and arrays deep, never an
/// array directly in an array, with what can only be written checked: an
/// in-range timestamp, valid UTF-8.
pub fn randomValue(g: *test_util.ByteGen, a: Allocator, depth: usize, in_array: bool) Allocator.Error!Value {
    const top: u8 = if (depth == 0) 8 else 10;
    var kind = g.intRange(u8, 0, top);
    if (in_array and kind == 9) kind = 10;
    return switch (kind) {
        0 => .null,
        1 => .{ .boolean = g.boolean() },
        2 => .{ .integer = @bitCast(g.int(u64)) },
        3 => .{ .double = switch (g.intRange(u8, 0, 5)) {
            0 => std.math.nan(f64),
            1 => std.math.inf(f64),
            2 => -std.math.inf(f64),
            3 => -0.0,
            else => d: {
                const d: f64 = @bitCast(g.int(u64));
                break :d if (std.math.isNan(d)) 0.5 else d;
            },
        } },
        4 => .{ .timestamp = .{ .nanoseconds = core.timestamp.min.nanoseconds +
            @as(i96, @intCast(g.int(u96) % @as(u96, @intCast(core.timestamp.max.nanoseconds - core.timestamp.min.nanoseconds + 1)))) } },
        5 => .{ .string = try a.dupe(u8, g.utf8(try a.alloc(u8, 24), 24)) },
        6 => .{ .bytes = try a.dupe(u8, g.slice(16)) },
        7 => .{ .reference = "projects/p/databases/(default)/documents/c/x" },
        8 => .{ .geo_point = .{
            .latitude = @as(f64, @floatFromInt(g.intRange(u16, 0, 18000))) / 100 - 90,
            .longitude = @as(f64, @floatFromInt(g.intRange(u16, 0, 36000))) / 100 - 180,
        } },
        9 => a: {
            const items = try a.alloc(Value, g.intRange(u8, 0, 3));
            for (items) |*item| item.* = try randomValue(g, a, depth - 1, true);
            break :a .{ .array = items };
        },
        else => m: {
            if (depth == 0) break :m .null;
            const fields = try a.alloc(Field, g.intRange(u8, 0, 3));
            for (fields, 0..) |*f, i| f.* = .{
                // Distinct names, some that need quoting in a path.
                .name = try std.fmt.allocPrint(a, "{s}{d}", .{ g.pick([]const u8, &.{ "k", "a-b", "é", "`" }), i }),
                .value = try randomValue(g, a, depth - 1, false),
            };
            break :m .{ .map = fields };
        },
    };
}

fn valueRoundTrip(_: void, input: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var g: test_util.ByteGen = .init(input);
    const v = try randomValue(&g, a, 4, false);
    try expectValueEqual(v, try decodeOne(a, try encodeOne(a, v)));
}

test "fuzz codec: value trees round-trip" {
    try test_util.fuzzBytes({}, valueRoundTrip, .{ .corpus = &.{ "", "\x09\x02\x03", "\x0a\x03\x00\x03\x01" } });
}

fn decodeNeverCrashes(_: void, input: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Anything that decodes encodes back to text that decodes the same.
    const v = decodeOne(a, input) catch return;
    try expectValueEqual(v, try decodeOne(a, try encodeOne(a, v)));
    _ = decodeSnapshot(a, input) catch {};
}

test "fuzz codec: arbitrary text never crashes" {
    try test_util.fuzzBytes({}, decodeNeverCrashes, .{ .corpus = &.{
        "{\"mapValue\":{\"fields\":{\"a\":{\"doubleValue\":\"NaN\"}}}}",
        "{\"arrayValue\":{\"values\":[{\"bytesValue\":\"AP_-\"}]}}",
        "{\"geoPointValue\":{\"latitude\":1e400}}",
        "{\"integerValue\":-0}",
        "{\"timestampValue\":\"0000-01-01T00:00:00Z\"}",
    } });
}
