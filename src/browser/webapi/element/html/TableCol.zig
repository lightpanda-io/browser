const lp = @import("lightpanda");

const js = @import("../../../js/js.zig");
const Factory = @import("../../../Factory.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");

const String = lp.String;

const TableCol = @This();

pub const Proto = HtmlElement;

_tag_name: String,
_tag: Element.Tag,
_proto_canary: if (lp.IS_DEBUG) *HtmlElement else void = undefined,

pub fn asElement(self: *TableCol) *Element {
    return Factory.protoOf(self).asElement();
}
pub fn asNode(self: *TableCol) *Node {
    return self.asElement().asNode();
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(TableCol);

    pub const Meta = struct {
        pub const name = "HTMLTableColElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    const reflect = Element.Reflect(TableCol);
    pub const span = reflect.unsignedLong("span", .{ .default = 1, .clamp = .{ .min = 1, .max = 1000 } });
    pub const width = reflect.string("width");
    pub const vAlign = reflect.string("valign");
    pub const chOff = reflect.string("charoff");
    pub const ch = reflect.string("char");
    pub const @"align" = reflect.string("align");
};
