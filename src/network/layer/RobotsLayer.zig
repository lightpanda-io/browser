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
const Forward = @import("Forward.zig");

const RobotsLayer = @This();

next: Layer = undefined,
obey_robots: bool,
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

fn request(ptr: *anyopaque, ctx: Context, req: Request) anyerror!void {
    const self: *RobotsLayer = @ptrCast(@alignCast(ptr));

    if (!self.obey_robots) {
        return self.next.request(ctx, req);
    }

    const robots_url = try URL.getRobotsUrl(self.allocator, req.url);
    errdefer self.allocator.free(robots_url);

    if (ctx.network.robot_store.get(robots_url)) |robot_entry| {
        defer self.allocator.free(robots_url);
        switch (robot_entry) {
            .present => |robots| {
                const path = URL.getPathname(req.url);
                if (!robots.isAllowed(path)) {
                    log.warn(.http, "blocked by robots", .{ .url = req.url });
                    req.error_callback(req.ctx, error.RobotsBlocked);
                    return;
                }
            },
            .absent => {},
        }
        return self.next.request(ctx, req);
    }

    return self.fetchRobotsThenRequest(ctx, robots_url, req);
}

fn fetchRobotsThenRequest(self: *RobotsLayer, ctx: Context, robots_url: [:0]const u8, req: Request) !void {
    const entry = try self.pending.getOrPut(self.allocator, robots_url);

    if (!entry.found_existing) {
        errdefer self.allocator.free(robots_url);
        entry.value_ptr.* = .empty;

        const robots_ctx = try self.allocator.create(RobotsContext);
        errdefer self.allocator.destroy(robots_ctx);
        robots_ctx.* = .{
            .layer = self,
            .ctx = ctx,
            .robots_url = robots_url,
            .buffer = .empty,
        };

        const headers = try ctx.newHeaders();
        log.debug(.browser, "fetching robots.txt", .{ .robots_url = robots_url });

        try self.next.request(ctx, .{
            .ctx = robots_ctx,
            .url = robots_url,
            .method = .GET,
            .page_id = req.page_id,
            .headers = headers,
            .blocking = false,
            .frame_id = req.frame_id,
            .cookie_jar = req.cookie_jar,
            .cookie_origin = req.cookie_origin,
            .notification = req.notification,
            .resource_type = .fetch,
            .header_callback = RobotsContext.headerCallback,
            .data_callback = RobotsContext.dataCallback,
            .done_callback = RobotsContext.doneCallback,
            .error_callback = RobotsContext.errorCallback,
            .shutdown_callback = RobotsContext.shutdownCallback,
        });
    } else {
        self.allocator.free(robots_url);
    }

    try entry.value_ptr.append(self.allocator, req);
}

fn flushPending(self: *RobotsLayer, ctx: Context, robots_url: [:0]const u8, allowed: bool) void {
    var queued = self.pending.fetchRemove(robots_url) orelse
        @panic("RobotsLayer.flushPending: missing queue");
    defer queued.value.deinit(self.allocator);

    for (queued.value.items) |queued_req| {
        if (!allowed) {
            log.warn(.http, "blocked by robots", .{ .url = queued_req.url });
            defer queued_req.headers.deinit();
            queued_req.error_callback(queued_req.ctx, error.RobotsBlocked);
        } else {
            self.next.request(ctx, queued_req) catch |e| {
                defer queued_req.headers.deinit();
                queued_req.error_callback(queued_req.ctx, e);
            };
        }
    }
}

fn flushPendingShutdown(self: *RobotsLayer, robots_url: [:0]const u8) void {
    var queued = self.pending.fetchRemove(robots_url) orelse
        @panic("RobotsLayer.flushPendingShutdown: missing queue");
    defer queued.value.deinit(self.allocator);

    for (queued.value.items) |queued_req| {
        defer queued_req.headers.deinit();
        if (queued_req.shutdown_callback) |cb| cb(queued_req.ctx);
    }
}

const RobotsContext = struct {
    layer: *RobotsLayer,
    ctx: Context,
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
                    try self.buffer.ensureTotalCapacity(self.layer.allocator, cl);
                }
            },
            .cached => {},
        }
        return true;
    }

    fn dataCallback(response: Response, data: []const u8) anyerror!void {
        const self: *RobotsContext = @ptrCast(@alignCast(response.ctx));
        try self.buffer.appendSlice(self.layer.allocator, data);
    }

    fn doneCallback(ctx_ptr: *anyopaque) anyerror!void {
        const self: *RobotsContext = @ptrCast(@alignCast(ctx_ptr));
        const l = self.layer;
        const ctx = self.ctx;
        const robots_url = self.robots_url;
        defer l.allocator.free(robots_url);
        defer self.deinit();

        var allowed = true;
        const network = ctx.network;

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
                        const path = URL.getPathname(self.layer.pending.get(robots_url).?.items[0].url);
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

        l.flushPending(ctx, robots_url, allowed);
    }

    fn errorCallback(ctx_ptr: *anyopaque, err: anyerror) void {
        const self: *RobotsContext = @ptrCast(@alignCast(ctx_ptr));
        const l = self.layer;
        const ctx = self.ctx;
        const robots_url = self.robots_url;
        defer l.allocator.free(robots_url);
        defer self.deinit();
        log.warn(.http, "robots fetch failed", .{ .err = err });
        l.flushPending(ctx, robots_url, true);
    }

    fn shutdownCallback(ctx_ptr: *anyopaque) void {
        const self: *RobotsContext = @ptrCast(@alignCast(ctx_ptr));
        const l = self.layer;
        const robots_url = self.robots_url;
        defer l.allocator.free(robots_url);
        defer self.deinit();
        log.debug(.http, "robots fetch shutdown", .{});
        l.flushPendingShutdown(robots_url);
    }
};
