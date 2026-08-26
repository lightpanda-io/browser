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
const DOMTokenList = @import("../../collections.zig").DOMTokenList;

const HtmlElement = @import("../Html.zig");

const Link = @This();

pub const Proto = HtmlElement;
_proto_canary: if (lp.IS_DEBUG) *HtmlElement else void = undefined,
// Cached CSSStyleSheet for an external `rel=stylesheet` once
// `Frame.loadExternalStylesheet` has registered it. Re-fetches (href
// mutated on a connected link) reuse this sheet via `replaceSync` so the
// old rules are dropped instead of accumulating in `document.styleSheets`.
// Mirrors `Style._sheet`.
_sheet: ?*@import("../../css/CSSStyleSheet.zig") = null,

pub fn asElement(self: *Link) *Element {
    return Factory.protoOf(self).asElement();
}
pub fn asConstElement(self: *const Link) *const Element {
    return Factory.protoOf(self).asElement();
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

pub fn getMedia(self: *Link) []const u8 {
    return self.asElement().getAttributeSafe(comptime .wrap("media")) orelse return "";
}

pub fn setMedia(self: *Link, value: []const u8, frame: *Frame) !void {
    return self.asElement().setAttributeSafe(comptime .wrap("media"), .wrap(value), frame);
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
            if (Frame.preload.scriptHint(frame, Factory.protoOf(self), href)) {
                // load/error fires when the fetch settles
                return;
            }
        }
        // synthetic load, fires next tick
        return frame.queueLoad(Factory.protoOf(self));
    }

    if (std.mem.eql(u8, rel, "modulepreload")) {
        // "as" defaults to script in this case
        const as = element.getAttributeSafe(comptime .wrap("as")) orelse "";
        if (as.len == 0 or std.ascii.eqlIgnoreCase(as, "script")) {
            if (Frame.preload.moduleHint(frame, Factory.protoOf(self), href)) {
                // load/error fires when the fetch settles
                return;
            }
        }
        // synthetic load, fires next tick
        return frame.queueLoad(Factory.protoOf(self));
    }
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Link);

    pub const Meta = struct {
        pub const name = "HTMLLinkElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    const reflect = Element.Reflect(Link);
    pub const nonce = reflect.string("nonce");

    pub const as = reflect.enumerated("as", &.{ "fetch", "audio", "document", "embed", "font", "image", "manifest", "object", "report", "script", "sharedworker", "style", "track", "video", "worker", "xslt" }, .{});
    pub const rel = bridge.accessor(Link.getRel, Link.setRel, .{ .ce_reactions = true });
    pub const media = bridge.accessor(Link.getMedia, Link.setMedia, .{ .ce_reactions = true });
    pub const href = bridge.accessor(Link.getHref, Link.setHref, .{ .ce_reactions = true });
    pub const crossOrigin = reflect.enumerated("crossorigin", &.{ "anonymous", "use-credentials" }, .{ .missing = null, .nullable = true, .invalid = "anonymous" });
    pub const referrerPolicy = reflect.referrerPolicy();
    pub const charset = reflect.string("charset");
    pub const hreflang = reflect.string("hreflang");
    pub const integrity = reflect.string("integrity");
    pub const @"type" = reflect.string("type");
    pub const rev = reflect.string("rev");
    pub const target = reflect.string("target");
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
    testing.silenceLog(&.{.http});
    try testing.htmlRunner("css/external_stylesheet.html", .{ .load_external_stylesheets = true });
}

// Regression: a synchronous external-stylesheet fetch must not strand the
// completion of an in-flight <script defer> (held back by the blocking-
// request gate during the sync window). Otherwise the deferred-script queue
// never drains and the document is stuck at readyState "loading".
test "WebApi: HTML.Link deferred script then external stylesheet" {
    testing.silenceLog(&.{.http});
    try testing.htmlRunner("css/deferred_script_then_stylesheet.html", .{ .load_external_stylesheets = true });
}
