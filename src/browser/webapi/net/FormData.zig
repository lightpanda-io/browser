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
const lp = @import("lightpanda");

const js = @import("../../js/js.zig");
const Frame = @import("../../Frame.zig");
const Form = @import("../element/html/Form.zig");
const Element = @import("../Element.zig");
const File = @import("../File.zig");
const KeyValueList = @import("../KeyValueList.zig");

const log = lp.log;
const String = lp.String;
const Execution = js.Execution;
const Allocator = std.mem.Allocator;

const FormData = @This();

_arena: Allocator,
_entries: std.ArrayList(Entry),

pub const Entry = struct {
    name: String,
    value: Value,

    const Value = union(enum) {
        file: *File,
        string: String,

        fn asString(self: *const Value) []const u8 {
            return switch (self.*) {
                .string => |*s| s.str(),
                .file => unreachable, // nothing currently creates this type of value
            };
        }
    };
};

pub fn init(form_: ?*Form, submitter: ?*Element, exec: *const Execution) !*FormData {
    const form = form_ orelse {
        return try exec._factory.create(FormData{
            ._arena = exec.arena,
            ._entries = .empty,
        });
    };

    const frame = switch (exec.context.global) {
        .frame => |f| f,
        .worker => lp.assert(false, "FormData worker form", .{}),
    };

    const form_data = try exec._factory.create(FormData{
        ._arena = exec.arena,
        ._entries = try collectForm(frame.arena, form, submitter, frame),
    });

    const form_data_event = try (@import("../event/FormDataEvent.zig")).initTrusted(
        comptime .wrap("formdata"),
        .{ .bubbles = true, .cancelable = false, .formData = form_data },
        frame,
    );
    try frame._event_manager.dispatch(form.asNode().asEventTarget(), form_data_event.asEvent());

    return form_data;
}

pub fn get(self: *const FormData, name: String) ?[]const u8 {
    for (self._entries.items) |*entry| {
        if (entry.name.eql(name)) {
            return entry.value.asString();
        }
    }
    return null;
}

pub fn getAll(self: *const FormData, name: String, exec: *const Execution) ![]const []const u8 {
    var arr: std.ArrayList([]const u8) = .empty;
    for (self._entries.items) |*entry| {
        if (entry.name.eql(name)) {
            try arr.append(exec.call_arena, entry.value.asString());
        }
    }
    return arr.items;
}

pub fn has(self: *const FormData, name: String) bool {
    for (self._entries.items) |*entry| {
        if (entry.name.eql(name)) {
            return true;
        }
    }
    return false;
}

pub fn set(self: *FormData, name: String, value: []const u8) !void {
    self.deleteByName(name);
    return self.append(name.str(), value);
}

pub fn append(self: *FormData, name: []const u8, value: []const u8) !void {
    try self._entries.append(self._arena, .{
        .name = try String.init(self._arena, name, .{}),
        .value = .{ .string = try String.init(self._arena, value, .{}) },
    });
}

pub fn delete(self: *FormData, name: String) void {
    self.deleteByName(name);
}

fn deleteByName(self: *FormData, name: String) void {
    var i: usize = 0;
    while (i < self._entries.items.len) {
        if (self._entries.items[i].name.eql(name)) {
            _ = self._entries.swapRemove(i);
            continue;
        }
        i += 1;
    }
}

pub fn keys(self: *FormData, exec: *const js.Execution) !*KeyIterator {
    return KeyIterator.init(.{ .fd = self, .list = self }, exec);
}

pub fn values(self: *FormData, exec: *const js.Execution) !*ValueIterator {
    return ValueIterator.init(.{ .fd = self, .list = self }, exec);
}

pub fn entries(self: *FormData, exec: *const js.Execution) !*EntryIterator {
    return EntryIterator.init(.{ .fd = self, .list = self }, exec);
}

pub fn forEach(self: *FormData, cb_: js.Function, js_this_: ?js.Object) !void {
    const cb = if (js_this_) |js_this| try cb_.withThis(js_this) else cb_;

    for (self._entries.items) |*entry| {
        cb.call(void, .{ entry.value.asString(), entry.name.str(), self }) catch |err| {
            // this is a non-JS error
            log.warn(.js, "FormData.forEach", .{ .err = err });
        };
    }
}

pub const EncType = union(enum) {
    urlencode,
    // Boundary delimiter; caller owns the bytes (must outlive the write).
    formdata: []const u8,
};

pub const WriteOpts = struct {
    encoding: EncType = .urlencode,
    charset: []const u8 = "UTF-8",
    allocator: ?std.mem.Allocator = null,
};

pub fn write(self: *const FormData, opts: WriteOpts, writer: *std.Io.Writer) !void {
    switch (opts.encoding) {
        .urlencode => return self.urlEncode(opts, writer),
        .formdata => |boundary| return self.multipartEncode(boundary, writer),
    }
}

fn urlEncode(self: *const FormData, opts: WriteOpts, writer: *std.Io.Writer) !void {
    const items = self._entries.items;
    if (items.len == 0) return;

    try urlEncodeEntry(&items[0], opts, writer);
    for (items[1..]) |*entry| {
        try writer.writeByte('&');
        try urlEncodeEntry(entry, opts, writer);
    }
}

fn urlEncodeEntry(entry: *const Entry, opts: WriteOpts, writer: *std.Io.Writer) !void {
    try KeyValueList.urlEncodeFormValue(entry.name.str(), opts.allocator, opts.charset, writer);
    try writer.writeByte('=');
    try KeyValueList.urlEncodeFormValue(entry.value.asString(), opts.allocator, opts.charset, writer);
}

fn multipartEncode(self: *const FormData, boundary: []const u8, writer: *std.Io.Writer) !void {
    for (self._entries.items) |*entry| {
        try multipartEncodeEntry(entry, boundary, writer);
    }
    try writer.print("--{s}--\r\n", .{boundary});
}

fn multipartEncodeEntry(entry: *const Entry, boundary: []const u8, writer: *std.Io.Writer) !void {
    try writer.print("--{s}\r\n", .{boundary});
    const value_ptr = &entry.value;
    switch (value_ptr.*) {
        .string => |*s| {
            try writer.writeAll("Content-Disposition: form-data; name=\"");
            try writeMultipartName(writer, entry.name.str());
            try writer.writeAll("\"\r\n\r\n");
            try writer.writeAll(s.str());
            try writer.writeAll("\r\n");
        },
        // File entries need a real payload (filename + bytes + Content-Type) — not yet wired.
        .file => log.warn(.not_implemented, "FormData.multipart.file", .{}),
    }
}

// Per RFC 7578 §4.2, Content-Disposition names are quoted-string form;
// CR/LF/" must be escaped.
fn writeMultipartName(writer: *std.Io.Writer, name: []const u8) !void {
    for (name) |c| {
        switch (c) {
            '"' => try writer.writeAll("%22"),
            '\r' => try writer.writeAll("%0D"),
            '\n' => try writer.writeAll("%0A"),
            else => try writer.writeByte(c),
        }
    }
}

// Used by URLSearchParams to ingest a FormData; file entries collapse via Value.asString.
pub fn toKeyValueList(self: *const FormData, arena: Allocator) !KeyValueList {
    var list: KeyValueList = .empty;
    try list.ensureTotalCapacity(arena, self._entries.items.len);
    for (self._entries.items) |*entry| {
        try list.appendAssumeCapacity(arena, entry.name.str(), entry.value.asString());
    }
    return list;
}

pub const Iterator = struct {
    index: u32 = 0,
    fd: *FormData,

    // See KeyValueList.Iterator.list — required by the GenericIterator wrapper.
    list: *anyopaque,

    pub const Entry = struct { []const u8, []const u8 };

    pub fn next(self: *Iterator, _: *const Execution) ?Iterator.Entry {
        const index = self.index;
        const items = self.fd._entries.items;
        if (index >= items.len) {
            return null;
        }
        self.index = index + 1;

        const e = &items[index];
        return .{ e.name.str(), e.value.asString() };
    }
};

const GenericIterator = @import("../collections/iterator.zig").Entry;
pub const KeyIterator = GenericIterator(Iterator, "0");
pub const ValueIterator = GenericIterator(Iterator, "1");
pub const EntryIterator = GenericIterator(Iterator, null);

pub fn registerTypes() []const type {
    return &.{
        FormData,
        KeyIterator,
        ValueIterator,
        EntryIterator,
    };
}

fn collectForm(arena: Allocator, form_: ?*Form, submitter_: ?*Element, frame: *Frame) !std.ArrayList(Entry) {
    var list: std.ArrayList(Entry) = .empty;
    const form = form_ orelse return list;

    var elements = try form.getElements(frame);
    var it = try elements.iterator();
    while (it.next()) |element| {
        if (element.isDisabled()) {
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
                try appendString(&list, arena, x_key, "0");
                try appendString(&list, arena, y_key, "0");
                continue;
            }
        }

        const name = element.getAttributeSafe(comptime .wrap("name")) orelse continue;
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
                    // Per the HTML spec, a single-select with no selectedness
                    // candidate (zero options or every option disabled)
                    // contributes no entry. Otherwise emit the candidate's
                    // value.
                    const opt = select.effectiveOption() orelse continue;
                    break :blk opt.getValue(frame);
                }

                var options = try select.getSelectedOptions(frame);
                while (options.next()) |option| {
                    try appendString(&list, arena, name, option.as(Form.Select.Option).getValue(frame));
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
        try appendString(&list, arena, name, value);
    }
    return list;
}

fn appendString(list: *std.ArrayList(Entry), arena: Allocator, name: []const u8, value: []const u8) !void {
    try list.append(arena, .{
        .name = try String.init(arena, name, .{}),
        .value = .{ .string = try String.init(arena, value, .{}) },
    });
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

test "FormData: multipart write" {
    const allocator = testing.arena_allocator;

    var fd = FormData{
        ._arena = allocator,
        ._entries = .empty,
    };
    try fd.append("name", "John");
    try fd.append("note", "two\r\nlines");

    var buf = std.Io.Writer.Allocating.init(allocator);
    try fd.write(.{
        .encoding = .{ .formdata = "BOUNDARY" },
        .allocator = allocator,
    }, &buf.writer);

    try testing.expectString(
        "--BOUNDARY\r\n" ++
            "Content-Disposition: form-data; name=\"name\"\r\n\r\n" ++
            "John\r\n" ++
            "--BOUNDARY\r\n" ++
            "Content-Disposition: form-data; name=\"note\"\r\n\r\n" ++
            "two\r\nlines\r\n" ++
            "--BOUNDARY--\r\n",
        buf.written(),
    );
}

test "FormData: multipart escapes name CR/LF/quote" {
    const allocator = testing.arena_allocator;

    var fd = FormData{
        ._arena = allocator,
        ._entries = .empty,
    };
    try fd.append("a\"b\r\nc", "v");

    var buf = std.Io.Writer.Allocating.init(allocator);
    try fd.write(.{
        .encoding = .{ .formdata = "B" },
        .allocator = allocator,
    }, &buf.writer);

    try testing.expectString(
        "--B\r\n" ++
            "Content-Disposition: form-data; name=\"a%22b%0D%0Ac\"\r\n\r\n" ++
            "v\r\n" ++
            "--B--\r\n",
        buf.written(),
    );
}

test "FormData: multipart empty body" {
    const allocator = testing.arena_allocator;

    var fd = FormData{
        ._arena = allocator,
        ._entries = .empty,
    };

    var buf = std.Io.Writer.Allocating.init(allocator);
    try fd.write(.{
        .encoding = .{ .formdata = "B" },
        .allocator = allocator,
    }, &buf.writer);

    try testing.expectString("--B--\r\n", buf.written());
}
