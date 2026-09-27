//! Durations as Google's JSON APIs write them: the proto3 JSON mapping of
//! `google.protobuf.Duration`, seconds with up to nine fractional digits
//! and an `s`, such as `600s` or `1.500s`.

const std = @import("std");
const test_util = @import("testing.zig");

pub const ParseError = error{InvalidDuration};

/// The range `google.protobuf.Duration` allows, in seconds either way:
/// about 10,000 years.
pub const max_seconds = 315_576_000_000;

/// The longest text `format` writes: `-315576000000.000000001s`.
pub const max_len = 24;

/// Parses a duration such as `3s`, `-1.5s` or `0.000000001s`: an optional
/// minus, whole seconds, a dot and one to nine fractional digits if any,
/// then `s`. Anything else is refused, as is a value outside
/// `max_seconds` either way.
pub fn parse(text: []const u8) ParseError!std.Io.Duration {
    if (text.len < 2 or text[text.len - 1] != 's') return error.InvalidDuration;
    var body = text[0 .. text.len - 1];
    const negative = body[0] == '-';
    if (negative) body = body[1..];
    const dot = std.mem.indexOfScalar(u8, body, '.');
    const whole = if (dot) |d| body[0..d] else body;
    const fraction = if (dot) |d| body[d + 1 ..] else "";
    if (whole.len == 0 or (dot != null and fraction.len == 0) or fraction.len > 9) return error.InvalidDuration;

    var seconds: u64 = 0;
    for (whole) |c| {
        if (!std.ascii.isDigit(c)) return error.InvalidDuration;
        seconds = std.math.mul(u64, seconds, 10) catch return error.InvalidDuration;
        seconds = std.math.add(u64, seconds, c - '0') catch return error.InvalidDuration;
    }
    if (seconds > max_seconds) return error.InvalidDuration;
    var nanos: u64 = 0;
    for (fraction) |c| {
        if (!std.ascii.isDigit(c)) return error.InvalidDuration;
        nanos = nanos * 10 + (c - '0');
    }
    for (fraction.len..9) |_| nanos *= 10;
    // The fraction cannot take a duration of max_seconds past the range.
    if (seconds == max_seconds and nanos != 0) return error.InvalidDuration;

    const total = @as(i96, seconds) * std.time.ns_per_s + nanos;
    return .{ .nanoseconds = if (negative) -total else total };
}

/// Writes `d` as the server writes durations: whole seconds, then no
/// fractional digits or 3, 6 or 9 of them, and `s`. `d` must be within
/// `max_seconds` either way.
pub fn format(buf: *[max_len]u8, d: std.Io.Duration) []const u8 {
    std.debug.assert(@abs(d.nanoseconds) <= @as(u96, max_seconds) * std.time.ns_per_s);
    var w: std.Io.Writer = .fixed(buf);
    const magnitude: u96 = @abs(d.nanoseconds);
    const seconds = magnitude / std.time.ns_per_s;
    const nanos: u32 = @intCast(magnitude % std.time.ns_per_s);
    // Fits: max_len is sized for the longest value the assert allows.
    if (d.nanoseconds < 0) w.writeByte('-') catch unreachable;
    w.print("{d}", .{seconds}) catch unreachable;
    if (nanos % std.time.ns_per_ms == 0) {
        if (nanos != 0) w.print(".{d:0>3}", .{nanos / std.time.ns_per_ms}) catch unreachable;
    } else if (nanos % std.time.ns_per_us == 0) {
        w.print(".{d:0>6}", .{nanos / std.time.ns_per_us}) catch unreachable;
    } else {
        w.print(".{d:0>9}", .{nanos}) catch unreachable;
    }
    w.writeByte('s') catch unreachable;
    return w.buffered();
}

const testing = std.testing;

fn expectFormat(expected: []const u8, d: std.Io.Duration) !void {
    var buf: [max_len]u8 = undefined;
    try testing.expectEqualStrings(expected, format(&buf, d));
}

test "format writes 0, 3, 6 or 9 fractional digits, as the server does" {
    try expectFormat("0s", .zero);
    try expectFormat("600s", .fromSeconds(600));
    try expectFormat("604800s", .fromSeconds(7 * 24 * 3600));
    try expectFormat("1.500s", .fromMilliseconds(1500));
    try expectFormat("0.000001s", .fromMicroseconds(1));
    try expectFormat("2.000100s", .fromMicroseconds(2_000_100));
    try expectFormat("0.000000001s", .fromNanoseconds(1));
    try expectFormat("-1.250s", .fromMilliseconds(-1250));
    try expectFormat("-315576000000s", .fromSeconds(-max_seconds));
    try expectFormat("315576000000s", .fromSeconds(max_seconds));
}

test "parse takes every form the mapping allows" {
    try testing.expectEqual(std.Io.Duration.fromSeconds(600), try parse("600s"));
    try testing.expectEqual(std.Io.Duration.fromMilliseconds(1500), try parse("1.5s"));
    try testing.expectEqual(std.Io.Duration.fromMilliseconds(1500), try parse("1.500s"));
    try testing.expectEqual(std.Io.Duration.fromMilliseconds(1500), try parse("1.500000000s"));
    try testing.expectEqual(std.Io.Duration.fromNanoseconds(1), try parse("0.000000001s"));
    try testing.expectEqual(std.Io.Duration.fromMilliseconds(-250), try parse("-0.25s"));
    try testing.expectEqual(std.Io.Duration.zero, try parse("0s"));
    try testing.expectEqual(std.Io.Duration.zero, try parse("-0s"));
    try testing.expectEqual(std.Io.Duration.fromSeconds(max_seconds), try parse("315576000000s"));
    try testing.expectEqual(std.Io.Duration.fromSeconds(-max_seconds), try parse("-315576000000.000s"));
    // Leading zeros are digits like any other.
    try testing.expectEqual(std.Io.Duration.fromSeconds(7), try parse("007s"));
}

test "parse refuses anything else" {
    for ([_][]const u8{
        "",       "s",    "1",             "1S",                      "1.s",
        ".5s",    "-s",   "--1s",          "+1s",                     " 1s",
        "1 s",    "1e3s", "1.1234567890s", "0x10s",                   "1..5s",
        "1.5.0s", "-.5s", "315576000001s", "315576000000.000000001s", "99999999999999999999999s",
    }) |text| {
        testing.expectError(error.InvalidDuration, parse(text)) catch |err| {
            std.debug.print("parse took \"{s}\"\n", .{text});
            return err;
        };
    }
}

fn roundTripProperty(_: void, input: []const u8) !void {
    var g: test_util.ByteGen = .init(input);
    const limit: u96 = @as(u96, max_seconds) * std.time.ns_per_s;
    // Any value in range, and often a round one, which the shorter forms
    // write.
    var magnitude: u96 = @intCast(g.int(u128) % (limit + 1));
    switch (g.intRange(u8, 0, 3)) {
        0 => magnitude -= magnitude % std.time.ns_per_s,
        1 => magnitude -= magnitude % std.time.ns_per_ms,
        2 => magnitude -= magnitude % std.time.ns_per_us,
        else => {},
    }
    const signed: i96 = @intCast(magnitude);
    const d: std.Io.Duration = .{ .nanoseconds = if (g.boolean()) -signed else signed };
    var buf: [max_len]u8 = undefined;
    const text = format(&buf, d);
    try testing.expectEqual(d, try parse(text));
    // And parse is total: arbitrary text is a duration or refused.
    if (parse(g.rest())) |any| {
        try testing.expect(@abs(any.nanoseconds) <= limit);
    } else |_| {}
}

test "fuzz duration: format round-trips through parse, and parse is total" {
    try test_util.fuzzBytes({}, roundTripProperty, .{ .corpus = &.{
        "",
        "\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\x03\x01",
        "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01\x03\x00-1.5s",
    } });
}
