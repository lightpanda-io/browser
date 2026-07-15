// Copyright (C) 2023-2026  Lightpanda (Selecy SAS)
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
const Frame = @import("../../../Frame.zig");
const URL = @import("../../../URL.zig");

const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const DOMTokenList = @import("../../collections.zig").DOMTokenList;

const HtmlElement = @import("../Html.zig");

const Area = @This();

_proto: *HtmlElement,

pub fn asElement(self: *Area) *Element {
    return self._proto._proto;
}
pub fn asConstElement(self: *const Area) *const Element {
    return self._proto._proto;
}
pub fn asNode(self: *Area) *Node {
    return self.asElement().asNode();
}

pub fn getAlt(self: *const Area) []const u8 {
    return self.asConstElement().getAttributeSafe(comptime .wrap("alt")) orelse "";
}

pub fn setAlt(self: *Area, value: []const u8, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("alt"), .wrap(value), frame);
}

pub fn getCoords(self: *const Area) []const u8 {
    return self.asConstElement().getAttributeSafe(comptime .wrap("coords")) orelse "";
}

pub fn setCoords(self: *Area, value: []const u8, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("coords"), .wrap(value), frame);
}

pub fn getShape(self: *const Area) []const u8 {
    return self.asConstElement().getAttributeSafe(comptime .wrap("shape")) orelse "";
}

pub fn setShape(self: *Area, value: []const u8, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("shape"), .wrap(value), frame);
}

pub fn getTarget(self: *const Area) []const u8 {
    return self.asConstElement().getAttributeSafe(comptime .wrap("target")) orelse "";
}

pub fn setTarget(self: *Area, value: []const u8, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("target"), .wrap(value), frame);
}

pub fn getDownload(self: *const Area) []const u8 {
    return self.asConstElement().getAttributeSafe(comptime .wrap("download")) orelse "";
}

pub fn setDownload(self: *Area, value: []const u8, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("download"), .wrap(value), frame);
}

pub fn getRel(self: *const Area) []const u8 {
    return self.asConstElement().getAttributeSafe(comptime .wrap("rel")) orelse "";
}

pub fn setRel(self: *Area, value: []const u8, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("rel"), .wrap(value), frame);
}

pub fn getReferrerPolicy(self: *const Area) []const u8 {
    const valid_referrer_policy = [_][]const u8{
        "",
        "no-referrer",
        "no-referrer-when-downgrade",
        "same-origin",
        "origin",
        "strict-origin",
        "origin-when-cross-origin",
        "strict-origin-when-cross-origin",
        "unsafe-url",
    };
    return HtmlElement.reflectEnumerated(self.asConstElement().getAttributeSafe(.wrap("referrerpolicy")), &valid_referrer_policy, "", "").?;
}

pub fn setReferrerPolicy(self: *Area, value: []const u8, frame: *Frame) !void {
    return self.asElement().setAttributeSafe(.wrap("referrerpolicy"), .wrap(value), frame);
}

pub fn getHref(self: *Area, frame: *Frame) ![]const u8 {
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

pub fn setHref(self: *Area, value: []const u8, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("href"), .wrap(value), frame);
}

pub fn getOrigin(self: *Area, frame: *Frame) ![]const u8 {
    const href = try getResolvedHref(self, frame) orelse return "";
    return (try URL.getOrigin(frame.local_arena, href)) orelse "null";
}

pub fn getHost(self: *Area, frame: *Frame) ![]const u8 {
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

pub fn setHost(self: *Area, value: []const u8, frame: *Frame) !void {
    const href = try getResolvedHref(self, frame) orelse return;
    const new_href = try URL.setHost(href, value, frame.call_arena);
    try setHref(self, new_href, frame);
}

pub fn getHostname(self: *Area, frame: *Frame) ![]const u8 {
    const href = try getResolvedHref(self, frame) orelse return "";
    return URL.getHostname(href);
}

pub fn setHostname(self: *Area, value: []const u8, frame: *Frame) !void {
    const href = try getResolvedHref(self, frame) orelse return;
    const new_href = try URL.setHostname(href, value, frame.call_arena);
    try setHref(self, new_href, frame);
}

pub fn getUsername(self: *Area, frame: *Frame) ![]const u8 {
    const href = try getResolvedHref(self, frame) orelse return "";
    return URL.getUsername(href);
}

pub fn setUsername(self: *Area, value: []const u8, frame: *Frame) !void {
    const href = try getResolvedHref(self, frame) orelse return;
    const new_href = try URL.setUsername(href, value, frame.call_arena);
    try setHref(self, new_href, frame);
}

pub fn getPassword(self: *Area, frame: *Frame) ![]const u8 {
    const href = try getResolvedHref(self, frame) orelse return "";
    return URL.getPassword(href);
}

pub fn setPassword(self: *Area, value: []const u8, frame: *Frame) !void {
    const href = try getResolvedHref(self, frame) orelse return;
    const new_href = try URL.setPassword(href, value, frame.call_arena);
    try setHref(self, new_href, frame);
}

pub fn getPort(self: *Area, frame: *Frame) ![]const u8 {
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

pub fn setPort(self: *Area, value: ?[]const u8, frame: *Frame) !void {
    const href = try getResolvedHref(self, frame) orelse return;
    const new_href = try URL.setPort(href, value, frame.call_arena);
    try setHref(self, new_href, frame);
}

pub fn getSearch(self: *Area, frame: *Frame) ![]const u8 {
    const href = try getResolvedHref(self, frame) orelse return "";
    return URL.getSearch(href);
}

pub fn setSearch(self: *Area, value: []const u8, frame: *Frame) !void {
    const href = try getResolvedHref(self, frame) orelse return;
    const new_href = try URL.setSearch(href, value, frame.call_arena);
    try setHref(self, new_href, frame);
}

pub fn getHash(self: *Area, frame: *Frame) ![]const u8 {
    const href = try getResolvedHref(self, frame) orelse return "";
    return URL.getHash(href);
}

pub fn setHash(self: *Area, value: []const u8, frame: *Frame) !void {
    const href = try getResolvedHref(self, frame) orelse return;
    const new_href = try URL.setHash(href, value, frame.call_arena);
    try setHref(self, new_href, frame);
}

pub fn getPathname(self: *Area, frame: *Frame) ![]const u8 {
    const href = try getResolvedHref(self, frame) orelse return "";
    return URL.getPathname(href);
}

pub fn setPathname(self: *Area, value: []const u8, frame: *Frame) !void {
    const href = try getResolvedHref(self, frame) orelse return;
    const new_href = try URL.setPathname(href, value, frame.call_arena);
    try setHref(self, new_href, frame);
}

pub fn getProtocol(self: *Area, frame: *Frame) ![]const u8 {
    const href = try getResolvedHref(self, frame) orelse return ":";
    return URL.getProtocol(href);
}

pub fn setProtocol(self: *Area, value: []const u8, frame: *Frame) !void {
    const href = try getResolvedHref(self, frame) orelse return;
    const new_href = try URL.setProtocol(href, value, frame.call_arena);
    try setHref(self, new_href, frame);
}

pub fn getRelList(self: *Area, frame: *Frame) !?*DOMTokenList {
    const element = self.asElement();
    // relList is only valid for HTML <area> elements
    if (element._namespace != .html) {
        return null;
    }
    return element.getRelList(frame);
}

fn getResolvedHref(self: *Area, frame: *Frame) !?[:0]const u8 {
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

pub const JsApi = struct {
    pub const bridge = js.Bridge(Area);

    pub const Meta = struct {
        pub const name = "HTMLAreaElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const href = bridge.accessor(Area.getHref, Area.setHref, .{ .ce_reactions = true });
    pub const origin = bridge.accessor(Area.getOrigin, null, .{});
    pub const protocol = bridge.accessor(Area.getProtocol, Area.setProtocol, .{ .ce_reactions = true });
    pub const host = bridge.accessor(Area.getHost, Area.setHost, .{ .ce_reactions = true });
    pub const hostname = bridge.accessor(Area.getHostname, Area.setHostname, .{ .ce_reactions = true });
    pub const username = bridge.accessor(Area.getUsername, Area.setUsername, .{ .ce_reactions = true });
    pub const password = bridge.accessor(Area.getPassword, Area.setPassword, .{ .ce_reactions = true });
    pub const port = bridge.accessor(Area.getPort, Area.setPort, .{ .ce_reactions = true });
    pub const pathname = bridge.accessor(Area.getPathname, Area.setPathname, .{ .ce_reactions = true });
    pub const search = bridge.accessor(Area.getSearch, Area.setSearch, .{ .ce_reactions = true });
    pub const hash = bridge.accessor(Area.getHash, Area.setHash, .{ .ce_reactions = true });
    pub const alt = bridge.accessor(Area.getAlt, Area.setAlt, .{ .ce_reactions = true });
    pub const coords = bridge.accessor(Area.getCoords, Area.setCoords, .{ .ce_reactions = true });
    pub const shape = bridge.accessor(Area.getShape, Area.setShape, .{ .ce_reactions = true });
    pub const target = bridge.accessor(Area.getTarget, Area.setTarget, .{ .ce_reactions = true });
    pub const download = bridge.accessor(Area.getDownload, Area.setDownload, .{ .ce_reactions = true });
    pub const rel = bridge.accessor(Area.getRel, Area.setRel, .{ .ce_reactions = true });
    pub const referrerPolicy = bridge.accessor(Area.getReferrerPolicy, Area.setReferrerPolicy, .{ .ce_reactions = true });
    pub const toString = bridge.function(Area.getHref, .{});
    pub const relList = bridge.accessor(Area.getRelList, null, .{ .null_as_undefined = true });
};

const testing = @import("../../../../testing.zig");
test "WebApi: HTML.Area" {
    try testing.htmlRunner("element/html/area.html", .{});
}
