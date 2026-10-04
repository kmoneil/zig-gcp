//! RFC 3339 timestamps, the proto3 JSON form of `google.protobuf.Timestamp`:
//! pubsub's `publishTime`, Firestore's `timestampValue` and the like.

const std = @import("std");
const test_util = @import("testing.zig");

pub const ParseError = error{InvalidTimestamp};

/// The range `google.protobuf.Timestamp` allows, and `format` writes:
/// 0001-01-01T00:00:00Z to 9999-12-31T23:59:59.999999999Z.
pub const min: std.Io.Timestamp = .{ .nanoseconds = -62_135_596_800 * std.time.ns_per_s };
pub const max: std.Io.Timestamp = .{ .nanoseconds = 253_402_300_799 * std.time.ns_per_s + 999_999_999 };

/// The longest text `format` writes: `9999-12-31T23:59:59.999999999Z`.
pub const max_len = 30;

/// Whether `ts` is within `min` and `max`, so `format` can write it.
pub fn inRange(ts: std.Io.Timestamp) bool {
    return ts.nanoseconds >= min.nanoseconds and ts.nanoseconds <= max.nanoseconds;
}

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

/// Writes `ts` as the server writes timestamps: in UTC with `Z`, and no
/// fractional digits or 3, 6 or 9 of them, the fewest that hold it
/// exactly. `ts` must be `inRange`.
pub fn format(buf: *[max_len]u8, ts: std.Io.Timestamp) []const u8 {
    std.debug.assert(inRange(ts));
    const seconds: i64 = @intCast(@divFloor(ts.nanoseconds, std.time.ns_per_s));
    const nanos: u32 = @intCast(@mod(ts.nanoseconds, std.time.ns_per_s));
    const days = @divFloor(seconds, std.time.s_per_day);
    const secs_of_day = @mod(seconds, std.time.s_per_day);
    const date = civilFromDays(days);
    var w: std.Io.Writer = .fixed(buf);
    // Fits: max_len is sized for the longest value the assert allows.
    w.print("{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}", .{
        @as(u64, @intCast(date.year)),
        @as(u64, @intCast(date.month)),
        @as(u64, @intCast(date.day)),
        @as(u64, @intCast(@divFloor(secs_of_day, 3600))),
        @as(u64, @intCast(@mod(@divFloor(secs_of_day, 60), 60))),
        @as(u64, @intCast(@mod(secs_of_day, 60))),
    }) catch unreachable;
    if (nanos % std.time.ns_per_ms == 0) {
        if (nanos != 0) w.print(".{d:0>3}", .{nanos / std.time.ns_per_ms}) catch unreachable;
    } else if (nanos % std.time.ns_per_us == 0) {
        w.print(".{d:0>6}", .{nanos / std.time.ns_per_us}) catch unreachable;
    } else {
        w.print(".{d:0>9}", .{nanos}) catch unreachable;
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
        "2026-09-18T23:00:00+02:000",
        "2026-09-18T23:00:00X",
        "2026-09-18T23:00:00.5X",
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

fn expectFormat(expected: []const u8, ts: std.Io.Timestamp) !void {
    var buf: [max_len]u8 = undefined;
    try testing.expectEqualStrings(expected, format(&buf, ts));
}

fn at(seconds: i96, nanos: i96) std.Io.Timestamp {
    return .{ .nanoseconds = seconds * std.time.ns_per_s + nanos };
}

test "format writes 0, 3, 6 or 9 fractional digits, as the server does" {
    try expectFormat("1970-01-01T00:00:00Z", .{ .nanoseconds = 0 });
    try expectFormat("2026-09-18T23:00:00Z", at(1_789_772_400, 0));
    try expectFormat("2026-09-18T23:00:00.100Z", at(1_789_772_400, 100_000_000));
    try expectFormat("2026-09-18T23:00:00.123Z", at(1_789_772_400, 123_000_000));
    try expectFormat("2026-09-18T23:00:00.000120Z", at(1_789_772_400, 120_000));
    try expectFormat("2026-09-18T23:00:00.123456Z", at(1_789_772_400, 123_456_000));
    try expectFormat("2026-09-18T23:00:00.000001Z", at(1_789_772_400, 1_000));
    try expectFormat("2026-09-18T23:00:00.000000001Z", at(1_789_772_400, 1));
    try expectFormat("2026-09-18T23:00:00.123456789Z", at(1_789_772_400, 123_456_789));
    try expectFormat("2026-09-18T23:00:00.120000001Z", at(1_789_772_400, 120_000_001));
    // Captured from the emulator.
    try expectFormat("2026-09-18T23:12:18.388Z", at(1_789_773_138, 388_000_000));
}

test "format before the epoch counts the fraction forward" {
    try expectFormat("1969-12-31T23:59:59.999999999Z", .{ .nanoseconds = -1 });
    try expectFormat("1969-12-31T23:59:59.999Z", .{ .nanoseconds = -std.time.ns_per_ms });
    try expectFormat("1969-12-31T23:59:59Z", .{ .nanoseconds = -std.time.ns_per_s });
    try expectFormat("1969-12-31T23:59:58.500Z", .{ .nanoseconds = -1_500_000_000 });
    try expectFormat("1900-01-01T00:00:00Z", at(-2_208_988_800, 0));
}

test "format writes calendar edges" {
    try expectFormat("2000-02-29T00:00:00Z", at(951_782_400, 0));
    try expectFormat("2000-03-01T00:00:00Z", at(951_868_800, 0));
    try expectFormat("1900-03-01T00:00:00Z", at(-2_203_891_200, 0)); // 1900 has no Feb 29
    try expectFormat("1600-02-29T00:00:00Z", at(-11_670_998_400, 0));
    try expectFormat("2026-12-31T23:59:59Z", at(1_798_761_599, 0));
    try expectFormat("2027-01-01T00:00:00Z", at(1_798_761_600, 0));
}

test "format writes the range's ends, the longest at max_len" {
    try expectFormat("0001-01-01T00:00:00Z", min);
    try expectFormat("9999-12-31T23:59:59.999999999Z", max);
    var buf: [max_len]u8 = undefined;
    try testing.expectEqual(max_len, format(&buf, max).len);
    try testing.expectEqual(min, try parse("0001-01-01T00:00:00Z"));
    try testing.expectEqual(max, try parse("9999-12-31T23:59:59.999999999Z"));
}

test "inRange takes min and max and nothing past them" {
    try testing.expect(inRange(min));
    try testing.expect(inRange(max));
    try testing.expect(inRange(.{ .nanoseconds = 0 }));
    try testing.expect(!inRange(.{ .nanoseconds = min.nanoseconds - 1 }));
    try testing.expect(!inRange(.{ .nanoseconds = max.nanoseconds + 1 }));
    try testing.expect(!inRange(.{ .nanoseconds = std.math.minInt(i96) }));
    try testing.expect(!inRange(.{ .nanoseconds = std.math.maxInt(i96) }));
    // Year 0000 parses but is outside google.protobuf.Timestamp.
    try testing.expect(!inRange(try parse("0000-12-31T23:59:59.999999999Z")));
}

test "format round-trips every text parse takes" {
    // The parse tests' accepted texts, each with the form format writes.
    for ([_][2][]const u8{
        .{ "1970-01-01T00:00:00Z", "1970-01-01T00:00:00Z" },
        .{ "2026-09-18T23:00:00Z", "2026-09-18T23:00:00Z" },
        .{ "2026-09-18T23:00:00.123Z", "2026-09-18T23:00:00.123Z" },
        .{ "2026-09-18T23:00:00.123456Z", "2026-09-18T23:00:00.123456Z" },
        .{ "2026-09-18T23:00:00.123456789Z", "2026-09-18T23:00:00.123456789Z" },
        .{ "2026-09-18T23:00:00.1Z", "2026-09-18T23:00:00.100Z" },
        .{ "2026-09-18T23:00:00.1234Z", "2026-09-18T23:00:00.123400Z" },
        .{ "2026-09-18T23:00:00.1234567Z", "2026-09-18T23:00:00.123456700Z" },
        .{ "2026-09-18T23:00:00.000Z", "2026-09-18T23:00:00Z" },
        .{ "2026-09-19T01:00:00+02:00", "2026-09-18T23:00:00Z" },
        .{ "2026-09-18T21:30:00-01:30", "2026-09-18T23:00:00Z" },
        .{ "2026-09-18t23:00:00z", "2026-09-18T23:00:00Z" },
        .{ "2026-09-19T00:30:00.5+01:30", "2026-09-18T23:00:00.500Z" },
        .{ "1969-12-31T23:59:59Z", "1969-12-31T23:59:59Z" },
        .{ "2000-02-29T00:00:00Z", "2000-02-29T00:00:00Z" },
        .{ "2026-09-18T23:12:18.388Z", "2026-09-18T23:12:18.388Z" },
        .{ "2026-10-02T13:02:50.882009Z", "2026-10-02T13:02:50.882009Z" },
        .{ "2027-01-01T00:59:59+01:00", "2026-12-31T23:59:59Z" },
    }) |pair| {
        const ts = try parse(pair[0]);
        var buf: [max_len]u8 = undefined;
        const text = format(&buf, ts);
        testing.expectEqualStrings(pair[1], text) catch |err| {
            std.debug.print("formatting {s}\n", .{pair[0]});
            return err;
        };
        try testing.expectEqual(ts, try parse(text));
    }
}

/// The date and time `std.time.epoch` computes for `seconds`, a second
/// opinion on `civilFromDays` for instants since the epoch.
fn stdCivil(buf: *[19]u8, seconds: u64) []const u8 {
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = seconds };
    const year_day = epoch.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day = epoch.getDaySeconds();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}", .{
        year_day.year,         month_day.month.numeric(), @as(u8, month_day.day_index) + 1,
        day.getHoursIntoDay(), day.getMinutesIntoHour(),  day.getSecondsIntoMinute(),
    }) catch unreachable;
}

fn roundTripProperty(_: void, input: []const u8) !void {
    var g: test_util.ByteGen = .init(input);
    // Any instant from min to max, now and then right at either end.
    const span: u96 = @intCast(max.nanoseconds - min.nanoseconds);
    const ns: i96 = switch (g.intRange(u8, 0, 15)) {
        0 => min.nanoseconds + g.intRange(u8, 0, 3),
        1 => max.nanoseconds - g.intRange(u8, 0, 3),
        else => min.nanoseconds + @as(i96, @intCast(g.int(u96) % (span + 1))),
    };
    var buf: [max_len]u8 = undefined;
    const text = format(&buf, .{ .nanoseconds = ns });
    try testing.expectEqual(ns, (try parse(text)).nanoseconds);

    // The shape: a 19-byte date and time, the fewest of 0, 3, 6 or 9
    // fractional digits that hold the nanoseconds, and Z.
    const nanos: u32 = @intCast(@mod(ns, std.time.ns_per_s));
    const digits_wanted: usize = if (nanos == 0) 0 else if (nanos % std.time.ns_per_ms == 0) 3 else if (nanos % std.time.ns_per_us == 0) 6 else 9;
    const len_wanted = 19 + @as(usize, if (digits_wanted == 0) 0 else 1 + digits_wanted) + 1;
    try testing.expectEqual(len_wanted, text.len);
    try testing.expectEqual('Z', text[text.len - 1]);

    const seconds = @divFloor(ns, std.time.ns_per_s);
    if (seconds >= 0) {
        var civil_buf: [19]u8 = undefined;
        try testing.expectEqualStrings(stdCivil(&civil_buf, @intCast(seconds)), text[0..19]);
    }
}

test "fuzz format: instants round-trip in the server's shape" {
    try test_util.fuzzBytes({}, roundTripProperty, .{ .corpus = &.{
        "",
        "\x00",
        "\x01",
        "\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff",
    } });
}

fn arbitraryProperty(_: void, input: []const u8) !void {
    const ts = parse(input) catch return;
    // Year 0000 parses, as does a year-0001 or year-9999 local time whose
    // offset carries it outside 0001..9999 in UTC; neither is a
    // google.protobuf.Timestamp, so format refuses them. (Found by this
    // test.)
    if (!inRange(ts)) return;
    // Anything accepted formats back to something that parses to the same instant.
    var buf: [max_len]u8 = undefined;
    try testing.expectEqual(ts.nanoseconds, (try parse(format(&buf, ts))).nanoseconds);
}

test "fuzz parse: arbitrary text never crashes" {
    try test_util.fuzzBytes({}, arbitraryProperty, .{
        .corpus = &.{
            "2026-09-18T23:12:18.388Z",
            "0000-01-01T00:00:00+23:59",
            "0001-01-01T00:00:00+00:01",
            "9999-12-31T23:59:59.999999999-23:59",
            "2026-09-18T23:00:00.",
            // Valid up to the last few bytes, so mutations explore the offset.
            "2026-09-18T23:00:00.123456+05:30",
            "2026-09-18T23:00:00+02:000",
            "2026-09-18T23:00:00X",
        },
    });
}
