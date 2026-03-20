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
const FsCache = @import("FsCache.zig");

/// A browser-wide cache for resources across the network.
/// This mostly conforms to RFC9111 with regards to caching behavior.
pub const Cache = @This();

kind: union(enum) {
    fs: FsCache,
},

pub fn get(self: *Cache, allocator: std.mem.Allocator, key: []const u8) ?CachedResponse {
    return switch (self.kind) {
        inline else => |*c| c.get(allocator, key),
    };
}

pub fn put(self: *Cache, key: []const u8, metadata: CachedMetadata, body: []const u8) !void {
    return switch (self.kind) {
        inline else => |*c| c.put(key, metadata, body),
    };
}

pub const CachedMetadata = struct {
    url: [:0]const u8,
    content_type: []const u8,

    status: u16,
    stored_at: i64,
    age_at_store: u64,
    max_age: u64,

    // for If-None-Match
    etag: ?[]const u8,
    // for If-Modified-Since
    last_modified: ?[]const u8,

    must_revalidate: bool,
    no_cache: bool,
    immutable: bool,

    // If non-null, must be incorporated into cache key.
    vary: ?[]const u8,

    pub fn deinit(self: CachedMetadata, allocator: std.mem.Allocator) void {
        allocator.free(self.url);
        allocator.free(self.content_type);
        if (self.etag) |e| allocator.free(e);
        if (self.last_modified) |lm| allocator.free(lm);
        if (self.vary) |v| allocator.free(v);
    }

    pub fn isAgeStale(self: *const CachedMetadata) bool {
        const now = std.time.timestamp();
        const age = now - self.stored_at + @as(i64, @intCast(self.age_at_store));
        return age < @as(i64, @intCast(self.max_age));
    }
};

pub const CachedData = union(enum) {
    buffer: []const u8,
    file: std.fs.File,
};

pub const CachedResponse = struct {
    metadata: CachedMetadata,
    data: CachedData,
};
