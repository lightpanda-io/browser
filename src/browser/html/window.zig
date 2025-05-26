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

const parser = @import("../netsurf.zig");
const Function = @import("../env.zig").Function;
const SessionState = @import("../env.zig").SessionState;
const Loop = @import("../../runtime/loop.zig").Loop;

const Navigator = @import("navigator.zig").Navigator;
const History = @import("history.zig").History;
const Location = @import("location.zig").Location;
const Crypto = @import("../crypto/crypto.zig").Crypto;
const Console = @import("../console/console.zig").Console;
const EventTarget = @import("../dom/event_target.zig").EventTarget;
const MediaQueryList = @import("media_query_list.zig").MediaQueryList;
const Performance = @import("performance.zig").Performance;
const TrustedTypePolicyFactory = @import("trusted_types.zig").TrustedTypePolicyFactory;

const storage = @import("../storage/storage.zig");

const log = std.log.scoped(.window);

// https://dom.spec.whatwg.org/#interface-window-extensions
// https://html.spec.whatwg.org/multipage/nav-history-apis.html#window
pub const Window = struct {
    pub const prototype = *EventTarget;

    // Extend libdom event target for pure zig struct.
    base: parser.EventTargetTBase = parser.EventTargetTBase{},

    document: *parser.DocumentHTML,
    target: []const u8 = "",
    history: History = .{},
    location: Location = .{},
    storage_shelf: ?*storage.Shelf = null,

    // counter for having unique timer ids
    timer_id: u31 = 0,
    timers: std.AutoHashMapUnmanaged(u32, *TimerCallback) = .{},

    crypto: Crypto = .{},
    console: Console = .{},
    navigator: Navigator = .{},
    performance: Performance,
    trusted_types: TrustedTypePolicyFactory = .{},

    pub fn create(target: ?[]const u8, navigator: ?Navigator) !Window {
        var fbs = std.io.fixedBufferStream("");
        const html_doc = try parser.documentHTMLParse(fbs.reader(), "utf-8");
        const doc = parser.documentHTMLToDocument(html_doc);
        try parser.documentSetDocumentURI(doc, "about:blank");

        return .{
            .document = html_doc,
            .target = target orelse "",
            .navigator = navigator orelse .{},
            .performance = .{ .time_origin = try std.time.Timer.start() },
        };
    }

    pub fn replaceLocation(self: *Window, loc: Location) !void {
        self.location = loc;
        try parser.documentHTMLSetLocation(Location, self.document, &self.location);
    }

    pub fn replaceDocument(self: *Window, doc: *parser.DocumentHTML) !void {
        self.performance.time_origin.reset(); // When to reset see: https://developer.mozilla.org/en-US/docs/Web/API/Performance/timeOrigin
        self.document = doc;
        try parser.documentHTMLSetLocation(Location, doc, &self.location);
    }

    pub fn setStorageShelf(self: *Window, shelf: *storage.Shelf) void {
        self.storage_shelf = shelf;
    }

    pub fn get_window(self: *Window) *Window {
        return self;
    }

    pub fn get_navigator(self: *Window) *Navigator {
        return &self.navigator;
    }

    pub fn get_location(self: *Window) *Location {
        return &self.location;
    }

    pub fn get_console(self: *Window) *Console {
        return &self.console;
    }

    pub fn get_crypto(self: *Window) *Crypto {
        return &self.crypto;
    }

    pub fn get_self(self: *Window) *Window {
        return self;
    }

    pub fn get_parent(self: *Window) *Window {
        return self;
    }

    pub fn get_document(self: *Window) ?*parser.DocumentHTML {
        return self.document;
    }

    pub fn get_history(self: *Window) *History {
        return &self.history;
    }

    //  The interior height of the window in pixels, including the height of the horizontal scroll bar, if present.
    pub fn get_innerHeight(_: *Window, state: *SessionState) u32 {
        // We do not have scrollbars or padding so this is the same as Element.clientHeight
        return state.renderer.height();
    }

    // The interior width of the window in pixels. That includes the width of the vertical scroll bar, if one is present.
    pub fn get_innerWidth(_: *Window, state: *SessionState) u32 {
        // We do not have scrollbars or padding so this is the same as Element.clientWidth
        return state.renderer.width();
    }

    pub fn get_name(self: *Window) []const u8 {
        return self.target;
    }

    pub fn get_localStorage(self: *Window) !*storage.Bottle {
        if (self.storage_shelf == null) return parser.DOMError.NotSupported;
        return &self.storage_shelf.?.bucket.local;
    }

    pub fn get_sessionStorage(self: *Window) !*storage.Bottle {
        if (self.storage_shelf == null) return parser.DOMError.NotSupported;
        return &self.storage_shelf.?.bucket.session;
    }

    pub fn get_performance(self: *Window) *Performance {
        return &self.performance;
    }

    pub fn get_trustedTypes(self: *Window) !TrustedTypePolicyFactory {
        return self.trusted_types;
    }

    // Tells the browser you wish to perform an animation. It requests the browser to call a user-supplied callback function before the next repaint.
    // fn callback(timestamp: f64)
    // Returns the request ID, that uniquely identifies the entry in the callback list.
    pub fn _requestAnimationFrame(
        self: *Window,
        callback: Function,
    ) !u32 {
        // We immediately execute the callback, but this may not be correct TBD.
        // Since: When multiple callbacks queued by requestAnimationFrame() begin to fire in a single frame, each receives the same timestamp even though time has passed during the computation of every previous callback's workload.
        var result: Function.Result = undefined;
        callback.tryCall(void, .{self.performance._now()}, &result) catch {
            log.err("Window.requestAnimationFrame(): {s}", .{result.exception});
            log.debug("stack:\n{s}", .{result.stack orelse "???"});
        };
        return 99; // not unique, but user cannot make assumptions about it. cancelAnimationFrame will be too late anyway.
    }

    // Cancels an animation frame request previously scheduled through requestAnimationFrame().
    // This is a no-op since _requestAnimationFrame immediately executes the callback.
    pub fn _cancelAnimationFrame(_: *Window, request_id: u32) void {
        _ = request_id;
    }

    // TODO handle callback arguments.
    pub fn _setTimeout(self: *Window, cbk: Function, delay: ?u32, state: *SessionState) !u32 {
        return self.createTimeout(cbk, delay, state, false);
    }

    // TODO handle callback arguments.
    pub fn _setInterval(self: *Window, cbk: Function, delay: ?u32, state: *SessionState) !u32 {
        return self.createTimeout(cbk, delay, state, true);
    }

    pub fn _clearTimeout(self: *Window, id: u32, state: *SessionState) !void {
        const kv = self.timers.fetchRemove(id) orelse return;
        try state.loop.cancel(kv.value.loop_id);
    }

    pub fn _clearInterval(self: *Window, id: u32, state: *SessionState) !void {
        const kv = self.timers.fetchRemove(id) orelse return;
        try state.loop.cancel(kv.value.loop_id);
    }

    pub fn _matchMedia(_: *const Window, media: []const u8, state: *SessionState) !MediaQueryList {
        return .{
            .matches = false, // TODO?
            .media = try state.arena.dupe(u8, media),
        };
    }

    fn createTimeout(self: *Window, cbk: Function, delay_: ?u32, state: *SessionState, comptime repeat: bool) !u32 {
        if (self.timers.count() > 512) {
            return error.TooManyTimeout;
        }
        const timer_id = self.timer_id +% 1;
        self.timer_id = timer_id;

        const arena = state.arena;

        const gop = try self.timers.getOrPut(arena, timer_id);
        if (gop.found_existing) {
            // this can only happen if we've created 2^31 timeouts.
            return error.TooManyTimeout;
        }
        errdefer _ = self.timers.remove(timer_id);

        const delay: u63 = @as(u63, (delay_ orelse 0)) * std.time.ns_per_ms;
        const callback = try arena.create(TimerCallback);

        callback.* = .{
            .cbk = cbk,
            .loop_id = 0, // we're going to set this to a real value shortly
            .window = self,
            .timer_id = timer_id,
            .node = .{ .func = TimerCallback.run },
            .repeat = if (repeat) delay else null,
        };
        callback.loop_id = try state.loop.timeout(delay, &callback.node);

        gop.value_ptr.* = callback;
        return timer_id;
    }

    // NOT IMPLEMENTED - This is a dummy implementation that always returns null to deter PlayWright from using this path to solve click.js.
    // returns an object containing the values of all CSS properties of an element, after applying active stylesheets and resolving any basic computation those values may contain.
    pub fn _getComputedStyle(_: *Window, element: *parser.Element, pseudo_element: ?[]const u8) !?void {
        _ = element;
        _ = pseudo_element;
        log.warn("Not implemented function getComputedStyle called, null returned", .{});
        return null;
    }
};

const TimerCallback = struct {
    // the internal loop id, need it when cancelling
    loop_id: usize,

    // the id of our timer (windows.timers key)
    timer_id: u31,

    // The JavaScript callback to execute
    cbk: Function,

    // This is the internal data that the event loop tracks. We'll get this
    // back in run and, from it, can get our TimerCallback instance
    node: Loop.CallbackNode = undefined,

    // if the event should be repeated
    repeat: ?u63 = null,

    window: *Window,

    fn run(node: *Loop.CallbackNode, repeat_delay: *?u63) void {
        const self: *TimerCallback = @fieldParentPtr("node", node);

        var result: Function.Result = undefined;
        self.cbk.tryCall(void, .{}, &result) catch {
            log.err("timeout callback error: {s}", .{result.exception});
            log.debug("stack:\n{s}", .{result.stack orelse "???"});
        };

        if (self.repeat) |r| {
            // setInterval
            repeat_delay.* = r;
            return;
        }

        // setTimeout
        _ = self.window.timers.remove(self.timer_id);
    }
};

const testing = @import("../../testing.zig");
test "Browser.HTML.Window" {
    var runner = try testing.jsRunner(testing.tracking_allocator, .{});
    defer runner.deinit();

    // requestAnimationFrame should be able to wait by recursively calling itself
    // Note however that we in this test do not wait as the request is just send to the browser
    try runner.testCases(&.{
        .{
            \\ let start;
            \\ function step(timestamp) {
            \\    if (start === undefined) {
            \\      start = timestamp;
            \\    }
            \\    const elapsed = timestamp - start;
            \\    if (elapsed < 2000) {
            \\      requestAnimationFrame(step);
            \\    }
            \\ }
            ,
            null,
        },
        .{ "requestAnimationFrame(step);", null }, // returned id is checked in the next test
    }, .{});

    // cancelAnimationFrame should be able to cancel a request with the given id
    try runner.testCases(&.{
        .{ "let request_id = requestAnimationFrame(timestamp => {});", null },
        .{ "cancelAnimationFrame(request_id);", "undefined" },
    }, .{});

    try runner.testCases(&.{
        .{ "innerHeight", "1" },
        .{ "innerWidth", "1" }, // Width is 1 even if there are no elements
        .{
            \\ let div1 = document.createElement('div');
            \\ document.body.appendChild(div1);
            \\ div1.getClientRects();
            ,
            null,
        },
        .{
            \\ let div2 = document.createElement('div');
            \\ document.body.appendChild(div2);
            \\ div2.getClientRects();
            ,
            null,
        },
        .{ "innerHeight", "1" },
        .{ "innerWidth", "2" },
    }, .{});
}
