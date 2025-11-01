const js = @import("../../../js/js.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");

const BR = @This();

_proto: *HtmlElement,

pub fn asElement(self: *BR) *Element {
    return self._proto._proto;
}
pub fn asNode(self: *BR) *Node {
    return self.asElement().asNode();
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(BR);

    pub const Meta = struct {
        pub const name = "HTMLBRElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };
};
