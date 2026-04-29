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
const Response = @import("../../browser/HttpClient.zig").Response;
const FulfilledResponse = @import("../../browser/HttpClient.zig").FulfilledResponse;
const Layer = @import("../../browser/HttpClient.zig").Layer;
const Forward = @import("Forward.zig");

const InterceptionLayer = @This();

// Count of intercepted requests. This is to help deal with intercepted requests.
// The client doesn't track intercepted transfers. If a request is intercepted,
// the client forgets about it and requires the interceptor to continue or abort
// it. That works well, except if we only rely on active, we might think there's
// no more network activity when, with interecepted requests, there might be more
// in the future. (We really only need this to properly emit a 'networkIdle' and
// 'networkAlmostIdle' Page.lifecycleEvent in CDP).
intercepted: usize = 0,

next: Layer = undefined,

pub fn layer(self: *InterceptionLayer) Layer {
    return .{
        .ptr = self,
        .vtable = &.{ .request = request },
    };
}

fn request(ptr: *anyopaque, client: *Client, in_req: Request) anyerror!void {
    const self: *InterceptionLayer = @ptrCast(@alignCast(ptr));

    const intercept_ctx = try in_req.params.arena.create(InterceptContext);
    intercept_ctx.* = .{
        .client = client,
        .forward = Forward.fromRequest(in_req),
        .layer = self,
        .request = in_req,
    };

    var req = intercept_ctx.forward.wrapRequest(
        in_req,
        intercept_ctx,
        .{
            .start = InterceptContext.startCallback,
            .header = InterceptContext.headerCallback,
            .data = InterceptContext.dataCallback,
            .done = InterceptContext.doneCallback,
            .err = InterceptContext.errorCallback,
            .shutdown = InterceptContext.shutdownCallback,
        },
    );

    req.params.notification.dispatch(.http_request_start, &.{ .request = &req });

    var wait_for_interception = false;
    req.params.notification.dispatch(.http_request_intercept, &.{
        .request = &req,
        .wait_for_interception = &wait_for_interception,
    });

    log.debug(.http, "interception check", .{
        .wait_for_interception = wait_for_interception,
        .intercepted = self.intercepted,
        .url = req.params.url,
    });

    if (!wait_for_interception) {
        return self.next.request(client, req);
    }

    self.intercepted += 1;
    if (comptime IS_DEBUG) {
        log.debug(.http, "wait for interception", .{ .intercepted = self.intercepted });
    }
}

pub const InterceptContext = struct {
    client: *Client,
    forward: Forward,
    layer: *InterceptionLayer,
    request: Request,
    content_length: usize = 0,

    fn startCallback(response: Response) anyerror!void {
        const self: *InterceptContext = @ptrCast(@alignCast(response.ctx));
        log.debug(.http, "intercept start", .{ .url = self.request.params.url });
        return self.forward.forwardStart(response);
    }

    fn headerCallback(response: Response) anyerror!bool {
        const self: *InterceptContext = @ptrCast(@alignCast(response.ctx));
        log.debug(.http, "intercept header", .{
            .url = self.request.params.url,
            .status = response.status(),
            .content_length = response.contentLength(),
        });

        self.content_length = response.contentLength() orelse 0;

        self.request.params.notification.dispatch(.http_response_header_done, &.{
            .request = &self.request,
            .response = &response,
        });

        return self.forward.forwardHeader(response);
    }

    fn dataCallback(response: Response, chunk: []const u8) anyerror!void {
        const self: *InterceptContext = @ptrCast(@alignCast(response.ctx));
        log.debug(.http, "intercept data", .{
            .url = self.request.params.url,
            .len = chunk.len,
        });

        self.request.params.notification.dispatch(.http_response_data, &.{
            .data = chunk,
            .request = &self.request,
        });

        return self.forward.forwardData(response, chunk);
    }

    fn doneCallback(ctx: *anyopaque) anyerror!void {
        const self: *InterceptContext = @ptrCast(@alignCast(ctx));

        log.debug(.http, "intercept done", .{
            .url = self.request.params.url,
            .content_length = self.content_length,
        });

        self.request.params.notification.dispatch(.http_request_done, &.{
            .request = &self.request,
            .content_length = self.content_length,
        });
        return self.forward.forwardDone();
    }

    fn errorCallback(ctx: *anyopaque, err: anyerror) void {
        const self: *InterceptContext = @ptrCast(@alignCast(ctx));

        log.debug(.http, "intercept error", .{
            .url = self.request.params.url,
            .err = err,
        });
        self.request.params.notification.dispatch(.http_request_fail, &.{
            .request = &self.request,
            .err = err,
        });
        self.forward.forwardErr(err);
    }

    fn shutdownCallback(ctx: *anyopaque) void {
        const self: *InterceptContext = @ptrCast(@alignCast(ctx));

        log.debug(.http, "intercept shutdown", .{ .url = self.request.params.url });
        self.request.params.notification.dispatch(.http_request_fail, &.{
            .request = &self.request,
            .err = error.Shutdown,
        });
        self.forward.forwardShutdown();
    }
};

// CDP Callbacks
// These handle their own clean up on errors with `self.next.request`.
// This is because they don't pass their error up the chain as they are async callbacks.

pub fn continueRequest(self: *InterceptionLayer, client: *Client, req: Request) anyerror!void {
    if (comptime IS_DEBUG) {
        lp.assert(self.intercepted > 0, "InterceptionLayer.continueRequest", .{ .value = self.intercepted });
        log.debug(.http, "continue transfer", .{ .intercepted = self.intercepted });
    }

    self.intercepted -= 1;
    self.next.request(client, req) catch |err| {
        const ctx: *InterceptContext = @ptrCast(@alignCast(req.ctx));
        req.error_callback(req.ctx, err);
        ctx.client.deinitRequest(req);
        return err;
    };
}

pub fn abortRequest(self: *InterceptionLayer, client: *Client, req: Request) void {
    if (comptime IS_DEBUG) {
        lp.assert(self.intercepted > 0, "InterceptionLayer.abortRequest", .{ .value = self.intercepted });
        log.debug(.http, "abort transfer", .{ .intercepted = self.intercepted });
    }
    self.intercepted -= 1;

    req.error_callback(req.ctx, error.Abort);
    client.deinitRequest(req);
}

fn fulfillInner(
    req: Request,
    status: u16,
    headers: []const http.Header,
    body: ?[]const u8,
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

    try req.done_callback(req.ctx);
}

pub fn fulfillRequest(
    self: *InterceptionLayer,
    client: *Client,
    req: Request,
    status: u16,
    headers: []const http.Header,
    body: ?[]const u8,
) !void {
    if (comptime IS_DEBUG) {
        lp.assert(self.intercepted > 0, "InterceptionLayer.fulfillRequest", .{ .value = self.intercepted });
        log.debug(.http, "fulfill transfer", .{ .intercepted = self.intercepted });
    }

    self.intercepted -= 1;
    defer client.deinitRequest(req);

    fulfillInner(req, status, headers, body) catch |err| {
        req.error_callback(req.ctx, err);
        return err;
    };
}
