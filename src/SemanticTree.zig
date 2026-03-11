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
const interactive = @import("browser/interactive.zig");

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
    const listener_targets = interactive.buildListenerTargetMap(self.page, self.arena) catch |err| {
        log.err(.app, "listener map failed", .{ .err = err });
        return error.WriteFailed;
    };
    self.walk(self.dom_node, &xpath_buffer, null, &visitor, 1, listener_targets) catch |err| {
        log.err(.app, "semantic tree json dump failed", .{ .err = err });
        return error.WriteFailed;
    };
}

pub fn textStringify(self: @This(), writer: *std.Io.Writer) error{WriteFailed}!void {
    var visitor = TextVisitor{ .writer = writer, .tree = self, .depth = 0 };
    var xpath_buffer: std.ArrayList(u8) = .empty;
    const listener_targets = interactive.buildListenerTargetMap(self.page, self.arena) catch |err| {
        log.err(.app, "listener map failed", .{ .err = err });
        return error.WriteFailed;
    };
    self.walk(self.dom_node, &xpath_buffer, null, &visitor, 1, listener_targets) catch |err| {
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

fn walk(self: @This(), node: *Node, xpath_buffer: *std.ArrayList(u8), parent_name: ?[]const u8, visitor: anytype, index: usize, listener_targets: interactive.ListenerTargetMap) !void {
    // 1. Skip non-content nodes
    if (node.is(Element)) |el| {
        const tag = el.getTag();
        if (tag.isMetadata() or tag == .svg) return;

        // We handle options/optgroups natively inside their parents, skip them in the general walk
        if (tag == .datalist or tag == .option or tag == .optgroup) return;

        // Check visibility using the engine's checkVisibility which handles CSS display: none
        if (!el.checkVisibility(self.page)) {
            return;
        }

        if (el.is(Element.Html)) |html_el| {
            if (html_el.getHidden()) return;
        }
    } else if (node.is(CData.Text) != null) {
        const text_node = node.as(CData.Text);
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

        if (el.is(Element.Html)) |html_el| {
            if (interactive.classifyInteractivity(el, html_el, listener_targets) != null) {
                is_interactive = true;
            }
        }
    } else if (node._type == .document or node._type == .document_fragment) {
        node_name = "root";
    }

    const initial_xpath_len = xpath_buffer.items.len;
    try appendXPathSegment(node, xpath_buffer.writer(self.arena), index);
    const xpath = xpath_buffer.items;

    var name = try axn.getName(self.page, self.arena);

    const has_explicit_label = if (node.is(Element)) |el|
        el.getAttributeSafe(.wrap("aria-label")) != null or el.getAttributeSafe(.wrap("title")) != null
    else
        false;

    const structural = isStructuralRole(role);

    // Filter out computed concatenated names for generic containers without explicit labels.
    // This prevents token bloat and ensures their StaticText children aren't incorrectly pruned.
    // We ignore interactivity because a generic wrapper with an event listener still shouldn't hoist all text.
    if (name != null and structural and !has_explicit_label) {
        name = null;
    }

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
        var tag_counts = std.StringArrayHashMap(usize).init(self.arena);
        while (it.next()) |child| {
            var tag: []const u8 = "text()";
            if (child.is(Element)) |el| {
                tag = el.getTagNameLower();
            }

            const gop = try tag_counts.getOrPut(tag);
            if (!gop.found_existing) {
                gop.value_ptr.* = 0;
            }
            gop.value_ptr.* += 1;

            try self.walk(child, xpath_buffer, name, visitor, gop.value_ptr.*, listener_targets);
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

fn appendXPathSegment(node: *Node, writer: anytype, index: usize) !void {
    if (node.is(Element)) |el| {
        const tag = el.getTagNameLower();
        try std.fmt.format(writer, "/{s}[{d}]", .{ tag, index });
    } else if (node.is(CData.Text) != null) {
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
        std.mem.eql(u8, role, "table") or
        std.mem.eql(u8, role, "rowgroup") or
        std.mem.eql(u8, role, "row") or
        std.mem.eql(u8, role, "cell") or
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
