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

const parser = @import("../netsurf.zig");
const Page = @import("../page.zig").Page;

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

    pub fn _isEqualNode(self: *parser.DocumentFragment, other_node: *parser.Node) !bool {
        const other_type = try parser.nodeType(other_node);
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
};

const testing = @import("../../testing.zig");
test "Browser.DOM.DocumentFragment" {
    var runner = try testing.jsRunner(testing.tracking_allocator, .{});
    defer runner.deinit();

    try runner.testCases(&.{
        .{ "const dc = new DocumentFragment()", "undefined" },
        .{ "dc.constructor.name", "DocumentFragment" },
    }, .{});

    try runner.testCases(&.{
        .{ "const dc1 = new DocumentFragment()", "undefined" },
        .{ "const dc2 = new DocumentFragment()", "undefined" },
        .{ "dc1.isEqualNode(dc1)", "true" },
        .{ "dc1.isEqualNode(dc2)", "true" },
    }, .{});

    try runner.testCases(&.{
        .{ "let f = document.createDocumentFragment()", null },
        .{ "let d = document.createElement('div');", null },
        .{ "d.id = 'x';", null },
        .{ "document.getElementById('x') == null;", "true" },

        .{ "f.append(d);", null },
        .{ "document.getElementById('x') == null;", "true" },

        .{ "document.getElementsByTagName('body')[0].append(f.cloneNode(true));", null },
        .{ "document.getElementById('x') != null;", "true" },
    }, .{});
}
