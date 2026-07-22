// Copyright (C) 2023-2026 Lightpanda (Selecy SAS)
// SPDX-License-Identifier: AGPL-3.0-or-later

const js = @import("../../../js/js.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const Svg = @import("../Svg.zig");

const Metadata = @This();
_proto: *Svg,

pub fn asElement(self: *Metadata) *Element {
    return self._proto.asElement();
}
pub fn asNode(self: *Metadata) *Node {
    return self.asElement().asNode();
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Metadata);
    pub const Meta = struct {
        pub const name = "SVGMetadataElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };
};
