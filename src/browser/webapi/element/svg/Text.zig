// Copyright (C) 2023-2025 Lightpanda Selecy SAS
// SPDX-License-Identifier: AGPL-3.0-or-later

// SVGTextElement - 8-level chain:
// EventTarget → Node → Element → Svg → GraphicsElement → TextContent → TextPositioning → Text
// NOTE: Factory.zig must handle 8-level chains for this element.

const js = @import("../../../js/js.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const Svg = @import("../Svg.zig");
const TextContent = @import("TextContent.zig");
const TextPositioning = @import("TextPositioning.zig");

const Text = @This();

_proto: *TextPositioning,

pub fn asTextPositioning(self: *Text) *TextPositioning {
    return self._proto;
}
pub fn asTextContent(self: *Text) *TextContent {
    return self._proto.asTextContent();
}
pub fn asSvg(self: *Text) *Svg {
    return self._proto.asSvg();
}
pub fn asElement(self: *Text) *Element {
    return self._proto.asElement();
}
pub fn asNode(self: *Text) *Node {
    return self._proto.asNode();
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Text);
    pub const Meta = struct {
        pub const name = "SVGTextElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };
};
