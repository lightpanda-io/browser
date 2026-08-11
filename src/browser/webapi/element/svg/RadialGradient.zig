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

const AnimatedLength = @import("../../svg/AnimatedLength.zig");

const GradientElement = @import("GradientElement.zig");

const RadialGradient = @This();

pub const Proto = GradientElement;
_pad: bool = false,
_proto_canary: if (lp.IS_DEBUG) *GradientElement else void = undefined,

pub fn asElement(self: *RadialGradient) *Element {
    return Factory.protoOf(self).asElement();
}
pub fn asNode(self: *RadialGradient) *Node {
    return self.asElement().asNode();
}

fn getCx(self: *RadialGradient, frame: *Frame) !*AnimatedLength {
    return AnimatedLength.getOrCreate(self.asElement(), .radial_gradient_cx, frame);
}
fn getCy(self: *RadialGradient, frame: *Frame) !*AnimatedLength {
    return AnimatedLength.getOrCreate(self.asElement(), .radial_gradient_cy, frame);
}
fn getR(self: *RadialGradient, frame: *Frame) !*AnimatedLength {
    return AnimatedLength.getOrCreate(self.asElement(), .radial_gradient_r, frame);
}
fn getFx(self: *RadialGradient, frame: *Frame) !*AnimatedLength {
    return AnimatedLength.getOrCreate(self.asElement(), .radial_gradient_fx, frame);
}
fn getFy(self: *RadialGradient, frame: *Frame) !*AnimatedLength {
    return AnimatedLength.getOrCreate(self.asElement(), .radial_gradient_fy, frame);
}
fn getFr(self: *RadialGradient, frame: *Frame) !*AnimatedLength {
    return AnimatedLength.getOrCreate(self.asElement(), .radial_gradient_fr, frame);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(RadialGradient);
    pub const Meta = struct {
        pub const name = "SVGRadialGradientElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };
    pub const cx = bridge.accessor(RadialGradient.getCx, null, .{});
    pub const cy = bridge.accessor(RadialGradient.getCy, null, .{});
    pub const r = bridge.accessor(RadialGradient.getR, null, .{});
    pub const fx = bridge.accessor(RadialGradient.getFx, null, .{});
    pub const fy = bridge.accessor(RadialGradient.getFy, null, .{});
    pub const fr = bridge.accessor(RadialGradient.getFr, null, .{});
};
