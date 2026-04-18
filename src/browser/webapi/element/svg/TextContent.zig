// Copyright (C) 2023-2025 Lightpanda Selecy SAS
// SPDX-License-Identifier: AGPL-3.0-or-later

// SVGTextContentElement - 6-level chain:
// EventTarget → Node → Element → Svg → GraphicsElement → TextContent
// TODO: Wire in real TextShaper from src/browser/text/TextShaper.zig once
// FreeType/HarfBuzz build deps are resolved. Currently delegates to
// text_shaper.zig which uses a heuristic fallback. When ready, swap the
// implementation inside text_shaper.zig — no changes needed here.

const std = @import("std");
const js = @import("../../../js/js.zig");
const text_shaper = @import("../../../text/text_shaper.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const Svg = @import("../Svg.zig");
const GraphicsElement = @import("GraphicsElement.zig");
const Page = @import("../../../Page.zig");
const CSSStyleDeclaration = @import("../../css/CSSStyleDeclaration.zig");

const TextContent = @This();

_proto: *GraphicsElement,

pub fn asSvg(self: *TextContent) *Svg {
    return self._proto._proto;
}
pub fn asElement(self: *TextContent) *Element {
    return self.asSvg()._proto;
}
pub fn asNode(self: *TextContent) *Node {
    return self.asElement().asNode();
}

fn parseCssFloat(val: []const u8) f64 {
    // Strip common CSS unit suffixes to get the numeric part.
    var end: usize = val.len;
    while (end > 0 and !std.ascii.isDigit(val[end - 1]) and val[end - 1] != '.') : (end -= 1) {}
    if (end == 0) return 16;
    const num = std.fmt.parseFloat(f64, val[0..end]) catch return 16;
    const suffix = val[end..];
    if (suffix.len > 0) {
        if (suffix[0] == 'e') return num * 16; // em
        if (suffix[0] == 'r') return num * 16; // rem
        if (suffix[0] == '%') return num * 16.0 / 100.0;
        if (suffix[0] == 'p' and suffix.len > 1 and suffix[1] == 't') return num * 4.0 / 3.0; // pt
    }
    return num; // px or unitless
}

fn resolveFontSize(element: *Element, page: *Page) f64 {
    const style = CSSStyleDeclaration.init(element, true, page) catch return 16;
    const val = style.getPropertyValue("font-size", page);
    if (val.len == 0) return 16;
    return parseCssFloat(val);
}

pub fn getNumberOfChars(self: *TextContent, page: *Page) u32 {
    const text = self.asNode().getTextContentAlloc(page.call_arena) catch return 0;
    return @intCast(std.unicode.utf8CountCodepoints(text) catch 0);
}

pub fn getComputedTextLength(self: *TextContent, page: *Page) f64 {
    const text = self.asNode().getTextContentAlloc(page.call_arena) catch return 0;
    const font_size = resolveFontSize(self.asElement(), page);
    return text_shaper.measureWidth(text, font_size, "sans-serif");
}

pub fn getSubStringLength(self: *TextContent, offset: u32, count: u32, page: *Page) f64 {
    const text = self.asNode().getTextContentAlloc(page.call_arena) catch return 0;
    const font_size = resolveFontSize(self.asElement(), page);
    // Walk codepoints to find byte offsets for offset..offset+count
    var iter = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
    var cp_idx: u32 = 0;
    while (cp_idx < offset) : (cp_idx += 1) {
        if (iter.nextCodepoint() == null) return 0;
    }
    const byte_start = iter.i;
    var remaining = count;
    while (remaining > 0) : (remaining -= 1) {
        if (iter.nextCodepoint() == null) break;
    }
    return text_shaper.measureWidth(text[byte_start..iter.i], font_size, "sans-serif");
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(TextContent);
    pub const Meta = struct {
        pub const name = "SVGTextContentElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };
    pub const getNumberOfChars = bridge.function(TextContent.getNumberOfChars, .{});
    pub const getComputedTextLength = bridge.function(TextContent.getComputedTextLength, .{});
    pub const getSubStringLength = bridge.function(TextContent.getSubStringLength, .{});
};
