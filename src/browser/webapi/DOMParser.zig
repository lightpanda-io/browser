const std = @import("std");

const js = @import("../js/js.zig");
const Page = @import("../Page.zig");
const Document = @import("Document.zig");
const HTMLDocument = @import("HTMLDocument.zig");

const DOMParser = @This();
// @ZIGDOM support empty structs
_: u8 = 0,

pub fn init() DOMParser {
    return .{};
}

pub fn parseFromString(self: *const DOMParser, html: []const u8, mime_type: []const u8, page: *Page) !*HTMLDocument {
    _ = self;

    // For now, only support text/html
    if (!std.mem.eql(u8, mime_type, "text/html")) {
        return error.NotSupported;
    }

    // Create a new HTMLDocument
    const doc = try page._factory.document(HTMLDocument{
        ._proto = undefined,
    });

    // Parse HTML into the document
    const Parser = @import("../parser/Parser.zig");
    var parser = Parser.init(page.arena, doc.asNode(), page);
    parser.parse(html);

    if (parser.err) |pe| {
        return pe.err;
    }

    return doc;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(DOMParser);

    pub const Meta = struct {
        pub const name = "DOMParser";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(DOMParser.init, .{});
    pub const parseFromString = bridge.function(DOMParser.parseFromString, .{});
};

const testing = @import("../../testing.zig");
test "WebApi: DOMParser" {
    try testing.htmlRunner("domparser.html", .{});
}
