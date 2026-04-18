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
const http = @import("../../../network/http.zig");

const URL = @import("../URL.zig");
const Page = @import("../../Page.zig");
const Headers = @import("Headers.zig");
const Blob = @import("../Blob.zig");
const AbortSignal = @import("../AbortSignal.zig");
const Allocator = std.mem.Allocator;

const Request = @This();

_url: [:0]const u8,
_method: http.Method,
_headers: ?*Headers,
_body: ?[]const u8,
_arena: Allocator,
_cache: Cache,
_credentials: Credentials,
_signal: ?*AbortSignal,

pub const Input = union(enum) {
    request: *Request,
    url: [:0]const u8,
};

pub const InitOpts = struct {
    method: ?[]const u8 = null,
    headers: ?Headers.InitOpts = null,
    body: ?[]const u8 = null,
    cache: Cache = .default,
    credentials: Credentials = .@"same-origin",
    signal: ?*AbortSignal = null,
};

const Credentials = enum {
    omit,
    include,
    @"same-origin",
    pub const js_enum_from_string = true;
};

const Cache = enum {
    default,
    @"no-store",
    reload,
    @"no-cache",
    @"force-cache",
    @"only-if-cached",
    pub const js_enum_from_string = true;
};

pub fn init(input: Input, opts_: ?InitOpts, page: *Page) !*Request {
    const arena = page.arena;
    const url = switch (input) {
        .url => |u| try URL.resolve(arena, page.base(), u, .{ .always_dupe = true, .encoding = page.charset }),
        .request => |r| try arena.dupeZ(u8, r._url),
    };

    const opts = opts_ orelse InitOpts{};
    const method = if (opts.method) |m|
        try parseMethod(m, page)
    else switch (input) {
        .url => .GET,
        .request => |r| r._method,
    };

    const headers = if (opts.headers) |headers_init| switch (headers_init) {
        .obj => |h| h,
        else => try Headers.init(headers_init, page),
    } else switch (input) {
        .url => null,
        .request => |r| r._headers,
    };

    const body = if (opts.body) |b|
        try arena.dupe(u8, b)
    else switch (input) {
        .url => null,
        .request => |r| r._body,
    };

    const signal = if (opts.signal) |s|
        s
    else switch (input) {
        .url => null,
        .request => |r| r._signal,
    };

    return page._factory.create(Request{
        ._url = url,
        ._arena = arena,
        ._method = method,
        ._headers = headers,
        ._cache = opts.cache,
        ._credentials = opts.credentials,
        ._body = body,
        ._signal = signal,
    });
}

fn parseMethod(method: []const u8, page: *Page) !http.Method {
    if (method.len > "propfind".len) {
        return error.InvalidMethod;
    }

    const lower = std.ascii.lowerString(&page.buf, method);

    const method_lookup = std.StaticStringMap(http.Method).initComptime(.{
        .{ "get", .GET },
        .{ "post", .POST },
        .{ "delete", .DELETE },
        .{ "put", .PUT },
        .{ "patch", .PATCH },
        .{ "head", .HEAD },
        .{ "options", .OPTIONS },
        .{ "propfind", .PROPFIND },
    });
    return method_lookup.get(lower) orelse return error.InvalidMethod;
}

pub fn getUrl(self: *const Request) []const u8 {
    return self._url;
}

pub fn getMethod(self: *const Request) []const u8 {
    return @tagName(self._method);
}

pub fn getCache(self: *const Request) []const u8 {
    return @tagName(self._cache);
}

pub fn getCredentials(self: *const Request) []const u8 {
    return @tagName(self._credentials);
}

pub fn getSignal(self: *const Request) ?*AbortSignal {
    return self._signal;
}

pub fn getHeaders(self: *Request, page: *Page) !*Headers {
    if (self._headers) |headers| {
        return headers;
    }

    const headers = try Headers.init(null, page);
    self._headers = headers;
    return headers;
}

pub fn blob(self: *Request, page: *Page) !js.Promise {
    const body = self._body orelse "";
    const headers = try self.getHeaders(page);
    const content_type = try headers.get("content-type", page) orelse "";

    const b = try Blob.initFromBytes(body, content_type, true, page);

    return page.js.local.?.resolvePromise(b);
}

pub fn text(self: *const Request, page: *Page) !js.Promise {
    const body = self._body orelse "";
    return page.js.local.?.resolvePromise(body);
}

pub fn json(self: *const Request, page: *Page) !js.Promise {
    const body = self._body orelse "";
    const local = page.js.local.?;
    const value = local.parseJSON(body) catch {
        return local.rejectPromise(.{ .syntax_error = "failed to parse" });
    };
    return local.resolvePromise(try value.persist());
}

pub fn arrayBuffer(self: *const Request, page: *Page) !js.Promise {
    return page.js.local.?.resolvePromise(js.ArrayBuffer{ .values = self._body orelse "" });
}

pub fn bytes(self: *const Request, page: *Page) !js.Promise {
    return page.js.local.?.resolvePromise(js.TypedArray(u8){ .values = self._body orelse "" });
}

pub fn clone(self: *const Request, page: *Page) !*Request {
    return page._factory.create(Request{
        ._url = self._url,
        ._arena = self._arena,
        ._method = self._method,
        ._headers = self._headers,
        ._cache = self._cache,
        ._credentials = self._credentials,
        ._body = self._body,
        ._signal = self._signal,
    });
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Request);

    pub const Meta = struct {
        pub const name = "Request";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(Request.init, .{});
    pub const url = bridge.accessor(Request.getUrl, null, .{});
    pub const method = bridge.accessor(Request.getMethod, null, .{});
    pub const headers = bridge.accessor(Request.getHeaders, null, .{});
    pub const cache = bridge.accessor(Request.getCache, null, .{});
    pub const credentials = bridge.accessor(Request.getCredentials, null, .{});
    pub const signal = bridge.accessor(Request.getSignal, null, .{});
    pub const blob = bridge.function(Request.blob, .{});
    pub const text = bridge.function(Request.text, .{});
    pub const json = bridge.function(Request.json, .{});
    pub const arrayBuffer = bridge.function(Request.arrayBuffer, .{});
    pub const bytes = bridge.function(Request.bytes, .{});
    pub const clone = bridge.function(Request.clone, .{});
};

const testing = @import("../../../testing.zig");
test "WebApi: Request" {
    try testing.htmlRunner("net/request.html", .{});
}
