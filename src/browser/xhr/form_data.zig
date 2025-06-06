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

const Allocator = std.mem.Allocator;

const log = @import("../../log.zig");
const parser = @import("../netsurf.zig");
const Page = @import("../page.zig").Page;
const kv = @import("../key_value.zig");
const iterator = @import("../iterator/iterator.zig");

pub const Interfaces = .{
    FormData,
    KeyIterable,
    ValueIterable,
    EntryIterable,
};

// https://xhr.spec.whatwg.org/#interface-formdata
pub const FormData = struct {
    entries: kv.List,

    pub fn constructor(form_: ?*parser.Form, submitter_: ?*parser.ElementHTML, page: *Page) !FormData {
        const form = form_ orelse return .{ .entries = .{} };
        return fromForm(form, submitter_, page);
    }

    pub fn fromForm(form: *parser.Form, submitter_: ?*parser.ElementHTML, page: *Page) !FormData {
        const entries = try collectForm(form, submitter_, page);
        return .{ .entries = entries };
    }

    pub fn _get(self: *const FormData, key: []const u8) ?[]const u8 {
        return self.entries.get(key);
    }

    pub fn _getAll(self: *const FormData, key: []const u8, page: *Page) ![]const []const u8 {
        return self.entries.getAll(page.call_arena, key);
    }

    pub fn _has(self: *const FormData, key: []const u8) bool {
        return self.entries.has(key);
    }

    // TODO: value should be a string or blog
    // TODO: another optional parameter for the filename
    pub fn _set(self: *FormData, key: []const u8, value: []const u8, page: *Page) !void {
        return self.entries.set(page.arena, key, value);
    }

    // TODO: value should be a string or blog
    // TODO: another optional parameter for the filename
    pub fn _append(self: *FormData, key: []const u8, value: []const u8, page: *Page) !void {
        return self.entries.append(page.arena, key, value);
    }

    pub fn _delete(self: *FormData, key: []const u8) void {
        return self.entries.delete(key);
    }

    pub fn _keys(self: *const FormData) KeyIterable {
        return .{ .inner = self.entries.keyIterator() };
    }

    pub fn _values(self: *const FormData) ValueIterable {
        return .{ .inner = self.entries.valueIterator() };
    }

    pub fn _entries(self: *const FormData) EntryIterable {
        return .{ .inner = self.entries.entryIterator() };
    }

    pub fn _symbol_iterator(self: *const FormData) EntryIterable {
        return self._entries();
    }

    pub fn write(self: *const FormData, encoding_: ?[]const u8, writer: anytype) !void {
        const encoding = encoding_ orelse {
            return kv.urlEncode(self.entries, .form, writer);
        };

        if (std.ascii.eqlIgnoreCase(encoding, "application/x-www-form-urlencoded")) {
            return kv.urlEncode(self.entries, .form, writer);
        }

        log.warn(.web_api, "not implemented", .{
            .feature = "form data encoding",
            .encoding = encoding,
        });
        return error.EncodingNotSupported;
    }
};

const KeyIterable = iterator.Iterable(kv.KeyIterator, "FormDataKeyIterator");
const ValueIterable = iterator.Iterable(kv.ValueIterator, "FormDataValueIterator");
const EntryIterable = iterator.Iterable(kv.EntryIterator, "FormDataEntryIterator");

// TODO: handle disabled fieldsets
fn collectForm(form: *parser.Form, submitter_: ?*parser.ElementHTML, page: *Page) !kv.List {
    const arena = page.arena;
    const collection = try parser.formGetCollection(form);
    const len = try parser.htmlCollectionGetLength(collection);

    var entries: kv.List = .{};
    try entries.ensureTotalCapacity(arena, len);

    var submitter_included = false;
    const submitter_name_ = try getSubmitterName(submitter_);

    for (0..len) |i| {
        const node = try parser.htmlCollectionItem(collection, @intCast(i));
        const element = parser.nodeToElement(node);

        // must have a name
        const name = try parser.elementGetAttribute(element, "name") orelse continue;
        if (try parser.elementGetAttribute(element, "disabled") != null) {
            continue;
        }

        const tag = try parser.elementHTMLGetTagType(@as(*parser.ElementHTML, @ptrCast(element)));
        switch (tag) {
            .input => {
                const tpe = try parser.elementGetAttribute(element, "type") orelse "";
                if (std.ascii.eqlIgnoreCase(tpe, "image")) {
                    if (submitter_name_) |submitter_name| {
                        if (std.mem.eql(u8, submitter_name, name)) {
                            const key_x = try std.fmt.allocPrint(arena, "{s}.x", .{name});
                            const key_y = try std.fmt.allocPrint(arena, "{s}.y", .{name});
                            try entries.appendOwned(arena, key_x, "0");
                            try entries.appendOwned(arena, key_y, "0");
                            submitter_included = true;
                        }
                    }
                    continue;
                }

                if (std.ascii.eqlIgnoreCase(tpe, "checkbox") or std.ascii.eqlIgnoreCase(tpe, "radio")) {
                    if (try parser.inputGetChecked(@ptrCast(element)) == false) {
                        continue;
                    }
                }
                if (std.ascii.eqlIgnoreCase(tpe, "submit")) {
                    if (submitter_name_ == null or !std.mem.eql(u8, submitter_name_.?, name)) {
                        continue;
                    }
                    submitter_included = true;
                }
                const value = (try parser.elementGetAttribute(element, "value")) orelse "";
                try entries.appendOwned(arena, name, value);
            },
            .select => {
                const select: *parser.Select = @ptrCast(node);
                try collectSelectValues(arena, select, name, &entries, page);
            },
            .textarea => {
                const textarea: *parser.TextArea = @ptrCast(node);
                const value = try parser.textareaGetValue(textarea);
                try entries.appendOwned(arena, name, value);
            },
            .button => if (submitter_name_) |submitter_name| {
                if (std.mem.eql(u8, submitter_name, name)) {
                    const value = (try parser.elementGetAttribute(element, "value")) orelse "";
                    try entries.appendOwned(arena, name, value);
                    submitter_included = true;
                }
            },
            else => {
                log.warn(.web_api, "unsupported form element", .{ .tag = @tagName(tag) });
                continue;
            },
        }
    }

    if (submitter_included == false) {
        if (submitter_) |submitter| {
            // this can happen if the submitter is outside the form, but associated
            // with the form via a form=ID attribute
            const value = (try parser.elementGetAttribute(@ptrCast(submitter), "value")) orelse "";
            try entries.appendOwned(arena, submitter_name_.?, value);
        }
    }

    return entries;
}

fn collectSelectValues(arena: Allocator, select: *parser.Select, name: []const u8, entries: *kv.List, page: *Page) !void {
    const HTMLSelectElement = @import("../html/select.zig").HTMLSelectElement;

    // Go through the HTMLSelectElement because it has specific logic for handling
    // the default selected option, which libdom doesn't properly handle
    const selected_index = try HTMLSelectElement.get_selectedIndex(select, page);
    if (selected_index == -1) {
        return;
    }
    std.debug.assert(selected_index >= 0);

    const options = try parser.selectGetOptions(select);
    const is_multiple = try parser.selectGetMultiple(select);
    if (is_multiple == false) {
        const option = try parser.optionCollectionItem(options, @intCast(selected_index));

        if (try parser.elementGetAttribute(@alignCast(@ptrCast(option)), "disabled") != null) {
            return;
        }
        const value = try parser.optionGetValue(option);
        return entries.appendOwned(arena, name, value);
    }

    const len = try parser.optionCollectionGetLength(options);

    // we can go directly to the first one
    for (@intCast(selected_index)..len) |i| {
        const option = try parser.optionCollectionItem(options, @intCast(i));
        if (try parser.elementGetAttribute(@alignCast(@ptrCast(option)), "disabled") != null) {
            continue;
        }

        if (try parser.optionGetSelected(option)) {
            const value = try parser.optionGetValue(option);
            try entries.appendOwned(arena, name, value);
        }
    }
}

fn getSubmitterName(submitter_: ?*parser.ElementHTML) !?[]const u8 {
    const submitter = submitter_ orelse return null;

    const tag = try parser.elementHTMLGetTagType(submitter);
    const element: *parser.Element = @ptrCast(submitter);
    const name = try parser.elementGetAttribute(element, "name");

    switch (tag) {
        .button => return name,
        .input => {
            const tpe = (try parser.elementGetAttribute(element, "type")) orelse "";
            // only an image type can be a sumbitter
            if (std.ascii.eqlIgnoreCase(tpe, "image") or std.ascii.eqlIgnoreCase(tpe, "submit")) {
                return name;
            }
        },
        else => {},
    }
    return error.InvalidArgument;
}

const testing = @import("../../testing.zig");
test "Browser.FormData" {
    var runner = try testing.jsRunner(testing.tracking_allocator, .{ .html = 
        \\ <form id="form1">
        \\   <input id="has_no_name" value="nope1">
        \\   <input id="is_disabled" disabled value="nope2">
        \\
        \\   <input name="txt-1" value="txt-1-v">
        \\   <input name="txt-2" value="txt-~-v" type=password>
        \\
        \\   <input name="chk-3" value="chk-3-va" type=checkbox>
        \\   <input name="chk-3" value="chk-3-vb" type=checkbox checked>
        \\   <input name="chk-3" value="chk-3-vc" type=checkbox checked>
        \\   <input name="chk-4" value="chk-4-va" type=checkbox>
        \\   <input name="chk-4" value="chk-4-va" type=checkbox>
        \\
        \\   <input name="rdi-1" value="rdi-1-va" type=radio>
        \\   <input name="rdi-1" value="rdi-1-vb" type=radio>
        \\   <input name="rdi-1" value="rdi-1-vc" type=radio checked>
        \\   <input name="rdi-2" value="rdi-2-va" type=radio>
        \\   <input name="rdi-2" value="rdi-2-vb" type=radio>
        \\
        \\   <textarea name="ta-1"> ta-1-v</textarea>
        \\   <textarea name="ta"></textarea>
        \\
        \\   <input type=hidden name=h1 value="h1-v">
        \\   <input type=hidden name=h2 value="h2-v" disabled=disabled>
        \\
        \\   <select name="sel-1"><option>blue<option>red</select>
        \\   <select name="sel-2"><option>blue<option value=sel-2-v selected>red</select>
        \\   <select name="sel-3"><option disabled>nope1<option>nope2</select>
        \\   <select name="mlt-1" multiple><option>water<option>tea</select>
        \\   <select name="mlt-2" multiple><option selected>water<option selected>tea<option>coffee</select>
        \\   <input type=submit id=s1 name=s1 value=s1-v>
        \\   <input type=submit name=s2 value=s2-v>
        \\   <input type=image name=i1 value=i1-v>
        \\ </form>
    });
    defer runner.deinit();

    try runner.testCases(&.{
        .{ "let f = new FormData()", null },
        .{ "f.get('a')", "null" },
        .{ "f.has('a')", "false" },
        .{ "f.getAll('a')", "" },
        .{ "f.delete('a')", "undefined" },

        .{ "f.set('a', 1)", "undefined" },
        .{ "f.has('a')", "true" },
        .{ "f.get('a')", "1" },
        .{ "f.getAll('a')", "1" },

        .{ "f.append('a', 2)", "undefined" },
        .{ "f.has('a')", "true" },
        .{ "f.get('a')", "1" },
        .{ "f.getAll('a')", "1,2" },

        .{ "f.append('b', '3')", "undefined" },
        .{ "f.has('a')", "true" },
        .{ "f.get('a')", "1" },
        .{ "f.getAll('a')", "1,2" },
        .{ "f.has('b')", "true" },
        .{ "f.get('b')", "3" },
        .{ "f.getAll('b')", "3" },

        .{ "let acc = [];", null },
        .{ "for (const key of f.keys()) { acc.push(key) }; acc;", "a,a,b" },

        .{ "acc = [];", null },
        .{ "for (const value of f.values()) { acc.push(value) }; acc;", "1,2,3" },

        .{ "acc = [];", null },
        .{ "for (const entry of f.entries()) { acc.push(entry) }; acc;", "a,1,a,2,b,3" },

        .{ "acc = [];", null },
        .{ "for (const entry of f) { acc.push(entry) }; acc;", "a,1,a,2,b,3" },

        .{ "f.delete('a')", "undefined" },
        .{ "f.has('a')", "false" },
        .{ "f.has('b')", "true" },

        .{ "acc = [];", null },
        .{ "for (const key of f.keys()) { acc.push(key) }; acc;", "b" },

        .{ "acc = [];", null },
        .{ "for (const value of f.values()) { acc.push(value) }; acc;", "3" },

        .{ "acc = [];", null },
        .{ "for (const entry of f.entries()) { acc.push(entry) }; acc;", "b,3" },

        .{ "acc = [];", null },
        .{ "for (const entry of f) { acc.push(entry) }; acc;", "b,3" },
    }, .{});

    try runner.testCases(&.{
        .{ "let form1 = document.getElementById('form1')", null },
        .{ "let submit1 = document.getElementById('s1')", null },
        .{ "let f2 = new FormData(form1, submit1)", null },
        .{ "acc = '';", null },
        .{
            \\ for (const entry of f2) {
            \\   acc += entry[0] + '=' + entry[1] + '\n';
            \\ };
            \\ acc.slice(0, -1)
            ,
            \\txt-1=txt-1-v
            \\txt-2=txt-~-v
            \\chk-3=chk-3-vb
            \\chk-3=chk-3-vc
            \\rdi-1=rdi-1-vc
            \\ta-1= ta-1-v
            \\ta=
            \\h1=h1-v
            \\sel-1=blue
            \\sel-2=sel-2-v
            \\mlt-2=water
            \\mlt-2=tea
            \\s1=s1-v
        },
    }, .{});
}

test "Browser.FormData: urlEncode" {
    var arr: std.ArrayListUnmanaged(u8) = .empty;
    defer arr.deinit(testing.allocator);

    {
        var fd = FormData{ .entries = .{} };
        try testing.expectError(error.EncodingNotSupported, fd.write("unknown", arr.writer(testing.allocator)));

        try fd.write(null, arr.writer(testing.allocator));
        try testing.expectEqual("", arr.items);

        try fd.write("application/x-www-form-urlencoded", arr.writer(testing.allocator));
        try testing.expectEqual("", arr.items);
    }

    {
        var fd = FormData{ .entries = kv.List.fromOwnedSlice(@constCast(&[_]kv.KeyValue{
            .{ .key = "a", .value = "1" },
            .{ .key = "it's over", .value = "9000 !!!" },
            .{ .key = "em~ot", .value = "ok: ☺" },
        })) };
        const expected = "a=1&it%27s+over=9000+%21%21%21&em%7Eot=ok%3A+%E2%98%BA";
        try fd.write(null, arr.writer(testing.allocator));
        try testing.expectEqual(expected, arr.items);

        arr.clearRetainingCapacity();
        try fd.write("application/x-www-form-urlencoded", arr.writer(testing.allocator));
        try testing.expectEqual(expected, arr.items);
    }
}
