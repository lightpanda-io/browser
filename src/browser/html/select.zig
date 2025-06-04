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
const HTMLElement = @import("elements.zig").HTMLElement;
const Page = @import("../page.zig").Page;

pub const HTMLSelectElement = struct {
    pub const Self = parser.Select;
    pub const prototype = *HTMLElement;
    pub const subtype = .node;

    pub fn get_length(select: *parser.Select) !u32 {
        return parser.selectGetLength(select);
    }

    pub fn get_form(select: *parser.Select) !?*parser.Form {
        return parser.selectGetForm(select);
    }

    pub fn get_name(select: *parser.Select) ![]const u8 {
        return parser.selectGetName(select);
    }
    pub fn set_name(select: *parser.Select, name: []const u8) !void {
        return parser.selectSetName(select, name);
    }

    pub fn get_disabled(select: *parser.Select) !bool {
        return parser.selectGetDisabled(select);
    }
    pub fn set_disabled(select: *parser.Select, disabled: bool) !void {
        return parser.selectSetDisabled(select, disabled);
    }

    pub fn get_multiple(select: *parser.Select) !bool {
        return parser.selectGetMultiple(select);
    }
    pub fn set_multiple(select: *parser.Select, multiple: bool) !void {
        return parser.selectSetMultiple(select, multiple);
    }

    pub fn get_selectedIndex(select: *parser.Select, page: *Page) !i32 {
        const state = try page.getOrCreateNodeState(@ptrCast(select));
        const selected_index = try parser.selectGetSelectedIndex(select);

        // See the explicit_index_set field documentation
        if (!state.explicit_index_set) {
            if (selected_index == -1) {
                if (try parser.selectGetMultiple(select) == false) {
                    if (try get_length(select) > 0) {
                        return 0;
                    }
                }
            }
        }
        return selected_index;
    }

    // Libdom's dom_html_select_select_set_selected_index will crash if index
    // is out of range, and it doesn't properly unset options
    pub fn set_selectedIndex(select: *parser.Select, index: i32, page: *Page) !void {
        var state = try page.getOrCreateNodeState(@ptrCast(select));
        state.explicit_index_set = true;

        const options = try parser.selectGetOptions(select);
        const len = try parser.optionCollectionGetLength(options);
        for (0..len) |i| {
            const option = try parser.optionCollectionItem(options, @intCast(i));
            try parser.optionSetSelected(option, false);
        }
        if (index >= 0 and index < try get_length(select)) {
            const option = try parser.optionCollectionItem(options, @intCast(index));
            try parser.optionSetSelected(option, true);
        }
    }
};

const testing = @import("../../testing.zig");
test "Browser.HTML.Select" {
    var runner = try testing.jsRunner(testing.tracking_allocator, .{ .html = 
        \\ <form id=f1>
        \\  <select id=s1 name=s1><option>o1<option>o2</select>
        \\ </form>
        \\ <select id=s2></select>
    });
    defer runner.deinit();

    try runner.testCases(&.{
        .{ "const s = document.getElementById('s1');", null },
        .{ "s.form", "[object HTMLFormElement]" },

        .{ "document.getElementById('s2').form", "null" },

        .{ "s.disabled", "false" },
        .{ "s.disabled = true", null },
        .{ "s.disabled", "true" },
        .{ "s.disabled = false", null },
        .{ "s.disabled", "false" },

        .{ "s.multiple", "false" },
        .{ "s.multiple = true", null },
        .{ "s.multiple", "true" },
        .{ "s.multiple = false", null },
        .{ "s.multiple", "false" },

        .{ "s.name;", "s1" },
        .{ "s.name = 'sel1';", null },
        .{ "s.name", "sel1" },

        .{ "s.length;", "2" },

        .{ "s.selectedIndex", "0" },
        .{ "s.selectedIndex = 2", null }, // out of range
        .{ "s.selectedIndex", "-1" },

        .{ "s.selectedIndex = -1", null },
        .{ "s.selectedIndex", "-1" },

        .{ "s.selectedIndex = 0", null },
        .{ "s.selectedIndex", "0" },

        .{ "s.selectedIndex = 1", null },
        .{ "s.selectedIndex", "1" },

        .{ "s.selectedIndex = -323", null },
        .{ "s.selectedIndex", "-1" },
    }, .{});
}
