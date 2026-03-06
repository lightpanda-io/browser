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
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

const std = @import("std");

const lp = @import("lightpanda");
const Page = lp.Page;

const CData = @import("../browser/webapi/CData.zig");
const Element = @import("../browser/webapi/Element.zig");
const Node = @import("../browser/webapi/Node.zig");
const AXNode = @import("AXNode.zig");
const CDPNode = @import("Node.zig");

pub fn dump(root: *Node, registry: *CDPNode.Registry, jw: *std.json.Stringify, page: *Page, arena: std.mem.Allocator) !void {
    try dumpNode(root, registry, jw, page, "", arena);
}

fn isAllWhitespace(text: []const u8) bool {
    for (text) |c| {
        if (!std.ascii.isWhitespace(c)) return false;
    }
    return true;
}

fn getXPathSegment(node: *Node, arena: std.mem.Allocator) ![]const u8 {
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
        return std.fmt.allocPrint(arena, "/{s}[{d}]", .{ tag, index });
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
        return std.fmt.allocPrint(arena, "/text()[{d}]", .{index});
    }
    return "";
}

fn dumpNode(node: *Node, registry: *CDPNode.Registry, jw: *std.json.Stringify, page: *Page, parent_xpath: []const u8, arena: std.mem.Allocator) !void {
    // 1. Skip non-content nodes
    if (node.is(Element)) |el| {
        const tag = el.getTagNameLower();
        if (std.mem.eql(u8, tag, "script") or
            std.mem.eql(u8, tag, "style") or
            std.mem.eql(u8, tag, "meta") or
            std.mem.eql(u8, tag, "link") or
            std.mem.eql(u8, tag, "noscript") or
            std.mem.eql(u8, tag, "svg") or
            std.mem.eql(u8, tag, "head") or
            std.mem.eql(u8, tag, "title"))
        {
            return;
        }

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

    const cdp_node = try registry.register(node);
    const axn = AXNode.fromNode(node);

    const role = try axn.getRole();

    var is_interactive = false;
    var node_name: []const u8 = "text";

    if (node.is(Element)) |el| {
        node_name = el.getTagNameLower();

        if (std.mem.eql(u8, role, "button") or
            std.mem.eql(u8, role, "link") or
            std.mem.eql(u8, role, "checkbox") or
            std.mem.eql(u8, role, "radio") or
            std.mem.eql(u8, role, "textbox") or
            std.mem.eql(u8, role, "combobox") or
            std.mem.eql(u8, role, "searchbox") or
            std.mem.eql(u8, role, "slider") or
            std.mem.eql(u8, role, "spinbutton") or
            std.mem.eql(u8, role, "switch") or
            std.mem.eql(u8, role, "menuitem"))
        {
            is_interactive = true;
        }

        const event_target = node.asEventTarget();
        if (page._event_manager.hasListener(event_target, "click") or
            page._event_manager.hasListener(event_target, "mousedown") or
            page._event_manager.hasListener(event_target, "mouseup") or
            page._event_manager.hasListener(event_target, "keydown") or
            page._event_manager.hasListener(event_target, "change") or
            page._event_manager.hasListener(event_target, "input"))
        {
            is_interactive = true;
        }

        if (el.is(Element.Html)) |html_el| {
            if (html_el.hasAttributeFunction(.onclick, page) or
                html_el.hasAttributeFunction(.onmousedown, page) or
                html_el.hasAttributeFunction(.onmouseup, page) or
                html_el.hasAttributeFunction(.onkeydown, page) or
                html_el.hasAttributeFunction(.onchange, page) or
                html_el.hasAttributeFunction(.oninput, page))
            {
                is_interactive = true;
            }
        }
    } else if (node._type == .document or node._type == .document_fragment) {
        node_name = "root";
    }

    const segment = try getXPathSegment(node, arena);
    const xpath = try std.mem.concat(arena, u8, &.{ parent_xpath, segment });

    try jw.beginObject();

    try jw.objectField("nodeId");
    try jw.write(cdp_node.id);

    try jw.objectField("backendNodeId");
    try jw.write(cdp_node.id);

    try jw.objectField("nodeName");
    try jw.write(node_name);

    try jw.objectField("xpath");
    try jw.write(xpath);

    if (node.is(Element)) |el| {
        try jw.objectField("nodeType");
        try jw.write(1);

        try jw.objectField("isInteractive");
        try jw.write(is_interactive);

        try jw.objectField("role");
        try jw.write(role);

        if (el._attributes) |attrs| {
            try jw.objectField("attributes");
            try jw.beginObject();
            var iter = attrs.iterator();
            while (iter.next()) |attr| {
                try jw.objectField(attr._name.str());
                try jw.write(attr._value.str());
            }
            try jw.endObject();
        }
    } else if (node.is(CData.Text) != null) {
        const text_node = node.is(CData.Text).?;
        try jw.objectField("nodeType");
        try jw.write(3);
        try jw.objectField("nodeValue");
        try jw.write(text_node.getWholeText());
    } else {
        try jw.objectField("nodeType");
        try jw.write(9);
    }

    try jw.objectField("children");
    try jw.beginArray();
    var it = node.childrenIterator();
    while (it.next()) |child| {
        try dumpNode(child, registry, jw, page, xpath, arena);
    }
    try jw.endArray();

    try jw.endObject();
}
