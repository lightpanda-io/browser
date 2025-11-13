const log = @import("../../../../log.zig");

const js = @import("../../../js/js.zig");
const Page = @import("../../../Page.zig");

const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");

const Body = @This();

_proto: *HtmlElement,

pub fn asElement(self: *Body) *Element {
    return self._proto._proto;
}
pub fn asNode(self: *Body) *Node {
    return self.asElement().asNode();
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Body);

    pub const Meta = struct {
        pub const name = "HTMLBodyElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };
};

pub const Build = struct {
    pub fn complete(node: *Node, page: *Page) !void {
        const el = node.as(Element);
        const on_load = el.getAttributeSafe("onload") orelse return;
        page.window._on_load = page.js.stringToFunction(on_load) catch |err| blk: {
            log.err(.js, "body.onload", .{ .err = err, .str = on_load });
            break :blk null;
        };
    }
};
