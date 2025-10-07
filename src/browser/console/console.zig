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
const log = @import("../../log.zig");

const js = @import("../js/js.zig");
const Page = @import("../page.zig").Page;

pub const Console = struct {
    // TODO: configurable writer
    timers: std.StringHashMapUnmanaged(u32) = .{},
    counts: std.StringHashMapUnmanaged(u32) = .{},

    pub fn _lp(values: []js.Object, page: *Page) !void {
        if (values.len == 0) {
            return;
        }
        log.fatal(.console, "lightpanda", .{ .args = try serializeValues(values, page) });
    }

    pub fn _log(values: []js.Object, page: *Page) !void {
        if (values.len == 0) {
            return;
        }
        log.info(.console, "info", .{ .args = try serializeValues(values, page) });
    }

    pub fn _info(values: []js.Object, page: *Page) !void {
        return _log(values, page);
    }

    pub fn _debug(values: []js.Object, page: *Page) !void {
        if (values.len == 0) {
            return;
        }
        log.debug(.console, "debug", .{ .args = try serializeValues(values, page) });
    }

    pub fn _warn(values: []js.Object, page: *Page) !void {
        if (values.len == 0) {
            return;
        }
        log.warn(.console, "warn", .{ .args = try serializeValues(values, page) });
    }

    pub fn _error(values: []js.Object, page: *Page) !void {
        if (values.len == 0) {
            return;
        }

        log.warn(.console, "error", .{
            .args = try serializeValues(values, page),
            .stack = page.stackTrace() catch "???",
        });
    }

    pub fn _trace(values: []js.Object, page: *Page) !void {
        if (values.len == 0) {
            return;
        }
        log.debug(.console, "debug", .{
            .stack = page.js.stackTrace() catch "???",
            .args = try serializeValues(values, page),
        });
    }

    pub fn _clear() void {}

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

    pub fn _assert(assertion: js.Object, values: []js.Object, page: *Page) !void {
        if (assertion.isTruthy()) {
            return;
        }
        var serialized_values: []const u8 = "";
        if (values.len > 0) {
            serialized_values = try serializeValues(values, page);
        }
        log.info(.console, "assertion failed", .{ .values = serialized_values });
    }

    fn serializeValues(values: []js.Object, page: *Page) ![]const u8 {
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
    return @import("../../datetime.zig").timestamp();
}
