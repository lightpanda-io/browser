const std = @import("std");
const js = @import("../../../js/js.zig");
const Page = @import("../../../Page.zig");
const Node = @import("../../Node.zig");
const Document = @import("../../Document.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");
const TableRow = @import("TableRow.zig");
const TableSection = @import("TableSection.zig");

const Table = @This();

_proto: *HtmlElement,

pub fn asElement(self: *Table) *Element {
    return self._proto._proto;
}
pub fn asNode(self: *Table) *Node {
    return self.asElement().asNode();
}

const RowPosition = struct {
    parent: *Node,
    row: *TableRow,
};

fn ownerDocument(self: *Table, page: *Page) *Document {
    return self.asNode().ownerDocument(page) orelse page.document;
}

fn collectRowPositions(
    self: *Table,
    allocator: std.mem.Allocator,
) !std.ArrayList(RowPosition) {
    var positions: std.ArrayList(RowPosition) = .empty;
    errdefer positions.deinit(allocator);

    var child_it = self.asNode().childrenIterator();
    while (child_it.next()) |child| {
        if (child.is(TableRow)) |row| {
            try positions.append(allocator, .{
                .parent = self.asNode(),
                .row = row,
            });
            continue;
        }
        if (child.is(TableSection)) |section| {
            var row_it = section.asNode().childrenIterator();
            while (row_it.next()) |row_child| {
                if (row_child.is(TableRow)) |row| {
                    try positions.append(allocator, .{
                        .parent = section.asNode(),
                        .row = row,
                    });
                }
            }
        }
    }

    return positions;
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

fn ensureBodyForInsertion(self: *Table, page: *Page) !*Node {
    var child_it = self.asNode().childrenIterator();
    var last_body: ?*TableSection = null;
    while (child_it.next()) |child| {
        if (child.is(TableSection)) |section| {
            if (section.asElement().getTag() == .tbody) {
                last_body = section;
            }
        }
    }
    if (last_body) |body| {
        return body.asNode();
    }

    const tbody_element = try ownerDocument(self, page).createElement("tbody", null, page);
    _ = try self.asNode().appendChild(tbody_element.asNode(), page);
    return tbody_element.asNode();
}

pub fn insertRow(self: *Table, index_: ?i32, page: *Page) !*TableRow {
    var positions = try self.collectRowPositions(page.call_arena);
    defer positions.deinit(page.call_arena);

    const insert_index = try normalizeInsertIndex(index_, positions.items.len);
    const row_element = try ownerDocument(self, page).createElement("tr", null, page);
    const row = row_element.as(TableRow);

    if (positions.items.len == 0) {
        const container = try self.ensureBodyForInsertion(page);
        _ = try container.appendChild(row.asNode(), page);
        return row;
    }

    if (insert_index == positions.items.len) {
        const target = positions.items[positions.items.len - 1];
        _ = try target.parent.appendChild(row.asNode(), page);
        return row;
    }

    const target = positions.items[insert_index];
    _ = try target.parent.insertBefore(row.asNode(), target.row.asNode(), page);
    return row;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Table);

    pub const Meta = struct {
        pub const name = "HTMLTableElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const insertRow = bridge.function(Table.insertRow, .{ .dom_exception = true });
};

const testing = @import("../../../../testing.zig");
test "WebApi: HTML.Table" {
    try testing.htmlRunner("element/html/table.html", .{});
}
