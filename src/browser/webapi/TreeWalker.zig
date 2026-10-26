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

const Node = @import("Node.zig");
const Element = @import("Element.zig");
const Frame = @import("../Frame.zig");

pub const Full = TreeWalker(.full, .dom);
pub const Children = TreeWalker(.children, .dom);
pub const FullExcludeSelf = TreeWalker(.exclude_self, .dom);

// Pierces the shadow roots, apply slots/fallback and skip unslotted light children
pub const Flat = TreeWalker(.full, .flat);
pub const FlatChildren = TreeWalker(.children, .flat);
pub const FlatExcludeSelf = TreeWalker(.exclude_self, .flat);

const Mode = enum {
    full,
    children,
    exclude_self,
};

const Tree = enum {
    dom,
    flat,
};

pub fn TreeWalker(comptime mode: Mode, comptime tree: Tree) type {
    return struct {
        _current: ?*Node = null,
        _next: ?*Node,
        _root: *Node,
        _frame: if (tree == .flat) *const Frame else void,

        const Self = @This();
        const Opts = if (tree == .flat) struct { frame: *const Frame } else struct {};

        pub fn init(root: *Node, opts: Opts) Self {
            var self: Self = .{
                ._next = null,
                ._root = root,
                ._frame = if (comptime tree == .flat) opts.frame else {},
            };
            self._next = self.firstNext();
            return self;
        }

        pub fn next(self: *Self) ?*Node {
            const node = self._next orelse return null;
            self._current = node;

            if (comptime mode == .children) {
                self._next = self.nextSiblingOf(node);
                return node;
            }

            if (self.firstChildOf(node)) |child| {
                self._next = child;
            } else {
                var current: *Node = node;
                while (current != self._root) {
                    if (self.nextSiblingOf(current)) |sibling| {
                        self._next = sibling;
                        return node;
                    }
                    current = self.parentOf(current) orelse break;
                }
                self._next = null;
            }
            return node;
        }

        pub fn skipChildren(self: *Self) void {
            if (comptime mode == .children) return;
            const current_node = self._current orelse return;

            var current: *Node = current_node;
            while (current != self._root) {
                if (self.nextSiblingOf(current)) |sibling| {
                    self._next = sibling;
                    return;
                }
                current = self.parentOf(current) orelse break;
            }
            self._next = null;
        }

        pub fn reset(self: *Self) void {
            self._current = null;
            self._next = self.firstNext();
        }

        pub fn contains(self: *const Self, target: *const Node) bool {
            const root = self._root;

            if (comptime mode == .children) {
                var child = self.firstChildOf(root);
                while (child) |c| : (child = self.nextSiblingOf(c)) {
                    if (c == target) {
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
                node = self.parentOf(@constCast(node)) orelse return false;
            }
        }

        pub fn clone(self: *const Self) Self {
            var copy: Self = .{
                ._next = null,
                ._root = self._root,
                ._frame = self._frame,
            };
            copy._next = copy.firstNext();
            return copy;
        }

        fn firstNext(self: *const Self) ?*Node {
            return switch (comptime mode) {
                .full => self._root,
                .exclude_self, .children => self.firstChildOf(self._root),
            };
        }

        fn firstChildOf(self: *const Self, node: *Node) ?*Node {
            if (comptime tree == .flat) {
                return node.flatFirstChild(self._frame);
            }
            return node.firstChild();
        }

        fn nextSiblingOf(self: *const Self, node: *Node) ?*Node {
            if (comptime tree == .flat) {
                return node.flatNextSibling(self._frame);
            }
            return node.nextSibling();
        }

        fn parentOf(self: *const Self, node: *Node) ?*Node {
            if (comptime tree == .flat) {
                return node.flatParent(self._frame);
            }
            return node._parent;
        }

        pub const Elements = struct {
            tw: Self,

            pub fn init(root: *Node, opts: Opts) Elements {
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

        pub fn ElementsOf(comptime T: type) type {
            return struct {
                tw: Self,

                const It = @This();

                pub fn init(root: *Node, opts: Opts) It {
                    return .{
                        .tw = Self.init(root, opts),
                    };
                }

                pub fn next(self: *It) ?*T {
                    while (self.tw.next()) |node| {
                        if (node.is(T)) |t| {
                            return t;
                        }
                    }
                    return null;
                }
            };
        }
    };
}

test "TreeWalker: skipChildren" {
    const testing = @import("../../testing.zig");
    const frame = try testing.createFrame();
    defer testing.test_session.closeAllPages();
    const doc = frame.window._document;

    // <div>
    //   <span>
    //     <b>A</b>
    //   </span>
    //   <p>B</p>
    // </div>
    const div = try doc.createElement("div", null, frame);
    const span = try doc.createElement("span", null, frame);
    const b = try doc.createElement("b", null, frame);
    const p = try doc.createElement("p", null, frame);
    _ = try span.asNode().appendChild(b.asNode(), frame);
    _ = try div.asNode().appendChild(span.asNode(), frame);
    _ = try div.asNode().appendChild(p.asNode(), frame);

    var tw = Full.init(div.asNode(), .{});

    // root (div)
    try testing.expect(tw.next() == div.asNode());

    // span
    try testing.expect(tw.next() == span.asNode());

    // skip children of span (should jump over <b> to <p>)
    tw.skipChildren();
    try testing.expect(tw.next() == p.asNode());

    try testing.expect(tw.next() == null);
}
