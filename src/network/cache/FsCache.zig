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
const log = @import("../../log.zig");
const Cache = @import("Cache.zig");
const Http = @import("../http.zig");
const CacheRequest = Cache.CacheRequest;
const CachedMetadata = Cache.CachedMetadata;
const CachedResponse = Cache.CachedResponse;

const CACHE_VERSION: usize = 1;
const LOCK_STRIPES = 16;
comptime {
    std.debug.assert(std.math.isPowerOfTwo(LOCK_STRIPES));
}

pub const FsCache = @This();

dir: std.fs.Dir,
locks: [LOCK_STRIPES]std.Thread.Mutex = .{std.Thread.Mutex{}} ** LOCK_STRIPES,

const CacheMetadataJson = struct {
    version: usize,
    metadata: CachedMetadata,
};

fn getLockPtr(self: *FsCache, key: *const [HASHED_KEY_LEN]u8) *std.Thread.Mutex {
    const lock_idx = std.hash.Wyhash.hash(0, key[0..]) & (LOCK_STRIPES - 1);
    return &self.locks[lock_idx];
}

const BODY_LEN_HEADER_LEN = 8;
const HASHED_KEY_LEN = 64;
const HASHED_PATH_LEN = HASHED_KEY_LEN + 6;
const HASHED_TMP_PATH_LEN = HASHED_PATH_LEN + 4;

fn hashKey(key: []const u8) [HASHED_KEY_LEN]u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(key, &digest, .{});
    var hex: [HASHED_KEY_LEN]u8 = undefined;
    _ = std.fmt.bufPrint(&hex, "{s}", .{std.fmt.bytesToHex(&digest, .lower)}) catch unreachable;
    return hex;
}

fn cachePath(hashed_key: *const [HASHED_KEY_LEN]u8) [HASHED_PATH_LEN]u8 {
    var path: [HASHED_PATH_LEN]u8 = undefined;
    _ = std.fmt.bufPrint(&path, "{s}.cache", .{hashed_key}) catch unreachable;
    return path;
}

fn cacheTmpPath(hashed_key: *const [HASHED_KEY_LEN]u8) [HASHED_TMP_PATH_LEN]u8 {
    var path: [HASHED_TMP_PATH_LEN]u8 = undefined;
    _ = std.fmt.bufPrint(&path, "{s}.cache.tmp", .{hashed_key}) catch unreachable;
    return path;
}

pub fn init(path: []const u8) !FsCache {
    const cwd = std.fs.cwd();

    cwd.makeDir(path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    const dir = try cwd.openDir(path, .{ .iterate = true });
    return .{ .dir = dir };
}

pub fn deinit(self: *FsCache) void {
    self.dir.close();
}

pub fn get(self: *FsCache, arena: std.mem.Allocator, req: CacheRequest) ?Cache.CachedResponse {
    const hashed_key = hashKey(req.url);
    const cache_p = cachePath(&hashed_key);

    const lock = self.getLockPtr(&hashed_key);
    lock.lock();
    defer lock.unlock();

    const file = self.dir.openFile(&cache_p, .{ .mode = .read_only }) catch |e| {
        switch (e) {
            std.fs.File.OpenError.FileNotFound => {
                log.debug(.cache, "miss", .{ .url = req.url, .hash = &hashed_key, .reason = "missing" });
            },
            else => |err| {
                log.warn(.cache, "open file err", .{ .url = req.url, .err = err });
            },
        }
        return null;
    };

    var cleanup = false;
    defer if (cleanup) {
        file.close();
        self.dir.deleteFile(&cache_p) catch |e| {
            log.err(.cache, "clean fail", .{ .url = req.url, .file = &cache_p, .err = e });
        };
    };

    var file_buf: [1024]u8 = undefined;
    var len_buf: [BODY_LEN_HEADER_LEN]u8 = undefined;

    var file_reader = file.reader(&file_buf);
    const file_reader_iface = &file_reader.interface;

    file_reader_iface.readSliceAll(&len_buf) catch |e| {
        log.warn(.cache, "read header", .{ .url = req.url, .err = e });
        cleanup = true;
        return null;
    };
    const body_len = std.mem.readInt(u64, &len_buf, .little);

    // Now we read metadata.
    file_reader.seekTo(body_len + BODY_LEN_HEADER_LEN) catch |e| {
        log.warn(.cache, "seek metadata", .{ .url = req.url, .err = e });
        cleanup = true;
        return null;
    };

    var json_reader = std.json.Reader.init(arena, file_reader_iface);
    const cache_file: CacheMetadataJson = std.json.parseFromTokenSourceLeaky(
        CacheMetadataJson,
        arena,
        &json_reader,
        .{ .allocate = .alloc_always },
    ) catch |e| {
        // Warn because malformed metadata can be a deeper symptom.
        log.warn(.cache, "miss", .{ .url = req.url, .err = e, .reason = "malformed metadata" });
        cleanup = true;
        return null;
    };

    if (cache_file.version != CACHE_VERSION) {
        log.debug(.cache, "miss", .{
            .url = req.url,
            .reason = "version mismatch",
            .expected = CACHE_VERSION,
            .got = cache_file.version,
        });
        cleanup = true;
        return null;
    }

    const metadata = cache_file.metadata;

    // Check entry expiration.
    const now = req.timestamp;
    const age = (now - metadata.stored_at) + @as(i64, @intCast(metadata.age_at_store));
    if (age < 0 or @as(u64, @intCast(age)) >= metadata.cache_control.max_age) {
        log.debug(.cache, "miss", .{ .url = req.url, .reason = "expired" });
        cleanup = true;
        return null;
    }

    // If we have Vary headers, ensure they are present & matching.
    for (metadata.vary_headers) |vary_hdr| {
        const name = vary_hdr.name;
        const value = vary_hdr.value;

        const incoming = for (req.request_headers) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, name)) break h.value;
        } else "";

        if (!std.ascii.eqlIgnoreCase(value, incoming)) {
            log.debug(.cache, "miss", .{
                .url = req.url,
                .reason = "vary mismatch",
                .header = name,
                .expected = value,
                .got = incoming,
            });
            return null;
        }
    }

    // On the case of a hash collision.
    if (!std.ascii.eqlIgnoreCase(metadata.url, req.url)) {
        log.warn(.cache, "collision", .{ .url = req.url, .expected = metadata.url, .got = req.url });
        cleanup = true;
        return null;
    }

    log.debug(.cache, "hit", .{ .url = req.url, .hash = &hashed_key });

    return .{
        .metadata = metadata,
        .data = .{
            .file = .{
                .file = file,
                .offset = BODY_LEN_HEADER_LEN,
                .len = body_len,
            },
        },
    };
}

pub fn put(self: *FsCache, meta: CachedMetadata, body: []const u8) !void {
    const hashed_key = hashKey(meta.url);
    const cache_p = cachePath(&hashed_key);
    const cache_tmp_p = cacheTmpPath(&hashed_key);

    const lock = self.getLockPtr(&hashed_key);
    lock.lock();
    defer lock.unlock();

    const file = self.dir.createFile(&cache_tmp_p, .{ .truncate = true }) catch |e| {
        log.err(.cache, "create file", .{ .url = meta.url, .file = &cache_tmp_p, .err = e });
        return e;
    };
    defer file.close();

    var writer_buf: [1024]u8 = undefined;
    var file_writer = file.writer(&writer_buf);
    var file_writer_iface = &file_writer.interface;

    var len_buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &len_buf, body.len, .little);

    file_writer_iface.writeAll(&len_buf) catch |e| {
        log.err(.cache, "write body len", .{ .url = meta.url, .err = e });
        return e;
    };
    file_writer_iface.writeAll(body) catch |e| {
        log.err(.cache, "write body", .{ .url = meta.url, .err = e });
        return e;
    };
    std.json.Stringify.value(
        CacheMetadataJson{ .version = CACHE_VERSION, .metadata = meta },
        .{ .whitespace = .minified },
        file_writer_iface,
    ) catch |e| {
        log.err(.cache, "write metadata", .{ .url = meta.url, .err = e });
        return e;
    };
    file_writer_iface.flush() catch |e| {
        log.err(.cache, "flush", .{ .url = meta.url, .err = e });
        return e;
    };
    self.dir.rename(&cache_tmp_p, &cache_p) catch |e| {
        log.err(.cache, "rename", .{ .url = meta.url, .from = &cache_tmp_p, .to = &cache_p, .err = e });
        return e;
    };

    log.debug(.cache, "put", .{ .url = meta.url, .hash = &hashed_key, .body_len = body.len });
}

const testing = std.testing;

fn setupCache() !struct { tmp: testing.TmpDir, cache: Cache } {
    var tmp = testing.tmpDir(.{});
    errdefer tmp.cleanup();

    const path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(path);

    return .{
        .tmp = tmp,
        .cache = Cache{ .kind = .{ .fs = try FsCache.init(path) } },
    };
}

test "FsCache: basic put and get" {
    var setup = try setupCache();
    defer {
        setup.cache.deinit();
        setup.tmp.cleanup();
    }

    const cache = &setup.cache;

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

    const body = "hello world";
    try cache.put(meta, body);

    const result = cache.get(
        arena.allocator(),
        .{
            .url = "https://example.com",
            .timestamp = now,
            .request_headers = &.{},
        },
    ) orelse return error.CacheMiss;
    const f = result.data.file;
    const file = f.file;
    defer file.close();

    var buf: [64]u8 = undefined;
    var file_reader = file.reader(&buf);
    try file_reader.seekTo(f.offset);

    const read_buf = try file_reader.interface.readAlloc(testing.allocator, f.len);
    defer testing.allocator.free(read_buf);
    try testing.expectEqualStrings(body, read_buf);
}

test "FsCache: get expiration" {
    var setup = try setupCache();
    defer {
        setup.cache.deinit();
        setup.tmp.cleanup();
    }

    const cache = &setup.cache;

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

    const body = "hello world";
    try cache.put(meta, body);

    const result = cache.get(
        arena.allocator(),
        .{
            .url = "https://example.com",
            .timestamp = now + 50,
            .request_headers = &.{},
        },
    ) orelse return error.CacheMiss;
    result.data.file.file.close();

    try testing.expectEqual(null, cache.get(
        arena.allocator(),
        .{
            .url = "https://example.com",
            .timestamp = now + 200,
            .request_headers = &.{},
        },
    ));

    try testing.expectEqual(null, cache.get(
        arena.allocator(),
        .{
            .url = "https://example.com",
            .timestamp = now,
            .request_headers = &.{},
        },
    ));
}

test "FsCache: put override" {
    var setup = try setupCache();
    defer {
        setup.cache.deinit();
        setup.tmp.cleanup();
    }

    const cache = &setup.cache;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    {
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

        const body = "hello world";
        try cache.put(meta, body);

        const result = cache.get(
            arena.allocator(),
            .{
                .url = "https://example.com",
                .timestamp = now,
                .request_headers = &.{},
            },
        ) orelse return error.CacheMiss;
        const f = result.data.file;
        const file = f.file;
        defer file.close();

        var buf: [64]u8 = undefined;
        var file_reader = file.reader(&buf);
        try file_reader.seekTo(f.offset);

        const read_buf = try file_reader.interface.readAlloc(testing.allocator, f.len);
        defer testing.allocator.free(read_buf);

        try testing.expectEqualStrings(body, read_buf);
    }

    {
        const now = 10000;
        const max_age = 2000;

        const meta = CachedMetadata{
            .url = "https://example.com",
            .content_type = "text/html",
            .status = 200,
            .stored_at = now,
            .age_at_store = 0,
            .cache_control = .{ .max_age = max_age },
            .headers = &.{},
            .vary_headers = &.{},
        };

        const body = "goodbye world";
        try cache.put(meta, body);

        const result = cache.get(
            arena.allocator(),
            .{
                .url = "https://example.com",
                .timestamp = now,
                .request_headers = &.{},
            },
        ) orelse return error.CacheMiss;
        const f = result.data.file;
        const file = f.file;
        defer file.close();

        var buf: [64]u8 = undefined;
        var file_reader = file.reader(&buf);
        try file_reader.seekTo(f.offset);

        const read_buf = try file_reader.interface.readAlloc(testing.allocator, f.len);
        defer testing.allocator.free(read_buf);

        try testing.expectEqualStrings(body, read_buf);
    }
}

test "FsCache: garbage file" {
    const LogFilter = @import("../../testing.zig").LogFilter;
    const filter: LogFilter = .init(&.{.cache});
    defer filter.deinit();

    var setup = try setupCache();
    defer {
        setup.cache.deinit();
        setup.tmp.cleanup();
    }

    const hashed_key = hashKey("https://example.com");
    const cache_p = cachePath(&hashed_key);
    const file = try setup.cache.kind.fs.dir.createFile(&cache_p, .{});
    try file.writeAll("this is not a valid cache file !@#$%");
    file.close();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    try testing.expectEqual(
        null,
        setup.cache.get(arena.allocator(), .{
            .url = "https://example.com",
            .timestamp = 5000,
            .request_headers = &.{},
        }),
    );
}

test "FsCache: vary hit and miss" {
    var setup = try setupCache();
    defer {
        setup.cache.deinit();
        setup.tmp.cleanup();
    }

    const cache = &setup.cache;

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

    const result = cache.get(arena.allocator(), .{
        .url = "https://example.com",
        .timestamp = now,
        .request_headers = &.{
            .{ .name = "Accept-Encoding", .value = "gzip" },
        },
    }) orelse return error.CacheMiss;
    result.data.file.file.close();

    try testing.expectEqual(null, cache.get(arena.allocator(), .{
        .url = "https://example.com",
        .timestamp = now,
        .request_headers = &.{
            .{ .name = "Accept-Encoding", .value = "br" },
        },
    }));

    try testing.expectEqual(null, cache.get(arena.allocator(), .{
        .url = "https://example.com",
        .timestamp = now,
        .request_headers = &.{},
    }));

    const result2 = cache.get(arena.allocator(), .{
        .url = "https://example.com",
        .timestamp = now,
        .request_headers = &.{
            .{ .name = "Accept-Encoding", .value = "gzip" },
        },
    }) orelse return error.CacheMiss;
    result2.data.file.file.close();
}

test "FsCache: vary multiple headers" {
    var setup = try setupCache();
    defer {
        setup.cache.deinit();
        setup.tmp.cleanup();
    }

    const cache = &setup.cache;

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

    const result = cache.get(arena.allocator(), .{
        .url = "https://example.com",
        .timestamp = now,
        .request_headers = &.{
            .{ .name = "Accept-Encoding", .value = "gzip" },
            .{ .name = "Accept-Language", .value = "en" },
        },
    }) orelse return error.CacheMiss;
    result.data.file.file.close();

    try testing.expectEqual(null, cache.get(arena.allocator(), .{
        .url = "https://example.com",
        .timestamp = now,
        .request_headers = &.{
            .{ .name = "Accept-Encoding", .value = "gzip" },
            .{ .name = "Accept-Language", .value = "fr" },
        },
    }));
}
