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

/// Commits `writes`, in order and atomically, in `transaction` when set,
/// and returns what each did, decoded into `response`. The call has begun.
pub fn commit(client: *Client, writes: []const types.Write, transaction: ?[]const u8, response: *std.heap.ArenaAllocator) Error!types.CommitResult {
    if (writes.len == 0) return rpc.refuse(client, error.InvalidArgument, "a commit needs at least one write: a transaction without any ends with rollback", .{});
    try rpc.checkTransaction(client, transaction, null);
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
    const body = try codec.encodeCommit(a, wire, transaction);
    // A transaction's commit is sent once: a repeat of one that landed
    // answers ABORTED, which would run the transaction again.
    const retried = transaction == null and (client.retry_unconditional_writes or for (wire) |w| {
        if (!safeToRepeat(w)) break false;
    } else true);
    const reply = rpc.execute(client, response, .{ .method = .POST, .path = url, .body = body, .retry = retried }) catch |err| {
        if (transaction != null) {
            if (client.retry.max_attempts > 1 and core.isRetryable(err)) rpc.appendNote(client, "; a transaction's commit is sent once: it may or may not have committed, so read to see");
        } else noteFailure(client, err, wire, retried);
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

/// The write `Document.update` sends: the mask given, or the top-level
/// names of `fields`; refused when it would change nothing.
pub fn updateWrite(client: *Client, a: Allocator, path: []const u8, fields: []const types.Field, options: types.UpdateOptions) Error!types.Write {
    try rpc.checkFields(client, fields);
    const mask = options.mask orelse try defaultMask(a, fields);
    if (mask.len == 0 and options.transforms.len == 0) {
        return rpc.refuse(client, error.InvalidArgument, "an update needs a field, a mask path or a transform: this one would change nothing", .{});
    }
    return .{ .update = .{
        .path = path,
        .fields = fields,
        .mask = mask,
        .transforms = options.transforms,
        .precondition = options.precondition,
    } };
}

/// The top-level names of `fields`, each as a field path.
fn defaultMask(a: Allocator, fields: []const types.Field) Allocator.Error![]const []const u8 {
    const mask = try a.alloc([]const u8, fields.len);
    for (fields, mask) |f, *m| m.* = try names.fieldPathOf(a, f.name);
    return mask;
}

/// Checks a write as `commit` would, without sending it.
pub fn check(client: *Client, a: Allocator, w: types.Write) Error!void {
    _ = try resolve(client, a, w);
}

/// `w` with everything it points to copied into `a`, for a write kept
/// past the call that made it, as a transaction keeps its writes.
pub fn copyWrite(a: Allocator, w: types.Write) Allocator.Error!types.Write {
    return switch (w) {
        .update => |u| .{ .update = .{
            .path = try a.dupe(u8, u.path),
            .fields = try copyFields(a, u.fields),
            .mask = if (u.mask) |m| try copyStrings(a, m) else null,
            .transforms = try copyTransforms(a, u.transforms),
            .precondition = u.precondition,
        } },
        .delete => |d| .{ .delete = .{ .path = try a.dupe(u8, d.path), .precondition = d.precondition } },
    };
}

fn copyStrings(a: Allocator, strings: []const []const u8) Allocator.Error![]const []const u8 {
    const out = try a.alloc([]const u8, strings.len);
    for (strings, out) |s, *o| o.* = try a.dupe(u8, s);
    return out;
}

fn copyFields(a: Allocator, fields: []const types.Field) Allocator.Error![]const types.Field {
    const out = try a.alloc(types.Field, fields.len);
    for (fields, out) |f, *o| o.* = .{ .name = try a.dupe(u8, f.name), .value = try copyValue(a, f.value) };
    return out;
}

fn copyValues(a: Allocator, values: []const types.Value) Allocator.Error![]const types.Value {
    const out = try a.alloc(types.Value, values.len);
    for (values, out) |v, *o| o.* = try copyValue(a, v);
    return out;
}

fn copyValue(a: Allocator, v: types.Value) Allocator.Error!types.Value {
    return switch (v) {
        .string => |s| .{ .string = try a.dupe(u8, s) },
        .bytes => |b| .{ .bytes = try a.dupe(u8, b) },
        .reference => |r| .{ .reference = try a.dupe(u8, r) },
        .array => |items| .{ .array = try copyValues(a, items) },
        .map => |fields| .{ .map = try copyFields(a, fields) },
        .null, .boolean, .integer, .double, .timestamp, .geo_point => v,
    };
}

fn copyTransforms(a: Allocator, transforms: []const types.Transform) Allocator.Error![]const types.Transform {
    const out = try a.alloc(types.Transform, transforms.len);
    for (transforms, out) |t, *o| o.* = .{
        .field_path = try a.dupe(u8, t.field_path),
        .op = switch (t.op) {
            .append_missing => |values| .{ .append_missing = try copyValues(a, values) },
            .remove_all => |values| .{ .remove_all = try copyValues(a, values) },
            else => t.op,
        },
    };
    return out;
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
            try rpc.checkDocumentSize(client, path, u.fields);
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

test "commit: a document or a request larger than Firestore takes is refused before sending" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = test_util.commit_body } },
        .{ .respond = .{ .body = test_util.docBody("c/new", "{}") } },
    }, .{});
    defer h.deinit();
    const big = try testing.allocator.alloc(u8, 1_000_000);
    defer testing.allocator.free(big);
    @memset(big, 'x');
    // 1,048,576 bytes exactly, as Firestore counts them, is taken: the
    // path 20, two fields, 32.
    const fit: []const types.Field = &.{ .{ .name = "a", .value = .{ .string = big } }, .{ .name = "b", .value = .{ .string = big[0..48_518] } } };
    try testing.expectEqual(validate.max_document_bytes, validate.documentSize("s/x", fit));
    _ = try h.client.doc("s/x").set(fit, .{});
    const over: []const types.Field = &.{ .{ .name = "a", .value = .{ .string = big } }, .{ .name = "b", .value = .{ .string = big[0..48_519] } } };
    try testing.expectError(error.InvalidArgument, h.client.doc("s/x").set(over, .{}));
    try h.expectDiag("the document s/x is at least 1048577 bytes as Firestore counts them, over the 1048576 it takes");
    // Through a mask, the fields sent are the least the document holds.
    try testing.expectError(error.InvalidArgument, h.client.doc("s/x").update(over, .{ .mask = &.{ "a", "b" } }));
    try testing.expectError(error.InvalidArgument, h.client.commit(&.{.{ .update = .{ .path = "s/x", .fields = over } }}, .{}));
    try testing.expectError(error.InvalidArgument, h.client.collection("s").create(over, .{ .document_id = "x" }));
    try h.expectDiag("the document s/x is at least 1048577 bytes");
    var made = try h.client.collection("c").create(&.{}, .{ .document_id = "new" });
    made.deinit();

    // Twelve documents of 1,000,000 bytes each fit, but not in one request.
    var writes: [12]types.Write = undefined;
    var paths: [12][8]u8 = undefined;
    for (&writes, &paths, 0..) |*w, *p, i| w.* = .{ .update = .{ .path = try std.fmt.bufPrint(p, "c/d{d:0>2}", .{i}), .fields = &.{.{ .name = "s", .value = .{ .string = big } }} } };
    try testing.expectError(error.InvalidArgument, h.client.commit(&writes, .{}));
    try h.expectDiag("over the 11534336 Firestore takes");
    // A query, buffered or streamed: thirty values of 1,000,000 bytes.
    var values: [30]types.Value = @splat(.{ .string = big });
    const q: types.Query = .{ .from = .{ .collection = "c" }, .where = &.{.{ .field = "s", .op = .in, .value = .{ .array = &values } }} };
    try testing.expectError(error.InvalidArgument, h.client.runQuery(q, .{}));
    const Nothing = struct {
        fn document(_: *anyopaque, snapshot: types.Owned(types.Snapshot)) anyerror!void {
            var s = snapshot;
            s.deinit();
        }
    };
    var nothing: u8 = 0;
    try testing.expectError(error.InvalidArgument, h.client.runQueryEach(q, .{}, .{ .ptr = &nothing, .vtable = &.{ .document = Nothing.document } }));
    try h.expectDiag("over the 11534336 Firestore takes");
    try h.expectRequestCount(2);
    try testing.expectEqual(0, h.fake.stream_requests.items.len);
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

/// The commit body of `w` alone, for comparing writes.
fn encodeOne(a: Allocator, w: types.Write) ![]u8 {
    const wire: codec.Write = switch (w) {
        .update => |u| .{ .name = u.path, .op = .{ .update = .{ .fields = u.fields, .mask = u.mask, .transforms = u.transforms } }, .precondition = u.precondition },
        .delete => |d| .{ .name = d.path, .op = .delete, .precondition = d.precondition },
    };
    return codec.encodeCommit(a, &.{wire}, null);
}

test "copyWrite: the copy says exactly what the original said, and outlives it" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Every value kind, transforms with values, a mask, in borrowed memory
    // that is overwritten once copied.
    const scratch = try testing.allocator.alloc(u8, 64);
    defer testing.allocator.free(scratch);
    @memcpy(scratch[0..20], "c/xbytesrefnamemaskv");
    const original: types.Write = .{ .update = .{
        .path = scratch[0..3],
        .fields = &.{
            .{ .name = scratch[15..19], .value = .{ .map = &.{
                .{ .name = "s", .value = .{ .string = scratch[3..8] } },
                .{ .name = "b", .value = .{ .bytes = scratch[3..8] } },
                .{ .name = "r", .value = .{ .reference = "projects/p/databases/(default)/documents/c/y" } },
                .{ .name = "a", .value = .{ .array = &.{ .{ .integer = 1 }, .{ .double = 1.5 }, .null, .{ .boolean = true } } } },
                .{ .name = "t", .value = .{ .timestamp = .{ .nanoseconds = 1_791_158_400_000_000_000 } } },
                .{ .name = "g", .value = .{ .geo_point = .{ .latitude = 1, .longitude = 2 } } },
            } } },
        },
        .mask = &.{scratch[15..19]},
        .transforms = &.{
            .{ .field_path = "n", .op = .{ .increment = .{ .integer = 1 } } },
            .{ .field_path = "tags", .op = .{ .append_missing = &.{.{ .string = scratch[3..8] }} } },
            .{ .field_path = "old", .op = .{ .remove_all = &.{.{ .map = &.{.{ .name = "k", .value = .null }} }} } },
            .{ .field_path = "at", .op = .server_time },
        },
        .precondition = .{ .exists = true },
    } };
    const before = try encodeOne(a, original);
    const copy = try copyWrite(a, original);
    @memset(scratch, 'Z');
    try testing.expectEqualStrings(before, try encodeOne(a, copy));

    @memcpy(scratch[0..3], "c/x");
    const delete: types.Write = .{ .delete = .{ .path = scratch[0..3], .precondition = .{ .update_time = .{ .nanoseconds = 1_000 } } } };
    const delete_before = try encodeOne(a, delete);
    const delete_copy = try copyWrite(a, delete);
    @memset(scratch, 'Z');
    try testing.expectEqualStrings(delete_before, try encodeOne(a, delete_copy));
}

fn copyProperty(_: void, input: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var g: test_util.ByteGen = .init(input);
    const fields = try a.alloc(types.Field, g.intRange(u8, 0, 3));
    for (fields, 0..) |*f, i| f.* = .{ .name = try std.fmt.allocPrint(a, "f{d}", .{i}), .value = try codec.randomValue(&g, a, 3, false) };
    const values = try a.alloc(types.Value, g.intRange(u8, 0, 2));
    for (values) |*v| v.* = try codec.randomValue(&g, a, 2, true);
    const w: types.Write = if (g.intRange(u8, 0, 4) == 0)
        .{ .delete = .{ .path = "c/x" } }
    else
        .{ .update = .{
            .path = "c/x",
            .fields = fields,
            .mask = if (g.boolean()) &.{"f0"} else null,
            .transforms = if (g.boolean()) &.{.{ .field_path = "z", .op = .{ .append_missing = values } }} else &.{},
        } };
    var copy_arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer copy_arena.deinit();
    const copy = try copyWrite(copy_arena.allocator(), w);
    try testing.expectEqualStrings(try encodeOne(a, w), try encodeOne(a, copy));
}

test "fuzz copyWrite: any write's copy encodes as the original" {
    try test_util.fuzzBytes({}, copyProperty, .{ .corpus = &.{ "", "\x01\x0a\x03\x09\x02", "\x03\x0a\x0a\x0a\x01\x01\x01" } });
}
