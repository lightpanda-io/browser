const std = @import("std");

const parser = @import("../netsurf.zig");

const Node = @import("node.zig").Node;

pub const Element = struct {
    pub const Self = parser.Element;
    pub const prototype = *Node;
    pub const mem_guarantied = true;

    // JS funcs
    // --------

    pub fn get_localName(self: *parser.Element) []const u8 {
        return parser.elementLocalName(self);
    }
};
