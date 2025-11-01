const js = @import("../../../js/js.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const Svg = @import("../Svg.zig");

const Rect = @This();
_proto: *Svg,

pub fn asElement(self: *Rect) *Element {
    return self._proto._proto;
}
pub fn asNode(self: *Rect) *Node {
    return self.asElement().asNode();
}

pub fn className(_: *const Rect) []const u8 {
    return "SVGRectElement";
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Rect);

    pub const Meta = struct {
        pub const name = "SVGRectElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };
};
