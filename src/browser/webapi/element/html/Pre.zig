const js = @import("../../../js/js.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");

const Pre = @This();

pub const Proto = HtmlElement;

_proto: *HtmlElement,

pub fn asElement(self: *Pre) *Element {
    return self._proto.asElement();
}
pub fn asNode(self: *Pre) *Node {
    return self.asElement().asNode();
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Pre);

    pub const Meta = struct {
        pub const name = "HTMLPreElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };
};
