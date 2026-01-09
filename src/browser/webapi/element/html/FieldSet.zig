const js = @import("../../../js/js.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");

const FieldSet = @This();

_proto: *HtmlElement,

pub fn asElement(self: *FieldSet) *Element {
    return self._proto._proto;
}
pub fn asNode(self: *FieldSet) *Node {
    return self.asElement().asNode();
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(FieldSet);

    pub const Meta = struct {
        pub const name = "HTMLFieldSetElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };
};
