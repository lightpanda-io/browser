// Copyright (C) 2023-2025  Lightpanda (Selecy SAS)
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

const log = @import("../../../log.zig");

const js = @import("../../js/js.zig");
const Page = @import("../../Page.zig");
const Form = @import("../element/html/Form.zig");
const Element = @import("../Element.zig");
const KeyValueList = @import("../KeyValueList.zig");

const Allocator = std.mem.Allocator;

const FormData = @This();

_arena: Allocator,
_list: KeyValueList,

pub fn init(form: ?*Form, submitter: ?*Element, page: *Page) !*FormData {
    return page._factory.create(FormData{
        ._arena = page.arena,
        ._list = try collectForm(page.arena, form, submitter, page),
    });
}

pub fn get(self: *const FormData, name: []const u8) ?[]const u8 {
    return self._list.get(name);
}

pub fn getAll(self: *const FormData, name: []const u8, page: *Page) ![]const []const u8 {
    return self._list.getAll(name, page);
}

pub fn has(self: *const FormData, name: []const u8) bool {
    return self._list.has(name);
}

pub fn set(self: *FormData, name: []const u8, value: []const u8) !void {
    return self._list.set(self._arena, name, value);
}

pub fn append(self: *FormData, name: []const u8, value: []const u8) !void {
    return self._list.append(self._arena, name, value);
}

pub fn delete(self: *FormData, name: []const u8) void {
    self._list.delete(name, null);
}

pub fn keys(self: *FormData, page: *Page) !*KeyValueList.KeyIterator {
    return KeyValueList.KeyIterator.init(.{ .list = self, .kv = &self._list }, page);
}

pub fn values(self: *FormData, page: *Page) !*KeyValueList.ValueIterator {
    return KeyValueList.ValueIterator.init(.{ .list = self, .kv = &self._list }, page);
}

pub fn entries(self: *FormData, page: *Page) !*KeyValueList.EntryIterator {
    return KeyValueList.EntryIterator.init(.{ .list = self, .kv = &self._list }, page);
}

pub fn forEach(self: *FormData, cb_: js.Function, js_this_: ?js.Object) !void {
    const cb = if (js_this_) |js_this| try cb_.withThis(js_this) else cb_;

    for (self._list._entries.items) |entry| {
        cb.call(void, .{ entry.value.str(), entry.name.str(), self }) catch |err| {
            // this is a non-JS error
            log.warn(.js, "FormData.forEach", .{ .err = err });
        };
    }
}

pub const Iterator = struct {
    index: u32 = 0,
    list: *const FormData,

    const Entry = struct { []const u8, []const u8 };

    pub fn next(self: *Iterator, _: *Page) !?Iterator.Entry {
        const index = self.index;
        const items = self.list._list.items();
        if (index >= items.len) {
            return null;
        }
        self.index = index + 1;

        const e = &items[index];
        return .{ e.name.str(), e.value.str() };
    }
};

fn collectForm(arena: Allocator, form_: ?*Form, submitter_: ?*Element, page: *Page) !KeyValueList {
    var list: KeyValueList = .empty;
    const form = form_ orelse return list;

    var elements = try form.getElements(page);
    var it = try elements.iterator();
    while (it.next()) |element| {
        if (element.getAttributeSafe("disabled") != null) {
            continue;
        }

        // Handle image submitters first - they can submit without a name
        if (element.is(Form.Input)) |input| {
            if (input._input_type == .image) {
                const submitter = submitter_ orelse continue;
                if (submitter != element) {
                    continue;
                }

                const name = element.getAttributeSafe("name");
                const x_key = if (name) |n| try std.fmt.allocPrint(arena, "{s}.x", .{n}) else "x";
                const y_key = if (name) |n| try std.fmt.allocPrint(arena, "{s}.y", .{n}) else "y";
                try list.append(arena, x_key, "0");
                try list.append(arena, y_key, "0");
                continue;
            }
        }

        const name = element.getAttributeSafe("name") orelse continue;
        const value = blk: {
            if (element.is(Form.Input)) |input| {
                const input_type = input._input_type;
                if (input_type == .checkbox or input_type == .radio) {
                    if (!input.getChecked()) {
                        continue;
                    }
                }
                if (input_type == .submit) {
                    const submitter = submitter_ orelse continue;
                    if (submitter != element) {
                        continue;
                    }
                }
                break :blk input.getValue();
            }

            if (element.is(Form.Select)) |select| {
                if (select.getMultiple() == false) {
                    break :blk select.getValue(page);
                }

                var options = try select.getSelectedOptions(page);
                while (options.next()) |option| {
                    try list.append(arena, name, option.as(Form.Select.Option).getValue(page));
                }
                continue;
            }

            if (element.is(Form.TextArea)) |textarea| {
                break :blk textarea.getValue();
            }

            if (submitter_) |submitter| {
                if (submitter == element) {
                    // The form iterator only yields form controls. If we're here
                    // all other control types have been handled. So the cast is safe.
                    break :blk element.as(Form.Button).getValue();
                }
            }
            continue;
        };
        try list.append(arena, name, value);
    }
    return list;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(FormData);

    pub const Meta = struct {
        pub const name = "FormData";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(FormData.init, .{});
    pub const has = bridge.function(FormData.has, .{});
    pub const get = bridge.function(FormData.get, .{});
    pub const set = bridge.function(FormData.set, .{});
    pub const append = bridge.function(FormData.append, .{});
    pub const getAll = bridge.function(FormData.getAll, .{});
    pub const delete = bridge.function(FormData.delete, .{});
    pub const keys = bridge.function(FormData.keys, .{});
    pub const values = bridge.function(FormData.values, .{});
    pub const entries = bridge.function(FormData.entries, .{});
    pub const symbol_iterator = bridge.iterator(FormData.entries, .{});
    pub const forEach = bridge.function(FormData.forEach, .{});
};

const testing = @import("../../../testing.zig");
test "WebApi: FormData" {
    try testing.htmlRunner("net/form_data.html", .{});
}
