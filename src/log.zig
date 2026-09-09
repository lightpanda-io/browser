// Copyright (C) 2023-2025 Lightpanda (Selecy SAS)
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
const lp = @import("lightpanda");

pub const Scope = enum {
    app,
    bidi,
    browser,
    bug,
    cache,
    cdp,
    console,
    disabled,
    dom,
    event,
    frame,
    http,
    js,
    mcp,
    note,
    not_implemented,
    scheduler,
    serve,
    storage,
    telemetry,
    unknown_prop,
    websocket,
    cors,
};

pub const num_scopes = @typeInfo(Scope).@"enum".fields.len;

/// A single `--log-filter-scopes` directive. `scope == null` targets every
/// scope (the `all` keyword). `enable` is true for `+X` (filter in), false
/// for `-X` / bare `X` (filter out).
pub const FilterRule = struct {
    scope: ?Scope,
    enable: bool,
};

/// Resolve an ordered list of filter directives into a per-scope enabled
/// array. Directives apply left-to-right, so `-all,+cdp` disables every
/// scope then re-enables `cdp`. Scopes untouched by any directive stay
/// enabled.
pub fn resolveFilters(rules: []const FilterRule) [num_scopes]bool {
    var scope_enabled = [_]bool{true} ** num_scopes;
    for (rules) |rule| {
        if (rule.scope) |scope| {
            scope_enabled[@intFromEnum(scope)] = rule.enable;
        } else {
            for (&scope_enabled) |*e| e.* = rule.enable;
        }
    }
    return scope_enabled;
}

const Opts = struct {
    format: Format = if (lp.IS_DEBUG) .pretty else .logfmt,
    level: Level = if (lp.IS_DEBUG) .info else .warn,
    // Per-scope enabled flags; a `false` entry suppresses that scope's logs.
    scope_enabled: [num_scopes]bool = [_]bool{true} ** num_scopes,
};

pub var opts = Opts{};

/// Optional sink for formatted log lines. The agent's REPL terminal sets
/// this so log output can be routed through `Spinner.emitAbove` instead
/// of trampling the spinner line on stderr.
pub var sink: ?*const fn (bytes: []const u8) void = null;

pub fn enabled(scope: Scope, level: Level) bool {
    if (@intFromEnum(level) < @intFromEnum(opts.level)) {
        return false;
    }

    if (opts.scope_enabled[@intFromEnum(scope)] == false) {
        return false;
    }

    return true;
}

// The number of log lines each scope is expected to emit for the current test.
// A line from a scope with a pending count is consumed instead of written; see
// testing.expectLog.
var expected_logs: [num_scopes]u16 = @splat(0);

// Registers one expected log line per entry in `scopes`.
pub fn expectLog(comptime scopes: []const Scope) void {
    comptime std.debug.assert(lp.IS_TEST);
    inline for (scopes) |scope| {
        expected_logs[@intFromEnum(scope)] += 1;
    }
}

// Called after each test. Returns the expectations that were never met.
pub fn resetTestState() [num_scopes]u16 {
    std.debug.assert(lp.IS_TEST);
    const unmet = expected_logs;
    expected_logs = @splat(0);
    opts.scope_enabled = @splat(true);
    return unmet;
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
    note,
};

pub const Format = enum {
    logfmt,
    pretty,
};

pub fn debug(scope: Scope, msg: []const u8, data: anytype) void {
    log(scope, .debug, msg, data);
}

pub fn info(scope: Scope, msg: []const u8, data: anytype) void {
    log(scope, .info, msg, data);
}

pub fn warn(scope: Scope, msg: []const u8, data: anytype) void {
    log(scope, .warn, msg, data);
}

pub fn err(scope: Scope, msg: []const u8, data: anytype) void {
    log(scope, .err, msg, data);
}

pub fn fatal(scope: Scope, msg: []const u8, data: anytype) void {
    log(scope, .fatal, msg, data);
}

pub fn note(scope: Scope, msg: []const u8, data: anytype) void {
    if (comptime lp.IS_TEST == false) {
        log(scope, .note, msg, data);
    }
}

var warned_disabled_worker = std.atomic.Value(bool).init(false);
pub fn warnDisabledWorker() void {
    if (warned_disabled_worker.swap(true, .monotonic) == false) {
        warn(.disabled, "workers disabled", .{ .hint = "enable via --load-resources worker" });
    }
}

var warned_disabled_iframe = std.atomic.Value(bool).init(false);
pub fn warnDisabledIFrame() void {
    if (warned_disabled_iframe.swap(true, .monotonic) == false) {
        warn(.disabled, "iframes disabled", .{ .hint = "enable via --load-resources iframe" });
    }
}

pub fn log(scope: Scope, level: Level, msg: []const u8, data: anytype) void {
    var kvs: [@typeInfo(@TypeOf(data)).@"struct".fields.len]KV = undefined;
    initKVs(data, &kvs);
    logKVs(scope, level, msg, &kvs);
}

inline fn initKVs(data: anytype, kvs: []KV) void {
    inline for (@typeInfo(@TypeOf(data)).@"struct".fields, 0..) |f, i| {
        const value = @field(data, f.name);
        kvs[i] = .{ .key = f.name, .value = Value.init(&value) };
    }
}

pub fn logKVs(scope: Scope, level: Level, msg: []const u8, kvs: []const KV) void {
    if (enabled(scope, level) == false) {
        return;
    }

    if (comptime lp.IS_TEST) {
        const expected = &expected_logs[@intFromEnum(scope)];
        if (expected.* > 0) {
            expected.* -= 1;
            return;
        }
    }

    if (sink) |s| {
        var buf: [4096]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        logToErased(scope, level, msg, kvs, &w) catch |log_err| {
            std.debug.print("$time={d} $level=fatal $scope={s} $msg=\"log err\" err={s} log_msg=\"{s}\"\n", .{ timestamp(.real), @tagName(scope), @errorName(log_err), msg });
            return;
        };
        s(w.buffered());
        return;
    }

    var buf: [4096]u8 = undefined;
    const stderr = std.debug.lockStderr(&buf);
    defer std.debug.unlockStderr();

    logToErased(scope, level, msg, kvs, &stderr.file_writer.interface) catch |log_err| {
        std.debug.print("$time={d} $level=fatal $scope={s} $msg=\"log err\" err={s} log_msg=\"{s}\"\n", .{ timestamp(.real), @tagName(scope), @errorName(log_err), msg });
    };
}

// Like `log`, but to an explicit writer and without the enabled/sink
// gating. Only used by tests.
fn logTo(scope: Scope, level: Level, msg: []const u8, data: anytype, out: *std.Io.Writer) !void {
    var kvs: [@typeInfo(@TypeOf(data)).@"struct".fields.len]KV = undefined;
    initKVs(data, &kvs);
    return logToErased(scope, level, msg, &kvs, out);
}

fn logToErased(scope: Scope, level: Level, msg: []const u8, kvs: []const KV, out: *std.Io.Writer) !void {
    if (lp.IS_DEBUG) {
        if (msg.len > 30) {
            std.debug.print("debug-only-panic: log msg cannot be more than 30 characters: {s}", .{msg});
            @panic("invalid log msg");
        }
        for (msg) |b| {
            switch (b) {
                'A'...'Z', 'a'...'z', ' ', '0'...'9', '_', '-', '.', '{', '}' => {},
                else => {
                    std.debug.print("debug-only-panic: log msg contains an invalid character: {s}", .{msg});
                    @panic("invalid log msg");
                },
            }
        }
    }
    switch (opts.format) {
        .logfmt => try logLogfmt(scope, level, msg, kvs, out),
        .pretty => try logPretty(scope, level, msg, kvs, out),
    }
    out.flush() catch return;
}

fn logLogfmt(scope: Scope, level: Level, msg: []const u8, kvs: []const KV, writer: *std.Io.Writer) !void {
    try logLogFmtPrefix(scope, level, msg, writer);
    for (kvs) |kv| {
        switch (kv.value) {
            // logFmt implementations write their own complete " key=value" pairs
            .log_fmt => |f| try f.logFmtFn(f.ptr, kv.key, writer),
            else => {
                try writer.print(" {s}=", .{kv.key});
                try writeErased(.logfmt, kv.value, writer);
            },
        }
    }
    try writer.writeByte('\n');
}

fn logLogFmtPrefix(scope: Scope, level: Level, msg: []const u8, writer: *std.Io.Writer) !void {
    try writer.writeAll("$time=");
    try writer.print("{d}", .{timestamp(.real)});

    try writer.writeAll(" $scope=");
    try writer.writeAll(@tagName(scope));

    try writer.writeAll(" $level=");
    try writer.writeAll(if (level == .err) "error" else @tagName(level));

    try writer.writeAll(" $msg=\"");
    try writer.writeAll(msg);
    try writer.writeByte('"');
}

fn logPretty(scope: Scope, level: Level, msg: []const u8, kvs: []const KV, writer: *std.Io.Writer) !void {
    try logPrettyPrefix(scope, level, msg, writer);
    for (kvs) |kv| {
        try writer.print("      {s} = ", .{kv.key});
        try writeErased(.pretty, kv.value, writer);
        try writer.writeByte('\n');
    }
    try writer.writeByte('\n');
}

fn logPrettyPrefix(scope: Scope, level: Level, msg: []const u8, writer: *std.Io.Writer) !void {
    if (scope == .console and level == .fatal) {
        try writer.writeAll("\x1b[0;104mWARN  ");
    } else {
        try writer.writeAll(switch (level) {
            .debug => "\x1b[0;36mDEBUG\x1b[0m ",
            .info => "\x1b[0;32mINFO\x1b[0m  ",
            .warn => "\x1b[0;33mWARN\x1b[0m  ",
            .err => "\x1b[0;31mERROR ",
            .fatal => "\x1b[0;35mFATAL ",
            .note => "\x1b[0;32mNOTE\x1b[0m  ",
        });
    }

    try writer.writeAll(@tagName(scope));
    try writer.writeAll(" : ");
    try writer.writeAll(msg);

    {
        // msg.len cannot be > 30, and @tagName(scope).len cannot be > 15
        // so this is safe
        const prefix_len = @tagName(scope).len + msg.len + 2;
        const padding = 55 - prefix_len;
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

pub const KV = struct {
    key: []const u8,
    value: Value,

    // `vp` is a pointer, as with Value.init. A string literal is already one;
    // for anything else pass `&value` and keep it alive until the log call.
    pub fn init(key: []const u8, vp: anytype) KV {
        return .{
            .key = key,
            .value = .init(vp),
        };
    }
};

/// A string the pretty format paints; logfmt writes it plainly.
pub const Colored = struct {
    code: []const u8,
    text: []const u8,

    pub fn logFmt(self: Colored, key: []const u8, writer: LogFormatWriter) !void {
        return writer.write(key, self.text);
    }

    pub fn format(self: Colored, writer: *std.Io.Writer) !void {
        try writer.writeAll(self.code);
        try writer.writeAll(self.text);
        return writer.writeAll("\x1b[0m");
    }
};

pub fn red(text: []const u8) Colored {
    return .{ .code = "\x1b[0;31m", .text = text };
}

pub fn green(text: []const u8) Colored {
    return .{ .code = "\x1b[0;32m", .text = text };
}

const Value = union(enum) {
    null,
    string: []const u8,
    int: i64,
    uint: u64,
    float32: f32,
    float64: f64,
    boolean: bool,
    formatter: Formatter,
    log_fmt: LogFmt,

    const Formatter = struct {
        ptr: *const anyopaque,
        writeFn: *const fn (ptr: *const anyopaque, writer: *std.Io.Writer) anyerror!void,
    };

    const LogFmt = struct {
        ptr: *const anyopaque,
        // writes one or more complete " key=value" pairs (logfmt only)
        logFmtFn: *const fn (ptr: *const anyopaque, key: []const u8, writer: *std.Io.Writer) anyerror!void,
        // value-only formatting, used by the pretty format
        writeFn: *const fn (ptr: *const anyopaque, writer: *std.Io.Writer) anyerror!void,
    };

    // The inline shim keeps a comptime-known `vp` comptime-known
    inline fn init(vp: anytype) Value {
        switch (@typeInfo(@typeInfo(@TypeOf(vp)).pointer.child)) {
            .comptime_int => {
                const value = vp.*;
                if (value >= 0 and value <= std.math.maxInt(u64)) {
                    return .{ .uint = value };
                }
                if (value < 0 and value >= std.math.minInt(i64)) {
                    return .{ .int = value };
                }
                return .{ .string = std.fmt.comptimePrint("{d}", .{value}) };
            },
            .comptime_float => return .{ .float64 = vp.* },
            else => return initRuntime(vp),
        }
    }

    fn initRuntime(vp: anytype) Value {
        const T = @TypeOf(vp.*);

        if (comptime std.meta.hasMethod(T, "logFmt")) {
            const Thunk = struct {
                fn logFmt(ptr: *const anyopaque, key: []const u8, writer: *std.Io.Writer) anyerror!void {
                    const value: *const T = @ptrCast(@alignCast(ptr));
                    return value.logFmt(key, LogFormatWriter{ .writer = writer });
                }
            };
            return .{ .log_fmt = .{
                .ptr = @ptrCast(vp),
                .logFmtFn = Thunk.logFmt,
                .writeFn = writeThunk(T, if (std.meta.hasMethod(T, "format")) "f" else ""),
            } };
        }

        if (comptime std.meta.hasMethod(T, "format")) {
            return formatterValue(vp, "f");
        }

        switch (@typeInfo(T)) {
            .optional => {
                if (vp.*) |_| {
                    return initRuntime(&vp.*.?);
                }
                return .null;
            },
            .int => |int_info| {
                if (comptime int_info.bits <= 64) {
                    return if (comptime int_info.signedness == .signed) .{ .int = vp.* } else .{ .uint = vp.* };
                }
                return formatterValue(vp, "d");
            },
            .float => |float_info| switch (comptime float_info.bits) {
                32 => return .{ .float32 = vp.* },
                64 => return .{ .float64 = vp.* },
                else => return formatterValue(vp, "d"),
            },
            .bool => return .{ .boolean = vp.* },
            .error_set => return .{ .string = @errorName(vp.*) },
            .@"enum" => return .{ .string = @tagName(vp.*) },
            .array => |arr| if (comptime arr.child == u8) {
                return .{ .string = vp };
            },
            .pointer => |ptr| switch (comptime ptr.size) {
                .slice => if (comptime ptr.child == u8) {
                    return .{ .string = vp.* };
                },
                .one => switch (@typeInfo(ptr.child)) {
                    .array => |arr| if (comptime arr.child == u8) {
                        return .{ .string = vp.* };
                    },
                    else => return formatterValue(vp, "f"),
                },
                else => {},
            },
            .@"union", .@"struct" => return formatterValue(vp, ""),
            else => {},
        }

        @compileError("cannot log a: " ++ @typeName(T));
    }
};

pub fn writeValue(comptime format: Format, value: anytype, writer: *std.Io.Writer) !void {
    return writeErased(format, Value.init(&value), writer);
}

fn formatterValue(vp: anytype, comptime spec: []const u8) Value {
    return .{ .formatter = .{
        .ptr = @ptrCast(vp),
        .writeFn = writeThunk(@TypeOf(vp.*), spec),
    } };
}

// The per-type fallback for values that Value cannot represent as a primitive:
fn writeThunk(comptime T: type, comptime spec: []const u8) *const fn (*const anyopaque, *std.Io.Writer) anyerror!void {
    return struct {
        fn write(ptr: *const anyopaque, writer: *std.Io.Writer) anyerror!void {
            const vp: *const T = @ptrCast(@alignCast(ptr));
            return writer.print("{" ++ spec ++ "}", .{vp.*});
        }
    }.write;
}

fn writeErased(format: Format, value: Value, writer: *std.Io.Writer) !void {
    switch (value) {
        .null => return writer.writeAll("null"),
        .string => |s| return writeString(format, s, writer),
        .int => |n| return writer.print("{d}", .{n}),
        .uint => |n| return writer.print("{d}", .{n}),
        .float32 => |n| return writer.print("{d}", .{n}),
        .float64 => |n| return writer.print("{d}", .{n}),
        .boolean => |b| return writer.writeAll(if (b) "true" else "false"),
        .formatter => |f| return f.writeFn(f.ptr, writer),
        .log_fmt => |f| return f.writeFn(f.ptr, writer),
    }
}

fn writeString(format: Format, value: []const u8, writer: *std.Io.Writer) !void {
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

pub const LogFormatWriter = struct {
    writer: *std.Io.Writer,

    pub fn write(self: LogFormatWriter, key: []const u8, value: anytype) !void {
        const writer = self.writer;
        try writer.print(" {s}=", .{key});
        try writeErased(.logfmt, Value.init(&value), writer);
    }
};

var first_log: std.atomic.Value(u64) = .init(0);
fn elapsed() struct { time: f64, unit: []const u8 } {
    const now = timestamp(.boot);

    var first = first_log.load(.monotonic);
    if (first == 0) {
        first = first_log.cmpxchgStrong(0, now, .monotonic, .monotonic) orelse now;
    }

    const e = now - first;
    if (e < 10_000) {
        return .{ .time = @floatFromInt(e), .unit = "ms" };
    }
    return .{ .time = @as(f64, @floatFromInt(e)) / @as(f64, 1000), .unit = "s" };
}

const datetime = @import("datetime.zig");
fn timestamp(comptime clock: std.Io.Clock) u64 {
    if (lp.IS_TEST) {
        return 1739795092929;
    }
    return datetime.milliTimestamp(clock);
}

const testing = @import("testing.zig");
test "log: colored" {
    opts.format = .logfmt;
    defer opts.format = .pretty;

    var aw = std.Io.Writer.Allocating.init(testing.allocator);
    defer aw.deinit();

    try logTo(.app, .err, "test", .{ .arg = red("--wait mss") }, &aw.writer);
    try testing.expectEqual("$time=1739795092929 $scope=app $level=error $msg=\"test\" arg=\"--wait mss\"\n", aw.written());

    aw.clearRetainingCapacity();
    try writeValue(.pretty, green("--wait-ms"), &aw.writer);
    try testing.expectEqual("\x1b[0;32m--wait-ms\x1b[0m", aw.written());
}

test "log: data" {
    opts.format = .logfmt;
    defer opts.format = .pretty;

    var aw = std.Io.Writer.Allocating.init(testing.allocator);
    defer aw.deinit();

    {
        try logTo(.browser, .err, "nope", .{}, &aw.writer);
        try testing.expectEqual("$time=1739795092929 $scope=browser $level=error $msg=\"nope\"\n", aw.written());
    }

    {
        aw.clearRetainingCapacity();
        const string = try testing.allocator.dupe(u8, "spice_must_flow");
        defer testing.allocator.free(string);

        try logTo(.frame, .warn, "a msg", .{
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

        try testing.expectEqual("$time=1739795092929 $scope=frame $level=warn $msg=\"a msg\" " ++
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

    const prefix = "$time=1739795092929 $scope=app $level=error $msg=\"test\" ";
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

test "log: resolveFilters" {
    // No directives: everything enabled.
    {
        const se = resolveFilters(&.{});
        try testing.expectEqual(true, se[@intFromEnum(Scope.cdp)]);
        try testing.expectEqual(true, se[@intFromEnum(Scope.http)]);
    }

    // Backward compatible: bare/`-` scope filters that scope out, rest stay in.
    {
        const se = resolveFilters(&.{
            .{ .scope = .cdp, .enable = false },
            .{ .scope = .http, .enable = false },
        });
        try testing.expectEqual(false, se[@intFromEnum(Scope.cdp)]);
        try testing.expectEqual(false, se[@intFromEnum(Scope.http)]);
        try testing.expectEqual(true, se[@intFromEnum(Scope.js)]);
    }

    // `-all,+cdp`: disable everything, then re-enable cdp.
    {
        const se = resolveFilters(&.{
            .{ .scope = null, .enable = false },
            .{ .scope = .cdp, .enable = true },
        });
        try testing.expectEqual(true, se[@intFromEnum(Scope.cdp)]);
        try testing.expectEqual(false, se[@intFromEnum(Scope.http)]);
        try testing.expectEqual(false, se[@intFromEnum(Scope.js)]);
    }

    // `+all,-cdp`: enable everything, then disable cdp. Order matters.
    {
        const se = resolveFilters(&.{
            .{ .scope = null, .enable = true },
            .{ .scope = .cdp, .enable = false },
        });
        try testing.expectEqual(false, se[@intFromEnum(Scope.cdp)]);
        try testing.expectEqual(true, se[@intFromEnum(Scope.http)]);
    }
}
