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
const lp = @import("../lightpanda.zig");
const DOMNode = @import("webapi/Node.zig");
const Element = @import("webapi/Element.zig");
const Event = @import("webapi/Event.zig");
const MouseEvent = @import("webapi/event/MouseEvent.zig");
const KeyboardEvent = @import("webapi/event/KeyboardEvent.zig");
const Frame = @import("Frame.zig");
const Session = @import("Session.zig");

fn dispatchInputAndChangeEvents(el: *Element, frame: *Frame) !void {
    const input_evt: *Event = try .initTrusted(comptime .wrap("input"), .{ .bubbles = true }, frame._page);
    frame._event_manager.dispatch(el.asEventTarget(), input_evt) catch |err| {
        lp.log.err(.app, "dispatch input event failed", .{ .err = err });
    };

    const change_evt: *Event = try .initTrusted(comptime .wrap("change"), .{ .bubbles = true }, frame._page);
    frame._event_manager.dispatch(el.asEventTarget(), change_evt) catch |err| {
        lp.log.err(.app, "dispatch change event failed", .{ .err = err });
    };
}

pub fn click(node: *DOMNode, frame: *Frame) !void {
    const el = node.is(Element) orelse return error.InvalidNodeType;

    const mouse_event: *MouseEvent = try .initTrusted(comptime .wrap("click"), .{
        .bubbles = true,
        .cancelable = true,
        .composed = true,
        .clientX = 0,
        .clientY = 0,
    }, frame);

    frame._event_manager.dispatch(el.asEventTarget(), mouse_event.asEvent()) catch |err| {
        lp.log.err(.app, "click failed", .{ .err = err });
        return error.ActionFailed;
    };
}

pub fn hover(node: *DOMNode, frame: *Frame) !void {
    const el = node.is(Element) orelse return error.InvalidNodeType;

    const mouseover_event: *MouseEvent = try .initTrusted(comptime .wrap("mouseover"), .{
        .bubbles = true,
        .cancelable = true,
        .composed = true,
    }, frame);

    frame._event_manager.dispatch(el.asEventTarget(), mouseover_event.asEvent()) catch |err| {
        lp.log.err(.app, "hover mouseover failed", .{ .err = err });
        return error.ActionFailed;
    };

    const mouseenter_event: *MouseEvent = try .initTrusted(comptime .wrap("mouseenter"), .{
        .composed = true,
    }, frame);

    frame._event_manager.dispatch(el.asEventTarget(), mouseenter_event.asEvent()) catch |err| {
        lp.log.err(.app, "hover mouseenter failed", .{ .err = err });
        return error.ActionFailed;
    };
}

pub fn press(node: ?*DOMNode, key: []const u8, frame: *Frame) !void {
    const target_el: ?*Element = if (node) |n|
        (n.is(Element) orelse return error.InvalidNodeType)
    else
        null;
    const target = if (target_el) |el| el.asEventTarget() else frame.document.asNode().asEventTarget();
    const canonical = canonicalKey(key);

    const keydown_event: *KeyboardEvent = try .initTrusted(comptime .wrap("keydown"), .{
        .bubbles = true,
        .cancelable = true,
        .composed = true,
        .key = canonical,
    }, frame);

    frame._event_manager.dispatch(target, keydown_event.asEvent()) catch |err| {
        lp.log.err(.app, "press keydown failed", .{ .err = err });
        return error.ActionFailed;
    };

    if (std.mem.eql(u8, canonical, "Enter") and !keydown_event.asEvent().getDefaultPrevented()) {
        if (target_el) |el| implicitFormSubmit(el, frame) catch |err| {
            // Don't skip keyup on a submit-listener throw — UIs that gate
            // state on keyup (e.g. clearing a "submitting" flag) would hang.
            lp.log.warn(.app, "implicit form submit failed", .{ .err = err });
        };
    }

    const keyup_event: *KeyboardEvent = try .initTrusted(comptime .wrap("keyup"), .{
        .bubbles = true,
        .cancelable = true,
        .composed = true,
        .key = canonical,
    }, frame);

    frame._event_manager.dispatch(target, keyup_event.asEvent()) catch |err| {
        lp.log.err(.app, "press keyup failed", .{ .err = err });
        return error.ActionFailed;
    };
}

/// Map common shorthand to the canonical KeyboardEvent.key string so users
/// can type "enter" instead of "Enter" without surprises.
fn canonicalKey(key: []const u8) []const u8 {
    const aliases = [_]struct { in: []const u8, out: []const u8 }{
        .{ .in = "enter", .out = "Enter" },
        .{ .in = "return", .out = "Enter" },
        .{ .in = "\n", .out = "Enter" },
        .{ .in = "\\n", .out = "Enter" },
        .{ .in = "esc", .out = "Escape" },
        .{ .in = "escape", .out = "Escape" },
        .{ .in = "tab", .out = "Tab" },
        .{ .in = "\t", .out = "Tab" },
        .{ .in = "space", .out = " " },
        .{ .in = "backspace", .out = "Backspace" },
        .{ .in = "delete", .out = "Delete" },
        .{ .in = "del", .out = "Delete" },
        .{ .in = "up", .out = "ArrowUp" },
        .{ .in = "down", .out = "ArrowDown" },
        .{ .in = "left", .out = "ArrowLeft" },
        .{ .in = "right", .out = "ArrowRight" },
    };
    for (aliases) |a| {
        if (std.ascii.eqlIgnoreCase(key, a.in)) return a.out;
    }
    return key;
}

fn implicitFormSubmit(el: *Element, frame: *Frame) !void {
    const Input = Element.Html.Input;
    const Button = Element.Html.Button;

    if (el.is(Input)) |input| {
        const form = input.getForm(frame) orelse return;
        const submitter: ?*Element = switch (input._input_type) {
            .submit, .image => el,
            // Non-text controls (checkbox, radio, file, ...) don't trigger
            // implicit submission; only the text-like family does.
            .text, .password, .email, .url, .tel, .search, .number, .date, .time, .@"datetime-local", .month, .week => null,
            else => return,
        };
        return form.requestSubmit(submitter, frame);
    }
    if (el.is(Button)) |button| {
        if (!std.ascii.eqlIgnoreCase(button.getType(), "submit")) return;
        const form = button.getForm(frame) orelse return;
        return form.requestSubmit(el, frame);
    }
}

pub fn selectOption(node: *DOMNode, value: []const u8, frame: *Frame) !void {
    const el = node.is(Element) orelse return error.InvalidNodeType;
    const select = el.is(Element.Html.Select) orelse return error.InvalidNodeType;

    select.setValue(value, frame) catch |err| {
        lp.log.err(.app, "select setValue failed", .{ .err = err });
        return error.ActionFailed;
    };

    try dispatchInputAndChangeEvents(el, frame);
}

pub fn setChecked(node: *DOMNode, checked: bool, frame: *Frame) !void {
    const el = node.is(Element) orelse return error.InvalidNodeType;
    const input = el.is(Element.Html.Input) orelse return error.InvalidNodeType;

    if (input._input_type != .checkbox and input._input_type != .radio) {
        return error.InvalidNodeType;
    }

    input.setChecked(checked, frame) catch |err| {
        lp.log.err(.app, "setChecked failed", .{ .err = err });
        return error.ActionFailed;
    };

    // Match browser event order: click fires first, then input and change.
    const click_event: *MouseEvent = try .initTrusted(comptime .wrap("click"), .{
        .bubbles = true,
        .cancelable = true,
        .composed = true,
    }, frame);

    frame._event_manager.dispatch(el.asEventTarget(), click_event.asEvent()) catch |err| {
        lp.log.err(.app, "dispatch click event failed", .{ .err = err });
    };

    try dispatchInputAndChangeEvents(el, frame);
}

pub fn fill(node: *DOMNode, text: []const u8, frame: *Frame) !void {
    const el = node.is(Element) orelse return error.InvalidNodeType;

    el.focus(frame) catch |err| {
        lp.log.err(.app, "fill focus failed", .{ .err = err });
    };

    if (el.is(Element.Html.Input)) |input| {
        input.setValue(text, frame) catch |err| {
            lp.log.err(.app, "fill input failed", .{ .err = err });
            return error.ActionFailed;
        };
    } else if (el.is(Element.Html.TextArea)) |textarea| {
        textarea.setValue(text, frame) catch |err| {
            lp.log.err(.app, "fill textarea failed", .{ .err = err });
            return error.ActionFailed;
        };
    } else if (el.is(Element.Html.Select)) |select| {
        select.setValue(text, frame) catch |err| {
            lp.log.err(.app, "fill select failed", .{ .err = err });
            return error.ActionFailed;
        };
    } else {
        return error.InvalidNodeType;
    }

    try dispatchInputAndChangeEvents(el, frame);
}

pub fn scroll(node: ?*DOMNode, x: ?i32, y: ?i32, frame: *Frame) !void {
    if (node) |n| {
        const el = n.is(Element) orelse return error.InvalidNodeType;

        if (x) |val| {
            el.setScrollLeft(val, frame) catch |err| {
                lp.log.err(.app, "setScrollLeft failed", .{ .err = err });
                return error.ActionFailed;
            };
        }
        if (y) |val| {
            el.setScrollTop(val, frame) catch |err| {
                lp.log.err(.app, "setScrollTop failed", .{ .err = err });
                return error.ActionFailed;
            };
        }

        const scroll_evt: *Event = try .initTrusted(comptime .wrap("scroll"), .{ .bubbles = true }, frame._page);
        frame._event_manager.dispatch(el.asEventTarget(), scroll_evt) catch |err| {
            lp.log.err(.app, "dispatch scroll event failed", .{ .err = err });
        };
    } else {
        frame.window.scrollTo(.{ .x = x orelse 0 }, y, frame) catch |err| {
            lp.log.err(.app, "scroll failed", .{ .err = err });
            return error.ActionFailed;
        };
    }
}

// Floored to 1 so timeout_ms=0 still gets one check instead of failing outright.
fn remainingMs(timeout_ms: u32, timer: *std.time.Timer) u32 {
    const elapsed: u32 = @intCast(timer.read() / std.time.ns_per_ms);
    return @max(1, timeout_ms -| elapsed);
}

pub fn waitForSelector(selector: [:0]const u8, timeout_ms: u32, frame_id: u32, session: *Session) !*DOMNode {
    var timer = try std.time.Timer.start();
    var runner = session.runner(.{});
    try runner.waitForFrame(frame_id, timeout_ms, .{ .until = .load });

    const el = try runner.waitForSelector(frame_id, selector, remainingMs(timeout_ms, &timer));
    return el.asNode();
}

pub fn waitForScript(script: [:0]const u8, timeout_ms: u32, frame_id: u32, session: *Session) !void {
    var timer = try std.time.Timer.start();
    var runner = session.runner(.{});
    try runner.waitForFrame(frame_id, timeout_ms, .{ .until = .load });

    return runner.waitForScript(frame_id, script, remainingMs(timeout_ms, &timer));
}

pub fn waitForState(state: lp.Config.WaitUntil, timeout_ms: u32, frame_id: u32, session: *Session) !void {
    var runner = session.runner(.{});
    try runner.waitForFrame(frame_id, timeout_ms, .{ .until = state });
}
