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
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const Svg = @import("../Svg.zig");
const GraphicsElement = @import("GraphicsElement.zig");
const DOMPoint = @import("../../DOMPoint.zig");
const Page = @import("../../../Page.zig");

const GeometryElement = @This();
_proto: *GraphicsElement,

pub fn asSvg(self: *GeometryElement) *Svg {
    return self._proto._proto;
}

pub fn asElement(self: *GeometryElement) *Element {
    return self.asSvg()._proto;
}

pub fn asNode(self: *GeometryElement) *Node {
    return self.asElement().asNode();
}

pub fn getTotalLength(self: *const GeometryElement) f64 {
    _ = self;
    return 0;
}

pub fn isPointInFill(self: *const GeometryElement, x: ?f64, y: ?f64) bool {
    _ = self;
    _ = x;
    _ = y;
    return false;
}

pub fn isPointInStroke(self: *const GeometryElement, x: ?f64, y: ?f64) bool {
    _ = self;
    _ = x;
    _ = y;
    return false;
}

pub fn getPointAtLength(_: *GeometryElement, _: f64, page: *Page) !*DOMPoint {
    return DOMPoint.init(null, null, null, null, page);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(GeometryElement);

    pub const Meta = struct {
        pub const name = "SVGGeometryElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const getTotalLength = bridge.function(GeometryElement.getTotalLength, .{});
    pub const isPointInFill = bridge.function(GeometryElement.isPointInFill, .{});
    pub const isPointInStroke = bridge.function(GeometryElement.isPointInStroke, .{});
    pub const getPointAtLength = bridge.function(GeometryElement.getPointAtLength, .{});
};
