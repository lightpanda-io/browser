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
const CachedMetadata = Cache.CachedMetadata;
const CachedResponse = Cache.CachedResponse;

pub const FsCache = @This();

allocator: std.mem.Allocator,
dir: std.fs.Dir,

const MAX_CACHE_SIZE_BYTES = 1024 * 1024 * 1024;

pub fn init(allocator: std.mem.Allocator, path: []const u8) !FsCache {
    const cwd = std.fs.cwd();

    cwd.makeDir(path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    const dir = try cwd.openDir(path, .{ .iterate = true });
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
    _ = std.fmt.bufPrint(&hex, "{s}", .{std.fmt.bytesToHex(&digest, .lower)}) catch unreachable;
    return hex;
}

fn serializeMeta(writer: *std.Io.Writer, meta: *const CachedMetadata) !void {
    try writer.print("{d}\n{d}\n{d}\n{d}\n", .{
        meta.status,
        meta.stored_at,
        meta.age_at_store,
        meta.max_age,
    });
    try writer.print("{s}\n", .{meta.etag orelse "null"});
    try writer.print("{s}\n", .{meta.last_modified orelse "null"});
    try writer.print("{s}\n", .{meta.vary orelse "null"});
    try writer.print("{}\n{}\n{}\n", .{
        meta.must_revalidate,
        meta.no_cache,
        meta.immutable,
    });
}

fn deserializeMetaOptionalString(bytes: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, bytes, "null")) return null else return bytes;
}

fn deserializeMetaBoolean(bytes: []const u8) !bool {
    if (std.mem.eql(u8, bytes, "true")) return true;
    if (std.mem.eql(u8, bytes, "false")) return false;
    return error.Malformed;
}

fn deserializeMeta(allocator: std.mem.Allocator, bytes: []const u8) !CachedMetadata {
    _ = allocator;

    var iter = std.mem.splitScalar(u8, bytes, '\n');

    const status = std.fmt.parseInt(
        u16,
        iter.next() orelse return error.Malformed,
        10,
    ) catch return error.Malformed;
    const stored_at = std.fmt.parseInt(
        i64,
        iter.next() orelse return error.Malformed,
        10,
    ) catch return error.Malformed;
    const age_at_store = std.fmt.parseInt(
        u64,
        iter.next() orelse return error.Malformed,
        10,
    ) catch return error.Malformed;
    const max_age = std.fmt.parseInt(
        u64,
        iter.next() orelse return error.Malformed,
        10,
    ) catch return error.Malformed;

    const etag = deserializeMetaOptionalString(
        iter.next() orelse return error.Malformed,
    );

    const last_modified = deserializeMetaOptionalString(
        iter.next() orelse return error.Malformed,
    );

    const vary = deserializeMetaOptionalString(
        iter.next() orelse return error.Malformed,
    );

    const must_revalidate = try deserializeMetaBoolean(
        iter.next() orelse return error.Malformed,
    );
    const no_cache = try deserializeMetaBoolean(
        iter.next() orelse return error.Malformed,
    );
    const immutable = try deserializeMetaBoolean(
        iter.next() orelse return error.Malformed,
    );

    return .{
        .status = status,
        .stored_at = stored_at,
        .age_at_store = age_at_store,
        .max_age = max_age,
        .etag = etag,
        .last_modified = last_modified,
        .must_revalidate = must_revalidate,
        .no_cache = no_cache,
        .immutable = immutable,
        .vary = vary,
    };
}

pub fn get(ptr: *anyopaque, key: []const u8) ?Cache.CachedResponse {
    const self: *FsCache = @ptrCast(@alignCast(ptr));
    const hashed_key = hashKey(key);

    var meta_path: [64 + 5]u8 = undefined;
    _ = std.fmt.bufPrint(&meta_path, "{s}.meta", .{hashed_key}) catch @panic("FsCache.get meta path overflowed");

    var body_path: [64 + 5]u8 = undefined;
    _ = std.fmt.bufPrint(&body_path, "{s}.body", .{hashed_key}) catch @panic("FsCache.get body path overflowed");

    const meta_bytes = self.dir.readFileAlloc(
        self.allocator,
        &meta_path,
        MAX_CACHE_SIZE_BYTES,
    ) catch return null;

    const meta = deserializeMeta(self.allocator, meta_bytes) catch return null;

    // Ensure age is still valid.
    const now = std.time.timestamp();
    const age = meta.age_at_store + @as(u64, @intCast(now - meta.stored_at));
    if (age > meta.max_age) {
        self.dir.deleteFile(&meta_path) catch {};
        self.dir.deleteFile(&body_path) catch {};
        return null;
    }

    const body = self.dir.readFileAlloc(
        self.allocator,
        &body_path,
        MAX_CACHE_SIZE_BYTES,
    ) catch return null;

    return .{ .metadata = meta, .data = .{ .file = body } };
}

pub fn put(ptr: *anyopaque, key: []const u8, response: CachedResponse) !void {
    const self: *FsCache = @ptrCast(@alignCast(ptr));
    const hashed_key = hashKey(key);

    // Write meta to a temp file, then atomically rename into place
    var meta_path: [64 + 5]u8 = undefined;
    _ = std.fmt.bufPrint(&meta_path, "{s}.meta", .{hashed_key}) catch
        @panic("FsCache.put meta path overflowed");

    var meta_tmp_path: [64 + 9]u8 = undefined;
    _ = std.fmt.bufPrint(&meta_tmp_path, "{s}.meta.tmp", .{hashed_key}) catch
        @panic("FsCache.put meta tmp path overflowed");

    {
        const meta_file = try self.dir.createFile(&meta_tmp_path, .{});
        errdefer {
            meta_file.close();
            self.dir.deleteFile(&meta_tmp_path) catch {};
        }

        var buf: [512]u8 = undefined;
        var meta_file_writer = meta_file.writer(&buf);
        try serializeMeta(&meta_file_writer.interface, &response.metadata);
        meta_file.close();
    }
    errdefer self.dir.deleteFile(&meta_tmp_path) catch {};
    try self.dir.rename(&meta_tmp_path, &meta_path);

    // Write body to a temp file, then atomically rename into place
    var body_path: [64 + 5]u8 = undefined;
    _ = std.fmt.bufPrint(&body_path, "{s}.body", .{hashed_key}) catch
        @panic("FsCache.put body path overflowed");

    var body_tmp_path: [64 + 9]u8 = undefined;
    _ = std.fmt.bufPrint(&body_tmp_path, "{s}.body.tmp", .{hashed_key}) catch
        @panic("FsCache.put body tmp path overflowed");

    {
        const body_file = try self.dir.createFile(&body_tmp_path, .{});
        errdefer {
            body_file.close();
            self.dir.deleteFile(&body_tmp_path) catch {};
        }
        try body_file.writeAll(response.data.file);
        body_file.close();
    }
    errdefer self.dir.deleteFile(&body_tmp_path) catch {};

    errdefer self.dir.deleteFile(&meta_path) catch {};
    try self.dir.rename(&body_tmp_path, &body_path);
}
