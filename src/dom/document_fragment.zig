const std = @import("std");

const parser = @import("../netsurf.zig");

const Node = @import("node.zig").Node;

// WEB IDL https://dom.spec.whatwg.org/#documentfragment
pub const DocumentFragment = struct {
    pub const Self = parser.DocumentFragment;
    pub const prototype = *Node;
    pub const mem_guarantied = true;

    // TODO add constructor, but I need to associate the new DocumentFragment
    // with the current document global object...
    // > The new DocumentFragment() constructor steps are to set this’s node
    // > document to current global object’s associated Document.
    // https://dom.spec.whatwg.org/#dom-documentfragment-documentfragment
    pub fn constructor() !*parser.DocumentFragment {
        return error.NotImplemented;
    }
};
