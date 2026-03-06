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
    self.dump(self.dom_node, jw, "") catch |err| {
        log.err(.cdp, "semantic tree dump failed", .{ .err = err });
        return error.WriteFailed;
    };
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

fn dump(self: Self, node: *Node, jw: *std.json.Stringify, parent_xpath: []const u8) !void {
    // 1. Skip non-content nodes
    if (node.is(Element)) |el| {
        switch (el.getTag()) {
            .script, .style, .meta, .link, .noscript, .svg, .head, .title => return,
            else => {},
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

    const cdp_node = try self.registry.register(node);
    const axn = AXNode.fromNode(node);

    const role = try axn.getRole();

    var is_interactive = false;
    var node_name: []const u8 = "text";

    if (node.is(Element)) |el| {
        node_name = el.getTagNameLower();

        const ax_role = std.meta.stringToEnum(AXNode.AXRole, role) orelse .none;
        if (ax_role.isInteractive()) {
            is_interactive = true;
        }

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
    } else if (node._type == .document or node._type == .document_fragment) {
        node_name = "root";
    }

    const segment = try self.getXPathSegment(node);
    const xpath = try std.mem.concat(self.arena, u8, &.{ parent_xpath, segment });

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
        try self.dump(child, jw, xpath);
    }
    try jw.endArray();

    try jw.endObject();
}
