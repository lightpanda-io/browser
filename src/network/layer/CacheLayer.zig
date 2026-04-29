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
const log = lp.log;

const http = @import("../http.zig");
const Client = @import("../../browser/HttpClient.zig").Client;
const Request = @import("../../browser/HttpClient.zig").Request;
const Response = @import("../../browser/HttpClient.zig").Response;
const Layer = @import("../../browser/HttpClient.zig").Layer;

const Cache = @import("../cache/Cache.zig");
const CachedMetadata = @import("../cache/Cache.zig").CachedMetadata;
const CachedResponse = @import("../cache/Cache.zig").CachedResponse;
const Forward = @import("Forward.zig");

const CacheLayer = @This();

enabled: bool = true,
next: Layer = undefined,

pub fn layer(self: *CacheLayer) Layer {
    return .{
        .ptr = self,
        .vtable = &.{
            .request = request,
        },
    };
}

fn request(ptr: *anyopaque, client: *Client, in_req: Request) anyerror!void {
    const self: *CacheLayer = @ptrCast(@alignCast(ptr));
    const network = client.network;
    var req = in_req;

    if (req.params.method != .GET or !self.enabled) {
        return self.next.request(client, req);
    }

    const arena = req.params.arena;

    var iter = req.params.headers.iterator();
    const req_header_list = try iter.collect(arena);

    if (network.cache.?.get(arena, .{
        .url = req.params.url,
        .timestamp = std.time.timestamp(),
        .request_headers = req_header_list.items,
    })) |cached| {
        req.params.notification.dispatch(
            .http_request_served_from_cache,
            &.{
                .request = &req,
            },
        );

        try serveFromCache(req, &cached);
        client.deinitRequest(req);

        return;
    }

    const cache_ctx = try arena.create(CacheContext);
    cache_ctx.* = .{
        .arena = arena,
        .client = client,
        .forward = Forward.fromRequest(req),
        .req_url = req.params.url,
        .req_headers = req.params.headers,
    };

    const wrapped = cache_ctx.forward.wrapRequest(
        req,
        cache_ctx,
        .{
            .header = CacheContext.headerCallback,
            .data = CacheContext.dataCallback,
            .done = CacheContext.doneCallback,
            .shutdown = CacheContext.shutdownCallback,
            .err = CacheContext.errorCallback,
        },
    );

    return self.next.request(client, wrapped);
}

pub fn setEnabled(self: *CacheLayer, enabled: bool) void {
    self.enabled = enabled;
}

fn serveFromCache(in_req: Request, cached: *const CachedResponse) !void {
    var req = in_req;

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

    // This dispatches the Network.responseReceived that we should send.
    req.params.notification.dispatch(.http_response_header_done, &.{
        .request = &req,
        .response = &response,
    });

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
    client: *Client,
    forward: Forward,
    req_url: [:0]const u8,
    req_headers: http.Headers,
    pending_metadata: ?*CachedMetadata = null,
    body_buffer: std.ArrayList(u8) = .empty,

    fn headerCallback(response: Response) anyerror!bool {
        const self: *CacheContext = @ptrCast(@alignCast(response.ctx));
        const allocator = self.arena;

        var vary: ?[]const u8 = null;
        var cache_control: ?[]const u8 = null;
        var age: ?[]const u8 = null;
        var has_set_cookie = false;
        var has_authorization = false;

        var iter = response.headerIterator();
        while (iter.next()) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "vary")) vary = h.value;
            if (std.ascii.eqlIgnoreCase(h.name, "cache-control")) cache_control = h.value;
            if (std.ascii.eqlIgnoreCase(h.name, "age")) age = h.value;
            if (std.ascii.eqlIgnoreCase(h.name, "set-cookie")) has_set_cookie = true;
            if (std.ascii.eqlIgnoreCase(h.name, "authorization")) has_authorization = true;
        }

        const maybe_cm = try Cache.tryCache(
            allocator,
            std.time.timestamp(),
            response.url(),
            response.status() orelse @panic("Response must have status"),
            response.contentType(),
            cache_control,
            vary,
            age,
            has_set_cookie,
            has_authorization,
        );

        if (maybe_cm) |cm| {
            var cache_iter = response.headerIterator();
            var header_list = try cache_iter.collect(allocator);
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

            if (response.contentLength()) |len| {
                try self.body_buffer.ensureTotalCapacity(self.arena, len);
            }
        }

        return self.forward.forwardHeader(response);
    }

    fn dataCallback(response: Response, data: []const u8) anyerror!void {
        const self: *CacheContext = @ptrCast(@alignCast(response.ctx));
        if (self.pending_metadata != null) {
            try self.body_buffer.appendSlice(self.arena, data);
        }
        return self.forward.forwardData(response, data);
    }

    fn doneCallback(ctx: *anyopaque) anyerror!void {
        const self: *CacheContext = @ptrCast(@alignCast(ctx));

        if (self.pending_metadata) |metadata| {
            const cache = &self.client.network.cache.?;

            log.debug(.browser, "http cache", .{ .key = self.req_url, .metadata = metadata });
            cache.put(metadata.*, self.body_buffer.items) catch |err| {
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
