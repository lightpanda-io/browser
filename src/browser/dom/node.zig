// Copyright (C) 2023-2024  Lightpanda (Selecy SAS)
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

const log = @import("../../log.zig");
const parser = @import("../netsurf.zig");
const generate = @import("../../runtime/generate.zig");

const Page = @import("../page.zig").Page;
const EventTarget = @import("event_target.zig").EventTarget;

// DOM
const Attr = @import("attribute.zig").Attr;
const CData = @import("character_data.zig");
const Element = @import("element.zig").Element;
const ElementUnion = @import("element.zig").Union;
const NodeList = @import("nodelist.zig").NodeList;
const Document = @import("document.zig").Document;
const DocumentType = @import("document_type.zig").DocumentType;
const DocumentFragment = @import("document_fragment.zig").DocumentFragment;
const HTMLCollection = @import("html_collection.zig").HTMLCollection;
const HTMLAllCollection = @import("html_collection.zig").HTMLAllCollection;
const HTMLCollectionIterator = @import("html_collection.zig").HTMLCollectionIterator;
const ShadowRoot = @import("shadow_root.zig").ShadowRoot;
const Walker = @import("walker.zig").WalkerDepthFirst;

// HTML
const HTML = @import("../html/html.zig");

// Node interfaces
pub const Interfaces = .{
    Attr,
    CData.CharacterData,
    CData.Interfaces,
    Element,
    Document,
    DocumentType,
    DocumentFragment,
    HTMLCollection,
    HTMLAllCollection,
    HTMLCollectionIterator,
    HTML.Interfaces,
};

pub const Union = generate.Union(Interfaces);

// Node implementation
pub const Node = struct {
    pub const Self = parser.Node;
    pub const prototype = *EventTarget;
    pub const subtype = .node;

    pub fn toInterface(node: *parser.Node) !Union {
        return switch (try parser.nodeType(node)) {
            .element => try Element.toInterfaceT(
                Union,
                @as(*parser.Element, @ptrCast(node)),
            ),
            .comment => .{ .Comment = @as(*parser.Comment, @ptrCast(node)) },
            .text => .{ .Text = @as(*parser.Text, @ptrCast(node)) },
            .cdata_section => .{ .CDATASection = @as(*parser.CDATASection, @ptrCast(node)) },
            .processing_instruction => .{ .ProcessingInstruction = @as(*parser.ProcessingInstruction, @ptrCast(node)) },
            .document => blk: {
                const doc: *parser.Document = @ptrCast(node);
                if (doc.is_html) {
                    break :blk .{ .HTMLDocument = @as(*parser.DocumentHTML, @ptrCast(node)) };
                }

                break :blk .{ .Document = doc };
            },
            .document_type => .{ .DocumentType = @as(*parser.DocumentType, @ptrCast(node)) },
            .attribute => .{ .Attr = @as(*parser.Attribute, @ptrCast(node)) },
            .document_fragment => .{ .DocumentFragment = @as(*parser.DocumentFragment, @ptrCast(node)) },
            else => @panic("node type not handled"), // TODO
        };
    }

    // class attributes

    pub const _ELEMENT_NODE = @intFromEnum(parser.NodeType.element);
    pub const _ATTRIBUTE_NODE = @intFromEnum(parser.NodeType.attribute);
    pub const _TEXT_NODE = @intFromEnum(parser.NodeType.text);
    pub const _CDATA_SECTION_NODE = @intFromEnum(parser.NodeType.cdata_section);
    pub const _PROCESSING_INSTRUCTION_NODE = @intFromEnum(parser.NodeType.processing_instruction);
    pub const _COMMENT_NODE = @intFromEnum(parser.NodeType.comment);
    pub const _DOCUMENT_NODE = @intFromEnum(parser.NodeType.document);
    pub const _DOCUMENT_TYPE_NODE = @intFromEnum(parser.NodeType.document_type);
    pub const _DOCUMENT_FRAGMENT_NODE = @intFromEnum(parser.NodeType.document_fragment);

    // These 3 are deprecated, but both Chrome and Firefox still expose them
    pub const _ENTITY_REFERENCE_NODE = @intFromEnum(parser.NodeType.entity_reference);
    pub const _ENTITY_NODE = @intFromEnum(parser.NodeType.entity);
    pub const _NOTATION_NODE = @intFromEnum(parser.NodeType.notation);

    pub const _DOCUMENT_POSITION_DISCONNECTED = @intFromEnum(parser.DocumentPosition.disconnected);
    pub const _DOCUMENT_POSITION_PRECEDING = @intFromEnum(parser.DocumentPosition.preceding);
    pub const _DOCUMENT_POSITION_FOLLOWING = @intFromEnum(parser.DocumentPosition.following);
    pub const _DOCUMENT_POSITION_CONTAINS = @intFromEnum(parser.DocumentPosition.contains);
    pub const _DOCUMENT_POSITION_CONTAINED_BY = @intFromEnum(parser.DocumentPosition.contained_by);
    pub const _DOCUMENT_POSITION_IMPLEMENTATION_SPECIFIC = @intFromEnum(parser.DocumentPosition.implementation_specific);

    // JS funcs
    // --------

    // Read-only attributes
    pub fn get_baseURI(_: *parser.Node, page: *Page) ![]const u8 {
        return page.url.raw;
    }

    pub fn get_firstChild(self: *parser.Node) !?Union {
        const res = try parser.nodeFirstChild(self);
        if (res == null) {
            return null;
        }
        return try Node.toInterface(res.?);
    }

    pub fn get_lastChild(self: *parser.Node) !?Union {
        const res = try parser.nodeLastChild(self);
        if (res == null) {
            return null;
        }
        return try Node.toInterface(res.?);
    }

    pub fn get_nextSibling(self: *parser.Node) !?Union {
        const res = try parser.nodeNextSibling(self);
        if (res == null) {
            return null;
        }
        return try Node.toInterface(res.?);
    }

    pub fn get_previousSibling(self: *parser.Node) !?Union {
        const res = try parser.nodePreviousSibling(self);
        if (res == null) {
            return null;
        }
        return try Node.toInterface(res.?);
    }

    pub fn get_parentNode(self: *parser.Node) !?Union {
        const res = try parser.nodeParentNode(self);
        if (res == null) {
            return null;
        }
        return try Node.toInterface(res.?);
    }

    pub fn get_parentElement(self: *parser.Node) !?ElementUnion {
        const res = try parser.nodeParentElement(self);
        if (res == null) {
            return null;
        }
        return try Element.toInterface(res.?);
    }

    pub fn get_nodeName(self: *parser.Node) ![]const u8 {
        return try parser.nodeName(self);
    }

    pub fn get_nodeType(self: *parser.Node) !u8 {
        return @intFromEnum(try parser.nodeType(self));
    }

    pub fn get_ownerDocument(self: *parser.Node) !?*parser.DocumentHTML {
        const res = try parser.nodeOwnerDocument(self);
        if (res == null) {
            return null;
        }
        return @as(*parser.DocumentHTML, @ptrCast(res.?));
    }

    pub fn get_isConnected(self: *parser.Node) !bool {
        var node = self;
        while (true) {
            const node_type = try parser.nodeType(node);
            if (node_type == .document) {
                return true;
            }

            if (try parser.nodeParentNode(node)) |parent| {
                // didn't find a document, but node has a parent, let's see
                // if it's connected;
                node = parent;
                continue;
            }

            if (node_type != .document_fragment) {
                // doesn't have a parent and isn't a document_fragment
                // can't be connected
                return false;
            }

            if (parser.documentFragmentGetHost(@ptrCast(node))) |host| {
                // node doesn't have a parent, but it's a document fragment
                // with a host. The host is like the parent, but we only want to
                // traverse up (or down) to it in specific cases, like isConnected.
                node = host;
                continue;
            }
            return false;
        }
    }

    // Read/Write attributes

    pub fn get_nodeValue(self: *parser.Node) !?[]const u8 {
        return try parser.nodeValue(self);
    }

    pub fn set_nodeValue(self: *parser.Node, data: []u8) !void {
        try parser.nodeSetValue(self, data);
    }

    pub fn get_textContent(self: *parser.Node) !?[]const u8 {
        return try parser.nodeTextContent(self);
    }

    pub fn set_textContent(self: *parser.Node, data: []u8) !void {
        return try parser.nodeSetTextContent(self, data);
    }

    // Methods

    pub fn _appendChild(self: *parser.Node, child: *parser.Node) !Union {
        const self_owner = try parser.nodeOwnerDocument(self);
        const child_owner = try parser.nodeOwnerDocument(child);

        // If the node to be inserted has a different ownerDocument than the parent node,
        // modern browsers automatically adopt the node and its descendants into
        // the parent's ownerDocument.
        // This process is known as adoption.
        // (7.1) https://dom.spec.whatwg.org/#concept-node-insert
        if (child_owner == null or (self_owner != null and child_owner.? != self_owner.?)) {
            const w = Walker{};
            var current = child;
            while (true) {
                current.owner = self_owner;
                current = try w.get_next(child, current) orelse break;
            }
        }

        // TODO: DocumentFragment special case
        const res = try parser.nodeAppendChild(self, child);
        return try Node.toInterface(res);
    }

    pub fn _cloneNode(self: *parser.Node, deep: ?bool) !Union {
        const clone = try parser.nodeCloneNode(self, deep orelse false);
        return try Node.toInterface(clone);
    }

    pub fn _compareDocumentPosition(self: *parser.Node, other: *parser.Node) !u32 {
        if (self == other) {
            return 0;
        }

        const docself = try parser.nodeOwnerDocument(self) orelse blk: {
            if (try parser.nodeType(self) == .document) {
                break :blk @as(*parser.Document, @ptrCast(self));
            }
            break :blk null;
        };
        const docother = try parser.nodeOwnerDocument(other) orelse blk: {
            if (try parser.nodeType(other) == .document) {
                break :blk @as(*parser.Document, @ptrCast(other));
            }
            break :blk null;
        };

        // Both are in different document.
        if (docself == null or docother == null or docself.? != docother.?) {
            return @intFromEnum(parser.DocumentPosition.disconnected) +
                @intFromEnum(parser.DocumentPosition.implementation_specific) +
                @intFromEnum(parser.DocumentPosition.preceding);
        }

        if (@intFromPtr(self) == @intFromPtr(docself.?)) {
            // if self is the document, and we already know other is in the
            // document, then other is contained by and following self.
            return @intFromEnum(parser.DocumentPosition.following) +
                @intFromEnum(parser.DocumentPosition.contained_by);
        }

        const rootself = try parser.nodeGetRootNode(self);
        const rootother = try parser.nodeGetRootNode(other);
        if (rootself != rootother) {
            return @intFromEnum(parser.DocumentPosition.disconnected) +
                @intFromEnum(parser.DocumentPosition.implementation_specific) +
                @intFromEnum(parser.DocumentPosition.preceding);
        }

        // TODO Both are in a different trees in the same document.

        const w = Walker{};
        var next: ?*parser.Node = null;

        // Is other a descendant of self?
        while (true) {
            next = try w.get_next(self, next) orelse break;
            if (other == next) {
                return @intFromEnum(parser.DocumentPosition.following) +
                    @intFromEnum(parser.DocumentPosition.contained_by);
            }
        }

        // Is self a descendant of other?
        next = null;
        while (true) {
            next = try w.get_next(other, next) orelse break;
            if (self == next) {
                return @intFromEnum(parser.DocumentPosition.contains) +
                    @intFromEnum(parser.DocumentPosition.preceding);
            }
        }

        next = null;
        while (true) {
            next = try w.get_next(parser.documentToNode(docself.?), next) orelse break;
            if (other == next) {
                // other precedes self.
                return @intFromEnum(parser.DocumentPosition.preceding);
            }
            if (self == next) {
                // other follows self.
                return @intFromEnum(parser.DocumentPosition.following);
            }
        }

        return 0;
    }

    pub fn _contains(self: *parser.Node, other: *parser.Node) !bool {
        return try parser.nodeContains(self, other);
    }

    // Returns itself or ancestor object inheriting from Node.
    // - An Element inside a standard web page will return an HTMLDocument object representing the entire page (or <iframe>).
    // - An Element inside a shadow DOM will return the associated ShadowRoot.
    // - An Element that is not attached to a document or a shadow tree will return the root of the DOM tree it belongs to
    const GetRootNodeResult = union(enum) {
        shadow_root: *ShadowRoot,
        node: Union,
    };
    pub fn _getRootNode(self: *parser.Node, options: ?struct { composed: bool = false }, page: *Page) !GetRootNodeResult {
        if (options) |options_| if (options_.composed) {
            log.warn(.web_api, "not implemented", .{ .feature = "getRootNode composed" });
        };

        const root = try parser.nodeGetRootNode(self);
        if (page.getNodeState(root)) |state| {
            if (state.shadow_root) |sr| {
                return .{ .shadow_root = sr };
            }
        }

        return .{ .node = try Node.toInterface(root) };
    }

    pub fn _hasChildNodes(self: *parser.Node) !bool {
        return try parser.nodeHasChildNodes(self);
    }

    pub fn get_childNodes(self: *parser.Node, page: *Page) !NodeList {
        const allocator = page.arena;
        var list: NodeList = .{};

        var n = try parser.nodeFirstChild(self) orelse return list;
        while (true) {
            try list.append(allocator, n);
            n = try parser.nodeNextSibling(n) orelse return list;
        }
    }

    pub fn _insertBefore(self: *parser.Node, new_node: *parser.Node, ref_node_: ?*parser.Node) !Union {
        if (ref_node_ == null) {
            return _appendChild(self, new_node);
        }

        const self_owner = try parser.nodeOwnerDocument(self);
        const new_node_owner = try parser.nodeOwnerDocument(new_node);

        // If the node to be inserted has a different ownerDocument than the parent node,
        // modern browsers automatically adopt the node and its descendants into
        // the parent's ownerDocument.
        // This process is known as adoption.
        // (7.1) https://dom.spec.whatwg.org/#concept-node-insert
        if (new_node_owner == null or (self_owner != null and new_node_owner.? != self_owner.?)) {
            const w = Walker{};
            var current = new_node;
            while (true) {
                current.owner = self_owner;
                current = try w.get_next(new_node, current) orelse break;
            }
        }

        return Node.toInterface(try parser.nodeInsertBefore(self, new_node, ref_node_.?));
    }

    pub fn _isDefaultNamespace(self: *parser.Node, namespace: ?[]const u8) !bool {
        return try parser.nodeIsDefaultNamespace(self, namespace);
    }

    pub fn _isEqualNode(self: *parser.Node, other: *parser.Node) !bool {
        // TODO: other is not an optional parameter, but can be null.
        return try parser.nodeIsEqualNode(self, other);
    }

    pub fn _isSameNode(self: *parser.Node, other: *parser.Node) !bool {
        // TODO: other is not an optional parameter, but can be null.
        // NOTE: there is no need to use isSameNode(); instead use the === strict equality operator
        return try parser.nodeIsSameNode(self, other);
    }

    pub fn _lookupPrefix(self: *parser.Node, namespace: ?[]const u8) !?[]const u8 {
        // TODO: other is not an optional parameter, but can be null.
        if (namespace == null) {
            return null;
        }
        if (std.mem.eql(u8, namespace.?, "")) {
            return null;
        }
        return try parser.nodeLookupPrefix(self, namespace.?);
    }

    pub fn _lookupNamespaceURI(self: *parser.Node, prefix: ?[]const u8) !?[]const u8 {
        // TODO: other is not an optional parameter, but can be null.
        return try parser.nodeLookupNamespaceURI(self, prefix);
    }

    pub fn _normalize(self: *parser.Node) !void {
        return try parser.nodeNormalize(self);
    }

    pub fn _removeChild(self: *parser.Node, child: *parser.Node) !Union {
        const res = try parser.nodeRemoveChild(self, child);
        return try Node.toInterface(res);
    }

    pub fn _replaceChild(self: *parser.Node, new_child: *parser.Node, old_child: *parser.Node) !Union {
        const res = try parser.nodeReplaceChild(self, new_child, old_child);
        return try Node.toInterface(res);
    }

    // Check if the hierarchy node tree constraints are respected.
    // For now, it checks only if new nodes are not self.
    // TODO implements the others contraints.
    // see https://dom.spec.whatwg.org/#concept-node-tree
    pub fn hierarchy(self: *parser.Node, nodes: []const NodeOrText) bool {
        for (nodes) |n| {
            if (n.is(self)) {
                return false;
            }
        }
        return true;
    }

    pub fn prepend(self: *parser.Node, nodes: []const NodeOrText) !void {
        if (nodes.len == 0) {
            return;
        }

        // check hierarchy
        if (!hierarchy(self, nodes)) {
            return parser.DOMError.HierarchyRequest;
        }

        const doc = (try parser.nodeOwnerDocument(self)) orelse return;

        if (try parser.nodeFirstChild(self)) |first| {
            for (nodes) |node| {
                _ = try parser.nodeInsertBefore(self, try node.toNode(doc), first);
            }
            return;
        }

        for (nodes) |node| {
            _ = try parser.nodeAppendChild(self, try node.toNode(doc));
        }
    }

    pub fn append(self: *parser.Node, nodes: []const NodeOrText) !void {
        if (nodes.len == 0) {
            return;
        }

        // check hierarchy
        if (!hierarchy(self, nodes)) {
            return parser.DOMError.HierarchyRequest;
        }

        const doc = (try parser.nodeOwnerDocument(self)) orelse return;
        for (nodes) |node| {
            _ = try parser.nodeAppendChild(self, try node.toNode(doc));
        }
    }

    pub fn replaceChildren(self: *parser.Node, nodes: []const NodeOrText) !void {
        if (nodes.len == 0) {
            return;
        }

        // check hierarchy
        if (!hierarchy(self, nodes)) {
            return parser.DOMError.HierarchyRequest;
        }

        // remove existing children
        try removeChildren(self);

        const doc = (try parser.nodeOwnerDocument(self)) orelse return;
        // add new children
        for (nodes) |node| {
            _ = try parser.nodeAppendChild(self, try node.toNode(doc));
        }
    }

    pub fn removeChildren(self: *parser.Node) !void {
        if (!try parser.nodeHasChildNodes(self)) return;

        const children = try parser.nodeGetChildNodes(self);
        const ln = try parser.nodeListLength(children);
        var i: u32 = 0;
        while (i < ln) {
            defer i += 1;
            // we always retrieve the 0 index child on purpose: libdom nodelist
            // are dynamic. So the next child to remove is always as pos 0.
            const child = try parser.nodeListItem(children, 0) orelse continue;
            _ = try parser.nodeRemoveChild(self, child);
        }
    }

    pub fn before(self: *parser.Node, nodes: []const NodeOrText) !void {
        const parent = try parser.nodeParentNode(self) orelse return;
        const doc = (try parser.nodeOwnerDocument(parent)) orelse return;

        var sibling: ?*parser.Node = self;
        // have to find the first sibling that isn't in nodes
        CHECK: while (sibling) |s| {
            for (nodes) |n| {
                if (n.is(s)) {
                    sibling = try parser.nodePreviousSibling(s);
                    continue :CHECK;
                }
            }
            break;
        }

        if (sibling == null) {
            sibling = try parser.nodeFirstChild(parent);
        }

        if (sibling) |ref_node| {
            for (nodes) |node| {
                _ = try parser.nodeInsertBefore(parent, try node.toNode(doc), ref_node);
            }
            return;
        }

        return Node.prepend(self, nodes);
    }

    pub fn after(self: *parser.Node, nodes: []const NodeOrText) !void {
        const parent = try parser.nodeParentNode(self) orelse return;
        const doc = (try parser.nodeOwnerDocument(parent)) orelse return;

        // have to find the first sibling that isn't in nodes
        var sibling = try parser.nodeNextSibling(self);
        CHECK: while (sibling) |s| {
            for (nodes) |n| {
                if (n.is(s)) {
                    sibling = try parser.nodeNextSibling(s);
                    continue :CHECK;
                }
            }
            break;
        }

        if (sibling) |ref_node| {
            for (nodes) |node| {
                _ = try parser.nodeInsertBefore(parent, try node.toNode(doc), ref_node);
            }
            return;
        }

        for (nodes) |node| {
            _ = try parser.nodeAppendChild(parent, try node.toNode(doc));
        }
    }

    // A lot of functions take either a node or text input.
    // The text input is to be converted into a Text node.
    pub const NodeOrText = union(enum) {
        text: []const u8,
        node: *parser.Node,

        fn toNode(self: NodeOrText, doc: *parser.Document) !*parser.Node {
            return switch (self) {
                .node => |n| n,
                .text => |txt| @ptrCast(@alignCast(try parser.documentCreateTextNode(doc, txt))),
            };
        }

        // Whether the node represented by the NodeOrText is the same as the
        // given Node. Always false for text values as these represent as-of-yet
        // created Text nodes.
        fn is(self: NodeOrText, other: *parser.Node) bool {
            return switch (self) {
                .text => false,
                .node => |n| n == other,
            };
        }
    };
};

const testing = @import("../../testing.zig");
test "Browser: DOM.Node" {
    try testing.htmlRunner("dom/node.html");
    try testing.htmlRunner("dom/node_owner.html");
}
