//! `batchGet`: many documents in one request, answered as one JSON array
//! of stream messages in no particular order, a name asked twice answered
//! once. The answer is laid back out in the order asked, matched by each
//! document's path below the database, so a server that answers names
//! with its project number instead of its id still matches.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const Client = @import("Client.zig");
const codec = @import("codec.zig");
const errors = @import("errors.zig");
const names = @import("names.zig");
const rpc = @import("rpc.zig");
const types = @import("types.zig");
const Error = errors.Error;

/// Reads the documents at `paths` into `response`. The call has begun.
pub fn batchGet(
    client: *Client,
    paths: []const []const u8,
    options: types.BatchGetOptions,
    response: *std.heap.ArenaAllocator,
) Error!types.BatchGetResult {
    if (options.mask) |m| try rpc.checkMask(client, m, "read mask");
    if (options.read_time) |t| try rpc.checkTime(client, t, "read time");
    try rpc.checkTransaction(client, options.transaction, options.read_time);
    if (paths.len == 0) return .{ .documents = &.{}, .read_time = null };

    var scratch: std.heap.ArenaAllocator = .init(client.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const checked = try a.alloc([]const u8, paths.len);
    const full_names = try a.alloc([]const u8, paths.len);
    // Each distinct path's first position, which the answer fills.
    var first: std.StringHashMapUnmanaged(usize) = .empty;
    for (paths, checked, full_names, 0..) |p, *c, *n, i| {
        c.* = try rpc.checkedPath(client, a, .init(p), .document);
        n.* = try client.documentName(a, c.*);
        const entry = try first.getOrPut(a, c.*);
        if (!entry.found_existing) entry.value_ptr.* = i;
    }
    const url = writeUrl(a, client) catch return error.OutOfMemory;
    const body = try codec.encodeBatchGet(a, full_names, options);

    // A read: asking again is harmless.
    const reply = try rpc.execute(client, response, .{ .method = .POST, .path = url, .body = body });
    const elements = codec.decodeBatchGet(response.allocator(), reply) catch |err|
        return rpc.decodeFailed(client, err, "batchGet");

    const documents = try response.allocator().alloc(?types.Snapshot, paths.len);
    const answered = try a.alloc(bool, paths.len);
    @memset(answered, false);
    var read_time: ?std.Io.Timestamp = null;
    for (elements) |e| {
        if (e.read_time) |t| read_time = t;
        const name = if (e.found) |f| f.name else e.missing orelse continue;
        const path = names.relativePath(name) orelse return rpc.decodeFailed(client, error.InvalidResponse, "batchGet");
        // A document nobody asked for is no answer to anything here.
        const i = first.get(path) orelse continue;
        documents[i] = e.found;
        answered[i] = true;
    }
    for (checked, 0..) |c, i| {
        const j = first.get(c).?;
        if (!answered[j]) {
            if (client.diagnostics) |d| d.print("the batchGet answer said nothing of {s}", .{c});
            return error.InvalidResponse;
        }
        documents[i] = documents[j];
    }
    return .{ .documents = documents, .read_time = read_time orelse return rpc.decodeFailed(client, error.InvalidResponse, "batchGet") };
}

fn writeUrl(a: Allocator, client: *const Client) Writer.Error![]const u8 {
    var out: Writer.Allocating = .init(a);
    try names.writeDocumentsPath(&out.writer, client.project_id, client.database_id, "");
    try out.writer.writeAll(":batchGet");
    return out.written();
}

const testing = std.testing;
const test_util = @import("test_util.zig");
const batch_url = test_util.base ++ ":batchGet";

inline fn found(comptime path: []const u8) []const u8 {
    return "{\"found\":" ++ test_util.docBody(path, "{\"id\":{\"stringValue\":\"" ++ path ++ "\"}}") ++ ",\"readTime\":\"2026-10-05T12:15:42.619554Z\"}";
}

inline fn missing(comptime path: []const u8) []const u8 {
    return "{\"missing\":\"" ++ test_util.name(path) ++ "\",\"readTime\":\"2026-10-05T12:15:42.619554Z\"}";
}

test "golden: batchGet lays the answer out in the order asked, twice where asked twice" {
    var h: test_util.Harness = undefined;
    // Out of order, the duplicate answered once, as the server may.
    try h.init(&.{.{ .respond = .{ .body = "[\n" ++ found("c/a") ++ ",\n" ++ missing("c/nope") ++ ",\n" ++ found("c/two") ++ "\n]\n" } }}, .{});
    defer h.deinit();
    var r = try h.client.batchGet(&.{ "c/two", "c/nope", "c/a", "c/two" }, .{});
    defer r.deinit();
    try h.expectRequest(0, .POST, batch_url, "{\"documents\":[\"" ++ test_util.name("c/two") ++ "\",\"" ++ test_util.name("c/nope") ++ "\",\"" ++ test_util.name("c/a") ++ "\",\"" ++ test_util.name("c/two") ++ "\"]}");
    const docs = r.value.documents;
    try testing.expectEqual(4, docs.len);
    try testing.expectEqualStrings("c/two", docs[0].?.get("id").?.string);
    try testing.expectEqual(null, docs[1]);
    try testing.expectEqualStrings("c/a", docs[2].?.get("id").?.string);
    try testing.expectEqualStrings("c/two", docs[3].?.get("id").?.string);
    try testing.expectEqual(1_791_202_542_619_554_000, r.value.read_time.?.nanoseconds);
}

test "golden: batchGet with a mask and a read time; nothing asked sends nothing" {
    var h: test_util.Harness = undefined;
    try h.init(&.{.{ .respond = .{ .body = "[" ++ found("c/a") ++ "]" } }}, .{ .database_id = "zigps-fs-1" });
    defer h.deinit();
    var r = try h.client.batchGet(&.{"c/a"}, .{ .mask = &.{ "id", "`a-b`" }, .read_time = .{ .nanoseconds = 1_791_202_542_000_000_000 } });
    defer r.deinit();
    try h.expectRequest(0, .POST, "https://firestore.googleapis.com/v1/projects/extractctl/databases/zigps-fs-1/documents:batchGet",
        \\{"documents":["projects/extractctl/databases/zigps-fs-1/documents/c/a"],"mask":{"fieldPaths":["id","`a-b`"]},"readTime":"2026-10-05T12:15:42Z"}
    );
    // Matched by path: the answer's database prefix does not matter.
    try testing.expect(r.value.documents[0] != null);
    var none = try h.client.batchGet(&.{}, .{});
    defer none.deinit();
    try testing.expectEqual(0, none.value.documents.len);
    try testing.expectEqual(null, none.value.read_time);
    try h.expectRequestCount(1);
}

test "batchGet: an answer that leaves a document out, or reads wrong, is InvalidResponse" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = "[" ++ found("c/a") ++ "]" } },
        .{ .respond = .{ .body = "{\"found\":{}}" } },
        .{ .respond = .{ .body = "[{\"found\":{\"name\":\"no-documents-here\",\"createTime\":\"2026-10-05T12:15:42Z\",\"updateTime\":\"2026-10-05T12:15:42Z\"}}]" } },
        .{ .respond = .{ .body = "[{\"missing\":\"" ++ test_util.name("c/a") ++ "\"}]" } },
        // An element for a document nobody asked for is passed over.
        .{ .respond = .{ .body = "[" ++ missing("c/other") ++ "," ++ found("c/a") ++ "]" } },
        // Neither found nor missing: a message with only a read time.
        .{ .respond = .{ .body = "[{\"readTime\":\"2026-10-05T12:15:42Z\"}," ++ found("c/a") ++ "]" } },
        .{ .respond = .{ .body = "[{\"found\":" ++ test_util.docBody("c/a", "{}") ++ ",\"missing\":\"x\"}]" } },
    }, .{});
    defer h.deinit();
    try testing.expectError(error.InvalidResponse, h.client.batchGet(&.{ "c/a", "c/b" }, .{}));
    try h.expectDiag("said nothing of c/b");
    try testing.expectError(error.InvalidResponse, h.client.batchGet(&.{"c/a"}, .{}));
    try h.expectDiag("the batchGet response could not be decoded");
    try testing.expectError(error.InvalidResponse, h.client.batchGet(&.{"c/a"}, .{}));
    // No read time anywhere in the answer.
    try testing.expectError(error.InvalidResponse, h.client.batchGet(&.{"c/a"}, .{}));
    var extra = try h.client.batchGet(&.{"c/a"}, .{});
    extra.deinit();
    var bare = try h.client.batchGet(&.{"c/a"}, .{});
    bare.deinit();
    try testing.expectError(error.InvalidResponse, h.client.batchGet(&.{"c/a"}, .{}));
}

test "batchGet refuses bad paths and masks before anything is sent" {
    var h: test_util.Harness = undefined;
    try h.init(&.{}, .{});
    defer h.deinit();
    try testing.expectError(error.InvalidResourceId, h.client.batchGet(&.{ "c/a", "c" }, .{}));
    try h.expectDiag("even number of segments");
    try testing.expectError(error.InvalidResourceId, h.client.batchGet(&.{"c/a"}, .{ .mask = &.{"a-b"} }));
    try testing.expectError(error.InvalidArgument, h.client.batchGet(&.{"c/a"}, .{ .read_time = .{ .nanoseconds = std.math.minInt(i96) } }));
    try h.expectRequestCount(0);
}

test "golden: get at a read time goes through batchGet; missing then is NotFound" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = "[" ++ found("cities/LA") ++ "]" } },
        .{ .respond = .{ .body = "[" ++ missing("cities/LA") ++ "]" } },
    }, .{});
    defer h.deinit();
    const la = h.client.doc("cities/LA");
    var got = try la.get(.{ .read_time = .{ .nanoseconds = 1_791_202_542_123_456_000 }, .mask = &.{"id"} });
    defer got.deinit();
    try h.expectRequest(0, .POST, batch_url, "{\"documents\":[\"" ++ test_util.name("cities/LA") ++ "\"],\"mask\":{\"fieldPaths\":[\"id\"]},\"readTime\":\"2026-10-05T12:15:42.123456Z\"}");
    try testing.expectEqualStrings("cities/LA", got.value.get("id").?.string);
    try testing.expectError(error.NotFound, la.get(.{ .read_time = .{ .nanoseconds = 1_791_202_542_000_000_000 } }));
    try h.expectDiag("did not exist at the read time");
}

test "batchGet: every allocation failure is OutOfMemory without leaks" {
    const Run = struct {
        fn run(gpa: Allocator) !void {
            var fake: test_util.FakeTransport = .init(testing.allocator, &.{
                .{ .respond = .{ .body = "[" ++ found("c/b") ++ "," ++ missing("c/a") ++ "]" } },
                .{ .respond = .{ .body = "[" ++ found("c/b") ++ "]" } },
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
            var r = try client.batchGet(&.{ "c/a", "c/b", "c/a" }, .{ .mask = &.{"id"} });
            r.deinit();
            var one = try client.doc("c/b").get(.{ .read_time = .{ .nanoseconds = 1_791_202_542_000_000_000 } });
            one.deinit();
        }
    };
    try testing.checkAllAllocationFailures(test_util.no_grow_allocator, Run.run, .{});
}
