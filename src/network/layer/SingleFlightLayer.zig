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
flights: std.StringHashMapUnmanaged(std.ArrayList(Request)) = .empty,

pub fn layer(self: *SingleFlightLayer) Layer {
    return .{
        .ptr = self,
        .vtable = &.{
            .request = request,
        },
    };
}

pub fn deinit(self: *SingleFlightLayer, allocator: std.mem.Allocator) void {
    _ = self;
    _ = allocator;
}

fn request(ptr: *anyopaque, ctx: Context, req: Request) anyerror!void {
    const self: *SingleFlightLayer = @ptrCast(@alignCast(ptr));

    if (req.method != .GET) {
        return self.next.request(ctx, req);
    }

    const arena = try ctx.network.app.arena_pool.acquire(.{ .debug = "SingleFlightLayer" });
    errdefer ctx.network.app.arena_pool.release(arena);

    const key = req.url;

    var gop = try self.flights.getOrPut(arena, key);
    if (gop.found_existing) {
        try gop.value_ptr.append(arena, req);
        return;
    }

    gop.value_ptr.* = .empty;

    const flight_ctx = try self.allocator.create(FlightContext);
    flight_ctx.* = .{
        .layer = self,
        .ctx = ctx,
        .url = req.url,
        .forward = Forward.fromRequest(req),
    };

    const wrapped = flight_ctx.forward.wrapRequest(req, flight_ctx, "forward", .{
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

    fn deinit(self: *FlightContext) void {
        self.layer.allocator.destroy(self);
    }

    fn fanout(self: *FlightContext) std.ArrayListUnmanaged(Request) {
        const kv = self.layer.flights.fetchRemove(self.url) orelse
            @panic("SingleFlightLayer.fanout: missing flight");
        return kv.value;
    }

    fn doneCallback(ctx_ptr: *anyopaque) anyerror!void {
        const self: *FlightContext = @ptrCast(@alignCast(ctx_ptr));
        var waiters = self.fanout();
        defer {
            waiters.deinit(self.layer.allocator);
            self.deinit();
        }

        try self.forward.forwardDone();

        // replay to waiters - they missed the header/data callbacks so we
        // can only signal done; callers that need the body should use CacheLayer
        for (waiters.items) |waiter| {
            waiter.done_callback(waiter.ctx) catch |err| {
                waiter.error_callback(waiter.ctx, err);
            };
        }
    }

    fn errorCallback(ctx_ptr: *anyopaque, err: anyerror) void {
        const self: *FlightContext = @ptrCast(@alignCast(ctx_ptr));
        var waiters = self.fanout();
        defer {
            waiters.deinit(self.layer.allocator);
            self.deinit();
        }

        self.forward.forwardErr(err);

        for (waiters.items) |waiter| {
            waiter.error_callback(waiter.ctx, err);
        }
    }

    fn shutdownCallback(ctx_ptr: *anyopaque) void {
        const self: *FlightContext = @ptrCast(@alignCast(ctx_ptr));
        var waiters = self.fanout();
        defer {
            waiters.deinit(self.layer.allocator);
            self.deinit();
        }

        self.forward.forwardShutdown();

        for (waiters.items) |waiter| {
            if (waiter.shutdown_callback) |cb| cb(waiter.ctx);
        }
    }
};
