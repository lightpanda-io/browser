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
const Frame = @import("../../../Frame.zig");

const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const DOMTokenList = @import("../../collections.zig").DOMTokenList;

const HtmlElement = @import("../Html.zig");

const Link = @This();
_proto: *HtmlElement,
// Cached CSSStyleSheet for an external `rel=stylesheet` once
// `Frame.loadExternalStylesheet` has registered it. Re-fetches (href
// mutated on a connected link) reuse this sheet via `replaceSync` so the
// old rules are dropped instead of accumulating in `document.styleSheets`.
// Mirrors `Style._sheet`.
_sheet: ?*@import("../../css/CSSStyleSheet.zig") = null,

pub fn asElement(self: *Link) *Element {
    return self._proto._proto;
}
pub fn asConstElement(self: *const Link) *const Element {
    return self._proto._proto;
}
pub fn asNode(self: *Link) *Node {
    return self.asElement().asNode();
}

pub fn getHref(self: *Link, frame: *Frame) ![]const u8 {
    const element = self.asElement();
    const href = element.getAttributeSafe(comptime .wrap("href")) orelse return "";
    if (href.len == 0) {
        return "";
    }
    return element.asNode().resolveURLReflect(href, frame, .{});
}

pub fn setHref(self: *Link, value: []const u8, frame: *Frame) !void {
    const element = self.asElement();
    try element.setAttributeSafe(comptime .wrap("href"), .wrap(value), frame);

    if (element.asNode().isConnected()) {
        try self.linkAddedCallback(frame);
    }
}

pub fn getRel(self: *Link) []const u8 {
    return self.asElement().getAttributeSafe(comptime .wrap("rel")) orelse return "";
}

pub fn setRel(self: *Link, value: []const u8, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("rel"), .wrap(value), frame);
}

pub fn getAs(self: *const Link) []const u8 {
    const valid_as = [_][]const u8{
        "fetch",
        "audio",
        "document",
        "embed",
        "font",
        "image",
        "manifest",
        "object",
        "report",
        "script",
        "sharedworker",
        "style",
        "track",
        "video",
        "worker",
        "xslt",
    };
    return HtmlElement.reflectEnumerated(self.asConstElement().getAttributeSafe(comptime .wrap("as")), &valid_as, "", "").?;
}

pub fn setAs(self: *Link, value: []const u8, frame: *Frame) !void {
    return self.asElement().setAttributeSafe(comptime .wrap("as"), .wrap(value), frame);
}

pub fn getReferrerPolicy(self: *const Link) []const u8 {
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

pub fn setReferrerPolicy(self: *Link, value: []const u8, frame: *Frame) !void {
    return self.asElement().setAttributeSafe(.wrap("referrerpolicy"), .wrap(value), frame);
}

pub fn getMedia(self: *Link) []const u8 {
    return self.asElement().getAttributeSafe(comptime .wrap("media")) orelse return "";
}

pub fn setMedia(self: *Link, value: []const u8, frame: *Frame) !void {
    return self.asElement().setAttributeSafe(comptime .wrap("media"), .wrap(value), frame);
}

pub fn getCrossOrigin(self: *const Link) ?[]const u8 {
    const valid_cross_origin = [_][]const u8{
        "anonymous", "use-credentials",
    };
    return HtmlElement.reflectEnumerated(self.asConstElement().getAttributeSafe(comptime .wrap("crossorigin")), &valid_cross_origin, null, "anonymous");
}

pub fn setCrossOrigin(self: *Link, value: ?[]const u8, frame: *Frame) !void {
    // Nullable reflection: a null (or undefined) value removes the attribute;
    // otherwise the content attribute mirrors the value verbatim and the
    // getter canonicalizes it.
    if (value) |v| {
        return self.asElement().setAttributeSafe(comptime .wrap("crossorigin"), .wrap(v), frame);
    }
    return self.asElement().removeAttribute(comptime .wrap("crossorigin"), frame);
}

pub fn getCharset(self: *const Link) []const u8 {
    return self.asConstElement().getAttributeSafe(comptime .wrap("charset")) orelse "";
}

pub fn setCharset(self: *Link, value: []const u8, frame: *Frame) !void {
    return self.asElement().setAttributeSafe(comptime .wrap("charset"), .wrap(value), frame);
}

pub fn getHreflang(self: *const Link) []const u8 {
    return self.asConstElement().getAttributeSafe(comptime .wrap("hreflang")) orelse "";
}

pub fn setHreflang(self: *Link, value: []const u8, frame: *Frame) !void {
    return self.asElement().setAttributeSafe(comptime .wrap("hreflang"), .wrap(value), frame);
}

pub fn getIntegrity(self: *const Link) []const u8 {
    return self.asConstElement().getAttributeSafe(comptime .wrap("integrity")) orelse "";
}

pub fn setIntegrity(self: *Link, value: []const u8, frame: *Frame) !void {
    return self.asElement().setAttributeSafe(comptime .wrap("integrity"), .wrap(value), frame);
}

pub fn getType(self: *const Link) []const u8 {
    return self.asConstElement().getAttributeSafe(comptime .wrap("type")) orelse "";
}

pub fn setType(self: *Link, value: []const u8, frame: *Frame) !void {
    return self.asElement().setAttributeSafe(comptime .wrap("type"), .wrap(value), frame);
}

pub fn getRev(self: *const Link) []const u8 {
    return self.asConstElement().getAttributeSafe(comptime .wrap("rev")) orelse "";
}

pub fn setRev(self: *Link, value: []const u8, frame: *Frame) !void {
    return self.asElement().setAttributeSafe(comptime .wrap("rev"), .wrap(value), frame);
}

pub fn getTarget(self: *const Link) []const u8 {
    return self.asConstElement().getAttributeSafe(comptime .wrap("target")) orelse "";
}

pub fn setTarget(self: *Link, value: []const u8, frame: *Frame) !void {
    return self.asElement().setAttributeSafe(comptime .wrap("target"), .wrap(value), frame);
}

pub fn getSizes(self: *Link, frame: *Frame) !?*DOMTokenList {
    const element = self.asElement();
    if (element._namespace != .html) {
        return null;
    }
    return element.getTokenList(.sizes, frame);
}

pub fn getRelList(self: *Link, frame: *Frame) !?*DOMTokenList {
    const element = self.asElement();
    // relList is only valid for HTML <link> elements, not SVG or MathML
    if (element._namespace != .html) {
        return null;
    }
    return element.getRelList(frame);
}

pub fn linkAddedCallback(self: *Link, frame: *Frame) !void {
    // if we're planning on navigating to another frame, don't trigger load event.
    if (frame.isGoingAway()) {
        return;
    }

    const element = self.asElement();

    const href = element.getAttributeSafe(comptime .wrap("href")) orelse return;
    if (href.len == 0) {
        return;
    }

    const rel = element.getAttributeSafe(comptime .wrap("rel")) orelse return;

    // Opt-in fetch for `rel="stylesheet"` — drives `frame.loadExternalStylesheet`,
    // which fires the load/error event itself.
    if (std.mem.eql(u8, rel, "stylesheet")) {
        return frame.loadExternalStylesheet(self, href);
    }

    if (std.mem.eql(u8, rel, "preload")) {
        const as = element.getAttributeSafe(comptime .wrap("as")) orelse "";
        if (std.ascii.eqlIgnoreCase(as, "script")) {
            if (frame.preloadScriptHint(self._proto, href)) {
                // load/error fires when the fetch settles
                return;
            }
        }
        // synthetic load, fires next tick
        return frame.queueLoad(self._proto);
    }

    if (std.mem.eql(u8, rel, "modulepreload")) {
        // "as" defaults to script in this case
        const as = element.getAttributeSafe(comptime .wrap("as")) orelse "";
        if (as.len == 0 or std.ascii.eqlIgnoreCase(as, "script")) {
            if (frame.preloadModuleHint(self._proto, href)) {
                // load/error fires when the fetch settles
                return;
            }
        }
        // synthetic load, fires next tick
        return frame.queueLoad(self._proto);
    }
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Link);

    pub const Meta = struct {
        pub const name = "HTMLLinkElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const as = bridge.accessor(Link.getAs, Link.setAs, .{ .ce_reactions = true });
    pub const rel = bridge.accessor(Link.getRel, Link.setRel, .{ .ce_reactions = true });
    pub const media = bridge.accessor(Link.getMedia, Link.setMedia, .{ .ce_reactions = true });
    pub const href = bridge.accessor(Link.getHref, Link.setHref, .{ .ce_reactions = true });
    pub const crossOrigin = bridge.accessor(Link.getCrossOrigin, Link.setCrossOrigin, .{ .ce_reactions = true });
    pub const referrerPolicy = bridge.accessor(Link.getReferrerPolicy, Link.setReferrerPolicy, .{ .ce_reactions = true });
    pub const charset = bridge.accessor(Link.getCharset, Link.setCharset, .{ .ce_reactions = true });
    pub const hreflang = bridge.accessor(Link.getHreflang, Link.setHreflang, .{ .ce_reactions = true });
    pub const integrity = bridge.accessor(Link.getIntegrity, Link.setIntegrity, .{ .ce_reactions = true });
    pub const @"type" = bridge.accessor(Link.getType, Link.setType, .{ .ce_reactions = true });
    pub const rev = bridge.accessor(Link.getRev, Link.setRev, .{ .ce_reactions = true });
    pub const target = bridge.accessor(Link.getTarget, Link.setTarget, .{ .ce_reactions = true });
    pub const relList = bridge.accessor(Link.getRelList, null, .{ .null_as_undefined = true });
    pub const sizes = bridge.accessor(Link.getSizes, null, .{ .null_as_undefined = true });
};

// Parser-created <link> elements are void (no closing tag) so they never
// reach `Frame.nodeComplete`. Mirror `Image.Build.created` so static head
// links in HTML go through `linkAddedCallback` at element-create time,
// with attributes already populated by `populateElementAttributes`.
pub const Build = struct {
    pub fn created(node: *Node, frame: *Frame) !void {
        const self = node.as(Link);
        return self.linkAddedCallback(frame);
    }
};

const testing = @import("../../../../testing.zig");
test "WebApi: HTML.Link" {
    try testing.htmlRunner("element/html/link.html", .{});
}

test "WebApi: HTML.Link external stylesheet" {
    const filter: testing.LogFilter = .init(&.{.http});
    defer filter.deinit();
    try testing.htmlRunner("css/external_stylesheet.html", .{ .load_external_stylesheets = true });
}

// Regression: a synchronous external-stylesheet fetch must not strand the
// completion of an in-flight <script defer> (held back by the blocking-
// request gate during the sync window). Otherwise the deferred-script queue
// never drains and the document is stuck at readyState "loading".
test "WebApi: HTML.Link deferred script then external stylesheet" {
    const filter: testing.LogFilter = .init(&.{.http});
    defer filter.deinit();
    try testing.htmlRunner("css/deferred_script_then_stylesheet.html", .{ .load_external_stylesheets = true });
}
