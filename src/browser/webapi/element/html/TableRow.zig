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
const Table = @import("Table.zig");
const Cell = @import("TableCell.zig");
const Section = @import("TableSection.zig");

const TableRow = @This();

pub const Proto = HtmlElement;

_pad: bool = false,
_proto_canary: if (lp.IS_DEBUG) *HtmlElement else void = undefined,

pub fn asElement(self: *TableRow) *Element {
    return Factory.protoOf(self).asElement();
}
pub fn asNode(self: *TableRow) *Node {
    return self.asElement().asNode();
}

fn getCells(self: *TableRow, frame: *Frame) collections.NodeLive(.cells) {
    return collections.NodeLive(.cells).init(self.asNode(), {}, frame);
}

fn insertCell(self: *TableRow, index: ?i32, frame: *Frame) !*Cell {
    return Table.insertChild(self.asNode(), Cell, "td", index, frame);
}

fn deleteCell(self: *TableRow, index: i32, frame: *Frame) !void {
    return Table.deleteChild(self.asNode(), Cell, index, frame);
}

fn getRowIndex(self: *TableRow) i32 {
    const node = self.asNode();
    const parent = node._parent orelse return -1;
    if (parent.is(Table)) |table| {
        return table.rowIndex(node);
    }
    if (parent.is(Section) == null) {
        return -1;
    }
    const grandparent = parent._parent orelse return -1;
    const table = grandparent.is(Table) orelse return -1;
    return table.rowIndex(node);
}

fn getSectionRowIndex(self: *TableRow) i32 {
    const node = self.asNode();
    const parent = node._parent orelse return -1;
    if (parent.is(Table)) |table| {
        return table.rowIndex(node);
    }
    if (parent.is(Section) == null) {
        return -1;
    }
    return Table.childIndex(parent, TableRow, node);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(TableRow);

    pub const Meta = struct {
        pub const name = "HTMLTableRowElement";
        pub var class_id: bridge.ClassId = undefined;
    };

    const reflect = Element.Reflect(TableRow);
    pub const vAlign = reflect.string("valign");
    pub const chOff = reflect.string("charoff");
    pub const ch = reflect.string("char");
    pub const bgColor = reflect.stringNullToEmpty("bgcolor");
    pub const @"align" = reflect.string("align");

    pub const cells = bridge.accessor(TableRow.getCells, null, .{});
    pub const insertCell = bridge.function(TableRow.insertCell, .{ .ce_reactions = true });
    pub const deleteCell = bridge.function(TableRow.deleteCell, .{ .ce_reactions = true });
    pub const rowIndex = bridge.accessor(TableRow.getRowIndex, null, .{});
    pub const sectionRowIndex = bridge.accessor(TableRow.getSectionRowIndex, null, .{});
};
