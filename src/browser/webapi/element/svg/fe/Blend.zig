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

const Blend = @This();
_proto: *Svg,

pub fn asElement(self: *Blend) *Element {
    return self._proto._proto;
}
pub fn asNode(self: *Blend) *Node {
    return self.asElement().asNode();
}

fn getAttr(element: *const Element, comptime name: []const u8) []const u8 {
    return element.getAttributeSafe(comptime String.wrap(name)) orelse "";
}

pub fn get_in(self: *Blend) []const u8 { return getAttr(self.asElement(), "in"); }
pub fn get_in2(self: *Blend) []const u8 { return getAttr(self.asElement(), "in2"); }
pub fn get_mode(self: *Blend) []const u8 { return getAttr(self.asElement(), "mode"); }
pub fn get_x(self: *Blend) []const u8 { return getAttr(self.asElement(), "x"); }
pub fn get_y(self: *Blend) []const u8 { return getAttr(self.asElement(), "y"); }
pub fn get_width(self: *Blend) []const u8 { return getAttr(self.asElement(), "width"); }
pub fn get_height(self: *Blend) []const u8 { return getAttr(self.asElement(), "height"); }
pub fn get_result(self: *Blend) []const u8 { return getAttr(self.asElement(), "result"); }

pub const JsApi = struct {
    pub const bridge = js.Bridge(Blend);
    pub const Meta = struct {
        pub const name = "SVGFEBlendElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };
    pub const @"in" = bridge.accessor(Blend.get_in, null, .{});
    pub const in2 = bridge.accessor(Blend.get_in2, null, .{});
    pub const mode = bridge.accessor(Blend.get_mode, null, .{});
    pub const x = bridge.accessor(Blend.get_x, null, .{});
    pub const y = bridge.accessor(Blend.get_y, null, .{});
    pub const width = bridge.accessor(Blend.get_width, null, .{});
    pub const height = bridge.accessor(Blend.get_height, null, .{});
    pub const result = bridge.accessor(Blend.get_result, null, .{});
};
