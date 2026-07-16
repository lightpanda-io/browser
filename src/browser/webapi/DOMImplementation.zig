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
const DocumentType = @import("DocumentType.zig");

const DOMImplementation = @This();

// The document this implementation object belongs to: nodes created through
// it are owned by that document, not necessarily the frame's main document.
_document: *Document,

pub fn createDocumentType(self: *const DOMImplementation, qualified_name: []const u8, public_id: ?[]const u8, system_id: ?[]const u8, frame: *Frame) !*DocumentType {
    // Per spec, qualifiedName must match the doctype name production: any
    // characters except ASCII whitespace or '>'.
    for (qualified_name) |c| {
        switch (c) {
            '\t', '\n', 0x0C, '\r', ' ', '>' => return error.InvalidCharacterError,
            else => {},
        }
    }

    const doctype = try DocumentType.init(qualified_name, public_id, system_id, frame);
    if (self._document != frame.document) {
        try frame.setNodeOwnerDocument(doctype.asNode(), self._document);
    }
    return doctype;
}

pub fn createHTMLDocument(_: *const DOMImplementation, title: ?js.NullableString, frame: *Frame) !*Document {
    const document = (try frame._factory.document(Node.Document.HTMLDocument{ ._proto = undefined })).asDocument();
    document._ready_state = .complete;
    document._url = "about:blank";
    document._charset = "UTF-8";

    {
        const doctype = try frame._factory.node(DocumentType{
            ._proto = undefined,
            ._name = "html",
            ._public_id = "",
            ._system_id = "",
        });
        _ = try document.asNode().appendChild(doctype.asNode(), frame);
    }

    const html_node = try Frame.node_factory.createElementNS(frame, .html, "html", null);
    _ = try document.asNode().appendChild(html_node, frame);

    const head_node = try Frame.node_factory.createElementNS(frame, .html, "head", null);
    _ = try html_node.appendChild(head_node, frame);

    if (title) |t| {
        const title_node = try Frame.node_factory.createElementNS(frame, .html, "title", null);
        _ = try head_node.appendChild(title_node, frame);
        const text_node = try Frame.node_factory.createTextNode(frame, t.value);
        _ = try title_node.appendChild(text_node, frame);
    }

    const body_node = try Frame.node_factory.createElementNS(frame, .html, "body", null);
    _ = try html_node.appendChild(body_node, frame);

    return document;
}

pub fn createDocument(_: *const DOMImplementation, namespace_nullable: js.Nullable([]const u8), qualified_name_: js.Value, doctype: ?*DocumentType, frame: *Frame) !*Document {
    // Both namespace (nullable) and qualifiedName are required arguments.
    const namespace_ = namespace_nullable.value;

    // Per Web IDL, qualifiedName is [LegacyNullToEmptyString]: null becomes
    // the empty string, while undefined stringifies to "undefined". The raw
    // js.Value keeps that distinction.
    const qname: []const u8 = blk: {
        if (qualified_name_.isNull()) {
            break :blk "";
        }
        break :blk try qualified_name_.toStringSlice();
    };

    if (qname.len > 0) {
        _ = try Document.validateAndExtract(namespace_, qname, .element);
    }

    // Create XML Document
    const document = (try frame._factory.document(Node.Document.XMLDocument{ ._proto = undefined })).asDocument();
    document._url = "about:blank";
    document._charset = "UTF-8";
    // Per spec the content type depends on the requested namespace.
    document._content_type = blk: {
        const ns = namespace_ orelse break :blk "application/xml";
        if (std.mem.eql(u8, ns, "http://www.w3.org/1999/xhtml")) break :blk "application/xhtml+xml";
        if (std.mem.eql(u8, ns, "http://www.w3.org/2000/svg")) break :blk "image/svg+xml";
        break :blk "application/xml";
    };

    // Append doctype if provided
    if (doctype) |dt| {
        _ = try document.asNode().appendChild(dt.asNode(), frame);
    }

    // Create and append root element if qualified_name provided
    if (qname.len > 0) {
        const namespace = Node.Element.Namespace.parse(namespace_);
        const root = try Frame.node_factory.createElementNS(frame, namespace, qname, null);

        // Store the original URI for unknown namespaces so namespaceURI and
        // lookupNamespaceURI can return it (mirrors Document.createElementNS).
        if (namespace == .unknown) {
            if (namespace_) |uri| {
                const duped = try frame.dupeString(uri);
                try frame._element_namespace_uris.put(frame.arena, root.as(Node.Element), duped);
            }
        }

        _ = try document.asNode().appendChild(root, frame);
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
    };

    pub const createDocumentType = bridge.function(DOMImplementation.createDocumentType, .{});
    pub const createDocument = bridge.function(DOMImplementation.createDocument, .{});
    pub const createHTMLDocument = bridge.function(DOMImplementation.createHTMLDocument, .{});
    pub const hasFeature = bridge.function(DOMImplementation.hasFeature, .{});
};

const testing = @import("../../testing.zig");
test "WebApi: DOMImplementation" {
    try testing.htmlRunner("domimplementation.html", .{});
}
