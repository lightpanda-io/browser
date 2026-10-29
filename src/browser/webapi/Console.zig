// Copyright (C) 2023-2025  Lightpanda (Selecy SAS)
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
const js = @import("../js/js.zig");

const Notification = @import("../../Notification.zig");

const logger = lp.log;

const Console = @This();

_timers: std.StringHashMapUnmanaged(u64) = .{},
_counts: std.StringHashMapUnmanaged(u64) = .{},

pub const init: Console = .{};

fn dispatchConsoleMessage(values: []const js.Value, console_type: Notification.ConsoleMessageType, exec: *js.Execution) void {
    const notification = exec.session.notification;
    const ts = lp.datetime.timestamp(.boot);
    const local = exec.js.local.?;

    notification.dispatch(.console_message, &.{
        .source = .javascript,
        .type = console_type,
        .values = values,
        .local = local,
        .timestamp = ts,
    });

    notification.dispatch(.runtime_console_message, &.{
        .source = .javascript,
        .type = console_type,
        .values = values,
        .local = local,
        .timestamp = ts,
    });
}

pub fn trace(args: js.Variadic(js.Value), exec: *js.Execution) !void {
    logger.debug(.js, "console.trace", .{
        .stack = exec.js.local.?.stackTrace() catch "???",
        .args = ValueWriter{ .values = args.values },
    });
    dispatchConsoleMessage(args.values, .trace, exec);
}

pub fn debug(args: js.Variadic(js.Value), exec: *js.Execution) void {
    logger.debug(.js, "console.debug", .{ValueWriter{ .values = args.values }});
    dispatchConsoleMessage(args.values, .debug, exec);
}

pub fn info(args: js.Variadic(js.Value), exec: *js.Execution) void {
    logger.info(.js, "console.info", .{ValueWriter{ .values = args.values }});
    dispatchConsoleMessage(args.values, .info, exec);
}

pub fn log(args: js.Variadic(js.Value), exec: *js.Execution) void {
    logger.info(.js, "console.log", .{ValueWriter{ .values = args.values }});
    dispatchConsoleMessage(args.values, .log, exec);
}

pub fn warn(args: js.Variadic(js.Value), exec: *js.Execution) void {
    logger.warn(.js, "console.warn", .{ValueWriter{ .values = args.values }});
    dispatchConsoleMessage(args.values, .warning, exec);
}

pub fn clear() void {}

pub fn assert(assertion_: ?js.Value, args: js.Variadic(js.Value), exec: *js.Execution) void {
    if (assertion_) |assertion| {
        if (assertion.toBool()) {
            return;
        }
    }
    logger.warn(.js, "console.assert", .{ValueWriter{ .values = args.values }});
    dispatchConsoleMessage(args.values, .warning, exec);
}

pub fn @"error"(args: js.Variadic(js.Value), exec: *js.Execution) void {
    logger.warn(.js, "console.error", .{ValueWriter{ .values = args.values, .stack = exec.js.local.?.stackTrace() catch |err| @errorName(err) orelse "???" }});
    dispatchConsoleMessage(args.values, .@"error", exec);
}

pub fn table(data: ?js.Value, columns: ?js.Value) void {
    logger.info(.js, "console.table", .{ .data = data, .columns = columns });
}

pub fn dir(item_: ?js.Value, _: ?js.Value, exec: *js.Execution) void {
    var buf: [1]js.Value = undefined;
    const values: []const js.Value = if (item_) |item| blk: {
        buf[0] = item;
        break :blk buf[0..1];
    } else buf[0..0];
    logger.info(.js, "console.dir", .{ValueWriter{ .values = values }});
    dispatchConsoleMessage(values, .dir, exec);
}

pub fn dirxml(args: js.Variadic(js.Value), exec: *js.Execution) void {
    logger.info(.js, "console.dirxml", .{ValueWriter{ .values = args.values }});
    dispatchConsoleMessage(args.values, .dirxml, exec);
}

pub fn count(label_: ?[]const u8, exec: *js.Execution) !void {
    const self = exec.console();
    const label = label_ orelse "default";
    const gop = try self._counts.getOrPut(exec.page_arena, label);

    var current: u64 = 0;
    if (gop.found_existing) {
        current = gop.value_ptr.*;
    } else {
        gop.key_ptr.* = try exec.page_arena.dupe(u8, label);
    }

    const c = current + 1;
    gop.value_ptr.* = c;

    logger.info(.js, "console.count", .{ .label = label, .count = c });
}

pub fn countReset(label_: ?[]const u8, exec: *js.Execution) !void {
    const self = exec.console();
    const label = label_ orelse "default";
    const kv = self._counts.fetchRemove(label) orelse {
        logger.info(.js, "console.countReset", .{ .label = label, .err = "invalid label" });
        return;
    };
    logger.info(.js, "console.countReset", .{ .label = label, .count = kv.value });
}

pub fn time(label_: ?[]const u8, exec: *js.Execution) !void {
    const self = exec.console();
    const label = label_ orelse "default";
    const gop = try self._timers.getOrPut(exec.page_arena, label);

    if (gop.found_existing) {
        logger.info(.js, "console.time", .{ .label = label, .err = "duplicate timer" });
        return;
    }
    gop.key_ptr.* = try exec.page_arena.dupe(u8, label);
    gop.value_ptr.* = lp.datetime.timestamp(.boot);
}

pub fn timeLog(label_: ?[]const u8, exec: *js.Execution) void {
    const self = exec.console();
    const elapsed = lp.datetime.timestamp(.boot);
    const label = label_ orelse "default";
    const start = self._timers.get(label) orelse {
        logger.info(.js, "console.timeLog", .{ .label = label, .err = "invalid timer" });
        return;
    };
    logger.info(.js, "console.timeLog", .{ .label = label, .elapsed = elapsed - start });
}

pub fn timeEnd(label_: ?[]const u8, exec: *js.Execution) void {
    const self = exec.console();
    const elapsed = lp.datetime.timestamp(.boot);
    const label = label_ orelse "default";
    const kv = self._timers.fetchRemove(label) orelse {
        logger.info(.js, "console.timeEnd", .{ .label = label, .err = "invalid timer" });
        return;
    };

    logger.info(.js, "console.timeEnd", .{ .label = label, .elapsed = elapsed - kv.value });
}

pub fn group(args: js.Variadic(js.Value)) void {
    logger.info(.js, "console.group", .{ValueWriter{ .values = args.values }});
}

pub fn groupCollapsed(args: js.Variadic(js.Value)) void {
    logger.info(.js, "console.groupCollapsed", .{ValueWriter{ .values = args.values }});
}

fn groupEnd() void {}
const ValueWriter = struct {
    values: []const js.Value,
    stack: ?[]const u8 = null,

    pub fn format(self: ValueWriter, writer: *std.Io.Writer) !void {
        for (self.valuesToLog(), 1..) |value, i| {
            try writer.print("\n  arg({d}): {f}", .{ i, value });
        }
        if (self.stack) |s| {
            try writer.print("\n stack: {s}", .{s});
        }
    }

    pub fn logFmt(self: ValueWriter, _: []const u8, writer: anytype) !void {
        var buf: [32]u8 = undefined;
        for (self.valuesToLog(), 0..) |value, i| {
            const name = try std.mem.print(&buf, "param.{d}", .{i});
            try writer.write(name, value);
        }
    }

    pub fn jsonStringify(self: ValueWriter, writer: *std.json.Stringify) !void {
        try writer.beginArray();
        for (self.valuesToLog()) |value| {
            try writer.write(value);
        }
        return writer.endArray();
    }

    fn valuesToLog(self: ValueWriter) []const js.Value {
        if (lp.build_config.wpt_extensions) {
            // A few WPT tests print HUGE arrays, it's at best, annoying when
            // running it locally
            return self.values[0..@min(self.values.len, 100)];
        }
        return self.values;
    }
};

pub const JsApi = struct {
    pub const bridge = js.Bridge(Console);

    pub const Meta = struct {
        pub const name = "Console";

        // Per the console spec, members are own properties of the namespace
        // object, so Object.entries(console) returns them.
        pub const namespace = true;

        pub const class_string = "console";

        pub var class_id: bridge.ClassId = undefined;
    };

    // Namespace members ignore their receiver (no signature check), so
    // detached calls like `console.log.apply(other, args)` work. Stateful
    // members resolve their instance from the global scope via exec.console().
    pub const trace = bridge.function(Console.trace, .{ .static = true });
    pub const debug = bridge.function(Console.debug, .{ .static = true });
    pub const info = bridge.function(Console.info, .{ .static = true });
    pub const log = bridge.function(Console.log, .{ .static = true });
    pub const warn = bridge.function(Console.warn, .{ .static = true });
    pub const clear = bridge.function(Console.clear, .{ .static = true, .noop = true });
    pub const assert = bridge.function(Console.assert, .{ .static = true });
    pub const @"error" = bridge.function(Console.@"error", .{ .static = true });
    pub const exception = bridge.function(Console.@"error", .{ .static = true });
    pub const table = bridge.function(Console.table, .{ .static = true });
    pub const dir = bridge.function(Console.dir, .{ .static = true });
    pub const dirxml = bridge.function(Console.dirxml, .{ .static = true });
    pub const count = bridge.function(Console.count, .{ .static = true });
    pub const countReset = bridge.function(Console.countReset, .{ .static = true });
    pub const time = bridge.function(Console.time, .{ .static = true });
    pub const timeLog = bridge.function(Console.timeLog, .{ .static = true });
    pub const timeEnd = bridge.function(Console.timeEnd, .{ .static = true });
    pub const group = bridge.function(Console.group, .{ .static = true });
    pub const groupCollapsed = bridge.function(Console.groupCollapsed, .{ .static = true });
    pub const groupEnd = bridge.function(Console.groupEnd, .{ .static = true });
};

const testing = @import("../../testing.zig");
test "WebApi: Console" {
    testing.expectLog(&.{ .js, .js, .js });
    try testing.htmlRunner("console", .{});
}

test "WebApi: Console escapes page values in the log" {
    const frame = try testing.createFrame();
    defer testing.test_session.closeAllPages();

    var ls: js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();

    const format = logger.opts.format;
    defer logger.opts.format = format;

    var aw = std.Io.Writer.Allocating.init(testing.allocator);
    defer aw.deinit();

    var values = [_]js.Value{
        try ls.local.exec("'one\\nx level=fatal'", null),
        try ls.local.exec("'\\x1b[31m'", null),
    };
    logger.opts.format = .logfmt;
    try logger.logTo(.js, .info, "console.log", .{ValueWriter{ .values = &values }}, &aw.writer);
    try testing.expect(std.mem.endsWith(u8, aw.written(), " param.0=\"one\\nx level=fatal\" param.1=G1szMW0\n"));

    aw.clearRetainingCapacity();
    logger.opts.format = .pretty;
    try logger.logTo(.js, .info, "console.log", .{ValueWriter{ .values = &values }}, &aw.writer);
    try testing.expect(std.mem.endsWith(u8, aw.written(), "\n  arg(1): one\nx level=fatal\n  arg(2): \\x1b[31m\n\n"));
}
