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

const Frame = @import("../Frame.zig");
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
    const document_element = self._proto.getDocumentElement() orelse return null;
    return findBodyForDoc(document_element);
}

pub fn setBody(self: *HTMLDocument, html: []const u8, frame: *Frame) !void {
    const document_element = self._proto.getDocumentElement() orelse return error.HierarchyError;

    // Build a fresh <body> holding the parsed HTML as its children. Fragment
    // parsing strips any <html>/<body>/<head> wrappers the author included.
    const new_body_node = try frame.createElementNS(.html, "body", null);
    if (html.len > 0) {
        try frame.parseHtmlAsChildren(new_body_node, html);
    }

    const document_node = document_element.asNode();
    if (findBodyForDoc(document_element)) |current| {
        _ = try document_node.replaceChild(new_body_node, current.asNode(), frame);
    } else {
        _ = try document_node.appendChild(new_body_node, frame);
    }
}

fn findBodyForDoc(document_element: *Element) ?*Element.Html.Body {
    var child = document_element.asNode().firstChild();
    while (child) |node| {
        if (node.is(Element.Html.Body)) |body| {
            return body;
        }
        child = node.nextSibling();
    }
    return null;
}

pub fn getTitle(self: *HTMLDocument, frame: *Frame) ![]const u8 {
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

    var buf = std.Io.Writer.Allocating.init(frame.call_arena);
    try title_element.asNode().getTextContent(&buf.writer);
    const text = buf.written();

    if (text.len == 0) {
        return "";
    }

    var started = false;
    var in_whitespace = false;
    var result: std.ArrayList(u8) = .empty;
    try result.ensureTotalCapacity(frame.call_arena, text.len);

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

pub fn setTitle(self: *HTMLDocument, title: []const u8, frame: *Frame) !void {
    const head = self.getHead() orelse return;

    // Find existing title element in head
    var it = head.asNode().childrenIterator();
    while (it.next()) |node| {
        if (node.is(Element.Html.Title)) |title_element| {
            // Replace children, but don't create text node for empty string
            if (title.len == 0) {
                return title_element.asElement().replaceChildren(&.{}, frame);
            } else {
                return title_element.asElement().replaceChildren(&.{.{ .text = title }}, frame);
            }
        }
    }

    // No title element found, create one
    const title_node = try frame.createElementNS(.html, "title", null);
    const title_element = title_node.as(Element);

    // Only add text if non-empty
    if (title.len > 0) {
        try title_element.replaceChildren(&.{.{ .text = title }}, frame);
    }

    _ = try head.asNode().appendChild(title_node, frame);
}

pub fn getImages(self: *HTMLDocument, frame: *Frame) !collections.NodeLive(.tag) {
    return collections.NodeLive(.tag).init(self.asNode(), .img, frame);
}

pub fn getScripts(self: *HTMLDocument, frame: *Frame) !collections.NodeLive(.tag) {
    return collections.NodeLive(.tag).init(self.asNode(), .script, frame);
}

pub fn getLinks(self: *HTMLDocument, frame: *Frame) !collections.NodeLive(.links) {
    return collections.NodeLive(.links).init(self.asNode(), {}, frame);
}

pub fn getAnchors(self: *HTMLDocument, frame: *Frame) !collections.NodeLive(.anchors) {
    return collections.NodeLive(.anchors).init(self.asNode(), {}, frame);
}

pub fn getForms(self: *HTMLDocument, frame: *Frame) !collections.NodeLive(.tag) {
    return collections.NodeLive(.tag).init(self.asNode(), .form, frame);
}

pub fn getEmbeds(self: *HTMLDocument, frame: *Frame) !collections.NodeLive(.tag) {
    return collections.NodeLive(.tag).init(self.asNode(), .embed, frame);
}

pub fn getApplets(_: *const HTMLDocument) collections.HTMLCollection {
    return .{ ._data = .empty };
}

pub fn getCurrentScript(self: *const HTMLDocument) ?*Element.Html.Script {
    return self._proto._current_script;
}

pub fn getLocation(self: *const HTMLDocument) ?*@import("Location.zig") {
    const frame = self._proto._frame orelse return null;
    return frame.window._location;
}

pub fn setLocation(self: *HTMLDocument, url: [:0]const u8, frame: *Frame) !void {
    return frame.scheduleNavigation(url, .{ .reason = .script, .kind = .{ .push = null } }, .{ .script = self._proto._frame });
}

pub fn getDir(self: *HTMLDocument) []const u8 {
    const el = self._proto.getDocumentElement() orelse return "";
    const html = el.is(Element.Html) orelse return "";
    return html.getDir();
}

pub fn setDir(self: *HTMLDocument, value: []const u8, frame: *Frame) !void {
    const el = self._proto.getDocumentElement() orelse return;
    const html = el.is(Element.Html) orelse return;
    try html.setDir(value, frame);
}

pub fn getLang(self: *HTMLDocument) []const u8 {
    const el = self._proto.getDocumentElement() orelse return "";
    const html = el.is(Element.Html) orelse return "";
    return html.getLang();
}

pub fn setLang(self: *HTMLDocument, value: []const u8, frame: *Frame) !void {
    const el = self._proto.getDocumentElement() orelse return;
    const html = el.is(Element.Html) orelse return;
    try html.setLang(value, frame);
}

pub fn getAll(self: *HTMLDocument, frame: *Frame) !*collections.HTMLAllCollection {
    return frame._factory.create(collections.HTMLAllCollection.init(self.asNode(), frame));
}

pub fn getCookie(_: *HTMLDocument, frame: *Frame) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    try frame._session.cookie_jar.forRequest(frame.url, buf.writer(frame.call_arena), .{
        .is_http = false,
        .is_navigation = true,
    });
    return buf.items;
}

pub fn setCookie(_: *HTMLDocument, cookie_str: []const u8, frame: *Frame) ![]const u8 {
    // we use the cookie jar's allocator to parse the cookie because it
    // outlives the frame's arena.
    const Cookie = @import("storage/Cookie.zig");
    const c = Cookie.parse(frame._session.cookie_jar.allocator, frame.url, cookie_str) catch {
        // Invalid cookies should be silently ignored, not throw errors
        return "";
    };
    errdefer c.deinit();
    if (c.http_only) {
        c.deinit();
        return ""; // HttpOnly cookies cannot be set from JS
    }
    try frame._session.cookie_jar.add(c, std.time.timestamp(), false);
    return cookie_str;
}

pub fn getDocType(self: *HTMLDocument, frame: *Frame) !*DocumentType {
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

    self._document_type = try frame._factory.node(DocumentType{
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
    fn _constructor(frame: *Frame) !*HTMLDocument {
        return frame._factory.document(HTMLDocument{
            ._proto = undefined,
        });
    }

    pub const dir = bridge.accessor(HTMLDocument.getDir, HTMLDocument.setDir, .{});
    pub const head = bridge.accessor(HTMLDocument.getHead, null, .{});
    pub const body = bridge.accessor(HTMLDocument.getBody, HTMLDocument.setBody, .{ .dom_exception = true });
    pub const lang = bridge.accessor(HTMLDocument.getLang, HTMLDocument.setLang, .{});
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
