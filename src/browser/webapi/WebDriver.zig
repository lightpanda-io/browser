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
const Modifiers = @import("../frame/user_input.zig").Modifiers;

const Event = @import("Event.zig");
const Element = @import("Element.zig");
const EventTarget = @import("EventTarget.zig");

const Cookie = @import("storage/Cookie.zig");
const MouseEvent = @import("event/MouseEvent.zig");
const TouchEvent = @import("event/TouchEvent.zig");
const PointerEvent = @import("event/PointerEvent.zig");
const KeyboardEvent = @import("event/KeyboardEvent.zig");
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
    if (element.is(Element.Html)) |html| {
        switch (html._type) {
            .button, .input, .textarea, .select, .option, .optgroup => if (element.isDisabled()) return,
            else => {},
        }
    }

    // A dispatch error must never reject the testdriver command.
    Frame.user_input.triggerClick(frame, element, frame.page.input_modifiers) catch |err| {
        log.warn(.app, "webdriver click", .{ .err = err });
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
    var pressed = false;
    // The buttons bitmask of the currently depressed button, carried on move
    // and boundary events while dragging.
    var pressed_mask: u16 = 0;
    // Where the last pointerDown landed: the click fires at the nearest common
    // inclusive ancestor of the down and up targets when they differ.
    var down_target: ?*Element = null;
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
            if (is_touch) {
                dispatchPointer(el, "pointermove", 0, pressed_mask, frame);
                if (pressed) {
                    dispatchTouch(el, "touchmove", frame);
                }
            } else {
                Frame.user_input.updateHoverTarget(frame, el, .{
                    .buttons = pressed_mask,
                    .modifiers = frame.page.input_modifiers,
                    .with_pointer = true,
                });
                dispatchPointer(el, "pointermove", 0, pressed_mask, frame);
                _ = dispatchMouse(el, "mousemove", 0, pressed_mask, 0, frame);
            }
        } else if (action_type.eql(comptime .wrap("pointerDown"))) {
            const el = target orelse continue;
            const button = readI32(action, "button", 0);
            pressed = true;
            pressed_mask = Frame.user_input.buttonsBitmask(button);
            down_target = el;
            if (last_click_target == el and last_click_button == button) {
                click_count += 1;
            } else {
                click_count = 1;
            }
            dispatchPointer(el, "pointerdown", button, Frame.user_input.buttonsBitmask(button), frame);
            if (is_touch) {
                dispatchTouch(el, "touchstart", frame);
            } else {
                const suppressed = dispatchMouse(el, "mousedown", button, Frame.user_input.buttonsBitmask(button), click_count, frame);
                if (!suppressed) {
                    Frame.user_input.focusForMouseDown(frame, el) catch |err| {
                        log.warn(.app, "webdriver mousedown focus", .{ .err = err });
                    };
                }
            }
        } else if (action_type.eql(comptime .wrap("pointerUp"))) {
            const el = target orelse continue;
            const button = readI32(action, "button", 0);
            pressed = false;
            pressed_mask = 0;
            dispatchPointer(el, "pointerup", button, 0, frame);
            if (is_touch) {
                dispatchTouch(el, "touchend", frame);
            } else {
                _ = dispatchMouse(el, "mouseup", button, 0, click_count, frame);
                const click_target = commonClickTarget(down_target orelse el, el);
                last_click_button = button;
                last_click_target = click_target;
                if (button == 0) {
                    _ = dispatchMouse(click_target, "click", button, 0, click_count, frame);
                    if (click_count % 2 == 0) {
                        _ = dispatchMouse(click_target, "dblclick", button, 0, click_count, frame);
                    }
                } else {
                    if (button == 2) {
                        _ = dispatchMouse(click_target, "contextmenu", button, 0, click_count, frame);
                    }
                    _ = dispatchMouse(click_target, "auxclick", button, 0, click_count, frame);
                }
            }
            down_target = null;
        }
        // "pause" carries timing only and is ignored. ("pointerCancel" is not
        // emitted by the testdriver Actions builder.)
    }
}

// A click whose mousedown and mouseup landed on different elements fires at
// their nearest common inclusive ancestor element.
fn commonClickTarget(down: *Element, up: *Element) *Element {
    if (down == up) {
        return up;
    }
    var current: ?*@import("Node.zig") = down.asNode();
    while (current) |node| : (current = node.parentNode()) {
        if (node.contains(up.asNode())) {
            return node.is(Element) orelse break;
        }
    }
    return up;
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

        const key = webdriverKey((try action.get("value")).toStringSlice() catch "");

        // A modifier's own keydown already carries its flag; its keyup no
        // longer does.
        setModifier(&frame.page.input_modifiers, key, is_down);

        dispatchKey(is_down, key, frame);
    }
}

// WebDriver's normalized-key PUA codepoints to KeyboardEvent.key values
// (https://w3c.github.io/webdriver/#keyboard-actions). Any other value is the
// key itself. The U+E050-U+E053 right-hand variants map to the same key name,
// only the (untracked) location differs.
fn webdriverKey(value: []const u8) []const u8 {
    // The U+E000-U+E05D PUA range always encodes as three UTF-8 bytes.
    if (value.len != 3) {
        return value;
    }
    const cp = std.unicode.utf8Decode(value) catch return value;
    return switch (cp) {
        0xE000 => "Unidentified",
        0xE001 => "Cancel",
        0xE002 => "Help",
        0xE003 => "Backspace",
        0xE004 => "Tab",
        0xE005 => "Clear",
        0xE006, 0xE007 => "Enter",
        0xE008, 0xE050 => "Shift",
        0xE009, 0xE051 => "Control",
        0xE00A, 0xE052 => "Alt",
        0xE00B => "Pause",
        0xE00C => "Escape",
        0xE00D => " ",
        0xE00E => "PageUp",
        0xE00F => "PageDown",
        0xE010 => "End",
        0xE011 => "Home",
        0xE012 => "ArrowLeft",
        0xE013 => "ArrowUp",
        0xE014 => "ArrowRight",
        0xE015 => "ArrowDown",
        0xE016 => "Insert",
        0xE017 => "Delete",
        0xE018 => ";",
        0xE019 => "=",
        0xE01A => "0",
        0xE01B => "1",
        0xE01C => "2",
        0xE01D => "3",
        0xE01E => "4",
        0xE01F => "5",
        0xE020 => "6",
        0xE021 => "7",
        0xE022 => "8",
        0xE023 => "9",
        0xE024 => "*",
        0xE025 => "+",
        0xE026 => ",",
        0xE027 => "-",
        0xE028 => ".",
        0xE029 => "/",
        0xE031 => "F1",
        0xE032 => "F2",
        0xE033 => "F3",
        0xE034 => "F4",
        0xE035 => "F5",
        0xE036 => "F6",
        0xE037 => "F7",
        0xE038 => "F8",
        0xE039 => "F9",
        0xE03A => "F10",
        0xE03B => "F11",
        0xE03C => "F12",
        0xE03D, 0xE053 => "Meta",
        else => value,
    };
}

fn setModifier(modifiers: *Modifiers, key: []const u8, pressed: bool) void {
    if (std.mem.eql(u8, key, "Shift")) {
        modifiers.shift = pressed;
    } else if (std.mem.eql(u8, key, "Control")) {
        modifiers.ctrl = pressed;
    } else if (std.mem.eql(u8, key, "Alt")) {
        modifiers.alt = pressed;
    } else if (std.mem.eql(u8, key, "Meta")) {
        modifiers.meta = pressed;
    }
}

// Key actions have no explicit target; they go to the focused element,
// resolved per action since a key's default action can move focus.
fn dispatchKey(is_down: bool, key: []const u8, frame: *Frame) void {
    const typ: lp.String = if (is_down) comptime .wrap("keydown") else comptime .wrap("keyup");
    const modifiers = frame.page.input_modifiers;
    const event = KeyboardEvent.initTrusted(typ, .{
        .bubbles = true,
        .cancelable = true,
        .composed = true,
        .key = key,
        .ctrlKey = modifiers.ctrl,
        .shiftKey = modifiers.shift,
        .altKey = modifiers.alt,
        .metaKey = modifiers.meta,
    }, frame) catch |err| {
        log.warn(.app, "webdriver key event", .{ .err = err });
        return;
    };
    if (is_down) {
        _ = Frame.user_input.triggerKeyDown(frame, event, Frame.user_input.textForKey(event)) catch |err| {
            log.warn(.app, "webdriver dispatch", .{ .err = err, .type = typ.str() });
        };
    } else {
        Frame.user_input.triggerKeyUp(frame, event) catch |err| {
            log.warn(.app, "webdriver dispatch", .{ .err = err, .type = typ.str() });
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

fn dispatchPointer(el: *Element, comptime typ: []const u8, button: i32, buttons: u16, frame: *Frame) void {
    const modifiers = frame.page.input_modifiers;
    const event = PointerEvent.initTrusted(typ, .{
        .bubbles = true,
        .cancelable = true,
        .composed = true,
        .button = button,
        .buttons = buttons,
        .pointerId = 1,
        .pointerType = "mouse",
        .isPrimary = true,
        .ctrlKey = modifiers.ctrl,
        .shiftKey = modifiers.shift,
        .altKey = modifiers.alt,
        .metaKey = modifiers.meta,
    }, frame) catch |err| {
        log.warn(.app, "webdriver pointer event", .{ .err = err, .type = typ });
        return;
    };
    dispatch(el.asEventTarget(), event.asEvent(), frame, typ);
}

fn dispatchMouse(el: *Element, comptime typ: []const u8, button: i32, buttons: u16, detail: u32, frame: *Frame) bool {
    const modifiers = frame.page.input_modifiers;
    const event = MouseEvent.initTrusted(comptime .wrap(typ), .{
        .bubbles = true,
        .cancelable = true,
        .composed = true,
        .button = button,
        .buttons = buttons,
        .detail = detail,
        .ctrlKey = modifiers.ctrl,
        .shiftKey = modifiers.shift,
        .altKey = modifiers.alt,
        .metaKey = modifiers.meta,
    }, frame) catch |err| {
        log.warn(.app, "webdriver mouse event", .{ .err = err, .type = typ });
        return false;
    };
    return frame._event_manager.dispatchCancelable(el.asEventTarget(), event.asEvent()) catch |err| {
        log.warn(.app, "webdriver dispatch", .{ .err = err, .type = typ });
        return false;
    };
}

// The action's x/y, which the caller already resolved the target from. An
// element origin makes them offsets from its center, but the faux layout has
// no center worth computing.
fn dispatchWheel(el: *Element, x: i32, y: i32, delta_x: i32, delta_y: i32, frame: *Frame) void {
    Frame.user_input.wheel(frame, el, @floatFromInt(x), @floatFromInt(y), @floatFromInt(delta_x), @floatFromInt(delta_y)) catch |err| {
        log.warn(.app, "webdriver wheel", .{ .err = err });
    };
}

fn dispatch(target: *EventTarget, event: *Event, frame: *Frame, typ: []const u8) void {
    frame._event_manager.dispatch(target, event) catch |err| {
        log.warn(.app, "webdriver dispatch", .{ .err = err, .type = typ });
    };
}

fn dispatchTouch(el: *Element, comptime typ: []const u8, frame: *Frame) void {
    const owner = el.ownerFrame(frame) orelse return;
    const event = TouchEvent.initTrusted(typ, .{
        .bubbles = true,
        .composed = true,
    }, owner) catch |err| {
        log.warn(.app, "webdriver touch event", .{ .err = err });
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
