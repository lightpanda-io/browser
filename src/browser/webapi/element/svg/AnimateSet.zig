// Copyright (C) 2023-2025 Lightpanda Selecy SAS
// SPDX-License-Identifier: AGPL-3.0-or-later

const js = @import("../../../js/js.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const Svg = @import("../Svg.zig");
const AnimationElement = @import("AnimationElement.zig");

const AnimateSet = @This();

_proto: *AnimationElement,

pub fn asSvg(self: *AnimateSet) *Svg {
    return self._proto._proto;
}
pub fn asElement(self: *AnimateSet) *Element {
    return self.asSvg()._proto;
}
pub fn asNode(self: *AnimateSet) *Node {
    return self.asElement().asNode();
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(AnimateSet);
    pub const Meta = struct {
        pub const name = "SVGSetElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };
};
