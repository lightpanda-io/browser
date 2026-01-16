// Copyright (C) 2023-2025  Lightpanda (Selecy SAS)
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
const log = @import("../../log.zig");

const js = @import("../js/js.zig");
const Page = @import("../Page.zig");
const Range = @import("Range.zig");
const AbstractRange = @import("AbstractRange.zig");
const Node = @import("Node.zig");

const Selection = @This();

const SelectionDirection = enum { backward, forward, none };

_ranges: std.ArrayList(*Range) = .empty,
_direction: SelectionDirection = .none,

pub const init: Selection = .{};

pub fn getAnchorNode(self: *const Selection) ?*Node {
    if (self._ranges.items.len == 0) return null;

    return switch (self._direction) {
        .backward => self._ranges.getLast().asAbstractRange().getEndContainer(),
        .forward, .none => self._ranges.items[0].asAbstractRange().getStartContainer(),
    };
}

pub fn getAnchorOffset(self: *const Selection) u32 {
    if (self._ranges.items.len == 0) return 0;

    return switch (self._direction) {
        .backward => self._ranges.getLast().asAbstractRange().getEndOffset(),
        .forward, .none => self._ranges.items[0].asAbstractRange().getStartOffset(),
    };
}

pub fn getDirection(self: *const Selection) []const u8 {
    return @tagName(self._direction);
}

pub fn getFocusNode(self: *const Selection) ?*Node {
    if (self._ranges.items.len == 0) return null;

    return switch (self._direction) {
        .backward => self._ranges.items[0].asAbstractRange().getStartContainer(),
        .forward, .none => self._ranges.getLast().asAbstractRange().getEndContainer(),
    };
}

pub fn getFocusOffset(self: *const Selection) u32 {
    if (self._ranges.items.len == 0) return 0;

    return switch (self._direction) {
        .backward => self._ranges.items[0].asAbstractRange().getStartOffset(),
        .forward, .none => self._ranges.getLast().asAbstractRange().getEndOffset(),
    };
}

pub fn getIsCollapsed(self: *const Selection) bool {
    if (self._ranges.items.len == 0) return true;
    if (self._ranges.items.len > 1) return false;

    return self._ranges.items[0].asAbstractRange().getCollapsed();
}

pub fn getRangeCount(self: *const Selection) u32 {
    return @intCast(self._ranges.items.len);
}

pub fn getType(self: *const Selection) []const u8 {
    if (self._ranges.items.len == 0) return "None";
    if (self.getIsCollapsed()) return "Caret";
    return "Range";
}

pub fn addRange(self: *Selection, range: *Range, page: *Page) !void {
    for (self._ranges.items) |r| {
        if (r == range) return;
    }

    return try self._ranges.append(page.arena, range);
}

pub fn removeRange(self: *Selection, range: *Range) !void {
    for (self._ranges.items, 0..) |r, i| {
        if (r == range) {
            _ = self._ranges.orderedRemove(i);
            return;
        }
    }

    return error.NotFound;
}

fn removeAllRangesInner(self: *Selection, reset_direction: bool) void {
    self._ranges.clearRetainingCapacity();
    if (reset_direction) {
        self._direction = .none;
    }
}

pub fn removeAllRanges(self: *Selection) void {
    self.removeAllRangesInner(true);
}

pub fn collapseToEnd(self: *Selection, page: *Page) !void {
    if (self._ranges.items.len == 0) return;

    const last_range = self._ranges.getLast().asAbstractRange();
    const last_node = last_range.getEndContainer();
    const last_offset = last_range.getEndOffset();

    const range = try Range.init(page);
    try range.setStart(last_node, last_offset);
    try range.setEnd(last_node, last_offset);

    self.removeAllRangesInner(true);
    try self._ranges.append(page.arena, range);
}

pub fn collapseToStart(self: *Selection, page: *Page) !void {
    if (self._ranges.items.len == 0) return;

    const first_range = self._ranges.items[0].asAbstractRange();
    const first_node = first_range.getStartContainer();
    const first_offset = first_range.getStartOffset();

    const range = try Range.init(page);
    try range.setStart(first_node, first_offset);
    try range.setEnd(first_node, first_offset);

    self.removeAllRangesInner(true);
    try self._ranges.append(page.arena, range);
    self._direction = .none;
}

pub fn containsNode(self: *const Selection, node: *Node, partial: bool) !bool {
    for (self._ranges.items) |r| {
        if (partial) {
            if (r.intersectsNode(node)) {
                return true;
            }
        } else {
            const parent = node.parentNode() orelse continue;
            const offset = parent.getChildIndex(node) orelse continue;

            const start_in = r.isPointInRange(parent, offset) catch false;
            const end_in = r.isPointInRange(parent, offset + 1) catch false;

            if (start_in and end_in) {
                return true;
            }
        }
    }

    return false;
}

pub fn deleteFromDocument(self: *Selection, page: *Page) !void {
    if (self._ranges.items.len == 0) return;

    try self._ranges.items[0].deleteContents(page);
}

pub fn extend(self: *Selection, node: *Node, _offset: ?u32) !void {
    if (self._ranges.items.len == 0) {
        return error.InvalidState;
    }

    const offset = _offset orelse 0;

    if (offset > node.getLength()) {
        return error.IndexSizeError;
    }

    const range = self._ranges.items[0];
    const old_anchor = switch (self._direction) {
        .backward => range.asAbstractRange().getEndContainer(),
        .forward, .none => range.asAbstractRange().getStartContainer(),
    };
    const old_anchor_offset = switch (self._direction) {
        .backward => range.asAbstractRange().getEndOffset(),
        .forward, .none => range.asAbstractRange().getStartOffset(),
    };

    const cmp = AbstractRange.compareBoundaryPoints(node, offset, old_anchor, old_anchor_offset);
    switch (cmp) {
        .before => {
            try range.setStart(node, offset);
            try range.setEnd(old_anchor, old_anchor_offset);
            self._direction = .backward;
        },
        .after => {
            try range.setStart(old_anchor, old_anchor_offset);
            try range.setEnd(node, offset);
            self._direction = .forward;
        },
        .equal => {
            try range.setStart(old_anchor, old_anchor_offset);
            try range.setEnd(old_anchor, old_anchor_offset);
            self._direction = .none;
        },
    }
}

pub fn getRangeAt(self: *Selection, index: u32) !*Range {
    if (index >= self.getRangeCount()) {
        return error.IndexSizeError;
    }

    return self._ranges.items[index];
}

const ModifyAlter = enum {
    move,
    extend,

    pub fn fromString(str: []const u8) ?ModifyAlter {
        return std.meta.stringToEnum(ModifyAlter, str);
    }
};

const ModifyDirection = enum {
    forward,
    backward,
    left,
    right,

    pub fn fromString(str: []const u8) ?ModifyDirection {
        return std.meta.stringToEnum(ModifyDirection, str);
    }
};

const ModifyGranularity = enum {
    character,
    word,
    line,
    paragraph,
    lineboundary,
    // Firefox doesn't implement:
    // - sentence
    // - paragraph
    // - sentenceboundary
    // - paragraphboundary
    // - documentboundary
    // so we won't either for now.

    pub fn fromString(str: []const u8) ?ModifyGranularity {
        return std.meta.stringToEnum(ModifyGranularity, str);
    }
};

pub fn modify(
    self: *Selection,
    alter_str: []const u8,
    direction_str: []const u8,
    granularity_str: []const u8,
) !void {
    const alter = ModifyAlter.fromString(alter_str) orelse return error.InvalidParams;
    const direction = ModifyDirection.fromString(direction_str) orelse return error.InvalidParams;
    const granularity = ModifyGranularity.fromString(granularity_str) orelse return error.InvalidParams;

    if (self._ranges.items.len == 0) return;

    log.warn(.not_implemented, "Selection.modify", .{
        .alter = alter,
        .direction = direction,
        .granularity = granularity,
    });
}

pub fn selectAllChildren(self: *Selection, parent: *Node, page: *Page) !void {
    if (parent._type == .document_type) {
        return error.InvalidNodeType;
    }

    const range = try Range.init(page);
    try range.setStart(parent, 0);

    const child_count = parent.getLength();
    try range.setEnd(parent, @intCast(child_count));

    self.removeAllRangesInner(true);
    try self._ranges.append(page.arena, range);
}

pub fn setBaseAndExtent(
    self: *Selection,
    anchor_node: *Node,
    anchor_offset: u32,
    focus_node: *Node,
    focus_offset: u32,
    page: *Page,
) !void {
    if (anchor_offset > anchor_node.getLength()) {
        return error.IndexSizeError;
    }

    if (focus_offset > focus_node.getLength()) {
        return error.IndexSizeError;
    }

    const cmp = AbstractRange.compareBoundaryPoints(
        anchor_node,
        anchor_offset,
        focus_node,
        focus_offset,
    );

    const range = try Range.init(page);

    switch (cmp) {
        .before => {
            try range.setStart(anchor_node, anchor_offset);
            try range.setEnd(focus_node, focus_offset);
            self._direction = .forward;
        },
        .after => {
            try range.setStart(focus_node, focus_offset);
            try range.setEnd(anchor_node, anchor_offset);
            self._direction = .backward;
        },
        .equal => {
            try range.setStart(anchor_node, anchor_offset);
            try range.setEnd(anchor_node, anchor_offset);
            self._direction = .none;
        },
    }

    self.removeAllRangesInner(false);
    try self._ranges.append(page.arena, range);
}

pub fn setPosition(self: *Selection, _node: ?*Node, _offset: ?u32, page: *Page) !void {
    const node = _node orelse {
        self.removeAllRangesInner(true);
        return;
    };

    const offset = _offset orelse 0;

    if (offset > node.getLength()) {
        return error.IndexSizeError;
    }

    const range = try Range.init(page);
    try range.setStart(node, offset);
    try range.setEnd(node, offset);

    self.removeAllRangesInner(true);
    try self._ranges.append(page.arena, range);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Selection);

    pub const Meta = struct {
        pub const name = "Selection";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const anchorNode = bridge.accessor(Selection.getAnchorNode, null, .{});
    pub const anchorOffset = bridge.accessor(Selection.getAnchorOffset, null, .{});
    pub const direction = bridge.accessor(Selection.getDirection, null, .{});
    pub const focusNode = bridge.accessor(Selection.getFocusNode, null, .{});
    pub const focusOffset = bridge.accessor(Selection.getFocusOffset, null, .{});
    pub const isCollapsed = bridge.accessor(Selection.getIsCollapsed, null, .{});
    pub const rangeCount = bridge.accessor(Selection.getRangeCount, null, .{});
    pub const @"type" = bridge.accessor(Selection.getType, null, .{});

    pub const addRange = bridge.function(Selection.addRange, .{});
    pub const collapse = bridge.function(Selection.setPosition, .{ .dom_exception = true });
    pub const collapseToEnd = bridge.function(Selection.collapseToEnd, .{});
    pub const collapseToStart = bridge.function(Selection.collapseToStart, .{});
    pub const containsNode = bridge.function(Selection.containsNode, .{});
    pub const deleteFromDocument = bridge.function(Selection.deleteFromDocument, .{});
    pub const empty = bridge.function(Selection.removeAllRanges, .{});
    pub const extend = bridge.function(Selection.extend, .{ .dom_exception = true });
    // unimplemented: getComposedRanges
    pub const getRangeAt = bridge.function(Selection.getRangeAt, .{ .dom_exception = true });
    pub const modify = bridge.function(Selection.modify, .{});
    pub const removeAllRanges = bridge.function(Selection.removeAllRanges, .{});
    pub const removeRange = bridge.function(Selection.removeRange, .{ .dom_exception = true });
    pub const selectAllChildren = bridge.function(Selection.selectAllChildren, .{});
    pub const setBaseAndExtent = bridge.function(Selection.setBaseAndExtent, .{ .dom_exception = true });
    pub const setPosition = bridge.function(Selection.setPosition, .{});
};

const testing = @import("../../testing.zig");
test "WebApi: Selection" {
    try testing.htmlRunner("selection.html", .{});
}
