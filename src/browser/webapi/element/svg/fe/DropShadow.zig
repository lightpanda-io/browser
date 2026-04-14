// Copyright (C) 2023-2025  Lightpanda Selecy SAS
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as
// published by the Free Software Foundation, version 3 of the License.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

const std = @import("std");
const js = @import("../../../../js/js.zig");
const Node = @import("../../../Node.zig");
const Element = @import("../../../Element.zig");
const Svg = @import("../../Svg.zig");
const String = @import("../../../../../string.zig").String;

const DropShadow = @This();
_proto: *Svg,

pub fn asElement(self: *DropShadow) *Element {
    return self._proto._proto;
}
pub fn asNode(self: *DropShadow) *Node {
    return self.asElement().asNode();
}

fn getAttr(element: *const Element, comptime name: []const u8) []const u8 {
    return element.getAttributeSafe(comptime String.wrap(name)) orelse "";
}

pub fn get_in(self: *DropShadow) []const u8 { return getAttr(self.asElement(), "in"); }
pub fn get_dx(self: *DropShadow) []const u8 { return getAttr(self.asElement(), "dx"); }
pub fn get_dy(self: *DropShadow) []const u8 { return getAttr(self.asElement(), "dy"); }
fn getStdDev(self: *DropShadow) []const u8 {
    return self.asElement().getAttributeSafe(String.wrap("stdDeviation")) orelse "";
}
pub fn get_stdDeviationX(self: *DropShadow) []const u8 {
    const val = self.getStdDev();
    if (std.mem.indexOf(u8, val, " ")) |idx| return val[0..idx];
    return val;
}
pub fn get_stdDeviationY(self: *DropShadow) []const u8 {
    const val = self.getStdDev();
    if (std.mem.indexOf(u8, val, " ")) |idx| return std.mem.trimLeft(u8, val[idx + 1 ..], " ");
    return val;
}
pub fn setStdDeviation(_: *DropShadow, _: f64, _: f64) void {}
pub fn get_x(self: *DropShadow) []const u8 { return getAttr(self.asElement(), "x"); }
pub fn get_y(self: *DropShadow) []const u8 { return getAttr(self.asElement(), "y"); }
pub fn get_width(self: *DropShadow) []const u8 { return getAttr(self.asElement(), "width"); }
pub fn get_height(self: *DropShadow) []const u8 { return getAttr(self.asElement(), "height"); }
pub fn get_result(self: *DropShadow) []const u8 { return getAttr(self.asElement(), "result"); }

pub const JsApi = struct {
    pub const bridge = js.Bridge(DropShadow);
    pub const Meta = struct {
        pub const name = "SVGFEDropShadowElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };
    pub const @"in" = bridge.accessor(DropShadow.get_in, null, .{});
    pub const dx = bridge.accessor(DropShadow.get_dx, null, .{});
    pub const dy = bridge.accessor(DropShadow.get_dy, null, .{});
    pub const stdDeviationX = bridge.accessor(DropShadow.get_stdDeviationX, null, .{});
    pub const stdDeviationY = bridge.accessor(DropShadow.get_stdDeviationY, null, .{});
    pub const setStdDeviation = bridge.function(DropShadow.setStdDeviation, .{});
    pub const x = bridge.accessor(DropShadow.get_x, null, .{});
    pub const y = bridge.accessor(DropShadow.get_y, null, .{});
    pub const width = bridge.accessor(DropShadow.get_width, null, .{});
    pub const height = bridge.accessor(DropShadow.get_height, null, .{});
    pub const result = bridge.accessor(DropShadow.get_result, null, .{});
};
