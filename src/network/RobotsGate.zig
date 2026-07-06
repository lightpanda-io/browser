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

// robots.txt gate for the HttpClient request pipeline. Answers allow/deny
// from the robot store; on a store miss it parks the transfer, coalesces
// concurrent requests for the same robots.txt behind a single internal
// fetch, and resumes (or fails) the parked transfers when it resolves.

const std = @import("std");
const lp = @import("lightpanda");

const URL = @import("../browser/URL.zig");

const Robots = @import("Robots.zig");
const Network = @import("Network.zig");
const Transfer = @import("HttpClient.zig").Transfer;

const log = lp.log;
const Allocator = std.mem.Allocator;

const RobotsGate = @This();

network: *Network,
allocator: Allocator,
pending: std.StringHashMapUnmanaged(std.ArrayList(*Transfer)) = .empty,

pub const Result = enum { allowed, blocked, pending };

pub fn deinit(self: *RobotsGate) void {
    var it = self.pending.iterator();
    while (it.next()) |entry| {
        entry.value_ptr.deinit(self.allocator);
    }
    self.pending.deinit(self.allocator);
}

pub fn check(self: *RobotsGate, transfer: *Transfer) !Result {
    const url = transfer.req.url;
    const robots_url = try URL.getRobotsUrl(transfer.arena, url);

    if (self.network.robot_store.get(robots_url)) |robot_entry| {
        switch (robot_entry) {
            .absent => return .allowed,
            .present => |robots| {
                if (robots.isAllowed(URL.getPathname(url))) {
                    return .allowed;
                }
                log.warn(.http, "blocked by robots", .{ .url = url });
                return .blocked;
            },
        }
        unreachable;
    }

    try self.fetchThenResume(robots_url, transfer);
    return .pending;
}

fn fetchThenResume(self: *RobotsGate, robots_url: [:0]const u8, transfer: *Transfer) !void {
    const entry = try self.pending.getOrPut(self.allocator, robots_url);

    if (entry.found_existing == false) {
        // A fetch for this robots.txt is already in flight, queue behind it.
        try entry.value_ptr.append(self.allocator, transfer);
        transfer.park(.robots);
        return;
    }

    errdefer _ = self.pending.remove(robots_url);
    entry.value_ptr.* = .empty;

    try entry.value_ptr.append(self.allocator, transfer);
    transfer.park(.robots);
    errdefer {
        entry.value_ptr.deinit(self.allocator);
        transfer.unpark();
    }

    const robots_ctx = try transfer.arena.create(RobotsContext);
    robots_ctx.* = .{
        .gate = self,
        .buffer = .empty,
        .arena = transfer.arena,
        .robots_url = robots_url,
    };

    log.debug(.browser, "fetching robots.txt", .{ .robots_url = robots_url });

    // Only the parent's frame/loader ids (CDP correlation) and notification
    // carry over — no cookies, credentials, headers, or timeout.
    try transfer.client.request(.{
        .url = robots_url,
        .method = .GET,
        .internal = true,
        .resource_type = .fetch,
        .frame_id = transfer.req.frame_id,
        .loader_id = transfer.req.loader_id,
        .notification = transfer.req.notification,
        .cookie_jar = null,
        .cookie_origin = robots_url,
        .ctx = robots_ctx,
        .header_callback = RobotsContext.headerCallback,
        .data_callback = RobotsContext.dataCallback,
        .done_callback = RobotsContext.doneCallback,
        .error_callback = RobotsContext.errorCallback,
        .shutdown_callback = RobotsContext.shutdownCallback,
    }, transfer.owner);
}

fn flushPending(self: *RobotsGate, robots_url: [:0]const u8, allowed: bool) void {
    var queued = self.pending.fetchRemove(robots_url) orelse return;
    defer queued.value.deinit(self.allocator);

    for (queued.value.items) |transfer| {
        transfer.unpark();
        if (!allowed) {
            log.warn(.http, "blocked by robots", .{ .url = transfer.req.url });
            transfer.failAsync(error.RobotsBlocked);
            continue;
        }
        // Hand back to the pipeline; the robots gate is the last step
        // before the network. If it fails before committing, clean up here.
        transfer.client.resumeAfterRobots(transfer) catch |e| {
            if (transfer.state == .created) {
                transfer.abort(e);
            }
        };
    }
}

// shutdown_callback is only called on owner shutdown. And if this robot's fetch
// is being shutdown, than any transfers waiting for it will be shutdown too.
fn flushPendingShutdown(self: *RobotsGate, robots_url: [:0]const u8) void {
    var pending = self.pending.fetchRemove(robots_url) orelse return;
    pending.value.deinit(self.allocator);
}

const RobotsContext = struct {
    gate: *RobotsGate,
    arena: Allocator,
    robots_url: [:0]const u8,
    buffer: std.ArrayList(u8),
    status: u16 = 0,

    fn headerCallback(transfer: *Transfer) anyerror!Transfer.HeaderResult {
        const self: *RobotsContext = @ptrCast(@alignCast(transfer.req.ctx));
        if (transfer.res.header) |hdr| {
            log.debug(.browser, "robots status", .{ .status = hdr.status, .robots_url = self.robots_url });
            self.status = hdr.status;
        }
        if (transfer.getContentLength()) |cl| {
            try self.buffer.ensureTotalCapacity(self.arena, cl);
        }
        return .proceed;
    }

    fn dataCallback(transfer: *Transfer, data: []const u8) anyerror!void {
        const self: *RobotsContext = @ptrCast(@alignCast(transfer.req.ctx));
        try self.buffer.appendSlice(self.arena, data);
    }

    fn doneCallback(ctx_ptr: *anyopaque) anyerror!void {
        const self: *RobotsContext = @ptrCast(@alignCast(ctx_ptr));
        const gate = self.gate;
        const robots_url = self.robots_url;

        var allowed = true;
        const network = gate.network;

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
                        const path = URL.getPathname(gate.pending.get(robots_url).?.items[0].req.url);
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

        gate.flushPending(robots_url, allowed);
    }

    fn errorCallback(ctx_ptr: *anyopaque, err: anyerror) void {
        const self: *RobotsContext = @ptrCast(@alignCast(ctx_ptr));

        log.warn(.http, "robots fetch failed", .{ .err = err });
        self.gate.flushPending(self.robots_url, true);
    }

    fn shutdownCallback(ctx_ptr: *anyopaque) void {
        const self: *RobotsContext = @ptrCast(@alignCast(ctx_ptr));

        log.debug(.http, "robots fetch shutdown", .{});
        self.gate.flushPendingShutdown(self.robots_url);
    }
};
