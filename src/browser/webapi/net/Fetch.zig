const std = @import("std");

const log = @import("../../../log.zig");
const Http = @import("../../../http/Http.zig");

const js = @import("../../js/js.zig");
const Page = @import("../../Page.zig");

const Request = @import("Request.zig");
const Response = @import("Response.zig");

const Allocator = std.mem.Allocator;

const Fetch = @This();

_page: *Page,
_response: std.ArrayList(u8),
_resolver: js.PersistentPromiseResolver,

pub const Input = Request.Input;

// @ZIGDOM just enough to get campire demo working
pub fn init(input: Input, page: *Page) !js.Promise {
    const request = try Request.init(input, page);

    const fetch = try page.arena.create(Fetch);
    fetch.* = .{
        ._page = page,
        ._response = .empty,
        ._resolver = try page.js.createPromiseResolver(.page),
    };

    const http_client = page._session.browser.http_client;
    const headers = try http_client.newHeaders();

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
    _ = self;
}

fn httpDataCallback(transfer: *Http.Transfer, data: []const u8) !void {
    const self: *Fetch = @ptrCast(@alignCast(transfer.ctx));
    try self._response.appendSlice(self._page.arena, data);
}

fn httpDoneCallback(ctx: *anyopaque) !void {
    const self: *Fetch = @ptrCast(@alignCast(ctx));

    const page = self._page;
    const res = try Response.initFromFetch(page.arena, self._response.items, page);
    return self._resolver.resolve(res);
}

fn httpErrorCallback(ctx: *anyopaque, err: anyerror) void {
    const self: *Fetch = @ptrCast(@alignCast(ctx));
    self._resolver.reject(@errorName(err)) catch |inner| {
        log.err(.bug, "failed to reject", .{ .source = "fetch", .err = inner, .reject = err });
    };
}
