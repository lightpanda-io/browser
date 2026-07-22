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

const js = @import("../../js/js.zig");
const Page = @import("../../Page.zig");
const GenericIterator = @import("iterator.zig").Entry;

pub const KeyIterator = GenericIterator(Iterator, "0");
pub const ValueIterator = GenericIterator(Iterator, "1");
pub const EntryIterator = GenericIterator(Iterator, null);

const Execution = js.Execution;
const Allocator = std.mem.Allocator;

// not registered in collections.zig, because this is one of the rare
// collections that's also available in Worker
pub fn registerTypes() []const type {
    return &.{
        DOMStringList,
        DOMStringList.KeyIterator,
        DOMStringList.ValueIterator,
        DOMStringList.EntryIterator,
    };
}

pub const DOMStringList = @This();

_rc: lp.RC = .{},
_arena: Allocator,
_items: []const []const u8,

pub fn acquireRef(self: *DOMStringList) void {
    self._rc.acquire();
}

pub fn deinit(self: *DOMStringList, page: *Page) void {
    page.releaseArena(self._arena);
}

pub fn releaseRef(self: *DOMStringList, page: *Page) void {
    self._rc.release(self, page);
}

pub fn length(self: *const DOMStringList) u32 {
    return @intCast(self._items.len);
}

pub fn item(self: *const DOMStringList, index: usize) ?[]const u8 {
    if (index >= self._items.len) {
        return null;
    }
    return self._items[index];
}

pub fn contains(self: *const DOMStringList, string: []const u8) bool {
    for (self._items) |entry| {
        if (std.mem.eql(u8, entry, string)) {
            return true;
        }
    }
    return false;
}

pub fn keys(self: *const DOMStringList, exec: *Execution) !*KeyIterator {
    return .init(.{ .items = self._items }, exec);
}

pub fn values(self: *const DOMStringList, exec: *Execution) !*ValueIterator {
    return .init(.{ .items = self._items }, exec);
}

pub fn entries(self: *const DOMStringList, exec: *Execution) !*EntryIterator {
    return .init(.{ .items = self._items }, exec);
}

// The iterator borrows the (page-arena) slice rather than the DOMStringList, so
// it's safe regardless of the wrapper's lifetime.
const Iterator = struct {
    index: u32 = 0,
    items: []const []const u8,

    const Entry = struct { u32, []const u8 };

    pub fn next(self: *Iterator, _: *Execution) ?Entry {
        const index = self.index;
        if (index >= self.items.len) {
            return null;
        }
        self.index = index + 1;
        return .{ index, self.items[index] };
    }
};

pub const JsApi = struct {
    pub const bridge = js.Bridge(DOMStringList);

    pub const Meta = struct {
        pub const name = "DOMStringList";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const length = bridge.accessor(DOMStringList.length, null, .{});
    pub const contains = bridge.function(DOMStringList.contains, .{});
    pub const item = bridge.function(_item, .{});
    fn _item(self: *const DOMStringList, index: i32) ?[]const u8 {
        if (index < 0) {
            return null;
        }
        return self.item(@intCast(index));
    }

    pub const keys = bridge.function(DOMStringList.keys, .{});
    pub const values = bridge.function(DOMStringList.values, .{});
    pub const entries = bridge.function(DOMStringList.entries, .{});
    pub const symbol_iterator = bridge.iterator(DOMStringList.values, .{});
    pub const @"[]" = bridge.indexed(DOMStringList.item, null, .{ .null_as_undefined = true });
};
