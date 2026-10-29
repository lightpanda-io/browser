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

const Notification = @import("../../Notification.zig");

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
const idb = @import("storage/idb/idb.zig");
const storage = @import("storage/storage.zig");
const CookieStore = @import("storage/CookieStore.zig");
const CacheStorage = @import("cache/CacheStorage.zig");
const Element = @import("Element.zig");
const CSSStyleProperties = @import("css/CSSStyleProperties.zig");
const CustomElementRegistry = @import("CustomElementRegistry.zig");
const Selection = @import("Selection.zig");
const Timers = @import("Timers.zig");
const Scheduler = @import("Scheduler.zig");
const global_event_handlers = @import("global_event_handlers.zig");

const log = lp.log;

const Execution = js.Execution;

pub fn registerTypes() []const type {
    return &.{ Window, CrossOriginWindow };
}

const Window = @This();

pub const Proto = EventTarget;

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
_performance: *Performance,
_cookie_store: ?*CookieStore = null,
_idb_factory: ?*idb.IDBFactory = null,
_caches: ?*CacheStorage = null,
_reporting_error: bool = false,
_current_event: ?*Event = null,
_location: *Location,
_history: History,
_timers: Timers = .{},
_scheduler: Scheduler = .{},
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

fn getEvent(self: *const Window) ?*Event {
    return self._current_event;
}

fn setEvent(self: *Window, value: js.Value) void {
    self.replaceGlobalProperty(value, "event");
}

fn getWindow(self: *Window) *Window {
    return self;
}

fn getOpener(self: *Window, frame: *Frame) ?Access {
    const opener = self._opener orelse return null;
    if (opener._closed) return null;
    return Access.init(frame.window, opener);
}

// Per the HTML spec's opener setter: null disowns the opener (the accessor
// stays in place and the getter now returns null); any other value redefines
// the property as an own data property, like [Replaceable].
fn setOpener(self: *Window, value: js.Value) void {
    if (value.isNull()) {
        self._opener = null;
        return;
    }
    self.replaceGlobalProperty(value, "opener");
}

fn getClosed(self: *const Window) bool {
    return self._closed;
}

pub fn getName(self: *const Window) []const u8 {
    return self._name;
}

pub fn setName(self: *Window, name: []const u8, frame: *Frame) !void {
    // Store in the Page's frame arena so the slice outlives any call_arena.
    self._name = try frame.page_arena.dupe(u8, name);
}

pub fn getTop(self: *Window, frame: *Frame) Access {
    var p = self._frame;
    while (p.parent) |parent| {
        p = parent;
    }
    return Access.init(frame.window, p.window);
}

fn getParent(self: *Window, frame: *Frame) Access {
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

fn setConsole(self: *Window, value: js.Value) void {
    self.replaceGlobalProperty(value, "console");
}

fn setSelf(self: *Window, value: js.Value) void {
    self.replaceGlobalProperty(value, "self");
}

fn setFrames(self: *Window, value: js.Value) void {
    self.replaceGlobalProperty(value, "frames");
}

fn setParent(self: *Window, value: js.Value) void {
    self.replaceGlobalProperty(value, "parent");
}

fn setLength(self: *Window, value: js.Value) void {
    self.replaceGlobalProperty(value, "length");
}

fn setInnerWidth(self: *Window, value: js.Value) void {
    self.replaceGlobalProperty(value, "innerWidth");
}

fn setInnerHeight(self: *Window, value: js.Value) void {
    self.replaceGlobalProperty(value, "innerHeight");
}

fn setDevicePixelRatio(self: *Window, value: js.Value) void {
    self.replaceGlobalProperty(value, "devicePixelRatio");
}

fn setOuterWidth(self: *Window, value: js.Value) void {
    self.replaceGlobalProperty(value, "outerWidth");
}

fn setOuterHeight(self: *Window, value: js.Value) void {
    self.replaceGlobalProperty(value, "outerHeight");
}

fn setScreenX(self: *Window, value: js.Value) void {
    self.replaceGlobalProperty(value, "screenX");
}

fn setScreenY(self: *Window, value: js.Value) void {
    self.replaceGlobalProperty(value, "screenY");
}

fn setScreenLeft(self: *Window, value: js.Value) void {
    self.replaceGlobalProperty(value, "screenLeft");
}

fn setScreenTop(self: *Window, value: js.Value) void {
    self.replaceGlobalProperty(value, "screenTop");
}

fn setScrollX(self: *Window, value: js.Value) void {
    self.replaceGlobalProperty(value, "scrollX");
}

fn setScrollY(self: *Window, value: js.Value) void {
    self.replaceGlobalProperty(value, "scrollY");
}

fn setPageXOffset(self: *Window, value: js.Value) void {
    self.replaceGlobalProperty(value, "pageXOffset");
}

fn setPageYOffset(self: *Window, value: js.Value) void {
    self.replaceGlobalProperty(value, "pageYOffset");
}

fn getNavigator(self: *Window) *Navigator {
    return &self._navigator;
}

fn getScheduler(self: *Window) *Scheduler {
    return &self._scheduler;
}

pub fn getModelContext(self: *Window) *ModelContext {
    return &self._model_context;
}

fn getScreen(self: *Window) *Screen {
    return self._screen;
}

fn setScreen(self: *Window, value: js.Value) void {
    self.replaceGlobalProperty(value, "screen");
}

fn getVisualViewport(self: *const Window) *VisualViewport {
    return self._visual_viewport;
}

fn setVisualViewport(self: *Window, value: js.Value) void {
    self.replaceGlobalProperty(value, "visualViewport");
}

fn getCrypto(self: *Window) *Crypto {
    return &self._crypto;
}

fn getCSS(self: *Window) *CSS {
    return &self._css;
}

fn getPerformance(self: *Window) *Performance {
    return self._performance;
}

fn setPerformance(self: *Window, value: js.Value) void {
    self.replaceGlobalProperty(value, "performance");
}

fn bucketForOrigin(self: *Window) *storage.Bucket {
    return self._frame._session.storage_shed.getOrPut(
        self._frame._session.browser.app.allocator,
        self._frame.js.origin.key,
    ) catch @panic("OOM");
}

fn getLocalStorage(self: *Window) *storage.Lookup {
    return &self.bucketForOrigin().local;
}

fn getSessionStorage(self: *Window) *storage.Lookup {
    return &self.bucketForOrigin().session;
}

fn getCookieStore(self: *Window, exec: *Execution) !*CookieStore {
    if (self._cookie_store) |cs| {
        return cs;
    }

    const cs = try exec._factory.eventTarget(CookieStore{ ._proto = undefined });
    try cs.attach(exec);
    self._cookie_store = cs;
    return cs;
}

fn getIndexedDB(self: *Window, exec: *Execution) !*idb.IDBFactory {
    if (self._idb_factory) |f| {
        return f;
    }
    const f = try exec._factory.create(idb.IDBFactory{});
    self._idb_factory = f;
    return f;
}

fn getCaches(self: *Window, exec: *Execution) !*CacheStorage {
    if (self._caches) |c| {
        return c;
    }
    const c = try exec._factory.create(CacheStorage{});
    self._caches = c;
    return c;
}

pub fn getOrigin(self: *const Window) []const u8 {
    return self._frame.origin orelse "null";
}

pub fn setOrigin(self: *Window, value: js.Value) void {
    self.replaceGlobalProperty(value, "origin");
}

fn getSelection(self: *const Window) *Selection {
    return &self._document._selection;
}

fn getIsSecureContext(self: *const Window) bool {
    return self._frame.isSecureContext();
}

fn getFrameElement(self: *const Window) ?*Element.Html.IFrame {
    return self._frame.iframe;
}

pub fn getLocation(self: *const Window) *Location {
    return self._location;
}

// [PutForwards=href]: window.location = url is location.href = url.
fn setLocation(self: *Window, url: [:0]const u8, frame: *Frame) !void {
    return self._location.assign(url, frame);
}

pub fn getHistory(self: *Window) *History {
    return &self._history;
}

fn getNavigation(_: *Window, frame: *Frame) *Navigation {
    return frame._session.navigationFor(frame);
}

fn setNavigation(self: *Window, value: js.Value) void {
    self.replaceGlobalProperty(value, "navigation");
}

pub fn getCustomElements(self: *Window) *CustomElementRegistry {
    return &self._custom_elements;
}

// The event handlers of body and frameset elements that are aliases for the
// Window's: the "window-reflecting body element event handler set" plus
// WindowEventHandlers (HTML spec, "determining the target of an event handler").
pub fn isWindowReflectingHandler(name: []const u8) bool {
    inline for (.{ "onblur", "onerror", "onfocus", "onload", "onresize", "onscroll" }) |n| {
        if (std.mem.eql(u8, name, n)) {
            return true;
        }
    }
    return global_event_handlers.isWindowEventHandler(name);
}

// Accessor for a window-reflecting event handler (i.e. body or frameset)..
pub fn reflectingHandlerAccessor(comptime T: type, comptime typ: []const u8) js.bridge.Accessor {
    const H = struct {
        fn get(self: *T, frame: *Frame) ?js.Function.Global {
            const owner = self.asElement().ownerFrame(frame) orelse return null;
            return owner._event_manager.getHandler(owner.window.asEventTarget(), typ);
        }

        fn set(self: *T, value: ?EventTarget.HandlerValue, frame: *Frame) !void {
            const owner = self.asElement().ownerFrame(frame) orelse return;
            return owner._event_manager.setHandler(owner.window.asEventTarget(), typ, EventTarget.HandlerValue.function(value));
        }
    };
    return js.Bridge(T).accessor(H.get, H.set, .{});
}

pub fn fetch(_: *const Window, input: Fetch.Input, options: ?Fetch.InitOpts, exec: *const js.Execution) !js.Promise {
    return Fetch.init(input, options, exec);
}

pub fn setTimeout(self: *Window, handler: Timers.LegacyHandler, delay_ms: ?i32, params: js.Variadic(js.Value.Global), exec: *js.Execution) !u32 {
    const cb = try handler.resolve(exec);
    return self._timers.schedule(exec, cb, Timers.delayFromJs(delay_ms), .{
        .repeat = false,
        .params = params.values,
        .name = "window.setTimeout",
    });
}

pub fn setInterval(self: *Window, handler: Timers.LegacyHandler, delay_ms: ?i32, params: js.Variadic(js.Value.Global), exec: *js.Execution) !u32 {
    const cb = try handler.resolve(exec);
    return self._timers.schedule(exec, cb, Timers.delayFromJs(delay_ms), .{
        .repeat = true,
        .params = params.values,
        .name = "window.setInterval",
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

fn queueMicrotask(_: *Window, cb: js.Function, frame: *Frame) void {
    frame.js.queueMicrotaskFunc(cb);
}

fn clearTimeout(self: *Window, id: u32) void {
    self._timers.clear(id);
}

fn clearInterval(self: *Window, id: u32) void {
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
        .blocks_done = false,
        .name = "window.requestIdleCallback",
    });
}

fn cancelIdleCallback(self: *Window, id: u32) void {
    self._timers.clear(id);
}

pub fn reportError(self: *Window, err: js.Value, frame: *Frame) !void {
    // Per spec's "in error reporting mode": an exception thrown while an
    // error is being reported (e.g. by an "error" listener) is not reported
    // again, which would otherwise recurse without bound.
    if (self._reporting_error) {
        return;
    }

    // Reporting calls back into Zig (e.g. a DOMException's message accessor).
    // At call_depth 0 that call resets the call_arena, which the code reporting
    // the error may still be using (e.g. a dispatch's snapshot of its targets).
    const call_depth = frame.js.call_depth;
    frame.js.call_depth = call_depth + 1;
    defer frame.js.call_depth = call_depth;

    frame.page.recordJsError(error.JsException);
    frame.page.status.noteException(err.toStringSlice() catch "");

    const location = err.errorLocation(frame.call_arena) catch js.Value.ErrorLocation{};

    const target = self.asEventTarget();
    if (!frame._event_manager.hasDirectListeners(target, "error")) {
        log.warn(.page_error, "uncaught exception", .{
            .message = err.toStringSlice() catch "Unknown error",
            .url = location.url,
            .line = location.line,
            .column = location.column,
        });
        notifyExceptionThrown(err, location, .exception, frame);
        return;
    }

    self._reporting_error = true;
    defer self._reporting_error = false;

    const error_event = try ErrorEvent.initTrusted(comptime .wrap("error"), .{
        .@"error" = try err.persist(),
        .message = err.toStringSlice() catch "Unknown error",
        .filename = location.url,
        .lineno = location.line,
        .colno = location.column,
        .bubbles = false,
        .cancelable = true,
    }, frame.page);

    const event = error_event.asEvent();
    event.acquireRef();
    defer event.releaseRef(frame.page);

    // window.onerror is called with the event's fields (see Listener.run).
    try frame._event_manager.dispatchDirect(target, event, .{
        .context = "window.reportError",
        .run_microtasks = false,
    });

    if (!event._prevent_default) {
        log.warn(.page_error, "uncaught exception", .{
            .message = error_event._message,
            .url = error_event._filename,
            .line = error_event._line_number,
            .column = error_event._column_number,
        });
        notifyExceptionThrown(err, location, .exception, frame);
    }
}

// An error event (or unhandledrejection event) left uncancelled leaves the
// exception "uncaught": CDP clients learn about it through
// Runtime.exceptionThrown.
pub fn notifyExceptionThrown(err: js.Value, location: js.Value.ErrorLocation, kind: @FieldType(Notification.ExceptionThrown, "kind"), frame: *Frame) void {
    frame._session.notification.dispatch(.exception_thrown, &.{
        .timestamp = lp.datetime.timestamp(.boot),
        .value = err,
        .location = location,
        .kind = kind,
    });
}

pub fn matchMedia(_: *const Window, query: []const u8, frame: *Frame) !*MediaQueryList {
    return MediaQueryList.init(query, frame);
}

pub fn getComputedStyle(_: *const Window, element: *Element, pseudo_element: ?[]const u8, frame: *Frame) !*CSSStyleProperties {
    // :before/:after get their own cache entry and no warning: our answer
    // (the element's own computed style) is a reasonable default for the
    // common probes
    const pseudo = Element.PseudoElement.parse(pseudo_element orelse "");
    const page = frame.page;
    const gop = try page.element_computed_styles.getOrPut(page.arena, .{ .element = element, .pseudo = pseudo });
    if (!gop.found_existing) {
        if (pseudo == .other) {
            log.debug(.not_implemented, "window.GetComputedStyle", .{ .pseudo_element = pseudo_element.? });
        }
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
        const nav_target = switch (frame.resolveTargetFrame(target)) {
            .frame => |f| f,
            .blank => unreachable,
        };
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

    const page = frame.page;

    // Name-based reuse: if a popup with this name already exists, reuse it.
    // `_blank` is reserved and never reuses.
    const is_named = target.len > 0 and !std.ascii.eqlIgnoreCase(target, "_blank");
    if (is_named) {
        if (page.findPopupByName(target)) |existing| {
            if (raw_url.len > 0) {
                try frame.scheduleNavigation(raw_url, .{
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
    if (std.mem.findScalar(*Frame, frame.page.popups.items, frame) == null) {
        return;
    }

    // Do not teardown the frame. The Window can still be referenced in JS
    // (window.open(...) returns the window). It would be nice to be able to
    // free this now (just like it would be nice to be more pro-active about
    // freeing workers), but, for now, we don't have the infrastructure to do
    // this safely so doing it on page tear down is our only option.
    frame.discard() catch @panic("OOM");
}

pub fn focus(_: *Window) void {}
pub fn blur(_: *Window) void {}

pub fn stop(self: *Window) void {
    self._frame.stopLoading();
}

// postMessage(message, targetOrigin, transfer) or postMessage(message, options).
pub fn postMessage(self: *Window, message: js.Value, target_origin_or_options: ?js.Value, transfer: ?js.Value, frame: *Frame) !void {
    // For now, we ignore targetOrigin checking and just dispatch the message
    // In a full implementation, we would validate the origin
    var transfer_arg = transfer;
    if (target_origin_or_options) |arg| {
        if (arg.isObject()) {
            transfer_arg = arg;
        }
    }
    const ports = try MessagePort.transferList(transfer_arg);

    const target_frame = self._frame;
    const source_window = target_frame.js.getIncumbent().window;

    const arena = try target_frame.getArena(.medium, "Window.postMessage");
    errdefer arena.release();

    // Clone the message into the target window's realm now: the receiver gets
    // a fresh copy minted in its own realm, and the transferred ports move
    // there. Mirrors Worker.postMessage.
    const cloned = try MessagePort.cloneMessage(message, ports, &target_frame.js.execution);
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
    };

    try target_frame.js.scheduler.add(callback, PostMessageCallback.run, 0, .{
        .name = "postMessage",
        .finalizer = PostMessageCallback.cancelled,
    });
}

const base64 = @import("encoding/base64.zig");
fn btoa(_: *const Window, input: base64.BinInput, frame: *Frame) ![]const u8 {
    return base64.encode(frame.local_arena, input);
}

fn atob(_: *const Window, input: base64.BinInput, frame: *Frame) !js.String.OneByte {
    const decoded = try base64.decode(frame.local_arena, input);
    return .{ .bytes = decoded };
}

pub fn structuredClone(_: *const Window, value: js.Value) !js.Value {
    // the serializer already threw (e.g. a DataCloneError); keep it
    return value.structuredClone() catch error.TryCatchRethrow;
}

fn getFrame(self: *Window, idx: usize) !?*Window {
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

fn getFramesLength(self: *const Window) u32 {
    return @intCast(self._frame.child_frames.items.len);
}

pub fn getScrollX(self: *const Window) u32 {
    return self._scroll_pos.x;
}

pub fn getScrollY(self: *const Window) u32 {
    return self._scroll_pos.y;
}

fn getInnerWidth(_: *const Window, frame: *Frame) u32 {
    return frame.page.getViewport().width;
}

// Faux-layout viewport height, used to decide whether an element is already
// within view (e.g. scrollIntoViewIfNeeded).
pub fn getInnerHeight(_: *const Window, frame: *Frame) u32 {
    return frame.page.getViewport().height;
}

fn getDevicePixelRatio(_: *const Window, frame: *Frame) f32 {
    return frame.page.getViewport().scale;
}

// There is no window frame around the viewport and no window position on a
// screen, so the outer size is the viewport and the position is 0.
fn getOuterWidth(_: *const Window, frame: *Frame) u32 {
    return frame.page.getViewport().width;
}

fn getOuterHeight(_: *const Window, frame: *Frame) u32 {
    return frame.page.getViewport().height;
}

fn getScreenPosition(_: *const Window) i32 {
    return 0;
}

pub fn scrollTo(self: *Window, opts: Element.ScrollToOpts, y: ?i32, frame: *Frame) !void {
    const o = opts.offsets(y);
    const size = self._frame.document.scrollSize();
    const max_x = scrollLimit(size.width, self.getInnerWidth(self._frame));
    const max_y = scrollLimit(size.height, self.getInnerHeight(self._frame));
    const new_x: u32 = if (o.left) |left| @min(@as(u32, @intCast(@max(0, left))), max_x) else self._scroll_pos.x;
    const new_y: u32 = if (o.top) |top| @min(@as(u32, @intCast(@max(0, top))), max_y) else self._scroll_pos.y;

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

                const event = try Event.initTrusted(comptime .wrap("scroll"), .{ .bubbles = true }, f.page);
                try f._event_manager.dispatch(f.document.asEventTarget(), event);
                pos.state = .end;

                return null;
            }
        }.dispatch,
        10,
        .{ .blocks_done = false },
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
                const event = try Event.initTrusted(comptime .wrap("scrollend"), .{ .bubbles = true }, f.page);
                try f._event_manager.dispatch(f.document.asEventTarget(), event);
                pos.state = .done;

                return null;
            }
        }.dispatch,
        20,
        .{ .blocks_done = false },
    );
}

fn scrollLimit(size: f64, visible: u32) u32 {
    const limit = size - @as(f64, @floatFromInt(visible));
    return @intFromFloat(std.math.clamp(limit, 0, std.math.maxInt(u32)));
}

pub fn scrollBy(self: *Window, opts: Element.ScrollToOpts, y: ?i32, frame: *Frame) !void {
    const o = opts.offsets(y);
    // The viewport has no honest extent, so a stored offset can sit above
    // maxInt(i32): widen before saturating back down.
    const absx: i32 = @intCast(@min(@as(i64, self._scroll_pos.x) + (o.left orelse 0), std.math.maxInt(i32)));
    const absy: i32 = @intCast(@min(@as(i64, self._scroll_pos.y) + (o.top orelse 0), std.math.maxInt(i32)));
    return self.scrollTo(.{ .x = absx }, absy, frame);
}

// only exposed when the binary is built with the -Dwpt_extensions flag
fn getWebDriver(_: *const Window) @import("WebDriver.zig") {
    return .{};
}

// "unhandledrejection" for a promise still rejected without a handler at the
// end of a microtask checkpoint, "rejectionhandled" for one that got a handler
// after that. Env.reportRejectedPromises reports an "unhandledrejection" the
// page doesn't cancel. Returns whether the event was cancelled.
pub fn unhandledPromiseRejection(self: *Window, no_handler: bool, promise: js.Promise, reason: ?js.Value, frame: *Frame) !bool {
    const event_name = if (no_handler) "unhandledrejection" else "rejectionhandled";

    const target = self.asEventTarget();
    if (!frame._event_manager.hasDirectListeners(target, event_name)) {
        return false;
    }

    const event = (try @import("event/PromiseRejectionEvent.zig").init(event_name, .{
        .reason = if (reason) |r| try r.persist() else null,
        .promise = try promise.persist(),
        .cancelable = no_handler,
    }, frame.page)).asEvent();
    // Keep the event alive past dispatch so we can read _prevent_default.
    event.acquireRef();
    defer event.releaseRef(frame.page);

    try frame._event_manager.dispatchDirect(target, event, .{ .context = "window.unhandledrejection" });
    return event._prevent_default;
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
    arena: *lp.Arena,
    origin: []const u8,
    message: MessagePort.Message,

    fn deinit(self: *PostMessageCallback) void {
        self.arena.release();
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
        defer self.message.releasePorts();

        const frame = self.frame;
        const window = frame.window;

        const event_target = window.asEventTarget();

        const data = self.message.data orelse {
            if (frame._event_manager.hasDirectListeners(event_target, "messageerror")) {
                const event = (try MessageEvent.initTrusted(comptime .wrap("messageerror"), .{
                    .origin = self.origin,
                    .source = .{ .window = self.source },
                    .ports = self.message.ports,
                    .bubbles = false,
                    .cancelable = false,
                }, frame.page)).asEvent();
                try frame._event_manager.dispatchDirect(event_target, event, .{ .context = "window.postMessage" });
            }
            return null;
        };

        // The MessageEvent takes ownership of the cloned temp and releases it on
        // teardown; if there are no listeners, release it here so it doesn't leak.
        if (!frame._event_manager.hasDirectListeners(event_target, "message")) {
            data.release();
            return null;
        }

        const event = (try MessageEvent.initTrusted(comptime .wrap("message"), .{
            .data = .{ .value = data },
            .origin = self.origin,
            .source = .{ .window = self.source },
            .ports = self.message.ports,
            .bubbles = false,
            .cancelable = false,
        }, frame.page)).asEvent();
        try frame._event_manager.dispatchDirect(event_target, event, .{ .context = "window.postMessage" });

        return null;
    }
};

// Checks whether a window.open features string contains a token, matched
// case-insensitively on whole-token boundaries (comma or whitespace separated).
// The features syntax is legacy and loose; the only tokens we interpret are
// noopener and noreferrer.
fn hasFeatureToken(features: []const u8, token: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, features, " \t\r\n,");
    while (it.next()) |raw| {
        // Trim a trailing =value if present — we only need the key.
        const key = if (std.mem.findScalarPos(u8, raw, 0, '=')) |eq| raw[0..eq] else raw;
        if (std.ascii.eqlIgnoreCase(key, token)) return true;
    }
    return false;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Window);

    pub const Meta = struct {
        pub const name = "Window";
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const document = bridge.accessor(Window.getDocument, null, .{ .cache = .{ .internal = 1 }, .deletable = false });
    pub const console = bridge.accessor(Window.getConsole, Window.setConsole, .{});

    pub const top = bridge.accessor(Window.getTop, null, .{});
    pub const self = bridge.accessor(Window.getWindow, Window.setSelf, .{});
    pub const window = bridge.accessor(Window.getWindow, null, .{});
    pub const parent = bridge.accessor(Window.getParent, Window.setParent, .{});
    pub const navigator = bridge.accessor(Window.getNavigator, null, .{});
    pub const scheduler = bridge.accessor(Window.getScheduler, null, .{});
    pub const screen = bridge.accessor(Window.getScreen, Window.setScreen, .{});
    pub const visualViewport = bridge.accessor(Window.getVisualViewport, Window.setVisualViewport, .{});
    pub const performance = bridge.accessor(Window.getPerformance, Window.setPerformance, .{});
    pub const localStorage = bridge.accessor(Window.getLocalStorage, null, .{});
    pub const sessionStorage = bridge.accessor(Window.getSessionStorage, null, .{});
    pub const cookieStore = bridge.accessor(Window.getCookieStore, null, .{});
    pub const indexedDB = bridge.accessor(Window.getIndexedDB, null, .{});
    pub const caches = bridge.accessor(Window.getCaches, null, .{});
    pub const origin = bridge.accessor(Window.getOrigin, Window.setOrigin, .{});
    pub const location = bridge.accessor(Window.getLocation, Window.setLocation, .{ .deletable = false });
    pub const history = bridge.accessor(Window.getHistory, null, .{});
    pub const navigation = bridge.accessor(Window.getNavigation, Window.setNavigation, .{});
    pub const crypto = bridge.accessor(Window.getCrypto, null, .{});
    pub const CSS = bridge.accessor(Window.getCSS, null, .{});
    pub const customElements = bridge.accessor(Window.getCustomElements, null, .{});
    pub const onabort = EventTarget.handlerAccessor(Window, "abort");
    pub const onanimationcancel = EventTarget.handlerAccessor(Window, "animationcancel");
    pub const onanimationend = EventTarget.handlerAccessor(Window, "animationend");
    pub const onanimationiteration = EventTarget.handlerAccessor(Window, "animationiteration");
    pub const onanimationstart = EventTarget.handlerAccessor(Window, "animationstart");
    pub const onauxclick = EventTarget.handlerAccessor(Window, "auxclick");
    pub const onbeforeinput = EventTarget.handlerAccessor(Window, "beforeinput");
    pub const onbeforematch = EventTarget.handlerAccessor(Window, "beforematch");
    pub const onbeforetoggle = EventTarget.handlerAccessor(Window, "beforetoggle");
    pub const onblur = EventTarget.handlerAccessor(Window, "blur");
    pub const oncancel = EventTarget.handlerAccessor(Window, "cancel");
    pub const oncanplay = EventTarget.handlerAccessor(Window, "canplay");
    pub const oncanplaythrough = EventTarget.handlerAccessor(Window, "canplaythrough");
    pub const onchange = EventTarget.handlerAccessor(Window, "change");
    pub const onclick = EventTarget.handlerAccessor(Window, "click");
    pub const onclose = EventTarget.handlerAccessor(Window, "close");
    pub const oncommand = EventTarget.handlerAccessor(Window, "command");
    pub const oncontentvisibilityautostatechange = EventTarget.handlerAccessor(Window, "contentvisibilityautostatechange");
    pub const oncontextlost = EventTarget.handlerAccessor(Window, "contextlost");
    pub const oncontextmenu = EventTarget.handlerAccessor(Window, "contextmenu");
    pub const oncontextrestored = EventTarget.handlerAccessor(Window, "contextrestored");
    pub const oncuechange = EventTarget.handlerAccessor(Window, "cuechange");
    pub const ondblclick = EventTarget.handlerAccessor(Window, "dblclick");
    pub const ondrag = EventTarget.handlerAccessor(Window, "drag");
    pub const ondragend = EventTarget.handlerAccessor(Window, "dragend");
    pub const ondragenter = EventTarget.handlerAccessor(Window, "dragenter");
    pub const ondragleave = EventTarget.handlerAccessor(Window, "dragleave");
    pub const ondragover = EventTarget.handlerAccessor(Window, "dragover");
    pub const ondragstart = EventTarget.handlerAccessor(Window, "dragstart");
    pub const ondrop = EventTarget.handlerAccessor(Window, "drop");
    pub const ondurationchange = EventTarget.handlerAccessor(Window, "durationchange");
    pub const onemptied = EventTarget.handlerAccessor(Window, "emptied");
    pub const onended = EventTarget.handlerAccessor(Window, "ended");
    pub const onerror = EventTarget.handlerAccessor(Window, "error");
    pub const onfocus = EventTarget.handlerAccessor(Window, "focus");
    pub const onformdata = EventTarget.handlerAccessor(Window, "formdata");
    pub const ongotpointercapture = EventTarget.handlerAccessor(Window, "gotpointercapture");
    pub const oninput = EventTarget.handlerAccessor(Window, "input");
    pub const oninvalid = EventTarget.handlerAccessor(Window, "invalid");
    pub const onkeydown = EventTarget.handlerAccessor(Window, "keydown");
    pub const onkeypress = EventTarget.handlerAccessor(Window, "keypress");
    pub const onkeyup = EventTarget.handlerAccessor(Window, "keyup");
    pub const onload = EventTarget.handlerAccessor(Window, "load");
    pub const onloadeddata = EventTarget.handlerAccessor(Window, "loadeddata");
    pub const onloadedmetadata = EventTarget.handlerAccessor(Window, "loadedmetadata");
    pub const onloadstart = EventTarget.handlerAccessor(Window, "loadstart");
    pub const onlostpointercapture = EventTarget.handlerAccessor(Window, "lostpointercapture");
    pub const onmousedown = EventTarget.handlerAccessor(Window, "mousedown");
    pub const onmouseenter = EventTarget.handlerAccessor(Window, "mouseenter");
    pub const onmouseleave = EventTarget.handlerAccessor(Window, "mouseleave");
    pub const onmousemove = EventTarget.handlerAccessor(Window, "mousemove");
    pub const onmouseout = EventTarget.handlerAccessor(Window, "mouseout");
    pub const onmouseover = EventTarget.handlerAccessor(Window, "mouseover");
    pub const onmouseup = EventTarget.handlerAccessor(Window, "mouseup");
    pub const onpause = EventTarget.handlerAccessor(Window, "pause");
    pub const onplay = EventTarget.handlerAccessor(Window, "play");
    pub const onplaying = EventTarget.handlerAccessor(Window, "playing");
    pub const onpointercancel = EventTarget.handlerAccessor(Window, "pointercancel");
    pub const onpointerdown = EventTarget.handlerAccessor(Window, "pointerdown");
    pub const onpointerenter = EventTarget.handlerAccessor(Window, "pointerenter");
    pub const onpointerleave = EventTarget.handlerAccessor(Window, "pointerleave");
    pub const onpointermove = EventTarget.handlerAccessor(Window, "pointermove");
    pub const onpointerout = EventTarget.handlerAccessor(Window, "pointerout");
    pub const onpointerover = EventTarget.handlerAccessor(Window, "pointerover");
    pub const onpointerrawupdate = EventTarget.handlerAccessor(Window, "pointerrawupdate");
    pub const onpointerup = EventTarget.handlerAccessor(Window, "pointerup");
    pub const onprogress = EventTarget.handlerAccessor(Window, "progress");
    pub const onratechange = EventTarget.handlerAccessor(Window, "ratechange");
    pub const onreset = EventTarget.handlerAccessor(Window, "reset");
    pub const onresize = EventTarget.handlerAccessor(Window, "resize");
    pub const onscroll = EventTarget.handlerAccessor(Window, "scroll");
    pub const onscrollend = EventTarget.handlerAccessor(Window, "scrollend");
    pub const onsecuritypolicyviolation = EventTarget.handlerAccessor(Window, "securitypolicyviolation");
    pub const onseeked = EventTarget.handlerAccessor(Window, "seeked");
    pub const onseeking = EventTarget.handlerAccessor(Window, "seeking");
    pub const onselect = EventTarget.handlerAccessor(Window, "select");
    pub const onselectionchange = EventTarget.handlerAccessor(Window, "selectionchange");
    pub const onselectstart = EventTarget.handlerAccessor(Window, "selectstart");
    pub const onslotchange = EventTarget.handlerAccessor(Window, "slotchange");
    pub const onstalled = EventTarget.handlerAccessor(Window, "stalled");
    pub const onsubmit = EventTarget.handlerAccessor(Window, "submit");
    pub const onsuspend = EventTarget.handlerAccessor(Window, "suspend");
    pub const ontimeupdate = EventTarget.handlerAccessor(Window, "timeupdate");
    pub const ontoggle = EventTarget.handlerAccessor(Window, "toggle");
    pub const ontransitioncancel = EventTarget.handlerAccessor(Window, "transitioncancel");
    pub const ontransitionend = EventTarget.handlerAccessor(Window, "transitionend");
    pub const ontransitionrun = EventTarget.handlerAccessor(Window, "transitionrun");
    pub const ontransitionstart = EventTarget.handlerAccessor(Window, "transitionstart");
    pub const onvolumechange = EventTarget.handlerAccessor(Window, "volumechange");
    pub const onwaiting = EventTarget.handlerAccessor(Window, "waiting");
    pub const onwheel = EventTarget.handlerAccessor(Window, "wheel");
    pub const onafterprint = EventTarget.handlerAccessor(Window, "afterprint");
    pub const onbeforeprint = EventTarget.handlerAccessor(Window, "beforeprint");
    pub const onbeforeunload = EventTarget.handlerAccessor(Window, "beforeunload");
    pub const onhashchange = EventTarget.handlerAccessor(Window, "hashchange");
    pub const onlanguagechange = EventTarget.handlerAccessor(Window, "languagechange");
    pub const onmessage = EventTarget.handlerAccessor(Window, "message");
    pub const onmessageerror = EventTarget.handlerAccessor(Window, "messageerror");
    pub const onoffline = EventTarget.handlerAccessor(Window, "offline");
    pub const ononline = EventTarget.handlerAccessor(Window, "online");
    pub const onpagehide = EventTarget.handlerAccessor(Window, "pagehide");
    pub const onpagereveal = EventTarget.handlerAccessor(Window, "pagereveal");
    pub const onpageshow = EventTarget.handlerAccessor(Window, "pageshow");
    pub const onpageswap = EventTarget.handlerAccessor(Window, "pageswap");
    pub const onpopstate = EventTarget.handlerAccessor(Window, "popstate");
    pub const onrejectionhandled = EventTarget.handlerAccessor(Window, "rejectionhandled");
    pub const onstorage = EventTarget.handlerAccessor(Window, "storage");
    pub const onunhandledrejection = EventTarget.handlerAccessor(Window, "unhandledrejection");
    pub const onunload = EventTarget.handlerAccessor(Window, "unload");
    pub const event = bridge.accessor(Window.getEvent, Window.setEvent, .{ .null_as_undefined = true });
    pub const fetch = bridge.function(Window.fetch, .{});
    pub const queueMicrotask = bridge.function(Window.queueMicrotask, .{});
    pub const setTimeout = bridge.function(Window.setTimeout, .{});
    pub const clearTimeout = bridge.function(Window.clearTimeout, .{});
    pub const setInterval = bridge.function(Window.setInterval, .{});
    pub const clearInterval = bridge.function(Window.clearInterval, .{});
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

    pub const isSecureContext = bridge.accessor(Window.getIsSecureContext, null, .{});

    // [Replaceable] (CSSOM-View): the getter reads the page's runtime viewport
    // (overridable via Emulation.setDeviceMetricsOverride); the setter overwrites
    // the attribute rather than throwing.
    pub const innerWidth = bridge.accessor(Window.getInnerWidth, Window.setInnerWidth, .{});
    pub const innerHeight = bridge.accessor(Window.getInnerHeight, Window.setInnerHeight, .{});
    pub const devicePixelRatio = bridge.accessor(Window.getDevicePixelRatio, Window.setDevicePixelRatio, .{});
    pub const outerWidth = bridge.accessor(Window.getOuterWidth, Window.setOuterWidth, .{});
    pub const outerHeight = bridge.accessor(Window.getOuterHeight, Window.setOuterHeight, .{});
    pub const screenX = bridge.accessor(Window.getScreenPosition, Window.setScreenX, .{});
    pub const screenY = bridge.accessor(Window.getScreenPosition, Window.setScreenY, .{});
    pub const screenLeft = bridge.accessor(Window.getScreenPosition, Window.setScreenLeft, .{});
    pub const screenTop = bridge.accessor(Window.getScreenPosition, Window.setScreenTop, .{});

    pub const opener = bridge.accessor(Window.getOpener, Window.setOpener, .{});
    pub const closed = bridge.accessor(Window.getClosed, null, .{});
    pub const name = bridge.accessor(Window.getName, Window.setName, .{});
    pub const open = bridge.function(Window.open, .{});
    pub const close = bridge.function(Window.close, .{});
    pub const focus = bridge.function(Window.focus, .{});
    pub const blur = bridge.function(Window.blur, .{});
    pub const stop = bridge.function(Window.stop, .{});

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

    pub fn postMessage(self: *CrossOriginWindow, message: js.Value, target_origin_or_options: ?js.Value, transfer: ?js.Value, frame: *Frame) !void {
        return self.window.postMessage(message, target_origin_or_options, transfer, frame);
    }

    pub fn getTop(self: *CrossOriginWindow, frame: *Frame) Access {
        return self.window.getParent(frame);
    }

    fn getParent(self: *CrossOriginWindow, frame: *Frame) Access {
        return self.window.getParent(frame);
    }

    fn getFramesLength(self: *const CrossOriginWindow) u32 {
        return self.window.getFramesLength();
    }

    fn getWindow(self: *CrossOriginWindow, frame: *Frame) Access {
        return Access.init(frame.window, self.window);
    }

    fn getOpener(self: *CrossOriginWindow, frame: *Frame) ?Access {
        return self.window.getOpener(frame);
    }

    fn getClosed(self: *const CrossOriginWindow) bool {
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
