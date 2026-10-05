//! Integration tests against real Firestore: what the emulator cannot be
//! trusted on, and the facts milestone 5 of the spec measures. They need a
//! project, a token, and a named database made for them:
//!
//!     gcloud --configuration=extractctl services enable firestore.googleapis.com
//!     gcloud --configuration=extractctl firestore databases create \
//!         --database=zigps-fs-$(openssl rand -hex 4) --location=us-central1
//!     GCP_TEST_PROJECT=extractctl FIRESTORE_TEST_DATABASE=zigps-fs-... \
//!     GCP_TEST_TOKEN=$(gcloud auth print-access-token) \
//!     zig build test-integration-gcp
//!     gcloud --configuration=extractctl firestore databases delete --database=zigps-fs-...
//!
//! Without all three variables every test skips. The suite never touches
//! `(default)`, and refuses to run against it. Firestore's free quota
//! covers exactly one database per project, the first one made, whatever
//! its id: one throwaway database at a time, in a project with no other,
//! keeps a run free. A deleted database's id cannot be used again for
//! about 5 minutes, so each run makes a new one.
//!
//! Each test keeps its documents under a collection of its own,
//! `zigps-` and random hex, and deletes them when it ends. Facts the
//! suite measures rather than asserts are printed, `fact: ...`, for the
//! spec.

const std = @import("std");
const core = @import("core");
const firestore = @import("firestore");
const testing = std.testing;
const Value = firestore.Value;

const Fixture = struct {
    env: std.process.Environ.Map,
    token: core.StaticToken,
    diag: firestore.Diagnostics,
    client: firestore.Client,
    /// "zigps-" plus 8 random hex digits: the test's collection.
    collection: [14]u8,

    fn init(f: *Fixture) !bool {
        const gpa = testing.allocator;
        f.env = try testing.environ.createMap(gpa);
        errdefer f.env.deinit();
        const project = f.env.get("GCP_TEST_PROJECT") orelse return f.skip();
        const token = f.env.get("GCP_TEST_TOKEN") orelse return f.skip();
        const database = f.env.get("FIRESTORE_TEST_DATABASE") orelse return f.skip();
        if (std.mem.eql(u8, database, "(default)")) return error.RefusedDefaultDatabase;
        f.token = .{ .token = std.mem.trim(u8, token, &std.ascii.whitespace) };
        f.diag = .{};
        var random: [4]u8 = undefined;
        testing.io.random(&random);
        _ = try std.fmt.bufPrint(&f.collection, "zigps-{x}", .{random});
        f.client = try .init(gpa, testing.io, .{
            .project_id = project,
            .database_id = database,
            .token_provider = f.token.provider(),
            .diagnostics = &f.diag,
            .user_agent = "zig-gcp-firestore-gcp-integration/0.1",
        });
        return true;
    }

    fn skip(f: *Fixture) bool {
        f.env.deinit();
        return false;
    }

    /// Deletes every document in the test's collection and below it.
    fn deinit(f: *Fixture) void {
        var group_buf: [14]u8 = f.collection;
        // Subcollections of the test's documents are named after it too.
        var r = f.client.runQuery(.{ .from = .{ .group = &group_buf } }, .{}) catch null;
        if (r) |*page| {
            defer page.deinit();
            for (page.value.documents) |d| f.client.doc(d.path()).delete(.{}) catch {};
        }
        var direct = f.client.runQuery(.{ .from = .{ .collection = &f.collection }, .select = &.{} }, .{}) catch null;
        if (direct) |*page| {
            defer page.deinit();
            for (page.value.documents) |d| f.client.doc(d.path()).delete(.{}) catch {};
        }
        f.client.deinit();
        f.env.deinit();
    }

    /// `<collection>/<id>`, in `buf`.
    fn path(f: *const Fixture, buf: []u8, id: []const u8) []const u8 {
        return std.fmt.bufPrint(buf, "{s}/{s}", .{ &f.collection, id }) catch unreachable;
    }

    /// Sends a request by hand, for what the library never sends, and
    /// returns its status and body, in `arena`.
    fn raw(f: *Fixture, arena: std.mem.Allocator, method: core.transport.Method, suffix: []const u8, body: ?[]const u8) !core.transport.Response {
        const url = try std.fmt.allocPrint(arena, "{s}/v1/projects/{s}/databases/{s}/documents{s}", .{ f.client.base_url, f.client.project_id, f.client.database_id, suffix });
        const bearer = try f.client.token_provider.getToken(testing.io, arena, &.{firestore.auth_scope});
        return f.client.transport.send(.{ .method = method, .url = url, .bearer = bearer, .body = body, .timeout_ms = 20_000 }, arena);
    }
};

fn fact(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("fact: " ++ fmt ++ "\n", args);
}

test "documents: every kind of value, preconditions, and the server's words" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    var buf: [64]u8 = undefined;
    const path = f.path(&buf, "a");
    const nan = std.math.nan(f64);
    const fields: []const firestore.Field = &.{
        .{ .name = "null", .value = .null },
        .{ .name = "max", .value = .{ .integer = std.math.maxInt(i64) } },
        .{ .name = "nan", .value = .{ .double = nan } },
        .{ .name = "negzero", .value = .{ .double = -0.0 } },
        .{ .name = "ts", .value = .{ .timestamp = .{ .nanoseconds = 1_791_153_779_123_456_789 } } },
        .{ .name = "bytes", .value = .{ .bytes = "\x00\xff" } },
        .{ .name = "geo", .value = .{ .geo_point = .{ .latitude = 0, .longitude = -118.25 } } },
        .{ .name = "a-b", .value = .{ .map = &.{.{ .name = "c`d", .value = .{ .array = &.{ .{ .integer = 1 }, .{ .string = "two" } } } }} } },
    };
    const written = try f.client.doc(path).set(fields, .{});
    var got = try f.client.doc(path).get(.{});
    defer got.deinit();
    try testing.expectEqual(std.math.maxInt(i64), got.value.get("max").?.integer);
    try testing.expect(std.math.isNan(got.value.get("nan").?.double));
    fact("timestamp .123456789 stored as {d} ns past the second", .{@mod(got.value.get("ts").?.timestamp.nanoseconds, std.time.ns_per_s)});
    fact("-0.0 comes back with its sign: {}", .{std.math.signbit(got.value.get("negzero").?.double)});
    try testing.expectEqual(written.update_time, got.value.update_time);

    // Preconditions, and production's words for each refusal.
    try testing.expectError(error.FailedPrecondition, f.client.doc(path).update(&.{.{ .name = "x", .value = .null }}, .{ .precondition = .{ .update_time = .{ .nanoseconds = written.update_time.nanoseconds - 1000 } } }));
    fact("stale update time: {s}", .{f.diag.message()});
    try testing.expectError(error.AlreadyExists, f.client.doc(path).set(&.{}, .{ .precondition = .{ .exists = false } }));
    fact("exists=false on an existing document: {s}", .{f.diag.message()});
    var missing_buf: [64]u8 = undefined;
    const missing = f.path(&missing_buf, "missing");
    try testing.expectError(error.NotFound, f.client.doc(missing).update(&.{.{ .name = "x", .value = .null }}, .{}));
    fact("update of a missing document: {s}", .{f.diag.message()});
    try testing.expectError(error.NotFound, f.client.doc(missing).get(.{}));
    fact("get of a missing document: {s}", .{f.diag.message()});
    var col_buf: [32]u8 = undefined;
    try testing.expectError(error.AlreadyExists, f.client.collection(std.fmt.bufPrint(&col_buf, "{s}", .{&f.collection}) catch unreachable).create(&.{}, .{ .document_id = "a" }));
    fact("create of an existing id: {s}", .{f.diag.message()});
    _ = try f.client.doc(path).update(&.{}, .{ .precondition = .{ .update_time = written.update_time }, .mask = &.{"null"} });
}

test "facts: timestamps as query parameters, the field path limit, colons, references, masks" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var buf: [64]u8 = undefined;
    const path = f.path(&buf, "q");
    const written = try f.client.doc(path).set(&.{.{ .name = "v", .value = .{ .integer = 1 } }}, .{});
    var ts_buf: [core.timestamp.max_len]u8 = undefined;
    const ts = core.timestamp.format(&ts_buf, written.update_time);

    // The emulator reads a timestamp query parameter as 0; production?
    const patch = try f.raw(a, .PATCH, try std.fmt.allocPrint(a, "/{s}?currentDocument.updateTime={s}&updateMask.fieldPaths=v", .{ path, ts }), "{\"fields\":{\"v\":{\"integerValue\":\"2\"}}}");
    fact("PATCH under an exact updateTime query parameter: {d} {s}", .{ patch.status, patch.body[0..@min(patch.body.len, 200)] });
    const get = try f.raw(a, .GET, try std.fmt.allocPrint(a, "/{s}?readTime={s}", .{ path, ts }), null);
    fact("GET with a readTime query parameter: {d} {s}", .{ get.status, get.body[0..@min(get.body.len, 160)] });

    // A field path of exactly 1,500 bytes, which the emulator refused.
    const long = core.testing.repeat("k", 1500);
    const masked = f.client.doc(path).update(&.{}, .{ .mask = &.{long}, .precondition = null });
    fact("an update mask path of 1,500 bytes: {s} {s}", .{ if (masked) |_| "taken" else |err| @errorName(err), f.diag.message() });

    // A document id holding a colon, and listing below it.
    var colon_buf: [64]u8 = undefined;
    const colon = f.path(&colon_buf, "a:b");
    var sub_buf: [96]u8 = undefined;
    _ = try f.client.doc(std.fmt.bufPrint(&sub_buf, "{s}/sub/x", .{colon}) catch unreachable).set(&.{}, .{});
    const listed = f.client.doc(colon).listCollectionIds(.{});
    fact("listCollectionIds below an id holding ':': {s} {s}", .{ if (listed) |_| "answered" else |err| @errorName(err), f.diag.message() });
    if (listed) |l| {
        var l2 = l;
        l2.deinit();
    } else |_| {}

    // References to another database and another project.
    const other_db = f.client.doc(path).set(&.{.{ .name = "r", .value = .{ .reference = "projects/p/databases/other/documents/c/x" } }}, .{});
    fact("a reference to another project's database: {s} {s}", .{ if (other_db) |_| "taken" else |err| @errorName(err), f.diag.message() });

    // Overlapping mask paths, which Google's clients refuse, sent raw.
    const overlap = try f.raw(a, .POST, ":commit", try std.fmt.allocPrint(a, "{{\"writes\":[{{\"update\":{{\"name\":\"projects/{s}/databases/{s}/documents/{s}\",\"fields\":{{\"m\":{{\"mapValue\":{{\"fields\":{{\"b\":{{\"integerValue\":\"2\"}}}}}}}}}}}},\"updateMask\":{{\"fieldPaths\":[\"m\",\"m.b\"]}}}}]}}", .{ f.client.project_id, f.client.database_id, path }));
    fact("overlapping update mask paths: {d} {s}", .{ overlap.status, overlap.body[0..@min(overlap.body.len, 160)] });

    // 501 transforms on one document, which the emulator took.
    var transforms: std.ArrayList(u8) = .empty;
    for (0..501) |i| {
        if (i > 0) try transforms.append(a, ',');
        try transforms.print(a, "{{\"fieldPath\":\"f{d}\",\"increment\":{{\"integerValue\":\"1\"}}}}", .{i});
    }
    const many = try f.raw(a, .POST, ":commit", try std.fmt.allocPrint(a, "{{\"writes\":[{{\"update\":{{\"name\":\"projects/{s}/databases/{s}/documents/{s}\",\"fields\":{{}}}},\"updateMask\":{{\"fieldPaths\":[]}},\"updateTransforms\":[{s}]}}]}}", .{ f.client.project_id, f.client.database_id, path, transforms.items }));
    fact("501 transforms on one document: {d} {s}", .{ many.status, many.body[0..@min(many.body.len, 160)] });
}

test "facts: queries, framing, null equality, key scans, and the aggregation rule" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]struct { []const u8, Value }{
        .{ "n", .null },
        .{ "nan", .{ .double = std.math.nan(f64) } },
        .{ "one", .{ .integer = 1 } },
        .{ "two", .{ .double = 2.0 } },
    }) |d| {
        var buf: [64]u8 = undefined;
        _ = try f.client.doc(f.path(&buf, d[0])).set(&.{.{ .name = "x", .value = d[1] }}, .{});
    }
    var buf: [64]u8 = undefined;
    _ = try f.client.doc(f.path(&buf, "none")).set(&.{.{ .name = "y", .value = .{ .integer = 5 } }}, .{});
    const from = try std.fmt.allocPrint(a, "{{\"from\":[{{\"collectionId\":\"{s}\"}}]", .{&f.collection});

    // Framing, with an offset: does production send skippedResults?
    const framed = try f.raw(a, .POST, ":runQuery", try std.fmt.allocPrint(a, "{{\"structuredQuery\":{s},\"offset\":2}}}}", .{from}));
    fact("runQuery with offset 2, raw: {s}", .{framed.body[0..@min(framed.body.len, 400)]});
    var skipped = try f.client.runQuery(.{ .from = .{ .collection = &f.collection }, .offset = 2 }, .{});
    defer skipped.deinit();
    fact("skipped_results with offset 2: {d}", .{skipped.value.skipped_results});

    // EQUAL with null and NaN as field filters, raw.
    for ([_][]const u8{ "{\"nullValue\":null}", "{\"doubleValue\":\"NaN\"}" }) |v| {
        const r = try f.raw(a, .POST, ":runQuery", try std.fmt.allocPrint(a, "{{\"structuredQuery\":{s},\"where\":{{\"fieldFilter\":{{\"field\":{{\"fieldPath\":\"x\"}},\"op\":\"EQUAL\",\"value\":{s}}}}}}}}}", .{ from, v }));
        fact("EQUAL {s} as a field filter: {d} documents in {s}", .{ v, std.mem.count(u8, r.body, "\"document\""), r.body[0..@min(r.body.len, 120)] });
    }
    // The library's unary forms find them.
    var nulls = try f.client.runQuery(.{ .from = .{ .collection = &f.collection }, .where = &.{.{ .field = "x", .op = .equal, .value = .null }} }, .{});
    defer nulls.deinit();
    try testing.expectEqual(1, nulls.value.documents.len);

    // A descending order by name alone, which the emulator calls a key
    // scan, needs an index in production: FAILED_PRECONDITION, sent inside
    // the streamed answer's array, which core reads.
    try testing.expectError(error.FailedPrecondition, f.client.runQuery(.{ .from = .{ .collection = &f.collection }, .order_by = &.{.{ .field = "__name__", .direction = .descending }} }, .{}));
    try testing.expect(std.mem.indexOf(u8, f.diag.message(), "requires an index") != null);

    // A sum narrows the count to documents holding the field, in
    // production as on the emulator.
    var agg = try f.client.runAggregationQuery(.{ .from = .{ .collection = &f.collection } }, &.{ .{ .count = .{} }, .{ .sum = "x" } }, .{});
    defer agg.deinit();
    var alone = try f.client.runAggregationQuery(.{ .from = .{ .collection = &f.collection } }, &.{.{ .count = .{} }}, .{});
    defer alone.deinit();
    try testing.expectEqual(4, agg.value.values[0].integer);
    try testing.expectEqual(5, alone.value.values[0].integer);
}

/// Increments a counter in a transaction, `times` times.
const Incrementer = struct {
    client: firestore.Client,
    path: []const u8,
    runs: u32 = 0,

    fn run(ptr: *anyopaque, txn: *firestore.Transaction) anyerror!void {
        const self: *Incrementer = @ptrCast(@alignCast(ptr));
        self.runs += 1;
        var got = try txn.get(self.path, .{});
        defer got.deinit();
        try txn.update(self.path, &.{.{ .name = "n", .value = .{ .integer = got.value.get("n").?.integer + 1 } }}, .{});
    }

    fn loop(self: *Incrementer, times: u32) anyerror!void {
        for (0..times) |_| try self.client.runTransaction(.{ .ptr = self, .vtable = &.{ .run = run } }, .{ .max_attempts = 20 });
    }
};

test "transactions: concurrent increments against production, and the contention they meet" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    var buf: [64]u8 = undefined;
    const path = f.path(&buf, "counter");
    _ = try f.client.doc(path).set(&.{.{ .name = "n", .value = .{ .integer = 0 } }}, .{});
    var workers: [3]Incrementer = undefined;
    for (&workers) |*w| w.* = .{ .path = path, .client = try .init(testing.allocator, testing.io, .{
        .project_id = f.client.project_id,
        .database_id = f.client.database_id,
        .token_provider = f.token.provider(),
    }) };
    defer for (&workers) |*w| w.client.deinit();
    var futures: [3]std.Io.Future(anyerror!void) = undefined;
    for (&workers, &futures) |*w, *fut| fut.* = try testing.io.concurrent(Incrementer.loop, .{ w, 3 });
    var failure: ?anyerror = null;
    for (&futures) |*fut| fut.await(testing.io) catch |err| {
        failure = err;
    };
    if (failure) |err| return err;
    var got = try f.client.doc(path).get(.{});
    defer got.deinit();
    try testing.expectEqual(9, got.value.get("n").?.integer);
    var runs: u32 = 0;
    for (workers) |w| runs += w.runs;
    fact("9 transactional increments from 3 tasks took {d} runs", .{runs});

    // REQUEST_TIME precision.
    var r = try f.client.commit(&.{.{ .update = .{ .path = path, .mask = &.{}, .transforms = &.{.{ .field_path = "at", .op = .server_time }} } }}, .{});
    defer r.deinit();
    fact("server time: {d} ns past the second", .{@mod(r.value.writes[0].transform_results[0].timestamp.nanoseconds, std.time.ns_per_s)});
}
