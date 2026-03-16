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
const Page = @import("Page.zig");

pub fn click(node: *DOMNode, page: *Page) !void {
    if (node.is(Element.Html)) |html_el| {
        html_el.click(page) catch |err| {
            lp.log.err(.app, "click failed", .{ .err = err });
            return error.ActionFailed;
        };
    } else {
        return error.InvalidNodeType;
    }
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

    const input_evt = try Event.initTrusted(comptime lp.String.wrap("input"), .{ .bubbles = true }, page);
    _ = page._event_manager.dispatch(el.asEventTarget(), input_evt) catch {};

    const change_evt = try Event.initTrusted(comptime lp.String.wrap("change"), .{ .bubbles = true }, page);
    _ = page._event_manager.dispatch(el.asEventTarget(), change_evt) catch {};
}

pub fn scroll(node: ?*DOMNode, x: ?i32, y: ?i32, page: *Page) !void {
    if (node) |n| {
        const el = n.is(Element) orelse return error.InvalidNodeType;

        if (x) |val| {
            el.setScrollLeft(val, page) catch {};
        }
        if (y) |val| {
            el.setScrollTop(val, page) catch {};
        }

        const scroll_evt = try Event.initTrusted(comptime lp.String.wrap("scroll"), .{ .bubbles = true }, page);
        _ = page._event_manager.dispatch(el.asEventTarget(), scroll_evt) catch {};
    } else {
        page.window.scrollTo(.{ .x = x orelse 0 }, y, page) catch |err| {
            lp.log.err(.app, "scroll failed", .{ .err = err });
            return error.ActionFailed;
        };
    }
}
