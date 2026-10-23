// Copyright (C) 2023 - 2026 Lightpanda (Selecy SAS)
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

// Sub-resources fetched only for their outcome, gated on `--load-resources`:
// nothing in the document consumes the body, we fetch so that the element's
// load/error event reflects the real HTTP status.

const lp = @import("lightpanda");

const URL = @import("../URL.zig");
const Frame = @import("../Frame.zig");
const Factory = @import("../Factory.zig");
const Element = @import("../webapi/Element.zig");
const image_dimensions = @import("../image_dimensions.zig");
const HttpClient = @import("../../network/HttpClient.zig");
const CorsGate = @import("../../network/CorsGate.zig");

const log = lp.log;

// Asynchronous, unlike `Frame.loadExternalStylesheet`: nothing in the document
// depends on the result, so there's no reason to block the parser on it. The
// request does take a `_pending_loads` slot, so the window load event waits
// for it the way the HTML spec says it should.
pub fn image(frame: *Frame, img: *Element.Html.Image, src: []const u8) !void {
    const session = frame._session;

    // Fragment-parsed images (innerHTML, DOMParser, ...) may never be attached,
    // and may belong to another Document. Same call `loadExternalStylesheet`
    // makes. They still get the synthetic load the no-fetch path would have
    // given them, so the two modes agree.
    if (frame._parse_mode == .fragment) {
        return frame.queueImageEvent(img, .load);
    }

    const arena = try session.getArena(.small, "resource_load.image");
    defer arena.release();

    const load = try frame._factory.create(ImageLoad{
        .frame = frame,
        .image = img,
        .generation = img._generation,
    });
    errdefer frame._factory.destroy(load);

    img._complete = false;
    frame._pending_loads += 1;
    errdefer {
        frame._pending_loads -= 1;
        img._complete = true;
    }

    const resolved = URL.resolve(arena.allocator(), frame.base(), src, .{ .encoding = frame.charset }) catch |err| {
        // An unresolvable src fails the same way a 404 does, but without a
        // request to carry the outcome. Settle on a task rather than inline:
        // we're on a DOM mutation path and must not dispatch events from
        // inside it.
        log.info(.http, "image resolve", .{ .err = err, .src = src });
        try frame.js.scheduler.add(load, ImageLoad.failed, 0, .{
            .name = "resource_load.image.failed",
            .finalizer = ImageLoad.finalizer,
        });
        return;
    };

    const transfer = try session.browser.http_client.newRequest(.{
        .ctx = load,
        .url = resolved,
        .method = .GET,
        .origin = frame.origin,
        .request_mode = .no_cors,
        .credentials_mode = .include,
        .resource_type = .image,
        .partial = 16 * 1024,
        .header_callback = ImageLoad.headerCallback,
        .data_callback = ImageLoad.dataCallback,
        .done_callback = ImageLoad.doneCallback,
        .error_callback = ImageLoad.errorCallback,
        .shutdown_callback = ImageLoad.shutdownCallback,
    }, &frame._http_owner);
    {
        // `deinit` fires no callbacks, so the errdefers above are still the
        // ones responsible for undoing our state on this path.
        errdefer transfer.deinit();
        // Part of mimicking the real request: origins that content-negotiate
        // (or that turn away clients which don't look like browsers) key off
        // exactly this header.
        try transfer.setHeader("Accept", "image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8", .{});
        try frame.headersForRequest(transfer, .{});
    }

    // From here the transfer owns `load`. `submit` either succeeds or has
    // already routed the failure through error_callback, which settles the
    // ImageLoad and gives the pending-load slot back.
    transfer.submit() catch |err| {
        log.debug(.http, "image fetch", .{ .err = err, .url = resolved });
    };
}

// A navigator.sendBeacon request: a POST whose response nobody reads. Its body
// counts against the sending document's keepalive quota, `in_flight`, until it
// settles.
// https://w3c.github.io/beacon/#sec-processing-model
//
// A keepalive request outlives the document that made it: a beacon sent by an
// iframe that's then removed still goes out. So the request is owned by the
// page's main frame, not `frame`, which supplies its origin, referrer and site
// for cookies, and `in_flight` must outlive `frame` too (it's in the page
// arena). The owner still attributes it to the main frame in CDP events.
pub fn beacon(frame: *Frame, in_flight: *usize, url: [:0]const u8, body: []const u8, content_type: ?[]const u8) !void {
    const root = &frame.page.frame;

    // A body with a Content-Type that isn't CORS-safelisted makes it a CORS
    // request; anything else (no body, a Blob without a type, ...) is no-cors.
    const cors = if (content_type) |ct| !CorsGate.isSafelistedHeader("content-type", ct) else false;

    const load = try root._factory.create(BeaconLoad{
        .root = root,
        .size = body.len,
        .in_flight = in_flight,
    });
    errdefer root._factory.destroy(load);

    const transfer = try frame._session.browser.http_client.newRequest(.{
        .ctx = load,
        .url = url,
        .method = .POST,
        .body = body,
        .origin = frame.origin,
        .cookie_origin = frame._http_owner.siteForCookies(),
        .request_mode = if (cors) .cors else .no_cors,
        .credentials_mode = .include,
        .resource_type = .beacon,
        .done_callback = BeaconLoad.doneCallback,
        .error_callback = BeaconLoad.errorCallback,
        .shutdown_callback = BeaconLoad.shutdownCallback,
    }, &root._http_owner);
    {
        errdefer transfer.deinit();
        if (content_type) |ct| {
            try transfer.setHeader("Content-Type", ct, .{ .source = .author });
        }
        try frame.headersForRequest(transfer, .{});
    }

    in_flight.* += body.len;
    // From here the transfer owns `load`, which gives the quota back.
    transfer.submit() catch |err| {
        log.debug(.http, "beacon", .{ .err = err, .url = url });
    };
}

// One in-flight beacon. Exactly one of done/error/shutdown runs.
const BeaconLoad = struct {
    root: *Frame,
    size: usize,
    in_flight: *usize,

    fn doneCallback(ctx: *anyopaque) !void {
        settle(ctx);
    }

    fn errorCallback(ctx: *anyopaque, err: anyerror) void {
        log.info(.http, "beacon", .{ .err = err });
        settle(ctx);
    }

    fn shutdownCallback(ctx: *anyopaque) void {
        settle(ctx);
    }

    fn settle(ctx: *anyopaque) void {
        const self: *BeaconLoad = @ptrCast(@alignCast(ctx));
        self.in_flight.* -|= self.size;
        self.root._factory.destroy(self);
    }
};

// One in-flight image fetch. Exactly one of done/error/shutdown runs, and each
// releases the `_pending_loads` slot taken above.
const ImageLoad = struct {
    frame: *Frame,
    image: *Element.Html.Image,
    generation: u32,
    status: u16 = 0,
    dimensions: ?image_dimensions.Dimensions = null,

    fn headerCallback(transfer: *HttpClient.Transfer) !HttpClient.Transfer.HeaderResult {
        const self: *ImageLoad = @ptrCast(@alignCast(transfer.req.ctx));
        self.status = transfer.responseStatus() orelse 0;
        return .proceed;
    }

    fn dataCallback(transfer: *HttpClient.Transfer, prefix: []const u8) !void {
        const self: *ImageLoad = @ptrCast(@alignCast(transfer.req.ctx));
        self.dimensions = image_dimensions.parse(prefix);
    }

    fn doneCallback(ctx: *anyopaque) !void {
        const self: *ImageLoad = @ptrCast(@alignCast(ctx));
        const ok = self.status >= 200 and self.status < 300;
        self.settle(if (ok) .load else .@"error");
    }

    fn errorCallback(ctx: *anyopaque, err: anyerror) void {
        const self: *ImageLoad = @ptrCast(@alignCast(ctx));
        log.info(.http, "image fetch", .{ .err = err, .status = self.status });
        self.settle(.@"error");
    }

    fn shutdownCallback(ctx: *anyopaque) void {
        const self: *ImageLoad = @ptrCast(@alignCast(ctx));
        const frame = self.frame;
        self.image._complete = true;
        frame._factory.destroy(self);

        // Teardown or a superseding navigation. Release the slot directly:
        // `pendingLoadCompleted` could reach `documentIsComplete`, and running
        // the load event on a frame that's being dismantled is exactly what
        // we're being told to stop doing.
        frame._pending_loads -|= 1;
    }

    // Scheduler task for a failure we knew about before making a request.
    fn failed(ctx: *anyopaque) !?u32 {
        const self: *ImageLoad = @ptrCast(@alignCast(ctx));
        self.settle(.@"error");
        return null;
    }

    // Runs instead of `failed` when the task is dropped (page teardown).
    fn finalizer(ctx: *anyopaque) void {
        shutdownCallback(ctx);
    }

    fn settle(self: *ImageLoad, kind: Frame.QueuedEvent.Kind) void {
        const frame = self.frame;
        const img = self.image;

        // A later src assignment owns the element's events now; this response
        // is only still here to give its pending-load slot back.
        const current = self.generation == img._generation;
        if (current) {
            img._complete = true;
            if (kind == .load) {
                if (self.dimensions) |dimensions| {
                    img._natural_width = dimensions.width;
                    img._natural_height = dimensions.height;
                }
            }
        }

        // Released before anything below, because everything below can run JS
        // and none of it reads `self` again.
        frame._factory.destroy(self);

        if (frame.isGoingAway()) {
            frame._pending_loads -|= 1;
            return;
        }

        if (current) {
            // Queued, not dispatched: `submit` can fail synchronously, which
            // puts us inside html5ever parsing, and an event handler is free
            // to navigate. Queueing also puts these events ahead of window
            // load, which is where the spec wants them.
            frame.queueImageEvent(img, kind) catch |err| {
                log.warn(.frame, "image queue event", .{ .err = err, .kind = kind });
            };
        }

        frame.pendingLoadCompleted();
    }
};
