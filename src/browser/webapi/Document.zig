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
const collections = @import("collections.zig");
const Selector = @import("selector/Selector.zig");
const NodeFilter = @import("NodeFilter.zig");
const DOMTreeWalker = @import("DOMTreeWalker.zig");
const DOMNodeIterator = @import("DOMNodeIterator.zig");
const DOMImplementation = @import("DOMImplementation.zig");
const StyleSheetList = @import("css/StyleSheetList.zig");

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

pub const Type = union(enum) {
    generic,
    html: *HTMLDocument,
};

pub fn is(self: *Document, comptime T: type) ?*T {
    switch (self._type) {
        .html => |html| {
            if (T == HTMLDocument) {
                return html;
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

    // Handle wildcard '*' - return all elements
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
    };
}

pub fn getImplementation(_: *const Document) DOMImplementation {
    return .{};
}

pub fn createDocumentFragment(_: *const Document, page: *Page) !*@import("DocumentFragment.zig") {
    return @import("DocumentFragment.zig").init(page);
}

pub fn createComment(_: *const Document, data: []const u8, page: *Page) !*Node {
    return page.createComment(data);
}

pub fn createTextNode(_: *const Document, data: []const u8, page: *Page) !*Node {
    return page.createTextNode(data);
}

pub fn createCDATASection(self: *const Document, data: []const u8, page: *Page) !*Node {
    switch (self._type) {
        .html => return error.NotSupported,
        .generic => return page.createCDATASection(data),
    }
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
