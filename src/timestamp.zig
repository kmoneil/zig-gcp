//! RFC 3339 timestamps, the format of `publishTime`.

const std = @import("std");
const test_util = @import("test_util.zig");

pub const ParseError = error{InvalidTimestamp};

/// Parses an RFC 3339 timestamp such as `2026-09-18T10:00:00.123Z` to
/// nanoseconds since the Unix epoch. Accepts 0 to 9 fractional digits and
/// either `Z` or a numeric offset. Leap seconds (`:60`) are rejected; Google
/// smears them, so the server never sends one.
pub fn parse(text: []const u8) ParseError!std.Io.Timestamp {
    if (text.len < 20) return error.InvalidTimestamp;
    const year = try digits(text[0..4]);
    try expect(text[4], '-');
    const month = try digits(text[5..7]);
    try expect(text[7], '-');
    const day = try digits(text[8..10]);
    if (text[10] != 'T' and text[10] != 't') return error.InvalidTimestamp;
    const hour = try digits(text[11..13]);
    try expect(text[13], ':');
    const minute = try digits(text[14..16]);
    try expect(text[16], ':');
    const second = try digits(text[17..19]);

    var i: usize = 19;
    var nanos: u32 = 0;
    if (text[i] == '.') {
        i += 1;
        const start = i;
        while (i < text.len and std.ascii.isDigit(text[i])) : (i += 1) {
            if (i - start == 9) return error.InvalidTimestamp;
            nanos = nanos * 10 + (text[i] - '0');
        }
        const n = i - start;
        if (n == 0) return error.InvalidTimestamp;
        nanos *= std.math.pow(u32, 10, @intCast(9 - n));
    }

    if (i >= text.len) return error.InvalidTimestamp;
    var offset_seconds: i64 = 0;
    switch (text[i]) {
        'Z', 'z' => i += 1,
        '+', '-' => |sign| {
            if (text.len - i != 6) return error.InvalidTimestamp;
            const off_hour = try digits(text[i + 1 ..][0..2]);
            try expect(text[i + 3], ':');
            const off_minute = try digits(text[i + 4 ..][0..2]);
            if (off_hour > 23 or off_minute > 59) return error.InvalidTimestamp;
            offset_seconds = (off_hour * 60 + off_minute) * 60;
            if (sign == '-') offset_seconds = -offset_seconds;
            i += 6;
        },
        else => return error.InvalidTimestamp,
    }
    if (i != text.len) return error.InvalidTimestamp;

    if (month < 1 or month > 12) return error.InvalidTimestamp;
    if (day < 1 or day > daysInMonth(year, month)) return error.InvalidTimestamp;
    if (hour > 23 or minute > 59 or second > 59) return error.InvalidTimestamp;

    const seconds = daysFromCivil(year, month, day) * std.time.s_per_day +
        hour * 3600 + minute * 60 + second - offset_seconds;
    return .{ .nanoseconds = @as(i96, seconds) * std.time.ns_per_s + nanos };
}

fn digits(text: []const u8) ParseError!i64 {
    var v: i64 = 0;
    for (text) |c| {
        if (!std.ascii.isDigit(c)) return error.InvalidTimestamp;
        v = v * 10 + (c - '0');
    }
    return v;
}

fn expect(actual: u8, wanted: u8) ParseError!void {
    if (actual != wanted) return error.InvalidTimestamp;
}

fn isLeapYear(year: i64) bool {
    return @mod(year, 4) == 0 and (@mod(year, 100) != 0 or @mod(year, 400) == 0);
}

fn daysInMonth(year: i64, month: i64) i64 {
    return switch (month) {
        2 => if (isLeapYear(year)) 29 else 28,
        4, 6, 9, 11 => 30,
        else => 31,
    };
}

/// Days since 1970-01-01 in the proleptic Gregorian calendar
/// (Howard Hinnant's algorithm).
fn daysFromCivil(year: i64, month: i64, day: i64) i64 {
    const y = if (month <= 2) year - 1 else year;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp = @mod(month + 9, 12);
    const doy = @divFloor(153 * mp + 2, 5) + day - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

/// The inverse of `daysFromCivil`.
fn civilFromDays(days: i64) struct { year: i64, month: i64, day: i64 } {
    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const day = doy - @divFloor(153 * mp + 2, 5) + 1;
    const month = if (mp < 10) mp + 3 else mp - 9;
    return .{ .year = yoe + era * 400 + @intFromBool(month <= 2), .month = month, .day = day };
}

/// Formats as the server does: UTC, with 0, 3, 6 or 9 fractional digits.
/// Test-only: v1 has no use for formatting.
fn format(ts: std.Io.Timestamp, buf: *[30]u8) []const u8 {
    const seconds: i64 = @intCast(@divFloor(ts.nanoseconds, std.time.ns_per_s));
    const nanos: u32 = @intCast(@mod(ts.nanoseconds, std.time.ns_per_s));
    const days = @divFloor(seconds, std.time.s_per_day);
    const secs_of_day = @mod(seconds, std.time.s_per_day);
    const date = civilFromDays(days);
    var w: std.Io.Writer = .fixed(buf);
    w.print("{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}", .{
        @as(u64, @intCast(date.year)),
        @as(u64, @intCast(date.month)),
        @as(u64, @intCast(date.day)),
        @as(u64, @intCast(@divFloor(secs_of_day, 3600))),
        @as(u64, @intCast(@mod(@divFloor(secs_of_day, 60), 60))),
        @as(u64, @intCast(@mod(secs_of_day, 60))),
    }) catch unreachable;
    if (nanos != 0) {
        if (nanos % 1_000_000 == 0) {
            w.print(".{d:0>3}", .{nanos / 1_000_000}) catch unreachable;
        } else if (nanos % 1000 == 0) {
            w.print(".{d:0>6}", .{nanos / 1000}) catch unreachable;
        } else {
            w.print(".{d:0>9}", .{nanos}) catch unreachable;
        }
    }
    w.writeByte('Z') catch unreachable;
    return w.buffered();
}

const testing = std.testing;

fn expectNs(expected: i96, text: []const u8) !void {
    try testing.expectEqual(expected, (try parse(text)).nanoseconds);
}

test "parse: fractional digits, offsets, epoch" {
    try expectNs(0, "1970-01-01T00:00:00Z");
    try expectNs(1_789_772_400 * std.time.ns_per_s, "2026-09-18T23:00:00Z");
    try expectNs(1_789_772_400 * std.time.ns_per_s + 123_000_000, "2026-09-18T23:00:00.123Z");
    try expectNs(1_789_772_400 * std.time.ns_per_s + 123_456_000, "2026-09-18T23:00:00.123456Z");
    try expectNs(1_789_772_400 * std.time.ns_per_s + 123_456_789, "2026-09-18T23:00:00.123456789Z");
    try expectNs(1_789_772_400 * std.time.ns_per_s + 100_000_000, "2026-09-18T23:00:00.1Z");
    try expectNs(1_789_772_400 * std.time.ns_per_s, "2026-09-19T01:00:00+02:00");
    try expectNs(1_789_772_400 * std.time.ns_per_s, "2026-09-18T21:30:00-01:30");
    try expectNs(1_789_772_400 * std.time.ns_per_s, "2026-09-18t23:00:00z");
    try expectNs(-std.time.ns_per_s, "1969-12-31T23:59:59Z");
    try expectNs(951_782_400 * std.time.ns_per_s, "2000-02-29T00:00:00Z");
    // Captured from the emulator.
    try expectNs(1_789_773_138_388_000_000, "2026-09-18T23:12:18.388Z");
}

test "parse: rejects malformed text" {
    for ([_][]const u8{
        "",
        "2026-09-18",
        "2026-09-18T23:00:00",
        "2026-09-18 23:00:00Z",
        "2026-13-18T23:00:00Z",
        "2026-00-18T23:00:00Z",
        "2026-02-29T23:00:00Z",
        "1900-02-29T00:00:00Z",
        "2026-04-31T23:00:00Z",
        "2026-09-18T24:00:00Z",
        "2026-09-18T23:60:00Z",
        "2026-09-18T23:59:60Z",
        "2026-09-18T23:00:00.Z",
        "2026-09-18T23:00:00.1234567890Z",
        "2026-09-18T23:00:00+2:00",
        "2026-09-18T23:00:00+24:00",
        "2026-09-18T23:00:00+02:60",
        "2026-09-18T23:00:00Zjunk",
        "2026-09-18T23:00:00.123",
        "+026-09-18T23:00:00Z",
        "2026-09-18T23:00:0aZ",
    }) |text| {
        if (parse(text)) |_| {
            std.debug.print("accepted {s}\n", .{text});
            return error.TestUnexpectedSuccess;
        } else |err| try testing.expectEqual(error.InvalidTimestamp, err);
    }
}

test "format matches the server's shape" {
    var buf: [30]u8 = undefined;
    try testing.expectEqualStrings("2026-09-18T23:12:18.388Z", format(try parse("2026-09-18T23:12:18.388Z"), &buf));
    try testing.expectEqualStrings("1970-01-01T00:00:00Z", format(.{ .nanoseconds = 0 }, &buf));
    try testing.expectEqualStrings("1969-12-31T23:59:59.999999999Z", format(.{ .nanoseconds = -1 }, &buf));
}

fn roundTripProperty(_: void, input: []const u8) !void {
    var g: test_util.ByteGen = .init(input);
    // Any instant from 0001-01-01 to 9999-12-31.
    const min: i96 = -62_135_596_800 * std.time.ns_per_s;
    const max: i96 = 253_402_300_799 * std.time.ns_per_s + 999_999_999;
    const span: u96 = @intCast(max - min);
    const ns = min + @as(i96, @intCast(g.int(u96) % (span + 1)));
    var buf: [30]u8 = undefined;
    const text = format(.{ .nanoseconds = ns }, &buf);
    try testing.expectEqual(ns, (try parse(text)).nanoseconds);
}

test "fuzz parse: formatted instants round-trip" {
    try test_util.fuzzBytes({}, roundTripProperty, .{ .corpus = &.{ "", "\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff" } });
}

fn arbitraryProperty(_: void, input: []const u8) !void {
    const ts = parse(input) catch return;
    // A year-0000 or year-9999 local time with an offset can land outside
    // 0000..9999 in UTC, which RFC 3339 cannot write. (Found by this test.)
    const first: i96 = -62_167_219_200 * std.time.ns_per_s; // 0000-01-01T00:00:00Z
    const last: i96 = 253_402_300_799 * std.time.ns_per_s + 999_999_999; // 9999-12-31T23:59:59.999999999Z
    if (ts.nanoseconds < first or ts.nanoseconds > last) return;
    // Anything accepted formats back to something that parses to the same instant.
    var buf: [30]u8 = undefined;
    try testing.expectEqual(ts.nanoseconds, (try parse(format(ts, &buf))).nanoseconds);
}

test "fuzz parse: arbitrary text never crashes" {
    try test_util.fuzzBytes({}, arbitraryProperty, .{ .corpus = &.{
        "2026-09-18T23:12:18.388Z",
        "0000-01-01T00:00:00+23:59",
        "9999-12-31T23:59:59.999999999-23:59",
        "2026-09-18T23:00:00.",
    } });
}
