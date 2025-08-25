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
const HttpClient = @import("../../http/Client.zig");
const Mime = @import("../mime.zig").Mime;

const v8 = @import("v8");
const Env = @import("../env.zig").Env;

pub const RequestInput = union(enum) {
    string: []const u8,
    request: Request,
};

// https://developer.mozilla.org/en-US/docs/Web/API/RequestInit
pub const RequestInit = struct {
    method: ?[]const u8 = null,
    body: ?[]const u8 = null,
};

// https://developer.mozilla.org/en-US/docs/Web/API/Request/Request
const Request = @This();

method: Http.Method,
url: [:0]const u8,
body: ?[]const u8,

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

    return .{
        .method = method,
        .url = url,
        .body = body,
    };
}

pub fn get_url(self: *const Request) []const u8 {
    return self.url;
}

pub fn get_method(self: *const Request) []const u8 {
    return @tagName(self.method);
}

// pub fn get_body(self: *const Request) ?[]const u8 {
//     return self.body;
// }

const FetchContext = struct {
    arena: std.mem.Allocator,
    js_ctx: *Env.JsContext,
    promise_resolver: v8.Persistent(v8.PromiseResolver),

    method: Http.Method,
    url: []const u8,
    body: std.ArrayListUnmanaged(u8) = .empty,
    headers: std.ArrayListUnmanaged([]const u8) = .empty,
    status: u16 = 0,
    mime: ?Mime = null,
    transfer: ?*HttpClient.Transfer = null,

    /// This effectively takes ownership of the FetchContext.
    ///
    /// We just return the underlying slices used for `headers`
    /// and for `body` here to avoid an allocation.
    pub fn toResponse(self: *const FetchContext) !Response {
        return Response{
            .status = self.status,
            .headers = self.headers.items,
            .mime = self.mime,
            .body = self.body.items,
        };
    }
};

// https://developer.mozilla.org/en-US/docs/Web/API/Window/fetch
pub fn fetch(input: RequestInput, options: ?RequestInit, page: *Page) !Env.Promise {
    const arena = page.arena;

    const req = try Request.constructor(input, options, page);

    const resolver = Env.PromiseResolver{
        .js_context = page.main_context,
        .resolver = v8.PromiseResolver.init(page.main_context.v8_context),
    };

    var headers = try Http.Headers.init();
    try page.requestCookie(.{}).headersForRequest(arena, req.url, &headers);

    const fetch_ctx = try arena.create(FetchContext);
    fetch_ctx.* = .{
        .arena = arena,
        .js_ctx = page.main_context,
        .promise_resolver = v8.Persistent(v8.PromiseResolver).init(
            page.main_context.isolate,
            resolver.resolver,
        ),
        .method = req.method,
        .url = req.url,
    };

    try page.http_client.request(.{
        .ctx = @ptrCast(fetch_ctx),
        .url = req.url,
        .method = req.method,
        .headers = headers,
        .body = req.body,
        .cookie_jar = page.cookie_jar,
        .resource_type = .fetch,

        .start_callback = struct {
            fn startCallback(transfer: *HttpClient.Transfer) !void {
                const self: *FetchContext = @alignCast(@ptrCast(transfer.ctx));
                log.debug(.http, "request start", .{ .method = self.method, .url = self.url, .source = "fetch" });

                self.transfer = transfer;
            }
        }.startCallback,
        .header_callback = struct {
            fn headerCallback(transfer: *HttpClient.Transfer) !void {
                const self: *FetchContext = @alignCast(@ptrCast(transfer.ctx));

                const header = &transfer.response_header.?;

                log.debug(.http, "request header", .{
                    .source = "fetch",
                    .method = self.method,
                    .url = self.url,
                    .status = header.status,
                });

                if (header.contentType()) |ct| {
                    self.mime = Mime.parse(ct) catch {
                        return error.MimeParsing;
                    };
                }

                var it = transfer.responseHeaderIterator();
                while (it.next()) |hdr| {
                    const joined = try std.fmt.allocPrint(self.arena, "{s}: {s}", .{ hdr.name, hdr.value });
                    try self.headers.append(self.arena, joined);
                }

                self.status = header.status;
            }
        }.headerCallback,
        .data_callback = struct {
            fn dataCallback(transfer: *HttpClient.Transfer, data: []const u8) !void {
                const self: *FetchContext = @alignCast(@ptrCast(transfer.ctx));
                try self.body.appendSlice(self.arena, data);
            }
        }.dataCallback,
        .done_callback = struct {
            fn doneCallback(ctx: *anyopaque) !void {
                const self: *FetchContext = @alignCast(@ptrCast(ctx));

                log.info(.http, "request complete", .{
                    .source = "fetch",
                    .method = self.method,
                    .url = self.url,
                    .status = self.status,
                });

                const response = try self.toResponse();
                const promise_resolver: Env.PromiseResolver = .{
                    .js_context = self.js_ctx,
                    .resolver = self.promise_resolver.castToPromiseResolver(),
                };

                try promise_resolver.resolve(response);
            }
        }.doneCallback,
        .error_callback = struct {
            fn errorCallback(ctx: *anyopaque, err: anyerror) void {
                const self: *FetchContext = @alignCast(@ptrCast(ctx));

                self.transfer = null;
                const promise_resolver: Env.PromiseResolver = .{
                    .js_context = self.js_ctx,
                    .resolver = self.promise_resolver.castToPromiseResolver(),
                };

                promise_resolver.reject(@errorName(err)) catch unreachable;
            }
        }.errorCallback,
    });

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
        .{ "request2.body", "Hello, World" },
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
