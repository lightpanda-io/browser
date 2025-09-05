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

const v8 = @import("v8");

const HttpClient = @import("../../http/Client.zig");
const Http = @import("../../http/Http.zig");
const URL = @import("../../url.zig").URL;

const ReadableStream = @import("../streams/ReadableStream.zig");
const Headers = @import("Headers.zig");
const HeadersInit = @import("Headers.zig").HeadersInit;

const Env = @import("../env.zig").Env;
const Mime = @import("../mime.zig").Mime;
const Page = @import("../page.zig").Page;

// https://developer.mozilla.org/en-US/docs/Web/API/Response
const Response = @This();

status: u16 = 0,
headers: Headers,
mime: ?Mime = null,
url: []const u8 = "",
body: []const u8 = "",
body_used: bool = false,
redirected: bool = false,

const ResponseBody = union(enum) {
    string: []const u8,
};

const ResponseOptions = struct {
    status: u16 = 200,
    statusText: []const u8 = "",
    headers: ?HeadersInit = null,
};

pub fn constructor(_input: ?ResponseBody, _options: ?ResponseOptions, page: *Page) !Response {
    const arena = page.arena;

    const options: ResponseOptions = _options orelse .{};

    const body = blk: {
        if (_input) |input| {
            switch (input) {
                .string => |str| {
                    break :blk try arena.dupe(u8, str);
                },
            }
        } else {
            break :blk "";
        }
    };

    const headers: Headers = if (options.headers) |hdrs| try Headers.constructor(hdrs, page) else .{};

    return .{
        .body = body,
        .headers = headers,
    };
}

pub fn get_body(self: *const Response, page: *Page) !*ReadableStream {
    const stream = try ReadableStream.constructor(null, null, page);
    try stream.queue.append(page.arena, self.body);
    return stream;
}

pub fn get_bodyUsed(self: *const Response) bool {
    return self.body_used;
}

pub fn get_headers(self: *Response) *Headers {
    return &self.headers;
}

pub fn get_ok(self: *const Response) bool {
    return self.status >= 200 and self.status <= 299;
}

pub fn get_redirected(self: *const Response) bool {
    return self.redirected;
}

pub fn get_status(self: *const Response) u16 {
    return self.status;
}

pub fn get_url(self: *const Response) []const u8 {
    return self.url;
}

pub fn _clone(self: *const Response, page: *Page) !Response {
    if (self.body_used) {
        return error.TypeError;
    }

    const arena = page.arena;

    return Response{
        .body = try arena.dupe(u8, self.body),
        .body_used = self.body_used,
        .mime = if (self.mime) |mime| try mime.clone(arena) else null,
        .headers = try self.headers.clone(arena),
        .redirected = self.redirected,
        .status = self.status,
        .url = try arena.dupe(u8, self.url),
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
        log.warn(.browser, "invalid json", .{ .err = e, .source = "fetch" });
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
test "fetch: response" {
    var runner = try testing.jsRunner(testing.tracking_allocator, .{ .url = "https://lightpanda.io" });
    defer runner.deinit();

    try runner.testCases(&.{}, .{});
}
