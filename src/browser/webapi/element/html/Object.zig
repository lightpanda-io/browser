const js = @import("../../../js/js.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");

const Object = @This();

_proto: *HtmlElement,

pub fn asElement(self: *Object) *Element {
    return self._proto._proto;
}
pub fn asNode(self: *Object) *Node {
    return self.asElement().asNode();
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Object);

    pub const Meta = struct {
        pub const name = "HTMLObjectElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };
};
