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

const log = @import("../../log.zig");
const js = @import("../js/js.zig");
const Page = @import("../Page.zig");
const reflect = @import("../reflect.zig");

const EventTarget = @import("EventTarget.zig");
const collections = @import("collections.zig");

pub const CData = @import("CData.zig");
pub const Element = @import("Element.zig");
pub const Document = @import("Document.zig");
pub const HTMLDocument = @import("HTMLDocument.zig");
pub const Children = @import("children.zig").Children;
pub const DocumentFragment = @import("DocumentFragment.zig");
pub const DocumentType = @import("DocumentType.zig");
pub const ShadowRoot = @import("ShadowRoot.zig");

const Allocator = std.mem.Allocator;
const LinkedList = std.DoublyLinkedList;

const Node = @This();

_type: Type,
_proto: *EventTarget,
_parent: ?*Node = null,
_children: ?*Children = null,
_child_link: LinkedList.Node = .{},

pub const Type = union(enum) {
    cdata: *CData,
    element: *Element,
    document: *Document,
    document_type: *DocumentType,
    attribute: *Element.Attribute,
    document_fragment: *DocumentFragment,
};

pub fn asEventTarget(self: *Node) *EventTarget {
    return self._proto;
}

// Returns the node as a more specific type. Will crash if node is not a `T`.
// Use `is` to optionally get the node as T
pub fn as(self: *Node, comptime T: type) *T {
    return self.is(T).?;
}

// Return the node as a more specific type or `null` if the node is not a `T`.
pub fn is(self: *Node, comptime T: type) ?*T {
    const type_name = @typeName(T);
    switch (self._type) {
        .element => |el| {
            if (T == Element) {
                return el;
            }
            if (comptime std.mem.startsWith(u8, type_name, "browser.webapi.element.")) {
                return el.is(T);
            }
        },
        .cdata => |cd| {
            if (T == CData) {
                return cd;
            }
            if (comptime std.mem.startsWith(u8, type_name, "browser.webapi.cdata.")) {
                return cd.is(T);
            }
        },
        .attribute => |attr| {
            if (T == Element.Attribute) {
                return attr;
            }
        },
        .document => |doc| {
            if (T == Document) {
                return doc;
            }
            if (comptime std.mem.startsWith(u8, type_name, "browser.webapi.htmldocument.")) {
                return doc.is(T);
            }
        },
        .document_type => |dt| {
            if (T == DocumentType) {
                return dt;
            }
        },
        .document_fragment => |doc| {
            if (T == DocumentFragment) {
                return doc;
            }
            if (T == ShadowRoot) {
                return doc.is(ShadowRoot);
            }
        },
    }
    return null;
}

pub fn firstChild(self: *const Node) ?*Node {
    const children = self._children orelse return null;
    return children.first();
}

pub fn lastChild(self: *const Node) ?*Node {
    const children = self._children orelse return null;
    return children.last();
}

pub fn nextSibling(self: *const Node) ?*Node {
    return linkToNodeOrNull(self._child_link.next);
}

pub fn previousSibling(self: *const Node) ?*Node {
    return linkToNodeOrNull(self._child_link.prev);
}

pub fn parentNode(self: *const Node) ?*Node {
    return self._parent;
}

pub fn parentElement(self: *const Node) ?*Element {
    const parent = self._parent orelse return null;
    return parent.is(Element);
}

pub fn appendChild(self: *Node, child: *Node, page: *Page) !*Node {
    if (child.is(DocumentFragment)) |_| {
        try page.appendAllChildren(child, self);
        return child;
    }

    page.domChanged();

    // If the child is currently connected, and if its new parent is connected,
    // then we can remove + add a bit more efficiently (we don't have to fully
    // disconnect then reconnect)
    const child_connected = child.isConnected();

    if (child._parent) |parent| {
        // we can signal removeNode that the child will remain connected
        // (when it's appended to self) so that it can be a bit more efficient.
        page.removeNode(parent, child, .{ .will_be_reconnected = self.isConnected() });
    }

    try page.appendNode(self, child, .{ .child_already_connected = child_connected });
    return child;
}

pub fn childNodes(self: *const Node, page: *Page) !*collections.ChildNodes {
    return collections.ChildNodes.init(self._children, page);
}

pub fn getTextContent(self: *Node, writer: *std.Io.Writer) error{WriteFailed}!void {
    switch (self._type) {
        .element => {
            var it = self.childrenIterator();
            while (it.next()) |child| {
                // ignore comments and TODO processing instructions.
                if (child.is(CData.Comment) != null) {
                    continue;
                }
                try child.getTextContent(writer);
            }
        },
        .cdata => |c| try writer.writeAll(c.getData()),
        .document => {},
        .document_type => {},
        .document_fragment => {},
        .attribute => |attr| try writer.writeAll(attr._value),
    }
}

pub fn getTextContentAlloc(self: *Node, allocator: Allocator) error{WriteFailed}![:0]const u8 {
    var buf = std.Io.Writer.Allocating.init(allocator);
    try self.getTextContent(&buf.writer);
    try buf.writer.writeByte(0);
    const data = buf.written();
    return data[0 .. data.len - 1 :0];
}

pub fn setTextContent(self: *Node, data: []const u8, page: *Page) !void {
    switch (self._type) {
        .element => |el| return el.replaceChildren(&.{.{ .text = data }}, page),
        .cdata => |c| c._data = try page.arena.dupe(u8, data),
        .document => {},
        .document_type => {},
        .document_fragment => |frag| return frag.replaceChildren(&.{.{ .text = data }}, page),
        .attribute => |attr| return attr.setValue(data, page),
    }
}

pub fn getNodeName(self: *const Node, page: *Page) []const u8 {
    return switch (self._type) {
        .element => |el| el.getTagNameSpec(&page.buf),
        .cdata => |cd| switch (cd._type) {
            .text => "#text",
            .cdata_section => "#cdata-section",
            .comment => "#comment",
        },
        .document => "#document",
        .document_type => |dt| dt.getName(),
        .document_fragment => "#document-fragment",
        .attribute => |attr| attr._name,
    };
}

pub fn nodeType(self: *const Node) u8 {
    return switch (self._type) {
        .element => 1,
        .attribute => 2,
        .cdata => |cd| switch (cd._type) {
            .text => 3,
            .cdata_section => 4,
            .comment => 8,
        },
        .document => 9,
        .document_type => 10,
        .document_fragment => 11,
    };
}

pub fn isInShadowTree(self: *Node) bool {
    var node = self._parent;
    while (node) |n| {
        if (n.is(ShadowRoot) != null) {
            return true;
        }
        node = n._parent;
    }
    return false;
}

pub fn isConnected(self: *const Node) bool {
    const target = Page.current.document.asNode();
    if (self == target) {
        return true;
    }

    var node = self._parent;
    while (node) |n| {
        if (n == target) {
            return true;
        }
        node = n._parent;
    }
    return false;
}

const GetRootNodeOpts = struct {
    composed: bool = false,
};
pub fn getRootNode(self: *const Node, opts_: ?GetRootNodeOpts) *const Node {
    const opts = opts_ orelse GetRootNodeOpts{};

    var root = self;
    while (root._parent) |parent| {
        root = parent;
    }

    // If composed is true, traverse through shadow boundaries
    if (opts.composed) {
        while (true) {
            const shadow_root = @constCast(root).is(ShadowRoot) orelse break;
            root = shadow_root.getHost().asNode();
            while (root._parent) |parent| {
                root = parent;
            }
        }
    }

    return root;
}

pub fn contains(self: *const Node, child: *const Node) bool {
    if (self == child) {
        // yes, this is correct
        return true;
    }

    var parent = child._parent;
    while (parent) |p| {
        if (p == self) {
            return true;
        }
        parent = p._parent;
    }
    return false;
}

pub fn ownerDocument(self: *const Node, page: *const Page) ?*Document {
    // A document node does not have an owner.
    if (self._type == .document) {
        return null;
    }

    // The root of the tree that a node belongs to is its owner.
    var current = self;
    while (current._parent) |parent| {
        current = parent;
    }

    // If the root is a document, then that's our owner.
    if (current._type == .document) {
        return current._type.document;
    }

    // Otherwise, this is a detached node. The owner is the document that
    // created it. For now, we only have one document.
    return page.document;
}

pub fn hasChildNodes(self: *const Node) bool {
    return self.firstChild() != null;
}

pub fn isSameNode(self: *const Node, other: ?*Node) bool {
    return self == other;
}

pub fn removeChild(self: *Node, child: *Node, page: *Page) !*Node {
    var it = self.childrenIterator();
    while (it.next()) |n| {
        if (n == child) {
            page.domChanged();
            page.removeNode(self, child, .{ .will_be_reconnected = false });
            return child;
        }
    }
    return error.NotFound;
}

pub fn insertBefore(self: *Node, new_node: *Node, ref_node_: ?*Node, page: *Page) !*Node {
    const ref_node = ref_node_ orelse {
        return self.appendChild(new_node, page);
    };

    if (ref_node._parent == null or ref_node._parent.? != self) {
        return error.NotFound;
    }

    if (new_node.is(DocumentFragment)) |_| {
        try page.insertAllChildrenBefore(new_node, self, ref_node);
        return new_node;
    }

    const child_already_connected = new_node.isConnected();

    page.domChanged();
    const will_be_reconnected = self.isConnected();
    if (new_node._parent) |parent| {
        page.removeNode(parent, new_node, .{ .will_be_reconnected = will_be_reconnected });
    }

    try page.insertNodeRelative(
        self,
        new_node,
        .{ .before = ref_node },
        .{ .child_already_connected = child_already_connected },
    );

    return new_node;
}

pub fn replaceChild(self: *Node, new_child: *Node, old_child: *Node, page: *Page) !*Node {
    if (old_child._parent == null or old_child._parent.? != self) {
        return error.HierarchyError;
    }
    if (self._type != .document and self._type != .element) {
        return error.HierarchyError;
    }
    if (new_child.contains(self)) {
        return error.HierarchyError;
    }

    _ = try self.insertBefore(new_child, old_child, page);
    page.removeNode(self, old_child, .{ .will_be_reconnected = false });
    return old_child;
}

pub fn getNodeValue(self: *const Node) ?[]const u8 {
    return switch (self._type) {
        .cdata => |c| c.getData(),
        .attribute => |attr| attr._value,
        .element => null,
        .document => null,
        .document_type => null,
        .document_fragment => null,
    };
}

pub fn setNodeValue(self: *const Node, value: ?[]const u8, page: *Page) !void {
    switch (self._type) {
        .cdata => |c| try c.setData(value, page),
        .attribute => |attr| try attr.setValue(value, page),
        .element => {},
        .document => {},
        .document_type => {},
        .document_fragment => {},
    }
}

pub fn format(self: *Node, writer: *std.Io.Writer) !void {
    // // If you need extra debugging:
    // return @import("../dump.zig").deep(self, .{}, writer);
    return switch (self._type) {
        .cdata => |cd| cd.format(writer),
        .element => |el| writer.print("{f}", .{el}),
        .document => writer.writeAll("<document>"),
        .document_type => writer.writeAll("<doctype>"),
        .document_fragment => writer.writeAll("<document_fragment>"),
        .attribute => |attr| writer.print("{f}", .{attr}),
    };
}

// Returns an iterator the can be used to iterate through the node's children
// For internal use.
pub fn childrenIterator(self: *Node) NodeIterator {
    const children = self._children orelse {
        return .{ .node = null };
    };

    return .{
        .node = children.first(),
    };
}

pub fn getLength(self: *Node) u32 {
    switch (self._type) {
        .cdata => |cdata| {
            return @intCast(cdata.getData().len);
        },
        .element, .document, .document_fragment => {
            var count: u32 = 0;
            var it = self.childrenIterator();
            while (it.next()) |_| {
                count += 1;
            }
            return count;
        },
        .document_type, .attribute => return 0,
    }
}

pub fn getChildIndex(self: *Node, target: *const Node) ?u32 {
    var i: u32 = 0;
    var it = self.childrenIterator();
    while (it.next()) |child| {
        if (child == target) {
            return i;
        }
        i += 1;
    }
    return null;
}

pub fn getChildAt(self: *Node, index: u32) ?*Node {
    var i: u32 = 0;
    var it = self.childrenIterator();
    while (it.next()) |child| {
        if (i == index) {
            return child;
        }
        i += 1;
    }
    return null;
}

pub fn getData(self: *const Node) []const u8 {
    return switch (self._type) {
        .cdata => |c| c.getData(),
        else => "",
    };
}

pub fn setData(self: *Node, data: []const u8) void {
    switch (self._type) {
        .cdata => |c| c._data = data,
        else => {},
    }
}

pub fn className(self: *const Node) []const u8 {
    switch (self._type) {
        inline else => |c| return c.className(),
    }
}

pub fn normalize(self: *Node, page: *Page) !void {
    var buffer: std.ArrayListUnmanaged(u8) = .empty;
    return self._normalize(page.call_arena, &buffer, page);
}

pub fn cloneNode(self: *Node, deep_: ?bool, page: *Page) error{ OutOfMemory, StringTooLarge, NotSupported, NotImplemented, InvalidCharacterError }!*Node {
    const deep = deep_ orelse false;
    switch (self._type) {
        .cdata => |cd| {
            const data = cd.getData();
            return switch (cd._type) {
                .text => page.createTextNode(data),
                .cdata_section => page.createCDATASection(data),
                .comment => page.createComment(data),
            };
        },
        .element => |el| return el.cloneElement(deep, page),
        .document => return error.NotSupported,
        .document_type => return error.NotSupported,
        .document_fragment => |frag| return frag.cloneFragment(deep, page),
        .attribute => return error.NotSupported,
    }
}

pub fn compareDocumentPosition(self: *const Node, other: *const Node) u16 {
    const DISCONNECTED: u16 = 0x01;
    const PRECEDING: u16 = 0x02;
    const FOLLOWING: u16 = 0x04;
    const CONTAINS: u16 = 0x08;
    const CONTAINED_BY: u16 = 0x10;
    const IMPLEMENTATION_SPECIFIC: u16 = 0x20;

    if (self == other) {
        return 0;
    }

    // Check if either node is disconnected
    const self_root = self.getRootNode(.{});
    const other_root = other.getRootNode(.{});

    if (self_root != other_root) {
        // Nodes are in different trees - disconnected
        // Use pointer comparison for implementation-specific ordering
        return DISCONNECTED | IMPLEMENTATION_SPECIFIC | if (@intFromPtr(self) < @intFromPtr(other)) FOLLOWING else PRECEDING;
    }

    // Check if one contains the other
    if (self.contains(other)) {
        return FOLLOWING | CONTAINED_BY;
    }

    if (other.contains(self)) {
        return PRECEDING | CONTAINS;
    }

    // Neither contains the other - find common ancestor and compare positions
    // Walk up from self to build ancestor chain
    var self_ancestors: [256]*const Node = undefined;
    var ancestor_count: usize = 0;
    var current: ?*const Node = self;
    while (current) |node| : (current = node._parent) {
        if (ancestor_count >= self_ancestors.len) break;
        self_ancestors[ancestor_count] = node;
        ancestor_count += 1;
    }

    const ancestors = self_ancestors[0..ancestor_count];

    // Walk up from other until we find common ancestor
    current = other;
    while (current) |node| : (current = node._parent) {
        // Check if this node is in self's ancestor chain
        for (ancestors, 0..) |ancestor, i| {
            if (ancestor != node) {
                continue;
            }

            // Found common ancestor
            // Compare the children that are ancestors of self and other
            if (i == 0) {
                // self is directly under the common ancestor
                // Find other's ancestor that's a child of the common ancestor
                if (other == node) {
                    // other is the common ancestor, so self follows it
                    return FOLLOWING;
                }
                var other_ancestor = other;
                while (other_ancestor._parent) |p| {
                    if (p == node) break;
                    other_ancestor = p;
                }
                return if (isNodeBefore(self, other_ancestor)) FOLLOWING else PRECEDING;
            }

            const self_ancestor = self_ancestors[i - 1];
            // Find other's ancestor that's a child of the common ancestor
            var other_ancestor = other;
            if (other == node) {
                // other is the common ancestor, so self is contained by it
                return PRECEDING | CONTAINS;
            }
            while (other_ancestor._parent) |p| {
                if (p == node) break;
                other_ancestor = p;
            }
            return if (isNodeBefore(self_ancestor, other_ancestor)) FOLLOWING else PRECEDING;
        }
    }

    // Shouldn't reach here if both nodes are in the same tree
    return DISCONNECTED;
}

// faster to compare the linked list node links directly
fn isNodeBefore(node1: *const Node, node2: *const Node) bool {
    var current = node1._child_link.next;
    const target = &node2._child_link;
    while (current) |link| {
        if (link == target) return true;
        current = link.next;
    }
    return false;
}

fn _normalize(self: *Node, allocator: Allocator, buffer: *std.ArrayListUnmanaged(u8), page: *Page) !void {
    var it = self.childrenIterator();
    while (it.next()) |child| {
        try child._normalize(allocator, buffer, page);
    }

    var child = self.firstChild();
    while (child) |current_node| {
        var next_node = current_node.nextSibling();

        const text_node = current_node.is(CData.Text) orelse {
            child = next_node;
            continue;
        };

        if (text_node._proto.getData().len == 0) {
            page.removeNode(self, current_node, .{ .will_be_reconnected = false });
            child = next_node;
            continue;
        }

        if (next_node) |next| {
            if (next.is(CData.Text)) |_| {
                try buffer.appendSlice(allocator, text_node.getWholeText());

                while (next_node) |node_to_merge| {
                    const next_text_node = node_to_merge.is(CData.Text) orelse break;
                    try buffer.appendSlice(allocator, next_text_node.getWholeText());

                    const to_remove = node_to_merge;
                    next_node = node_to_merge.nextSibling();
                    page.removeNode(self, to_remove, .{ .will_be_reconnected = false });
                }
                text_node._proto._data = try page.dupeString(buffer.items);
                buffer.clearRetainingCapacity();
            }
        }

        child = next_node;
    }
}

// Writes a JSON representation of the node and its children
pub fn jsonStringify(self: *const Node, writer: *std.json.Stringify) !void {
    // stupid json api requires this to be const,
    // so we @constCast it because our stringify re-uses code that can be
    // used to iterate nodes, e.g. the NodeIterator
    return @import("../dump.zig").toJSON(@constCast(self), writer);
}

const NodeIterator = struct {
    node: ?*Node,
    pub fn next(self: *NodeIterator) ?*Node {
        const node = self.node orelse return null;
        self.node = linkToNodeOrNull(node._child_link.next);
        return node;
    }
};

// Turns a linked list node into a Node
pub fn linkToNode(n: *LinkedList.Node) *Node {
    return @fieldParentPtr("_child_link", n);
}

pub fn linkToNodeOrNull(n_: ?*LinkedList.Node) ?*Node {
    return if (n_) |n| linkToNode(n) else null;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Node);

    pub const Meta = struct {
        pub const name = "Node";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const ELEMENT_NODE = bridge.property(1);
    pub const ATTRIBUTE_NODE = bridge.property(2);
    pub const TEXT_NODE = bridge.property(3);
    pub const CDATA_SECTION_NODE = bridge.property(4);
    pub const PROCESSING_INSTRUCTION_NODE = bridge.property(7);
    pub const COMMENT_NODE = bridge.property(8);
    pub const DOCUMENT_NODE = bridge.property(9);
    pub const DOCUMENT_TYPE_NODE = bridge.property(10);
    pub const DOCUMENT_FRAGMENT_NODE = bridge.property(11);

    pub const DOCUMENT_POSITION_DISCONNECTED = bridge.property(0x01);
    pub const DOCUMENT_POSITION_PRECEDING = bridge.property(0x02);
    pub const DOCUMENT_POSITION_FOLLOWING = bridge.property(0x04);
    pub const DOCUMENT_POSITION_CONTAINS = bridge.property(0x08);
    pub const DOCUMENT_POSITION_CONTAINED_BY = bridge.property(0x10);
    pub const DOCUMENT_POSITION_IMPLEMENTATION_SPECIFIC = bridge.property(0x20);

    pub const nodeName = bridge.accessor(Node.getNodeName, null, .{});
    pub const nodeType = bridge.accessor(Node.nodeType, null, .{});

    pub const textContent = bridge.accessor(_textContext, Node.setTextContent, .{});
    fn _textContext(self: *Node, page: *const Page) !?[]const u8 {
        // cdata and attributes can return value directly, avoiding the copy
        switch (self._type) {
            .element => |el| {
                var buf = std.Io.Writer.Allocating.init(page.call_arena);
                try el.asNode().getTextContent(&buf.writer);
                return buf.written();
            },
            .cdata => |cdata| return cdata.getData(),
            .attribute => |attr| return attr._value,
            .document => return null,
            .document_type => return null,
            .document_fragment => return null,
        }
    }

    pub const firstChild = bridge.accessor(Node.firstChild, null, .{});
    pub const lastChild = bridge.accessor(Node.lastChild, null, .{});
    pub const nextSibling = bridge.accessor(Node.nextSibling, null, .{});
    pub const previousSibling = bridge.accessor(Node.previousSibling, null, .{});
    pub const parentNode = bridge.accessor(Node.parentNode, null, .{});
    pub const parentElement = bridge.accessor(Node.parentElement, null, .{});
    pub const appendChild = bridge.function(Node.appendChild, .{});
    pub const childNodes = bridge.accessor(Node.childNodes, null, .{});
    pub const isConnected = bridge.accessor(Node.isConnected, null, .{});
    pub const ownerDocument = bridge.accessor(Node.ownerDocument, null, .{});
    pub const hasChildNodes = bridge.function(Node.hasChildNodes, .{});
    pub const isSameNode = bridge.function(Node.isSameNode, .{});
    pub const contains = bridge.function(Node.contains, .{});
    pub const removeChild = bridge.function(Node.removeChild, .{ .dom_exception = true });
    pub const nodeValue = bridge.accessor(Node.getNodeValue, Node.setNodeValue, .{});
    pub const insertBefore = bridge.function(Node.insertBefore, .{ .dom_exception = true });
    pub const replaceChild = bridge.function(Node.replaceChild, .{ .dom_exception = true });
    pub const normalize = bridge.function(Node.normalize, .{});
    pub const cloneNode = bridge.function(Node.cloneNode, .{ .dom_exception = true });
    pub const compareDocumentPosition = bridge.function(Node.compareDocumentPosition, .{});
    pub const getRootNode = bridge.function(Node.getRootNode, .{});

    pub const toString = bridge.function(_toString, .{});
    fn _toString(self: *const Node) []const u8 {
        return self.className();
    }
};

pub const Build = struct {
    // Calls `func_name` with `args` on the most specific type where it is
    // implement. This could be on the Node itself (as a last-resort);
    pub fn call(self: *const Node, comptime func_name: []const u8, args: anytype) !void {
        inline for (@typeInfo(Node.Type).@"union".fields) |f| {
            // The inner type has its own "call" method. Defer to it.
            if (@field(Node.Type, f.name) == self._type) {
                const S = reflect.Struct(f.type);
                if (@hasDecl(S, "Build")) {
                    if (@hasDecl(S.Build, "call")) {
                        const sub = @field(self._type, f.name);
                        if (try S.Build.call(sub, func_name, args)) {
                            return;
                        }
                    }
                    // The inner type implements this function. Call it and we're done.
                    if (@hasDecl(S, func_name)) {
                        return @call(.auto, @field(f.type, func_name), args);
                    }
                }
            }
        }

        if (@hasDecl(Node.Build, func_name)) {
            // Our last resort - the node implements this function.
            return @call(.auto, @field(Node.Build, func_name), args);
        }
    }
};

pub const NodeOrText = union(enum) {
    node: *Node,
    text: []const u8,

    pub fn format(self: *const NodeOrText, writer: *std.io.Writer) !void {
        switch (self.*) {
            .node => |n| try n.format(writer),
            .text => |text| {
                try writer.writeByte('\'');
                try writer.writeAll(text);
                try writer.writeByte('\'');
            },
        }
    }

    pub fn toNode(self: *const NodeOrText, page: *Page) !*Node {
        return switch (self.*) {
            .node => |n| n,
            .text => |txt| page.createTextNode(txt),
        };
    }
};

const testing = @import("../../testing.zig");
test "WebApi: Node" {
    try testing.htmlRunner("node", .{});
}
