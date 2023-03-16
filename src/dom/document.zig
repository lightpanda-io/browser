const std = @import("std");

const parser = @import("../parser.zig");

const Node = @import("node.zig").Node;
const Element = @import("element.zig").Element;

pub const Document = struct {
    proto: Node,
    base: ?*parser.Document,

    pub const prototype = *Node;

    pub fn init(base: ?*parser.Document) Document {
        return .{
            .proto = Node.init(null),
            .base = base,
        };
    }

    pub fn constructor() Document {
        return Document.init(null);
    }

    pub fn getElementById(self: Document, elem_dom: *parser.Element, id: []const u8) ?Element {
        if (self.base == null) {
            return null;
        }
        const collection = parser.collectionInit(self.base.?, 1);
        defer parser.collectionDeinit(collection);
        const case_sensitve = true;
        parser.elementsByAttr(elem_dom, collection, "id", id, case_sensitve) catch |err| {
            std.debug.print("getElementById error: {s}\n", .{@errorName(err)});
            return null;
        };
        if (collection.array.length == 0) {
            // no results
            return null;
        }
        const element_base = parser.collectionElement(collection, 0);
        return Element.init(element_base);
    }

    // JS funcs
    // --------

    pub fn get_body(_: Document) ?void {
        // TODO
        return null;
    }

    pub fn _getElementById(_: Document, _: []u8) ?Element {
        // TODO
        return null;
    }
};
