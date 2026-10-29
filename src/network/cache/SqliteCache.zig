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

const Pool = @import("../../storage/sqlite/Pool.zig");
const Sqlite = @import("../../storage/sqlite/Sqlite.zig");

const Http = @import("../http.zig");
const Cache = @import("Cache.zig");

const log = lp.log;
const Blob = Sqlite.Blob;
const CacheGetRequest = Cache.CacheGetRequest;
const RenewResponse = Cache.RenewResponse;
const CachePutRequest = Cache.CachePutRequest;
const CacheGetResult = Cache.CacheGetResult;
const CachedResponse = Cache.CachedResponse;

pub const SqliteCache = @This();

pool: Pool,
allocator: std.mem.Allocator,
entry_limit: u32,

// When the schema changes, change this value, and the DB will be deleted and
// re-created with the schema
const schema_version = 2;

// body stays last so that reading columns before it hopefully doesn't visit
// overflow pages.
const schema = [_][:0]const u8{
    \\ create table cache (
    \\      url               text not null primary key,
    \\      status            integer not null,
    \\      stored_at         integer not null,
    \\      age_at_store      integer not null,
    \\      max_age           integer not null,
    \\      must_revalidate   integer not null,
    \\      content_type      text not null,
    \\      etag              text,
    \\      last_modified     text,
    \\      vary_headers      blob not null,
    \\      headers           blob not null,
    \\      script_cache      blob,
    \\      body              blob not null
    \\ ) strict
    ,
    "create index cache_stored_at on cache(stored_at)",
    \\ create index cache_expiry on cache(stored_at + max_age - age_at_store)
    \\     where etag is null and last_modified is null
    ,
};

// Don't change this without also updating the cache_expiry index.
const purge_expired_sql =
    \\ delete from cache
    \\ where etag is null and last_modified is null
    \\     and stored_at + max_age - age_at_store <= $1
;

const SqliteCachePath = union(enum) {
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

const db_name = "cache.db";
const db_files = [_][]const u8{ db_name, db_name ++ "-wal", db_name ++ "-shm" };

pub fn init(allocator: std.mem.Allocator, path: SqliteCachePath, entry_limit: u32) !SqliteCache {
    return open(allocator, path, entry_limit) catch |err| {
        const cache_dir = switch (path) {
            .path => |p| p,
            .memory => return err,
        };
        switch (err) {
            error.NotADB, error.Corrupt, error.SchemaVersion => {},
            else => return err,
        }
        // It's only a cache: start over rather than fail to start.
        log.warn(.cache, "discarding cache", .{ .kind = "SqliteCache", .path = cache_dir, .err = err });
        var dir = try std.Io.Dir.cwd().openDir(lp.io, cache_dir, .{});
        defer dir.close(lp.io);
        for (db_files) |name| {
            dir.deleteFile(lp.io, name) catch |delete_err| switch (delete_err) {
                error.FileNotFound => {},
                else => return delete_err,
            };
        }
        return open(allocator, path, entry_limit);
    };
}

fn open(allocator: std.mem.Allocator, path: SqliteCachePath, entry_limit: u32) !SqliteCache {
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

            const full_path = try allocator.printSentinel(
                "{s}/" ++ db_name,
                .{std.mem.trimEnd(u8, cache_dir, &.{'/'})},
                0,
            );
            defer allocator.free(full_path);
            break :blk try Pool.init(allocator, full_path);
        },
    };
    errdefer pool.deinit(allocator);

    {
        const conn = try pool.acquire();
        defer pool.release(conn);

        try conn.exec("pragma journal_mode=wal", .{});
        try createSchema(conn);
    }

    var cache: SqliteCache = .{ .allocator = allocator, .pool = pool, .entry_limit = entry_limit };
    cache.maintenance(lp.datetime.timestamp(.real));

    log.info(.cache, "sqlite cache initialized", .{ .path = path, .entry_limit = entry_limit, .version = schema_version });
    return cache;
}

fn createSchema(conn: Sqlite.Conn) !void {
    // immediate: another process opening the same new file waits, then sees
    // the schema this one created.
    try conn.begin(.immediate);
    defer conn.rollback() catch {};

    const version = try conn.scalar(i64, "pragma user_version", .{}) orelse 0;
    if (version == schema_version) {
        return;
    }

    const objects = try conn.scalar(i64, "select count(*) from sqlite_schema", .{}) orelse 0;
    if (objects != 0) {
        // Another version's cache (user_version 0 = the old migrations schema).
        return error.SchemaVersion;
    }

    for (schema) |sql| {
        try conn.exec(sql, .{});
    }
    try conn.exec(std.fmt.comptimePrint("pragma user_version = {d}", .{schema_version}), .{});
    try conn.commit();
}

pub fn deinit(self: *SqliteCache) void {
    self.pool.deinit(self.allocator);
}

/// Removes expired entries and enforces size limit.
pub fn maintenance(self: *SqliteCache, now: u64) void {
    const conn = self.pool.acquire() catch |err| {
        log.err(.cache, "sqlite acquire", .{ .err = err });
        return;
    };
    defer self.pool.release(conn);

    conn.exec(purge_expired_sql, .{@as(i64, @intCast(now))}) catch |err| {
        log.err(.cache, "purge expired", .{ .err = err });
    };
    const purged = conn.changes();

    if (self.entry_limit == 0) {
        return;
    }

    conn.exec(
        \\ delete from cache
        \\ where rowid in (
        \\     select rowid from cache
        \\     order by stored_at desc
        \\     limit -1 offset $1
        \\ )
    , .{@as(i64, @intCast(self.entry_limit))}) catch |err| {
        log.err(.cache, "evict overflow", .{ .err = err });
    };

    log.debug(.cache, "maintenance", .{ .purged = purged, .evicted = conn.changes() });
}

pub fn get(self: *SqliteCache, arena: std.mem.Allocator, req: CacheGetRequest) !CacheGetResult {
    const conn = try self.pool.acquire();
    defer self.pool.release(conn);

    return readEntry(conn, arena, req) catch |err| switch (err) {
        error.CorruptEntry => {
            discardCorrupt(conn, req.url);
            return .miss;
        },
        else => return err,
    };
}

fn readEntry(conn: Sqlite.Conn, arena: std.mem.Allocator, req: CacheGetRequest) !CacheGetResult {
    var entry = try conn.row(
        \\ select status, stored_at, age_at_store, max_age, must_revalidate,
        \\     content_type, etag, last_modified, vary_headers, headers,
        \\     script_cache, body
        \\ from cache where url = $1
    , .{req.url}) orelse {
        log.debug(.cache, "miss", .{ .url = req.url, .reason = "missing" });
        return .miss;
    };
    defer entry.deinit();

    const status = std.math.cast(u16, entry.get(i64, 0)) orelse return error.CorruptEntry;
    const stored_at = std.math.cast(u64, entry.get(i64, 1)) orelse return error.CorruptEntry;
    const age_at_store = std.math.cast(u64, entry.get(i64, 2)) orelse return error.CorruptEntry;
    const max_age = std.math.cast(u64, entry.get(i64, 3)) orelse return error.CorruptEntry;
    const must_revalidate = entry.get(bool, 4);
    const raw_content_type = entry.get([]const u8, 5);
    const raw_etag = entry.get(?[]const u8, 6);
    const raw_last_modified = entry.get(?[]const u8, 7);

    const expired = must_revalidate or blk: {
        // Saturates if the clock went back since the entry was stored.
        const age = (req.timestamp -| stored_at) +| age_at_store;
        break :blk age >= max_age;
    };
    const has_validators = raw_etag != null or raw_last_modified != null;

    // If it is expired without validators,
    // we are going to have to make a network request for this resource.
    if (expired and !has_validators) {
        log.debug(.cache, "miss", .{ .url = req.url, .reason = "expired with no validators" });
        return .stale;
    }

    var vary_it: HeaderIterator = try .init(entry.get(Blob, 8).data);
    while (try vary_it.next()) |vary| {
        const incoming = for (req.request_headers) |rh| {
            if (std.ascii.eqlIgnoreCase(rh.name, vary.name)) {
                break rh.value;
            }
        } else "";

        if (!std.ascii.eqlIgnoreCase(vary.value, incoming)) {
            log.debug(.cache, "miss", .{
                .url = req.url,
                .reason = "vary mismatch",
                .header = vary.name,
                .expected = vary.value,
                .got = incoming,
            });
            return .miss;
        }
    }

    var header_it: HeaderIterator = try .init(try arena.dupe(u8, entry.get(Blob, 9).data));
    const headers = try arena.alloc(Http.Header, header_it.remaining);
    for (headers) |*h| {
        h.* = try header_it.pair();
    }
    try header_it.end();

    log.debug(.cache, "hit", .{ .url = req.url, .expired = expired });

    const resp: CachedResponse = .{
        .status = status,
        .headers = headers,
        .content_type = try arena.dupe(u8, raw_content_type),
        .etag = if (raw_etag) |v| try arena.dupe(u8, v) else null,
        .last_modified = if (raw_last_modified) |v| try arena.dupe(u8, v) else null,
        .script_cache = if (entry.get(?Blob, 10)) |b| try arena.dupe(u8, b.data) else null,
        .data = .{ .buffer = try arena.dupe(u8, entry.get(Blob, 11).data) },
    };
    return if (expired) .{ .revalidate = resp } else .{ .hit = resp };
}

pub fn put(self: *SqliteCache, req: CachePutRequest, body: []const u8) !void {
    assertLowercaseNames(req.headers);

    // * 50 is just a guess
    var encoded: std.Io.Writer.Allocating = try .initCapacity(self.allocator, req.vary_headers.len + req.headers.len * 50);
    defer encoded.deinit();

    try HeaderEncoder.all(&encoded.writer, req.vary_headers);
    const vary_len = encoded.written().len;
    try HeaderEncoder.all(&encoded.writer, req.headers);

    const vary_headers = encoded.written()[0..vary_len];
    const headers = encoded.written()[vary_len..];

    const conn = try self.pool.acquire();
    defer self.pool.release(conn);

    try conn.exec(
        \\ insert or replace into cache
        \\     (url, status, stored_at, age_at_store, max_age, must_revalidate,
        \\     content_type, etag, last_modified, vary_headers, headers, body)
        \\ values ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12)
    , .{
        req.url,
        @as(i64, @intCast(req.status)),
        req.stored_at,
        @as(i64, @intCast(req.age_at_store)),
        @as(i64, @intCast(req.cache_control.max_age)),
        req.cache_control.must_revalidate,
        req.content_type,
        req.etag,
        req.last_modified,
        Blob{ .data = vary_headers },
        Blob{ .data = headers },
        Blob{ .data = body },
    });

    log.debug(.cache, "put", .{ .url = req.url, .body_len = body.len });
}

pub fn putScriptCache(self: *SqliteCache, url: []const u8, body: []const u8, bytes: []const u8) !void {
    const conn = try self.pool.acquire();
    defer self.pool.release(conn);

    // We match on the body to make sure we're setting the script_cache for
    // the right body. It is possible, though unlikely, that this row has been
    // updated since we read it with a new body. If so, our cached script would
    // no longer be valid.
    try conn.exec(
        "update cache set script_cache = $1 where url = $2 and body = $3",
        .{ Blob{ .data = bytes }, url, Blob{ .data = body } },
    );
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

    deleteEntry(conn, url);
    log.debug(.cache, "evict", .{ .url = url });
}

fn deleteEntry(conn: Sqlite.Conn, url: []const u8) void {
    conn.exec("delete from cache where url = $1", .{url}) catch |err| {
        log.err(.cache, "delete from cache", .{ .url = url, .err = err });
    };
}

fn discardCorrupt(conn: Sqlite.Conn, url: []const u8) void {
    log.warn(.cache, "discarding corrupt entry", .{ .url = url });
    deleteEntry(conn, url);
}

pub fn renew(self: *SqliteCache, arena: std.mem.Allocator, req: RenewResponse) !void {
    const conn = try self.pool.acquire();
    defer self.pool.release(conn);

    try conn.begin(.immediate);
    defer conn.rollback() catch {};

    assertLowercaseNames(req.headers);

    // The 304's headers replace stored ones with the same name, except
    // content-length, which describes the 304 itself.
    var encoded: std.Io.Writer.Allocating = .init(arena);
    var encoder: HeaderEncoder = .{ .writer = &encoded.writer };
    keepStoredHeaders(conn, &encoder, req) catch |err| switch (err) {
        error.CorruptEntry => {
            discardCorrupt(conn, req.url);
            try conn.commit();
            return;
        },
        else => return err,
    };
    for (req.headers) |h| {
        if (isContentLength(h.name) == false) {
            try encoder.add(h);
        }
    }
    try encoder.finish();

    const directive = req.directive();

    try conn.exec(
        \\ update cache
        \\ set stored_at = $1,
        \\     age_at_store = $2,
        \\     max_age = coalesce($3, max_age),
        \\     must_revalidate = coalesce($4, must_revalidate),
        \\     content_type = coalesce($5, content_type),
        \\     etag = coalesce($6, etag),
        \\     last_modified = coalesce($7, last_modified),
        \\     headers = $8
        \\ where url = $9
    , .{
        directive.timestamp,
        directive.age_at_store,
        directive.max_age,
        directive.must_revalidate,
        directive.content_type,
        directive.etag,
        directive.last_modified,
        Blob{ .data = encoded.written() },
        req.url,
    });

    try conn.commit();

    log.debug(.cache, "renewed", .{
        .url = req.url,
        .timestamp = req.timestamp,
    });
}

// Encodes the stored headers the 304 doesn't replace.
fn keepStoredHeaders(conn: Sqlite.Conn, encoder: *HeaderEncoder, req: RenewResponse) !void {
    var current = try conn.row("select headers from cache where url = $1", .{req.url}) orelse {
        log.debug(.cache, "miss", .{ .url = req.url, .reason = "missing" });
        return error.CacheEntryNotFound;
    };
    defer current.deinit();

    var it: HeaderIterator = try .init(current.get(Blob, 0).data);
    while (try it.next()) |stored| {
        const replaced = for (req.headers) |h| {
            if (std.mem.eql(u8, h.name, stored.name) and isContentLength(h.name) == false) {
                break true;
            }
        } else false;
        if (replaced == false) {
            try encoder.add(stored);
        }
    }
}

fn isContentLength(name: []const u8) bool {
    return std.mem.eql(u8, name, "content-length");
}

// We depend on the response header names being lowercase. HttpClient does this.
// Assert it in debug mode.
fn assertLowercaseNames(headers: []const Http.Header) void {
    if (comptime lp.IS_DEBUG) {
        for (headers) |h| {
            for (h.name) |b| {
                std.debug.assert(std.ascii.isUpper(b) == false);
            }
        }
    }
}

// We encode headers using length-prefixed name, length-prefixed value
// and end with a count of the total # of headers. Putting the count at the
// end is a bit unorthodox, but it makes writing simpler AND, we aren't
// streaming: we have the full header blob in memory, reading the last 2 bytes
// is as easy as reading the first two.
const HeaderEncoder = struct {
    count: u16 = 0,
    writer: *std.Io.Writer,

    fn all(writer: *std.Io.Writer, headers: []const Http.Header) !void {
        var encoder: HeaderEncoder = .{ .writer = writer };
        for (headers) |h| {
            try encoder.add(h);
        }
        try encoder.finish();
    }

    fn add(self: *HeaderEncoder, h: Http.Header) !void {
        if (self.count == std.math.maxInt(u16)) {
            return error.TooManyHeaders;
        }
        if (h.name.len > std.math.maxInt(u16)) {
            return error.InvalidHeaderName;
        }
        if (h.value.len > std.math.maxInt(u16)) {
            return error.InvalidHeaderValue;
        }
        try self.writer.writeInt(u16, @intCast(h.name.len), .little);
        try self.writer.writeAll(h.name);
        try self.writer.writeInt(u16, @intCast(h.value.len), .little);
        try self.writer.writeAll(h.value);
        self.count += 1;
    }

    fn finish(self: *HeaderEncoder) !void {
        try self.writer.writeInt(u16, self.count, .little);
    }
};

const HeaderIterator = struct {
    data: []const u8,
    remaining: u16,

    fn init(blob: []const u8) !HeaderIterator {
        if (blob.len < 2) {
            return error.CorruptEntry;
        }
        const pairs_len = blob.len - 2;
        const count = std.mem.readInt(u16, blob[pairs_len..][0..2], .little);
        if (@as(usize, count) * 4 > pairs_len) {
            // every name=>value pair is at least 4 bytes (the two u16 lengths)
            return error.CorruptEntry;
        }
        return .{
            .remaining = count,
            .data = blob[0..pairs_len],
        };
    }

    fn next(self: *HeaderIterator) !?Http.Header {
        if (self.remaining == 0) {
            try self.end();
            return null;
        }
        return try self.pair();
    }

    fn pair(self: *HeaderIterator) !Http.Header {
        if (self.remaining == 0) {
            return error.CorruptEntry;
        }
        self.remaining -= 1;
        const name = try self.take();
        return .{ .name = name, .value = try self.take() };
    }

    // The count and the pairs must agree.
    fn end(self: *const HeaderIterator) !void {
        if (self.remaining != 0 or self.data.len != 0) {
            return error.CorruptEntry;
        }
    }

    fn take(self: *HeaderIterator) ![]const u8 {
        if (self.data.len < 2) {
            return error.CorruptEntry;
        }
        const len = std.mem.readInt(u16, self.data[0..2], .little);
        const rest = self.data[2..];
        if (rest.len < len) {
            return error.CorruptEntry;
        }
        self.data = rest[len..];
        return rest[0..len];
    }
};

const testing = @import("../../testing.zig");

fn setupCache(allocator: std.mem.Allocator) !Cache {
    return Cache{ .kind = .{ .sqlite = try .init(allocator, .memory, 0) } };
}

test "SqliteCache: basic put and get" {
    var cache = try setupCache(testing.allocator);
    defer cache.deinit();

    const now: u64 = @intCast(std.Io.Timestamp.now(testing.io, .boot).toSeconds());
    const req = CachePutRequest{
        .url = "https://example.com",
        .content_type = "text/html",
        .status = 200,
        .stored_at = now,
        .age_at_store = 0,
        .cache_control = .{ .max_age = 600, .must_revalidate = false },
        .headers = &.{.{ .name = "content-type", .value = "text/html" }},
        .vary_headers = &.{},
    };

    try cache.put(req, "hello world");

    const result = try cache.get(testing.arena_allocator, .{
        .url = "https://example.com",
        .timestamp = now,
        .request_headers = &.{},
    });

    try testing.expect(result == .hit);
    try testing.expectEqual("hello world", result.hit.data.buffer);
    try testing.expectEqual(@as(u16, 200), result.hit.status);
    try testing.expectEqual("text/html", result.hit.content_type);
}

test "SqliteCache: get expiration" {
    var cache = try setupCache(testing.allocator);
    defer cache.deinit();

    const now = 5000;
    const max_age = 1000;

    const req = CachePutRequest{
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

    try cache.put(req, "hello world");

    // age = 50 + 900 = 950 < 1000: fresh
    const fresh = try cache.get(testing.arena_allocator, .{
        .url = "https://example.com",
        .timestamp = now + 50,
        .request_headers = &.{},
    });
    try testing.expect(fresh == .hit);

    const stale = try cache.get(testing.arena_allocator, .{
        .url = "https://example.com",
        .timestamp = now + 200,
        .request_headers = &.{},
    });
    try testing.expect(stale == .revalidate);
    try testing.expectEqual("hello world", stale.revalidate.data.buffer);
}

test "SqliteCache: get expiration (without validators)" {
    var cache = try setupCache(testing.allocator);
    defer cache.deinit();

    const now = 5000;
    const max_age = 1000;

    const req = CachePutRequest{
        .url = "https://example.com",
        .content_type = "text/html",
        .status = 200,
        .stored_at = now,
        .age_at_store = 900,
        .cache_control = .{ .max_age = max_age },
        .headers = &.{},
        .vary_headers = &.{},
    };

    try cache.put(req, "hello world");

    // age = 50 + 900 = 950 < 1000: fresh
    const fresh = try cache.get(testing.arena_allocator, .{
        .url = "https://example.com",
        .timestamp = now + 50,
        .request_headers = &.{},
    });
    try testing.expect(fresh == .hit);

    const stale = try cache.get(testing.arena_allocator, .{
        .url = "https://example.com",
        .timestamp = now + 200,
        .request_headers = &.{},
    });
    try testing.expect(stale == .stale);
}

test "SqliteCache: put override" {
    var cache = try setupCache(testing.allocator);
    defer cache.deinit();

    {
        const req = CachePutRequest{
            .url = "https://example.com",
            .content_type = "text/html",
            .status = 200,
            .stored_at = 5000,
            .age_at_store = 0,
            .cache_control = .{ .max_age = 1000 },
            .headers = &.{},
            .vary_headers = &.{},
        };
        try cache.put(req, "hello world");

        const result = try cache.get(testing.arena_allocator, .{
            .url = "https://example.com",
            .timestamp = 5000,
            .request_headers = &.{},
        });
        try testing.expect(result == .hit);
        try testing.expectEqual("hello world", result.hit.data.buffer);
    }

    {
        const req = CachePutRequest{
            .url = "https://example.com",
            .content_type = "text/html",
            .status = 200,
            .stored_at = 10000,
            .age_at_store = 0,
            .cache_control = .{ .max_age = 2000 },
            .headers = &.{},
            .vary_headers = &.{},
        };
        try cache.put(req, "goodbye world");

        const result = try cache.get(testing.arena_allocator, .{
            .url = "https://example.com",
            .timestamp = 10000,
            .request_headers = &.{},
        });
        try testing.expect(result == .hit);
        try testing.expectEqual("goodbye world", result.hit.data.buffer);
    }
}

test "SqliteCache: vary hit and miss" {
    var cache = try setupCache(testing.allocator);
    defer cache.deinit();

    const now: u64 = @intCast(std.Io.Timestamp.now(testing.io, .boot).toSeconds());
    const req = CachePutRequest{
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

    try cache.put(req, "hello world");

    const hit = try cache.get(testing.arena_allocator, .{
        .url = "https://example.com",
        .timestamp = now,
        .request_headers = &.{.{ .name = "Accept-Encoding", .value = "gzip" }},
    });
    try testing.expect(hit == .hit);
    try testing.expectEqual("hello world", hit.hit.data.buffer);

    const mismatch = try cache.get(testing.arena_allocator, .{
        .url = "https://example.com",
        .timestamp = now,
        .request_headers = &.{.{ .name = "Accept-Encoding", .value = "br" }},
    });
    try testing.expect(mismatch == .miss);

    const missing_header = try cache.get(testing.arena_allocator, .{
        .url = "https://example.com",
        .timestamp = now,
        .request_headers = &.{},
    });
    try testing.expect(missing_header == .miss);
}

test "SqliteCache: vary multiple headers" {
    var cache = try setupCache(testing.allocator);
    defer cache.deinit();

    const now: u64 = @intCast(std.Io.Timestamp.now(testing.io, .boot).toSeconds());
    const req = CachePutRequest{
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

    try cache.put(req, "hello world");

    const hit = try cache.get(testing.arena_allocator, .{
        .url = "https://example.com",
        .timestamp = now,
        .request_headers = &.{
            .{ .name = "Accept-Encoding", .value = "gzip" },
            .{ .name = "Accept-Language", .value = "en" },
        },
    });
    try testing.expect(hit == .hit);
    try testing.expectEqual("hello world", hit.hit.data.buffer);

    const mismatch = try cache.get(testing.arena_allocator, .{
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

    const now: u64 = @intCast(std.Io.Timestamp.now(testing.io, .boot).toSeconds());
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
        testing.arena_allocator,
        .{
            .url = "https://example.com/a",
            .timestamp = now,
            .request_headers = &.{},
        },
    )) == .hit);
    try testing.expect((try cache.get(
        testing.arena_allocator,
        .{
            .url = "https://example.com/b",
            .timestamp = now,
            .request_headers = &.{},
        },
    )) == .hit);

    try cache.clear();

    try testing.expect((try cache.get(
        testing.arena_allocator,
        .{
            .url = "https://example.com/a",
            .timestamp = now,
            .request_headers = &.{},
        },
    )) == .miss);
    try testing.expect((try cache.get(
        testing.arena_allocator,
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

    const now: u64 = @intCast(std.Io.Timestamp.now(testing.io, .boot).toSeconds());
    const req = CachePutRequest{
        .url = "https://example.com",
        .content_type = "text/html",
        .status = 200,
        .stored_at = now,
        .age_at_store = 0,
        .cache_control = .{ .max_age = 600 },
        .headers = &.{},
        .vary_headers = &.{},
    };

    try cache.put(req, "before clear");
    try cache.clear();

    try testing.expect((try cache.get(testing.arena_allocator, .{
        .url = "https://example.com",
        .timestamp = now,
        .request_headers = &.{},
    })) == .miss);

    try cache.put(req, "after clear");
    const result = try cache.get(testing.arena_allocator, .{
        .url = "https://example.com",
        .timestamp = now,
        .request_headers = &.{},
    });
    try testing.expect(result == .hit);
    try testing.expectEqual("after clear", result.hit.data.buffer);
}

test "SqliteCache: evict removes entry" {
    var cache = try setupCache(testing.allocator);
    defer cache.deinit();

    const now: u64 = @intCast(std.Io.Timestamp.now(testing.io, .boot).toSeconds());
    const req = CachePutRequest{
        .url = "https://example.com",
        .content_type = "text/html",
        .status = 200,
        .stored_at = now,
        .age_at_store = 0,
        .cache_control = .{ .max_age = 600 },
        .headers = &.{},
        .vary_headers = &.{},
    };

    try cache.put(req, "hello world");

    const before = try cache.get(testing.arena_allocator, .{ .url = "https://example.com", .timestamp = now, .request_headers = &.{} });
    try testing.expect(before == .hit);

    cache.evict("https://example.com");

    try testing.expect((try cache.get(
        testing.arena_allocator,
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

    try cache.renew(testing.arena_allocator, .{
        .url = "https://example.com",
        .timestamp = now + 500,
        .headers = &.{},
    });

    // Clock reset to now+500, so still fresh at now+1200
    const fresh = try cache.get(testing.arena_allocator, .{
        .url = "https://example.com",
        .timestamp = now + 1200,
        .request_headers = &.{},
    });
    try testing.expect(fresh == .hit);

    const stale = try cache.get(testing.arena_allocator, .{
        .url = "https://example.com",
        .timestamp = now + 1500,
        .request_headers = &.{},
    });
    try testing.expect(stale == .revalidate);
}

test "SqliteCache: renew preserves body" {
    var cache = try setupCache(testing.allocator);
    defer cache.deinit();

    const now: u64 = @intCast(std.Io.Timestamp.now(testing.io, .boot).toSeconds());
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

    try cache.renew(testing.arena_allocator, .{
        .url = "https://example.com",
        .timestamp = now + 100,
        .headers = &.{},
    });

    const result = try cache.get(
        testing.arena_allocator,
        .{
            .url = "https://example.com",
            .timestamp = now + 100,
            .request_headers = &.{},
        },
    );
    try testing.expect(result == .hit);
    try testing.expectEqual("original body", result.hit.data.buffer);
}

test "SqliteCache: script cache is kept by renew and cleared by put" {
    var cache = try setupCache(testing.allocator);
    defer cache.deinit();

    const now: u64 = @intCast(std.Io.Timestamp.now(testing.io, .boot).toSeconds());
    const req: CachePutRequest = .{
        .url = "https://example.com/a.js",
        .content_type = "text/javascript",
        .status = 200,
        .stored_at = now,
        .age_at_store = 0,
        .cache_control = .{ .max_age = 600 },
        .headers = &.{},
        .vary_headers = &.{},
    };
    try cache.put(req, "var a = 1;");
    try testing.expectEqual(null, try getScriptCache(&cache, now));

    // Not written when the stored body isn't the one the bytes came from.
    try cache.putScriptCache(req.url, "var a = 2;", "stale");
    try testing.expectEqual(null, try getScriptCache(&cache, now));

    try cache.putScriptCache(req.url, "var a = 1;", "compiled");
    try testing.expectEqual("compiled", (try getScriptCache(&cache, now)).?);

    try cache.renew(testing.arena_allocator, .{ .url = req.url, .timestamp = now + 100, .headers = &.{} });
    try testing.expectEqual("compiled", (try getScriptCache(&cache, now + 100)).?);

    try cache.put(req, "var a = 1;");
    try testing.expectEqual(null, try getScriptCache(&cache, now));
}

fn getScriptCache(cache: *Cache, now: u64) !?[]const u8 {
    const result = try cache.get(testing.arena_allocator, .{
        .url = "https://example.com/a.js",
        .timestamp = now,
        .request_headers = &.{},
    });
    return result.hit.script_cache;
}

test "SqliteCache: renew merges the 304's headers into the stored ones" {
    var cache = try setupCache(testing.allocator);
    defer cache.deinit();

    const now: u64 = @intCast(std.Io.Timestamp.now(testing.io, .boot).toSeconds());
    try cache.put(.{
        .url = "https://example.com",
        .content_type = "application/json",
        .status = 200,
        .stored_at = now,
        .age_at_store = 0,
        .cache_control = .{ .max_age = 0 },
        .etag = "\"v1\"",
        .headers = &.{
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "content-length", .value = "11" },
            .{ .name = "etag", .value = "\"v1\"" },
            .{ .name = "link", .value = "</old>" },
        },
        .vary_headers = &.{.{ .name = "Accept-Encoding", .value = "gzip" }},
    }, "hello world");

    try cache.renew(testing.arena_allocator, .{
        .url = "https://example.com",
        .timestamp = now + 100,
        .headers = &.{
            .{ .name = "etag", .value = "\"v2\"" },
            .{ .name = "cache-control", .value = "max-age=600" },
            .{ .name = "content-length", .value = "0" },
            .{ .name = "link", .value = "</a>" },
            .{ .name = "link", .value = "</b>" },
        },
    });

    const result = try cache.get(testing.arena_allocator, .{
        .url = "https://example.com",
        .timestamp = now + 100,
        .request_headers = &.{.{ .name = "Accept-Encoding", .value = "gzip" }},
    });
    try testing.expect(result == .hit);

    const expected = [_]Http.Header{
        .{ .name = "content-type", .value = "application/json" },
        .{ .name = "content-length", .value = "11" },
        .{ .name = "etag", .value = "\"v2\"" },
        .{ .name = "cache-control", .value = "max-age=600" },
        .{ .name = "link", .value = "</a>" },
        .{ .name = "link", .value = "</b>" },
    };
    const headers = result.hit.headers;
    try testing.expectEqual(expected.len, headers.len);
    for (expected, headers) |e, h| {
        try testing.expectEqual(e.name, h.name);
        try testing.expectEqual(e.value, h.value);
    }
}

test "SqliteCache: maintenance purges expired entries without validators" {
    var cache = try setupCache(testing.allocator);
    defer cache.deinit();

    // Expires at 6000, no validators: purged.
    try cache.put(.{
        .url = "https://example.com/expired",
        .content_type = "text/html",
        .status = 200,
        .stored_at = 5000,
        .age_at_store = 0,
        .cache_control = .{ .max_age = 1000 },
        .headers = &.{},
        .vary_headers = &.{},
    }, "expired");

    // Expires at 6000 but has an etag: kept for revalidation.
    try cache.put(.{
        .url = "https://example.com/revalidate",
        .content_type = "text/html",
        .status = 200,
        .stored_at = 5000,
        .age_at_store = 0,
        .cache_control = .{ .max_age = 1000 },
        .etag = "ABC",
        .headers = &.{},
        .vary_headers = &.{},
    }, "revalidate");

    // Expires at 7900: kept.
    try cache.put(.{
        .url = "https://example.com/fresh",
        .content_type = "text/html",
        .status = 200,
        .stored_at = 6900,
        .age_at_store = 0,
        .cache_control = .{ .max_age = 1000 },
        .headers = &.{},
        .vary_headers = &.{},
    }, "fresh");

    cache.maintenance(7000);

    try testing.expect((try cache.get(testing.arena_allocator, .{
        .url = "https://example.com/expired",
        .timestamp = 7000,
        .request_headers = &.{},
    })) == .miss);
    try testing.expect((try cache.get(testing.arena_allocator, .{
        .url = "https://example.com/revalidate",
        .timestamp = 7000,
        .request_headers = &.{},
    })) == .revalidate);
    try testing.expect((try cache.get(testing.arena_allocator, .{
        .url = "https://example.com/fresh",
        .timestamp = 7000,
        .request_headers = &.{},
    })) == .hit);
}

test "SqliteCache: expired purge uses the cache_expiry index" {
    var cache = try SqliteCache.init(testing.allocator, .memory, 0);
    defer cache.deinit();

    const conn = try cache.pool.acquire();
    defer cache.pool.release(conn);

    var plan = (try conn.row(
        "explain query plan " ++ purge_expired_sql,
        .{@as(i64, 0)},
    )) orelse return error.NoQueryPlan;
    defer plan.deinit();

    const detail = plan.get([]const u8, 3);
    if (std.mem.find(u8, detail, "cache_expiry") == null) {
        std.debug.print("query plan: {s}\n", .{detail});
        return error.FullTableScan;
    }
}

test "SqliteCache: evicts oldest entries over the limit" {
    var cache = Cache{ .kind = .{ .sqlite = try .init(testing.allocator, .memory, 3) } };
    defer cache.deinit();

    const now: u64 = @intCast(std.Io.Timestamp.now(testing.io, .boot).toSeconds());

    const urls = [_][:0]const u8{
        "https://example.com/a",
        "https://example.com/b",
        "https://example.com/c",
        "https://example.com/d",
    };

    for (urls, 0..) |url, i| {
        try cache.put(.{
            .url = url,
            .content_type = "text/html",
            .status = 200,
            .stored_at = now + i,
            .age_at_store = 0,
            .cache_control = .{ .max_age = 600 },
            .headers = &.{},
            .vary_headers = &.{},
        }, url);
    }

    cache.maintenance(now + urls.len);

    const evicted = try cache.get(testing.arena_allocator, .{
        .url = "https://example.com/a",
        .timestamp = now,
        .request_headers = &.{},
    });
    try testing.expect(evicted == .miss);

    for (urls[1..]) |url| {
        const hit = try cache.get(testing.arena_allocator, .{
            .url = url,
            .timestamp = now + urls.len,
            .request_headers = &.{},
        });
        try testing.expect(hit == .hit);
        try testing.expectEqual(url, hit.hit.data.buffer);
    }
}

test "SqliteCache: starts over from an unreadable database" {
    testing.expectLog(&.{.cache});
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "cache.db", .data = "This is not an SQLite database, only a page of text where its header would be." });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "cache.db-wal", .data = "stale" });

    const cache_dir = try std.Io.Dir.path.join(testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer testing.allocator.free(cache_dir);

    var cache = Cache{ .kind = .{ .sqlite = try .init(testing.allocator, .{ .path = cache_dir }, 0) } };
    defer cache.deinit();

    const now: u64 = @intCast(std.Io.Timestamp.now(testing.io, .boot).toSeconds());
    try cache.put(.{
        .url = "https://example.com",
        .content_type = "text/html",
        .status = 200,
        .stored_at = now,
        .age_at_store = 0,
        .cache_control = .{ .max_age = 600 },
        .headers = &.{},
        .vary_headers = &.{},
    }, "hello world");

    const result = try cache.get(testing.arena_allocator, .{
        .url = "https://example.com",
        .timestamp = now,
        .request_headers = &.{},
    });
    try testing.expect(result == .hit);
    try testing.expectEqual("hello world", result.hit.data.buffer);
}

test "SqliteCache: starts over from another schema version" {
    testing.expectLog(&.{.cache});
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cache_dir = try std.Io.Dir.path.join(testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer testing.allocator.free(cache_dir);

    {
        // The schema from before user_version was used.
        const db_path = try testing.allocator.printSentinel("{s}/" ++ db_name, .{cache_dir}, 0);
        defer testing.allocator.free(db_path);
        const conn = try Sqlite.Conn.open(db_path);
        defer conn.close();
        try conn.exec("create table migrations (id integer primary key, applied_at integer not null) strict", .{});
        try conn.exec("create table cache (url text not null primary key, body blob not null) strict", .{});
    }

    var cache = Cache{ .kind = .{ .sqlite = try .init(testing.allocator, .{ .path = cache_dir }, 0) } };
    defer cache.deinit();

    {
        const conn = try cache.kind.sqlite.pool.acquire();
        defer cache.kind.sqlite.pool.release(conn);
        try testing.expectEqual(schema_version, (try conn.scalar(i64, "pragma user_version", .{})).?);
        try testing.expectEqual(0, (try conn.scalar(i64, "select count(*) from sqlite_schema where name = 'migrations'", .{})).?);
    }

    const now: u64 = @intCast(std.Io.Timestamp.now(testing.io, .boot).toSeconds());
    try cache.put(.{
        .url = "https://example.com",
        .content_type = "text/html",
        .status = 200,
        .stored_at = now,
        .age_at_store = 0,
        .cache_control = .{ .max_age = 600 },
        .headers = &.{.{ .name = "x-test", .value = "1" }},
        .vary_headers = &.{},
    }, "hello world");

    const result = try cache.get(testing.arena_allocator, .{
        .url = "https://example.com",
        .timestamp = now,
        .request_headers = &.{},
    });
    try testing.expect(result == .hit);
    try testing.expectEqual("hello world", result.hit.data.buffer);
    try testing.expectEqual(1, result.hit.headers.len);
    try testing.expectEqual("x-test", result.hit.headers[0].name);
}

fn putCorruptible(cache: *Cache, now: u64) !void {
    try cache.put(.{
        .url = "https://example.com",
        .content_type = "text/html",
        .status = 200,
        .stored_at = now,
        .age_at_store = 0,
        .cache_control = .{ .max_age = 600 },
        .etag = "ABC",
        .headers = &.{.{ .name = "x-test", .value = "1" }},
        .vary_headers = &.{},
    }, "hello world");
}

fn corrupt(cache: *Cache, sql: [:0]const u8) !void {
    const conn = try cache.kind.sqlite.pool.acquire();
    defer cache.kind.sqlite.pool.release(conn);
    try conn.exec(sql, .{});
}

fn entryCount(cache: *Cache) !i64 {
    const conn = try cache.kind.sqlite.pool.acquire();
    defer cache.kind.sqlite.pool.release(conn);
    return (try conn.scalar(i64, "select count(*) from cache", .{})).?;
}

test "SqliteCache: get discards a corrupt entry" {
    const corruptions = [_][:0]const u8{
        // count says 2, one pair (aaa: b) present
        "update cache set headers = x'03006161610100620200'",
        // count says 0, a pair present
        "update cache set headers = x'0100610100620000'",
        // value length past the end
        "update cache set headers = x'010061ff00620100'",
        // count far larger than the pairs could hold
        "update cache set headers = x'ffff'",
        // too short for the count
        "update cache set vary_headers = x'00'",
        "update cache set status = -1",
        "update cache set status = 70000",
        "update cache set max_age = -5",
    };

    const now: u64 = 5000;
    for (corruptions) |sql| {
        testing.expectLog(&.{.cache});
        var cache = try setupCache(testing.allocator);
        defer cache.deinit();

        try putCorruptible(&cache, now);
        try corrupt(&cache, sql);

        const result = try cache.get(testing.arena_allocator, .{
            .url = "https://example.com",
            .timestamp = now,
            .request_headers = &.{},
        });
        try testing.expect(result == .miss);
        try testing.expectEqual(0, try entryCount(&cache));
    }
}

test "SqliteCache: renew discards a corrupt entry" {
    testing.expectLog(&.{.cache});

    var cache = try setupCache(testing.allocator);
    defer cache.deinit();

    try putCorruptible(&cache, 5000);
    try corrupt(&cache, "update cache set headers = x'01'");

    try cache.renew(testing.arena_allocator, .{ .url = "https://example.com", .timestamp = 5100, .headers = &.{} });
    try testing.expectEqual(0, try entryCount(&cache));
}

test "SqliteCache: clock gone backwards" {
    var cache = try setupCache(testing.allocator);
    defer cache.deinit();

    try putCorruptible(&cache, 5000);
    const result = try cache.get(testing.arena_allocator, .{
        .url = "https://example.com",
        .timestamp = 4000,
        .request_headers = &.{},
    });
    try testing.expect(result == .hit);
    try testing.expectEqual(1, result.hit.headers.len);
}
