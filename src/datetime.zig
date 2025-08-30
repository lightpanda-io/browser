const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Date = struct {
    year: i16,
    month: u8,
    day: u8,

    pub const Format = enum {
        iso8601,
        rfc3339,
    };

    pub fn init(year: i16, month: u8, day: u8) !Date {
        if (!Date.valid(year, month, day)) {
            return error.InvalidDate;
        }

        return .{
            .year = year,
            .month = month,
            .day = day,
        };
    }

    pub fn valid(year: i16, month: u8, day: u8) bool {
        if (month == 0 or month > 12) {
            return false;
        }

        if (day == 0) {
            return false;
        }

        const month_days = [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
        const max_days = if (month == 2 and (@rem(year, 400) == 0 or (@rem(year, 100) != 0 and @rem(year, 4) == 0))) 29 else month_days[month - 1];
        if (day > max_days) {
            return false;
        }

        return true;
    }

    pub fn parse(input: []const u8, fmt: Format) !Date {
        var parser = Parser.init(input);

        const date = switch (fmt) {
            .rfc3339 => try parser.rfc3339Date(),
            .iso8601 => try parser.iso8601Date(),
        };

        if (parser.unconsumed() != 0) {
            return error.InvalidDate;
        }

        return date;
    }

    pub fn order(a: Date, b: Date) std.math.Order {
        const year_order = std.math.order(a.year, b.year);
        if (year_order != .eq) return year_order;

        const month_order = std.math.order(a.month, b.month);
        if (month_order != .eq) return month_order;

        return std.math.order(a.day, b.day);
    }

    pub fn format(self: Date, writer: *std.Io.Writer) !void {
        var buf: [11]u8 = undefined;
        const n = writeDate(&buf, self);
        try writer.writeAll(buf[0..n]);
    }

    pub fn jsonStringify(self: Date, out: anytype) !void {
        // Our goal here isn't to validate the date. It's to write what we have
        // in a YYYY-MM-DD format. If the data in Date isn't valid, that's not
        // our problem and we don't guarantee any reasonable output in such cases.

        // std.fmt.formatInt is difficult to work with. The padding with signs
        // doesn't work and it'll always put a + sign given a signed integer with padding
        // So, for year, we always feed it an unsigned number (which avoids both issues)
        // and prepend the - if we need it.s
        var buf: [13]u8 = undefined;
        const n = writeDate(buf[1..12], self);
        buf[0] = '"';
        buf[n + 1] = '"';
        try out.print("{s}", .{buf[0 .. n + 2]});
    }

    pub fn jsonParse(allocator: Allocator, source: anytype, options: anytype) !Date {
        _ = options;

        switch (try source.nextAlloc(allocator, .alloc_if_needed)) {
            inline .string, .allocated_string => |str| return Date.parse(str, .rfc3339) catch return error.InvalidCharacter,
            else => return error.UnexpectedToken,
        }
    }
};

pub const Time = struct {
    hour: u8,
    min: u8,
    sec: u8,
    micros: u32,

    pub const Format = enum {
        rfc3339,
    };

    pub fn init(hour: u8, min: u8, sec: u8, micros: u32) !Time {
        if (!Time.valid(hour, min, sec, micros)) {
            return error.InvalidTime;
        }

        return .{
            .hour = hour,
            .min = min,
            .sec = sec,
            .micros = micros,
        };
    }

    pub fn valid(hour: u8, min: u8, sec: u8, micros: u32) bool {
        if (hour > 23) {
            return false;
        }

        if (min > 59) {
            return false;
        }

        if (sec > 59) {
            return false;
        }

        if (micros > 999999) {
            return false;
        }

        return true;
    }

    pub fn parse(input: []const u8, fmt: Format) !Time {
        var parser = Parser.init(input);
        const time = switch (fmt) {
            .rfc3339 => try parser.time(true),
        };

        if (parser.unconsumed() != 0) {
            return error.InvalidTime;
        }
        return time;
    }

    pub fn order(a: Time, b: Time) std.math.Order {
        const hour_order = std.math.order(a.hour, b.hour);
        if (hour_order != .eq) return hour_order;

        const min_order = std.math.order(a.min, b.min);
        if (min_order != .eq) return min_order;

        const sec_order = std.math.order(a.sec, b.sec);
        if (sec_order != .eq) return sec_order;

        return std.math.order(a.micros, b.micros);
    }

    pub fn format(self: Time, writer: *std.Io.Writer) !void {
        var buf: [15]u8 = undefined;
        const n = writeTime(&buf, self);
        try writer.writeAll(buf[0..n]);
    }

    pub fn jsonStringify(self: Time, out: anytype) !void {
        // Our goal here isn't to validate the time. It's to write what we have
        // in a hh:mm:ss.sss format. If the data in Time isn't valid, that's not
        // our problem and we don't guarantee any reasonable output in such cases.
        var buf: [17]u8 = undefined;
        const n = writeTime(buf[1..16], self);
        buf[0] = '"';
        buf[n + 1] = '"';
        try out.print("{s}", .{buf[0 .. n + 2]});
    }

    pub fn jsonParse(allocator: Allocator, source: anytype, options: anytype) !Time {
        _ = options;

        switch (try source.nextAlloc(allocator, .alloc_if_needed)) {
            inline .string, .allocated_string => |str| return Time.parse(str, .rfc3339) catch return error.InvalidCharacter,
            else => return error.UnexpectedToken,
        }
    }
};

pub const DateTime = struct {
    micros: i64,

    const MICROSECONDS_IN_A_DAY = 86_400_000_000;
    const MICROSECONDS_IN_AN_HOUR = 3_600_000_000;
    const MICROSECONDS_IN_A_MIN = 60_000_000;
    const MICROSECONDS_IN_A_SEC = 1_000_000;

    pub const Format = enum {
        rfc822,
        rfc3339,
    };

    pub const TimestampPrecision = enum {
        seconds,
        milliseconds,
        microseconds,
    };

    pub const TimeUnit = enum {
        days,
        hours,
        minutes,
        seconds,
        milliseconds,
        microseconds,
    };

    // https://blog.reverberate.org/2020/05/12/optimizing-date-algorithms.html
    pub fn initUTC(year: i16, month: u8, day: u8, hour: u8, min: u8, sec: u8, micros: u32) !DateTime {
        if (Date.valid(year, month, day) == false) {
            return error.InvalidDate;
        }

        if (Time.valid(hour, min, sec, micros) == false) {
            return error.InvalidTime;
        }

        const year_base = 4800;
        const month_adj = @as(i32, @intCast(month)) - 3; // March-based month
        const carry: u8 = if (month_adj < 0) 1 else 0;
        const adjust: u8 = if (carry == 1) 12 else 0;
        const year_adj: i64 = year + year_base - carry;
        const month_days = @divTrunc(((month_adj + adjust) * 62719 + 769), 2048);
        const leap_days = @divTrunc(year_adj, 4) - @divTrunc(year_adj, 100) + @divTrunc(year_adj, 400);

        const date_micros: i64 = (year_adj * 365 + leap_days + month_days + (day - 1) - 2472632) * MICROSECONDS_IN_A_DAY;
        const time_micros = (@as(i64, @intCast(hour)) * MICROSECONDS_IN_AN_HOUR) + (@as(i64, @intCast(min)) * MICROSECONDS_IN_A_MIN) + (@as(i64, @intCast(sec)) * MICROSECONDS_IN_A_SEC) + micros;

        return fromUnix(date_micros + time_micros, .microseconds);
    }

    pub fn fromUnix(value: i64, precision: TimestampPrecision) !DateTime {
        switch (precision) {
            .seconds => {
                if (value < -210863520000 or value > 253402300799) {
                    return error.OutsideJulianPeriod;
                }
                return .{ .micros = value * 1_000_000 };
            },
            .milliseconds => {
                if (value < -210863520000000 or value > 253402300799999) {
                    return error.OutsideJulianPeriod;
                }
                return .{ .micros = value * 1_000 };
            },
            .microseconds => {
                if (value < -210863520000000000 or value > 253402300799999999) {
                    return error.OutsideJulianPeriod;
                }
                return .{ .micros = value };
            },
        }
    }

    pub fn now() DateTime {
        return .{
            .micros = std.time.microTimestamp(),
        };
    }

    pub fn parse(input: []const u8, fmt: Format) !DateTime {
        switch (fmt) {
            .rfc822 => return parseRFC822(input),
            .rfc3339 => return parseRFC3339(input),
        }
    }

    pub fn parseRFC822(input: []const u8) !DateTime {
        if (input.len < 10) {
            return error.InvalidDateTime;
        }
        var parser = Parser.init(input);
        if (input[3] == ',' and input[4] == ' ') {
            _ = std.meta.stringToEnum(enum { Mon, Tue, Wed, Thu, Fri, Sat, Sun }, input[0..3]) orelse return error.InvalidDate;
            // skip over the "DoW, "
            parser.pos = 5;
        }

        const day = parser.paddedInt(u8, 2) orelse return error.InvalidDate;
        if (parser.consumeIf(' ') == false) {
            return error.InvalidDate;
        }

        const month = std.meta.stringToEnum(enum { Jan, Feb, Mar, Apr, May, Jun, Jul, Aug, Sep, Oct, Nov, Dec }, parser.consumeN(3) orelse return error.InvalidDate) orelse return error.InvalidDate;

        if (parser.consumeIf(' ') == false) {
            return error.InvalidDate;
        }

        const year = parser.paddedInt(i16, 4) orelse blk: {
            const short_year = parser.paddedInt(u8, 2) orelse return error.InvalidDate;
            break :blk if (short_year > 68) 1900 + @as(i16, short_year) else 2000 + @as(i16, short_year);
        };

        if (parser.consumeIf(' ') == false) {
            return error.InvalidDateTime;
        }
        const tm = try parser.time(false);

        if (parser.consumeIf(' ') == false) {
            return error.InvalidTime;
        }

        _ = std.meta.stringToEnum(enum { UT, GMT, Z }, parser.rest()) orelse return error.UnsupportedTimeZone;

        return initUTC(year, @intFromEnum(month) + 1, day, tm.hour, tm.min, tm.sec, tm.micros);
    }

    pub fn parseRFC3339(input: []const u8) !DateTime {
        var parser = Parser.init(input);

        const dt = try parser.rfc3339Date();

        const year = dt.year;
        if (year < -4712 or year > 9999) {
            return error.OutsideJulianPeriod;
        }

        // Per the spec, it can be argued thatt 't' and even ' ' should be allowed,
        // but certainly not encouraged.
        if (parser.consumeIf('T') == false) {
            return error.InvalidDateTime;
        }

        const tm = try parser.time(true);

        switch (parser.unconsumed()) {
            0 => return error.InvalidDateTime,
            1 => if (parser.consumeIf('Z') == false) {
                return error.InvalidDateTime;
            },
            6 => {
                const suffix = parser.rest();
                if (suffix[0] != '+' and suffix[0] != '-') {
                    return error.InvalidDateTime;
                }
                if (std.mem.eql(u8, suffix[1..], "00:00") == false) {
                    return error.NonUTCNotSupported;
                }
            },
            else => return error.InvalidDateTime,
        }

        return initUTC(dt.year, dt.month, dt.day, tm.hour, tm.min, tm.sec, tm.micros);
    }

    pub fn add(dt: DateTime, value: i64, unit: TimeUnit) !DateTime {
        const micros = dt.micros;
        switch (unit) {
            .days => return fromUnix(micros + value * MICROSECONDS_IN_A_DAY, .microseconds),
            .hours => return fromUnix(micros + value * MICROSECONDS_IN_AN_HOUR, .microseconds),
            .minutes => return fromUnix(micros + value * MICROSECONDS_IN_A_MIN, .microseconds),
            .seconds => return fromUnix(micros + value * MICROSECONDS_IN_A_SEC, .microseconds),
            .milliseconds => return fromUnix(micros + value * 1_000, .microseconds),
            .microseconds => return fromUnix(micros + value, .microseconds),
        }
    }

    pub fn sub(a: DateTime, b: DateTime, precision: TimestampPrecision) i64 {
        return a.unix(precision) - b.unix(precision);
    }

    // https://git.musl-libc.org/cgit/musl/tree/src/time/__secs_to_tm.c?h=v0.9.15
    pub fn date(dt: DateTime) Date {
        // 2000-03-01 (mod 400 year, immediately after feb29
        const leap_epoch = 946684800 + 86400 * (31 + 29);
        const days_per_400y = 365 * 400 + 97;
        const days_per_100y = 365 * 100 + 24;
        const days_per_4y = 365 * 4 + 1;

        // march-based
        const month_days = [_]u8{ 31, 30, 31, 30, 31, 31, 30, 31, 30, 31, 31, 29 };

        const secs = @divTrunc(dt.micros, 1_000_000) - leap_epoch;

        var days = @divTrunc(secs, 86400);
        if (@rem(secs, 86400) < 0) {
            days -= 1;
        }

        var qc_cycles = @divTrunc(days, days_per_400y);
        var rem_days = @rem(days, days_per_400y);
        if (rem_days < 0) {
            rem_days += days_per_400y;
            qc_cycles -= 1;
        }

        var c_cycles = @divTrunc(rem_days, days_per_100y);
        if (c_cycles == 4) {
            c_cycles -= 1;
        }
        rem_days -= c_cycles * days_per_100y;

        var q_cycles = @divTrunc(rem_days, days_per_4y);
        if (q_cycles == 25) {
            q_cycles -= 1;
        }
        rem_days -= q_cycles * days_per_4y;

        var rem_years = @divTrunc(rem_days, 365);
        if (rem_years == 4) {
            rem_years -= 1;
        }
        rem_days -= rem_years * 365;

        var year = rem_years + 4 * q_cycles + 100 * c_cycles + 400 * qc_cycles + 2000;

        var month: u8 = 0;
        while (month_days[month] <= rem_days) : (month += 1) {
            rem_days -= month_days[month];
        }

        month += 2;
        if (month >= 12) {
            year += 1;
            month -= 12;
        }

        return .{
            .year = @intCast(year),
            .month = month + 1,
            .day = @intCast(rem_days + 1),
        };
    }

    pub fn time(dt: DateTime) Time {
        const micros = @mod(dt.micros, MICROSECONDS_IN_A_DAY);

        return .{
            .hour = @intCast(@divTrunc(micros, MICROSECONDS_IN_AN_HOUR)),
            .min = @intCast(@divTrunc(@rem(micros, MICROSECONDS_IN_AN_HOUR), MICROSECONDS_IN_A_MIN)),
            .sec = @intCast(@divTrunc(@rem(micros, MICROSECONDS_IN_A_MIN), MICROSECONDS_IN_A_SEC)),
            .micros = @intCast(@rem(micros, MICROSECONDS_IN_A_SEC)),
        };
    }

    pub fn unix(self: DateTime, precision: TimestampPrecision) i64 {
        const micros = self.micros;
        return switch (precision) {
            .seconds => @divTrunc(micros, 1_000_000),
            .milliseconds => @divTrunc(micros, 1_000),
            .microseconds => micros,
        };
    }

    pub fn order(a: DateTime, b: DateTime) std.math.Order {
        return std.math.order(a.micros, b.micros);
    }

    pub fn format(self: DateTime, writer: *std.Io.Writer) !void {
        var buf: [28]u8 = undefined;
        const n = self.bufWrite(&buf);
        try writer.writeAll(buf[0..n]);
    }

    pub fn jsonStringify(self: DateTime, out: anytype) !void {
        var buf: [30]u8 = undefined;
        buf[0] = '"';
        const n = self.bufWrite(buf[1..]);
        buf[n + 1] = '"';
        try out.print("{s}", .{buf[0 .. n + 2]});
    }

    pub fn jsonParse(allocator: Allocator, source: anytype, options: anytype) !DateTime {
        _ = options;

        switch (try source.nextAlloc(allocator, .alloc_if_needed)) {
            inline .string, .allocated_string => |str| return parseRFC3339(str) catch return error.InvalidCharacter,
            else => return error.UnexpectedToken,
        }
    }

    fn bufWrite(self: DateTime, buf: []u8) usize {
        const date_n = writeDate(buf, self.date());

        buf[date_n] = 'T';

        const time_start = date_n + 1;
        const time_n = writeTime(buf[time_start..], self.time());

        const time_stop = time_start + time_n;
        buf[time_stop] = 'Z';

        return time_stop + 1;
    }
};

pub fn timestamp() u32 {
    const ts = timespec();
    return @intCast(ts.sec);
}

pub fn milliTimestamp() u64 {
    const ts = timespec();
    return @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(@divTrunc(ts.nsec, 1_000_000)));
}

fn timespec() std.posix.timespec {
    const clock_id = switch (@import("builtin").os.tag) {
        .freebsd, .dragonfly => std.posix.CLOCK.MONOTONIC_FAST,
        .macos, .ios, .tvos, .watchos, .visionos => std.posix.CLOCK.UPTIME_RAW, // continues counting while suspended
        .linux => std.posix.CLOCK.BOOTTIME, // continues counting while suspended
        else => std.posix.CLOCK.MONOTONIC,
    };
    // we don't currently support platforms where, at the very least,
    // posix.CLOCK.MONOTONIC wouldn't be available.
    return std.posix.clock_gettime(clock_id) catch unreachable;
}

fn writeDate(into: []u8, date: Date) u8 {
    var buf: []u8 = undefined;
    // cast year to a u16 so it doesn't insert a sign
    // we don't want the + sign, ever
    // and we don't even want it to insert the - sign, because it screws up
    // the padding (we need to do it ourselfs)
    const year = date.year;
    if (year < 0) {
        _ = std.fmt.printInt(into[1..], @as(u16, @intCast(year * -1)), 10, .lower, .{ .width = 4, .fill = '0' });
        into[0] = '-';
        buf = into[5..];
    } else {
        _ = std.fmt.printInt(into, @as(u16, @intCast(year)), 10, .lower, .{ .width = 4, .fill = '0' });
        buf = into[4..];
    }

    buf[0] = '-';
    buf[1..3].* = paddingTwoDigits(date.month);
    buf[3] = '-';
    buf[4..6].* = paddingTwoDigits(date.day);

    // return the length of the string. 10 for positive year, 11 for negative
    return if (year < 0) 11 else 10;
}

fn writeTime(into: []u8, time: Time) u8 {
    into[0..2].* = paddingTwoDigits(time.hour);
    into[2] = ':';
    into[3..5].* = paddingTwoDigits(time.min);
    into[5] = ':';
    into[6..8].* = paddingTwoDigits(time.sec);

    const micros = time.micros;
    if (micros == 0) {
        return 8;
    }

    if (@rem(micros, 1000) == 0) {
        into[8] = '.';
        _ = std.fmt.printInt(into[9..12], micros / 1000, 10, .lower, .{ .width = 3, .fill = '0' });
        return 12;
    }

    into[8] = '.';
    _ = std.fmt.printInt(into[9..15], micros, 10, .lower, .{ .width = 6, .fill = '0' });
    return 15;
}

fn paddingTwoDigits(value: usize) [2]u8 {
    std.debug.assert(value < 61);
    const digits = "0001020304050607080910111213141516171819" ++
        "2021222324252627282930313233343536373839" ++
        "4041424344454647484950515253545556575859" ++
        "60";
    return digits[value * 2 ..][0..2].*;
}

const Parser = struct {
    input: []const u8,
    pos: usize,

    fn init(input: []const u8) Parser {
        return .{
            .pos = 0,
            .input = input,
        };
    }

    fn unconsumed(self: *const Parser) usize {
        return self.input.len - self.pos;
    }

    fn rest(self: *const Parser) []const u8 {
        return self.input[self.pos..];
    }

    // unsafe, assumes caller has checked remaining first
    fn peek(self: *const Parser) u8 {
        return self.input[self.pos];
    }

    // unsafe, assumes caller has checked remaining first
    fn consumeIf(self: *Parser, c: u8) bool {
        const pos = self.pos;
        if (self.input[pos] != c) {
            return false;
        }
        self.pos = pos + 1;
        return true;
    }

    fn consumeN(self: *Parser, n: usize) ?[]const u8 {
        const pos = self.pos;
        const end = pos + n;
        if (end > self.input.len) {
            return null;
        }

        defer self.pos = end;
        return self.input[pos..end];
    }

    fn nanoseconds(self: *Parser) ?usize {
        const start = self.pos;
        const input = self.input[start..];

        var len = input.len;
        if (len == 0) {
            return null;
        }

        var value: usize = 0;
        for (input, 0..) |b, i| {
            const n = b -% '0'; // wrapping subtraction
            if (n > 9) {
                len = i;
                break;
            }
            value = value * 10 + n;
        }

        if (len > 9) {
            return null;
        }

        self.pos = start + len;
        return value * std.math.pow(usize, 10, 9 - len);
    }

    fn paddedInt(self: *Parser, comptime T: type, size: u8) ?T {
        const pos = self.pos;
        const end = pos + size;
        const input = self.input;

        if (end > input.len) {
            return null;
        }

        var value: T = 0;
        for (input[pos..end]) |b| {
            const n = b -% '0'; // wrapping subtraction
            if (n > 9) return null;
            value = value * 10 + n;
        }
        self.pos = end;
        return value;
    }

    fn time(self: *Parser, allow_nano: bool) !Time {
        const len = self.unconsumed();
        if (len < 5) {
            return error.InvalidTime;
        }

        const hour = self.paddedInt(u8, 2) orelse return error.InvalidTime;
        if (self.consumeIf(':') == false) {
            return error.InvalidTime;
        }

        const min = self.paddedInt(u8, 2) orelse return error.InvalidTime;
        if (len == 5 or self.consumeIf(':') == false) {
            return Time.init(hour, min, 0, 0);
        }

        const sec = self.paddedInt(u8, 2) orelse return error.InvalidTime;
        if (allow_nano == false or len == 8 or self.consumeIf('.') == false) {
            return Time.init(hour, min, sec, 0);
        }

        const nanos = self.nanoseconds() orelse return error.InvalidTime;
        return Time.init(hour, min, sec, @intCast(nanos / 1000));
    }

    fn iso8601Date(self: *Parser) !Date {
        const len = self.unconsumed();
        if (len < 8) {
            return error.InvalidDate;
        }

        const negative = self.consumeIf('-');
        const year = self.paddedInt(i16, 4) orelse return error.InvalidDate;

        var with_dashes = false;
        if (self.consumeIf('-')) {
            if (len < 10) {
                return error.InvalidDate;
            }
            with_dashes = true;
        }

        const month = self.paddedInt(u8, 2) orelse return error.InvalidDate;
        if (self.consumeIf('-') == !with_dashes) {
            return error.InvalidDate;
        }

        const day = self.paddedInt(u8, 2) orelse return error.InvalidDate;
        return Date.init(if (negative) -year else year, month, day);
    }

    fn rfc3339Date(self: *Parser) !Date {
        const len = self.unconsumed();
        if (len < 10) {
            return error.InvalidDate;
        }

        const negative = self.consumeIf('-');
        const year = self.paddedInt(i16, 4) orelse return error.InvalidDate;

        if (self.consumeIf('-') == false) {
            return error.InvalidDate;
        }

        const month = self.paddedInt(u8, 2) orelse return error.InvalidDate;

        if (self.consumeIf('-') == false) {
            return error.InvalidDate;
        }

        const day = self.paddedInt(u8, 2) orelse return error.InvalidDate;
        return Date.init(if (negative) -year else year, month, day);
    }
};

const testing = @import("testing.zig");
test "Date: json" {
    {
        // date, positive year
        const date = Date{ .year = 2023, .month = 9, .day = 22 };
        const out = try std.json.Stringify.valueAlloc(testing.allocator, date, .{});
        defer testing.allocator.free(out);
        try testing.expectString("\"2023-09-22\"", out);
    }

    {
        // date, negative year
        const date = Date{ .year = -4, .month = 12, .day = 3 };
        const out = try std.json.Stringify.valueAlloc(testing.allocator, date, .{});
        defer testing.allocator.free(out);
        try testing.expectString("\"-0004-12-03\"", out);
    }

    {
        // parse
        const ts = try std.json.parseFromSlice(TestStruct, testing.allocator, "{\"date\":\"2023-09-22\"}", .{});
        defer ts.deinit();
        try testing.expectEqual(Date{ .year = 2023, .month = 9, .day = 22 }, ts.value.date.?);
    }
}

test "Date: format" {
    {
        var buf: [20]u8 = undefined;
        const out = try std.fmt.bufPrint(&buf, "{f}", .{Date{ .year = 2023, .month = 5, .day = 22 }});
        try testing.expectString("2023-05-22", out);
    }

    {
        var buf: [20]u8 = undefined;
        const out = try std.fmt.bufPrint(&buf, "{f}", .{Date{ .year = -102, .month = 12, .day = 9 }});
        try testing.expectString("-0102-12-09", out);
    }
}

test "Date: parse ISO8601" {
    {
        //valid YYYY-MM-DD
        try testing.expectEqual(Date{ .year = 2023, .month = 5, .day = 22 }, try Date.parse("2023-05-22", .iso8601));
        try testing.expectEqual(Date{ .year = -2023, .month = 2, .day = 3 }, try Date.parse("-2023-02-03", .iso8601));
        try testing.expectEqual(Date{ .year = 1, .month = 2, .day = 3 }, try Date.parse("0001-02-03", .iso8601));
        try testing.expectEqual(Date{ .year = -1, .month = 2, .day = 3 }, try Date.parse("-0001-02-03", .iso8601));
    }

    {
        //valid YYYYMMDD
        try testing.expectEqual(Date{ .year = 2023, .month = 5, .day = 22 }, try Date.parse("20230522", .iso8601));
        try testing.expectEqual(Date{ .year = -2023, .month = 2, .day = 3 }, try Date.parse("-20230203", .iso8601));
        try testing.expectEqual(Date{ .year = 1, .month = 2, .day = 3 }, try Date.parse("00010203", .iso8601));
        try testing.expectEqual(Date{ .year = -1, .month = 2, .day = 3 }, try Date.parse("-00010203", .iso8601));
    }
}

test "Date: parse RFC339" {
    {
        //valid YYYY-MM-DD
        try testing.expectEqual(Date{ .year = 2023, .month = 5, .day = 22 }, try Date.parse("2023-05-22", .rfc3339));
        try testing.expectEqual(Date{ .year = -2023, .month = 2, .day = 3 }, try Date.parse("-2023-02-03", .rfc3339));
        try testing.expectEqual(Date{ .year = 1, .month = 2, .day = 3 }, try Date.parse("0001-02-03", .rfc3339));
        try testing.expectEqual(Date{ .year = -1, .month = 2, .day = 3 }, try Date.parse("-0001-02-03", .rfc3339));
    }

    {
        //valid YYYYMMDD
        try testing.expectError(error.InvalidDate, Date.parse("20230522", .rfc3339));
        try testing.expectError(error.InvalidDate, Date.parse("-20230203", .rfc3339));
        try testing.expectError(error.InvalidDate, Date.parse("00010203", .rfc3339));
        try testing.expectError(error.InvalidDate, Date.parse("-00010203", .rfc3339));
    }
}

test "Date: parse invalid common" {
    for (&[_]Date.Format{ .rfc3339, .iso8601 }) |format| {
        {
            // invalid format
            try testing.expectError(error.InvalidDate, Date.parse("", format));
            try testing.expectError(error.InvalidDate, Date.parse("2023/01-02", format));
            try testing.expectError(error.InvalidDate, Date.parse("2023-01/02", format));
            try testing.expectError(error.InvalidDate, Date.parse("0001-01-01 ", format));
            try testing.expectError(error.InvalidDate, Date.parse("2023-1-02", format));
            try testing.expectError(error.InvalidDate, Date.parse("2023-01-2", format));
            try testing.expectError(error.InvalidDate, Date.parse("9-01-2", format));
            try testing.expectError(error.InvalidDate, Date.parse("99-01-2", format));
            try testing.expectError(error.InvalidDate, Date.parse("999-01-2", format));
            try testing.expectError(error.InvalidDate, Date.parse("-999-01-2", format));
            try testing.expectError(error.InvalidDate, Date.parse("-1-01-2", format));
        }

        {
            // invalid month
            try testing.expectError(error.InvalidDate, Date.parse("2023-00-22", format));
            try testing.expectError(error.InvalidDate, Date.parse("2023-0A-22", format));
            try testing.expectError(error.InvalidDate, Date.parse("2023-13-22", format));
            try testing.expectError(error.InvalidDate, Date.parse("2023-99-22", format));
            try testing.expectError(error.InvalidDate, Date.parse("-2023-00-22", format));
            try testing.expectError(error.InvalidDate, Date.parse("-2023-13-22", format));
            try testing.expectError(error.InvalidDate, Date.parse("-2023-99-22", format));
        }

        {
            // invalid day
            try testing.expectError(error.InvalidDate, Date.parse("2023-01-00", format));
            try testing.expectError(error.InvalidDate, Date.parse("2023-01-32", format));
            try testing.expectError(error.InvalidDate, Date.parse("2023-02-29", format));
            try testing.expectError(error.InvalidDate, Date.parse("2023-03-32", format));
            try testing.expectError(error.InvalidDate, Date.parse("2023-04-31", format));
            try testing.expectError(error.InvalidDate, Date.parse("2023-05-32", format));
            try testing.expectError(error.InvalidDate, Date.parse("2023-06-31", format));
            try testing.expectError(error.InvalidDate, Date.parse("2023-07-32", format));
            try testing.expectError(error.InvalidDate, Date.parse("2023-08-32", format));
            try testing.expectError(error.InvalidDate, Date.parse("2023-09-31", format));
            try testing.expectError(error.InvalidDate, Date.parse("2023-10-32", format));
            try testing.expectError(error.InvalidDate, Date.parse("2023-11-31", format));
            try testing.expectError(error.InvalidDate, Date.parse("2023-12-32", format));
        }

        {
            // valid (max day)
            try testing.expectEqual(Date{ .year = 2023, .month = 1, .day = 31 }, try Date.parse("2023-01-31", format));
            try testing.expectEqual(Date{ .year = 2023, .month = 2, .day = 28 }, try Date.parse("2023-02-28", format));
            try testing.expectEqual(Date{ .year = 2023, .month = 3, .day = 31 }, try Date.parse("2023-03-31", format));
            try testing.expectEqual(Date{ .year = 2023, .month = 4, .day = 30 }, try Date.parse("2023-04-30", format));
            try testing.expectEqual(Date{ .year = 2023, .month = 5, .day = 31 }, try Date.parse("2023-05-31", format));
            try testing.expectEqual(Date{ .year = 2023, .month = 6, .day = 30 }, try Date.parse("2023-06-30", format));
            try testing.expectEqual(Date{ .year = 2023, .month = 7, .day = 31 }, try Date.parse("2023-07-31", format));
            try testing.expectEqual(Date{ .year = 2023, .month = 8, .day = 31 }, try Date.parse("2023-08-31", format));
            try testing.expectEqual(Date{ .year = 2023, .month = 9, .day = 30 }, try Date.parse("2023-09-30", format));
            try testing.expectEqual(Date{ .year = 2023, .month = 10, .day = 31 }, try Date.parse("2023-10-31", format));
            try testing.expectEqual(Date{ .year = 2023, .month = 11, .day = 30 }, try Date.parse("2023-11-30", format));
            try testing.expectEqual(Date{ .year = 2023, .month = 12, .day = 31 }, try Date.parse("2023-12-31", format));
        }

        {
            // leap years
            try testing.expectEqual(Date{ .year = 2000, .month = 2, .day = 29 }, try Date.parse("2000-02-29", format));
            try testing.expectEqual(Date{ .year = 2400, .month = 2, .day = 29 }, try Date.parse("2400-02-29", format));
            try testing.expectEqual(Date{ .year = 2012, .month = 2, .day = 29 }, try Date.parse("2012-02-29", format));
            try testing.expectEqual(Date{ .year = 2024, .month = 2, .day = 29 }, try Date.parse("2024-02-29", format));

            try testing.expectError(error.InvalidDate, Date.parse("2000-02-30", format));
            try testing.expectError(error.InvalidDate, Date.parse("2400-02-30", format));
            try testing.expectError(error.InvalidDate, Date.parse("2012-02-30", format));
            try testing.expectError(error.InvalidDate, Date.parse("2024-02-30", format));

            try testing.expectError(error.InvalidDate, Date.parse("2100-02-29", format));
            try testing.expectError(error.InvalidDate, Date.parse("2200-02-29", format));
        }
    }
}

test "Date: order" {
    {
        const a = Date{ .year = 2023, .month = 5, .day = 22 };
        const b = Date{ .year = 2023, .month = 5, .day = 22 };
        try testing.expectEqual(std.math.Order.eq, a.order(b));
    }

    {
        const a = Date{ .year = 2023, .month = 5, .day = 22 };
        const b = Date{ .year = 2022, .month = 5, .day = 22 };
        try testing.expectEqual(std.math.Order.gt, a.order(b));
        try testing.expectEqual(std.math.Order.lt, b.order(a));
    }

    {
        const a = Date{ .year = 2022, .month = 6, .day = 22 };
        const b = Date{ .year = 2022, .month = 5, .day = 22 };
        try testing.expectEqual(std.math.Order.gt, a.order(b));
        try testing.expectEqual(std.math.Order.lt, b.order(a));
    }

    {
        const a = Date{ .year = 2023, .month = 5, .day = 23 };
        const b = Date{ .year = 2022, .month = 5, .day = 22 };
        try testing.expectEqual(std.math.Order.gt, a.order(b));
        try testing.expectEqual(std.math.Order.lt, b.order(a));
    }
}

test "Time: json" {
    {
        // time no fraction
        const time = Time{ .hour = 23, .min = 59, .sec = 2, .micros = 0 };
        const out = try std.json.Stringify.valueAlloc(testing.allocator, time, .{});
        defer testing.allocator.free(out);
        try testing.expectString("\"23:59:02\"", out);
    }

    {
        // time, milliseconds only
        const time = Time{ .hour = 7, .min = 9, .sec = 32, .micros = 202000 };
        const out = try std.json.Stringify.valueAlloc(testing.allocator, time, .{});
        defer testing.allocator.free(out);
        try testing.expectString("\"07:09:32.202\"", out);
    }

    {
        // time, micros
        const time = Time{ .hour = 1, .min = 2, .sec = 3, .micros = 123456 };
        const out = try std.json.Stringify.valueAlloc(testing.allocator, time, .{});
        defer testing.allocator.free(out);
        try testing.expectString("\"01:02:03.123456\"", out);
    }

    {
        // parse
        const ts = try std.json.parseFromSlice(TestStruct, testing.allocator, "{\"time\":\"01:02:03.123456\"}", .{});
        defer ts.deinit();
        try testing.expectEqual(Time{ .hour = 1, .min = 2, .sec = 3, .micros = 123456 }, ts.value.time.?);
    }
}

test "Time: format" {
    {
        var buf: [20]u8 = undefined;
        const out = try std.fmt.bufPrint(&buf, "{f}", .{Time{ .hour = 23, .min = 59, .sec = 59, .micros = 0 }});
        try testing.expectString("23:59:59", out);
    }

    {
        var buf: [20]u8 = undefined;
        const out = try std.fmt.bufPrint(&buf, "{f}", .{Time{ .hour = 8, .min = 9, .sec = 10, .micros = 12 }});
        try testing.expectString("08:09:10.000012", out);
    }

    {
        var buf: [20]u8 = undefined;
        const out = try std.fmt.bufPrint(&buf, "{f}", .{Time{ .hour = 8, .min = 9, .sec = 10, .micros = 123 }});
        try testing.expectString("08:09:10.000123", out);
    }

    {
        var buf: [20]u8 = undefined;
        const out = try std.fmt.bufPrint(&buf, "{f}", .{Time{ .hour = 8, .min = 9, .sec = 10, .micros = 1234 }});
        try testing.expectString("08:09:10.001234", out);
    }

    {
        var buf: [20]u8 = undefined;
        const out = try std.fmt.bufPrint(&buf, "{f}", .{Time{ .hour = 8, .min = 9, .sec = 10, .micros = 12345 }});
        try testing.expectString("08:09:10.012345", out);
    }

    {
        var buf: [20]u8 = undefined;
        const out = try std.fmt.bufPrint(&buf, "{f}", .{Time{ .hour = 8, .min = 9, .sec = 10, .micros = 123456 }});
        try testing.expectString("08:09:10.123456", out);
    }
}

test "Time: parse" {
    {
        //valid
        try testing.expectEqual(Time{ .hour = 9, .min = 8, .sec = 0, .micros = 0 }, try Time.parse("09:08", .rfc3339));
        try testing.expectEqual(Time{ .hour = 9, .min = 8, .sec = 5, .micros = 123000 }, try Time.parse("09:08:05.123", .rfc3339));
        try testing.expectEqual(Time{ .hour = 23, .min = 59, .sec = 59, .micros = 0 }, try Time.parse("23:59:59", .rfc3339));
        try testing.expectEqual(Time{ .hour = 0, .min = 0, .sec = 0, .micros = 0 }, try Time.parse("00:00:00", .rfc3339));
        try testing.expectEqual(Time{ .hour = 0, .min = 0, .sec = 0, .micros = 0 }, try Time.parse("00:00:00.0", .rfc3339));
        try testing.expectEqual(Time{ .hour = 0, .min = 0, .sec = 0, .micros = 1 }, try Time.parse("00:00:00.000001", .rfc3339));
        try testing.expectEqual(Time{ .hour = 0, .min = 0, .sec = 0, .micros = 12 }, try Time.parse("00:00:00.000012", .rfc3339));
        try testing.expectEqual(Time{ .hour = 0, .min = 0, .sec = 0, .micros = 123 }, try Time.parse("00:00:00.000123", .rfc3339));
        try testing.expectEqual(Time{ .hour = 0, .min = 0, .sec = 0, .micros = 1234 }, try Time.parse("00:00:00.001234", .rfc3339));
        try testing.expectEqual(Time{ .hour = 0, .min = 0, .sec = 0, .micros = 12345 }, try Time.parse("00:00:00.012345", .rfc3339));
        try testing.expectEqual(Time{ .hour = 0, .min = 0, .sec = 0, .micros = 123456 }, try Time.parse("00:00:00.123456", .rfc3339));
        try testing.expectEqual(Time{ .hour = 0, .min = 0, .sec = 0, .micros = 123456 }, try Time.parse("00:00:00.1234567", .rfc3339));
        try testing.expectEqual(Time{ .hour = 0, .min = 0, .sec = 0, .micros = 123456 }, try Time.parse("00:00:00.12345678", .rfc3339));
        try testing.expectEqual(Time{ .hour = 0, .min = 0, .sec = 0, .micros = 123456 }, try Time.parse("00:00:00.123456789", .rfc3339));
    }

    {
        try testing.expectError(error.InvalidTime, Time.parse("", .rfc3339));
        try testing.expectError(error.InvalidTime, Time.parse("01:00:", .rfc3339));
        try testing.expectError(error.InvalidTime, Time.parse("1:00:00", .rfc3339));
        try testing.expectError(error.InvalidTime, Time.parse("10:1:00", .rfc3339));
        try testing.expectError(error.InvalidTime, Time.parse("10:11:4", .rfc3339));
        try testing.expectError(error.InvalidTime, Time.parse("10:20:30.", .rfc3339));
        try testing.expectError(error.InvalidTime, Time.parse("10:20:30.a", .rfc3339));
        try testing.expectError(error.InvalidTime, Time.parse("10:20:30.1234567899", .rfc3339));
        try testing.expectError(error.InvalidTime, Time.parse("10:20:30.123Z", .rfc3339));
        try testing.expectError(error.InvalidTime, Time.parse("24:00:00", .rfc3339));
        try testing.expectError(error.InvalidTime, Time.parse("00:60:00", .rfc3339));
        try testing.expectError(error.InvalidTime, Time.parse("00:00:60", .rfc3339));
        try testing.expectError(error.InvalidTime, Time.parse("0a:00:00", .rfc3339));
        try testing.expectError(error.InvalidTime, Time.parse("00:0a:00", .rfc3339));
        try testing.expectError(error.InvalidTime, Time.parse("00:00:0a", .rfc3339));
        try testing.expectError(error.InvalidTime, Time.parse("00/00:00", .rfc3339));
        try testing.expectError(error.InvalidTime, Time.parse("00:00 00", .rfc3339));
    }
}

test "Time: order" {
    {
        const a = Time{ .hour = 19, .min = 17, .sec = 22, .micros = 101002 };
        const b = Time{ .hour = 19, .min = 17, .sec = 22, .micros = 101002 };
        try testing.expectEqual(std.math.Order.eq, a.order(b));
    }

    {
        const a = Time{ .hour = 20, .min = 17, .sec = 22, .micros = 101002 };
        const b = Time{ .hour = 19, .min = 17, .sec = 22, .micros = 101002 };
        try testing.expectEqual(std.math.Order.gt, a.order(b));
        try testing.expectEqual(std.math.Order.lt, b.order(a));
    }

    {
        const a = Time{ .hour = 19, .min = 18, .sec = 22, .micros = 101002 };
        const b = Time{ .hour = 19, .min = 17, .sec = 22, .micros = 101002 };
        try testing.expectEqual(std.math.Order.gt, a.order(b));
        try testing.expectEqual(std.math.Order.lt, b.order(a));
    }

    {
        const a = Time{ .hour = 19, .min = 17, .sec = 23, .micros = 101002 };
        const b = Time{ .hour = 19, .min = 17, .sec = 22, .micros = 101002 };
        try testing.expectEqual(std.math.Order.gt, a.order(b));
        try testing.expectEqual(std.math.Order.lt, b.order(a));
    }

    {
        const a = Time{ .hour = 19, .min = 17, .sec = 22, .micros = 101003 };
        const b = Time{ .hour = 19, .min = 17, .sec = 22, .micros = 101002 };
        try testing.expectEqual(std.math.Order.gt, a.order(b));
        try testing.expectEqual(std.math.Order.lt, b.order(a));
    }
}

test "DateTime: initUTC" {
    // GO
    // for i := 0; i < 100; i++ {
    //   us := rand.Int63n(31536000000000000)
    //   if i%2 == 1 {
    //     us = -us
    //   }
    //   date := time.UnixMicro(us).UTC()
    //   fmt.Printf("\ttry testing.expectEqual(%d, (try DateTime.initUTC(%d, %d, %d, %d, %d, %d, %d)).micros);\n", us, date.Year(), date.Month(), date.Day(), date.Hour(), date.Minute(), date.Second(), date.Nanosecond()/1000)
    // }
    try testing.expectEqual(31185488490276150, (try DateTime.initUTC(2958, 3, 25, 3, 41, 30, 276150)).micros);
    try testing.expectEqual(-17564653328342207, (try DateTime.initUTC(1413, 5, 26, 9, 37, 51, 657793)).micros);
    try testing.expectEqual(11204762425459393, (try DateTime.initUTC(2325, 1, 24, 18, 0, 25, 459393)).micros);
    try testing.expectEqual(-11416605162739875, (try DateTime.initUTC(1608, 3, 22, 8, 47, 17, 260125)).micros);
    try testing.expectEqual(4075732367920414, (try DateTime.initUTC(2099, 2, 25, 19, 52, 47, 920414)).micros);
    try testing.expectEqual(-18408335598163579, (try DateTime.initUTC(1386, 8, 30, 13, 26, 41, 836421)).micros);
    try testing.expectEqual(17086490946271926, (try DateTime.initUTC(2511, 6, 14, 7, 29, 6, 271926)).micros);
    try testing.expectEqual(-235277150936616, (try DateTime.initUTC(1962, 7, 18, 21, 14, 9, 63384)).micros);
    try testing.expectEqual(11104788804726682, (try DateTime.initUTC(2321, 11, 24, 15, 33, 24, 726682)).micros);
    try testing.expectEqual(-4568937205156452, (try DateTime.initUTC(1825, 3, 20, 18, 46, 34, 843548)).micros);
    try testing.expectEqual(24765673968274275, (try DateTime.initUTC(2754, 10, 17, 17, 52, 48, 274275)).micros);
    try testing.expectEqual(-7121990846251510, (try DateTime.initUTC(1744, 4, 24, 13, 12, 33, 748490)).micros);
    try testing.expectEqual(17226397205968456, (try DateTime.initUTC(2515, 11, 19, 14, 20, 5, 968456)).micros);
    try testing.expectEqual(-6754262392339050, (try DateTime.initUTC(1755, 12, 19, 16, 0, 7, 660950)).micros);
    try testing.expectEqual(16357572620714009, (try DateTime.initUTC(2488, 5, 7, 18, 10, 20, 714009)).micros);
    try testing.expectEqual(-25688820176639049, (try DateTime.initUTC(1155, 12, 15, 16, 37, 3, 360951)).micros);
    try testing.expectEqual(20334458172336139, (try DateTime.initUTC(2614, 5, 17, 12, 36, 12, 336139)).micros);
    try testing.expectEqual(-30602962159178117, (try DateTime.initUTC(1000, 3, 26, 1, 10, 40, 821883)).micros);
    try testing.expectEqual(10851036879825648, (try DateTime.initUTC(2313, 11, 9, 16, 54, 39, 825648)).micros);
    try testing.expectEqual(-21853769826060317, (try DateTime.initUTC(1277, 6, 24, 20, 22, 53, 939683)).micros);
    try testing.expectEqual(23747326217087461, (try DateTime.initUTC(2722, 7, 11, 7, 30, 17, 87461)).micros);
    try testing.expectEqual(-6579703114708064, (try DateTime.initUTC(1761, 7, 1, 0, 41, 25, 291936)).micros);
    try testing.expectEqual(14734931422924073, (try DateTime.initUTC(2436, 12, 6, 4, 30, 22, 924073)).micros);
    try testing.expectEqual(-14370161672281011, (try DateTime.initUTC(1514, 8, 18, 16, 25, 27, 718989)).micros);
    try testing.expectEqual(21611484560584058, (try DateTime.initUTC(2654, 11, 3, 22, 9, 20, 584058)).micros);
    try testing.expectEqual(-15774514890527755, (try DateTime.initUTC(1470, 2, 15, 14, 18, 29, 472245)).micros);
    try testing.expectEqual(12457884381373706, (try DateTime.initUTC(2364, 10, 10, 11, 26, 21, 373706)).micros);
    try testing.expectEqual(-9291409512875127, (try DateTime.initUTC(1675, 7, 26, 12, 54, 47, 124873)).micros);
    try testing.expectEqual(18766703512694310, (try DateTime.initUTC(2564, 9, 10, 5, 11, 52, 694310)).micros);
    try testing.expectEqual(-10898338457124469, (try DateTime.initUTC(1624, 8, 23, 19, 45, 42, 875531)).micros);
    try testing.expectEqual(27404278841361952, (try DateTime.initUTC(2838, 5, 29, 3, 40, 41, 361952)).micros);
    try testing.expectEqual(-11493696741549109, (try DateTime.initUTC(1605, 10, 12, 2, 27, 38, 450891)).micros);
    try testing.expectEqual(25167839321247044, (try DateTime.initUTC(2767, 7, 16, 10, 28, 41, 247044)).micros);
    try testing.expectEqual(-8645720427930599, (try DateTime.initUTC(1696, 1, 10, 18, 59, 32, 69401)).micros);
    try testing.expectEqual(7021225980669527, (try DateTime.initUTC(2192, 6, 29, 4, 33, 0, 669527)).micros);
    try testing.expectEqual(-22567421500525473, (try DateTime.initUTC(1254, 11, 12, 23, 48, 19, 474527)).micros);
    try testing.expectEqual(3592419409525180, (try DateTime.initUTC(2083, 11, 2, 22, 16, 49, 525180)).micros);
    try testing.expectEqual(-24897829995733878, (try DateTime.initUTC(1181, 1, 7, 16, 6, 44, 266122)).micros);
    try testing.expectEqual(1801796752202729, (try DateTime.initUTC(2027, 2, 5, 3, 5, 52, 202729)).micros);
    try testing.expectEqual(-21458729756349585, (try DateTime.initUTC(1289, 12, 31, 1, 44, 3, 650415)).micros);
    try testing.expectEqual(27431277767015263, (try DateTime.initUTC(2839, 4, 6, 15, 22, 47, 15263)).micros);
    try testing.expectEqual(-11932647633976328, (try DateTime.initUTC(1591, 11, 14, 15, 39, 26, 23672)).micros);
    try testing.expectEqual(11561116817530249, (try DateTime.initUTC(2336, 5, 11, 5, 20, 17, 530249)).micros);
    try testing.expectEqual(-20238374988448844, (try DateTime.initUTC(1328, 9, 2, 13, 10, 11, 551156)).micros);
    try testing.expectEqual(17825448287939368, (try DateTime.initUTC(2534, 11, 13, 1, 24, 47, 939368)).micros);
    try testing.expectEqual(-16551182110752962, (try DateTime.initUTC(1445, 7, 7, 9, 24, 49, 247038)).micros);
    try testing.expectEqual(7773488831126355, (try DateTime.initUTC(2216, 5, 1, 22, 27, 11, 126355)).micros);
    try testing.expectEqual(-17967725644400042, (try DateTime.initUTC(1400, 8, 17, 5, 5, 55, 599958)).micros);
    try testing.expectEqual(30634276344447791, (try DateTime.initUTC(2940, 10, 5, 9, 12, 24, 447791)).micros);
    try testing.expectEqual(-3201531339091604, (try DateTime.initUTC(1868, 7, 19, 5, 44, 20, 908396)).micros);
    try testing.expectEqual(16621702451341054, (try DateTime.initUTC(2496, 9, 19, 19, 34, 11, 341054)).micros);
    try testing.expectEqual(-12321145808433043, (try DateTime.initUTC(1579, 7, 24, 3, 29, 51, 566957)).micros);
    try testing.expectEqual(116851935152341, (try DateTime.initUTC(1973, 9, 14, 10, 52, 15, 152341)).micros);
    try testing.expectEqual(-26516365395395707, (try DateTime.initUTC(1129, 9, 24, 14, 56, 44, 604293)).micros);
    try testing.expectEqual(29944637164250909, (try DateTime.initUTC(2918, 11, 28, 10, 46, 4, 250909)).micros);
    try testing.expectEqual(-14268089958574835, (try DateTime.initUTC(1517, 11, 12, 1, 40, 41, 425165)).micros);
    try testing.expectEqual(10902808879115327, (try DateTime.initUTC(2315, 7, 1, 22, 1, 19, 115327)).micros);
    try testing.expectEqual(-13675746347719473, (try DateTime.initUTC(1536, 8, 19, 21, 34, 12, 280527)).micros);
    try testing.expectEqual(9823904882276154, (try DateTime.initUTC(2281, 4, 22, 14, 28, 2, 276154)).micros);
    try testing.expectEqual(-8027825490751946, (try DateTime.initUTC(1715, 8, 11, 8, 28, 29, 248054)).micros);
    try testing.expectEqual(8338818189787922, (try DateTime.initUTC(2234, 4, 1, 2, 23, 9, 787922)).micros);
    try testing.expectEqual(-2417779710874201, (try DateTime.initUTC(1893, 5, 20, 10, 31, 29, 125799)).micros);
    try testing.expectEqual(15579463520321126, (try DateTime.initUTC(2463, 9, 10, 20, 45, 20, 321126)).micros);
    try testing.expectEqual(-30111774746323219, (try DateTime.initUTC(1015, 10, 19, 2, 7, 33, 676781)).micros);
    try testing.expectEqual(8586318907201828, (try DateTime.initUTC(2242, 2, 2, 16, 35, 7, 201828)).micros);
    try testing.expectEqual(-20727462914538728, (try DateTime.initUTC(1313, 3, 4, 19, 24, 45, 461272)).micros);
    try testing.expectEqual(12684924982677857, (try DateTime.initUTC(2371, 12, 21, 6, 16, 22, 677857)).micros);
    try testing.expectEqual(-26995363453933698, (try DateTime.initUTC(1114, 7, 21, 15, 55, 46, 66302)).micros);
    try testing.expectEqual(5769549719315448, (try DateTime.initUTC(2152, 10, 30, 4, 41, 59, 315448)).micros);
    try testing.expectEqual(-9362762735064704, (try DateTime.initUTC(1673, 4, 21, 16, 34, 24, 935296)).micros);
    try testing.expectEqual(5196087673076825, (try DateTime.initUTC(2134, 8, 28, 21, 41, 13, 76825)).micros);
    try testing.expectEqual(-10198286600499296, (try DateTime.initUTC(1646, 10, 30, 6, 36, 39, 500704)).micros);
    try testing.expectEqual(19333137979539125, (try DateTime.initUTC(2582, 8, 23, 4, 6, 19, 539125)).micros);
    try testing.expectEqual(-18867539824804327, (try DateTime.initUTC(1372, 2, 10, 16, 42, 55, 195673)).micros);
    try testing.expectEqual(14853031249581056, (try DateTime.initUTC(2440, 9, 3, 2, 0, 49, 581056)).micros);
    try testing.expectEqual(-1356282109230506, (try DateTime.initUTC(1927, 1, 9, 6, 58, 10, 769494)).micros);
    try testing.expectEqual(15713222018105813, (try DateTime.initUTC(2467, 12, 6, 23, 53, 38, 105813)).micros);
    try testing.expectEqual(-12693041975378709, (try DateTime.initUTC(1567, 10, 10, 19, 0, 24, 621291)).micros);
    try testing.expectEqual(29394313298789588, (try DateTime.initUTC(2901, 6, 20, 23, 1, 38, 789588)).micros);
    try testing.expectEqual(-10583952098364782, (try DateTime.initUTC(1634, 8, 10, 13, 18, 21, 635218)).micros);
    try testing.expectEqual(22418800474726154, (try DateTime.initUTC(2680, 6, 3, 20, 34, 34, 726154)).micros);
    try testing.expectEqual(-13067278028607441, (try DateTime.initUTC(1555, 12, 1, 8, 32, 51, 392559)).micros);
    try testing.expectEqual(22348003126725817, (try DateTime.initUTC(2678, 3, 7, 10, 38, 46, 725817)).micros);
    try testing.expectEqual(-11101998054915852, (try DateTime.initUTC(1618, 3, 11, 15, 39, 5, 84148)).micros);
    try testing.expectEqual(30004645932503986, (try DateTime.initUTC(2920, 10, 22, 23, 52, 12, 503986)).micros);
    try testing.expectEqual(-27551013013624622, (try DateTime.initUTC(1096, 12, 10, 12, 49, 46, 375378)).micros);
    try testing.expectEqual(10162791607756167, (try DateTime.initUTC(2292, 1, 17, 21, 40, 7, 756167)).micros);
    try testing.expectEqual(-31309636417799549, (try DateTime.initUTC(977, 11, 1, 22, 46, 22, 200451)).micros);
    try testing.expectEqual(9816298180956872, (try DateTime.initUTC(2281, 1, 24, 13, 29, 40, 956872)).micros);
    try testing.expectEqual(-13248552913008079, (try DateTime.initUTC(1550, 3, 4, 6, 24, 46, 991921)).micros);
    try testing.expectEqual(24898184818866845, (try DateTime.initUTC(2758, 12, 29, 10, 26, 58, 866845)).micros);
    try testing.expectEqual(-10721424878768860, (try DateTime.initUTC(1630, 4, 2, 10, 25, 21, 231140)).micros);
    try testing.expectEqual(3556757075942051, (try DateTime.initUTC(2082, 9, 16, 4, 4, 35, 942051)).micros);
    try testing.expectEqual(-9515936853544912, (try DateTime.initUTC(1668, 6, 13, 20, 12, 26, 455088)).micros);
    try testing.expectEqual(23236928933459964, (try DateTime.initUTC(2706, 5, 8, 22, 28, 53, 459964)).micros);
    try testing.expectEqual(-5811784886171477, (try DateTime.initUTC(1785, 10, 30, 23, 18, 33, 828523)).micros);
    try testing.expectEqual(27342496921109542, (try DateTime.initUTC(2836, 6, 13, 2, 2, 1, 109542)).micros);
    try testing.expectEqual(-25369943235288340, (try DateTime.initUTC(1166, 1, 22, 9, 32, 44, 711660)).micros);
    try testing.expectEqual(10054378230055484, (try DateTime.initUTC(2288, 8, 11, 2, 50, 30, 55484)).micros);
    try testing.expectEqual(-10826899878642792, (try DateTime.initUTC(1626, 11, 28, 15, 48, 41, 357208)).micros);
}

test "DateTime: now" {
    const dt = DateTime.now();
    try testing.expectDelta(std.time.microTimestamp(), dt.micros, 1000);
}

test "DateTime: date" {
    try testing.expectEqual(Date{ .year = 2023, .month = 11, .day = 25 }, (try DateTime.fromUnix(1700886257, .seconds)).date());
    try testing.expectEqual(Date{ .year = 2023, .month = 11, .day = 25 }, (try DateTime.fromUnix(1700886257655, .milliseconds)).date());
    try testing.expectEqual(Date{ .year = 2023, .month = 11, .day = 25 }, (try DateTime.fromUnix(1700886257655392, .microseconds)).date());
    try testing.expectEqual(Date{ .year = 1970, .month = 1, .day = 1 }, (try DateTime.fromUnix(0, .milliseconds)).date());

    // GO:
    // for i := 0; i < 100; i++ {
    //   us := rand.Int63n(31536000000000000)
    //   if i%2 == 1 {
    //     us = -us
    //   }
    //   date := time.UnixMicro(us).UTC()
    //   fmt.Printf("\ttry testing.expectEqual(Date{.year = %d, .month = %d, .day = %d}, DateTime.fromUnix(%d, .seconds).date());\n", date.Year(), date.Month(), date.Day(), date.Unix())
    // }
    try testing.expectEqual(Date{ .year = 2438, .month = 8, .day = 8 }, (try DateTime.fromUnix(14787635606, .seconds)).date());
    try testing.expectEqual(Date{ .year = 1290, .month = 10, .day = 9 }, (try DateTime.fromUnix(-21434368940, .seconds)).date());
    try testing.expectEqual(Date{ .year = 2769, .month = 12, .day = 3 }, (try DateTime.fromUnix(25243136028, .seconds)).date());
    try testing.expectEqual(Date{ .year = 1437, .month = 6, .day = 30 }, (try DateTime.fromUnix(-16804239664, .seconds)).date());
    try testing.expectEqual(Date{ .year = 2752, .month = 4, .day = 7 }, (try DateTime.fromUnix(24685876670, .seconds)).date());
    try testing.expectEqual(Date{ .year = 1484, .month = 1, .day = 29 }, (try DateTime.fromUnix(-15334209737, .seconds)).date());
    try testing.expectEqual(Date{ .year = 2300, .month = 1, .day = 4 }, (try DateTime.fromUnix(10414107497, .seconds)).date());
    try testing.expectEqual(Date{ .year = 1520, .month = 3, .day = 27 }, (try DateTime.fromUnix(-14193188705, .seconds)).date());
    try testing.expectEqual(Date{ .year = 2628, .month = 11, .day = 21 }, (try DateTime.fromUnix(20792540664, .seconds)).date());
    try testing.expectEqual(Date{ .year = 1807, .month = 2, .day = 21 }, (try DateTime.fromUnix(-5139411928, .seconds)).date());
    try testing.expectEqual(Date{ .year = 2249, .month = 12, .day = 12 }, (try DateTime.fromUnix(8834245007, .seconds)).date());
    try testing.expectEqual(Date{ .year = 1694, .month = 11, .day = 17 }, (try DateTime.fromUnix(-8681990253, .seconds)).date());
    try testing.expectEqual(Date{ .year = 2725, .month = 6, .day = 10 }, (try DateTime.fromUnix(23839369640, .seconds)).date());
    try testing.expectEqual(Date{ .year = 1947, .month = 2, .day = 16 }, (try DateTime.fromUnix(-721811319, .seconds)).date());
    try testing.expectEqual(Date{ .year = 2293, .month = 9, .day = 28 }, (try DateTime.fromUnix(10216323340, .seconds)).date());
    try testing.expectEqual(Date{ .year = 1614, .month = 8, .day = 12 }, (try DateTime.fromUnix(-11214942944, .seconds)).date());
    try testing.expectEqual(Date{ .year = 2923, .month = 6, .day = 24 }, (try DateTime.fromUnix(30088834422, .seconds)).date());
    try testing.expectEqual(Date{ .year = 1120, .month = 4, .day = 16 }, (try DateTime.fromUnix(-26814276389, .seconds)).date());
    try testing.expectEqual(Date{ .year = 2035, .month = 12, .day = 9 }, (try DateTime.fromUnix(2080850037, .seconds)).date());
    try testing.expectEqual(Date{ .year = 1167, .month = 1, .day = 15 }, (try DateTime.fromUnix(-25338977309, .seconds)).date());
    try testing.expectEqual(Date{ .year = 2665, .month = 4, .day = 15 }, (try DateTime.fromUnix(21941133655, .seconds)).date());
    try testing.expectEqual(Date{ .year = 1375, .month = 6, .day = 18 }, (try DateTime.fromUnix(-18761787336, .seconds)).date());
    try testing.expectEqual(Date{ .year = 2189, .month = 6, .day = 13 }, (try DateTime.fromUnix(6925211914, .seconds)).date());
    try testing.expectEqual(Date{ .year = 1938, .month = 1, .day = 12 }, (try DateTime.fromUnix(-1008879186, .seconds)).date());
    try testing.expectEqual(Date{ .year = 2556, .month = 6, .day = 9 }, (try DateTime.fromUnix(18506255391, .seconds)).date());
    try testing.expectEqual(Date{ .year = 1294, .month = 10, .day = 29 }, (try DateTime.fromUnix(-21306371902, .seconds)).date());
    try testing.expectEqual(Date{ .year = 2330, .month = 3, .day = 19 }, (try DateTime.fromUnix(11367189469, .seconds)).date());
    try testing.expectEqual(Date{ .year = 1696, .month = 5, .day = 22 }, (try DateTime.fromUnix(-8634251099, .seconds)).date());
    try testing.expectEqual(Date{ .year = 2759, .month = 5, .day = 14 }, (try DateTime.fromUnix(24909971092, .seconds)).date());
    try testing.expectEqual(Date{ .year = 1641, .month = 1, .day = 31 }, (try DateTime.fromUnix(-10379518549, .seconds)).date());
    try testing.expectEqual(Date{ .year = 2451, .month = 6, .day = 26 }, (try DateTime.fromUnix(15194147684, .seconds)).date());
    try testing.expectEqual(Date{ .year = 1962, .month = 1, .day = 4 }, (try DateTime.fromUnix(-252197440, .seconds)).date());
    try testing.expectEqual(Date{ .year = 2883, .month = 11, .day = 15 }, (try DateTime.fromUnix(28839089617, .seconds)).date());
    try testing.expectEqual(Date{ .year = 1587, .month = 8, .day = 5 }, (try DateTime.fromUnix(-12067604792, .seconds)).date());
    try testing.expectEqual(Date{ .year = 2724, .month = 5, .day = 28 }, (try DateTime.fromUnix(23806729201, .seconds)).date());
    try testing.expectEqual(Date{ .year = 1043, .month = 2, .day = 25 }, (try DateTime.fromUnix(-29248487174, .seconds)).date());
    try testing.expectEqual(Date{ .year = 2927, .month = 3, .day = 9 }, (try DateTime.fromUnix(30205844459, .seconds)).date());
    try testing.expectEqual(Date{ .year = 1451, .month = 6, .day = 16 }, (try DateTime.fromUnix(-16363722083, .seconds)).date());
    try testing.expectEqual(Date{ .year = 2145, .month = 1, .day = 21 }, (try DateTime.fromUnix(5524305523, .seconds)).date());
    try testing.expectEqual(Date{ .year = 1497, .month = 10, .day = 31 }, (try DateTime.fromUnix(-14900125085, .seconds)).date());
    try testing.expectEqual(Date{ .year = 2162, .month = 4, .day = 1 }, (try DateTime.fromUnix(6066812142, .seconds)).date());
    try testing.expectEqual(Date{ .year = 1738, .month = 8, .day = 12 }, (try DateTime.fromUnix(-7301852750, .seconds)).date());
    try testing.expectEqual(Date{ .year = 2100, .month = 2, .day = 7 }, (try DateTime.fromUnix(4105665807, .seconds)).date());
    try testing.expectEqual(Date{ .year = 1847, .month = 9, .day = 29 }, (try DateTime.fromUnix(-3858020808, .seconds)).date());
    try testing.expectEqual(Date{ .year = 2370, .month = 9, .day = 19 }, (try DateTime.fromUnix(12645416176, .seconds)).date());
    try testing.expectEqual(Date{ .year = 1292, .month = 7, .day = 8 }, (try DateTime.fromUnix(-21379166225, .seconds)).date());
    try testing.expectEqual(Date{ .year = 2931, .month = 12, .day = 19 }, (try DateTime.fromUnix(30356691249, .seconds)).date());
    try testing.expectEqual(Date{ .year = 1064, .month = 5, .day = 12 }, (try DateTime.fromUnix(-28579189254, .seconds)).date());
    try testing.expectEqual(Date{ .year = 2295, .month = 5, .day = 13 }, (try DateTime.fromUnix(10267494406, .seconds)).date());
    try testing.expectEqual(Date{ .year = 1449, .month = 12, .day = 4 }, (try DateTime.fromUnix(-16411941423, .seconds)).date());
    try testing.expectEqual(Date{ .year = 2565, .month = 1, .day = 16 }, (try DateTime.fromUnix(18777760055, .seconds)).date());
    try testing.expectEqual(Date{ .year = 1968, .month = 6, .day = 25 }, (try DateTime.fromUnix(-47882241, .seconds)).date());
    try testing.expectEqual(Date{ .year = 2817, .month = 5, .day = 9 }, (try DateTime.fromUnix(26739900891, .seconds)).date());
    try testing.expectEqual(Date{ .year = 1334, .month = 7, .day = 16 }, (try DateTime.fromUnix(-20053254809, .seconds)).date());
    try testing.expectEqual(Date{ .year = 2945, .month = 4, .day = 24 }, (try DateTime.fromUnix(30777844895, .seconds)).date());
    try testing.expectEqual(Date{ .year = 1930, .month = 2, .day = 27 }, (try DateTime.fromUnix(-1257362995, .seconds)).date());
    try testing.expectEqual(Date{ .year = 2768, .month = 10, .day = 19 }, (try DateTime.fromUnix(25207675701, .seconds)).date());
    try testing.expectEqual(Date{ .year = 1372, .month = 6, .day = 12 }, (try DateTime.fromUnix(-18856904218, .seconds)).date());
    try testing.expectEqual(Date{ .year = 2603, .month = 8, .day = 29 }, (try DateTime.fromUnix(19996315706, .seconds)).date());
    try testing.expectEqual(Date{ .year = 1201, .month = 4, .day = 7 }, (try DateTime.fromUnix(-24258926407, .seconds)).date());
    try testing.expectEqual(Date{ .year = 2466, .month = 4, .day = 16 }, (try DateTime.fromUnix(15661407305, .seconds)).date());
    try testing.expectEqual(Date{ .year = 1513, .month = 5, .day = 7 }, (try DateTime.fromUnix(-14410616341, .seconds)).date());
    try testing.expectEqual(Date{ .year = 2619, .month = 9, .day = 11 }, (try DateTime.fromUnix(20502308837, .seconds)).date());
    try testing.expectEqual(Date{ .year = 1501, .month = 5, .day = 13 }, (try DateTime.fromUnix(-14788768973, .seconds)).date());
    try testing.expectEqual(Date{ .year = 2765, .month = 11, .day = 19 }, (try DateTime.fromUnix(25115683551, .seconds)).date());
    try testing.expectEqual(Date{ .year = 1881, .month = 2, .day = 9 }, (try DateTime.fromUnix(-2805094638, .seconds)).date());
    try testing.expectEqual(Date{ .year = 2253, .month = 4, .day = 28 }, (try DateTime.fromUnix(8940802800, .seconds)).date());
    try testing.expectEqual(Date{ .year = 1941, .month = 11, .day = 23 }, (try DateTime.fromUnix(-886973505, .seconds)).date());
    try testing.expectEqual(Date{ .year = 2565, .month = 1, .day = 18 }, (try DateTime.fromUnix(18777963967, .seconds)).date());
    try testing.expectEqual(Date{ .year = 1313, .month = 5, .day = 20 }, (try DateTime.fromUnix(-20720877804, .seconds)).date());
    try testing.expectEqual(Date{ .year = 2401, .month = 5, .day = 6 }, (try DateTime.fromUnix(13611949193, .seconds)).date());
    try testing.expectEqual(Date{ .year = 1146, .month = 11, .day = 2 }, (try DateTime.fromUnix(-25976564837, .seconds)).date());
    try testing.expectEqual(Date{ .year = 2115, .month = 6, .day = 11 }, (try DateTime.fromUnix(4589719542, .seconds)).date());
    try testing.expectEqual(Date{ .year = 1276, .month = 8, .day = 1 }, (try DateTime.fromUnix(-21882043432, .seconds)).date());
    try testing.expectEqual(Date{ .year = 2224, .month = 4, .day = 26 }, (try DateTime.fromUnix(8025468043, .seconds)).date());
    try testing.expectEqual(Date{ .year = 1336, .month = 6, .day = 19 }, (try DateTime.fromUnix(-19992405201, .seconds)).date());
    try testing.expectEqual(Date{ .year = 2717, .month = 5, .day = 5 }, (try DateTime.fromUnix(23583761778, .seconds)).date());
    try testing.expectEqual(Date{ .year = 1222, .month = 3, .day = 15 }, (try DateTime.fromUnix(-23598239244, .seconds)).date());
    try testing.expectEqual(Date{ .year = 2841, .month = 8, .day = 29 }, (try DateTime.fromUnix(27506984246, .seconds)).date());
    try testing.expectEqual(Date{ .year = 1818, .month = 7, .day = 28 }, (try DateTime.fromUnix(-4778656923, .seconds)).date());
    try testing.expectEqual(Date{ .year = 2533, .month = 5, .day = 13 }, (try DateTime.fromUnix(17778031068, .seconds)).date());
    try testing.expectEqual(Date{ .year = 1146, .month = 7, .day = 28 }, (try DateTime.fromUnix(-25984946441, .seconds)).date());
    try testing.expectEqual(Date{ .year = 2451, .month = 2, .day = 1 }, (try DateTime.fromUnix(15181688532, .seconds)).date());
    try testing.expectEqual(Date{ .year = 1091, .month = 8, .day = 28 }, (try DateTime.fromUnix(-27717880960, .seconds)).date());
    try testing.expectEqual(Date{ .year = 2168, .month = 4, .day = 12 }, (try DateTime.fromUnix(6257133476, .seconds)).date());
    try testing.expectEqual(Date{ .year = 1718, .month = 10, .day = 16 }, (try DateTime.fromUnix(-7927438165, .seconds)).date());
    try testing.expectEqual(Date{ .year = 2614, .month = 8, .day = 21 }, (try DateTime.fromUnix(20342724001, .seconds)).date());
    try testing.expectEqual(Date{ .year = 1869, .month = 5, .day = 4 }, (try DateTime.fromUnix(-3176499822, .seconds)).date());
    try testing.expectEqual(Date{ .year = 2504, .month = 4, .day = 20 }, (try DateTime.fromUnix(16860953121, .seconds)).date());
    try testing.expectEqual(Date{ .year = 1401, .month = 5, .day = 2 }, (try DateTime.fromUnix(-17945432544, .seconds)).date());
    try testing.expectEqual(Date{ .year = 2467, .month = 8, .day = 2 }, (try DateTime.fromUnix(15702325347, .seconds)).date());
    try testing.expectEqual(Date{ .year = 1654, .month = 3, .day = 12 }, (try DateTime.fromUnix(-9965864717, .seconds)).date());
    try testing.expectEqual(Date{ .year = 2371, .month = 9, .day = 2 }, (try DateTime.fromUnix(12675412066, .seconds)).date());
    try testing.expectEqual(Date{ .year = 1784, .month = 1, .day = 16 }, (try DateTime.fromUnix(-5868249970, .seconds)).date());
    try testing.expectEqual(Date{ .year = 2907, .month = 8, .day = 25 }, (try DateTime.fromUnix(29589265328, .seconds)).date());
    try testing.expectEqual(Date{ .year = 987, .month = 4, .day = 9 }, (try DateTime.fromUnix(-31011963272, .seconds)).date());
    try testing.expectEqual(Date{ .year = 1980, .month = 10, .day = 19 }, (try DateTime.fromUnix(340838803, .seconds)).date());
    try testing.expectEqual(Date{ .year = 1386, .month = 5, .day = 18 }, (try DateTime.fromUnix(-18417299412, .seconds)).date());
    try testing.expectEqual(Date{ .year = 2622, .month = 2, .day = 5 }, (try DateTime.fromUnix(20578157994, .seconds)).date());
    try testing.expectEqual(Date{ .year = 1056, .month = 11, .day = 6 }, (try DateTime.fromUnix(-28816263601, .seconds)).date());
}

test "DateTime: time" {
    // GO:
    // for i := 0; i < 100; i++ {
    //   us := rand.Int63n(31536000000000000)
    //   if i%2 == 1 {
    //     us = -us
    //   }
    //   date := time.UnixMicro(us).UTC()
    //   fmt.Printf("\ttry testing.expectEqual(Time{.hour = %d, .min = %d, .sec = %d, .micros = %d}, (try DateTime.fromUnix(%d, .microseconds)).time());\n", date.Hour(), date.Minute(), date.Second(), date.Nanosecond()/1000, us)
    // }
    try testing.expectEqual(Time{ .hour = 18, .min = 56, .sec = 18, .micros = 38399 }, (try DateTime.fromUnix(6940752978038399, .microseconds)).time());
    try testing.expectEqual(Time{ .hour = 14, .min = 10, .sec = 48, .micros = 481799 }, (try DateTime.fromUnix(-15037004951518201, .microseconds)).time());
    try testing.expectEqual(Time{ .hour = 13, .min = 49, .sec = 27, .micros = 814723 }, (try DateTime.fromUnix(26507483367814723, .microseconds)).time());
    try testing.expectEqual(Time{ .hour = 3, .min = 53, .sec = 47, .micros = 990825 }, (try DateTime.fromUnix(-15290625972009175, .microseconds)).time());
    try testing.expectEqual(Time{ .hour = 9, .min = 28, .sec = 54, .micros = 16606 }, (try DateTime.fromUnix(28046078934016606, .microseconds)).time());
    try testing.expectEqual(Time{ .hour = 17, .min = 36, .sec = 38, .micros = 380600 }, (try DateTime.fromUnix(-8638640601619400, .microseconds)).time());
    try testing.expectEqual(Time{ .hour = 17, .min = 29, .sec = 27, .micros = 109527 }, (try DateTime.fromUnix(26649192567109527, .microseconds)).time());
    try testing.expectEqual(Time{ .hour = 23, .min = 54, .sec = 48, .micros = 10233 }, (try DateTime.fromUnix(-24667200311989767, .microseconds)).time());
    try testing.expectEqual(Time{ .hour = 5, .min = 44, .sec = 50, .micros = 913226 }, (try DateTime.fromUnix(22200932690913226, .microseconds)).time());
    try testing.expectEqual(Time{ .hour = 5, .min = 36, .sec = 19, .micros = 337687 }, (try DateTime.fromUnix(-13186952620662313, .microseconds)).time());
    try testing.expectEqual(Time{ .hour = 20, .min = 6, .sec = 37, .micros = 157270 }, (try DateTime.fromUnix(17827416397157270, .microseconds)).time());
    try testing.expectEqual(Time{ .hour = 4, .min = 43, .sec = 33, .micros = 871331 }, (try DateTime.fromUnix(-15558635786128669, .microseconds)).time());
    try testing.expectEqual(Time{ .hour = 0, .min = 26, .sec = 54, .micros = 557236 }, (try DateTime.fromUnix(23322644814557236, .microseconds)).time());
    try testing.expectEqual(Time{ .hour = 7, .min = 38, .sec = 40, .micros = 370732 }, (try DateTime.fromUnix(-1368030079629268, .microseconds)).time());
    try testing.expectEqual(Time{ .hour = 2, .min = 31, .sec = 9, .micros = 223691 }, (try DateTime.fromUnix(20164386669223691, .microseconds)).time());
    try testing.expectEqual(Time{ .hour = 12, .min = 41, .sec = 23, .micros = 165207 }, (try DateTime.fromUnix(-20761960716834793, .microseconds)).time());
    try testing.expectEqual(Time{ .hour = 0, .min = 46, .sec = 49, .micros = 962075 }, (try DateTime.fromUnix(549247609962075, .microseconds)).time());
    try testing.expectEqual(Time{ .hour = 2, .min = 7, .sec = 12, .micros = 984678 }, (try DateTime.fromUnix(-11643688367015322, .microseconds)).time());
    try testing.expectEqual(Time{ .hour = 11, .min = 32, .sec = 16, .micros = 343799 }, (try DateTime.fromUnix(4022998336343799, .microseconds)).time());
    try testing.expectEqual(Time{ .hour = 17, .min = 26, .sec = 54, .micros = 366277 }, (try DateTime.fromUnix(-8557597985633723, .microseconds)).time());
    try testing.expectEqual(Time{ .hour = 16, .min = 1, .sec = 4, .micros = 485152 }, (try DateTime.fromUnix(15070896064485152, .microseconds)).time());
    try testing.expectEqual(Time{ .hour = 4, .min = 14, .sec = 18, .micros = 923558 }, (try DateTime.fromUnix(-15995389541076442, .microseconds)).time());
    try testing.expectEqual(Time{ .hour = 5, .min = 37, .sec = 58, .micros = 948826 }, (try DateTime.fromUnix(16828148278948826, .microseconds)).time());
    try testing.expectEqual(Time{ .hour = 6, .min = 52, .sec = 27, .micros = 1770 }, (try DateTime.fromUnix(-30509975252998230, .microseconds)).time());
    try testing.expectEqual(Time{ .hour = 0, .min = 32, .sec = 28, .micros = 381047 }, (try DateTime.fromUnix(7813499548381047, .microseconds)).time());
    try testing.expectEqual(Time{ .hour = 14, .min = 1, .sec = 49, .micros = 267686 }, (try DateTime.fromUnix(-14265712690732314, .microseconds)).time());
    try testing.expectEqual(Time{ .hour = 4, .min = 53, .sec = 23, .micros = 233239 }, (try DateTime.fromUnix(31107646403233239, .microseconds)).time());
    try testing.expectEqual(Time{ .hour = 3, .min = 0, .sec = 53, .micros = 292242 }, (try DateTime.fromUnix(-10317099546707758, .microseconds)).time());
    try testing.expectEqual(Time{ .hour = 8, .min = 22, .sec = 13, .micros = 966628 }, (try DateTime.fromUnix(11215959733966628, .microseconds)).time());
    try testing.expectEqual(Time{ .hour = 17, .min = 32, .sec = 22, .micros = 779813 }, (try DateTime.fromUnix(-15711949657220187, .microseconds)).time());
    try testing.expectEqual(Time{ .hour = 1, .min = 6, .sec = 36, .micros = 405828 }, (try DateTime.fromUnix(6872691996405828, .microseconds)).time());
    try testing.expectEqual(Time{ .hour = 12, .min = 0, .sec = 55, .micros = 420129 }, (try DateTime.fromUnix(-31068273544579871, .microseconds)).time());
    try testing.expectEqual(Time{ .hour = 22, .min = 17, .sec = 6, .micros = 930158 }, (try DateTime.fromUnix(26304473826930158, .microseconds)).time());
    try testing.expectEqual(Time{ .hour = 12, .min = 45, .sec = 25, .micros = 203619 }, (try DateTime.fromUnix(-5358482074796381, .microseconds)).time());
    try testing.expectEqual(Time{ .hour = 19, .min = 28, .sec = 0, .micros = 476749 }, (try DateTime.fromUnix(9134623680476749, .microseconds)).time());
    try testing.expectEqual(Time{ .hour = 11, .min = 58, .sec = 41, .micros = 864572 }, (try DateTime.fromUnix(-29314353678135428, .microseconds)).time());
    try testing.expectEqual(Time{ .hour = 6, .min = 19, .sec = 27, .micros = 566937 }, (try DateTime.fromUnix(9005494767566937, .microseconds)).time());
    try testing.expectEqual(Time{ .hour = 9, .min = 3, .sec = 17, .micros = 164061 }, (try DateTime.fromUnix(-24631052202835939, .microseconds)).time());
    try testing.expectEqual(Time{ .hour = 23, .min = 2, .sec = 41, .micros = 147703 }, (try DateTime.fromUnix(27754959761147703, .microseconds)).time());
    try testing.expectEqual(Time{ .hour = 16, .min = 51, .sec = 1, .micros = 710888 }, (try DateTime.fromUnix(-29839475338289112, .microseconds)).time());
    try testing.expectEqual(Time{ .hour = 1, .min = 31, .sec = 44, .micros = 244667 }, (try DateTime.fromUnix(13143000704244667, .microseconds)).time());
    try testing.expectEqual(Time{ .hour = 14, .min = 40, .sec = 45, .micros = 594500 }, (try DateTime.fromUnix(-27029323154405500, .microseconds)).time());
    try testing.expectEqual(Time{ .hour = 3, .min = 28, .sec = 18, .micros = 941443 }, (try DateTime.fromUnix(26929337298941443, .microseconds)).time());
    try testing.expectEqual(Time{ .hour = 18, .min = 34, .sec = 26, .micros = 418287 }, (try DateTime.fromUnix(-16849401933581713, .microseconds)).time());
    try testing.expectEqual(Time{ .hour = 16, .min = 51, .sec = 12, .micros = 390293 }, (try DateTime.fromUnix(24013471872390293, .microseconds)).time());
    try testing.expectEqual(Time{ .hour = 5, .min = 27, .sec = 59, .micros = 116472 }, (try DateTime.fromUnix(-4881839520883528, .microseconds)).time());
    try testing.expectEqual(Time{ .hour = 22, .min = 38, .sec = 58, .micros = 829840 }, (try DateTime.fromUnix(28012689538829840, .microseconds)).time());
    try testing.expectEqual(Time{ .hour = 13, .min = 31, .sec = 51, .micros = 397163 }, (try DateTime.fromUnix(-14000034488602837, .microseconds)).time());
    try testing.expectEqual(Time{ .hour = 16, .min = 25, .sec = 36, .micros = 566333 }, (try DateTime.fromUnix(3819630336566333, .microseconds)).time());
    try testing.expectEqual(Time{ .hour = 23, .min = 52, .sec = 35, .micros = 404576 }, (try DateTime.fromUnix(-24790838844595424, .microseconds)).time());
    try testing.expectEqual(Time{ .hour = 14, .min = 17, .sec = 56, .micros = 248627 }, (try DateTime.fromUnix(4303462676248627, .microseconds)).time());
    try testing.expectEqual(Time{ .hour = 22, .min = 56, .sec = 31, .micros = 445770 }, (try DateTime.fromUnix(-7573827808554230, .microseconds)).time());
    try testing.expectEqual(Time{ .hour = 1, .min = 36, .sec = 32, .micros = 60901 }, (try DateTime.fromUnix(12791180192060901, .microseconds)).time());
    try testing.expectEqual(Time{ .hour = 4, .min = 12, .sec = 1, .micros = 816276 }, (try DateTime.fromUnix(-29726596078183724, .microseconds)).time());
    try testing.expectEqual(Time{ .hour = 17, .min = 25, .sec = 2, .micros = 88680 }, (try DateTime.fromUnix(9072494702088680, .microseconds)).time());
    try testing.expectEqual(Time{ .hour = 7, .min = 14, .sec = 18, .micros = 149127 }, (try DateTime.fromUnix(-20968821941850873, .microseconds)).time());
    try testing.expectEqual(Time{ .hour = 15, .min = 45, .sec = 55, .micros = 818121 }, (try DateTime.fromUnix(14590424755818121, .microseconds)).time());
    try testing.expectEqual(Time{ .hour = 13, .min = 45, .sec = 5, .micros = 544234 }, (try DateTime.fromUnix(-21099694494455766, .microseconds)).time());
    try testing.expectEqual(Time{ .hour = 20, .min = 58, .sec = 32, .micros = 361661 }, (try DateTime.fromUnix(27070837112361661, .microseconds)).time());
    try testing.expectEqual(Time{ .hour = 18, .min = 42, .sec = 3, .micros = 375293 }, (try DateTime.fromUnix(-22783699076624707, .microseconds)).time());
    try testing.expectEqual(Time{ .hour = 15, .min = 5, .sec = 18, .micros = 844868 }, (try DateTime.fromUnix(3924515118844868, .microseconds)).time());
    try testing.expectEqual(Time{ .hour = 17, .min = 39, .sec = 15, .micros = 454348 }, (try DateTime.fromUnix(-19519510844545652, .microseconds)).time());
    try testing.expectEqual(Time{ .hour = 22, .min = 34, .sec = 57, .micros = 584438 }, (try DateTime.fromUnix(25405223697584438, .microseconds)).time());
    try testing.expectEqual(Time{ .hour = 12, .min = 58, .sec = 48, .micros = 604253 }, (try DateTime.fromUnix(-23848167671395747, .microseconds)).time());
    try testing.expectEqual(Time{ .hour = 21, .min = 6, .sec = 10, .micros = 130143 }, (try DateTime.fromUnix(9179039170130143, .microseconds)).time());
    try testing.expectEqual(Time{ .hour = 11, .min = 40, .sec = 45, .micros = 806457 }, (try DateTime.fromUnix(-10457900354193543, .microseconds)).time());
    try testing.expectEqual(Time{ .hour = 5, .min = 32, .sec = 3, .micros = 84471 }, (try DateTime.fromUnix(20206560723084471, .microseconds)).time());
    try testing.expectEqual(Time{ .hour = 11, .min = 8, .sec = 48, .micros = 571978 }, (try DateTime.fromUnix(-13147966271428022, .microseconds)).time());
    try testing.expectEqual(Time{ .hour = 10, .min = 37, .sec = 9, .micros = 847397 }, (try DateTime.fromUnix(9639599829847397, .microseconds)).time());
    try testing.expectEqual(Time{ .hour = 20, .min = 15, .sec = 37, .micros = 731453 }, (try DateTime.fromUnix(-17972509462268547, .microseconds)).time());
    try testing.expectEqual(Time{ .hour = 0, .min = 36, .sec = 51, .micros = 658834 }, (try DateTime.fromUnix(23080639011658834, .microseconds)).time());
    try testing.expectEqual(Time{ .hour = 3, .min = 6, .sec = 2, .micros = 359939 }, (try DateTime.fromUnix(-13484004837640061, .microseconds)).time());
    try testing.expectEqual(Time{ .hour = 1, .min = 24, .sec = 8, .micros = 76822 }, (try DateTime.fromUnix(22642161848076822, .microseconds)).time());
    try testing.expectEqual(Time{ .hour = 5, .min = 20, .sec = 47, .micros = 940649 }, (try DateTime.fromUnix(-9576815952059351, .microseconds)).time());
    try testing.expectEqual(Time{ .hour = 16, .min = 19, .sec = 30, .micros = 228423 }, (try DateTime.fromUnix(11237847570228423, .microseconds)).time());
    try testing.expectEqual(Time{ .hour = 16, .min = 54, .sec = 33, .micros = 913828 }, (try DateTime.fromUnix(-9146156726086172, .microseconds)).time());
    try testing.expectEqual(Time{ .hour = 20, .min = 14, .sec = 10, .micros = 663120 }, (try DateTime.fromUnix(12400805650663120, .microseconds)).time());
    try testing.expectEqual(Time{ .hour = 15, .min = 22, .sec = 22, .micros = 500411 }, (try DateTime.fromUnix(-13183893457499589, .microseconds)).time());
    try testing.expectEqual(Time{ .hour = 18, .min = 42, .sec = 11, .micros = 637021 }, (try DateTime.fromUnix(17415888131637021, .microseconds)).time());
    try testing.expectEqual(Time{ .hour = 22, .min = 7, .sec = 43, .micros = 497651 }, (try DateTime.fromUnix(-3828045136502349, .microseconds)).time());
    try testing.expectEqual(Time{ .hour = 9, .min = 25, .sec = 22, .micros = 960397 }, (try DateTime.fromUnix(25585406722960397, .microseconds)).time());
    try testing.expectEqual(Time{ .hour = 20, .min = 36, .sec = 31, .micros = 312572 }, (try DateTime.fromUnix(-11209202608687428, .microseconds)).time());
    try testing.expectEqual(Time{ .hour = 5, .min = 25, .sec = 18, .micros = 104173 }, (try DateTime.fromUnix(7748544318104173, .microseconds)).time());
    try testing.expectEqual(Time{ .hour = 11, .min = 23, .sec = 25, .micros = 504363 }, (try DateTime.fromUnix(-22111446994495637, .microseconds)).time());
    try testing.expectEqual(Time{ .hour = 19, .min = 48, .sec = 44, .micros = 703684 }, (try DateTime.fromUnix(21347696924703684, .microseconds)).time());
    try testing.expectEqual(Time{ .hour = 12, .min = 10, .sec = 21, .micros = 67035 }, (try DateTime.fromUnix(-29976004178932965, .microseconds)).time());
    try testing.expectEqual(Time{ .hour = 6, .min = 0, .sec = 55, .micros = 355102 }, (try DateTime.fromUnix(15622869655355102, .microseconds)).time());
    try testing.expectEqual(Time{ .hour = 21, .min = 12, .sec = 1, .micros = 574873 }, (try DateTime.fromUnix(-28386384478425127, .microseconds)).time());
    try testing.expectEqual(Time{ .hour = 22, .min = 29, .sec = 45, .micros = 886627 }, (try DateTime.fromUnix(27787703385886627, .microseconds)).time());
    try testing.expectEqual(Time{ .hour = 8, .min = 43, .sec = 51, .micros = 403514 }, (try DateTime.fromUnix(-591981368596486, .microseconds)).time());
    try testing.expectEqual(Time{ .hour = 12, .min = 1, .sec = 19, .micros = 667089 }, (try DateTime.fromUnix(411998479667089, .microseconds)).time());
    try testing.expectEqual(Time{ .hour = 14, .min = 15, .sec = 53, .micros = 366760 }, (try DateTime.fromUnix(-29916899046633240, .microseconds)).time());
    try testing.expectEqual(Time{ .hour = 19, .min = 31, .sec = 23, .micros = 639485 }, (try DateTime.fromUnix(29847555083639485, .microseconds)).time());
    try testing.expectEqual(Time{ .hour = 0, .min = 21, .sec = 29, .micros = 207122 }, (try DateTime.fromUnix(-13356229110792878, .microseconds)).time());
    try testing.expectEqual(Time{ .hour = 10, .min = 35, .sec = 51, .micros = 789976 }, (try DateTime.fromUnix(2401353351789976, .microseconds)).time());
    try testing.expectEqual(Time{ .hour = 23, .min = 51, .sec = 4, .micros = 23674 }, (try DateTime.fromUnix(-8687002135976326, .microseconds)).time());
    try testing.expectEqual(Time{ .hour = 3, .min = 23, .sec = 21, .micros = 985741 }, (try DateTime.fromUnix(7637772201985741, .microseconds)).time());
    try testing.expectEqual(Time{ .hour = 22, .min = 3, .sec = 34, .micros = 497666 }, (try DateTime.fromUnix(-22331814985502334, .microseconds)).time());
    try testing.expectEqual(Time{ .hour = 17, .min = 15, .sec = 11, .micros = 818441 }, (try DateTime.fromUnix(14544983711818441, .microseconds)).time());
    try testing.expectEqual(Time{ .hour = 17, .min = 47, .sec = 39, .micros = 303089 }, (try DateTime.fromUnix(-19977775940696911, .microseconds)).time());
}

test "DateTime: parse RFC822" {
    // try testing.expectError(error.InvalidDateTime, DateTime.parse("", .rfc822));
    // try testing.expectError(error.InvalidDateTime, DateTime.parse("nope", .rfc822));
    try testing.expectError(error.InvalidDate, DateTime.parse("Oth, 01 Jan 20 10:10 Z", .rfc822));
    try testing.expectError(error.InvalidDate, DateTime.parse("Mon , 01 Jan 20 10:10 Z", .rfc822));
    try testing.expectError(error.InvalidDate, DateTime.parse("Mon,  01 Jan 20 10:10 Z", .rfc822));
    try testing.expectError(error.InvalidDate, DateTime.parse(" Mon, 1 Jan 20 10:10 Z", .rfc822));
    try testing.expectError(error.InvalidDate, DateTime.parse("Wed, 1 Jan 20 10:10 Z", .rfc822));
    try testing.expectError(error.InvalidDate, DateTime.parse("Wed, 01  Jan 20 10:10 Z", .rfc822));
    try testing.expectError(error.InvalidDate, DateTime.parse("Wed, 01 J 20 10:10 Z", .rfc822));
    try testing.expectError(error.InvalidDate, DateTime.parse("Wed, 01 Ja 20 10:10 Z", .rfc822));
    try testing.expectError(error.InvalidDate, DateTime.parse("Wed, 01 Jan 2 10:10 Z", .rfc822));
    try testing.expectError(error.InvalidDate, DateTime.parse("Wed, 01 Jan  20 10:10 Z", .rfc822));
    try testing.expectError(error.InvalidTime, DateTime.parse("Wed, 01 Jan 20  10:10 Z", .rfc822));
    try testing.expectError(error.InvalidTime, DateTime.parse("Wed, 01 Jan 20 1:10 Z", .rfc822));
    try testing.expectError(error.InvalidTime, DateTime.parse("Wed, 01 Jan 20 a:10 Z", .rfc822));
    try testing.expectError(error.InvalidTime, DateTime.parse("Wed, 01 Jan 20 1a:10 Z", .rfc822));
    try testing.expectError(error.InvalidTime, DateTime.parse("Wed, 01 Jan 20 200:10 Z", .rfc822));
    try testing.expectError(error.InvalidTime, DateTime.parse("Wed, 01 Jan 20 20:1 Z", .rfc822));
    try testing.expectError(error.InvalidTime, DateTime.parse("Wed, 01 Jan 20 20:001 Z", .rfc822));
    try testing.expectError(error.InvalidTime, DateTime.parse("Wed, 01 Jan 20 20:a Z", .rfc822));
    try testing.expectError(error.InvalidTime, DateTime.parse("Wed, 01 Jan 20 20:1a Z", .rfc822));
    try testing.expectError(error.InvalidTime, DateTime.parse("Wed, 01 Jan 20 20:1a: Z", .rfc822));
    try testing.expectError(error.InvalidTime, DateTime.parse("Wed, 01 Jan 20 20:1a:1 Z", .rfc822));
    try testing.expectError(error.InvalidTime, DateTime.parse("Wed, 01 Jan 20 20:1a:a Z", .rfc822));
    try testing.expectError(error.InvalidTime, DateTime.parse("Wed, 01 Jan 20 20:1a:999 Z", .rfc822));
    try testing.expectError(error.InvalidTime, DateTime.parse("Wed, 01 Jan 20 20:1a:999 Z", .rfc822));
    try testing.expectError(error.InvalidTime, DateTime.parse("Wed, 01 Jan 20 20:1a:22", .rfc822));
    try testing.expectError(error.InvalidTime, DateTime.parse("Wed, 01 Jan 20 20:1a:22  Z", .rfc822));
    try testing.expectError(error.InvalidTime, DateTime.parse("Wed, 01 Jan 20 20:1a:22 X", .rfc822));
    try testing.expectError(error.InvalidTime, DateTime.parse("Wed, 01 Jan 20 20:1a:22 ZZ", .rfc822));

    {
        const dt = try DateTime.parse("31 Dec 68 23:59 Z", .rfc822);
        try testing.expectEqual(3124223940000000, dt.micros);
        try testing.expectEqual(2068, dt.date().year);
        try testing.expectEqual(12, dt.date().month);
        try testing.expectEqual(31, dt.date().day);
        try testing.expectEqual(23, dt.time().hour);
        try testing.expectEqual(59, dt.time().min);
        try testing.expectEqual(0, dt.time().sec);
        try testing.expectEqual(0, dt.time().micros);
    }

    {
        const dt = try DateTime.parse("Mon, 31 Dec 68 23:59 Z", .rfc822);
        try testing.expectEqual(3124223940000000, dt.micros);
        try testing.expectEqual(2068, dt.date().year);
        try testing.expectEqual(12, dt.date().month);
        try testing.expectEqual(31, dt.date().day);
        try testing.expectEqual(23, dt.time().hour);
        try testing.expectEqual(59, dt.time().min);
        try testing.expectEqual(0, dt.time().sec);
        try testing.expectEqual(0, dt.time().micros);
    }

    {
        const dt = try DateTime.parse("01 Jan 69 01:22:03 GMT", .rfc822);
        try testing.expectEqual(-31531077000000, dt.micros);
        try testing.expectEqual(1969, dt.date().year);
        try testing.expectEqual(1, dt.date().month);
        try testing.expectEqual(1, dt.date().day);
        try testing.expectEqual(1, dt.time().hour);
        try testing.expectEqual(22, dt.time().min);
        try testing.expectEqual(3, dt.time().sec);
        try testing.expectEqual(0, dt.time().micros);
    }

    {
        const dt = try DateTime.parse("Sat, 18 Jan 2070 01:22:03 GMT", .rfc822);
        try testing.expectEqual(3157233723000000, dt.micros);
        try testing.expectEqual(2070, dt.date().year);
        try testing.expectEqual(1, dt.date().month);
        try testing.expectEqual(18, dt.date().day);
        try testing.expectEqual(1, dt.time().hour);
        try testing.expectEqual(22, dt.time().min);
        try testing.expectEqual(3, dt.time().sec);
        try testing.expectEqual(0, dt.time().micros);
    }
}

test "DateTime: parse RFC3339" {
    {
        const dt = try DateTime.parse("-3221-01-02T03:04:05Z", .rfc3339);
        try testing.expectEqual(-163812056155000000, dt.micros);
        try testing.expectEqual(-3221, dt.date().year);
        try testing.expectEqual(1, dt.date().month);
        try testing.expectEqual(2, dt.date().day);
        try testing.expectEqual(3, dt.time().hour);
        try testing.expectEqual(4, dt.time().min);
        try testing.expectEqual(5, dt.time().sec);
        try testing.expectEqual(0, dt.time().micros);
    }

    {
        const dt = try DateTime.parse("0001-02-03T04:05:06.789+00:00", .rfc3339);
        try testing.expectEqual(-62132730893211000, dt.micros);
        try testing.expectEqual(1, dt.date().year);
        try testing.expectEqual(2, dt.date().month);
        try testing.expectEqual(3, dt.date().day);
        try testing.expectEqual(4, dt.time().hour);
        try testing.expectEqual(5, dt.time().min);
        try testing.expectEqual(6, dt.time().sec);
        try testing.expectEqual(789000, dt.time().micros);
    }

    {
        const dt = try DateTime.parse("5000-12-31T23:59:58.987654321Z", .rfc3339);
        try testing.expectEqual(95649119998987654, dt.micros);
        try testing.expectEqual(5000, dt.date().year);
        try testing.expectEqual(12, dt.date().month);
        try testing.expectEqual(31, dt.date().day);
        try testing.expectEqual(23, dt.time().hour);
        try testing.expectEqual(59, dt.time().min);
        try testing.expectEqual(58, dt.time().sec);
        try testing.expectEqual(987654, dt.time().micros);
    }

    {
        // invalid format
        try testing.expectError(error.InvalidDate, DateTime.parse("", .rfc3339));
        try testing.expectError(error.InvalidDate, DateTime.parse("2023/01-02T00:00Z", .rfc3339));
        try testing.expectError(error.InvalidDate, DateTime.parse("2023-01/02T00:00Z", .rfc3339));
        try testing.expectError(error.InvalidDateTime, DateTime.parse("0001-01-01 T00:00Z", .rfc3339));
        try testing.expectError(error.InvalidDateTime, DateTime.parse("0001-01-01t00:00Z", .rfc3339));
        try testing.expectError(error.InvalidDateTime, DateTime.parse("0001-01-01 00:00Z", .rfc3339));
        try testing.expectError(error.InvalidDate, DateTime.parse("2023-1-02T00:00Z", .rfc3339));
        try testing.expectError(error.InvalidDate, DateTime.parse("2023-01-2T00:00Z", .rfc3339));
        try testing.expectError(error.InvalidDate, DateTime.parse("9-01-2T00:00Z", .rfc3339));
        try testing.expectError(error.InvalidDate, DateTime.parse("99-01-2T00:00Z", .rfc3339));
        try testing.expectError(error.InvalidDate, DateTime.parse("999-01-2T00:00Z", .rfc3339));
        try testing.expectError(error.InvalidDate, DateTime.parse("-999-01-2T00:00Z", .rfc3339));
        try testing.expectError(error.InvalidDate, DateTime.parse("-1-01-2T00:00Z", .rfc3339));
    }

    // date portion is ISO8601
    try testing.expectError(error.InvalidDate, DateTime.parse("20230102T23:59:58.987654321Z", .rfc3339));

    {
        // invalid month
        try testing.expectError(error.InvalidDate, DateTime.parse("2023-00-22T00:00Z", .rfc3339));
        try testing.expectError(error.InvalidDate, DateTime.parse("2023-0A-22T00:00Z", .rfc3339));
        try testing.expectError(error.InvalidDate, DateTime.parse("2023-13-22T00:00Z", .rfc3339));
        try testing.expectError(error.InvalidDate, DateTime.parse("2023-99-22T00:00Z", .rfc3339));
        try testing.expectError(error.InvalidDate, DateTime.parse("-2023-00-22T00:00Z", .rfc3339));
        try testing.expectError(error.InvalidDate, DateTime.parse("-2023-13-22T00:00Z", .rfc3339));
        try testing.expectError(error.InvalidDate, DateTime.parse("-2023-99-22T00:00Z", .rfc3339));
    }

    {
        // invalid day
        try testing.expectError(error.InvalidDate, DateTime.parse("2023-01-00T00:00Z", .rfc3339));
        try testing.expectError(error.InvalidDate, DateTime.parse("2023-01-32T00:00Z", .rfc3339));
        try testing.expectError(error.InvalidDate, DateTime.parse("2023-02-29T00:00Z", .rfc3339));
        try testing.expectError(error.InvalidDate, DateTime.parse("2023-03-32T00:00Z", .rfc3339));
        try testing.expectError(error.InvalidDate, DateTime.parse("2023-04-31T00:00Z", .rfc3339));
        try testing.expectError(error.InvalidDate, DateTime.parse("2023-05-32T00:00Z", .rfc3339));
        try testing.expectError(error.InvalidDate, DateTime.parse("2023-06-31T00:00Z", .rfc3339));
        try testing.expectError(error.InvalidDate, DateTime.parse("2023-07-32T00:00Z", .rfc3339));
        try testing.expectError(error.InvalidDate, DateTime.parse("2023-08-32T00:00Z", .rfc3339));
        try testing.expectError(error.InvalidDate, DateTime.parse("2023-09-31T00:00Z", .rfc3339));
        try testing.expectError(error.InvalidDate, DateTime.parse("2023-10-32T00:00Z", .rfc3339));
        try testing.expectError(error.InvalidDate, DateTime.parse("2023-11-31T00:00Z", .rfc3339));
        try testing.expectError(error.InvalidDate, DateTime.parse("2023-12-32T00:00Z", .rfc3339));
    }

    {
        // valid (max day)
        try testing.expectEqual(1675123200000000, (try DateTime.parse("2023-01-31T00:00Z", .rfc3339)).micros);
        try testing.expectEqual(1677542400000000, (try DateTime.parse("2023-02-28T00:00Z", .rfc3339)).micros);
        try testing.expectEqual(1680220800000000, (try DateTime.parse("2023-03-31T00:00Z", .rfc3339)).micros);
        try testing.expectEqual(1682812800000000, (try DateTime.parse("2023-04-30T00:00Z", .rfc3339)).micros);
        try testing.expectEqual(1685491200000000, (try DateTime.parse("2023-05-31T00:00Z", .rfc3339)).micros);
        try testing.expectEqual(1688083200000000, (try DateTime.parse("2023-06-30T00:00Z", .rfc3339)).micros);
        try testing.expectEqual(1690761600000000, (try DateTime.parse("2023-07-31T00:00Z", .rfc3339)).micros);
        try testing.expectEqual(1693440000000000, (try DateTime.parse("2023-08-31T00:00Z", .rfc3339)).micros);
        try testing.expectEqual(1696032000000000, (try DateTime.parse("2023-09-30T00:00Z", .rfc3339)).micros);
        try testing.expectEqual(1698710400000000, (try DateTime.parse("2023-10-31T00:00Z", .rfc3339)).micros);
        try testing.expectEqual(1701302400000000, (try DateTime.parse("2023-11-30T00:00Z", .rfc3339)).micros);
        try testing.expectEqual(1703980800000000, (try DateTime.parse("2023-12-31T00:00Z", .rfc3339)).micros);
    }

    {
        // leap years
        try testing.expectEqual(951782400000000, (try DateTime.parse("2000-02-29T00:00Z", .rfc3339)).micros);
        try testing.expectEqual(13574563200000000, (try DateTime.parse("2400-02-29T00:00Z", .rfc3339)).micros);
        try testing.expectEqual(1330473600000000, (try DateTime.parse("2012-02-29T00:00Z", .rfc3339)).micros);
        try testing.expectEqual(1709164800000000, (try DateTime.parse("2024-02-29T00:00Z", .rfc3339)).micros);

        try testing.expectError(error.InvalidDate, DateTime.parse("2000-02-30T00:00Z", .rfc3339));
        try testing.expectError(error.InvalidDate, DateTime.parse("2400-02-30T00:00Z", .rfc3339));
        try testing.expectError(error.InvalidDate, DateTime.parse("2012-02-30T00:00Z", .rfc3339));
        try testing.expectError(error.InvalidDate, DateTime.parse("2024-02-30T00:00Z", .rfc3339));

        try testing.expectError(error.InvalidDate, DateTime.parse("2100-02-29T00:00Z", .rfc3339));
        try testing.expectError(error.InvalidDate, DateTime.parse("2200-02-29T00:00Z", .rfc3339));
    }

    {
        // invalid time
        try testing.expectError(error.InvalidTime, DateTime.parse("2023-10-10T", .rfc3339));
        try testing.expectError(error.InvalidTime, DateTime.parse("2023-10-10T01:00:", .rfc3339));
        try testing.expectError(error.InvalidTime, DateTime.parse("2023-10-10T1:00:00", .rfc3339));
        try testing.expectError(error.InvalidTime, DateTime.parse("2023-10-10T10:1:00", .rfc3339));
        try testing.expectError(error.InvalidTime, DateTime.parse("2023-10-10T10:11:4", .rfc3339));
        try testing.expectError(error.InvalidTime, DateTime.parse("2023-10-10T10:20:30.", .rfc3339));
        try testing.expectError(error.InvalidDateTime, DateTime.parse("2023-10-10T10:20:30.a", .rfc3339));
        try testing.expectError(error.InvalidTime, DateTime.parse("2023-10-10T10:20:30.1234567899", .rfc3339));
        try testing.expectError(error.InvalidTime, DateTime.parse("2023-10-10T24:00:00", .rfc3339));
        try testing.expectError(error.InvalidTime, DateTime.parse("2023-10-10T00:60:00", .rfc3339));
        try testing.expectError(error.InvalidTime, DateTime.parse("2023-10-10T00:00:60", .rfc3339));
        try testing.expectError(error.InvalidTime, DateTime.parse("2023-10-10T0a:00:00", .rfc3339));
        try testing.expectError(error.InvalidTime, DateTime.parse("2023-10-10T00:0a:00", .rfc3339));
        try testing.expectError(error.InvalidTime, DateTime.parse("2023-10-10T00:00:0a", .rfc3339));
        try testing.expectError(error.InvalidTime, DateTime.parse("2023-10-10T00/00:00", .rfc3339));
        try testing.expectError(error.InvalidDateTime, DateTime.parse("2023-10-10T00:00 00", .rfc3339));
    }
}

test "DateTime: json" {
    {
        // DateTime, time no fraction
        const dt = try DateTime.parse("2023-09-22T23:59:02Z", .rfc3339);
        const out = try std.json.Stringify.valueAlloc(testing.allocator, dt, .{});
        defer testing.allocator.free(out);
        try testing.expectString("\"2023-09-22T23:59:02Z\"", out);
    }

    {
        // time, milliseconds only
        const dt = try DateTime.parse("2023-09-22T07:09:32.202Z", .rfc3339);
        const out = try std.json.Stringify.valueAlloc(testing.allocator, dt, .{});
        defer testing.allocator.free(out);
        try testing.expectString("\"2023-09-22T07:09:32.202Z\"", out);
    }

    {
        // time, micros
        const dt = try DateTime.parse("-0004-12-03T01:02:03.123456Z", .rfc3339);
        const out = try std.json.Stringify.valueAlloc(testing.allocator, dt, .{});
        defer testing.allocator.free(out);
        try testing.expectString("\"-0004-12-03T01:02:03.123456Z\"", out);
    }

    {
        // parse
        const ts = try std.json.parseFromSlice(TestStruct, testing.allocator, "{\"datetime\":\"2023-09-22T07:09:32.202Z\"}", .{});
        defer ts.deinit();
        try testing.expectEqual(try DateTime.parse("2023-09-22T07:09:32.202Z", .rfc3339), ts.value.datetime.?);
    }
}

test "DateTime: format" {
    {
        var buf: [30]u8 = undefined;
        const out = try std.fmt.bufPrint(&buf, "{f}", .{try DateTime.initUTC(2023, 5, 22, 23, 59, 59, 0)});
        try testing.expectString("2023-05-22T23:59:59Z", out);
    }

    {
        var buf: [30]u8 = undefined;
        const out = try std.fmt.bufPrint(&buf, "{f}", .{try DateTime.initUTC(2023, 5, 22, 8, 9, 10, 12)});
        try testing.expectString("2023-05-22T08:09:10.000012Z", out);
    }

    {
        var buf: [30]u8 = undefined;
        const out = try std.fmt.bufPrint(&buf, "{f}", .{try DateTime.initUTC(2023, 5, 22, 8, 9, 10, 123)});
        try testing.expectString("2023-05-22T08:09:10.000123Z", out);
    }

    {
        var buf: [30]u8 = undefined;
        const out = try std.fmt.bufPrint(&buf, "{f}", .{try DateTime.initUTC(2023, 5, 22, 8, 9, 10, 1234)});
        try testing.expectString("2023-05-22T08:09:10.001234Z", out);
    }

    {
        var buf: [30]u8 = undefined;
        const out = try std.fmt.bufPrint(&buf, "{f}", .{try DateTime.initUTC(-102, 12, 9, 8, 9, 10, 12345)});
        try testing.expectString("-0102-12-09T08:09:10.012345Z", out);
    }

    {
        var buf: [30]u8 = undefined;
        const out = try std.fmt.bufPrint(&buf, "{f}", .{try DateTime.initUTC(-102, 12, 9, 8, 9, 10, 123456)});
        try testing.expectString("-0102-12-09T08:09:10.123456Z", out);
    }
}

test "DateTime: order" {
    {
        const a = try DateTime.initUTC(2023, 11, 23, 19, 17, 22, 101002);
        const b = try DateTime.initUTC(2023, 11, 23, 19, 17, 22, 101002);
        try testing.expectEqual(std.math.Order.eq, a.order(b));
    }

    {
        const a = try DateTime.initUTC(2023, 5, 22, 12, 59, 2, 492);
        const b = try DateTime.initUTC(2022, 5, 22, 23, 59, 2, 492);
        try testing.expectEqual(std.math.Order.gt, a.order(b));
        try testing.expectEqual(std.math.Order.lt, b.order(a));
    }

    {
        const a = try DateTime.initUTC(2022, 6, 22, 23, 59, 2, 492);
        const b = try DateTime.initUTC(2022, 5, 22, 23, 33, 2, 492);
        try testing.expectEqual(std.math.Order.gt, a.order(b));
        try testing.expectEqual(std.math.Order.lt, b.order(a));
    }

    {
        const a = try DateTime.initUTC(2023, 5, 23, 23, 59, 2, 492);
        const b = try DateTime.initUTC(2022, 5, 22, 23, 59, 11, 492);
        try testing.expectEqual(std.math.Order.gt, a.order(b));
        try testing.expectEqual(std.math.Order.lt, b.order(a));
    }

    {
        const a = try DateTime.initUTC(2023, 11, 23, 20, 17, 22, 101002);
        const b = try DateTime.initUTC(2023, 11, 23, 19, 17, 22, 101002);
        try testing.expectEqual(std.math.Order.gt, a.order(b));
        try testing.expectEqual(std.math.Order.lt, b.order(a));
    }

    {
        const a = try DateTime.initUTC(2023, 11, 23, 19, 18, 22, 101002);
        const b = try DateTime.initUTC(2023, 11, 23, 19, 17, 22, 101002);
        try testing.expectEqual(std.math.Order.gt, a.order(b));
        try testing.expectEqual(std.math.Order.lt, b.order(a));
    }

    {
        const a = try DateTime.initUTC(2023, 11, 23, 19, 17, 23, 101002);
        const b = try DateTime.initUTC(2023, 11, 23, 19, 17, 22, 101002);
        try testing.expectEqual(std.math.Order.gt, a.order(b));
        try testing.expectEqual(std.math.Order.lt, b.order(a));
    }

    {
        const a = try DateTime.initUTC(2023, 11, 23, 19, 17, 22, 101003);
        const b = try DateTime.initUTC(2023, 11, 23, 19, 17, 22, 101002);
        try testing.expectEqual(std.math.Order.gt, a.order(b));
        try testing.expectEqual(std.math.Order.lt, b.order(a));
    }
}

test "DateTime: unix" {
    {
        const dt = try DateTime.initUTC(-4322, 1, 1, 0, 0, 0, 0);
        try testing.expectEqual(-198556272000, dt.unix(.seconds));
        try testing.expectEqual(-198556272000000, dt.unix(.milliseconds));
        try testing.expectEqual(-198556272000000000, dt.unix(.microseconds));
    }

    {
        const dt = try DateTime.initUTC(1970, 1, 1, 0, 0, 0, 0);
        try testing.expectEqual(0, dt.unix(.seconds));
        try testing.expectEqual(0, dt.unix(.milliseconds));
        try testing.expectEqual(0, dt.unix(.microseconds));
    }

    {
        const dt = try DateTime.initUTC(2023, 11, 24, 12, 6, 14, 918000);
        try testing.expectEqual(1700827574, dt.unix(.seconds));
        try testing.expectEqual(1700827574918, dt.unix(.milliseconds));
        try testing.expectEqual(1700827574918000, dt.unix(.microseconds));
    }

    // microseconds
    // GO:
    // for i := 0; i < 50; i++ {
    //   us := rand.Int63n(3153600000000000)
    //   if i%2 == 1 {
    //     us = -us
    //   }
    //   date := time.UnixMicro(us).UTC()
    //   fmt.Printf("\ttry testing.expectEqual(%d, (try DateTime.parse(\"%s\", .rfc3339)).unix(.microseconds));\n", us, date.Format(time.RFC3339Nano))
    // }
    try testing.expectEqual(2568689002670356, (try DateTime.parse("2051-05-26T04:43:22.670356Z", .rfc3339)).unix(.microseconds));
    try testing.expectEqual(-2994122503199268, (try DateTime.parse("1875-02-13T19:18:16.800732Z", .rfc3339)).unix(.microseconds));
    try testing.expectEqual(2973860981156244, (try DateTime.parse("2064-03-27T16:29:41.156244Z", .rfc3339)).unix(.microseconds));
    try testing.expectEqual(-2122539648627924, (try DateTime.parse("1902-09-28T13:39:11.372076Z", .rfc3339)).unix(.microseconds));
    try testing.expectEqual(1440540448439442, (try DateTime.parse("2015-08-25T22:07:28.439442Z", .rfc3339)).unix(.microseconds));
    try testing.expectEqual(-843471236299718, (try DateTime.parse("1943-04-10T14:26:03.700282Z", .rfc3339)).unix(.microseconds));
    try testing.expectEqual(2428009970341301, (try DateTime.parse("2046-12-09T23:12:50.341301Z", .rfc3339)).unix(.microseconds));
    try testing.expectEqual(-861640488391156, (try DateTime.parse("1942-09-12T07:25:11.608844Z", .rfc3339)).unix(.microseconds));
    try testing.expectEqual(107457228254516, (try DateTime.parse("1973-05-28T17:13:48.254516Z", .rfc3339)).unix(.microseconds));
    try testing.expectEqual(-858997335483954, (try DateTime.parse("1942-10-12T21:37:44.516046Z", .rfc3339)).unix(.microseconds));
    try testing.expectEqual(1879201014676957, (try DateTime.parse("2029-07-20T00:16:54.676957Z", .rfc3339)).unix(.microseconds));
    try testing.expectEqual(-2779215184508509, (try DateTime.parse("1881-12-06T03:46:55.491491Z", .rfc3339)).unix(.microseconds));
    try testing.expectEqual(790920073212180, (try DateTime.parse("1995-01-24T04:01:13.21218Z", .rfc3339)).unix(.microseconds));
    try testing.expectEqual(-1986764905311346, (try DateTime.parse("1907-01-17T00:51:34.688654Z", .rfc3339)).unix(.microseconds));
    try testing.expectEqual(1567001594851223, (try DateTime.parse("2019-08-28T14:13:14.851223Z", .rfc3339)).unix(.microseconds));
    try testing.expectEqual(-2786308994565191, (try DateTime.parse("1881-09-15T01:16:45.434809Z", .rfc3339)).unix(.microseconds));
    try testing.expectEqual(1190930851203854, (try DateTime.parse("2007-09-27T22:07:31.203854Z", .rfc3339)).unix(.microseconds));
    try testing.expectEqual(-13894507787609, (try DateTime.parse("1969-07-24T04:24:52.212391Z", .rfc3339)).unix(.microseconds));
    try testing.expectEqual(1283185581222987, (try DateTime.parse("2010-08-30T16:26:21.222987Z", .rfc3339)).unix(.microseconds));
    try testing.expectEqual(-3080071240438154, (try DateTime.parse("1872-05-25T00:39:19.561846Z", .rfc3339)).unix(.microseconds));
    try testing.expectEqual(3091078494301752, (try DateTime.parse("2067-12-14T08:54:54.301752Z", .rfc3339)).unix(.microseconds));
    try testing.expectEqual(-2788286096253476, (try DateTime.parse("1881-08-23T04:05:03.746524Z", .rfc3339)).unix(.microseconds));
    try testing.expectEqual(1226140349962650, (try DateTime.parse("2008-11-08T10:32:29.96265Z", .rfc3339)).unix(.microseconds));
    try testing.expectEqual(-173789078990530, (try DateTime.parse("1964-06-29T13:15:21.00947Z", .rfc3339)).unix(.microseconds));
    try testing.expectEqual(2202006978733437, (try DateTime.parse("2039-10-12T04:36:18.733437Z", .rfc3339)).unix(.microseconds));
    try testing.expectEqual(-1957390566907891, (try DateTime.parse("1907-12-23T00:23:53.092109Z", .rfc3339)).unix(.microseconds));
    try testing.expectEqual(2704228013874812, (try DateTime.parse("2055-09-10T22:26:53.874812Z", .rfc3339)).unix(.microseconds));
    try testing.expectEqual(-2162891323622724, (try DateTime.parse("1901-06-18T12:51:16.377276Z", .rfc3339)).unix(.microseconds));
    try testing.expectEqual(2985526644225853, (try DateTime.parse("2064-08-09T16:57:24.225853Z", .rfc3339)).unix(.microseconds));
    try testing.expectEqual(-2714126911982044, (try DateTime.parse("1883-12-29T11:51:28.017956Z", .rfc3339)).unix(.microseconds));
    try testing.expectEqual(1389358847381035, (try DateTime.parse("2014-01-10T13:00:47.381035Z", .rfc3339)).unix(.microseconds));
    try testing.expectEqual(-2599632972496238, (try DateTime.parse("1887-08-15T15:43:47.503762Z", .rfc3339)).unix(.microseconds));
    try testing.expectEqual(2842567982275671, (try DateTime.parse("2060-01-29T02:13:02.275671Z", .rfc3339)).unix(.microseconds));
    try testing.expectEqual(-2924719405531619, (try DateTime.parse("1877-04-27T01:56:34.468381Z", .rfc3339)).unix(.microseconds));
    try testing.expectEqual(929389345478708, (try DateTime.parse("1999-06-14T19:42:25.478708Z", .rfc3339)).unix(.microseconds));
    try testing.expectEqual(-2928161617689577, (try DateTime.parse("1877-03-18T05:46:22.310423Z", .rfc3339)).unix(.microseconds));
    try testing.expectEqual(1981926664387480, (try DateTime.parse("2032-10-20T23:11:04.38748Z", .rfc3339)).unix(.microseconds));
    try testing.expectEqual(-3077852548046313, (try DateTime.parse("1872-06-19T16:57:31.953687Z", .rfc3339)).unix(.microseconds));
    try testing.expectEqual(323327680783683, (try DateTime.parse("1980-03-31T05:14:40.783683Z", .rfc3339)).unix(.microseconds));
    try testing.expectEqual(-1282955701919591, (try DateTime.parse("1929-05-06T23:24:58.080409Z", .rfc3339)).unix(.microseconds));
    try testing.expectEqual(1382921217423641, (try DateTime.parse("2013-10-28T00:46:57.423641Z", .rfc3339)).unix(.microseconds));
    try testing.expectEqual(-1431006940775286, (try DateTime.parse("1924-08-27T10:04:19.224714Z", .rfc3339)).unix(.microseconds));
    try testing.expectEqual(3074639946025509, (try DateTime.parse("2067-06-07T02:39:06.025509Z", .rfc3339)).unix(.microseconds));
    try testing.expectEqual(-2634608860053384, (try DateTime.parse("1886-07-06T20:12:19.946616Z", .rfc3339)).unix(.microseconds));
    try testing.expectEqual(2779915686281386, (try DateTime.parse("2058-02-02T22:48:06.281386Z", .rfc3339)).unix(.microseconds));
    try testing.expectEqual(-2016252325938190, (try DateTime.parse("1906-02-09T17:54:34.06181Z", .rfc3339)).unix(.microseconds));
    try testing.expectEqual(342848400150959, (try DateTime.parse("1980-11-12T03:40:00.150959Z", .rfc3339)).unix(.microseconds));
    try testing.expectEqual(-2645960576992651, (try DateTime.parse("1886-02-25T10:57:03.007349Z", .rfc3339)).unix(.microseconds));
    try testing.expectEqual(2460926767780856, (try DateTime.parse("2047-12-25T22:46:07.780856Z", .rfc3339)).unix(.microseconds));
    try testing.expectEqual(-3072719558320472, (try DateTime.parse("1872-08-18T02:47:21.679528Z", .rfc3339)).unix(.microseconds));

    // milliseconds
    // GO
    // for i := 0; i < 50; i++ {
    //   us := rand.Int63n(3153600000000000)
    //   if i%2 == 1 {
    //     us = -us
    //   }
    //   date := time.UnixMicro(us).UTC()
    //   fmt.Printf("\ttry testing.expectEqual(%d, (try DateTime.parse(\"%s\", .rfc3339)).unix(.milliseconds));\n", us/1000, date.Format(time.RFC3339Nano))
    // }
    try testing.expectEqual(1397526377500, (try DateTime.parse("2014-04-15T01:46:17.500928Z", .rfc3339)).unix(.milliseconds));
    try testing.expectEqual(-586731476093, (try DateTime.parse("1951-05-30T03:02:03.906951Z", .rfc3339)).unix(.milliseconds));
    try testing.expectEqual(2626709817261, (try DateTime.parse("2053-03-27T17:36:57.261986Z", .rfc3339)).unix(.milliseconds));
    try testing.expectEqual(-2699459388451, (try DateTime.parse("1884-06-16T06:10:11.548899Z", .rfc3339)).unix(.milliseconds));
    try testing.expectEqual(187068511670, (try DateTime.parse("1975-12-06T03:28:31.670454Z", .rfc3339)).unix(.milliseconds));
    try testing.expectEqual(-785593098555, (try DateTime.parse("1945-02-08T11:41:41.444519Z", .rfc3339)).unix(.milliseconds));
    try testing.expectEqual(2482013929293, (try DateTime.parse("2048-08-26T00:18:49.293566Z", .rfc3339)).unix(.milliseconds));
    try testing.expectEqual(-39404841784, (try DateTime.parse("1968-10-01T22:12:38.215367Z", .rfc3339)).unix(.milliseconds));
    try testing.expectEqual(1534769380821, (try DateTime.parse("2018-08-20T12:49:40.821612Z", .rfc3339)).unix(.milliseconds));
    try testing.expectEqual(-1980714497790, (try DateTime.parse("1907-03-28T01:31:42.209908Z", .rfc3339)).unix(.milliseconds));
    try testing.expectEqual(1981870811721, (try DateTime.parse("2032-10-20T07:40:11.721424Z", .rfc3339)).unix(.milliseconds));
    try testing.expectEqual(-554657243269, (try DateTime.parse("1952-06-04T08:32:36.730587Z", .rfc3339)).unix(.milliseconds));
    try testing.expectEqual(78531146024, (try DateTime.parse("1972-06-27T22:12:26.024177Z", .rfc3339)).unix(.milliseconds));
    try testing.expectEqual(-2360798362731, (try DateTime.parse("1895-03-10T22:40:37.268319Z", .rfc3339)).unix(.milliseconds));
    try testing.expectEqual(2843392029355, (try DateTime.parse("2060-02-07T15:07:09.355931Z", .rfc3339)).unix(.milliseconds));
    try testing.expectEqual(-1289360209568, (try DateTime.parse("1929-02-21T20:23:10.431793Z", .rfc3339)).unix(.milliseconds));
    try testing.expectEqual(2440116994057, (try DateTime.parse("2047-04-29T02:16:34.057859Z", .rfc3339)).unix(.milliseconds));
    try testing.expectEqual(-1958937239211, (try DateTime.parse("1907-12-05T02:46:00.788847Z", .rfc3339)).unix(.milliseconds));
    try testing.expectEqual(2092930144205, (try DateTime.parse("2036-04-27T17:29:04.205599Z", .rfc3339)).unix(.milliseconds));
    try testing.expectEqual(-1314934006371, (try DateTime.parse("1928-05-01T20:33:13.628366Z", .rfc3339)).unix(.milliseconds));
    try testing.expectEqual(1987707686213, (try DateTime.parse("2032-12-26T21:01:26.21383Z", .rfc3339)).unix(.milliseconds));
    try testing.expectEqual(-2863567343704, (try DateTime.parse("1879-04-04T20:37:36.295226Z", .rfc3339)).unix(.milliseconds));
    try testing.expectEqual(1776340450602, (try DateTime.parse("2026-04-16T11:54:10.602059Z", .rfc3339)).unix(.milliseconds));
    try testing.expectEqual(-135109264096, (try DateTime.parse("1965-09-20T05:38:55.903281Z", .rfc3339)).unix(.milliseconds));
    try testing.expectEqual(664556549013, (try DateTime.parse("1991-01-22T15:02:29.013079Z", .rfc3339)).unix(.milliseconds));
    try testing.expectEqual(-1265741428742, (try DateTime.parse("1929-11-22T05:09:31.257333Z", .rfc3339)).unix(.milliseconds));
    try testing.expectEqual(677440942549, (try DateTime.parse("1991-06-20T18:02:22.549734Z", .rfc3339)).unix(.milliseconds));
    try testing.expectEqual(-3086845293210, (try DateTime.parse("1872-03-07T14:58:26.789666Z", .rfc3339)).unix(.milliseconds));
    try testing.expectEqual(2662366721158, (try DateTime.parse("2054-05-14T10:18:41.158507Z", .rfc3339)).unix(.milliseconds));
    try testing.expectEqual(-35310777646, (try DateTime.parse("1968-11-18T07:27:02.353055Z", .rfc3339)).unix(.milliseconds));
    try testing.expectEqual(466748318057, (try DateTime.parse("1984-10-16T04:18:38.057985Z", .rfc3339)).unix(.milliseconds));
    try testing.expectEqual(-1142849776788, (try DateTime.parse("1933-10-14T13:43:43.211425Z", .rfc3339)).unix(.milliseconds));
    try testing.expectEqual(299657172861, (try DateTime.parse("1979-07-01T06:06:12.86151Z", .rfc3339)).unix(.milliseconds));
    try testing.expectEqual(-2674956599650, (try DateTime.parse("1885-03-26T20:30:00.34904Z", .rfc3339)).unix(.milliseconds));
    try testing.expectEqual(2608306771546, (try DateTime.parse("2052-08-26T17:39:31.546441Z", .rfc3339)).unix(.milliseconds));
    try testing.expectEqual(-2890194900832, (try DateTime.parse("1878-05-31T16:04:59.167405Z", .rfc3339)).unix(.milliseconds));
    try testing.expectEqual(396552033685, (try DateTime.parse("1982-07-26T17:20:33.68525Z", .rfc3339)).unix(.milliseconds));
    try testing.expectEqual(-107099840493, (try DateTime.parse("1966-08-10T10:02:39.506219Z", .rfc3339)).unix(.milliseconds));
    try testing.expectEqual(3003275118291, (try DateTime.parse("2065-03-03T03:05:18.291675Z", .rfc3339)).unix(.milliseconds));
    try testing.expectEqual(-1827348315834, (try DateTime.parse("1912-02-05T03:14:44.165534Z", .rfc3339)).unix(.milliseconds));
    try testing.expectEqual(276927903561, (try DateTime.parse("1978-10-11T04:25:03.561761Z", .rfc3339)).unix(.milliseconds));
    try testing.expectEqual(-2769749223625, (try DateTime.parse("1882-03-25T17:12:56.374223Z", .rfc3339)).unix(.milliseconds));
    try testing.expectEqual(2626498021199, (try DateTime.parse("2053-03-25T06:47:01.199662Z", .rfc3339)).unix(.milliseconds));
    try testing.expectEqual(-1394547124859, (try DateTime.parse("1925-10-23T09:47:55.140254Z", .rfc3339)).unix(.milliseconds));
    try testing.expectEqual(272330504585, (try DateTime.parse("1978-08-18T23:21:44.585364Z", .rfc3339)).unix(.milliseconds));
    try testing.expectEqual(-2210407675350, (try DateTime.parse("1899-12-15T13:52:04.649158Z", .rfc3339)).unix(.milliseconds));
    try testing.expectEqual(1506546882755, (try DateTime.parse("2017-09-27T21:14:42.755649Z", .rfc3339)).unix(.milliseconds));
    try testing.expectEqual(-2320627977264, (try DateTime.parse("1896-06-17T21:07:02.735544Z", .rfc3339)).unix(.milliseconds));
    try testing.expectEqual(2719300156090, (try DateTime.parse("2056-03-03T09:09:16.090337Z", .rfc3339)).unix(.milliseconds));
    try testing.expectEqual(-450791776320, (try DateTime.parse("1955-09-19T12:03:43.679144Z", .rfc3339)).unix(.milliseconds));

    // seconds
    // GO
    // for i := 0; i < 50; i++ {
    //   us := rand.Int63n(3153600000000000)
    //   if i%2 == 1 {
    //     us = -us
    //   }
    //   date := time.UnixMicro(us).UTC()
    //   fmt.Printf("\ttry testing.expectEqual(%d, (try DateTime.parse(\"%s\", .rfc3339)).unix(.milliseconds));\n", us/1000/1000, date.Format(time.RFC3339Nano))
    // }
    try testing.expectEqual(1019355037, (try DateTime.parse("2002-04-21T02:10:37.264298Z", .rfc3339)).unix(.seconds));
    try testing.expectEqual(-2639191098, (try DateTime.parse("1886-05-14T19:21:41.481076Z", .rfc3339)).unix(.seconds));
    try testing.expectEqual(552479765, (try DateTime.parse("1987-07-05T10:36:05.374475Z", .rfc3339)).unix(.seconds));
    try testing.expectEqual(-2842270449, (try DateTime.parse("1879-12-07T08:25:50.857157Z", .rfc3339)).unix(.seconds));
    try testing.expectEqual(2287542812, (try DateTime.parse("2042-06-28T04:33:32.585424Z", .rfc3339)).unix(.seconds));
    try testing.expectEqual(-1032056861, (try DateTime.parse("1937-04-18T21:32:18.185245Z", .rfc3339)).unix(.seconds));
    try testing.expectEqual(2294125759, (try DateTime.parse("2042-09-12T09:09:19.324234Z", .rfc3339)).unix(.seconds));
    try testing.expectEqual(-2434666174, (try DateTime.parse("1892-11-05T23:50:25.855342Z", .rfc3339)).unix(.seconds));
    try testing.expectEqual(2130180824, (try DateTime.parse("2037-07-02T20:53:44.663679Z", .rfc3339)).unix(.seconds));
    try testing.expectEqual(-2088926942, (try DateTime.parse("1903-10-22T14:30:57.110159Z", .rfc3339)).unix(.seconds));
    try testing.expectEqual(210188161, (try DateTime.parse("1976-08-29T17:36:01.512348Z", .rfc3339)).unix(.seconds));
    try testing.expectEqual(-1594811550, (try DateTime.parse("1919-06-19T12:47:29.692995Z", .rfc3339)).unix(.seconds));
    try testing.expectEqual(408055212, (try DateTime.parse("1982-12-06T20:40:12.74791Z", .rfc3339)).unix(.seconds));
    try testing.expectEqual(-763370385, (try DateTime.parse("1945-10-23T16:40:14.54824Z", .rfc3339)).unix(.seconds));
    try testing.expectEqual(2220686606, (try DateTime.parse("2040-05-15T09:23:26.183323Z", .rfc3339)).unix(.seconds));
    try testing.expectEqual(-1829267394, (try DateTime.parse("1912-01-13T22:10:05.152891Z", .rfc3339)).unix(.seconds));
    try testing.expectEqual(186103622, (try DateTime.parse("1975-11-24T23:27:02.092278Z", .rfc3339)).unix(.seconds));
    try testing.expectEqual(-104963797, (try DateTime.parse("1966-09-04T03:23:22.379643Z", .rfc3339)).unix(.seconds));
    try testing.expectEqual(188664629, (try DateTime.parse("1975-12-24T14:50:29.082285Z", .rfc3339)).unix(.seconds));
    try testing.expectEqual(-978305356, (try DateTime.parse("1939-01-01T00:30:43.460779Z", .rfc3339)).unix(.seconds));
    try testing.expectEqual(1857079750, (try DateTime.parse("2028-11-05T23:29:10.225783Z", .rfc3339)).unix(.seconds));
    try testing.expectEqual(-1059764722, (try DateTime.parse("1936-06-02T04:54:37.841836Z", .rfc3339)).unix(.seconds));
    try testing.expectEqual(2931563560, (try DateTime.parse("2062-11-24T03:12:40.682221Z", .rfc3339)).unix(.seconds));
    try testing.expectEqual(-58861051, (try DateTime.parse("1968-02-19T17:42:28.861019Z", .rfc3339)).unix(.seconds));
    try testing.expectEqual(2540374023, (try DateTime.parse("2050-07-02T11:27:03.083527Z", .rfc3339)).unix(.seconds));
    try testing.expectEqual(-369803898, (try DateTime.parse("1958-04-13T20:41:41.391534Z", .rfc3339)).unix(.seconds));
    try testing.expectEqual(1150522786, (try DateTime.parse("2006-06-17T05:39:46.776689Z", .rfc3339)).unix(.seconds));
    try testing.expectEqual(-3094311182, (try DateTime.parse("1871-12-12T05:06:57.955425Z", .rfc3339)).unix(.seconds));
    try testing.expectEqual(2742945297, (try DateTime.parse("2056-12-02T01:14:57.552041Z", .rfc3339)).unix(.seconds));
    try testing.expectEqual(-3055421456, (try DateTime.parse("1873-03-06T07:49:03.861761Z", .rfc3339)).unix(.seconds));
    try testing.expectEqual(1935913185, (try DateTime.parse("2031-05-07T09:39:45.408961Z", .rfc3339)).unix(.seconds));
    try testing.expectEqual(-1546803921, (try DateTime.parse("1920-12-26T04:14:38.089431Z", .rfc3339)).unix(.seconds));
    try testing.expectEqual(2430955251, (try DateTime.parse("2047-01-13T01:20:51.611416Z", .rfc3339)).unix(.seconds));
    try testing.expectEqual(-1162742133, (try DateTime.parse("1933-02-26T08:04:26.776057Z", .rfc3339)).unix(.seconds));
    try testing.expectEqual(2820984010, (try DateTime.parse("2059-05-24T06:40:10.9707Z", .rfc3339)).unix(.seconds));
    try testing.expectEqual(-2671779872, (try DateTime.parse("1885-05-02T14:55:27.010415Z", .rfc3339)).unix(.seconds));
    try testing.expectEqual(419726969, (try DateTime.parse("1983-04-20T22:49:29.184213Z", .rfc3339)).unix(.seconds));
    try testing.expectEqual(-2886236400, (try DateTime.parse("1878-07-16T11:39:59.700923Z", .rfc3339)).unix(.seconds));
    try testing.expectEqual(1091845921, (try DateTime.parse("2004-08-07T02:32:01.949043Z", .rfc3339)).unix(.seconds));
    try testing.expectEqual(-1345585389, (try DateTime.parse("1927-05-13T02:16:50.807413Z", .rfc3339)).unix(.seconds));
    try testing.expectEqual(968555612, (try DateTime.parse("2000-09-10T03:13:32.056103Z", .rfc3339)).unix(.seconds));
    try testing.expectEqual(-525723150, (try DateTime.parse("1953-05-05T05:47:29.657935Z", .rfc3339)).unix(.seconds));
    try testing.expectEqual(2179443523, (try DateTime.parse("2039-01-24T00:58:43.238504Z", .rfc3339)).unix(.seconds));
    try testing.expectEqual(-2200838901, (try DateTime.parse("1900-04-05T07:51:38.801707Z", .rfc3339)).unix(.seconds));
    try testing.expectEqual(567335109, (try DateTime.parse("1987-12-24T09:05:09.535877Z", .rfc3339)).unix(.seconds));
    try testing.expectEqual(-714932675, (try DateTime.parse("1947-05-07T07:35:24.863781Z", .rfc3339)).unix(.seconds));
    try testing.expectEqual(2735649359, (try DateTime.parse("2056-09-08T14:35:59.483204Z", .rfc3339)).unix(.seconds));
    try testing.expectEqual(-2386101706, (try DateTime.parse("1894-05-22T01:58:13.445088Z", .rfc3339)).unix(.seconds));
    try testing.expectEqual(115985094, (try DateTime.parse("1973-09-04T10:04:54.005266Z", .rfc3339)).unix(.seconds));
    try testing.expectEqual(-3046532170, (try DateTime.parse("1873-06-17T05:03:49.260067Z", .rfc3339)).unix(.seconds));
}

test "DateTime: limits" {
    {
        // min
        const dt1 = try DateTime.initUTC(-4712, 1, 1, 0, 0, 0, 0);
        const dt2 = try DateTime.parse("-4712-01-01T00:00:00.000000Z", .rfc3339);
        const dt3 = try DateTime.fromUnix(-210863520000, .seconds);
        const dt4 = try DateTime.fromUnix(-210863520000000, .milliseconds);
        const dt5 = try DateTime.fromUnix(-210863520000000000, .microseconds);
        for ([_]DateTime{ dt1, dt2, dt3, dt4, dt5 }) |dt| {
            try testing.expectEqual(-4712, dt.date().year);
            try testing.expectEqual(1, dt.date().month);
            try testing.expectEqual(1, dt.date().day);
            try testing.expectEqual(0, dt.time().hour);
            try testing.expectEqual(0, dt.time().min);
            try testing.expectEqual(0, dt.time().sec);
            try testing.expectEqual(0, dt.time().micros);
            try testing.expectEqual(-210863520000, dt.unix(.seconds));
            try testing.expectEqual(-210863520000000, dt.unix(.milliseconds));
            try testing.expectEqual(-210863520000000000, dt.unix(.microseconds));
        }
    }

    {
        // max
        const dt1 = try DateTime.initUTC(9999, 12, 31, 23, 59, 59, 999999);
        const dt2 = try DateTime.parse("9999-12-31T23:59:59.999999Z", .rfc3339);
        const dt3 = try DateTime.fromUnix(253402300799, .seconds);
        const dt4 = try DateTime.fromUnix(253402300799999, .milliseconds);
        const dt5 = try DateTime.fromUnix(253402300799999999, .microseconds);
        for ([_]DateTime{ dt1, dt2, dt3, dt4, dt5 }, 0..) |dt, i| {
            try testing.expectEqual(9999, dt.date().year);
            try testing.expectEqual(12, dt.date().month);
            try testing.expectEqual(31, dt.date().day);
            try testing.expectEqual(23, dt.time().hour);
            try testing.expectEqual(59, dt.time().min);
            try testing.expectEqual(59, dt.time().sec);

            try testing.expectEqual(253402300799, dt.unix(.seconds));

            if (i == 2) {
                try testing.expectEqual(0, dt.time().micros);
                try testing.expectEqual(253402300799000, dt.unix(.milliseconds));
                try testing.expectEqual(253402300799000000, dt.unix(.microseconds));
            } else if (i == 3) {
                try testing.expectEqual(999000, dt.time().micros);
                try testing.expectEqual(253402300799999, dt.unix(.milliseconds));
                try testing.expectEqual(253402300799999000, dt.unix(.microseconds));
            } else {
                try testing.expectEqual(999999, dt.time().micros);
                try testing.expectEqual(253402300799999, dt.unix(.milliseconds));
                try testing.expectEqual(253402300799999999, dt.unix(.microseconds));
            }
        }
    }
}

test "DateTime: add" {
    {
        // positive
        var dt = try DateTime.parse("2023-11-26T03:13:46.540234Z", .rfc3339);

        dt = try dt.add(800, .microseconds);
        try expectDateTime("2023-11-26T03:13:46.541034Z", dt);

        dt = try dt.add(950, .milliseconds);
        try expectDateTime("2023-11-26T03:13:47.491034Z", dt);

        dt = try dt.add(32, .seconds);
        try expectDateTime("2023-11-26T03:14:19.491034Z", dt);

        dt = try dt.add(1489, .minutes);
        try expectDateTime("2023-11-27T04:03:19.491034Z", dt);

        dt = try dt.add(6, .days);
        try expectDateTime("2023-12-03T04:03:19.491034Z", dt);
    }

    {
        // negative
        var dt = try DateTime.parse("2023-11-26T03:13:46.540234Z", .rfc3339);

        dt = try dt.add(-800, .microseconds);
        try expectDateTime("2023-11-26T03:13:46.539434Z", dt);

        dt = try dt.add(-950, .milliseconds);
        try expectDateTime("2023-11-26T03:13:45.589434Z", dt);

        dt = try dt.add(-50, .seconds);
        try expectDateTime("2023-11-26T03:12:55.589434Z", dt);

        dt = try dt.add(-1489, .minutes);
        try expectDateTime("2023-11-25T02:23:55.589434Z", dt);

        dt = try dt.add(-6, .days);
        try expectDateTime("2023-11-19T02:23:55.589434Z", dt);
    }
}

test "DateTime: sub" {
    {
        const a = try DateTime.parse("2023-11-26T03:13:46.540234Z", .rfc3339);
        const b = try DateTime.parse("2023-11-26T03:13:47.540236Z", .rfc3339);

        try testing.expectEqual(-1, a.sub(b, .seconds));
        try testing.expectEqual(-1000, a.sub(b, .milliseconds));
        try testing.expectEqual(-1000002, a.sub(b, .microseconds));
    }

    {
        const a = try DateTime.parse("2023-11-27T03:13:47.540234Z", .rfc3339);
        const b = try DateTime.parse("2023-11-26T03:13:47.540234Z", .rfc3339);

        try testing.expectEqual(86400, a.sub(b, .seconds));
        try testing.expectEqual(86400000, a.sub(b, .milliseconds));
        try testing.expectEqual(86400000000, a.sub(b, .microseconds));
    }
}

fn expectDateTime(expected: []const u8, dt: DateTime) !void {
    var buf: [30]u8 = undefined;
    const actual = try std.fmt.bufPrint(&buf, "{f}", .{dt});
    try testing.expectString(expected, actual);
}

const TestStruct = struct {
    date: ?Date = null,
    time: ?Time = null,
    datetime: ?DateTime = null,
};
