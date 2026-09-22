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
const SingleFlight = @import("SingleFlight.zig");

const log = lp.log;

const RobotsGate = @This();

network: *Network,
single_flight: SingleFlight,

pub const Result = enum { allowed, blocked, pending };

pub fn deinit(self: *RobotsGate) void {
    self.single_flight.deinit();
}

pub fn check(self: *RobotsGate, transfer: *Transfer) !Result {
    const url = transfer.req.url;
    const robots_url = try URL.getRobotsUrl(transfer.arena.allocator(), url);

    if (self.network.robot_store.checkPath(robots_url, URL.getPathname(url))) |decision| {
        switch (decision) {
            .allowed => return .allowed,
            .blocked => {
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
    self.single_flight.remove(transfer);
}

fn fetchThenResume(self: *RobotsGate, robots_url: [:0]const u8, transfer: *Transfer) !void {
    const client = transfer.client;

    const result = try self.single_flight.enter(robots_url, transfer, .robots);
    if (result == .queued) return;
    errdefer {
        self.single_flight.discard(robots_url);
        transfer.unpark();
    }

    const arena = try client.arena_pool.acquire(.small, "RobotsGate.RobotsContext");
    errdefer arena.release();

    const owned_url = try arena.dupeZ(u8, robots_url);
    const robots_ctx = try arena.create(RobotsContext);
    robots_ctx.* = .{
        .gate = self,
        .buffer = .empty,
        .arena = arena,
        .robots_url = owned_url,
    };

    log.debug(.browser, "fetching robots.txt", .{ .robots_url = owned_url });

    // Ownerless: no cookies, credentials, headers, or timeout. We attribute to
    // the parent for CDP correlation
    const fetch_transfer = try client.newRequest(.{
        .url = owned_url,
        .method = .GET,
        .internal = true,
        .resource_type = .fetch,
        .frame_id = transfer.req.frame_id,
        .document_frame_id = transfer.req.document_frame_id,
        .loader_id = transfer.req.loader_id,
        .notification = transfer.req.notification,
        .origin = null,
        .credentials_mode = .omit,
        .request_mode = .no_cors,
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

const Outcome = union(enum) {
    decision: Robots.RobotStore.Decision,
    robots: Robots.Robots,
};

// The robots.txt fetch resolved: hand every waiter back to the pipeline,
// each judged against its own path. No store entry (fetch failed, or a 200
// whose body never got parsed) fails open.
fn flushPending(self: *RobotsGate, robots_url: []const u8, outcome: Outcome) void {
    var queued = self.single_flight.take(robots_url) orelse return;
    defer queued.deinit(self.single_flight.allocator);

    for (queued.items) |transfer| {
        transfer.unpark();

        const decision: Robots.RobotStore.Decision = switch (outcome) {
            .decision => |d| d,
            .robots => |r| if (r.isAllowed(URL.getPathname(transfer.req.url))) .allowed else .blocked,
        };

        if (decision == .blocked) {
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

const RobotsContext = struct {
    gate: *RobotsGate,
    arena: *lp.Arena,
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
        try self.buffer.ensureTotalCapacityPrecise(self.arena.allocator(), transfer.bodyLen());
        return .proceed;
    }

    fn dataCallback(transfer: *Transfer, data: []const u8) anyerror!void {
        const self: *RobotsContext = @ptrCast(@alignCast(transfer.req.ctx));
        if (self.status == 200) {
            try self.buffer.appendSlice(self.arena.allocator(), data);
        }
    }

    fn doneCallback(ctx_ptr: *anyopaque) anyerror!void {
        const self: *RobotsContext = @ptrCast(@alignCast(ctx_ptr));
        const robots_url = self.robots_url;
        const network = self.gate.network;

        switch (self.status) {
            200 => {
                if (self.buffer.items.len == 0) {
                    // Empty robots.txt means we can short-circuit the allowed path.
                    self.settle(.{ .outcome = .{ .decision = .allowed } });
                    return;
                }

                const robots = network.robot_store.robotsFromBytes(
                    network.config.http_headers.user_agent,
                    self.buffer.items,
                ) catch |err| {
                    // We only return an error if an allocation or something fails.
                    // Our parser does already leniently handle malformed input and takes whichever rules it can parse.
                    // On this case of an allocation failure, it is our fault so we put it as disallowed.
                    log.warn(.browser, "error while parsing robots.txt", .{ .robots_url = robots_url, .err = err });
                    self.settle(.{ .outcome = .{ .decision = .blocked } });
                    return;
                };

                // BE CAREFUL: robots can be invalidated after this call
                self.settle(.{ .outcome = .{ .robots = robots } });
            },
            // Unauthorized/Forbidden: treat as fully disallowed since we can't verify permissions.
            401, 403 => {
                log.debug(.http, "robots.txt access denied", .{
                    .url = robots_url,
                    .status = self.status,
                });
                self.settle(.{ .outcome = .{ .decision = .blocked } });
            },
            // RFC9309: Unavailable (400-499) means that we may access any resources on the server.
            400, 402, 404...499 => {
                log.debug(.http, "robots.txt unavailable", .{ .url = robots_url });
                self.settle(.{ .outcome = .{ .decision = .allowed } });
            },
            // RFC9309: Unreachable (500-599) means that we are completely disallowed.
            500...599 => {
                log.warn(.http, "robots.txt unreachable", .{
                    .url = robots_url,
                    .status = self.status,
                });
                self.settle(.{ .outcome = .{ .decision = .blocked } });
            },
            else => {
                log.debug(.http, "unexpected status on robots", .{
                    .url = robots_url,
                    .status = self.status,
                });
                self.settle(.{ .outcome = .{ .decision = .blocked } });
            },
        }
    }

    fn errorCallback(ctx_ptr: *anyopaque, err: anyerror) void {
        const self: *RobotsContext = @ptrCast(@alignCast(ctx_ptr));

        log.warn(.http, "robots fetch failed", .{ .err = err });
        self.settle(.{
            .outcome = .{ .decision = .allowed },
            .cache = false,
        });
    }

    fn shutdownCallback(ctx_ptr: *anyopaque) void {
        const self: *RobotsContext = @ptrCast(@alignCast(ctx_ptr));

        log.debug(.http, "robots fetch shutdown", .{});
        const gate = self.gate;
        const arena = self.arena;
        gate.single_flight.discard(self.robots_url);
        arena.release();
    }

    const SettleOptions = struct {
        outcome: RobotsGate.Outcome,
        cache: bool = true,
    };

    fn settle(self: *RobotsContext, options: SettleOptions) void {
        const arena = self.arena;
        defer arena.release();

        const gate = self.gate;
        const network = gate.network;

        gate.flushPending(self.robots_url, options.outcome);

        if (options.cache) {
            switch (options.outcome) {
                .decision => |d| switch (d) {
                    .allowed => network.robot_store.putAllowed(self.robots_url) catch |err| {
                        log.warn(.browser, "failed to cache robots decision", .{ .url = self.robots_url, .err = err });
                    },
                    .blocked => network.robot_store.putDisallowed(self.robots_url) catch |err| {
                        log.warn(.browser, "failed to cache robots decision", .{ .url = self.robots_url, .err = err });
                    },
                },
                .robots => |r| network.robot_store.put(self.robots_url, r) catch |err| {
                    log.warn(.browser, "failed to cache robots rules", .{ .url = self.robots_url, .err = err });
                },
            }
        }
    }
};
