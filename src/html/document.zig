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

        // TODO: order by probability instead of alphabetically
        // TODO: this does not seems very efficient, do we have a better way?
        if (std.mem.eql(u8, tag_name, "a")) {
            return .{ .anchor = E.HTMLAnchorElement.init(base) };
        } else if (std.mem.eql(u8, tag_name, "area")) {
            return .{ .area = E.HTMLAreaElement.init(base) };
        } else if (std.mem.eql(u8, tag_name, "audio")) {
            return .{ .audio = E.HTMLAudioElement.init(base) };
        } else if (std.mem.eql(u8, tag_name, "br")) {
            return .{ .br = E.HTMLBRElement.init(base) };
        } else if (std.mem.eql(u8, tag_name, "base")) {
            return .{ .base = E.HTMLBaseElement.init(base) };
        } else if (std.mem.eql(u8, tag_name, "body")) {
            return .{ .body = E.HTMLBodyElement.init(base) };
        } else if (std.mem.eql(u8, tag_name, "button")) {
            return .{ .button = E.HTMLButtonElement.init(base) };
        } else if (std.mem.eql(u8, tag_name, "canvas")) {
            return .{ .canvas = E.HTMLCanvasElement.init(base) };
        } else if (std.mem.eql(u8, tag_name, "dl")) {
            return .{ .dlist = E.HTMLDListElement.init(base) };
        } else if (std.mem.eql(u8, tag_name, "dialog")) {
            return .{ .dialog = E.HTMLDialogElement.init(base) };
        } else if (std.mem.eql(u8, tag_name, "data")) {
            return .{ .data = E.HTMLDataElement.init(base) };
        } else if (std.mem.eql(u8, tag_name, "div")) {
            return .{ .div = E.HTMLDivElement.init(base) };
        } else if (std.mem.eql(u8, tag_name, "embed")) {
            return .{ .embed = E.HTMLEmbedElement.init(base) };
        } else if (std.mem.eql(u8, tag_name, "fieldset")) {
            return .{ .fieldset = E.HTMLFieldSetElement.init(base) };
        } else if (std.mem.eql(u8, tag_name, "form")) {
            return .{ .form = E.HTMLFormElement.init(base) };
        } else if (std.mem.eql(u8, tag_name, "frameset")) {
            return .{ .frameset = E.HTMLFrameSetElement.init(base) };
        } else if (std.mem.eql(u8, tag_name, "hr")) {
            return .{ .hr = E.HTMLHRElement.init(base) };
        } else if (std.mem.eql(u8, tag_name, "head")) {
            return .{ .head = E.HTMLHeadElement.init(base) };
        } else if (std.mem.eql(u8, tag_name, "h1")) {
            return .{ .heading = E.HTMLHeadingElement.init(base) };
        } else if (std.mem.eql(u8, tag_name, "h2")) {
            return .{ .heading = E.HTMLHeadingElement.init(base) };
        } else if (std.mem.eql(u8, tag_name, "h3")) {
            return .{ .heading = E.HTMLHeadingElement.init(base) };
        } else if (std.mem.eql(u8, tag_name, "h4")) {
            return .{ .heading = E.HTMLHeadingElement.init(base) };
        } else if (std.mem.eql(u8, tag_name, "h5")) {
            return .{ .heading = E.HTMLHeadingElement.init(base) };
        } else if (std.mem.eql(u8, tag_name, "h6")) {
            return .{ .heading = E.HTMLHeadingElement.init(base) };
        } else if (std.mem.eql(u8, tag_name, "html")) {
            return .{ .html = E.HTMLHtmlElement.init(base) };
        } else if (std.mem.eql(u8, tag_name, "iframe")) {
            return .{ .iframe = E.HTMLIFrameElement.init(base) };
        } else if (std.mem.eql(u8, tag_name, "img")) {
            return .{ .img = E.HTMLImageElement.init(base) };
        } else if (std.mem.eql(u8, tag_name, "input")) {
            return .{ .input = E.HTMLInputElement.init(base) };
        } else if (std.mem.eql(u8, tag_name, "li")) {
            return .{ .li = E.HTMLLIElement.init(base) };
        } else if (std.mem.eql(u8, tag_name, "label")) {
            return .{ .label = E.HTMLLabelElement.init(base) };
        } else if (std.mem.eql(u8, tag_name, "legend")) {
            return .{ .legend = E.HTMLLegendElement.init(base) };
        } else if (std.mem.eql(u8, tag_name, "link")) {
            return .{ .link = E.HTMLLinkElement.init(base) };
        } else if (std.mem.eql(u8, tag_name, "map")) {
            return .{ .map = E.HTMLMapElement.init(base) };
        } else if (std.mem.eql(u8, tag_name, "meta")) {
            return .{ .meta = E.HTMLMetaElement.init(base) };
        } else if (std.mem.eql(u8, tag_name, "meter")) {
            return .{ .meter = E.HTMLMeterElement.init(base) };
        } else if (std.mem.eql(u8, tag_name, "ins")) {
            return .{ .mod = E.HTMLModElement.init(base) };
        } else if (std.mem.eql(u8, tag_name, "del")) {
            return .{ .mod = E.HTMLModElement.init(base) };
        } else if (std.mem.eql(u8, tag_name, "ol")) {
            return .{ .olist = E.HTMLOListElement.init(base) };
        } else if (std.mem.eql(u8, tag_name, "object")) {
            return .{ .object = E.HTMLObjectElement.init(base) };
        } else if (std.mem.eql(u8, tag_name, "optgroup")) {
            return .{ .optgroup = E.HTMLOptGroupElement.init(base) };
        } else if (std.mem.eql(u8, tag_name, "option")) {
            return .{ .option = E.HTMLOptionElement.init(base) };
        } else if (std.mem.eql(u8, tag_name, "output")) {
            return .{ .output = E.HTMLOutputElement.init(base) };
        } else if (std.mem.eql(u8, tag_name, "p")) {
            return .{ .paragraph = E.HTMLParagraphElement.init(base) };
        } else if (std.mem.eql(u8, tag_name, "picture")) {
            return .{ .picture = E.HTMLPictureElement.init(base) };
        } else if (std.mem.eql(u8, tag_name, "pre")) {
            return .{ .pre = E.HTMLPreElement.init(base) };
        } else if (std.mem.eql(u8, tag_name, "progress")) {
            return .{ .progress = E.HTMLProgressElement.init(base) };
        } else if (std.mem.eql(u8, tag_name, "blockquote")) {
            return .{ .quote = E.HTMLQuoteElement.init(base) };
        } else if (std.mem.eql(u8, tag_name, "q")) {
            return .{ .quote = E.HTMLQuoteElement.init(base) };
        } else if (std.mem.eql(u8, tag_name, "script")) {
            return .{ .script = E.HTMLScriptElement.init(base) };
        } else if (std.mem.eql(u8, tag_name, "select")) {
            return .{ .select = E.HTMLSelectElement.init(base) };
        } else if (std.mem.eql(u8, tag_name, "source")) {
            return .{ .source = E.HTMLSourceElement.init(base) };
        } else if (std.mem.eql(u8, tag_name, "span")) {
            return .{ .span = E.HTMLSpanElement.init(base) };
        } else if (std.mem.eql(u8, tag_name, "style")) {
            return .{ .style = E.HTMLStyleElement.init(base) };
        } else if (std.mem.eql(u8, tag_name, "table")) {
            return .{ .table = E.HTMLTableElement.init(base) };
        } else if (std.mem.eql(u8, tag_name, "caption")) {
            return .{ .tablecaption = E.HTMLTableCaptionElement.init(base) };
        } else if (std.mem.eql(u8, tag_name, "th")) {
            return .{ .tablecell = E.HTMLTableCellElement.init(base) };
        } else if (std.mem.eql(u8, tag_name, "td")) {
            return .{ .tablecell = E.HTMLTableCellElement.init(base) };
        } else if (std.mem.eql(u8, tag_name, "col")) {
            return .{ .tablecol = E.HTMLTableColElement.init(base) };
        } else if (std.mem.eql(u8, tag_name, "tr")) {
            return .{ .tablerow = E.HTMLTableRowElement.init(base) };
        } else if (std.mem.eql(u8, tag_name, "thead")) {
            return .{ .tablesection = E.HTMLTableSectionElement.init(base) };
        } else if (std.mem.eql(u8, tag_name, "tbody")) {
            return .{ .tablesection = E.HTMLTableSectionElement.init(base) };
        } else if (std.mem.eql(u8, tag_name, "tfoot")) {
            return .{ .tablesection = E.HTMLTableSectionElement.init(base) };
        } else if (std.mem.eql(u8, tag_name, "template")) {
            return .{ .template = E.HTMLTemplateElement.init(base) };
        } else if (std.mem.eql(u8, tag_name, "textarea")) {
            return .{ .textarea = E.HTMLTextAreaElement.init(base) };
        } else if (std.mem.eql(u8, tag_name, "time")) {
            return .{ .time = E.HTMLTimeElement.init(base) };
        } else if (std.mem.eql(u8, tag_name, "title")) {
            return .{ .title = E.HTMLTitleElement.init(base) };
        } else if (std.mem.eql(u8, tag_name, "track")) {
            return .{ .track = E.HTMLTrackElement.init(base) };
        } else if (std.mem.eql(u8, tag_name, "ul")) {
            return .{ .ulist = E.HTMLUListElement.init(base) };
        } else if (std.mem.eql(u8, tag_name, "video")) {
            return .{ .video = E.HTMLVideoElement.init(base) };
        }
        return .{ .unknown = E.HTMLUnknownElement.init(base) };
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
