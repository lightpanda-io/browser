const String = @import("../../../../string.zig").String;

const js = @import("../../../js/js.zig");

const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");

const Unknown = @This();
_proto: *HtmlElement,
_tag_name: String,

pub fn asElement(self: *Unknown) *Element {
    return self._proto._proto;
}
pub fn asNode(self: *Unknown) *Node {
    return self.asElement().asNode();
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Unknown);

    pub const Meta = struct {
        pub const name = "HTMLUnknownElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_index: u16 = 0;
    };
};
