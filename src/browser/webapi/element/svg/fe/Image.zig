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

const Image = @This();
_proto: *Svg,

pub fn asElement(self: *Image) *Element {
    return self._proto._proto;
}
pub fn asNode(self: *Image) *Node {
    return self.asElement().asNode();
}

fn getAttr(element: *const Element, comptime name: []const u8) []const u8 {
    return element.getAttributeSafe(comptime String.wrap(name)) orelse "";
}

pub fn get_href(self: *Image) []const u8 { return getAttr(self.asElement(), "href"); }
pub fn get_preserveAspectRatio(self: *Image) []const u8 {
    return self.asElement().getAttributeSafe(String.wrap("preserveAspectRatio")) orelse "";
}
pub fn get_x(self: *Image) []const u8 { return getAttr(self.asElement(), "x"); }
pub fn get_y(self: *Image) []const u8 { return getAttr(self.asElement(), "y"); }
pub fn get_width(self: *Image) []const u8 { return getAttr(self.asElement(), "width"); }
pub fn get_height(self: *Image) []const u8 { return getAttr(self.asElement(), "height"); }
pub fn get_result(self: *Image) []const u8 { return getAttr(self.asElement(), "result"); }

pub const JsApi = struct {
    pub const bridge = js.Bridge(Image);
    pub const Meta = struct {
        pub const name = "SVGFEImageElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };
    pub const href = bridge.accessor(Image.get_href, null, .{});
    pub const preserveAspectRatio = bridge.accessor(Image.get_preserveAspectRatio, null, .{});
    pub const x = bridge.accessor(Image.get_x, null, .{});
    pub const y = bridge.accessor(Image.get_y, null, .{});
    pub const width = bridge.accessor(Image.get_width, null, .{});
    pub const height = bridge.accessor(Image.get_height, null, .{});
    pub const result = bridge.accessor(Image.get_result, null, .{});
};
