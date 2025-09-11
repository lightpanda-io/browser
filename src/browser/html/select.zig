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
const collection = @import("../dom/html_collection.zig");

const Page = @import("../page.zig").Page;
const HTMLElement = @import("elements.zig").HTMLElement;

pub const Interfaces = .{
    HTMLSelectElement,
    HTMLOptionElement,
    HTMLOptionsCollection,
};

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
        const state = try page.getOrCreateNodeState(@ptrCast(@alignCast(select)));
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
        var state = try page.getOrCreateNodeState(@ptrCast(@alignCast(select)));
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

    pub fn get_options(select: *parser.Select) HTMLOptionsCollection {
        return .{
            .select = select,
            .proto = collection.HTMLCollectionChildren(@ptrCast(@alignCast(select)), .{
                .mutable = true,
                .include_root = false,
            }),
        };
    }
};

pub const HTMLOptionElement = struct {
    pub const Self = parser.Option;
    pub const prototype = *HTMLElement;
    pub const subtype = .node;

    pub fn get_value(self: *parser.Option) ![]const u8 {
        return parser.optionGetValue(self);
    }
    pub fn set_value(self: *parser.Option, value: []const u8) !void {
        return parser.optionSetValue(self, value);
    }

    pub fn get_label(self: *parser.Option) ![]const u8 {
        return parser.optionGetLabel(self);
    }
    pub fn set_label(self: *parser.Option, label: []const u8) !void {
        return parser.optionSetLabel(self, label);
    }

    pub fn get_selected(self: *parser.Option) !bool {
        return parser.optionGetSelected(self);
    }
    pub fn set_selected(self: *parser.Option, value: bool) !void {
        return parser.optionSetSelected(self, value);
    }

    pub fn get_disabled(self: *parser.Option) !bool {
        return parser.optionGetDisabled(self);
    }
    pub fn set_disabled(self: *parser.Option, value: bool) !void {
        return parser.optionSetDisabled(self, value);
    }

    pub fn get_text(self: *parser.Option) ![]const u8 {
        return parser.optionGetText(self);
    }

    pub fn get_form(self: *parser.Option) !?*parser.Form {
        return parser.optionGetForm(self);
    }
};

pub const HTMLOptionsCollection = struct {
    pub const prototype = *collection.HTMLCollection;

    proto: collection.HTMLCollection,
    select: *parser.Select,

    pub fn get_selectedIndex(self: *HTMLOptionsCollection, page: *Page) !i32 {
        return HTMLSelectElement.get_selectedIndex(self.select, page);
    }

    pub fn set_selectedIndex(self: *HTMLOptionsCollection, index: i32, page: *Page) !void {
        return HTMLSelectElement.set_selectedIndex(self.select, index, page);
    }

    const BeforeOpts = union(enum) {
        index: u32,
        option: *parser.Option,
    };
    pub fn _add(self: *HTMLOptionsCollection, option: *parser.Option, before_: ?BeforeOpts) !void {
        const Node = @import("../dom/node.zig").Node;
        const before = before_ orelse {
            return self.appendOption(option);
        };

        const insert_before: *parser.Node = switch (before) {
            .option => |o| @ptrCast(@alignCast(o)),
            .index => |i| (try self.proto.item(i)) orelse return self.appendOption(option),
        };
        return Node.before(insert_before, &.{
            .{ .node = @ptrCast(@alignCast(option)) },
        });
    }

    pub fn _remove(self: *HTMLOptionsCollection, index: u32) !void {
        const Node = @import("../dom/node.zig").Node;
        const option = (try self.proto.item(index)) orelse return;
        _ = try Node._removeChild(@ptrCast(@alignCast(self.select)), option);
    }

    fn appendOption(self: *HTMLOptionsCollection, option: *parser.Option) !void {
        const Node = @import("../dom/node.zig").Node;
        return Node.append(@ptrCast(@alignCast(self.select)), &.{
            .{ .node = @ptrCast(@alignCast(option)) },
        });
    }
};

const testing = @import("../../testing.zig");
test "Browser: HTML.Select" {
    try testing.htmlRunner("html/select.html");
}
