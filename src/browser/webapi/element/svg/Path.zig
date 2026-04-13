// Copyright (C) 2023-2025  Lightpanda (Selecy SAS)
//
// Francis Bouvier <francis@lightpanda.io>
// Pierre Tachoire <pierre@lightpanda.io>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as
// published by the Free Software Foundation, either version 3 of the
// License, or (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

const js = @import("../../../js/js.zig");
const Page = @import("../../../Page.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const Svg = @import("../Svg.zig");
const GraphicsElement = @import("GraphicsElement.zig");
const GeometryElement = @import("GeometryElement.zig");
const DOMRect = @import("../../DOMRect.zig");
const String = @import("../../../../string.zig").String;
const path_parser = @import("../../svg_types/path_parser.zig");

const Path = @This();
_proto: *GeometryElement,

pub fn asGraphics(self: *Path) *GraphicsElement {
    return self._proto._proto;
}
pub fn asSvg(self: *Path) *Svg {
    return self.asGraphics()._proto;
}
pub fn asElement(self: *Path) *Element {
    return self.asSvg()._proto;
}
pub fn asConstElement(self: *const Path) *const Element {
    return @as(*const GraphicsElement, self._proto._proto)._proto._proto;
}
pub fn asNode(self: *Path) *Node {
    return self.asElement().asNode();
}

pub fn get_d(self: *Path) []const u8 {
    return self.asConstElement().getAttributeSafe(comptime String.wrap("d")) orelse "";
}

pub fn set_d(self: *Path, value: []const u8, page: *Page) !void {
    try self.asElement().setAttributeSafe(comptime String.wrap("d"), String.wrap(value), page);
}

pub fn getBBox(self: *Path, page: *Page) !*DOMRect {
    const d = self.asConstElement().getAttributeSafe(comptime String.wrap("d")) orelse
        return DOMRect.init(0, 0, 0, 0, page);
    const bbox = path_parser.computeBBox(d) orelse return DOMRect.init(0, 0, 0, 0, page);
    return DOMRect.init(bbox.min_x, bbox.min_y, bbox.width(), bbox.height(), page);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Path);
    pub const Meta = struct {
        pub const name = "SVGPathElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };
    pub const getBBox = bridge.function(Path.getBBox, .{});
    pub const d = bridge.accessor(Path.get_d, Path.set_d, .{});
};
