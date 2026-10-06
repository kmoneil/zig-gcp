//! Streamed reads: a request whose answer, one JSON array of messages, is
//! split as it arrives (`core.JsonArraySplitter`), each message decoded
//! from its own bytes and handed on before the next arrives, so an answer
//! of any size is read in the memory of one message.
//!
//! Production flushes each message as it finds it (measured 2026-10-05:
//! 50,000 documents, the first after 0.2 s, one HTTP chunk each), and an
//! error after some, such as a deadline, arrives as one more message
//! inside the 200, which fails the read after the messages before it.
//!
//! Retries: a status, buffered by the engine, retries as any read's does;
//! a connection that drops mid-answer retries only while nothing has been
//! handed to the caller, since a repeat would hand it over again.

const std = @import("std");
const core = @import("core");

const Client = @import("Client.zig");
const codec = @import("codec.zig");
const logging = @import("logging.zig");
const rpc = @import("rpc.zig");

/// The longest message read: a document is at most 1 MiB as Firestore
/// counts it, and written as JSON, escapes and base64 make it at most
/// about six times that.
pub const max_message_bytes = 16 << 20;

/// What a streamed read does with each message of the answer.
pub const Reader = struct {
    ptr: *anyopaque,
    /// Decodes one message and hands on what it holds. A failure it
    /// describes goes in `said`: the engine's own words about the failed
    /// write would otherwise take its place.
    message: *const fn (ptr: *anyopaque, bytes: []const u8, said: *Said) anyerror!void,
    /// Whether anything has been handed to the caller, after which the
    /// answer cannot be read again.
    handed: *const fn (ptr: *anyopaque) bool,
    /// Forgets what the messages so far said, before the answer is read
    /// again.
    reset: *const fn (ptr: *anyopaque) void,
};

/// What a reader says about the failure it returns, kept until the read
/// ends and then put in the client's `Diagnostics`.
pub const Said = struct {
    diagnostics: core.Diagnostics = .{},
    any: bool = false,

    pub fn print(said: *Said, comptime format: []const u8, args: anytype) void {
        said.diagnostics.print(format, args);
        said.any = true;
    }

    /// A message that would not decode, or an error the server sent inside
    /// the answer, returned as `rpc.streamFailed` returns it.
    pub fn failed(said: *Said, err: codec.StreamDecodeError, streamed: ?codec.StreamedError, what: []const u8) anyerror {
        switch (err) {
            error.Streamed => {
                const s = streamed.?;
                logging.debug("{s} answered {d} {s} inside its stream", .{ what, s.code, s.status });
                said.diagnostics.set(s.code, s.status, s.message);
                said.any = true;
                return core.errors.fromResponse(s.code, s.status);
            },
            error.InvalidResponse => {
                said.print("the {s} response could not be decoded", .{what});
                return error.InvalidResponse;
            },
            error.OutOfMemory => return error.OutOfMemory,
        }
    }
};

const State = struct {
    reader: Reader,
    splitter: core.JsonArraySplitter,
    said: Said = .{},

    fn element(ptr: *anyopaque, bytes: []const u8) anyerror!void {
        const self: *State = @ptrCast(@alignCast(ptr));
        return self.reader.message(self.reader.ptr, bytes, &self.said);
    }

    fn restart(ptr: *anyopaque) bool {
        const self: *State = @ptrCast(@alignCast(ptr));
        if (self.reader.handed(self.reader.ptr)) return false;
        self.reader.reset(self.reader.ptr);
        // Messages that handed nothing on, such as a read time alone, are
        // read again with the rest.
        self.splitter.reset();
        self.said = .{};
        return true;
    }
};

/// Posts `body` to `path` and hands each message of the answer to
/// `reader`, within `timeout_ms` in all (0: no limit). `what` names the
/// call in `Diagnostics`. Returns the server's error, the reader's, or the
/// engine's.
pub fn read(client: *Client, path: []const u8, body: []const u8, timeout_ms: u32, reader: Reader, what: []const u8) anyerror!void {
    try rpc.checkRequestSize(client, body.len);
    var state: State = .{ .reader = reader, .splitter = undefined };
    state.splitter = .init(client.gpa, .{ .ptr = &state, .element = State.element }, max_message_bytes);
    defer state.splitter.deinit();
    var response: std.heap.ArenaAllocator = .init(client.gpa);
    defer response.deinit();
    _ = rpc.executeStream(client, &response, .{
        .method = .POST,
        .path = path,
        .content_type = "application/json",
        .body = .{ .segments = &.{body} },
        .sink = .{ .writer = &state.splitter.writer },
        .restart = .{ .ptr = &state, .restart = State.restart },
        .timeout_ms = timeout_ms,
    }) catch |err| {
        if (err != error.WriteFailed) return err;
        // The splitter's writer failed: the framing, a message too long,
        // or what the reader returned.
        const failure = state.splitter.failure orelse return err;
        if (client.diagnostics) |d| {
            if (state.said.any) {
                d.* = state.said.diagnostics;
            } else switch (failure) {
                error.InvalidResponse => d.print("the {s} response could not be decoded", .{what}),
                error.ResponseTooLarge => d.print("a message of the {s} answer is over {d} bytes", .{ what, max_message_bytes }),
                error.OutOfMemory => d.print("out of memory reading the {s} answer", .{what}),
                else => d.print("the handler returned error.{t}", .{failure}),
            }
        }
        return failure;
    };
    state.splitter.finish() catch |err| return rpc.decodeFailed(client, switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidResponse,
    }, what);
}

const testing = std.testing;
const test_util = @import("test_util.zig");
const types = @import("types.zig");

/// Keeps the id of each document it is handed, or `-` for a missing one.
const Collect = struct {
    arena: std.heap.ArenaAllocator,
    ids: std.ArrayList([]const u8) = .empty,
    /// Returns `error.Stop` when handed the document at this index.
    stop_at: ?usize = null,

    fn init() Collect {
        return .{ .arena = .init(testing.allocator) };
    }

    fn deinit(c: *Collect) void {
        c.arena.deinit();
    }

    fn documents(c: *Collect) types.DocumentHandler {
        return .{ .ptr = c, .vtable = &.{ .document = document } };
    }

    fn items(c: *Collect) types.BatchGetHandler {
        return .{ .ptr = c, .vtable = &.{ .item = item } };
    }

    fn keep(c: *Collect, id: []const u8) !void {
        if (c.stop_at == c.ids.items.len) return error.Stop;
        const a = c.arena.allocator();
        try c.ids.append(a, try a.dupe(u8, id));
    }

    fn document(ptr: *anyopaque, snapshot: types.Owned(types.Snapshot)) anyerror!void {
        const c: *Collect = @ptrCast(@alignCast(ptr));
        var s = snapshot;
        defer s.deinit();
        try c.keep(s.value.id());
    }

    fn item(ptr: *anyopaque, it: types.Owned(types.BatchGetItem)) anyerror!void {
        const c: *Collect = @ptrCast(@alignCast(ptr));
        var i = it;
        defer i.deinit();
        try c.keep(if (i.value.document) |d| d.id() else try std.fmt.allocPrint(c.arena.allocator(), "-{s}", .{i.value.path}));
    }

    fn expect(c: *const Collect, expected: []const []const u8) !void {
        testing.expectEqual(expected.len, c.ids.items.len) catch |err| {
            for (c.ids.items) |id| std.debug.print("{s} ", .{id});
            std.debug.print("\n", .{});
            return err;
        };
        for (expected, c.ids.items) |e, got| try testing.expectEqualStrings(e, got);
    }
};

/// A query's document as production streams it, pretty-printed.
inline fn queryDoc(comptime path: []const u8) []const u8 {
    return "{\n  \"document\": " ++ test_util.docBody(path, "{\"n\":{\"integerValue\":\"1\"}}") ++ ",\n  \"readTime\": \"2026-10-05T22:28:44.615753Z\"\n}";
}

const read_ns: i96 = 1_791_239_324_615_753_000;

test "golden: runQueryEach hands each document over as it arrives, as production frames them" {
    var h: test_util.Harness = undefined;
    try h.init(&.{.{ .respond = .{ .body = test_util.streamed(&.{
        "{\"readTime\":\"2026-10-05T22:28:44.615753Z\",\"skippedResults\":2}",
        queryDoc("c/a"),
        queryDoc("c/b"),
    }) } }}, .{});
    defer h.deinit();
    var c: Collect = .init();
    defer c.deinit();
    const end = try h.client.runQueryEach(.{ .from = .{ .collection = "c" }, .offset = 2 }, .{}, c.documents());
    try c.expect(&.{ "a", "b" });
    try testing.expectEqual(2, end.documents);
    try testing.expectEqual(2, end.skipped_results);
    try testing.expectEqual(read_ns, end.read_time.nanoseconds);
    // The request runQuery sends, streamed, within the default limit.
    const r = try h.fake.streamRequest(0);
    try testing.expectEqual(.POST, r.method);
    try testing.expectEqualStrings(test_util.base ++ ":runQuery", r.url);
    try testing.expectEqualStrings("{\"structuredQuery\":{\"from\":[{\"collectionId\":\"c\"}],\"offset\":2}}", r.body_prefix);
    try testing.expectEqualStrings("application/json", r.content_type.?);
    try testing.expectEqual(.writer, r.sink);
    try testing.expectEqual(types.default_stream_timeout_ms, r.timeout_ms);
    try h.expectRequestCount(0);
}

test "runQueryEach: an empty answer, a time limit of the caller's, and a read time or transaction" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = "[{\n  \"readTime\": \"2026-10-05T22:28:44.615753Z\"\n}\n]" } },
        .{ .respond = .{ .body = test_util.streamed(&.{queryDoc("c/a")}) } },
    }, .{});
    defer h.deinit();
    var c: Collect = .init();
    defer c.deinit();
    const none = try h.client.runQueryEach(.{ .from = .{ .collection = "c" } }, .{ .timeout_ms = 0 }, c.documents());
    try testing.expectEqual(0, none.documents);
    try testing.expectEqual(read_ns, none.read_time.nanoseconds);
    try testing.expectEqual(0, (try h.fake.streamRequest(0)).timeout_ms);
    _ = try h.client.runQueryEach(.{ .from = .{ .collection = "c" } }, .{ .read_time = .{ .nanoseconds = read_ns } }, c.documents());
    try testing.expectEqualStrings("{\"structuredQuery\":{\"from\":[{\"collectionId\":\"c\"}]},\"readTime\":\"2026-10-05T22:28:44.615753Z\"}", (try h.fake.streamRequest(1)).body_prefix);
    // Refused before sending, as runQuery refuses them.
    try testing.expectError(error.InvalidArgument, h.client.runQueryEach(.{ .from = .{ .collection = "c" } }, .{ .read_time = .{ .nanoseconds = 1 }, .transaction = "dHg=" }, c.documents()));
    try testing.expectError(error.InvalidResourceId, h.client.runQueryEach(.{ .from = .{ .collection = "__c__" } }, .{}, c.documents()));
    try testing.expectEqual(2, h.fake.stream_requests.items.len);
}

test "runQueryEach: an error after documents is returned after the handler has seen them" {
    var h: test_util.Harness = undefined;
    try h.init(&.{.{ .respond = .{ .body = test_util.streamed(&.{ queryDoc("c/a"), queryDoc("c/b"), test_util.deadline_element }) } }}, .{});
    defer h.deinit();
    var c: Collect = .init();
    defer c.deinit();
    try testing.expectError(error.DeadlineExceeded, h.client.runQueryEach(.{ .from = .{ .collection = "c" } }, .{}, c.documents()));
    try c.expect(&.{ "a", "b" });
    try testing.expectEqualStrings("DEADLINE_EXCEEDED", h.diag.status());
    try h.expectDiag("The operation exceeded the deadline during execution.");
    try testing.expectEqual(504, h.diag.http_status);
    try testing.expectEqual(1, h.fake.stream_requests.items.len);
}

test "runQueryEach: the handler's error stops the read and is returned" {
    var h: test_util.Harness = undefined;
    try h.init(&.{.{ .respond = .{ .body = test_util.streamed(&.{ queryDoc("c/a"), queryDoc("c/b"), queryDoc("c/c") }) } }}, .{});
    defer h.deinit();
    var c: Collect = .init();
    defer c.deinit();
    c.stop_at = 1;
    try testing.expectError(error.Stop, h.client.runQueryEach(.{ .from = .{ .collection = "c" } }, .{}, c.documents()));
    try c.expect(&.{"a"});
    try h.expectDiag("the handler returned error.Stop");
    try testing.expectEqual(1, h.fake.stream_requests.items.len);
}

test "runQueryEach: a status is retried; a dropped connection only before the first document" {
    const answer = test_util.streamed(&.{ "{\"readTime\":\"2026-10-05T22:28:44.615753Z\",\"skippedResults\":1}", queryDoc("c/a"), queryDoc("c/b") });
    // Inside the first document, after the read time alone.
    const before_first = std.mem.indexOf(u8, answer, "\"document\"").?;
    const after_first = std.mem.indexOf(u8, answer, "c/b").?;
    var h: test_util.Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .status = 503, .body = "{\"error\":{\"code\":503,\"status\":\"UNAVAILABLE\",\"message\":\"x\"}}" } },
        .{ .respond = .{ .body = answer, .cut_after = before_first } },
        .{ .respond = .{ .body = answer } },
        .{ .respond = .{ .body = answer, .cut_after = after_first } },
        .{ .respond = .{ .body = answer } },
    }, .{});
    defer h.deinit();
    var c: Collect = .init();
    defer c.deinit();
    // Read again from the start: the skipped count is not counted twice.
    const end = try h.client.runQueryEach(.{ .from = .{ .collection = "c" } }, .{}, c.documents());
    try c.expect(&.{ "a", "b" });
    try testing.expectEqual(1, end.skipped_results);
    try testing.expectEqual(3, h.fake.stream_requests.items.len);
    var once: Collect = .init();
    defer once.deinit();
    try testing.expectError(error.ConnectionResetByPeer, h.client.runQueryEach(.{ .from = .{ .collection = "c" } }, .{}, once.documents()));
    try once.expect(&.{"a"});
    try testing.expectEqual(4, h.fake.stream_requests.items.len);
}

test "runQueryEach: a drop in the closing bracket fails a read that handed everything over" {
    // Production sends no `done` on its last message, so only the bracket
    // says the answer was whole.
    const answer = test_util.streamed(&.{ queryDoc("c/a"), queryDoc("c/b") });
    var h: test_util.Harness = undefined;
    try h.init(&.{.{ .respond = .{ .body = answer, .cut_after = answer.len - 1 } }}, .{});
    defer h.deinit();
    var c: Collect = .init();
    defer c.deinit();
    try testing.expectError(error.ConnectionResetByPeer, h.client.runQueryEach(.{ .from = .{ .collection = "c" } }, .{}, c.documents()));
    try c.expect(&.{ "a", "b" });
}

test "runQueryEach: an answer that is no array of messages is InvalidResponse" {
    inline for (.{
        "{}",
        "[1]",
        "[{\"document\":{}}]",
        // Cut short, with no error: the array never closes.
        "[" ++ queryDoc("c/a"),
        "[" ++ queryDoc("c/a") ++ "] x",
        // No read time anywhere.
        "[]",
    }) |body| {
        var h: test_util.Harness = undefined;
        try h.init(&.{.{ .respond = .{ .body = body } }}, .{});
        defer h.deinit();
        var c: Collect = .init();
        defer c.deinit();
        try testing.expectError(error.InvalidResponse, h.client.runQueryEach(.{ .from = .{ .collection = "c" } }, .{}, c.documents()));
        try h.expectDiag("the runQuery response could not be decoded");
    }
}

test "runQueryEach: a message over 16 MiB is refused, not held" {
    const big = try testing.allocator.alloc(u8, max_message_bytes + 64);
    defer testing.allocator.free(big);
    const head = "[{\"document\":{\"name\":\"projects/extractctl/databases/(default)/documents/c/a\",\"fields\":{\"s\":{\"stringValue\":\"";
    @memcpy(big[0..head.len], head);
    @memset(big[head.len..], 'x');
    var h: test_util.Harness = undefined;
    try h.init(&.{.{ .respond = .{ .body = big } }}, .{});
    defer h.deinit();
    var c: Collect = .init();
    defer c.deinit();
    try testing.expectError(error.ResponseTooLarge, h.client.runQueryEach(.{ .from = .{ .collection = "c" } }, .{}, c.documents()));
    try h.expectDiag("a message of the runQuery answer is over 16777216 bytes");
}

inline fn foundDoc(comptime path: []const u8) []const u8 {
    return "{\n  \"found\": " ++ test_util.docBody(path, "{}") ++ ",\n  \"readTime\": \"2026-10-05T22:28:44.615753Z\"\n}";
}

inline fn missingDoc(comptime path: []const u8) []const u8 {
    return "{\n  \"missing\": \"" ++ test_util.name(path) ++ "\",\n  \"readTime\": \"2026-10-05T22:28:44.615753Z\"\n}";
}

test "golden: batchGetEach asks each path once and hands each over once, as answered" {
    var h: test_util.Harness = undefined;
    // In production's order, by name, the missing last; one nobody asked
    // for, and one answered twice, passed over.
    try h.init(&.{.{ .respond = .{ .body = test_util.streamed(&.{ foundDoc("c/a"), foundDoc("c/a"), foundDoc("c/other"), foundDoc("c/z"), missingDoc("c/none") }) } }}, .{});
    defer h.deinit();
    var c: Collect = .init();
    defer c.deinit();
    const end = try h.client.batchGetEach(&.{ "c/z", "c/none", "c/a", "c/z" }, .{ .mask = &.{"n"} }, c.items());
    try c.expect(&.{ "a", "z", "-c/none" });
    try testing.expectEqual(3, end.items);
    try testing.expectEqual(read_ns, end.read_time.?.nanoseconds);
    const r = try h.fake.streamRequest(0);
    try testing.expectEqualStrings(test_util.base ++ ":batchGet", r.url);
    try testing.expectEqualStrings("{\"documents\":[\"" ++ test_util.name("c/z") ++ "\",\"" ++ test_util.name("c/none") ++ "\",\"" ++ test_util.name("c/a") ++ "\"],\"mask\":{\"fieldPaths\":[\"n\"]}}", r.body_prefix);
    // Nothing asked sends nothing.
    const nothing = try h.client.batchGetEach(&.{}, .{}, c.items());
    try testing.expectEqual(0, nothing.items);
    try testing.expectEqual(null, nothing.read_time);
    try testing.expectEqual(1, h.fake.stream_requests.items.len);
}

test "batchGetEach: a drop before the first item is read again; the read time is the second answer's" {
    const first = "[{\"readTime\":\"2026-10-05T12:00:00Z\"},\n" ++ foundDoc("c/a") ++ "]";
    var h: test_util.Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = first, .cut_after = std.mem.indexOf(u8, first, "c/a").? } },
        // Read again, with no read time of its own: the first answer's is
        // forgotten, not kept.
        .{ .respond = .{ .body = "[{\"found\":" ++ test_util.docBody("c/a", "{}") ++ "}]" } },
    }, .{});
    defer h.deinit();
    var c: Collect = .init();
    defer c.deinit();
    try testing.expectError(error.InvalidResponse, h.client.batchGetEach(&.{"c/a"}, .{}, c.items()));
    try c.expect(&.{"a"});
    try testing.expectEqual(2, h.fake.stream_requests.items.len);
}

test "batchGetEach: an answer that leaves a path out, an error inside, a drop after an item" {
    const answer = test_util.streamed(&.{ foundDoc("c/a"), foundDoc("c/b") });
    var h: test_util.Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = test_util.streamed(&.{foundDoc("c/a")}) } },
        .{ .respond = .{ .body = test_util.streamed(&.{ foundDoc("c/a"), test_util.deadline_element }) } },
        .{ .respond = .{ .body = answer, .cut_after = std.mem.indexOf(u8, answer, "c/b").? } },
        .{ .respond = .{ .body = "[{\"missing\":\"not-a-document-name\"}]" } },
    }, .{});
    defer h.deinit();
    var c: Collect = .init();
    defer c.deinit();
    try testing.expectError(error.InvalidResponse, h.client.batchGetEach(&.{ "c/a", "c/b" }, .{}, c.items()));
    try h.expectDiag("the batchGet answer said nothing of c/b");
    try testing.expectError(error.DeadlineExceeded, h.client.batchGetEach(&.{ "c/a", "c/b" }, .{}, c.items()));
    try testing.expectEqualStrings("DEADLINE_EXCEEDED", h.diag.status());
    try testing.expectError(error.ConnectionResetByPeer, h.client.batchGetEach(&.{ "c/a", "c/b" }, .{}, c.items()));
    try c.expect(&.{ "a", "a", "a" });
    try testing.expectError(error.InvalidResponse, h.client.batchGetEach(&.{"c/a"}, .{}, c.items()));
    try h.expectDiag("the batchGet response could not be decoded");
    try testing.expectEqual(4, h.fake.stream_requests.items.len);
}

test "runQueryEach and batchGetEach: every allocation failure is OutOfMemory without leaks" {
    const Run = struct {
        fn run(gpa: std.mem.Allocator) !void {
            var fake: test_util.FakeTransport = .init(testing.allocator, &.{
                .{ .respond = .{ .body = test_util.streamed(&.{ queryDoc("c/a"), queryDoc("c/b") }) } },
                .{ .respond = .{ .body = test_util.streamed(&.{ foundDoc("c/a"), missingDoc("c/b") }) } },
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
            var c: Collect = .init();
            defer c.deinit();
            _ = try client.runQueryEach(.{ .from = .{ .collection = "c" } }, .{}, c.documents());
            _ = try client.batchGetEach(&.{ "c/a", "c/b" }, .{}, c.items());
        }
    };
    try testing.checkAllAllocationFailures(test_util.no_grow_allocator, Run.run, .{});
}
