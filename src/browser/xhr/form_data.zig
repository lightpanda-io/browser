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
const iterator = @import("../iterator/iterator.zig");
const Page = @import("../page.zig").Page;

pub const Interfaces = .{
    FormData,
    KeyIterable,
    ValueIterable,
    EntryIterable,
};

// We store the values in an ArrayList rather than a an
// StringArrayHashMap([]const u8) because of the way the iterators (i.e., keys(),
// values() and entries()) work. The FormData can contain duplicate keys, and
// each iteration yields 1 key=>value pair. So, given:
//
//  let f = new FormData();
//  f.append('a', '1');
//  f.append('a', '2');
//
// Then we'd expect f.keys(), f.values() and f.entries() to yield 2 results:
//  ['a', '1']
//  ['a', '2']
//
// This is much easier to do with an ArrayList than a HashMap, especially given
// that the FormData could be mutated while iterating.
// The downside is that most of the normal operations are O(N).

// https://xhr.spec.whatwg.org/#interface-formdata
pub const FormData = struct {
    entries: std.ArrayListUnmanaged(Entry),

    pub fn constructor(form_: ?*parser.Form, submitter_: ?*parser.ElementHTML, page: *Page) !FormData {
        const form = form_ orelse return .{ .entries = .empty };
        return fromForm(form, submitter_, page, .{});
    }

    const FromFormOpts = struct {
        // Uses the page.arena if null. This is needed for when we're handling
        // form submission from the Page, and we want to capture the form within
        // the session's transfer_arena.
        allocator: ?Allocator = null,
    };
    pub fn fromForm(form: *parser.Form, submitter_: ?*parser.ElementHTML, page: *Page, opts: FromFormOpts) !FormData {
        const entries = try collectForm(opts.allocator orelse page.arena, form, submitter_, page);
        return .{ .entries = entries };
    }

    pub fn _get(self: *const FormData, key: []const u8) ?[]const u8 {
        const result = self.find(key) orelse return null;
        return result.entry.value;
    }

    pub fn _getAll(self: *const FormData, key: []const u8, page: *Page) ![][]const u8 {
        const arena = page.call_arena;
        var arr: std.ArrayListUnmanaged([]const u8) = .empty;
        for (self.entries.items) |entry| {
            if (std.mem.eql(u8, key, entry.key)) {
                try arr.append(arena, entry.value);
            }
        }
        return arr.items;
    }

    pub fn _has(self: *const FormData, key: []const u8) bool {
        return self.find(key) != null;
    }

    // TODO: value should be a string or blog
    // TODO: another optional parameter for the filename
    pub fn _set(self: *FormData, key: []const u8, value: []const u8, page: *Page) !void {
        self._delete(key);
        return self._append(key, value, page);
    }

    // TODO: value should be a string or blog
    // TODO: another optional parameter for the filename
    pub fn _append(self: *FormData, key: []const u8, value: []const u8, page: *Page) !void {
        const arena = page.arena;
        return self.entries.append(arena, .{ .key = try arena.dupe(u8, key), .value = try arena.dupe(u8, value) });
    }

    pub fn _delete(self: *FormData, key: []const u8) void {
        var i: usize = 0;
        while (i < self.entries.items.len) {
            const entry = self.entries.items[i];
            if (std.mem.eql(u8, key, entry.key)) {
                _ = self.entries.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }

    pub fn _keys(self: *const FormData) KeyIterable {
        return .{ .inner = .{ .entries = &self.entries } };
    }

    pub fn _values(self: *const FormData) ValueIterable {
        return .{ .inner = .{ .entries = &self.entries } };
    }

    pub fn _entries(self: *const FormData) EntryIterable {
        return .{ .inner = .{ .entries = &self.entries } };
    }

    pub fn _symbol_iterator(self: *const FormData) EntryIterable {
        return self._entries();
    }

    const FindResult = struct {
        index: usize,
        entry: Entry,
    };

    fn find(self: *const FormData, key: []const u8) ?FindResult {
        for (self.entries.items, 0..) |entry, i| {
            if (std.mem.eql(u8, key, entry.key)) {
                return .{ .index = i, .entry = entry };
            }
        }
        return null;
    }
};

const Entry = struct {
    key: []const u8,
    value: []const u8,
};

const KeyIterable = iterator.Iterable(KeyIterator, "FormDataKeyIterator");
const ValueIterable = iterator.Iterable(ValueIterator, "FormDataValueIterator");
const EntryIterable = iterator.Iterable(EntryIterator, "FormDataEntryIterator");

const KeyIterator = struct {
    index: usize = 0,
    entries: *const std.ArrayListUnmanaged(Entry),

    pub fn _next(self: *KeyIterator) ?[]const u8 {
        const index = self.index;
        if (index == self.entries.items.len) {
            return null;
        }
        self.index += 1;
        return self.entries.items[index].key;
    }
};

const ValueIterator = struct {
    index: usize = 0,
    entries: *const std.ArrayListUnmanaged(Entry),

    pub fn _next(self: *ValueIterator) ?[]const u8 {
        const index = self.index;
        if (index == self.entries.items.len) {
            return null;
        }
        self.index += 1;
        return self.entries.items[index].value;
    }
};

const EntryIterator = struct {
    index: usize = 0,
    entries: *const std.ArrayListUnmanaged(Entry),

    pub fn _next(self: *EntryIterator) ?struct { []const u8, []const u8 } {
        const index = self.index;
        if (index == self.entries.items.len) {
            return null;
        }
        self.index += 1;
        const entry = self.entries.items[index];
        return .{ entry.key, entry.value };
    }
};

fn collectForm(arena: Allocator, form: *parser.Form, submitter_: ?*parser.ElementHTML, page: *Page) !std.ArrayListUnmanaged(Entry) {
    const collection = try parser.formGetCollection(form);
    const len = try parser.htmlCollectionGetLength(collection);

    var entries: std.ArrayListUnmanaged(Entry) = .empty;
    try entries.ensureTotalCapacity(arena, len);

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
                            try entries.append(arena, .{
                                .key = try std.fmt.allocPrint(arena, "{s}.x", .{name}),
                                .value = "0",
                            });
                            try entries.append(arena, .{
                                .key = try std.fmt.allocPrint(arena, "{s}.y", .{name}),
                                .value = "0",
                            });
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
                }
                const value = (try parser.elementGetAttribute(element, "value")) orelse "";
                try entries.append(arena, .{ .key = name, .value = value });
            },
            .select => {
                const select: *parser.Select = @ptrCast(node);
                try collectSelectValues(arena, select, name, &entries, page);
            },
            .textarea => {
                const textarea: *parser.TextArea = @ptrCast(node);
                const value = try parser.textareaGetValue(textarea);
                try entries.append(arena, .{ .key = name, .value = value });
            },
            .button => if (submitter_name_) |submitter_name| {
                if (std.mem.eql(u8, submitter_name, name)) {
                    const value = (try parser.elementGetAttribute(element, "value")) orelse "";
                    try entries.append(arena, .{ .key = name, .value = value });
                }
            },
            else => {
                log.warn(.form_data, "unsupported element", .{ .tag = @tagName(tag) });
                continue;
            },
        }
    }

    return entries;
}

fn collectSelectValues(arena: Allocator, select: *parser.Select, name: []const u8, entries: *std.ArrayListUnmanaged(Entry), page: *Page) !void {
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

        if (try parser.elementGetAttribute(@ptrCast(option), "disabled") != null) {
            return;
        }
        const value = try parser.optionGetValue(option);
        return entries.append(arena, .{ .key = name, .value = value });
    }

    const len = try parser.optionCollectionGetLength(options);

    // we can go directly to the first one
    for (@intCast(selected_index)..len) |i| {
        const option = try parser.optionCollectionItem(options, @intCast(i));
        if (try parser.elementGetAttribute(@ptrCast(option), "disabled") != null) {
            continue;
        }

        if (try parser.optionGetSelected(option)) {
            const value = try parser.optionGetValue(option);
            try entries.append(arena, .{ .key = name, .value = value });
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
        \\   <input name="txt-2" value="txt-2-v" type=password>
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
            \\txt-2=txt-2-v
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
