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
const js = @import("../../js/js.zig");
const Http = @import("../../../http/Http.zig");

const Page = @import("../../Page.zig");
const Headers = @import("Headers.zig");
const ReadableStream = @import("../streams/ReadableStream.zig");

const Allocator = std.mem.Allocator;

const Response = @This();

pub const Type = enum {
    basic,
    cors,
    @"error",
    @"opaque",
    opaqueredirect,
};

_status: u16,
_arena: Allocator,
_headers: *Headers,
_body: ?[]const u8,
_type: Type,
_status_text: []const u8,
_url: [:0]const u8,
_is_redirected: bool,
_transfer: ?*Http.Transfer = null,

const InitOpts = struct {
    status: u16 = 200,
    headers: ?Headers.InitOpts = null,
    statusText: ?[]const u8 = null,
};

pub fn init(body_: ?[]const u8, opts_: ?InitOpts, page: *Page) !*Response {
    const arena = try page.getArena(.{ .debug = "Response" });
    errdefer page.releaseArena(arena);

    const opts = opts_ orelse InitOpts{};

    // Store empty string as empty string, not null
    const body = if (body_) |b| try arena.dupe(u8, b) else null;
    const status_text = if (opts.statusText) |st| try arena.dupe(u8, st) else "";

    const self = try arena.create(Response);
    self.* = .{
        ._arena = arena,
        ._status = opts.status,
        ._status_text = status_text,
        ._url = "",
        ._body = body,
        ._type = .basic,
        ._is_redirected = false,
        ._headers = try Headers.init(opts.headers, page),
    };
    return self;
}

pub fn deinit(self: *Response, shutdown: bool, page: *Page) void {
    if (self._transfer) |transfer| {
        if (shutdown) {
            transfer.terminate();
        } else {
            transfer.abort(error.Abort);
        }
        self._transfer = null;
    }
    page.releaseArena(self._arena);
}

pub fn getStatus(self: *const Response) u16 {
    return self._status;
}

pub fn getStatusText(self: *const Response) []const u8 {
    return self._status_text;
}

pub fn getURL(self: *const Response) []const u8 {
    return self._url;
}

pub fn isRedirected(self: *const Response) bool {
    return self._is_redirected;
}

pub fn getHeaders(self: *const Response) *Headers {
    return self._headers;
}

pub fn getType(self: *const Response) []const u8 {
    return @tagName(self._type);
}

pub fn getBody(self: *const Response, page: *Page) !?*ReadableStream {
    const body = self._body orelse return null;

    // Empty string should create a closed stream with no data
    if (body.len == 0) {
        const stream = try ReadableStream.init(null, null, page);
        try stream._controller.close();
        return stream;
    }

    return ReadableStream.initWithData(body, page);
}

pub fn isOK(self: *const Response) bool {
    return self._status >= 200 and self._status <= 299;
}

pub fn getText(self: *const Response, page: *Page) !js.Promise {
    const body = self._body orelse "";
    return page.js.local.?.resolvePromise(body);
}

pub fn getJson(self: *Response, page: *Page) !js.Promise {
    const body = self._body orelse "";
    const local = page.js.local.?;
    const value = local.parseJSON(body) catch |err| {
        return local.rejectPromise(.{@errorName(err)});
    };
    return local.resolvePromise(try value.persist());
}

pub fn arrayBuffer(self: *const Response, page: *Page) !js.Promise {
    return page.js.local.?.resolvePromise(js.ArrayBuffer{ .values = self._body orelse "" });
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Response);

    pub const Meta = struct {
        pub const name = "Response";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
        pub const weak = true;
        pub const finalizer = bridge.finalizer(Response.deinit);
    };

    pub const constructor = bridge.constructor(Response.init, .{});
    pub const ok = bridge.accessor(Response.isOK, null, .{});
    pub const status = bridge.accessor(Response.getStatus, null, .{});
    pub const statusText = bridge.accessor(Response.getStatusText, null, .{});
    pub const @"type" = bridge.accessor(Response.getType, null, .{});
    pub const text = bridge.function(Response.getText, .{});
    pub const json = bridge.function(Response.getJson, .{});
    pub const headers = bridge.accessor(Response.getHeaders, null, .{});
    pub const body = bridge.accessor(Response.getBody, null, .{});
    pub const url = bridge.accessor(Response.getURL, null, .{});
    pub const redirected = bridge.accessor(Response.isRedirected, null, .{});
    pub const arrayBuffer = bridge.function(Response.arrayBuffer, .{});
};

const testing = @import("../../../testing.zig");
test "WebApi: Response" {
    try testing.htmlRunner("net/response.html", .{});
}
