const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;

// synchronizes writes to the output
// in debug mode, also synchronizes the timestamp counter for a more human-
// readable time display
var mutex: std.Thread.Mutex = .{};

const LogLevel: Log.Level = blk: {
    const root = @import("root");
    break :blk if (@hasDecl(root, "LogLevel")) root.LogLevel else .info;
};

pub const Log = LogT(std.fs.File, builtin.mode == .Debug);

// Generic so that we can test it against an ArrayList
fn LogT(comptime Out: type, comptime enhanced_readability: bool) type {
    return struct {
        out: Out,
        inject: ?[]const u8,
        allocator: Allocator,
        buffer: std.ArrayListUnmanaged(u8),

        const Self = @This();

        pub const Level = enum {
            debug,
            info,
            warn,
            @"error",
            fatal,
        };

        //
        pub fn init(allocator: Allocator) !Self {
            return initTo(allocator, std.io.getStdErr());
        }

        // Used for tests
        fn initTo(allocator: Allocator, out: Out) !Self {
            var buffer: std.ArrayListUnmanaged(u8) = .{};
            try buffer.ensureTotalCapacity(allocator, 2048);

            return .{
                .out = out,
                .inject = null,
                .buffer = buffer,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.buffer.deinit(self.allocator);
        }

        pub fn enabled(comptime level: Level) bool {
            return @intFromEnum(level) >= @intFromEnum(LogLevel);
        }

        pub fn debug(self: *Self, comptime msg: []const u8, data: anytype) void {
            self.log(.debug, msg, data);
        }

        pub fn info(self: *Self, comptime msg: []const u8, data: anytype) void {
            self.log(.info, msg, data);
        }

        pub fn warn(self: *Self, comptime msg: []const u8, data: anytype) void {
            self.log(.warn, msg, data);
        }

        pub fn err(self: *Self, comptime msg: []const u8, data: anytype) void {
            self.log(.@"error", msg, data);
        }

        pub fn fatal(self: *Self, comptime msg: []const u8, data: anytype) void {
            self.log(.fatal, msg, data);
        }

        fn log(self: *Self, comptime level: Level, comptime msg: []const u8, data: anytype) void {
            if (comptime enabled(level) == false) {
                return;
            }
            defer self.buffer.clearRetainingCapacity();
            self._log(level, msg, data) catch |e| {
                std.debug.print("log error: {}  ({s} - {s})\n", .{ e, @tagName(level), msg });
            };
        }

        fn _log(self: *Self, comptime level: Level, comptime msg: []const u8, data: anytype) !void {
            const allocator = self.allocator;

            // We use *AssumeCapacity here because we expect buffer to have
            // a reasonable default size. We expect time + level + msg + inject
            // to fit in the initial buffer;
            var buffer = &self.buffer;

            comptime {
                if (msg.len > 512) {
                    @compileError("log msg cannot be greater than 512 characters: '" ++ msg ++ "'");
                }
                for (msg) |b| {
                    switch (b) {
                        'A'...'Z', 'a'...'z', ' ', '0'...'9', '_', '-', '.', '{', '}' => {},
                        else => @compileError("log msg contains an invalid character '" ++ msg ++ "'"),
                    }
                }
            }

            std.debug.assert(buffer.capacity >= 1024);

            if (comptime enhanced_readability) {
                // used when developing, and we prefer readability over having
                // the output in logfmt

                // write the level this way so that the column lines up.
                switch (level) {
                    .info => buffer.appendSliceAssumeCapacity("info  | "),
                    .debug => buffer.appendSliceAssumeCapacity("debug | "),
                    .warn => buffer.appendSliceAssumeCapacity("\x1b[33m warn\x1b[0m  | "),
                    .@"error" => buffer.appendSliceAssumeCapacity("\x1b[31m error\x1b[0m | "),
                    .fatal => buffer.appendSliceAssumeCapacity("\x1b[41m fatal\x1b[0m | "),
                }

                buffer.appendSliceAssumeCapacity(msg ++ " | ");
                const since_last_log = msSinceLastLog();

                if (since_last_log > 1000) {
                    buffer.appendSliceAssumeCapacity("\x1b[35m");
                }
                try std.fmt.format(buffer.writer(allocator), "{d}\x1b[0m |", .{since_last_log});
            } else {
                buffer.appendSliceAssumeCapacity("_time=");
                try std.fmt.format(buffer.writer(allocator), "{d}", .{getTime()});

                const level_and_msg = comptime blk: {
                    // only wrap msg in quotes if it contains a space
                    const lm = " _level=" ++ @tagName(level) ++ " _msg=";
                    if (std.mem.indexOfScalar(u8, msg, ' ') == null) {
                        break :blk lm ++ msg;
                    }
                    break :blk lm ++ "\"" ++ msg ++ "\"";
                };
                buffer.appendSliceAssumeCapacity(level_and_msg);
            }

            if (self.inject) |inject| {
                buffer.appendAssumeCapacity(' ');
                buffer.appendSliceAssumeCapacity(inject);
            }

            inline for (@typeInfo(@TypeOf(data)).Struct.fields) |f| {
                // + 2 for the leading space and the equal sign
                // + 5 to save space for null/false/true common values
                const key_len = f.name.len + 7;
                try buffer.ensureUnusedCapacity(allocator, key_len);
                buffer.appendAssumeCapacity(' ');
                buffer.appendSliceAssumeCapacity(f.name);
                buffer.appendAssumeCapacity('=');
                try writeValue(allocator, buffer, @field(data, f.name));
            }

            if (comptime enhanced_readability) {
                // reset any color
                try buffer.appendSlice(allocator, "\x1b[0m");
            }

            try buffer.append(allocator, '\n');

            mutex.lock();
            defer mutex.unlock();
            try self.out.writeAll(self.buffer.items);
        }
    };
}

fn writeValue(allocator: Allocator, buffer: *std.ArrayListUnmanaged(u8), value: anytype) !void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .Optional => {
            if (value) |v| {
                return writeValue(allocator, buffer, v);
            }
            // in _log, we reserved space for a value of up to 5 bytes.
            return buffer.appendSliceAssumeCapacity("null");
        },
        .ComptimeInt, .Int, .ComptimeFloat, .Float => {
            return std.fmt.format(buffer.writer(allocator), "{d}", .{value});
        },
        .Bool => {
            // in _log, we reserved space for a value of up to 5 bytes.
            return buffer.appendSliceAssumeCapacity(if (value) "true" else "false");
        },
        .ErrorSet => return buffer.appendSlice(allocator, @errorName(value)),
        .Enum => return buffer.appendSlice(allocator, @tagName(value)),
        .Array => return writeValue(allocator, buffer, &value),
        .Pointer => |ptr| switch (ptr.size) {
            .Slice => switch (ptr.child) {
                u8 => return writeString(allocator, buffer, value),
                else => {},
            },
            .One => switch (@typeInfo(ptr.child)) {
                .Array => |arr| if (arr.child == u8) {
                    return writeString(allocator, buffer, value);
                },
                else => return false,
            },
            else => {},
        },
        else => {},
    }
    @compileError("cannot log a: " ++ @typeName(T));
}

fn writeString(allocator: Allocator, buffer: *std.ArrayListUnmanaged(u8), value: []const u8) !void {
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
        // TODO: use a different encoding if the ratio of binary data / printable
        // is low
        // TODO: Zig 0.14 adds an encodeWriter
        return buffer.appendSlice(allocator, "\"<binary data> (will be supported once we move to Zig 0.14\"");
        // return std.base64.standard_no_pad.Encoder.encodeWriter(buffer.writer(allocator), value);
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

fn getTime() i64 {
    if (comptime @import("builtin").is_test) {
        return 1739795092929;
    }
    return std.time.milliTimestamp();
}

var last_log_for_debug: i64 = 0;
fn msSinceLastLog() i64 {
    if (comptime builtin.mode != .Debug) {
        @compileError("Log's enhanced_readability is not safe to use in non-Debug mode");
    }
    const now = getTime();

    mutex.lock();
    defer mutex.unlock();
    defer last_log_for_debug = now;
    if (last_log_for_debug == 0) {
        return 0;
    }
    return now - last_log_for_debug;
}

const testing = std.testing;
const TestLogger = LogT(std.ArrayListUnmanaged(u8).Writer, false);

test "log: data" {
    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(testing.allocator);

    var log = try TestLogger.initTo(testing.allocator, buf.writer(testing.allocator));
    defer log.deinit();

    {
        log.err("nope", .{});
        try testing.expectEqualStrings("_time=1739795092929 _level=error _msg=nope\n", buf.items);
    }

    {
        buf.clearRetainingCapacity();
        const string = try testing.allocator.dupe(u8, "spice_must_flow");
        defer testing.allocator.free(string);

        log.warn("a msg", .{
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
            .level = Log.Level.warn,
        });

        try testing.expectEqualStrings("_time=1739795092929 _level=warn _msg=\"a msg\" " ++
            "cint=5 cfloat=3.43 int=-49 float=0.0003232 bt=true bf=false " ++
            "nn=33 n=null lit=over9000! slice=spice_must_flow " ++
            "err=Nope level=warn\n", buf.items);
    }
}

test "log: string escape" {
    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(testing.allocator);

    var log = try TestLogger.initTo(testing.allocator, buf.writer(testing.allocator));
    defer log.deinit();

    const prefix = "_time=1739795092929 _level=error _msg=test ";
    {
        log.err("test", .{ .string = "hello world" });
        try testing.expectEqualStrings(prefix ++ "string=\"hello world\"\n", buf.items);
    }

    {
        buf.clearRetainingCapacity();
        log.err("test", .{ .string = "\n \thi  \" \" " });
        try testing.expectEqualStrings(prefix ++ "string=\"\\n \thi  \\\" \\\" \"\n", buf.items);
    }

    // TODO: Zig 0.14
    // {
    //     log.err("test", .{.string = [_]u8{0, 244, 55, 77}});
    //     try testing.expectEqualStrings(prefix ++ "string=\"\\n \\thi  \\\" \\\" \"\n", buf.items);
    // }
}

test "log: with inject" {
    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(testing.allocator);

    var log = try TestLogger.initTo(testing.allocator, buf.writer(testing.allocator));
    defer log.deinit();

    log.inject = "conn_id=339494";
    log.fatal("hit", .{ .over = 9000 });
    try testing.expectEqualStrings("_time=1739795092929 _level=fatal _msg=hit conn_id=339494 over=9000\n", buf.items);
}
