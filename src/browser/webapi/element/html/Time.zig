const lp = @import("lightpanda");
const Factory = @import("../../../Factory.zig");
const js = @import("../../../js/js.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");

const Time = @This();

pub const Proto = HtmlElement;

_pad: bool = false,
_proto_canary: if (lp.IS_DEBUG) *HtmlElement else void = undefined,

pub fn asElement(self: *Time) *Element {
    return Factory.protoOf(self).asElement();
}
pub fn asNode(self: *Time) *Node {
    return self.asElement().asNode();
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Time);

    pub const Meta = struct {
        pub const name = "HTMLTimeElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    const reflect = Element.Reflect(Time);

    pub const dateTime = reflect.string("datetime");
};

const testing = @import("../../../../testing.zig");
test "WebApi: HTML.Time" {
    try testing.htmlRunner("element/html/time.html", .{});
}
