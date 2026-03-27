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
const Http = @import("../http.zig");
const FsCache = @import("FsCache.zig");

/// A browser-wide cache for resources across the network.
/// This mostly conforms to RFC9111 with regards to caching behavior.
pub const Cache = @This();

kind: union(enum) {
    fs: FsCache,
},

pub fn get(self: *Cache, arena: std.mem.Allocator, req: CacheRequest) ?CachedResponse {
    return switch (self.kind) {
        inline else => |*c| c.get(arena, req),
    };
}

pub fn put(self: *Cache, metadata: CachedMetadata, body: []const u8) !void {
    return switch (self.kind) {
        inline else => |*c| c.put(metadata, body),
    };
}

pub const CacheControl = struct {
    max_age: u64,
    must_revalidate: bool = false,
    immutable: bool = false,

    pub fn parse(value: []const u8) ?CacheControl {
        var cc: CacheControl = .{ .max_age = undefined };

        var max_age_set = false;
        var max_s_age_set = false;
        var is_public = false;

        var iter = std.mem.splitScalar(u8, value, ',');
        while (iter.next()) |part| {
            const directive = std.mem.trim(u8, part, &std.ascii.whitespace);
            if (std.ascii.eqlIgnoreCase(directive, "no-store")) {
                return null;
            } else if (std.ascii.eqlIgnoreCase(directive, "no-cache")) {
                return null;
            } else if (std.ascii.eqlIgnoreCase(directive, "must-revalidate")) {
                cc.must_revalidate = true;
            } else if (std.ascii.eqlIgnoreCase(directive, "immutable")) {
                cc.immutable = true;
            } else if (std.ascii.eqlIgnoreCase(directive, "public")) {
                is_public = true;
            } else if (std.ascii.startsWithIgnoreCase(directive, "max-age=")) {
                if (!max_s_age_set) {
                    if (std.fmt.parseInt(u64, directive[8..], 10) catch null) |max_age| {
                        cc.max_age = max_age;
                        max_age_set = true;
                    }
                }
            } else if (std.ascii.startsWithIgnoreCase(directive, "s-maxage=")) {
                if (std.fmt.parseInt(u64, directive[9..], 10) catch null) |max_age| {
                    cc.max_age = max_age;
                    max_age_set = true;
                    max_s_age_set = true;
                }
            }
        }

        if (!max_age_set) return null;
        if (!is_public) return null;
        if (cc.max_age == 0) return null;

        return cc;
    }
};

pub const Vary = union(enum) {
    wildcard: void,
    value: []const u8,

    pub fn parse(value: []const u8) Vary {
        if (std.mem.eql(u8, value, "*")) return .wildcard;
        return .{ .value = value };
    }

    pub fn toString(self: Vary) []const u8 {
        return switch (self) {
            .wildcard => "*",
            .value => |v| v,
        };
    }
};

pub const CachedMetadata = struct {
    url: [:0]const u8,
    content_type: []const u8,

    status: u16,
    stored_at: i64,
    age_at_store: u64,

    // for If-None-Match
    etag: ?[]const u8,
    // for If-Modified-Since
    last_modified: ?[]const u8,

    cache_control: CacheControl,
    vary: ?Vary,
    headers: []const Http.Header,
};

pub const CacheRequest = struct {
    url: []const u8,
    timestamp: i64,
};

pub const CachedData = union(enum) {
    buffer: []const u8,
    file: std.fs.File,
};

pub const CachedResponse = struct {
    metadata: CachedMetadata,
    data: CachedData,
};

pub fn tryCache(
    arena: std.mem.Allocator,
    timestamp: i64,
    url: [:0]const u8,
    status: u16,
    content_type: ?[]const u8,
    cache_control: ?[]const u8,
    vary: ?[]const u8,
    etag: ?[]const u8,
    last_modified: ?[]const u8,
    age: ?[]const u8,
    has_set_cookie: bool,
    has_authorization: bool,
) !?CachedMetadata {
    if (status != 200) return null;
    if (has_set_cookie) return null;
    if (has_authorization) return null;
    const cc = CacheControl.parse(cache_control orelse return null) orelse return null;

    return .{
        .url = url,
        .content_type = if (content_type) |ct| try arena.dupe(u8, ct) else "application/octet-stream",
        .status = status,
        .stored_at = timestamp,
        .age_at_store = if (age) |a| std.fmt.parseInt(u64, a, 10) catch 0 else 0,
        .cache_control = cc,
        .vary = if (vary) |v| Vary.parse(v) else null,
        .etag = if (etag) |e| try arena.dupe(u8, e) else null,
        .last_modified = if (last_modified) |lm| try arena.dupe(u8, lm) else null,
        .headers = &.{},
    };
}
