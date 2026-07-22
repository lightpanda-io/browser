// Copyright (C) 2023-2026 Lightpanda (Selecy SAS)
// SPDX-License-Identifier: AGPL-3.0-or-later

const js = @import("../../../js/js.zig");
const Frame = @import("../../../Frame.zig");
const text_measure = @import("../../../text_measure.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const AnimatedEnumeration = @import("../../svg/AnimatedEnumeration.zig");
const AnimatedLength = @import("../../svg/AnimatedLength.zig");
const Length = @import("../../svg/Length.zig");
const Graphics = @import("Graphics.zig");

pub const TextPositioning = @import("TextPositioning.zig");
pub const TextPath = @import("TextPath.zig");

const TextContent = @This();
_proto: *Graphics,
_type: Type,

pub const Type = union(enum) {
    positioning: *TextPositioning,
    text_path: *TextPath,
};

pub fn is(self: *TextContent, comptime T: type) ?*T {
    inline for (@typeInfo(Type).@"union".fields) |field| {
        if (@field(Type, field.name) == self._type) {
            if (field.type == *T) return @field(self._type, field.name);
        }
    }
    if (self._type == .positioning) return self._type.positioning.is(T);
    return null;
}

pub fn asElement(self: *TextContent) *Element {
    return self._proto.asElement();
}
pub fn asNode(self: *TextContent) *Node {
    return self.asElement().asNode();
}

fn text(self: *TextContent, frame: *Frame) []const u8 {
    return self.asNode().getTextContentAlloc(frame.local_arena) catch "";
}

fn fontSize(self: *TextContent, frame: *Frame) f64 {
    return Length.fontSizeForElement(self.asElement(), frame);
}

fn getTextLength(self: *TextContent, frame: *Frame) !*AnimatedLength {
    return AnimatedLength.getOrCreate(self.asElement(), .text_length, frame);
}

fn getLengthAdjust(self: *TextContent, frame: *Frame) !*AnimatedEnumeration {
    return AnimatedEnumeration.getOrCreate(self.asElement(), .length_adjust, frame);
}

pub fn getNumberOfChars(self: *TextContent, frame: *Frame) u32 {
    return text_measure.countCodepoints(self.text(frame));
}

pub fn getComputedTextLength(self: *TextContent, frame: *Frame) f64 {
    return text_measure.width(self.text(frame), self.fontSize(frame));
}

pub fn getSubStringLength(self: *TextContent, charnum: u32, nchars: u32, frame: *Frame) !f64 {
    return text_measure.substringWidth(self.text(frame), charnum, nchars, self.fontSize(frame));
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(TextContent);
    pub const Meta = struct {
        pub const name = "SVGTextContentElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const LENGTHADJUST_UNKNOWN = bridge.property(0, .{ .template = true });
    pub const LENGTHADJUST_SPACING = bridge.property(1, .{ .template = true });
    pub const LENGTHADJUST_SPACINGANDGLYPHS = bridge.property(2, .{ .template = true });

    pub const textLength = bridge.accessor(TextContent.getTextLength, null, .{});
    pub const lengthAdjust = bridge.accessor(TextContent.getLengthAdjust, null, .{});
    pub const getNumberOfChars = bridge.function(TextContent.getNumberOfChars, .{});
    pub const getComputedTextLength = bridge.function(TextContent.getComputedTextLength, .{});
    pub const getSubStringLength = bridge.function(TextContent.getSubStringLength, .{});
};
