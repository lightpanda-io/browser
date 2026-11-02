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

const URL = @import("../URL.zig");
const Frame = @import("../Frame.zig");
const js = @import("../js/js.zig");
const dump = @import("../dump.zig");
const StyleManager = @import("../StyleManager.zig");

const Node = @import("../webapi/Node.zig");
const Event = @import("../webapi/Event.zig");
const Element = @import("../webapi/Element.zig");
const TreeWalker = @import("../webapi/TreeWalker.zig");
const TextEvent = @import("../webapi/event/TextEvent.zig");
const InputEvent = @import("../webapi/event/InputEvent.zig");
const MouseEvent = @import("../webapi/event/MouseEvent.zig");
const Touch = @import("../webapi/event/Touch.zig");
const TouchEvent = @import("../webapi/event/TouchEvent.zig");
const WheelEvent = @import("../webapi/event/WheelEvent.zig");
const PointerEvent = @import("../webapi/event/PointerEvent.zig");
const KeyboardEvent = @import("../webapi/event/KeyboardEvent.zig");
const DragEvent = @import("../webapi/event/DragEvent.zig");
const DataTransfer = @import("../webapi/DataTransfer.zig");

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

    fn offset(self: HoverContext, dx: f64, dy: f64) HoverContext {
        var ctx = self;
        ctx.x += dx;
        ctx.y += dy;
        return ctx;
    }

    fn emit(ctx: HoverContext, frame: *Frame, target: *Element, comptime suffix: []const u8, related: ?*Element, bubbling: bool) void {
        dispatchPointerBoundary(frame, target, "pointer" ++ suffix, related, bubbling, ctx);
        dispatchMouseBoundary(frame, target, "mouse" ++ suffix, related, bubbling, ctx);
    }
};

/// A touch's compatibility hover: the pointer half already fired with the
/// touch, so only the mouse half is left.
const CompatHover = struct {
    ctx: HoverContext,

    fn offset(self: CompatHover, dx: f64, dy: f64) CompatHover {
        return .{ .ctx = self.ctx.offset(dx, dy) };
    }

    fn emit(self: CompatHover, frame: *Frame, target: *Element, comptime suffix: []const u8, related: ?*Element, bubbling: bool) void {
        dispatchMouseBoundary(frame, target, "mouse" ++ suffix, related, bubbling, self.ctx);
    }
};

// Update the element being hovered. The page always tracks the currently
// hovered item so that trasitions can fire the correct events. e.g. mouseout
// bubbles up normally, but mouseleave will only fire on parents where the new
// target isn't part of.
pub fn updateHoverTarget(frame: *Frame, to: ?*Element, emitter: anytype) void {
    const page = frame.page;
    const from = page.input_hover_target;
    if (from == to) {
        return;
    }
    page.input_hover_target = to;
    const from_owner = if (from) |el| el.ownerFrame(frame) else null;
    const to_owner = if (to) |el| el.ownerFrame(frame) else null;
    if (from_owner == to_owner) {
        dispatchBoundaryEvents(frame, from, to, emitterIn(emitter, frame, to_owner));
        return;
    }

    // Each document has its own hover path. In an ancestor document, a
    // descendant's target is represented by the iframe containing it.
    var common = from_owner;
    while (common) |candidate| : (common = candidate.parent) {
        var current = to_owner;
        while (current) |owner| : (current = owner.parent) {
            if (owner == candidate) break;
        }
        if (current != null) break;
    }

    var old = from;
    var current = from_owner;
    while (current != common) {
        const owner = current orelse break;
        dispatchBoundaryEvents(frame, old, null, emitterIn(emitter, frame, owner));
        old = if (owner.iframe) |iframe| iframe.asElement() else null;
        current = owner.parent;
    }

    var new = to;
    current = to_owner;
    var depth: usize = 0;
    while (current != common) {
        const owner = current orelse break;
        new = if (owner.iframe) |iframe| iframe.asElement() else null;
        current = owner.parent;
        depth += 1;
    }
    if (common != null) dispatchBoundaryEvents(frame, old, new, emitterIn(emitter, frame, common));

    // Enter the new browsing contexts outermost first. A context crossed in
    // either direction has no relatedTarget from the other document.
    while (depth > 0) : (depth -= 1) {
        new = to;
        current = to_owner;
        var remaining = depth - 1;
        while (remaining > 0) : (remaining -= 1) {
            const owner = current orelse break;
            new = if (owner.iframe) |iframe| iframe.asElement() else null;
            current = owner.parent;
        }
        dispatchBoundaryEvents(frame, null, new, emitterIn(emitter, frame, current));
    }
}

/// `emitter`'s point is in `frame`'s viewport; boundary events in `owner`'s
/// document carry it in that document's viewport.
fn emitterIn(emitter: anytype, frame: *Frame, owner: ?*Frame) @TypeOf(emitter) {
    const doc_frame = owner orelse return emitter;
    if (doc_frame == frame) {
        return emitter;
    }
    const point = pointInFrame(frame, doc_frame, 0, 0);
    return emitter.offset(point.x, point.y);
}

/// `emitter.emit` fires one boundary event, named by its suffix ("out",
/// "leave", "over", "enter").
fn dispatchBoundaryEvents(frame: *Frame, from: ?*Element, to: ?*Element, emitter: anytype) void {
    if (from == to) return;
    const pivot: ?*Node = blk: {
        const a = from orelse break :blk null;
        const b = to orelse break :blk null;
        break :blk commonAncestor(a.asNode(), b.asNode(), frame);
    };

    if (from) |old| {
        emitter.emit(frame, old, "out", to, true);
        var current: ?*Node = old.asNode();
        while (current) |node| : (current = node.flatTreeParent(frame)) {
            if (node == pivot) {
                break;
            }
            if (node.is(Element)) |element| {
                emitter.emit(frame, element, "leave", to, false);
            }
        }
    }

    if (to) |new| {
        emitter.emit(frame, new, "over", from, true);

        // Enter fires outermost-first. The chain is walked without allocating:
        // count the elements between the target and the pivot, then re-walk to
        // reach each one from the deepest ancestor down.
        var count: usize = 0;
        var current: ?*Node = new.asNode();
        while (current) |node| : (current = node.flatTreeParent(frame)) {
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
            while (current) |node| : (current = node.flatTreeParent(frame)) {
                const element = node.is(Element) orelse continue;
                remaining -= 1;
                if (remaining == 0) {
                    emitter.emit(frame, element, "enter", from, false);
                    break;
                }
            }
        }
    }
}

fn dispatchPointerBoundary(frame: *Frame, target: *Element, comptime pointer_typ: []const u8, related: ?*Element, bubbling: bool, ctx: HoverContext) void {
    const owner = target.ownerFrame(frame) orelse return;
    if (owner.window._closed) return;
    const modifiers = ctx.modifiers;
    // Hover transitions never pair elements from different documents.
    const related_target = if (related) |r| r.asEventTarget() else null;
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
    }, owner) catch |err| {
        log.debug(.frame, "boundary pointer event", .{ .err = err, .type = pointer_typ });
        return;
    };
    owner._event_manager.dispatch(target.asEventTarget(), pointer_event.asEvent()) catch |err| {
        log.debug(.frame, "boundary pointer dispatch", .{ .err = err, .type = pointer_typ });
    };
}

fn dispatchMouseBoundary(frame: *Frame, target: *Element, comptime mouse_typ: []const u8, related: ?*Element, bubbling: bool, ctx: HoverContext) void {
    const owner = target.ownerFrame(frame) orelse return;
    if (owner.window._closed) return;
    const modifiers = ctx.modifiers;
    // Hover transitions never pair elements from different documents.
    const related_target = if (related) |r| r.asEventTarget() else null;
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
    }, owner) catch |err| {
        log.debug(.frame, "boundary mouse event", .{ .err = err, .type = mouse_typ });
        return;
    };
    owner._event_manager.dispatch(target.asEventTarget(), mouse_event.asEvent()) catch |err| {
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
    pointer_type: []const u8 = "mouse",
    pointer_id: i32 = 1,
    width: f64 = 1,
    height: f64 = 1,
    pressure: f64 = 0.5,
};

/// Dispatch a trusted pointer event; returns whether its default action is off:
/// preventDefault() cancelled it, or its frame is gone (a listener can remove
/// the iframe).
fn emitPointer(
    frame: *Frame,
    target: *Element,
    comptime typ: []const u8,
    g: Gesture,
    detail: u32,
) !bool {
    const owner = target.ownerFrame(frame) orelse frame;
    if (owner.window._closed) return true;
    const boundary = comptime std.mem.eql(u8, typ, "pointerenter") or std.mem.eql(u8, typ, "pointerleave");
    const event: *PointerEvent = try .initTrusted(typ, .{
        .bubbles = !boundary,
        .cancelable = !boundary and comptime !std.mem.eql(u8, typ, "pointercancel"),
        .composed = !boundary,
        .clientX = g.x,
        .clientY = g.y,
        .button = g.button,
        .buttons = g.buttons_down,
        .detail = detail,
        .pointerId = g.pointer_id,
        .pointerType = g.pointer_type,
        .isPrimary = true,
        .width = g.width,
        .height = g.height,
        .pressure = if (g.buttons_down != 0) g.pressure else 0.0,
        .ctrlKey = g.modifiers.ctrl,
        .shiftKey = g.modifiers.shift,
        .altKey = g.modifiers.alt,
        .metaKey = g.modifiers.meta,
    }, owner);
    const cancelled = try owner._event_manager.dispatchCancelable(target.asEventTarget(), event.asEvent());
    return cancelled or owner.window._closed;
}

/// Dispatch a trusted mouse event; returns whether its default action is off,
/// as for `emitPointer`.
fn emitMouse(
    frame: *Frame,
    target: *Element,
    comptime typ: []const u8,
    g: Gesture,
    detail: u32,
) !bool {
    const owner = target.ownerFrame(frame) orelse frame;
    if (owner.window._closed) return true;
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
    const cancelled = try owner._event_manager.dispatchCancelable(target.asEventTarget(), event.asEvent());
    return cancelled or owner.window._closed;
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
    /// Where the latest press landed, until the release that follows it fires
    /// its click. A release with no press behind it has no target, and
    /// reports a click count of 0.
    down_target: ?*Element = null,

    /// `g.buttons_down` is ignored: the held mask supplies it.
    pub fn press(self: *PointerButtons, frame: *Frame, target: *Element, g: Gesture) !void {
        const bit = buttonsBitmask(g.button);
        const starts_gesture = self.held & ~bit == 0;
        self.down_target = target;
        self.held |= bit;

        var pg = g;
        pg.buttons_down = self.held;
        const suppressed = try pressSequence(frame, target, pg, self.mousedown_suppressed);
        // A listener may have discarded the target's frame and reset us.
        if (starts_gesture and self.down_target == target) {
            self.mousedown_suppressed = suppressed;
        }
    }

    /// Returns the element the click fired at, if any. `g.buttons_down` is
    /// ignored: the held mask supplies it.
    pub fn release(self: *PointerButtons, frame: *Frame, target: *Element, g: Gesture) !?*Element {
        const click_target = if (self.down_target) |down| commonClickTarget(frame, down, target) else null;
        const was_suppressed = self.mousedown_suppressed;
        const was_pressed = self.down_target != null;
        self.releaseButton(g.button);

        var rg = g;
        rg.buttons_down = self.held;
        // Chrome reports a release with no press since the previous one (the
        // later releases of a chord, or a lone release) with a click count of
        // 0, whatever the client sent.
        if (!was_pressed) rg.click_count = 0;
        try releaseSequence(frame, target, rg, was_suppressed, click_target);
        return click_target;
    }

    /// Every release consumes the latest press, even if it hit no element.
    /// The last held button releasing also clears the gesture's suppression.
    fn releaseButton(self: *PointerButtons, button: i32) void {
        self.down_target = null;
        self.held &= ~buttonsBitmask(button);
        if (self.held == 0) {
            self.mousedown_suppressed = false;
        }
    }

    /// Discards an in-progress gesture (a press that hit no element).
    pub fn reset(self: *PointerButtons) void {
        self.* = .{};
    }
};

/// The nearest common inclusive ancestor in the flat tree, where a shadow
/// tree sits inside its host, as hit-testing sees it.
fn commonAncestor(a: *Node, b: *Node, frame: *const Frame) ?*Node {
    var current: ?*Node = a;
    while (current) |node| : (current = node.flatTreeParent(frame)) {
        var other: ?*Node = b;
        while (other) |candidate| : (other = candidate.flatTreeParent(frame)) {
            if (node == candidate) {
                return node;
            }
        }
    }
    return null;
}

/// A click whose mousedown and mouseup landed on different elements fires at
/// their nearest common inclusive ancestor element. Two nodes of one shadow
/// tree meet at its shadow root, which isn't an element: the host is.
fn commonClickTarget(frame: *Frame, down: *Element, up: *Element) ?*Element {
    const owner = down.ownerFrame(frame) orelse return null;
    if (up.ownerFrame(frame) != owner) return null;
    if (down == up) {
        return up;
    }
    var current = commonAncestor(down.asNode(), up.asNode(), frame);
    while (current) |ancestor| : (current = ancestor.flatTreeParent(frame)) {
        if (ancestor.is(Element)) |element| {
            return element;
        }
    }
    return up;
}

pub fn moveSequence(frame: *Frame, target: *Element, g: Gesture) !void {
    updateHoverTarget(frame, target, HoverContext{ .x = g.x, .y = g.y, .buttons = g.buttons_down, .modifiers = g.modifiers });
    // A move changes no button: https://www.w3.org/TR/pointerevents3/#the-button-property
    var pg = g;
    pg.button = -1;
    _ = try emitPointer(frame, target, "pointermove", pg, 0);
    _ = try emitMouse(frame, target, "mousemove", g, 0);
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
    if (!suppressed) {
        try mouseDown(frame, target, g);
    }
    // Chrome on Linux and macOS fires contextmenu on press, even when the
    // pointerdown was cancelled.
    if (g.button == mouse_button.secondary) {
        _ = try emitPointer(frame, target, "contextmenu", g, 0);
    }
    return suppressed;
}

/// A disabled control gets the pointer events, contextmenu and auxclick, but
/// no mouse events, click or focus, as in Chrome.
fn mouseDown(frame: *Frame, target: *Element, g: Gesture) !void {
    if (!target.isDisabled() and !try emitMouse(frame, target, "mousedown", g, g.click_count)) {
        focusForMouseDown(frame, target) catch |err| log.debug(.app, "mousedown focus", .{ .err = err });
    }
}

/// A null `click_target` releases without a click, as for a later release in
/// a chord.
fn releaseSequence(frame: *Frame, up_target: *Element, g: Gesture, suppressed: bool, click_target: ?*Element) !void {
    if (g.buttons_down == 0) {
        _ = try emitPointer(frame, up_target, "pointerup", g, 0);
    } else {
        _ = try emitPointer(frame, up_target, "pointermove", g, 0);
    }
    try mouseUpAndClick(frame, up_target, g, suppressed, click_target);
}

/// `suppressed` drops the mouseup but keeps the click, as a cancelled
/// pointerdown does.
fn mouseUpAndClick(frame: *Frame, up_target: *Element, g: Gesture, suppressed: bool, click_target: ?*Element) !void {
    if (!suppressed and !up_target.isDisabled()) {
        _ = try emitMouse(frame, up_target, "mouseup", g, g.click_count);
    }

    // clickCount 0 releases without a click, as in Chrome.
    const click_el = click_target orelse return;
    if (g.click_count == 0) {
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

const MouseHit = struct {
    /// The innermost frame the point reached, and the point in its viewport.
    frame: *Frame,
    /// Null when nothing in `frame`'s document takes the point.
    target: ?*Element,
    x: f64,
    y: f64,
};

/// Input coordinates start in the caller's viewport. Unlike the DOM API,
/// native hit testing descends into the hit iframe's document.
fn mouseHitTest(frame: *Frame, x: f64, y: f64) !MouseHit {
    var hit: MouseHit = .{ .frame = frame, .target = null, .x = x, .y = y };
    if (frame.window._closed) {
        return hit;
    }
    const viewport = frame.page.getViewport();
    hit.target = try documentHit(frame, x, y, @floatFromInt(viewport.width), @floatFromInt(viewport.height));
    while (hit.target) |target| {
        const iframe = target.is(Element.Html.IFrame) orelse break;
        const window = iframe._window orelse break;
        if (window._closed) break;
        const child = window._frame;
        const rect = target.boundingClientRectValues(hit.frame);
        const child_x = hit.x - rect.x - target.getClientLeft();
        const child_y = hit.y - rect.y - target.getClientTop();
        const width = target.getClientWidth(hit.frame);
        const height = target.getClientHeight(hit.frame);
        // The iframe's client box is the child viewport. A point in its border
        // stays on the iframe in the parent document.
        if (!inBox(child_x, child_y, width, height)) break;
        hit = .{
            .frame = child,
            .target = try documentHit(child, child_x, child_y, width, height),
            .x = child_x,
            .y = child_y,
        };
    }
    return hit;
}

/// Like Chrome, a point inside the viewport that no element box covers lands
/// on the root element, unless the root itself can't be hit.
fn documentHit(frame: *Frame, x: f64, y: f64, width: f64, height: f64) !?*Element {
    if (try frame.document.hitTest(x, y, frame)) |target| {
        return target;
    }
    if (!inBox(x, y, width, height)) {
        return null;
    }
    const root = frame.document.getDocumentElement() orelse return null;
    const style_manager = &frame._style_manager;
    if (style_manager.hasDisplayNone(root) or !style_manager.isHitTestable(root)) {
        return null;
    }
    return root;
}

fn inBox(x: f64, y: f64, width: f64, height: f64) bool {
    return x >= 0 and y >= 0 and x < width and y < height;
}

const Point = struct { x: f64, y: f64 };

/// Where `frame`'s viewport sits in the top-level viewport. The faux layout
/// has no transform scaling and client borders are zero; this uses the same
/// rects as hit testing, including each parent's scroll.
fn viewportOrigin(frame: *Frame) Point {
    var point: Point = .{ .x = 0, .y = 0 };
    var current = frame;
    while (current.parent) |parent| {
        const element = (current.iframe orelse break).asElement();
        const rect = element.boundingClientRectValues(parent);
        point.x += rect.x + element.getClientLeft();
        point.y += rect.y + element.getClientTop();
        current = parent;
    }
    return point;
}

/// Converts a point in `from`'s viewport to `to`'s viewport.
pub fn pointInFrame(from: *Frame, to: *Frame, x: f64, y: f64) Point {
    if (from == to) return .{ .x = x, .y = y };
    const from_origin = viewportOrigin(from);
    const to_origin = viewportOrigin(to);
    return .{ .x = x + from_origin.x - to_origin.x, .y = y + from_origin.y - to_origin.y };
}

pub fn triggerMousePress(frame: *Frame, x: f64, y: f64, button: i32, click_count: i32) !void {
    const hit = try mouseHitTest(frame, x, y);
    const target = hit.target orelse {
        // Don't leave a prior gesture's state for the next message to misread.
        frame.page.input_pointer.reset();
        return;
    };
    if (comptime lp.IS_DEBUG) {
        log.debug(.frame, "frame mouse press", .{
            .url = frame.url,
            .node = target,
            .x = hit.x,
            .y = hit.y,
            .button = button,
            .type = frame._type,
        });
    }

    try frame.page.input_pointer.press(hit.frame, target, .{
        .button = button,
        // clickCount 0 (omitted) stays 0, not forced to 1: Chrome and Firefox
        // both fire mousedown with detail 0 in that case.
        .click_count = if (click_count > 0) @intCast(click_count) else 0,
        .x = hit.x,
        .y = hit.y,
    });
}

pub fn triggerMouseMove(frame: *Frame, x: f64, y: f64) !void {
    const hit = try mouseHitTest(frame, x, y);
    const target = hit.target orelse {
        // A miss ends hover without releasing a held button.
        updateHoverTarget(frame, null, HoverContext{ .x = x, .y = y, .buttons = frame.page.input_pointer.held });
        return;
    };
    if (comptime lp.IS_DEBUG) {
        log.debug(.frame, "frame mouse move", .{
            .url = frame.url,
            .node = target,
            .x = hit.x,
            .y = hit.y,
            .type = frame._type,
        });
    }

    try moveSequence(hit.frame, target, .{ .buttons_down = frame.page.input_pointer.held, .x = hit.x, .y = hit.y });
}

pub fn triggerMouseRelease(frame: *Frame, x: f64, y: f64, button: i32, click_count: i32) !void {
    const pointer = &frame.page.input_pointer;
    // A release that misses every element still lets go of the button, so
    // the next message doesn't read it as held.
    const hit = mouseHitTest(frame, x, y) catch |err| {
        pointer.releaseButton(button);
        return err;
    };
    const target = hit.target orelse {
        pointer.releaseButton(button);
        return;
    };
    if (comptime lp.IS_DEBUG) {
        log.debug(.frame, "frame mouse release", .{
            .url = frame.url,
            .node = target,
            .x = hit.x,
            .y = hit.y,
            .button = button,
            .type = frame._type,
        });
    }

    _ = try pointer.release(hit.frame, target, .{
        .button = button,
        .click_count = if (click_count > 0) @intCast(click_count) else 0,
        .x = hit.x,
        .y = hit.y,
    });
}

pub fn triggerMouseWheel(frame: *Frame, x: f64, y: f64, delta_x: f64, delta_y: f64) !void {
    const hit = try mouseHitTest(frame, x, y);
    const target = hit.target orelse blk: {
        // Over an iframe whose document takes nothing, the wheel goes nowhere.
        // A top-level miss still scrolls the root.
        if (hit.frame != frame) return;
        break :blk frame.document.getDocumentElement() orelse return;
    };
    if (comptime lp.IS_DEBUG) {
        log.debug(.frame, "frame mouse wheel", .{
            .url = frame.url,
            .node = target,
            .x = hit.x,
            .y = hit.y,
            .delta_x = delta_x,
            .delta_y = delta_y,
            .type = frame._type,
        });
    }

    try wheel(hit.frame, target, hit.x, hit.y, delta_x, delta_y);
}

/// A wheel over `target`: a trusted `wheel`, then the scroll unless it was
/// canceled. The event manager retypes it as Blink's legacy `mousewheel` for
/// targets listening only to that, and makes it cancelable only while a
/// listener on its dispatch path is non-passive.
pub fn wheel(frame: *Frame, target: *Element, x: f64, y: f64, delta_x: f64, delta_y: f64) !void {
    // Listeners live in the event manager of the element's own frame, which
    // is not the caller's when the element belongs to an iframe's document.
    const owner = target.ownerFrame(frame) orelse return;
    if (owner.window._closed) return;

    const event: *WheelEvent = try .initTrusted("wheel", .{
        .bubbles = true,
        .composed = true,
        .clientX = x,
        .clientY = y,
        .deltaX = delta_x,
        .deltaY = delta_y,
    }, owner);
    event.asEvent()._cancelable_unless_passive = true;
    const cancelled = try owner._event_manager.dispatchCancelable(target.asEventTarget(), event.asEvent());
    // A wheel listener may remove the iframe before the default action.
    if (cancelled or owner.window._closed) {
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
        current = container.asNode().flatTreeParentElement(frame);
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

/// One string of a drag's data, for one MIME type (CDP Input.DragDataItem).
pub const DragItem = struct {
    mimeType: []const u8,
    data: []const u8,
};

/// What a drag from outside the page carries: its items, and the operations
/// its source allows, as Chrome's mask (copy 1, link 2, move 16).
pub const DragData = struct {
    items: []const DragItem,
    dragOperationsMask: u32,
};

pub const DragType = enum { enter, over, drop, cancel };

/// A drag from outside the page, driven message by message (CDP
/// Input.dispatchDragEvent). Mouse input never starts a drag, so there is no
/// source element and no dragstart, drag or dragend.
pub const DragInput = struct {
    /// Set by dragEnter. A drop or dragCancel ends the drag, and dragOver and
    /// drop do nothing until the next dragEnter.
    active: bool = false,
    /// The element the drag is over (the spec's current target element).
    target: ?*Element = null,
};

const drag_copy: u32 = 1;
const drag_link: u32 = 2;
const drag_move: u32 = 16;
const drag_every = drag_copy | drag_link | drag_move;

fn dragEffectAllowed(mask: u32) []const u8 {
    return switch (mask & drag_every) {
        0 => "none",
        drag_copy => "copy",
        drag_link => "link",
        drag_move => "move",
        drag_copy | drag_link => "copyLink",
        drag_copy | drag_move => "copyMove",
        drag_link | drag_move => "linkMove",
        else => "all",
    };
}

/// The dropEffect a dragenter or dragover starts with, picked as Blink does.
fn dragDefaultDropEffect(mask: u32) []const u8 {
    const ops = mask & drag_every;
    if (ops == drag_every) return "copy";
    if (ops & drag_move != 0) return "move";
    if (ops & drag_copy != 0) return "copy";
    if (ops & drag_link != 0) return "link";
    return "none";
}

fn dragAllows(mask: u32, effect: []const u8) bool {
    const bit: u32 = if (std.mem.eql(u8, effect, "copy"))
        drag_copy
    else if (std.mem.eql(u8, effect, "link"))
        drag_link
    else if (std.mem.eql(u8, effect, "move"))
        drag_move
    else
        0;
    return mask & bit != 0;
}

/// Moves, drops or cancels a drag from outside the page, as Chrome does for
/// Input.dispatchDragEvent. dragEnter, dragOver and drop each run one step: a
/// new target gets dragenter, then the old one dragleave; the same target gets
/// dragover. A drop then goes to the target if that step accepted the drag
/// with an operation the source allows. If not, the target gets dragleave only
/// when a listener called preventDefault(). dragCancel fires nothing.
pub fn triggerDrag(frame: *Frame, typ: DragType, x: f64, y: f64, data: DragData, modifiers: Modifiers) !void {
    const drag = &frame.page.input_drag;
    switch (typ) {
        .cancel => {
            drag.* = .{};
            return;
        },
        .enter => drag.active = true,
        .over, .drop => if (!drag.active) return,
    }

    const d: DragDispatch = .{ .x = x, .y = y, .data = data, .modifiers = modifiers };
    const drop_effect = dragDefaultDropEffect(data.dragOperationsMask);
    const hit = try mouseHitTest(frame, x, y);
    var result: DragResult = .{ .cancelled = false, .drop_effect = "none" };
    if (hit.target != drag.target) {
        const old = drag.target;
        drag.target = hit.target;
        if (hit.target) |target| {
            result = try emitDrag(frame, target, "dragenter", old, d, .protected, drop_effect);
        }
        if (old) |target| {
            _ = try emitDrag(frame, target, "dragleave", hit.target, d, .protected, "none");
        }
    } else if (drag.target) |target| {
        result = try emitDrag(frame, target, "dragover", null, d, .protected, drop_effect);
    }
    // A listener may have discarded the target's frame and reset us.
    if (drag.target != hit.target) return;
    if (typ != .drop) return;

    drag.* = .{};
    const target = hit.target orelse return;
    if (result.cancelled and dragAllows(data.dragOperationsMask, result.drop_effect)) {
        _ = try emitDrag(frame, target, "drop", null, d, .read_only, result.drop_effect);
    } else if (result.cancelled) {
        _ = try emitDrag(frame, target, "dragleave", null, d, .protected, "none");
    }
}

const DragDispatch = struct {
    x: f64,
    y: f64,
    data: DragData,
    modifiers: Modifiers,
};

const DragResult = struct {
    cancelled: bool,
    /// dataTransfer.dropEffect once the listeners ran.
    drop_effect: []const u8,
};

/// Dispatches a trusted DragEvent whose dataTransfer holds the drag's items.
/// Each event gets its own DataTransfer, as in Blink.
fn emitDrag(
    frame: *Frame,
    target: *Element,
    comptime typ: []const u8,
    related: ?*Element,
    d: DragDispatch,
    mode: DataTransfer.Mode,
    drop_effect: []const u8,
) !DragResult {
    const owner = target.ownerFrame(frame) orelse frame;
    if (owner.window._closed) return .{ .cancelled = true, .drop_effect = "none" };

    const data_transfer = try DataTransfer.init(owner);
    data_transfer.acquireRef();
    defer data_transfer.releaseRef(owner.page);
    for (d.data.items) |item| {
        try data_transfer.setData(item.mimeType, item.data);
    }
    data_transfer._mode = mode;
    data_transfer._drop_effect = drop_effect;
    data_transfer._effect_allowed = dragEffectAllowed(d.data.dragOperationsMask);

    // No relatedTarget from another document.
    const same_document = if (related) |el| el.ownerFrame(frame) == owner else false;
    const related_target = if (same_document) related.?.asEventTarget() else null;
    const point = pointInFrame(frame, owner, d.x, d.y);
    const event: *DragEvent = try .initTrusted(typ, .{
        .bubbles = true,
        .cancelable = comptime !std.mem.eql(u8, typ, "dragleave"),
        .composed = true,
        .clientX = point.x,
        .clientY = point.y,
        .relatedTarget = related_target,
        .ctrlKey = d.modifiers.ctrl,
        .shiftKey = d.modifiers.shift,
        .altKey = d.modifiers.alt,
        .metaKey = d.modifiers.meta,
        .dataTransfer = data_transfer,
    }, owner);
    const cancelled = try owner._event_manager.dispatchCancelable(target.asEventTarget(), event.asEvent());
    return .{ .cancelled = cancelled, .drop_effect = data_transfer._drop_effect };
}

// pointerId 1 is the mouse.
pub const first_touch_pointer_id: i32 = 2;
// Chrome's touch slop, also the tap slop: inside it touchmove is suppressed.
const tap_slop_px = 15;
// Chrome's multi-tap window: the next tap must start within this time of the
// last release and within this distance of the last tap's start.
const multi_tap_ms = 400;
const multi_tap_slop_px = 20;

pub const TouchContact = struct {
    target: *Element,
    point: Touch.Point,
    start: Touch.Point,
    pointer_id: i32,
    tap_count: u32 = 1,
    // WebDriver chose the target, which then stands in for every hit-test.
    pinned: bool = false,
    suppress_mouse: bool = false,
    start_prevented: bool = false,
    phase: Phase = .slop,

    const Phase = enum {
        // Still a tap: only the pointer moves.
        slop,
        // Moved past the slop, so touchmove fires and nothing activates.
        drag,
        // The page didn't cancel the drag: the touch events left aren't
        // cancelable.
        scroll,
        // A scroll the touch-action allows: the pointer was cancelled.
        pan,
    };

    fn dispatch(self: TouchContact, modifiers: Modifiers) TouchDispatch {
        return .{ .modifiers = modifiers, .scrolling = self.phase == .scroll or self.phase == .pan };
    }

    /// A released contact reports a 1x1 point; a cancelled one keeps its
    /// geometry.
    fn gesture(self: TouchContact, point: Touch.Point, phase: enum { down, move, up, cancel }, modifiers: Modifiers) Gesture {
        const released = phase == .up;
        return .{
            .button = switch (phase) {
                .down, .up => mouse_button.main,
                .move, .cancel => -1,
            },
            .buttons_down = if (phase == .down or phase == .move) 1 else 0,
            .click_count = self.tap_count,
            .x = point.x,
            .y = point.y,
            .modifiers = modifiers,
            .pointer_type = "touch",
            .pointer_id = self.pointer_id,
            .width = if (released) 1 else point.radiusX * 2,
            .height = if (released) 1 else point.radiusY * 2,
            .pressure = point.force,
        };
    }
};

/// Fires only the pointer half of each boundary event: touch has no hover, so
/// the mouse half comes later, with the tap's compatibility events.
const TouchBoundary = struct {
    g: Gesture,

    fn emit(self: TouchBoundary, frame: *Frame, target: *Element, comptime suffix: []const u8, _: ?*Element, _: bool) void {
        _ = emitPointer(frame, target, "pointer" ++ suffix, self.g, 0) catch |err| {
            log.debug(.frame, "touch boundary event", .{ .err = err, .type = suffix });
        };
    }
};

const TouchType = enum {
    touchstart,
    touchmove,
    touchend,
    touchcancel,
};

pub const LastTap = struct {
    count: u32,
    x: f64,
    y: f64,
    released_ms: u64,
    // WebDriver's pinned target, standing in for the point it doesn't have.
    pinned: ?*Element,
};

pub const TouchInput = struct {
    // Single-touch, so at most one.
    contact: ?TouchContact = null,
    next_pointer_id: i32 = first_touch_pointer_id,
    // The last tap that activated, for counting the next one.
    last_tap: ?LastTap = null,
};

const TouchDispatch = struct {
    modifiers: Modifiers = .{},
    // A scrolling contact's touch events aren't cancelable.
    scrolling: bool = false,
};

/// Fires the touch event on `target` (no hit-test); returns whether
/// preventDefault() cancelled it.
fn dispatchTouchEvent(frame: *Frame, target: *Element, typ: TouchType, point: Touch.Point, opts: TouchDispatch) !bool {
    const owner = target.ownerFrame(frame) orelse frame;
    const event: *TouchEvent = try .initTrustedWithTouch(@tagName(typ), .{
        .bubbles = true,
        .composed = true,
        .altKey = opts.modifiers.alt,
        .ctrlKey = opts.modifiers.ctrl,
        .metaKey = opts.modifiers.meta,
        .shiftKey = opts.modifiers.shift,
    }, target, point, owner);

    // touchcancel is never cancelable per spec; the others follow the same
    // passive-listener-dependent rule as wheel (see EventManager).
    if (typ != .touchcancel and !opts.scrolling) {
        event.asEvent()._cancelable_unless_passive = true;
    }

    return owner._event_manager.dispatchCancelable(target.asEventTarget(), event.asEvent());
}

/// A point that misses every element falls back to the document element, as
/// WebDriver's pointerMove does, rather than dropping the contact. `target`
/// replaces the hit-test for WebDriver, whose actions have no viewport point.
pub fn touchStart(frame: *Frame, target: ?*Element, point: Touch.Point, modifiers: Modifiers) !void {
    const touch = &frame.page.input_touch;
    if (touch.contact != null) {
        return;
    }
    const owner = if (target) |el| el.ownerFrame(frame) orelse frame else frame;
    const resolved = target orelse
        (try owner.window._document.hitTest(point.x, point.y, owner)) orelse
        owner.window._document.getDocumentElement() orelse return;
    if (comptime lp.IS_DEBUG) {
        log.debug(.frame, "frame touch", .{
            .url = owner.url,
            .node = resolved,
            .x = point.x,
            .y = point.y,
            .type = owner._type,
        });
    }
    var contact: TouchContact = .{
        .target = resolved,
        .point = point,
        .start = point,
        .pointer_id = touch.next_pointer_id,
        .tap_count = nextTapCount(touch.last_tap, point, target),
        .pinned = target != null,
    };
    touch.last_tap = null;
    touch.next_pointer_id = if (contact.pointer_id == std.math.maxInt(i32)) first_touch_pointer_id else contact.pointer_id + 1;
    const g = contact.gesture(point, .down, modifiers);
    dispatchBoundaryEvents(owner, null, resolved, TouchBoundary{ .g = g });
    contact.suppress_mouse = try emitPointer(owner, resolved, "pointerdown", g, 0);
    contact.start_prevented = try dispatchTouchEvent(owner, resolved, .touchstart, point, .{ .modifiers = modifiers });
    touch.contact = contact;
}

/// Taps count 1, 2, 3, then start over, as in Chrome.
fn nextTapCount(last_tap: ?LastTap, start: Touch.Point, pinned: ?*Element) u32 {
    const last = last_tap orelse return 1;
    if (lp.datetime.milliTimestamp(.boot) -| last.released_ms > multi_tap_ms) return 1;
    if (last.pinned != pinned) return 1;
    const dx = start.x - last.x;
    const dy = start.y - last.y;
    if (dx * dx + dy * dy > multi_tap_slop_px * multi_tap_slop_px) return 1;
    return last.count % 3 + 1;
}

/// Stays on the touchstart element. Inside the slop only the pointer moves, as
/// in Chrome. Leaving it is a drag, which never activates: past the slop, or
/// for WebDriver, which has no viewport distance, onto another element `over`.
/// A drag the page doesn't cancel scrolls: its touch events stop being
/// cancelable, and where touch-action allows the pan the pointer is cancelled.
pub fn touchMove(frame: *Frame, over: ?*Element, point: Touch.Point, modifiers: Modifiers) !void {
    const touch = &frame.page.input_touch;
    var contact = touch.contact orelse return;
    const owner = contact.target.ownerFrame(frame) orelse frame;
    contact.point = point;
    const dx = point.x - contact.start.x;
    const dy = point.y - contact.start.y;
    const moved_off = if (over) |el| el != contact.target else false;
    const leaves_slop = contact.phase == .slop and (moved_off or dx * dx + dy * dy > tap_slop_px * tap_slop_px);
    if (leaves_slop) {
        contact.phase = .drag;
    }
    if (contact.phase != .pan) {
        _ = try emitPointer(owner, contact.target, "pointermove", contact.gesture(point, .move, modifiers), 0);
    }
    if (contact.phase == .slop) {
        touch.contact = contact;
        return;
    }
    const prevented = try dispatchTouchEvent(owner, contact.target, .touchmove, point, contact.dispatch(modifiers));
    if (leaves_slop and !prevented and !contact.start_prevented) {
        contact.phase = .scroll;
        if (allowsPan(owner, contact.target, dx, dy)) {
            contact.phase = .pan;
            const cg = contact.gesture(point, .cancel, modifiers);
            _ = try emitPointer(owner, contact.target, "pointercancel", cg, 0);
            dispatchBoundaryEvents(owner, contact.target, null, TouchBoundary{ .g = cg });
        }
    }
    touch.contact = contact;
}

/// Whether `target`'s effective touch-action allows a pan in the drag's
/// dominant direction. A drag with no dominant direction, as WebDriver's,
/// needs either axis.
fn allowsPan(frame: *Frame, target: *Element, dx: f64, dy: f64) bool {
    const owner = target.ownerFrame(frame) orelse frame;
    const blocked = owner._style_manager.touchPanBlockedAxes(target);
    if (@abs(dx) > @abs(dy)) return !blocked.x;
    if (@abs(dy) > @abs(dx)) return !blocked.y;
    return !blocked.x or !blocked.y;
}

/// A touch pointer moving with no contact down, which only WebDriver expresses.
pub fn touchHover(frame: *Frame, target: *Element, modifiers: Modifiers) !void {
    _ = try emitPointer(frame, target, "pointermove", .{
        .button = -1,
        .modifiers = modifiers,
        .pointer_type = "touch",
        .pointer_id = frame.page.input_touch.next_pointer_id,
    }, 0);
}

/// Puppeteer sends the released point and Chrome dispatches there; Playwright
/// sends none, so the stored contact is used. The compatibility mouse events
/// hit-test the release point, unless WebDriver pinned the target.
pub fn touchEnd(frame: *Frame, point: ?Touch.Point, modifiers: Modifiers) !void {
    const touch = &frame.page.input_touch;
    const contact = touch.contact orelse return;
    const owner = contact.target.ownerFrame(frame) orelse frame;
    // Cleared before dispatch so a throwing listener can't leave a stale
    // contact blocking every later touchStart.
    touch.contact = null;
    const pinned: ?*Element = if (contact.pinned) contact.target else null;
    const lift = point orelse contact.point;

    const g = contact.gesture(lift, .up, modifiers);
    if (contact.phase != .pan) {
        _ = try emitPointer(owner, contact.target, "pointerup", g, 0);
        dispatchBoundaryEvents(owner, contact.target, null, TouchBoundary{ .g = g });
    }
    const prevented = try dispatchTouchEvent(owner, contact.target, .touchend, lift, contact.dispatch(modifiers));
    if (contact.start_prevented or contact.phase != .slop or prevented) return;
    touch.last_tap = .{
        .count = contact.tap_count,
        .x = contact.start.x,
        .y = contact.start.y,
        .released_ms = lp.datetime.milliTimestamp(.boot),
        .pinned = pinned,
    };

    var target = try touchCompatTarget(owner, lift, pinned) orelse return;
    updateHoverTarget(owner, target, CompatHover{ .ctx = .{ .x = lift.x, .y = lift.y, .modifiers = modifiers } });
    if (contact.suppress_mouse) {
        return mouseUpAndClick(owner, target, g, true, target);
    }

    // Each listener can replace the element under the finger, so every
    // compatibility event hit-tests again, as Chrome does.
    target = try touchCompatTarget(owner, lift, pinned) orelse return;
    _ = try emitMouse(owner, target, "mousemove", g, 0);
    const down_target = try touchCompatTarget(owner, lift, pinned) orelse return;
    var dg = g;
    dg.buttons_down = 1;
    try mouseDown(owner, down_target, dg);
    const up_target = try touchCompatTarget(owner, lift, pinned) orelse return;
    // Chrome drops the click when mousedown's target is removed before the
    // release.
    const click_target = if (down_target.asNode().isConnected()) commonClickTarget(owner, down_target, up_target) else null;
    try mouseUpAndClick(owner, up_target, g, false, click_target);
}

pub fn touchCancel(frame: *Frame, modifiers: Modifiers) !void {
    const touch = &frame.page.input_touch;
    const contact = touch.contact orelse return;
    const owner = contact.target.ownerFrame(frame) orelse frame;
    touch.contact = null;
    if (contact.phase != .pan) {
        const g = contact.gesture(contact.point, .cancel, modifiers);
        _ = try emitPointer(owner, contact.target, "pointercancel", g, 0);
        dispatchBoundaryEvents(owner, contact.target, null, TouchBoundary{ .g = g });
    }
    _ = try dispatchTouchEvent(owner, contact.target, .touchcancel, contact.point, .{ .modifiers = modifiers });
}

fn touchCompatTarget(frame: *Frame, point: Touch.Point, pinned: ?*Element) !?*Element {
    if (pinned) |el| return el;
    return frame.window._document.hitTest(point.x, point.y, frame);
}

/// Drops the page's input state on `frame`'s elements, which are going away.
pub fn forgetFrame(frame: *Frame) void {
    const page = frame.page;
    if (page.input_hover_target) |el| {
        if (el.ownerFrame(frame) == frame) {
            page.input_hover_target = null;
        }
    }
    if (page.input_pointer.down_target) |el| {
        if (el.ownerFrame(frame) == frame) {
            page.input_pointer.reset();
        }
    }
    if (page.input_drag.target) |el| {
        if (el.ownerFrame(frame) == frame) {
            page.input_drag = .{};
        }
    }
    const touch = &page.input_touch;
    if (touch.contact) |contact| {
        if (contact.target.ownerFrame(frame) == frame) {
            touch.contact = null;
        }
    }
    if (touch.last_tap) |tap| {
        if (tap.pinned) |el| if (el.ownerFrame(frame) == frame) {
            touch.last_tap = null;
        };
    }
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

pub fn outermostEditingHost(target: *Element) ?*Element {
    var host: ?*Element = null;
    var current: ?*Element = target;
    while (current) |el| : (current = el.parentElement()) {
        if (el.contentEditableState()) |editable| {
            if (editable == false) {
                break;
            }
            host = el;
        } else if (el.isEditingHost()) {
            // the body of a designMode document
            host = el;
        }
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

    const owner = target.ownerFrame(frame) orelse return;
    try Element.focusFrameAncestors(owner);
    if (owner.window._closed) return;
    if (owner.document._active_element) |active| {
        try active.blur(owner);
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

// Runs a javascript: URL's script, `source` being the URL without its scheme.
// It is percent-decoded first, as the "evaluate a javascript: URL" steps do.
pub fn runJavascriptUrl(frame: *Frame, source: []const u8) !void {
    const arena = try frame.getArena(.tiny, "javascript-url");
    errdefer arena.release();

    const task = try arena.create(JavascriptUrlTask);
    task.* = .{
        .frame = frame,
        .arena = arena,
        .source = std.Uri.percentDecodeInPlace(try arena.dupe(u8, source)),
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
// user_initiated: a trusted click, for the navigate event it can start.
pub fn handleClick(frame: *Frame, target: *Node, event_target: *Node, user_initiated: bool) !void {
    // TODO: Also support <area> elements when implement
    const element = target.is(Element) orelse return;

    if (element.is(Element.Svg.Graphics.A) != null) {
        const href = element.svgAnchorHref() orelse return;
        const target_name = element.getAttributeInterned("target") orelse "";
        return followLink(frame, target, element, href, target_name, user_initiated);
    }

    const html_element = element.is(Element.Html) orelse return;

    switch (html_element._type) {
        .anchor => {
            const anchor = html_element.subtype(Element.Html.Anchor);
            const href = element.getAttributeInterned("href") orelse return;
            return followLink(frame, target, element, href, anchor.getTarget(), user_initiated);
        },
        .input => {
            const input = html_element.subtype(Element.Html.Input);
            // Per HTML §4.10.18.6.4 "Image Button state (type=image)", clicking an
            // image button submits its form. The form-data set already gets the
            // submitter's coordinate fields appended via FormData.collectForm
            // (see src/browser/webapi/net/FormData.zig).
            // A disabled submit button has no activation behavior; isDisabled
            // also covers an ancestor <fieldset disabled>, which a synthetic
            // dispatchEvent click does not otherwise check.
            if (input._input_type == .submit or input._input_type == .image) {
                if (element.isDisabled()) {
                    return;
                }
                return frame.submitForm(element, input.getForm(), .{ .user_initiated = user_initiated });
            }
            if (input._input_type == .reset) {
                if (element.isDisabled()) {
                    return;
                }
                const form = input.getForm() orelse return;
                return form.reset(frame);
            }
        },
        .button => {
            const button = html_element.subtype(Element.Html.Button);
            if (std.mem.eql(u8, button.getType(), "submit")) {
                if (element.isDisabled()) {
                    return;
                }
                return frame.submitForm(element, button.getForm(), .{ .user_initiated = user_initiated });
            }
            if (std.mem.eql(u8, button.getType(), "reset")) {
                if (element.isDisabled()) {
                    return;
                }
                const form = button.getForm() orelse return;
                return form.reset(frame);
            }
        },
        .label => {
            const label = html_element.subtype(Element.Html.Label);
            // Per HTML §4.10.4 "The label element", a label's activation
            // behavior is to run the synthetic click activation steps on the
            // labeled control. Mirrors Chrome's HTMLLabelElement::DefaultEventHandler.
            const control = label.getControl() orelse return;
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
fn followLink(frame: *Frame, target: *Node, element: *Element, href: []const u8, target_name: []const u8, user_initiated: bool) !void {
    if (href.len == 0) {
        return;
    }

    // The link's document initiates the navigation, which isn't `frame` when
    // a script clicks a link in another frame.
    const owner = target.ownerFrame(frame) orelse return;

    // <a href="/images/panda.png" download>
    const maybe_download = try element.getAttribute(comptime .wrap("download"), frame);
    if (URL.isJavascriptUrl(href) == false and maybe_download != null) {
        const download = maybe_download orelse unreachable;
        return @import("../Download.zig").fromHref(owner, href, download.str());
    }

    const target_frame = blk: {
        if (target_name.len == 0) {
            break :blk owner;
        }
        break :blk switch (owner.resolveTargetFrame(target_name)) {
            .frame => |f| f,
            .blank => {
                _ = try owner.openBlankTarget(element, href);
                return;
            },
        };
    };

    try owner.scheduleNavigation(href, .{
        .reason = .script,
        .kind = .{ .push = null },
        .source_element = element,
        .user_initiated = user_initiated,
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
    // read before dispatch, which can free the event
    const user_initiated = keypress.asEvent()._is_trusted;
    if (try frame._event_manager.dispatchCancelable(target.asEventTarget(), keypress.asEvent())) {
        return;
    }
    const is_enter = text.len == 1 and (text[0] == '\r' or text[0] == '\n');
    if (is_enter and isButton(target)) {
        return dispatchKeyboardClick(frame, target);
    }

    if (target.is(Element.Html.Input)) |input| {
        if (is_enter) {
            try input.dispatchChangeIfEdited(frame);
            return implicitFormSubmission(frame, input, user_initiated);
        }
        _ = try applyEdit(frame, input, .{ .insert = text });
    } else if (target.is(Element.Html.TextArea)) |textarea| {
        _ = try applyEdit(frame, textarea, if (is_enter) .line_break else .{ .insert = text });
    } else if (!is_enter and target.isEditable()) {
        _ = try insertIntoEditingHost(frame, target, text);
    }
}

/// Enter in a form field. The default button, when there is one, is clicked and
/// its activation submits the form with it as the submitter; otherwise the
/// form submits itself (SubmitEvent.submitter is null).
/// https://html.spec.whatwg.org/multipage/form-control-infrastructure.html#implicit-submission
fn implicitFormSubmission(frame: *Frame, input: *Element.Html.Input, user_initiated: bool) !void {
    const form = input.getForm() orelse return;
    if (form.getDefaultButton(frame)) |button| {
        if (button.isDisabled()) {
            return;
        }
        return dispatchKeyboardClick(frame, button);
    }
    if (!form.canSubmitImplicitly(input, frame)) {
        return;
    }
    return frame.submitForm(form.asElement(), form, .{ .user_initiated = user_initiated });
}

fn keypressFor(frame: *Frame, keydown: *const KeyboardEvent) !*KeyboardEvent {
    return KeyboardEvent.initTrusted(comptime .wrap("keypress"), .{
        .key = keydown.getKey().asString(),
        .code = keydown._code,
        .location = keydown._location,
        .ctrlKey = keydown.getCtrlKey(),
        .shiftKey = keydown.getShiftKey(),
        .altKey = keydown.getAltKey(),
        .metaKey = keydown.getMetaKey(),
    }, frame);
}

pub fn handleKeydown(frame: *Frame, target: *Node, event: *Event) !void {
    if (event.getIsTrusted() == false) {
        return;
    }
    const keyboard_event = event.is(KeyboardEvent) orelse return;
    const key = keyboard_event.getKey();

    if (key == .Dead) {
        return;
    }

    if (key == .Tab) {
        // tab -> forward, shift+tab -> backwards
        return moveFocus(frame, keyboard_event.getShiftKey() == false);
    }

    if (key == .Escape) {
        return Element.Html.Dialog.requestCloseTopModal(frame);
    }

    if (key == .Enter) {
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
    if (isSelectAll(keyboard_event, key)) {
        return ctl.select(frame);
    }

    if (caretMove(key, ctl)) |move| {
        // Word/paragraph motions (ctrl/alt/meta variants) aren't modeled.
        if (keyboard_event.getCtrlKey() or keyboard_event.getAltKey() or keyboard_event.getMetaKey()) {
            return;
        }
        return ctl.moveCaret(move, keyboard_event.getShiftKey(), frame);
    }

    if (key == .Backspace or key == .Delete) {
        const edit: Edit = .{ .delete = if (key == .Delete) .forward else .backward };
        _ = try applyEdit(frame, ctl, edit);
    }
}

pub const Edit = union(enum) {
    insert: []const u8,
    line_break,
    delete: enum { backward, forward },
};

/// A text edit as the user makes it: cancellable through beforeinput, and
/// refused on a readonly or disabled control. Returns whether it happened.
pub fn applyEdit(frame: *Frame, ctl: anytype, edit: Edit) !bool {
    const el = ctl.asElement();
    if (!ctl.acceptsTextEntry() or el.isDisabled()) {
        return false;
    }
    const editable = acceptsEdit(el);
    // Chrome fires beforeinput and textInput for text typed into a readonly
    // control and only then refuses it; its editing commands fire nothing.
    if (!editable and edit != .insert) {
        return false;
    }

    const data: ?[]const u8, const text: ?[]const u8, const input_type: []const u8 = switch (edit) {
        .insert => |t| .{ t, t, "insertText" },
        .line_break => .{ null, "\n", "insertLineBreak" },
        .delete => |dir| .{ null, null, if (dir == .forward) "deleteContentForward" else "deleteContentBackward" },
    };
    if (!try allowEdit(frame, el, data, text, input_type)) {
        return false;
    }
    if (!editable) {
        return false;
    }

    try ctl.rememberValueBeforeEdit(frame);
    if (text) |t| {
        try ctl.innerInsert(t, data, input_type, frame);
    } else {
        try ctl.innerDelete(edit.delete == .forward, input_type, frame);
    }
    return true;
}

/// Plain text typed into editable content (contenteditable): cancellable
/// through beforeinput like a control's edit, then replaces the selection and
/// leaves the caret after the text. The events target the editing host of
/// `target`, as in Chrome. A selection outside the editable content of the
/// host puts the text at the host's first editable position, where Chrome
/// places the caret when the host is focused. Only text insertion is supported: line breaks,
/// deletion and formatting need an editing pipeline. Returns whether the edit
/// happened.
fn insertIntoEditingHost(frame: *Frame, target: *Element, text: []const u8) !bool {
    const host_el = outermostEditingHost(target) orelse return false;
    if (!try allowEdit(frame, host_el, text, text, "insertText")) {
        return false;
    }
    // a beforeinput or textInput listener can make it non-editable or remove it
    if (!host_el.isEditable() or !host_el.asNode().isConnected()) {
        return false;
    }
    try insertAtSelection(frame, host_el, text);
    return true;
}

/// The edit part of insertIntoEditingHost, without the events that can cancel
/// it: replaces the selection in `host_el` with `text`, leaves the caret after
/// it and fires input.
pub fn insertAtSelection(frame: *Frame, host_el: *Element, text: []const u8) !void {
    const host = host_el.asNode();
    const selection = &frame.document._selection;
    var container: *Node, var offset: u32 = firstCaretPosition(host);
    if (selection._range) |range| {
        const abstract = range.asAbstractRange();
        if (isEditableIn(host, abstract.getStartContainer()) and isEditableIn(host, abstract.getEndContainer())) {
            if (!abstract.getCollapsed()) {
                try range.deleteContents(frame);
            }
            container = abstract.getStartContainer();
            offset = abstract.getStartOffset();
        }
    }

    // Join the text node at the caret, as Chrome does, rather than adding a
    // sibling next to it.
    var text_node: ?*Node.CData.Text = container.is(Node.CData.Text);
    if (text_node) |t| {
        // a caret inside a surrogate pair: before the pair
        const data = t.asCData().getData().str();
        offset = @intCast(Node.CData.utf16Len(data[0..Node.CData.utf16OffsetToUtf8Floor(data, offset)]));
    } else {
        if (container.is(Node.CData) != null) {
            // a caret in a comment or processing instruction: after it
            offset = @intCast(container.parentNode().?.getChildIndex(container).? + 1);
            container = container.parentNode().?;
        }
        if (offset > 0) {
            if (container.getChildAt(offset - 1)) |before| {
                if (before.is(Node.CData.Text)) |t| {
                    text_node = t;
                    offset = @intCast(t.asCData().getLength());
                }
            }
        }
    }
    if (text_node == null) {
        if (container.getChildAt(offset)) |after| {
            if (after.is(Node.CData.Text)) |t| {
                text_node = t;
                offset = 0;
            }
        }
    }

    const caret: u32 = if (text_node) |t| blk: {
        try t.asCData().insertData(offset, text, frame);
        break :blk offset + @as(u32, @intCast(Node.CData.utf16Len(text)));
    } else blk: {
        const new_node = try frame.document.createTextNode(text);
        _ = try container.insertBefore(new_node, container.getChildAt(offset), frame);
        text_node = new_node.is(Node.CData.Text).?;
        break :blk @intCast(Node.CData.utf16Len(text));
    };
    try selection.collapse(text_node.?.asCData().asNode(), caret, frame);

    const event = try InputEvent.initTrusted(comptime .wrap("input"), .{
        .bubbles = true,
        .composed = true,
        .data = text,
        .inputType = "insertText",
    }, frame);
    try frame._event_manager.dispatch(host_el.asEventTarget(), event.asEvent());
}

/// Deletes the selection in `host_el`, or the character before (or after,
/// when `forward`) a collapsed one, and fires input. Inline elements left
/// empty go, and a block left empty gets a <br> placeholder, as in Chrome. At
/// the edge of the host there's nothing to delete: no edit, no event. Returns
/// false, without editing, for what needs an editing pipeline: merging blocks
/// and deleting a <br>, an image or other non-text content.
pub fn deleteAtSelection(frame: *Frame, host_el: *Element, forward: bool) !bool {
    const host = host_el.asNode();
    const selection = &frame.document._selection;
    const usable = if (selection._range) |range| blk: {
        const abstract = range.asAbstractRange();
        break :blk isEditableIn(host, abstract.getStartContainer()) and isEditableIn(host, abstract.getEndContainer());
    } else false;
    if (!usable) {
        const container, const offset = firstCaretPosition(host);
        try selection.collapse(container, offset, frame);
    }
    // Live, so it follows the edits below. A collapse replaces it, and a
    // selectionchange listener can do anything, so there's one collapse,
    // after the edit.
    const live = selection._range orelse return false;
    const range = live.asAbstractRange();
    if (!isEditableIn(host, range.getStartContainer()) or !isEditableIn(host, range.getEndContainer())) {
        return false;
    }
    const style_manager = &frame._style_manager;

    var caret: ?struct { *Node, u32 } = null;
    if (range.getCollapsed()) {
        const container = range.getStartContainer();
        const root = blockRoot(style_manager, host, container);
        const found = if (forward)
            charAfter(style_manager, root, container, range.getStartOffset())
        else
            charBefore(style_manager, root, container, range.getStartOffset());
        const char = switch (found) {
            .char => |c| c,
            .edge => return root == host,
            .unsupported => return false,
        };
        const cdata = char.text.asCData();
        try cdata.replaceData(char.offset, char.len, "", frame);
        if (cdata.getLength() == 0) {
            try removeEmpty(frame, root, cdata.asNode());
        } else if (!forward) {
            caret = .{ cdata.asNode(), char.offset };
        }
    } else {
        const common = range.getCommonAncestorContainer();
        const start = range.getStartContainer();
        const end = range.getEndContainer();
        // a boundary inside a block (or anything but a plain inline) would
        // leave two blocks to merge
        if (!onlyInlinesBetween(style_manager, common, start) or !onlyInlinesBetween(style_manager, common, end)) {
            return false;
        }
        const root = blockRoot(style_manager, host, common);
        try live.deleteContents(frame);
        for ([_]*Node{ end, start }) |node| {
            const cdata = node.is(Node.CData.Text) orelse continue;
            if (cdata.asCData().getLength() == 0 and root.contains(node) and node != root) {
                try removeEmpty(frame, root, node);
            }
        }
    }

    if (caret == null) {
        // Like Chrome, a caret right after a text node goes into it.
        const container = range.getStartContainer();
        const offset = range.getStartOffset();
        if (container.is(Node.CData) == null and offset > 0) {
            if (container.getChildAt(offset - 1)) |before| {
                if (before.is(Node.CData.Text)) |t| {
                    caret = .{ before, @intCast(t.asCData().getLength()) };
                }
            }
        }
    }
    if (caret) |c| {
        try selection.collapse(c[0], c[1], frame);
    }

    const event = try InputEvent.initTrusted(comptime .wrap("input"), .{
        .bubbles = true,
        .composed = true,
        .data = null,
        .inputType = if (forward) "deleteContentForward" else "deleteContentBackward",
    }, frame);
    try frame._event_manager.dispatch(host_el.asEventTarget(), event.asEvent());
    return true;
}

// The innermost box holding `node` that text can't run out of: its nearest
// ancestor that isn't a plain inline, or the host.
fn blockRoot(style_manager: *StyleManager, host: *Node, node: *Node) *Node {
    var current: *Node = if (node.is(Element) != null) node else node.parentNode() orelse return host;
    while (current != host) {
        const el = current.is(Element) orelse return host;
        if (!isTextInline(style_manager, el)) {
            return current;
        }
        current = current.parentNode() orelse return host;
    }
    return host;
}

// An element a caret moves through as if it weren't there: editable, shown,
// plain inline, not void (<br>, <img>).
fn isTextInline(style_manager: *StyleManager, el: *Element) bool {
    return el.isEditable() and !dump.isVoidElement(el) and !style_manager.hasDisplayNone(el) and style_manager.isPlainInline(el);
}

fn onlyInlinesBetween(style_manager: *StyleManager, ancestor: *Node, node: *Node) bool {
    var current: ?*Node = node;
    while (current) |n| : (current = n.parentNode()) {
        if (n == ancestor) {
            return true;
        }
        const el = n.is(Element) orelse continue;
        if (!isTextInline(style_manager, el)) {
            return false;
        }
    }
    return false;
}

const CharToDelete = union(enum) {
    // a code point in `text`, as a UTF-16 offset and length
    char: struct { text: *Node.CData.Text, offset: u32, len: u32 },
    // nothing to delete before (or after) the caret in `root`
    edge,
    // a <br>, an image, a block, ...
    unsupported,
};

fn charBefore(style_manager: *StyleManager, root: *Node, container: *Node, offset: u32) CharToDelete {
    var parent = container;
    var prev: ?*Node = null;
    if (container.is(Node.CData)) |cdata| {
        if (container.is(Node.CData.Text)) |t| {
            if (offset > 0) {
                return lastCodePoint(t, cdata.getData().str(), offset);
            }
        }
        parent = container.parentNode() orelse return .unsupported;
        prev = container.previousSibling();
    } else if (offset > 0) {
        prev = container.getChildAt(offset - 1);
    }

    while (true) {
        const node = prev orelse {
            if (parent == root) {
                return .edge;
            }
            prev = parent.previousSibling();
            parent = parent.parentNode() orelse return .unsupported;
            continue;
        };
        if (node.is(Node.CData)) |cdata| {
            if (node.is(Node.CData.Text)) |t| {
                const len = cdata.getLength();
                if (len > 0) {
                    return lastCodePoint(t, cdata.getData().str(), @intCast(len));
                }
            }
            // empty text, comments
            prev = node.previousSibling();
            continue;
        }
        const el = node.is(Element) orelse return .unsupported;
        if (!isTextInline(style_manager, el)) {
            return .unsupported;
        }
        parent = node;
        prev = node.lastChild();
    }
}

fn charAfter(style_manager: *StyleManager, root: *Node, container: *Node, offset: u32) CharToDelete {
    var parent = container;
    var next: ?*Node = null;
    if (container.is(Node.CData)) |cdata| {
        if (container.is(Node.CData.Text)) |t| {
            if (offset < cdata.getLength()) {
                return firstCodePoint(t, cdata.getData().str(), offset);
            }
        }
        parent = container.parentNode() orelse return .unsupported;
        next = container.nextSibling();
    } else {
        next = container.getChildAt(offset);
    }

    while (true) {
        const node = next orelse {
            if (parent == root) {
                return .edge;
            }
            next = parent.nextSibling();
            parent = parent.parentNode() orelse return .unsupported;
            continue;
        };
        if (node.is(Node.CData)) |cdata| {
            if (node.is(Node.CData.Text)) |t| {
                if (cdata.getLength() > 0) {
                    return firstCodePoint(t, cdata.getData().str(), 0);
                }
            }
            next = node.nextSibling();
            continue;
        }
        const el = node.is(Element) orelse return .unsupported;
        if (!isTextInline(style_manager, el)) {
            return .unsupported;
        }
        parent = node;
        next = node.firstChild();
    }
}

// The code point ending at UTF-16 offset `end` (> 0). A whole code point,
// not a grapheme, like Backspace in a text control.
fn lastCodePoint(text: *Node.CData.Text, data: []const u8, end: u32) CharToDelete {
    var byte = Node.CData.utf16OffsetToUtf8Floor(data, end);
    if (Node.CData.utf16Len(data[0..byte]) < end) {
        // inside a surrogate pair: the whole pair
        byte = @min(byte + (std.unicode.utf8ByteSequenceLength(data[byte]) catch 1), data.len);
    }
    var start = byte - 1;
    while (start > 0 and (data[start] & 0xC0) == 0x80) {
        start -= 1;
    }
    const len: u32 = @intCast(Node.CData.utf16Len(data[start..byte]));
    const offset: u32 = @intCast(Node.CData.utf16Len(data[0..start]));
    return .{ .char = .{ .text = text, .offset = offset, .len = len } };
}

// The code point starting at UTF-16 offset `start`.
fn firstCodePoint(text: *Node.CData.Text, data: []const u8, start: u32) CharToDelete {
    const byte = Node.CData.utf16OffsetToUtf8Floor(data, start);
    const seq = std.unicode.utf8ByteSequenceLength(data[byte]) catch 1;
    const end = @min(byte + seq, data.len);
    const len: u32 = @intCast(Node.CData.utf16Len(data[byte..end]));
    const offset: u32 = @intCast(Node.CData.utf16Len(data[0..byte]));
    return .{ .char = .{ .text = text, .offset = offset, .len = len } };
}

// Removes `node` (an emptied text node) along with the inline elements it
// leaves empty. A block (or block host) left with nothing gets a <br>, so
// it keeps a line to put the caret on.
fn removeEmpty(frame: *Frame, root: *Node, node: *Node) !void {
    var gone = node;
    while (gone.parentNode()) |parent| {
        if (parent == root or gone.previousSibling() != null or gone.nextSibling() != null) {
            break;
        }
        gone = parent;
    }
    const parent = gone.parentNode() orelse return;
    _ = try parent.removeChild(gone, frame);

    if (root.firstChild() != null) {
        return;
    }
    const root_el = root.is(Element) orelse return;
    if (!frame._style_manager.isBlockLevel(root_el)) {
        return;
    }
    // a caret in what was removed is now at (root, 0), and stays there
    const br = try frame.document.createElement("br", null, frame);
    _ = try root.appendChild(br.asNode(), frame);
}

// Where Chrome puts the caret when an editing host is focused: its first
// editable position, so inside a leading <p> rather than before it. Skips
// comments and whitespace-only text, and stops at a void or non-editable
// element.
fn firstCaretPosition(host: *Node) struct { *Node, u32 } {
    var container = host;
    descend: while (true) {
        var index: u32 = 0;
        var child = container.firstChild();
        while (child) |c| : ({
            child = c.nextSibling();
            index += 1;
        }) {
            if (c.is(Node.CData.Text)) |t| {
                if (std.mem.trim(u8, t.asCData().getData().str(), " \t\n\r\x0c").len == 0) {
                    continue;
                }
                return .{ c, 0 };
            }
            const el = c.is(Element) orelse continue;
            if (el.isEditable() == false or dump.isVoidElement(el)) {
                return .{ container, index };
            }
            container = c;
            continue :descend;
        }
        return .{ container, 0 };
    }
}

// Whether `node` is inside `host` and editable: the nearest contenteditable
// attribute of its element (or of its parent, for a text node) allows editing.
fn isEditableIn(host: *Node, node: *Node) bool {
    if (!host.contains(node)) {
        return false;
    }
    const element = node.is(Element) orelse node.parentElement() orelse return false;
    return element.isEditable();
}

pub fn acceptsEdit(el: *Element) bool {
    if (el.isDisabled()) {
        return false;
    }
    if (el.is(Element.Html.Input)) |input| {
        if (!input.readonlyApplies()) {
            return true;
        }
    }
    return !el.hasAttributeInterned("readonly");
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

// Ctrl+A alone, as in Chrome on Linux
fn isSelectAll(keyboard_event: *KeyboardEvent, key: KeyboardEvent.Key) bool {
    if (!keyboard_event.getCtrlKey() or keyboard_event.getAltKey() or keyboard_event.getMetaKey() or keyboard_event.getShiftKey()) {
        return false;
    }
    return switch (key) {
        .standard => |s| std.ascii.eqlIgnoreCase(s, "a"),
        else => false,
    };
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
        _ = try applyEdit(frame, input, .{ .insert = v });
    } else if (html_element.is(Element.Html.TextArea)) |textarea| {
        _ = try applyEdit(frame, textarea, .{ .insert = v });
    } else if (html_element.isEditable()) {
        _ = try insertIntoEditingHost(frame, html_element, v);
    }
}

pub const Modifiers = struct {
    ctrl: bool = false,
    shift: bool = false,
    alt: bool = false,
    meta: bool = false,
};

const testing = @import("../../testing.zig");

test "user_input: touchcancel is never cancelable" {
    const page = try testing.pageTest("mcp_actions.html", .{});
    defer page.close();
    const frame = page.frame().?;
    var ls: js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();
    var tc: js.TryCatch = undefined;
    tc.init(&ls.local);
    defer tc.deinit();

    const value = try ls.local.compileAndRun(
        \\const t = document.getElementById('hoverTarget');
        \\t.addEventListener('touchcancel', e => {
        \\  e.preventDefault();
        \\  window.result = !e.cancelable && !e.defaultPrevented;
        \\}, {passive: false});
        \\t;
    , null);
    const target = try ls.local.jsValueToZig(*Element, value);
    try touchStart(frame, target, .{ .x = 10, .y = 20 }, .{});
    try touchCancel(frame, .{});
    try testing.expect((try ls.local.compileAndRun("window.result === true", null)).isTrue());
}

test "user_input: dispatchTouchEvent a passive-only touchstart listener is not cancelable" {
    const page = try testing.pageTest("mcp_actions.html", .{});
    defer page.close();
    const frame = page.frame().?;
    var ls: js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();
    var tc: js.TryCatch = undefined;
    tc.init(&ls.local);
    defer tc.deinit();

    const value = try ls.local.compileAndRun(
        \\const t = document.getElementById('hoverTarget');
        \\t.addEventListener('touchstart', e => { window.result = !e.cancelable; }, {passive: true});
        \\t;
    , null);
    const target = try ls.local.jsValueToZig(*Element, value);
    _ = try dispatchTouchEvent(frame, target, .touchstart, .{ .x = 10, .y = 20 }, .{});
    try testing.expect((try ls.local.compileAndRun("window.result === true", null)).isTrue());
}

test "user_input: dispatchTouchEvent a non-passive listener makes touchstart cancelable" {
    const page = try testing.pageTest("mcp_actions.html", .{});
    defer page.close();
    const frame = page.frame().?;
    var ls: js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();
    var tc: js.TryCatch = undefined;
    tc.init(&ls.local);
    defer tc.deinit();

    const value = try ls.local.compileAndRun(
        \\const t = document.getElementById('hoverTarget');
        \\t.addEventListener('touchstart', e => { window.result = e.cancelable; });
        \\t;
    , null);
    const target = try ls.local.jsValueToZig(*Element, value);
    _ = try dispatchTouchEvent(frame, target, .touchstart, .{ .x = 10, .y = 20 }, .{});
    try testing.expect((try ls.local.compileAndRun("window.result === true", null)).isTrue());
}

test "user_input: dispatchTouchEvent a closed-shadow touch target retargets to the host" {
    const page = try testing.pageTest("mcp_actions.html", .{});
    defer page.close();
    const frame = page.frame().?;
    var ls: js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();
    var tc: js.TryCatch = undefined;
    tc.init(&ls.local);
    defer tc.deinit();

    const value = try ls.local.compileAndRun(
        \\const host = document.createElement('div');
        \\document.body.appendChild(host);
        \\const root = host.attachShadow({mode: 'closed'});
        \\const inner = document.createElement('button');
        \\root.appendChild(inner);
        \\host.addEventListener('touchstart', e => {
        \\  window.eventTargetOK = e.target === host;
        \\  window.touchTargetOK = e.touches[0].target === host;
        \\});
        \\inner;
    , null);
    const target = try ls.local.jsValueToZig(*Element, value);
    _ = try dispatchTouchEvent(frame, target, .touchstart, .{ .x = 10, .y = 20 }, .{});
    const result = try ls.local.compileAndRun("window.eventTargetOK === true && window.touchTargetOK === true", null);
    try testing.expect(result.isTrue());
}

test "user_input: mouse hit testing descends nested iframe viewports" {
    const page = try testing.pageTest("input_mouse_frames.html", .{});
    defer page.close();
    const main = page.frame().?;
    const child = main.child_frames.items[0];
    const nested = child.child_frames.items[0];
    const target = nested.document.getElementById("inner").?;
    const rect = target.boundingClientRectValues(nested);
    const child_rect = child.iframe.?.asElement().boundingClientRectValues(main);
    const nested_rect = nested.iframe.?.asElement().boundingClientRectValues(child);
    const x = rect.x + nested_rect.x + child_rect.x + 1;
    const y = rect.y + nested_rect.y + child_rect.y + 1;

    // The DOM API intentionally returns the iframe in the calling document.
    try testing.expect((try main.document.hitTest(x, y, main)) == child.iframe.?.asElement());
    var ls: js.Local.Scope = undefined;
    nested.js.localScope(&ls);
    defer ls.deinit();
    _ = try ls.local.compileAndRun(
        \\window.events = [];
        \\const target = document.getElementById('inner');
        \\for (const type of ['pointerover', 'mouseover', 'pointermove', 'mousemove', 'pointerdown', 'mousedown', 'pointerup', 'mouseup', 'click']) {
        \\  target.addEventListener(type, e => events.push({type, x:e.clientX, y:e.clientY, trusted:e.isTrusted}));
        \\}
    , null);
    try triggerMouseMove(main, x, y);
    try triggerMousePress(main, x, y, mouse_button.main, 1);
    try triggerMouseRelease(main, x, y, mouse_button.main, 1);
    try testing.expect(focusedFrame(main) == nested);
    try insertText(focusedFrame(main), "typed");
    try testing.expect((try ls.local.compileAndRun(
        \\target.value === 'typed' &&
        \\events.map(e => e.type).join(',') === 'pointerover,mouseover,pointermove,mousemove,pointerdown,mousedown,pointerup,mouseup,click' &&
        \\events.every(e => e.trusted && e.x === target.getBoundingClientRect().x + 1 && e.y === target.getBoundingClientRect().y + 1)
    , null)).isTrue());
}

test "user_input: mouse release in another document does not click" {
    const page = try testing.pageTest("input_mouse_frames.html", .{});
    defer page.close();
    const main = page.frame().?;
    const child = main.child_frames.items[0];
    const nested = child.child_frames.items[0];
    const inner = nested.document.getElementById("inner").?;
    const outer = main.document.getElementById("outer").?;
    const inner_rect = inner.boundingClientRectValues(nested);
    const child_rect = child.iframe.?.asElement().boundingClientRectValues(main);
    const nested_rect = nested.iframe.?.asElement().boundingClientRectValues(child);
    const outer_rect = outer.boundingClientRectValues(main);
    var ls: js.Local.Scope = undefined;
    main.js.localScope(&ls);
    defer ls.deinit();
    _ = try ls.local.compileAndRun("window.clicks = 0; document.addEventListener('click', () => clicks++);", null);
    try triggerMousePress(main, inner_rect.x + nested_rect.x + child_rect.x + 1, inner_rect.y + nested_rect.y + child_rect.y + 1, mouse_button.main, 1);
    try testing.expect(main.page.input_pointer.down_target == inner);
    try triggerMouseRelease(main, outer_rect.x + 1, outer_rect.y + 1, mouse_button.main, 1);
    try testing.expect((try ls.local.compileAndRun("clicks === 0", null)).isTrue());
    try testing.expectEqual(0, main.page.input_pointer.held);
    try testing.expect(main.page.input_pointer.down_target == null);
}

test "user_input: a blank viewport point hovers the root; only leaving the viewport leaves the document" {
    const page = try testing.pageTest("input_mouse_frames.html", .{});
    defer page.close();
    const main = page.frame().?;
    const outer = main.document.getElementById("outer").?;
    const rect = outer.boundingClientRectValues(main);
    const viewport = main.page.getViewport();
    const blank_y: f64 = @floatFromInt(viewport.height - 1);
    try testing.expect((try main.document.hitTest(1, blank_y, main)) == null);

    var ls: js.Local.Scope = undefined;
    main.js.localScope(&ls);
    defer ls.deinit();
    _ = try ls.local.compileAndRun(
        \\window.events = [];
        \\for (const type of ['mouseover', 'mouseout', 'mouseleave', 'mousedown', 'click']) {
        \\  document.documentElement.addEventListener(type, e => events.push(`${type}:${e.target.tagName}`));
        \\}
    , null);
    try triggerMouseMove(main, rect.x + 1, rect.y + 1);
    _ = try ls.local.compileAndRun("events = []", null);

    try triggerMouseMove(main, 1, blank_y);
    try testing.expect(main.page.input_hover_target == main.document.getDocumentElement().?);
    try triggerMousePress(main, 1, blank_y, mouse_button.main, 1);
    try triggerMouseRelease(main, 1, blank_y, mouse_button.main, 1);
    try testing.expect((try ls.local.compileAndRun(
        \\events.join(',') === 'mouseout:INPUT,mouseover:HTML,mousedown:HTML,click:HTML'
    , null)).isTrue());

    _ = try ls.local.compileAndRun("events = []", null);
    try triggerMouseMove(main, 1, blank_y + 10);
    try testing.expect(main.page.input_hover_target == null);
    try testing.expect((try ls.local.compileAndRun("events.join(',') === 'mouseout:HTML,mouseleave:HTML'", null)).isTrue());
}

test "user_input: removing hit iframe in pointerdown stops its mouse sequence" {
    const page = try testing.pageTest("input_mouse_frames.html", .{});
    defer page.close();
    const main = page.frame().?;
    const child = main.child_frames.items[0];
    const target = child.document.getElementById("middle").?;
    const rect = target.boundingClientRectValues(child);
    const iframe_rect = child.iframe.?.asElement().boundingClientRectValues(main);
    var ls: js.Local.Scope = undefined;
    main.js.localScope(&ls);
    defer ls.deinit();
    _ = try ls.local.compileAndRun(
        \\window.events = [];
        \\const childInput = document.getElementById('child').contentDocument.getElementById('middle');
        \\childInput.addEventListener('pointerdown', e => { e.preventDefault(); events.push('pointerdown'); document.getElementById('child').remove(); });
        \\for (const type of ['mousedown', 'focus', 'mouseup', 'click']) childInput.addEventListener(type, () => events.push(type));
    , null);
    try testing.expect((try main.document.hitTest(rect.x + iframe_rect.x + 1, rect.y + iframe_rect.y + 1, main)) == child.iframe.?.asElement());
    try triggerMousePress(main, rect.x + iframe_rect.x + 1, rect.y + iframe_rect.y + 1, mouse_button.main, 1);
    try testing.expect((try ls.local.compileAndRun("events.join(',') === 'pointerdown'", null)).isTrue());
    try testing.expect(child.window._closed);
    try testing.expect(main.page.input_pointer.down_target == null);
    try testing.expectEqual(0, main.page.input_pointer.held);
    try testing.expect(!main.page.input_pointer.mousedown_suppressed);
}

test "user_input: an excluded child document root is not a mouse target" {
    const page = try testing.pageTest("input_mouse_frames.html", .{});
    defer page.close();
    const main = page.frame().?;
    const child = main.child_frames.items[0];
    const iframe = child.iframe.?.asElement();
    const rect = iframe.boundingClientRectValues(main);
    const x = rect.x + 1;
    const y = rect.y + 1;

    const root = child.document.getDocumentElement().?;

    var main_ls: js.Local.Scope = undefined;
    main.js.localScope(&main_ls);
    defer main_ls.deinit();
    _ = try main_ls.local.compileAndRun(
        \\window.parentEvents = [];
        \\for (const type of ['pointermove', 'mousemove', 'pointerdown', 'mousedown', 'pointerup', 'mouseup', 'click', 'wheel']) {
        \\  document.addEventListener(type, () => parentEvents.push(type), true);
        \\}
    , null);

    var child_ls: js.Local.Scope = undefined;
    child.js.localScope(&child_ls);
    defer child_ls.deinit();
    _ = try child_ls.local.compileAndRun(
        \\window.events = [];
        \\for (const type of ['pointerover', 'mouseover', 'pointermove', 'mousemove', 'pointerdown', 'mousedown', 'pointerup', 'mouseup', 'click', 'wheel']) {
        \\  document.addEventListener(type, () => events.push(type), true);
        \\}
    , null);

    for ([_][]const u8{ "display: none", "pointer-events: none" }) |style| {
        try root.setStyle(style, child);
        try testing.expect((try main.document.hitTest(x, y, main)) == iframe);
        try testing.expect((try child.document.hitTest(1, 1, child)) == null);

        try triggerMouseMove(main, x, y);
        try triggerMousePress(main, x, y, mouse_button.main, 1);
        try triggerMouseRelease(main, x, y, mouse_button.main, 1);
        try triggerMouseWheel(main, x, y, 0, 10);
        try testing.expect((try child_ls.local.compileAndRun("events.length === 0", null)).isTrue());
        try testing.expect((try main_ls.local.compileAndRun("parentEvents.length === 0", null)).isTrue());
        try root.setStyle("", child);
    }
}

test "user_input: mouse hit testing still enters a blank child document" {
    const page = try testing.pageTest("input_mouse_frames.html", .{});
    defer page.close();
    const main = page.frame().?;
    const child = main.child_frames.items[0];
    const iframe = child.iframe.?;
    const rect = iframe.asElement().boundingClientRectValues(main);
    const x = rect.x + 1;
    const y = rect.y + 1;
    const edge_hit = try mouseHitTest(main, rect.x + iframe.asElement().getClientWidth(main), y);
    try testing.expect(edge_hit.frame == main);
    try testing.expect(edge_hit.target == iframe.asElement());

    var ls: js.Local.Scope = undefined;
    child.js.localScope(&ls);
    defer ls.deinit();
    _ = try ls.local.compileAndRun("document.documentElement.replaceChildren()", null);

    const hit = try mouseHitTest(main, x, y);
    try testing.expect((try main.document.hitTest(x, y, main)) == iframe.asElement());
    try testing.expect((try child.document.hitTest(1, 1, child)) == null);
    try testing.expect(hit.frame == child);
    try testing.expect(hit.target == child.document.getDocumentElement().?);

    _ = try ls.local.compileAndRun(
        \\window.events = [];
        \\for (const type of ['pointerover', 'mouseover', 'pointermove', 'mousemove', 'pointerdown', 'mousedown', 'pointerup', 'mouseup', 'click']) {
        \\  document.addEventListener(type, e => events.push({type, target: e.target.tagName, x: e.clientX, y: e.clientY}), true);
        \\}
    , null);

    try triggerMouseMove(main, x, y);
    try triggerMousePress(main, x, y, mouse_button.main, 1);
    try triggerMouseRelease(main, x, y, mouse_button.main, 1);
    try testing.expect((try ls.local.compileAndRun(
        \\events.map(e => e.type).join(',') === 'pointerover,mouseover,pointermove,mousemove,pointerdown,mousedown,pointerup,mouseup,click' &&
        \\events.every(e => e.target === 'HTML' && e.x === 1 && e.y === 1)
    , null)).isTrue());
}

test "user_input: excluded child roots clear hover without releasing held buttons" {
    for ([_][]const u8{ "display: none", "pointer-events: none" }) |style| {
        for ([_]bool{ false, true }) |from_child| {
            const page = try testing.pageTest("input_mouse_frames.html", .{});
            defer page.close();
            const main = page.frame().?;
            const child = main.child_frames.items[0];
            const owner = if (from_child) child else main;
            const target = owner.document.getElementById(if (from_child) "middle" else "outer").?;
            const rect = target.boundingClientRectValues(owner);
            const iframe_rect = child.iframe.?.asElement().boundingClientRectValues(main);
            const x = rect.x + (if (from_child) iframe_rect.x else @as(f64, 0)) + 1;
            const y = rect.y + (if (from_child) iframe_rect.y else @as(f64, 0)) + 1;
            var ls: js.Local.Scope = undefined;
            owner.js.localScope(&ls);
            defer ls.deinit();
            _ = try ls.local.compileAndRun(
                \\window.events = [];
                \\const target = document.getElementById(window.parent === window ? 'outer' : 'middle');
                \\for (const type of ['pointerover', 'mouseover', 'pointerenter', 'mouseenter', 'pointerout', 'mouseout', 'pointerleave', 'mouseleave']) {
                \\  target.addEventListener(type, e => events.push({type, buttons:e.buttons, related:e.relatedTarget, trusted:e.isTrusted}));
                \\}
            , null);
            try triggerMouseMove(main, x, y);
            try triggerMousePress(main, x, y, mouse_button.main, 1);
            try testing.expect(main.page.input_hover_target == target);
            const root = child.document.getDocumentElement().?;
            try root.setStyle(style, child);
            try testing.expect((try child.document.hitTest(1, 1, child)) == null);
            try triggerMouseMove(main, iframe_rect.x + 1, iframe_rect.y + 1);
            try testing.expect(main.page.input_hover_target == null);
            try testing.expectEqual(1, main.page.input_pointer.held);
            try testing.expect(main.page.input_pointer.down_target == target);
            try root.setStyle("", child);
            try triggerMouseMove(main, x, y);
            try testing.expect(main.page.input_hover_target == target);
            try testing.expect((try ls.local.compileAndRun(
                \\events.map(e => e.type).join(',') === 'pointerover,mouseover,pointerenter,mouseenter,pointerout,mouseout,pointerleave,mouseleave,pointerover,mouseover,pointerenter,mouseenter' &&
                \\events.every(e => e.related === null && e.trusted) &&
                \\events.slice(0,4).every(e => e.buttons === 0) && events.slice(4).every(e => e.buttons === 1)
            , null)).isTrue());
            try triggerMouseRelease(main, x, y, mouse_button.main, 1);
            try testing.expectEqual(0, main.page.input_pointer.held);
            try testing.expect(main.page.input_pointer.down_target == null);
        }
    }
}

test "user_input: removing a pressed iframe between messages clears pointer state" {
    const page = try testing.pageTest("input_mouse_frames.html", .{});
    defer page.close();
    const main = page.frame().?;
    const child = main.child_frames.items[0];
    const target = child.document.getElementById("middle").?;
    const outer = main.document.getElementById("outer").?;
    const target_rect = target.boundingClientRectValues(child);
    const iframe_rect = child.iframe.?.asElement().boundingClientRectValues(main);
    const outer_rect = outer.boundingClientRectValues(main);

    var main_ls: js.Local.Scope = undefined;
    main.js.localScope(&main_ls);
    defer main_ls.deinit();
    _ = try main_ls.local.compileAndRun(
        \\window.events = [];
        \\const outer = document.getElementById('outer');
        \\for (const type of ['mousedown', 'mouseup', 'click']) {
        \\  outer.addEventListener(type, () => events.push(type));
        \\}
    , null);

    {
        var child_ls: js.Local.Scope = undefined;
        child.js.localScope(&child_ls);
        defer child_ls.deinit();
        _ = try child_ls.local.compileAndRun(
            \\document.getElementById('middle').addEventListener('pointerdown', e => e.preventDefault());
        , null);
    }

    try triggerMousePress(main, target_rect.x + iframe_rect.x + 1, target_rect.y + iframe_rect.y + 1, mouse_button.main, 1);
    try testing.expect(main.page.input_pointer.down_target == target);
    try testing.expectEqual(@as(u16, 1), main.page.input_pointer.held);
    try testing.expect(main.page.input_pointer.mousedown_suppressed);

    // Detach only after press returns so the later release exercises stored state.
    _ = try main_ls.local.compileAndRun("document.getElementById('child').remove()", null);
    try testing.expect(child.window._closed);
    try testing.expect(main.page.input_pointer.down_target == null);
    try testing.expectEqual(@as(u16, 0), main.page.input_pointer.held);
    try testing.expect(!main.page.input_pointer.mousedown_suppressed);

    try triggerMouseRelease(main, outer_rect.x + 1, outer_rect.y + 1, mouse_button.main, 1);
    try testing.expect((try main_ls.local.compileAndRun("events.join(',') === 'mouseup'", null)).isTrue());

    // A stale suppression flag would drop this new gesture's mousedown.
    try triggerMousePress(main, outer_rect.x + 1, outer_rect.y + 1, mouse_button.main, 1);
    try triggerMouseRelease(main, outer_rect.x + 1, outer_rect.y + 1, mouse_button.main, 1);
    try testing.expect((try main_ls.local.compileAndRun("events.join(',') === 'mouseup,mousedown,mouseup,click'", null)).isTrue());
    try testing.expect(main.page.input_pointer.down_target == null);
    try testing.expectEqual(@as(u16, 0), main.page.input_pointer.held);
    try testing.expect(!main.page.input_pointer.mousedown_suppressed);
}

test "user_input: wheel listener removing its iframe prevents the scroll default action" {
    const page = try testing.pageTest("input_mouse_frames.html", .{});
    defer page.close();
    const main = page.frame().?;
    const child = main.child_frames.items[0];

    var main_ls: js.Local.Scope = undefined;
    main.js.localScope(&main_ls);
    defer main_ls.deinit();
    _ = try main_ls.local.compileAndRun(
        \\window.parentWheels = 0;
        \\window.wheelEvents = 0;
        \\document.addEventListener('wheel', () => parentWheels++, true);
    , null);

    {
        var child_ls: js.Local.Scope = undefined;
        child.js.localScope(&child_ls);
        defer child_ls.deinit();
        _ = try child_ls.local.compileAndRun(
            \\const box = document.createElement('div');
            \\box.id = 'wheelBox';
            \\box.setAttribute('style', 'width:80px;height:10px;overflow:auto');
            \\const content = document.createElement('div');
            \\content.setAttribute('style', 'height:100px');
            \\box.appendChild(content);
            \\document.body.appendChild(box);
            \\box.addEventListener('wheel', () => {
            \\  parent.wheelEvents++;
            \\  parent.document.getElementById('child').remove();
            \\});
        , null);
    }

    const box = child.document.getElementById("wheelBox").?;
    const box_rect = box.boundingClientRectValues(child);
    const iframe_rect = child.iframe.?.asElement().boundingClientRectValues(main);
    const x = box_rect.x + iframe_rect.x + 1;
    const y = box_rect.y + iframe_rect.y + 1;
    try testing.expect(box.getScrollHeight(child) > box.getClientHeight(child));
    try testing.expectEqual(@as(u32, 0), box.getScrollTop(child));
    const child_hit = (try child.document.hitTest(box_rect.x + 1, box_rect.y + 1, child)).?;
    try testing.expect(box.asNode().contains(child_hit.asNode()));

    try triggerMouseWheel(main, x, y, 0, 20);

    try testing.expect(child.window._closed);
    try testing.expect((try main_ls.local.compileAndRun("wheelEvents === 1 && parentWheels === 0 && window.scrollY === 0", null)).isTrue());
    const scroll: Element.ScrollPosition = main.page.element_scroll_positions.get(box) orelse .{};
    try testing.expectEqual(@as(u32, 0), scroll.y);
}

test "user_input: mouse hover transitions cross nested iframe documents" {
    const page = try testing.pageTest("input_mouse_frames.html", .{});
    defer page.close();
    const main = page.frame().?;
    const child = main.child_frames.items[0];
    const nested = child.child_frames.items[0];

    const outer = main.document.getElementById("outer").?;
    const child_iframe = child.iframe.?.asElement();
    const middle = child.document.getElementById("middle").?;
    const nested_iframe = nested.iframe.?.asElement();
    const inner = nested.document.getElementById("inner").?;
    const outer_rect = outer.boundingClientRectValues(main);
    const child_rect = child_iframe.boundingClientRectValues(main);
    const middle_rect = middle.boundingClientRectValues(child);
    const nested_rect = nested_iframe.boundingClientRectValues(child);
    const inner_rect = inner.boundingClientRectValues(nested);

    var main_ls: js.Local.Scope = undefined;
    main.js.localScope(&main_ls);
    defer main_ls.deinit();
    _ = try main_ls.local.compileAndRun(
        \\window.events = [];
        \\const watch = (where, el) => {
        \\  for (const type of ['pointerout', 'pointerleave', 'pointerover', 'pointerenter', 'mouseout', 'mouseleave', 'mouseover', 'mouseenter']) {
        \\    el.addEventListener(type, e => events.push({where, type, related: e.relatedTarget?.id || null, x: e.clientX, y: e.clientY}));
        \\  }
        \\};
        \\const child = document.getElementById('child');
        \\const middle = child.contentDocument.getElementById('middle');
        \\const nested = child.contentDocument.getElementById('nested');
        \\const inner = nested.contentDocument.getElementById('inner');
        \\watch('outer', document.getElementById('outer'));
        \\watch('child', child);
    , null);

    var child_ls: js.Local.Scope = undefined;
    child.js.localScope(&child_ls);
    defer child_ls.deinit();
    _ = try child_ls.local.compileAndRun(
        \\const watch = (where, el) => {
        \\  for (const type of ['pointerout', 'pointerleave', 'pointerover', 'pointerenter', 'mouseout', 'mouseleave', 'mouseover', 'mouseenter']) {
        \\    el.addEventListener(type, e => parent.events.push({where, type, related: e.relatedTarget?.id || null, x: e.clientX, y: e.clientY}));
        \\  }
        \\};
        \\watch('middle', document.getElementById('middle'));
        \\watch('nested', document.getElementById('nested'));
    , null);

    var nested_ls: js.Local.Scope = undefined;
    nested.js.localScope(&nested_ls);
    defer nested_ls.deinit();
    _ = try nested_ls.local.compileAndRun(
        \\const watch = (where, el) => {
        \\  for (const type of ['pointerout', 'pointerleave', 'pointerover', 'pointerenter', 'mouseout', 'mouseleave', 'mouseover', 'mouseenter']) {
        \\    el.addEventListener(type, e => parent.parent.events.push({where, type, related: e.relatedTarget?.id || null, x: e.clientX, y: e.clientY}));
        \\  }
        \\};
        \\watch('inner', document.getElementById('inner'));
    , null);

    // Start on the top-level input, then enter the child input.
    try triggerMouseMove(main, outer_rect.x + 1, outer_rect.y + 1);
    _ = try main_ls.local.compileAndRun("events = []", null);
    try triggerMouseMove(main, child_rect.x + middle_rect.x + 1, child_rect.y + middle_rect.y + 1);
    try testing.expect((try main_ls.local.compileAndRun(
        \\events.map(e => `${e.where}:${e.type}`).join(',') ===
        \\'outer:pointerout,outer:mouseout,outer:pointerleave,outer:mouseleave,' +
        \\'child:pointerover,child:mouseover,child:pointerenter,child:mouseenter,' +
        \\'middle:pointerover,middle:mouseover,middle:pointerenter,middle:mouseenter' &&
        \\events.find(e => e.where === 'outer' && e.type === 'pointerout').related === 'child' &&
        \\events.find(e => e.where === 'child' && e.type === 'pointerover').related === 'outer' &&
        \\events.find(e => e.where === 'middle' && e.type === 'pointerover').related === null &&
        \\events.find(e => e.where === 'outer' && e.type === 'pointerout').x === child.getBoundingClientRect().x + middle.getBoundingClientRect().x + 1 &&
        \\events.find(e => e.where === 'child' && e.type === 'pointerover').x === child.getBoundingClientRect().x + middle.getBoundingClientRect().x + 1 &&
        \\events.find(e => e.where === 'middle' && e.type === 'pointerover').x === middle.getBoundingClientRect().x + 1 &&
        \\events.find(e => e.where === 'middle' && e.type === 'pointerover').y === middle.getBoundingClientRect().y + 1
    , null)).isTrue());

    // Enter the nested frame from its parent document.
    _ = try main_ls.local.compileAndRun("events = []", null);
    const nested_x = child_rect.x + nested_rect.x + inner_rect.x + 1;
    const nested_y = child_rect.y + nested_rect.y + inner_rect.y + 1;
    try triggerMouseMove(main, nested_x, nested_y);
    try testing.expect((try main_ls.local.compileAndRun(
        \\events.map(e => `${e.where}:${e.type}`).join(',') ===
        \\'middle:pointerout,middle:mouseout,middle:pointerleave,middle:mouseleave,' +
        \\'nested:pointerover,nested:mouseover,nested:pointerenter,nested:mouseenter,' +
        \\'inner:pointerover,inner:mouseover,inner:pointerenter,inner:mouseenter' &&
        \\events.find(e => e.where === 'middle' && e.type === 'pointerout').related === 'nested' &&
        \\events.find(e => e.where === 'nested' && e.type === 'pointerover').related === 'middle' &&
        \\events.find(e => e.where === 'inner' && e.type === 'pointerover').related === null &&
        \\events.find(e => e.where === 'middle' && e.type === 'pointerout').x === nested.getBoundingClientRect().x + inner.getBoundingClientRect().x + 1 &&
        \\events.find(e => e.where === 'nested' && e.type === 'pointerover').x === nested.getBoundingClientRect().x + inner.getBoundingClientRect().x + 1 &&
        \\events.find(e => e.where === 'inner' && e.type === 'pointerover').x === inner.getBoundingClientRect().x + 1 &&
        \\events.find(e => e.where === 'inner' && e.type === 'pointerover').y === inner.getBoundingClientRect().y + 1
    , null)).isTrue());

    // Leaving the nested frame keeps relatedTarget local to the child document.
    _ = try main_ls.local.compileAndRun("events = []", null);
    try triggerMouseMove(main, child_rect.x + middle_rect.x + 1, child_rect.y + middle_rect.y + 1);
    try testing.expect((try main_ls.local.compileAndRun(
        \\events.map(e => `${e.where}:${e.type}`).join(',') ===
        \\'inner:pointerout,inner:mouseout,inner:pointerleave,inner:mouseleave,' +
        \\'nested:pointerout,nested:mouseout,nested:pointerleave,nested:mouseleave,' +
        \\'middle:pointerover,middle:mouseover,middle:pointerenter,middle:mouseenter' &&
        \\events.find(e => e.where === 'inner' && e.type === 'pointerout').related === null &&
        \\events.find(e => e.where === 'nested' && e.type === 'pointerout').related === 'middle' &&
        \\events.find(e => e.where === 'middle' && e.type === 'pointerover').related === 'nested' &&
        \\events.find(e => e.where === 'middle' && e.type === 'pointerover').x === middle.getBoundingClientRect().x + 1
    , null)).isTrue());

    // Leave the child frame for the top-level input.
    _ = try main_ls.local.compileAndRun("events = []", null);
    try triggerMouseMove(main, outer_rect.x + 1, outer_rect.y + 1);
    try testing.expect((try main_ls.local.compileAndRun(
        \\events.map(e => `${e.where}:${e.type}`).join(',') ===
        \\'middle:pointerout,middle:mouseout,middle:pointerleave,middle:mouseleave,' +
        \\'child:pointerout,child:mouseout,child:pointerleave,child:mouseleave,' +
        \\'outer:pointerover,outer:mouseover,outer:pointerenter,outer:mouseenter' &&
        \\events.find(e => e.where === 'middle' && e.type === 'pointerout').related === null &&
        \\events.find(e => e.where === 'child' && e.type === 'pointerout').related === 'outer' &&
        \\events.find(e => e.where === 'outer' && e.type === 'pointerover').related === 'child' &&
        \\events.find(e => e.where === 'outer' && e.type === 'pointerover').x === document.getElementById('outer').getBoundingClientRect().x + 1 &&
        \\events.find(e => e.where === 'outer' && e.type === 'pointerover').y === document.getElementById('outer').getBoundingClientRect().y + 1
    , null)).isTrue());
}

test "user_input: mouse blank iframe takes document focus" {
    const page = try testing.pageTest("input_mouse_frames.html", .{});
    defer page.close();
    const main = page.frame().?;
    const child = main.child_frames.items[0];
    const outer = main.document.getElementById("outer").?;
    var ls: js.Local.Scope = undefined;
    child.js.localScope(&ls);
    defer ls.deinit();
    _ = try ls.local.compileAndRun("document.body.replaceChildren();", null);
    try outer.focus(main);
    const rect = child.iframe.?.asElement().boundingClientRectValues(main);
    try triggerMousePress(main, rect.x + 1, rect.y + 1, mouse_button.main, 1);
    try triggerMouseRelease(main, rect.x + 1, rect.y + 1, mouse_button.main, 1);
    try testing.expect(main.document._active_element == child.iframe.?.asElement());
    try testing.expect(focusedFrame(main) == child);
    try insertText(focusedFrame(main), "wrong-document");
    var outer_scope: js.Local.Scope = undefined;
    main.js.localScope(&outer_scope);
    defer outer_scope.deinit();
    try testing.expect((try outer_scope.local.compileAndRun("document.getElementById('outer').value === ''", null)).isTrue());
}

test "user_input: mouse static nested iframe takes document focus" {
    const page = try testing.pageTest("input_mouse_frames.html", .{});
    defer page.close();
    const main = page.frame().?;
    const child = main.child_frames.items[0];
    const nested = child.child_frames.items[0];
    var ls: js.Local.Scope = undefined;
    nested.js.localScope(&ls);
    defer ls.deinit();
    _ = try ls.local.compileAndRun("document.body.innerHTML = '<div style=width:150px;height:150px>static</div>';", null);
    try main.document.getElementById("outer").?.focus(main);
    const child_rect = child.iframe.?.asElement().boundingClientRectValues(main);
    const nested_rect = nested.iframe.?.asElement().boundingClientRectValues(child);
    const x = child_rect.x + nested_rect.x + 10;
    const y = child_rect.y + nested_rect.y + 10;
    try triggerMousePress(main, x, y, mouse_button.main, 1);
    try triggerMouseRelease(main, x, y, mouse_button.main, 1);
    try testing.expect(main.document._active_element == child.iframe.?.asElement());
    try testing.expect(child.document._active_element == nested.iframe.?.asElement());
    try testing.expect(focusedFrame(main) == nested);
}

test "user_input: mouse blank iframe cancelled press preserves focus" {
    for ([_][]const u8{ "pointerdown", "mousedown" }) |event| {
        const page = try testing.pageTest("input_mouse_frames.html", .{});
        defer page.close();
        const main = page.frame().?;
        const child = main.child_frames.items[0];
        const outer = main.document.getElementById("outer").?;
        var ls: js.Local.Scope = undefined;
        child.js.localScope(&ls);
        defer ls.deinit();
        _ = try ls.local.compileAndRun("document.body.replaceChildren();", null);
        const script = try std.fmt.allocPrint(testing.allocator, "document.addEventListener('{s}', e => e.preventDefault());", .{event});
        defer testing.allocator.free(script);
        _ = try ls.local.compileAndRun(script, null);
        try outer.focus(main);
        const rect = child.iframe.?.asElement().boundingClientRectValues(main);
        try triggerMousePress(main, rect.x + 1, rect.y + 1, mouse_button.main, 1);
        try triggerMouseRelease(main, rect.x + 1, rect.y + 1, mouse_button.main, 1);
        try testing.expect(main.document._active_element == outer);
        try testing.expect(focusedFrame(main) == main);
    }
}

test "user_input: mouse removed blank iframe does not take focus" {
    for ([_][]const u8{ "pointerdown", "mousedown" }) |event| {
        const page = try testing.pageTest("input_mouse_frames.html", .{});
        defer page.close();
        const main = page.frame().?;
        const child = main.child_frames.items[0];
        const outer = main.document.getElementById("outer").?;
        var ls: js.Local.Scope = undefined;
        main.js.localScope(&ls);
        defer ls.deinit();
        const script = try std.fmt.allocPrint(testing.allocator,
            \\const iframe = document.getElementById('child');
            \\iframe.contentDocument.body.replaceChildren();
            \\iframe.contentDocument.addEventListener('{s}', () => iframe.remove());
        , .{event});
        defer testing.allocator.free(script);
        _ = try ls.local.compileAndRun(script, null);
        try outer.focus(main);
        const rect = child.iframe.?.asElement().boundingClientRectValues(main);
        try triggerMousePress(main, rect.x + 1, rect.y + 1, mouse_button.main, 1);
        try testing.expect(child.window._closed);
        try testing.expect(main.document._active_element == outer);
        try testing.expect(focusedFrame(main) == main);
        try testing.expect(main.page.input_pointer.down_target == null);
    }
}

test "user_input: mouse blank sibling iframe clears old focus chain" {
    const page = try testing.pageTest("input_mouse_frames.html", .{});
    defer page.close();
    const main = page.frame().?;
    const child = main.child_frames.items[0];
    const sibling = main.child_frames.items[1];
    const middle = child.document.getElementById("middle").?;
    var ls: js.Local.Scope = undefined;
    main.js.localScope(&ls);
    defer ls.deinit();
    _ = try ls.local.compileAndRun(
        \\window.events = [];
        \\document.getElementById('child').contentDocument.getElementById('middle').addEventListener('blur', () => events.push('blur'));
        \\for (const iframe of document.querySelectorAll('iframe')) {
        \\  for (const type of ['focus', 'focusin', 'blur', 'focusout']) iframe.addEventListener(type, () => events.push('iframe-' + type));
        \\}
    , null);
    try middle.focus(child);
    const rect = sibling.iframe.?.asElement().boundingClientRectValues(main);
    try triggerMousePress(main, rect.x + 1, rect.y + 1, mouse_button.main, 1);
    try triggerMouseRelease(main, rect.x + 1, rect.y + 1, mouse_button.main, 1);
    try testing.expect(main.document._active_element == sibling.iframe.?.asElement());
    try testing.expect(child.document._active_element == null);
    try testing.expect(focusedFrame(main) == sibling);
    try insertText(focusedFrame(main), "wrong-document");
    try testing.expect((try ls.local.compileAndRun(
        \\events.join(',') === 'blur' && document.getElementById('child').contentDocument.getElementById('middle').value === ''
    , null)).isTrue());
}

test "user_input: synthetic blank iframe click preserves focus" {
    const page = try testing.pageTest("input_mouse_frames.html", .{});
    defer page.close();
    const main = page.frame().?;
    const outer = main.document.getElementById("outer").?;
    try outer.focus(main);
    var ls: js.Local.Scope = undefined;
    main.js.localScope(&ls);
    defer ls.deinit();
    _ = try ls.local.compileAndRun("document.getElementById('sibling').contentDocument.body.click();", null);
    try testing.expect(main.document._active_element == outer);
    try testing.expect(focusedFrame(main) == main);
}

test "user_input: shadow mouse rects are viewport relative and native clicks reach inner target" {
    const page = try testing.pageTest("input_mouse_shadow.html", .{});
    defer page.close();
    const frame = page.frame().?;
    var ls: js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();
    const host = frame.document.getElementById("host").?;
    const inner = try ls.local.jsValueToZig(*Element, try ls.local.compileAndRun("inner", null));
    const host_rect = host.boundingClientRectValues(frame);
    const rect = inner.boundingClientRectValues(frame);
    try testing.expectEqual(host_rect.x + 20, rect.x);
    try testing.expectEqual(host_rect.y + 5, rect.y);
    const x = rect.x + 1;
    const y = rect.y + 1;
    try testing.expect((try mouseHitTest(frame, x, y)).target == inner);
    try triggerMouseMove(frame, x, y);
    try triggerMousePress(frame, x, y, mouse_button.main, 1);
    try triggerMouseRelease(frame, x, y, mouse_button.main, 1);
    try testing.expect((try ls.local.compileAndRun(
        \\events.length === 2 && events[0].listener === 'inner' && events[0].target === 'inner' &&
        \\events[1].listener === 'host' && events[1].target === 'host' && events[1].inner && events.every(e => e.trusted)
    , null)).isTrue());
}

test "user_input: shadow mouse hit testing respects bounds and hidden descendants" {
    const page = try testing.pageTest("input_mouse_shadow.html", .{});
    defer page.close();
    const frame = page.frame().?;
    var ls: js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();
    const host = frame.document.getElementById("host").?;
    const inner = try ls.local.jsValueToZig(*Element, try ls.local.compileAndRun("inner", null));
    const rect = inner.boundingClientRectValues(frame);
    try testing.expect((try mouseHitTest(frame, rect.x, rect.y)).target == inner);
    try testing.expect((try mouseHitTest(frame, rect.x + rect.width + 1, rect.y + 1)).target == host);
    try testing.expect((try mouseHitTest(frame, rect.x + 1, rect.y + rect.height + 1)).target == host);
    try testing.expect((try mouseHitTest(frame, rect.x - 1, rect.y + 1)).target == host);
    for ([_][]const u8{ "pointer-events:none", "visibility:hidden", "display:none" }) |style| {
        try inner.setStyle(try std.fmt.allocPrint(frame.local_arena, "transform:translateX(20px);width:80px;height:60px;{s}", .{style}), frame);
        try testing.expect((try mouseHitTest(frame, rect.x + 1, rect.y + 1)).target == host);
    }
    _ = try ls.local.compileAndRun(
        \\root.innerHTML = '<div style="display:none"><button style="width:100px;height:100px">Hidden</button></div>';
    , null);
    try testing.expect((try mouseHitTest(frame, rect.x + 1, rect.y + 1)).target == host);
}

test "user_input: shadow mouse nested closed roots and window scroll share coordinates" {
    const page = try testing.pageTest("input_mouse_shadow.html", .{});
    defer page.close();
    const frame = page.frame().?;
    var ls: js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();
    const target = try ls.local.jsValueToZig(*Element, try ls.local.compileAndRun(
        \\root.innerHTML = '<div id="nested" style="transform:translateX(10px);width:150px;height:150px"></div>';
        \\const nested = root.getElementById('nested');
        \\const closedRoot = nested.attachShadow({mode:'closed'});
        \\closedRoot.innerHTML = '<button id="deep" style="transform:translateX(15px);width:60px;height:40px">Deep</button>';
        \\const deep = closedRoot.getElementById('deep');
        \\window.deepClicks = 0;
        \\deep.addEventListener('click', e => { if (e.isTrusted && e.target === deep) deepClicks++; });
        \\deep;
    , null));
    const host = frame.document.getElementById("host").?;
    const host_rect = host.boundingClientRectValues(frame);
    const before = target.boundingClientRectValues(frame);
    try testing.expectEqual(host_rect.x + 25, before.x);
    try testing.expectEqual(host_rect.y + 10, before.y);
    _ = try ls.local.compileAndRun("document.body.style.width = '3000px'; document.body.style.height = '3000px'; window.scrollTo(30, 10)", null);
    const rect = target.boundingClientRectValues(frame);
    try testing.expectEqual(before.x - 30, rect.x);
    try testing.expectEqual(before.y - 10, rect.y);
    try testing.expect((try mouseHitTest(frame, rect.x + 1, rect.y + 1)).target == target);
    try triggerMousePress(frame, rect.x + 1, rect.y + 1, mouse_button.main, 1);
    try triggerMouseRelease(frame, rect.x + 1, rect.y + 1, mouse_button.main, 1);
    try testing.expect((try ls.local.compileAndRun("deepClicks === 1 && nested.shadowRoot === null", null)).isTrue());
    _ = try ls.local.compileAndRun("nested.style.display = 'none'", null);
    try testing.expect((try mouseHitTest(frame, rect.x + 1, rect.y + 1)).target == host);
}

test "user_input: shadow mouse descendants can override inherited hit exclusions" {
    const page = try testing.pageTest("input_mouse_shadow.html", .{});
    defer page.close();
    const frame = page.frame().?;
    var ls: js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();
    const target = try ls.local.jsValueToZig(*Element, try ls.local.compileAndRun(
        \\root.innerHTML = '<div style="pointer-events:none;visibility:hidden;width:150px;height:150px"><button id="enabled" style="pointer-events:auto;visibility:visible;width:60px;height:40px">Enabled</button></div>';
        \\root.getElementById('enabled');
    , null));
    const rect = target.boundingClientRectValues(frame);
    try testing.expect((try mouseHitTest(frame, rect.x + 1, rect.y + 1)).target == target);
}

test "user_input: shadow mouse keeps host boundary path and common click target" {
    for ([_][]const u8{ "open", "closed" }) |mode| {
        const page = try testing.pageTest("input_mouse_shadow.html", .{});
        defer page.close();
        const frame = page.frame().?;
        var ls: js.Local.Scope = undefined;
        frame.js.localScope(&ls);
        defer ls.deinit();
        _ = try ls.local.compileAndRun(try std.fmt.allocPrint(frame.local_arena, "window.boundaryMode = '{s}'", .{mode}), null);
        const inner = try ls.local.jsValueToZig(*Element, try ls.local.compileAndRun(
            \\document.body.innerHTML = '<div id="boundaryHost" style="transform:translateX(80px);width:200px;height:200px"></div>';
            \\const boundaryHost = document.getElementById('boundaryHost');
            \\const boundaryRoot = boundaryHost.attachShadow({mode:boundaryMode});
            \\boundaryRoot.innerHTML = '<button id="boundaryInner" style="transform:translateX(20px);width:80px;height:60px">Inner</button>';
            \\const boundaryInner = boundaryRoot.getElementById('boundaryInner');
            \\window.enters = []; window.leaves = []; window.clicks = [];
            \\boundaryHost.addEventListener('mouseenter', () => enters.push('mouse'));
            \\boundaryHost.addEventListener('pointerenter', () => enters.push('pointer'));
            \\boundaryHost.addEventListener('mouseleave', () => leaves.push('mouse'));
            \\boundaryHost.addEventListener('pointerleave', () => leaves.push('pointer'));
            \\boundaryInner.addEventListener('click', e => clicks.push({where:'inner', target:e.target.id, trusted:e.isTrusted}));
            \\boundaryHost.addEventListener('click', e => clicks.push({where:'host', target:e.target.id, trusted:e.isTrusted, inner:e.composedPath().includes(boundaryInner)}));
            \\boundaryInner;
        , null));
        const host = frame.document.getElementById("boundaryHost").?;
        const rect = inner.boundingClientRectValues(frame);
        const host_rect = host.boundingClientRectValues(frame);
        try triggerMouseMove(frame, rect.x + 1, rect.y + 1);
        try testing.expect((try ls.local.compileAndRun("enters.join(',') === 'pointer,mouse' && leaves.length === 0", null)).isTrue());
        // Moving within the host does not leave or re-enter it.
        try triggerMouseMove(frame, host_rect.x + 1, host_rect.y + 1);
        try triggerMouseMove(frame, rect.x + 1, rect.y + 1);
        try testing.expect((try ls.local.compileAndRun("enters.length === 2 && leaves.length === 0", null)).isTrue());
        try triggerMousePress(frame, rect.x + 1, rect.y + 1, mouse_button.main, 1);
        try triggerMouseRelease(frame, rect.x + 1, rect.y + 1, mouse_button.main, 1);
        try testing.expect((try ls.local.compileAndRun(
            \\clicks.length === 2 && clicks[0].where === 'inner' && clicks[0].target === 'boundaryInner' &&
            \\clicks[1].where === 'host' && clicks[1].target === 'boundaryHost' &&
            \\clicks[1].inner === (boundaryMode === 'open') && clicks.every(e => e.trusted)
        , null)).isTrue());
        _ = try ls.local.compileAndRun("clicks = []", null);
        try triggerMousePress(frame, host_rect.x + 1, host_rect.y + 1, mouse_button.main, 1);
        try triggerMouseRelease(frame, rect.x + 1, rect.y + 1, mouse_button.main, 1);
        try testing.expect((try ls.local.compileAndRun("clicks.length === 1 && clicks[0].where === 'host' && clicks[0].trusted", null)).isTrue());
        try triggerMouseMove(frame, -1, -1);
        try testing.expect((try ls.local.compileAndRun("leaves.join(',') === 'pointer,mouse'", null)).isTrue());
    }
}

test "user_input: shadow mouse wheel preserves outer scroll container" {
    const page = try testing.pageTest("input_mouse_shadow.html", .{});
    defer page.close();
    const frame = page.frame().?;
    var ls: js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();
    const inner = try ls.local.jsValueToZig(*Element, try ls.local.compileAndRun(
        \\const scroller = document.createElement('div');
        \\scroller.id = 'scroller'; scroller.style = 'overflow:auto;width:400px;height:100px';
        \\host.before(scroller); scroller.appendChild(host);
        \\inner;
    , null));
    const rect = inner.boundingClientRectValues(frame);
    const scroller = frame.document.getElementById("scroller").?;
    try testing.expect(scroller.getScrollHeight(frame) > scroller.getClientHeight(frame));
    try triggerMouseWheel(frame, rect.x + 1, rect.y + 1, 0, 20);
    try testing.expectEqual(@as(u32, 20), scroller.getScrollTop(frame));
    try testing.expectEqual(@as(u32, 0), frame.window.getScrollY());
}

test "user_input: shadow mouse press and release on shadow siblings clicks the host" {
    const page = try testing.pageTest("input_mouse_shadow.html", .{});
    defer page.close();
    const frame = page.frame().?;
    var ls: js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();
    const other = try ls.local.jsValueToZig(*Element, try ls.local.compileAndRun(
        \\const other = document.createElement('button');
        \\other.style = 'width:50px;height:60px'; other.textContent = 'Other'; root.appendChild(other);
        \\other.addEventListener('click', () => events.push({listener:'other'}));
        \\other;
    , null));
    const inner = try ls.local.jsValueToZig(*Element, try ls.local.compileAndRun("inner", null));
    const start = inner.boundingClientRectValues(frame);
    const end = other.boundingClientRectValues(frame);
    try testing.expect((try mouseHitTest(frame, start.x + 1, start.y + 1)).target == inner);
    try testing.expect((try mouseHitTest(frame, end.x + end.width - 1, end.y + 1)).target == other);
    try triggerMousePress(frame, start.x + 1, start.y + 1, mouse_button.main, 1);
    try triggerMouseRelease(frame, end.x + end.width - 1, end.y + 1, mouse_button.main, 1);
    try testing.expect((try ls.local.compileAndRun("events.length === 1 && events[0].listener === 'host' && events[0].trusted", null)).isTrue());
}
