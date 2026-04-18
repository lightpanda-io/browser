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
const DOMRect = @import("../../DOMRect.zig");
const DOMMatrix = @import("../../DOMMatrix.zig");
const Page = @import("../../../Page.zig");

const GraphicsElement = @This();
_proto: *Svg,

pub fn asElement(self: *GraphicsElement) *Element {
    return self._proto._proto;
}

pub fn asConstElement(self: *const GraphicsElement) *const Element {
    return self._proto._proto;
}

pub fn asNode(self: *GraphicsElement) *Node {
    return self.asElement().asNode();
}

/// getBBox stub - returns zero rect, overridden by specific elements
pub fn getBBox(self: *GraphicsElement, page: *Page) !*DOMRect {
    _ = self;
    return DOMRect.init(0, 0, 0, 0, page);
}

pub fn getCTM(_: *GraphicsElement, page: *Page) !*DOMMatrix {
    return DOMMatrix.init(page);
}

pub fn getScreenCTM(_: *GraphicsElement, page: *Page) !*DOMMatrix {
    return DOMMatrix.init(page);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(GraphicsElement);

    pub const Meta = struct {
        pub const name = "SVGGraphicsElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const getBBox = bridge.function(GraphicsElement.getBBox, .{});
    pub const getCTM = bridge.function(GraphicsElement.getCTM, .{});
    pub const getScreenCTM = bridge.function(GraphicsElement.getScreenCTM, .{});
};
