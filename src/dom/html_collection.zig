const std = @import("std");

const parser = @import("../netsurf.zig");

const jsruntime = @import("jsruntime");

const Element = @import("element.zig").Element;

// WEB IDL https://dom.spec.whatwg.org/#htmlcollection
// HTMLCollection is re implemented in zig here because libdom
// dom_html_collection expects a comparison function callback as arguement.
// But we wanted a dynamically comparison here, according to the match tagname.
pub const HTMLCollection = struct {
    pub const mem_guarantied = true;

    root: *parser.Node,
    // match is used to select node against their name.
    // match comparison is case sensitive.
    match: []const u8,

    /// _get_length computes the collection's length dynamically according to
    /// the current root structure.
    // TODO: nodes retrieved must be de-referenced.
    pub fn get_length(self: *HTMLCollection) u32 {
        var len: u32 = 0;
        var node: ?*parser.Node = self.root;
        var ntype: parser.NodeType = undefined;

        var is_wildcard = std.mem.eql(u8, self.match, "*");

        while (node != null) {
            ntype = parser.nodeType(node.?);
            if (ntype == .element) {
                if (is_wildcard or std.mem.eql(u8, self.match, parser.nodeName(node.?))) {
                    len += 1;
                }
            }

            // Iterate hover the DOM tree.
            var next = parser.nodeFirstChild(node.?);
            if (next != null) {
                node = next;
                continue;
            }

            next = parser.nodeNextSibling(node.?);
            if (next != null) {
                node = next;
                continue;
            }

            var parent = parser.nodeParentNode(node.?);
            var lastchild = parser.nodeLastChild(parent.?);
            while (node.? != self.root and node.? == lastchild) {
                node = parent;
                parent = parser.nodeParentNode(node.?);
                lastchild = parser.nodeLastChild(parent.?);
            }

            if (node.? == self.root) {
                node = null;
                continue;
            }

            node = parser.nodeNextSibling(node.?);
        }

        return len;
    }

    pub fn _item(self: *HTMLCollection, index: u32) ?*parser.Element {
        var len: u32 = 0;
        var node: ?*parser.Node = self.root;
        var ntype: parser.NodeType = undefined;

        var is_wildcard = std.mem.eql(u8, self.match, "*");

        while (node != null) {
            ntype = parser.nodeType(node.?);
            if (ntype == .element) {
                if (is_wildcard or std.mem.eql(u8, self.match, parser.nodeName(node.?))) {
                    len += 1;

                    // check if we found the searched element.
                    if (len == index + 1) {
                        return @as(*parser.Element, @ptrCast(node));
                    }
                }
            }

            // Iterate hover the DOM tree.
            var next = parser.nodeFirstChild(node.?);
            if (next != null) {
                node = next;
                continue;
            }

            next = parser.nodeNextSibling(node.?);
            if (next != null) {
                node = next;
                continue;
            }

            var parent = parser.nodeParentNode(node.?);
            var lastchild = parser.nodeLastChild(parent.?);
            while (node.? != self.root and node.? == lastchild) {
                node = parent;
                parent = parser.nodeParentNode(node.?);
                lastchild = parser.nodeLastChild(parent.?);
            }

            if (node.? == self.root) {
                node = null;
                continue;
            }

            node = parser.nodeNextSibling(node.?);
        }

        return null;
    }

    pub fn _namedItem(self: *HTMLCollection, name: []const u8) ?*parser.Element {
        _ = name;
        _ = self;
        return null;
    }
};
