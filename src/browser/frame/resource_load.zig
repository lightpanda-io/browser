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
const HttpClient = @import("../../network/HttpClient.zig");

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
        return frame.queueLoad(Factory.protoOf(img));
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
        .frame_id = frame._frame_id,
        .loader_id = frame._loader_id,
        .cookie_jar = &session.cookie_jar,
        .cookie_origin = frame.url,
        .resource_type = .image,
        .notification = session.notification,
        .headers_only = true,
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
        try frame.headersForRequest(transfer);
    }

    // From here the transfer owns `load`. `submit` either succeeds or has
    // already routed the failure through error_callback, which settles the
    // ImageLoad and gives the pending-load slot back.
    transfer.submit() catch |err| {
        log.warn(.http, "image fetch", .{ .err = err, .url = resolved });
    };
}

// One in-flight image fetch. Exactly one of done/error/shutdown runs, and each
// releases the `_pending_loads` slot taken above.
const ImageLoad = struct {
    frame: *Frame,
    image: *Element.Html.Image,
    generation: u32,
    status: u16 = 0,

    fn headerCallback(transfer: *HttpClient.Transfer) !HttpClient.Transfer.HeaderResult {
        const self: *ImageLoad = @ptrCast(@alignCast(transfer.req.ctx));
        self.status = transfer.responseStatus() orelse 0;
        return .proceed;
    }

    fn dataCallback(_: *HttpClient.Transfer, _: []const u8) !void {
        // headers_only tears the transfer down at the first body byte.
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
            frame.queueElementEvent(Factory.protoOf(img), kind) catch |err| {
                log.warn(.frame, "image queue event", .{ .err = err, .kind = kind });
            };
        }

        frame.pendingLoadCompleted();
    }
};
