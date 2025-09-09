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
const Env = @import("../env.zig").Env;
const Node = @import("node.zig").Node;

pub const NodeFilter = struct {
    pub const _FILTER_ACCEPT: u16 = 1;
    pub const _FILTER_REJECT: u16 = 2;
    pub const _FILTER_SKIP: u16 = 3;

    pub const _SHOW_ALL: u32 = std.math.maxInt(u32);
    pub const _SHOW_ELEMENT: u32 = 0b1;
    pub const _SHOW_ATTRIBUTE: u32 = 0b10;
    pub const _SHOW_TEXT: u32 = 0b100;
    pub const _SHOW_CDATA_SECTION: u32 = 0b1000;
    pub const _SHOW_ENTITY_REFERENCE: u32 = 0b10000;
    pub const _SHOW_ENTITY: u32 = 0b100000;
    pub const _SHOW_PROCESSING_INSTRUCTION: u32 = 0b1000000;
    pub const _SHOW_COMMENT: u32 = 0b10000000;
    pub const _SHOW_DOCUMENT: u32 = 0b100000000;
    pub const _SHOW_DOCUMENT_TYPE: u32 = 0b1000000000;
    pub const _SHOW_DOCUMENT_FRAGMENT: u32 = 0b10000000000;
    pub const _SHOW_NOTATION: u32 = 0b100000000000;
};

const VerifyResult = enum { accept, skip, reject };

pub fn verify(what_to_show: u32, filter: ?Env.Function, node: *parser.Node) !VerifyResult {
    const node_type = try parser.nodeType(node);

    // Verify that we can show this node type.
    if (!switch (node_type) {
        .attribute => what_to_show & NodeFilter._SHOW_ATTRIBUTE != 0,
        .cdata_section => what_to_show & NodeFilter._SHOW_CDATA_SECTION != 0,
        .comment => what_to_show & NodeFilter._SHOW_COMMENT != 0,
        .document => what_to_show & NodeFilter._SHOW_DOCUMENT != 0,
        .document_fragment => what_to_show & NodeFilter._SHOW_DOCUMENT_FRAGMENT != 0,
        .document_type => what_to_show & NodeFilter._SHOW_DOCUMENT_TYPE != 0,
        .element => what_to_show & NodeFilter._SHOW_ELEMENT != 0,
        .entity => what_to_show & NodeFilter._SHOW_ENTITY != 0,
        .entity_reference => what_to_show & NodeFilter._SHOW_ENTITY_REFERENCE != 0,
        .notation => what_to_show & NodeFilter._SHOW_NOTATION != 0,
        .processing_instruction => what_to_show & NodeFilter._SHOW_PROCESSING_INSTRUCTION != 0,
        .text => what_to_show & NodeFilter._SHOW_TEXT != 0,
    }) return .reject;

    // Verify that we aren't filtering it out.
    if (filter) |f| {
        const acceptance = try f.call(u16, .{try Node.toInterface(node)});
        return switch (acceptance) {
            NodeFilter._FILTER_ACCEPT => .accept,
            NodeFilter._FILTER_REJECT => .reject,
            NodeFilter._FILTER_SKIP => .skip,
            else => .reject,
        };
    } else return .accept;
}

const testing = @import("../../testing.zig");
test "Browser: DOM.NodeFilter" {
    try testing.htmlRunner("dom/node_filter.html");
}
