// Copyright (C) 2023-2025 Lightpanda Selecy SAS
// SPDX-License-Identifier: AGPL-3.0-or-later

const js = @import("../../../js/js.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const Svg = @import("../Svg.zig");

const MPath = @This();

_proto: *Svg,

pub fn asElement(self: *MPath) *Element {
    return self._proto._proto;
}
pub fn asNode(self: *MPath) *Node {
    return self.asElement().asNode();
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(MPath);
    pub const Meta = struct {
        pub const name = "SVGMPathElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };
};
