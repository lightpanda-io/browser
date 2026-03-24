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
const Page = @import("Page.zig");
const Session = @import("Session.zig");
const Selector = @import("webapi/selector/Selector.zig");

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

pub fn fill(node: *DOMNode, text: []const u8, page: *Page) !void {
    const el = node.is(Element) orelse return error.InvalidNodeType;

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

    const input_evt: *Event = try .initTrusted(comptime .wrap("input"), .{ .bubbles = true }, page);
    page._event_manager.dispatch(el.asEventTarget(), input_evt) catch |err| {
        lp.log.err(.app, "dispatch input event failed", .{ .err = err });
    };

    const change_evt: *Event = try .initTrusted(comptime .wrap("change"), .{ .bubbles = true }, page);
    page._event_manager.dispatch(el.asEventTarget(), change_evt) catch |err| {
        lp.log.err(.app, "dispatch change event failed", .{ .err = err });
    };
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

    while (true) {
        const page = runner.page;
        const element = Selector.querySelector(page.document.asNode(), selector, page) catch {
            return error.InvalidSelector;
        };

        if (element) |el| {
            return el.asNode();
        }

        const elapsed: u32 = @intCast(timer.read() / std.time.ns_per_ms);
        if (elapsed >= timeout_ms) {
            return error.Timeout;
        }
        switch (try runner.tick(.{ .ms = timeout_ms - elapsed })) {
            .done => return error.Timeout,
            .ok => |recommended_sleep_ms| {
                if (recommended_sleep_ms > 0) {
                    // guanrateed to be <= 20ms
                    std.Thread.sleep(std.time.ns_per_ms * recommended_sleep_ms);
                }
            },
        }
    }
}
