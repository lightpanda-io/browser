const js = @import("../../../js/js.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");

const HR = @This();
_proto: *HtmlElement,

pub fn asElement(self: *HR) *Element {
    return self._proto._proto;
}
pub fn asNode(self: *HR) *Node {
    return self.asElement().asNode();
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(HR);

    pub const Meta = struct {
        pub const name = "HTMLHRElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_index: u16 = 0;
    };
};
