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

const js = @import("../../js/js.zig");
const Frame = @import("../../Frame.zig");
const Node = @import("../Node.zig");
const CData = @import("../CData.zig");
const Slot = @import("../element/html/Slot.zig");
const slotting = @import("../element/slotting.zig");

const Text = @This();

_proto: *CData,

pub fn init(str: ?js.NullableString, frame: *Frame) !*Text {
    const node = try Frame.node_factory.createTextNode(frame, if (str) |s| s.value else "");
    return node.as(Text);
}

// This Text node's own data (getWholeText below spans adjacent Text nodes).
pub fn ownData(self: *const Text) []const u8 {
    return self._proto._data.str();
}

// The concatenated data of the contiguous exclusive Text nodes (adjacent
// Text siblings on both sides of this one), in tree order.
pub fn getWholeText(self: *Text, frame: *Frame) ![]const u8 {
    const node = self._proto.asNode();

    var first = node;
    while (first.previousSibling()) |prev| {
        if (!isExclusiveTextNode(prev)) {
            break;
        }
        first = prev;
    }

    // Common case: no adjacent text nodes, return our data directly.
    const has_next_text = if (node.nextSibling()) |next| isExclusiveTextNode(next) else false;
    if (first == node and !has_next_text) {
        return self._proto._data.str();
    }

    var buf: std.ArrayList(u8) = .empty;
    var current: ?*Node = first;
    while (current) |cur| : (current = cur.nextSibling()) {
        const text = cur.is(Text) orelse break;
        try buf.appendSlice(frame.local_arena, text.ownData());
    }
    return buf.items;
}

fn isExclusiveTextNode(node: *Node) bool {
    return node.is(Text) != null;
}

pub fn getAssignedSlot(self: *Text, frame: *Frame) ?*Slot {
    return slotting.findSlot(self._proto.asNode(), true, frame);
}

pub fn splitText(self: *Text, offset: usize, frame: *Frame) !*Text {
    const data = self._proto._data.str();

    const byte_offset = CData.utf16OffsetToUtf8(data, offset) catch return error.IndexSizeError;

    const new_data = data[byte_offset..];
    const new_node = try Frame.node_factory.createTextNode(frame, new_data);
    const new_text = new_node.as(Text);

    const node = self._proto.asNode();

    // Per DOM spec splitText: insert first (step 7a), then update ranges (7b-7e),
    // then truncate original node (step 8).
    if (node.parentNode()) |parent| {
        const next_sibling = node.nextSibling();
        _ = try parent.insertBefore(new_node, next_sibling, frame);

        // splitText-specific range updates (steps 7b-7e)
        if (parent.getChildIndex(node)) |node_index| {
            frame.updateRangesForSplitText(node, new_node, @intCast(offset), parent, node_index);
        }
    }

    // Step 8: truncate original node via replaceData(offset, count, "").
    // Use replaceData instead of setData so live range updates fire
    // (matters for detached text nodes where steps 7b-7e were skipped).
    const length = self._proto.getLength();
    try self._proto.replaceData(offset, length - offset, "", frame);

    return new_text;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Text);

    pub const Meta = struct {
        pub const name = "Text";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(Text.init, .{});
    pub const wholeText = bridge.accessor(Text.getWholeText, null, .{});
    pub const assignedSlot = bridge.accessor(Text.getAssignedSlot, null, .{});
    pub const splitText = bridge.function(Text.splitText, .{});
};
