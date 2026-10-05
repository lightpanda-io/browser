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

// Synthetic user input driving the DOM: mouse, wheel, keyboard, focus
// navigation and text insertion. These are mostly fed by CDP's Input domain
// (src/server/cdp/domains/input.zig) and by EventManager's default activation
// behavior. Form submission itself lives on the Frame (it's a navigation
// concern); the activation paths here call into it.

const std = @import("std");
const lp = @import("lightpanda");

const Frame = @import("../Frame.zig");
const js = @import("../js/js.zig");

const Node = @import("../webapi/Node.zig");
const Event = @import("../webapi/Event.zig");
const Element = @import("../webapi/Element.zig");
const TreeWalker = @import("../webapi/TreeWalker.zig");
const TextEvent = @import("../webapi/event/TextEvent.zig");
const InputEvent = @import("../webapi/event/InputEvent.zig");
const MouseEvent = @import("../webapi/event/MouseEvent.zig");
const TouchEvent = @import("../webapi/event/TouchEvent.zig");
const WheelEvent = @import("../webapi/event/WheelEvent.zig");
const PointerEvent = @import("../webapi/event/PointerEvent.zig");
const KeyboardEvent = @import("../webapi/event/KeyboardEvent.zig");

const log = lp.log;

// DOM MouseEvent.button values.
// https://developer.mozilla.org/en-US/docs/Web/API/MouseEvent/button
pub const mouse_button = struct {
    pub const main: i32 = 0; // left
    pub const auxiliary: i32 = 1; // middle
    pub const secondary: i32 = 2; // right
    pub const fourth: i32 = 3; // back
    pub const fifth: i32 = 4; // forward
};

const HoverContext = struct {
    x: f64 = 0,
    y: f64 = 0,
    buttons: u16 = 0,
    modifiers: Modifiers = .{},
    with_pointer: bool = true,
};

// Update the element being hovered. The page always tracks the currently
// hovered item so that trasitions can fire the correct events. e.g. mouseout
// bubbles up normally, but mouseleave will only fire on parents where the new
// target isn't part of.
pub fn updateHoverTarget(frame: *Frame, to: ?*Element, ctx: HoverContext) void {
    const page = frame.page;
    const from = page.input_hover_target;
    if (from == to) {
        return;
    }
    page.input_hover_target = to;

    const pivot: ?*Node = blk: {
        const a = from orelse break :blk null;
        const b = to orelse break :blk null;
        break :blk commonAncestor(a.asNode(), b.asNode());
    };

    if (from) |old| {
        dispatchBoundaryEvent(frame, old, "mouseout", "pointerout", to, true, ctx);
        var current: ?*Node = old.asNode();
        while (current) |node| : (current = node.parentNode()) {
            if (node == pivot) {
                break;
            }
            if (node.is(Element)) |element| {
                dispatchBoundaryEvent(frame, element, "mouseleave", "pointerleave", to, false, ctx);
            }
        }
    }

    if (to) |new| {
        dispatchBoundaryEvent(frame, new, "mouseover", "pointerover", from, true, ctx);

        // Enter fires outermost-first. The chain is walked without allocating:
        // count the elements between the target and the pivot, then re-walk to
        // reach each one from the deepest ancestor down.
        var count: usize = 0;
        var current: ?*Node = new.asNode();
        while (current) |node| : (current = node.parentNode()) {
            if (node == pivot) {
                break;
            }
            if (node.is(Element) != null) {
                count += 1;
            }
        }
        while (count > 0) : (count -= 1) {
            var remaining = count;
            current = new.asNode();
            while (current) |node| : (current = node.parentNode()) {
                const element = node.is(Element) orelse continue;
                remaining -= 1;
                if (remaining == 0) {
                    dispatchBoundaryEvent(frame, element, "mouseenter", "pointerenter", from, false, ctx);
                    break;
                }
            }
        }
    }
}

// Fire a pointer/mouse event pair, e.g. pointerout + mouseout
fn dispatchBoundaryEvent(frame: *Frame, target: *Element, comptime mouse_typ: []const u8, comptime pointer_typ: []const u8, related: ?*Element, bubbling: bool, ctx: HoverContext) void {
    const modifiers = ctx.modifiers;
    const related_target = if (related) |r| r.asEventTarget() else null;

    if (ctx.with_pointer) {
        const pointer_event = PointerEvent.initTrusted(pointer_typ, .{
            .bubbles = bubbling,
            .cancelable = bubbling,
            .composed = bubbling,
            .clientX = ctx.x,
            .clientY = ctx.y,
            // No button changed state: https://www.w3.org/TR/pointerevents3/#the-button-property
            .button = -1,
            .buttons = ctx.buttons,
            .pointerId = 1,
            .pointerType = "mouse",
            .isPrimary = true,
            .relatedTarget = related_target,
            .ctrlKey = modifiers.ctrl,
            .shiftKey = modifiers.shift,
            .altKey = modifiers.alt,
            .metaKey = modifiers.meta,
        }, frame) catch |err| {
            log.debug(.frame, "boundary pointer event", .{ .err = err, .type = pointer_typ });
            return;
        };
        frame._event_manager.dispatch(target.asEventTarget(), pointer_event.asEvent()) catch |err| {
            log.debug(.frame, "boundary pointer dispatch", .{ .err = err, .type = pointer_typ });
        };
    }

    const mouse_event = MouseEvent.initTrusted(comptime .wrap(mouse_typ), .{
        .bubbles = bubbling,
        .cancelable = bubbling,
        .composed = bubbling,
        .clientX = ctx.x,
        .clientY = ctx.y,
        .buttons = ctx.buttons,
        .relatedTarget = related_target,
        .ctrlKey = modifiers.ctrl,
        .shiftKey = modifiers.shift,
        .altKey = modifiers.alt,
        .metaKey = modifiers.meta,
    }, frame) catch |err| {
        log.debug(.frame, "boundary mouse event", .{ .err = err, .type = mouse_typ });
        return;
    };
    frame._event_manager.dispatch(target.asEventTarget(), mouse_event.asEvent()) catch |err| {
        log.debug(.frame, "boundary mouse dispatch", .{ .err = err, .type = mouse_typ });
    };
}

const Gesture = struct {
    button: i32 = mouse_button.main,
    buttons_down: u16 = 0,
    click_count: u32 = 0,
    x: f64 = 0,
    y: f64 = 0,
    modifiers: Modifiers = .{},
    emit_mouse_compat: bool = true,
};

/// Dispatch a trusted pointer event; returns whether preventDefault() cancelled it.
fn emitPointer(
    frame: *Frame,
    target: *Element,
    typ: []const u8,
    g: Gesture,
    detail: u32,
) !bool {
    const owner = target.ownerFrame(frame) orelse frame;
    const event: *PointerEvent = try .initTrusted(typ, .{
        .bubbles = true,
        .cancelable = true,
        .composed = true,
        .clientX = g.x,
        .clientY = g.y,
        .button = g.button,
        .buttons = g.buttons_down,
        .detail = detail,
        .pointerId = 1,
        .pointerType = "mouse",
        .isPrimary = true,
        .pressure = if (g.buttons_down != 0) 0.5 else 0.0,
        .ctrlKey = g.modifiers.ctrl,
        .shiftKey = g.modifiers.shift,
        .altKey = g.modifiers.alt,
        .metaKey = g.modifiers.meta,
    }, owner);
    return owner._event_manager.dispatchCancelable(target.asEventTarget(), event.asEvent());
}

/// Dispatch a trusted mouse event; returns whether preventDefault() cancelled it.
fn emitMouse(
    frame: *Frame,
    target: *Element,
    comptime typ: []const u8,
    g: Gesture,
    detail: u32,
) !bool {
    const owner = target.ownerFrame(frame) orelse frame;
    const event: *MouseEvent = try .initTrusted(comptime .wrap(typ), .{
        .bubbles = true,
        .cancelable = true,
        .composed = true,
        .clientX = g.x,
        .clientY = g.y,
        .button = g.button,
        .buttons = g.buttons_down,
        .detail = detail,
        .ctrlKey = g.modifiers.ctrl,
        .shiftKey = g.modifiers.shift,
        .altKey = g.modifiers.alt,
        .metaKey = g.modifiers.meta,
    }, owner);
    return owner._event_manager.dispatchCancelable(target.asEventTarget(), event.asEvent());
}

/// MouseEvent/PointerEvent.buttons bitmask for a MouseEvent.button value.
/// https://developer.mozilla.org/en-US/docs/Web/API/MouseEvent/buttons
fn buttonsBitmask(button: i32) u16 {
    return switch (button) {
        mouse_button.main => 1,
        mouse_button.secondary => 2,
        mouse_button.auxiliary => 4,
        mouse_button.fourth => 8,
        mouse_button.fifth => 16,
        else => 0,
    };
}

/// Held-button mask and suppression flag for the single synthetic mouse
/// pointer, tracked across the split press/release messages of one gesture so
/// a chord is told apart from a new gesture.
pub const PointerButtons = struct {
    /// Mask of buttons currently held.
    held: u16 = 0,
    /// Whether the gesture's opening pointerdown suppressed the compat mouse
    /// events; held for the whole gesture so each split message reads it here.
    mousedown_suppressed: bool = false,
    /// Where the gesture's pointerdown landed, until its first release fires
    /// the gesture's one click.
    down_target: ?*Element = null,

    /// `g.buttons_down` is ignored: the held mask supplies it.
    pub fn press(self: *PointerButtons, frame: *Frame, target: *Element, g: Gesture) !void {
        const bit = buttonsBitmask(g.button);
        const starts_gesture = self.held & ~bit == 0;
        if (starts_gesture) {
            self.down_target = target;
        }
        self.held |= bit;

        var pg = g;
        pg.buttons_down = self.held;
        const suppressed = try pressSequence(frame, target, pg, self.mousedown_suppressed);
        if (starts_gesture) {
            self.mousedown_suppressed = suppressed;
        }
    }

    /// Returns the element the click fired at, if any. `g.buttons_down` is
    /// ignored: the held mask supplies it.
    pub fn release(self: *PointerButtons, frame: *Frame, target: *Element, g: Gesture) !?*Element {
        const click_target = if (self.down_target) |down| commonClickTarget(down, target) else null;
        const was_suppressed = self.mousedown_suppressed;
        self.down_target = null;
        self.releaseButton(g.button);

        var rg = g;
        rg.buttons_down = self.held;
        try releaseSequence(frame, target, rg, was_suppressed, click_target);
        return click_target;
    }

    /// The last held button releasing ends the gesture and clears its state.
    fn releaseButton(self: *PointerButtons, button: i32) void {
        self.held &= ~buttonsBitmask(button);
        if (self.held == 0) {
            self.mousedown_suppressed = false;
            self.down_target = null;
        }
    }

    /// Discards an in-progress gesture (a press that hit no element).
    pub fn reset(self: *PointerButtons) void {
        self.* = .{};
    }
};

fn commonAncestor(a: *Node, b: *Node) ?*Node {
    var current: ?*Node = a;
    while (current) |node| : (current = node.parentNode()) {
        if (node.contains(b)) {
            return node;
        }
    }
    return null;
}

/// A click whose mousedown and mouseup landed on different elements fires at
/// their nearest common inclusive ancestor element.
fn commonClickTarget(down: *Element, up: *Element) *Element {
    if (down == up) {
        return up;
    }
    const ancestor = commonAncestor(down.asNode(), up.asNode()) orelse return up;
    return ancestor.is(Element) orelse up;
}

pub fn moveSequence(frame: *Frame, target: *Element, g: Gesture) !void {
    if (g.emit_mouse_compat) {
        updateHoverTarget(frame, target, .{ .x = g.x, .y = g.y, .buttons = g.buttons_down, .modifiers = g.modifiers });
    }
    // A move changes no button: https://www.w3.org/TR/pointerevents3/#the-button-property
    var pg = g;
    pg.button = -1;
    _ = try emitPointer(frame, target, "pointermove", pg, 0);
    if (g.emit_mouse_compat) {
        _ = try emitMouse(frame, target, "mousemove", g, 0);
    }
}

/// Returns whether the gesture's compat mouse events are suppressed: by the
/// opening pointerdown, or for a chorded press, `chord_suppressed` carried over.
fn pressSequence(frame: *Frame, target: *Element, g: Gesture, chord_suppressed: bool) !bool {
    const starts_gesture = (g.buttons_down & ~buttonsBitmask(g.button)) == 0;
    // A chorded press is a buttons-mask change (pointermove), not a second
    // pointerdown: https://www.w3.org/TR/pointerevents3/#chorded-button-interactions
    const suppressed = if (starts_gesture)
        try emitPointer(frame, target, "pointerdown", g, 0)
    else blk: {
        _ = try emitPointer(frame, target, "pointermove", g, 0);
        break :blk chord_suppressed;
    };
    if (!g.emit_mouse_compat) {
        return suppressed;
    }

    // A disabled control gets the pointer events, contextmenu and auxclick,
    // but no mouse events, click or focus, as in Chrome.
    if (!suppressed and !target.isDisabled() and !try emitMouse(frame, target, "mousedown", g, g.click_count)) {
        focusForMouseDown(frame, target) catch |err| log.debug(.app, "mousedown focus", .{ .err = err });
    }
    // Chrome on Linux and macOS fires contextmenu on press, even when the
    // pointerdown was cancelled.
    if (g.button == mouse_button.secondary) {
        _ = try emitPointer(frame, target, "contextmenu", g, 0);
    }
    return suppressed;
}

/// A null `click_target` releases without a click, as for a later release in
/// a chord.
fn releaseSequence(frame: *Frame, up_target: *Element, g: Gesture, suppressed: bool, click_target: ?*Element) !void {
    _ = try emitPointer(frame, up_target, if (g.buttons_down == 0) "pointerup" else "pointermove", g, 0);
    if (g.emit_mouse_compat and !suppressed and !up_target.isDisabled()) {
        _ = try emitMouse(frame, up_target, "mouseup", g, g.click_count);
    }

    // clickCount 0 releases without a click, as in Chrome.
    const click_el = click_target orelse return;
    if (!g.emit_mouse_compat or g.click_count == 0) {
        return;
    }

    if (g.button == mouse_button.main) {
        if (click_el.isDisabled()) {
            return;
        }
        _ = try emitPointer(frame, click_el, "click", g, g.click_count);
        if (g.click_count % 2 == 0) {
            _ = try emitMouse(frame, click_el, "dblclick", g, g.click_count);
        }
    } else {
        _ = try emitPointer(frame, click_el, "auxclick", g, g.click_count);
    }
}

/// The trusted primary-button gesture a real user click produces; widgets key
/// off pointerdown/mousedown, not click alone. A focus failure is logged, not
/// returned.
pub fn triggerClick(frame: *Frame, target: *Element, modifiers: Modifiers) !void {
    try moveSequence(frame, target, .{ .modifiers = modifiers });

    const g: Gesture = .{ .click_count = 1, .modifiers = modifiers };
    var pointer: PointerButtons = .{};
    try pointer.press(frame, target, g);
    _ = try pointer.release(frame, target, g);
}

pub fn triggerMousePress(frame: *Frame, x: f64, y: f64, button: i32, click_count: i32) !void {
    const target = (try frame.window._document.elementFromPoint(x, y, frame)) orelse {
        // Don't leave a prior gesture's state for the next message to misread.
        frame.page.input_pointer.reset();
        return;
    };
    if (comptime lp.IS_DEBUG) {
        log.debug(.frame, "frame mouse press", .{
            .url = frame.url,
            .node = target,
            .x = x,
            .y = y,
            .button = button,
            .type = frame._type,
        });
    }

    try frame.page.input_pointer.press(frame, target, .{
        .button = button,
        // clickCount 0 (omitted) stays 0, not forced to 1: Chrome and Firefox
        // both fire mousedown with detail 0 in that case.
        .click_count = if (click_count > 0) @intCast(click_count) else 0,
        .x = x,
        .y = y,
    });
}

pub fn triggerMouseMove(frame: *Frame, x: f64, y: f64) !void {
    const target = (try frame.window._document.elementFromPoint(x, y, frame)) orelse return;
    if (comptime lp.IS_DEBUG) {
        log.debug(.frame, "frame mouse move", .{
            .url = frame.url,
            .node = target,
            .x = x,
            .y = y,
            .type = frame._type,
        });
    }

    try moveSequence(frame, target, .{ .buttons_down = frame.page.input_pointer.held, .x = x, .y = y });
}

pub fn triggerMouseRelease(frame: *Frame, x: f64, y: f64, button: i32, click_count: i32) !void {
    const pointer = &frame.page.input_pointer;
    // A release that misses every element still lets go of the button, so
    // the next message doesn't read it as held.
    const hit = frame.window._document.elementFromPoint(x, y, frame) catch |err| {
        pointer.releaseButton(button);
        return err;
    };
    const target = hit orelse {
        pointer.releaseButton(button);
        return;
    };
    if (comptime lp.IS_DEBUG) {
        log.debug(.frame, "frame mouse release", .{
            .url = frame.url,
            .node = target,
            .x = x,
            .y = y,
            .button = button,
            .type = frame._type,
        });
    }

    _ = try pointer.release(frame, target, .{
        .button = button,
        .click_count = if (click_count > 0) @intCast(click_count) else 0,
        .x = x,
        .y = y,
    });
}

pub fn triggerMouseWheel(frame: *Frame, x: f64, y: f64, delta_x: f64, delta_y: f64) !void {
    const document = frame.window._document;
    const target = (try document.elementFromPoint(x, y, frame)) orelse
        document.getDocumentElement() orelse return;
    if (comptime lp.IS_DEBUG) {
        log.debug(.frame, "frame mouse wheel", .{
            .url = frame.url,
            .node = target,
            .x = x,
            .y = y,
            .delta_x = delta_x,
            .delta_y = delta_y,
            .type = frame._type,
        });
    }

    try wheel(frame, target, x, y, delta_x, delta_y);
}

/// A wheel over `target`: a trusted `wheel`, then the scroll unless it was
/// canceled. The event manager retypes it as Blink's legacy `mousewheel` for
/// targets listening only to that, and makes it cancelable only while a
/// listener on its dispatch path is non-passive.
pub fn wheel(frame: *Frame, target: *Element, x: f64, y: f64, delta_x: f64, delta_y: f64) !void {
    // Listeners live in the event manager of the element's own frame, which
    // is not the caller's when the element belongs to an iframe's document.
    const owner = target.ownerFrame(frame) orelse return;

    const event: *WheelEvent = try .initTrusted("wheel", .{
        .bubbles = true,
        .composed = true,
        .clientX = x,
        .clientY = y,
        .deltaX = delta_x,
        .deltaY = delta_y,
    }, owner);
    event.asEvent()._cancelable_unless_passive = true;
    if (try owner._event_manager.dispatchCancelable(target.asEventTarget(), event.asEvent())) {
        return;
    }

    // Deltas come from the wire, so guard NaN and saturate the addition.
    try scrollAxis(target, .width, deltaToScroll(delta_x), owner);
    try scrollAxis(target, .height, deltaToScroll(delta_y), owner);
}

/// A wheel latches to a single scroller and a delta is never split across two,
/// as in Chrome's FindNodeToLatch (cc/input/input_handler.cc): the whole delta
/// goes to the nearest ancestor-or-self container that can still move along
/// this axis. One whose overscroll-behavior doesn't propagate takes the latch
/// even when it can't move, which ends the walk.
fn scrollAxis(target: *Element, comptime axis: Element.Axis, delta: i32, frame: *Frame) !void {
    if (delta == 0) {
        return;
    }
    const axes: Element.ScrollAxes = switch (axis) {
        .width => .{ .x = true },
        .height => .{ .y = true },
    };

    var current: ?*Element = target;
    while (current) |el| {
        const container = switch (el.scrollContainer(axes, frame)) {
            .container => |c| c,
            .viewport => break,
        };
        if (try container.scrollByAxis(axis, delta, frame)) {
            return;
        }
        if (container.containsOverscroll(axes, frame)) {
            return;
        }
        current = container.parentElement();
    }

    const opts: Element.ScrollToOpts = switch (axis) {
        .width => .{ .opts = .{ .left = delta } },
        .height => .{ .opts = .{ .top = delta } },
    };
    return frame.window.scrollBy(opts, null, frame);
}

fn deltaToScroll(d: f64) i32 {
    if (std.math.isNan(d)) return 0;
    return @trunc(std.math.clamp(d, std.math.minInt(i32), std.math.maxInt(i32)));
}

/// One contact as the client described it. The id is whatever the client
/// picked on touchstart (Puppeteer counts up from 1; a bare CDP call with no
/// id defaults to 0). The radius, angle and force defaults are Chrome's for a
/// point that leaves them out, and Puppeteer overrides all three per tap.
pub const TouchPoint = struct {
    x: f64,
    y: f64,
    identifier: i32 = 0,
    radius_x: f64 = 1,
    radius_y: f64 = 1,
    rotation_angle: f64 = 0,
    force: f64 = 1,
};

/// The CDP-tracked touch contact. Single-touch scope: at most one.
pub const TouchContact = struct {
    target: *Element,
    point: TouchPoint,
    start: TouchPoint,
    pointer_id: i32,
    suppress_mouse: bool = false,
    suppress_click: bool = false,
};

pub const TouchType = enum {
    touchstart,
    touchmove,
    touchend,
    touchcancel,

    fn name(self: TouchType) []const u8 {
        return @tagName(self);
    }

    fn isLift(self: TouchType) bool {
        return self == .touchend or self == .touchcancel;
    }
};

/// The caller supplies the target (no hit-test), so touchmove/touchend/
/// touchcancel can stay pinned to the touchstart element instead of
/// re-resolving at the current point.
pub fn dispatchTouchEventOn(frame: *Frame, target: *Element, typ: TouchType, point: TouchPoint, modifiers: Modifiers) !void {
    _ = try dispatchTouchEventCancelable(frame, target, typ, point, modifiers);
}

fn dispatchTouchEventCancelable(frame: *Frame, target: *Element, typ: TouchType, point: TouchPoint, modifiers: Modifiers) !bool {
    const active = !typ.isLift();

    const event: *TouchEvent = try .initTrustedWithTouch(typ.name(), .{
        .bubbles = true,
        .composed = true,
        .altKey = modifiers.alt,
        .ctrlKey = modifiers.ctrl,
        .metaKey = modifiers.meta,
        .shiftKey = modifiers.shift,
    }, .{
        .identifier = point.identifier,
        .target = target,
        .clientX = point.x,
        .clientY = point.y,
        .radiusX = point.radius_x,
        .radiusY = point.radius_y,
        .rotationAngle = point.rotation_angle,
        .force = point.force,
    }, active, frame);

    // touchcancel is never cancelable per spec; the others follow the same
    // passive-listener-dependent rule as wheel (see EventManager).
    if (typ != .touchcancel) {
        event.asEvent()._cancelable_unless_passive = true;
    }

    return frame._event_manager.dispatchCancelable(target.asEventTarget(), event.asEvent());
}

fn dispatchTouchPointerEventOn(frame: *Frame, target: *Element, comptime typ: []const u8, contact: TouchContact, point: TouchPoint, modifiers: Modifiers, cancelled: bool) !bool {
    const lift = comptime std.mem.eql(u8, typ, "pointerup") or std.mem.eql(u8, typ, "pointercancel") or
        std.mem.eql(u8, typ, "pointerout") or std.mem.eql(u8, typ, "pointerleave") or std.mem.eql(u8, typ, "click");
    const boundary = comptime std.mem.eql(u8, typ, "pointerenter") or std.mem.eql(u8, typ, "pointerleave");
    const event: *PointerEvent = try .initTrusted(typ, .{
        .bubbles = !boundary,
        .cancelable = !boundary and !comptime std.mem.eql(u8, typ, "pointercancel"),
        .composed = !boundary,
        .clientX = point.x,
        .clientY = point.y,
        .button = if (cancelled or comptime std.mem.eql(u8, typ, "pointermove")) -1 else mouse_button.main,
        .buttons = if (lift) 0 else 1,
        .detail = if (comptime std.mem.eql(u8, typ, "click")) 1 else 0,
        .pointerId = contact.pointer_id,
        .pointerType = "touch",
        .isPrimary = true,
        .width = if (lift and !cancelled) 1 else point.radius_x * 2,
        .height = if (lift and !cancelled) 1 else point.radius_y * 2,
        .pressure = if (lift) 0 else point.force,
        .ctrlKey = modifiers.ctrl,
        .shiftKey = modifiers.shift,
        .altKey = modifiers.alt,
        .metaKey = modifiers.meta,
    }, frame);
    return frame._event_manager.dispatchCancelable(target.asEventTarget(), event.asEvent());
}

fn dispatchTouchPointerEnter(frame: *Frame, contact: TouchContact, modifiers: Modifiers) !void {
    _ = try dispatchTouchPointerEventOn(frame, contact.target, "pointerover", contact, contact.point, modifiers, false);
    var count: usize = 0;
    var current: ?*Node = contact.target.asNode();
    while (current) |node| : (current = node.parentNode()) {
        if (node.is(Element) != null) count += 1;
    }
    while (count > 0) : (count -= 1) {
        var remaining = count;
        current = contact.target.asNode();
        while (current) |node| : (current = node.parentNode()) {
            const element = node.is(Element) orelse continue;
            remaining -= 1;
            if (remaining == 0) {
                _ = try dispatchTouchPointerEventOn(frame, element, "pointerenter", contact, contact.point, modifiers, false);
                break;
            }
        }
    }
}

fn dispatchTouchPointerLeave(frame: *Frame, contact: TouchContact, point: TouchPoint, modifiers: Modifiers, cancelled: bool) !void {
    _ = try dispatchTouchPointerEventOn(frame, contact.target, "pointerout", contact, point, modifiers, cancelled);
    var current: ?*Node = contact.target.asNode();
    while (current) |node| : (current = node.parentNode()) {
        const element = node.is(Element) orelse continue;
        _ = try dispatchTouchPointerEventOn(frame, element, "pointerleave", contact, point, modifiers, cancelled);
    }
}

pub fn hasActiveTouch(frame: *Frame) bool {
    return frame.page.input_touch_contact != null;
}

/// When the point misses every element (e.g. past the end of a short faux
/// layout), fall back to the document element rather than dropping the
/// contact silently, the same fallback WebDriver's pointerMove uses.
pub fn triggerTouch(frame: *Frame, typ: TouchType, point: TouchPoint, modifiers: Modifiers) !void {
    const page = frame.page;
    const pinned = if (typ == .touchstart) null else if (page.input_touch_contact) |c| c.target else null;
    const resolved = pinned orelse
        (try frame.window._document.elementFromPoint(point.x, point.y, frame)) orelse
        frame.window._document.getDocumentElement() orelse return;
    if (comptime lp.IS_DEBUG) {
        log.debug(.frame, "frame touch", .{
            .url = frame.url,
            .node = resolved,
            .x = point.x,
            .y = point.y,
            .type = frame._type,
        });
    }
    var contact: TouchContact = if (typ == .touchstart) .{
        .target = resolved,
        .point = point,
        .start = point,
        .pointer_id = page.input_touch_next_pointer_id,
    } else page.input_touch_contact orelse return;
    contact.point = point;
    if (typ == .touchstart) {
        page.input_touch_next_pointer_id = if (contact.pointer_id == std.math.maxInt(i32)) 2 else contact.pointer_id + 1;
        try dispatchTouchPointerEnter(frame, contact, modifiers);
        contact.suppress_mouse = try dispatchTouchPointerEventOn(frame, resolved, "pointerdown", contact, point, modifiers, false);
    } else {
        // Keep small finger jitter tappable, but never activate after a drag.
        const dx = point.x - contact.start.x;
        const dy = point.y - contact.start.y;
        contact.suppress_click = contact.suppress_click or dx * dx + dy * dy > 15 * 15;
        _ = try dispatchTouchPointerEventOn(frame, resolved, "pointermove", contact, point, modifiers, false);
    }
    const prevented = try dispatchTouchEventCancelable(frame, resolved, typ, point, modifiers);
    contact.suppress_click = contact.suppress_click or prevented;
    page.input_touch_contact = contact;
}

/// Playwright sends an empty touchPoints list, so there's nowhere to read a
/// release position from but the stored contact. Puppeteer sends the point
/// being released, and Chrome dispatches at that wire position rather than
/// the last-seen one, so `point` (when given) wins over the stored
/// coordinates.
pub fn triggerTouchLift(frame: *Frame, typ: TouchType, point: ?TouchPoint, modifiers: Modifiers) !void {
    const contact = frame.page.input_touch_contact orelse return;
    // Consume the state before the fallible dispatch, so a dispatch that
    // fails partway through (e.g. a listener throws) can't leave a stale
    // contact that locks out every future touchStart for this page.
    frame.page.input_touch_contact = null;
    // The lift keeps the contact's id whatever the client re-sent, so a
    // released point can move the position but not rename the contact.
    var lift = point orelse contact.point;
    lift.identifier = contact.point.identifier;
    if (typ == .touchcancel) {
        _ = try dispatchTouchPointerEventOn(frame, contact.target, "pointercancel", contact, lift, modifiers, true);
    } else {
        _ = try dispatchTouchPointerEventOn(frame, contact.target, "pointerup", contact, lift, modifiers, false);
    }
    try dispatchTouchPointerLeave(frame, contact, lift, modifiers, typ == .touchcancel);
    const prevented = try dispatchTouchEventCancelable(frame, contact.target, typ, lift, modifiers);
    if (typ == .touchcancel or contact.suppress_click or prevented) return;

    // Compatibility mouse events use the release hit-test, after touchend
    // listeners have had a chance to change the DOM. Pointer/touch delivery
    // above remains pinned to the original contact target.
    const document = frame.window._document;
    var target = (try document.elementFromPoint(lift.x, lift.y, frame)) orelse return;
    updateHoverTarget(frame, target, .{ .x = lift.x, .y = lift.y, .modifiers = modifiers, .with_pointer = false });
    if (!contact.suppress_mouse) {
        // Hover and move listeners can replace the element before the press.
        target = (try document.elementFromPoint(lift.x, lift.y, frame)) orelse return;
        _ = try emitMouse(frame, target, "mousemove", .{ .x = lift.x, .y = lift.y, .modifiers = modifiers }, 0);
        const down_target = (try document.elementFromPoint(lift.x, lift.y, frame)) orelse return;
        if (down_target.isDisabled()) return;
        const suppress_focus = try emitMouse(frame, down_target, "mousedown", .{ .x = lift.x, .y = lift.y, .buttons_down = 1, .modifiers = modifiers }, 1);
        if (!suppress_focus and down_target.asNode().isConnected() and !down_target.isDisabled()) {
            try focusForMouseDown(frame, down_target);
        }

        // Mousedown and focus/blur handlers may have removed or moved the
        // pressed control. Release at the current hit-test, then click only
        // the common ancestor of the connected press and release targets.
        const up_target = (try document.elementFromPoint(lift.x, lift.y, frame)) orelse return;
        if (up_target.isDisabled()) return;
        var click_target: ?*Element = null;
        if (down_target.asNode().isConnected()) {
            var current: ?*Node = down_target.asNode();
            while (current) |node| : (current = node.parentNode()) {
                if (node.contains(up_target.asNode())) {
                    click_target = node.is(Element);
                    break;
                }
            }
        }
        _ = try emitMouse(frame, up_target, "mouseup", .{ .x = lift.x, .y = lift.y, .modifiers = modifiers }, 1);
        // Chrome retains the selected click target if mouseup removes it.
        target = click_target orelse return;
    }
    // Recheck after mouseup too: disabling a control suppresses activation,
    // including when pointerdown suppressed the compatibility mouse events.
    if (target.isDisabled()) return;
    _ = try dispatchTouchPointerEventOn(frame, target, "click", contact, lift, modifiers, false);
}

/// Whether the element has a click activation behavior that handleClick
/// implements.
fn hasClickActivationBehavior(node: *Node) bool {
    const element = node.is(Element) orelse return false;

    const html_element = element.is(Element.Html) orelse return element.isSvgLink();

    return switch (html_element._type) {
        .anchor => element.getAttributeInterned("href") != null,
        .input, .button, .select, .textarea, .label => true,
        .generic => html_element.subtype(Element.Html.Generic)._tag == .summary,
        else => false,
    };
}

// Clicks on editable content are for editing: they don't activate the
// element or any enclosing link.
fn isEditingHost(node: *Node) bool {
    const element = node.is(Element) orelse return false;
    return element.isEditingHost();
}

fn outermostEditingHost(target: *Element) ?*Element {
    var host: ?*Element = null;
    var current: ?*Element = target;
    while (current) |el| : (current = el.parentElement()) {
        if (el.getAttributeInterned("contenteditable") == null) {
            continue;
        }
        if (el.isEditingHost() == false) {
            break;
        }
        host = el;
    }
    return host;
}

/// Mousedown default action. A mousedown outside any focusable element moves
/// focus to the body.
pub fn focusForMouseDown(frame: *Frame, target: *Element) !void {
    if (outermostEditingHost(target)) |host| {
        try host.focus(frame);
        return;
    }

    var node: ?*Node = target.asNode();
    while (node) |n| : (node = n._parent) {
        const el = n.is(Element) orelse continue;
        // Unlike sequential focus navigation, a negative tabindex is still
        // mouse-focusable, so any focusable area qualifies.
        if (el.focusTabIndex() != null) {
            try el.focus(frame);
            return;
        }
    }

    const doc = target.asNode().ownerDocument(frame) orelse frame.document;
    if (doc._active_element) |active| {
        try active.blur(frame);
    }
}

// Per the DOM dispatch algorithm, a click's activation target is the event
// target itself when it has activation behavior, otherwise — for bubbling
// events only — the nearest ancestor that has one.
pub fn findClickActivationTarget(target: *Node, bubbles: bool) ?*Node {
    if (isEditingHost(target)) {
        return null;
    }
    if (hasClickActivationBehavior(target)) {
        return target;
    }
    if (!bubbles) {
        return null;
    }
    var node = target._parent;
    while (node) |n| : (node = n._parent) {
        if (isEditingHost(n)) {
            return null;
        }
        if (hasClickActivationBehavior(n)) {
            return n;
        }
    }
    return null;
}

fn runJavascriptUrl(frame: *Frame, source: []const u8) !void {
    const arena = try frame.getArena(.tiny, "javascript-url");
    errdefer arena.release();

    const task = try arena.create(JavascriptUrlTask);
    task.* = .{
        .frame = frame,
        .arena = arena,
        // TODO: the URL body should be percent-decoded; hrefs written in
        // markup rarely are.
        .source = try arena.dupe(u8, source),
    };
    try frame.js.scheduler.add(task, JavascriptUrlTask.run, 0, .{
        .name = "javascript-url",
        .finalizer = JavascriptUrlTask.finalize,
    });
}

const JavascriptUrlTask = struct {
    frame: *Frame,
    arena: *lp.Arena,
    source: []const u8,

    fn run(ptr: *anyopaque) !?u32 {
        const self: *JavascriptUrlTask = @ptrCast(@alignCast(ptr));
        const frame = self.frame;
        defer self.deinit();

        var ls: js.Local.Scope = undefined;
        frame.js.localScope(&ls);
        defer ls.deinit();

        const script = ls.local.compile(self.source, "javascript:") catch |err| {
            log.debug(.browser, "javascript-url compile", .{ .err = err, .type = frame._type, .url = frame.url });
            return null;
        };
        _ = script.run() catch |err| {
            log.debug(.browser, "javascript-url run", .{ .err = err, .type = frame._type, .url = frame.url });
        };
        return null;
    }

    fn finalize(ptr: *anyopaque) void {
        const self: *JavascriptUrlTask = @ptrCast(@alignCast(ptr));
        self.deinit();
    }

    fn deinit(self: *JavascriptUrlTask) void {
        self.arena.release();
    }
};

// event_target is the element that was actually clicked
// target is the element that's being activated. Imagine a span inside an anchor
// the span is clicked (event_target), but it's the anchor that we're activating
// (target).
pub fn handleClick(frame: *Frame, target: *Node, event_target: *Node) !void {
    // TODO: Also support <area> elements when implement
    const element = target.is(Element) orelse return;

    if (element.is(Element.Svg.Graphics.A) != null) {
        const href = element.svgAnchorHref() orelse return;
        const target_name = element.getAttributeInterned("target") orelse "";
        return followLink(frame, target, element, href, target_name);
    }

    const html_element = element.is(Element.Html) orelse return;

    switch (html_element._type) {
        .anchor => {
            const anchor = html_element.subtype(Element.Html.Anchor);
            const href = element.getAttributeInterned("href") orelse return;
            return followLink(frame, target, element, href, anchor.getTarget());
        },
        .input => {
            const input = html_element.subtype(Element.Html.Input);
            // Per HTML §4.10.18.6.4 "Image Button state (type=image)", clicking an
            // image button submits its form. The form-data set already gets the
            // submitter's coordinate fields appended via FormData.collectForm
            // (see src/browser/webapi/net/FormData.zig).
            if (input._input_type == .submit or input._input_type == .image) {
                return frame.submitForm(element, input.getForm(frame), .{});
            }
        },
        .button => {
            const button = html_element.subtype(Element.Html.Button);
            if (std.mem.eql(u8, button.getType(), "submit")) {
                return frame.submitForm(element, button.getForm(frame), .{});
            }
        },
        .label => {
            const label = html_element.subtype(Element.Html.Label);
            // Per HTML §4.10.4 "The label element", a label's activation
            // behavior is to run the synthetic click activation steps on the
            // labeled control. Mirrors Chrome's HTMLLabelElement::DefaultEventHandler.
            const control = label.getControl(frame) orelse return;
            if (control.asNode().contains(event_target)) {
                // label is the only control that synthesizes another click, so
                // we need to guard against that activation re-triggering the
                // label (into an infinite loop)
                return;
            }
            try control.focus(frame);
            const control_html = control.is(Element.Html) orelse return;
            try control_html.click(frame);
        },
        .generic => {
            switch (html_element.subtype(Element.Html.Generic)._tag) {
                .summary => {
                    const parent_el = target.parentElement() orelse return;
                    const details = parent_el.is(Element.Html.Details) orelse return;
                    var maybe_prev = element.previousElementSibling();
                    while (maybe_prev) |prev| {
                        if (prev.getTag() == .summary) {
                            // we found a summary element before the clicked one
                            return;
                        }
                        maybe_prev = prev.previousElementSibling();
                    }
                    try details.setOpen(!details.getOpen(), frame);
                },
                else => {},
            }
        },
        else => {},
    }
}

// Follow a link on activation. Shared by HTML <a> and SVG <a>.
fn followLink(frame: *Frame, target: *Node, element: *Element, href: []const u8, target_name: []const u8) !void {
    if (href.len == 0) {
        return;
    }

    if (std.mem.startsWith(u8, href, "javascript:")) {
        // Navigating to a javascript: URL evaluates the script in the
        // node's frame as a queued task. (A string completion value
        // would replace the document; we ignore results.)
        return runJavascriptUrl(target.ownerFrame(frame) orelse return, href["javascript:".len..]);
    }

    if (try element.hasAttribute(comptime .wrap("download"), frame)) {
        log.debug(.browser, "a.download", .{ .type = frame._type, .url = frame.url });
        return;
    }

    const target_frame = blk: {
        if (target_name.len == 0) {
            break :blk target.ownerFrame(frame) orelse return;
        }
        break :blk switch (frame.resolveTargetFrame(target_name)) {
            .frame => |f| f,
            .blank => {
                _ = try (target.ownerFrame(frame) orelse return).openBlankTarget(element, href);
                return;
            },
        };
    };

    try frame.scheduleNavigation(href, .{
        .reason = .script,
        .kind = .{ .push = null },
    }, .{ .anchor = target_frame });
}

pub fn triggerKeyDown(frame: *Frame, keydown: *KeyboardEvent, text: ?[]const u8) !bool {
    const element = focusedElement(frame) orelse {
        keydown.asEvent().deinit(frame.page);
        return false;
    };
    return pressKey(frame, element, keydown, text);
}

pub fn triggerKeyUp(frame: *Frame, keyup: *KeyboardEvent) !void {
    const element = focusedElement(frame) orelse {
        keyup.asEvent().deinit(frame.page);
        return;
    };
    try frame._event_manager.dispatch(element.asEventTarget(), keyup.asEvent());
}

/// Where a key event goes: `document.activeElement`, so with nothing focused
/// a key still fires on <body> and Tab's focus navigation can run.
pub fn focusedElement(frame: *Frame) ?*Element {
    return frame.window._document.getActiveElement();
}

/// The frame keyboard input goes to. Starting from `frame`, descend while the
/// focused element is an <iframe> with a loaded document: that iframe holds
/// the focus chain, so its document's focused element is where keys land.
pub fn focusedFrame(frame: *Frame) *Frame {
    var current = frame;
    while (current.document._active_element) |active| {
        const iframe = active.is(Element.Html.IFrame) orelse break;
        const window = iframe._window orelse break;
        current = window._frame;
    }
    return current;
}

/// Dispatches a trusted keydown on `target` then, unless cancelled, types
/// `text` (Chrome's WebKeyboardEvent.text; null when the client sends the
/// char as its own event, as chromedp does). Returns whether the keydown was
/// cancelled.
pub fn pressKey(frame: *Frame, target: *Element, keydown: *KeyboardEvent, text: ?[]const u8) !bool {
    if (comptime lp.IS_DEBUG) {
        log.debug(.frame, "frame keydown", .{
            .url = frame.url,
            .node = target,
            .key = keydown._key,
            .type = frame._type,
        });
    }
    const event = keydown.asEvent();
    const t = text orelse return frame._event_manager.dispatchCancelable(target.asEventTarget(), event);

    // dispatch drops the event; keypressFor still needs it.
    event.acquireRef();
    defer event.releaseRef(frame.page);
    if (try frame._event_manager.dispatchCancelable(target.asEventTarget(), event)) {
        return true;
    }
    // logged like a default action's failure, not the key event's
    typeChar(frame, target, try keypressFor(frame, keydown), t) catch |err| {
        log.debug(.frame, "frame.keypress", .{ .err = err });
    };
    return false;
}

/// The text a key press produces, following Chrome's WebKeyboardEvent.text: the
/// key itself when printable, "\r" for Enter, nothing when ctrl/meta turn the
/// press into a shortcut.
pub fn textForKey(keyboard_event: *const KeyboardEvent) ?[]const u8 {
    if (keyboard_event.getCtrlKey() or keyboard_event.getMetaKey()) {
        return null;
    }
    const key = keyboard_event.getKey();
    if (key == .Enter) {
        return "\r";
    }
    return if (key.isPrintable()) key.asString() else null;
}

/// The char half of a key press (Chrome's WebInputEvent::kChar): fires
/// `keypress` on `target` and, unless a listener cancels it, performs the
/// text edit it stands for.
pub fn typeChar(frame: *Frame, target: *Element, keypress: *KeyboardEvent, text: []const u8) !void {
    if (try frame._event_manager.dispatchCancelable(target.asEventTarget(), keypress.asEvent())) {
        return;
    }
    const is_enter = text.len == 1 and (text[0] == '\r' or text[0] == '\n');
    if (is_enter and isButton(target)) {
        return dispatchKeyboardClick(frame, target);
    }

    if (target.is(Element.Html.Input)) |input| {
        if (is_enter) {
            return frame.submitForm(input.asElement(), input.getForm(frame), .{});
        }
        return insertInto(frame, input, text);
    }

    if (target.is(Element.Html.TextArea)) |textarea| {
        if (is_enter) {
            if (try allowEdit(frame, textarea.asElement(), null, "\n", "insertLineBreak")) {
                try textarea.innerInsert("\n", frame);
            }
            return;
        }
        return insertInto(frame, textarea, text);
    }
}

fn keypressFor(frame: *Frame, keydown: *const KeyboardEvent) !*KeyboardEvent {
    return KeyboardEvent.initTrusted(comptime .wrap("keypress"), .{
        .key = keydown.getKey().asString(),
        .ctrlKey = keydown.getCtrlKey(),
        .shiftKey = keydown.getShiftKey(),
        .altKey = keydown.getAltKey(),
        .metaKey = keydown.getMetaKey(),
    }, frame);
}

pub fn handleKeydown(frame: *Frame, target: *Node, event: *Event) !void {
    const keyboard_event = event.is(KeyboardEvent) orelse return;
    const key = keyboard_event.getKey();

    if (key == .Dead) {
        return;
    }

    if (key == .Tab) {
        // tab -> forward, shift+tab -> backwards
        return moveFocus(frame, keyboard_event.getShiftKey() == false);
    }

    if (key == .Enter and event.getIsTrusted()) {
        if (target.is(Element)) |element| {
            if (enterFollowsLink(element)) {
                return dispatchKeyboardClick(frame, element);
            }
        }
    }

    if (target.is(Element.Html.Input)) |input| {
        if (!input.acceptsTextEntry()) {
            return;
        }
        return editKey(frame, keyboard_event, input, key);
    }

    if (target.is(Element.Html.TextArea)) |textarea| {
        return editKey(frame, keyboard_event, textarea, key);
    }
}

// edit keys other than text insertion (typeChar's) are handled by Input and
// TextArea the same
fn editKey(frame: *Frame, keyboard_event: *KeyboardEvent, ctl: anytype, key: KeyboardEvent.Key) !void {
    if (caretMove(key, ctl)) |move| {
        // Word/paragraph motions (ctrl/alt/meta variants) aren't modeled.
        if (keyboard_event.getCtrlKey() or keyboard_event.getAltKey() or keyboard_event.getMetaKey()) {
            return;
        }
        return ctl.moveCaret(move, keyboard_event.getShiftKey(), frame);
    }

    if (key == .Backspace or key == .Delete) {
        const forward = key == .Delete;
        if (!keyboard_event.asEvent().getIsTrusted() or try allowEdit(frame, ctl.asElement(), null, null, deleteInputType(forward))) {
            try ctl.innerDelete(forward, frame);
        }
    }
}

fn insertInto(frame: *Frame, ctl: anytype, text: []const u8) !void {
    if (!ctl.acceptsTextEntry()) {
        return;
    }
    if (try allowEdit(frame, ctl.asElement(), text, text, "insertText")) {
        try ctl.innerInsert(text, frame);
    }
}

// Caret movement a key's default action performs on `ctl`, if any. On a
// single-line <input> ArrowUp/ArrowDown go to the ends of the value, as in
// Chrome; on a <textarea> they would need line geometry, so they do nothing.
fn caretMove(key: KeyboardEvent.Key, ctl: anytype) ?@TypeOf(ctl.*).CaretMove {
    return switch (key) {
        .ArrowLeft => .backward,
        .ArrowRight => .forward,
        .Home => .line_start,
        .End => .line_end,
        .ArrowUp => if (@TypeOf(ctl) == *Element.Html.Input) .line_start else null,
        .ArrowDown => if (@TypeOf(ctl) == *Element.Html.Input) .line_end else null,
        else => null,
    };
}

fn deleteInputType(forward: bool) []const u8 {
    return if (forward) "deleteContentForward" else "deleteContentBackward";
}

// pre-edit events for a trusted key's default action, can cancel the edit
// (i.e. by returning false)
fn allowEdit(frame: *Frame, target: *Element, before_data: ?[]const u8, text_data: ?[]const u8, input_type: []const u8) !bool {
    {
        const before = (try InputEvent.initTrusted(comptime .wrap("beforeinput"), .{
            .bubbles = true,
            .cancelable = true,
            .composed = true,
            .data = before_data,
            .inputType = input_type,
        }, frame)).asEvent();
        if (try frame._event_manager.dispatchCancelable(target.asEventTarget(), before)) {
            return false;
        }
    }

    {
        const data = text_data orelse return true;
        const text_event = (try TextEvent.initTrusted("textInput", .{
            .bubbles = true,
            .cancelable = true,
            .view = frame.window,
            .data = data,
        }, frame)).asEvent();
        return !try frame._event_manager.dispatchCancelable(target.asEventTarget(), text_event);
    }
}

pub fn handleKeyup(frame: *Frame, target: *Node, event: *Event) !void {
    if (event.getIsTrusted() == false) {
        return;
    }
    const keyboard_event = event.is(KeyboardEvent) orelse return;
    const key = keyboard_event.getKey();

    if (key.isPrintable() == false or std.mem.eql(u8, key.asString(), " ") == false) {
        return;
    }
    const element = target.is(Element) orelse return;
    if (spaceActivates(element)) {
        // on keyup, for a trusted event and on specific element types, space
        // triggers a click-like event
        return dispatchKeyboardClick(frame, element);
    }
}

// keydown+enter or keyup+space trigger this syntthetic pointer event (under
// specific conditions, see handleKeydown and handleKeyup).
fn dispatchKeyboardClick(frame: *Frame, element: *Element) !void {
    const event = try PointerEvent.initTrusted("click", .{
        .bubbles = true,
        .cancelable = true,
        .composed = true,
        .pointerId = -1,
    }, frame);
    try frame._event_manager.dispatch(element.asEventTarget(), event.asEvent());
}

// Which elements act on which key, and at which step: a link follows Enter on
// the keydown, a button clicks on Enter's keypress (typeChar) and on Space's
// keyup, as do checkboxes and radios for Space.
fn enterFollowsLink(element: *Element) bool {
    const html_element = element.is(Element.Html) orelse return false;
    return html_element._type == .anchor and element.getAttributeInterned("href") != null;
}

fn isButton(element: *Element) bool {
    const html_element = element.is(Element.Html) orelse return false;
    if (html_element._type == .button) {
        return true;
    }
    if (element.is(Element.Html.Input)) |input| {
        return switch (input._input_type) {
            .button, .submit, .reset, .image => true,
            else => false,
        };
    }
    return false;
}

fn spaceActivates(element: *Element) bool {
    if (isButton(element)) {
        return true;
    }
    const input = element.is(Element.Html.Input) orelse return false;
    return input._input_type == .checkbox or input._input_type == .radio;
}

// Sequential focus navigation: move `document.activeElement` to the next (Tab)
// or previous (Shift+Tab) focusable element, firing the usual blur/focus events
// via `Element.focus`. The order is fully determined by tabindex + document
// position, so no layout is needed:
//   1. elements with a positive tabindex, in ascending tabindex order;
//   2. then elements with tabindex 0 (or a natively-focusable default), in
//      document order.
// Ties within a group break on document order, and Tab wraps around at the ends.
// https://html.spec.whatwg.org/multipage/interaction.html#sequential-focus-navigation
fn moveFocus(frame: *Frame, forward: bool) !void {
    const document = frame.document;
    const current = document._active_element;

    const current_tab_index = blk: {
        const cur = current orelse break :blk 0;
        const current_html = cur.is(Element.Html) orelse break :blk 0;
        break :blk current_html.getTabIndex();
    };

    // Single document-order pass tracking two candidates:
    //   edge   — the global first (forward) / last (backward) focusable element,
    //            used to wrap around when `current` is at an end, or as the
    //            landing spot when nothing is focused yet.
    //   chosen — the closest focusable element strictly past `current` in the
    //            travel direction.
    var edge: ?*Element = null;
    var edge_tab_index: i32 = 0;

    var chosen: ?*Element = null;
    var chosen_tab_index: i32 = 0;

    var tw = TreeWalker.Full.Elements.init(document.asNode(), .{});
    while (tw.next()) |candidate| {
        const candidate_tab_index = candidate.focusTabIndex() orelse continue;
        if (candidate_tab_index < 0) {
            continue;
        }

        if (edge == null or focusOrderBefore(candidate, candidate_tab_index, edge.?, edge_tab_index) == forward) {
            edge = candidate;
            edge_tab_index = candidate_tab_index;
        }

        const cur = current orelse continue;

        if (candidate == cur) {
            continue;
        }

        const past = if (forward) focusOrderBefore(cur, current_tab_index, candidate, candidate_tab_index) else focusOrderBefore(candidate, candidate_tab_index, cur, current_tab_index);
        if (!past) {
            continue;
        }
        if (chosen == null or focusOrderBefore(candidate, candidate_tab_index, chosen.?, chosen_tab_index) == forward) {
            chosen = candidate;
            chosen_tab_index = candidate_tab_index;
        }
    }

    const next = chosen orelse edge orelse return;
    try next.focus(frame);
}

// Orders two focusable elements by sequential focus navigation order: positive
// tabindex first (ascending), then tabindex 0, ties broken by document order.
fn focusOrderBefore(a: *Element, a_tab_index: i32, b: *Element, b_tab_index: i32) bool {
    if (a_tab_index == b_tab_index) {
        // Equal tabindex → document order: `a` precedes `b` when `b` follows `a`.
        const FOLLOWING: u16 = 0x04;
        return (a.asNode().compareDocumentPosition(b.asNode()) & FOLLOWING) != 0;
    }

    const group_a: u8 = if (a_tab_index > 0) 0 else 1;
    const group_b: u8 = if (b_tab_index > 0) 0 else 1;
    if (group_a != group_b) {
        return group_a < group_b;
    }

    return a_tab_index < b_tab_index;
}

/// Text input without a key press (IME, paste): beforeinput but no keypress.
pub fn insertText(frame: *Frame, v: []const u8) !void {
    const html_element = frame.document._active_element orelse return;

    if (html_element.is(Element.Html.Input)) |input| {
        return insertInto(frame, input, v);
    }

    if (html_element.is(Element.Html.TextArea)) |textarea| {
        return insertInto(frame, textarea, v);
    }
}

pub const Modifiers = struct {
    ctrl: bool = false,
    shift: bool = false,
    alt: bool = false,
    meta: bool = false,
};
