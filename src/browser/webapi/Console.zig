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
const js = @import("../js/js.zig");

const Page = @import("../Page.zig");
const logger = @import("../../log.zig");

const Console = @This();

_timers: std.StringHashMapUnmanaged(u64) = .{},
_counts: std.StringHashMapUnmanaged(u64) = .{},

pub const init: Console = .{};

pub fn trace(_: *const Console, values: []js.Value, page: *Page) !void {
    logger.debug(.js, "console.trace", .{
        .stack = page.js.local.?.stackTrace() catch "???",
        .args = ValueWriter{ .page = page, .values = values },
    });
}

pub fn debug(_: *const Console, values: []js.Value, page: *Page) void {
    logger.debug(.js, "console.debug", .{ValueWriter{ .page = page, .values = values }});
}

pub fn info(_: *const Console, values: []js.Value, page: *Page) void {
    logger.info(.js, "console.info", .{ValueWriter{ .page = page, .values = values }});
}

pub fn log(_: *const Console, values: []js.Value, page: *Page) void {
    logger.info(.js, "console.log", .{ValueWriter{ .page = page, .values = values }});
}

pub fn warn(_: *const Console, values: []js.Value, page: *Page) void {
    logger.warn(.js, "console.warn", .{ValueWriter{ .page = page, .values = values }});
}

pub fn clear(_: *const Console) void {}

pub fn assert(_: *const Console, assertion: js.Value, values: []js.Value, page: *Page) void {
    if (assertion.toBool()) {
        return;
    }
    logger.warn(.js, "console.assert", .{ValueWriter{ .page = page, .values = values }});
}

pub fn @"error"(_: *const Console, values: []js.Value, page: *Page) void {
    logger.warn(.js, "console.error", .{ValueWriter{ .page = page, .values = values, .include_stack = true }});
}

pub fn count(self: *Console, label_: ?[]const u8, page: *Page) !void {
    const label = label_ orelse "default";
    const gop = try self._counts.getOrPut(page.arena, label);

    var current: u64 = 0;
    if (gop.found_existing) {
        current = gop.value_ptr.*;
    } else {
        gop.key_ptr.* = try page.dupeString(label);
    }

    const c = current + 1;
    gop.value_ptr.* = c;

    logger.info(.js, "console.count", .{ .label = label, .count = c });
}

pub fn countReset(self: *Console, label_: ?[]const u8) !void {
    const label = label_ orelse "default";
    const kv = self._counts.fetchRemove(label) orelse {
        logger.info(.js, "console.countReset", .{ .label = label, .err = "invalid label" });
        return;
    };
    logger.info(.js, "console.countReset", .{ .label = label, .count = kv.value });
}

pub fn time(self: *Console, label_: ?[]const u8, page: *Page) !void {
    const label = label_ orelse "default";
    const gop = try self._timers.getOrPut(page.arena, label);

    if (gop.found_existing) {
        logger.info(.js, "console.time", .{ .label = label, .err = "duplicate timer" });
        return;
    }
    gop.key_ptr.* = try page.dupeString(label);
    gop.value_ptr.* = timestamp();
}

pub fn timeLog(self: *Console, label_: ?[]const u8) void {
    const elapsed = timestamp();
    const label = label_ orelse "default";
    const start = self._timers.get(label) orelse {
        logger.info(.js, "console.timeLog", .{ .label = label, .err = "invalid timer" });
        return;
    };
    logger.info(.js, "console.timeLog", .{ .label = label, .elapsed = elapsed - start });
}

pub fn timeEnd(self: *Console, label_: ?[]const u8) void {
    const elapsed = timestamp();
    const label = label_ orelse "default";
    const kv = self._timers.fetchRemove(label) orelse {
        logger.info(.js, "console.timeEnd", .{ .label = label, .err = "invalid timer" });
        return;
    };

    logger.info(.js, "console.timeEnd", .{ .label = label, .elapsed = elapsed - kv.value });
}

fn timestamp() u64 {
    return @import("../../datetime.zig").timestamp(.monotonic);
}

const ValueWriter = struct {
    page: *Page,
    values: []js.Value,
    include_stack: bool = false,

    pub fn format(self: ValueWriter, writer: *std.io.Writer) !void {
        for (self.values, 1..) |value, i| {
            try writer.print("\n  arg({d}): {f}", .{ i, value });
        }
        if (self.include_stack) {
            try writer.print("\n stack: {s}", .{self.page.js.local.?.stackTrace() catch |err| @errorName(err) orelse "???"});
        }
    }

    pub fn logFmt(self: ValueWriter, _: []const u8, writer: anytype) !void {
        var buf: [32]u8 = undefined;
        for (self.values, 0..) |value, i| {
            const name = try std.fmt.bufPrint(&buf, "param.{d}", .{i});
            try writer.write(name, try value.toString(.{}));
        }
    }

    pub fn jsonStringify(self: ValueWriter, writer: *std.json.Stringify) !void {
        try writer.beginArray();
        for (self.values) |value| {
            try writer.write(value);
        }
        return writer.endArray();
    }
};

pub const JsApi = struct {
    pub const bridge = js.Bridge(Console);

    pub const Meta = struct {
        pub const name = "Console";

        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
        pub const empty_with_no_proto = true;
    };

    pub const trace = bridge.function(Console.trace, .{});
    pub const debug = bridge.function(Console.debug, .{});
    pub const info = bridge.function(Console.info, .{});
    pub const log = bridge.function(Console.log, .{});
    pub const warn = bridge.function(Console.warn, .{});
    pub const clear = bridge.function(Console.clear, .{});
    pub const assert = bridge.function(Console.assert, .{});
    pub const @"error" = bridge.function(Console.@"error", .{});
    pub const exception = bridge.function(Console.@"error", .{});
    pub const count = bridge.function(Console.count, .{});
    pub const countReset = bridge.function(Console.countReset, .{});
    pub const time = bridge.function(Console.time, .{});
    pub const timeLog = bridge.function(Console.timeLog, .{});
    pub const timeEnd = bridge.function(Console.timeEnd, .{});
};
