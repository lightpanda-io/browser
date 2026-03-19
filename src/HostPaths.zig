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

const log = @import("log.zig");

pub fn resolveProfileDir(allocator: Allocator, override_path: ?[]const u8) ?[]const u8 {
    if (override_path) |path| {
        return copyAndPrepareDir(allocator, path) catch |err| {
            log.warn(.app, "use explicit profile dir", .{ .err = err, .path = path });
            return null;
        };
    }

    if (builtin.is_test) {
        return allocator.dupe(u8, "/tmp") catch unreachable;
    }

    if (!supportsProfileDirFilesystem()) {
        return null;
    }

    const app_dir_path = std.fs.getAppDataDir(allocator, "lightpanda") catch |err| {
        log.warn(.app, "get data dir", .{ .err = err });
        return null;
    };

    std.fs.cwd().makePath(app_dir_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => {
            allocator.free(app_dir_path);
            log.warn(.app, "create data dir", .{ .err = err, .path = app_dir_path });
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

pub fn resolveProfileFile(allocator: Allocator, profile_root: ?[]const u8, name: []const u8) ?[]u8 {
    const root = profile_root orelse return null;
    return std.fs.path.join(allocator, &.{ root, name }) catch null;
}

pub fn resolveProfileSubdir(allocator: Allocator, profile_root: ?[]const u8, subdir: []const u8) ?[]u8 {
    const path = resolveProfileFile(allocator, profile_root, subdir) orelse return null;
    if (!supportsProfileDirFilesystem()) {
        return path;
    }

    std.fs.cwd().makePath(path) catch |err| switch (err) {
        error.PathAlreadyExists => return path,
        else => {
            log.warn(.app, "create profile subdir", .{ .err = err, .path = path });
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

test "resolveProfileDir uses explicit override" {
    const rel_dir = "tmp-host-profile-dir";
    std.fs.cwd().deleteTree(rel_dir) catch {};
    defer std.fs.cwd().deleteTree(rel_dir) catch {};

    const resolved = resolveProfileDir(std.testing.allocator, rel_dir).?;
    defer std.testing.allocator.free(resolved);

    try std.testing.expectEqualStrings(rel_dir, resolved);
    var dir = try std.fs.cwd().openDir(rel_dir, .{});
    defer dir.close();
}

test "resolveProfileFile joins profile root and file name" {
    const rel_dir = "tmp-host-profile-file";
    std.fs.cwd().deleteTree(rel_dir) catch {};
    defer std.fs.cwd().deleteTree(rel_dir) catch {};

    const root = resolveProfileDir(std.testing.allocator, rel_dir).?;
    defer std.testing.allocator.free(root);

    const resolved = resolveProfileFile(std.testing.allocator, root, "cookies-v1.txt") orelse return error.TestExpected;
    defer std.testing.allocator.free(resolved);

    const expected = try std.fs.path.join(std.testing.allocator, &.{ root, "cookies-v1.txt" });
    defer std.testing.allocator.free(expected);

    try std.testing.expectEqualStrings(expected, resolved);
}

test "resolveProfileSubdir creates profile subdir" {
    if (!supportsProfileDirFilesystem()) return;

    const rel_dir = "tmp-host-profile-subdir";
    std.fs.cwd().deleteTree(rel_dir) catch {};
    defer std.fs.cwd().deleteTree(rel_dir) catch {};

    const root = resolveProfileDir(std.testing.allocator, rel_dir).?;
    defer std.testing.allocator.free(root);

    const subdir = resolveProfileSubdir(std.testing.allocator, root, "downloads") orelse return error.TestExpected;
    defer std.testing.allocator.free(subdir);

    const expected = try std.fs.path.join(std.testing.allocator, &.{ root, "downloads" });
    defer std.testing.allocator.free(expected);

    try std.testing.expect(std.mem.endsWith(u8, subdir, expected));

    var dir = if (std.fs.path.isAbsolute(subdir))
        try std.fs.openDirAbsolute(subdir, .{})
    else
        try std.fs.cwd().openDir(subdir, .{});
    defer dir.close();
}
