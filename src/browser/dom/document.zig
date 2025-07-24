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
const Page = @import("../page.zig").Page;

const Node = @import("node.zig").Node;
const NodeList = @import("nodelist.zig").NodeList;
const NodeUnion = @import("node.zig").Union;

const collection = @import("html_collection.zig");
const css = @import("css.zig");

const Element = @import("element.zig").Element;
const ElementUnion = @import("element.zig").Union;
const TreeWalker = @import("tree_walker.zig").TreeWalker;
const CSSStyleSheet = @import("../cssom/CSSStyleSheet.zig");
const NodeIterator = @import("node_iterator.zig").NodeIterator;
const Range = @import("range.zig").Range;

const Env = @import("../env.zig").Env;

const DOMImplementation = @import("implementation.zig").DOMImplementation;

// WEB IDL https://dom.spec.whatwg.org/#document
pub const Document = struct {
    pub const Self = parser.Document;
    pub const prototype = *Node;
    pub const subtype = .node;

    pub fn constructor(page: *const Page) !*parser.DocumentHTML {
        const doc = try parser.documentCreateDocument(
            try parser.documentHTMLGetTitle(page.window.document),
        );

        // we have to work w/ document instead of html document.
        const ddoc = parser.documentHTMLToDocument(doc);
        const ccur = parser.documentHTMLToDocument(page.window.document);
        try parser.documentSetDocumentURI(ddoc, try parser.documentGetDocumentURI(ccur));
        try parser.documentSetInputEncoding(ddoc, try parser.documentGetInputEncoding(ccur));

        return doc;
    }

    // JS funcs
    // --------
    pub fn get_implementation(_: *parser.Document) DOMImplementation {
        return DOMImplementation{};
    }

    pub fn get_documentElement(self: *parser.Document) !?ElementUnion {
        const e = try parser.documentGetDocumentElement(self);
        if (e == null) return null;
        return try Element.toInterface(e.?);
    }

    pub fn get_documentURI(self: *parser.Document) ![]const u8 {
        return try parser.documentGetDocumentURI(self);
    }

    pub fn get_URL(self: *parser.Document) ![]const u8 {
        return try get_documentURI(self);
    }

    // TODO implement contentType
    pub fn get_contentType(self: *parser.Document) []const u8 {
        _ = self;
        return "text/html";
    }

    // TODO implement compactMode
    pub fn get_compatMode(self: *parser.Document) []const u8 {
        _ = self;
        return "CSS1Compat";
    }

    pub fn get_characterSet(self: *parser.Document) ![]const u8 {
        return try parser.documentGetInputEncoding(self);
    }

    // alias of get_characterSet
    pub fn get_charset(self: *parser.Document) ![]const u8 {
        return try get_characterSet(self);
    }

    // alias of get_characterSet
    pub fn get_inputEncoding(self: *parser.Document) ![]const u8 {
        return try get_characterSet(self);
    }

    pub fn get_doctype(self: *parser.Document) !?*parser.DocumentType {
        return try parser.documentGetDoctype(self);
    }

    pub fn _createEvent(_: *parser.Document, eventCstr: []const u8) !*parser.Event {
        // TODO: for now only "Event" constructor is supported
        // see table on https://dom.spec.whatwg.org/#dom-document-createevent $2
        if (std.ascii.eqlIgnoreCase(eventCstr, "Event") or std.ascii.eqlIgnoreCase(eventCstr, "Events")) {
            return try parser.eventCreate();
        }
        return parser.DOMError.NotSupported;
    }

    pub fn _getElementById(self: *parser.Document, id: []const u8) !?ElementUnion {
        const e = try parser.documentGetElementById(self, id) orelse return null;
        return try Element.toInterface(e);
    }

    pub fn _createElement(self: *parser.Document, tag_name: []const u8) !ElementUnion {
        // The element’s namespace is the HTML namespace when document is an HTML document
        // https://dom.spec.whatwg.org/#ref-for-dom-document-createelement%E2%91%A0
        const e = try parser.documentCreateElementNS(self, "http://www.w3.org/1999/xhtml", tag_name);
        return Element.toInterface(e);
    }

    pub fn _createElementNS(self: *parser.Document, ns: []const u8, tag_name: []const u8) !ElementUnion {
        const e = try parser.documentCreateElementNS(self, ns, tag_name);
        return try Element.toInterface(e);
    }

    // We can't simply use libdom dom_document_get_elements_by_tag_name here.
    // Indeed, netsurf implemented a previous dom spec when
    // getElementsByTagName returned a NodeList.
    // But since
    // https://github.com/whatwg/dom/commit/190700b7c12ecfd3b5ebdb359ab1d6ea9cbf7749
    // the spec changed to return an HTMLCollection instead.
    // That's why we reimplemented getElementsByTagName by using an
    // HTMLCollection in zig here.
    pub fn _getElementsByTagName(
        self: *parser.Document,
        tag_name: []const u8,
        page: *Page,
    ) !collection.HTMLCollection {
        return try collection.HTMLCollectionByTagName(page.arena, parser.documentToNode(self), tag_name, .{
            .include_root = true,
        });
    }

    pub fn _getElementsByClassName(
        self: *parser.Document,
        classNames: []const u8,
        page: *Page,
    ) !collection.HTMLCollection {
        return try collection.HTMLCollectionByClassName(page.arena, parser.documentToNode(self), classNames, .{
            .include_root = true,
        });
    }

    pub fn _createDocumentFragment(self: *parser.Document) !*parser.DocumentFragment {
        return try parser.documentCreateDocumentFragment(self);
    }

    pub fn _createTextNode(self: *parser.Document, data: []const u8) !*parser.Text {
        return try parser.documentCreateTextNode(self, data);
    }

    pub fn _createCDATASection(self: *parser.Document, data: []const u8) !*parser.CDATASection {
        return try parser.documentCreateCDATASection(self, data);
    }

    pub fn _createComment(self: *parser.Document, data: []const u8) !*parser.Comment {
        return try parser.documentCreateComment(self, data);
    }

    pub fn _createProcessingInstruction(self: *parser.Document, target: []const u8, data: []const u8) !*parser.ProcessingInstruction {
        return try parser.documentCreateProcessingInstruction(self, target, data);
    }

    pub fn _importNode(self: *parser.Document, node: *parser.Node, deep: ?bool) !NodeUnion {
        const n = try parser.documentImportNode(self, node, deep orelse false);
        return try Node.toInterface(n);
    }

    pub fn _adoptNode(self: *parser.Document, node: *parser.Node) !NodeUnion {
        const n = try parser.documentAdoptNode(self, node);
        return try Node.toInterface(n);
    }

    pub fn _createAttribute(self: *parser.Document, name: []const u8) !*parser.Attribute {
        return try parser.documentCreateAttribute(self, name);
    }

    pub fn _createAttributeNS(self: *parser.Document, ns: []const u8, qname: []const u8) !*parser.Attribute {
        return try parser.documentCreateAttributeNS(self, ns, qname);
    }

    // ParentNode
    // https://dom.spec.whatwg.org/#parentnode
    pub fn get_children(self: *parser.Document) !collection.HTMLCollection {
        return collection.HTMLCollectionChildren(parser.documentToNode(self), .{
            .include_root = false,
        });
    }

    pub fn get_firstElementChild(self: *parser.Document) !?ElementUnion {
        const elt = try parser.documentGetDocumentElement(self) orelse return null;
        return try Element.toInterface(elt);
    }

    pub fn get_lastElementChild(self: *parser.Document) !?ElementUnion {
        const elt = try parser.documentGetDocumentElement(self) orelse return null;
        return try Element.toInterface(elt);
    }

    pub fn get_childElementCount(self: *parser.Document) !u32 {
        _ = try parser.documentGetDocumentElement(self) orelse return 0;
        return 1;
    }

    pub fn _querySelector(self: *parser.Document, selector: []const u8, page: *Page) !?ElementUnion {
        if (selector.len == 0) return null;

        const n = try css.querySelector(page.call_arena, parser.documentToNode(self), selector);

        if (n == null) return null;

        return try Element.toInterface(parser.nodeToElement(n.?));
    }

    pub fn _querySelectorAll(self: *parser.Document, selector: []const u8, page: *Page) !NodeList {
        return css.querySelectorAll(page.arena, parser.documentToNode(self), selector);
    }

    pub fn _prepend(self: *parser.Document, nodes: []const Node.NodeOrText) !void {
        return Node.prepend(parser.documentToNode(self), nodes);
    }

    pub fn _append(self: *parser.Document, nodes: []const Node.NodeOrText) !void {
        return Node.append(parser.documentToNode(self), nodes);
    }

    pub fn _replaceChildren(self: *parser.Document, nodes: []const Node.NodeOrText) !void {
        return Node.replaceChildren(parser.documentToNode(self), nodes);
    }

    pub fn _createTreeWalker(_: *parser.Document, root: *parser.Node, what_to_show: ?u32, filter: ?TreeWalker.TreeWalkerOpts) !TreeWalker {
        return try TreeWalker.init(root, what_to_show, filter);
    }

    pub fn _createNodeIterator(_: *parser.Document, root: *parser.Node, what_to_show: ?u32, filter: ?NodeIterator.NodeIteratorOpts) !NodeIterator {
        return try NodeIterator.init(root, what_to_show, filter);
    }

    pub fn getActiveElement(self: *parser.Document, page: *Page) !?*parser.Element {
        if (page.getNodeState(@alignCast(@ptrCast(self)))) |state| {
            if (state.active_element) |ae| {
                return ae;
            }
        }

        if (try parser.documentHTMLBody(page.window.document)) |body| {
            return @alignCast(@ptrCast(body));
        }

        return try parser.documentGetDocumentElement(self);
    }

    pub fn get_activeElement(self: *parser.Document, page: *Page) !?ElementUnion {
        const ae = (try getActiveElement(self, page)) orelse return null;
        return try Element.toInterface(ae);
    }

    // TODO: some elements can't be focused, like if they're disabled
    // but there doesn't seem to be a generic way to check this. For example
    // we could look for the "disabled" attribute, but that's only meaningful
    // on certain types, and libdom's vtable doesn't seem to expose this.
    pub fn setFocus(self: *parser.Document, e: *parser.ElementHTML, page: *Page) !void {
        const state = try page.getOrCreateNodeState(@alignCast(@ptrCast(self)));
        state.active_element = @ptrCast(e);
    }

    pub fn _createRange(_: *parser.Document, page: *Page) Range {
        return Range.constructor(page);
    }

    // TODO: dummy implementation
    pub fn get_styleSheets(_: *parser.Document) []CSSStyleSheet {
        return &.{};
    }
};

const testing = @import("../../testing.zig");
test "Browser.DOM.Document" {
    var runner = try testing.jsRunner(testing.tracking_allocator, .{
        .url = "about:blank",
    });
    defer runner.deinit();

    try runner.testCases(&.{
        .{ "document.__proto__.__proto__.constructor.name", "Document" },
        .{ "document.__proto__.__proto__.__proto__.constructor.name", "Node" },
        .{ "document.__proto__.__proto__.__proto__.__proto__.constructor.name", "EventTarget" },

        .{ "let newdoc = new Document()", "undefined" },
        .{ "newdoc.documentElement", "null" },
        .{ "newdoc.children.length", "0" },
        .{ "newdoc.getElementsByTagName('*').length", "0" },
        .{ "newdoc.getElementsByTagName('*').item(0)", "null" },
        .{ "newdoc.inputEncoding === document.inputEncoding", "true" },
        .{ "newdoc.documentURI === document.documentURI", "true" },
        .{ "newdoc.URL === document.URL", "true" },
        .{ "newdoc.compatMode === document.compatMode", "true" },
        .{ "newdoc.characterSet === document.characterSet", "true" },
        .{ "newdoc.charset === document.charset", "true" },
        .{ "newdoc.contentType === document.contentType", "true" },
    }, .{});

    try runner.testCases(&.{
        .{ "let getElementById = document.getElementById('content')", "undefined" },
        .{ "getElementById.constructor.name", "HTMLDivElement" },
        .{ "getElementById.localName", "div" },
    }, .{});

    try runner.testCases(&.{
        .{ "let getElementsByTagName = document.getElementsByTagName('p')", "undefined" },
        .{ "getElementsByTagName.length", "2" },
        .{ "getElementsByTagName.item(0).localName", "p" },
        .{ "getElementsByTagName.item(1).localName", "p" },
        .{ "let getElementsByTagNameAll = document.getElementsByTagName('*')", "undefined" },
        .{ "getElementsByTagNameAll.length", "8" },
        .{ "getElementsByTagNameAll.item(0).localName", "html" },
        .{ "getElementsByTagNameAll.item(7).localName", "p" },
        .{ "getElementsByTagNameAll.namedItem('para-empty-child').localName", "span" },
    }, .{});

    try runner.testCases(&.{
        .{ "let ok = document.getElementsByClassName('ok')", "undefined" },
        .{ "ok.length", "2" },
        .{ "let empty = document.getElementsByClassName('empty')", "undefined" },
        .{ "empty.length", "1" },
        .{ "let emptyok = document.getElementsByClassName('empty ok')", "undefined" },
        .{ "emptyok.length", "1" },
    }, .{});

    try runner.testCases(&.{
        .{ "let e = document.documentElement", "undefined" },
        .{ "e.localName", "html" },
    }, .{});

    try runner.testCases(&.{
        .{ "document.characterSet", "UTF-8" },
        .{ "document.charset", "UTF-8" },
        .{ "document.inputEncoding", "UTF-8" },
    }, .{});

    try runner.testCases(&.{
        .{ "document.compatMode", "CSS1Compat" },
    }, .{});

    try runner.testCases(&.{
        .{ "document.contentType", "text/html" },
    }, .{});

    try runner.testCases(&.{
        .{ "document.documentURI", "about:blank" },
        .{ "document.URL", "about:blank" },
    }, .{});

    try runner.testCases(&.{
        .{ "let impl = document.implementation", "undefined" },
    }, .{});

    try runner.testCases(&.{
        .{ "let d = new Document()", "undefined" },
        .{ "d.characterSet", "UTF-8" },
        .{ "d.URL", "about:blank" },
        .{ "d.documentURI", "about:blank" },
        .{ "d.compatMode", "CSS1Compat" },
        .{ "d.contentType", "text/html" },
    }, .{});

    try runner.testCases(&.{
        .{ "var v = document.createDocumentFragment()", "undefined" },
        .{ "v.nodeName", "#document-fragment" },
    }, .{});

    try runner.testCases(&.{
        .{ "var v = document.createTextNode('foo')", "undefined" },
        .{ "v.nodeName", "#text" },
    }, .{});

    try runner.testCases(&.{
        .{ "var v = document.createCDATASection('foo')", "undefined" },
        .{ "v.nodeName", "#cdata-section" },
    }, .{});

    try runner.testCases(&.{
        .{ "var v = document.createComment('foo')", "undefined" },
        .{ "v.nodeName", "#comment" },
        .{ "let v2 = v.cloneNode()", "undefined" },
    }, .{});

    try runner.testCases(&.{
        .{ "let pi = document.createProcessingInstruction('foo', 'bar')", "undefined" },
        .{ "pi.target", "foo" },
        .{ "let pi2 = pi.cloneNode()", "undefined" },
    }, .{});

    try runner.testCases(&.{
        .{ "let nimp = document.getElementById('content')", "undefined" },
        .{ "var v = document.importNode(nimp)", "undefined" },
        .{ "v.nodeName", "DIV" },
    }, .{});

    try runner.testCases(&.{
        .{ "var v = document.createAttribute('foo')", "undefined" },
        .{ "v.nodeName", "foo" },
    }, .{});

    try runner.testCases(&.{
        .{ "document.children.length", "1" },
        .{ "document.children.item(0).nodeName", "HTML" },
        .{ "document.firstElementChild.nodeName", "HTML" },
        .{ "document.lastElementChild.nodeName", "HTML" },
        .{ "document.childElementCount", "1" },

        .{ "let nd = new Document()", "undefined" },
        .{ "nd.children.length", "0" },
        .{ "nd.children.item(0)", "null" },
        .{ "nd.firstElementChild", "null" },
        .{ "nd.lastElementChild", "null" },
        .{ "nd.childElementCount", "0" },

        .{ "let emptydoc = document.createElement('html')", "undefined" },
        .{ "emptydoc.prepend(document.createElement('html'))", "undefined" },

        .{ "let emptydoc2 = document.createElement('html')", "undefined" },
        .{ "emptydoc2.append(document.createElement('html'))", "undefined" },
    }, .{});

    try runner.testCases(&.{
        .{ "document.querySelector('')", "null" },
        .{ "document.querySelector('*').nodeName", "HTML" },
        .{ "document.querySelector('#content').id", "content" },
        .{ "document.querySelector('#para').id", "para" },
        .{ "document.querySelector('.ok').id", "link" },
        .{ "document.querySelector('a ~ p').id", "para-empty" },
        .{ "document.querySelector(':root').nodeName", "HTML" },

        .{ "document.querySelectorAll('p').length", "2" },
        .{
            \\  Array.from(document.querySelectorAll('#content > p#para-empty'))
            \\    .map(row => row.querySelector('span').textContent)
            \\    .length;
            ,
            "1",
        },

        .{ "document.querySelectorAll('.\\\\:popover-open').length", "0" },
        .{ "document.querySelectorAll('.foo\\\\:bar').length", "0" },
    }, .{});

    try runner.testCases(&.{
        .{ "document.activeElement === document.body", "true" },
        .{ "document.getElementById('link').focus()", "undefined" },
        .{ "document.activeElement === document.getElementById('link')", "true" },
    }, .{});

    try runner.testCases(&.{
        .{ "document.styleSheets.length", "0" },
    }, .{});

    // this test breaks the doc structure, keep it at the end of the test
    // suite.
    try runner.testCases(&.{
        .{ "let nadop = document.getElementById('content')", "undefined" },
        .{ "var v = document.adoptNode(nadop)", "undefined" },
        .{ "v.nodeName", "DIV" },
    }, .{});

    const Case = testing.JsRunner.Case;
    const tags = comptime parser.Tag.all();
    var createElements: [(tags.len) * 2]Case = undefined;
    inline for (tags, 0..) |tag, i| {
        const tag_name = @tagName(tag);
        createElements[i * 2] = Case{
            "var " ++ tag_name ++ "Elem = document.createElement('" ++ tag_name ++ "')",
            "undefined",
        };
        createElements[(i * 2) + 1] = Case{
            tag_name ++ "Elem.localName",
            tag_name,
        };
    }
    try runner.testCases(&createElements, .{});
}
