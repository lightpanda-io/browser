// Copyright (C) 2023-2026 Lightpanda (Selecy SAS)
// SPDX-License-Identifier: AGPL-3.0-or-later

const js = @import("../../../js/js.zig");
const Frame = @import("../../../Frame.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const AnimatedLength = @import("../../svg/AnimatedLength.zig");
const GradientElement = @import("GradientElement.zig");

const LinearGradient = @This();
_proto: *GradientElement,

pub fn asElement(self: *LinearGradient) *Element {
    return self._proto.asElement();
}
pub fn asNode(self: *LinearGradient) *Node {
    return self.asElement().asNode();
}

fn getX1(self: *LinearGradient, frame: *Frame) !*AnimatedLength {
    return AnimatedLength.getOrCreate(self.asElement(), .linear_gradient_x1, frame);
}
fn getY1(self: *LinearGradient, frame: *Frame) !*AnimatedLength {
    return AnimatedLength.getOrCreate(self.asElement(), .linear_gradient_y1, frame);
}
fn getX2(self: *LinearGradient, frame: *Frame) !*AnimatedLength {
    return AnimatedLength.getOrCreate(self.asElement(), .linear_gradient_x2, frame);
}
fn getY2(self: *LinearGradient, frame: *Frame) !*AnimatedLength {
    return AnimatedLength.getOrCreate(self.asElement(), .linear_gradient_y2, frame);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(LinearGradient);
    pub const Meta = struct {
        pub const name = "SVGLinearGradientElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };
    pub const x1 = bridge.accessor(LinearGradient.getX1, null, .{});
    pub const y1 = bridge.accessor(LinearGradient.getY1, null, .{});
    pub const x2 = bridge.accessor(LinearGradient.getX2, null, .{});
    pub const y2 = bridge.accessor(LinearGradient.getY2, null, .{});
};
