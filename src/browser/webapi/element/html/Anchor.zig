const js = @import("../../../js/js.zig");
const Page = @import("../../../Page.zig");

const URL = @import("../../URL.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");

const Anchor = @This();
_proto: *HtmlElement,

pub fn asElement(self: *Anchor) *Element {
    return self._proto._proto;
}
pub fn asNode(self: *Anchor) *Node {
    return self.asElement().asNode();
}

pub fn getHref(self: *Anchor, page: *Page) ![]const u8 {
    const el = self.asElement();
    const href = el.getAttributeSafe("href");
    return URL.resolve(page.call_arena, page.url, href orelse "", .{});
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Anchor);

    pub const Meta = struct {
        pub const name = "HTMLAnchorElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const href = bridge.accessor(Anchor.getHref, null, .{});
};

const testing = @import("../../../../testing.zig");
test "WebApi: HTML.Anchor" {
    try testing.htmlRunner("element/html/anchor.html", .{});
}
