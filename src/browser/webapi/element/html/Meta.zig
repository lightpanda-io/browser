const js = @import("../../../js/js.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");

const Meta = @This();
// Because we have a JsApi.Meta, "Meta" can be ambiguous in some scopes.
// Create a different alias we can use when in such ambiguous cases.
const MetaElement = Meta;

_proto: *HtmlElement,

pub fn asElement(self: *Meta) *Element {
    return self._proto._proto;
}
pub fn asNode(self: *Meta) *Node {
    return self.asElement().asNode();
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(MetaElement);

    pub const Meta = struct {
        pub const name = "HTMLMetaElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_index: u16 = 0;
    };
};
