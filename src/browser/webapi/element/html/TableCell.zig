const std = @import("std");
const String = @import("../../../../string.zig").String;
const js = @import("../../../js/js.zig");
const Page = @import("../../../Page.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");

const TableCell = @This();

_tag_name: String,
_tag: Element.Tag,
_proto: *HtmlElement,

pub fn asElement(self: *TableCell) *Element {
    return self._proto._proto;
}
pub fn asNode(self: *TableCell) *Node {
    return self.asElement().asNode();
}

pub fn getColSpan(self: *TableCell) u32 {
    const attr = self.asElement().getAttributeSafe(comptime .wrap("colspan")) orelse return 1;
    return std.fmt.parseUnsigned(u32, attr, 10) catch 1;
}

pub fn setColSpan(self: *TableCell, value: u32, page: *Page) !void {
    const str = try std.fmt.allocPrint(page.call_arena, "{d}", .{value});
    try self.asElement().setAttributeSafe(comptime .wrap("colspan"), .wrap(str), page);
}

pub fn getRowSpan(self: *TableCell) u32 {
    const attr = self.asElement().getAttributeSafe(comptime .wrap("rowspan")) orelse return 1;
    return std.fmt.parseUnsigned(u32, attr, 10) catch 1;
}

pub fn setRowSpan(self: *TableCell, value: u32, page: *Page) !void {
    const str = try std.fmt.allocPrint(page.call_arena, "{d}", .{value});
    try self.asElement().setAttributeSafe(comptime .wrap("rowspan"), .wrap(str), page);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(TableCell);

    pub const Meta = struct {
        pub const name = "HTMLTableCellElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const colSpan = bridge.accessor(TableCell.getColSpan, TableCell.setColSpan, .{});
    pub const rowSpan = bridge.accessor(TableCell.getRowSpan, TableCell.setRowSpan, .{});
};

const testing = @import("../../../../testing.zig");
test "WebApi: HTML.TableCell" {
    try testing.htmlRunner("element/html/tablecell.html", .{});
}
