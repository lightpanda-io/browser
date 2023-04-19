const std = @import("std");

const parser = @import("../parser.zig");

const jsruntime = @import("jsruntime");
const Case = jsruntime.test_utils.Case;
const checkCases = jsruntime.test_utils.checkCases;

const Document = @import("../dom/document.zig").Document;

const E = @import("elements.zig");

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

    pub fn get_body(self: HTMLDocument) ?E.HTMLBodyElement {
        const body_dom = parser.documentHTMLBody(self.base);
        return E.HTMLBodyElement.init(body_dom);
    }

    pub fn _getElementById(self: HTMLDocument, id: []u8) ?E.HTMLElement {
        const body_dom = parser.documentHTMLBody(self.base);
        if (self.proto.getElementById(body_dom, id)) |elem| {
            return E.HTMLElement.init(elem.base);
        }
        return null;
    }

    pub fn _createElement(self: HTMLDocument, tag_name: []const u8) E.HTMLElements {
        const base = parser.documentCreateElement(self.proto.base.?, tag_name);
        return E.ElementToHTMLElementInterface(base);
    }
};

// Tests
// -----

fn upper(comptime name: []const u8, comptime indexes: anytype) []u8 {
    // indexes is [_]comptime_int
    comptime {
        var upper_name: [name.len]u8 = undefined;
        for (name) |char, i| {
            var toUpper = false;
            for (indexes) |index| {
                if (index == i) {
                    toUpper = true;
                    break;
                }
            }
            if (toUpper) {
                upper_name[i] = std.ascii.toUpper(char);
            } else {
                upper_name[i] = char;
            }
        }
        return &upper_name;
    }
}

// fn allUpper(comptime name: []const u8) []u8 {
//     comptime {
//         var upper_name: [name.len]u8 = undefined;
//         for (name) |char, i| {
//             upper_name[i] = std.ascii.toUpper(char);
//         }
//         return &upper_name;
//     }
// }

pub fn testExecFn(
    alloc: std.mem.Allocator,
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

    comptime var htmlElements = [_][]const u8{
        "a", // Anchor
        "area",
        "audio",
        "br", // BR
        "base",
        "body",
        "button",
        "canvas",
        "dl", // DList
        "dialog",
        "data",
        "div",
        "embed",
        "fieldset", // FieldSet
        "form",
        "frameset", // FrameSet
        "hr", // HR
        "head",
        "h1", // Heading
        "h2", // Heading
        "h3", // Heading
        "h4", // Heading
        "h5", // Heading
        "h6", // Heading
        "html",
        "iframe", // IFrame
        "img", // Image
        "input",
        "li", // LI
        "label",
        "legend",
        "link",
        "map",
        "meta",
        "meter",
        "ins", // Mod
        "del", // Mod
        "ol", // OList
        "object",
        "optgroup", // OptGroup
        "option",
        "output",
        "p", // Paragraph
        "picture",
        "pre",
        "progress",
        "blockquote", // Quote
        "q", // Quote
        "script",
        "select",
        "source",
        "span",
        "style",
        "table",
        "caption", // TableCaption
        "th", // TableCell
        "td", // TableCell
        "col", // TableCol
        "tr", // TableRow
        "thead", // TableSection
        "tbody", // TableSection
        "tfoot", // TableSection
        "template",
        "textarea", // TextArea
        "time",
        "title",
        "track",
        "ul", // UList
        "video",
    };
    var createElement: [htmlElements.len * 3]Case = undefined;
    inline for (htmlElements) |elem, i| {
        var upperName: []const u8 = undefined;
        if (std.mem.eql(u8, elem, "a")) {
            upperName = "Anchor";
        } else if (std.mem.eql(u8, elem, "dl")) {
            upperName = "DList";
        } else if (std.mem.eql(u8, elem, "fieldset")) {
            upperName = "FieldSet";
        } else if (std.mem.eql(u8, elem, "frameset")) {
            upperName = "FrameSet";
        } else if (std.mem.eql(u8, elem, "h1") or
            std.mem.eql(u8, elem, "h2") or
            std.mem.eql(u8, elem, "h3") or
            std.mem.eql(u8, elem, "h4") or
            std.mem.eql(u8, elem, "h5") or
            std.mem.eql(u8, elem, "h6"))
        {
            upperName = "Heading";
        } else if (std.mem.eql(u8, elem, "iframe")) {
            upperName = "IFrame";
        } else if (std.mem.eql(u8, elem, "img")) {
            upperName = "Image";
        } else if (std.mem.eql(u8, elem, "del") or std.mem.eql(u8, elem, "ins")) {
            upperName = "Mod";
        } else if (std.mem.eql(u8, elem, "ol")) {
            upperName = "OList";
        } else if (std.mem.eql(u8, elem, "optgroup")) {
            upperName = "OptGroup";
        } else if (std.mem.eql(u8, elem, "p")) {
            upperName = "Paragraph";
        } else if (std.mem.eql(u8, elem, "blockquote") or std.mem.eql(u8, elem, "q")) {
            upperName = "Quote";
        } else if (std.mem.eql(u8, elem, "caption")) {
            upperName = "TableCaption";
        } else if (std.mem.eql(u8, elem, "th") or std.mem.eql(u8, elem, "td")) {
            upperName = "TableCell";
        } else if (std.mem.eql(u8, elem, "col")) {
            upperName = "TableCol";
        } else if (std.mem.eql(u8, elem, "tr")) {
            upperName = "TableRow";
        } else if (std.mem.eql(u8, elem, "thead") or
            std.mem.eql(u8, elem, "tbody") or
            std.mem.eql(u8, elem, "tfoot"))
        {
            upperName = "TableSection";
        } else if (std.mem.eql(u8, elem, "textarea")) {
            upperName = "TextArea";
        } else if (std.mem.eql(u8, elem, "ul")) {
            upperName = "UList";
        } else {
            if (elem.len == 2) {
                upperName = upper(elem, [_]comptime_int{ 0, 1 });
            } else {
                upperName = upper(elem, [_]comptime_int{0});
            }
        }

        createElement[i * 3] = Case{
            .src = try std.fmt.allocPrint(alloc, "var {s}Elem = document.createElement('{s}')", .{ elem, elem }),
            .ex = "undefined",
        };
        createElement[(i * 3) + 1] = Case{
            .src = try std.fmt.allocPrint(alloc, "{s}Elem.constructor.name", .{elem}),
            .ex = try std.fmt.allocPrint(alloc, "HTML{s}Element", .{upperName}),
        };
        createElement[(i * 3) + 2] = Case{
            .src = try std.fmt.allocPrint(alloc, "{s}Elem.localName", .{elem}),
            .ex = elem,
        };
    }
    try checkCases(js_env, &createElement);

    var unknown = [_]Case{
        .{ .src = "let unknown = document.createElement('unknown')", .ex = "undefined" },
        .{ .src = "unknown.constructor.name", .ex = "HTMLUnknownElement" },
    };
    try checkCases(js_env, &unknown);
}
