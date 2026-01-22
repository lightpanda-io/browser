const js = @import("../../../js/js.zig");
const Page = @import("../../../Page.zig");

const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");

const Dialog = @This();

_proto: *HtmlElement,

pub fn asElement(self: *Dialog) *Element {
    return self._proto._proto;
}
pub fn asConstElement(self: *const Dialog) *const Element {
    return self._proto._proto;
}
pub fn asNode(self: *Dialog) *Node {
    return self.asElement().asNode();
}

pub fn getOpen(self: *const Dialog) bool {
    return self.asConstElement().getAttributeSafe(comptime .literal("open")) != null;
}

pub fn setOpen(self: *Dialog, open: bool, page: *Page) !void {
    if (open) {
        try self.asElement().setAttributeSafe("open", "", page);
    } else {
        try self.asElement().removeAttribute("open", page);
    }
}

pub fn getReturnValue(self: *const Dialog) []const u8 {
    return self.asConstElement().getAttributeSafe(comptime .literal("returnvalue")) orelse "";
}

pub fn setReturnValue(self: *Dialog, value: []const u8, page: *Page) !void {
    try self.asElement().setAttributeSafe("returnvalue", value, page);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Dialog);

    pub const Meta = struct {
        pub const name = "HTMLDialogElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const open = bridge.accessor(Dialog.getOpen, Dialog.setOpen, .{});
    pub const returnValue = bridge.accessor(Dialog.getReturnValue, Dialog.setReturnValue, .{});
};

const testing = @import("../../../../testing.zig");
test "WebApi: HTML.Dialog" {
    try testing.htmlRunner("element/html/dialog.html", .{});
}
