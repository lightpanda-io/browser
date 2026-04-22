const js = @import("../../../js/js.zig");
const Frame = @import("../../../Frame.zig");

const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");

const Details = @This();

_proto: *HtmlElement,

pub fn asElement(self: *Details) *Element {
    return self._proto._proto;
}
pub fn asConstElement(self: *const Details) *const Element {
    return self._proto._proto;
}
pub fn asNode(self: *Details) *Node {
    return self.asElement().asNode();
}

pub fn getOpen(self: *const Details) bool {
    return self.asConstElement().getAttributeSafe(comptime .wrap("open")) != null;
}

pub fn setOpen(self: *Details, open: bool, frame: *Frame) !void {
    if (open) {
        try self.asElement().setAttributeSafe(comptime .wrap("open"), .wrap(""), frame);
    } else {
        try self.asElement().removeAttribute(comptime .wrap("open"), frame);
    }
}

pub fn getName(self: *const Details) []const u8 {
    return self.asConstElement().getAttributeSafe(comptime .wrap("name")) orelse "";
}

pub fn setName(self: *Details, value: []const u8, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("name"), .wrap(value), frame);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Details);

    pub const Meta = struct {
        pub const name = "HTMLDetailsElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const open = bridge.accessor(Details.getOpen, Details.setOpen, .{});
    pub const name = bridge.accessor(Details.getName, Details.setName, .{});
};

const testing = @import("../../../../testing.zig");
test "WebApi: HTML.Details" {
    try testing.htmlRunner("element/html/details.html", .{});
}
