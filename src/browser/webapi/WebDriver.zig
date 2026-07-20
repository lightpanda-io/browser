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

const js = @import("../js/js.zig");
const Page = @import("../Page.zig");
const Frame = @import("../Frame.zig");

const Cookie = @import("storage/Cookie.zig");
const Element = @import("Element.zig");
const Event = @import("Event.zig");
const EventTarget = @import("EventTarget.zig");
const MouseEvent = @import("event/MouseEvent.zig");
const PointerEvent = @import("event/PointerEvent.zig");
const KeyboardEvent = @import("event/KeyboardEvent.zig");
const WheelEvent = @import("event/WheelEvent.zig");
const TouchEvent = @import("event/TouchEvent.zig");
const EventManagerBase = @import("../EventManagerBase.zig");

const log = lp.log;
const Allocator = std.mem.Allocator;

// This type is only included when the binary is built with the -Dwpt_extensions flag
const WebDriver = @This();

_pad: bool = false,

pub fn deleteAllCookies(_: *const WebDriver, page: *Page) void {
    page.session.cookie_jar.clearRetainingCapacity();
}

pub fn getComputedLabel(_: *const WebDriver, element: *Element, frame: *Frame) ![]const u8 {
    const AXNode = @import("../../cdp/AXNode.zig");
    const axnode = AXNode.fromNode(element.asNode());
    return (try axnode.getName(frame, frame.call_arena)) orelse "";
}

// Implements testdriver's `click`: a full trusted primary-button click
// sequence on the element, as a real user click would produce. Unlike
// HTMLElement.click() (a lone untrusted click event), the events are trusted
// and preceded by the pointer/mouse press and release. Dispatched
// synchronously so the events are observable when the testdriver promise
// resolves.
pub fn click(_: *const WebDriver, element: *Element, frame: *Frame) !void {
    if (element.is(Element.Html)) |html| {
        switch (html._type) {
            inline .button, .input, .textarea, .select => |i| {
                if (i.getDisabled()) {
                    return;
                }
            },
            else => {},
        }
    }

    dispatchPointer(element, "pointerdown", 0, 1, frame);
    dispatchMouse(element, "mousedown", 0, 1, frame);
    dispatchPointer(element, "pointerup", 0, 0, frame);
    dispatchMouse(element, "mouseup", 0, 0, frame);
    dispatchMouse(element, "click", 0, 0, frame);
}

const WebDriverCookie = struct {
    name: []const u8,
    value: []const u8,
    path: []const u8,
    domain: []const u8,
    secure: bool,
    httpOnly: bool,
    sameSite: []const u8,
    expiry: ?f64,
};

// Unlike the script-facing CookieStore, WebDriver can see HttpOnly cookies.
pub fn getNamedCookie(_: *const WebDriver, name: []const u8, frame: *Frame) ?WebDriverCookie {
    const jar = &frame._session.cookie_jar;
    const target = Cookie.PreparedUri.init(frame.url);
    if (target.host.len == 0) {
        return null;
    }

    jar.removeExpired(null);
    for (jar.cookies.items) |*cookie| {
        if (cookie.appliesTo(&target, true, true, true) == false) {
            continue;
        }
        if (std.mem.eql(u8, cookie.name, name) == false) {
            continue;
        }
        return .{
            .name = cookie.name,
            .value = cookie.value,
            .path = cookie.path,
            .domain = if (cookie.domain.len > 0 and cookie.domain[0] == '.') cookie.domain[1..] else cookie.domain,
            .secure = cookie.secure,
            .httpOnly = cookie.http_only,
            .sameSite = switch (cookie.same_site) {
                .strict => "Strict",
                .lax => "Lax",
                .none => "None",
            },
            .expiry = cookie.expires,
        };
    }
    return null;
}

// Implements testdriver's `action_sequence` (the WebDriver "Perform Actions"
// command) for the renderless browser. We can't do real hit-testing, so we only
// support the subset that targets a concrete element via `origin`. Each input
// source is the serialized form produced by testdriver-actions.js:
//   { type: "pointer", actions: [{type: "pointerMove", x, y, origin}, ...] }
//   { type: "key",     actions: [{type: "keyDown", value}, ...] }
//   { type: "wheel",   actions: [{type: "scroll", deltaX, deltaY, origin}, ...] }
pub fn actionSequence(_: *const WebDriver, sources: js.Value, frame: *Frame) !js.Promise {
    if (sources.isArray() == false) {
        return error.InvalidArgument;
    }

    const arena = try frame.getArena(.tiny, "WebDriver.actionSequence");
    errdefer frame.releaseArena(arena);

    const persisted = try sources.persist();
    errdefer persisted.release();

    // Resolved once the actions have been performed, so testdriver's
    // Actions().send() promise doesn't settle before the events fired.
    const resolver = frame.js.local.?.createPromiseResolver();

    const action_sequence = try arena.create(ActionSequence);
    action_sequence.* = .{
        .frame = frame,
        .arena = arena,
        .sources = persisted,
        .resolver = try resolver.persist(),
    };
    errdefer action_sequence.resolver.release();

    // cannot be run synchronously, has to be run on the next tick
    try frame.js.scheduler.add(action_sequence, ActionSequence.run, 0, .{
        .name = "WebDriver.actionSequence",
        .finalizer = ActionSequence.finalize,
    });

    return resolver.promise();
}

const ActionSequence = struct {
    frame: *Frame,
    arena: Allocator,
    sources: js.Value.Global,
    resolver: js.PromiseResolver.Global,

    fn run(ptr: *anyopaque) !?u32 {
        const self: *ActionSequence = @ptrCast(@alignCast(ptr));
        const frame = self.frame;
        defer self.deinit();

        var ls: js.Local.Scope = undefined;
        frame.js.localScope(&ls);
        defer ls.deinit();

        errdefer |err| {
            ls.toLocal(self.resolver).reject("WebDriver.actionSequence", ls.local.newString(@errorName(err)));
        }

        const sources = self.sources.local(&ls.local).toArray();
        for (0..sources.len()) |i| {
            const source_val = try sources.get(@intCast(i));
            if (!source_val.isObject()) {
                continue;
            }
            const source = source_val.toObject();
            const source_type = (try source.get("type")).toSSO(false) catch continue;
            if (source_type.eql(comptime .wrap("pointer"))) {
                try performPointerSource(source, frame);
            } else if (source_type.eql(comptime .wrap("key"))) {
                try performKeySource(source, frame);
            } else if (source_type.eql(comptime .wrap("wheel"))) {
                try performWheelSource(source, frame);
            }
            // "none" sources only carry pauses, which have no observable effect here.
        }

        ls.toLocal(self.resolver).resolve("WebDriver.actionSequence", {});
        return null;
    }

    fn finalize(ptr: *anyopaque) void {
        const self: *ActionSequence = @ptrCast(@alignCast(ptr));
        self.deinit();
    }

    fn deinit(self: *ActionSequence) void {
        self.sources.release();
        self.resolver.release();
        self.frame.releaseArena(self.arena);
    }
};

fn performPointerSource(source: js.Object, frame: *Frame) !void {
    const actions_val = try source.get("actions");
    if (!actions_val.isArray()) {
        return;
    }
    const actions = actions_val.toArray();

    // A touch pointer dispatches touch events instead of mouse events.
    var is_touch = false;
    const params = try source.get("parameters");
    if (params.isObject()) {
        if ((try params.toObject().get("pointerType")).toSSO(false)) |pointer_type| {
            is_touch = pointer_type.eql(comptime .wrap("touch"));
        } else |_| {}
    }

    // The element the pointer is currently over, set by the last pointerMove
    // whose origin resolved to an element.
    var target: ?*Element = null;
    var pressed = false;

    for (0..actions.len()) |i| {
        const action_val = try actions.get(@intCast(i));
        if (!action_val.isObject()) {
            continue;
        }
        const action = action_val.toObject();
        const action_type = (try action.get("type")).toSSO(false) catch continue;

        if (action_type.eql(comptime .wrap("pointerMove"))) {
            const origin = try action.get("origin");
            if (origin.isObject()) {
                target = origin.local.jsValueToZig(*Element, origin) catch null;
            }
            const el = target orelse continue;
            dispatchPointer(el, "pointermove", 0, 0, frame);
            if (is_touch) {
                if (pressed) {
                    dispatchTouch(el, "touchmove", frame);
                }
            } else {
                dispatchMouse(el, "mousemove", 0, 0, frame);
            }
        } else if (action_type.eql(comptime .wrap("pointerDown"))) {
            const el = target orelse continue;
            const button = readI32(action, "button", 0);
            pressed = true;
            dispatchPointer(el, "pointerdown", button, 1, frame);
            if (is_touch) {
                dispatchTouch(el, "touchstart", frame);
            } else {
                dispatchMouse(el, "mousedown", button, 1, frame);
                Frame.user_input.focusEditingHostForMouseDown(frame, el) catch |err| {
                    log.warn(.app, "webdriver editable focus", .{ .err = err });
                };
            }
        } else if (action_type.eql(comptime .wrap("pointerUp"))) {
            const el = target orelse continue;
            const button = readI32(action, "button", 0);
            pressed = false;
            dispatchPointer(el, "pointerup", button, 0, frame);
            if (is_touch) {
                dispatchTouch(el, "touchend", frame);
            } else {
                dispatchMouse(el, "mouseup", button, 0, frame);
                dispatchMouse(el, "click", button, 0, frame);
            }
        }
        // "pause" carries timing only and is ignored. ("pointerCancel" is not
        // emitted by the testdriver Actions builder.)
    }
}

fn performWheelSource(source: js.Object, frame: *Frame) !void {
    const actions_val = try source.get("actions");
    if (!actions_val.isArray()) {
        return;
    }
    const actions = actions_val.toArray();

    for (0..actions.len()) |i| {
        const action_val = try actions.get(@intCast(i));
        if (!action_val.isObject()) {
            continue;
        }
        const action = action_val.toObject();
        const action_type = (try action.get("type")).toSSO(false) catch continue;
        if (action_type.eql(comptime .wrap("scroll")) == false) {
            // "pause" is the only other action and has no observable effect.
            continue;
        }

        const origin = try action.get("origin");
        var el: ?*Element = null;
        if (origin.isObject()) {
            el = origin.local.jsValueToZig(*Element, origin) catch null;
        } else {
            // "viewport"/"pointer" origins: approximate hit-testing with
            // the faux layout's vertical axis, falling back to the root.
            const y = readI32(action, "y", 0);
            el = frame.document.elementFromVerticalPoint(@floatFromInt(y), frame) catch null;
            if (el == null) {
                el = frame.document.getDocumentElement();
            }
        }
        const target = el orelse continue;

        const delta_x = readI32(action, "deltaX", 0);
        const delta_y = readI32(action, "deltaY", 0);
        dispatchWheel(target, delta_x, delta_y, frame);
    }
}

fn performKeySource(source: js.Object, frame: *Frame) !void {
    const actions_val = try source.get("actions");
    if (!actions_val.isArray()) return;
    const actions = actions_val.toArray();

    // Key actions have no explicit target; they go to the focused element, or
    // the document if nothing is focused.
    const target = if (frame.document._active_element) |el|
        el.asEventTarget()
    else
        frame.document.asNode().asEventTarget();

    for (0..actions.len()) |i| {
        const action_val = try actions.get(@intCast(i));
        if (!action_val.isObject()) continue;
        const action = action_val.toObject();
        const action_type = (try action.get("type")).toSSO(false) catch continue;

        const key = (try action.get("value")).toStringSlice() catch "";
        if (action_type.eql(comptime .wrap("keyDown"))) {
            dispatchKey(target, comptime .wrap("keydown"), key, frame);
        } else if (action_type.eql(comptime .wrap("keyUp"))) {
            dispatchKey(target, comptime .wrap("keyup"), key, frame);
        }
    }
}

fn dispatchKey(target: *EventTarget, typ: lp.String, key: []const u8, frame: *Frame) void {
    const event = KeyboardEvent.initTrusted(typ, .{
        .bubbles = true,
        .cancelable = true,
        .composed = true,
        .key = key,
    }, frame) catch |err| {
        log.warn(.app, "webdriver key event", .{ .err = err });
        return;
    };
    dispatch(target, event.asEvent(), frame, typ.str());
}

fn readI32(obj: js.Object, key: []const u8, default: i32) i32 {
    const val = obj.get(key) catch return default;
    if (val.isNullOrUndefined()) {
        return default;
    }
    return val.toI32() catch default;
}

fn dispatchPointer(el: *Element, comptime typ: []const u8, button: i32, buttons: u16, frame: *Frame) void {
    const event = PointerEvent.initTrusted(typ, .{
        .bubbles = true,
        .cancelable = true,
        .composed = true,
        .button = button,
        .buttons = buttons,
        .pointerId = 1,
        .pointerType = "mouse",
        .isPrimary = true,
    }, frame) catch |err| {
        log.warn(.app, "webdriver pointer event", .{ .err = err, .type = typ });
        return;
    };
    dispatch(el.asEventTarget(), event.asEvent(), frame, typ);
}

fn dispatchMouse(el: *Element, comptime typ: []const u8, button: i32, buttons: u16, frame: *Frame) void {
    const event = MouseEvent.initTrusted(comptime .wrap(typ), .{
        .bubbles = true,
        .cancelable = true,
        .composed = true,
        .button = button,
        .buttons = buttons,
    }, frame) catch |err| {
        log.warn(.app, "webdriver mouse event", .{ .err = err, .type = typ });
        return;
    };
    dispatch(el.asEventTarget(), event.asEvent(), frame, typ);
}

fn dispatchWheel(el: *Element, delta_x: i32, delta_y: i32, frame: *Frame) void {
    // The UA dispatches scroll-blocking events as non-cancelable when every
    // listener on the propagation path is passive: it already knows
    // preventDefault can't be called.
    const event = WheelEvent.initTrusted("wheel", .{
        .bubbles = true,
        .cancelable = hasNonPassiveListener(el, "wheel", frame),
        .composed = true,
        .deltaX = @floatFromInt(delta_x),
        .deltaY = @floatFromInt(delta_y),
    }, frame) catch |err| {
        log.warn(.app, "webdriver wheel event", .{ .err = err });
        return;
    };

    // Keep the event alive past dispatch so we can read _prevent_default.
    event.asEvent().acquireRef();
    defer _ = event.asEvent().releaseRef(frame._page);
    dispatch(el.asEventTarget(), event.asEvent(), frame, "wheel");

    // Blink also fires the legacy mousewheel event.
    const legacy = WheelEvent.initTrusted("mousewheel", .{
        .bubbles = true,
        .cancelable = hasNonPassiveListener(el, "mousewheel", frame),
        .composed = true,
        .deltaX = @floatFromInt(delta_x),
        .deltaY = @floatFromInt(delta_y),
    }, frame) catch |err| {
        log.warn(.app, "webdriver mousewheel event", .{ .err = err });
        return;
    };
    legacy.asEvent().acquireRef();
    defer _ = legacy.asEvent().releaseRef(frame._page);
    dispatch(el.asEventTarget(), legacy.asEvent(), frame, "mousewheel");

    if (event.asEvent()._prevent_default or legacy.asEvent()._prevent_default) {
        return;
    }

    // Apply the scroll and fire a trusted scroll event, mirroring actions.scroll.
    const new_left: i32 = @as(i32, @intCast(el.getScrollLeft(frame))) + delta_x;
    const new_top: i32 = @as(i32, @intCast(el.getScrollTop(frame))) + delta_y;
    el.setScrollLeft(new_left, frame) catch {};
    el.setScrollTop(new_top, frame) catch {};

    const scroll_evt = Event.initTrusted(comptime .wrap("scroll"), .{ .bubbles = true }, frame._page) catch |err| {
        log.warn(.app, "webdriver scroll event", .{ .err = err });
        return;
    };
    dispatch(el.asEventTarget(), scroll_evt, frame, "scroll");
}

fn dispatch(target: *EventTarget, event: *Event, frame: *Frame, typ: []const u8) void {
    frame._event_manager.dispatch(target, event) catch |err| {
        log.warn(.app, "webdriver dispatch", .{ .err = err, .type = typ });
    };
}

fn hasNonPassiveListener(el: *Element, typ: []const u8, frame: *Frame) bool {
    // Listeners live in the event manager of the element's own frame (and the
    // propagation path ends at that frame's window), which is not the caller's
    // frame when the element belongs to e.g. an iframe's document.
    const owner = el.ownerFrame(frame);
    const base = &owner._event_manager.base;
    var current: ?*@import("Node.zig") = el.asNode();
    while (current) |node| : (current = node.parentNode()) {
        if (anyNonPassive(base.getListeners(node.asEventTarget(), .wrap(typ)))) {
            return true;
        }
    }
    return anyNonPassive(base.getListeners(owner.window.asEventTarget(), .wrap(typ)));
}

fn anyNonPassive(list_: ?*std.DoublyLinkedList) bool {
    const list = list_ orelse return false;
    var link = list.first;
    while (link) |l| : (link = l.next) {
        const listener: *align(8) EventManagerBase.Listener = @fieldParentPtr("node", l);
        if (!listener.passive) {
            return true;
        }
    }
    return false;
}

fn dispatchTouch(el: *Element, comptime typ: []const u8, frame: *Frame) void {
    const event = TouchEvent.initTrusted(typ, .{
        .bubbles = true,
        .cancelable = hasNonPassiveListener(el, typ, frame),
        .composed = true,
    }, frame) catch |err| {
        log.warn(.app, "webdriver touch event", .{ .err = err });
        return;
    };
    dispatch(el.asEventTarget(), event.asEvent(), frame, typ);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(WebDriver);

    pub const Meta = struct {
        pub const name = "WebDriver";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
        pub const empty_with_no_proto = true;
    };
    pub const deleteAllCookies = bridge.function(WebDriver.deleteAllCookies, .{});
    pub const getComputedLabel = bridge.function(WebDriver.getComputedLabel, .{});
    pub const getNamedCookie = bridge.function(WebDriver.getNamedCookie, .{});
    pub const actionSequence = bridge.function(WebDriver.actionSequence, .{});
    pub const click = bridge.function(WebDriver.click, .{});
};
