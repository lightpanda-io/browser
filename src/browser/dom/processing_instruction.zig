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
const Page = @import("../page.zig").Page;

// https://dom.spec.whatwg.org/#processinginstruction
pub const ProcessingInstruction = struct {
    pub const Self = parser.ProcessingInstruction;

    // TODO for libdom processing instruction inherit from node.
    // But the spec says it must inherit from CDATA.
    pub const prototype = *Node;
    pub const subtype = .node;

    pub fn get_target(self: *parser.ProcessingInstruction) ![]const u8 {
        // libdom stores the ProcessingInstruction target in the node's name.
        return try parser.nodeName(parser.processingInstructionToNode(self));
    }

    // There's something wrong when we try to clone a ProcessInstruction normally.
    // The resulting object can't be cast back into a node (it crashes). This is
    // a simple workaround.
    pub fn _cloneNode(self: *parser.ProcessingInstruction, _: ?bool, page: *Page) !*parser.ProcessingInstruction {
        return try parser.documentCreateProcessingInstruction(
            @ptrCast(page.window.document),
            try get_target(self),
            (try get_data(self)) orelse "",
        );
    }

    pub fn get_data(self: *parser.ProcessingInstruction) !?[]const u8 {
        return parser.nodeValue(parser.processingInstructionToNode(self));
    }

    pub fn set_data(self: *parser.ProcessingInstruction, data: []u8) !void {
        try parser.nodeSetValue(parser.processingInstructionToNode(self), data);
    }

    // netsurf's ProcessInstruction doesn't implement the dom_node_get_attributes
    // and thus will crash if we try to call nodeIsEqualNode.
    pub fn _isEqualNode(self: *parser.ProcessingInstruction, other_node: *parser.Node) !bool {
        if (parser.nodeType(other_node) != .processing_instruction) {
            return false;
        }

        const other: *parser.ProcessingInstruction = @ptrCast(other_node);

        if (std.mem.eql(u8, try get_target(self), try get_target(other)) == false) {
            return false;
        }

        {
            const self_data = try get_data(self);
            const other_data = try get_data(other);
            if (self_data == null and other_data != null) {
                return false;
            }
            if (self_data != null and other_data == null) {
                return false;
            }
            if (std.mem.eql(u8, self_data.?, other_data.?) == false) {
                return false;
            }
        }

        return true;
    }
};

const testing = @import("../../testing.zig");
test "Browser: DOM.ProcessingInstruction" {
    try testing.htmlRunner("dom/processing_instruction.html");
}
