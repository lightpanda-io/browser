const std = @import("std");
const js = @import("../../../js/js.zig");
const Page = @import("../../../Page.zig");
const Node = @import("../../Node.zig");
const Document = @import("../../Document.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");
const TableCell = @import("TableCell.zig");

const TableRow = @This();

_proto: *HtmlElement,

pub fn asElement(self: *TableRow) *Element {
    return self._proto._proto;
}
pub fn asNode(self: *TableRow) *Node {
    return self.asElement().asNode();
}

fn ownerDocument(self: *TableRow, page: *Page) *Document {
    return self.asNode().ownerDocument(page) orelse page.document;
}

fn normalizeInsertIndex(index_: ?i32, len: usize) !usize {
    const index = index_ orelse -1;
    if (index < -1) {
        return error.IndexSizeError;
    }
    if (index == -1) {
        return len;
    }
    const normalized: usize = @intCast(index);
    if (normalized > len) {
        return error.IndexSizeError;
    }
    return normalized;
}

fn cellCount(self: *TableRow) usize {
    var count: usize = 0;
    var it = self.asNode().childrenIterator();
    while (it.next()) |child| {
        if (child.is(TableCell) != null) {
            count += 1;
        }
    }
    return count;
}

fn cellBeforeIndex(self: *TableRow, index: usize) ?*Node {
    var current: usize = 0;
    var it = self.asNode().childrenIterator();
    while (it.next()) |child| {
        if (child.is(TableCell) == null) {
            continue;
        }
        if (current == index) {
            return child;
        }
        current += 1;
    }
    return null;
}

pub fn insertCell(self: *TableRow, index_: ?i32, page: *Page) !*TableCell {
    const insert_index = try normalizeInsertIndex(index_, self.cellCount());
    const cell_element = try ownerDocument(self, page).createElement("td", null, page);
    const cell = cell_element.as(TableCell);
    const before = self.cellBeforeIndex(insert_index);
    _ = try self.asNode().insertBefore(cell.asNode(), before, page);
    return cell;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(TableRow);

    pub const Meta = struct {
        pub const name = "HTMLTableRowElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const insertCell = bridge.function(TableRow.insertCell, .{ .dom_exception = true });
};

const testing = @import("../../../../testing.zig");
test "WebApi: HTML.TableRow" {
    try testing.htmlRunner("element/html/tablerow.html", .{});
}
