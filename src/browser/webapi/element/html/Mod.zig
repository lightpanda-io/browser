const String = @import("../../../../string.zig").String;
const js = @import("../../../js/js.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");

const Mod = @This();

_tag_name: String,
_tag: Element.Tag,
_proto: *HtmlElement,

pub fn asElement(self: *Mod) *Element {
    return self._proto._proto;
}
pub fn asNode(self: *Mod) *Node {
    return self.asElement().asNode();
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Mod);

    pub const Meta = struct {
        pub const name = "HTMLModElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };
};
