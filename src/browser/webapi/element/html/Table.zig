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

const Row = @import("TableRow.zig");
const Col = @import("TableCol.zig");
const Section = @import("TableSection.zig");
const Caption = @import("TableCaption.zig");

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

fn getCaption(self: *Table) ?*Caption {
    var child = self.asNode().firstChild();
    while (child) |node| : (child = node.nextSibling()) {
        if (node.is(Caption)) |caption| {
            return caption;
        }
    }
    return null;
}

fn setCaption(self: *Table, caption_: ?*Caption, frame: *Frame) !void {
    try self.deleteCaption(frame);
    const caption = caption_ orelse return;
    _ = try self.asNode().insertBefore(caption.asNode(), self.asNode().firstChild(), frame);
}

fn createCaption(self: *Table, frame: *Frame) !*Caption {
    if (self.getCaption()) |caption| {
        return caption;
    }
    const caption = try createElement(self.asNode(), Caption, "caption", frame);
    _ = try self.asNode().insertBefore(caption.asNode(), self.asNode().firstChild(), frame);
    return caption;
}

fn deleteCaption(self: *Table, frame: *Frame) !void {
    const caption = self.getCaption() orelse return;
    _ = try self.asNode().removeChild(caption.asNode(), frame);
}

fn getTHead(self: *Table) ?*Section {
    return self.findSection(.thead);
}

fn setTHead(self: *Table, head_: ?*Section, frame: *Frame) !void {
    if (head_) |head| {
        if (head._tag != .thead) {
            return error.HierarchyError;
        }
    }
    try self.deleteTHead(frame);
    const head = head_ orelse return;
    try self.insertTHead(head, frame);
}

fn createTHead(self: *Table, frame: *Frame) !*Section {
    if (self.getTHead()) |head| {
        return head;
    }
    const head = try createElement(self.asNode(), Section, "thead", frame);
    try self.insertTHead(head, frame);
    return head;
}

fn deleteTHead(self: *Table, frame: *Frame) !void {
    const head = self.getTHead() orelse return;
    _ = try self.asNode().removeChild(head.asNode(), frame);
}

// A thead goes before the first element child that is neither a caption nor a colgroup
fn insertTHead(self: *Table, head: *Section, frame: *Frame) !void {
    var child = self.asNode().firstChild();
    while (child) |node| : (child = node.nextSibling()) {
        if (node.is(Element) == null or node.is(Caption) != null) {
            continue;
        }
        if (node.is(Col)) |col| {
            if (col._tag == .colgroup) {
                continue;
            }
        }
        break;
    }
    _ = try self.asNode().insertBefore(head.asNode(), child, frame);
}

fn getTFoot(self: *Table) ?*Section {
    return self.findSection(.tfoot);
}

fn setTFoot(self: *Table, foot_: ?*Section, frame: *Frame) !void {
    if (foot_) |foot| {
        if (foot._tag != .tfoot) {
            return error.HierarchyError;
        }
    }
    try self.deleteTFoot(frame);
    const foot = foot_ orelse return;
    _ = try self.asNode().appendChild(foot.asNode(), frame);
}

fn createTFoot(self: *Table, frame: *Frame) !*Section {
    if (self.getTFoot()) |foot| {
        return foot;
    }
    const foot = try createElement(self.asNode(), Section, "tfoot", frame);
    _ = try self.asNode().appendChild(foot.asNode(), frame);
    return foot;
}

fn deleteTFoot(self: *Table, frame: *Frame) !void {
    const foot = self.getTFoot() orelse return;
    _ = try self.asNode().removeChild(foot.asNode(), frame);
}

// The new tbody goes right after the last tbody child, or at the end
fn createTBody(self: *Table, frame: *Frame) !*Section {
    const body = try createElement(self.asNode(), Section, "tbody", frame);
    const ref = if (self.lastTBody()) |last| last.asNode().nextSibling() else null;
    _ = try self.asNode().insertBefore(body.asNode(), ref, frame);
    return body;
}

fn findSection(self: *Table, tag: Element.Tag) ?*Section {
    var child = self.asNode().firstChild();
    while (child) |node| : (child = node.nextSibling()) {
        const section = node.is(Section) orelse continue;
        if (section._tag == tag) {
            return section;
        }
    }
    return null;
}

fn lastTBody(self: *Table) ?*Section {
    var child = self.asNode().lastChild();
    while (child) |node| : (child = node.previousSibling()) {
        const section = node.is(Section) orelse continue;
        if (section._tag == .tbody) {
            return section;
        }
    }
    return null;
}

fn insertRow(self: *Table, index_: ?i32, frame: *Frame) !*Row {
    const index = index_ orelse -1;
    if (index < -1) {
        return error.IndexSizeError;
    }

    var it = RowWalker.init(self.asNode(), .{});
    var count: i32 = 0;
    var target: ?*Node = null;
    var last: ?*Node = null;
    while (it.next()) |row| {
        if (count == index) {
            target = row;
        }
        count += 1;
        last = row;
    }
    if (index > count) {
        return error.IndexSizeError;
    }

    const row = try createElement(self.asNode(), Row, "tr", frame);
    if (target) |ref| {
        _ = try ref.parentNode().?.insertBefore(row.asNode(), ref, frame);
    } else if (last) |ref| {
        _ = try ref.parentNode().?.appendChild(row.asNode(), frame);
    } else if (self.lastTBody()) |body| {
        _ = try body.asNode().appendChild(row.asNode(), frame);
    } else {
        const body = try createElement(self.asNode(), Section, "tbody", frame);
        _ = try body.asNode().appendChild(row.asNode(), frame);
        _ = try self.asNode().appendChild(body.asNode(), frame);
    }
    return row;
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

pub fn rowIndex(self: *Table, row: *Node) i32 {
    var it = RowWalker.init(self.asNode(), .{});
    var index: i32 = 0;
    while (it.next()) |node| : (index += 1) {
        if (node == row) {
            return index;
        }
    }
    return -1;
}

fn createElement(parent: *Node, comptime T: type, comptime name: []const u8, frame: *Frame) !*T {
    const node = try Frame.node_factory.createElementNS(parent.getDocument(frame), .html, name, null);
    return node.as(T);
}

pub fn childIndex(parent: *Node, comptime T: type, child: *Node) i32 {
    var index: i32 = 0;
    var it = parent.firstChild();
    while (it) |node| : (it = node.nextSibling()) {
        if (node == child) {
            return index;
        }
        if (node.is(T) != null) {
            index += 1;
        }
    }
    return -1;
}

pub fn insertChild(parent: *Node, comptime T: type, comptime name: []const u8, index_: ?i32, frame: *Frame) !*T {
    const index = index_ orelse -1;
    if (index < -1) {
        return error.IndexSizeError;
    }
    var count: i32 = 0;
    var ref: ?*Node = null;
    var it = parent.firstChild();
    while (it) |node| : (it = node.nextSibling()) {
        if (node.is(T) == null) {
            continue;
        }
        if (count == index) {
            ref = node;
        }
        count += 1;
    }
    // -1 and an index one past the end both append
    if (index > count) {
        return error.IndexSizeError;
    }
    const child = try createElement(parent, T, name, frame);
    _ = try parent.insertBefore(child.asNode(), ref, frame);
    return child;
}

pub fn deleteChild(parent: *Node, comptime T: type, index: i32, frame: *Frame) !void {
    if (index < -1) {
        return error.IndexSizeError;
    }
    if (index == -1) {
        // -1 with nothing to delete is a no-op
        const child = lastOfType(parent, T) orelse return;
        _ = try parent.removeChild(child, frame);
        return;
    }
    const child = nthOfType(parent, T, index) orelse return error.IndexSizeError;
    _ = try parent.removeChild(child, frame);
}

fn nthOfType(parent: *Node, comptime T: type, index: i32) ?*Node {
    var count: i32 = 0;
    var it = parent.firstChild();
    while (it) |node| : (it = node.nextSibling()) {
        if (node.is(T) == null) {
            continue;
        }
        if (count == index) {
            return node;
        }
        count += 1;
    }
    return null;
}

fn lastOfType(parent: *Node, comptime T: type) ?*Node {
    var it = parent.lastChild();
    while (it) |node| : (it = node.previousSibling()) {
        if (node.is(T) != null) {
            return node;
        }
    }
    return null;
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
                if (node.is(Row) != null) {
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
                .head => if (sectionTag(child) == .thead) {
                    self._row = child.firstChild();
                },
                .body => if (child.is(Row) != null) {
                    return child;
                } else if (sectionTag(child) == .tbody) {
                    self._row = child.firstChild();
                },
                .foot => if (sectionTag(child) == .tfoot) {
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
        if (target.is(Row) == null) {
            return false;
        }
        const parent = target._parent orelse return false;
        if (parent == self._root) {
            return true;
        }
        return parent.is(Section) != null and parent._parent == self._root;
    }

    fn sectionTag(node: *Node) ?Element.Tag {
        const section = node.is(Section) orelse return null;
        return section._tag;
    }
};

pub const JsApi = struct {
    pub const bridge = js.Bridge(Table);

    pub const Meta = struct {
        pub const name = "HTMLTableElement";
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

    pub const caption = bridge.accessor(Table.getCaption, Table.setCaption, .{ .ce_reactions = true });
    pub const createCaption = bridge.function(Table.createCaption, .{ .ce_reactions = true });
    pub const deleteCaption = bridge.function(Table.deleteCaption, .{ .ce_reactions = true });
    pub const tHead = bridge.accessor(Table.getTHead, Table.setTHead, .{ .ce_reactions = true });
    pub const createTHead = bridge.function(Table.createTHead, .{ .ce_reactions = true });
    pub const deleteTHead = bridge.function(Table.deleteTHead, .{ .ce_reactions = true });
    pub const tFoot = bridge.accessor(Table.getTFoot, Table.setTFoot, .{ .ce_reactions = true });
    pub const createTFoot = bridge.function(Table.createTFoot, .{ .ce_reactions = true });
    pub const deleteTFoot = bridge.function(Table.deleteTFoot, .{ .ce_reactions = true });
    pub const tBodies = bridge.accessor(Table.getTBodies, null, .{});
    pub const createTBody = bridge.function(Table.createTBody, .{ .ce_reactions = true });
    pub const rows = bridge.accessor(Table.getRows, null, .{});
    pub const insertRow = bridge.function(Table.insertRow, .{ .ce_reactions = true });
    pub const deleteRow = bridge.function(Table.deleteRow, .{ .ce_reactions = true });
};

const testing = @import("../../../../testing.zig");
test "WebApi: HTML.Table" {
    try testing.htmlRunner("element/html/table.html", .{});
}
