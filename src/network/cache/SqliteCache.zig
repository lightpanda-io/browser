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
const CacheGetRequest = Cache.CacheGetRequest;
const RenewResponse = Cache.RenewResponse;
const CachePutRequest = Cache.CachePutRequest;
const CacheGetResult = Cache.CacheGetResult;
const CachedResponse = Cache.CachedResponse;
const CacheControl = Cache.CacheControl;
const parseDeltaSeconds = Cache.parseDeltaSeconds;

const Http = @import("../http.zig");
const Blob = @import("../../storage/sqlite/Sqlite.zig").Blob;
const Pool = @import("../../storage/sqlite/Pool.zig");
const Conn = @import("../../storage/sqlite/Sqlite.zig").Conn;
const Migration = @import("../../storage/sqlite/Sqlite.zig").Migration;
const Migrations = @import("../../storage/sqlite/Sqlite.zig").Migrations;

pub const SqliteCache = @This();

allocator: std.mem.Allocator,
pool: Pool,

const cache_migrations: []const Migration = &.{
    .{ .sql =
    \\ create table cache (
    \\      url               text not null primary key,
    \\      status            integer not null,
    \\      stored_at         integer not null,
    \\      age_at_store      integer not null,
    \\      max_age           integer not null,
    \\      must_revalidate   integer not null,
    \\      etag              text,
    \\      last_modified     text,
    \\      body              blob not null
    \\ ) strict
    },
    .{ .sql =
    \\ create table header (
    \\      url               text not null,
    \\      name              text not null,
    \\      value             blob not null,
    \\      vary              integer not null,
    \\      foreign key (url) references cache(url) on delete cascade
    \\ ) strict
    },
    .{ .sql = "create index header_url on header(url)" },
};

pub const SqliteCachePath = union(enum) {
    path: []const u8,
    memory,

    pub fn format(
        self: SqliteCachePath,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        const name = switch (self) {
            .memory => "memory",
            .path => |p| p,
        };
        try writer.writeAll(name);
    }
};

pub fn init(allocator: std.mem.Allocator, path: SqliteCachePath) !SqliteCache {
    var pool = switch (path) {
        .memory => try Pool.init(allocator, ":memory:"),
        .path => |cache_dir| blk: {
            std.Io.Dir.cwd().createDirPath(lp.io, cache_dir) catch |e| {
                log.err(
                    .cache,
                    "failed to make path",
                    .{ .kind = "SqliteCache", .path = cache_dir, .err = e },
                );
                return e;
            };

            const full_path = try std.fmt.allocPrintSentinel(
                allocator,
                "{s}/cache.db",
                .{std.mem.trimEnd(u8, cache_dir, &.{'/'})},
                0,
            );
            defer allocator.free(full_path);
            break :blk try Pool.init(allocator, full_path);
        },
    };
    errdefer pool.deinit(allocator);

    var version: usize = 0;

    {
        const conn = try pool.acquire();
        defer pool.release(conn);

        try conn.exec("pragma journal_mode=wal", .{});
        version = try Migrations.run(conn, cache_migrations);
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

pub fn get(self: *SqliteCache, arena: std.mem.Allocator, req: CacheGetRequest) !CacheGetResult {
    const conn = try self.pool.acquire();
    defer self.pool.release(conn);

    try conn.begin(.deferred);
    defer conn.rollback() catch {};

    var entry = try conn.row(
        \\ select status, stored_at, age_at_store,
        \\     max_age, must_revalidate, etag, last_modified, body
        \\ from cache where url = $1
    , .{req.url}) orelse {
        log.debug(.cache, "miss", .{ .url = req.url, .reason = "missing" });
        return .miss;
    };
    defer entry.deinit();

    const status: u16 = @intCast(entry.get(i64, 0));
    const stored_at = entry.get(i64, 1);
    const age_at_store = entry.get(i64, 2);
    const max_age: u64 = @intCast(entry.get(i64, 3));
    const must_revalidate = entry.get(bool, 4);
    const raw_etag = entry.get(?[]const u8, 5);
    const raw_last_modified = entry.get(?[]const u8, 6);
    const raw_body = entry.get(Blob, 7);

    const expired = must_revalidate or blk: {
        const age = (req.timestamp - stored_at) + age_at_store;
        break :blk age >= @as(i64, @intCast(max_age));
    };
    const has_validators = raw_etag != null or raw_last_modified != null;

    // If it is expired without validators,
    // we are going to have to make a network request for this resource.
    if (expired and !has_validators) {
        log.debug(.cache, "miss", .{ .url = req.url, .reason = "expired with no validators" });
        return .stale;
    }

    var vary_rows = try conn.rows(
        "select name, value from header where url = $1 and vary = true",
        .{req.url},
    );
    defer vary_rows.deinit();

    while (try vary_rows.next()) |row| {
        const name = row.get([]const u8, 0);
        const value = row.get(Blob, 1).data;

        const incoming = for (req.request_headers) |rh| {
            if (std.ascii.eqlIgnoreCase(rh.name, name)) break rh.value;
        } else "";

        if (!std.ascii.eqlIgnoreCase(value, incoming)) {
            log.debug(.cache, "miss", .{
                .url = req.url,
                .reason = "vary mismatch",
                .header = name,
                .expected = value,
                .got = incoming,
            });
            return .miss;
        }
    }

    var header_rows = try conn.rows(
        "select name, value from header where url = $1 and vary = false",
        .{req.url},
    );
    defer header_rows.deinit();

    var headers: std.ArrayList(Http.Header) = .empty;
    var content_type: []const u8 = "application/octet-stream";

    while (try header_rows.next()) |row| {
        const name = try arena.dupe(u8, row.get([]const u8, 0));
        const value = try arena.dupe(u8, row.get(Blob, 1).data);
        if (std.ascii.eqlIgnoreCase(name, "content-type")) content_type = value;
        try headers.append(arena, .{ .name = name, .value = value });
    }

    log.debug(.cache, "hit", .{ .url = req.url, .expired = expired });

    const resp: CachedResponse = .{
        .status = status,
        .content_type = content_type,
        .headers = headers.items,
        .etag = if (raw_etag) |v| try arena.dupe(u8, v) else null,
        .last_modified = if (raw_last_modified) |v| try arena.dupe(u8, v) else null,
        .data = .{ .buffer = try arena.dupe(u8, raw_body.data) },
    };
    return if (expired) .{ .revalidate = resp } else .{ .hit = resp };
}

pub fn put(self: *SqliteCache, req: CachePutRequest, body: []const u8) !void {
    const conn = try self.pool.acquire();
    defer self.pool.release(conn);

    try conn.begin(.immediate);
    defer conn.rollback() catch {};

    try conn.exec("delete from cache where url = $1", .{req.url});

    try conn.exec(
        \\ insert into cache
        \\     (url, status, stored_at, age_at_store, max_age, must_revalidate, etag, last_modified, body)
        \\ values ($1, $2, $3, $4, $5, $6, $7, $8, $9)
    , .{
        req.url,
        @as(i64, @intCast(req.status)),
        req.stored_at,
        @as(i64, @intCast(req.age_at_store)),
        @as(i64, @intCast(req.cache_control.max_age)),
        req.cache_control.must_revalidate,
        req.etag,
        req.last_modified,
        Blob{ .data = body },
    });

    var lower_name: [256]u8 = undefined;
    for (req.headers) |h| {
        if (h.name.len > lower_name.len) return error.HeaderNameTooLong;
        const name = std.ascii.lowerString(lower_name[0..h.name.len], h.name);
        try conn.exec(
            "insert into header (url, name, value, vary) values ($1, $2, $3, false)",
            .{ req.url, name, Blob{ .data = h.value } },
        );
    }
    for (req.vary_headers) |h| {
        if (h.name.len > lower_name.len) return error.HeaderNameTooLong;
        const name = std.ascii.lowerString(lower_name[0..h.name.len], h.name);
        try conn.exec(
            "insert into header (url, name, value, vary) values ($1, $2, $3, true)",
            .{ req.url, name, Blob{ .data = h.value } },
        );
    }

    try conn.commit();

    log.debug(.cache, "put", .{ .url = req.url, .body_len = body.len });
}

pub fn clear(self: *SqliteCache) !void {
    const conn = try self.pool.acquire();
    defer self.pool.release(conn);

    try conn.exec("delete from cache", .{});
    log.debug(.cache, "clear", .{});
}

pub fn evict(self: *SqliteCache, url: []const u8) void {
    const conn = self.pool.acquire() catch |err| {
        log.err(.cache, "sqlite acquire", .{ .url = url, .err = err });
        return;
    };
    defer self.pool.release(conn);

    conn.exec("delete from cache where url = $1", .{url}) catch |err| {
        log.err(.cache, "delete from cache", .{ .url = url, .err = err });
        return;
    };

    log.debug(.cache, "evict", .{ .url = url });
}

pub fn renew(self: *SqliteCache, _: std.mem.Allocator, req: RenewResponse) !void {
    const conn = try self.pool.acquire();
    defer self.pool.release(conn);

    try conn.begin(.immediate);
    defer conn.rollback() catch {};

    var age_at_store: u64 = 0;
    var etag: ?[]const u8 = null;
    var last_modified: ?[]const u8 = null;
    var cache_control: ?CacheControl = null;

    for (req.headers) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "Age")) {
            age_at_store = parseDeltaSeconds(h.value) orelse 0;
        } else if (std.ascii.eqlIgnoreCase(h.name, "Cache-Control")) {
            cache_control = CacheControl.parse(h.value) orelse continue;
        } else if (std.ascii.eqlIgnoreCase(h.name, "ETag")) {
            etag = h.value;
        } else if (std.ascii.eqlIgnoreCase(h.name, "Last-Modified")) {
            last_modified = h.value;
        }
    }

    try conn.exec(
        \\ update cache
        \\ set stored_at = $1,
        \\     age_at_store = $2,
        \\     max_age = coalesce($3, max_age),
        \\     must_revalidate = coalesce($4, must_revalidate),
        \\     etag = coalesce($5, etag),
        \\     last_modified = coalesce($6, last_modified)
        \\ where url = $7
    , .{
        req.timestamp,
        age_at_store,
        if (cache_control) |cc| cc.max_age else null,
        if (cache_control) |cc| cc.must_revalidate else null,
        etag,
        last_modified,
        req.url,
    });

    const affected = conn.changes();
    if (affected == 0) {
        log.debug(.cache, "miss", .{ .url = req.url, .reason = "missing" });
        return error.CacheEntryNotFound;
    }

    // Clear old non-Vary headers.
    try conn.exec("delete from header where url = $1 and vary = false", .{req.url});

    var lower_name: [256]u8 = undefined;
    for (req.headers) |h| {
        if (h.name.len > lower_name.len) return error.HeaderNameTooLong;
        const name = std.ascii.lowerString(lower_name[0..h.name.len], h.name);
        try conn.exec(
            "insert into header (url, name, value, vary) values ($1, $2, $3, false)",
            .{ req.url, name, Blob{ .data = h.value } },
        );
    }

    try conn.commit();

    log.debug(.cache, "renewed", .{
        .url = req.url,
        .timestamp = req.timestamp,
    });
}

const testing = std.testing;

fn setupCache(allocator: std.mem.Allocator) !Cache {
    return Cache{ .kind = .{ .sqlite = try .init(allocator, .memory) } };
}

test "SqliteCache: Migrations" {
    const allocator = testing.allocator;
    var pool = try Pool.init(allocator, ":memory:");
    defer pool.deinit(allocator);

    const conn = try pool.acquire();
    defer pool.release(conn);

    _ = try Migrations.run(conn, cache_migrations);
}

test "SqliteCache: basic put and get" {
    var cache = try setupCache(testing.allocator);
    defer cache.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const now = std.Io.Clock.now(.boot, lp.io).toSeconds();
    const meta = CachePutRequest{
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
    );

    try testing.expect(result == .hit);
    try testing.expectEqualStrings("hello world", result.hit.data.buffer);
    try testing.expectEqual(@as(u16, 200), result.hit.status);
    try testing.expectEqualStrings("text/html", result.hit.content_type);
}

test "SqliteCache: get expiration" {
    var cache = try setupCache(testing.allocator);
    defer cache.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const now = 5000;
    const max_age = 1000;

    const meta = CachePutRequest{
        .url = "https://example.com",
        .content_type = "text/html",
        .status = 200,
        .stored_at = now,
        .age_at_store = 900,
        .cache_control = .{ .max_age = max_age },
        .etag = "ABC",
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
    );
    try testing.expect(fresh == .hit);

    const stale = try cache.get(
        arena.allocator(),
        .{
            .url = "https://example.com",
            .timestamp = now + 200,
            .request_headers = &.{},
        },
    );
    try testing.expect(stale == .revalidate);
    try testing.expectEqualStrings("hello world", stale.revalidate.data.buffer);
}

test "SqliteCache: get expiration (without validators)" {
    var cache = try setupCache(testing.allocator);
    defer cache.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const now = 5000;
    const max_age = 1000;

    const meta = CachePutRequest{
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
    );
    try testing.expect(fresh == .hit);

    const stale = try cache.get(
        arena.allocator(),
        .{
            .url = "https://example.com",
            .timestamp = now + 200,
            .request_headers = &.{},
        },
    );
    try testing.expect(stale == .stale);
}

test "SqliteCache: put override" {
    var cache = try setupCache(testing.allocator);
    defer cache.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    {
        const meta = CachePutRequest{
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
        );
        try testing.expect(result == .hit);
        try testing.expectEqualStrings("hello world", result.hit.data.buffer);
    }

    {
        const meta = CachePutRequest{
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
        );
        try testing.expect(result == .hit);
        try testing.expectEqualStrings("goodbye world", result.hit.data.buffer);
    }
}

test "SqliteCache: vary hit and miss" {
    var cache = try setupCache(testing.allocator);
    defer cache.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const now = std.Io.Clock.now(.boot, testing.io).toSeconds();
    const meta = CachePutRequest{
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
    });
    try testing.expect(hit == .hit);
    try testing.expectEqualStrings("hello world", hit.hit.data.buffer);

    const mismatch = try cache.get(arena.allocator(), .{
        .url = "https://example.com",
        .timestamp = now,
        .request_headers = &.{.{ .name = "Accept-Encoding", .value = "br" }},
    });
    try testing.expect(mismatch == .miss);

    const missing_header = try cache.get(arena.allocator(), .{
        .url = "https://example.com",
        .timestamp = now,
        .request_headers = &.{},
    });
    try testing.expect(missing_header == .miss);
}

test "SqliteCache: vary multiple headers" {
    var cache = try setupCache(testing.allocator);
    defer cache.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const now = std.Io.Clock.now(.boot, testing.io).toSeconds();
    const meta = CachePutRequest{
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
    });
    try testing.expect(hit == .hit);
    try testing.expectEqualStrings("hello world", hit.hit.data.buffer);

    const mismatch = try cache.get(arena.allocator(), .{
        .url = "https://example.com",
        .timestamp = now,
        .request_headers = &.{
            .{ .name = "Accept-Encoding", .value = "gzip" },
            .{ .name = "Accept-Language", .value = "fr" },
        },
    });
    try testing.expect(mismatch == .miss);
}

test "SqliteCache: clear removes all entries" {
    var cache = try setupCache(testing.allocator);
    defer cache.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const now = std.Io.Clock.now(.boot, testing.io).toSeconds();
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

    try testing.expect((try cache.get(
        arena.allocator(),
        .{
            .url = "https://example.com/a",
            .timestamp = now,
            .request_headers = &.{},
        },
    )) == .hit);
    try testing.expect((try cache.get(
        arena.allocator(),
        .{
            .url = "https://example.com/b",
            .timestamp = now,
            .request_headers = &.{},
        },
    )) == .hit);

    try cache.clear();

    try testing.expect((try cache.get(
        arena.allocator(),
        .{
            .url = "https://example.com/a",
            .timestamp = now,
            .request_headers = &.{},
        },
    )) == .miss);
    try testing.expect((try cache.get(
        arena.allocator(),
        .{
            .url = "https://example.com/b",
            .timestamp = now,
            .request_headers = &.{},
        },
    )) == .miss);
}

test "SqliteCache: put after clear works" {
    var cache = try setupCache(testing.allocator);
    defer cache.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const now = std.Io.Clock.now(.boot, testing.io).toSeconds();
    const meta = CachePutRequest{
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

    try testing.expect((try cache.get(
        arena.allocator(),
        .{
            .url = "https://example.com",
            .timestamp = now,
            .request_headers = &.{},
        },
    )) == .miss);

    try cache.put(meta, "after clear");
    const result = try cache.get(
        arena.allocator(),
        .{
            .url = "https://example.com",
            .timestamp = now,
            .request_headers = &.{},
        },
    );
    try testing.expect(result == .hit);
    try testing.expectEqualStrings("after clear", result.hit.data.buffer);
}

test "SqliteCache: evict removes entry" {
    var cache = try setupCache(testing.allocator);
    defer cache.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const now = std.Io.Clock.now(.boot, testing.io).toSeconds();
    const meta = CachePutRequest{
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

    const before = try cache.get(
        arena.allocator(),
        .{ .url = "https://example.com", .timestamp = now, .request_headers = &.{} },
    );
    try testing.expect(before == .hit);

    cache.evict("https://example.com");

    try testing.expect((try cache.get(
        arena.allocator(),
        .{
            .url = "https://example.com",
            .timestamp = now,
            .request_headers = &.{},
        },
    )) == .miss);
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
        .etag = "ABC",
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
    );
    try testing.expect(fresh == .hit);

    const stale = try cache.get(
        arena.allocator(),
        .{
            .url = "https://example.com",
            .timestamp = now + 1500,
            .request_headers = &.{},
        },
    );
    try testing.expect(stale == .revalidate);
}

test "SqliteCache: renew preserves body" {
    var cache = try setupCache(testing.allocator);
    defer cache.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const now = std.Io.Clock.now(.boot, testing.io).toSeconds();
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
    );
    try testing.expect(result == .hit);
    try testing.expectEqualStrings("original body", result.hit.data.buffer);
}
