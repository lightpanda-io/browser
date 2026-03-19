// Copyright (C) 2023-2026  Lightpanda (Selecy SAS)
//
// Francis Bouvier <francis@lightpanda.io>
// Pierre Tachoire <pierre@lightpanda.io>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or (at your
// option) any later version.
//
// This program is distributed in the hope that it will be useful, but WITHOUT
// ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
// FITNESS FOR A PARTICULAR PURPOSE. See the GNU Affero General Public License
// for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.

const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Input = struct {
    events: std.ArrayListUnmanaged(Event) = .{},

    pub const Button = enum {
        left,
        middle,
        right,
    };

    pub const KeyEvent = struct {
        code: u32,
        pressed: bool,
        modifiers: u8 = 0,
    };

    pub const PointerEvent = struct {
        x: i32,
        y: i32,
        button: Button = .left,
        pressed: bool,
        modifiers: u8 = 0,
    };

    pub const MoveEvent = struct {
        x: i32,
        y: i32,
        modifiers: u8 = 0,
    };

    pub const WheelEvent = struct {
        delta_x: i32 = 0,
        delta_y: i32 = 0,
        modifiers: u8 = 0,
    };

    pub const Event = union(enum) {
        key: KeyEvent,
        pointer: PointerEvent,
        move: MoveEvent,
        wheel: WheelEvent,
    };

    pub fn deinit(self: *Input, allocator: Allocator) void {
        self.events.deinit(allocator);
        self.* = undefined;
    }

    pub fn push(self: *Input, allocator: Allocator, event: Event) !void {
        try self.events.append(allocator, event);
    }

    pub fn pushKey(self: *Input, allocator: Allocator, code: u32, pressed: bool, modifiers: u8) !void {
        try self.push(allocator, .{ .key = .{ .code = code, .pressed = pressed, .modifiers = modifiers } });
    }

    pub fn pushPointer(
        self: *Input,
        allocator: Allocator,
        x: i32,
        y: i32,
        button: Button,
        pressed: bool,
        modifiers: u8,
    ) !void {
        try self.push(allocator, .{ .pointer = .{ .x = x, .y = y, .button = button, .pressed = pressed, .modifiers = modifiers } });
    }

    pub fn pushMove(self: *Input, allocator: Allocator, x: i32, y: i32, modifiers: u8) !void {
        try self.push(allocator, .{ .move = .{ .x = x, .y = y, .modifiers = modifiers } });
    }

    pub fn pushWheel(self: *Input, allocator: Allocator, delta_x: i32, delta_y: i32, modifiers: u8) !void {
        try self.push(allocator, .{ .wheel = .{ .delta_x = delta_x, .delta_y = delta_y, .modifiers = modifiers } });
    }

    pub fn pop(self: *Input) ?Event {
        if (self.events.items.len == 0) {
            return null;
        }
        return self.events.orderedRemove(0);
    }

    pub fn clear(self: *Input) void {
        self.events.clearRetainingCapacity();
    }

    pub fn isEmpty(self: *const Input) bool {
        return self.events.items.len == 0;
    }
};

test "input queue preserves event order" {
    var input = Input{};
    defer input.deinit(std.testing.allocator);

    try input.pushKey(std.testing.allocator, 65, true, 0);
    try input.pushMove(std.testing.allocator, 9, 11, 0);
    try input.pushPointer(std.testing.allocator, 10, 12, .left, true, 0);
    try input.pushWheel(std.testing.allocator, 0, -1, 0);

    try std.testing.expect(!input.isEmpty());
    try std.testing.expectEqual(@as(u32, 65), input.pop().?.key.code);
    try std.testing.expectEqual(@as(i32, 9), input.pop().?.move.x);
    try std.testing.expectEqual(@as(i32, 10), input.pop().?.pointer.x);
    try std.testing.expectEqual(@as(i32, -1), input.pop().?.wheel.delta_y);
    try std.testing.expect(input.isEmpty());
}
