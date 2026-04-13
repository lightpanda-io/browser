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

const Line = @This();
_proto: *GeometryElement,
_x1: SVGAnimatedLength = .{},
_y1: SVGAnimatedLength = .{},
_x2: SVGAnimatedLength = .{},
_y2: SVGAnimatedLength = .{},

pub fn asGraphics(self: *Line) *GraphicsElement {
    return self._proto._proto;
}
pub fn asSvg(self: *Line) *Svg {
    return self.asGraphics()._proto;
}
pub fn asElement(self: *Line) *Element {
    return self.asSvg()._proto;
}
pub fn asConstElement(self: *const Line) *const Element {
    return @as(*const GraphicsElement, self._proto._proto)._proto._proto;
}
pub fn asNode(self: *Line) *Node {
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

pub fn get_x1(self: *Line) *SVGAnimatedLength {
    if (self._x1._base_val._element == null) self._x1 = SVGAnimatedLength.init(self.asElement(), comptime String.wrap("x1"));
    return &self._x1;
}

pub fn get_y1(self: *Line) *SVGAnimatedLength {
    if (self._y1._base_val._element == null) self._y1 = SVGAnimatedLength.init(self.asElement(), comptime String.wrap("y1"));
    return &self._y1;
}

pub fn get_x2(self: *Line) *SVGAnimatedLength {
    if (self._x2._base_val._element == null) self._x2 = SVGAnimatedLength.init(self.asElement(), comptime String.wrap("x2"));
    return &self._x2;
}

pub fn get_y2(self: *Line) *SVGAnimatedLength {
    if (self._y2._base_val._element == null) self._y2 = SVGAnimatedLength.init(self.asElement(), comptime String.wrap("y2"));
    return &self._y2;
}

pub fn getBBox(self: *Line, page: *Page) !*DOMRect {
    const el = self.asConstElement();
    const x1 = getFloatAttr(el, "x1");
    const y1 = getFloatAttr(el, "y1");
    const x2 = getFloatAttr(el, "x2");
    const y2 = getFloatAttr(el, "y2");
    return DOMRect.init(@min(x1, x2), @min(y1, y2), @abs(x2 - x1), @abs(y2 - y1), page);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Line);
    pub const Meta = struct {
        pub const name = "SVGLineElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };
    pub const getBBox = bridge.function(Line.getBBox, .{});
    pub const x1 = bridge.accessor(Line.get_x1, null, .{});
    pub const y1 = bridge.accessor(Line.get_y1, null, .{});
    pub const x2 = bridge.accessor(Line.get_x2, null, .{});
    pub const y2 = bridge.accessor(Line.get_y2, null, .{});
};
