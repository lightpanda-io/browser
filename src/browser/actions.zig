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
const Page = @import("Page.zig");
const Session = @import("Session.zig");
const Selector = @import("webapi/selector/Selector.zig");

fn dispatchInputAndChangeEvents(el: *Element, page: *Page) !void {
    const input_evt: *Event = try .initTrusted(comptime .wrap("input"), .{ .bubbles = true }, page);
    page._event_manager.dispatch(el.asEventTarget(), input_evt) catch |err| {
        lp.log.err(.app, "dispatch input event failed", .{ .err = err });
    };

    const change_evt: *Event = try .initTrusted(comptime .wrap("change"), .{ .bubbles = true }, page);
    page._event_manager.dispatch(el.asEventTarget(), change_evt) catch |err| {
        lp.log.err(.app, "dispatch change event failed", .{ .err = err });
    };
}

pub fn click(node: *DOMNode, page: *Page) !void {
    const el = node.is(Element) orelse return error.InvalidNodeType;

    const mouse_event: *MouseEvent = try .initTrusted(comptime .wrap("click"), .{
        .bubbles = true,
        .cancelable = true,
        .composed = true,
        .clientX = 0,
        .clientY = 0,
    }, page);

    page._event_manager.dispatch(el.asEventTarget(), mouse_event.asEvent()) catch |err| {
        lp.log.err(.app, "click failed", .{ .err = err });
        return error.ActionFailed;
    };
}

pub fn hover(node: *DOMNode, page: *Page) !void {
    const el = node.is(Element) orelse return error.InvalidNodeType;

    const mouseover_event: *MouseEvent = try .initTrusted(comptime .wrap("mouseover"), .{
        .bubbles = true,
        .cancelable = true,
        .composed = true,
    }, page);

    page._event_manager.dispatch(el.asEventTarget(), mouseover_event.asEvent()) catch |err| {
        lp.log.err(.app, "hover mouseover failed", .{ .err = err });
        return error.ActionFailed;
    };

    const mouseenter_event: *MouseEvent = try .initTrusted(comptime .wrap("mouseenter"), .{
        .composed = true,
    }, page);

    page._event_manager.dispatch(el.asEventTarget(), mouseenter_event.asEvent()) catch |err| {
        lp.log.err(.app, "hover mouseenter failed", .{ .err = err });
        return error.ActionFailed;
    };
}

pub fn press(node: ?*DOMNode, key: []const u8, page: *Page) !void {
    const target = if (node) |n|
        (n.is(Element) orelse return error.InvalidNodeType).asEventTarget()
    else
        page.document.asNode().asEventTarget();

    const keydown_event: *KeyboardEvent = try .initTrusted(comptime .wrap("keydown"), .{
        .bubbles = true,
        .cancelable = true,
        .composed = true,
        .key = key,
    }, page);

    page._event_manager.dispatch(target, keydown_event.asEvent()) catch |err| {
        lp.log.err(.app, "press keydown failed", .{ .err = err });
        return error.ActionFailed;
    };

    const keyup_event: *KeyboardEvent = try .initTrusted(comptime .wrap("keyup"), .{
        .bubbles = true,
        .cancelable = true,
        .composed = true,
        .key = key,
    }, page);

    page._event_manager.dispatch(target, keyup_event.asEvent()) catch |err| {
        lp.log.err(.app, "press keyup failed", .{ .err = err });
        return error.ActionFailed;
    };
}

pub fn selectOption(node: *DOMNode, value: []const u8, page: *Page) !void {
    const el = node.is(Element) orelse return error.InvalidNodeType;
    const select = el.is(Element.Html.Select) orelse return error.InvalidNodeType;

    select.setValue(value, page) catch |err| {
        lp.log.err(.app, "select setValue failed", .{ .err = err });
        return error.ActionFailed;
    };

    try dispatchInputAndChangeEvents(el, page);
}

pub fn setChecked(node: *DOMNode, checked: bool, page: *Page) !void {
    const el = node.is(Element) orelse return error.InvalidNodeType;
    const input = el.is(Element.Html.Input) orelse return error.InvalidNodeType;

    if (input._input_type != .checkbox and input._input_type != .radio) {
        return error.InvalidNodeType;
    }

    input.setChecked(checked, page) catch |err| {
        lp.log.err(.app, "setChecked failed", .{ .err = err });
        return error.ActionFailed;
    };

    // Match browser event order: click fires first, then input and change.
    const click_event: *MouseEvent = try .initTrusted(comptime .wrap("click"), .{
        .bubbles = true,
        .cancelable = true,
        .composed = true,
    }, page);

    page._event_manager.dispatch(el.asEventTarget(), click_event.asEvent()) catch |err| {
        lp.log.err(.app, "dispatch click event failed", .{ .err = err });
    };

    try dispatchInputAndChangeEvents(el, page);
}

pub fn fill(node: *DOMNode, text: []const u8, page: *Page) !void {
    const el = node.is(Element) orelse return error.InvalidNodeType;

    el.focus(page) catch |err| {
        lp.log.err(.app, "fill focus failed", .{ .err = err });
    };

    if (el.is(Element.Html.Input)) |input| {
        input.setValue(text, page) catch |err| {
            lp.log.err(.app, "fill input failed", .{ .err = err });
            return error.ActionFailed;
        };
    } else if (el.is(Element.Html.TextArea)) |textarea| {
        textarea.setValue(text, page) catch |err| {
            lp.log.err(.app, "fill textarea failed", .{ .err = err });
            return error.ActionFailed;
        };
    } else if (el.is(Element.Html.Select)) |select| {
        select.setValue(text, page) catch |err| {
            lp.log.err(.app, "fill select failed", .{ .err = err });
            return error.ActionFailed;
        };
    } else {
        return error.InvalidNodeType;
    }

    try dispatchInputAndChangeEvents(el, page);
}

pub fn scroll(node: ?*DOMNode, x: ?i32, y: ?i32, page: *Page) !void {
    if (node) |n| {
        const el = n.is(Element) orelse return error.InvalidNodeType;

        if (x) |val| {
            el.setScrollLeft(val, page) catch |err| {
                lp.log.err(.app, "setScrollLeft failed", .{ .err = err });
                return error.ActionFailed;
            };
        }
        if (y) |val| {
            el.setScrollTop(val, page) catch |err| {
                lp.log.err(.app, "setScrollTop failed", .{ .err = err });
                return error.ActionFailed;
            };
        }

        const scroll_evt: *Event = try .initTrusted(comptime .wrap("scroll"), .{ .bubbles = true }, page);
        page._event_manager.dispatch(el.asEventTarget(), scroll_evt) catch |err| {
            lp.log.err(.app, "dispatch scroll event failed", .{ .err = err });
        };
    } else {
        page.window.scrollTo(.{ .x = x orelse 0 }, y, page) catch |err| {
            lp.log.err(.app, "scroll failed", .{ .err = err });
            return error.ActionFailed;
        };
    }
}

pub fn waitForSelector(selector: [:0]const u8, timeout_ms: u32, session: *Session) !*DOMNode {
    var timer = try std.time.Timer.start();
    var runner = try session.runner(.{});
    try runner.wait(.{ .ms = timeout_ms, .until = .load });

    const elapsed: u32 = @intCast(timer.read() / std.time.ns_per_ms);
    const remaining = timeout_ms -| elapsed;
    if (remaining == 0) return error.Timeout;

    const el = try runner.waitForSelector(selector, remaining);
    return el.asNode();
}
