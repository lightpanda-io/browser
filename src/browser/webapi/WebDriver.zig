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
const keyboard = @import("../frame/keyboard.zig");

const Event = @import("Event.zig");
const Element = @import("Element.zig");
const EventTarget = @import("EventTarget.zig");

const Cookie = @import("storage/Cookie.zig");
const TouchEvent = @import("event/TouchEvent.zig");
const Label = @import("element/html/Label.zig");

const log = lp.log;

// This type is only included when the binary is built with the -Dwpt_extensions flag
const WebDriver = @This();

_pad: bool = false,

fn deleteAllCookies(_: *const WebDriver, page: *Page) void {
    page.session.cookie_jar.clearRetainingCapacity();
}

fn getComputedLabel(_: *const WebDriver, element: *Element, frame: *Frame) ![]const u8 {
    const AXNode = @import("../../server/cdp/AXNode.zig");
    const axnode = AXNode.fromNode(element.asNode());
    var labels: Label.LabelByForIndex = .{};
    return (try axnode.getName(frame, frame.call_arena, &labels)) orelse "";
}

// Implements testdriver's `click`: a full trusted primary-button click
// sequence on the element, as a real user click would produce. Unlike
// HTMLElement.click() (a lone untrusted click event), the events are trusted
// and preceded by the pointer/mouse press and release. Dispatched
// synchronously so the events are observable when the testdriver promise
// resolves.
pub fn click(_: *const WebDriver, element: *Element, frame: *Frame) !void {
    // A dispatch error must never reject the testdriver command.
    Frame.user_input.triggerClick(frame, element, frame.page.input_modifiers) catch |err| {
        log.debug(.app, "webdriver click", .{ .err = err });
    };
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
fn getNamedCookie(_: *const WebDriver, name: []const u8, frame: *Frame) ?WebDriverCookie {
    const jar = &frame._session.cookie_jar;
    const target = Cookie.PreparedUri.init(frame.url);
    if (target.host.len == 0) {
        return null;
    }

    jar.removeExpired(null);
    for (jar.cookies.items) |*cookie| {
        if (cookie.appliesTo(&target, .{ .same_site = true, .is_http = true, .kind = .navigation }) == false) {
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
    errdefer arena.release();

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
    arena: *lp.Arena,
    sources: js.Value.Global,
    resolver: js.PromiseResolver.Global,

    fn run(ptr: *anyopaque) !?u32 {
        const self: *ActionSequence = @ptrCast(@alignCast(ptr));
        const frame = self.frame;
        defer self.deinit();

        var ls: js.Local.Scope = undefined;
        frame.js.localScope(&ls);
        defer ls.deinit();

        performSources(self, &ls) catch |err| {
            ls.toLocal(self.resolver).reject("WebDriver.actionSequence", ls.local.newString(@errorName(err)));
            return err;
        };

        ls.toLocal(self.resolver).resolve("WebDriver.actionSequence", {});
        return null;
    }

    fn performSources(self: *ActionSequence, ls: *js.Local.Scope) !void {
        const frame = self.frame;
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
    }

    fn finalize(ptr: *anyopaque) void {
        const self: *ActionSequence = @ptrCast(@alignCast(ptr));
        self.deinit();
    }

    fn deinit(self: *ActionSequence) void {
        self.sources.release();
        self.resolver.release();
        self.arena.release();
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
    var pointer: Frame.user_input.PointerButtons = .{};
    var click_count: u32 = 0;
    var last_click_button: i32 = 0;
    var last_click_target: ?*Element = null;

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
            } else {
                const y = readI32(action, "y", 0);
                if (frame.document.elementFromVerticalPoint(@floatFromInt(y), frame) catch null) |el| {
                    target = el;
                } else if (frame.document.getDocumentElement()) |root| {
                    target = root;
                }
            }
            const el = target orelse continue;
            Frame.user_input.moveSequence(frame, el, .{
                .buttons_down = pointer.held,
                .modifiers = frame.page.input_modifiers,
                .emit_mouse_compat = !is_touch,
            }) catch {};
            if (is_touch and pointer.held != 0) {
                dispatchTouch(el, "touchmove", frame);
            }
        } else if (action_type.eql(comptime .wrap("pointerDown"))) {
            const el = target orelse continue;
            const button = readI32(action, "button", 0);
            if (last_click_target == el and last_click_button == button) {
                click_count += 1;
            } else {
                click_count = 1;
            }
            pointer.press(frame, el, .{
                .button = button,
                .click_count = click_count,
                .modifiers = frame.page.input_modifiers,
                .emit_mouse_compat = !is_touch,
            }) catch {};
            if (is_touch) {
                dispatchTouch(el, "touchstart", frame);
            }
        } else if (action_type.eql(comptime .wrap("pointerUp"))) {
            const el = target orelse continue;
            const button = readI32(action, "button", 0);
            last_click_button = button;
            last_click_target = pointer.release(frame, el, .{
                .button = button,
                .click_count = click_count,
                .modifiers = frame.page.input_modifiers,
                .emit_mouse_compat = !is_touch,
            }) catch null;
            if (is_touch) {
                dispatchTouch(el, "touchend", frame);
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

        const x = readI32(action, "x", 0);
        const y = readI32(action, "y", 0);

        const origin = try action.get("origin");
        var el: ?*Element = null;
        if (origin.isObject()) {
            el = origin.local.jsValueToZig(*Element, origin) catch null;
        } else {
            // "viewport"/"pointer" origins: approximate hit-testing with
            // the faux layout's vertical axis, falling back to the root.
            el = frame.document.elementFromVerticalPoint(@floatFromInt(y), frame) catch null;
            if (el == null) {
                el = frame.document.getDocumentElement();
            }
        }
        const target = el orelse continue;

        const delta_x = readI32(action, "deltaX", 0);
        const delta_y = readI32(action, "deltaY", 0);
        dispatchWheel(target, x, y, delta_x, delta_y, frame);
    }
}

fn performKeySource(source: js.Object, frame: *Frame) !void {
    const actions_val = try source.get("actions");
    if (!actions_val.isArray()) return;
    const actions = actions_val.toArray();

    for (0..actions.len()) |i| {
        const action_val = try actions.get(@intCast(i));
        if (!action_val.isObject()) continue;
        const action = action_val.toObject();
        const action_type = (try action.get("type")).toSSO(false) catch continue;

        const is_down = action_type.eql(comptime .wrap("keyDown"));
        if (!is_down and action_type.eql(comptime .wrap("keyUp")) == false) {
            continue;
        }

        const value = (try action.get("value")).toStringSlice() catch "";
        const direction: keyboard.Direction = if (is_down) .down else .up;
        const modifiers = &frame.page.input_modifiers;
        // A grapheme cluster of several code points is its own key name.
        const dispatched = if (keyboard.singleCodepoint(value)) |cp|
            keyboard.keyAction(frame, cp, direction, modifiers)
        else
            keyboard.dispatch(frame, null, direction, &.{ .key = .{ .name = value }, .code = "" }, modifiers);
        dispatched catch |err| {
            log.debug(.app, "webdriver key", .{ .err = err });
        };
    }
}

fn readI32(obj: js.Object, key: []const u8, default: i32) i32 {
    const val = obj.get(key) catch return default;
    if (val.isNullOrUndefined()) {
        return default;
    }
    return val.toI32() catch default;
}

// The action's x/y, which the caller already resolved the target from. An
// element origin makes them offsets from its center, but the faux layout has
// no center worth computing.
fn dispatchWheel(el: *Element, x: i32, y: i32, delta_x: i32, delta_y: i32, frame: *Frame) void {
    Frame.user_input.wheel(frame, el, @floatFromInt(x), @floatFromInt(y), @floatFromInt(delta_x), @floatFromInt(delta_y)) catch |err| {
        log.debug(.app, "webdriver wheel", .{ .err = err });
    };
}

fn dispatch(target: *EventTarget, event: *Event, frame: *Frame, typ: []const u8) void {
    frame._event_manager.dispatch(target, event) catch |err| {
        log.debug(.app, "webdriver dispatch", .{ .err = err, .type = typ });
    };
}

fn dispatchTouch(el: *Element, comptime typ: []const u8, frame: *Frame) void {
    const owner = el.ownerFrame(frame) orelse return;
    const event = TouchEvent.initTrusted(typ, .{
        .bubbles = true,
        .composed = true,
    }, owner) catch |err| {
        log.debug(.app, "webdriver touch event", .{ .err = err });
        return;
    };
    event.asEvent()._cancelable_unless_passive = true;
    dispatch(el.asEventTarget(), event.asEvent(), owner, typ);
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
