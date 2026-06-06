const std = @import("std");
const Allocator = std.mem.Allocator;

const lp = @import("lightpanda");
const log = lp.log;

const HttpClient = @import("../../browser/HttpClient.zig");
const Layer = HttpClient.Layer;
const Transfer = HttpClient.Transfer;
const Request = HttpClient.Request;
const Response = HttpClient.Response;
const URL = @import("../../browser/URL.zig");
const Fetch = @import("../../browser/webapi/net/Fetch.zig");
const Network = @import("../Network.zig");
const DeferringContext = @import("DeferringLayer.zig").DeferredContext;
const Forward = @import("Forward.zig");

const CorsLayer = @This();
const Cors = @import("../Cors.zig");
const CorsMode = Cors.CorsMode;

next: Layer = undefined,
network: *Network,

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
    const def_ctx: *DeferringContext = @ptrCast(@alignCast(req.ctx));
    const fetch_ctx: *Fetch = @ptrCast(@alignCast(def_ctx.forward.ctx));

    const arena = transfer.arena;

    var from_url: [:0]const u8 = "";
    var from_origin: []const u8 = "";
    var to_origin: []const u8 = "";

    const mode: CorsMode = switch (req.resource_type) {
        .fetch => blk: {
            from_url = fetch_ctx._exec.url.*;
            from_origin = try URL.getOrigin(
                arena,
                from_url,
            ) orelse break :blk .none;

            to_origin = try URL.getOrigin(
                arena,
                req.url,
            ) orelse break :blk .none; // not http or https

            break :blk if (std.mem.eql(u8, from_origin, to_origin)) .same_origin else .cross_site;
        },
        // TODO: xhr
        else => .none,
    };

    const sfs_header, const origin_header = switch (mode) {
        .none => .{ "Sec-Fetch-Site: none", "" },
        .same_origin => .{ "Sec-Fetch-Site: same-origin", try std.mem.concatWithSentinel(arena, u8, &.{ "Origin: ", from_origin }, 0) },
        .cross_site => .{ "Sec-Fetch-Site: cross-site", try std.mem.concatWithSentinel(arena, u8, &.{ "Origin: ", from_origin }, 0) },
    };

    try req.headers.add(sfs_header.ptr);
    if (origin_header.len != 0) try req.headers.add(origin_header.ptr);
    log.debug(.http, "CORS checked", .{ .from_url = from_url, .to_url = req.url, .sfs_header = sfs_header });

    // for none or same-site, we don't care
    // it's calld cors not s/nors
    // yeah cause i'm snoring at this request
    if (mode != .cross_site) {
        return cors_layer.next.request(transfer);
    }

    // cross-site request;
    // yay.
    const corstext = try arena.create(CorsContext);
    corstext.* = .{
        .forward = Forward.capture(&transfer.req),
        .arena = arena,
        .url = transfer.req.url, // don't think this gets re-allocated ever?
        .from_origin = from_origin,
        .method = @tagName(req.method),
        .credentials = req.cookie_jar != null,
        .layer = cors_layer,
    };

    // set callbacks so we can check if we pass on the return trip
    transfer.req.ctx = corstext;
    transfer.req.start_callback = if (corstext.forward.start != null) CorsContext.startCallback else null;
    transfer.req.header_callback = CorsContext.headerCallback;
    transfer.req.data_callback = CorsContext.dataCallback;
    transfer.req.done_callback = CorsContext.doneCallback;
    transfer.req.error_callback = CorsContext.errorCallback;
    transfer.req.shutdown_callback = if (corstext.forward.shutdown != null) CorsContext.shutdownCallback else null;

    if (try Cors.determineSimpleRequest(corstext, req)) {
        return cors_layer.next.request(transfer);
    }

    // preflight required:
    // create a new request and
    // await response.

    // new request will be responsible for this one
    // put thyself to sleep
    transfer.park(.cors);
    corstext.held = transfer;

    // TODO: don't copy make a new one?
    // don't need all the extra stuff
    var new_req = transfer.req;
    new_req.headers = try transfer.client.newHeaders();
    errdefer new_req.headers.deinit();
    new_req.method = .OPTIONS;
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

pub const CorsContext = struct {
    forward: Forward,
    arena: std.mem.Allocator,
    url: [:0]const u8,
    from_origin: []const u8,
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
            if (std.ascii.eqlIgnoreCase(h.name, "ACCESS-CONTROL-ALLOW-ORIGIN")) {
                store.res_origin = h.value;
            } else if (std.ascii.eqlIgnoreCase(h.name, "ACCESS-CONTROL-ALLOW-CREDENTIALS")) {
                store.credentials = std.ascii.eqlIgnoreCase(h.value, "true");
            } else if (std.ascii.eqlIgnoreCase(h.name, "ACCESS-CONTROL-ALLOW-METHODS")) {
                var iter = std.mem.tokenizeAny(u8, h.value, ", ");
                while (iter.next()) |val| {
                    try store.res_methods.append(arena, val);
                }
            } else if (std.ascii.eqlIgnoreCase(h.name, "ACCESS-CONTROL-ALLOW-HEADERS")) {
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
            const origin_match = std.mem.eql(u8, store.res_origin.?, corstext.from_origin);

            if (!origin_wildcard and !origin_match) {
                break :blk false;
            }

            var method_wildcard = false;
            var method_match = false;

            var headers_wildcard = false;
            var headers_match = false;

            if (corstext.held) |_| {
                // this is a preflight request;
                // mandatory: methods & headers, ~credentials.
                // optional: max-age
                method_wildcard = for (store.res_methods.items) |h| {
                    if (std.mem.eql(u8, h, "*")) {
                        break true;
                    }
                } else false;

                method_match = for (store.res_methods.items) |h| {
                    if (std.mem.eql(u8, h, corstext.method)) {
                        break true;
                    }
                } else false;

                if (corstext.extra_headers.items.len == 0) {
                    headers_match = true;
                } else {
                    headers_wildcard = for (store.res_headers.items) |h| {
                        if (std.mem.eql(u8, h, "*")) {
                            break true;
                        }
                    } else false;

                    headers_match = found: {
                        for (corstext.extra_headers.items) |req_header| {
                            for (store.res_headers.items) |h| {
                                if (std.mem.eql(u8, req_header, h)) {
                                    break;
                                }
                            } else break :found false;
                        } else break :found true;
                    };
                }

                if (corstext.credentials) {
                    if (!store.credentials) {
                        break :blk false;
                    }
                    if (origin_wildcard or method_wildcard or headers_wildcard) {
                        break :blk false;
                    }
                    if (!(origin_match and method_match and headers_match)) {
                        break :blk false;
                    }
                } else {
                    if (!(origin_wildcard or origin_match) or
                        !(method_wildcard or method_match) or
                        !(headers_wildcard or headers_match))
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
