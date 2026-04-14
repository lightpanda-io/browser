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

const SpecularLighting = @This();
_proto: *Svg,

pub fn asElement(self: *SpecularLighting) *Element {
    return self._proto._proto;
}
pub fn asNode(self: *SpecularLighting) *Node {
    return self.asElement().asNode();
}

pub fn get_in(self: *SpecularLighting) []const u8 {
    return self.asElement().getAttributeSafe(comptime String.wrap("in")) orelse "";
}
pub fn get_surfaceScale(self: *SpecularLighting) []const u8 {
    return self.asElement().getAttributeSafe(String.wrap("surfaceScale")) orelse "";
}
pub fn get_specularConstant(self: *SpecularLighting) []const u8 {
    return self.asElement().getAttributeSafe(String.wrap("specularConstant")) orelse "";
}
pub fn get_specularExponent(self: *SpecularLighting) []const u8 {
    return self.asElement().getAttributeSafe(String.wrap("specularExponent")) orelse "";
}
pub fn get_x(self: *SpecularLighting) []const u8 {
    return self.asElement().getAttributeSafe(comptime String.wrap("x")) orelse "";
}
pub fn get_y(self: *SpecularLighting) []const u8 {
    return self.asElement().getAttributeSafe(comptime String.wrap("y")) orelse "";
}
pub fn get_width(self: *SpecularLighting) []const u8 {
    return self.asElement().getAttributeSafe(comptime String.wrap("width")) orelse "";
}
pub fn get_height(self: *SpecularLighting) []const u8 {
    return self.asElement().getAttributeSafe(comptime String.wrap("height")) orelse "";
}
pub fn get_result(self: *SpecularLighting) []const u8 {
    return self.asElement().getAttributeSafe(comptime String.wrap("result")) orelse "";
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(SpecularLighting);
    pub const Meta = struct {
        pub const name = "SVGFESpecularLightingElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };
    pub const @"in" = bridge.accessor(SpecularLighting.get_in, null, .{});
    pub const surfaceScale = bridge.accessor(SpecularLighting.get_surfaceScale, null, .{});
    pub const specularConstant = bridge.accessor(SpecularLighting.get_specularConstant, null, .{});
    pub const specularExponent = bridge.accessor(SpecularLighting.get_specularExponent, null, .{});
    pub const x = bridge.accessor(SpecularLighting.get_x, null, .{});
    pub const y = bridge.accessor(SpecularLighting.get_y, null, .{});
    pub const width = bridge.accessor(SpecularLighting.get_width, null, .{});
    pub const height = bridge.accessor(SpecularLighting.get_height, null, .{});
    pub const result = bridge.accessor(SpecularLighting.get_result, null, .{});
};
