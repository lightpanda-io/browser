const lp = @import("lightpanda");

const js = @import("../../../js/js.zig");
const Factory = @import("../../../Factory.zig");
const Node = @import("../../Node.zig");
const Frame = @import("../../../Frame.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");
const collections = @import("../../collections.zig");

const String = lp.String;

const TableSection = @This();

pub const Proto = HtmlElement;

_tag_name: String,
_tag: Element.Tag,
_proto_canary: if (lp.IS_DEBUG) *HtmlElement else void = undefined,

pub fn asElement(self: *TableSection) *Element {
    return Factory.protoOf(self).asElement();
}
pub fn asNode(self: *TableSection) *Node {
    return self.asElement().asNode();
}

pub fn getRows(self: *TableSection, frame: *Frame) collections.NodeLive(.child_tag) {
    return collections.NodeLive(.child_tag).init(self.asNode(), .tr, frame);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(TableSection);

    pub const Meta = struct {
        pub const name = "HTMLTableSectionElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    const reflect = Element.Reflect(TableSection);
    pub const vAlign = reflect.string("valign");
    pub const chOff = reflect.string("charoff");
    pub const ch = reflect.string("char");
    pub const @"align" = reflect.string("align");

    pub const rows = bridge.accessor(TableSection.getRows, null, .{});
};
