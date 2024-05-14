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
const fspath = std.fs.path;

// FileLoader loads files content from the filesystem.
pub const FileLoader = struct {
    const FilesMap = std.StringHashMap([]const u8);

    files: FilesMap,
    path: []const u8,
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator, path: []const u8) FileLoader {
        const files = FilesMap.init(alloc);

        return FileLoader{
            .path = path,
            .alloc = alloc,
            .files = files,
        };
    }
    pub fn get(self: *FileLoader, name: []const u8) ![]const u8 {
        if (!self.files.contains(name)) {
            try self.load(name);
        }
        return self.files.get(name).?;
    }
    pub fn load(self: *FileLoader, name: []const u8) !void {
        const filename = try fspath.join(self.alloc, &.{ self.path, name });
        defer self.alloc.free(filename);
        var file = try std.fs.cwd().openFile(filename, .{});
        defer file.close();

        const file_size = try file.getEndPos();
        const content = try file.readToEndAlloc(self.alloc, file_size);
        const namedup = try self.alloc.dupe(u8, name);
        try self.files.put(namedup, content);
    }
    pub fn deinit(self: *FileLoader) void {
        var iter = self.files.iterator();
        while (iter.next()) |entry| {
            self.alloc.free(entry.key_ptr.*);
            self.alloc.free(entry.value_ptr.*);
        }
        self.files.deinit();
    }
};
