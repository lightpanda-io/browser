const std = @import("std");

const parser = @import("../parser.zig");

const Node = @import("node.zig").Node;

pub const Element = struct {
    proto: Node,
    base: *parser.Element,

    pub const prototype = *Node;

    pub fn init(base: *parser.Element) Element {
        return .{
            .proto = Node.init(null),
            .base = base,
        };
    }

    // JS funcs
    // --------

    pub fn get_localName(self: Element) []const u8 {
        return parser.elementLocalName(self.base);
    }
};
