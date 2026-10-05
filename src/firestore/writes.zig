//! Writes: the checks every write gets before it is sent, how a list of
//! them becomes one commit, and which commits may be sent again after a
//! lost answer.
//!
//! A write without transforms is retried: writing the same fields again
//! leaves what a reader sees as it was, and the call was still running
//! when any other writer's change landed. A write with transforms is
//! retried only under a precondition a repeat fails (an update time, or
//! `exists == false`), since an increment sent twice counts twice; or
//! when `Client.Options.retry_unconditional_writes` says so. A commit
//! retries only when every write in it may.

const std = @import("std");
const Allocator = std.mem.Allocator;
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

/// Commits `writes`, in order and atomically, and returns what each did,
/// decoded into `response`. The call has begun.
pub fn commit(client: *Client, writes: []const types.Write, response: *std.heap.ArenaAllocator) Error!types.CommitResult {
    if (writes.len == 0) return rpc.refuse(client, error.InvalidArgument, "a commit needs at least one write", .{});
    var scratch: std.heap.ArenaAllocator = .init(client.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const wire = try a.alloc(codec.Write, writes.len);
    for (writes, wire, 0..) |w, *out, i| {
        out.* = resolve(client, a, w) catch |err| {
            if (writes.len > 1) prefixDiagnostics(client, i);
            return err;
        };
    }
    try checkTransformCounts(client, a, wire);
    const url = rpc.commitPath(a, client) catch return error.OutOfMemory;
    const body = try codec.encodeCommit(a, wire);
    const retried = client.retry_unconditional_writes or for (wire) |w| {
        if (!safeToRepeat(w)) break false;
    } else true;
    const reply = rpc.execute(client, response, .{ .method = .POST, .path = url, .body = body, .retry = retried }) catch |err| {
        noteFailure(client, err, wire, retried);
        return err;
    };
    const result = codec.decodeCommit(response.allocator(), reply) catch |err|
        return rpc.decodeFailed(client, err, "commit");
    if (result.writes.len != wire.len) return rpc.decodeFailed(client, error.InvalidResponse, "commit");
    for (result.writes, wire) |r, w| {
        if (r.transform_results.len != w.transformCount()) return rpc.decodeFailed(client, error.InvalidResponse, "commit");
    }
    // A commit of writes always carries its time; decodeCommit says so.
    return .{ .writes = result.writes, .commit_time = result.commit_time.? };
}

/// Whether sending `w` again after a lost answer is safe; see the top of
/// this file.
pub fn safeToRepeat(w: codec.Write) bool {
    if (w.transformCount() == 0) return true;
    const p = w.precondition orelse return false;
    return switch (p) {
        .exists => |e| !e,
        .update_time => true,
    };
}

/// Checks one write as the server would, and gives it its full name.
fn resolve(client: *Client, a: Allocator, w: types.Write) Error!codec.Write {
    switch (w) {
        .update => |u| {
            const path = try rpc.checkedPath(client, a, .init(u.path), .document);
            try rpc.checkFields(client, u.fields);
            if (u.mask) |mask| try checkUpdateMask(client, mask, u.fields);
            try checkTransforms(client, u.transforms);
            try rpc.checkPrecondition(client, u.precondition);
            return .{
                .name = try client.documentName(a, path),
                .op = .{ .update = .{ .fields = u.fields, .mask = u.mask, .transforms = u.transforms } },
                .precondition = u.precondition,
            };
        },
        .delete => |d| {
            const path = try rpc.checkedPath(client, a, .init(d.path), .document);
            try rpc.checkPrecondition(client, d.precondition);
            return .{ .name = try client.documentName(a, path), .op = .delete, .precondition = d.precondition };
        },
    }
}

/// An update mask's paths: the grammar, no two overlapping, and every
/// value in `fields` under one of them.
pub fn checkUpdateMask(client: *Client, mask: []const []const u8, fields: []const types.Field) Error!void {
    try rpc.checkMask(client, mask, "update mask");
    for (mask, 0..) |p, i| for (mask[0..i]) |q| {
        if (names.fieldPathsOverlap(p, q)) return rpc.refuse(client, error.InvalidArgument, "the update mask paths {s} and {s} overlap", .{ q, p });
    };
    var where_buf: [160]u8 = undefined;
    if (uncovered(mask, fields, &where_buf)) |where| {
        return rpc.refuse(client, error.InvalidArgument, "the field {s} is outside the update mask, so it would not be written", .{where});
    }
}

/// Transforms as the server takes them: valid paths, not the document's
/// name, no path inside another's (measured: "Cannot transform property m
/// and its nested property at the same time."), and array values that
/// hold no arrays.
pub fn checkTransforms(client: *Client, transforms: []const types.Transform) Error!void {
    for (transforms, 0..) |t, i| {
        if (names.fieldPathProblem(t.field_path)) |problem| {
            return rpc.refuse(client, error.InvalidResourceId, "invalid field path in a transform: {s}", .{problem});
        }
        // The emulator takes it, and makes a field of that name.
        if (std.mem.eql(u8, t.field_path, "__name__")) {
            return rpc.refuse(client, error.InvalidArgument, "a transform cannot change __name__, the document's name", .{});
        }
        for (transforms[0..i]) |earlier| {
            if (names.fieldPathsOverlap(earlier.field_path, t.field_path) and !names.fieldPathsEqual(earlier.field_path, t.field_path)) {
                return rpc.refuse(client, error.InvalidArgument, "the transforms of {s} and {s} overlap: Firestore refuses a field and one inside it", .{ earlier.field_path, t.field_path });
            }
        }
        switch (t.op) {
            .append_missing, .remove_all => |values| {
                var where_buf: [160]u8 = undefined;
                if (validate.arrayElementsProblem(values, &where_buf)) |problem| {
                    return rpc.refuse(client, error.InvalidArgument, "invalid value in the transform of {s}: {s}", .{ t.field_path, problem.what });
                }
            },
            else => {},
        }
    }
}

/// At most 500 transforms per document in one commit.
fn checkTransformCounts(client: *Client, a: Allocator, wire: []const codec.Write) Error!void {
    var counts: std.StringHashMapUnmanaged(usize) = .empty;
    for (wire) |w| {
        const n = w.transformCount();
        if (n == 0) continue;
        const entry = try counts.getOrPut(a, w.name);
        if (!entry.found_existing) entry.value_ptr.* = 0;
        entry.value_ptr.* += n;
        if (entry.value_ptr.* > validate.max_transforms_per_document) {
            return rpc.refuse(client, error.InvalidArgument, "over 500 transforms for one document in one commit", .{});
        }
    }
}

/// Says in the diagnostics what a failed commit leaves open.
fn noteFailure(client: *Client, err: anyerror, wire: []const codec.Write, retried: bool) void {
    if (client.retry.max_attempts <= 1) return;
    if (retried) {
        for (wire) |w| if (rpc.meetsOwnWrite(err, w.precondition)) return rpc.appendNote(client, rpc.retried_note);
    } else if (core.isRetryable(err)) {
        rpc.appendNote(client, "; not retried, since a transform sent twice applies twice: the write may or may not have landed, so read the document to see, or hold the write to an update time or exists == false, or set Client.Options.retry_unconditional_writes");
    }
}

/// Names the write a refusal is about, in a commit of several.
fn prefixDiagnostics(client: *Client, index: usize) void {
    const d = client.diagnostics orelse return;
    var buf: [600]u8 = undefined;
    const message = std.fmt.bufPrint(&buf, "write {d}: {s}", .{ index, d.message() }) catch return;
    d.print("{s}", .{message});
}

/// How a mask path relates to the field at a path of names.
const Relation = enum {
    /// The mask path is the field's path or a map above it: the field is
    /// written.
    covers,
    /// The mask path names a field inside this one.
    inside,
    unrelated,
};

fn relation(mask_path: []const u8, field_names: []const []const u8) Relation {
    var it: names.FieldPathIterator = .init(mask_path);
    for (field_names) |name| {
        // Checked already, so the path parses.
        const segment = (it.next() catch return .unrelated) orelse return .covers;
        if (!segment.eql(name)) return .unrelated;
    }
    return if ((it.next() catch null) == null) .covers else .inside;
}

/// The path of a value in `fields` that no mask path writes, quoted, into
/// `where_buf`; null when every value is written.
pub fn uncovered(mask: []const []const u8, fields: []const types.Field, where_buf: []u8) ?[]const u8 {
    var stack: [validate.max_value_depth + 1][]const u8 = undefined;
    const depth = uncoveredBelow(mask, fields, &stack, 0) orelse return null;
    var w: Writer = .fixed(where_buf);
    for (stack[0..depth], 0..) |name, i| {
        if (i > 0) w.writeByte('.') catch break;
        names.writeFieldSegment(&w, name) catch break;
    }
    return w.buffered();
}

/// The depth of the first unwritten value's path, left in `stack`.
fn uncoveredBelow(mask: []const []const u8, fields: []const types.Field, stack: [][]const u8, depth: usize) ?usize {
    for (fields) |f| {
        stack[depth] = f.name;
        const path = stack[0 .. depth + 1];
        var inside = false;
        for (mask) |m| switch (relation(m, path)) {
            .covers => break,
            .inside => inside = true,
            .unrelated => {},
        } else {
            // Nothing writes it whole; a mask path inside it writes part of
            // it, and only a map has parts. The fields were checked, so the
            // nesting fits the stack.
            if (!inside or f.value != .map or depth + 1 >= stack.len) return depth + 1;
            if (uncoveredBelow(mask, f.value.map, stack, depth + 1)) |d| return d;
        }
    }
    return null;
}

const testing = std.testing;
const test_util = @import("test_util.zig");
const commit_url = test_util.base ++ ":commit";
const unavailable: test_util.FakeTransport.Reply = .{ .respond = .{ .status = 503, .body = "{\"error\":{\"code\":503,\"message\":\"unavailable\",\"status\":\"UNAVAILABLE\"}}" } };

test "golden: a commit of every transform, a delete, and what it answers" {
    var h: test_util.Harness = undefined;
    try h.init(&.{.{ .respond = .{ .body =
        \\{"writeResults": [{"updateTime": "2026-10-05T12:15:13.233173Z", "transformResults": [{"timestampValue": "2026-10-05T12:15:13.232Z"}, {"integerValue": "6"}, {"doubleValue": 7.5}, {"integerValue": "1"}, {"nullValue": null}, {"nullValue": null}]}, {}],
        \\ "commitTime": "2026-10-05T12:15:13.233173Z"}
    } }}, .{});
    defer h.deinit();
    var result = try h.client.commit(&.{
        .{ .update = .{
            .path = "cities/LA",
            .fields = &.{.{ .name = "nickname", .value = .{ .string = "LA" } }},
            .mask = &.{"nickname"},
            .transforms = &.{
                .{ .field_path = "updated", .op = .server_time },
                .{ .field_path = "visits", .op = .{ .increment = .{ .integer = 1 } } },
                .{ .field_path = "stats.`max-temp`", .op = .{ .maximum = .{ .double = 7.5 } } },
                .{ .field_path = "low", .op = .{ .minimum = .{ .integer = 1 } } },
                .{ .field_path = "tags", .op = .{ .append_missing = &.{ .{ .string = "big" }, .{ .integer = 3 } } } },
                .{ .field_path = "old", .op = .{ .remove_all = &.{.null} } },
            },
        } },
        .{ .delete = .{ .path = "cities/SF", .precondition = .{ .exists = true } } },
    }, .{});
    defer result.deinit();
    try h.expectRequest(0, .POST, commit_url,
        \\{"writes":[{"update":{"name":"projects/extractctl/databases/(default)/documents/cities/LA","fields":{"nickname":{"stringValue":"LA"}}},"updateMask":{"fieldPaths":["nickname"]},"updateTransforms":[
    ++
        \\{"fieldPath":"updated","setToServerValue":"REQUEST_TIME"},{"fieldPath":"visits","increment":{"integerValue":"1"}},{"fieldPath":"stats.`max-temp`","maximum":{"doubleValue":7.5}},{"fieldPath":"low","minimum":{"integerValue":"1"}},
    ++
        \\{"fieldPath":"tags","appendMissingElements":{"values":[{"stringValue":"big"},{"integerValue":"3"}]}},{"fieldPath":"old","removeAllFromArray":{"values":[{"nullValue":"NULL_VALUE"}]}}]},
    ++
        \\{"delete":"projects/extractctl/databases/(default)/documents/cities/SF","currentDocument":{"exists":true}}]}
    );
    try testing.expectEqual(2, result.value.writes.len);
    const r = result.value.writes[0];
    try testing.expectEqual(6, r.transform_results.len);
    try testing.expectEqual(1_791_202_513_232_000_000, r.transform_results[0].timestamp.nanoseconds);
    try testing.expectEqual(6, r.transform_results[1].integer);
    try testing.expectEqual(7.5, r.transform_results[2].double);
    try testing.expectEqual(types.Value.null, r.transform_results[4]);
    try testing.expectEqual(null, result.value.writes[1].update_time);
    try testing.expectEqual(1_791_202_513_233_173_000, result.value.commit_time.nanoseconds);
    // Transforms with nothing else: the empty mask goes too, or the update
    // would replace the document with no fields first.
}

test "golden: transforms alone, through Document.update, send an empty mask" {
    var h: test_util.Harness = undefined;
    try h.init(&.{.{ .respond = .{ .body = "{\"writeResults\":[{\"updateTime\":\"2026-10-04T22:42:59.269778Z\",\"transformResults\":[{\"integerValue\":\"2\"}]}],\"commitTime\":\"2026-10-04T22:42:59.269778Z\"}" } }}, .{});
    defer h.deinit();
    const written = try h.client.doc("cities/LA").update(&.{}, .{ .transforms = &.{.{ .field_path = "visits", .op = .{ .increment = .{ .integer = 1 } } }} });
    try testing.expectEqual(test_util.doc_update_ns, written.update_time.nanoseconds);
    try h.expectRequest(0, .POST, commit_url,
        \\{"writes":[{"update":{"name":"projects/extractctl/databases/(default)/documents/cities/LA","fields":{}},"updateMask":{"fieldPaths":[]},"updateTransforms":[{"fieldPath":"visits","increment":{"integerValue":"1"}}],"currentDocument":{"exists":true}}]}
    );
}

test "commit refuses what the server would, naming the write" {
    var h: test_util.Harness = undefined;
    try h.init(&.{}, .{});
    defer h.deinit();
    const c = &h.client;
    try testing.expectError(error.InvalidArgument, c.commit(&.{}, .{}));
    try h.expectDiag("at least one write");
    // Measured: "Cannot transform property m and its nested property at the same time."
    try testing.expectError(error.InvalidArgument, c.commit(&.{.{ .update = .{ .path = "c/x", .transforms = &.{
        .{ .field_path = "m", .op = .server_time },
        .{ .field_path = "m.b", .op = .{ .increment = .{ .integer = 1 } } },
    } } }}, .{}));
    try h.expectDiag("overlap");
    // The emulator takes these; nothing should send them.
    try testing.expectError(error.InvalidArgument, c.commit(&.{.{ .update = .{ .path = "c/x", .transforms = &.{.{ .field_path = "__name__", .op = .server_time }} } }}, .{}));
    try h.expectDiag("__name__");
    try testing.expectError(error.InvalidArgument, c.commit(&.{.{ .update = .{ .path = "c/x", .transforms = &.{.{ .field_path = "a", .op = .{ .append_missing = &.{.{ .array = &.{} }} } }} } }}, .{}));
    try h.expectDiag("no array may hold");
    try testing.expectError(error.InvalidResourceId, c.commit(&.{.{ .update = .{ .path = "c/x", .transforms = &.{.{ .field_path = "a-b", .op = .server_time }} } }}, .{}));
    // The second write's refusal says which write it is.
    try testing.expectError(error.InvalidResourceId, c.commit(&.{
        .{ .delete = .{ .path = "c/x" } },
        .{ .update = .{ .path = "c", .fields = &.{} } },
    }, .{}));
    try h.expectDiag("write 1: invalid document path");
    try testing.expectError(error.InvalidArgument, c.commit(&.{.{ .update = .{ .path = "c/x", .fields = &.{
        .{ .name = "s", .value = .null },
        .{ .name = "z", .value = .null },
    }, .mask = &.{"s"} } }}, .{}));
    try h.expectDiag("the field z is outside");
    try testing.expectError(error.InvalidArgument, c.commit(&.{.{ .delete = .{ .path = "c/x", .precondition = .{ .update_time = .{ .nanoseconds = std.math.maxInt(i96) } } } }}, .{}));
    // Two transforms on one field are fine; their order is kept.
    try checkTransforms(c, &.{
        .{ .field_path = "n", .op = .{ .increment = .{ .integer = 1 } } },
        .{ .field_path = "`n`", .op = .{ .increment = .{ .integer = 1 } } },
    });
    try h.expectRequestCount(0);
}

test "commit: at most 500 transforms for one document, across writes" {
    var h: test_util.Harness = undefined;
    try h.init(&.{}, .{});
    defer h.deinit();
    var many: [301]types.Transform = undefined;
    var name_bufs: [301][8]u8 = undefined;
    for (&many, &name_bufs, 0..) |*t, *buf, i| t.* = .{ .field_path = std.fmt.bufPrint(buf, "f{d}", .{i}) catch unreachable, .op = .server_time };
    // 301 + 200 on cities/LA is one too many; on two documents, fine to send.
    try testing.expectError(error.InvalidArgument, h.client.commit(&.{
        .{ .update = .{ .path = "cities/LA", .mask = &.{}, .transforms = &many } },
        .{ .update = .{ .path = "cities/LA", .mask = &.{}, .transforms = many[0..200] } },
    }, .{}));
    try h.expectDiag("over 500 transforms");
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    try checkTransformCounts(&h.client, a.allocator(), &.{
        .{ .name = "x", .op = .{ .update = .{ .fields = &.{}, .transforms = &many } } },
        .{ .name = "y", .op = .{ .update = .{ .fields = &.{}, .transforms = many[0..200] } } },
        .{ .name = "x", .op = .{ .update = .{ .fields = &.{}, .transforms = many[0..199] } } },
    });
    try h.expectRequestCount(0);
}

test "retries: transforms only under a precondition a repeat fails, or when told" {
    const increment: []const types.Transform = &.{.{ .field_path = "n", .op = .{ .increment = .{ .integer = 1 } } }};
    const ok = "{\"writeResults\":[{\"updateTime\":\"2026-10-04T22:42:59Z\",\"transformResults\":[{\"integerValue\":\"1\"}]}],\"commitTime\":\"2026-10-04T22:42:59Z\"}";
    {
        // Unconditional: sent once, and the diagnostics say what that leaves open.
        var h: test_util.Harness = undefined;
        try h.init(&.{ unavailable, unavailable }, .{});
        defer h.deinit();
        try testing.expectError(error.Unavailable, h.client.commit(&.{.{ .update = .{ .path = "c/x", .mask = &.{}, .transforms = increment } }}, .{}));
        try h.expectRequestCount(1);
        try h.expectDiag("not retried, since a transform sent twice applies twice");
        // Document.update's default, exists == true, is no such precondition.
        try testing.expectError(error.Unavailable, h.client.doc("c/x").update(&.{}, .{ .transforms = increment }));
        try h.expectRequestCount(2);
    }
    for ([_]types.Precondition{ .{ .exists = false }, .{ .update_time = .{ .nanoseconds = 1 } } }) |p| {
        var h: test_util.Harness = undefined;
        try h.init(&.{ unavailable, .{ .respond = .{ .body = ok } } }, .{});
        defer h.deinit();
        var r = try h.client.commit(&.{.{ .update = .{ .path = "c/x", .mask = &.{}, .transforms = increment, .precondition = p } }}, .{});
        r.deinit();
        try h.expectRequestCount(2);
    }
    {
        var h: test_util.Harness = undefined;
        try h.init(&.{ unavailable, .{ .respond = .{ .body = ok } } }, .{});
        defer h.deinit();
        h.client.retry_unconditional_writes = true;
        var r = try h.client.commit(&.{.{ .update = .{ .path = "c/x", .mask = &.{}, .transforms = increment } }}, .{});
        r.deinit();
        try h.expectRequestCount(2);
    }
    {
        // One unsafe write keeps the whole commit from being sent again.
        var h: test_util.Harness = undefined;
        try h.init(&.{ unavailable, unavailable }, .{});
        defer h.deinit();
        try testing.expectError(error.Unavailable, h.client.commit(&.{
            .{ .delete = .{ .path = "c/y" } },
            .{ .update = .{ .path = "c/x", .mask = &.{}, .transforms = increment } },
        }, .{}));
        try h.expectRequestCount(1);
    }
    {
        // A refusal is no lost answer: nothing to add.
        var h: test_util.Harness = undefined;
        try h.init(&.{.{ .respond = .{ .status = 400, .body = "{\"error\":{\"code\":400,\"message\":\"bad\",\"status\":\"INVALID_ARGUMENT\"}}" } }}, .{});
        defer h.deinit();
        try testing.expectError(error.InvalidArgument, h.client.commit(&.{.{ .update = .{ .path = "c/x", .mask = &.{}, .transforms = increment } }}, .{}));
        try testing.expect(std.mem.indexOf(u8, h.diag.message(), "not retried") == null);
    }
    {
        // With retries off, a lost answer says nothing more.
        var h: test_util.Harness = undefined;
        try h.init(&.{unavailable}, .{ .retry = .{ .max_attempts = 1 } });
        defer h.deinit();
        try testing.expectError(error.Unavailable, h.client.commit(&.{.{ .update = .{ .path = "c/x", .mask = &.{}, .transforms = increment } }}, .{}));
        try testing.expect(std.mem.indexOf(u8, h.diag.message(), "not retried") == null);
    }
    // Which writes are safe to send twice.
    try testing.expect(safeToRepeat(.{ .name = "n", .op = .delete }));
    try testing.expect(safeToRepeat(.{ .name = "n", .op = .{ .update = .{ .fields = &.{} } } }));
    try testing.expect(!safeToRepeat(.{ .name = "n", .op = .{ .update = .{ .fields = &.{}, .transforms = increment } } }));
    try testing.expect(!safeToRepeat(.{ .name = "n", .op = .{ .update = .{ .fields = &.{}, .transforms = increment } }, .precondition = .{ .exists = true } }));
    try testing.expect(safeToRepeat(.{ .name = "n", .op = .{ .update = .{ .fields = &.{}, .transforms = increment } }, .precondition = .{ .exists = false } }));
}

test "a commit answer that does not match the writes is InvalidResponse" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        // Two results for one write.
        .{ .respond = .{ .body = "{\"writeResults\":[{},{}],\"commitTime\":\"2026-10-04T22:42:59Z\"}" } },
        // A transform's result missing.
        .{ .respond = .{ .body = "{\"writeResults\":[{\"updateTime\":\"2026-10-04T22:42:59Z\"}],\"commitTime\":\"2026-10-04T22:42:59Z\"}" } },
        // A result for a transform nobody sent.
        .{ .respond = .{ .body = "{\"writeResults\":[{\"updateTime\":\"2026-10-04T22:42:59Z\",\"transformResults\":[{\"nullValue\":null}]}],\"commitTime\":\"2026-10-04T22:42:59Z\"}" } },
    }, .{});
    defer h.deinit();
    try testing.expectError(error.InvalidResponse, h.client.commit(&.{.{ .delete = .{ .path = "c/x" } }}, .{}));
    try h.expectDiag("the commit response could not be decoded");
    h.client.retry_unconditional_writes = true;
    try testing.expectError(error.InvalidResponse, h.client.commit(&.{.{ .update = .{ .path = "c/x", .mask = &.{}, .transforms = &.{.{ .field_path = "t", .op = .server_time }} } }}, .{}));
    try testing.expectError(error.InvalidResponse, h.client.commit(&.{.{ .update = .{ .path = "c/x", .fields = &.{} } }}, .{}));
}

test "commit: every allocation failure is OutOfMemory without leaks" {
    const Run = struct {
        fn run(gpa: Allocator) !void {
            var fake: test_util.FakeTransport = .init(testing.allocator, &.{
                .{ .respond = .{ .body = "{\"writeResults\":[{\"updateTime\":\"2026-10-04T22:42:59Z\",\"transformResults\":[{\"integerValue\":\"2\"},{\"nullValue\":null}]},{}],\"commitTime\":\"2026-10-04T22:42:59Z\"}" } },
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
            var r = try client.commit(&.{
                .{ .update = .{ .path = "c/x", .fields = &.{.{ .name = "a-b", .value = .{ .map = &.{.{ .name = "c", .value = .null }} } }}, .mask = &.{"`a-b`.c"}, .transforms = &.{
                    .{ .field_path = "n", .op = .{ .increment = .{ .integer = 1 } } },
                    .{ .field_path = "t", .op = .{ .append_missing = &.{.{ .string = "x" }} } },
                } } },
                .{ .delete = .{ .path = "c/y" } },
            }, .{});
            r.deinit();
        }
    };
    try testing.checkAllAllocationFailures(test_util.no_grow_allocator, Run.run, .{});
}
