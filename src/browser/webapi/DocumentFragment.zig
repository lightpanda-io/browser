const std = @import("std");
const js = @import("../js/js.zig");

const Page = @import("../Page.zig");
const Node = @import("Node.zig");
const Element = @import("Element.zig");
const collections = @import("collections.zig");
const Selector = @import("selector/Selector.zig");

const DocumentFragment = @This();

_proto: *Node,

pub fn init(page: *Page) !*DocumentFragment {
    return page._factory.node(DocumentFragment{
        ._proto = undefined,
    });
}

pub fn asNode(self: *DocumentFragment) *Node {
    return self._proto;
}

pub fn asEventTarget(self: *DocumentFragment) *@import("EventTarget.zig") {
    return self._proto.asEventTarget();
}

pub fn className(_: *const DocumentFragment) []const u8 {
    return "[object DocumentFragment]";
}

pub fn getElementById(self: *DocumentFragment, id_: ?[]const u8) ?*Element {
    const id = id_ orelse return null;

    var tw = @import("TreeWalker.zig").Full.Elements.init(self.asNode(), .{});
    while (tw.next()) |el| {
        if (el.getAttributeSafe("id")) |element_id| {
            if (std.mem.eql(u8, element_id, id)) {
                return el;
            }
        }
    }
    return null;
}

pub fn querySelector(self: *DocumentFragment, selector: []const u8, page: *Page) !?*Element {
    return Selector.querySelector(self.asNode(), selector, page);
}

pub fn querySelectorAll(self: *DocumentFragment, input: []const u8, page: *Page) !*Selector.List {
    return Selector.querySelectorAll(self.asNode(), input, page);
}

pub fn getChildren(self: *DocumentFragment, page: *Page) !collections.NodeLive(.child_elements) {
    return collections.NodeLive(.child_elements).init(null, self.asNode(), {}, page);
}

pub fn firstElementChild(self: *DocumentFragment) ?*Element {
    var maybe_child = self.asNode().firstChild();
    while (maybe_child) |child| {
        if (child.is(Element)) |el| return el;
        maybe_child = child.nextSibling();
    }
    return null;
}

pub fn lastElementChild(self: *DocumentFragment) ?*Element {
    var maybe_child = self.asNode().lastChild();
    while (maybe_child) |child| {
        if (child.is(Element)) |el| return el;
        maybe_child = child.previousSibling();
    }
    return null;
}

pub fn getChildElementCount(self: *DocumentFragment) usize {
    var count: usize = 0;
    var it = self.asNode().childrenIterator();
    while (it.next()) |node| {
        if (node.is(Element) != null) {
            count += 1;
        }
    }
    return count;
}

pub fn append(self: *DocumentFragment, nodes: []const Node.NodeOrText, page: *Page) !void {
    const parent = self.asNode();
    for (nodes) |node_or_text| {
        const child = try node_or_text.toNode(page);
        _ = try parent.appendChild(child, page);
    }
}

pub fn prepend(self: *DocumentFragment, nodes: []const Node.NodeOrText, page: *Page) !void {
    const parent = self.asNode();
    var i = nodes.len;
    while (i > 0) {
        i -= 1;
        const child = try nodes[i].toNode(page);
        _ = try parent.insertBefore(child, parent.firstChild(), page);
    }
}

pub fn replaceChildren(self: *DocumentFragment, nodes: []const Node.NodeOrText, page: *Page) !void {
    page.domChanged();
    var parent = self.asNode();

    var it = parent.childrenIterator();
    while (it.next()) |child| {
        page.removeNode(parent, child, .{ .will_be_reconnected = false });
    }

    const parent_is_connected = parent.isConnected();
    for (nodes) |node_or_text| {
        const child = try node_or_text.toNode(page);
        try page.appendNode(parent, child, .{ .child_already_connected = parent_is_connected });
    }
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(DocumentFragment);

    pub const Meta = struct {
        pub const name = "DocumentFragment";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(DocumentFragment.init, .{});

    pub const getElementById = bridge.function(DocumentFragment.getElementById, .{});
    pub const querySelector = bridge.function(DocumentFragment.querySelector, .{ .dom_exception = true });
    pub const querySelectorAll = bridge.function(DocumentFragment.querySelectorAll, .{ .dom_exception = true });
    pub const children = bridge.accessor(DocumentFragment.getChildren, null, .{});
    pub const childElementCount = bridge.accessor(DocumentFragment.getChildElementCount, null, .{});
    pub const firstElementChild = bridge.accessor(DocumentFragment.firstElementChild, null, .{});
    pub const lastElementChild = bridge.accessor(DocumentFragment.lastElementChild, null, .{});
    pub const append = bridge.function(DocumentFragment.append, .{});
    pub const prepend = bridge.function(DocumentFragment.prepend, .{});
    pub const replaceChildren = bridge.function(DocumentFragment.replaceChildren, .{});
};

const testing = @import("../../testing.zig");
test "WebApi: DocumentFragment" {
    try testing.htmlRunner("document_fragment", .{});
}
