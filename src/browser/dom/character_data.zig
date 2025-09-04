// Copyright (C) 2023-2024  Lightpanda (Selecy SAS)
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

const parser = @import("../netsurf.zig");

const Node = @import("node.zig").Node;
const Comment = @import("comment.zig").Comment;
const Text = @import("text.zig");
const ProcessingInstruction = @import("processing_instruction.zig").ProcessingInstruction;
const Element = @import("element.zig").Element;
const ElementUnion = @import("element.zig").Union;

// CharacterData interfaces
pub const Interfaces = .{
    Comment,
    Text.Text,
    Text.Interfaces,
    ProcessingInstruction,
};

// CharacterData implementation
pub const CharacterData = struct {
    pub const Self = parser.CharacterData;
    pub const prototype = *Node;
    pub const subtype = .node;

    // JS funcs
    // --------

    // Read attributes

    pub fn get_length(self: *parser.CharacterData) !u32 {
        return try parser.characterDataLength(self);
    }

    pub fn get_nextElementSibling(self: *parser.CharacterData) !?ElementUnion {
        const res = try parser.nodeNextElementSibling(parser.characterDataToNode(self));
        if (res == null) {
            return null;
        }
        return try Element.toInterface(res.?);
    }

    pub fn get_previousElementSibling(self: *parser.CharacterData) !?ElementUnion {
        const res = try parser.nodePreviousElementSibling(parser.characterDataToNode(self));
        if (res == null) {
            return null;
        }
        return try Element.toInterface(res.?);
    }

    // Read/Write attributes

    pub fn get_data(self: *parser.CharacterData) ![]const u8 {
        return try parser.characterDataData(self);
    }

    pub fn set_data(self: *parser.CharacterData, data: []const u8) !void {
        return try parser.characterDataSetData(self, data);
    }

    // JS methods
    // ----------

    pub fn _appendData(self: *parser.CharacterData, data: []const u8) !void {
        return try parser.characterDataAppendData(self, data);
    }

    pub fn _deleteData(self: *parser.CharacterData, offset: u32, count: u32) !void {
        return try parser.characterDataDeleteData(self, offset, count);
    }

    pub fn _insertData(self: *parser.CharacterData, offset: u32, data: []const u8) !void {
        return try parser.characterDataInsertData(self, offset, data);
    }

    pub fn _replaceData(self: *parser.CharacterData, offset: u32, count: u32, data: []const u8) !void {
        return try parser.characterDataReplaceData(self, offset, count, data);
    }

    pub fn _substringData(self: *parser.CharacterData, offset: u32, count: u32) ![]const u8 {
        return try parser.characterDataSubstringData(self, offset, count);
    }

    // netsurf's CharacterData (text, comment) doesn't implement the
    // dom_node_get_attributes and thus will crash if we try to call nodeIsEqualNode.
    pub fn _isEqualNode(self: *parser.CharacterData, other_node: *parser.Node) !bool {
        if (try parser.nodeType(@ptrCast(@alignCast(self))) != try parser.nodeType(other_node)) {
            return false;
        }

        const other: *parser.CharacterData = @ptrCast(other_node);
        if (std.mem.eql(u8, try get_data(self), try get_data(other)) == false) {
            return false;
        }

        return true;
    }

    pub fn _before(self: *parser.CharacterData, nodes: []const Node.NodeOrText) !void {
        const ref_node = parser.characterDataToNode(self);
        return Node.before(ref_node, nodes);
    }

    pub fn _after(self: *parser.CharacterData, nodes: []const Node.NodeOrText) !void {
        const ref_node = parser.characterDataToNode(self);
        return Node.after(ref_node, nodes);
    }
};

// Tests
// -----

const testing = @import("../../testing.zig");
test "Browser: DOM.CharacterData" {
    try testing.htmlRunner("dom/character_data.html");
}
