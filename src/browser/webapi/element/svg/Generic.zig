const js = @import("../../../js/js.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const Svg = @import("../Svg.zig");

const Generic = @This();
_proto: *Svg,
_tag: Element.Tag,

pub fn asElement(self: *Generic) *Element {
    return self._proto._proto;
}
pub fn asNode(self: *Generic) *Node {
    return self.asElement().asNode();
}

pub fn className(_: *const Generic) []const u8 {
    return "SVGGenericElement";
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Generic);

    pub const Meta = struct {
        pub const name = "SVGGenericElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_index: u16 = 0;
    };
};
