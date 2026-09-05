const lp = @import("lightpanda");
const Factory = @import("../../../Factory.zig");
const js = @import("../../../js/js.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");

const FieldSet = @This();

pub const Proto = HtmlElement;

_pad: bool = false,
_proto_canary: if (lp.IS_DEBUG) *HtmlElement else void = undefined,

pub fn asElement(self: *FieldSet) *Element {
    return Factory.protoOf(self).asElement();
}
pub fn asNode(self: *FieldSet) *Node {
    return self.asElement().asNode();
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(FieldSet);

    pub const Meta = struct {
        pub const name = "HTMLFieldSetElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    const reflect = Element.Reflect(FieldSet);

    pub const disabled = reflect.boolean("disabled");
    pub const name = reflect.string("name");
};

const testing = @import("../../../../testing.zig");
test "WebApi: HTML.FieldSet" {
    try testing.htmlRunner("element/html/fieldset.html", .{});
}
