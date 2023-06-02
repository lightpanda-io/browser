const std = @import("std");

const parser = @import("../parser.zig");

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

    pub fn getElementById(self: *parser.Document, elem: *parser.Element, id: []const u8) ?*parser.Element {
        const collection = parser.collectionInit(self, 1);
        defer parser.collectionDeinit(collection);
        const case_sensitve = true;
        parser.elementsByAttr(elem, collection, "id", id, case_sensitve) catch |err| {
            std.debug.print("getElementById error: {s}\n", .{@errorName(err)});
            return null;
        };
        if (collection.array.length == 0) {
            // no results
            return null;
        }
        return parser.collectionElement(collection, 0);
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
