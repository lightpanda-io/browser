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

const testing = @import("../../testing.zig");
test "Browser.DOM.NodeFilter" {
    var runner = try testing.jsRunner(testing.tracking_allocator, .{});
    defer runner.deinit();

    try runner.testCases(&.{
        .{ "NodeFilter.FILTER_ACCEPT", "1" },
        .{ "NodeFilter.FILTER_REJECT", "2" },
        .{ "NodeFilter.FILTER_SKIP", "3" },
        .{ "NodeFilter.SHOW_ALL", "4294967295" },
        .{ "NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_COMMENT", "129" },
    }, .{});
}
