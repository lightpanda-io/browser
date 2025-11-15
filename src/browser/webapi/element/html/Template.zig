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

pub const JsApi = struct {
    pub const bridge = js.Bridge(Template);

    pub const Meta = struct {
        pub const name = "HTMLTemplateElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const content = bridge.accessor(Template.getContent, null, .{});
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
