const js = @import("../../../js/js.zig");
const Frame = @import("../../../Frame.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");

const Progress = @This();

_proto: *HtmlElement,

pub fn asElement(self: *Progress) *Element {
    return self._proto._proto;
}
pub fn asNode(self: *Progress) *Node {
    return self.asElement().asNode();
}

pub fn getLabels(self: *Progress, frame: *Frame) !js.Array {
    return @import("Label.zig").getControlLabels(self.asElement(), frame);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Progress);

    pub const Meta = struct {
        pub const name = "HTMLProgressElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const labels = bridge.accessor(Progress.getLabels, null, .{});
};
