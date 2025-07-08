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

const log = @import("../../log.zig");
const parser = @import("../netsurf.zig");
const Function = @import("../env.zig").Function;
const Page = @import("../page.zig").Page;
const Loop = @import("../../runtime/loop.zig").Loop;

const Navigator = @import("navigator.zig").Navigator;
const History = @import("history.zig").History;
const Location = @import("location.zig").Location;
const Crypto = @import("../crypto/crypto.zig").Crypto;
const Console = @import("../console/console.zig").Console;
const EventTarget = @import("../dom/event_target.zig").EventTarget;
const MediaQueryList = @import("media_query_list.zig").MediaQueryList;
const Performance = @import("../dom/performance.zig").Performance;
const CSSStyleDeclaration = @import("../cssom/css_style_declaration.zig").CSSStyleDeclaration;
const CustomElementRegistry = @import("../webcomponents/custom_element_registry.zig").CustomElementRegistry;
const Screen = @import("screen.zig").Screen;
const Css = @import("../css/css.zig").Css;

const storage = @import("../storage/storage.zig");

// https://dom.spec.whatwg.org/#interface-window-extensions
// https://html.spec.whatwg.org/multipage/nav-history-apis.html#window
pub const Window = struct {
    pub const prototype = *EventTarget;

    // Extend libdom event target for pure zig struct.
    base: parser.EventTargetTBase = parser.EventTargetTBase{ .internal_target_type = .window },

    document: *parser.DocumentHTML,
    target: []const u8 = "",
    history: History = .{},
    location: Location = .{},
    storage_shelf: ?*storage.Shelf = null,

    // counter for having unique timer ids
    timer_id: u30 = 0,
    timers: std.AutoHashMapUnmanaged(u32, *TimerCallback) = .{},

    crypto: Crypto = .{},
    console: Console = .{},
    navigator: Navigator = .{},
    performance: Performance,
    custom_elements: CustomElementRegistry = .{},
    screen: Screen = .{},
    css: Css = .{},

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

    // TODO: frames
    pub fn get_top(self: *Window) *Window {
        return self;
    }

    pub fn get_document(self: *Window) ?*parser.DocumentHTML {
        return self.document;
    }

    pub fn get_history(self: *Window) *History {
        return &self.history;
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

    pub fn get_customElements(self: *Window) *CustomElementRegistry {
        return &self.custom_elements;
    }

    pub fn get_screen(self: *Window) *Screen {
        return &self.screen;
    }

    pub fn get_CSS(self: *Window) *Css {
        return &self.css;
    }

    pub fn _requestAnimationFrame(self: *Window, cbk: Function, page: *Page) !u32 {
        return self.createTimeout(cbk, 5, page, .{ .animation_frame = true });
    }

    pub fn _cancelAnimationFrame(self: *Window, id: u32, page: *Page) !void {
        const kv = self.timers.fetchRemove(id) orelse return;
        return page.loop.cancel(kv.value.loop_id);
    }

    // TODO handle callback arguments.
    pub fn _setTimeout(self: *Window, cbk: Function, delay: ?u32, page: *Page) !u32 {
        return self.createTimeout(cbk, delay, page, .{});
    }

    // TODO handle callback arguments.
    pub fn _setInterval(self: *Window, cbk: Function, delay: ?u32, page: *Page) !u32 {
        return self.createTimeout(cbk, delay, page, .{ .repeat = true });
    }

    pub fn _clearTimeout(self: *Window, id: u32, page: *Page) !void {
        const kv = self.timers.fetchRemove(id) orelse return;
        return page.loop.cancel(kv.value.loop_id);
    }

    pub fn _clearInterval(self: *Window, id: u32, page: *Page) !void {
        const kv = self.timers.fetchRemove(id) orelse return;
        return page.loop.cancel(kv.value.loop_id);
    }

    pub fn _matchMedia(_: *const Window, media: []const u8, page: *Page) !MediaQueryList {
        return .{
            .matches = false, // TODO?
            .media = try page.arena.dupe(u8, media),
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
        repeat: bool = false,
        animation_frame: bool = false,
    };
    fn createTimeout(self: *Window, cbk: Function, delay_: ?u32, page: *Page, comptime opts: CreateTimeoutOpts) !u32 {
        const delay = delay_ orelse 0;
        if (delay > 5000) {
            log.warn(.user_script, "long timeout ignored", .{ .delay = delay, .interval = opts.repeat });
            // self.timer_id is u30, so the largest value we can generate is
            // 1_073_741_824. Returning 2_000_000_000 makes sure that clients
            // can call cancelTimer/cancelInterval without breaking anything.
            return 2_000_000_000;
        }

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
        }
        errdefer _ = self.timers.remove(timer_id);

        const delay_ms: u63 = @as(u63, delay) * std.time.ns_per_ms;
        const callback = try arena.create(TimerCallback);

        callback.* = .{
            .cbk = cbk,
            .loop_id = 0, // we're going to set this to a real value shortly
            .window = self,
            .timer_id = timer_id,
            .node = .{ .func = TimerCallback.run },
            .repeat = if (opts.repeat) delay_ms else null,
            .animation_frame = opts.animation_frame,
        };
        callback.loop_id = try page.loop.timeout(delay_ms, &callback.node);

        gop.value_ptr.* = callback;
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
            behavior: []const u8,
        };
    };
    pub fn _scrollTo(self: *Window, opts: ScrollToOpts, y: ?u32) !void {
        _ = opts;
        _ = y;

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

    animation_frame: bool = false,

    window: *Window,

    fn run(node: *Loop.CallbackNode, repeat_delay: *?u63) void {
        const self: *TimerCallback = @fieldParentPtr("node", node);

        var result: Function.Result = undefined;

        var call: anyerror!void = undefined;
        if (self.animation_frame) {
            call = self.cbk.tryCall(void, .{self.window.performance._now()}, &result);
        } else {
            call = self.cbk.tryCall(void, .{}, &result);
        }

        call catch {
            log.warn(.user_script, "callback error", .{
                .err = result.exception,
                .stack = result.stack,
                .source = "window timeout",
            });
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

    try runner.testCases(&.{
        .{ "window.parent === window", "true" },
        .{ "window.top === window", "true" },
    }, .{});

    // requestAnimationFrame should be able to wait by recursively calling itself
    // Note however that we in this test do not wait as the request is just send to the browser
    try runner.testCases(&.{
        .{
            \\ let start = 0;
            \\ function step(timestamp) {
            \\    start = timestamp;
            \\ }
            ,
            null,
        },
        .{ "requestAnimationFrame(step);", null }, // returned id is checked in the next test
        .{ " start > 0", "true" },
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

    // cancelAnimationFrame should be able to cancel a request with the given id
    try runner.testCases(&.{
        .{ "let longCall = false;", null },
        .{ "window.setTimeout(() => {longCall = true}, 5001);", null },
        .{ "longCall;", "false" },
    }, .{});

    // window event target
    try runner.testCases(&.{
        .{
            \\ let called = false;
            \\ window.addEventListener("ready", (e) => {
            \\   called = (e.currentTarget == window);
            \\ }, {capture: false, once: false});
            \\ const evt = new Event("ready", { bubbles: true, cancelable: false });
            \\ window.dispatchEvent(evt);
            \\ called;
            ,
            "true",
        },
    }, .{});

    try runner.testCases(&.{
        .{ "const b64 = btoa('https://ziglang.org/documentation/master/std/#std.base64.Base64Decoder')", "undefined" },
        .{ "b64", "aHR0cHM6Ly96aWdsYW5nLm9yZy9kb2N1bWVudGF0aW9uL21hc3Rlci9zdGQvI3N0ZC5iYXNlNjQuQmFzZTY0RGVjb2Rlcg==" },
        .{ "const str = atob(b64)", "undefined" },
        .{ "str", "https://ziglang.org/documentation/master/std/#std.base64.Base64Decoder" },
        .{ "try { atob('b') } catch (e) { e } ", "Error: InvalidCharacterError" },
    }, .{});

    try runner.testCases(&.{
        .{ "let scroll = false; let scrolend = false", null },
        .{ "window.addEventListener('scroll', () => {scroll = true});", null },
        .{ "document.addEventListener('scrollend', () => {scrollend = true});", null },
        .{ "window.scrollTo(0)", null },
        .{ "scroll", "true" },
        .{ "scrollend", "true" },
    }, .{});
}
