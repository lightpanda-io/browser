// Copyright (C) 2023-2026  Lightpanda (Selecy SAS)
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

const String = @import("../../string.zig").String;

const js = @import("../js/js.zig");
const Page = @import("../Page.zig");
const h5e = @import("../parser/html5ever.zig");

const Execution = js.Execution;
const Allocator = std.mem.Allocator;

pub fn registerTypes() []const type {
    return &.{
        KeyIterator,
        ValueIterator,
        EntryIterator,
    };
}

const Normalizer = *const fn ([]const u8, []u8) []const u8;

pub const Entry = struct {
    name: String,
    value: String,

    pub fn format(self: Entry, writer: *std.Io.Writer) !void {
        return writer.print("{f}: {f}", .{ self.name, self.value });
    }
};

pub const KeyValueList = @This();

_entries: std.ArrayList(Entry) = .empty,

pub const empty: KeyValueList = .{
    ._entries = .empty,
};

pub fn copy(arena: Allocator, original: KeyValueList) !KeyValueList {
    var list = KeyValueList.init();
    try list.ensureTotalCapacity(arena, original.len());
    for (original._entries.items) |entry| {
        try list.appendAssumeCapacity(arena, entry.name.str(), entry.value.str());
    }
    return list;
}

pub fn fromJsObject(arena: Allocator, js_obj: js.Object, comptime normalizer: ?Normalizer, buf: []u8) !KeyValueList {
    var it = try js_obj.nameIterator();
    var list = KeyValueList.init();
    try list.ensureTotalCapacity(arena, it.count);

    while (try it.next()) |name| {
        const js_value = try js_obj.get(name);
        const normalized = if (comptime normalizer) |n| n(name, buf) else name;

        list._entries.appendAssumeCapacity(.{
            .name = try String.init(arena, normalized, .{}),
            .value = try js_value.toSSOWithAlloc(arena),
        });
    }

    return list;
}

pub fn fromArray(arena: Allocator, kvs: []const [2][]const u8, comptime normalizer: ?Normalizer, buf: []u8) !KeyValueList {
    var list = KeyValueList.init();
    try list.ensureTotalCapacity(arena, kvs.len);

    for (kvs) |pair| {
        const normalized = if (comptime normalizer) |n| n(pair[0], buf) else pair[0];

        list._entries.appendAssumeCapacity(.{
            .name = try String.init(arena, normalized, .{}),
            .value = try String.init(arena, pair[1], .{}),
        });
    }
    return list;
}

pub fn init() KeyValueList {
    return .{};
}

pub fn ensureTotalCapacity(self: *KeyValueList, allocator: Allocator, n: usize) !void {
    return self._entries.ensureTotalCapacity(allocator, n);
}

pub fn get(self: *const KeyValueList, name: []const u8) ?[]const u8 {
    for (self._entries.items) |*entry| {
        if (entry.name.eqlSlice(name)) {
            return entry.value.str();
        }
    }
    return null;
}

pub fn getAll(self: *const KeyValueList, allocator: Allocator, name: []const u8) ![]const []const u8 {
    var arr: std.ArrayList([]const u8) = .empty;
    for (self._entries.items) |*entry| {
        if (entry.name.eqlSlice(name)) {
            try arr.append(allocator, entry.value.str());
        }
    }
    return arr.items;
}

pub fn has(self: *const KeyValueList, name: []const u8) bool {
    for (self._entries.items) |*entry| {
        if (entry.name.eqlSlice(name)) {
            return true;
        }
    }
    return false;
}

pub fn append(self: *KeyValueList, allocator: Allocator, name: []const u8, value: []const u8) !void {
    try self._entries.append(allocator, .{
        .name = try String.init(allocator, name, .{}),
        .value = try String.init(allocator, value, .{}),
    });
}

pub fn appendAssumeCapacity(self: *KeyValueList, allocator: Allocator, name: []const u8, value: []const u8) !void {
    self._entries.appendAssumeCapacity(.{
        .name = try String.init(allocator, name, .{}),
        .value = try String.init(allocator, value, .{}),
    });
}

pub fn delete(self: *KeyValueList, name: []const u8, value: ?[]const u8) void {
    var i: usize = 0;
    while (i < self._entries.items.len) {
        const entry = self._entries.items[i];
        if (entry.name.eqlSlice(name)) {
            if (value == null or entry.value.eqlSlice(value.?)) {
                _ = self._entries.swapRemove(i);
                continue;
            }
        }
        i += 1;
    }
}

pub fn set(self: *KeyValueList, allocator: Allocator, name: []const u8, value: []const u8) !void {
    self.delete(name, null);
    try self.append(allocator, name, value);
}

pub fn len(self: *const KeyValueList) usize {
    return self._entries.items.len;
}

pub fn items(self: *const KeyValueList) []const Entry {
    return self._entries.items;
}

const URLEncodeMode = enum {
    form,
    query,
};

// URL-encode the key-value pairs.
// For UTF-8 charset, does standard percent encoding.
// For legacy charsets, converts to that encoding with NCR fallback for unmappable chars.
pub fn urlEncode(self: *const KeyValueList, comptime mode: URLEncodeMode, allocator_: ?Allocator, charset: []const u8, writer: *std.Io.Writer) !void {
    const entries = self._entries.items;
    if (entries.len == 0) {
        return;
    }

    try urlEncodeEntry(entries[0], mode, allocator_, charset, writer);
    for (entries[1..]) |entry| {
        try writer.writeByte('&');
        try urlEncodeEntry(entry, mode, allocator_, charset, writer);
    }
}

fn urlEncodeEntry(entry: Entry, comptime mode: URLEncodeMode, allocator_: ?Allocator, charset: []const u8, writer: *std.Io.Writer) !void {
    try urlEncodeValue(entry.name.str(), mode, allocator_, charset, writer);

    // for a form, for an empty value, we'll do "spice="
    // but for a query, we do "spice"
    if ((comptime mode == .query) and entry.value.len == 0) {
        return;
    }

    try writer.writeByte('=');
    try urlEncodeValue(entry.value.str(), mode, allocator_, charset, writer);
}

fn urlEncodeValue(value: []const u8, comptime mode: URLEncodeMode, allocator_: ?Allocator, charset: []const u8, writer: *std.Io.Writer) !void {
    // For UTF-8, do standard percent encoding
    if (std.mem.eql(u8, charset, "UTF-8")) {
        return urlEncodeValueUtf8(value, mode, writer);
    }

    const allocator = allocator_ orelse return urlEncodeValueUtf8(value, mode, writer);

    const enc_info = h5e.encoding_for_label(charset.ptr, charset.len);
    if (!enc_info.isValid()) {
        // Unknown encoding, fall back to UTF-8
        return urlEncodeValueUtf8(value, mode, writer);
    }

    // Calculate max buffer size for encoded output
    // encoding_max_encode_buffer_length doesn't account for NCR expansion,
    // so we need extra space. Each UTF-8 char (1-4 bytes) can become &#NNNNNNN; (10 bytes)
    const base_len = h5e.encoding_max_encode_buffer_length(enc_info.handle.?, value.len);
    if (base_len == 0) {
        return urlEncodeValueUtf8(value, mode, writer);
    }
    // For NCR encoding, each character could expand significantly
    // Use 4x the base buffer to be safe (NCRs are ~10 bytes for a 3-byte UTF-8 char)
    const max_encoded_len = base_len * 4;

    const encode_buf = try allocator.alloc(u8, max_encoded_len);
    defer allocator.free(encode_buf);

    // Encode UTF-8 to legacy encoding with NCR fallback
    const result = h5e.encoding_encode_with_ncr(
        enc_info.handle.?,
        value.ptr,
        value.len,
        encode_buf.ptr,
        encode_buf.len,
    );

    if (!result.isSuccess()) {
        // Encoding failed, fall back to UTF-8
        return urlEncodeValueUtf8(value, mode, writer);
    }

    // Percent-encode the result, preserving NCRs (& and ; must be encoded)
    const encoded_bytes = encode_buf[0..result.bytes_written];
    return urlEncodeValueLegacy(encoded_bytes, mode, writer);
}

/// Percent-encode a UTF-8 value - bytes >= 0x80 are percent-encoded directly.
fn urlEncodeValueUtf8(value: []const u8, comptime mode: URLEncodeMode, writer: *std.Io.Writer) !void {
    if (!urlEncodeShouldEscape(value, mode)) {
        return writer.writeAll(value);
    }

    for (value) |b| {
        if (urlEncodeUnreserved(b, mode)) {
            try writer.writeByte(b);
        } else if (b == ' ') {
            try writer.writeByte('+');
        } else {
            try writer.print("%{X:0>2}", .{b});
        }
    }
}

/// Percent-encode a legacy-encoded value - must also encode & and ; to preserve NCRs.
fn urlEncodeValueLegacy(value: []const u8, comptime mode: URLEncodeMode, writer: *std.Io.Writer) !void {
    for (value) |b| {
        if (urlEncodeUnreserved(b, mode)) {
            try writer.writeByte(b);
        } else if (b == ' ') {
            try writer.writeByte('+');
        } else if (b == '&' or b == ';') {
            // Must encode & and ; to preserve NCRs like &#12345;
            try writer.print("%{X:0>2}", .{b});
        } else {
            try writer.print("%{X:0>2}", .{b});
        }
    }
}

fn urlEncodeShouldEscape(value: []const u8, comptime mode: URLEncodeMode) bool {
    for (value) |b| {
        if (!urlEncodeUnreserved(b, mode)) {
            return true;
        }
    }
    return false;
}

fn urlEncodeUnreserved(b: u8, comptime mode: URLEncodeMode) bool {
    return switch (b) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '*' => true,
        '~' => comptime mode == .form,
        else => false,
    };
}

pub const Iterator = struct {
    index: u32 = 0,
    kv: *KeyValueList,

    // Why? Because whenever an Iterator is created, we need to increment the
    // RC of what it's iterating. And when the iterator is destroyed, we need
    // to decrement it. The generic iterator which will wrap this handles that
    // by using this "list" field. Most things that use the GenericIterator can
    // just set `list: *ZigCollection`, and everything will work. But KeyValueList
    // is being composed by various types, so it can't reference those types.
    // Using *anyopaque here is "dangerous", in that it requires the composer
    // to pass the right value, which normally would be itself (`*Self`), but
    // only because (as of now) everything that uses KeyValueList has no prototype
    list: *anyopaque,

    pub const Entry = struct { []const u8, []const u8 };

    pub fn next(self: *Iterator, _: *const Execution) ?Iterator.Entry {
        const index = self.index;
        const entries = self.kv._entries.items;
        if (index >= entries.len) {
            return null;
        }
        self.index = index + 1;

        const e = &entries[index];
        return .{ e.name.str(), e.value.str() };
    }
};

pub fn iterator(self: *const KeyValueList) Iterator {
    return .{ .list = self };
}

const GenericIterator = @import("collections/iterator.zig").Entry;
pub const KeyIterator = GenericIterator(Iterator, "0");
pub const ValueIterator = GenericIterator(Iterator, "1");
pub const EntryIterator = GenericIterator(Iterator, null);

const testing = @import("../../testing.zig");

test "KeyValueList: urlEncode UTF-8" {
    // Test that UTF-8 characters are properly percent-encoded (not double-encoded)
    const allocator = testing.arena_allocator;
    var list = KeyValueList.init();
    try list.append(allocator, "cafe", "café"); // é = C3 A9 in UTF-8

    var buf = std.Io.Writer.Allocating.init(allocator);
    try list.urlEncode(.form, null, "UTF-8", &buf.writer);

    // é (U+00E9) in UTF-8 is C3 A9, percent-encoded as %C3%A9
    try testing.expectString("cafe=caf%C3%A9", buf.written());
}

test "KeyValueList: urlEncode UTF-8 CJK" {
    // Test 3-byte UTF-8 characters (Chinese/Japanese)
    const allocator = testing.arena_allocator;
    var list = KeyValueList.init();
    try list.append(allocator, "text", "中文"); // 中 = E4 B8 AD, 文 = E6 96 87

    var buf = std.Io.Writer.Allocating.init(allocator);
    try list.urlEncode(.form, null, "UTF-8", &buf.writer);

    try testing.expectString("text=%E4%B8%AD%E6%96%87", buf.written());
}

test "KeyValueList: urlEncode GBK with NCR fallback" {
    // Test legacy encoding with NCR fallback for unmappable characters
    // U+3D34 (㴴) is NOT in GBK, should become &#15668;
    const allocator = testing.arena_allocator;
    var list = KeyValueList.init();
    try list.append(allocator, "q", "\u{3D34}");

    var buf = std.Io.Writer.Allocating.init(allocator);
    try list.urlEncode(.form, allocator, "GBK", &buf.writer);

    // &#15668; percent-encoded is %26%2315668%3B
    try testing.expectString("q=%26%2315668%3B", buf.written());
}

test "KeyValueList: urlEncode GBK mappable character" {
    // Test legacy encoding with a character that IS in GBK
    // U+4E2D (中) IS in GBK, should encode to GBK bytes D6 D0
    const allocator = testing.arena_allocator;
    var list = KeyValueList.init();
    try list.append(allocator, "q", "中");

    var buf = std.Io.Writer.Allocating.init(allocator);
    try list.urlEncode(.form, allocator, "GBK", &buf.writer);

    // GBK encoding of 中 is D6 D0, percent-encoded as %D6%D0
    try testing.expectString("q=%D6%D0", buf.written());
}

test "KeyValueList: urlEncode Big5 unmappable character" {
    // U+70A3 (炣) is NOT in Big5, should become &#28835;
    const allocator = testing.arena_allocator;
    var list = KeyValueList.init();
    try list.append(allocator, "q", "\u{70A3}");

    var buf = std.Io.Writer.Allocating.init(allocator);
    try list.urlEncode(.form, allocator, "Big5", &buf.writer);

    // &#28835; percent-encoded is %26%2328835%3B
    try testing.expectString("q=%26%2328835%3B", buf.written());
}
