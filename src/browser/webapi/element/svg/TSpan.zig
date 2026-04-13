// Copyright (C) 2023-2025 Lightpanda Selecy SAS
// SPDX-License-Identifier: AGPL-3.0-or-later

// SVGTSpanElement - 8-level chain:
// EventTarget → Node → Element → Svg → GraphicsElement → TextContent → TextPositioning → TSpan
// NOTE: Factory.zig must handle 8-level chains for this element.

const js = @import("../../../js/js.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const Svg = @import("../Svg.zig");
const TextContent = @import("TextContent.zig");
const TextPositioning = @import("TextPositioning.zig");

const TSpan = @This();

_proto: *TextPositioning,

pub fn asTextPositioning(self: *TSpan) *TextPositioning {
    return self._proto;
}
pub fn asTextContent(self: *TSpan) *TextContent {
    return self._proto.asTextContent();
}
pub fn asSvg(self: *TSpan) *Svg {
    return self._proto.asSvg();
}
pub fn asElement(self: *TSpan) *Element {
    return self._proto.asElement();
}
pub fn asNode(self: *TSpan) *Node {
    return self._proto.asNode();
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(TSpan);
    pub const Meta = struct {
        pub const name = "SVGTSpanElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };
};
