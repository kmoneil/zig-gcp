//! Queries: a `Query` checked as the server would check it, written as a
//! `StructuredQuery`, sent to `runQuery` or `runAggregationQuery`, and the
//! streamed answer read back.
//!
//! What the emulator showed (2026-10-05, `_tmp/firestore-m3/probe.py`)
//! and the checks here take from it: an equality with null or NaN as a
//! field filter matches nothing, so `equal` and `not_equal` against them
//! are sent as the server's unary tests, as Google's clients send them; a
//! range or `array_contains` with null or NaN matches nothing either, and
//! is refused; `in` and `array_contains_any` take 1 to 30 values,
//! `not_in` 1 to 10; and a cursor may hold no more values than the query
//! has orders.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Stringify = std.json.Stringify;
const Writer = std.Io.Writer;
const core = @import("core");

const Client = @import("Client.zig");
const codec = @import("codec.zig");
const errors = @import("errors.zig");
const names = @import("names.zig");
const rpc = @import("rpc.zig");
const types = @import("types.zig");
const validate = @import("validate.zig");
const Error = errors.Error;
const Value = types.Value;

/// Deepest nesting of `all` and `any` sent.
pub const max_filter_depth = 32;
/// Most values `in` and `array_contains_any` take: "'IN' supports up to 30
/// comparison values."
pub const max_in_values = 30;
/// Most values `not_in` takes: "'NOT_IN' supports up to 10 comparison
/// values."
pub const max_not_in_values = 10;
/// Most aggregations in one query: "The maximum number of aggregations
/// allowed in an aggregation query is 5."
pub const max_aggregations = 5;

/// Runs `query` and decodes its results into `response`. The call has
/// begun.
pub fn run(client: *Client, query: types.Query, options: types.QueryOptions, response: *std.heap.ArenaAllocator) Error!types.QueryResult {
    var scratch: std.heap.ArenaAllocator = .init(client.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const parent = try check(client, a, query);
    if (options.read_time) |t| try rpc.checkTime(client, t, "read time");
    try rpc.checkTransaction(client, options.transaction, options.read_time);
    const url = writeUrl(a, client, parent, ":runQuery") catch return error.OutOfMemory;
    const body = try encode(a, query, null, options);

    // A read: asking again is harmless.
    const reply = try rpc.execute(client, response, .{ .method = .POST, .path = url, .body = body });
    return codec.decodeRunQuery(response.allocator(), reply) catch |err|
        return rpc.decodeFailed(client, err, "runQuery");
}

/// Runs `aggregations` over `query`'s results. The call has begun.
pub fn aggregate(
    client: *Client,
    query: types.Query,
    aggregations: []const types.Aggregation,
    options: types.QueryOptions,
    response: *std.heap.ArenaAllocator,
) Error!types.AggregationResult {
    if (aggregations.len == 0 or aggregations.len > max_aggregations) {
        return rpc.refuse(client, error.InvalidArgument, "an aggregation query takes 1 to 5 aggregations", .{});
    }
    for (aggregations) |agg| switch (agg) {
        .count => {},
        .sum, .avg => |field| if (names.fieldPathProblem(field)) |problem| {
            return rpc.refuse(client, error.InvalidResourceId, "invalid field path in an aggregation: {s}", .{problem});
        },
    };
    var scratch: std.heap.ArenaAllocator = .init(client.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const parent = try check(client, a, query);
    if (options.read_time) |t| try rpc.checkTime(client, t, "read time");
    try rpc.checkTransaction(client, options.transaction, options.read_time);
    const url = writeUrl(a, client, parent, ":runAggregationQuery") catch return error.OutOfMemory;
    // A select means nothing to an aggregation, and the emulator refuses a
    // sum or average over one of names only: "Aggregation over non-key
    // properties is not supported for base query that only returns keys."
    var unselected = query;
    unselected.select = null;
    const body = try encode(a, unselected, aggregations, options);

    const reply = try rpc.execute(client, response, .{ .method = .POST, .path = url, .body = body });
    return codec.decodeAggregation(response.allocator(), reply, aggregations.len) catch |err|
        return rpc.decodeFailed(client, err, "runAggregationQuery");
}

/// Checks `query` as the server would, and returns its parent's path.
pub fn check(client: *Client, a: Allocator, query: types.Query) Error![]const u8 {
    const id = switch (query.from) {
        .collection, .group => |id| id,
    };
    if (validate.idProblem(id)) |problem| {
        return rpc.refuse(client, error.InvalidResourceId, "invalid collection id: {s}", .{problem});
    }
    const parent = if (query.parent.len == 0) "" else try rpc.checkedPath(client, a, .init(query.parent), .document);
    if (query.filter != null and query.where.len > 0) {
        return rpc.refuse(client, error.InvalidArgument, "a query takes where or filter, not both", .{});
    }
    for (query.where) |c| try checkCondition(client, c);
    if (query.filter) |f| try checkFilter(client, f, 0);
    for (query.order_by) |o| if (names.fieldPathProblem(o.field)) |problem| {
        return rpc.refuse(client, error.InvalidResourceId, "invalid field path in the order: {s}", .{problem});
    };
    if (query.select) |fields| for (fields) |f| if (names.fieldPathProblem(f)) |problem| {
        return rpc.refuse(client, error.InvalidResourceId, "invalid field path in the select: {s}", .{problem});
    };
    if (query.start_at) |c| try checkCursor(client, query.order_by, c, "start");
    if (query.end_at) |c| try checkCursor(client, query.order_by, c, "end");
    if (query.offset > std.math.maxInt(i32)) return rpc.refuse(client, error.InvalidArgument, "the offset is over 2^31 - 1", .{});
    if (query.limit) |l| if (l > std.math.maxInt(i32)) return rpc.refuse(client, error.InvalidArgument, "the limit is over 2^31 - 1", .{});
    return parent;
}

fn checkFilter(client: *Client, f: types.Filter, depth: usize) Error!void {
    if (depth >= max_filter_depth) return rpc.refuse(client, error.InvalidArgument, "the filter nests over 32 deep", .{});
    switch (f) {
        .condition => |c| try checkCondition(client, c),
        .all, .any => |filters| {
            if (filters.len == 0) return rpc.refuse(client, error.InvalidArgument, "an all or any filter needs at least one filter", .{});
            for (filters) |inner| try checkFilter(client, inner, depth + 1);
        },
    }
}

fn isNan(v: Value) bool {
    return v == .double and std.math.isNan(v.double);
}

fn checkCondition(client: *Client, c: types.Condition) Error!void {
    if (names.fieldPathProblem(c.field)) |problem| {
        return rpc.refuse(client, error.InvalidResourceId, "invalid field path in a condition: {s}", .{problem});
    }
    const name_field = std.mem.eql(u8, c.field, "__name__");
    // A name is never null or NaN, and the server refuses to test one:
    // "__key__ filter value must be a Key".
    if (name_field and unaryOp(c) != null) {
        return rpc.refuse(client, error.InvalidArgument, "__name__ is never null or NaN, so it cannot be tested for either", .{});
    }
    // Nor is it an array: "the name __key__ is reserved".
    if (name_field and (c.op == .array_contains or c.op == .array_contains_any)) {
        return rpc.refuse(client, error.InvalidArgument, "__name__ is no array, so it cannot be tested for what an array holds", .{});
    }
    switch (c.op) {
        .is_null, .is_nan, .is_not_null, .is_not_nan => return,
        .equal, .not_equal => {
            if (c.value == .null or isNan(c.value)) return;
            try checkValue(client, c.field, c.value, name_field);
        },
        .less_than, .less_than_or_equal, .greater_than, .greater_than_or_equal, .array_contains => {
            // Measured: these match nothing, so a query with one is a mistake.
            if (c.value == .null or isNan(c.value)) {
                return rpc.refuse(client, error.InvalidArgument, "the condition on {s} compares with null or NaN, which matches nothing: is_null, is_nan and their negations test for them", .{c.field});
            }
            try checkValue(client, c.field, c.value, name_field and c.op != .array_contains);
        },
        .in, .array_contains_any, .not_in => {
            const items = switch (c.value) {
                .array => |items| items,
                else => return rpc.refuse(client, error.InvalidArgument, "the condition on {s} takes an array of values", .{c.field}),
            };
            const most: usize = if (c.op == .not_in) max_not_in_values else max_in_values;
            if (items.len == 0 or items.len > most) {
                return rpc.refuse(client, error.InvalidArgument, "the condition on {s} takes 1 to {d} values", .{ c.field, most });
            }
            for (items) |item| try checkValue(client, c.field, item, name_field and c.op != .array_contains_any);
        },
    }
}

/// A value a query sends: what a document could store, a reference where
/// it is compared with names.
fn checkValue(client: *Client, field: []const u8, v: Value, reference: bool) Error!void {
    if (reference and v != .reference) {
        return rpc.refuse(client, error.InvalidArgument, "__name__ is compared with references, which Client.documentName builds", .{});
    }
    var where_buf: [160]u8 = undefined;
    if (validate.fieldsProblem(&.{.{ .name = "value", .value = v }}, &where_buf)) |problem| {
        return rpc.refuse(client, error.InvalidArgument, "invalid value in the condition on {s}: {s}", .{ field, problem.what });
    }
}

fn checkCursor(client: *Client, order_by: []const types.Order, c: types.Cursor, which: []const u8) Error!void {
    // Measured: "Cursor has too many values.", the implicit order by name
    // not counted.
    if (c.values.len > order_by.len) {
        return rpc.refuse(client, error.InvalidArgument, "the {s} cursor holds {d} values for {d} orders", .{ which, c.values.len, order_by.len });
    }
    for (c.values, order_by[0..c.values.len]) |v, o| {
        // Measured: "Cursor __key__ value is not a document reference."
        try checkValue(client, o.field, v, std.mem.eql(u8, o.field, "__name__"));
    }
}

fn writeUrl(a: Allocator, client: *const Client, parent: []const u8, verb: []const u8) Writer.Error![]const u8 {
    var out: Writer.Allocating = .init(a);
    try names.writeDocumentsPath(&out.writer, client.project_id, client.database_id, parent);
    try out.writer.writeAll(verb);
    return out.written();
}

/// The `runQuery` body, or the `runAggregationQuery` one when
/// `aggregations` is set. The query has been checked.
pub fn encode(a: Allocator, query: types.Query, aggregations: ?[]const types.Aggregation, options: types.QueryOptions) Allocator.Error![]u8 {
    var out: Writer.Allocating = .init(a);
    var jw: Stringify = .{ .writer = &out.writer };
    writeBody(&jw, query, aggregations, options) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn writeBody(jw: *Stringify, query: types.Query, aggregations: ?[]const types.Aggregation, options: types.QueryOptions) Stringify.Error!void {
    try jw.beginObject();
    if (aggregations) |aggs| {
        try jw.objectField("structuredAggregationQuery");
        try jw.beginObject();
        try jw.objectField("structuredQuery");
        try writeStructuredQuery(jw, query);
        try jw.objectField("aggregations");
        try jw.beginArray();
        for (aggs, 0..) |agg, i| try writeAggregation(jw, agg, i);
        try jw.endArray();
        try jw.endObject();
    } else {
        try jw.objectField("structuredQuery");
        try writeStructuredQuery(jw, query);
    }
    if (options.read_time) |t| {
        try jw.objectField("readTime");
        try codec.writeTimestamp(jw, t);
    }
    if (options.transaction) |t| {
        try jw.objectField("transaction");
        try jw.write(t);
    }
    try jw.endObject();
}

/// The alias of the `i`th aggregation: the answer is matched by it.
pub fn alias(buf: *[8]u8, i: usize) []const u8 {
    return std.fmt.bufPrint(buf, "a{d}", .{i}) catch unreachable;
}

fn writeAggregation(jw: *Stringify, agg: types.Aggregation, i: usize) Stringify.Error!void {
    try jw.beginObject();
    try jw.objectField("alias");
    var buf: [8]u8 = undefined;
    try jw.write(alias(&buf, i));
    switch (agg) {
        .count => |c| {
            try jw.objectField("count");
            try jw.beginObject();
            if (c.up_to) |n| {
                try jw.objectField("upTo");
                try jw.print("\"{d}\"", .{n});
            }
            try jw.endObject();
        },
        .sum, .avg => |field| {
            try jw.objectField(if (agg == .sum) "sum" else "avg");
            try jw.beginObject();
            try jw.objectField("field");
            try writeFieldReference(jw, field);
            try jw.endObject();
        },
    }
    try jw.endObject();
}

fn writeFieldReference(jw: *Stringify, field: []const u8) Stringify.Error!void {
    try jw.beginObject();
    try jw.objectField("fieldPath");
    try jw.write(field);
    try jw.endObject();
}

fn writeStructuredQuery(jw: *Stringify, query: types.Query) Stringify.Error!void {
    try jw.beginObject();
    if (query.select) |fields| {
        try jw.objectField("select");
        try jw.beginObject();
        try jw.objectField("fields");
        try jw.beginArray();
        for (fields) |f| try writeFieldReference(jw, f);
        try jw.endArray();
        try jw.endObject();
    }
    try jw.objectField("from");
    try jw.beginArray();
    try jw.beginObject();
    try jw.objectField("collectionId");
    switch (query.from) {
        .collection => |id| try jw.write(id),
        .group => |id| {
            try jw.write(id);
            try jw.objectField("allDescendants");
            try jw.write(true);
        },
    }
    try jw.endObject();
    try jw.endArray();
    if (query.filter) |f| {
        try jw.objectField("where");
        try writeFilter(jw, f);
    } else if (query.where.len == 1) {
        try jw.objectField("where");
        try writeCondition(jw, query.where[0]);
    } else if (query.where.len > 1) {
        try jw.objectField("where");
        try jw.beginObject();
        try jw.objectField("compositeFilter");
        try jw.beginObject();
        try jw.objectField("op");
        try jw.write("AND");
        try jw.objectField("filters");
        try jw.beginArray();
        for (query.where) |c| try writeCondition(jw, c);
        try jw.endArray();
        try jw.endObject();
        try jw.endObject();
    }
    if (query.order_by.len > 0) {
        try jw.objectField("orderBy");
        try jw.beginArray();
        for (query.order_by) |o| {
            try jw.beginObject();
            try jw.objectField("field");
            try writeFieldReference(jw, o.field);
            try jw.objectField("direction");
            try jw.write(switch (o.direction) {
                .ascending => "ASCENDING",
                .descending => "DESCENDING",
            });
            try jw.endObject();
        }
        try jw.endArray();
    }
    // startAt's `before` includes the position; endAt's excludes it.
    if (query.start_at) |c| try writeCursor(jw, "startAt", c, c.inclusive);
    if (query.end_at) |c| try writeCursor(jw, "endAt", c, !c.inclusive);
    if (query.offset > 0) {
        try jw.objectField("offset");
        try jw.write(query.offset);
    }
    if (query.limit) |l| {
        try jw.objectField("limit");
        try jw.write(l);
    }
    try jw.endObject();
}

fn writeCursor(jw: *Stringify, field: []const u8, c: types.Cursor, before: bool) Stringify.Error!void {
    try jw.objectField(field);
    try jw.beginObject();
    try jw.objectField("values");
    try jw.beginArray();
    for (c.values) |v| try codec.writeValue(jw, v);
    try jw.endArray();
    try jw.objectField("before");
    try jw.write(before);
    try jw.endObject();
}

fn writeFilter(jw: *Stringify, f: types.Filter) Stringify.Error!void {
    switch (f) {
        .condition => |c| try writeCondition(jw, c),
        .all, .any => |filters| {
            try jw.beginObject();
            try jw.objectField("compositeFilter");
            try jw.beginObject();
            try jw.objectField("op");
            try jw.write(if (f == .all) "AND" else "OR");
            try jw.objectField("filters");
            try jw.beginArray();
            for (filters) |inner| try writeFilter(jw, inner);
            try jw.endArray();
            try jw.endObject();
            try jw.endObject();
        },
    }
}

/// The unary test a condition is sent as, if any: the four `is_*`
/// operators, and equality or its negation with null or NaN.
fn unaryOp(c: types.Condition) ?[]const u8 {
    return switch (c.op) {
        .is_null => "IS_NULL",
        .is_nan => "IS_NAN",
        .is_not_null => "IS_NOT_NULL",
        .is_not_nan => "IS_NOT_NAN",
        .equal => if (c.value == .null) "IS_NULL" else if (isNan(c.value)) "IS_NAN" else null,
        .not_equal => if (c.value == .null) "IS_NOT_NULL" else if (isNan(c.value)) "IS_NOT_NAN" else null,
        else => null,
    };
}

fn writeCondition(jw: *Stringify, c: types.Condition) Stringify.Error!void {
    try jw.beginObject();
    if (unaryOp(c)) |op| {
        try jw.objectField("unaryFilter");
        try jw.beginObject();
        try jw.objectField("field");
        try writeFieldReference(jw, c.field);
        try jw.objectField("op");
        try jw.write(op);
        try jw.endObject();
    } else {
        try jw.objectField("fieldFilter");
        try jw.beginObject();
        try jw.objectField("field");
        try writeFieldReference(jw, c.field);
        try jw.objectField("op");
        try jw.write(switch (c.op) {
            .less_than => "LESS_THAN",
            .less_than_or_equal => "LESS_THAN_OR_EQUAL",
            .greater_than => "GREATER_THAN",
            .greater_than_or_equal => "GREATER_THAN_OR_EQUAL",
            .equal => "EQUAL",
            .not_equal => "NOT_EQUAL",
            .array_contains => "ARRAY_CONTAINS",
            .in => "IN",
            .array_contains_any => "ARRAY_CONTAINS_ANY",
            .not_in => "NOT_IN",
            .is_null, .is_nan, .is_not_null, .is_not_nan => unreachable,
        });
        try jw.objectField("value");
        try codec.writeValue(jw, c.value);
        try jw.endObject();
    }
    try jw.endObject();
}

const testing = std.testing;
const test_util = @import("test_util.zig");

inline fn queryElement(comptime path: []const u8) []const u8 {
    return "{\"document\":" ++ test_util.docBody(path, "{}") ++ ",\"readTime\":\"2026-10-05T12:43:42.208112Z\"}";
}

test "golden: a query in full, as runQuery takes it" {
    var h: test_util.Harness = undefined;
    try h.init(&.{.{ .respond = .{ .body = "[" ++ queryElement("cities/LA/landmarks/a") ++ ",\n{\"document\":" ++ test_util.docBody("cities/LA/landmarks/b", "{}") ++ ",\"readTime\":\"2026-10-05T12:43:42.208112Z\",\"done\":true}]" } }}, .{});
    defer h.deinit();
    var r = try h.client.runQuery(.{
        .from = .{ .group = "landmarks" },
        .parent = "cities/LA",
        .where = &.{
            .{ .field = "height", .op = .greater_than, .value = .{ .integer = 100 } },
            .{ .field = "kind", .op = .in, .value = .{ .array = &.{ .{ .string = "tower" }, .{ .string = "bridge" } } } },
        },
        .order_by = &.{ .{ .field = "height", .direction = .descending }, .{ .field = "__name__" } },
        .select = &.{ "height", "`a-b`" },
        .start_at = .{ .values = &.{.{ .integer = 500 }}, .inclusive = false },
        .end_at = .{ .values = &.{.{ .integer = 100 }} },
        .offset = 2,
        .limit = 10,
    }, .{ .read_time = .{ .nanoseconds = 1_791_202_542_000_000_000 } });
    defer r.deinit();
    try h.expectRequest(0, .POST, test_util.base ++ "/cities/LA:runQuery",
        \\{"structuredQuery":{"select":{"fields":[{"fieldPath":"height"},{"fieldPath":"`a-b`"}]},"from":[{"collectionId":"landmarks","allDescendants":true}],
    ++
        \\"where":{"compositeFilter":{"op":"AND","filters":[{"fieldFilter":{"field":{"fieldPath":"height"},"op":"GREATER_THAN","value":{"integerValue":"100"}}},{"fieldFilter":{"field":{"fieldPath":"kind"},"op":"IN","value":{"arrayValue":{"values":[{"stringValue":"tower"},{"stringValue":"bridge"}]}}}}]}},
    ++
        \\"orderBy":[{"field":{"fieldPath":"height"},"direction":"DESCENDING"},{"field":{"fieldPath":"__name__"},"direction":"ASCENDING"}],"startAt":{"values":[{"integerValue":"500"}],"before":false},"endAt":{"values":[{"integerValue":"100"}],"before":false},"offset":2,"limit":10},"readTime":"2026-10-05T12:15:42Z"}
    );
    try testing.expectEqual(2, r.value.documents.len);
    try testing.expectEqualStrings("b", r.value.documents[1].id());
    try testing.expectEqual(1_791_204_222_208_112_000, r.value.read_time.nanoseconds);
}

test "golden: equality with null or NaN goes as the server's own tests; trees of all and any" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = "[{\"readTime\":\"2026-10-05T12:43:42Z\",\"done\":true}]" } },
        .{ .respond = .{ .body = "[{\"readTime\":\"2026-10-05T12:43:42Z\",\"done\":true}]" } },
    }, .{});
    defer h.deinit();
    const nan = std.math.nan(f64);
    var r = try h.client.runQuery(.{ .from = .{ .collection = "c" }, .where = &.{
        .{ .field = "a", .op = .equal, .value = .null },
        .{ .field = "b", .op = .equal, .value = .{ .double = nan } },
        .{ .field = "c", .op = .not_equal, .value = .null },
        .{ .field = "d", .op = .not_equal, .value = .{ .double = nan } },
        .{ .field = "e", .op = .is_null },
        .{ .field = "f", .op = .is_not_nan },
    } }, .{});
    defer r.deinit();
    try h.expectRequest(0, .POST, test_util.base ++ ":runQuery",
        \\{"structuredQuery":{"from":[{"collectionId":"c"}],"where":{"compositeFilter":{"op":"AND","filters":[
    ++
        \\{"unaryFilter":{"field":{"fieldPath":"a"},"op":"IS_NULL"}},{"unaryFilter":{"field":{"fieldPath":"b"},"op":"IS_NAN"}},{"unaryFilter":{"field":{"fieldPath":"c"},"op":"IS_NOT_NULL"}},
    ++
        \\{"unaryFilter":{"field":{"fieldPath":"d"},"op":"IS_NOT_NAN"}},{"unaryFilter":{"field":{"fieldPath":"e"},"op":"IS_NULL"}},{"unaryFilter":{"field":{"fieldPath":"f"},"op":"IS_NOT_NAN"}}]}}}}
    );
    try testing.expectEqual(0, r.value.documents.len);

    var tree = try h.client.runQuery(.{ .from = .{ .collection = "c" }, .filter = .{ .any = &.{
        .{ .condition = .{ .field = "a", .op = .equal, .value = .{ .integer = 1 } } },
        .{ .all = &.{
            .{ .condition = .{ .field = "b", .op = .array_contains, .value = .{ .string = "x" } } },
            .{ .condition = .{ .field = "c", .op = .not_in, .value = .{ .array = &.{.{ .boolean = false }} } } },
        } },
    } } }, .{});
    defer tree.deinit();
    try h.expectRequest(1, .POST, test_util.base ++ ":runQuery",
        \\{"structuredQuery":{"from":[{"collectionId":"c"}],"where":{"compositeFilter":{"op":"OR","filters":[{"fieldFilter":{"field":{"fieldPath":"a"},"op":"EQUAL","value":{"integerValue":"1"}}},
    ++
        \\{"compositeFilter":{"op":"AND","filters":[{"fieldFilter":{"field":{"fieldPath":"b"},"op":"ARRAY_CONTAINS","value":{"stringValue":"x"}}},{"fieldFilter":{"field":{"fieldPath":"c"},"op":"NOT_IN","value":{"arrayValue":{"values":[{"booleanValue":false}]}}}}]}}]}}}}
    );
}

test "queries the server would refuse, or that match nothing, are refused before sending" {
    var h: test_util.Harness = undefined;
    try h.init(&.{}, .{});
    defer h.deinit();
    const c = &h.client;
    const Case = struct { types.Query, anyerror, []const u8 };
    var deep: [40]types.Filter = undefined;
    deep[deep.len - 1] = .{ .condition = .{ .field = "a", .op = .is_null } };
    var i: usize = deep.len - 1;
    while (i > 0) : (i -= 1) deep[i - 1] = .{ .all = deep[i .. i + 1] };
    var many: [31]types.Value = undefined;
    for (&many, 0..) |*v, n| v.* = .{ .integer = @intCast(n) };
    const cases = [_]Case{
        .{ .{ .from = .{ .collection = "a/b" } }, error.InvalidResourceId, "invalid collection id" },
        .{ .{ .from = .{ .group = "__x__" } }, error.InvalidResourceId, "invalid collection id" },
        .{ .{ .from = .{ .collection = "c" }, .parent = "cities" }, error.InvalidResourceId, "even number" },
        .{ .{ .from = .{ .collection = "c" }, .where = &.{.{ .field = "a", .op = .is_null }}, .filter = .{ .condition = .{ .field = "a", .op = .is_null } } }, error.InvalidArgument, "not both" },
        .{ .{ .from = .{ .collection = "c" }, .filter = .{ .all = &.{} } }, error.InvalidArgument, "at least one filter" },
        .{ .{ .from = .{ .collection = "c" }, .filter = deep[0] }, error.InvalidArgument, "over 32 deep" },
        .{ .{ .from = .{ .collection = "c" }, .where = &.{.{ .field = "a", .op = .less_than, .value = .null }} }, error.InvalidArgument, "matches nothing" },
        .{ .{ .from = .{ .collection = "c" }, .where = &.{.{ .field = "a", .op = .greater_than_or_equal, .value = .{ .double = std.math.nan(f64) } }} }, error.InvalidArgument, "matches nothing" },
        .{ .{ .from = .{ .collection = "c" }, .where = &.{.{ .field = "a", .op = .array_contains, .value = .null }} }, error.InvalidArgument, "matches nothing" },
        .{ .{ .from = .{ .collection = "c" }, .where = &.{.{ .field = "a", .op = .in, .value = .{ .integer = 1 } }} }, error.InvalidArgument, "takes an array" },
        .{ .{ .from = .{ .collection = "c" }, .where = &.{.{ .field = "a", .op = .in, .value = .{ .array = &.{} } }} }, error.InvalidArgument, "1 to 30 values" },
        .{ .{ .from = .{ .collection = "c" }, .where = &.{.{ .field = "a", .op = .array_contains_any, .value = .{ .array = &many } }} }, error.InvalidArgument, "1 to 30 values" },
        .{ .{ .from = .{ .collection = "c" }, .where = &.{.{ .field = "a", .op = .not_in, .value = .{ .array = many[0..11] } }} }, error.InvalidArgument, "1 to 10 values" },
        .{ .{ .from = .{ .collection = "c" }, .where = &.{.{ .field = "a-b", .op = .is_null }} }, error.InvalidResourceId, "in a condition" },
        .{ .{ .from = .{ .collection = "c" }, .where = &.{.{ .field = "__name__", .op = .equal, .value = .{ .string = "c/x" } }} }, error.InvalidArgument, "references" },
        .{ .{ .from = .{ .collection = "c" }, .where = &.{.{ .field = "__name__", .op = .in, .value = .{ .array = &.{.{ .string = "x" }} } }} }, error.InvalidArgument, "references" },
        .{ .{ .from = .{ .collection = "c" }, .where = &.{.{ .field = "__name__", .op = .is_not_null }} }, error.InvalidArgument, "never null or NaN" },
        .{ .{ .from = .{ .collection = "c" }, .where = &.{.{ .field = "__name__", .op = .equal, .value = .null }} }, error.InvalidArgument, "never null or NaN" },
        .{ .{ .from = .{ .collection = "c" }, .where = &.{.{ .field = "__name__", .op = .array_contains, .value = .{ .reference = "projects/p/databases/(default)/documents/c/x" } }} }, error.InvalidArgument, "no array" },
        .{ .{ .from = .{ .collection = "c" }, .where = &.{.{ .field = "__name__", .op = .array_contains_any, .value = .{ .array = &.{.{ .reference = "projects/p/databases/(default)/documents/c/x" }} } }} }, error.InvalidArgument, "no array" },
        .{ .{ .from = .{ .collection = "c" }, .where = &.{.{ .field = "a", .op = .equal, .value = .{ .string = "\xff" } }} }, error.InvalidArgument, "UTF-8" },
        .{ .{ .from = .{ .collection = "c" }, .order_by = &.{.{ .field = "a-b" }} }, error.InvalidResourceId, "in the order" },
        .{ .{ .from = .{ .collection = "c" }, .select = &.{"__x__"} }, error.InvalidResourceId, "in the select" },
        .{ .{ .from = .{ .collection = "c" }, .order_by = &.{.{ .field = "a" }}, .start_at = .{ .values = &.{ .{ .integer = 1 }, .{ .integer = 2 } } } }, error.InvalidArgument, "2 values for 1 orders" },
        .{ .{ .from = .{ .collection = "c" }, .end_at = .{ .values = &.{.{ .integer = 1 }} } }, error.InvalidArgument, "1 values for 0 orders" },
        .{ .{ .from = .{ .collection = "c" }, .order_by = &.{.{ .field = "__name__" }}, .start_at = .{ .values = &.{.{ .string = "x" }} } }, error.InvalidArgument, "references" },
        .{ .{ .from = .{ .collection = "c" }, .limit = std.math.maxInt(i32) + 1 }, error.InvalidArgument, "limit" },
        .{ .{ .from = .{ .collection = "c" }, .offset = std.math.maxInt(i32) + 1 }, error.InvalidArgument, "offset" },
    };
    for (cases, 0..) |case, n| {
        testing.expectError(case[1], c.runQuery(case[0], .{})) catch |err| {
            std.debug.print("case {d}\n", .{n});
            return err;
        };
        try h.expectDiag(case[2]);
    }
    try testing.expectError(error.InvalidArgument, c.runQuery(.{ .from = .{ .collection = "c" } }, .{ .read_time = .{ .nanoseconds = std.math.maxInt(i96) } }));
    try testing.expectError(error.InvalidArgument, c.runAggregationQuery(.{ .from = .{ .collection = "c" } }, &.{}, .{}));
    try h.expectDiag("1 to 5 aggregations");
    try testing.expectError(error.InvalidArgument, c.runAggregationQuery(.{ .from = .{ .collection = "c" } }, &.{ .{ .count = .{} }, .{ .count = .{} }, .{ .count = .{} }, .{ .count = .{} }, .{ .count = .{} }, .{ .count = .{} } }, .{}));
    try testing.expectError(error.InvalidResourceId, c.runAggregationQuery(.{ .from = .{ .collection = "c" } }, &.{.{ .sum = "a-b" }}, .{}));
    // A reference compared with __name__, in or out of a list, is fine.
    _ = check(c, testing.allocator, .{
        .from = .{ .collection = "c" },
        .where = &.{
            .{ .field = "__name__", .op = .greater_than, .value = .{ .reference = "projects/p/databases/(default)/documents/c/x" } },
            .{ .field = "__name__", .op = .not_in, .value = .{ .array = &.{.{ .reference = "projects/p/databases/(default)/documents/c/y" }} } },
            // in takes arrays among its values: a field equal to one matches.
            .{ .field = "pair", .op = .in, .value = .{ .array = &.{.{ .array = &.{ .{ .integer = 1 }, .{ .integer = 2 } } }} } },
        },
    }) catch |err| {
        std.debug.print("{s}\n", .{h.diag.message()});
        return err;
    };
    try h.expectRequestCount(0);
}

test "golden: aggregations, under aliases of the library's own, answered in order" {
    var h: test_util.Harness = undefined;
    try h.init(&.{.{ .respond = .{ .body =
        \\[{"result": {"aggregateFields": {"a2": {"doubleValue": 2.0}, "a0": {"integerValue": "3"}, "a1": {"integerValue": "6"}}}, "readTime": "2026-10-05T12:43:42.235453Z", "done": true}]
    } }}, .{});
    defer h.deinit();
    var r = try h.client.runAggregationQuery(.{ .from = .{ .group = "kids" }, .where = &.{.{ .field = "n", .op = .greater_than, .value = .{ .integer = 0 } }}, .limit = 100 }, &.{
        .{ .count = .{ .up_to = 1000 } },
        .{ .sum = "n" },
        .{ .avg = "stats.`n-2`" },
    }, .{});
    defer r.deinit();
    try h.expectRequest(0, .POST, test_util.base ++ ":runAggregationQuery",
        \\{"structuredAggregationQuery":{"structuredQuery":{"from":[{"collectionId":"kids","allDescendants":true}],"where":{"fieldFilter":{"field":{"fieldPath":"n"},"op":"GREATER_THAN","value":{"integerValue":"0"}}},"limit":100},
    ++
        \\"aggregations":[{"alias":"a0","count":{"upTo":"1000"}},{"alias":"a1","sum":{"field":{"fieldPath":"n"}}},{"alias":"a2","avg":{"field":{"fieldPath":"stats.`n-2`"}}}]}}
    );
    try testing.expectEqual(3, r.value.values[0].integer);
    try testing.expectEqual(6, r.value.values[1].integer);
    try testing.expectEqual(2.0, r.value.values[2].double);
    try testing.expectEqual(1_791_204_222_235_453_000, r.value.read_time.nanoseconds);
}

test "decode: query and aggregation answers, and the ones that are wrong" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // As the emulator answers an empty result.
    const empty = try codec.decodeRunQuery(a, "[{\n  \"readTime\": \"2026-10-05T12:43:42.208112Z\",\n  \"done\": true\n}]\n");
    try testing.expectEqual(0, empty.documents.len);
    // Progress messages counting what an offset skipped, as production may send.
    const skipped = try codec.decodeRunQuery(a, "[{\"readTime\":\"2026-10-05T12:43:42Z\",\"skippedResults\":2},{\"readTime\":\"2026-10-05T12:43:43Z\",\"skippedResults\":\"3\"}," ++ queryElement("c/a") ++ "]");
    try testing.expectEqual(5, skipped.skipped_results);
    try testing.expectEqual(1, skipped.documents.len);
    try testing.expectEqual(1_791_204_222_208_112_000, skipped.read_time.nanoseconds);
    for ([_][]const u8{ "{}", "[]", "[1]", "[{\"document\":{}}]", "[{\"readTime\":\"2026-10-05T12:43:42Z\",\"skippedResults\":-1}]", "[{\"readTime\":\"x\"}]" }) |text| {
        try testing.expectError(error.InvalidResponse, codec.decodeRunQuery(a, text));
    }
    const agg = try codec.decodeAggregation(a, "[{\"readTime\":\"2026-10-05T12:43:42Z\"},{\"result\":{\"aggregateFields\":{\"a0\":{\"nullValue\":null}}},\"readTime\":\"2026-10-05T12:43:42Z\",\"done\":true}]", 1);
    try testing.expectEqual(Value.null, agg.values[0]);
    for ([_][]const u8{
        "[]",
        "{\"result\":{}}",
        "[{\"result\":{\"aggregateFields\":{\"a0\":{\"integerValue\":\"1\"}}}}]",
        "[{\"result\":{\"aggregateFields\":{\"a1\":{\"integerValue\":\"1\"}}},\"readTime\":\"2026-10-05T12:43:42Z\"}]",
        "[{\"result\":{},\"readTime\":\"2026-10-05T12:43:42Z\"}]",
        "[{\"result\":{\"aggregateFields\":{\"a0\":{}}},\"readTime\":\"2026-10-05T12:43:42Z\"}]",
        "[{\"result\":{\"aggregateFields\":{\"a0\":{\"integerValue\":\"1\"}}},\"readTime\":\"2026-10-05T12:43:42Z\"},{\"result\":{\"aggregateFields\":{\"a0\":{\"integerValue\":\"1\"}}}}]",
    }) |text| try testing.expectError(error.InvalidResponse, codec.decodeAggregation(a, text, 1));
}

test "runQuery and runAggregationQuery: every allocation failure is OutOfMemory without leaks" {
    const Run = struct {
        fn run(gpa: Allocator) !void {
            var fake: test_util.FakeTransport = .init(testing.allocator, &.{
                .{ .respond = .{ .body = "[" ++ queryElement("c/a") ++ "," ++ queryElement("c/b") ++ "]" } },
                .{ .respond = .{ .body = "[{\"result\":{\"aggregateFields\":{\"a0\":{\"integerValue\":\"2\"},\"a1\":{\"doubleValue\":1.5}}},\"readTime\":\"2026-10-05T12:43:42Z\"}]" } },
            });
            defer fake.deinit();
            var clock: test_util.FakeClock = .{};
            var token: test_util.FakeTokenProvider = .{};
            var client = try Client.init(gpa, clock.io(), .{
                .project_id = "extractctl",
                .token_provider = token.provider(),
                .transport = fake.transport(),
            });
            defer client.deinit();
            const q: types.Query = .{ .from = .{ .collection = "c" }, .filter = .{ .any = &.{
                .{ .condition = .{ .field = "a", .op = .in, .value = .{ .array = &.{ .{ .integer = 1 }, .{ .string = "x" } } } } },
                .{ .condition = .{ .field = "b", .op = .equal, .value = .null } },
            } }, .order_by = &.{.{ .field = "a" }}, .start_at = .{ .values = &.{.{ .integer = 0 }} } };
            var r = try client.runQuery(q, .{});
            r.deinit();
            var agg = try client.runAggregationQuery(q, &.{ .{ .count = .{} }, .{ .avg = "a" } }, .{});
            agg.deinit();
        }
    };
    try testing.checkAllAllocationFailures(test_util.no_grow_allocator, Run.run, .{});
}
