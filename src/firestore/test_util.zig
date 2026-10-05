//! Test-only helpers: `Harness`, a real `Client` wired to core's fake
//! transport and fake clock, and core's test helpers under their own names.
//! Only test blocks import this file, so none of it reaches a normal build.

const std = @import("std");
const core = @import("core");

const Client = @import("Client.zig");
pub const FakeFirestore = @import("fake_firestore.zig").FakeFirestore;
const Method = core.transport.Method;
const Diagnostics = core.Diagnostics;
const RetryPolicy = core.RetryPolicy;

pub const FakeTransport = core.testing.FakeTransport;
pub const FakeTokenProvider = core.testing.FakeTokenProvider;
pub const FakeClock = core.testing.FakeClock;
pub const ByteGen = core.testing.ByteGen;
pub const FuzzOptions = core.testing.FuzzOptions;
pub const fuzzBytes = core.testing.fuzzBytes;
pub const max_fuzz_input = core.testing.max_fuzz_input;
pub const repeat = core.testing.repeat;
pub const no_grow_allocator = core.testing.no_grow_allocator;

/// A real `Client` wired to a `FakeTransport` and a `FakeClock`. Initialize
/// it in place with `init`: the client points into the harness.
pub const Harness = struct {
    fake: FakeTransport,
    clock: FakeClock,
    diag: Diagnostics,
    token: FakeTokenProvider,
    client: Client,

    pub const Options = struct {
        project_id: []const u8 = "extractctl",
        database_id: []const u8 = "(default)",
        retry: RetryPolicy = .{},
        quota_project: ?[]const u8 = null,
        /// Against `127.0.0.1:8087` as the emulator.
        emulator: bool = false,
    };

    pub fn init(h: *Harness, script: []const FakeTransport.Reply, options: Options) !void {
        h.* = .{
            .fake = .init(std.testing.allocator, script),
            .clock = .{},
            .diag = .{},
            .token = .{ .token = "ya29.test-token", .quota_project = options.quota_project },
            .client = undefined,
        };
        errdefer h.fake.deinit();
        h.client = try .init(std.testing.allocator, h.clock.io(), .{
            .project_id = options.project_id,
            .database_id = options.database_id,
            .endpoint = if (options.emulator) .{ .url = "127.0.0.1:8087", .emulator = true } else null,
            .token_provider = h.token.provider(),
            .retry = options.retry,
            .diagnostics = &h.diag,
            .transport = h.fake.transport(),
        });
    }

    pub fn deinit(h: *Harness) void {
        h.client.deinit();
        h.fake.deinit();
    }

    /// Asserts the method, URL and body of the request at `index`.
    pub fn expectRequest(h: *const Harness, index: usize, method: Method, url: []const u8, body: ?[]const u8) !void {
        const r = try h.fake.request(index);
        try std.testing.expectEqual(method, r.method);
        try std.testing.expectEqualStrings(url, r.url);
        if (body) |b| {
            try std.testing.expectEqualStrings(b, r.body orelse return error.TestExpectedBody);
        } else {
            try std.testing.expectEqual(null, r.body);
        }
    }

    pub fn expectRequestCount(h: *const Harness, count: usize) !void {
        try std.testing.expectEqual(count, h.fake.requests.items.len);
    }

    /// Asserts the diagnostics say `part` somewhere.
    pub fn expectDiag(h: *const Harness, part: []const u8) !void {
        if (std.mem.indexOf(u8, h.diag.message(), part) == null) {
            std.debug.print("diagnostics: {s}\n", .{h.diag.message()});
            return error.TestUnexpectedDiagnostics;
        }
    }
};

/// A real `Client` against a `FakeFirestore`. Initialize it in place with
/// `init`: the client points into the harness.
pub const FakeHarness = struct {
    server: FakeFirestore,
    clock: FakeClock,
    diag: Diagnostics,
    token: FakeTokenProvider,
    client: Client,

    pub fn init(h: *FakeHarness, options: Harness.Options) !void {
        h.* = .{
            .server = .init(std.testing.allocator),
            .clock = .{},
            .diag = .{},
            .token = .{ .token = "ya29.test-token" },
            .client = undefined,
        };
        errdefer h.server.deinit();
        h.client = try .init(std.testing.allocator, h.clock.io(), .{
            .project_id = options.project_id,
            .database_id = options.database_id,
            .token_provider = h.token.provider(),
            .retry = options.retry,
            .diagnostics = &h.diag,
            .transport = h.server.transport(),
        });
    }

    pub fn deinit(h: *FakeHarness) void {
        h.client.deinit();
        h.server.deinit();
    }

    pub fn expectDiag(h: *const FakeHarness, part: []const u8) !void {
        if (std.mem.indexOf(u8, h.diag.message(), part) == null) {
            std.debug.print("diagnostics: {s}\n", .{h.diag.message()});
            return error.TestUnexpectedDiagnostics;
        }
    }
};

/// The base of every production URL these tests expect.
pub const base = "https://firestore.googleapis.com/v1/projects/extractctl/databases/(default)/documents";

/// A document as the server answers it, at `path`, with `fields_json`
/// as its `fields` member.
pub inline fn docBody(comptime path: []const u8, comptime fields_json: []const u8) []const u8 {
    return "{\"name\":\"projects/extractctl/databases/(default)/documents/" ++ path ++ "\",\"fields\":" ++ fields_json ++
        ",\"createTime\":\"2026-10-04T22:42:59.233365Z\",\"updateTime\":\"2026-10-04T22:42:59.269778Z\"}";
}

/// The update time `docBody` answers, in nanoseconds.
pub const doc_update_ns: i96 = 1_791_153_779_269_778_000;

/// A commit of one write, as the server answers it, with `doc_update_ns`
/// as the write's update time.
pub const commit_body = "{\"writeResults\":[{\"updateTime\":\"2026-10-04T22:42:59.269778Z\"}],\"commitTime\":\"2026-10-04T22:42:59.269778Z\"}";

/// A commit of one delete: its result is empty.
pub const delete_body = "{\"writeResults\":[{}],\"commitTime\":\"2026-10-04T22:42:59.269778Z\"}";

/// The full name of `path` in the test database.
pub inline fn name(comptime path: []const u8) []const u8 {
    return "projects/extractctl/databases/(default)/documents/" ++ path;
}

/// The error production sent inside a query's 200 answer, after the
/// documents it had found, when the query ran past its deadline: measured
/// 2026-10-05 with `X-Server-Timeout`, pretty-printed as sent.
pub const deadline_element = "{\n  \"error\": {\n    \"code\": 504,\n    \"message\": \"The operation exceeded the deadline during execution.\\n\\nIf this is a query, try using explain to identify sources of latency within the plan.\",\n    \"status\": \"DEADLINE_EXCEEDED\",\n    \"details\": [\n      {\n        \"@type\": \"type.googleapis.com/google.rpc.ErrorInfo\",\n        \"reason\": \"EXECUTION_DEADLINE_EXCEEDED\",\n        \"domain\": \"firestore.googleapis.com\"\n      }\n    ]\n  }\n}";

/// One message of a streamed answer framed as production frames it: the
/// first right after `[`, each later one after `\n,\r\n`.
pub inline fn streamed(comptime elements: []const []const u8) []const u8 {
    comptime var out: []const u8 = "[";
    inline for (elements, 0..) |e, i| out = out ++ (if (i == 0) "" else "\n,\r\n") ++ e;
    return out ++ "\n]";
}
