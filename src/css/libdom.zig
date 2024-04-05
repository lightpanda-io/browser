const std = @import("std");

const parser = @import("../netsurf.zig");

// Node implementation with Netsurf Libdom C lib.
pub const Node = struct {
    node: *parser.Node,

    pub fn firstChild(n: Node) !?Node {
        const c = try parser.nodeFirstChild(n.node);
        if (c) |cc| return .{ .node = cc };

        return null;
    }

    pub fn lastChild(n: Node) !?Node {
        const c = try parser.nodeLastChild(n.node);
        if (c) |cc| return .{ .node = cc };

        return null;
    }

    pub fn nextSibling(n: Node) !?Node {
        const c = try parser.nodeNextSibling(n.node);
        if (c) |cc| return .{ .node = cc };

        return null;
    }

    pub fn prevSibling(n: Node) !?Node {
        const c = try parser.nodePreviousSibling(n.node);
        if (c) |cc| return .{ .node = cc };

        return null;
    }

    pub fn parent(n: Node) !?Node {
        const c = try parser.nodeParentNode(n.node);
        if (c) |cc| return .{ .node = cc };

        return null;
    }

    pub fn isElement(n: Node) bool {
        const t = parser.nodeType(n.node) catch return false;
        return t == .element;
    }

    pub fn isDocument(n: Node) bool {
        const t = parser.nodeType(n.node) catch return false;
        return t == .document;
    }

    pub fn isComment(n: Node) bool {
        const t = parser.nodeType(n.node) catch return false;
        return t == .comment;
    }

    pub fn isText(n: Node) bool {
        const t = parser.nodeType(n.node) catch return false;
        return t == .text;
    }

    pub fn isEmptyText(n: Node) !bool {
        const data = try parser.nodeTextContent(n.node);
        if (data == null) return true;
        if (data.?.len == 0) return true;

        return std.mem.trim(u8, data.?, &std.ascii.whitespace).len == 0;
    }

    pub fn tag(n: Node) ![]const u8 {
        return try parser.nodeName(n.node);
    }

    pub fn attr(n: Node, key: []const u8) !?[]const u8 {
        if (!n.isElement()) return null;
        return try parser.elementGetAttribute(parser.nodeToElement(n.node), key);
    }

    pub fn eql(a: Node, b: Node) bool {
        return a.node == b.node;
    }
};
