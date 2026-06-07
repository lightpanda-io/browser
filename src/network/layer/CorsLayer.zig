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
const Cors = @import("../Cors.zig");
const CorsMode = Cors.CorsMode;
const DeferringContext = @import("DeferringLayer.zig").DeferredContext;
const Forward = @import("Forward.zig");

const CorsLayer = @This();

next: Layer = undefined,

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

    const sfs_header: [:0]const u8, const origin_header: [:0]const u8 = switch (mode) {
        .none => .{ "Sec-Fetch-Site: none", "" },
        .same_origin => .{
            "Sec-Fetch-Site: same-origin",
            try std.mem.concatWithSentinel(arena, u8, &.{ "Origin: ", from_origin }, 0),
        },
        .cross_site => .{
            "Sec-Fetch-Site: cross-site",
            try std.mem.concatWithSentinel(arena, u8, &.{ "Origin: ", from_origin }, 0),
        },
    };

    try req.headers.add(sfs_header.ptr);
    if (origin_header.len != 0) try req.headers.add(origin_header.ptr);
    log.debug(.http, "CORS checked", .{
        .from_url = from_url,
        .to_url = req.url,
        .sfs_header = sfs_header,
    });

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
        .req_url = req.url, // don't think this gets re-allocated ever?
        .from_origin = from_origin,
        .original_method = @tagName(req.method),
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
    // new request will be responsible for this one
    // put thyself to sleep
    transfer.park(.cors);
    corstext.held = transfer;

    var new_req: Request = req.*;
    // mayhaps it shouldn't skip?
    new_req.skip_robots = true;
    new_req.headers = try transfer.client.newHeaders();
    new_req.method = .OPTIONS;
    new_req.resource_type = .preflight;
    new_req.start_callback = null;
    new_req.shutdown_callback = null;
    {
        // once request is sent, client owns the headers,
        // so scope it.
        errdefer new_req.headers.deinit();

        // preflight headers
        const acr_method: [:0]const u8 = switch (req.method) {
            inline else => |m| "Access-Control-Request-Method: " ++ @tagName(m),
        };

        const acr_headers: [:0]const u8 = blk: {
            const headers_csv = try std.mem.join(arena, ",", corstext.extra_headers.items);
            break :blk try std.mem.joinZ(arena, "", &.{ "Access-Control-Request-Headers: ", headers_csv });
        };

        try new_req.headers.add(origin_header.ptr);
        try new_req.headers.add(acr_method.ptr);
        try new_req.headers.add(acr_headers.ptr);

        log.info(.browser, "CORS Preflight sent", .{
            .origin_header = origin_header,
            .acr_method = acr_method,
            .acr_headers = acr_headers,
        });
    }
    return transfer.client.request(new_req, transfer.owner);
}

pub const CorsContext = struct {
    forward: Forward,
    arena: std.mem.Allocator,
    req_url: [:0]const u8,
    from_origin: []const u8,
    original_method: [:0]const u8,
    credentials: bool = false,
    extra_headers: std.ArrayList([]const u8) = .empty,
    layer: *CorsLayer,
    held: ?*Transfer = null,

    fn headerCallback(response: Response) anyerror!bool {
        const corstext: *CorsContext = @ptrCast(@alignCast(response.ctx));

        if (try Cors.responsePassesCors(corstext, response)) {
            return corstext.forward.forwardHeader(response);
        } else {
            return error.CorsDeinied;
        }
    }

    fn doneCallback(ctx: *anyopaque) anyerror!void {
        var corstext: *CorsContext = @ptrCast(@alignCast(ctx));
        if (corstext.held) |held| {
            corstext.held = null;
            if (held.state == .parked) {
                held.unpark();
            }
            corstext.layer.next.request(held) catch |e| {
                held.abort(e);
            };
        }
        return corstext.forward.forwardDone();
    }

    fn errorCallback(ctx: *anyopaque, err: anyerror) void {
        const corstext: *CorsContext = @ptrCast(@alignCast(ctx));
        if (corstext.held) |held| {
            corstext.held = null;
            held.abort(err);
        }
        return corstext.forward.forwardErr(err);
    }

    fn shutdownCallback(ctx: *anyopaque) void {
        const cors_ctx: *CorsContext = @ptrCast(@alignCast(ctx));
        return cors_ctx.forward.forwardShutdown();
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
