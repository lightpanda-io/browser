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

const Frame = @import("../browser/Frame.zig");
const DOMNode = @import("../browser/webapi/Node.zig");
const Label = @import("../browser/webapi/element/html/Label.zig");

const Node = @import("Node.zig");

const log = lp.log;
const jsonStringify = std.json.Stringify;

const AXNode = @This();

// Max bytes retained in the name-resolution scratch arena across resets.
// Anything beyond is freed back to the backing allocator.
const scratch_retain_limit = 64 * 1024;

// Need a custom writer, because we can't just serialize the node as-is.
// Sometimes we want to serializ the node without children, sometimes with just
// its direct children, and sometimes the entire tree.
// (For now, we only support direct children)
pub const Writer = struct {
    root: *const Node,
    registry: *Node.Registry,
    frame: *Frame,
    visibility_cache: *DOMNode.Element.VisibilityCache,
    label_index: *Label.LabelByForIndex,
    temp_arena: std.mem.Allocator,

    pub const Opts = struct {};

    pub fn jsonStringify(self: *const Writer, w: anytype) error{WriteFailed}!void {
        self.toJSON(self.root, w) catch |err| {
            // The only error our jsonStringify method can return is
            // @TypeOf(w).Error. In other words, our code can't return its own
            // error, we can only return a writer error. Kinda sucks.
            log.err(.cdp, "node toJSON stringify", .{ .err = err });
            return error.WriteFailed;
        };
    }

    fn toJSON(self: *const Writer, node: *const Node, w: anytype) !void {
        try w.beginArray();
        const root = AXNode.fromNode(node.dom);
        if (try self.writeNode(node.id, root, false, w)) {
            try self.writeNodeChildren(root, false, w);
        }
        return w.endArray();
    }

    // CDP spec defines AXNodeId as a string, so nodeId/parentId/childIds must
    // be serialized as JSON strings even though we track them internally as u32.
    fn writeIdString(id: u32, w: anytype) !void {
        var buf: [10]u8 = undefined;
        const s = try std.fmt.bufPrint(&buf, "{d}", .{id});
        try w.write(s);
    }

    fn writeNodeChildren(self: *const Writer, parent: AXNode, in_aria_hidden: bool, w: anytype) !void {
        // Add ListMarker for listitem elements
        if (parent.dom.is(DOMNode.Element)) |parent_el| {
            if (parent_el.getTag() == .li) {
                try self.writeListMarker(parent.dom, w);
            }
        }

        const child_in_aria_hidden = in_aria_hidden or blk: {
            const parent_el = parent.dom.is(DOMNode.Element) orelse break :blk false;
            break :blk hasAriaHiddenTrue(parent_el);
        };

        var it = parent.dom.childrenIterator();
        const ignore_text = ignoreText(parent.dom);
        while (it.next()) |dom_node| {
            switch (dom_node._type) {
                .cdata => {
                    if (dom_node.is(DOMNode.CData.Text) == null) {
                        continue;
                    }
                    if (ignore_text) {
                        continue;
                    }
                },
                .element => {
                    // Prune hidden subtrees entirely (display:none,
                    // visibility:hidden, aria-hidden, hidden, inert). Matches
                    // Chromium: these elements aren't exposed to the AX tree.
                    const child_el = dom_node.as(DOMNode.Element);
                    if (child_in_aria_hidden or isHidden(child_el, self.frame, self.visibility_cache)) {
                        continue;
                    }
                },
                else => continue,
            }

            const node = try self.registry.register(dom_node);
            const axn = AXNode.fromNode(node.dom);
            if (try self.writeNode(node.id, axn, child_in_aria_hidden, w)) {
                try self.writeNodeChildren(axn, child_in_aria_hidden, w);
            }
        }
    }

    fn writeListMarker(self: *const Writer, li_node: *DOMNode, w: anytype) !void {
        // Find the parent list element
        const parent = li_node._parent orelse return;
        const parent_el = parent.is(DOMNode.Element) orelse return;
        const list_type = parent_el.getTag();

        // Only create markers for actual list elements
        switch (list_type) {
            .ul, .ol, .menu => {},
            else => return,
        }

        // Write the ListMarker node
        try w.beginObject();

        // Use the next available ID for the marker
        try w.objectField("nodeId");
        const marker_id = self.registry.node_id;
        self.registry.node_id += 1;
        try writeIdString(marker_id, w);

        try w.objectField("backendDOMNodeId");
        try w.write(marker_id);

        try w.objectField("role");
        try self.writeAXValue(.{ .role = "ListMarker" }, w);

        try w.objectField("ignored");
        try w.write(false);

        try w.objectField("name");
        try w.beginObject();
        try w.objectField("type");
        try w.write("computedString");
        try w.objectField("value");

        // Write marker text directly based on list type
        switch (list_type) {
            .ul, .menu => try w.write("• "),
            .ol => {
                // Calculate the list item number by counting preceding li siblings
                var count: usize = 1;
                var it = parent.childrenIterator();
                while (it.next()) |child| {
                    if (child == li_node) break;
                    if (child.is(DOMNode.Element.Html) == null) continue;
                    const child_el = child.as(DOMNode.Element);
                    if (child_el.getTag() == .li) count += 1;
                }

                // Sanity check: lists with >9999 items are unrealistic
                if (count > 9999) return error.ListTooLong;

                // Use a small stack buffer to format the number (max "9999. " = 6 chars)
                var buf: [6]u8 = undefined;
                const marker_text = try std.fmt.bufPrint(&buf, "{d}. ", .{count});
                try w.write(marker_text);
            },
            else => unreachable,
        }

        try w.objectField("sources");
        try w.beginArray();
        try w.beginObject();
        try w.objectField("type");
        try w.write("contents");
        try w.endObject();
        try w.endArray();
        try w.endObject();

        try w.objectField("properties");
        try w.beginArray();
        try w.endArray();

        // Get the parent node ID for the parentId field
        const li_registered = try self.registry.register(li_node);
        try w.objectField("parentId");
        try writeIdString(li_registered.id, w);

        try w.objectField("childIds");
        try w.beginArray();
        try w.endArray();

        try w.endObject();
    }

    const AXValue = union(enum) {
        role: []const u8,
        string: []const u8,
        computedString: []const u8,
        integer: usize,
        boolean: bool,
        booleanOrUndefined: bool,
        token: []const u8,
        // TODO not implemented:
        // tristate, idrefList, node, nodeList, number, tokenList,
        // domRelation, internalRole, valueUndefined,
    };

    fn writeAXSource(_: *const Writer, source: AXSource, w: anytype) !void {
        try w.objectField("sources");
        try w.beginArray();
        try w.beginObject();

        // attribute, implicit, style, contents, placeholder, relatedElement
        const source_type = switch (source) {
            .aria_labelledby => blk: {
                try w.objectField("attribute");
                try w.write(@tagName(source));
                break :blk "relatedElement";
            },
            .aria_label, .alt, .title, .placeholder, .value => blk: {
                // Not sure if it's correct for .value case.
                try w.objectField("attribute");
                try w.write(@tagName(source));
                break :blk "attribute";
            },
            // Chrome sends the content AXValue *again* in the source.
            // But It seems useless to me.
            //
            // w.objectField("value");
            // self.writeAXValue(.{ .type = .computedString, .value = value.value }, w);
            .contents => "contents",
            .label_element => blk: {
                try w.objectField("attribute");
                try w.write("for");
                break :blk "relatedElement";
            },
            .label_wrap => "relatedElement",
        };
        try w.objectField("type");
        try w.write(source_type);

        try w.endObject();
        try w.endArray();
    }

    fn writeAXValue(_: *const Writer, value: AXValue, w: anytype) !void {
        try w.beginObject();
        try w.objectField("type");
        try w.write(@tagName(std.meta.activeTag(value)));

        try w.objectField("value");
        switch (value) {
            .integer => |v| {
                // CDP spec requires integer values to be serialized as strings.
                // 20 bytes is enough for the decimal representation of a 64-bit integer.
                var buf: [20]u8 = undefined;
                const s = try std.fmt.bufPrint(&buf, "{d}", .{v});
                try w.write(s);
            },
            inline else => |v| try w.write(v),
        }

        try w.endObject();
    }

    const AXProperty = struct {
        // zig fmt: off
        name: enum(u8) {
            actions, busy, disabled, editable, focusable, focused, hidden,
            hiddenRoot, invalid, keyshortcuts, settable, roledescription, live,
            atomic, relevant, root, autocomplete, hasPopup, level,
            multiselectable, orientation, multiline, readonly, required,
            valuemin, valuemax, valuetext, checked, expanded, modal, pressed,
            selected, activedescendant, controls, describedby, details,
            errormessage, flowto, labelledby, owns, url,
            activeFullscreenElement, activeModalDialog, activeAriaModalDialog,
            ariaHiddenElement, ariaHiddenSubtree, emptyAlt, emptyText,
            inertElement, inertSubtree, labelContainer, labelFor, notRendered,
            notVisible, presentationalRole, probablyPresentational,
            inactiveCarouselTabContent, uninteresting,
        },
        // zig fmt: on
        value: AXValue,
    };

    fn writeAXProperties(self: *const Writer, axnode: AXNode, w: anytype) !void {
        const frame = self.frame;
        const dom_node = axnode.dom;

        switch (dom_node._type) {
            .document => |document| {
                const uri = document.getURL(frame);
                try self.writeAXProperty(.{ .name = .url, .value = .{ .string = uri } }, w);
                try self.writeAXProperty(.{ .name = .focusable, .value = .{ .booleanOrUndefined = true } }, w);
                try self.writeAXProperty(.{ .name = .focused, .value = .{ .booleanOrUndefined = true } }, w);
                return;
            },
            .cdata => return,
            .element => |el| switch (el.getTag()) {
                .h1 => try self.writeAXProperty(.{ .name = .level, .value = .{ .integer = 1 } }, w),
                .h2 => try self.writeAXProperty(.{ .name = .level, .value = .{ .integer = 2 } }, w),
                .h3 => try self.writeAXProperty(.{ .name = .level, .value = .{ .integer = 3 } }, w),
                .h4 => try self.writeAXProperty(.{ .name = .level, .value = .{ .integer = 4 } }, w),
                .h5 => try self.writeAXProperty(.{ .name = .level, .value = .{ .integer = 5 } }, w),
                .h6 => try self.writeAXProperty(.{ .name = .level, .value = .{ .integer = 6 } }, w),
                .img => {
                    const img = el.as(DOMNode.Element.Html.Image);
                    const uri = try img.getSrc(self.frame);
                    if (uri.len == 0) return;
                    try self.writeAXProperty(.{ .name = .url, .value = .{ .string = uri } }, w);
                },
                .anchor => {
                    const a = el.as(DOMNode.Element.Html.Anchor);
                    const uri = try a.getHref(self.frame);
                    if (uri.len == 0) return;
                    try self.writeAXProperty(.{ .name = .url, .value = .{ .string = uri } }, w);
                    try self.writeAXProperty(.{ .name = .focusable, .value = .{ .booleanOrUndefined = true } }, w);
                },
                .input => {
                    const input = el.as(DOMNode.Element.Html.Input);
                    const is_disabled = el.isDisabled();

                    switch (input._input_type) {
                        .text, .email, .tel, .url, .search, .password, .number => {
                            if (is_disabled) {
                                try self.writeAXProperty(.{ .name = .disabled, .value = .{ .boolean = true } }, w);
                            }
                            try self.writeAXProperty(.{ .name = .invalid, .value = .{ .token = "false" } }, w);
                            if (!is_disabled) {
                                try self.writeAXProperty(.{ .name = .focusable, .value = .{ .booleanOrUndefined = true } }, w);
                            }
                            try self.writeAXProperty(.{ .name = .editable, .value = .{ .token = "plaintext" } }, w);
                            if (!is_disabled) {
                                try self.writeAXProperty(.{ .name = .settable, .value = .{ .booleanOrUndefined = true } }, w);
                            }
                            try self.writeAXProperty(.{ .name = .multiline, .value = .{ .boolean = false } }, w);
                            try self.writeAXProperty(.{ .name = .readonly, .value = .{ .boolean = el.hasAttributeSafe(comptime .wrap("readonly")) } }, w);
                            try self.writeAXProperty(.{ .name = .required, .value = .{ .boolean = el.hasAttributeSafe(comptime .wrap("required")) } }, w);
                        },
                        .button, .submit, .reset, .image => {
                            try self.writeAXProperty(.{ .name = .invalid, .value = .{ .token = "false" } }, w);
                            if (!is_disabled) {
                                try self.writeAXProperty(.{ .name = .focusable, .value = .{ .booleanOrUndefined = true } }, w);
                            }
                        },
                        .checkbox, .radio => {
                            try self.writeAXProperty(.{ .name = .invalid, .value = .{ .token = "false" } }, w);
                            if (!is_disabled) {
                                try self.writeAXProperty(.{ .name = .focusable, .value = .{ .booleanOrUndefined = true } }, w);
                            }
                            const is_checked = el.hasAttributeSafe(comptime .wrap("checked"));
                            try self.writeAXProperty(.{ .name = .checked, .value = .{ .token = if (is_checked) "true" else "false" } }, w);
                        },
                        else => {},
                    }
                },
                .textarea => {
                    const is_disabled = el.isDisabled();

                    try self.writeAXProperty(.{ .name = .invalid, .value = .{ .token = "false" } }, w);
                    if (!is_disabled) {
                        try self.writeAXProperty(.{ .name = .focusable, .value = .{ .booleanOrUndefined = true } }, w);
                    }
                    try self.writeAXProperty(.{ .name = .editable, .value = .{ .token = "plaintext" } }, w);
                    if (!is_disabled) {
                        try self.writeAXProperty(.{ .name = .settable, .value = .{ .booleanOrUndefined = true } }, w);
                    }
                    try self.writeAXProperty(.{ .name = .multiline, .value = .{ .boolean = true } }, w);
                    try self.writeAXProperty(.{ .name = .readonly, .value = .{ .boolean = el.hasAttributeSafe(comptime .wrap("readonly")) } }, w);
                    try self.writeAXProperty(.{ .name = .required, .value = .{ .boolean = el.hasAttributeSafe(comptime .wrap("required")) } }, w);
                },
                .select => {
                    const is_disabled = el.isDisabled();

                    try self.writeAXProperty(.{ .name = .invalid, .value = .{ .token = "false" } }, w);
                    if (!is_disabled) {
                        try self.writeAXProperty(.{ .name = .focusable, .value = .{ .booleanOrUndefined = true } }, w);
                    }
                    try self.writeAXProperty(.{ .name = .hasPopup, .value = .{ .token = "menu" } }, w);
                    try self.writeAXProperty(.{ .name = .expanded, .value = .{ .booleanOrUndefined = false } }, w);
                },
                .option => {
                    const option = el.as(DOMNode.Element.Html.Option);
                    try self.writeAXProperty(.{ .name = .focusable, .value = .{ .booleanOrUndefined = true } }, w);

                    // Check if this option is selected by examining the parent select
                    const is_selected = blk: {
                        // First check if explicitly selected
                        if (option.getSelected()) break :blk true;

                        // Check if implicitly selected (first enabled option in select with no explicit selection)
                        const parent = dom_node._parent orelse break :blk false;
                        const parent_el = parent.as(DOMNode.Element);
                        if (parent_el.getTag() != .select) break :blk false;

                        const select = parent_el.as(DOMNode.Element.Html.Select);
                        const selected_idx = select.getSelectedIndex();

                        // Find this option's index
                        var idx: i32 = 0;
                        var it = parent.childrenIterator();
                        while (it.next()) |child| {
                            if (child.is(DOMNode.Element.Html.Option) == null) continue;
                            if (child == dom_node) {
                                break :blk idx == selected_idx;
                            }
                            idx += 1;
                        }
                        break :blk false;
                    };

                    if (is_selected) {
                        try self.writeAXProperty(.{ .name = .selected, .value = .{ .booleanOrUndefined = true } }, w);
                    }
                },
                .button => {
                    const is_disabled = el.isDisabled();
                    try self.writeAXProperty(.{ .name = .invalid, .value = .{ .token = "false" } }, w);
                    if (!is_disabled) {
                        try self.writeAXProperty(.{ .name = .focusable, .value = .{ .booleanOrUndefined = true } }, w);
                    }
                },
                .hr => {
                    try self.writeAXProperty(.{ .name = .settable, .value = .{ .booleanOrUndefined = true } }, w);
                    try self.writeAXProperty(.{ .name = .orientation, .value = .{ .token = "horizontal" } }, w);
                },
                .li => {
                    // Calculate level by counting list ancestors (ul, ol, menu)
                    var level: usize = 0;
                    var current = dom_node._parent;
                    while (current) |node| {
                        if (node.is(DOMNode.Element) == null) {
                            current = node._parent;
                            continue;
                        }
                        const current_el = node.as(DOMNode.Element);
                        switch (current_el.getTag()) {
                            .ul, .ol, .menu => level += 1,
                            else => {},
                        }
                        current = node._parent;
                    }
                    try self.writeAXProperty(.{ .name = .level, .value = .{ .integer = level } }, w);
                },
                else => {},
            },
            else => |tag| {
                log.debug(.cdp, "invalid tag", .{ .tag = tag });
                return error.InvalidTag;
            },
        }
    }

    fn writeAXProperty(self: *const Writer, value: AXProperty, w: anytype) !void {
        try w.beginObject();
        try w.objectField("name");
        try w.write(@tagName(value.name));
        try w.objectField("value");
        try self.writeAXValue(value.value, w);
        try w.endObject();
    }

    // write a node. returns true if children must be written.
    fn writeNode(self: *const Writer, id: u32, axn: AXNode, in_aria_hidden: bool, w: anytype) !bool {
        // ignore empty texts
        try w.beginObject();

        try w.objectField("nodeId");
        try writeIdString(id, w);

        try w.objectField("backendDOMNodeId");
        try w.write(id);

        const promoted_input = labelPromotionTarget(axn, self.frame, self.visibility_cache);

        try w.objectField("role");
        if (promoted_input) |input| {
            try self.writeAXValue(.{ .role = switch (input._input_type) {
                .checkbox => "checkbox",
                .radio => "radio",
                else => unreachable,
            } }, w);
        } else {
            try self.writeAXValue(.{ .role = try axn.getRole() }, w);
        }

        const ignore = axn.isIgnore(self.frame, self.visibility_cache, in_aria_hidden);
        try w.objectField("ignored");
        try w.write(ignore);

        if (ignore) {
            // Ignore reasons
            try w.objectField("ignoredReasons");
            try w.beginArray();
            try w.beginObject();
            try w.objectField("name");
            try w.write("uninteresting");
            try w.objectField("value");
            try self.writeAXValue(.{ .boolean = true }, w);
            try w.endObject();
            try w.endArray();
        } else {
            // Name
            try w.objectField("name");
            try w.beginObject();
            try w.objectField("type");
            try w.write(@tagName(.computedString));
            try w.objectField("value");
            const source = try axn.writeName(self.temp_arena, w, self.frame, self.label_index);
            if (source) |s| {
                try self.writeAXSource(s, w);
            }
            try w.endObject();

            // Value (for form controls)
            try self.writeNodeValue(axn, w);

            // Properties
            try w.objectField("properties");
            try w.beginArray();
            try self.writeAXProperties(axn, w);
            if (promoted_input) |input| {
                const input_el = input.asElement();
                const is_disabled = input_el.isDisabled();
                if (is_disabled) {
                    try self.writeAXProperty(.{ .name = .disabled, .value = .{ .boolean = true } }, w);
                }
                try self.writeAXProperty(.{ .name = .invalid, .value = .{ .token = "false" } }, w);
                if (!is_disabled) {
                    try self.writeAXProperty(.{ .name = .focusable, .value = .{ .booleanOrUndefined = true } }, w);
                }
                try self.writeAXProperty(.{ .name = .checked, .value = .{ .token = if (input._checked) "true" else "false" } }, w);
            }
            try w.endArray();
        }

        const n = axn.dom;

        // Parent
        if (n._parent) |p| {
            const parent_node = try self.registry.register(p);
            try w.objectField("parentId");
            try writeIdString(parent_node.id, w);
        }

        // Children
        const write_children = axn.ignoreChildren() == false;
        const skip_text = ignoreText(axn.dom);

        const child_in_aria_hidden = in_aria_hidden or blk: {
            const self_el = n.is(DOMNode.Element) orelse break :blk false;
            break :blk hasAriaHiddenTrue(self_el);
        };

        try w.objectField("childIds");
        try w.beginArray();
        if (write_children) {
            var registry = self.registry;
            var it = n.childrenIterator();
            while (it.next()) |child| {
                // ignore non-elements or text.
                if (child.is(DOMNode.Element.Html) == null and (child.is(DOMNode.CData.Text) == null or skip_text)) {
                    continue;
                }

                // Skip hidden element children so childIds matches the
                // subtree-pruning done in writeNodeChildren.
                if (child.is(DOMNode.Element)) |child_el| {
                    if (child_in_aria_hidden or isHidden(child_el, self.frame, self.visibility_cache)) {
                        continue;
                    }
                }

                const child_node = try registry.register(child);
                try writeIdString(child_node.id, w);
            }
        }
        try w.endArray();

        try w.endObject();

        return write_children;
    }

    fn writeNodeValue(self: *const Writer, axnode: AXNode, w: anytype) !void {
        const node = axnode.dom;

        if (node.is(DOMNode.Element.Html) == null) {
            return;
        }

        const el = node.as(DOMNode.Element);

        const value: ?[]const u8 = switch (el.getTag()) {
            .input => blk: {
                const input = el.as(DOMNode.Element.Html.Input);
                const val = input.getValue();
                if (val.len == 0) break :blk null;
                break :blk val;
            },
            .textarea => blk: {
                const textarea = el.as(DOMNode.Element.Html.TextArea);
                const val = textarea.getValue();
                if (val.len == 0) break :blk null;
                break :blk val;
            },
            .select => blk: {
                const select = el.as(DOMNode.Element.Html.Select);
                const val = select.getValue(self.frame);
                if (val.len == 0) break :blk null;
                break :blk val;
            },
            else => null,
        };

        if (value) |val| {
            try w.objectField("value");
            try self.writeAXValue(.{ .string = val }, w);
        }
    }
};

pub const AXRole = enum(u8) {
    // zig fmt: off
    none, article, banner, blockquote, button, caption, cell, checkbox, code, color,
    columnheader, combobox, complementary, contentinfo, date, definition, deletion,
    dialog, document, emphasis, figure, file, form, group, heading, image, insertion,
    link, list, listbox, listitem, main, marquee, menuitem, meter, month, navigation, option,
    paragraph, presentation, progressbar, radio, region, row, rowgroup,
    rowheader, searchbox, separator, slider, spinbutton, status, strong,
    subscript, superscript, @"switch", table, term, textbox, time, RootWebArea, LineBreak,
    StaticText,
    // zig fmt: on

    fn fromNode(node: *DOMNode) !AXRole {
        return switch (node._type) {
            .document => return .RootWebArea, // Chrome specific.
            .cdata => |cd| {
                if (cd.is(DOMNode.CData.Text) == null) {
                    log.debug(.cdp, "invalid tag", .{ .tag = cd });
                    return error.InvalidTag;
                }

                return .StaticText;
            },
            .element => |el| switch (el.getTag()) {
                // Navigation & Structure
                .nav => .navigation,
                .main => .main,
                .aside => .complementary,
                // TODO conditions:
                // .banner Not descendant of article, aside, main, nav, section
                // (none) When descendant of article, aside, main, nav, section
                .header => .banner,
                // TODO conditions:
                // contentinfo Not descendant of article, aside, main, nav, section
                // (none)  When descendant of article, aside, main, nav, section
                .footer => .contentinfo,
                // TODO conditions:
                // region Has accessible name (aria-label, aria-labelledby, or title) |
                // (none) No accessible name                                          |
                .section => .region,
                .article, .hgroup => .article,
                .address => .group,

                // Headings
                .h1, .h2, .h3, .h4, .h5, .h6 => .heading,
                .ul, .ol, .menu => .list,
                .li => .listitem,
                .dt => .term,
                .dd => .definition,

                // Forms & Inputs
                // TODO conditions:
                //  form  Has accessible name
                //  (none) No accessible name
                .form => .form,
                .input => {
                    const input = el.as(DOMNode.Element.Html.Input);
                    return switch (input._input_type) {
                        .tel, .url, .email, .text => .textbox,
                        .image, .reset, .button, .submit => .button,
                        .radio => .radio,
                        .range => .slider,
                        .number => .spinbutton,
                        .search => .searchbox,
                        .checkbox => .checkbox,
                        .color => .color,
                        .date => .date,
                        .file => .file,
                        .month => .month,
                        .@"datetime-local", .week, .time => .combobox,
                        // zig fmt: off
                        .password, .hidden => .none,
                        // zig fmt: on
                    };
                },
                .textarea => .textbox,
                .select => {
                    if (el.getAttributeSafe(comptime .wrap("multiple")) != null) {
                        return .listbox;
                    }
                    if (el.getAttributeSafe(comptime .wrap("size"))) |size| {
                        if (!std.ascii.eqlIgnoreCase(size, "1")) {
                            return .listbox;
                        }
                    }
                    return .combobox;
                },
                .option => .option,
                .optgroup, .fieldset => .group,
                .button => .button,
                .output => .status,
                .progress => .progressbar,
                .meter => .meter,
                .datalist => .listbox,

                // Interactive Elements
                .anchor, .area => {
                    if (el.getAttributeSafe(comptime .wrap("href")) == null) {
                        return .none;
                    }

                    return .link;
                },
                .details => .group,
                .summary => .button,
                .dialog => .dialog,

                // Media
                .img => .image,
                .figure => .figure,

                // Tables
                .table => .table,
                .caption => .caption,
                .thead, .tbody, .tfoot => .rowgroup,
                .tr => .row,
                .th => {
                    if (el.getAttributeSafe(comptime .wrap("scope"))) |scope| {
                        if (std.ascii.eqlIgnoreCase(scope, "row")) {
                            return .rowheader;
                        }
                    }
                    return .columnheader;
                },
                .td => .cell,

                // Text & Semantics
                .p => .paragraph,
                .hr => .separator,
                .blockquote => .blockquote,
                .code => .code,
                .em => .emphasis,
                .strong => .strong,
                .s, .del => .deletion,
                .ins => .insertion,
                .sub => .subscript,
                .sup => .superscript,
                .time => .time,
                .dfn => .term,

                // Document Structure
                .html => .none,
                .body => .none,

                // Deprecated/Obsolete Elements
                .marquee => .marquee,

                .br => .LineBreak,

                else => .none,
            },
            else => |tag| {
                log.debug(.cdp, "invalid tag", .{ .tag = tag });
                return error.InvalidTag;
            },
        };
    }
};

dom: *DOMNode,
role_attr: ?[]const u8,

pub fn fromNode(dom: *DOMNode) AXNode {
    return .{
        .dom = dom,
        .role_attr = blk: {
            if (dom.is(DOMNode.Element.Html) == null) {
                break :blk null;
            }
            const elt = dom.as(DOMNode.Element);
            break :blk elt.getAttributeSafe(comptime .wrap("role"));
        },
    };
}

const AXSource = enum(u8) {
    aria_labelledby,
    aria_label,
    label_element, // <label for="...">
    label_wrap, // <label><input></label>
    alt, // img alt attribute
    title, // title attribute
    placeholder, // input placeholder
    contents, // text content
    value, // input value
};

pub fn getName(self: AXNode, frame: *Frame, allocator: std.mem.Allocator) !?[]const u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    // writeName expects a std.json.Stringify instance.
    const TextCaptureWriter = struct {
        aw: *std.Io.Writer.Allocating,
        writer: *std.Io.Writer,

        pub fn write(w: @This(), val: anytype) !void {
            const T = @TypeOf(val);
            if (T == []const u8 or T == [:0]const u8 or T == *const [val.len]u8) {
                try w.aw.writer.writeAll(val);
            } else if (comptime std.meta.hasMethod(T, "format")) {
                try std.fmt.format(w.aw.writer, "{s}", .{val});
            } else {
                // Ignore unexpected types (e.g. booleans) to avoid garbage output
            }
        }

        // Mock JSON Stringifier lifecycle methods
        pub fn beginWriteRaw(_: @This()) !void {}
        pub fn endWriteRaw(_: @This()) void {}
    };

    const w: TextCaptureWriter = .{ .aw = &aw, .writer = &aw.writer };

    const source = try self.writeName(null, w, frame, null);
    if (source != null) {
        // Remove literal quotes inserted by writeString.
        var raw_text = std.mem.trim(u8, aw.written(), "\"");
        raw_text = std.mem.trim(u8, raw_text, &std.ascii.whitespace);
        return try allocator.dupe(u8, raw_text);
    }

    return null;
}

fn writeName(
    axnode: AXNode,
    temp_arena: ?std.mem.Allocator,
    w: anytype,
    frame: *Frame,
    label_index: ?*Label.LabelByForIndex,
) !?AXSource {
    defer if (temp_arena) |a| frame._session.arena_pool.reset(a, scratch_retain_limit);

    const node = axnode.dom;

    return switch (node._type) {
        .document => |doc| switch (doc._type) {
            .html => |doc_html| {
                try w.write(try doc_html.getTitle(frame));
                return .title;
            },
            else => null,
        },
        .cdata => |cd| switch (cd._type) {
            .text => |*text| {
                try writeString(text.getWholeText(), w);
                return .contents;
            },
            else => null,
        },
        .element => |el| {
            // Handle aria-labelledby attribute (highest priority)
            if (el.getAttributeSafe(.wrap("aria-labelledby"))) |labelledby| {
                // Get the document to look up elements by ID
                const doc = node.ownerDocument(frame) orelse return null;

                // Parse space-separated list of IDs and concatenate their text content
                var it = std.mem.splitScalar(u8, labelledby, ' ');
                var has_content = false;

                var buf = std.Io.Writer.Allocating.init(scratchAllocator(temp_arena, frame));
                while (it.next()) |id| {
                    const trimmed_id = std.mem.trim(u8, id, &std.ascii.whitespace);
                    if (trimmed_id.len == 0) continue;

                    if (doc.getElementById(trimmed_id, frame)) |referenced_el| {
                        // Get the text content of the referenced element
                        try referenced_el.getInnerText(&buf.writer);
                        try buf.writer.writeByte(' ');
                        has_content = true;
                    }
                }

                if (has_content) {
                    try writeString(buf.written(), w);
                    return .aria_labelledby;
                }
            }

            if (el.getAttributeSafe(comptime .wrap("aria-label"))) |aria_label| {
                try w.write(aria_label);
                return .aria_label;
            }

            if (isLabellableTag(el.getTag())) {
                if (try writeLabelName(temp_arena, node, el, frame, label_index, w)) |source| {
                    return source;
                }
            }

            if (el.getAttributeSafe(comptime .wrap("alt"))) |alt| {
                try w.write(alt);
                return .alt;
            }

            switch (el.getTag()) {
                .br => {
                    try writeString("\n", w);
                    return .contents;
                },
                .input => {
                    const input = el.as(DOMNode.Element.Html.Input);
                    switch (input._input_type) {
                        .reset, .button, .submit => |t| {
                            const v = input.getValue();
                            if (v.len > 0) {
                                try w.write(input.getValue());
                            } else {
                                try w.write(@tagName(t));
                            }

                            return .value;
                        },
                        else => {},
                    }
                    // TODO Check for <label> with matching "for" attribute
                    // TODO Check if input is wrapped in a <label>
                },
                // zig fmt: off
                .textarea, .select, .img, .audio, .video, .iframe, .embed,
                .object, .progress, .meter, .main, .nav, .aside, .header,
                .footer, .form, .section, .article, .ul, .ol, .dl, .menu,
                .thead, .tbody, .tfoot, .tr, .td, .div, .span, .p, .details, .li,
                .style, .script, .html, .body,
                // zig fmt: on
                => {},
                else => {
                    // write text content if exists.
                    var buf: std.Io.Writer.Allocating = .init(scratchAllocator(temp_arena, frame));
                    try writeAccessibleNameFallback(node, &buf.writer, frame);
                    if (buf.written().len > 0) {
                        try writeString(buf.written(), w);
                        return .contents;
                    }
                },
            }

            if (el.getAttributeSafe(comptime .wrap("title"))) |title| {
                try w.write(title);
                return .title;
            }

            if (el.getAttributeSafe(comptime .wrap("placeholder"))) |placeholder| {
                try w.write(placeholder);
                return .placeholder;
            }

            try w.write("");
            return null;
        },
        else => {
            try w.write("");
            return null;
        },
    };
}

fn writeAccessibleNameFallback(node: *DOMNode, writer: *std.Io.Writer, frame: *Frame) !void {
    var it = node.childrenIterator();
    while (it.next()) |child| {
        switch (child._type) {
            .cdata => |cd| switch (cd._type) {
                .text => |*text| {
                    const content = std.mem.trim(u8, text.getWholeText(), &std.ascii.whitespace);
                    if (content.len > 0) {
                        try writer.writeAll(content);
                        try writer.writeByte(' ');
                    }
                },
                else => {},
            },
            .element => |el| {
                if (el.getTag() == .img) {
                    if (el.getAttributeSafe(.wrap("alt"))) |alt| {
                        try writer.writeAll(alt);
                        try writer.writeByte(' ');
                    }
                } else if (el.getTag() == .svg) {
                    // Try to find a <title> inside SVG
                    var sit = child.childrenIterator();
                    while (sit.next()) |s_child| {
                        if (s_child.is(DOMNode.Element)) |s_el| {
                            if (std.mem.eql(u8, s_el.getTagNameLower(), "title")) {
                                try writeAccessibleNameFallback(s_child, writer, frame);
                                try writer.writeByte(' ');
                            }
                        }
                    }
                } else {
                    if (!el.getTag().isMetadata()) {
                        try writeAccessibleNameFallback(child, writer, frame);
                    }
                }
            },
            else => {},
        }
    }
}

fn hasAriaHiddenTrue(elt: *DOMNode.Element) bool {
    if (elt.getAttributeSafe(comptime .wrap("aria-hidden"))) |value| {
        return std.mem.eql(u8, value, "true");
    }
    return false;
}

fn isLabellableTag(tag: DOMNode.Element.Tag) bool {
    return switch (tag) {
        .button, .meter, .output, .progress, .select, .textarea, .input => true,
        else => false,
    };
}

// CSS-only toggle switches and custom radios commonly visually-style a
// `<label>` while `display:none`-ing the real `<input>`. Chromium matches
// this by pruning the input from the AX tree, which leaves the label as a
// generic role=none element and an agent walking the tree has nothing
// interactive to click.
//
// When a `<label>` targets a hidden checkbox or radio, promote it: emit
// the label with the input's role and state. Browsers already forward
// label clicks to the associated input, so the label's backendDOMNodeId
// is a valid click target.
fn labelPromotionTarget(
    axn: AXNode,
    frame: *Frame,
    cache: *DOMNode.Element.VisibilityCache,
) ?*DOMNode.Element.Html.Input {
    // Respect an explicit role= on the label.
    if (axn.role_attr != null) return null;

    const node = axn.dom;
    const el = node.is(DOMNode.Element) orelse return null;
    if (el.getTag() != .label) return null;

    const label = el.as(DOMNode.Element.Html.Label);
    const control = label.getControl(frame) orelse return null;

    // Only promote when the control is hidden; otherwise it appears
    // normally and the label stays as-is.
    if (!isHidden(control, frame, cache)) return null;

    if (control.getTag() != .input) return null;
    const input = control.as(DOMNode.Element.Html.Input);
    return switch (input._input_type) {
        .checkbox, .radio => input,
        else => null,
    };
}

fn writeLabelName(
    temp_arena: ?std.mem.Allocator,
    node: *DOMNode,
    el: *DOMNode.Element,
    frame: *Frame,
    label_index: ?*Label.LabelByForIndex,
    w: anytype,
) !?AXSource {
    if (el.getAttributeSafe(comptime .wrap("id"))) |id_value| {
        if (id_value.len > 0) {
            if (node.ownerDocument(frame)) |doc| {
                const match: ?*DOMNode.Element = if (label_index) |idx|
                    try idx.lookup(doc.asNode(), id_value, frame.call_arena)
                else
                    Label.findLabelByFor(doc.asNode(), id_value);
                if (match) |label_el| {
                    if (try writeLabelInnerText(temp_arena, label_el, frame, w)) return .label_element;
                }
            }
        }
    }

    if (Label.findWrappingLabel(el)) |wrap_label| {
        if (try writeLabelInnerText(temp_arena, wrap_label, frame, w)) return .label_wrap;
    }

    return null;
}

fn writeLabelInnerText(
    temp_arena: ?std.mem.Allocator,
    label_el: *DOMNode.Element,
    frame: *Frame,
    w: anytype,
) !bool {
    var buf: std.Io.Writer.Allocating = .init(scratchAllocator(temp_arena, frame));
    try label_el.getInnerText(&buf.writer);
    const text = std.mem.trim(u8, buf.written(), &std.ascii.whitespace);
    if (text.len == 0) return false;
    try writeString(text, w);
    return true;
}

/// Allocator for throwaway name-resolution buffers: prefers the writer's
/// temp arena so multiple calls reuse its retained page; falls back to
/// `frame.call_arena` on the non-Writer `getName` path.
fn scratchAllocator(temp_arena: ?std.mem.Allocator, frame: *Frame) std.mem.Allocator {
    return temp_arena orelse frame.call_arena;
}

fn isHidden(elt: *DOMNode.Element, frame: *Frame, cache: *DOMNode.Element.VisibilityCache) bool {
    if (elt.getAttributeSafe(comptime .wrap("aria-hidden"))) |value| {
        if (std.mem.eql(u8, value, "true")) {
            return true;
        }
    }

    if (elt.hasAttributeSafe(comptime .wrap("hidden"))) {
        return true;
    }

    if (elt.hasAttributeSafe(comptime .wrap("inert"))) {
        return true;
    }

    // CSS display:none and visibility:hidden (both inherited from ancestors via
    // style computation). Matches Chromium's AX tree which prunes both.
    if (frame._style_manager.isHidden(elt, cache, .{ .check_visibility = true })) {
        return true;
    }

    return false;
}

fn ignoreText(node: *DOMNode) bool {
    if (node.is(DOMNode.Element.Html) == null) {
        return true;
    }

    const elt = node.as(DOMNode.Element);
    // Only ignore text for structural/container elements that typically
    // don't have meaningful direct text content
    return switch (elt.getTag()) {
        // zig fmt: off
        // Structural containers
        .html, .body, .head,
        // Lists (text is in li elements, not in ul/ol)
        .ul, .ol, .menu,
        // Tables (text is in cells, not in table/tbody/thead/tfoot/tr)
        .table, .thead, .tbody, .tfoot, .tr,
        // Form containers
        .form, .fieldset, .datalist,
        // Grouping elements
        .details, .figure,
        // Other containers
        .select, .optgroup, .colgroup, .script,
        => true,
        // zig fmt: on
        // All other elements should include their text content
        else => false,
    };
}

fn ignoreChildren(self: AXNode) bool {
    const node = self.dom;
    if (node.is(DOMNode.Element.Html) == null) {
        return false;
    }

    const elt = node.as(DOMNode.Element);
    return switch (elt.getTag()) {
        .head, .script, .style => true,
        else => false,
    };
}

fn isIgnore(self: AXNode, frame: *Frame, cache: *DOMNode.Element.VisibilityCache, in_aria_hidden: bool) bool {
    const node = self.dom;
    const role_attr = self.role_attr;

    // Don't ignore non-Element node: CData, Document...
    const elt = node.is(DOMNode.Element) orelse return in_aria_hidden;
    // Ignore non-HTML elements: svg...
    if (elt._type != .html) {
        return true;
    }

    const tag = elt.getTag();
    switch (tag) {
        // zig fmt: off
        .script, .style, .meta, .link, .title, .base, .head, .noscript,
        .template, .param, .source, .track, .datalist, .col, .colgroup, .html,
        .body
        => return true,
        // zig fmt: on
        .img => {
            // Check for empty decorative images
            const alt_ = elt.getAttributeSafe(comptime .wrap("alt"));
            if (alt_ == null or alt_.?.len == 0) {
                return true;
            }
        },
        .input => {
            // Check for hidden inputs
            const input = elt.as(DOMNode.Element.Html.Input);
            if (input._input_type == .hidden) {
                return true;
            }
        },
        else => {},
    }

    if (role_attr) |role| {
        if (std.ascii.eqlIgnoreCase(role, "none") or std.ascii.eqlIgnoreCase(role, "presentation")) {
            return true;
        }
    }

    if (in_aria_hidden) {
        return true;
    }

    if (isHidden(elt, frame, cache)) {
        return true;
    }

    // Generic containers with no semantic value
    if (tag == .div or tag == .span) {
        const has_role = elt.hasAttributeSafe(comptime .wrap("role"));
        const has_aria_label = elt.hasAttributeSafe(comptime .wrap("aria-label"));
        const has_aria_labelledby = elt.hasAttributeSafe(.wrap("aria-labelledby"));

        if (!has_role and !has_aria_label and !has_aria_labelledby) {
            // Check if it has any non-ignored children.
            var it = node.childrenIterator();
            while (it.next()) |child| {
                const axn = AXNode.fromNode(child);
                if (!axn.isIgnore(frame, cache, in_aria_hidden)) {
                    return false;
                }
            }

            return true;
        }
    }

    return false;
}

pub fn getRole(self: AXNode) ![]const u8 {
    if (self.role_attr) |role_value| {
        // TODO the role can have multiple comma separated values.
        return role_value;
    }

    const role_implicit = try AXRole.fromNode(self.dom);

    return @tagName(role_implicit);
}

// Replace successives whitespaces with one whitespace.
// Trims left and right according to the options.
// Returns true if the string ends with a trimmed whitespace.
fn writeString(s: []const u8, w: anytype) !void {
    try w.beginWriteRaw();
    try w.writer.writeByte('\"');
    try stripWhitespaces(s, w.writer);
    try w.writer.writeByte('\"');
    w.endWriteRaw();
}

// string written is json encoded.
fn stripWhitespaces(s: []const u8, writer: anytype) !void {
    var start: usize = 0;
    var prev_w: ?bool = null;
    var is_w: bool = false;

    for (s, 0..) |c, i| {
        is_w = std.ascii.isWhitespace(c);

        // Detect the first char type.
        if (prev_w == null) {
            prev_w = is_w;
        }
        // The current char is the same kind of char, the chunk continues.
        if (prev_w.? == is_w) {
            continue;
        }

        // Starting here, the chunk changed.
        if (is_w) {
            // We have a chunk of non-whitespaces, we write it as it.
            try jsonStringify.encodeJsonStringChars(s[start..i], .{}, writer);
        } else {
            // We have a chunk of whitespaces, replace with one space,
            // depending the position.
            if (start > 0) {
                try writer.writeByte(' ');
            }
        }
        // Start the new chunk.
        prev_w = is_w;
        start = i;
    }
    // Write the reminder chunk.
    if (!is_w) {
        // last chunk is non whitespaces.
        try jsonStringify.encodeJsonStringChars(s[start..], .{}, writer);
    }
}

test "AXnode: stripWhitespaces" {
    const allocator = std.testing.allocator;

    const TestCase = struct {
        value: []const u8,
        expected: []const u8,
    };

    const test_cases = [_]TestCase{
        .{ .value = "   ", .expected = "" },
        .{ .value = "   ", .expected = "" },
        .{ .value = "foo bar", .expected = "foo bar" },
        .{ .value = "foo  bar", .expected = "foo bar" },
        .{ .value = "  foo bar", .expected = "foo bar" },
        .{ .value = "foo bar  ", .expected = "foo bar" },
        .{ .value = "  foo bar  ", .expected = "foo bar" },
        .{ .value = "foo\n\tbar", .expected = "foo bar" },
        .{ .value = "\tfoo bar   baz   \t\n yeah\r\n", .expected = "foo bar baz yeah" },
        // string must be json encoded.
        .{ .value = "\"foo\"", .expected = "\\\"foo\\\"" },
    };

    var buffer = std.io.Writer.Allocating.init(allocator);
    defer buffer.deinit();

    for (test_cases) |test_case| {
        buffer.clearRetainingCapacity();
        try stripWhitespaces(test_case.value, &buffer.writer);
        try std.testing.expectEqualStrings(test_case.expected, buffer.written());
    }
}

const testing = @import("testing.zig");
test "AXNode: writer" {
    var registry = Node.Registry.init(testing.allocator);
    defer registry.deinit();

    var frame = try testing.pageTest("cdp/dom3.html", .{});
    defer frame._session.removePage();
    var doc = frame.window._document;

    const node = try registry.register(doc.asNode());
    var visibility_cache: DOMNode.Element.VisibilityCache = .empty;
    var label_index: Label.LabelByForIndex = .{};
    const temp_arena = try frame.getArena(.medium, "AXNode");
    defer frame.releaseArena(temp_arena);
    const json = try std.json.Stringify.valueAlloc(testing.allocator, Writer{
        .root = node,
        .registry = &registry,
        .frame = frame,
        .visibility_cache = &visibility_cache,
        .label_index = &label_index,
        .temp_arena = temp_arena,
    }, .{});
    defer testing.allocator.free(json);

    // Check that the document node is present with proper structure
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();

    const nodes = parsed.value.array.items;
    try testing.expect(nodes.len > 0);

    // First node should be the document
    const doc_node = nodes[0].object;
    // CDP spec: AXNodeId is a string; backendDOMNodeId (DOM.BackendNodeId) is an integer.
    try testing.expectEqual("1", doc_node.get("nodeId").?.string);
    try testing.expectEqual(1, doc_node.get("backendDOMNodeId").?.integer);
    try testing.expectEqual(false, doc_node.get("ignored").?.bool);

    const role = doc_node.get("role").?.object;
    try testing.expectEqual("role", role.get("type").?.string);
    try testing.expectEqual("RootWebArea", role.get("value").?.string);

    const name = doc_node.get("name").?.object;
    try testing.expectEqual("computedString", name.get("type").?.string);
    try testing.expectEqual("Test Page", name.get("value").?.string);

    // Check properties array exists
    const properties = doc_node.get("properties").?.array.items;
    try testing.expect(properties.len >= 1);

    // Check childIds array exists
    const child_ids = doc_node.get("childIds").?.array.items;
    try testing.expect(child_ids.len > 0);
    // CDP spec: childIds entries are AXNodeId (strings).
    for (child_ids) |cid| {
        try testing.expect(cid == .string);
    }

    // A non-root node must have parentId serialized as a string.
    var saw_parent_id = false;
    for (nodes[1..]) |node_val| {
        if (node_val.object.get("parentId")) |pid| {
            try testing.expect(pid == .string);
            saw_parent_id = true;
            break;
        }
    }
    try testing.expect(saw_parent_id);

    // Find the h1 node and verify its level property is serialized as a string
    for (nodes) |node_val| {
        const obj = node_val.object;
        const role_obj = obj.get("role") orelse continue;
        const role_val = role_obj.object.get("value") orelse continue;
        if (!std.mem.eql(u8, role_val.string, "heading")) continue;

        const props = obj.get("properties").?.array.items;
        for (props) |prop| {
            const prop_obj = prop.object;
            const name_str = prop_obj.get("name").?.string;
            if (!std.mem.eql(u8, name_str, "level")) continue;
            const level_value = prop_obj.get("value").?.object;
            try testing.expectEqual("integer", level_value.get("type").?.string);
            // CDP spec: integer values must be serialized as strings
            try testing.expectEqual("1", level_value.get("value").?.string);
            return;
        }
    }
    return error.HeadingNodeNotFound;
}

test "AXNode: writer prunes hidden and resolves labels" {
    var registry = Node.Registry.init(testing.allocator);
    defer registry.deinit();

    var frame = try testing.pageTest("cdp/ax_tree.html", .{});
    defer frame._session.removePage();
    var doc = frame.window._document;

    const node = try registry.register(doc.asNode());
    var visibility_cache: DOMNode.Element.VisibilityCache = .empty;
    var label_index: Label.LabelByForIndex = .{};
    const temp_arena = try frame.getArena(.medium, "AXNode");
    defer frame.releaseArena(temp_arena);
    const json = try std.json.Stringify.valueAlloc(testing.allocator, Writer{
        .root = node,
        .registry = &registry,
        .frame = frame,
        .visibility_cache = &visibility_cache,
        .label_index = &label_index,
        .temp_arena = temp_arena,
    }, .{});
    defer testing.allocator.free(json);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    const nodes = parsed.value.array.items;

    // No hidden-subtree text should have leaked into the tree.
    const hidden_texts = [_][]const u8{
        "under-display-none",
        "under-visibility-hidden",
        "under-hidden-attr",
        "under-aria-hidden",
    };
    for (nodes) |node_val| {
        const obj = node_val.object;
        const name_obj = obj.get("name") orelse continue;
        const value = name_obj.object.get("value") orelse continue;
        if (value != .string) continue;
        for (hidden_texts) |bad| {
            try testing.expect(std.mem.indexOf(u8, value.string, bad) == null);
        }
    }

    // The visible paragraph's text leaks into the tree as a StaticText child.
    var found_visible = false;
    for (nodes) |node_val| {
        const obj = node_val.object;
        const name_obj = obj.get("name") orelse continue;
        const value = name_obj.object.get("value") orelse continue;
        if (value == .string and std.mem.indexOf(u8, value.string, "visible-para") != null) {
            found_visible = true;
            break;
        }
    }
    try testing.expect(found_visible);

    // The search input gets its name from <label for=search-input>.
    var search_named = false;
    for (nodes) |node_val| {
        const obj = node_val.object;
        const role_obj = obj.get("role") orelse continue;
        const role_val = role_obj.object.get("value") orelse continue;
        if (!std.mem.eql(u8, role_val.string, "searchbox")) continue;
        const name_val = obj.get("name").?.object.get("value").?;
        if (name_val == .string and std.mem.indexOf(u8, name_val.string, "Search") != null) {
            search_named = true;
        }
    }
    try testing.expect(search_named);

    // The wrapped input gets its name from its ancestor <label>.
    var wrapped_named = false;
    for (nodes) |node_val| {
        const obj = node_val.object;
        const role_obj = obj.get("role") orelse continue;
        const role_val = role_obj.object.get("value") orelse continue;
        if (!std.mem.eql(u8, role_val.string, "textbox")) continue;
        const name_val = obj.get("name").?.object.get("value").?;
        if (name_val == .string and std.mem.indexOf(u8, name_val.string, "Wrap") != null) {
            wrapped_named = true;
        }
    }
    try testing.expect(wrapped_named);

    // Labels associated with CSS-hidden checkboxes/radios are promoted:
    // the label appears with the control's role + state so agents can
    // interact with CSS-only toggle switches.
    const Expected = struct {
        name_needle: []const u8,
        role: []const u8,
        checked: []const u8,
    };
    const expected = [_]Expected{
        // `for=`-associated: CSS display:none checkbox with `checked`.
        .{ .name_needle = "Enable feature", .role = "checkbox", .checked = "true" },
        // `for=`-associated: display:none radio with `checked`.
        .{ .name_needle = "Option A", .role = "radio", .checked = "true" },
        // `for=`-associated: visibility:hidden radio, unchecked.
        .{ .name_needle = "Option B", .role = "radio", .checked = "false" },
        // Wrapping label pattern, checkbox hidden, unchecked.
        .{ .name_needle = "Accept terms", .role = "checkbox", .checked = "false" },
    };
    for (expected) |exp| {
        var found = false;
        for (nodes) |node_val| {
            const obj = node_val.object;
            const role_obj = obj.get("role") orelse continue;
            const role_val = role_obj.object.get("value") orelse continue;
            if (!std.mem.eql(u8, role_val.string, exp.role)) continue;
            const name_obj = obj.get("name") orelse continue;
            const name_value = name_obj.object.get("value") orelse continue;
            if (name_value != .string) continue;
            if (std.mem.indexOf(u8, name_value.string, exp.name_needle) == null) continue;

            // Verify the `checked` property was emitted with the right value.
            const props = obj.get("properties").?.array.items;
            var checked_matches = false;
            for (props) |prop| {
                const prop_obj = prop.object;
                if (!std.mem.eql(u8, prop_obj.get("name").?.string, "checked")) continue;
                const val = prop_obj.get("value").?.object.get("value").?.string;
                if (std.mem.eql(u8, val, exp.checked)) checked_matches = true;
                break;
            }
            try testing.expect(checked_matches);
            found = true;
            break;
        }
        try testing.expect(found);
    }
}
