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
    // WebDriver's pointer source also fires the pointerover/out/enter/leave
    // twins; the CDP mouse path only synthesizes mouse events.
    with_pointer: bool = false,
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
        var current: ?*Node = a.asNode();
        while (current) |node| : (current = node.parentNode()) {
            if (node.contains(b.asNode())) {
                break :blk node;
            }
        }
        break :blk null;
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
            log.warn(.frame, "boundary pointer event", .{ .err = err, .type = pointer_typ });
            return;
        };
        frame._event_manager.dispatch(target.asEventTarget(), pointer_event.asEvent()) catch |err| {
            log.warn(.frame, "boundary pointer dispatch", .{ .err = err, .type = pointer_typ });
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
        log.warn(.frame, "boundary mouse event", .{ .err = err, .type = mouse_typ });
        return;
    };
    frame._event_manager.dispatch(target.asEventTarget(), mouse_event.asEvent()) catch |err| {
        log.warn(.frame, "boundary mouse dispatch", .{ .err = err, .type = mouse_typ });
    };
}

/// Event fields for the trusted mouse/pointer dispatchers, bundled so `button`
/// (which button changed) and `buttons` (the held mask) can't be transposed.
const PointerInput = struct {
    x: f64,
    y: f64,
    button: i32 = mouse_button.main,
    buttons: u16 = 0,
    detail: u32 = 0,
    modifiers: Modifiers = .{},
};

/// Dispatch a trusted mouse event; returns whether preventDefault() cancelled it.
fn dispatchMouseEventOn(frame: *Frame, target: *Element, comptime typ: []const u8, in: PointerInput) !bool {
    const event: *MouseEvent = try .initTrusted(comptime .wrap(typ), .{
        .bubbles = true,
        .cancelable = true,
        .composed = true,
        .clientX = in.x,
        .clientY = in.y,
        .button = in.button,
        .buttons = in.buttons,
        .detail = in.detail,
        .ctrlKey = in.modifiers.ctrl,
        .shiftKey = in.modifiers.shift,
        .altKey = in.modifiers.alt,
        .metaKey = in.modifiers.meta,
    }, frame);
    return frame._event_manager.dispatchCancelable(target.asEventTarget(), event.asEvent());
}

/// Dispatch a trusted pointer event (always mouse-sourced: pointerType,
/// pointerId, isPrimary fixed); returns whether preventDefault() cancelled it.
fn dispatchPointerEventOn(frame: *Frame, target: *Element, comptime typ: []const u8, in: PointerInput) !bool {
    const event: *PointerEvent = try .initTrusted(typ, .{
        .bubbles = true,
        .cancelable = true,
        .composed = true,
        .clientX = in.x,
        .clientY = in.y,
        .button = in.button,
        .buttons = in.buttons,
        .detail = in.detail,
        .pointerId = 1,
        .pointerType = "mouse",
        .isPrimary = true,
        .pressure = if (in.buttons != 0) 0.5 else 0.0,
        .ctrlKey = in.modifiers.ctrl,
        .shiftKey = in.modifiers.shift,
        .altKey = in.modifiers.alt,
        .metaKey = in.modifiers.meta,
    }, frame);
    return frame._event_manager.dispatchCancelable(target.asEventTarget(), event.asEvent());
}

/// MouseEvent/PointerEvent.buttons bitmask for a MouseEvent.button value.
/// https://developer.mozilla.org/en-US/docs/Web/API/MouseEvent/buttons
pub fn buttonsBitmask(button: i32) u16 {
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

    /// `starts_gesture` is false for a chorded press (another button held).
    pub fn press(self: *PointerButtons, button: i32) struct { starts_gesture: bool, held: u16 } {
        const bit = buttonsBitmask(button);
        const starts_gesture = self.held & ~bit == 0;
        self.held |= bit;
        return .{ .starts_gesture = starts_gesture, .held = self.held };
    }

    /// `ends_gesture` is the last held button releasing, which clears the
    /// suppression flag; `was_suppressed` is that flag for this gesture.
    pub fn release(self: *PointerButtons, button: i32) struct { ends_gesture: bool, held: u16, was_suppressed: bool } {
        const was_suppressed = self.mousedown_suppressed;
        self.held &= ~buttonsBitmask(button);
        const ends_gesture = self.held == 0;
        if (ends_gesture) self.mousedown_suppressed = false;
        return .{ .ends_gesture = ends_gesture, .held = self.held, .was_suppressed = was_suppressed };
    }

    /// Discards an in-progress gesture (a press/release that hit no element).
    pub fn reset(self: *PointerButtons) void {
        self.* = .{};
    }
};

const PressResult = struct {
    /// pointerdown's preventDefault() suppressed the compat mousedown here and
    /// the paired mouseup on release.
    suppress_mouse: bool,
    /// mousedown's focus default action is suppressed (always when
    /// suppress_mouse is).
    suppress_focus: bool,
};

/// pointerdown, then mousedown unless pointerdown was cancelled. `in.detail`
/// applies to mousedown only.
fn dispatchPointerPress(frame: *Frame, target: *Element, in: PointerInput) !PressResult {
    var pointer = in;
    pointer.detail = 0;
    const suppress_mouse = try dispatchPointerEventOn(frame, target, "pointerdown", pointer);
    if (suppress_mouse) {
        return .{ .suppress_mouse = true, .suppress_focus = true };
    }
    const suppress_focus = try dispatchMouseEventOn(frame, target, "mousedown", in);
    return .{ .suppress_mouse = false, .suppress_focus = suppress_focus };
}

/// pointerup, then mouseup unless the gesture's pointerdown was cancelled.
/// `in.detail` applies to mouseup only.
fn dispatchPointerRelease(frame: *Frame, target: *Element, in: PointerInput, suppress_mouse: bool) !void {
    var pointer = in;
    pointer.detail = 0;
    _ = try dispatchPointerEventOn(frame, target, "pointerup", pointer);
    if (suppress_mouse == false) {
        _ = try dispatchMouseEventOn(frame, target, "mouseup", in);
    }
}

/// The trusted primary-button gesture a real user click produces; widgets key
/// off pointerdown/mousedown, not click alone. A focus failure is logged, not
/// returned.
pub fn triggerClick(frame: *Frame, target: *Element, modifiers: Modifiers) !void {
    const press = try dispatchPointerPress(frame, target, .{ .x = 0, .y = 0, .buttons = 1, .detail = 1, .modifiers = modifiers });
    if (press.suppress_focus == false) {
        focusForMouseDown(frame, target) catch |err| log.warn(.app, "click mousedown focus", .{ .err = err });
    }

    const up: PointerInput = .{ .x = 0, .y = 0, .detail = 1, .modifiers = modifiers };
    try dispatchPointerRelease(frame, target, up, press.suppress_mouse);
    // click is a PointerEvent, matching HTMLElement.click().
    _ = try dispatchPointerEventOn(frame, target, "click", up);
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

    const gesture = frame.page.input_pointer.press(button);
    // clickCount 0 (omitted) stays 0, not forced to 1: Chrome and Firefox
    // both fire mousedown with detail 0 in that case.
    const detail: u32 = if (click_count > 0) @intCast(click_count) else 0;
    const in: PointerInput = .{ .x = x, .y = y, .button = button, .buttons = gesture.held, .detail = detail };

    if (gesture.starts_gesture) {
        // Stash the pointerdown outcome before the fallible focus call: the
        // release half is a separate message and can't observe it otherwise.
        const press = try dispatchPointerPress(frame, target, in);
        frame.page.input_pointer.mousedown_suppressed = press.suppress_mouse;
        if (press.suppress_focus == false) {
            try focusForMouseDown(frame, target);
        }
    } else {
        // A chorded press is a buttons-mask change (pointermove), not a second
        // pointerdown: https://www.w3.org/TR/pointerevents3/#chorded-button-interactions
        _ = try dispatchPointerEventOn(frame, target, "pointermove", .{ .x = x, .y = y, .button = button, .buttons = gesture.held });
        if (frame.page.input_pointer.mousedown_suppressed == false) {
            const suppress_focus = try dispatchMouseEventOn(frame, target, "mousedown", in);
            if (suppress_focus == false) {
                try focusForMouseDown(frame, target);
            }
        }
    }
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

    updateHoverTarget(frame, target, .{ .x = x, .y = y });

    const move_event: *MouseEvent = try .initTrusted(comptime .wrap("mousemove"), .{
        .bubbles = true,
        .cancelable = true,
        .composed = true,
        .clientX = x,
        .clientY = y,
    }, frame);
    try frame._event_manager.dispatch(target.asEventTarget(), move_event.asEvent());
}

pub fn triggerMouseRelease(frame: *Frame, x: f64, y: f64, button: i32, click_count: i32) !void {
    // Consume the state before any early return, so a release that misses
    // every element can't leave it for the next message to misread.
    const gesture = frame.page.input_pointer.release(button);
    const remaining = gesture.held;
    const ends_gesture = gesture.ends_gesture;
    const was_suppressed = gesture.was_suppressed;

    const target = (try frame.window._document.elementFromPoint(x, y, frame)) orelse return;
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

    const detail: u32 = if (click_count > 0) @intCast(click_count) else 1;

    if (ends_gesture) {
        try dispatchPointerRelease(frame, target, .{ .x = x, .y = y, .button = button, .detail = detail }, was_suppressed);
    } else {
        // A chorded release (another button still held) is a buttons-mask
        // change, not pointerup.
        _ = try dispatchPointerEventOn(frame, target, "pointermove", .{ .x = x, .y = y, .button = button, .buttons = remaining });
        if (!was_suppressed) {
            _ = try dispatchMouseEventOn(frame, target, "mouseup", .{ .x = x, .y = y, .button = button, .buttons = remaining, .detail = detail });
        }
    }

    // After mouseup, the activation event depends on the button.
    switch (button) {
        mouse_button.main => {
            _ = try dispatchPointerEventOn(frame, target, "click", .{ .x = x, .y = y, .buttons = remaining, .detail = detail });
            // A second click in quick succession also fires dblclick.
            if (click_count == 2) {
                _ = try dispatchMouseEventOn(frame, target, "dblclick", .{ .x = x, .y = y, .button = button, .buttons = remaining, .detail = detail });
            }
        },
        mouse_button.auxiliary => _ = try dispatchMouseEventOn(frame, target, "auxclick", .{ .x = x, .y = y, .button = button, .buttons = remaining, .detail = detail }),
        mouse_button.secondary => _ = try dispatchMouseEventOn(frame, target, "contextmenu", .{ .x = x, .y = y, .button = button, .buttons = remaining, .detail = detail }),
        else => {},
    }
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
    try wheelScroll(target, deltaToScroll(delta_x), deltaToScroll(delta_y), owner);
}

/// Each axis scrolls the nearest ancestor-or-self scroll container along it,
/// else the viewport. Relative deltas may land on different scrollers per
/// axis, unlike an absolute position.
fn wheelScroll(target: *Element, delta_x: i32, delta_y: i32, frame: *Frame) !void {
    // A zero delta resolves to .viewport and scrolls it by nothing.
    try target.scrollContainer(.{ .x = delta_x != 0 }, frame).scrollBy(delta_x, 0, frame);
    try target.scrollContainer(.{ .y = delta_y != 0 }, frame).scrollBy(0, delta_y, frame);
}

fn deltaToScroll(d: f64) i32 {
    if (std.math.isNan(d)) return 0;
    return @trunc(std.math.clamp(d, std.math.minInt(i32), std.math.maxInt(i32)));
}

/// Whether the element has a click activation behavior that handleClick
/// implements.
fn hasClickActivationBehavior(node: *Node) bool {
    const element = node.is(Element) orelse return false;

    const html_element = element.is(Element.Html) orelse return isSvgLink(element);

    return switch (html_element._type) {
        .anchor => element.getAttributeInterned("href") != null,
        .input, .button, .select, .textarea, .label => true,
        .generic => html_element.subtype(Element.Html.Generic)._tag == .summary,
        else => false,
    };
}

// SVG 2 <a> links via `href`; xlink:href is the deprecated SVG 1.1 spelling.
fn svgAnchorHref(element: *Element) ?[]const u8 {
    return element.getAttributeInterned("href") orelse element.getAttributeSafe(comptime .wrap("xlink:href"));
}

fn isSvgLink(element: *Element) bool {
    return element.is(Element.Svg.Graphics.A) != null and svgAnchorHref(element) != null;
}

/// Focusable without a tabindex attribute.
fn isNativelyFocusable(el: *Element) bool {
    if (el.is(Element.Html) == null) {
        return isSvgLink(el);
    }
    return switch (el.getTag()) {
        .button, .select, .textarea, .iframe => true,
        .input => el.as(Element.Html.Input)._input_type != .hidden,
        .anchor, .area => el.getAttributeInterned("href") != null,
        else => false,
    };
}

// Clicks on editable content are for editing: they don't activate the
// element or any enclosing link.
// "contenteditable" is 15 bytes — past the comptime SSO limit — so the
// String wrap runs at runtime, mirroring Html.getIsContentEditable.
fn isEditingHost(node: *Node) bool {
    const element = node.is(Element) orelse return false;
    const value = element.getAttributeSafe(.wrap("contenteditable")) orelse return false;
    return std.ascii.eqlIgnoreCase(value, "false") == false;
}

fn outermostEditingHost(target: *Element) ?*Element {
    var node: ?*Node = target.asNode();
    var editable: ?*Node = null;
    while (node) |n| : (node = n._parent) {
        if (isEditingHost(n)) {
            editable = n;
            break;
        }
    }
    var host = editable orelse return null;
    while (host._parent) |p| {
        if (!isEditingHost(p)) {
            break;
        }
        host = p;
    }
    return host.is(Element);
}

/// Unlike sequential focus, a negative tabindex is still mouse-focusable, and
/// an unparsable one counts as absent (HTML §6.6.3), not as "not focusable".
fn isMouseFocusable(el: *Element) bool {
    if (el.isDisabled()) return false;

    if (el.getAttributeInterned("tabindex")) |attr| {
        if (Element.Html.parseInteger(attr) != null) return true;
    }
    return isNativelyFocusable(el);
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
        if (isMouseFocusable(el)) {
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
            log.warn(.browser, "javascript-url compile", .{ .err = err, .type = frame._type, .url = frame.url });
            return null;
        };
        _ = script.run() catch |err| {
            log.warn(.browser, "javascript-url run", .{ .err = err, .type = frame._type, .url = frame.url });
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
        const href = svgAnchorHref(element) orelse return;
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
            try element.focus(frame);
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
            try element.focus(frame);
            if (std.mem.eql(u8, button.getType(), "submit")) {
                return frame.submitForm(element, button.getForm(frame), .{});
            }
        },
        .select, .textarea => try element.focus(frame),
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
        log.warn(.browser, "a.download", .{ .type = frame._type, .url = frame.url });
        return;
    }

    const target_frame = blk: {
        if (target_name.len == 0) {
            break :blk target.ownerFrame(frame) orelse return;
        }
        break :blk switch (frame.resolveTargetFrame(target_name)) {
            .frame => |f| f,
            .blank => {
                try element.focus(frame);
                _ = try (target.ownerFrame(frame) orelse return).openBlankTarget(element, href);
                return;
            },
        };
    };

    try element.focus(frame);
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
        log.warn(.frame, "frame.keypress", .{ .err = err });
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
        before.acquireRef(); // need to check its _prevent_default
        defer _ = before.releaseRef(frame.page);
        try frame._event_manager.dispatch(target.asEventTarget(), before);
        if (before._prevent_default) {
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
        text_event.acquireRef(); // need to check its _prevent_default
        defer _ = text_event.releaseRef(frame.page);
        try frame._event_manager.dispatch(target.asEventTarget(), text_event);
        return text_event._prevent_default == false;
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
