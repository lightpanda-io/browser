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
const lp = @import("lightpanda");

const js = @import("../../../js/js.zig");
const Frame = @import("../../../Frame.zig");
const Factory = @import("../../../Factory.zig");
const referrer = @import("../../../referrer.zig");

const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");

const HtmlElement = @import("../Html.zig");

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
    if (!std.ascii.eqlIgnoreCase(self.getHttpEquiv(), "refresh")) {
        return;
    }

    if (frame._load_state != .complete) {
        // meta refresh doesn't fire until document and, by that point, this
        // meta tag might change. We signal the frame that MAYBE there's a meta
        // refresh that it needs to execute. For the common case where a page
        // never has a meta refresh, the frame's load can skip finding one.
        frame._maybe_meta_refresh = true;
        return;
    }

    // Already loaded, so this navigates as soon as it's a valid refresh.
    if (!self.asNode().isConnected()) {
        return;
    }
    const target = immediateRefreshTarget(self.getContent()) orelse return;
    return frame.metaRefresh(target);
}

// Where this meta wants to navigate, or null if it doesn't. Only for a meta
// that's in the document: the caller's tree walk is what establishes that.
pub fn refreshTarget(self: *Meta) ?[]const u8 {
    if (!std.ascii.eqlIgnoreCase(self.getHttpEquiv(), "refresh")) {
        return null;
    }
    return immediateRefreshTarget(self.getContent());
}

// Extracts the URL out of a <meta http-equiv=refresh> `content`
fn immediateRefreshTarget(content: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, content, &std.ascii.whitespace);

    // The delay ends at the first separator. Without one, there's no URL.
    const separators = std.ascii.whitespace ++ [_]u8{ ';', ',' };
    const separator = std.mem.indexOfAny(u8, trimmed, &separators) orelse return null;
    const seconds = std.fmt.parseFloat(f64, trimmed[0..separator]) catch return null;
    if (seconds != 0) {
        // For now, we skip any meta refresh where the delay isn't 0. It isn't
        // clear if there's a "best" option in all cases for this.
        lp.log.info(.browser, "ignoring meta refresh", .{ .hint = "Non-zero delay meta refresh are currently always ignored" });
        return null;
    }

    var rest = std.mem.trimStart(u8, trimmed[separator..], &std.ascii.whitespace);
    if (rest.len > 0 and (rest[0] == ';' or rest[0] == ',')) {
        rest = std.mem.trimStart(u8, rest[1..], &std.ascii.whitespace);
    }

    // An optional "url" prefix. Without the "=", it isn't a prefix at all, the
    // value is the URL itself (i.e. "0; url.html").
    if (rest.len >= 3 and std.ascii.eqlIgnoreCase(rest[0..3], "url")) {
        const after_url = std.mem.trimStart(u8, rest[3..], &std.ascii.whitespace);
        if (after_url.len > 0 and after_url[0] == '=') {
            rest = std.mem.trimStart(u8, after_url[1..], &std.ascii.whitespace);
        }
    }

    // A quoted URL ends at its matching quote; whatever follows is junk.
    if (rest.len > 0 and (rest[0] == '"' or rest[0] == '\'')) {
        const quote = rest[0];
        const quoted = rest[1..];
        rest = quoted[0 .. std.mem.indexOfScalar(u8, quoted, quote) orelse quoted.len];
    }

    const target = std.mem.trim(u8, rest, &std.ascii.whitespace);
    // an empty URL is a reload of the current page
    return if (target.len == 0) null else target;
}

pub const Build = struct {
    pub fn created(node: *Node, frame: *Frame) !void {
        const self = node.as(Meta);
        const el = self.asElement();

        // <meta name=referrer> sets the document's referrer policy.
        if (el.getAttributeSafe(comptime .wrap("name"))) |name| {
            if (std.ascii.eqlIgnoreCase(name, "referrer")) {
                if (el.getAttributeSafe(comptime .wrap("content"))) |content| {
                    if (referrer.parseMeta(content)) |rp| {
                        frame.referrer_policy = rp;
                    }
                }
            }
        }

        if (frame._parse_mode == .fragment) {
            // innerHTML and DOMParser: these nodes are detached, they'll go
            // through nodeIsReady if they're ever inserted.
            return;
        }
        return self.processRefresh(frame);
    }

    pub fn attributeChange(element: *Element, name: String, _: String, frame: *Frame) !void {
        if (!name.eql(comptime .wrap("http-equiv")) and !name.eql(comptime .wrap("content"))) {
            return;
        }
        return element.as(Meta).processRefresh(element.asNode().ownerFrame(frame));
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
    try testing.expectString("/target", immediateRefreshTarget("0,/target").?);
    try testing.expectString("/target", immediateRefreshTarget("  0 /target  ").?);
    try testing.expectString("/target", immediateRefreshTarget("0, URL = '/target'").?);
    try testing.expectString("/target", immediateRefreshTarget("0;url=/target").?);
    try testing.expectString("/target", immediateRefreshTarget("0; \"/target\" junk").?);
    try testing.expectString("url.html", immediateRefreshTarget("0; url.html").?);
    try testing.expectString("urlencoded.html", immediateRefreshTarget("0;urlencoded.html").?);
    try testing.expectString("https://example.com/", immediateRefreshTarget("0.0; https://example.com/").?);

    try testing.expectEqual(null, immediateRefreshTarget(""));
    try testing.expectEqual(null, immediateRefreshTarget("0"));
    try testing.expectEqual(null, immediateRefreshTarget("0;"));
    try testing.expectEqual(null, immediateRefreshTarget("0; url="));
    try testing.expectEqual(null, immediateRefreshTarget("1; /target"));
    try testing.expectEqual(null, immediateRefreshTarget("0.5; /target"));
    try testing.expectEqual(null, immediateRefreshTarget("invalid; /target"));
    try testing.expectEqual(null, immediateRefreshTarget("0abc; /target"));
}
