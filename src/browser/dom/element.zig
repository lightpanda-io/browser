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

const parser = @import("../netsurf.zig");
const SessionState = @import("../env.zig").SessionState;

const collection = @import("html_collection.zig");
const dump = @import("../dump.zig");
const css = @import("css.zig");

const Node = @import("node.zig").Node;
const Walker = @import("walker.zig").WalkerDepthFirst;
const NodeList = @import("nodelist.zig").NodeList;
const HTMLElem = @import("../html/elements.zig");
pub const Union = @import("../html/elements.zig").Union;

const DOMException = @import("exceptions.zig").DOMException;

// WEB IDL https://dom.spec.whatwg.org/#element
pub const Element = struct {
    pub const Self = parser.Element;
    pub const prototype = *Node;
    pub const subtype = .node;

    pub const DOMRect = struct {
        x: f64,
        y: f64,
        width: f64,
        height: f64,
    };

    pub fn toInterface(e: *parser.Element) !Union {
        return try HTMLElem.toInterface(Union, e);
        // SVGElement and MathML are not supported yet.
    }

    // JS funcs
    // --------

    pub fn get_namespaceURI(self: *parser.Element) !?[]const u8 {
        return try parser.nodeGetNamespace(parser.elementToNode(self));
    }

    pub fn get_prefix(self: *parser.Element) !?[]const u8 {
        return try parser.nodeGetPrefix(parser.elementToNode(self));
    }

    pub fn get_localName(self: *parser.Element) ![]const u8 {
        return try parser.nodeLocalName(parser.elementToNode(self));
    }

    pub fn get_tagName(self: *parser.Element) ![]const u8 {
        return try parser.nodeName(parser.elementToNode(self));
    }

    pub fn get_id(self: *parser.Element) ![]const u8 {
        return try parser.elementGetAttribute(self, "id") orelse "";
    }

    pub fn set_id(self: *parser.Element, id: []const u8) !void {
        return try parser.elementSetAttribute(self, "id", id);
    }

    pub fn get_className(self: *parser.Element) ![]const u8 {
        return try parser.elementGetAttribute(self, "class") orelse "";
    }

    pub fn set_className(self: *parser.Element, class: []const u8) !void {
        return try parser.elementSetAttribute(self, "class", class);
    }

    pub fn get_slot(self: *parser.Element) ![]const u8 {
        return try parser.elementGetAttribute(self, "slot") orelse "";
    }

    pub fn set_slot(self: *parser.Element, slot: []const u8) !void {
        return try parser.elementSetAttribute(self, "slot", slot);
    }

    pub fn get_classList(self: *parser.Element) !*parser.TokenList {
        return try parser.tokenListCreate(self, "class");
    }

    pub fn get_attributes(self: *parser.Element) !*parser.NamedNodeMap {
        // An element must have non-nil attributes.
        return try parser.nodeGetAttributes(parser.elementToNode(self)) orelse unreachable;
    }

    pub fn get_innerHTML(self: *parser.Element, state: *SessionState) ![]const u8 {
        var buf = std.ArrayList(u8).init(state.arena);
        defer buf.deinit();

        try dump.writeChildren(parser.elementToNode(self), buf.writer());
        // TODO express the caller owned the slice.
        // https://github.com/lightpanda-io/jsruntime-lib/issues/195
        return buf.toOwnedSlice();
    }

    pub fn get_outerHTML(self: *parser.Element, state: *SessionState) ![]const u8 {
        var buf = std.ArrayList(u8).init(state.arena);
        defer buf.deinit();

        try dump.writeNode(parser.elementToNode(self), buf.writer());
        // TODO express the caller owned the slice.
        // https://github.com/lightpanda-io/jsruntime-lib/issues/195
        return buf.toOwnedSlice();
    }

    pub fn set_innerHTML(self: *parser.Element, str: []const u8) !void {
        const node = parser.elementToNode(self);
        const doc = try parser.nodeOwnerDocument(node) orelse return parser.DOMError.WrongDocument;
        // parse the fragment
        const fragment = try parser.documentParseFragmentFromStr(doc, str);

        // remove existing children
        try Node.removeChildren(node);

        // get fragment body children
        const children = try parser.documentFragmentBodyChildren(fragment) orelse return;

        // append children to the node
        const ln = try parser.nodeListLength(children);
        var i: u32 = 0;
        while (i < ln) {
            defer i += 1;
            const child = try parser.nodeListItem(children, i) orelse continue;
            _ = try parser.nodeAppendChild(node, child);
        }
    }

    pub fn _hasAttributes(self: *parser.Element) !bool {
        return try parser.nodeHasAttributes(parser.elementToNode(self));
    }

    pub fn _getAttribute(self: *parser.Element, qname: []const u8) !?[]const u8 {
        return try parser.elementGetAttribute(self, qname);
    }

    pub fn _getAttributeNS(self: *parser.Element, ns: []const u8, qname: []const u8) !?[]const u8 {
        return try parser.elementGetAttributeNS(self, ns, qname);
    }

    pub fn _setAttribute(self: *parser.Element, qname: []const u8, value: []const u8) !void {
        return try parser.elementSetAttribute(self, qname, value);
    }

    pub fn _setAttributeNS(self: *parser.Element, ns: []const u8, qname: []const u8, value: []const u8) !void {
        return try parser.elementSetAttributeNS(self, ns, qname, value);
    }

    pub fn _removeAttribute(self: *parser.Element, qname: []const u8) !void {
        return try parser.elementRemoveAttribute(self, qname);
    }

    pub fn _removeAttributeNS(self: *parser.Element, ns: []const u8, qname: []const u8) !void {
        return try parser.elementRemoveAttributeNS(self, ns, qname);
    }

    pub fn _hasAttribute(self: *parser.Element, qname: []const u8) !bool {
        return try parser.elementHasAttribute(self, qname);
    }

    // https://dom.spec.whatwg.org/#dom-element-toggleattribute
    pub fn _toggleAttribute(self: *parser.Element, qname: []const u8, force: ?bool) !bool {
        const exists = try parser.elementHasAttribute(self, qname);

        // If attribute is null, then:
        if (!exists) {
            // If force is not given or is true, create an attribute whose
            // local name is qualifiedName, value is the empty string and node
            // document is this’s node document, then append this attribute to
            // this, and then return true.
            if (force == null or force.?) {
                try parser.elementSetAttribute(self, qname, "");
                return true;
            }

            // Return false.
            return false;
        }

        // Otherwise, if force is not given or is false, remove an attribute
        // given qualifiedName and this, and then return false.
        if (force == null or !force.?) {
            try parser.elementRemoveAttribute(self, qname);
            return false;
        }

        // Return true.
        return true;
    }

    pub fn _getAttributeNode(self: *parser.Element, name: []const u8) !?*parser.Attribute {
        return try parser.elementGetAttributeNode(self, name);
    }

    pub fn _getAttributeNodeNS(self: *parser.Element, ns: []const u8, name: []const u8) !?*parser.Attribute {
        return try parser.elementGetAttributeNodeNS(self, ns, name);
    }

    pub fn _setAttributeNode(self: *parser.Element, attr: *parser.Attribute) !?*parser.Attribute {
        return try parser.elementSetAttributeNode(self, attr);
    }

    pub fn _setAttributeNodeNS(self: *parser.Element, attr: *parser.Attribute) !?*parser.Attribute {
        return try parser.elementSetAttributeNodeNS(self, attr);
    }

    pub fn _removeAttributeNode(self: *parser.Element, attr: *parser.Attribute) !*parser.Attribute {
        return try parser.elementRemoveAttributeNode(self, attr);
    }

    pub fn _getElementsByTagName(
        self: *parser.Element,
        tag_name: []const u8,
        state: *SessionState,
    ) !collection.HTMLCollection {
        return try collection.HTMLCollectionByTagName(
            state.arena,
            parser.elementToNode(self),
            tag_name,
            false,
        );
    }

    pub fn _getElementsByClassName(
        self: *parser.Element,
        classNames: []const u8,
        state: *SessionState,
    ) !collection.HTMLCollection {
        return try collection.HTMLCollectionByClassName(
            state.arena,
            parser.elementToNode(self),
            classNames,
            false,
        );
    }

    // ParentNode
    // https://dom.spec.whatwg.org/#parentnode
    pub fn get_children(self: *parser.Element) !collection.HTMLCollection {
        return try collection.HTMLCollectionChildren(parser.elementToNode(self), false);
    }

    pub fn get_firstElementChild(self: *parser.Element) !?Union {
        var children = try get_children(self);
        return try children._item(0);
    }

    pub fn get_lastElementChild(self: *parser.Element) !?Union {
        // TODO we could check the last child node first, if it's an element,
        // we can return it directly instead of looping twice over the
        // children.
        var children = try get_children(self);
        const ln = try children.get_length();
        if (ln == 0) return null;
        return try children._item(ln - 1);
    }

    pub fn get_childElementCount(self: *parser.Element) !u32 {
        var children = try get_children(self);
        return try children.get_length();
    }

    // NonDocumentTypeChildNode
    // https://dom.spec.whatwg.org/#interface-nondocumenttypechildnode
    pub fn get_previousElementSibling(self: *parser.Element) !?Union {
        const res = try parser.nodePreviousElementSibling(parser.elementToNode(self));
        if (res == null) return null;
        return try HTMLElem.toInterface(HTMLElem.Union, res.?);
    }

    pub fn get_nextElementSibling(self: *parser.Element) !?Union {
        const res = try parser.nodeNextElementSibling(parser.elementToNode(self));
        if (res == null) return null;
        return try HTMLElem.toInterface(HTMLElem.Union, res.?);
    }

    fn getElementById(self: *parser.Element, id: []const u8) !?*parser.Node {
        // walk over the node tree fo find the node by id.
        const root = parser.elementToNode(self);
        const walker = Walker{};
        var next: ?*parser.Node = null;
        while (true) {
            next = try walker.get_next(root, next) orelse return null;
            // ignore non-element nodes.
            if (try parser.nodeType(next.?) != .element) {
                continue;
            }
            const e = parser.nodeToElement(next.?);
            if (std.mem.eql(u8, id, try get_id(e))) return next;
        }
    }

    pub fn _querySelector(self: *parser.Element, selector: []const u8, state: *SessionState) !?Union {
        if (selector.len == 0) return null;

        const n = try css.querySelector(state.arena, parser.elementToNode(self), selector);

        if (n == null) return null;

        return try toInterface(parser.nodeToElement(n.?));
    }

    pub fn _querySelectorAll(self: *parser.Element, selector: []const u8, state: *SessionState) !NodeList {
        return css.querySelectorAll(state.arena, parser.elementToNode(self), selector);
    }

    // TODO according with https://dom.spec.whatwg.org/#parentnode, the
    // function must accept either node or string.
    // blocked by https://github.com/lightpanda-io/jsruntime-lib/issues/114
    pub fn _prepend(self: *parser.Element, nodes: []const *parser.Node) !void {
        return Node.prepend(parser.elementToNode(self), nodes);
    }

    // TODO according with https://dom.spec.whatwg.org/#parentnode, the
    // function must accept either node or string.
    // blocked by https://github.com/lightpanda-io/jsruntime-lib/issues/114
    pub fn _append(self: *parser.Element, nodes: []const *parser.Node) !void {
        return Node.append(parser.elementToNode(self), nodes);
    }

    // TODO according with https://dom.spec.whatwg.org/#parentnode, the
    // function must accept either node or string.
    // blocked by https://github.com/lightpanda-io/jsruntime-lib/issues/114
    pub fn _replaceChildren(self: *parser.Element, nodes: []const *parser.Node) !void {
        return Node.replaceChildren(parser.elementToNode(self), nodes);
    }

    pub fn _getBoundingClientRect(self: *parser.Element, state: *SessionState) !DOMRect {
        return state.renderer.getRect(self);
    }

    pub fn get_clientWidth(_: *parser.Element, state: *SessionState) u32 {
        return state.renderer.width();
    }

    pub fn get_clientHeight(_: *parser.Element, state: *SessionState) u32 {
        return state.renderer.height();
    }

    pub fn deinit(_: *parser.Element, _: std.mem.Allocator) void {}
};

// Tests
// -----

const testing = @import("../../testing.zig");
test "Browser.DOM.Element" {
    var runner = try testing.jsRunner(testing.tracking_allocator, .{});
    defer runner.deinit();

    try runner.testCases(&.{
        .{ "let g = document.getElementById('content')", "undefined" },
        .{ "g.namespaceURI", "http://www.w3.org/1999/xhtml" },
        .{ "g.prefix", "null" },
        .{ "g.localName", "div" },
        .{ "g.tagName", "DIV" },
    }, .{});

    try runner.testCases(&.{
        .{ "let gs = document.getElementById('content')", "undefined" },
        .{ "gs.id", "content" },
        .{ "gs.id = 'foo'", "foo" },
        .{ "gs.id", "foo" },
        .{ "gs.id = 'content'", "content" },
        .{ "gs.className", "" },
        .{ "let gs2 = document.getElementById('para-empty')", "undefined" },
        .{ "gs2.className", "ok empty" },
        .{ "gs2.className = 'foo bar baz'", "foo bar baz" },
        .{ "gs2.className", "foo bar baz" },
        .{ "gs2.className = 'ok empty'", "ok empty" },
        .{ "let cl = gs2.classList", "undefined" },
        .{ "cl.length", "2" },
    }, .{});

    try runner.testCases(&.{
        .{ "let a = document.getElementById('content')", "undefined" },
        .{ "a.hasAttributes()", "true" },
        .{ "a.attributes.length", "1" },

        .{ "a.getAttribute('id')", "content" },

        .{ "a.hasAttribute('foo')", "false" },
        .{ "a.getAttribute('foo')", "null" },

        .{ "a.setAttribute('foo', 'bar')", "undefined" },
        .{ "a.hasAttribute('foo')", "true" },
        .{ "a.getAttribute('foo')", "bar" },

        .{ "a.setAttribute('foo', 'baz')", "undefined" },
        .{ "a.hasAttribute('foo')", "true" },
        .{ "a.getAttribute('foo')", "baz" },

        .{ "a.removeAttribute('foo')", "undefined" },
        .{ "a.hasAttribute('foo')", "false" },
        .{ "a.getAttribute('foo')", "null" },
    }, .{});

    try runner.testCases(&.{
        .{ "let b = document.getElementById('content')", "undefined" },
        .{ "b.toggleAttribute('foo')", "true" },
        .{ "b.hasAttribute('foo')", "true" },
        .{ "b.getAttribute('foo')", "" },

        .{ "b.toggleAttribute('foo')", "false" },
        .{ "b.hasAttribute('foo')", "false" },
    }, .{});

    try runner.testCases(&.{
        .{ "let c = document.getElementById('content')", "undefined" },
        .{ "c.children.length", "3" },
        .{ "c.firstElementChild.nodeName", "A" },
        .{ "c.lastElementChild.nodeName", "P" },
        .{ "c.childElementCount", "3" },

        .{ "c.prepend(document.createTextNode('foo'))", "undefined" },
        .{ "c.append(document.createTextNode('bar'))", "undefined" },
    }, .{});

    try runner.testCases(&.{
        .{ "let d = document.getElementById('para')", "undefined" },
        .{ "d.previousElementSibling.nodeName", "P" },
        .{ "d.nextElementSibling", "null" },
    }, .{});

    try runner.testCases(&.{
        .{ "let e = document.getElementById('content')", "undefined" },
        .{ "e.querySelector('foo')", "null" },
        .{ "e.querySelector('#foo')", "null" },
        .{ "e.querySelector('#link').id", "link" },
        .{ "e.querySelector('#para').id", "para" },
        .{ "e.querySelector('*').id", "link" },
        .{ "e.querySelector('')", "null" },
        .{ "e.querySelector('*').id", "link" },
        .{ "e.querySelector('#content')", "null" },
        .{ "e.querySelector('#para').id", "para" },
        .{ "e.querySelector('.ok').id", "link" },
        .{ "e.querySelector('a ~ p').id", "para-empty" },

        .{ "e.querySelectorAll('foo').length", "0" },
        .{ "e.querySelectorAll('#foo').length", "0" },
        .{ "e.querySelectorAll('#link').length", "1" },
        .{ "e.querySelectorAll('#link').item(0).id", "link" },
        .{ "e.querySelectorAll('#para').length", "1" },
        .{ "e.querySelectorAll('#para').item(0).id", "para" },
        .{ "e.querySelectorAll('*').length", "4" },
        .{ "e.querySelectorAll('p').length", "2" },
        .{ "e.querySelectorAll('.ok').item(0).id", "link" },
    }, .{});

    try runner.testCases(&.{
        .{ "let f = document.getElementById('content')", "undefined" },
        .{ "let ff = document.createAttribute('foo')", "undefined" },
        .{ "f.setAttributeNode(ff)", "null" },
        .{ "f.getAttributeNode('foo').name", "foo" },
        .{ "f.removeAttributeNode(ff).name", "foo" },
        .{ "f.getAttributeNode('bar')", "null" },
    }, .{});

    try runner.testCases(&.{
        .{ "document.getElementById('para').innerHTML", " And" },
        .{ "document.getElementById('para-empty').innerHTML.trim()", "<span id=\"para-empty-child\"></span>" },

        .{ "let h = document.getElementById('para-empty')", "undefined" },
        .{ "const prev = h.innerHTML", "undefined" },
        .{ "h.innerHTML = '<p id=\"hello\">hello world</p>'", "<p id=\"hello\">hello world</p>" },
        .{ "h.innerHTML", "<p id=\"hello\">hello world</p>" },
        .{ "h.firstChild.nodeName", "P" },
        .{ "h.firstChild.id", "hello" },
        .{ "h.firstChild.textContent", "hello world" },
        .{ "h.innerHTML = prev; true", "true" },
        .{ "document.getElementById('para-empty').innerHTML.trim()", "<span id=\"para-empty-child\"></span>" },
    }, .{});

    try runner.testCases(&.{
        .{ "document.getElementById('para').outerHTML", "<p id=\"para\"> And</p>" },
    }, .{});

    try runner.testCases(&.{
        .{ "document.getElementById('para').clientWidth", "0" },
        .{ "document.getElementById('para').clientHeight", "1" },

        .{ "let r1 = document.getElementById('para').getBoundingClientRect()", "undefined" },
        .{ "r1.x", "1" },
        .{ "r1.y", "0" },
        .{ "r1.width", "1" },
        .{ "r1.height", "1" },

        .{ "let r2 = document.getElementById('content').getBoundingClientRect()", "undefined" },
        .{ "r2.x", "2" },
        .{ "r2.y", "0" },
        .{ "r2.width", "1" },
        .{ "r2.height", "1" },

        .{ "let r3 = document.getElementById('para').getBoundingClientRect()", "undefined" },
        .{ "r3.x", "1" },
        .{ "r3.y", "0" },
        .{ "r3.width", "1" },
        .{ "r3.height", "1" },

        .{ "document.getElementById('para').clientWidth", "2" },
        .{ "document.getElementById('para').clientHeight", "1" },
    }, .{});
}
