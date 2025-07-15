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
const Page = @import("../page.zig").Page;

const css = @import("css.zig");
const log = @import("../../log.zig");
const dump = @import("../dump.zig");
const collection = @import("html_collection.zig");

const Node = @import("node.zig").Node;
const Walker = @import("walker.zig").WalkerDepthFirst;
const NodeList = @import("nodelist.zig").NodeList;
const HTMLElem = @import("../html/elements.zig");
const ShadowRoot = @import("../dom/shadow_root.zig").ShadowRoot;

pub const Union = @import("../html/elements.zig").Union;

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
        bottom: f64,
        right: f64,
        top: f64,
        left: f64,
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

    pub fn get_innerHTML(self: *parser.Element, page: *Page) ![]const u8 {
        var buf = std.ArrayList(u8).init(page.arena);
        try dump.writeChildren(parser.elementToNode(self), .{}, buf.writer());
        return buf.items;
    }

    pub fn get_outerHTML(self: *parser.Element, page: *Page) ![]const u8 {
        var buf = std.ArrayList(u8).init(page.arena);
        try dump.writeNode(parser.elementToNode(self), .{}, buf.writer());
        return buf.items;
    }

    pub fn set_innerHTML(self: *parser.Element, str: []const u8) !void {
        const node = parser.elementToNode(self);
        const doc = try parser.nodeOwnerDocument(node) orelse return parser.DOMError.WrongDocument;
        // parse the fragment
        const fragment = try parser.documentParseFragmentFromStr(doc, str);

        // remove existing children
        try Node.removeChildren(node);

        // I'm not sure what the exact behavior is supposed to be. Initially,
        // we were only copying the body of the document fragment. But it seems
        // like head elements should be copied too. Specifically, some sites
        // create script tags via innerHTML, which we need to capture.
        // If you play with this in a browser, you should notice that the
        // behavior is different depending on whether you're in a blank page
        // or an actual document. In a blank page, something like:
        //    x.innerHTML = '<script></script>';
        // does _not_ create an empty script, but in a real page, it does. Weird.
        const fragment_node = parser.documentFragmentToNode(fragment);
        const html = try parser.nodeFirstChild(fragment_node) orelse return;
        const head = try parser.nodeFirstChild(html) orelse return;
        {
            // First, copy some of the head element
            const children = try parser.nodeGetChildNodes(head);
            const ln = try parser.nodeListLength(children);
            for (0..ln) |_| {
                // always index 0, because nodeAppendChild moves the node out of
                // the nodeList and into the new tree
                const child = try parser.nodeListItem(children, 0) orelse continue;
                _ = try parser.nodeAppendChild(node, child);
            }
        }

        {
            const body = try parser.nodeNextSibling(head) orelse return;
            const children = try parser.nodeGetChildNodes(body);
            const ln = try parser.nodeListLength(children);
            for (0..ln) |_| {
                // always index 0, because nodeAppendChild moves the node out of
                // the nodeList and into the new tree
                const child = try parser.nodeListItem(children, 0) orelse continue;
                _ = try parser.nodeAppendChild(node, child);
            }
        }
    }

    // The closest() method of the Element interface traverses the element and its parents (heading toward the document root) until it finds a node that matches the specified CSS selector.
    // Returns the closest ancestor Element or itself, which matches the selectors. If there are no such element, null.
    pub fn _closest(self: *parser.Element, selector: []const u8, page: *Page) !?*parser.Element {
        const cssParse = @import("../css/css.zig").parse;
        const CssNodeWrap = @import("../css/libdom.zig").Node;
        const select = try cssParse(page.call_arena, selector, .{});

        var current: CssNodeWrap = .{ .node = parser.elementToNode(self) };
        while (true) {
            if (try select.match(current)) {
                if (!current.isElement()) {
                    log.err(.browser, "closest invalid type", .{ .type = try current.tag() });
                    return null;
                }
                return parser.nodeToElement(current.node);
            }
            current = try current.parent() orelse return null;
        }
    }

    // don't use parser.nodeHasAttributes(...) because that returns true/false
    // based on the type, e.g. a node never as attributes, an element always has
    // attributes. But, Element.hasAttributes is supposed to return true only
    // if the element has at least 1 attribute.
    pub fn _hasAttributes(self: *parser.Element) !bool {
        // an element _must_ have at least an empty attribute
        const node_map = try parser.nodeGetAttributes(parser.elementToNode(self)) orelse unreachable;
        return try parser.namedNodeMapGetLength(node_map) > 0;
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

    pub fn _hasAttributeNS(self: *parser.Element, ns: []const u8, qname: []const u8) !bool {
        return try parser.elementHasAttributeNS(self, ns, qname);
    }

    // https://dom.spec.whatwg.org/#dom-element-toggleattribute
    pub fn _toggleAttribute(self: *parser.Element, qname: []u8, force: ?bool) !bool {
        _ = std.ascii.lowerString(qname, qname);
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
            if (try parser.validateName(qname) == false) {
                return parser.DOMError.InvalidCharacter;
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
        page: *Page,
    ) !collection.HTMLCollection {
        return try collection.HTMLCollectionByTagName(
            page.arena,
            parser.elementToNode(self),
            tag_name,
            false,
        );
    }

    pub fn _getElementsByClassName(
        self: *parser.Element,
        classNames: []const u8,
        page: *Page,
    ) !collection.HTMLCollection {
        return try collection.HTMLCollectionByClassName(
            page.arena,
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

    pub fn _querySelector(self: *parser.Element, selector: []const u8, page: *Page) !?Union {
        if (selector.len == 0) return null;

        const n = try css.querySelector(page.call_arena, parser.elementToNode(self), selector);

        if (n == null) return null;

        return try toInterface(parser.nodeToElement(n.?));
    }

    pub fn _querySelectorAll(self: *parser.Element, selector: []const u8, page: *Page) !NodeList {
        return css.querySelectorAll(page.arena, parser.elementToNode(self), selector);
    }

    pub fn _prepend(self: *parser.Element, nodes: []const Node.NodeOrText) !void {
        return Node.prepend(parser.elementToNode(self), nodes);
    }

    pub fn _append(self: *parser.Element, nodes: []const Node.NodeOrText) !void {
        return Node.append(parser.elementToNode(self), nodes);
    }

    pub fn _before(self: *parser.Element, nodes: []const Node.NodeOrText) !void {
        const ref_node = parser.elementToNode(self);
        return Node.before(ref_node, nodes);
    }

    pub fn _after(self: *parser.Element, nodes: []const Node.NodeOrText) !void {
        const ref_node = parser.elementToNode(self);
        return Node.after(ref_node, nodes);
    }

    pub fn _replaceChildren(self: *parser.Element, nodes: []const Node.NodeOrText) !void {
        return Node.replaceChildren(parser.elementToNode(self), nodes);
    }

    // A DOMRect object providing information about the size of an element and its position relative to the viewport.
    // Returns a 0 DOMRect object if the element is eventually detached from the main window
    pub fn _getBoundingClientRect(self: *parser.Element, page: *Page) !DOMRect {
        // Since we are lazy rendering we need to do this check. We could store the renderer in a viewport such that it could cache these, but it would require tracking changes.
        if (!try page.isNodeAttached(parser.elementToNode(self))) {
            return DOMRect{
                .x = 0,
                .y = 0,
                .width = 0,
                .height = 0,
                .bottom = 0,
                .right = 0,
                .top = 0,
                .left = 0,
            };
        }
        return page.renderer.getRect(self);
    }

    // Returns a collection of DOMRect objects that indicate the bounding rectangles for each CSS border box in a client.
    // We do not render so it only always return the element's bounding rect.
    // Returns an empty array if the element is eventually detached from the main window
    pub fn _getClientRects(self: *parser.Element, page: *Page) ![]DOMRect {
        if (!try page.isNodeAttached(parser.elementToNode(self))) {
            return &.{};
        }
        const heap_ptr = try page.call_arena.create(DOMRect);
        heap_ptr.* = try page.renderer.getRect(self);
        return heap_ptr[0..1];
    }

    pub fn get_clientWidth(_: *parser.Element, page: *Page) u32 {
        return page.renderer.width();
    }

    pub fn get_clientHeight(_: *parser.Element, page: *Page) u32 {
        return page.renderer.height();
    }

    pub fn _matches(self: *parser.Element, selectors: []const u8, page: *Page) !bool {
        const cssParse = @import("../css/css.zig").parse;
        const CssNodeWrap = @import("../css/libdom.zig").Node;
        const s = try cssParse(page.call_arena, selectors, .{});
        return s.match(CssNodeWrap{ .node = parser.elementToNode(self) });
    }

    pub fn _scrollIntoViewIfNeeded(_: *parser.Element, center_if_needed: ?bool) void {
        _ = center_if_needed;
    }

    const CheckVisibilityOpts = struct {
        contentVisibilityAuto: bool,
        opacityProperty: bool,
        visibilityProperty: bool,
    };

    pub fn _checkVisibility(self: *parser.Element, opts: ?CheckVisibilityOpts) bool {
        _ = self;
        _ = opts;
        return true;
    }

    const AttachShadowOpts = struct {
        mode: []const u8, // must be specified
    };
    pub fn _attachShadow(self: *parser.Element, opts: AttachShadowOpts, page: *Page) !*ShadowRoot {
        const mode = std.meta.stringToEnum(ShadowRoot.Mode, opts.mode) orelse return error.InvalidArgument;
        const state = try page.getOrCreateNodeState(@alignCast(@ptrCast(self)));
        if (state.shadow_root) |sr| {
            if (mode != sr.mode) {
                // this is the behavior per the spec
                return error.NotSupportedError;
            }

            // TODO: the existing shadow root should be cleared!
            return sr;
        }

        // Not sure what to do if there is no owner document
        const doc = try parser.nodeOwnerDocument(@ptrCast(self)) orelse return error.InvalidArgument;
        const fragment = try parser.documentCreateDocumentFragment(doc);
        const sr = try page.arena.create(ShadowRoot);
        sr.* = .{
            .host = self,
            .mode = mode,
            .proto = fragment,
        };
        state.shadow_root = sr;
        return sr;
    }

    pub fn get_shadowRoot(self: *parser.Element, page: *Page) ?*ShadowRoot {
        const state = page.getNodeState(@alignCast(@ptrCast(self))) orelse return null;
        const sr = state.shadow_root orelse return null;
        if (sr.mode == .closed) {
            return null;
        }
        return sr;
    }
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
        .{ "const el2 = document.createElement('div');", "undefined" },
        .{ "el2.id = 'closest'; el2.className = 'ok';", "ok" },
        .{ "el2.closest('#closest')", "[object HTMLDivElement]" },
        .{ "el2.closest('.ok')", "[object HTMLDivElement]" },
        .{ "el2.closest('#9000')", "null" },
        .{ "el2.closest('.notok')", "null" },

        .{ "const sp = document.createElement('span');", "undefined" },
        .{ "el2.appendChild(sp);", "[object HTMLSpanElement]" },
        .{ "sp.closest('#closest')", "[object HTMLDivElement]" },
        .{ "sp.closest('#9000')", "null" },
    }, .{});

    try runner.testCases(&.{
        .{ "let a = document.getElementById('content')", "undefined" },
        .{ "a.hasAttributes()", "true" },
        .{ "a.attributes.length", "1" },
        .{ "a.getAttribute('id')", "content" },
        .{ "a.attributes['id'].value", "content" },
        .{
            \\ let x = '';
            \\ for (const attr of a.attributes) {
            \\   x += attr.name + '=' + attr.value;
            \\ }
            \\ x;
            ,
            "id=content",
        },

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
        .{ "document.getElementById('para').clientWidth", "1" },
        .{ "document.getElementById('para').clientHeight", "1" },

        .{ "let r1 = document.getElementById('para').getBoundingClientRect()", "undefined" },
        .{ "r1.x", "0" },
        .{ "r1.y", "0" },
        .{ "r1.width", "1" },
        .{ "r1.height", "1" },

        .{ "let r2 = document.getElementById('content').getBoundingClientRect()", "undefined" },
        .{ "r2.x", "1" },
        .{ "r2.y", "0" },
        .{ "r2.width", "1" },
        .{ "r2.height", "1" },

        .{ "let r3 = document.getElementById('para').getBoundingClientRect()", "undefined" },
        .{ "r3.x", "0" },
        .{ "r3.y", "0" },
        .{ "r3.width", "1" },
        .{ "r3.height", "1" },

        .{ "document.getElementById('para').clientWidth", "2" },
        .{ "document.getElementById('para').clientHeight", "1" },

        .{ "let r4 = document.createElement('div').getBoundingClientRect()", null },
        .{ "r4.x", "0" },
        .{ "r4.y", "0" },
        .{ "r4.width", "0" },
        .{ "r4.height", "0" },

        // Test setup causes WrongDocument or HierarchyRequest error unlike in chrome/firefox
        // .{ // An element of another document, even if created from the main document, is not rendered.
        //     \\ let div5 = document.createElement('div');
        //     \\ const newDoc = document.implementation.createHTMLDocument("New Document");
        //     \\ newDoc.body.appendChild(div5);
        //     \\ let r5 = div5.getBoundingClientRect();
        //     ,
        //     null,
        // },
        // .{ "r5.x", "0" },
        // .{ "r5.y", "0" },
        // .{ "r5.width", "0" },
        // .{ "r5.height", "0" },
    }, .{});

    try runner.testCases(&.{
        .{ "const el = document.createElement('div');", "undefined" },
        .{ "el.id = 'matches'; el.className = 'ok';", "ok" },
        .{ "el.matches('#matches')", "true" },
        .{ "el.matches('.ok')", "true" },
        .{ "el.matches('#9000')", "false" },
        .{ "el.matches('.notok')", "false" },
    }, .{});

    try runner.testCases(&.{
        .{ "const el3 = document.createElement('div');", "undefined" },
        .{ "el3.scrollIntoViewIfNeeded();", "undefined" },
        .{ "el3.scrollIntoViewIfNeeded(false);", "undefined" },
    }, .{});

    // before
    try runner.testCases(&.{
        .{ "const before_container = document.createElement('div');", "undefined" },
        .{ "document.append(before_container);", "undefined" },
        .{ "const b1 = document.createElement('div');", "undefined" },
        .{ "before_container.append(b1);", "undefined" },

        .{ "const b1_a = document.createElement('p');", "undefined" },
        .{ "b1.before(b1_a, 'over 9000');", "undefined" },
        .{ "before_container.innerHTML", "<p></p>over 9000<div></div>" },
    }, .{});

    // after
    try runner.testCases(&.{
        .{ "const after_container = document.createElement('div');", "undefined" },
        .{ "document.append(after_container);", "undefined" },
        .{ "const a1 = document.createElement('div');", "undefined" },
        .{ "after_container.append(a1);", "undefined" },

        .{ "const a1_a = document.createElement('p');", "undefined" },
        .{ "a1.after('over 9000', a1_a);", "undefined" },
        .{ "after_container.innerHTML", "<div></div>over 9000<p></p>" },
    }, .{});

    try runner.testCases(&.{
        .{ "var div1 = document.createElement('div');", null },
        .{ "div1.innerHTML = \"  <link/><table></table><a href='/a'>a</a><input type='checkbox'/>\"", null },
        .{ "div1.getElementsByTagName('a').length", "1" },
    }, .{});

    try runner.testCases(&.{
        .{ "document.createElement('a').hasAttributes()", "false" },
        .{ "var fc; (fc = document.createElement('div')).innerHTML = '<script><\\/script>'", null },
        .{ "fc.outerHTML", "<div><script></script></div>" },

        .{ "fc; (fc = document.createElement('div')).innerHTML = '<script><\\/script><p>hello</p>'", null },
        .{ "fc.outerHTML", "<div><script></script><p>hello</p></div>" },
    }, .{});
}
