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
const Page = @import("../page.zig").Page;

pub const Interfaces = .{
    AbstractRange,
    Range,
};

pub const AbstractRange = struct {
    collapsed: bool,
    end_container: *parser.Node,
    end_offset: i32,
    start_container: *parser.Node,
    start_offset: i32,

    pub fn updateCollapsed(self: *AbstractRange) void {
        // TODO: Eventually, compare properly.
        self.collapsed = false;
    }

    pub fn get_collapsed(self: *const AbstractRange) bool {
        return self.collapsed;
    }

    pub fn get_endContainer(self: *const AbstractRange) *parser.Node {
        return self.end_container;
    }

    pub fn get_endOffset(self: *const AbstractRange) i32 {
        return self.end_offset;
    }

    pub fn get_startContainer(self: *const AbstractRange) *parser.Node {
        return self.start_container;
    }

    pub fn get_startOffset(self: *const AbstractRange) i32 {
        return self.start_offset;
    }
};

pub const Range = struct {
    pub const prototype = *AbstractRange;

    proto: AbstractRange,

    pub fn constructor() Range {
        const proto: AbstractRange = .{
            .collapsed = true,
            .end_container = undefined,
            .end_offset = 0,
            .start_container = undefined,
            .start_offset = 0,
        };

        return .{ .proto = proto };
    }

    pub fn _setStart(self: *Range, node: *parser.Node, offset: i32) void {
        self.proto.start_container = node;
        self.proto.start_offset = offset;
        self.proto.updateCollapsed();
    }

    pub fn _setEnd(self: *Range, node: *parser.Node, offset: i32) void {
        self.proto.end_container = node;
        self.proto.end_offset = offset;
        self.proto.updateCollapsed();
    }

    pub fn _createContextualFragment(_: *Range, fragment: []const u8, page: *Page) !*parser.DocumentFragment {
        const document_html = page.window.document;
        const document = parser.documentHTMLToDocument(document_html);
        const doc_frag = try parser.documentParseFragmentFromStr(document, fragment);
        return doc_frag;
    }
};

const testing = @import("../../testing.zig");
test "Browser.Range" {
    var runner = try testing.jsRunner(testing.tracking_allocator, .{});
    defer runner.deinit();

    try runner.testCases(&.{
        // Test Range constructor
        .{ "let range = new Range()", "undefined" },
        .{ "range instanceof Range", "true" },
        .{ "range instanceof AbstractRange", "true" },

        // Test initial state - collapsed range
        .{ "range.collapsed", "true" },
        .{ "range.startOffset", "0" },
        .{ "range.endOffset", "0" },

        // Test document.createRange()
        .{ "let docRange = document.createRange()", "undefined" },
        .{ "docRange instanceof Range", "true" },
        .{ "docRange.collapsed", "true" },
    }, .{});
}
