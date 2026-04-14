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

const Turbulence = @This();
_proto: *Svg,

pub fn asElement(self: *Turbulence) *Element {
    return self._proto._proto;
}
pub fn asNode(self: *Turbulence) *Node {
    return self.asElement().asNode();
}

pub fn get_baseFrequencyX(self: *Turbulence) []const u8 {
    return self.asElement().getAttributeSafe(String.wrap("baseFrequencyX")) orelse "";
}
pub fn get_baseFrequencyY(self: *Turbulence) []const u8 {
    return self.asElement().getAttributeSafe(String.wrap("baseFrequencyY")) orelse "";
}
pub fn get_numOctaves(self: *Turbulence) []const u8 {
    return self.asElement().getAttributeSafe(comptime String.wrap("numOctaves")) orelse "";
}
pub fn get_seed(self: *Turbulence) []const u8 {
    return self.asElement().getAttributeSafe(comptime String.wrap("seed")) orelse "";
}
pub fn get_stitchTiles(self: *Turbulence) []const u8 {
    return self.asElement().getAttributeSafe(String.wrap("stitchTiles")) orelse "";
}
pub fn get_type(self: *Turbulence) []const u8 {
    return self.asElement().getAttributeSafe(comptime String.wrap("type")) orelse "";
}
pub fn get_x(self: *Turbulence) []const u8 {
    return self.asElement().getAttributeSafe(comptime String.wrap("x")) orelse "";
}
pub fn get_y(self: *Turbulence) []const u8 {
    return self.asElement().getAttributeSafe(comptime String.wrap("y")) orelse "";
}
pub fn get_width(self: *Turbulence) []const u8 {
    return self.asElement().getAttributeSafe(comptime String.wrap("width")) orelse "";
}
pub fn get_height(self: *Turbulence) []const u8 {
    return self.asElement().getAttributeSafe(comptime String.wrap("height")) orelse "";
}
pub fn get_result(self: *Turbulence) []const u8 {
    return self.asElement().getAttributeSafe(comptime String.wrap("result")) orelse "";
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Turbulence);
    pub const Meta = struct {
        pub const name = "SVGFETurbulenceElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };
    pub const baseFrequencyX = bridge.accessor(Turbulence.get_baseFrequencyX, null, .{});
    pub const baseFrequencyY = bridge.accessor(Turbulence.get_baseFrequencyY, null, .{});
    pub const numOctaves = bridge.accessor(Turbulence.get_numOctaves, null, .{});
    pub const seed = bridge.accessor(Turbulence.get_seed, null, .{});
    pub const stitchTiles = bridge.accessor(Turbulence.get_stitchTiles, null, .{});
    pub const @"type" = bridge.accessor(Turbulence.get_type, null, .{});
    pub const x = bridge.accessor(Turbulence.get_x, null, .{});
    pub const y = bridge.accessor(Turbulence.get_y, null, .{});
    pub const width = bridge.accessor(Turbulence.get_width, null, .{});
    pub const height = bridge.accessor(Turbulence.get_height, null, .{});
    pub const result = bridge.accessor(Turbulence.get_result, null, .{});
};
