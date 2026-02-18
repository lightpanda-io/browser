const js = @import("../../../js/js.zig");
const Page = @import("../../../Page.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");

const OptGroup = @This();

_proto: *HtmlElement,

pub fn asElement(self: *OptGroup) *Element {
    return self._proto._proto;
}
pub fn asNode(self: *OptGroup) *Node {
    return self.asElement().asNode();
}

pub fn getDisabled(self: *OptGroup) bool {
    return self.asElement().getAttributeSafe(comptime .wrap("disabled")) != null;
}

pub fn setDisabled(self: *OptGroup, value: bool, page: *Page) !void {
    if (value) {
        try self.asElement().setAttributeSafe(comptime .wrap("disabled"), .wrap(""), page);
    } else {
        try self.asElement().removeAttribute(comptime .wrap("disabled"), page);
    }
}

pub fn getLabel(self: *OptGroup) []const u8 {
    return self.asElement().getAttributeSafe(comptime .wrap("label")) orelse "";
}

pub fn setLabel(self: *OptGroup, value: []const u8, page: *Page) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("label"), .wrap(value), page);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(OptGroup);

    pub const Meta = struct {
        pub const name = "HTMLOptGroupElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const disabled = bridge.accessor(OptGroup.getDisabled, OptGroup.setDisabled, .{});
    pub const label = bridge.accessor(OptGroup.getLabel, OptGroup.setLabel, .{});
};

const testing = @import("../../../../testing.zig");
test "WebApi: HTML.OptGroup" {
    try testing.htmlRunner("element/html/optgroup.html", .{});
}
