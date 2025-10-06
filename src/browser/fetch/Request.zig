// Copyright (C) 2023-2024  Lightpanda (Selecy SAS)
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
const js = @import("../js/js.zig");
const log = @import("../../log.zig");

const URL = @import("../../url.zig").URL;
const Page = @import("../page.zig").Page;

const Response = @import("./Response.zig");
const Http = @import("../../http/Http.zig");
const ReadableStream = @import("../streams/ReadableStream.zig");

const Headers = @import("Headers.zig");
const HeadersInit = @import("Headers.zig").HeadersInit;

pub const RequestInput = union(enum) {
    string: []const u8,
    request: *Request,
};

pub const RequestCache = enum {
    default,
    @"no-store",
    reload,
    @"no-cache",
    @"force-cache",
    @"only-if-cached",

    pub fn fromString(str: []const u8) ?RequestCache {
        for (std.enums.values(RequestCache)) |cache| {
            if (std.ascii.eqlIgnoreCase(str, @tagName(cache))) {
                return cache;
            }
        } else {
            return null;
        }
    }

    pub fn toString(self: RequestCache) []const u8 {
        return @tagName(self);
    }
};

pub const RequestCredentials = enum {
    omit,
    @"same-origin",
    include,

    pub fn fromString(str: []const u8) ?RequestCredentials {
        for (std.enums.values(RequestCredentials)) |cache| {
            if (std.ascii.eqlIgnoreCase(str, @tagName(cache))) {
                return cache;
            }
        } else {
            return null;
        }
    }

    pub fn toString(self: RequestCredentials) []const u8 {
        return @tagName(self);
    }
};

pub const RequestMode = enum {
    cors,
    @"no-cors",
    @"same-origin",
    navigate,

    pub fn fromString(str: []const u8) ?RequestMode {
        for (std.enums.values(RequestMode)) |cache| {
            if (std.ascii.eqlIgnoreCase(str, @tagName(cache))) {
                return cache;
            }
        } else {
            return null;
        }
    }

    pub fn toString(self: RequestMode) []const u8 {
        return @tagName(self);
    }
};

// https://developer.mozilla.org/en-US/docs/Web/API/RequestInit
pub const RequestInit = struct {
    body: ?[]const u8 = null,
    cache: ?[]const u8 = null,
    credentials: ?[]const u8 = null,
    headers: ?HeadersInit = null,
    integrity: ?[]const u8 = null,
    method: ?[]const u8 = null,
    mode: ?[]const u8 = null,
};

// https://developer.mozilla.org/en-US/docs/Web/API/Request/Request
const Request = @This();

method: Http.Method,
url: [:0]const u8,
cache: RequestCache,
credentials: RequestCredentials,
// no-cors is default is not built with constructor.
mode: RequestMode = .@"no-cors",
headers: Headers,
body: ?[]const u8,
body_used: bool = false,
integrity: []const u8,

pub fn constructor(input: RequestInput, _options: ?RequestInit, page: *Page) !Request {
    const arena = page.arena;
    const options: RequestInit = _options orelse .{};

    const url: [:0]const u8 = blk: switch (input) {
        .string => |str| {
            break :blk try URL.stitch(arena, str, page.url.raw, .{ .null_terminated = true });
        },
        .request => |req| {
            break :blk try arena.dupeZ(u8, req.url);
        },
    };

    const cache = (if (options.cache) |cache| RequestCache.fromString(cache) else null) orelse RequestCache.default;
    const credentials = (if (options.credentials) |creds| RequestCredentials.fromString(creds) else null) orelse RequestCredentials.@"same-origin";
    const integrity = if (options.integrity) |integ| try arena.dupe(u8, integ) else "";
    const headers: Headers = if (options.headers) |hdrs| try Headers.constructor(hdrs, page) else .{};
    const mode = (if (options.mode) |mode| RequestMode.fromString(mode) else null) orelse RequestMode.cors;

    const method: Http.Method = blk: {
        if (options.method) |given_method| {
            for (std.enums.values(Http.Method)) |method| {
                if (std.ascii.eqlIgnoreCase(given_method, @tagName(method))) {
                    break :blk method;
                }
            } else {
                return error.TypeError;
            }
        } else {
            break :blk Http.Method.GET;
        }
    };

    // Can't have a body on .GET or .HEAD.
    const body: ?[]const u8 = blk: {
        if (method == .GET or method == .HEAD) {
            break :blk null;
        } else break :blk if (options.body) |body| try arena.dupe(u8, body) else null;
    };

    return .{
        .method = method,
        .url = url,
        .cache = cache,
        .credentials = credentials,
        .mode = mode,
        .headers = headers,
        .body = body,
        .integrity = integrity,
    };
}

pub fn get_body(self: *const Request, page: *Page) !?*ReadableStream {
    if (self.body) |body| {
        const stream = try ReadableStream.constructor(null, null, page);
        try stream.queue.append(page.arena, .{ .string = body });
        return stream;
    } else return null;
}

pub fn get_bodyUsed(self: *const Request) bool {
    return self.body_used;
}

pub fn get_cache(self: *const Request) RequestCache {
    return self.cache;
}

pub fn get_credentials(self: *const Request) RequestCredentials {
    return self.credentials;
}

pub fn get_headers(self: *Request) *Headers {
    return &self.headers;
}

pub fn get_integrity(self: *const Request) []const u8 {
    return self.integrity;
}

// TODO: If we ever support the Navigation API, we need isHistoryNavigation
// https://developer.mozilla.org/en-US/docs/Web/API/Request/isHistoryNavigation

pub fn get_method(self: *const Request) []const u8 {
    return @tagName(self.method);
}

pub fn get_mode(self: *const Request) RequestMode {
    return self.mode;
}

pub fn get_url(self: *const Request) []const u8 {
    return self.url;
}

pub fn _clone(self: *Request) !Request {
    // Not allowed to clone if the body was used.
    if (self.body_used) {
        return error.TypeError;
    }

    // OK to just return the same fields BECAUSE
    // all of these fields are read-only and can't be modified.
    return Request{
        .body = self.body,
        .body_used = self.body_used,
        .cache = self.cache,
        .credentials = self.credentials,
        .headers = self.headers,
        .method = self.method,
        .integrity = self.integrity,
        .url = self.url,
    };
}

pub fn _bytes(self: *Response, page: *Page) !js.Promise {
    if (self.body_used) {
        return error.TypeError;
    }
    self.body_used = true;
    return page.js.resolvePromise(self.body);
}

pub fn _json(self: *Response, page: *Page) !js.Promise {
    if (self.body_used) {
        return error.TypeError;
    }
    self.body_used = true;

    if (self.body) |body| {
        const p = std.json.parseFromSliceLeaky(
            std.json.Value,
            page.call_arena,
            body,
            .{},
        ) catch |e| {
            log.info(.browser, "invalid json", .{ .err = e, .source = "Request" });
            return error.SyntaxError;
        };

        return page.js.resolvePromise(p);
    }
    return page.js.resolvePromise(null);
}

pub fn _text(self: *Response, page: *Page) !js.Promise {
    if (self.body_used) {
        return error.TypeError;
    }
    self.body_used = true;
    return page.js.resolvePromise(self.body);
}

const testing = @import("../../testing.zig");
test "fetch: Request" {
    try testing.htmlRunner("fetch/request.html");
}
