// Copyright (C) 2023-2026 Lightpanda (Selecy SAS)
// SPDX-License-Identifier: AGPL-3.0-or-later

const js = @import("../../../js/js.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const Graphics = @import("Graphics.zig");

const Switch = @This();
_proto: *Graphics,

pub fn asElement(self: *Switch) *Element {
    return self._proto.asElement();
}
pub fn asNode(self: *Switch) *Node {
    return self.asElement().asNode();
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Switch);
    pub const Meta = struct {
        pub const name = "SVGSwitchElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };
};
