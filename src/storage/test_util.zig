//! Test-only helpers: `Harness`, a real `Client` wired to core's fake
//! transport and fake clock, and core's test helpers under their own names.
//! Only test blocks import this file, so none of it reaches a normal build.

const std = @import("std");
const core = @import("core");

const Client = @import("Client.zig");
const Checkpoint = @import("checkpoint.zig").Checkpoint;
const Method = core.transport.Method;
const Diagnostics = core.Diagnostics;
const RetryPolicy = core.RetryPolicy;

pub const FakeTransport = core.testing.FakeTransport;
pub const FakeMultipart = @import("fake_multipart.zig").FakeMultipart;
pub const MultipartServer = @import("fake_multipart.zig").MultipartServer;
pub const FakeTokenProvider = core.testing.FakeTokenProvider;
pub const FakeClock = core.testing.FakeClock;
pub const ByteGen = core.testing.ByteGen;
pub const FuzzOptions = core.testing.FuzzOptions;
pub const fuzzBytes = core.testing.fuzzBytes;
pub const max_fuzz_input = core.testing.max_fuzz_input;

/// A checkpoint kept in memory, counting its calls: a "process" is one
/// call, so a restart is two calls sharing one of these. Failures on
/// demand, and a `clear` that keeps the state, as a crash between the last
/// range and the clear would.
pub const MemoryCheckpoint = struct {
    gpa: std.mem.Allocator,
    stored: ?[]u8 = null,
    loads: u32 = 0,
    saves: u32 = 0,
    clears: u32 = 0,
    /// Fail every save once this many succeeded.
    saves_allowed: ?u32 = null,
    fail_loads: bool = false,
    keep_on_clear: bool = false,

    pub fn deinit(self: *MemoryCheckpoint) void {
        if (self.stored) |bytes| self.gpa.free(bytes);
        self.* = undefined;
    }

    pub fn checkpoint(self: *MemoryCheckpoint) Checkpoint {
        return .{ .ptr = self, .vtable = &.{ .load = load, .save = save, .clear = clear } };
    }

    fn load(ptr: *anyopaque, arena: std.mem.Allocator) Checkpoint.Error!?[]const u8 {
        const self: *MemoryCheckpoint = @ptrCast(@alignCast(ptr));
        self.loads += 1;
        if (self.fail_loads) return error.CheckpointFailed;
        const bytes = self.stored orelse return null;
        return try arena.dupe(u8, bytes);
    }

    fn save(ptr: *anyopaque, state: []const u8) Checkpoint.Error!void {
        const self: *MemoryCheckpoint = @ptrCast(@alignCast(ptr));
        if (self.saves_allowed) |allowed| if (self.saves >= allowed) return error.CheckpointFailed;
        self.saves += 1;
        const copy = try self.gpa.dupe(u8, state);
        if (self.stored) |old| self.gpa.free(old);
        self.stored = copy;
    }

    fn clear(ptr: *anyopaque) void {
        const self: *MemoryCheckpoint = @ptrCast(@alignCast(ptr));
        self.clears += 1;
        if (self.keep_on_clear) return;
        if (self.stored) |old| self.gpa.free(old);
        self.stored = null;
    }
};

/// A real `Client` wired to a `FakeTransport` and a `FakeClock`. Initialize
/// it in place with `init`: the client points into the harness.
pub const Harness = struct {
    fake: FakeTransport,
    clock: FakeClock,
    diag: Diagnostics,
    token: FakeTokenProvider,
    client: Client,

    pub const Options = struct {
        project_id: ?[]const u8 = "extractctl",
        retry: RetryPolicy = .{},
        retry_unconditional_writes: bool = false,
        verify_checksums: bool = true,
        chunk_size: usize = 8 * 1024 * 1024,
        single_request_limit: usize = 8 * 1024 * 1024,
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
            .token_provider = h.token.provider(),
            .retry = options.retry,
            .retry_unconditional_writes = options.retry_unconditional_writes,
            .verify_checksums = options.verify_checksums,
            .chunk_size = options.chunk_size,
            .single_request_limit = options.single_request_limit,
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
