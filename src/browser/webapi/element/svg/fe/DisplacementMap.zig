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

const DisplacementMap = @This();
_proto: *Svg,

pub fn asElement(self: *DisplacementMap) *Element {
    return self._proto._proto;
}
pub fn asNode(self: *DisplacementMap) *Node {
    return self.asElement().asNode();
}

fn getAttr(element: *const Element, comptime name: []const u8) []const u8 {
    return element.getAttributeSafe(comptime String.wrap(name)) orelse "";
}

pub fn get_in(self: *DisplacementMap) []const u8 { return getAttr(self.asElement(), "in"); }
pub fn get_in2(self: *DisplacementMap) []const u8 { return getAttr(self.asElement(), "in2"); }
pub fn get_scale(self: *DisplacementMap) []const u8 { return getAttr(self.asElement(), "scale"); }
pub fn get_xChannelSelector(self: *DisplacementMap) []const u8 {
    return self.asElement().getAttributeSafe(String.wrap("xChannelSelector")) orelse "";
}
pub fn get_yChannelSelector(self: *DisplacementMap) []const u8 {
    return self.asElement().getAttributeSafe(String.wrap("yChannelSelector")) orelse "";
}
pub fn get_x(self: *DisplacementMap) []const u8 { return getAttr(self.asElement(), "x"); }
pub fn get_y(self: *DisplacementMap) []const u8 { return getAttr(self.asElement(), "y"); }
pub fn get_width(self: *DisplacementMap) []const u8 { return getAttr(self.asElement(), "width"); }
pub fn get_height(self: *DisplacementMap) []const u8 { return getAttr(self.asElement(), "height"); }
pub fn get_result(self: *DisplacementMap) []const u8 { return getAttr(self.asElement(), "result"); }

pub const JsApi = struct {
    pub const bridge = js.Bridge(DisplacementMap);
    pub const Meta = struct {
        pub const name = "SVGFEDisplacementMapElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };
    pub const @"in" = bridge.accessor(DisplacementMap.get_in, null, .{});
    pub const in2 = bridge.accessor(DisplacementMap.get_in2, null, .{});
    pub const scale = bridge.accessor(DisplacementMap.get_scale, null, .{});
    pub const xChannelSelector = bridge.accessor(DisplacementMap.get_xChannelSelector, null, .{});
    pub const yChannelSelector = bridge.accessor(DisplacementMap.get_yChannelSelector, null, .{});
    pub const x = bridge.accessor(DisplacementMap.get_x, null, .{});
    pub const y = bridge.accessor(DisplacementMap.get_y, null, .{});
    pub const width = bridge.accessor(DisplacementMap.get_width, null, .{});
    pub const height = bridge.accessor(DisplacementMap.get_height, null, .{});
    pub const result = bridge.accessor(DisplacementMap.get_result, null, .{});
};
