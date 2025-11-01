const std = @import("std");
const js = @import("../js/js.zig");
const builtin = @import("builtin");

const log = @import("../../log.zig");
const Page = @import("../Page.zig");
const Console = @import("Console.zig");
const Navigator = @import("Navigator.zig");
const Document = @import("Document.zig");
const Location = @import("Location.zig");
const Fetch = @import("net/Fetch.zig");
const EventTarget = @import("EventTarget.zig");
const ErrorEvent = @import("event/ErrorEvent.zig");
const MediaQueryList = @import("css/MediaQueryList.zig");
const storage = @import("storage/storage.zig");

const Window = @This();

_proto: *EventTarget,
_document: *Document,
_console: Console = .init,
_navigator: Navigator = .init,
_storage_bucket: *storage.Bucket,
_on_load: ?js.Function = null,
_location: *Location,
_timer_id: u30 = 0,
_timers: std.AutoHashMapUnmanaged(u32, *ScheduleCallback) = .{},

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

pub fn getConsole(_: *const Window) Console {
    return .{};
}

pub fn getNavigator(_: *const Window) Navigator {
    return .{};
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
        .name = "window.requestAnimationFrame",
    }, page);
}

// queueMicrotask: quickjs implements this directly

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

pub fn matchMedia(_: *const Window, query: []const u8, page: *Page) !*MediaQueryList {
    return page._factory.eventTarget(MediaQueryList{
        ._proto = undefined,
        ._media = try page.dupeString(query),
    });
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
};
fn scheduleCallback(self: *Window, cb: js.Function, delay_ms: u32, opts: ScheduleOpts, page: *Page) !u32 {
    if (self._timers.count() > 512) {
        // these are active
        return error.TooManyTimeout;
    }

    const timer_id = self._timer_id +% 1;
    self._timer_id = timer_id;

    for (opts.params) |*js_obj| {
        js_obj.* = try js_obj.persist();
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
        .params = opts.params,
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

    fn deinit(self: *ScheduleCallback) void {
        self.page._factory.destroy(self);
    }

    fn run(ctx: *anyopaque) !?u32 {
        const self: *ScheduleCallback = @ptrCast(@alignCast(ctx));
        if (self.removed) {
            _ = self.page.window._timers.remove(self.timer_id);
            self.deinit();
            return null;
        }

        self.cb.call(void, .{self.params}) catch |err| {
            // a non-JS error
            log.warn(.js, "window.timer", .{ .name = self.name, .err = err });
        };

        if (self.repeat_ms) |ms| {
            return ms;
        }

        _ = self.page.window._timers.remove(self.timer_id);
        self.deinit();
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

    pub const self = bridge.accessor(Window.getWindow, null, .{ .cache = "self" });
    pub const window = bridge.accessor(Window.getWindow, null, .{ .cache = "window" });
    pub const parent = bridge.accessor(Window.getWindow, null, .{ .cache = "parent" });
    pub const console = bridge.accessor(Window.getConsole, null, .{ .cache = "console" });
    pub const navigator = bridge.accessor(Window.getNavigator, null, .{ .cache = "navigator" });
    pub const localStorage = bridge.accessor(Window.getLocalStorage, null, .{ .cache = "localStorage" });
    pub const sessionStorage = bridge.accessor(Window.getSessionStorage, null, .{ .cache = "sessionStorage" });
    pub const document = bridge.accessor(Window.getDocument, null, .{ .cache = "document" });
    pub const location = bridge.accessor(Window.getLocation, null, .{ .cache = "location" });
    pub const onload = bridge.accessor(Window.getOnLoad, Window.setOnLoad, .{});
    pub const fetch = bridge.function(Window.fetch, .{});
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
};

const testing = @import("../../testing.zig");
test "WebApi: Window" {
    try testing.htmlRunner("window", .{});
}
