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

const Frame = @import("Frame.zig");
const StyleManager = @import("StyleManager.zig");

const Node = @import("webapi/Node.zig");
const Element = @import("webapi/Element.zig");
const TreeWalker = @import("webapi/TreeWalker.zig");
const text_measure = @import("text_measure.zig");
const isAllWhitespace = @import("../string.zig").isAllWhitespace;

// Width flows down (height flows up): a block in normal flow is as wide as
// its containing block.
pub fn boxWidth(self: *Element, owner: *Frame) f64 {
    const style_manager = &owner._style_manager;
    if (style_manager.getCachedLayout(self, .box_width)) |width| {
        return width;
    }
    const fill = StyleManager.fill_check.enter(style_manager);
    defer StyleManager.fill_check.exit(fill);

    const own = self.getElementAxis(owner, .width);
    const width = blk: {
        if (self.isRootContainer()) {
            // html/body return their set value regardless of children.
            break :blk own.value;
        }
        const sizing = style_manager.widthSizing(self);
        if (sizing == .contents) {
            break :blk 0;
        }
        if (style_manager.isFlexRowItem(self)) {
            const row = style_manager.boxParent(self).?;
            // The row's items size each other
            style_manager.setSizesOthers(row);
            const item = flexBase(self, boxWidth(row, owner), owner);
            // Snapped to Chrome's 1/64px layout unit, past the float error
            const shrunk = @round(item.base * (1 - rowShrinkRatio(row, owner)) * 64) / 64;
            var width = @max(item.floor, shrunk);
            if (sizing == .grow and own.explicit == false) {
                width = @max(width, growShare(self, owner));
            }
            break :blk clampWidth(self, width, .box, owner);
        }
        const width = if (own.explicit) own.value else switch (sizing) {
            .fixed => |width| width,
            .percent => |fraction| fraction * containingBlockWidth(self, owner),
            .fill => fillWidth(self, owner),
            .grow, .shrink => shrunk: {
                // The boxes inside it take their width from its content's
                style_manager.setSizesOthers(self);
                break :shrunk @max(own.value, contentWidth(self, .clipped, owner));
            },
            .contents => unreachable,
        };
        break :blk clampWidth(self, width, .box, owner);
    };
    style_manager.setCacheLayout(self, .box_width, width);
    return width;
}

// How a box that clips its overflow counts toward its ancestors' content.
// Out-of-flow boxes take no room in their parent's flow, so they don't size
// it, but they still extend a scroller's scrollable area.
// Text that wraps is as wide as the line it wraps at (see textLineWidth).
pub const ContentMode = enum {
    full,
    clipped,
    // clipped, with wrapping text at its longest word: the least it takes
    min,
    // clipped, with out-of-flow boxes counted
    scrollable,
};

// What the box, with its margins, adds to its parent's content width.
fn widthContribution(self: *Element, comptime mode: ContentMode, owner: *Frame) f64 {
    const style_manager = &owner._style_manager;
    const own = self.getElementAxis(owner, .width);
    const width = if (own.explicit) own.value else switch (style_manager.widthSizing(self)) {
        .fixed => |width| width,
        .shrink, .grow => @max(own.value, contentWidth(self, mode, owner)),
        .percent, .fill => if (mode != .full and style_manager.clipsOverflowX(self)) 0 else contentWidth(self, mode, owner),
        .contents => return contentWidth(self, mode, owner),
    };
    return clampWidth(self, width, .contribution, owner) + style_manager.inlineMargins(self, null);
}

const FlexBase = struct {
    base: f64, // The width before the row shrinks it
    floor: f64, // The least it shrinks to; base when it doesn't shrink
};

// Get a flex row's item hypothetical width and how far it can shrink.
// No flex-basis (yet?)/
fn flexBase(self: *Element, row_width: f64, owner: *Frame) FlexBase {
    const style_manager = &owner._style_manager;
    // Its content decides how the row's other items shrink and grow
    style_manager.setSizesOthers(self);
    const own = self.getElementAxis(owner, .width);
    const width = if (own.explicit) own.value else switch (style_manager.widthSizing(self)) {
        .fixed => |width| width,
        .percent => |fraction| fraction * row_width,
        .shrink, .grow, .fill => @max(own.value, contentWidth(self, .full, owner)),
        .contents => return .{
            .base = widthContribution(self, .full, owner),
            .floor = widthContribution(self, .min, owner),
        },
    };
    const base = clampWidth(self, width, .box, owner);
    if (style_manager.flexShrinks(self) == false) {
        return .{ .base = base, .floor = base };
    }
    return .{ .base = base, .floor = flexMinWidth(self, base, owner) };
}

// min-width: auto on a flex item: no narrower than its content, or than its
// width if that's narrower; 0 if it clips its overflow (CSS Flexbox §4.5).
// Content its descendants clip doesn't count. A declared min-width replaces
// it, and clampWidth applies that one.
fn flexMinWidth(self: *Element, base: f64, owner: *Frame) f64 {
    const style_manager = &owner._style_manager;
    if (style_manager.widthLimits(self).min != null or style_manager.clipsOverflowX(self)) {
        return 0;
    }
    if (self.getTag().isReplacedOrControl()) {
        // Its intrinsic width is unknown
        return base;
    }
    const own = self.getElementAxis(owner, .width);
    const content = contentWidth(self, .min, owner);
    // An auto width's fallback stands in for an empty box
    return @min(base, if (own.explicit) content else @max(own.value, content));
}

// The fraction of its base each shrinking item of an overflowing flex row
// gives up: the overflow split in proportion to the bases (a flex-shrink is
// 0 or 1 here). Items that would drop below their floor freeze there and the
// rest share what they couldn't give (CSS Flexbox §9.7). A wrapping row moves
// items to a new line instead, so it shrinks nothing.
fn rowShrinkRatio(self: *Element, owner: *Frame) f64 {
    const style_manager = &owner._style_manager;
    style_manager.setSizesOthers(self);
    if (style_manager.flexWraps(self)) {
        return 0;
    }
    if (style_manager.getCachedLayout(self, .row_shrink)) |ratio| {
        return ratio;
    }
    const fill = StyleManager.fill_check.enter(style_manager);
    defer StyleManager.fill_check.exit(fill);

    const row_width = boxWidth(self, owner);
    var total: f64 = 0;
    var items: TreeWalker.FlatChildren = .init(self.asNode(), .{ .frame = owner });
    while (nextFlexItem(&items, style_manager)) |el| {
        total += flexBase(el, row_width, owner).base + flexItemMargins(el, row_width, style_manager);
    }

    var ratio: f64 = 0;
    const overflow = total - row_width;
    if (overflow > 0) {
        // Freezing an item leaves more for the others to give, so the ratio
        // only grows between passes and a frozen item stays frozen: each pass
        // freezes at least one more item, or the count holds and it's settled.
        var frozen_before: ?usize = null;
        while (true) {
            var frozen: usize = 0;
            var given: f64 = 0;
            var shrinkable: f64 = 0;
            items = .init(self.asNode(), .{ .frame = owner });
            while (nextFlexItem(&items, style_manager)) |el| {
                const item = flexBase(el, row_width, owner);
                if (item.base <= item.floor) {
                    continue;
                }
                if (item.base * (1 - ratio) < item.floor) {
                    frozen += 1;
                    given += item.base - item.floor;
                } else {
                    shrinkable += item.base;
                }
            }
            ratio = if (shrinkable == 0) 1 else std.math.clamp((overflow - given) / shrinkable, 0, 1);
            if (frozen_before) |previous| {
                if (frozen <= previous) break;
            }
            frozen_before = frozen;
        }
    }
    style_manager.setCacheLayout(self, .row_shrink, ratio);
    return ratio;
}

// The next child of a flex row that is one of its items: rendered and in flow.
fn nextFlexItem(children: *TreeWalker.FlatChildren, style_manager: *StyleManager) ?*Element {
    while (children.next()) |node| {
        const el = node.is(Element) orelse continue;
        if (style_manager.hasDisplayNone(el) or style_manager.isFlexRowItem(el) == false) {
            continue;
        }
        return el;
    }
    return null;
}

// display: contents has no margins; its children's are in its contribution.
fn flexItemMargins(el: *Element, row_width: f64, style_manager: *StyleManager) f64 {
    if (style_manager.widthSizing(el) == .contents) {
        return 0;
    }
    return style_manager.inlineMargins(el, row_width);
}

// max-width caps the width, min-width wins over both.
fn clampWidth(self: *Element, width: f64, comptime of: enum { box, contribution }, owner: *Frame) f64 {
    const limits = owner._style_manager.widthLimits(self);
    var clamped = width;
    if (limits.max) |max| {
        clamped = @min(clamped, resolveWidthLimit(self, max, of == .box, owner) orelse clamped);
    }
    if (limits.min) |min| {
        clamped = @max(clamped, resolveWidthLimit(self, min, of == .box, owner) orelse clamped);
    }
    return clamped;
}

fn resolveWidthLimit(self: *Element, limit: StyleManager.BoxLength, resolve_percent: bool, owner: *Frame) ?f64 {
    return switch (limit) {
        .px => |px| px,
        .percent => |fraction| if (resolve_percent) fraction * containingBlockWidth(self, owner) else null,
    };
}

// A block in normal flow fills its containing block, less its margins; a
// positioned box pinned on both sides, less its offsets too.
fn fillWidth(self: *Element, owner: *Frame) f64 {
    const style_manager = &owner._style_manager;
    const containing = containingBlockWidth(self, owner);
    return @max(0, containing - style_manager.inlineMargins(self, containing) - style_manager.inlineInsets(self, containing));
}

/// The width of the containing block; the viewport above the root.
fn containingBlockWidth(self: *Element, owner: *Frame) f64 {
    const parent = owner._style_manager.containingBlock(self) orelse {
        return @floatFromInt(owner.page.getViewport().width);
    };
    return boxWidth(parent, owner);
}

/// A growing flex item's share: the row's free space, after the siblings
/// that don't grow and everyone's margins, split evenly among those that do.
fn growShare(self: *Element, owner: *Frame) f64 {
    const style_manager = &owner._style_manager;
    const parent = style_manager.boxParent(self) orelse return 0;
    style_manager.setSizesOthers(parent);
    const row_width = boxWidth(parent, owner);
    var taken: f64 = 0;
    var growers: f64 = 0;
    var items: TreeWalker.FlatChildren = .init(parent.asNode(), .{ .frame = owner });
    while (nextFlexItem(&items, style_manager)) |el| {
        switch (style_manager.widthSizing(el)) {
            .grow => growers += 1,
            // Its children are the row's items
            .contents => taken += widthContribution(el, .clipped, owner),
            // Only walks up, and the row's width never reads a child's box
            else => taken += boxWidth(el, owner),
        }
        taken += flexItemMargins(el, row_width, style_manager);
    }
    return @max(0, row_width - taken) / @max(1, growers);
}

// The width the children would take unconstrained: the sum of their
// contributions. In a flex row or grid they sit side by side; elsewhere
// block-level children stack, so the widest counts, and inline-level ones
// and text share one line. Boxes on a line never wrap (the dummy layout has
// no line breaking, which keeps the "append until the lane outgrows its
// shell" idiom terminating); only text does.
pub fn contentWidth(self: *Element, comptime mode: ContentMode, owner: *Frame) f64 {
    const kind: StyleManager.LayoutKind = switch (mode) {
        .full => .full_content_width,
        .clipped => .content_width,
        .min => .min_content_width,
        .scrollable => .scrollable_content_width,
    };
    const style_manager = &owner._style_manager;
    if (style_manager.getCachedLayout(self, kind)) |width| {
        return width;
    }
    const fill = StyleManager.fill_check.enter(style_manager);
    defer StyleManager.fill_check.exit(fill);

    const in_row = style_manager.laysOutInRow(self);
    var widest: f64 = 0;
    var line: f64 = 0;
    var text: LineText(mode) = .{ .parent = self };
    var children: TreeWalker.FlatChildren = .init(self.asNode(), .{ .frame = owner });
    while (children.next()) |node| {
        const el = node.is(Element) orelse {
            if (node.is(Node.CData.Text)) |t| {
                text.add(t.ownData(), owner);
            }
            continue;
        };
        if (style_manager.hasDisplayNone(el)) {
            continue;
        }
        if (mode != .scrollable and style_manager.isOutOfFlow(el)) {
            continue;
        }
        const width = widthContribution(el, mode, owner);
        if (in_row or style_manager.isBlockLevel(el) == false) {
            line += width;
        } else {
            widest = @max(widest, line + text.end(), width);
            line = 0;
        }
    }
    const width = @max(widest, line + text.end());
    style_manager.setCacheLayout(self, kind, width);
    return width;
}

// Where el's text wraps, for each mode: never for its full width, at the
// viewport to size a box by it (its containing block's width may be sized by
// this box), between every word for the least it takes, and at its block's
// width for what overflows.
fn textLineWidth(self: *Element, comptime mode: ContentMode, white_space: text_measure.WhiteSpace, owner: *Frame) f64 {
    if (white_space.wrap == false) {
        return std.math.inf(f64);
    }
    return switch (mode) {
        .full => std.math.inf(f64),
        .clipped => @floatFromInt(owner.page.getViewport().width),
        .min => 0,
        .scrollable => {
            const block = owner._style_manager.blockContainer(self) orelse {
                return @floatFromInt(owner.page.getViewport().width);
            };
            return boxWidth(block, owner);
        },
    };
}

/// The text of parent's children on one line, measured as it's added.
pub fn LineText(comptime mode: ContentMode) type {
    return struct {
        parent: *Element,
        // Set up at the first text with content
        wrap: ?text_measure.LineWrap = null,

        const Self = @This();

        pub fn add(self: *Self, data: []const u8, owner: *Frame) void {
            if (self.wrap) |*w| {
                w.add(data);
                return;
            }
            if (isAllWhitespace(data)) {
                return;
            }
            const style_manager = &owner._style_manager;
            const white_space = style_manager.whiteSpace(self.parent);
            self.wrap = .{
                .line_width = textLineWidth(self.parent, mode, white_space, owner),
                .font_size = style_manager.computedFontSize(self.parent),
                .white_space = white_space,
            };
            self.wrap.?.add(data);
        }

        /// The text's width; the next line's text starts afresh.
        pub fn end(self: *Self) f64 {
            const w = self.wrap orelse return 0;
            self.wrap = .{ .line_width = w.line_width, .font_size = w.font_size, .white_space = w.white_space };
            return w.lines().width;
        }

        /// The text's width so far, with the space before what comes next.
        /// The line goes on: more text can follow.
        pub fn widthBefore(self: *const Self) f64 {
            const w = self.wrap orelse return 0;
            return w.lines().width + w.space;
        }
    };
}

/// Height flows up, top flows down. In the flow, a box is never above its
/// parent, nor above an earlier sibling. Offsets are cached from the parent's
/// top, so a height write moves only the siblings below it (see
/// StyleManager.heightWritten). A positioned box then moves from there (see
/// Anchor), along with its subtree.
pub fn boxTop(self: *Element, owner: *Frame) f64 {
    var top: f64 = 0;
    var el = self;
    while (true) {
        if (Anchor.vertical(el, owner)) |anchor| {
            top += anchor.offset;
            el = anchor.base orelse return top;
            continue;
        }
        const parent = el.asNode().flatTreeParentElement(owner) orelse return top;
        top += boxOffset(el, parent, owner) + relativeShift(el, .vertical, owner);
        el = parent;
    }
}

/// The box's top, given its flat-tree parent and the parent's top (for walks
/// that already have them).
pub fn boxTopFrom(self: *Element, parent: ?*Element, parent_top: f64, owner: *Frame) f64 {
    if (Anchor.vertical(self, owner)) |anchor| {
        const base = anchor.base orelse return anchor.offset;
        return boxTop(base, owner) + anchor.offset;
    }
    const p = parent orelse return 0;
    return parent_top + boxOffset(self, p, owner) + relativeShift(self, .vertical, owner);
}

pub const Axis = enum { vertical, horizontal };

/// Where an absolutely positioned or fixed box with an inset on the axis
/// sits: offset from its containing block's edge (base), or from the
/// document's when base is null. It takes no room in the flow, so nothing
/// else moves with it but its subtree. Without an inset it stays where the
/// flow put it.
pub const Anchor = struct {
    offset: f64,
    base: ?*Element,

    pub fn vertical(el: *Element, owner: *Frame) ?Anchor {
        return anchor(el, .vertical, owner);
    }

    pub fn horizontal(el: *Element, owner: *Frame) ?Anchor {
        return anchor(el, .horizontal, owner);
    }

    fn anchor(el: *Element, comptime axis: Axis, owner: *Frame) ?Anchor {
        const style_manager = &owner._style_manager;
        const position = style_manager.position(el);
        if (position != .absolute and position != .fixed) {
            return null;
        }
        const start, const end = switch (axis) {
            .vertical => .{ style_manager.inset(el, .top), style_manager.inset(el, .bottom) },
            .horizontal => .{ style_manager.inset(el, .left), style_manager.inset(el, .right) },
        };
        if (start == null and end == null) {
            return null;
        }

        const base = style_manager.containingBlock(el);
        var offset = if (start) |s|
            resolveInset(s, base, axis, owner)
        else
            containingSize(base, axis, owner) - resolveInset(end.?, base, axis, owner) - boxSize(el, axis, owner);

        if (position == .fixed) {
            // against the viewport, wherever it's scrolled to
            const window = owner.window;
            offset += @floatFromInt(if (axis == .vertical) window.getScrollY() else window.getScrollX());
        }
        return .{ .offset = offset, .base = base };
    }
};

/// How far a relatively positioned box moves from where the flow put it
pub fn relativeShift(el: *Element, comptime axis: Axis, owner: *Frame) f64 {
    const style_manager = &owner._style_manager;
    if (style_manager.position(el) != .relative) {
        return 0;
    }
    const start, const end = switch (axis) {
        .vertical => .{ style_manager.inset(el, .top), style_manager.inset(el, .bottom) },
        .horizontal => .{ style_manager.inset(el, .left), style_manager.inset(el, .right) },
    };
    const base = style_manager.containingBlock(el);
    if (start) |s| {
        return resolveInset(s, base, axis, owner);
    }
    if (end) |e| {
        return -resolveInset(e, base, axis, owner);
    }
    return 0;
}

fn resolveInset(length: StyleManager.BoxLength, base: ?*Element, comptime axis: Axis, owner: *Frame) f64 {
    return switch (length) {
        .px => |px| px,
        .percent => |fraction| fraction * containingSize(base, axis, owner),
    };
}

// The containing block's size on the axis; the viewport's for null
fn containingSize(base: ?*Element, comptime axis: Axis, owner: *Frame) f64 {
    if (base) |b| {
        return boxSize(b, axis, owner);
    }
    const viewport = owner.page.getViewport();
    return @floatFromInt(if (axis == .vertical) viewport.height else viewport.width);
}

fn boxSize(el: *Element, comptime axis: Axis, owner: *Frame) f64 {
    return switch (axis) {
        .vertical => boxHeight(el, owner),
        .horizontal => boxWidth(el, owner),
    };
}

// The box's top, from its parent's top. Caches every sibling's up to it: an
// offset needs only the heights before it, and going on would measure self's
// subtree and everything after it (for body, the whole document).
fn boxOffset(self: *Element, parent: *Element, owner: *Frame) f64 {
    const style_manager = &owner._style_manager;
    if (style_manager.getCachedOffset(self, parent)) |offset| {
        return offset;
    }
    const fill = StyleManager.fill_check.enter(style_manager);
    defer StyleManager.fill_check.exit(fill);

    if (style_manager.laysOutInRow(parent)) {
        // A row's children all sit at its top (see Flow.at): nothing to
        // stack, so nothing to cache.
        return 0;
    }

    var flow: Flow = .{ .in_row = false };
    var next = parent.asNode().flatFirstChild(owner);
    // How many children, from the first, have their offset cached. A failed
    // cache ends it, so a cached prefix never has a hole.
    var position: u32 = 0;
    var placed: u32 = 0;
    if (resumePoint(self, parent, owner)) |point| {
        flow.offset = point.offset;
        next = point.next;
        position = point.position;
        // The siblings replayed up to there keep the offsets they have
        placed = style_manager.getCachedPlaced(parent);
    }
    defer style_manager.setCachePlaced(parent, placed);

    while (next) |node| : (next = node.flatNextSibling(owner)) {
        const el = node.is(Element) orelse continue;
        const offset = flow.at(el, owner);
        if (placed == position) {
            const cached = style_manager.setCacheOffset(el, position, offset);
            if (cached) {
                placed += 1;
            }
        }
        position += 1;
        if (el == self) {
            return offset;
        }
        flow.advance(el, owner);
    }
    return 0;
}

// Where boxOffset's walk can start instead of at the parent's first child.
const ResumePoint = struct {
    next: ?*Node, // the first sibling to place
    position: u32, // its index among the parent's element children
    offset: f64, // Flow.offset there, the line empty
};

// The nearest sibling before self whose cached offset gives the flow's state
// after it, so reading a parent's children in order, or one just appended,
// doesn't stack them all again. Null to start from the first child.
fn resumePoint(self: *Element, parent: *Element, owner: *Frame) ?ResumePoint {
    const style_manager = &owner._style_manager;
    if (style_manager.getCachedPlaced(parent) == 0) {
        return null;
    }
    const self_node = self.asNode();
    if (self_node._flags.assigned_slot or self_node.isOutsideFlatTree()) {
        // Slotted nodes aren't DOM siblings, the others aren't laid out
        return null;
    }

    // A line-level box sits at its line's top whatever the line's height, so
    // the line-level sibling right before it is enough.
    var adjacent = style_manager.isBlockLevel(self) == false;
    var previous = self_node.previousSibling();
    while (previous) |node| : (previous = node.previousSibling()) {
        const el = node.is(Element) orelse continue;
        if (style_manager.isBlockLevel(el) == false) {
            if (adjacent) {
                if (style_manager.getCachedPlacement(el, parent)) |placement| {
                    return .{ .next = node.nextSibling(), .position = placement.position + 1, .offset = placement.offset };
                }
                adjacent = false;
            }
            continue;
        }
        adjacent = false;
        if (style_manager.hasDisplayNone(el)) {
            continue;
        }
        // A block ends its line: the next box goes right below it
        const placement = style_manager.getCachedPlacement(el, parent) orelse continue;
        return .{ .next = node.nextSibling(), .position = placement.position + 1, .offset = placement.offset + boxHeight(el, owner) };
    }
    return null;
}

/// The declared height, else the content's
pub fn boxHeight(self: *Element, owner: *Frame) f64 {
    const style_manager = &owner._style_manager;
    if (style_manager.getCachedLayout(self, .box_height)) |height| {
        return height;
    }
    const fill = StyleManager.fill_check.enter(style_manager);
    defer StyleManager.fill_check.exit(fill);

    const own = self.getElementAxis(owner, .height);
    const height = if (own.explicit or self.isRootContainer()) own.value else @max(own.value, contentHeight(self, owner));
    style_manager.setCacheLayout(self, .box_height, height);
    return height;
}

/// The height the children take
pub fn contentHeight(self: *Element, owner: *Frame) f64 {
    const style_manager = &owner._style_manager;
    if (style_manager.getCachedLayout(self, .content_height)) |height| {
        return height;
    }
    const fill = StyleManager.fill_check.enter(style_manager);
    defer StyleManager.fill_check.exit(fill);

    var wrap: ?text_measure.LineWrap = null;
    // Without a width to wrap at, each text node with content is one line
    // tall, placed like an inline box. Computed on first use.
    var line_height: ?f64 = null;
    const width = self.getElementAxis(owner, .width);
    if (width.explicit) {
        wrap = .{
            .line_width = width.value,
            .font_size = style_manager.computedFontSize(self),
            .white_space = style_manager.whiteSpace(self),
        };
    }

    var flow: Flow = .{ .in_row = style_manager.laysOutInRow(self) };
    var children: TreeWalker.FlatChildren = .init(self.asNode(), .{ .frame = owner });
    while (children.next()) |node| {
        if (node.is(Element)) |el| {
            flow.advance(el, owner);
            continue;
        }
        const text = node.is(Node.CData.Text) orelse continue;
        if (wrap) |*w| {
            w.add(text.ownData());
            continue;
        }
        // Skip the scan once the line is already this tall
        if (line_height) |h| {
            if (flow.line >= h) continue;
        }
        if (isAllWhitespace(text.ownData())) {
            continue;
        }
        const h = line_height orelse blk: {
            // Whole pixels, like the wrapped height
            const h = @ceil(style_manager.computedFontSize(self) * text_measure.LINE_HEIGHT);
            line_height = h;
            break :blk h;
        };
        flow.line = @max(flow.line, h);
    }

    var height = flow.offset + flow.line;
    if (wrap) |w| {
        // Whole pixels, like scroll offsets
        height += @ceil(w.height());
    }
    style_manager.setCacheLayout(self, .content_height, height);
    return height;
}

// A parent's children, laid out top to bottom.
const Flow = struct {
    in_row: bool,
    line: f64 = 0, // The current line's height
    offset: f64 = 0, // The current line's top, from the parent's

    // Where el goes, from the parent's top. Its own height only moves what
    // comes after it.
    fn at(self: *const Flow, el: *Element, owner: *Frame) f64 {
        const style_manager = &owner._style_manager;
        if (self.in_row or style_manager.isBlockLevel(el) == false) {
            return self.offset;
        }
        // A block ends the line and starts below it
        return self.offset + self.line;
    }

    // Moves past el, to where the next box goes
    fn advance(self: *Flow, el: *Element, owner: *Frame) void {
        const style_manager = &owner._style_manager;
        if (style_manager.hasDisplayNone(el) or style_manager.isOutOfFlow(el)) {
            return;
        }
        const height = boxHeight(el, owner);
        if (self.in_row or style_manager.isBlockLevel(el) == false) {
            self.line = @max(self.line, height);
            return;
        }
        self.offset += self.line + height;
        self.line = 0;
    }
};
