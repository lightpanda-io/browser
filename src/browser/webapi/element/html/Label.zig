const js = @import("../../../js/js.zig");
const Page = @import("../../../Page.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");

const Label = @This();

_proto: *HtmlElement,

pub fn asElement(self: *Label) *Element {
    return self._proto._proto;
}
pub fn asNode(self: *Label) *Node {
    return self.asElement().asNode();
}

pub fn getHtmlFor(self: *Label) []const u8 {
    return self.asElement().getAttributeSafe(comptime .wrap("for")) orelse "";
}

pub fn setHtmlFor(self: *Label, value: []const u8, page: *Page) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("for"), .wrap(value), page);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Label);

    pub const Meta = struct {
        pub const name = "HTMLLabelElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const htmlFor = bridge.accessor(Label.getHtmlFor, Label.setHtmlFor, .{});
};

const testing = @import("../../../../testing.zig");
test "WebApi: HTML.Label" {
    try testing.htmlRunner("element/html/label.html", .{});
}
