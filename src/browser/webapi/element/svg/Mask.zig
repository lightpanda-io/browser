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

const lp = @import("lightpanda");
const Factory = @import("../../../Factory.zig");
const js = @import("../../../js/js.zig");
const Frame = @import("../../../Frame.zig");

const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");

const AnimatedEnumeration = @import("../../svg/AnimatedEnumeration.zig");
const AnimatedLength = @import("../../svg/AnimatedLength.zig");

const Svg = @import("../Svg.zig");

const Mask = @This();

pub const Proto = Svg;
_pad: bool = false,
_proto_canary: if (lp.IS_DEBUG) *Svg else void = undefined,

pub fn asElement(self: *Mask) *Element {
    return Factory.protoOf(self).asElement();
}
pub fn asNode(self: *Mask) *Node {
    return self.asElement().asNode();
}

fn getX(self: *Mask, frame: *Frame) !*AnimatedLength {
    return AnimatedLength.getOrCreate(self.asElement(), .mask_x, frame);
}
fn getY(self: *Mask, frame: *Frame) !*AnimatedLength {
    return AnimatedLength.getOrCreate(self.asElement(), .mask_y, frame);
}
fn getWidth(self: *Mask, frame: *Frame) !*AnimatedLength {
    return AnimatedLength.getOrCreate(self.asElement(), .mask_width, frame);
}
fn getHeight(self: *Mask, frame: *Frame) !*AnimatedLength {
    return AnimatedLength.getOrCreate(self.asElement(), .mask_height, frame);
}
fn getMaskUnits(self: *Mask, frame: *Frame) !*AnimatedEnumeration {
    return AnimatedEnumeration.getOrCreate(self.asElement(), .mask_units, frame);
}
fn getMaskContentUnits(self: *Mask, frame: *Frame) !*AnimatedEnumeration {
    return AnimatedEnumeration.getOrCreate(self.asElement(), .mask_content_units, frame);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Mask);
    pub const Meta = struct {
        pub const name = "SVGMaskElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };
    pub const x = bridge.accessor(Mask.getX, null, .{});
    pub const y = bridge.accessor(Mask.getY, null, .{});
    pub const width = bridge.accessor(Mask.getWidth, null, .{});
    pub const height = bridge.accessor(Mask.getHeight, null, .{});
    pub const maskUnits = bridge.accessor(Mask.getMaskUnits, null, .{});
    pub const maskContentUnits = bridge.accessor(Mask.getMaskContentUnits, null, .{});
};
