const js = @import("../../../js/js.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");

const FrameSet = @This();

_proto: *HtmlElement,

pub fn asElement(self: *FrameSet) *Element {
    return self._proto._proto;
}
pub fn asNode(self: *FrameSet) *Node {
    return self.asElement().asNode();
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(FrameSet);

    pub const Meta = struct {
        pub const name = "HTMLFrameSetElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };
};

const testing = @import("../../../../testing.zig");
test "WebApi: HTML.Frameset" {
    try testing.htmlRunner("element/html/frameset.html", .{});
}
