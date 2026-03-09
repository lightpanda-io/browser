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
// along with this program.  See <https://www.gnu.org/licenses/>.

const std = @import("std");

const lp = @import("lightpanda");
const log = @import("log.zig");
const isAllWhitespace = @import("string.zig").isAllWhitespace;
const Page = lp.Page;

const CData = @import("browser/webapi/CData.zig");
const Element = @import("browser/webapi/Element.zig");
const Node = @import("browser/webapi/Node.zig");
const AXNode = @import("cdp/AXNode.zig");
const CDPNode = @import("cdp/Node.zig");

const Self = @This();

dom_node: *Node,
registry: *CDPNode.Registry,
page: *Page,
arena: std.mem.Allocator,

pub fn jsonStringify(self: @This(), jw: *std.json.Stringify) error{WriteFailed}!void {
    var visitor = JsonVisitor{ .jw = jw, .tree = self };
    self.walk(self.dom_node, "", &visitor) catch |err| {
        log.err(.app, "semantic tree json dump failed", .{ .err = err });
        return error.WriteFailed;
    };
}

pub fn textStringify(self: @This(), writer: *std.Io.Writer) error{WriteFailed}!void {
    var visitor = TextVisitor{ .writer = writer, .tree = self, .depth = 0 };
    self.walk(self.dom_node, "", &visitor) catch |err| {
        log.err(.app, "semantic tree text dump failed", .{ .err = err });
        return error.WriteFailed;
    };
}

const NodeData = struct {
    id: u32,
    axn: AXNode,
    role: []const u8,
    name: ?[]const u8,
    value: ?[]const u8,
    xpath: []const u8,
    is_interactive: bool,
    node_name: []const u8,
};

fn walk(self: @This(), node: *Node, parent_xpath: []const u8, visitor: anytype) !void {
    // 1. Skip non-content nodes
    if (node.is(Element)) |el| {
        const tag = el.getTag();
        if (tag.isMetadata() or tag == .svg) return;

        // CSS display: none visibility check (inline style only for now)
        if (el.getAttributeSafe(comptime lp.String.wrap("style"))) |style| {
            if (std.mem.indexOf(u8, style, "display: none") != null or
                std.mem.indexOf(u8, style, "display:none") != null)
            {
                return;
            }
        }

        if (el.is(Element.Html)) |html_el| {
            if (html_el.getHidden()) return;
        }
    } else if (node.is(CData.Text) != null) {
        const text_node = node.is(CData.Text).?;
        const text = text_node.getWholeText();
        if (isAllWhitespace(text)) {
            return;
        }
    } else if (node._type != .document and node._type != .document_fragment) {
        return;
    }

    const cdp_node = try self.registry.register(node);
    const axn = AXNode.fromNode(node);
    const role = try axn.getRole();

    var is_interactive = false;
    var value: ?[]const u8 = null;
    var node_name: []const u8 = "text";

    if (node.is(Element)) |el| {
        node_name = el.getTagNameLower();

        const ax_role = std.meta.stringToEnum(AXNode.AXRole, role) orelse .none;
        is_interactive = ax_role.isInteractive();

        const event_target = node.asEventTarget();
        if (self.page._event_manager.hasListener(event_target, "click") or
            self.page._event_manager.hasListener(event_target, "mousedown") or
            self.page._event_manager.hasListener(event_target, "mouseup") or
            self.page._event_manager.hasListener(event_target, "keydown") or
            self.page._event_manager.hasListener(event_target, "change") or
            self.page._event_manager.hasListener(event_target, "input"))
        {
            is_interactive = true;
        }

        if (el.is(Element.Html)) |html_el| {
            if (html_el.hasAttributeFunction(.onclick, self.page) or
                html_el.hasAttributeFunction(.onmousedown, self.page) or
                html_el.hasAttributeFunction(.onmouseup, self.page) or
                html_el.hasAttributeFunction(.onkeydown, self.page) or
                html_el.hasAttributeFunction(.onchange, self.page) or
                html_el.hasAttributeFunction(.oninput, self.page))
            {
                is_interactive = true;
            }
        }

        if (el.is(Element.Html.Input)) |input| {
            value = input.getValue();
        } else if (el.is(Element.Html.TextArea)) |textarea| {
            value = textarea.getValue();
        } else if (el.is(Element.Html.Select)) |select| {
            value = select.getValue(self.page);
        }
    } else if (node._type == .document or node._type == .document_fragment) {
        node_name = "root";
    }

    const segment = try self.getXPathSegment(node);
    const xpath = try std.mem.concat(self.arena, u8, &.{ parent_xpath, segment });

    const name = try axn.getName(self.page, self.arena);

    var data = NodeData{
        .id = cdp_node.id,
        .axn = axn,
        .role = role,
        .name = name,
        .value = value,
        .xpath = xpath,
        .is_interactive = is_interactive,
        .node_name = node_name,
    };

    if (try visitor.visit(node, &data)) {
        var it = node.childrenIterator();
        while (it.next()) |child| {
            try self.walk(child, xpath, visitor);
        }
        try visitor.leave(node, &data);
    }
}

fn getXPathSegment(self: @This(), node: *Node) ![]const u8 {
    if (node.is(Element)) |el| {
        const tag = el.getTagNameLower();
        var index: usize = 1;

        if (node._parent) |parent| {
            var it = parent.childrenIterator();
            while (it.next()) |sibling| {
                if (sibling == node) break;
                if (sibling.is(Element)) |s_el| {
                    if (std.mem.eql(u8, s_el.getTagNameLower(), tag)) {
                        index += 1;
                    }
                }
            }
        }
        return std.fmt.allocPrint(self.arena, "/{s}[{d}]", .{ tag, index });
    } else if (node.is(CData.Text) != null) {
        var index: usize = 1;
        if (node._parent) |parent| {
            var it = parent.childrenIterator();
            while (it.next()) |sibling| {
                if (sibling == node) break;
                if (sibling.is(CData.Text) != null) {
                    index += 1;
                }
            }
        }
        return std.fmt.allocPrint(self.arena, "/text()[{d}]", .{index});
    }
    return "";
}

const JsonVisitor = struct {
    jw: *std.json.Stringify,
    tree: Self,

    pub fn visit(self: *JsonVisitor, node: *Node, data: *NodeData) !bool {
        try self.jw.beginObject();

        try self.jw.objectField("nodeId");
        try self.jw.write(try std.fmt.allocPrint(self.tree.arena, "{d}", .{data.id}));

        try self.jw.objectField("backendDOMNodeId");
        try self.jw.write(data.id);

        try self.jw.objectField("nodeName");
        try self.jw.write(data.node_name);

        try self.jw.objectField("xpath");
        try self.jw.write(data.xpath);

        if (node.is(Element)) |el| {
            try self.jw.objectField("nodeType");
            try self.jw.write(1);

            try self.jw.objectField("isInteractive");
            try self.jw.write(data.is_interactive);

            try self.jw.objectField("role");
            try self.jw.write(data.role);

            if (data.name) |name| {
                if (name.len > 0) {
                    try self.jw.objectField("name");
                    try self.jw.write(name);
                }
            }

            if (data.value) |value| {
                try self.jw.objectField("value");
                try self.jw.write(value);
            }

            if (el._attributes) |attrs| {
                try self.jw.objectField("attributes");
                try self.jw.beginObject();
                var iter = attrs.iterator();
                while (iter.next()) |attr| {
                    try self.jw.objectField(attr._name.str());
                    try self.jw.write(attr._value.str());
                }
                try self.jw.endObject();
            }
        } else if (node.is(CData.Text) != null) {
            const text_node = node.is(CData.Text).?;
            try self.jw.objectField("nodeType");
            try self.jw.write(3);
            try self.jw.objectField("nodeValue");
            try self.jw.write(text_node.getWholeText());
        } else {
            try self.jw.objectField("nodeType");
            try self.jw.write(9);
        }

        try self.jw.objectField("children");
        try self.jw.beginArray();
        return true;
    }

    pub fn leave(self: *JsonVisitor, _: *Node, _: *NodeData) !void {
        try self.jw.endArray();
        try self.jw.endObject();
    }
};

fn isStructuralRole(role: []const u8) bool {
    return std.mem.eql(u8, role, "none") or
        std.mem.eql(u8, role, "generic") or
        std.mem.eql(u8, role, "InlineTextBox");
}

const TextVisitor = struct {
    writer: *std.Io.Writer,
    tree: Self,
    depth: usize,

    pub fn visit(self: *TextVisitor, node: *Node, data: *NodeData) !bool {
        // Pruning Heuristic:
        // If it's a structural node (none/generic) and has no unique label, unwrap it.
        // We only keep 'none'/'generic' if they are interactive.
        const structural = isStructuralRole(data.role);
        const has_explicit_label = if (node.is(Element)) |el|
            el.getAttributeSafe(.wrap("aria-label")) != null or el.getAttributeSafe(.wrap("title")) != null
        else
            false;

        if (structural and !data.is_interactive and !has_explicit_label) {
            // Just unwrap (don't print this node, but visit children at same depth)
            return true;
        }

        // Skip redundant StaticText nodes if the parent already captures the text
        if (std.mem.eql(u8, data.role, "StaticText") and node._parent != null) {
            const parent_axn = AXNode.fromNode(node._parent.?);
            const parent_name = try parent_axn.getName(self.tree.page, self.tree.arena);
            if (parent_name != null and data.name != null and std.mem.indexOf(u8, parent_name.?, data.name.?) != null) {
                return false;
            }
        }

        // Format: "  [12] link: Hacker News (value)"
        for (0..(self.depth * 2)) |_| {
            try self.writer.writeByte(' ');
        }
        try self.writer.print("[{d}] {s}: ", .{ data.id, data.role });

        if (data.name) |n| {
            if (n.len > 0) {
                try self.writer.writeAll(n);
            }
        } else if (node.is(CData.Text) != null) {
            const text_node = node.is(CData.Text).?;
            const trimmed = std.mem.trim(u8, text_node.getWholeText(), " \t\r\n");
            if (trimmed.len > 0) {
                try self.writer.writeAll(trimmed);
            }
        }

        if (data.value) |v| {
            if (v.len > 0) {
                try self.writer.print(" (value: {s})", .{v});
            }
        }

        try self.writer.writeByte('\n');
        self.depth += 1;
        return true;
    }

    pub fn leave(self: *TextVisitor, node: *Node, data: *NodeData) !void {
        const structural = isStructuralRole(data.role);
        const has_explicit_label = if (node.is(Element)) |el|
            el.getAttributeSafe(.wrap("aria-label")) != null or el.getAttributeSafe(.wrap("title")) != null
        else
            false;

        if (structural and !data.is_interactive and !has_explicit_label) {
            return;
        }
        self.depth -= 1;
    }
};
