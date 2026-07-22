// Copyright (C) 2023-2026 Lightpanda (Selecy SAS)
// SPDX-License-Identifier: AGPL-3.0-or-later

const js = @import("../../../js/js.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const TextContent = @import("TextContent.zig");

pub const Text = @import("Text.zig");
pub const TSpan = @import("TSpan.zig");

const TextPositioning = @This();
_proto: *TextContent,
_type: Type,

pub const Type = union(enum) {
    text: *Text,
    tspan: *TSpan,
};

pub fn is(self: *TextPositioning, comptime T: type) ?*T {
    inline for (@typeInfo(Type).@"union".fields) |field| {
        if (@field(Type, field.name) == self._type) {
            if (field.type == *T) return @field(self._type, field.name);
        }
    }
    return null;
}

pub fn asElement(self: *TextPositioning) *Element {
    return self._proto.asElement();
}
pub fn asNode(self: *TextPositioning) *Node {
    return self.asElement().asNode();
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(TextPositioning);
    pub const Meta = struct {
        pub const name = "SVGTextPositioningElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };
};
