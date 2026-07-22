// Copyright (C) 2023-2026 Lightpanda (Selecy SAS)
// SPDX-License-Identifier: AGPL-3.0-or-later

const js = @import("../../../js/js.zig");
const Frame = @import("../../../Frame.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const AnimatedLength = @import("../../svg/AnimatedLength.zig");
const GradientElement = @import("GradientElement.zig");

const RadialGradient = @This();
_proto: *GradientElement,

pub fn asElement(self: *RadialGradient) *Element {
    return self._proto.asElement();
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
