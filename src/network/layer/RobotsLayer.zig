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

const URL = @import("../../browser/URL.zig");
const Robots = @import("../Robots.zig");
const Client = @import("../../browser/HttpClient.zig").Client;
const Request = @import("../../browser/HttpClient.zig").Request;
const Response = @import("../../browser/HttpClient.zig").Response;
const Layer = @import("../../browser/HttpClient.zig").Layer;
const Forward = @import("Forward.zig");

const RobotsLayer = @This();

next: Layer = undefined,
allocator: std.mem.Allocator,
pending: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(Request)) = .empty,

pub fn layer(self: *RobotsLayer) Layer {
    return .{
        .ptr = self,
        .vtable = &.{
            .request = request,
        },
    };
}

pub fn deinit(self: *RobotsLayer, allocator: std.mem.Allocator) void {
    var it = self.pending.iterator();
    while (it.next()) |entry| {
        entry.value_ptr.deinit(allocator);
    }
    self.pending.deinit(allocator);
}

fn request(ptr: *anyopaque, client: *Client, req: Request) anyerror!void {
    const self: *RobotsLayer = @ptrCast(@alignCast(ptr));

    const arena = req.params.arena;
    const robots_url = try URL.getRobotsUrl(arena, req.params.url);

    if (client.network.robot_store.get(robots_url)) |robot_entry| {
        switch (robot_entry) {
            .present => |robots| {
                const path = URL.getPathname(req.params.url);

                if (!robots.isAllowed(path)) {
                    log.warn(.http, "blocked by robots", .{ .url = req.params.url });
                    return error.RobotsBlocked;
                }
            },
            .absent => {},
        }
        return self.next.request(client, req);
    }

    return self.fetchRobotsThenRequest(client, robots_url, req);
}

fn fetchRobotsThenRequest(
    self: *RobotsLayer,
    client: *Client,
    robots_url: [:0]const u8,
    req: Request,
) !void {
    const entry = try self.pending.getOrPut(self.allocator, robots_url);

    if (!entry.found_existing) {
        errdefer std.debug.assert(self.pending.remove(robots_url));
        entry.value_ptr.* = .empty;

        // This arena is later owned by the Request. It does not need to be cleaned up by us because
        // it will be cleaned up by the `Transfer.deinit()` or any `Request.deinit()` called on any sublayers.
        const new_arena = try client.network.app.arena_pool.acquire(.small, "RobotsLayer.RobotsContext");
        errdefer client.network.app.arena_pool.release(new_arena);

        const robots_ctx = try new_arena.create(RobotsContext);
        robots_ctx.* = .{
            .layer = self,
            .client = client,
            .arena = new_arena,
            .robots_url = robots_url,
            .buffer = .empty,
        };

        const headers = try client.newHeaders();
        log.debug(.browser, "fetching robots.txt", .{ .robots_url = robots_url });

        try self.next.request(client, .{
            .ctx = robots_ctx,
            .params = .{
                // We have to do this ourselves because we are not going through the top level `request`.
                .arena = new_arena,
                .request_id = client.incrReqId(),
                .url = robots_url,
                .method = .GET,
                .headers = headers,
                .frame_id = req.params.frame_id,
                .loader_id = req.params.loader_id,
                .cookie_jar = req.params.cookie_jar,
                .cookie_origin = req.params.cookie_origin,
                .notification = req.params.notification,
                .resource_type = .fetch,
            },
            .header_callback = RobotsContext.headerCallback,
            .data_callback = RobotsContext.dataCallback,
            .done_callback = RobotsContext.doneCallback,
            .error_callback = RobotsContext.errorCallback,
            .shutdown_callback = RobotsContext.shutdownCallback,
        });
    }

    try entry.value_ptr.append(self.allocator, req);
}

fn flushPending(self: *RobotsLayer, client: *Client, robots_url: [:0]const u8, allowed: bool) void {
    var queued = self.pending.fetchRemove(robots_url) orelse
        @panic("RobotsLayer.flushPending: missing queue");
    defer queued.value.deinit(self.allocator);

    for (queued.value.items) |queued_req| {
        if (!allowed) {
            log.warn(.http, "blocked by robots", .{ .url = queued_req.params.url });
            defer client.deinitRequest(queued_req);
            queued_req.error_callback(queued_req.ctx, error.RobotsBlocked);
        } else {
            self.next.request(client, queued_req) catch |e| {
                defer client.deinitRequest(queued_req);
                queued_req.error_callback(queued_req.ctx, e);
            };
        }
    }
}

fn flushPendingShutdown(self: *RobotsLayer, robots_url: [:0]const u8, client: *Client) void {
    var queued = self.pending.fetchRemove(robots_url) orelse
        @panic("RobotsLayer.flushPendingShutdown: missing queue");
    defer queued.value.deinit(self.allocator);

    for (queued.value.items) |queued_req| {
        defer client.deinitRequest(queued_req);
        if (queued_req.shutdown_callback) |cb| cb(queued_req.ctx);
    }
}

const RobotsContext = struct {
    layer: *RobotsLayer,
    arena: std.mem.Allocator,
    client: *Client,
    robots_url: [:0]const u8,
    buffer: std.ArrayListUnmanaged(u8),
    status: u16 = 0,

    fn deinit(self: *RobotsContext) void {
        self.buffer.deinit(self.layer.allocator);
        self.layer.allocator.destroy(self);
    }

    fn headerCallback(response: Response) anyerror!bool {
        const self: *RobotsContext = @ptrCast(@alignCast(response.ctx));
        switch (response.inner) {
            .transfer => |t| {
                if (t.response_header) |hdr| {
                    log.debug(.browser, "robots status", .{ .status = hdr.status, .robots_url = self.robots_url });
                    self.status = hdr.status;
                }
                if (t.getContentLength()) |cl| {
                    try self.buffer.ensureTotalCapacity(self.arena, cl);
                }
            },
            else => {},
        }
        return true;
    }

    fn dataCallback(response: Response, data: []const u8) anyerror!void {
        const self: *RobotsContext = @ptrCast(@alignCast(response.ctx));
        try self.buffer.appendSlice(self.arena, data);
    }

    fn doneCallback(ctx_ptr: *anyopaque) anyerror!void {
        const self: *RobotsContext = @ptrCast(@alignCast(ctx_ptr));
        const l = self.layer;
        const client = self.client;
        const robots_url = self.robots_url;

        var allowed = true;
        const network = client.network;

        switch (self.status) {
            200 => {
                if (self.buffer.items.len > 0) {
                    const robots: ?Robots = network.robot_store.robotsFromBytes(
                        network.config.http_headers.user_agent,
                        self.buffer.items,
                    ) catch blk: {
                        log.warn(.browser, "failed to parse robots", .{ .robots_url = robots_url });
                        try network.robot_store.putAbsent(robots_url);
                        break :blk null;
                    };
                    if (robots) |r| {
                        try network.robot_store.put(robots_url, r);
                        const path = URL.getPathname(l.pending.get(robots_url).?.items[0].params.url);
                        allowed = r.isAllowed(path);
                    }
                }
            },
            404 => {
                log.debug(.http, "robots not found", .{ .url = robots_url });
                try network.robot_store.putAbsent(robots_url);
            },
            else => {
                log.debug(.http, "unexpected status on robots", .{
                    .url = robots_url,
                    .status = self.status,
                });
                try network.robot_store.putAbsent(robots_url);
            },
        }

        l.flushPending(client, robots_url, allowed);
    }

    fn errorCallback(ctx_ptr: *anyopaque, err: anyerror) void {
        const self: *RobotsContext = @ptrCast(@alignCast(ctx_ptr));
        const l = self.layer;
        const client = self.client;
        const robots_url = self.robots_url;

        log.warn(.http, "robots fetch failed", .{ .err = err });
        l.flushPending(client, robots_url, true);
    }

    fn shutdownCallback(ctx_ptr: *anyopaque) void {
        const self: *RobotsContext = @ptrCast(@alignCast(ctx_ptr));
        const l = self.layer;
        const client = self.client;
        const robots_url = self.robots_url;

        log.debug(.http, "robots fetch shutdown", .{});
        l.flushPendingShutdown(robots_url, client);
    }
};
