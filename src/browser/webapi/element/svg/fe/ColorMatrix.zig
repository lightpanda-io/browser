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

const ColorMatrix = @This();
_proto: *Svg,

pub fn asElement(self: *ColorMatrix) *Element {
    return self._proto._proto;
}
pub fn asNode(self: *ColorMatrix) *Node {
    return self.asElement().asNode();
}

fn getAttr(element: *const Element, comptime name: []const u8) []const u8 {
    return element.getAttributeSafe(comptime String.wrap(name)) orelse "";
}

pub fn get_in(self: *ColorMatrix) []const u8 { return getAttr(self.asElement(), "in"); }
pub fn get_type(self: *ColorMatrix) []const u8 { return getAttr(self.asElement(), "type"); }
pub fn get_values(self: *ColorMatrix) []const u8 { return getAttr(self.asElement(), "values"); }
pub fn get_x(self: *ColorMatrix) []const u8 { return getAttr(self.asElement(), "x"); }
pub fn get_y(self: *ColorMatrix) []const u8 { return getAttr(self.asElement(), "y"); }
pub fn get_width(self: *ColorMatrix) []const u8 { return getAttr(self.asElement(), "width"); }
pub fn get_height(self: *ColorMatrix) []const u8 { return getAttr(self.asElement(), "height"); }
pub fn get_result(self: *ColorMatrix) []const u8 { return getAttr(self.asElement(), "result"); }

pub const JsApi = struct {
    pub const bridge = js.Bridge(ColorMatrix);
    pub const Meta = struct {
        pub const name = "SVGFEColorMatrixElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };
    pub const @"in" = bridge.accessor(ColorMatrix.get_in, null, .{});
    pub const @"type" = bridge.accessor(ColorMatrix.get_type, null, .{});
    pub const values = bridge.accessor(ColorMatrix.get_values, null, .{});
    pub const x = bridge.accessor(ColorMatrix.get_x, null, .{});
    pub const y = bridge.accessor(ColorMatrix.get_y, null, .{});
    pub const width = bridge.accessor(ColorMatrix.get_width, null, .{});
    pub const height = bridge.accessor(ColorMatrix.get_height, null, .{});
    pub const result = bridge.accessor(ColorMatrix.get_result, null, .{});
};
