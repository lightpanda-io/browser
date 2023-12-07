const std = @import("std");

const parser = @import("../netsurf.zig");

const jsruntime = @import("jsruntime");
const Case = jsruntime.test_utils.Case;
const checkCases = jsruntime.test_utils.checkCases;

const Node = @import("node.zig").Node;

const collection = @import("html_collection.zig");

const Element = @import("element.zig").Element;
const ElementUnion = @import("element.zig").Union;

const DocumentType = @import("document_type.zig").DocumentType;
const DocumentFragment = @import("document_fragment.zig").DocumentFragment;
const DOMImplementation = @import("implementation.zig").DOMImplementation;

// WEB IDL https://dom.spec.whatwg.org/#document
pub const Document = struct {
    pub const Self = parser.Document;
    pub const prototype = *Node;
    pub const mem_guarantied = true;

    pub fn constructor() !*parser.Document {
        return try parser.domImplementationCreateHTMLDocument(null);
    }

    // JS funcs
    // --------
    pub fn get_implementation(_: *parser.Document) DOMImplementation {
        return DOMImplementation{};
    }

    pub fn get_documentElement(self: *parser.Document) !ElementUnion {
        const e = try parser.documentGetDocumentElement(self);
        return try Element.toInterface(e);
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

    pub fn _getElementById(self: *parser.Document, id: []const u8) !?ElementUnion {
        const e = try parser.documentGetElementById(self, id) orelse return null;
        return try Element.toInterface(e);
    }

    pub fn _createElement(self: *parser.Document, tag_name: []const u8) !ElementUnion {
        const e = try parser.documentCreateElement(self, tag_name);
        return try Element.toInterface(e);
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
        alloc: std.mem.Allocator,
        tag_name: []const u8,
    ) !collection.HTMLCollection {
        const root = try parser.documentGetDocumentElement(self);
        return try collection.HTMLCollectionByTagName(
            alloc,
            parser.elementToNode(root),
            tag_name,
        );
    }

    pub fn _getElementsByClassName(
        self: *parser.Document,
        alloc: std.mem.Allocator,
        classNames: []const u8,
    ) !collection.HTMLCollection {
        const root = try parser.documentGetDocumentElement(self);
        return try collection.HTMLCollectionByClassName(
            alloc,
            parser.elementToNode(root),
            classNames,
        );
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

    pub fn _importNode(self: *parser.Document, node: *parser.Node, deep: ?bool) !*parser.Node {
        return try parser.documentImportNode(self, node, deep orelse false);
    }

    pub fn _adoptNode(self: *parser.Document, node: *parser.Node) !*parser.Node {
        return try parser.documentAdoptNode(self, node);
    }

    pub fn _createAttribute(self: *parser.Document, name: []const u8) !*parser.Attribute {
        return try parser.documentCreateAttribute(self, name);
    }

    pub fn _createAttributeNS(self: *parser.Document, ns: []const u8, qname: []const u8) !*parser.Attribute {
        return try parser.documentCreateAttributeNS(self, ns, qname);
    }

    pub fn deinit(_: *parser.Document, _: std.mem.Allocator) void {}
};

// Tests
// -----

pub fn testExecFn(
    _: std.mem.Allocator,
    js_env: *jsruntime.Env,
    comptime _: []jsruntime.API,
) !void {
    var constructor = [_]Case{
        .{ .src = "document.__proto__.__proto__.constructor.name", .ex = "Document" },
        .{ .src = "document.__proto__.__proto__.__proto__.constructor.name", .ex = "Node" },
        .{ .src = "document.__proto__.__proto__.__proto__.__proto__.constructor.name", .ex = "EventTarget" },
    };
    try checkCases(js_env, &constructor);

    var getElementById = [_]Case{
        .{ .src = "let getElementById = document.getElementById('content')", .ex = "undefined" },
        .{ .src = "getElementById.constructor.name", .ex = "HTMLDivElement" },
        .{ .src = "getElementById.localName", .ex = "div" },
    };
    try checkCases(js_env, &getElementById);

    var getElementsByTagName = [_]Case{
        .{ .src = "let getElementsByTagName = document.getElementsByTagName('p')", .ex = "undefined" },
        .{ .src = "getElementsByTagName.length", .ex = "2" },
        .{ .src = "getElementsByTagName.item(0).localName", .ex = "p" },
        .{ .src = "getElementsByTagName.item(1).localName", .ex = "p" },
        .{ .src = "let getElementsByTagNameAll = document.getElementsByTagName('*')", .ex = "undefined" },
        .{ .src = "getElementsByTagNameAll.length", .ex = "8" },
        .{ .src = "getElementsByTagNameAll.item(0).localName", .ex = "html" },
        .{ .src = "getElementsByTagNameAll.item(7).localName", .ex = "p" },
        .{ .src = "getElementsByTagNameAll.namedItem('para-empty-child').localName", .ex = "span" },
    };
    try checkCases(js_env, &getElementsByTagName);

    var getElementsByClassName = [_]Case{
        .{ .src = "let ok = document.getElementsByClassName('ok')", .ex = "undefined" },
        .{ .src = "ok.length", .ex = "2" },
        .{ .src = "let empty = document.getElementsByClassName('empty')", .ex = "undefined" },
        .{ .src = "empty.length", .ex = "1" },
        .{ .src = "let emptyok = document.getElementsByClassName('empty ok')", .ex = "undefined" },
        .{ .src = "emptyok.length", .ex = "1" },
    };
    try checkCases(js_env, &getElementsByClassName);

    var getDocumentElement = [_]Case{
        .{ .src = "let e = document.documentElement", .ex = "undefined" },
        .{ .src = "e.localName", .ex = "html" },
    };
    try checkCases(js_env, &getDocumentElement);

    var getCharacterSet = [_]Case{
        .{ .src = "document.characterSet", .ex = "UTF-8" },
        .{ .src = "document.charset", .ex = "UTF-8" },
        .{ .src = "document.inputEncoding", .ex = "UTF-8" },
    };
    try checkCases(js_env, &getCharacterSet);

    var getCompatMode = [_]Case{
        .{ .src = "document.compatMode", .ex = "CSS1Compat" },
    };
    try checkCases(js_env, &getCompatMode);

    var getContentType = [_]Case{
        .{ .src = "document.contentType", .ex = "text/html" },
    };
    try checkCases(js_env, &getContentType);

    var getDocumentURI = [_]Case{
        .{ .src = "document.documentURI", .ex = "about:blank" },
        .{ .src = "document.URL", .ex = "about:blank" },
    };
    try checkCases(js_env, &getDocumentURI);

    var getImplementation = [_]Case{
        .{ .src = "let impl = document.implementation", .ex = "undefined" },
    };
    try checkCases(js_env, &getImplementation);

    var new = [_]Case{
        .{ .src = "let d = new Document()", .ex = "undefined" },
        .{ .src = "d.characterSet", .ex = "UTF-8" },
        .{ .src = "d.URL", .ex = "about:blank" },
        .{ .src = "d.documentURI", .ex = "about:blank" },
        .{ .src = "d.compatMode", .ex = "CSS1Compat" },
        .{ .src = "d.contentType", .ex = "text/html" },
    };
    try checkCases(js_env, &new);

    var createDocumentFragment = [_]Case{
        .{ .src = "document.createDocumentFragment()", .ex = "[object DocumentFragment]" },
    };
    try checkCases(js_env, &createDocumentFragment);

    var createTextNode = [_]Case{
        .{ .src = "document.createTextNode('foo')", .ex = "[object Text]" },
    };
    try checkCases(js_env, &createTextNode);

    var createCDATASection = [_]Case{
        .{ .src = "document.createCDATASection('foo')", .ex = "[object CDATASection]" },
    };
    try checkCases(js_env, &createCDATASection);

    var createComment = [_]Case{
        .{ .src = "document.createComment('foo')", .ex = "[object Comment]" },
    };
    try checkCases(js_env, &createComment);

    var createProcessingInstruction = [_]Case{
        .{ .src = "let pi = document.createProcessingInstruction('foo', 'bar')", .ex = "undefined" },
        .{ .src = "pi.target", .ex = "foo" },
    };
    try checkCases(js_env, &createProcessingInstruction);

    var importNode = [_]Case{
        .{ .src = "let nimp = document.getElementById('content')", .ex = "undefined" },
        .{ .src = "document.importNode(nimp)", .ex = "[object Node]" },
    };
    try checkCases(js_env, &importNode);

    var adoptNode = [_]Case{
        .{ .src = "let nadop = document.getElementById('content')", .ex = "undefined" },
        .{ .src = "document.adoptNode(nadop)", .ex = "[object Node]" },
    };
    try checkCases(js_env, &adoptNode);

    var createAttr = [_]Case{
        .{ .src = "document.createAttribute('foo')", .ex = "[object Attr]" },
    };
    try checkCases(js_env, &createAttr);

    const tags = comptime parser.Tag.all();
    comptime var createElements: [(tags.len) * 2]Case = undefined;
    inline for (tags, 0..) |tag, i| {
        const tag_name = @tagName(tag);
        createElements[i * 2] = Case{
            .src = "var " ++ tag_name ++ "Elem = document.createElement('" ++ tag_name ++ "')",
            .ex = "undefined",
        };
        createElements[(i * 2) + 1] = Case{
            .src = tag_name ++ "Elem.localName",
            .ex = tag_name,
        };
    }
    try checkCases(js_env, &createElements);
}
