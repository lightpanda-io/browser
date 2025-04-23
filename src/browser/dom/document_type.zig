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

// WEB IDL https://dom.spec.whatwg.org/#documenttype
pub const DocumentType = struct {
    pub const Self = parser.DocumentType;
    pub const prototype = *Node;
    pub const subtype = .node;

    pub fn get_name(self: *parser.DocumentType) ![]const u8 {
        return try parser.documentTypeGetName(self);
    }

    pub fn get_publicId(self: *parser.DocumentType) ![]const u8 {
        return try parser.documentTypeGetPublicId(self);
    }

    pub fn get_systemId(self: *parser.DocumentType) ![]const u8 {
        return try parser.documentTypeGetSystemId(self);
    }

    // netsurf's DocumentType doesn't implement the dom_node_get_attributes
    // and thus will crash if we try to call nodeIsEqualNode.
    pub fn _isEqualNode(self: *parser.DocumentType, other_node: *parser.Node) !bool {
        if (try parser.nodeType(other_node) != .document_type) {
            return false;
        }

        const other: *parser.DocumentType = @ptrCast(other_node);
        if (std.mem.eql(u8, try get_name(self), try get_name(other)) == false) {
            return false;
        }
        if (std.mem.eql(u8, try get_publicId(self), try get_publicId(other)) == false) {
            return false;
        }
        if (std.mem.eql(u8, try get_systemId(self), try get_systemId(other)) == false) {
            return false;
        }
        return true;
    }
};

const testing = @import("../../testing.zig");
test "Browser.DOM.DocumentType" {
    var runner = try testing.jsRunner(testing.tracking_allocator, .{});
    defer runner.deinit();

    try runner.testCases(&.{
        .{ "let dt1 = document.implementation.createDocumentType('qname1', 'pid1', 'sys1');", "undefined" },
        .{ "let dt2 = document.implementation.createDocumentType('qname2', 'pid2', 'sys2');", "undefined" },
        .{ "let dt3 = document.implementation.createDocumentType('qname1', 'pid1', 'sys1');", "undefined" },
        .{ "dt1.isEqualNode(dt1)", "true" },
        .{ "dt1.isEqualNode(dt3)", "true" },
        .{ "dt1.isEqualNode(dt2)", "false" },
        .{ "dt2.isEqualNode(dt3)", "false" },
        .{ "dt1.isEqualNode(document)", "false" },
        .{ "document.isEqualNode(dt1)", "false" },
    }, .{});
}
