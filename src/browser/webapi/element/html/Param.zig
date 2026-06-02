const js = @import("../../../js/js.zig");
const Frame = @import("../../../Frame.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");

const Param = @This();

_proto: *HtmlElement,

pub fn asElement(self: *Param) *Element {
    return self._proto._proto;
}
pub fn asNode(self: *Param) *Node {
    return self.asElement().asNode();
}

pub fn getName(self: *Param) []const u8 {
    return self.asElement().getAttributeSafe(comptime .wrap("name")) orelse "";
}

pub fn setName(self: *Param, value: []const u8, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("name"), .wrap(value), frame);
}

pub fn getValue(self: *Param) []const u8 {
    return self.asElement().getAttributeSafe(comptime .wrap("value")) orelse "";
}

pub fn setValue(self: *Param, value: []const u8, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("value"), .wrap(value), frame);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Param);

    pub const Meta = struct {
        pub const name = "HTMLParamElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const name = bridge.accessor(Param.getName, Param.setName, .{ .ce_reactions = true });
    pub const value = bridge.accessor(Param.getValue, Param.setValue, .{ .ce_reactions = true });
};

const testing = @import("../../../../testing.zig");
test "WebApi: HTML.Param" {
    try testing.htmlRunner("element/html/param.html", .{});
}
