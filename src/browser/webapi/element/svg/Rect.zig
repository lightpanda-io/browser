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

const std = @import("std");
const js = @import("../../../js/js.zig");
const Page = @import("../../../Page.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const Svg = @import("../Svg.zig");
const GraphicsElement = @import("GraphicsElement.zig");
const GeometryElement = @import("GeometryElement.zig");
const DOMRect = @import("../../DOMRect.zig");
const String = @import("../../../../string.zig").String;
const SVGAnimatedLength = @import("../../svg_types/SVGAnimatedLength.zig");

const Rect = @This();
_proto: *GeometryElement,
_x: SVGAnimatedLength = .{},
_y: SVGAnimatedLength = .{},
_width: SVGAnimatedLength = .{},
_height: SVGAnimatedLength = .{},
_rx: SVGAnimatedLength = .{},
_ry: SVGAnimatedLength = .{},

pub fn asGraphics(self: *Rect) *GraphicsElement {
    return self._proto._proto;
}
pub fn asSvg(self: *Rect) *Svg {
    return self.asGraphics()._proto;
}
pub fn asElement(self: *Rect) *Element {
    return self.asSvg()._proto;
}
pub fn asConstElement(self: *const Rect) *const Element {
    return @as(*const GraphicsElement, self._proto._proto)._proto._proto;
}
pub fn asNode(self: *Rect) *Node {
    return self.asElement().asNode();
}

fn getFloatAttr(element: *const Element, comptime name: []const u8) f64 {
    const val = element.getAttributeSafe(comptime String.wrap(name)) orelse return 0;
    // Find end of numeric part (handles units like px, cm, in, etc.)
    var end: usize = 0;
    while (end < val.len) : (end += 1) {
        const c = val[end];
        if (c >= '0' and c <= '9' or c == '.' or ((c == '-' or c == '+') and end == 0)) continue;
        if ((c == 'e' or c == 'E') and end > 0 and end + 1 < val.len and
            (val[end + 1] >= '0' and val[end + 1] <= '9' or val[end + 1] == '-' or val[end + 1] == '+')) {
            end += 1;
            continue;
        }
        break;
    }
    if (end == 0) return 0;
    return std.fmt.parseFloat(f64, val[0..end]) catch 0;
}

pub fn get_x(self: *Rect) *SVGAnimatedLength {
    if (self._x._base_val._element == null) self._x = SVGAnimatedLength.init(self.asElement(), comptime String.wrap("x"));
    return &self._x;
}

pub fn get_y(self: *Rect) *SVGAnimatedLength {
    if (self._y._base_val._element == null) self._y = SVGAnimatedLength.init(self.asElement(), comptime String.wrap("y"));
    return &self._y;
}

pub fn get_width(self: *Rect) *SVGAnimatedLength {
    if (self._width._base_val._element == null) self._width = SVGAnimatedLength.init(self.asElement(), comptime String.wrap("width"));
    return &self._width;
}

pub fn get_height(self: *Rect) *SVGAnimatedLength {
    if (self._height._base_val._element == null) self._height = SVGAnimatedLength.init(self.asElement(), comptime String.wrap("height"));
    return &self._height;
}

pub fn get_rx(self: *Rect) *SVGAnimatedLength {
    if (self._rx._base_val._element == null) self._rx = SVGAnimatedLength.init(self.asElement(), comptime String.wrap("rx"));
    return &self._rx;
}

pub fn get_ry(self: *Rect) *SVGAnimatedLength {
    if (self._ry._base_val._element == null) self._ry = SVGAnimatedLength.init(self.asElement(), comptime String.wrap("ry"));
    return &self._ry;
}

pub fn getBBox(self: *Rect, page: *Page) !*DOMRect {
    const el = self.asConstElement();
    return DOMRect.init(
        getFloatAttr(el, "x"),
        getFloatAttr(el, "y"),
        getFloatAttr(el, "width"),
        getFloatAttr(el, "height"),
        page,
    );
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Rect);
    pub const Meta = struct {
        pub const name = "SVGRectElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };
    pub const getBBox = bridge.function(Rect.getBBox, .{});
    pub const x = bridge.accessor(Rect.get_x, null, .{});
    pub const y = bridge.accessor(Rect.get_y, null, .{});
    pub const width = bridge.accessor(Rect.get_width, null, .{});
    pub const height = bridge.accessor(Rect.get_height, null, .{});
    pub const rx = bridge.accessor(Rect.get_rx, null, .{});
    pub const ry = bridge.accessor(Rect.get_ry, null, .{});
};
