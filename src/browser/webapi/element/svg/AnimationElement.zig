// Copyright (C) 2023-2025 Lightpanda Selecy SAS
// SPDX-License-Identifier: AGPL-3.0-or-later

const js = @import("../../../js/js.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const Svg = @import("../Svg.zig");

const AnimationElement = @This();

_proto: *Svg,

pub fn asElement(self: *AnimationElement) *Element {
    return self._proto._proto;
}
pub fn asNode(self: *AnimationElement) *Node {
    return self.asElement().asNode();
}

pub fn getStartTime(self: *const AnimationElement) f64 {
    _ = self;
    return 0;
}
pub fn getCurrentTime(self: *const AnimationElement) f64 {
    _ = self;
    return 0;
}
pub fn getSimpleDuration(self: *const AnimationElement) f64 {
    _ = self;
    return 0;
}
pub fn beginElement(self: *AnimationElement) void {
    _ = self;
}
pub fn endElement(self: *AnimationElement) void {
    _ = self;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(AnimationElement);

    pub const Meta = struct {
        pub const name = "SVGAnimationElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const getStartTime = bridge.function(AnimationElement.getStartTime, .{});
    pub const getCurrentTime = bridge.function(AnimationElement.getCurrentTime, .{});
    pub const getSimpleDuration = bridge.function(AnimationElement.getSimpleDuration, .{});
    pub const beginElement = bridge.function(AnimationElement.beginElement, .{});
    pub const endElement = bridge.function(AnimationElement.endElement, .{});
};
