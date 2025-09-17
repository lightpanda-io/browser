// Copyright (C) 2023-2024  Lightpanda (Selecy SAS)
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

const css = @import("css.zig");
const parser = @import("../netsurf.zig");
const Page = @import("../page.zig").Page;
const NodeList = @import("nodelist.zig").NodeList;
const Element = @import("element.zig").Element;
const ElementUnion = @import("element.zig").Union;
const collection = @import("html_collection.zig");

const Node = @import("node.zig").Node;

// WEB IDL https://dom.spec.whatwg.org/#documentfragment
pub const DocumentFragment = struct {
    pub const Self = parser.DocumentFragment;
    pub const prototype = *Node;
    pub const subtype = .node;

    pub fn constructor(page: *const Page) !*parser.DocumentFragment {
        return parser.documentCreateDocumentFragment(
            parser.documentHTMLToDocument(page.window.document),
        );
    }

    pub fn _isEqualNode(self: *parser.DocumentFragment, other_node: *parser.Node) bool {
        const other_type = parser.nodeType(other_node);
        if (other_type != .document_fragment) {
            return false;
        }
        _ = self;
        return true;
    }

    pub fn _prepend(self: *parser.DocumentFragment, nodes: []const Node.NodeOrText) !void {
        return Node.prepend(parser.documentFragmentToNode(self), nodes);
    }

    pub fn _append(self: *parser.DocumentFragment, nodes: []const Node.NodeOrText) !void {
        return Node.append(parser.documentFragmentToNode(self), nodes);
    }

    pub fn _replaceChildren(self: *parser.DocumentFragment, nodes: []const Node.NodeOrText) !void {
        return Node.replaceChildren(parser.documentFragmentToNode(self), nodes);
    }

    pub fn _querySelector(self: *parser.DocumentFragment, selector: []const u8, page: *Page) !?ElementUnion {
        if (selector.len == 0) return null;

        const n = try css.querySelector(page.call_arena, parser.documentFragmentToNode(self), selector);

        if (n == null) return null;

        return try Element.toInterface(parser.nodeToElement(n.?));
    }

    pub fn _querySelectorAll(self: *parser.DocumentFragment, selector: []const u8, page: *Page) !NodeList {
        return css.querySelectorAll(page.arena, parser.documentFragmentToNode(self), selector);
    }

    pub fn get_childElementCount(self: *parser.DocumentFragment) !u32 {
        var children = try get_children(self);
        return children.get_length();
    }

    pub fn get_children(self: *parser.DocumentFragment) !collection.HTMLCollection {
        return collection.HTMLCollectionChildren(parser.documentFragmentToNode(self), .{
            .include_root = false,
        });
    }

    pub fn _getElementById(self: *parser.DocumentFragment, id: []const u8) !?ElementUnion {
        const e = try parser.nodeGetElementById(@ptrCast(@alignCast(self)), id) orelse return null;
        return try Element.toInterface(e);
    }
};

const testing = @import("../../testing.zig");
test "Browser: DOM.DocumentFragment" {
    try testing.htmlRunner("dom/document_fragment.html");
}
