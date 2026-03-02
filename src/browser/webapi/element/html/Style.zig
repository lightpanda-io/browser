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

const Style = @This();
_proto: *HtmlElement,
_sheet: ?*CSSStyleSheet = null,

pub fn asElement(self: *Style) *Element {
    return self._proto._proto;
}
pub fn asConstElement(self: *const Style) *const Element {
    return self._proto._proto;
}
pub fn asNode(self: *Style) *Node {
    return self.asElement().asNode();
}

// Attribute-backed properties

pub fn getBlocking(self: *const Style) []const u8 {
    return self.asConstElement().getAttributeSafe(comptime .wrap("blocking")) orelse "";
}

pub fn setBlocking(self: *Style, value: []const u8, page: *Page) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("blocking"), .wrap(value), page);
}

pub fn getMedia(self: *const Style) []const u8 {
    return self.asConstElement().getAttributeSafe(comptime .wrap("media")) orelse "";
}

pub fn setMedia(self: *Style, value: []const u8, page: *Page) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("media"), .wrap(value), page);
}

pub fn getType(self: *const Style) []const u8 {
    return self.asConstElement().getAttributeSafe(comptime .wrap("type")) orelse "text/css";
}

pub fn setType(self: *Style, value: []const u8, page: *Page) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("type"), .wrap(value), page);
}

pub fn getDisabled(self: *const Style) bool {
    return self.asConstElement().getAttributeSafe(comptime .wrap("disabled")) != null;
}

pub fn setDisabled(self: *Style, disabled: bool, page: *Page) !void {
    if (disabled) {
        try self.asElement().setAttributeSafe(comptime .wrap("disabled"), .wrap(""), page);
    } else {
        try self.asElement().removeAttribute(comptime .wrap("disabled"), page);
    }
}

const CSSStyleSheet = @import("../../css/CSSStyleSheet.zig");
pub fn getSheet(self: *Style, page: *Page) !?*CSSStyleSheet {
    // Per spec, sheet is null for disconnected elements or non-CSS types.
    // Valid types: absent (defaults to "text/css"), empty string, or
    // case-insensitive match for "text/css".
    if (!self.asNode().isConnected()) {
        self._sheet = null;
        return null;
    }
    const t = self.getType();
    if (t.len != 0 and !std.ascii.eqlIgnoreCase(t, "text/css")) {
        self._sheet = null;
        return null;
    }

    if (self._sheet) |sheet| return sheet;
    const sheet = try CSSStyleSheet.initWithOwner(self.asElement(), page);
    self._sheet = sheet;
    return sheet;
}

pub fn styleAddedCallback(self: *Style, page: *Page) !void {
    // if we're planning on navigating to another page, don't trigger load event.
    if (page.isGoingAway()) {
        return;
    }

    try page._to_load.append(page.arena, self._proto);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Style);

    pub const Meta = struct {
        pub const name = "HTMLStyleElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const blocking = bridge.accessor(Style.getBlocking, Style.setBlocking, .{});
    pub const media = bridge.accessor(Style.getMedia, Style.setMedia, .{});
    pub const @"type" = bridge.accessor(Style.getType, Style.setType, .{});
    pub const disabled = bridge.accessor(Style.getDisabled, Style.setDisabled, .{});
    pub const sheet = bridge.accessor(Style.getSheet, null, .{});
};

const testing = @import("../../../../testing.zig");
test "WebApi: Style" {
    try testing.htmlRunner("element/html/style.html", .{});
}
