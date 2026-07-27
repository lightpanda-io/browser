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

const js = @import("../../../js/js.zig");
const Frame = @import("../../../Frame.zig");

const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");

const Geometry = @import("Geometry.zig");
const AnimatedLength = @import("../../svg/AnimatedLength.zig");

const Ellipse = @This();
_proto: *Geometry,

pub fn asElement(self: *Ellipse) *Element {
    return self._proto.asElement();
}
pub fn asNode(self: *Ellipse) *Node {
    return self.asElement().asNode();
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Ellipse);

    pub const Meta = struct {
        pub const name = "SVGEllipseElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const cx = bridge.accessor(Ellipse.getCx, null, .{});
    pub const cy = bridge.accessor(Ellipse.getCy, null, .{});
    pub const rx = bridge.accessor(Ellipse.getRx, null, .{});
    pub const ry = bridge.accessor(Ellipse.getRy, null, .{});
};

pub fn getCx(self: *Ellipse, frame: *Frame) !*AnimatedLength {
    return AnimatedLength.getOrCreate(self.asElement(), .cx, frame);
}
pub fn getCy(self: *Ellipse, frame: *Frame) !*AnimatedLength {
    return AnimatedLength.getOrCreate(self.asElement(), .cy, frame);
}
pub fn getRx(self: *Ellipse, frame: *Frame) !*AnimatedLength {
    return AnimatedLength.getOrCreate(self.asElement(), .rx, frame);
}
pub fn getRy(self: *Ellipse, frame: *Frame) !*AnimatedLength {
    return AnimatedLength.getOrCreate(self.asElement(), .ry, frame);
}
