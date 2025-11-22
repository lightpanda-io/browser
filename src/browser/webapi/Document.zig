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

const Node = @import("Node.zig");
const Element = @import("Element.zig");
const Location = @import("Location.zig");
const collections = @import("collections.zig");
const Selector = @import("selector/Selector.zig");
const NodeFilter = @import("NodeFilter.zig");
const DOMTreeWalker = @import("DOMTreeWalker.zig");
const DOMNodeIterator = @import("DOMNodeIterator.zig");
const DOMImplementation = @import("DOMImplementation.zig");

pub const HTMLDocument = @import("HTMLDocument.zig");

const Document = @This();

_type: Type,
_proto: *Node,
_location: ?*Location = null,
_ready_state: ReadyState = .loading,
_current_script: ?*Element.Html.Script = null,
_elements_by_id: std.StringHashMapUnmanaged(*Element) = .empty,
_active_element: ?*Element = null,

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
            .tag = collections.NodeLive(.tag).init(null, self.asNode(), known, page),
        };
    }

    const arena = page.arena;
    const filter = try String.init(arena, lower, .{});
    return .{ .tag_name = collections.NodeLive(.tag_name).init(arena, self.asNode(), filter, page) };
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
    pub const documentElement = bridge.accessor(Document.getDocumentElement, null, .{});
    pub const readyState = bridge.accessor(Document.getReadyState, null, .{});
    pub const implementation = bridge.accessor(Document.getImplementation, null, .{});
    pub const activeElement = bridge.accessor(Document.getActiveElement, null, .{});

    pub const createElement = bridge.function(Document.createElement, .{});
    pub const createElementNS = bridge.function(Document.createElementNS, .{});
    pub const createDocumentFragment = bridge.function(Document.createDocumentFragment, .{});
    pub const createComment = bridge.function(Document.createComment, .{});
    pub const createTextNode = bridge.function(Document.createTextNode, .{});
    pub const createEvent = bridge.function(Document.createEvent, .{ .dom_exception = true });
    pub const createTreeWalker = bridge.function(Document.createTreeWalker, .{});
    pub const createNodeIterator = bridge.function(Document.createNodeIterator, .{});
    pub const getElementById = bridge.function(Document.getElementById, .{});
    pub const querySelector = bridge.function(Document.querySelector, .{ .dom_exception = true });
    pub const querySelectorAll = bridge.function(Document.querySelectorAll, .{ .dom_exception = true });
    pub const getElementsByTagName = bridge.function(Document.getElementsByTagName, .{});
    pub const getElementsByClassName = bridge.function(Document.getElementsByClassName, .{});
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
