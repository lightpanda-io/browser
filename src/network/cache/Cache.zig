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
const Http = @import("../http.zig");
const FsCache = @import("FsCache.zig");

const log = lp.log;

/// A browser-wide cache for resources across the network.
/// This mostly conforms to RFC9111 with regards to caching behavior.
pub const Cache = @This();

kind: union(enum) {
    fs: FsCache,
},

pub fn deinit(self: *Cache) void {
    return switch (self.kind) {
        inline else => |*c| c.deinit(),
    };
}

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

pub fn evict(self: *Cache, url: []const u8) void {
    return switch (self.kind) {
        inline else => |*c| c.evict(url),
    };
}

pub fn renew(self: *Cache, arena: std.mem.Allocator, req: RenewResponse) !void {
    return switch (self.kind) {
        inline else => |*c| c.renew(arena, req),
    };
}

pub fn clear(self: *Cache) !void {
    return switch (self.kind) {
        inline else => |*c| c.clear(),
    };
}

pub const CacheControl = struct {
    max_age: u64,
    must_revalidate: bool = false,

    pub fn parse(value: []const u8) ?CacheControl {
        var cc: CacheControl = .{ .max_age = undefined };

        var max_age_set = false;
        var max_s_age_set = false;

        var iter = std.mem.splitScalar(u8, value, ',');
        while (iter.next()) |part| {
            const stripped = std.mem.trim(u8, part, &std.ascii.whitespace);

            var buf: [16]u8 = undefined;
            const len = @min(buf.len, stripped.len);
            const directive = std.ascii.lowerString(buf[0..len], stripped[0..len]);

            if (std.mem.eql(u8, directive, "no-store")) {
                return null;
            }
            if (std.mem.eql(u8, directive, "no-cache")) {
                if (!max_age_set) {
                    cc.max_age = 0;
                    max_age_set = true;
                }

                cc.must_revalidate = true;
                continue;
            }
            if (std.mem.eql(u8, directive, "private")) {
                return null;
            }

            if (std.mem.startsWith(u8, directive, "max-age=")) {
                if (!max_s_age_set) {
                    if (std.fmt.parseInt(u64, directive[8..], 10) catch null) |max_age| {
                        cc.max_age = max_age;
                        max_age_set = true;
                    }
                }
            } else if (std.mem.startsWith(u8, directive, "s-maxage=")) {
                if (std.fmt.parseInt(u64, directive[9..], 10) catch null) |max_age| {
                    cc.max_age = max_age;
                    max_age_set = true;
                    max_s_age_set = true;
                }
            }
        }

        if (!max_age_set) return null;
        if (cc.max_age == 0 and !cc.must_revalidate) return null;

        return cc;
    }
};

pub const CachedMetadata = struct {
    url: [:0]const u8,
    content_type: []const u8,

    status: u16,
    stored_at: i64,
    age_at_store: u64,

    cache_control: CacheControl,
    /// Response Headers
    headers: []const Http.Header,
    /// These are Request Headers used by Vary.
    vary_headers: []const Http.Header,

    // Validators for conditional requests.
    etag: ?[]const u8 = null,
    last_modified: ?[]const u8 = null,

    pub fn format(self: CachedMetadata, writer: *std.Io.Writer) !void {
        try writer.print("url={s} | status={d} | content_type={s} | max_age={d} | etag={s} | last-modified={s} | vary=[", .{
            self.url,
            self.status,
            self.content_type,
            self.cache_control.max_age,
            self.etag orelse "null",
            self.last_modified orelse "null",
        });

        // Logging all headers gets pretty verbose...
        // so we just log the Vary ones that matter for caching.

        if (self.vary_headers.len > 0) {
            for (self.vary_headers, 0..) |hdr, i| {
                if (i > 0) try writer.print(", ", .{});
                try writer.print("{s}: {s}", .{ hdr.name, hdr.value });
            }
        }
        try writer.print("]", .{});
    }

    pub fn isStale(self: CachedMetadata, timestamp: i64) bool {
        if (self.cache_control.must_revalidate) return true;
        const age = (timestamp - self.stored_at) + @as(i64, @intCast(self.age_at_store));
        return age >= @as(i64, @intCast(self.cache_control.max_age));
    }

    pub fn hasValidators(self: CachedMetadata) bool {
        return self.etag != null or self.last_modified != null;
    }

    pub fn renew(self: *CachedMetadata, req: RenewResponse) void {
        self.stored_at = req.timestamp;
        self.age_at_store = 0;

        for (req.headers) |h| {
            const name = h.name;
            const value = h.value;

            if (std.ascii.eqlIgnoreCase("Age", name)) {
                self.age_at_store = std.fmt.parseInt(u64, value, 10) catch 0;
            } else if (std.ascii.eqlIgnoreCase("Cache-Control", name)) {
                self.cache_control = CacheControl.parse(value) orelse continue;
            } else if (std.ascii.eqlIgnoreCase("ETag", name)) {
                self.etag = value;
            } else if (std.ascii.eqlIgnoreCase("Last-Modified", name)) {
                self.last_modified = value;
            }
        }
    }
};

pub const CacheRequest = struct {
    url: []const u8,
    timestamp: i64,
    request_headers: []const Http.Header,
};

pub const RenewResponse = struct {
    url: []const u8,
    timestamp: i64,
    headers: []const Http.Header,
};

pub const CachedData = union(enum) {
    buffer: []const u8,
    file: struct {
        file: std.fs.File,
        offset: usize,
        len: usize,
    },

    pub fn deinit(self: CachedData) void {
        switch (self) {
            .buffer => {},
            .file => |*f| f.file.close(),
        }
    }

    pub fn format(self: CachedData, writer: *std.Io.Writer) !void {
        switch (self) {
            .buffer => |buf| try writer.print("buffer({d} bytes)", .{buf.len}),
            .file => |f| try writer.print("file(offset={d}, len={d} bytes)", .{ f.offset, f.len }),
        }
    }
};

pub const CachedResponse = struct {
    metadata: CachedMetadata,
    data: CachedData,
    expired: bool,

    pub fn format(self: *const CachedResponse, writer: *std.Io.Writer) !void {
        try writer.print("expired={}, ", .{self.expired});
        try writer.print("metadata=(", .{});
        try self.metadata.format(writer);
        try writer.print("), data=", .{});
        try self.data.format(writer);
    }
};

pub fn tryCache(
    arena: std.mem.Allocator,
    timestamp: i64,
    url: [:0]const u8,
    status: u16,
    content_type: ?[]const u8,
    cache_control: ?[]const u8,
    vary: ?[]const u8,
    age: ?[]const u8,
    etag: ?[]const u8,
    last_modified: ?[]const u8,
    has_set_cookie: bool,
    has_authorization: bool,
) !?CachedMetadata {
    if (status != 200) {
        log.debug(.cache, "no store", .{ .url = url, .code = status, .reason = "status" });
        return null;
    }
    if (has_set_cookie) {
        log.debug(.cache, "no store", .{ .url = url, .reason = "has_cookies" });
        return null;
    }
    if (has_authorization) {
        log.debug(.cache, "no store", .{ .url = url, .reason = "has_authorization" });
        return null;
    }
    if (vary) |v| if (std.mem.eql(u8, v, "*")) {
        log.debug(.cache, "no store", .{ .url = url, .vary = v, .reason = "vary" });
        return null;
    };

    const cc = blk: {
        if (cache_control) |c| {
            if (CacheControl.parse(c)) |cc| {
                break :blk cc;
            }
        } else if (last_modified != null) {
            // Requires Last-Modified to be present to heuristically cache.
            log.debug(.cache, "heuristic cache", .{ .url = url, .max_age = 86400 });
            break :blk CacheControl{ .max_age = 86400, .must_revalidate = false };
        }

        log.debug(.cache, "no store", .{
            .url = url,
            .cache_control = cache_control orelse "null",
            .last_modified = last_modified orelse "null",
        });
        return null;
    };

    return .{
        .url = try arena.dupeZ(u8, url),
        .content_type = if (content_type) |ct| try arena.dupe(u8, ct) else "application/octet-stream",
        .status = status,
        .stored_at = timestamp,
        .age_at_store = if (age) |a| std.fmt.parseInt(u64, a, 10) catch 0 else 0,
        .cache_control = cc,
        .headers = &.{},
        .vary_headers = &.{},
        .etag = if (etag) |e| try arena.dupe(u8, e) else null,
        .last_modified = if (last_modified) |lm| try arena.dupe(u8, lm) else null,
    };
}
const testing = @import("../../testing.zig");

test "Cache: CacheControl.parse" {
    try testing.expectEqual(300, CacheControl.parse("max-age=300").?.max_age);

    try testing.expectEqual(300, CacheControl.parse("Max-Age=300").?.max_age);
    try testing.expectEqual(300, CacheControl.parse("MAX-AGE=300").?.max_age);

    try testing.expectEqual(300, CacheControl.parse("public, max-age=300").?.max_age);
    try testing.expectEqual(300, CacheControl.parse("  max-age=300  ").?.max_age);

    try testing.expectEqual(600, CacheControl.parse("max-age=300, s-maxage=600").?.max_age);
    try testing.expectEqual(600, CacheControl.parse("s-maxage=600, max-age=300").?.max_age);

    try testing.expectEqual(null, CacheControl.parse("no-store"));
    try testing.expectEqual(
        CacheControl{ .max_age = 0, .must_revalidate = true },
        CacheControl.parse("no-cache"),
    );
    try testing.expectEqual(null, CacheControl.parse("private"));
    try testing.expectEqual(null, CacheControl.parse("max-age=300, no-store"));
    try testing.expectEqual(
        CacheControl{ .max_age = 300, .must_revalidate = true },
        CacheControl.parse("no-cache, max-age=300"),
    );
    try testing.expectEqual(null, CacheControl.parse("Private, max-age=300"));

    try testing.expectEqual(null, CacheControl.parse("max-age=0"));

    try testing.expectEqual(null, CacheControl.parse("public"));
    try testing.expectEqual(null, CacheControl.parse(""));

    try testing.expectEqual(null, CacheControl.parse("max-age=abc"));
    try testing.expectEqual(null, CacheControl.parse("max-age="));
}

test "Cache: CachedMetadata.renew updates timestamp and age" {
    var meta = CachedMetadata{
        .url = "https://example.com",
        .content_type = "text/html",
        .status = 200,
        .stored_at = 1000,
        .age_at_store = 50,
        .cache_control = .{ .max_age = 600 },
        .headers = &.{},
        .vary_headers = &.{},
    };

    meta.renew(.{ .url = "https://example.com", .timestamp = 2000, .headers = &.{} });

    try testing.expectEqual(2000, meta.stored_at);
    try testing.expectEqual(0, meta.age_at_store);
}

test "Cache: CachedMetadata.renew updates age from Age header" {
    var meta = CachedMetadata{
        .url = "https://example.com",
        .content_type = "text/html",
        .status = 200,
        .stored_at = 1000,
        .age_at_store = 0,
        .cache_control = .{ .max_age = 600 },
        .headers = &.{},
        .vary_headers = &.{},
    };

    meta.renew(.{
        .url = "https://example.com",
        .timestamp = 2000,
        .headers = &.{.{ .name = "Age", .value = "42" }},
    });

    try testing.expectEqual(42, meta.age_at_store);
}

test "Cache: CachedMetadata.renew updates cache_control" {
    var meta = CachedMetadata{
        .url = "https://example.com",
        .content_type = "text/html",
        .status = 200,
        .stored_at = 1000,
        .age_at_store = 0,
        .cache_control = .{ .max_age = 600 },
        .headers = &.{},
        .vary_headers = &.{},
    };

    meta.renew(.{
        .url = "https://example.com",
        .timestamp = 2000,
        .headers = &.{.{ .name = "Cache-Control", .value = "max-age=1200" }},
    });

    try testing.expectEqual(1200, meta.cache_control.max_age);
}

test "Cache: CachedMetadata.renew preserves cache_control on invalid header" {
    var meta = CachedMetadata{
        .url = "https://example.com",
        .content_type = "text/html",
        .status = 200,
        .stored_at = 1000,
        .age_at_store = 0,
        .cache_control = .{ .max_age = 600 },
        .headers = &.{},
        .vary_headers = &.{},
    };

    meta.renew(.{
        .url = "https://example.com",
        .timestamp = 2000,
        .headers = &.{.{ .name = "Cache-Control", .value = "no-store" }},
    });

    try testing.expectEqual(600, meta.cache_control.max_age);
}

test "Cache: CachedMetadata.renew updates etag and last_modified" {
    var meta = CachedMetadata{
        .url = "https://example.com",
        .content_type = "text/html",
        .status = 200,
        .stored_at = 1000,
        .age_at_store = 0,
        .cache_control = .{ .max_age = 600 },
        .headers = &.{},
        .vary_headers = &.{},
        .etag = "\"old-etag\"",
        .last_modified = "Mon, 01 Jan 2024 00:00:00 GMT",
    };

    meta.renew(.{
        .url = "https://example.com",
        .timestamp = 2000,
        .headers = &.{
            .{ .name = "ETag", .value = "\"new-etag\"" },
            .{ .name = "Last-Modified", .value = "Tue, 02 Jan 2024 00:00:00 GMT" },
        },
    });

    try testing.expectEqualSlices(u8, "\"new-etag\"", meta.etag.?);
    try testing.expectEqualSlices(u8, "Tue, 02 Jan 2024 00:00:00 GMT", meta.last_modified.?);
}

test "Cache: tryCache heuristic when no cache-control" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const result = try tryCache(
        arena.allocator(),
        1000,
        "https://example.com",
        200,
        "text/html",
        null,
        null,
        null,
        null,
        null,
        false,
        false,
    );
    try testing.expectEqual(null, result);
}

test "Cache: tryCache heuristic when no cache-control with last-modified" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const result = try tryCache(
        arena.allocator(),
        1000,
        "https://example.com",
        200,
        "text/html",
        null,
        null,
        null,
        null,
        "Wed, 21 Oct 2015 07:28:00 GMT",
        false,
        false,
    );
    try testing.expectEqual(@as(u64, 86400), result.?.cache_control.max_age);
    try testing.expectEqual(false, result.?.cache_control.must_revalidate);
}
