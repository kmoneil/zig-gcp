//! A secret's bytes, in memory that is wiped when the value is released.
//!
//! Everything the call touched lives in one arena over a
//! `core.WipingAllocator`: the response body, which holds the bytes in
//! base64, the JSON parser's scratch space, and the decoded bytes
//! themselves. One `deinit` zeroes all of it.

const SecretValue = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("core");
const names = @import("names.zig");

/// The bytes, behind a type that will not print them. Read them with
/// `bytes()`.
data: Redacted,
/// The resolved name of the version that answered, such as
/// `projects/82150720798/secrets/db-password/versions/3`. After accessing
/// `.latest`, it says which number that was.
version_name: []const u8,
/// False only where the server sent no checksum and `verify_checksum`
/// allowed that.
checksum_verified: bool,
/// The wiped arena holding everything above. `deinit` frees it.
backing: *Backing,

const Backing = struct {
    wiping: core.WipingAllocator,
    arena: std.heap.ArenaAllocator,
};

/// A slice of secret bytes that no format specifier prints. `{f}` gives
/// `[REDACTED]`; `{}` and `{any}` print the fields of a struct, so the bytes
/// are held as a pointer and a length, which print as an address and a
/// number. Nothing reaches a log line by accident.
pub const Redacted = struct {
    ptr: [*]const u8,
    len: usize,

    pub fn init(slice_: []const u8) Redacted {
        return .{ .ptr = slice_.ptr, .len = slice_.len };
    }

    pub fn slice(self: Redacted) []const u8 {
        return self.ptr[0..self.len];
    }

    pub fn format(self: Redacted, w: *std.Io.Writer) std.Io.Writer.Error!void {
        _ = self;
        try w.writeAll("[REDACTED]");
    }
};

/// An empty value, with the wiped arena that the call fills.
pub fn init(gpa: Allocator) Allocator.Error!SecretValue {
    const backing = try gpa.create(Backing);
    backing.wiping = .init(gpa);
    backing.arena = .init(backing.wiping.allocator());
    return .{
        .data = .init(""),
        .version_name = "",
        .checksum_verified = false,
        .backing = backing,
    };
}

/// The arena every byte of this value lives in.
pub fn arena(self: SecretValue) *std.heap.ArenaAllocator {
    return &self.backing.arena;
}

/// Allocates inside that arena, so what is allocated is wiped with it.
pub fn allocator(self: SecretValue) Allocator {
    return self.backing.arena.allocator();
}

/// Wipes everything the arena holds and empties the value, ready to be
/// filled again. Used between attempts, so bad bytes never outlive the
/// attempt that fetched them.
pub fn clear(self: *SecretValue) void {
    _ = self.backing.arena.reset(.free_all);
    self.data = .init("");
    self.version_name = "";
    self.checksum_verified = false;
}

/// Wipes and frees the secret. Pass a `SecretValue` by pointer: a copy whose
/// `deinit` also runs frees the same memory twice.
pub fn deinit(self: *SecretValue) void {
    const gpa = self.backing.wiping.child;
    self.backing.arena.deinit();
    gpa.destroy(self.backing);
    self.* = undefined;
}

/// The secret's bytes, exactly as stored: a secret written with `echo` ends
/// in a newline, and the library never trims one. They live until `deinit`.
pub fn bytes(self: SecretValue) []const u8 {
    return self.data.slice();
}

/// The number of the version that answered, or null when the name does not
/// end in one.
pub fn versionNumber(self: SecretValue) ?u64 {
    return names.versionNumber(self.version_name);
}

/// Prints `[REDACTED]`. An accidental `{f}` in a log line cannot leak the
/// secret, and neither can `{}` or `{any}`, which print `data` as a pointer.
pub fn format(self: SecretValue, w: *std.Io.Writer) std.Io.Writer.Error!void {
    _ = self;
    try w.writeAll("[REDACTED]");
}

const testing = std.testing;

test "init, fill and deinit, with nothing left behind" {
    var value: SecretValue = try .init(testing.allocator);
    value.data = .init(try value.allocator().dupe(u8, "s3cr3t"));
    value.version_name = try value.allocator().dupe(u8, "projects/1/secrets/db/versions/3");
    value.checksum_verified = true;
    try testing.expectEqualStrings("s3cr3t", value.bytes());
    try testing.expectEqual(3, value.versionNumber().?);
    value.deinit();
}

test "deinit wipes every byte the arena held" {
    var backing: [16 * 1024]u8 = @splat(0);
    var fba: std.heap.FixedBufferAllocator = .init(&backing);
    var value: SecretValue = try .init(fba.allocator());
    // The arena's own chunks start after the header `init` allocated, which
    // holds no secret and is not wiped.
    const chunks_from = fba.end_index;
    // More than one chunk, so the arena takes several from the allocator.
    for (0..20) |i| {
        const buf = try value.allocator().alloc(u8, 200 + i * 13);
        @memset(buf, 'S');
    }
    value.data = .init(try value.allocator().dupe(u8, "s3cr3t"));
    try testing.expect(std.mem.indexOf(u8, &backing, "s3cr3t") != null);
    const used = fba.end_index;
    value.deinit();
    try testing.expect(std.mem.allEqual(u8, backing[chunks_from..used], 0));
}

test "clear wipes what was fetched and leaves the value empty" {
    var backing: [16 * 1024]u8 = @splat(0);
    var fba: std.heap.FixedBufferAllocator = .init(&backing);
    var value: SecretValue = try .init(fba.allocator());
    defer value.deinit();
    value.data = .init(try value.allocator().dupe(u8, "wrong-bytes"));
    value.version_name = try value.allocator().dupe(u8, "v/1");
    value.checksum_verified = true;

    value.clear();
    try testing.expectEqual(null, std.mem.indexOf(u8, &backing, "wrong-bytes"));
    try testing.expectEqualStrings("", value.bytes());
    try testing.expectEqualStrings("", value.version_name);
    try testing.expect(!value.checksum_verified);
}

test "no format specifier prints the bytes" {
    var value: SecretValue = try .init(testing.allocator);
    defer value.deinit();
    value.data = .init(try value.allocator().dupe(u8, "s3cr3t"));
    value.version_name = try value.allocator().dupe(u8, "projects/1/secrets/db/versions/3");

    var buf: [512]u8 = undefined;
    try testing.expectEqualStrings("[REDACTED]", try std.fmt.bufPrint(&buf, "{f}", .{value}));
    try testing.expectEqualStrings("[REDACTED]", try std.fmt.bufPrint(&buf, "{f}", .{value.data}));
    inline for (.{ "{}", "{any}" }) |spec| {
        const printed = try std.fmt.bufPrint(&buf, spec, .{value});
        // The bytes of "s3cr3t" as std would print a slice of them.
        try testing.expectEqual(null, std.mem.indexOf(u8, printed, "115, 51"));
        try testing.expectEqual(null, std.mem.indexOf(u8, printed, "s3cr3t"));
    }
}

test "every allocation failure is OutOfMemory without leaks" {
    const Run = struct {
        fn run(gpa: Allocator) !void {
            var value: SecretValue = try .init(gpa);
            defer value.deinit();
            value.data = .init(try value.allocator().dupe(u8, "s3cr3t"));
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Run.run, .{});
}
