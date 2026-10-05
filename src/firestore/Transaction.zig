//! A transaction as `Client.runTransaction` hands it to a handler: reads
//! that join it, and writes kept until the handler returns, then committed
//! together. A read does not see the transaction's own writes, which are
//! not sent until the end, as in every Firestore client.
//!
//! The run loop follows Google's clients where they agree, and fixes where
//! two of them are recorded as wrong: at most `max_attempts` runs (5 by
//! default), run again only when the server answers ABORTED, as Go and
//! Python do; each new attempt names the last transaction as the one it
//! retries, which keeps its place in line for locks; the client's retry
//! policy spaces the attempts out; and every failure rolls the transaction
//! back, a failed commit included (Go skips that, and holds locks until
//! they expire). A read-only transaction runs once. Measured on the
//! emulator (2026-10-05), contention shows as ABORTED: a commit waits for
//! a lock about 2 s, then answers "Transaction lock timeout.".

const Transaction = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("core");

const Client = @import("Client.zig");
const batch_get = @import("batch_get.zig");
const codec = @import("codec.zig");
const errors = @import("errors.zig");
const logging = @import("logging.zig");
const names = @import("names.zig");
const query_ = @import("query.zig");
const rpc = @import("rpc.zig");
const types = @import("types.zig");
const writes_ = @import("writes.zig");
const Error = errors.Error;

client: *Client,
/// The transaction's id, as the server gave it.
id: []const u8,
read_only: bool,
/// Holds the writes kept for the commit.
arena: std.heap.ArenaAllocator,
writes: std.ArrayListUnmanaged(types.Write) = .empty,

/// What `Client.runTransaction` runs.
pub const Handler = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Reads through `txn` and writes through it. Runs once per
        /// attempt, from the start each time, so whatever else it does
        /// must bear repeating. Returning an error ends the transaction
        /// with that error, rolled back, unless it is `error.Aborted`,
        /// which runs it again as an ABORTED commit does.
        run: *const fn (ptr: *anyopaque, txn: *Transaction) anyerror!void,
    };

    pub fn run(self: Handler, txn: *Transaction) anyerror!void {
        return self.vtable.run(self.ptr, txn);
    }
};

/// Reads the document at `path` in this transaction. A missing one is
/// `error.NotFound`.
pub fn get(self: *Transaction, path: []const u8, options: struct { mask: ?[]const []const u8 = null }) Error!types.Owned(types.Snapshot) {
    return self.client.doc(path).get(.{ .mask = options.mask, .transaction = self.id });
}

/// Reads the documents at `paths` in this transaction; see
/// `Client.batchGet`.
pub fn batchGet(self: *Transaction, paths: []const []const u8, options: struct { mask: ?[]const []const u8 = null }) Error!types.Owned(types.BatchGetResult) {
    return self.client.batchGet(paths, .{ .mask = options.mask, .transaction = self.id });
}

/// Runs `query` in this transaction; see `Client.runQuery`.
pub fn runQuery(self: *Transaction, query: types.Query) Error!types.Owned(types.QueryResult) {
    return self.client.runQuery(query, .{ .transaction = self.id });
}

/// Aggregates over `query` in this transaction; see
/// `Client.runAggregationQuery`.
pub fn runAggregationQuery(self: *Transaction, query: types.Query, aggregations: []const types.Aggregation) Error!types.Owned(types.AggregationResult) {
    return self.client.runAggregationQuery(query, aggregations, .{ .transaction = self.id });
}

/// Keeps `Document.set`'s write for the commit.
pub fn set(self: *Transaction, path: []const u8, fields: []const types.Field, options: types.SetOptions) Error!void {
    return self.write(.{ .update = .{
        .path = path,
        .fields = fields,
        .transforms = options.transforms,
        .precondition = options.precondition,
    } });
}

/// Keeps `Document.update`'s write for the commit.
pub fn update(self: *Transaction, path: []const u8, fields: []const types.Field, options: types.UpdateOptions) Error!void {
    rpc.begin(self.client);
    var scratch: std.heap.ArenaAllocator = .init(self.client.gpa);
    defer scratch.deinit();
    return self.write(try writes_.updateWrite(self.client, scratch.allocator(), path, fields, options));
}

/// Keeps a delete for the commit.
pub fn delete(self: *Transaction, path: []const u8, options: types.DeleteOptions) Error!void {
    return self.write(.{ .delete = .{ .path = path, .precondition = options.precondition } });
}

/// Keeps `w` for the commit, checked now as the commit will check it, and
/// copied: nothing it points to need outlive this call.
pub fn write(self: *Transaction, w: types.Write) Error!void {
    rpc.begin(self.client);
    if (self.read_only) return rpc.refuse(self.client, error.InvalidArgument, "a read-only transaction takes no writes", .{});
    var scratch: std.heap.ArenaAllocator = .init(self.client.gpa);
    defer scratch.deinit();
    try writes_.check(self.client, scratch.allocator(), w);
    try self.writes.append(self.arena.allocator(), try writes_.copyWrite(self.arena.allocator(), w));
}

/// Begins a transaction and returns its id. The call has begun.
pub fn begin(client: *Client, options: types.TransactionOptions, retry: ?[]const u8) Error!types.Owned([]const u8) {
    switch (options) {
        .read_write => {},
        .read_only => |ro| if (ro.read_time) |t| try rpc.checkTime(client, t, "read time"),
    }
    if (retry) |r| try rpc.checkTransaction(client, r, null);
    var scratch: std.heap.ArenaAllocator = .init(client.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const url = verbPath(a, client, ":beginTransaction") catch return error.OutOfMemory;
    const body = try codec.encodeBeginTransaction(a, options, retry);
    var result: types.Owned([]const u8) = try .init(client.gpa);
    errdefer result.deinit();
    // A transaction begun twice is two transactions, the first idle until
    // it expires: harmless, as reads are.
    const reply = try rpc.execute(client, result.arena, .{ .method = .POST, .path = url, .body = body });
    result.value = codec.decodeBeginTransaction(result.arena.allocator(), reply) catch |err|
        return rpc.decodeFailed(client, err, "beginTransaction");
    return result;
}

/// Rolls a transaction back. The call has begun.
pub fn rollback(client: *Client, transaction: []const u8) Error!void {
    try rpc.checkTransaction(client, transaction, null);
    var scratch: std.heap.ArenaAllocator = .init(client.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const url = verbPath(a, client, ":rollback") catch return error.OutOfMemory;
    return rpc.executeDiscard(client, .{ .method = .POST, .path = url, .body = try codec.encodeRollback(a, transaction) });
}

fn verbPath(a: Allocator, client: *const Client, verb: []const u8) std.Io.Writer.Error![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    try names.writeDocumentsPath(&out.writer, client.project_id, client.database_id, "");
    try out.writer.writeAll(verb);
    return out.written();
}

/// Rolls back after a failure, keeping the failure's diagnostics: the
/// rollback's own outcome is only logged.
fn rollbackQuietly(client: *Client, transaction: []const u8) void {
    var quiet = client.*;
    quiet.diagnostics = null;
    rollback(&quiet, transaction) catch |err| {
        logging.debug("rollback after a failed transaction failed with {t}", .{err});
    };
}

/// The run loop; see the top of this file.
pub fn run(client: *Client, handler: Handler, options: types.RunTransactionOptions) anyerror!void {
    rpc.begin(client);
    if (options.max_attempts == 0) return rpc.refuse(client, error.InvalidOptions, "a transaction runs at least once: max_attempts is 0", .{});
    if (options.read_time != null and !options.read_only) {
        return rpc.refuse(client, error.InvalidOptions, "only a read-only transaction reads at a past time", .{});
    }
    const begin_options: types.TransactionOptions = if (options.read_only) .{ .read_only = .{ .read_time = options.read_time } } else .read_write;
    var previous: ?[]u8 = null;
    defer if (previous) |p| client.gpa.free(p);

    var attempt: u32 = 1;
    while (true) : (attempt += 1) {
        rpc.begin(client);
        var begun = try begin(client, begin_options, previous);
        defer begun.deinit();
        var txn: Transaction = .{
            .client = client,
            .id = begun.value,
            .read_only = options.read_only,
            .arena = .init(client.gpa),
        };
        defer txn.arena.deinit();

        const outcome: anyerror!void = attempt: {
            handler.run(&txn) catch |err| break :attempt err;
            if (txn.writes.items.len == 0) {
                // Nothing to commit: end it, freeing what it holds.
                rpc.begin(client);
                rollback(client, txn.id) catch |err| break :attempt err;
                return;
            }
            rpc.begin(client);
            var response: std.heap.ArenaAllocator = .init(client.gpa);
            defer response.deinit();
            _ = writes_.commit(client, txn.writes.items, txn.id, &response) catch |err| break :attempt err;
            return;
        };
        const err = if (outcome) |_| unreachable else |e| e;
        rollbackQuietly(client, txn.id);
        if (err != error.Aborted or options.read_only or attempt >= options.max_attempts) return err;
        logging.debug("transaction aborted on attempt {d} of {d}; running it again", .{ attempt, options.max_attempts });
        if (previous) |p| client.gpa.free(p);
        previous = try client.gpa.dupe(u8, txn.id);
        try client.io.sleep(.fromMilliseconds(client.retry.backoffMs(attempt, core.rpc.entropy(client.io))), .awake);
    }
}

const testing = std.testing;
const test_util = @import("test_util.zig");
const base = test_util.base;
const id1 = "EQIAAAAAAAAA";
const id2 = "ERAAAAAAAAAA";
const begun1: test_util.FakeTransport.Reply = .{ .respond = .{ .body = "{\"transaction\":\"" ++ id1 ++ "\"}" } };
const begun2: test_util.FakeTransport.Reply = .{ .respond = .{ .body = "{\"transaction\":\"" ++ id2 ++ "\"}" } };
const read_a: test_util.FakeTransport.Reply = .{ .respond = .{ .body = "[{\"found\":" ++ test_util.docBody("c/a", "{\"n\":{\"integerValue\":\"1\"}}") ++ ",\"readTime\":\"2026-10-05T13:22:13Z\"}]" } };
const aborted: test_util.FakeTransport.Reply = .{ .respond = .{ .status = 409, .body = "{\"error\":{\"code\":409,\"message\":\"Transaction lock timeout.\",\"status\":\"ABORTED\"}}" } };
const empty_ok: test_util.FakeTransport.Reply = .{ .respond = .{ .body = "{}" } };

/// Reads c/a and writes its n plus one to c/a; counts its runs.
const Increment = struct {
    runs: u32 = 0,
    fail_with: ?anyerror = null,

    fn handler(self: *Increment) Handler {
        return .{ .ptr = self, .vtable = &.{ .run = run_ } };
    }

    fn run_(ptr: *anyopaque, txn: *Transaction) anyerror!void {
        const self: *Increment = @ptrCast(@alignCast(ptr));
        self.runs += 1;
        var got = try txn.get("c/a", .{});
        defer got.deinit();
        if (self.fail_with) |err| return err;
        // From a buffer this run reuses: the kept write is a copy.
        var buf: [8]u8 = "counted!".*;
        try txn.set("c/a", &.{
            .{ .name = "n", .value = .{ .integer = got.value.get("n").?.integer + 1 } },
            .{ .name = "note", .value = .{ .string = &buf } },
        }, .{});
        @memset(&buf, 'x');
    }
};

test "golden: a transaction that commits on its first run" {
    var h: test_util.Harness = undefined;
    try h.init(&.{ begun1, read_a, .{ .respond = .{ .body = test_util.commit_body } } }, .{});
    defer h.deinit();
    var inc: Increment = .{};
    try h.client.runTransaction(inc.handler(), .{});
    try testing.expectEqual(1, inc.runs);
    try h.expectRequest(0, .POST, base ++ ":beginTransaction", "{\"options\":{\"readWrite\":{}}}");
    try h.expectRequest(1, .POST, base ++ ":batchGet", "{\"documents\":[\"" ++ test_util.name("c/a") ++ "\"],\"transaction\":\"" ++ id1 ++ "\"}");
    try h.expectRequest(2, .POST, base ++ ":commit", "{\"writes\":[{\"update\":{\"name\":\"" ++ test_util.name("c/a") ++ "\",\"fields\":{\"n\":{\"integerValue\":\"2\"},\"note\":{\"stringValue\":\"counted!\"}}}}],\"transaction\":\"" ++ id1 ++ "\"}");
    try h.expectRequestCount(3);
    try testing.expectEqual(0, h.clock.sleep_count);
}

test "golden: ABORTED rolls back, waits, and runs again naming the last transaction" {
    var h: test_util.Harness = undefined;
    try h.init(&.{ begun1, read_a, aborted, empty_ok, begun2, read_a, .{ .respond = .{ .body = test_util.commit_body } } }, .{});
    defer h.deinit();
    var inc: Increment = .{};
    try h.client.runTransaction(inc.handler(), .{});
    try testing.expectEqual(2, inc.runs);
    try h.expectRequest(3, .POST, base ++ ":rollback", "{\"transaction\":\"" ++ id1 ++ "\"}");
    try h.expectRequest(4, .POST, base ++ ":beginTransaction", "{\"options\":{\"readWrite\":{\"retryTransaction\":\"" ++ id1 ++ "\"}}}");
    try testing.expectEqualStrings(base ++ ":commit", (try h.fake.request(6)).url);
    try testing.expect(std.mem.indexOf(u8, (try h.fake.request(6)).body.?, "\"transaction\":\"" ++ id2 ++ "\"") != null);
    try h.expectRequestCount(7);
    try testing.expectEqual(1, h.clock.sleep_count);
}

test "runTransaction: at most max_attempts runs, then the ABORTED stands, said in the diagnostics" {
    var script: [12]test_util.FakeTransport.Reply = undefined;
    for (0..3) |i| {
        script[i * 4 ..][0..4].* = .{ begun1, read_a, aborted, empty_ok };
    }
    var h: test_util.Harness = undefined;
    try h.init(&script, .{});
    defer h.deinit();
    var inc: Increment = .{};
    try testing.expectError(error.Aborted, h.client.runTransaction(inc.handler(), .{ .max_attempts = 3 }));
    try testing.expectEqual(3, inc.runs);
    try h.expectRequestCount(12);
    // The rollback after the last abort kept the abort's words.
    try h.expectDiag("Transaction lock timeout.");
    try testing.expectEqual(2, h.clock.sleep_count);
}

test "runTransaction: a handler's own error rolls back and returns, once; its ABORTED runs again" {
    {
        var h: test_util.Harness = undefined;
        try h.init(&.{ begun1, read_a, empty_ok }, .{});
        defer h.deinit();
        var inc: Increment = .{ .fail_with = error.OutOfStock };
        try testing.expectError(error.OutOfStock, h.client.runTransaction(inc.handler(), .{}));
        try testing.expectEqual(1, inc.runs);
        try h.expectRequest(2, .POST, base ++ ":rollback", "{\"transaction\":\"" ++ id1 ++ "\"}");
    }
    {
        // A read the server answers ABORTED comes back through the handler.
        var h: test_util.Harness = undefined;
        try h.init(&.{ begun1, aborted, empty_ok, begun2, read_a, .{ .respond = .{ .body = test_util.commit_body } } }, .{});
        defer h.deinit();
        var inc: Increment = .{};
        try h.client.runTransaction(inc.handler(), .{});
        try testing.expectEqual(2, inc.runs);
    }
    {
        // A commit answer lost: not sent again, not run again.
        const unavailable: test_util.FakeTransport.Reply = .{ .respond = .{ .status = 503, .body = "{\"error\":{\"code\":503,\"message\":\"unavailable\",\"status\":\"UNAVAILABLE\"}}" } };
        var h: test_util.Harness = undefined;
        try h.init(&.{ begun1, read_a, unavailable, empty_ok }, .{});
        defer h.deinit();
        var inc: Increment = .{};
        try testing.expectError(error.Unavailable, h.client.runTransaction(inc.handler(), .{}));
        try testing.expectEqual(1, inc.runs);
        try h.expectRequestCount(4);
        try h.expectDiag("may or may not have committed");
    }
}

const ReadOnly = struct {
    runs: u32 = 0,
    try_write: bool = false,

    fn handler(self: *ReadOnly) Handler {
        return .{ .ptr = self, .vtable = &.{ .run = run_ } };
    }

    fn run_(ptr: *anyopaque, txn: *Transaction) anyerror!void {
        const self: *ReadOnly = @ptrCast(@alignCast(ptr));
        self.runs += 1;
        var got = try txn.batchGet(&.{"c/a"}, .{});
        got.deinit();
        if (self.try_write) try txn.delete("c/a", .{});
    }
};

test "golden: a read-only transaction reads, ends with a rollback, and never runs again" {
    var h: test_util.Harness = undefined;
    try h.init(&.{ begun1, read_a, empty_ok, begun1, aborted, empty_ok }, .{});
    defer h.deinit();
    var ro: ReadOnly = .{};
    try h.client.runTransaction(ro.handler(), .{ .read_only = true, .read_time = .{ .nanoseconds = 1_791_158_400_000_000_000 } });
    try h.expectRequest(0, .POST, base ++ ":beginTransaction", "{\"options\":{\"readOnly\":{\"readTime\":\"2026-10-05T00:00:00Z\"}}}");
    try h.expectRequest(2, .POST, base ++ ":rollback", "{\"transaction\":\"" ++ id1 ++ "\"}");
    try testing.expectError(error.Aborted, h.client.runTransaction(ro.handler(), .{ .read_only = true }));
    try testing.expectEqual(2, ro.runs);
    try h.expectRequestCount(6);
}

test "runTransaction refuses what cannot run, before beginning" {
    var h: test_util.Harness = undefined;
    try h.init(&.{ begun1, read_a, empty_ok }, .{});
    defer h.deinit();
    var inc: Increment = .{};
    try testing.expectError(error.InvalidOptions, h.client.runTransaction(inc.handler(), .{ .max_attempts = 0 }));
    try testing.expectError(error.InvalidOptions, h.client.runTransaction(inc.handler(), .{ .read_time = .{ .nanoseconds = 0 } }));
    try h.expectDiag("read-only");
    try h.expectRequestCount(0);
    // A write in a read-only transaction is refused when made.
    var ro: ReadOnly = .{ .try_write = true };
    try testing.expectError(error.InvalidArgument, h.client.runTransaction(ro.handler(), .{ .read_only = true }));
    try h.expectDiag("takes no writes");
    try h.expectRequestCount(3);
}

test "golden: the low-level calls, and reads that join a transaction" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        begun1,
        .{ .respond = .{ .body = "{\"transaction\":\"" ++ id2 ++ "\"}" } },
        read_a,
        .{ .respond = .{ .body = "[{\"readTime\":\"2026-10-05T13:22:13Z\",\"done\":true}]" } },
        .{ .respond = .{ .body = test_util.commit_body } },
        empty_ok,
    }, .{});
    defer h.deinit();
    var rw = try h.client.beginTransaction(.read_write);
    defer rw.deinit();
    try testing.expectEqualStrings(id1, rw.value);
    var ro = try h.client.beginTransaction(.{ .read_only = .{} });
    defer ro.deinit();
    try h.expectRequest(1, .POST, base ++ ":beginTransaction", "{\"options\":{\"readOnly\":{}}}");
    var got = try h.client.doc("c/a").get(.{ .transaction = rw.value, .mask = &.{"n"} });
    defer got.deinit();
    try h.expectRequest(2, .POST, base ++ ":batchGet", "{\"documents\":[\"" ++ test_util.name("c/a") ++ "\"],\"mask\":{\"fieldPaths\":[\"n\"]},\"transaction\":\"" ++ id1 ++ "\"}");
    var q = try h.client.runQuery(.{ .from = .{ .collection = "c" } }, .{ .transaction = rw.value });
    defer q.deinit();
    try h.expectRequest(3, .POST, base ++ ":runQuery", "{\"structuredQuery\":{\"from\":[{\"collectionId\":\"c\"}]},\"transaction\":\"" ++ id1 ++ "\"}");
    var c = try h.client.commit(&.{.{ .delete = .{ .path = "c/a" } }}, .{ .transaction = rw.value });
    defer c.deinit();
    try h.expectRequest(4, .POST, base ++ ":commit", "{\"writes\":[{\"delete\":\"" ++ test_util.name("c/a") ++ "\"}],\"transaction\":\"" ++ id1 ++ "\"}");
    try h.client.rollback(ro.value);
    try h.expectRequest(5, .POST, base ++ ":rollback", "{\"transaction\":\"" ++ id2 ++ "\"}");

    // A transaction and a read time together, or a bad id, are refused.
    try testing.expectError(error.InvalidArgument, h.client.doc("c/a").get(.{ .transaction = id1, .read_time = .{ .nanoseconds = 0 } }));
    try h.expectDiag("not both");
    try testing.expectError(error.InvalidArgument, h.client.runQuery(.{ .from = .{ .collection = "c" } }, .{ .transaction = "not base64!" }));
    try testing.expectError(error.InvalidArgument, h.client.batchGet(&.{"c/a"}, .{ .transaction = "" }));
    try testing.expectError(error.InvalidArgument, h.client.rollback("a b"));
    try testing.expectError(error.InvalidArgument, h.client.commit(&.{}, .{ .transaction = id1 }));
    try h.expectDiag("ends with rollback");
    try h.expectRequestCount(6);
}

test "fake: contention aborts a commit, and the run loop wins on its next run" {
    var h: test_util.FakeHarness = undefined;
    try h.init(.{});
    defer h.deinit();
    _ = try h.client.doc("c/a").set(&.{.{ .name = "n", .value = .{ .integer = 1 } }}, .{});
    // On its first run, the handler's read is overtaken by another writer.
    const Racing = struct {
        runs: u32 = 0,
        other: *Client,

        fn run_(ptr: *anyopaque, txn: *Transaction) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.runs += 1;
            var got = try txn.get("c/a", .{});
            defer got.deinit();
            if (self.runs == 1) _ = try self.other.doc("c/a").update(&.{.{ .name = "n", .value = .{ .integer = 100 } }}, .{});
            try txn.update("c/a", &.{.{ .name = "n", .value = .{ .integer = got.value.get("n").?.integer + 1 } }}, .{});
        }
    };
    var racing: Racing = .{ .other = &h.client };
    try h.client.runTransaction(.{ .ptr = &racing, .vtable = &.{ .run = Racing.run_ } }, .{});
    try testing.expectEqual(2, racing.runs);
    var got = try h.client.doc("c/a").get(.{});
    defer got.deinit();
    // The other writer's 100, plus one: no update was lost.
    try testing.expectEqual(101, got.value.get("n").?.integer);
    try testing.expectEqual(2, h.server.begun);
    try testing.expectEqual(1, h.server.commits);
    try testing.expectEqual(1, h.server.rolled_back);

    // Forced aborts, past max_attempts.
    h.server.abort_next_commits = 3;
    var inc: Increment = .{};
    _ = try h.client.doc("c/a").set(&.{.{ .name = "n", .value = .{ .integer = 1 } }}, .{});
    try testing.expectError(error.Aborted, h.client.runTransaction(inc.handler(), .{ .max_attempts = 3 }));
    try testing.expectEqual(3, inc.runs);

    // Over, a transaction refuses reads and commits; unknown, it is invalid.
    var t = try h.client.beginTransaction(.read_write);
    defer t.deinit();
    try h.client.rollback(t.value);
    try testing.expectError(error.Aborted, h.client.doc("c/a").get(.{ .transaction = t.value }));
    try h.expectDiag("expired or is no longer valid");
    try testing.expectError(error.InvalidArgument, h.client.rollback("Zm9vYmFy"));
    try h.expectDiag("Invalid transaction.");
    var ro = try h.client.beginTransaction(.{ .read_only = .{} });
    defer ro.deinit();
    try testing.expectError(error.InvalidArgument, h.client.commit(&.{.{ .delete = .{ .path = "c/a" } }}, .{ .transaction = ro.value }));
    try h.expectDiag("Cannot modify entities in a read-only transaction.");
}

test "runTransaction: every allocation failure is OutOfMemory without leaks" {
    const Run = struct {
        fn run_(gpa: Allocator) !void {
            var server: @import("fake_firestore.zig").FakeFirestore = .init(testing.allocator);
            defer server.deinit();
            var clock: test_util.FakeClock = .{};
            var token: test_util.FakeTokenProvider = .{};
            var client = try Client.init(gpa, clock.io(), .{
                .project_id = "extractctl",
                .token_provider = token.provider(),
                .transport = server.transport(),
            });
            defer client.deinit();
            _ = try client.doc("c/a").set(&.{.{ .name = "n", .value = .{ .integer = 1 } }}, .{});
            server.abort_next_commits = 1;
            var inc: Increment = .{};
            try client.runTransaction(inc.handler(), .{});
        }
    };
    try testing.checkAllAllocationFailures(test_util.no_grow_allocator, Run.run_, .{});
}
