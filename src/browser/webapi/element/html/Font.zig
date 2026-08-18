const lp = @import("lightpanda");
const Factory = @import("../../../Factory.zig");
const js = @import("../../../js/js.zig");
const Frame = @import("../../../Frame.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");

const Font = @This();

pub const Proto = HtmlElement;

_pad: bool = false,
_proto_canary: if (lp.IS_DEBUG) *HtmlElement else void = undefined,

pub fn asElement(self: *Font) *Element {
    return Factory.protoOf(self).asElement();
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

pub const JsApi = struct {
    pub const bridge = js.Bridge(Font);

    pub const Meta = struct {
        pub const name = "HTMLFontElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    const reflect = Element.Reflect(Font);

    pub const color = bridge.accessor(Font.getColor, Font.setColor, .{ .ce_reactions = true });
    pub const face = reflect.string("face");
    pub const size = reflect.string("size");
};

const testing = @import("../../../../testing.zig");
test "WebApi: HTML.Font" {
    try testing.htmlRunner("element/html/font.html", .{});
}
