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

const Headers = @import("Headers.zig");
const Request = @import("Request.zig");
const Response = @import("Response.zig");

const Allocator = std.mem.Allocator;
const IS_DEBUG = @import("builtin").mode == .Debug;

const Fetch = @This();

_page: *Page,
_buf: std.ArrayList(u8),
_response: *Response,
_resolver: js.PersistentPromiseResolver,

pub const Input = Request.Input;

// @ZIGDOM just enough to get campfire demo working
pub fn init(input: Input, page: *Page) !js.Promise {
    const request = try Request.init(input, null, page);

    const fetch = try page.arena.create(Fetch);
    fetch.* = .{
        ._page = page,
        ._buf = .empty,
        ._resolver = try page.js.createPromiseResolver(.page),
        ._response = try Response.init(null, .{ .status = 0 }, page),
    };

    const http_client = page._session.browser.http_client;
    const headers = try http_client.newHeaders();

    if (comptime IS_DEBUG) {
        log.debug(.http, "fetch", .{ .url = request._url });
    }

    try http_client.request(.{
        .ctx = fetch,
        .url = request._url,
        .method = .GET,
        .headers = headers,
        .cookie_jar = &page._session.cookie_jar,
        .resource_type = .fetch,
        .header_callback = httpHeaderDoneCallback,
        .data_callback = httpDataCallback,
        .done_callback = httpDoneCallback,
        .error_callback = httpErrorCallback,
    });
    return fetch._resolver.promise();
}

fn httpHeaderDoneCallback(transfer: *Http.Transfer) !void {
    const self: *Fetch = @ptrCast(@alignCast(transfer.ctx));

    if (transfer.getContentLength()) |cl| {
        try self._buf.ensureTotalCapacity(self._page.arena, cl);
    }

    const res = self._response;
    res._status = transfer.response_header.?.status;
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
    return self._resolver.resolve(self._response);
}

fn httpErrorCallback(ctx: *anyopaque, err: anyerror) void {
    const self: *Fetch = @ptrCast(@alignCast(ctx));
    self._resolver.reject(@errorName(err)) catch |inner| {
        log.err(.bug, "failed to reject", .{ .source = "fetch", .err = inner, .reject = err });
    };
}
