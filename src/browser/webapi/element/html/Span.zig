const js = @import("../../../js/js.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");

const Span = @This();

_proto: *HtmlElement,

pub fn asElement(self: *Span) *Element {
    return self._proto._proto;
}
pub fn asNode(self: *Span) *Node {
    return self.asElement().asNode();
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Span);

    pub const Meta = struct {
        pub const name = "HTMLSpanElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };
};
