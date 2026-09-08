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

pub const HoverContext = struct {
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
    const page = frame._page;
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

// Dispatch a single trusted mouse event of the given type on `target`, carrying
// the pressed button and pointer position. `detail` is the click count (used for
// click/dblclick); 0 for events where it does not apply.
fn dispatchMouseEventOn(frame: *Frame, target: *Element, comptime typ: []const u8, x: f64, y: f64, button: i32, detail: u32) !void {
    const event: *MouseEvent = try .initTrusted(comptime .wrap(typ), .{
        .bubbles = true,
        .cancelable = true,
        .composed = true,
        .clientX = x,
        .clientY = y,
        .button = button,
        .detail = detail,
    }, frame);
    try frame._event_manager.dispatch(target.asEventTarget(), event.asEvent());
}

pub fn triggerMousePress(frame: *Frame, x: f64, y: f64, button: i32) !void {
    const target = (try frame.window._document.elementFromPoint(x, y, frame)) orelse return;
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
    try dispatchMouseEventOn(frame, target, "mousedown", x, y, button, 0);
    try focusEditingHostForMouseDown(frame, target);
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

    try dispatchMouseEventOn(frame, target, "mouseup", x, y, button, detail);

    // After mouseup, the activation event depends on the button.
    switch (button) {
        mouse_button.main => {
            try dispatchMouseEventOn(frame, target, "click", x, y, button, detail);
            // A second click in quick succession also fires dblclick.
            if (click_count == 2) {
                try dispatchMouseEventOn(frame, target, "dblclick", x, y, button, detail);
            }
        },
        mouse_button.auxiliary => try dispatchMouseEventOn(frame, target, "auxclick", x, y, button, detail),
        mouse_button.secondary => try dispatchMouseEventOn(frame, target, "contextmenu", x, y, button, detail),
        else => {},
    }
}

pub fn triggerMouseWheel(frame: *Frame, x: f64, y: f64, delta_x: f64, delta_y: f64) !void {
    const target = (try frame.window._document.elementFromPoint(x, y, frame)) orelse return;
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

    const wheel_event: *WheelEvent = try .initTrusted("wheel", .{
        .bubbles = true,
        .cancelable = true,
        .composed = true,
        .clientX = x,
        .clientY = y,
        .deltaX = delta_x,
        .deltaY = delta_y,
    }, frame);

    // Keep the event alive past dispatch so we can read _prevent_default.
    wheel_event.asEvent().acquireRef();
    defer _ = wheel_event.asEvent().releaseRef(frame._page);
    try frame._event_manager.dispatch(target.asEventTarget(), wheel_event.asEvent());

    if (wheel_event.asEvent()._prevent_default) {
        return;
    }

    // Apply the scroll and fire a trusted scroll event, mirroring WebDriver wheel.
    // CDP deltas are untrusted, so guard NaN and saturate the addition.
    const new_left: i32 = @as(i32, @intCast(target.getScrollLeft(frame))) +| deltaToScroll(delta_x);
    const new_top: i32 = @as(i32, @intCast(target.getScrollTop(frame))) +| deltaToScroll(delta_y);
    try target.setScrollLeft(new_left, frame);
    try target.setScrollTop(new_top, frame);

    const scroll_event = try Event.initTrusted(comptime .wrap("scroll"), .{ .bubbles = true }, frame._page);
    try frame._event_manager.dispatch(target.asEventTarget(), scroll_event);
}

fn deltaToScroll(d: f64) i32 {
    if (std.math.isNan(d)) return 0;
    return @trunc(std.math.clamp(d, std.math.minInt(i32), std.math.maxInt(i32)));
}

// callback when the "click" event reaches the frame.
// Whether the element has a click activation behavior that handleClick
// implements.
fn hasClickActivationBehavior(node: *Node) bool {
    const element = node.is(Element) orelse return false;

    const html_element = element.is(Element.Html) orelse {
        if (element.is(Element.Svg.Graphics.A) != null) {
            return svgAnchorHref(element) != null;
        }
        return false;
    };

    return switch (html_element._type) {
        .anchor => element.getAttributeSafe(comptime .wrap("href")) != null,
        .input, .button, .select, .textarea, .label => true,
        .generic => html_element.subtype(Element.Html.Generic)._tag == .summary,
        else => false,
    };
}

// SVG 2 <a> links via `href`; xlink:href is the deprecated SVG 1.1 spelling.
fn svgAnchorHref(element: *Element) ?[]const u8 {
    return element.getAttributeSafe(comptime .wrap("href")) orelse element.getAttributeSafe(comptime .wrap("xlink:href"));
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

// A mousedown on editable content focuses its editing host: the outermost
// element of the contiguous editable chain containing the target.
pub fn focusEditingHostForMouseDown(frame: *Frame, target: *Element) !void {
    var node: ?*Node = target.asNode();
    var editable: ?*Node = null;
    while (node) |n| : (node = n._parent) {
        if (isEditingHost(n)) {
            editable = n;
            break;
        }
    }
    var host = editable orelse return;
    while (host._parent) |p| {
        if (!isEditingHost(p)) {
            break;
        }
        host = p;
    }
    const host_element = host.is(Element) orelse return;
    try host_element.focus(frame);
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
        const target_name = element.getAttributeSafe(comptime .wrap("target")) orelse "";
        return followLink(frame, target, element, href, target_name);
    }

    const html_element = element.is(Element.Html) orelse return;

    switch (html_element._type) {
        .anchor => {
            const anchor = html_element.subtype(Element.Html.Anchor);
            const href = element.getAttributeSafe(comptime .wrap("href")) orelse return;
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
        return runJavascriptUrl(target.ownerFrame(frame), href["javascript:".len..]);
    }

    if (try element.hasAttribute(comptime .wrap("download"), frame)) {
        log.warn(.browser, "a.download", .{ .type = frame._type, .url = frame.url });
        return;
    }

    const target_frame = blk: {
        if (target_name.len == 0) {
            break :blk target.ownerFrame(frame);
        }
        break :blk switch (frame.resolveTargetFrame(target_name)) {
            .frame => |f| f,
            .blank => {
                try element.focus(frame);
                _ = try target.ownerFrame(frame).openBlankTarget(element, href);
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

pub fn triggerKeyboard(frame: *Frame, keyboard_event: *KeyboardEvent) !void {
    const event = keyboard_event.asEvent();
    // Dispatch to the effective active element. When nothing is explicitly
    // focused this resolves to <body> (matching `document.activeElement`), so
    // the keydown still fires and its default action — e.g. sequential focus
    // navigation on Tab — can run.
    const element = frame.window._document.getActiveElement() orelse {
        event.deinit(frame._page);
        return;
    };

    if (comptime lp.IS_DEBUG) {
        log.debug(.frame, "frame keydown", .{
            .url = frame.url,
            .node = element,
            .key = keyboard_event._key,
            .type = frame._type,
        });
    }
    try frame._event_manager.dispatch(element.asEventTarget(), event);
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

    if (event.getIsTrusted()) {
        if ((key.isPrintable() or key == .Enter) and keyboard_event.getCtrlKey() == false and keyboard_event.getMetaKey() == false) {
            // Fire a keypress for a printable (or Enter) keydown when ctrl/meta
            // aren't pressed
            if (try dispatchKeypress(frame, target, keyboard_event)) {
                return;
            }
        }

        if (key == .Enter) {
            if (target.is(Element)) |element| {
                if (enterActivates(element)) {
                    // Enter generates a button-like "click" for  some elements
                    return dispatchKeyboardClick(frame, element);
                }
            }
        }
    }

    if (target.is(Element.Html.Input)) |input| {
        if (key == .Enter) {
            return frame.submitForm(input.asElement(), input.getForm(frame), .{});
        }

        // Don't handle text input for radio/checkbox
        const input_type = input._input_type;
        if (input_type == .radio or input_type == .checkbox) {
            return;
        }

        return editKey(frame, keyboard_event, input, key);
    }

    if (target.is(Element.Html.TextArea)) |textarea| {
        if (key == .Enter) {
            if (try allowEdit(frame, event, textarea.asElement(), null, "\n", "insertLineBreak")) {
                try textarea.innerInsert("\n", frame);
            }
            return;
        }

        return editKey(frame, keyboard_event, textarea, key);
    }
}

// edit keys are handled by Input and TextArea the same
fn editKey(frame: *Frame, keyboard_event: *KeyboardEvent, ctl: anytype, key: KeyboardEvent.Key) !void {
    const event = keyboard_event.asEvent();

    if (caretMove(key, ctl)) |move| {
        // Word/paragraph motions (ctrl/alt/meta variants) aren't modeled.
        if (keyboard_event.getCtrlKey() or keyboard_event.getAltKey() or keyboard_event.getMetaKey()) {
            return;
        }
        return ctl.moveCaret(move, keyboard_event.getShiftKey(), frame);
    }

    if (key == .Backspace or key == .Delete) {
        const forward = key == .Delete;
        if (try allowEdit(frame, event, ctl.asElement(), null, null, deleteInputType(forward))) {
            try ctl.innerDelete(forward, frame);
        }
        return;
    }

    if (key.isPrintable()) {
        if (try allowEdit(frame, event, ctl.asElement(), key.asString(), key.asString(), "insertText")) {
            try ctl.innerInsert(key.asString(), frame);
        }
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

// pre-edit events for a key's default action, can cancel the edit (i.e. by
// returning false)
fn allowEdit(frame: *Frame, keydown: *Event, target: *Element, before_data: ?[]const u8, text_data: ?[]const u8, input_type: []const u8) !bool {
    if (keydown.getIsTrusted() == false) {
        // only trusted events fire these events, so for a untrusted event, the
        // edit isn't cancelled.
        return true;
    }

    {
        const before = (try InputEvent.initTrusted(comptime .wrap("beforeinput"), .{
            .bubbles = true,
            .cancelable = true,
            .composed = true,
            .data = before_data,
            .inputType = input_type,
        }, frame)).asEvent();
        before.acquireRef(); // need to check its _prevent_default
        defer _ = before.releaseRef(frame._page);
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
        defer _ = text_event.releaseRef(frame._page);
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

// Dispatch keypress mirroring `keydown`'s key and modifiers; returns true when
// a listener canceled it.
fn dispatchKeypress(frame: *Frame, target: *Node, keydown: *KeyboardEvent) !bool {
    const event = (try KeyboardEvent.initTrusted(comptime .wrap("keypress"), .{
        .bubbles = true,
        .cancelable = true,
        .composed = true,
        .key = keydown.getKey().asString(),
        .ctrlKey = keydown.getCtrlKey(),
        .shiftKey = keydown.getShiftKey(),
        .altKey = keydown.getAltKey(),
        .metaKey = keydown.getMetaKey(),
    }, frame)).asEvent();

    // Keep the event alive past dispatch so we can read _prevent_default.
    event.acquireRef();
    defer _ = event.releaseRef(frame._page);

    try frame._event_manager.dispatch(target.asEventTarget(), event);
    return event._prevent_default;
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

// elements where enter on a keydown should dispatch a click-click event
fn enterActivates(element: *Element) bool {
    const html_element = element.is(Element.Html) orelse return false;
    if (html_element._type == .button) {
        return true;
    }
    if (html_element._type == .anchor) {
        return element.getAttributeSafe(comptime .wrap("href")) != null;
    }
    if (element.is(Element.Html.Input)) |input| {
        return switch (input._input_type) {
            .button, .submit, .reset, .image => true,
            else => false,
        };
    }
    return false;
}

// elements where space on a keyup should dispatch a click-click event
fn spaceActivates(element: *Element) bool {
    const html_element = element.is(Element.Html) orelse return false;
    if (html_element._type == .button) {
        return true;
    }
    if (element.is(Element.Html.Input)) |input| {
        return switch (input._input_type) {
            .button, .submit, .reset, .image, .checkbox, .radio => true,
            else => false,
        };
    }
    return false;
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
        if (candidate.isDisabled()) {
            continue;
        }
        if (candidate.is(Element.Html) == null) {
            continue;
        }

        const candidate_tab_index = blk: {
            if (candidate.getAttributeSafe(comptime .wrap("tabindex"))) |attr| {
                if (Element.Html.parseInteger(attr)) |tab_index| {
                    if (tab_index < 0) {
                        continue;
                    }
                    break :blk tab_index;
                }
                break :blk 0;
            }

            // no tab index, maybe this item isn't focusable..
            const focusable = switch (candidate.getTag()) {
                .button, .select, .textarea, .iframe => true,
                .input => candidate.as(Element.Html.Input)._input_type != .hidden,
                .anchor, .area => candidate.getAttributeSafe(comptime .wrap("href")) != null,
                else => false,
            };
            if (focusable == false) {
                continue;
            }

            break :blk 0;
        };

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

// insertText is a shortcut to insert text into the active element.
pub fn insertText(frame: *Frame, v: []const u8) !void {
    const html_element = frame.document._active_element orelse return;

    if (html_element.is(Element.Html.Input)) |input| {
        const input_type = input._input_type;
        if (input_type == .radio or input_type == .checkbox) {
            return;
        }

        return input.innerInsert(v, frame);
    }

    if (html_element.is(Element.Html.TextArea)) |textarea| {
        return textarea.innerInsert(v, frame);
    }
}

pub const Modifiers = struct {
    ctrl: bool = false,
    shift: bool = false,
    alt: bool = false,
    meta: bool = false,
};
