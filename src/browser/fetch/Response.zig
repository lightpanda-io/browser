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

const HttpClient = @import("../../http/Client.zig");
const Http = @import("../../http/Http.zig");
const URL = @import("../../url.zig").URL;

const ReadableStream = @import("../streams/ReadableStream.zig");
const Headers = @import("Headers.zig");
const HeadersInit = @import("Headers.zig").HeadersInit;

const Mime = @import("../mime.zig").Mime;
const Page = @import("../page.zig").Page;

// https://developer.mozilla.org/en-US/docs/Web/API/Response
const Response = @This();

status: u16 = 200,
status_text: []const u8 = "",
headers: Headers,
mime: ?Mime = null,
url: []const u8 = "",
body: ?[]const u8 = null,
body_used: bool = false,
redirected: bool = false,
type: ResponseType = .basic,

const ResponseBody = union(enum) {
    string: []const u8,
};

const ResponseOptions = struct {
    status: u16 = 200,
    statusText: ?[]const u8 = null,
    headers: ?HeadersInit = null,
};

pub const ResponseType = enum {
    basic,
    cors,
    @"error",
    @"opaque",
    opaqueredirect,

    pub fn fromString(str: []const u8) ?ResponseType {
        for (std.enums.values(ResponseType)) |cache| {
            if (std.ascii.eqlIgnoreCase(str, @tagName(cache))) {
                return cache;
            }
        } else {
            return null;
        }
    }

    pub fn toString(self: ResponseType) []const u8 {
        return @tagName(self);
    }
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
            break :blk null;
        }
    };

    const headers: Headers = if (options.headers) |hdrs| try Headers.constructor(hdrs, page) else .{};
    const status_text = if (options.statusText) |st| try arena.dupe(u8, st) else "";

    return .{
        .body = body,
        .headers = headers,
        .status = options.status,
        .status_text = status_text,
    };
}

pub fn get_body(self: *const Response, page: *Page) !*ReadableStream {
    const stream = try ReadableStream.constructor(null, null, page);
    if (self.body) |body| {
        try stream.queue.append(page.arena, .{ .string = body });
    }
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

pub fn get_statusText(self: *const Response) []const u8 {
    return self.status_text;
}

pub fn get_type(self: *const Response) ResponseType {
    return self.type;
}

pub fn get_url(self: *const Response) []const u8 {
    return self.url;
}

pub fn _clone(self: *const Response) !Response {
    if (self.body_used) {
        return error.TypeError;
    }

    // OK to just return the same fields BECAUSE
    // all of these fields are read-only and can't be modified.
    return Response{
        .body = self.body,
        .body_used = self.body_used,
        .mime = self.mime,
        .headers = self.headers,
        .redirected = self.redirected,
        .status = self.status,
        .url = self.url,
        .type = self.type,
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

    if (self.body) |body| {
        self.body_used = true;
        const p = std.json.parseFromSliceLeaky(
            std.json.Value,
            page.call_arena,
            body,
            .{},
        ) catch |e| {
            log.info(.browser, "invalid json", .{ .err = e, .source = "Response" });
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
test "fetch: Response" {
    try testing.htmlRunner("fetch/response.html");
}
