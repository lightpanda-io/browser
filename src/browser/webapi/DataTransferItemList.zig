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

const js = @import("../js/js.zig");
const Frame = @import("../Frame.zig");
const Page = @import("../Page.zig");

const DataTransfer = @import("DataTransfer.zig");
const DataTransferItem = @import("DataTransferItem.zig");

// https://html.spec.whatwg.org/multipage/dnd.html#the-datatransferitemlist-interface
//
// A live view over the owning DataTransfer's item list; all mutations are
// delegated to the DataTransfer so `.files` stays in sync.
const DataTransferItemList = @This();

_data_transfer: *DataTransfer,

pub fn acquireRef(self: *DataTransferItemList) void {
    self._data_transfer.acquireRef();
}

pub fn releaseRef(self: *DataTransferItemList, page: *Page) void {
    self._data_transfer.releaseRef(page);
}

pub fn getLength(self: *const DataTransferItemList) u32 {
    return @intCast(self._data_transfer._items.items.len);
}

pub fn item(self: *const DataTransferItemList, index: u32) ?*DataTransferItem {
    const items = self._data_transfer._items.items;
    if (index >= items.len) {
        return null;
    }
    return items[index];
}

// add(DOMString data, DOMString type) | add(File data)
// The overload is resolved by inspecting the first argument: a File yields a
// file item (the `type` argument is ignored), anything else a string item.
pub fn add(self: *DataTransferItemList, data: js.Value, type_: ?[]const u8, frame: *Frame) !?*DataTransferItem {
    return self._data_transfer.addItem(data, type_, frame);
}

pub fn remove(self: *DataTransferItemList, index: u32, frame: *Frame) !void {
    return self._data_transfer.removeItem(index, frame);
}

pub fn clear(self: *DataTransferItemList, frame: *Frame) !void {
    return self._data_transfer.clearItems(frame);
}

pub fn iterator(self: *DataTransferItemList, exec: *const js.Execution) !*Iterator {
    return Iterator.init(.{
        .index = 0,
        .list = self,
    }, exec);
}

const GenericIterator = @import("collections/iterator.zig").Entry;
pub const Iterator = GenericIterator(struct {
    index: u32,
    list: *DataTransferItemList,

    pub fn acquireRef(self: *@This()) void {
        self.list.acquireRef();
    }

    pub fn releaseRef(self: *@This(), page: *Page) void {
        self.list.releaseRef(page);
    }

    pub fn next(self: *@This(), _: *const js.Execution) ?*DataTransferItem {
        const index = self.index;
        const it = self.list.item(index) orelse return null;
        self.index = index + 1;
        return it;
    }
}, null);

pub const JsApi = struct {
    pub const bridge = js.Bridge(DataTransferItemList);

    pub const Meta = struct {
        pub const name = "DataTransferItemList";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const length = bridge.accessor(DataTransferItemList.getLength, null, .{});
    pub const add = bridge.function(DataTransferItemList.add, .{});
    pub const remove = bridge.function(DataTransferItemList.remove, .{});
    pub const clear = bridge.function(DataTransferItemList.clear, .{});
    pub const @"[]" = bridge.indexed(DataTransferItemList.item, getIndexes, .{ .null_as_undefined = true });
    pub const symbol_iterator = bridge.iterator(DataTransferItemList.iterator, .{});

    fn getIndexes(self: *DataTransferItemList, exec: *const js.Execution) !js.Array {
        const len = self.getLength();
        var arr = exec.js.local.?.newArray(len);
        for (0..len) |i| {
            _ = try arr.set(@intCast(i), i, .{});
        }
        return arr;
    }
};
