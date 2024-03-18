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

    pub fn nextSibling(n: Node) !?Node {
        const c = try parser.nodeNextSibling(n.node);
        if (c) |cc| return .{ .node = cc };

        return null;
    }

    pub fn isElement(n: Node) bool {
        const t = parser.nodeType(n.node) catch return false;
        return t == .element;
    }

    pub fn tag(n: Node) ![]const u8 {
        return try parser.nodeName(n.node);
    }
};
