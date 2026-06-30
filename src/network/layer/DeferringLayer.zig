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

const Network = @import("../Network.zig");
const Transfer = @import("../../browser/HttpClient.zig").Transfer;
const Response = @import("../../browser/HttpClient.zig").Response;
const Layer = @import("../../browser/HttpClient.zig").Layer;
const StableResponse = @import("../../browser/HttpClient.zig").StableResponse;
const Forward = @import("Forward.zig");
const HeaderResult = @import("../../browser/HttpClient.zig").HeaderResult;

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

    if (transfer.req.internal) {
        return self.next.request(transfer);
    }

    const arena = try self.network.app.arena_pool.acquire(.small, "DeferringContext");
    errdefer self.network.app.arena_pool.release(arena);

    // this might outlive the transfer, we need to dupe eveyrthing we'll need to use
    const ctx = try arena.create(DeferredContext);
    ctx.* = .{
        .arena = arena,
        .layer = self,
        .transfer = transfer,
        .frame_id = transfer.req.frame_id,
        .url = try arena.dupeZ(u8, transfer.req.url),
        .forward = Forward.capture(&transfer.req),
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

pub fn flushFrame(self: *DeferringLayer, frame_id: u32) void {
    // DeferredContext.fire() can re-enter flushFrame, so we'll capture
    // ready items in this list, so that a reentrant flushFrame doesn't mutate
    // self.active while we're iterating.
    var ready: std.DoublyLinkedList = .{};

    var node = self.active.first;
    while (node) |n| {
        node = n.next;
        const ctx: *DeferredContext = @fieldParentPtr("node", n);
        if (!ctx.deferring) {
            continue;
        }

        // captured frame_id, not ctx.transfer: the transfer may be freed.
        if (ctx.frame_id != frame_id) {
            continue;
        }

        if (ctx.terminal) {
            self.active.remove(n);
            ready.append(n);
        } else {
            ctx.firePartial();
            ctx.deferring = false;
        }
    }

    // ready is local, ctx.fire() re-entering flushFrame can't invalidate it.
    while (ready.popFirst()) |n| {
        const ctx: *DeferredContext = @fieldParentPtr("node", n);
        ctx.fire();
    }
}

/// Drop orphaned deferred contexts for a frame that's going away. A `terminal`
/// context's transfer already completed while deferred, so it's been deinited
/// and unlinked from the owner — abortOwner can't reach it, yet it lingers in
/// `active` pointing at a forward target (the Fetch) whose arena page teardown
/// is about to free, and a later flushFrame would fire into it. Non-terminal
/// contexts still have a live transfer that cleans them up itself.
pub fn cancelFrame(self: *DeferringLayer, frame_id: u32) void {
    var node = self.active.first;
    while (node) |n| {
        node = n.next;
        const ctx: *DeferredContext = @fieldParentPtr("node", n);
        if (ctx.frame_id != frame_id or !ctx.terminal) {
            continue;
        }
        self.active.remove(n);
        ctx.deinit();
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
    frame_id: u32,
    url: [:0]const u8,
    forward: Forward,
    node: std.DoublyLinkedList.Node = .{},

    buffered: std.ArrayList(BufferedEvent) = .{},
    done: bool = false,
    deferring: bool = false,
    terminal: bool = false,
    stable_resp: ?StableResponse = null,

    const BufferedEvent = union(enum) {
        start,
        header,
        data: []const u8,
        done,
        err: anyerror,
    };

    fn deinit(self: *DeferredContext) void {
        self.layer.network.app.arena_pool.release(self.arena);
    }

    fn setStableResponse(self: *DeferredContext, response: Response) !void {
        if (self.stable_resp == null) {
            self.stable_resp = try Response.toStable(response, self.arena);
        }
    }

    fn shouldDefer(self: *DeferredContext) bool {
        const req = self.transfer.req;
        const blocking_id = self.transfer.client.blocking_requests.get(req.frame_id) orelse return false;
        return self.transfer.id != blocking_id;
    }

    fn startCallback(response: Response) anyerror!void {
        const self: *DeferredContext = @ptrCast(@alignCast(response.ctx));

        if (!self.deferring and !self.shouldDefer()) {
            return self.forward.forwardStart(response);
        }

        log.debug(.http, "deferring start callback", .{ .url = self.url });
        try self.setStableResponse(response);
        self.deferring = true;
        try self.buffered.append(self.arena, .start);
    }

    fn headerCallback(response: Response) anyerror!HeaderResult {
        const self: *DeferredContext = @ptrCast(@alignCast(response.ctx));

        if (!self.deferring and !self.shouldDefer()) {
            return self.forward.forwardHeader(response);
        }

        log.debug(.http, "deferring header callback", .{ .url = self.url });
        try self.setStableResponse(response);
        self.deferring = true;
        try self.buffered.append(self.arena, .header);
        return .proceed;
    }

    fn dataCallback(response: Response, chunk: []const u8) anyerror!void {
        const self: *DeferredContext = @ptrCast(@alignCast(response.ctx));

        if (!self.deferring and !self.shouldDefer()) {
            return self.forward.forwardData(response, chunk);
        }

        log.debug(.http, "deferring data callback", .{ .url = self.url });
        try self.setStableResponse(response);
        self.deferring = true;
        try self.buffered.append(self.arena, .{ .data = try self.arena.dupe(u8, chunk) });
    }

    fn doneCallback(ctx: *anyopaque) anyerror!void {
        const self: *DeferredContext = @ptrCast(@alignCast(ctx));

        if (!self.deferring and !self.shouldDefer()) {
            defer self.deinit();
            self.done = true;
            self.layer.active.remove(&self.node);
            return self.forward.forwardDone();
        }

        log.debug(.http, "deferring done callback", .{ .url = self.url });
        self.deferring = true;
        self.terminal = true;
        try self.buffered.append(self.arena, .done);
    }

    fn errorCallback(ctx: *anyopaque, err: anyerror) void {
        const self: *DeferredContext = @ptrCast(@alignCast(ctx));

        if (!self.deferring and !self.shouldDefer()) {
            defer self.deinit();
            self.done = true;
            self.layer.active.remove(&self.node);
            self.forward.forwardErr(err);
            return;
        }

        log.debug(.http, "deferring error callback", .{ .url = self.url, .err = err });
        self.deferring = true;
        self.terminal = true;
        self.buffered.append(self.arena, .{ .err = err }) catch {};
    }

    fn shutdownCallback(ctx: *anyopaque) void {
        const self: *DeferredContext = @ptrCast(@alignCast(ctx));
        if (self.done) return;

        defer self.deinit();
        self.done = true;
        self.layer.active.remove(&self.node);

        log.debug(.http, "deferring shutdown callback", .{});
        self.forward.forwardShutdown();
    }

    fn fire(self: *DeferredContext) void {
        defer self.deinit();

        for (self.buffered.items) |event| {
            switch (event) {
                .start => {
                    const stable_response = self.stable_resp orelse @panic("stable_resp must be set for start events");
                    const response = Response.fromStable(&stable_response);

                    self.forward.forwardStart(response) catch |err| {
                        log.err(.http, "deferred start callback", .{ .err = err, .url = self.url });
                        self.forward.forwardErr(err);
                        return;
                    };
                },
                .header => {
                    const stable_response = self.stable_resp orelse @panic("stable_resp must be set for header events");
                    const response = Response.fromStable(&stable_response);

                    const result = self.forward.forwardHeader(response) catch |err| {
                        log.err(.http, "deferred header callback", .{ .err = err, .url = self.url });
                        self.forward.forwardErr(err);
                        return;
                    };
                    if (result == .abort) {
                        self.forward.forwardErr(error.Abort);
                        return;
                    }
                },
                .data => |chunk| {
                    const stable_response = self.stable_resp orelse @panic("stable_resp must be set for data events");
                    const response = Response.fromStable(&stable_response);

                    self.forward.forwardData(response, chunk) catch |err| {
                        log.err(.http, "deferred data callback", .{ .err = err, .url = self.url });
                        self.forward.forwardErr(err);
                        return;
                    };
                },
                .done => {
                    self.forward.forwardDone() catch |err| {
                        log.err(.http, "deferred done callback", .{ .err = err, .url = self.url });
                        self.forward.forwardErr(err);
                    };

                    return;
                },
                .err => |err| {
                    self.forward.forwardErr(err);
                    return;
                },
            }
        }
    }

    fn firePartial(self: *DeferredContext) void {
        const stable_response = self.stable_resp orelse @panic("stable_resp must be set for any of the partial fire events");
        const response = Response.fromStable(&stable_response);

        for (self.buffered.items) |event| {
            switch (event) {
                .start => {
                    self.forward.forwardStart(response) catch |err| {
                        log.err(.http, "defer part start callback", .{ .err = err, .url = self.url });
                        self.forward.forwardErr(err);
                        return;
                    };
                },
                .header => {
                    const result = self.forward.forwardHeader(response) catch |err| {
                        log.err(.http, "defer part header callback", .{ .err = err, .url = self.url });
                        self.forward.forwardErr(err);
                        return;
                    };
                    if (result == .abort) {
                        self.forward.forwardErr(error.Abort);
                        return;
                    }
                },
                .data => |chunk| {
                    self.forward.forwardData(response, chunk) catch |err| {
                        log.err(.http, "defer part data callback", .{ .err = err, .url = self.url });
                        self.forward.forwardErr(err);
                        return;
                    };
                },
                .done, .err => @panic("firePartial cant fire terminal events"),
            }
        }

        self.buffered.clearRetainingCapacity();
    }
};
