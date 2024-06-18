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

const jsruntime = @import("jsruntime");
const Case = jsruntime.test_utils.Case;
const checkCases = jsruntime.test_utils.checkCases;

const parser = @import("netsurf");
const Node = @import("node.zig").Node;

// https://dom.spec.whatwg.org/#processinginstruction
pub const ProcessingInstruction = struct {
    pub const Self = parser.ProcessingInstruction;

    // TODO for libdom processing instruction inherit from node.
    // But the spec says it must inherit from CDATA.
    pub const prototype = *Node;
    pub const mem_guarantied = true;

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

pub fn testExecFn(
    _: std.mem.Allocator,
    js_env: *jsruntime.Env,
) anyerror!void {
    var createProcessingInstruction = [_]Case{
        .{ .src = "let pi = document.createProcessingInstruction('foo', 'bar')", .ex = "undefined" },
        .{ .src = "pi.target", .ex = "foo" },
        .{ .src = "pi.data", .ex = "bar" },
        .{ .src = "pi.data = 'foo'", .ex = "foo" },
        .{ .src = "pi.data", .ex = "foo" },

        .{ .src = "let pi2 = pi.cloneNode()", .ex = "undefined" },
    };
    try checkCases(js_env, &createProcessingInstruction);
}
