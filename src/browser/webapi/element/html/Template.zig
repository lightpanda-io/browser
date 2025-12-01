const std = @import("std");

const js = @import("../../../js/js.zig");
const Page = @import("../../../Page.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");
const DocumentFragment = @import("../../DocumentFragment.zig");

const Template = @This();

_proto: *HtmlElement,
_content: *DocumentFragment,

pub fn asElement(self: *Template) *Element {
    return self._proto._proto;
}
pub fn asNode(self: *Template) *Node {
    return self.asElement().asNode();
}

pub fn getContent(self: *Template) *DocumentFragment {
    return self._content;
}

pub fn setInnerHTML(self: *Template, html: []const u8, page: *Page) !void {
    return self._content.setInnerHTML(html, page);
}

pub fn getOuterHTML(self: *Template, writer: *std.Io.Writer, page: *Page) !void {
    const dump = @import("../../../dump.zig");
    const el = self.asElement();

    try el.format(writer);
    try dump.children(self._content.asNode(), .{ .shadow = .skip }, writer, page);
    try writer.writeAll("</");
    try writer.writeAll(el.getTagNameDump());
    try writer.writeByte('>');
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Template);

    pub const Meta = struct {
        pub const name = "HTMLTemplateElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const content = bridge.accessor(Template.getContent, null, .{});
    pub const innerHTML = bridge.accessor(_getInnerHTML, Template.setInnerHTML, .{});
    pub const outerHTML = bridge.accessor(_getOuterHTML, null, .{});

    fn _getInnerHTML(self: *Template, page: *Page) ![]const u8 {
        var buf = std.Io.Writer.Allocating.init(page.call_arena);
        try self._content.getInnerHTML(&buf.writer, page);
        return buf.written();
    }

    fn _getOuterHTML(self: *Template, page: *Page) ![]const u8 {
        var buf = std.Io.Writer.Allocating.init(page.call_arena);
        try self.getOuterHTML(&buf.writer, page);
        return buf.written();
    }
};

pub const Build = struct {
    pub fn created(node: *Node, page: *Page) !void {
        const self = node.as(Template);
        // Create the template content DocumentFragment
        self._content = try DocumentFragment.init(page);
    }
};

const testing = @import("../../../../testing.zig");
test "WebApi: Template" {
    try testing.htmlRunner("element/html/template.html", .{});
}
