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

pub fn put(self: *Cache, req: CacheRequest, metadata: CachedMetadata, body: []const u8) !void {
    return switch (self.kind) {
        inline else => |*c| c.put(req, metadata, body),
    };
}

pub const CacheControl = struct {
    max_age: ?u64 = null,
    s_maxage: ?u64 = null,
    is_public: bool = false,
    must_revalidate: bool = false,
    no_cache: bool = false,
    no_store: bool = false,
    immutable: bool = false,

    pub fn parse(value: []const u8) CacheControl {
        var cc: CacheControl = .{};

        var iter = std.mem.splitScalar(u8, value, ',');
        while (iter.next()) |part| {
            const directive = std.mem.trim(u8, part, &std.ascii.whitespace);
            if (std.ascii.eqlIgnoreCase(directive, "no-store")) {
                cc.no_store = true;
            } else if (std.ascii.eqlIgnoreCase(directive, "no-cache")) {
                cc.no_cache = true;
            } else if (std.ascii.eqlIgnoreCase(directive, "must-revalidate")) {
                cc.must_revalidate = true;
            } else if (std.ascii.eqlIgnoreCase(directive, "immutable")) {
                cc.immutable = true;
            } else if (std.ascii.eqlIgnoreCase(directive, "public")) {
                cc.is_public = true;
            } else if (std.ascii.startsWithIgnoreCase(directive, "max-age=")) {
                cc.max_age = std.fmt.parseInt(u64, directive[8..], 10) catch null;
            } else if (std.ascii.startsWithIgnoreCase(directive, "s-maxage=")) {
                cc.s_maxage = std.fmt.parseInt(u64, directive[9..], 10) catch null;
                // s-maxage takes precedence over max-age
                cc.max_age = cc.s_maxage orelse cc.max_age;
            }
        }
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

    pub fn deinit(self: Vary, allocator: std.mem.Allocator) void {
        switch (self) {
            .wildcard => {},
            .value => |v| allocator.free(v),
        }
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

    pub fn fromHeaders(
        url: [:0]const u8,
        status: u16,
        timestamp: i64,
        headers: []const Http.Header,
    ) !?CachedMetadata {
        var cc: CacheControl = .{};
        var vary: ?Vary = null;
        var etag: ?[]const u8 = null;
        var last_modified: ?[]const u8 = null;
        var age_at_store: u64 = 0;
        var content_type: []const u8 = "application/octet-stream";
        var has_set_cookie = false;
        var has_authorization = false;

        for (headers) |hdr| {
            if (std.ascii.eqlIgnoreCase(hdr.name, "cache-control")) {
                cc = CacheControl.parse(hdr.value);
            } else if (std.ascii.eqlIgnoreCase(hdr.name, "etag")) {
                etag = hdr.value;
            } else if (std.ascii.eqlIgnoreCase(hdr.name, "last-modified")) {
                last_modified = hdr.value;
            } else if (std.ascii.eqlIgnoreCase(hdr.name, "vary")) {
                vary = Vary.parse(hdr.value);
            } else if (std.ascii.eqlIgnoreCase(hdr.name, "age")) {
                age_at_store = std.fmt.parseInt(u64, hdr.value, 10) catch 0;
            } else if (std.ascii.eqlIgnoreCase(hdr.name, "content-type")) {
                content_type = hdr.value;
            } else if (std.ascii.eqlIgnoreCase(hdr.name, "set-cookie")) {
                has_set_cookie = true;
            } else if (std.ascii.eqlIgnoreCase(hdr.name, "authorization")) {
                has_authorization = true;
            }
        }

        // no-store: must not be stored
        if (cc.no_store) return null;

        // Vary: * means the response cannot be cached
        if (vary) |v| if (v == .wildcard) return null;

        // must have an explicit max-age to be cacheable
        if (cc.max_age == null) return null;

        // Set-Cookie without explicit public
        if (has_set_cookie and !cc.is_public) return null;

        // Authorization header without explicit public or s-maxage
        if (has_authorization and !cc.is_public and cc.s_maxage == null) return null;

        // Only cache 200 for now. Technically, we can cache others.
        switch (status) {
            200 => {},
            else => return null,
        }

        return .{
            .url = url,
            .content_type = content_type,
            .status = status,
            .stored_at = timestamp,
            .age_at_store = age_at_store,
            .etag = etag,
            .last_modified = last_modified,
            .cache_control = cc,
            .vary = vary,
            .headers = headers,
        };
    }
};

pub const CacheRequest = struct {
    url: []const u8,
};

pub const CachedData = union(enum) {
    buffer: []const u8,
    file: std.fs.File,
};

pub const CachedResponse = struct {
    metadata: CachedMetadata,
    data: CachedData,
};
