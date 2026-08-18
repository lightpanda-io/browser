const lp = @import("lightpanda");
const js = @import("../../../js/js.zig");
const Factory = @import("../../../Factory.zig");
const Frame = @import("../../../Frame.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");

const Source = @This();

pub const Proto = HtmlElement;

_pad: bool = false,
_proto_canary: if (lp.IS_DEBUG) *HtmlElement else void = undefined,

pub fn asElement(self: *Source) *Element {
    return Factory.protoOf(self).asElement();
}
pub fn asConstElement(self: *const Source) *const Element {
    return Factory.protoOf(self).asElement();
}
pub fn asNode(self: *Source) *Node {
    return self.asElement().asNode();
}

pub fn getSrc(self: *const Source, frame: *Frame) ![]const u8 {
    const element = self.asConstElement();
    const src = element.getAttributeSafe(comptime .wrap("src")) orelse return "";
    if (src.len == 0) {
        return "";
    }
    return element.asConstNode().resolveURLReflect(src, frame, .{});
}

pub fn setSrc(self: *Source, value: []const u8, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("src"), .wrap(value), frame);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Source);

    pub const Meta = struct {
        pub const name = "HTMLSourceElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    const reflect = Element.Reflect(Source);

    pub const height = reflect.unsignedLong("height", .{});
    pub const media = reflect.string("media");
    pub const sizes = reflect.string("sizes");
    pub const src = bridge.accessor(Source.getSrc, Source.setSrc, .{ .ce_reactions = true });
    pub const srcset = reflect.string("srcset");
    pub const @"type" = reflect.string("type");
    pub const width = reflect.unsignedLong("width", .{});
};

const testing = @import("../../../../testing.zig");
test "WebApi: HTML.Source" {
    try testing.htmlRunner("element/html/source.html", .{});
}
