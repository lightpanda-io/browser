const std = @import("std");

const parser = @import("../netsurf.zig");

const Node = @import("node.zig").Node;
const Union = @import("node.zig").Union;

pub const Element = struct {
    pub const Self = parser.Element;
    pub const prototype = *Node;
    pub const mem_guarantied = true;

    pub fn toInterface(e: *parser.Element) Union {
        const n = @as(*parser.Node, @ptrCast(e));
        return Node.toInterface(n);
    }

    // JS funcs
    // --------

    pub fn get_localName(self: *parser.Element) []const u8 {
        return parser.elementLocalName(self);
    }
};
