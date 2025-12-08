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
    const href = element.getAttributeSafe("href") orelse "";
    if (href.len == 0) {
        return page.url;
    }

    const first = href[0];
    if (first == '#' or first == '?' or first == '/' or std.mem.startsWith(u8, href, "../") or std.mem.startsWith(u8, href, "./")) {
        return URL.resolve(page.call_arena, page.url, href, .{});
    }

    return href;
}

pub fn setHref(self: *Anchor, value: []const u8, page: *Page) !void {
    try self.asElement().setAttributeSafe("href", value, page);
}

pub fn getTarget(self: *Anchor) []const u8 {
    return self.asElement().getAttributeSafe("target") orelse "";
}

pub fn setTarget(self: *Anchor, value: []const u8, page: *Page) !void {
    try self.asElement().setAttributeSafe("target", value, page);
}

pub fn getOrigin(self: *Anchor, page: *Page) ![]const u8 {
    const href = try getResolvedHref(self, page);
    return (try URL.getOrigin(page.call_arena, href)) orelse "null";
}

pub fn getHost(self: *Anchor, page: *Page) ![]const u8 {
    const href = try getResolvedHref(self, page);
    return URL.getHost(href);
}

pub fn setHost(self: *Anchor, value: []const u8, page: *Page) !void {
    const href = try getResolvedHref(self, page);
    const protocol = URL.getProtocol(href);
    const pathname = URL.getPathname(href);
    const search = URL.getSearch(href);
    const hash = URL.getHash(href);

    // Check if the host includes a port
    const colon_pos = std.mem.lastIndexOfScalar(u8, value, ':');
    const clean_host = if (colon_pos) |pos| blk: {
        const port_str = value[pos + 1 ..];
        // Remove default ports
        if (std.mem.eql(u8, protocol, "https:") and std.mem.eql(u8, port_str, "443")) {
            break :blk value[0..pos];
        }
        if (std.mem.eql(u8, protocol, "http:") and std.mem.eql(u8, port_str, "80")) {
            break :blk value[0..pos];
        }
        break :blk value;
    } else value;

    const new_href = try buildUrl(page.call_arena, protocol, clean_host, pathname, search, hash);
    try setHref(self, new_href, page);
}

pub fn getHostname(self: *Anchor, page: *Page) ![]const u8 {
    const href = try getResolvedHref(self, page);
    return URL.getHostname(href);
}

pub fn setHostname(self: *Anchor, value: []const u8, page: *Page) !void {
    const href = try getResolvedHref(self, page);
    const current_port = URL.getPort(href);
    const new_host = if (current_port.len > 0)
        try std.fmt.allocPrint(page.call_arena, "{s}:{s}", .{ value, current_port })
    else
        value;

    try setHost(self, new_host, page);
}

pub fn getPort(self: *Anchor, page: *Page) ![]const u8 {
    const href = try getResolvedHref(self, page);
    return URL.getPort(href);
}

pub fn setPort(self: *Anchor, value: ?[]const u8, page: *Page) !void {
    const href = try getResolvedHref(self, page);
    const hostname = URL.getHostname(href);
    const protocol = URL.getProtocol(href);

    // Handle null or default ports
    const new_host = if (value) |port_str| blk: {
        if (port_str.len == 0) {
            break :blk hostname;
        }
        // Check if this is a default port for the protocol
        if (std.mem.eql(u8, protocol, "https:") and std.mem.eql(u8, port_str, "443")) {
            break :blk hostname;
        }
        if (std.mem.eql(u8, protocol, "http:") and std.mem.eql(u8, port_str, "80")) {
            break :blk hostname;
        }
        break :blk try std.fmt.allocPrint(page.call_arena, "{s}:{s}", .{ hostname, port_str });
    } else hostname;

    try setHost(self, new_host, page);
}

pub fn getSearch(self: *Anchor, page: *Page) ![]const u8 {
    const href = try getResolvedHref(self, page);
    return URL.getSearch(href);
}

pub fn setSearch(self: *Anchor, value: []const u8, page: *Page) !void {
    const href = try getResolvedHref(self, page);
    const protocol = URL.getProtocol(href);
    const host = URL.getHost(href);
    const pathname = URL.getPathname(href);
    const hash = URL.getHash(href);

    // Add ? prefix if not present and value is not empty
    const search = if (value.len > 0 and value[0] != '?')
        try std.fmt.allocPrint(page.call_arena, "?{s}", .{value})
    else
        value;

    const new_href = try buildUrl(page.call_arena, protocol, host, pathname, search, hash);
    try setHref(self, new_href, page);
}

pub fn getHash(self: *Anchor, page: *Page) ![]const u8 {
    const href = try getResolvedHref(self, page);
    return URL.getHash(href);
}

pub fn setHash(self: *Anchor, value: []const u8, page: *Page) !void {
    const href = try getResolvedHref(self, page);
    const protocol = URL.getProtocol(href);
    const host = URL.getHost(href);
    const pathname = URL.getPathname(href);
    const search = URL.getSearch(href);

    // Add # prefix if not present and value is not empty
    const hash = if (value.len > 0 and value[0] != '#')
        try std.fmt.allocPrint(page.call_arena, "#{s}", .{value})
    else
        value;

    const new_href = try buildUrl(page.call_arena, protocol, host, pathname, search, hash);
    try setHref(self, new_href, page);
}

pub fn getType(self: *Anchor) []const u8 {
    return self.asElement().getAttributeSafe("type") orelse "";
}

pub fn setType(self: *Anchor, value: []const u8, page: *Page) !void {
    try self.asElement().setAttributeSafe("type", value, page);
}

pub fn getName(self: *const Anchor) []const u8 {
    return self.asConstElement().getAttributeSafe("name") orelse "";
}

pub fn setName(self: *Anchor, value: []const u8, page: *Page) !void {
    try self.asElement().setAttributeSafe("name", value, page);
}

pub fn getText(self: *Anchor, page: *Page) ![:0]const u8 {
    return self.asNode().getTextContentAlloc(page.call_arena);
}

pub fn setText(self: *Anchor, value: []const u8, page: *Page) !void {
    try self.asNode().setTextContent(value, page);
}

fn getResolvedHref(self: *Anchor, page: *Page) ![:0]const u8 {
    const href = self.asElement().getAttributeSafe("href");
    return URL.resolve(page.call_arena, page.url, href orelse "", .{});
}

// Helper function to build a new URL from components
fn buildUrl(
    allocator: std.mem.Allocator,
    protocol: []const u8,
    host: []const u8,
    pathname: []const u8,
    search: []const u8,
    hash: []const u8,
) ![:0]const u8 {
    return std.fmt.allocPrintSentinel(allocator, "{s}//{s}{s}{s}{s}", .{
        protocol,
        host,
        pathname,
        search,
        hash,
    }, 0);
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
    pub const host = bridge.accessor(Anchor.getHost, Anchor.setHost, .{});
    pub const hostname = bridge.accessor(Anchor.getHostname, Anchor.setHostname, .{});
    pub const port = bridge.accessor(Anchor.getPort, Anchor.setPort, .{});
    pub const search = bridge.accessor(Anchor.getSearch, Anchor.setSearch, .{});
    pub const hash = bridge.accessor(Anchor.getHash, Anchor.setHash, .{});
    pub const @"type" = bridge.accessor(Anchor.getType, Anchor.setType, .{});
    pub const text = bridge.accessor(Anchor.getText, Anchor.setText, .{});
    pub const toString = bridge.function(Anchor.getHref, .{});
};

const testing = @import("../../../../testing.zig");
test "WebApi: HTML.Anchor" {
    try testing.htmlRunner("element/html/anchor.html", .{});
}
