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

//! The observation a System One decider sees: one dense, indexed table of the
//! operations available on the current page.
//!
//! The model never receives a selector, an xpath or a registry id — only an
//! index into a table this module built, which is why a hallucinated target
//! cannot become an action. Indices are dense `1..N` and live for exactly one
//! turn; `NodeRegistry.Id` is the internal identity and never leaves here.
//!
//! The action-space shape (an element table plus per-operation target heads)
//! follows browser-use/jev-ultrafast, MIT licensed.

const std = @import("std");
const lp = @import("lightpanda");
const zenai = @import("zenai");

const DomElement = @import("../../browser/webapi/Element.zig");
const Node = @import("../../browser/webapi/Node.zig");
const interactive = lp.interactive;
const prompts = @import("prompts.zig");
const string = @import("../../string.zig");
const NodeRegistry = lp.NodeRegistry;
const SemanticTree = lp.SemanticTree;

const Question = zenai.typesafe.types.Question;
const QuestionEntry = zenai.typesafe.types.QuestionEntry;

/// Everything the decider may choose. A `SELECT` target carries an option.
pub const Operation = enum {
    CLICK,
    TYPE_TEXT,
    SELECT,
    WAIT,
    DONE,
    BLOCKED,

    pub fn needsTarget(self: Operation) bool {
        return self.targetQuestion() != null;
    }

    /// The question id carrying this operation's candidates.
    pub fn targetQuestion(self: Operation) ?[]const u8 {
        return switch (self) {
            .CLICK => "click_target",
            .TYPE_TEXT => "type_text_target",
            .SELECT => "select_target",
            else => null,
        };
    }
};

/// A dense `1..N` position in `Table.elements`. A distinct type from
/// `NodeRegistry.Id` so the sparse internal ids and the dense model-facing
/// ones cannot be swapped by accident.
pub const Index = enum(u16) {
    _,

    pub fn slot(self: Index) usize {
        return @intFromEnum(self) - 1;
    }
};

/// Which operations an element accepts.
pub const OpSet = struct {
    click: bool = false,
    type_text: bool = false,
    select: bool = false,

    pub fn any(self: OpSet) bool {
        return self.click or self.type_text or self.select;
    }

    pub fn has(self: OpSet, op: Operation) bool {
        return switch (op) {
            .CLICK => self.click,
            .TYPE_TEXT => self.type_text,
            .SELECT => self.select,
            else => false,
        };
    }
};

pub const Element = struct {
    pub const Choice = struct {
        element: *const Element,
        /// Only set for `SELECT`.
        option: ?[]const u8 = null,
    };

    index: Index,
    /// Internal only — never serialized into the state.
    node_id: NodeRegistry.Id,
    role: []const u8,
    label: []const u8,
    value: ?[]const u8,
    checked: ?bool,
    ops: OpSet,
    /// `<select>`/datalist option values, addressed as `"<index>:<option>"`.
    options: []const []const u8,
};

/// What the decider picked.
pub const Target = Element.Choice;

/// Upstream's page-text budget.
pub const default_text_bytes = 6000;

/// Upstream keeps its table small by capturing only elements whose centre is
/// inside the viewport. We have no layout to ask, so labels are deduplicated
/// and the result capped instead — a page of forty identical "edit" links is
/// forty criteria to the decider and one control to a reader.
pub const max_offered = 120;

/// A page with more actionable elements than this is pathological; stop
/// collecting rather than walking an unbounded list to window it.
const max_collected = 5000;

/// A label longer than this is a paragraph, not a name. The same ceiling
/// holds for a field's current value and an option's text, both of which are
/// echoed back to the decider every turn.
const max_label_bytes = 120;

pub const Table = struct {
    url: []const u8,
    title: []const u8,
    text: []const u8,
    elements: []const Element,
    /// Elements the collector refused outright, and those dropped by the
    /// dedupe cap. Sent to the decider: a table that silently stops is one it
    /// reads as the whole page.
    dropped: u32,
    /// Hash of the url and every element's identity and current state. Cheap
    /// enough to recompute mid-turn to catch a page that moved under a
    /// decision.
    fingerprint: u64,
    /// `Page.style_version` at observation — a superset of `dom_version` that
    /// also moves for non-tree state. Monotonic, so an unchanged value is
    /// proof the page did not move and a changed one only means it might
    /// have; `fingerprint` settles that.
    style_version: usize,

    /// Whether this table's ids still resolve. All of them share one frame, so
    /// one probe answers for the batch: a registry reset evicts every id at
    /// once, and ids are never reused.
    pub fn live(self: Table, registry: *NodeRegistry) bool {
        if (self.elements.len == 0) return true;
        return registry.lookup_by_id.contains(self.elements[0].node_id);
    }

    pub fn byIndex(self: Table, index: Index) ?*const Element {
        const slot = index.slot();
        if (slot >= self.elements.len) return null;
        return &self.elements[slot];
    }

    /// The criteria offered for `op`: the `"<index>"` or `"<index>:<option>"`
    /// id the decider answers with, and the description it chooses on. The
    /// table is already bounded, so this only filters and formats -- except for
    /// `<select>`, where one element contributes a target per option and can
    /// overflow a head on its own.
    /// The offered ids for one target head. Descriptions are null: `stateJson`
    /// already sends every element under the same index, and repeating it here
    /// cost 23% of the request for no change in what the decider picks.
    pub fn criteria(self: Table, arena: std.mem.Allocator, op: Operation) ![]const ChoiceEntry {
        var out: std.ArrayList(ChoiceEntry) = .empty;
        for (self.elements) |el| {
            if (!el.ops.has(op)) continue;
            if (out.items.len >= max_offered) break;
            if (op == .SELECT) {
                for (el.options) |option| {
                    if (out.items.len >= max_offered) break;
                    try out.append(arena, .{
                        .key = try std.fmt.allocPrint(arena, "{d}:{s}", .{ @intFromEnum(el.index), option }),
                        .value = null,
                    });
                }
            } else {
                try out.append(arena, .{
                    .key = try std.fmt.allocPrint(arena, "{d}", .{@intFromEnum(el.index)}),
                    .value = null,
                });
            }
        }
        return out.items;
    }

    /// Resolve a chosen target id back to an observed element — the last gate
    /// before anything touches the DOM.
    pub fn parseTarget(self: Table, op: Operation, raw: []const u8) error{InvalidTarget}!Target {
        const sep = std.mem.indexOfScalar(u8, raw, ':');
        const index_text = if (sep) |i| raw[0..i] else raw;
        const option = if (sep) |i| raw[i + 1 ..] else null;

        // An option belongs to SELECT and to nothing else.
        if ((op == .SELECT) != (option != null)) return error.InvalidTarget;

        const number = std.fmt.parseInt(u16, index_text, 10) catch return error.InvalidTarget;
        if (number == 0) return error.InvalidTarget;
        const element = self.byIndex(@enumFromInt(number)) orelse return error.InvalidTarget;
        if (!element.ops.has(op)) return error.InvalidTarget;

        if (option) |want| {
            for (element.options) |candidate| {
                if (std.mem.eql(u8, candidate, want)) {
                    return .{ .element = element, .option = candidate };
                }
            }
            return error.InvalidTarget;
        }
        return .{ .element = element };
    }
};

pub const ObserveOpts = struct {
    /// Cap on the rendered page text handed to the decider. Zero skips the
    /// render entirely, for the post-action snapshot that only needs to know
    /// whether the page moved.
    text_bytes: u32 = default_text_bytes,
};

pub const ObserveError = error{ ObserveFailed, OutOfMemory };

/// Snapshot the current page into an action space. Everything is allocated
/// from `arena`, which the caller resets each turn.
pub fn observe(
    arena: std.mem.Allocator,
    session: *lp.Session,
    registry: *NodeRegistry,
    opts: ObserveOpts,
) ObserveError!Table {
    // A frame can go missing mid-run. That is an observation, not a failure:
    // the action space then offers nothing but WAIT and BLOCKED.
    const frame = session.currentFrame() orelse return .{
        .url = "",
        .title = "",
        .text = "",
        .elements = &.{},
        .dropped = 0,
        .fingerprint = 0,
        .style_version = 0,
    };

    var elements: std.ArrayList(Element) = .empty;
    var collector: Collector = .{ .arena = arena, .elements = &elements };
    const tree = SemanticTree.init(arena, frame.document.asNode(), registry, frame, .{
        .interactive_only = true,
    }) catch return error.ObserveFailed;
    tree.visitAll(&collector) catch return error.ObserveFailed;

    // Bound the table here, once, so the state and every target head agree on
    // what exists. Doing it only in `targets` left the decider reading 521
    // element records while it could choose among 128 of them.
    const offered = try bound(arena, elements.items);

    for (offered, 1..) |*el, i| el.index = @enumFromInt(@as(u16, @intCast(i)));

    var table: Table = .{
        .url = frame.url,
        .title = (frame.getTitle() catch null) orelse "",
        .text = if (opts.text_bytes > 0) try renderText(arena, frame, opts.text_bytes) else "",
        .elements = offered,
        .dropped = collector.dropped + @as(u32, @intCast(elements.items.len - offered.len)),
        .fingerprint = 0,
        .style_version = frame.page.style_version,
    };
    table.fingerprint = fingerprint(table);
    return table;
}

/// Upstream keeps its table small by capturing only elements whose centre is
/// inside the viewport. With no layout to ask, role and label together are the
/// signal that two entries are the same control to a reader: a comment
/// thread's fifty identical `reply` links are one choice, not fifty.
///
/// Role matters as much as the label. A `<label for=q>Search</label>` names
/// its input "Search" and the submit `<button>Search</button>` next to it
/// carries the same name -- collapsing those two would delete the type-then-
/// submit pattern that most forms are.
///
/// An unnamed control is not a duplicate of the next unnamed one -- an item
/// page carries fifty-eight nameless upvote arrows and the row is the point of
/// them -- so those are kept and the cap is what bounds them.
fn bound(arena: std.mem.Allocator, all: []Element) ![]Element {
    // Hashed rather than printed: a duplicate would otherwise allocate its key
    // only to discard it, once per repeated control on the page.
    var seen: std.AutoHashMapUnmanaged(u64, void) = .empty;
    var kept: usize = 0;
    for (all) |el| {
        if (kept >= max_offered) break;
        if (el.label.len > 0) {
            var hasher: std.hash.Wyhash = .init(0);
            hasher.update(el.role);
            hasher.update(el.label);
            if ((try seen.getOrPut(arena, hasher.final())).found_existing) continue;
        }
        all[kept] = el;
        kept += 1;
    }
    return all[0..kept];
}

fn renderText(arena: std.mem.Allocator, frame: *lp.Frame, max_bytes: u32) ObserveError![]const u8 {
    // `clutter`/`shell` stay off: they are reader-mode heuristics that delete
    // page chrome, and chrome is where a headline or a result count lives. The
    // byte cap truncates visibly; a reader-mode pass silently removes the part
    // of the page the goal was about.
    const state = lp.RenderTree.resolve(arena, frame.document.asNode(), .{
        .js = true,
        .css = true,
        .ui = true,
        .invisible = true,
    }, frame) catch return error.OutOfMemory;

    var aw: std.Io.Writer.Allocating = .init(arena);
    lp.markdown.dump(state, .{ .max_bytes = max_bytes }, &aw.writer, frame) catch
        return error.ObserveFailed;
    return aw.written();
}

/// Identity plus current state of everything the decider can see. Geometry is
/// excluded: it moves on its own during animations without changing a single
/// available action.
fn fingerprint(table: Table) u64 {
    var hasher: std.hash.Wyhash = .init(0);
    hasher.update(table.url);
    hasher.update(table.title);
    // Not the page text: `moved` compares a text-free observation against a
    // full one, and the two have to agree.
    for (table.elements) |el| {
        // Deliberately not `node_id`: a registry id is identity, not
        // appearance, and navigating to the same page again mints fresh ones.
        // Liveness is a separate question, and `Table.live` answers it.
        hasher.update(el.role);
        hasher.update(el.label);
        hasher.update(el.value orelse "");
        hasher.update(std.mem.asBytes(&el.checked));
        hasher.update(std.mem.asBytes(&el.ops));
        for (el.options) |option| hasher.update(option);
    }
    return hasher.final();
}

const Collector = struct {
    arena: std.mem.Allocator,
    elements: *std.ArrayList(Element),
    dropped: u32 = 0,

    pub fn visit(self: *Collector, node: *Node, data: *SemanticTree.NodeData) !bool {
        // `NodeData.disabled` is the form-control attribute; `aria-disabled`
        // is a separate opt-out authors apply to custom controls and to whole
        // containers.
        if (data.disabled) return true;

        const ops = operationsFor(data);
        if (!ops.any()) return true;

        // After the cheap filters: this walks every ancestor, and almost
        // nothing the tree visits is a target.
        if (ariaDisabled(node)) return true;

        if (self.elements.items.len >= max_collected) {
            self.dropped += 1;
            return true;
        }

        // `SemanticTree.walk` clears a computed name for a generic role, so a
        // listener-bearing container arrives unnamed and its own text is what
        // a person would read off it. Same fallback `interactive` applies, so
        // both agent views name an element alike.
        var label = string.truncateUtf8(data.name orelse "", max_label_bytes);
        if (label.len == 0) {
            const text = (try interactive.getTextContent(node, self.arena)) orelse "";
            label = string.truncateUtf8(text, max_label_bytes);
        }

        var options: []const []const u8 = &.{};
        if (data.options) |opts| {
            const values = try self.arena.alloc([]const u8, opts.len);
            for (opts, 0..) |option, i| values[i] = option.value;
            options = values;
        }

        try self.elements.append(self.arena, .{
            .index = @enumFromInt(@as(u16, @intCast(self.elements.items.len + 1))),
            .node_id = data.id,
            .role = data.role,
            .label = label,
            .value = data.value,
            .checked = data.checked,
            .ops = ops,
            .options = options,
        });
        return true;
    }

    pub fn leave(_: *Collector) !void {}
};

/// `<select>` is offered as SELECT only: the composite `"<index>:<option>"`
/// target already picks a value, so also offering CLICK would double a target
/// head for nothing.
fn operationsFor(data: *const SemanticTree.NodeData) OpSet {
    if (std.mem.eql(u8, data.tag_name, "select")) {
        return if (data.options != null and data.options.?.len > 0) .{ .select = true } else .{};
    }
    if (std.mem.eql(u8, data.tag_name, "textarea")) {
        return .{ .type_text = true };
    }
    if (std.mem.eql(u8, data.tag_name, "input")) {
        // A datalist-backed input takes both a typed value and one of its
        // suggestions.
        const has_list = data.options != null and data.options.?.len > 0;
        if (string.isOneOf(data.role, &.{ "textbox", "searchbox", "combobox", "spinbutton" })) {
            return .{ .type_text = true, .select = has_list };
        }
        return .{ .click = true, .select = has_list };
    }
    if (data.interactive) return .{ .click = true };
    return .{};
}

/// True when the element or any ancestor is `aria-disabled="true"`.
fn ariaDisabled(node: *Node) bool {
    var current: ?*Node = node;
    while (current) |n| : (current = n._parent) {
        const el = n.is(DomElement) orelse continue;
        if (el.getAttributeInterned("aria-disabled")) |value| {
            if (std.ascii.eqlIgnoreCase(value, "true")) return true;
        }
    }
    return false;
}

/// One executed step. Only `op`, `target`, `text`, `ok` and `page_changed`
/// reach the decider; the rest feed the terminal and `--save`.
pub const Step = struct {
    number: u32,
    op: Operation,
    target: ?[]const u8 = null,
    /// The chosen element's label, for the terminal.
    label: []const u8 = "",
    /// The value typed, for TYPE_TEXT.
    text: ?[]const u8 = null,
    probability: f64 = 0,
    confidence: f64 = 0,
    latency_ms: u64 = 0,
    ok: bool = true,
    page_changed: bool = false,
};

/// How many executed steps the decider sees.
pub const recent_actions = 10;

/// Whether anything the decider can see moved.
pub fn changed(before: Table, after: Table) bool {
    return before.fingerprint != after.fingerprint or
        !std.mem.eql(u8, before.url, after.url);
}

/// The `state` document: the goal, the page, the indexed element table, and
/// the recent action history. Absent values are omitted rather than sent as
/// null — every byte here is a billed input token.
pub fn stateJson(
    arena: std.mem.Allocator,
    table: Table,
    goal: []const u8,
    step: u32,
    history: []const Step,
) std.mem.Allocator.Error![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    var jw: std.json.Stringify = .{ .writer = &aw.writer };
    writeState(&jw, table, goal, step, history) catch return error.OutOfMemory;
    return aw.written();
}

fn writeState(
    jw: *std.json.Stringify,
    table: Table,
    goal: []const u8,
    step: u32,
    history: []const Step,
) !void {
    try jw.beginObject();
    try jw.objectField("goal");
    try jw.write(goal);
    try jw.objectField("step");
    try jw.write(step);

    try jw.objectField("page");
    try jw.beginObject();
    try jw.objectField("url");
    try jw.write(table.url);
    try jw.objectField("title");
    try jw.write(table.title);
    try jw.objectField("text");
    try jw.write(table.text);
    try jw.endObject();

    try jw.objectField("elements");
    try jw.beginArray();
    for (table.elements) |el| {
        try jw.beginObject();
        try jw.objectField("i");
        try jw.write(@intFromEnum(el.index));
        try jw.objectField("role");
        try jw.write(el.role);
        if (el.label.len > 0) {
            try jw.objectField("label");
            try jw.write(el.label);
        }
        if (el.value) |value| {
            if (value.len > 0) {
                try jw.objectField("value");
                try jw.write(value);
            }
        }
        if (el.checked) |checked| {
            try jw.objectField("checked");
            try jw.write(checked);
        }
        try jw.objectField("ops");
        try jw.beginArray();
        inline for (.{ Operation.CLICK, Operation.TYPE_TEXT, Operation.SELECT }) |op| {
            if (el.ops.has(op)) try jw.write(@tagName(op));
        }
        try jw.endArray();
        if (el.options.len > 0) {
            try jw.objectField("options");
            try jw.write(el.options);
        }
        try jw.endObject();
    }
    try jw.endArray();

    // What the table leaves out, so the decider does not read a truncated
    // list as the whole page.
    if (table.dropped > 0) {
        try jw.objectField("elements_omitted");
        try jw.write(table.dropped);
    }

    try jw.objectField("recent_actions");
    try jw.beginArray();
    const start = history.len -| recent_actions;
    for (history[start..]) |entry| {
        try jw.beginObject();
        try jw.objectField("op");
        try jw.write(@tagName(entry.op));
        if (entry.target) |t| {
            try jw.objectField("target");
            try jw.write(t);
        }
        if (entry.text) |t| {
            try jw.objectField("text");
            try jw.write(t);
        }
        try jw.objectField("ok");
        try jw.write(entry.ok);
        try jw.objectField("page_changed");
        try jw.write(entry.page_changed);
        try jw.endObject();
    }
    try jw.endArray();
    try jw.endObject();
}

/// The speculative fan-out for one turn: the operation head plus one target
/// head per operation that actually has candidates. The offered option lists
/// come back alongside, because validating an answer means checking it against
/// exactly the set that was sent.
/// One turn's questions: the operation head plus a target head per operation
/// that has candidates. Kept as sent, because that is what an answer has to be
/// validated against.
pub const Ask = struct {
    questions: zenai.typesafe.types.Questions,

    pub fn entries(self: Ask) []const QuestionEntry {
        return self.questions.entries;
    }
};

pub const AskOpts = struct {
    /// False when no model is configured to write field values. TYPE_TEXT is
    /// then not offered at all: an operation the loop cannot carry out has no
    /// business in the action space.
    can_type: bool = true,
};

/// Build the turn's questions. An operation with no candidates is dropped from
/// the operation head *and* loses its target head, so the decider can never
/// pick something the page cannot do.
pub fn ask(arena: std.mem.Allocator, observed: Table, opts: AskOpts) std.mem.Allocator.Error!Ask {
    var operations: std.ArrayList(ChoiceEntry) = .empty;
    var entries: std.ArrayList(QuestionEntry) = .empty;

    inline for (.{ Operation.CLICK, Operation.TYPE_TEXT, Operation.SELECT }) |op| {
        const candidates: []const ChoiceEntry = if (op == .TYPE_TEXT and !opts.can_type)
            &.{}
        else
            try observed.criteria(arena, op);
        if (candidates.len > 0) {
            try operations.append(arena, describe(op));
            try entries.append(arena, .{
                .key = op.targetQuestion().?,
                .value = .{ .choice = .{
                    .instructions = .{ .text = target_instructions[@intFromEnum(op)] },
                    .criteria = .init(candidates),
                } },
            });
        }
    }

    inline for (.{ Operation.WAIT, Operation.DONE, Operation.BLOCKED }) |op| {
        try operations.append(arena, describe(op));
    }

    try entries.insert(arena, 0, .{
        .key = "operation",
        .value = .{ .choice = .{
            .instructions = .{ .text = prompts.next_action },
            .criteria = .init(operations.items),
        } },
    });
    return .{ .questions = .init(entries.items) };
}

const ChoiceEntry = zenai.typesafe.types.ChoiceCriteria.Entry;
const Content = zenai.typesafe.types.Content;

fn describe(comptime op: Operation) ChoiceEntry {
    return .{ .key = @tagName(op), .value = .{ .text = prompts.describe(op) } };
}

/// Both halves are constant per operation, so the per-turn `allocPrint` the
/// three heads used to do was ~1.5 KB of identical text rebuilt every step.
const target_instructions = blk: {
    var out: [@typeInfo(Operation).@"enum".fields.len][]const u8 = undefined;
    for (&out, 0..) |*slot, i| {
        const op: Operation = @enumFromInt(i);
        slot.* = prompts.target ++ "\n\nThe operation this question chooses a target for is " ++
            @tagName(op) ++ ".\n\n" ++ prompts.next_action;
    }
    break :blk out;
};

const testing = @import("../../testing.zig");

/// `expectEqualSlices` compares slices of slices by pointer, which is never
/// what a list of option ids means.
fn expectOptions(expected: []const []const u8, actual: ?zenai.typesafe.types.Question) !void {
    const question = actual orelse return error.TestExpectedCriteria;
    const criteria = switch (question) {
        .choice => |c| c.criteria,
        else => return error.TestExpectedCriteria,
    };
    try std.testing.expectEqual(expected.len, criteria.count());
    for (expected, criteria.entries) |want, got| try std.testing.expectEqualStrings(want, got.key);
}

/// A hand-built table, so the serialization tests do not depend on a page.
fn fixtureTable() Table {
    const elements = [_]Element{
        .{
            .index = @enumFromInt(1),
            .node_id = 11,
            .role = "searchbox",
            .label = "Search",
            .value = "ramen",
            .checked = null,
            .ops = .{ .type_text = true },
            .options = &.{},
        },
        .{
            .index = @enumFromInt(2),
            .node_id = 12,
            .role = "button",
            .label = "Go",
            .value = null,
            .checked = null,
            .ops = .{ .click = true },
            .options = &.{},
        },
        .{
            .index = @enumFromInt(3),
            .node_id = 13,
            .role = "combobox",
            .label = "Party size",
            .value = "2",
            .checked = null,
            .ops = .{ .select = true },
            .options = &.{ "1", "2" },
        },
    };
    return .{
        .url = "https://example.com/search",
        .title = "Search",
        .text = "Reserve a table",
        .elements = &elements,
        .dropped = 0,
        .fingerprint = 0,
        .style_version = 0,
    };
}

test "observe: only what the page offers, densely indexed" {
    var registry: lp.NodeRegistry = .init(std.testing.allocator);
    defer registry.deinit();

    var page = try testing.pageTest("jev/action_space.html", .{ .wait_until_done = true });
    defer page.close();

    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const observed = try observe(arena.allocator(), page.session, &registry, .{});

    // The disabled button, the `aria-disabled` span and the `display:none`
    // input are all absent; indices are dense and in document order.
    try std.testing.expectEqual(@as(usize, 7), observed.elements.len);
    for (observed.elements, 1..) |el, i| {
        try std.testing.expectEqual(@as(u16, @intCast(i)), @intFromEnum(el.index));
        try std.testing.expect(el.node_id != 0);
    }

    const search = observed.elements[0];
    try std.testing.expectEqualStrings("searchbox", search.role);
    try std.testing.expectEqualStrings("Search", search.label);
    try std.testing.expectEqualStrings("ramen", search.value.?);
    try std.testing.expectEqual(OpSet{ .type_text = true }, search.ops);

    try std.testing.expectEqual(OpSet{ .type_text = true }, observed.elements[1].ops);

    // Optgroups are flattened; the select is offered as SELECT only.
    const party = observed.elements[2];
    try std.testing.expectEqual(OpSet{ .select = true }, party.ops);
    try std.testing.expectEqualStrings("2", party.value.?);
    try std.testing.expectEqual(@as(usize, 3), party.options.len);
    try std.testing.expectEqualStrings("6", party.options[2]);

    const checkbox = observed.elements[3];
    try std.testing.expectEqual(OpSet{ .click = true }, checkbox.ops);
    try std.testing.expectEqual(false, checkbox.checked.?);

    try std.testing.expectEqualStrings("Registered handler", observed.elements[6].label);

    try std.testing.expect(std.mem.indexOf(u8, observed.text, "Reserve a table") != null);
    try std.testing.expect(observed.live(&registry));
    try std.testing.expect(observed.fingerprint != 0);
}

test "observe: text can be skipped for a fingerprint-only snapshot" {
    var registry: lp.NodeRegistry = .init(std.testing.allocator);
    defer registry.deinit();

    var page = try testing.pageTest("jev/action_space.html", .{ .wait_until_done = true });
    defer page.close();

    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const full = try observe(arena.allocator(), page.session, &registry, .{});
    const bare = try observe(arena.allocator(), page.session, &registry, .{ .text_bytes = 0 });

    try std.testing.expectEqualStrings("", bare.text);
    // The page did not move, so the two snapshots must agree.
    try std.testing.expectEqual(full.fingerprint, bare.fingerprint);
    try std.testing.expect(!changed(full, bare));
}

test "parseTarget: only an offered index, for an operation the element accepts" {
    const t = fixtureTable();

    try std.testing.expectEqual(@as(u32, 12), (try t.parseTarget(.CLICK, "2")).element.node_id);
    const selected = try t.parseTarget(.SELECT, "3:2");
    try std.testing.expectEqual(@as(u32, 13), selected.element.node_id);
    try std.testing.expectEqualStrings("2", selected.option.?);

    // Wrong operation for that element.
    try std.testing.expectError(error.InvalidTarget, t.parseTarget(.CLICK, "1"));
    try std.testing.expectError(error.InvalidTarget, t.parseTarget(.TYPE_TEXT, "2"));
    // SELECT needs an option, and nothing else may carry one.
    try std.testing.expectError(error.InvalidTarget, t.parseTarget(.SELECT, "3"));
    try std.testing.expectError(error.InvalidTarget, t.parseTarget(.CLICK, "2:1"));
    // An option the element does not have.
    try std.testing.expectError(error.InvalidTarget, t.parseTarget(.SELECT, "3:99"));
    // Off the end, zero, and not a number at all.
    try std.testing.expectError(error.InvalidTarget, t.parseTarget(.CLICK, "9"));
    try std.testing.expectError(error.InvalidTarget, t.parseTarget(.CLICK, "0"));
    try std.testing.expectError(error.InvalidTarget, t.parseTarget(.CLICK, "x"));
    try std.testing.expectError(error.InvalidTarget, t.parseTarget(.CLICK, ""));
}

test "stateJson: the decider sees indices, never node ids" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const history = [_]Step{
        .{ .number = 1, .op = .CLICK, .target = "2", .ok = true, .page_changed = true },
        .{ .number = 2, .op = .TYPE_TEXT, .target = "1", .text = "ramen", .ok = true, .page_changed = false },
    };
    const state = try stateJson(arena.allocator(), fixtureTable(), "book a table", 3, &history);

    try std.testing.expectEqualStrings(
        \\{"goal":"book a table","step":3,"page":{"url":"https://example.com/search","title":"Search","text":"Reserve a table"},"elements":[{"i":1,"role":"searchbox","label":"Search","value":"ramen","ops":["TYPE_TEXT"]},{"i":2,"role":"button","label":"Go","ops":["CLICK"]},{"i":3,"role":"combobox","label":"Party size","value":"2","ops":["SELECT"],"options":["1","2"]}],"recent_actions":[{"op":"CLICK","target":"2","ok":true,"page_changed":true},{"op":"TYPE_TEXT","target":"1","text":"ramen","ok":true,"page_changed":false}]}
    , state);
}

test "ask: an operation with no candidates loses its head and its option" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const full = try ask(a, fixtureTable(), .{});
    try expectOptions(&.{"2"}, full.questions.get("click_target"));
    try expectOptions(&.{"1"}, full.questions.get("type_text_target"));
    try expectOptions(&.{ "3:1", "3:2" }, full.questions.get("select_target"));
    // The operation head comes first so the answer is easy to find.
    try std.testing.expectEqualStrings("operation", full.entries()[0].key);
    try std.testing.expectEqual(@as(usize, 4), full.entries().len);
    try expectOptions(&.{
        "CLICK", "TYPE_TEXT", "SELECT", "WAIT", "DONE", "BLOCKED",
    }, full.questions.get("operation"));

    var narrow = fixtureTable();
    narrow.elements = fixtureTable().elements[1..2]; // the button alone
    const only_click = try ask(a, narrow, .{});
    try std.testing.expectEqual(@as(usize, 2), only_click.entries().len);
    try std.testing.expectEqualStrings("click_target", only_click.entries()[1].key);
    try std.testing.expectEqual(@as(?zenai.typesafe.types.Question, null), only_click.questions.get("type_text_target"));
}

test "targets: no head can exceed what a choice question accepts" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // One `<select>` is enough to overflow the head on its own.
    const options = try a.alloc([]const u8, 400);
    for (options, 0..) |*option, i| option.* = try std.fmt.allocPrint(a, "opt{d}", .{i});
    const picker = [_]Element{.{
        .index = @enumFromInt(1),
        .node_id = 1,
        .role = "combobox",
        .label = "Country",
        .value = null,
        .checked = null,
        .ops = .{ .select = true },
        .options = options,
    }};

    var t = fixtureTable();
    t.elements = &picker;
    const select = try t.criteria(a, .SELECT);
    try std.testing.expectEqual(max_offered, select.len);
    try std.testing.expectEqualStrings("1:opt0", select[0].key);

    const ask_result = try ask(a, t, .{});
    try std.testing.expectEqual(max_offered, ask_result.questions.get("select_target").?.choice.criteria.count());
    // The API rejects a choice question with more than 255 options outright.
    try std.testing.expect(max_offered <= 255);
}

test "criteria: an id and nothing else, since the state already describes it" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const typed = try fixtureTable().criteria(a, .TYPE_TEXT);
    try std.testing.expectEqual(@as(usize, 1), typed.len);
    try std.testing.expectEqualStrings("1", typed[0].key);
    try std.testing.expectEqual(@as(?Content, null), typed[0].value);

    const clicked = try fixtureTable().criteria(a, .CLICK);
    try std.testing.expectEqualStrings("2", clicked[0].key);
    try std.testing.expectEqual(@as(?Content, null), clicked[0].value);

    // A select option keeps its compound id: the element table has no row for
    // one option, so the id is the only thing that identifies it.
    const picked = try fixtureTable().criteria(a, .SELECT);
    try std.testing.expectEqualStrings("3:1", picked[0].key);
    try std.testing.expectEqual(@as(?Content, null), picked[0].value);
}

test "bound: one entry per distinct label, since we cannot ask what is on screen" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A comment thread: every row carries its own identical "reply" link.
    var rows: [40]Element = undefined;
    for (&rows, 0..) |*el, i| el.* = .{
        .index = @enumFromInt(@as(u16, @intCast(i + 1))),
        .node_id = @intCast(i + 1),
        .role = "link",
        .label = "reply",
        .value = null,
        .checked = null,
        .ops = .{ .click = true },
        .options = &.{},
    };

    // Upstream never sees these: all but the first few are outside its
    // viewport. With no layout to ask, the label is what tells them apart.
    var once = rows;
    try std.testing.expectEqual(@as(usize, 1), (try bound(a, &once)).len);

    // Distinct labels all survive.
    var two = rows;
    two[7].label = "permalink";
    try std.testing.expectEqual(@as(usize, 2), (try bound(a, &two)).len);

    // Same label, different control: a search field and the button that
    // submits it are both named "Search", and losing either breaks the form.
    var same_name = rows;
    same_name[0].role = "searchbox";
    same_name[0].label = "Search";
    same_name[1].role = "button";
    same_name[1].label = "Search";
    const both = try bound(a, &same_name);
    try std.testing.expectEqual(@as(usize, 3), both.len);
    try std.testing.expectEqualStrings("searchbox", both[0].role);
    try std.testing.expectEqualStrings("button", both[1].role);

    // Unnamed controls are not duplicates of each other: an upvote arrow per
    // row has no name, and the row is the whole point.
    var unnamed = rows;
    for (&unnamed) |*el| el.label = "";
    try std.testing.expectEqual(rows.len, (try bound(a, &unnamed)).len);
}

test "ask: TYPE_TEXT is not offered without a model to write the value" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const typeless = try ask(a, fixtureTable(), .{ .can_type = false });
    try expectOptions(&.{
        "CLICK", "SELECT", "WAIT", "DONE", "BLOCKED",
    }, typeless.questions.get("operation"));
    // Its head goes with it, so there is nothing to select even speculatively.
    try std.testing.expectEqual(@as(?zenai.typesafe.types.Question, null), typeless.questions.get("type_text_target"));
    // The field is still listed: it is worth knowing the page has one.
    try std.testing.expectEqual(@as(usize, 3), fixtureTable().elements.len);
}
