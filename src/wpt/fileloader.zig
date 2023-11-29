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
