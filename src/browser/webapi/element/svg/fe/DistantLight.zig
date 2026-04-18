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

const DistantLight = @This();
_proto: *Svg,

pub fn asElement(self: *DistantLight) *Element {
    return self._proto._proto;
}
pub fn asNode(self: *DistantLight) *Node {
    return self.asElement().asNode();
}

fn getAttr(element: *const Element, comptime name: []const u8) []const u8 {
    return element.getAttributeSafe(comptime String.wrap(name)) orelse "";
}

pub fn get_azimuth(self: *DistantLight) []const u8 { return getAttr(self.asElement(), "azimuth"); }
pub fn get_elevation(self: *DistantLight) []const u8 { return getAttr(self.asElement(), "elevation"); }

pub const JsApi = struct {
    pub const bridge = js.Bridge(DistantLight);
    pub const Meta = struct {
        pub const name = "SVGFEDistantLightElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };
    pub const azimuth = bridge.accessor(DistantLight.get_azimuth, null, .{});
    pub const elevation = bridge.accessor(DistantLight.get_elevation, null, .{});
};
