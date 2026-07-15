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

pub fn deleteRow(self: *Table, index: i32, frame: *Frame) !void {
    if (index < -1) {
        return error.IndexSizeError;
    }
    const row = self.findRow(index) orelse {
        if (index == -1) {
            // deleteRow(-1) on a rowless table is a no-op.
            return;
        }
        return error.IndexSizeError;
    };
    _ = try row.parentNode().?.removeChild(row, frame);
}

// Finds the index-th row (or the last row for -1) in spec order: thead, tr,
// tbody then tfoot
fn findRow(self: *Table, index: i32) ?*Node {
    var scan: RowScan = .{ .index = index };

    if (self.scanSectionRows(.thead, &scan)) |row| {
        return row;
    }

    var it = self.asNode().childrenIterator();
    while (it.next()) |child| {
        const el = child.is(Element) orelse continue;
        switch (el.getTag()) {
            .tr => if (scan.check(child)) |row| {
                return row;
            },
            .tbody => if (scanChildRows(child, &scan)) |row| {
                return row;
            },
            else => {},
        }
    }

    if (self.scanSectionRows(.tfoot, &scan)) |row| {
        return row;
    }
    if (index == -1) {
        return scan.last;
    }
    return null;
}

const RowScan = struct {
    index: i32,
    count: i32 = 0,
    last: ?*Node = null,

    fn check(self: *RowScan, row: *Node) ?*Node {
        if (self.count == self.index) {
            return row;
        }
        self.count += 1;
        self.last = row;
        return null;
    }
};

fn scanSectionRows(self: *Table, tag: Element.Tag, scan: *RowScan) ?*Node {
    var it = self.asNode().childrenIterator();
    while (it.next()) |child| {
        const el = child.is(Element) orelse continue;
        if (el.getTag() != tag) {
            continue;
        }
        if (scanChildRows(child, scan)) |row| {
            return row;
        }
    }
    return null;
}

fn scanChildRows(section: *Node, scan: *RowScan) ?*Node {
    var it = section.childrenIterator();
    while (it.next()) |child| {
        const el = child.is(Element) orelse continue;
        if (el.getTag() == .tr) {
            if (scan.check(child)) |row| {
                return row;
            }
        }
    }
    return null;
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

const testing = @import("../../../../testing.zig");
test "WebApi: HTML.Table" {
    try testing.htmlRunner("element/html/table.html", .{});
}
