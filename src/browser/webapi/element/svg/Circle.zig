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

const Circle = @This();
_proto: *GeometryElement,
_cx: SVGAnimatedLength = .{},
_cy: SVGAnimatedLength = .{},
_r: SVGAnimatedLength = .{},

pub fn asGraphics(self: *Circle) *GraphicsElement {
    return self._proto._proto;
}
pub fn asSvg(self: *Circle) *Svg {
    return self.asGraphics()._proto;
}
pub fn asElement(self: *Circle) *Element {
    return self.asSvg()._proto;
}
pub fn asConstElement(self: *const Circle) *const Element {
    return @as(*const GraphicsElement, self._proto._proto)._proto._proto;
}
pub fn asNode(self: *Circle) *Node {
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

pub fn get_cx(self: *Circle) *SVGAnimatedLength {
    if (self._cx._base_val._element == null) self._cx = SVGAnimatedLength.init(self.asElement(), comptime String.wrap("cx"));
    return &self._cx;
}

pub fn get_cy(self: *Circle) *SVGAnimatedLength {
    if (self._cy._base_val._element == null) self._cy = SVGAnimatedLength.init(self.asElement(), comptime String.wrap("cy"));
    return &self._cy;
}

pub fn get_r(self: *Circle) *SVGAnimatedLength {
    if (self._r._base_val._element == null) self._r = SVGAnimatedLength.init(self.asElement(), comptime String.wrap("r"));
    return &self._r;
}

pub fn getBBox(self: *Circle, page: *Page) !*DOMRect {
    const el = self.asConstElement();
    const cx = getFloatAttr(el, "cx");
    const cy = getFloatAttr(el, "cy");
    const r = @max(getFloatAttr(el, "r"), 0);
    return DOMRect.init(cx - r, cy - r, 2 * r, 2 * r, page);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Circle);
    pub const Meta = struct {
        pub const name = "SVGCircleElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };
    pub const getBBox = bridge.function(Circle.getBBox, .{});
    pub const cx = bridge.accessor(Circle.get_cx, null, .{});
    pub const cy = bridge.accessor(Circle.get_cy, null, .{});
    pub const r = bridge.accessor(Circle.get_r, null, .{});
};
