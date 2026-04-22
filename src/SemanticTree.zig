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

const isAllWhitespace = @import("string.zig").isAllWhitespace;
const interactive = @import("browser/interactive.zig");

const CData = @import("browser/webapi/CData.zig");
const Element = @import("browser/webapi/Element.zig");
const Node = @import("browser/webapi/Node.zig");
const AXNode = @import("cdp/AXNode.zig");
const CDPNode = @import("cdp/Node.zig");

const log = lp.log;
const Frame = lp.Frame;

const Self = @This();

dom_node: *Node,
registry: *CDPNode.Registry,
frame: *Frame,
arena: std.mem.Allocator,
prune: bool = true,
interactive_only: bool = false,
max_depth: u32 = std.math.maxInt(u32) - 1,

pub fn jsonStringify(self: @This(), jw: *std.json.Stringify) error{WriteFailed}!void {
    var visitor = JsonVisitor{ .jw = jw, .tree = self };
    var xpath_buffer: std.ArrayList(u8) = .{};
    const listener_targets = interactive.buildListenerTargetMap(self.frame, self.arena) catch |err| {
        log.err(.app, "listener map failed", .{ .err = err });
        return error.WriteFailed;
    };
    var visibility_cache: Element.VisibilityCache = .empty;
    var pointer_events_cache: Element.PointerEventsCache = .empty;
    var ctx: WalkContext = .{
        .xpath_buffer = &xpath_buffer,
        .listener_targets = listener_targets,
        .visibility_cache = &visibility_cache,
        .pointer_events_cache = &pointer_events_cache,
    };
    self.walk(&ctx, self.dom_node, null, &visitor, 1, 0) catch |err| {
        log.err(.app, "semantic tree json dump failed", .{ .err = err });
        return error.WriteFailed;
    };
}

pub fn textStringify(self: @This(), writer: *std.Io.Writer) error{WriteFailed}!void {
    var visitor = TextVisitor{ .writer = writer, .tree = self, .depth = 0 };
    var xpath_buffer: std.ArrayList(u8) = .empty;
    const listener_targets = interactive.buildListenerTargetMap(self.frame, self.arena) catch |err| {
        log.err(.app, "listener map failed", .{ .err = err });
        return error.WriteFailed;
    };
    var visibility_cache: Element.VisibilityCache = .empty;
    var pointer_events_cache: Element.PointerEventsCache = .empty;
    var ctx: WalkContext = .{
        .xpath_buffer = &xpath_buffer,
        .listener_targets = listener_targets,
        .visibility_cache = &visibility_cache,
        .pointer_events_cache = &pointer_events_cache,
    };
    self.walk(&ctx, self.dom_node, null, &visitor, 1, 0) catch |err| {
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
    id: CDPNode.Id,
    axn: AXNode,
    role: []const u8,
    name: ?[]const u8,
    value: ?[]const u8,
    options: ?[]OptionData = null,
    checked: ?bool = null,
    xpath: []const u8,
    interactive: bool,
    disabled: bool,
    tag_name: []const u8,
};

const WalkContext = struct {
    xpath_buffer: *std.ArrayList(u8),
    listener_targets: interactive.ListenerTargetMap,
    visibility_cache: *Element.VisibilityCache,
    pointer_events_cache: *Element.PointerEventsCache,
};

fn walk(
    self: @This(),
    ctx: *WalkContext,
    node: *Node,
    parent_name: ?[]const u8,
    visitor: anytype,
    index: usize,
    current_depth: u32,
) !void {
    if (current_depth > self.max_depth) return;

    // 1. Skip non-content nodes
    if (node.is(Element)) |el| {
        const tag = el.getTag();
        if (tag.isMetadata() or tag == .svg) return;

        // We handle options/optgroups natively inside their parents, skip them in the general walk
        if (tag == .datalist or tag == .option or tag == .optgroup) return;

        // Check visibility using the engine's checkVisibility which handles CSS display: none
        if (!el.checkVisibilityCached(ctx.visibility_cache, self.frame)) {
            return;
        }

        if (el.is(Element.Html)) |html_el| {
            if (html_el.getHidden()) return;
        }
    } else if (node.is(CData.Text)) |text_node| {
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
    var is_disabled = false;
    var value: ?[]const u8 = null;
    var options: ?[]OptionData = null;
    var checked: ?bool = null;
    var tag_name: []const u8 = "text";

    if (node.is(Element)) |el| {
        tag_name = el.getTagNameLower();

        if (el.is(Element.Html.Input)) |input| {
            value = input.getValue();
            if (input._input_type == .checkbox or input._input_type == .radio) {
                checked = input.getChecked();
            }
            if (el.getAttributeSafe(comptime .wrap("list"))) |list_id| {
                options = try extractDataListOptions(list_id, self.frame, self.arena);
            }
        } else if (el.is(Element.Html.TextArea)) |textarea| {
            value = textarea.getValue();
        } else if (el.is(Element.Html.Select)) |select| {
            value = select.getValue(self.frame);
            options = try extractSelectOptions(el.asNode(), self.frame, self.arena);
        }

        if (el.is(Element.Html)) |html_el| {
            if (interactive.classifyInteractivity(self.frame, el, html_el, ctx.listener_targets, ctx.pointer_events_cache) != null) {
                is_interactive = true;
            }
        }

        is_disabled = el.isDisabled();
    } else if (node._type == .document or node._type == .document_fragment) {
        tag_name = "root";
    }

    const initial_xpath_len = ctx.xpath_buffer.items.len;
    try appendXPathSegment(node, ctx.xpath_buffer.writer(self.arena), index);
    const xpath = ctx.xpath_buffer.items;

    var name = try axn.getName(self.frame, self.arena);

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

    var should_visit = true;
    if (self.interactive_only) {
        var keep = false;
        if (interactive.isInteractiveRole(role)) {
            keep = true;
        } else if (interactive.isContentRole(role)) {
            if (name != null and name.?.len > 0) {
                keep = true;
            }
        } else if (std.mem.eql(u8, role, "RootWebArea")) {
            keep = true;
        } else if (is_interactive) {
            keep = true;
        }
        if (!keep) {
            should_visit = false;
        }
    } else if (self.prune) {
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
    var data: NodeData = .{
        .id = cdp_node.id,
        .axn = axn,
        .role = role,
        .name = name,
        .value = value,
        .options = options,
        .checked = checked,
        .xpath = xpath,
        .interactive = is_interactive,
        .disabled = is_disabled,
        .tag_name = tag_name,
    };

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

            try self.walk(ctx, child, name, visitor, gop.value_ptr.*, current_depth + 1);
        }
    }

    if (did_visit) {
        try visitor.leave();
    }

    ctx.xpath_buffer.shrinkRetainingCapacity(initial_xpath_len);
}

fn extractSelectOptions(node: *Node, frame: *Frame, arena: std.mem.Allocator) ![]OptionData {
    var options: std.ArrayList(OptionData) = .empty;
    var it = node.childrenIterator();
    while (it.next()) |child| {
        if (child.is(Element)) |el| {
            if (el.getTag() == .option) {
                if (el.is(Element.Html.Option)) |opt| {
                    const text = opt.getText(frame);
                    const value = opt.getValue(frame);
                    const selected = opt.getSelected();
                    try options.append(arena, .{ .text = text, .value = value, .selected = selected });
                }
            } else if (el.getTag() == .optgroup) {
                var group_it = child.childrenIterator();
                while (group_it.next()) |group_child| {
                    if (group_child.is(Element.Html.Option)) |opt| {
                        const text = opt.getText(frame);
                        const value = opt.getValue(frame);
                        const selected = opt.getSelected();
                        try options.append(arena, .{ .text = text, .value = value, .selected = selected });
                    }
                }
            }
        }
    }
    return options.toOwnedSlice(arena);
}

fn extractDataListOptions(list_id: []const u8, frame: *Frame, arena: std.mem.Allocator) !?[]OptionData {
    if (frame.document.getElementById(list_id, frame)) |referenced_el| {
        if (referenced_el.getTag() == .datalist) {
            return try extractSelectOptions(referenced_el.asNode(), frame, arena);
        }
    }
    return null;
}

fn appendXPathSegment(node: *Node, writer: anytype, index: usize) !void {
    if (node.is(Element)) |el| {
        const tag = el.getTagNameLower();
        try std.fmt.format(writer, "/{s}[{d}]", .{ tag, index });
    } else if (node.is(CData.Text)) |_| {
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
        try self.jw.write(data.tag_name);

        try self.jw.objectField("xpath");
        try self.jw.write(data.xpath);

        if (node.is(Element)) |el| {
            try self.jw.objectField("nodeType");
            try self.jw.write(1);

            try self.jw.objectField("isInteractive");
            try self.jw.write(data.interactive);

            if (data.disabled) {
                try self.jw.objectField("isDisabled");
                try self.jw.write(true);
            }

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

            if (data.checked) |checked| {
                try self.jw.objectField("checked");
                try self.jw.write(checked);
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
        } else if (node.is(CData.Text)) |text_node| {
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
    const structural_roles = std.StaticStringMap(void).initComptime(.{
        .{ "none", {} },
        .{ "generic", {} },
        .{ "InlineTextBox", {} },
        .{ "banner", {} },
        .{ "navigation", {} },
        .{ "main", {} },
        .{ "list", {} },
        .{ "listitem", {} },
        .{ "table", {} },
        .{ "rowgroup", {} },
        .{ "row", {} },
        .{ "cell", {} },
        .{ "region", {} },
    });
    return structural_roles.has(role);
}

const TextVisitor = struct {
    writer: *std.Io.Writer,
    tree: Self,
    depth: usize,

    pub fn visit(self: *TextVisitor, node: *Node, data: *NodeData) !bool {
        for (0..self.depth) |_| {
            try self.writer.writeByte(' ');
        }

        var name_to_print: ?[]const u8 = null;
        if (data.name) |n| {
            if (n.len > 0) {
                name_to_print = n;
            }
        } else if (node.is(CData.Text)) |text_node| {
            const trimmed = std.mem.trim(u8, text_node.getWholeText(), " \t\r\n");
            if (trimmed.len > 0) {
                name_to_print = trimmed;
            }
        }

        const is_text_only = std.mem.eql(u8, data.role, "StaticText") or std.mem.eql(u8, data.role, "none") or std.mem.eql(u8, data.role, "generic");

        try self.writer.print("{d}", .{data.id});
        if (data.interactive) {
            try self.writer.writeAll(if (data.disabled) " [i:disabled]" else " [i]");
        }
        if (!is_text_only) {
            try self.writer.print(" {s}", .{data.role});
        }
        if (name_to_print) |n| {
            try self.writer.print(" '{s}'", .{n});
        }

        if (data.value) |v| {
            if (v.len > 0) {
                try self.writer.print(" value='{s}'", .{v});
            }
        }

        if (data.checked) |c| {
            if (c) {
                try self.writer.writeAll(" [checked]");
            } else {
                try self.writer.writeAll(" [unchecked]");
            }
        }

        if (data.options) |options| {
            try self.writer.writeAll(" options=[");
            for (options, 0..) |opt, i| {
                if (i > 0) try self.writer.writeAll(",");
                try self.writer.print("'{s}'", .{opt.value});
                if (opt.selected) {
                    try self.writer.writeAll("*");
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

pub const NodeDetails = struct {
    backendNodeId: CDPNode.Id,
    tag_name: []const u8,
    role: []const u8,
    name: ?[]const u8,
    interactive: bool,
    disabled: bool,
    value: ?[]const u8 = null,
    input_type: ?[]const u8 = null,
    placeholder: ?[]const u8 = null,
    href: ?[]const u8 = null,
    id: ?[]const u8 = null,
    class: ?[]const u8 = null,
    checked: ?bool = null,
    options: ?[]OptionData = null,

    pub fn jsonStringify(self: *const NodeDetails, jw: anytype) !void {
        try jw.beginObject();

        try jw.objectField("backendNodeId");
        try jw.write(self.backendNodeId);

        try jw.objectField("tagName");
        try jw.write(self.tag_name);

        try jw.objectField("role");
        try jw.write(self.role);

        if (self.name) |n| {
            try jw.objectField("name");
            try jw.write(n);
        }

        try jw.objectField("isInteractive");
        try jw.write(self.interactive);

        if (self.disabled) {
            try jw.objectField("isDisabled");
            try jw.write(true);
        }

        if (self.value) |v| {
            try jw.objectField("value");
            try jw.write(v);
        }

        if (self.input_type) |v| {
            try jw.objectField("inputType");
            try jw.write(v);
        }

        if (self.placeholder) |v| {
            try jw.objectField("placeholder");
            try jw.write(v);
        }

        if (self.href) |v| {
            try jw.objectField("href");
            try jw.write(v);
        }

        if (self.id) |v| {
            try jw.objectField("id");
            try jw.write(v);
        }

        if (self.class) |v| {
            try jw.objectField("class");
            try jw.write(v);
        }

        if (self.checked) |c| {
            try jw.objectField("checked");
            try jw.write(c);
        }

        if (self.options) |opts| {
            try jw.objectField("options");
            try jw.beginArray();
            for (opts) |opt| {
                try jw.beginObject();
                try jw.objectField("value");
                try jw.write(opt.value);
                try jw.objectField("text");
                try jw.write(opt.text);
                if (opt.selected) {
                    try jw.objectField("selected");
                    try jw.write(true);
                }
                try jw.endObject();
            }
            try jw.endArray();
        }

        try jw.endObject();
    }
};

pub fn getNodeDetails(
    arena: std.mem.Allocator,
    node: *Node,
    registry: *CDPNode.Registry,
    frame: *Frame,
) !NodeDetails {
    const cdp_node = try registry.register(node);
    const axn = AXNode.fromNode(node);
    const role = try axn.getRole();
    const name = try axn.getName(frame, arena);

    var is_interactive = false;
    var is_disabled = false;
    var tag_name: []const u8 = "text";
    var value: ?[]const u8 = null;
    var input_type: ?[]const u8 = null;
    var placeholder: ?[]const u8 = null;
    var href: ?[]const u8 = null;
    var id_attr: ?[]const u8 = null;
    var class_attr: ?[]const u8 = null;
    var checked: ?bool = null;
    var options: ?[]OptionData = null;

    if (node.is(Element)) |el| {
        tag_name = el.getTagNameLower();
        is_disabled = el.isDisabled();
        id_attr = el.getAttributeSafe(comptime .wrap("id"));
        class_attr = el.getAttributeSafe(comptime .wrap("class"));
        placeholder = el.getAttributeSafe(comptime .wrap("placeholder"));

        if (el.getAttributeSafe(comptime .wrap("href"))) |h| {
            const URL = lp.URL;
            href = URL.resolve(arena, frame.base(), h, .{ .encoding = frame.charset }) catch h;
        }

        if (el.is(Element.Html.Input)) |input| {
            value = input.getValue();
            input_type = input._input_type.toString();
            if (input._input_type == .checkbox or input._input_type == .radio) {
                checked = input.getChecked();
            }
            if (el.getAttributeSafe(comptime .wrap("list"))) |list_id| {
                options = try extractDataListOptions(list_id, frame, arena);
            }
        } else if (el.is(Element.Html.TextArea)) |textarea| {
            value = textarea.getValue();
        } else if (el.is(Element.Html.Select)) |select| {
            value = select.getValue(frame);
            options = try extractSelectOptions(el.asNode(), frame, arena);
        }

        if (el.is(Element.Html)) |html_el| {
            const listener_targets = try interactive.buildListenerTargetMap(frame, arena);
            var pointer_events_cache: Element.PointerEventsCache = .empty;
            if (interactive.classifyInteractivity(frame, el, html_el, listener_targets, &pointer_events_cache) != null) {
                is_interactive = true;
            }
        }
    }

    return .{
        .backendNodeId = cdp_node.id,
        .tag_name = tag_name,
        .role = role,
        .name = name,
        .interactive = is_interactive,
        .disabled = is_disabled,
        .value = value,
        .input_type = input_type,
        .placeholder = placeholder,
        .href = href,
        .id = id_attr,
        .class = class_attr,
        .checked = checked,
        .options = options,
    };
}

const testing = @import("testing.zig");

test "SemanticTree backendDOMNodeId" {
    var registry: CDPNode.Registry = .init(testing.allocator);
    defer registry.deinit();

    var frame = try testing.pageTest("cdp/registry1.html", .{});
    defer testing.reset();
    defer frame._session.removePage();

    const st: Self = .{
        .dom_node = frame.window._document.asNode(),
        .registry = &registry,
        .frame = frame,
        .arena = testing.arena_allocator,
        .prune = false,
        .interactive_only = false,
        .max_depth = std.math.maxInt(u32) - 1,
    };

    const json_str = try std.json.Stringify.valueAlloc(testing.allocator, st, .{});
    defer testing.allocator.free(json_str);

    try testing.expect(std.mem.indexOf(u8, json_str, "\"backendDOMNodeId\":") != null);
}

test "SemanticTree max_depth" {
    var registry: CDPNode.Registry = .init(testing.allocator);
    defer registry.deinit();

    var frame = try testing.pageTest("cdp/registry1.html", .{});
    defer testing.reset();
    defer frame._session.removePage();

    const st: Self = .{
        .dom_node = frame.window._document.asNode(),
        .registry = &registry,
        .frame = frame,
        .arena = testing.arena_allocator,
        .prune = false,
        .interactive_only = false,
        .max_depth = 1,
    };

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    try st.textStringify(&aw.writer);
    const text_str = aw.written();

    try testing.expect(std.mem.indexOf(u8, text_str, "other") == null);
}
