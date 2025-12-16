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

const URL = @import("../URL.zig");
const Page = @import("../../Page.zig");
const Headers = @import("Headers.zig");
const Allocator = std.mem.Allocator;

const Request = @This();

_url: [:0]const u8,
_method: Http.Method,
_headers: ?*Headers,
_body: ?[]const u8,
_arena: Allocator,
_cache: Cache,
_credentials: Credentials,

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
    @"reload",
    @"no-cache",
    @"force-cache",
    @"only-if-cached",
    pub const js_enum_from_string = true;
};

pub fn init(input: Input, opts_: ?InitOpts, page: *Page) !*Request {
    const arena = page.arena;
    const url = switch (input) {
        .url => |u| try URL.resolve(arena, page.url, u, .{ .always_dupe = true }),
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

    return page._factory.create(Request{
        ._url = url,
        ._arena = arena,
        ._method = method,
        ._headers = headers,
        ._cache = opts.cache,
        ._credentials = opts.credentials,
        ._body = body,
    });
}

fn parseMethod(method: []const u8, page: *Page) !Http.Method {
    if (method.len > "options".len) {
        return error.InvalidMethod;
    }

    const lower = std.ascii.lowerString(&page.buf, method);

    const method_lookup = std.StaticStringMap(Http.Method).initComptime(.{
        .{ "get", .GET },
        .{ "post", .POST },
        .{ "delete", .DELETE },
        .{ "put", .PUT },
        .{ "patch", .PATCH },
        .{ "head", .HEAD },
        .{ "options", .OPTIONS },
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

pub fn getHeaders(self: *Request, page: *Page) !*Headers {
    if (self._headers) |headers| {
        return headers;
    }

    const headers = try Headers.init(null, page);
    self._headers = headers;
    return headers;
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
};

const testing = @import("../../../testing.zig");
test "WebApi: Request" {
    try testing.htmlRunner("net/request.html", .{});
}
