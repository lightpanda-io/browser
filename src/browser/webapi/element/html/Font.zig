const js = @import("../../../js/js.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");

const Font = @This();

_proto: *HtmlElement,

pub fn asElement(self: *Font) *Element {
    return self._proto._proto;
}
pub fn asNode(self: *Font) *Node {
    return self.asElement().asNode();
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Font);

    pub const Meta = struct {
        pub const name = "HTMLFontElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };
};
