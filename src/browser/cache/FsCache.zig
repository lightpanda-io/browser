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
const Cache = @import("Cache.zig");

pub const FsCache = @This();

allocator: std.mem.Allocator,
dir: std.fs.Dir,

const MAX_CACHE_SIZE_BYTES = 1024 * 1024 * 1024;

pub fn init(allocator: std.mem.Allocator, path: []const u8) !FsCache {
    std.fs.makeDirAbsolute(path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    const dir = std.fs.openDirAbsolute(path, .{ .iterate = true });
    return .{
        .allocator = allocator,
        .dir = dir,
    };
}

pub fn deinit(self: *FsCache) void {
    self.dir.close();
}

pub fn cache(self: *FsCache) Cache {
    return Cache.init(self);
}

fn hashKey(key: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(key, &digest, .{});
    var hex: [64]u8 = undefined;
    _ = std.fmt.bufPrint(&hex, "{}", .{std.fmt.bytesToHex(&digest, .lower)}) catch unreachable;
    return hex;
}

fn parseMeta(allocator: std.mem.Allocator, bytes: []const u8) !void {}

pub fn get(ptr: *anyopaque, key: []const u8) ?Cache.CachedResponse {
    const self: *FsCache = @ptrCast(@alignCast(ptr));
    const hashed_key = hashKey(key);

    var meta_filename: [64 + 5]u8 = undefined;
    const meta_path = std.fmt.bufPrint(&meta_filename, "{s}.meta", .{hashed_key}) catch unreachable;

    const meta_bytes = self.dir.readFileAlloc(self.allocator, meta_filename, MAX_CACHE_SIZE_BYTES) catch return null;
    defer self.allocator.free(meta_bytes);

    const meta = parseMeta(self.allocator, meta_bytes) catch return null;

    // check is meta is valid

    // get the actual file that corresponds to this hash
}
