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

const Allocator = std.mem.Allocator;
const Page = @import("../page.zig").Page;
const JsObject = @import("../env.zig").Env.JsObject;

const log = if (builtin.is_test) &test_capture else @import("../../log.zig");

pub const Console = struct {
    // TODO: configurable writer
    timers: std.StringHashMapUnmanaged(u32) = .{},
    counts: std.StringHashMapUnmanaged(u32) = .{},

    pub fn _lp(_: *const Console, values: []JsObject, page: *Page) !void {
        if (values.len == 0) {
            return;
        }
        log.fatal(.console, "lightpanda", .{ .args = try serializeValues(values, page) });
    }

    pub fn _log(_: *const Console, values: []JsObject, page: *Page) !void {
        if (values.len == 0) {
            return;
        }
        log.info(.console, "info", .{ .args = try serializeValues(values, page) });
    }

    pub fn _info(console: *const Console, values: []JsObject, page: *Page) !void {
        return console._log(values, page);
    }

    pub fn _debug(_: *const Console, values: []JsObject, page: *Page) !void {
        if (values.len == 0) {
            return;
        }
        log.debug(.console, "debug", .{ .args = try serializeValues(values, page) });
    }

    pub fn _warn(_: *const Console, values: []JsObject, page: *Page) !void {
        if (values.len == 0) {
            return;
        }
        log.warn(.console, "warn", .{ .args = try serializeValues(values, page) });
    }

    pub fn _error(_: *const Console, values: []JsObject, page: *Page) !void {
        if (values.len == 0) {
            return;
        }

        log.info(.console, "error", .{
            .args = try serializeValues(values, page),
            .stack = page.stackTrace() catch "???",
        });
    }

    pub fn _clear(_: *const Console) void {}

    pub fn _count(self: *Console, label_: ?[]const u8, page: *Page) !void {
        const label = label_ orelse "default";
        const gop = try self.counts.getOrPut(page.arena, label);

        var current: u32 = 0;
        if (gop.found_existing) {
            current = gop.value_ptr.*;
        } else {
            gop.key_ptr.* = try page.arena.dupe(u8, label);
        }

        const count = current + 1;
        gop.value_ptr.* = count;

        log.info(.console, "count", .{ .label = label, .count = count });
    }

    pub fn _countReset(self: *Console, label_: ?[]const u8) !void {
        const label = label_ orelse "default";
        const kv = self.counts.fetchRemove(label) orelse {
            log.info(.console, "invalid counter", .{ .label = label });
            return;
        };
        log.info(.console, "count reset", .{ .label = label, .count = kv.value });
    }

    pub fn _time(self: *Console, label_: ?[]const u8, page: *Page) !void {
        const label = label_ orelse "default";
        const gop = try self.timers.getOrPut(page.arena, label);

        if (gop.found_existing) {
            log.info(.console, "duplicate timer", .{ .label = label });
            return;
        }
        gop.key_ptr.* = try page.arena.dupe(u8, label);
        gop.value_ptr.* = timestamp();
    }

    pub fn _timeLog(self: *Console, label_: ?[]const u8) void {
        const elapsed = timestamp();
        const label = label_ orelse "default";
        const start = self.timers.get(label) orelse {
            log.info(.console, "invalid timer", .{ .label = label });
            return;
        };
        log.info(.console, "timer", .{ .label = label, .elapsed = elapsed - start });
    }

    pub fn _timeStop(self: *Console, label_: ?[]const u8) void {
        const elapsed = timestamp();
        const label = label_ orelse "default";
        const kv = self.timers.fetchRemove(label) orelse {
            log.info(.console, "invalid timer", .{ .label = label });
            return;
        };

        log.warn(.console, "timer stop", .{ .label = label, .elapsed = elapsed - kv.value });
    }

    pub fn _assert(_: *Console, assertion: JsObject, values: []JsObject, page: *Page) !void {
        if (assertion.isTruthy()) {
            return;
        }
        var serialized_values: []const u8 = "";
        if (values.len > 0) {
            serialized_values = try serializeValues(values, page);
        }
        log.info(.console, "assertion failed", .{ .values = serialized_values });
    }

    fn serializeValues(values: []JsObject, page: *Page) ![]const u8 {
        if (values.len == 0) {
            return "";
        }

        const arena = page.call_arena;
        const separator = log.separator();
        var arr: std.ArrayListUnmanaged(u8) = .{};

        for (values, 1..) |value, i| {
            try arr.appendSlice(arena, separator);
            try arr.writer(arena).print("{d}: ", .{i});
            const serialized = if (builtin.mode == .Debug) value.toDetailString() else value.toString();
            try arr.appendSlice(arena, try serialized);
        }
        return arr.items;
    }
};

fn timestamp() u32 {
    const ts = std.posix.clock_gettime(std.posix.CLOCK.MONOTONIC) catch unreachable;
    return @intCast(ts.sec);
}

var test_capture = TestCapture{};
const testing = @import("../../testing.zig");
test "Browser.Console" {
    defer testing.reset();

    var runner = try testing.jsRunner(testing.tracking_allocator, .{});
    defer runner.deinit();

    {
        try runner.testCases(&.{
            .{ "console.log('a')", "undefined" },
            .{ "console.warn('hello world', 23, true, new Object())", "undefined" },
        }, .{});

        const captured = test_capture.captured.items;
        try testing.expectEqual("[info] args= 1: a", captured[0]);
        try testing.expectEqual("[warn] args= 1: hello world 2: 23 3: true 4: #<Object>", captured[1]);
    }

    {
        test_capture.reset();
        try runner.testCases(&.{
            .{ "console.countReset()", "undefined" },
            .{ "console.count()", "undefined" },
            .{ "console.count('teg')", "undefined" },
            .{ "console.count('teg')", "undefined" },
            .{ "console.count('teg')", "undefined" },
            .{ "console.count()", "undefined" },
            .{ "console.countReset('teg')", "undefined" },
            .{ "console.countReset()", "undefined" },
            .{ "console.count()", "undefined" },
        }, .{});

        const captured = test_capture.captured.items;
        try testing.expectEqual("[invalid counter] label=default", captured[0]);
        try testing.expectEqual("[count] label=default count=1", captured[1]);
        try testing.expectEqual("[count] label=teg count=1", captured[2]);
        try testing.expectEqual("[count] label=teg count=2", captured[3]);
        try testing.expectEqual("[count] label=teg count=3", captured[4]);
        try testing.expectEqual("[count] label=default count=2", captured[5]);
        try testing.expectEqual("[count reset] label=teg count=3", captured[6]);
        try testing.expectEqual("[count reset] label=default count=2", captured[7]);
        try testing.expectEqual("[count] label=default count=1", captured[8]);
    }

    {
        test_capture.reset();
        try runner.testCases(&.{
            .{ "console.assert(true)", "undefined" },
            .{ "console.assert('a', 2, 3, 4)", "undefined" },
            .{ "console.assert('')", "undefined" },
            .{ "console.assert('', 'x', true)", "undefined" },
            .{ "console.assert(false, 'x')", "undefined" },
        }, .{});

        const captured = test_capture.captured.items;
        try testing.expectEqual("[assertion failed] values=", captured[0]);
        try testing.expectEqual("[assertion failed] values= 1: x 2: true", captured[1]);
        try testing.expectEqual("[assertion failed] values= 1: x", captured[2]);
    }
}
const TestCapture = struct {
    captured: std.ArrayListUnmanaged([]const u8) = .{},

    fn separator(_: *const TestCapture) []const u8 {
        return " ";
    }

    fn reset(self: *TestCapture) void {
        self.captured = .{};
    }

    fn debug(
        self: *TestCapture,
        comptime scope: @Type(.enum_literal),
        comptime msg: []const u8,
        args: anytype,
    ) void {
        self.capture(scope, msg, args);
    }

    fn info(
        self: *TestCapture,
        comptime scope: @Type(.enum_literal),
        comptime msg: []const u8,
        args: anytype,
    ) void {
        self.capture(scope, msg, args);
    }

    fn warn(
        self: *TestCapture,
        comptime scope: @Type(.enum_literal),
        comptime msg: []const u8,
        args: anytype,
    ) void {
        self.capture(scope, msg, args);
    }

    fn err(
        self: *TestCapture,
        comptime scope: @Type(.enum_literal),
        comptime msg: []const u8,
        args: anytype,
    ) void {
        self.capture(scope, msg, args);
    }

    fn fatal(
        self: *TestCapture,
        comptime scope: @Type(.enum_literal),
        comptime msg: []const u8,
        args: anytype,
    ) void {
        self.capture(scope, msg, args);
    }

    fn capture(
        self: *TestCapture,
        comptime scope: @Type(.enum_literal),
        comptime msg: []const u8,
        args: anytype,
    ) void {
        self._capture(scope, msg, args) catch unreachable;
    }

    fn _capture(
        self: *TestCapture,
        comptime scope: @Type(.enum_literal),
        comptime msg: []const u8,
        args: anytype,
    ) !void {
        std.debug.assert(scope == .console);

        const allocator = testing.arena_allocator;
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        try buf.appendSlice(allocator, "[" ++ msg ++ "] ");

        inline for (@typeInfo(@TypeOf(args)).@"struct".fields) |f| {
            try buf.appendSlice(allocator, f.name);
            try buf.append(allocator, '=');
            try @import("../../log.zig").writeValue(.pretty, @field(args, f.name), buf.writer(allocator));
            try buf.append(allocator, ' ');
        }
        self.captured.append(testing.arena_allocator, std.mem.trimRight(u8, buf.items, " ")) catch unreachable;
    }
};
