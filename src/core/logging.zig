//! Logging for the modules. Each logs through `std.log` under its own scope,
//! such as `.gcp_pubsub`, so applications can filter or silence each with
//! `std_options.log_scope_levels`. Callers pass only methods, paths,
//! statuses, counts, sizes and timings: never tokens, secrets, message data
//! or attribute values.
//!
//! In test builds, lines are captured in memory instead of printed, so tests
//! stay quiet and can assert on exactly what would have been logged.

const std = @import("std");
const builtin = @import("builtin");

/// The logging functions for one module's scope.
pub fn Scoped(comptime scope: @EnumLiteral()) type {
    return struct {
        const log = std.log.scoped(scope);

        pub fn debug(comptime format: []const u8, args: anytype) void {
            if (builtin.is_test) return capture.record("debug", format, args);
            log.debug(format, args);
        }

        pub fn warn(comptime format: []const u8, args: anytype) void {
            if (builtin.is_test) return capture.record("warn", format, args);
            log.warn(format, args);
        }

        /// The in-memory sink used in test builds, one per scope. Tasks on
        /// other threads may record at the same time.
        pub const capture = if (builtin.is_test) struct {
            // A type that captures no comptime value is shared by every
            // instantiation; naming the scope gives each scope its own buffer.
            const owner = scope;
            var buffer: [64 * 1024]u8 = undefined;
            var len: usize = 0;
            /// Lines recorded since the last reset, including any that did not fit.
            pub var lines: usize = 0;

            fn record(comptime level: []const u8, comptime format: []const u8, args: anytype) void {
                var line_buffer: [1024]u8 = undefined;
                var w: std.Io.Writer = .fixed(&line_buffer);
                w.print(level ++ ": " ++ format ++ "\n", args) catch {};
                const line = w.buffered();
                const at = @atomicRmw(usize, &len, .Add, line.len, .monotonic);
                if (at + line.len <= buffer.len) @memcpy(buffer[at..][0..line.len], line);
                _ = @atomicRmw(usize, &lines, .Add, 1, .monotonic);
            }

            pub fn reset() void {
                len = 0;
                lines = 0;
            }

            pub fn text() []const u8 {
                return buffer[0..@min(len, buffer.len)];
            }
        } else struct {};
    };
}

test "capture records formatted lines" {
    const scoped = Scoped(.gcp_core_test);
    scoped.capture.reset();
    scoped.debug("{s} {s} -> {d}", .{ "GET", "/v1/x", 200 });
    scoped.warn("retrying in {d} ms", .{150});
    try std.testing.expectEqualStrings("debug: GET /v1/x -> 200\nwarn: retrying in 150 ms\n", scoped.capture.text());
    try std.testing.expectEqual(2, scoped.capture.lines);
    scoped.capture.reset();
    try std.testing.expectEqualStrings("", scoped.capture.text());
}

test "capture keeps scopes apart" {
    const a = Scoped(.gcp_core_test_a);
    const b = Scoped(.gcp_core_test_b);
    a.capture.reset();
    b.capture.reset();
    a.warn("only in a", .{});
    try std.testing.expectEqualStrings("warn: only in a\n", a.capture.text());
    try std.testing.expectEqualStrings("", b.capture.text());
}
