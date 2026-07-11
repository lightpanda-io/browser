// Copyright (C) 2023-2026  Lightpanda (Selecy SAS)
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
const Frame = @import("../../../Frame.zig");

const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const TreeWalker = @import("../../TreeWalker.zig");
const DOMRect = @import("../../DOMRect.zig");
const DOMPoint = @import("../../DOMPoint.zig");
const DOMMatrix = @import("../../DOMMatrix.zig");
const SvgNumber = @import("../../svg/Number.zig");

const Graphics = @import("Graphics.zig");

const Svg = @This();
_proto: *Graphics,

pub fn asElement(self: *Svg) *Element {
    return self._proto.asElement();
}
pub fn asNode(self: *Svg) *Node {
    return self.asElement().asNode();
}

pub fn getElementById(self: *Svg, id: []const u8) ?*Element {
    if (id.len == 0) {
        return null;
    }

    var tw = TreeWalker.Full.Elements.init(self.asNode(), .{});
    while (tw.next()) |el| {
        const element_id = el.getAttributeSafe(comptime .wrap("id")) orelse continue;
        if (std.mem.eql(u8, element_id, id)) {
            return el;
        }
    }
    return null;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Svg);

    pub const Meta = struct {
        pub const name = "SVGSVGElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const getElementById = bridge.function(Svg.getElementById, .{});

    pub const createSVGPoint = bridge.function(_createSVGPoint, .{});
    fn _createSVGPoint(_: *Svg, frame: *Frame) !*DOMPoint {
        return DOMPoint.create(0, 0, 0, 1, frame._page);
    }

    pub const createSVGMatrix = bridge.function(_createSVGMatrix, .{});
    fn _createSVGMatrix(_: *Svg, frame: *Frame) !*DOMMatrix {
        const identity: [16]f64 = .{
            1, 0, 0, 0,
            0, 1, 0, 0,
            0, 0, 1, 0,
            0, 0, 0, 1,
        };
        return DOMMatrix.create(identity, true, frame._page);
    }

    pub const createSVGRect = bridge.function(_createSVGRect, .{});
    fn _createSVGRect(_: *Svg, frame: *Frame) !*DOMRect {
        return DOMRect.init(0, 0, 0, 0, frame);
    }

    pub const createSVGNumber = bridge.function(_createSVGNumber, .{});
    fn _createSVGNumber(_: *Svg, frame: *Frame) !*SvgNumber {
        return frame._factory.create(SvgNumber{});
    }
};
