const lp = @import("lightpanda");
const Factory = @import("../../../Factory.zig");
const js = @import("../../../js/js.zig");
const Node = @import("../../Node.zig");
const Frame = @import("../../../Frame.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");
const collections = @import("../../collections.zig");

const TableRow = @This();

pub const Proto = HtmlElement;

_pad: bool = false,
_proto_canary: if (lp.IS_DEBUG) *HtmlElement else void = undefined,

pub fn asElement(self: *TableRow) *Element {
    return Factory.protoOf(self).asElement();
}
pub fn asNode(self: *TableRow) *Node {
    return self.asElement().asNode();
}

pub fn getCells(self: *TableRow, frame: *Frame) collections.NodeLive(.cells) {
    return collections.NodeLive(.cells).init(self.asNode(), {}, frame);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(TableRow);

    pub const Meta = struct {
        pub const name = "HTMLTableRowElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    const reflect = Element.Reflect(TableRow);
    pub const vAlign = reflect.string("valign");
    pub const chOff = reflect.string("charoff");
    pub const ch = reflect.string("char");
    pub const bgColor = reflect.stringNullToEmpty("bgcolor");
    pub const @"align" = reflect.string("align");

    pub const cells = bridge.accessor(TableRow.getCells, null, .{});
};
