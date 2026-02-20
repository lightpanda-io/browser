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
const js = @import("../js/js.zig");
const String = @import("../../string.zig").String;

const Page = @import("../Page.zig");
const Node = @import("Node.zig");
const Document = @import("Document.zig");
const Element = @import("Element.zig");
const DocumentType = @import("DocumentType.zig");
const collections = @import("collections.zig");

const HTMLDocument = @This();

_proto: *Document,
_document_type: ?*DocumentType = null,

pub fn asDocument(self: *HTMLDocument) *Document {
    return self._proto;
}

pub fn asNode(self: *HTMLDocument) *Node {
    return self._proto.asNode();
}

pub fn asEventTarget(self: *HTMLDocument) *@import("EventTarget.zig") {
    return self._proto.asEventTarget();
}

// HTML-specific accessors
pub fn getHead(self: *HTMLDocument) ?*Element.Html.Head {
    const doc_el = self._proto.getDocumentElement() orelse return null;
    var child = doc_el.asNode().firstChild();
    while (child) |node| {
        if (node.is(Element.Html.Head)) |head| {
            return head;
        }
        child = node.nextSibling();
    }
    return null;
}

pub fn getBody(self: *HTMLDocument) ?*Element.Html.Body {
    const doc_el = self._proto.getDocumentElement() orelse return null;
    var child = doc_el.asNode().firstChild();
    while (child) |node| {
        if (node.is(Element.Html.Body)) |body| {
            return body;
        }
        child = node.nextSibling();
    }
    return null;
}

pub fn getTitle(self: *HTMLDocument, page: *Page) ![]const u8 {
    // Search the entire document for the first <title> element
    const root = self._proto.getDocumentElement() orelse return "";
    const title_element = blk: {
        var walker = @import("TreeWalker.zig").Full.init(root.asNode(), .{});
        while (walker.next()) |node| {
            if (node.is(Element.Html.Title)) |title| {
                break :blk title;
            }
        }
        return "";
    };

    var buf = std.Io.Writer.Allocating.init(page.call_arena);
    try title_element.asNode().getTextContent(&buf.writer);
    const text = buf.written();

    if (text.len == 0) {
        return "";
    }

    var started = false;
    var in_whitespace = false;
    var result: std.ArrayList(u8) = .empty;
    try result.ensureTotalCapacity(page.call_arena, text.len);

    for (text) |c| {
        const is_ascii_ws = c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == '\x0C';

        if (is_ascii_ws) {
            if (started) {
                in_whitespace = true;
            }
        } else {
            if (in_whitespace) {
                result.appendAssumeCapacity(' ');
                in_whitespace = false;
            }
            result.appendAssumeCapacity(c);
            started = true;
        }
    }

    return result.items;
}

pub fn setTitle(self: *HTMLDocument, title: []const u8, page: *Page) !void {
    const head = self.getHead() orelse return;

    // Find existing title element in head
    var it = head.asNode().childrenIterator();
    while (it.next()) |node| {
        if (node.is(Element.Html.Title)) |title_element| {
            // Replace children, but don't create text node for empty string
            if (title.len == 0) {
                return title_element.asElement().replaceChildren(&.{}, page);
            } else {
                return title_element.asElement().replaceChildren(&.{.{ .text = title }}, page);
            }
        }
    }

    // No title element found, create one
    const title_node = try page.createElementNS(.html, "title", null);
    const title_element = title_node.as(Element);

    // Only add text if non-empty
    if (title.len > 0) {
        try title_element.replaceChildren(&.{.{ .text = title }}, page);
    }

    _ = try head.asNode().appendChild(title_node, page);
}

pub fn getImages(self: *HTMLDocument, page: *Page) !collections.NodeLive(.tag) {
    return collections.NodeLive(.tag).init(self.asNode(), .img, page);
}

pub fn getScripts(self: *HTMLDocument, page: *Page) !collections.NodeLive(.tag) {
    return collections.NodeLive(.tag).init(self.asNode(), .script, page);
}

pub fn getLinks(self: *HTMLDocument, page: *Page) !collections.NodeLive(.links) {
    return collections.NodeLive(.links).init(self.asNode(), {}, page);
}

pub fn getAnchors(self: *HTMLDocument, page: *Page) !collections.NodeLive(.anchors) {
    return collections.NodeLive(.anchors).init(self.asNode(), {}, page);
}

pub fn getForms(self: *HTMLDocument, page: *Page) !collections.NodeLive(.tag) {
    return collections.NodeLive(.tag).init(self.asNode(), .form, page);
}

pub fn getEmbeds(self: *HTMLDocument, page: *Page) !collections.NodeLive(.tag) {
    return collections.NodeLive(.tag).init(self.asNode(), .embed, page);
}

const applet_string = String.init(undefined, "applet", .{}) catch unreachable;
pub fn getApplets(self: *HTMLDocument, page: *Page) !collections.NodeLive(.tag_name) {
    return collections.NodeLive(.tag_name).init(self.asNode(), applet_string, page);
}

pub fn getCurrentScript(self: *const HTMLDocument) ?*Element.Html.Script {
    return self._proto._current_script;
}

pub fn getLocation(self: *const HTMLDocument) ?*@import("Location.zig") {
    return self._proto._location;
}

pub fn setLocation(_: *const HTMLDocument, url: [:0]const u8, page: *Page) !void {
    return page.scheduleNavigation(url, .{ .reason = .script, .kind = .{ .push = null } }, .script);
}

pub fn getAll(self: *HTMLDocument, page: *Page) !*collections.HTMLAllCollection {
    return page._factory.create(collections.HTMLAllCollection.init(self.asNode(), page));
}

pub fn getCookie(_: *HTMLDocument, page: *Page) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    try page._session.cookie_jar.forRequest(page.url, buf.writer(page.call_arena), .{
        .is_http = false,
        .is_navigation = true,
    });
    return buf.items;
}

pub fn setCookie(_: *HTMLDocument, cookie_str: []const u8, page: *Page) ![]const u8 {
    // we use the cookie jar's allocator to parse the cookie because it
    // outlives the page's arena.
    const Cookie = @import("storage/Cookie.zig");
    const c = Cookie.parse(page._session.cookie_jar.allocator, page.url, cookie_str) catch {
        // Invalid cookies should be silently ignored, not throw errors
        return "";
    };
    errdefer c.deinit();
    if (c.http_only) {
        c.deinit();
        return ""; // HttpOnly cookies cannot be set from JS
    }
    try page._session.cookie_jar.add(c, std.time.timestamp());
    return cookie_str;
}

pub fn getDocType(self: *HTMLDocument, page: *Page) !*DocumentType {
    if (self._document_type) |dt| {
        return dt;
    }

    var tw = @import("TreeWalker.zig").Full.init(self.asNode(), .{});
    while (tw.next()) |node| {
        if (node._type == .document_type) {
            self._document_type = node.as(DocumentType);
            return self._document_type.?;
        }
    }

    self._document_type = try page._factory.node(DocumentType{
        ._proto = undefined,
        ._name = "html",
        ._public_id = "",
        ._system_id = "",
    });
    return self._document_type.?;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(HTMLDocument);

    pub const Meta = struct {
        pub const name = "HTMLDocument";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(_constructor, .{});
    fn _constructor(page: *Page) !*HTMLDocument {
        return page._factory.document(HTMLDocument{
            ._proto = undefined,
        });
    }

    pub const head = bridge.accessor(HTMLDocument.getHead, null, .{});
    pub const body = bridge.accessor(HTMLDocument.getBody, null, .{});
    pub const title = bridge.accessor(HTMLDocument.getTitle, HTMLDocument.setTitle, .{});
    pub const images = bridge.accessor(HTMLDocument.getImages, null, .{});
    pub const scripts = bridge.accessor(HTMLDocument.getScripts, null, .{});
    pub const links = bridge.accessor(HTMLDocument.getLinks, null, .{});
    pub const anchors = bridge.accessor(HTMLDocument.getAnchors, null, .{});
    pub const forms = bridge.accessor(HTMLDocument.getForms, null, .{});
    pub const embeds = bridge.accessor(HTMLDocument.getEmbeds, null, .{});
    pub const applets = bridge.accessor(HTMLDocument.getApplets, null, .{});
    pub const plugins = bridge.accessor(HTMLDocument.getEmbeds, null, .{});
    pub const currentScript = bridge.accessor(HTMLDocument.getCurrentScript, null, .{});
    pub const location = bridge.accessor(HTMLDocument.getLocation, HTMLDocument.setLocation, .{});
    pub const all = bridge.accessor(HTMLDocument.getAll, null, .{});
    pub const cookie = bridge.accessor(HTMLDocument.getCookie, HTMLDocument.setCookie, .{});
    pub const doctype = bridge.accessor(HTMLDocument.getDocType, null, .{});
};
