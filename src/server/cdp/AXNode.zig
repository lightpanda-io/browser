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
    // When null, emit the nodes `scope` selects. When set, walk the
    // subtree visiting all nodes (including AX-ignored ones, per the
    // queryAXTree spec) and emit only nodes whose role + accessible name
    // match the filter, in a flat shape.
    filter: ?Filter = null,
    depth: i32 = 0,
    scope: Scope = .subtree,

    // Which nodes around `root` to emit when there's no filter.
    pub const Scope = enum {
        // `root` and its descendants, down to `depth` (getFullAXTree).
        subtree,
        // `root` alone.
        node,
        // `root` alone, as a bare AXNode rather than a list (getRootAXNode).
        bare_node,
        // `root`, its children unless it's ignored, then its ancestors
        // (getPartialAXTree with fetchRelatives).
        relatives,
        // `root`, then each ancestor up to its frame's document
        // (getAXNodeAndAncestors). Like getFullAXTree, this stays in the
        // frame: clients stitch frames together themselves.
        ancestors,
        // The children of `root`, and through an ignored child its own
        // (getChildAXNodes).
        children,
    };

    // What writeNode wrote: whether the node's children follow it, and
    // whether it's ignored.
    const Written = struct {
        children: bool,
        ignored: bool,
    };

    pub const Filter = struct {
        role: ?[]const u8 = null,
        accessible_name: ?[]const u8 = null,
    };

    pub const Opts = struct {
        depth: i32 = 0,
        filter: ?Filter = null,
        scope: Scope = .subtree,
    };

    const ResolvedRole = struct {
        role: []const u8,
        // Non-null when the current node is a <label> whose target control is
        // a hidden checkbox/radio. Callers use this to emit the control's
        // checked/disabled properties on the promoted label.
        promoted_input: ?*DOMNode.Element.Html.Input,
    };

    // A writer bound to `frame`, the frame that owns `root`.
    pub fn init(frame: *Frame, root: *const NodeRegistry.Node, registry: *NodeRegistry, temp_arena: *lp.Arena, opts: Opts) !Writer {
        const label_index = try frame.call_arena.create(Label.LabelByForIndex);
        label_index.* = .{};
        return .{
            .frame = frame,
            .root = root,
            .registry = registry,
            .label_index = label_index,
            .temp_arena = temp_arena,
            .filter = opts.filter,
            .depth = opts.depth,
            .scope = opts.scope,
        };
    }

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

        if (self.scope == .bare_node) {
            return self.writeScope(&ignore_cache, w);
        }
        try w.beginArray();
        if (self.filter != null) {
            try self.walkQuery(&ignore_cache, w);
        } else {
            try self.writeScope(&ignore_cache, w);
        }
        return w.endArray();
    }

    fn writeScope(self: *const Writer, ignore_cache: *IgnoreCache, w: anytype) !void {
        if (self.scope == .subtree) {
            return self.writeTree(ignore_cache, w);
        }

        // Every other scope is about a node in the AX tree. A node outside it
        // is a lone ignored node under its nearest ancestor in the tree, and
        // has no children.
        const root = self.root.dom;
        const nearest = self.nearestInTree(root);
        const in_tree = if (nearest) |n| n == root else false;
        if (!in_tree) {
            switch (self.scope) {
                .subtree => unreachable,
                .children => {},
                .node, .bare_node => try self.writeNotRendered(nearest, w),
                .ancestors, .relatives => {
                    try self.writeNotRendered(nearest, w);
                    if (nearest) |n| try self.writeAncestors(n, ignore_cache, w);
                },
            }
            return;
        }

        switch (self.scope) {
            .subtree => unreachable,
            .node, .bare_node => _ = try self.writeSingle(root, ignore_cache, w),
            .ancestors => try self.writeAncestors(root, ignore_cache, w),
            // Like Chrome: the node, its children unless it's ignored, then
            // its ancestors.
            .relatives => {
                const written = try self.writeSingle(root, ignore_cache, w);
                if (written.children and !written.ignored) {
                    try self.writeChildren(root, ignore_cache, w);
                }
                if (root.flatParent(self.frame)) |parent| {
                    try self.writeAncestors(parent, ignore_cache, w);
                }
            },
            .children => if (!AXNode.fromNode(root).ignoreChildren()) {
                try self.writeChildren(root, ignore_cache, w);
            },
        }
    }

    // `node` when it's in the AX tree, else its nearest ancestor that is. Null
    // when no document is above it (detached, template content). A node is in
    // the tree when each step up to the document is one childIds lists.
    fn nearestInTree(self: *const Writer, node: *DOMNode) ?*DOMNode {
        var nearest: ?*DOMNode = null;
        // display:none hides the whole subtree: once a node isn't hidden, its
        // ancestors aren't either.
        var displayed = false;
        var current = node;
        while (current.flatParent(self.frame)) |parent| : (current = parent) {
            // An unslotted child of a host, or unused slot fallback: the flat
            // tree skips it, though flatParent still finds the parent.
            var listed = !current.isOutsideFlatTree() and
                !AXNode.fromNode(parent).ignoreChildren() and
                isAXChildType(current, ignoreText(parent)) and
                !hidesSubtree(current);
            if (listed and !displayed) {
                displayed = hiddenState(current, self.frame) != .pruned;
                listed = displayed;
            }
            if (!listed) {
                nearest = null;
            } else if (nearest == null) {
                nearest = current;
            }
        }
        if (current._type != .document) {
            return null;
        }
        return nearest orelse current;
    }

    // Chrome's AXNode for a DOM node outside the AX tree. `parent` is its
    // nearest ancestor in the tree, which doesn't list it in its childIds.
    fn writeNotRendered(self: *const Writer, parent: ?*DOMNode, w: anytype) !void {
        const id = self.root.id;
        try w.beginObject();
        try w.objectField("nodeId");
        try writeIdString(id, w);
        try w.objectField("backendDOMNodeId");
        try w.write(id);
        try w.objectField("role");
        try self.writeAXValue(.{ .role = "none" }, w);
        try w.objectField("ignored");
        try w.write(true);
        try self.writeIgnoredReason("notRendered", w);
        if (parent) |p| {
            try w.objectField("parentId");
            try writeIdString((try self.registry.register(p)).id, w);
        }
        try w.objectField("childIds");
        try w.beginArray();
        try w.endArray();
        try w.endObject();
    }

    // The ignoredReasons field of an ignored node, with the one reason.
    fn writeIgnoredReason(self: *const Writer, reason: []const u8, w: anytype) !void {
        try w.objectField("ignoredReasons");
        try w.beginArray();
        try w.beginObject();
        try w.objectField("name");
        try w.write(reason);
        try w.objectField("value");
        try self.writeAXValue(.{ .boolean = true }, w);
        try w.endObject();
        try w.endArray();
    }

    // Write `dom`, a node in the AX tree, without its descendants.
    fn writeSingle(self: *const Writer, dom: *DOMNode, ignore_cache: *IgnoreCache, w: anytype) !Written {
        const node = try self.registry.register(dom);
        return self.writeNode(node.id, .fromNode(dom), hiddenState(dom, self.frame), ignore_cache, w);
    }

    // `start`, a node in the AX tree, then each ancestor up to its frame's
    // document.
    fn writeAncestors(self: *const Writer, start: *DOMNode, ignore_cache: *IgnoreCache, w: anytype) !void {
        var current: ?*DOMNode = start;
        while (current) |node| : (current = node.flatParent(self.frame)) {
            _ = try self.writeSingle(node, ignore_cache, w);
        }
    }

    // The nodes in `parent`'s childIds and, through an ignored one, its own
    // children, like Chrome's getChildAXNodes. `parent` must be in the AX
    // tree and show its children.
    fn writeChildren(self: *const Writer, parent: *DOMNode, ignore_cache: *IgnoreCache, w: anytype) !void {
        var walker: Walker = .init(parent, self.frame);
        return self.writeDescendants(&walker, .ignored, ignore_cache, w);
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
        const root = self.root.dom;
        var walker: Walker = .init(root, self.frame);
        const written = try self.writeNode(self.root.id, .fromNode(root), walker.hidden(root), ignore_cache, w);
        if (written.children) {
            try self.writeDescendants(&walker, .all, ignore_cache, w);
        }
    }

    // Which nodes writeDescendants enters: every one (down to `depth`), or
    // only ignored ones.
    const Follow = enum { all, ignored };

    // Write the AX nodes under the walker's root, which shows its children,
    // in pre-order: its ListMarker first, then each node, followed by its
    // marker and the nodes `follow` enters.
    fn writeDescendants(self: *const Writer, walker: *Walker, follow: Follow, ignore_cache: *IgnoreCache, w: anytype) !void {
        try self.writeListMarker(walker.root, w);
        var descend = true;
        while (walker.next(descend)) |dom_node| {
            descend = false;
            if (self.depth > 0 and self.depth < walker.depth) continue;

            // Only text needs its parent's ignoreText.
            const skip_text = dom_node._type == .cdata and ignoreText(dom_node.flatParent(self.frame).?);
            if (!isAXChildType(dom_node, skip_text)) {
                continue;
            }
            const hidden = walker.hidden(dom_node);
            if (hidden == .pruned) {
                continue;
            }
            const node = try self.registry.register(dom_node);
            const written = try self.writeNode(node.id, .fromNode(dom_node), hidden, ignore_cache, w);
            descend = written.children and (follow == .all or written.ignored);
            // The marker is a child: drop it with the others at the depth
            // cut-off.
            if (descend and (self.depth <= 0 or walker.depth < self.depth)) {
                try self.writeListMarker(dom_node, w);
            }
        }
    }

    // The tree walk follows an <li> with its synthetic ListMarker node. A
    // no-op for any other node: see hasListMarker.
    fn writeListMarker(self: *const Writer, li_node: *DOMNode, w: anytype) !void {
        if (!hasListMarker(li_node)) {
            return;
        }
        const parent = li_node._parent.?;
        const list_type = parent.as(DOMNode.Element).getTag();

        const li = try self.registry.register(li_node);

        // Write the ListMarker node. It has no DOM node, so no
        // backendDOMNodeId.
        try w.beginObject();

        try w.objectField("nodeId");
        try writeIdString(try self.registry.listMarkerId(li), w);

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

        try w.objectField("parentId");
        try writeIdString(li.id, w);

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

    pub const AriaState = enum { true, false, mixed };

    /// Like Chrome, any other token, even " false ", reads as true.
    fn parseAriaState(value: []const u8) AriaState {
        if (value.len == 0 or std.ascii.eqlIgnoreCase(value, "false")) return .false;
        if (std.ascii.eqlIgnoreCase(value, "mixed")) return .mixed;
        return .true;
    }

    const RoleStates = struct {
        expanded: bool = false,
        // Only tri-state roles keep aria-checked="mixed"; the rest read it as false.
        checked: ?enum { binary, tri_state } = null,
        // Options and tree items are only checkable once aria-checked is set.
        checked_needs_attr: bool = false,
    };

    fn roleStates(role: []const u8) RoleStates {
        const max_len = "menuitemcheckbox".len;
        if (role.len > max_len) return .{};
        var buf: [max_len]u8 = undefined;
        const roles = std.StaticStringMap(RoleStates).initComptime(.{
            .{ "application", RoleStates{ .expanded = true } },
            .{ "button", RoleStates{ .expanded = true } },
            .{ "checkbox", RoleStates{ .expanded = true, .checked = .tri_state } },
            .{ "columnheader", RoleStates{ .expanded = true } },
            .{ "combobox", RoleStates{ .expanded = true } },
            .{ "gridcell", RoleStates{ .expanded = true } },
            .{ "link", RoleStates{ .expanded = true } },
            .{ "listbox", RoleStates{ .expanded = true } },
            .{ "listitem", RoleStates{ .expanded = true } },
            .{ "menuitem", RoleStates{ .expanded = true } },
            .{ "menuitemcheckbox", RoleStates{ .expanded = true, .checked = .tri_state } },
            .{ "menuitemradio", RoleStates{ .expanded = true, .checked = .binary } },
            .{ "option", RoleStates{ .checked = .tri_state, .checked_needs_attr = true } },
            .{ "radio", RoleStates{ .checked = .binary } },
            .{ "row", RoleStates{ .expanded = true } },
            .{ "rowheader", RoleStates{ .expanded = true } },
            .{ "switch", RoleStates{ .expanded = true, .checked = .binary } },
            .{ "tab", RoleStates{ .expanded = true } },
            .{ "treeitem", RoleStates{ .expanded = true, .checked = .tri_state, .checked_needs_attr = true } },
        });
        return roles.get(std.ascii.lowerString(&buf, role)) orelse .{};
    }

    // Native input checked state remains owned by the input serializer.
    pub const AriaProperties = struct {
        expanded: ?bool = null,
        checked: ?AriaState = null,
    };

    pub fn ariaProperties(el: *DOMNode.Element, role: []const u8) AriaProperties {
        const states = roleStates(role);
        var props: AriaProperties = .{};
        if (states.expanded and el.getTag() != .select) {
            const raw = el.getAttributeInterned("aria-expanded") orelse "";
            if (raw.len != 0) props.expanded = parseAriaState(raw) != .false;
        }
        if (states.checked) |kind| {
            const raw = el.getAttributeSafe(.wrap("aria-checked")) orelse "";
            if (el.getTag() != .input and (raw.len != 0 or !states.checked_needs_attr)) {
                const state = parseAriaState(raw);
                props.checked = if (state == .mixed and kind == .binary) .false else state;
            }
        }
        return props;
    }

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
                switch (el.getTag()) {
                    .h1 => try self.writeAXProperty(.{ .name = .level, .value = .{ .integer = 1 } }, w),
                    .h2 => try self.writeAXProperty(.{ .name = .level, .value = .{ .integer = 2 } }, w),
                    .h3 => try self.writeAXProperty(.{ .name = .level, .value = .{ .integer = 3 } }, w),
                    .h4 => try self.writeAXProperty(.{ .name = .level, .value = .{ .integer = 4 } }, w),
                    .h5 => try self.writeAXProperty(.{ .name = .level, .value = .{ .integer = 5 } }, w),
                    .h6 => try self.writeAXProperty(.{ .name = .level, .value = .{ .integer = 6 } }, w),
                    .img => {
                        const img = el.as(DOMNode.Element.Html.Image);
                        const uri = try img.getSrc(self.frame);
                        if (uri.len != 0) {
                            try self.writeAXProperty(.{ .name = .url, .value = .{ .string = uri } }, w);
                        }
                    },
                    .a => {
                        const a = el.as(DOMNode.Element.Html.Anchor);
                        const uri = try a.getHref(self.frame);
                        if (uri.len != 0) {
                            try self.writeAXProperty(.{ .name = .url, .value = .{ .string = uri } }, w);
                        }
                    },
                    .input => {
                        const input = el.as(DOMNode.Element.Html.Input);
                        const is_disabled = el.isDisabled();
                        const is_readonly = el.hasAttributeInterned("readonly");

                        if (is_disabled) {
                            try self.writeAXProperty(.{ .name = .disabled, .value = .{ .boolean = true } }, w);
                        }
                        try self.writeAXProperty(.{ .name = .invalid, .value = .{ .token = "false" } }, w);
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
                                try self.writeAXProperty(.{ .name = .checked, .value = .{ .token = if (input._checked) "true" else "false" } }, w);
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
                        try self.writeAXProperty(.{ .name = .invalid, .value = .{ .token = "false" } }, w);
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

                        if (option.getSelected()) {
                            try self.writeAXProperty(.{ .name = .selected, .value = .{ .booleanOrUndefined = true } }, w);
                        }
                    },
                    .button => {
                        const is_disabled = el.isDisabled();
                        if (is_disabled) {
                            try self.writeAXProperty(.{ .name = .disabled, .value = .{ .boolean = true } }, w);
                        }
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

                // Resolved roles gate states. Native select/input states are handled above.
                const aria = ariaProperties(el, try axnode.getRole());
                if (aria.expanded) |expanded| {
                    try self.writeAXProperty(.{ .name = .expanded, .value = .{ .booleanOrUndefined = expanded } }, w);
                }
                if (aria.checked) |checked| {
                    try self.writeAXProperty(.{ .name = .checked, .value = .{ .token = @tagName(checked) } }, w);
                }

                // Hidden and inert nodes never reach here, so tabindex alone decides.
                switch (el.getTag()) {
                    .input, .textarea, .select, .button, .option => {},
                    else => if (el.focusTabIndex() != null) {
                        try self.writeAXProperty(.{ .name = .focusable, .value = .{ .booleanOrUndefined = true } }, w);
                    },
                }
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

    fn writeNode(self: *const Writer, id: u32, axn: AXNode, hidden: Hidden, ignore_cache: *IgnoreCache, w: anytype) !Written {
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
            try self.writeIgnoredReason("uninteresting", w);
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
        if (n.flatParent(self.frame)) |p| {
            const parent_node = try self.registry.register(p);
            try w.objectField("parentId");
            try writeIdString(parent_node.id, w);
        }

        // Children
        const write_children = axn.ignoreChildren() == false and hidden != .pruned;

        try w.objectField("childIds");
        try w.beginArray();
        if (write_children) {
            var it: AXChildren = .init(n, self.frame);
            while (it.next()) |child| {
                const child_id = switch (child) {
                    .marker => try self.registry.listMarkerId(try self.registry.register(n)),
                    .node => |c| (try self.registry.register(c.dom)).id,
                };
                try writeIdString(child_id, w);
            }
        }
        try w.endArray();

        try w.endObject();

        return .{ .children = write_children, .ignored = ignore };
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

                    if (doc.getElementById(trimmed_id)) |referenced_el| {
                        // Get the text content of the referenced element
                        try referenced_el.getInnerText(&buf.writer, frame);
                        try buf.writer.writeByte(' ');
                        has_content = true;
                    }
                }

                if (has_content) {
                    try writeString(buf.written(), w);
                    return .aria_labelledby;
                }
            }

            // A blank aria-label is ignored (accname 2D), so the name comes
            // from content instead.
            const aria_label = el.getAttributeInterned("aria-label") orelse "";
            if (!isAllWhitespace(aria_label)) {
                try w.write(aria_label);
                return .aria_label;
            }

            if (isLabellableTag(el.getTag())) {
                if (try writeLabelName(temp_arena, node, el, frame, label_index, w)) |source| {
                    return source;
                }
            }

            if (el.getAttributeInterned("alt")) |alt| {
                try w.write(alt);
                return .alt;
            }

            const use_name_for_content: bool = switch (el.getTag()) {
                .br => {
                    try writeString("\n", w);
                    return .contents;
                },
                .input => blk: {
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
                    break :blk false;
                },
                // zig fmt: off
                .textarea, .select, .img, .audio, .video, .iframe, .embed,
                .object, .progress, .meter, .main, .nav, .aside, .header,
                .footer, .form, .section, .article, .ul, .ol, .dl, .menu,
                .thead, .tbody, .tfoot, .tr, .td, .div, .span, .p, .details, .li,
                .style, .script, .html, .body,
                // zig fmt: on
                => nameFromContentRole(axnode.role_attr),
                else => true,
            };

            if (use_name_for_content) {
                var buf: std.Io.Writer.Allocating = .init(scratchAllocator(temp_arena, frame));
                try writeAccessibleNameFallback(node, &buf.writer, frame);
                if (buf.written().len > 0) {
                    try writeString(buf.written(), w);
                    return .contents;
                }
            }

            if (el.getAttributeInterned("title")) |title| {
                try w.write(title);
                return .title;
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

fn writeAccessibleNameFallback(node: *DOMNode, writer: *std.Io.Writer, frame: *const Frame) !void {
    var tw: TreeWalker.FlatExcludeSelf = .init(node, .{ .frame = frame });
    while (tw.next()) |child| {
        const parent = child.flatParent(frame).?;
        const in_svg = if (parent.is(DOMNode.Element)) |p| p.getTag() == .svg else false;
        if (in_svg and parent != node) {
            // Inside an SVG, only a <title> names it
            const is_title = if (child.is(DOMNode.Element)) |el| std.mem.eql(u8, el.getTagNameLower(), "title") else false;
            if (is_title) {
                try writer.writeByte(' ');
            } else {
                tw.skipChildren();
            }
            continue;
        }

        switch (child._type) {
            .cdata => {
                const cd = child.subtype(DOMNode.CData);
                if (cd._type == .text) {
                    const content = std.mem.trim(u8, cd._data.str(), &std.ascii.whitespace);
                    if (content.len > 0) {
                        try writer.writeAll(content);
                        try writer.writeByte(' ');
                    }
                }
            },
            .element => {
                const el = child.subtype(DOMNode.Element);
                const tag = el.getTag();
                if (tag == .img) {
                    if (el.getAttributeSafe(.wrap("alt"))) |alt| {
                        try writer.writeAll(alt);
                        try writer.writeByte(' ');
                    }
                    tw.skipChildren();
                } else if (tag != .svg and tag.isMetadata()) {
                    tw.skipChildren();
                }
            },
            else => {},
        }
    }
}

/// Pre-order walk tracking the outermost aria-hidden or inert ancestor, since
/// TreeWalker leaves subtrees without saying so. CSS needs no tracking: the
/// StyleManager resolves it through flat-tree ancestors. Walks the flat tree,
/// like Chrome's AX tree: shadow content under its host, slotted nodes under
/// their slot, unslotted light children skipped.
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
            if (self.current.flatFirstChild(self.frame)) |child| {
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
            if (node.flatNextSibling(self.frame)) |sibling| {
                self.current = sibling;
                return sibling;
            }
            node = node.flatParent(self.frame).?;
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
// (AccName "name from content"). Used so an explicit role can opt a host
// element back into name-from-content when its tag wouldn't otherwise — e.g.
// <div role="heading"> or <span role="button">.
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
        .{ "row", {} },
        .{ "rowheader", {} },
        .{ "switch", {} },
        .{ "tab", {} },
        .{ "tooltip", {} },
        .{ "treeitem", {} },
        .{ "term", {} },
    });
    return name_for_content_roles.has(role);
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
    const control = label.getControl() orelse return null;
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

fn writeLabelName(
    temp_arena: ?*lp.Arena,
    node: *DOMNode,
    el: *DOMNode.Element,
    frame: *Frame,
    label_index: *Label.LabelByForIndex,
    w: anytype,
) !?AXSource {
    if (el.getId()) |id_value| {
        if (id_value.len > 0) {
            if (node.ownerDocument(frame)) |doc| {
                if (try label_index.lookup(doc.asNode(), id_value, frame.call_arena)) |label_el| {
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
    temp_arena: ?*lp.Arena,
    label_el: *DOMNode.Element,
    frame: *Frame,
    w: anytype,
) !bool {
    var buf: std.Io.Writer.Allocating = .init(scratchAllocator(temp_arena, frame));
    try label_el.getInnerText(&buf.writer, frame);
    const text = std.mem.trim(u8, buf.written(), &std.ascii.whitespace);
    if (text.len == 0) return false;
    try writeString(text, w);
    return true;
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

/// Whether the tree has a ListMarker node for `node`: an <li> of a list.
pub fn hasListMarker(node: *DOMNode) bool {
    const el = node.is(DOMNode.Element) orelse return false;
    if (el.getTag() != .li) {
        return false;
    }
    const parent = (node._parent orelse return false).is(DOMNode.Element) orelse return false;
    return switch (parent.getTag()) {
        .ul, .ol, .menu => true,
        else => false,
    };
}

/// Whether a flat child of this type can be an AX node: an element, or text
/// unless `skip_text` (ignoreText of the parent). Pruning aside, these are
/// the nodes writeTree walks and childIds lists.
fn isAXChildType(child: *DOMNode, skip_text: bool) bool {
    return child.is(DOMNode.Element) != null or (child.is(DOMNode.CData.Text) != null and !skip_text);
}

/// The hidden state of `child` when it appears in its parent's childIds,
/// null when it doesn't. `skip_text` is ignoreText of the parent.
fn axChildHidden(child: *DOMNode, skip_text: bool, frame: *Frame) ?Hidden {
    if (!isAXChildType(child, skip_text)) {
        return null;
    }
    const hidden = hiddenState(child, frame);
    return if (hidden == .pruned) null else hidden;
}

/// The entries of a node's childIds, in order: an <li>'s ListMarker, then
/// each flat child in the AX tree. The caller checks the node shows its
/// children at all (ignoreChildren, pruning).
const AXChildren = struct {
    parent: *DOMNode,
    frame: *Frame,
    skip_text: bool,
    marker_pending: bool,
    it: TreeWalker.FlatChildren,

    const Child = union(enum) {
        marker,
        node: struct { dom: *DOMNode, hidden: Hidden },
    };

    fn init(parent: *DOMNode, frame: *Frame) AXChildren {
        return .{
            .parent = parent,
            .frame = frame,
            .skip_text = ignoreText(parent),
            .marker_pending = hasListMarker(parent),
            .it = .init(parent, .{ .frame = frame }),
        };
    }

    fn next(self: *AXChildren) ?Child {
        if (self.marker_pending) {
            self.marker_pending = false;
            return .marker;
        }
        while (self.it.next()) |child| {
            const hidden = axChildHidden(child, self.skip_text, self.frame) orelse continue;
            return .{ .node = .{ .dom = child, .hidden = hidden } };
        }
        return null;
    }
};

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
        // An <iframe>'s content is another frame's tree; its DOM children
        // are only fallback text.
        .head, .script, .style, .iframe => true,
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

        var tw: TreeWalker.FlatExcludeSelf = .init(root, .{ .frame = frame });
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

        var node = exposed.flatParent(frame).?;
        while (node != root) : (node = node.flatParent(frame).?) {
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
            // Check for empty decorative images
            const alt_ = elt.getAttributeInterned("alt");
            if (alt_ == null or alt_.?.len == 0) {
                return .ignored;
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
    const json = try std.json.Stringify.valueAlloc(testing.arena_allocator, Writer{
        .root = node,
        .registry = &registry,
        .frame = frame,
        .label_index = &label_index,
        .temp_arena = temp_arena,
    }, .{});

    // Check that the document node is present with proper structure
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, testing.arena_allocator, json, .{});

    const nodes = parsed.array.items;
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
    const json = try std.json.Stringify.valueAlloc(testing.arena_allocator, Writer{
        .root = node,
        .registry = &registry,
        .frame = frame,
        .label_index = &label_index,
        .temp_arena = temp_arena,
    }, .{});

    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, testing.arena_allocator, json, .{});
    const nodes = parsed.array.items;

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

    const json = try std.json.Stringify.valueAlloc(testing.arena_allocator, Writer{
        .root = node,
        .registry = &registry,
        .frame = frame,
        .label_index = &label_index,
        .temp_arena = temp_arena,
        .filter = .{ .role = "heading" },
    }, .{});

    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, testing.arena_allocator, json, .{});

    const nodes = parsed.array.items;
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
    const json = try std.json.Stringify.valueAlloc(testing.arena_allocator, Writer{
        .root = node,
        .registry = &registry,
        .frame = frame,
        .label_index = &label_index,
        .temp_arena = temp_arena,
    }, .{});

    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, testing.arena_allocator, json, .{});

    const textbox = findNode(parsed.array.items, "textbox", "Password") orelse return error.PasswordTextboxNodeNotFound;
    try testing.expectEqual(false, textbox.get("ignored").?.bool);
    const required = nodeProperty(textbox, "required") orelse return error.PasswordRequiredPropertyNotFound;
    try testing.expectEqual(true, required.get("value").?.bool);
}

test "AXNode: writer reports the current checked state, not the attribute" {
    var registry = NodeRegistry.init(testing.allocator);
    defer registry.deinit();

    var page = try testing.pageTest("cdp/ax_tree.html", .{});
    defer page.close();

    const frame = page.frame().?;
    var doc = frame.window._document;

    const body = (try doc.querySelector(comptime .wrap("body"), frame)).?;

    const Case = struct { label: []const u8, type: []const u8, attribute: bool, checked: bool };
    const cases = [_]Case{
        .{ .label = "Unticked box", .type = "checkbox", .attribute = true, .checked = false },
        .{ .label = "Ticked box", .type = "checkbox", .attribute = false, .checked = true },
        .{ .label = "Picked radio", .type = "radio", .attribute = false, .checked = true },
    };
    for (cases) |case| {
        const label = try doc.createElement("label", null, frame);
        const input = try doc.createElement("input", null, frame);
        try input.setAttributeSafe(comptime .wrap("type"), .wrap(case.type), frame);
        if (case.attribute) {
            try input.setAttributeSafe(comptime .wrap("checked"), comptime .wrap(""), frame);
        }
        try input.as(DOMNode.Element.Html.Input).setChecked(case.checked, frame);
        _ = try label.asNode().appendChild(input.asNode(), frame);
        _ = try label.asNode().appendChild(try doc.createTextNode(case.label), frame);
        _ = try body.asNode().appendChild(label.asNode(), frame);
    }

    const node = try registry.register(doc.asNode());
    var label_index: Label.LabelByForIndex = .{};
    const temp_arena = try frame.getArena(.medium, "AXNode");
    defer temp_arena.release();
    const json = try std.json.Stringify.valueAlloc(testing.arena_allocator, Writer{
        .root = node,
        .registry = &registry,
        .frame = frame,
        .label_index = &label_index,
        .temp_arena = temp_arena,
    }, .{});

    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, testing.arena_allocator, json, .{});

    for (cases) |case| {
        const ax = findNode(parsed.array.items, case.type, case.label) orelse return error.InputNotFound;
        const checked = nodeProperty(ax, "checked") orelse return error.CheckedPropertyNotFound;
        try testing.expectEqual(if (case.checked) "true" else "false", checked.get("value").?.string);
    }
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

    const json = try std.json.Stringify.valueAlloc(testing.arena_allocator, Writer{
        .root = node,
        .registry = &registry,
        .frame = frame,
        .label_index = &label_index,
        .temp_arena = temp_arena,
        .filter = .{ .accessible_name = "Search" },
    }, .{});

    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, testing.arena_allocator, json, .{});

    const nodes = parsed.array.items;
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
    const query = try std.json.Stringify.valueAlloc(testing.arena_allocator, writer, .{});

    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, testing.arena_allocator, query, .{});
    // Chrome returns no match (an ignored node has no name); we may, but ignored
    for (parsed.array.items) |n| {
        try testing.expectEqual(true, n.object.get("ignored").?.bool);
    }

    const button = (try frame.window._document.querySelector(.wrap("#under-inert"), frame)).?;
    const host = (try frame.window._document.querySelector(.wrap("#inert-host"), frame)).?;
    const shadow_button = host.getShadowRoot(frame).?.getElementById("in-inert-shadow").?;

    writer.filter = null;
    for ([_]*DOMNode.Element{ button, shadow_button }) |root| {
        writer.root = try registry.register(root.asNode());
        const tree = try std.json.Stringify.valueAlloc(testing.arena_allocator, writer, .{});

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
    const json = try std.json.Stringify.valueAlloc(testing.arena_allocator, Writer{
        .root = node,
        .registry = &registry,
        .frame = frame,
        .label_index = &label_index,
        .temp_arena = temp_arena,
        .filter = .{ .accessible_name = "Enable feature", .role = "checkbox" },
    }, .{});

    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, testing.arena_allocator, json, .{});

    const nodes = parsed.array.items;
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

    const json = try std.json.Stringify.valueAlloc(testing.arena_allocator, Writer{
        .root = node,
        .registry = &registry,
        .frame = frame,
        .label_index = &label_index,
        .temp_arena = temp_arena,
        .filter = .{ .role = "marquee" },
    }, .{});

    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, testing.arena_allocator, json, .{});

    try testing.expectEqual(0, parsed.array.items.len);
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

    const json = try std.json.Stringify.valueAlloc(testing.arena_allocator, Writer{
        .root = node,
        .registry = &registry,
        .frame = frame,
        .label_index = &label_index,
        .temp_arena = temp_arena,
    }, .{});

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
        const json = try std.json.Stringify.valueAlloc(testing.arena_allocator, Writer{
            .root = node,
            .registry = &registry,
            .frame = frame,
            .label_index = &label_index,
            .temp_arena = temp_arena,
            .depth = 3,
        }, .{});

        const parsed = try std.json.parseFromSliceLeaky(std.json.Value, testing.arena_allocator, json, .{});
        const nodes = parsed.array.items;

        // Every branch reaches depth 3, not only the first one.
        try testing.expect(findNode(nodes, "list", "") != null);
        try testing.expect(findNode(nodes, "button", "btn") != null);
        // Nothing below depth 3.
        try testing.expect(findNode(nodes, "paragraph", "") == null);
        try testing.expect(findNode(nodes, "listitem", "") == null);
        try testing.expect(findNode(nodes, "StaticText", "btn") == null);
    }

    {
        const json = try std.json.Stringify.valueAlloc(testing.arena_allocator, Writer{
            .root = node,
            .registry = &registry,
            .frame = frame,
            .label_index = &label_index,
            .temp_arena = temp_arena,
            .depth = 4,
        }, .{});

        const parsed = try std.json.parseFromSliceLeaky(std.json.Value, testing.arena_allocator, json, .{});
        const nodes = parsed.array.items;

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
        \\<div id="a"><div id="b"><img></div><div id="c"><span id="d">text</span></div></div>
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

    const json = try std.json.Stringify.valueAlloc(testing.arena_allocator, Writer{
        .root = node,
        .registry = &registry,
        .frame = frame,
        .label_index = &label_index,
        .temp_arena = temp_arena,
    }, .{});

    try testing.expect(std.mem.find(u8, json, "hidden-upper") == null);
    try testing.expect(std.mem.find(u8, json, "hidden-mixed") == null);
    try testing.expect(std.mem.find(u8, json, "visible-false") != null);
}

test "AXNode: custom ARIA states and tabindex focusability" {
    var registry = NodeRegistry.init(testing.allocator);
    defer registry.deinit();

    var page = try testing.pageTest("cdp/ax_aria_states.html", .{});
    defer page.close();

    const frame = page.frame().?;
    var label_index: Label.LabelByForIndex = .{};
    const temp_arena = try frame.getArena(.medium, "AXNode");
    defer temp_arena.release();

    const node = try registry.register(frame.window._document.asNode());
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

    const Case = struct { role: ?[]const u8, name: []const u8, property: []const u8, value: ?std.json.Value };
    const cases = [_]Case{
        .{ .role = "button", .name = "Expanded details", .property = "expanded", .value = .{ .bool = true } },
        .{ .role = "button", .name = "Collapsed details", .property = "expanded", .value = .{ .bool = false } },
        .{ .role = "button", .name = "Invalid details", .property = "expanded", .value = .{ .bool = true } },
        .{ .role = "button", .name = "Spaced expanded", .property = "expanded", .value = .{ .bool = true } },
        .{ .role = "button", .name = "Empty expanded", .property = "expanded", .value = null },
        .{ .role = "listitem", .name = "Listitem expanded", .property = "expanded", .value = .{ .bool = true } },
        .{ .role = "button", .name = "Uppercase expanded", .property = "expanded", .value = .{ .bool = true } },
        .{ .role = "button", .name = "Uppercase collapsed", .property = "expanded", .value = .{ .bool = false } },
        .{ .role = null, .name = "Generic expanded", .property = "expanded", .value = null },
        .{ .role = "button", .name = "Custom anchor", .property = "expanded", .value = .{ .bool = true } },
        .{ .role = "button", .name = "Custom image", .property = "expanded", .value = .{ .bool = true } },
        .{ .role = "switch", .name = "Expanded switch", .property = "expanded", .value = .{ .bool = true } },

        .{ .role = "checkbox", .name = "Mixed terms", .property = "checked", .value = .{ .string = "mixed" } },
        .{ .role = "checkbox", .name = "Checked terms", .property = "checked", .value = .{ .string = "true" } },
        .{ .role = "checkbox", .name = "Unfocusable terms", .property = "checked", .value = .{ .string = "false" } },
        .{ .role = "checkbox", .name = "Invalid state", .property = "checked", .value = .{ .string = "true" } },
        .{ .role = "checkbox", .name = "Empty checked", .property = "checked", .value = .{ .string = "false" } },
        .{ .role = "checkbox", .name = "Spaced checked", .property = "checked", .value = .{ .string = "true" } },
        .{ .role = "option", .name = "Option checked", .property = "checked", .value = .{ .string = "true" } },
        .{ .role = "option", .name = "Option mixed", .property = "checked", .value = .{ .string = "mixed" } },
        .{ .role = "treeitem", .name = "Treeitem checked", .property = "checked", .value = .{ .string = "true" } },
        .{ .role = "treeitem", .name = "Treeitem checked", .property = "expanded", .value = .{ .bool = false } },
        .{ .role = "option", .name = "Option absent", .property = "checked", .value = null },
        .{ .role = "option", .name = "Native option", .property = "checked", .value = null },
        .{ .role = "treeitem", .name = "Treeitem absent", .property = "checked", .value = null },
        .{ .role = "checkbox", .name = "Padded false", .property = "checked", .value = .{ .string = "true" } },
        .{ .role = "checkbox", .name = "Blank checked", .property = "checked", .value = .{ .string = "true" } },
        .{ .role = "button", .name = "Padded collapsed", .property = "expanded", .value = .{ .bool = true } },
        .{ .role = "button", .name = "Blank expanded", .property = "expanded", .value = .{ .bool = true } },
        .{ .role = "checkbox", .name = "Uppercase mixed", .property = "checked", .value = .{ .string = "mixed" } },
        .{ .role = "checkbox", .name = "Absent checked", .property = "checked", .value = .{ .string = "false" } },
        .{ .role = "checkbox", .name = "Native terms", .property = "checked", .value = .{ .string = "true" } },
        .{ .role = "switch", .name = "Switch checked", .property = "checked", .value = .{ .string = "true" } },
        .{ .role = "switch", .name = "Switch mixed", .property = "checked", .value = .{ .string = "false" } },
        .{ .role = "menuitemcheckbox", .name = "Menu checkbox checked", .property = "checked", .value = .{ .string = "true" } },
        .{ .role = "menuitemcheckbox", .name = "Menu checkbox mixed", .property = "checked", .value = .{ .string = "mixed" } },
        .{ .role = "radio", .name = "Radio unchecked", .property = "checked", .value = .{ .string = "false" } },
        .{ .role = "radio", .name = "Radio absent", .property = "checked", .value = .{ .string = "false" } },
        .{ .role = "menuitemradio", .name = "Menu radio checked", .property = "checked", .value = .{ .string = "true" } },

        .{ .role = "checkbox", .name = "Mixed terms", .property = "focusable", .value = .{ .bool = true } },
        // A negative tabindex is focusable through script, but not Tab navigation.
        .{ .role = "checkbox", .name = "Checked terms", .property = "focusable", .value = .{ .bool = true } },
        .{ .role = "checkbox", .name = "Unfocusable terms", .property = "focusable", .value = null },
        .{ .role = "checkbox", .name = "Invalid state", .property = "focusable", .value = null },
        .{ .role = "button", .name = "Custom anchor", .property = "focusable", .value = .{ .bool = true } },
        .{ .role = "link", .name = "Plain link", .property = "focusable", .value = .{ .bool = true } },
    };
    for (cases) |case| {
        const ax_node = findNode(nodes, case.role, case.name) orelse return error.NodeNotFound;
        const actual = if (nodeProperty(ax_node, case.property)) |property| property.get("value").? else null;
        const expected = case.value orelse {
            try testing.expect(actual == null);
            continue;
        };
        const value = actual orelse return error.PropertyNotFound;
        switch (expected) {
            .bool => |b| try testing.expectEqual(b, value.bool),
            .string => |s| try testing.expectEqual(s, value.string),
            else => unreachable,
        }
    }

    // Native input serialization already includes checked; do not emit it twice.
    const native = findNode(nodes, "checkbox", "Native terms") orelse return error.NativeCheckboxNotFound;
    var checked_count: usize = 0;
    for (native.get("properties").?.array.items) |property| {
        if (std.mem.eql(u8, property.object.get("name").?.string, "checked")) {
            checked_count += 1;
        }
    }
    try testing.expectEqual(1, checked_count);

    try testing.expect(findNode(nodes, "checkbox", "Inert terms") == null);
    try testing.expect(findNode(nodes, "checkbox", "Hidden terms") == null);
}

test "AXNode: writer walks the flat tree" {
    var registry = NodeRegistry.init(testing.allocator);
    defer registry.deinit();

    var page = try testing.pageTest("cdp/shadow_dom.html", .{});
    defer page.close();

    const frame = page.frame().?;
    const doc = frame.window._document;

    var label_index: Label.LabelByForIndex = .{};
    const temp_arena = try frame.getArena(.medium, "AXNode");
    defer temp_arena.release();
    const json = try std.json.Stringify.valueAlloc(testing.arena_allocator, Writer{
        .root = try registry.register(doc.asNode()),
        .registry = &registry,
        .frame = frame,
        .label_index = &label_index,
        .temp_arena = temp_arena,
    }, .{});
    const nodes = (try std.json.parseFromSliceLeaky(std.json.Value, testing.arena_allocator, json, .{})).array.items;

    try testing.expect(findNode(nodes, "textbox", "Coupon code") != null);
    try testing.expect(findNode(nodes, "button", "in-closed") != null);
    try testing.expect(findNode(nodes, "StaticText", "slotted-text") != null);
    try testing.expect(findNode(nodes, null, "unslotted-text") == null);

    // Shadow content hangs off the host; the shadow root isn't an AX node.
    const host = doc.getElementById("coupon").?;
    var host_id_buf: [10]u8 = undefined;
    const host_id = try std.fmt.bufPrint(&host_id_buf, "{d}", .{(try registry.register(host.asNode())).id});

    const apply = findNode(nodes, "button", "Apply") orelse return error.ApplyNotFound;
    try testing.expectEqual(host_id, apply.get("parentId").?.string);

    const apply_id = apply.get("nodeId").?.string;
    for (nodes) |n| {
        if (std.mem.eql(u8, n.object.get("nodeId").?.string, host_id)) {
            for (n.object.get("childIds").?.array.items) |cid| {
                if (std.mem.eql(u8, cid.string, apply_id)) break;
            } else return error.ApplyNotChildOfHost;
            break;
        }
    } else return error.HostNotFound;
}
