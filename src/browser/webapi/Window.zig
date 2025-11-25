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
const Console = @import("Console.zig");
const History = @import("History.zig");
const Crypto = @import("Crypto.zig");
const Navigator = @import("Navigator.zig");
const Performance = @import("Performance.zig");
const Document = @import("Document.zig");
const Location = @import("Location.zig");
const Fetch = @import("net/Fetch.zig");
const EventTarget = @import("EventTarget.zig");
const ErrorEvent = @import("event/ErrorEvent.zig");
const MediaQueryList = @import("css/MediaQueryList.zig");
const storage = @import("storage/storage.zig");
const Element = @import("Element.zig");
const CSSStyleDeclaration = @import("css/CSSStyleDeclaration.zig");
const CustomElementRegistry = @import("CustomElementRegistry.zig");

const Window = @This();

_proto: *EventTarget,
_document: *Document,
_crypto: Crypto = .init,
_console: Console = .init,
_navigator: Navigator = .init,
_performance: Performance,
_history: History,
_storage_bucket: *storage.Bucket,
_on_load: ?js.Function = null,
_on_error: ?js.Function = null, // TODO: invoke on error?
_location: *Location,
_timer_id: u30 = 0,
_timers: std.AutoHashMapUnmanaged(u32, *ScheduleCallback) = .{},
_custom_elements: CustomElementRegistry = .{},

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

pub fn getCrypto(self: *Window) *Crypto {
    return &self._crypto;
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

pub fn getHistory(self: *Window) *History {
    return &self._history;
}

pub fn getCustomElements(self: *Window) *CustomElementRegistry {
    return &self._custom_elements;
}

pub fn getOnLoad(self: *const Window) ?js.Function {
    return self._on_load;
}

pub fn setOnLoad(self: *Window, cb_: ?js.Function) !void {
    if (cb_) |cb| {
        self._on_load = cb;
    } else {
        self._on_load = null;
    }
}

pub fn getOnError(self: *const Window) ?js.Function {
    return self._on_error;
}

pub fn setOnError(self: *Window, cb_: ?js.Function) !void {
    if (cb_) |cb| {
        self._on_error = cb;
    } else {
        self._on_error = null;
    }
}

pub fn fetch(_: *const Window, input: Fetch.Input, page: *Page) !js.Promise {
    return Fetch.init(input, page);
}

pub fn setTimeout(self: *Window, cb: js.Function, delay_ms: ?u32, params: []js.Object, page: *Page) !u32 {
    return self.scheduleCallback(cb, delay_ms orelse 0, .{
        .repeat = false,
        .params = params,
        .low_priority = false,
        .name = "window.setTimeout",
    }, page);
}

pub fn setInterval(self: *Window, cb: js.Function, delay_ms: ?u32, params: []js.Object, page: *Page) !u32 {
    return self.scheduleCallback(cb, delay_ms orelse 0, .{
        .repeat = true,
        .params = params,
        .low_priority = false,
        .name = "window.setInterval",
    }, page);
}

pub fn setImmediate(self: *Window, cb: js.Function, params: []js.Object, page: *Page) !u32 {
    return self.scheduleCallback(cb, 0, .{
        .repeat = false,
        .params = params,
        .low_priority = false,
        .name = "window.setImmediate",
    }, page);
}

pub fn requestAnimationFrame(self: *Window, cb: js.Function, page: *Page) !u32 {
    return self.scheduleCallback(cb, 5, .{
        .repeat = false,
        .params = &.{},
        .low_priority = false,
        .animation_frame = true,
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

pub fn reportError(self: *Window, err: js.Object, page: *Page) !void {
    const error_event = try ErrorEvent.init("error", .{
        .@"error" = err,
        .message = err.toString() catch "Unknown error",
        .bubbles = false,
        .cancelable = true,
    }, page);

    const event = error_event.asEvent();
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

pub fn getComputedStyle(_: *const Window, _: *Element, page: *Page) !*CSSStyleDeclaration {
    return CSSStyleDeclaration.init(null, page);
}

pub fn btoa(_: *const Window, input: []const u8, page: *Page) ![]const u8 {
    const encoded_len = std.base64.standard.Encoder.calcSize(input.len);
    const encoded = try page.call_arena.alloc(u8, encoded_len);
    return std.base64.standard.Encoder.encode(encoded, input);
}

pub fn atob(_: *const Window, input: []const u8, page: *Page) ![]const u8 {
    const decoded_len = try std.base64.standard.Decoder.calcSizeForSlice(input);
    const decoded = try page.call_arena.alloc(u8, decoded_len);
    try std.base64.standard.Decoder.decode(decoded, input);
    return decoded;
}

const ScheduleOpts = struct {
    repeat: bool,
    params: []js.Object,
    name: []const u8,
    low_priority: bool = false,
    animation_frame: bool = false,
};
fn scheduleCallback(self: *Window, cb: js.Function, delay_ms: u32, opts: ScheduleOpts, page: *Page) !u32 {
    if (self._timers.count() > 512) {
        // these are active
        return error.TooManyTimeout;
    }

    const timer_id = self._timer_id +% 1;
    self._timer_id = timer_id;

    const params = opts.params;
    var persisted_params: []js.Object = &.{};
    if (params.len > 0) {
        persisted_params = try page.arena.alloc(js.Object, params.len);
        for (params, persisted_params) |a, *ca| {
            ca.* = try a.persist();
        }
    }

    const gop = try self._timers.getOrPut(page.arena, timer_id);
    if (gop.found_existing) {
        // 2^31 would have to wrap for this to happen.
        return error.TooManyTimeout;
    }
    errdefer _ = self._timers.remove(timer_id);

    const callback = try page._factory.create(ScheduleCallback{
        .cb = cb,
        .page = page,
        .name = opts.name,
        .timer_id = timer_id,
        .params = persisted_params,
        .animation_frame = opts.animation_frame,
        .repeat_ms = if (opts.repeat) if (delay_ms == 0) 1 else delay_ms else null,
    });
    gop.value_ptr.* = callback;
    errdefer page._factory.destroy(callback);

    try page.scheduler.add(callback, ScheduleCallback.run, delay_ms, .{
        .name = opts.name,
        .low_priority = opts.low_priority,
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

    cb: js.Function,

    page: *Page,

    params: []const js.Object,

    removed: bool = false,

    animation_frame: bool = false,

    fn deinit(self: *ScheduleCallback) void {
        self.page._factory.destroy(self);
    }

    fn run(ctx: *anyopaque) !?u32 {
        const self: *ScheduleCallback = @ptrCast(@alignCast(ctx));
        const page = self.page;
        if (self.removed) {
            _ = page.window._timers.remove(self.timer_id);
            self.deinit();
            return null;
        }

        if (self.animation_frame) {
            self.cb.call(void, .{page.window._performance.now()}) catch |err| {
                // a non-JS error
                log.warn(.js, "window.RAF", .{ .name = self.name, .err = err });
            };
        } else {
            self.cb.call(void, .{self.params}) catch |err| {
                // a non-JS error
                log.warn(.js, "window.timer", .{ .name = self.name, .err = err });
            };
        }

        if (self.repeat_ms) |ms| {
            return ms;
        }
        defer self.deinit();

        _ = page.window._timers.remove(self.timer_id);
        page.js.runMicrotasks();
        return null;
    }
};

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
    pub const performance = bridge.accessor(Window.getPerformance, null, .{ .cache = "performance" });
    pub const localStorage = bridge.accessor(Window.getLocalStorage, null, .{ .cache = "localStorage" });
    pub const sessionStorage = bridge.accessor(Window.getSessionStorage, null, .{ .cache = "sessionStorage" });
    pub const document = bridge.accessor(Window.getDocument, null, .{ .cache = "document" });
    pub const location = bridge.accessor(Window.getLocation, null, .{ .cache = "location" });
    pub const history = bridge.accessor(Window.getHistory, null, .{ .cache = "history" });
    pub const crypto = bridge.accessor(Window.getCrypto, null, .{ .cache = "crypto" });
    pub const customElements = bridge.accessor(Window.getCustomElements, null, .{ .cache = "customElements" });
    pub const onload = bridge.accessor(Window.getOnLoad, Window.setOnLoad, .{});
    pub const onerror = bridge.accessor(Window.getOnError, Window.getOnError, .{});
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
    pub const matchMedia = bridge.function(Window.matchMedia, .{});
    pub const btoa = bridge.function(Window.btoa, .{});
    pub const atob = bridge.function(Window.atob, .{});
    pub const reportError = bridge.function(Window.reportError, .{});
    pub const frames = bridge.accessor(Window.getWindow, null, .{ .cache = "frames" });
    pub const length = bridge.accessor(struct {
        fn wrap(_: *const Window) u32 {
            return 0;
        }
    }.wrap, null, .{ .cache = "length" });

    pub const innerWidth = bridge.accessor(struct {
        fn wrap(_: *const Window) u32 {
            return 1920;
        }
    }.wrap, null, .{ .cache = "innerWidth" });
    pub const innerHeight = bridge.accessor(struct {
        fn wrap(_: *const Window) u32 {
            return 1080;
        }
    }.wrap, null, .{ .cache = "innerHeight" });
    pub const getComputedStyle = bridge.function(Window.getComputedStyle, .{});
};

const testing = @import("../../testing.zig");
test "WebApi: Window" {
    try testing.htmlRunner("window", .{});
}
