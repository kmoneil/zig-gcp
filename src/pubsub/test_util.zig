//! Test-only helpers: `Harness`, a real `Client` wired to core's fake
//! transport and fake clock, and core's test helpers under their old names.
//! Only test blocks import this file, so none of it reaches a normal build.

const std = @import("std");
const core = @import("core");

const Method = core.transport.Method;
const Client = @import("Client.zig");
const Endpoint = @import("Endpoint.zig");
const Diagnostics = @import("errors.zig").Diagnostics;
const StaticToken = @import("auth.zig").StaticToken;
const RetryPolicy = @import("core").RetryPolicy;

pub const FakeTransport = core.testing.FakeTransport;
pub const FakeClock = core.testing.FakeClock;
pub const ByteGen = core.testing.ByteGen;
pub const FuzzOptions = core.testing.FuzzOptions;
pub const fuzzBytes = core.testing.fuzzBytes;
pub const max_fuzz_input = core.testing.max_fuzz_input;

/// A real `Client` wired to a `FakeTransport` and a `FakeClock`. Initialize
/// it in place with `init`: the client points into the harness.
pub const Harness = struct {
    fake: FakeTransport,
    clock: FakeClock,
    diag: Diagnostics,
    token: StaticToken,
    client: Client,

    pub const Options = struct {
        /// Null targets the emulator, which gets no credentials. A token
        /// targets production.
        token: ?[]const u8 = null,
        retry: RetryPolicy = .{},
        retry_publish: bool = true,
        project_id: []const u8 = "p",
    };

    pub fn init(h: *Harness, script: []const FakeTransport.Reply, options: Options) !void {
        h.* = .{
            .fake = .init(std.testing.allocator, script),
            .clock = .{},
            .diag = .{},
            .token = .{ .token = options.token orelse "" },
            .client = undefined,
        };
        errdefer h.fake.deinit();
        const emulator: Endpoint = .{ .url = "localhost:8085", .emulator = true };
        h.client = try .init(std.testing.allocator, h.clock.io(), .{
            .project_id = options.project_id,
            .endpoint = if (options.token == null) emulator else null,
            .token_provider = if (options.token == null) null else h.token.provider(),
            .retry = options.retry,
            .retry_publish = options.retry_publish,
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
};
