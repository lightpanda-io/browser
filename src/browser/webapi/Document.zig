const std = @import("std");
const String = @import("../../string.zig").String;

const js = @import("../js/js.zig");
const Page = @import("../Page.zig");

const Node = @import("Node.zig");
const Element = @import("Element.zig");
const Location = @import("Location.zig");
const collections = @import("collections.zig");
const Selector = @import("selector/Selector.zig");
const NodeFilter = @import("NodeFilter.zig");
const DOMTreeWalker = @import("DOMTreeWalker.zig");
const DOMNodeIterator = @import("DOMNodeIterator.zig");

const Document = @This();

_proto: *Node,
_location: ?*Location = null,
_ready_state: ReadyState = .loading,
_current_script: ?*Element.Html.Script = null,
_elements_by_id: std.StringHashMapUnmanaged(*Element) = .empty,

pub fn asNode(self: *Document) *Node {
    return self._proto;
}

pub fn asEventTarget(self: *Document) *@import("EventTarget.zig") {
    return self._proto.asEventTarget();
}

pub fn getURL(_: *const Document, page: *const Page) [:0]const u8 {
    return page.url;
}

pub fn getReadyState(self: *const Document) []const u8 {
    return @tagName(self._ready_state);
}

pub fn getCurrentScript(self: *const Document) ?*Element.Html.Script {
    return self._current_script;
}

pub fn createElement(_: *const Document, name: []const u8, page: *Page) !*Element {
    const node = try page.createElement(null, name, null);
    return node.as(Element);
}

pub fn createElementNS(_: *const Document, namespace: ?[]const u8, name: []const u8, page: *Page) !*Element {
    const node = try page.createElement(namespace, name, null);
    return node.as(Element);
}

pub fn getElementById(self: *const Document, id_: ?[]const u8) ?*Element {
    const id = id_ orelse return null;
    return self._elements_by_id.get(id);
}

const GetElementsByTagNameResult = union(enum) {
    tag: collections.NodeLive(.tag),
    tag_name: collections.NodeLive(.tag_name),
};
pub fn getElementsByTagName(self: *Document, tag_name: []const u8, page: *Page) !GetElementsByTagNameResult {
    if (tag_name.len > 256) {
        // 256 seems generous.
        return error.InvalidTagName;
    }

    const lower = std.ascii.lowerString(&page.buf, tag_name);
    if (Node.Element.Tag.parseForMatch(lower)) |known| {
        // optimized for known tag names, comparis
        return .{
            .tag = try collections.NodeLive(.tag).init(null, self.asNode(), known, page),
        };
    }

    const arena = page.arena;
    const filter = try String.init(arena, lower, .{});
    return .{ .tag_name = try collections.NodeLive(.tag_name).init(arena, self.asNode(), filter, page) };
}

pub fn getElementsByClassName(self: *Document, class_name: []const u8, page: *Page) !collections.NodeLive(.class_name) {
    const arena = page.arena;
    const filter = try arena.dupe(u8, class_name);
    return collections.NodeLive(.class_name).init(arena, self.asNode(), filter, page);
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

pub fn getImages(self: *Document, page: *Page) !collections.NodeLive(.tag) {
    return collections.NodeLive(.tag).init(null, self.asNode(), .img, page);
}

pub fn getScripts(self: *Document, page: *Page) !collections.NodeLive(.tag) {
    return collections.NodeLive(.tag).init(null, self.asNode(), .script, page);
}

pub fn getForms(self: *Document, page: *Page) !collections.NodeLive(.tag) {
    return collections.NodeLive(.tag).init(null, self.asNode(), .form, page);
}

pub fn getLinks(self: *Document, page: *Page) !collections.NodeLive(.tag) {
    return collections.NodeLive(.tag).init(null, self.asNode(), .anchor, page);
}

pub fn getHead(self: *Document) ?*Element.Html.Head {
    const doc_el = self.getDocumentElement() orelse return null;
    var child = doc_el.asNode().firstChild();
    while (child) |node| {
        if (node.is(Element.Html.Head)) |head| {
            return head;
        }
        child = node.nextSibling();
    }
    return null;
}

pub fn getBody(self: *Document) ?*Element.Html.Body {
    const doc_el = self.getDocumentElement() orelse return null;
    var child = doc_el.asNode().firstChild();
    while (child) |node| {
        if (node.is(Element.Html.Body)) |body| {
            return body;
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

pub fn className(_: *const Document) []const u8 {
    return "[object Document]";
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

pub fn getLocation(self: *const Document) ?*Location {
    return self._location;
}

// @ZIGDOM what_to_show tristate (null vs undefined vs value)
pub fn createTreeWalker(_: *const Document, root: *Node, what_to_show: ?u32, filter: ?DOMTreeWalker.FilterOpts, page: *Page) !*DOMTreeWalker {
    const show = what_to_show orelse NodeFilter.SHOW_ALL;
    return DOMTreeWalker.init(root, show, filter, page);
}

 // @ZIGDOM what_to_show tristate (null vs undefined vs value)
pub fn createNodeIterator(_: *const Document, root: *Node, what_to_show: ?u32, filter: ?DOMNodeIterator.FilterOpts, page: *Page) !*DOMNodeIterator {
    const show = what_to_show orelse NodeFilter.SHOW_ALL;
    return DOMNodeIterator.init(root, show, filter, page);
}

pub fn getTitle(self: *Document, page: *Page) ![]const u8 {
    const head = self.getHead() orelse return "";
    var it = head.asNode().childrenIterator();
    while (it.next()) |node| {
        if (node.is(Element.Html.Title)) |title| {
            var buf = std.Io.Writer.Allocating.init(page.call_arena);
            try title.asElement().getInnerText(&buf.writer);
            return buf.written();
        }
    }
    return "";
}

pub fn setTitle(self: *Document, title: []const u8, page: *Page) !void {
    const head = self.getHead() orelse return;
    var it = head.asNode().childrenIterator();
    while (it.next()) |node| {
        if (node.is(Element.Html.Title)) |title_element| {
            return title_element.asElement().replaceChildren(&.{.{ .text = title }}, page);
        }
    }
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
        pub var class_index: u16 = 0;
    };

    pub const constructor = bridge.constructor(_constructor, .{});
    fn _constructor(page: *Page) !*Document {
        return page._factory.node(Document{ ._proto = undefined });
    }

    pub const URL = bridge.accessor(Document.getURL, null, .{});
    pub const currentScript = bridge.accessor(Document.getCurrentScript, null, .{});
    pub const head = bridge.accessor(Document.getHead, null, .{});
    pub const body = bridge.accessor(Document.getBody, null, .{});
    pub const title = bridge.accessor(Document.getTitle, Document.setTitle, .{});
    pub const documentElement = bridge.accessor(Document.getDocumentElement, null, .{});
    pub const images = bridge.accessor(Document.getImages, null, .{});
    pub const scripts = bridge.accessor(Document.getScripts, null, .{});
    pub const links = bridge.accessor(Document.getLinks, null, .{});
    pub const forms = bridge.accessor(Document.getForms, null, .{});
    pub const location = bridge.accessor(Document.getLocation, null, .{ .cache = "location" });
    pub const readyState = bridge.accessor(Document.getReadyState, null, .{});

    pub const createElement = bridge.function(Document.createElement, .{});
    pub const createElementNS = bridge.function(Document.createElementNS, .{});
    pub const createDocumentFragment = bridge.function(Document.createDocumentFragment, .{});
    pub const createComment = bridge.function(Document.createComment, .{});
    pub const createTextNode = bridge.function(Document.createTextNode, .{});
    pub const createTreeWalker = bridge.function(Document.createTreeWalker, .{});
    pub const createNodeIterator = bridge.function(Document.createNodeIterator, .{});
    pub const getElementById = bridge.function(Document.getElementById, .{});
    pub const querySelector = bridge.function(Document.querySelector, .{ .dom_exception = true });
    pub const querySelectorAll = bridge.function(Document.querySelectorAll, .{ .dom_exception = true });
    pub const getElementsByTagName = bridge.function(Document.getElementsByTagName, .{});
    pub const getElementsByClassName = bridge.function(Document.getElementsByClassName, .{});
};

const testing = @import("../../testing.zig");
test "WebApi: Document" {
    try testing.htmlRunner("document", .{});
}
