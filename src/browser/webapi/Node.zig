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
const lp = @import("lightpanda");

const js = @import("../js/js.zig");
const Frame = @import("../Frame.zig");
const URL = @import("../URL.zig");
const reflect = @import("../reflect.zig");

const EventTarget = @import("EventTarget.zig");
const collections = @import("collections.zig");

pub const CData = @import("CData.zig");
pub const Element = @import("Element.zig");
pub const Document = @import("Document.zig");
pub const HTMLDocument = @import("HTMLDocument.zig");
pub const DocumentFragment = @import("DocumentFragment.zig");
pub const DocumentType = @import("DocumentType.zig");
pub const ShadowRoot = @import("ShadowRoot.zig");

const String = lp.String;
const Allocator = std.mem.Allocator;
const LinkedList = std.DoublyLinkedList;

pub const AssignedSlotLookup = std.AutoHashMapUnmanaged(*Node, *Element.Html.Slot);

const Node = @This();

_type: Type,
_proto: *EventTarget,
_parent: ?*Node = null,
// A node with no children leaves this null (no allocation). Otherwise it
// points to a heap-allocated intrusive list of the node's `_child_link`s.
_children: ?*LinkedList = null,
_child_link: LinkedList.Node = .{},

// Lookup for nodes that have a different owner document than frame.document
pub const OwnerDocumentLookup = std.AutoHashMapUnmanaged(*Node, *Document);

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

/// Which "insert adjacent" flavor is asking. insertAdjacentHTML throws
/// NoModificationAllowedError for a null or document parent, while
/// insertAdjacentElement/Text return null for a null parent and otherwise
/// rely on the pre-insert validity checks (HierarchyRequestError).
const AdjacentVariant = enum { html, node };

/// Given a position, returns target and previous nodes required for
/// insertAdjacentHTML, insertAdjacentElement and insertAdjacentText.
/// * `target_node` is `*Node` (where we actually insert),
/// * `previous_node` is `?*Node`.
pub fn findAdjacentNodes(self: *Node, position: []const u8, variant: AdjacentVariant) !struct { *Node, ?*Node } {
    // Case-insensitive match per HTML spec.
    // "beforeend" was the most common case in my tests; we might adjust the order
    // depending on which ones websites prefer most.
    if (std.ascii.eqlIgnoreCase(position, "beforeend")) {
        return .{ self, null };
    }

    if (std.ascii.eqlIgnoreCase(position, "afterbegin")) {
        // Get the first child; null indicates there are no children.
        return .{ self, self.firstChild() };
    }

    if (std.ascii.eqlIgnoreCase(position, "beforebegin")) {
        return .{ try self.adjacentParent(variant), self };
    }

    if (std.ascii.eqlIgnoreCase(position, "afterend")) {
        // Get the next sibling or null; null indicates our node is the only one.
        return .{ try self.adjacentParent(variant), self.nextSibling() };
    }

    // Returned if:
    // * position is not one of the four listed values.
    // * The input is XML that is not well-formed.
    return error.SyntaxError;
}

// beforebegin/afterend insert into the parent, which must exist and, for the
// html variant, cannot be a document or fragment.
fn adjacentParent(self: *Node, variant: AdjacentVariant) !*Node {
    const parent_node = self.parentNode() orelse switch (variant) {
        .html => return error.NoModificationAllowed,
        .node => return error.AdjacentNoParent,
    };
    if (variant == .html) {
        switch (parent_node._type) {
            .document, .document_fragment => return error.NoModificationAllowed,
            else => {},
        }
    }
    return parent_node;
}

pub fn firstChild(self: *const Node) ?*Node {
    const children = self._children orelse return null;
    return linkToNodeOrNull(children.first);
}

pub fn lastChild(self: *const Node) ?*Node {
    const children = self._children orelse return null;
    return linkToNodeOrNull(children.last);
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

// Validates that a node can be inserted as a child of parent.
fn validateNodeInsertion(parent: *Node, node: *Node) !void {
    // Check if parent is a valid type to have children
    if (parent._type != .document and parent._type != .element and parent._type != .document_fragment) {
        return error.HierarchyError;
    }

    // Check if node contains parent (would create a cycle)
    if (node.contains(parent)) {
        return error.HierarchyError;
    }

    if (node._type == .attribute) {
        return error.HierarchyError;
    }

    // Doctype nodes can only be inserted into a Document
    if (node._type == .document_type and parent._type != .document) {
        return error.HierarchyError;
    }
}

// DOM "ensure pre-insert validity" (and its replaceChild variant), with the
// checks in spec order: parent type, cycle, child-parent (NotFoundError),
// node type, then the document-parent structure rules.
const PreInsertMode = enum { insert, replace };

fn ensurePreInsertValidity(parent: *Node, node: *Node, child: ?*Node, comptime mode: PreInsertMode) !void {
    switch (parent._type) {
        .document, .document_fragment, .element => {},
        else => return error.HierarchyError,
    }

    if (node.contains(parent)) {
        return error.HierarchyError;
    }

    if (child) |c| {
        if (c._parent == null or c._parent.? != parent) {
            return error.NotFound;
        }
    }

    switch (node._type) {
        .document, .attribute => return error.HierarchyError,
        .cdata => |cd| {
            if ((cd._type == .text or cd._type == .cdata_section) and parent._type == .document) {
                // A Text node (CDATASection included) cannot be a child of a
                // document.
                return error.HierarchyError;
            }
        },
        .document_type => {
            if (parent._type != .document) {
                return error.HierarchyError;
            }
        },
        else => {},
    }

    if (parent._type != .document) {
        return;
    }

    switch (node._type) {
        .document_fragment => {
            var element_count: u32 = 0;
            var it = node.childrenIterator();
            while (it.next()) |frag_child| {
                switch (frag_child._type) {
                    .element => element_count += 1,
                    .cdata => |cd| {
                        // A Text node (CDATASection included) cannot be a
                        // child of a document.
                        if (cd._type == .text or cd._type == .cdata_section) {
                            return error.HierarchyError;
                        }
                    },
                    else => {},
                }
            }
            if (element_count > 1) {
                return error.HierarchyError;
            }
            if (element_count == 1) {
                try checkDocumentElementRules(parent, node, child, mode);
            }
        },
        .element => try checkDocumentElementRules(parent, node, child, mode),
        .document_type => {
            var it = parent.childrenIterator();
            while (it.next()) |existing| {
                if (existing._type == .document_type and existing != node) {
                    if (mode == .replace and existing == child) continue;
                    return error.HierarchyError;
                }
            }
            if (child) |c| {
                // An element preceding child?
                var prev = c.previousSibling();
                while (prev) |p| : (prev = p.previousSibling()) {
                    if (p._type == .element) {
                        return error.HierarchyError;
                    }
                }
            } else if (mode == .insert) {
                var it2 = parent.childrenIterator();
                while (it2.next()) |existing| {
                    if (existing._type == .element) {
                        return error.HierarchyError;
                    }
                }
            }
        },
        else => {},
    }
}

fn checkDocumentElementRules(parent: *Node, node: *Node, child: ?*Node, comptime mode: PreInsertMode) !void {
    // A document can have at most one element child.
    var it = parent.childrenIterator();
    while (it.next()) |existing| {
        if (existing._type == .element and existing != node) {
            if (mode == .replace and existing == child) continue;
            return error.HierarchyError;
        }
    }
    if (child) |c| {
        if (mode == .insert and c._type == .document_type) {
            return error.HierarchyError;
        }
        // A doctype following child?
        var next = c.nextSibling();
        while (next) |n| : (next = n.nextSibling()) {
            if (n._type == .document_type) {
                return error.HierarchyError;
            }
        }
    }
}

pub fn appendChild(self: *Node, child: *Node, frame: *Frame) !*Node {
    try ensurePreInsertValidity(self, child, null, .insert);

    if (child.is(DocumentFragment)) |_| {
        try frame.appendAllChildren(child, self);
        return child;
    }

    frame.domChanged();

    // If the child is currently connected, and if its new parent is connected,
    // then we can remove + add a bit more efficiently (we don't have to fully
    // disconnect then reconnect)
    const child_connected = child.isConnected();

    // Check if we're adopting the node to a different document
    const child_owner = child.ownerDocument(frame);
    const parent_owner = self.ownerDocument(frame) orelse self.as(Document);
    const adopting_to_new_document = child_owner != null and child_owner.? != parent_owner;

    if (child._parent) |parent| {
        // we can signal removeNode that the child will remain connected
        // (when it's appended to self) so that it can be a bit more efficient.
        // But on cross-document moves the child must fully disconnect from the
        // source document (firing disconnectedCallback) before adoption.
        frame.removeNode(parent, child, .{
            .will_be_reconnected = self.isConnected() and !adopting_to_new_document,
        });
    }

    // Adopt the node tree if moving between documents
    if (adopting_to_new_document) {
        try frame.adoptNodeTree(child, child_owner.?, parent_owner);
    }

    try frame.appendNode(self, child, .{
        .child_already_connected = child_connected,
        .adopting_to_new_document = adopting_to_new_document,
    });
    return child;
}

pub fn childNodes(self: *Node, frame: *Frame) !*collections.ChildNodes {
    return collections.ChildNodes.init(self, frame);
}

pub fn getTextContent(self: *Node, writer: *std.Io.Writer) error{WriteFailed}!void {
    switch (self._type) {
        .element, .document_fragment => {
            var it = self.childrenIterator();
            while (it.next()) |child| {
                // ignore comments and processing instructions.
                if (child.is(CData.Comment) != null or child.is(CData.ProcessingInstruction) != null) {
                    continue;
                }
                try child.getTextContent(writer);
            }
        },
        .cdata => |c| try writer.writeAll(c._data.str()),
        .document => {},
        .document_type => {},
        .attribute => |attr| try writer.writeAll(attr._value.str()),
    }
}

pub fn getTextContentAlloc(self: *Node, allocator: Allocator) error{WriteFailed}![:0]const u8 {
    var buf = std.Io.Writer.Allocating.init(allocator);
    try self.getTextContent(&buf.writer);
    try buf.writer.writeByte(0);
    const data = buf.written();
    return data[0 .. data.len - 1 :0];
}

/// Returns the "child text content" which is the concatenation of the data
/// of all the Text node children of the node, in tree order.
/// This differs from textContent which includes all descendant text.
/// See: https://dom.spec.whatwg.org/#concept-child-text-content
pub fn getChildTextContent(self: *Node, writer: *std.Io.Writer) error{WriteFailed}!void {
    var it = self.childrenIterator();
    while (it.next()) |child| {
        if (child.is(CData.Text)) |text| {
            try writer.writeAll(text._proto._data.str());
        }
    }
}

// The byte length of what getChildTextContent writes; lets callers size a
// buffer (or arena) before extracting.
pub fn childTextContentLen(self: *Node) usize {
    var len: usize = 0;
    var it = self.childrenIterator();
    while (it.next()) |child| {
        if (child.is(CData.Text)) |text| {
            len += text._proto._data.str().len;
        }
    }
    return len;
}

pub fn setTextContent(self: *Node, data: []const u8, frame: *Frame) !void {
    switch (self._type) {
        .element => |el| {
            if (data.len == 0) {
                return el.replaceChildren(&.{}, frame);
            }
            return el.replaceChildren(&.{.{ .text = data }}, frame);
        },
        // Per spec, setting textContent on CharacterData runs replaceData(0, length, value)
        .cdata => |c| try c.replaceData(0, c.getLength(), data, frame),
        .document => {},
        .document_type => {},
        .document_fragment => |frag| {
            if (data.len == 0) {
                return frag.replaceChildren(&.{}, frame);
            }
            return frag.replaceChildren(&.{.{ .text = data }}, frame);
        },
        .attribute => |attr| return attr.setValue(.wrap(data), frame),
    }
}

pub fn getNodeName(self: *const Node, buf: []u8) []const u8 {
    return switch (self._type) {
        .element => |el| el.getTagNameSpec(buf),
        .cdata => |cd| switch (cd._type) {
            .text => "#text",
            .cdata_section => "#cdata-section",
            .comment => "#comment",
            .processing_instruction => |pi| pi._target,
        },
        .document => "#document",
        .document_type => |dt| dt.getName(),
        .document_fragment => "#document-fragment",
        .attribute => |attr| attr._name.str(),
    };
}

pub fn getNodeType(self: *const Node) u8 {
    return switch (self._type) {
        .element => 1,
        .attribute => 2,
        .cdata => |cd| switch (cd._type) {
            .text => 3,
            .cdata_section => 4,
            .processing_instruction => 7,
            .comment => 8,
        },
        .document => 9,
        .document_type => 10,
        .document_fragment => 11,
    };
}

pub fn lookupNamespaceURI(self: *Node, prefix_arg: ?[]const u8, frame: *Frame) ?[]const u8 {
    const prefix: ?[]const u8 = if (prefix_arg) |p| (if (p.len == 0) null else p) else null;

    switch (self._type) {
        .element => |el| return el.lookupNamespaceURIForElement(prefix, frame),
        .document => |doc| {
            const de = doc.getDocumentElement() orelse return null;
            return de.lookupNamespaceURIForElement(prefix, frame);
        },
        .document_type, .document_fragment => return null,
        .attribute => |attr| {
            const owner = attr.getOwnerElement() orelse return null;
            return owner.lookupNamespaceURIForElement(prefix, frame);
        },
        .cdata => {
            const parent = self.parentElement() orelse return null;
            return parent.lookupNamespaceURIForElement(prefix, frame);
        },
    }
}

pub fn lookupPrefix(self: *Node, namespace_arg: ?[]const u8, frame: *Frame) ?[]const u8 {
    const namespace = namespace_arg orelse return null;
    if (namespace.len == 0) return null;

    switch (self._type) {
        .element => |el| return el.lookupPrefixForElement(namespace, frame),
        .document => |doc| {
            const de = doc.getDocumentElement() orelse return null;
            return de.lookupPrefixForElement(namespace, frame);
        },
        .document_type, .document_fragment => return null,
        .attribute => |attr| {
            const owner = attr.getOwnerElement() orelse return null;
            return owner.lookupPrefixForElement(namespace, frame);
        },
        .cdata => {
            const parent = self.parentElement() orelse return null;
            return parent.lookupPrefixForElement(namespace, frame);
        },
    }
}

pub fn isDefaultNamespace(self: *Node, namespace_arg: ?[]const u8, frame: *Frame) bool {
    const namespace: ?[]const u8 = if (namespace_arg) |ns| (if (ns.len == 0) null else ns) else null;
    const default_ns = self.lookupNamespaceURI(null, frame);
    if (default_ns == null and namespace == null) return true;
    if (default_ns != null and namespace != null) return std.mem.eql(u8, default_ns.?, namespace.?);
    return false;
}

pub fn isEqualNode(self: *Node, other: *Node) bool {
    if (self == other) {
        return true;
    }

    // Make sure types match.
    if (self.getNodeType() != other.getNodeType()) {
        return false;
    }

    // TODO: Compare `localName` and prefix.
    return switch (self._type) {
        .element => self.as(Element).isEqualNode(other.as(Element)),
        .attribute => self.as(Element.Attribute).isEqualNode(other.as(Element.Attribute)),
        .cdata => self.as(CData).isEqualNode(other.as(CData)),
        .document_type => self.as(DocumentType).isEqualNode(other.as(DocumentType)),
        .document_fragment, .document => self.isEqualChildren(other),
    };
}

pub fn isEqualChildren(a: *Node, b: *Node) bool {
    var a_count: usize = 0;
    var a_iter = a.childrenIterator();

    var b_count: usize = 0;
    var b_iter = b.childrenIterator();

    while (a_iter.next()) |a_node| : (a_count += 1) {
        const b_node = b_iter.next() orelse return false;
        b_count += 1;
        if (a_node.isEqualNode(b_node)) {
            continue;
        }

        return false;
    }

    // Make sure both have equal number of children.
    return a_count == b_count;
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
    // Walk up to find the root node
    var root = self;
    while (root._parent) |parent| {
        root = parent;
    }

    switch (root._type) {
        .document => return true,
        .document_fragment => |df| {
            const sr = df.is(ShadowRoot) orelse return false;
            return sr._host.asNode().isConnected();
        },
        else => return false,
    }
}

const GetRootNodeOpts = struct {
    composed: bool = false,
};
pub fn getRootNode(self: *Node, opts: GetRootNodeOpts) *Node {
    var root = self;
    while (root._parent) |parent| {
        root = parent;
    }

    // If composed is true, traverse through shadow boundaries
    if (opts.composed) {
        while (true) {
            const shadow_root = root.is(ShadowRoot) orelse break;
            root = shadow_root.getHost().asNode();
            while (root._parent) |parent| {
                root = parent;
            }
        }
    }

    return root;
}

pub fn contains(self: *const Node, child_: ?*const Node) bool {
    const child = child_ orelse return false;

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

pub fn ownerDocument(self: *const Node, frame: *const Frame) ?*Document {
    // A document node does not have an owner.
    if (self._type == .document) {
        return null;
    }

    // An attribute node has no parent; its owner follows its element's
    // (including across adoption into another document).
    if (self._type == .attribute) {
        if (self._type.attribute._element) |element| {
            return element.asNode().ownerDocument(frame);
        }
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

    // A shadow tree's root is a parent-less ShadowRoot fragment; its owner
    // is the host's owner document.
    // can't use current.is(ShadowRoot) without @constCast on `current`
    if (current._type == .document_fragment) {
        const df = current._type.document_fragment;
        if (df._type == .shadow_root) {
            return df._type.shadow_root._host.asNode().ownerDocument(frame);
        }
    }

    // Otherwise, this is a detached node. Check if it has a specific owner
    // document registered (for nodes created via non-main documents).
    if (frame._node_owner_documents.get(@constCast(self))) |owner| {
        return owner;
    }

    // Default to the main document for detached nodes without a specific owner.
    return frame.document;
}

fn ownerDocumentIncludingSelf(self: *const Node, frame: *const Frame) ?*Document {
    if (self._type == .document) {
        return self._type.document;
    }
    return self.ownerDocument(frame);
}

// Returns the Frame that owns this node's tree. Used to tie cached state of
// "live" collections (NodeList, HTMLCollection, etc.) to the right frame's DOM
// version: cross-realm callers must invalidate based on mutations through the
// node's owning frame, not the caller's frame.
//
// Falls back to `default` when the node has no associated document yet (e.g.,
// freshly created and detached) or its document has no frame.
pub fn ownerFrame(self: *const Node, default: *Frame) *Frame {
    const doc = self.ownerDocumentIncludingSelf(default) orelse return default;
    return doc._frame orelse default;
}

pub const ResolveURLOpts = struct {
    allocator: ?Allocator = null,
};

// Resolve a URL relative to this node's owning document.
// Uses the document's charset for query string encoding (with NCR fallback for unmappable chars).
pub fn resolveURL(self: *const Node, url: anytype, frame: *Frame, opts: ResolveURLOpts) ![:0]const u8 {
    const owner_frame = self.ownerFrame(frame);
    const allocator = opts.allocator orelse frame.call_arena;
    const doc: ?*const Document = self.ownerDocumentIncludingSelf(frame);
    const encoding = if (doc) |d| d.getCharset() else owner_frame.charset;
    return URL.resolve(allocator, owner_frame.base(), url, .{ .encoding = encoding });
}

// Same as `resolveURL` but can't return `TypeError`, this is needed for multiple
// getters throughout codebase. Returns provided `url` on `TypeError`.
pub fn resolveURLReflect(self: *const Node, url: []const u8, frame: *Frame, opts: ResolveURLOpts) ![]const u8 {
    return self.resolveURL(url, frame, opts) catch |err| switch (err) {
        error.TypeError => url,
        else => err,
    };
}

pub fn isSameDocumentAs(self: *const Node, other: *const Node, frame: *const Frame) bool {
    // Get the root document for each node
    const self_doc = self.ownerDocumentIncludingSelf(frame);
    const other_doc = other.ownerDocumentIncludingSelf(frame);
    return self_doc == other_doc;
}

pub fn hasChildNodes(self: *const Node) bool {
    return self.firstChild() != null;
}

pub fn isSameNode(self: *const Node, other: ?*Node) bool {
    return self == other;
}

pub fn removeChild(self: *Node, child: *Node, frame: *Frame) !*Node {
    var it = self.childrenIterator();
    while (it.next()) |n| {
        if (n == child) {
            frame.domChanged();
            frame.removeNode(self, child, .{ .will_be_reconnected = false });
            return child;
        }
    }
    return error.NotFound;
}

pub fn insertBefore(self: *Node, new_node: *Node, ref_node_: ?*Node, frame: *Frame) !*Node {
    try ensurePreInsertValidity(self, new_node, ref_node_, .insert);
    return self.insertBeforeInner(new_node, ref_node_, frame);
}

// The insertion work, after pre-insert (or replace) validity was ensured by
// the caller.
fn insertBeforeInner(self: *Node, new_node: *Node, ref_node_: ?*Node, frame: *Frame) !*Node {
    const ref_node = ref_node_ orelse {
        return self.appendChild(new_node, frame);
    };

    // special case: if nodes are the same, ignore the change.
    if (new_node == ref_node_) {
        frame.domChanged();

        if (Frame.observers.hasMutationObservers(frame)) {
            const parent = new_node._parent.?;
            const previous_sibling = new_node.previousSibling();
            const next_sibling = new_node.nextSibling();
            const replaced = [_]*Node{new_node};
            Frame.observers.notifyChildListChange(frame, parent, &replaced, &replaced, previous_sibling, next_sibling);
        }

        return new_node;
    }

    if (new_node.is(DocumentFragment)) |_| {
        try frame.insertAllChildrenBefore(new_node, self, ref_node);
        return new_node;
    }

    const child_already_connected = new_node.isConnected();

    // Check if we're adopting the node to a different document
    const child_owner = new_node.ownerDocument(frame);
    const parent_owner = self.ownerDocument(frame) orelse self.as(Document);
    const adopting_to_new_document = child_owner != null and child_owner.? != parent_owner;

    frame.domChanged();
    const will_be_reconnected = self.isConnected() and !adopting_to_new_document;
    if (new_node._parent) |parent| {
        frame.removeNode(parent, new_node, .{ .will_be_reconnected = will_be_reconnected });
    }

    // Adopt the node tree if moving between documents
    if (adopting_to_new_document) {
        try frame.adoptNodeTree(new_node, child_owner.?, parent_owner);
    }

    try frame.insertNodeRelative(
        self,
        new_node,
        .{ .before = ref_node },
        .{
            .child_already_connected = child_already_connected,
            .adopting_to_new_document = adopting_to_new_document,
        },
    );

    return new_node;
}

pub fn replaceChild(self: *Node, new_child: *Node, old_child: *Node, frame: *Frame) !*Node {
    try ensurePreInsertValidity(self, new_child, old_child, .replace);

    frame.domChanged();
    const notify = Frame.observers.hasMutationObservers(frame);

    if (new_child == old_child) {
        // Replacing a node with itself leaves the tree unchanged, but the
        // remove-then-reinsert still happens: live ranges anchored inside the
        // node move to its old position, and observers get a removal record
        // followed by an addition record.
        const prev = old_child.previousSibling();
        const next = old_child.nextSibling();
        const was_connected = old_child.isConnected();
        frame.removeNode(self, old_child, .{ .will_be_reconnected = was_connected, .notify_observers = false });
        if (next) |reference| {
            try frame.insertNodeRelative(self, old_child, .{ .before = reference }, .{
                .child_already_connected = was_connected,
                .notify_observers = false,
            });
        } else {
            try frame.appendNode(self, old_child, .{
                .child_already_connected = was_connected,
                .notify_observers = false,
            });
        }
        if (notify) {
            const nodes = [_]*Node{old_child};
            Frame.observers.notifyChildListChange(frame, self, &.{}, &nodes, prev, next);
            Frame.observers.notifyChildListChange(frame, self, &nodes, &.{}, prev, next);
        }
        return old_child;
    }

    // Spec order: capture the reference points, remove new_child from its
    // current position (notifying normally - internal replacement), remove
    // old_child (suppressed), insert new_child before the reference
    // (suppressed), and queue one combined record. Removing old_child before
    // inserting matters for live ranges anchored on this parent's offsets.
    const prev = old_child.previousSibling();
    var reference = old_child.nextSibling();
    if (reference == new_child) {
        reference = new_child.nextSibling();
    }

    const child_already_connected = new_child.isConnected();
    const child_owner = new_child.ownerDocument(frame);
    const parent_owner = self.ownerDocument(frame) orelse self.as(Document);
    const adopting = child_owner != null and child_owner.? != parent_owner;
    const will_be_reconnected = self.isConnected() and !adopting;

    if (new_child.is(DocumentFragment) == null) {
        if (new_child._parent) |previous_parent| {
            frame.removeNode(previous_parent, new_child, .{ .will_be_reconnected = will_be_reconnected });
        }
        if (adopting) {
            try frame.adoptNodeTree(new_child, child_owner.?, parent_owner);
        }
    }

    var added: std.ArrayList(*Node) = .empty;
    if (notify) {
        if (new_child.is(DocumentFragment)) |_| {
            var it = new_child.childrenIterator();
            while (it.next()) |fragment_child| {
                try added.append(frame.call_arena, fragment_child);
            }
        } else {
            try added.append(frame.call_arena, new_child);
        }
    }

    frame.removeNode(self, old_child, .{ .will_be_reconnected = false, .notify_observers = false });

    if (new_child.is(DocumentFragment)) |_| {
        try frame.moveAllChildren(new_child, self, reference, .silent_parent);
    } else if (reference) |ref| {
        try frame.insertNodeRelative(
            self,
            new_child,
            .{ .before = ref },
            .{
                .child_already_connected = child_already_connected,
                .adopting_to_new_document = adopting,
                .notify_observers = false,
            },
        );
    } else {
        try frame.appendNode(self, new_child, .{
            .child_already_connected = child_already_connected,
            .adopting_to_new_document = adopting,
            .notify_observers = false,
        });
    }

    if (notify) {
        const removed = [_]*Node{old_child};
        Frame.observers.notifyChildListChange(frame, self, added.items, &removed, prev, reference);
    }

    return old_child;
}

// `node` and `child` are taken as raw js.Values rather than `*Node`/`?*Node`
// because both must be present, and `child` is nullable.
pub fn moveBefore(self: *Node, node_val: js.Value, child_val: js.Value, frame: *Frame) !void {
    const node = try node_val.toZig(*Node);
    const child: ?*Node = if (child_val.isNullOrUndefined()) null else try child_val.toZig(*Node);

    // parent must be a Document, DocumentFragment, or Element node.
    switch (self._type) {
        .document, .document_fragment, .element => {},
        else => return error.HierarchyError,
    }

    if (node.contains(self)) {
        return error.HierarchyError;
    }

    if (self.getRootNode(.{ .composed = true }) != node.getRootNode(.{ .composed = true })) {
        return error.HierarchyError;
    }

    // node must be an Element or a CharacterData node.
    switch (node._type) {
        .element, .cdata => {},
        else => return error.HierarchyError,
    }

    if (self._type == .document) {
        switch (node._type) {
            .cdata => |cd| {
                if (cd._type == .text) {
                    // A Text node cannot be a child of a document.
                    return error.HierarchyError;
                }
            },
            .element => {
                var it = self.childrenIterator();
                while (it.next()) |existing| {
                    if (existing._type == .element and existing != node) {
                        // A document can have at most one element child.
                        return error.HierarchyError;
                    }
                }
            },
            else => {},
        }
    }

    if (child) |c| {
        if (c._parent != self) {
            // If child is non-null, its parent must be parent.
            return error.NotFound;
        }
    }

    // Moving a node before itself is a relative no-op: the reference child
    // becomes the node's own next sibling.
    var ref = child;
    if (ref) |r| {
        if (r == node) {
            ref = node.nextSibling();
        }
    }

    frame.domChanged();

    // selfand node share a root, so the connectedness won't change. This API
    // should appear atomic as much as possible. We can skip the id-map
    // management (because it won't change) and custom elements shouldn't fire
    // disconnect/connected callbacks. But MutationObservers and ranges still
    // fire
    const connected = node.isConnected();

    if (node._parent) |old_parent| {
        frame.removeNode(old_parent, node, .{ .will_be_reconnected = connected });
    }

    if (ref) |r| {
        try frame.insertNodeRelative(self, node, .{ .before = r }, .{ .child_already_connected = connected });
    } else {
        try frame.appendNode(self, node, .{ .child_already_connected = connected });
    }

    if (connected) {
        // Enqueue on a move callback (if we're connected) for any nested
        // custom element
        const TreeWalker = @import("TreeWalker.zig");
        var tw = TreeWalker.Full.Elements.init(node, .{});
        while (tw.next()) |el| {
            Element.Html.Custom.enqueueMoveCallbackOnElement(el, frame);
        }
    }
}

pub fn getNodeValue(self: *const Node) ?String {
    return switch (self._type) {
        .cdata => |c| c.getData(),
        .attribute => |attr| attr._value,
        .element => null,
        .document => null,
        .document_type => null,
        .document_fragment => null,
    };
}

pub fn setNodeValue(self: *const Node, value: ?String, frame: *Frame) !void {
    switch (self._type) {
        // Per spec, setting nodeValue on CharacterData runs replaceData(0, length, value)
        .cdata => |c| {
            const new_value: []const u8 = if (value) |v| v.str() else "";
            try c.replaceData(0, c.getLength(), new_value, frame);
        },
        .attribute => |attr| try attr.setValue(value, frame),
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
        .node = linkToNodeOrNull(children.first),
    };
}

pub fn getChildrenCount(self: *Node) usize {
    return switch (self._type) {
        .element, .document, .document_fragment => self.getLength(),
        .document_type, .attribute, .cdata => return 0,
    };
}

pub fn getLength(self: *Node) u32 {
    switch (self._type) {
        .cdata => |cdata| {
            // The node length of CharacterData is in UTF-16 code units.
            return @intCast(cdata.getLength());
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

pub fn getData(self: *const Node) String {
    return switch (self._type) {
        .cdata => |c| c.getData(),
        else => .empty,
    };
}

pub fn setData(self: *Node, data: []const u8, frame: *Frame) !void {
    switch (self._type) {
        .cdata => |c| try c.setData(data, frame),
        else => {},
    }
}

pub fn normalize(self: *Node, frame: *Frame) !void {
    var buffer: std.ArrayList(u8) = .empty;
    return self._normalize(frame.local_arena, &buffer, frame);
}

const CloneError = error{
    OutOfMemory,
    StringTooLarge,
    NotSupported,
    NotImplemented,
    InvalidCharacterError,
    CloneError,
    Idna,
    IFrameLoadError,
    TooManyContexts,
    LinkLoadError,
    StyleLoadError,
    TypeError,
    CompilationError,
    JsException,
};
pub fn cloneNode(self: *Node, deep_: ?bool, frame: *Frame) CloneError!*Node {
    const deep = deep_ orelse false;
    switch (self._type) {
        .cdata => |cd| {
            const data = cd.getData().str();
            return switch (cd._type) {
                .text => Frame.node_factory.createTextNode(frame, data),
                .cdata_section => Frame.node_factory.createCDATASection(frame, data),
                .comment => Frame.node_factory.createComment(frame, data),
                .processing_instruction => |pi| Frame.node_factory.createProcessingInstruction(frame, pi._target, data),
            };
        },
        .element => |el| return el.clone(deep, frame),
        .document => |doc| {
            const cloned = switch (doc._type) {
                .xml => (frame._factory.document(Document.XMLDocument{ ._proto = undefined }) catch return error.CloneError).asDocument(),
                else => (frame._factory.document(Document.HTMLDocument{ ._proto = undefined }) catch return error.CloneError).asDocument(),
            };
            cloned._url = doc._url;
            cloned._ready_state = .complete;

            if (deep) {
                var child_it = self.childrenIterator();
                while (child_it.next()) |child| {
                    if (try child.cloneNodeForAppending(true, frame)) |cloned_child| {
                        _ = cloned.asNode().appendChild(cloned_child, frame) catch return error.CloneError;
                    }
                }
            }
            return cloned.asNode();
        },
        .document_type => |dt| {
            const cloned = dt.clone(frame) catch return error.CloneError;
            return cloned.asNode();
        },
        .document_fragment => |frag| return frag.cloneFragment(deep, frame),
        .attribute => |attr| {
            const cloned = attr.clone(frame) catch return error.CloneError;
            return cloned._proto;
        },
    }
}

/// Clone a node for the purpose of appending to a parent.
/// Returns null if the cloned node was already attached somewhere by a custom element
/// constructor, indicating that the constructor's decision should be respected.
///
/// This helper is used when iterating over children to clone them. The typical pattern is:
///   while (child_it.next()) |child| {
///       if (try child.cloneNodeForAppending(true, frame)) |cloned| {
///           try frame.appendNode(parent, cloned, opts);
///       }
///   }
///
/// The only case where a cloned node would already have a parent is when a custom element
/// constructor (which runs during cloning per the HTML spec) explicitly attaches the element
/// somewhere. In that case, we respect the constructor's decision and return null to signal
/// that the cloned node should not be appended to our intended parent.
pub fn cloneNodeForAppending(self: *Node, deep: bool, frame: *Frame) CloneError!?*Node {
    const cloned = try self.cloneNode(deep, frame);
    if (cloned._parent != null) {
        return null;
    }
    return cloned;
}

pub fn compareDocumentPosition(self: *Node, other: *Node) u16 {
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

fn _normalize(self: *Node, allocator: Allocator, buffer: *std.ArrayList(u8), frame: *Frame) !void {
    var it = self.childrenIterator();
    while (it.next()) |child| {
        try child._normalize(allocator, buffer, frame);
    }

    var child = self.firstChild();
    while (child) |current_node| {
        var next_node = current_node.nextSibling();

        const text_node = current_node.is(CData.Text) orelse {
            child = next_node;
            continue;
        };

        if (text_node._proto.getData().len == 0) {
            frame.removeNode(self, current_node, .{ .will_be_reconnected = false });
            child = next_node;
            continue;
        }

        if (next_node) |next| {
            if (next.is(CData.Text)) |_| {
                try buffer.appendSlice(allocator, text_node.ownData());

                while (next_node) |node_to_merge| {
                    const next_text_node = node_to_merge.is(CData.Text) orelse break;
                    try buffer.appendSlice(allocator, next_text_node.ownData());

                    const to_remove = node_to_merge;
                    next_node = node_to_merge.nextSibling();
                    frame.removeNode(self, to_remove, .{ .will_be_reconnected = false });
                }
                text_node._proto._data = try frame.dupeSSO(buffer.items);
                buffer.clearRetainingCapacity();
            }
        }

        child = next_node;
    }
}

pub const GetElementsByTagNameResult = union(enum) {
    tag: collections.NodeLive(.tag),
    tag_name: collections.NodeLive(.tag_name),
    all_elements: collections.NodeLive(.all_elements),
};
// Not exposed in the WebAPI, but used by both Element and Document
pub fn getElementsByTagName(self: *Node, tag_name: []const u8, frame: *Frame) !GetElementsByTagNameResult {
    if (tag_name.len > 256) {
        // 256 seems generous.
        return error.InvalidTagName;
    }

    if (std.mem.eql(u8, tag_name, "*")) {
        return .{
            .all_elements = collections.NodeLive(.all_elements).init(self, {}, frame),
        };
    }

    const lower = std.ascii.lowerString(&frame.buf, tag_name);
    if (Node.Element.Tag.parseForMatch(lower)) |known| {
        // optimized for known tag names, comparis
        return .{
            .tag = collections.NodeLive(.tag).init(self, known, frame),
        };
    }

    const arena = frame.arena;
    const filter = try String.init(arena, tag_name, .{});
    return .{ .tag_name = collections.NodeLive(.tag_name).init(self, filter, frame) };
}

// Not exposed in the WebAPI, but used by both Element and Document
pub fn getElementsByTagNameNS(self: *Node, namespace: ?[]const u8, local_name: []const u8, frame: *Frame) !collections.NodeLive(.tag_name_ns) {
    if (local_name.len > 256) {
        return error.InvalidTagName;
    }

    // Parse namespace - "*" means wildcard (null), null means Element.Namespace.null
    const ns: ?Element.Namespace = if (namespace) |ns_str|
        if (std.mem.eql(u8, ns_str, "*")) null else Element.Namespace.parse(ns_str)
    else
        Element.Namespace.null;

    return collections.NodeLive(.tag_name_ns).init(self, .{
        .namespace = ns,
        .local_name = try String.init(frame.arena, local_name, .{}),
    }, frame);
}

// Not exposed in the WebAPI, but used by both Element and Document
pub fn getElementsByClassName(self: *Node, class_name: []const u8, frame: *Frame) !collections.NodeLive(.class_name) {
    const arena = frame.arena;

    // Parse space-separated class names
    var class_names: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeAny(u8, class_name, "\t\n\x0C\r ");
    while (it.next()) |name| {
        try class_names.append(arena, try frame.dupeString(name));
    }

    const quirks = if (self.ownerDocumentIncludingSelf(frame)) |doc| doc.isQuirksMode() else false;
    return collections.NodeLive(.class_name).init(self, .{
        .names = class_names.items,
        .case_insensitive = quirks,
    }, frame);
}

// ParentNode.append/prepend with several nodes convert them into a fragment
// first, so the insertion happens as one operation: an earlier script must
// observe its later siblings inserted (and can remove them before they run).
pub fn appendNodes(self: *Node, nodes: []const NodeOrText, frame: *Frame) !void {
    if (nodes.len == 1) {
        const child = try nodes[0].toNode(frame);
        _ = try self.appendChild(child, frame);
        return;
    }
    const fragment = try DocumentFragment.init(frame);
    const fragment_node = fragment.asNode();
    // The fragment is internal — JS never sees it, and no mutation record
    // targets it — so it can be reclaimed once its children have moved out.
    // If conversion or insertion failed, nodes left inside stay parented to
    // it (per spec), so it must live on.
    defer if (fragment_node.firstChild() == null) frame._factory.destroy(fragment);
    for (nodes) |node_or_text| {
        const child = try node_or_text.toNode(frame);
        _ = try fragment_node.appendChild(child, frame);
    }
    _ = try self.appendChild(fragment_node, frame);
}

pub fn prependNodes(self: *Node, nodes: []const NodeOrText, frame: *Frame) !void {
    if (nodes.len == 1) {
        const child = try nodes[0].toNode(frame);
        _ = try self.insertBefore(child, self.firstChild(), frame);
        return;
    }
    const fragment = try DocumentFragment.init(frame);
    const fragment_node = fragment.asNode();
    defer if (fragment_node.firstChild() == null) frame._factory.destroy(fragment);
    for (nodes) |node_or_text| {
        const child = try node_or_text.toNode(frame);
        _ = try fragment_node.appendChild(child, frame);
    }
    // The reference child is evaluated after converting nodes into the
    // fragment: one of the arguments may be the current first child.
    _ = try self.insertBefore(fragment_node, self.firstChild(), frame);
}

/// Shared implementation of replaceChildren for Element, Document, and DocumentFragment.
/// Validates all nodes, removes existing children, then appends new children.
pub fn replaceChildren(self: *Node, nodes: []const NodeOrText, frame: *Frame) !void {
    // First pass: validate all nodes and collect them
    // We need to collect because DocumentFragments contribute their children, not themselves
    var children_to_add: std.ArrayList(*Node) = .empty;

    for (nodes) |node_or_text| {
        const child = try node_or_text.toNode(frame);

        // DocumentFragments contribute their children, not themselves
        if (child.is(DocumentFragment)) |frag| {
            var frag_it = frag.asNode().childrenIterator();
            while (frag_it.next()) |frag_child| {
                try validateNodeInsertion(self, frag_child);
                try children_to_add.append(frame.call_arena, frag_child);
            }
        } else {
            try validateNodeInsertion(self, child);
            try children_to_add.append(frame.call_arena, child);
        }
    }

    frame.domChanged();

    // Per the "replace all" algorithm, observers get one combined mutation
    // record with all removed and added nodes, so per-node notification is
    // suppressed here.
    const notify = Frame.observers.hasMutationObservers(frame);
    const removed = try self.removeAllChildrenCollecting(notify, frame);

    // Append new children
    const parent_is_connected = self.isConnected();
    for (children_to_add.items) |child| {
        var child_connected = false;
        if (child._parent) |previous_parent| {
            child_connected = child.isConnected();
            frame.removeNode(previous_parent, child, .{ .will_be_reconnected = parent_is_connected });
        }
        try frame.appendNode(self, child, .{ .child_already_connected = child_connected, .notify_observers = false });
    }

    if (notify and (removed.items.len > 0 or children_to_add.items.len > 0)) {
        Frame.observers.notifyChildListChange(frame, self, children_to_add.items, removed.items, null, null);
    }
}

// Removes every child with per-node notification suppressed, returning the
// removed nodes when `notify` is set so the caller can queue one combined
// "replace all" mutation record.
fn removeAllChildrenCollecting(self: *Node, notify: bool, frame: *Frame) !std.ArrayList(*Node) {
    var removed: std.ArrayList(*Node) = .empty;
    var it = self.childrenIterator();
    while (it.next()) |child| {
        if (notify) {
            try removed.append(frame.call_arena, child);
        }
        frame.removeNode(self, child, .{ .will_be_reconnected = false, .notify_observers = false });
    }
    return removed;
}

/// Shared implementation in Element and DocumentFragment
pub fn setHTML(self: *Node, html: []const u8, allow_declarative_shadow: bool, frame: *Frame) !void {
    frame.domChanged();

    // Observers of this subtree get one combined "replace all" mutation
    // record; per-node notification is suppressed for the removals here and
    // for the parser insertions (fragment parsing never notifies).
    const notify = Frame.observers.hasMutationObservers(frame);
    const removed = try self.removeAllChildrenCollecting(notify, frame);

    if (html.len > 0) {
        if (allow_declarative_shadow) {
            try frame.parseHtmlUnsafeAsChildren(self, html);
        } else {
            try frame.parseHtmlAsChildren(self, html);
        }
    }

    if (notify) {
        var added: std.ArrayList(*Node) = .empty;
        var child_it = self.childrenIterator();
        while (child_it.next()) |child| {
            try added.append(frame.local_arena, child);
        }
        if (removed.items.len > 0 or added.items.len > 0) {
            Frame.observers.notifyChildListChange(frame, self, added.items, removed.items, null, null);
        }
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

    pub const ELEMENT_NODE = bridge.property(1, .{ .template = true });
    pub const ATTRIBUTE_NODE = bridge.property(2, .{ .template = true });
    pub const TEXT_NODE = bridge.property(3, .{ .template = true });
    pub const CDATA_SECTION_NODE = bridge.property(4, .{ .template = true });
    pub const ENTITY_REFERENCE_NODE = bridge.property(5, .{ .template = true });
    pub const ENTITY_NODE = bridge.property(6, .{ .template = true });
    pub const PROCESSING_INSTRUCTION_NODE = bridge.property(7, .{ .template = true });
    pub const COMMENT_NODE = bridge.property(8, .{ .template = true });
    pub const DOCUMENT_NODE = bridge.property(9, .{ .template = true });
    pub const DOCUMENT_TYPE_NODE = bridge.property(10, .{ .template = true });
    pub const DOCUMENT_FRAGMENT_NODE = bridge.property(11, .{ .template = true });
    pub const NOTATION_NODE = bridge.property(12, .{ .template = true });

    pub const DOCUMENT_POSITION_DISCONNECTED = bridge.property(0x01, .{ .template = true });
    pub const DOCUMENT_POSITION_PRECEDING = bridge.property(0x02, .{ .template = true });
    pub const DOCUMENT_POSITION_FOLLOWING = bridge.property(0x04, .{ .template = true });
    pub const DOCUMENT_POSITION_CONTAINS = bridge.property(0x08, .{ .template = true });
    pub const DOCUMENT_POSITION_CONTAINED_BY = bridge.property(0x10, .{ .template = true });
    pub const DOCUMENT_POSITION_IMPLEMENTATION_SPECIFIC = bridge.property(0x20, .{ .template = true });

    pub const nodeName = bridge.accessor(struct {
        fn wrap(self: *const Node, frame: *Frame) []const u8 {
            return self.getNodeName(&frame.buf);
        }
    }.wrap, null, .{});
    pub const nodeType = bridge.accessor(Node.getNodeType, null, .{});

    pub const textContent = bridge.accessor(_textContext, Node.setTextContent, .{ .ce_reactions = true });
    fn _textContext(self: *Node, frame: *const Frame) !?[]const u8 {
        // cdata and attributes can return value directly, avoiding the copy
        switch (self._type) {
            .element, .document_fragment => {
                // local_arena: read-only text collection, result converted to
                // v8 before returning; no JS runs in between.
                var buf = std.Io.Writer.Allocating.init(frame.local_arena);
                try self.getTextContent(&buf.writer);
                return buf.written();
            },
            .cdata => |cdata| return cdata._data.str(),
            .attribute => |attr| return attr._value.str(),
            .document => return null,
            .document_type => return null,
        }
    }

    pub const firstChild = bridge.accessor(Node.firstChild, null, .{});
    pub const lastChild = bridge.accessor(Node.lastChild, null, .{});
    pub const nextSibling = bridge.accessor(Node.nextSibling, null, .{});
    pub const previousSibling = bridge.accessor(Node.previousSibling, null, .{});
    pub const parentNode = bridge.accessor(Node.parentNode, null, .{});
    pub const parentElement = bridge.accessor(Node.parentElement, null, .{});
    pub const appendChild = bridge.function(Node.appendChild, .{ .ce_reactions = true });
    pub const childNodes = bridge.accessor(Node.childNodes, null, .{ .cache = .{ .private = "child_nodes" } });
    pub const isConnected = bridge.accessor(Node.isConnected, null, .{});
    pub const ownerDocument = bridge.accessor(Node.ownerDocument, null, .{});
    pub const hasChildNodes = bridge.function(Node.hasChildNodes, .{});
    pub const isSameNode = bridge.function(Node.isSameNode, .{});
    pub const contains = bridge.function(Node.contains, .{});
    pub const removeChild = bridge.function(Node.removeChild, .{ .ce_reactions = true });
    pub const nodeValue = bridge.accessor(Node.getNodeValue, Node.setNodeValue, .{ .ce_reactions = true });
    pub const insertBefore = bridge.function(_insertBefore, .{ .ce_reactions = true });
    fn _insertBefore(self: *Node, new_node: *Node, ref_node: js.Nullable(*Node), frame: *Frame) !*Node {
        return self.insertBefore(new_node, ref_node.value, frame);
    }
    pub const replaceChild = bridge.function(Node.replaceChild, .{ .ce_reactions = true });
    pub const normalize = bridge.function(Node.normalize, .{ .ce_reactions = true });
    pub const cloneNode = bridge.function(Node.cloneNode, .{ .ce_reactions = true });
    pub const compareDocumentPosition = bridge.function(Node.compareDocumentPosition, .{});
    pub const getRootNode = bridge.function(_getRootNode, .{});
    // The `options` argument is optional in JS; default it before calling the
    // (non-optional) Node.getRootNode.
    fn _getRootNode(self: *Node, opts: ?GetRootNodeOpts) *Node {
        return self.getRootNode(opts orelse .{});
    }
    pub const isEqualNode = bridge.function(Node.isEqualNode, .{});
    pub const lookupNamespaceURI = bridge.function(Node.lookupNamespaceURI, .{});
    pub const lookupPrefix = bridge.function(Node.lookupPrefix, .{});
    pub const isDefaultNamespace = bridge.function(Node.isDefaultNamespace, .{});

    pub const baseURI = bridge.accessor(_baseURI, null, .{});
    fn _baseURI(self: *Node, frame: *const Frame) []const u8 {
        const doc = self.ownerDocumentIncludingSelf(frame) orelse return frame.base();
        if (doc._frame) |doc_frame| {
            return doc_frame.base();
        }
        return doc.getURL(frame);
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

    pub fn format(self: *const NodeOrText, writer: *std.Io.Writer) !void {
        switch (self.*) {
            .node => |n| try n.format(writer),
            .text => |text| {
                try writer.writeByte('\'');
                try writer.writeAll(text);
                try writer.writeByte('\'');
            },
        }
    }

    pub fn toNode(self: *const NodeOrText, frame: *Frame) !*Node {
        return switch (self.*) {
            .node => |n| n,
            .text => |txt| Frame.node_factory.createTextNode(frame, txt),
        };
    }

    /// DOM spec: first following sibling of `node` that is not in `nodes`.
    pub fn viableNextSibling(node: *Node, nodes: []const NodeOrText) ?*Node {
        var sibling = node.nextSibling() orelse return null;
        blk: while (true) {
            for (nodes) |n| {
                switch (n) {
                    .node => |nn| if (sibling == nn) {
                        sibling = sibling.nextSibling() orelse return null;
                        continue :blk;
                    },
                    .text => {},
                }
            } else {
                return sibling;
            }
        }
        return null;
    }
};

const testing = @import("../../testing.zig");
test "WebApi: Node" {
    try testing.htmlRunner("node", .{});
}
