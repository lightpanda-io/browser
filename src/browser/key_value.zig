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

// Used by FormDAta and URLSearchParams.
//
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
pub const List = struct {
    entries: std.ArrayListUnmanaged(KeyValue) = .{},

    pub fn init(entries: std.ArrayListUnmanaged(KeyValue)) List {
        return .{ .entries = entries };
    }

    pub fn clone(self: *const List, arena: Allocator) !List {
        const entries = self.entries.items;

        var c: std.ArrayListUnmanaged(KeyValue) = .{};
        try c.ensureTotalCapacity(arena, entries.len);
        for (entries) |kv| {
            c.appendAssumeCapacity(kv);
        }

        return .{ .entries = c };
    }

    pub fn fromOwnedSlice(entries: []KeyValue) List {
        return .{
            .entries = std.ArrayListUnmanaged(KeyValue).fromOwnedSlice(entries),
        };
    }

    pub fn count(self: *const List) usize {
        return self.entries.items.len;
    }

    pub fn get(self: *const List, key: []const u8) ?[]const u8 {
        const result = self.find(key) orelse return null;
        return result.entry.value;
    }

    pub fn getAll(self: *const List, arena: Allocator, key: []const u8) ![]const []const u8 {
        var arr: std.ArrayListUnmanaged([]const u8) = .empty;
        for (self.entries.items) |entry| {
            if (std.mem.eql(u8, key, entry.key)) {
                try arr.append(arena, entry.value);
            }
        }
        return arr.items;
    }

    pub fn has(self: *const List, key: []const u8) bool {
        return self.find(key) != null;
    }

    pub fn set(self: *List, arena: Allocator, key: []const u8, value: []const u8) !void {
        self.delete(key);
        return self.append(arena, key, value);
    }

    pub fn append(self: *List, arena: Allocator, key: []const u8, value: []const u8) !void {
        return self.appendOwned(arena, try arena.dupe(u8, key), try arena.dupe(u8, value));
    }

    pub fn appendOwned(self: *List, arena: Allocator, key: []const u8, value: []const u8) !void {
        return self.entries.append(arena, .{
            .key = key,
            .value = value,
        });
    }

    pub fn appendOwnedAssumeCapacity(self: *List, key: []const u8, value: []const u8) void {
        self.entries.appendAssumeCapacity(.{
            .key = key,
            .value = value,
        });
    }

    pub fn delete(self: *List, key: []const u8) void {
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

    pub fn deleteKeyValue(self: *List, key: []const u8, value: []const u8) void {
        var i: usize = 0;
        while (i < self.entries.items.len) {
            const entry = self.entries.items[i];
            if (std.mem.eql(u8, key, entry.key) and std.mem.eql(u8, value, entry.value)) {
                _ = self.entries.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }

    pub fn keyIterator(self: *const List) KeyIterator {
        return .{ .entries = &self.entries };
    }

    pub fn valueIterator(self: *const List) ValueIterator {
        return .{ .entries = &self.entries };
    }

    pub fn entryIterator(self: *const List) EntryIterator {
        return .{ .entries = &self.entries };
    }

    pub fn ensureTotalCapacity(self: *List, arena: Allocator, len: usize) !void {
        return self.entries.ensureTotalCapacity(arena, len);
    }

    const FindResult = struct {
        index: usize,
        entry: KeyValue,
    };

    fn find(self: *const List, key: []const u8) ?FindResult {
        for (self.entries.items, 0..) |entry, i| {
            if (std.mem.eql(u8, key, entry.key)) {
                return .{ .index = i, .entry = entry };
            }
        }
        return null;
    }
};

pub const KeyValue = struct {
    key: []const u8,
    value: []const u8,
};

pub const KeyIterator = struct {
    index: usize = 0,
    entries: *const std.ArrayListUnmanaged(KeyValue),

    pub fn _next(self: *KeyIterator) ?[]const u8 {
        const entries = self.entries.items;

        const index = self.index;
        if (index == entries.len) {
            return null;
        }
        self.index += 1;
        return entries[index].key;
    }
};

pub const ValueIterator = struct {
    index: usize = 0,
    entries: *const std.ArrayListUnmanaged(KeyValue),

    pub fn _next(self: *ValueIterator) ?[]const u8 {
        const entries = self.entries.items;

        const index = self.index;
        if (index == entries.len) {
            return null;
        }
        self.index += 1;
        return entries[index].value;
    }
};

pub const EntryIterator = struct {
    index: usize = 0,
    entries: *const std.ArrayListUnmanaged(KeyValue),

    pub fn _next(self: *EntryIterator) ?struct { []const u8, []const u8 } {
        const entries = self.entries.items;

        const index = self.index;
        if (index == entries.len) {
            return null;
        }
        self.index += 1;
        const entry = entries[index];
        return .{ entry.key, entry.value };
    }
};

const URLEncodeMode = enum {
    form,
    query,
};

pub fn urlEncode(list: List, mode: URLEncodeMode, writer: anytype) !void {
    const entries = list.entries.items;
    if (entries.len == 0) {
        return;
    }

    try urlEncodeEntry(entries[0], mode, writer);
    for (entries[1..]) |entry| {
        try writer.writeByte('&');
        try urlEncodeEntry(entry, mode, writer);
    }
}

fn urlEncodeEntry(entry: KeyValue, mode: URLEncodeMode, writer: anytype) !void {
    try urlEncodeValue(entry.key, mode, writer);

    // for a form, for an empty value, we'll do "spice="
    // but for a query, we do "spice"
    if (mode == .query and entry.value.len == 0) {
        return;
    }

    try writer.writeByte('=');
    try urlEncodeValue(entry.value, mode, writer);
}

fn urlEncodeValue(value: []const u8, mode: URLEncodeMode, writer: anytype) !void {
    if (!urlEncodeShouldEscape(value, mode)) {
        return writer.writeAll(value);
    }

    for (value) |b| {
        if (urlEncodeUnreserved(b, mode)) {
            try writer.writeByte(b);
        } else if (b == ' ' and mode == .form) {
            // for form submission, space should be encoded as '+', not '%20'
            try writer.writeByte('+');
        } else {
            try writer.print("%{X:0>2}", .{b});
        }
    }
}

fn urlEncodeShouldEscape(value: []const u8, mode: URLEncodeMode) bool {
    for (value) |b| {
        if (!urlEncodeUnreserved(b, mode)) {
            return true;
        }
    }
    return false;
}

fn urlEncodeUnreserved(b: u8, mode: URLEncodeMode) bool {
    return switch (b) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_' => true,
        '~' => mode == .query,
        else => false,
    };
}
