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

const std = @import("std");
const js = @import("../js/js.zig");
const builtin = @import("builtin");

const log = @import("../../log.zig");
const Page = @import("../Page.zig");
const Console = @import("Console.zig");
const History = @import("History.zig");
const Navigation = @import("navigation/Navigation.zig");
const Crypto = @import("Crypto.zig");
const CSS = @import("CSS.zig");
const Navigator = @import("Navigator.zig");
const Screen = @import("Screen.zig");
const VisualViewport = @import("VisualViewport.zig");
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

const IS_DEBUG = builtin.mode == .Debug;

const Allocator = std.mem.Allocator;

pub fn registerTypes() []const type {
    return &.{ Window, CrossOriginWindow };
}

const Window = @This();

_proto: *EventTarget,
_page: *Page,
_document: *Document,
_css: CSS = .init,
_crypto: Crypto = .init,
_console: Console = .init,
_navigator: Navigator = .init,
_screen: *Screen,
_visual_viewport: *VisualViewport,
_performance: Performance,
_storage_bucket: storage.Bucket = .{},
_on_load: ?js.Function.Global = null,
_on_pageshow: ?js.Function.Global = null,
_on_popstate: ?js.Function.Global = null,
_on_error: ?js.Function.Global = null,
_on_message: ?js.Function.Global = null,
_on_rejection_handled: ?js.Function.Global = null,
_on_unhandled_rejection: ?js.Function.Global = null,
_current_event: ?*Event = null,
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
// A cross origin wrapper for this window
_cross_origin_wrapper: CrossOriginWindow,

pub fn asEventTarget(self: *Window) *EventTarget {
    return self._proto;
}

pub fn getEvent(self: *const Window) ?*Event {
    return self._current_event;
}

pub fn getSelf(self: *Window) *Window {
    return self;
}

pub fn getWindow(self: *Window) *Window {
    return self;
}

pub fn getTop(self: *Window, page: *Page) Access {
    var p = self._page;
    while (p.parent) |parent| {
        p = parent;
    }
    return Access.init(page.window, p.window);
}

pub fn getParent(self: *Window, page: *Page) Access {
    if (self._page.parent) |p| {
        return Access.init(page.window, p.window);
    }
    return .{ .window = self };
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

pub fn getVisualViewport(self: *const Window) *VisualViewport {
    return self._visual_viewport;
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

pub fn getLocalStorage(self: *Window) *storage.Lookup {
    return &self._storage_bucket.local;
}

pub fn getSessionStorage(self: *Window) *storage.Lookup {
    return &self._storage_bucket.session;
}

pub fn getOrigin(self: *const Window) []const u8 {
    return self._page.origin orelse "null";
}

pub fn getLocation(self: *const Window) *Location {
    return self._location;
}

pub fn getSelection(self: *const Window) *Selection {
    return &self._document._selection;
}

pub fn setLocation(self: *Window, url: [:0]const u8, page: *Page) !void {
    return page.scheduleNavigation(url, .{ .reason = .script, .kind = .{ .push = null } }, .{ .script = self._page });
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

pub fn getOnMessage(self: *const Window) ?js.Function.Global {
    return self._on_message;
}

pub fn setOnMessage(self: *Window, setter: ?FunctionSetter) void {
    self._on_message = getFunctionFromSetter(setter);
}

pub fn getOnRejectionHandled(self: *const Window) ?js.Function.Global {
    return self._on_rejection_handled;
}

pub fn setOnRejectionHandled(self: *Window, setter: ?FunctionSetter) void {
    self._on_rejection_handled = getFunctionFromSetter(setter);
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
    var sc = self._timers.fetchRemove(id) orelse return;
    sc.value.removed = true;
}

pub fn clearInterval(self: *Window, id: u32) void {
    var sc = self._timers.fetchRemove(id) orelse return;
    sc.value.removed = true;
}

pub fn clearImmediate(self: *Window, id: u32) void {
    var sc = self._timers.fetchRemove(id) orelse return;
    sc.value.removed = true;
}

pub fn cancelAnimationFrame(self: *Window, id: u32) void {
    var sc = self._timers.fetchRemove(id) orelse return;
    sc.value.removed = true;
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
    var sc = self._timers.fetchRemove(id) orelse return;
    sc.value.removed = true;
}

pub fn reportError(self: *Window, err: js.Value, page: *Page) !void {
    const error_event = try ErrorEvent.initTrusted(comptime .wrap("error"), .{
        .@"error" = try err.temp(),
        .message = err.toStringSlice() catch "Unknown error",
        .bubbles = false,
        .cancelable = true,
    }, page._session);

    // Invoke window.onerror callback if set (per WHATWG spec, this is called
    // with 5 arguments: message, source, lineno, colno, error)
    // If it returns true, the event is cancelled.
    var prevent_default = false;
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
            prevent_default = r.isTrue();
        }
    }

    const event = error_event.asEvent();
    event._prevent_default = prevent_default;
    // Pass null as handler: onerror was already called above with 5 args.
    // We still dispatch so that addEventListener('error', ...) listeners fire.
    try page._event_manager.dispatchDirect(self.asEventTarget(), event, null, .{
        .context = "window.reportError",
    });

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

pub fn postMessage(self: *Window, message: js.Value.Temp, target_origin: ?[]const u8, page: *Page) !void {
    // For now, we ignore targetOrigin checking and just dispatch the message
    // In a full implementation, we would validate the origin
    _ = target_origin;

    // self = the window that will get the message
    // page = the context calling postMessage
    const target_page = self._page;
    const source_window = target_page.js.getIncumbent().window;

    const arena = try target_page.getArena(.medium, "Window.postMessage");
    errdefer target_page.releaseArena(arena);

    // Origin should be the source window's origin (where the message came from)
    const origin = try source_window._location.getOrigin(&page.js.execution);
    const callback = try arena.create(PostMessageCallback);
    callback.* = .{
        .arena = arena,
        .message = message,
        .page = target_page,
        .source = source_window,
        .origin = try arena.dupe(u8, origin),
    };

    try target_page.js.scheduler.add(callback, PostMessageCallback.run, 0, .{
        .name = "postMessage",
        .low_priority = false,
        .finalizer = PostMessageCallback.cancelled,
    });
}

pub fn btoa(_: *const Window, input: []const u8, page: *Page) ![]const u8 {
    return @import("encoding/base64.zig").encode(page.call_arena, input);
}

pub fn atob(_: *const Window, input: []const u8, page: *Page) ![]const u8 {
    return @import("encoding/base64.zig").decode(page.call_arena, input);
}

pub fn structuredClone(_: *const Window, value: js.Value) !js.Value {
    return value.structuredClone();
}

pub fn getFrame(self: *Window, idx: usize) !?*Window {
    const page = self._page;
    const frames = page.frames.items;
    if (idx >= frames.len) {
        return null;
    }

    if (page.frames_sorted == false) {
        std.mem.sort(*Page, frames, {}, struct {
            fn lessThan(_: void, a: *Page, b: *Page) bool {
                const iframe_a = a.iframe orelse return false;
                const iframe_b = b.iframe orelse return true;

                const pos = iframe_a.asNode().compareDocumentPosition(iframe_b.asNode());
                // Return true if a precedes b (a should come before b in sorted order)
                return (pos & 0x04) != 0; // FOLLOWING bit: b follows a
            }
        }.lessThan);
        page.frames_sorted = true;
    }
    return frames[idx].window;
}

pub fn getFramesLength(self: *const Window) u32 {
    return @intCast(self._page.frames.items.len);
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
    try page.js.scheduler.add(
        page,
        struct {
            fn dispatch(_page: *anyopaque) anyerror!?u32 {
                const p: *Page = @ptrCast(@alignCast(_page));
                const pos = &p.window._scroll_pos;
                // If the state isn't scroll, we can ignore safely to throttle
                // the events.
                if (pos.state != .scroll) {
                    return null;
                }

                const event = try Event.initTrusted(comptime .wrap("scroll"), .{ .bubbles = true }, p);
                try p._event_manager.dispatch(p.document.asEventTarget(), event);

                pos.state = .end;

                return null;
            }
        }.dispatch,
        10,
        .{ .low_priority = true },
    );
    // We dispatch scrollend event asynchronously after 20ms.
    try page.js.scheduler.add(
        page,
        struct {
            fn dispatch(_page: *anyopaque) anyerror!?u32 {
                const p: *Page = @ptrCast(@alignCast(_page));
                const pos = &p.window._scroll_pos;
                // Dispatch only if the state is .end.
                // If a scroll is pending, retry in 10ms.
                // If the state is .end, the event has been dispatched, so
                // ignore safely.
                switch (pos.state) {
                    .scroll => return 10,
                    .end => {},
                    .done => return null,
                }
                const event = try Event.initTrusted(comptime .wrap("scrollend"), .{ .bubbles = true }, p);
                try p._event_manager.dispatch(p.document.asEventTarget(), event);

                pos.state = .done;

                return null;
            }
        }.dispatch,
        20,
        .{ .low_priority = true },
    );
}

pub fn scrollBy(self: *Window, opts: ScrollToOpts, y: ?i32, page: *Page) !void {
    // The scroll is relative to the current position. So compute to new
    // absolute position.
    var absx: i32 = undefined;
    var absy: i32 = undefined;
    switch (opts) {
        .x => |x| {
            absx = @as(i32, @intCast(self._scroll_pos.x)) + x;
            absy = @as(i32, @intCast(self._scroll_pos.y)) + (y orelse 0);
        },
        .opts => |o| {
            absx = @as(i32, @intCast(self._scroll_pos.x)) + o.left;
            absy = @as(i32, @intCast(self._scroll_pos.y)) + o.top;
        },
    }
    return self.scrollTo(.{ .x = absx }, absy, page);
}

// only exposed when the binary is built with the -Dwpt_extensions flag
pub fn getWebDriver(_: *const Window) @import("WebDriver.zig") {
    return .{};
}

pub fn unhandledPromiseRejection(self: *Window, no_handler: bool, rejection: js.PromiseRejection, page: *Page) !void {
    if (comptime IS_DEBUG) {
        log.debug(.js, "unhandled rejection", .{
            .target = "window",
            .value = rejection.reason(),
            .stack = rejection.local.stackTrace() catch |err| @errorName(err) orelse "???",
        });
    }

    const event_name, const attribute_callback = blk: {
        if (no_handler) {
            break :blk .{ "unhandledrejection", self._on_unhandled_rejection };
        }
        break :blk .{ "rejectionhandled", self._on_rejection_handled };
    };

    const target = self.asEventTarget();
    if (page._event_manager.hasDirectListeners(target, event_name, attribute_callback)) {
        const event = (try @import("event/PromiseRejectionEvent.zig").init(event_name, .{
            .reason = if (rejection.reason()) |r| try r.temp() else null,
            .promise = try rejection.promise().temp(),
        }, page._session)).asEvent();
        try page._event_manager.dispatchDirect(target, event, attribute_callback, .{ .context = "window.unhandledrejection" });
    }
}

pub const Access = union(enum) {
    window: *Window,
    cross_origin: *CrossOriginWindow,

    pub fn init(callee: *Window, accessing: *Window) Access {
        if (callee == accessing) {
            // common enough that it's worth the check
            return .{ .window = accessing };
        }

        if (callee._page.js.origin == accessing._page.js.origin) {
            // two different windows, but same origin, return the full window
            return .{ .window = accessing };
        }

        return .{ .cross_origin = &accessing._cross_origin_wrapper };
    }
};

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

    const arena = try page.getArena(.tiny, "Window.schedule");
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

    try page.js.scheduler.add(callback, ScheduleCallback.run, delay_ms, .{
        .name = opts.name,
        .low_priority = opts.low_priority,
        .finalizer = ScheduleCallback.cancelled,
    });

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

    fn cancelled(ctx: *anyopaque) void {
        var self: *ScheduleCallback = @ptrCast(@alignCast(ctx));
        self.deinit();
    }

    fn deinit(self: *ScheduleCallback) void {
        self.cb.release();
        for (self.params) |param| {
            param.release();
        }
        self.page.releaseArena(self.arena);
    }

    fn run(ctx: *anyopaque) !?u32 {
        const self: *ScheduleCallback = @ptrCast(@alignCast(ctx));
        const page = self.page;
        const window = page.window;

        if (self.removed) {
            self.deinit();
            return null;
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
            return ms;
        }
        defer self.deinit();
        _ = window._timers.remove(self.timer_id);
        return null;
    }
};

const PostMessageCallback = struct {
    page: *Page,
    source: *Window,
    arena: Allocator,
    origin: []const u8,
    message: js.Value.Temp,

    fn deinit(self: *PostMessageCallback) void {
        self.page.releaseArena(self.arena);
    }

    fn cancelled(ctx: *anyopaque) void {
        const self: *PostMessageCallback = @ptrCast(@alignCast(ctx));
        self.deinit();
    }

    fn run(ctx: *anyopaque) !?u32 {
        const self: *PostMessageCallback = @ptrCast(@alignCast(ctx));
        defer self.deinit();

        const page = self.page;
        const window = page.window;

        const event_target = window.asEventTarget();
        if (page._event_manager.hasDirectListeners(event_target, "message", window._on_message)) {
            const event = (try MessageEvent.initTrusted(comptime .wrap("message"), .{
                .data = .{ .value = self.message },
                .origin = self.origin,
                .source = self.source,
                .bubbles = false,
                .cancelable = false,
            }, page._session)).asEvent();
            try page._event_manager.dispatchDirect(event_target, event, window._on_message, .{ .context = "window.postMessage" });
        }

        return null;
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

    pub const document = bridge.accessor(Window.getDocument, null, .{ .cache = .{ .internal = 1 }, .deletable = false });
    pub const console = bridge.accessor(Window.getConsole, null, .{ .cache = .{ .internal = 2 } });

    pub const top = bridge.accessor(Window.getTop, null, .{});
    pub const self = bridge.accessor(Window.getWindow, null, .{});
    pub const window = bridge.accessor(Window.getWindow, null, .{});
    pub const parent = bridge.accessor(Window.getParent, null, .{});
    pub const navigator = bridge.accessor(Window.getNavigator, null, .{});
    pub const screen = bridge.accessor(Window.getScreen, null, .{});
    pub const visualViewport = bridge.accessor(Window.getVisualViewport, null, .{});
    pub const performance = bridge.accessor(Window.getPerformance, null, .{});
    pub const localStorage = bridge.accessor(Window.getLocalStorage, null, .{});
    pub const sessionStorage = bridge.accessor(Window.getSessionStorage, null, .{});
    pub const origin = bridge.accessor(Window.getOrigin, null, .{});
    pub const location = bridge.accessor(Window.getLocation, Window.setLocation, .{ .deletable = false });
    pub const history = bridge.accessor(Window.getHistory, null, .{});
    pub const navigation = bridge.accessor(Window.getNavigation, null, .{});
    pub const crypto = bridge.accessor(Window.getCrypto, null, .{});
    pub const CSS = bridge.accessor(Window.getCSS, null, .{});
    pub const customElements = bridge.accessor(Window.getCustomElements, null, .{});
    pub const onload = bridge.accessor(Window.getOnLoad, Window.setOnLoad, .{});
    pub const onpageshow = bridge.accessor(Window.getOnPageShow, Window.setOnPageShow, .{});
    pub const onpopstate = bridge.accessor(Window.getOnPopState, Window.setOnPopState, .{});
    pub const onerror = bridge.accessor(Window.getOnError, Window.setOnError, .{});
    pub const onmessage = bridge.accessor(Window.getOnMessage, Window.setOnMessage, .{});
    pub const onrejectionhandled = bridge.accessor(Window.getOnRejectionHandled, Window.setOnRejectionHandled, .{});
    pub const onunhandledrejection = bridge.accessor(Window.getOnUnhandledRejection, Window.setOnUnhandledRejection, .{});
    pub const event = bridge.accessor(Window.getEvent, null, .{ .null_as_undefined = true });
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
    pub const atob = bridge.function(Window.atob, .{ .dom_exception = true });
    pub const reportError = bridge.function(Window.reportError, .{});
    pub const structuredClone = bridge.function(Window.structuredClone, .{});
    pub const getComputedStyle = bridge.function(Window.getComputedStyle, .{});
    pub const getSelection = bridge.function(Window.getSelection, .{});

    pub const frames = bridge.accessor(Window.getWindow, null, .{});
    pub const index = bridge.indexed(Window.getFrame, null, .{ .null_as_undefined = true });
    pub const length = bridge.accessor(Window.getFramesLength, null, .{});
    pub const scrollX = bridge.accessor(Window.getScrollX, null, .{});
    pub const scrollY = bridge.accessor(Window.getScrollY, null, .{});
    pub const pageXOffset = bridge.accessor(Window.getScrollX, null, .{});
    pub const pageYOffset = bridge.accessor(Window.getScrollY, null, .{});
    pub const scrollTo = bridge.function(Window.scrollTo, .{});
    pub const scroll = bridge.function(Window.scrollTo, .{});
    pub const scrollBy = bridge.function(Window.scrollBy, .{});

    // Return false since we don't have secure-context-only APIs implemented
    // (webcam, geolocation, clipboard, etc.)
    // This is safer and could help avoid processing errors by hinting at
    // sites not to try to access those features
    pub const isSecureContext = bridge.property(false, .{ .template = false });

    pub const innerWidth = bridge.property(1920, .{ .template = false });
    pub const innerHeight = bridge.property(1080, .{ .template = false });
    pub const devicePixelRatio = bridge.property(1, .{ .template = false });

    // This should return a window-like object in specific conditions. Would be
    // pretty complicated to properly support I think.
    pub const opener = bridge.property(null, .{ .template = false });

    pub const alert = bridge.function(struct {
        fn alert(_: *const Window, message: ?[]const u8, page: *Page) void {
            page._session.notification.dispatch(.javascript_dialog_opening, &.{
                .url = page.url,
                .message = message orelse "",
                .dialog_type = "alert",
            });
        }
    }.alert, .{});
    pub const confirm = bridge.function(struct {
        fn confirm(_: *const Window, message: ?[]const u8, page: *Page) bool {
            page._session.notification.dispatch(.javascript_dialog_opening, &.{
                .url = page.url,
                .message = message orelse "",
                .dialog_type = "confirm",
            });
            return false;
        }
    }.confirm, .{});
    pub const prompt = bridge.function(struct {
        fn prompt(_: *const Window, message: ?[]const u8, _: ?[]const u8, page: *Page) ?[]const u8 {
            page._session.notification.dispatch(.javascript_dialog_opening, &.{
                .url = page.url,
                .message = message orelse "",
                .dialog_type = "prompt",
            });
            return null;
        }
    }.prompt, .{});

    pub const webdriver = bridge.accessor(Window.getWebDriver, null, .{ .wpt_only = true });
};

const CrossOriginWindow = struct {
    window: *Window,

    pub fn postMessage(self: *CrossOriginWindow, message: js.Value.Temp, target_origin: ?[]const u8, page: *Page) !void {
        return self.window.postMessage(message, target_origin, page);
    }

    pub fn getTop(self: *CrossOriginWindow, page: *Page) Access {
        return self.window.getParent(page);
    }

    pub fn getParent(self: *CrossOriginWindow, page: *Page) Access {
        return self.window.getParent(page);
    }

    pub fn getFramesLength(self: *const CrossOriginWindow) u32 {
        return self.window.getFramesLength();
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(CrossOriginWindow);

        pub const Meta = struct {
            pub const name = "CrossOriginWindow";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const postMessage = bridge.function(CrossOriginWindow.postMessage, .{});
        pub const top = bridge.accessor(CrossOriginWindow.getTop, null, .{});
        pub const parent = bridge.accessor(CrossOriginWindow.getParent, null, .{});
        pub const length = bridge.accessor(CrossOriginWindow.getFramesLength, null, .{});
    };
};

const testing = @import("../../testing.zig");
test "WebApi: Window" {
    try testing.htmlRunner("window", .{});
}

test "WebApi: Window scroll" {
    try testing.htmlRunner("window_scroll.html", .{});
}

test "WebApi: Window.onerror" {
    try testing.htmlRunner("event/report_error.html", .{});
}
