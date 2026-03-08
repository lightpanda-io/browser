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
const Node = @import("../Node.zig");
const Form = @import("../element/html/Form.zig");
const Element = @import("../Element.zig");
const KeyValueList = @import("../KeyValueList.zig");

const Allocator = std.mem.Allocator;

const FormData = @This();

_arena: Allocator,
_list: KeyValueList,
_file_entries: std.ArrayListUnmanaged(FileEntry),
_multipart_boundary: []const u8,

const FileEntry = struct {
    name: []const u8,
    path: []const u8,
    filename: []const u8,
    content_type: []const u8,
};

pub fn init(form: ?*Form, submitter: ?*Element, page: *Page) !*FormData {
    var file_entries: std.ArrayListUnmanaged(FileEntry) = .{};
    return page._factory.create(FormData{
        ._arena = page.arena,
        ._list = try collectForm(page.arena, form, submitter, page, &file_entries),
        ._file_entries = file_entries,
        ._multipart_boundary = try std.fmt.allocPrint(page.arena, "----lightpanda-formdata-{x}", .{@intFromPtr(page)}),
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

pub fn write(self: *const FormData, encoding_: ?[]const u8, writer: *std.Io.Writer) !void {
    const encoding = encoding_ orelse {
        return self._list.urlEncode(.form, writer);
    };

    if (std.ascii.eqlIgnoreCase(encoding, "application/x-www-form-urlencoded")) {
        return self._list.urlEncode(.form, writer);
    }

    if (isMultipartFormEncoding(encoding)) {
        return self.writeMultipart(writer);
    }

    log.warn(.not_implemented, "FormData.encoding", .{
        .encoding = encoding,
    });
}

pub fn contentTypeHeader(self: *const FormData, encoding_: ?[]const u8) ![:0]const u8 {
    const encoding = encoding_ orelse "application/x-www-form-urlencoded";
    if (std.ascii.eqlIgnoreCase(encoding, "application/x-www-form-urlencoded")) {
        return "Content-Type: application/x-www-form-urlencoded";
    }
    if (isMultipartFormEncoding(encoding)) {
        const header = try std.fmt.allocPrint(self._arena, "Content-Type: multipart/form-data; boundary={s}", .{self._multipart_boundary});
        return try self._arena.dupeZ(u8, header);
    }
    log.warn(.not_implemented, "FormData.encoding", .{
        .encoding = encoding,
    });
    return "Content-Type: application/x-www-form-urlencoded";
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

fn collectForm(
    arena: Allocator,
    form_: ?*Form,
    submitter_: ?*Element,
    page: *Page,
    file_entries: *std.ArrayListUnmanaged(FileEntry),
) !KeyValueList {
    var list: KeyValueList = .empty;
    const form = form_ orelse return list;

    const form_node = form.asNode();

    var elements = try form.getElements(page);
    var it = try elements.iterator();
    while (it.next()) |element| {
        if (element.getAttributeSafe(comptime .wrap("disabled")) != null) {
            continue;
        }
        if (isDisabledByFieldset(element, form_node)) {
            continue;
        }

        // Handle image submitters first - they can submit without a name
        if (element.is(Form.Input)) |input| {
            if (input._input_type == .image) {
                const submitter = submitter_ orelse continue;
                if (submitter != element) {
                    continue;
                }

                const name = element.getAttributeSafe(comptime .wrap("name"));
                const x_key = if (name) |n| try std.fmt.allocPrint(arena, "{s}.x", .{n}) else "x";
                const y_key = if (name) |n| try std.fmt.allocPrint(arena, "{s}.y", .{n}) else "y";
                try list.append(arena, x_key, "0");
                try list.append(arena, y_key, "0");
                continue;
            }
        }

        const name = element.getAttributeSafe(comptime .wrap("name")) orelse continue;
        const value = blk: {
            if (element.is(Form.Input)) |input| {
                const input_type = input._input_type;
                if (input_type == .file) {
                    const selected = input.getSelectedFile() orelse continue;
                    try file_entries.append(arena, .{
                        .name = try arena.dupe(u8, name),
                        .path = try arena.dupe(u8, selected.path),
                        .filename = try arena.dupe(u8, selected.name),
                        .content_type = try arena.dupe(u8, selected.content_type),
                    });
                    continue;
                }
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

fn isMultipartFormEncoding(encoding: []const u8) bool {
    const trimmed = std.mem.trim(u8, encoding, &std.ascii.whitespace);
    return std.ascii.startsWithIgnoreCase(trimmed, "multipart/form-data");
}

fn writeMultipart(self: *const FormData, writer: *std.Io.Writer) !void {
    for (self._list.items()) |entry| {
        const name = try sanitizeMultipartToken(self._arena, entry.name.str());
        const value = entry.value.str();
        try writer.print("--{s}\r\n", .{self._multipart_boundary});
        try writer.print("Content-Disposition: form-data; name=\"{s}\"\r\n\r\n", .{name});
        try writer.writeAll(value);
        try writer.writeAll("\r\n");
    }

    for (self._file_entries.items) |entry| {
        const name = try sanitizeMultipartToken(self._arena, entry.name);
        const filename = try sanitizeMultipartToken(self._arena, entry.filename);
        try writer.print("--{s}\r\n", .{self._multipart_boundary});
        try writer.print("Content-Disposition: form-data; name=\"{s}\"; filename=\"{s}\"\r\n", .{ name, filename });
        try writer.print("Content-Type: {s}\r\n\r\n", .{entry.content_type});

        const file = try std.fs.openFileAbsolute(entry.path, .{});
        defer file.close();
        const stat = try file.stat();
        const file_size = std.math.cast(usize, stat.size) orelse return error.FileTooLarge;
        const data = try file.readToEndAlloc(self._arena, file_size + 1);
        try writer.writeAll(data);
        try writer.writeAll("\r\n");
    }

    try writer.print("--{s}--\r\n", .{self._multipart_boundary});
}

fn sanitizeMultipartToken(allocator: Allocator, value: []const u8) ![]const u8 {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);

    for (value) |char| {
        switch (char) {
            '"', '\r', '\n' => try buf.append(allocator, '_'),
            else => try buf.append(allocator, char),
        }
    }
    return allocator.dupe(u8, buf.items);
}

// Returns true if `element` is disabled by an ancestor <fieldset disabled>,
// stopping the upward walk when the form node is reached.
// Per spec, elements inside the first <legend> child of a disabled fieldset
// are NOT disabled by that fieldset.
fn isDisabledByFieldset(element: *Element, form_node: *Node) bool {
    const element_node = element.asNode();
    var current: ?*Node = element_node._parent;
    while (current) |node| {
        // Stop at the form boundary (common case optimisation)
        if (node == form_node) {
            return false;
        }

        current = node._parent;
        const el = node.is(Element) orelse continue;

        if (el.getTag() == .fieldset and el.getAttributeSafe(comptime .wrap("disabled")) != null) {
            // Check if `element` is inside the first <legend> child of this fieldset
            var child = el.firstElementChild();
            while (child) |c| {
                if (c.getTag() == .legend) {
                    // Found the first legend; exempt if element is a descendant
                    if (c.asNode().contains(element_node)) {
                        return false;
                    }
                    break;
                }
                child = c.nextElementSibling();
            }
            return true;
        }
    }
    return false;
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

test "FormData write multipart/form-data includes file parts" {
    var arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    var list = KeyValueList.init();
    try list.append(arena, "title", "hello");

    var file_entries: std.ArrayListUnmanaged(FileEntry) = .{};
    const temp_path = "tmp-formdata-upload.txt";
    try std.fs.cwd().writeFile(.{ .sub_path = temp_path, .data = "hello upload" });
    defer std.fs.cwd().deleteFile(temp_path) catch {};
    const abs_path = try std.fs.cwd().realpathAlloc(std.testing.allocator, temp_path);
    defer std.testing.allocator.free(abs_path);

    try file_entries.append(arena, .{
        .name = try arena.dupe(u8, "upload"),
        .path = try arena.dupe(u8, abs_path),
        .filename = try arena.dupe(u8, "sample.txt"),
        .content_type = try arena.dupe(u8, "text/plain"),
    });

    const form_data = FormData{
        ._arena = arena,
        ._list = list,
        ._file_entries = file_entries,
        ._multipart_boundary = "BOUNDARY",
    };

    var buf = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer buf.deinit();

    try form_data.write("multipart/form-data", &buf.writer);
    try std.testing.expect(std.mem.indexOf(u8, buf.written(), "Content-Disposition: form-data; name=\"title\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.written(), "Content-Disposition: form-data; name=\"upload\"; filename=\"sample.txt\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.written(), "Content-Type: text/plain") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.written(), "hello upload") != null);
}

test "FormData contentTypeHeader includes multipart boundary" {
    const form_data = FormData{
        ._arena = std.testing.allocator,
        ._list = .empty,
        ._file_entries = .{},
        ._multipart_boundary = "BOUNDARY",
    };
    const header = try form_data.contentTypeHeader("multipart/form-data");
    defer std.testing.allocator.free(header);
    try std.testing.expectEqualStrings("Content-Type: multipart/form-data; boundary=BOUNDARY", header);
}
