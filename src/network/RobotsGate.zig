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
const ArenaPool = @import("../ArenaPool.zig");

const http = @import("http.zig");
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
    }

    try self.fetchThenResume(robots_url, transfer);
    return .pending;
}

// A parked transfer is dying out-of-band (abort, owner teardown) — unlink
// it so the robots.txt resolution doesn't touch freed memory. The map entry
// stays: the in-flight fetch owns it (the key lives on the fetch's context
// arena) and still resolves the remaining waiters.
pub fn remove(self: *RobotsGate, transfer: *Transfer) void {
    var it = self.pending.valueIterator();
    while (it.next()) |waiting| {
        for (waiting.items, 0..) |t, i| {
            if (t == transfer) {
                _ = waiting.swapRemove(i);
                return;
            }
        }
    }
}

fn fetchThenResume(self: *RobotsGate, robots_url: [:0]const u8, transfer: *Transfer) !void {
    if (self.pending.getPtr(robots_url)) |waiting| {
        // A fetch for this robots.txt is already in flight, queue behind it.
        try waiting.append(self.allocator, transfer);
        transfer.park(.robots);
        return;
    }

    const client = transfer.client;

    // The context, the response buffer and the pending-map key live on
    // their own pooled arena, NOT on transfer.arena — any waiter (this one
    // included) can be aborted while the fetch is still in flight, and the
    // fetch's callbacks must survive that. The arena is released by
    // whichever terminal callback fires (done / error / shutdown).
    const arena = try client.arena_pool.acquire(.small, "RobotsGate.RobotsContext");
    errdefer client.arena_pool.release(arena);

    const owned_url = try arena.dupeZ(u8, robots_url);
    const robots_ctx = try arena.create(RobotsContext);
    robots_ctx.* = .{
        .gate = self,
        .buffer = .empty,
        .arena = arena,
        .arena_pool = client.arena_pool,
        .robots_url = owned_url,
    };

    var waiting: std.ArrayList(*Transfer) = .empty;
    try waiting.append(self.allocator, transfer);
    errdefer waiting.deinit(self.allocator);

    try self.pending.putNoClobber(self.allocator, owned_url, waiting);
    errdefer _ = self.pending.remove(owned_url);

    transfer.park(.robots);
    errdefer transfer.unpark();

    log.debug(.browser, "fetching robots.txt", .{ .robots_url = owned_url });

    // Only the parent's frame/loader ids (CDP correlation) and notification
    // carry over — no cookies, credentials, headers, or timeout.
    const fetch_transfer = try client.newRequest(.{
        .url = owned_url,
        .method = .GET,
        .internal = true,
        .resource_type = .fetch,
        .frame_id = transfer.req.frame_id,
        .loader_id = transfer.req.loader_id,
        .notification = transfer.req.notification,
        .cookie_jar = null,
        .cookie_origin = owned_url,
        .ctx = robots_ctx,
        .header_callback = RobotsContext.headerCallback,
        .data_callback = RobotsContext.dataCallback,
        .done_callback = RobotsContext.doneCallback,
        .error_callback = RobotsContext.errorCallback,
        .shutdown_callback = RobotsContext.shutdownCallback,
    }, null);

    // From here the fetch owns the pending entry and the context arena. If
    // submit fails it fires error_callback — possibly synchronously, right
    // here — which resolves the waiters (fail-open, may already have resumed
    // `transfer`) and releases the arena. So there is nothing to unwind
    // locally and the errdefers above must not run: swallow the error.
    fetch_transfer.submit() catch {};
}

// The robots.txt fetch resolved: hand every waiter back to the pipeline,
// each judged against its own path. No store entry (fetch failed, or a 200
// whose body never got parsed) fails open.
fn flushPending(self: *RobotsGate, robots_url: []const u8) void {
    var queued = self.pending.fetchRemove(robots_url) orelse return;
    defer queued.value.deinit(self.allocator);

    const robot_entry = self.network.robot_store.get(robots_url);
    for (queued.value.items) |transfer| {
        transfer.unpark();

        const allowed = if (robot_entry) |entry| switch (entry) {
            .absent => true,
            .present => |robots| robots.isAllowed(URL.getPathname(transfer.req.url)),
        } else true;

        if (!allowed) {
            lp.metrics.robots_access.incr(.deny);
            log.warn(.http, "blocked by robots", .{ .url = transfer.req.url });
            transfer.failAsync(error.RobotsBlocked);
            continue;
        }
        // Hand back to the pipeline; the robots gate is the last step
        // before the network. If it fails while we still own the transfer,
        // clean up here.
        lp.metrics.robots_access.incr(.allow);
        transfer.client.resumeAfterRobots(transfer) catch |e| {
            transfer.abortPipelineError(e);
        };
    }
}

// shutdown_callback fires when the fetch is kill()'d. The fetch is
// ownerless, so that only happens at client-wide teardown (Client.abort),
// where every waiter is being kill()'d by the same loop; their deinit
// finds no gate entry left (or unlinks itself first) and no-ops.
fn flushPendingShutdown(self: *RobotsGate, robots_url: []const u8) void {
    var pending = self.pending.fetchRemove(robots_url) orelse return;
    pending.value.deinit(self.allocator);
}

const RobotsContext = struct {
    gate: *RobotsGate,
    arena: Allocator,
    arena_pool: *ArenaPool,
    robots_url: [:0]const u8,
    buffer: std.ArrayList(u8),
    status: u16 = 0,

    fn headerCallback(transfer: *Transfer) anyerror!Transfer.HeaderResult {
        const self: *RobotsContext = @ptrCast(@alignCast(transfer.req.ctx));
        if (transfer.res.header) |hdr| {
            log.debug(.browser, "robots status", .{ .status = hdr.status, .robots_url = self.robots_url });
            self.status = hdr.status;
        }
        lp.metrics.robots_status.incr(http.statusCategory(self.status));
        if (transfer.getContentLength()) |cl| {
            try self.buffer.ensureTotalCapacity(self.arena, cl);
        }
        return .proceed;
    }

    fn dataCallback(transfer: *Transfer, data: []const u8) anyerror!void {
        const self: *RobotsContext = @ptrCast(@alignCast(transfer.req.ctx));
        if (self.status == 200) {
            try self.buffer.appendSlice(self.arena, data);
        }
    }

    fn doneCallback(ctx_ptr: *anyopaque) anyerror!void {
        const self: *RobotsContext = @ptrCast(@alignCast(ctx_ptr));
        const robots_url = self.robots_url;
        const network = self.gate.network;

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

        // If anything above threw, error_callback fires next and resolves
        // instead — resolve() must run exactly once.
        self.resolve();
    }

    fn errorCallback(ctx_ptr: *anyopaque, err: anyerror) void {
        const self: *RobotsContext = @ptrCast(@alignCast(ctx_ptr));

        log.warn(.http, "robots fetch failed", .{ .err = err });
        self.resolve();
    }

    fn shutdownCallback(ctx_ptr: *anyopaque) void {
        const self: *RobotsContext = @ptrCast(@alignCast(ctx_ptr));

        log.debug(.http, "robots fetch shutdown", .{});
        const gate = self.gate;
        const pool = self.arena_pool;
        const arena = self.arena;
        gate.flushPendingShutdown(self.robots_url);
        pool.release(arena);
    }

    fn resolve(self: *RobotsContext) void {
        const gate = self.gate;
        const pool = self.arena_pool;
        const arena = self.arena;
        gate.flushPending(self.robots_url);
        pool.release(arena);
    }
};
