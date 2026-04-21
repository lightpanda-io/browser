// Copyright (C) 2023-2025 Lightpanda Selecy SAS
// SPDX-License-Identifier: AGPL-3.0-or-later

const js = @import("../../../js/js.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const Svg = @import("../Svg.zig");
const String = @import("../../../../string.zig").String;

const SvgStyle = @This();

_proto: *Svg,

pub fn asElement(self: *SvgStyle) *Element {
    return self._proto._proto;
}
pub fn asNode(self: *SvgStyle) *Node {
    return self.asElement().asNode();
}

fn getStringAttr(element: *const Element, comptime name: []const u8) []const u8 {
    return element.getAttributeSafe(comptime String.wrap(name)) orelse "";
}

pub fn get_type(self: *SvgStyle) []const u8 {
    return getStringAttr(self.asElement(), "type");
}
pub fn get_media(self: *SvgStyle) []const u8 {
    return getStringAttr(self.asElement(), "media");
}
pub fn get_title(self: *SvgStyle) []const u8 {
    return getStringAttr(self.asElement(), "title");
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(SvgStyle);
    pub const Meta = struct {
        pub const name = "SVGStyleElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };
    pub const @"type" = bridge.accessor(SvgStyle.get_type, null, .{});
    pub const media = bridge.accessor(SvgStyle.get_media, null, .{});
    pub const title = bridge.accessor(SvgStyle.get_title, null, .{});
};
