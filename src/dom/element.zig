const std = @import("std");

const parser = @import("../netsurf.zig");

const Node = @import("node.zig").Node;
const HTMLElem = @import("../html/elements.zig");
pub const Union = @import("../html/elements.zig").Union;

// WEB IDL https://dom.spec.whatwg.org/#element
pub const Element = struct {
    pub const Self = parser.Element;
    pub const prototype = *Node;
    pub const mem_guarantied = true;

    pub fn toInterface(e: *parser.Element) Union {
        return HTMLElem.toInterface(Union, e);
    }

    // JS funcs
    // --------

    pub fn get_localName(self: *parser.Element) []const u8 {
        return parser.elementLocalName(self);
    }
};
