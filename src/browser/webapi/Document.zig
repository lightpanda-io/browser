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
const String = @import("../../string.zig").String;

const js = @import("../js/js.zig");
const Page = @import("../Page.zig");
const URL = @import("../URL.zig");

const Node = @import("Node.zig");
const Element = @import("Element.zig");
const Location = @import("Location.zig");
const Parser = @import("../parser/Parser.zig");
const collections = @import("collections.zig");
const Selector = @import("selector/Selector.zig");
const NodeFilter = @import("NodeFilter.zig");
const DocumentType = @import("DocumentType.zig");
const DOMTreeWalker = @import("DOMTreeWalker.zig");
const DOMNodeIterator = @import("DOMNodeIterator.zig");
const DOMImplementation = @import("DOMImplementation.zig");
const StyleSheetList = @import("css/StyleSheetList.zig");

pub const XMLDocument = @import("XMLDocument.zig");
pub const HTMLDocument = @import("HTMLDocument.zig");

const Document = @This();

_type: Type,
_proto: *Node,
_location: ?*Location = null,
_ready_state: ReadyState = .loading,
_current_script: ?*Element.Html.Script = null,
_elements_by_id: std.StringHashMapUnmanaged(*Element) = .empty,
_active_element: ?*Element = null,
_style_sheets: ?*StyleSheetList = null,
_write_insertion_point: ?*Node = null,
_script_created_parser: ?Parser.Streaming = null,
_adopted_style_sheets: ?js.Object = null,

pub const Type = union(enum) {
    generic,
    html: *HTMLDocument,
    xml: *XMLDocument,
};

pub fn is(self: *Document, comptime T: type) ?*T {
    switch (self._type) {
        .html => |html| {
            if (T == HTMLDocument) {
                return html;
            }
        },
        .xml => |xml| {
            if (T == XMLDocument) {
                return xml;
            }
        },
        .generic => {},
    }
    return null;
}

pub fn as(self: *Document, comptime T: type) *T {
    return self.is(T).?;
}

pub fn asNode(self: *Document) *Node {
    return self._proto;
}

pub fn asEventTarget(self: *Document) *@import("EventTarget.zig") {
    return self._proto.asEventTarget();
}

pub fn getURL(_: *const Document, page: *const Page) [:0]const u8 {
    return page.url;
}

pub fn getContentType(self: *const Document) []const u8 {
    return switch (self._type) {
        .html => "text/html",
        .xml => "application/xml",
        .generic => "application/xml",
    };
}

pub fn getCharacterSet(_: *const Document) []const u8 {
    return "UTF-8";
}

pub fn getCompatMode(_: *const Document) []const u8 {
    return "CSS1Compat";
}

pub fn getReferrer(_: *const Document) []const u8 {
    return "";
}

pub fn getDomain(_: *const Document, page: *const Page) []const u8 {
    return URL.getHostname(page.url);
}

const CreateElementOptions = struct {
    is: ?[]const u8 = null,
};

pub fn createElement(_: *const Document, name: []const u8, options_: ?CreateElementOptions, page: *Page) !*Element {
    const node = try page.createElement(null, name, null);
    const element = node.as(Element);

    const options = options_ orelse return element;
    if (options.is) |is_value| {
        try element.setAttribute("is", is_value, page);
        try Element.Html.Custom.checkAndAttachBuiltIn(element, page);
    }

    return element;
}

pub fn createElementNS(_: *const Document, namespace: ?[]const u8, name: []const u8, page: *Page) !*Element {
    const node = try page.createElement(namespace, name, null);
    return node.as(Element);
}

pub fn createAttribute(_: *const Document, name: []const u8, page: *Page) !?*Element.Attribute {
    try Element.Attribute.validateAttributeName(name);
    return page._factory.node(Element.Attribute{
        ._proto = undefined,
        ._name = try page.dupeString(name),
        ._value = "",
        ._element = null,
    });
}

pub fn getElementById(self: *const Document, id_: ?[]const u8) ?*Element {
    const id = id_ orelse return null;
    return self._elements_by_id.get(id);
}

const GetElementsByTagNameResult = union(enum) {
    tag: collections.NodeLive(.tag),
    tag_name: collections.NodeLive(.tag_name),
    all_elements: collections.NodeLive(.all_elements),
};
pub fn getElementsByTagName(self: *Document, tag_name: []const u8, page: *Page) !GetElementsByTagNameResult {
    if (tag_name.len > 256) {
        // 256 seems generous.
        return error.InvalidTagName;
    }

    if (std.mem.eql(u8, tag_name, "*")) {
        return .{
            .all_elements = collections.NodeLive(.all_elements).init(self.asNode(), {}, page),
        };
    }

    const lower = std.ascii.lowerString(&page.buf, tag_name);
    if (Node.Element.Tag.parseForMatch(lower)) |known| {
        // optimized for known tag names, comparis
        return .{
            .tag = collections.NodeLive(.tag).init(self.asNode(), known, page),
        };
    }

    const arena = page.arena;
    const filter = try String.init(arena, lower, .{});
    return .{ .tag_name = collections.NodeLive(.tag_name).init(self.asNode(), filter, page) };
}

pub fn getElementsByClassName(self: *Document, class_name: []const u8, page: *Page) !collections.NodeLive(.class_name) {
    const arena = page.arena;

    // Parse space-separated class names
    var class_names: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeAny(u8, class_name, &std.ascii.whitespace);
    while (it.next()) |name| {
        try class_names.append(arena, try page.dupeString(name));
    }

    return collections.NodeLive(.class_name).init(self.asNode(), class_names.items, page);
}

pub fn getElementsByName(self: *Document, name: []const u8, page: *Page) !collections.NodeLive(.name) {
    const arena = page.arena;
    const filter = try arena.dupe(u8, name);
    return collections.NodeLive(.name).init(self.asNode(), filter, page);
}

pub fn getChildren(self: *Document, page: *Page) !collections.NodeLive(.child_elements) {
    return collections.NodeLive(.child_elements).init(self.asNode(), {}, page);
}

pub fn getDocumentElement(self: *Document) ?*Element {
    var child = self.asNode().firstChild();
    while (child) |node| {
        if (node.is(Element)) |el| {
            return el;
        }
        child = node.nextSibling();
    }
    return null;
}

pub fn querySelector(self: *Document, input: []const u8, page: *Page) !?*Element {
    return Selector.querySelector(self.asNode(), input, page);
}

pub fn querySelectorAll(self: *Document, input: []const u8, page: *Page) !*Selector.List {
    return Selector.querySelectorAll(self.asNode(), input, page);
}

pub fn className(self: *const Document) []const u8 {
    return switch (self._type) {
        .generic => "[object Document]",
        .html => "[object HTMLDocument]",
        .xml => "[object XMLDocument]",
    };
}

pub fn getImplementation(_: *const Document) DOMImplementation {
    return .{};
}

pub fn createDocumentFragment(_: *const Document, page: *Page) !*Node.DocumentFragment {
    return Node.DocumentFragment.init(page);
}

pub fn createComment(_: *const Document, data: []const u8, page: *Page) !*Node {
    return page.createComment(data);
}

pub fn createTextNode(_: *const Document, data: []const u8, page: *Page) !*Node {
    return page.createTextNode(data);
}

pub fn createCDATASection(self: *const Document, data: []const u8, page: *Page) !*Node {
    switch (self._type) {
        .html => return error.NotSupported,  // cannot create a CDataSection in an HTMLDocument
        .xml => return page.createCDATASection(data),
        .generic => return page.createCDATASection(data),
    }
}

pub fn createProcessingInstruction(_: *const Document, target: []const u8, data: []const u8, page: *Page) !*Node {
    return page.createProcessingInstruction(target, data);
}

const Range = @import("Range.zig");
pub fn createRange(_: *const Document, page: *Page) !*Range {
    return Range.init(page);
}

pub fn createEvent(_: *const Document, event_type: []const u8, page: *Page) !*@import("Event.zig") {
    const Event = @import("Event.zig");

    if (std.ascii.eqlIgnoreCase(event_type, "event") or std.ascii.eqlIgnoreCase(event_type, "events") or std.ascii.eqlIgnoreCase(event_type, "htmlevents")) {
        return Event.init("", null, page);
    }

    if (std.ascii.eqlIgnoreCase(event_type, "customevent") or std.ascii.eqlIgnoreCase(event_type, "customevents")) {
        const CustomEvent = @import("event/CustomEvent.zig");
        const custom_event = try CustomEvent.init("", null, page);
        return custom_event.asEvent();
    }

    if (std.ascii.eqlIgnoreCase(event_type, "messageevent")) {
        return error.NotSupported;
    }

    return error.NotSupported;
}

pub fn createTreeWalker(_: *const Document, root: *Node, what_to_show: ?u32, filter: ?DOMTreeWalker.FilterOpts, page: *Page) !*DOMTreeWalker {
    const show = what_to_show orelse NodeFilter.SHOW_ALL;
    return DOMTreeWalker.init(root, show, filter, page);
}

pub fn createNodeIterator(_: *const Document, root: *Node, what_to_show: ?u32, filter: ?DOMNodeIterator.FilterOpts, page: *Page) !*DOMNodeIterator {
    const show = what_to_show orelse NodeFilter.SHOW_ALL;
    return DOMNodeIterator.init(root, show, filter, page);
}

pub fn getReadyState(self: *const Document) []const u8 {
    return @tagName(self._ready_state);
}

pub fn getActiveElement(self: *Document) ?*Element {
    if (self._active_element) |el| {
        return el;
    }

    // Default to body if it exists
    if (self.is(HTMLDocument)) |html_doc| {
        if (html_doc.getBody()) |body| {
            return body.asElement();
        }
    }

    // Fallback to document element
    return self.getDocumentElement();
}

pub fn getStyleSheets(self: *Document, page: *Page) !*StyleSheetList {
    if (self._style_sheets) |sheets| {
        return sheets;
    }
    const sheets = try StyleSheetList.init(page);
    self._style_sheets = sheets;
    return sheets;
}

pub fn adoptNode(_: *const Document, node: *Node, page: *Page) !*Node {
    if (node._type == .document) {
        return error.NotSupported;
    }

    if (node._parent) |parent| {
        page.removeNode(parent, node, .{ .will_be_reconnected = false });
    }

    return node;
}

pub fn importNode(_: *const Document, node: *Node, deep_: ?bool, page: *Page) !*Node {
    if (node._type == .document) {
        return error.NotSupported;
    }

    return node.cloneNode(deep_, page);
}

pub fn append(self: *Document, nodes: []const Node.NodeOrText, page: *Page) !void {
    const parent = self.asNode();
    for (nodes) |node_or_text| {
        const child = try node_or_text.toNode(page);
        _ = try parent.appendChild(child, page);
    }
}

pub fn prepend(self: *Document, nodes: []const Node.NodeOrText, page: *Page) !void {
    const parent = self.asNode();
    var i = nodes.len;
    while (i > 0) {
        i -= 1;
        const child = try nodes[i].toNode(page);
        _ = try parent.insertBefore(child, parent.firstChild(), page);
    }
}

pub fn elementFromPoint(self: *Document, x: f64, y: f64, page: *Page) !?*Element {
    // Traverse document in depth-first order to find the topmost (last in document order)
    // element that contains the point (x, y)
    var topmost: ?*Element = null;

    const root = self.asNode();
    var stack: std.ArrayList(*Node) = .empty;
    try stack.append(page.call_arena, root);

    while (stack.items.len > 0) {
        const node = stack.pop() orelse break;
        if (node.is(Element)) |element| {
            if (try element.checkVisibility(page)) {
                const rect = try element.getBoundingClientRect(page);
                if (x >= rect._left and x <= rect._right and y >= rect._top and y <= rect._bottom) {
                    topmost = element;
                }
            }
        }

        // Add children to stack in reverse order so we process them in document order
        var child = node.lastChild();
        while (child) |c| {
            try stack.append(page.call_arena, c);
            child = c.previousSibling();
        }
    }

    return topmost;
}

pub fn elementsFromPoint(self: *Document, x: f64, y: f64, page: *Page) ![]const *Element {
    // Get topmost element
    var current: ?*Element = (try self.elementFromPoint(x, y, page)) orelse return &.{};
    var result: std.ArrayList(*Element) = .empty;
    while (current) |el| {
        try result.append(page.call_arena, el);
        current = el.parentElement();
    }
    return result.items;
}

pub fn getDocType(_: *const Document) ?*DocumentType {
    return null;
}

pub fn write(self: *Document, text: []const []const u8, page: *Page) !void {
    if (self._type == .xml) {
        return error.InvalidStateError;
    }

    const html = blk: {
        var joined: std.ArrayList(u8) = .empty;
        for (text) |str| {
            try joined.appendSlice(page.call_arena, str);
        }
        break :blk joined.items;
    };

    if (self._current_script == null or page._load_state != .parsing) {
        // Post-parsing (destructive behavior)
        if (self._script_created_parser == null) {
            _ = try self.open(page);
        }
        if (html.len > 0) {
            self._script_created_parser.?.read(html);
        }
        return;
    }

    // Inline script during parsing
    const script = self._current_script.?;
    const parent = script.asNode().parentNode() orelse return;

    // Our implemnetation is hacky. We'll write to a DocumentFragment, then
    // append its children.
    const fragment = try Node.DocumentFragment.init(page);
    const fragment_node = fragment.asNode();

    const previous_parse_mode = page._parse_mode;
    page._parse_mode = .document_write;
    defer page._parse_mode = previous_parse_mode;

    var parser = Parser.init(page.call_arena, fragment_node, page);
    parser.parseFragment(html);

    // Extract children from wrapper HTML element (html5ever wraps fragments)
    // https://github.com/servo/html5ever/issues/583
    const children = fragment_node._children orelse return;
    const first = children.first();

    // Collect all children to insert (to avoid iterator invalidation)
    var children_to_insert: std.ArrayList(*Node) = .empty;

    var it = if (first.is(Element.Html.Html) == null) fragment_node.childrenIterator() else first.childrenIterator();
    while (it.next()) |child| {
        try children_to_insert.append(page.call_arena, child);
    }

    if (children_to_insert.items.len == 0) {
        return;
    }

    // Determine insertion point:
    // - If _write_insertion_point is set, continue from there (subsequent write)
    // - Otherwise, start after the script (first write)
    var insert_after: ?*Node = self._write_insertion_point orelse script.asNode();

    for (children_to_insert.items) |child| {
        // Clear parent pointer (child is currently parented to fragment/HTML wrapper)
        child._parent = null;
        try page.insertNodeRelative(parent, child, .{ .after = insert_after.? }, .{});
        insert_after = child;
    }

    page.domChanged();
    self._write_insertion_point = children_to_insert.getLast();
}

pub fn open(self: *Document, page: *Page) !*Document {
    if (self._type == .xml) {
        return error.InvalidStateError;
    }

    if (page._load_state == .parsing) {
        return self;
    }

    if (self._script_created_parser != null) {
        return self;
    }

    // If we aren't parsing, then open clears the document.
    const doc_node = self.asNode();

    {
        // Remove all children from document
        var it = doc_node.childrenIterator();
        while (it.next()) |child| {
            page.removeNode(doc_node, child, .{ .will_be_reconnected = false });
        }
    }

    // reset the document
    self._elements_by_id.clearAndFree(page.arena);
    self._active_element = null;
    self._style_sheets = null;
    self._ready_state = .loading;

    self._script_created_parser = Parser.Streaming.init(page.arena, doc_node, page);
    try self._script_created_parser.?.start();
    page._parse_mode = .document;

    return self;
}

pub fn close(self: *Document, page: *Page) !void {
    if (self._type == .xml) {
        return error.InvalidStateError;
    }

    if (self._script_created_parser == null) {
        return;
    }

    // done() calls html5ever_streaming_parser_finish which frees the parser
    // We must NOT call deinit() after done() as that would be a double-free
    self._script_created_parser.?.done();
    // Just null out the handle since done() already freed it
    self._script_created_parser.?.handle = null;
    self._script_created_parser = null;

    page.documentIsComplete();
}

pub fn getFirstElementChild(self: *Document) ?*Element {
    var it = self.asNode().childrenIterator();
    while (it.next()) |child| {
        if (child.is(Element)) |el| {
            return el;
        }
    }
    return null;
}

pub fn getLastElementChild(self: *Document) ?*Element {
    var maybe_child = self.asNode().lastChild();
    while (maybe_child) |child| {
        if (child.is(Element)) |el| {
            return el;
        }
        maybe_child = child.previousSibling();
    }
    return null;
}

pub fn getChildElementCount(self: *Document) u32 {
    var i: u32 = 0;
    var it = self.asNode().childrenIterator();
    while (it.next()) |child| {
        if (child.is(Element) != null) {
            i += 1;
        }
    }
    return i;
}

 pub fn getAdoptedStyleSheets(self: *Document, page: *Page) !js.Object {
    if (self._adopted_style_sheets) |ass| {
        return ass;
    }
    const obj = try page.js.createArray(0).persist();
    self._adopted_style_sheets = obj;
    return obj;
}

pub fn setAdoptedStyleSheets(self: *Document, sheets: js.Object) !void {
    self._adopted_style_sheets = try sheets.persist();
}

const ReadyState = enum {
    loading,
    interactive,
    complete,
};

pub const JsApi = struct {
    pub const bridge = js.Bridge(Document);

    pub const Meta = struct {
        pub const name = "Document";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(_constructor, .{});
    fn _constructor(page: *Page) !*Document {
        return page._factory.node(Document{
            ._proto = undefined,
            ._type = .generic,
        });
    }

    pub const URL = bridge.accessor(Document.getURL, null, .{});
    pub const documentURI = bridge.accessor(Document.getURL, null, .{});
    pub const documentElement = bridge.accessor(Document.getDocumentElement, null, .{});
    pub const children = bridge.accessor(Document.getChildren, null, .{});
    pub const readyState = bridge.accessor(Document.getReadyState, null, .{});
    pub const implementation = bridge.accessor(Document.getImplementation, null, .{});
    pub const activeElement = bridge.accessor(Document.getActiveElement, null, .{});
    pub const styleSheets = bridge.accessor(Document.getStyleSheets, null, .{});
    pub const contentType = bridge.accessor(Document.getContentType, null, .{});
    pub const characterSet = bridge.accessor(Document.getCharacterSet, null, .{});
    pub const charset = bridge.accessor(Document.getCharacterSet, null, .{});
    pub const inputEncoding = bridge.accessor(Document.getCharacterSet, null, .{});
    pub const compatMode = bridge.accessor(Document.getCompatMode, null, .{});
    pub const referrer = bridge.accessor(Document.getReferrer, null, .{});
    pub const domain = bridge.accessor(Document.getDomain, null, .{});
    pub const createElement = bridge.function(Document.createElement, .{});
    pub const createElementNS = bridge.function(Document.createElementNS, .{});
    pub const createDocumentFragment = bridge.function(Document.createDocumentFragment, .{});
    pub const createComment = bridge.function(Document.createComment, .{});
    pub const createTextNode = bridge.function(Document.createTextNode, .{});
    pub const createAttribute = bridge.function(Document.createAttribute, .{ .dom_exception = true });
    pub const createCDATASection = bridge.function(Document.createCDATASection, .{ .dom_exception = true });
    pub const createProcessingInstruction = bridge.function(Document.createProcessingInstruction, .{ .dom_exception = true });
    pub const createRange = bridge.function(Document.createRange, .{});
    pub const createEvent = bridge.function(Document.createEvent, .{ .dom_exception = true });
    pub const createTreeWalker = bridge.function(Document.createTreeWalker, .{});
    pub const createNodeIterator = bridge.function(Document.createNodeIterator, .{});
    pub const getElementById = bridge.function(Document.getElementById, .{});
    pub const querySelector = bridge.function(Document.querySelector, .{ .dom_exception = true });
    pub const querySelectorAll = bridge.function(Document.querySelectorAll, .{ .dom_exception = true });
    pub const getElementsByTagName = bridge.function(Document.getElementsByTagName, .{});
    pub const getElementsByClassName = bridge.function(Document.getElementsByClassName, .{});
    pub const getElementsByName = bridge.function(Document.getElementsByName, .{});
    pub const adoptNode = bridge.function(Document.adoptNode, .{ .dom_exception = true });
    pub const importNode = bridge.function(Document.importNode, .{ .dom_exception = true });
    pub const append = bridge.function(Document.append, .{});
    pub const prepend = bridge.function(Document.prepend, .{});
    pub const elementFromPoint = bridge.function(Document.elementFromPoint, .{});
    pub const elementsFromPoint = bridge.function(Document.elementsFromPoint, .{});
    pub const write = bridge.function(Document.write, .{ .dom_exception = true });
    pub const open = bridge.function(Document.open, .{ .dom_exception = true });
    pub const close = bridge.function(Document.close, .{ .dom_exception = true });
    pub const doctype = bridge.accessor(Document.getDocType, null, .{});
    pub const firstElementChild = bridge.accessor(Document.getFirstElementChild, null, .{});
    pub const lastElementChild = bridge.accessor(Document.getLastElementChild, null, .{});
    pub const childElementCount = bridge.accessor(Document.getChildElementCount, null, .{});
    pub const adoptedStyleSheets = bridge.accessor(Document.getAdoptedStyleSheets, Document.setAdoptedStyleSheets, .{});

    pub const defaultView = bridge.accessor(struct {
        fn defaultView(_: *const Document, page: *Page) *@import("Window.zig") {
            return page.window;
        }
    }.defaultView, null, .{ .cache = "defaultView" });
};

const testing = @import("../../testing.zig");
test "WebApi: Document" {
    try testing.htmlRunner("document", .{});
}
