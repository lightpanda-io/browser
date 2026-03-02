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

const URL = @import("../../../URL.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");

const Anchor = @This();
_proto: *HtmlElement,

pub fn asElement(self: *Anchor) *Element {
    return self._proto._proto;
}
pub fn asConstElement(self: *const Anchor) *const Element {
    return self._proto._proto;
}
pub fn asNode(self: *Anchor) *Node {
    return self.asElement().asNode();
}

pub fn getHref(self: *Anchor, page: *Page) ![]const u8 {
    const element = self.asElement();
    const href = element.getAttributeSafe(comptime .wrap("href")) orelse return "";
    if (href.len == 0) {
        return "";
    }
    return URL.resolve(page.call_arena, page.base(), href, .{ .encode = true });
}

pub fn setHref(self: *Anchor, value: []const u8, page: *Page) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("href"), .wrap(value), page);
}

pub fn getTarget(self: *Anchor) []const u8 {
    return self.asElement().getAttributeSafe(comptime .wrap("target")) orelse "";
}

pub fn setTarget(self: *Anchor, value: []const u8, page: *Page) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("target"), .wrap(value), page);
}

pub fn getOrigin(self: *Anchor, page: *Page) ![]const u8 {
    const href = try getResolvedHref(self, page) orelse return "";
    return (try URL.getOrigin(page.call_arena, href)) orelse "null";
}

pub fn getHost(self: *Anchor, page: *Page) ![]const u8 {
    const href = try getResolvedHref(self, page) orelse return "";
    const host = URL.getHost(href);
    const protocol = URL.getProtocol(href);
    const port = URL.getPort(href);

    // Strip default ports
    if (port.len > 0) {
        if ((std.mem.eql(u8, protocol, "https:") and std.mem.eql(u8, port, "443")) or
            (std.mem.eql(u8, protocol, "http:") and std.mem.eql(u8, port, "80")))
        {
            return URL.getHostname(href);
        }
    }

    return host;
}

pub fn setHost(self: *Anchor, value: []const u8, page: *Page) !void {
    const href = try getResolvedHref(self, page) orelse return;
    const new_href = try URL.setHost(href, value, page.call_arena);
    try setHref(self, new_href, page);
}

pub fn getHostname(self: *Anchor, page: *Page) ![]const u8 {
    const href = try getResolvedHref(self, page) orelse return "";
    return URL.getHostname(href);
}

pub fn setHostname(self: *Anchor, value: []const u8, page: *Page) !void {
    const href = try getResolvedHref(self, page) orelse return;
    const new_href = try URL.setHostname(href, value, page.call_arena);
    try setHref(self, new_href, page);
}

pub fn getPort(self: *Anchor, page: *Page) ![]const u8 {
    const href = try getResolvedHref(self, page) orelse return "";
    const port = URL.getPort(href);
    const protocol = URL.getProtocol(href);

    // Return empty string for default ports
    if (port.len > 0) {
        if ((std.mem.eql(u8, protocol, "https:") and std.mem.eql(u8, port, "443")) or
            (std.mem.eql(u8, protocol, "http:") and std.mem.eql(u8, port, "80")))
        {
            return "";
        }
    }

    return port;
}

pub fn setPort(self: *Anchor, value: ?[]const u8, page: *Page) !void {
    const href = try getResolvedHref(self, page) orelse return;
    const new_href = try URL.setPort(href, value, page.call_arena);
    try setHref(self, new_href, page);
}

pub fn getSearch(self: *Anchor, page: *Page) ![]const u8 {
    const href = try getResolvedHref(self, page) orelse return "";
    return URL.getSearch(href);
}

pub fn setSearch(self: *Anchor, value: []const u8, page: *Page) !void {
    const href = try getResolvedHref(self, page) orelse return;
    const new_href = try URL.setSearch(href, value, page.call_arena);
    try setHref(self, new_href, page);
}

pub fn getHash(self: *Anchor, page: *Page) ![]const u8 {
    const href = try getResolvedHref(self, page) orelse return "";
    return URL.getHash(href);
}

pub fn setHash(self: *Anchor, value: []const u8, page: *Page) !void {
    const href = try getResolvedHref(self, page) orelse return;
    const new_href = try URL.setHash(href, value, page.call_arena);
    try setHref(self, new_href, page);
}

pub fn getPathname(self: *Anchor, page: *Page) ![]const u8 {
    const href = try getResolvedHref(self, page) orelse return "";
    return URL.getPathname(href);
}

pub fn setPathname(self: *Anchor, value: []const u8, page: *Page) !void {
    const href = try getResolvedHref(self, page) orelse return;
    const new_href = try URL.setPathname(href, value, page.call_arena);
    try setHref(self, new_href, page);
}

pub fn getProtocol(self: *Anchor, page: *Page) ![]const u8 {
    const href = try getResolvedHref(self, page) orelse return "";
    return URL.getProtocol(href);
}

pub fn setProtocol(self: *Anchor, value: []const u8, page: *Page) !void {
    const href = try getResolvedHref(self, page) orelse return;
    const new_href = try URL.setProtocol(href, value, page.call_arena);
    try setHref(self, new_href, page);
}

pub fn getType(self: *Anchor) []const u8 {
    return self.asElement().getAttributeSafe(comptime .wrap("type")) orelse "";
}

pub fn setType(self: *Anchor, value: []const u8, page: *Page) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("type"), .wrap(value), page);
}

pub fn getName(self: *const Anchor) []const u8 {
    return self.asConstElement().getAttributeSafe(comptime .wrap("name")) orelse "";
}

pub fn setName(self: *Anchor, value: []const u8, page: *Page) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("name"), .wrap(value), page);
}

pub fn getText(self: *Anchor, page: *Page) ![:0]const u8 {
    return self.asNode().getTextContentAlloc(page.call_arena);
}

pub fn setText(self: *Anchor, value: []const u8, page: *Page) !void {
    try self.asNode().setTextContent(value, page);
}

fn getResolvedHref(self: *Anchor, page: *Page) !?[:0]const u8 {
    const href = self.asElement().getAttributeSafe(comptime .wrap("href")) orelse return null;
    if (href.len == 0) {
        return null;
    }
    return try URL.resolve(page.call_arena, page.base(), href, .{});
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Anchor);

    pub const Meta = struct {
        pub const name = "HTMLAnchorElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const href = bridge.accessor(Anchor.getHref, Anchor.setHref, .{});
    pub const target = bridge.accessor(Anchor.getTarget, Anchor.setTarget, .{});
    pub const name = bridge.accessor(Anchor.getName, Anchor.setName, .{});
    pub const origin = bridge.accessor(Anchor.getOrigin, null, .{});
    pub const protocol = bridge.accessor(Anchor.getProtocol, Anchor.setProtocol, .{});
    pub const host = bridge.accessor(Anchor.getHost, Anchor.setHost, .{});
    pub const hostname = bridge.accessor(Anchor.getHostname, Anchor.setHostname, .{});
    pub const port = bridge.accessor(Anchor.getPort, Anchor.setPort, .{});
    pub const pathname = bridge.accessor(Anchor.getPathname, Anchor.setPathname, .{});
    pub const search = bridge.accessor(Anchor.getSearch, Anchor.setSearch, .{});
    pub const hash = bridge.accessor(Anchor.getHash, Anchor.setHash, .{});
    pub const @"type" = bridge.accessor(Anchor.getType, Anchor.setType, .{});
    pub const text = bridge.accessor(Anchor.getText, Anchor.setText, .{});
    pub const relList = bridge.accessor(_getRelList, null, .{ .null_as_undefined = true });
    pub const toString = bridge.function(Anchor.getHref, .{});

    fn _getRelList(self: *Anchor, page: *Page) !?*@import("../../collections.zig").DOMTokenList {
        const element = self.asElement();
        // relList is only valid for HTML and SVG <a> elements
        const namespace = element._namespace;
        if (namespace != .html and namespace != .svg) {
            return null;
        }
        return element.getRelList(page);
    }
};

const testing = @import("../../../../testing.zig");
test "WebApi: HTML.Anchor" {
    try testing.htmlRunner("element/html/anchor.html", .{});
}
