// Copyright (C) 2023-2026  Lightpanda (Selecy SAS)
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

// The stylesheets the document's parser links load in parallel, as in Chrome.
// Chrome starts a stylesheet's fetch when the parser creates its <link> and
// parses on: a stylesheet blocks scripts, not parsing. Fetched one at a time
// from the parser, a page's sheets would add up before DOMContentLoaded.
//
// - Start: Link.Build.created marks the parser's call (State.from_parser), and
//   Frame.loadExternalStylesheet hands that link to `start`, which submits the
//   fetch and returns. Only the main document's parse does this, with no
//   script running. A link a script inserts or changes, one document.write's
//   parser creates, and a fragment's load synchronously, as before.
// - Scripts: a parser-blocking script (a classic <script> without async or
//   defer, inline or fetched) runs once every stylesheet the parser met before
//   it has loaded. `waitForParserSheets` ticks the HTTP client for each in
//   turn, letting only that sheet's transfer through (HttpClient.blockOn), as
//   the synchronous fetch does. A fetched script is fetched first, while the
//   sheets load. Deferred scripts, and the parser's module scripts, wait too:
//   `holdDeferredScripts` holds ScriptManager.staticScriptsDone back while a
//   sheet loads and a deferred script is queued, and the last sheet to settle
//   lets them run. With no deferred script, DOMContentLoaded doesn't wait for
//   stylesheets.
// - Load: a loading sheet holds a Frame._pending_loads slot, so the window's
//   load event waits for it.
// - Order: a loaded sheet joins document.styleSheets in tree order, so the
//   cascade follows the document, whichever sheet arrives first.
// - Events: load and error are queued (Frame.queueLinkEvent), in the order the
//   sheets settle.

const std = @import("std");
const lp = @import("lightpanda");

const URL = @import("../URL.zig");
const Frame = @import("../Frame.zig");
const Element = @import("../webapi/Element.zig");
const HttpClient = @import("../../network/HttpClient.zig");

const log = lp.log;

pub const State = struct {
    // Set by Link.Build.created around its linkAddedCallback: the parser
    // created the link.
    from_parser: bool = false,
    // The parser's sheets in flight, in the order the parser met them.
    pending: std.DoublyLinkedList = .{},
    // ScriptManager.staticScriptsDone is held back until `pending` empties.
    deferred_held: bool = false,
};

/// Starts the parser's `link` loading and returns true, or returns false to
/// leave it to the synchronous fetch.
pub fn start(frame: *Frame, link: *Element.Html.Link, href: []const u8) !bool {
    const state = &frame._stylesheets;
    if (state.from_parser == false or frame._parse_mode != .document or frame._parse_state != .html) {
        return false;
    }
    if (frame._script_manager.base.is_evaluating) {
        return false;
    }

    const generation = link._generation;
    const arena = try frame.getArena(.small, "stylesheets.start");
    errdefer arena.release();

    const url = URL.resolve(arena.allocator(), frame.base(), href, .{ .encoding = frame.charset }) catch |err| {
        log.debug(.http, "external stylesheet resolve", .{ .err = err, .href = href });
        try frame.queueLinkEvent(link, .@"error", generation);
        arena.release();
        return true;
    };

    const load = try arena.allocator().create(Load);
    load.* = .{
        .frame = frame,
        .link = link,
        .generation = generation,
        .arena = arena,
        .url = url,
    };

    const transfer = frame._session.browser.http_client.newRequest(.{
        .ctx = load,
        .url = url,
        .method = .GET,
        .origin = frame.origin,
        .request_mode = .no_cors,
        .credentials_mode = .same_origin,
        .resource_type = .stylesheet,
        .done_callback = Load.doneCallback,
        .error_callback = Load.errorCallback,
        .shutdown_callback = Load.shutdownCallback,
    }, &frame._http_owner) catch |err| {
        log.debug(.http, "external stylesheet fetch", .{ .err = err, .url = url });
        try frame.queueLinkEvent(link, .@"error", generation);
        arena.release();
        return true;
    };
    {
        // `deinit` fires no callback: the errdefer above releases `load`.
        errdefer transfer.deinit();
        try transfer.setHeader("Accept", "text/css,*/*;q=0.1", .{});
        try frame.headersForRequest(transfer, .{});
    }

    load.transfer_id = transfer.id;
    load.frame_id = transfer.req.frame_id;
    state.pending.append(&load.node);
    frame._pending_loads += 1;

    // From here the transfer owns `load`: a failure to submit has already gone
    // through errorCallback, which settled it and released `url`.
    transfer.submit() catch |err| {
        log.debug(.http, "external stylesheet submit", .{ .err = err });
    };
    return true;
}

/// Before a parser-blocking script runs, the parser's stylesheets before it
/// load. If ticking the client fails, the script runs without them, as it
/// would once they failed.
pub fn waitForParserSheets(frame: *Frame) void {
    const state = &frame._stylesheets;
    if (state.pending.first == null) {
        return;
    }

    // As for the synchronous fetch: Session.removePage must not free the frame
    // while the ticks below hold it.
    const sm = &frame._script_manager.base;
    const was_evaluating = sm.is_evaluating;
    sm.is_evaluating = true;
    defer sm.endEvaluationWindow(was_evaluating);

    const client = &frame._session.browser.http_client;
    while (firstPending(state)) |load| {
        const transfer_id = load.transfer_id;
        const frame_id = load.frame_id;
        if (client.blocking_requests.contains(frame_id)) {
            // Another wait of this frame is on the stack; ours could never be
            // delivered.
            return;
        }
        client.blockOn(frame_id, transfer_id) catch return;
        defer client.releaseBlocking(frame_id);

        while (firstPending(state)) |first| {
            if (first.transfer_id != transfer_id) {
                break;
            }
            client.tickSync(200) catch |err| {
                log.debug(.http, "external stylesheet wait", .{ .err = err });
                return;
            };
        }
    }
}

/// True holds the deferred scripts back until the parser's stylesheets have
/// loaded. With nothing deferred, or no sheet in flight, DOMContentLoaded
/// follows the parse.
pub fn holdDeferredScripts(frame: *Frame) bool {
    const state = &frame._stylesheets;
    if (state.pending.first == null or frame._script_manager.base.defer_scripts.first == null) {
        return false;
    }
    state.deferred_held = true;
    return true;
}

fn firstPending(state: *State) ?*Load {
    const node = state.pending.first orelse return null;
    return @fieldParentPtr("node", node);
}

// One parser stylesheet in flight, in its own arena. Exactly one of
// done/error/shutdown runs.
const Load = struct {
    frame: *Frame,
    link: *Element.Html.Link,
    // The link's generation when the parser met it: a reprocessed or
    // disconnected link drops this load's outcome.
    generation: u32,
    arena: *lp.Arena,
    url: [:0]const u8,
    transfer_id: u32 = 0,
    // The transfer's, HttpClient.blockOn's key
    frame_id: u32 = 0,
    node: std.DoublyLinkedList.Node = .{},

    fn doneCallback(transfer: *HttpClient.Transfer) !void {
        const self: *Load = @ptrCast(@alignCast(transfer.req.ctx));
        const frame = self.frame;
        if (self.generation != self.link._generation or frame.isGoingAway()) {
            return self.settle(.load);
        }

        const arena = try frame._session.getArena(.large, "stylesheets.done");
        defer arena.release();

        const status = transfer.responseStatus() orelse 0;
        const kind = frame.applyStylesheet(self.link, self.url, status, transfer.contentType(), transfer.responseBody(), arena.allocator(), .tree_order) catch |err| blk: {
            log.debug(.http, "external stylesheet", .{ .err = err, .url = self.url });
            break :blk .@"error";
        };
        self.settle(kind);
    }

    fn errorCallback(ctx: *anyopaque, err: anyerror) void {
        const self: *Load = @ptrCast(@alignCast(ctx));
        log.debug(.http, "external stylesheet fetch", .{ .err = err, .url = self.url });
        self.settle(.@"error");
    }

    // Teardown or a superseding navigation: no event, no script, and the load
    // slot goes back without completing the document.
    fn shutdownCallback(ctx: *anyopaque) void {
        const self: *Load = @ptrCast(@alignCast(ctx));
        const frame = self.frame;
        frame._stylesheets.pending.remove(&self.node);
        self.arena.release();
        frame._pending_loads -|= 1;
    }

    fn settle(self: *Load, kind: Frame.QueuedEvent.Kind) void {
        const frame = self.frame;
        const link = self.link;
        const generation = self.generation;
        const state = &frame._stylesheets;
        state.pending.remove(&self.node);
        // Released before anything below, which can run JS and doesn't read
        // `self` again.
        self.arena.release();

        if (frame.isGoingAway()) {
            frame._pending_loads -|= 1;
            return;
        }

        // Queued, not dispatched: this can run on the parser's stack. A
        // reprocessed link's queued event is dropped.
        frame.queueLinkEvent(link, kind, generation) catch |err| {
            log.warn(.frame, "stylesheet queue event", .{ .err = err, .kind = kind });
        };

        if (state.deferred_held and state.pending.first == null) {
            state.deferred_held = false;
            const sm = &frame._script_manager;
            if (sm.base.static_scripts_done) {
                // document.open() and close() ran meanwhile.
                sm.base.evaluate();
            } else {
                sm.base.staticScriptsDone();
            }
        }

        frame.pendingLoadCompleted();
    }
};
