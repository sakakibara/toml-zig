//! RFC 3339 date/time parsing for TOML 1.1.
//!
//! TOML defines four datetime-like types, all derived from RFC 3339:
//! - Offset date-time: `YYYY-MM-DDTHH:MM:SS[.fff]+/-HH:MM` or `...Z`
//! - Local date-time:  `YYYY-MM-DDTHH:MM:SS[.fff]` (T or space separator)
//! - Local date:       `YYYY-MM-DD`
//! - Local time:       `HH:MM:SS[.fff]`
//!
//! Parsing is hand-rolled against a byte slice  -  no regex, no heap
//! allocations, no errors beyond `InvalidDateTime`.

const std = @import("std");
const v = @import("value.zig");

pub const Date = v.Date;
pub const Time = v.Time;
pub const DateTime = v.DateTime;

/// Tagged result of `parseAny`. The caller (parser.zig) uses this to
/// pick the matching `Value` variant.
pub const Parsed = union(enum) {
    datetime: DateTime,
    date: Date,
    time: Time,
};

pub const Error = error{InvalidDateTime};

/// Parse a single date/time/datetime literal from the entire slice.
/// The slice must contain exactly the literal  -  no trailing whitespace
/// or extra bytes.
pub fn parseAny(s: []const u8) Error!Parsed {
    // Date-like: starts with `YYYY-`
    if (s.len >= 10 and isDigit(s[0]) and isDigit(s[1]) and isDigit(s[2]) and isDigit(s[3]) and s[4] == '-') {
        const date = try parseDate(s[0..10]);
        if (s.len == 10) return .{ .date = date };

        // Must be a full datetime: separator T, t, or space.
        const sep = s[10];
        if (sep != 'T' and sep != 't' and sep != ' ') return error.InvalidDateTime;
        // Time after separator is at least HH:MM (5 chars).
        if (s.len < 16) return error.InvalidDateTime;

        const time_end_and_rest = try parseTimePrefix(s[11..]);
        var dt = DateTime{ .date = date, .time = time_end_and_rest.time, .tz_offset_minutes = null };

        const rest = s[11 + time_end_and_rest.consumed ..];
        if (rest.len == 0) return .{ .datetime = dt };

        // Offset follows. `Z`, `z`, or `+/-HH:MM`.
        dt.tz_offset_minutes = try parseOffset(rest);
        return .{ .datetime = dt };
    }

    // Time-like: HH:MM:SS[.fff]
    const tp = try parseTimePrefix(s);
    if (tp.consumed != s.len) return error.InvalidDateTime;
    return .{ .time = tp.time };
}

/// Parse `YYYY-MM-DD`.
pub fn parseDate(s: []const u8) Error!Date {
    if (s.len != 10) return error.InvalidDateTime;
    if (s[4] != '-' or s[7] != '-') return error.InvalidDateTime;
    const year = try parseUint(u16, s[0..4]);
    const month = try parseUint(u8, s[5..7]);
    const day = try parseUint(u8, s[8..10]);
    try validateDate(year, month, day);
    return .{ .year = year, .month = month, .day = day };
}

/// Parse a `HH:MM:SS[.fff]` literal (entire input).
pub fn parseTimeOnly(s: []const u8) Error!Time {
    const tp = try parseTimePrefix(s);
    if (tp.consumed != s.len) return error.InvalidDateTime;
    return tp.time;
}

const TimePrefix = struct { time: Time, consumed: usize };

/// Parse a `HH:MM[:SS[.fff]]` prefix from `s`. Returns the parsed Time
/// and how many bytes were consumed. Seconds and fractional seconds are
/// both optional (TOML 1.1).
fn parseTimePrefix(s: []const u8) Error!TimePrefix {
    if (s.len < 5) return error.InvalidDateTime;
    if (s[2] != ':') return error.InvalidDateTime;
    const hour = try parseUint(u8, s[0..2]);
    const minute = try parseUint(u8, s[3..5]);
    if (hour > 23 or minute > 59) return error.InvalidDateTime;

    var consumed: usize = 5;
    var second: u8 = 0;
    var nanos: u32 = 0;

    if (s.len > 5 and s[5] == ':') {
        if (s.len < 8) return error.InvalidDateTime;
        second = try parseUint(u8, s[6..8]);
        if (second > 60) return error.InvalidDateTime; // 60 = leap second
        consumed = 8;

        if (s.len > 8 and s[8] == '.') {
            consumed = 9;
            const frac_start = consumed;
            while (consumed < s.len and isDigit(s[consumed])) consumed += 1;
            const frac_len = consumed - frac_start;
            if (frac_len == 0) return error.InvalidDateTime;
            var scale: u32 = 1_000_000_000;
            const take = @min(frac_len, 9);
            var i: usize = 0;
            while (i < take) : (i += 1) {
                const d: u32 = @intCast(s[frac_start + i] - '0');
                scale /= 10;
                nanos += d * scale;
            }
        }
    }

    return .{ .time = .{ .hour = hour, .minute = minute, .second = second, .nanos = nanos }, .consumed = consumed };
}

/// Parse an RFC 3339 offset (`Z`, `z`, `+HH:MM`, `-HH:MM`) covering
/// the entirety of `s`. Returns minutes east of UTC.
fn parseOffset(s: []const u8) Error!i16 {
    if (s.len == 1 and (s[0] == 'Z' or s[0] == 'z')) return 0;
    if (s.len != 6) return error.InvalidDateTime;
    const sign: i16 = switch (s[0]) {
        '+' => 1,
        '-' => -1,
        else => return error.InvalidDateTime,
    };
    if (s[3] != ':') return error.InvalidDateTime;
    const hh = try parseUint(u8, s[1..3]);
    const mm = try parseUint(u8, s[4..6]);
    if (hh > 23 or mm > 59) return error.InvalidDateTime;
    return sign * (@as(i16, hh) * 60 + @as(i16, mm));
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn parseUint(comptime T: type, s: []const u8) Error!T {
    var n: T = 0;
    for (s) |c| {
        if (!isDigit(c)) return error.InvalidDateTime;
        n = n * 10 + @as(T, c - '0');
    }
    return n;
}

fn validateDate(year: u16, month: u8, day: u8) Error!void {
    if (month < 1 or month > 12) return error.InvalidDateTime;
    if (day < 1) return error.InvalidDateTime;
    const days_in_month = [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    var max = days_in_month[month - 1];
    if (month == 2 and isLeap(year)) max = 29;
    if (day > max) return error.InvalidDateTime;
}

fn isLeap(year: u16) bool {
    if (year % 400 == 0) return true;
    if (year % 100 == 0) return false;
    return year % 4 == 0;
}

test "parse date" {
    const d = try parseDate("1979-05-27");
    try std.testing.expectEqual(@as(u16, 1979), d.year);
    try std.testing.expectEqual(@as(u8, 5), d.month);
    try std.testing.expectEqual(@as(u8, 27), d.day);
}

test "parse date invalid" {
    try std.testing.expectError(error.InvalidDateTime, parseDate("1979/05/27"));
    try std.testing.expectError(error.InvalidDateTime, parseDate("1979-13-01"));
    try std.testing.expectError(error.InvalidDateTime, parseDate("1979-02-30"));
    try std.testing.expectError(error.InvalidDateTime, parseDate("1900-02-29")); // not leap
    // 2000 IS leap: Gregorian rule %400.
    const d = try parseDate("2000-02-29");
    try std.testing.expectEqual(@as(u8, 29), d.day);
}

test "parse time" {
    const p = try parseAny("07:32:00");
    try std.testing.expectEqual(@as(u8, 7), p.time.hour);
    try std.testing.expectEqual(@as(u8, 32), p.time.minute);
    try std.testing.expectEqual(@as(u8, 0), p.time.second);
    try std.testing.expectEqual(@as(u32, 0), p.time.nanos);
}

test "parse time with ms" {
    const p = try parseAny("00:32:00.999999");
    try std.testing.expectEqual(@as(u32, 999_999_000), p.time.nanos);
}

test "parse local datetime" {
    const p = try parseAny("1979-05-27T07:32:00");
    try std.testing.expectEqual(@as(u16, 1979), p.datetime.date.year);
    try std.testing.expectEqual(@as(u8, 7), p.datetime.time.hour);
    try std.testing.expect(p.datetime.tz_offset_minutes == null);
}

test "parse local datetime space sep" {
    const p = try parseAny("1979-05-27 07:32:00");
    try std.testing.expectEqual(@as(u8, 7), p.datetime.time.hour);
}

test "parse offset datetime Z" {
    const p = try parseAny("1979-05-27T07:32:00Z");
    try std.testing.expectEqual(@as(i16, 0), p.datetime.tz_offset_minutes.?);
}

test "parse offset datetime + offset" {
    const p = try parseAny("1979-05-27T00:32:00-07:00");
    try std.testing.expectEqual(@as(i16, -420), p.datetime.tz_offset_minutes.?);
}

test "parse offset datetime + fractional" {
    const p = try parseAny("1979-05-27T07:32:00.999999+09:30");
    try std.testing.expectEqual(@as(i16, 9 * 60 + 30), p.datetime.tz_offset_minutes.?);
    try std.testing.expectEqual(@as(u32, 999_999_000), p.datetime.time.nanos);
}

test "parse invalid" {
    try std.testing.expectError(error.InvalidDateTime, parseAny("1979-05-27T25:00:00"));
    try std.testing.expectError(error.InvalidDateTime, parseAny("1979-05-27T07:60:00"));
    try std.testing.expectError(error.InvalidDateTime, parseAny("1979-05-27T07:32:00+25:00"));
    try std.testing.expectError(error.InvalidDateTime, parseAny("1979-05-27T07:32:00."));
    try std.testing.expectError(error.InvalidDateTime, parseAny("not a date"));
}

test "truncate fractional beyond 9 digits" {
    const p = try parseAny("00:00:00.1234567890123");
    try std.testing.expectEqual(@as(u32, 123_456_789), p.time.nanos);
}
