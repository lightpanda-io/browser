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

const Morphology = @This();
_proto: *Svg,

pub fn asElement(self: *Morphology) *Element {
    return self._proto._proto;
}
pub fn asNode(self: *Morphology) *Node {
    return self.asElement().asNode();
}

pub fn get_in(self: *Morphology) []const u8 {
    return self.asElement().getAttributeSafe(comptime String.wrap("in")) orelse "";
}
pub fn get_operator(self: *Morphology) []const u8 {
    return self.asElement().getAttributeSafe(comptime String.wrap("operator")) orelse "";
}
pub fn get_radiusX(self: *Morphology) []const u8 {
    return self.asElement().getAttributeSafe(comptime String.wrap("radiusX")) orelse "";
}
pub fn get_radiusY(self: *Morphology) []const u8 {
    return self.asElement().getAttributeSafe(comptime String.wrap("radiusY")) orelse "";
}
pub fn get_x(self: *Morphology) []const u8 {
    return self.asElement().getAttributeSafe(comptime String.wrap("x")) orelse "";
}
pub fn get_y(self: *Morphology) []const u8 {
    return self.asElement().getAttributeSafe(comptime String.wrap("y")) orelse "";
}
pub fn get_width(self: *Morphology) []const u8 {
    return self.asElement().getAttributeSafe(comptime String.wrap("width")) orelse "";
}
pub fn get_height(self: *Morphology) []const u8 {
    return self.asElement().getAttributeSafe(comptime String.wrap("height")) orelse "";
}
pub fn get_result(self: *Morphology) []const u8 {
    return self.asElement().getAttributeSafe(comptime String.wrap("result")) orelse "";
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Morphology);
    pub const Meta = struct {
        pub const name = "SVGFEMorphologyElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };
    pub const @"in" = bridge.accessor(Morphology.get_in, null, .{});
    pub const operator = bridge.accessor(Morphology.get_operator, null, .{});
    pub const radiusX = bridge.accessor(Morphology.get_radiusX, null, .{});
    pub const radiusY = bridge.accessor(Morphology.get_radiusY, null, .{});
    pub const x = bridge.accessor(Morphology.get_x, null, .{});
    pub const y = bridge.accessor(Morphology.get_y, null, .{});
    pub const width = bridge.accessor(Morphology.get_width, null, .{});
    pub const height = bridge.accessor(Morphology.get_height, null, .{});
    pub const result = bridge.accessor(Morphology.get_result, null, .{});
};
