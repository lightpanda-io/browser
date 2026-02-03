// Copyright (C) 2023-2025  Lightpanda (Selecy SAS)
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
const builtin = @import("builtin");

const log = @import("../../log.zig");
const Page = @import("../Page.zig");
const Scheduler = @import("../Scheduler.zig");
const Console = @import("Console.zig");
const History = @import("History.zig");
const Navigation = @import("navigation/Navigation.zig");
const Crypto = @import("Crypto.zig");
const CSS = @import("CSS.zig");
const Navigator = @import("Navigator.zig");
const Screen = @import("Screen.zig");
const Performance = @import("Performance.zig");
const Document = @import("Document.zig");
const Location = @import("Location.zig");
const Fetch = @import("net/Fetch.zig");
const Event = @import("Event.zig");
const EventTarget = @import("EventTarget.zig");
const ErrorEvent = @import("event/ErrorEvent.zig");
const MessageEvent = @import("event/MessageEvent.zig");
const MediaQueryList = @import("css/MediaQueryList.zig");
const storage = @import("storage/storage.zig");
const Element = @import("Element.zig");
const CSSStyleProperties = @import("css/CSSStyleProperties.zig");
const CustomElementRegistry = @import("CustomElementRegistry.zig");
const Selection = @import("Selection.zig");

const Allocator = std.mem.Allocator;

const Window = @This();

_proto: *EventTarget,
_document: *Document,
_css: CSS = .init,
_crypto: Crypto = .init,
_console: Console = .init,
_navigator: Navigator = .init,
_screen: *Screen,
_performance: Performance,
_storage_bucket: *storage.Bucket,
_on_load: ?js.Function.Global = null,
_on_pageshow: ?js.Function.Global = null,
_on_popstate: ?js.Function.Global = null,
_on_error: ?js.Function.Global = null,
_on_unhandled_rejection: ?js.Function.Global = null, // TODO: invoke on error
_location: *Location,
_timer_id: u30 = 0,
_timers: std.AutoHashMapUnmanaged(u32, *ScheduleCallback) = .{},
_custom_elements: CustomElementRegistry = .{},
_scroll_pos: struct {
    x: u32,
    y: u32,
    state: enum {
        scroll,
        end,
        done,
    },
} = .{
    .x = 0,
    .y = 0,
    .state = .done,
},

pub fn asEventTarget(self: *Window) *EventTarget {
    return self._proto;
}

pub fn getSelf(self: *Window) *Window {
    return self;
}

pub fn getWindow(self: *Window) *Window {
    return self;
}

pub fn getDocument(self: *Window) *Document {
    return self._document;
}

pub fn getConsole(self: *Window) *Console {
    return &self._console;
}

pub fn getNavigator(self: *Window) *Navigator {
    return &self._navigator;
}

pub fn getScreen(self: *Window) *Screen {
    return self._screen;
}

pub fn getCrypto(self: *Window) *Crypto {
    return &self._crypto;
}

pub fn getCSS(self: *Window) *CSS {
    return &self._css;
}

pub fn getPerformance(self: *Window) *Performance {
    return &self._performance;
}

pub fn getLocalStorage(self: *const Window) *storage.Lookup {
    return &self._storage_bucket.local;
}

pub fn getSessionStorage(self: *const Window) *storage.Lookup {
    return &self._storage_bucket.session;
}

pub fn getLocation(self: *const Window) *Location {
    return self._location;
}

pub fn getSelection(self: *const Window) *Selection {
    return &self._document._selection;
}

pub fn setLocation(_: *const Window, url: [:0]const u8, page: *Page) !void {
    return page.scheduleNavigation(url, .{ .reason = .script, .kind = .{ .push = null } }, .script);
}

pub fn getHistory(_: *Window, page: *Page) *History {
    return &page._session.history;
}

pub fn getNavigation(_: *Window, page: *Page) *Navigation {
    return &page._session.navigation;
}

pub fn getCustomElements(self: *Window) *CustomElementRegistry {
    return &self._custom_elements;
}

pub fn getOnLoad(self: *const Window) ?js.Function.Global {
    return self._on_load;
}

pub fn setOnLoad(self: *Window, setter: ?FunctionSetter) void {
    self._on_load = getFunctionFromSetter(setter);
}

pub fn getOnPageShow(self: *const Window) ?js.Function.Global {
    return self._on_pageshow;
}

pub fn setOnPageShow(self: *Window, setter: ?FunctionSetter) void {
    self._on_pageshow = getFunctionFromSetter(setter);
}

pub fn getOnPopState(self: *const Window) ?js.Function.Global {
    return self._on_popstate;
}

pub fn setOnPopState(self: *Window, setter: ?FunctionSetter) void {
    self._on_popstate = getFunctionFromSetter(setter);
}

pub fn getOnError(self: *const Window) ?js.Function.Global {
    return self._on_error;
}

pub fn setOnError(self: *Window, setter: ?FunctionSetter) void {
    self._on_error = getFunctionFromSetter(setter);
}

pub fn getOnUnhandledRejection(self: *const Window) ?js.Function.Global {
    return self._on_unhandled_rejection;
}

pub fn setOnUnhandledRejection(self: *Window, setter: ?FunctionSetter) void {
    self._on_unhandled_rejection = getFunctionFromSetter(setter);
}

pub fn fetch(_: *const Window, input: Fetch.Input, options: ?Fetch.InitOpts, page: *Page) !js.Promise {
    return Fetch.init(input, options, page);
}

pub fn setTimeout(self: *Window, cb: js.Function.Temp, delay_ms: ?u32, params: []js.Value.Temp, page: *Page) !u32 {
    return self.scheduleCallback(cb, delay_ms orelse 0, .{
        .repeat = false,
        .params = params,
        .low_priority = false,
        .name = "window.setTimeout",
    }, page);
}

pub fn setInterval(self: *Window, cb: js.Function.Temp, delay_ms: ?u32, params: []js.Value.Temp, page: *Page) !u32 {
    return self.scheduleCallback(cb, delay_ms orelse 0, .{
        .repeat = true,
        .params = params,
        .low_priority = false,
        .name = "window.setInterval",
    }, page);
}

pub fn setImmediate(self: *Window, cb: js.Function.Temp, params: []js.Value.Temp, page: *Page) !u32 {
    return self.scheduleCallback(cb, 0, .{
        .repeat = false,
        .params = params,
        .low_priority = false,
        .name = "window.setImmediate",
    }, page);
}

pub fn requestAnimationFrame(self: *Window, cb: js.Function.Temp, page: *Page) !u32 {
    return self.scheduleCallback(cb, 5, .{
        .repeat = false,
        .params = &.{},
        .low_priority = false,
        .mode = .animation_frame,
        .name = "window.requestAnimationFrame",
    }, page);
}

pub fn queueMicrotask(_: *Window, cb: js.Function, page: *Page) void {
    page.js.queueMicrotaskFunc(cb);
}

pub fn clearTimeout(self: *Window, id: u32) void {
    var sc = self._timers.get(id) orelse return;
    sc.removed = true;
}

pub fn clearInterval(self: *Window, id: u32) void {
    var sc = self._timers.get(id) orelse return;
    sc.removed = true;
}

pub fn clearImmediate(self: *Window, id: u32) void {
    var sc = self._timers.get(id) orelse return;
    sc.removed = true;
}

pub fn cancelAnimationFrame(self: *Window, id: u32) void {
    var sc = self._timers.get(id) orelse return;
    sc.removed = true;
}

const RequestIdleCallbackOpts = struct {
    timeout: ?u32 = null,
};
pub fn requestIdleCallback(self: *Window, cb: js.Function.Temp, opts_: ?RequestIdleCallbackOpts, page: *Page) !u32 {
    const opts = opts_ orelse RequestIdleCallbackOpts{};
    return self.scheduleCallback(cb, opts.timeout orelse 50, .{
        .mode = .idle,
        .repeat = false,
        .params = &.{},
        .low_priority = true,
        .name = "window.requestIdleCallback",
    }, page);
}

pub fn cancelIdleCallback(self: *Window, id: u32) void {
    var sc = self._timers.get(id) orelse return;
    sc.removed = true;
}

pub fn reportError(self: *Window, err: js.Value, page: *Page) !void {
    const error_event = try ErrorEvent.initTrusted("error", .{
        .@"error" = try err.persist(),
        .message = err.toStringSlice() catch "Unknown error",
        .bubbles = false,
        .cancelable = true,
    }, page);

    const event = error_event.asEvent();

    // Invoke window.onerror callback if set (per WHATWG spec, this is called
    // with 5 arguments: message, source, lineno, colno, error)
    // If it returns true, the event is cancelled.
    if (self._on_error) |on_error| {
        var ls: js.Local.Scope = undefined;
        page.js.localScope(&ls);
        defer ls.deinit();

        const local_func = ls.toLocal(on_error);
        const result = local_func.call(js.Value, .{
            error_event._message,
            error_event._filename,
            error_event._line_number,
            error_event._column_number,
            err,
        }) catch null;

        // Per spec: returning true from onerror cancels the event
        if (result) |r| {
            if (r.isTrue()) {
                event._prevent_default = true;
            }
        }
    }

    try page._event_manager.dispatch(self.asEventTarget(), event);

    if (comptime builtin.is_test == false) {
        if (!event._prevent_default) {
            log.warn(.js, "window.reportError", .{
                .message = error_event._message,
                .filename = error_event._filename,
                .line_number = error_event._line_number,
                .column_number = error_event._column_number,
            });
        }
    }
}

pub fn matchMedia(_: *const Window, query: []const u8, page: *Page) !*MediaQueryList {
    return page._factory.eventTarget(MediaQueryList{
        ._proto = undefined,
        ._media = try page.dupeString(query),
    });
}

pub fn getComputedStyle(_: *const Window, element: *Element, pseudo_element: ?[]const u8, page: *Page) !*CSSStyleProperties {
    if (pseudo_element) |pe| {
        if (pe.len != 0) {
            log.warn(.not_implemented, "window.GetComputedStyle", .{ .pseudo_element = pe });
        }
    }
    return CSSStyleProperties.init(element, true, page);
}

pub fn getIsSecureContext(_: *const Window) bool {
    // Return false since we don't have secure-context-only APIs implemented
    // (webcam, geolocation, clipboard, etc.)
    // This is safer and could help avoid processing errors by hinting at
    // sites not to try to access those features
    return false;
}

pub fn postMessage(self: *Window, message: js.Value.Global, target_origin: ?[]const u8, page: *Page) !void {
    // For now, we ignore targetOrigin checking and just dispatch the message
    // In a full implementation, we would validate the origin
    _ = target_origin;

    // postMessage queues a task (not a microtask), so use the scheduler
    const arena = try page.getArena(.{ .debug = "Window.schedule" });
    errdefer page.releaseArena(arena);

    const origin = try self._location.getOrigin(page);
    const callback = try arena.create(PostMessageCallback);
    callback.* = .{
        .page = page,
        .arena = arena,
        .message = message,
        .origin = try arena.dupe(u8, origin),
    };

    return page.scheduler.once(
        .{ .name = "postMessage", .prio = .high },
        PostMessageCallback,
        callback,
        PostMessageCallback,
    );
}

pub fn btoa(_: *const Window, input: []const u8, page: *Page) ![]const u8 {
    const encoded_len = std.base64.standard.Encoder.calcSize(input.len);
    const encoded = try page.call_arena.alloc(u8, encoded_len);
    return std.base64.standard.Encoder.encode(encoded, input);
}

pub fn atob(_: *const Window, input: []const u8, page: *Page) ![]const u8 {
    const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(input) catch return error.InvalidCharacterError;
    const decoded = try page.call_arena.alloc(u8, decoded_len);
    std.base64.standard.Decoder.decode(decoded, input) catch return error.InvalidCharacterError;
    return decoded;
}

pub fn getFrame(_: *Window, _: usize) !?*Window {
    // TODO return the iframe's window.
    return null;
}

pub fn getFramesLength(self: *const Window) u32 {
    const TreeWalker = @import("TreeWalker.zig");
    var walker = TreeWalker.Full.init(self._document.asNode(), .{});

    var ln: u32 = 0;
    while (walker.next()) |node| {
        if (node.is(Element.Html.IFrame) != null) {
            ln += 1;
        }
    }

    return ln;
}

pub fn getInnerWidth(_: *const Window) u32 {
    return 1920;
}

pub fn getInnerHeight(_: *const Window) u32 {
    return 1080;
}

pub fn getScrollX(self: *const Window) u32 {
    return self._scroll_pos.x;
}

pub fn getScrollY(self: *const Window) u32 {
    return self._scroll_pos.y;
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
pub fn scrollTo(self: *Window, opts: ScrollToOpts, y: ?i32, page: *Page) !void {
    switch (opts) {
        .x => |x| {
            self._scroll_pos.x = @intCast(@max(x, 0));
            self._scroll_pos.y = @intCast(@max(0, y orelse 0));
        },
        .opts => |o| {
            self._scroll_pos.x = @intCast(@max(0, o.left));
            self._scroll_pos.y = @intCast(@max(0, o.top));
        },
    }

    self._scroll_pos.state = .scroll;

    // We dispatch scroll event asynchronously after 10ms. So we can throttle
    // them.
    try page.scheduler.once(
        .{ .prio = .low },
        Page,
        page,
        struct {
            pub fn action(_: *Scheduler, p: *Page) !void {
                const pos = &p.window._scroll_pos;
                // If the state isn't scroll, we can ignore safely to throttle
                // the events.
                if (pos.state != .scroll) {
                    return;
                }

                const event = try Event.initTrusted("scroll", .{ .bubbles = true }, p);
                try p._event_manager.dispatch(p.document.asEventTarget(), event);

                pos.state = .end;

                return;
            }
        },
    );

    // We dispatch scrollend event asynchronously after 20ms.
    try page.scheduler.after(
        .{ .prio = .low },
        Page,
        page,
        20,
        struct {
            pub fn action(_: *Scheduler, p: *Page) !Scheduler.AfterAction {
                const pos = &p.window._scroll_pos;
                // Dispatch only if the state is .end.
                // If a scroll is pending, retry in 10ms.
                // If the state is .end, the event has been dispatched, so
                // ignore safely.
                switch (pos.state) {
                    .scroll => return .repeat(10),
                    .end => {},
                    .done => return .dont_repeat,
                }
                const event = try Event.initTrusted("scrollend", .{ .bubbles = true }, p);
                try p._event_manager.dispatch(p.document.asEventTarget(), event);

                pos.state = .done;

                return .dont_repeat;
            }
        },
    );
}

const ScheduleOpts = struct {
    repeat: bool,
    params: []js.Value.Temp,
    name: []const u8,
    low_priority: bool = false,
    animation_frame: bool = false,
    mode: ScheduleCallback.Mode = .normal,
};
fn scheduleCallback(self: *Window, cb: js.Function.Temp, delay_ms: u32, opts: ScheduleOpts, page: *Page) !u32 {
    if (self._timers.count() > 512) {
        // these are active
        return error.TooManyTimeout;
    }

    const arena = try page.getArena(.{ .debug = "Window.schedule" });
    errdefer page.releaseArena(arena);

    const timer_id = self._timer_id +% 1;
    self._timer_id = timer_id;

    const params = opts.params;
    var persisted_params: []js.Value.Temp = &.{};
    if (params.len > 0) {
        persisted_params = try arena.dupe(js.Value.Temp, params);
    }

    const gop = try self._timers.getOrPut(page.arena, timer_id);
    if (gop.found_existing) {
        // 2^31 would have to wrap for this to happen.
        return error.TooManyTimeout;
    }
    errdefer _ = self._timers.remove(timer_id);

    const callback = try arena.create(ScheduleCallback);
    callback.* = .{
        .cb = cb,
        .page = page,
        .arena = arena,
        .mode = opts.mode,
        .name = opts.name,
        .timer_id = timer_id,
        .params = persisted_params,
        .repeat_ms = if (opts.repeat) if (delay_ms == 0) 1 else delay_ms else null,
    };
    gop.value_ptr.* = callback;

    //try page.scheduler.add(callback, ScheduleCallback.run, delay_ms, .{
    //    .name = opts.name,
    //    .low_priority = opts.low_priority,
    //    .finalizer = ScheduleCallback.cancelled,
    //});

    try page.scheduler.after(
        .{ .prio = .high },
        ScheduleCallback,
        callback,
        delay_ms,
        ScheduleCallback,
    );

    return timer_id;
}

const ScheduleCallback = struct {
    // for debugging
    name: []const u8,

    // window._timers key
    timer_id: u31,

    // delay, in ms, to repeat. When null, will be removed after the first time
    repeat_ms: ?u32,

    cb: js.Function.Temp,

    mode: Mode,
    page: *Page,
    arena: Allocator,
    removed: bool = false,
    params: []const js.Value.Temp,

    const Mode = enum {
        idle,
        normal,
        animation_frame,
    };

    fn deinit(self: *ScheduleCallback) void {
        self.page.js.release(self.cb);
        for (self.params) |param| {
            self.page.js.release(param);
        }
        self.page.releaseArena(self.arena);
    }

    pub fn finalize(self: *ScheduleCallback) void {
        self.deinit();
    }

    pub fn action(_: *Scheduler, self: *ScheduleCallback) !Scheduler.AfterAction {
        const page = self.page;
        const window = page.window;

        if (self.removed) {
            _ = window._timers.remove(self.timer_id);
            self.deinit();
            return .dont_repeat;
        }

        var ls: js.Local.Scope = undefined;
        page.js.localScope(&ls);
        defer ls.deinit();

        switch (self.mode) {
            .idle => {
                const IdleDeadline = @import("IdleDeadline.zig");
                ls.toLocal(self.cb).call(void, .{IdleDeadline{}}) catch |err| {
                    log.warn(.js, "window.idleCallback", .{ .name = self.name, .err = err });
                };
            },
            .animation_frame => {
                ls.toLocal(self.cb).call(void, .{window._performance.now()}) catch |err| {
                    log.warn(.js, "window.RAF", .{ .name = self.name, .err = err });
                };
            },
            .normal => {
                ls.toLocal(self.cb).call(void, self.params) catch |err| {
                    log.warn(.js, "window.timer", .{ .name = self.name, .err = err });
                };
            },
        }
        ls.local.runMicrotasks();
        if (self.repeat_ms) |ms| {
            return .repeat(@intCast(ms));
        }
        defer self.deinit();
        _ = window._timers.remove(self.timer_id);
        return .dont_repeat;
    }
};

const PostMessageCallback = struct {
    page: *Page,
    arena: Allocator,
    origin: []const u8,
    message: js.Value.Global,

    fn deinit(self: *PostMessageCallback) void {
        self.page.releaseArena(self.arena);
    }

    pub fn finalize(self: *PostMessageCallback) void {
        self.page.releaseArena(self.arena);
    }

    pub fn action(_: *Scheduler, self: *PostMessageCallback) !void {
        defer self.deinit();

        const page = self.page;
        const window = page.window;

        const message_event = try MessageEvent.initTrusted("message", .{
            .data = self.message,
            .origin = self.origin,
            .source = window,
            .bubbles = false,
            .cancelable = false,
        }, page);

        const event = message_event.asEvent();
        try page._event_manager.dispatch(window.asEventTarget(), event);
    }
};

const FunctionSetter = union(enum) {
    func: js.Function.Global,
    anything: js.Value,
};

// window.onload = {}; doesn't fail, but it doesn't do anything.
// seems like setting to null is ok (though, at least on Firefix, it preserves
// the original value, which we could do, but why?)
fn getFunctionFromSetter(setter_: ?FunctionSetter) ?js.Function.Global {
    const setter = setter_ orelse return null;
    return switch (setter) {
        .func => |func| func, // Already a Global from bridge auto-conversion
        .anything => null,
    };
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Window);

    pub const Meta = struct {
        pub const name = "Window";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const top = bridge.accessor(Window.getWindow, null, .{ .cache = "top" });
    pub const self = bridge.accessor(Window.getWindow, null, .{ .cache = "self" });
    pub const window = bridge.accessor(Window.getWindow, null, .{ .cache = "window" });
    pub const parent = bridge.accessor(Window.getWindow, null, .{ .cache = "parent" });
    pub const console = bridge.accessor(Window.getConsole, null, .{ .cache = "console" });
    pub const navigator = bridge.accessor(Window.getNavigator, null, .{ .cache = "navigator" });
    pub const screen = bridge.accessor(Window.getScreen, null, .{ .cache = "screen" });
    pub const performance = bridge.accessor(Window.getPerformance, null, .{ .cache = "performance" });
    pub const localStorage = bridge.accessor(Window.getLocalStorage, null, .{ .cache = "localStorage" });
    pub const sessionStorage = bridge.accessor(Window.getSessionStorage, null, .{ .cache = "sessionStorage" });
    pub const document = bridge.accessor(Window.getDocument, null, .{ .cache = "document" });
    pub const location = bridge.accessor(Window.getLocation, Window.setLocation, .{});
    pub const history = bridge.accessor(Window.getHistory, null, .{});
    pub const navigation = bridge.accessor(Window.getNavigation, null, .{});
    pub const crypto = bridge.accessor(Window.getCrypto, null, .{ .cache = "crypto" });
    pub const CSS = bridge.accessor(Window.getCSS, null, .{ .cache = "CSS" });
    pub const customElements = bridge.accessor(Window.getCustomElements, null, .{ .cache = "customElements" });
    pub const onload = bridge.accessor(Window.getOnLoad, Window.setOnLoad, .{});
    pub const onpageshow = bridge.accessor(Window.getOnPageShow, Window.setOnPageShow, .{});
    pub const onpopstate = bridge.accessor(Window.getOnPopState, Window.setOnPopState, .{});
    pub const onerror = bridge.accessor(Window.getOnError, Window.setOnError, .{});
    pub const onunhandledrejection = bridge.accessor(Window.getOnUnhandledRejection, Window.setOnUnhandledRejection, .{});
    pub const fetch = bridge.function(Window.fetch, .{});
    pub const queueMicrotask = bridge.function(Window.queueMicrotask, .{});
    pub const setTimeout = bridge.function(Window.setTimeout, .{});
    pub const clearTimeout = bridge.function(Window.clearTimeout, .{});
    pub const setInterval = bridge.function(Window.setInterval, .{});
    pub const clearInterval = bridge.function(Window.clearInterval, .{});
    pub const setImmediate = bridge.function(Window.setImmediate, .{});
    pub const clearImmediate = bridge.function(Window.clearImmediate, .{});
    pub const requestAnimationFrame = bridge.function(Window.requestAnimationFrame, .{});
    pub const cancelAnimationFrame = bridge.function(Window.cancelAnimationFrame, .{});
    pub const requestIdleCallback = bridge.function(Window.requestIdleCallback, .{});
    pub const cancelIdleCallback = bridge.function(Window.cancelIdleCallback, .{});
    pub const matchMedia = bridge.function(Window.matchMedia, .{});
    pub const postMessage = bridge.function(Window.postMessage, .{});
    pub const btoa = bridge.function(Window.btoa, .{});
    pub const atob = bridge.function(Window.atob, .{});
    pub const reportError = bridge.function(Window.reportError, .{});
    pub const getComputedStyle = bridge.function(Window.getComputedStyle, .{});
    pub const getSelection = bridge.function(Window.getSelection, .{});
    pub const isSecureContext = bridge.accessor(Window.getIsSecureContext, null, .{});
    pub const frames = bridge.accessor(Window.getWindow, null, .{ .cache = "frames" });
    pub const index = bridge.indexed(Window.getFrame, .{ .null_as_undefined = true });
    pub const length = bridge.accessor(Window.getFramesLength, null, .{ .cache = "length" });
    pub const innerWidth = bridge.accessor(Window.getInnerWidth, null, .{ .cache = "innerWidth" });
    pub const innerHeight = bridge.accessor(Window.getInnerHeight, null, .{ .cache = "innerHeight" });
    pub const scrollX = bridge.accessor(Window.getScrollX, null, .{ .cache = "scrollX" });
    pub const scrollY = bridge.accessor(Window.getScrollY, null, .{ .cache = "scrollY" });
    pub const pageXOffset = bridge.accessor(Window.getScrollX, null, .{ .cache = "pageXOffset" });
    pub const pageYOffset = bridge.accessor(Window.getScrollY, null, .{ .cache = "pageYOffset" });
    pub const scrollTo = bridge.function(Window.scrollTo, .{});
    pub const scroll = bridge.function(Window.scrollTo, .{});
};

const testing = @import("../../testing.zig");
test "WebApi: Window" {
    try testing.htmlRunner("window", .{});
}
