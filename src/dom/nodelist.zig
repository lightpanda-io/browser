const std = @import("std");

const parser = @import("../netsurf.zig");

const jsruntime = @import("jsruntime");

const NodeUnion = @import("node.zig").Union;
const Node = @import("node.zig").Node;

const DOMException = @import("exceptions.zig").DOMException;

// WEB IDL https://dom.spec.whatwg.org/#nodelist
pub const NodeList = struct {
    pub const Self = parser.NodeList;
    pub const mem_guarantied = true;

    pub const Exception = DOMException;

    pub fn get_length(self: *parser.NodeList) !u32 {
        return try parser.nodeListLength(self);
    }

    pub fn _item(self: *parser.NodeList, index: u32) !?NodeUnion {
        const n = try parser.nodeListItem(self, index);
        if (n == null) return null;
        return try Node.toInterface(n.?);
    }

    // TODO _symbol_iterator

    // TODO implement postAttach
};
