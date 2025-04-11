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
const Comment = @import("comment.zig").Comment;
const Text = @import("text.zig");
const ProcessingInstruction = @import("processing_instruction.zig").ProcessingInstruction;
const HTMLElem = @import("../html/elements.zig");

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
    pub const mem_guarantied = true;
    pub const sub_type = "node";

    // JS funcs
    // --------

    // Read attributes

    pub fn get_length(self: *parser.CharacterData) !u32 {
        return try parser.characterDataLength(self);
    }

    pub fn get_nextElementSibling(self: *parser.CharacterData) !?HTMLElem.Union {
        const res = try parser.nodeNextElementSibling(parser.characterDataToNode(self));
        if (res == null) {
            return null;
        }
        return try HTMLElem.toInterface(HTMLElem.Union, res.?);
    }

    pub fn get_previousElementSibling(self: *parser.CharacterData) !?HTMLElem.Union {
        const res = try parser.nodePreviousElementSibling(parser.characterDataToNode(self));
        if (res == null) {
            return null;
        }
        return try HTMLElem.toInterface(HTMLElem.Union, res.?);
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
};

// Tests
// -----

pub fn testExecFn(
    _: std.mem.Allocator,
    js_env: *jsruntime.Env,
) anyerror!void {
    var get_data = [_]Case{
        .{ .src = "let link = document.getElementById('link')", .ex = "undefined" },
        .{ .src = "let cdata = link.firstChild", .ex = "undefined" },
        .{ .src = "cdata.data", .ex = "OK" },
    };
    try checkCases(js_env, &get_data);

    var set_data = [_]Case{
        .{ .src = "cdata.data = 'OK modified'", .ex = "OK modified" },
        .{ .src = "cdata.data === 'OK modified'", .ex = "true" },
        .{ .src = "cdata.data = 'OK'", .ex = "OK" },
    };
    try checkCases(js_env, &set_data);

    var get_length = [_]Case{
        .{ .src = "cdata.length === 2", .ex = "true" },
    };
    try checkCases(js_env, &get_length);

    var get_next_elem_sibling = [_]Case{
        .{ .src = "cdata.nextElementSibling === null", .ex = "true" },
        // create a next element
        .{ .src = "let next = document.createElement('a')", .ex = "undefined" },
        .{ .src = "link.appendChild(next, cdata) !== undefined", .ex = "true" },
        .{ .src = "cdata.nextElementSibling.localName === 'a' ", .ex = "true" },
    };
    try checkCases(js_env, &get_next_elem_sibling);

    var get_prev_elem_sibling = [_]Case{
        .{ .src = "cdata.previousElementSibling === null", .ex = "true" },
        // create a prev element
        .{ .src = "let prev = document.createElement('div')", .ex = "undefined" },
        .{ .src = "link.insertBefore(prev, cdata) !== undefined", .ex = "true" },
        .{ .src = "cdata.previousElementSibling.localName === 'div' ", .ex = "true" },
    };
    try checkCases(js_env, &get_prev_elem_sibling);

    var append_data = [_]Case{
        .{ .src = "cdata.appendData(' modified')", .ex = "undefined" },
        .{ .src = "cdata.data === 'OK modified' ", .ex = "true" },
    };
    try checkCases(js_env, &append_data);

    var delete_data = [_]Case{
        .{ .src = "cdata.deleteData('OK'.length, ' modified'.length)", .ex = "undefined" },
        .{ .src = "cdata.data == 'OK'", .ex = "true" },
    };
    try checkCases(js_env, &delete_data);

    var insert_data = [_]Case{
        .{ .src = "cdata.insertData('OK'.length-1, 'modified')", .ex = "undefined" },
        .{ .src = "cdata.data == 'OmodifiedK'", .ex = "true" },
    };
    try checkCases(js_env, &insert_data);

    var replace_data = [_]Case{
        .{ .src = "cdata.replaceData('OK'.length-1, 'modified'.length, 'replaced')", .ex = "undefined" },
        .{ .src = "cdata.data == 'OreplacedK'", .ex = "true" },
    };
    try checkCases(js_env, &replace_data);

    var substring_data = [_]Case{
        .{ .src = "cdata.substringData('OK'.length-1, 'replaced'.length) == 'replaced'", .ex = "true" },
        .{ .src = "cdata.substringData('OK'.length-1, 0) == ''", .ex = "true" },
    };
    try checkCases(js_env, &substring_data);
}
