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

const iterator = @import("../iterator/iterator.zig");
const SessionState = @import("../env.zig").SessionState;

pub const Interfaces = .{
    FormData,
    KeyIterable,
    ValueIterable,
    EntryIterable,
};

// We store the values in an ArrayList rather than a an
// StringArrayHashMap([]const u8)  because of the way the iterators (i.e., keys(),
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
pub const FormData = struct {
    entries: std.ArrayListUnmanaged(Entry),

    pub fn constructor() FormData {
        return .{
            .entries = .empty,
        };
    }

    pub fn _get(self: *const FormData, key: []const u8) ?[]const u8 {
        const result = self.find(key) orelse return null;
        return result.entry.value;
    }

    pub fn _getAll(self: *const FormData, key: []const u8, state: *SessionState) ![][]const u8 {
        const arena = state.call_arena;
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
    pub fn _set(self: *FormData, key: []const u8, value: []const u8, state: *SessionState) !void {
        self._delete(key);
        return self._append(key, value, state);
    }

    // TODO: value should be a string or blog
    // TODO: another optional parameter for the filename
    pub fn _append(self: *FormData, key: []const u8, value: []const u8, state: *SessionState) !void {
        const arena = state.arena;
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

const testing = @import("../../testing.zig");
test "FormData" {
    var runner = try testing.jsRunner(testing.tracking_allocator, .{});
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
}
