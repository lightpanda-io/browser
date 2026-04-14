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

const PointLight = @This();
_proto: *Svg,

pub fn asElement(self: *PointLight) *Element {
    return self._proto._proto;
}
pub fn asNode(self: *PointLight) *Node {
    return self.asElement().asNode();
}

pub fn get_x(self: *PointLight) []const u8 {
    return self.asElement().getAttributeSafe(comptime String.wrap("x")) orelse "";
}
pub fn get_y(self: *PointLight) []const u8 {
    return self.asElement().getAttributeSafe(comptime String.wrap("y")) orelse "";
}
pub fn get_z(self: *PointLight) []const u8 {
    return self.asElement().getAttributeSafe(comptime String.wrap("z")) orelse "";
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(PointLight);
    pub const Meta = struct {
        pub const name = "SVGFEPointLightElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };
    pub const x = bridge.accessor(PointLight.get_x, null, .{});
    pub const y = bridge.accessor(PointLight.get_y, null, .{});
    pub const z = bridge.accessor(PointLight.get_z, null, .{});
};
