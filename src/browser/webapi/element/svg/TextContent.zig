// Copyright (C) 2023-2026  Lightpanda (Selecy SAS)
//
// Francis Bouvier <francis@lightpanda.io>
// Pierre Tachoire <pierre@lightpanda.io>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as
// published by the Free Software Foundation, either version 3 of the
// License, or (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

const std = @import("std");
const lp = @import("lightpanda");

const js = @import("../../../js/js.zig");
const Frame = @import("../../../Frame.zig");
const text_measure = @import("../../../text_measure.zig");
const StyleManager = @import("../../../StyleManager.zig");

const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const Factory = @import("../../../Factory.zig");
const TreeWalker = @import("../../TreeWalker.zig");

const Length = @import("../../svg/Length.zig");
const PathData = @import("../../svg/PathData.zig");
const AnimatedLength = @import("../../svg/AnimatedLength.zig");
const AnimatedEnumeration = @import("../../svg/AnimatedEnumeration.zig");

const SvgElement = @import("../Svg.zig");

const Graphics = @import("Graphics.zig");
pub const TextPath = @import("TextPath.zig");
pub const TextPositioning = @import("TextPositioning.zig");

const TextContent = @This();

pub const Proto = Graphics;
_type: Type,
_proto_canary: if (lp.IS_DEBUG) *Graphics else void = undefined,

pub const Type = enum(u8) {
    positioning,
    text_path,
};

pub fn Subtype(comptime tag: Type) type {
    return switch (tag) {
        .positioning => TextPositioning,
        .text_path => TextPath,
    };
}

pub fn subtype(self: *const TextContent, comptime T: type) *T {
    const offset = comptime Factory.chainOffsetOf(T, T) - Factory.chainOffsetOf(T, TextContent);
    const sub: *T = @ptrFromInt(@intFromPtr(self) + offset);
    if (comptime lp.IS_DEBUG) {
        // This pointer dance only works because the factory allocates the chain
        // in a contiguous block of memory. In debug, we assert this holds via
        // the _proto_canary back pointer.
        std.debug.assert(Factory.protoOf(sub) == self);
    }
    return sub;
}

pub fn is(self: *TextContent, comptime T: type) ?*T {
    switch (self._type) {
        inline else => |tag| {
            if (Subtype(tag) == T) {
                return self.subtype(T);
            }
        },
    }
    if (self._type == .positioning) return self.subtype(TextPositioning).is(T);
    return null;
}

pub fn asElement(self: *TextContent) *Element {
    return Factory.protoOf(self).asElement();
}
pub fn asNode(self: *TextContent) *Node {
    return self.asElement().asNode();
}

fn text(self: *TextContent, frame: *Frame) []const u8 {
    const raw = self.asNode().getTextContentAlloc(frame.local_arena) catch return "";
    return collapseSpaces(raw, self.preservesSpaces(), .both, frame.local_arena) catch "";
}

const Trim = enum { both, start };

// By default, newlines and tabs become spaces. Runs collapse to one. Edges
// are trimmmed. `xml:space="preserve"` only does the first (newlines+tabs => space)
fn collapseSpaces(raw: []const u8, preserve: bool, trim: Trim, allocator: std.mem.Allocator) ![]const u8 {
    const out = try allocator.alloc(u8, raw.len);
    var len: usize = 0;
    for (raw) |c| {
        const char: u8 = switch (c) {
            '\n', '\r', '\t' => ' ',
            else => c,
        };
        if (preserve == false and char == ' ' and (len == 0 or out[len - 1] == ' ')) {
            continue;
        }
        out[len] = char;
        len += 1;
    }
    if (preserve == false and trim == .both and len > 0 and out[len - 1] == ' ') {
        len -= 1;
    }
    return out[0..len];
}

fn preservesSpaces(self: *TextContent) bool {
    var current: ?*Element = self.asElement();
    while (current) |element| : (current = element.parentElement()) {
        const value = element.getAttributeSafe(comptime .wrap("xml:space")) orelse continue;
        return std.mem.eql(u8, value, "preserve");
    }
    return false;
}

/// The box the deterministic text model gives this element: glyphs start at
/// the first x/y, shifted by the first dx/dy and by text-anchor, and advance
/// along the baseline. Per-glyph positions, textPath geometry and bidi are not
/// modelled.
pub fn getBounds(self: *TextContent, frame: *Frame) PathData.Bounds {
    const element = self.asElement();
    if (element.asNode().isConnected() == false) {
        // without a layout box, there is no geometry
        return .{};
    }
    const owner = element.ownerFrame(frame) orelse return .{};
    if (owner._style_manager.rendering(element) == .none) {
        return .{};
    }

    const content = self.text(frame);
    if (content.len == 0) {
        return .{};
    }
    const font_size = self.fontSize(frame);
    const width = text_measure.width(content, font_size);
    const origin = self.baselineOrigin(width, frame);
    return .{
        .min_x = origin.x,
        .min_y = origin.y - font_size * text_measure.ASCENT,
        .max_x = origin.x + width,
        .max_y = origin.y + font_size * text_measure.DESCENT,
    };
}

/// Where the first glyph sits on the baseline. A <tspan> or <textPath> without
/// its own x/y continues its <text>, after the text that precedes it.
fn baselineOrigin(self: *TextContent, width: f64, frame: *Frame) PathData.Point {
    const element = self.asElement();
    const own_x = firstLength(element, "x", .horizontal, frame);
    const own_y = firstLength(element, "y", .vertical, frame);
    const dx = firstLength(element, "dx", .horizontal, frame) orelse 0;
    const dy = firstLength(element, "dy", .vertical, frame) orelse 0;

    const root = self.textRoot();
    if (root == self) {
        return .{
            .x = (own_x orelse 0) + dx - anchorShift(element, width, frame),
            .y = (own_y orelse 0) + dy,
        };
    }

    const root_width = text_measure.width(root.text(frame), root.fontSize(frame));
    const root_origin = root.baselineOrigin(root_width, frame);
    const x = if (own_x) |value|
        value - anchorShift(element, width, frame)
    else
        root_origin.x + self.precedingWidth(root, frame);
    return .{ .x = x + dx, .y = (own_y orelse root_origin.y) + dy };
}

/// The outermost text content element this one is nested in, or itself.
fn textRoot(self: *TextContent) *TextContent {
    var root = self;
    var parent = self.asElement().parentElement();
    while (parent) |element| : (parent = element.parentElement()) {
        if (element._namespace != .svg) {
            break;
        }
        const graphics = element.as(SvgElement).is(Graphics) orelse break;
        root = graphics.is(TextContent) orelse break;
    }
    return root;
}

/// Advance of the text in `root` that comes before this element.
fn precedingWidth(self: *TextContent, root: *TextContent, frame: *Frame) f64 {
    var preceding: std.Io.Writer.Allocating = .init(frame.local_arena);
    const stop = self.asNode();
    var walker = TreeWalker.FullExcludeSelf.init(root.asNode(), .{});
    while (walker.next()) |node| {
        if (node == stop) {
            break;
        }
        const text_node = node.is(Node.CData.Text) orelse continue;
        preceding.writer.writeAll(text_node.asCData()._data.str()) catch return 0;
    }
    const collapsed = collapseSpaces(preceding.written(), root.preservesSpaces(), .start, frame.local_arena) catch return 0;
    return text_measure.width(collapsed, root.fontSize(frame));
}

/// The first entry of a length-list attribute such as x="10 20 30".
fn firstLength(element: *Element, comptime name: []const u8, direction: Length.Direction, frame: *Frame) ?f64 {
    const raw = element.getAttributeSafe(comptime .wrap(name)) orelse return null;
    var entries = std.mem.tokenizeAny(u8, raw, " \t\r\n,");
    const first = entries.next() orelse return null;
    const value = Length.resolve(first, element, direction, frame) orelse return null;
    return if (std.math.isFinite(value)) value else null;
}

/// How far text-anchor moves a run of `width` back from its x. Like
/// computedFontSize, only inline styles and attributes are consulted.
fn anchorShift(element: *Element, width: f64, frame: *Frame) f64 {
    const owner = element.ownerFrame(frame) orelse return 0;
    const style_manager = &owner._style_manager;
    var current: ?*Element = element;
    while (current) |el| : (current = el.asNode().flatTreeParentElement(owner)) {
        const raw = style_manager.inlineStyleValue(el, comptime .wrap("text-anchor")) orelse
            el.getAttributeSafe(comptime .wrap("text-anchor")) orelse continue;
        const value = std.mem.trim(u8, raw, " \t\r\n\x0c");
        if (std.ascii.eqlIgnoreCase(value, "start")) {
            return 0;
        }
        if (std.ascii.eqlIgnoreCase(value, "middle")) {
            return width / 2;
        }
        if (std.ascii.eqlIgnoreCase(value, "end")) {
            return width;
        }
        // inherit, or a value the cascade would drop: keep looking up.
    }
    return 0;
}

fn fontSize(self: *TextContent, frame: *Frame) f64 {
    const element = self.asElement();
    const owner = element.ownerFrame(frame) orelse return StyleManager.DEFAULT_FONT_SIZE;
    return owner._style_manager.computedFontSize(element);
}

fn getTextLength(self: *TextContent, frame: *Frame) !*AnimatedLength {
    return AnimatedLength.getOrCreate(self.asElement(), .text_length, frame);
}

fn getLengthAdjust(self: *TextContent, frame: *Frame) !*AnimatedEnumeration {
    return AnimatedEnumeration.getOrCreate(self.asElement(), .length_adjust, frame);
}

fn getNumberOfChars(self: *TextContent, frame: *Frame) u32 {
    return text_measure.utf16Length(self.text(frame));
}

fn getComputedTextLength(self: *TextContent, frame: *Frame) f64 {
    return text_measure.width(self.text(frame), self.fontSize(frame));
}

fn getSubStringLength(self: *TextContent, charnum: u32, nchars: u32, frame: *Frame) !f64 {
    return text_measure.substringWidth(self.text(frame), charnum, nchars, self.fontSize(frame));
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(TextContent);
    pub const Meta = struct {
        pub const name = "SVGTextContentElement";
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
