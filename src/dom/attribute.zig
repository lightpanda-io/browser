const std = @import("std");

const parser = @import("../netsurf.zig");

const Node = @import("node.zig").Node;
const DOMException = @import("exceptions.zig").DOMException;

// WEB IDL https://dom.spec.whatwg.org/#attr
pub const Attr = struct {
    pub const Self = parser.Attribute;
    pub const prototype = *Node;
    pub const mem_guarantied = true;

    pub const Exception = DOMException;
};
