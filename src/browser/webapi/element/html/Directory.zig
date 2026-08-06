const lp = @import("lightpanda");
const Factory = @import("../../../Factory.zig");
const js = @import("../../../js/js.zig");
const Frame = @import("../../../Frame.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");

const Directory = @This();

pub const Proto = HtmlElement;

_pad: bool = false,
_proto_canary: if (lp.IS_DEBUG) *HtmlElement else void = undefined,

pub fn asElement(self: *Directory) *Element {
    return Factory.protoOf(self).asElement();
}
pub fn asNode(self: *Directory) *Node {
    return self.asElement().asNode();
}

pub fn getCompact(self: *Directory) bool {
    return self.asElement().getAttributeSafe(comptime .wrap("compact")) != null;
}

pub fn setCompact(self: *Directory, compact: bool, frame: *Frame) !void {
    if (compact) {
        try self.asElement().setAttributeSafe(comptime .wrap("compact"), .wrap(""), frame);
    } else {
        try self.asElement().removeAttribute(comptime .wrap("compact"), frame);
    }
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Directory);

    pub const Meta = struct {
        pub const name = "HTMLDirectoryElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const compact = bridge.accessor(Directory.getCompact, Directory.setCompact, .{ .ce_reactions = true });
};
