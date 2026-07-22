// Copyright (C) 2023-2026 Lightpanda (Selecy SAS)
// SPDX-License-Identifier: AGPL-3.0-or-later

const js = @import("../../../js/js.zig");
const Frame = @import("../../../Frame.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const Svg = @import("../Svg.zig");
const AnimatedNumber = @import("../../svg/AnimatedNumber.zig");

const Stop = @This();
_proto: *Svg,

pub fn asElement(self: *Stop) *Element {
    return self._proto.asElement();
}
pub fn asNode(self: *Stop) *Node {
    return self.asElement().asNode();
}

fn getOffset(self: *Stop, frame: *Frame) !*AnimatedNumber {
    return AnimatedNumber.getOrCreatePercentage(self.asElement(), frame);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Stop);
    pub const Meta = struct {
        pub const name = "SVGStopElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };
    pub const offset = bridge.accessor(Stop.getOffset, null, .{});
};
