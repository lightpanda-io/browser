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
const CachedMetadata = Cache.CachedMetadata;
const CachedResponse = Cache.CachedResponse;

pub const FsCache = @This();

dir: std.fs.Dir,

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

pub fn cache(self: *FsCache) Cache {
    return Cache.init(self);
}

const HASHED_KEY_LEN = 16;
const HASHED_PATH_LEN = HASHED_KEY_LEN + 5;
const HASHED_TMP_PATH_LEN = HASHED_PATH_LEN + 4;

fn hashKey(key: []const u8) [HASHED_KEY_LEN]u8 {
    const h = std.hash.Wyhash.hash(0, key);
    var hex: [HASHED_KEY_LEN]u8 = undefined;
    _ = std.fmt.bufPrint(&hex, "{x:0>16}", .{h}) catch unreachable;
    return hex;
}

fn serializeMeta(writer: *std.Io.Writer, meta: *const CachedMetadata) !void {
    try writer.print("{s}\n{s}\n", .{ meta.url, meta.content_type });
    try writer.print("{d}\n{d}\n{d}\n", .{
        meta.status,
        meta.stored_at,
        meta.age_at_store,
    });
    try writer.print("{s}\n", .{meta.etag orelse "null"});
    try writer.print("{s}\n", .{meta.last_modified orelse "null"});

    // cache-control
    try writer.print("{d}\n", .{meta.cache_control.max_age orelse 0});
    try writer.print("{}\n{}\n{}\n{}\n", .{
        meta.cache_control.max_age != null,
        meta.cache_control.must_revalidate,
        meta.cache_control.no_cache,
        meta.cache_control.immutable,
    });

    // vary
    if (meta.vary) |v| {
        try writer.print("{s}\n", .{v.toString()});
    } else {
        try writer.print("null\n", .{});
    }
    try writer.flush();

    try writer.print("{d}\n", .{meta.headers.len});
    for (meta.headers) |hdr| {
        try writer.print("{s}\n{s}\n", .{ hdr.name, hdr.value });
        try writer.flush();
    }
    try writer.flush();
}

fn deserializeMetaOptionalString(bytes: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, bytes, "null")) return null else return bytes;
}

fn deserializeMetaBoolean(bytes: []const u8) !bool {
    if (std.mem.eql(u8, bytes, "true")) return true;
    if (std.mem.eql(u8, bytes, "false")) return false;
    return error.Malformed;
}

fn deserializeMeta(allocator: std.mem.Allocator, file: std.fs.File) !CachedMetadata {
    var file_buf: [1024]u8 = undefined;
    var file_reader = file.reader(&file_buf);
    const reader = &file_reader.interface;

    const url = blk: {
        const line = try reader.takeDelimiter('\n') orelse return error.Malformed;
        break :blk try allocator.dupeZ(u8, line);
    };
    errdefer allocator.free(url);

    const content_type = blk: {
        const line = try reader.takeDelimiter('\n') orelse return error.Malformed;
        break :blk try allocator.dupe(u8, line);
    };
    errdefer allocator.free(content_type);

    const status = blk: {
        const line = try reader.takeDelimiter('\n') orelse return error.Malformed;
        break :blk std.fmt.parseInt(u16, line, 10) catch return error.Malformed;
    };
    const stored_at = blk: {
        const line = try reader.takeDelimiter('\n') orelse return error.Malformed;
        break :blk std.fmt.parseInt(i64, line, 10) catch return error.Malformed;
    };
    const age_at_store = blk: {
        const line = try reader.takeDelimiter('\n') orelse return error.Malformed;
        break :blk std.fmt.parseInt(u64, line, 10) catch return error.Malformed;
    };

    const etag = blk: {
        const line = try reader.takeDelimiter('\n') orelse return error.Malformed;
        break :blk if (std.mem.eql(u8, line, "null")) null else try allocator.dupe(u8, line);
    };
    errdefer if (etag) |e| allocator.free(e);

    const last_modified = blk: {
        const line = try reader.takeDelimiter('\n') orelse return error.Malformed;
        break :blk if (std.mem.eql(u8, line, "null")) null else try allocator.dupe(u8, line);
    };
    errdefer if (last_modified) |lm| allocator.free(lm);

    // cache-control
    const cc = cache_control: {
        const max_age_val = blk: {
            const line = try reader.takeDelimiter('\n') orelse return error.Malformed;
            break :blk std.fmt.parseInt(u64, line, 10) catch return error.Malformed;
        };
        const max_age_present = blk: {
            const line = try reader.takeDelimiter('\n') orelse return error.Malformed;
            break :blk try deserializeMetaBoolean(line);
        };
        const must_revalidate = blk: {
            const line = try reader.takeDelimiter('\n') orelse return error.Malformed;
            break :blk try deserializeMetaBoolean(line);
        };
        const no_cache = blk: {
            const line = try reader.takeDelimiter('\n') orelse return error.Malformed;
            break :blk try deserializeMetaBoolean(line);
        };
        const immutable = blk: {
            const line = try reader.takeDelimiter('\n') orelse return error.Malformed;
            break :blk try deserializeMetaBoolean(line);
        };
        break :cache_control Cache.CacheControl{
            .max_age = if (max_age_present) max_age_val else null,
            .must_revalidate = must_revalidate,
            .no_cache = no_cache,
            .immutable = immutable,
        };
    };

    // vary
    const vary = blk: {
        const line = try reader.takeDelimiter('\n') orelse return error.Malformed;
        if (std.mem.eql(u8, line, "null")) break :blk null;
        const duped = try allocator.dupe(u8, line);
        break :blk Cache.Vary.parse(duped);
    };
    errdefer if (vary) |v| if (v == .value) allocator.free(v.value);

    const headers = blk: {
        const line = try reader.takeDelimiter('\n') orelse return error.Malformed;
        const count = std.fmt.parseInt(usize, line, 10) catch return error.Malformed;

        const hdrs = try allocator.alloc(Http.Header, count);
        errdefer allocator.free(hdrs);

        for (hdrs) |*hdr| {
            const name = try reader.takeDelimiter('\n') orelse return error.Malformed;
            const value = try reader.takeDelimiter('\n') orelse return error.Malformed;
            hdr.* = .{
                .name = try allocator.dupe(u8, name),
                .value = try allocator.dupe(u8, value),
            };
        }

        break :blk hdrs;
    };
    errdefer {
        for (headers) |hdr| {
            allocator.free(hdr.name);
            allocator.free(hdr.value);
        }
        allocator.free(headers);
    }

    return .{
        .url = url,
        .content_type = content_type,
        .status = status,
        .stored_at = stored_at,
        .age_at_store = age_at_store,
        .cache_control = cc,
        .etag = etag,
        .last_modified = last_modified,
        .vary = vary,
        .headers = headers,
    };
}

pub fn get(self: *FsCache, allocator: std.mem.Allocator, key: []const u8) ?Cache.CachedResponse {
    const hashed_key = hashKey(key);

    var meta_path: [HASHED_PATH_LEN]u8 = undefined;
    _ = std.fmt.bufPrint(&meta_path, "{s}.meta", .{hashed_key}) catch @panic("FsCache.get meta path overflowed");

    var body_path: [HASHED_PATH_LEN]u8 = undefined;
    _ = std.fmt.bufPrint(&body_path, "{s}.body", .{hashed_key}) catch @panic("FsCache.get body path overflowed");

    const meta_file = self.dir.openFile(&meta_path, .{ .mode = .read_only }) catch return null;
    defer meta_file.close();

    const meta = deserializeMeta(allocator, meta_file) catch {
        self.dir.deleteFile(&meta_path) catch {};
        self.dir.deleteFile(&body_path) catch {};
        return null;
    };

    const body_file = self.dir.openFile(&body_path, .{ .mode = .read_only }) catch return null;

    return .{
        .metadata = meta,
        .data = .{ .file = body_file },
    };
}

pub fn put(self: *FsCache, key: []const u8, meta: CachedMetadata, body: []const u8) !void {
    const hashed_key = hashKey(key);

    // Write meta to a temp file, then atomically rename into place
    var meta_path: [HASHED_PATH_LEN]u8 = undefined;
    _ = std.fmt.bufPrint(&meta_path, "{s}.meta", .{hashed_key}) catch
        @panic("FsCache.put meta path overflowed");

    var meta_tmp_path: [HASHED_TMP_PATH_LEN]u8 = undefined;
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
        try serializeMeta(&meta_file_writer.interface, &meta);
        meta_file.close();
    }
    errdefer self.dir.deleteFile(&meta_tmp_path) catch {};
    try self.dir.rename(&meta_tmp_path, &meta_path);

    // Write body to a temp file, then atomically rename into place
    var body_path: [HASHED_PATH_LEN]u8 = undefined;
    _ = std.fmt.bufPrint(&body_path, "{s}.body", .{hashed_key}) catch
        @panic("FsCache.put body path overflowed");

    var body_tmp_path: [HASHED_TMP_PATH_LEN]u8 = undefined;
    _ = std.fmt.bufPrint(&body_tmp_path, "{s}.body.tmp", .{hashed_key}) catch
        @panic("FsCache.put body tmp path overflowed");

    {
        const body_file = try self.dir.createFile(&body_tmp_path, .{});
        errdefer {
            body_file.close();
            self.dir.deleteFile(&body_tmp_path) catch {};
        }
        try body_file.writeAll(body);
        body_file.close();
    }
    errdefer self.dir.deleteFile(&body_tmp_path) catch {};

    errdefer self.dir.deleteFile(&meta_path) catch {};
    try self.dir.rename(&body_tmp_path, &body_path);
}
