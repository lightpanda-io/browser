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
// (src/cdp/domains/input.zig) and by EventManager's default activation
// behavior. Form submission itself lives on the Frame (it's a navigation
// concern); the activation paths here call into it.

const std = @import("std");
const lp = @import("lightpanda");
const builtin = @import("builtin");

const Frame = @import("../Frame.zig");

const Node = @import("../webapi/Node.zig");
const Event = @import("../webapi/Event.zig");
const Element = @import("../webapi/Element.zig");
const TreeWalker = @import("../webapi/TreeWalker.zig");
const MouseEvent = @import("../webapi/event/MouseEvent.zig");
const WheelEvent = @import("../webapi/event/WheelEvent.zig");
const KeyboardEvent = @import("../webapi/event/KeyboardEvent.zig");

const log = lp.log;
const IS_DEBUG = builtin.mode == .Debug;

// DOM MouseEvent.button values.
// https://developer.mozilla.org/en-US/docs/Web/API/MouseEvent/button
pub const mouse_button = struct {
    pub const main: i32 = 0; // left
    pub const auxiliary: i32 = 1; // middle
    pub const secondary: i32 = 2; // right
    pub const fourth: i32 = 3; // back
    pub const fifth: i32 = 4; // forward
};

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
    if (comptime IS_DEBUG) {
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
}

pub fn triggerMouseMove(frame: *Frame, x: f64, y: f64) !void {
    const target = (try frame.window._document.elementFromPoint(x, y, frame)) orelse return;
    if (comptime IS_DEBUG) {
        log.debug(.frame, "frame mouse move", .{
            .url = frame.url,
            .node = target,
            .x = x,
            .y = y,
            .type = frame._type,
        });
    }

    const move_event: *MouseEvent = try .initTrusted(comptime .wrap("mousemove"), .{
        .bubbles = true,
        .cancelable = true,
        .composed = true,
        .clientX = x,
        .clientY = y,
    }, frame);
    try frame._event_manager.dispatch(target.asEventTarget(), move_event.asEvent());

    const over_event: *MouseEvent = try .initTrusted(comptime .wrap("mouseover"), .{
        .bubbles = true,
        .cancelable = true,
        .composed = true,
        .clientX = x,
        .clientY = y,
    }, frame);
    try frame._event_manager.dispatch(target.asEventTarget(), over_event.asEvent());

    const enter_event: *MouseEvent = try .initTrusted(comptime .wrap("mouseenter"), .{
        .composed = true,
        .clientX = x,
        .clientY = y,
    }, frame);
    try frame._event_manager.dispatch(target.asEventTarget(), enter_event.asEvent());
}

pub fn triggerMouseRelease(frame: *Frame, x: f64, y: f64, button: i32, click_count: i32) !void {
    const target = (try frame.window._document.elementFromPoint(x, y, frame)) orelse return;
    if (comptime IS_DEBUG) {
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
    if (comptime IS_DEBUG) {
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
    return @intFromFloat(std.math.clamp(d, std.math.minInt(i32), std.math.maxInt(i32)));
}

// callback when the "click" event reaches the frame.
pub fn handleClick(frame: *Frame, target: *Node) !void {
    // TODO: Also support <area> elements when implement
    const element = target.is(Element) orelse return;
    const html_element = element.is(Element.Html) orelse return;

    switch (html_element._type) {
        .anchor => |anchor| {
            const href = element.getAttributeSafe(comptime .wrap("href")) orelse return;
            if (href.len == 0) {
                return;
            }

            if (std.mem.startsWith(u8, href, "javascript:")) {
                return;
            }

            if (try element.hasAttribute(comptime .wrap("download"), frame)) {
                log.warn(.browser, "a.download", .{ .type = frame._type, .url = frame.url });
                return;
            }

            const target_frame = blk: {
                const target_name = anchor.getTarget();
                if (target_name.len == 0) {
                    break :blk target.ownerFrame(frame);
                }
                break :blk frame.resolveTargetFrame(target_name) orelse {
                    log.warn(.not_implemented, "target", .{ .type = frame._type, .url = frame.url, .target = target_name });
                    return;
                };
            };

            try element.focus(frame);
            try frame.scheduleNavigation(href, .{
                .reason = .script,
                .kind = .{ .push = null },
            }, .{ .anchor = target_frame });
        },
        .input => |input| {
            try element.focus(frame);
            // Per HTML §4.10.18.6.4 "Image Button state (type=image)", clicking an
            // image button submits its form. The form-data set already gets the
            // submitter's coordinate fields appended via FormData.collectForm
            // (see src/browser/webapi/net/FormData.zig).
            if (input._input_type == .submit or input._input_type == .image) {
                return frame.submitForm(element, input.getForm(frame), .{});
            }
        },
        .button => |button| {
            try element.focus(frame);
            if (std.mem.eql(u8, button.getType(), "submit")) {
                return frame.submitForm(element, button.getForm(frame), .{});
            }
        },
        .select, .textarea => try element.focus(frame),
        .label => |label| {
            // Per HTML §4.10.4 "The label element", a label's activation
            // behavior is to run the synthetic click activation steps on the
            // labeled control. Mirrors Chrome's HTMLLabelElement::DefaultEventHandler.
            const control = label.getControl(frame) orelse return;
            const control_html = control.is(Element.Html) orelse return;
            try control_html.click(frame);
        },
        .generic => |generic| {
            switch (generic._tag) {
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

    if (comptime IS_DEBUG) {
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

    if (target.is(Element.Html.Input)) |input| {
        if (key == .Enter) {
            return frame.submitForm(input.asElement(), input.getForm(frame), .{});
        }

        // Don't handle text input for radio/checkbox
        const input_type = input._input_type;
        if (input_type == .radio or input_type == .checkbox) {
            return;
        }

        // Handle printable characters
        if (key.isPrintable()) {
            try input.innerInsert(key.asString(), frame);
        }
        return;
    }

    if (target.is(Element.Html.TextArea)) |textarea| {
        // zig fmt: off
        const append =
            if (key == .Enter) "\n"
            else if (key.isPrintable()) key.asString()
            else return
        ;
        // zig fmt: on
        return textarea.innerInsert(append, frame);
    }
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
