const std = @import("std");
const js = @import("../../js/js.zig");

const Node = @import("../Node.zig");
const Page = @import("../../Page.zig");
const GenericIterator = @import("iterator.zig").Entry;

// Optimized for node.childNodes, which has to be a live list.
// No need to go through a TreeWalker or add any filtering.
const ChildNodes = @This();

_last_index: usize,
_last_length: ?u32,
_last_node: ?*std.DoublyLinkedList.Node,
_cached_version: usize,
_children: ?*Node.Children,

pub const KeyIterator = GenericIterator(Iterator, "0");
pub const ValueIterator = GenericIterator(Iterator, "1");
pub const EntryIterator = GenericIterator(Iterator, null);

pub fn init(children: ?*Node.Children, page: *Page) !*ChildNodes {
    return page._factory.create(ChildNodes{
        ._last_index = 0,
        ._last_node = null,
        ._last_length = null,
        ._children = children,
        ._cached_version = page.version,
    });
}

pub fn length(self: *ChildNodes, page: *Page) !u32 {
    if (self.versionCheck(page)) {
        if (self._last_length) |cached_length| {
            return cached_length;
        }
    }
    const children = self._children orelse return 0;

    // O(N)
    const len = children.len();
    self._last_length = len;
    return len;
}

pub fn getAtIndex(self: *ChildNodes, index: usize, page: *Page) !?*Node {
    _ = self.versionCheck(page);

    var current = self._last_index;
    var node: ?*std.DoublyLinkedList.Node = null;
    if (index <= current) {
        current = 0;
        node = self.first() orelse return null;
    } else {
        node = self._last_node orelse self.first() orelse return null;
    }
    defer self._last_index = current + 1;

    while (node) |n| {
        if (index == current) {
            self._last_node = n;
            return Node.linkToNode(n);
        }
        current += 1;
        node = n.next;
    }
    self._last_node = null;
    return null;
}

pub fn first(self: *const ChildNodes) ?*std.DoublyLinkedList.Node {
    return &(self._children orelse return null).first()._child_link;
}

pub fn keys(self: *ChildNodes, page: *Page) !*KeyIterator {
    return .init(.{ .list = self }, page);
}

pub fn values(self: *ChildNodes, page: *Page) !*ValueIterator {
    return .init(.{ .list = self }, page);
}

pub fn entries(self: *ChildNodes, page: *Page) !*EntryIterator {
    return .init(.{ .list = self }, page);
}

fn versionCheck(self: *ChildNodes, page: *Page) bool {
    const current = page.version;
    if (current == self._cached_version) {
        return true;
    }
    self._last_index = 0;
    self._last_node = null;
    self._last_length = null;
    self._cached_version = current;
    return false;
}

const NodeList = @import("NodeList.zig");
pub fn runtimeGenericWrap(self: *ChildNodes, page: *Page) !*NodeList {
    return page._factory.create(NodeList{ .data = .{ .child_nodes = self } });
}

const Iterator = struct {
    index: u32 = 0,
    list: *ChildNodes,

    const Entry = struct { u32, *Node };

    pub fn next(self: *Iterator, page: *Page) !?Entry {
        const index = self.index;
        const node = try self.list.getAtIndex(index, page) orelse return null;
        self.index = index + 1;
        return .{ index, node };
    }
};
