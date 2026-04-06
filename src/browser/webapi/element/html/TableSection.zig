const String = @import("../../../../string.zig").String;
const std = @import("std");
const js = @import("../../../js/js.zig");
const Page = @import("../../../Page.zig");
const Node = @import("../../Node.zig");
const Document = @import("../../Document.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");
const TableRow = @import("TableRow.zig");

const TableSection = @This();

_tag_name: String,
_tag: Element.Tag,
_proto: *HtmlElement,

pub fn asElement(self: *TableSection) *Element {
    return self._proto._proto;
}
pub fn asNode(self: *TableSection) *Node {
    return self.asElement().asNode();
}

fn ownerDocument(self: *TableSection, page: *Page) *Document {
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

fn rowCount(self: *TableSection) usize {
    var count: usize = 0;
    var it = self.asNode().childrenIterator();
    while (it.next()) |child| {
        if (child.is(TableRow) != null) {
            count += 1;
        }
    }
    return count;
}

fn rowBeforeIndex(self: *TableSection, index: usize) ?*Node {
    var current: usize = 0;
    var it = self.asNode().childrenIterator();
    while (it.next()) |child| {
        if (child.is(TableRow) == null) {
            continue;
        }
        if (current == index) {
            return child;
        }
        current += 1;
    }
    return null;
}

pub fn insertRow(self: *TableSection, index_: ?i32, page: *Page) !*TableRow {
    const insert_index = try normalizeInsertIndex(index_, self.rowCount());
    const row_element = try ownerDocument(self, page).createElement("tr", null, page);
    const row = row_element.as(TableRow);
    const before = self.rowBeforeIndex(insert_index);
    _ = try self.asNode().insertBefore(row.asNode(), before, page);
    return row;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(TableSection);

    pub const Meta = struct {
        pub const name = "HTMLTableSectionElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const insertRow = bridge.function(TableSection.insertRow, .{ .dom_exception = true });
};

const testing = @import("../../../../testing.zig");
test "WebApi: HTML.TableSection" {
    try testing.htmlRunner("element/html/tablesection.html", .{});
}
