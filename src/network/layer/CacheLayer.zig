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

const Layer = @import("../../browser/HttpClient.zig").Layer;
const Transfer = @import("../../browser/HttpClient.zig").Transfer;
const Response = @import("../../browser/HttpClient.zig").Response;

const Cache = @import("../cache/Cache.zig");
const CachedMetadata = @import("../cache/Cache.zig").CachedMetadata;
const CachedResponse = @import("../cache/Cache.zig").CachedResponse;

const HeaderResult = @import("../../browser/HttpClient.zig").HeaderResult;
const Forward = @import("Forward.zig");

const log = lp.log;
const IS_DEBUG = @import("builtin").mode == .Debug;

const CacheLayer = @This();

next: Layer = undefined,
disabled: bool = false,

pub fn layer(self: *CacheLayer) Layer {
    return .{
        .ptr = self,
        .vtable = &.{
            .request = request,
        },
    };
}

fn request(ptr: *anyopaque, transfer: *Transfer) anyerror!void {
    const self: *CacheLayer = @ptrCast(@alignCast(ptr));
    const req = &transfer.req;

    if (self.disabled or req.method != .GET) {
        return self.next.request(transfer);
    }

    const arena = transfer.arena;

    var iter = req.headers.iterator();
    const req_header_list = try iter.collect(arena);

    const cached = transfer.client.network.cache.?.get(arena, .{
        .url = req.url,
        .timestamp = std.time.timestamp(),
        .request_headers = req_header_list.items,
    }) orelse {
        // Cache miss: install wrappers so we can inspect the response and decide
        // whether to write the body into the cache when it's done.
        try installCacheContext(arena, transfer, null);
        return self.next.request(transfer);
    };

    if (!cached.expired) {
        const ctx = try arena.create(CachedResponse);
        ctx.* = cached;

        try transfer.client.runNextTick(transfer, ctx, .{
            .run = struct {
                fn run(t: *Transfer, ctx_ptr: ?*anyopaque) void {
                    defer t.deinit();

                    const c: *CachedResponse = @ptrCast(@alignCast(ctx_ptr.?));
                    serveFromCache(t, c) catch |err| {
                        t.req.error_callback(t.req.ctx, err);
                    };
                }
            }.run,
            .abort = struct {
                fn abort(ctx_ptr: ?*anyopaque) void {
                    const c: *CachedResponse = @ptrCast(@alignCast(ctx_ptr.?));
                    switch (c.data) {
                        .buffer => |_| {},
                        .file => |f| f.file.close(),
                    }
                }
            }.abort,
        });
        return;
    }

    if (cached.metadata.hasValidators()) {
        if (cached.metadata.etag) |etag| {
            log.debug(.cache, "revalidate with etag", .{ .url = req.url, .etag = etag });
            const header_value = try std.fmt.allocPrintSentinel(arena, "If-None-Match: {s}", .{etag}, 0);
            try req.headers.add(header_value);
        }

        if (cached.metadata.last_modified) |lm| {
            log.debug(.cache, "revalidate with last-modified", .{ .url = req.url, .last_modified = lm });
            const header_value = try std.fmt.allocPrintSentinel(arena, "If-Modified-Since: {s}", .{lm}, 0);
            try req.headers.add(header_value);
        }

        try installCacheContext(arena, transfer, cached);
    } else {
        defer cached.data.deinit();
        // If it is expired w/o validators, evict from Cache.
        transfer.client.network.cache.?.evict(req.url);
        try installCacheContext(arena, transfer, null);
    }

    return self.next.request(transfer);
}

fn installCacheContext(
    arena: std.mem.Allocator,
    transfer: *Transfer,
    stale_entry: ?CachedResponse,
) !void {
    const req = &transfer.req;
    const ctx = try arena.create(CacheContext);
    ctx.* = .{
        .arena = arena,
        .transfer = transfer,
        .forward = Forward.capture(req),
        .req_url = req.url,
        .req_headers = req.headers,
        .stale_entry = stale_entry,
    };

    req.ctx = ctx;
    req.header_callback = CacheContext.headerCallback;
    req.data_callback = CacheContext.dataCallback;
    req.done_callback = CacheContext.doneCallback;
    req.error_callback = CacheContext.errorCallback;

    if (ctx.forward.start != null) req.start_callback = CacheContext.startCallback;
    if (ctx.forward.shutdown != null) req.shutdown_callback = CacheContext.shutdownCallback;
}

fn forwardFromCache(
    transfer: *Transfer,
    forward: *Forward,
    cached: *const CachedResponse,
) !void {
    transfer.req.notification.dispatch(
        .http_request_served_from_cache,
        &.{ .transfer = transfer },
    );

    const req = &transfer.req;
    const response = Response.fromCached(req.ctx, cached);
    defer cached.data.deinit();

    try forward.forwardStart(response);
    const result = try forward.forwardHeader(response);
    if (result == .abort) return error.Abort;

    switch (cached.data) {
        .buffer => |data| {
            if (data.len > 0) try forward.forwardData(response, data);
        },
        .file => |f| {
            const file = f.file;
            var buf: [1024]u8 = undefined;
            var file_reader = file.reader(&buf);
            try file_reader.seekTo(f.offset);
            const reader = &file_reader.interface;
            var read_buf: [1024]u8 = undefined;
            var remaining = f.len;
            while (remaining > 0) {
                const read_len = @min(read_buf.len, remaining);
                const n = try reader.readSliceShort(read_buf[0..read_len]);
                if (n == 0) break;
                remaining -= n;
                try forward.forwardData(response, read_buf[0..n]);
            }
        },
    }

    try forward.forwardDone();
}

fn serveFromCache(transfer: *Transfer, cached: *const CachedResponse) !void {
    transfer.req.notification.dispatch(
        .http_request_served_from_cache,
        &.{ .transfer = transfer },
    );

    const req = &transfer.req;
    const response = Response.fromCached(req.ctx, cached);
    defer cached.data.deinit();

    if (req.start_callback) |cb| {
        try cb(response);
    }

    const result = try req.header_callback(response);
    if (result == .abort) {
        return error.Abort;
    }

    switch (cached.data) {
        .buffer => |data| {
            if (data.len > 0) {
                try req.data_callback(response, data);
            }
        },
        .file => |f| {
            const file = f.file;
            var buf: [1024]u8 = undefined;
            var file_reader = file.reader(&buf);
            try file_reader.seekTo(f.offset);
            const reader = &file_reader.interface;
            var read_buf: [1024]u8 = undefined;
            var remaining = f.len;
            while (remaining > 0) {
                const read_len = @min(read_buf.len, remaining);
                const n = try reader.readSliceShort(read_buf[0..read_len]);
                if (n == 0) break;
                remaining -= n;
                try req.data_callback(response, read_buf[0..n]);
            }
        },
    }

    try req.done_callback(req.ctx);
}

const CacheContext = struct {
    arena: std.mem.Allocator,
    transfer: *Transfer,
    forward: Forward,
    req_url: [:0]const u8,
    req_headers: @import("../http.zig").Headers,
    pending_metadata: ?*CachedMetadata = null,
    stale_entry: ?CachedResponse = null,

    fn startCallback(response: Response) anyerror!void {
        const self: *CacheContext = @ptrCast(@alignCast(response.ctx));
        return self.forward.forwardStart(response);
    }

    fn dataCallback(response: Response, chunk: []const u8) anyerror!void {
        const self: *CacheContext = @ptrCast(@alignCast(response.ctx));
        return self.forward.forwardData(response, chunk);
    }

    fn headerCallback(response: Response) anyerror!HeaderResult {
        const self: *CacheContext = @ptrCast(@alignCast(response.ctx));

        // For non-transfer responses (fulfilled by interception, or future
        // cached-while-cached cases), there's nothing to inspect for caching
        // decisions — just forward.
        const transfer = switch (response.inner) {
            .transfer => |t| t,
            else => return self.forward.forwardHeader(response),
        };

        const arena = self.arena;
        const conn = transfer._conn.?;
        var rh = &transfer.res.header.?;

        if (self.stale_entry != null and rh.status == 304) {
            const stale = self.stale_entry.?;
            self.stale_entry = null;

            var iter = response.headerIterator();
            const headers = try iter.collect(arena);

            transfer.client.network.cache.?.renew(
                arena,
                .{
                    .url = self.req_url,
                    .timestamp = std.time.timestamp(),
                    .headers = headers.items,
                },
            ) catch |err| {
                log.warn(.cache, "renew failed", .{ .err = err });
            };

            try forwardFromCache(transfer, &self.forward, &stale);
            return .handled;
        }

        if (self.stale_entry) |stale| {
            stale.data.deinit();
            self.stale_entry = null;
        }

        const vary = if (conn.getResponseHeader("vary", 0)) |h| h.value else null;
        const maybe_cm = try Cache.tryCache(
            arena,
            std.time.timestamp(),
            self.req_url,
            rh.status,
            rh.contentType(),
            if (conn.getResponseHeader("cache-control", 0)) |h| h.value else null,
            vary,
            if (conn.getResponseHeader("age", 0)) |h| h.value else null,
            if (conn.getResponseHeader("etag", 0)) |h| h.value else null,
            if (conn.getResponseHeader("last-modified", 0)) |h| h.value else null,
            conn.getResponseHeader("set-cookie", 0) != null,
            conn.getResponseHeader("authorization", 0) != null,
        );

        if (maybe_cm) |cm| {
            var iter = transfer.responseHeaderIterator();
            var header_list = try iter.collect(arena);
            const end_of_response = header_list.items.len;

            if (vary) |vary_str| {
                var req_it = self.req_headers.iterator();
                while (req_it.next()) |hdr| {
                    var vary_iter = std.mem.splitScalar(u8, vary_str, ',');
                    while (vary_iter.next()) |part| {
                        const name = std.mem.trim(u8, part, &std.ascii.whitespace);
                        if (std.ascii.eqlIgnoreCase(hdr.name, name)) {
                            try header_list.append(arena, .{
                                .name = try arena.dupe(u8, hdr.name),
                                .value = try arena.dupe(u8, hdr.value),
                            });
                        }
                    }
                }
            }

            const metadata = try arena.create(CachedMetadata);
            metadata.* = cm;
            metadata.headers = header_list.items[0..end_of_response];
            metadata.vary_headers = header_list.items[end_of_response..];
            self.pending_metadata = metadata;
        }

        return self.forward.forwardHeader(response);
    }

    fn doneCallback(ctx: *anyopaque) anyerror!void {
        const self: *CacheContext = @ptrCast(@alignCast(ctx));
        const transfer = self.transfer;

        if (self.pending_metadata) |metadata| {
            const cache = &transfer.client.network.cache.?;

            if (comptime IS_DEBUG) {
                log.debug(.browser, "http cache", .{ .key = self.req_url, .metadata = metadata });
            }
            cache.put(metadata.*, transfer.res.stream_buffer.items) catch |err| {
                log.warn(.http, "cache put failed", .{ .err = err });
            };
        }

        return self.forward.forwardDone();
    }

    fn shutdownCallback(ctx: *anyopaque) void {
        const self: *CacheContext = @ptrCast(@alignCast(ctx));
        if (self.stale_entry) |entry| {
            self.stale_entry = null;
            entry.data.deinit();
        }

        self.forward.forwardShutdown();
    }

    fn errorCallback(ctx: *anyopaque, e: anyerror) void {
        const self: *CacheContext = @ptrCast(@alignCast(ctx));
        if (self.stale_entry) |entry| {
            self.stale_entry = null;
            entry.data.deinit();
        }

        self.forward.forwardErr(e);
    }
};
