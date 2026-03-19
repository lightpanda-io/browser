// Copyright (C) 2023-2026  Lightpanda (Selecy SAS)
//
// Francis Bouvier <francis@lightpanda.io>
// Pierre Tachoire <pierre@lightpanda.io>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or (at your
// option) any later version.
//
// This program is distributed in the hope that it will be useful, but WITHOUT
// ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
// FITNESS FOR A PARTICULAR PURPOSE. See the GNU Affero General Public License
// for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.

const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;

fn storageResolveProfileDir(allocator: Allocator, override_path: ?[]const u8) ?[]const u8 {
    if (override_path) |path| {
        return copyAndPrepareDir(allocator, path) catch return null;
    }

    if (builtin.is_test) {
        return allocator.dupe(u8, "/tmp") catch unreachable;
    }

    if (!supportsProfileDirFilesystem()) {
        return null;
    }

    const app_dir_path = std.fs.getAppDataDir(allocator, "lightpanda") catch return null;

    std.fs.cwd().makePath(app_dir_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => {
            allocator.free(app_dir_path);
            return null;
        },
    };
    return app_dir_path;
}

fn copyAndPrepareDir(allocator: Allocator, path: []const u8) ![]const u8 {
    const owned = try allocator.dupe(u8, path);
    errdefer allocator.free(owned);
    if (supportsProfileDirFilesystem()) {
        std.fs.cwd().makePath(owned) catch |err| switch (err) {
            error.PathAlreadyExists => return owned,
            else => return err,
        };
    }
    return owned;
}

fn resolveProfileFile(allocator: Allocator, profile_root: ?[]const u8, name: []const u8) ?[]u8 {
    const root = profile_root orelse return null;
    return std.fs.path.join(allocator, &.{ root, name }) catch null;
}

fn storageResolveProfileSubdir(allocator: Allocator, profile_root: ?[]const u8, subdir: []const u8) ?[]u8 {
    const path = resolveProfileFile(allocator, profile_root, subdir) orelse return null;
    if (!supportsProfileDirFilesystem()) {
        return path;
    }

    std.fs.cwd().makePath(path) catch |err| switch (err) {
        error.PathAlreadyExists => return path,
        else => {
            allocator.free(path);
            return null;
        },
    };
    return path;
}

fn supportsProfileDirFilesystem() bool {
    return switch (builtin.os.tag) {
        .windows, .linux, .macos, .ios, .tvos, .watchos, .visionos, .freebsd, .netbsd, .openbsd, .dragonfly, .haiku => true,
        else => false,
    };
}

pub const Storage = struct {
    mode: Mode = .hosted,
    files: std.ArrayListUnmanaged(FileEntry) = .{},

    pub const Mode = enum {
        hosted,
        mock,
    };

    pub const FileEntry = struct {
        path: []u8,
        data: []u8,

        fn deinit(self: *FileEntry, allocator: Allocator) void {
            allocator.free(self.path);
            allocator.free(self.data);
            self.* = undefined;
        }
    };

    pub fn hosted() Storage {
        return .{ .mode = .hosted };
    }

    pub fn mock() Storage {
        return .{ .mode = .mock };
    }

    pub fn deinit(self: *Storage, allocator: Allocator) void {
        if (self.mode == .mock) {
            for (self.files.items) |*entry| {
                entry.deinit(allocator);
            }
        }
        self.files.deinit(allocator);
        self.* = undefined;
    }

    pub fn resolveProfileDir(self: *const Storage, allocator: Allocator, override_path: ?[]const u8) ?[]const u8 {
        return switch (self.mode) {
            .hosted => storageResolveProfileDir(allocator, override_path),
            .mock => {
                const path = override_path orelse "/mock/profile";
                return allocator.dupe(u8, path) catch null;
            },
        };
    }

    pub fn resolveProfileFile(self: *const Storage, allocator: Allocator, profile_root: ?[]const u8, name: []const u8) ?[]const u8 {
        _ = self;
        const root = profile_root orelse return null;
        return std.fs.path.join(allocator, &.{ root, name }) catch null;
    }

    pub fn resolveProfileSubdir(self: *const Storage, allocator: Allocator, profile_root: ?[]const u8, subdir: []const u8) ?[]const u8 {
        return switch (self.mode) {
            .hosted => storageResolveProfileSubdir(allocator, profile_root, subdir),
            .mock => {
                const root = profile_root orelse return null;
                return std.fs.path.join(allocator, &.{ root, subdir }) catch null;
            },
        };
    }

    pub fn writeFile(self: *Storage, allocator: Allocator, path: []const u8, data: []const u8) !void {
        switch (self.mode) {
            .hosted => {
                var file = if (std.fs.path.isAbsolute(path))
                    try std.fs.createFileAbsolute(path, .{ .truncate = true })
                else
                    try std.fs.cwd().createFile(path, .{ .truncate = true });
                defer file.close();
                try file.writeAll(data);
            },
            .mock => {
                if (self.indexOf(path)) |index| {
                    var entry = &self.files.items[index];
                    const data_copy = try allocator.dupe(u8, data);
                    allocator.free(entry.data);
                    entry.data = data_copy;
                    return;
                }

                const path_copy = try allocator.dupe(u8, path);
                errdefer allocator.free(path_copy);
                const data_copy = try allocator.dupe(u8, data);
                errdefer allocator.free(data_copy);
                try self.files.append(allocator, .{
                    .path = path_copy,
                    .data = data_copy,
                });
            },
        }
    }

    pub fn readFile(self: *Storage, allocator: Allocator, path: []const u8) ![]u8 {
        switch (self.mode) {
            .hosted => {
                var file = if (std.fs.path.isAbsolute(path))
                    try std.fs.openFileAbsolute(path, .{})
                else
                    try std.fs.cwd().openFile(path, .{});
                defer file.close();
                return try file.readToEndAlloc(allocator, 1024 * 1024);
            },
            .mock => {
                const index = self.indexOf(path) orelse return error.FileNotFound;
                return allocator.dupe(u8, self.files.items[index].data);
            },
        }
    }

    pub fn deleteFile(self: *Storage, allocator: Allocator, path: []const u8) !void {
        switch (self.mode) {
            .hosted => {
                if (std.fs.path.isAbsolute(path)) {
                    try std.fs.deleteFileAbsolute(path);
                } else {
                    try std.fs.cwd().deleteFile(path);
                }
            },
            .mock => {
                const index = self.indexOf(path) orelse return error.FileNotFound;
                var entry = self.files.swapRemove(index);
                entry.deinit(allocator);
            },
        }
    }

    pub fn clear(self: *Storage, allocator: Allocator) void {
        if (self.mode == .mock) {
            while (self.files.items.len > 0) {
                var owned = self.files.pop();
                owned.deinit(allocator);
            }
        }
    }

    fn indexOf(self: *const Storage, path: []const u8) ?usize {
        for (self.files.items, 0..) |entry, index| {
            if (std.mem.eql(u8, entry.path, path)) {
                return index;
            }
        }
        return null;
    }
};

test "storage mock stores file contents in memory" {
    var storage = Storage.mock();
    defer storage.deinit(std.testing.allocator);

    const path = "tmp-mock-storage.txt";
    try storage.writeFile(std.testing.allocator, path, "hello");
    const data = try storage.readFile(std.testing.allocator, path);
    defer std.testing.allocator.free(data);

    try std.testing.expectEqualStrings("hello", data);
    try storage.deleteFile(std.testing.allocator, path);
    try std.testing.expectError(error.FileNotFound, storage.readFile(std.testing.allocator, path));
}
