const std = @import("std");

const jsruntime = @import("jsruntime");
const Case = jsruntime.test_utils.Case;
const checkCases = jsruntime.test_utils.checkCases;

const parser = @import("../parser.zig");

const DOM = @import("../dom.zig");
const Node = DOM.Node;
const Element = DOM.Element;
const HTMLElement = DOM.HTMLElement;
const HTMLBodyElement = DOM.HTMLBodyElement;

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

    fn getElementById(self: Document, elem_dom: *parser.Element, id: []const u8) ?Element {
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

pub const HTMLDocument = struct {
    proto: Document,
    base: *parser.DocumentHTML,

    pub const prototype = *Document;

    pub fn init() HTMLDocument {
        return .{
            .proto = Document.init(null),
            .base = parser.documentHTMLInit(),
        };
    }

    pub fn deinit(self: HTMLDocument) void {
        parser.documentHTMLDeinit(self.base);
    }

    pub fn parse(self: *HTMLDocument, html: []const u8) !void {
        try parser.documentHTMLParse(self.base, html);
        self.proto.base = parser.documentHTMLToDocument(self.base);
    }

    // JS funcs
    // --------

    pub fn get_body(self: HTMLDocument) ?HTMLBodyElement {
        const body_dom = parser.documentHTMLBody(self.base);
        return HTMLBodyElement.init(body_dom);
    }

    pub fn _getElementById(self: HTMLDocument, id: []u8) ?HTMLElement {
        const body_dom = parser.documentHTMLBody(self.base);
        if (self.proto.getElementById(body_dom, id)) |elem| {
            return HTMLElement.init(elem.base);
        }
        return null;
    }
};

pub fn testExecFn(
    js_env: *jsruntime.Env,
    comptime _: []jsruntime.API,
) !void {
    var constructor = [_]Case{
        .{ .src = "document.__proto__.constructor.name", .ex = "HTMLDocument" },
        .{ .src = "document.__proto__.__proto__.constructor.name", .ex = "Document" },
        .{ .src = "document.__proto__.__proto__.__proto__.constructor.name", .ex = "Node" },
        .{ .src = "document.__proto__.__proto__.__proto__.__proto__.constructor.name", .ex = "EventTarget" },
    };
    try checkCases(js_env, &constructor);

    var getElementById = [_]Case{
        .{ .src = "let getElementById = document.getElementById('content')", .ex = "undefined" },
        .{ .src = "getElementById.constructor.name", .ex = "HTMLElement" },
        .{ .src = "getElementById.localName", .ex = "main" },
    };
    try checkCases(js_env, &getElementById);
}
