// Copyright (C) 2023-2026 Lightpanda (Selecy SAS)
// SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");

const js = @import("../../../js/js.zig");
const Frame = @import("../../../Frame.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const AnimatedLength = @import("../../svg/AnimatedLength.zig");
const PathData = @import("../../svg/PathData.zig");
const Graphics = @import("Graphics.zig");

const ForeignObject = @This();
_proto: *Graphics,

pub fn asElement(self: *ForeignObject) *Element {
    return self._proto.asElement();
}
pub fn asNode(self: *ForeignObject) *Node {
    return self.asElement().asNode();
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(ForeignObject);
    pub const Meta = struct {
        pub const name = "SVGForeignObjectElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const x = bridge.accessor(ForeignObject.getX, null, .{});
    pub const y = bridge.accessor(ForeignObject.getY, null, .{});
    pub const width = bridge.accessor(ForeignObject.getWidth, null, .{});
    pub const height = bridge.accessor(ForeignObject.getHeight, null, .{});
};

pub fn getX(self: *ForeignObject, frame: *Frame) !*AnimatedLength {
    return AnimatedLength.getOrCreate(self.asElement(), .x, frame);
}
pub fn getY(self: *ForeignObject, frame: *Frame) !*AnimatedLength {
    return AnimatedLength.getOrCreate(self.asElement(), .y, frame);
}
pub fn getWidth(self: *ForeignObject, frame: *Frame) !*AnimatedLength {
    return AnimatedLength.getOrCreate(self.asElement(), .width, frame);
}
pub fn getHeight(self: *ForeignObject, frame: *Frame) !*AnimatedLength {
    return AnimatedLength.getOrCreate(self.asElement(), .height, frame);
}

pub fn getBounds(self: *ForeignObject, frame: *Frame) !PathData.Bounds {
    const x = (try self.getX(frame)).getBaseVal().getValue(frame);
    const y = (try self.getY(frame)).getBaseVal().getValue(frame);
    const width = (try self.getWidth(frame)).getBaseVal().getValue(frame);
    const height = (try self.getHeight(frame)).getBaseVal().getValue(frame);
    if (!std.math.isFinite(x) or !std.math.isFinite(y) or
        !std.math.isFinite(width) or !std.math.isFinite(height))
    {
        return .{};
    }
    if (width <= 0 or height <= 0) return .{};
    return .{ .min_x = x, .min_y = y, .max_x = x + width, .max_y = y + height };
}
