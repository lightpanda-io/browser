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

const Element = @import("webapi/Element.zig");
const TreeWalker = @import("webapi/TreeWalker.zig");

// Width flows down (height flows up): a block in normal flow is as wide as
// its containing block.
pub fn boxWidth(self: *Element, owner: *Frame) f64 {
    const style_manager = &owner._style_manager;
    if (style_manager.cachedWidth(self, .box)) |width| {
        return width;
    }

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
            .grow, .shrink => @max(own.value, contentWidth(self, .clipped, owner)),
            .contents => unreachable,
        };
        break :blk clampWidth(self, width, .box, owner);
    };
    style_manager.cacheWidth(self, .box, width);
    return width;
}

// How a box that clips its overflow counts toward its ancestors' content.
pub const ContentMode = enum {
    full,
    clipped,
};

// What the box, with its margins, adds to its parent's content width.
fn widthContribution(self: *Element, comptime mode: ContentMode, owner: *Frame) f64 {
    const style_manager = &owner._style_manager;
    const own = self.getElementAxis(owner, .width);
    const width = if (own.explicit) own.value else switch (style_manager.widthSizing(self)) {
        .fixed => |width| width,
        .shrink, .grow => @max(own.value, contentWidth(self, mode, owner)),
        .percent, .fill => if (mode == .clipped and style_manager.clipsOverflowX(self)) 0 else contentWidth(self, mode, owner),
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
    const own = self.getElementAxis(owner, .width);
    const width = if (own.explicit) own.value else switch (style_manager.widthSizing(self)) {
        .fixed => |width| width,
        .percent => |fraction| fraction * row_width,
        .shrink, .grow, .fill => @max(own.value, contentWidth(self, .full, owner)),
        .contents => return .{
            .base = widthContribution(self, .full, owner),
            .floor = widthContribution(self, .clipped, owner),
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
    const content = contentWidth(self, .clipped, owner);
    // An auto width's fallback stands in for its text
    return @min(base, if (own.explicit) content else @max(own.value, content));
}

// The fraction of its base each shrinking item of an overflowing flex row
// gives up: the overflow split in proportion to the bases (a flex-shrink is
// 0 or 1 here). Items that would drop below their floor freeze there and the
// rest share what they couldn't give (CSS Flexbox §9.7). A wrapping row moves
// items to a new line instead, so it shrinks nothing.
fn rowShrinkRatio(self: *Element, owner: *Frame) f64 {
    const style_manager = &owner._style_manager;
    if (style_manager.flexWraps(self)) {
        return 0;
    }
    if (style_manager.cachedWidth(self, .row_shrink)) |ratio| {
        return ratio;
    }

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
    style_manager.cacheWidth(self, .row_shrink, ratio);
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

fn resolveWidthLimit(self: *Element, limit: StyleManager.WidthLimit, resolve_percent: bool, owner: *Frame) ?f64 {
    return switch (limit) {
        .px => |px| px,
        .percent => |fraction| if (resolve_percent) fraction * containingBlockWidth(self, owner) else null,
    };
}

// A block in normal flow fills its containing block, less its margins.
fn fillWidth(self: *Element, owner: *Frame) f64 {
    const containing = containingBlockWidth(self, owner);
    return @max(0, containing - owner._style_manager.inlineMargins(self, containing));
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
// share one line that never wraps (the dummy layout has no line breaking,
// which keeps the "append until the lane outgrows its shell" idiom
// terminating).
pub fn contentWidth(self: *Element, comptime mode: ContentMode, owner: *Frame) f64 {
    const kind: StyleManager.WidthKind = if (mode == .clipped) .content else .full_content;
    const style_manager = &owner._style_manager;
    if (style_manager.cachedWidth(self, kind)) |width| {
        return width;
    }

    const in_row = style_manager.laysOutInRow(self);
    var widest: f64 = 0;
    var line: f64 = 0;
    var children: TreeWalker.FlatChildren = .init(self.asNode(), .{ .frame = owner });
    while (children.next()) |node| {
        const el = node.is(Element) orelse continue;
        if (style_manager.hasDisplayNone(el)) {
            continue;
        }
        const width = widthContribution(el, mode, owner);
        if (in_row or style_manager.isBlockLevel(el) == false) {
            line += width;
        } else {
            widest = @max(widest, line, width);
            line = 0;
        }
    }
    const width = @max(widest, line);
    style_manager.cacheWidth(self, kind, width);
    return width;
}
