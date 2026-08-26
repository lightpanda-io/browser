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
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");
const referrer = @import("../../../referrer.zig");

const String = lp.String;
const Meta = @This();

pub const Proto = HtmlElement;
// Because we have a JsApi.Meta, "Meta" can be ambiguous in some scopes.
// Create a different alias we can use when in such ambiguous cases.
const MetaElement = Meta;

_pad: bool = false,
_proto_canary: if (lp.IS_DEBUG) *HtmlElement else void = undefined,

pub fn asElement(self: *Meta) *Element {
    return Factory.protoOf(self).asElement();
}
pub fn asNode(self: *Meta) *Node {
    return self.asElement().asNode();
}

pub fn getName(self: *Meta) []const u8 {
    return self.asElement().getAttributeSafe(comptime .wrap("name")) orelse return "";
}

pub fn setName(self: *Meta, value: []const u8, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("name"), .wrap(value), frame);
}

pub fn getHttpEquiv(self: *Meta) []const u8 {
    return self.asElement().getAttributeSafe(comptime .wrap("http-equiv")) orelse return "";
}

pub fn setHttpEquiv(self: *Meta, value: []const u8, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("http-equiv"), .wrap(value), frame);
}

pub fn getContent(self: *Meta) []const u8 {
    return self.asElement().getAttributeSafe(comptime .wrap("content")) orelse return "";
}

pub fn setContent(self: *Meta, value: []const u8, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("content"), .wrap(value), frame);
}

pub fn getMedia(self: *Meta) []const u8 {
    return self.asElement().getAttributeSafe(comptime .wrap("media")) orelse return "";
}

pub fn setMedia(self: *Meta, value: []const u8, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("media"), .wrap(value), frame);
}

pub fn getScheme(self: *Meta) []const u8 {
    return self.asElement().getAttributeSafe(comptime .wrap("scheme")) orelse return "";
}

pub fn setScheme(self: *Meta, value: []const u8, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("scheme"), .wrap(value), frame);
}

pub fn processRefresh(self: *Meta, frame: *Frame) !void {
    if (!self.asNode().isConnected()) return;
    try self.scheduleRefresh(frame);
}

fn scheduleRefresh(self: *Meta, frame: *Frame) !void {
    if (!std.ascii.eqlIgnoreCase(self.getHttpEquiv(), "refresh")) return;

    const target = immediateRefreshTarget(self.getContent()) orelse return;
    try frame.scheduleNavigation(target, .{
        .reason = .script,
        .kind = .{ .replace = null },
    }, .{ .script = frame });
}

fn immediateRefreshTarget(content: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, content, &std.ascii.whitespace);
    const separator = std.mem.indexOfAny(u8, trimmed, ";,") orelse return null;
    const delay = std.mem.trim(u8, trimmed[0..separator], &std.ascii.whitespace);
    const seconds = std.fmt.parseFloat(f64, delay) catch return null;
    if (!std.math.isFinite(seconds) or seconds != 0) return null;

    var target = std.mem.trim(u8, trimmed[separator + 1 ..], &std.ascii.whitespace);
    if (target.len >= 3 and std.ascii.eqlIgnoreCase(target[0..3], "url")) {
        target = std.mem.trimStart(u8, target[3..], &std.ascii.whitespace);
        if (target.len == 0 or target[0] != '=') return null;
        target = std.mem.trim(u8, target[1..], &std.ascii.whitespace);
    }
    if (target.len >= 2 and ((target[0] == '"' and target[target.len - 1] == '"') or (target[0] == '\'' and target[target.len - 1] == '\''))) {
        target = std.mem.trim(u8, target[1 .. target.len - 1], &std.ascii.whitespace);
    }
    return if (target.len == 0) null else target;
}

pub const Build = struct {
    // <meta name=referrer> sets the document's referrer policy.
    pub fn created(node: *Node, frame: *Frame) !void {
        const self = node.as(Meta);
        const el = self.asElement();
        if (el.getAttributeSafe(comptime .wrap("name"))) |name| {
            if (std.ascii.eqlIgnoreCase(name, "referrer")) {
                if (el.getAttributeSafe(comptime .wrap("content"))) |content| {
                    if (referrer.parseMeta(content)) |rp| {
                        frame.referrer_policy = rp;
                    }
                }
            }
        }

        if (frame._parse_mode != .fragment) {
            try self.scheduleRefresh(frame);
        }
    }

    pub fn attributeChange(element: *Element, name: String, _: String, frame: *Frame) !void {
        if (!name.eql(comptime .wrap("http-equiv")) and !name.eql(comptime .wrap("content"))) return;
        try element.as(Meta).processRefresh(frame);
    }
};

pub const JsApi = struct {
    pub const bridge = js.Bridge(MetaElement);

    pub const Meta = struct {
        pub const name = "HTMLMetaElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const name = bridge.accessor(MetaElement.getName, MetaElement.setName, .{ .ce_reactions = true });
    pub const httpEquiv = bridge.accessor(MetaElement.getHttpEquiv, MetaElement.setHttpEquiv, .{ .ce_reactions = true });
    pub const content = bridge.accessor(MetaElement.getContent, MetaElement.setContent, .{ .ce_reactions = true });
    pub const media = bridge.accessor(MetaElement.getMedia, MetaElement.setMedia, .{ .ce_reactions = true });
    pub const scheme = bridge.accessor(MetaElement.getScheme, MetaElement.setScheme, .{ .ce_reactions = true });
};

const testing = @import("../../../../testing.zig");
test "WebApi: Meta immediate refresh target" {
    try testing.expectString("/target", immediateRefreshTarget("0; /target").?);
    try testing.expectString("/target", immediateRefreshTarget("0, URL = '/target'").?);
    try testing.expectString("https://example.com/", immediateRefreshTarget("0.0; https://example.com/").?);
    try testing.expectEqual(null, immediateRefreshTarget("1; /target"));
    try testing.expectEqual(null, immediateRefreshTarget("invalid; /target"));
}
