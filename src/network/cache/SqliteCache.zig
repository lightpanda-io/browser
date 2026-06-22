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

const Cache = @import("Cache.zig");

const log = lp.log;
const CacheRequest = Cache.CacheRequest;
const RenewResponse = Cache.RenewResponse;
const CachedMetadata = Cache.CachedMetadata;
const CachedResponse = Cache.CachedResponse;

const Http = @import("../http.zig");
const Pool = @import("../../storage/sqlite/Pool.zig");
const Conn = @import("../../storage/sqlite/Sqlite.zig").Conn;
const Migrations = @import("../../storage/sqlite/Sqlite.zig").Migrations;

pub const SqliteCache = @This();

allocator: std.mem.Allocator,
pool: Pool,

const SqliteCacheMigrations = Migrations(&.{
    \\ create table metadata (
    \\      url               text not null primary key,
    \\      status            integer not null,
    \\      stored_at         integer not null,
    \\      age_at_store      integer not null,
    \\      max_age           integer not null,
    \\      must_revalidate   bool not null,
    \\      etag              text,
    \\      last_modified     text
    \\ )
    ,
    \\ create table body (
    \\      url               text not null primary key,
    \\      data              blob not null,
    \\      foreign key (url) references metadata(url) on delete cascade
    \\ )
    ,
    \\ create table header (
    \\      url               text not null,
    \\      name              text not null,
    \\      value             text not null,
    \\      vary              bool not null,
    \\      primary key (url, name),
    \\      foreign key (url) references metadata(url) on delete cascade
    \\ )
    ,
    "create index header_url on header(url)",
});

pub fn init(allocator: std.mem.Allocator, path: [:0]const u8) !SqliteCache {
    var pool = try Pool.init(allocator, path);
    var version: usize = 0;

    {
        const conn = try pool.acquire();
        defer pool.release(conn);

        try conn.exec("pragma journal_mode=wal", .{});
        version = try SqliteCacheMigrations.run(conn);
    }

    for (pool.conns) |conn| {
        try conn.exec("pragma foreign_keys=on", .{});
    }

    log.info(.cache, "sqlite cache initialized", .{ .path = path, .version = version });
    return .{ .allocator = allocator, .pool = pool };
}

pub fn deinit(self: *SqliteCache) void {
    self.pool.deinit(self.allocator);
}

fn loadMetadata(conn: Conn, arena: std.mem.Allocator, url: []const u8) !?CachedMetadata {
    var entry = try conn.row(
        \\ select status, stored_at, age_at_store,
        \\      max_age, must_revalidate, etag, last_modified
        \\ from metadata
        \\ where url = $1
    , .{url}) orelse return null;
    defer entry.deinit();

    const status: u16 = @intCast(entry.get(i64, 0));
    const stored_at = entry.get(i64, 1);
    const age_at_store = entry.get(i64, 2);
    const max_age: u64 = @intCast(entry.get(i64, 3));
    const must_revalidate = entry.get(bool, 4);
    const etag = if (entry.get(?[]const u8, 5)) |opt| try arena.dupe(u8, opt) else null;
    const last_modified = if (entry.get(?[]const u8, 6)) |opt| try arena.dupe(u8, opt) else null;

    var header_rows = try conn.rows(
        "select name, value, vary from header where url = $1",
        .{url},
    );
    defer header_rows.deinit();

    var headers: std.ArrayList(Http.Header) = .empty;
    var vary_headers: std.ArrayList(Http.Header) = .empty;

    while (try header_rows.next()) |row| {
        const name = try arena.dupe(u8, row.get([]const u8, 0));
        const value = try arena.dupe(u8, row.get([]const u8, 1));
        const vary = row.get(bool, 2);

        const h = Http.Header{ .name = name, .value = value };
        if (vary) {
            try vary_headers.append(arena, h);
        } else {
            try headers.append(arena, h);
        }
    }

    return CachedMetadata{
        .url = try arena.dupeZ(u8, url),
        .content_type = blk: {
            for (headers.items) |h| {
                if (std.ascii.eqlIgnoreCase(h.name, "content-type")) break :blk h.value;
            }
            break :blk "application/octet-stream";
        },
        .status = status,
        .stored_at = stored_at,
        .age_at_store = @intCast(age_at_store),
        .cache_control = .{
            .max_age = max_age,
            .must_revalidate = must_revalidate,
        },
        .headers = headers.items,
        .vary_headers = vary_headers.items,
        .etag = etag,
        .last_modified = last_modified,
    };
}

fn loadBody(conn: Conn, arena: std.mem.Allocator, url: []const u8) ![]const u8 {
    const body_entry = try conn.row(
        "select data from body where url = $1",
        .{url},
    ) orelse @panic("valid metadata must have a body");
    defer body_entry.deinit();

    return try arena.dupe(u8, body_entry.get([]const u8, 0));
}

fn insertMetadata(conn: Conn, meta: CachedMetadata, body: []const u8) !void {
    try conn.exec(
        \\ insert or replace into metadata
        \\     (url, status, stored_at, age_at_store, max_age, must_revalidate, etag, last_modified)
        \\ values ($1, $2, $3, $4, $5, $6, $7, $8)
    , .{
        meta.url,
        @as(i64, @intCast(meta.status)),
        meta.stored_at,
        @as(i64, @intCast(meta.age_at_store)),
        @as(i64, @intCast(meta.cache_control.max_age)),
        meta.cache_control.must_revalidate,
        meta.etag,
        meta.last_modified,
    });

    try conn.exec(
        "insert into body (url, data) values ($1, $2)",
        .{ meta.url, body },
    );

    var lower_name: [256]u8 = undefined;
    for (meta.headers) |h| {
        const name = std.ascii.lowerString(lower_name[0..h.name.len], h.name);
        try conn.exec(
            "insert into header (url, name, value, vary) values ($1, $2, $3, false)",
            .{ meta.url, name, h.value },
        );
    }
    for (meta.vary_headers) |h| {
        const name = std.ascii.lowerString(lower_name[0..h.name.len], h.name);
        try conn.exec(
            "insert into header (url, name, value, vary) values ($1, $2, $3, true)",
            .{ meta.url, name, h.value },
        );
    }
}

fn updateMetadata(conn: Conn, meta: CachedMetadata) !void {
    try conn.exec(
        \\ update metadata
        \\ set status = $1, stored_at = $2, age_at_store = $3, max_age = $4, must_revalidate = $5, etag = $6, last_modified = $7
        \\ where url = $8
    , .{
        @as(i64, @intCast(meta.status)),
        meta.stored_at,
        @as(i64, @intCast(meta.age_at_store)),
        @as(i64, @intCast(meta.cache_control.max_age)),
        meta.cache_control.must_revalidate,
        meta.etag,
        meta.last_modified,
        meta.url,
    });

    try conn.exec("delete from header where url = $1 and vary = false", .{meta.url});

    var lower_name: [256]u8 = undefined;
    for (meta.headers) |h| {
        const name = std.ascii.lowerString(lower_name[0..h.name.len], h.name);
        try conn.exec(
            "insert into header (url, name, value, vary) values ($1, $2, $3, false)",
            .{ meta.url, name, h.value },
        );
    }
}

pub fn get(self: *SqliteCache, arena: std.mem.Allocator, req: CacheRequest) !?CachedResponse {
    const conn = try self.pool.acquire();
    defer self.pool.release(conn);

    try conn.begin();
    defer conn.rollback() catch {};

    const metadata = try loadMetadata(conn, arena, req.url) orelse {
        log.debug(.cache, "miss", .{ .url = req.url, .reason = "missing" });
        return null;
    };

    const body = try loadBody(conn, arena, req.url);

    // Vary matching.
    for (metadata.vary_headers) |vary_hdr| {
        const incoming = for (req.request_headers) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, vary_hdr.name)) break h.value;
        } else "";

        if (!std.ascii.eqlIgnoreCase(vary_hdr.value, incoming)) {
            log.debug(.cache, "miss", .{
                .url = req.url,
                .reason = "vary mismatch",
                .header = vary_hdr.name,
                .expected = vary_hdr.value,
                .got = incoming,
            });
            return null;
        }
    }

    const expired = metadata.isStale(req.timestamp);
    log.debug(.cache, "hit", .{ .url = req.url, .expired = expired });

    return .{
        .metadata = metadata,
        .data = .{ .buffer = body },
        .expired = expired,
    };
}

pub fn put(self: *SqliteCache, meta: CachedMetadata, body: []const u8) !void {
    const conn = try self.pool.acquire();
    defer self.pool.release(conn);

    try conn.begin();
    errdefer conn.rollback() catch {};

    try insertMetadata(conn, meta, body);
    try conn.commit();

    log.debug(.cache, "put", .{ .url = meta.url, .body_len = body.len });
}

pub fn clear(self: *SqliteCache) !void {
    const conn = try self.pool.acquire();
    defer self.pool.release(conn);

    try conn.exec("delete from metadata", .{});
    log.debug(.cache, "clear", .{});
}

pub fn evict(self: *SqliteCache, url: []const u8) void {
    const conn = self.pool.acquire() catch |err| {
        log.err(.cache, "sqlite acquire", .{ .url = url, .err = err });
        return;
    };
    defer self.pool.release(conn);

    conn.exec("delete from metadata where url = $1", .{url}) catch |err| {
        log.err(.cache, "delete from cache", .{ .url = url, .err = err });
        return;
    };

    log.debug(.cache, "evict", .{ .url = url });
}

pub fn renew(self: *SqliteCache, arena: std.mem.Allocator, req: RenewResponse) !void {
    const conn = try self.pool.acquire();
    defer self.pool.release(conn);

    try conn.begin();
    errdefer conn.rollback() catch {};

    var metadata = try loadMetadata(conn, arena, req.url) orelse {
        log.debug(.cache, "miss", .{ .url = req.url, .reason = "missing" });
        return error.CacheEntryNotFound;
    };

    metadata.renew(req);

    try updateMetadata(conn, metadata);
    try conn.commit();

    log.debug(.cache, "renewed", .{
        .url = req.url,
        .timestamp = req.timestamp,
    });
}

const testing = std.testing;

fn setupCache(allocator: std.mem.Allocator) !Cache {
    return Cache{ .kind = .{ .sqlite = try .init(allocator, ":memory:") } };
}

test "SqliteCache: Migrations" {
    const allocator = testing.allocator;
    var pool = try Pool.init(allocator, ":memory:");
    defer pool.deinit(allocator);

    const conn = try pool.acquire();
    defer pool.release(conn);

    _ = try SqliteCacheMigrations.run(conn);
}

test "SqliteCache: basic put and get" {
    var cache = try setupCache(testing.allocator);
    defer cache.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const now = std.time.timestamp();
    const meta = CachedMetadata{
        .url = "https://example.com",
        .content_type = "text/html",
        .status = 200,
        .stored_at = now,
        .age_at_store = 0,
        .cache_control = .{ .max_age = 600, .must_revalidate = false },
        .headers = &.{.{ .name = "Content-Type", .value = "text/html" }},
        .vary_headers = &.{},
    };

    try cache.put(meta, "hello world");

    const result = try cache.get(
        arena.allocator(),
        .{
            .url = "https://example.com",
            .timestamp = now,
            .request_headers = &.{},
        },
    ) orelse return error.CacheMiss;

    try testing.expectEqualStrings("hello world", result.data.buffer);
    try testing.expectEqual(@as(u16, 200), result.metadata.status);
    try testing.expectEqual(false, result.expired);
    try testing.expectEqualStrings("text/html", result.metadata.content_type);
}

test "SqliteCache: get expiration" {
    var cache = try setupCache(testing.allocator);
    defer cache.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const now = 5000;
    const max_age = 1000;

    const meta = CachedMetadata{
        .url = "https://example.com",
        .content_type = "text/html",
        .status = 200,
        .stored_at = now,
        .age_at_store = 900,
        .cache_control = .{ .max_age = max_age },
        .headers = &.{},
        .vary_headers = &.{},
    };

    try cache.put(meta, "hello world");

    // age = 50 + 900 = 950 < 1000: fresh
    const fresh = try cache.get(
        arena.allocator(),
        .{
            .url = "https://example.com",
            .timestamp = now + 50,
            .request_headers = &.{},
        },
    ) orelse return error.CacheMiss;
    try testing.expectEqual(false, fresh.expired);

    // age = 200 + 900 = 1100 >= 1000: stale
    const stale = try cache.get(
        arena.allocator(),
        .{
            .url = "https://example.com",
            .timestamp = now + 200,
            .request_headers = &.{},
        },
    ) orelse return error.CacheMiss;
    try testing.expectEqual(true, stale.expired);
}

test "SqliteCache: put override" {
    var cache = try setupCache(testing.allocator);
    defer cache.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    {
        const meta = CachedMetadata{
            .url = "https://example.com",
            .content_type = "text/html",
            .status = 200,
            .stored_at = 5000,
            .age_at_store = 0,
            .cache_control = .{ .max_age = 1000 },
            .headers = &.{},
            .vary_headers = &.{},
        };
        try cache.put(meta, "hello world");

        const result = try cache.get(
            arena.allocator(),
            .{
                .url = "https://example.com",
                .timestamp = 5000,
                .request_headers = &.{},
            },
        ) orelse return error.CacheMiss;
        try testing.expectEqualStrings("hello world", result.data.buffer);
    }

    {
        const meta = CachedMetadata{
            .url = "https://example.com",
            .content_type = "text/html",
            .status = 200,
            .stored_at = 10000,
            .age_at_store = 0,
            .cache_control = .{ .max_age = 2000 },
            .headers = &.{},
            .vary_headers = &.{},
        };
        try cache.put(meta, "goodbye world");

        const result = try cache.get(
            arena.allocator(),
            .{
                .url = "https://example.com",
                .timestamp = 10000,
                .request_headers = &.{},
            },
        ) orelse return error.CacheMiss;
        try testing.expectEqualStrings("goodbye world", result.data.buffer);
    }
}

test "SqliteCache: vary hit and miss" {
    var cache = try setupCache(testing.allocator);
    defer cache.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const now = std.time.timestamp();
    const meta = CachedMetadata{
        .url = "https://example.com",
        .content_type = "text/html",
        .status = 200,
        .stored_at = now,
        .age_at_store = 0,
        .cache_control = .{ .max_age = 600 },
        .headers = &.{},
        .vary_headers = &.{
            .{ .name = "Accept-Encoding", .value = "gzip" },
        },
    };

    try cache.put(meta, "hello world");

    const hit = try cache.get(arena.allocator(), .{
        .url = "https://example.com",
        .timestamp = now,
        .request_headers = &.{.{ .name = "Accept-Encoding", .value = "gzip" }},
    }) orelse return error.CacheMiss;
    try testing.expectEqualStrings("hello world", hit.data.buffer);

    try testing.expectEqual(null, try cache.get(arena.allocator(), .{
        .url = "https://example.com",
        .timestamp = now,
        .request_headers = &.{.{ .name = "Accept-Encoding", .value = "br" }},
    }));

    try testing.expectEqual(null, try cache.get(arena.allocator(), .{
        .url = "https://example.com",
        .timestamp = now,
        .request_headers = &.{},
    }));
}

test "SqliteCache: vary multiple headers" {
    var cache = try setupCache(testing.allocator);
    defer cache.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const now = std.time.timestamp();
    const meta = CachedMetadata{
        .url = "https://example.com",
        .content_type = "text/html",
        .status = 200,
        .stored_at = now,
        .age_at_store = 0,
        .cache_control = .{ .max_age = 600 },
        .headers = &.{},
        .vary_headers = &.{
            .{ .name = "Accept-Encoding", .value = "gzip" },
            .{ .name = "Accept-Language", .value = "en" },
        },
    };

    try cache.put(meta, "hello world");

    const hit = try cache.get(arena.allocator(), .{
        .url = "https://example.com",
        .timestamp = now,
        .request_headers = &.{
            .{ .name = "Accept-Encoding", .value = "gzip" },
            .{ .name = "Accept-Language", .value = "en" },
        },
    }) orelse return error.CacheMiss;
    try testing.expectEqualStrings("hello world", hit.data.buffer);

    try testing.expectEqual(null, try cache.get(arena.allocator(), .{
        .url = "https://example.com",
        .timestamp = now,
        .request_headers = &.{
            .{ .name = "Accept-Encoding", .value = "gzip" },
            .{ .name = "Accept-Language", .value = "fr" },
        },
    }));
}

test "SqliteCache: clear removes all entries" {
    var cache = try setupCache(testing.allocator);
    defer cache.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const now = std.time.timestamp();

    try cache.put(.{
        .url = "https://example.com/a",
        .content_type = "text/html",
        .status = 200,
        .stored_at = now,
        .age_at_store = 0,
        .cache_control = .{ .max_age = 600 },
        .headers = &.{},
        .vary_headers = &.{},
    }, "body a");

    try cache.put(.{
        .url = "https://example.com/b",
        .content_type = "text/html",
        .status = 200,
        .stored_at = now,
        .age_at_store = 0,
        .cache_control = .{ .max_age = 600 },
        .headers = &.{},
        .vary_headers = &.{},
    }, "body b");

    try testing.expect(null != try cache.get(
        arena.allocator(),
        .{
            .url = "https://example.com/a",
            .timestamp = now,
            .request_headers = &.{},
        },
    ));
    try testing.expect(null != try cache.get(
        arena.allocator(),
        .{
            .url = "https://example.com/b",
            .timestamp = now,
            .request_headers = &.{},
        },
    ));

    try cache.clear();

    try testing.expectEqual(null, try cache.get(
        arena.allocator(),
        .{
            .url = "https://example.com/a",
            .timestamp = now,
            .request_headers = &.{},
        },
    ));
    try testing.expectEqual(null, try cache.get(
        arena.allocator(),
        .{
            .url = "https://example.com/b",
            .timestamp = now,
            .request_headers = &.{},
        },
    ));
}

test "SqliteCache: put after clear works" {
    var cache = try setupCache(testing.allocator);
    defer cache.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const now = std.time.timestamp();
    const meta = CachedMetadata{
        .url = "https://example.com",
        .content_type = "text/html",
        .status = 200,
        .stored_at = now,
        .age_at_store = 0,
        .cache_control = .{ .max_age = 600 },
        .headers = &.{},
        .vary_headers = &.{},
    };

    try cache.put(meta, "before clear");
    try cache.clear();

    try testing.expectEqual(null, try cache.get(
        arena.allocator(),
        .{
            .url = "https://example.com",
            .timestamp = now,
            .request_headers = &.{},
        },
    ));

    try cache.put(meta, "after clear");
    const result = try cache.get(
        arena.allocator(),
        .{
            .url = "https://example.com",
            .timestamp = now,
            .request_headers = &.{},
        },
    ) orelse return error.CacheMiss;
    try testing.expectEqualStrings("after clear", result.data.buffer);
}

test "SqliteCache: evict removes entry" {
    var cache = try setupCache(testing.allocator);
    defer cache.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const now = std.time.timestamp();
    const meta = CachedMetadata{
        .url = "https://example.com",
        .content_type = "text/html",
        .status = 200,
        .stored_at = now,
        .age_at_store = 0,
        .cache_control = .{ .max_age = 600 },
        .headers = &.{},
        .vary_headers = &.{},
    };

    try cache.put(meta, "hello world");

    _ = try cache.get(
        arena.allocator(),
        .{ .url = "https://example.com", .timestamp = now, .request_headers = &.{} },
    ) orelse return error.CacheMiss;

    cache.evict("https://example.com");

    try testing.expectEqual(null, try cache.get(
        arena.allocator(),
        .{
            .url = "https://example.com",
            .timestamp = now,
            .request_headers = &.{},
        },
    ));
}

test "SqliteCache: renew refreshes expiry" {
    var cache = try setupCache(testing.allocator);
    defer cache.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const now: i64 = 5000;

    try cache.put(.{
        .url = "https://example.com",
        .content_type = "text/html",
        .status = 200,
        .stored_at = now,
        .age_at_store = 0,
        .cache_control = .{ .max_age = 1000 },
        .headers = &.{},
        .vary_headers = &.{},
    }, "hello world");

    try cache.renew(
        arena.allocator(),
        .{ .url = "https://example.com", .timestamp = now + 500, .headers = &.{} },
    );

    // Clock reset to now+500, so still fresh at now+1200
    const fresh = try cache.get(
        arena.allocator(),
        .{
            .url = "https://example.com",
            .timestamp = now + 1200,
            .request_headers = &.{},
        },
    ) orelse return error.CacheMiss;
    try testing.expectEqual(false, fresh.expired);

    // Expires at now+500+1000 = now+1500
    const stale = try cache.get(
        arena.allocator(),
        .{
            .url = "https://example.com",
            .timestamp = now + 1500,
            .request_headers = &.{},
        },
    ) orelse return error.CacheMiss;
    try testing.expectEqual(true, stale.expired);
}

test "SqliteCache: renew preserves body" {
    var cache = try setupCache(testing.allocator);
    defer cache.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const now = std.time.timestamp();

    try cache.put(.{
        .url = "https://example.com",
        .content_type = "text/html",
        .status = 200,
        .stored_at = now,
        .age_at_store = 0,
        .cache_control = .{ .max_age = 600 },
        .headers = &.{},
        .vary_headers = &.{},
    }, "original body");

    try cache.renew(
        arena.allocator(),
        .{ .url = "https://example.com", .timestamp = now + 100, .headers = &.{} },
    );

    const result = try cache.get(
        arena.allocator(),
        .{
            .url = "https://example.com",
            .timestamp = now + 100,
            .request_headers = &.{},
        },
    ) orelse return error.CacheMiss;
    try testing.expectEqualStrings("original body", result.data.buffer);
}
