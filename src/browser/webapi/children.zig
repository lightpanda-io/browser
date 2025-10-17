const std = @import("std");

const Node = @import("Node.zig");

const LinkedList = std.DoublyLinkedList;

// Our node._chilren is of type ?*NodeList. The extra (extra) indirection is to
// keep memory size down.
// First, a lot of nodes have no children. For these nodes, `?*NodeList = null`
// will take 8 bytes and require no allocations (because an optional pointer in
// Zig uses the address 0 to represent null, rather than a separate field).
// Second, a lot of nodes will have one child. For these nodes, we'll also only
// use 8 bytes, because @sizeOf(NodeList) == 8. This is the reason the
// list: *LinkedList is behind a pointer.
pub const Children = union(enum) {
    one: *Node,
    list: *LinkedList,

    pub fn first(self: *const Children) *Node {
        return switch (self.*) {
            .one => |n| n,
            .list => |list| Node.linkToNode(list.first.?),
        };
    }

    pub fn last(self: *const Children) *Node {
        return switch (self.*) {
            .one => |n| n,
            .list => |list| Node.linkToNode(list.last.?),
        };
    }

    pub fn len(self: *const Children) u32 {
        return switch (self.*) {
            .one => 1,
            .list => |list| @intCast(list.len()),
        };
    }
};
