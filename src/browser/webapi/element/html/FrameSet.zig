const js = @import("../../../js/js.zig");
const Frame = @import("../../../Frame.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");

const FrameSet = @This();

_proto: *HtmlElement,

pub fn asElement(self: *FrameSet) *Element {
    return self._proto._proto;
}
pub fn asNode(self: *FrameSet) *Node {
    return self.asElement().asNode();
}

pub fn getCols(self: *FrameSet) []const u8 {
    return self.asElement().getAttributeSafe(comptime .wrap("cols")) orelse "";
}

pub fn setCols(self: *FrameSet, value: []const u8, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("cols"), .wrap(value), frame);
}

pub fn getRows(self: *FrameSet) []const u8 {
    return self.asElement().getAttributeSafe(comptime .wrap("rows")) orelse "";
}

pub fn setRows(self: *FrameSet, value: []const u8, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("rows"), .wrap(value), frame);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(FrameSet);

    pub const Meta = struct {
        pub const name = "HTMLFrameSetElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const cols = bridge.accessor(FrameSet.getCols, FrameSet.setCols, .{ .ce_reactions = true });
    pub const rows = bridge.accessor(FrameSet.getRows, FrameSet.setRows, .{ .ce_reactions = true });
};

const testing = @import("../../../../testing.zig");
test "WebApi: HTML.Frameset" {
    try testing.htmlRunner("element/html/frameset.html", .{});
}
