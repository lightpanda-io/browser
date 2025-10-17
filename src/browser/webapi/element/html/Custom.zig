const String = @import("../../../../string.zig").String;

const js = @import("../../../js/js.zig");

const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");

const Custom = @This();
_proto: *HtmlElement,
_tag_name: String,

pub fn asElement(self: *Custom) *Element {
    return self._proto._proto;
}
pub fn asNode(self: *Custom) *Node {
    return self.asElement().asNode();
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Custom);

    pub const Meta = struct {
        pub const name = "TODO-CUSTOM-NAME";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_index: u16 = 0;
    };
};
