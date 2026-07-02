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
const Page = @import("../Page.zig");

const File = @import("File.zig");

pub fn registerTypes() []const type {
    return &.{
        FileList,
        FileList.Iterator,
    };
}

const FileList = @This();

_files: []*File = &.{},

pub fn getLength(self: *const FileList) u32 {
    return @intCast(self._files.len);
}

pub fn item(self: *const FileList, index: u32) ?*File {
    if (index >= self._files.len) {
        return null;
    }
    return self._files[index];
}

pub fn structuredSerialize(self: *const FileList, writer: *js.StructuredWriter) !void {
    writer.writeUint32(@intCast(self._files.len));
    for (self._files) |file| {
        try file.structuredSerialize(writer);
    }
}

pub fn structuredDeserialize(reader: *js.StructuredReader, page: *Page) !FileList {
    const count = try reader.readUint32();
    const files = try reader.local.ctx.arena.alloc(*File, count);
    for (files) |*file| {
        file.* = try File.structuredDeserialize(reader, page);
    }
    return .{ ._files = files };
}

pub fn iterator(self: *FileList, exec: *const js.Execution) !*Iterator {
    return Iterator.init(.{
        .index = 0,
        .list = self,
    }, exec);
}

const GenericIterator = @import("collections/iterator.zig").Entry;
pub const Iterator = GenericIterator(struct {
    index: u32,
    list: *FileList,

    pub fn next(self: *@This(), _: *const js.Execution) ?*File {
        const index = self.index;
        const file = self.list.item(index) orelse return null;
        self.index = index + 1;
        return file;
    }
}, null);

pub const JsApi = struct {
    pub const bridge = js.Bridge(FileList);

    pub const Meta = struct {
        pub const name = "FileList";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const length = bridge.accessor(FileList.getLength, null, .{});
    pub const item = bridge.function(FileList.item, .{});
    pub const @"[]" = bridge.indexed(FileList.item, getIndexes, .{ .null_as_undefined = true });
    pub const symbol_iterator = bridge.iterator(FileList.iterator, .{});

    fn getIndexes(self: *FileList, exec: *const js.Execution) !js.Array {
        const len = self.getLength();
        var arr = exec.js.local.?.newArray(len);
        for (0..len) |i| {
            _ = try arr.set(@intCast(i), i, .{});
        }
        return arr;
    }
};
