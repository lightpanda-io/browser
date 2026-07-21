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
const lp = @import("lightpanda");
const builtin = @import("builtin");

const js = @import("../js/js.zig");
const URL = @import("../URL.zig");
const Frame = @import("../Frame.zig");
const Console = @import("Console.zig");
const History = @import("History.zig");
const Navigation = @import("navigation/Navigation.zig");
const Crypto = @import("Crypto.zig");
const CSS = @import("CSS.zig");
const Navigator = @import("Navigator.zig");
const ModelContext = @import("ModelContext.zig");
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
const MessagePort = @import("MessagePort.zig");
const MediaQueryList = @import("css/MediaQueryList.zig");
const storage = @import("storage/storage.zig");
const idb = @import("storage/idb/idb.zig");
const CookieStore = @import("storage/CookieStore.zig");
const Element = @import("Element.zig");
const CSSStyleProperties = @import("css/CSSStyleProperties.zig");
const CustomElementRegistry = @import("CustomElementRegistry.zig");
const Selection = @import("Selection.zig");
const Timers = @import("Timers.zig");
const Notification = @import("../../Notification.zig");

const log = lp.log;
const IS_DEBUG = builtin.mode == .Debug;

const Allocator = std.mem.Allocator;
const Execution = js.Execution;

pub fn registerTypes() []const type {
    return &.{ Window, CrossOriginWindow };
}

const Window = @This();

_proto: *EventTarget,
_frame: *Frame,
_document: *Document,
_css: CSS = .init,
_crypto: Crypto = .init,
_console: Console = .init,
_navigator: Navigator = .init,
_model_context: ModelContext = .init,
_screen: *Screen,
_visual_viewport: *VisualViewport,
_performance: Performance,
_cookie_store: ?*CookieStore = null,
_idb_factory: ?*idb.IDBFactory = null,
_on_load: ?js.Function.Global = null,
_on_pageshow: ?js.Function.Global = null,
_on_popstate: ?js.Function.Global = null,
_on_hashchange: ?js.Function.Global = null,
_on_error: ?js.Function.Global = null,
_on_blur: ?js.Function.Global = null,
_on_focus: ?js.Function.Global = null,
_on_resize: ?js.Function.Global = null,
_on_scroll: ?js.Function.Global = null,
_on_message: ?js.Function.Global = null,
_on_rejection_handled: ?js.Function.Global = null,
_on_unhandled_rejection: ?js.Function.Global = null,
_reporting_error: bool = false,
_current_event: ?*Event = null,
_location: *Location,
_timers: Timers = .{},
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

// The Window that called window.open to create this one. Null for the root
// window, for noopener popups, and cleared if the opener is torn down while
// we're still alive. Only valid if `!_opener.?._closed`.
_opener: ?*Window = null,

// True after window.close. The Frame itself stays alive (parked in
// page.closed_frames until Page.deinit) so cached references to this Window
// don't dangle, but the popup is neutered: dropped from page.popups, its
// transfers aborted, scheduler reset, and unreachable for events / name lookup.
_closed: bool = false,

// Popup name (owned by page.arena)
_name: []const u8 = "",

pub fn asEventTarget(self: *Window) *EventTarget {
    return self._proto;
}

pub fn getEvent(self: *const Window) ?*Event {
    return self._current_event;
}

pub fn setEvent(self: *Window, value: js.Value) void {
    self.replaceGlobalProperty(value, "event");
}

pub fn getSelf(self: *Window) *Window {
    return self;
}

pub fn getWindow(self: *Window) *Window {
    return self;
}

pub fn getOpener(self: *Window, frame: *Frame) ?Access {
    const opener = self._opener orelse return null;
    if (opener._closed) return null;
    return Access.init(frame.window, opener);
}

// Per the HTML spec's opener setter: null disowns the opener (the accessor
// stays in place and the getter now returns null); any other value redefines
// the property as an own data property, like [Replaceable].
pub fn setOpener(self: *Window, value: js.Value) void {
    if (value.isNull()) {
        self._opener = null;
        return;
    }
    self.replaceGlobalProperty(value, "opener");
}

pub fn getClosed(self: *const Window) bool {
    return self._closed;
}

pub fn getName(self: *const Window) []const u8 {
    return self._name;
}

pub fn setName(self: *Window, name: []const u8, frame: *Frame) !void {
    // Store in the Page's frame arena so the slice outlives any call_arena.
    self._name = try frame.arena.dupe(u8, name);
}

pub fn getTop(self: *Window, frame: *Frame) Access {
    var p = self._frame;
    while (p.parent) |parent| {
        p = parent;
    }
    return Access.init(frame.window, p.window);
}

pub fn getParent(self: *Window, frame: *Frame) Access {
    if (self._frame.parent) |p| {
        return Access.init(frame.window, p.window);
    }
    return .{ .window = self };
}

pub fn getDocument(self: *Window) *Document {
    return self._document;
}

pub fn getConsole(self: *Window) *Console {
    return &self._console;
}

pub fn setConsole(self: *Window, value: js.Value) void {
    self.replaceGlobalProperty(value, "console");
}

pub fn setSelf(self: *Window, value: js.Value) void {
    self.replaceGlobalProperty(value, "self");
}

pub fn setFrames(self: *Window, value: js.Value) void {
    self.replaceGlobalProperty(value, "frames");
}

pub fn setParent(self: *Window, value: js.Value) void {
    self.replaceGlobalProperty(value, "parent");
}

pub fn setLength(self: *Window, value: js.Value) void {
    self.replaceGlobalProperty(value, "length");
}

pub fn setInnerWidth(self: *Window, value: js.Value) void {
    self.replaceGlobalProperty(value, "innerWidth");
}

pub fn setInnerHeight(self: *Window, value: js.Value) void {
    self.replaceGlobalProperty(value, "innerHeight");
}

pub fn setScrollX(self: *Window, value: js.Value) void {
    self.replaceGlobalProperty(value, "scrollX");
}

pub fn setScrollY(self: *Window, value: js.Value) void {
    self.replaceGlobalProperty(value, "scrollY");
}

pub fn setPageXOffset(self: *Window, value: js.Value) void {
    self.replaceGlobalProperty(value, "pageXOffset");
}

pub fn setPageYOffset(self: *Window, value: js.Value) void {
    self.replaceGlobalProperty(value, "pageYOffset");
}

pub fn getNavigator(self: *Window) *Navigator {
    return &self._navigator;
}

pub fn getModelContext(self: *Window) *ModelContext {
    return &self._model_context;
}

pub fn getScreen(self: *Window) *Screen {
    return self._screen;
}

pub fn setScreen(self: *Window, value: js.Value) void {
    self.replaceGlobalProperty(value, "screen");
}

pub fn getVisualViewport(self: *const Window) *VisualViewport {
    return self._visual_viewport;
}

pub fn setVisualViewport(self: *Window, value: js.Value) void {
    self.replaceGlobalProperty(value, "visualViewport");
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

pub fn setPerformance(self: *Window, value: js.Value) void {
    self.replaceGlobalProperty(value, "performance");
}

fn bucketForOrigin(self: *Window) *storage.Bucket {
    return self._frame._session.storage_shed.getOrPut(
        self._frame._session.browser.app.allocator,
        self._frame.js.origin.key,
    ) catch @panic("OOM");
}

pub fn getLocalStorage(self: *Window) *storage.Lookup {
    return &self.bucketForOrigin().local;
}

pub fn getSessionStorage(self: *Window) *storage.Lookup {
    return &self.bucketForOrigin().session;
}

pub fn getCookieStore(self: *Window, exec: *Execution) !*CookieStore {
    if (self._cookie_store) |cs| return cs;
    const cs = try exec._factory.eventTarget(CookieStore{ ._proto = undefined });
    try cs.attach(exec);
    self._cookie_store = cs;
    return cs;
}

pub fn getIndexedDB(self: *Window, exec: *Execution) !*idb.IDBFactory {
    if (self._idb_factory) |f| {
        return f;
    }
    const f = try exec._factory.create(idb.IDBFactory{});
    self._idb_factory = f;
    return f;
}

pub fn getOrigin(self: *const Window) []const u8 {
    return self._frame.origin orelse "null";
}

pub fn setOrigin(self: *Window, value: js.Value) void {
    self.replaceGlobalProperty(value, "origin");
}

pub fn getSelection(self: *const Window) *Selection {
    return &self._document._selection;
}

pub fn getFrameElement(self: *const Window) ?*Element.Html.IFrame {
    return self._frame.iframe;
}

pub fn getLocation(self: *const Window) *Location {
    return self._location;
}

pub fn setLocation(self: *Window, url: [:0]const u8, frame: *Frame) !void {
    return frame.scheduleNavigation(url, .{ .reason = .script, .kind = .{ .push = null } }, .{ .script = self._frame });
}

pub fn getHistory(_: *Window, frame: *Frame) *History {
    return &frame._session.history;
}

pub fn getNavigation(_: *Window, frame: *Frame) *Navigation {
    return &frame._session.navigation;
}

pub fn setNavigation(self: *Window, value: js.Value) void {
    self.replaceGlobalProperty(value, "navigation");
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

pub fn getOnHashChange(self: *const Window) ?js.Function.Global {
    return self._on_hashchange;
}

pub fn setOnHashChange(self: *Window, setter: ?FunctionSetter) void {
    self._on_hashchange = getFunctionFromSetter(setter);
}

pub fn getOnError(self: *const Window) ?js.Function.Global {
    return self._on_error;
}

pub fn setOnError(self: *Window, setter: ?FunctionSetter) void {
    self._on_error = getFunctionFromSetter(setter);
}

pub fn getOnBlur(self: *const Window) ?js.Function.Global {
    return self._on_blur;
}

pub fn setOnBlur(self: *Window, setter: ?FunctionSetter) void {
    self._on_blur = getFunctionFromSetter(setter);
}

pub fn getOnFocus(self: *const Window) ?js.Function.Global {
    return self._on_focus;
}

pub fn setOnFocus(self: *Window, setter: ?FunctionSetter) void {
    self._on_focus = getFunctionFromSetter(setter);
}

pub fn getOnResize(self: *const Window) ?js.Function.Global {
    return self._on_resize;
}

pub fn setOnResize(self: *Window, setter: ?FunctionSetter) void {
    self._on_resize = getFunctionFromSetter(setter);
}

pub fn getOnScroll(self: *const Window) ?js.Function.Global {
    return self._on_scroll;
}

pub fn setOnScroll(self: *Window, setter: ?FunctionSetter) void {
    self._on_scroll = getFunctionFromSetter(setter);
}

// Stored in the frame's attribute-listener map (like element and ShadowRoot
// property handlers), which the dispatch propagation path consults for any
// event target.
pub fn getOnClick(self: *Window) ?js.Function.Global {
    return self._frame._event_target_attr_listeners.get(.{ .target = self.asEventTarget(), .handler = .onclick });
}

pub fn setOnClick(self: *Window, setter: ?FunctionSetter) !void {
    if (getFunctionFromSetter(setter)) |cb| {
        try self._frame._event_target_attr_listeners.put(self._frame.arena, .{ .target = self.asEventTarget(), .handler = .onclick }, cb);
    } else {
        _ = self._frame._event_target_attr_listeners.remove(.{ .target = self.asEventTarget(), .handler = .onclick });
    }
}

// The "window-reflecting body element event handler set" (HTML spec): these
// event handlers of body and frameset elements are aliases for the Window's.
// Returns the Window storage slot for the given content attribute name, or
// null if the attribute isn't part of the set.
fn windowReflectingHandler(self: *Window, name: lp.String) ?*?js.Function.Global {
    if (name.eql(comptime .wrap("onblur"))) return &self._on_blur;
    if (name.eql(comptime .wrap("onerror"))) return &self._on_error;
    if (name.eql(comptime .wrap("onfocus"))) return &self._on_focus;
    if (name.eql(comptime .wrap("onload"))) return &self._on_load;
    if (name.eql(comptime .wrap("onresize"))) return &self._on_resize;
    if (name.eql(comptime .wrap("onscroll"))) return &self._on_scroll;
    return null;
}

// Applies a window-reflecting content attribute (set on a body or frameset
// element) to the Window's event handler. A null value clears the handler.
pub fn setWindowReflectingHandlerFromAttribute(self: *Window, name: lp.String, value: ?[]const u8, frame: *Frame) void {
    const slot = self.windowReflectingHandler(name) orelse return;
    const expr = value orelse {
        slot.* = null;
        return;
    };
    if (frame.js.stringToPersistedFunction(expr, &.{"event"}, &.{})) |func| {
        slot.* = func;
    } else |err| {
        log.err(.js, "window reflecting handler", .{ .err = err, .str = expr });
        slot.* = null;
    }
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

pub fn fetch(_: *const Window, input: Fetch.Input, options: ?Fetch.InitOpts, exec: *const js.Execution) !js.Promise {
    return Fetch.init(input, options, exec);
}

pub fn setTimeout(self: *Window, handler: Timers.LegacyHandler, delay_ms: ?u32, params: []js.Value.Global, exec: *js.Execution) !u32 {
    const cb = try handler.resolve(exec);
    return self._timers.schedule(exec, cb, delay_ms orelse 0, .{
        .repeat = false,
        .params = params,
        .name = "window.setTimeout",
    });
}

pub fn setInterval(self: *Window, handler: Timers.LegacyHandler, delay_ms: ?u32, params: []js.Value.Global, exec: *js.Execution) !u32 {
    const cb = try handler.resolve(exec);
    return self._timers.schedule(exec, cb, delay_ms orelse 0, .{
        .repeat = true,
        .params = params,
        .name = "window.setInterval",
    });
}

pub fn setImmediate(self: *Window, cb: js.Function.Global, params: []js.Value.Global, exec: *js.Execution) !u32 {
    return self._timers.schedule(exec, cb, 0, .{
        .repeat = false,
        .params = params,
        .name = "window.setImmediate",
    });
}

pub fn requestAnimationFrame(self: *Window, cb: js.Function.Global, exec: *js.Execution) !u32 {
    return self._timers.schedule(exec, cb, 5, .{
        .repeat = false,
        .params = &.{},
        .mode = .animation_frame,
        .name = "window.requestAnimationFrame",
    });
}

pub fn queueMicrotask(_: *Window, cb: js.Function, frame: *Frame) void {
    frame.js.queueMicrotaskFunc(cb);
}

pub fn clearTimeout(self: *Window, id: u32) void {
    self._timers.clear(id);
}

pub fn clearInterval(self: *Window, id: u32) void {
    self._timers.clear(id);
}

pub fn clearImmediate(self: *Window, id: u32) void {
    self._timers.clear(id);
}

pub fn cancelAnimationFrame(self: *Window, id: u32) void {
    self._timers.clear(id);
}

const RequestIdleCallbackOpts = struct {
    timeout: ?u32 = null,
};
pub fn requestIdleCallback(self: *Window, cb: js.Function.Global, opts_: ?RequestIdleCallbackOpts, exec: *js.Execution) !u32 {
    const opts = opts_ orelse RequestIdleCallbackOpts{};
    return self._timers.schedule(exec, cb, opts.timeout orelse 50, .{
        .mode = .idle,
        .repeat = false,
        .params = &.{},
        .low_priority = true,
        .name = "window.requestIdleCallback",
    });
}

pub fn cancelIdleCallback(self: *Window, id: u32) void {
    self._timers.clear(id);
}

pub fn reportError(self: *Window, err: js.Value, frame: *Frame) !void {
    // Per spec's "in error reporting mode": an exception thrown while an
    // error is being reported (e.g. by an "error" listener) is not reported
    // again, which would otherwise recurse without bound.
    if (self._reporting_error) {
        return;
    }

    const target = self.asEventTarget();
    if (!frame._event_manager.hasDirectListeners(target, "error", self._on_error)) {
        if (comptime builtin.is_test == false) {
            log.warn(.js, "window.reportError", .{
                .message = err.toStringSlice() catch "Unknown error",
            });
        }
        return;
    }

    self._reporting_error = true;
    defer self._reporting_error = false;

    const error_event = try ErrorEvent.initTrusted(comptime .wrap("error"), .{
        .@"error" = try err.persist(),
        .message = err.toStringSlice() catch "Unknown error",
        .bubbles = false,
        .cancelable = true,
    }, frame._page);

    // Invoke window.onerror callback if set (per WHATWG spec, this is called
    // with 5 arguments: message, source, lineno, colno, error)
    // If it returns true, the event is cancelled.
    var prevent_default = false;
    if (self._on_error) |on_error| {
        var ls: js.Local.Scope = undefined;
        frame.js.localScope(&ls);
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
    try frame._event_manager.dispatchDirect(target, event, null, .{
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

pub fn matchMedia(_: *const Window, query: []const u8, frame: *Frame) !*MediaQueryList {
    return frame._factory.eventTarget(MediaQueryList{
        ._proto = undefined,
        ._media = try frame.dupeString(query),
    });
}

pub fn getComputedStyle(_: *const Window, element: *Element, pseudo_element: ?[]const u8, frame: *Frame) !*CSSStyleProperties {
    if (pseudo_element) |pe| {
        if (pe.len != 0) {
            log.warn(.not_implemented, "window.GetComputedStyle", .{ .pseudo_element = pe });
            // Chrome hands out a distinct object per pseudo-element, so these
            // can't share the per-element cache entry.
            return CSSStyleProperties.init(element, true, frame);
        }
    }
    const gop = try frame._element_computed_styles.getOrPut(frame.arena, element);
    if (!gop.found_existing) {
        gop.value_ptr.* = try CSSStyleProperties.init(element, true, frame);
    }
    return gop.value_ptr.*;
}

// window.open(url?, target?, features?) — v1 scope:
//   * Always creates a new popup Frame on the Page (sibling to the root).
//   * Honors `noopener` / `noreferrer` tokens in `features` (opener=null,
//     return value=null). Geometry (width, height, ...) ignored.
//   * `target` values `_self` / `_parent` / `_top` navigate the current frame.
//     Any other value is treated as a popup name; reusing a live name
//     navigates the existing popup instead of spawning a new one.
//   * `url` empty or missing opens about:blank.
pub fn open(self: *Window, url_: ?[]const u8, target_: ?[]const u8, features_: ?[]const u8, frame: *Frame) !?Access {
    const raw_url = url_ orelse "";
    const target = target_ orelse "";
    const features = features_ orelse "";

    const no_opener = hasFeatureToken(features, "noopener") or hasFeatureToken(features, "noreferrer");

    if (raw_url.len > 0) {
        // Per spec, we should validate the url
        _ = URL.resolve(frame.call_arena, frame.base(), raw_url, .{}) catch |err| switch (err) {
            error.OutOfMemory => |e| return e,
            else => return error.SyntaxError,
        };
    }

    // _self / _parent / _top navigate the current browsing context.
    if (std.ascii.eqlIgnoreCase(target, "_self") or
        std.ascii.eqlIgnoreCase(target, "_parent") or
        std.ascii.eqlIgnoreCase(target, "_top"))
    {
        const nav_target = frame.resolveTargetFrame(target) orelse frame;
        const nav_url = if (raw_url.len == 0) "about:blank" else raw_url;
        try frame.scheduleNavigation(nav_url, .{
            .reason = .script,
            .kind = .{ .push = null },
        }, .{ .script = nav_target });

        if (no_opener) {
            return null;
        }

        return Access.init(frame.window, nav_target.window);
    }

    const page = frame._page;

    // Name-based reuse: if a popup with this name already exists, reuse it.
    // `_blank` is reserved and never reuses.
    const is_named = target.len > 0 and !std.ascii.eqlIgnoreCase(target, "_blank");
    if (is_named) {
        if (page.findPopupByName(target)) |existing| {
            if (raw_url.len > 0) {
                try existing.scheduleNavigation(raw_url, .{
                    .reason = .script,
                    .kind = .{ .push = null },
                }, .{ .script = existing });
            }
            if (no_opener) {
                return null;
            }
            return Access.init(frame.window, existing.window);
        }
    }

    // Spawn a new popup Frame as a sibling of the root.
    const popup = try frame.openPopup(.{
        .url = raw_url,
        .name = target,
        .opener = if (no_opener) null else self,
    });

    if (no_opener) {
        return null;
    }
    return Access.init(frame.window, popup.window);
}

pub fn close(self: *Window) void {
    if (self._closed) {
        return;
    }

    // Per spec, close() is only honored on script-opened windows. That
    // maps exactly to membership in page.popups.
    const frame = self._frame;
    const page = frame._page;

    var popup_index: usize = 0;
    while (popup_index < page.popups.items.len) : (popup_index += 1) {
        if (page.popups.items[popup_index] == frame) {
            break;
        }
    } else return;

    self._closed = true;

    // Any live Window holding us as its opener must drop the reference —
    // our Frame is about to go away, and a stale _frame deref on their
    // side would crash.
    for (page.popups.items) |popup| {
        if (popup.window._opener == self) {
            popup.window._opener = null;
        }
    }
    if (page.frame.window._opener == self) {
        page.frame.window._opener = null;
    }

    _ = page.popups.swapRemove(popup_index);

    // Drop any pending queued navigation for this frame.
    if (frame._queued_navigation != null) {
        for (page.queued_navigation.items, 0..) |f, i| {
            if (f == frame) {
                _ = page.queued_navigation.swapRemove(i);
                break;
            }
        }
    }

    page.session.idb.detachContext(frame.js);
    frame.js.scheduler.reset();
    frame.abortTransfers();

    // Do not teardown the frame. The Window can still be referenced in JS
    // (window.open(...) returns the window). It would be nice to be able to
    // free this now (just like it would be nice to be more pro-active about
    // freeing workers and iframes), but, for now, we don't have the
    // infrastructure to do this safely so doing it on page tear down is our
    // only option.
    page.closed_frames.append(page.frame_arena, frame) catch @panic("OOM");
}

pub fn focus(_: *Window) void {}
pub fn blur(_: *Window) void {}

pub fn postMessage(self: *Window, message: js.Value, target_origin: ?[]const u8, transfer: ?[]const *MessagePort, frame: *Frame) !void {
    // For now, we ignore targetOrigin checking and just dispatch the message
    // In a full implementation, we would validate the origin
    _ = target_origin;

    const target_frame = self._frame;
    const source_window = target_frame.js.getIncumbent().window;

    const arena = try target_frame.getArena(.medium, "Window.postMessage");
    errdefer target_frame.releaseArena(arena);

    // StructuredSerialize runs synchronously (per spec): clone the message into
    // the target window's realm now. The receiver gets a fresh, independent copy
    // minted in its own realm (not the source realm's object), an unserializable
    // value throws a DataCloneError to the caller, and the source-realm temp
    // doesn't leak into the destination context. Mirrors Worker.postMessage.
    const cloned = blk: {
        var ls: js.Local.Scope = undefined;
        target_frame.js.localScope(&ls);
        defer ls.deinit();

        // Contain any V8 exception from a failed serialization so it surfaces as
        // a clean DataCloneError; deinit() (no rethrow) clears it.
        var try_catch: js.TryCatch = undefined;
        try_catch.init(&ls.local);
        defer try_catch.deinit();

        const c = message.structuredCloneTo(&ls.local) catch {
            return error.DataClone;
        };
        break :blk try c.persist();
    };
    errdefer cloned.release();

    // Origin should be the source window's origin (where the message came from)
    const origin = try source_window._location.getOrigin(&frame.js.execution);
    const callback = try arena.create(PostMessageCallback);
    callback.* = .{
        .arena = arena,
        .message = cloned,
        .frame = target_frame,
        .source = source_window,
        .origin = try arena.dupe(u8, origin),
        .ports = if (transfer) |t| try arena.dupe(*MessagePort, t) else &.{},
    };

    try target_frame.js.scheduler.add(callback, PostMessageCallback.run, 0, .{
        .name = "postMessage",
        .low_priority = false,
        .finalizer = PostMessageCallback.cancelled,
    });
}

const base64 = @import("encoding/base64.zig");
pub fn btoa(_: *const Window, input: base64.BinInput, frame: *Frame) ![]const u8 {
    return base64.encode(frame.local_arena, input);
}

pub fn atob(_: *const Window, input: base64.BinInput, frame: *Frame) !js.String.OneByte {
    const decoded = try base64.decode(frame.local_arena, input);
    return .{ .bytes = decoded };
}

pub fn structuredClone(_: *const Window, value: js.Value) !js.Value {
    // the serializer already threw (e.g. a DataCloneError); keep it
    return value.structuredClone() catch error.TryCatchRethrow;
}

pub fn getFrame(self: *Window, idx: usize) !?*Window {
    const frame = self._frame;
    const frames = frame.child_frames.items;
    if (idx >= frames.len) {
        return null;
    }

    if (frame.child_frames_sorted == false) {
        std.mem.sort(*Frame, frames, {}, struct {
            fn lessThan(_: void, a: *Frame, b: *Frame) bool {
                const iframe_a = a.iframe orelse return false;
                const iframe_b = b.iframe orelse return true;

                const pos = iframe_a.asNode().compareDocumentPosition(iframe_b.asNode());
                // Return true if a precedes b (a should come before b in sorted order)
                return (pos & 0x04) != 0; // FOLLOWING bit: b follows a
            }
        }.lessThan);
        frame.child_frames_sorted = true;
    }
    return frames[idx].window;
}

pub fn getFramesLength(self: *const Window) u32 {
    return @intCast(self._frame.child_frames.items.len);
}

pub fn getScrollX(self: *const Window) u32 {
    return self._scroll_pos.x;
}

pub fn getScrollY(self: *const Window) u32 {
    return self._scroll_pos.y;
}

pub fn getInnerWidth(_: *const Window, frame: *Frame) u32 {
    return frame._page.getViewport().width;
}

// Faux-layout viewport height, used to decide whether an element is already
// within view (e.g. scrollIntoViewIfNeeded).
pub fn getInnerHeight(_: *const Window, frame: *Frame) u32 {
    return frame._page.getViewport().height;
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
pub fn scrollTo(self: *Window, opts: ScrollToOpts, y: ?i32, frame: *Frame) !void {
    const new_x: u32, const new_y: u32 = switch (opts) {
        .x => |x| .{ @intCast(@max(x, 0)), @intCast(@max(0, y orelse 0)) },
        .opts => |o| .{ @intCast(@max(0, o.left)), @intCast(@max(0, o.top)) },
    };

    if (new_x == self._scroll_pos.x and new_y == self._scroll_pos.y) {
        return;
    }

    self._scroll_pos.x = new_x;
    self._scroll_pos.y = new_y;
    self._scroll_pos.state = .scroll;

    // We dispatch scroll event asynchronously after 10ms. So we can throttle
    // them.
    try frame.js.scheduler.add(
        frame,
        struct {
            fn dispatch(_frame: *anyopaque) anyerror!?u32 {
                const f: *Frame = @ptrCast(@alignCast(_frame));
                const pos = &f.window._scroll_pos;
                // If the state isn't scroll, we can ignore safely to throttle
                // the events.
                if (pos.state != .scroll) {
                    return null;
                }

                const event = try Event.initTrusted(comptime .wrap("scroll"), .{ .bubbles = true }, f._page);
                try f._event_manager.dispatch(f.document.asEventTarget(), event);
                pos.state = .end;

                return null;
            }
        }.dispatch,
        10,
        .{ .low_priority = true },
    );
    // We dispatch scrollend event asynchronously after 20ms.
    try frame.js.scheduler.add(
        frame,
        struct {
            fn dispatch(_frame: *anyopaque) anyerror!?u32 {
                const f: *Frame = @ptrCast(@alignCast(_frame));
                const pos = &f.window._scroll_pos;
                // Dispatch only if the state is .end.
                // If a scroll is pending, retry in 10ms.
                // If the state is .end, the event has been dispatched, so
                // ignore safely.
                switch (pos.state) {
                    .scroll => return 10,
                    .end => {},
                    .done => return null,
                }
                const event = try Event.initTrusted(comptime .wrap("scrollend"), .{ .bubbles = true }, f._page);
                try f._event_manager.dispatch(f.document.asEventTarget(), event);
                pos.state = .done;

                return null;
            }
        }.dispatch,
        20,
        .{ .low_priority = true },
    );
}

pub fn scrollBy(self: *Window, opts: ScrollToOpts, y: ?i32, frame: *Frame) !void {
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
    return self.scrollTo(.{ .x = absx }, absy, frame);
}

// only exposed when the binary is built with the -Dwpt_extensions flag
pub fn getWebDriver(_: *const Window) @import("WebDriver.zig") {
    return .{};
}

pub fn unhandledPromiseRejection(self: *Window, no_handler: bool, rejection: js.PromiseRejection, frame: *Frame) !void {
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
    if (frame._event_manager.hasDirectListeners(target, event_name, attribute_callback)) {
        const event = (try @import("event/PromiseRejectionEvent.zig").init(event_name, .{
            .reason = if (rejection.reason()) |r| try r.persist() else null,
            .promise = try rejection.promise().persist(),
        }, frame._page)).asEvent();
        try frame._event_manager.dispatchDirect(target, event, attribute_callback, .{ .context = "window.unhandledrejection" });
    }
}

// Some properties are readonly but [Replaceable]. They get assigned as own
// data properties on the underlying v8::object that represents the global (the
// Window)
fn replaceGlobalProperty(self: *Window, value: js.Value, comptime name: []const u8) void {
    const global = self._frame.js.globalObject(value.local);
    _ = global.defineOwnProperty(name, value, 0);
}

pub const Access = union(enum) {
    window: *Window,
    cross_origin: *CrossOriginWindow,

    pub fn init(callee: *Window, accessing: *Window) Access {
        if (callee == accessing) {
            // common enough that it's worth the check
            return .{ .window = accessing };
        }

        if (callee._frame.js.origin == accessing._frame.js.origin) {
            // two different windows, but same origin, return the full window
            return .{ .window = accessing };
        }

        return .{ .cross_origin = &accessing._cross_origin_wrapper };
    }
};

const PostMessageCallback = struct {
    frame: *Frame,
    source: *Window,
    arena: Allocator,
    origin: []const u8,
    message: js.Value.Global,
    ports: []const *MessagePort,

    fn deinit(self: *PostMessageCallback) void {
        self.frame.releaseArena(self.arena);
    }

    // Called by the scheduler if the task is dropped before it runs. `run` and
    // `cancelled` are mutually exclusive, so the temp is released exactly once.
    fn cancelled(ctx: *anyopaque) void {
        const self: *PostMessageCallback = @ptrCast(@alignCast(ctx));
        self.message.release();
        self.deinit();
    }

    fn run(ctx: *anyopaque) !?u32 {
        const self: *PostMessageCallback = @ptrCast(@alignCast(ctx));
        defer self.deinit();

        const frame = self.frame;
        const window = frame.window;

        const event_target = window.asEventTarget();

        // The MessageEvent takes ownership of the cloned temp and releases it on
        // teardown; if there are no listeners, release it here so it doesn't leak.
        if (!frame._event_manager.hasDirectListeners(event_target, "message", window._on_message)) {
            self.message.release();
            return null;
        }

        const event = (try MessageEvent.initTrusted(comptime .wrap("message"), .{
            .data = .{ .value = self.message },
            .origin = self.origin,
            .source = .{ .window = self.source },
            .ports = self.ports,
            .bubbles = false,
            .cancelable = false,
        }, frame._page)).asEvent();
        try frame._event_manager.dispatchDirect(event_target, event, window._on_message, .{ .context = "window.postMessage" });

        return null;
    }
};

pub const FunctionSetter = union(enum) {
    func: js.Function.Global,
    anything: js.Value,
};

// window.onload = {}; doesn't fail, but it doesn't do anything.
// seems like setting to null is ok (though, at least on Firefix, it preserves
// the original value, which we could do, but why?)
pub fn getFunctionFromSetter(setter_: ?FunctionSetter) ?js.Function.Global {
    const setter = setter_ orelse return null;
    return switch (setter) {
        .func => |func| func, // Already a Global from bridge auto-conversion
        .anything => null,
    };
}

// Checks whether a window.open features string contains a token, matched
// case-insensitively on whole-token boundaries (comma or whitespace separated).
// The features syntax is legacy and loose; the only tokens we interpret are
// noopener and noreferrer.
fn hasFeatureToken(features: []const u8, token: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, features, " \t\r\n,");
    while (it.next()) |raw| {
        // Trim a trailing =value if present — we only need the key.
        const key = if (std.mem.indexOfScalarPos(u8, raw, 0, '=')) |eq| raw[0..eq] else raw;
        if (std.ascii.eqlIgnoreCase(key, token)) return true;
    }
    return false;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Window);

    pub const Meta = struct {
        pub const name = "Window";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const document = bridge.accessor(Window.getDocument, null, .{ .cache = .{ .internal = 1 }, .deletable = false });
    pub const console = bridge.accessor(Window.getConsole, Window.setConsole, .{});

    pub const top = bridge.accessor(Window.getTop, null, .{});
    pub const self = bridge.accessor(Window.getWindow, Window.setSelf, .{});
    pub const window = bridge.accessor(Window.getWindow, null, .{});
    pub const parent = bridge.accessor(Window.getParent, Window.setParent, .{});
    pub const navigator = bridge.accessor(Window.getNavigator, null, .{});
    pub const screen = bridge.accessor(Window.getScreen, Window.setScreen, .{});
    pub const visualViewport = bridge.accessor(Window.getVisualViewport, Window.setVisualViewport, .{});
    pub const performance = bridge.accessor(Window.getPerformance, Window.setPerformance, .{});
    pub const localStorage = bridge.accessor(Window.getLocalStorage, null, .{});
    pub const sessionStorage = bridge.accessor(Window.getSessionStorage, null, .{});
    pub const cookieStore = bridge.accessor(Window.getCookieStore, null, .{});
    pub const indexedDB = bridge.accessor(Window.getIndexedDB, null, .{});
    pub const origin = bridge.accessor(Window.getOrigin, Window.setOrigin, .{});
    pub const location = bridge.accessor(Window.getLocation, Window.setLocation, .{ .deletable = false });
    pub const history = bridge.accessor(Window.getHistory, null, .{});
    pub const navigation = bridge.accessor(Window.getNavigation, Window.setNavigation, .{});
    pub const crypto = bridge.accessor(Window.getCrypto, null, .{});
    pub const CSS = bridge.accessor(Window.getCSS, null, .{});
    pub const customElements = bridge.accessor(Window.getCustomElements, null, .{});
    pub const onload = bridge.accessor(Window.getOnLoad, Window.setOnLoad, .{});
    pub const onpageshow = bridge.accessor(Window.getOnPageShow, Window.setOnPageShow, .{});
    pub const onpopstate = bridge.accessor(Window.getOnPopState, Window.setOnPopState, .{});
    pub const onhashchange = bridge.accessor(Window.getOnHashChange, Window.setOnHashChange, .{});
    pub const onerror = bridge.accessor(Window.getOnError, Window.setOnError, .{});
    pub const onblur = bridge.accessor(Window.getOnBlur, Window.setOnBlur, .{});
    pub const onfocus = bridge.accessor(Window.getOnFocus, Window.setOnFocus, .{});
    pub const onresize = bridge.accessor(Window.getOnResize, Window.setOnResize, .{});
    pub const onscroll = bridge.accessor(Window.getOnScroll, Window.setOnScroll, .{});
    pub const onclick = bridge.accessor(Window.getOnClick, Window.setOnClick, .{});
    pub const onmessage = bridge.accessor(Window.getOnMessage, Window.setOnMessage, .{});
    pub const onrejectionhandled = bridge.accessor(Window.getOnRejectionHandled, Window.setOnRejectionHandled, .{});
    pub const onunhandledrejection = bridge.accessor(Window.getOnUnhandledRejection, Window.setOnUnhandledRejection, .{});
    pub const event = bridge.accessor(Window.getEvent, Window.setEvent, .{ .null_as_undefined = true });
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
    pub const structuredClone = bridge.function(Window.structuredClone, .{});
    pub const getComputedStyle = bridge.function(Window.getComputedStyle, .{});
    pub const getSelection = bridge.function(Window.getSelection, .{});
    pub const frameElement = bridge.accessor(Window.getFrameElement, null, .{});

    pub const frames = bridge.accessor(Window.getWindow, Window.setFrames, .{});
    pub const index = bridge.indexed(Window.getFrame, null, .{ .null_as_undefined = true });
    pub const length = bridge.accessor(Window.getFramesLength, Window.setLength, .{});
    pub const scrollX = bridge.accessor(Window.getScrollX, Window.setScrollX, .{});
    pub const scrollY = bridge.accessor(Window.getScrollY, Window.setScrollY, .{});
    pub const pageXOffset = bridge.accessor(Window.getScrollX, Window.setPageXOffset, .{});
    pub const pageYOffset = bridge.accessor(Window.getScrollY, Window.setPageYOffset, .{});
    pub const scrollTo = bridge.function(Window.scrollTo, .{});
    pub const scroll = bridge.function(Window.scrollTo, .{});
    pub const scrollBy = bridge.function(Window.scrollBy, .{});

    // Return false since we don't have secure-context-only APIs implemented
    // (webcam, geolocation, clipboard, etc.)
    // This is safer and could help avoid processing errors by hinting at
    // sites not to try to access those features
    pub const isSecureContext = bridge.property(false, .{ .template = false });

    // [Replaceable] (CSSOM-View): the getter reads the page's runtime viewport
    // (overridable via Emulation.setDeviceMetricsOverride); the setter overwrites
    // the attribute rather than throwing.
    pub const innerWidth = bridge.accessor(Window.getInnerWidth, Window.setInnerWidth, .{});
    pub const innerHeight = bridge.accessor(Window.getInnerHeight, Window.setInnerHeight, .{});
    pub const devicePixelRatio = bridge.property(1, .{ .template = false, .readonly = false });

    pub const opener = bridge.accessor(Window.getOpener, Window.setOpener, .{});
    pub const closed = bridge.accessor(Window.getClosed, null, .{});
    pub const name = bridge.accessor(Window.getName, Window.setName, .{});
    pub const open = bridge.function(Window.open, .{});
    pub const close = bridge.function(Window.close, .{});
    pub const focus = bridge.function(Window.focus, .{});
    pub const blur = bridge.function(Window.blur, .{});

    pub const alert = bridge.function(struct {
        fn alert(_: *const Window, message: ?[]const u8, frame: *Frame) void {
            var response: Notification.DialogResponse = .{};
            frame._session.notification.dispatch(.javascript_dialog_opening, &.{
                .url = frame.url,
                .message = message orelse "",
                .dialog_type = "alert",
                .response = &response,
            });
            // Return value is void; we still pop a pre-armed response so the
            // CDP client's pre-arm doesn't leak across to the next dialog.
        }
    }.alert, .{});
    pub const confirm = bridge.function(struct {
        fn confirm(_: *const Window, message: ?[]const u8, frame: *Frame) bool {
            var response: Notification.DialogResponse = .{};
            frame._session.notification.dispatch(.javascript_dialog_opening, &.{
                .url = frame.url,
                .message = message orelse "",
                .dialog_type = "confirm",
                .response = &response,
            });
            return response.accept;
        }
    }.confirm, .{});
    pub const prompt = bridge.function(struct {
        fn prompt(_: *const Window, message: ?[]const u8, default_text: ?[]const u8, frame: *Frame) ?[]const u8 {
            var response: Notification.DialogResponse = .{};
            frame._session.notification.dispatch(.javascript_dialog_opening, &.{
                .url = frame.url,
                .message = message orelse "",
                .dialog_type = "prompt",
                .response = &response,
            });
            if (!response.accept) return null;
            // Pre-armed promptText wins when present. Otherwise fall back to
            // the dialog's defaultText (second arg to window.prompt) — Chrome's
            // accept-without-typing behavior. If both are absent, return ""
            // per CDP spec
            // (https://chromedevtools.github.io/devtools-protocol/tot/Page/#method-handleJavaScriptDialog).
            return response.prompt_text orelse default_text orelse "";
        }
    }.prompt, .{});

    pub const webdriver = bridge.accessor(Window.getWebDriver, null, .{ .wpt_only = true });
};

const CrossOriginWindow = struct {
    window: *Window,

    pub fn postMessage(self: *CrossOriginWindow, message: js.Value, target_origin: ?[]const u8, transfer: ?[]const *MessagePort, frame: *Frame) !void {
        return self.window.postMessage(message, target_origin, transfer, frame);
    }

    pub fn getTop(self: *CrossOriginWindow, frame: *Frame) Access {
        return self.window.getParent(frame);
    }

    pub fn getParent(self: *CrossOriginWindow, frame: *Frame) Access {
        return self.window.getParent(frame);
    }

    pub fn getFramesLength(self: *const CrossOriginWindow) u32 {
        return self.window.getFramesLength();
    }

    pub fn getWindow(self: *CrossOriginWindow, frame: *Frame) Access {
        return Access.init(frame.window, self.window);
    }

    pub fn getOpener(self: *CrossOriginWindow, frame: *Frame) ?Access {
        return self.window.getOpener(frame);
    }

    pub fn getClosed(self: *const CrossOriginWindow) bool {
        return self.window.getClosed();
    }

    pub fn close(self: *CrossOriginWindow) void {
        self.window.close();
    }

    pub fn focus(self: *CrossOriginWindow) void {
        self.window.focus();
    }

    pub fn blur(self: *CrossOriginWindow) void {
        self.window.blur();
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(CrossOriginWindow);

        pub const Meta = struct {
            pub const name = "CrossOriginWindow";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const postMessage = bridge.function(CrossOriginWindow.postMessage, .{});
        pub const close = bridge.function(CrossOriginWindow.close, .{});
        pub const focus = bridge.function(CrossOriginWindow.focus, .{});
        pub const blur = bridge.function(CrossOriginWindow.blur, .{});
        pub const window = bridge.accessor(CrossOriginWindow.getWindow, null, .{});
        pub const self = bridge.accessor(CrossOriginWindow.getWindow, null, .{});
        pub const frames = bridge.accessor(CrossOriginWindow.getWindow, null, .{});
        pub const top = bridge.accessor(CrossOriginWindow.getTop, null, .{});
        pub const parent = bridge.accessor(CrossOriginWindow.getParent, null, .{});
        pub const opener = bridge.accessor(CrossOriginWindow.getOpener, null, .{});
        pub const closed = bridge.accessor(CrossOriginWindow.getClosed, null, .{});
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
