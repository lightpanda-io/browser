const js = @import("../../../js/js.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");

const OL = @This();
_proto: *HtmlElement,

pub fn asElement(self: *OL) *Element {
    return self._proto._proto;
}
pub fn asNode(self: *OL) *Node {
    return self.asElement().asNode();
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(OL);

    pub const Meta = struct {
        pub const name = "HTMLOLElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_index: u16 = 0;
    };
};
