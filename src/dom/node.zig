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

const jsruntime = @import("jsruntime");
const Case = jsruntime.test_utils.Case;
const checkCases = jsruntime.test_utils.checkCases;
const runScript = jsruntime.test_utils.runScript;
const Variadic = jsruntime.Variadic;

const generate = @import("../generate.zig");

const parser = @import("netsurf");

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
    HTMLCollectionIterator,
    HTML.Interfaces,
};

pub const Union = generate.Union(Interfaces);

// Node implementation
pub const Node = struct {
    pub const Self = parser.Node;
    pub const prototype = *EventTarget;
    pub const mem_guarantied = true;
    pub const sub_type = "node";

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

    pub fn _getRootNode(self: *parser.Node) !?HTMLElem.Union {
        // TODO return this’s shadow-including root if options["composed"] is true
        const res = try parser.nodeOwnerDocument(self);
        if (res == null) {
            return null;
        }
        return try HTMLElem.toInterface(HTMLElem.Union, @as(*parser.Element, @ptrCast(res.?)));
    }

    pub fn _hasChildNodes(self: *parser.Node) !bool {
        return try parser.nodeHasChildNodes(self);
    }

    pub fn get_childNodes(self: *parser.Node, alloc: std.mem.Allocator) !NodeList {
        var list = NodeList.init();
        errdefer list.deinit(alloc);

        var n = try parser.nodeFirstChild(self) orelse return list;
        while (true) {
            try list.append(alloc, n);
            n = try parser.nodeNextSibling(n) orelse return list;
        }
    }

    pub fn _insertBefore(self: *parser.Node, new_node: *parser.Node, ref_node: *parser.Node) !*parser.Node {
        return try parser.nodeInsertBefore(self, new_node, ref_node);
    }

    pub fn _isDefaultNamespace(self: *parser.Node, namespace: []const u8) !bool {
        // TODO: namespace is not an optional parameter, but can be null.
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
    pub fn hierarchy(self: *parser.Node, nodes: ?Variadic(*parser.Node)) !bool {
        if (nodes == null) return true;
        if (nodes.?.slice.len == 0) return true;

        for (nodes.?.slice) |node| if (self == node) return false;

        return true;
    }

    // TODO according with https://dom.spec.whatwg.org/#parentnode, the
    // function must accept either node or string.
    // blocked by https://github.com/lightpanda-io/jsruntime-lib/issues/114
    pub fn prepend(self: *parser.Node, nodes: ?Variadic(*parser.Node)) !void {
        if (nodes == null) return;
        if (nodes.?.slice.len == 0) return;

        // check hierarchy
        if (!try hierarchy(self, nodes)) return parser.DOMError.HierarchyRequest;

        const first = try parser.nodeFirstChild(self);
        if (first == null) {
            for (nodes.?.slice) |node| {
                _ = try parser.nodeAppendChild(self, node);
            }
            return;
        }

        for (nodes.?.slice) |node| {
            _ = try parser.nodeInsertBefore(self, node, first.?);
        }
    }

    // TODO according with https://dom.spec.whatwg.org/#parentnode, the
    // function must accept either node or string.
    // blocked by https://github.com/lightpanda-io/jsruntime-lib/issues/114
    pub fn append(self: *parser.Node, nodes: ?Variadic(*parser.Node)) !void {
        if (nodes == null) return;
        if (nodes.?.slice.len == 0) return;

        // check hierarchy
        if (!try hierarchy(self, nodes)) return parser.DOMError.HierarchyRequest;

        for (nodes.?.slice) |node| {
            _ = try parser.nodeAppendChild(self, node);
        }
    }

    // TODO according with https://dom.spec.whatwg.org/#parentnode, the
    // function must accept either node or string.
    // blocked by https://github.com/lightpanda-io/jsruntime-lib/issues/114
    pub fn replaceChildren(self: *parser.Node, nodes: ?Variadic(*parser.Node)) !void {
        if (nodes == null) return;
        if (nodes.?.slice.len == 0) return;

        // check hierarchy
        if (!try hierarchy(self, nodes)) return parser.DOMError.HierarchyRequest;

        // remove existing children
        try removeChildren(self);

        // add new children
        for (nodes.?.slice) |node| {
            _ = try parser.nodeAppendChild(self, node);
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

    pub fn deinit(_: *parser.Node, _: std.mem.Allocator) void {}
};

// Tests
// -----

pub fn testExecFn(
    alloc: std.mem.Allocator,
    js_env: *jsruntime.Env,
) anyerror!void {

    // helper functions
    const trim_and_replace =
        \\function trimAndReplace(str) {
        \\str = str.replace(/(\r\n|\n|\r)/gm,'');
        \\str = str.replace(/\s+/g, ' ');
        \\str = str.trim();
        \\return str;
        \\}
    ;
    try runScript(js_env, alloc, trim_and_replace, "proto_test");

    var node_compare_document_position = [_]Case{
        .{ .src = "document.body.compareDocumentPosition(document.firstChild); ", .ex = "10" },
        .{ .src = "document.getElementById(\"para-empty\").compareDocumentPosition(document.getElementById(\"content\"));", .ex = "10" },
        .{ .src = "document.getElementById(\"content\").compareDocumentPosition(document.getElementById(\"para-empty\"));", .ex = "20" },
        .{ .src = "document.getElementById(\"link\").compareDocumentPosition(document.getElementById(\"link\"));", .ex = "0" },
        .{ .src = "document.getElementById(\"para-empty\").compareDocumentPosition(document.getElementById(\"link\"));", .ex = "2" },
        .{ .src = "document.getElementById(\"link\").compareDocumentPosition(document.getElementById(\"para-empty\"));", .ex = "4" },
    };
    try checkCases(js_env, &node_compare_document_position);

    var get_root_node = [_]Case{
        .{ .src = "document.getElementById('content').getRootNode().__proto__.constructor.name", .ex = "HTMLDocument" },
    };
    try checkCases(js_env, &get_root_node);

    var first_child = [_]Case{
        // for next test cases
        .{ .src = "let content = document.getElementById('content')", .ex = "undefined" },
        .{ .src = "let link = document.getElementById('link')", .ex = "undefined" },
        .{ .src = "let first_child = content.firstChild.nextSibling", .ex = "undefined" }, // nextSibling because of line return \n

        .{ .src = "let body_first_child = document.body.firstChild", .ex = "undefined" },
        .{ .src = "body_first_child.localName", .ex = "div" },
        .{ .src = "body_first_child.__proto__.constructor.name", .ex = "HTMLDivElement" },
        .{ .src = "document.getElementById('para-empty').firstChild.firstChild", .ex = "null" },
    };
    try checkCases(js_env, &first_child);

    var last_child = [_]Case{
        .{ .src = "let last_child = content.lastChild.previousSibling", .ex = "undefined" }, // previousSibling because of line return \n
        .{ .src = "last_child.__proto__.constructor.name", .ex = "Comment" },
    };
    try checkCases(js_env, &last_child);

    var next_sibling = [_]Case{
        .{ .src = "let next_sibling = link.nextSibling.nextSibling", .ex = "undefined" },
        .{ .src = "next_sibling.localName", .ex = "p" },
        .{ .src = "next_sibling.__proto__.constructor.name", .ex = "HTMLParagraphElement" },
        .{ .src = "content.nextSibling.nextSibling", .ex = "null" },
    };
    try checkCases(js_env, &next_sibling);

    var prev_sibling = [_]Case{
        .{ .src = "let prev_sibling = document.getElementById('para-empty').previousSibling.previousSibling", .ex = "undefined" },
        .{ .src = "prev_sibling.localName", .ex = "a" },
        .{ .src = "prev_sibling.__proto__.constructor.name", .ex = "HTMLAnchorElement" },
        .{ .src = "content.previousSibling", .ex = "null" },
    };
    try checkCases(js_env, &prev_sibling);

    var parent = [_]Case{
        .{ .src = "let parent = document.getElementById('para').parentElement", .ex = "undefined" },
        .{ .src = "parent.localName", .ex = "div" },
        .{ .src = "parent.__proto__.constructor.name", .ex = "HTMLDivElement" },
        .{ .src = "let h = content.parentElement.parentElement", .ex = "undefined" },
        .{ .src = "h.parentElement", .ex = "null" },
        .{ .src = "h.parentNode.__proto__.constructor.name", .ex = "HTMLDocument" },
    };
    try checkCases(js_env, &parent);

    var node_name = [_]Case{
        .{ .src = "first_child.nodeName === 'A'", .ex = "true" },
        .{ .src = "link.firstChild.nodeName === '#text'", .ex = "true" },
        .{ .src = "last_child.nodeName === '#comment'", .ex = "true" },
        .{ .src = "document.nodeName === '#document'", .ex = "true" },
    };
    try checkCases(js_env, &node_name);

    var node_type = [_]Case{
        .{ .src = "first_child.nodeType === 1", .ex = "true" },
        .{ .src = "link.firstChild.nodeType === 3", .ex = "true" },
        .{ .src = "last_child.nodeType === 8", .ex = "true" },
        .{ .src = "document.nodeType === 9", .ex = "true" },
    };
    try checkCases(js_env, &node_type);

    var owner = [_]Case{
        .{ .src = "let owner = content.ownerDocument", .ex = "undefined" },
        .{ .src = "owner.__proto__.constructor.name", .ex = "HTMLDocument" },
        .{ .src = "document.ownerDocument", .ex = "null" },
        .{ .src = "let owner2 = document.createElement('div').ownerDocument", .ex = "undefined" },
        .{ .src = "owner2.__proto__.constructor.name", .ex = "HTMLDocument" },
    };
    try checkCases(js_env, &owner);

    var connected = [_]Case{
        .{ .src = "content.isConnected", .ex = "true" },
        .{ .src = "document.isConnected", .ex = "true" },
        .{ .src = "document.createElement('div').isConnected", .ex = "false" },
    };
    try checkCases(js_env, &connected);

    var node_value = [_]Case{
        .{ .src = "last_child.nodeValue === 'comment'", .ex = "true" },
        .{ .src = "link.nodeValue === null", .ex = "true" },
        .{ .src = "let text = link.firstChild", .ex = "undefined" },
        .{ .src = "text.nodeValue === 'OK'", .ex = "true" },
        .{ .src = "text.nodeValue = 'OK modified'", .ex = "OK modified" },
        .{ .src = "text.nodeValue === 'OK modified'", .ex = "true" },
        .{ .src = "link.nodeValue = 'nothing'", .ex = "nothing" },
    };
    try checkCases(js_env, &node_value);

    var node_text_content = [_]Case{
        .{ .src = "text.textContent === 'OK modified'", .ex = "true" },
        .{ .src = "trimAndReplace(content.textContent) === 'OK modified And'", .ex = "true" },
        .{ .src = "text.textContent = 'OK'", .ex = "OK" },
        .{ .src = "text.textContent", .ex = "OK" },
        .{ .src = "trimAndReplace(document.getElementById('para-empty').textContent)", .ex = "" },
        .{ .src = "document.getElementById('para-empty').textContent = 'OK'", .ex = "OK" },
        .{ .src = "document.getElementById('para-empty').firstChild.nodeName === '#text'", .ex = "true" },
    };
    try checkCases(js_env, &node_text_content);

    var node_append_child = [_]Case{
        .{ .src = "let append = document.createElement('h1')", .ex = "undefined" },
        .{ .src = "content.appendChild(append).toString()", .ex = "[object HTMLHeadingElement]" },
        .{ .src = "content.lastChild.__proto__.constructor.name", .ex = "HTMLHeadingElement" },
        .{ .src = "content.appendChild(link).toString()", .ex = "[object HTMLAnchorElement]" },
    };
    try checkCases(js_env, &node_append_child);

    var node_clone = [_]Case{
        .{ .src = "let clone = link.cloneNode()", .ex = "undefined" },
        .{ .src = "clone.toString()", .ex = "[object HTMLAnchorElement]" },
        .{ .src = "clone.parentNode === null", .ex = "true" },
        .{ .src = "clone.firstChild === null", .ex = "true" },
        .{ .src = "let clone_deep = link.cloneNode(true)", .ex = "undefined" },
        .{ .src = "clone_deep.firstChild.nodeName === '#text'", .ex = "true" },
    };
    try checkCases(js_env, &node_clone);

    var node_contains = [_]Case{
        .{ .src = "link.contains(text)", .ex = "true" },
        .{ .src = "text.contains(link)", .ex = "false" },
    };
    try checkCases(js_env, &node_contains);

    var node_has_child_nodes = [_]Case{
        .{ .src = "link.hasChildNodes()", .ex = "true" },
        .{ .src = "text.hasChildNodes()", .ex = "false" },
    };
    try checkCases(js_env, &node_has_child_nodes);

    var node_child_nodes = [_]Case{
        .{ .src = "link.childNodes.length", .ex = "1" },
        .{ .src = "text.childNodes.length", .ex = "0" },
    };
    try checkCases(js_env, &node_child_nodes);

    var node_insert_before = [_]Case{
        .{ .src = "let insertBefore = document.createElement('a')", .ex = "undefined" },
        .{ .src = "link.insertBefore(insertBefore, text) !== undefined", .ex = "true" },
        .{ .src = "link.firstChild.localName === 'a'", .ex = "true" },
    };
    try checkCases(js_env, &node_insert_before);

    var node_is_default_namespace = [_]Case{
        // TODO: does not seems to work
        // .{ .src = "link.isDefaultNamespace('')", .ex = "true" },
        .{ .src = "link.isDefaultNamespace('false')", .ex = "false" },
    };
    try checkCases(js_env, &node_is_default_namespace);

    var node_is_equal_node = [_]Case{
        .{ .src = "let equal1 = document.createElement('a')", .ex = "undefined" },
        .{ .src = "let equal2 = document.createElement('a')", .ex = "undefined" },
        .{ .src = "equal1.textContent = 'is equal'", .ex = "is equal" },
        .{ .src = "equal2.textContent = 'is equal'", .ex = "is equal" },
        // TODO: does not seems to work
        // .{ .src = "equal1.isEqualNode(equal2)", .ex = "true" },
    };
    try checkCases(js_env, &node_is_equal_node);

    var node_is_same_node = [_]Case{
        .{ .src = "document.body.isSameNode(document.body)", .ex = "true" },
    };
    try checkCases(js_env, &node_is_same_node);

    var node_normalize = [_]Case{
        // TODO: no test
        .{ .src = "link.normalize()", .ex = "undefined" },
    };
    try checkCases(js_env, &node_normalize);

    var node_remove_child = [_]Case{
        .{ .src = "content.removeChild(append) !== undefined", .ex = "true" },
        .{ .src = "last_child.__proto__.constructor.name !== 'HTMLHeadingElement'", .ex = "true" },
    };
    try checkCases(js_env, &node_remove_child);

    var node_replace_child = [_]Case{
        .{ .src = "let replace = document.createElement('div')", .ex = "undefined" },
        .{ .src = "link.replaceChild(replace, insertBefore) !== undefined", .ex = "true" },
    };
    try checkCases(js_env, &node_replace_child);
}
