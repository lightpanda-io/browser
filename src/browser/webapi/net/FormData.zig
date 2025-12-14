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

const Alloctor = std.mem.Allocator;

const FormData = @This();

_arena: Alloctor,
_list: KeyValueList,

pub fn init(form_: ?*Form, submitter_: ?*Element, page: *Page) !*FormData {
    _ = form_;
    _ = submitter_;
    return page._factory.create(FormData{
        ._arena = page.arena,
        ._list = KeyValueList.init(),
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

// fn collectForm(form: *Form, submitter_: ?*Element, page: *Page) !KeyValueList {
//     const arena = page.arena;

//     // Don't use libdom's formGetCollection (aka dom_html_form_element_get_elements)
//     // It doesn't work with dynamically added elements, because their form
//     // property doesn't get set. We should fix that.
//     // However, even once fixed, there are other form-collection features we
//     // probably want to implement (like disabled fieldsets), so we might want
//     // to stick with our own walker even if fix libdom to properly support
//     // dynamically added elements.
//     const node_list = try @import("../dom/css.zig").querySelectorAll(arena, @ptrCast(@alignCast(form)), "input,select,button,textarea");
//     const nodes = node_list.nodes.items;

//     var entries: kv.List = .{};
//     try entries.ensureTotalCapacity(arena, nodes.len);

//     var submitter_included = false;
//     const submitter_name_ = try getSubmitterName(submitter_);

//     for (nodes) |node| {
//         const element = parser.nodeToElement(node);

//         // must have a name
//         const name = try parser.elementGetAttribute(element, "name") orelse continue;
//         if (try parser.elementGetAttribute(element, "disabled") != null) {
//             continue;
//         }

//         const tag = try parser.elementTag(element);
//         switch (tag) {
//             .input => {
//                 const tpe = try parser.inputGetType(@ptrCast(element));
//                 if (std.ascii.eqlIgnoreCase(tpe, "image")) {
//                     if (submitter_name_) |submitter_name| {
//                         if (std.mem.eql(u8, submitter_name, name)) {
//                             const key_x = try std.fmt.allocPrint(arena, "{s}.x", .{name});
//                             const key_y = try std.fmt.allocPrint(arena, "{s}.y", .{name});
//                             try entries.appendOwned(arena, key_x, "0");
//                             try entries.appendOwned(arena, key_y, "0");
//                             submitter_included = true;
//                         }
//                     }
//                     continue;
//                 }

//                 if (std.ascii.eqlIgnoreCase(tpe, "checkbox") or std.ascii.eqlIgnoreCase(tpe, "radio")) {
//                     if (try parser.inputGetChecked(@ptrCast(element)) == false) {
//                         continue;
//                     }
//                 }
//                 if (std.ascii.eqlIgnoreCase(tpe, "submit")) {
//                     if (submitter_name_ == null or !std.mem.eql(u8, submitter_name_.?, name)) {
//                         continue;
//                     }
//                     submitter_included = true;
//                 }
//                 const value = try parser.inputGetValue(@ptrCast(element));
//                 try entries.appendOwned(arena, name, value);
//             },
//             .select => {
//                 const select: *parser.Select = @ptrCast(node);
//                 try collectSelectValues(arena, select, name, &entries, page);
//             },
//             .textarea => {
//                 const textarea: *parser.TextArea = @ptrCast(node);
//                 const value = try parser.textareaGetValue(textarea);
//                 try entries.appendOwned(arena, name, value);
//             },
//             .button => if (submitter_name_) |submitter_name| {
//                 if (std.mem.eql(u8, submitter_name, name)) {
//                     const value = (try parser.elementGetAttribute(element, "value")) orelse "";
//                     try entries.appendOwned(arena, name, value);
//                     submitter_included = true;
//                 }
//             },
//             else => unreachable,
//         }
//     }

//     if (submitter_included == false) {
//         if (submitter_name_) |submitter_name| {
//             // this can happen if the submitter is outside the form, but associated
//             // with the form via a form=ID attribute
//             const value = (try parser.elementGetAttribute(@ptrCast(submitter_.?), "value")) orelse "";
//             try entries.appendOwned(arena, submitter_name, value);
//         }
//     }

//     return entries;
// }

const testing = @import("../../../testing.zig");
test "WebApi: FormData" {
    try testing.htmlRunner("net/form_data.html", .{});
}
