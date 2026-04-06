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
_sheet_source_hash: u64 = 0,
_sheet_source_loaded: bool = false,

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
fn stylesheetSourceHash(text: []const u8, base_url: []const u8, referer_url: []const u8, include_credentials: bool) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(text);
    hasher.update(base_url);
    hasher.update(referer_url);
    hasher.update(&[_]u8{@intFromBool(include_credentials)});
    return hasher.final();
}

pub fn getSheet(self: *Style, page: *Page) !?*CSSStyleSheet {
    // Per spec, sheet is null for disconnected elements or non-CSS types.
    // Valid types: absent (defaults to "text/css"), empty string, or
    // case-insensitive match for "text/css".
    if (!self.asNode().isConnected()) {
        self._sheet = null;
        self._sheet_source_loaded = false;
        self._sheet_source_hash = 0;
        return null;
    }
    const t = self.getType();
    if (t.len != 0 and !std.ascii.eqlIgnoreCase(t, "text/css")) {
        self._sheet = null;
        self._sheet_source_loaded = false;
        self._sheet_source_hash = 0;
        return null;
    }

    const base_url = page.base();
    const referer_url = page.url;
    const include_credentials = true;
    const text = try self.asNode().getTextContentAlloc(page.call_arena);
    const source_hash = stylesheetSourceHash(text, base_url, referer_url, include_credentials);

    if (self._sheet) |sheet| {
        sheet._request_base_url = try page.arena.dupeZ(u8, base_url);
        sheet._request_referer_url = try page.arena.dupeZ(u8, referer_url);
        sheet._request_include_credentials = include_credentials;
        if (!self._sheet_source_loaded or self._sheet_source_hash != source_hash) {
            try sheet.replaceSync(text, page);
            self._sheet_source_hash = source_hash;
            self._sheet_source_loaded = true;
        }
        return sheet;
    }
    const sheet = try CSSStyleSheet.initWithOwner(self.asElement(), page);
    sheet._request_base_url = try page.arena.dupeZ(u8, base_url);
    sheet._request_referer_url = try page.arena.dupeZ(u8, referer_url);
    sheet._request_include_credentials = include_credentials;
    try sheet.replaceSync(text, page);
    self._sheet = sheet;
    self._sheet_source_hash = source_hash;
    self._sheet_source_loaded = true;
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

test "WebApi: Style caches unchanged inline stylesheet source" {
    var page = try testing.pageTest("element/html/style_cache.html");
    defer page._session.removePage();

    const style_element = page.window._document.getElementById("sheet", page) orelse return error.TestExpected;
    const style = style_element.is(Element.Html.Style) orelse return error.TestExpected;

    const first_sheet = (try style.getSheet(page)) orelse return error.TestExpected;
    const first_rules_ptr = first_sheet._rules.ptr;

    const second_sheet = (try style.getSheet(page)) orelse return error.TestExpected;
    try std.testing.expectEqual(first_sheet, second_sheet);
    try std.testing.expectEqual(first_rules_ptr, second_sheet._rules.ptr);

    try style_element.asNode().setTextContent("body { color: rgb(4, 5, 6); }", page);

    const refreshed_sheet = (try style.getSheet(page)) orelse return error.TestExpected;
    try std.testing.expectEqual(first_sheet, refreshed_sheet);
    try std.testing.expect(refreshed_sheet._rules.ptr != first_rules_ptr);
}
