//! Retry policy: which failures are retried and how long to wait in between.

const std = @import("std");
const test_util = @import("testing.zig");

pub const RetryPolicy = struct {
    /// Attempts in total, including the first. 1 disables retries.
    max_attempts: u8 = 5,
    initial_backoff_ms: u32 = 100,
    max_backoff_ms: u32 = 10_000,
    /// At least 1.
    multiplier: f32 = 2.0,

    pub fn isValid(p: RetryPolicy) bool {
        return p.max_attempts >= 1 and std.math.isFinite(p.multiplier) and p.multiplier >= 1.0;
    }

    /// The longest wait before retry number `retry`, where 1 is the first
    /// retry: `min(max_backoff_ms, initial_backoff_ms * multiplier^(retry - 1))`.
    /// Total over every input; an invalid multiplier counts as 1.
    pub fn backoffCapMs(p: RetryPolicy, retry: u32) u32 {
        // Checked first: 0 * inf would be NaN.
        if (p.initial_backoff_ms == 0) return 0;
        const multiplier: f64 = if (std.math.isFinite(p.multiplier) and p.multiplier >= 1.0) p.multiplier else 1.0;
        const exponent: f64 = @floatFromInt(@max(retry, 1) - 1);
        // At least `initial_backoff_ms`, possibly +inf, never NaN.
        const cap = @as(f64, @floatFromInt(p.initial_backoff_ms)) * std.math.pow(f64, multiplier, exponent);
        return if (cap < @as(f64, @floatFromInt(p.max_backoff_ms))) @intFromFloat(cap) else p.max_backoff_ms;
    }

    /// Full jitter: a wait in `[0, backoffCapMs(retry)]`, chosen by `entropy`,
    /// which should be uniformly random.
    pub fn backoffMs(p: RetryPolicy, retry: u32, entropy: u64) u32 {
        const cap = p.backoffCapMs(retry);
        return @intCast(entropy % (@as(u64, cap) + 1));
    }
};

/// Whether a failed attempt may be retried: the retryable API statuses
/// (RESOURCE_EXHAUSTED, INTERNAL, BAD_GATEWAY and UNAVAILABLE, both mapped to
/// `Unavailable`, and DEADLINE_EXCEEDED) and connections that dropped, timed
/// out or could not be made. Everything else is returned as is.
///
/// `TlsFailure` is retried because std.http reports a connection dropped
/// mid-handshake the same way as a certificate problem; a real certificate
/// problem fails again on every attempt.
pub fn isRetryable(err: anyerror) bool {
    return switch (err) {
        error.ResourceExhausted,
        error.Internal,
        error.Unavailable,
        error.DeadlineExceeded,
        error.ConnectionRefused,
        error.ConnectionResetByPeer,
        error.ConnectionTimedOut,
        error.NetworkUnreachable,
        error.NameServerFailure,
        error.TlsFailure,
        // A request that outlived its own deadline: the next attempt may
        // find the server healthy again.
        error.TimedOut,
        => true,
        else => false,
    };
}

const testing = std.testing;

test "default backoff caps grow and saturate" {
    const p: RetryPolicy = .{};
    try testing.expect(p.isValid());
    try testing.expectEqual(100, p.backoffCapMs(1));
    try testing.expectEqual(200, p.backoffCapMs(2));
    try testing.expectEqual(400, p.backoffCapMs(3));
    try testing.expectEqual(800, p.backoffCapMs(4));
    try testing.expectEqual(10_000, p.backoffCapMs(8));
    try testing.expectEqual(10_000, p.backoffCapMs(std.math.maxInt(u32)));
    // Retry 0 is treated as the first retry.
    try testing.expectEqual(100, p.backoffCapMs(0));
}

test "full jitter spans zero to the cap" {
    const p: RetryPolicy = .{};
    try testing.expectEqual(0, p.backoffMs(3, 0));
    try testing.expectEqual(400, p.backoffMs(3, 400));
    try testing.expectEqual(0, p.backoffMs(3, 401));
    try testing.expect(p.backoffMs(3, std.math.maxInt(u64)) <= 400);
}

test "odd policies stay total" {
    try testing.expect(!(RetryPolicy{ .max_attempts = 0 }).isValid());
    try testing.expect(!(RetryPolicy{ .multiplier = 0.5 }).isValid());
    try testing.expect(!(RetryPolicy{ .multiplier = std.math.nan(f32) }).isValid());
    try testing.expect(!(RetryPolicy{ .multiplier = std.math.inf(f32) }).isValid());
    const nan: RetryPolicy = .{ .multiplier = std.math.nan(f32) };
    try testing.expectEqual(100, nan.backoffCapMs(5));
    const huge: RetryPolicy = .{ .multiplier = std.math.floatMax(f32), .max_backoff_ms = std.math.maxInt(u32) };
    try testing.expectEqual(std.math.maxInt(u32), huge.backoffCapMs(50));
    const inverted: RetryPolicy = .{ .initial_backoff_ms = 5000, .max_backoff_ms = 10 };
    try testing.expectEqual(10, inverted.backoffCapMs(1));
    const zero: RetryPolicy = .{ .initial_backoff_ms = 0 };
    try testing.expectEqual(0, zero.backoffMs(4, 12345));
    // Regression: 0 * inf is NaN, which once made the cap jump to the maximum.
    const zero_huge: RetryPolicy = .{ .initial_backoff_ms = 0, .multiplier = std.math.floatMax(f32) };
    try testing.expectEqual(0, zero_huge.backoffCapMs(1000));
}

test "retryable errors are exactly the transient ones" {
    for ([_]anyerror{
        error.ResourceExhausted, error.Internal,           error.Unavailable,
        error.DeadlineExceeded,  error.ConnectionRefused,  error.ConnectionResetByPeer,
        error.TimedOut,          error.ConnectionTimedOut, error.NetworkUnreachable,
        error.NameServerFailure, error.TlsFailure,
    }) |err| try testing.expect(isRetryable(err));
    for ([_]anyerror{
        error.InvalidArgument,      error.FailedPrecondition, error.Unauthenticated,
        error.PermissionDenied,     error.NotFound,           error.AlreadyExists,
        error.ServerCancelled,      error.Canceled,           error.Aborted,
        error.Unknown,              error.InvalidResponse,    error.InvalidEndpoint,
        error.UnknownHostName,      error.ResponseTooLarge,   error.OutOfMemory,
        error.InvalidMessage,       error.TokenUnavailable,   error.HttpProtocolError,
        error.InvalidRequestHeader,
    }) |err| try testing.expect(!isRetryable(err));
}

fn backoffProperty(_: void, input: []const u8) !void {
    var g: test_util.ByteGen = .init(input);
    const p: RetryPolicy = .{
        .max_attempts = g.int(u8),
        .initial_backoff_ms = g.int(u32),
        .max_backoff_ms = g.int(u32),
        .multiplier = @bitCast(g.int(u32)),
    };
    const retry = g.int(u32);
    const cap = p.backoffCapMs(retry);
    try testing.expect(cap <= p.max_backoff_ms);
    try testing.expect(cap >= @min(p.initial_backoff_ms, p.max_backoff_ms));
    try testing.expect(p.backoffMs(retry, g.int(u64)) <= cap);
    // Caps never shrink from one retry to the next.
    if (retry < std.math.maxInt(u32)) try testing.expect(p.backoffCapMs(retry + 1) >= cap);
}

test "fuzz backoff: bounded, monotonic, total for any policy" {
    try test_util.fuzzBytes({}, backoffProperty, .{ .corpus = &.{
        "\x05\x00\x00\x00\x64\x00\x00\x27\x10\x40\x00\x00\x00\x00\x00\x00\x03",
        "\x05\x00\x00\x00\x64\x00\x00\x27\x10\x7f\xc0\x00\x00\x00\x00\x00\x03",
        "\x05\xff\xff\xff\xff\xff\xff\xff\xff\x7f\x7f\xff\xff\xff\xff\xff\xff",
    } });
}
