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
        const edges: Edges = .of(self, .width, true, owner);
        if (style_manager.gridOf(self)) |grid| {
            const width = if (own.explicit) edges.outer(own.value) else gridItemWidth(self, grid, owner);
            break :blk clampWidth(self, width, .box, edges, owner);
        }
        if (style_manager.isFlexRowItem(self)) {
            const row = style_manager.boxParent(self).?;
            // The row's items size each other
            style_manager.setSizesOthers(row);
            const item = flexBase(self, innerWidth(row, owner), owner);
            // Snapped to Chrome's 1/64px layout unit, past the float error
            const shrunk = @round(item.base * (1 - rowShrinkRatio(row, owner)) * 64) / 64;
            var width = @max(item.floor, shrunk);
            if (sizing == .grow and own.explicit == false) {
                width = @max(width, growShare(self, owner));
            }
            break :blk clampWidth(self, width, .box, edges, owner);
        }
        const width = if (own.explicit) edges.outer(own.value) else switch (sizing) {
            .fixed => |width| edges.outer(width),
            .percent => |percent| edges.outer(@max(0, percent.of(containingBlockWidth(self, owner)))),
            .fill => fillWidth(self, owner),
            .grow, .shrink => shrunk: {
                // The boxes inside it take their width from its content's
                style_manager.setSizesOthers(self);
                break :shrunk @max(own.value, contentWidth(self, .clipped, owner) + edges.padding);
            },
            .contents => unreachable,
        };
        break :blk clampWidth(self, width, .box, edges, owner);
    };
    style_manager.setCacheLayout(self, .box_width, width);
    return width;
}

// The padding on an axis's two sides together, and the box a declared size
// is. Borders aren't modelled, so the padding is all there is between a
// content box and its border box. Every size here is a border box's: the
// content sits inside it at contentStart.
const Edges = struct {
    padding: f64,
    border_box: bool,

    // A percentage is of the containing block's width. A box's contribution
    // to that width can't read it: the percentage is 0 there.
    fn of(el: *Element, comptime axis: Element.Axis, resolve_percent: bool, owner: *Frame) Edges {
        const style_manager = &owner._style_manager;
        const edges = style_manager.boxEdges(el, axis);
        var padding = edges.padding.px;
        if (resolve_percent and edges.padding.fraction != 0) {
            if (axis == .height) {
                style_manager.setHeightReadsWidth(el);
            }
            padding = edges.padding.of(containingBlockWidth(el, owner));
        }
        return .{ .padding = @max(0, padding), .border_box = edges.border_box };
    }

    // A declared size, as the border box's: one narrower than its padding
    // is all padding
    fn outer(self: Edges, size: f64) f64 {
        return if (self.border_box) @max(size, self.padding) else size + self.padding;
    }

    // A border box's size, as the content box's
    fn inner(self: Edges, size: f64) f64 {
        return @max(0, size - self.padding);
    }
};

/// The width of the box's content box: what its children fill, and where
/// its text wraps.
pub fn innerWidth(self: *Element, owner: *Frame) f64 {
    return Edges.of(self, .width, true, owner).inner(boxWidth(self, owner));
}

/// How far the box's children start from its left (.width) or top (.height)
/// edge: its padding on that side. One with no box (display: contents) has
/// no padding to put them in.
pub fn contentStart(self: *Element, comptime axis: Element.Axis, owner: *Frame) f64 {
    const style_manager = &owner._style_manager;
    const padding = style_manager.paddingStart(self, axis);
    if (padding.fraction == 0 and padding.px == 0) {
        return 0;
    }
    if (style_manager.boxElement(self) != self) {
        return 0;
    }
    if (padding.fraction == 0) {
        return padding.px;
    }
    return @max(0, padding.of(containingBlockWidth(self, owner)));
}

/// The box's size as getComputedStyle resolves it: the box `box-sizing` names.
pub fn declaredBoxSize(self: *Element, comptime axis: Element.Axis, owner: *Frame) f64 {
    const size = switch (axis) {
        .width => boxWidth(self, owner),
        .height => boxHeight(self, owner),
    };
    if (self.isRootContainer()) {
        return size;
    }
    const edges: Edges = .of(self, axis, true, owner);
    return if (edges.border_box) size else edges.inner(size);
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
    const sizing = style_manager.widthSizing(self);
    if (own.explicit == false and sizing == .contents) {
        return contentWidth(self, mode, owner);
    }
    const edges: Edges = .of(self, .width, false, owner);
    const width = if (own.explicit) edges.outer(own.value) else switch (sizing) {
        .fixed => |width| edges.outer(width),
        .shrink, .grow => @max(own.value, contentWidth(self, mode, owner) + edges.padding),
        .percent, .fill => edges.padding + if (mode != .full and style_manager.clipsOverflowX(self)) 0 else contentWidth(self, mode, owner),
        .contents => unreachable,
    };
    return clampWidth(self, width, .contribution, edges, owner) + style_manager.inlineMargins(self, null);
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
    const sizing = style_manager.widthSizing(self);
    if (own.explicit == false and sizing == .contents) {
        return .{
            .base = widthContribution(self, .full, owner),
            .floor = widthContribution(self, .min, owner),
        };
    }
    const edges: Edges = .of(self, .width, true, owner);
    const width = if (own.explicit) edges.outer(own.value) else switch (sizing) {
        .fixed => |width| edges.outer(width),
        .percent => |percent| edges.outer(@max(0, percent.of(row_width))),
        .shrink, .grow, .fill => @max(own.value, contentWidth(self, .full, owner) + edges.padding),
        .contents => unreachable,
    };
    const base = clampWidth(self, width, .box, edges, owner);
    if (style_manager.flexShrinks(self) == false) {
        return .{ .base = base, .floor = base };
    }
    return .{ .base = base, .floor = flexMinWidth(self, base, edges.padding, owner) };
}

// min-width: auto on a flex item: no narrower than its content, or than its
// width if that's narrower; 0 if it clips its overflow (CSS Flexbox §4.5).
// Content its descendants clip doesn't count. A declared min-width replaces
// it, and clampWidth applies that one. Its padding never shrinks.
fn flexMinWidth(self: *Element, base: f64, padding: f64, owner: *Frame) f64 {
    const style_manager = &owner._style_manager;
    if (style_manager.widthLimits(self).min != null or style_manager.clipsOverflowX(self)) {
        return @min(base, padding);
    }
    if (self.getTag().isReplacedOrControl()) {
        // Its intrinsic width is unknown
        return base;
    }
    const own = self.getElementAxis(owner, .width);
    const content = contentWidth(self, .min, owner) + padding;
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

    const row_width = innerWidth(self, owner);
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

// max-width caps the width, min-width wins over both. Like the width, they
// limit the box `box-sizing` names.
fn clampWidth(self: *Element, width: f64, comptime of: enum { box, contribution }, edges: Edges, owner: *Frame) f64 {
    const limits = owner._style_manager.widthLimits(self);
    var clamped = width;
    if (limits.max) |max| {
        clamped = @min(clamped, resolveWidthLimit(self, max, of == .box, edges, owner) orelse clamped);
    }
    if (limits.min) |min| {
        clamped = @max(clamped, resolveWidthLimit(self, min, of == .box, edges, owner) orelse clamped);
    }
    return clamped;
}

fn resolveWidthLimit(self: *Element, limit: StyleManager.BoxLength, resolve_percent: bool, edges: Edges, owner: *Frame) ?f64 {
    return edges.outer(switch (limit) {
        // a calc() can go below 0, a limit can't
        .px => |px| @max(0, px),
        .percent => |percent| if (resolve_percent) @max(0, percent.of(containingBlockWidth(self, owner))) else return null,
    });
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
    const style_manager = &owner._style_manager;
    const parent = style_manager.containingBlock(self) orelse {
        return @floatFromInt(owner.page.getViewport().width);
    };
    if (style_manager.position(self) == .absolute) {
        // Its padding box, which without borders is the whole box
        return boxWidth(parent, owner);
    }
    return innerWidth(parent, owner);
}

/// A growing flex item's share: the row's free space, after the siblings
/// that don't grow and everyone's margins, split evenly among those that do.
fn growShare(self: *Element, owner: *Frame) f64 {
    const style_manager = &owner._style_manager;
    const parent = style_manager.boxParent(self) orelse return 0;
    style_manager.setSizesOthers(parent);
    const row_width = innerWidth(parent, owner);
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
        const role = style_manager.flowRole(el);
        if (role == .none) {
            continue;
        }
        if (mode != .scrollable and role == .out_of_flow) {
            continue;
        }
        const width = widthContribution(el, mode, owner);
        if (in_row or role != .block) {
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
            return innerWidth(block, owner);
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

/// boxTopFrom, for a walk that already read the box's position: one in the
/// flow has no anchor and no shift to look for.
pub fn boxTopAt(self: *Element, position: StyleManager.Position, parent: ?*Element, parent_top: f64, owner: *Frame) f64 {
    switch (position) {
        .static, .sticky => {
            const p = parent orelse return 0;
            return parent_top + boxOffset(self, p, owner);
        },
        .relative, .absolute, .fixed => return boxTopFrom(self, parent, parent_top, owner),
    }
}

pub const Origin = struct {
    x: f64 = 0,
    y: f64 = 0,

    fn plus(self: Origin, other: Origin) Origin {
        return .{ .x = self.x + other.x, .y = self.y + other.y };
    }
};

/// The box's top-left in document coordinates: boxTop and
/// Element.horizontalPosition in one walk up, reading each box's style once.
/// Its parent's origin is kept (StyleManager.originMemo), so reading every
/// child of one parent walks the ancestors once.
pub fn boxOrigin(self: *Element, owner: *Frame, frame: *Frame) Origin {
    const style_manager = &owner._style_manager;
    const own = originStep(self, self, owner, frame);
    var next = own.up orelse return own.delta;
    if (style_manager.originMemo(next)) |memo| {
        return own.delta.plus(.{ .x = memo.x, .y = memo.y });
    }
    const memo_el = next;
    var rest: Origin = .{};
    while (true) {
        const step = originStep(next, self, owner, frame);
        rest = rest.plus(step.delta);
        next = step.up orelse break;
    }
    style_manager.setOriginMemo(memo_el, rest.x, rest.y);
    return own.delta.plus(rest);
}

const OriginStep = struct {
    delta: Origin,
    // where the walk goes on, both axes; null when delta is the rest of it
    up: ?*Element,
};

// el's top-left from the box the walk goes on to: its parent's, or its
// containing block's for a box positioned on both axes. A box positioned on
// one axis only goes on to a different box on each: the rest of the walk is
// then each axis' own.
fn originStep(el: *Element, self: *Element, owner: *Frame, frame: *Frame) OriginStep {
    const style_manager = &owner._style_manager;
    var delta: Origin = .{};
    switch (style_manager.position(el)) {
        .static, .sticky => {},
        .relative => {
            delta.x = relativeShift(el, .horizontal, owner);
            delta.y = relativeShift(el, .vertical, owner);
        },
        .absolute, .fixed => {
            const vertical = Anchor.vertical(el, owner);
            const horizontal = Anchor.horizontal(el, owner);
            if (vertical != null and horizontal != null) {
                // Both against its containing block
                return .{
                    .delta = .{ .x = el.translateX(frame) + horizontal.?.offset, .y = vertical.?.offset },
                    .up = vertical.?.base,
                };
            }
            if (vertical != null or horizontal != null) {
                return .{ .delta = .{ .x = el.horizontalPosition(frame), .y = boxTop(el, owner) }, .up = null };
            }
        },
    }
    delta.x += el.translateX(frame);

    const parent = el.asNode().flatTreeParentElement(owner) orelse return .{ .delta = delta, .up = null };
    delta.y += boxOffset(el, parent, owner);
    delta.x += contentStart(parent, .width, owner);
    const alongside = style_manager.alongside(el);
    if (alongside == .grid) {
        delta.x += gridItemLeft(el, parent, owner);
    } else if (Element.LineCursor.Mode.from(alongside)) |mode| {
        if (el == self) {
            // Its own line is the one a caller reads child after child; an
            // ancestor's would take the one slot from it
            delta.x += Element.LineCursor.resumed(parent.asNode(), mode, el.asNode(), owner, frame);
        } else {
            var cursor: Element.LineCursor = .init(parent.asNode(), mode, frame);
            delta.x += cursor.offsetOf(el.asNode(), owner);
        }
    }
    return .{ .delta = delta, .up = parent };
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
            .vertical => style_manager.insets(el, .top, .bottom),
            .horizontal => style_manager.insets(el, .left, .right),
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
        .vertical => style_manager.insets(el, .top, .bottom),
        .horizontal => style_manager.insets(el, .left, .right),
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
        .percent => |percent| percent.of(containingSize(base, axis, owner)),
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

// The box's top, from its parent's top: inside the parent's padding, where
// the flow puts it. Caches every sibling's up to it: an offset needs only the
// heights before it, and going on would measure self's subtree and everything
// after it (for body, the whole document). What's cached includes the
// padding, which a padding change drops along with the offsets.
fn boxOffset(self: *Element, parent: *Element, owner: *Frame) f64 {
    const style_manager = &owner._style_manager;
    if (style_manager.getCachedOffset(self, parent)) |offset| {
        return offset;
    }
    const fill = StyleManager.fill_check.enter(style_manager);
    defer StyleManager.fill_check.exit(fill);

    const start = contentStart(parent, .height, owner);
    var flow: Flow = .of(parent, owner);
    if (flow.mode == .row) {
        // A row's children all sit at its content's top (see Flow.at):
        // nothing to stack, so nothing to cache.
        return start;
    }

    var next = parent.asNode().flatFirstChild(owner);
    // How many children, from the first, have their offset cached. A failed
    // cache ends it, so a cached prefix never has a hole.
    var position: u32 = 0;
    var placed: u32 = 0;
    const resume_point = switch (flow.mode) {
        .grid => gridResumePoint(self, parent, owner),
        else => resumePoint(self, parent, owner),
    };
    if (resume_point) |point| {
        // From cached offsets, which include the padding
        flow.offset = point.offset - start;
        next = point.next;
        position = point.position;
        // The siblings replayed up to there keep the offsets they have
        placed = style_manager.getCachedPlaced(parent);
    }
    defer style_manager.setCachePlaced(parent, placed);

    while (next) |node| : (next = node.flatNextSibling(owner)) {
        const el = node.is(Element) orelse continue;
        if (comptime lp.IS_TEST) {
            style_manager.offset_steps += 1;
        }
        const role = style_manager.flowRole(el);
        const offset = start + flow.at(el, role, owner);
        if (placed == position) {
            const cached = style_manager.setCacheOffset(el, position, offset, flow.columnOf(el));
            if (cached) {
                placed += 1;
            }
        }
        position += 1;
        if (el == self) {
            return offset;
        }
        flow.advance(el, role, owner);
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
    // the sibling right before it that isn't a block is enough: Flow.at puts
    // that one at the line's top too.
    var adjacent = style_manager.flowRole(self) != .block;
    var previous = self_node.previousSibling();
    while (previous) |node| : (previous = node.previousSibling()) {
        const el = node.is(Element) orelse continue;
        if (style_manager.flowRole(el) != .block) {
            if (adjacent) {
                if (style_manager.getCachedPlacement(el, parent)) |placement| {
                    return .{ .next = node.nextSibling(), .position = placement.position + 1, .offset = placement.offset };
                }
                adjacent = false;
            }
            continue;
        }
        adjacent = false;
        // A block ends its line: the next box goes right below it
        const placement = style_manager.getCachedPlacement(el, parent) orelse continue;
        return .{ .next = node.nextSibling(), .position = placement.position + 1, .offset = placement.offset + boxHeight(el, owner) };
    }
    return null;
}

// A grid's items share their row's top, whatever their heights: the walk
// resumes at the first item of the row the nearest placed sibling before self
// is on, with the row empty (see Flow.grid). An item starts a row when the
// placed item before it has another top, or there's none.
fn gridResumePoint(self: *Element, parent: *Element, owner: *Frame) ?ResumePoint {
    const style_manager = &owner._style_manager;
    if (style_manager.getCachedPlaced(parent) == 0) {
        return null;
    }
    const self_node = self.asNode();
    if (self_node._flags.assigned_slot or self_node.isOutsideFlatTree()) {
        // Slotted nodes aren't DOM siblings, the others aren't laid out
        return null;
    }

    // A hidden or out-of-flow child is placed at the top of the row the walk
    // is on (Flow.at), so it never splits one
    var row_start: ?ResumePoint = null;
    var previous = self_node.previousSibling();
    while (previous) |node| : (previous = node.previousSibling()) {
        const el = node.is(Element) orelse continue;
        const placement = style_manager.getCachedPlacement(el, parent) orelse {
            if (row_start != null) {
                // The cached prefix ends nowhere but at its start
                break;
            }
            continue;
        };
        if (row_start) |start| {
            if (placement.offset != start.offset) {
                break;
            }
        }
        row_start = .{ .next = node, .position = placement.position, .offset = placement.offset };
    }
    return row_start;
}

/// The declared height, else the content's (within min-height and max-height)
pub fn boxHeight(self: *Element, owner: *Frame) f64 {
    const style_manager = &owner._style_manager;
    // Both in one read: a box without its height usually lacks its content's
    const cached = style_manager.getCachedHeights(self);
    if (cached.box) |height| {
        return height;
    }
    const fill = StyleManager.fill_check.enter(style_manager);
    defer StyleManager.fill_check.exit(fill);

    const own = self.getElementAxis(owner, .height);
    if (self.isRootContainer()) {
        style_manager.setCacheLayout(self, .box_height, own.value);
        return own.value;
    }
    const edges: Edges = .of(self, .height, true, owner);
    if (own.explicit) {
        const height = clampHeight(self, edges.outer(own.value), edges, owner);
        style_manager.setCacheLayout(self, .box_height, height);
        return height;
    }
    const content = cached.content orelse measureContentHeight(self, owner);
    // The fallback stands in for an empty box, padding included
    const height = clampHeight(self, @max(own.value, content + edges.padding), edges, owner);
    style_manager.setCacheHeights(self, content, height);
    return height;
}

// Like the height, the limits are of the box `box-sizing` names
fn clampHeight(self: *Element, height: f64, edges: Edges, owner: *Frame) f64 {
    const limits = owner._style_manager.heightLimits(self);
    var clamped = height;
    if (limits.max) |max| {
        // max-height clamps the height
        clamped = @min(clamped, edges.outer(max));
    }
    if (limits.min) |min| {
        // min-height has the final say
        clamped = @max(clamped, edges.outer(min));
    }
    return clamped;
}

/// The height the children take
pub fn contentHeight(self: *Element, owner: *Frame) f64 {
    const style_manager = &owner._style_manager;
    if (style_manager.getCachedLayout(self, .content_height)) |height| {
        return height;
    }
    const fill = StyleManager.fill_check.enter(style_manager);
    defer StyleManager.fill_check.exit(fill);

    const height = measureContentHeight(self, owner);
    style_manager.setCacheLayout(self, .content_height, height);
    return height;
}

// contentHeight, without the memo: the caller caches it
fn measureContentHeight(self: *Element, owner: *Frame) f64 {
    const style_manager = &owner._style_manager;

    // Text wraps at a declared width. An inline box's text wraps with its
    // line's, which isn't modelled: each text node with content is one line
    // tall, placed like an inline box. Any other box's text wraps at the
    // width layout gives it. All read at the first text: a box without text
    // needs no width.
    var wrap: ?text_measure.LineWrap = null;
    var declared_read = false;
    var wraps_at_box: ?bool = null;
    var line_height: ?f64 = null;

    var flow: Flow = .of(self, owner);
    var children: TreeWalker.FlatChildren = .init(self.asNode(), .{ .frame = owner });
    while (children.next()) |node| {
        if (node.is(Element)) |el| {
            const role = style_manager.flowRole(el);
            if (wrap) |*w| {
                // The text so far is the lines above a block
                if (flow.mode == .block and role == .block) {
                    flow.line = @max(flow.line, w.wrappedHeight());
                    w.* = .{ .line_width = w.line_width, .font_size = w.font_size, .white_space = w.white_space };
                }
            }
            flow.advance(el, role, owner);
            continue;
        }
        const text = node.is(Node.CData.Text) orelse continue;
        if (declared_read == false) {
            declared_read = true;
            const width = self.getElementAxis(owner, .width);
            if (width.explicit) {
                // A percentage padding isn't read: the height would follow
                // the containing block's width
                const edges: Edges = .of(self, .width, false, owner);
                wrap = .{
                    .line_width = if (edges.border_box) edges.inner(width.value) else width.value,
                    .font_size = style_manager.computedFontSize(self),
                    .white_space = style_manager.whiteSpace(self),
                };
            }
        }
        if (wrap) |*w| {
            w.add(text.ownData());
            continue;
        }
        if (wraps_at_box == false) {
            // Skip the scan once the line is already this tall
            if (line_height) |h| {
                if (flow.line >= h) continue;
            }
        }
        if (isAllWhitespace(text.ownData())) {
            continue;
        }
        const at_box = wraps_at_box orelse blk: {
            const wraps = style_manager.wrapsOwnText(self);
            wraps_at_box = wraps;
            break :blk wraps;
        };
        if (at_box) {
            style_manager.setHeightReadsWidth(self);
            wrap = .{
                .line_width = innerWidth(self, owner),
                .font_size = style_manager.computedFontSize(self),
                .white_space = style_manager.whiteSpace(self),
            };
            wrap.?.add(text.ownData());
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

    if (wrap) |w| {
        // Its lines share the last line's height with the inline boxes there
        flow.line = @max(flow.line, w.wrappedHeight());
    }
    return flow.offset + flow.line;
}

// A parent's children, laid out top to bottom.
const Flow = struct {
    mode: Mode,
    line: f64 = 0, // The current line's height
    offset: f64 = 0, // The current line's top, from the parent's
    column: u32 = 0, // A grid's next free column on the current row
    // The grid cell at() found, for advance() past the same item
    cell: ?struct { el: *Element, cell: GridCell } = null,

    // StyleManager.ChildFlow, with a wrapping grid's column count
    const Mode = union(enum) {
        block,
        row,
        grid: u32,
    };

    fn of(parent: *Element, owner: *Frame) Flow {
        return switch (owner._style_manager.childFlow(parent)) {
            .block => .{ .mode = .block },
            .row => .{ .mode = .row },
            .grid => .{ .mode = .{ .grid = gridTrackCount(parent, owner) } },
        };
    }

    // Where el goes, from the parent's top. Its own height only moves what
    // comes after it.
    fn at(self: *Flow, el: *Element, role: StyleManager.FlowRole, owner: *Frame) f64 {
        switch (self.mode) {
            .row => return self.offset,
            .block => {
                if (role != .block) {
                    return self.offset;
                }
                // A block ends the line and starts below it
                return self.offset + self.line;
            },
            .grid => |tracks| {
                if (role == .none or role == .out_of_flow) {
                    return self.offset;
                }
                const cell = self.gridCell(el, tracks, owner);
                self.cell = .{ .el = el, .cell = cell };
                return if (cell.wraps) self.offset + self.line else self.offset;
            },
        }
    }

    // Moves past el, to where the next box goes
    fn advance(self: *Flow, el: *Element, role: StyleManager.FlowRole, owner: *Frame) void {
        if (role == .none or role == .out_of_flow) {
            return;
        }
        const height = boxHeight(el, owner);
        switch (self.mode) {
            .row => {},
            .block => if (role == .block) {
                self.offset += self.line + height;
                self.line = 0;
                return;
            },
            .grid => |tracks| {
                const cell = if (self.cell) |c| (if (c.el == el) c.cell else self.gridCell(el, tracks, owner)) else self.gridCell(el, tracks, owner);
                if (cell.wraps) {
                    self.offset += self.line;
                    self.line = 0;
                }
                self.column = cell.column + cell.span;
            },
        }
        self.line = @max(self.line, height);
    }

    // The column at() put el at, in a grid; 0 otherwise
    fn columnOf(self: *const Flow, el: *Element) u16 {
        const c = self.cell orelse return 0;
        return if (c.el == el) @intCast(@min(c.cell.column, std.math.maxInt(u16))) else 0;
    }

    const GridCell = struct {
        wraps: bool, // it starts the next row
        column: u32,
        span: u32,
    };

    // Where a grid item goes on the current row, or whether it wraps:
    // auto-placed items fill the columns in order, an item with a start
    // line goes at it, on the next row if the row is past it. Sparse, as
    // grid-auto-flow: row is; rows themselves aren't modelled.
    fn gridCell(self: *const Flow, el: *Element, tracks: u32, owner: *Frame) GridCell {
        const placement = owner._style_manager.gridColumn(el);
        // Lines are 1 to tracks + 1, negative ones counted from the end
        const start = gridLine(placement.start, tracks);
        const end = gridLine(placement.end, tracks);
        const span = gridSpan(placement, tracks);

        const column = if (start) |s| s else if (end) |e| (if (e >= span) e - span else 0) else null;
        if (column) |c| {
            const at_column = @min(c, tracks - 1);
            return .{ .wraps = at_column < self.column, .column = at_column, .span = span };
        }
        if (self.column > 0 and self.column + span > tracks) {
            return .{ .wraps = true, .column = 0, .span = span };
        }
        return .{ .wraps = false, .column = self.column, .span = span };
    }

    // How many columns an item takes
    fn gridSpan(placement: StyleManager.GridColumn, tracks: u32) u32 {
        const span: u32 = if (placement.span != 0) placement.span else blk: {
            const s = gridLine(placement.start, tracks) orelse break :blk 1;
            const e = gridLine(placement.end, tracks) orelse break :blk 1;
            break :blk if (e > s) e - s else 1;
        };
        return std.math.clamp(span, 1, tracks);
    }

    // A line's column index, null for auto
    fn gridLine(line: i8, tracks: u32) ?u32 {
        if (line > 0) {
            return @as(u32, @intCast(line)) - 1;
        }
        if (line < 0) {
            const from_end: u32 = @intCast(-@as(i32, line));
            return (tracks + 1) -| from_end;
        }
        return null;
    }
};

// A wrapping grid's item is as wide as the columns it spans, less its
// margins. The columns share the grid's width evenly: fr tracks; a px or
// auto track among them isn't sized, nor are gaps.
fn gridItemWidth(item: *Element, grid: *Element, owner: *Frame) f64 {
    const tracks = gridTrackCount(grid, owner);
    const span = Flow.gridSpan(owner._style_manager.gridColumn(item), tracks);
    const area = innerWidth(grid, owner) * @as(f64, @floatFromInt(span)) / @as(f64, @floatFromInt(tracks));
    return @max(0, area - owner._style_manager.inlineMargins(item, area));
}

/// A wrapping grid's item: its left from the grid's, at its column, which
/// boxOffset caches with its offset.
pub fn gridItemLeft(item: *Element, grid: *Element, owner: *Frame) f64 {
    const style_manager = &owner._style_manager;
    const tracks = switch (Flow.of(grid, owner).mode) {
        .grid => |tracks| tracks,
        .block, .row => return 0,
    };
    _ = boxOffset(item, grid, owner);
    const column = if (style_manager.getCachedPlacement(item, grid)) |placement| placement.column else gridColumnByWalk(item, grid, tracks, owner);
    return innerWidth(grid, owner) * @as(f64, @floatFromInt(column)) / @as(f64, @floatFromInt(tracks));
}

// The item's column without the cache: the row replayed from its first item
fn gridColumnByWalk(item: *Element, grid: *Element, tracks: u32, owner: *Frame) u32 {
    const style_manager = &owner._style_manager;
    var flow: Flow = .{ .mode = .{ .grid = tracks } };
    var next = grid.asNode().flatFirstChild(owner);
    if (gridResumePoint(item, grid, owner)) |point| {
        next = point.next;
    }
    while (next) |node| : (next = node.flatNextSibling(owner)) {
        const el = node.is(Element) orelse continue;
        switch (style_manager.flowRole(el)) {
            .none, .out_of_flow => continue,
            .block, .line => {},
        }
        const cell = flow.gridCell(el, tracks, owner);
        if (el == item) {
            return cell.column;
        }
        flow.column = cell.column + cell.span;
    }
    return 0;
}

// A wrapping grid's columns: its fixed tracks, and as many repeat(auto-fill)
// ones as its width holds.
fn gridTrackCount(grid: *Element, owner: *Frame) u32 {
    const tracks = owner._style_manager.gridTracks(grid);
    var count: u32 = tracks.tracks;
    if (tracks.fill_px > 0) {
        const fill: f64 = @floatFromInt(tracks.fill_px);
        count += @intFromFloat(@max(1, @floor(innerWidth(grid, owner) / fill)));
    }
    return @max(count, 1);
}
