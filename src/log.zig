// Copyright (C) 2023-2024  Lightpanda (Selecy SAS)
//
// Francis Bouvier <francis@lightpanda.io>
// Pierre Tachoire <pierre@lightpanda.io>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as
// published by the Free Software Foundation, either version 3 of the
// License, or (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

const std = @import("std");
const builtin = @import("builtin");

const Thread = std.Thread;

const is_debug = builtin.mode == .Debug;

pub const Scope = enum {
    app,
    browser,
    cdp,
    console,
    http,
    js,
    loop,
    script_event,
    telemetry,
    user_script,
    unknown_prop,
    web_api,
    xhr,
    fetch,
    polyfill,
    interceptor,
};

const Opts = struct {
    format: Format = if (is_debug) .pretty else .logfmt,
    level: Level = if (is_debug) .info else .warn,
    filter_scopes: []const Scope = &.{},
};

pub var opts = Opts{};

// synchronizes writes to the output
var out_lock: Thread.Mutex = .{};

// synchronizes access to last_log
var last_log_lock: Thread.Mutex = .{};

pub fn enabled(comptime scope: Scope, level: Level) bool {
    if (@intFromEnum(level) < @intFromEnum(opts.level)) {
        return false;
    }

    if (comptime builtin.mode == .Debug) {
        for (opts.filter_scopes) |fs| {
            if (fs == scope) {
                return false;
            }
        }
    }

    return true;
}

// Ugliness to support complex debug parameters. Could add better support for
// this directly in writeValue, but we [currently] only need this in one place
// and I kind of don't want to encourage / make this easy.
pub fn separator() []const u8 {
    return if (opts.format == .pretty) "\n        " else "; ";
}

pub const Level = enum {
    debug,
    info,
    warn,
    err,
    fatal,
};

pub const Format = enum {
    logfmt,
    pretty,
};

pub fn debug(comptime scope: Scope, comptime msg: []const u8, data: anytype) void {
    log(scope, .debug, msg, data);
}

pub fn info(comptime scope: Scope, comptime msg: []const u8, data: anytype) void {
    log(scope, .info, msg, data);
}

pub fn warn(comptime scope: Scope, comptime msg: []const u8, data: anytype) void {
    log(scope, .warn, msg, data);
}

pub fn err(comptime scope: Scope, comptime msg: []const u8, data: anytype) void {
    log(scope, .err, msg, data);
}

pub fn fatal(comptime scope: Scope, comptime msg: []const u8, data: anytype) void {
    log(scope, .fatal, msg, data);
}

pub fn log(comptime scope: Scope, level: Level, comptime msg: []const u8, data: anytype) void {
    if (enabled(scope, level) == false) {
        return;
    }

    std.debug.lockStdErr();
    defer std.debug.unlockStdErr();

    var buf: [4096]u8 = undefined;
    var stderr = std.fs.File.stderr();
    var writer = stderr.writer(&buf);

    logTo(scope, level, msg, data, &writer.interface) catch |log_err| {
        std.debug.print("$time={d} $level=fatal $scope={s} $msg=\"log err\" err={s} log_msg=\"{s}\"", .{ timestamp(), @errorName(log_err), @tagName(scope), msg });
    };
}

fn logTo(comptime scope: Scope, level: Level, comptime msg: []const u8, data: anytype, out: *std.Io.Writer) !void {
    comptime {
        if (msg.len > 30) {
            @compileError("log msg cannot be more than 30 characters: '" ++ msg ++ "'");
        }
        for (msg) |b| {
            switch (b) {
                'A'...'Z', 'a'...'z', ' ', '0'...'9', '_', '-', '.', '{', '}' => {},
                else => @compileError("log msg contains an invalid character '" ++ msg ++ "'"),
            }
        }
    }

    switch (opts.format) {
        .logfmt => try logLogfmt(scope, level, msg, data, out),
        .pretty => try logPretty(scope, level, msg, data, out),
    }
    out.flush() catch return;

    const interceptor = _interceptor orelse return;
    if (interceptor.writer(interceptor.ctx, scope, level)) |iwriter| {
        try logLogfmt(scope, level, msg, data, iwriter);
        try iwriter.flush();
        interceptor.done(interceptor.ctx, scope, level);
    }
}

fn logLogfmt(comptime scope: Scope, level: Level, comptime msg: []const u8, data: anytype, writer: anytype) !void {
    try logLogFmtPrefix(scope, level, msg, writer);
    inline for (@typeInfo(@TypeOf(data)).@"struct".fields) |f| {
        const key = " " ++ f.name ++ "=";
        try writer.writeAll(key);
        try writeValue(.logfmt, @field(data, f.name), writer);
    }
    try writer.writeByte('\n');
}

fn logLogFmtPrefix(comptime scope: Scope, level: Level, comptime msg: []const u8, writer: anytype) !void {
    try writer.writeAll("$time=");
    try writer.print("{d}", .{timestamp()});

    try writer.writeAll(" $scope=");
    try writer.writeAll(@tagName(scope));

    try writer.writeAll(" $level=");
    try writer.writeAll(if (level == .err) "error" else @tagName(level));

    const full_msg = comptime blk: {
        // only wrap msg in quotes if it contains a space
        const prefix = " $msg=";
        if (std.mem.indexOfScalar(u8, msg, ' ') == null) {
            break :blk prefix ++ msg;
        }
        break :blk prefix ++ "\"" ++ msg ++ "\"";
    };
    try writer.writeAll(full_msg);
}

fn logPretty(comptime scope: Scope, level: Level, comptime msg: []const u8, data: anytype, writer: anytype) !void {
    try logPrettyPrefix(scope, level, msg, writer);
    inline for (@typeInfo(@TypeOf(data)).@"struct".fields) |f| {
        const key = "      " ++ f.name ++ " = ";
        try writer.writeAll(key);
        try writeValue(.pretty, @field(data, f.name), writer);
        try writer.writeByte('\n');
    }
    try writer.writeByte('\n');
}

fn logPrettyPrefix(comptime scope: Scope, level: Level, comptime msg: []const u8, writer: anytype) !void {
    if (scope == .console and level == .fatal and comptime std.mem.eql(u8, msg, "lightpanda")) {
        try writer.writeAll("\x1b[0;104mWARN  ");
    } else {
        try writer.writeAll(switch (level) {
            .debug => "\x1b[0;36mDEBUG\x1b[0m ",
            .info => "\x1b[0;32mINFO\x1b[0m  ",
            .warn => "\x1b[0;33mWARN\x1b[0m  ",
            .err => "\x1b[0;31mERROR ",
            .fatal => "\x1b[0;35mFATAL ",
        });
    }

    const prefix = @tagName(scope) ++ " : " ++ msg;
    try writer.writeAll(prefix);

    {
        // msg.len cannot be > 30, and @tagName(scope).len cannot be > 15
        // so this is safe
        const padding = 55 - prefix.len;
        for (0..padding / 2) |_| {
            try writer.writeAll(" .");
        }
        if (@mod(padding, 2) == 1) {
            try writer.writeByte(' ');
        }
        const el = elapsed();
        try writer.print(" \x1b[0m[+{d}{s}]", .{ el.time, el.unit });
        try writer.writeByte('\n');
    }
}

pub fn writeValue(comptime format: Format, value: anytype, writer: anytype) !void {
    const T = @TypeOf(value);
    if (std.meta.hasMethod(T, "format")) {
        return writer.print("{f}", .{value});
    }

    switch (@typeInfo(T)) {
        .optional => {
            if (value) |v| {
                return writeValue(format, v, writer);
            }
            return writer.writeAll("null");
        },
        .comptime_int, .int, .comptime_float, .float => {
            return writer.print("{d}", .{value});
        },
        .bool => {
            return writer.writeAll(if (value) "true" else "false");
        },
        .error_set => return writer.writeAll(@errorName(value)),
        .@"enum" => return writer.writeAll(@tagName(value)),
        .array => return writeValue(format, &value, writer),
        .pointer => |ptr| switch (ptr.size) {
            .slice => switch (ptr.child) {
                u8 => return writeString(format, value, writer),
                else => {},
            },
            .one => switch (@typeInfo(ptr.child)) {
                .array => |arr| if (arr.child == u8) {
                    return writeString(format, value, writer);
                },
                else => return writer.print("{f}", .{value}),
            },
            else => {},
        },
        .@"union" => return writer.print("{}", .{value}),
        .@"struct" => return writer.print("{}", .{value}),
        else => {},
    }

    @compileError("cannot log a: " ++ @typeName(T));
}

fn writeString(comptime format: Format, value: []const u8, writer: anytype) !void {
    if (format == .pretty) {
        return writer.writeAll(value);
    }

    var space_count: usize = 0;
    var escape_count: usize = 0;
    var binary_count: usize = 0;

    for (value) |b| {
        switch (b) {
            '\r', '\n', '"' => escape_count += 1,
            ' ' => space_count += 1,
            '\t', '!', '#'...'~' => {}, // printable characters
            else => binary_count += 1,
        }
    }

    if (binary_count > 0) {
        // TODO: use a different encoding if the ratio of binary data / printable is low
        return std.base64.standard_no_pad.Encoder.encodeWriter(writer, value);
    }

    if (escape_count == 0) {
        if (space_count == 0) {
            return writer.writeAll(value);
        }
        try writer.writeByte('"');
        try writer.writeAll(value);
        try writer.writeByte('"');
        return;
    }

    try writer.writeByte('"');

    var rest = value;
    while (rest.len > 0) {
        const pos = std.mem.indexOfAny(u8, rest, "\r\n\"") orelse {
            try writer.writeAll(rest);
            break;
        };
        try writer.writeAll(rest[0..pos]);
        try writer.writeByte('\\');
        switch (rest[pos]) {
            '"' => try writer.writeByte('"'),
            '\r' => try writer.writeByte('r'),
            '\n' => try writer.writeByte('n'),
            else => unreachable,
        }
        rest = rest[pos + 1 ..];
    }
    return writer.writeByte('"');
}

fn timestamp() u64 {
    if (comptime @import("builtin").is_test) {
        return 1739795092929;
    }
    return @import("datetime.zig").milliTimestamp();
}

var first_log: u64 = 0;
fn elapsed() struct { time: f64, unit: []const u8 } {
    const now = timestamp();

    last_log_lock.lock();
    defer last_log_lock.unlock();

    if (first_log == 0) {
        first_log = now;
    }

    const e = now - first_log;
    if (e < 10_000) {
        return .{ .time = @floatFromInt(e), .unit = "ms" };
    }
    return .{ .time = @as(f64, @floatFromInt(e)) / @as(f64, 1000), .unit = "s" };
}

var _interceptor: ?Interceptor = null;
pub fn registerInterceptor(interceptor: Interceptor) void {
    _interceptor = interceptor;
}

pub fn unregisterInterceptor() void {
    _interceptor = null;
}

const Interceptor = struct {
    ctx: *anyopaque,
    done: DoneFunc,
    writer: WriterFunc,

    const DoneFunc = *const fn (ctx: *anyopaque, scope: Scope, level: Level) void;
    const WriterFunc = *const fn (ctx: *anyopaque, scope: Scope, level: Level) ?*std.Io.Writer;
};

const testing = @import("testing.zig");
test "log: data" {
    opts.format = .logfmt;
    defer opts.format = .pretty;

    var aw = std.Io.Writer.Allocating.init(testing.allocator);
    defer aw.deinit();

    {
        try logTo(.browser, .err, "nope", .{}, &aw.writer);
        try testing.expectEqual("$time=1739795092929 $scope=browser $level=error $msg=nope\n", aw.written());
    }

    {
        aw.clearRetainingCapacity();
        const string = try testing.allocator.dupe(u8, "spice_must_flow");
        defer testing.allocator.free(string);

        try logTo(.http, .warn, "a msg", .{
            .cint = 5,
            .cfloat = 3.43,
            .int = @as(i16, -49),
            .float = @as(f32, 0.0003232),
            .bt = true,
            .bf = false,
            .nn = @as(?i32, 33),
            .n = @as(?i32, null),
            .lit = "over9000!",
            .slice = string,
            .err = error.Nope,
            .level = Level.warn,
        }, &aw.writer);

        try testing.expectEqual("$time=1739795092929 $scope=http $level=warn $msg=\"a msg\" " ++
            "cint=5 cfloat=3.43 int=-49 float=0.0003232 bt=true bf=false " ++
            "nn=33 n=null lit=over9000! slice=spice_must_flow " ++
            "err=Nope level=warn\n", aw.written());
    }
}

test "log: string escape" {
    opts.format = .logfmt;
    defer opts.format = .pretty;

    var aw = std.Io.Writer.Allocating.init(testing.allocator);
    defer aw.deinit();

    const prefix = "$time=1739795092929 $scope=app $level=error $msg=test ";
    {
        try logTo(.app, .err, "test", .{ .string = "hello world" }, &aw.writer);
        try testing.expectEqual(prefix ++ "string=\"hello world\"\n", aw.written());
    }

    {
        aw.clearRetainingCapacity();
        try logTo(.app, .err, "test", .{ .string = "\n \thi  \" \" " }, &aw.writer);
        try testing.expectEqual(prefix ++ "string=\"\\n \thi  \\\" \\\" \"\n", aw.written());
    }
}
