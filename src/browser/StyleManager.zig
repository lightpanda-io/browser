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

const Frame = @import("Frame.zig");
const Viewport = @import("Viewport.zig");
const text_measure = @import("text_measure.zig");

const units = @import("css/units.zig");
const CssParser = @import("css/Parser.zig");
const MediaQuery = @import("css/MediaQuery.zig");
const Animation = @import("css/Animation.zig");
const properties = @import("css/properties.zig");
const DeclarationBlock = @import("css/DeclarationBlock.zig");
const Node = @import("webapi/Node.zig");
const Element = @import("webapi/Element.zig");
const TreeWalker = @import("webapi/TreeWalker.zig");
const popover = @import("webapi/element/popover.zig");

const Selector = @import("webapi/selector/Selector.zig");
const SelectorParser = @import("webapi/selector/Parser.zig");
const SelectorList = @import("webapi/selector/List.zig");

const RuleStore = @import("css/RuleStore.zig");
const CSSStyleSheet = @import("webapi/css/CSSStyleSheet.zig");

const log = lp.log;
const String = lp.String;
const Allocator = std.mem.Allocator;

// Tracks the CSS properties the renderless layout acts on (display, visibility,
// opacity, pointer-events, overflow, width, height) and text-transform, which
// innerText applies, from author stylesheets.
// Rules are bucketed by their rightmost selector part for fast lookup.
const StyleManager = @This();

const Tag = Element.Tag;
const Input = Element.Html.Input;

frame: *Frame,

arena: *lp.Arena,

visibility: Group(Visibility) = .{},
geometry: Group(Geometry) = .{},
touch_action: Group(TouchAction) = .{},
text: Group(Text) = .{},
flow: Group(Flow) = .{},

layout_memo: LayoutMemo = .{},

// Inline writes of a property the layout memos read, and tree changes whose
// cascade entries treeChanged dropped itself: boxes move either way.
layout_bumps: usize = 0,

// Inline height writes that reached the root, see extentVersion.
extent_bumps: usize = 0,

// The rules declaring each custom property and `content`, by property id,
// pruning to what is (hopefully) one or few rules. Nothing memoizes `content`:
// it only matters to scripts reading it back, often from a probe element.
// @ant-design/cssinjs reads which styles a static CSS file already ships from a
// `content` rule.
lazy_rules: std.HashMapUnmanaged(properties.Id, LazyRules, IdContext, std.hash_map.default_max_load_percentage) = .empty,

// The rules declaring each animation property, the shorthand apart from the
// longhands. frame/css_animations.zig reads them to fire the animation events.
animation_rules: std.enums.EnumArray(Animation.Property, LazyRules) = .initFill(.{}),

// The @keyframes names. An animation-name without keyframes runs nothing.
keyframes: std.StringHashMapUnmanaged(void) = .empty,

// Whether a sheet's text says "keyframes", until the next sheetModified().
keyframes_mentioned: ?bool = null,

/// The thing to remember about layers is that we can't determine priority's
/// layer_rank until everything is parsed. So we need to build up meta data when
/// rebuilding and do one final pass to apply the resulting layering rank.

// Layer registry rebuilt with the rules. Append-only.
layers: std.ArrayList(Layer) = .empty,
// layer full name -> layers index
layer_ids: std.StringHashMapUnmanaged(u16) = .empty,
// rule -> layers index, e.g. for rule at index N, rule_layers[N] is its layer
rule_layers: std.ArrayList(u16) = .empty,

next_anon_layer: u32 = 0,

// Document order counter for tie-breaking equal specificity. Starts at 1;
// a priority of 0 means no author rule applied (see compute).
next_doc_order: u32 = 1,

// When true, rules need to be rebuilt
dirty: bool = false,

// A rule's selector reads the style attribute, so any inline style write can
// change what it matches.
reads_style_attribute: bool = false,

// The attribute names the tracked selectors read. Nested selectors (:is,
// :not, :has, ...) and pseudo-classes included.
attribute_names: std.HashMapUnmanaged([]const u8, void, AttributeNameContext, std.hash_map.default_max_load_percentage) = .empty,

// Can any tracked selector read a form, or depends on :empty or uses :has
// pseudo-selector. All of these are mechanisms that break normal selector
// hierachy (e.g. selectors don't match up, or into their sibling trees), and
// thus having any selector like this disables some optimizations. TODO: make
// this more selective than a global boolean.
reads_form: bool = false,
reads_default: bool = false,
reads_empty: bool = false,
siblings: SiblingReads = .{},

// given a class name, what, if anything, does it reach. Best class: a class
// that no selector we track uses is a noop.
class_reach: std.HashMapUnmanaged([]const u8, ClassReach, AttributeNameContext, std.hash_map.default_max_load_percentage) = .empty,

// The widest reach of a compound reading the class attribute as a string
// ([class*=x]): any change to it can change what that matches. Null: none.
class_attribute_reach: ?ClassReach = null,
has: HasKeys = .{},

// Short dudupe list of roots that had treeChanged call since the memos last
// filled. They don't need to be dropped again. Useful for common pattern of
// appending in a loop.
dropped: [4]*Node = undefined,
dropped_len: u8 = 0,
dropped_fills: usize = 0,

// treeChanged's visited elements, our tests want to count work, not time
walked: if (lp.IS_TEST) usize else void = if (lp.IS_TEST) 0 else {},

// The sheet that emitted the highest document order. A rule appended to it,
// or to a later sheet, stays last in cascade order.
last_rule_sheet: ?*CSSStyleSheet = null,

pub fn init(frame: *Frame) !StyleManager {
    return .{
        .frame = frame,
        .arena = try frame.getArena(.medium, "StyleManager"),
    };
}

// el's index into every StyleManager's records
fn claimSlot(self: *StyleManager, el: *Element) ?u32 {
    if (el._style_slot != 0) {
        return el._style_slot;
    }
    const page = self.frame.page;
    if (page.next_style_slot == std.math.maxInt(u32)) {
        // Unlikely, but doesn't break anything. Just gets slower: el isn't memoized
        return null;
    }
    const index = page.next_style_slot;
    el._style_slot = index;
    page.next_style_slot = index + 1;
    return index;
}

/// The values for one group, by Element._style_slot. Chunked in groups of 256
/// so we can grow without copying into the arena.
fn Records(comptime T: type) type {
    return struct {
        generation: u32 = 1, // An entry is valid so long as its stamp == generation
        len: u32 = 0, // valid entries
        chunks: std.ArrayList(?*Chunk) = .empty,

        const Self = @This();
        const chunk_shift = 8;
        const chunk_len = 1 << chunk_shift;
        const Entry = struct { stamp: u32, value: T };
        const Chunk = [chunk_len]Entry;

        fn entry(self: *const Self, el: *const Element) ?*Entry {
            const slot = el._style_slot;
            if (slot == 0) {
                return null;
            }
            const i = slot >> chunk_shift;
            if (i >= self.chunks.items.len) {
                return null;
            }
            const chunk = self.chunks.items[i] orelse return null;
            return &chunk[slot & (chunk_len - 1)];
        }

        pub fn get(self: *const Self, el: *const Element) ?T {
            const e = self.entry(el) orelse return null;
            return if (e.stamp == self.generation) e.value else null;
        }

        fn getPtr(self: *const Self, el: *const Element) ?*T {
            const e = self.entry(el) orelse return null;
            return if (e.stamp == self.generation) &e.value else null;
        }

        pub fn contains(self: *const Self, el: *const Element) bool {
            return self.get(el) != null;
        }

        pub fn count(self: *const Self) u32 {
            return self.len;
        }

        // Whether it held a valid entry
        fn remove(self: *Self, el: *const Element) bool {
            const e = self.entry(el) orelse return false;
            if (e.stamp != self.generation) {
                return false;
            }
            e.stamp = 0;
            self.len -= 1;
            return true;
        }

        // `index` is el's, from claimSlot
        fn put(self: *Self, allocator: Allocator, index: u32, value: T) !void {
            const i = index >> chunk_shift;
            if (i >= self.chunks.items.len) {
                try self.chunks.appendNTimes(allocator, null, i + 1 - self.chunks.items.len);
            }
            const chunk = self.chunks.items[i] orelse blk: {
                const chunk = try allocator.create(Chunk);
                for (chunk) |*e| {
                    e.stamp = 0;
                }
                self.chunks.items[i] = chunk;
                break :blk chunk;
            };
            const e = &chunk[index & (chunk_len - 1)];
            // callers put what they missed
            std.debug.assert(e.stamp != self.generation);
            self.len += 1;
            e.* = .{ .stamp = self.generation, .value = value };
        }

        fn clear(self: *Self) void {
            self.len = 0;
            self.generation +%= 1;
            if (self.generation == 0) {
                // Wrapped: a stamp from 2^32 clears ago would come back valid
                for (self.chunks.items) |chunk_| {
                    const chunk = chunk_ orelse continue;
                    for (chunk) |*e| {
                        e.stamp = 0;
                    }
                }
                self.generation = 1;
            }
        }
    };
}

pub fn deinit(self: *StyleManager) void {
    self.arena.release();
}

// StyleManager methods should always be invoked on the StyleManager of the
// Frame associated with an Element's document.
fn assertOwns(self: *const StyleManager, el_: ?*const Element) void {
    if (comptime lp.IS_DEBUG == false) {
        return;
    }
    const el = el_ orelse return;
    std.debug.assert(el.ownerFrame(self.frame) == self.frame);
}

/// Hard cap on rule nesting depth: `@media` / `@layer` blocks and nested
/// style rules. CSS allows arbitrarily-deep nesting; without a cap a hostile
/// stylesheet could blow the Zig stack via the recursive parse and
/// `addStoredRules`. 32 is well past anything seen in the wild.
pub const MAX_AT_RULE_NESTING: u8 = 32;

fn parseSheet(self: *StyleManager, build_arena: Allocator, sheet: *CSSStyleSheet) !void {
    // A <style> is parsed into its store on first use
    try sheet.ensureParsed(self.frame);
    try self.addStoredRules(build_arena, &sheet._store, 0, NO_LAYER, null);
}

/// Adds a store's rules in cascade order.
fn addStoredRules(self: *StyleManager, build_arena: Allocator, store: *const RuleStore, depth: u8, layer: u16, nest: ?[]const u8) Allocator.Error!void {
    if (depth >= MAX_AT_RULE_NESTING) {
        return;
    }
    for (store.entries()) |*entry| {
        switch (entry._kind) {
            .style => {
                const selector = if (nest) |parent|
                    // The arena, not build_arena: a custom property's rule
                    // keeps its selector text past the rebuild.
                    try CssParser.resolveNestedSelector(self.arena.allocator(), parent, entry.text()) orelse continue
                else
                    entry.text();
                if (selector.len == 0) {
                    // An invalid rule: its nested rules go with it
                    continue;
                }
                _ = try self.addStoredRule(entry, selector, layer);
                if (entry._children) |children| {
                    try self.addStoredRules(build_arena, children, depth + 1, layer, selector);
                }
            },
            .media => try self.applyMediaRule(build_arena, entry, depth, layer, nest),
            .layer => try self.applyLayerRule(build_arena, entry, depth, layer, nest),
            .keyframes => try self.addKeyframes(entry.text()),
            // `@supports` isn't evaluated: its rules are dropped. The others
            // (`@font-face`, …) hold nothing the cascade reads.
            else => {},
        }
    }
}

/// Apply an `@media` rule: when its query matches the current viewport, its
/// rules as if they lived where the rule does. A non-matching one drops them.
fn applyMediaRule(self: *StyleManager, build_arena: Allocator, entry: *const RuleStore.Entry, depth: u8, layer: u16, nest: ?[]const u8) Allocator.Error!void {
    // Without a block, it's nothing
    const children = entry._children orelse return;
    if (MediaQuery.matches(CssParser.atRulePrelude(entry.text()), self.frame.page.getViewport()) == false) {
        return;
    }
    try self.applyGroupRules(build_arena, entry, children, depth + 1, layer, nest);
}

/// Apply an `@layer` rule (css-cascade-5). Layers have two forms:
/// 1 - Block form which may or may not have a name. We register the layer and
//      add its rules.
/// 2 - Statement form only registes the name for ordering.
///
/// The layer parameter is the enclosing layer, or NO_LAYER at the top level.
/// Priority is not assigned here, we need all the layers parsed to do that
/// (since a layer statement can alter the ordering). So we'll do one final pass
// in finalizerLayerRanks. `nest` is as for addStoredRules.
fn applyLayerRule(self: *StyleManager, build_arena: Allocator, entry: *const RuleStore.Entry, depth: u8, layer: u16, nest: ?[]const u8) Allocator.Error!void {
    const prelude = CssParser.atRulePrelude(entry.text());
    const children = entry._children orelse {
        // Statement form: `@layer <name>, <name>;`. One invalid name
        // invalidates the whole statement. Validate everything before
        // registering anything.
        var names = prelude;
        if (std.mem.findScalar(u8, names, ';')) |semi| {
            names = names[0..semi];
        }

        var check = std.mem.splitScalar(u8, names, ',');
        while (check.next()) |raw| {
            if (isValidLayerName(std.mem.trim(u8, raw, &std.ascii.whitespace)) == false) {
                return;
            }
        }

        var it = std.mem.splitScalar(u8, names, ',');
        while (it.next()) |raw| {
            _ = try self.registerLayerPath(build_arena, layer, std.mem.trim(u8, raw, &std.ascii.whitespace));
        }
        return;
    };

    if (prelude.len != 0 and isValidLayerName(prelude) == false) {
        // An invalid layer name invalidates the whole rule.
        return;
    }

    const id = if (prelude.len == 0)
        try self.internAnonymousLayer(build_arena, layer)
    else
        try self.registerLayerPath(build_arena, layer, prelude);

    try self.applyGroupRules(build_arena, entry, children, depth + 1, id, nest);
}

/// The rules of a grouping rule that applies. One nested in a style rule
/// first adds its own declarations, which are that rule's: `.a { @media (…) {
/// color: red } }` is `@media (…) { .a { color: red } }`.
fn applyGroupRules(self: *StyleManager, build_arena: Allocator, entry: *const RuleStore.Entry, children: *const RuleStore, depth: u8, layer: u16, nest: ?[]const u8) Allocator.Error!void {
    if (nest) |selector| {
        _ = try self.addStoredRule(entry, selector, layer);
    }
    try self.addStoredRules(build_arena, children, depth, layer, nest);
}

/// `text` is the whole `@keyframes <name> { … }` rule; the name can be a string.
fn addKeyframes(self: *StyleManager, text: []const u8) Allocator.Error!void {
    if (self.animationsEnabled() == false) {
        return;
    }
    const open = std.mem.findScalar(u8, text, '{') orelse return;
    const keyword_end = std.mem.findAny(u8, text[0..open], &std.ascii.whitespace) orelse return;
    const name = std.mem.trim(u8, text[keyword_end..open], " \t\r\n\x0c\"'");
    if (name.len == 0) {
        return;
    }
    const arena = self.arena.allocator();
    const gop = try self.keyframes.getOrPut(arena, name);
    if (gop.found_existing == false) {
        // A CSSOM rule's text goes with the rule
        gop.key_ptr.* = try arena.dupe(u8, name);
    }
}

/// Register a (possibly dotted) layer name declared inside `parent`,
/// creating any missing ancestors, and return the layer's id. The name must
/// already have passed isValidLayerName — per css-cascade-5 an invalid name
/// invalidates the containing rule, which callers handle before registering.
fn registerLayerPath(self: *StyleManager, build_arena: Allocator, parent: u16, dotted: []const u8) Allocator.Error!u16 {
    var current = parent;
    var it = std.mem.splitScalar(u8, dotted, '.');
    while (it.next()) |component| {
        // should have been verified by the caller, via isValidLayerName
        if (comptime lp.IS_DEBUG) {
            std.debug.assert(isValidLayerComponent(component));
        }

        // Components past the depth cap collapse into their ancestor;
        // MAX_AT_RULE_NESTING also bounds finalizeLayerRanks' path buffers.
        if (current != NO_LAYER and self.layers.items[current].depth >= MAX_AT_RULE_NESTING) {
            break;
        }
        current = try self.internLayer(build_arena, current, component);
    }
    return current;
}

/// Each anonymous `@layer { … }` block is its own distinct layer
fn internAnonymousLayer(self: *StyleManager, build_arena: Allocator, parent: u16) Allocator.Error!u16 {
    const id = self.next_anon_layer;
    // \x00{d} isn't a valid layer name, so this can't conflict
    const name = try build_arena.print("\x00{d}", .{id});
    self.next_anon_layer = id + 1;
    return self.internLayer(build_arena, parent, name);
}

fn internLayer(self: *StyleManager, build_arena: Allocator, parent: u16, name: []const u8) Allocator.Error!u16 {
    const path = if (parent == NO_LAYER)
        try build_arena.dupe(u8, name)
    else
        try build_arena.print("{s}.{s}", .{ self.layers.items[parent].path, name });

    const gop = try self.layer_ids.getOrPut(build_arena, path);
    if (gop.found_existing) {
        return gop.value_ptr.*;
    }

    if (self.layers.items.len >= MAX_LAYERS) {
        _ = self.layer_ids.remove(path);
        return parent;
    }

    const id: u16 = @intCast(self.layers.items.len);
    gop.value_ptr.* = id;
    const depth = if (parent == NO_LAYER) 1 else self.layers.items[parent].depth + 1;
    try self.layers.append(build_arena, .{ .path = path, .parent = parent, .depth = depth });
    return id;
}

fn isValidLayerName(dotted: []const u8) bool {
    var it = std.mem.splitScalar(u8, dotted, '.');
    while (it.next()) |component| {
        if (isValidLayerComponent(component) == false) {
            return false;
        }
    }
    return true;
}

fn isValidLayerComponent(component: []const u8) bool {
    if (component.len == 0) {
        return false;
    }
    if (std.ascii.isDigit(component[0])) {
        return false;
    }
    for (component) |c| {
        switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '-', '_' => {},
            else => if (c < 0x80) return false,
        }
    }
    return true;
}

/// Compute every layer's rank and apply it to every group Rule we have.
/// We can only do this now that we've parsed every parsed every sheet since
/// @layer statement can change the ordering/
fn finalizeLayerRanks(self: *StyleManager, build_arena: Allocator) Allocator.Error!void {
    const layers = self.layers.items;

    if (layers.len == 0) {
        // No layers. Every group Rule already has the correct layerless
        // priority, and with no layers, there's nothing to adjust.
        return;
    }

    {
        // If we have three layers:
        //   @layer a.x { ... }
        //   @layer b   { ... }
        //   @layer a.y { ... }
        // If we prioritize them by the order they are defined, we'd get:
        //    a.x => 1  (lowest priority),  b => 2  and  a.y => 3 (highest priority)
        //
        // But it should really be:
        //     a.x => 1, a.y => 2, b => 3
        //
        // because a.y "inherits" the lower priority of the "a" from "a.x" having
        // been declared first.
        //
        // So we need to create something:
        //  a.x => [0, 1],  b => [2], a.y => [0, 3]
        //
        // And now when we sort them, we'll get the correct order because[2] > [0, 3]

        const paths = try build_arena.alloc([]const u16, layers.len);
        for (layers, 0..) |layer, i| {
            const path = try build_arena.alloc(u16, layer.depth);
            var id: u16 = @intCast(i);
            var d = layer.depth;
            while (d > 0) {
                d -= 1;
                path[d] = id;
                id = layers[id].parent;
            }
            paths[i] = path;
        }

        const order = try build_arena.alloc(u16, layers.len);
        for (order, 0..) |*slot, i| {
            slot.* = @intCast(i);
        }

        std.mem.sort(u16, order, paths, struct {
            fn lessThan(ctx: []const []const u16, a: u16, b: u16) bool {
                const pa = ctx[a];
                const pb = ctx[b];
                const common = @min(pa.len, pb.len);
                for (pa[0..common], pb[0..common]) |ca, cb| {
                    if (ca != cb) {
                        return ca < cb;
                    }
                }
                return pa.len > pb.len;
            }
        }.lessThan);

        for (order, 0..) |id, rank| {
            layers[id].rank = @intCast(rank);
        }
    }

    inline for (group_fields) |field| {
        @field(self, field).stampRules(self);
    }

    // Lazy rules parse their selectors on first lookup, but the layer ranks
    // are only known now that every sheet has been read
    var lazy_it = self.lazy_rules.valueIterator();
    while (lazy_it.next()) |property| {
        property.stampRules(self);
    }
    for (&self.animation_rules.values) |*rules| {
        rules.stampRules(self);
    }
}

/// The rank finalizeLayerRanks still has to stamp for a packed priority, via
/// its doc_order: 0 for an unlayered rule, which packed its rank at creation.
fn layerRank(self: *const StyleManager, priority: u64) u64 {
    const doc_order: u32 = @as(u22, @truncate(priority));
    const layer = self.rule_layers.items[doc_order - 1];
    if (layer == NO_LAYER) {
        return 0;
    }
    const rank = self.layers.items[layer].rank;
    // Important declarations cascade their layers in reverse
    if (priority & IMPORTANT_BIT != 0) {
        return UNLAYERED_RANK - rank;
    }
    return rank;
}

// Tracked rules get one group Rule per selector (not per selector list)
// so each has correct specificity, bucketed by their rightmost selector part.
// Custom properties and `content` are lazy rules instead, keyed by id: they
// parse the selector on first lookup. Returns whether the rule set a tracked or
// a custom property: nothing memoizes `content`.
fn addSelectorRules(
    self: *StyleManager,
    selector_text: []const u8,
    // By pointer: inlined, by value would copy them for every rule
    props: *const Declarations,
    important: *const Declarations,
    declared: LazyDeclarations,
    layer: u16,
) !bool {
    var lazy = declared;
    if (self.animationsEnabled() == false) {
        lazy.animation = .{};
    }
    if ((lazy.declares(.content) or lazy.animation.isEmpty() == false) and selectsOnlyPseudoElements(selector_text)) {
        // Icon fonts declare `content` on hundreds of `::before` rules, spinners
        // an animation, and no element matches one.
        lazy.dropContent();
        lazy.animation = .{};
    }

    const relevant = props.isRelevant() or important.isRelevant();
    if (relevant == false and lazy.isEmpty()) {
        return false;
    }

    const arena = self.arena.allocator();
    var changed = lazy.declaresCustom();

    if (lazy.isEmpty() == false) {
        const priority = try self.nextPriority(layer);
        const important_priority = IMPORTANT_BIT | (priority & ~RANK_MASK);
        for (lazy.declared) |declaration| {
            const gop = try self.lazy_rules.getOrPut(arena, declaration.id);
            if (gop.found_existing == false) {
                gop.value_ptr.* = .{};
            }
            try gop.value_ptr.append(arena, selector_text, declaration.value, if (declaration.important) important_priority else priority);
        }
        for (std.enums.values(Animation.Property)) |property| {
            const rules = self.animation_rules.getPtr(property);
            if (lazy.animation.normal.get(property)) |value| {
                try rules.append(arena, selector_text, value, priority);
            }
            if (lazy.animation.important.get(property)) |value| {
                try rules.append(arena, selector_text, value, important_priority);
            }
        }
    }

    if (relevant) {
        const before = self.next_doc_order;
        const selectors = SelectorParser.parseList(arena, selector_text) catch &.{};
        for (selectors) |selector| {
            try self.addTrackedRule(selector, props, important, layer);
        }
        changed = changed or self.next_doc_order != before;
    }
    return changed;
}

// One priority per selector, shared by every group it lands in: doc_order
// indexes rule_layers. The !important declarations become a second rule in
// the tier above every normal one, where an unlayered rule packs rank 0.
fn addTrackedRule(self: *StyleManager, selector: Selector.Selector, props: *const Declarations, important: *const Declarations, layer: u16) !void {
    try self.collectAttributeNames(selector);
    self.siblings.addNext(nextReach(selector));
    try self.collectClassReach(selector, .subtree);
    const matched = unwrapWhere(selector);
    const placement = placeSelector(matched) orelse return;
    const rank_and_order = try self.nextPriority(layer);
    const priority = rank_and_order | (@as(u64, computeSpecificity(selector)) << SPEC_SHIFT);
    const important_priority = IMPORTANT_BIT | (priority & ~RANK_MASK);
    inline for (group_fields) |field| {
        inline for (.{ @field(props, field), @field(important, field) }, .{ priority, important_priority }) |declared, p| {
            if (declaresAny(declared)) {
                try @field(self, field).bucket(self.arena.allocator(), placement, .{
                    .props = .init(declared),
                    .selector = matched,
                    .priority = p,
                });
            }
        }
    }
}

fn collectAttributeNames(self: *StyleManager, selector: Selector.Selector) Allocator.Error!void {
    try self.collectCompoundAttributeNames(selector.first);
    for (selector.segments) |segment| {
        switch (segment.combinator) {
            .subsequent_sibling => self.siblings.later = true,
            // counted by nextReach
            .next_sibling, .descendant, .child => {},
        }
        try self.collectCompoundAttributeNames(segment.compound);
    }
}

fn collectCompoundAttributeNames(self: *StyleManager, compound: Selector.Compound) Allocator.Error!void {
    // By pointer: a short name's str() points into its String, which would be
    // an issue, except these are all on the same self.arena, so we can copy the pointer.
    const allocator = self.arena.allocator();
    for (compound.parts) |*part| {
        const nested: []const Selector.Selector = switch (part.*) {
            .attribute => |*attr| {
                if (attr.name.eql(comptime .wrap("style"))) {
                    self.reads_style_attribute = true;
                }
                try self.attribute_names.put(allocator, attr.name.str(), {});
                continue;
            },
            .pseudo_class => |pseudo| switch (pseudo) {
                .not, .is, .where => |selectors| selectors,
                .has => |selectors| blk: {
                    for (selectors) |argument| {
                        try self.has.add(allocator, argument);
                    }
                    break :blk selectors;
                },
                .nth_child_of => |of| blk: {
                    self.siblings.later = true;
                    break :blk of.selectors;
                },
                .nth_last_child_of => |of| blk: {
                    self.siblings.earlier = true;
                    break :blk of.selectors;
                },
                else => {
                    self.siblings.add(pseudo);
                    if (readsOtherFormElements(pseudo)) {
                        self.reads_form = true;
                        self.reads_default = self.reads_default or pseudo == .default;
                    }
                    if (pseudo == .empty) {
                        self.reads_empty = true;
                    }
                    for (pseudoClassAttributes(pseudo)) |name| {
                        try self.attribute_names.put(allocator, name, {});
                    }
                    continue;
                },
            },
            else => continue,
        };
        for (nested) |selector| {
            try self.collectAttributeNames(selector);
        }
    }
}

/// The attribute names that are read for a pseudo. For example, the :link
/// pseudo class requires that we read the "href" attribute, thus we need to
/// monitor changes to "href".
fn pseudoClassAttributes(pseudo: Selector.PseudoClass) []const []const u8 {
    return switch (pseudo) {
        .link, .any_link => &.{"href"},
        .lang => &.{"lang"},
        .disabled, .enabled => &.{"disabled"},
        .checked => &.{ "checked", "selected" },
        .default => &.{ "checked", "selected", "form" },
        .required, .optional => &.{ "required", "readonly", "disabled" },
        .read_only, .read_write => &.{ "readonly", "disabled", "contenteditable" },
        // Constraint validation (ValidityState); a form or fieldset checks
        // the controls under it, name groups radios. checked, selected and
        // value set a control's state while the user hasn't touched it.
        .valid, .invalid, .in_range, .out_of_range => &.{ "required", "readonly", "disabled", "pattern", "min", "max", "step", "minlength", "maxlength", "multiple", "value", "checked", "selected", "form", "name" },
        // Element state, the tree, or always_read (:target reads id)
        .modal, .popover_open, .indeterminate, .placeholder_shown, .hover, .active, .focus, .focus_within, .focus_visible, .visited, .target, .root, .scope, .empty, .first_child, .last_child, .only_child, .first_of_type, .last_of_type, .only_of_type, .nth_child, .nth_last_child, .nth_of_type, .nth_last_of_type, .defined => &.{},
        // Walked by collectCompoundAttributeNames
        .not, .is, .where, .has, .nth_child_of, .nth_last_child_of => unreachable,
    };
}

/// Attributes the engine reads whatever the rules: class and id selectors,
/// inline style, the UA hidden-element rules (matchesUaDisplayNoneRule),
/// img/iframe sizes (Element.getElementAxis) and SVG's font-size presentation
/// attribute (computedFontSizeAt).
const always_read = std.StaticStringMapWithEql(void, std.static_string_map.eqlAsciiIgnoreCase).initComptime(.{
    .{"class"}, .{"id"},      .{"style"}, .{"hidden"}, .{"type"},
    .{"open"},  .{"popover"}, .{"width"}, .{"height"}, .{"font-size"},
});

/// When an attribute changes, we only want to invalidate the caches if we care
/// about that attribute. Some attributes we care about because a selector is
/// using it (div[role=menu]), which is what the `attribute_names` field is
/// tracking. But we implicitly always care about some attributes, like "hidden"
/// or "open". But how do we make sure that `readsAttribute` is kept in sync?
/// What if someone adds el.isAccessible() which the StyleManager starts to use
/// and which accesses the "axs" attribute? This is what this debug-only code
/// is for. A thread-local variable is set by the StyleManager before it reads
/// anything, and then in Attribute.zig, when an attribute is read, and the
/// thread local is set, we can make sure that the attribute is a known one.
pub const fill_check = struct {
    threadlocal var current: ?*const StyleManager = null;

    pub fn enter(self: *const StyleManager) ?*const StyleManager {
        if (comptime lp.IS_DEBUG == false) {
            return null;
        }
        const previous = current;
        current = self;
        return previous;
    }

    pub fn exit(previous: ?*const StyleManager) void {
        if (comptime lp.IS_DEBUG) {
            current = previous;
        }
    }

    pub fn attributeRead(name: []const u8) void {
        if (comptime lp.IS_DEBUG == false) {
            return;
        }
        const self = current orelse return;
        if (self.readsAttribute(name) == false) {
            std.debug.panic("StyleManager memo read untracked attribute '{s}': add it to always_read or pseudoClassAttributes", .{name});
        }
    }
};

/// Whether writing attribute `name` can change what a memo holds
pub fn readsAttribute(self: *const StyleManager, name: []const u8) bool {
    if (self.dirty) {
        // doesn't matter, we're rebuilding anyways.
        return true;
    }
    return always_read.has(name) or self.attribute_names.contains(name);
}

// Selector attribute names are lowercased, but a foreign element's attribute
// keeps its case (viewBox). Ignoring the case can only cost us perf, not
// correctness.
const AttributeNameContext = struct {
    pub fn hash(_: AttributeNameContext, name: []const u8) u64 {
        var buf: [32]u8 = undefined;
        var hasher: std.hash.Wyhash = .init(0);

        var rest = name;
        while (rest.len > 0) {
            const n = @min(rest.len, buf.len);
            hasher.update(std.ascii.lowerString(&buf, rest[0..n]));
            rest = rest[n..];
        }
        return hasher.final();
    }

    pub fn eql(_: AttributeNameContext, a: []const u8, b: []const u8) bool {
        return std.ascii.eqlIgnoreCase(a, b);
    }
};

/// Which siblings are impacted by a change.
const SiblingReads = struct {
    // A change reaches this many element siblings after it: one for `+` or
    // :first-child, one more for each `+` that follows (see nextReach)
    next: u8 = 0,
    // ... every later one: `~`, :nth-child(), :nth-of-type(), :first-of-type
    later: bool = false,
    // ... the previous element sibling: :last-child
    previous: bool = false,
    // ... every earlier one: :nth-last-child(), :nth-last-of-type(), :last-of-type
    earlier: bool = false,

    // Past this, walking the next siblings one by one costs more than the
    // parent's subtree, which batches.
    const max_next = 4;

    fn addNext(self: *SiblingReads, reach: usize) void {
        if (reach > max_next) {
            self.later = true;
            return;
        }
        self.next = @max(self.next, @as(u8, @intCast(reach)));
    }

    fn add(self: *SiblingReads, pseudo: Selector.PseudoClass) void {
        switch (pseudo) {
            // their next sibling is counted by nextReach
            .last_child, .only_child => self.previous = true,
            .nth_child, .nth_of_type, .first_of_type => self.later = true,
            .nth_last_child, .nth_last_of_type, .last_of_type => self.earlier = true,
            .only_of_type => {
                self.later = true;
                self.earlier = true;
            },
            else => {},
        }
    }
};

/// How many element siblings after a gap (an element inserted or removed) can
/// change what `selector` matches. A compound's match changes at the gap (the
/// moved element), one after it through :first-child, and each `+` reaches one
/// further: `:first-child + b + u` reaches u, 3 after. A descendant or child
/// combinator starts over in another sibling list, but whatever it reaches is
/// under a sibling that's dropped with its subtree. `~` is SiblingReads.later.
fn nextReach(selector: Selector.Selector) usize {
    var reach = compoundNextReach(selector.first);
    var deepest = reach;
    for (selector.segments) |segment| {
        const compound = compoundNextReach(segment.compound);
        reach = switch (segment.combinator) {
            .next_sibling => @max(reach + 1, compound),
            .subsequent_sibling, .descendant, .child => compound,
        };
        deepest = @max(deepest, reach);
    }
    return deepest;
}

fn compoundNextReach(compound: Selector.Compound) usize {
    var reach: usize = 0;
    for (compound.parts) |part| {
        const nested: []const Selector.Selector = switch (part) {
            .pseudo_class => |pseudo| switch (pseudo) {
                .first_child, .only_child => {
                    reach = @max(reach, 1);
                    continue;
                },
                .not, .is, .where, .has => |selectors| selectors,
                .nth_child_of, .nth_last_child_of => |of| of.selectors,
                else => continue,
            },
            else => continue,
        };
        for (nested) |selector| {
            reach = @max(reach, nextReach(selector));
        }
    }
    return reach;
}

/// Pseudo-classes whose match reads other elements of a form or select, e.g the
/// form's default button, the fieldset's first levent, ...
fn readsOtherFormElements(pseudo: Selector.PseudoClass) bool {
    return switch (pseudo) {
        .default, .valid, .invalid, .disabled, .enabled, .read_only, .read_write, .checked => true,
        else => false,
    };
}

/// Elements whose insertion or removal can change a form pseudo-class elsewhere
fn isFormElement(el: *Element) bool {
    return switch (el.getTag()) {
        .form, .input, .button, .select, .textarea, .output, .object, .fieldset, .legend, .option, .optgroup => true,
        .custom => if (el.is(Element.Html.Custom)) |custom| custom.isFormAssociated() else false,
        else => false,
    };
}

/// E:has(S) reads E's subtree, so a change under E can change what it matches.
/// But if the argument is only made of descendants and child combinators, the
/// selector can only change when the change matches S's subject.
const HasKeys = struct {
    // An argument that can change without its subject moving, or with no key.
    any: bool = false,
    tags: std.EnumSet(Tag) = .empty,
    names: std.HashMapUnmanaged([]const u8, void, AttributeNameContext, std.hash_map.default_max_load_percentage) = .empty,

    // How many ancestors of a subject an argument reaches: `:has(> a > img)`
    // (stored as `:scope > a > img`) 2, so its subject moving can only change
    // the match of its 2 nearest ancestors. Unbounded with a descendant
    // combinator.
    depth: usize = 0,
    unbounded: bool = false,

    fn isEmpty(self: *const HasKeys) bool {
        return self.any == false and self.tags.count() == 0 and self.names.count() == 0;
    }

    fn add(self: *HasKeys, allocator: Allocator, argument: Selector.Selector) Allocator.Error!void {
        if (self.any) {
            // no point tracking anything else
            return;
        }

        if (reachesOutside(argument)) {
            self.any = true;
            return;
        }

        for (argument.segments) |segment| {
            if (segment.combinator != .child) {
                self.unbounded = true;
            }
        }
        self.depth = @max(self.depth, argument.segments.len);

        const subject = argument.rightmost();
        for (subject.parts) |*part| {
            switch (part.*) {
                .id, .class, .tag_name => |name| return self.names.put(allocator, name, {}),
                .attribute => |*attr| return self.names.put(allocator, attr.name.str(), {}),
                else => {},
            }
        }
        for (subject.parts) |part| {
            switch (part) {
                .tag => |tag| return self.tags.insert(tag),
                else => {},
            }
        }
        self.any = true;
    }

    fn matches(self: *const HasKeys, el: *Element) bool {
        if (self.tags.contains(el.getTag())) {
            return true;
        }
        if (self.names.count() == 0) {
            return false;
        }
        if (self.names.contains(el.getTagNameLower())) {
            return true;
        }
        if (el.getId()) |id| {
            if (self.names.contains(id)) {
                return true;
            }
        }
        if (el.getClassName()) |class_attr| {
            var it = std.mem.tokenizeAny(u8, class_attr, &std.ascii.whitespace);
            while (it.next()) |class| {
                if (self.names.contains(class)) {
                    return true;
                }
            }
        }
        for (el._attributes.entries()) |*entry| {
            if (self.names.contains(entry.name())) {
                return true;
            }
        }
        return false;
    }

    // Whether a :has() argument's match can change without its subject moving.
    fn reachesOutside(selector: Selector.Selector) bool {
        if (compoundReachesOutside(selector.first)) {
            return true;
        }
        for (selector.segments) |segment| {
            switch (segment.combinator) {
                .next_sibling, .subsequent_sibling => return true,
                .descendant, .child => {},
            }
            if (compoundReachesOutside(segment.compound)) {
                return true;
            }
        }
        return false;
    }

    fn compoundReachesOutside(compound: Selector.Compound) bool {
        for (compound.parts) |part| {
            const pseudo = switch (part) {
                .pseudo_class => |pseudo| pseudo,
                else => continue,
            };
            switch (pseudo) {
                .not, .is, .where => |selectors| for (selectors) |selector| {
                    if (reachesOutside(selector)) {
                        return true;
                    }
                },
                .empty, .first_child, .last_child, .only_child, .first_of_type, .last_of_type, .only_of_type, .nth_child, .nth_last_child, .nth_child_of, .nth_last_child_of, .nth_of_type, .nth_last_of_type, .has, .focus_within => return true,
                else => if (readsOtherFormElements(pseudo)) {
                    return true;
                },
            }
        }
        return false;
    }
};

/// Something changed in the detached tree. Selectors never cross this, so
/// all this can ever invalidate are caches within that tree.
pub fn detachedChanged(self: *StyleManager, node: *Node) bool {
    if (self.dirty) {
        return true;
    }
    var memos: Memos = .empty;
    var budget: usize = 0;
    inline for (group_fields) |field| {
        const group = &@field(self, field);
        if (group.detached and group.fresh(self.frame)) {
            memos.insert(@field(Memo, field));
            budget += group.memo.count();
        }
    }
    // A detached element's box sizes to its tree: the layout memo too
    if (self.layout_memo.detached and self.layoutMemoLive()) {
        memos.insert(.layout);
        budget += self.layout_memo.map.count();
    }
    if (budget == 0) {
        return true;
    }
    return self.dropSubtree(node.getRootNode(.{ .composed = true }), memos, &budget);
}

/// When the class on an element changes.  For example .hidden{display: none}
const ClassReach = enum(u8) {
    // Order matters: narrowest to widest.
    subtree, // the element and whatever inherits them
    parent_subtree, // sibling combinator, all later siblings
    full, // something in a :has(...) argument. ARG!

    fn widest(a: ClassReach, b: ClassReach) ClassReach {
        return @fromBackingInt(@intCast(@max(@backingInt(a), @backingInt(b))));
    }
};

// `subject` is the reach of the selector's subject compound: .subtree for a
// rule's selector, the enclosing compound's for an :is() argument.
fn collectClassReach(self: *StyleManager, selector: Selector.Selector, subject: ClassReach) Allocator.Error!void {
    const segments = selector.segments;
    for (0..segments.len + 1) |i| {
        const compound = if (i == 0) selector.first else segments[i - 1].compound;
        // The combinator to the compound's right relates it to the subject.
        // In a :has() argument (.full) every compound reaches everything.
        const reach: ClassReach = if (i == segments.len or subject == .full) subject else switch (segments[i].combinator) {
            .descendant, .child => .subtree,
            .next_sibling, .subsequent_sibling => .parent_subtree,
        };
        try self.collectCompoundClassReach(compound, reach);
    }
}

fn collectCompoundClassReach(self: *StyleManager, compound: Selector.Compound, reach: ClassReach) Allocator.Error!void {
    for (compound.parts) |part| {
        switch (part) {
            .class => |class| {
                const gop = try self.class_reach.getOrPut(self.arena.allocator(), class);
                gop.value_ptr.* = if (gop.found_existing) gop.value_ptr.widest(reach) else reach;
            },
            .attribute => |attr| if (attr.name.eql(comptime .wrap("class"))) {
                self.class_attribute_reach = if (self.class_attribute_reach) |current| current.widest(reach) else reach;
            },
            .pseudo_class => |pseudo| switch (pseudo) {
                .not, .is, .where => |selectors| for (selectors) |selector| {
                    try self.collectClassReach(selector, reach);
                },
                // A sibling's class changes which index the element has
                .nth_child_of, .nth_last_child_of => |of| for (of.selectors) |selector| {
                    try self.collectClassReach(selector, reach.widest(.parent_subtree));
                },
                .has => |selectors| for (selectors) |selector| {
                    try self.collectClassReach(selector, .full);
                },
                else => {},
            },
            else => {},
        }
    }
}

/// `el`'s class attribute went from `old` to `new` (null: absent), `el`
/// connected. Drops the memo entries the classes added or removed can reach.
/// Returns false when that's everything: the caller reports a full style change.
pub fn classChanged(self: *StyleManager, el: *Element, old: ?[]const u8, new: ?[]const u8) bool {
    self.assertOwns(el);
    if (self.dirty) {
        // the rebuild resets every memo
        return true;
    }
    // [class*=x] reads the string, [class] its presence: any call is a change
    // (change.attributeSet skips same-value writes)
    var reach: ?ClassReach = self.class_attribute_reach;
    inline for (.{ .{ old, new }, .{ new, old } }) |pair| {
        var it = std.mem.tokenizeAny(u8, pair[0] orelse "", &std.ascii.whitespace);
        outer: while (it.next()) |class| {
            var others = std.mem.tokenizeAny(u8, pair[1] orelse "", &std.ascii.whitespace);
            while (others.next()) |other| {
                if (std.mem.eql(u8, class, other)) {
                    continue :outer;
                }
            }
            if (self.class_reach.get(class)) |r| {
                reach = if (reach) |current| current.widest(r) else r;
            }
        }
    }
    const scope = reach orelse return true;
    if (scope == .full) {
        return false;
    }

    // Boxes can move
    self.layout_bumps += 1;
    var memos: Memos = .empty;
    var budget: usize = 0;
    inline for (group_fields) |field| {
        const group = &@field(self, field);
        if (group.memo.count() != 0 and group.fresh(self.frame)) {
            memos.insert(@field(Memo, field));
            budget += group.memo.count();
        }
    }
    if (budget == 0) {
        return true;
    }
    const node = el.asNode();
    const root = if (scope == .parent_subtree) node._parent orelse node else node;
    if (self.droppedCovers(root)) {
        // nothing under it was read since it was dropped
        return true;
    }
    if (self.dropSubtree(root, memos, &budget) == false) {
        return false;
    }
    self.recordDropped(root);
    return true;
}

pub const TreeChange = enum { inserted, removed };

/// `child` was inserted/removed from `parent`. Drop the memo entries that can
/// change. Returns false if treeChanged wasn't able to prune only the tree, in
/// which case the caller should report a full style change.
pub fn treeChanged(self: *StyleManager, parent: *Node, child: *Node, previous: ?*Node, next: ?*Node, op: TreeChange) bool {
    // Boxes move whatever the cascade does
    self.layout_bumps += 1;
    if (self.dirty) {
        // doesn't matter, a rebuild is needed anyways.
        return true;
    }

    if (parent._type == .document) {
        // everything is under the root, invaliding its tree is the same as a
        // full invalidation, so there's no optimization to be had here.
        return false;
    }

    // A memo the next read clears anyway holds nothing to drop
    var memos: Memos = .empty;
    var budget: usize = 0;
    inline for (group_fields) |field| {
        const group = &@field(self, field);
        if (group.memo.count() != 0 and group.fresh(self.frame)) {
            memos.insert(@field(Memo, field));
            budget += group.memo.count();
        }
    }
    if (budget == 0) {
        return true;
    }

    if (self.holdsFocus(child)) {
        // :focus-within on the ancestors
        return false;
    }
    // Usually parent's subtree, wider when the moved subtree reaches a match
    // above it: a :has() anchor, a form's validity
    var root = parent;
    if (self.reads_form or self.has.isEmpty() == false) {
        if (self.has.any) {
            return false;
        }
        const reach = self.movedReach(child) orelse return false;
        root = movedRoot(parent, reach, self.has.depth);
    }

    // Past the budget, dropping costs more than recomputing what's cached.
    if (self.droppedCovers(root)) {
        // Changes batched between two reads: parent's subtree was dropped and
        // nothing filled since, but what this inserts can come with entries
        // (read while detached).
        if (op == .inserted and self.dropSubtree(child, memos, &budget) == false) {
            return false;
        }
    } else if (root != parent or (child._type == .element and self.readsAllSiblings(previous, next))) {
        // Widened (a :has() anchor, a form), or a match reads every sibling
        // and there are some: everything under root, which batching can skip
        // next time
        if (op == .removed and self.dropSubtree(child, memos, &budget) == false) {
            return false;
        }
        if (self.dropSubtree(root, memos, &budget) == false) {
            return false;
        }
        self.recordDropped(root);
    } else {
        // What moved, and the siblings whose matches read across the gap it
        // opened or closed. parent's own match doesn't change but for :empty.
        if (self.dropSubtree(child, memos, &budget) == false) {
            return false;
        }
        if (child._type == .element and self.dropSiblings(previous, next, memos, &budget) == false) {
            return false;
        }
    }
    if (self.reads_empty and emptinessFlips(parent, child)) {
        // parent's :empty, and through `:empty + x` and `:empty ~ x` its later
        // siblings
        if (self.dropSubtree(parent, memos, &budget) == false) {
            return false;
        }
        var sibling = parent.nextSibling();
        while (sibling) |s| : (sibling = s.nextSibling()) {
            if (self.dropSubtree(s, memos, &budget) == false) {
                return false;
            }
        }
    }
    return true;
}

// Whether a match reads every sibling on a side of the gap that has some
// (`~`, :nth-child()...). Not for an append when only earlier siblings are
// read: there's nothing after it.
fn readsAllSiblings(self: *const StyleManager, previous: ?*Node, next: ?*Node) bool {
    if (self.siblings.later and nextElement(next) != null) {
        return true;
    }
    if (self.siblings.earlier and previousElement(previous) != null) {
        return true;
    }
    return false;
}

fn nextElement(from: ?*Node) ?*Node {
    var sibling = from;
    while (sibling) |s| : (sibling = s.nextSibling()) {
        if (s._type == .element) {
            return s;
        }
    }
    return null;
}

fn previousElement(from: ?*Node) ?*Node {
    var sibling = from;
    while (sibling) |s| : (sibling = s.previousSibling()) {
        if (s._type == .element) {
            return s;
        }
    }
    return null;
}

// The siblings of a gap (an element inserted or removed between `previous`
// and `next`) whose match can change (see SiblingReads), with their subtrees.
// Only the nearest ones: readsAllSiblings sent the rest to the parent's
// subtree.
fn dropSiblings(self: *StyleManager, previous: ?*Node, next: ?*Node, memos: Memos, budget: *usize) bool {
    var sibling = next;
    for (0..self.siblings.next) |_| {
        const s = nextElement(sibling) orelse break;
        if (self.dropSubtree(s, memos, budget) == false) {
            return false;
        }
        sibling = s.nextSibling();
    }
    if (self.siblings.previous) {
        if (previousElement(previous)) |s| {
            if (self.dropSubtree(s, memos, budget) == false) {
                return false;
            }
        }
    }
    return true;
}

fn memoFills(self: *const StyleManager) usize {
    var fills: usize = 0;
    inline for (group_fields) |field| {
        fills += @field(self, field).fills;
    }
    return fills;
}

// Whether `parent` is under a root dropped since the memos last filled. Then
// nothing under it has an entry: whatever entered it since came through an
// insertion, which dropped what it brought.
fn droppedCovers(self: *StyleManager, parent: *Node) bool {
    if (self.dropped_fills != self.memoFills()) {
        self.dropped_len = 0;
        return false;
    }
    for (self.dropped[0..self.dropped_len]) |root| {
        if (root.contains(parent)) {
            return true;
        }
    }
    return false;
}

fn recordDropped(self: *StyleManager, root: *Node) void {
    const fills = self.memoFills();
    if (self.dropped_fills != fills) {
        self.dropped_len = 0;
        self.dropped_fills = fills;
    }
    if (self.dropped_len == self.dropped.len) {
        std.mem.copyForwards(*Node, self.dropped[0 .. self.dropped.len - 1], self.dropped[1..]);
        self.dropped_len -= 1;
    }
    self.dropped[self.dropped_len] = root;
    self.dropped_len += 1;
}

// Focus inside a shadow tree counts: :focus-within crosses into the host
fn holdsFocus(self: *const StyleManager, child: *Node) bool {
    const active = self.frame.document._active_element orelse return false;
    return child.isHostIncludingInclusiveAncestorOf(active.asNode());
}

// Whether `child`'s subtree holds an element whose insertion or removal
// changes a match outside it: a form element or a :has() subject.
const MovedReach = struct {
    // A form control: the forms, fieldsets and selects around read it
    form: bool = false,
    // A :has() subject: the anchors above, up to HasKeys.depth
    has: bool = false,
};

// What outside `child`'s subtree its insertion or removal can change. Null
// when that can be anywhere: a :has() subject any ancestor can anchor on, or a
// control whose form owner, radio group or default button can be elsewhere.
fn movedReach(self: *const StyleManager, child: *Node) ?MovedReach {
    var reach: MovedReach = .{};
    var tw = TreeWalker.Full.Elements.init(child, .{});
    while (tw.next()) |el| {
        if (self.reads_form and isFormElement(el)) {
            if (el.hasAttributeSafe(comptime .wrap("form"))) {
                // owned by a form anywhere
                return null;
            }
            if (el.is(Input)) |input| {
                if (input._input_type == .radio) {
                    // a group's validity reads every radio in the form owner
                    return null;
                }
            }
            if (self.reads_default and Element.Html.Form.isSubmitButton(el)) {
                return null;
            }
            reach.form = true;
        }
        if (self.has.matches(el)) {
            if (self.has.unbounded) {
                return null;
            }
            reach.has = true;
        }
    }
    return reach;
}

// The subtree to drop for `reach` around `parent`: the parent of the highest
// element whose match can change, as it can reach its later siblings.
fn movedRoot(parent: *Node, reach: MovedReach, has_depth: usize) *Node {
    var highest: ?*Node = null;
    if (reach.has) {
        // The moved subject's anchors: parent, and so on up
        var anchor = parent;
        for (1..has_depth) |_| {
            anchor = anchor._parent orelse break;
        }
        highest = anchor;
    }
    if (reach.form) {
        var node: ?*Node = parent;
        while (node) |n| : (node = n._parent) {
            const el = n.is(Element) orelse continue;
            switch (el.getTag()) {
                .form, .fieldset, .select => if (highest == null or n.contains(highest.?)) {
                    highest = n;
                },
                else => {},
            }
        }
    }
    const top = highest orelse return parent;
    return top._parent orelse top;
}

fn emptinessFlips(parent: *Node, child: *Node) bool {
    if (countsForEmpty(child) == false) {
        return false;
    }
    var it = parent.childrenIterator();
    while (it.next()) |other| {
        if (other != child and countsForEmpty(other)) {
            return false;
        }
    }
    return true;
}

// What makes an element not :empty (see selector/List.zig)
fn countsForEmpty(node: *Node) bool {
    const cdata = node.is(Node.CData) orelse return true;
    return switch (cdata._type) {
        .comment, .processing_instruction => false,
        else => cdata.getLength() > 0,
    };
}

/// Drops `root`'s subtree from `memos` (.layout: the layout memo), and what
/// inherits from it outside the DOM subtree: a host's shadow tree, the nodes
/// assigned to a slot. False once it visits more elements than `budget`.
fn dropSubtree(self: *StyleManager, root: *Node, memos: Memos, budget: *usize) bool {
    var tw = TreeWalker.Full.Elements.init(root, .{});
    while (tw.next()) |el| {
        if (budget.* == 0) {
            return false;
        }
        budget.* -= 1;
        if (comptime lp.IS_TEST) {
            self.walked += 1;
        }

        var it = memos.iterator();
        while (it.next()) |memo| {
            switch (memo) {
                .layout, .heights => _ = self.layout_memo.map.remove(el),
                inline else => |group| _ = @field(self, @tagName(group)).memo.remove(el),
            }
        }
        if (el.hostedShadowRoot(self.frame)) |shadow| {
            if (self.dropSubtree(shadow.asNode(), memos, budget) == false) {
                return false;
            }
        }
        if (el.is(Element.Html.Slot)) |slot| {
            for (slot._assigned.items) |assigned| {
                if (self.dropSubtree(assigned, memos, budget) == false) {
                    return false;
                }
            }
        }
    }
    return true;
}

/// The memos an inline write can invalidate on its own, one per Group. Plus
/// the layout memos comes from several groups.
const Memo = enum { visibility, geometry, touch_action, text, flow, layout, heights };
const Memos = std.EnumSet(Memo);

comptime {
    for (group_fields) |field| {
        _ = @field(Memo, field);
    }
}

/// Invalidates the memos an inline style write of `name` on `el` can change.
/// This returns false when an individual memo cannot be cleared. The caller
/// must report a full style change.
pub fn inlineStyleWritten(self: *StyleManager, el: *Element, id: properties.Id) bool {
    self.assertOwns(el);
    if (el.asNode().isConnected() == false) {
        return self.detachedChanged(el.asNode());
    }
    if (self.dirty or self.reads_style_attribute) {
        return false;
    }
    self.invalidateInline(el, propertyReach(id));
    return true;
}

/// `el`'s style attribute went from `old` to `new` (null: absent), `el`
/// connected: setAttribute('style'), cssText. Like an inline write (see
/// inlineStyleWritten) of what changed. Returns false when that can't be
/// scoped: the caller reports a full style change.
pub fn styleAttributeChanged(self: *StyleManager, el: *Element, old: ?[]const u8, new: ?[]const u8) bool {
    self.assertOwns(el);
    if (self.dirty or self.reads_style_attribute) {
        return false;
    }
    var reach: Memos = .empty;
    var it = declaredReach(old).unionWith(declaredReach(new)).iterator();
    while (it.next()) |memo| {
        if (sameDeclarations(old, new, memo) == false) {
            reach.insert(memo);
        }
    }
    self.invalidateInline(el, reach);
    return true;
}

// The memos a style attribute's declarations reach
fn declaredReach(text: ?[]const u8) Memos {
    var reach: Memos = .empty;
    var it = CssParser.parseDeclarationsList(text orelse "");
    while (it.next()) |declaration| {
        const id = knownId(declaration.name) orelse continue;
        reach = reach.unionWith(propertyReach(id));
    }
    return reach;
}

// Whether `old` and `new` declare the same for `memo`, in the same order: a
// shorthand and its longhands fold by position (the style object expands
// `margin` in place), so `margin: 0; margin-left: 5px` and its reverse differ.
fn sameDeclarations(old: ?[]const u8, new: ?[]const u8, memo: Memo) bool {
    var old_it = CssParser.parseDeclarationsList(old orelse "");
    var new_it = CssParser.parseDeclarationsList(new orelse "");
    while (true) {
        const a = nextReaching(&old_it, memo);
        const b = nextReaching(&new_it, memo);
        const x = a orelse return b == null;
        const y = b orelse return false;
        // the parser trims values
        if (x.id != y.id or x.important != y.important or std.mem.eql(u8, x.value, y.value) == false) {
            return false;
        }
    }
}

const Reaching = struct { id: properties.Id, value: []const u8, important: bool };

fn nextReaching(it: *CssParser.DeclarationsIterator, memo: Memo) ?Reaching {
    while (it.next()) |declaration| {
        const id = knownId(declaration.name) orelse continue;
        if (propertyReach(id).contains(memo)) {
            return .{ .id = id, .value = declaration.value, .important = declaration.important };
        }
    }
    return null;
}

fn invalidateInline(self: *StyleManager, el: *Element, reach: Memos) void {
    var it = reach.iterator();
    while (it.next()) |memo| {
        switch (memo) {
            .layout => self.layout_bumps += 1,
            .heights => self.heightWritten(el),
            inline else => |m| {
                const group = &@field(self, @tagName(m));
                // A stale memo: the next read clears it
                if (group.fresh(self.frame)) switch (m) {
                    // Entries hold the element's own values. el1.style.width =
                    // '100px' might change the bounding rect of its parent or
                    // children, but not their styles.
                    .geometry, .text => _ = group.memo.remove(el),
                    // Entries hold resolved values: el's reach its descendants
                    .visibility, .touch_action, .flow => self.dropInherited(&group.memo, el.asNode()),
                    .layout, .heights => unreachable,
                };
            },
        }
    }
}

/// Drops `root`'s entry and those of everything that inherits from it.
fn dropInherited(self: *StyleManager, memo: anytype, root: *Node) void {
    var tw = TreeWalker.Full.init(root, .{});
    while (tw.next()) |node| {
        const el = node.is(Element) orelse continue;
        if (comptime lp.IS_TEST) {
            self.walked += 1;
        }
        if (memo.remove(el) == false) {
            // inheritedProps stores an element with its whole ancestor chain,
            // so if there's nothing removed here, none of the descendants
            // can be cached either, stop here.
            tw.skipChildren();
            continue;
        }
        if (el.hostedShadowRoot(self.frame)) |shadow| {
            self.dropInherited(memo, shadow.asNode());
        }
        if (el.is(Element.Html.Slot)) |slot| {
            for (slot._assigned.items) |assigned| {
                // also a DOM child of the host: whichever visit comes first
                // finds it cached
                self.dropInherited(memo, assigned);
            }
        }
    }
}

// A known property's id, by a name as written (any case)
fn knownId(name: []const u8) ?properties.Id {
    var buf: [64]u8 = undefined;
    if (name.len > buf.len) {
        return null;
    }
    return properties.idOf(std.ascii.lowerString(&buf, name));
}

/// The version the layout memos are valid for.
pub fn layoutVersion(self: *const StyleManager) usize {
    return self.frame.page.style_version + self.layout_bumps;
}

/// The version Document.extent is valid for: the layout's, plus height writes
/// that changed the root's content height.
pub fn extentVersion(self: *const StyleManager) usize {
    return self.layoutVersion() + self.extent_bumps;
}

// Part of the optimization: invalidate only the layout a height change can
// move. Take this tree:
//
//  A
//   B
//    C
//     D
//     E
//    F
//     G
//    H
//   I
//
// If F's height changes, nothing before or inside it moves: not D or E in C,
// not G in F, not C in B, not B in A. Only the siblings after F (H) move, so
// their offsets get invalidated.
//
// If B's height is auto, it grows with F, so B's height goes too, and the
// siblings after B (I) move. And so on up, until a parent with a declared
// height (it doesn't grow) or the root (the document's height changes).
//
// Each entry keeps `placed`: how many of its first children have a correct
// offset. Each child keeps its `position` among them. Here B.placed becomes
// F.position + 1 = 2 (C and F are still correct, H isn't), and if B is auto,
// A.placed becomes B.position + 1 = 1 (B is correct, I isn't). The next read
// of H sees its position isn't under B.placed and re-stacks B's children.
fn heightWritten(self: *StyleManager, el: *Element) void {
    const memo = &self.layout_memo;
    if (memo.version != self.layoutVersion()) {
        // stale: the next read resets it
        return;
    }
    if (memo.map.getPtr(el)) |entry| {
        entry.drop(.box_height);
    }
    // Takes no room in its parent's flow (see layout.Flow.advance)
    if (self.hasDisplayNone(el) or self.isOutOfFlow(el)) {
        return;
    }

    var child = el;
    while (child.asNode().flatTreeParentElement(self.frame)) |parent| : (child = parent) {
        // Not placed: nothing after it is either
        const index: ?u32 = if (memo.map.getPtr(child)) |c| (if (c.get(.offset) != null) c.position else null) else null;
        const entry = self.layoutEntry(parent) orelse {
            self.layout_bumps += 1;
            return;
        };
        if (index) |i| {
            entry.placed = @min(entry.placed, i + 1);
        }
        entry.drop(.content_height);
        // html and body take the document's height, so they never stop it
        if (parent.isRootContainer() == false and parent.getElementAxis(self.frame, .height).explicit) {
            return;
        }
        entry.drop(.box_height);
    }
    self.extent_bumps += 1;
}

/// Each known property's memos: the ones that read it. A property not listed
/// reaches nothing. transform/z-index/custom properties...no memo reads them.
/// Nothing substitutes var() (yet).
const property_reach = blk: {
    // layout reads everything, except what we explicitly ignore (safer option)
    // A vertical inset only moves a positioned box, and that's applied on
    // every read (layout.boxTop), never cached.
    const layout_ignores = [_]properties.Id{ .visibility, .opacity, .@"pointer-events", .@"touch-action", .@"overscroll-behavior-x", .@"overscroll-behavior-y", .top, .bottom, .@"inset-block", .@"inset-block-start", .@"inset-block-end" };

    // font-size isn't cascaded by any group, but text wraps at it
    const names = Declarations.names ++ [_][]const u8{ "font", "font-size" };
    @setEvalBranchQuota(names.len * names.len * 100);

    var result: [properties.known_count]Memos = @splat(.empty);
    for (names) |name| {
        var memos: Memos = .empty;
        for (group_fields) |field| {
            const Spec = @FieldType(Declarations, field);
            for (Spec.names) |declared| {
                if (std.mem.eql(u8, name, declared)) {
                    memos.insert(@field(Memo, field));
                }
            }
        }
        const id = @field(properties.Id, name);
        if (std.mem.findScalar(properties.Id, &layout_ignores, id) == null) {
            // a height reaches only the vertical layout, not the widths
            memos.insert(if (id == .height) .heights else .layout);
        }
        result[@backingInt(id)] = memos;
    }
    // An axis shorthand reaches what its longhands do
    for (properties.axis_shorthands) |shorthand| {
        result[@backingInt(shorthand.name)] = result[@backingInt(shorthand.x)].unionWith(result[@backingInt(shorthand.y)]);
    }
    break :blk result;
};

fn propertyReach(id: properties.Id) Memos {
    const index = @backingInt(id);
    if (index >= property_reach.len) {
        // a custom property
        return .empty;
    }
    return property_reach[index];
}

/// Rank and document-order bits of the next rule. A rule outside any layer
/// carries UNLAYERED_RANK from the start; finalizeLayerRanks stamps the
/// layered ones once every layer is known.
fn nextPriority(self: *StyleManager, layer: u16) !u64 {
    try self.rule_layers.append(self.arena.allocator(), layer);
    const rank: u64 = if (layer == NO_LAYER) UNLAYERED_RANK else 0;
    const priority = (rank << RANK_SHIFT) | @min(self.next_doc_order, MAX_DOC_ORDER);
    self.next_doc_order += 1;
    return priority;
}

/// Whether every selector of a list ends in a pseudo-element. A scan rather
/// than a parse: anything it can't tell reads as false, and parsedRules skips
/// those selectors anyway.
fn selectsOnlyPseudoElements(text: []const u8) bool {
    var depth: usize = 0;
    var pseudo = false;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        switch (text[i]) {
            '\\' => i += 1,
            '"', '\'' => |quote| {
                i += 1;
                while (i < text.len and text[i] != quote) : (i += 1) {
                    if (text[i] == '\\') {
                        i += 1;
                    }
                }
            },
            '(', '[' => depth += 1,
            ')', ']' => depth -|= 1,
            ',' => if (depth == 0) {
                if (pseudo == false) {
                    return false;
                }
                pseudo = false;
            },
            ':' => if (depth == 0 and startsPseudoElement(text[i + 1 ..])) {
                pseudo = true;
            },
            else => {},
        }
    }
    return pseudo;
}

// `::name`, or one of the pseudo-elements CSS2 wrote with a single colon.
fn startsPseudoElement(after_colon: []const u8) bool {
    if (after_colon.len > 0 and after_colon[0] == ':') {
        return true;
    }
    for ([_][]const u8{ "before", "after", "first-line", "first-letter" }) |name| {
        if (std.ascii.startsWithIgnoreCase(after_colon, name) == false) {
            continue;
        }
        const rest = after_colon[name.len..];
        if (rest.len == 0) {
            return true;
        }
        switch (rest[0]) {
            'a'...'z', 'A'...'Z', '0'...'9', '-', '_', '\\', 0x80...0xFF => {},
            else => return true,
        }
    }
    return false;
}

pub fn sheetModified(self: *StyleManager) void {
    self.dirty = true;
    self.keyframes_mentioned = null;
    Frame.change.rulesChanged(self.frame);
    Frame.css_animations.documentChanged(self.frame);
}

/// Rebuilds the rule list from all document stylesheets.
/// Called lazily when dirty flag is set and rules are needed.
fn rebuildIfDirty(self: *StyleManager) !void {
    if (!self.dirty) {
        return;
    }

    // There are some allocations that only need to live for the duration of
    // this rebuild. Having two arena (build_arena and self.arena) isn't ideal
    // as it's easy to use the wrong one.
    const build_arena = try self.frame.getArena(.medium, "StyleManager.rebuild");
    defer {
        self.layers = .empty;
        self.layer_ids = .empty;
        self.next_anon_layer = 0;
        build_arena.release();
    }

    self.dirty = false;
    errdefer self.dirty = true;
    self.reads_style_attribute = false;
    self.reads_form = false;
    self.reads_default = false;
    self.siblings = .{};
    self.reads_empty = false;
    self.class_reach = .empty;
    self.class_attribute_reach = null;
    self.has = .{};
    self.dropped_len = 0;
    var caps: [group_fields.len]Capacities = undefined;
    inline for (group_fields, &caps) |field, *c| {
        c.* = @field(self, field).capacities();
    }
    const lazy_rules_count = self.lazy_rules.count();
    const attribute_names_count = self.attribute_names.count();

    self.arena.resetRetain();
    self.layout_memo = .{};

    self.next_doc_order = 1;
    self.rule_layers = .empty;
    self.last_rule_sheet = null;

    const arena = self.arena.allocator();

    inline for (group_fields, caps) |field, c| {
        try @field(self, field).reset(arena, c);
    }

    self.lazy_rules = .empty;
    try self.lazy_rules.ensureTotalCapacity(arena, lazy_rules_count);
    self.animation_rules = .initFill(.{});
    self.keyframes = .empty;
    self.attribute_names = .empty;
    try self.attribute_names.ensureTotalCapacity(arena, attribute_names_count);

    const sheets = self.frame.document._style_sheets orelse return;
    for (sheets._sheets.items) |sheet| {
        if (sheet._disabled) {
            continue;
        }
        const before = self.next_doc_order;
        self.parseSheet(build_arena.allocator(), sheet) catch |err| {
            log.err(.browser, "StyleManager parseSheet", .{ .err = err });
            return err;
        };
        if (self.next_doc_order != before) {
            self.last_rule_sheet = sheet;
        }
    }

    try self.finalizeLayerRanks(build_arena.allocator());
}

pub fn isHidden(self: *StyleManager, el: *Element, options: CheckVisibilityOptions) bool {
    self.assertOwns(el);
    self.rebuildIfDirty() catch return false;
    return self.visibilityProps(el).isHidden(options);
}

pub const Rendering = enum { visible, invisible, none };

/// `.none` hides `el` and its subtree (display:none, here or above).
/// `.invisible` hides `el` alone: visibility:hidden inherits, but a
/// descendant can set it back to visible.
pub fn rendering(self: *StyleManager, el: *Element) Rendering {
    self.assertOwns(el);
    self.rebuildIfDirty() catch return .visible;
    const props = self.visibilityProps(el);
    if (props.isHidden(.{})) return .none;
    return if (props.visibility_hidden) .invisible else .visible;
}

/// The element's own display:none. Use `isHidden` to see if it's hidden by an ancestor
/// Honors the UA stylesheet rules per HTML Rendering §15.3.1 "Hidden elements".
pub fn hasDisplayNone(self: *StyleManager, el: *Element) bool {
    return self.display(el) == .none;
}

/// `display: contents`. On the root element it computes to block instead.
pub fn hasDisplayContents(self: *StyleManager, el: *Element) bool {
    self.assertOwns(el);
    self.rebuildIfDirty() catch return false;
    return self.generatesBox(el) == false;
}

/// Own property, not inherited; honors the UA hidden-element rules.
pub fn display(self: *StyleManager, el: *Element) Display {
    self.assertOwns(el);
    self.rebuildIfDirty() catch return .other;
    return self.visibilityProps(el).display;
}

/// True when `el` generates an inline-level box: a plain `inline` box or an
/// atomic inline (`inline-block`, `inline-flex`, ...). Block containers,
/// tables and `display: contents` are false.
pub fn isInlineLevel(self: *StyleManager, el: *Element) bool {
    self.assertOwns(el);
    self.rebuildIfDirty() catch return false;
    return switch (self.visibilityProps(el).box) {
        .inline_level, .atomic_inline => true,
        else => false,
    };
}

/// Computed display:none coming only from inline style or an author stylesheet
/// rule — the UA stylesheet's hidden elements (<head>, <script>, [hidden], …)
/// are NOT counted, so document scaffolding is preserved. Used by the HTML
/// dump's "invisible" strip mode.
pub fn hasAuthorDisplayNone(self: *StyleManager, el: *Element) bool {
    self.assertOwns(el);
    self.rebuildIfDirty() catch return false;
    const p = self.visibilityProps(el);
    return p.author_display and p.display == .none;
}

/// Computed visibility:hidden, which inherits from the ancestors. Ignores
/// display:none: an ancestor with display:none means the element isn't
/// rendered, but its computed `visibility` still reflects inherited visibility.
pub fn hasVisibilityHiddenInherited(self: *StyleManager, el: *Element) bool {
    self.assertOwns(el);
    self.rebuildIfDirty() catch return false;
    return self.visibilityProps(el).visibility_hidden;
}

pub fn hasPointerEventsNone(self: *StyleManager, el: *Element) bool {
    self.assertOwns(el);
    self.rebuildIfDirty() catch return false;
    return self.visibilityProps(el).pointer_events_none;
}

/// Blink's VisibleToHitTestRequest, plus display:contents, which generates no
/// box to hit. Ignores display:none, which callers handle for the whole subtree.
pub fn isHitTestable(self: *StyleManager, el: *Element) bool {
    self.assertOwns(el);
    self.rebuildIfDirty() catch return true;
    const p = self.visibilityProps(el);
    return !p.visibility_hidden and !p.pointer_events_none and self.generatesBox(el);
}

/// Computed text-transform, which inherits: the nearest of `el` and its
/// ancestors with its own value, else none.
pub fn textTransform(self: *StyleManager, el: *Element) TextTransform {
    self.assertOwns(el);
    var current: ?*Element = el;
    while (current) |elem| : (current = elem.parentElement()) {
        const own = self.ownTextTransform(elem);
        if (own != .inherit) {
            return own;
        }
    }
    return .none;
}

/// `el`'s own cascaded text-transform; `.inherit` when it takes its parent's.
/// For tree walks that already know the parent's value.
pub fn ownTextTransform(self: *StyleManager, el: *Element) TextTransform {
    self.rebuildIfDirty() catch return .inherit;
    // Most pages declare no text-transform: skip the cascade and the memo.
    if (!self.text.hasRules() and !el._flags.has_inline_style) {
        return .inherit;
    }
    return self.text.ownProps(self.arena.allocator(), el, self.frame).text_transform;
}

/// The two parts of computed white-space: white-space-collapse and
/// text-wrap-mode.
pub fn whiteSpace(self: *StyleManager, el: *Element) text_measure.WhiteSpace {
    self.assertOwns(el);
    self.rebuildIfDirty() catch return .{};

    var wrap: WrapMode = .inherit;
    var collapse: SpaceCollapse = .inherit;

    var current: ?*Element = el;
    while (current) |elem| : (current = elem.asNode().flatTreeParentElement(self.frame)) {
        const own = self.ownWhiteSpace(elem);
        if (collapse == .inherit) {
            collapse = own.collapse;
        }
        if (wrap == .inherit) {
            wrap = own.wrap;
        }
        if (collapse != .inherit and wrap != .inherit) {
            break;
        }
    }
    return .{
        .collapse = !collapse.keepsSpaces(),
        .newlines = switch (collapse) {
            .preserve, .preserve_breaks, .break_spaces => true,
            .inherit, .collapse, .preserve_spaces => false,
        },
        .wrap = wrap != .nowrap,
    };
}

/// For tree walks that already know the parent's value, this returns null
/// when it takes its parent value.
pub fn ownKeepsSpaces(self: *StyleManager, el: *Element) ?bool {
    self.rebuildIfDirty() catch return null;
    const collapse = self.ownWhiteSpace(el).collapse;
    if (collapse == .inherit) {
        return null;
    }
    return collapse.keepsSpaces();
}

fn ownWhiteSpace(self: *StyleManager, el: *Element) WhiteSpace {
    if (!self.text.hasRules() and !el._flags.has_inline_style) {
        // Most pages declare no white-space: skip the cascade and the memo.
        return WhiteSpace.uaDefault(el.getTag()) orelse .{};
    }
    const p = self.text.ownProps(self.arena.allocator(), el, self.frame);
    return .{ .collapse = p.white_space_collapse, .wrap = p.text_wrap_mode };
}

/// The axes along which `el` is a scroll container: its own computed overflow
/// on that axis is auto, scroll or overlay. No ancestor walk.
pub fn overflowAxes(self: *StyleManager, el: *Element) Element.ScrollAxes {
    self.rebuildIfDirty() catch return .{};
    const p = self.geometryProps(el);
    return .{ .x = p.overflow_x_scrolls, .y = p.overflow_y_scrolls };
}

/// The axes along which `el` keeps a scroll from chaining out of it: its own
/// computed overscroll-behavior on that axis is contain or none. No ancestor
/// walk.
pub fn overscrollContainAxes(self: *StyleManager, el: *Element) Element.ScrollAxes {
    self.rebuildIfDirty() catch return .{};
    const p = self.geometryProps(el);
    return .{ .x = p.overscroll_x_contains, .y = p.overscroll_y_contains };
}

/// The axes along which the effective touch-action of `el`, its own
/// intersected with its ancestors', forbids a touch from panning.
pub fn touchPanBlockedAxes(self: *StyleManager, el: *Element) Element.ScrollAxes {
    self.assertOwns(el);
    self.rebuildIfDirty() catch return .{};
    const p = self.touch_action.inheritedProps(self.arena.allocator(), el, self.frame);
    return .{ .x = p.pan_x_blocked, .y = p.pan_y_blocked };
}

/// Own computed width or height in px, from inline style or a sheet rule.
/// Null when undeclared or when it needs layout to resolve.
pub fn declaredSize(self: *StyleManager, el: *Element, comptime axis: Element.Axis) ?f64 {
    self.assertOwns(el);
    self.rebuildIfDirty() catch return null;
    const length = @field(self.geometryProps(el), @tagName(axis));
    return length.resolve(self.frame.page.getViewport());
}

/// Like declaredSize, but only the inline style counts.
pub fn inlineSize(self: *StyleManager, el: *Element, comptime axis: Element.Axis) ?f64 {
    self.assertOwns(el);
    const length = @field(inlineDeclared(Geometry.Declared, el, self.frame).props(.any), @tagName(axis)) orelse return null;
    return length.resolve(self.frame.page.getViewport());
}

pub const WidthSizing = union(enum) {
    fixed: f64, // A resolved length
    percent: f64, // A fraction of the containing block
    fill, // The containing block's width
    grow, // A flex item that grows
    shrink, // Shrink-to-fit its content
    contents, // display: contents  generates no box
};

pub fn widthSizing(self: *StyleManager, el: *Element) WidthSizing {
    self.assertOwns(el);
    self.rebuildIfDirty() catch return .shrink;

    const vis = self.visibilityProps(el);
    if (vis.box == .contents) {
        return .contents;
    }

    const width = self.geometryProps(el).width;
    switch (width.unit) {
        .px, .vw, .vh => return .{ .fixed = width.resolve(self.frame.page.getViewport()).? },
        .percent => return .{ .percent = @as(f64, width.value) / 100.0 },
        .content => return .shrink,
        .auto => {},
    }
    const flow = self.flowProps(el);
    if (flow.position.outOfFlow()) {
        // Pinned on both sides, it stretches between them (CSS 2 §10.3.7).
        // It's blockified, so an inline box does too; a table and a
        // replaced box keep their own width.
        const geometry = self.geometryProps(el);
        if (vis.box == .table or el.getTag().isReplacedOrControl() or geometry.left.unit == .auto or geometry.right.unit == .auto) {
            return .shrink;
        }
        return .fill;
    }
    // A row fills its table; the table and its cells shrink to their content
    if ((vis.box != .block_level and vis.box != .table_row) or el.getTag().isReplacedOrControl() or flow.floated) {
        return .shrink;
    }
    const parent = self.boxParent(el) orelse return .fill;
    const parent_vis = self.visibilityProps(parent);
    if (parent_vis.display != .flex or parent_vis.flex_column) {
        // Block, grid and column-flex containers stretch their children
        return .fill;
    }
    return if (self.geometryProps(el).flex_grow) .grow else .shrink;
}

/// An in-flow child of a row flex container: one of the row's flex items.
pub fn isFlexRowItem(self: *StyleManager, el: *Element) bool {
    self.assertOwns(el);
    self.rebuildIfDirty() catch return false;
    if (self.flowProps(el).position.outOfFlow()) {
        return false;
    }
    const parent = self.boxParent(el) orelse return false;
    const parent_vis = self.visibilityProps(parent);
    return parent_vis.display == .flex and parent_vis.flex_column == false;
}

/// A flex container that wraps its items onto new lines instead of
/// shrinking them. The lines aren't modeled.
pub fn flexWraps(self: *StyleManager, el: *Element) bool {
    self.assertOwns(el);
    self.rebuildIfDirty() catch return false;
    return self.visibilityProps(el).flex_wrap;
}

pub fn flexShrinks(self: *StyleManager, el: *Element) bool {
    self.assertOwns(el);
    self.rebuildIfDirty() catch return false;
    return self.geometryProps(el).flex_no_shrink == false;
}

/// The left and right margins together. A percentage resolves against the
/// containing block's width.
pub fn inlineMargins(self: *StyleManager, el: *Element, containing_width: ?f64) f64 {
    self.assertOwns(el);
    self.rebuildIfDirty() catch return 0;
    const geometry = self.geometryProps(el);
    return self.inlineSum(geometry.margin_left, geometry.margin_right, containing_width);
}

/// The left and right offsets of a positioned box, 0 for one in flow. A
/// percentage resolves against the containing block's width.
pub fn inlineInsets(self: *StyleManager, el: *Element, containing_width: f64) f64 {
    self.assertOwns(el);
    self.rebuildIfDirty() catch return 0;
    if (self.flowProps(el).position.outOfFlow() == false) {
        return 0;
    }
    const geometry = self.geometryProps(el);
    return self.inlineSum(geometry.left, geometry.right, containing_width);
}

// A left and right length together, in px. A percentage resolves against
// the containing block's width (0 when it isn't known); auto and values
// that need layout are 0.
fn inlineSum(self: *StyleManager, left: Length, right: Length, containing_width: ?f64) f64 {
    const viewport = self.frame.page.getViewport();
    var total: f64 = 0;
    for ([_]Length{ left, right }) |length| {
        total += length.resolve(viewport) orelse switch (length.unit) {
            .percent => if (containing_width) |width| @as(f64, length.value) / 100.0 * width else 0,
            else => 0,
        };
    }
    return total;
}

/// The nearest element to el that generates a box, or `el` itself it it does
pub fn boxElement(self: *StyleManager, el: *Element) ?*Element {
    self.assertOwns(el);
    if (self.generatesBox(el)) {
        return el;
    }
    return self.boxParent(el);
}

/// The nearest ancestor that generates a box
pub fn boxParent(self: *StyleManager, el: *Element) ?*Element {
    var parent = el.asNode().flatTreeParentElement(self.frame);
    while (parent) |p| : (parent = p.asNode().flatTreeParentElement(self.frame)) {
        if (self.generatesBox(p)) {
            return p;
        }
    }
    return null;
}

fn generatesBox(self: *StyleManager, el: *Element) bool {
    if (self.visibilityProps(el).box != .contents) {
        return true;
    }
    const parent = el.asNode().parentNode() orelse return false;
    // if we're at the root, and we have `display: contents`, we still force a block
    return parent._type == .document;
}

/// The nearest ancestor whose width el's percentages and fill resolve
/// against; null for the viewport. A plain inline box is skipped: a block
/// inside a span sizes off the block around the span. An absolutely
/// positioned box sizes off its nearest positioned ancestor, a fixed one
/// off the viewport.
pub fn containingBlock(self: *StyleManager, el: *Element) ?*Element {
    self.assertOwns(el);
    self.rebuildIfDirty() catch return self.boxParent(el);
    switch (self.flowProps(el).position) {
        .fixed => return null,
        .absolute => {
            var current = self.boxParent(el);
            while (current) |c| : (current = self.boxParent(c)) {
                if (self.flowProps(c).position != .static) {
                    return c;
                }
            }
            return null;
        },
        .static, .relative, .sticky => {},
    }
    return self.blockContainer(self.boxParent(el) orelse return null);
}

/// el, if it's a block container (anything but a plain inline box), else
/// its containing block. Text in el wraps at this box's width.
pub fn blockContainer(self: *StyleManager, el: *Element) ?*Element {
    self.assertOwns(el);
    self.rebuildIfDirty() catch return el;
    var current: ?*Element = el;
    while (current) |c| : (current = self.boxParent(c)) {
        if (self.plainInline(c) == false) {
            return c;
        }
    }
    return null;
}

/// A plain inline box, like <span> or <b>: text runs through it on the same
/// line, with no box boundary of its own.
pub fn isPlainInline(self: *StyleManager, el: *Element) bool {
    self.assertOwns(el);
    self.rebuildIfDirty() catch return false;
    return self.plainInline(el);
}

fn plainInline(self: *StyleManager, el: *Element) bool {
    if (self.visibilityProps(el).box != .inline_level or el.getTag().isReplacedOrControl()) {
        return false;
    }
    // Floats, out-of-flow boxes and flex/grid items are blockified
    const flow = self.flowProps(el);
    if (flow.position.outOfFlow() or flow.floated) {
        return false;
    }
    const parent = self.boxParent(el) orelse return false;
    return self.visibilityProps(parent).display != .flex and self.visibilityProps(parent).display != .grid;
}

/// The children lay out side by side: a flex row, a grid or a table row.
/// Elsewhere block children stack and only inline-level ones share a line.
pub fn laysOutInRow(self: *StyleManager, el: *Element) bool {
    self.assertOwns(el);
    self.rebuildIfDirty() catch return false;
    const vis = self.visibilityProps(el);
    return vis.box == .table_row or vis.display == .grid or (vis.display == .flex and vis.flex_column == false);
}

/// An in-flow table cell: it sits beside its sibling cells.
pub fn isTableCell(self: *StyleManager, el: *Element) bool {
    self.assertOwns(el);
    self.rebuildIfDirty() catch return false;
    if (self.visibilityProps(el).box != .table_cell) {
        return false;
    }
    const flow = self.flowProps(el);
    return flow.position.outOfFlow() == false and flow.floated == false;
}

pub fn isBlockLevel(self: *StyleManager, el: *Element) bool {
    self.assertOwns(el);
    self.rebuildIfDirty() catch return false;
    switch (self.visibilityProps(el).box) {
        .block_level, .table, .table_row => {},
        .inline_level, .atomic_inline, .contents, .table_cell => return false,
    }
    const flow = self.flowProps(el);
    return flow.position.outOfFlow() == false and flow.floated == false;
}

/// position: absolute or fixed
pub fn isOutOfFlow(self: *StyleManager, el: *Element) bool {
    self.assertOwns(el);
    self.rebuildIfDirty() catch return false;
    return self.flowProps(el).position.outOfFlow();
}

/// Own property, not inherited.
pub fn position(self: *StyleManager, el: *Element) Position {
    self.assertOwns(el);
    self.rebuildIfDirty() catch return .static;
    return self.flowProps(el).position;
}

/// `position: fixed` on `el` or on a box above it.
pub fn inFixedBox(self: *StyleManager, el: *Element) bool {
    self.assertOwns(el);
    self.rebuildIfDirty() catch return false;
    return self.flowProps(el).in_fixed;
}

/// Overflow along x is clipped or scrolled within the box, so it doesn't
/// widen the ancestors' scrollable area.
pub fn clipsOverflowX(self: *StyleManager, el: *Element) bool {
    self.assertOwns(el);
    self.rebuildIfDirty() catch return false;
    return self.geometryProps(el).overflow_x_clips;
}

/// A length that may depend on the containing block's size.
pub const BoxLength = union(enum) {
    px: f64,
    percent: f64, // A fraction of the containing block
};

pub const Side = enum { top, right, bottom, left };

/// A positioned box's inset on one side. Null for auto, and for values that
/// need layout (em, calc).
pub fn inset(self: *StyleManager, el: *Element, comptime side: Side) ?BoxLength {
    self.assertOwns(el);
    self.rebuildIfDirty() catch return null;
    return self.widthLimit(@field(self.geometryProps(el), @tagName(side)));
}

/// min-width and max-width. Null where they don't limit: auto, none, the
/// intrinsic keywords, and values that need layout (em, calc).
pub fn widthLimits(self: *StyleManager, el: *Element) struct { min: ?BoxLength, max: ?BoxLength } {
    self.assertOwns(el);
    self.rebuildIfDirty() catch return .{ .min = null, .max = null };
    const geometry = self.geometryProps(el);
    return .{ .min = self.widthLimit(geometry.min_width), .max = self.widthLimit(geometry.max_width) };
}

fn widthLimit(self: *StyleManager, length: Length) ?BoxLength {
    return switch (length.unit) {
        .auto, .content => null,
        .percent => .{ .percent = @as(f64, length.value) / 100.0 },
        .px, .vw, .vh => .{ .px = length.resolve(self.frame.page.getViewport()).? },
    };
}

// row_shrink is a flex row's shrink ratio, not a width. Offsets aren't a
// kind: see getCachedOffset.
pub const LayoutKind = enum { box_width, content_width, full_content_width, min_content_width, scrollable_content_width, row_shrink, box_height, content_height };

/// Element's computed layout (see layout.zig), valid for one layout version and viewport.
const LayoutMemo = struct {
    version: usize = 0,
    // Whether the map holds a detached element (see detachedChanged)
    detached: bool = false,
    viewport_width: u32 = 0,
    viewport_height: u32 = 0,
    map: Records(Entry) = .{},

    // One per element read. (A call to Document.extent essentially reads element)
    const Entry = struct {
        // rather than storing a bunch of optional f64 (box_width: ?f64)
        // we use a bitmap to track nullability.
        cached: std.EnumSet(Measure) = .empty,
        values: std.EnumArray(Measure, f64) = .initUndefined(),

        // offset is valid while position (among the parent's element
        // children) is under the parent's placed: how many of its first
        // children have theirs (see heightWritten).
        position: u32 = 0,
        placed: u32 = 0,

        fn get(self: *const Entry, slot: Measure) ?f64 {
            return if (self.cached.contains(slot)) self.values.get(slot) else null;
        }

        fn put(self: *Entry, slot: Measure, value: f64) void {
            self.values.set(slot, value);
            self.cached.insert(slot);
        }

        fn drop(self: *Entry, slot: Measure) void {
            self.cached.remove(slot);
        }
    };

    // The LayoutKinds, plus the box's top from its parent's top (offset).
    const Measure = blk: {
        const names = @typeInfo(LayoutKind).@"enum".field_names ++ .{"offset"};
        var values: [names.len]u8 = undefined;
        for (&values, 0..) |*value, i| {
            value.* = i;
        }
        break :blk @Enum(u8, .exhaustive, names, &values);
    };

    comptime {
        std.debug.assert(@sizeOf(Entry) <= 88);
    }
};

pub fn getCachedLayout(self: *StyleManager, el: *Element, comptime kind: LayoutKind) ?f64 {
    const memo = self.freshLayoutMemo() orelse return null;
    const entry = memo.map.getPtr(el) orelse return null;
    return entry.get(@field(LayoutMemo.Measure, @tagName(kind)));
}

pub fn setCacheLayout(self: *StyleManager, el: *Element, comptime kind: LayoutKind, value: f64) void {
    _ = self.freshLayoutMemo() orelse return;
    const entry = self.layoutEntry(el) orelse return;
    entry.put(@field(LayoutMemo.Measure, @tagName(kind)), value);
}

/// el's top, from parent's top. parent is el's flat-tree parent.
pub fn getCachedOffset(self: *StyleManager, el: *Element, parent: *Element) ?f64 {
    const memo = self.freshLayoutMemo() orelse return null;
    const entry = memo.map.getPtr(el) orelse return null;
    const offset = entry.get(.offset) orelse return null;
    const placed = if (memo.map.getPtr(parent)) |p| p.placed else 0;
    return if (entry.position < placed) offset else null;
}

/// Caches el's offset, el being its parent's index-th element child. Only
/// valid once setCachePlaced covers index.
pub fn setCacheOffset(self: *StyleManager, el: *Element, index: u32, offset: f64) bool {
    _ = self.freshLayoutMemo() orelse return false;
    const entry = self.layoutEntry(el) orelse return false;
    entry.put(.offset, offset);
    entry.position = index;
    return true;
}

/// The first `count` of parent's element children have their offsets cached.
pub fn setCachePlaced(self: *StyleManager, parent: *Element, count: u32) void {
    _ = self.freshLayoutMemo() orelse return;
    const entry = self.layoutEntry(parent) orelse return;
    entry.placed = @max(entry.placed, count);
}

// el's entry in the (fresh) layout memo, added empty if it has none
fn layoutEntry(self: *StyleManager, el: *Element) ?*LayoutMemo.Entry {
    const memo = &self.layout_memo;
    if (memo.map.getPtr(el)) |entry| {
        return entry;
    }
    const index = self.claimSlot(el) orelse return null;
    memo.map.put(self.arena.allocator(), index, .{}) catch |err| {
        log.warn(.browser, "StyleManager layout memo", .{ .err = err });
        return null;
    };
    if (memo.detached == false and el.asNode().isConnected() == false) {
        memo.detached = true;
    }
    return memo.map.getPtr(el).?;
}

// Whether the layout memo holds entries the next read keeps
fn layoutMemoLive(self: *StyleManager) bool {
    const memo = &self.layout_memo;
    const viewport = self.frame.page.getViewport();
    return memo.map.count() != 0 and memo.version == self.layoutVersion() and
        memo.viewport_width == viewport.width and memo.viewport_height == viewport.height;
}

// Rebuilding resets the arena the memo lives in, so it runs first.
fn freshLayoutMemo(self: *StyleManager) ?*LayoutMemo {
    self.rebuildIfDirty() catch return null;
    const memo = &self.layout_memo;
    const version = self.layoutVersion();
    const viewport = self.frame.page.getViewport();
    if (memo.version != version or memo.viewport_width != viewport.width or memo.viewport_height != viewport.height) {
        memo.detached = false;
        memo.map.clear();
        memo.version = version;
        memo.viewport_width = viewport.width;
        memo.viewport_height = viewport.height;
    }
    return memo;
}

/// Callers must have run rebuildIfDirty, which resets the memo.
fn visibilityProps(self: *StyleManager, el: *Element) Visibility.Computed {
    return self.visibility.inheritedProps(self.arena.allocator(), el, self.frame);
}

/// Callers must have run rebuildIfDirty, which resets the memo.
fn geometryProps(self: *StyleManager, el: *Element) Geometry.Computed {
    return self.geometry.ownProps(self.arena.allocator(), el, self.frame);
}

/// Callers must have run rebuildIfDirty, which resets the memo.
fn flowProps(self: *StyleManager, el: *Element) Flow.Computed {
    return self.flow.inheritedProps(self.arena.allocator(), el, self.frame);
}

/// A Group's rule lookup work, counted in tests.
const Work = struct {
    // bucket hash lookups: the id, each class and the tag of the element,
    // and of its parent when parent-keyed rules exist
    probes: usize = 0,
    // selectors matched against the element
    matches: usize = 0,
};

/// Taken before the arena resets, to presize the new containers.
const Capacities = struct {
    subject: BucketCapacities,
    parent: BucketCapacities,
    other_rules: usize,
};

const BucketCapacities = struct {
    id: u32,
    class: u32,
    tag: u32,
};

/// One property group's rules and memo. A rule joins only the groups it
/// declares something in.
fn Group(comptime Spec: type) type {
    return struct {
        const Self = @This();
        const Declared = Spec.Declared;
        // What we return
        const Computed = Spec.Computed;
        // What we store in our memo, see store/load
        const Stored = if (@hasDecl(Spec, "Stored")) Spec.Stored else Computed;
        // The element's own value, only used while resolving, never stored
        const Cascaded = if (@hasDecl(Spec, "Cascaded")) Spec.Cascaded else Computed;
        const Field = std.meta.FieldEnum(Declared);
        const fields = @typeInfo(Declared).@"struct".field_names;

        // applyRules' bucket lookups and selector matches, so tests can count
        // work instead of timing it. Per group type, not a field: applyRules
        // only has a const Self.
        var work: if (lp.IS_TEST) Work else void = if (lp.IS_TEST) .{} else {};

        comptime {
            // compute copies each declared value into its Cascaded namesake
            for (fields) |field| {
                std.debug.assert(@FieldType(Cascaded, field) == @typeInfo(@FieldType(Declared, field)).optional.child);
            }
        }

        const Rule = struct {
            props: RuleProps,
            selector: Selector.Selector, // Single selector, not a list

            // Packed priority: important:1 | layer_rank:11 | specificity:30 |
            // doc_order:22. A layered rule's rank bits stay 0 until
            // finalizeLayerRanks knows every layer and stamps them from
            // rule_layers[doc_order - 1].
            priority: u64,
        };

        const RuleList = std.MultiArrayList(Rule);

        // A rule's Declared without the optionals: which fields it sets, and
        // their values. Read for every candidate rule, so kept small.
        const RuleProps = struct {
            set: std.EnumSet(Field) = .empty,
            values: Cascaded = .{},

            fn init(declared: Declared) RuleProps {
                var self: RuleProps = .{};
                inline for (fields) |field| {
                    if (@field(declared, field)) |value| {
                        @field(self.values, field) = value;
                        self.set.insert(@field(Field, field));
                    }
                }
                return self;
            }
        };

        /// Rules filed under an id, class or tag, probed with one element's.
        const Buckets = struct {
            id: std.StringHashMapUnmanaged(RuleList) = .empty,
            class: std.StringHashMapUnmanaged(RuleList) = .empty,
            tag: std.AutoHashMapUnmanaged(Tag, RuleList) = .empty,

            fn isEmpty(self: *const Buckets) bool {
                return self.id.count() == 0 and self.class.count() == 0 and self.tag.count() == 0;
            }

            fn capacities(self: *const Buckets) BucketCapacities {
                return .{ .id = self.id.count(), .class = self.class.count(), .tag = self.tag.count() };
            }

            fn reset(self: *Buckets, allocator: Allocator, caps: BucketCapacities) !void {
                self.* = .{};
                try self.id.ensureTotalCapacity(allocator, caps.id);
                try self.class.ensureTotalCapacity(allocator, caps.class);
                try self.tag.ensureTotalCapacity(allocator, caps.tag);
            }

            fn list(self: *Buckets, allocator: Allocator, key: BucketKey) !*RuleList {
                return switch (key) {
                    .id => |id| (try self.id.getOrPutValue(allocator, id, .empty)).value_ptr,
                    .class => |class| (try self.class.getOrPutValue(allocator, class, .empty)).value_ptr,
                    .tag => |tag| (try self.tag.getOrPutValue(allocator, tag, .empty)).value_ptr,
                    .other => unreachable,
                };
            }

            fn stamp(self: *Buckets, sm: *const StyleManager) void {
                inline for (.{ &self.id, &self.class, &self.tag }) |map| {
                    var it = map.valueIterator();
                    while (it.next()) |rules| {
                        stampRuleList(sm, rules);
                    }
                }
            }

            // Checks the rules filed under `keyed`'s id, classes and tag
            // against `el`: the same element, or its parent.
            fn apply(self: *const Buckets, keyed: *Element, p: *Cascaded, priorities: *Priorities(Declared), el: *Element, frame: *Frame) void {
                if (keyed.getId()) |id| {
                    count(.probes);
                    if (self.id.get(id)) |rules| {
                        checkRules(&rules, p, priorities, el, frame);
                    }
                }

                if (keyed.getClassName()) |class_attr| {
                    var it = std.mem.tokenizeAny(u8, class_attr, &std.ascii.whitespace);
                    while (it.next()) |class| {
                        count(.probes);
                        if (self.class.get(class)) |rules| {
                            checkRules(&rules, p, priorities, el, frame);
                        }
                    }
                }

                count(.probes);
                if (self.tag.get(keyed.getTag())) |rules| {
                    checkRules(&rules, p, priorities, el, frame);
                }
            }
        };

        // Rules keyed by their rightmost compound's id, class or tag
        subject: Buckets = .{},

        // Rules with no such key whose `>` pins the subject's parent, keyed by
        // that parent compound (Tailwind's `.space-x-4 > * ~ *`, `.row > *`)
        parent: Buckets = .{},

        // the whole point of the parent/subject optimization is to try to keep
        // rules out of here, because it's the slowest and largest.
        other_rules: RuleList = .empty,

        // Whether any bucketed rule is !important, so importantRuleWins can
        // skip the cascade on the many pages without one.
        has_important: bool = false,

        // Valid while Page.style_version == memo_version.
        memo: Records(Stored) = .{},
        memo_version: usize = 0,

        // Entries put, ever: see StyleManager.dropped
        fills: usize = 0,

        // Whether the memo holds a detached element (see detachedChanged)
        detached: bool = false,

        // inheritedProps' scratch, kept so each walk doesn't reallocate
        path: std.ArrayList(struct { el: *Element, own: Cascaded }) = .empty,

        // inheritedProps' cascades, so tests can count work instead of timing it
        cascades: if (lp.IS_TEST) usize else void = if (lp.IS_TEST) 0 else {},

        fn hasRules(self: *const Self) bool {
            return self.subject.isEmpty() == false or self.parent.isEmpty() == false or self.other_rules.len != 0;
        }

        fn capacities(self: *const Self) Capacities {
            return .{
                .parent = self.parent.capacities(),
                .subject = self.subject.capacities(),
                .other_rules = self.other_rules.len,
            };
        }

        fn reset(self: *Self, allocator: Allocator, caps: Capacities) !void {
            self.memo = .{};
            self.path = .empty;

            try self.parent.reset(allocator, caps.parent);
            try self.subject.reset(allocator, caps.subject);

            self.other_rules = .{};
            self.has_important = false;
            try self.other_rules.ensureTotalCapacity(allocator, caps.other_rules);
        }

        fn bucket(self: *Self, allocator: Allocator, placement: Placement, rule: Rule) !void {
            const list: *RuleList = switch (placement) {
                .parent => |key| try self.parent.list(allocator, key),
                .subject => |key| try self.subject.list(allocator, key),
                .other => &self.other_rules,
            };
            try list.append(allocator, rule);
            if (rule.priority & IMPORTANT_BIT != 0) {
                self.has_important = true;
            }
        }

        fn stampRules(self: *Self, sm: *const StyleManager) void {
            stampRuleList(sm, &self.other_rules);
            self.parent.stamp(sm);
            self.subject.stamp(sm);
        }

        fn stampRuleList(sm: *const StyleManager, rules: *RuleList) void {
            for (rules.items(.priority)) |*priority| {
                priority.* |= sm.layerRank(priority.*) << RANK_SHIFT;
            }
        }

        fn ownProps(self: *Self, allocator: Allocator, el: *Element, frame: *Frame) Computed {
            comptime std.debug.assert(Cascaded == Computed);
            const memo = self.freshMemo(frame);
            if (memo.get(el)) |cached| {
                return load(cached);
            }
            const computed = self.compute(el, frame);
            const index = frame._style_manager.claimSlot(el) orelse return computed;
            memo.put(allocator, index, store(computed)) catch |err| {
                log.warn(.browser, "StyleManager memo", .{ .err = err });
                return computed;
            };
            self.fills += 1;
            if (self.detached == false and el.asNode().isConnected() == false) {
                self.detached = true;
            }
            return computed;
        }

        /// Resolves the path up to the first memoized ancestor, so each
        /// element is cascaded once per memo version however deep the tree.
        fn inheritedProps(self: *Self, allocator: Allocator, el: *Element, frame: *Frame) Computed {
            const memo = self.freshMemo(frame);
            self.path.clearRetainingCapacity();
            var above: Computed = .{};
            var current: ?*Element = el;
            while (current) |elem| : (current = elem.asNode().flatTreeParentElement(frame)) {
                if (memo.get(elem)) |cached| {
                    above = load(cached);
                    break;
                }
                if (comptime lp.IS_TEST) {
                    self.cascades += 1;
                }
                self.path.append(allocator, .{ .el = elem, .own = self.compute(elem, frame) }) catch |err| {
                    log.warn(.browser, "StyleManager path", .{ .err = err });
                    // Degrades to the element's own values, without its ancestors
                    return .resolve(self.compute(el, frame), .{});
                };
            }

            // The walk stopped at a memoized ancestor, whose tree is el's,
            // or at the root of el's tree.
            if (current == null and self.path.items.len != 0 and self.detached == false) {
                self.detached = self.path.items[self.path.items.len - 1].el.asNode().isConnected() == false;
            }
            self.fills += self.path.items.len;
            var storing = true;
            var it = std.mem.reverseIterator(self.path.items);
            while (it.next()) |step| {
                above = .resolve(step.own, above);
                if (storing) {
                    // Not below an ancestor that isn't stored: dropInherited
                    // stops at an uncached element
                    const index = frame._style_manager.claimSlot(step.el) orelse {
                        storing = false;
                        continue;
                    };
                    memo.put(allocator, index, store(above)) catch |err| {
                        log.warn(.browser, "StyleManager memo", .{ .err = err });
                        storing = false;
                    };
                }
            }
            return above;
        }

        fn fresh(self: *const Self, frame: *const Frame) bool {
            return self.memo_version == frame.page.style_version;
        }

        fn store(computed: Computed) Stored {
            return if (Stored == Computed) computed else .pack(computed);
        }

        fn load(stored: Stored) Computed {
            return if (Stored == Computed) stored else stored.unpack();
        }

        fn freshMemo(self: *Self, frame: *Frame) *Records(Stored) {
            const version = frame.page.style_version;
            if (self.memo_version != version) {
                self.memo.clear();
                self.detached = false;
                self.memo_version = version;
            }
            return &self.memo;
        }

        fn compute(self: *const Self, el: *Element, frame: *Frame) Cascaded {
            // Debug only check to make sure any attribute we access is known.
            // Protects against adding reads to un-tracked attributes.
            const previous = fill_check.enter(&frame._style_manager);
            defer fill_check.exit(previous);

            var p: Cascaded = .{};
            var priorities: Priorities(Declared) = .initFill(0);

            const inline_style = inlineDeclared(Declared, el, frame);
            inline for (.{ .normal, .important }, .{ INLINE_PRIORITY, INLINE_IMPORTANT_PRIORITY }) |importance, priority| {
                const inline_declared = inline_style.props(importance);
                inline for (fields) |field| {
                    if (@field(inline_declared, field)) |value| {
                        @field(p, field) = value;
                        priorities.set(@field(Field, field), priority);
                    }
                }
            }

            self.applyRules(&p, &priorities, el, frame);

            if (@hasDecl(Spec, "finish")) {
                Spec.finish(&p, el, frame, &priorities);
            }
            return p;
        }

        // Whether an !important rule beats a normal inline declaration of the
        // properties `declared` sets: the cascade seeded with just that
        // declaration, every other property out of reach.
        fn importantRuleWins(self: *const Self, declared: Declared, el: *Element, frame: *Frame) bool {
            if (self.has_important == false or declaresAny(declared) == false) {
                return false;
            }
            var p: Cascaded = .{};
            var priorities: Priorities(Declared) = .initFill(INLINE_IMPORTANT_PRIORITY);
            inline for (fields) |field| {
                if (@field(declared, field) != null) {
                    priorities.set(@field(Field, field), INLINE_PRIORITY);
                }
            }

            self.applyRules(&p, &priorities, el, frame);

            inline for (fields) |field| {
                if (@field(declared, field) != null and priorities.get(@field(Field, field)) != INLINE_PRIORITY) {
                    return true;
                }
            }
            return false;
        }

        // checkRules keeps the strongest rule per property, so the order the
        // lists are walked in doesn't change the result.
        fn applyRules(self: *const Self, p: *Cascaded, priorities: *Priorities(Declared), el: *Element, frame: *Frame) void {
            self.subject.apply(el, p, priorities, el, frame);

            if (self.parent.isEmpty() == false) {
                // The DOM parent, as `>` matches: a shadow root's children have
                // none, and no parent-keyed rule can match them.
                if (el.asNode()._parent) |parent| {
                    if (parent.is(Element)) |parent_el| {
                        self.parent.apply(parent_el, p, priorities, el, frame);
                    }
                }
            }

            checkRules(&self.other_rules, p, priorities, el, frame);
        }

        inline fn count(comptime field: std.meta.FieldEnum(Work)) void {
            if (comptime lp.IS_TEST) {
                @field(work, @tagName(field)) += 1;
            }
        }

        fn checkRules(rules: *const RuleList, p: *Cascaded, priorities: *Priorities(Declared), el: *Element, frame: *Frame) void {
            rules: for (rules.items(.priority), rules.items(.props), rules.items(.selector)) |priority, rule, selector| {
                var matched = false;
                inline for (fields) |field| {
                    const f = @field(Field, field);
                    // Only a rule that sets a property nothing stronger has set
                    // yet is worth matching, once.
                    if (rule.set.contains(f) and priority > priorities.get(f)) {
                        if (matched == false) {
                            count(.matches);
                            if (matchesSelector(el, selector, frame) == false) {
                                continue :rules;
                            }
                            matched = true;
                        }
                        @field(p, field) = @field(rule.values, field);
                        priorities.set(f, priority);
                    }
                }
            }
        }
    };
}

/// Centralizes UA-stylesheet display:none truth so `getComputedStyle().display`
/// (via `hasDisplayNone`) and `el.checkVisibility()` (via `isHidden`) agree.
/// Spec: HTML Rendering §15.3.1 "Hidden elements".
fn matchesUaDisplayNoneRule(el: *Element, frame: *Frame) bool {
    // Tag check first: O(1) switch, exits for the ~95% of elements with
    // ordinary tags before we touch the attribute list.
    const tag = el.getTag();
    if (tag.isHiddenByUaStylesheet()) return true;

    if (el.hasAttributeInterned("hidden")) return true;

    // input[type="hidden" i] { display: none !important }
    // _input_type is parsed case-insensitively at attribute-set time.
    if (tag == .input) {
        if (el.is(Input)) |input| {
            if (input._input_type == .hidden) return true;
        }
    }

    if (tag == .dialog) {
        // dialog:not([open]) { display: none }
        // dialog:popover-open { display: block }
        if (!el.hasAttributeSafe(comptime .wrap("open")) and !popover.isOpen(el, frame)) return true;
    } else if (el.hasAttributeInterned("popover") and !popover.isOpen(el, frame)) {
        // [popover]:not(:popover-open):not(dialog[open]) { display: none }
        return true;
    }

    // details:not([open]) > *:not(summary) { display: none }
    if (tag != .summary) {
        if (el.parentElement()) |parent| {
            if (parent.is(Element.Html.Details)) |d| {
                if (d.isClosed()) {
                    return true;
                }
            }
        }
    }

    return false;
}

/// Add a rule's declarations under `selector_text`: a style rule's own
/// selector or, for a nested rule, that selector resolved against its parent's.
/// Returns what addSelectorRules does.
fn addStoredRule(self: *StyleManager, entry: *const RuleStore.Entry, selector_text: []const u8, layer: u16) !bool {
    if (selector_text.len == 0) {
        return false;
    }
    const folded = extractDeclared(Declarations, &entry._block, self.frame);
    const lazy = try self.extractLazyDeclarations(&entry._block);

    // A custom rule holds selector_text until the property is looked up, but it
    // doesn't need a copy: the sheet frees a rule's selector only along with
    // sheetModified(), and every lookup rebuilds first.
    const normal = folded.props(.normal);
    const important = folded.props(.important);
    return self.addSelectorRules(selector_text, &normal, &important, lazy, layer);
}

/// A style rule appended at or after the sheet that emitted the last rule is
/// last in cascade order, so it joins the buckets directly. Anything else
/// takes the rebuild path.
pub fn ruleInserted(self: *StyleManager, sheet: *CSSStyleSheet, index: u32) void {
    if (self.dirty or sheet._disabled) {
        // The pending rebuild reads the sheet's rules and picks it up.
        return;
    }
    const entry = &sheet._store.entries()[index];
    // A rule with nested rules takes the rebuild path, which adds them.
    if (entry._kind != .style or entry._children != null or !self.appendable(sheet, index)) {
        return self.sheetModified();
    }
    const before = self.next_doc_order;
    const animations = self.animationRuleCount();
    const changed = self.addStoredRule(entry, entry.text(), NO_LAYER) catch return self.sheetModified();
    if (self.next_doc_order != before) {
        self.last_rule_sheet = sheet;
    }
    if (self.animationRuleCount() != animations) {
        Frame.css_animations.documentChanged(self.frame);
    }
    if (!changed) {
        // Nothing tracked changed, so every memoized answer still holds.
        return;
    }
    Frame.change.rulesChanged(self.frame);
}

fn appendable(self: *const StyleManager, sheet: *CSSStyleSheet, index: u32) bool {
    if (index + 1 != sheet._store.length()) {
        return false;
    }
    const sheets = self.frame.document._style_sheets orelse return false;
    var past_last = self.last_rule_sheet == null;
    for (sheets._sheets.items) |s| {
        if (s == self.last_rule_sheet) {
            past_last = true;
        }
        if (s == sheet) {
            return past_last;
        }
    }
    return false;
}

/// The lazy declarations of a block. Names within one
/// declaration block are already unique, so there is nothing to dedup here.
fn extractLazyDeclarations(self: *StyleManager, block: *const DeclarationBlock) !LazyDeclarations {
    const arena = self.arena.allocator();

    var declared: std.ArrayList(LazyDeclaration) = .empty;
    var lazy_animation: LazyAnimation = .{};
    var it = block.iterator(&self.frame.page.css_custom_names);
    while (it.next()) |declaration| {
        if (isLazy(declaration.id)) {
            // Not duping declaration.value is risky, but ok. Any write to the
            // declaration which would free the value also makes the StyleManager
            // as dirty and a rebuild would happen 100% of the time before the
            // freed value was accessed.
            try declared.append(arena, .{
                .id = declaration.id,
                .value = declaration.value,
                .important = declaration.important,
            });
        } else if (Animation.Property.fromId(declaration.id)) |animation_property| {
            lazy_animation.declare(animation_property, declaration.value, declaration.important);
        }
    }
    return .{ .declared = declared.items, .animation = lazy_animation };
}

const BucketKey = union(enum) {
    other,
    tag: Tag,
    id: []const u8,
    class: []const u8,
};

/// Where a group files a rule.
const Placement = union(enum) {
    other,
    parent: BucketKey,
    subject: BucketKey,
};

/// Null for a selector we skip (see getBucketKey).
fn placeSelector(selector: Selector.Selector) ?Placement {
    const key = getBucketKey(selector.rightmost()) orelse return null;
    if (key != .other) {
        // our goal is just to limit things that end up in .other
        return .{ .subject = key };
    }

    const compound = parentCompound(selector) orelse return .other;
    const parent_key = getBucketKey(compound) orelse return .other;
    if (parent_key == .other) {
        return .other;
    }
    return .{ .parent = parent_key };
}

/// The compound a `>` requires the subject's parent to match, looking past
/// any `+`/`~` chain (siblings share the parent).
fn parentCompound(selector: Selector.Selector) ?Selector.Compound {
    var i = selector.segments.len;
    while (i > 0) {
        i -= 1;
        switch (selector.segments[i].combinator) {
            .next_sibling, .subsequent_sibling => {},
            .child => return if (i == 0) selector.first else selector.segments[i - 1].compound,
            .descendant => return null,
        }
    }
    return null;
}

/// Optimization. A lone `:where(X)` matches exactly what X does. What changes
/// is its priority (it has zero specificity). So we need to remain aware of
/// the :where with respect to the priority, but we can unwrap so that it
/// hopefully doesn't land in the .other list.
fn unwrapWhere(selector: Selector.Selector) Selector.Selector {
    if (selector.segments.len != 0 or selector.first.parts.len != 1) {
        return selector;
    }

    const inner = switch (selector.first.parts[0]) {
        .pseudo_class => |pc| switch (pc) {
            .where => |list| list,
            else => return selector,
        },
        else => return selector,
    };
    if (inner.len != 1 or getBucketKey(inner[0].rightmost()) == null) {
        return selector;
    }
    return inner[0];
}

/// Returns the best bucket key for a compound selector, or null if it contains
/// a dynamic pseudo-class we should skip (hover, active, focus, etc.)
/// Priority: id > class > tag > other
fn getBucketKey(compound: Selector.Compound) ?BucketKey {
    var best_key: BucketKey = .other;

    for (compound.parts) |part| {
        switch (part) {
            .id => |id| {
                best_key = .{ .id = id };
            },
            .class => |class| {
                if (best_key != .id) {
                    best_key = .{ .class = class };
                }
            },
            .tag => |tag| {
                if (best_key == .other) {
                    best_key = .{ .tag = tag };
                }
            },
            .tag_name => {
                // Custom tag - put in other bucket (can't efficiently look up)
                // Keep current best_key if we have something better
            },
            .pseudo_class => |pc| {
                // Skip dynamic pseudo-classes - they depend on interaction state
                switch (pc) {
                    .hover, .active, .focus, .focus_within, .focus_visible, .visited, .target => {
                        return null; // Skip this selector entirely
                    },
                    else => {},
                }
            },
            .pseudo_element, .never => return null,
            .universal, .attribute => {},
        }
    }

    return best_key;
}

/// Extracts the tracked properties from a declaration block. The block holds
/// one entry per name in first-declared order, so folding it in order gives a
/// shorthand and its longhands the same precedence as the source text.
fn extractDeclared(comptime Declared: type, block: *const DeclarationBlock, frame: *const Frame) Slots(Declared) {
    var slots: Slots(Declared) = .{};
    var it = block.iterator(&frame.page.css_custom_names);
    while (it.next()) |declaration| {
        slots.apply(declaration.id, declaration.value, declaration.important);
    }
    return slots;
}

// Computes CSS specificity for a selector.
// Returns packed value: (id_count << 20) | (class_count << 10) | element_count
pub fn computeSpecificity(selector: Selector.Selector) u32 {
    var ids: u32 = 0;
    var classes: u32 = 0; // includes classes, attributes, pseudo-classes
    var elements: u32 = 0; // includes elements, pseudo-elements

    // Count specificity for first compound
    countCompoundSpecificity(selector.first, &ids, &classes, &elements);

    // Count specificity for subsequent segments
    for (selector.segments) |segment| {
        countCompoundSpecificity(segment.compound, &ids, &classes, &elements);
    }

    // Pack into single u32: (ids << 20) | (classes << 10) | elements
    // This gives us 10 bits each, supporting up to 1023 of each type
    return (@as(u32, @min(ids, 1023)) << 20) | (@as(u32, @min(classes, 1023)) << 10) | @min(elements, 1023);
}

fn countCompoundSpecificity(compound: Selector.Compound, ids: *u32, classes: *u32, elements: *u32) void {
    for (compound.parts) |part| {
        switch (part) {
            .id => ids.* += 1,
            .class => classes.* += 1,
            .tag, .tag_name, .pseudo_element => elements.* += 1,
            .universal => {}, // zero specificity
            .attribute, .never => classes.* += 1,
            .pseudo_class => |pc| {
                switch (pc) {
                    // :where() has zero specificity
                    .where => {},
                    // :not(), :is(), :has() take specificity of their most specific argument
                    .not, .is, .has => |nested| {
                        var max_nested: u32 = 0;
                        for (nested) |nested_sel| {
                            const spec = computeSpecificity(nested_sel);
                            if (spec > max_nested) max_nested = spec;
                        }
                        // Unpack and add to our counts
                        ids.* += (max_nested >> 20) & 0x3FF;
                        classes.* += (max_nested >> 10) & 0x3FF;
                        elements.* += max_nested & 0x3FF;
                    },
                    // :nth-child(An+B of S) is a pseudo-class plus its most specific argument
                    .nth_child_of, .nth_last_child_of => |nth_of| {
                        var max_nested: u32 = 0;
                        for (nth_of.selectors) |nested_sel| {
                            const spec = computeSpecificity(nested_sel);
                            if (spec > max_nested) max_nested = spec;
                        }
                        ids.* += (max_nested >> 20) & 0x3FF;
                        classes.* += 1 + ((max_nested >> 10) & 0x3FF);
                        elements.* += max_nested & 0x3FF;
                    },
                    // All other pseudo-classes count as class-level specificity
                    else => classes.* += 1,
                }
            },
        }
    }
}

fn matchesSelector(el: *Element, selector: Selector.Selector, frame: *Frame) bool {
    // Outside @scope, a stylesheet's :scope is the root element.
    return SelectorList.matches(el.asNode(), selector, frame.document.asNode(), null, frame);
}

/// Only the values the dumpers act on; everything else is `other`.
pub const Display = enum(u2) {
    none,
    flex,
    grid,
    other,

    fn parse(value: []const u8) Display {
        if (std.ascii.eqlIgnoreCase(value, "none")) return .none;
        if (std.ascii.eqlIgnoreCase(value, "flex") or std.ascii.eqlIgnoreCase(value, "inline-flex")) return .flex;
        if (std.ascii.eqlIgnoreCase(value, "grid") or std.ascii.eqlIgnoreCase(value, "inline-grid")) return .grid;
        return .other;
    }
};

const Box = enum(u3) {
    block_level,
    // A plain inline box: not a block container, so not a containing block
    inline_level,
    // inline-block, inline-flex, ...: inline outside, block container inside
    atomic_inline,
    contents,
    table,
    // Stacks like a block, lays its cells out side by side
    table_row,
    // Sits beside its siblings, like in an anonymous row when its parent
    // isn't one
    table_cell,

    fn parse(value: []const u8) ?Box {
        const trimmed = std.mem.trim(u8, value, &std.ascii.whitespace);
        if (std.ascii.eqlIgnoreCase(trimmed, "contents")) {
            return .contents;
        }

        if (std.ascii.eqlIgnoreCase(trimmed, "table")) {
            return .table;
        }
        if (std.ascii.eqlIgnoreCase(trimmed, "table-row")) {
            return .table_row;
        }
        if (std.ascii.eqlIgnoreCase(trimmed, "table-cell")) {
            return .table_cell;
        }
        // Row groups and captions stack their children like a block
        inline for (.{ "table-row-group", "table-header-group", "table-footer-group", "table-caption" }) |keyword| {
            if (std.ascii.eqlIgnoreCase(trimmed, keyword)) {
                return .block_level;
            }
        }

        if (std.ascii.eqlIgnoreCase(trimmed, "inline") or std.ascii.eqlIgnoreCase(trimmed, "inline flow")) {
            return .inline_level;
        }
        if (std.ascii.startsWithIgnoreCase(trimmed, "inline")) {
            return .atomic_inline;
        }

        inline for (.{ "block", "flow-root", "list-item", "flex", "grid", "flow" }) |keyword| {
            if (std.ascii.eqlIgnoreCase(trimmed, keyword)) {
                return .block_level;
            }
        }

        // Multi-keyword values start with the outer type
        if (std.ascii.startsWithIgnoreCase(trimmed, "block ")) {
            return .block_level;
        }
        return null;
    }

    fn uaDefault(tag: Tag) Box {
        return switch (tag) {
            .table => .table,
            .tr => .table_row,
            .td, .th => .table_cell,
            .slot => .contents,
            .form, .li, .dd, .dt, .details, .summary, .menu, .dir, .hgroup, .legend, .html, .body, .optgroup, .option => .block_level,
            .tbody, .thead, .tfoot, .caption => .block_level,
            else => if (tag.isBlock()) .block_level else .inline_level,
        };
    }
};

/// The case-changing part of `text-transform`. innerText applies `uppercase`
/// and `lowercase`; `capitalize` is a computed value only, and `full-width`,
/// `full-size-kana` and `math-auto` are accepted but not applied. `.inherit` is both the
/// `inherit`/`unset` keywords and "nothing declared": text-transform inherits.
pub const TextTransform = enum(u3) {
    inherit,
    none,
    capitalize,
    uppercase,
    lowercase,

    // Null for an invalid value, which drops the declaration.
    fn parse(value: []const u8) ?TextTransform {
        const trimmed = std.mem.trim(u8, value, &std.ascii.whitespace);
        if (std.ascii.eqlIgnoreCase(trimmed, "inherit") or std.ascii.eqlIgnoreCase(trimmed, "unset") or std.ascii.eqlIgnoreCase(trimmed, "revert") or std.ascii.eqlIgnoreCase(trimmed, "revert-layer")) {
            return .inherit;
        }
        if (std.ascii.eqlIgnoreCase(trimmed, "initial") or std.ascii.eqlIgnoreCase(trimmed, "none")) {
            return .none;
        }

        // At most one case keyword, alongside any of the non-case ones.
        var result: ?TextTransform = null;
        var any = false;
        var it = std.mem.tokenizeAny(u8, trimmed, &std.ascii.whitespace);
        while (it.next()) |token| {
            any = true;
            const case: TextTransform = if (std.ascii.eqlIgnoreCase(token, "uppercase"))
                .uppercase
            else if (std.ascii.eqlIgnoreCase(token, "lowercase"))
                .lowercase
            else if (std.ascii.eqlIgnoreCase(token, "capitalize"))
                .capitalize
            else if (std.ascii.eqlIgnoreCase(token, "full-width") or std.ascii.eqlIgnoreCase(token, "full-size-kana") or std.ascii.eqlIgnoreCase(token, "math-auto"))
                continue
            else
                return null;
            if (result != null) {
                return null;
            }
            result = case;
        }
        if (any == false) {
            return null;
        }
        return result orelse .none;
    }

    /// The computed-value keyword, as getComputedStyle reports it.
    pub fn keyword(self: TextTransform) []const u8 {
        return switch (self) {
            .inherit, .none => "none",
            else => @tagName(self),
        };
    }
};

// white-space-collapse
const SpaceCollapse = enum(u3) {
    inherit,
    collapse,
    preserve,
    preserve_breaks,
    preserve_spaces,
    break_spaces,

    // null when invalid
    fn parse(value: []const u8) ?SpaceCollapse {
        const trimmed = std.mem.trim(u8, value, &std.ascii.whitespace);
        if (isInheritKeyword(trimmed)) {
            return .inherit;
        }
        if (std.ascii.eqlIgnoreCase(trimmed, "initial")) {
            return .collapse;
        }
        return keyword(trimmed);
    }

    fn keyword(token: []const u8) ?SpaceCollapse {
        if (std.ascii.eqlIgnoreCase(token, "collapse") or std.ascii.eqlIgnoreCase(token, "discard")) {
            return .collapse;
        }
        if (std.ascii.eqlIgnoreCase(token, "preserve")) {
            return .preserve;
        }
        if (std.ascii.eqlIgnoreCase(token, "preserve-breaks")) {
            return .preserve_breaks;
        }
        if (std.ascii.eqlIgnoreCase(token, "preserve-spaces")) {
            return .preserve_spaces;
        }
        if (std.ascii.eqlIgnoreCase(token, "break-spaces")) {
            return .break_spaces;
        }
        return null;
    }

    fn keepsSpaces(self: SpaceCollapse) bool {
        return switch (self) {
            .inherit, .collapse, .preserve_breaks => false,
            .preserve, .preserve_spaces, .break_spaces => true,
        };
    }
};

/// text-wrap-mode
const WrapMode = enum(u2) {
    inherit,
    wrap,
    nowrap,

    // null when invalid
    fn parse(value: []const u8) ?WrapMode {
        const trimmed = std.mem.trim(u8, value, &std.ascii.whitespace);
        if (isInheritKeyword(trimmed)) {
            return .inherit;
        }
        if (std.ascii.eqlIgnoreCase(trimmed, "initial")) {
            return .wrap;
        }
        return keyword(trimmed);
    }

    /// The `text-wrap` shorthand
    fn parseTextWrap(value: []const u8) ?WrapMode {
        const trimmed = std.mem.trim(u8, value, &std.ascii.whitespace);
        if (isInheritKeyword(trimmed)) {
            return .inherit;
        }
        if (std.ascii.eqlIgnoreCase(trimmed, "initial")) {
            return .wrap;
        }

        var any = false;
        var mode: ?WrapMode = null;

        var it = std.mem.tokenizeAny(u8, trimmed, &std.ascii.whitespace);
        while (it.next()) |token| {
            any = true;
            if (keyword(token)) |m| {
                if (mode != null) {
                    return null;
                }
                mode = m;
            } else if (isWrapStyle(token) == false) {
                return null;
            }
        }
        if (any == false) {
            return null;
        }
        return mode orelse .wrap;
    }

    fn keyword(token: []const u8) ?WrapMode {
        if (std.ascii.eqlIgnoreCase(token, "wrap")) return .wrap;
        if (std.ascii.eqlIgnoreCase(token, "nowrap")) return .nowrap;
        return null;
    }

    fn isWrapStyle(token: []const u8) bool {
        inline for (.{ "auto", "balance", "pretty", "stable" }) |style| {
            if (std.ascii.eqlIgnoreCase(token, style)) return true;
        }
        return false;
    }
};

/// The `white-space` shorthand: a legacy keyword, or any of a
/// white-space-collapse and a text-wrap-mode keyword. white-space-trim's
/// keywords are accepted but not applied.
const WhiteSpace = struct {
    collapse: SpaceCollapse = .inherit,
    wrap: WrapMode = .inherit,

    // Null for an invalid value, which drops the declaration.
    fn parse(value: []const u8) ?WhiteSpace {
        const trimmed = std.mem.trim(u8, value, &std.ascii.whitespace);
        if (isInheritKeyword(trimmed)) return .{};
        if (std.ascii.eqlIgnoreCase(trimmed, "normal") or std.ascii.eqlIgnoreCase(trimmed, "initial")) return .{ .collapse = .collapse, .wrap = .wrap };
        if (std.ascii.eqlIgnoreCase(trimmed, "pre")) return .{ .collapse = .preserve, .wrap = .nowrap };
        if (std.ascii.eqlIgnoreCase(trimmed, "pre-wrap")) return .{ .collapse = .preserve, .wrap = .wrap };
        if (std.ascii.eqlIgnoreCase(trimmed, "pre-line")) return .{ .collapse = .preserve_breaks, .wrap = .wrap };

        var collapse: ?SpaceCollapse = null;
        var wrap: ?WrapMode = null;
        var any = false;
        var it = std.mem.tokenizeAny(u8, trimmed, &std.ascii.whitespace);
        while (it.next()) |token| {
            any = true;
            if (SpaceCollapse.keyword(token)) |c| {
                if (collapse != null) return null;
                collapse = c;
            } else if (WrapMode.keyword(token)) |w| {
                if (wrap != null) return null;
                wrap = w;
            } else if (isTrimKeyword(token) == false) {
                return null;
            }
        }
        if (any == false) return null;
        return .{ .collapse = collapse orelse .collapse, .wrap = wrap orelse .wrap };
    }

    fn uaDefault(tag: Tag) ?WhiteSpace {
        return switch (tag) {
            .pre => .{ .collapse = .preserve, .wrap = .nowrap },
            .textarea => .{ .collapse = .preserve, .wrap = .wrap },
            else => null,
        };
    }

    fn isTrimKeyword(token: []const u8) bool {
        inline for (.{ "discard-before", "discard-after", "discard-inner" }) |trim| {
            if (std.ascii.eqlIgnoreCase(token, trim)) return true;
        }
        return false;
    }
};

fn isInheritKeyword(value: []const u8) bool {
    return inheritsKeyword(value) or std.ascii.eqlIgnoreCase(value, "revert") or std.ascii.eqlIgnoreCase(value, "revert-layer");
}

/// A declared width or height. Values that need layout (auto, em, calc) are
/// `auto`: they win the cascade but give no size. The intrinsic sizes, which
/// follow the content, are `content`. A `percent` resolves against the
/// containing block, which only the width axis knows.
pub const Length = packed struct(u35) {
    value: f32 = 0,
    unit: Unit = .auto,

    const Unit = enum(u3) { auto, content, px, vw, vh, percent };

    fn parse(text: []const u8) Length {
        if (isIntrinsic(text)) {
            return .{ .unit = .content };
        }
        const parsed = units.parse(text) catch return .{};
        if (parsed.value < 0) {
            return .{};
        }
        return switch (parsed.unit) {
            inline .vw, .vh => |unit| .{ .value = @floatCast(parsed.value), .unit = @field(Unit, @tagName(unit)) },
            .percentage => .{ .value = @floatCast(parsed.value), .unit = .percent },
            else => .{
                .value = @floatCast(parsed.value * (units.absoluteLengthFactor(parsed.unit) orelse return .{})),
                .unit = .px,
            },
        };
    }

    // A margin may be negative and has no intrinsic sizes; auto is 0.
    fn parseMargin(text: []const u8) Length {
        const parsed = units.parse(text) catch return .{};
        return switch (parsed.unit) {
            inline .vw, .vh => |unit| .{ .value = @floatCast(parsed.value), .unit = @field(Unit, @tagName(unit)) },
            .percentage => .{ .value = @floatCast(parsed.value), .unit = .percent },
            else => .{
                .value = @floatCast(parsed.value * (units.absoluteLengthFactor(parsed.unit) orelse return .{})),
                .unit = .px,
            },
        };
    }

    fn isIntrinsic(text: []const u8) bool {
        inline for (.{ "min-content", "max-content", "fit-content" }) |keyword| {
            if (std.ascii.eqlIgnoreCase(text, keyword)) {
                return true;
            }
        }
        return std.ascii.startsWithIgnoreCase(text, "fit-content(");
    }

    fn resolve(self: Length, viewport: Viewport) ?f64 {
        const value: f64 = self.value;
        return switch (self.unit) {
            .auto, .content, .percent => null,
            .px => value,
            .vw, .vh => value * @as(f64, @floatFromInt(if (self.unit == .vw) viewport.width else viewport.height)) / 100.0,
        };
    }
};

/// Whether an element is rendered and takes pointer input.
const Visibility = struct {
    const Declared = struct {
        // A shorthand comes before its longhands, so a later longhand wins
        const names = [_][]const u8{ "display", "visibility", "opacity", "pointer-events", "flex-flow", "flex-direction", "flex-wrap" };

        display: ?Display = null,
        box: ?Box = null,
        flex_column: ?bool = null,
        flex_wrap: ?bool = null,
        // Inner null: an explicit inherit, which still wins the cascade
        visibility_hidden: ??bool = null,
        opacity_zero: ?bool = null,
        pointer_events_none: ??bool = null,

        fn apply(self: *Declared, id: properties.Id, value: []const u8) void {
            switch (id) {
                .display => {
                    self.display = Display.parse(value);
                    self.box = Box.parse(value);
                },
                .@"flex-direction" => {
                    self.flex_column = isColumnDirection(value);
                },
                .@"flex-wrap" => {
                    self.flex_wrap = isWrap(value);
                },
                .@"flex-flow" => {
                    self.flex_column = false;
                    self.flex_wrap = false;
                    // Either order; an omitted one resets to row or nowrap
                    var it = std.mem.tokenizeAny(u8, value, &std.ascii.whitespace);
                    while (it.next()) |token| {
                        if (isColumnDirection(token)) {
                            self.flex_column = true;
                        }
                        if (isWrap(token)) {
                            self.flex_wrap = true;
                        }
                    }
                },
                .visibility => {
                    self.visibility_hidden = parseInheritedFlag(value, &.{ "hidden", "collapse" }, &.{ "visible", "initial" });
                },
                .opacity => {
                    self.opacity_zero = std.ascii.eqlIgnoreCase(value, "0");
                },
                .@"pointer-events" => {
                    self.pointer_events_none = parseInheritedFlag(value, &.{"none"}, &.{
                        "auto",         "initial", "visiblePainted", "visibleFill", "visibleStroke",
                        "visible",      "painted", "fill",           "stroke",      "all",
                        "bounding-box",
                    });
                },
                else => {},
            }
        }

        fn isColumnDirection(value: []const u8) bool {
            const trimmed = std.mem.trim(u8, value, &std.ascii.whitespace);
            return std.ascii.eqlIgnoreCase(trimmed, "column") or std.ascii.eqlIgnoreCase(trimmed, "column-reverse");
        }

        fn isWrap(value: []const u8) bool {
            const trimmed = std.mem.trim(u8, value, &std.ascii.whitespace);
            return std.ascii.eqlIgnoreCase(trimmed, "wrap") or std.ascii.eqlIgnoreCase(trimmed, "wrap-reverse");
        }
    };

    // The element's own values, from the cascade.
    pub const Cascaded = struct {
        // Author value (inline or sheet). Without `author_display` it's the UA
        // fallback: .none when matchesUaDisplayNoneRule, else .other.
        display: Display = .other,
        // Without an author `display` it's the tag's UA default, see finish
        box: Box = .inline_level,
        flex_column: bool = false,
        flex_wrap: bool = false,
        author_display: bool = false,
        // Null takes the parent's value
        visibility_hidden: ?bool = null,
        opacity_zero: bool = false,
        pointer_events_none: ?bool = null,
        // see Node.isOutsideFlatTree. Hidden like display:none
        outside_flat_tree: bool = false,
    };

    const Computed = packed struct(u12) {
        display: Display = .other,
        box: Box = .inline_level,
        flex_column: bool = false,
        flex_wrap: bool = false,
        author_display: bool = false,
        visibility_hidden: bool = false, // inherited
        pointer_events_none: bool = false, // inherited
        in_display_none: bool = false, // This element or an ancestor
        in_opacity_zero: bool = false, // This element or an ancestor

        fn resolve(own: Cascaded, parent: Computed) Computed {
            return .{
                .display = own.display,
                .box = own.box,
                .flex_column = own.flex_column,
                .flex_wrap = own.flex_wrap,
                .author_display = own.author_display,
                .visibility_hidden = own.visibility_hidden orelse parent.visibility_hidden,
                .pointer_events_none = own.pointer_events_none orelse parent.pointer_events_none,
                .in_display_none = own.display == .none or own.outside_flat_tree or parent.in_display_none,
                .in_opacity_zero = own.opacity_zero or parent.in_opacity_zero,
            };
        }

        fn isHidden(self: Computed, options: CheckVisibilityOptions) bool {
            return self.in_display_none or
                (options.check_visibility and self.visibility_hidden) or
                (options.check_opacity and self.in_opacity_zero);
        }
    };

    // UA stylesheet display:none fallback (HTML Rendering §15.3.1 "Hidden
    // elements"). Applied only when no author rule for `display` matched the
    // element — per CSS Cascade §6.1 any normal-origin author rule beats UA
    // origin regardless of specificity, so `.x { display: flex }` on a
    // `<div class="x" hidden>` must report visible.
    pub fn finish(p: *Cascaded, el: *Element, frame: *Frame, priorities: *const Priorities(Declared)) void {
        p.outside_flat_tree = el.asNode().isOutsideFlatTree();
        p.author_display = priorities.get(.display) != 0;
        if (priorities.get(.box) == 0) {
            p.box = Box.uaDefault(el.getTag());
        }
        if (!p.author_display and matchesUaDisplayNoneRule(el, frame)) {
            p.display = .none;
        }
    }
};

/// An element's box: its size and how it scrolls.
const Geometry = struct {
    const Declared = struct {
        const names = [_][]const u8{ "overflow-x", "overflow-y", "overscroll-behavior-x", "overscroll-behavior-y", "width", "height", "min-width", "max-width", "flex", "flex-grow", "flex-shrink", "margin", "margin-inline", "margin-left", "margin-right", "margin-inline-start", "margin-inline-end", "inset", "inset-inline", "left", "right", "inset-inline-start", "inset-inline-end", "inset-block", "top", "bottom", "inset-block-start", "inset-block-end" };

        overflow_x_scrolls: ?bool = null,
        overflow_x_clips: ?bool = null,
        flex_grow: ?bool = null,
        flex_no_shrink: ?bool = null,
        overflow_y_scrolls: ?bool = null,
        overscroll_x_contains: ?bool = null,
        overscroll_y_contains: ?bool = null,
        width: ?Length = null,
        height: ?Length = null,
        min_width: ?Length = null,
        max_width: ?Length = null,
        margin_left: ?Length = null,
        margin_right: ?Length = null,
        left: ?Length = null,
        right: ?Length = null,
        top: ?Length = null,
        bottom: ?Length = null,

        fn apply(self: *Declared, id: properties.Id, value: []const u8) void {
            switch (id) {
                .@"overflow-x" => {
                    self.overflow_x_scrolls = overflowScrolls(value);
                    self.overflow_x_clips = overflowClips(value);
                },
                .@"flex-grow" => {
                    self.flex_grow = flexGrows(value);
                },
                .@"flex-shrink" => {
                    if (flexFactor(value)) |factor| {
                        self.flex_no_shrink = factor == 0;
                    }
                },
                .flex => {
                    self.flex_grow = flexShorthandGrows(value);
                    self.flex_no_shrink = flexShorthandNoShrink(value);
                },
                .margin => {
                    const sides = boxSides(value) orelse return;
                    self.margin_left = sides.left;
                    self.margin_right = sides.right;
                },
                .@"margin-inline" => {
                    const sides = inlineSides(value) orelse return;
                    self.margin_left = sides.left;
                    self.margin_right = sides.right;
                },
                .inset => {
                    const sides = boxSides(value) orelse return;
                    self.left = sides.left;
                    self.right = sides.right;
                    self.top = sides.top;
                    self.bottom = sides.bottom;
                },
                .@"inset-block" => {
                    const sides = inlineSides(value) orelse return;
                    self.top = sides.left;
                    self.bottom = sides.right;
                },
                .top, .@"inset-block-start" => {
                    self.top = Length.parseMargin(value);
                },
                .bottom, .@"inset-block-end" => {
                    self.bottom = Length.parseMargin(value);
                },
                .@"inset-inline" => {
                    const sides = inlineSides(value) orelse return;
                    self.left = sides.left;
                    self.right = sides.right;
                },
                .left, .@"inset-inline-start" => {
                    self.left = Length.parseMargin(value);
                },
                .right, .@"inset-inline-end" => {
                    self.right = Length.parseMargin(value);
                },
                .@"margin-left", .@"margin-inline-start" => {
                    self.margin_left = Length.parseMargin(value);
                },
                .@"margin-right", .@"margin-inline-end" => {
                    self.margin_right = Length.parseMargin(value);
                },
                .@"overflow-y" => {
                    self.overflow_y_scrolls = overflowScrolls(value);
                },
                .@"overscroll-behavior-x" => {
                    self.overscroll_x_contains = overscrollContains(value);
                },
                .@"overscroll-behavior-y" => {
                    self.overscroll_y_contains = overscrollContains(value);
                },
                .width => {
                    self.width = Length.parse(value);
                },
                .height => {
                    self.height = Length.parse(value);
                },
                .@"min-width" => {
                    self.min_width = Length.parse(value);
                },
                .@"max-width" => {
                    self.max_width = Length.parse(value);
                },
                else => {},
            }
        }

        // top and bottom only from boxSides
        const Sides = struct { left: Length, right: Length, top: Length = .{}, bottom: Length = .{} };

        // The sides of a `top [right [bottom [left]]]` shorthand (margin,
        // inset).
        fn boxSides(value: []const u8) ?Sides {
            var count: usize = 0;
            var tokens: [4][]const u8 = undefined;
            var it = std.mem.tokenizeAny(u8, value, &std.ascii.whitespace);
            while (it.next()) |token| : (count += 1) {
                if (count == tokens.len) {
                    return null;
                }
                tokens[count] = token;
            }
            if (count == 0) {
                return null;
            }
            const right = tokens[@min(count - 1, 1)];
            return .{
                .left = Length.parseMargin(if (count == 4) tokens[3] else right),
                .right = Length.parseMargin(right),
                .top = Length.parseMargin(tokens[0]),
                .bottom = Length.parseMargin(tokens[if (count >= 3) 2 else 0]),
            };
        }

        // `start [end]` (margin-inline, inset-inline), in a left-to-right flow
        fn inlineSides(value: []const u8) ?Sides {
            var it = std.mem.tokenizeAny(u8, value, &std.ascii.whitespace);
            const start = it.next() orelse return null;
            return .{
                .left = Length.parseMargin(start),
                .right = Length.parseMargin(it.next() orelse start),
            };
        }

        // `overlay` is Chrome's legacy alias of auto.
        fn overflowScrolls(value: []const u8) bool {
            return std.ascii.eqlIgnoreCase(value, "auto") or
                std.ascii.eqlIgnoreCase(value, "scroll") or
                std.ascii.eqlIgnoreCase(value, "overlay");
        }

        // Clipped or scrolled within the box: hidden, clip and the scrolling values.
        fn overflowClips(value: []const u8) bool {
            return overflowScrolls(value) or
                std.ascii.eqlIgnoreCase(value, "hidden") or
                std.ascii.eqlIgnoreCase(value, "clip");
        }

        fn flexGrows(value: []const u8) bool {
            const number = std.fmt.parseFloat(f64, std.mem.trim(u8, value, &std.ascii.whitespace)) catch return false;
            return number > 0;
        }

        // A non-negative <number>, null for anything else (a basis, a keyword)
        fn flexFactor(value: []const u8) ?f64 {
            const number = std.fmt.parseFloat(f64, std.mem.trim(u8, value, &std.ascii.whitespace)) catch return null;
            return if (number >= 0) number else null;
        }

        // `flex: <grow> [<shrink>] [<basis>]`; `auto` grows, `none` and
        // `initial` don't, and a lone width (`flex: 200px`) is a basis.
        fn flexShorthandGrows(value: []const u8) bool {
            var it = std.mem.tokenizeAny(u8, value, &std.ascii.whitespace);
            const first = it.next() orelse return false;
            if (std.ascii.eqlIgnoreCase(first, "auto")) return true;
            return flexGrows(first);
        }

        // Only `none` and an explicit 0 shrink factor stop the shrinking; an
        // omitted shrink is 1. The shrink is the number after the grow.
        fn flexShorthandNoShrink(value: []const u8) bool {
            var it = std.mem.tokenizeAny(u8, value, &std.ascii.whitespace);
            const first = it.next() orelse return false;
            if (std.ascii.eqlIgnoreCase(first, "none")) {
                return true;
            }
            if (flexFactor(first) == null) {
                return false;
            }
            const second = it.next() orelse return false;
            return flexFactor(second) == 0;
        }

        // `contain` keeps the scroll in the box, `none` also kills the bounce we
        // don't render anyway; only `auto` lets a scroll chain outward.
        fn overscrollContains(value: []const u8) bool {
            return std.ascii.eqlIgnoreCase(value, "contain") or
                std.ascii.eqlIgnoreCase(value, "none");
        }
    };

    // Presentational width and height attributes (HTML Rendering §15.3.10
    // "Tables"): author-level hints that any declaration beats.
    pub fn finish(p: *Computed, el: *Element, _: *Frame, priorities: *const Priorities(Declared)) void {
        const tag = el.getTag();
        // td and th ignore a zero height; table and tr don't
        const zero_height = switch (tag) {
            .table, .tr => true,
            .td, .th => false,
            else => return,
        };
        if (priorities.get(.width) == 0 and tag != .tr) {
            if (el.getAttributeSafe(comptime .wrap("width"))) |attr| {
                if (parseDimension(attr, false)) |length| {
                    p.width = length;
                }
            }
        }
        if (priorities.get(.height) == 0) {
            if (el.getAttributeSafe(comptime .wrap("height"))) |attr| {
                if (parseDimension(attr, zero_height)) |length| {
                    p.height = length;
                }
            }
        }
    }

    // HTML "rules for parsing dimension values": leading digits, then a `%`
    // for a percentage; anything after is ignored.
    fn parseDimension(text: []const u8, allow_zero: bool) ?Length {
        const trimmed = std.mem.trimStart(u8, text, &std.ascii.whitespace);
        var end: usize = 0;
        while (end < trimmed.len and std.ascii.isDigit(trimmed[end])) : (end += 1) {}
        if (end == 0) {
            return null;
        }
        if (end < trimmed.len and trimmed[end] == '.') {
            end += 1;
            while (end < trimmed.len and std.ascii.isDigit(trimmed[end])) : (end += 1) {}
        }
        const value = std.fmt.parseFloat(f32, std.mem.trimEnd(u8, trimmed[0..end], ".")) catch return null;
        if (value == 0 and allow_zero == false) {
            return null;
        }
        const percent = end < trimmed.len and trimmed[end] == '%';
        return .{ .value = value, .unit = if (percent) .percent else .px };
    }

    const Computed = packed struct(u357) {
        overflow_x_scrolls: bool = false,
        overflow_x_clips: bool = false,
        flex_grow: bool = false,
        flex_no_shrink: bool = false,
        overflow_y_scrolls: bool = false,
        overscroll_x_contains: bool = false,
        overscroll_y_contains: bool = false,
        width: Length = .{},
        height: Length = .{},
        // auto, none and the intrinsic keywords don't limit
        min_width: Length = .{},
        max_width: Length = .{},
        // auto, and values that need layout, are 0
        margin_left: Length = .{},
        margin_right: Length = .{},
        // Positioned boxes only; auto, and values that need layout, are auto
        left: Length = .{},
        right: Length = .{},
        top: Length = .{},
        bottom: Length = .{},
    };

    // Memory optimization. We usedto store each value as a
    //          const Length = struct{value: f32, unit: enum(u3)};
    // But that wastes a lot of memory. So now we store it like a specialized
    // struct of arrays ("specialized", because the unit is bit-packed into bits)
    const Stored = struct {
        values: [length_count]f32,
        // each length's unit, then the bools: apart so neither needs a u64,
        // which would pad the record
        units: u32,
        flags: u8,

        const names = @typeInfo(Computed).@"struct".field_names;
        const types = @typeInfo(Computed).@"struct".field_types;
        const length_count = std.mem.count(type, types, &.{Length});

        comptime {
            std.debug.assert(length_count * @bitSizeOf(Length.Unit) <= 32);
            std.debug.assert(names.len - length_count <= 8);
        }

        fn pack(computed: Computed) Stored {
            var stored: Stored = .{ .values = undefined, .units = 0, .flags = 0 };
            comptime var length = 0;
            comptime var flag = 0;
            inline for (names, types) |name, T| {
                const value = @field(computed, name);
                if (T == Length) {
                    stored.values[length] = value.value;
                    stored.units |= @as(u32, @backingInt(value.unit)) << (length * @bitSizeOf(Length.Unit));
                    length += 1;
                } else {
                    stored.flags |= @as(u8, @intFromBool(value)) << flag;
                    flag += 1;
                }
            }
            return stored;
        }

        fn unpack(self: Stored) Computed {
            var computed: Computed = .{};
            comptime var length = 0;
            comptime var flag = 0;
            inline for (names, types) |name, T| {
                if (T == Length) {
                    const unit: std.meta.Tag(Length.Unit) = @truncate(self.units >> (length * @bitSizeOf(Length.Unit)));
                    @field(computed, name) = .{ .value = self.values[length], .unit = @fromBackingInt(unit) };
                    length += 1;
                } else {
                    @field(computed, name) = (self.flags >> flag) & 1 == 1;
                    flag += 1;
                }
            }
            return computed;
        }
    };
};

/// The axes a touch may not pan along: touch-action, intersected with the
/// ancestors' (an ancestor's `none` stops the pan too).
const TouchAction = struct {
    const Declared = struct {
        const names = [_][]const u8{"touch-action"};

        pan_x_blocked: ?bool = null,
        pan_y_blocked: ?bool = null,

        fn apply(self: *Declared, id: properties.Id, value: []const u8) void {
            if (id != .@"touch-action") return;
            const pans = parse(value) orelse return;
            self.pan_x_blocked = !pans.x;
            self.pan_y_blocked = !pans.y;
        }

        // The axes a touch may pan along; null for an invalid value. The
        // directional keywords count for their whole axis.
        fn parse(value: []const u8) ?Element.ScrollAxes {
            if (std.ascii.eqlIgnoreCase(value, "auto") or std.ascii.eqlIgnoreCase(value, "manipulation")) {
                return .{ .x = true, .y = true };
            }
            if (std.ascii.eqlIgnoreCase(value, "none")) {
                return .{};
            }
            var pans: Element.ScrollAxes = .{};
            var it = std.mem.tokenizeAny(u8, value, &std.ascii.whitespace);
            while (it.next()) |token| {
                if (std.ascii.eqlIgnoreCase(token, "pan-x") or std.ascii.eqlIgnoreCase(token, "pan-left") or std.ascii.eqlIgnoreCase(token, "pan-right")) {
                    pans.x = true;
                } else if (std.ascii.eqlIgnoreCase(token, "pan-y") or std.ascii.eqlIgnoreCase(token, "pan-up") or std.ascii.eqlIgnoreCase(token, "pan-down")) {
                    pans.y = true;
                } else if (!std.ascii.eqlIgnoreCase(token, "pinch-zoom")) {
                    return null;
                }
            }
            return pans;
        }
    };

    pub const Cascaded = struct {
        pan_x_blocked: bool = false,
        pan_y_blocked: bool = false,
    };

    const Computed = packed struct(u2) {
        pan_x_blocked: bool = false,
        pan_y_blocked: bool = false,

        fn resolve(own: Cascaded, parent: Computed) Computed {
            return .{
                .pan_x_blocked = own.pan_x_blocked or parent.pan_x_blocked,
                .pan_y_blocked = own.pan_y_blocked or parent.pan_y_blocked,
            };
        }
    };
};

/// Inherited text properties. Each element stores only its own cascaded
/// value; `.inherit` means it takes its parent's.
const Text = struct {
    const Declared = struct {
        const names = [_][]const u8{ "text-transform", "white-space", "white-space-collapse", "text-wrap-mode", "text-wrap" };

        text_wrap_mode: ?WrapMode = null,
        text_transform: ?TextTransform = null,
        white_space_collapse: ?SpaceCollapse = null,

        fn apply(self: *Declared, id: properties.Id, value: []const u8) void {
            switch (id) {
                .@"text-transform" => {
                    self.text_transform = TextTransform.parse(value);
                },
                .@"white-space" => {
                    if (WhiteSpace.parse(value)) |white_space| {
                        self.white_space_collapse = white_space.collapse;
                        self.text_wrap_mode = white_space.wrap;
                    }
                },
                .@"white-space-collapse" => {
                    if (SpaceCollapse.parse(value)) |collapse| {
                        self.white_space_collapse = collapse;
                    }
                },
                .@"text-wrap-mode" => {
                    if (WrapMode.parse(value)) |mode| {
                        self.text_wrap_mode = mode;
                    }
                },
                .@"text-wrap" => {
                    if (WrapMode.parseTextWrap(value)) |mode| {
                        self.text_wrap_mode = mode;
                    }
                },
                else => {},
            }
        }
    };

    const Computed = packed struct(u8) {
        text_wrap_mode: WrapMode = .inherit,
        text_transform: TextTransform = .inherit,
        white_space_collapse: SpaceCollapse = .inherit,
    };

    pub fn finish(p: *Computed, el: *Element, _: *Frame, priorities: *const Priorities(Declared)) void {
        const ua = WhiteSpace.uaDefault(el.getTag()) orelse return;
        if (priorities.get(.white_space_collapse) == 0) {
            p.white_space_collapse = ua.collapse;
        }
        if (priorities.get(.text_wrap_mode) == 0) {
            p.text_wrap_mode = ua.wrap;
        }
    }
};

/// `inherit`, `unset` and `revert` are not handled, so they drop the
/// declaration. `initial` is the initial value, static.
pub const Position = enum(u3) {
    static,
    relative,
    absolute,
    fixed,
    sticky,

    // Null for an invalid value, which drops the declaration.
    fn parse(value: []const u8) ?Position {
        const trimmed = std.mem.trim(u8, value, &std.ascii.whitespace);
        if (std.ascii.eqlIgnoreCase(trimmed, "static") or std.ascii.eqlIgnoreCase(trimmed, "initial")) return .static;
        if (std.ascii.eqlIgnoreCase(trimmed, "relative")) return .relative;
        if (std.ascii.eqlIgnoreCase(trimmed, "absolute")) return .absolute;
        if (std.ascii.eqlIgnoreCase(trimmed, "fixed")) return .fixed;
        if (std.ascii.eqlIgnoreCase(trimmed, "sticky") or std.ascii.eqlIgnoreCase(trimmed, "-webkit-sticky")) return .sticky;
        return null;
    }

    /// Out of flow, so the box sizes to its content. Sticky is not: it lays
    /// out in flow and is only offset when painted.
    fn outOfFlow(self: Position) bool {
        return self == .absolute or self == .fixed;
    }

    /// The computed-value keyword, as getComputedStyle reports it.
    pub fn keyword(self: Position) []const u8 {
        return @tagName(self);
    }
};

/// Where a box sits: its position and whether it floats.
const Flow = struct {
    const Declared = struct {
        const names = [_][]const u8{ "position", "float" };

        position: ?Position = null,
        floated: ?bool = null,

        fn apply(self: *Declared, id: properties.Id, value: []const u8) void {
            switch (id) {
                .position => {
                    self.position = Position.parse(value);
                },
                .float => {
                    self.floated = std.ascii.eqlIgnoreCase(value, "left") or std.ascii.eqlIgnoreCase(value, "right") or
                        std.ascii.eqlIgnoreCase(value, "inline-start") or std.ascii.eqlIgnoreCase(value, "inline-end");
                },
                else => {},
            }
        }
    };

    pub const Cascaded = struct {
        position: Position = .static,
        floated: bool = false,
    };

    const Computed = packed struct(u5) {
        position: Position = .static,
        floated: bool = false,
        in_fixed: bool = false, // This element or an ancestor

        fn resolve(own: Cascaded, parent: Computed) Computed {
            return .{
                .position = own.position,
                .floated = own.floated,
                .in_fixed = own.position == .fixed or parent.in_fixed,
            };
        }
    };
};

/// Every group's share of one declaration block, so a sheet's block is folded
/// once. Field names match the StyleManager's group fields.
const Declarations = struct {
    const names = Visibility.Declared.names ++ Geometry.Declared.names ++ TouchAction.Declared.names ++ Text.Declared.names ++ Flow.Declared.names;

    visibility: Visibility.Declared = .{},
    geometry: Geometry.Declared = .{},
    touch_action: TouchAction.Declared = .{},
    text: Text.Declared = .{},
    flow: Flow.Declared = .{},

    fn apply(self: *Declarations, id: properties.Id, value: []const u8) void {
        inline for (group_fields) |field| {
            @field(self, field).apply(id, value);
        }
    }

    fn isRelevant(self: Declarations) bool {
        inline for (group_fields) |field| {
            if (declaresAny(@field(self, field))) {
                return true;
            }
        }
        return false;
    }
};

const group_fields = @typeInfo(Declarations).@"struct".field_names;

fn declaresAny(declared: anytype) bool {
    inline for (@typeInfo(@TypeOf(declared)).@"struct".field_names) |field| {
        if (@field(declared, field) != null) {
            return true;
        }
    }
    return false;
}

/// Per property, the priority of the declaration winning so far; 0 while
/// none has.
fn Priorities(comptime Declared: type) type {
    return std.enums.EnumArray(std.meta.FieldEnum(Declared), u64);
}

// lazy_rules map is property id -> LazyRules, loosely:
//    --color => [(:root, "#ff0"), (.card, "#000")]
// So when code says "getComputedStyle(el).getPropertyValue("--color")
// We end up with a relatively small number of rules. `content` is one more id.
const LazyRules = struct {
    rules: std.ArrayList(LazyRule) = .empty,
    parsed: ?[]const ParsedRule = null, // lazily parsed

    fn append(self: *LazyRules, arena: Allocator, selector_text: []const u8, value: []const u8, priority: u64) !void {
        // An appended rule joins rules that may already be parsed
        self.parsed = null;
        try self.rules.append(arena, .{
            .value = value,
            .priority = priority,
            .selector_text = selector_text,
        });
    }

    fn stampRules(self: *LazyRules, sm: *const StyleManager) void {
        for (self.rules.items) |*rule| {
            rule.priority |= sm.layerRank(rule.priority) << RANK_SHIFT;
        }
    }
};

const LazyRule = struct {
    selector_text: []const u8,
    value: []const u8,
    priority: u64,
};

/// Some frameworks define hundreds+ of custom properties, 99% of which are
/// never accessed via JS. So we don't parse them until something asks for it.
const ParsedRule = struct {
    selector: Selector.Selector,
    value: []const u8,
    priority: u64, // packed the same way as a group Rule.priority
};

/// A lazy declaration on its way from a rule block into lazy_rules.
const LazyDeclaration = struct {
    id: properties.Id,
    value: []const u8,
    important: bool,
};

/// The lazy declarations of one rule block.
const LazyDeclarations = struct {
    // Custom properties and `content`, one per id
    declared: []LazyDeclaration = &.{},
    animation: LazyAnimation = .{},

    fn isEmpty(self: LazyDeclarations) bool {
        return self.declared.len == 0 and self.animation.isEmpty();
    }

    fn declares(self: LazyDeclarations, id: properties.Id) bool {
        for (self.declared) |declaration| {
            if (declaration.id == id) {
                return true;
            }
        }
        return false;
    }

    // Unlike `content`, a custom property can change what a memo reads
    fn declaresCustom(self: LazyDeclarations) bool {
        for (self.declared) |declaration| {
            if (declaration.id != .content) {
                return true;
            }
        }
        return false;
    }

    fn dropContent(self: *LazyDeclarations) void {
        for (self.declared, 0..) |declaration, i| {
            if (declaration.id == .content) {
                // Each id goes to its own rules: the order doesn't matter
                self.declared[i] = self.declared[self.declared.len - 1];
                self.declared.len -= 1;
                return;
            }
        }
    }
};

/// A block's animation declarations, normal and !important ones apart. The
/// last of a property wins, and a shorthand drops the longhands before it.
const LazyAnimation = struct {
    normal: std.enums.EnumArray(Animation.Property, ?[]const u8) = .initFill(null),
    important: std.enums.EnumArray(Animation.Property, ?[]const u8) = .initFill(null),

    fn declare(self: *LazyAnimation, property: Animation.Property, value: []const u8, important: bool) void {
        const values = if (important) &self.important else &self.normal;
        if (property == .shorthand) {
            values.* = .initFill(null);
        }
        values.set(property, value);
    }

    fn isEmpty(self: *const LazyAnimation) bool {
        for (self.normal.values, self.important.values) |normal, important| {
            if (normal != null or important != null) {
                return false;
            }
        }
        return true;
    }
};

const Layer = struct {
    // dotted path from the root
    path: []const u8,

    // Number of path components
    depth: u16,

    // Index of the parent layer in `layers` (NO_LAYER for top level)
    parent: u16,

    /// Position in the final cascade order, lowest priority first.
    rank: u32 = 0,
};

/// This sentinel has two meanings. AS a rule's layer, it's the highest priority
/// (rules outside of a layer are highest priority). As a Layer.parent, it means
// no paren (top-level layer)
const NO_LAYER: u16 = std.math.maxInt(u16);

const UNLAYERED_RANK: u32 = std.math.maxInt(u11);

/// Protect against hostile input. Must be < UNLAYERED_RANK so that it fits in
// its 11 bits of VisibleRule.priority
const MAX_LAYERS: usize = 1024;

// Group Rule.priority field offsets (important:1 | layer_rank:11 | spec:30 | doc:22).
const SPEC_SHIFT: u6 = 22;
const RANK_SHIFT: u6 = 52;
const RANK_MASK: u64 = @as(u64, UNLAYERED_RANK) << RANK_SHIFT;
const IMPORTANT_BIT: u64 = 1 << 63;

// - 1 since the INLINE_* sentinels are _always_ higher
const MAX_DOC_ORDER: u32 = std.math.maxInt(u22) - 1;

const CheckVisibilityOptions = struct {
    check_visibility: bool = false,
    check_opacity: bool = false,
};

// Inline styles win over the stylesheets of the same importance, and the
// cascade goes: normal rules < normal inline < important rules < important
// inline. Each sentinel is the top of its tier: doc_order saturates one below
// its field max, so a real rule can never pack to all-ones.
const INLINE_PRIORITY: u64 = IMPORTANT_BIT - 1;
const INLINE_IMPORTANT_PRIORITY: u64 = std.math.maxInt(u64);

// `frame` must be el's owner frame (el.ownerFrame): that is the map where a
// parsed inline style lives. Without one the attribute text is folded in
// place; layout materializes the object itself when it needs it.
fn inlineDeclared(comptime Declared: type, el: *Element, frame: *Frame) Slots(Declared) {
    if (!el._flags.has_inline_style) {
        // Neither a style object nor a style attribute; skip both lookups.
        return .{};
    }
    if (el.existingStyle(frame)) |style| {
        return extractDeclared(Declared, style.asCSSStyleDeclaration().declarationBlock(), frame);
    }
    const attr = el.getAttributeInterned("style") orelse return .{};
    return foldDeclarations(Declared, CssParser.parseDeclarationsList(attr));
}

/// For the maps keyed by property id. Ids are small and dense, so a multiply
/// spreads them; the default hashes their bytes with Wyhash, which costs a
/// custom property about as much as hashing its name. The map takes the slot
/// from the low bits and the fingerprint from the top 7, so both need mixing.
const IdContext = struct {
    pub fn hash(_: IdContext, id: properties.Id) u64 {
        const h = @as(u64, @backingInt(id)) *% 0x9e3779b97f4a7c15;
        return h ^ (h >> 32);
    }

    pub fn eql(_: IdContext, a: properties.Id, b: properties.Id) bool {
        return a == b;
    }
};

/// Custom properties and `content`: kept as declared, and resolved only when
/// a script reads one.
fn isLazy(id: properties.Id) bool {
    return id == .content or properties.knownName(id) == null;
}

// Must agree with CSSStyleDeclaration.applyDeclarations, which is what the
// materialized object is built from: a normal declaration never overrides an
// earlier !important one, and an empty value removes the property. The tracked
// properties are matched case-insensitively.
fn foldDeclarations(comptime Declared: type, declarations: CssParser.DeclarationsIterator) Slots(Declared) {
    var slots: Slots(Declared) = .{};
    var it = declarations;
    while (it.next()) |declaration| {
        // Custom properties, `content` and the animation properties have no
        // slot: they're read from the parsed object.
        const id = trackedId(declaration.name) orelse continue;
        slots.apply(id, declaration.value, declaration.important);
    }
    return slots;
}

/// One block's winning value per property in `Declared.names`, folded in
/// declaration order.
fn Slots(comptime Declared: type) type {
    return struct {
        const Self = @This();

        slots: [Declared.names.len]Slot = @splat(.{}),

        const ids = blk: {
            var result: [Declared.names.len]properties.Id = undefined;
            for (Declared.names, &result) |name, *id| {
                id.* = @field(properties.Id, name);
            }
            break :blk result;
        };

        // Each known property's slot, or `untracked`.
        const untracked = std.math.maxInt(u8);
        const slot_of = blk: {
            std.debug.assert(Declared.names.len < untracked);
            var result: [properties.known_count]u8 = @splat(untracked);
            for (ids, 0..) |id, i| {
                // A name in two groups' lists would only reach the last
                std.debug.assert(result[@backingInt(id)] == untracked);
                result[@backingInt(id)] = i;
            }
            break :blk result;
        };

        fn apply(self: *Self, id: properties.Id, value: []const u8, important: bool) void {
            if (properties.axisShorthand(id)) |longhands| {
                const values = CssParser.splitAxisPair(value) orelse return;
                self.apply(longhands.x, values.x, important);
                self.apply(longhands.y, values.y, important);
                return;
            }
            const index = @backingInt(id);
            if (index >= slot_of.len) {
                // a custom property
                return;
            }
            const slot = slot_of[index];
            if (slot != untracked) {
                self.slots[slot].apply(value, important);
            }
        }

        fn props(self: *const Self, comptime importance: Importance) Declared {
            var p: Declared = .{};
            for (ids, self.slots) |id, s| {
                const value = s.value orelse continue;
                switch (importance) {
                    .any => {},
                    .normal => if (s.important) continue,
                    .important => if (s.important == false) continue,
                }
                p.apply(id, value);
            }
            return p;
        }
    };
}

const Importance = enum { any, normal, important };

/// This is an optimized version of properties.idOf. It's the same thing, except
/// limited to keys that the cascade reads. That sounds like a micro-optimization
/// right? But it actually shows up in profiling.
const tracked_ids = blk: {
    @setEvalBranchQuota(1_000_000);
    const Tracked = Slots(Declarations);
    var kvs: []const struct { []const u8, properties.Id } = &.{};
    for (0..properties.known_count) |i| {
        const id: properties.Id = @fromBackingInt(i);
        if (Tracked.slot_of[i] != Tracked.untracked or properties.axisShorthand(id) != null or id == .content or Animation.Property.fromId(id) != null) {
            kvs = kvs ++ .{.{ properties.knownName(id).?, id }};
        }
    }
    break :blk std.StaticStringMap(properties.Id).initComptime(kvs);
};

/// tracked_ids by id.
const tracked_bits = blk: {
    var result: std.StaticBitSet(properties.known_count) = .empty;
    for (tracked_ids.values()) |id| {
        result.set(@backingInt(id));
    }
    break :blk result;
};

/// Whether the cascade reads a rule's declaration of `id`: a tracked property,
/// a custom one, or a box shorthand with a tracked side. Writing one it doesn't
/// (transform, color...) changes no answer, so needs no rebuild.
pub fn readsDeclaration(id: properties.Id) bool {
    const index = @backingInt(id);
    if (index >= properties.known_count) {
        // a custom property
        return true;
    }
    if (properties.boxShorthand(id)) |shorthand| {
        // writing it writes its sides
        for (shorthand.sides) |side| {
            if (tracked_bits.isSet(@backingInt(side))) {
                return true;
            }
        }
    }
    return tracked_bits.isSet(index);
}

/// Whether the cascade took anything from a rule, so removing it changes
/// answers (and frees a selector the buckets hold).
pub fn readsRule(entry: *const RuleStore.Entry) bool {
    if (entry._kind != .style or entry._children != null) {
        return true;
    }
    for (entry._block.entries()) |declaration| {
        if (readsDeclaration(declaration._id)) {
            return true;
        }
    }
    return false;
}

/// The id of a property the cascade reads, by its name in any case, or null.
fn trackedId(name: []const u8) ?properties.Id {
    var buf: [tracked_ids.max_len]u8 = undefined;
    if (name.len > buf.len) {
        return null;
    }
    return tracked_ids.get(std.ascii.lowerString(&buf, name));
}

const Slot = struct {
    value: ?[]const u8 = null,
    important: bool = false,

    fn apply(self: *Slot, value: []const u8, important: bool) void {
        if (self.important and !important) {
            return;
        }
        if (value.len == 0) {
            self.* = .{};
            return;
        }
        self.value = value;
        self.important = important;
    }
};

/// Resolved value of an element's inline `style=` declaration of `id`,
/// or null when the element has no such declaration. Reads the element's parsed
/// inline style (the same source `el.style` exposes), so `getComputedStyle` and
/// `el.style` agree on inline values instead of resolving them independently.
/// Null too when a tracked property's normal declaration loses to an
/// !important stylesheet rule.
pub fn inlineStyleValue(self: *StyleManager, el: *Element, id: properties.Id) ?[]const u8 {
    self.assertOwns(el);
    const style = el.inlineStyle(self.frame) orelse return null;
    const declaration = style.asCSSStyleDeclaration();
    const value = declaration.declaredValue(id, self.frame) orelse return null;
    if (declaration.declaredImportant(id) == false and self.importantRuleWins(el, id, value)) {
        return null;
    }
    return value;
}

// Folds the one declaration the way the inline style is folded for layout, so
// a shorthand checks its longhands and a value we don't parse checks nothing.
fn importantRuleWins(self: *StyleManager, el: *Element, id: properties.Id, value: []const u8) bool {
    self.rebuildIfDirty() catch return false;
    var slots: Slots(Declarations) = .{};
    slots.apply(id, value, false);
    const declared = slots.props(.any);
    inline for (group_fields) |field| {
        if (@field(self, field).importantRuleWins(@field(declared, field), el, self.frame)) {
            return true;
        }
    }
    return false;
}

/// The id of custom property `name` as `el` can see it, null when nothing
/// declares it for `el`: no rule, and no style attribute on its flat-tree
/// ancestors. Unlike numbering it, a miss leaves the page's names as they are.
pub fn customPropertyId(self: *StyleManager, el: *Element, name: []const u8) ?properties.Id {
    self.assertOwns(el);
    self.rebuildIfDirty() catch return null;

    // The rebuild numbered every sheet's custom names
    const custom_names = &self.frame.page.css_custom_names;
    if (custom_names.lookup(name)) |id| {
        return id;
    }

    // A style attribute's are numbered once it's parsed
    var current: ?*Element = el;
    while (current) |elem| : (current = elem.asNode().flatTreeParentElement(self.frame)) {
        if (elem.inlineStyle(self.frame) == null) {
            continue;
        }
        if (custom_names.lookup(name)) |id| {
            return id;
        }
    }
    return null;
}

/// Computed value of custom property `id` on `el`, or null when nothing
/// declares it. The value is returned as-is, no var substitution
pub fn customPropertyValue(self: *StyleManager, el: *Element, id: properties.Id) ?[]const u8 {
    self.assertOwns(el);
    self.rebuildIfDirty() catch return null;

    // Only the rules declaring this name; usually a handful, often none. An
    // element can still shadow them with an inline declaration, so a miss here
    // means walking for inline styles, not returning early.
    const rules = self.parsedRules(self.lazy_rules.getPtr(id)) catch |err| blk: {
        log.err(.browser, "StyleManager customProperty", .{ .err = err });
        break :blk &.{};
    };

    var current: ?*Element = el;
    while (current) |elem| : (current = elem.asNode().flatTreeParentElement(self.frame)) {
        if (self.lazyWinner(elem, id, rules, null)) |winner| {
            return winner.value;
        }
    }
    return null;
}

/// Declared `content` of `el`, or null when nothing declares it. It doesn't
/// inherit, so only `el`'s own declarations count.
pub fn contentValue(self: *StyleManager, el: *Element) ?[]const u8 {
    self.assertOwns(el);
    self.rebuildIfDirty() catch return null;

    const rules = self.parsedRules(self.lazy_rules.getPtr(.content)) catch |err| blk: {
        log.err(.browser, "StyleManager content", .{ .err = err });
        break :blk &.{};
    };
    var before: ?u16 = null;
    while (self.lazyWinner(el, .content, rules, before)) |winner| {
        if (std.ascii.eqlIgnoreCase(winner.value, "revert-layer") == false) {
            return winner.value;
        }
        // Back to the layers before the winner's. Chrome and Firefox drop the
        // later layers' declarations too, even under an important one.
        before = winner.layer;
    }
    return null;
}

/// The animation longhands `el` ends up with. One rule can set the name and
/// another the duration, so each longhand takes its own winner, the shorthand's
/// or its own declaration's.
pub fn animation(self: *StyleManager, el: *Element) Animation {
    self.assertOwns(el);
    self.rebuildIfDirty() catch return .{};

    // The style attribute, folded like a rule block: in order, the -webkit-
    // names aliased, and a shorthand dropping the longhands before it.
    var inline_declared: LazyAnimation = .{};
    if (el.inlineStyle(self.frame)) |style| {
        var it = style.asCSSStyleDeclaration().declarationBlock().iterator(&self.frame.page.css_custom_names);
        while (it.next()) |declaration| {
            const animation_property = Animation.Property.fromId(declaration.id) orelse continue;
            const value = declaration.value;
            if (std.ascii.eqlIgnoreCase(value, "revert-layer")) {
                // Back to the rules, every one of them in an earlier layer
                continue;
            }
            inline_declared.declare(animation_property, value, declaration.important);
        }
    }

    var result: Animation = .{};
    const shorthand = self.animationWinner(el, .shorthand, &inline_declared);
    for (std.enums.values(Animation.Longhand)) |longhand| {
        const own = self.animationWinner(el, switch (longhand) {
            .name => .name,
            .duration => .duration,
            .delay => .delay,
            .iteration_count => .iteration_count,
        }, &inline_declared);
        // Equal priorities are one block, where the longhand came last: a
        // shorthand after it dropped it.
        if (own) |winner| {
            if (shorthand == null or winner.priority >= shorthand.?.priority) {
                result.sources.set(longhand, .{ .list = winner.value });
                continue;
            }
        }
        if (shorthand) |winner| {
            result.sources.set(longhand, .{ .shorthand = winner.value });
        }
    }
    return result;
}

/// `inline_declared` is `el`'s style attribute: lazyWinner reads it by the
/// standard name alone, missing the -webkit- names and the shorthand's order.
fn animationWinner(self: *StyleManager, el: *Element, property: Animation.Property, inline_declared: *const LazyAnimation) ?LazyWinner {
    // Nothing beats an !important inline declaration
    if (inline_declared.important.get(property)) |value| {
        return .{ .value = value, .layer = INLINE_LAYER, .priority = INLINE_IMPORTANT_PRIORITY };
    }

    const rules = self.parsedRules(self.animation_rules.getPtr(property)) catch |err| blk: {
        log.err(.browser, "StyleManager animation", .{ .err = err });
        break :blk &.{};
    };
    var winner: ?LazyWinner = null;
    // Stopping at INLINE_LAYER keeps lazyWinner off the style attribute
    var before: ?u16 = INLINE_LAYER;
    while (self.lazyWinner(el, property.standardId(), rules, before)) |candidate| {
        if (std.ascii.eqlIgnoreCase(candidate.value, "revert-layer") == false) {
            winner = candidate;
            break;
        }
        before = candidate.layer;
    }

    // A normal inline declaration beats every normal rule
    if (inline_declared.normal.get(property)) |value| {
        if (winner == null or winner.?.priority < INLINE_PRIORITY) {
            return .{ .value = value, .layer = INLINE_LAYER, .priority = INLINE_PRIORITY };
        }
    }
    return winner;
}

/// Only frame/css_animations.zig reads the animation rules and @keyframes,
/// and only with the experimental feature on: without it, they aren't kept.
/// The feature is set per session, so a page's rules never miss a change.
fn animationsEnabled(self: *const StyleManager) bool {
    return self.frame._session.experimental_features.animation;
}

fn animationRuleCount(self: *const StyleManager) usize {
    var n: usize = 0;
    for (self.animation_rules.values) |rules| {
        n += rules.rules.items.len;
    }
    return n;
}

/// Whether a @keyframes rule has `name`.
pub fn hasKeyframes(self: *StyleManager, name: []const u8) bool {
    if (self.rebuildForKeyframes() == false) {
        return false;
    }
    return self.keyframes.contains(name);
}

pub fn hasAnyKeyframes(self: *StyleManager) bool {
    if (self.rebuildForKeyframes() == false) {
        return false;
    }
    return self.keyframes.count() > 0;
}

/// False when no sheet can hold keyframes. The animation check asks on every
/// page: one without keyframes would pay a rebuild nothing else may need.
fn rebuildForKeyframes(self: *StyleManager) bool {
    if (self.dirty and !self.sheetsMentionKeyframes()) {
        return false;
    }
    self.rebuildIfDirty() catch return false;
    return true;
}

/// The sheets `parseSheet` reads, searched as text.
fn sheetsMentionKeyframes(self: *StyleManager) bool {
    if (self.keyframes_mentioned) |mentioned| {
        return mentioned;
    }
    const mentioned = self.searchSheetsForKeyframes() catch true;
    self.keyframes_mentioned = mentioned;
    return mentioned;
}

fn searchSheetsForKeyframes(self: *StyleManager) !bool {
    const sheets = self.frame.document._style_sheets orelse return false;
    for (sheets._sheets.items) |sheet| {
        if (sheet._disabled) {
            continue;
        }
        try sheet.ensureParsed(self.frame);
        if (storeMentionsKeyframes(&sheet._store)) {
            return true;
        }
    }
    return false;
}

fn storeMentionsKeyframes(store: *const RuleStore) bool {
    for (store.entries()) |*entry| {
        if (entry._kind != .style and std.ascii.findIgnoreCase(entry.text(), "keyframes") != null) {
            return true;
        }
        // A grouping rule's text is only its prelude
        if (entry._children) |children| {
            if (storeMentionsKeyframes(children)) {
                return true;
            }
        }
    }
    return false;
}

const LazyWinner = struct {
    value: []const u8,
    // Where it is in the layer order; see layerOrder.
    layer: u16,
    priority: u64,
};

/// The style attribute cascades after every layer, unlayered rules included.
const INLINE_LAYER: u16 = UNLAYERED_RANK + 1;

/// The layer a packed priority's rule is in: its rank, which an important
/// declaration packs reversed.
fn layerOrder(priority: u64) u16 {
    const rank: u16 = @intCast((priority & RANK_MASK) >> RANK_SHIFT);
    if (priority & IMPORTANT_BIT != 0) {
        return @intCast(UNLAYERED_RANK - rank);
    }
    return rank;
}

/// The declaration of a lazy property that wins on `el`, from the matching
/// rules and its inline style. With `before`, only those from earlier layers.
fn lazyWinner(self: *StyleManager, el: *Element, id: properties.Id, rules: []const ParsedRule, before: ?u16) ?LazyWinner {
    const limit = before orelse std.math.maxInt(u16);

    var winner: ?LazyWinner = null;
    var priority: u64 = 0;
    for (rules) |rule| {
        if (rule.priority <= priority) {
            continue;
        }
        const layer = layerOrder(rule.priority);
        if (layer >= limit) {
            continue;
        }
        if (matchesSelector(el, rule.selector, self.frame) == false) {
            continue;
        }
        winner = .{ .value = rule.value, .layer = layer, .priority = rule.priority };
        priority = rule.priority;
    }

    if (limit > INLINE_LAYER) {
        if (el.inlineStyle(self.frame)) |style| {
            const declaration = style.asCSSStyleDeclaration();
            if (declaration.storedDeclaration(id)) |declared| {
                const inline_priority = if (declared.important) INLINE_IMPORTANT_PRIORITY else INLINE_PRIORITY;
                if (inline_priority > priority) {
                    winner = .{ .value = declared.value, .layer = INLINE_LAYER, .priority = inline_priority };
                }
            }
        }
    }
    return winner;
}

/// Gets the parsed rules of a lazy property; `maybe_property` is null when
/// nothing declares it
fn parsedRules(self: *StyleManager, maybe_property: ?*LazyRules) ![]const ParsedRule {
    const property = maybe_property orelse return &.{};
    if (property.parsed) |parsed| {
        // the property exists, and we already parsed it.
        return parsed;
    }

    const arena = self.arena.allocator();
    var parsed: std.ArrayList(ParsedRule) = .empty;

    for (property.rules.items) |rule| {
        const selectors = SelectorParser.parseList(arena, rule.selector_text) catch continue;
        for (selectors) |selector| {
            {
                // we don't use buckets for custom properties (are property name
                // lookup is more efficient), but we still want to skip dynamic
                // pseudo-classes just like visibility does
                _ = getBucketKey(selector.rightmost()) orelse continue;
            }

            try parsed.append(arena, .{
                .selector = selector,
                .value = rule.value,
                .priority = rule.priority | (@as(u64, computeSpecificity(selector)) << SPEC_SHIFT),
            });
        }
    }

    property.parsed = parsed.items;
    return parsed.items;
}

/// Bounds computedFontSize's ancestor recursion (the parent walk and
/// `inherit`/relative-unit chains share it).
const MAX_FONT_ANCESTOR_DEPTH = 32;

/// The font-size an element inherits when nothing declares one and when an
/// element is part of a frameless document.
pub const DEFAULT_FONT_SIZE = 16;

/// Computed font-size in CSS pixels. We do what we can, namely inline styles
/// font-related attributes, up the parent chain.
pub fn computedFontSize(self: *StyleManager, element: ?*Element) f64 {
    self.assertOwns(element);
    return self.computedFontSizeAt(element, 0);
}

fn computedFontSizeAt(self: *StyleManager, element: ?*Element, depth: u8) f64 {
    if (depth >= MAX_FONT_ANCESTOR_DEPTH) {
        return DEFAULT_FONT_SIZE;
    }
    const current = element orelse return DEFAULT_FONT_SIZE;
    const parent = current.asNode().flatTreeParentElement(self.frame);

    if (self.inlineStyleValue(current, .@"font-size")) |raw| {
        if (self.parseFontSize(raw, parent, depth + 1)) |size| {
            return size;
        }
    }
    if (current.getAttributeSafe(comptime .wrap("font-size"))) |raw| {
        if (self.parseFontSize(raw, parent, depth + 1)) |size| {
            return size;
        }
    }
    return self.computedFontSizeAt(parent, depth + 1);
}

/// `inherit`, or `unset` on an inherited property.
fn inheritsKeyword(value: []const u8) bool {
    return std.ascii.eqlIgnoreCase(value, "inherit") or std.ascii.eqlIgnoreCase(value, "unset");
}

/// An inherited boolean property's declared value: inner null for an explicit
/// inherit, outer null for an invalid value, which the cascade drops. No UA
/// style sets these properties, so revert also rolls back to inheriting.
fn parseInheritedFlag(value: []const u8, comptime on: []const []const u8, comptime off: []const []const u8) ??bool {
    if (inheritsKeyword(value) or std.ascii.eqlIgnoreCase(value, "revert") or std.ascii.eqlIgnoreCase(value, "revert-layer")) {
        return @as(?bool, null);
    }
    inline for (on) |keyword| {
        if (std.ascii.eqlIgnoreCase(value, keyword)) return true;
    }
    inline for (off) |keyword| {
        if (std.ascii.eqlIgnoreCase(value, keyword)) return false;
    }
    return null;
}

// Absolute-size keywords, in pixels as Chrome maps them.
const font_size_keywords = std.StaticStringMapWithEql(f64, std.static_string_map.eqlAsciiIgnoreCase).initComptime(.{
    .{ "xx-small", 9 },
    .{ "x-small", 10 },
    .{ "small", 13 },
    .{ "medium", 16 },
    .{ "large", 18 },
    .{ "x-large", 24 },
    .{ "xx-large", 32 },
    .{ "xxx-large", 48 },
});

fn parseFontSize(self: *StyleManager, raw: []const u8, parent: ?*Element, depth: u8) ?f64 {
    const value = std.mem.trim(u8, raw, " \t\r\n\x0c");
    if (inheritsKeyword(value)) {
        return self.computedFontSizeAt(parent, depth);
    }
    if (std.ascii.eqlIgnoreCase(value, "initial")) {
        return DEFAULT_FONT_SIZE;
    }
    if (font_size_keywords.get(value)) |size| {
        return size;
    }
    if (std.ascii.eqlIgnoreCase(value, "smaller")) {
        return self.computedFontSizeAt(parent, depth) / 1.2;
    }
    if (std.ascii.eqlIgnoreCase(value, "larger")) {
        return self.computedFontSizeAt(parent, depth) * 1.2;
    }

    const parsed = units.parse(value) catch return null;
    const factor = units.absoluteLengthFactor(parsed.unit) orelse switch (parsed.unit) {
        .percentage => self.computedFontSizeAt(parent, depth) / 100.0,
        .em => self.computedFontSizeAt(parent, depth),
        .ex => self.computedFontSizeAt(parent, depth) / 2.0,
        // The root's own `rem` resolves against the initial size.
        .rem => if (parent == null) DEFAULT_FONT_SIZE else self.computedFontSizeAt(self.frame.document.getDocumentElement(), depth),
        else => return null,
    };
    const size = parsed.value * factor;
    return if (size >= 0 and std.math.isFinite(size)) size else null;
}

const testing = @import("../testing.zig");

test "StyleManager: important cascade across external sheets, inline styles and layers" {
    try testing.htmlRunner("css/important_cascade.html", .{ .load_resources = .{ .stylesheet = true } });
}

test "StyleManager: custom properties" {
    try testing.htmlRunner("css/custom_properties.html", .{});
}

test "StyleManager: text-transform" {
    try testing.htmlRunner("css/text_transform.html", .{});
}

test "StyleManager: stylesheet :scope is the root element" {
    try testing.htmlRunner("css/scope_pseudo.html", .{});
}

test "StyleManager: position" {
    try testing.htmlRunner("css/position.html", .{});
}

test "StyleManager: inline style writes" {
    try testing.htmlRunner("css/inline_style_writes.html", .{});
}

test "StyleManager: animation events" {
    try testing.htmlRunner("css/animation_events.html", .{ .experimental_features = .{ .animation = true } });
}

test "StyleManager: hasKeyframes rebuilds only when a sheet mentions keyframes" {
    testing.test_session.experimental_features.animation = true;
    defer testing.test_session.experimental_features = .{};
    const frame = try testing.createFrame();
    defer testing.test_session.closeAllPages();
    const sm = &frame._style_manager;

    const doc = frame.document;
    const html = (try doc.createElement("html", null, frame)).asNode();
    _ = try doc.asNode().appendChild(html, frame);
    const body = (try doc.createElement("body", null, frame)).asNode();
    _ = try html.appendChild(body, frame);

    const style_el = (try doc.createElement("style", null, frame)).as(Element.Html.Style);
    try style_el.asNode().setTextContent(".a { color: red }", frame);
    _ = try body.appendChild(style_el.asNode(), frame);
    try testing.expectEqual(true, sm.dirty);
    try testing.expectEqual(false, sm.hasAnyKeyframes());
    try testing.expectEqual(true, sm.dirty);

    try style_el.asNode().setTextContent("@keyframes fade { to { opacity: 0 } }", frame);
    try testing.expectEqual(true, sm.hasKeyframes("fade"));
    try testing.expectEqual(false, sm.dirty);

    const sheet = style_el._sheet orelse return error.NoSheet;
    _ = try sheet.insertRule("@-webkit-keyframes spin { to { opacity: 1 } }", 0, frame);
    try testing.expectEqual(true, sm.dirty);
    try testing.expectEqual(true, sm.hasKeyframes("spin"));
}

test "StyleManager: text-transform without rules skips the memo" {
    const frame = try testing.createFrame();
    defer testing.test_session.closeAllPages();
    const sm = &frame._style_manager;

    const div = try frame.window._document.createElement("div", null, frame);
    try Frame.parse.htmlAsChildren(frame, div.asNode(),
        \\<p style="text-transform: uppercase"><b><i></i></b></p>
    );
    const p = div.asNode().firstChild().?.as(Element);
    const b = p.asNode().firstChild().?.as(Element);
    const i = b.asNode().firstChild().?.as(Element);

    // Inherited from the inline declaration; only <p> needs the cascade.
    try testing.expectEqual(TextTransform.uppercase, sm.textTransform(i));
    try testing.expectEqual(1, sm.text.memo.count());
    try testing.expectEqual(TextTransform.none, sm.textTransform(div));
}

test "StyleManager: computeSpecificity: element selector" {
    // div -> (0, 0, 1)
    const selector = Selector.Selector{
        .first = .{ .parts = &.{.{ .tag = .div }} },
        .segments = &.{},
    };
    try testing.expectEqual(1, computeSpecificity(selector));
}

test "StyleManager: computeSpecificity: class selector" {
    // .foo -> (0, 1, 0)
    const selector = Selector.Selector{
        .first = .{ .parts = &.{.{ .class = "foo" }} },
        .segments = &.{},
    };
    try testing.expectEqual(1 << 10, computeSpecificity(selector));
}

test "StyleManager: computeSpecificity: id selector" {
    // #bar -> (1, 0, 0)
    const selector = Selector.Selector{
        .first = .{ .parts = &.{.{ .id = "bar" }} },
        .segments = &.{},
    };
    try testing.expectEqual(1 << 20, computeSpecificity(selector));
}

test "StyleManager: computeSpecificity: combined selector" {
    // div.foo#bar -> (1, 1, 1)
    const selector = Selector.Selector{
        .first = .{ .parts = &.{
            .{ .tag = .div },
            .{ .class = "foo" },
            .{ .id = "bar" },
        } },
        .segments = &.{},
    };
    try testing.expectEqual((1 << 20) | (1 << 10) | 1, computeSpecificity(selector));
}

test "StyleManager: computeSpecificity: universal selector" {
    // * -> (0, 0, 0)
    const selector = Selector.Selector{
        .first = .{ .parts = &.{.universal} },
        .segments = &.{},
    };
    try testing.expectEqual(0, computeSpecificity(selector));
}

test "StyleManager: computeSpecificity: multiple classes" {
    // .a.b.c -> (0, 3, 0)
    const selector = Selector.Selector{
        .first = .{ .parts = &.{
            .{ .class = "a" },
            .{ .class = "b" },
            .{ .class = "c" },
        } },
        .segments = &.{},
    };
    try testing.expectEqual(3 << 10, computeSpecificity(selector));
}

test "StyleManager: computeSpecificity: descendant combinator" {
    // div span -> (0, 0, 2)
    const selector = Selector.Selector{
        .first = .{ .parts = &.{.{ .tag = .div }} },
        .segments = &.{
            .{ .combinator = .descendant, .compound = .{ .parts = &.{.{ .tag = .span }} } },
        },
    };
    try testing.expectEqual(2, computeSpecificity(selector));
}

test "StyleManager: computeSpecificity: :where() has zero specificity" {
    // :where(.foo) -> (0, 0, 0) regardless of what's inside
    const inner_selector = Selector.Selector{
        .first = .{ .parts = &.{.{ .class = "foo" }} },
        .segments = &.{},
    };
    const selector = Selector.Selector{
        .first = .{ .parts = &.{
            .{ .pseudo_class = .{ .where = &.{inner_selector} } },
        } },
        .segments = &.{},
    };
    try testing.expectEqual(0, computeSpecificity(selector));
}

test "StyleManager: computeSpecificity: :not() takes inner specificity" {
    // :not(.foo) -> (0, 1, 0) - takes specificity of .foo
    const inner_selector = Selector.Selector{
        .first = .{ .parts = &.{.{ .class = "foo" }} },
        .segments = &.{},
    };
    const selector = Selector.Selector{
        .first = .{ .parts = &.{
            .{ .pseudo_class = .{ .not = &.{inner_selector} } },
        } },
        .segments = &.{},
    };
    try testing.expectEqual(1 << 10, computeSpecificity(selector));
}

test "StyleManager: computeSpecificity: :is() takes most specific inner" {
    // :is(.foo, #bar) -> (1, 0, 0) - takes the most specific (#bar)
    const class_selector = Selector.Selector{
        .first = .{ .parts = &.{.{ .class = "foo" }} },
        .segments = &.{},
    };
    const id_selector = Selector.Selector{
        .first = .{ .parts = &.{.{ .id = "bar" }} },
        .segments = &.{},
    };
    const selector = Selector.Selector{
        .first = .{ .parts = &.{
            .{ .pseudo_class = .{ .is = &.{ class_selector, id_selector } } },
        } },
        .segments = &.{},
    };
    try testing.expectEqual(1 << 20, computeSpecificity(selector));
}

test "StyleManager: computeSpecificity: never-matching attribute keeps attribute weight" {
    // :is([a^=""], div) -> (0, 1, 0): :is() takes its most specific argument,
    // matching or not
    const never_selector = Selector.Selector{
        .first = .{ .parts = &.{.never} },
        .segments = &.{},
    };
    const tag_selector = Selector.Selector{
        .first = .{ .parts = &.{.{ .tag = .div }} },
        .segments = &.{},
    };
    const selector = Selector.Selector{
        .first = .{ .parts = &.{
            .{ .pseudo_class = .{ .is = &.{ never_selector, tag_selector } } },
        } },
        .segments = &.{},
    };
    try testing.expectEqual(1 << 10, computeSpecificity(selector));
}

test "StyleManager: computeSpecificity: pseudo-class (general)" {
    // :hover -> (0, 1, 0) - pseudo-classes count as class-level
    const selector = Selector.Selector{
        .first = .{ .parts = &.{
            .{ .pseudo_class = .hover },
        } },
        .segments = &.{},
    };
    try testing.expectEqual(1 << 10, computeSpecificity(selector));
}

test "StyleManager: document order tie-breaking" {
    // When specificity is equal, higher doc_order (later in document) wins
    const beats = struct {
        fn f(spec: u32, doc_order: u32, best_spec: u32, best_doc_order: u32) bool {
            return spec > best_spec or (spec == best_spec and doc_order > best_doc_order);
        }
    }.f;

    // Higher specificity always wins regardless of doc_order
    try testing.expect(beats(2, 0, 1, 10));
    try testing.expect(!beats(1, 10, 2, 0));

    // Equal specificity: higher doc_order wins
    try testing.expect(beats(1, 5, 1, 3)); // doc_order 5 > 3
    try testing.expect(!beats(1, 3, 1, 5)); // doc_order 3 < 5

    // Equal specificity and doc_order: no win
    try testing.expect(!beats(1, 5, 1, 5));
}

test "StyleManager: packed priority bounds" {
    // The four fields fill the u64 exactly, without overlap.
    try testing.expectEqual(IMPORTANT_BIT, @as(u64, 1) << (RANK_SHIFT + 11));
    try testing.expectEqual(RANK_SHIFT, @as(u32, SPEC_SHIFT) + 30);

    // The maximum packable rule priority (unlayered rank, fully-clamped
    // specificity, saturated doc_order) stays below its tier's inline sentinel,
    // and every important rule above INLINE_PRIORITY.
    const max_packed = (@as(u64, UNLAYERED_RANK) << RANK_SHIFT) |
        (@as(u64, std.math.maxInt(u30)) << SPEC_SHIFT) |
        MAX_DOC_ORDER;
    try testing.expect(max_packed < INLINE_PRIORITY);
    try testing.expect(IMPORTANT_BIT > INLINE_PRIORITY);
    try testing.expect((IMPORTANT_BIT | max_packed) < INLINE_IMPORTANT_PRIORITY);

    // Real layer ranks fit the 11 rank bits below the unlayered sentinel.
    try testing.expect(MAX_LAYERS < UNLAYERED_RANK);
}

test "StyleManager: inlineDeclared: scan matches the parsed style object" {
    const frame = try testing.createFrame();
    defer testing.test_session.closeAllPages();

    const div = try frame.window._document.createElement("div", null, frame);
    try Frame.parse.htmlAsChildren(frame, div.asNode(),
        \\<i style="display:none"></i>
        \\<i style="color:red; DISPLAY : none !important ; display:block"></i>
        \\<i style="display:block;display:none"></i>
        \\<i style="display: none; display: /* c */ block"></i>
        \\<i style="visibility:hidden !important; display:none; visibility:visible"></i>
        \\<i style="opacity: 0; pointer-events: none"></i>
        \\<i style="pointer-events: none !important; pointer-events: auto; opacity: 1"></i>
        \\<i style="visibility:hidden"></i>
        \\<i style="display:"></i>
        \\<i></i>
        \\<i style="overflow: auto"></i>
        \\<i style="overflow: hidden scroll"></i>
        \\<i style="overflow: hidden; overflow-y: auto"></i>
        \\<i style="overflow-y: auto; overflow: hidden"></i>
        \\<i style="overflow-y: auto !important; overflow: hidden"></i>
        \\<i style="overflow-x: overlay"></i>
        \\<i style="overflow:"></i>
        \\<i style="width: 100px; height: 1in"></i>
        \\<i style="height: 10vh; height: auto"></i>
        \\<i style="width: 50%; height: -5px"></i>
        \\<i style="width: 2em !important; width: 10vw"></i>
        \\<i style="display: flex"></i>
        \\<i style="display: inline-grid"></i>
        \\<i style="width: max-content; position: absolute; float: left"></i>
        \\<i style="width: fit-content(10px); position: relative; float: none"></i>
    );
    const expected = [_]Declarations{
        .{ .visibility = .{ .display = .none } },
        .{ .visibility = .{ .display = .none } },
        .{ .visibility = .{ .display = .none } },
        .{ .visibility = .{ .display = .other, .box = .block_level } },
        .{ .visibility = .{ .display = .none, .visibility_hidden = true } },
        .{ .visibility = .{ .opacity_zero = true, .pointer_events_none = true } },
        .{ .visibility = .{ .opacity_zero = false, .pointer_events_none = true } },
        .{ .visibility = .{ .visibility_hidden = true } },
        .{},
        .{},
        .{ .geometry = .{ .overflow_x_scrolls = true, .overflow_x_clips = true, .overflow_y_scrolls = true } },
        .{ .geometry = .{ .overflow_x_scrolls = false, .overflow_x_clips = true, .overflow_y_scrolls = true } },
        .{ .geometry = .{ .overflow_x_scrolls = false, .overflow_x_clips = true, .overflow_y_scrolls = true } },
        .{ .geometry = .{ .overflow_x_scrolls = false, .overflow_x_clips = true, .overflow_y_scrolls = false } },
        .{ .geometry = .{ .overflow_x_scrolls = false, .overflow_x_clips = true, .overflow_y_scrolls = true } },
        .{ .geometry = .{ .overflow_x_scrolls = true, .overflow_x_clips = true } },
        .{},
        .{ .geometry = .{ .width = .{ .value = 100, .unit = .px }, .height = .{ .value = 96, .unit = .px } } },
        .{ .geometry = .{ .height = .{} } },
        .{ .geometry = .{ .width = .{ .value = 50, .unit = .percent }, .height = .{} } },
        .{ .geometry = .{ .width = .{} } },
        .{ .visibility = .{ .display = .flex, .box = .block_level } },
        .{ .visibility = .{ .display = .grid, .box = .atomic_inline } },
        .{ .geometry = .{ .width = .{ .unit = .content } }, .flow = .{ .position = .absolute, .floated = true } },
        .{ .geometry = .{ .width = .{ .unit = .content } }, .flow = .{ .position = .relative, .floated = false } },
    };

    var i: usize = 0;
    var child = div.asNode().firstChild();
    while (child) |node| : (child = node.nextSibling()) {
        const el = node.is(Element) orelse continue;
        // std's expectEqual: testing's can't compare an optional struct
        const scanned = inlineDeclared(Declarations, el, frame).props(.any);
        try std.testing.expectEqual(expected[i], scanned);
        try std.testing.expectEqual(expected[i].visibility, inlineDeclared(Visibility.Declared, el, frame).props(.any));
        try std.testing.expectEqual(expected[i].geometry, inlineDeclared(Geometry.Declared, el, frame).props(.any));
        try std.testing.expectEqual(expected[i].flow, inlineDeclared(Flow.Declared, el, frame).props(.any));
        // scanning never creates the style object
        try testing.expectEqual(null, el.existingStyle(frame));
        const materialized = extractDeclared(Declarations, (try el.getOrCreateStyle(frame)).asCSSStyleDeclaration().declarationBlock(), frame).props(.any);
        try std.testing.expectEqual(expected[i], materialized);
        i += 1;
    }
    try testing.expectEqual(expected.len, i);
}

test "StyleManager: memo: reuse and invalidation" {
    const frame = try testing.createFrame();
    defer testing.test_session.closeAllPages();
    const sm = &frame._style_manager;

    const div = try frame.window._document.createElement("div", null, frame);
    try Frame.parse.htmlAsChildren(frame, div.asNode(),
        \\<p><b style="color: red">x</b></p>
    );
    const p = div.asNode().firstChild().?.as(Element);
    const b = p.asNode().firstChild().?.as(Element);

    // The walk memoizes the element and every ancestor
    try testing.expectEqual(false, sm.isHidden(b, .{}));
    try testing.expectEqual(3, sm.visibility.memo.count());
    try testing.expectEqual(0, sm.geometry.memo.count());
    try testing.expectEqual(false, sm.isHidden(b, .{}));
    try testing.expectEqual(3, sm.visibility.memo.count());

    // Probes never create the style object
    try testing.expectEqual(null, b.existingStyle(frame));

    // An attribute change anywhere invalidates the memo
    try p.setAttributeSafe(comptime .wrap("hidden"), .wrap(""), frame);
    try testing.expectEqual(true, sm.isHidden(b, .{}));
    try testing.expectEqual(false, sm.hasDisplayNone(b));
    try testing.expectEqual(true, sm.hasDisplayNone(p));
    try testing.expectEqual(false, sm.hasAuthorDisplayNone(p));

    p.removeAttributeSafe(comptime .wrap("hidden"), frame);
    try testing.expectEqual(false, sm.isHidden(b, .{}));

    try b.setStyle("display: none; pointer-events: none", frame);
    try testing.expectEqual(true, sm.hasAuthorDisplayNone(b));
    try testing.expectEqual(true, sm.hasPointerEventsNone(b));
    try testing.expectEqual(false, sm.hasPointerEventsNone(p));

    try b.setStyle("display: flex; visibility: hidden", frame);
    try testing.expectEqual(.flex, sm.display(b));
    try testing.expectEqual(false, sm.isHidden(b, .{}));
    try testing.expectEqual(true, sm.isHidden(b, .{ .check_visibility = true }));
    try testing.expectEqual(true, sm.hasVisibilityHiddenInherited(b));
    try testing.expectEqual(false, sm.hasPointerEventsNone(b));

    try b.setStyle("overflow: hidden auto", frame);
    try testing.expectEqual(Element.ScrollAxes{ .x = false, .y = true }, sm.overflowAxes(b));
    try testing.expectEqual(Element.ScrollAxes{}, sm.overflowAxes(p));

    // Setting the shorthand resets both longhands, whatever declared them.
    try b.setStyle("overflow: hidden; overflow-y: scroll", frame);
    try testing.expectEqual(Element.ScrollAxes{ .x = false, .y = true }, sm.overflowAxes(b));
    try (try b.getOrCreateStyle(frame)).asCSSStyleDeclaration().setProperty("overflow", "hidden", null, frame);
    try testing.expectEqual(Element.ScrollAxes{}, sm.overflowAxes(b));

    // overscroll-behavior expands the same way; only `auto` chains outward.
    try b.setStyle("overscroll-behavior: contain auto", frame);
    try testing.expectEqual(Element.ScrollAxes{ .x = true, .y = false }, sm.overscrollContainAxes(b));
    try testing.expectEqual(Element.ScrollAxes{}, sm.overscrollContainAxes(p));
    try b.setStyle("overscroll-behavior-y: none", frame);
    try testing.expectEqual(Element.ScrollAxes{ .x = false, .y = true }, sm.overscrollContainAxes(b));
    try b.setStyle("overscroll-behavior: contain; overscroll-behavior-x: auto", frame);
    try testing.expectEqual(Element.ScrollAxes{ .x = false, .y = true }, sm.overscrollContainAxes(b));

    try b.setStyle("touch-action: pan-y pinch-zoom", frame);
    try testing.expectEqual(Element.ScrollAxes{ .x = true, .y = false }, sm.touchPanBlockedAxes(b));
    try b.setStyle("touch-action: none", frame);
    try testing.expectEqual(Element.ScrollAxes{ .x = true, .y = true }, sm.touchPanBlockedAxes(b));
    try b.setStyle("touch-action: manipulation", frame);
    try testing.expectEqual(Element.ScrollAxes{}, sm.touchPanBlockedAxes(b));
    try testing.expectEqual(Element.ScrollAxes{}, sm.touchPanBlockedAxes(p));
    // An ancestor's touch-action narrows its descendants'.
    try p.setStyle("touch-action: pan-x", frame);
    try testing.expectEqual(Element.ScrollAxes{ .x = false, .y = true }, sm.touchPanBlockedAxes(b));

    // A stylesheet change resets the memo
    sm.sheetModified();
    try testing.expectEqual(false, sm.isHidden(p, .{}));
    try testing.expectEqual(2, sm.visibility.memo.count());
}

test "StyleManager: memo: an inline write it doesn't cascade keeps it" {
    const frame = try testing.createFrame();
    defer testing.test_session.closeAllPages();
    const sm = &frame._style_manager;

    const doc = frame.document;
    const html = (try doc.createElement("html", null, frame)).asNode();
    _ = try doc.asNode().appendChild(html, frame);
    const body = (try doc.createElement("body", null, frame)).asNode();
    _ = try html.appendChild(body, frame);
    try Frame.parse.htmlAsChildren(frame, body, "<div></div>");
    const div = body.firstChild().?.as(Element);
    const style = (try div.getOrCreateStyle(frame)).asCSSStyleDeclaration();

    // A carousel moves each slide with a transform, many times a second
    const version = frame.page.style_version;
    try style.setProperty("transform", "translateX(-50px)", null, frame);
    try style.setProperty("z-index", "2", null, frame);
    _ = try style.removeProperty("transform", frame);
    try testing.expectEqual(version, frame.page.style_version);
    try testing.expectString("z-index: 2;", div.getAttributeSafe(comptime .wrap("style")).?);

    // Once a selector reads the style attribute, any write can change a match
    const style_el = (try doc.createElement("style", null, frame)).as(Element.Html.Style);
    try style_el.asNode().setTextContent("[style*=rotate] { display: none }", frame);
    _ = try body.appendChild(style_el.asNode(), frame);
    try testing.expectEqual(false, sm.hasDisplayNone(div));
    try style.setProperty("transform", "rotate(5deg)", null, frame);
    try testing.expectEqual(true, sm.hasDisplayNone(div));
}

test "StyleManager: memo: validity pseudo-classes read only listed attributes" {
    const frame = try testing.createFrame();
    defer testing.test_session.closeAllPages();
    const sm = &frame._style_manager;

    const doc = frame.document;
    const html = (try doc.createElement("html", null, frame)).asNode();
    _ = try doc.asNode().appendChild(html, frame);
    const body = (try doc.createElement("body", null, frame)).asNode();
    _ = try html.appendChild(body, frame);
    // One control per validity path. fill_check panics on any attribute
    // read that pseudoClassAttributes doesn't list.
    try Frame.parse.htmlAsChildren(frame, body,
        \\<form id=f><fieldset>
        \\<input required pattern="\d+" minlength=2 maxlength=4 value=abc>
        \\<input type=email multiple value="a@b, c">
        \\<input type=url value=x>
        \\<input type=number min=1 max=5 step=2 value=4>
        \\<input type=range min=1 max=5>
        \\<input type=date min=2020-01-01 max=2020-12-31 value=2019-01-01>
        \\<input type=time step=60 value=10:00:30>
        \\<input type=month value=2020-01><input type=week value=2020-W01>
        \\<input type=datetime-local value=2020-01-01T00:00>
        \\<input type=checkbox required><input type=radio name=r required>
        \\<input type=file required><input type=hidden required>
        \\<input readonly required><input disabled required>
        \\<input list=l><datalist id=l><option value=1></datalist>
        \\<textarea required minlength=2 maxlength=4>a</textarea>
        \\<select required><option value="">-</option><option>a</option></select>
        \\<select multiple required><option selected>a</option></select>
        \\<button>b</button><button type=reset>r</button><output></output>
        \\</fieldset></form>
        \\<input form=f required>
    );
    const style_el = (try doc.createElement("style", null, frame)).as(Element.Html.Style);
    try style_el.asNode().setTextContent(":invalid, :out-of-range { display: none } :valid, :in-range { visibility: hidden }", frame);
    _ = try body.appendChild(style_el.asNode(), frame);

    // Too long and too short only apply once the user edited the value
    const first = (try doc.querySelector(comptime .wrap("input"), frame)).?;
    try first.as(Element.Html.Input).setUserValue("abcde", frame);
    const textarea = (try doc.querySelector(comptime .wrap("textarea"), frame)).?;
    try textarea.as(Element.Html.TextArea).setUserValue("abcde", frame);

    var it: TreeWalker.Full = .init(body, .{});
    while (it.next()) |node| {
        const el = node.is(Element) orelse continue;
        _ = sm.hasDisplayNone(el);
        _ = sm.hasVisibilityHiddenInherited(el);
    }

    // A listed name flips :invalid
    try testing.expectEqual(true, sm.hasDisplayNone(first));
    try first.setAttribute(comptime .wrap("pattern"), comptime .wrap("[a-z]+"), frame);
    try first.setAttribute(comptime .wrap("maxlength"), comptime .wrap("8"), frame);
    try testing.expectEqual(false, sm.hasDisplayNone(first));
}

test "StyleManager: memo: attribute writes no selector reads keep it" {
    const frame = try testing.createFrame();
    defer testing.test_session.closeAllPages();
    const sm = &frame._style_manager;

    const doc = frame.document;
    const html = (try doc.createElement("html", null, frame)).asNode();
    _ = try doc.asNode().appendChild(html, frame);
    const body = (try doc.createElement("body", null, frame)).asNode();
    _ = try html.appendChild(body, frame);
    try Frame.parse.htmlAsChildren(frame, body, "<div data-open><p class=a></p></div>");
    const style_el = (try doc.createElement("style", null, frame)).as(Element.Html.Style);
    try style_el.asNode().setTextContent("div:not([data-open]) .a { display: none } :has(> [aria-busy=true]) { visibility: hidden } :disabled { display: none }", frame);
    _ = try body.appendChild(style_el.asNode(), frame);
    const div = body.firstChild().?.as(Element);
    const p = div.asNode().firstChild().?.as(Element);
    try testing.expectEqual(false, sm.hasDisplayNone(p));

    // A foreign element's attribute keeps its case: names match ignoring it
    try testing.expectEqual(false, sm.readsAttribute("viewBox"));
    try testing.expectEqual(true, sm.readsAttribute("Data-Open"));
    try testing.expectEqual(true, sm.readsAttribute("HIDDEN"));

    // Unread names and same-value writes keep the memo
    const version = frame.page.style_version;
    try div.setAttribute(comptime .wrap("data-track"), comptime .wrap("1"), frame);
    try div.setAttribute(comptime .wrap("aria-label"), comptime .wrap("x"), frame);
    try div.setAttribute(comptime .wrap("title"), comptime .wrap("x"), frame);
    try div.setAttribute(comptime .wrap("href"), comptime .wrap("/x"), frame);
    try div.removeAttribute(comptime .wrap("data-track"), frame);
    try div.setAttribute(comptime .wrap("data-open"), comptime .wrap(""), frame);
    try testing.expectEqual(version, frame.page.style_version);

    // Names read inside :not() and :has() drop it
    try div.removeAttribute(comptime .wrap("data-open"), frame);
    try testing.expectEqual(true, sm.hasDisplayNone(p));
    try testing.expectEqual(false, sm.hasVisibilityHiddenInherited(div));
    try p.setAttribute(comptime .wrap("aria-busy"), comptime .wrap("true"), frame);
    try testing.expectEqual(true, sm.hasVisibilityHiddenInherited(div));

    // Names a pseudo-class reads: :disabled reads disabled
    try p.setAttribute(comptime .wrap("disabled"), comptime .wrap(""), frame);
    try testing.expect(frame.page.style_version != version);

    // Names the engine reads whatever the rules
    const before = frame.page.style_version;
    try div.setAttribute(comptime .wrap("hidden"), comptime .wrap(""), frame);
    try testing.expect(frame.page.style_version != before);
    try testing.expectEqual(true, sm.hasDisplayNone(div));
}

test "StyleManager: memo: a tree change drops only what it can reach" {
    const frame = try testing.createFrame();
    defer testing.test_session.closeAllPages();
    const sm = &frame._style_manager;

    const doc = frame.document;
    const html = (try doc.createElement("html", null, frame)).asNode();
    _ = try doc.asNode().appendChild(html, frame);
    const body = (try doc.createElement("body", null, frame)).asNode();
    _ = try html.appendChild(body, frame);
    try Frame.parse.htmlAsChildren(frame, body, "<div><p></p></div><section></section>");
    const style_el = (try doc.createElement("style", null, frame)).as(Element.Html.Style);
    try style_el.asNode().setTextContent("p + i { visibility: hidden } :has(> b) { visibility: hidden }", frame);
    _ = try body.appendChild(style_el.asNode(), frame);
    const div = body.firstChild().?;
    const p = div.firstChild().?.as(Element);
    const section = div.nextSibling().?;

    try testing.expectEqual(false, sm.hasVisibilityHiddenInherited(p));
    const version = frame.page.style_version;
    const layout_version = sm.layoutVersion();
    const cascades = sm.visibility.cascades;

    // An insertion into section keeps p's entry, but moves the layout memos
    const in_section = try doc.createElement("i", null, frame);
    _ = try section.appendChild(in_section.asNode(), frame);
    try testing.expectEqual(version, frame.page.style_version);
    try testing.expect(sm.layoutVersion() != layout_version);
    try testing.expectEqual(false, sm.hasVisibilityHiddenInherited(p));
    try testing.expectEqual(cascades, sm.visibility.cascades);

    // Appended after p: `+` reads the previous sibling, so only what's
    // appended can change; div and p keep their entries
    const after_p = try doc.createElement("i", null, frame);
    _ = try div.appendChild(after_p.asNode(), frame);
    try testing.expectEqual(version, frame.page.style_version);
    try testing.expectEqual(true, sm.hasVisibilityHiddenInherited(after_p));
    try testing.expectEqual(false, sm.hasVisibilityHiddenInherited(p));
    try testing.expectEqual(cascades + 1, sm.visibility.cascades);

    // Inserted before p: p's previous sibling changed, p goes, div stays
    const before_p = try doc.createElement("i", null, frame);
    _ = try div.insertBefore(before_p.asNode(), p.asNode(), frame);
    try testing.expectEqual(false, sm.hasVisibilityHiddenInherited(p));
    try testing.expectEqual(cascades + 2, sm.visibility.cascades);
    // A text node isn't a sibling to any selector: nothing changes
    _ = try div.insertBefore(try doc.createTextNode("x"), p.asNode(), frame);
    try testing.expectEqual(false, sm.hasVisibilityHiddenInherited(p));
    try testing.expectEqual(cascades + 2, sm.visibility.cascades);

    // A removed element inherited from its old ancestors
    _ = try div.removeChild(p.asNode(), frame);
    try testing.expectEqual(version, frame.page.style_version);
    const before_read = sm.visibility.cascades;
    try testing.expectEqual(false, sm.hasVisibilityHiddenInherited(p));
    try testing.expectEqual(before_read + 1, sm.visibility.cascades);

    // A :has() subject moving in reaches the ancestors: everything goes
    const b = try doc.createElement("b", null, frame);
    _ = try section.appendChild(b.asNode(), frame);
    try testing.expect(frame.page.style_version != version);
    try testing.expectEqual(true, sm.hasVisibilityHiddenInherited(in_section));
}

test "StyleManager: memo: form controls and :has() subjects widen a tree change" {
    const frame = try testing.createFrame();
    defer testing.test_session.closeAllPages();
    const sm = &frame._style_manager;

    const doc = frame.document;
    const html = (try doc.createElement("html", null, frame)).asNode();
    _ = try doc.asNode().appendChild(html, frame);
    const body = (try doc.createElement("body", null, frame)).asNode();
    _ = try html.appendChild(body, frame);
    try Frame.parse.htmlAsChildren(frame, body, "<p></p><main><ul><li></li></ul></main><section><form><div></div></form></section>");
    const style_el = (try doc.createElement("style", null, frame)).as(Element.Html.Style);
    try style_el.asNode().setTextContent(
        \\.ctl:invalid ~ .msg, :disabled { display: none }
        \\.card:has(> img) { visibility: hidden }
    , frame);
    _ = try body.appendChild(style_el.asNode(), frame);
    const p = body.firstChild().?.as(Element);
    const main = p.asNode().nextSibling().?;
    const ul = main.firstChild().?;
    const section = main.nextSibling().?;
    const form = section.firstChild().?;
    var tw = TreeWalker.Full.Elements.init(body, .{});
    while (tw.next()) |el| {
        _ = sm.hasVisibilityHiddenInherited(el);
    }
    try testing.expectEqual(1, sm.has.depth);
    try testing.expectEqual(false, sm.has.unbounded);
    const version = frame.page.style_version;

    // A row with a control and an image, outside any form: ul's parent's
    // subtree (the image's anchor is ul), p untouched
    const li = try doc.createElement("li", null, frame);
    try Frame.parse.htmlAsChildren(frame, li.asNode(), "<input class=ctl required><img>");
    _ = try ul.appendChild(li.asNode(), frame);
    try testing.expectEqual(version, frame.page.style_version);
    try testing.expectEqual(true, sm.visibility.memo.contains(p));
    try testing.expectEqual(false, sm.visibility.memo.contains(main.as(Element)));

    // A control in a form: the form's parent's subtree
    _ = sm.hasVisibilityHiddenInherited(main.as(Element));
    const input = try doc.createElement("input", null, frame);
    _ = try form.firstChild().?.appendChild(input.asNode(), frame);
    try testing.expectEqual(version, frame.page.style_version);
    try testing.expectEqual(false, sm.visibility.memo.contains(section.as(Element)));
    try testing.expectEqual(true, sm.visibility.memo.contains(p));

    // A radio's group can be anywhere in its form owner: everything
    tw = TreeWalker.Full.Elements.init(body, .{});
    while (tw.next()) |el| {
        _ = sm.hasVisibilityHiddenInherited(el);
    }
    const radio = try doc.createElement("input", null, frame);
    try radio.setAttribute(comptime .wrap("type"), comptime .wrap("radio"), frame);
    _ = try ul.appendChild(radio.asNode(), frame);
    try testing.expect(frame.page.style_version != version);
}

test "StyleManager: memo: a class change drops what its selectors reach" {
    const frame = try testing.createFrame();
    defer testing.test_session.closeAllPages();
    const sm = &frame._style_manager;

    const doc = frame.document;
    const html = (try doc.createElement("html", null, frame)).asNode();
    _ = try doc.asNode().appendChild(html, frame);
    const body = (try doc.createElement("body", null, frame)).asNode();
    _ = try html.appendChild(body, frame);
    try Frame.parse.htmlAsChildren(frame, body, "<div><p></p></div><section><i></i></section>");
    const style_el = (try doc.createElement("style", null, frame)).as(Element.Html.Style);
    try style_el.asNode().setTextContent(
        \\.a { visibility: hidden }
        \\.anc .x, .sib + i, :not(.neg) > b { display: none }
        \\li:nth-child(odd of .of) { display: none }
        \\.h:has(.k > .kk) { display: none }
        \\.hh:has(:is(.ka .kb)) { display: none }
    , frame);
    _ = try body.appendChild(style_el.asNode(), frame);
    const div = body.firstChild().?.as(Element);
    const p = div.asNode().firstChild().?.as(Element);
    const section = div.asNode().nextSibling().?.as(Element);
    const i = section.asNode().firstChild().?.as(Element);

    try testing.expectEqual(false, sm.hasVisibilityHiddenInherited(p));
    try testing.expectEqual(ClassReach.subtree, sm.class_reach.get("a").?);
    try testing.expectEqual(ClassReach.subtree, sm.class_reach.get("anc").?);
    try testing.expectEqual(ClassReach.subtree, sm.class_reach.get("x").?);
    try testing.expectEqual(ClassReach.parent_subtree, sm.class_reach.get("sib").?);
    try testing.expectEqual(ClassReach.subtree, sm.class_reach.get("neg").?);
    try testing.expectEqual(ClassReach.parent_subtree, sm.class_reach.get("of").?);
    try testing.expectEqual(ClassReach.subtree, sm.class_reach.get("h").?);
    try testing.expectEqual(ClassReach.full, sm.class_reach.get("k").?);
    try testing.expectEqual(ClassReach.full, sm.class_reach.get("kk").?);
    try testing.expectEqual(ClassReach.full, sm.class_reach.get("ka").?);
    try testing.expectEqual(ClassReach.full, sm.class_reach.get("kb").?);
    try testing.expectEqual(null, sm.class_reach.get("hook"));

    _ = sm.hasVisibilityHiddenInherited(i);
    const version = frame.page.style_version;
    const layout_version = sm.layoutVersion();
    const cascades = sm.visibility.cascades;

    // No selector names it: nothing moves
    try section.setAttribute(comptime .wrap("class"), comptime .wrap("hook"), frame);
    try testing.expectEqual(version, frame.page.style_version);
    try testing.expectEqual(layout_version, sm.layoutVersion());

    // Its subtree only: p keeps its entry
    try section.setAttribute(comptime .wrap("class"), comptime .wrap("hook a"), frame);
    try testing.expectEqual(version, frame.page.style_version);
    try testing.expect(sm.layoutVersion() != layout_version);
    try testing.expectEqual(true, sm.hasVisibilityHiddenInherited(i));
    try testing.expectEqual(false, sm.hasVisibilityHiddenInherited(p));
    try testing.expectEqual(cascades + 2, sm.visibility.cascades);

    // Reordering the same classes changes nothing
    try section.setAttribute(comptime .wrap("class"), comptime .wrap("a  hook"), frame);
    try testing.expectEqual(cascades + 2, sm.visibility.cascades);

    // In a :has() argument: everything
    try i.setAttribute(comptime .wrap("class"), comptime .wrap("k"), frame);
    try testing.expect(frame.page.style_version != version);
}

test "StyleManager: memo: a class attribute selector reaches where it sits" {
    const frame = try testing.createFrame();
    defer testing.test_session.closeAllPages();
    const sm = &frame._style_manager;

    const doc = frame.document;
    const html = (try doc.createElement("html", null, frame)).asNode();
    _ = try doc.asNode().appendChild(html, frame);
    const body = (try doc.createElement("body", null, frame)).asNode();
    _ = try html.appendChild(body, frame);
    try Frame.parse.htmlAsChildren(frame, body, "<div><p></p></div><main><section></section><i></i></main>");
    const style_el = (try doc.createElement("style", null, frame)).as(Element.Html.Style);
    try style_el.asNode().setTextContent("[class] + i { visibility: hidden }", frame);
    _ = try body.appendChild(style_el.asNode(), frame);
    const div = body.firstChild().?.as(Element);
    const p = div.asNode().firstChild().?.as(Element);
    const main = div.asNode().nextSibling().?;
    const section = main.firstChild().?.as(Element);
    const i = section.asNode().nextSibling().?.as(Element);
    try testing.expectEqual(false, sm.hasVisibilityHiddenInherited(i));
    try testing.expectEqual(false, sm.hasVisibilityHiddenInherited(p));
    // More cached than the walk visits, or dropping costs more than a reset
    _ = sm.hasVisibilityHiddenInherited(section);
    try testing.expectEqual(ClassReach.parent_subtree, sm.class_attribute_reach.?);
    const version = frame.page.style_version;

    // Present but empty is a change for [class]: i, a later sibling, sees it
    try section.setAttribute(comptime .wrap("class"), comptime .wrap(""), frame);
    try testing.expectEqual(version, frame.page.style_version);
    try testing.expectEqual(true, sm.hasVisibilityHiddenInherited(i));
    try testing.expectEqual(true, sm.visibility.memo.contains(p));
    try section.removeAttribute(comptime .wrap("class"), frame);
    try testing.expectEqual(false, sm.hasVisibilityHiddenInherited(i));
}

test "StyleManager: memo: changes in a detached tree keep it" {
    const frame = try testing.createFrame();
    defer testing.test_session.closeAllPages();
    const sm = &frame._style_manager;

    const doc = frame.document;
    const html = (try doc.createElement("html", null, frame)).asNode();
    _ = try doc.asNode().appendChild(html, frame);
    const body = (try doc.createElement("body", null, frame)).asNode();
    _ = try html.appendChild(body, frame);
    try Frame.parse.htmlAsChildren(frame, body, "<p></p>");
    const style_el = (try doc.createElement("style", null, frame)).as(Element.Html.Style);
    try style_el.asNode().setTextContent(".x i { visibility: hidden } [data-off] { display: none }", frame);
    _ = try body.appendChild(style_el.asNode(), frame);
    const p = body.firstChild().?.as(Element);
    try testing.expectEqual(false, sm.hasVisibilityHiddenInherited(p));
    const version = frame.page.style_version;
    const layout_version = sm.layoutVersion();
    sm.setCacheLayout(p, .box_width, 10);

    // A component built off-DOM: attributes, children, text, inline style,
    // innerHTML
    const card = try doc.createElement("div", null, frame);
    try card.setAttribute(comptime .wrap("class"), comptime .wrap("x"), frame);
    const i = try doc.createElement("i", null, frame);
    _ = try card.asNode().appendChild(i.asNode(), frame);
    try i.asNode().setTextContent("text", frame);
    const style = (try i.getOrCreateStyle(frame)).asCSSStyleDeclaration();
    try style.setProperty("width", "10px", null, frame);
    const extra = try doc.createElement("div", null, frame);
    try Frame.parse.htmlAsChildren(frame, extra.asNode(), "<b data-off></b>");
    _ = try card.asNode().appendChild(extra.asNode(), frame);
    try testing.expectEqual(version, frame.page.style_version);
    try testing.expectEqual(layout_version, sm.layoutVersion());

    // Once a detached element is read, a change in its tree drops that
    // tree's entries, and only those
    try testing.expectEqual(true, sm.hasVisibilityHiddenInherited(i));
    try testing.expectEqual(true, sm.visibility.memo.contains(i));
    sm.setCacheLayout(i, .box_width, 50);
    try card.removeAttribute(comptime .wrap("class"), frame);
    try testing.expectEqual(version, frame.page.style_version);
    try testing.expectEqual(layout_version, sm.layoutVersion());
    try testing.expectEqual(false, sm.visibility.memo.contains(i));
    try testing.expectEqual(false, sm.visibility.memo.contains(card));
    try testing.expectEqual(true, sm.visibility.memo.contains(p));
    try testing.expectEqual(null, sm.getCachedLayout(i, .box_width));
    try testing.expectEqual(@as(?f64, 10), sm.getCachedLayout(p, .box_width));
    try testing.expectEqual(false, sm.hasVisibilityHiddenInherited(i));

    // Taken out of its detached tree, it no longer inherits from it
    try card.setAttribute(comptime .wrap("class"), comptime .wrap("x"), frame);
    try testing.expectEqual(true, sm.hasVisibilityHiddenInherited(i));
    _ = try card.asNode().removeChild(i.asNode(), frame);
    try testing.expectEqual(false, sm.hasVisibilityHiddenInherited(i));
    _ = try card.asNode().insertBefore(i.asNode(), card.asNode().firstChild(), frame);
    try testing.expectEqual(version, frame.page.style_version);

    // Inserted, it's read from the cascade again
    _ = try body.appendChild(card.asNode(), frame);
    try testing.expectEqual(true, sm.hasVisibilityHiddenInherited(i));
    try testing.expectEqual(true, sm.visibility.memo.contains(i));
    try testing.expectEqual(true, sm.hasDisplayNone(extra.asNode().firstChild().?.as(Element)));
    try testing.expectEqual(false, sm.hasVisibilityHiddenInherited(p));

    // Removed, its entries go with it
    _ = try body.removeChild(card.asNode(), frame);
    try testing.expectEqual(false, sm.visibility.memo.contains(i));
}

test "StyleManager: memo: a style attribute write drops what its declarations reach" {
    const frame = try testing.createFrame();
    defer testing.test_session.closeAllPages();
    const sm = &frame._style_manager;

    const doc = frame.document;
    const html = (try doc.createElement("html", null, frame)).asNode();
    _ = try doc.asNode().appendChild(html, frame);
    const body = (try doc.createElement("body", null, frame)).asNode();
    _ = try html.appendChild(body, frame);
    try Frame.parse.htmlAsChildren(frame, body, "<div><p></p></div>");
    const div = body.firstChild().?.as(Element);
    const p = div.asNode().firstChild().?.as(Element);
    try testing.expectEqual(false, sm.hasVisibilityHiddenInherited(p));
    _ = sm.geometryProps(div);
    const version = frame.page.style_version;
    var layout_version = sm.layoutVersion();

    // No memo reads a custom property or a transform
    try div.setAttribute(comptime .wrap("style"), .wrap("--x: 1; transform: translateX(3px)"), frame);
    try testing.expectEqual(layout_version, sm.layoutVersion());
    try testing.expectEqual(true, sm.geometry.memo.contains(div));

    // A width: the element's geometry and the layout, not visibility
    try div.setAttribute(comptime .wrap("style"), .wrap("--x: 1; transform: translateX(3px); width: 10px"), frame);
    try testing.expectEqual(false, sm.geometry.memo.contains(div));
    try testing.expect(sm.layoutVersion() != layout_version);
    try testing.expectEqual(true, sm.visibility.memo.contains(p));

    // The same width, written differently: only the custom property changed
    _ = sm.geometryProps(div);
    layout_version = sm.layoutVersion();
    try div.setAttribute(comptime .wrap("style"), .wrap("WIDTH:10px ; --x: 2; transform: translateX(3px)"), frame);
    try testing.expectEqual(layout_version, sm.layoutVersion());
    try testing.expectEqual(true, sm.geometry.memo.contains(div));

    // A shorthand and its longhand, reordered: same declarations, but they
    // fold by position
    try div.setAttribute(comptime .wrap("style"), .wrap("margin: 0; margin-left: 50px"), frame);
    _ = sm.geometryProps(div);
    layout_version = sm.layoutVersion();
    try div.setAttribute(comptime .wrap("style"), .wrap("margin-left: 50px; margin: 0"), frame);
    try testing.expectEqual(false, sm.geometry.memo.contains(div));
    try testing.expect(sm.layoutVersion() != layout_version);

    // Visibility is inherited: the element's subtree goes
    try div.setAttribute(comptime .wrap("style"), .wrap("visibility: hidden"), frame);
    try testing.expectEqual(false, sm.visibility.memo.contains(p));
    try testing.expectEqual(true, sm.hasVisibilityHiddenInherited(p));
    try div.removeAttribute(comptime .wrap("style"), frame);
    try testing.expectEqual(false, sm.hasVisibilityHiddenInherited(p));
    try testing.expectEqual(version, frame.page.style_version);
}

test "StyleManager: memo: :first-child alone reaches the next element" {
    const frame = try testing.createFrame();
    defer testing.test_session.closeAllPages();
    const sm = &frame._style_manager;

    const doc = frame.document;
    const html = (try doc.createElement("html", null, frame)).asNode();
    _ = try doc.asNode().appendChild(html, frame);
    const body = (try doc.createElement("body", null, frame)).asNode();
    _ = try html.appendChild(body, frame);
    try Frame.parse.htmlAsChildren(frame, body, "<ul><li></li><li></li></ul><p></p>");
    const style_el = (try doc.createElement("style", null, frame)).as(Element.Html.Style);
    try style_el.asNode().setTextContent("li:first-child { visibility: hidden }", frame);
    _ = try body.appendChild(style_el.asNode(), frame);
    const ul = body.firstChild().?;
    const first = ul.firstChild().?.as(Element);
    const second = first.asNode().nextSibling().?.as(Element);
    try testing.expectEqual(true, sm.hasVisibilityHiddenInherited(first));
    try testing.expectEqual(false, sm.hasVisibilityHiddenInherited(second));
    try testing.expectEqual(SiblingReads{ .next = 1 }, sm.siblings);

    const version = frame.page.style_version;
    const li = try doc.createElement("li", null, frame);
    _ = try ul.insertBefore(li.asNode(), first.asNode(), frame);
    try testing.expectEqual(version, frame.page.style_version);
    try testing.expectEqual(false, sm.hasVisibilityHiddenInherited(first));
    // only the next one: second kept its entry
    try testing.expectEqual(true, sm.visibility.memo.contains(second));
}

test "StyleManager: memo: a `+` chain reaches a sibling per hop" {
    const frame = try testing.createFrame();
    defer testing.test_session.closeAllPages();
    const sm = &frame._style_manager;

    const doc = frame.document;
    const html = (try doc.createElement("html", null, frame)).asNode();
    _ = try doc.asNode().appendChild(html, frame);
    const body = (try doc.createElement("body", null, frame)).asNode();
    _ = try html.appendChild(body, frame);
    try Frame.parse.htmlAsChildren(frame, body, "<div><i></i><b></b><u></u><s></s></div>");
    const style_el = (try doc.createElement("style", null, frame)).as(Element.Html.Style);
    try style_el.asNode().setTextContent("i + b + u { visibility: hidden }", frame);
    _ = try body.appendChild(style_el.asNode(), frame);
    const div = body.firstChild().?;
    const b = div.firstChild().?.nextSibling().?;
    const u = b.nextSibling().?.as(Element);
    const s = u.asNode().nextSibling().?.as(Element);
    try testing.expectEqual(true, sm.hasVisibilityHiddenInherited(u));
    try testing.expectEqual(false, sm.hasVisibilityHiddenInherited(s));
    try testing.expectEqual(SiblingReads{ .next = 2 }, sm.siblings);

    const version = frame.page.style_version;
    const span = try doc.createElement("span", null, frame);
    _ = try div.insertBefore(span.asNode(), b, frame);
    try testing.expectEqual(version, frame.page.style_version);
    // two hops from the gap: u's entry went, s kept its own
    try testing.expectEqual(false, sm.hasVisibilityHiddenInherited(u));
    try testing.expectEqual(true, sm.visibility.memo.contains(s));

    // :first-child counts as a hop
    try style_el.asNode().setTextContent(":first-child + b + u { visibility: hidden }", frame);
    try testing.expectEqual(false, sm.hasVisibilityHiddenInherited(u));
    try testing.expectEqual(SiblingReads{ .next = 3 }, sm.siblings);
}

test "StyleManager: memo: tree changes between two reads walk once" {
    const frame = try testing.createFrame();
    defer testing.test_session.closeAllPages();
    const sm = &frame._style_manager;

    const doc = frame.document;
    const html = (try doc.createElement("html", null, frame)).asNode();
    _ = try doc.asNode().appendChild(html, frame);
    const body = (try doc.createElement("body", null, frame)).asNode();
    _ = try html.appendChild(body, frame);
    try Frame.parse.htmlAsChildren(frame, body, "<main><ul class=hide><li></li><li></li><li></li></ul></main><p></p>");
    const style_el = (try doc.createElement("style", null, frame)).as(Element.Html.Style);
    // An li moving reaches ul's match, so main's subtree: a drop batching skips
    try style_el.asNode().setTextContent(".hide i { visibility: hidden } ul:has(> li) { visibility: visible }", frame);
    _ = try body.appendChild(style_el.asNode(), frame);
    const main = body.firstChild().?;
    const ul = main.firstChild().?;
    const p = main.nextSibling().?.as(Element);
    var it = ul.childrenIterator();
    while (it.next()) |li| {
        _ = sm.hasVisibilityHiddenInherited(li.as(Element));
    }
    try testing.expectEqual(false, sm.hasVisibilityHiddenInherited(p));
    // Read while detached: its entry is stale once it's under .hide
    const detached = try doc.createElement("i", null, frame);
    try testing.expectEqual(false, sm.hasVisibilityHiddenInherited(detached));

    // The first change walks main, ul and its items, the next ones only what
    // they insert, which can bring entries along
    const version = frame.page.style_version;
    var walked = sm.walked;
    _ = try ul.appendChild((try doc.createElement("li", null, frame)).asNode(), frame);
    try testing.expectEqual(walked + 6, sm.walked);
    walked = sm.walked;
    _ = try ul.appendChild((try doc.createElement("li", null, frame)).asNode(), frame);
    _ = try ul.removeChild(ul.firstChild().?, frame);
    _ = try ul.lastChild().?.appendChild(detached.asNode(), frame);
    try testing.expectEqual(walked + 2, sm.walked);
    try testing.expectEqual(version, frame.page.style_version);
    try testing.expectEqual(true, sm.hasVisibilityHiddenInherited(detached));

    // Reads fill the memo again: the next change walks ul again
    it = ul.childrenIterator();
    while (it.next()) |li| {
        _ = sm.hasVisibilityHiddenInherited(li.as(Element));
    }
    walked = sm.walked;
    _ = try ul.appendChild((try doc.createElement("li", null, frame)).asNode(), frame);
    try testing.expect(sm.walked > walked + 1);
    try testing.expectEqual(version, frame.page.style_version);
}

test "StyleManager: memo: a tree change moves only its own frame's layout" {
    const page = try testing.pageTest("input_mouse_frames.html", .{});
    defer page.close();
    const main = page.frame().?;
    const child = main.child_frames.items[0];
    const main_version = main._style_manager.layoutVersion();
    const child_version = child._style_manager.layoutVersion();

    const div = try child.document.createElement("div", null, child);
    _ = try child.document.getBody().?.asNode().appendChild(div.asNode(), child);
    try testing.expect(child._style_manager.layoutVersion() != child_version);
    try testing.expectEqual(main_version, main._style_manager.layoutVersion());

    // A parent's script mutating the child's DOM passes the parent's frame:
    // the bump still goes to the node's own
    const span = try child.document.createElement("span", null, child);
    _ = try div.asNode().appendChild(span.asNode(), main);
    try testing.expectEqual(main_version, main._style_manager.layoutVersion());
}

test "StyleManager: memo: an inline write drops only the memos that read it" {
    const frame = try testing.createFrame();
    defer testing.test_session.closeAllPages();
    const sm = &frame._style_manager;

    const doc = frame.document;
    const html = (try doc.createElement("html", null, frame)).asNode();
    _ = try doc.asNode().appendChild(html, frame);
    const body = (try doc.createElement("body", null, frame)).asNode();
    _ = try html.appendChild(body, frame);
    try Frame.parse.htmlAsChildren(frame, body, "<div><p></p></div>");
    const div = body.firstChild().?.as(Element);
    const p = div.asNode().firstChild().?.as(Element);
    const style = (try div.getOrCreateStyle(frame)).asCSSStyleDeclaration();
    const version = frame.page.style_version;

    // A fading slide: its visibility, inherited below it, but no width
    sm.setCacheLayout(div, .box_width, 100);
    try testing.expectEqual(false, sm.isHidden(p, .{ .check_opacity = true }));
    try style.setProperty("opacity", "0", null, frame);
    try testing.expectEqual(true, sm.isHidden(p, .{ .check_opacity = true }));
    try testing.expectEqual(@as(?f64, 100), sm.getCachedLayout(div, .box_width));

    // display reaches both
    try style.setProperty("display", "none", null, frame);
    try testing.expectEqual(true, sm.hasDisplayNone(div));
    try testing.expectEqual(null, sm.getCachedLayout(div, .box_width));

    // A shorthand reaches what its longhands do: overflow-x clips the width
    sm.setCacheLayout(div, .box_width, 100);
    try testing.expectEqual(false, sm.clipsOverflowX(div));
    try testing.expectEqual(false, sm.clipsOverflowX(p));
    try style.setProperty("overflow", "hidden", null, frame);
    try testing.expectEqual(true, sm.clipsOverflowX(div));
    try testing.expectEqual(null, sm.getCachedLayout(div, .box_width));
    try testing.expectEqual(true, sm.visibility.memo.contains(div));
    // geometry isn't inherited: only the written element's entry goes
    try testing.expect(sm.geometry.memo.contains(p));
    try testing.expectEqual(false, sm.clipsOverflowX(p));

    // A vertical inset only moves a positioned box, applied on every read
    sm.setCacheLayout(div, .box_width, 100);
    try style.setProperty("top", "4px", null, frame);
    try testing.expectEqual(@as(?f64, 100), sm.getCachedLayout(div, .box_width));

    // No memo reads a custom property
    sm.setCacheLayout(div, .box_width, 100);
    try style.setProperty("--offset", "4px", null, frame);
    try testing.expectString("4px", sm.customPropertyValue(p, sm.customPropertyId(p, "--offset").?).?);
    try testing.expectEqual(@as(?f64, 100), sm.getCachedLayout(div, .box_width));

    // None of it touched another frame's memos
    try testing.expectEqual(version, frame.page.style_version);
}

test "StyleManager: memo: an inherited inline write drops the element's subtree" {
    const frame = try testing.createFrame();
    defer testing.test_session.closeAllPages();
    const sm = &frame._style_manager;

    const doc = frame.document;
    const html = (try doc.createElement("html", null, frame)).asNode();
    _ = try doc.asNode().appendChild(html, frame);
    const body = (try doc.createElement("body", null, frame)).asNode();
    _ = try html.appendChild(body, frame);
    try Frame.parse.htmlAsChildren(frame, body, "<div><p style=\"color: red\"><b style=\"color: red\"></b></p><p><i></i></p></div><section><span></span></section>");
    const div = body.firstChild().?.as(Element);
    const p1 = div.asNode().firstChild().?.as(Element);
    const b = p1.asNode().firstChild().?.as(Element);
    const p2 = p1.asNode().nextSibling().?.as(Element);
    const i = p2.asNode().firstChild().?.as(Element);
    const span = div.asNode().nextSibling().?.firstChild().?.as(Element);
    const style = (try div.getOrCreateStyle(frame)).asCSSStyleDeclaration();
    const version = frame.page.style_version;

    // p2's subtree is never read
    try testing.expectEqual(false, sm.hasVisibilityHiddenInherited(b));
    try testing.expectEqual(false, sm.hasVisibilityHiddenInherited(span));
    try testing.expectEqual(false, sm.inFixedBox(b));
    try testing.expectEqual(false, sm.visibility.memo.contains(p2));

    // div and what's cached under it; the walk stops at p2, not at i
    sm.walked = 0;
    try style.setProperty("visibility", "hidden", null, frame);
    try testing.expectEqual(4, sm.walked);
    try testing.expectEqual(false, sm.visibility.memo.contains(div));
    try testing.expectEqual(false, sm.visibility.memo.contains(b));
    try testing.expectEqual(true, sm.visibility.memo.contains(body.as(Element)));
    try testing.expectEqual(true, sm.visibility.memo.contains(span));
    // flow doesn't declare visibility
    try testing.expectEqual(true, sm.flow.memo.contains(b));
    try testing.expectEqual(true, sm.hasVisibilityHiddenInherited(b));
    try testing.expectEqual(true, sm.hasVisibilityHiddenInherited(i));

    try style.setProperty("position", "fixed", null, frame);
    try testing.expectEqual(true, sm.inFixedBox(b));

    // An uncached element: nothing under it is cached
    sm.walked = 0;
    try (try span.getOrCreateStyle(frame)).asCSSStyleDeclaration().setProperty("position", "fixed", null, frame);
    try testing.expectEqual(1, sm.walked);

    // Text entries hold the element's own values: only its entry goes
    try testing.expectEqual(.inherit, sm.ownTextTransform(b));
    try testing.expectEqual(.inherit, sm.ownTextTransform(p1));
    try testing.expectEqual(.inherit, sm.ownTextTransform(div));
    try style.setProperty("text-transform", "uppercase", null, frame);
    try testing.expectEqual(false, sm.text.memo.contains(div));
    try testing.expectEqual(true, sm.text.memo.contains(b));
    try testing.expectEqual(.uppercase, sm.textTransform(b));

    try testing.expectEqual(version, frame.page.style_version);
}

test "StyleManager: memo: an inherited inline write reaches the flat tree" {
    const frame = try testing.createFrame();
    defer testing.test_session.closeAllPages();
    const sm = &frame._style_manager;

    const doc = frame.document;
    const html = (try doc.createElement("html", null, frame)).asNode();
    _ = try doc.asNode().appendChild(html, frame);
    const body = (try doc.createElement("body", null, frame)).asNode();
    _ = try html.appendChild(body, frame);
    const host = try doc.createElement("div", null, frame);
    _ = try body.appendChild(host.asNode(), frame);
    const shadow = try host.attachShadow(.{ .mode = .open }, frame);
    try Frame.parse.htmlAsChildren(frame, shadow.asNode(), "<h2><slot><b>unused fallback</b></slot></h2>");
    try Frame.parse.htmlAsChildren(frame, host.asNode(), "<p>one</p><span slot=\"none\">orphan</span>");
    const h2 = shadow.asNode().firstChild().?.as(Element);
    const slot = h2.asNode().firstChild().?.as(Element);
    const fallback = slot.asNode().firstChild().?.as(Element);
    const p = host.asNode().firstChild().?.as(Element);
    const orphan = p.asNode().nextSibling().?.as(Element);

    // p inherits through the slot; the unused fallback and the orphan, outside
    // the flat tree, from their DOM parents
    try testing.expectEqual(false, sm.hasVisibilityHiddenInherited(p));
    _ = sm.hasVisibilityHiddenInherited(fallback);
    _ = sm.hasVisibilityHiddenInherited(orphan);
    for ([_]*Element{ h2, slot, fallback, p, orphan }) |el| {
        try testing.expectEqual(true, sm.visibility.memo.contains(el));
    }

    try (try h2.getOrCreateStyle(frame)).asCSSStyleDeclaration().setProperty("visibility", "hidden", null, frame);
    try testing.expectEqual(false, sm.visibility.memo.contains(p));
    try testing.expectEqual(false, sm.visibility.memo.contains(fallback));
    try testing.expectEqual(true, sm.visibility.memo.contains(orphan));
    try testing.expectEqual(true, sm.hasVisibilityHiddenInherited(p));

    try (try host.getOrCreateStyle(frame)).asCSSStyleDeclaration().setProperty("pointer-events", "none", null, frame);
    for ([_]*Element{ h2, slot, p, orphan }) |el| {
        try testing.expectEqual(false, sm.visibility.memo.contains(el));
    }
    try testing.expectEqual(true, sm.hasPointerEventsNone(p));
}

test "StyleManager: records: slots are unique across the page's StyleManagers" {
    const frame = try testing.createFrame();
    defer testing.test_session.closeAllPages();
    const sm = &frame._style_manager;

    const div = try frame.window._document.createElement("div", null, frame);
    try Frame.parse.htmlAsChildren(frame, div.asNode(), "<b style=\"visibility: hidden\"></b><i></i>");
    const b = div.asNode().firstChild().?.as(Element);
    const i = b.asNode().nextSibling().?.as(Element);

    // As another frame's StyleManager, which shares the page's counter
    var other = try StyleManager.init(frame);
    defer other.deinit();
    try testing.expectEqual(false, other.hasVisibilityHiddenInherited(i));
    try testing.expectEqual(true, other.visibility.memo.contains(i));

    try testing.expectEqual(true, sm.hasVisibilityHiddenInherited(b));
    try testing.expect(b._style_slot != i._style_slot);
    try testing.expectEqual(false, sm.visibility.memo.contains(i));
    try testing.expectEqual(false, other.visibility.memo.contains(b));
}

test "StyleManager: records: an adopted element gives up its slot" {
    const frame = try testing.createFrame();
    defer testing.test_session.closeAllPages();
    const sm = &frame._style_manager;
    const doc = frame.window._document;

    const div = try doc.createElement("div", null, frame);
    try Frame.parse.htmlAsChildren(frame, div.asNode(), "<b style=\"visibility: hidden\"></b>");
    const b = div.asNode().firstChild().?.as(Element);
    try testing.expectEqual(true, sm.hasVisibilityHiddenInherited(b));
    const was = b._style_slot;
    try testing.expect(was != 0 and div._style_slot != 0);

    const other = (try frame._factory.document(Node.Document.HTMLDocument{ ._proto = undefined })).asDocument();
    try frame.adoptNodeTree(div.asNode(), doc, other);
    try testing.expectEqual(0, b._style_slot);
    try testing.expectEqual(0, div._style_slot);

    // Back: a new slot, nothing from the old one
    try frame.adoptNodeTree(div.asNode(), other, doc);
    try testing.expectEqual(false, sm.visibility.memo.contains(b));
    try testing.expectEqual(true, sm.hasVisibilityHiddenInherited(b));
    try testing.expect(b._style_slot > was);
}

test "StyleManager: records: a group allocates the chunks it reaches" {
    const frame = try testing.createFrame();
    defer testing.test_session.closeAllPages();
    const sm = &frame._style_manager;

    const div = try frame.window._document.createElement("div", null, frame);
    var html: std.ArrayList(u8) = .empty;
    defer html.deinit(testing.allocator);
    for (0..300) |_| {
        try html.appendSlice(testing.allocator, "<p style=\"text-transform: uppercase\"></p>");
    }
    try Frame.parse.htmlAsChildren(frame, div.asNode(), html.items);

    var it = div.asNode().childrenIterator();
    var last: *Element = undefined;
    while (it.next()) |child| {
        last = child.as(Element);
        _ = sm.hasVisibilityHiddenInherited(last);
    }
    try testing.expectEqual(301, sm.visibility.memo.count());
    try testing.expectEqual(2, sm.visibility.memo.chunks.items.len);

    // Only the last p's chunk
    try testing.expectEqual(.uppercase, sm.ownTextTransform(last));
    try testing.expectEqual(1, sm.text.memo.count());
    try testing.expectEqual(2, sm.text.memo.chunks.items.len);
    try testing.expectEqual(null, sm.text.memo.chunks.items[0]);

    // A style change clears them all at once
    frame.page.style_version += 1;
    try testing.expectEqual(false, sm.hasVisibilityHiddenInherited(last));
    try testing.expectEqual(2, sm.visibility.memo.count());
    try testing.expectEqual(false, sm.visibility.memo.contains(div.asNode().firstChild().?.as(Element)));
}

test "StyleManager: records: geometry packs its lengths' units with the flags" {
    try testing.expectEqual(52, @sizeOf(Records(Geometry.Stored).Entry));

    // Each field apart from its neighbours
    const names = Geometry.Stored.names;
    const types = Geometry.Stored.types;
    inline for (names, types, 0..) |name, T, n| {
        var computed: Geometry.Computed = .{};
        if (T == Length) {
            @field(computed, name) = .{ .value = @floatFromInt(n + 1), .unit = .percent };
        } else {
            @field(computed, name) = true;
        }
        try testing.expectEqual(computed, Geometry.Stored.pack(computed).unpack());
    }

    // All at once, every unit
    var computed: Geometry.Computed = .{};
    const unit_values = std.enums.values(Length.Unit);
    inline for (names, types, 0..) |name, T, n| {
        if (T == Length) {
            @field(computed, name) = .{ .value = -@as(f32, @floatFromInt(n)) / 3, .unit = unit_values[n % unit_values.len] };
        } else {
            @field(computed, name) = n % 2 == 0;
        }
    }
    try testing.expectEqual(computed, Geometry.Stored.pack(computed).unpack());
}

test "StyleManager: records: the layout memo keeps each kind apart" {
    try testing.expectEqual(96, @sizeOf(Records(LayoutMemo.Entry).Entry));

    const frame = try testing.createFrame();
    defer testing.test_session.closeAllPages();
    const sm = &frame._style_manager;

    const div = try frame.window._document.createElement("div", null, frame);
    try testing.expectEqual(null, sm.getCachedLayout(div, .box_width));
    sm.setCacheLayout(div, .box_width, 120);
    sm.setCacheLayout(div, .row_shrink, 0.5);
    try testing.expectEqual(120, sm.getCachedLayout(div, .box_width));
    try testing.expectEqual(0.5, sm.getCachedLayout(div, .row_shrink));
    try testing.expectEqual(null, sm.getCachedLayout(div, .content_width));
    try testing.expectEqual(1, sm.layout_memo.map.count());

    // A layout change clears them all at once
    sm.layout_bumps += 1;
    try testing.expectEqual(null, sm.getCachedLayout(div, .box_width));
    sm.setCacheLayout(div, .content_width, 80);
    try testing.expectEqual(80, sm.getCachedLayout(div, .content_width));
    try testing.expectEqual(null, sm.getCachedLayout(div, .row_shrink));
}

test "StyleManager: records: the generation wraps" {
    const frame = try testing.createFrame();
    defer testing.test_session.closeAllPages();
    const sm = &frame._style_manager;

    const div = try frame.window._document.createElement("div", null, frame);
    _ = sm.hasVisibilityHiddenInherited(div);
    const memo = &sm.visibility.memo;
    // stamped 2^32 - 1 clears ago
    memo.generation = std.math.maxInt(u32);
    memo.chunks.items[0].?[div._style_slot].stamp = 1;
    memo.clear();
    try testing.expectEqual(1, memo.generation);
    try testing.expectEqual(false, memo.contains(div));
}

test "StyleManager: memo: a height write moves only what's stacked below it" {
    const layout = @import("layout.zig");
    const frame = try testing.createFrame();
    defer testing.test_session.closeAllPages();
    const sm = &frame._style_manager;

    const doc = frame.document;
    const html = (try doc.createElement("html", null, frame)).asNode();
    _ = try doc.asNode().appendChild(html, frame);
    const body = (try doc.createElement("body", null, frame)).asNode();
    _ = try html.appendChild(body, frame);
    try Frame.parse.htmlAsChildren(frame, body,
        \\<div id=a><div id=b><div id=c><div id=d style="height:10px"></div> <div id=e style="height:20px"></div></div><div id=f><div id=g style="height:30px"></div></div><div id=h style="height:40px"></div></div><div id=i style="height:50px"><div id=k style="position:absolute"></div></div></div>
    );
    const ids = [_][]const u8{ "a", "b", "c", "d", "e", "f", "g", "h", "i" };
    var els: [ids.len]*Element = undefined;
    for (ids, &els) |id, *el| {
        el.* = doc.getElementById(id).?;
    }
    const a, const b, const c, const d, const e, const f, const g, const h, const i = els;

    const tops = struct {
        fn of(all: []const *Element, owner: *Frame) [ids.len]f64 {
            var out: [ids.len]f64 = undefined;
            for (all, &out) |el, *top| {
                top.* = layout.boxTop(el, owner);
            }
            return out;
        }
    }.of;

    try testing.expectEqual([_]f64{ 0, 0, 0, 0, 10, 30, 30, 60, 100 }, tops(&els, frame));
    try testing.expectEqual(150, doc.extent().height);
    const layout_bumps = sm.layout_bumps;
    const version = frame.page.style_version;

    // c grows: its following siblings (f, h) move, and so does b's (i), since
    // b and a are as tall as their content. Nothing before them moves, nor
    // inside c and f.
    const c_style = (try c.getOrCreateStyle(frame)).asCSSStyleDeclaration();
    try c_style.setProperty("height", "100px", null, frame);
    for ([_]*Element{ b, c, d, e, g }) |el| {
        try testing.expect(sm.getCachedOffset(el, el.asNode().parentElement().?) != null);
    }
    for ([_]*Element{ f, h, i }) |el| {
        try testing.expectEqual(null, sm.getCachedOffset(el, el.asNode().parentElement().?));
    }
    for ([_]*Element{ d, e, f, g, h, i }) |el| {
        try testing.expect(sm.getCachedLayout(el, .box_height) != null);
    }
    for ([_]*Element{ a, b, c }) |el| {
        try testing.expectEqual(null, sm.getCachedLayout(el, .box_height));
    }
    try testing.expectEqual([_]f64{ 0, 0, 0, 0, 10, 100, 100, 130, 170 }, tops(&els, frame));
    try testing.expectEqual(220, doc.extent().height);

    // A declared height stops it: with b's set, d moves e, and nothing past b
    const b_style = (try b.getOrCreateStyle(frame)).asCSSStyleDeclaration();
    try b_style.setProperty("height", "200px", null, frame);
    try testing.expectEqual([_]f64{ 0, 0, 0, 0, 10, 100, 100, 130, 200 }, tops(&els, frame));
    try testing.expectEqual(250, doc.extent().height);
    _ = try c_style.removeProperty("height", frame);
    try testing.expectEqual(null, sm.getCachedOffset(f, b));
    try testing.expect(sm.getCachedOffset(i, a) != null);
    try testing.expect(sm.getCachedLayout(a, .box_height) != null);
    try testing.expectEqual([_]f64{ 0, 0, 0, 0, 10, 30, 30, 60, 200 }, tops(&els, frame));
    try testing.expectEqual(250, doc.extent().height);

    // An out-of-flow box takes no room: its height moves nothing
    const k = doc.getElementById("k").?;
    try testing.expectEqual(200, layout.boxTop(k, frame));
    try testing.expectEqual(0, layout.contentHeight(i, frame));
    const k_style = (try k.getOrCreateStyle(frame)).asCSSStyleDeclaration();
    try k_style.setProperty("height", "30px", null, frame);
    try testing.expect(sm.getCachedOffset(k, i) != null);
    try testing.expect(sm.getCachedLayout(i, .content_height) != null);
    try testing.expectEqual(30, layout.boxHeight(k, frame));

    // None of it dropped the whole layout memo
    try testing.expectEqual(layout_bumps, sm.layout_bumps);
    try testing.expectEqual(version, frame.page.style_version);
}

test "StyleManager: memo: inherited values, any query order" {
    const frame = try testing.createFrame();
    defer testing.test_session.closeAllPages();
    const sm = &frame._style_manager;

    const div = try frame.window._document.createElement("div", null, frame);
    try Frame.parse.htmlAsChildren(frame, div.asNode(),
        \\<p><b style="pointer-events: none"><i style="visibility: hidden"><s style="opacity: 0"><u></u></s></i></b></p>
    );
    const p = div.asNode().firstChild().?.as(Element);
    const b = p.asNode().firstChild().?.as(Element);
    const i = b.asNode().firstChild().?.as(Element);
    const s = i.asNode().firstChild().?.as(Element);
    const u = s.asNode().firstChild().?.as(Element);

    // The deepest first stores every ancestor, each resolved against its parent
    try testing.expectEqual(true, sm.hasPointerEventsNone(u));
    try testing.expectEqual(6, sm.visibility.memo.count());
    try testing.expectEqual(Visibility.Computed{ .visibility_hidden = true, .pointer_events_none = true, .in_opacity_zero = true }, sm.visibility.memo.get(u).?);
    try testing.expectEqual(Visibility.Computed{ .visibility_hidden = true, .pointer_events_none = true }, sm.visibility.memo.get(i).?);
    try testing.expectEqual(Visibility.Computed{ .box = .block_level }, sm.visibility.memo.get(p).?);

    try testing.expectEqual(false, sm.isHidden(u, .{}));
    try testing.expectEqual(true, sm.isHidden(u, .{ .check_visibility = true }));
    try testing.expectEqual(true, sm.isHidden(u, .{ .check_opacity = true }));
    try testing.expectEqual(true, sm.isHidden(s, .{ .check_opacity = true }));
    try testing.expectEqual(false, sm.isHidden(i, .{ .check_opacity = true }));
    try testing.expectEqual(true, sm.hasVisibilityHiddenInherited(i));
    try testing.expectEqual(false, sm.hasVisibilityHiddenInherited(b));
    try testing.expectEqual(true, sm.hasPointerEventsNone(b));
    try testing.expectEqual(false, sm.hasPointerEventsNone(p));

    // A DOM change drops the memo; a middle element first, then below and above it
    try p.setStyle("display: none", frame);
    try testing.expectEqual(true, sm.isHidden(i, .{}));
    try testing.expectEqual(true, sm.isHidden(u, .{}));
    // display itself isn't inherited
    try testing.expectEqual(false, sm.hasDisplayNone(u));
    try testing.expectEqual(true, sm.hasDisplayNone(p));
    try testing.expectEqual(true, sm.hasPointerEventsNone(u));
    try testing.expectEqual(false, sm.hasPointerEventsNone(p));
    try testing.expectEqual(true, sm.isHidden(p, .{}));
    try testing.expectEqual(false, sm.isHidden(div, .{}));

    try p.setStyle("", frame);
    try testing.expectEqual(false, sm.isHidden(u, .{}));
    try testing.expectEqual(true, sm.hasPointerEventsNone(s));
}

test "StyleManager: memo: a descendant overrides inherited visibility and pointer-events" {
    const frame = try testing.createFrame();
    defer testing.test_session.closeAllPages();
    const sm = &frame._style_manager;

    const div = try frame.window._document.createElement("div", null, frame);
    try Frame.parse.htmlAsChildren(frame, div.asNode(),
        \\<b style="visibility: hidden; pointer-events: none"><i style="visibility: visible; pointer-events: auto"><s><u style="visibility: inherit; pointer-events: unset"></u></s></i></b>
    );
    const b = div.asNode().firstChild().?.as(Element);
    const i = b.asNode().firstChild().?.as(Element);
    const s = i.asNode().firstChild().?.as(Element);
    const u = s.asNode().firstChild().?.as(Element);

    // Deepest first resolves the whole path in one walk; top-down hits the
    // memo one level up each time
    for ([_][4]*Element{ .{ u, s, i, b }, .{ b, i, s, u } }) |order| {
        frame.page.style_version += 1; // drop the memo
        for (order) |el| {
            try testing.expectEqual(el == b, sm.isHidden(el, .{ .check_visibility = true }));
            try testing.expectEqual(el == b, sm.hasPointerEventsNone(el));
        }
    }

    try i.setStyle("", frame);
    try testing.expectEqual(true, sm.hasVisibilityHiddenInherited(u));
    try testing.expectEqual(true, sm.hasPointerEventsNone(u));

    // inherit wins the cascade like any value, over a weaker declaration
    try b.setStyle("visibility: inherit !important; visibility: hidden; pointer-events: inherit !important; pointer-events: none", frame);
    try testing.expectEqual(false, sm.hasVisibilityHiddenInherited(u));
    try testing.expectEqual(false, sm.hasPointerEventsNone(b));

    // An invalid value is dropped, so the parent's value still inherits
    try b.setStyle("visibility: hidden; pointer-events: none", frame);
    try u.setStyle("visibility: bogus; pointer-events: bogus", frame);
    try testing.expectEqual(true, sm.hasVisibilityHiddenInherited(u));
    try testing.expectEqual(true, sm.hasPointerEventsNone(u));
}

test "StyleManager: revert on visibility and pointer-events inherits" {
    const frame = try testing.createFrame();
    defer testing.test_session.closeAllPages();
    const sm = &frame._style_manager;

    const doc = frame.document;
    const html = (try doc.createElement("html", null, frame)).asNode();
    _ = try doc.asNode().appendChild(html, frame);
    const body = (try doc.createElement("body", null, frame)).asNode();
    _ = try html.appendChild(body, frame);
    try Frame.parse.htmlAsChildren(frame, body, "<div class=\"x\"></div><div class=\"x\"></div>");
    const a = body.firstChild().?.as(Element);
    const b = a.asNode().nextSibling().?.as(Element);

    const style_el = (try doc.createElement("style", null, frame)).as(Element.Html.Style);
    try style_el.asNode().setTextContent(".x { visibility: hidden; pointer-events: none }", frame);
    _ = try body.insertBefore(style_el.asNode(), a.asNode(), frame);

    // No UA style sets either property, so the inline revert beats the class
    // and inherits the body's values, instead of being dropped as invalid.
    try a.setStyle("visibility: revert; pointer-events: revert", frame);
    try b.setStyle("visibility: REVERT-LAYER; pointer-events: revert-layer", frame);
    for ([_]*Element{ a, b }) |el| {
        try testing.expectEqual(false, sm.hasVisibilityHiddenInherited(el));
        try testing.expectEqual(false, sm.hasPointerEventsNone(el));
    }
}

// Every element of a deep chain probed in document order, the shape of an
// interactivity pass. Walking all ancestors per probe would cascade each
// element once per descendant; the memo cascades it once.
test "StyleManager: memo: probing a deep tree stays linear" {
    const frame = try testing.createFrame();
    defer testing.test_session.closeAllPages();
    const sm = &frame._style_manager;

    const DEPTH = 1000;
    const top = try buildDivChain(frame, DEPTH);

    frame.page.style_version += 1; // drop the memo
    const before = sm.visibility.cascades;
    var current: ?*Element = top;
    while (current) |el| {
        const child = if (el.asNode().firstChild()) |c| c.as(Element) else null;
        // only the deepest one declares it
        try testing.expectEqual(child == null, sm.hasPointerEventsNone(el));
        current = child;
    }
    try testing.expectEqual(DEPTH, sm.visibility.cascades - before);
}

fn buildDivChain(frame: *Frame, depth: usize) !*Element {
    const doc = frame.window._document;
    // Bottom-up: appending under a deep parent walks its ancestors
    var top = try doc.createElement("div", null, frame);
    try top.setStyle("pointer-events: none", frame);
    for (1..depth) |_| {
        const div = try doc.createElement("div", null, frame);
        _ = try div.asNode().appendChild(top.asNode(), frame);
        top = div;
    }
    return top;
}

test "StyleManager: ruleInserted: append joins the buckets without a rebuild" {
    const frame = try testing.createFrame();
    defer testing.test_session.closeAllPages();
    const sm = &frame._style_manager;

    const doc = frame.document;
    const html = (try doc.createElement("html", null, frame)).asNode();
    _ = try doc.asNode().appendChild(html, frame);
    const body = (try doc.createElement("body", null, frame)).asNode();
    _ = try html.appendChild(body, frame);
    // No whitespace between the elements: they must be adjacent siblings
    try Frame.parse.htmlAsChildren(frame, body, "<div class=\"a\"></div><div class=\"b\"></div><div class=\"c\"></div>");
    const a = body.firstChild().?.as(Element);
    const b = a.asNode().nextSibling().?.as(Element);
    const c = b.asNode().nextSibling().?.as(Element);

    // The fragment parser skips a <style>'s ready work, which is what creates
    // and registers its sheet; a connected insert runs it.
    const style_el = (try doc.createElement("style", null, frame)).as(Element.Html.Style);
    try style_el.asNode().setTextContent(".a { display: none }", frame);
    _ = try body.insertBefore(style_el.asNode(), a.asNode(), frame);
    const sheet = style_el._sheet orelse return error.NoSheet;

    try testing.expectEqual(true, sm.isHidden(a, .{}));
    try testing.expectEqual(false, sm.isHidden(b, .{}));
    try testing.expectEqual(false, sm.dirty);

    // Appended to the last sheet: no rebuild, but the memo is stale
    _ = try sheet.insertRule(".b { display: none }", 1, frame);
    try testing.expectEqual(false, sm.dirty);
    try testing.expectEqual(true, sm.isHidden(b, .{}));
    try testing.expectEqual(false, sm.isHidden(c, .{}));

    // A later append wins over the earlier one at equal specificity
    _ = try sheet.insertRule(".b { display: block }", 2, frame);
    try testing.expectEqual(false, sm.dirty);
    try testing.expectEqual(false, sm.isHidden(b, .{}));

    // Inserting in the middle rebuilds; the cascade must agree either way
    _ = try sheet.insertRule(".c { display: none }", 0, frame);
    try testing.expectEqual(true, sm.dirty);
    try testing.expectEqual(true, sm.isHidden(c, .{}));
    try testing.expectEqual(false, sm.isHidden(b, .{}));
    try testing.expectEqual(false, sm.dirty);

    // At-rules always rebuild
    _ = try sheet.insertRule("@media (min-width: 1px) { .c { display: block } }", 4, frame);
    try testing.expectEqual(true, sm.dirty);
    try testing.expectEqual(false, sm.isHidden(c, .{}));
}

test "StyleManager: selectsOnlyPseudoElements" {
    for ([_][]const u8{ ".a::before", ".a:before", ".a:AFTER", ".a::before, .b:first-line", "a > b::marker", ".a:hover::after" }) |text| {
        try testing.expectEqual(true, selectsOnlyPseudoElements(text));
    }
    for ([_][]const u8{ ".a", ".a::before, .b", ".a, .b::before", ".a\\:before", "[data-x=\"::before\"]", ":is(.a, .b)::before, .c", ".a:beforeish", ".a:not(.b)" }) |text| {
        try testing.expectEqual(false, selectsOnlyPseudoElements(text));
    }
}

test "StyleManager: content rules no element matches aren't kept" {
    const frame = try testing.createFrame();
    defer testing.test_session.closeAllPages();
    const sm = &frame._style_manager;

    const doc = frame.document;
    const html = (try doc.createElement("html", null, frame)).asNode();
    _ = try doc.asNode().appendChild(html, frame);
    const body = (try doc.createElement("body", null, frame)).asNode();
    _ = try html.appendChild(body, frame);
    try Frame.parse.htmlAsChildren(frame, body, "<div class=\"probe\"></div>");
    const probe = body.firstChild().?.as(Element);

    const style_el = (try doc.createElement("style", null, frame)).as(Element.Html.Style);
    try style_el.asNode().setTextContent(
        \\.icon-a:before { content: "\f000" }
        \\.icon-b::before, .icon-c::after { content: "\f001" }
        \\.probe { content: "probe" }
    , frame);
    _ = try body.insertBefore(style_el.asNode(), probe.asNode(), frame);

    try testing.expectString("\"probe\"", sm.contentValue(probe).?);
    try testing.expectEqual(1, sm.lazy_rules.get(.content).?.rules.items.len);
}

test "StyleManager: animation rules no element matches aren't kept" {
    testing.test_session.experimental_features.animation = true;
    defer testing.test_session.experimental_features = .{};
    const frame = try testing.createFrame();
    defer testing.test_session.closeAllPages();
    const sm = &frame._style_manager;

    const doc = frame.document;
    const html = (try doc.createElement("html", null, frame)).asNode();
    _ = try doc.asNode().appendChild(html, frame);
    const body = (try doc.createElement("body", null, frame)).asNode();
    _ = try html.appendChild(body, frame);
    try Frame.parse.htmlAsChildren(frame, body, "<div class=\"probe\"></div>");
    const probe = body.firstChild().?.as(Element);

    const style_el = (try doc.createElement("style", null, frame)).as(Element.Html.Style);
    try style_el.asNode().setTextContent(
        \\.spinner::before { animation: spin 1s infinite }
        \\.dot-a:after, .dot-b::after { animation-name: pulse }
        \\.probe { animation: fade 1s }
    , frame);
    _ = try body.insertBefore(style_el.asNode(), probe.asNode(), frame);

    try testing.expectEqual(1, sm.animation(probe).count());
    try testing.expectEqual(1, sm.animation_rules.get(.shorthand).rules.items.len);
    try testing.expectEqual(0, sm.animation_rules.get(.name).rules.items.len);
}

test "StyleManager: animations aren't kept without the experimental feature" {
    const frame = try testing.createFrame();
    defer testing.test_session.closeAllPages();
    const sm = &frame._style_manager;

    const doc = frame.document;
    const html = (try doc.createElement("html", null, frame)).asNode();
    _ = try doc.asNode().appendChild(html, frame);
    const body = (try doc.createElement("body", null, frame)).asNode();
    _ = try html.appendChild(body, frame);
    try Frame.parse.htmlAsChildren(frame, body, "<div class=\"probe\"></div>");
    const probe = body.firstChild().?.as(Element);

    const style_el = (try doc.createElement("style", null, frame)).as(Element.Html.Style);
    try style_el.asNode().setTextContent(
        \\@keyframes fade { to { opacity: 0 } }
        \\.probe { animation: fade 1s; display: block }
    , frame);
    _ = try body.insertBefore(style_el.asNode(), probe.asNode(), frame);

    // The rebuild still cascades the rest of the block
    try testing.expectEqual(false, sm.hasDisplayNone(probe));
    try testing.expectEqual(0, sm.animation(probe).count());
    try testing.expectEqual(0, sm.animation_rules.get(.shorthand).rules.items.len);
    try testing.expectEqual(0, sm.keyframes.count());
}

test "StyleManager: ruleInserted: a content rule keeps the memos" {
    const frame = try testing.createFrame();
    defer testing.test_session.closeAllPages();
    const sm = &frame._style_manager;

    const doc = frame.document;
    const html = (try doc.createElement("html", null, frame)).asNode();
    _ = try doc.asNode().appendChild(html, frame);
    const body = (try doc.createElement("body", null, frame)).asNode();
    _ = try html.appendChild(body, frame);
    try Frame.parse.htmlAsChildren(frame, body, "<div class=\"a\"></div>");
    const a = body.firstChild().?.as(Element);

    const style_el = (try doc.createElement("style", null, frame)).as(Element.Html.Style);
    try style_el.asNode().setTextContent(".a { content: \"first\" }", frame);
    _ = try body.insertBefore(style_el.asNode(), a.asNode(), frame);
    const sheet = style_el._sheet orelse return error.NoSheet;
    try testing.expectString("\"first\"", sm.contentValue(a).?);

    // CSS-in-JS inserts its rules one at a time, many of them pseudo-element
    // content
    const version = frame.page.style_version;
    _ = try sheet.insertRule(".a::before { content: \"\" }", 1, frame);
    _ = try sheet.insertRule(".a { content: \"second\" }", 2, frame);
    try testing.expectEqual(false, sm.dirty);
    try testing.expectEqual(version, frame.page.style_version);
    try testing.expectString("\"second\"", sm.contentValue(a).?);
}

// Child-combinator rules whose subject compound has no id, class or tag
// (Tailwind 3's `.space-x-N > :not([hidden]) ~ :not([hidden])`, Tailwind 4's
// `:where(.space-x-N > :not(:last-child))`, Bootstrap's `.row > *`) are filed
// under the parent compound. Counts the Geometry cascade's lookups: matches
// is what the parent buckets prune, probes is what they cost.
test "StyleManager: work: child-combinator rules keyed by parent" {
    const frame = try testing.createFrame();
    defer testing.test_session.closeAllPages();
    const sm = &frame._style_manager;
    const GeometryGroup = @TypeOf(sm.geometry);

    const SPACE_RULES = 40;
    const css = comptime blk: {
        var text: []const u8 = ".row > * { width: 100% }\n";
        for (0..SPACE_RULES) |i| {
            text = text ++ std.fmt.comptimePrint(
                \\.space-x-{d} > :not([hidden]) ~ :not([hidden]) {{ margin-left: {d}px }}
                \\:where(.gap-x-{d} > :not(:last-child)) {{ margin-right: {d}px }}
                \\
            , .{ i, i, i, i });
        }
        break :blk text;
    };

    const doc = frame.document;
    const html = (try doc.createElement("html", null, frame)).asNode();
    _ = try doc.asNode().appendChild(html, frame);
    const body = (try doc.createElement("body", null, frame)).asNode();
    _ = try html.appendChild(body, frame);
    try Frame.parse.htmlAsChildren(frame, body,
        \\<div class="space-x-4"><span></span><span></span><span></span><span></span><span></span><span></span><span></span><span></span></div><div class="row"><div></div><div></div><div></div><div></div></div><div><div></div><div></div><div></div><div></div></div><div class="gap-x-4"><span></span><span></span><span></span><span></span></div>
    );
    const style_el = (try doc.createElement("style", null, frame)).as(Element.Html.Style);
    try style_el.asNode().setTextContent(css, frame);
    _ = try body.insertBefore(style_el.asNode(), body.firstChild(), frame);

    // Each row's parent, then its children
    var elements: [24]*Element = undefined;
    var count: usize = 0;
    var it = style_el.asNode().nextSibling();
    while (it) |node| : (it = node.nextSibling()) {
        elements[count] = node.as(Element);
        count += 1;
        var child = node.firstChild();
        while (child) |c| : (child = c.nextSibling()) {
            elements[count] = c.as(Element);
            count += 1;
        }
    }
    try testing.expectEqual(elements.len, count);

    try sm.rebuildIfDirty();
    GeometryGroup.work = .{};
    for (elements) |el| {
        _ = sm.geometryProps(el);
    }
    const work = GeometryGroup.work;

    // The cascade the counts describe
    const spans = elements[1..9];
    try testing.expectEqual(Length{}, sm.geometryProps(spans[0]).margin_left);
    try testing.expectEqual(Length{ .value = 4, .unit = .px }, sm.geometryProps(spans[1]).margin_left);
    try testing.expectEqual(Length{ .value = 100, .unit = .percent }, sm.geometryProps(elements[10]).width);
    try testing.expectEqual(Length{}, sm.geometryProps(elements[15]).width);
    const gap_spans = elements[20..24];
    try testing.expectEqual(Length{ .value = 4, .unit = .px }, sm.geometryProps(gap_spans[0]).margin_right);
    try testing.expectEqual(Length{}, sm.geometryProps(gap_spans[3]).margin_right);

    // Filed in `other`, every element was matched against all 81 rules:
    // 24 * 81 = 1944 matches for 27 probes. Now each child of a keyed parent
    // matches its one rule, at the price of probing every element's parent:
    // the 4 rows' <body> tag, each child's parent tag plus its class if any.
    try testing.expectEqual(Work{
        .probes = (24 + 3) + (4 + 8 * 2 + 4 * 2 + 4 * 1 + 4 * 2),
        .matches = 8 + 4 + 4,
    }, work);
}

test "StyleManager: parent-keyed and :where rules keep their priority" {
    const frame = try testing.createFrame();
    defer testing.test_session.closeAllPages();
    const sm = &frame._style_manager;

    const doc = frame.document;
    const html = (try doc.createElement("html", null, frame)).asNode();
    _ = try doc.asNode().appendChild(html, frame);
    const body = (try doc.createElement("body", null, frame)).asNode();
    _ = try html.appendChild(body, frame);
    try Frame.parse.htmlAsChildren(frame, body,
        \\<div class="a"><p></p><p class="x"></p><p></p><p></p></div><section class="a"><p></p></section>
    );
    const style_el = (try doc.createElement("style", null, frame)).as(Element.Html.Style);
    // `div > *` (0,0,1) beats the later :where (0,0,0); the :where beats
    // the earlier `*` (0,0,0) on document order; `.a > .x + *` keys on
    // `.a` past the `+`; `.a:hover > *` can't be keyed, and stays in other.
    try style_el.asNode().setTextContent(
        \\* { width: 30px }
        \\div > * { width: 20px }
        \\:where(.a > *) { width: 10px }
        \\.a > .x + * { margin-left: 5px }
        \\.a:hover > * { margin-right: 7px }
    , frame);
    _ = try body.insertBefore(style_el.asNode(), body.firstChild(), frame);

    const div = style_el.asNode().nextSibling().?.as(Element);
    const section = div.asNode().nextSibling().?.as(Element);
    const ps = div.asNode().firstChild().?;
    const x = ps.nextSibling().?;
    const after_x = x.nextSibling().?.as(Element);

    try sm.rebuildIfDirty();
    try testing.expectEqual(Length{ .value = 20, .unit = .px }, sm.geometryProps(ps.as(Element)).width);
    try testing.expectEqual(Length{ .value = 10, .unit = .px }, sm.geometryProps(section.asNode().firstChild().?.as(Element)).width);
    try testing.expectEqual(Length{ .value = 30, .unit = .px }, sm.geometryProps(section).width);
    try testing.expectEqual(Length{ .value = 5, .unit = .px }, sm.geometryProps(after_x).margin_left);
    try testing.expectEqual(Length{}, sm.geometryProps(after_x.asNode().nextSibling().?.as(Element)).margin_left);
    try testing.expectEqual(Length{}, sm.geometryProps(after_x).margin_right);

    // `*` and `.a:hover > *`
    try testing.expectEqual(2, sm.geometry.other_rules.len);
    try testing.expectEqual(1, sm.geometry.parent.tag.count());
    try testing.expectEqual(1, sm.geometry.parent.class.count());
    try testing.expectEqual(2, sm.geometry.parent.class.get("a").?.len);
}
