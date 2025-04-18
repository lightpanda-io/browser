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

// https://dom.spec.whatwg.org/#processinginstruction
pub const ProcessingInstruction = struct {
    pub const Self = parser.ProcessingInstruction;

    // TODO for libdom processing instruction inherit from node.
    // But the spec says it must inherit from CDATA.
    pub const prototype = *Node;
    pub const subtype = "node";

    pub fn get_target(self: *parser.ProcessingInstruction) ![]const u8 {
        // libdom stores the ProcessingInstruction target in the node's name.
        return try parser.nodeName(parser.processingInstructionToNode(self));
    }

    pub fn _cloneNode(self: *parser.ProcessingInstruction, _: ?bool) !*parser.ProcessingInstruction {
        return try parser.processInstructionCopy(self);
    }

    pub fn get_data(self: *parser.ProcessingInstruction) !?[]const u8 {
        return try parser.nodeValue(parser.processingInstructionToNode(self));
    }

    pub fn set_data(self: *parser.ProcessingInstruction, data: []u8) !void {
        try parser.nodeSetValue(parser.processingInstructionToNode(self), data);
    }
};

const testing = @import("../../testing.zig");
test "Browser.DOM.ProcessingInstruction" {
    var runner = try testing.jsRunner(testing.tracking_allocator, .{});
    defer runner.deinit();

    try runner.testCases(&.{
        .{ "let pi = document.createProcessingInstruction('foo', 'bar')", "undefined" },
        .{ "pi.target", "foo" },
        .{ "pi.data", "bar" },
        .{ "pi.data = 'foo'", "foo" },
        .{ "pi.data", "foo" },

        .{ "let pi2 = pi.cloneNode()", "undefined" },
    }, .{});
}
