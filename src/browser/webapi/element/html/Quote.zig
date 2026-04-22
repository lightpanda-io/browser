const lp = @import("lightpanda");

const js = @import("../../../js/js.zig");
const Frame = @import("../../../Frame.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");

const String = lp.String;

const Quote = @This();

_tag_name: String,
_tag: Element.Tag,
_proto: *HtmlElement,

pub fn asElement(self: *Quote) *Element {
    return self._proto._proto;
}
pub fn asNode(self: *Quote) *Node {
    return self.asElement().asNode();
}

pub fn getCite(self: *Quote, frame: *Frame) ![]const u8 {
    const attr = self.asElement().getAttributeSafe(comptime .wrap("cite")) orelse return "";
    if (attr.len == 0) return "";
    const URL = @import("../../URL.zig");
    return URL.resolve(frame.call_arena, frame.base(), attr, .{});
}

pub fn setCite(self: *Quote, value: []const u8, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("cite"), .wrap(value), frame);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Quote);

    pub const Meta = struct {
        pub const name = "HTMLQuoteElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const cite = bridge.accessor(Quote.getCite, Quote.setCite, .{});
};

const testing = @import("../../../../testing.zig");
test "WebApi: HTML.Quote" {
    try testing.htmlRunner("element/html/quote.html", .{});
}
