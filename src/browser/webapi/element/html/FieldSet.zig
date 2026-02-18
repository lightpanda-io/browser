const js = @import("../../../js/js.zig");
const Page = @import("../../../Page.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");

const FieldSet = @This();

_proto: *HtmlElement,

pub fn asElement(self: *FieldSet) *Element {
    return self._proto._proto;
}
pub fn asNode(self: *FieldSet) *Node {
    return self.asElement().asNode();
}

pub fn getDisabled(self: *FieldSet) bool {
    return self.asElement().getAttributeSafe(comptime .wrap("disabled")) != null;
}

pub fn setDisabled(self: *FieldSet, value: bool, page: *Page) !void {
    if (value) {
        try self.asElement().setAttributeSafe(comptime .wrap("disabled"), .wrap(""), page);
    } else {
        try self.asElement().removeAttribute(comptime .wrap("disabled"), page);
    }
}

pub fn getName(self: *FieldSet) []const u8 {
    return self.asElement().getAttributeSafe(comptime .wrap("name")) orelse "";
}

pub fn setName(self: *FieldSet, value: []const u8, page: *Page) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("name"), .wrap(value), page);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(FieldSet);

    pub const Meta = struct {
        pub const name = "HTMLFieldSetElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const disabled = bridge.accessor(FieldSet.getDisabled, FieldSet.setDisabled, .{});
    pub const name = bridge.accessor(FieldSet.getName, FieldSet.setName, .{});
};

const testing = @import("../../../../testing.zig");
test "WebApi: HTML.FieldSet" {
    try testing.htmlRunner("element/html/fieldset.html", .{});
}
