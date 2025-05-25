const std = @import("std");
const builtin = @import("builtin");
const build_config = @import("build_config");

const Thread = std.Thread;
const Allocator = std.mem.Allocator;

const LogLevel: Level = blk: {
    if (builtin.is_test) break :blk .err;
    break :blk @enumFromInt(@intFromEnum(build_config.log_level));
};

var pool: Pool = undefined;
pub fn init(allocator: Allocator, opts: Opts) !void {
    pool = try Pool.init(allocator, 3, opts);
}

pub fn deinit(allocator: Allocator) void {
    pool.deinit(allocator);
}

// synchronizes writes to the output
var out_lock: Thread.Mutex = .{};

// synchronizes access to last_log
var last_log_lock: Thread.Mutex = .{};

pub fn enabled(comptime scope: @Type(.enum_literal), comptime level: Level) bool {
    // TODO scope disabling
    _ = scope;
    return @intFromEnum(level) >= @intFromEnum(LogLevel);
}

pub const Level = enum {
    debug,
    info,
    warn,
    err,
    fatal,
};

const Opts = struct {
    format: Format = if (!builtin.is_test and builtin.mode == .Debug) .pretty else .logfmt,
};

pub const Format = enum {
    logfmt,
    pretty,
};

pub fn debug(comptime scope: @Type(.enum_literal), comptime msg: []const u8, data: anytype) void {
    log(scope, .debug, msg, data);
}

pub fn info(comptime scope: @Type(.enum_literal), comptime msg: []const u8, data: anytype) void {
    log(scope, .info, msg, data);
}

pub fn warn(comptime scope: @Type(.enum_literal), comptime msg: []const u8, data: anytype) void {
    log(scope, .warn, msg, data);
}

pub fn err(comptime scope: @Type(.enum_literal), comptime msg: []const u8, data: anytype) void {
    log(scope, .err, msg, data);
}

pub fn fatal(comptime scope: @Type(.enum_literal), comptime msg: []const u8, data: anytype) void {
    log(scope, .fatal, msg, data);
}

pub fn log(comptime scope: @Type(.enum_literal), comptime level: Level, comptime msg: []const u8, data: anytype) void {
    if (comptime enabled(scope, level) == false) {
        return;
    }
    const logger = pool.acquire();
    defer pool.release(logger);
    logger.log(scope, level, msg, data) catch |log_err| {
        std.debug.print("$time={d} $level=fatal $scope={s} $msg=\"log err\" err={s} log_msg=\"{s}\"", .{ timestamp(), @errorName(log_err), @tagName(scope), msg });
    };
}

// Generic so that we can test it against an ArrayList
fn LogT(comptime Out: type) type {
    return struct {
        out: Out,
        format: Format,
        allocator: Allocator,
        buffer: std.ArrayListUnmanaged(u8),

        const Self = @This();

        fn init(allocator: Allocator, opts: Opts) !Self {
            return initTo(allocator, opts, std.io.getStdOut());
        }

        // Used for tests
        fn initTo(allocator: Allocator, opts: Opts, out: Out) !Self {
            var buffer: std.ArrayListUnmanaged(u8) = .{};
            try buffer.ensureTotalCapacity(allocator, 2048);

            return .{
                .out = out,
                .buffer = buffer,
                .format = opts.format,
                .allocator = allocator,
            };
        }

        fn deinit(self: *Self) void {
            self.buffer.deinit(self.allocator);
        }

        fn log(self: *Self, comptime scope: @Type(.enum_literal), comptime level: Level, comptime msg: []const u8, data: anytype) !void {
            comptime {
                if (msg.len > 30) {
                    @compileError("log msg cannot be more than 30 characters: '" ++ msg ++ "'");
                }
                if (@tagName(scope).len > 15) {
                    @compileError("log scope cannot be more than 15 characters: '" ++ @tagName(scope) ++ "'");
                }
                for (msg) |b| {
                    switch (b) {
                        'A'...'Z', 'a'...'z', ' ', '0'...'9', '_', '-', '.', '{', '}' => {},
                        else => @compileError("log msg contains an invalid character '" ++ msg ++ "'"),
                    }
                }
            }

            defer self.buffer.clearRetainingCapacity();
            switch (self.format) {
                .logfmt => try self.logfmt(scope, level, msg, data),
                .pretty => try self.pretty(scope, level, msg, data),
            }

            out_lock.lock();
            defer out_lock.unlock();
            try self.out.writeAll(self.buffer.items);
        }

        fn logfmt(self: *Self, comptime scope: @Type(.enum_literal), comptime level: Level, comptime msg: []const u8, data: anytype) !void {
            const buffer = &self.buffer;
            const allocator = self.allocator;

            buffer.appendSliceAssumeCapacity("$time=");
            try std.fmt.format(buffer.writer(allocator), "{d}", .{timestamp()});

            buffer.appendSliceAssumeCapacity(" $scope=");
            buffer.appendSliceAssumeCapacity(@tagName(scope));

            const level_and_msg = comptime blk: {
                const l = if (level == .err) "error" else @tagName(level);
                // only wrap msg in quotes if it contains a space
                const lm = " $level=" ++ l ++ " $msg=";
                if (std.mem.indexOfScalar(u8, msg, ' ') == null) {
                    break :blk lm ++ msg;
                }
                break :blk lm ++ "\"" ++ msg ++ "\"";
            };
            buffer.appendSliceAssumeCapacity(level_and_msg);
            inline for (@typeInfo(@TypeOf(data)).@"struct".fields) |f| {
                const key = " " ++ f.name ++ "=";

                // + 5 covers null/true/false
                try buffer.ensureUnusedCapacity(allocator, key.len + 5);
                buffer.appendSliceAssumeCapacity(key);
                try writeValue(allocator, buffer, true, @field(data, f.name));
            }
            try buffer.append(allocator, '\n');
        }

        fn pretty(self: *Self, comptime scope: @Type(.enum_literal), comptime level: Level, comptime msg: []const u8, data: anytype) !void {
            const buffer = &self.buffer;
            const allocator = self.allocator;

            buffer.appendSliceAssumeCapacity(switch (level) {
                .debug => "\x1b[0;36mDEBUG\x1b[0m ",
                .info => "\x1b[0;32mINFO\x1b[0m  ",
                .warn => "\x1b[0;33mWARN\x1b[0m  ",
                .err => "\x1b[0;31mERROR\x1b[0m ",
                .fatal => "\x1b[0;35mFATAL\x1b[0m ",
            });

            const prefix = @tagName(scope) ++ " : " ++ msg;
            buffer.appendSliceAssumeCapacity(prefix);

            {
                // msg.len cannot be > 30, and @tagName(scope).len cannot be > 15
                // so this is safe
                const padding = 55 - prefix.len;
                for (0..padding / 2) |_| {
                    buffer.appendSliceAssumeCapacity(" .");
                }
                if (@mod(padding, 2) == 1) {
                    buffer.appendAssumeCapacity(' ');
                }
                try buffer.writer(allocator).print(" [+{d}ms]", .{elapsed()});
                buffer.appendAssumeCapacity('\n');
            }

            inline for (@typeInfo(@TypeOf(data)).@"struct".fields) |f| {
                const key = "      " ++ f.name ++ " = ";

                // + 5 covers null/true/false
                try buffer.ensureUnusedCapacity(allocator, key.len + 5);
                buffer.appendSliceAssumeCapacity(key);
                try writeValue(allocator, buffer, false, @field(data, f.name));
                try buffer.append(allocator, '\n');
            }
            try buffer.append(allocator, '\n');
        }
    };
}

const Pool = struct {
    loggers: []*Log,
    available: usize,
    mutex: Thread.Mutex,
    cond: Thread.Condition,

    const Self = @This();
    const Log = LogT(std.fs.File);

    pub fn init(allocator: Allocator, count: usize, opts: Opts) !Self {
        const loggers = try allocator.alloc(*Log, count);
        errdefer allocator.free(loggers);

        var started: usize = 0;
        errdefer for (0..started) |i| {
            loggers[i].deinit();
            allocator.destroy(loggers[i]);
        };

        const out = std.io.getStdOut();
        for (0..count) |i| {
            const logger = try allocator.create(Log);
            errdefer allocator.destroy(logger);
            logger.* = try Log.initTo(allocator, opts, out);
            loggers[i] = logger;
            started += 1;
        }

        return .{
            .cond = .{},
            .mutex = .{},
            .loggers = loggers,
            .available = count,
        };
    }

    pub fn deinit(self: *Self, allocator: Allocator) void {
        for (self.loggers) |logger| {
            logger.deinit();
            allocator.destroy(logger);
        }
        allocator.free(self.loggers);
    }

    pub fn acquire(self: *Self) *Log {
        self.mutex.lock();
        while (true) {
            const loggers = self.loggers;
            const available = self.available;
            if (available == 0) {
                self.cond.wait(&self.mutex);
                continue;
            }
            const index = available - 1;
            const logger = loggers[index];
            self.available = index;
            self.mutex.unlock();
            return logger;
        }
    }

    pub fn release(self: *Self, logger: *Log) void {
        self.mutex.lock();
        var loggers = self.loggers;
        const available = self.available;
        loggers[available] = logger;
        self.available = available + 1;
        self.mutex.unlock();
        self.cond.signal();
    }
};

pub fn writeValue(allocator: Allocator, buffer: *std.ArrayListUnmanaged(u8), escape_string: bool, value: anytype) !void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .optional => {
            if (value) |v| {
                return writeValue(allocator, buffer, escape_string, v);
            }
            // in _log, we reserved space for a value of up to 5 bytes.
            return buffer.appendSliceAssumeCapacity("null");
        },
        .comptime_int, .int, .comptime_float, .float => {
            return std.fmt.format(buffer.writer(allocator), "{d}", .{value});
        },
        .bool => {
            // in _log, we reserved space for a value of up to 5 bytes.
            return buffer.appendSliceAssumeCapacity(if (value) "true" else "false");
        },
        .error_set => return buffer.appendSlice(allocator, @errorName(value)),
        .@"enum" => return buffer.appendSlice(allocator, @tagName(value)),
        .array => return writeValue(allocator, buffer, escape_string, &value),
        .pointer => |ptr| switch (ptr.size) {
            .slice => switch (ptr.child) {
                u8 => return writeString(allocator, buffer, escape_string, value),
                else => {},
            },
            .one => switch (@typeInfo(ptr.child)) {
                .array => |arr| if (arr.child == u8) {
                    return writeString(allocator, buffer, escape_string, value);
                },
                else => {
                    var writer = buffer.writer(allocator);
                    return writer.print("{}", .{value});
                },
            },
            else => {},
        },
        .@"union" => {
            var writer = buffer.writer(allocator);
            return writer.print("{}", .{value});
        },
        .@"struct" => {
            var writer = buffer.writer(allocator);
            return writer.print("{}", .{value});
        },
        else => {},
    }
    @compileError("cannot log a: " ++ @typeName(T));
}

fn writeString(allocator: Allocator, buffer: *std.ArrayListUnmanaged(u8), escape: bool, value: []const u8) !void {
    if (escape == false) {
        return buffer.appendSlice(allocator, value);
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
        return std.base64.standard_no_pad.Encoder.encodeWriter(buffer.writer(allocator), value);
    }

    if (escape_count == 0) {
        if (space_count == 0) {
            return buffer.appendSlice(allocator, value);
        }
        try buffer.ensureUnusedCapacity(allocator, 2 + value.len);
        buffer.appendAssumeCapacity('"');
        buffer.appendSliceAssumeCapacity(value);
        buffer.appendAssumeCapacity('"');
        return;
    }

    // + 2 for the quotes
    // + escape_count because every character that needs escaping is + 1
    try buffer.ensureUnusedCapacity(allocator, 2 + value.len + escape_count);

    buffer.appendAssumeCapacity('"');

    var rest = value;
    while (rest.len > 0) {
        const pos = std.mem.indexOfAny(u8, rest, "\r\n\"") orelse {
            buffer.appendSliceAssumeCapacity(rest);
            break;
        };
        buffer.appendSliceAssumeCapacity(rest[0..pos]);
        buffer.appendAssumeCapacity('\\');
        switch (rest[pos]) {
            '"' => buffer.appendAssumeCapacity('"'),
            '\r' => buffer.appendAssumeCapacity('r'),
            '\n' => buffer.appendAssumeCapacity('n'),
            else => unreachable,
        }
        rest = rest[pos + 1 ..];
    }

    buffer.appendAssumeCapacity('"');
}

fn timestamp() i64 {
    if (comptime @import("builtin").is_test) {
        return 1739795092929;
    }
    return std.time.milliTimestamp();
}

var last_log: i64 = 0;
fn elapsed() i64 {
    const now = timestamp();

    last_log_lock.lock();
    const previous = last_log;
    last_log = now;
    last_log_lock.unlock();

    if (previous == 0) {
        return 0;
    }
    if (previous > now) {
        return 0;
    }
    return now - previous;
}

const testing = @import("testing.zig");
test "log: data" {
    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(testing.allocator);

    var logger = try TestLogger.initTo(testing.allocator, .{ .format = .logfmt }, buf.writer(testing.allocator));
    defer logger.deinit();

    {
        try logger.log(.t_scope, .err, "nope", .{});
        try testing.expectEqual("$time=1739795092929 $scope=t_scope $level=error $msg=nope\n", buf.items);
    }

    {
        buf.clearRetainingCapacity();
        const string = try testing.allocator.dupe(u8, "spice_must_flow");
        defer testing.allocator.free(string);

        try logger.log(.scope_2, .warn, "a msg", .{
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
        });

        try testing.expectEqual("$time=1739795092929 $scope=scope_2 $level=warn $msg=\"a msg\" " ++
            "cint=5 cfloat=3.43 int=-49 float=0.0003232 bt=true bf=false " ++
            "nn=33 n=null lit=over9000! slice=spice_must_flow " ++
            "err=Nope level=warn\n", buf.items);
    }
}

test "log: string escape" {
    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(testing.allocator);

    var logger = try TestLogger.initTo(testing.allocator, .{ .format = .logfmt }, buf.writer(testing.allocator));
    defer logger.deinit();

    const prefix = "$time=1739795092929 $scope=scope $level=error $msg=test ";
    {
        try logger.log(.scope, .err, "test", .{ .string = "hello world" });
        try testing.expectEqual(prefix ++ "string=\"hello world\"\n", buf.items);
    }

    {
        buf.clearRetainingCapacity();
        try logger.log(.scope, .err, "test", .{ .string = "\n \thi  \" \" " });
        try testing.expectEqual(prefix ++ "string=\"\\n \thi  \\\" \\\" \"\n", buf.items);
    }
}

const TestLogger = LogT(std.ArrayListUnmanaged(u8).Writer);
