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
const Page = @import("../../Page.zig");
const Frame = @import("../../Frame.zig");
const Form = @import("../element/html/Form.zig");
const Element = @import("../Element.zig");
const Blob = @import("../Blob.zig");
const File = @import("../File.zig");
const KeyValueList = @import("../KeyValueList.zig");
const simd = @import("../../../simd.zig");

const log = lp.log;
const String = lp.String;
const Execution = js.Execution;
const Allocator = std.mem.Allocator;

const FormData = @This();

_rc: lp.RC,

_arena: Allocator,
_entries: std.ArrayList(Entry),

pub const Entry = struct {
    name: String,
    value: Value,

    const Value = union(enum) {
        no_file: void,
        file: *File,
        string: String,

        fn asString(self: *const Value) []const u8 {
            return switch (self.*) {
                .string => |*s| s.str(),
                // Per WHATWG, file entries serialized in a non-multipart encoding
                // (application/x-www-form-urlencoded, text/plain) collapse to the
                // file's name only — body is dropped.
                .file => |f| f.getName(),
                // An unselected file input contributes a File with an empty name,
                // so it collapses to the empty string.
                .no_file => "",
            };
        }

        pub fn format(self: Value, writer: *std.Io.Writer) !void {
            return switch (self) {
                .string => |s| s.format(writer),
                .file => |f| writer.writeAll(f.getName()),
                .no_file => {},
            };
        }
    };
};

pub fn init(form_: ?*Form, submitter: ?*Element, exec: *const Execution) !*FormData {
    const arena = try exec.getArena(.small, "FormData");
    errdefer exec.releaseArena(arena);

    const form_data = try arena.create(FormData);
    form_data.* = .{
        ._rc = .{},
        ._arena = arena,
        ._entries = .empty,
    };

    const form = form_ orelse return form_data;

    const frame = switch (exec.js.global) {
        .frame => |f| f,
        .worker => lp.assert(false, "FormData worker form", .{}),
    };

    if (form._constructing_entry_list) {
        // see the `_constructing_entry_list` field documentation
        return error.InvalidStateError;
    }

    form._constructing_entry_list = true;
    defer form._constructing_entry_list = false;

    form_data._entries = try collectForm(arena, form, submitter, frame);

    // Hold a reference on each entry's File for the FormData's lifetime; released
    // in deinit.
    for (form_data._entries.items) |entry| {
        switch (entry.value) {
            .file => |file| file.acquireRef(),
            else => {},
        }
    }

    const form_data_event = try (@import("../event/FormDataEvent.zig")).initTrusted(
        comptime .wrap("formdata"),
        .{ .bubbles = true, .cancelable = false, .formData = form_data },
        frame,
    );
    try frame._event_manager.dispatch(form.asNode().asEventTarget(), form_data_event.asEvent());

    return form_data;
}

// Fetch §6.4 "package data" with type FormData: parse an
// application/x-www-form-urlencoded body back into a FormData.
pub fn initFromUrlEncoded(bytes: []const u8, exec: *const Execution) !*FormData {
    const arena = try exec.getArena(.small, "FormData");
    errdefer exec.releaseArena(arena);

    const form_data = try arena.create(FormData);
    form_data.* = .{
        ._rc = .{},
        ._arena = arena,
        ._entries = .empty,
    };
    try form_data.parseUrlEncoded(bytes);
    return form_data;
}

// Fetch §6.4 "package data" with type FormData: parse a multipart/form-data
// body back into a FormData. `boundary` is the Content-Type boundary param.
pub fn initFromMultipart(bytes: []const u8, boundary: []const u8, exec: *const Execution) !*FormData {
    const arena = try exec.getArena(.small, "FormData");
    errdefer exec.releaseArena(arena);

    const form_data = try arena.create(FormData);
    form_data.* = .{
        ._rc = .{},
        ._arena = arena,
        ._entries = .empty,
    };

    // On failure, drop the refs parseMultipart acquired on the file entries
    // appended so far (runs before the arena release above frees the list).
    errdefer for (form_data._entries.items) |entry| switch (entry.value) {
        .file => |file| file.releaseRef(exec.page),
        else => {},
    };

    try form_data.parseMultipart(exec.page, bytes, boundary);
    return form_data;
}

pub fn deinit(self: *FormData, page: *Page) void {
    for (self._entries.items) |entry| {
        switch (entry.value) {
            .file => |file| file.releaseRef(page),
            else => {},
        }
    }
    // Frees the entry list and this FormData itself; do not touch self afterwards.
    page.releaseArena(self._arena);
}

pub fn releaseRef(self: *FormData, page: *Page) void {
    self._rc.release(self, page);
}

pub fn acquireRef(self: *FormData) void {
    self._rc.acquire();
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

pub fn set(self: *FormData, name: String, value: []const u8, exec: *Execution) !void {
    self.deleteByName(name, exec);
    return self.append(name.str(), value);
}

pub fn append(self: *FormData, name: []const u8, value: []const u8) !void {
    try self._entries.append(self._arena, .{
        .name = try String.init(self._arena, name, .{}),
        .value = .{ .string = try String.init(self._arena, value, .{}) },
    });
}

pub fn delete(self: *FormData, name: String, exec: *Execution) void {
    self.deleteByName(name, exec);
}

fn deleteByName(self: *FormData, name: String, exec: *Execution) void {
    var i: usize = 0;
    while (i < self._entries.items.len) {
        if (self._entries.items[i].name.eql(name)) {
            const entry = self._entries.swapRemove(i);

            switch (entry.value) {
                .file => |file| file.releaseRef(exec.page),
                else => {},
            }

            continue;
        }
        i += 1;
    }
}

pub fn keys(self: *FormData, exec: *const js.Execution) !*KeyIterator {
    return KeyIterator.init(.{ .fd = self }, exec);
}

pub fn values(self: *FormData, exec: *const js.Execution) !*ValueIterator {
    return ValueIterator.init(.{ .fd = self }, exec);
}

pub fn entries(self: *FormData, exec: *const js.Execution) !*EntryIterator {
    return EntryIterator.init(.{ .fd = self }, exec);
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
    plaintext,
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
        .plaintext => return self.plaintextEncode(writer),
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

/// https://html.spec.whatwg.org/multipage/form-control-infrastructure.html#text/plain-encoding-algorithm
///
/// For each entry: name, "=", value, CRLF. No URL-encoding, no escaping. Per the
/// spec this is a low-fidelity encoding intended for human-readable values; a
/// value containing "=" or CRLF produces an ambiguous wire format, by design.
fn plaintextEncode(self: *const FormData, writer: *std.Io.Writer) !void {
    for (self._entries.items) |*entry| {
        try entry.name.format(writer);
        try writer.writeByte('=');
        try entry.value.format(writer);
        try writer.writeAll("\r\n");
    }
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
        // Per RFC 7578 + WHATWG FormData: file parts carry a filename in
        // Content-Disposition, a Content-Type (defaulting to
        // application/octet-stream when the Blob has no MIME), and the raw bytes.
        .file => |file| {
            try writer.writeAll("Content-Disposition: form-data; name=\"");
            try writeMultipartName(writer, entry.name.str());
            try writer.writeAll("\"; filename=\"");
            try writeMultipartName(writer, file.getName());
            try writer.writeAll("\"\r\n");

            const mime = file._proto._mime;
            try writer.writeAll("Content-Type: ");
            try writer.writeAll(if (mime.len == 0) "application/octet-stream" else mime);
            try writer.writeAll("\r\n\r\n");

            try writer.writeAll(file._proto._slice);
            try writer.writeAll("\r\n");
        },
        // An unselected file input still contributes a part: an empty filename,
        // the default application/octet-stream Content-Type, and an empty body.
        // This matches the empty File (no name, no type, no body) the WHATWG
        // algorithm creates, and Chrome's wire output.
        .no_file => {
            try writer.writeAll("Content-Disposition: form-data; name=\"");
            try writeMultipartName(writer, entry.name.str());
            try writer.writeAll("\"; filename=\"\"\r\n");
            try writer.writeAll("Content-Type: application/octet-stream\r\n\r\n");
            try writer.writeAll("\r\n");
        },
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

// Inverse of urlEncode: application/x-www-form-urlencoded parsing per
// URL §5.1 — '+' decodes to a space, invalid percent sequences pass through
// verbatim, and a pair without '=' becomes an entry with an empty value.
pub fn parseUrlEncoded(self: *FormData, bytes: []const u8) !void {
    var it = std.mem.splitScalar(u8, bytes, '&');
    while (it.next()) |pair| {
        if (pair.len == 0) {
            continue;
        }
        if (std.mem.indexOfScalar(u8, pair, '=')) |idx| {
            try self.append(
                try urlDecode(self._arena, pair[0..idx]),
                try urlDecode(self._arena, pair[idx + 1 ..]),
            );
        } else {
            const key = try urlDecode(self._arena, pair);
            // Insert with empty value.
            try self.append(key, "");
        }
    }
}

/// Index of the first byte needing URL-decoding ('%' or '+'), or null if
/// the slice needs no decoding at all.
fn indexOfSpecial(slice: []const u8) ?usize {
    const vector_len = std.simd.suggestVectorLength(u8) orelse {
        // Non-SIMD path.
        return std.mem.indexOfAnyPos(u8, slice, 0, "%+");
    };
    const Vector = @Vector(vector_len, u8);

    var end: usize = 0;
    while (end + vector_len <= slice.len) : (end += vector_len) {
        const percent: Vector = @splat('%');
        const plus: Vector = @splat('+');
        const chunk: Vector = slice[end..][0..vector_len].*;

        const mask = @intFromBool(chunk == percent) | @intFromBool(chunk == plus);
        const mask_int = @as(std.meta.Int(.unsigned, vector_len), @bitCast(mask));

        if (mask_int != 0) {
            return end + @ctz(mask_int);
        }
    }

    return std.mem.indexOfAnyPos(u8, slice, end, "%+");
}

/// URL-decodes passed `raw` slice; returned value may or may not be heap allocated.
/// TODO: This can be more efficient I believe.
fn urlDecode(arena: Allocator, raw: []const u8) ![]const u8 {
    // Get where to start decoding.
    var i: usize = indexOfSpecial(raw) orelse return raw;

    var out: std.ArrayList(u8) = try .initCapacity(arena, raw.len);
    out.appendSliceAssumeCapacity(raw[0..i]);

    while (i < raw.len) {
        const c = raw[i];
        switch (c) {
            '+' => {
                out.appendAssumeCapacity(' ');
                i += 1;
            },
            '%' => {
                // Per URL §5.1 percent-decode, an invalid or truncated
                // escape sequence passes through verbatim.
                const decoded: ?u8 = blk: {
                    if (i + 2 >= raw.len) break :blk null;
                    const hi = std.fmt.charToDigit(raw[i + 1], 16) catch break :blk null;
                    const lo = std.fmt.charToDigit(raw[i + 2], 16) catch break :blk null;
                    break :blk hi * 16 + lo;
                };
                if (decoded) |b| {
                    out.appendAssumeCapacity(b);
                    i += 3;
                } else {
                    out.appendAssumeCapacity('%');
                    i += 1;
                }
            },
            else => {
                out.appendAssumeCapacity(c);
                i += 1;
            },
        }
    }

    return out.items;
}

// Inverse of multipartEncode: strict multipart/form-data parsing (no
// preamble, CRLF line breaks). Parts carrying a filename become File
// entries — the FormData holds a ref on each, released in deinit — and the
// rest become string entries.
fn parseMultipart(self: *FormData, page: *Page, bytes: []const u8, boundary: []const u8) !void {
    // The body must open with the dash-boundary: "--" boundary.
    if (!std.mem.startsWith(u8, bytes, "--") or !std.mem.startsWith(u8, bytes[2..], boundary)) {
        return error.InvalidFormData;
    }
    // Skip-past boundary.
    var cursor = bytes[2 + boundary.len ..];

    const double_dash: u16 = @bitCast([_]u8{ '-', '-' });
    const crlf: u16 = @bitCast([_]u8{ '\r', '\n' });

    while (true) {
        if (cursor.len < 2) {
            return error.InvalidFormData;
        }
        const prefix: u16 = @bitCast(cursor[0..2].*);
        // Check if we've reached the end.
        if (prefix == double_dash) {
            return;
        }
        // If we haven't reached the end, CRLF is required.
        if (prefix != crlf) {
            return error.InvalidFormData;
        }
        // Consume prefix.
        cursor = cursor[2..];

        // Content-Disposition can appear once a part, and is required.
        var disposition: ?simd.Disposition = null;
        // Default Content-Type; can be overwritten while parsing headers.
        var content_type: []const u8 = "text/plain";
        // Reused for parsing headers.
        var header: simd.HttpHeader = undefined;

        // Parse the whole header block; the content starts only after the
        // terminating empty line.
        while (true) {
            if (cursor.len == 0) {
                return error.InvalidFormData;
            }

            // Check if headers part has finished.
            switch (cursor[0]) {
                '\n' => {
                    // End of headers.
                    cursor = cursor[1..];
                    break;
                },
                '\r' => {
                    // We need a `\n` character too.
                    if (cursor.len < 2 or cursor[1] != '\n') {
                        return error.InvalidFormData;
                    }

                    // End of headers.
                    cursor = cursor[2..];
                    break;
                },
                else => {},
            }

            const consumed = try simd.parseHttpHeader(cursor, &header);
            cursor = cursor[consumed..];

            if (std.ascii.eqlIgnoreCase(header.key, "content-type")) {
                content_type = header.value;
            } else if (std.ascii.eqlIgnoreCase(header.key, "content-disposition")) {
                if (disposition != null) {
                    // Content-Disposition found twice, report an error.
                    return error.InvalidFormData;
                }
                disposition = try simd.parseDisposition(header.value);
            }
        }

        const parsed = disposition orelse return error.InvalidFormData;
        const name = try decodeMultipartName(self._arena, parsed.name orelse return error.InvalidFormData);

        const content_end = indexOfBoundary(cursor, boundary) orelse return error.InvalidFormData;
        const content = cursor[0..content_end];
        cursor = cursor[content_end + "\r\n--".len + boundary.len ..];

        // Got a file.
        if (parsed.filename) |filename| {
            const blob = try Blob.initFromBytes(content, content_type, page);
            errdefer blob.deinit(page);

            const file = try blob._arena.create(File);
            file.* = .{
                ._proto = blob,
                ._name = try blob._arena.dupe(u8, try decodeMultipartName(self._arena, filename)),
                ._last_modified = std.time.milliTimestamp(),
            };
            blob._type = .{ .file = file };

            file.acquireRef();
            try self._entries.append(self._arena, .{
                .name = try String.init(self._arena, name, .{}),
                .value = .{ .file = file },
            });
        } else {
            try self.append(name, content);
        }
    }
}

// Finds the "\r\n--" ++ boundary delimiter in haystack without materializing
// the needle. Per RFC 2046 §5.1.1 the delimiter must be followed by CRLF (or
// "--" for the close delimiter), so a value containing the boundary as a
// prefix of longer text does not terminate the part.
fn indexOfBoundary(haystack: []const u8, boundary: []const u8) ?usize {
    var start: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, start, "\r\n--")) |i| {
        const rest = haystack[i + 4 ..];
        if (std.mem.startsWith(u8, rest, boundary)) {
            const after = rest[boundary.len..];
            if (std.mem.startsWith(u8, after, "\r\n") or std.mem.startsWith(u8, after, "--")) {
                return i;
            }
        }
        start = i + 1;
    }
    return null;
}

// "Parse a multipart/form-data name": undo writeMultipartName's escapes
// (%0A, %0D, %22); any other percent sequence passes through verbatim.
fn decodeMultipartName(arena: Allocator, raw: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, raw, '%') == null) {
        return raw;
    }

    var out: std.ArrayList(u8) = try .initCapacity(arena, raw.len);
    var i: usize = 0;
    while (i < raw.len) {
        const rest = raw[i..];
        if (std.mem.startsWith(u8, rest, "%22")) {
            out.appendAssumeCapacity('"');
            i += 3;
        } else if (std.mem.startsWith(u8, rest, "%0D")) {
            out.appendAssumeCapacity('\r');
            i += 3;
        } else if (std.mem.startsWith(u8, rest, "%0A")) {
            out.appendAssumeCapacity('\n');
            i += 3;
        } else {
            out.appendAssumeCapacity(raw[i]);
            i += 1;
        }
    }
    return out.items;
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

    pub const Entry = struct { []const u8, []const u8 };

    pub fn acquireRef(self: *Iterator) void {
        self.fd.acquireRef();
    }

    pub fn releaseRef(self: *Iterator, page: *Page) void {
        self.fd.releaseRef(page);
    }

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
                if (input_type == .file) {
                    // WHATWG: a file input with zero selected files contributes a
                    // single entry whose value is an empty File of MIME
                    // application/octet-stream; otherwise, one entry per file.
                    const files = if (input._files) |fl| fl._files else &.{};
                    if (files.len == 0) {
                        try list.append(arena, .{
                            .name = try String.init(arena, name, .{}),
                            .value = .no_file,
                        });
                    } else {
                        for (files) |file| {
                            try appendFile(&list, arena, name, file);
                        }
                    }
                    continue;
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

fn appendFile(list: *std.ArrayList(Entry), arena: Allocator, name: []const u8, file: *File) !void {
    try list.append(arena, .{
        .name = try String.init(arena, name, .{}),
        .value = .{ .file = file },
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
        ._rc = .{},
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
        ._rc = .{},
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
        ._rc = .{},
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

fn buildTestFile(arena: Allocator, page: *@import("../../Page.zig"), name: []const u8, mime: []const u8, body: []const u8) !*File {
    const blob = try Blob.initFromBytes(body, mime, page);
    blob.acquireRef();
    const file = try arena.create(File);
    file.* = .{
        ._proto = blob,
        ._name = try arena.dupe(u8, name),
        ._last_modified = 0,
    };
    return file;
}

test "FormData: multipart with file" {
    const allocator = testing.arena_allocator;
    const frame = try testing.createFrame();
    defer testing.test_session.closeAllPages();

    const file = try buildTestFile(allocator, frame._page, "hello.txt", "text/plain", "hello");
    defer file._proto.releaseRef(frame._page);

    var fd = FormData{
        ._rc = .{},
        ._arena = allocator,
        ._entries = .empty,
    };
    try fd.append("field", "value");
    try fd._entries.append(allocator, .{
        .name = try String.init(allocator, "upload", .{}),
        .value = .{ .file = file },
    });

    var buf = std.Io.Writer.Allocating.init(allocator);
    try fd.write(.{
        .encoding = .{ .formdata = "BOUNDARY" },
        .allocator = allocator,
    }, &buf.writer);

    try testing.expectString(
        "--BOUNDARY\r\n" ++
            "Content-Disposition: form-data; name=\"field\"\r\n\r\n" ++
            "value\r\n" ++
            "--BOUNDARY\r\n" ++
            "Content-Disposition: form-data; name=\"upload\"; filename=\"hello.txt\"\r\n" ++
            "Content-Type: text/plain\r\n\r\n" ++
            "hello\r\n" ++
            "--BOUNDARY--\r\n",
        buf.written(),
    );
}

test "FormData: multipart with empty file defaults to octet-stream" {
    const allocator = testing.arena_allocator;
    const frame = try testing.createFrame();
    defer testing.test_session.closeAllPages();

    const file = try buildTestFile(allocator, frame._page, "", "", "");
    defer file._proto.releaseRef(frame._page);

    var fd = FormData{
        ._rc = .{},
        ._arena = allocator,
        ._entries = .empty,
    };
    try fd._entries.append(allocator, .{
        .name = try String.init(allocator, "upload", .{}),
        .value = .{ .file = file },
    });

    var buf = std.Io.Writer.Allocating.init(allocator);
    try fd.write(.{
        .encoding = .{ .formdata = "B" },
        .allocator = allocator,
    }, &buf.writer);

    try testing.expectString(
        "--B\r\n" ++
            "Content-Disposition: form-data; name=\"upload\"; filename=\"\"\r\n" ++
            "Content-Type: application/octet-stream\r\n\r\n" ++
            "\r\n" ++
            "--B--\r\n",
        buf.written(),
    );
}

test "FormData: multipart escapes file name and filename" {
    const allocator = testing.arena_allocator;
    const frame = try testing.createFrame();
    defer testing.test_session.closeAllPages();

    const file = try buildTestFile(allocator, frame._page, "a\"b\r\nc.txt", "text/plain", "x");
    defer file._proto.releaseRef(frame._page);

    var fd = FormData{
        ._rc = .{},
        ._arena = allocator,
        ._entries = .empty,
    };
    try fd._entries.append(allocator, .{
        .name = try String.init(allocator, "up\"load", .{}),
        .value = .{ .file = file },
    });

    var buf = std.Io.Writer.Allocating.init(allocator);
    try fd.write(.{
        .encoding = .{ .formdata = "B" },
        .allocator = allocator,
    }, &buf.writer);

    try testing.expectString(
        "--B\r\n" ++
            "Content-Disposition: form-data; name=\"up%22load\"; filename=\"a%22b%0D%0Ac.txt\"\r\n" ++
            "Content-Type: text/plain\r\n\r\n" ++
            "x\r\n" ++
            "--B--\r\n",
        buf.written(),
    );
}

test "FormData: file entry collapses to filename in urlencode" {
    const allocator = testing.arena_allocator;
    const frame = try testing.createFrame();
    defer testing.test_session.closeAllPages();

    const file = try buildTestFile(allocator, frame._page, "hello.txt", "text/plain", "hello");
    defer file._proto.releaseRef(frame._page);

    var fd = FormData{
        ._rc = .{},
        ._arena = allocator,
        ._entries = .empty,
    };
    try fd._entries.append(allocator, .{
        .name = try String.init(allocator, "upload", .{}),
        .value = .{ .file = file },
    });

    var buf = std.Io.Writer.Allocating.init(allocator);
    try fd.write(.{ .encoding = .urlencode, .allocator = allocator }, &buf.writer);
    try testing.expectString("upload=hello.txt", buf.written());
}

test "FormData: multipart no_file (unselected file input)" {
    const allocator = testing.arena_allocator;

    var fd = FormData{
        ._rc = .{},
        ._arena = allocator,
        ._entries = .empty,
    };
    try fd._entries.append(allocator, .{
        .name = try String.init(allocator, "upload", .{}),
        .value = .no_file,
    });

    var buf = std.Io.Writer.Allocating.init(allocator);
    try fd.write(.{
        .encoding = .{ .formdata = "B" },
        .allocator = allocator,
    }, &buf.writer);

    try testing.expectString(
        "--B\r\n" ++
            "Content-Disposition: form-data; name=\"upload\"; filename=\"\"\r\n" ++
            "Content-Type: application/octet-stream\r\n\r\n" ++
            "\r\n" ++
            "--B--\r\n",
        buf.written(),
    );
}

test "FormData: no_file entry collapses to empty in urlencode" {
    const allocator = testing.arena_allocator;

    var fd = FormData{
        ._rc = .{},
        ._arena = allocator,
        ._entries = .empty,
    };
    try fd._entries.append(allocator, .{
        .name = try String.init(allocator, "upload", .{}),
        .value = .no_file,
    });

    var buf = std.Io.Writer.Allocating.init(allocator);
    try fd.write(.{ .encoding = .urlencode, .allocator = allocator }, &buf.writer);
    try testing.expectString("upload=", buf.written());
}

test "FormData: plaintext write" {
    const allocator = testing.arena_allocator;

    var fd = FormData{
        ._rc = .{},
        ._arena = allocator,
        ._entries = .empty,
    };
    try fd.append("name", "John");
    try fd.append("note", "two\r\nlines");
    try fd.append("equals", "a=b");

    var buf = std.Io.Writer.Allocating.init(allocator);
    try fd.write(.{ .encoding = .plaintext, .allocator = allocator }, &buf.writer);

    // Per WHATWG HTML text/plain encoding algorithm: name=value CRLF per entry.
    // Values containing "=" or CRLF are written verbatim — the spec accepts that
    // text/plain is a low-fidelity, lossy encoding for human-readable content.
    try testing.expectString(
        "name=John\r\n" ++
            "note=two\r\nlines\r\n" ++
            "equals=a=b\r\n",
        buf.written(),
    );
}

test "FormData: plaintext empty body" {
    const allocator = testing.arena_allocator;

    var fd = FormData{
        ._rc = .{},
        ._arena = allocator,
        ._entries = .empty,
    };

    var buf = std.Io.Writer.Allocating.init(allocator);
    try fd.write(.{ .encoding = .plaintext, .allocator = allocator }, &buf.writer);

    try testing.expectString("", buf.written());
}

test "FormData: urlencoded parse" {
    const allocator = testing.arena_allocator;

    var fd = FormData{
        ._rc = .{},
        ._arena = allocator,
        ._entries = .empty,
    };
    try fd.parseUrlEncoded("a=1&b=hello+world&c=%26%3D&no_value&&bad=100%zz");

    try testing.expectEqual(5, fd._entries.items.len);
    try testing.expectString("1", fd.get(.wrap("a")).?);
    try testing.expectString("hello world", fd.get(.wrap("b")).?);
    try testing.expectString("&=", fd.get(.wrap("c")).?);
    try testing.expectString("", fd.get(.wrap("no_value")).?);
    // An invalid percent sequence passes through verbatim.
    try testing.expectString("100%zz", fd.get(.wrap("bad")).?);
}

test "FormData: urlencoded parse exercises the vectorized guard" {
    const allocator = testing.arena_allocator;

    var fd = FormData{
        ._rc = .{},
        ._arena = allocator,
        ._entries = .empty,
    };
    // Values longer than any SIMD vector length, with the lone special
    // character early so only the vectorized loop (not the scalar tail)
    // can spot it — a regression guard for needsDecoding's chunk mask.
    try fd.parseUrlEncoded("plus=aaa+aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" ++
        "&pct=aaa%41aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" ++
        "&clean=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");

    try testing.expectString("aaa aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", fd.get(.wrap("plus")).?);
    try testing.expectString("aaaAaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", fd.get(.wrap("pct")).?);
    try testing.expectString("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", fd.get(.wrap("clean")).?);
}

test "FormData: multipart parse" {
    const allocator = testing.arena_allocator;
    const frame = try testing.createFrame();
    defer testing.test_session.closeAllPages();

    var fd = FormData{
        ._rc = .{},
        ._arena = allocator,
        ._entries = .empty,
    };
    try fd.parseMultipart(frame._page, "--BOUNDARY\r\n" ++
        "Content-Disposition: form-data; name=\"name\"\r\n\r\n" ++
        "John\r\n" ++
        "--BOUNDARY\r\n" ++
        "Content-Disposition: form-data; name=\"a%22b%0D%0Ac\"\r\n\r\n" ++
        "two\r\nlines\r\n" ++
        "--BOUNDARY\r\n" ++
        "Content-Disposition: form-data; name=\"tricky\"\r\n\r\n" ++
        "a\r\n--BOUNDARYx b\r\n" ++
        "--BOUNDARY--\r\n", "BOUNDARY");

    try testing.expectEqual(3, fd._entries.items.len);
    try testing.expectString("John", fd.get(.wrap("name")).?);
    // Escaped name decodes, and a value containing CRLF survives.
    try testing.expectString("a\"b\r\nc", fd._entries.items[1].name.str());
    try testing.expectString("two\r\nlines", fd._entries.items[1].value.asString());
    // The boundary as a prefix of longer text is not a delimiter.
    try testing.expectString("a\r\n--BOUNDARYx b", fd.get(.wrap("tricky")).?);
}

test "FormData: multipart parse with file" {
    const allocator = testing.arena_allocator;
    const frame = try testing.createFrame();
    defer testing.test_session.closeAllPages();

    var fd = FormData{
        ._rc = .{},
        ._arena = allocator,
        ._entries = .empty,
    };
    try fd.parseMultipart(frame._page, "--B\r\n" ++
        "Content-Disposition: form-data; name=\"upload\"; filename=\"hello.txt\"\r\n" ++
        "Content-Type: text/plain\r\n\r\n" ++
        "hello\r\n" ++
        "--B\r\n" ++
        "Content-Disposition: form-data; name=\"raw\"; filename=\"raw.bin\"\r\n\r\n" ++
        "bytes\r\n" ++
        "--B--\r\n", "B");
    defer for (fd._entries.items) |entry| switch (entry.value) {
        .file => |file| file.releaseRef(frame._page),
        else => {},
    };

    try testing.expectEqual(2, fd._entries.items.len);

    const file = fd._entries.items[0].value.file;
    try testing.expectString("upload", fd._entries.items[0].name.str());
    try testing.expectString("hello.txt", file.getName());
    try testing.expectString("hello", file._proto._slice);
    try testing.expectString("text/plain", file._proto._mime);

    // A file part without a Content-Type header defaults to text/plain.
    const raw = fd._entries.items[1].value.file;
    try testing.expectString("raw.bin", raw.getName());
    try testing.expectString("bytes", raw._proto._slice);
    try testing.expectString("text/plain", raw._proto._mime);
}

test "FormData: multipart parse rejects malformed bodies" {
    const allocator = testing.arena_allocator;
    const frame = try testing.createFrame();
    defer testing.test_session.closeAllPages();

    const cases = [_][]const u8{
        "", // no dash-boundary
        "--OTHER\r\n", // wrong boundary
        "--B\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\nv\r\n", // unterminated
        "--B\r\n\r\nv\r\n--B--\r\n", // no Content-Disposition
        "--B\r\nContent-Disposition: inline; name=\"a\"\r\n\r\nv\r\n--B--\r\n", // not form-data
        "--B\r\nContent-Disposition: form-data\r\n\r\nv\r\n--B--\r\n", // no name
    };
    for (cases) |case| {
        var fd = FormData{
            ._rc = .{},
            ._arena = allocator,
            ._entries = .empty,
        };
        try testing.expectError(error.InvalidFormData, fd.parseMultipart(frame._page, case, "B"));
    }
}

test "FormData: multipart round-trip" {
    const allocator = testing.arena_allocator;
    const frame = try testing.createFrame();
    defer testing.test_session.closeAllPages();

    var src = FormData{
        ._rc = .{},
        ._arena = allocator,
        ._entries = .empty,
    };
    try src.append("username", "alice");
    try src.append("username", "bob");
    try src.append("a\"b\r\nc", "quoted \"value\"");

    var buf = std.Io.Writer.Allocating.init(allocator);
    try src.write(.{
        .encoding = .{ .formdata = "BOUNDARY" },
        .allocator = allocator,
    }, &buf.writer);

    var fd = FormData{
        ._rc = .{},
        ._arena = allocator,
        ._entries = .empty,
    };
    try fd.parseMultipart(frame._page, buf.written(), "BOUNDARY");

    try testing.expectEqual(3, fd._entries.items.len);
    try testing.expectString("username", fd._entries.items[0].name.str());
    try testing.expectString("alice", fd._entries.items[0].value.asString());
    try testing.expectString("username", fd._entries.items[1].name.str());
    try testing.expectString("bob", fd._entries.items[1].value.asString());
    try testing.expectString("quoted \"value\"", fd.get(.wrap("a\"b\r\nc")).?);
}
