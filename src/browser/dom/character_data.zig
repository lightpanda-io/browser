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

const testing = @import("../../testing.zig");
test "Browser.DOM.CharacterData" {
    var runner = try testing.jsRunner(testing.allocator, .{});
    defer runner.deinit();

    try runner.testCases(&.{
        .{ "let link = document.getElementById('link')", "undefined" },
        .{ "let cdata = link.firstChild", "undefined" },
        .{ "cdata.data", "OK" },
    }, .{});

    try runner.testCases(&.{
        .{ "cdata.data = 'OK modified'", "OK modified" },
        .{ "cdata.data === 'OK modified'", "true" },
        .{ "cdata.data = 'OK'", "OK" },
    }, .{});

    try runner.testCases(&.{
        .{ "cdata.length === 2", "true" },
    }, .{});

    try runner.testCases(&.{
        .{ "cdata.nextElementSibling === null", "true" },
        // create a next element
        .{ "let next = document.createElement('a')", "undefined" },
        .{ "link.appendChild(next, cdata) !== undefined", "true" },
        .{ "cdata.nextElementSibling.localName === 'a' ", "true" },
    }, .{});

    try runner.testCases(&.{
        .{ "cdata.previousElementSibling === null", "true" },
        // create a prev element
        .{ "let prev = document.createElement('div')", "undefined" },
        .{ "link.insertBefore(prev, cdata) !== undefined", "true" },
        .{ "cdata.previousElementSibling.localName === 'div' ", "true" },
    }, .{});

    try runner.testCases(&.{
        .{ "cdata.appendData(' modified')", "undefined" },
        .{ "cdata.data === 'OK modified' ", "true" },
    }, .{});

    try runner.testCases(&.{
        .{ "cdata.deleteData('OK'.length, ' modified'.length)", "undefined" },
        .{ "cdata.data == 'OK'", "true" },
    }, .{});

    try runner.testCases(&.{
        .{ "cdata.insertData('OK'.length-1, 'modified')", "undefined" },
        .{ "cdata.data == 'OmodifiedK'", "true" },
    }, .{});

    try runner.testCases(&.{
        .{ "cdata.replaceData('OK'.length-1, 'modified'.length, 'replaced')", "undefined" },
        .{ "cdata.data == 'OreplacedK'", "true" },
    }, .{});

    try runner.testCases(&.{
        .{ "cdata.substringData('OK'.length-1, 'replaced'.length) == 'replaced'", "true" },
        .{ "cdata.substringData('OK'.length-1, 0) == ''", "true" },
    }, .{});
}
