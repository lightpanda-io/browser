const lp = @import("lightpanda");
const Factory = @import("../../../Factory.zig");
const js = @import("../../../js/js.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");

const OptGroup = @This();

pub const Proto = HtmlElement;

_pad: bool = false,
_proto_canary: if (lp.IS_DEBUG) *HtmlElement else void = undefined,

pub fn asElement(self: *OptGroup) *Element {
    return Factory.protoOf(self).asElement();
}
pub fn asNode(self: *OptGroup) *Node {
    return self.asElement().asNode();
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(OptGroup);

    pub const Meta = struct {
        pub const name = "HTMLOptGroupElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    const reflect = Element.Reflect(OptGroup);

    pub const disabled = reflect.boolean("disabled");
    pub const label = reflect.string("label");
};

const testing = @import("../../../../testing.zig");
test "WebApi: HTML.OptGroup" {
    try testing.htmlRunner("element/html/optgroup.html", .{});
}
