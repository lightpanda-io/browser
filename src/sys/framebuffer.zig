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

pub const Framebuffer = struct {
    width: u32 = 0,
    height: u32 = 0,
    pixels: []u32 = &.{},

    pub fn empty() Framebuffer {
        return .{};
    }

    pub fn init(allocator: Allocator, width: u32, height: u32) !Framebuffer {
        const count = @as(usize, width) * @as(usize, height);
        const pixels = try allocator.alloc(u32, count);
        return .{
            .width = width,
            .height = height,
            .pixels = pixels,
        };
    }

    pub fn deinit(self: *Framebuffer, allocator: Allocator) void {
        if (self.pixels.len > 0) {
            allocator.free(self.pixels);
        }
        self.* = .{};
    }

    pub fn resize(self: *Framebuffer, allocator: Allocator, width: u32, height: u32) !void {
        const next = try Framebuffer.init(allocator, width, height);
        self.deinit(allocator);
        self.* = next;
    }

    pub fn fill(self: *Framebuffer, color: u32) void {
        for (self.pixels) |*px| {
            px.* = color;
        }
    }

    pub fn fillRect(self: *Framebuffer, x: i32, y: i32, width: i32, height: i32, color: u32) void {
        if (width <= 0 or height <= 0 or self.width == 0 or self.height == 0) {
            return;
        }

        const start_x = @as(i32, @intCast(@max(x, 0)));
        const start_y = @as(i32, @intCast(@max(y, 0)));
        const end_x = @as(i32, @intCast(@min(@as(i64, x) + @as(i64, width), @as(i64, self.width))));
        const end_y = @as(i32, @intCast(@min(@as(i64, y) + @as(i64, height), @as(i64, self.height))));
        if (start_x >= end_x or start_y >= end_y) {
            return;
        }

        var py = start_y;
        while (py < end_y) : (py += 1) {
            var px = start_x;
            while (px < end_x) : (px += 1) {
                self.setPixel(@as(u32, @intCast(px)), @as(u32, @intCast(py)), color);
            }
        }
    }

    pub fn setPixel(self: *Framebuffer, x: u32, y: u32, color: u32) void {
        if (x >= self.width or y >= self.height) {
            return;
        }
        self.pixels[@as(usize, y) * @as(usize, self.width) + @as(usize, x)] = color;
    }

    pub fn pixel(self: *const Framebuffer, x: u32, y: u32) ?u32 {
        if (x >= self.width or y >= self.height) {
            return null;
        }
        return self.pixels[@as(usize, y) * @as(usize, self.width) + @as(usize, x)];
    }
};

test "framebuffer fills and reads pixels" {
    var fb = try Framebuffer.init(std.testing.allocator, 2, 2);
    defer fb.deinit(std.testing.allocator);

    fb.fill(0x11223344);
    try std.testing.expectEqual(@as(u32, 0x11223344), fb.pixel(0, 0).?);
    fb.setPixel(1, 1, 0x55667788);
    try std.testing.expectEqual(@as(u32, 0x55667788), fb.pixel(1, 1).?);
    try std.testing.expectEqual(@as(?u32, null), fb.pixel(9, 9));
}

test "framebuffer fillRect clips to bounds" {
    var fb = try Framebuffer.init(std.testing.allocator, 4, 4);
    defer fb.deinit(std.testing.allocator);

    fb.fill(0);
    fb.fillRect(-2, 1, 4, 3, 0xAABBCCDD);

    try std.testing.expectEqual(@as(u32, 0), fb.pixel(0, 0).?);
    try std.testing.expectEqual(@as(u32, 0xAABBCCDD), fb.pixel(0, 1).?);
    try std.testing.expectEqual(@as(u32, 0xAABBCCDD), fb.pixel(1, 3).?);
    try std.testing.expectEqual(@as(u32, 0), fb.pixel(3, 0).?);
}
