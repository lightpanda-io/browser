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
const DocumentType = @import("DocumentType.zig");

const DOMImplementation = @This();
_pad: bool = false,

pub fn createDocumentType(_: *const DOMImplementation, qualified_name: []const u8, public_id: ?[]const u8, system_id: ?[]const u8, page: *Page) !*DocumentType {
    return DocumentType.init(qualified_name, public_id, system_id, page);
}

pub fn createHTMLDocument(_: *const DOMImplementation, title: ?js.NullableString, page: *Page) !*Document {
    const document = (try page._factory.document(Node.Document.HTMLDocument{ ._proto = undefined })).asDocument();
    document._ready_state = .complete;
    document._url = "about:blank";

    {
        const doctype = try page._factory.node(DocumentType{
            ._proto = undefined,
            ._name = "html",
            ._public_id = "",
            ._system_id = "",
        });
        _ = try document.asNode().appendChild(doctype.asNode(), page);
    }

    const html_node = try page.createElementNS(.html, "html", null);
    _ = try document.asNode().appendChild(html_node, page);

    const head_node = try page.createElementNS(.html, "head", null);
    _ = try html_node.appendChild(head_node, page);

    if (title) |t| {
        const title_node = try page.createElementNS(.html, "title", null);
        _ = try head_node.appendChild(title_node, page);
        const text_node = try page.createTextNode(t.value);
        _ = try title_node.appendChild(text_node, page);
    }

    const body_node = try page.createElementNS(.html, "body", null);
    _ = try html_node.appendChild(body_node, page);

    return document;
}

pub fn createDocument(_: *const DOMImplementation, namespace_: ?[]const u8, qualified_name: ?[]const u8, doctype: ?*DocumentType, page: *Page) !*Document {
    // Create XML Document
    const document = (try page._factory.document(Node.Document.XMLDocument{ ._proto = undefined })).asDocument();
    document._url = "about:blank";

    // Append doctype if provided
    if (doctype) |dt| {
        _ = try document.asNode().appendChild(dt.asNode(), page);
    }

    // Create and append root element if qualified_name provided
    if (qualified_name) |qname| {
        if (qname.len > 0) {
            const namespace = if (namespace_) |ns| Node.Element.Namespace.parse(ns) else .xml;
            const root = try page.createElementNS(namespace, qname, null);
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

pub const JsApi = struct {
    pub const bridge = js.Bridge(DOMImplementation);

    pub const Meta = struct {
        pub const name = "DOMImplementation";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
        pub const empty_with_no_proto = true;
        pub const enumerable = false;
    };

    pub const createDocumentType = bridge.function(DOMImplementation.createDocumentType, .{ .dom_exception = true });
    pub const createDocument = bridge.function(DOMImplementation.createDocument, .{});
    pub const createHTMLDocument = bridge.function(DOMImplementation.createHTMLDocument, .{});
    pub const hasFeature = bridge.function(DOMImplementation.hasFeature, .{});
};

const testing = @import("../../testing.zig");
test "WebApi: DOMImplementation" {
    try testing.htmlRunner("domimplementation.html", .{});
}
