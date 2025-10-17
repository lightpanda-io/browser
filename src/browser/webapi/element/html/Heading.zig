const String = @import("../../../../string.zig").String;

const js = @import("../../../js/js.zig");

const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");

const Heading = @This();
_proto: *HtmlElement,
_tag_name: String,
_tag: Element.Tag,

pub fn asElement(self: *Heading) *Element {
    return self._proto._proto;
}
pub fn asNode(self: *Heading) *Node {
    return self.asElement().asNode();
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Heading);

    pub const Meta = struct {
        pub const name = "HTMLHeadingElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_index: u16 = 0;
    };
};
