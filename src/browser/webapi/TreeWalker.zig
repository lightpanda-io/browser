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
        _current: ?*Node = null,
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
            self._current = node;

            if (comptime mode == .children) {
                self._next = node.nextSibling();
                return node;
            }

            if (node.firstChild()) |child| {
                self._next = child;
            } else {
                var current: *Node = node;
                while (current != self._root) {
                    if (current.nextSibling()) |sibling| {
                        self._next = sibling;
                        return node;
                    }
                    current = current._parent orelse break;
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
                if (current.nextSibling()) |sibling| {
                    self._next = sibling;
                    return;
                }
                current = current._parent orelse break;
            }
            self._next = null;
        }

        pub fn reset(self: *Self) void {
            self._current = null;
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

test "TreeWalker: skipChildren" {
    const testing = @import("../../testing.zig");
    const page = try testing.test_session.createPage();
    defer testing.test_session.removePage();
    const doc = page.window._document;

    // <div>
    //   <span>
    //     <b>A</b>
    //   </span>
    //   <p>B</p>
    // </div>
    const div = try doc.createElement("div", null, page);
    const span = try doc.createElement("span", null, page);
    const b = try doc.createElement("b", null, page);
    const p = try doc.createElement("p", null, page);
    _ = try span.asNode().appendChild(b.asNode(), page);
    _ = try div.asNode().appendChild(span.asNode(), page);
    _ = try div.asNode().appendChild(p.asNode(), page);

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
