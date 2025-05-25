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

const SessionState = @import("../env.zig").SessionState;
const EventTarget = @import("event_target.zig").EventTarget;

// DOM
const Attr = @import("attribute.zig").Attr;
const CData = @import("character_data.zig");
const Element = @import("element.zig").Element;
const NodeList = @import("nodelist.zig").NodeList;
const Document = @import("document.zig").Document;
const DocumentType = @import("document_type.zig").DocumentType;
const DocumentFragment = @import("document_fragment.zig").DocumentFragment;
const HTMLCollection = @import("html_collection.zig").HTMLCollection;
const HTMLAllCollection = @import("html_collection.zig").HTMLAllCollection;
const HTMLCollectionIterator = @import("html_collection.zig").HTMLCollectionIterator;
const Walker = @import("walker.zig").WalkerDepthFirst;

// HTML
const HTML = @import("../html/html.zig");
const HTMLElem = @import("../html/elements.zig");

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
            .element => try HTMLElem.toInterface(
                Union,
                @as(*parser.Element, @ptrCast(node)),
            ),
            .comment => .{ .Comment = @as(*parser.Comment, @ptrCast(node)) },
            .text => .{ .Text = @as(*parser.Text, @ptrCast(node)) },
            .cdata_section => .{ .CDATASection = @as(*parser.CDATASection, @ptrCast(node)) },
            .processing_instruction => .{ .ProcessingInstruction = @as(*parser.ProcessingInstruction, @ptrCast(node)) },
            .document => .{ .HTMLDocument = @as(*parser.DocumentHTML, @ptrCast(node)) },
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

    // JS funcs
    // --------

    // Read-only attributes

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

    pub fn get_parentElement(self: *parser.Node) !?HTMLElem.Union {
        const res = try parser.nodeParentElement(self);
        if (res == null) {
            return null;
        }
        return try HTMLElem.toInterface(HTMLElem.Union, @as(*parser.Element, @ptrCast(res.?)));
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
        // TODO: handle Shadow DOM
        if (try parser.nodeType(self) == .document) {
            return true;
        }
        return try Node.get_parentNode(self) != null;
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
        // TODO: DocumentFragment special case
        const res = try parser.nodeAppendChild(self, child);
        return try Node.toInterface(res);
    }

    pub fn _cloneNode(self: *parser.Node, deep: ?bool) !Union {
        const clone = try parser.nodeCloneNode(self, deep orelse false);
        return try Node.toInterface(clone);
    }

    pub fn _compareDocumentPosition(self: *parser.Node, other: *parser.Node) !u32 {
        if (self == other) return 0;

        const docself = try parser.nodeOwnerDocument(self);
        const docother = try parser.nodeOwnerDocument(other);

        // Both are in different document.
        if (docself == null or docother == null or docother.? != docself.?) {
            return @intFromEnum(parser.DocumentPosition.disconnected);
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
    pub fn _getRootNode(self: *parser.Node, options: ?struct { composed: bool = false }) !Union {
        if (options) |options_| if (options_.composed) {
            log.warn(.node, "not implemented", .{ .feature = "getRootNode composed" });
        };
        return try Node.toInterface(try parser.nodeGetRootNode(self));
    }

    pub fn _hasChildNodes(self: *parser.Node) !bool {
        return try parser.nodeHasChildNodes(self);
    }

    pub fn get_childNodes(self: *parser.Node, state: *SessionState) !NodeList {
        const allocator = state.arena;
        var list: NodeList = .{};

        var n = try parser.nodeFirstChild(self) orelse return list;
        while (true) {
            try list.append(allocator, n);
            n = try parser.nodeNextSibling(n) orelse return list;
        }
    }

    pub fn _insertBefore(self: *parser.Node, new_node: *parser.Node, ref_node: *parser.Node) !*parser.Node {
        return try parser.nodeInsertBefore(self, new_node, ref_node);
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
                .text => |txt| @ptrCast(try parser.documentCreateTextNode(doc, txt)),
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
test "Browser.DOM.node" {
    var runner = try testing.jsRunner(testing.tracking_allocator, .{});
    defer runner.deinit();

    {
        var err_out: ?[]const u8 = null;
        try runner.exec(
            \\ function trimAndReplace(str) {
            \\   str = str.replace(/(\r\n|\n|\r)/gm,'');
            \\   str = str.replace(/\s+/g, ' ');
            \\   str = str.trim();
            \\   return str;
            \\ }
        , "trimAndReplace", &err_out);
    }

    try runner.testCases(&.{
        .{ "document.body.compareDocumentPosition(document.firstChild); ", "10" },
        .{ "document.getElementById(\"para-empty\").compareDocumentPosition(document.getElementById(\"content\"));", "10" },
        .{ "document.getElementById(\"content\").compareDocumentPosition(document.getElementById(\"para-empty\"));", "20" },
        .{ "document.getElementById(\"link\").compareDocumentPosition(document.getElementById(\"link\"));", "0" },
        .{ "document.getElementById(\"para-empty\").compareDocumentPosition(document.getElementById(\"link\"));", "2" },
        .{ "document.getElementById(\"link\").compareDocumentPosition(document.getElementById(\"para-empty\"));", "4" },
    }, .{});

    try runner.testCases(&.{
        .{ "document.getElementById('content').getRootNode().__proto__.constructor.name", "HTMLDocument" },
    }, .{});

    try runner.testCases(&.{
        // for next test cases
        .{ "let content = document.getElementById('content')", "undefined" },
        .{ "let link = document.getElementById('link')", "undefined" },
        .{ "let first_child = content.firstChild.nextSibling", "undefined" }, // nextSibling because of line return \n

        .{ "let body_first_child = document.body.firstChild", "undefined" },
        .{ "body_first_child.localName", "div" },
        .{ "body_first_child.__proto__.constructor.name", "HTMLDivElement" },
        .{ "document.getElementById('para-empty').firstChild.firstChild", "null" },
    }, .{});

    try runner.testCases(&.{
        .{ "let last_child = content.lastChild.previousSibling", "undefined" }, // previousSibling because of line return \n
        .{ "last_child.__proto__.constructor.name", "Comment" },
    }, .{});

    try runner.testCases(&.{
        .{ "let next_sibling = link.nextSibling.nextSibling", "undefined" },
        .{ "next_sibling.localName", "p" },
        .{ "next_sibling.__proto__.constructor.name", "HTMLParagraphElement" },
        .{ "content.nextSibling.nextSibling", "null" },
    }, .{});

    try runner.testCases(&.{
        .{ "let prev_sibling = document.getElementById('para-empty').previousSibling.previousSibling", "undefined" },
        .{ "prev_sibling.localName", "a" },
        .{ "prev_sibling.__proto__.constructor.name", "HTMLAnchorElement" },
        .{ "content.previousSibling", "null" },
    }, .{});

    try runner.testCases(&.{
        .{ "let parent = document.getElementById('para').parentElement", "undefined" },
        .{ "parent.localName", "div" },
        .{ "parent.__proto__.constructor.name", "HTMLDivElement" },
        .{ "let h = content.parentElement.parentElement", "undefined" },
        .{ "h.parentElement", "null" },
        .{ "h.parentNode.__proto__.constructor.name", "HTMLDocument" },
    }, .{});

    try runner.testCases(&.{
        .{ "first_child.nodeName === 'A'", "true" },
        .{ "link.firstChild.nodeName === '#text'", "true" },
        .{ "last_child.nodeName === '#comment'", "true" },
        .{ "document.nodeName === '#document'", "true" },
    }, .{});

    try runner.testCases(&.{
        .{ "first_child.nodeType === 1", "true" },
        .{ "link.firstChild.nodeType === 3", "true" },
        .{ "last_child.nodeType === 8", "true" },
        .{ "document.nodeType === 9", "true" },
    }, .{});

    try runner.testCases(&.{
        .{ "let owner = content.ownerDocument", "undefined" },
        .{ "owner.__proto__.constructor.name", "HTMLDocument" },
        .{ "document.ownerDocument", "null" },
        .{ "let owner2 = document.createElement('div').ownerDocument", "undefined" },
        .{ "owner2.__proto__.constructor.name", "HTMLDocument" },
    }, .{});

    try runner.testCases(&.{
        .{ "content.isConnected", "true" },
        .{ "document.isConnected", "true" },
        .{ "document.createElement('div').isConnected", "false" },
    }, .{});

    try runner.testCases(&.{
        .{ "last_child.nodeValue === 'comment'", "true" },
        .{ "link.nodeValue === null", "true" },
        .{ "let text = link.firstChild", "undefined" },
        .{ "text.nodeValue === 'OK'", "true" },
        .{ "text.nodeValue = 'OK modified'", "OK modified" },
        .{ "text.nodeValue === 'OK modified'", "true" },
        .{ "link.nodeValue = 'nothing'", "nothing" },
    }, .{});

    try runner.testCases(&.{
        .{ "text.textContent === 'OK modified'", "true" },
        .{ "trimAndReplace(content.textContent) === 'OK modified And'", "true" },
        .{ "text.textContent = 'OK'", "OK" },
        .{ "text.textContent", "OK" },
        .{ "trimAndReplace(document.getElementById('para-empty').textContent)", "" },
        .{ "document.getElementById('para-empty').textContent = 'OK'", "OK" },
        .{ "document.getElementById('para-empty').firstChild.nodeName === '#text'", "true" },
    }, .{});

    try runner.testCases(&.{
        .{ "let append = document.createElement('h1')", "undefined" },
        .{ "content.appendChild(append).toString()", "[object HTMLHeadingElement]" },
        .{ "content.lastChild.__proto__.constructor.name", "HTMLHeadingElement" },
        .{ "content.appendChild(link).toString()", "[object HTMLAnchorElement]" },
    }, .{});

    try runner.testCases(&.{
        .{ "let clone = link.cloneNode()", "undefined" },
        .{ "clone.toString()", "[object HTMLAnchorElement]" },
        .{ "clone.parentNode === null", "true" },
        .{ "clone.firstChild === null", "true" },
        .{ "let clone_deep = link.cloneNode(true)", "undefined" },
        .{ "clone_deep.firstChild.nodeName === '#text'", "true" },
    }, .{});

    try runner.testCases(&.{
        .{ "link.contains(text)", "true" },
        .{ "text.contains(link)", "false" },
    }, .{});

    try runner.testCases(&.{
        .{ "link.hasChildNodes()", "true" },
        .{ "text.hasChildNodes()", "false" },
    }, .{});

    try runner.testCases(&.{
        .{ "link.childNodes.length", "1" },
        .{ "text.childNodes.length", "0" },
    }, .{});

    try runner.testCases(&.{
        .{ "let insertBefore = document.createElement('a')", "undefined" },
        .{ "link.insertBefore(insertBefore, text) !== undefined", "true" },
        .{ "link.firstChild.localName === 'a'", "true" },
    }, .{});

    try runner.testCases(&.{
        // TODO: does not seems to work
        // .{ "link.isDefaultNamespace('')", "true" },
        .{ "link.isDefaultNamespace('false')", "false" },
    }, .{});

    try runner.testCases(&.{
        .{ "let equal1 = document.createElement('a')", "undefined" },
        .{ "let equal2 = document.createElement('a')", "undefined" },
        .{ "equal1.textContent = 'is equal'", "is equal" },
        .{ "equal2.textContent = 'is equal'", "is equal" },
        // TODO: does not seems to work
        // .{ "equal1.isEqualNode(equal2)", "true" },
    }, .{});

    try runner.testCases(&.{
        .{ "document.body.isSameNode(document.body)", "true" },
    }, .{});

    try runner.testCases(&.{
        // TODO: no test
        .{ "link.normalize()", "undefined" },
    }, .{});

    try runner.testCases(&.{
        .{ "content.removeChild(append) !== undefined", "true" },
        .{ "last_child.__proto__.constructor.name !== 'HTMLHeadingElement'", "true" },
    }, .{});

    try runner.testCases(&.{
        .{ "let replace = document.createElement('div')", "undefined" },
        .{ "link.replaceChild(replace, insertBefore) !== undefined", "true" },
    }, .{});

    try runner.testCases(&.{
        .{ "Node.ELEMENT_NODE", "1" },
        .{ "Node.ATTRIBUTE_NODE", "2" },
        .{ "Node.TEXT_NODE", "3" },
        .{ "Node.CDATA_SECTION_NODE", "4" },
        .{ "Node.PROCESSING_INSTRUCTION_NODE", "7" },
        .{ "Node.COMMENT_NODE", "8" },
        .{ "Node.DOCUMENT_NODE", "9" },
        .{ "Node.DOCUMENT_TYPE_NODE", "10" },
        .{ "Node.DOCUMENT_FRAGMENT_NODE", "11" },
        .{ "Node.ENTITY_REFERENCE_NODE", "5" },
        .{ "Node.ENTITY_NODE", "6" },
        .{ "Node.NOTATION_NODE", "12" },
    }, .{});
}
