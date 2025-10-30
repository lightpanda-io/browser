const std = @import("std");
const js = @import("../js/js.zig");

const Page = @import("../Page.zig");
const Node = @import("Node.zig");
const Document = @import("Document.zig");
const Element = @import("Element.zig");
const collections = @import("collections.zig");

const HTMLDocument = @This();

_proto: *Document,

pub fn asDocument(self: *HTMLDocument) *Document {
    return self._proto;
}

pub fn asNode(self: *HTMLDocument) *Node {
    return self._proto.asNode();
}

pub fn asEventTarget(self: *HTMLDocument) *@import("EventTarget.zig") {
    return self._proto.asEventTarget();
}

pub fn className(_: *const HTMLDocument) []const u8 {
    return "[object HTMLDocument]";
}

// HTML-specific accessors
pub fn getHead(self: *HTMLDocument) ?*Element.Html.Head {
    const doc_el = self._proto.getDocumentElement() orelse return null;
    var child = doc_el.asNode().firstChild();
    while (child) |node| {
        if (node.is(Element.Html.Head)) |head| {
            return head;
        }
        child = node.nextSibling();
    }
    return null;
}

pub fn getBody(self: *HTMLDocument) ?*Element.Html.Body {
    const doc_el = self._proto.getDocumentElement() orelse return null;
    var child = doc_el.asNode().firstChild();
    while (child) |node| {
        if (node.is(Element.Html.Body)) |body| {
            return body;
        }
        child = node.nextSibling();
    }
    return null;
}

pub fn getTitle(self: *HTMLDocument, page: *Page) ![]const u8 {
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

pub fn setTitle(self: *HTMLDocument, title: []const u8, page: *Page) !void {
    const head = self.getHead() orelse return;
    var it = head.asNode().childrenIterator();
    while (it.next()) |node| {
        if (node.is(Element.Html.Title)) |title_element| {
            return title_element.asElement().replaceChildren(&.{.{ .text = title }}, page);
        }
    }
}

pub fn getImages(self: *HTMLDocument, page: *Page) !collections.NodeLive(.tag) {
    return collections.NodeLive(.tag).init(null, self.asNode(), .img, page);
}

pub fn getScripts(self: *HTMLDocument, page: *Page) !collections.NodeLive(.tag) {
    return collections.NodeLive(.tag).init(null, self.asNode(), .script, page);
}

pub fn getLinks(self: *HTMLDocument, page: *Page) !collections.NodeLive(.tag) {
    return collections.NodeLive(.tag).init(null, self.asNode(), .anchor, page);
}

pub fn getForms(self: *HTMLDocument, page: *Page) !collections.NodeLive(.tag) {
    return collections.NodeLive(.tag).init(null, self.asNode(), .form, page);
}

pub fn getCurrentScript(self: *const HTMLDocument) ?*Element.Html.Script {
    return self._proto._current_script;
}

pub fn getLocation(self: *const HTMLDocument) ?*@import("Location.zig") {
    return self._proto._location;
}

pub fn getAll(self: *HTMLDocument, page: *Page) !*collections.HTMLAllCollection {
    return page._factory.create(collections.HTMLAllCollection.init(self.asNode(), page));
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(HTMLDocument);

    pub const Meta = struct {
        pub const name = "HTMLDocument";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_index: u16 = 0;
    };

    pub const constructor = bridge.constructor(_constructor, .{});
    fn _constructor(page: *Page) !*HTMLDocument {
        return page._factory.document(HTMLDocument{
            ._proto = undefined,
        });
    }

    pub const head = bridge.accessor(HTMLDocument.getHead, null, .{});
    pub const body = bridge.accessor(HTMLDocument.getBody, null, .{});
    pub const title = bridge.accessor(HTMLDocument.getTitle, HTMLDocument.setTitle, .{});
    pub const images = bridge.accessor(HTMLDocument.getImages, null, .{});
    pub const scripts = bridge.accessor(HTMLDocument.getScripts, null, .{});
    pub const links = bridge.accessor(HTMLDocument.getLinks, null, .{});
    pub const forms = bridge.accessor(HTMLDocument.getForms, null, .{});
    pub const currentScript = bridge.accessor(HTMLDocument.getCurrentScript, null, .{});
    pub const location = bridge.accessor(HTMLDocument.getLocation, null, .{ .cache = "location" });
    pub const all = bridge.accessor(HTMLDocument.getAll, null, .{});
};
