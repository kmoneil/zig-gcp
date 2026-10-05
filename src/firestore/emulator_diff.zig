//! FakeFirestore held against the emulator: the same documents written to
//! both through the client, then hundreds of random queries and
//! aggregations, whose answers must agree, document for document. A unit
//! test that skips unless FIRESTORE_EMULATOR_HOST names an emulator; CI's
//! integration step runs it with one. FIRESTORE_DIFF_SEED replays a seed.

const std = @import("std");
const core = @import("core");

const Client = @import("Client.zig");
const Endpoint = @import("Endpoint.zig");
const FakeFirestore = @import("fake_firestore.zig").FakeFirestore;
const codec = @import("codec.zig");
const types = @import("types.zig");
const testing = std.testing;
const Value = types.Value;

const expectValueEqual = codec.expectValueEqual;

/// Values chosen to meet each other under Firestore's order and equality:
/// numbers of both kinds, NaN, the infinities, null, strings that sort
/// differently by byte and by character, arrays and maps.
const Pools = struct {
    const n = [_]?Value{ null, .null, .{ .integer = -2 }, .{ .integer = 0 }, .{ .integer = 1 }, .{ .integer = 3 }, .{ .double = 1.0 }, .{ .double = 1.5 }, .{ .double = -0.5 }, .{ .double = std.math.nan(f64) }, .{ .double = std.math.inf(f64) }, .{ .double = -std.math.inf(f64) }, .{ .string = "1" }, .{ .boolean = true } };
    const s = [_]?Value{ null, .{ .string = "a" }, .{ .string = "B" }, .{ .string = "b" }, .{ .string = "ab" }, .{ .string = "" }, .{ .string = "\u{e9}" }, .{ .string = "\u{1F600}" }, .{ .string = "\u{FF61}" } };
    const arr = [_]?Value{ null, .{ .array = &.{} }, .{ .array = &.{.{ .integer = 1 }} }, .{ .array = &.{ .{ .integer = 1 }, .{ .integer = 2 } } }, .{ .array = &.{.{ .double = 2.0 }} }, .{ .array = &.{.{ .string = "a" }} }, .{ .array = &.{.null} }, .{ .array = &.{ .{ .integer = 2 }, .{ .integer = 1 } } } };
    const m = [_]?Value{ null, .{ .map = &.{} }, .{ .map = &.{.{ .name = "k", .value = .{ .integer = 1 } }} }, .{ .map = &.{ .{ .name = "k", .value = .{ .double = 1.0 } }, .{ .name = "j", .value = .{ .integer = 2 } } } }, .{ .map = &.{.{ .name = "k", .value = .{ .string = "a" } }} }, .{ .map = &.{.{ .name = "j", .value = .null }} } };
    const values = [_]Value{ .null, .{ .integer = 0 }, .{ .integer = 1 }, .{ .integer = 2 }, .{ .double = 1.0 }, .{ .double = 1.5 }, .{ .double = std.math.nan(f64) }, .{ .string = "a" }, .{ .string = "b" }, .{ .string = "\u{e9}" }, .{ .string = "\u{1F600}" }, .{ .boolean = true }, .{ .array = &.{.{ .integer = 1 }} }, .{ .map = &.{.{ .name = "k", .value = .{ .integer = 1 } }} } };
    const fields = [_][]const u8{ "n", "s", "arr", "m", "m.k", "__name__" };
};

fn pick(r: std.Random, comptime T: type, items: []const T) T {
    return items[r.uintLessThan(usize, items.len)];
}

fn randomCondition(r: std.Random, a: std.mem.Allocator, names: []const []const u8) !types.Condition {
    const field = pick(r, []const u8, &Pools.fields);
    const op = pick(r, types.Operator, std.enums.values(types.Operator));
    const value: Value = if (std.mem.eql(u8, field, "__name__"))
        .{ .reference = pick(r, []const u8, names) }
    else switch (op) {
        .in, .not_in, .array_contains_any => list: {
            const items = try a.alloc(Value, r.intRangeAtMost(usize, 1, 3));
            for (items) |*v| v.* = pick(r, Value, &Pools.values);
            break :list .{ .array = items };
        },
        else => pick(r, Value, &Pools.values),
    };
    if (std.mem.eql(u8, field, "__name__") and (op == .in or op == .not_in)) {
        const items = try a.alloc(Value, 2);
        for (items) |*v| v.* = .{ .reference = pick(r, []const u8, names) };
        return .{ .field = field, .op = op, .value = .{ .array = items } };
    }
    return .{ .field = field, .op = op, .value = value };
}

fn randomQuery(r: std.Random, a: std.mem.Allocator, names: []const []const u8) !types.Query {
    var q: types.Query = .{ .from = if (r.uintLessThan(u8, 5) == 0) .{ .group = "d" } else .{ .collection = "d" } };
    switch (r.uintLessThan(u8, 4)) {
        0 => {},
        1, 2 => {
            const where = try a.alloc(types.Condition, r.intRangeAtMost(usize, 1, 2));
            for (where) |*c| c.* = try randomCondition(r, a, names);
            q.where = where;
        },
        else => {
            const branches = try a.alloc(types.Filter, 2);
            for (branches) |*b| b.* = .{ .condition = try randomCondition(r, a, names) };
            q.filter = if (r.boolean()) .{ .any = branches } else .{ .all = branches };
        },
    }
    const orders = try a.alloc(types.Order, r.uintLessThan(usize, 3));
    for (orders) |*o| o.* = .{ .field = pick(r, []const u8, &Pools.fields), .direction = if (r.boolean()) .ascending else .descending };
    q.order_by = orders;
    if (orders.len > 0 and r.uintLessThan(u8, 3) == 0) {
        const values = try a.alloc(Value, r.intRangeAtMost(usize, 1, orders.len));
        for (values, orders[0..values.len]) |*v, o| v.* = if (std.mem.eql(u8, o.field, "__name__")) .{ .reference = pick(r, []const u8, names) } else pick(r, Value, &Pools.values);
        const cursor: types.Cursor = .{ .values = values, .inclusive = r.boolean() };
        if (r.boolean()) q.start_at = cursor else q.end_at = cursor;
    }
    if (r.uintLessThan(u8, 3) == 0) q.limit = r.uintLessThan(u32, 6);
    if (r.uintLessThan(u8, 4) == 0) q.offset = r.uintLessThan(u32, 4);
    if (r.uintLessThan(u8, 6) == 0) q.select = if (r.boolean()) &.{} else &.{ "s", "m.k" };
    return q;
}

fn printCondition(c: types.Condition) void {
    std.debug.print("    {s} {t} {any}\n", .{ c.field, c.op, c.value });
}

fn printFilter(f: types.Filter, depth: usize) void {
    switch (f) {
        .condition => |c| printCondition(c),
        .all, .any => |fs| {
            std.debug.print("    {t} of:\n", .{f});
            for (fs) |inner| printFilter(inner, depth + 1);
        },
    }
}

fn printQuery(q: types.Query) void {
    std.debug.print("  from {any}\n", .{q.from});
    for (q.where) |c| printCondition(c);
    if (q.filter) |f| printFilter(f, 0);
    for (q.order_by) |o| std.debug.print("  order {s} {t}\n", .{ o.field, o.direction });
    std.debug.print("  start {any} end {any} offset {d} limit {any} select {any}\n", .{ q.start_at, q.end_at, q.offset, q.limit, q.select });
}

test "emulator differential: the fake answers random queries as the emulator does" {
    const gpa = testing.allocator;
    var env = try testing.environ.createMap(gpa);
    defer env.deinit();
    const endpoint = Endpoint.fromEnv(&env) orelse return error.SkipZigTest;
    // The seeds that first found the rules the fake now models, unless
    // FIRESTORE_DIFF_SEED names one to replay.
    const seeds: []const u64 = &.{ 0x5eed_f00d, 1, 5, 7, 11 };
    if (env.get("FIRESTORE_DIFF_SEED")) |text| {
        try differential(gpa, endpoint, try std.fmt.parseInt(u64, text, 0));
    } else for (seeds) |seed| try differential(gpa, endpoint, seed);
}

/// One run: a project of its own on the emulator, a fake of its own, the
/// same documents in both, and 400 random queries with aggregations.
fn differential(gpa: std.mem.Allocator, endpoint: Endpoint, seed: u64) !void {
    var project_buf: [14]u8 = undefined;
    var random_id: [4]u8 = undefined;
    testing.io.random(&random_id);
    const project = try std.fmt.bufPrint(&project_buf, "zigps-{x}", .{random_id});
    var diag: core.Diagnostics = .{};
    var emulator: Client = try .init(gpa, testing.io, .{ .project_id = project, .endpoint = endpoint, .diagnostics = &diag });
    defer emulator.deinit();
    defer clearProject(&emulator, project);
    var fake: FakeFirestore = .init(gpa);
    defer fake.deinit();
    var token: core.StaticToken = .{ .token = "fake" };
    var fake_diag: core.Diagnostics = .{};
    var other: Client = try .init(gpa, testing.io, .{
        .project_id = project,
        .token_provider = token.provider(),
        .transport = fake.transport(),
        .diagnostics = &fake_diag,
    });
    defer other.deinit();

    var prng: std.Random.DefaultPrng = .init(seed);
    const r = prng.random();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // The same documents in both: some in d at the root, some in d below
    // other documents, for the group queries.
    var full_names: std.ArrayList([]const u8) = .empty;
    for (0..40) |i| {
        const path = if (i % 8 == 7) try std.fmt.allocPrint(a, "p/{d}/d/x{d:0>2}", .{ i % 3, i }) else try std.fmt.allocPrint(a, "d/x{d:0>2}", .{i});
        var fields: std.ArrayList(types.Field) = .empty;
        inline for (.{ .{ "n", &Pools.n }, .{ "s", &Pools.s }, .{ "arr", &Pools.arr }, .{ "m", &Pools.m } }) |pool| {
            if (pick(r, ?Value, pool[1])) |v| try fields.append(a, .{ .name = pool[0], .value = v });
        }
        _ = try emulator.doc(path).set(fields.items, .{});
        _ = try other.doc(path).set(fields.items, .{});
        try full_names.append(a, try emulator.documentName(a, path));
    }

    var compared: usize = 0;
    var both_refused: usize = 0;
    for (0..400) |i| {
        const q = try randomQuery(r, a, full_names.items);
        var want = emulator.runQuery(q, .{});
        var got = other.runQuery(q, .{});
        defer if (want) |*w| w.deinit() else |_| {};
        defer if (got) |*g| g.deinit() else |_| {};
        if (want) |w| {
            const g = got catch |err| {
                std.debug.print("seed {x}, query {d}: emulator answered, fake refused with {t}: {s}\n", .{ seed, i, err, fake_diag.message() });
                printQuery(q);
                return error.TestFakeDiffers;
            };
            var same = w.value.documents.len == g.value.documents.len;
            if (same) for (w.value.documents, g.value.documents) |x, y| {
                if (!std.mem.eql(u8, x.path(), y.path()) or x.fields.len != y.fields.len) same = false;
            };
            if (!same) {
                std.debug.print("seed {x}, query {d}: results differ\n  emulator:", .{ seed, i });
                for (w.value.documents) |d| std.debug.print(" {s}", .{d.path()});
                std.debug.print("\n  fake:    ", .{});
                for (g.value.documents) |d| std.debug.print(" {s}", .{d.path()});
                std.debug.print("\n", .{});
                printQuery(q);
                return error.TestFakeDiffers;
            }
            compared += 1;
        } else |want_err| {
            const got_err: ?anyerror = if (got) |_| null else |e| e;
            if (got_err == null or got_err.? != @as(anyerror, want_err)) {
                std.debug.print("seed {x}, query {d}: emulator refused with {t} ({s}), fake answered {any} ({s})\n", .{ seed, i, want_err, diag.message(), got_err, fake_diag.message() });
                printQuery(q);
                return error.TestFakeDiffers;
            }
            both_refused += 1;
        }

        // The same query aggregated.
        const aggs = try a.alloc(types.Aggregation, r.intRangeAtMost(usize, 1, 3));
        for (aggs) |*agg| agg.* = switch (r.uintLessThan(u8, 3)) {
            0 => .{ .count = .{ .up_to = if (r.boolean()) r.uintLessThan(u63, 5) else null } },
            1 => .{ .sum = pick(r, []const u8, &.{ "n", "m.k" }) },
            else => .{ .avg = pick(r, []const u8, &.{ "n", "m.k" }) },
        };
        var want_agg = emulator.runAggregationQuery(q, aggs, .{});
        var got_agg = other.runAggregationQuery(q, aggs, .{});
        defer if (want_agg) |*w| w.deinit() else |_| {};
        defer if (got_agg) |*g| g.deinit() else |_| {};
        if (want_agg) |w| {
            const g = got_agg catch |err| {
                std.debug.print("seed {x}, aggregation {d}: fake refused with {t}: {s}\n", .{ seed, i, err, fake_diag.message() });
                printQuery(q);
                return error.TestFakeDiffers;
            };
            for (w.value.values, g.value.values, aggs) |x, y, agg| expectValueEqual(x, y) catch {
                std.debug.print("seed {x}, aggregation {d} {any}: emulator {any}, fake {any}\n", .{ seed, i, agg, x, y });
                printQuery(q);
                return error.TestFakeDiffers;
            };
        } else |want_err| {
            const got_err: ?anyerror = if (got_agg) |_| null else |e| e;
            if (got_err == null or got_err.? != @as(anyerror, want_err)) {
                std.debug.print("seed {x}, aggregation {d}: emulator refused with {t} ({s}), fake answered {any} ({s})\n", .{ seed, i, want_err, diag.message(), got_err, fake_diag.message() });
                printQuery(q);
                return error.TestFakeDiffers;
            }
        }
    }
    // Most queries must reach both servers, or this proves little.
    try testing.expect(compared > 200);
    std.debug.print("seed {x}: {d} queries answered alike, {d} refused alike\n", .{ seed, compared, both_refused });
}

/// Empties the test's project through the emulator's documented endpoint.
fn clearProject(client: *Client, project: []const u8) void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const url = std.fmt.allocPrint(arena.allocator(), "{s}/emulator/v1/projects/{s}/databases/(default)/documents", .{ client.base_url, project }) catch return;
    _ = client.transport.send(.{ .method = .DELETE, .url = url, .timeout_ms = 10_000 }, arena.allocator()) catch {};
}
