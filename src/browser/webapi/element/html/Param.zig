const lp = @import("lightpanda");
const Factory = @import("../../../Factory.zig");
const js = @import("../../../js/js.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");

const Param = @This();

pub const Proto = HtmlElement;

_pad: bool = false,
_proto_canary: if (lp.IS_DEBUG) *HtmlElement else void = undefined,

pub fn asElement(self: *Param) *Element {
    return Factory.protoOf(self).asElement();
}
pub fn asNode(self: *Param) *Node {
    return self.asElement().asNode();
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Param);

    pub const Meta = struct {
        pub const name = "HTMLParamElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    const reflect = Element.Reflect(Param);
    pub const valueType = reflect.string("valuetype");
    pub const @"type" = reflect.string("type");

    pub const name = reflect.string("name");
    pub const value = reflect.string("value");
};

const testing = @import("../../../../testing.zig");
test "WebApi: HTML.Param" {
    try testing.htmlRunner("element/html/param.html", .{});
}
