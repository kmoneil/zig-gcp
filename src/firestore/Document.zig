//! A handle for one document: read, write and delete it, and reach its
//! subcollections. Cheap to copy; it borrows its client and the strings
//! its path was built from, and sends nothing until a call.

const Document = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const core = @import("core");

const Client = @import("Client.zig");
const Collection = @import("Collection.zig");
const batch_get = @import("batch_get.zig");
const codec = @import("codec.zig");
const errors = @import("errors.zig");
const names = @import("names.zig");
const rpc = @import("rpc.zig");
const types = @import("types.zig");
const writes = @import("writes.zig");
const Error = errors.Error;
const Params = core.query.Params;

client: *Client,
path: names.Path,

/// The document's own id: the last segment of its path.
pub fn id(self: Document) []const u8 {
    return self.path.last();
}

/// A handle for the subcollection `collection_id` below this document.
/// The document need not exist: a subcollection outlives its parent.
pub fn collection(self: Document, collection_id: []const u8) Collection {
    return .{ .client = self.client, .path = self.path.child(collection_id) };
}

/// Reads the document. A missing one is `error.NotFound`; `batchGet` is
/// the way to ask whether documents exist without an error.
pub fn get(self: Document, options: types.GetOptions) Error!types.Owned(types.Snapshot) {
    const client = self.client;
    rpc.begin(client);
    var scratch: std.heap.ArenaAllocator = .init(client.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const path = try rpc.checkedPath(client, a, self.path, .document);
    if (options.mask) |m| try rpc.checkMask(client, m, "read mask");

    try rpc.checkTransaction(client, options.transaction, options.read_time);

    var result: types.Owned(types.Snapshot) = try .init(client.gpa);
    errdefer result.deinit();
    if (options.read_time != null or options.transaction != null) {
        // Measured: the emulator refuses a read time as a query parameter,
        // "Only timestamps past epoch are supported.", and hangs on a
        // transaction there; batchGet takes either in its body.
        const batch = try batch_get.batchGet(client, &.{path}, .{ .mask = options.mask, .read_time = options.read_time, .transaction = options.transaction }, result.arena);
        result.value = batch.documents[0] orelse return rpc.refuse(client, error.NotFound, "{s}", .{
            if (options.read_time != null) "the document did not exist at the read time" else "the document does not exist",
        });
        return result;
    }
    const url = writeUrl(a, client, path, options.mask) catch return error.OutOfMemory;
    const body = try rpc.execute(client, result.arena, .{ .method = .GET, .path = url });
    result.value = codec.decodeSnapshot(result.arena.allocator(), body) catch |err|
        return rpc.decodeFailed(client, err, "document");
    return result;
}

/// Writes the document whole: `fields` replace every field it had, and a
/// missing document is created, unless `options.precondition` says
/// otherwise; then `options.transforms` apply. Retried after a lost answer
/// as `Client.Options.retry_unconditional_writes` describes.
pub fn set(self: Document, fields: []const types.Field, options: types.SetOptions) Error!types.WriteResult {
    const client = self.client;
    rpc.begin(client);
    var scratch: std.heap.ArenaAllocator = .init(client.gpa);
    defer scratch.deinit();
    const path = try rpc.checkedPath(client, scratch.allocator(), self.path, .document);
    return writeOne(client, .{ .update = .{
        .path = path,
        .fields = fields,
        .transforms = options.transforms,
        .precondition = options.precondition,
    } });
}

/// Changes the fields `options.mask` names, by default the top-level
/// names of `fields`, each replaced whole, and leaves the rest alone; then
/// `options.transforms` apply. A mask path with no value in `fields`
/// deletes that field, and one inside a map, such as `address.city`,
/// changes only that field of it. By default the document must exist
/// (`error.NotFound` otherwise). Every value in `fields` must lie under a
/// mask path, and no two mask paths may overlap, such as `a` and `a.b`:
/// the server would ignore the one, or decide between the two. Retried
/// after a lost answer as `Client.Options.retry_unconditional_writes`
/// describes.
pub fn update(self: Document, fields: []const types.Field, options: types.UpdateOptions) Error!types.WriteResult {
    const client = self.client;
    rpc.begin(client);
    var scratch: std.heap.ArenaAllocator = .init(client.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const path = try rpc.checkedPath(client, a, self.path, .document);
    return writeOne(client, try writes.updateWrite(client, a, path, fields, options));
}

/// Deletes the document. Deleting a missing one succeeds unless
/// `options.precondition` says it must exist. Its subcollections stay:
/// Firestore deletes no document but the one named. Always retried: a
/// repeat deletes nothing more.
pub fn delete(self: Document, options: types.DeleteOptions) Error!void {
    const client = self.client;
    rpc.begin(client);
    var scratch: std.heap.ArenaAllocator = .init(client.gpa);
    defer scratch.deinit();
    const path = try rpc.checkedPath(client, scratch.allocator(), self.path, .document);
    _ = try writeOne(client, .{ .delete = .{ .path = path, .precondition = options.precondition } });
}

/// One page of the ids of the collections directly below this document,
/// in ascending order. The document need not exist.
pub fn listCollectionIds(self: Document, options: types.ListCollectionIdsOptions) Error!types.Owned(types.CollectionIdPage) {
    const client = self.client;
    rpc.begin(client);
    var scratch: std.heap.ArenaAllocator = .init(client.gpa);
    defer scratch.deinit();
    const path = try rpc.checkedPath(client, scratch.allocator(), self.path, .document);
    return rpc.listCollectionIds(client, path, options);
}

/// Commits one write and returns its update time: a delete's is the
/// commit's own. The call has begun.
fn writeOne(client: *Client, write: types.Write) Error!types.WriteResult {
    var response: std.heap.ArenaAllocator = .init(client.gpa);
    defer response.deinit();
    const result = try writes.commit(client, &.{write}, null, &response);
    return .{ .update_time = result.writes[0].update_time orelse result.commit_time };
}

/// The request path for reading the document at `path`.
fn writeUrl(a: Allocator, client: *const Client, path: []const u8, mask: ?[]const []const u8) Writer.Error![]const u8 {
    var out: Writer.Allocating = .init(a);
    const w = &out.writer;
    try names.writeDocumentsPath(w, client.project_id, client.database_id, path);
    var params: Params = .init(w);
    if (mask) |m| try rpc.addMask(&params, "mask.fieldPaths", m);
    return out.written();
}

const testing = std.testing;
const test_util = @import("test_util.zig");
const base = test_util.base;

test "golden: get, with a mask" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = test_util.docBody("cities/LA", "{\"name\":{\"stringValue\":\"Los Angeles\"}}") } },
        .{ .respond = .{ .body = test_util.docBody("cities/LA", "{}") } },
    }, .{});
    defer h.deinit();

    var got = try h.client.doc("cities/LA").get(.{});
    defer got.deinit();
    try h.expectRequest(0, .GET, base ++ "/cities/LA", null);
    try testing.expectEqualStrings("Los Angeles", got.value.get("name").?.string);
    try testing.expectEqual(test_util.doc_update_ns, got.value.update_time.nanoseconds);

    var masked = try h.client.doc("cities/LA").get(.{ .mask = &.{ "name", "`a-b`.c" } });
    defer masked.deinit();
    try h.expectRequest(1, .GET, base ++ "/cities/LA?mask.fieldPaths=name&mask.fieldPaths=%60a-b%60.c", null);
    // The token goes to the caller's provider.
    try testing.expectEqualStrings("ya29.test-token", (try h.fake.request(0)).bearer.?);
    try testing.expectEqualStrings(rpc.scope, h.token.firstScope());
}

test "get: a missing document is NotFound, with the server's words" {
    var h: test_util.Harness = undefined;
    try h.init(&.{.{ .respond = .{ .status = 404, .body =
        \\{"error":{"code":404,"message":"Document (projects/extractctl/databases/(default)/documents/c/missing) not found.","status":"NOT_FOUND"}}
    } }}, .{});
    defer h.deinit();
    try testing.expectError(error.NotFound, h.client.doc("c/missing").get(.{}));
    try h.expectDiag("not found");
    try h.expectRequestCount(1);
}

test "get: subcollections, derived handles and odd ids" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = test_util.docBody("cities/LA/landmarks/tower", "{}") } },
        .{ .respond = .{ .body = test_util.docBody("c/a b%c+d", "{}") } },
    }, .{ .database_id = "zigps-fs-1" });
    defer h.deinit();
    var tower = try h.client.collection("cities").doc("LA").collection("landmarks").doc("tower").get(.{});
    defer tower.deinit();
    try h.expectRequest(0, .GET, "https://firestore.googleapis.com/v1/projects/extractctl/databases/zigps-fs-1/documents/cities/LA/landmarks/tower", null);
    var odd = try h.client.collection("c").doc("a b%c+d").get(.{});
    defer odd.deinit();
    try h.expectRequest(1, .GET, "https://firestore.googleapis.com/v1/projects/extractctl/databases/zigps-fs-1/documents/c/a%20b%25c%2Bd", null);
    try testing.expectEqualStrings("tower", h.client.collection("cities").doc("LA").collection("landmarks").doc("tower").id());
}

test "bad paths and masks are refused before anything is sent" {
    var h: test_util.Harness = undefined;
    try h.init(&.{}, .{});
    defer h.deinit();
    const c = &h.client;
    try testing.expectError(error.InvalidResourceId, c.doc("cities").get(.{}));
    try h.expectDiag("even number of segments");
    try testing.expectError(error.InvalidResourceId, c.doc("cities/__x__").get(.{}));
    try h.expectDiag("reserved");
    try testing.expectError(error.InvalidResourceId, c.doc("cities//LA").get(.{}));
    try testing.expectError(error.InvalidResourceId, c.collection("a").doc("b/c").get(.{}));
    try testing.expectError(error.InvalidResourceId, c.doc("cities/LA").get(.{ .mask = &.{"a-b"} }));
    try h.expectDiag("invalid field path in the read mask");

    // Derived past max_path_parts: refused at the call, not at derivation.
    var deep = c.collection("a").doc("b");
    for (0..names.max_path_parts) |_| deep = deep.collection("c").doc("d");
    try testing.expectError(error.InvalidResourceId, deep.get(.{}));
    try h.expectDiag("more than 8 parts");

    // A full name over 6 KiB.
    const long_id = test_util.repeat("i", 1500);
    const long_path = "c/" ++ long_id ++ "/c/" ++ long_id ++ "/c/" ++ long_id ++ "/c/" ++ long_id ++ "/c/" ++ long_id;
    try testing.expectError(error.InvalidResourceId, c.doc(long_path).get(.{}));
    try h.expectDiag("6 KiB");
    try h.expectRequestCount(0);
}

const commit_url = base ++ ":commit";

test "golden: set commits the whole document, with preconditions" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = test_util.commit_body } },
        .{ .respond = .{ .body = test_util.commit_body } },
        .{ .respond = .{ .body = test_util.commit_body } },
    }, .{});
    defer h.deinit();
    const la = h.client.doc("cities/LA");
    const written = try la.set(&.{
        .{ .name = "name", .value = .{ .string = "Los Angeles" } },
        .{ .name = "population", .value = .{ .integer = 3_900_000 } },
    }, .{});
    try testing.expectEqual(test_util.doc_update_ns, written.update_time.nanoseconds);
    try h.expectRequest(0, .POST, commit_url, "{\"writes\":[{\"update\":{\"name\":\"" ++ test_util.name("cities/LA") ++ "\",\"fields\":{\"name\":{\"stringValue\":\"Los Angeles\"},\"population\":{\"integerValue\":\"3900000\"}}}}]}");

    _ = try la.set(&.{}, .{ .precondition = .{ .exists = false } });
    try h.expectRequest(1, .POST, commit_url, "{\"writes\":[{\"update\":{\"name\":\"" ++ test_util.name("cities/LA") ++ "\",\"fields\":{}},\"currentDocument\":{\"exists\":false}}]}");
    _ = try la.set(&.{}, .{ .precondition = .{ .update_time = written.update_time } });
    try h.expectRequest(2, .POST, commit_url, "{\"writes\":[{\"update\":{\"name\":\"" ++ test_util.name("cities/LA") ++ "\",\"fields\":{}},\"currentDocument\":{\"updateTime\":\"2026-10-04T22:42:59.269778Z\"}}]}");
}

test "set: retried after a lost answer, with the ambiguity said when a precondition meets it" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .status = 503, .body = "{\"error\":{\"code\":503,\"message\":\"unavailable\",\"status\":\"UNAVAILABLE\"}}" } },
        .{ .respond = .{ .status = 409, .body = "{\"error\":{\"code\":409,\"message\":\"Document already exists: projects/extractctl/databases/(default)/documents/cities/LA\",\"status\":\"ALREADY_EXISTS\"}}" } },
        .{ .respond = .{ .status = 503, .body = "{\"error\":{\"code\":503,\"message\":\"unavailable\",\"status\":\"UNAVAILABLE\"}}" } },
        .{ .respond = .{ .body = test_util.commit_body } },
    }, .{});
    defer h.deinit();
    const la = h.client.doc("cities/LA");
    try testing.expectError(error.AlreadyExists, la.set(&.{}, .{ .precondition = .{ .exists = false } }));
    try h.expectDiag("Document already exists");
    try h.expectDiag("an earlier attempt may have landed");
    try testing.expectEqualStrings("ALREADY_EXISTS", h.diag.status());
    try testing.expectEqual(409, h.diag.http_status);
    // An unconditional set retries too, and succeeds.
    _ = try la.set(&.{}, .{});
    try h.expectRequestCount(4);
}

test "a failed precondition without retries says nothing of earlier attempts" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .status = 400, .body = "{\"error\":{\"code\":400,\"message\":\"the stored version (1791153779335637) does not match the required base version (0)\",\"status\":\"FAILED_PRECONDITION\"}}" } },
        .{ .respond = .{ .status = 409, .body = "{\"error\":{\"code\":409,\"message\":\"exists\",\"status\":\"ALREADY_EXISTS\"}}" } },
    }, .{ .retry = .{ .max_attempts = 1 } });
    defer h.deinit();
    const la = h.client.doc("cities/LA");
    try testing.expectError(error.FailedPrecondition, la.delete(.{ .precondition = .{ .update_time = .{ .nanoseconds = 0 } } }));
    try h.expectDiag("does not match the required base version");
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "earlier attempt") == null);
    // exists == true never meets its own earlier write as a refusal.
    try testing.expectError(error.AlreadyExists, la.set(&.{}, .{ .precondition = .{ .exists = true } }));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "earlier attempt") == null);
}

test "a missing document under update's default precondition is NotFound, with no word of earlier attempts" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .status = 404, .body = "{\"error\":{\"code\":404,\"message\":\"No document to update\",\"status\":\"NOT_FOUND\"}}" } },
        .{ .respond = .{ .status = 409, .body = "{\"error\":{\"code\":409,\"message\":\"exists\",\"status\":\"ALREADY_EXISTS\"}}" } },
    }, .{});
    defer h.deinit();
    // Retries are on: only a precondition a repeat fails earns the note.
    try testing.expectError(error.NotFound, h.client.doc("cities/SF").update(&.{.{ .name = "x", .value = .null }}, .{}));
    try h.expectDiag("No document to update");
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "earlier attempt") == null);
    try testing.expectError(error.AlreadyExists, h.client.doc("cities/SF").set(&.{}, .{ .precondition = .{ .exists = true } }));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "earlier attempt") == null);
}

test "the 6 KiB limit counts the full name, project and database included" {
    var h: test_util.Harness = undefined;
    try h.init(&.{.{ .respond = .{ .body = test_util.docBody("x/y", "{}") } }}, .{});
    defer h.deinit();
    const col = test_util.repeat("c", 30);
    const long = test_util.repeat("i", 1500);
    // 6,127 bytes of path, 6,177 with `projects/extractctl/.../documents/`.
    const path = col ++ "/" ++ long ++ "/" ++ col ++ "/" ++ long ++ "/" ++ col ++ "/" ++ long ++ "/" ++ col ++ "/" ++ long;
    try testing.expectEqual(6127, path.len);
    try testing.expectError(error.InvalidResourceId, h.client.doc(path).get(.{}));
    try h.expectDiag("6 KiB");
    // 17 bytes shorter is 6,144 in full: the limit, and allowed.
    var got = try h.client.doc(path[0 .. path.len - 33]).get(.{});
    defer got.deinit();
    try h.expectRequestCount(1);
}

test "golden: update masks the given fields, quoted, and requires the document" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = test_util.commit_body } },
        .{ .respond = .{ .body = test_util.commit_body } },
        .{ .respond = .{ .body = test_util.commit_body } },
    }, .{});
    defer h.deinit();
    const la = h.client.doc("cities/LA");
    _ = try la.update(&.{
        .{ .name = "population", .value = .{ .integer = 4_000_000 } },
        .{ .name = "a-b", .value = .null },
    }, .{});
    try h.expectRequest(0, .POST, commit_url, "{\"writes\":[{\"update\":{\"name\":\"" ++ test_util.name("cities/LA") ++ "\",\"fields\":{\"population\":{\"integerValue\":\"4000000\"},\"a-b\":{\"nullValue\":\"NULL_VALUE\"}}},\"updateMask\":{\"fieldPaths\":[\"population\",\"`a-b`\"]},\"currentDocument\":{\"exists\":true}}]}");

    // A mask path with no value deletes; one inside a map changes only that.
    _ = try la.update(&.{
        .{ .name = "address", .value = .{ .map = &.{.{ .name = "city", .value = .{ .string = "LA" } }} } },
    }, .{ .mask = &.{ "address.city", "nickname" }, .precondition = null });
    try h.expectRequest(1, .POST, commit_url, "{\"writes\":[{\"update\":{\"name\":\"" ++ test_util.name("cities/LA") ++ "\",\"fields\":{\"address\":{\"mapValue\":{\"fields\":{\"city\":{\"stringValue\":\"LA\"}}}}}},\"updateMask\":{\"fieldPaths\":[\"address.city\",\"nickname\"]}}]}");

    // Deletes alone: no fields at all.
    _ = try la.update(&.{}, .{ .mask = &.{"nickname"}, .precondition = .{ .update_time = .{ .nanoseconds = test_util.doc_update_ns } } });
    try h.expectRequest(2, .POST, commit_url, "{\"writes\":[{\"update\":{\"name\":\"" ++ test_util.name("cities/LA") ++ "\",\"fields\":{}},\"updateMask\":{\"fieldPaths\":[\"nickname\"]},\"currentDocument\":{\"updateTime\":\"2026-10-04T22:42:59.269778Z\"}}]}");
}

test "update refuses what the server would misapply" {
    var h: test_util.Harness = undefined;
    try h.init(&.{}, .{});
    defer h.deinit();
    const la = h.client.doc("cities/LA");
    // An empty mask would overwrite the whole document.
    try testing.expectError(error.InvalidArgument, la.update(&.{}, .{}));
    try h.expectDiag("would change nothing");
    try testing.expectError(error.InvalidArgument, la.update(&.{}, .{ .mask = &.{} }));
    // Overlapping paths: the emulator takes them, Google's clients refuse.
    try testing.expectError(error.InvalidArgument, la.update(&.{}, .{ .mask = &.{ "a", "a.b" } }));
    try h.expectDiag("a and a.b overlap");
    try testing.expectError(error.InvalidArgument, la.update(&.{}, .{ .mask = &.{ "x", "`x`" } }));
    // A value no mask path writes: measured, the server ignores it.
    try testing.expectError(error.InvalidArgument, la.update(&.{
        .{ .name = "s", .value = .{ .string = "q" } },
        .{ .name = "z", .value = .{ .string = "ignored" } },
    }, .{ .mask = &.{"s"} }));
    try h.expectDiag("the field z is outside");
    try testing.expectError(error.InvalidArgument, la.update(&.{
        .{ .name = "a", .value = .{ .map = &.{ .{ .name = "b", .value = .null }, .{ .name = "c-d", .value = .null } } } },
    }, .{ .mask = &.{"a.b"} }));
    try h.expectDiag("the field a.`c-d` is outside");
    try testing.expectError(error.InvalidArgument, la.update(&.{
        .{ .name = "a", .value = .{ .integer = 1 } },
    }, .{ .mask = &.{"a.b"} }));
    try h.expectDiag("the field a is outside");
    try testing.expectError(error.InvalidResourceId, la.update(&.{}, .{ .mask = &.{"__x__"} }));
    try testing.expectError(error.InvalidArgument, la.update(&.{.{ .name = "__x__", .value = .null }}, .{}));
    try h.expectDiag("reserved");
    try h.expectRequestCount(0);
}

test "update: mask coverage, the cases that pass" {
    var where_buf: [64]u8 = undefined;
    const fields: []const types.Field = &.{
        .{ .name = "a", .value = .{ .map = &.{
            .{ .name = "b", .value = .null },
            .{ .name = "c", .value = .{ .map = &.{.{ .name = "d", .value = .null }} } },
        } } },
        .{ .name = "e.f", .value = .null },
    };
    try testing.expectEqual(null, writes.uncovered(&.{ "a", "`e.f`" }, fields, &where_buf));
    try testing.expectEqual(null, writes.uncovered(&.{ "a.b", "a.c", "`e.f`" }, fields, &where_buf));
    try testing.expectEqual(null, writes.uncovered(&.{ "a.b", "a.c.d", "`e.f`", "zzz" }, fields, &where_buf));
    try testing.expectEqualStrings("`e.f`", writes.uncovered(&.{ "a", "e.f" }, fields, &where_buf).?);
    try testing.expectEqualStrings("a.c.d", writes.uncovered(&.{ "a.b", "a.c.x", "`e.f`" }, fields, &where_buf).?);
}

test "golden: delete, plain and held to a precondition" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = test_util.delete_body } },
        .{ .respond = .{ .body = test_util.delete_body } },
        .{ .respond = .{ .status = 404, .body = "{\"error\":{\"code\":404,\"message\":\"No document to update\",\"status\":\"NOT_FOUND\"}}" } },
    }, .{});
    defer h.deinit();
    const la = h.client.doc("cities/LA");
    try la.delete(.{});
    try h.expectRequest(0, .POST, commit_url, "{\"writes\":[{\"delete\":\"" ++ test_util.name("cities/LA") ++ "\"}]}");
    try la.delete(.{ .precondition = .{ .update_time = .{ .nanoseconds = test_util.doc_update_ns } } });
    try h.expectRequest(1, .POST, commit_url, "{\"writes\":[{\"delete\":\"" ++ test_util.name("cities/LA") ++ "\",\"currentDocument\":{\"updateTime\":\"2026-10-04T22:42:59.269778Z\"}}]}");
    try testing.expectError(error.NotFound, la.delete(.{ .precondition = .{ .exists = true } }));
    try h.expectRequest(2, .POST, commit_url, "{\"writes\":[{\"delete\":\"" ++ test_util.name("cities/LA") ++ "\",\"currentDocument\":{\"exists\":true}}]}");
}

test "golden: a document's subcollection ids" {
    var h: test_util.Harness = undefined;
    try h.init(&.{.{ .respond = .{ .body = "{\"collectionIds\":[\"landmarks\"]}" } }}, .{});
    defer h.deinit();
    var page = try h.client.doc("cities/LA").listCollectionIds(.{ .page_size = 10 });
    defer page.deinit();
    try h.expectRequest(0, .POST, base ++ "/cities/LA:listCollectionIds", "{\"pageSize\":10}");
    try testing.expectEqualStrings("landmarks", page.value.collection_ids[0]);
    try testing.expectError(error.InvalidResourceId, h.client.doc("cities").listCollectionIds(.{}));
}

test "writes refuse bad values before anything is sent" {
    var h: test_util.Harness = undefined;
    try h.init(&.{}, .{});
    defer h.deinit();
    const la = h.client.doc("cities/LA");
    try testing.expectError(error.InvalidArgument, la.set(&.{.{ .name = "a", .value = .{ .array = &.{.{ .array = &.{} }} } }}, .{}));
    try h.expectDiag("invalid field a: an array holds an array");
    try testing.expectError(error.InvalidArgument, la.set(&.{.{ .name = "t", .value = .{ .timestamp = .{ .nanoseconds = std.math.maxInt(i96) } } }}, .{}));
    try testing.expectError(error.InvalidArgument, la.set(&.{}, .{ .precondition = .{ .update_time = .{ .nanoseconds = std.math.maxInt(i96) } } }));
    try h.expectDiag("precondition's update time");
    try h.expectRequestCount(0);
}

test "a response that does not decode is InvalidResponse, said in the diagnostics" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = "{\"name\":\"x\"}" } },
        .{ .respond = .{ .body = "not json" } },
        // A commit of one write that answers for two, or for none.
        .{ .respond = .{ .body = "{\"writeResults\":[{},{}],\"commitTime\":\"2026-10-04T22:42:59Z\"}" } },
        .{ .respond = .{ .body = "{\"commitTime\":\"2026-10-04T22:42:59Z\"}" } },
    }, .{});
    defer h.deinit();
    try testing.expectError(error.InvalidResponse, h.client.doc("c/x").get(.{}));
    try h.expectDiag("the document response could not be decoded");
    try testing.expectError(error.InvalidResponse, h.client.doc("c/x").set(&.{}, .{}));
    try h.expectDiag("the commit response could not be decoded");
    try testing.expectError(error.InvalidResponse, h.client.doc("c/x").set(&.{}, .{}));
    try testing.expectError(error.InvalidResponse, h.client.doc("c/x").delete(.{}));
}

test "get, set, update and delete: every allocation failure is OutOfMemory without leaks" {
    const Run = struct {
        fn run(gpa: Allocator) !void {
            var fake: test_util.FakeTransport = .init(testing.allocator, &.{
                .{ .respond = .{ .body = test_util.docBody("cities/LA", "{\"a\":{\"mapValue\":{\"fields\":{\"b\":{\"arrayValue\":{\"values\":[{\"integerValue\":\"1\"},{\"bytesValue\":\"AP_-\"}]}}}}}}") } },
                .{ .respond = .{ .body = test_util.commit_body } },
                .{ .respond = .{ .body = test_util.commit_body } },
                .{ .respond = .{ .body = test_util.delete_body } },
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
            const la = client.collection("cities").doc("LA");
            var got = try la.get(.{ .mask = &.{"a"} });
            got.deinit();
            _ = try la.set(&.{.{ .name = "a", .value = .{ .map = &.{.{ .name = "b-c", .value = .{ .integer = 1 } }} } }}, .{});
            _ = try la.update(&.{.{ .name = "x", .value = .{ .string = "y" } }}, .{ .mask = &.{ "x", "gone" } });
            try la.delete(.{ .precondition = .{ .exists = true } });
        }
    };
    try testing.checkAllAllocationFailures(test_util.no_grow_allocator, Run.run, .{});
}
