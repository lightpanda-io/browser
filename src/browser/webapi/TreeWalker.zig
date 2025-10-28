const Node = @import("Node.zig");
const Element = @import("Element.zig");

pub const Full = TreeWalker(.full);
pub const FullExcludeSelf = TreeWalker(.exclude_self);
pub const Children = TreeWalker(.children);

const Mode = enum {
    full,
    children,
    exclude_self,
};

pub fn TreeWalker(comptime mode: Mode) type {
    return struct {
        _next: ?*Node,
        _root: *Node,

        const Self = @This();
        const Opts = struct {};

        pub fn init(root: *Node, opts: Opts) Self {
            _ = opts;
            return .{
                ._next = firstNext(root),
                ._root = root,
            };
        }

        pub fn next(self: *Self) ?*Node {
            const node = self._next orelse return null;

            if (comptime mode == .children) {
                self._next = Node.linkToNodeOrNull(node._child_link.next);
                return node;
            }

            if (node._children) |children| {
                self._next = children.first();
            } else if (node._child_link.next) |n| {
                self._next = Node.linkToNode(n);
            } else {
                // No children, no next sibling - walk up until we find a next sibling or hit root
                var current = node._parent;
                while (current) |parent| {
                    if (parent == self._root) {
                        self._next = null;
                        break;
                    }
                    if (parent._child_link.next) |next_sibling| {
                        self._next = Node.linkToNode(next_sibling);
                        break;
                    }
                    current = parent._parent;
                } else {
                    self._next = null;
                }
            }
            return node;
        }

        pub fn reset(self: *Self) void {
            self._next = firstNext(self._root);
        }

        pub fn contains(self: *const Self, target: *const Node) bool {
            const root = self._root;

            if (comptime mode == .children) {
                var it = root.childrenIterator();
                while (it.next()) |child| {
                    if (child == target) {
                        return true;
                    }
                }
                return false;
            }

            var node = target;
            if ((comptime mode == .exclude_self) and node == root) {
                return false;
            }

            while (true) {
                if (node == root) {
                    return true;
                }
                node = node._parent orelse return false;
            }
        }

        pub fn clone(self: *const Self) Self {
            const root = self._root;
            return .{
                ._next = firstNext(root),
                ._root = root,
            };
        }

        fn firstNext(root: *Node) ?*Node {
            return switch (comptime mode) {
                .full => root,
                .exclude_self => root.firstChild(),
                .children => root.firstChild(),
            };
        }

        pub const Elements = struct {
            tw: Self,

            pub fn init(root: *Node, comptime opts: Opts) Elements {
                return .{
                    .tw = Self.init(root, opts),
                };
            }

            pub fn next(self: *Elements) ?*Element {
                while (self.tw.next()) |node| {
                    if (node.is(Element)) |el| {
                        return el;
                    }
                }
                return null;
            }

            pub fn reset(self: *Elements) void {
                self.tw.reset();
            }
        };
    };
}
