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

const lp = @import("lightpanda");
const std = @import("std");
const js = @import("../../../js/js.zig");
const Factory = @import("../../../Factory.zig");
const Frame = @import("../../../Frame.zig");

const URL = @import("../../../URL.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");

const Anchor = @This();

pub const Proto = HtmlElement;
_pad: bool = false,
_proto_canary: if (lp.IS_DEBUG) *HtmlElement else void = undefined,

pub fn asElement(self: *Anchor) *Element {
    return Factory.protoOf(self).asElement();
}
pub fn asConstElement(self: *const Anchor) *const Element {
    return Factory.protoOf(self).asElement();
}
pub fn asNode(self: *Anchor) *Node {
    return self.asElement().asNode();
}

pub fn getHref(self: *Anchor, frame: *Frame) ![]const u8 {
    const href = self.asElement().getAttributeSafe(comptime .wrap("href")) orelse return "";
    if (href.len == 0) {
        return "";
    }
    return self.asNode().resolveURL(href, frame, .{}) catch |err| switch (err) {
        // Per spec the getter must not throw; it returns the content attribute.
        error.TypeError => href,
        else => return err,
    };
}

pub fn setHref(self: *Anchor, value: []const u8, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("href"), .wrap(value), frame);
}

pub fn getOrigin(self: *Anchor, frame: *Frame) ![]const u8 {
    const href = try getResolvedHref(self, frame) orelse return "";
    return (try URL.getOrigin(frame.local_arena, href)) orelse "null";
}

pub fn getHost(self: *Anchor, frame: *Frame) ![]const u8 {
    const href = try getResolvedHref(self, frame) orelse return "";
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

pub fn setHost(self: *Anchor, value: []const u8, frame: *Frame) !void {
    const href = try getResolvedHref(self, frame) orelse return;
    const new_href = try URL.setHost(href, value, frame.call_arena);
    try setHref(self, new_href, frame);
}

pub fn getHostname(self: *Anchor, frame: *Frame) ![]const u8 {
    const href = try getResolvedHref(self, frame) orelse return "";
    return URL.getHostname(href);
}

pub fn setHostname(self: *Anchor, value: []const u8, frame: *Frame) !void {
    const href = try getResolvedHref(self, frame) orelse return;
    const new_href = try URL.setHostname(href, value, frame.call_arena);
    try setHref(self, new_href, frame);
}

pub fn getPort(self: *Anchor, frame: *Frame) ![]const u8 {
    const href = try getResolvedHref(self, frame) orelse return "";
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

pub fn setPort(self: *Anchor, value: ?[]const u8, frame: *Frame) !void {
    const href = try getResolvedHref(self, frame) orelse return;
    const new_href = try URL.setPort(href, value, frame.call_arena);
    try setHref(self, new_href, frame);
}

pub fn getSearch(self: *Anchor, frame: *Frame) ![]const u8 {
    const href = try getResolvedHref(self, frame) orelse return "";
    return URL.getSearch(href);
}

pub fn setSearch(self: *Anchor, value: []const u8, frame: *Frame) !void {
    const href = try getResolvedHref(self, frame) orelse return;
    const new_href = try URL.setSearch(href, value, frame.call_arena);
    try setHref(self, new_href, frame);
}

pub fn getHash(self: *Anchor, frame: *Frame) ![]const u8 {
    const href = try getResolvedHref(self, frame) orelse return "";
    return URL.getHash(href);
}

pub fn setHash(self: *Anchor, value: []const u8, frame: *Frame) !void {
    const href = try getResolvedHref(self, frame) orelse return;
    const new_href = try URL.setHash(href, value, frame.call_arena);
    try setHref(self, new_href, frame);
}

pub fn getPathname(self: *Anchor, frame: *Frame) ![]const u8 {
    const href = try getResolvedHref(self, frame) orelse return "";
    return URL.getPathname(href);
}

pub fn setPathname(self: *Anchor, value: []const u8, frame: *Frame) !void {
    const href = try getResolvedHref(self, frame) orelse return;
    const new_href = try URL.setPathname(href, value, frame.call_arena);
    try setHref(self, new_href, frame);
}

pub fn getProtocol(self: *Anchor, frame: *Frame) ![]const u8 {
    const href = try getResolvedHref(self, frame) orelse return ":";
    return URL.getProtocol(href);
}

pub fn setProtocol(self: *Anchor, value: []const u8, frame: *Frame) !void {
    const href = try getResolvedHref(self, frame) orelse return;
    const new_href = try URL.setProtocol(href, value, frame.call_arena);
    try setHref(self, new_href, frame);
}

pub fn getUsername(self: *Anchor, frame: *Frame) ![]const u8 {
    const href = try getResolvedHref(self, frame) orelse return "";
    return URL.getUsername(href);
}

pub fn setUsername(self: *Anchor, value: []const u8, frame: *Frame) !void {
    const href = try getResolvedHref(self, frame) orelse return;
    const new_href = try URL.setUsername(href, value, frame.call_arena);
    try setHref(self, new_href, frame);
}

pub fn getPassword(self: *Anchor, frame: *Frame) ![]const u8 {
    const href = try getResolvedHref(self, frame) orelse return "";
    return URL.getPassword(href);
}

pub fn setPassword(self: *Anchor, value: []const u8, frame: *Frame) !void {
    const href = try getResolvedHref(self, frame) orelse return;
    const new_href = try URL.setPassword(href, value, frame.call_arena);
    try setHref(self, new_href, frame);
}

pub fn getText(self: *Anchor, frame: *Frame) ![:0]const u8 {
    return self.asNode().getTextContentAlloc(frame.local_arena);
}

pub fn setText(self: *Anchor, value: []const u8, frame: *Frame) !void {
    try self.asNode().setTextContent(value, frame);
}

fn getResolvedHref(self: *Anchor, frame: *Frame) !?[:0]const u8 {
    const href = self.asElement().getAttributeSafe(comptime .wrap("href")) orelse return null;
    if (href.len == 0) {
        return null;
    }
    return self.asNode().resolveURL(href, frame, .{}) catch |err| switch (err) {
        // Unparseable against the base: treat as no resolved URL so the
        // component getters return "" instead of throwing.
        error.TypeError => null,
        else => return err,
    };
}

pub fn getTarget(self: *Anchor) []const u8 {
    return self.asElement().getAttributeSafe(comptime .wrap("target")) orelse "";
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Anchor);

    pub const Meta = struct {
        pub const name = "HTMLAnchorElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    const reflect = Element.Reflect(Anchor);
    pub const referrerPolicy = reflect.referrerPolicy();
    pub const shape = reflect.string("shape");
    pub const rev = reflect.string("rev");
    pub const ping = reflect.string("ping");
    pub const hreflang = reflect.string("hreflang");
    pub const download = reflect.string("download");
    pub const coords = reflect.string("coords");
    pub const charset = reflect.string("charset");

    pub const href = bridge.accessor(Anchor.getHref, Anchor.setHref, .{ .ce_reactions = true });
    pub const target = reflect.string("target");
    pub const name = reflect.string("name");
    pub const origin = bridge.accessor(Anchor.getOrigin, null, .{});
    pub const protocol = bridge.accessor(Anchor.getProtocol, Anchor.setProtocol, .{ .ce_reactions = true });
    pub const host = bridge.accessor(Anchor.getHost, Anchor.setHost, .{ .ce_reactions = true });
    pub const hostname = bridge.accessor(Anchor.getHostname, Anchor.setHostname, .{ .ce_reactions = true });
    pub const username = bridge.accessor(Anchor.getUsername, Anchor.setUsername, .{ .ce_reactions = true });
    pub const password = bridge.accessor(Anchor.getPassword, Anchor.setPassword, .{ .ce_reactions = true });
    pub const port = bridge.accessor(Anchor.getPort, Anchor.setPort, .{ .ce_reactions = true });
    pub const pathname = bridge.accessor(Anchor.getPathname, Anchor.setPathname, .{ .ce_reactions = true });
    pub const search = bridge.accessor(Anchor.getSearch, Anchor.setSearch, .{ .ce_reactions = true });
    pub const hash = bridge.accessor(Anchor.getHash, Anchor.setHash, .{ .ce_reactions = true });
    pub const rel = reflect.string("rel");
    pub const @"type" = reflect.string("type");
    pub const text = bridge.accessor(Anchor.getText, Anchor.setText, .{ .ce_reactions = true });
    pub const relList = bridge.accessor(_getRelList, null, .{ .null_as_undefined = true });
    pub const toString = bridge.function(Anchor.getHref, .{});

    fn _getRelList(self: *Anchor, frame: *Frame) !?*@import("../../collections.zig").DOMTokenList {
        const element = self.asElement();
        // relList is only valid for HTML and SVG <a> elements
        const namespace = element._namespace;
        if (namespace != .html and namespace != .svg) {
            return null;
        }
        return element.getRelList(frame);
    }
};

const testing = @import("../../../../testing.zig");
test "WebApi: HTML.Anchor" {
    try testing.htmlRunner("element/html/anchor.html", .{});
}
