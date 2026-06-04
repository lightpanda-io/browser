const std = @import("std");
const Allocator = std.mem.Allocator;

const lp = @import("lightpanda");
const log = lp.log;

const HttpClient = @import("../../browser/HttpClient.zig");
const Layer = @import("../../browser/HttpClient.zig").Layer;
const Transfer = @import("../../browser/HttpClient.zig").Transfer;
const Response = @import("../../browser/HttpClient.zig").Response;
const URL = @import("../../browser/URL.zig");
const Fetch = @import("../../browser/webapi/net/Fetch.zig");
const Network = @import("../Network.zig");
const DeferringContext = @import("DeferringLayer.zig").DeferredContext;
const Forward = @import("Forward.zig");

const CorsLayer = @This();

next: Layer = undefined,
network: *Network,

const CorsMode = enum {
    same_origin,
    cross_site,
    none,
};

pub fn layer(self: *CorsLayer) Layer {
    return .{
        .ptr = self,
        .vtable = &.{
            .request = request,
        },
    };
}

fn request(ptr: *anyopaque, transfer: *Transfer) anyerror!void {
    const cors_layer: *CorsLayer = @ptrCast(@alignCast(ptr));
    const req = &transfer.req;

    const arena = transfer.arena;

    const mode: CorsMode, const from: ?[]const u8, const to: ?[]const u8 =
        switch (req.resource_type) {
            .fetch => blk: {
                const def_ctx: *DeferringContext = @ptrCast(@alignCast(req.ctx));
                const fetch_ctx: *Fetch = @ptrCast(@alignCast(def_ctx.forward.ctx));

                const requesting_origin = URL.getOrigin(
                    arena,
                    fetch_ctx._exec.url.*,
                ) catch null;

                const to_origin = URL.getOrigin(
                    arena,
                    req.url,
                ) catch null;

                if (requesting_origin) |from| {
                    try req.headers.add(
                        (try std.fmt.allocPrint(
                            arena,
                            "Origin: {s}",
                            .{from},
                        )).ptr,
                    );

                    if (to_origin) |to| {
                        break :blk .{
                            if (std.mem.eql(u8, from, to)) .same_origin else .cross_site,
                            from,
                            to,
                        };
                    }
                }

                break :blk .{
                    .none,
                    null,
                    null,
                };
            },
            // TODO: xhr
            else => .{
                .none,
                null,
                null,
            },
        };

    const sts = switch (mode) {
        .none => "Sec-Fetch-Site: none",
        .same_origin => "Sec-Fetch-Site: same-origin",
        .cross_site => "Sec-Fetch-Site: cross-site",
    };

    try req.headers.add(sts);
    log.debug(.http, "CORS checked", .{ .from = from, .to = to, .sts = sts });

    if (mode != .cross_site) {
        return cors_layer.next.request(transfer);
    }

    // cross-site request;
    // yay.

    const corstext = try arena.create(CorsContext);
    corstext.* = .{
        .arena = arena,
        .url = try arena.dupeZ(u8, transfer.req.url),
        .forward = Forward.capture(&transfer.req),
        .from_origin = from.?,
        .method = @tagName(req.method),
        .credentials = req.cookie_jar != null,
        .layer = cors_layer,
    };

    transfer.req.ctx = corstext;
    transfer.req.start_callback = if (corstext.forward.start != null) CorsContext.startCallback else null;
    transfer.req.header_callback = CorsContext.headerCallback;
    transfer.req.data_callback = CorsContext.dataCallback;
    transfer.req.done_callback = CorsContext.doneCallback;
    transfer.req.error_callback = CorsContext.errorCallback;
    transfer.req.shutdown_callback = if (corstext.forward.shutdown != null) CorsContext.shutdownCallback else null;

    // check if it's a 'simple request'.
    // if not, then will need to do a preflight
    // and assess the CORS situation.
    // https://developer.mozilla.org/en-US/docs/Web/HTTP/Guides/CORS#simple_requests
    const is_simple_request = blk: {
        switch (req.method) {
            .GET, .HEAD, .POST => {},
            else => break :blk false,
        }

        var header_iter = req.headers.iterator();
        outer: while (header_iter.next()) |h| {
            const upper = try std.ascii.allocUpperString(arena, h.name);
            if (std.mem.startsWith(u8, upper, "SEC-") or
                std.mem.startsWith(u8, upper, "PROXY-"))
            {
                continue;
            }

            for (allowed_headers) |a_h| {
                if (std.mem.eql(u8, upper, a_h)) {
                    continue :outer;
                }
            }

            try corstext.extra_headers.append(arena, upper);
        }

        break :blk corstext.extra_headers.items.len == 0;
    };

    if (is_simple_request) {
        return cors_layer.next.request(transfer);
    }

    // preflight required:
    // create a new request and
    // await response.

    // take responsibility for the held
    // request.
    transfer.park(.cors);
    corstext.held = transfer;

    // from RobotsLayer.zig:
    // CRITICAL: build a fresh Headers for the inner robots fetch.
    // We value-copy req from the parent, but Headers is a struct wrapping
    // a *curl_slist — value copy shares the pointer. Letting Client.request
    // take ownership of a shared headers list means both transfers will
    // free it at deinit time -> double-free. The robots.txt fetch is a
    // system-level GET anyway, no need to inherit the parent's user headers.
    var new_req = transfer.req;
    new_req.headers = try transfer.client.newHeaders();
    errdefer new_req.headers.deinit();
    new_req.method = .GET;
    new_req.url = corstext.url;
    new_req.skip_robots = true;
    new_req.resource_type = .preflight;
    new_req.body = null;
    new_req.ctx = corstext;
    new_req.start_callback = null;
    new_req.header_callback = CorsContext.headerCallback;
    new_req.data_callback = CorsContext.dataCallback;
    new_req.done_callback = CorsContext.doneCallback;
    new_req.error_callback = CorsContext.errorCallback;
    new_req.shutdown_callback = CorsContext.shutdownCallback;

    // !!!!!!!!!!

    // FIX: add preflight headers

    // !!!!!!!!!!

    log.info(.browser, "CORS Preflight sent", .{});
    return transfer.client.request(new_req, transfer.owner);
}

pub fn deinit(self: *CorsLayer) void {
    _ = self;
}

const CorsContext = struct {
    arena: std.mem.Allocator,
    url: [:0]const u8,
    from_origin: []const u8,
    forward: Forward,
    layer: *CorsLayer,
    credentials: bool = false,
    extra_headers: std.ArrayList([]const u8) = .empty,
    method: [:0]const u8,
    held: ?*Transfer = null,

    fn headerCallback(response: Response) anyerror!bool {
        const corstext: *CorsContext = @ptrCast(@alignCast(response.ctx));
        const arena = corstext.arena;

        const HeaderStore = struct {
            credentials: bool = false,
            res_origin: ?[]const u8 = null,
            res_methods: std.ArrayList([]const u8) = .empty,
            res_headers: std.ArrayList([]const u8) = .empty,
        };
        var store: HeaderStore = .{};

        var header_it = response.headerIterator();
        const headers = try header_it.collect(arena);

        for (headers.items) |h| {
            const upper = try std.ascii.allocUpperString(arena, h.name);

            if (std.mem.eql(u8, upper, "ACCESS-CONTROL-ALLOW-ORIGIN")) {
                store.res_origin = h.value;
            } else if (std.mem.eql(u8, upper, "ACCESS-CONTROL-ALLOW-CREDENTIALS")) {
                const upper_bool = try std.ascii.allocUpperString(arena, h.value);
                store.credentials = std.mem.eql(u8, upper_bool, "TRUE");
            } else if (std.mem.eql(u8, upper, "ACCESS-CONTROL-ALLOW-METHODS")) {
                var iter = std.mem.tokenizeAny(u8, h.value, ", ");
                while (iter.next()) |val| {
                    try store.res_methods.append(arena, val);
                }
            } else if (std.mem.eql(u8, upper, "ACCESS-CONTROL-ALLOW-HEADERS")) {
                var iter = std.mem.tokenizeAny(u8, h.value, ", ");
                while (iter.next()) |val| {
                    try store.res_headers.append(arena, val);
                }
            }
        }

        // possibly the ugliest code ever written
        const allowed = blk: {
            // origin is mandatory,
            // check it first for early exit.
            if (store.res_origin == null) {
                break :blk false;
            }

            const origin_wildcard: bool = std.mem.eql(u8, store.res_origin.?, "*");
            const origin_found = std.mem.eql(u8, store.res_origin.?, corstext.from_origin);

            if (!origin_wildcard and !origin_found) {
                break :blk false;
            }

            var method_wildcard = false;
            var method_found = false;

            var headers_wildcard = false;
            var headers_found = false;

            if (corstext.held) |_| {
                // this is a preflight request;
                // mandatory: methods & headers.
                // NOTE: optional: max-age, credentials
                method_wildcard = for (store.res_methods.items) |h| {
                    if (std.mem.containsAtLeastScalar(u8, h, 1, '*')) {
                        break true;
                    }
                } else false;

                headers_wildcard = for (store.res_headers.items) |h| {
                    if (std.mem.containsAtLeastScalar(u8, h, 1, '*')) {
                        break true;
                    }
                } else false;

                method_found = for (store.res_methods.items) |h| {
                    if (std.mem.containsAtLeast(u8, h, 1, corstext.method)) {
                        break true;
                    }
                } else false;

                headers_found = found: {
                    for (corstext.extra_headers.items) |req_header| {
                        for (store.res_headers.items) |h| {
                            if (std.mem.eql(u8, req_header, h)) {
                                break;
                            }
                        } else break :found false;
                    } else break :found true;
                };

                if (corstext.credentials) {
                    if (!store.credentials) {
                        break :blk false;
                    }
                    if (origin_wildcard or method_wildcard or headers_wildcard) {
                        break :blk false;
                    }
                    if (!(origin_found and method_found and headers_found)) {
                        break :blk false;
                    }
                } else {
                    if (!(origin_wildcard or origin_found) or
                        !(method_wildcard or method_found) or
                        !(headers_wildcard or headers_found))
                    {
                        break :blk false;
                    }
                }
            } else {
                // non-preflight;
                // just check credentials
                if (corstext.credentials) {
                    if (!store.credentials or origin_wildcard) {
                        break :blk false;
                    }
                }
            }

            break :blk true;
        };

        if (allowed) {
            return corstext.forward.forwardHeader(response);
        } else {
            return error.CorsDeinied;
        }
    }

    fn doneCallback(ctx: *anyopaque) anyerror!void {
        var corstext: *CorsContext = @ptrCast(@alignCast(ctx));
        if (corstext.held) |held| {
            if (held.state == .parked) {
                held.unpark();
            }
            corstext.layer.next.request(held) catch |e| {
                held.abort(e);
            };
            corstext.held = null;
        }
        return corstext.forward.forwardDone();
    }

    fn shutdownCallback(ctx: *anyopaque) void {
        const cors_ctx: *CorsContext = @ptrCast(@alignCast(ctx));
        return cors_ctx.forward.forwardShutdown();
    }

    fn errorCallback(ctx: *anyopaque, err: anyerror) void {
        const corstext: *CorsContext = @ptrCast(@alignCast(ctx));
        if (corstext.held) |held| {
            held.abort(err);
            corstext.held = null;
        }
        return corstext.forward.forwardErr(err);
    }

    fn startCallback(response: Response) anyerror!void {
        const cors_ctx: *CorsContext = @ptrCast(@alignCast(response.ctx));
        return cors_ctx.forward.forwardStart(response);
    }

    fn dataCallback(response: Response, chunk: []const u8) anyerror!void {
        const cors_ctx: *CorsContext = @ptrCast(@alignCast(response.ctx));
        return cors_ctx.forward.forwardData(response, chunk);
    }
};

const allowed_headers = [_][]const u8{
    "ACCEPT-CHARSET",
    "ACCESS-CONTROL-REQUEST-HEADERS",
    "ACCESS-CONTROL-REQUEST-METHOD",
    "ACCEPT-ENCODING",
    "CONNECTION",
    "CONTENT-LENGTH",
    "COOKIE",
    "DATE",
    "DNT",
    "EXPECT",
    "HOST",
    "KEEP-ALIVE",
    "ORIGIN",
    "REFERER",
    "SET-COOKIE",
    "TE",
    "TRAILER",
    "TRANSFER-ENCODING",
    "UPGRADE",
    "USER-AGENT",
    "VIA",
    // TODO: separate for further checks:
    // - https://developer.mozilla.org/en-US/docs/Glossary/CORS-safelisted_request_header#additional_restrictions
    // - https://developer.mozilla.org/en-US/docs/Glossary/Forbidden_request_header
    "ACCEPT",
    "ACCEPT-LANGUAGE",
    "CONTENT-LANGUAGE",
    "CONTENT-TYPE",
    "RANGE",
    "X-HTTP-METHOD",
    "X-HTTP-METHOD-OVERRIDE",
    "X-METHOD-OVERRIDE",
};
