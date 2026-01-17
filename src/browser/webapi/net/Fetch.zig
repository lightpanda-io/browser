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

const log = @import("../../../log.zig");
const Http = @import("../../../http/Http.zig");

const js = @import("../../js/js.zig");
const Page = @import("../../Page.zig");
const URL = @import("../../URL.zig");

const Request = @import("Request.zig");
const Response = @import("Response.zig");

const IS_DEBUG = @import("builtin").mode == .Debug;

const Fetch = @This();

_page: *Page,
_url: []const u8,
_buf: std.ArrayList(u8),
_response: *Response,
_resolver: js.PromiseResolver.Global,

pub const Input = Request.Input;
pub const InitOpts = Request.InitOpts;

pub fn init(input: Input, options: ?InitOpts, page: *Page) !js.Promise {
    const request = try Request.init(input, options, page);

    const fetch = try page.arena.create(Fetch);
    fetch.* = .{
        ._page = page,
        ._buf = .empty,
        ._url = try page.arena.dupe(u8, request._url),
        ._resolver = try page.js.createPromiseResolver().persist(),
        ._response = try Response.init(null, .{ .status = 0 }, page),
    };

    const http_client = page._session.browser.http_client;
    var headers = try http_client.newHeaders();
    if (request._headers) |h| {
        try h.populateHttpHeader(page.call_arena, &headers);
    }
    try page.requestCookie(.{}).headersForRequest(page.arena, request._url, &headers);

    if (comptime IS_DEBUG) {
        log.debug(.http, "fetch", .{ .url = request._url });
    }

    try http_client.request(.{
        .ctx = fetch,
        .url = request._url,
        .method = request._method,
        .body = request._body,
        .headers = headers,
        .resource_type = .fetch,
        .cookie_jar = &page._session.cookie_jar,
        .header_callback = httpHeaderDoneCallback,
        .data_callback = httpDataCallback,
        .done_callback = httpDoneCallback,
        .error_callback = httpErrorCallback,
    });
    return fetch._resolver.local().promise();
}

pub fn deinit(self: *Fetch) void {
    if (self.transfer) |transfer| {
        transfer.abort();
        self.transfer = null;
    }
}

fn httpHeaderDoneCallback(transfer: *Http.Transfer) !void {
    const self: *Fetch = @ptrCast(@alignCast(transfer.ctx));

    if (transfer.getContentLength()) |cl| {
        try self._buf.ensureTotalCapacity(self._page.arena, cl);
    }

    const res = self._response;
    const header = transfer.response_header.?;

    if (comptime IS_DEBUG) {
        log.debug(.http, "request header", .{
            .source = "fetch",
            .url = self._url,
            .status = header.status,
        });
    }

    res._status = header.status;
    res._url = try self._page.arena.dupeZ(u8, std.mem.span(header.url));
    res._is_redirected = header.redirect_count > 0;

    // Determine response type based on origin comparison
    const page_origin = URL.getOrigin(self._page.call_arena, self._page.url) catch null;
    const response_origin = URL.getOrigin(self._page.call_arena, res._url) catch null;

    if (page_origin) |po| {
        if (response_origin) |ro| {
            if (std.mem.eql(u8, po, ro)) {
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

    var it = transfer.responseHeaderIterator();
    while (it.next()) |hdr| {
        try res._headers.append(hdr.name, hdr.value, self._page);
    }
}

fn httpDataCallback(transfer: *Http.Transfer, data: []const u8) !void {
    const self: *Fetch = @ptrCast(@alignCast(transfer.ctx));
    try self._buf.appendSlice(self._page.arena, data);
}

fn httpDoneCallback(ctx: *anyopaque) !void {
    const self: *Fetch = @ptrCast(@alignCast(ctx));
    self._response._body = self._buf.items;

    log.info(.http, "request complete", .{
        .source = "fetch",
        .url = self._url,
        .status = self._response._status,
        .len = self._buf.items.len,
    });

    return self._resolver.local().resolve("fetch done", self._response);
}

fn httpErrorCallback(ctx: *anyopaque, err: anyerror) void {
    const self: *Fetch = @ptrCast(@alignCast(ctx));
    self._response._type = .@"error"; // Set type to error for network failures
    self._resolver.local().reject("fetch error", @errorName(err));
}

const testing = @import("../../../testing.zig");
test "WebApi: fetch" {
    try testing.htmlRunner("net/fetch.html", .{});
}
