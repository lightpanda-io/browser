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
const log = @import("../../log.zig");

const URL = @import("../../url.zig").URL;
const Page = @import("../page.zig").Page;

const Response = @import("./Response.zig");

const Http = @import("../../http/Http.zig");

const v8 = @import("v8");
const Env = @import("../env.zig").Env;

const Headers = @import("Headers.zig");
const HeadersInit = @import("Headers.zig").HeadersInit;

pub const RequestInput = union(enum) {
    string: []const u8,
    request: *Request,
};

// https://developer.mozilla.org/en-US/docs/Web/API/RequestInit
pub const RequestInit = struct {
    method: ?[]const u8 = null,
    body: ?[]const u8 = null,
    integrity: ?[]const u8 = null,
    headers: ?HeadersInit = null,
};

// https://developer.mozilla.org/en-US/docs/Web/API/Request/Request
const Request = @This();

method: Http.Method,
url: [:0]const u8,
headers: Headers,
body: ?[]const u8,
body_used: bool = false,
integrity: []const u8,

pub fn constructor(input: RequestInput, _options: ?RequestInit, page: *Page) !Request {
    const arena = page.arena;
    const options: RequestInit = _options orelse .{};

    const url = blk: switch (input) {
        .string => |str| {
            break :blk try URL.stitch(arena, str, page.url.raw, .{ .null_terminated = true });
        },
        .request => |req| {
            break :blk try arena.dupeZ(u8, req.url);
        },
    };

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

    const body = if (options.body) |body| try arena.dupe(u8, body) else null;
    const integrity = if (options.integrity) |integ| try arena.dupe(u8, integ) else "";
    const headers = if (options.headers) |hdrs| try Headers.constructor(hdrs, page) else Headers{};

    return .{
        .method = method,
        .url = url,
        .headers = headers,
        .body = body,
        .integrity = integrity,
    };
}

// pub fn get_body(self: *const Request) ?[]const u8 {
//     return self.body;
// }

pub fn get_bodyUsed(self: *const Request) bool {
    return self.body_used;
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

pub fn get_url(self: *const Request) []const u8 {
    return self.url;
}

pub fn _clone(self: *Request, page: *Page) !Request {
    // Not allowed to clone if the body was used.
    if (self.body_used) {
        return error.TypeError;
    }

    const arena = page.arena;

    return Request{
        .body = if (self.body) |body| try arena.dupe(u8, body) else null,
        .body_used = self.body_used,
        .headers = try self.headers.clone(arena),
        .method = self.method,
        .integrity = try arena.dupe(u8, self.integrity),
        .url = try arena.dupeZ(u8, self.url),
    };
}

pub fn _bytes(self: *Response, page: *Page) !Env.Promise {
    if (self.body_used) {
        return error.TypeError;
    }

    const resolver = Env.PromiseResolver{
        .js_context = page.main_context,
        .resolver = v8.PromiseResolver.init(page.main_context.v8_context),
    };

    try resolver.resolve(self.body);
    self.body_used = true;
    return resolver.promise();
}

pub fn _json(self: *Response, page: *Page) !Env.Promise {
    if (self.body_used) {
        return error.TypeError;
    }

    const resolver = Env.PromiseResolver{
        .js_context = page.main_context,
        .resolver = v8.PromiseResolver.init(page.main_context.v8_context),
    };

    const p = std.json.parseFromSliceLeaky(
        std.json.Value,
        page.arena,
        self.body,
        .{},
    ) catch |e| {
        log.warn(.browser, "invalid json", .{ .err = e, .source = "Request" });
        return error.SyntaxError;
    };

    try resolver.resolve(p);
    self.body_used = true;
    return resolver.promise();
}

pub fn _text(self: *Response, page: *Page) !Env.Promise {
    if (self.body_used) {
        return error.TypeError;
    }

    const resolver = Env.PromiseResolver{
        .js_context = page.main_context,
        .resolver = v8.PromiseResolver.init(page.main_context.v8_context),
    };

    try resolver.resolve(self.body);
    self.body_used = true;
    return resolver.promise();
}

const testing = @import("../../testing.zig");
test "fetch: request" {
    var runner = try testing.jsRunner(testing.tracking_allocator, .{ .url = "https://lightpanda.io" });
    defer runner.deinit();

    try runner.testCases(&.{
        .{ "let request = new Request('flower.png')", "undefined" },
        .{ "request.url", "https://lightpanda.io/flower.png" },
        .{ "request.method", "GET" },
    }, .{});

    try runner.testCases(&.{
        .{ "let request2 = new Request('https://google.com', { method: 'POST', body: 'Hello, World' })", "undefined" },
        .{ "request2.url", "https://google.com" },
        .{ "request2.method", "POST" },
    }, .{});
}

test "fetch: Browser.fetch" {
    var runner = try testing.jsRunner(testing.tracking_allocator, .{});
    defer runner.deinit();

    try runner.testCases(&.{
        .{
            \\  var ok = false;
            \\  const request = new Request("http://127.0.0.1:9582/loader");
            \\  fetch(request).then((response) => { ok = response.ok; });
            \\  false;
            ,
            "false",
        },
        // all events have been resolved.
        .{ "ok", "true" },
    }, .{});

    try runner.testCases(&.{
        .{
            \\  var ok2 = false;
            \\  const request2 = new Request("http://127.0.0.1:9582/loader");
            \\  (async function () { resp = await fetch(request2); ok2 = resp.ok; }());
            \\  false;
            ,
            "false",
        },
        // all events have been resolved.
        .{ "ok2", "true" },
    }, .{});
}
