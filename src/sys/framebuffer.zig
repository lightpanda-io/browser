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
