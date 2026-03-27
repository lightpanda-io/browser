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
const Http = @import("../http.zig");
const CacheRequest = Cache.CacheRequest;
const CachedMetadata = Cache.CachedMetadata;
const CachedResponse = Cache.CachedResponse;

const CACHE_VERSION: usize = 1;
const LOCK_STRIPES = 16;

pub const FsCache = @This();

dir: std.fs.Dir,
locks: [LOCK_STRIPES]std.Thread.Mutex = .{std.Thread.Mutex{}} ** LOCK_STRIPES,

const CacheMetadataFile = struct {
    version: usize,
    metadata: CachedMetadata,
};

fn getLockPtr(self: *FsCache, key: *const [HASHED_KEY_LEN]u8) *std.Thread.Mutex {
    const lock_idx: usize = @truncate(std.hash.Wyhash.hash(0, key) % LOCK_STRIPES);
    return &self.locks[lock_idx];
}

const HASHED_KEY_LEN = 64;
const HASHED_PATH_LEN = HASHED_KEY_LEN + 5;
const HASHED_TMP_PATH_LEN = HASHED_PATH_LEN + 4;

fn hashKey(key: []const u8) [HASHED_KEY_LEN]u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(key, &digest, .{});
    var hex: [HASHED_KEY_LEN]u8 = undefined;
    _ = std.fmt.bufPrint(&hex, "{s}", .{std.fmt.bytesToHex(&digest, .lower)}) catch unreachable;
    return hex;
}

fn metaPath(hashed_key: *const [HASHED_KEY_LEN]u8) [HASHED_PATH_LEN]u8 {
    var path: [HASHED_PATH_LEN]u8 = undefined;
    _ = std.fmt.bufPrint(&path, "{s}.meta", .{hashed_key}) catch unreachable;
    return path;
}

fn bodyPath(hashed_key: *const [HASHED_KEY_LEN]u8) [HASHED_PATH_LEN]u8 {
    var path: [HASHED_PATH_LEN]u8 = undefined;
    _ = std.fmt.bufPrint(&path, "{s}.body", .{hashed_key}) catch unreachable;
    return path;
}

fn metaTmpPath(hashed_key: *const [HASHED_KEY_LEN]u8) [HASHED_TMP_PATH_LEN]u8 {
    var path: [HASHED_TMP_PATH_LEN]u8 = undefined;
    _ = std.fmt.bufPrint(&path, "{s}.meta.tmp", .{hashed_key}) catch unreachable;
    return path;
}

fn bodyTmpPath(hashed_key: *const [HASHED_KEY_LEN]u8) [HASHED_TMP_PATH_LEN]u8 {
    var path: [HASHED_TMP_PATH_LEN]u8 = undefined;
    _ = std.fmt.bufPrint(&path, "{s}.body.tmp", .{hashed_key}) catch unreachable;
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
    const meta_p = metaPath(&hashed_key);
    const body_p = bodyPath(&hashed_key);

    const lock = self.getLockPtr(&hashed_key);
    lock.lock();
    defer lock.unlock();

    const meta_file = self.dir.openFile(&meta_p, .{ .mode = .read_only }) catch return null;
    defer meta_file.close();

    const contents = meta_file.readToEndAlloc(arena, 1 * 1024 * 1024) catch return null;
    defer arena.free(contents);

    const cache_file: CacheMetadataFile = std.json.parseFromSliceLeaky(
        CacheMetadataFile,
        arena,
        contents,
        .{ .allocate = .alloc_always },
    ) catch {
        self.dir.deleteFile(&meta_p) catch {};
        self.dir.deleteFile(&body_p) catch {};
        return null;
    };

    const metadata = cache_file.metadata;

    if (cache_file.version != CACHE_VERSION) {
        self.dir.deleteFile(&meta_p) catch {};
        self.dir.deleteFile(&body_p) catch {};
        return null;
    }

    const now = req.timestamp;
    const age = (now - metadata.stored_at) + @as(i64, @intCast(metadata.age_at_store));
    if (age < 0 or @as(u64, @intCast(age)) >= metadata.cache_control.max_age) {
        self.dir.deleteFile(&meta_p) catch {};
        self.dir.deleteFile(&body_p) catch {};
        return null;
    }

    const body_file = self.dir.openFile(
        &body_p,
        .{ .mode = .read_only },
    ) catch return null;

    return .{
        .metadata = metadata,
        .data = .{ .file = body_file },
    };
}

pub fn put(self: *FsCache, meta: CachedMetadata, body: []const u8) !void {
    const hashed_key = hashKey(meta.url);
    const meta_p = metaPath(&hashed_key);
    const meta_tmp_p = metaTmpPath(&hashed_key);
    const body_p = bodyPath(&hashed_key);
    const body_tmp_p = bodyTmpPath(&hashed_key);
    var writer_buf: [512]u8 = undefined;

    const lock = self.getLockPtr(&hashed_key);
    lock.lock();
    defer lock.unlock();

    {
        const meta_file = try self.dir.createFile(&meta_tmp_p, .{});
        errdefer {
            meta_file.close();
            self.dir.deleteFile(&meta_tmp_p) catch {};
        }

        var meta_file_writer = meta_file.writer(&writer_buf);
        const meta_file_writer_iface = &meta_file_writer.interface;
        try std.json.Stringify.value(
            CacheMetadataFile{ .version = CACHE_VERSION, .metadata = meta },
            .{ .whitespace = .minified },
            meta_file_writer_iface,
        );
        try meta_file_writer_iface.flush();
        meta_file.close();
    }
    errdefer self.dir.deleteFile(&meta_tmp_p) catch {};
    try self.dir.rename(&meta_tmp_p, &meta_p);

    {
        const body_file = try self.dir.createFile(&body_tmp_p, .{});
        errdefer {
            body_file.close();
            self.dir.deleteFile(&body_tmp_p) catch {};
        }

        var body_file_writer = body_file.writer(&writer_buf);
        const body_file_writer_iface = &body_file_writer.interface;
        try body_file_writer_iface.writeAll(body);
        try body_file_writer_iface.flush();
        body_file.close();
    }
    errdefer self.dir.deleteFile(&body_tmp_p) catch {};

    errdefer self.dir.deleteFile(&meta_p) catch {};
    try self.dir.rename(&body_tmp_p, &body_p);
}

const testing = std.testing;

test "FsCache: basic put and get" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(path);

    var fs_cache = try FsCache.init(path);
    defer fs_cache.deinit();
    var cache = Cache{ .kind = .{ .fs = fs_cache } };

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const now = std.time.timestamp();
    const meta = CachedMetadata{
        .url = "https://example.com",
        .content_type = "text/html",
        .status = 200,
        .stored_at = now,
        .age_at_store = 0,
        .etag = null,
        .last_modified = null,
        .cache_control = .{ .max_age = 600 },
        .vary = null,
        .headers = &.{},
    };

    const body = "hello world";
    try cache.put(meta, body);

    const result = cache.get(arena.allocator(), .{ .url = "https://example.com", .timestamp = now }) orelse return error.CacheMiss;
    defer result.data.file.close();

    var buf: [64]u8 = undefined;
    var file_reader = result.data.file.reader(&buf);

    const read_buf = try file_reader.interface.allocRemaining(testing.allocator, .unlimited);
    defer testing.allocator.free(read_buf);

    try testing.expectEqualStrings(body, read_buf);
}

test "FsCache: get expiration" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(path);

    var fs_cache = try FsCache.init(path);
    defer fs_cache.deinit();
    var cache = Cache{ .kind = .{ .fs = fs_cache } };

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
        .etag = null,
        .last_modified = null,
        .cache_control = .{ .max_age = max_age },
        .vary = null,
        .headers = &.{},
    };

    const body = "hello world";
    try cache.put(meta, body);

    const result = cache.get(
        arena.allocator(),
        .{ .url = "https://example.com", .timestamp = now + 50 },
    ) orelse return error.CacheMiss;
    result.data.file.close();

    try testing.expectEqual(null, cache.get(
        arena.allocator(),
        .{ .url = "https://example.com", .timestamp = now + 200 },
    ));

    try testing.expectEqual(null, cache.get(
        arena.allocator(),
        .{ .url = "https://example.com", .timestamp = now },
    ));
}
