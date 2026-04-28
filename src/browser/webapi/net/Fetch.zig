// Copyright (C) 2023-2025  Lightpanda (Selecy SAS)
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
const HttpClient = @import("../../HttpClient.zig");

const js = @import("../../js/js.zig");
const Frame = @import("../../Frame.zig");
const URL = @import("../../URL.zig");

const Blob = @import("../Blob.zig");
const Request = @import("Request.zig");
const Response = @import("Response.zig");
const AbortSignal = @import("../AbortSignal.zig");
const DOMException = @import("../DOMException.zig");

const log = lp.log;
const IS_DEBUG = @import("builtin").mode == .Debug;

const Fetch = @This();

_frame: *Frame,
_url: []const u8,
_buf: std.ArrayList(u8),
_response: *Response,
_resolver: js.PromiseResolver.Global,
_owns_response: bool,
_signal: ?*AbortSignal,

pub const Input = Request.Input;
pub const InitOpts = Request.InitOpts;

pub fn init(input: Input, options: ?InitOpts, frame: *Frame) !js.Promise {
    const request = try Request.init(input, options, &frame.js.execution);
    const resolver = frame.js.local.?.createPromiseResolver();

    if (request._signal) |signal| {
        if (signal._aborted) {
            resolver.reject("fetch aborted", DOMException.init("The operation was aborted.", "AbortError"));
            return resolver.promise();
        }
    }

    if (std.mem.startsWith(u8, request._url, "blob:")) {
        return handleBlobUrl(request._url, resolver, frame);
    }

    const response = try Response.init(null, .{ .status = 0 }, &frame.js.execution);
    errdefer response.deinit(frame._page);

    const fetch = try response._arena.create(Fetch);
    fetch.* = .{
        ._frame = frame,
        ._buf = .empty,
        ._url = try response._arena.dupe(u8, request._url),
        ._resolver = try resolver.persist(),
        ._response = response,
        ._owns_response = true,
        ._signal = request._signal,
    };

    const http_client = frame._session.browser.http_client;
    var headers = try http_client.newHeaders();
    if (request._headers) |h| {
        try h.populateHttpHeader(frame.call_arena, &headers);
    }
    try frame.headersForRequest(&headers);

    if (comptime IS_DEBUG) {
        log.debug(.http, "fetch", .{ .url = request._url });
    }

    const cookie_jar = switch (request._credentials) {
        .omit => null,
        .include => &frame._session.cookie_jar,
        .@"same-origin" => if (frame.isSameOrigin(request._url)) &frame._session.cookie_jar else null,
    };

    try http_client.request(.{
        .ctx = fetch,
        .params = .{
            .url = request._url,
            .method = request._method,
            .frame_id = frame._frame_id,
            .loader_id = frame._loader_id,
            .body = request._body,
            .headers = headers,
            .resource_type = .fetch,
            .cookie_jar = cookie_jar,
            .cookie_origin = frame.url,
            .notification = frame._session.notification,
        },
        .start_callback = httpStartCallback,
        .header_callback = httpHeaderDoneCallback,
        .data_callback = httpDataCallback,
        .done_callback = httpDoneCallback,
        .error_callback = httpErrorCallback,
        .shutdown_callback = httpShutdownCallback,
    });
    return resolver.promise();
}

fn handleBlobUrl(url: []const u8, resolver: js.PromiseResolver, frame: *Frame) !js.Promise {
    const blob: *Blob = frame.lookupBlobUrl(url) orelse {
        resolver.rejectError("fetch blob error", .{ .type_error = "BlobNotFound" });
        return resolver.promise();
    };

    const response = try Response.init(null, .{ .status = 200 }, &frame.js.execution);
    response._body = .{ .bytes = try response._arena.dupe(u8, blob._slice) };
    response._url = try response._arena.dupeZ(u8, url);
    response._type = .basic;

    if (blob._mime.len > 0) {
        try response._headers.append("Content-Type", blob._mime, &frame.js.execution);
    }

    const js_val = try frame.js.local.?.zigValueToJs(response, .{});
    resolver.resolve("fetch blob done", js_val);
    return resolver.promise();
}

fn httpStartCallback(response: HttpClient.Response) !void {
    const self: *Fetch = @ptrCast(@alignCast(response.ctx));
    if (comptime IS_DEBUG) {
        log.debug(.http, "request start", .{ .url = self._url, .source = "fetch" });
    }
    self._response._http_response = response;
}

fn httpHeaderDoneCallback(response: HttpClient.Response) !bool {
    const self: *Fetch = @ptrCast(@alignCast(response.ctx));

    if (self._signal) |signal| {
        if (signal._aborted) {
            return false;
        }
    }

    const arena = self._response._arena;
    if (response.contentLength()) |cl| {
        try self._buf.ensureTotalCapacity(arena, cl);
    }

    const res = self._response;

    if (comptime IS_DEBUG) {
        log.debug(.http, "request header", .{
            .source = "fetch",
            .url = self._url,
            .status = response.status(),
        });
    }

    res._status = response.status().?;
    res._status_text = std.http.Status.phrase(@enumFromInt(response.status().?)) orelse "";
    res._url = try arena.dupeZ(u8, response.url());
    res._is_redirected = response.redirectCount().? > 0;

    // Determine response type based on origin comparison
    const frame_origin = URL.getOrigin(arena, self._frame.url) catch null;
    const response_origin = URL.getOrigin(arena, res._url) catch null;

    if (frame_origin) |fo| {
        if (response_origin) |ro| {
            if (std.mem.eql(u8, fo, ro)) {
                res._type = .basic; // Same-origin
            } else {
                res._type = .cors; // Cross-origin (for simplicity, assume CORS passed)
            }
        } else {
            res._type = .basic;
        }
    } else {
        res._type = .basic;
    }

    var it = response.headerIterator();
    while (it.next()) |hdr| {
        try res._headers.append(hdr.name, hdr.value, &self._frame.js.execution);
    }

    return true;
}

fn httpDataCallback(response: HttpClient.Response, data: []const u8) !void {
    const self: *Fetch = @ptrCast(@alignCast(response.ctx));

    // Check if aborted
    if (self._signal) |signal| {
        if (signal._aborted) {
            return error.Abort;
        }
    }

    try self._buf.appendSlice(self._response._arena, data);
}

fn httpDoneCallback(ctx: *anyopaque) !void {
    const self: *Fetch = @ptrCast(@alignCast(ctx));
    var response = self._response;
    response._http_response = null;
    response._body = .{ .bytes = self._buf.items };

    log.info(.http, "request complete", .{
        .source = "fetch",
        .url = self._url,
        .status = response._status,
        .len = self._buf.items.len,
    });

    var ls: js.Local.Scope = undefined;
    self._frame.js.localScope(&ls);
    defer ls.deinit();

    const js_val = try ls.local.zigValueToJs(self._response, .{});
    self._owns_response = false;
    return ls.toLocal(self._resolver).resolve("fetch done", js_val);
}

fn httpErrorCallback(ctx: *anyopaque, err: anyerror) void {
    const self: *Fetch = @ptrCast(@alignCast(ctx));

    log.info(.http, "request error", .{
        .source = "fetch",
        .url = self._url,
        .status = self._response._status,
        .err = err,
    });

    var response = self._response;
    response._http_response = null;
    // the response is only passed on v8 on success, if we're here, it's safe to
    // clear this. (defer since `self is in the response's arena).

    defer if (self._owns_response) {
        response.deinit(self._frame._page);
    };

    var ls: js.Local.Scope = undefined;
    self._frame.js.localScope(&ls);
    defer ls.deinit();

    // fetch() must reject with a TypeError on network errors per spec
    ls.toLocal(self._resolver).rejectError("fetch error", .{ .type_error = "fetch error" });
}

fn httpShutdownCallback(ctx: *anyopaque) void {
    const self: *Fetch = @ptrCast(@alignCast(ctx));
    if (comptime IS_DEBUG) {
        // should always be true
        std.debug.assert(self._owns_response);
    }

    if (self._owns_response) {
        var response = self._response;
        response._http_response = null;
        response.deinit(self._frame._page);
        // Do not access `self` after this point: the Fetch struct was
        // allocated from response._arena which has been released.
    }
}

const testing = @import("../../../testing.zig");
test "WebApi: fetch" {
    try testing.htmlRunner("net/fetch.html", .{});
}
