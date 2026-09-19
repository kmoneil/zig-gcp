//! Library logging. Everything goes through `std.log.scoped(.pubsub)`, so
//! applications can filter or silence it with `std_options.log_scope_levels`.
//! Callers pass only methods, paths, statuses, counts and timings: never
//! tokens, message data or attribute values.
//!
//! In test builds, lines are captured in memory instead of printed, so tests
//! stay quiet and can assert on exactly what would have been logged.

const std = @import("std");
const builtin = @import("builtin");

const log = std.log.scoped(.pubsub);

pub fn debug(comptime format: []const u8, args: anytype) void {
    if (builtin.is_test) return capture.record("debug", format, args);
    log.debug(format, args);
}

pub fn warn(comptime format: []const u8, args: anytype) void {
    if (builtin.is_test) return capture.record("warn", format, args);
    log.warn(format, args);
}

/// The in-memory sink used in test builds. Single-threaded, like the test runner.
pub const capture = if (builtin.is_test) struct {
    var buffer: [64 * 1024]u8 = undefined;
    var len: usize = 0;
    /// Lines recorded since the last reset, including any that did not fit.
    pub var lines: usize = 0;

    fn record(comptime level: []const u8, comptime format: []const u8, args: anytype) void {
        var w: std.Io.Writer = .fixed(buffer[len..]);
        w.print(level ++ ": " ++ format ++ "\n", args) catch {};
        len += w.end;
        lines += 1;
    }

    pub fn reset() void {
        len = 0;
        lines = 0;
    }

    pub fn text() []const u8 {
        return buffer[0..len];
    }
} else struct {};

test "capture records formatted lines" {
    capture.reset();
    debug("{s} {s} -> {d}", .{ "GET", "/v1/x", 200 });
    warn("retrying in {d} ms", .{150});
    try std.testing.expectEqualStrings("debug: GET /v1/x -> 200\nwarn: retrying in 150 ms\n", capture.text());
    try std.testing.expectEqual(2, capture.lines);
    capture.reset();
    try std.testing.expectEqualStrings("", capture.text());
}
