const js = @import("../../../js/js.zig");
const Frame = @import("../../../Frame.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");

const Font = @This();

_proto: *HtmlElement,

pub fn asElement(self: *Font) *Element {
    return self._proto._proto;
}
pub fn asNode(self: *Font) *Node {
    return self.asElement().asNode();
}

pub fn getColor(self: *Font) []const u8 {
    return self.asElement().getAttributeSafe(comptime .wrap("color")) orelse "";
}

pub fn setColor(self: *Font, value: js.Value, frame: *Frame) !void {
    // color is `[LegacyNullToEmptyString] DOMString`: a JS null becomes "",
    // not the string "null".
    const str: []const u8 = if (value.isNull()) "" else try value.toZig([]const u8);
    try self.asElement().setAttributeSafe(comptime .wrap("color"), .wrap(str), frame);
}

pub fn getFace(self: *Font) []const u8 {
    return self.asElement().getAttributeSafe(comptime .wrap("face")) orelse "";
}

pub fn setFace(self: *Font, value: []const u8, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("face"), .wrap(value), frame);
}

pub fn getSize(self: *Font) []const u8 {
    return self.asElement().getAttributeSafe(comptime .wrap("size")) orelse "";
}

pub fn setSize(self: *Font, value: []const u8, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("size"), .wrap(value), frame);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Font);

    pub const Meta = struct {
        pub const name = "HTMLFontElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const color = bridge.accessor(Font.getColor, Font.setColor, .{ .ce_reactions = true });
    pub const face = bridge.accessor(Font.getFace, Font.setFace, .{ .ce_reactions = true });
    pub const size = bridge.accessor(Font.getSize, Font.setSize, .{ .ce_reactions = true });
};

const testing = @import("../../../../testing.zig");
test "WebApi: HTML.Font" {
    try testing.htmlRunner("element/html/font.html", .{});
}
