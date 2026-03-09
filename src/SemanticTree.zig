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
prune: bool = false,

pub fn jsonStringify(self: @This(), jw: *std.json.Stringify) error{WriteFailed}!void {
    var visitor = JsonVisitor{ .jw = jw, .tree = self };
    var xpath_buffer: std.ArrayList(u8) = .{};
    self.walk(self.dom_node, &xpath_buffer, null, &visitor) catch |err| {
        log.err(.app, "semantic tree json dump failed", .{ .err = err });
        return error.WriteFailed;
    };
}

pub fn textStringify(self: @This(), writer: *std.Io.Writer) error{WriteFailed}!void {
    var visitor = TextVisitor{ .writer = writer, .tree = self, .depth = 0 };
    var xpath_buffer: std.ArrayList(u8) = .empty;
    self.walk(self.dom_node, &xpath_buffer, null, &visitor) catch |err| {
        log.err(.app, "semantic tree text dump failed", .{ .err = err });
        return error.WriteFailed;
    };
}

const OptionData = struct {
    value: []const u8,
    text: []const u8,
    selected: bool,
};

const NodeData = struct {
    id: u32,
    axn: AXNode,
    role: []const u8,
    name: ?[]const u8,
    value: ?[]const u8,
    options: ?[]OptionData = null,
    xpath: []const u8,
    is_interactive: bool,
    node_name: []const u8,
};

fn isDisplayNone(style: []const u8) bool {
    var it = std.mem.splitScalar(u8, style, ';');
    while (it.next()) |decl| {
        var decl_it = std.mem.splitScalar(u8, decl, ':');
        const prop = decl_it.next() orelse continue;
        const value = decl_it.next() orelse continue;

        const prop_trimmed = std.mem.trim(u8, prop, &std.ascii.whitespace);
        const value_trimmed = std.mem.trim(u8, value, &std.ascii.whitespace);

        if (std.ascii.eqlIgnoreCase(prop_trimmed, "display") and
            std.ascii.eqlIgnoreCase(value_trimmed, "none"))
        {
            return true;
        }
    }
    return false;
}

fn walk(self: @This(), node: *Node, xpath_buffer: *std.ArrayList(u8), parent_name: ?[]const u8, visitor: anytype) !void {
    // 1. Skip non-content nodes
    if (node.is(Element)) |el| {
        const tag = el.getTag();
        if (tag.isMetadata() or tag == .svg) return;

        // We handle options/optgroups natively inside their parents, skip them in the general walk
        if (tag == .datalist or tag == .option or tag == .optgroup) return;

        // CSS display: none visibility check (inline style only for now)
        if (el.getAttributeSafe(comptime lp.String.wrap("style"))) |style| {
            if (isDisplayNone(style)) {
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
    var options: ?[]OptionData = null;
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
            if (el.getAttributeSafe(comptime lp.String.wrap("list"))) |list_id| {
                options = try extractDataListOptions(list_id, self.page, self.arena);
            }
        } else if (el.is(Element.Html.TextArea)) |textarea| {
            value = textarea.getValue();
        } else if (el.is(Element.Html.Select)) |select| {
            value = select.getValue(self.page);
            options = try extractSelectOptions(el.asNode(), self.page, self.arena);
        }
    } else if (node._type == .document or node._type == .document_fragment) {
        node_name = "root";
    }

    const initial_xpath_len = xpath_buffer.items.len;
    try appendXPathSegment(node, xpath_buffer.writer(self.arena));
    const xpath = xpath_buffer.items;

    const name = try axn.getName(self.page, self.arena);

    var data = NodeData{
        .id = cdp_node.id,
        .axn = axn,
        .role = role,
        .name = name,
        .value = value,
        .options = options,
        .xpath = xpath,
        .is_interactive = is_interactive,
        .node_name = node_name,
    };

    var should_visit = true;
    if (self.prune) {
        const structural = isStructuralRole(role);
        const has_explicit_label = if (node.is(Element)) |el|
            el.getAttributeSafe(.wrap("aria-label")) != null or el.getAttributeSafe(.wrap("title")) != null
        else
            false;

        if (structural and !is_interactive and !has_explicit_label) {
            should_visit = false;
        }

        if (std.mem.eql(u8, role, "StaticText") and node._parent != null) {
            if (parent_name != null and name != null and std.mem.indexOf(u8, parent_name.?, name.?) != null) {
                should_visit = false;
            }
        }
    }

    var did_visit = false;
    var should_walk_children = true;
    if (should_visit) {
        should_walk_children = try visitor.visit(node, &data);
        did_visit = true; // Always true if should_visit was true, because visit() executed and opened structures
    } else {
        // If we skip the node, we must NOT tell the visitor to close it later
        did_visit = false;
    }

    if (should_walk_children) {
        // If we are printing this node normally OR skipping it and unrolling its children,
        // we walk the children iterator.
        var it = node.childrenIterator();
        while (it.next()) |child| {
            try self.walk(child, xpath_buffer, name, visitor);
        }
    }

    if (did_visit) {
        try visitor.leave();
    }

    xpath_buffer.shrinkRetainingCapacity(initial_xpath_len);
}

fn extractSelectOptions(node: *Node, page: *Page, arena: std.mem.Allocator) ![]OptionData {
    var options = std.ArrayListUnmanaged(OptionData){};
    var it = node.childrenIterator();
    while (it.next()) |child| {
        if (child.is(Element)) |el| {
            if (el.getTag() == .option) {
                if (el.is(Element.Html.Option)) |opt| {
                    const text = opt.getText();
                    const value = opt.getValue(page);
                    const selected = opt.getSelected();
                    try options.append(arena, .{ .text = text, .value = value, .selected = selected });
                }
            } else if (el.getTag() == .optgroup) {
                var group_it = child.childrenIterator();
                while (group_it.next()) |group_child| {
                    if (group_child.is(Element.Html.Option)) |opt| {
                        const text = opt.getText();
                        const value = opt.getValue(page);
                        const selected = opt.getSelected();
                        try options.append(arena, .{ .text = text, .value = value, .selected = selected });
                    }
                }
            }
        }
    }
    return options.toOwnedSlice(arena);
}

fn extractDataListOptions(list_id: []const u8, page: *Page, arena: std.mem.Allocator) !?[]OptionData {
    if (page.document.getElementById(list_id, page)) |referenced_el| {
        if (referenced_el.getTag() == .datalist) {
            return try extractSelectOptions(referenced_el.asNode(), page, arena);
        }
    }
    return null;
}

fn appendXPathSegment(node: *Node, writer: anytype) !void {
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
        try std.fmt.format(writer, "/{s}[{d}]", .{ tag, index });
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
        try std.fmt.format(writer, "/text()[{d}]", .{index});
    }
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

            if (data.options) |options| {
                try self.jw.objectField("options");
                try self.jw.beginArray();
                for (options) |opt| {
                    try self.jw.beginObject();
                    try self.jw.objectField("value");
                    try self.jw.write(opt.value);
                    try self.jw.objectField("text");
                    try self.jw.write(opt.text);
                    try self.jw.objectField("selected");
                    try self.jw.write(opt.selected);
                    try self.jw.endObject();
                }
                try self.jw.endArray();
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

        if (data.options != null) {
            // Signal to not walk children, as we handled them natively
            return false;
        }

        return true;
    }

    pub fn leave(self: *JsonVisitor) !void {
        try self.jw.endArray();
        try self.jw.endObject();
    }
};

fn isStructuralRole(role: []const u8) bool {
    // zig fmt: off
    return std.mem.eql(u8, role, "none") or
        std.mem.eql(u8, role, "generic") or
        std.mem.eql(u8, role, "InlineTextBox") or
        std.mem.eql(u8, role, "banner") or
        std.mem.eql(u8, role, "navigation") or
        std.mem.eql(u8, role, "main") or
        std.mem.eql(u8, role, "list") or
        std.mem.eql(u8, role, "listitem") or
        std.mem.eql(u8, role, "region");
    // zig fmt: on
}

const TextVisitor = struct {
    writer: *std.Io.Writer,
    tree: Self,
    depth: usize,

    pub fn visit(self: *TextVisitor, node: *Node, data: *NodeData) !bool {
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

        if (data.options) |options| {
            try self.writer.writeAll(" options: [");
            for (options, 0..) |opt, i| {
                if (i > 0) try self.writer.writeAll(", ");
                try self.writer.print("'{s}'", .{opt.value});
                if (opt.selected) {
                    try self.writer.writeAll(" (selected)");
                }
            }
            try self.writer.writeAll("]\n");
            self.depth += 1;
            return false; // Native handling complete, do not walk children
        }

        try self.writer.writeByte('\n');
        self.depth += 1;

        // If this is a leaf-like semantic node and we already have a name,
        // skip children to avoid redundant StaticText or noise.
        const is_leaf_semantic = std.mem.eql(u8, data.role, "link") or
            std.mem.eql(u8, data.role, "button") or
            std.mem.eql(u8, data.role, "heading") or
            std.mem.eql(u8, data.role, "code");
        if (is_leaf_semantic and data.name != null and data.name.?.len > 0) {
            return false;
        }

        return true;
    }

    pub fn leave(self: *TextVisitor) !void {
        if (self.depth > 0) {
            self.depth -= 1;
        }
    }
};
