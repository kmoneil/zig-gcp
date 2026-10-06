//! A handle for one collection: create documents in it, list them, and
//! reach each by id. Cheap to copy; it borrows its client and the strings
//! its path was built from, and sends nothing until a call.

const Collection = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const core = @import("core");

const Client = @import("Client.zig");
const Document = @import("Document.zig");
const codec = @import("codec.zig");
const errors = @import("errors.zig");
const names = @import("names.zig");
const rpc = @import("rpc.zig");
const types = @import("types.zig");
const validate = @import("validate.zig");
const Error = errors.Error;
const Params = core.query.Params;

client: *Client,
path: names.Path,

/// The length of an id `create` chooses, as Google's clients choose them.
pub const auto_id_len = 20;

/// The collection's own id: the last segment of its path.
pub fn id(self: Collection) []const u8 {
    return self.path.last();
}

/// A handle for the document `document_id` in this collection.
pub fn doc(self: Collection, document_id: []const u8) Document {
    return .{ .client = self.client, .path = self.path.child(document_id) };
}

/// Creates a document in this collection and returns it as stored. An
/// existing document of the same id is `error.AlreadyExists`. Without
/// `options.document_id`, this picks a random id of 20 letters and digits
/// first, as Google's clients do, rather than leave it to the server, so
/// a create whose answer was lost can be sent again under the same id: a
/// repeat then meets its own earlier attempt, and reads that document
/// back instead of failing.
pub fn create(self: Collection, fields: []const types.Field, options: types.CreateOptions) Error!types.Owned(types.Snapshot) {
    const client = self.client;
    rpc.begin(client);
    var scratch: std.heap.ArenaAllocator = .init(client.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const path = try rpc.checkedPath(client, a, self.path, .collection);
    var auto_buf: [auto_id_len]u8 = undefined;
    const document_id = options.document_id orelse autoId(client.io, &auto_buf);
    if (validate.idProblem(document_id)) |problem| {
        return rpc.refuse(client, error.InvalidResourceId, "invalid document id: {s}", .{problem});
    }
    try rpc.checkFields(client, fields);
    // The collection's path and the id were checked, so this is a
    // document's path, at most 100 segments deep; only its length is new.
    const document_path = try std.fmt.allocPrint(a, "{s}/{s}", .{ path, document_id });
    if (document_path.len + client.name_prefix_len > validate.max_name_bytes) {
        return rpc.refuse(client, error.InvalidResourceId, "invalid document path: the full name is over 6 KiB", .{});
    }
    try rpc.checkDocumentSize(client, document_path, fields);
    const url = writeCreateUrl(a, client, path, document_id) catch return error.OutOfMemory;
    const body = try codec.encodeDocument(a, fields);

    var result: types.Owned(types.Snapshot) = try .init(client.gpa);
    errdefer result.deinit();
    const precondition: types.Precondition = .{ .exists = false };
    const reply = rpc.executeWrite(client, result.arena, .{ .method = .POST, .path = url, .body = body }, precondition) catch |err| reply: {
        // A random id of 20 of 62 characters is taken only by this call's
        // own earlier attempt, whose answer was lost: that document is the
        // create's result.
        if (err == error.AlreadyExists and options.document_id == null and client.retry.max_attempts > 1) {
            rpc.begin(client);
            const read_url = writeReadUrl(a, client, document_path) catch return error.OutOfMemory;
            break :reply try rpc.execute(client, result.arena, .{ .method = .GET, .path = read_url });
        }
        return err;
    };
    result.value = codec.decodeSnapshot(result.arena.allocator(), reply) catch |err|
        return rpc.decodeFailed(client, err, "document");
    return result;
}

/// One page of the documents in this collection, by name unless
/// `options.order_by` says otherwise. Documents in its subcollections are
/// not listed, and neither are missing documents that only have
/// subcollections of their own.
pub fn list(self: Collection, options: types.ListOptions) Error!types.Owned(types.SnapshotPage) {
    const client = self.client;
    rpc.begin(client);
    var scratch: std.heap.ArenaAllocator = .init(client.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const path = try rpc.checkedPath(client, a, self.path, .collection);
    if (options.mask) |m| try rpc.checkMask(client, m, "read mask");
    for (options.order_by) |o| if (names.fieldPathProblem(o.field)) |problem| {
        return rpc.refuse(client, error.InvalidResourceId, "invalid field path in the order: {s}", .{problem});
    };
    const url = writeListUrl(a, client, path, options) catch return error.OutOfMemory;

    var result: types.Owned(types.SnapshotPage) = try .init(client.gpa);
    errdefer result.deinit();
    const body = try rpc.execute(client, result.arena, .{ .method = .GET, .path = url });
    result.value = codec.decodeSnapshotPage(result.arena.allocator(), body) catch |err|
        return rpc.decodeFailed(client, err, "document list");
    return result;
}

/// 20 characters of `[A-Za-z0-9]`, drawn evenly from `io`'s randomness.
fn autoId(io: std.Io, buf: *[auto_id_len]u8) []const u8 {
    const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
    var n: usize = 0;
    while (n < buf.len) {
        var bytes: [32]u8 = undefined;
        io.random(&bytes);
        for (bytes) |b| {
            // 248 is the largest multiple of 62 a byte holds: anything
            // above it is drawn again, so every character is as likely.
            if (b >= 248) continue;
            buf[n] = alphabet[b % alphabet.len];
            n += 1;
            if (n == buf.len) break;
        }
    }
    return buf;
}

fn writeCreateUrl(a: Allocator, client: *const Client, path: []const u8, document_id: []const u8) Writer.Error![]const u8 {
    var out: Writer.Allocating = .init(a);
    const w = &out.writer;
    try names.writeDocumentsPath(w, client.project_id, client.database_id, path);
    var params: Params = .init(w);
    try params.add("documentId", document_id);
    return out.written();
}

fn writeReadUrl(a: Allocator, client: *const Client, document_path: []const u8) Writer.Error![]const u8 {
    var out: Writer.Allocating = .init(a);
    try names.writeDocumentsPath(&out.writer, client.project_id, client.database_id, document_path);
    return out.written();
}

fn writeListUrl(a: Allocator, client: *const Client, path: []const u8, options: types.ListOptions) Writer.Error![]const u8 {
    var out: Writer.Allocating = .init(a);
    const w = &out.writer;
    try names.writeDocumentsPath(w, client.project_id, client.database_id, path);
    var params: Params = .init(w);
    try params.addNonZero("pageSize", options.page_size);
    try params.addOptional("pageToken", options.page_token);
    if (options.order_by.len > 0) {
        var order: Writer.Allocating = .init(a);
        for (options.order_by, 0..) |o, i| {
            if (i > 0) try order.writer.writeAll(", ");
            try order.writer.writeAll(o.field);
            if (o.direction == .descending) try order.writer.writeAll(" desc");
        }
        try params.add("orderBy", order.written());
    }
    if (options.mask) |m| try rpc.addMask(&params, "mask.fieldPaths", m);
    return out.written();
}

const testing = std.testing;
const test_util = @import("test_util.zig");
const base = test_util.base;

test "golden: create with an id, and the document as stored" {
    var h: test_util.Harness = undefined;
    try h.init(&.{.{ .respond = .{ .body = test_util.docBody("cities/LA", "{\"name\":{\"stringValue\":\"Los Angeles\"}}") } }}, .{});
    defer h.deinit();
    var made = try h.client.collection("cities").create(&.{.{ .name = "name", .value = .{ .string = "Los Angeles" } }}, .{ .document_id = "LA" });
    defer made.deinit();
    try h.expectRequest(0, .POST, base ++ "/cities?documentId=LA", "{\"fields\":{\"name\":{\"stringValue\":\"Los Angeles\"}}}");
    try testing.expectEqualStrings("LA", made.value.id());
    try testing.expectEqualStrings("Los Angeles", made.value.get("name").?.string);
}

test "create: an id of its own, 20 letters and digits, sent with the request" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = test_util.docBody("cities/LA/landmarks/x", "{}") } },
        .{ .respond = .{ .body = test_util.docBody("cities/LA/landmarks/x", "{}") } },
    }, .{});
    defer h.deinit();
    const landmarks = h.client.doc("cities/LA").collection("landmarks");
    var first = try landmarks.create(&.{}, .{});
    defer first.deinit();
    var second = try landmarks.create(&.{}, .{});
    defer second.deinit();
    const prefix = base ++ "/cities/LA/landmarks?documentId=";
    var ids: [2][]const u8 = undefined;
    for (0..2) |i| {
        const r = try h.fake.request(i);
        try testing.expect(std.mem.startsWith(u8, r.url, prefix));
        ids[i] = r.url[prefix.len..];
        try testing.expectEqual(auto_id_len, ids[i].len);
        for (ids[i]) |c| try testing.expect(std.ascii.isAlphanumeric(c));
    }
    try testing.expect(!std.mem.eql(u8, ids[0], ids[1]));
}

test "autoId: every character as likely, and only the 62" {
    var clock: test_util.FakeClock = .{};
    var counts: [256]u32 = @splat(0);
    var buf: [auto_id_len]u8 = undefined;
    for (0..3100) |_| for (autoId(clock.io(), &buf)) |c| {
        counts[c] += 1;
    };
    var used: usize = 0;
    for (counts, 0..) |n, c| {
        if (n == 0) continue;
        used += 1;
        try testing.expect(std.ascii.isAlphanumeric(@intCast(c)));
        // 62,000 draws over 62 characters: 1,000 each, give or take.
        try testing.expect(n > 850 and n < 1150);
    }
    try testing.expectEqual(62, used);
}

test "create: a lost answer's own document is read back, under a chosen id it is AlreadyExists" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        // The first attempt landed but its answer did not arrive.
        .{ .respond = .{ .status = 503, .body = "{\"error\":{\"code\":503,\"message\":\"unavailable\",\"status\":\"UNAVAILABLE\"}}" } },
        .{ .respond = .{ .status = 409, .body = "{\"error\":{\"code\":409,\"message\":\"Document already exists\",\"status\":\"ALREADY_EXISTS\"}}" } },
        .{ .respond = .{ .body = test_util.docBody("cities/auto", "{\"v\":{\"integerValue\":\"1\"}}") } },
        // And under a chosen id, where the server's id could be anyone's.
        .{ .respond = .{ .status = 503, .body = "{\"error\":{\"code\":503,\"message\":\"unavailable\",\"status\":\"UNAVAILABLE\"}}" } },
        .{ .respond = .{ .status = 409, .body = "{\"error\":{\"code\":409,\"message\":\"Document already exists\",\"status\":\"ALREADY_EXISTS\"}}" } },
    }, .{});
    defer h.deinit();
    const cities = h.client.collection("cities");
    var made = try cities.create(&.{.{ .name = "v", .value = .{ .integer = 1 } }}, .{});
    defer made.deinit();
    try testing.expectEqual(1, made.value.get("v").?.integer);
    const create_url = (try h.fake.request(0)).url;
    const auto = create_url[create_url.len - auto_id_len ..];
    try testing.expectEqualStrings(create_url, (try h.fake.request(1)).url);
    const read_url = (try h.fake.request(2)).url;
    try testing.expectEqual(core.transport.Method.GET, (try h.fake.request(2)).method);
    try testing.expect(std.mem.endsWith(u8, read_url, auto));

    try testing.expectError(error.AlreadyExists, cities.create(&.{}, .{ .document_id = "LA" }));
    try h.expectDiag("an earlier attempt may have landed");
    try h.expectRequestCount(5);
}

test "create refuses bad ids and paths before anything is sent" {
    var h: test_util.Harness = undefined;
    try h.init(&.{}, .{});
    defer h.deinit();
    // A collection path within 6 KiB, 4,659 bytes as a full name, whose
    // new document is not: 6,160.
    const long = test_util.repeat("i", 1500);
    const collection = "c/" ++ long ++ "/c/" ++ long ++ "/c/" ++ long ++ "/" ++ test_util.repeat("c", 100);
    try testing.expectError(error.InvalidResourceId, h.client.collection(collection).create(&.{}, .{ .document_id = long }));
    try h.expectDiag("6 KiB");
    try testing.expectError(error.InvalidResourceId, h.client.collection("cities").create(&.{}, .{ .document_id = "a/b" }));
    try h.expectDiag("invalid document id");
    try testing.expectError(error.InvalidResourceId, h.client.collection("cities").create(&.{}, .{ .document_id = "__x__" }));
    try testing.expectError(error.InvalidResourceId, h.client.collection("cities/LA").create(&.{}, .{}));
    try h.expectDiag("odd number of segments");
    try testing.expectError(error.InvalidArgument, h.client.collection("cities").create(&.{.{ .name = "", .value = .null }}, .{}));
    try h.expectRequestCount(0);
}

test "golden: list pages, orders and masks" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body =
        \\{"documents":[{"name":"projects/extractctl/databases/(default)/documents/cities/LA","createTime":"2026-10-04T22:42:59.495496Z","updateTime":"2026-10-04T22:42:59.495496Z"}],
        \\ "nextPageToken":"Ci5w+/="}
        } },
        .{ .respond = .{ .body = "{}" } },
    }, .{});
    defer h.deinit();
    const cities = h.client.collection("cities");
    var first = try cities.list(.{
        .page_size = 1,
        .order_by = &.{ .{ .field = "population", .direction = .descending }, .{ .field = "__name__" } },
        .mask = &.{"__name__"},
    });
    defer first.deinit();
    try h.expectRequest(0, .GET, base ++ "/cities?pageSize=1&orderBy=population%20desc%2C%20__name__&mask.fieldPaths=__name__", null);
    try testing.expectEqualStrings("LA", first.value.documents[0].id());
    var second = try cities.list(.{ .page_token = first.value.next_page_token });
    defer second.deinit();
    try h.expectRequest(1, .GET, base ++ "/cities?pageToken=Ci5w%2B%2F%3D", null);
    try testing.expectEqual(0, second.value.documents.len);
    try testing.expectEqual(null, second.value.next_page_token);

    try testing.expectError(error.InvalidResourceId, cities.list(.{ .order_by = &.{.{ .field = "a-b" }} }));
    try h.expectDiag("in the order");
    try testing.expectError(error.InvalidResourceId, h.client.collection("cities/LA").list(.{}));
}

test "create and list: every allocation failure is OutOfMemory without leaks" {
    const Run = struct {
        fn run(gpa: Allocator) !void {
            var fake: test_util.FakeTransport = .init(testing.allocator, &.{
                .{ .respond = .{ .body = test_util.docBody("cities/LA", "{\"a\":{\"stringValue\":\"b\"}}") } },
                .{ .respond = .{ .body = "{\"documents\":[" ++ test_util.docBody("cities/LA", "{}") ++ "],\"nextPageToken\":\"t\"}" } },
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
            var made = try client.collection("cities").create(&.{.{ .name = "a", .value = .{ .string = "b" } }}, .{});
            made.deinit();
            var page = try client.collection("cities").list(.{ .order_by = &.{.{ .field = "a" }}, .mask = &.{"a"} });
            page.deinit();
        }
    };
    try testing.checkAllAllocationFailures(test_util.no_grow_allocator, Run.run, .{});
}
