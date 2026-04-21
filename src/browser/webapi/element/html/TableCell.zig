const std = @import("std");
const lp = @import("lightpanda");

const js = @import("../../../js/js.zig");
const Frame = @import("../../../Frame.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");

const String = lp.String;

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
    const v = std.fmt.parseUnsigned(u32, attr, 10) catch return 1;
    if (v == 0) return 1;
    return @min(v, 1000);
}

pub fn setColSpan(self: *TableCell, value: u32, frame: *Frame) !void {
    const str = try std.fmt.allocPrint(frame.call_arena, "{d}", .{value});
    try self.asElement().setAttributeSafe(comptime .wrap("colspan"), .wrap(str), frame);
}

pub fn getRowSpan(self: *TableCell) u32 {
    const attr = self.asElement().getAttributeSafe(comptime .wrap("rowspan")) orelse return 1;
    const v = std.fmt.parseUnsigned(u32, attr, 10) catch return 1;
    return @min(v, 65534);
}

pub fn setRowSpan(self: *TableCell, value: u32, frame: *Frame) !void {
    const str = try std.fmt.allocPrint(frame.call_arena, "{d}", .{value});
    try self.asElement().setAttributeSafe(comptime .wrap("rowspan"), .wrap(str), frame);
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
