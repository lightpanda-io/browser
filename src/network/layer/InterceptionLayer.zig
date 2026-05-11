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
const builtin = @import("builtin");
const lp = @import("lightpanda");
const log = lp.log;

const IS_DEBUG = builtin.mode == .Debug;

const http = @import("../http.zig");
const Client = @import("../../browser/HttpClient.zig").Client;
const Request = @import("../../browser/HttpClient.zig").Request;
const Transfer = @import("../../browser/HttpClient.zig").Transfer;
const Response = @import("../../browser/HttpClient.zig").Response;
const FulfilledResponse = @import("../../browser/HttpClient.zig").FulfilledResponse;
const Layer = @import("../../browser/HttpClient.zig").Layer;
const Forward = @import("Forward.zig");

const InterceptionLayer = @This();

// Count of intercepted requests. The client doesn't track intercepted transfers
// on its own active counters: once intercepted, a transfer leaves the layer
// chain and waits for the interceptor (CDP) to call continue/abort/fulfill.
// We track them here so the network-idle / network-almost-idle CDP lifecycle
// events don't fire prematurely.
intercepted: usize = 0,

next: Layer = undefined,

pub fn layer(self: *InterceptionLayer) Layer {
    return .{
        .ptr = self,
        .vtable = &.{ .request = request },
    };
}

fn request(ptr: *anyopaque, transfer: *Transfer) anyerror!void {
    const self: *InterceptionLayer = @ptrCast(@alignCast(ptr));
    const req = &transfer.req;

    const ctx = try transfer.arena.create(InterceptContext);
    ctx.* = .{
        .layer = self,
        .transfer = transfer,
        .forward = Forward.capture(req),
    };

    // Install our wrappers on the transfer's request. The interceptor wants to
    // observe every callback (start/header/data/done/err/shutdown) so it can
    // mirror the Network.* CDP events.
    req.ctx = ctx;
    if (ctx.forward.start != null) req.start_callback = InterceptContext.startCallback;
    req.header_callback = InterceptContext.headerCallback;
    req.data_callback = InterceptContext.dataCallback;
    req.done_callback = InterceptContext.doneCallback;
    req.error_callback = InterceptContext.errorCallback;
    if (ctx.forward.shutdown != null) req.shutdown_callback = InterceptContext.shutdownCallback;

    req.params.notification.dispatch(.http_request_start, &.{ .transfer = transfer });

    var wait_for_interception = false;
    req.params.notification.dispatch(.http_request_intercept, &.{
        .transfer = transfer,
        .wait_for_interception = &wait_for_interception,
    });

    log.debug(.http, "interception check", .{
        .wait_for_interception = wait_for_interception,
        .intercepted = self.intercepted,
        .url = req.params.url,
    });

    if (!wait_for_interception) {
        return self.next.request(transfer);
    }

    // Paused: the CDP listener stashed `transfer` and will eventually call
    // continueRequest / abortRequest / fulfillRequest. Until then, CDP owns
    // the transfer's lifecycle, so flag it loop_owned to keep the outer
    // Client.request errdefer from tearing it down.
    self.intercepted += 1;
    transfer.loop_owned = true;
    if (comptime IS_DEBUG) {
        log.debug(.http, "wait for interception", .{ .intercepted = self.intercepted });
    }
}

pub const InterceptContext = struct {
    layer: *InterceptionLayer,
    transfer: *Transfer,
    forward: Forward,
    content_length: usize = 0,

    fn startCallback(response: Response) anyerror!void {
        const self: *InterceptContext = @ptrCast(@alignCast(response.ctx));
        log.debug(.http, "intercept start", .{ .url = self.transfer.url });
        return self.forward.forwardStart(response);
    }

    fn headerCallback(response: Response) anyerror!bool {
        const self: *InterceptContext = @ptrCast(@alignCast(response.ctx));
        log.debug(.http, "intercept header", .{
            .url = self.transfer.url,
            .status = response.status(),
            .content_length = response.contentLength(),
        });

        self.content_length = response.contentLength() orelse 0;

        self.transfer.req.params.notification.dispatch(.http_response_header_done, &.{
            .transfer = self.transfer,
            .response = &response,
        });

        return self.forward.forwardHeader(response);
    }

    fn dataCallback(response: Response, chunk: []const u8) anyerror!void {
        const self: *InterceptContext = @ptrCast(@alignCast(response.ctx));
        log.debug(.http, "intercept data", .{
            .url = self.transfer.url,
            .len = chunk.len,
        });

        self.transfer.req.params.notification.dispatch(.http_response_data, &.{
            .data = chunk,
            .transfer = self.transfer,
        });

        return self.forward.forwardData(response, chunk);
    }

    fn doneCallback(ctx: *anyopaque) anyerror!void {
        const self: *InterceptContext = @ptrCast(@alignCast(ctx));

        log.debug(.http, "intercept done", .{
            .url = self.transfer.url,
            .content_length = self.content_length,
        });

        self.transfer.req.params.notification.dispatch(.http_request_done, &.{
            .transfer = self.transfer,
            .content_length = self.content_length,
        });
        return self.forward.forwardDone();
    }

    fn errorCallback(ctx: *anyopaque, err: anyerror) void {
        const self: *InterceptContext = @ptrCast(@alignCast(ctx));

        log.debug(.http, "intercept error", .{
            .url = self.transfer.url,
            .err = err,
        });
        self.transfer.req.params.notification.dispatch(.http_request_fail, &.{
            .transfer = self.transfer,
            .err = err,
        });
        self.forward.forwardErr(err);
    }

    fn shutdownCallback(ctx: *anyopaque) void {
        const self: *InterceptContext = @ptrCast(@alignCast(ctx));

        log.debug(.http, "intercept shutdown", .{ .url = self.transfer.url });
        self.transfer.req.params.notification.dispatch(.http_request_fail, &.{
            .transfer = self.transfer,
            .err = error.Shutdown,
        });
        self.forward.forwardShutdown();
    }
};

// CDP-driven resolution entry points. The transfer was paused inside `request`
// (loop_owned = true). One of these three is called by CDP to resume / drop
// the transfer.

pub fn continueRequest(self: *InterceptionLayer, transfer: *Transfer) anyerror!void {
    if (comptime IS_DEBUG) {
        lp.assert(self.intercepted > 0, "InterceptionLayer.continueRequest", .{ .value = self.intercepted });
        log.debug(.http, "continue transfer", .{ .intercepted = self.intercepted });
    }
    self.intercepted -= 1;

    // Resume the layer chain. Ownership is re-handed to whichever subsequent
    // layer commits the transfer (queue, multi, or another pause). If the
    // chain fails before any commit, we clean up here. Mirror the errdefer
    // pattern in Client.request.
    transfer.loop_owned = false;
    self.next.request(transfer) catch |err| {
        if (!transfer.loop_owned) {
            transfer.requestFailed(err, true);
            transfer.deinit();
        }
        return err;
    };
}

pub fn abortRequest(self: *InterceptionLayer, transfer: *Transfer) void {
    if (comptime IS_DEBUG) {
        lp.assert(self.intercepted > 0, "InterceptionLayer.abortRequest", .{ .value = self.intercepted });
        log.debug(.http, "abort transfer", .{ .intercepted = self.intercepted });
    }
    self.intercepted -= 1;

    transfer.requestFailed(error.Abort, true);
    transfer.deinit();
}

pub fn fulfillRequest(
    self: *InterceptionLayer,
    transfer: *Transfer,
    status: u16,
    headers: []const http.Header,
    body: ?[]const u8,
) !void {
    if (comptime IS_DEBUG) {
        lp.assert(self.intercepted > 0, "InterceptionLayer.fulfillRequest", .{ .value = self.intercepted });
        log.debug(.http, "fulfill transfer", .{ .intercepted = self.intercepted });
    }
    self.intercepted -= 1;
    defer transfer.deinit();

    // `done` flips true once we've called the user's done_callback. If
    // done_callback itself throws, the user already saw their end-of-flow
    // notification; suppress error_callback to avoid double-notify.
    var done: bool = false;
    fulfillInner(&transfer.req, status, headers, body, &done) catch |err| {
        if (!done) {
            transfer.requestFailed(err, true);
        }
        return err;
    };
}

fn fulfillInner(
    req: *Request,
    status: u16,
    headers: []const http.Header,
    body: ?[]const u8,
    done: *bool,
) !void {
    const fulfilled = FulfilledResponse{
        .status = status,
        .url = req.params.url,
        .headers = headers,
        .body = body,
    };

    const response = Response.fromFulfilled(req.ctx, &fulfilled);

    if (req.start_callback) |cb| {
        try cb(response);
    }

    const proceed = try req.header_callback(response);
    if (!proceed) {
        return error.Abort;
    }

    if (body) |b| {
        try req.data_callback(response, b);
    }

    done.* = true;
    try req.done_callback(req.ctx);
}
