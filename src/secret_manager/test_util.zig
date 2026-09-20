//! Test-only helpers: `Harness`, a real `Client` wired to core's fake
//! transport and fake clock, and core's test helpers under their own names.
//! Only test blocks import this file, so none of it reaches a normal build.

const std = @import("std");
const core = @import("core");

const Client = @import("Client.zig");
const Method = core.transport.Method;
const Diagnostics = core.Diagnostics;
const RetryPolicy = core.RetryPolicy;
const types = @import("types.zig");

pub const FakeTransport = core.testing.FakeTransport;
pub const FakeTokenProvider = core.testing.FakeTokenProvider;
pub const FakeClock = core.testing.FakeClock;
pub const WipeChecker = core.testing.WipeChecker;
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
    token: FakeTokenProvider,
    client: Client,

    pub const Options = struct {
        project_id: []const u8 = "extractctl",
        location: ?[]const u8 = null,
        verify_checksum: types.ChecksumMode = .if_present,
        retry: RetryPolicy = .{},
        quota_project: ?[]const u8 = null,
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
            .location = options.location,
            .token_provider = h.token.provider(),
            .verify_checksum = options.verify_checksum,
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
};

/// `data` in base64, as it travels in a payload.
pub inline fn encoded(comptime data: []const u8) []const u8 {
    const text = comptime t: {
        var buf: [std.base64.standard.Encoder.calcSize(data.len)]u8 = undefined;
        break :t std.fmt.comptimePrint("{s}", .{std.base64.standard.Encoder.encode(&buf, data)});
    };
    return text;
}

/// An access response for `data`, with the checksum production would send.
pub inline fn accessBody(comptime name: []const u8, comptime data: []const u8) []const u8 {
    const checksum = comptime std.fmt.comptimePrint("{d}", .{core.crc32c.hash(data)});
    return accessBodyChecksum(name, data, checksum);
}

/// The same, with the checksum written out, so a test can send the wrong one.
pub inline fn accessBodyChecksum(
    comptime name: []const u8,
    comptime data: []const u8,
    comptime checksum: []const u8,
) []const u8 {
    return std.fmt.comptimePrint(
        "{{\"name\":\"{s}\",\"payload\":{{\"data\":\"{s}\",\"dataCrc32c\":\"{s}\"}}}}",
        .{ name, encoded(data), checksum },
    );
}
