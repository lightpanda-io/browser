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

const SpotLight = @This();
_proto: *Svg,

pub fn asElement(self: *SpotLight) *Element {
    return self._proto._proto;
}
pub fn asNode(self: *SpotLight) *Node {
    return self.asElement().asNode();
}

pub fn get_x(self: *SpotLight) []const u8 {
    return self.asElement().getAttributeSafe(comptime String.wrap("x")) orelse "";
}
pub fn get_y(self: *SpotLight) []const u8 {
    return self.asElement().getAttributeSafe(comptime String.wrap("y")) orelse "";
}
pub fn get_z(self: *SpotLight) []const u8 {
    return self.asElement().getAttributeSafe(comptime String.wrap("z")) orelse "";
}
pub fn get_pointsAtX(self: *SpotLight) []const u8 {
    return self.asElement().getAttributeSafe(String.wrap("pointsAtX")) orelse "";
}
pub fn get_pointsAtY(self: *SpotLight) []const u8 {
    return self.asElement().getAttributeSafe(String.wrap("pointsAtY")) orelse "";
}
pub fn get_pointsAtZ(self: *SpotLight) []const u8 {
    return self.asElement().getAttributeSafe(String.wrap("pointsAtZ")) orelse "";
}
pub fn get_specularExponent(self: *SpotLight) []const u8 {
    return self.asElement().getAttributeSafe(String.wrap("specularExponent")) orelse "";
}
pub fn get_limitingConeAngle(self: *SpotLight) []const u8 {
    return self.asElement().getAttributeSafe(String.wrap("limitingConeAngle")) orelse "";
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(SpotLight);
    pub const Meta = struct {
        pub const name = "SVGFESpotLightElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };
    pub const x = bridge.accessor(SpotLight.get_x, null, .{});
    pub const y = bridge.accessor(SpotLight.get_y, null, .{});
    pub const z = bridge.accessor(SpotLight.get_z, null, .{});
    pub const pointsAtX = bridge.accessor(SpotLight.get_pointsAtX, null, .{});
    pub const pointsAtY = bridge.accessor(SpotLight.get_pointsAtY, null, .{});
    pub const pointsAtZ = bridge.accessor(SpotLight.get_pointsAtZ, null, .{});
    pub const specularExponent = bridge.accessor(SpotLight.get_specularExponent, null, .{});
    pub const limitingConeAngle = bridge.accessor(SpotLight.get_limitingConeAngle, null, .{});
};
