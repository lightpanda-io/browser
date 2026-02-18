const js = @import("../../../js/js.zig");
const Page = @import("../../../Page.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");
const TreeWalker = @import("../../TreeWalker.zig");

const Label = @This();

_proto: *HtmlElement,

pub fn asElement(self: *Label) *Element {
    return self._proto._proto;
}
pub fn asNode(self: *Label) *Node {
    return self.asElement().asNode();
}

pub fn getHtmlFor(self: *Label) []const u8 {
    return self.asElement().getAttributeSafe(comptime .wrap("for")) orelse "";
}

pub fn setHtmlFor(self: *Label, value: []const u8, page: *Page) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("for"), .wrap(value), page);
}

pub fn getControl(self: *Label, page: *Page) ?*Element {
    if (self.asElement().getAttributeSafe(comptime .wrap("for"))) |id| {
        const el = page.document.getElementById(id, page) orelse return null;
        if (!isLabelable(el)) {
            return null;
        }
        return el;
    }

    var tw = TreeWalker.FullExcludeSelf.Elements.init(self.asNode(), .{});
    while (tw.next()) |el| {
        if (isLabelable(el)) {
            return el;
        }
    }
    return null;
}

fn isLabelable(el: *Element) bool {
    const html = el.is(HtmlElement) orelse return false;
    return switch (html._type) {
        .button, .meter, .output, .progress, .select, .textarea => true,
        .input => |input| input._input_type != .hidden,
        else => false,
    };
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Label);

    pub const Meta = struct {
        pub const name = "HTMLLabelElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const htmlFor = bridge.accessor(Label.getHtmlFor, Label.setHtmlFor, .{});
    pub const control = bridge.accessor(Label.getControl, null, .{});
};

const testing = @import("../../../../testing.zig");
test "WebApi: HTML.Label" {
    try testing.htmlRunner("element/html/label.html", .{});
}
