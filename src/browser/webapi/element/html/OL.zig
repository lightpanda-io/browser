// Copyright (C) 2023-2025  Lightpanda (Selecy SAS)
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
const js = @import("../../../js/js.zig");
const Page = @import("../../../Page.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");

const OL = @This();
_proto: *HtmlElement,

pub fn asElement(self: *OL) *Element {
    return self._proto._proto;
}
pub fn asNode(self: *OL) *Node {
    return self.asElement().asNode();
}

pub fn getStart(self: *OL) i32 {
    const attr = self.asElement().getAttributeSafe(comptime .wrap("start")) orelse return 1;
    return std.fmt.parseInt(i32, attr, 10) catch 1;
}

pub fn setStart(self: *OL, value: i32, page: *Page) !void {
    const str = try std.fmt.allocPrint(page.call_arena, "{d}", .{value});
    try self.asElement().setAttributeSafe(comptime .wrap("start"), .wrap(str), page);
}

pub fn getReversed(self: *OL) bool {
    return self.asElement().getAttributeSafe(comptime .wrap("reversed")) != null;
}

pub fn setReversed(self: *OL, value: bool, page: *Page) !void {
    if (value) {
        try self.asElement().setAttributeSafe(comptime .wrap("reversed"), .wrap(""), page);
    } else {
        try self.asElement().removeAttribute(comptime .wrap("reversed"), page);
    }
}

pub fn getType(self: *OL) []const u8 {
    return self.asElement().getAttributeSafe(comptime .wrap("type")) orelse "1";
}

pub fn setType(self: *OL, value: []const u8, page: *Page) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("type"), .wrap(value), page);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(OL);

    pub const Meta = struct {
        pub const name = "HTMLOListElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const start = bridge.accessor(OL.getStart, OL.setStart, .{});
    pub const reversed = bridge.accessor(OL.getReversed, OL.setReversed, .{});
    pub const @"type" = bridge.accessor(OL.getType, OL.setType, .{});
};

const testing = @import("../../../../testing.zig");
test "WebApi: HTML.OL" {
    try testing.htmlRunner("element/html/ol.html", .{});
}
