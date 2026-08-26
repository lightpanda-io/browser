const lp = @import("lightpanda");
const Factory = @import("../../../Factory.zig");
const js = @import("../../../js/js.zig");
const Frame = @import("../../../Frame.zig");

const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");

const Details = @This();

pub const Proto = HtmlElement;

_pad: bool = false,
_proto_canary: if (lp.IS_DEBUG) *HtmlElement else void = undefined,

pub fn asElement(self: *Details) *Element {
    return Factory.protoOf(self).asElement();
}
pub fn asConstElement(self: *const Details) *const Element {
    return Factory.protoOf(self).asElement();
}
pub fn asNode(self: *Details) *Node {
    return self.asElement().asNode();
}

pub fn setOpen(self: *Details, open: bool, frame: *Frame) !void {
    if (open) {
        try self.asElement().setAttributeSafe(comptime .wrap("open"), .wrap(""), frame);
    } else {
        try self.asElement().removeAttribute(comptime .wrap("open"), frame);
    }
}

pub fn getOpen(self: *const Details) bool {
    return self.asConstElement().getAttributeSafe(comptime .wrap("open")) != null;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Details);

    pub const Meta = struct {
        pub const name = "HTMLDetailsElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    const reflect = Element.Reflect(Details);

    pub const open = reflect.boolean("open");
    pub const name = reflect.string("name");
};

const testing = @import("../../../../testing.zig");
test "WebApi: HTML.Details" {
    try testing.htmlRunner("element/html/details.html", .{});
}

test "WebApi: HTML.Summary click toggles parent details" {
    try testing.htmlRunner("element/html/summary_click.html", .{});
}
