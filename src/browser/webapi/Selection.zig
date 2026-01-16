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

/// https://w3c.github.io/selection-api/
const Selection = @This();

const SelectionDirection = enum { backward, forward, none };

_range: ?*Range = null,
_direction: SelectionDirection = .none,

pub const init: Selection = .{};

fn isInTree(self: *const Selection) bool {
    if (self._range == null) return false;
    return self.getAnchorNode().?.isConnected() and self.getFocusNode().?.isConnected();
}

pub fn getAnchorNode(self: *const Selection) ?*Node {
    const range = self._range orelse return null;

    const node = switch (self._direction) {
        .backward => range.asAbstractRange().getEndContainer(),
        .forward, .none => range.asAbstractRange().getStartContainer(),
    };

    return if (node.isConnected()) node else null;
}

pub fn getAnchorOffset(self: *const Selection) u32 {
    const range = self._range orelse return 0;
    if (!self.getAnchorNode().?.isConnected()) return 0;

    return switch (self._direction) {
        .backward => range.asAbstractRange().getEndOffset(),
        .forward, .none => range.asAbstractRange().getStartOffset(),
    };
}

pub fn getDirection(self: *const Selection) []const u8 {
    return @tagName(self._direction);
}

pub fn getFocusNode(self: *const Selection) ?*Node {
    const range = self._range orelse return null;

    const node = switch (self._direction) {
        .backward => range.asAbstractRange().getStartContainer(),
        .forward, .none => range.asAbstractRange().getEndContainer(),
    };

    return if (node.isConnected()) node else null;
}

pub fn getFocusOffset(self: *const Selection) u32 {
    const range = self._range orelse return 0;
    if (!self.getFocusNode().?.isConnected()) return 0;

    return switch (self._direction) {
        .backward => range.asAbstractRange().getStartOffset(),
        .forward, .none => range.asAbstractRange().getEndOffset(),
    };
}

pub fn getIsCollapsed(self: *const Selection) bool {
    const range = self._range orelse return true;
    return range.asAbstractRange().getCollapsed();
}

pub fn getRangeCount(self: *const Selection) u32 {
    if (self._range == null) return 0;
    if (!self.isInTree()) return 0;

    return 1;
}

pub fn getType(self: *const Selection) []const u8 {
    if (self._range == null) return "None";
    if (!self.isInTree()) return "None";
    if (self.getIsCollapsed()) return "Caret";
    return "Range";
}

pub fn addRange(self: *Selection, range: *Range) !void {
    if (self._range != null) return;
    self._range = range;
}

pub fn removeRange(self: *Selection, range: *Range) !void {
    if (self._range == range) {
        self._range = null;
        return;
    } else {
        return error.NotFound;
    }
}

pub fn removeAllRanges(self: *Selection) void {
    self._range = null;
    self._direction = .none;
}

pub fn collapseToEnd(self: *Selection) !void {
    const range = self._range orelse return;

    const abstract = range.asAbstractRange();
    const last_node = abstract.getEndContainer();
    const last_offset = abstract.getEndOffset();

    try range.setStart(last_node, last_offset);
    try range.setEnd(last_node, last_offset);
    self._direction = .none;
}

pub fn collapseToStart(self: *Selection) !void {
    const range = self._range orelse return;

    const abstract = range.asAbstractRange();
    const first_node = abstract.getStartContainer();
    const first_offset = abstract.getStartOffset();

    try range.setStart(first_node, first_offset);
    try range.setEnd(first_node, first_offset);
    self._direction = .none;
}

pub fn containsNode(self: *const Selection, node: *Node, partial: bool) !bool {
    const range = self._range orelse return false;

    if (partial) {
        if (range.intersectsNode(node)) {
            return true;
        }
    } else {
        const abstract = range.asAbstractRange();
        if (abstract.getStartContainer() == node or abstract.getEndContainer() == node) {
            return false;
        }

        const parent = node.parentNode() orelse return false;
        const offset = parent.getChildIndex(node) orelse return false;
        const start_cmp = range.comparePoint(parent, offset) catch return false;
        const end_cmp = range.comparePoint(parent, offset + 1) catch return false;

        if (start_cmp <= 0 and end_cmp >= 0) {
            return true;
        }
    }

    return false;
}

pub fn deleteFromDocument(self: *Selection, page: *Page) !void {
    const range = self._range orelse return;

    try range.deleteContents(page);
}

pub fn extend(self: *Selection, node: *Node, _offset: ?u32, page: *Page) !void {
    const range = self._range orelse return error.InvalidState;
    const offset = _offset orelse 0;

    if (offset > node.getLength()) {
        return error.IndexSizeError;
    }

    const old_anchor = switch (self._direction) {
        .backward => range.asAbstractRange().getEndContainer(),
        .forward, .none => range.asAbstractRange().getStartContainer(),
    };
    const old_anchor_offset = switch (self._direction) {
        .backward => range.asAbstractRange().getEndOffset(),
        .forward, .none => range.asAbstractRange().getStartOffset(),
    };

    const new_range = try Range.init(page);

    const cmp = AbstractRange.compareBoundaryPoints(node, offset, old_anchor, old_anchor_offset);
    switch (cmp) {
        .before => {
            try new_range.setStart(node, offset);
            try new_range.setEnd(old_anchor, old_anchor_offset);
            self._direction = .backward;
        },
        .after => {
            try new_range.setStart(old_anchor, old_anchor_offset);
            try new_range.setEnd(node, offset);
            self._direction = .forward;
        },
        .equal => {
            try new_range.setStart(old_anchor, old_anchor_offset);
            try new_range.setEnd(old_anchor, old_anchor_offset);
            self._direction = .none;
        },
    }

    self._range = new_range;
}

pub fn getRangeAt(self: *Selection, index: u32) !*Range {
    if (index != 0) return error.IndexSizeError;
    if (!self.isInTree()) return error.IndexSizeError;
    const range = self._range orelse return error.IndexSizeError;

    return range;
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

    _ = self._range orelse return;

    log.warn(.not_implemented, "Selection.modify", .{
        .alter = alter,
        .direction = direction,
        .granularity = granularity,
    });
}

pub fn selectAllChildren(self: *Selection, parent: *Node, page: *Page) !void {
    if (parent._type == .document_type) return error.InvalidNodeTypeError;

    const range = try Range.init(page);
    try range.setStart(parent, 0);

    const child_count = parent.getLength();
    try range.setEnd(parent, @intCast(child_count));

    self._range = range;
    self._direction = .forward;
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

    self._range = range;
}

pub fn collapse(self: *Selection, _node: ?*Node, _offset: ?u32, page: *Page) !void {
    const node = _node orelse {
        self.removeAllRanges();
        return;
    };

    if (node._type == .document_type) return error.InvalidNodeType;

    const offset = _offset orelse 0;
    if (offset > node.getLength()) {
        return error.IndexSizeError;
    }

    const range = try Range.init(page);
    try range.setStart(node, offset);
    try range.setEnd(node, offset);

    self._range = range;
    self._direction = .none;
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
    pub const collapse = bridge.function(Selection.collapse, .{ .dom_exception = true });
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
    pub const setPosition = bridge.function(Selection.collapse, .{});
};

const testing = @import("../../testing.zig");
test "WebApi: Selection" {
    try testing.htmlRunner("selection.html", .{});
}
