const js = @import("../../../js/js.zig");
const Frame = @import("../../../Frame.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");
const collections = @import("../../collections.zig");

const DataList = @This();

pub const Proto = HtmlElement;

_proto: *HtmlElement,

pub fn asElement(self: *DataList) *Element {
    return self._proto.asElement();
}
pub fn asNode(self: *DataList) *Node {
    return self.asElement().asNode();
}

/// The live collection of descendant option elements.
pub fn getOptions(self: *DataList, frame: *Frame) collections.NodeLive(.tag) {
    return collections.NodeLive(.tag).init(self.asNode(), .option, frame);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(DataList);

    pub const Meta = struct {
        pub const name = "HTMLDataListElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const options = bridge.accessor(DataList.getOptions, null, .{ .cache = .{ .private = "datalist_options" } });
};

const testing = @import("../../../../testing.zig");
test "WebApi: HTML.DataList" {
    try testing.htmlRunner("element/html/datalist.html", .{});
}
