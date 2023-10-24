const std = @import("std");

const parser = @import("../netsurf.zig");

const jsruntime = @import("jsruntime");

const Element = @import("element.zig").Element;

// WEB IDL https://dom.spec.whatwg.org/#htmlcollection
pub const HTMLCollection = struct {
    pub const Self = parser.HTMLCollection;
    pub const mem_guarantied = true;

    // JS funcs
    // --------

    pub fn _get_length(self: *parser.HTMLCollection) u32 {
        return parser.HTMLCollectionLength(self);
    }

    pub fn _item(self: *parser.HTMLCollection, index: u32) ?*parser.Element {
        return parser.HTMLCollectionItem(self, index);
    }

    pub fn _namedItem(self: *parser.HTMLCollection, name: []const u8) ?*parser.Element {
        return parser.HTMLCollectionNamedItem(self, name);
    }
};
