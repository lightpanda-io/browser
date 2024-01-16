const std = @import("std");

const parser = @import("../netsurf.zig");

pub const Walker = union(enum) {
    walkerDepthFirst: WalkerDepthFirst,
    walkerChildren: WalkerChildren,
    walkerNone: WalkerNone,

    pub fn get_next(self: Walker, root: *parser.Node, cur: ?*parser.Node) !?*parser.Node {
        switch (self) {
            inline else => |case| return case.get_next(root, cur),
        }
    }
};

// WalkerDepthFirst iterates over the DOM tree to return the next following
// node or null at the end.
//
// This implementation is a zig version of Netsurf code.
// http://source.netsurf-browser.org/libdom.git/tree/src/html/html_collection.c#n177
//
// The iteration is a depth first as required by the specification.
// https://dom.spec.whatwg.org/#htmlcollection
// https://dom.spec.whatwg.org/#concept-tree-order
pub const WalkerDepthFirst = struct {
    pub fn get_next(_: WalkerDepthFirst, root: *parser.Node, cur: ?*parser.Node) !?*parser.Node {
        var n = cur orelse root;

        // TODO deinit next
        if (try parser.nodeFirstChild(n)) |next| {
            return next;
        }

        // TODO deinit next
        if (try parser.nodeNextSibling(n)) |next| {
            return next;
        }

        // TODO deinit parent
        // Back to the parent of cur.
        // If cur has no parent, then the iteration is over.
        var parent = try parser.nodeParentNode(n) orelse return null;

        // TODO deinit lastchild
        var lastchild = try parser.nodeLastChild(parent);
        while (n != root and n == lastchild) {
            n = parent;

            // TODO deinit parent
            // Back to the prev's parent.
            // If prev has no parent, then the loop must stop.
            parent = try parser.nodeParentNode(n) orelse break;

            // TODO deinit lastchild
            lastchild = try parser.nodeLastChild(parent);
        }

        if (n == root) {
            return null;
        }

        return try parser.nodeNextSibling(n);
    }
};

// WalkerChildren iterates over the root's children only.
pub const WalkerChildren = struct {
    pub fn get_next(_: WalkerChildren, root: *parser.Node, cur: ?*parser.Node) !?*parser.Node {
        // On walk start, we return the first root's child.
        if (cur == null) return try parser.nodeFirstChild(root);

        // If cur is root, then return null.
        // This is a special case, if the root is included in the walk, we
        // don't want to go further to find children.
        if (root == cur.?) return null;

        return try parser.nodeNextSibling(cur.?);
    }
};

pub const WalkerNone = struct {
    pub fn get_next(_: WalkerNone, _: *parser.Node, _: ?*parser.Node) !?*parser.Node {
        return null;
    }
};
