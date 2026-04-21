// Copyright (C) 2023-2025 Lightpanda Selecy SAS
// SPDX-License-Identifier: AGPL-3.0-or-later

// SVGTextPathElement - 7-level chain:
// EventTarget → Node → Element → Svg → GraphicsElement → TextContent → TextPath
// NOTE: Factory.zig must handle 7-level chains for this element.

const std = @import("std");
const js = @import("../../../js/js.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const Svg = @import("../Svg.zig");
const TextContent = @import("TextContent.zig");
const String = @import("../../../../string.zig").String;

const TextPath = @This();

_proto: *TextContent,

pub fn asTextContent(self: *TextPath) *TextContent {
    return self._proto;
}
pub fn asSvg(self: *TextPath) *Svg {
    return self._proto.asSvg();
}
pub fn asElement(self: *TextPath) *Element {
    return self._proto.asElement();
}
pub fn asNode(self: *TextPath) *Node {
    return self._proto.asNode();
}

fn getStringAttr(element: *const Element, comptime name: []const u8) []const u8 {
    return element.getAttributeSafe(comptime String.wrap(name)) orelse "";
}

fn getFloatAttr(element: *const Element, comptime name: []const u8) f64 {
    const val = element.getAttributeSafe(comptime String.wrap(name)) orelse return 0;
    // Find end of numeric part (handles units like px, cm, in, etc.)
    var end: usize = 0;
    while (end < val.len) : (end += 1) {
        const c = val[end];
        if (c >= '0' and c <= '9' or c == '.' or ((c == '-' or c == '+') and end == 0)) continue;
        if ((c == 'e' or c == 'E') and end > 0 and end + 1 < val.len and
            (val[end + 1] >= '0' and val[end + 1] <= '9' or val[end + 1] == '-' or val[end + 1] == '+')) {
            end += 1;
            continue;
        }
        break;
    }
    if (end == 0) return 0;
    return std.fmt.parseFloat(f64, val[0..end]) catch 0;
}

pub fn get_href(self: *TextPath) []const u8 {
    return getStringAttr(self.asElement(), "href");
}
pub fn get_startOffset(self: *TextPath) f64 {
    return getFloatAttr(self.asElement(), "startOffset");
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(TextPath);
    pub const Meta = struct {
        pub const name = "SVGTextPathElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };
    pub const href = bridge.accessor(TextPath.get_href, null, .{});
    pub const startOffset = bridge.accessor(TextPath.get_startOffset, null, .{});
};
