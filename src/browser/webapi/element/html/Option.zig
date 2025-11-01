const js = @import("../../../js/js.zig");
const Page = @import("../../../Page.zig");

const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");

const Option = @This();

_proto: *HtmlElement,
_value: ?[]const u8 = null,
_text: ?[]const u8 = null,
_selected: bool = false,
_default_selected: bool = false,
_disabled: bool = false,

pub fn asElement(self: *Option) *Element {
    return self._proto._proto;
}
pub fn asNode(self: *Option) *Node {
    return self.asElement().asNode();
}

pub fn getValue(self: *const Option) []const u8 {
    // If value attribute exists, use that; otherwise use text content
    return self._value orelse self._text orelse "";
}

pub fn setValue(self: *Option, value: []const u8, page: *Page) !void {
    const owned = try page.arena.dupe(u8, value);
    try self.asElement().setAttributeSafe("value", owned, page);
    self._value = owned;
}

pub fn getText(self: *const Option) []const u8 {
    return self._text orelse "";
}

pub fn getSelected(self: *const Option) bool {
    return self._selected;
}

pub fn setSelected(self: *Option, selected: bool, page: *Page) !void {
    _ = page;
    // TODO: When setting selected=true, may need to unselect other options
    // in the parent <select> if it doesn't have multiple attribute
    self._selected = selected;
}

pub fn getDefaultSelected(self: *const Option) bool {
    return self._default_selected;
}

pub fn getDisabled(self: *const Option) bool {
    return self._disabled;
}

pub fn setDisabled(self: *Option, disabled: bool, page: *Page) !void {
    self._disabled = disabled;
    if (disabled) {
        try self.asElement().setAttributeSafe("disabled", "", page);
    } else {
        try self.asElement().removeAttribute("disabled", page);
    }
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Option);

    pub const Meta = struct {
        pub const name = "HTMLOptionElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const value = bridge.accessor(Option.getValue, Option.setValue, .{});
    pub const text = bridge.accessor(Option.getText, null, .{});
    pub const selected = bridge.accessor(Option.getSelected, Option.setSelected, .{});
    pub const defaultSelected = bridge.accessor(Option.getDefaultSelected, null, .{});
    pub const disabled = bridge.accessor(Option.getDisabled, Option.setDisabled, .{});
};

pub const Build = struct {
    const CData = @import("../../CData.zig");

    pub fn created(node: *Node, _: *Page) !void {
        var self = node.as(Option);
        const element = self.asElement();

        // Check for value attribute
        self._value = element.getAttributeSafe("value");

        // Check for selected attribute
        self._default_selected = element.getAttributeSafe("selected") != null;
        self._selected = self._default_selected;

        // Check for disabled attribute
        self._disabled = element.getAttributeSafe("disabled") != null;
    }

    pub fn complete(node: *Node, _: *const Page) !void {
        var self = node.as(Option);

        // Get text content
        if (node.firstChild()) |child| {
            if (child.is(CData.Text)) |txt| {
                self._text = txt.getWholeText();
            }
        }
    }
};

const testing = @import("../../../../testing.zig");
test "WebApi: HTML.Option" {
    try testing.htmlRunner("element/html/option.html", .{});
}
