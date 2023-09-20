const std = @import("std");

const parser = @import("../netsurf.zig");

const Node = @import("node.zig").Node;
const Element = @import("element.zig").Element;

pub const Document = struct {
    pub const Self = parser.Document;
    pub const prototype = *Node;
    pub const mem_guarantied = true;

    // pub fn constructor() *parser.Document {
    //     // TODO
    //     return .{};
    // }

    pub fn getElementById(self: *parser.Document, id: []const u8) ?*parser.Element {
        return parser.documentGetElementById(self, id);
    }

    // JS funcs
    // --------

    pub fn get_body(_: *parser.Document) ?*parser.Body {
        // TODO
        return null;
    }

    pub fn _getElementById(_: *parser.Document, _: []u8) ?*parser.Element {
        // TODO
        return null;
    }
};
