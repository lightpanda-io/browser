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
const lp = @import("lightpanda");

const properties = @import("properties.zig");

const String = lp.String;
const Allocator = std.mem.Allocator;

const DeclarationBlock = @This();

_len: u16 = 0,
_cap: u16 = 0,
_entries: [*]Entry = @constCast(&empty_entries),

const empty_entries: [0]Entry = .{};

pub fn deinit(self: *DeclarationBlock, allocator: Allocator) void {
    self.clear(allocator);
    allocator.free(self._entries[0..self._cap]);
    self.* = .{};
}

pub fn entries(self: *const DeclarationBlock) []Entry {
    return self._entries[0..self._len];
}

pub fn length(self: *const DeclarationBlock) u16 {
    return self._len;
}

pub fn find(self: *const DeclarationBlock, id: properties.Id) ?*Entry {
    const index = self.findIndex(id) orelse return null;
    return &self._entries[index];
}

pub fn findIndex(self: *const DeclarationBlock, id: properties.Id) ?usize {
    for (self.entries(), 0..) |*entry, i| {
        if (entry._id == id) {
            return i;
        }
    }
    return null;
}

pub fn append(self: *DeclarationBlock, allocator: Allocator, id: properties.Id, value: []const u8, important: bool) !void {
    if (comptime lp.IS_DEBUG) {
        // the caller updates an existing declaration instead
        std.debug.assert(self.findIndex(id) == null);
    }
    if (self._len == self._cap) {
        if (self._cap > std.math.maxInt(u16) - 4) {
            return error.OutOfMemory;
        }
        // A parsed block is trimmed once done, so most take one allocation
        // here. Additions from JS are rare and small.
        try self.setCapacity(allocator, self._cap + 4);
    }
    var entry: Entry = .{
        ._id = id,
        ._value_ptr = undefined,
        ._value_len = 0,
        ._important = important,
        ._value_owned = false,
    };
    try entry.setValue(allocator, value);
    self._entries[self._len] = entry;
    self._len += 1;
}

pub fn removeAt(self: *DeclarationBlock, allocator: Allocator, index: usize) void {
    const all = self.entries();
    all[index].freeValue(allocator);
    // keep declaration order
    std.mem.copyForwards(Entry, all[index..], all[index + 1 ..]);
    self._len -= 1;
}

pub fn clear(self: *DeclarationBlock, allocator: Allocator) void {
    for (self.entries()) |*entry| {
        entry.freeValue(allocator);
    }
    // Keeps the capacity: a new set of declarations usually follows
    self._len = 0;
}

/// A parsed block rarely changes after. Gives back the spare room.
pub fn trim(self: *DeclarationBlock, allocator: Allocator) !void {
    if (self._cap > self._len) {
        try self.setCapacity(allocator, self._len);
    }
}

fn setCapacity(self: *DeclarationBlock, allocator: Allocator, cap: u16) !void {
    const resized = try allocator.realloc(self._entries[0..self._cap], cap);
    self._entries = resized.ptr;
    self._cap = cap;
}

pub fn iterator(self: *const DeclarationBlock, custom_names: *const properties.CustomNames) Iterator {
    return .{ .entries = self.entries(), .custom_names = custom_names };
}

/// The declarations in declared order. Their strings belong to the block: any
/// write to it can free them.
pub const Iterator = struct {
    pub const Declaration = struct {
        id: properties.Id,
        name: []const u8,
        value: []const u8,
        important: bool,
    };

    entries: []const Entry,
    custom_names: *const properties.CustomNames,
    index: usize = 0,

    pub fn next(self: *Iterator) ?Declaration {
        if (self.index == self.entries.len) {
            return null;
        }
        const entry = &self.entries[self.index];
        self.index += 1;
        return .{
            .id = entry._id,
            .name = entry.name(self.custom_names),
            .value = entry.value(),
            .important = entry._important,
        };
    }
};

// One declaration in 16 bytes. A known property's name is the table's, a
// custom one's the page's (both by id). A common value points at a static copy
// (see properties.internValue).
pub const Entry = struct {
    _value_ptr: [*]const u8,
    _value_len: u32,
    _id: properties.Id,
    _important: bool,
    _value_owned: bool, // False when the value is static: nothing to free.

    comptime {
        std.debug.assert(@sizeOf(Entry) == 16);
    }

    pub fn name(self: *const Entry, custom_names: *const properties.CustomNames) []const u8 {
        return properties.knownName(self._id) orelse custom_names.nameOf(self._id);
    }

    pub fn value(self: *const Entry) []const u8 {
        return self._value_ptr[0..self._value_len];
    }

    // The new value is stored before the old one is freed, so `new_value` may
    // alias it, and a failed allocation leaves the entry as it was.
    pub fn setValue(self: *Entry, allocator: Allocator, new_value: []const u8) !void {
        if (new_value.len > std.math.maxInt(u32)) {
            return error.StringTooLarge;
        }
        const static = properties.internValue(new_value) orelse String.intern(new_value);
        const stored = static orelse try allocator.dupe(u8, new_value);
        self.freeValue(allocator);
        self._value_ptr = stored.ptr;
        self._value_len = @intCast(stored.len);
        self._value_owned = static == null;
    }

    fn freeValue(self: *const Entry, allocator: Allocator) void {
        if (self._value_owned) {
            allocator.free(self.value());
        }
    }
};
