const js = @import("../../../js/js.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");

const Html = @This();
_proto: *HtmlElement,

pub fn asElement(self: *Html) *Element {
    return self._proto._proto;
}
pub fn asNode(self: *Html) *Node {
    return self.asElement().asNode();
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Html);

    pub const Meta = struct {
        pub const name = "HTMLHtmlElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };
};
