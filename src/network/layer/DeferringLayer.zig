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
const Request = @import("../../browser/HttpClient.zig").Request;
const Response = @import("../../browser/HttpClient.zig").Response;
const Layer = @import("../../browser/HttpClient.zig").Layer;
const Forward = @import("Forward.zig");

const DeferringLayer = @This();

allocator: std.mem.Allocator,
next: Layer = undefined,

// Requests whose callbacks should be deferred until flush() is called.
// Each node is a DeferredRequest allocated in the request's arena.
deferred: std.DoublyLinkedList = .{},

pub fn layer(self: *DeferringLayer) Layer {
    return .{
        .ptr = self,
        .vtable = &.{ .request = request },
    };
}

pub fn deinit(self: *DeferringLayer) void {
    while (self.deferred.popFirst()) |node| {
        const deferred: *DeferredContext = @fieldParentPtr("node", node);
        deferred.deinit();
    }
}

fn request(ptr: *anyopaque, client: *Client, in_req: Request) anyerror!void {
    const self: *DeferringLayer = @ptrCast(@alignCast(ptr));

    const deferred_req = try self.allocator.create(DeferredContext);
    errdefer self.allocator.destroy(deferred_req);

    deferred_req.* = .{
        .layer = self,
        .client = client,
        .forward = Forward.fromRequest(in_req),
        .request = in_req,
        .node = .{},
    };

    const wrapped = deferred_req.forward.wrapRequest(
        in_req,
        deferred_req,
        .{
            .start = DeferredContext.startCallback,
            .header = DeferredContext.headerCallback,
            .data = DeferredContext.dataCallback,
            .done = DeferredContext.doneCallback,
            .err = DeferredContext.errorCallback,
            .shutdown = DeferredContext.shutdownCallback,
        },
    );

    return self.next.request(client, wrapped);
}

// Flush all deferred requests, firing their done/error callbacks.
pub fn flush(self: *DeferringLayer) void {
    while (self.deferred.popFirst()) |node| {
        const deferred: *DeferredContext = @fieldParentPtr("node", node);
        deferred.fire();
    }
}

pub fn hasPending(self: *const DeferringLayer) bool {
    return self.deferred.first != null;
}

const DeferredContext = struct {
    layer: *DeferringLayer,
    client: *Client,
    forward: Forward,
    request: Request,
    node: std.DoublyLinkedList.Node,

    outcome: union(enum) {
        none,
        done,
        err: anyerror,
        shutdown,
    } = .none,

    fn deinit(self: *DeferredContext) void {
        self.layer.allocator.destroy(self);
    }

    fn shouldDefer(self: *DeferredContext) bool {
        const blocking_id = self.client.blocking_request_id orelse return false;
        return self.request.params.request_id != blocking_id;
    }

    fn startCallback(response: Response) anyerror!void {
        const self: *DeferredContext = @ptrCast(@alignCast(response.ctx));
        return self.forward.forwardStart(response);
    }

    fn headerCallback(response: Response) anyerror!bool {
        const self: *DeferredContext = @ptrCast(@alignCast(response.ctx));
        return self.forward.forwardHeader(response);
    }

    fn dataCallback(response: Response, chunk: []const u8) anyerror!void {
        const self: *DeferredContext = @ptrCast(@alignCast(response.ctx));
        return self.forward.forwardData(response, chunk);
    }

    fn doneCallback(ctx: *anyopaque) anyerror!void {
        const self: *DeferredContext = @ptrCast(@alignCast(ctx));
        if (self.shouldDefer()) {
            log.debug(.http, "deferring done callback", .{ .url = self.request.params.url });
            self.outcome = .done;
            self.layer.deferred.append(&self.node);
            return;
        }

        defer self.deinit();
        return self.forward.forwardDone();
    }

    fn errorCallback(ctx: *anyopaque, err: anyerror) void {
        const self: *DeferredContext = @ptrCast(@alignCast(ctx));
        if (self.shouldDefer()) {
            log.debug(.http, "deferring error callback", .{ .url = self.request.params.url, .err = err });
            self.outcome = .{ .err = err };
            self.layer.deferred.append(&self.node);
            return;
        }

        defer self.deinit();
        self.forward.forwardErr(err);
    }

    fn shutdownCallback(ctx: *anyopaque) void {
        const self: *DeferredContext = @ptrCast(@alignCast(ctx));
        if (self.shouldDefer()) {
            self.outcome = .shutdown;
            self.layer.deferred.append(&self.node);
            return;
        }

        defer self.deinit();
        self.forward.forwardShutdown();
    }

    fn fire(self: *DeferredContext) void {
        defer self.deinit();

        switch (self.outcome) {
            .none => unreachable,
            .done => self.forward.forwardDone() catch |err| {
                log.err(.http, "deferred done callback", .{ .err = err, .url = self.request.params.url });
            },
            .err => |err| self.forward.forwardErr(err),
            .shutdown => self.forward.forwardShutdown(),
        }
    }
};
