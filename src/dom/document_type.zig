const std = @import("std");

const parser = @import("../netsurf.zig");

const Node = @import("node.zig").Node;

// WEB IDL https://dom.spec.whatwg.org/#documenttype
pub const DocumentType = struct {
    pub const Self = parser.DocumentType;
    pub const prototype = *Node;
    pub const mem_guarantied = true;

    pub fn get_name(self: *parser.DocumentType) []const u8 {
        return parser.documentTypeGetName(self);
    }

    pub fn get_publicId(self: *parser.DocumentType) []const u8 {
        return parser.documentTypeGetPublicId(self);
    }

    pub fn get_systemId(self: *parser.DocumentType) []const u8 {
        return parser.documentTypeGetSystemId(self);
    }
};
