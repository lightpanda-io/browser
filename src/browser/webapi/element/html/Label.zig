const js = @import("../../../js/js.zig");
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

pub const JsApi = struct {
    pub const bridge = js.Bridge(Label);

    pub const Meta = struct {
        pub const name = "HTMLLabelElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };
};
