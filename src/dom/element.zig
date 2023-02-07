const std = @import("std");

const jsruntime = @import("jsruntime");
const Case = jsruntime.test_utils.Case;
const checkCases = jsruntime.test_utils.checkCases;

const parser = @import("../parser.zig");

const DOM = @import("../dom.zig");
const Node = DOM.Node;

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

// HTML elements
// -------------

pub const HTMLElement = struct {
    proto: Element,

    pub const prototype = *Element;

    pub fn init(elem_base: *parser.Element) HTMLElement {
        return .{ .proto = Element.init(elem_base) };
    }
};

pub const HTMLBodyElement = struct {
    proto: HTMLElement,

    pub const prototype = *HTMLElement;

    pub fn init(elem_base: *parser.Element) HTMLBodyElement {
        return .{ .proto = HTMLElement.init(elem_base) };
    }
};
