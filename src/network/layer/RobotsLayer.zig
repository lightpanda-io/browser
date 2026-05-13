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

const URL = @import("../../browser/URL.zig");
const Layer = @import("../../browser/HttpClient.zig").Layer;
const Client = @import("../../browser/HttpClient.zig").Client;
const Transfer = @import("../../browser/HttpClient.zig").Transfer;
const Response = @import("../../browser/HttpClient.zig").Response;

const Robots = @import("../Robots.zig");
const Network = @import("../Network.zig");

const Forward = @import("Forward.zig");

const log = lp.log;
const Allocator = std.mem.Allocator;

const RobotsLayer = @This();

next: Layer = undefined,
network: *Network,
allocator: Allocator,
pending: std.StringHashMapUnmanaged(std.ArrayList(*Transfer)) = .empty,

pub fn layer(self: *RobotsLayer) Layer {
    return .{
        .ptr = self,
        .vtable = &.{
            .request = request,
        },
    };
}

pub fn deinit(self: *RobotsLayer, allocator: Allocator) void {
    var it = self.pending.iterator();
    while (it.next()) |entry| {
        entry.value_ptr.deinit(allocator);
    }
    self.pending.deinit(allocator);
}

fn request(ptr: *anyopaque, transfer: *Transfer) anyerror!void {
    const self: *RobotsLayer = @ptrCast(@alignCast(ptr));

    if (transfer.req.params.skip_robots) {
        return self.next.request(transfer);
    }

    const url = transfer.url;
    const robots_url = try URL.getRobotsUrl(transfer.arena, url);

    if (self.network.robot_store.get(robots_url)) |robot_entry| {
        switch (robot_entry) {
            .present => |robots| {
                const path = URL.getPathname(url);

                if (!robots.isAllowed(path)) {
                    log.warn(.http, "blocked by robots", .{ .url = url });
                    return error.RobotsBlocked;
                }
            },
            .absent => {},
        }
        return self.next.request(transfer);
    }

    return self.fetchRobotsThenRequest(robots_url, transfer);
}

fn fetchRobotsThenRequest(
    self: *RobotsLayer,
    robots_url: [:0]const u8,
    transfer: *Transfer,
) !void {
    const entry = try self.pending.getOrPut(self.allocator, robots_url);

    if (!entry.found_existing) {
        errdefer std.debug.assert(self.pending.remove(robots_url));
        entry.value_ptr.* = .empty;

        try entry.value_ptr.append(self.allocator, transfer);
        transfer.loop_owned = true;
        errdefer {
            entry.value_ptr.deinit(self.allocator);
            transfer.loop_owned = false;
        }

        const robots_ctx = try transfer.arena.create(RobotsContext);
        robots_ctx.* = .{
            .layer = self,
            .buffer = .empty,
            .arena = transfer.arena,
            .robots_url = robots_url,
        };

        var params = transfer.req.params;
        if (@typeInfo(@TypeOf(params)) != .@"struct") {
            // protect against mutating the original request
            @compileError("expected request.params to be a struct");
        }

        // CRITICAL: build a fresh Headers for the inner robots fetch.
        // params is value-copied from the parent's req.params, but
        // Headers is a struct wrapping a *curl_slist — value copy shares
        // the pointer. Letting Client.request take ownership of a shared
        // headers list means both transfers will free it at deinit time
        // -> double-free. The robots.txt fetch is a system-level GET
        // anyway, no need to inherit the parent's user headers.
        params.headers = try transfer.client.newHeaders();
        errdefer params.headers.deinit();
        params.method = .GET;
        params.url = robots_url;
        params.skip_robots = true;
        params.resource_type = .fetch;
        params.body = null;

        log.debug(.browser, "fetching robots.txt", .{ .robots_url = robots_url });
        try transfer.client.request(.{
            .ctx = robots_ctx,
            .params = params,
            .header_callback = RobotsContext.headerCallback,
            .data_callback = RobotsContext.dataCallback,
            .done_callback = RobotsContext.doneCallback,
            .error_callback = RobotsContext.errorCallback,
            .shutdown_callback = RobotsContext.shutdownCallback,
        }, transfer.owner);
    } else {
        // Already one in flight, just queue behind.
        try entry.value_ptr.append(self.allocator, transfer);

        // Parked: RobotsLayer owns destruction via flushPending / flushPendingShutdown
        // until robots.txt resolves. Without this, Client.request's errdefer (or
        // any caller's cleanup) would deinit a transfer that's still on the
        // pending list, leaving flushPending with a dangling pointer.
        transfer.loop_owned = true;
    }
}

fn flushPending(self: *RobotsLayer, robots_url: [:0]const u8, allowed: bool) void {
    var queued = self.pending.fetchRemove(robots_url) orelse @panic("RobotsLayer.flushPending: missing queue");
    defer queued.value.deinit(self.allocator);

    for (queued.value.items) |transfer| {
        if (!allowed) {
            log.warn(.http, "blocked by robots", .{ .url = transfer.url });
            transfer.abort(error.RobotsBlocked);
        } else {
            // Reset ownership: handing back to the layer chain. If a downstream
            // layer commits (multi / queue / pause), it'll flip loop_owned back
            // to true. If it fails before committing, we clean up here.
            transfer.loop_owned = false;
            self.next.request(transfer) catch |e| {
                if (!transfer.loop_owned) {
                    transfer.abort(e);
                }
            };
        }
    }
}

// Invariant: shutdown_callback fires on a Transfer only via Transfer.kill,
// and the only callers of kill are Client.abortOwner / .abortRequests
// (owner-driven teardown). So if THIS robots fetch's shutdown_callback
// fired, the owner is being torn down — every parked transfer in this
// pending queue is on the same owner list and is already being killed by
// the same walk. We just need to drop the pending entry; the owner walk
// handles the rest. (If a future code path adds per-transfer kill
// without owner teardown, this assumption breaks — see comment above
// detachOrDeinit in HttpClient.zig.)
fn flushPendingShutdown(self: *RobotsLayer, robots_url: [:0]const u8) void {
    var pending = self.pending.fetchRemove(robots_url) orelse
        @panic("RobotsLayer.flushPendingShutdown: missing queue");
    pending.value.deinit(self.allocator);
}

const RobotsContext = struct {
    layer: *RobotsLayer,
    arena: Allocator,
    robots_url: [:0]const u8,
    buffer: std.ArrayList(u8),
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
        const robots_url = self.robots_url;

        var allowed = true;
        const network = l.network;

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
                        const path = URL.getPathname(l.pending.get(robots_url).?.items[0].req.params.url);
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

        l.flushPending(robots_url, allowed);
    }

    fn errorCallback(ctx_ptr: *anyopaque, err: anyerror) void {
        const self: *RobotsContext = @ptrCast(@alignCast(ctx_ptr));
        const l = self.layer;
        const robots_url = self.robots_url;

        log.warn(.http, "robots fetch failed", .{ .err = err });
        l.flushPending(robots_url, true);
    }

    fn shutdownCallback(ctx_ptr: *anyopaque) void {
        const self: *RobotsContext = @ptrCast(@alignCast(ctx_ptr));
        const l = self.layer;
        const robots_url = self.robots_url;

        log.debug(.http, "robots fetch shutdown", .{});
        l.flushPendingShutdown(robots_url);
    }
};
