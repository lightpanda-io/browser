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

const http = @import("../http.zig");
const Transfer = @import("../../browser/HttpClient.zig").Transfer;
const Context = @import("../../browser/HttpClient.zig").Context;
const Request = @import("../../browser/HttpClient.zig").Request;
const Response = @import("../../browser/HttpClient.zig").Response;
const Layer = @import("../../browser/HttpClient.zig").Layer;

const Cache = @import("../cache/Cache.zig");
const CachedMetadata = @import("../cache/Cache.zig").CachedMetadata;
const CachedResponse = @import("../cache/Cache.zig").CachedResponse;
const Forward = @import("Forward.zig");

const CacheLayer = @This();

next: Layer = undefined,

pub fn layer(self: *CacheLayer) Layer {
    return .{
        .ptr = self,
        .vtable = &.{
            .request = request,
        },
    };
}

fn request(ptr: *anyopaque, ctx: Context, req: Request) anyerror!void {
    const self: *CacheLayer = @ptrCast(@alignCast(ptr));
    const network = ctx.network;

    if (req.params.method != .GET) {
        return self.next.request(ctx, req);
    }

    const arena = try network.app.arena_pool.acquire(.small, "CacheLayer");
    errdefer network.app.arena_pool.release(arena);

    var iter = req.params.headers.iterator();
    const req_header_list = try iter.collect(arena);

    if (network.cache.?.get(arena, .{
        .url = req.params.url,
        .timestamp = std.time.timestamp(),
        .request_headers = req_header_list.items,
    })) |cached| {
        defer req.deinit();
        defer network.app.arena_pool.release(arena);
        return serveFromCache(req, &cached);
    }

    const cache_ctx = try arena.create(CacheContext);
    cache_ctx.* = .{
        .arena = arena,
        .context = ctx,
        .forward = Forward.fromRequest(req),
        .req_url = req.params.url,
        .req_headers = req.params.headers,
    };

    const wrapped = cache_ctx.forward.wrapRequest(
        req,
        cache_ctx,
        .{
            .start = CacheContext.startCallback,
            .header = CacheContext.headerCallback,
            .done = CacheContext.doneCallback,
            .shutdown = CacheContext.shutdownCallback,
            .err = CacheContext.errorCallback,
        },
    );

    return self.next.request(ctx, wrapped);
}

fn serveFromCache(req: Request, cached: *const CachedResponse) !void {
    const response = Response.fromCached(req.ctx, cached);
    defer switch (cached.data) {
        .buffer => |_| {},
        .file => |f| f.file.close(),
    };

    if (req.start_callback) |cb| {
        try cb(response);
    }

    const proceed = try req.header_callback(response);
    if (!proceed) {
        req.error_callback(req.ctx, error.Abort);
        return;
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
    context: Context,
    transfer: ?*Transfer = null,
    forward: Forward,
    req_url: [:0]const u8,
    req_headers: http.Headers,
    pending_metadata: ?*CachedMetadata = null,

    fn startCallback(response: Response) anyerror!void {
        const self: *CacheContext = @ptrCast(@alignCast(response.ctx));
        self.transfer = response.inner.transfer;
        return self.forward.forwardStart(response);
    }

    fn headerCallback(response: Response) anyerror!bool {
        const self: *CacheContext = @ptrCast(@alignCast(response.ctx));
        const allocator = self.arena;

        const transfer = response.inner.transfer;
        var rh = &transfer.response_header.?;

        const conn = transfer._conn.?;

        const vary = if (conn.getResponseHeader("vary", 0)) |h| h.value else null;

        const maybe_cm = try Cache.tryCache(
            allocator,
            std.time.timestamp(),
            transfer.url,
            rh.status,
            rh.contentType(),
            if (conn.getResponseHeader("cache-control", 0)) |h| h.value else null,
            vary,
            if (conn.getResponseHeader("age", 0)) |h| h.value else null,
            conn.getResponseHeader("set-cookie", 0) != null,
            conn.getResponseHeader("authorization", 0) != null,
        );

        if (maybe_cm) |cm| {
            var iter = transfer.responseHeaderIterator();
            var header_list = try iter.collect(allocator);
            const end_of_response = header_list.items.len;

            if (vary) |vary_str| {
                var req_it = self.req_headers.iterator();
                while (req_it.next()) |hdr| {
                    var vary_iter = std.mem.splitScalar(u8, vary_str, ',');
                    while (vary_iter.next()) |part| {
                        const name = std.mem.trim(u8, part, &std.ascii.whitespace);
                        if (std.ascii.eqlIgnoreCase(hdr.name, name)) {
                            try header_list.append(allocator, .{
                                .name = try allocator.dupe(u8, hdr.name),
                                .value = try allocator.dupe(u8, hdr.value),
                            });
                        }
                    }
                }
            }

            const metadata = try allocator.create(CachedMetadata);
            metadata.* = cm;
            metadata.headers = header_list.items[0..end_of_response];
            metadata.vary_headers = header_list.items[end_of_response..];
            self.pending_metadata = metadata;
        }

        return self.forward.forwardHeader(response);
    }

    fn doneCallback(ctx: *anyopaque) anyerror!void {
        const self: *CacheContext = @ptrCast(@alignCast(ctx));
        defer self.context.network.app.arena_pool.release(self.arena);

        const transfer = self.transfer orelse @panic("Start Callback didn't set CacheLayer.transfer");

        if (self.pending_metadata) |metadata| {
            const cache = &self.context.network.cache.?;

            log.debug(.browser, "http cache", .{ .key = self.req_url, .metadata = metadata });
            cache.put(metadata.*, transfer._stream_buffer.items) catch |err| {
                log.warn(.http, "cache put failed", .{ .err = err });
            };
            log.debug(.browser, "http.cache.put", .{ .url = self.req_url });
        }

        return self.forward.forwardDone();
    }

    fn shutdownCallback(ctx: *anyopaque) void {
        const self: *CacheContext = @ptrCast(@alignCast(ctx));
        defer self.context.network.app.arena_pool.release(self.arena);
        self.forward.forwardShutdown();
    }

    fn errorCallback(ctx: *anyopaque, e: anyerror) void {
        const self: *CacheContext = @ptrCast(@alignCast(ctx));
        defer self.context.network.app.arena_pool.release(self.arena);
        self.forward.forwardErr(e);
    }
};
