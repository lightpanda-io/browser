const js = @import("../../../js/js.zig");
const Page = @import("../../../Page.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");

const Time = @This();

_proto: *HtmlElement,

pub fn asElement(self: *Time) *Element {
    return self._proto._proto;
}
pub fn asNode(self: *Time) *Node {
    return self.asElement().asNode();
}

pub fn getDateTime(self: *Time) []const u8 {
    return self.asElement().getAttributeSafe(comptime .wrap("datetime")) orelse "";
}

pub fn setDateTime(self: *Time, value: []const u8, page: *Page) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("datetime"), .wrap(value), page);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Time);

    pub const Meta = struct {
        pub const name = "HTMLTimeElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const dateTime = bridge.accessor(Time.getDateTime, Time.setDateTime, .{});
};

const testing = @import("../../../../testing.zig");
test "WebApi: HTML.Time" {
    try testing.htmlRunner("element/html/time.html", .{});
}
