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

const URL = @import("../../browser/URL.zig");
const Robots = @import("../Robots.zig");
const Context = @import("../../browser/HttpClient.zig").Context;
const Request = @import("../../browser/HttpClient.zig").Request;
const Response = @import("../../browser/HttpClient.zig").Response;
const Layer = @import("../../browser/HttpClient.zig").Layer;

const RobotsLayer = @This();

next: Layer = undefined,
obey_robots: bool,
allocator: std.mem.Allocator,

pub fn layer(self: *RobotsLayer) Layer {
    return .{
        .ptr = self,
        .vtable = &.{
            .request = request,
        },
    };
}

pub fn deinit(self: *RobotsLayer, _: std.mem.Allocator) void {
    _ = self;
}

fn request(ptr: *anyopaque, ctx: Context, req: Request) anyerror!void {
    const self: *RobotsLayer = @ptrCast(@alignCast(ptr));

    if (!self.obey_robots) {
        return self.next.request(ctx, req);
    }

    const arena = try ctx.network.app.arena_pool.acquire(.small, "RobotsLayer");
    errdefer ctx.network.app.arena_pool.release(arena);

    const robots_url = try URL.getRobotsUrl(arena, req.params.url);

    if (ctx.network.robot_store.get(robots_url)) |robot_entry| {
        defer ctx.network.app.arena_pool.release(arena);

        switch (robot_entry) {
            .present => |robots| {
                const path = URL.getPathname(req.params.url);

                if (!robots.isAllowed(path)) {
                    log.warn(.http, "blocked by robots", .{ .url = req.params.url });
                    req.error_callback(req.ctx, error.RobotsBlocked);
                    return;
                }
            },
            .absent => {},
        }

        return self.next.request(ctx, req);
    }

    // robots not cached yet, fetch it first
    const robots_ctx = try arena.create(RobotsContext);
    robots_ctx.* = .{
        .layer = self,
        .arena = arena,
        .ctx = ctx,
        .req = req,
        .robots_url = try arena.dupeZ(u8, robots_url),
        .buffer = .empty,
    };

    const headers = try ctx.newHeaders();
    log.debug(.browser, "fetching robots.txt", .{ .robots_url = robots_url });

    var new_params = req.params;
    new_params.url = robots_ctx.robots_url;
    new_params.method = .GET;
    new_params.headers = headers;
    new_params.blocking = false;
    new_params.resource_type = .fetch;

    try self.next.request(ctx, .{
        .params = new_params,
        .ctx = robots_ctx,
        .header_callback = RobotsContext.headerCallback,
        .data_callback = RobotsContext.dataCallback,
        .done_callback = RobotsContext.doneCallback,
        .error_callback = RobotsContext.errorCallback,
        .shutdown_callback = RobotsContext.shutdownCallback,
    });
}

const RobotsContext = struct {
    layer: *RobotsLayer,
    arena: std.mem.Allocator,
    ctx: Context,
    req: Request,
    robots_url: [:0]const u8,
    buffer: std.ArrayList(u8),
    status: u16 = 0,

    fn deinit(self: *RobotsContext) void {
        self.ctx.network.app.arena_pool.release(self.arena);
    }

    fn headerCallback(response: Response) anyerror!bool {
        const self: *RobotsContext = @ptrCast(@alignCast(response.ctx));

        const status = response.status().?;
        log.debug(.browser, "robots status", .{ .status = status, .robots_url = self.robots_url });
        self.status = status;

        if (response.contentLength()) |cl| {
            try self.buffer.ensureTotalCapacity(self.arena, cl);
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
        const ctx = self.ctx;
        const req = self.req;
        defer self.deinit();

        const network = ctx.network;

        switch (self.status) {
            200 => {
                if (self.buffer.items.len > 0) {
                    const robots: ?Robots = network.robot_store.robotsFromBytes(
                        network.config.http_headers.user_agent,
                        self.buffer.items,
                    ) catch blk: {
                        log.warn(.browser, "failed to parse robots", .{ .robots_url = self.robots_url });
                        try network.robot_store.putAbsent(self.robots_url);
                        break :blk null;
                    };
                    if (robots) |r| {
                        try network.robot_store.put(self.robots_url, r);
                        const path = URL.getPathname(req.params.url);
                        if (!r.isAllowed(path)) {
                            log.warn(.http, "blocked by robots", .{ .url = req.params.url });
                            req.error_callback(req.ctx, error.RobotsBlocked);
                            return;
                        }
                    }
                }
            },
            404 => {
                log.debug(.http, "robots not found", .{ .url = self.robots_url });
                try network.robot_store.putAbsent(self.robots_url);
            },
            else => {
                log.debug(.http, "unexpected status on robots", .{
                    .url = self.robots_url,
                    .status = self.status,
                });
                try network.robot_store.putAbsent(self.robots_url);
            },
        }

        try l.next.request(ctx, req);
    }

    fn errorCallback(ctx_ptr: *anyopaque, err: anyerror) void {
        const self: *RobotsContext = @ptrCast(@alignCast(ctx_ptr));
        const l = self.layer;
        const ctx = self.ctx;
        const req = self.req;
        defer self.deinit();

        log.warn(.http, "robots fetch failed", .{ .err = err });

        // proceed anyway if robots fetch fails
        l.next.request(ctx, req) catch |e| {
            req.error_callback(req.ctx, e);
        };
    }

    fn shutdownCallback(ctx_ptr: *anyopaque) void {
        const self: *RobotsContext = @ptrCast(@alignCast(ctx_ptr));
        const req = self.req;
        defer self.deinit();

        log.debug(.http, "robots fetch shutdown", .{});
        if (req.shutdown_callback) |cb| cb(req.ctx);
    }
};
