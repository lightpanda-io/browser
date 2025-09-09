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
const Env = @import("../env.zig").Env;
const Page = @import("../page.zig").Page;

const Http = @import("../../http/Http.zig");
const HttpClient = @import("../../http/Client.zig");
const Mime = @import("../mime.zig").Mime;

const Headers = @import("Headers.zig");

const RequestInput = @import("Request.zig").RequestInput;
const RequestInit = @import("Request.zig").RequestInit;
const Request = @import("Request.zig");
const Response = @import("Response.zig");

pub const Interfaces = .{
    @import("Headers.zig"),
    @import("Headers.zig").HeaderEntryIterator,
    @import("Headers.zig").HeaderKeyIterator,
    @import("Headers.zig").HeaderValueIterator,
    @import("Request.zig"),
    @import("Response.zig"),
};

pub const FetchContext = struct {
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
        var headers: Headers = .{};

        // convert into Headers
        for (self.headers.items) |hdr| {
            var iter = std.mem.splitScalar(u8, hdr, ':');
            const name = iter.next() orelse "";
            const value = iter.next() orelse "";
            try headers.append(name, value, self.arena);
        }

        return Response{
            .status = self.status,
            .headers = headers,
            .mime = self.mime,
            .body = self.body.items,
            .url = self.url,
        };
    }

    pub fn destructor(self: *FetchContext) void {
        if (self.transfer) |_| {
            const resolver = Env.PromiseResolver{
                .js_context = self.js_ctx,
                .resolver = self.promise_resolver.castToPromiseResolver(),
            };

            resolver.reject("TypeError") catch unreachable;
            self.promise_resolver.deinit();
        }
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

    // Add destructor callback for FetchContext.
    try page.main_context.destructor_callbacks.append(arena, Env.DestructorCallback.init(fetch_ctx));

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
                const self: *FetchContext = @ptrCast(@alignCast(transfer.ctx));
                log.debug(.http, "request start", .{ .method = self.method, .url = self.url, .source = "fetch" });

                self.transfer = transfer;
            }
        }.startCallback,
        .header_callback = struct {
            fn headerCallback(transfer: *HttpClient.Transfer) !void {
                const self: *FetchContext = @ptrCast(@alignCast(transfer.ctx));

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
                const self: *FetchContext = @ptrCast(@alignCast(transfer.ctx));
                try self.body.appendSlice(self.arena, data);
            }
        }.dataCallback,
        .done_callback = struct {
            fn doneCallback(ctx: *anyopaque) !void {
                const self: *FetchContext = @ptrCast(@alignCast(ctx));
                defer self.promise_resolver.deinit();
                self.transfer = null;

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
                const self: *FetchContext = @ptrCast(@alignCast(ctx));
                self.transfer = null;

                log.err(.http, "error", .{
                    .url = self.url,
                    .err = err,
                    .source = "fetch error",
                });
            }
        }.errorCallback,
    });

    return resolver.promise();
}
