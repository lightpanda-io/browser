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

const Ellipse = @This();
_proto: *GeometryElement,
_cx: SVGAnimatedLength = .{},
_cy: SVGAnimatedLength = .{},
_rx: SVGAnimatedLength = .{},
_ry: SVGAnimatedLength = .{},

pub fn asGraphics(self: *Ellipse) *GraphicsElement {
    return self._proto._proto;
}
pub fn asSvg(self: *Ellipse) *Svg {
    return self.asGraphics()._proto;
}
pub fn asElement(self: *Ellipse) *Element {
    return self.asSvg()._proto;
}
pub fn asConstElement(self: *const Ellipse) *const Element {
    return @as(*const GraphicsElement, self._proto._proto)._proto._proto;
}
pub fn asNode(self: *Ellipse) *Node {
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

pub fn get_cx(self: *Ellipse) *SVGAnimatedLength {
    if (self._cx._base_val._element == null) self._cx = SVGAnimatedLength.init(self.asElement(), comptime String.wrap("cx"));
    return &self._cx;
}

pub fn get_cy(self: *Ellipse) *SVGAnimatedLength {
    if (self._cy._base_val._element == null) self._cy = SVGAnimatedLength.init(self.asElement(), comptime String.wrap("cy"));
    return &self._cy;
}

pub fn get_rx(self: *Ellipse) *SVGAnimatedLength {
    if (self._rx._base_val._element == null) self._rx = SVGAnimatedLength.init(self.asElement(), comptime String.wrap("rx"));
    return &self._rx;
}

pub fn get_ry(self: *Ellipse) *SVGAnimatedLength {
    if (self._ry._base_val._element == null) self._ry = SVGAnimatedLength.init(self.asElement(), comptime String.wrap("ry"));
    return &self._ry;
}

pub fn getBBox(self: *Ellipse, page: *Page) !*DOMRect {
    const el = self.asConstElement();
    const cx = getFloatAttr(el, "cx");
    const cy = getFloatAttr(el, "cy");
    const rx = @max(getFloatAttr(el, "rx"), 0);
    const ry = @max(getFloatAttr(el, "ry"), 0);
    return DOMRect.init(cx - rx, cy - ry, 2 * rx, 2 * ry, page);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Ellipse);
    pub const Meta = struct {
        pub const name = "SVGEllipseElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };
    pub const getBBox = bridge.function(Ellipse.getBBox, .{});
    pub const cx = bridge.accessor(Ellipse.get_cx, null, .{});
    pub const cy = bridge.accessor(Ellipse.get_cy, null, .{});
    pub const rx = bridge.accessor(Ellipse.get_rx, null, .{});
    pub const ry = bridge.accessor(Ellipse.get_ry, null, .{});
};
