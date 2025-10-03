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

const js = @import("../js/js.zig");
const log = @import("../../log.zig");
const parser = @import("../netsurf.zig");
const Page = @import("../page.zig").Page;

const Navigator = @import("navigator.zig").Navigator;
const History = @import("History.zig");
const Location = @import("location.zig").Location;
const Crypto = @import("../crypto/crypto.zig").Crypto;
const Console = @import("../console/console.zig").Console;
const EventTarget = @import("../dom/event_target.zig").EventTarget;
const MediaQueryList = @import("media_query_list.zig").MediaQueryList;
const Performance = @import("../dom/performance.zig").Performance;
const CSSStyleDeclaration = @import("../cssom/CSSStyleDeclaration.zig");
const Screen = @import("screen.zig").Screen;
const domcss = @import("../dom/css.zig");
const Css = @import("../css/css.zig").Css;
const EventHandler = @import("../events/event.zig").EventHandler;

const Request = @import("../fetch/Request.zig");
const fetchFn = @import("../fetch/fetch.zig").fetch;

const storage = @import("../storage/storage.zig");

// https://dom.spec.whatwg.org/#interface-window-extensions
// https://html.spec.whatwg.org/multipage/nav-history-apis.html#window
pub const Window = struct {
    pub const prototype = *EventTarget;

    // Extend libdom event target for pure zig struct.
    base: parser.EventTargetTBase = parser.EventTargetTBase{ .internal_target_type = .window },

    document: *parser.DocumentHTML,
    target: []const u8 = "",
    location: Location = .{},
    storage_shelf: ?*storage.Shelf = null,

    // counter for having unique timer ids
    timer_id: u30 = 0,
    timers: std.AutoHashMapUnmanaged(u32, void) = .{},

    crypto: Crypto = .{},
    console: Console = .{},
    navigator: Navigator = .{},
    performance: Performance,
    screen: Screen = .{},
    css: Css = .{},
    scroll_x: u32 = 0,
    scroll_y: u32 = 0,
    onload_callback: ?js.Function = null,

    pub fn create(target: ?[]const u8, navigator: ?Navigator) !Window {
        var fbs = std.io.fixedBufferStream("");
        const html_doc = try parser.documentHTMLParse(fbs.reader(), "utf-8");
        const doc = parser.documentHTMLToDocument(html_doc);
        try parser.documentSetDocumentURI(doc, "about:blank");

        return .{
            .document = html_doc,
            .target = target orelse "",
            .navigator = navigator orelse .{},
            .performance = Performance.init(),
        };
    }

    pub fn replaceLocation(self: *Window, loc: Location) !void {
        self.location = loc;
        try parser.documentHTMLSetLocation(Location, self.document, &self.location);
    }

    pub fn replaceDocument(self: *Window, doc: *parser.DocumentHTML) !void {
        self.performance.reset(); // When to reset see: https://developer.mozilla.org/en-US/docs/Web/API/Performance/timeOrigin
        self.document = doc;
        try parser.documentHTMLSetLocation(Location, doc, &self.location);
    }

    pub fn setStorageShelf(self: *Window, shelf: *storage.Shelf) void {
        self.storage_shelf = shelf;
    }

    pub fn _fetch(_: *Window, input: Request.RequestInput, options: ?Request.RequestInit, page: *Page) !js.Promise {
        return fetchFn(input, options, page);
    }

    /// Returns `onload_callback`.
    pub fn get_onload(self: *const Window) ?js.Function {
        return self.onload_callback;
    }

    /// Sets `onload_callback`.
    pub fn set_onload(self: *Window, maybe_listener: ?EventHandler.Listener, page: *Page) !void {
        const event_target = parser.toEventTarget(Window, self);
        const event_type = "load";

        // Check if we have a listener set.
        if (self.onload_callback) |callback| {
            const listener = try parser.eventTargetHasListener(event_target, event_type, false, callback.id);
            std.debug.assert(listener != null);
            try parser.eventTargetRemoveEventListener(event_target, event_type, listener.?, false);
        }

        if (maybe_listener) |listener| {
            switch (listener) {
                // If an object is given as listener, do nothing.
                .object => {},
                .function => |callback| {
                    _ = try EventHandler.register(page.arena, event_target, event_type, listener, null) orelse unreachable;
                    self.onload_callback = callback;

                    return;
                },
            }
        }

        // Just unset the listener.
        self.onload_callback = null;
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

    pub fn set_location(_: *const Window, url: []const u8, page: *Page) !void {
        return page.navigateFromWebAPI(url, .{ .reason = .script });
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

    // frames return the window itself, but accessing it via a pseudo
    // array returns the Window object corresponding to the given frame or
    // iframe.
    // https://developer.mozilla.org/en-US/docs/Web/API/Window/frames
    pub fn get_frames(self: *Window) *Window {
        return self;
    }

    pub fn indexed_get(self: *Window, index: u32, has_value: *bool, page: *Page) !*Window {
        const frames = try domcss.querySelectorAll(
            page.call_arena,
            parser.documentHTMLToNode(self.document),
            "iframe",
        );

        if (index >= frames.nodes.items.len) {
            has_value.* = false;
            return undefined;
        }

        has_value.* = true;
        // TODO return the correct frame's window
        // frames.nodes.items[indexed]
        return error.TODO;
    }

    // Retrieve the numbre of frames/iframes from the DOM dynamically.
    pub fn get_length(self: *const Window, page: *Page) !u32 {
        const frames = try domcss.querySelectorAll(
            page.call_arena,
            parser.documentHTMLToNode(self.document),
            "iframe",
        );

        return frames.get_length();
    }

    pub fn get_top(self: *Window) *Window {
        return self;
    }

    pub fn get_document(self: *Window) ?*parser.DocumentHTML {
        return self.document;
    }

    pub fn get_history(_: *Window, page: *Page) *History {
        return &page.session.history;
    }

    //  The interior height of the window in pixels, including the height of the horizontal scroll bar, if present.
    pub fn get_innerHeight(_: *Window, page: *Page) u32 {
        // We do not have scrollbars or padding so this is the same as Element.clientHeight
        return page.renderer.height();
    }

    // The interior width of the window in pixels. That includes the width of the vertical scroll bar, if one is present.
    pub fn get_innerWidth(_: *Window, page: *Page) u32 {
        // We do not have scrollbars or padding so this is the same as Element.clientWidth
        return page.renderer.width();
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

    pub fn get_screen(self: *Window) *Screen {
        return &self.screen;
    }

    pub fn get_CSS(self: *Window) *Css {
        return &self.css;
    }

    pub fn _requestAnimationFrame(self: *Window, cbk: js.Function, page: *Page) !u32 {
        return self.createTimeout(cbk, 5, page, .{
            .animation_frame = true,
            .name = "animationFrame",
            .low_priority = true,
        });
    }

    pub fn _cancelAnimationFrame(self: *Window, id: u32) !void {
        _ = self.timers.remove(id);
    }

    pub fn _setTimeout(self: *Window, cbk: js.Function, delay: ?u32, params: []js.Object, page: *Page) !u32 {
        return self.createTimeout(cbk, delay, page, .{ .args = params, .name = "setTimeout" });
    }

    pub fn _setInterval(self: *Window, cbk: js.Function, delay: ?u32, params: []js.Object, page: *Page) !u32 {
        return self.createTimeout(cbk, delay, page, .{ .repeat = true, .args = params, .name = "setInterval" });
    }

    pub fn _clearTimeout(self: *Window, id: u32) !void {
        _ = self.timers.remove(id);
    }

    pub fn _clearInterval(self: *Window, id: u32) !void {
        _ = self.timers.remove(id);
    }

    pub fn _queueMicrotask(self: *Window, cbk: js.Function, page: *Page) !u32 {
        return self.createTimeout(cbk, 0, page, .{ .name = "queueMicrotask" });
    }

    pub fn _setImmediate(self: *Window, cbk: js.Function, page: *Page) !u32 {
        return self.createTimeout(cbk, 0, page, .{ .name = "setImmediate" });
    }

    pub fn _clearImmediate(self: *Window, id: u32) void {
        _ = self.timers.remove(id);
    }

    pub fn _matchMedia(_: *const Window, media: js.String) !MediaQueryList {
        return .{
            .matches = false, // TODO?
            .media = media.string,
        };
    }

    pub fn _btoa(_: *const Window, value: []const u8, page: *Page) ![]const u8 {
        const Encoder = std.base64.standard.Encoder;
        const out = try page.call_arena.alloc(u8, Encoder.calcSize(value.len));
        return Encoder.encode(out, value);
    }

    pub fn _atob(_: *const Window, value: []const u8, page: *Page) ![]const u8 {
        const Decoder = std.base64.standard.Decoder;
        const size = Decoder.calcSizeForSlice(value) catch return error.InvalidCharacterError;

        const out = try page.call_arena.alloc(u8, size);
        Decoder.decode(out, value) catch return error.InvalidCharacterError;
        return out;
    }

    const CreateTimeoutOpts = struct {
        name: []const u8,
        args: []js.Object = &.{},
        repeat: bool = false,
        animation_frame: bool = false,
        low_priority: bool = false,
    };
    fn createTimeout(self: *Window, cbk: js.Function, delay_: ?u32, page: *Page, opts: CreateTimeoutOpts) !u32 {
        const delay = delay_ orelse 0;
        if (self.timers.count() > 512) {
            return error.TooManyTimeout;
        }
        const timer_id = self.timer_id +% 1;
        self.timer_id = timer_id;

        const arena = page.arena;

        const gop = try self.timers.getOrPut(arena, timer_id);
        if (gop.found_existing) {
            // this can only happen if we've created 2^31 timeouts.
            return error.TooManyTimeout;
        } else {
            gop.value_ptr.* = {};
        }
        errdefer _ = self.timers.remove(timer_id);

        const args = opts.args;
        var persisted_args: []js.Object = &.{};
        if (args.len > 0) {
            persisted_args = try page.arena.alloc(js.Object, args.len);
            for (args, persisted_args) |a, *ca| {
                ca.* = try a.persist();
            }
        }

        const callback = try arena.create(TimerCallback);
        callback.* = .{
            .cbk = cbk,
            .window = self,
            .timer_id = timer_id,
            .args = persisted_args,
            .animation_frame = opts.animation_frame,
            // setting a repeat time of 0 is illegal, doing + 1 is a simple way to avoid that
            .repeat = if (opts.repeat) delay + 1 else null,
        };

        try page.scheduler.add(callback, TimerCallback.run, delay, .{
            .name = opts.name,
            .low_priority = opts.low_priority,
        });

        return timer_id;
    }

    // TODO: getComputedStyle should return a read-only CSSStyleDeclaration.
    // We currently don't have a read-only one, so we return a new instance on
    // each call.
    pub fn _getComputedStyle(_: *const Window, element: *parser.Element, pseudo_element: ?[]const u8) !CSSStyleDeclaration {
        _ = element;
        _ = pseudo_element;
        return .empty;
    }

    const ScrollToOpts = union(enum) {
        x: i32,
        opts: Opts,

        const Opts = struct {
            top: i32,
            left: i32,
            behavior: []const u8 = "",
        };
    };
    pub fn _scrollTo(self: *Window, opts: ScrollToOpts, y: ?i32) !void {
        switch (opts) {
            .x => |x| {
                self.scroll_x = @intCast(@max(x, 0));
                self.scroll_y = @intCast(@max(0, y orelse 0));
            },
            .opts => |o| {
                self.scroll_y = @intCast(@max(0, o.top));
                self.scroll_x = @intCast(@max(0, o.left));
            },
        }

        {
            const scroll_event = try parser.eventCreate();
            defer parser.eventDestroy(scroll_event);

            try parser.eventInit(scroll_event, "scroll", .{});
            _ = try parser.eventTargetDispatchEvent(
                parser.toEventTarget(Window, self),
                scroll_event,
            );
        }

        {
            const scroll_end = try parser.eventCreate();
            defer parser.eventDestroy(scroll_end);

            try parser.eventInit(scroll_end, "scrollend", .{});
            _ = try parser.eventTargetDispatchEvent(
                parser.toEventTarget(parser.DocumentHTML, self.document),
                scroll_end,
            );
        }
    }
    pub fn _scroll(self: *Window, opts: ScrollToOpts, y: ?i32) !void {
        // just an alias for scrollTo
        return self._scrollTo(opts, y);
    }

    pub fn get_scrollX(self: *const Window) u32 {
        return self.scroll_x;
    }

    pub fn get_scrollY(self: *const Window) u32 {
        return self.scroll_y;
    }

    pub fn get_pageXOffset(self: *const Window) u32 {
        // just an alias for scrollX
        return self.get_scrollX();
    }

    pub fn get_pageYOffset(self: *const Window) u32 {
        // just an alias for scrollY
        return self.get_scrollY();
    }

    // libdom's document doesn't have a parent, which is correct, but
    // breaks the event bubbling that happens for many events from
    // document -> window.
    // We need to force dispatch this event on the window, with the
    // document target.
    // In theory, we should do this for a lot of events and might need
    // to come up with a good way to solve this more generically. But
    // this specific event, and maybe a few others in the near future,
    // are blockers.
    // Worth noting that NetSurf itself appears to do something similar:
    // https://github.com/netsurf-browser/netsurf/blob/a32e1a03e1c91ee9f0aa211937dbae7a96831149/content/handlers/html/html.c#L380
    pub fn dispatchForDocumentTarget(self: *Window, evt: *parser.Event) !void {
        // we assume that this evt has already been dispatched on the document
        // and thus the target has already been set to the document.
        return self.base.redispatchEvent(evt);
    }
};

const TimerCallback = struct {
    // the id of our timer (windows.timers key)
    timer_id: u31,

    // if false, we'll remove the timer_id from the window.timers lookup on run
    repeat: ?u32,

    // The JavaScript callback to execute
    cbk: js.Function,

    animation_frame: bool = false,

    window: *Window,

    args: []js.Object = &.{},

    fn run(ctx: *anyopaque) ?u32 {
        const self: *TimerCallback = @ptrCast(@alignCast(ctx));
        if (self.repeat != null) {
            if (self.window.timers.contains(self.timer_id) == false) {
                // it was called
                return null;
            }
        } else if (self.window.timers.remove(self.timer_id) == false) {
            // it was cancelled
            return null;
        }

        var result: js.Function.Result = undefined;

        var call: anyerror!void = undefined;
        if (self.animation_frame) {
            call = self.cbk.tryCall(void, .{self.window.performance._now()}, &result);
        } else {
            call = self.cbk.tryCall(void, self.args, &result);
        }

        call catch {
            log.warn(.user_script, "callback error", .{
                .err = result.exception,
                .stack = result.stack,
                .source = "window timeout",
            });
        };

        return self.repeat;
    }
};

const testing = @import("../../testing.zig");
test "Browser: Window" {
    try testing.htmlRunner("window/window.html");
    try testing.htmlRunner("window/frames.html");
}
