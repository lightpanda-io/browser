// Copyright (C) 2023-2025 Lightpanda Selecy SAS
// SPDX-License-Identifier: AGPL-3.0-or-later

const js = @import("../../../js/js.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const Svg = @import("../Svg.zig");

const View = @This();

_proto: *Svg,

pub fn asElement(self: *View) *Element {
    return self._proto._proto;
}
pub fn asNode(self: *View) *Node {
    return self.asElement().asNode();
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(View);
    pub const Meta = struct {
        pub const name = "SVGViewElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };
};
