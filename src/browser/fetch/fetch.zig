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

const js = @import("../js/js.zig");
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
    @import("Headers.zig").HeadersEntryIterable,
    @import("Headers.zig").HeadersKeyIterable,
    @import("Headers.zig").HeadersValueIterable,
    @import("Request.zig"),
    @import("Response.zig"),
};

pub const FetchContext = struct {
    page: *Page,
    arena: std.mem.Allocator,
    promise_resolver: js.PersistentPromiseResolver,

    method: Http.Method,
    url: []const u8,
    body: std.ArrayListUnmanaged(u8) = .empty,
    headers: std.ArrayListUnmanaged([]const u8) = .empty,
    status: u16 = 0,
    mime: ?Mime = null,
    mode: Request.RequestMode,
    transfer: ?*HttpClient.Transfer = null,

    /// This effectively takes ownership of the FetchContext.
    ///
    /// We just return the underlying slices used for `headers`
    /// and for `body` here to avoid an allocation.
    pub fn toResponse(self: *const FetchContext) !Response {
        var headers: Headers = .{};

        // seems to be the highest priority
        const same_origin = try self.page.isSameOrigin(self.url);

        // If the mode is "no-cors", we need to return this opaque/stripped Response.
        // https://developer.mozilla.org/en-US/docs/Web/API/Response/type
        if (!same_origin and self.mode == .@"no-cors") {
            return Response{
                .status = 0,
                .headers = headers,
                .mime = self.mime,
                .body = null,
                .url = self.url,
                .type = .@"opaque",
            };
        }

        // convert into Headers
        for (self.headers.items) |hdr| {
            var iter = std.mem.splitScalar(u8, hdr, ':');
            const name = iter.next() orelse "";
            const value = iter.next() orelse "";
            try headers.append(name, value, self.arena);
        }

        const resp_type: Response.ResponseType = blk: {
            if (same_origin or std.mem.startsWith(u8, self.url, "data:")) {
                break :blk .basic;
            }

            break :blk switch (self.mode) {
                .cors => .cors,
                .@"same-origin", .navigate => .basic,
                .@"no-cors" => unreachable,
            };
        };

        return Response{
            .status = self.status,
            .headers = headers,
            .mime = self.mime,
            .body = self.body.items,
            .url = self.url,
            .type = resp_type,
        };
    }
};

// https://developer.mozilla.org/en-US/docs/Web/API/Window/fetch
pub fn fetch(input: RequestInput, options: ?RequestInit, page: *Page) !js.Promise {
    const arena = page.arena;

    const req = try Request.constructor(input, options, page);
    var headers = try page.http_client.newHeaders();

    // Copy our headers into the HTTP headers.
    var header_iter = req.headers.headers.iterator();
    while (header_iter.next()) |entry| {
        const combined = try std.fmt.allocPrintSentinel(
            page.arena,
            "{s}: {s}",
            .{ entry.key_ptr.*, entry.value_ptr.* },
            0,
        );
        try headers.add(combined.ptr);
    }

    try page.requestCookie(.{}).headersForRequest(arena, req.url, &headers);

    const resolver = try page.js.createPromiseResolver(.page);

    const fetch_ctx = try arena.create(FetchContext);
    fetch_ctx.* = .{
        .page = page,
        .arena = arena,
        .promise_resolver = resolver,
        .method = req.method,
        .url = req.url,
        .mode = req.mode,
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
                const self: *FetchContext = @ptrCast(@alignCast(transfer.ctx));
                log.debug(.fetch, "request start", .{ .method = self.method, .url = self.url, .source = "fetch" });

                self.transfer = transfer;
            }
        }.startCallback,
        .header_callback = struct {
            fn headerCallback(transfer: *HttpClient.Transfer) !void {
                const self: *FetchContext = @ptrCast(@alignCast(transfer.ctx));

                const header = &transfer.response_header.?;

                log.debug(.fetch, "request header", .{
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

                if (transfer.getContentLength()) |cl| {
                    try self.body.ensureTotalCapacity(self.arena, cl);
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
                self.transfer = null;

                log.info(.fetch, "request complete", .{
                    .source = "fetch",
                    .method = self.method,
                    .url = self.url,
                    .status = self.status,
                });

                const response = try self.toResponse();
                try self.promise_resolver.resolve(response);
            }
        }.doneCallback,
        .error_callback = struct {
            fn errorCallback(ctx: *anyopaque, err: anyerror) void {
                const self: *FetchContext = @ptrCast(@alignCast(ctx));
                self.transfer = null;

                log.err(.fetch, "error", .{
                    .url = self.url,
                    .err = err,
                    .source = "fetch error",
                });

                // We throw an Abort error when the page is getting closed so,
                // in this case, we don't need to reject the promise.
                if (err != error.Abort) {
                    self.promise_resolver.reject(@errorName(err)) catch unreachable;
                }
            }
        }.errorCallback,
    });

    return resolver.promise();
}

const testing = @import("../../testing.zig");
test "fetch: fetch" {
    try testing.htmlRunner("fetch/fetch.html");
}
