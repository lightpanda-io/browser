// Copyright (C) 2023-2025 Lightpanda Selecy SAS
// SPDX-License-Identifier: AGPL-3.0-or-later

const js = @import("../../../js/js.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const Svg = @import("../Svg.zig");
const String = @import("../../../../string.zig").String;

const ClipPath = @This();

_proto: *Svg,

pub fn asElement(self: *ClipPath) *Element {
    return self._proto._proto;
}
pub fn asNode(self: *ClipPath) *Node {
    return self.asElement().asNode();
}

pub fn get_clipPathUnits(self: *ClipPath) []const u8 {
    return self.asElement().getAttributeSafe(String.wrap("clipPathUnits")) orelse "";
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(ClipPath);
    pub const Meta = struct {
        pub const name = "SVGClipPathElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };
    pub const clipPathUnits = bridge.accessor(ClipPath.get_clipPathUnits, null, .{});
};
