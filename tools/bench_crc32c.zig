//! How fast this build computes a CRC-32C: std's one table, the tables
//! `core.crc32c` falls back to, and `core.crc32c.hash`, which runs the CPU's
//! instructions where the target has them. 256 MiB of random bytes, best of
//! five, always in ReleaseFast.
//!
//!     zig build bench-crc32c
//!     zig build bench-crc32c -Dcpu=baseline

const std = @import("std");
const builtin = @import("builtin");
const core = @import("core");

const size = 256 * 1024 * 1024;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const data = try init.gpa.alloc(u8, size);
    defer init.gpa.free(data);
    io.random(data);

    const Candidate = struct { name: []const u8, run: *const fn ([]const u8) u32 };
    const Stream = struct {
        /// `core.crc32c.Hasher` fed 64 KiB at a time, as a download feeds it.
        fn run(bytes: []const u8) u32 {
            var hasher: core.crc32c.Hasher = .init();
            var rest = bytes;
            while (rest.len > 0) {
                const n = @min(rest.len, 64 * 1024);
                hasher.update(rest[0..n]);
                rest = rest[n..];
            }
            return hasher.final();
        }
    };
    const candidates = [_]Candidate{
        .{ .name = "std Crc32Iscsi", .run = std.hash.crc.Crc32Iscsi.hash },
        .{ .name = "core.crc32c.hashSoftware", .run = core.crc32c.hashSoftware },
        .{ .name = "core.crc32c.hash", .run = core.crc32c.hash },
        .{ .name = "Hasher, 64 KiB updates", .run = Stream.run },
    };
    std.debug.print("{t} ({s}), core.crc32c.implementation = .{t}\n", .{ builtin.cpu.arch, builtin.cpu.model.name, core.crc32c.implementation });
    var want: ?u32 = null;
    for (candidates) |candidate| {
        var best: u64 = std.math.maxInt(u64);
        for (0..5) |_| {
            // Keep the optimizer from hashing once for all five runs.
            std.mem.doNotOptimizeAway(data.ptr);
            const started = std.Io.Clock.awake.now(io);
            const crc = candidate.run(data);
            std.mem.doNotOptimizeAway(crc);
            best = @min(best, @as(u64, @intCast(started.durationTo(std.Io.Clock.awake.now(io)).toNanoseconds())));
            if (want) |w| {
                if (crc != w) return error.CandidatesDisagree;
            } else want = crc;
        }
        const mib_per_s = @as(f64, @floatFromInt(size)) / (1024.0 * 1024.0) / (@as(f64, @floatFromInt(best)) / 1e9);
        std.debug.print("  {s:<26} {d:>8.0} MiB/s\n", .{ candidate.name, mib_per_s });
    }
}
