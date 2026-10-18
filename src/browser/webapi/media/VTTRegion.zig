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

const js = @import("../../js/js.zig");
const Frame = @import("../../Frame.zig");

const VTTRegion = @This();

_id: []const u8 = "",
_width: f64 = 100,
_lines: u32 = 3,
_region_anchor_x: f64 = 0,
_region_anchor_y: f64 = 100,
_viewport_anchor_x: f64 = 0,
_viewport_anchor_y: f64 = 100,
_scroll: Scroll = .none,

pub const Scroll = enum {
    none,
    up,

    pub fn fromString(value: []const u8) ?Scroll {
        if (value.len == 0) {
            return .none;
        }
        if (std.mem.eql(u8, value, "up")) {
            return .up;
        }
        return null;
    }
};

pub fn init(frame: *Frame) !*VTTRegion {
    return frame._factory.create(VTTRegion{});
}

fn percentage(value: f64) !f64 {
    if (std.math.isFinite(value) == false) {
        return error.TypeError;
    }
    if (value < 0 or value > 100) {
        return error.IndexSizeError;
    }
    return value;
}

pub fn getId(self: *const VTTRegion) []const u8 {
    return self._id;
}

pub fn setId(self: *VTTRegion, value: []const u8, frame: *Frame) !void {
    self._id = try frame.dupeString(value);
}

fn getWidth(self: *const VTTRegion) f64 {
    return self._width;
}

pub fn setWidth(self: *VTTRegion, value: f64) !void {
    self._width = try percentage(value);
}

fn getLines(self: *const VTTRegion) u32 {
    return self._lines;
}

pub fn setLines(self: *VTTRegion, value: u32) void {
    self._lines = value;
}

fn getRegionAnchorX(self: *const VTTRegion) f64 {
    return self._region_anchor_x;
}

pub fn setRegionAnchorX(self: *VTTRegion, value: f64) !void {
    self._region_anchor_x = try percentage(value);
}

fn getRegionAnchorY(self: *const VTTRegion) f64 {
    return self._region_anchor_y;
}

pub fn setRegionAnchorY(self: *VTTRegion, value: f64) !void {
    self._region_anchor_y = try percentage(value);
}

fn getViewportAnchorX(self: *const VTTRegion) f64 {
    return self._viewport_anchor_x;
}

pub fn setViewportAnchorX(self: *VTTRegion, value: f64) !void {
    self._viewport_anchor_x = try percentage(value);
}

fn getViewportAnchorY(self: *const VTTRegion) f64 {
    return self._viewport_anchor_y;
}

pub fn setViewportAnchorY(self: *VTTRegion, value: f64) !void {
    self._viewport_anchor_y = try percentage(value);
}

fn getScroll(self: *const VTTRegion) []const u8 {
    return switch (self._scroll) {
        .none => "",
        .up => "up",
    };
}

fn setScroll(self: *VTTRegion, value: []const u8) void {
    // invalid enum values are ignored
    self._scroll = Scroll.fromString(value) orelse return;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(VTTRegion);

    pub const Meta = struct {
        pub const name = "VTTRegion";
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(VTTRegion.init, .{});
    pub const id = bridge.accessor(VTTRegion.getId, VTTRegion.setId, .{});
    pub const width = bridge.accessor(VTTRegion.getWidth, VTTRegion.setWidth, .{});
    pub const lines = bridge.accessor(VTTRegion.getLines, VTTRegion.setLines, .{});
    pub const regionAnchorX = bridge.accessor(VTTRegion.getRegionAnchorX, VTTRegion.setRegionAnchorX, .{});
    pub const regionAnchorY = bridge.accessor(VTTRegion.getRegionAnchorY, VTTRegion.setRegionAnchorY, .{});
    pub const viewportAnchorX = bridge.accessor(VTTRegion.getViewportAnchorX, VTTRegion.setViewportAnchorX, .{});
    pub const viewportAnchorY = bridge.accessor(VTTRegion.getViewportAnchorY, VTTRegion.setViewportAnchorY, .{});
    pub const scroll = bridge.accessor(VTTRegion.getScroll, VTTRegion.setScroll, .{});
};

const testing = @import("../../../testing.zig");
test "WebApi: VTTRegion" {
    try testing.htmlRunner("media/vttregion.html", .{});
}
