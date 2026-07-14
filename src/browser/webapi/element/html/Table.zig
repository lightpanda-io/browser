const std = @import("std");

const js = @import("../../../js/js.zig");
const Node = @import("../../Node.zig");
const Frame = @import("../../../Frame.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");
const collections = @import("../../collections.zig");

const Table = @This();

_proto: *HtmlElement,

pub fn asElement(self: *Table) *Element {
    return self._proto._proto;
}
pub fn asNode(self: *Table) *Node {
    return self.asElement().asNode();
}

pub fn getTBodies(self: *Table, frame: *Frame) collections.NodeLive(.child_tag) {
    return collections.NodeLive(.child_tag).init(self.asNode(), .tbody, frame);
}

// The table's rows in spec order: rows of thead children first, then tr
// children of the table and rows of tbody children in tree order, then rows
// of tfoot children.
fn collectRows(self: *Table, frame: *Frame) !std.ArrayList(*Node) {
    var rows: std.ArrayList(*Node) = .empty;
    // Scratch only: deleteRow reads the list before the removal (the only
    // point that can re-enter JS), so the local arena suffices.
    const arena = frame.local_arena;

    try self.appendSectionRows(.thead, &rows, arena);

    var it = self.asNode().childrenIterator();
    while (it.next()) |child| {
        const el = child.is(Element) orelse continue;
        switch (el.getTag()) {
            .tr => try rows.append(arena, child),
            .tbody => try appendChildRows(child, &rows, arena),
            else => {},
        }
    }

    try self.appendSectionRows(.tfoot, &rows, arena);
    return rows;
}

fn appendSectionRows(self: *Table, tag: Element.Tag, rows: *std.ArrayList(*Node), arena: std.mem.Allocator) !void {
    var it = self.asNode().childrenIterator();
    while (it.next()) |child| {
        const el = child.is(Element) orelse continue;
        if (el.getTag() != tag) continue;
        try appendChildRows(child, rows, arena);
    }
}

fn appendChildRows(section: *Node, rows: *std.ArrayList(*Node), arena: std.mem.Allocator) !void {
    var it = section.childrenIterator();
    while (it.next()) |child| {
        const el = child.is(Element) orelse continue;
        if (el.getTag() == .tr) {
            try rows.append(arena, child);
        }
    }
}

pub fn deleteRow(self: *Table, index: i32, frame: *Frame) !void {
    const rows = try self.collectRows(frame);
    const len: i32 = @intCast(rows.items.len);
    const idx: i32 = if (index == -1) len - 1 else index;
    if (idx == -1 and index == -1) {
        // deleteRow(-1) on a rowless table is a no-op.
        return;
    }
    if (idx < 0 or idx >= len) {
        return error.IndexSizeError;
    }
    const row = rows.items[@intCast(idx)];
    _ = try row.parentNode().?.removeChild(row, frame);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Table);

    pub const Meta = struct {
        pub const name = "HTMLTableElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const tBodies = bridge.accessor(Table.getTBodies, null, .{});
    pub const deleteRow = bridge.function(Table.deleteRow, .{ .ce_reactions = true });
};
