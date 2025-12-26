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
const js = @import("../js/js.zig");

const Node = @import("Node.zig");
const Range = @import("Range.zig");

const AbstractRange = @This();

pub const _prototype_root = true;

_type: Type,

_end_offset: u32,
_start_offset: u32,
_end_container: *Node,
_start_container: *Node,

pub const Type = union(enum) {
    range: *Range,
    // TODO: static_range: *StaticRange,
};

pub fn as(self: *AbstractRange, comptime T: type) *T {
    return self.is(T).?;
}

pub fn is(self: *AbstractRange, comptime T: type) ?*T {
    switch (self._type) {
        .range => |r| return if (T == Range) r else null,
    }
}

pub fn getStartContainer(self: *const AbstractRange) *Node {
    return self._start_container;
}

pub fn getStartOffset(self: *const AbstractRange) u32 {
    return self._start_offset;
}

pub fn getEndContainer(self: *const AbstractRange) *Node {
    return self._end_container;
}

pub fn getEndOffset(self: *const AbstractRange) u32 {
    return self._end_offset;
}

pub fn getCollapsed(self: *const AbstractRange) bool {
    return self._start_container == self._end_container and
        self._start_offset == self._end_offset;
}

pub fn isStartAfterEnd(self: *const AbstractRange) bool {
    return compareBoundaryPoints(
        self._start_container,
        self._start_offset,
        self._end_container,
        self._end_offset,
    ) == .after;
}

const BoundaryComparison = enum {
    before,
    equal,
    after,
};

fn compareBoundaryPoints(
    node_a: *Node,
    offset_a: u32,
    node_b: *Node,
    offset_b: u32,
) BoundaryComparison {
    // If same container, just compare offsets
    if (node_a == node_b) {
        if (offset_a < offset_b) return .before;
        if (offset_a > offset_b) return .after;
        return .equal;
    }

    // Check if one contains the other
    if (isAncestorOf(node_a, node_b)) {
        // A contains B, so A's position comes before B
        // But we need to check if the offset in A comes after B
        var child = node_b;
        var parent = child.parentNode();
        while (parent) |p| {
            if (p == node_a) {
                const child_index = p.getChildIndex(child) orelse unreachable;
                if (offset_a <= child_index) {
                    return .before;
                }
                return .after;
            }
            child = p;
            parent = p.parentNode();
        }
        unreachable;
    }

    if (isAncestorOf(node_b, node_a)) {
        // B contains A, so B's position comes before A
        var child = node_a;
        var parent = child.parentNode();
        while (parent) |p| {
            if (p == node_b) {
                const child_index = p.getChildIndex(child) orelse unreachable;
                if (child_index < offset_b) {
                    return .before;
                }
                return .after;
            }
            child = p;
            parent = p.parentNode();
        }
        unreachable;
    }

    // Neither contains the other, find their relative position in tree order
    // Walk up from A to find all ancestors
    var current = node_a;
    var a_count: usize = 0;
    var a_ancestors: [64]*Node = undefined;
    while (a_count < 64) {
        a_ancestors[a_count] = current;
        a_count += 1;
        current = current.parentNode() orelse break;
    }

    // Walk up from B and find first common ancestor
    current = node_b;
    while (current.parentNode()) |parent| {
        for (a_ancestors[0..a_count]) |ancestor| {
            if (ancestor != parent) {
                continue;
            }

            // Found common ancestor
            // Now compare positions of the children in this ancestor
            const a_child = blk: {
                var node = node_a;
                while (node.parentNode()) |p| {
                    if (p == parent) break :blk node;
                    node = p;
                }
                unreachable;
            };
            const b_child = current;

            const a_index = parent.getChildIndex(a_child) orelse unreachable;
            const b_index = parent.getChildIndex(b_child) orelse unreachable;

            if (a_index < b_index) {
                return .before;
            }
            if (a_index > b_index) {
                return .after;
            }
            return .equal;
        }
        current = parent;
    }

    // Should not reach here if nodes are in the same tree
    return .before;
}

fn isAncestorOf(potential_ancestor: *Node, node: *Node) bool {
    var current = node.parentNode();
    while (current) |parent| {
        if (parent == potential_ancestor) {
            return true;
        }
        current = parent.parentNode();
    }
    return false;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(AbstractRange);

    pub const Meta = struct {
        pub const name = "AbstractRange";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const startContainer = bridge.accessor(AbstractRange.getStartContainer, null, .{});
    pub const startOffset = bridge.accessor(AbstractRange.getStartOffset, null, .{});
    pub const endContainer = bridge.accessor(AbstractRange.getEndContainer, null, .{});
    pub const endOffset = bridge.accessor(AbstractRange.getEndOffset, null, .{});
    pub const collapsed = bridge.accessor(AbstractRange.getCollapsed, null, .{});
};
