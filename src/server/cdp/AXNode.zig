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

const Frame = @import("../../browser/Frame.zig");
const DOMNode = @import("../../browser/webapi/Node.zig");
const Label = @import("../../browser/webapi/element/html/Label.zig");
const TreeWalker = @import("../../browser/webapi/TreeWalker.zig");
const interactive = @import("../../browser/interactive.zig");

const NodeRegistry = @import("../../NodeRegistry.zig");
const isAllWhitespace = @import("../../string.zig").isAllWhitespace;

const log = lp.log;
const jsonStringify = std.json.Stringify;

const AXNode = @This();

// Max bytes retained in the name-resolution scratch arena across resets.
// Anything beyond is freed back to the backing allocator.
const scratch_retain_limit = 64 * 1024;

// Need a custom writer, because we can't just serialize the node as-is.
// Sometimes we want to serializ the node without children, sometimes with just
// its direct children, and sometimes the entire tree.
pub const Writer = struct {
    root: *const NodeRegistry.Node,
    registry: *NodeRegistry,
    frame: *Frame,
    label_index: *Label.LabelByForIndex,
    temp_arena: *lp.Arena,
    // When null, emit the full AX tree (getFullAXTree). When set, walk the
    // subtree visiting all nodes (including AX-ignored ones, per the
    // queryAXTree spec) and emit only nodes whose role + accessible name
    // match the filter, in a flat shape.
    filter: ?Filter = null,
    depth: i32 = 0,

    pub const Filter = struct {
        role: ?[]const u8 = null,
        accessible_name: ?[]const u8 = null,
    };

    pub const Opts = struct {
        depth: i32 = 0,
        filter: ?Filter = null,
    };

    const ResolvedRole = struct {
        role: []const u8,
        // Non-null when the current node is a <label> whose target control is
        // a hidden checkbox/radio. Callers use this to emit the control's
        // checked/disabled properties on the promoted label.
        promoted_input: ?*DOMNode.Element.Html.Input,
    };

    pub fn jsonStringify(self: *const Writer, w: anytype) error{WriteFailed}!void {
        self.toJSON(w) catch |err| {
            // The only error our jsonStringify method can return is
            // @TypeOf(w).Error. In other words, our code can't return its own
            // error, we can only return a writer error. Kinda sucks.
            log.err(.cdp, "node toJSON stringify", .{ .err = err });
            return error.WriteFailed;
        };
    }

    fn toJSON(self: *const Writer, w: anytype) !void {
        const cache_arena = try self.frame.getArena(.medium, "AXNode.IgnoreCache");
        defer cache_arena.release();
        var ignore_cache: IgnoreCache = .{ .allocator = cache_arena.allocator() };

        try w.beginArray();
        if (self.filter != null) {
            try self.walkQuery(&ignore_cache, w);
        } else {
            try self.writeTree(&ignore_cache, w);
        }
        return w.endArray();
    }

    /// Resolve the displayed role for `axn`, accounting for label-promotion
    /// when a <label> targets a hidden checkbox/radio. Shared between the
    /// tree (writeNode) and query (emitMatch) paths so the two can't drift.
    fn resolveRole(self: *const Writer, axn: AXNode) !ResolvedRole {
        if (labelPromotionTarget(axn, self.frame)) |input| {
            return .{
                .role = switch (input._input_type) {
                    .checkbox => "checkbox",
                    .radio => "radio",
                    else => unreachable,
                },
                .promoted_input = input,
            };
        }
        return .{ .role = try axn.getRole(), .promoted_input = null };
    }

    // CDP spec defines AXNodeId as a string, so nodeId/parentId/childIds must
    // be serialized as JSON strings even though we track them internally as u32.
    fn writeIdString(id: u32, w: anytype) !void {
        var buf: [10]u8 = undefined;
        const s = try std.mem.print(&buf, "{d}", .{id});
        try w.write(s);
    }

    fn writeTree(self: *const Writer, ignore_cache: *IgnoreCache, w: anytype) !void {
        var walker: Walker = .init(self.root.dom, self.frame);
        var descend = try self.writeNode(self.root.id, .fromNode(self.root.dom), walker.hidden(self.root.dom), ignore_cache, w);
        while (walker.next(descend)) |dom_node| {
            descend = false;
            if (self.depth > 0 and self.depth < walker.depth) continue;

            switch (dom_node._type) {
                .cdata => {
                    if (dom_node.is(DOMNode.CData.Text) == null) {
                        continue;
                    }
                    if (ignoreText(dom_node._parent.?)) {
                        continue;
                    }
                },
                .element => {},
                else => continue,
            }

            const hidden = walker.hidden(dom_node);
            if (hidden == .pruned) {
                continue;
            }
            const node = try self.registry.register(dom_node);
            descend = try self.writeNode(node.id, .fromNode(dom_node), hidden, ignore_cache, w);
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
                const marker_text = try std.mem.print(&buf, "{d}. ", .{count});
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
            .caption => blk: {
                try w.objectField("nativeSource");
                try w.write("tablecaption");
                break :blk "relatedElement";
            },
            .legend => blk: {
                try w.objectField("nativeSource");
                try w.write("legend");
                break :blk "relatedElement";
            },
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
            .document => {
                const uri = dom_node.subtype(DOMNode.Document).getURL(frame);
                try self.writeAXProperty(.{ .name = .url, .value = .{ .string = uri } }, w);
                try self.writeAXProperty(.{ .name = .focusable, .value = .{ .booleanOrUndefined = true } }, w);
                try self.writeAXProperty(.{ .name = .focused, .value = .{ .booleanOrUndefined = true } }, w);
                return;
            },
            .cdata => return,
            .element => {
                const el = dom_node.subtype(DOMNode.Element);
                try self.writeAriaProperties(axnode, el, w);
                switch (el.getTag()) {
                    .img => {
                        const img = el.as(DOMNode.Element.Html.Image);
                        const uri = try img.getSrc(self.frame);
                        if (uri.len == 0) return;
                        try self.writeAXProperty(.{ .name = .url, .value = .{ .string = uri } }, w);
                    },
                    .a => {
                        const a = el.as(DOMNode.Element.Html.Anchor);
                        const uri = try a.getHref(self.frame);
                        if (uri.len == 0) return;
                        try self.writeAXProperty(.{ .name = .url, .value = .{ .string = uri } }, w);
                        try self.writeAXProperty(.{ .name = .focusable, .value = .{ .booleanOrUndefined = true } }, w);
                    },
                    .input => {
                        const input = el.as(DOMNode.Element.Html.Input);
                        const is_disabled = el.isDisabled();
                        const is_readonly = el.hasAttributeInterned("readonly");

                        if (is_disabled) {
                            try self.writeAXProperty(.{ .name = .disabled, .value = .{ .boolean = true } }, w);
                        }
                        try self.writeAXProperty(.{ .name = .invalid, .value = .{ .token = invalidToken(el) } }, w);
                        if (!is_disabled) {
                            try self.writeAXProperty(.{ .name = .focusable, .value = .{ .booleanOrUndefined = true } }, w);
                        }

                        switch (input._input_type) {
                            .text, .email, .tel, .url, .password => {
                                try self.writeAXProperty(.{ .name = .editable, .value = .{ .token = "plaintext" } }, w);
                                if (!is_disabled and !is_readonly) {
                                    try self.writeAXProperty(.{ .name = .settable, .value = .{ .booleanOrUndefined = true } }, w);
                                }
                                try self.writeAXProperty(.{ .name = .multiline, .value = .{ .boolean = false } }, w);
                                // Readonly is set to false if the field is disabled, disregarding the readonly attribute.
                                if (is_disabled == false) {
                                    try self.writeAXProperty(.{ .name = .readonly, .value = .{ .boolean = false } }, w);
                                } else {
                                    try self.writeAXProperty(.{ .name = .readonly, .value = .{ .boolean = is_readonly } }, w);
                                }
                                try self.writeAXProperty(.{ .name = .required, .value = .{ .boolean = el.hasAttributeInterned("required") } }, w);
                            },
                            .search => {
                                try self.writeAXProperty(.{ .name = .editable, .value = .{ .token = "plaintext" } }, w);
                                if (!is_disabled and !is_readonly) {
                                    try self.writeAXProperty(.{ .name = .settable, .value = .{ .booleanOrUndefined = true } }, w);
                                }
                            },
                            .number => {
                                try self.writeAXProperty(.{ .name = .editable, .value = .{ .token = "plaintext" } }, w);
                                if (!is_disabled and !is_readonly) {
                                    try self.writeAXProperty(.{ .name = .settable, .value = .{ .booleanOrUndefined = true } }, w);
                                }
                                try self.writeAXProperty(.{ .name = .required, .value = .{ .boolean = el.hasAttributeInterned("required") } }, w);
                            },
                            .checkbox, .radio => {
                                const is_checked = el.hasAttributeInterned("checked");
                                try self.writeAXProperty(.{ .name = .checked, .value = .{ .token = if (is_checked) "true" else "false" } }, w);
                            },
                            .range, .color, .date, .time, .@"datetime-local", .month, .week => {
                                if (!is_disabled) {
                                    try self.writeAXProperty(.{ .name = .settable, .value = .{ .booleanOrUndefined = true } }, w);
                                }
                            },
                            else => {},
                        }
                    },
                    .textarea => {
                        const is_disabled = el.isDisabled();
                        const is_readonly = el.hasAttributeInterned("readonly");

                        if (is_disabled) {
                            try self.writeAXProperty(.{ .name = .disabled, .value = .{ .boolean = true } }, w);
                        }
                        try self.writeAXProperty(.{ .name = .invalid, .value = .{ .token = invalidToken(el) } }, w);
                        if (!is_disabled) {
                            try self.writeAXProperty(.{ .name = .focusable, .value = .{ .booleanOrUndefined = true } }, w);
                        }
                        try self.writeAXProperty(.{ .name = .editable, .value = .{ .token = "plaintext" } }, w);
                        if (!is_disabled and !is_readonly) {
                            try self.writeAXProperty(.{ .name = .settable, .value = .{ .booleanOrUndefined = true } }, w);
                        }
                        try self.writeAXProperty(.{ .name = .multiline, .value = .{ .boolean = true } }, w);
                        try self.writeAXProperty(.{ .name = .readonly, .value = .{ .boolean = el.hasAttributeInterned("readonly") } }, w);
                        try self.writeAXProperty(.{ .name = .required, .value = .{ .boolean = el.hasAttributeInterned("required") } }, w);
                    },
                    .select => {
                        const is_disabled = el.isDisabled();

                        if (is_disabled) {
                            try self.writeAXProperty(.{ .name = .disabled, .value = .{ .boolean = true } }, w);
                        }
                        try self.writeAXProperty(.{ .name = .invalid, .value = .{ .token = invalidToken(el) } }, w);
                        if (!is_disabled) {
                            try self.writeAXProperty(.{ .name = .focusable, .value = .{ .booleanOrUndefined = true } }, w);
                        }
                        try self.writeAXProperty(.{ .name = .hasPopup, .value = .{ .token = "menu" } }, w);
                        try self.writeAXProperty(.{ .name = .expanded, .value = .{ .booleanOrUndefined = false } }, w);
                    },
                    .option => {
                        const option = el.as(DOMNode.Element.Html.Option);
                        try self.writeAXProperty(.{ .name = .focusable, .value = .{ .booleanOrUndefined = true } }, w);
                        try self.writeAXProperty(.{ .name = .selected, .value = .{ .booleanOrUndefined = option.getSelected() } }, w);
                    },
                    .button => {
                        const is_disabled = el.isDisabled();
                        if (is_disabled) {
                            try self.writeAXProperty(.{ .name = .disabled, .value = .{ .boolean = true } }, w);
                        }
                        try self.writeAXProperty(.{ .name = .invalid, .value = .{ .token = invalidToken(el) } }, w);
                        if (!is_disabled) {
                            try self.writeAXProperty(.{ .name = .focusable, .value = .{ .booleanOrUndefined = true } }, w);
                        }
                    },
                    .hr => {
                        try self.writeAXProperty(.{ .name = .settable, .value = .{ .booleanOrUndefined = true } }, w);
                        try self.writeAXProperty(.{ .name = .orientation, .value = .{ .token = "horizontal" } }, w);
                    },
                    .li => {
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
                        // As far as I can see, chrome reports a min of 1, even
                        // for a list without ul/ol/menu parent.
                        try self.writeAXProperty(.{ .name = .level, .value = .{ .integer = @max(level, 1) } }, w);
                    },
                    else => {},
                }
            },
            else => |tag| {
                log.debug(.cdp, "invalid tag", .{ .tag = tag });
                return error.InvalidTag;
            },
        }
    }

    // Properties every element can carry through ARIA attributes.
    fn writeAriaProperties(self: *const Writer, axnode: AXNode, el: *DOMNode.Element, w: anytype) !void {
        if (el.getAttributeSafe(.wrap("aria-labelledby"))) |ids| {
            try self.writeIdrefListProperty(.labelledby, ids, axnode.dom, w);
        }
        if (el.getAttributeSafe(.wrap("aria-describedby"))) |ids| {
            try self.writeIdrefListProperty(.describedby, ids, axnode.dom, w);
        }
        if (el.getAttributeSafe(.wrap("aria-roledescription"))) |roledescription| {
            if (!isAllWhitespace(roledescription)) {
                try self.writeAXProperty(.{ .name = .roledescription, .value = .{ .string = roledescription } }, w);
            }
        }
        if (headingLevel(axnode, el)) |level| {
            try self.writeAXProperty(.{ .name = .level, .value = .{ .integer = level } }, w);
        }
    }

    // {"name": <name>, "value": {"type": "idrefList", "value": <ids>,
    // "relatedNodes": [{"idref", "backendDOMNodeId"}...]}}, for the elements
    // of an idref-list attribute that exist in the document.
    fn writeIdrefListProperty(self: *const Writer, name: @FieldType(AXProperty, "name"), ids: []const u8, node: *DOMNode, w: anytype) !void {
        try w.beginObject();
        try w.objectField("name");
        try w.write(@tagName(name));
        try w.objectField("value");
        try w.beginObject();
        try w.objectField("type");
        try w.write("idrefList");
        try w.objectField("value");
        try w.write(ids);
        try w.objectField("relatedNodes");
        try w.beginArray();
        if (node.ownerDocument(self.frame)) |doc| {
            var it = std.mem.tokenizeAny(u8, ids, &std.ascii.whitespace);
            while (it.next()) |id| {
                const referenced = doc.getElementById(id, self.frame) orelse continue;
                const registered = try self.registry.register(referenced.asNode());
                try w.beginObject();
                try w.objectField("idref");
                try w.write(id);
                try w.objectField("backendDOMNodeId");
                try w.write(registered.id);
                try w.endObject();
            }
        }
        try w.endArray();
        try w.endObject();
        try w.endObject();
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
    fn writeNode(self: *const Writer, id: u32, axn: AXNode, hidden: Hidden, ignore_cache: *IgnoreCache, w: anytype) !bool {
        try w.beginObject();

        try w.objectField("nodeId");
        try writeIdString(id, w);

        try w.objectField("backendDOMNodeId");
        try w.write(id);

        const resolved = try self.resolveRole(axn);
        const promoted_input = resolved.promoted_input;

        try w.objectField("role");
        try self.writeAXValue(.{ .role = resolved.role }, w);

        const ignore = hidden != .visible or try axn.isIgnore(self.frame, ignore_cache);
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

            // Description
            {
                var buf: std.Io.Writer.Allocating = .init(self.temp_arena.allocator());
                if (try axn.writeDescription(&buf, self.frame, source)) {
                    try w.objectField("description");
                    try w.beginObject();
                    try w.objectField("type");
                    try w.write(@tagName(.computedString));
                    try w.objectField("value");
                    try writeString(buf.written(), w);
                    try w.endObject();
                }
            }

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
                try self.writeAXProperty(.{ .name = .invalid, .value = .{ .token = invalidToken(input_el) } }, w);
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
        const write_children = axn.ignoreChildren() == false and hidden != .pruned;
        const skip_text = ignoreText(axn.dom);

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

                // Matches writeTree's pruning
                if (hiddenState(child, self.frame) == .pruned) {
                    continue;
                }

                const child_node = try registry.register(child);
                try writeIdString(child_node.id, w);
            }
        }
        try w.endArray();

        try w.endObject();

        if (write_children) {
            if (n.is(DOMNode.Element)) |el| {
                if (el.getTag() == .li) {
                    try self.writeListMarker(n, w);
                }
            }
        }

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
                switch (input._input_type) {
                    // No value of their own in the AX tree: a button's value
                    // is its name, checked is a property.
                    .checkbox, .radio, .button, .submit, .reset, .image, .hidden => break :blk null,
                    else => {},
                }
                const val = input.getRedactedValue();
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

    // Query-mode walk. Visits every node under the root (including AX-ignored
    // ones, per the queryAXTree spec) and defers emission to emitMatch.
    fn walkQuery(self: *const Writer, ignore_cache: *IgnoreCache, w: anytype) !void {
        const root = self.root.dom;
        var walker: Walker = .init(root, self.frame);
        const root_axn: AXNode = .fromNode(root);
        try self.emitMatch(root_axn, walker.hidden(root), ignore_cache, w);
        // <head>, <script>, <style> never expose AX content — skip their children.
        var descend = !root_axn.ignoreChildren();
        while (walker.next(descend)) |node| {
            descend = false;
            switch (node._type) {
                .element, .cdata => {},
                else => continue,
            }
            const axn: AXNode = .fromNode(node);
            try self.emitMatch(axn, walker.hidden(node), ignore_cache, w);
            descend = !axn.ignoreChildren();
        }
    }

    // Emit `axn` to `w` iff it satisfies the active filter. Output shape is
    // the queryAXTree flat-match shape: nodeId, backendDOMNodeId, ignored,
    // role, name, plus empty properties / childIds (clients fetch full
    // properties via getFullAXTree on a matched nodeId).
    fn emitMatch(self: *const Writer, axn: AXNode, hidden: Hidden, ignore_cache: *IgnoreCache, w: anytype) !void {
        const filter = self.filter.?;
        const resolved = self.resolveRole(axn) catch return;

        if (filter.role) |needle| {
            if (!std.mem.eql(u8, needle, resolved.role)) return;
        }

        const name = (try axn.getName(self.frame, self.temp_arena.allocator(), self.label_index)) orelse "";
        if (filter.accessible_name) |needle| {
            if (!std.mem.eql(u8, needle, name)) return;
        }

        const node = try self.registry.register(axn.dom);
        const ignored = hidden != .visible or try axn.isIgnore(self.frame, ignore_cache);

        try w.beginObject();

        try w.objectField("nodeId");
        try writeIdString(node.id, w);

        try w.objectField("backendDOMNodeId");
        try w.write(node.id);

        try w.objectField("ignored");
        try w.write(ignored);

        try w.objectField("role");
        try self.writeAXValue(.{ .role = resolved.role }, w);

        try w.objectField("name");
        try w.beginObject();
        try w.objectField("type");
        try w.write("computedString");
        try w.objectField("value");
        try w.write(name);
        try w.endObject();

        try w.objectField("properties");
        try w.beginArray();
        try w.endArray();

        try w.objectField("childIds");
        try w.beginArray();
        try w.endArray();

        try w.endObject();
    }
};

const AXRole = enum(u8) {
    // zig fmt: off
    none, article, banner, blockquote, button, caption, cell, checkbox, code, color,
    columnheader, combobox, complementary, contentinfo, date, definition, deletion,
    dialog, document, emphasis, figure, file, form, group, heading, image, insertion,
    link, list, listbox, listitem, main, marquee, menuitem, meter, month, navigation, option,
    paragraph, presentation, progressbar, radio, region, row, rowgroup,
    rowheader, searchbox, separator, slider, spinbutton, status, strong,
    subscript, superscript, @"switch", table, term, textbox, time, RootWebArea, LineBreak,
    StaticText, Iframe,
    // zig fmt: on

    fn fromNode(node: *DOMNode) !AXRole {
        return switch (node._type) {
            .document => return .RootWebArea, // Chrome specific.
            .cdata => {
                const cd = node.subtype(DOMNode.CData);
                if (cd.is(DOMNode.CData.Text) == null) {
                    log.debug(.cdp, "invalid tag", .{ .tag = cd });
                    return error.InvalidTag;
                }

                return .StaticText;
            },
            .element => {
                const el = node.subtype(DOMNode.Element);
                return switch (el.getTag()) {
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
                            .tel, .url, .email, .text, .password => .textbox,
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
                            .hidden => .none,
                        };
                    },
                    .textarea => .textbox,
                    .select => {
                        if (el.getAttributeInterned("multiple") != null) {
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
                    .a, .area => {
                        if (el.getAttributeInterned("href") == null) {
                            return .none;
                        }

                        return .link;
                    },
                    .details => .group,
                    .summary => .button,
                    .dialog => .dialog,

                    // Media
                    .img => .image,
                    .iframe => .Iframe,
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
                };
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
        .role_attr = if (dom.is(DOMNode.Element.Html) != null) interactive.explicitRole(dom.as(DOMNode.Element)) else null,
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
    caption, // <table><caption>
    legend, // <fieldset><legend>
};

/// `labels` fills on its first `<label for>` lookup; share one across a walk.
pub fn getName(self: AXNode, frame: *Frame, allocator: std.mem.Allocator, labels: *Label.LabelByForIndex) !?[]const u8 {
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

    const source = try self.writeName(null, w, frame, labels);
    if (source != null) {
        // Remove literal quotes inserted by writeString.
        var raw_text = std.mem.trim(u8, aw.written(), "\"");
        raw_text = std.mem.trim(u8, raw_text, &std.ascii.whitespace);
        return try allocator.dupe(u8, raw_text);
    }

    return null;
}

// The accessible name of `axnode`, written to `w` as a JSON string, and where
// it came from (null when the node has no name). Follows the Accessible Name
// and Description Computation (AccName 1.2) in precedence order:
//   2B aria-labelledby, 2C aria-label, 2D native labels (<label>, alt, a
//   button's value, <caption>, <legend>), 2F name from content for the roles
//   that allow it, 2I the title tooltip, then HTML-AAM's placeholder.
fn writeName(
    axnode: AXNode,
    temp_arena: ?*lp.Arena,
    w: anytype,
    frame: *Frame,
    label_index: *Label.LabelByForIndex,
) !?AXSource {
    defer if (temp_arena) |a| a.reset(scratch_retain_limit);

    const node = axnode.dom;

    return switch (node._type) {
        .document => switch (node.subtype(DOMNode.Document)._type) {
            .html => |doc_html| {
                try w.write(try doc_html.getTitle(frame));
                return .title;
            },
            else => null,
        },
        .cdata => {
            const cd = node.subtype(DOMNode.CData);
            switch (cd._type) {
                .text => {
                    try writeString(cd._data.str(), w);
                    return .contents;
                },
                else => return null,
            }
        },
        .element => {
            const el = node.subtype(DOMNode.Element);

            // 2B: the referenced elements are named whatever their role, hidden
            // or not. Their own aria-labelledby is not followed.
            if (el.getAttributeSafe(.wrap("aria-labelledby"))) |labelledby| {
                var buf: std.Io.Writer.Allocating = .init(scratchAllocator(temp_arena, frame));
                if (try writeIdrefText(labelledby, node, frame, &buf)) {
                    try writeString(buf.written(), w);
                    return .aria_labelledby;
                }
            }

            // 2C: an empty (or whitespace-only) aria-label is no label at all.
            if (el.getAttributeInterned("aria-label")) |aria_label| {
                if (!isAllWhitespace(aria_label)) {
                    try writeString(aria_label, w);
                    return .aria_label;
                }
            }

            // 2D: native host language labels.
            if (isLabellableTag(el.getTag())) {
                if (try writeLabelName(temp_arena, node, el, frame, label_index, w)) |source| {
                    return source;
                }
            }

            if (el.getAttributeInterned("alt")) |alt| {
                if (alt.len > 0) {
                    try writeString(alt, w);
                    return .alt;
                }
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
                                try writeString(v, w);
                                return .value;
                            }
                            // HTML-AAM: the implementation-defined default
                            // label; a value-less type=button has none.
                            if (defaultButtonLabel(t)) |label| {
                                try w.write(label);
                                return .value;
                            }
                        },
                        else => {},
                    }
                },
                .table => if (firstChildWithTag(node, .caption)) |caption| {
                    if (try writeElementContent(temp_arena, caption, frame, w)) return .caption;
                },
                .fieldset => if (firstChildWithTag(node, .legend)) |legend| {
                    if (try writeElementContent(temp_arena, legend, frame, w)) return .legend;
                },
                else => {},
            }

            // 2F: name from content, for the roles that allow it. Hidden
            // descendants don't contribute.
            const role = axnode.effectiveRole(frame);
            if (nameFromContentRole(role)) {
                if (try writeElementContent(temp_arena, el, frame, w)) return .contents;
            }

            // 2I: the title tooltip. Roles that prohibit naming (generic,
            // paragraph, emphasis...) only get it as their description, as in
            // Chromium.
            if (!nameProhibitedRole(role)) {
                if (el.getAttributeInterned("title")) |title| {
                    if (!isAllWhitespace(title)) {
                        try writeString(title, w);
                        return .title;
                    }
                }
            }

            if (el.getAttributeInterned("placeholder")) |placeholder| {
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

/// The accessible description of `axnode` (AccName 1.2 §4.3.2): the
/// aria-describedby references, else aria-description, else the title when it
/// wasn't already spent as the name. Returns false when there is none.
pub fn writeDescription(self: AXNode, buf: *std.Io.Writer.Allocating, frame: *Frame, name_source: ?AXSource) !bool {
    const node = self.dom;
    const el = node.is(DOMNode.Element) orelse return false;

    if (el.getAttributeSafe(.wrap("aria-describedby"))) |describedby| {
        if (try writeIdrefText(describedby, node, frame, buf)) return true;
    }

    if (el.getAttributeSafe(.wrap("aria-description"))) |description| {
        if (!isAllWhitespace(description)) {
            try appendWord(buf, description);
            return true;
        }
    }

    if (name_source == null or name_source.? != .title) {
        if (el.getAttributeInterned("title")) |title| {
            if (!isAllWhitespace(title)) {
                try appendWord(buf, title);
                return true;
            }
        }
    }

    return false;
}

/// Text alternative of the elements an idref list (aria-labelledby,
/// aria-describedby) points at, space-joined into `buf`. Returns false when
/// none of them contributed text. A hidden element that is referenced
/// directly contributes, hidden descendants included (2A).
fn writeIdrefText(ids: []const u8, node: *DOMNode, frame: *Frame, buf: *std.Io.Writer.Allocating) !bool {
    const doc = node.ownerDocument(frame) orelse return false;

    var wrote = false;
    var it = std.mem.tokenizeAny(u8, ids, &std.ascii.whitespace);
    while (it.next()) |id| {
        const referenced = (doc.getElementById(id, frame) orelse continue).asNode();
        const hidden = hidingAncestor(referenced, frame) != null or hiddenState(referenced, frame) != .visible;
        var walk: ContentWalk = .{ .root = referenced, .buf = buf, .frame = frame, .include_hidden = hidden };
        defer walk.deinit();

        const before = buf.written().len;
        try walk.run(.with_root);
        if (buf.written().len > before) wrote = true;
    }
    return wrote;
}

/// Name-from-content of `el` written to `w`. Returns false when the content
/// has no text.
fn writeElementContent(temp_arena: ?*lp.Arena, el: *DOMNode.Element, frame: *Frame, w: anytype) !bool {
    var buf: std.Io.Writer.Allocating = .init(scratchAllocator(temp_arena, frame));
    var walk: ContentWalk = .{ .root = el.asNode(), .buf = &buf, .frame = frame };
    defer walk.deinit();

    try walk.run(.content_only);
    if (isAllWhitespace(buf.written())) return false;
    try writeString(buf.written(), w);
    return true;
}

/// AccName 2F, the text alternative of every node under `root` in tree order,
/// space-separated into `buf`. An element contributes its aria-label (2C), an
/// embedded control's value (2E), an image's alt, else its own content, and as
/// a last resort its title (2I). Hidden elements (aria-hidden, inert,
/// display:none, visibility:hidden) are skipped unless `include_hidden`.
///
/// Iterative: a title only stands in once the element's content turned out to
/// add nothing, so `titles` holds the open ones until `leave` closes them.
const ContentWalk = struct {
    root: *DOMNode,
    buf: *std.Io.Writer.Allocating,
    frame: *Frame,
    /// Set for an aria-labelledby/describedby traversal rooted at a hidden
    /// element: its hidden descendants contribute too (AccName 2A).
    include_hidden: bool = false,
    titles: std.ArrayList(TitleFallback) = .empty,

    const TitleFallback = struct {
        node: *DOMNode,
        title: []const u8,
        // The text length when `node` was entered.
        len: usize,
    };

    fn deinit(self: *ContentWalk) void {
        self.titles.deinit(self.buf.allocator);
    }

    /// `with_root` adds the root's own text alternative (an aria-labelledby
    /// target), `content_only` just its content (the node being named).
    fn run(self: *ContentWalk, mode: enum { with_root, content_only }) !void {
        const root = self.root;
        if (mode == .with_root and !try self.enter(root)) {
            return;
        }

        var node = root.firstChild() orelse return self.leave(root);
        while (true) {
            if (try self.enter(node)) {
                if (node.firstChild()) |child| {
                    node = child;
                    continue;
                }
                try self.leave(node);
            }
            while (node.nextSibling() == null) {
                node = node._parent.?;
                try self.leave(node);
                if (node == root) return;
            }
            node = node.nextSibling().?;
        }
    }

    /// Adds what `node` itself contributes. Returns true when its children
    /// are walked too, `leave` closing it once they are.
    fn enter(self: *ContentWalk, node: *DOMNode) !bool {
        const el = switch (node._type) {
            .element => node.subtype(DOMNode.Element),
            .cdata => {
                const cd = node.subtype(DOMNode.CData);
                if (cd._type == .text) {
                    try appendWord(self.buf, cd._data.str());
                }
                return false;
            },
            else => return false,
        };

        if (node != self.root) {
            // Inside an SVG, only a <title> names it.
            if (node._parent.?.is(DOMNode.Element)) |parent| {
                if (parent.getTag() == .svg) {
                    return std.mem.eql(u8, el.getTagNameLower(), "title");
                }
            }
            if (el.getTag().isMetadata()) {
                return false;
            }
            if (!self.include_hidden and hidesFromContent(el, self.frame)) {
                return false;
            }
        }

        if (el.getAttributeInterned("aria-label")) |aria_label| {
            if (!isAllWhitespace(aria_label)) {
                try appendWord(self.buf, aria_label);
                return false;
            }
        }

        if (try writeEmbeddedControlValue(el, self.buf, self.frame)) {
            return false;
        }

        switch (el.getTag()) {
            // alt="" is a decorative image: it contributes nothing, not even
            // its title.
            .img, .area => if (el.getAttributeInterned("alt")) |alt| {
                try appendWord(self.buf, alt);
                return false;
            },
            .br => {
                try self.buf.writer.writeByte(' ');
                return false;
            },
            else => {},
        }

        if (el.getAttributeInterned("title")) |title| {
            if (!isAllWhitespace(title)) {
                try self.titles.append(self.buf.allocator, .{ .node = node, .title = title, .len = self.buf.written().len });
            }
        }
        return true;
    }

    fn leave(self: *ContentWalk, node: *DOMNode) !void {
        const open = self.titles.getLastOrNull() orelse return;
        if (open.node != node) {
            return;
        }
        _ = self.titles.pop();
        if (self.buf.written().len == open.len) {
            try appendWord(self.buf, open.title);
        }
    }
};

/// Whether `el` keeps its subtree out of the content it sits in: its own
/// aria-hidden, inert or display:none, or a visibility:hidden. Its ancestors
/// up to the named node don't matter, the walk already left those out.
fn hidesFromContent(el: *DOMNode.Element, frame: *Frame) bool {
    if (hidesSubtree(el.asNode())) {
        return true;
    }
    const owner = el.ownerFrame(frame) orelse return false;
    const style_manager = &owner._style_manager;
    return style_manager.hasDisplayNone(el) or style_manager.hasVisibilityHiddenInherited(el);
}

/// AccName 2E: a form control embedded in the traversal contributes its value
/// (textbox, combobox, range). Returns true when `el` is such a control, even
/// if it contributed nothing (a checkbox has no text alternative of its own).
fn writeEmbeddedControlValue(el: *DOMNode.Element, buf: *std.Io.Writer.Allocating, frame: *Frame) !bool {
    switch (el.getTag()) {
        .input => {
            const input = el.as(DOMNode.Element.Html.Input);
            switch (input._input_type) {
                .checkbox, .radio, .hidden, .file, .image => {},
                .reset, .button, .submit => |t| {
                    const v = input.getValue();
                    try appendWord(buf, if (v.len > 0) v else defaultButtonLabel(t) orelse "");
                },
                else => try appendWord(buf, input.getRedactedValue()),
            }
            return true;
        },
        .textarea => {
            try appendWord(buf, el.as(DOMNode.Element.Html.TextArea).getValue());
            return true;
        },
        .select => {
            var it = el.asNode().childrenIterator();
            while (it.next()) |child| {
                const child_el = child.is(DOMNode.Element) orelse continue;
                switch (child_el.getTag()) {
                    .option => if (try appendSelectedOption(child_el, buf, frame)) return true,
                    .optgroup => {
                        var group_it = child.childrenIterator();
                        while (group_it.next()) |grand_child| {
                            const option_el = grand_child.is(DOMNode.Element) orelse continue;
                            if (option_el.getTag() != .option) continue;
                            if (try appendSelectedOption(option_el, buf, frame)) return true;
                        }
                    },
                    else => {},
                }
            }
            return true;
        },
        else => return false,
    }
}

fn appendSelectedOption(option_el: *DOMNode.Element, buf: *std.Io.Writer.Allocating, frame: *Frame) !bool {
    const option = option_el.as(DOMNode.Element.Html.Option);
    if (!option.getSelected()) return false;
    try appendWord(buf, option.getText(frame));
    return true;
}

fn defaultButtonLabel(input_type: @FieldType(DOMNode.Element.Html.Input, "_input_type")) ?[]const u8 {
    return switch (input_type) {
        .submit => "Submit",
        .reset => "Reset",
        else => null,
    };
}

fn appendWord(buf: *std.Io.Writer.Allocating, text: []const u8) !void {
    const trimmed = std.mem.trim(u8, text, &std.ascii.whitespace);
    if (trimmed.len == 0) return;
    try buf.writer.writeAll(trimmed);
    try buf.writer.writeByte(' ');
}

fn firstChildWithTag(node: *DOMNode, tag: DOMNode.Element.Tag) ?*DOMNode.Element {
    var it = node.childrenIterator();
    while (it.next()) |child| {
        const el = child.is(DOMNode.Element) orelse continue;
        if (el.getTag() == tag) return el;
    }
    return null;
}

/// Pre-order walk tracking the outermost aria-hidden or inert ancestor, since
/// TreeWalker leaves subtrees without saying so. CSS needs no tracking: the
/// StyleManager resolves it through flat-tree ancestors. The walk itself stays
/// in the light tree; only the root's ancestors are looked up through the flat
/// tree.
const Walker = struct {
    root: *DOMNode,
    current: *DOMNode,
    frame: *Frame,
    hiding_ancestor: ?*DOMNode,
    depth: i32 = 0,

    fn init(root: *DOMNode, frame: *Frame) Walker {
        return .{ .root = root, .current = root, .frame = frame, .hiding_ancestor = hidingAncestor(root, frame) };
    }

    /// `descend` false skips the current node's children.
    fn next(self: *Walker, descend: bool) ?*DOMNode {
        if (descend) {
            if (self.current.firstChild()) |child| {
                if (self.hiding_ancestor == null and hidesSubtree(self.current)) {
                    self.hiding_ancestor = self.current;
                }
                self.current = child;
                self.depth += 1;
                return child;
            }
        }

        var node = self.current;
        while (node != self.root) {
            if (node.nextSibling()) |sibling| {
                self.current = sibling;
                return sibling;
            }
            node = node._parent.?;
            self.depth -= 1;
            if (node == self.hiding_ancestor) {
                self.hiding_ancestor = null;
            }
        }
        return null;
    }

    /// Only valid for the node `next` just returned, or the root.
    fn hidden(self: *const Walker, node: *DOMNode) Hidden {
        return if (self.hiding_ancestor != null) .pruned else hiddenState(node, self.frame);
    }
};

fn isLabellableTag(tag: DOMNode.Element.Tag) bool {
    return switch (tag) {
        .button, .meter, .output, .progress, .select, .textarea, .input => true,
        else => false,
    };
}

// ARIA roles whose accessible name may be computed from descendant content
// (AccName "name from content"). Decides name-from-content for every element,
// implicit role included: a <div role="heading"> opts in, a <label> or <em>
// (roles that name from author only) stays out. `row` is left out on
// purpose, as Chromium only names rows from content inside a treegrid.
fn nameFromContentRole(role_: ?[]const u8) bool {
    const role = role_ orelse return false;
    const name_for_content_roles = std.StaticStringMap(void).initComptime(.{
        .{ "button", {} },
        .{ "cell", {} },
        .{ "checkbox", {} },
        .{ "columnheader", {} },
        .{ "gridcell", {} },
        .{ "heading", {} },
        .{ "link", {} },
        .{ "menuitem", {} },
        .{ "menuitemcheckbox", {} },
        .{ "menuitemradio", {} },
        .{ "option", {} },
        .{ "radio", {} },
        .{ "rowheader", {} },
        .{ "sectionhead", {} },
        .{ "switch", {} },
        .{ "tab", {} },
        .{ "tooltip", {} },
        .{ "treeitem", {} },
        .{ "term", {} },
    });
    return name_for_content_roles.has(role);
}

// ARIA 1.2 roles for which naming is prohibited. A title on one of these is
// exposed as its description only.
fn nameProhibitedRole(role: []const u8) bool {
    const prohibited = std.StaticStringMap(void).initComptime(.{
        .{ "caption", {} },
        .{ "code", {} },
        .{ "deletion", {} },
        .{ "emphasis", {} },
        .{ "generic", {} },
        .{ "insertion", {} },
        .{ "none", {} },
        .{ "paragraph", {} },
        .{ "presentation", {} },
        .{ "strong", {} },
        .{ "subscript", {} },
        .{ "superscript", {} },
    });
    return prohibited.has(role);
}

/// CSS-only toggle switches and custom radios commonly visually-style a
/// `<label>` while `display:none`-ing the real `<input>`. Chromium matches
/// this by pruning the input from the AX tree, which leaves the label as a
/// generic role=none element and an agent walking the tree has nothing
/// interactive to click.
///
/// When a `<label>` targets a hidden checkbox or radio, promote it: emit
/// the label with the input's role and state. Browsers already forward
/// label clicks to the associated input, inert included, so the label's
/// backendDOMNodeId is a valid click target.
fn labelPromotionTarget(
    axn: AXNode,
    frame: *Frame,
) ?*DOMNode.Element.Html.Input {
    // Respect an explicit role= on the label.
    if (axn.role_attr != null) return null;

    const node = axn.dom;
    const el = node.is(DOMNode.Element) orelse return null;
    if (el.getTag() != .label) return null;

    const label = el.as(DOMNode.Element.Html.Label);
    const control = label.getControl(frame) orelse return null;
    if (control.getTag() != .input) return null;
    const input = control.as(DOMNode.Element.Html.Input);
    switch (input._input_type) {
        .checkbox, .radio => {},
        else => return null,
    }

    const control_node = control.asNode();
    if (hidingAncestor(control_node, frame) == null and hiddenState(control_node, frame) == .visible) {
        return null;
    }
    return input;
}

// HTML-AAM: every <label for> pointing at the control, then a wrapping
// <label> (unless it is one of the former), space-joined.
fn writeLabelName(
    temp_arena: ?*lp.Arena,
    node: *DOMNode,
    el: *DOMNode.Element,
    frame: *Frame,
    label_index: *Label.LabelByForIndex,
    w: anytype,
) !?AXSource {
    var buf: std.Io.Writer.Allocating = .init(scratchAllocator(temp_arena, frame));
    var source: ?AXSource = null;

    const id_value = el.getId() orelse "";
    if (id_value.len > 0) {
        if (node.ownerDocument(frame)) |doc| {
            for (try label_index.lookupAll(doc.asNode(), id_value, frame.call_arena)) |label_el| {
                if (try appendLabelInnerText(&buf, label_el, frame)) source = .label_element;
            }
        }
    }

    if (Label.findWrappingLabel(el)) |wrap_label| {
        const targets_control = if (wrap_label.getAttributeInterned("for")) |for_attr| std.mem.eql(u8, for_attr, id_value) else false;
        if (!targets_control) {
            if (try appendLabelInnerText(&buf, wrap_label, frame)) {
                if (source == null) source = .label_wrap;
            }
        }
    }

    if (source != null) {
        try writeString(buf.written(), w);
    }
    return source;
}

fn appendLabelInnerText(buf: *std.Io.Writer.Allocating, label_el: *DOMNode.Element, frame: *Frame) !bool {
    const before = buf.written().len;
    try label_el.getInnerText(&buf.writer, frame);
    if (isAllWhitespace(buf.written()[before..])) {
        buf.shrinkRetainingCapacity(before);
        return false;
    }
    try buf.writer.writeByte(' ');
    return true;
}

// The `invalid` AX property: aria-invalid's token, "false" when unset or
// unknown.
fn invalidToken(el: *DOMNode.Element) []const u8 {
    const value = el.getAttributeSafe(.wrap("aria-invalid")) orelse return "false";
    const tokens = [_][]const u8{ "true", "grammar", "spelling" };
    for (tokens) |token| {
        if (std.ascii.eqlIgnoreCase(value, token)) return token;
    }
    return "false";
}

// The `level` of a heading: aria-level when valid, else the h1-h6 tag's, else
// 2 for an explicit heading role (the ARIA default).
fn headingLevel(axnode: AXNode, el: *DOMNode.Element) ?usize {
    const role = axnode.getRole() catch return null;
    if (!std.mem.eql(u8, role, "heading")) return null;

    if (el.getAttributeSafe(.wrap("aria-level"))) |aria_level| {
        const level = std.fmt.parseInt(usize, std.mem.trim(u8, aria_level, &std.ascii.whitespace), 10) catch 0;
        if (level >= 1) return level;
    }
    return switch (el.getTag()) {
        .h1 => 1,
        .h2 => 2,
        .h3 => 3,
        .h4 => 4,
        .h5 => 5,
        .h6 => 6,
        else => 2,
    };
}

/// Allocator for throwaway name-resolution buffers: prefers the writer's
/// temp arena so multiple calls reuse its retained page; falls back to
/// `frame.call_arena` on the non-Writer `getName` path.
fn scratchAllocator(temp_arena: ?*lp.Arena, frame: *Frame) std.mem.Allocator {
    return if (temp_arena) |a| a.allocator() else frame.call_arena;
}

/// `invisible` (visibility:hidden) ignores only the node: a descendant can set
/// `visibility: visible`. `pruned` ignores the whole subtree.
const Hidden = enum { visible, invisible, pruned };

/// Text takes its flat-tree parent's state.
fn hiddenState(node: *DOMNode, frame: *Frame) Hidden {
    const elt = node.is(DOMNode.Element) orelse node.flatTreeParentElement(frame) orelse return .visible;
    if (hidesSubtree(elt.asNode())) {
        return .pruned;
    }
    const owner = elt.ownerFrame(frame) orelse return .visible;
    const style_manager = &owner._style_manager;
    if (style_manager.isHidden(elt, .{})) {
        return .pruned;
    }
    return if (style_manager.hasVisibilityHiddenInherited(elt)) .invisible else .visible;
}

/// Not [hidden]: an author display rule can override it, so the StyleManager
/// owns it.
fn hidesSubtree(node: *DOMNode) bool {
    const elt = node.is(DOMNode.Element) orelse return false;
    const aria_hidden = elt.getAttributeInterned("aria-hidden") orelse "";
    return std.ascii.eqlIgnoreCase(aria_hidden, "true") or elt.hasAttributeSafe(comptime .wrap("inert"));
}

/// The first flat-tree ancestor of `node` whose attributes hide its subtree.
fn hidingAncestor(node: *DOMNode, frame: *Frame) ?*DOMNode {
    var current = node.flatTreeParent(frame);
    while (current) |ancestor| : (current = ancestor.flatTreeParent(frame)) {
        if (hidesSubtree(ancestor)) {
            return ancestor;
        }
    }
    return null;
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

// A generic container's answer depends on the ones below it; without a memo,
// a walk asking about every node of a deep chain is O(depth²).
const IgnoreCache = struct {
    allocator: std.mem.Allocator,
    map: std.AutoHashMapUnmanaged(*DOMNode, bool) = .empty,

    /// Keyed on the node alone: never reached under a hiding ancestor (callers
    /// check it first). `root` isn't cached, walks ask about each node once.
    fn isGenericIgnored(self: *IgnoreCache, root: *DOMNode, frame: *Frame) !bool {
        if (self.map.get(root)) |ignored| return ignored;

        var tw = TreeWalker.FullExcludeSelf.init(root, .{});
        const exposed = while (tw.next()) |node| {
            const hidden = hiddenState(node, frame);
            if (hidden == .pruned) {
                tw.skipChildren();
                continue;
            }
            switch (AXNode.fromNode(node).ignoreSelf()) {
                .ignored => tw.skipChildren(),
                .exposed => if (hidden == .visible) break node,
                .generic => {
                    // Until an exposed node turns up under it.
                    const gop = try self.map.getOrPut(self.allocator, node);
                    if (!gop.found_existing) {
                        gop.value_ptr.* = true;
                    } else if (gop.value_ptr.*) {
                        tw.skipChildren();
                    } else {
                        break node;
                    }
                },
            }
        } else return true;

        var node = exposed._parent.?;
        while (node != root) : (node = node._parent.?) {
            self.map.getPtr(node).?.* = false;
        }
        return false;
    }
};

fn isIgnore(self: AXNode, frame: *Frame, cache: *IgnoreCache) !bool {
    return switch (self.ignoreSelf()) {
        .ignored => true,
        .exposed => false,
        .generic => cache.isGenericIgnored(self.dom, frame),
    };
}

/// isIgnore for `self` alone, leaving generic containers to the caller.
fn ignoreSelf(self: AXNode) enum { ignored, exposed, generic } {
    // Don't ignore non-Element node: CData, Document...
    const elt = self.dom.is(DOMNode.Element) orelse return .exposed;
    // Ignore non-HTML elements: svg...
    if (elt._type != .html) {
        return .ignored;
    }

    const tag = elt.getTag();
    switch (tag) {
        // zig fmt: off
        .script, .style, .meta, .link, .title, .base, .head, .noscript,
        .template, .param, .source, .track, .datalist, .col, .colgroup, .html,
        .body
        => return .ignored,
        // zig fmt: on
        .img => {
            // alt="" marks a decorative image. An image with no alt at all
            // is exposed, unnamed, as Chromium does.
            if (elt.getAttributeInterned("alt")) |alt| {
                if (alt.len == 0) return .ignored;
            }
        },
        .input => {
            // Check for hidden inputs
            const input = elt.as(DOMNode.Element.Html.Input);
            if (input._input_type == .hidden) {
                return .ignored;
            }
        },
        else => {},
    }

    if (self.role_attr) |role| {
        if (std.ascii.eqlIgnoreCase(role, "none") or std.ascii.eqlIgnoreCase(role, "presentation")) {
            return .ignored;
        }
    }

    // Generic containers with no semantic value
    if (tag == .div or tag == .span) {
        const has_role = elt.hasAttributeInterned("role");
        const has_aria_label = elt.hasAttributeInterned("aria-label");
        const has_aria_labelledby = elt.hasAttributeSafe(.wrap("aria-labelledby"));

        if (!has_role and !has_aria_label and !has_aria_labelledby) {
            return .generic;
        }
    }

    return .exposed;
}

// The role the node is exposed with: a <label> promoted to stand in for its
// hidden checkbox/radio (see labelPromotionTarget) takes the control's role,
// and is named from its content like one.
fn effectiveRole(self: AXNode, frame: *Frame) []const u8 {
    if (labelPromotionTarget(self, frame)) |input| {
        return switch (input._input_type) {
            .checkbox => "checkbox",
            .radio => "radio",
            else => unreachable,
        };
    }
    return self.getRole() catch "none";
}

pub fn getRole(self: AXNode) ![]const u8 {
    if (self.role_attr) |role_value| {
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

    var buffer = std.Io.Writer.Allocating.init(allocator);
    defer buffer.deinit();

    for (test_cases) |test_case| {
        buffer.clearRetainingCapacity();
        try stripWhitespaces(test_case.value, &buffer.writer);
        try std.testing.expectEqualStrings(test_case.expected, buffer.written());
    }
}

const testing = @import("testing.zig");
/// The first serialized node with `role` (any when null) whose name contains
/// `name_needle`.
fn findNode(nodes: []const std.json.Value, role: ?[]const u8, name_needle: []const u8) ?std.json.ObjectMap {
    for (nodes) |node_val| {
        const obj = node_val.object;
        if (role) |r| {
            const role_val = (obj.get("role") orelse continue).object.get("value") orelse continue;
            if (!std.mem.eql(u8, role_val.string, r)) continue;
        }
        const name_val = (obj.get("name") orelse continue).object.get("value") orelse continue;
        if (name_val == .string and std.mem.find(u8, name_val.string, name_needle) != null) {
            return obj;
        }
    }
    return null;
}

/// The AXValue of a serialized node's property.
fn nodeProperty(node: std.json.ObjectMap, name: []const u8) ?std.json.ObjectMap {
    for ((node.get("properties") orelse return null).array.items) |prop| {
        if (std.mem.eql(u8, prop.object.get("name").?.string, name)) {
            return prop.object.get("value").?.object;
        }
    }
    return null;
}

test "AXNode: writer" {
    var registry = NodeRegistry.init(testing.allocator);
    defer registry.deinit();

    var page = try testing.pageTest("cdp/dom3.html", .{});
    defer page.close();

    const frame = page.frame().?;
    var doc = frame.window._document;

    const node = try registry.register(doc.asNode());
    var label_index: Label.LabelByForIndex = .{};
    const temp_arena = try frame.getArena(.medium, "AXNode");
    defer temp_arena.release();
    const json = try std.json.Stringify.valueAlloc(testing.allocator, Writer{
        .root = node,
        .registry = &registry,
        .frame = frame,
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

    const heading = findNode(nodes, "heading", "") orelse return error.HeadingNodeNotFound;
    const level = nodeProperty(heading, "level") orelse return error.HeadingLevelNotFound;
    try testing.expectEqual("integer", level.get("type").?.string);
    // CDP spec: integer values must be serialized as strings
    try testing.expectEqual(1, level.get("value").?.integer);
}

test "AXNode: writer prunes hidden and resolves labels" {
    var registry = NodeRegistry.init(testing.allocator);
    defer registry.deinit();

    var page = try testing.pageTest("cdp/ax_tree.html", .{});
    defer page.close();

    const frame = page.frame().?;
    var doc = frame.window._document;

    const node = try registry.register(doc.asNode());
    var label_index: Label.LabelByForIndex = .{};
    const temp_arena = try frame.getArena(.medium, "AXNode");
    defer temp_arena.release();
    const json = try std.json.Stringify.valueAlloc(testing.allocator, Writer{
        .root = node,
        .registry = &registry,
        .frame = frame,
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
        "under-inert",
        "in-inert-shadow",
    };
    for (hidden_texts) |bad| {
        try testing.expect(findNode(nodes, null, bad) == null);
    }

    // Visible text is exposed, including under a [hidden] that `display: block`
    // overrides.
    try testing.expect(findNode(nodes, null, "visible-para") != null);
    try testing.expect(findNode(nodes, null, "hidden-overridden") != null);

    // A visibility:visible descendant of a visibility:hidden element is exposed
    const link = findNode(nodes, "link", "visible-in-hidden") orelse return error.LinkNotFound;
    try testing.expectEqual(false, link.get("ignored").?.bool);

    // The search input gets its name from <label for=search-input>.
    try testing.expect(findNode(nodes, "searchbox", "Search") != null);

    // The wrapped input gets its name from its ancestor <label>.
    try testing.expect(findNode(nodes, "textbox", "Wrap") != null);

    // Labels associated with hidden checkboxes/radios are promoted:
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
        // `for=`-associated: checkbox under an inert ancestor.
        .{ .name_needle = "Inert option", .role = "checkbox", .checked = "false" },
    };
    for (expected) |exp| {
        const label = findNode(nodes, exp.role, exp.name_needle) orelse return error.PromotedLabelNotFound;
        const checked = nodeProperty(label, "checked") orelse return error.CheckedPropertyNotFound;
        try testing.expectEqual(exp.checked, checked.get("value").?.string);
    }
}

test "AXNode: Writer query filters by role" {
    var registry = NodeRegistry.init(testing.allocator);
    defer registry.deinit();

    var page = try testing.pageTest("cdp/ax_tree.html", .{});
    defer page.close();

    const frame = page.frame().?;
    var doc = frame.window._document;

    const node = try registry.register(doc.asNode());
    var label_index: Label.LabelByForIndex = .{};
    const temp_arena = try frame.getArena(.medium, "AXNode");
    defer temp_arena.release();

    const json = try std.json.Stringify.valueAlloc(testing.allocator, Writer{
        .root = node,
        .registry = &registry,
        .frame = frame,
        .label_index = &label_index,
        .temp_arena = temp_arena,
        .filter = .{ .role = "heading" },
    }, .{});
    defer testing.allocator.free(json);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();

    const nodes = parsed.value.array.items;
    // Fixture has one <h1>Visible</h1>.
    try testing.expectEqual(1, nodes.len);

    const role_val = nodes[0].object.get("role").?.object.get("value").?.string;
    try testing.expectEqual("heading", role_val);

    const name_val = nodes[0].object.get("name").?.object.get("value").?.string;
    try testing.expectEqual("Visible", name_val);
}

test "AXNode: role attribute token list" {
    var page = try testing.pageTest("cdp/accname.html", .{});
    defer page.close();
    const frame = page.frame().?;

    const div = try frame.window._document.createElement("div", null, frame);
    try Frame.parse.htmlAsChildren(frame, div.asNode(),
        \\<div role="switch checkbox"></div><div role=" heading "></div><h1 role=""></h1>
    );

    var child = div.asNode().firstChild().?;
    try testing.expectEqual("switch", try AXNode.fromNode(child).getRole());
    child = child.nextSibling().?;
    try testing.expectEqual("heading", try AXNode.fromNode(child).getRole());
    child = child.nextSibling().?;
    try testing.expectEqual("heading", try AXNode.fromNode(child).getRole());
}

test "AXNode: writer maps password input to textbox" {
    var registry = NodeRegistry.init(testing.allocator);
    defer registry.deinit();

    var page = try testing.pageTest("cdp/ax_tree.html", .{});
    defer page.close();

    const frame = page.frame().?;
    var doc = frame.window._document;

    const body = (try doc.querySelector(comptime .wrap("body"), frame)).?;

    const password_label = try doc.createElement("label", null, frame);
    try password_label.setAttributeSafe(comptime .wrap("for"), comptime .wrap("pw"), frame);
    try password_label.setInnerText("Password", frame);

    const password_input = try doc.createElement("input", null, frame);
    try password_input.setAttributeSafe(comptime .wrap("id"), comptime .wrap("pw"), frame);
    try password_input.setAttributeSafe(comptime .wrap("type"), comptime .wrap("password"), frame);
    try password_input.setAttributeSafe(comptime .wrap("required"), comptime .wrap(""), frame);

    const hidden_input = try doc.createElement("input", null, frame);
    try hidden_input.setAttributeSafe(comptime .wrap("type"), comptime .wrap("hidden"), frame);

    _ = try body.asNode().appendChild(password_label.asNode(), frame);
    _ = try body.asNode().appendChild(password_input.asNode(), frame);
    _ = try body.asNode().appendChild(hidden_input.asNode(), frame);

    const password_role = try AXNode.fromNode(password_input.asNode()).getRole();
    try testing.expectEqual("textbox", password_role);

    const hidden_role = try AXNode.fromNode(hidden_input.asNode()).getRole();
    try testing.expectEqual("none", hidden_role);

    const node = try registry.register(doc.asNode());
    var label_index: Label.LabelByForIndex = .{};
    const temp_arena = try frame.getArena(.medium, "AXNode");
    defer temp_arena.release();
    const json = try std.json.Stringify.valueAlloc(testing.allocator, Writer{
        .root = node,
        .registry = &registry,
        .frame = frame,
        .label_index = &label_index,
        .temp_arena = temp_arena,
    }, .{});
    defer testing.allocator.free(json);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();

    const textbox = findNode(parsed.value.array.items, "textbox", "Password") orelse return error.PasswordTextboxNodeNotFound;
    try testing.expectEqual(false, textbox.get("ignored").?.bool);
    const required = nodeProperty(textbox, "required") orelse return error.PasswordRequiredPropertyNotFound;
    try testing.expectEqual(true, required.get("value").?.bool);
}

test "AXNode: Writer query filters by accessible name" {
    var registry = NodeRegistry.init(testing.allocator);
    defer registry.deinit();

    var page = try testing.pageTest("cdp/ax_tree.html", .{});
    defer page.close();

    const frame = page.frame().?;
    var doc = frame.window._document;

    const node = try registry.register(doc.asNode());
    var label_index: Label.LabelByForIndex = .{};
    const temp_arena = try frame.getArena(.medium, "AXNode");
    defer temp_arena.release();

    const json = try std.json.Stringify.valueAlloc(testing.allocator, Writer{
        .root = node,
        .registry = &registry,
        .frame = frame,
        .label_index = &label_index,
        .temp_arena = temp_arena,
        .filter = .{ .accessible_name = "Search" },
    }, .{});
    defer testing.allocator.free(json);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();

    const nodes = parsed.value.array.items;
    // Fixture has <label for="search-input">Search</label> — its accessible
    // name is "Search". The label itself plus the input it labels both
    // surface as candidates; verify at least one match with the right name.
    try testing.expect(nodes.len >= 1);
    for (nodes) |n| {
        const name_val = n.object.get("name").?.object.get("value").?.string;
        try testing.expectEqual("Search", name_val);
    }
}

test "AXNode: Writer query and subtree root see a hiding ancestor" {
    var registry = NodeRegistry.init(testing.allocator);
    defer registry.deinit();

    var page = try testing.pageTest("cdp/ax_tree.html", .{});
    defer page.close();

    const frame = page.frame().?;
    var label_index: Label.LabelByForIndex = .{};
    const temp_arena = try frame.getArena(.medium, "AXNode");
    defer temp_arena.release();

    var writer: Writer = .{
        .root = try registry.register(frame.window._document.asNode()),
        .registry = &registry,
        .frame = frame,
        .label_index = &label_index,
        .temp_arena = temp_arena,
        .filter = .{ .accessible_name = "under-inert" },
    };
    const query = try std.json.Stringify.valueAlloc(testing.allocator, writer, .{});
    defer testing.allocator.free(query);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, query, .{});
    defer parsed.deinit();
    // Chrome returns no match (an ignored node has no name); we may, but ignored
    for (parsed.value.array.items) |n| {
        try testing.expectEqual(true, n.object.get("ignored").?.bool);
    }

    const button = (try frame.window._document.querySelector(.wrap("#under-inert"), frame)).?;
    const host = (try frame.window._document.querySelector(.wrap("#inert-host"), frame)).?;
    const shadow_button = host.getShadowRoot(frame).?.getElementById("in-inert-shadow", frame).?;

    writer.filter = null;
    for ([_]*DOMNode.Element{ button, shadow_button }) |root| {
        writer.root = try registry.register(root.asNode());
        const tree = try std.json.Stringify.valueAlloc(testing.allocator, writer, .{});
        defer testing.allocator.free(tree);

        try testing.expect(std.mem.find(u8, tree, "\"ignored\":true") != null);
        try testing.expect(std.mem.find(u8, tree, "\"childIds\":[]") != null);
    }
}

test "AXNode: Writer query combined role+name filter promotes hidden-input labels" {
    var registry = NodeRegistry.init(testing.allocator);
    defer registry.deinit();

    var page = try testing.pageTest("cdp/ax_tree.html", .{});
    defer page.close();

    const frame = page.frame().?;
    var doc = frame.window._document;

    const node = try registry.register(doc.asNode());
    var label_index: Label.LabelByForIndex = .{};
    const temp_arena = try frame.getArena(.medium, "AXNode");
    defer temp_arena.release();

    // Fixture has a CSS-hidden checkbox `<input id="toggle-switch" ...>` plus
    // `<label for="toggle-switch">Enable feature</label>`. Walking finds both:
    //   - the label (role promoted to "checkbox", ignored=false, clickable)
    //   - the hidden input (intrinsic role="checkbox", ignored=true)
    // The label is the actionable target — a real client searching by role
    // would act on the entry with ignored=false.
    const json = try std.json.Stringify.valueAlloc(testing.allocator, Writer{
        .root = node,
        .registry = &registry,
        .frame = frame,
        .label_index = &label_index,
        .temp_arena = temp_arena,
        .filter = .{ .accessible_name = "Enable feature", .role = "checkbox" },
    }, .{});
    defer testing.allocator.free(json);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();

    const nodes = parsed.value.array.items;
    try testing.expect(nodes.len >= 1);

    // Every match has the right role and name.
    var actionable_match = false;
    for (nodes) |n| {
        const role_val = n.object.get("role").?.object.get("value").?.string;
        const name_val = n.object.get("name").?.object.get("value").?.string;
        try testing.expectEqual("checkbox", role_val);
        try testing.expectEqual("Enable feature", name_val);
        if (!n.object.get("ignored").?.bool) actionable_match = true;
    }
    // At least one match must be ignored=false. If the label wasn't promoted,
    // only the hidden input would match (ignored=true) — a regression.
    try testing.expect(actionable_match);
}

test "AXNode: Writer query no match returns empty array" {
    var registry = NodeRegistry.init(testing.allocator);
    defer registry.deinit();

    var page = try testing.pageTest("cdp/ax_tree.html", .{});
    defer page.close();

    const frame = page.frame().?;
    var doc = frame.window._document;

    const node = try registry.register(doc.asNode());
    var label_index: Label.LabelByForIndex = .{};
    const temp_arena = try frame.getArena(.medium, "AXNode");
    defer temp_arena.release();

    const json = try std.json.Stringify.valueAlloc(testing.allocator, Writer{
        .root = node,
        .registry = &registry,
        .frame = frame,
        .label_index = &label_index,
        .temp_arena = temp_arena,
        .filter = .{ .role = "marquee" },
    }, .{});
    defer testing.allocator.free(json);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();

    try testing.expectEqual(0, parsed.value.array.items.len);
}

test "AXNode: nameFromContentRole" {
    try testing.expect(nameFromContentRole("heading"));
    try testing.expect(nameFromContentRole("button"));
    try testing.expect(nameFromContentRole("link"));
    try testing.expect(nameFromContentRole("presentation") == false);
    try testing.expect(nameFromContentRole(null) == false);
}

test "AXNode: getName name-from-content honors explicit role" {
    var page = try testing.pageTest("cdp/accname.html", .{});
    defer page.close();

    const frame = page.frame().?;
    var doc = frame.window._document;

    const Case = struct { selector: []const u8, expected: ?[]const u8 };
    const cases = [_]Case{
        // Explicit name-from-content role opts a div/span into name-from-content.
        .{ .selector = "#heading", .expected = "Hello World" },
        .{ .selector = "#button", .expected = "Click me" },
        // Recurses through child elements; the space here is real source whitespace.
        .{ .selector = "#nested", .expected = "Read more" },
        .{ .selector = "#empty_label", .expected = "Sat 10" },
        .{ .selector = "#blank_label", .expected = "Pick" },
        .{ .selector = "#set_label", .expected = "Saturday" },
        // No role, or a non-name-from-content role: no name from contents.
        .{ .selector = "#plain", .expected = null },
        .{ .selector = "#pres", .expected = null },
    };

    for (cases) |c| {
        const el = (try doc.querySelector(.wrap(c.selector), frame)).?;
        const axn = AXNode.fromNode(el.asNode());
        var labels: Label.LabelByForIndex = .{};
        const name = try axn.getName(frame, testing.allocator, &labels);
        defer if (name) |n| testing.allocator.free(n);

        if (c.expected) |exp| {
            try testing.expect(name != null);
            try testing.expectEqual(exp, name.?);
        } else {
            try testing.expect(name == null);
        }
    }
}

test "AXNode: getName follows AccName precedence and hidden rules" {
    var page = try testing.pageTest("cdp/accname.html", .{});
    defer page.close();

    const frame = page.frame().?;
    var doc = frame.window._document;

    const Case = struct { selector: []const u8, expected: ?[]const u8 };
    const cases = [_]Case{
        // 2F: aria-hidden, display:none and hidden descendants don't contribute.
        .{ .selector = "#hidden-child", .expected = "Click me" },
        // 2C: a whitespace-only aria-label is no label; contents win.
        .{ .selector = "#empty-label", .expected = "Fallback" },
        // 2C on a child: its aria-label replaces its contents.
        .{ .selector = "#child-label", .expected = "Inner label" },
        // 2B/2A: a hidden reference contributes, hidden descendants included.
        .{ .selector = "#labelledby-hidden", .expected = "Hidden deep ref" },
        // 2B: the reference's own aria-labelledby is not followed.
        .{ .selector = "#labelledby-nested", .expected = "A" },
        // 2B: self-reference and ordering.
        .{ .selector = "#labelledby-self", .expected = "Me B" },
        // 2E: a referenced text control contributes its value.
        .{ .selector = "#labelledby-control", .expected = "typed" },
        // 2E: embedded controls in the contents contribute their value.
        .{ .selector = "#embedded", .expected = "typed Two" },
        // 2I in the contents: a child's title stands in when it adds no
        // text, the innermost one first.
        .{ .selector = "#child-title", .expected = "Go Tip" },
        .{ .selector = "#nested-title", .expected = "Inner" },
        // Only an SVG's <title> names it; visibility:hidden content is hidden.
        .{ .selector = "#svg-title", .expected = "Close" },
        .{ .selector = "#invisible-child", .expected = "Shown" },
        // HTML-AAM: <legend>, <caption>, every <label for>, a wrapping label
        // that is also the `for` label counts once.
        .{ .selector = "#fieldset", .expected = "Legend text" },
        .{ .selector = "#table", .expected = "Caption text" },
        .{ .selector = "#cell", .expected = "Cell text" },
        .{ .selector = "#two-labels", .expected = "First Second" },
        .{ .selector = "#wrapped-for", .expected = "Outer label" },
        // 2I: the title names roles that can be named, not the prohibited ones.
        .{ .selector = "#title-link", .expected = "Link title" },
        .{ .selector = "#title-span", .expected = null },
        .{ .selector = "#title-em", .expected = null },
        .{ .selector = "#both", .expected = "Both" },
        // Default button labels.
        .{ .selector = "#submit-default", .expected = "Submit" },
        .{ .selector = "#reset-default", .expected = "Reset" },
        // Author-only roles take no name from their contents.
        .{ .selector = "#sel", .expected = null },
        .{ .selector = "#plain-label", .expected = null },
    };

    for (cases) |c| {
        const el = (try doc.querySelector(.wrap(c.selector), frame)).?;
        const axn = AXNode.fromNode(el.asNode());
        var labels: Label.LabelByForIndex = .{};
        const name = try axn.getName(frame, testing.allocator, &labels);
        defer if (name) |n| testing.allocator.free(n);

        if (c.expected) |exp| {
            if (name == null) {
                std.debug.print("{s}: expected \"{s}\", got null\n", .{ c.selector, exp });
                return error.TestUnexpectedResult;
            }
            testing.expectEqual(exp, name.?) catch |err| {
                std.debug.print("{s}: expected \"{s}\", got \"{s}\"\n", .{ c.selector, exp, name.? });
                return err;
            };
        } else if (name != null) {
            std.debug.print("{s}: expected null, got \"{s}\"\n", .{ c.selector, name.? });
            return error.TestUnexpectedResult;
        }
    }
}

test "AXNode: writer emits descriptions and ARIA properties" {
    var registry = NodeRegistry.init(testing.allocator);
    defer registry.deinit();

    var page = try testing.pageTest("cdp/accname.html", .{});
    defer page.close();

    const frame = page.frame().?;
    var doc = frame.window._document;

    const root = try registry.register(doc.asNode());
    var label_index: Label.LabelByForIndex = .{};
    const temp_arena = try frame.getArena(.medium, "AXNode");
    defer temp_arena.release();
    const json = try std.json.Stringify.valueAlloc(testing.allocator, Writer{
        .root = root,
        .registry = &registry,
        .frame = frame,
        .label_index = &label_index,
        .temp_arena = temp_arena,
    }, .{});
    defer testing.allocator.free(json);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    const nodes = parsed.value.array.items;

    const Case = struct {
        selector: []const u8,
        description: ?[]const u8 = null,
        // AX property name -> expected `value.value`, as its JSON text.
        property: ?[]const u8 = null,
        value: ?[]const u8 = null,
        ignored: bool = false,
    };
    const cases = [_]Case{
        .{ .selector = "#described", .description = "First desc Second desc", .property = "describedby", .value = "\"desc-1 desc-2\"" },
        .{ .selector = "#aria-description", .description = "Described inline" },
        // The title is the description when it isn't the name.
        .{ .selector = "#title-span", .description = "Span title" },
        .{ .selector = "#both", .description = "Ti" },
        .{ .selector = "#title-link", .description = null },
        .{ .selector = "#labelledby-self", .property = "labelledby", .value = "\"labelledby-self ref-b\"" },
        .{ .selector = "#lvl", .property = "level", .value = "4" },
        .{ .selector = "#lvl-default", .property = "level", .value = "2" },
        .{ .selector = "#h3-override", .property = "level", .value = "5" },
        .{ .selector = "#invalid", .property = "invalid", .value = "\"true\"" },
        .{ .selector = "#rd", .property = "roledescription", .value = "\"Fancy\"" },
        // A value-less checkbox has no value; only alt="" images are decorative.
        .{ .selector = "#wrapped-for", .property = "checked", .value = "\"false\"" },
        .{ .selector = "#no-alt", .ignored = false },
        .{ .selector = "#empty-alt", .ignored = true },
    };

    for (cases) |c| {
        const el = (try doc.querySelector(.wrap(c.selector), frame)).?;
        const backend_id = (try registry.register(el.asNode())).id;

        var found: ?std.json.ObjectMap = null;
        for (nodes) |node_val| {
            const obj = node_val.object;
            if (obj.get("backendDOMNodeId").?.integer == backend_id) {
                found = obj;
                break;
            }
        }
        const obj = found orelse {
            std.debug.print("{s}: not in the AX tree\n", .{c.selector});
            return error.TestUnexpectedResult;
        };

        try testing.expectEqual(c.ignored, obj.get("ignored").?.bool);
        if (c.ignored) continue;

        const description: ?[]const u8 = if (obj.get("description")) |d| d.object.get("value").?.string else null;
        if (c.description) |expected| {
            testing.expectEqual(expected, description orelse "<none>") catch |err| {
                std.debug.print("{s}: description\n", .{c.selector});
                return err;
            };
        } else if (description != null) {
            std.debug.print("{s}: unexpected description \"{s}\"\n", .{ c.selector, description.? });
            return error.TestUnexpectedResult;
        }

        if (c.property) |property| {
            var value: ?[]const u8 = null;
            for (obj.get("properties").?.array.items) |prop| {
                if (!std.mem.eql(u8, prop.object.get("name").?.string, property)) continue;
                value = try std.json.Stringify.valueAlloc(testing.allocator, prop.object.get("value").?.object.get("value").?, .{});
                break;
            }
            defer if (value) |v| testing.allocator.free(v);
            testing.expectEqual(c.value.?, value orelse "<missing>") catch |err| {
                std.debug.print("{s}: property {s}\n", .{ c.selector, property });
                return err;
            };
        }
    }
}

test "AXNode: writer prunes children when root is hidden" {
    var registry = NodeRegistry.init(testing.allocator);
    defer registry.deinit();

    var page = try testing.pageTest("cdp/ax_tree.html", .{});
    defer page.close();

    const frame = page.frame().?;
    const el = (try frame.window._document.querySelector(.wrap("#d-none"), frame)).?;
    const node = try registry.register(el.asNode());
    var label_index: Label.LabelByForIndex = .{};
    const temp_arena = try frame.getArena(.medium, "AXNode");
    defer temp_arena.release();

    const json = try std.json.Stringify.valueAlloc(testing.allocator, Writer{
        .root = node,
        .registry = &registry,
        .frame = frame,
        .label_index = &label_index,
        .temp_arena = temp_arena,
    }, .{});
    defer testing.allocator.free(json);

    try testing.expect(std.mem.find(u8, json, "under-display-none") == null);
    try testing.expect(std.mem.find(u8, json, "\"childIds\":[]") != null);
}

test "AXNode: writer depth cuts every branch at the same level" {
    var registry = NodeRegistry.init(testing.allocator);
    defer registry.deinit();

    var page = try testing.pageTest("cdp/ax_depth.html", .{});
    defer page.close();

    const frame = page.frame().?;
    const node = try registry.register(frame.window._document.asNode());
    var label_index: Label.LabelByForIndex = .{};
    const temp_arena = try frame.getArena(.medium, "AXNode");
    defer temp_arena.release();

    // document(0) > html(1) > body(2) > div, ul, button(3) > p, li, text(4) > text(5)
    {
        const json = try std.json.Stringify.valueAlloc(testing.allocator, Writer{
            .root = node,
            .registry = &registry,
            .frame = frame,
            .label_index = &label_index,
            .temp_arena = temp_arena,
            .depth = 3,
        }, .{});
        defer testing.allocator.free(json);

        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
        defer parsed.deinit();
        const nodes = parsed.value.array.items;

        // Every branch reaches depth 3, not only the first one.
        try testing.expect(findNode(nodes, "list", "") != null);
        try testing.expect(findNode(nodes, "button", "btn") != null);
        // Nothing below depth 3.
        try testing.expect(findNode(nodes, "paragraph", "") == null);
        try testing.expect(findNode(nodes, "listitem", "") == null);
        try testing.expect(findNode(nodes, "StaticText", "btn") == null);
    }

    {
        const json = try std.json.Stringify.valueAlloc(testing.allocator, Writer{
            .root = node,
            .registry = &registry,
            .frame = frame,
            .label_index = &label_index,
            .temp_arena = temp_arena,
            .depth = 4,
        }, .{});
        defer testing.allocator.free(json);

        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
        defer parsed.deinit();
        const nodes = parsed.value.array.items;

        try testing.expect(findNode(nodes, "paragraph", "") != null);
        try testing.expect(findNode(nodes, "listitem", "") != null);
        try testing.expect(findNode(nodes, "StaticText", "btn") != null);
        // Nothing below depth 4.
        try testing.expect(findNode(nodes, "StaticText", "one") == null);
        try testing.expect(findNode(nodes, "StaticText", "item-a") == null);
    }
}

test "AXNode: generic containers share memoized ignore answers" {
    const frame = try testing.base.createFrame();
    defer testing.base.test_session.closeAllPages();

    const root = try frame.window._document.createElement("div", null, frame);
    // #b holds only a decorative image; the text under #d exposes #c and #d.
    try root.setInnerHTML(
        \\<div id="a"><div id="b"><img alt=""></div><div id="c"><span id="d">text</span></div></div>
    , frame);

    var cache: IgnoreCache = .{ .allocator = testing.arena_allocator };
    const expected = [_]struct { []const u8, bool }{ .{ "#a", false }, .{ "#b", true }, .{ "#c", false }, .{ "#d", false } };
    for (expected) |e| {
        const el = (try root.querySelector(e[0], frame)).?;
        try testing.expectEqual(e[1], try AXNode.fromNode(el.asNode()).isIgnore(frame, &cache));
    }
    // Filled by #a's scan.
    try testing.expectEqual(3, cache.map.count());

    var fresh: IgnoreCache = .{ .allocator = testing.arena_allocator };
    for (expected[1..]) |e| {
        const el = (try root.querySelector(e[0], frame)).?;
        try testing.expectEqual(e[1], try AXNode.fromNode(el.asNode()).isIgnore(frame, &fresh));
    }
}

test "AXNode: aria-hidden is case-insensitive" {
    const frame = try testing.base.createFrame();
    defer testing.base.test_session.closeAllPages();

    const root = try frame.window._document.createElement("div", null, frame);
    try root.setInnerHTML(
        \\<div id="hidden-upper" aria-hidden="TRUE"><p>hidden-upper</p></div>
        \\<div id="hidden-mixed" aria-hidden="True"><p>hidden-mixed</p></div>
        \\<div id="visible-false" aria-hidden="false"><p>visible-false</p></div>
    , frame);

    const hidden_upper = (try root.querySelector("#hidden-upper", frame)).?;
    const hidden_mixed = (try root.querySelector("#hidden-mixed", frame)).?;
    const visible_false = (try root.querySelector("#visible-false", frame)).?;

    try testing.expect(hidesSubtree(hidden_upper.asNode()));
    try testing.expect(hidesSubtree(hidden_mixed.asNode()));
    try testing.expect(!hidesSubtree(visible_false.asNode()));

    var registry = NodeRegistry.init(testing.allocator);
    defer registry.deinit();

    const node = try registry.register(root.asNode());
    var label_index: Label.LabelByForIndex = .{};
    const temp_arena = try frame.getArena(.medium, "AXNode");
    defer temp_arena.release();

    const json = try std.json.Stringify.valueAlloc(testing.allocator, Writer{
        .root = node,
        .registry = &registry,
        .frame = frame,
        .label_index = &label_index,
        .temp_arena = temp_arena,
    }, .{});
    defer testing.allocator.free(json);

    try testing.expect(std.mem.find(u8, json, "hidden-upper") == null);
    try testing.expect(std.mem.find(u8, json, "hidden-mixed") == null);
    try testing.expect(std.mem.find(u8, json, "visible-false") != null);
}
