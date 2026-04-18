// Copyright (C) 2023-2025 Lightpanda Selecy SAS
// SPDX-License-Identifier: AGPL-3.0-or-later

const js = @import("../../../js/js.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const Svg = @import("../Svg.zig");
const AnimationElement = @import("AnimationElement.zig");

const Animate = @This();

_proto: *AnimationElement,

pub fn asSvg(self: *Animate) *Svg {
    return self._proto._proto;
}
pub fn asElement(self: *Animate) *Element {
    return self.asSvg()._proto;
}
pub fn asNode(self: *Animate) *Node {
    return self.asElement().asNode();
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Animate);
    pub const Meta = struct {
        pub const name = "SVGAnimateElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };
};
