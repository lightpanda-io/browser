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

const js = @import("../js/js.zig");
const Page = @import("../Page.zig");
const Frame = @import("../Frame.zig");

const log = lp.log;
const String = lp.String;
const Execution = js.Execution;

const CustomStateSet = @This();

pub fn registerTypes() []const type {
    return &.{
        CustomStateSet,
        ValueIterator,
        EntryIterator,
    };
}

_size: u32 = 0,
_items: std.ArrayList(?String) = .empty,
_iterators: u32 = 0, // live iterators, while != 0, tomestones must stay put

fn has(self: *const CustomStateSet, value: String) bool {
    return self.indexOf(value) != null;
}

fn getSize(self: *const CustomStateSet) u32 {
    return self._size;
}

fn add(self: *CustomStateSet, value: String, frame: *Frame) !*CustomStateSet {
    if (self.indexOf(value) != null) {
        return self;
    }
    if (self._iterators == 0 and self._items.items.len > self._size) {
        self.compact();
    }
    try self._items.append(frame.page_arena, try frame.dupeSSO(value.str()));
    self._size += 1;
    return self;
}

fn delete(self: *CustomStateSet, value: String) bool {
    const index = self.indexOf(value) orelse return false;
    self._items.items[index] = null;
    self._size -= 1;
    return true;
}

fn clear(self: *CustomStateSet) void {
    @memset(self._items.items, null);
    self._size = 0;
}

fn indexOf(self: *const CustomStateSet, value: String) ?usize {
    for (self._items.items, 0..) |item_, i| {
        const item = item_ orelse continue;
        if (item.eql(value)) {
            return i;
        }
    }
    return null;
}

fn compact(self: *CustomStateSet) void {
    var len: usize = 0;
    for (self._items.items) |item| {
        if (item != null) {
            self._items.items[len] = item;
            len += 1;
        }
    }
    self._items.shrinkRetainingCapacity(len);
}

fn values(self: *CustomStateSet, exec: *const Execution) !*ValueIterator {
    return ValueIterator.init(.{ .set = self }, exec);
}

fn entries(self: *CustomStateSet, exec: *const Execution) !*EntryIterator {
    return EntryIterator.init(.{ .set = self }, exec);
}

fn forEach(self: *CustomStateSet, cb_: js.Function, js_this_: ?js.Object, exec: *const Execution) !void {
    const cb = if (js_this_) |js_this| try cb_.withThis(js_this) else cb_;

    var it = Iterator{ .set = self };
    it.acquireRef();
    defer it.releaseRef(exec.page);

    while (it.next(exec)) |entry| {
        var caught: js.TryCatch.Caught = .{};
        cb.tryCall(void, .{ entry.@"0", entry.@"1", self }, &caught) catch {
            log.debug(.js, "forEach callback", .{ .caught = caught, .source = "CustomStateSet" });
        };
    }
}

pub const Iterator = struct {
    index: u32 = 0,
    done: bool = false,
    set: *CustomStateSet,

    pub const Entry = struct { []const u8, []const u8 };

    pub fn next(self: *Iterator, _: *const Execution) ?Iterator.Entry {
        if (self.done) {
            return null;
        }
        const items = self.set._items.items;
        while (self.index < items.len) {
            const index = self.index;
            self.index = index + 1;
            // by pointer: an SSO String's bytes may be inline
            if (items[index]) |*value| {
                return .{ value.str(), value.str() };
            }
        }
        // Like a Set iterator, once exhausted it stays exhausted.
        self.done = true;
        return null;
    }

    pub fn acquireRef(self: *Iterator) void {
        self.set._iterators += 1;
    }

    pub fn releaseRef(self: *Iterator, _: *Page) void {
        self.set._iterators -= 1;
    }
};

const GenericIterator = @import("collections/iterator.zig").Entry;
pub const ValueIterator = GenericIterator(Iterator, "0");
pub const EntryIterator = GenericIterator(Iterator, null);

pub const JsApi = struct {
    pub const bridge = js.Bridge(CustomStateSet);

    pub const Meta = struct {
        pub const name = "CustomStateSet";
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const size = bridge.accessor(CustomStateSet.getSize, null, .{});
    pub const has = bridge.function(CustomStateSet.has, .{});
    pub const add = bridge.function(CustomStateSet.add, .{});
    pub const delete = bridge.function(CustomStateSet.delete, .{});
    pub const clear = bridge.function(CustomStateSet.clear, .{});
    pub const keys = bridge.function(CustomStateSet.values, .{});
    pub const values = bridge.function(CustomStateSet.values, .{});
    pub const entries = bridge.function(CustomStateSet.entries, .{});
    pub const forEach = bridge.function(CustomStateSet.forEach, .{});
    pub const symbol_iterator = bridge.iterator(CustomStateSet.values, .{});
};
