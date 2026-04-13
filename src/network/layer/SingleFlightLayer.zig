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

const SingleFlightLayer = @This();

next: Layer = undefined,
allocator: std.mem.Allocator,
flights: std.StringHashMapUnmanaged(Flight) = .empty,

pub const Flight = struct {
    arena: std.mem.Allocator,
    waiters: std.ArrayList(Request) = .empty,

    pub fn append(self: *Flight, req: Request) !void {
        try self.waiters.append(self.arena, req);
    }
};

pub fn layer(self: *SingleFlightLayer) Layer {
    return .{
        .ptr = self,
        .vtable = &.{
            .request = request,
        },
    };
}

pub fn deinit(self: *SingleFlightLayer, _: std.mem.Allocator) void {
    self.flights.deinit(self.allocator);
}

fn request(ptr: *anyopaque, ctx: Context, req: Request) anyerror!void {
    const self: *SingleFlightLayer = @ptrCast(@alignCast(ptr));

    // only single flight idempotent reqursts.
    if (!req.method.idempotent()) {
        return self.next.request(ctx, req);
    }

    const arena = try ctx.network.app.arena_pool.acquire(.small, "SingleFlightLayer");
    errdefer ctx.network.app.arena_pool.release(arena);

    const key = try arena.dupeZ(u8, req.url);
    var gop = try self.flights.getOrPut(self.allocator, key);

    // if we already have this flight, just add it to the list.
    if (gop.found_existing) {
        log.debug(.browser, "single flight join", .{ .url = key });
        try gop.value_ptr.append(req);
        ctx.network.app.arena_pool.release(arena);
        return;
    }

    // create a new flight
    log.debug(.browser, "single flight start", .{ .url = key });
    gop.value_ptr.* = .{ .arena = arena, .waiters = .empty };

    const flight_ctx = try arena.create(FlightContext);
    flight_ctx.* = .{
        .layer = self,
        .ctx = ctx,
        .url = key,
        .forward = Forward.fromRequest(req),
    };

    const wrapped = flight_ctx.forward.wrapRequest(req, flight_ctx, "forward", .{
        .header = FlightContext.headerCallback,
        .data = FlightContext.dataCallback,
        .done = FlightContext.doneCallback,
        .err = FlightContext.errorCallback,
        .shutdown = FlightContext.shutdownCallback,
    });

    return self.next.request(ctx, wrapped);
}

const FlightContext = struct {
    layer: *SingleFlightLayer,
    ctx: Context,
    url: [:0]const u8,
    forward: Forward,

    pub fn headerCallback(resp: Response) !bool {
        const self: *FlightContext = @ptrCast(@alignCast(resp.ctx));
        const flight: *Flight = self.layer.flights.getPtr(self.url).?;

        for (flight.waiters.items) |waiter| {
            var sub_resp = resp;
            sub_resp.ctx = waiter.ctx;
            const proceed = try waiter.header_callback(sub_resp);
            if (!proceed) return false;
        }

        return self.forward.forwardHeader(resp);
    }

    pub fn dataCallback(resp: Response, chunk: []const u8) !void {
        const self: *FlightContext = @ptrCast(@alignCast(resp.ctx));
        const flight: *Flight = self.layer.flights.getPtr(self.url).?;

        log.debug(.browser, "single flight data", .{
            .url = self.url,
            .count = flight.waiters.items.len,
        });

        for (flight.waiters.items) |waiter| {
            var sub_resp = resp;
            sub_resp.ctx = waiter.ctx;
            try waiter.data_callback(sub_resp, chunk);
        }

        try self.forward.forwardData(resp, chunk);
    }

    pub fn doneCallback(ctx: *anyopaque) !void {
        const self: *FlightContext = @ptrCast(@alignCast(ctx));
        const flight: *Flight = self.layer.flights.getPtr(self.url).?;

        const arena = flight.arena;
        defer {
            std.debug.assert(self.layer.flights.remove(self.url));
            self.ctx.network.app.arena_pool.release(arena);
        }

        log.debug(.browser, "single flight done", .{
            .url = self.url,
            .count = flight.waiters.items.len,
        });

        for (flight.waiters.items) |waiter| {
            try waiter.done_callback(waiter.ctx);
        }

        try self.forward.forwardDone();
    }

    pub fn errorCallback(ctx: *anyopaque, err: anyerror) void {
        const self: *FlightContext = @ptrCast(@alignCast(ctx));
        const flight: *Flight = self.layer.flights.getPtr(self.url).?;

        const arena = flight.arena;
        defer {
            std.debug.assert(self.layer.flights.remove(self.url));
            self.ctx.network.app.arena_pool.release(arena);
        }

        log.debug(.browser, "single flight error", .{
            .url = self.url,
            .count = flight.waiters.items.len,
        });

        for (flight.waiters.items) |waiter| {
            waiter.error_callback(waiter.ctx, err);
        }

        self.forward.forwardErr(err);
    }

    pub fn shutdownCallback(ctx: *anyopaque) void {
        const self: *FlightContext = @ptrCast(@alignCast(ctx));
        const flight: *Flight = self.layer.flights.getPtr(self.url).?;

        const arena = flight.arena;
        defer {
            std.debug.assert(self.layer.flights.remove(self.url));
            self.ctx.network.app.arena_pool.release(arena);
        }

        log.debug(.browser, "single flight shutdown", .{
            .url = self.url,
            .count = flight.waiters.items.len,
        });

        for (flight.waiters.items) |waiter| {
            if (waiter.shutdown_callback) |cb| cb(waiter.ctx);
        }

        self.forward.forwardShutdown();
    }
};
