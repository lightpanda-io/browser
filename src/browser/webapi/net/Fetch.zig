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
const Allocator = std.mem.Allocator;

const IS_DEBUG = @import("builtin").mode == .Debug;

const Fetch = @This();

_page: *Page,
_url: []const u8,
_buf: std.ArrayList(u8),
_response: *Response,
_resolver: js.PromiseResolver.Global,
_owns_response: bool,

pub const Input = Request.Input;
pub const InitOpts = Request.InitOpts;

pub fn init(input: Input, options: ?InitOpts, page: *Page) !js.Promise {
    const request = try Request.init(input, options, page);
    const request_url = try fetchRequestUrlForFetch(page.arena, request._url);
    const response = try Response.init(null, .{ .status = 0 }, page);
    errdefer response.deinit(true, page);

    const resolver = page.js.local.?.createPromiseResolver();

    const fetch = try response._arena.create(Fetch);
    fetch.* = .{
        ._page = page,
        ._buf = .empty,
        ._url = try response._arena.dupe(u8, request_url),
        ._resolver = try resolver.persist(),
        ._response = response,
        ._owns_response = true,
    };

    const http_client = page._session.browser.http_client;
    var headers = try http_client.newHeaders();
    if (request._headers) |h| {
        try h.populateHttpHeader(page.call_arena, &headers);
    }
    const include_credentials = try fetchIncludesCredentials(request, page);
    try page.headersForRequestWithPolicy(page.arena, request_url, &headers, .{
        .include_credentials = include_credentials,
        .authorization_source_url = request._url,
    });

    if (comptime IS_DEBUG) {
        log.debug(.http, "fetch", .{ .url = request._url });
    }

    try http_client.request(.{
        .ctx = fetch,
        .url = request_url,
        .method = request._method,
        .frame_id = page._frame_id,
        .body = request._body,
        .headers = headers,
        .resource_type = .fetch,
        .cookie_jar = if (include_credentials) page._session.cookie_jar else null,
        .notification = page._session.notification,
        .start_callback = httpStartCallback,
        .header_callback = httpHeaderDoneCallback,
        .data_callback = httpDataCallback,
        .done_callback = httpDoneCallback,
        .error_callback = httpErrorCallback,
        .shutdown_callback = httpShutdownCallback,
    });
    return resolver.promise();
}

fn fetchIncludesCredentials(request: *const Request, page: *Page) !bool {
    return switch (request._credentials) {
        .omit => false,
        .include => true,
        .@"same-origin" => try page.isSameOrigin(request._url),
    };
}

fn fetchRequestUrlForFetch(
    allocator: Allocator,
    url: [:0]const u8,
) ![:0]const u8 {
    if (URL.getUsername(url).len == 0) {
        return try allocator.dupeZ(u8, url);
    }

    return try URL.buildUrl(
        allocator,
        URL.getProtocol(url),
        URL.getHost(url),
        URL.getPathname(url),
        URL.getSearch(url),
        URL.getHash(url),
    );
}

fn httpStartCallback(transfer: *Http.Transfer) !void {
    const self: *Fetch = @ptrCast(@alignCast(transfer.ctx));
    if (comptime IS_DEBUG) {
        log.debug(.http, "request start", .{ .url = self._url, .source = "fetch" });
    }
    self._response._transfer = transfer;
}

fn httpHeaderDoneCallback(transfer: *Http.Transfer) !bool {
    const self: *Fetch = @ptrCast(@alignCast(transfer.ctx));

    const arena = self._response._arena;
    if (transfer.getContentLength()) |cl| {
        try self._buf.ensureTotalCapacity(arena, cl);
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
    res._status_text = std.http.Status.phrase(@enumFromInt(header.status)) orelse "";
    res._url = try arena.dupeZ(u8, std.mem.span(header.url));
    res._is_redirected = header.redirect_count > 0;

    // Determine response type based on origin comparison
    const page_origin = URL.getOrigin(arena, self._page.url) catch null;
    const response_origin = URL.getOrigin(arena, res._url) catch null;

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

    return true;
}

fn httpDataCallback(transfer: *Http.Transfer, data: []const u8) !void {
    const self: *Fetch = @ptrCast(@alignCast(transfer.ctx));
    try self._buf.appendSlice(self._response._arena, data);
}

fn httpDoneCallback(ctx: *anyopaque) !void {
    const self: *Fetch = @ptrCast(@alignCast(ctx));
    var response = self._response;
    response._transfer = null;
    response._body = self._buf.items;

    log.info(.http, "request complete", .{
        .source = "fetch",
        .url = self._url,
        .status = response._status,
        .len = self._buf.items.len,
    });

    var ls: js.Local.Scope = undefined;
    self._page.js.localScope(&ls);
    defer ls.deinit();

    const js_val = try ls.local.zigValueToJs(self._response, .{});
    self._owns_response = false;
    return ls.toLocal(self._resolver).resolve("fetch done", js_val);
}

fn httpErrorCallback(ctx: *anyopaque, err: anyerror) void {
    const self: *Fetch = @ptrCast(@alignCast(ctx));

    var response = self._response;
    response._transfer = null;
    // the response is only passed on v8 on success, if we're here, it's safe to
    // clear this. (defer since `self is in the response's arena).

    defer if (self._owns_response) {
        response.deinit(err == error.Abort, self._page);
        self._owns_response = false;
    };

    var ls: js.Local.Scope = undefined;
    self._page.js.localScope(&ls);
    defer ls.deinit();

    ls.toLocal(self._resolver).reject("fetch error", @errorName(err));
}

fn httpShutdownCallback(ctx: *anyopaque) void {
    const self: *Fetch = @ptrCast(@alignCast(ctx));
    if (comptime IS_DEBUG) {
        // should always be true
        std.debug.assert(self._owns_response);
    }

    if (self._owns_response) {
        var response = self._response;
        response._transfer = null;
        response.deinit(true, self._page);
        // Do not access `self` after this point: the Fetch struct was
        // allocated from response._arena which has been released.
    }
}

const testing = @import("../../../testing.zig");
test "WebApi: fetch" {
    try testing.htmlRunner("net/fetch.html", .{});
}

test "fetchIncludesCredentials respects request credentials policy" {
    var page = try testing.pageTest("page/auth_image_inherited.html");
    defer page._session.removePage();

    const omit_request = try Request.init(.{ .url = "http://127.0.0.1:9582/private.png" }, .{
        .credentials = .omit,
    }, page);
    try std.testing.expect(!(try fetchIncludesCredentials(omit_request, page)));

    const include_request = try Request.init(.{ .url = "http://127.0.0.1:9583/private.png" }, .{
        .credentials = .include,
    }, page);
    try std.testing.expect(try fetchIncludesCredentials(include_request, page));

    const same_origin_request = try Request.init(.{ .url = "http://127.0.0.1:9582/private.png" }, .{
        .credentials = .@"same-origin",
    }, page);
    try std.testing.expect(try fetchIncludesCredentials(same_origin_request, page));

    const cross_origin_request = try Request.init(.{ .url = "http://127.0.0.1:9583/private.png" }, .{
        .credentials = .@"same-origin",
    }, page);
    try std.testing.expect(!(try fetchIncludesCredentials(cross_origin_request, page)));
}

test "fetchRequestUrlForFetch strips userinfo from request url" {
    const allocator = std.testing.allocator;

    const stripped = try fetchRequestUrlForFetch(
        allocator,
        "http://fetch%20user:p%40ss@127.0.0.1:9582/private.png?x=1#frag",
    );
    defer allocator.free(stripped);
    try std.testing.expectEqualStrings("http://127.0.0.1:9582/private.png?x=1#frag", stripped);

    const kept = try fetchRequestUrlForFetch(
        allocator,
        "http://127.0.0.1:9582/private.png?x=1#frag",
    );
    defer allocator.free(kept);
    try std.testing.expectEqualStrings("http://127.0.0.1:9582/private.png?x=1#frag", kept);
}
