const std = @import("std");

const parser = @import("../netsurf.zig");

const Node = @import("node.zig").Node;
const NodeUnion = @import("node.zig").Union;
const Element = @import("element.zig").Element;
const HTMLBodyElement = @import("../html/elements.zig").HTMLBodyElement;

pub const Document = struct {
    pub const Self = parser.Document;
    pub const prototype = *Node;
    pub const mem_guarantied = true;

    // pub fn constructor() *parser.Document {
    //     // TODO
    //     return .{};
    // }

    // JS funcs
    // --------

    pub fn get_body(self: *parser.Document) ?*HTMLBodyElement {
        const b = parser.documentBody(self) orelse null;
        return @as(*HTMLBodyElement, @ptrCast(b));
    }

    pub fn _getElementById(self: *parser.Document, id: []const u8) ?NodeUnion {
        const e = parser.documentGetElementById(self, id) orelse return null;
        return Element.toInterface(e);
    }

    pub fn _createElement(self: *parser.Document, tag_name: []const u8) NodeUnion {
        const e = parser.documentCreateElement(self, tag_name);
        return Element.toInterface(e);
    }
};
