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
const Client = @import("../../browser/HttpClient.zig").Client;
const Request = @import("../../browser/HttpClient.zig").Request;
const Transfer = @import("../../browser/HttpClient.zig").Transfer;
const Response = @import("../../browser/HttpClient.zig").Response;

const Cache = @import("../cache/Cache.zig");
const CachedMetadata = @import("../cache/Cache.zig").CachedMetadata;
const CachedResponse = @import("../cache/Cache.zig").CachedResponse;

const Forward = @import("Forward.zig");

const log = lp.log;

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

fn request(ptr: *anyopaque, transfer: *Transfer) anyerror!void {
    const self: *CacheLayer = @ptrCast(@alignCast(ptr));
    const req = &transfer.req;

    if (req.params.method != .GET) {
        return self.next.request(transfer);
    }

    const arena = transfer.arena;

    var iter = req.params.headers.iterator();
    const req_header_list = try iter.collect(arena);

    if (transfer.client.network.cache.?.get(arena, .{
        .url = transfer.url,
        .timestamp = std.time.timestamp(),
        .request_headers = req_header_list.items,
    })) |cached| {
        // Dispatch that the Request was served from the Cache.
        transfer.req.params.notification.dispatch(
            .http_request_served_from_cache,
            &.{ .transfer = transfer },
        );

        // Cache hit: serve synchronously from the original callbacks, then
        // tear down. On error, the transfer is still alive and Client.request's
        // errdefer will handle cleanup (loop_owned is still false).
        try serveFromCache(req, &cached);
        transfer.deinit();
        return;
    }

    // Cache miss: install wrappers so we can inspect the response and decide
    // whether to write the body into the cache when it's done.
    const ctx = try arena.create(CacheContext);
    ctx.* = .{
        .arena = arena,
        .transfer = transfer,
        .forward = Forward.capture(req),
        .req_url = transfer.url,
        .req_headers = req.params.headers,
    };

    req.ctx = ctx;
    req.header_callback = CacheContext.headerCallback;
    req.data_callback = CacheContext.dataCallback;
    req.done_callback = CacheContext.doneCallback;
    req.error_callback = CacheContext.errorCallback;

    if (ctx.forward.start != null) {
        // req.ctx was changed, need to ovewrite this
        req.start_callback = CacheContext.startCallback;
    }
    if (ctx.forward.shutdown != null) {
        // req.ctx was changed, need to ovewrite this
        req.shutdown_callback = CacheContext.shutdownCallback;
    }

    return self.next.request(transfer);
}

fn serveFromCache(req: *Request, cached: *const CachedResponse) !void {
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

    fn startCallback(response: Response) anyerror!void {
        const self: *CacheContext = @ptrCast(@alignCast(response.ctx));
        return self.forward.forwardStart(response);
    }

    fn dataCallback(response: Response, chunk: []const u8) anyerror!void {
        const self: *CacheContext = @ptrCast(@alignCast(response.ctx));
        return self.forward.forwardData(response, chunk);
    }

    fn headerCallback(response: Response) anyerror!bool {
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
        const vary = if (conn.getResponseHeader("vary", 0)) |h| h.value else null;

        var rh = &transfer.response_header.?;
        const maybe_cm = try Cache.tryCache(
            arena,
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
        self.forward.forwardShutdown();
    }

    fn errorCallback(ctx: *anyopaque, e: anyerror) void {
        const self: *CacheContext = @ptrCast(@alignCast(ctx));
        self.forward.forwardErr(e);
    }
};
