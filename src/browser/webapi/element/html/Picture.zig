const js = @import("../../../js/js.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");

const Picture = @This();

_proto: *HtmlElement,

pub fn asElement(self: *Picture) *Element {
    return self._proto._proto;
}
pub fn asNode(self: *Picture) *Node {
    return self.asElement().asNode();
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Picture);

    pub const Meta = struct {
        pub const name = "HTMLPictureElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };
};

const testing = @import("../../../../testing.zig");
test "WebApi: Picture" {
    try testing.htmlRunner("element/html/picture.html", .{});
}
