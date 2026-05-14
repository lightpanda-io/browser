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

const Client = @import("../../browser/HttpClient.zig").Client;
const Network = @import("../Network.zig");
const Transfer = @import("../../browser/HttpClient.zig").Transfer;
const Request = @import("../../browser/HttpClient.zig").Request;
const Response = @import("../../browser/HttpClient.zig").Response;
const Layer = @import("../../browser/HttpClient.zig").Layer;
const StableResponse = @import("../../browser/HttpClient.zig").StableResponse;
const Forward = @import("Forward.zig");

const DeferringLayer = @This();

allocator: std.mem.Allocator,
network: *Network,

next: Layer = undefined,

active: std.DoublyLinkedList = .{},

pub fn layer(self: *DeferringLayer) Layer {
    return .{
        .ptr = self,
        .vtable = &.{ .request = request },
    };
}

pub fn deinit(self: *DeferringLayer) void {
    self.drainAll();
}

fn request(ptr: *anyopaque, transfer: *Transfer) anyerror!void {
    const self: *DeferringLayer = @ptrCast(@alignCast(ptr));

    const arena = try self.network.app.arena_pool.acquire(.small, "DeferringContext");
    errdefer self.network.app.arena_pool.release(arena);

    const ctx = try arena.create(DeferredContext);
    ctx.* = .{
        .arena = arena,
        .layer = self,
        .transfer = transfer,
        .forward = Forward.capture(&transfer.req),
        .node = .{},
    };

    self.active.append(&ctx.node);
    errdefer self.active.remove(&ctx.node);

    transfer.req.ctx = ctx;
    transfer.req.start_callback = if (ctx.forward.start != null) DeferredContext.startCallback else null;
    transfer.req.header_callback = DeferredContext.headerCallback;
    transfer.req.data_callback = DeferredContext.dataCallback;
    transfer.req.done_callback = DeferredContext.doneCallback;
    transfer.req.error_callback = DeferredContext.errorCallback;
    transfer.req.shutdown_callback = if (ctx.forward.shutdown != null) DeferredContext.shutdownCallback else null;

    return self.next.request(transfer);
}

pub fn flushUnblocked(
    self: *DeferringLayer,
    blocking_requests: *const std.AutoHashMapUnmanaged(u32, u32),
) void {
    var node = self.active.first;
    while (node) |n| {
        node = n.next;
        const ctx: *DeferredContext = @fieldParentPtr("node", n);
        if (!ctx.deferring or !ctx.terminal) continue;

        const deferred_req = ctx.transfer.req;
        const frame_id = deferred_req.params.frame_id;
        if (!blocking_requests.contains(frame_id)) {
            self.active.remove(n);
            ctx.fire();
        }
    }
}

pub fn flushFrame(self: *DeferringLayer, frame_id: u32) void {
    var node = self.active.first;
    while (node) |n| {
        node = n.next;
        const ctx: *DeferredContext = @fieldParentPtr("node", n);
        if (!ctx.deferring or !ctx.terminal) continue;

        const deferred_req = ctx.transfer.req;
        if (deferred_req.params.frame_id == frame_id) {
            self.active.remove(n);
            ctx.fire();
        }
    }
}

pub fn drainAll(self: *DeferringLayer) void {
    while (self.active.popFirst()) |node| {
        const ctx: *DeferredContext = @fieldParentPtr("node", node);
        ctx.deinit();
    }
}

const DeferredContext = struct {
    arena: std.mem.Allocator,
    layer: *DeferringLayer,
    transfer: *Transfer,
    forward: Forward,
    node: std.DoublyLinkedList.Node,

    buffered: std.ArrayListUnmanaged(BufferedEvent) = .{},
    deferring: bool = false,
    terminal: bool = false,
    stable_resp: ?StableResponse = null,

    const BufferedEvent = union(enum) {
        start,
        header,
        data: []const u8,
        done,
        err: anyerror,
        shutdown,
    };

    fn deinit(self: *DeferredContext) void {
        self.layer.network.app.arena_pool.release(self.arena);
    }

    fn shouldDefer(self: *DeferredContext) bool {
        const req = self.transfer.req;
        const blocking_id = self.transfer.client.blocking_requests.get(req.params.frame_id) orelse return false;
        return self.transfer.id != blocking_id;
    }

    fn startCallback(response: Response) anyerror!void {
        const self: *DeferredContext = @ptrCast(@alignCast(response.ctx));
        const req = self.transfer.req;

        if (!self.deferring and !self.shouldDefer()) {
            return self.forward.forwardStart(response);
        }

        log.debug(.http, "deferring start callback", .{ .url = req.params.url });
        self.stable_resp = try response.toStable(self.arena);
        self.deferring = true;
        try self.buffered.append(self.arena, .start);
    }

    fn headerCallback(response: Response) anyerror!bool {
        const self: *DeferredContext = @ptrCast(@alignCast(response.ctx));
        const req = self.transfer.req;

        if (!self.deferring and !self.shouldDefer()) {
            return self.forward.forwardHeader(response);
        }

        log.debug(.http, "deferring header callback", .{ .url = req.params.url });
        self.stable_resp = try response.toStable(self.arena);
        self.deferring = true;
        try self.buffered.append(self.arena, .header);
        return true;
    }

    fn dataCallback(response: Response, chunk: []const u8) anyerror!void {
        const self: *DeferredContext = @ptrCast(@alignCast(response.ctx));
        const req = self.transfer.req;

        if (!self.deferring and !self.shouldDefer()) {
            return self.forward.forwardData(response, chunk);
        }

        log.debug(.http, "deferring data callback", .{ .url = req.params.url });
        self.deferring = true;
        try self.buffered.append(self.arena, .{ .data = try self.arena.dupe(u8, chunk) });
    }

    fn doneCallback(ctx: *anyopaque) anyerror!void {
        const self: *DeferredContext = @ptrCast(@alignCast(ctx));
        const req = self.transfer.req;

        if (!self.deferring and !self.shouldDefer()) {
            defer self.deinit();
            self.layer.active.remove(&self.node);
            return self.forward.forwardDone();
        }

        log.debug(.http, "deferring done callback", .{ .url = req.params.url });
        self.deferring = true;
        self.terminal = true;
        try self.buffered.append(self.arena, .done);
    }

    fn errorCallback(ctx: *anyopaque, err: anyerror) void {
        const self: *DeferredContext = @ptrCast(@alignCast(ctx));
        const req = self.transfer.req;

        if (!self.deferring and !self.shouldDefer()) {
            defer self.deinit();
            self.layer.active.remove(&self.node);
            self.forward.forwardErr(err);
            return;
        }

        log.debug(.http, "deferring error callback", .{ .url = req.params.url, .err = err });
        self.deferring = true;
        self.terminal = true;
        self.buffered.append(self.arena, .{ .err = err }) catch {};
    }

    fn shutdownCallback(ctx: *anyopaque) void {
        const self: *DeferredContext = @ptrCast(@alignCast(ctx));
        const req = self.transfer.req;

        if (!self.deferring and !self.shouldDefer()) {
            defer self.deinit();
            self.layer.active.remove(&self.node);
            self.forward.forwardShutdown();
            return;
        }

        log.debug(.http, "deferring shutdown callback", .{ .url = req.params.url });
        self.deferring = true;
        self.terminal = true;
        self.buffered.append(self.arena, .shutdown) catch {};
    }

    // Replay all buffered events in order, then clean up.
    fn fire(self: *DeferredContext) void {
        defer self.deinit();

        const req = self.transfer.req;
        const stable_response = self.stable_resp.?;
        const response = Response.fromStable(&stable_response);

        for (self.buffered.items) |event| {
            switch (event) {
                .start => {
                    self.forward.forwardStart(response) catch |err| {
                        log.err(.http, "deferred start callback", .{ .err = err, .url = req.params.url });
                        self.forward.forwardErr(err);
                        return;
                    };
                },
                .header => {
                    const proceed = self.forward.forwardHeader(response) catch |err| {
                        log.err(.http, "deferred header callback", .{ .err = err, .url = req.params.url });
                        self.forward.forwardErr(err);
                        return;
                    };

                    if (!proceed) {
                        self.forward.forwardErr(error.Abort);
                    }
                },
                .data => |chunk| {
                    self.forward.forwardData(response, chunk) catch |err| {
                        log.err(.http, "deferred data callback", .{ .err = err, .url = req.params.url });
                        self.forward.forwardErr(err);
                        return;
                    };
                },
                .done => {
                    self.forward.forwardDone() catch |err| {
                        log.err(.http, "deferred done callback", .{ .err = err, .url = req.params.url });
                        self.forward.forwardErr(err);
                    };

                    return;
                },
                .err => |err| {
                    self.forward.forwardErr(err);
                    return;
                },
                .shutdown => {
                    self.forward.forwardShutdown();
                    return;
                },
            }
        }
    }
};
