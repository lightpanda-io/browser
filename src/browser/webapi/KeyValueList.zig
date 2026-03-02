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

const String = @import("../../string.zig").String;

const js = @import("../js/js.zig");
const Page = @import("../Page.zig");

const Allocator = std.mem.Allocator;

pub fn registerTypes() []const type {
    return &.{
        KeyIterator,
        ValueIterator,
        EntryIterator,
    };
}

const Normalizer = *const fn ([]const u8, *Page) []const u8;

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

pub fn fromJsObject(arena: Allocator, js_obj: js.Object, comptime normalizer: ?Normalizer, page: *Page) !KeyValueList {
    var it = try js_obj.nameIterator();
    var list = KeyValueList.init();
    try list.ensureTotalCapacity(arena, it.count);

    while (try it.next()) |name| {
        const js_value = try js_obj.get(name);
        const normalized = if (comptime normalizer) |n| n(name, page) else name;

        list._entries.appendAssumeCapacity(.{
            .name = try String.init(arena, normalized, .{}),
            .value = try js_value.toSSOWithAlloc(arena),
        });
    }

    return list;
}

pub fn fromArray(arena: Allocator, kvs: []const [2][]const u8, comptime normalizer: ?Normalizer, page: *Page) !KeyValueList {
    var list = KeyValueList.init();
    try list.ensureTotalCapacity(arena, kvs.len);

    for (kvs) |pair| {
        const normalized = if (comptime normalizer) |n| n(pair[0], page) else pair[0];

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

pub fn getAll(self: *const KeyValueList, name: []const u8, page: *Page) ![]const []const u8 {
    const arena = page.call_arena;
    var arr: std.ArrayList([]const u8) = .empty;
    for (self._entries.items) |*entry| {
        if (entry.name.eqlSlice(name)) {
            try arr.append(arena, entry.value.str());
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

pub fn urlEncode(self: *const KeyValueList, comptime mode: URLEncodeMode, writer: *std.Io.Writer) !void {
    const entries = self._entries.items;
    if (entries.len == 0) {
        return;
    }

    try urlEncodeEntry(entries[0], mode, writer);
    for (entries[1..]) |entry| {
        try writer.writeByte('&');
        try urlEncodeEntry(entry, mode, writer);
    }
}

fn urlEncodeEntry(entry: Entry, comptime mode: URLEncodeMode, writer: *std.Io.Writer) !void {
    try urlEncodeValue(entry.name.str(), mode, writer);

    // for a form, for an empty value, we'll do "spice="
    // but for a query, we do "spice"
    if ((comptime mode == .query) and entry.value.len == 0) {
        return;
    }

    try writer.writeByte('=');
    try urlEncodeValue(entry.value.str(), mode, writer);
}

fn urlEncodeValue(value: []const u8, comptime mode: URLEncodeMode, writer: *std.Io.Writer) !void {
    if (!urlEncodeShouldEscape(value, mode)) {
        return writer.writeAll(value);
    }

    for (value) |b| {
        if (urlEncodeUnreserved(b, mode)) {
            try writer.writeByte(b);
        } else if (b == ' ') {
            try writer.writeByte('+');
        } else if (b >= 0x80) {
            // Double-encode: treat byte as Latin-1 code point, encode to UTF-8, then percent-encode
            // For bytes 0x80-0xFF (U+0080 to U+00FF), UTF-8 encoding is 2 bytes:
            // [0xC0 | (b >> 6), 0x80 | (b & 0x3F)]
            const byte1 = 0xC0 | (b >> 6);
            const byte2 = 0x80 | (b & 0x3F);
            try writer.print("%{X:0>2}%{X:0>2}", .{ byte1, byte2 });
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
    // only because (as of now) everyting that uses KeyValueList has no prototype
    list: *anyopaque,

    pub const Entry = struct { []const u8, []const u8 };

    pub fn next(self: *Iterator, _: *const Page) ?Iterator.Entry {
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
