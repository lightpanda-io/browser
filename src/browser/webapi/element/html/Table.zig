// Copyright (C) 2023-2026  Lightpanda (Selecy SAS)
//
// Francis Bouvier <francis@lightpanda.io>
// Pierre Tachoire <pierre@lightpanda.io>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as
// published by the Free Software Foundation, either version 3 of the
// License, or (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License

const lp = @import("lightpanda");

const js = @import("../../../js/js.zig");
const Frame = @import("../../../Frame.zig");
const Factory = @import("../../../Factory.zig");

const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const collections = @import("../../collections.zig");

const HtmlElement = @import("../Html.zig");

const Table = @This();

pub const Proto = HtmlElement;

_pad: bool = false,
_proto_canary: if (lp.IS_DEBUG) *HtmlElement else void = undefined,

pub fn asElement(self: *Table) *Element {
    return Factory.protoOf(self).asElement();
}
pub fn asNode(self: *Table) *Node {
    return self.asElement().asNode();
}

fn getTBodies(self: *Table, frame: *Frame) collections.NodeLive(.child_tag) {
    return collections.NodeLive(.child_tag).init(self.asNode(), .tbody, frame);
}

fn deleteRow(self: *Table, index: i32, frame: *Frame) !void {
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

// Finds the index-th row (or the last row for -1) in spec order
fn findRow(self: *Table, index: i32) ?*Node {
    var it = RowWalker.init(self.asNode(), .{});
    var count: i32 = 0;
    var last: ?*Node = null;
    while (it.next()) |row| {
        if (count == index) {
            return row;
        }
        count += 1;
        last = row;
    }
    return if (index == -1) last else null;
}

fn getRows(self: *Table, frame: *Frame) collections.NodeLive(.table_rows) {
    return collections.NodeLive(.table_rows).init(self.asNode(), {}, frame);
}

// Walks a table's rows in spec order: thead rows, then tr children of the
// table and tbody rows, then tfoot rows, each group in tree order.
pub const RowWalker = struct {
    _root: *Node,
    _phase: Phase = .head,
    // the next child of the table to look at
    _child: ?*Node,
    // the next candidate row inside the current section
    _row: ?*Node = null,

    const Phase = enum { head, body, foot };
    const Opts = struct {};

    pub fn init(root: *Node, _: Opts) RowWalker {
        return .{
            ._root = root,
            ._child = root.firstChild(),
        };
    }

    pub fn next(self: *RowWalker) ?*Node {
        while (true) {
            while (self._row) |node| {
                self._row = node.nextSibling();
                if (tagOf(node) == .tr) {
                    return node;
                }
            }

            const child = self._child orelse {
                self._phase = switch (self._phase) {
                    .head => .body,
                    .body => .foot,
                    .foot => return null,
                };
                self._child = self._root.firstChild();
                continue;
            };
            self._child = child.nextSibling();

            switch (self._phase) {
                .head => if (tagOf(child) == .thead) {
                    self._row = child.firstChild();
                },
                .body => switch (tagOf(child) orelse continue) {
                    .tr => return child,
                    .tbody => self._row = child.firstChild(),
                    else => {},
                },
                .foot => if (tagOf(child) == .tfoot) {
                    self._row = child.firstChild();
                },
            }
        }
    }

    pub fn reset(self: *RowWalker) void {
        self.* = init(self._root, .{});
    }

    pub fn clone(self: *const RowWalker) RowWalker {
        return init(self._root, .{});
    }

    pub fn contains(self: *const RowWalker, target: *Node) bool {
        if (tagOf(target) != .tr) {
            return false;
        }
        const parent = target._parent orelse return false;
        if (parent == self._root) {
            return true;
        }
        return switch (tagOf(parent) orelse return false) {
            .thead, .tbody, .tfoot => parent._parent == self._root,
            else => false,
        };
    }

    fn tagOf(node: *Node) ?Element.Tag {
        const el = node.is(Element) orelse return null;
        return el.getTag();
    }
};

pub const JsApi = struct {
    pub const bridge = js.Bridge(Table);

    pub const Meta = struct {
        pub const name = "HTMLTableElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    const reflect = Element.Reflect(Table);
    pub const width = reflect.string("width");
    pub const summary = reflect.string("summary");
    pub const rules = reflect.string("rules");
    pub const frame = reflect.string("frame");
    pub const cellSpacing = reflect.stringNullToEmpty("cellspacing");
    pub const cellPadding = reflect.stringNullToEmpty("cellpadding");
    pub const border = reflect.string("border");
    pub const bgColor = reflect.stringNullToEmpty("bgcolor");
    pub const @"align" = reflect.string("align");

    pub const tBodies = bridge.accessor(Table.getTBodies, null, .{});
    pub const rows = bridge.accessor(Table.getRows, null, .{});
    pub const deleteRow = bridge.function(Table.deleteRow, .{ .ce_reactions = true });
};

const testing = @import("../../../../testing.zig");
test "WebApi: HTML.Table" {
    try testing.htmlRunner("element/html/table.html", .{});
}
