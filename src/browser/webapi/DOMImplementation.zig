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
const Page = @import("../Page.zig");
const Node = @import("Node.zig");
const Document = @import("Document.zig");
const HTMLDocument = @import("HTMLDocument.zig");
const DocumentType = @import("DocumentType.zig");

const DOMImplementation = @This();

pub fn createDocumentType(_: *const DOMImplementation, qualified_name: []const u8, public_id: ?[]const u8, system_id: ?[]const u8, page: *Page) !*DocumentType {
    const name = try page.dupeString(qualified_name);
    // Firefox converts null to the string "null", not empty string
    const pub_id = if (public_id) |p| try page.dupeString(p) else "null";
    const sys_id = if (system_id) |s| try page.dupeString(s) else "null";

    const doctype = try page._factory.node(DocumentType{
        ._proto = undefined,
        ._name = name,
        ._public_id = pub_id,
        ._system_id = sys_id,
    });

    return doctype;
}

pub fn createHTMLDocument(_: *const DOMImplementation, title: ?[]const u8, page: *Page) !*Document {
    const document = (try page._factory.document(Node.Document.HTMLDocument{ ._proto = undefined })).asDocument();
    document._ready_state = .complete;

    {
        const doctype = try page._factory.node(DocumentType{
            ._proto = undefined,
            ._name = "html",
            ._public_id = "",
            ._system_id = "",
        });
        _ = try document.asNode().appendChild(doctype.asNode(), page);
    }

    const html_node = try page.createElement(null, "html", null);
    _ = try document.asNode().appendChild(html_node, page);

    const head_node = try page.createElement(null, "head", null);
    _ = try html_node.appendChild(head_node, page);

    if (title) |t| {
        const title_node = try page.createElement(null, "title", null);
        _ = try head_node.appendChild(title_node, page);
        const text_node = try page.createTextNode(t);
        _ = try title_node.appendChild(text_node, page);
    }

    const body_node = try page.createElement(null, "body", null);
    _ = try html_node.appendChild(body_node, page);

    return document;
}

pub fn createDocument(_: *const DOMImplementation, namespace: ?[]const u8, qualified_name: ?[]const u8, doctype: ?*DocumentType, page: *Page) !*Document {
    // Create XML Document
    const document = (try page._factory.document(Node.Document.XMLDocument{ ._proto = undefined })).asDocument();

    // Append doctype if provided
    if (doctype) |dt| {
        _ = try document.asNode().appendChild(dt.asNode(), page);
    }

    // Create and append root element if qualified_name provided
    if (qualified_name) |qname| {
        if (qname.len > 0) {
            const root = try page.createElement(namespace, qname, null);
            _ = try document.asNode().appendChild(root, page);
        }
    }

    return document;
}

pub fn hasFeature(_: *const DOMImplementation, _: ?[]const u8, _: ?[]const u8) bool {
    // Modern DOM spec says this should always return true
    // This method is deprecated and kept for compatibility only
    return true;
}

pub fn className(_: *const DOMImplementation) []const u8 {
    return "[object DOMImplementation]";
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(DOMImplementation);

    pub const Meta = struct {
        pub const name = "DOMImplementation";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
        pub const empty_with_no_proto = true;
    };

    pub const createDocumentType = bridge.function(DOMImplementation.createDocumentType, .{ .dom_exception = true });
    pub const createDocument = bridge.function(DOMImplementation.createDocument, .{});
    pub const createHTMLDocument = bridge.function(DOMImplementation.createHTMLDocument, .{});
    pub const hasFeature = bridge.function(DOMImplementation.hasFeature, .{});

    pub const toString = bridge.function(_toString, .{});
    fn _toString(_: *const DOMImplementation) []const u8 {
        return "[object DOMImplementation]";
    }
};

const testing = @import("../../testing.zig");
test "WebApi: DOMImplementation" {
    try testing.htmlRunner("domimplementation.html", .{});
}
