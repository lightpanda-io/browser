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
const Event = @import("Event.zig");
const Document = @import("Document.zig");

/// https://w3c.github.io/selection-api/
const Selection = @This();

pub const SelectionDirection = enum { backward, forward, none };

_range: ?*Range = null,
_direction: SelectionDirection = .none,

pub const init: Selection = .{};

fn dispatchSelectionChangeEvent(page: *Page) !void {
    const event = try Event.init("selectionchange", .{}, page);
    try page._event_manager.dispatch(page.document.asEventTarget(), event);
}

fn isInTree(self: *const Selection) bool {
    if (self._range == null) return false;
    const anchor_node = self.getAnchorNode() orelse return false;
    const focus_node = self.getFocusNode() orelse return false;
    return anchor_node.isConnected() and focus_node.isConnected();
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

    const anchor_node = self.getAnchorNode() orelse return 0;
    if (!anchor_node.isConnected()) return 0;

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
    const focus_node = self.getFocusNode() orelse return 0;
    if (!focus_node.isConnected()) return 0;

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

pub fn addRange(self: *Selection, range: *Range, page: *Page) !void {
    if (self._range != null) return;

    // Only add the range if its root node is in the document associated with this selection
    const start_node = range.asAbstractRange().getStartContainer();
    if (!page.document.asNode().contains(start_node)) {
        return;
    }

    self._range = range;
    try dispatchSelectionChangeEvent(page);
}

pub fn removeRange(self: *Selection, range: *Range, page: *Page) !void {
    if (self._range == range) {
        self._range = null;
        try dispatchSelectionChangeEvent(page);
        return;
    } else {
        return error.NotFound;
    }
}

pub fn removeAllRanges(self: *Selection, page: *Page) !void {
    self._range = null;
    self._direction = .none;
    try dispatchSelectionChangeEvent(page);
}

pub fn collapseToEnd(self: *Selection, page: *Page) !void {
    const range = self._range orelse return;

    const abstract = range.asAbstractRange();
    const last_node = abstract.getEndContainer();
    const last_offset = abstract.getEndOffset();

    const new_range = try Range.init(page);
    try new_range.setStart(last_node, last_offset);
    try new_range.setEnd(last_node, last_offset);

    self._range = new_range;
    self._direction = .none;
    try dispatchSelectionChangeEvent(page);
}

pub fn collapseToStart(self: *Selection, page: *Page) !void {
    const range = self._range orelse return error.InvalidStateError;

    const abstract = range.asAbstractRange();
    const first_node = abstract.getStartContainer();
    const first_offset = abstract.getStartOffset();

    const new_range = try Range.init(page);
    try new_range.setStart(first_node, first_offset);
    try new_range.setEnd(first_node, first_offset);

    self._range = new_range;
    self._direction = .none;
    try dispatchSelectionChangeEvent(page);
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
    try dispatchSelectionChangeEvent(page);
}

pub fn extend(self: *Selection, node: *Node, _offset: ?u32, page: *Page) !void {
    const range = self._range orelse return error.InvalidState;
    const offset = _offset orelse 0;

    // If the node is not contained in the document, do not change the selection
    if (!page.document.asNode().contains(node)) {
        return;
    }

    if (node._type == .document_type) return error.InvalidNodeType;

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
    try dispatchSelectionChangeEvent(page);
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
    // The rest are either:
    // 1. Layout dependent.
    // 2. Not widely supported across browsers.

    pub fn fromString(str: []const u8) ?ModifyGranularity {
        return std.meta.stringToEnum(ModifyGranularity, str);
    }
};

pub fn modify(
    self: *Selection,
    alter_str: []const u8,
    direction_str: []const u8,
    granularity_str: []const u8,
    page: *Page,
) !void {
    const alter = ModifyAlter.fromString(alter_str) orelse return;
    const direction = ModifyDirection.fromString(direction_str) orelse return;
    const granularity = ModifyGranularity.fromString(granularity_str) orelse return;

    const range = self._range orelse return;

    const is_forward = switch (direction) {
        .forward, .right => true,
        .backward, .left => false,
    };

    switch (granularity) {
        .character => try self.modifyByCharacter(alter, is_forward, range, page),
        .word => try self.modifyByWord(alter, is_forward, range, page),
    }
}

fn isTextNode(node: *const Node) bool {
    return switch (node._type) {
        .cdata => |cd| cd._type == .text,
        else => false,
    };
}

fn nextTextNode(node: *Node) ?*Node {
    var current = node;

    while (true) {
        if (current.firstChild()) |child| {
            current = child;
        } else if (current.nextSibling()) |sib| {
            current = sib;
        } else {
            while (true) {
                const parent = current.parentNode() orelse return null;
                if (parent.nextSibling()) |uncle| {
                    current = uncle;
                    break;
                }
                current = parent;
            }
        }

        if (isTextNode(current)) return current;
    }
}

fn nextTextNodeAfter(node: *Node) ?*Node {
    var current = node;
    while (true) {
        if (current.nextSibling()) |sib| {
            current = sib;
        } else {
            while (true) {
                const parent = current.parentNode() orelse return null;
                if (parent.nextSibling()) |uncle| {
                    current = uncle;
                    break;
                }
                current = parent;
            }
        }

        var descend = current;
        while (true) {
            if (isTextNode(descend)) return descend;
            descend = descend.firstChild() orelse break;
        }
    }
}

fn prevTextNode(node: *Node) ?*Node {
    var current = node;

    while (true) {
        if (current.previousSibling()) |sib| {
            current = sib;
            while (current.lastChild()) |child| {
                current = child;
            }
        } else {
            current = current.parentNode() orelse return null;
        }

        if (isTextNode(current)) return current;
    }
}

fn modifyByCharacter(self: *Selection, alter: ModifyAlter, forward: bool, range: *Range, page: *Page) !void {
    const abstract = range.asAbstractRange();

    const focus_node = switch (self._direction) {
        .backward => abstract.getStartContainer(),
        .forward, .none => abstract.getEndContainer(),
    };
    const focus_offset = switch (self._direction) {
        .backward => abstract.getStartOffset(),
        .forward, .none => abstract.getEndOffset(),
    };

    var new_node = focus_node;
    var new_offset = focus_offset;

    if (isTextNode(focus_node)) {
        if (forward) {
            const len = focus_node.getLength();
            if (focus_offset < len) {
                new_offset += 1;
            } else if (nextTextNode(focus_node)) |next| {
                new_node = next;
                new_offset = 0;
            }
        } else {
            if (focus_offset > 0) {
                new_offset -= 1;
            } else if (prevTextNode(focus_node)) |prev| {
                new_node = prev;
                new_offset = prev.getLength();
            }
        }
    } else {
        if (forward) {
            if (focus_node.getChildAt(focus_offset)) |child| {
                if (isTextNode(child)) {
                    new_node = child;
                    new_offset = 0;
                } else if (nextTextNode(child)) |t| {
                    new_node = t;
                    new_offset = 0;
                }
            } else if (nextTextNodeAfter(focus_node)) |next| {
                new_node = next;
                new_offset = 1;
            }
        } else {
            // backward element-node case
            var idx = focus_offset;
            while (idx > 0) {
                idx -= 1;
                const child = focus_node.getChildAt(idx) orelse break;
                var bottom = child;
                while (bottom.lastChild()) |c| bottom = c;
                if (isTextNode(bottom)) {
                    new_node = bottom;
                    new_offset = bottom.getLength();
                    break;
                }
            }
        }
    }

    try self.applyModify(alter, new_node, new_offset, page);
}

fn isWordChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn nextWordEnd(text: []const u8, offset: u32) u32 {
    var i = offset;
    // consumes whitespace till next word
    while (i < text.len and !isWordChar(text[i])) : (i += 1) {}
    // consumes next word
    while (i < text.len and isWordChar(text[i])) : (i += 1) {}
    return i;
}

fn prevWordStart(text: []const u8, offset: u32) u32 {
    var i = offset;
    if (i > 0) i -= 1;
    // consumes the white space
    while (i > 0 and !isWordChar(text[i])) : (i -= 1) {}
    // consumes the last word
    while (i > 0 and isWordChar(text[i - 1])) : (i -= 1) {}
    return i;
}

fn modifyByWord(self: *Selection, alter: ModifyAlter, forward: bool, range: *Range, page: *Page) !void {
    const abstract = range.asAbstractRange();

    const focus_node = switch (self._direction) {
        .backward => abstract.getStartContainer(),
        .forward, .none => abstract.getEndContainer(),
    };
    const focus_offset = switch (self._direction) {
        .backward => abstract.getStartOffset(),
        .forward, .none => abstract.getEndOffset(),
    };

    var new_node = focus_node;
    var new_offset = focus_offset;

    if (isTextNode(focus_node)) {
        if (forward) {
            const i = nextWordEnd(new_node.getData().str(), new_offset);
            if (i > new_offset) {
                new_offset = i;
            } else if (nextTextNode(focus_node)) |next| {
                new_node = next;
                new_offset = nextWordEnd(next.getData().str(), 0);
            }
        } else {
            const i = prevWordStart(new_node.getData().str(), new_offset);
            if (i < new_offset) {
                new_offset = i;
            } else if (prevTextNode(focus_node)) |prev| {
                new_node = prev;
                new_offset = prevWordStart(prev.getData().str(), @intCast(prev.getData().len));
            }
        }
    } else {
        // Search and apply rules on the next Text Node.
        // This is either next (on forward) or previous (on backward).

        if (forward) {
            const child = focus_node.getChildAt(focus_offset) orelse {
                if (nextTextNodeAfter(focus_node)) |next| {
                    new_node = next;
                    new_offset = nextWordEnd(next.getData().str(), 0);
                }
                return self.applyModify(alter, new_node, new_offset, page);
            };

            const t = if (isTextNode(child)) child else nextTextNode(child) orelse {
                return self.applyModify(alter, new_node, new_offset, page);
            };

            new_node = t;
            new_offset = nextWordEnd(t.getData().str(), 0);
        } else {
            var idx = focus_offset;
            while (idx > 0) {
                idx -= 1;
                const child = focus_node.getChildAt(idx) orelse break;
                var bottom = child;
                while (bottom.lastChild()) |c| bottom = c;
                if (isTextNode(bottom)) {
                    new_node = bottom;
                    new_offset = prevWordStart(bottom.getData().str(), bottom.getLength());
                    break;
                }
            }
        }
    }

    try self.applyModify(alter, new_node, new_offset, page);
}

fn applyModify(self: *Selection, alter: ModifyAlter, new_node: *Node, new_offset: u32, page: *Page) !void {
    switch (alter) {
        .move => {
            const new_range = try Range.init(page);
            try new_range.setStart(new_node, new_offset);
            try new_range.setEnd(new_node, new_offset);
            self._range = new_range;
            self._direction = .none;
            try dispatchSelectionChangeEvent(page);
        },
        .extend => try self.extend(new_node, new_offset, page),
    }
}

pub fn selectAllChildren(self: *Selection, parent: *Node, page: *Page) !void {
    if (parent._type == .document_type) return error.InvalidNodeType;

    // If the node is not contained in the document, do not change the selection
    if (!page.document.asNode().contains(parent)) {
        return;
    }

    const range = try Range.init(page);
    try range.setStart(parent, 0);

    const child_count = parent.getChildrenCount();
    try range.setEnd(parent, @intCast(child_count));

    self._range = range;
    self._direction = .forward;
    try dispatchSelectionChangeEvent(page);
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
    try dispatchSelectionChangeEvent(page);
}

pub fn collapse(self: *Selection, _node: ?*Node, _offset: ?u32, page: *Page) !void {
    const node = _node orelse {
        try self.removeAllRanges(page);
        return;
    };

    if (node._type == .document_type) return error.InvalidNodeType;

    const offset = _offset orelse 0;
    if (offset > node.getLength()) {
        return error.IndexSizeError;
    }

    // If the node is not contained in the document, do not change the selection
    if (!page.document.asNode().contains(node)) {
        return;
    }

    const range = try Range.init(page);
    try range.setStart(node, offset);
    try range.setEnd(node, offset);

    self._range = range;
    self._direction = .none;
    try dispatchSelectionChangeEvent(page);
}

pub fn toString(self: *const Selection, page: *Page) ![]const u8 {
    const range = self._range orelse return "";
    return try range.toString(page);
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
    pub const collapseToStart = bridge.function(Selection.collapseToStart, .{ .dom_exception = true });
    pub const containsNode = bridge.function(Selection.containsNode, .{});
    pub const deleteFromDocument = bridge.function(Selection.deleteFromDocument, .{});
    pub const empty = bridge.function(Selection.removeAllRanges, .{});
    pub const extend = bridge.function(Selection.extend, .{ .dom_exception = true });
    // unimplemented: getComposedRanges
    pub const getRangeAt = bridge.function(Selection.getRangeAt, .{ .dom_exception = true });
    pub const modify = bridge.function(Selection.modify, .{});
    pub const removeAllRanges = bridge.function(Selection.removeAllRanges, .{});
    pub const removeRange = bridge.function(Selection.removeRange, .{ .dom_exception = true });
    pub const selectAllChildren = bridge.function(Selection.selectAllChildren, .{ .dom_exception = true });
    pub const setBaseAndExtent = bridge.function(Selection.setBaseAndExtent, .{ .dom_exception = true });
    pub const setPosition = bridge.function(Selection.collapse, .{ .dom_exception = true });
    pub const toString = bridge.function(Selection.toString, .{});
};

const testing = @import("../../testing.zig");
test "WebApi: Selection" {
    try testing.htmlRunner("selection.html", .{});
}
