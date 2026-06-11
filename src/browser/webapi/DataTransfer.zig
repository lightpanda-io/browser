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
const Frame = @import("../Frame.zig");
const Page = @import("../Page.zig");

const File = @import("File.zig");
const FileList = @import("FileList.zig");
const DataTransferItem = @import("DataTransferItem.zig");
const DataTransferItemList = @import("DataTransferItemList.zig");

const Allocator = std.mem.Allocator;

// https://html.spec.whatwg.org/multipage/dnd.html#the-datatransfer-interface
//
// The canonical drag-data-store: one ordered list of items (string- or
// file-kind). `.items` is a live DataTransferItemList view; `.files` is a
// FileList rebuilt from the file-kind items so the two stay in sync. Per v1
// scope the store is always read/write (no event-phase mode gating).
const DataTransfer = @This();

pub fn registerTypes() []const type {
    return &.{
        DataTransfer,
        DataTransferItem,
        DataTransferItemList,
        DataTransferItemList.Iterator,
    };
}

_arena: Allocator,
// Refcounted so the GC weak-finalizer (or page teardown) releases the pooled
// arena exactly once; mirrors Blob's lifecycle.
_rc: lp.RC(u32) = .{},
_items: std.ArrayList(*DataTransferItem) = .{},
_item_list: *DataTransferItemList,
// FileList lives on the factory slab and is frame-tracked, so each File ref it
// holds is released at frame teardown (same path as `<input type=file>`).
_files: *FileList,
_drop_effect: []const u8 = "none",
_effect_allowed: []const u8 = "uninitialized",

pub fn init(frame: *Frame) !*DataTransfer {
    const arena = try frame.getArena(.medium, "DataTransfer");
    errdefer frame.releaseArena(arena);

    const fl = try frame._factory.create(FileList{});
    try frame.trackFileList(fl);

    const self = try arena.create(DataTransfer);
    const list = try arena.create(DataTransferItemList);
    self.* = .{
        ._arena = arena,
        ._item_list = list,
        ._files = fl,
    };
    list.* = .{ ._data_transfer = self };
    return self;
}

pub fn deinit(self: *DataTransfer, page: *Page) void {
    page.releaseArena(self._arena);
}

pub fn acquireRef(self: *DataTransfer) void {
    self._rc.acquire();
}

pub fn releaseRef(self: *DataTransfer, page: *Page) void {
    self._rc.release(self, page);
}

// https://html.spec.whatwg.org/multipage/dnd.html#dom-datatransfer-getdata
// "text" and "url" are shorthands the spec maps onto MIME types.
fn normalizeFormat(arena: Allocator, format: []const u8) ![]const u8 {
    if (std.ascii.eqlIgnoreCase(format, "text")) {
        return "text/plain";
    }
    if (std.ascii.eqlIgnoreCase(format, "url")) {
        return "text/uri-list";
    }
    return std.ascii.allocLowerString(arena, format);
}

pub fn getData(self: *const DataTransfer, format: []const u8, frame: *Frame) ![]const u8 {
    const norm = try normalizeFormat(frame.call_arena, format);
    for (self._items.items) |it| {
        if (it._kind == .string and std.mem.eql(u8, it._type, norm)) {
            return it._payload.string;
        }
    }
    return "";
}

pub fn setData(self: *DataTransfer, format: []const u8, data: []const u8) !void {
    const norm = try normalizeFormat(self._arena, format);
    const owned_data = try self._arena.dupe(u8, data);
    for (self._items.items) |it| {
        if (it._kind == .string and std.mem.eql(u8, it._type, norm)) {
            it._payload = .{ .string = owned_data };
            return;
        }
    }
    const it = try self._arena.create(DataTransferItem);
    it.* = .{ ._data_transfer = self, ._kind = .string, ._type = norm, ._payload = .{ .string = owned_data } };
    try self._items.append(self._arena, it);
}

pub fn clearData(self: *DataTransfer, format_: ?[]const u8, frame: *Frame) !void {
    if (format_) |format| {
        const norm = try normalizeFormat(frame.call_arena, format);
        var i: usize = 0;
        while (i < self._items.items.len) {
            const it = self._items.items[i];
            if (it._kind == .string and std.mem.eql(u8, it._type, norm)) {
                _ = self._items.orderedRemove(i);
            } else {
                i += 1;
            }
        }
        return;
    }
    // No format: remove every string item, leave file items in place.
    var i: usize = 0;
    while (i < self._items.items.len) {
        if (self._items.items[i]._kind == .string) {
            _ = self._items.orderedRemove(i);
        } else {
            i += 1;
        }
    }
}

// --- DataTransferItemList delegation ---

// add(File) -> file item ; add(DOMString, DOMString) -> string item.
pub fn addItem(self: *DataTransfer, data: js.Value, type_: ?[]const u8, frame: *Frame) !?*DataTransferItem {
    if (data.toZig(*File)) |file| {
        return try self.addFileItem(file, frame);
    } else |_| {}

    const owned_data = try data.toStringSliceWithAlloc(self._arena);
    const norm = try normalizeFormat(self._arena, type_ orelse "");
    const it = try self._arena.create(DataTransferItem);
    it.* = .{ ._data_transfer = self, ._kind = .string, ._type = norm, ._payload = .{ .string = owned_data } };
    try self._items.append(self._arena, it);
    return it;
}

fn addFileItem(self: *DataTransfer, file: *File, frame: *Frame) !*DataTransferItem {
    file._proto.acquireRef();
    const it = try self._arena.create(DataTransferItem);
    it.* = .{ ._data_transfer = self, ._kind = .file, ._type = file._proto.getType(), ._payload = .{ .file = file } };
    try self._items.append(self._arena, it);
    try self.rebuildFiles(frame);
    return it;
}

pub fn removeItem(self: *DataTransfer, index: u32, frame: *Frame) !void {
    if (index >= self._items.items.len) {
        return;
    }
    const it = self._items.orderedRemove(index);
    if (it._kind == .file) {
        it._payload.file._proto.releaseRef(frame._page);
        try self.rebuildFiles(frame);
    }
}

pub fn clearItems(self: *DataTransfer, frame: *Frame) !void {
    for (self._items.items) |it| {
        if (it._kind == .file) {
            it._payload.file._proto.releaseRef(frame._page);
        }
    }
    self._items.clearRetainingCapacity();
    try self.rebuildFiles(frame);
}

// Rebuild the FileList slice from the current file-kind items, in order.
fn rebuildFiles(self: *DataTransfer, frame: *Frame) !void {
    var files: std.ArrayList(*File) = .{};
    for (self._items.items) |it| {
        if (it._kind == .file) {
            try files.append(frame.arena, it._payload.file);
        }
    }
    self._files._files = try files.toOwnedSlice(frame.arena);
}

// --- accessors ---

pub fn getFiles(self: *DataTransfer) *FileList {
    return self._files;
}

pub fn getItems(self: *DataTransfer) *DataTransferItemList {
    return self._item_list;
}

pub fn getTypes(self: *DataTransfer, frame: *Frame) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .{};
    var has_files = false;
    for (self._items.items) |it| {
        switch (it._kind) {
            .string => try out.append(frame.call_arena, it._type),
            .file => has_files = true,
        }
    }
    if (has_files) {
        try out.append(frame.call_arena, "Files");
    }
    return out.toOwnedSlice(frame.call_arena);
}

pub fn getDropEffect(self: *const DataTransfer) []const u8 {
    return self._drop_effect;
}

pub fn setDropEffect(self: *DataTransfer, value: []const u8) !void {
    inline for (.{ "none", "copy", "link", "move" }) |valid| {
        if (std.mem.eql(u8, value, valid)) {
            self._drop_effect = valid;
            return;
        }
    }
}

pub fn getEffectAllowed(self: *const DataTransfer) []const u8 {
    return self._effect_allowed;
}

pub fn setEffectAllowed(self: *DataTransfer, value: []const u8) !void {
    inline for (.{ "none", "copy", "copyLink", "copyMove", "link", "linkMove", "move", "all", "uninitialized" }) |valid| {
        if (std.mem.eql(u8, value, valid)) {
            self._effect_allowed = valid;
            return;
        }
    }
}

// https://html.spec.whatwg.org/multipage/dnd.html#dom-datatransfer-setdragimage
// No-op: Lightpanda has no rendered drag feedback.
pub fn setDragImage(_: *DataTransfer, _: js.Value, _: i32, _: i32) void {}

pub const JsApi = struct {
    pub const bridge = js.Bridge(DataTransfer);

    pub const Meta = struct {
        pub const name = "DataTransfer";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(DataTransfer.init, .{});
    pub const dropEffect = bridge.accessor(DataTransfer.getDropEffect, DataTransfer.setDropEffect, .{});
    pub const effectAllowed = bridge.accessor(DataTransfer.getEffectAllowed, DataTransfer.setEffectAllowed, .{});
    pub const files = bridge.accessor(DataTransfer.getFiles, null, .{});
    pub const items = bridge.accessor(DataTransfer.getItems, null, .{});
    pub const types = bridge.accessor(DataTransfer.getTypes, null, .{});
    pub const getData = bridge.function(DataTransfer.getData, .{});
    pub const setData = bridge.function(DataTransfer.setData, .{});
    pub const clearData = bridge.function(DataTransfer.clearData, .{});
    pub const setDragImage = bridge.function(DataTransfer.setDragImage, .{});
};

const testing = @import("../../testing.zig");
test "WebApi: DataTransfer" {
    try testing.htmlRunner("data_transfer.html", .{});
}
