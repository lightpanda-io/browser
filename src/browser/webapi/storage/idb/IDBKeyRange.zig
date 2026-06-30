// Copyright (C) 2023-2026  Lightpanda (Selecy SAS)
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

const js = @import("../../../js/js.zig");

const Key = @import("Key.zig");
const Engine = @import("Engine.zig");

const Allocator = std.mem.Allocator;
const Execution = js.Execution;

const IDBKeyRange = @This();

_exec: *Execution,
// Encoded bound bytes (page-arena lived), null when that side is unbounded.
_lower: ?[]const u8,
_upper: ?[]const u8,
_lower_open: bool,
_upper_open: bool,

fn create(exec: *Execution, lower: ?[]const u8, upper: ?[]const u8, lower_open: bool, upper_open: bool) !*IDBKeyRange {
    return exec._factory.create(IDBKeyRange{
        ._exec = exec,
        ._lower = lower,
        ._upper = upper,
        ._lower_open = lower_open,
        ._upper_open = upper_open,
    });
}

pub fn only(value: js.Value, exec: *Execution) !*IDBKeyRange {
    const encoded = try Key.encodeValue(exec.arena, value);
    return create(exec, encoded, encoded, false, false);
}

pub fn lowerBound(value: js.Value, open: ?bool, exec: *Execution) !*IDBKeyRange {
    const encoded = try Key.encodeValue(exec.arena, value);
    return create(exec, encoded, null, open orelse false, false);
}

pub fn upperBound(value: js.Value, open: ?bool, exec: *Execution) !*IDBKeyRange {
    const encoded = try Key.encodeValue(exec.arena, value);
    return create(exec, null, encoded, false, open orelse false);
}

pub fn bound(lower: js.Value, upper: js.Value, lower_open: ?bool, upper_open: ?bool, exec: *Execution) !*IDBKeyRange {
    const lo = try Key.encodeValue(exec.arena, lower);
    const up = try Key.encodeValue(exec.arena, upper);
    if (std.mem.order(u8, lo, up) == .gt) {
        return error.DataError;
    }
    return create(exec, lo, up, lower_open orelse false, upper_open orelse false);
}

pub fn getLower(self: *const IDBKeyRange, exec: *Execution) !?js.Value {
    const encoded = self._lower orelse return null;
    return try Key.decodeToJs(exec.call_arena, exec.js.local.?, encoded);
}

pub fn getUpper(self: *const IDBKeyRange, exec: *Execution) !?js.Value {
    const encoded = self._upper orelse return null;
    return try Key.decodeToJs(exec.call_arena, exec.js.local.?, encoded);
}

pub fn getLowerOpen(self: *const IDBKeyRange) bool {
    return self._lower_open;
}

pub fn getUpperOpen(self: *const IDBKeyRange) bool {
    return self._upper_open;
}

pub fn includes(self: *const IDBKeyRange, key: js.Value, exec: *Execution) !bool {
    const encoded = try Key.encodeValue(exec.call_arena, key);
    return self.containsEncoded(encoded);
}

fn containsEncoded(self: *const IDBKeyRange, encoded: []const u8) bool {
    if (self._lower) |lo| {
        switch (std.mem.order(u8, encoded, lo)) {
            .lt => return false,
            .eq => if (self._lower_open) return false,
            .gt => {},
        }
    }
    if (self._upper) |up| {
        switch (std.mem.order(u8, encoded, up)) {
            .gt => return false,
            .eq => if (self._upper_open) return false,
            .lt => {},
        }
    }
    return true;
}

// SQL bounds for the engine's ranged queries.
pub fn toBounds(self: *const IDBKeyRange) Engine.Bounds {
    return .{
        .is_point = false,
        .lower = self._lower orelse Engine.Bounds.min_sentinel,
        .upper = self._upper orelse Engine.Bounds.max_sentinel,
        .lower_op = if (self._lower_open) "> " else ">= ",
        .upper_op = if (self._upper_open) "< " else "<= ",
    };
}

// Resolve a get/getAll/count/delete query argument — a key, an IDBKeyRange, or
// nothing (null/undefined) — into engine bounds. A bare key becomes a point
// range; the encoded key is allocated in `arena`.
pub fn resolveQuery(arena: Allocator, query: ?js.Value, exec: *Execution) !Engine.Bounds {
    const q = query orelse return Engine.Bounds.unbounded();
    if (q.isNullOrUndefined()) {
        return Engine.Bounds.unbounded();
    }
    if (exec.js.local.?.jsValueToZig(*IDBKeyRange, q)) |range| {
        return range.toBounds();
    } else |_| {}
    return Engine.Bounds.point(try Key.encodeValue(arena, q));
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(IDBKeyRange);

    pub const Meta = struct {
        pub const name = "IDBKeyRange";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const only = bridge.function(IDBKeyRange.only, .{ .static = true });
    pub const lowerBound = bridge.function(IDBKeyRange.lowerBound, .{
        .static = true,
    });
    pub const upperBound = bridge.function(IDBKeyRange.upperBound, .{
        .static = true,
    });
    pub const bound = bridge.function(IDBKeyRange.bound, .{
        .static = true,
    });

    pub const lower = bridge.accessor(IDBKeyRange.getLower, null, .{ .null_as_undefined = true });
    pub const upper = bridge.accessor(IDBKeyRange.getUpper, null, .{ .null_as_undefined = true });
    pub const lowerOpen = bridge.accessor(IDBKeyRange.getLowerOpen, null, .{});
    pub const upperOpen = bridge.accessor(IDBKeyRange.getUpperOpen, null, .{});
    pub const includes = bridge.function(IDBKeyRange.includes, .{});
};
