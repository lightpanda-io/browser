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

const interactive = @import("browser/interactive.zig");
const SelectorPath = @import("browser/SelectorPath.zig");

const CData = @import("browser/webapi/CData.zig");
const Element = @import("browser/webapi/Element.zig");
const Label = @import("browser/webapi/element/html/Label.zig");
const Node = @import("browser/webapi/Node.zig");
const AXNode = @import("server/cdp/AXNode.zig");

const NodeRegistry = @import("NodeRegistry.zig");
const isAllWhitespace = @import("string.zig").isAllWhitespace;

const log = lp.log;
const Frame = lp.Frame;

const Self = @This();

dom_node: *Node,
registry: *NodeRegistry,
frame: *Frame, // we never visit iframes, every node we visit is in the same frame as dom_node
arena: std.mem.Allocator,
prune: bool,
interactive_only: bool,
max_depth: u32,
max_bytes: ?u32,

pub const Opts = struct {
    prune: bool = true,
    interactive_only: bool = false,
    max_depth: u32 = std.math.maxInt(u32) - 1,
    // Text output only.
    max_bytes: ?u32 = null,
};

/// `frame` only seeds the owner lookup; the tree is walked with the frame
/// that owns `node`. A node whose document has no frame (DOMParser, XHR, or
/// a frame that has since navigated away) has no styles or layout to
/// describe.
pub fn init(arena: std.mem.Allocator, node: *Node, registry: *NodeRegistry, frame: *Frame, opts: Opts) error{FramelessNode}!Self {
    return .{
        .dom_node = node,
        .registry = registry,
        .frame = node.ownerFrame(frame) orelse return error.FramelessNode,
        .arena = arena,
        .prune = opts.prune,
        .interactive_only = opts.interactive_only,
        .max_depth = opts.max_depth,
        .max_bytes = opts.max_bytes,
    };
}

/// Walk the pruned tree with `visitor`: `visit(*Node, *NodeData) !Walk`
/// says which descendants to visit, `leave() !void` closes a
/// visited node. An optional `visitPruned(*Node, *NodeData) !bool` sees the
/// nodes pruning skips, and returns whether to get a `leave()` for it too.
fn visitAll(self: @This(), visitor: anytype) error{WriteFailed}!void {
    var xpath_buffer: std.ArrayList(u8) = .empty;
    const listener_targets = interactive.buildListenerTargetMap(self.frame, self.arena) catch |err| {
        log.err(.app, "listener map failed", .{ .err = err });
        return error.WriteFailed;
    };
    var label_index: Label.LabelByForIndex = .{};
    var ctx: WalkContext = .{
        .xpath_buffer = &xpath_buffer,
        .listener_targets = listener_targets,
        .label_index = &label_index,
    };
    self.walk(&ctx, visitor) catch |err| {
        log.err(.app, "semantic tree walk failed", .{ .err = err });
        return error.WriteFailed;
    };
}

pub fn jsonStringify(self: @This(), jw: *std.json.Stringify) error{WriteFailed}!void {
    var visitor = JsonVisitor{ .jw = jw, .tree = self };
    return self.visitAll(&visitor);
}

/// Past `max_bytes`, lines are kept by priority, records round-robin, and
/// dropped lines are counted in `[more]` markers.
pub fn textStringify(self: @This(), writer: *std.Io.Writer) error{WriteFailed}!void {
    const max_bytes = self.max_bytes orelse {
        var visitor: TextVisitor = .{ .writer = writer };
        return self.visitAll(&visitor);
    };
    var collector: LineCollector = .{
        .arena = self.arena,
        .text = .init(self.arena),
        .focused = if (self.frame.document._active_element) |el| el.asNode() else null,
    };
    try self.visitAll(&collector);
    const text = collector.text.written();
    if (text.len <= max_bytes) return writer.writeAll(text);
    const budget: Budget = Budget.init(self.arena, text, collector.lines.items, max_bytes) catch return error.WriteFailed;
    try budget.render(self.arena, writer);
}

const TextVisitor = struct {
    writer: *std.Io.Writer,
    depth: u32 = 0,

    pub fn visit(self: *TextVisitor, node: *Node, data: *NodeData) !Walk {
        try self.writer.splatByteAll(' ', self.depth);
        const line = try writeTextLine(self.writer, node, data);
        try self.writer.writeByte('\n');
        self.depth += 1;
        return line.children;
    }

    pub fn leave(self: *TextVisitor) !void {
        self.depth -= 1;
    }
};

const Priority = enum(u3) { critical, heading, named, text, chrome };

const Line = struct {
    id: NodeRegistry.Id,
    // Into the collector's text buffer, indent and newline included.
    start: u32,
    end: u32,
    depth: u32,
    parent: ?u32,
    priority: Priority,
    // Says something itself (a name, text or value), not only through children.
    contentful: bool,
    // A pruned row, list or landmark, or the pruned walk root: never printed,
    // but it groups its lines into a record and scopes their markers.
    hidden: bool,
    // Inside an alert or status message, all of which is critical.
    critical_subtree: bool,
    // Inside site navigation, all of which ranks last unless critical.
    chrome_subtree: bool,
    subtree_len: u32 = 1,
    // Printed lines in the subtree, this one included.
    printed_len: u32,

    fn childDepth(line: Line) u32 {
        return line.depth + @intFromBool(!line.hidden);
    }

    fn printedBelow(line: Line) u32 {
        return line.printed_len - @intFromBool(!line.hidden);
    }
};

const LineCollector = struct {
    arena: std.mem.Allocator,
    text: std.Io.Writer.Allocating,
    focused: ?*Node,
    lines: std.ArrayList(Line) = .empty,
    current: ?u32 = null,

    pub fn visit(self: *LineCollector, node: *Node, data: *NodeData) !Walk {
        const start = self.text.written().len;
        try self.text.writer.splatByteAll(' ', self.depth());
        const line = try writeTextLine(&self.text.writer, node, data);
        try self.text.writer.writeByte('\n');
        try self.append(data, start, .{
            .hidden = false,
            .contentful = line.contentful,
            .priority = linePriority(node, data, self.focused),
        });
        return line.children;
    }

    pub fn visitPruned(self: *LineCollector, _: *Node, data: *NodeData) !bool {
        // The walk root always gets a line, so the output has a single top.
        const anchor = (structural_roles.get(data.role) orelse .wrapper) == .anchor;
        if (self.current != null and !anchor) return false;
        try self.append(data, self.text.written().len, .{ .hidden = true, .contentful = false, .priority = .text });
        return true;
    }

    pub fn leave(self: *LineCollector) !void {
        const index = self.current.?;
        const line = &self.lines.items[index];
        line.subtree_len = @intCast(self.lines.items.len - index);
        self.current = line.parent;
        if (line.parent) |p| self.lines.items[p].printed_len += line.printed_len;
    }

    const Own = struct { hidden: bool, contentful: bool, priority: Priority };

    fn append(self: *LineCollector, data: *const NodeData, start: usize, own: Own) !void {
        const inherited = if (self.current) |p| self.lines.items[p].critical_subtree else false;
        const role_scope = critical_roles.get(data.role);
        const critical = inherited or role_scope != null;
        const chrome = (if (self.current) |p| self.lines.items[p].chrome_subtree else false) or chrome_roles.has(data.role);
        try self.lines.append(self.arena, .{
            .id = data.id,
            .start = @intCast(start),
            .end = @intCast(self.text.written().len),
            .depth = self.depth(),
            .parent = self.current,
            .priority = if (critical) .critical else if (chrome) .chrome else own.priority,
            .contentful = own.contentful,
            .hidden = own.hidden,
            .critical_subtree = inherited or role_scope == .subtree,
            .chrome_subtree = chrome,
            .printed_len = @intFromBool(!own.hidden),
        });
        self.current = @intCast(self.lines.items.len - 1);
    }

    fn depth(self: *const LineCollector) u32 {
        return if (self.current) |p| self.lines.items[p].childDepth() else 0;
    }
};

// Ordered: an inner scope can widen an outer one, never narrow it.
const critical_roles = std.StaticStringMap(enum { self, subtree }).initComptime(.{
    // Their message is their children.
    .{ "alert", .subtree },
    .{ "status", .subtree },
    // External stylesheets are off by default, so a menu or drawer that an
    // author class hides still looks like an open dialog: promoting its
    // controls would hand them the budget.
    .{ "dialog", .self },
    .{ "alertdialog", .self },
});

// Menus and footers often come before the content, with more links than it.
// A banner is left out: it holds the search box and the cart.
const chrome_roles = std.StaticStringMap(void).initComptime(.{
    .{ "navigation", {} },
    .{ "complementary", {} },
    .{ "contentinfo", {} },
});

fn linePriority(node: *Node, data: *const NodeData, focused: ?*Node) Priority {
    if (focused == node) return .critical;
    if (node.is(Element)) |el| {
        if (std.mem.eql(u8, el.getAttributeSafe(comptime .wrap("aria-invalid")) orelse "", "true")) return .critical;
    }
    if (data.value != null or data.options != null or data.checked != null or data.aria.expanded != null or data.aria.checked != null) return .named;
    const named = data.name != null and data.name.?.len > 0;
    // Headings outline the page, and a record's title is often one.
    if (named and std.mem.eql(u8, data.role, "heading")) return .heading;
    if (named and !std.mem.eql(u8, data.role, "StaticText")) return .named;
    return .text;
}

const Budget = struct {
    text: []const u8,
    lines: []const Line,
    kept: []bool,
    // For a kept line: how many printed lines have it as their nearest kept ancestor.
    omitted: []u32,

    fn init(arena: std.mem.Allocator, text: []const u8, lines: []const Line, max_bytes: usize) !Budget {
        var self: Budget = .{
            .text = text,
            .lines = lines,
            .kept = try arena.alloc(bool, lines.len),
            .omitted = try arena.alloc(u32, lines.len),
        };
        @memset(self.kept, false);
        @memset(self.omitted, 0);

        // The walk root is always kept, so a tiny budget can still be exceeded.
        const root = lines[0];
        self.kept[0] = true;
        self.omitted[0] = root.printedBelow();
        var used = lineCost(root) + markerCost(root, self.omitted[0]);

        const limit = max_bytes -| trailerCost(root.printed_len);
        var chain: std.ArrayList(u32) = .empty;
        for (try candidateOrder(arena, lines)) |i| {
            if (self.kept[i]) continue;
            chain.clearRetainingCapacity();
            var c = i;
            while (!self.kept[c]) : (c = lines[c].parent.?) {
                try chain.append(arena, c);
            }
            const new_used = self.chainCost(chain.items, used);
            if (new_used <= limit) {
                self.keep(chain.items);
                used = new_used;
            }
        }
        return self;
    }

    /// `used` once `chain`, a candidate then its unkept ancestors, is kept.
    fn chainCost(self: *const Budget, chain: []const u32, used: usize) usize {
        var total = used;
        var below: u32 = 0;
        for (chain) |c| {
            const line = self.lines[c];
            total += lineCost(line) + markerCost(line, line.printedBelow() - below);
            below = line.printed_len;
        }
        const p = self.lines[chain[chain.len - 1]].parent.?;
        return total + markerCost(self.lines[p], self.omitted[p] - below) - markerCost(self.lines[p], self.omitted[p]);
    }

    fn keep(self: *Budget, chain: []const u32) void {
        var it = std.mem.reverseIterator(chain);
        while (it.next()) |c| {
            const line = self.lines[c];
            self.omitted[line.parent.?] -= line.printed_len;
            self.kept[c] = true;
            self.omitted[c] = line.printedBelow();
        }
    }

    fn render(self: *const Budget, arena: std.mem.Allocator, writer: *std.Io.Writer) error{WriteFailed}!void {
        var pending: std.ArrayList(u32) = .empty;
        var shown: usize = 0;
        for (self.lines, 0..) |line, i| {
            while (pending.getLastOrNull()) |p| {
                if (p + self.lines[p].subtree_len > i) break;
                try writeMarker(writer, self.lines[p], self.omitted[p]);
                _ = pending.pop();
            }
            if (!self.kept[i]) continue;
            try writer.writeAll(self.text[line.start..line.end]);
            shown += @intFromBool(!line.hidden);
            if (self.omitted[i] > 0) {
                pending.append(arena, @intCast(i)) catch return error.WriteFailed;
            }
        }
        while (pending.pop()) |p| {
            try writeMarker(writer, self.lines[p], self.omitted[p]);
        }
        try writer.print(trailer_fmt, .{ shown, self.lines[0].printed_len });
    }

    /// Contentful lines by (priority, rank among same-priority siblings): with
    /// rows and list items as hidden parents, that takes records round-robin.
    /// Containers only come in as the ancestors of a kept line.
    fn candidateOrder(arena: std.mem.Allocator, lines: []const Line) ![]u32 {
        const rank = try arena.alloc(u32, lines.len);
        const next = try arena.alloc(std.EnumArray(Priority, u32), lines.len);
        @memset(next, .initFill(0));
        var keys: std.ArrayList(u64) = .empty;
        rank[0] = 0;
        for (lines[1..], 1..) |line, i| {
            // Nested detail never outranks its parent.
            const parent = line.parent.?;
            if (line.hidden) {
                rank[i] = rank[parent];
                continue;
            }
            const counter = next[parent].getPtr(line.priority);
            rank[i] = @max(counter.*, rank[parent]);
            counter.* += 1;
            if (!line.contentful and line.priority != .critical) continue;
            const r: u64 = @min(rank[i], std.math.maxInt(u29));
            try keys.append(arena, @as(u64, @backingInt(line.priority)) << 61 | r << 32 | i);
        }
        std.mem.sort(u64, keys.items, {}, std.sort.asc(u64));

        const order = try arena.alloc(u32, keys.items.len);
        for (order, keys.items) |*o, key| o.* = @truncate(key);
        return order;
    }

    const trailer_fmt = "[showing {d} of {d} nodes; read a [+N more @id] with tree backendNodeId=id]\n";

    fn lineCost(line: Line) usize {
        return line.end - line.start;
    }

    fn markerCost(line: Line, omitted: u32) usize {
        if (omitted == 0) return 0;
        var counter: std.Io.Writer.Discarding = .init(&.{});
        writeMarker(&counter.writer, line, omitted) catch unreachable;
        return @intCast(counter.fullCount());
    }

    fn trailerCost(total: usize) usize {
        return std.fmt.count(trailer_fmt, .{ total, total });
    }

    fn writeMarker(writer: *std.Io.Writer, line: Line, omitted: u32) error{WriteFailed}!void {
        try writer.splatByteAll(' ', line.childDepth());
        // Scoping `tree` to the walk root returns the same budget problem.
        if (line.parent == null) {
            try writer.print("[+{d} more; raise maxBytes]\n", .{omitted});
        } else {
            try writer.print("[+{d} more @{d}]\n", .{ omitted, line.id });
        }
    }
};

const OptionData = struct {
    value: []const u8,
    text: []const u8,
    selected: bool,
};

const NodeData = struct {
    id: NodeRegistry.Id,
    axn: AXNode,
    role: []const u8,
    name: ?[]const u8,
    value: ?[]const u8,
    options: ?[]OptionData = null,
    checked: ?bool = null,
    aria: AXNode.Writer.AriaProperties = .{},
    xpath: []const u8,
    interactive: bool,
    disabled: bool,
    tag_name: []const u8,
};

const WalkContext = struct {
    xpath_buffer: *std.ArrayList(u8),
    listener_targets: interactive.ListenerTargetMap,
    label_index: *Label.LabelByForIndex,
};

// A node whose children are still being walked
const Open = struct {
    next_child: ?*Node,
    // for the children's xpath index
    tag_counts: std.StringArrayHashMapUnmanaged(usize) = .empty,
    name: ?[]const u8, // The children's parent_name
    invisible: bool, // visibility:hidden, so its text children are too
    controls_only: bool, // Walk.controls from it or an ancestor
    xpath_len: usize,
    // Whether the visitor gets a `leave()` once the children are done.
    opened: bool,
};

fn walk(self: @This(), ctx: *WalkContext, visitor: anytype) !void {
    var stack: std.ArrayList(Open) = .empty;
    defer stack.deinit(self.arena);

    try self.visitNode(ctx, &stack, self.dom_node, null, false, false, visitor, 1);
    while (stack.items.len > 0) {
        // Everything read from `top` is read before visitNode, which can grow (move) the stack.
        const top = &stack.items[stack.items.len - 1];
        if (top.next_child) |child| {
            top.next_child = child._next;

            var tag: []const u8 = "text()";
            if (child.is(Element)) |el| {
                tag = el.getTagNameLower();
            }
            const gop = try top.tag_counts.getOrPut(self.arena, tag);
            if (!gop.found_existing) {
                gop.value_ptr.* = 0;
            }
            gop.value_ptr.* += 1;

            try self.visitNode(ctx, &stack, child, top.name, top.invisible, top.controls_only, visitor, gop.value_ptr.*);
            continue;
        }

        const done = stack.pop().?;
        if (done.opened) {
            try visitor.leave();
        }
        ctx.xpath_buffer.shrinkRetainingCapacity(done.xpath_len);
    }
}

// Every ancestor of `node` below the root is open, so the stack's length is its depth.
fn visitNode(
    self: @This(),
    ctx: *WalkContext,
    stack: *std.ArrayList(Open),
    node: *Node,
    parent_name: ?[]const u8,
    parent_invisible: bool,
    controls_only: bool,
    visitor: anytype,
    index: usize,
) !void {
    const current_depth = stack.items.len;
    if (current_depth > self.max_depth) return;

    // 1. Skip non-content nodes. An invisible element is passed through, not
    // cut: a descendant can be visible again.
    var invisible = false;
    if (node.is(Element)) |el| {
        const tag = el.getTag();
        if (tag.isMetadata() or tag == .svg) return;

        // We handle options/optgroups natively inside their parents, skip them in the general walk
        if (tag == .datalist or tag == .option or tag == .optgroup) return;

        // Not just the element's own display: a slotted element inherits
        // from its slot, which this light-tree walk never visits.
        switch (self.frame._style_manager.rendering(el)) {
            .none => return,
            .invisible => invisible = true,
            .visible => {},
        }

        if (el.is(Element.Html)) |html_el| {
            if (html_el.getHidden()) return;
        }
    } else if (node.is(CData.Text)) |text_node| {
        if (parent_invisible or controls_only) return;
        const text = text_node.ownData();
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

    if (invisible) {
        // Never printed: skip reading its value and interactivity.
        tag_name = node.as(Element).getTagNameLower();
    } else if (node.is(Element)) |el| {
        tag_name = el.getTagNameLower();

        if (el.is(Element.Html.Input)) |input| {
            value = input.getRedactedValue();
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
        } else if (el.is(Element.Html.IFrame)) |iframe| {
            // The tree doesn't enter frames; the URL lets the agent open one.
            value = try iframe.currentURL(self.frame);
        }

        if (el.is(Element.Html)) |html_el| {
            if (interactive.classifyInteractivity(self.frame, el, html_el, ctx.listener_targets) != null) {
                is_interactive = true;
            }
        }

        is_disabled = el.isDisabled();
    } else if (node._type == .document or node._type == .document_fragment) {
        tag_name = "root";
    }

    const initial_xpath_len = ctx.xpath_buffer.items.len;
    try appendXPathSegment(node, ctx.xpath_buffer, self.arena, index);
    const xpath = ctx.xpath_buffer.items;

    const has_explicit_label = if (node.is(Element)) |el|
        !isAllWhitespace(el.getAttributeInterned("aria-label") orelse "") or el.getAttributeInterned("title") != null
    else
        false;

    const structural = isStructuralRole(role);

    // No computed concatenated names for generic containers without explicit labels.
    // This prevents token bloat and ensures their StaticText children aren't incorrectly pruned.
    // We ignore interactivity because a generic wrapper with an event listener still shouldn't hoist all text.
    // Not computing it also keeps a deep chain of containers from being O(depth²).
    const name = if (invisible or (structural and !has_explicit_label))
        null
    else
        try axn.getName(self.frame, self.arena, ctx.label_index);

    var should_visit = true;
    if (invisible) {
        should_visit = false;
    } else if (controls_only) {
        should_visit = is_interactive or interactive.isInteractiveRole(role);
    } else if (self.interactive_only) {
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
            if (parent_name != null and name != null and std.mem.find(u8, parent_name.?, name.?) != null) {
                should_visit = false;
            }
        }
    }

    var opened = false;
    var children: Walk = .all;
    var data: NodeData = .{
        .id = cdp_node.id,
        .axn = axn,
        .role = role,
        .name = name,
        .value = value,
        .options = options,
        .checked = checked,
        .aria = if (invisible) .{} else if (node.is(Element)) |el| AXNode.Writer.ariaProperties(el, role) else .{},
        .xpath = xpath,
        .interactive = is_interactive,
        .disabled = is_disabled,
        .tag_name = tag_name,
    };

    if (should_visit) {
        children = try visitor.visit(node, &data);
        opened = true;
    } else if (@hasDecl(@TypeOf(visitor.*), "visitPruned")) {
        opened = try visitor.visitPruned(node, &data);
    }

    // Its text is the only thing saying what it is, as outside a heading.
    const nameless_control = should_visit and (name == null or name.?.len == 0);
    try stack.append(self.arena, .{
        .next_child = if (children != .none) node._first_child else null,
        .name = name,
        .invisible = invisible,
        .controls_only = children == .controls or (controls_only and !nameless_control),
        .xpath_len = initial_xpath_len,
        .opened = opened,
    });
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
    if (frame.document.getElementById(list_id)) |referenced_el| {
        if (referenced_el.getTag() == .datalist) {
            return try extractSelectOptions(referenced_el.asNode(), frame, arena);
        }
    }
    return null;
}

fn appendXPathSegment(node: *Node, buffer: *std.ArrayList(u8), allocator: std.mem.Allocator, index: usize) !void {
    if (node.is(Element)) |el| {
        const tag = el.getTagNameLower();
        try buffer.print(allocator, "/{s}[{d}]", .{ tag, index });
    } else if (node.is(CData.Text)) |_| {
        try buffer.print(allocator, "/text()[{d}]", .{index});
    }
}

const JsonVisitor = struct {
    jw: *std.json.Stringify,
    tree: Self,

    pub fn visit(self: *JsonVisitor, node: *Node, data: *NodeData) !Walk {
        try self.jw.beginObject();

        try self.jw.objectField("nodeId");
        try self.jw.write(try self.tree.arena.print("{d}", .{data.id}));

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

            if (!el._attributes.isEmpty()) {
                try self.jw.objectField("attributes");
                try self.jw.beginObject();
                for (el.attributeEntries()) |*attr| {
                    try self.jw.objectField(attr.name());
                    try self.jw.write(attr.value());
                }
                try self.jw.endObject();
            }

            if (data.checked) |checked| {
                try self.jw.objectField("checked");
                try self.jw.write(checked);
            }
            if (data.aria.expanded) |expanded| {
                try self.jw.objectField("ariaExpanded");
                try self.jw.write(expanded);
            }
            if (data.aria.checked) |checked| {
                try self.jw.objectField("ariaChecked");
                try self.jw.write(@tagName(checked));
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
            try self.jw.write(text_node.ownData());
        } else {
            try self.jw.objectField("nodeType");
            try self.jw.write(9);
        }

        try self.jw.objectField("children");
        try self.jw.beginArray();

        if (data.options != null) {
            // Signal to not walk children, as we handled them natively
            return .none;
        }

        return .all;
    }

    pub fn leave(self: *JsonVisitor) !void {
        try self.jw.endArray();
        try self.jw.endObject();
    }
};

fn isStructuralRole(role: []const u8) bool {
    return structural_roles.has(role);
}

// Pruned from the tree. In the text output, anchors still group their lines
// into records and scope the `[more]` markers for what's dropped.
const structural_roles = std.StaticStringMap(enum { wrapper, anchor }).initComptime(.{
    .{ "none", .wrapper },
    .{ "generic", .wrapper },
    .{ "InlineTextBox", .wrapper },
    .{ "rowgroup", .wrapper },
    .{ "cell", .wrapper },
    .{ "banner", .anchor },
    .{ "navigation", .anchor },
    .{ "main", .anchor },
    .{ "list", .anchor },
    .{ "listitem", .anchor },
    .{ "table", .anchor },
    .{ "row", .anchor },
    .{ "region", .anchor },
});

const Walk = enum {
    all,
    none,
    // Only the interactive descendants: the rest is already in the name.
    controls,
};

const TextLine = struct {
    children: Walk,
    // A name, text or value of its own, not only children.
    contentful: bool,
};

fn writeTextLine(writer: *std.Io.Writer, node: *Node, data: *NodeData) !TextLine {
    var name_to_print: ?[]const u8 = null;
    if (data.name) |n| {
        if (n.len > 0) {
            name_to_print = n;
        }
    } else if (node.is(CData.Text)) |text_node| {
        const trimmed = std.mem.trim(u8, text_node.ownData(), " \t\r\n");
        if (trimmed.len > 0) {
            name_to_print = trimmed;
        }
    }

    const is_text_only = std.mem.eql(u8, data.role, "StaticText") or std.mem.eql(u8, data.role, "none") or std.mem.eql(u8, data.role, "generic");

    try writer.print("{d}", .{data.id});
    if (data.interactive) {
        try writer.writeAll(if (data.disabled) " [i:disabled]" else " [i]");
    }
    if (!is_text_only) {
        try writer.print(" {s}", .{data.role});
    }
    if (name_to_print) |n| {
        try writer.writeAll(" '");
        try writeOneLine(writer, n);
        try writer.writeByte('\'');
    }

    if (data.value) |v| {
        if (v.len > 0) {
            try writer.writeAll(" value='");
            try writeEscapedNewlines(writer, v);
            try writer.writeByte('\'');
        }
    }

    if (data.checked) |c| {
        if (c) {
            try writer.writeAll(" [checked]");
        } else {
            try writer.writeAll(" [unchecked]");
        }
    }

    if (data.aria.expanded) |expanded| {
        try writer.writeAll(if (expanded) " [expanded]" else " [collapsed]");
    }
    if (data.aria.checked) |checked| {
        try writer.writeAll(switch (checked) {
            .true => " [checked]",
            .false => " [unchecked]",
            .mixed => " [mixed]",
        });
    }

    if (data.options) |options| {
        try writer.writeAll(" options=[");
        for (options, 0..) |opt, i| {
            if (i > 0) try writer.writeAll(",");
            try writer.writeByte('\'');
            try writeEscapedNewlines(writer, opt.value);
            try writer.writeByte('\'');
            if (opt.selected) {
                try writer.writeAll("*");
            }
        }
        try writer.writeAll("]");
        return .{ .children = .none, .contentful = true }; // Native handling complete, do not walk children
    }
    const contentful = name_to_print != null or (if (data.value) |v| v.len > 0 else false) or data.checked != null or data.aria.expanded != null or data.aria.checked != null;

    // A named one already says what its children say, but a heading or
    // code can still wrap a link.
    const named = data.name != null and data.name.?.len > 0;
    const children: Walk = if (!named)
        .all
    else if (std.mem.eql(u8, data.role, "link") or std.mem.eql(u8, data.role, "button"))
        .none
    else if (std.mem.eql(u8, data.role, "heading") or std.mem.eql(u8, data.role, "code"))
        .controls
    else
        .all;
    return .{ .children = children, .contentful = contentful };
}

/// Each node is one line: a newline in a name would start another.
fn writeOneLine(writer: *std.Io.Writer, s: []const u8) !void {
    var words = std.mem.tokenizeAny(u8, s, &std.ascii.whitespace);
    if (words.next()) |first| try writer.writeAll(first);
    while (words.next()) |word| {
        try writer.writeByte(' ');
        try writer.writeAll(word);
    }
}

/// Unlike a name, a value is kept exact: only its line breaks are escaped.
fn writeEscapedNewlines(writer: *std.Io.Writer, s: []const u8) !void {
    for (s) |c| switch (c) {
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        else => try writer.writeByte(c),
    };
}

const NodeDetails = struct {
    backendNodeId: NodeRegistry.Id,
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
    selector: ?[]const u8 = null,
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

        if (self.selector) |v| {
            try jw.objectField("selector");
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

pub fn nodeDetails(self: Self) !NodeDetails {
    const arena = self.arena;
    const node = self.dom_node;
    const frame = self.frame;

    const cdp_node = try self.registry.register(node);
    const axn = AXNode.fromNode(node);
    const role = try axn.getRole();
    var labels: Label.LabelByForIndex = .{};
    const name = try axn.getName(frame, arena, &labels);

    var is_interactive = false;
    var is_disabled = false;
    var tag_name: []const u8 = "text";
    var value: ?[]const u8 = null;
    var input_type: ?[]const u8 = null;
    var placeholder: ?[]const u8 = null;
    var href: ?[]const u8 = null;
    var id_attr: ?[]const u8 = null;
    var class_attr: ?[]const u8 = null;
    var selector: ?[]const u8 = null;
    var checked: ?bool = null;
    var options: ?[]OptionData = null;

    if (node.is(Element)) |el| {
        tag_name = el.getTagNameLower();
        is_disabled = el.isDisabled();
        id_attr = el.getId();
        class_attr = el.getClassName();
        selector = try SelectorPath.init(arena, frame).build(el);
        placeholder = el.getAttributeInterned("placeholder");

        if (el.getAttributeInterned("href")) |h| {
            const URL = lp.URL;
            href = URL.resolve(arena, frame.base(), h, .{ .encoding = frame.charset }) catch h;
        }

        if (el.is(Element.Html.Input)) |input| {
            value = input.getRedactedValue();
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
        } else if (el.is(Element.Html.IFrame)) |iframe| {
            value = try iframe.currentURL(frame);
        }

        if (el.is(Element.Html)) |html_el| {
            const listener_targets = try interactive.buildListenerTargetMap(frame, arena);
            if (interactive.classifyInteractivity(frame, el, html_el, listener_targets) != null) {
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
        .selector = selector,
        .checked = checked,
        .options = options,
    };
}

const testing = @import("testing.zig");

test "SemanticTree backendDOMNodeId" {
    var registry: NodeRegistry = .init(testing.allocator);
    defer registry.deinit();

    var page = try testing.pageTest("cdp/registry1.html", .{});
    defer page.close();
    const frame = page.frame().?;

    const st: Self = try .init(testing.arena_allocator, frame.window._document.asNode(), &registry, frame, .{ .prune = false });

    const json_str = try std.json.Stringify.valueAlloc(testing.allocator, st, .{});
    defer testing.allocator.free(json_str);

    try testing.expect(std.mem.find(u8, json_str, "\"backendDOMNodeId\":") != null);
}

test "SemanticTree: JSON exposes custom ARIA states without changing native checked" {
    var registry: NodeRegistry = .init(testing.allocator);
    defer registry.deinit();

    var page = try testing.pageTest("cdp/ax_aria_states.html", .{});
    defer page.close();
    const frame = page.frame().?;
    const st: Self = try .init(testing.arena_allocator, frame.window._document.asNode(), &registry, frame, .{ .prune = false });

    const json = try std.json.Stringify.valueAlloc(testing.allocator, st, .{});
    defer testing.allocator.free(json);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();

    const find = struct {
        fn named(node: std.json.Value, name: []const u8) ?std.json.Value {
            if (node != .object) return null;
            if (node.object.get("name")) |n| {
                if (n == .string and std.mem.eql(u8, n.string, name)) return node;
            }
            if (node.object.get("children")) |children| {
                for (children.array.items) |child| {
                    if (named(child, name)) |found| return found;
                }
            }
            return null;
        }
    }.named;

    const expanded = find(parsed.value, "Uppercase expanded") orelse return error.NodeNotFound;
    try testing.expect(expanded.object.get("ariaExpanded").?.bool);
    const collapsed = find(parsed.value, "Collapsed details") orelse return error.NodeNotFound;
    try testing.expect(!collapsed.object.get("ariaExpanded").?.bool);
    const generic = find(parsed.value, "Generic expanded") orelse return error.NodeNotFound;
    try testing.expect(generic.object.get("ariaExpanded") == null);
    const mixed = find(parsed.value, "Uppercase mixed") orelse return error.NodeNotFound;
    try testing.expectString("mixed", mixed.object.get("ariaChecked").?.string);
    const switch_mixed = find(parsed.value, "Switch mixed") orelse return error.NodeNotFound;
    try testing.expectString("false", switch_mixed.object.get("ariaChecked").?.string);
    const invalid = find(parsed.value, "Invalid details") orelse return error.NodeNotFound;
    try testing.expect(invalid.object.get("ariaExpanded").?.bool);
    const empty_expanded = find(parsed.value, "Empty expanded") orelse return error.NodeNotFound;
    try testing.expect(empty_expanded.object.get("ariaExpanded") == null);
    const spaced_checked = find(parsed.value, "Spaced checked") orelse return error.NodeNotFound;
    try testing.expectString("true", spaced_checked.object.get("ariaChecked").?.string);
    const option_mixed = find(parsed.value, "Option mixed") orelse return error.NodeNotFound;
    try testing.expectString("mixed", option_mixed.object.get("ariaChecked").?.string);
    const native = find(parsed.value, "Native terms") orelse return error.NodeNotFound;
    try testing.expect(native.object.get("checked").?.bool);
    try testing.expect(native.object.get("ariaChecked") == null);
}

test "SemanticTree max_depth" {
    var registry: NodeRegistry = .init(testing.allocator);
    defer registry.deinit();

    var page = try testing.pageTest("cdp/registry1.html", .{});
    defer page.close();
    const frame = page.frame().?;

    const st: Self = try .init(testing.arena_allocator, frame.window._document.asNode(), &registry, frame, .{ .prune = false, .max_depth = 1 });

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    try st.textStringify(&aw.writer);
    const text_str = aw.written();

    try testing.expect(std.mem.find(u8, text_str, "other") == null);
}

test "SemanticTree: a slotted element inherits its slot's display" {
    var registry: NodeRegistry = .init(testing.allocator);
    defer registry.deinit();

    var page = try testing.pageTest("cdp/slotted_hidden.html", .{});
    defer page.close();
    const frame = page.frame().?;

    const st: Self = try .init(testing.arena_allocator, frame.window._document.asNode(), &registry, frame, .{ .prune = false });

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try st.textStringify(&aw.writer);

    try testing.expect(std.mem.find(u8, aw.written(), "slotted-shown") != null);
    try testing.expect(std.mem.find(u8, aw.written(), "slotted-hidden") == null);
}

test "SemanticTree: visibility:hidden drops the element, not a visible descendant" {
    var registry: NodeRegistry = .init(testing.allocator);
    defer registry.deinit();

    var page = try testing.pageTest("cdp/visibility_hidden.html", .{});
    defer page.close();
    const frame = page.frame().?;

    for ([_]bool{ false, true }) |prune| {
        const st: Self = try .init(testing.arena_allocator, frame.window._document.asNode(), &registry, frame, .{ .prune = prune });

        var aw: std.Io.Writer.Allocating = .init(testing.allocator);
        defer aw.deinit();
        try st.textStringify(&aw.writer);
        const text = aw.written();

        try testing.expect(std.mem.find(u8, text, "We use cookies") == null);
        try testing.expect(std.mem.find(u8, text, "Accept all") == null);
        try testing.expect(std.mem.find(u8, text, "Inherited hidden") == null);
        try testing.expect(std.mem.find(u8, text, "Shown again") != null);
        try testing.expect(std.mem.find(u8, text, "Page content") != null);
    }
}

test "SemanticTree: deep nesting doesn't overflow the native stack" {
    var registry: NodeRegistry = .init(testing.allocator);
    defer registry.deinit();

    const frame = try testing.createFrame();
    defer testing.test_session.closeAllPages();

    // The link's name comes from its content: the whole chain. The <g>s are
    // pruned, so the JSON only nests link > text. SVG, as an HTML element's
    // pointer-events lookup walks its ancestors: O(depth²).
    const depth = 50_000;
    const doc = frame.window._document;
    var top = try doc.createTextNode("deep");
    for (0..depth) |_| {
        const parent = (try doc.createElementNS("http://www.w3.org/2000/svg", "g", frame)).asNode();
        _ = try parent.appendChild(top, frame);
        top = parent;
    }
    const link = try doc.createElement("a", null, frame);
    try link.setAttribute(.wrap("href"), .wrap("#"), frame);
    _ = try link.asNode().appendChild(top, frame);

    const st: Self = try .init(testing.arena_allocator, link.asNode(), &registry, frame, .{});
    const json_str = try std.json.Stringify.valueAlloc(testing.allocator, st, .{});
    defer testing.allocator.free(json_str);

    try testing.expect(std.mem.find(u8, json_str, "\"role\":\"link\",\"name\":\"deep\"") != null);
    try testing.expectEqual(depth, std.mem.count(u8, json_str, "/g[1]"));
    try testing.expect(std.mem.endsWith(u8, json_str, "/text()[1]\",\"nodeType\":3,\"nodeValue\":\"deep\",\"children\":[]}]}"));
}

test "SemanticTree: a named heading or code keeps its links" {
    var registry: NodeRegistry = .init(testing.allocator);
    defer registry.deinit();

    var page = try testing.pageTest("cdp/tree_heading_links.html", .{});
    defer page.close();
    const frame = page.frame().?;

    for ([_]bool{ false, true }) |interactive_only| {
        const st: Self = try .init(testing.arena_allocator, frame.window._document.asNode(), &registry, frame, .{ .interactive_only = interactive_only });

        var aw: std.Io.Writer.Allocating = .init(testing.allocator);
        defer aw.deinit();
        try st.textStringify(&aw.writer);
        const out = aw.written();

        try testing.expect(std.mem.find(u8, out, "heading 'Post title'\n") != null);
        try testing.expect(std.mem.find(u8, out, "link 'Post title'\n") != null);
        try testing.expect(std.mem.find(u8, out, "button 'Follow'\n") != null);
        try testing.expect(std.mem.find(u8, out, "link 'ls'\n") != null);
        // A control without a name keeps the text that says what it is.
        if (!interactive_only) try testing.expectEqual(2, std.mem.count(u8, out, "'Clickable title'"));
        // The rest of a heading's text is in its name, not repeated below it.
        try testing.expectEqual(1, std.mem.count(u8, out, "Acme"));
    }
}

test "SemanticTree: a multi-line name or value stays on its node's line" {
    var registry: NodeRegistry = .init(testing.allocator);
    defer registry.deinit();

    var page = try testing.pageTest("cdp/tree_multiline.html", .{});
    defer page.close();
    const frame = page.frame().?;

    const st: Self = try .init(testing.arena_allocator, frame.window._document.asNode(), &registry, frame, .{});

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try st.textStringify(&aw.writer);
    const out = aw.written();

    try testing.expect(std.mem.find(u8, out, "button 'Close dialog'\n") != null);
    try testing.expect(std.mem.find(u8, out, "textbox value='first line\\nsecond line'\n") != null);
    try testing.expect(std.mem.find(u8, out, "textbox value='a   b'\n") != null);
}

test "SemanticTree: maxBytes keeps alerts and controls, marks the rest" {
    var registry: NodeRegistry = .init(testing.allocator);
    defer registry.deinit();

    var page = try testing.pageTest("cdp/tree_budget.html", .{});
    defer page.close();
    const frame = page.frame().?;

    const max_bytes = 500;
    const st: Self = try .init(testing.arena_allocator, frame.window._document.asNode(), &registry, frame, .{ .max_bytes = max_bytes });

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try st.textStringify(&aw.writer);
    const out = aw.written();

    try testing.expect(out.len <= max_bytes);
    try testing.expect(std.mem.find(u8, out, "'Email is invalid'") != null);
    try testing.expect(std.mem.find(u8, out, "textbox 'Email' value='nope'") != null);
    try testing.expect(std.mem.find(u8, out, "button 'Submit'") != null);
    // The list item, pruned from the output, scopes the marker for its text.
    try testing.expect(std.mem.find(u8, out, "link 'Result four'\n  [+1 more @") != null);
    try testing.expect(std.mem.find(u8, out, "Lorem ipsum") == null);
    try testing.expect(std.mem.find(u8, out, "paragraph") == null);
    try testing.expect(std.mem.find(u8, out, "[showing ") != null);
}

test "SemanticTree: maxBytes keeps a dialog, not its text" {
    var registry: NodeRegistry = .init(testing.allocator);
    defer registry.deinit();

    var page = try testing.pageTest("cdp/tree_budget_dialog.html", .{});
    defer page.close();
    const frame = page.frame().?;

    const max_bytes = 300;
    const st: Self = try .init(testing.arena_allocator, frame.window._document.asNode(), &registry, frame, .{ .max_bytes = max_bytes });

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try st.textStringify(&aw.writer);
    const out = aw.written();

    try testing.expect(out.len <= max_bytes);
    try testing.expect(std.mem.find(u8, out, "dialog 'Your privacy'") != null);
    try testing.expect(std.mem.find(u8, out, "1,042 partners") == null);
}

test "SemanticTree: maxBytes ranks headings first and navigation last" {
    var registry: NodeRegistry = .init(testing.allocator);
    defer registry.deinit();

    var page = try testing.pageTest("cdp/tree_budget_nav.html", .{});
    defer page.close();
    const frame = page.frame().?;

    const max_bytes = 300;
    const st: Self = try .init(testing.arena_allocator, frame.window._document.asNode(), &registry, frame, .{ .max_bytes = max_bytes });

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try st.textStringify(&aw.writer);
    const out = aw.written();

    try testing.expect(out.len <= max_bytes);
    try testing.expect(std.mem.find(u8, out, "heading 'Mini PC 128GB'") != null);
    try testing.expect(std.mem.find(u8, out, "heading 'Warranty'") != null);
    try testing.expect(std.mem.find(u8, out, "button 'Add to cart'") != null);
    try testing.expect(std.mem.find(u8, out, "'$3,879.00'") != null);
    try testing.expect(std.mem.find(u8, out, "Category 1'") == null);
    try testing.expect(std.mem.find(u8, out, "Footer link 1'") == null);
}
