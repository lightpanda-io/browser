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
const Element = @import("webapi/Element.zig");
const popover = @import("webapi/element/popover.zig");

const Selector = @import("webapi/selector/Selector.zig");
const SelectorParser = @import("webapi/selector/Parser.zig");
const SelectorList = @import("webapi/selector/List.zig");

const CSSRule = @import("webapi/css/CSSRule.zig");
const CSSStyleRule = @import("webapi/css/CSSStyleRule.zig");
const CSSStyleSheet = @import("webapi/css/CSSStyleSheet.zig");
const CSSStyleProperties = @import("webapi/css/CSSStyleProperties.zig");

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

widths: WidthMemo = .{},

// Keyed by property name, pruning to what is (hopefully) one or few rules
custom_rules: std.StringHashMapUnmanaged(CustomProperty) = .empty,

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

// The sheet that emitted the highest document order. A rule appended to it,
// or to a later sheet, stays last in cascade order.
last_rule_sheet: ?*CSSStyleSheet = null,

pub fn init(frame: *Frame) !StyleManager {
    return .{
        .frame = frame,
        .arena = try frame.getArena(.medium, "StyleManager"),
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

/// Hard cap on `@media` / `@layer` nesting depth. CSS allows arbitrarily-deep
/// at-rule nesting; without a cap a hostile inline stylesheet could blow the
/// Zig stack via the mutually-recursive `applyMediaAtRule` / `applyLayerAtRule`
/// `applyInnerRules` frames. 32 is well past anything seen in the wild.
pub const MAX_AT_RULE_NESTING: u8 = 32;

fn parseSheet(self: *StyleManager, build_arena: Allocator, sheet: *CSSStyleSheet) !void {
    if (sheet._css_rules) |css_rules| {
        for (css_rules._rules.items) |rule| {
            switch (rule._type) {
                .style => |sr| {
                    _ = try self.addRule(sr);
                    try self.addNestedCssomRules(build_arena, sr, sr._selector_text, 0);
                },
                // Re-parse the stored source so an `@media` rule inserted via
                // `insertRule` / `replaceSync` participates in the cascade
                // when its query matches the viewport.
                .media => try self.applyMediaAtRule(build_arena, rule._text, 0, NO_LAYER, null),
                .layer => try self.applyLayerAtRule(build_arena, rule._text, 0, NO_LAYER, null),
                else => {},
            }
        }
        return;
    }

    const owner_node = sheet.getOwnerNode() orelse return;
    if (owner_node.is(Element.Html.Style)) |style| {
        const text = try style.asNode().getTextContentAlloc(self.arena.allocator());
        var it = CssParser.parseStylesheet(text);
        while (it.next()) |parsed_rule| {
            switch (parsed_rule) {
                .style => |s| try self.addRawRule(build_arena, s.selector, s.block, 0, NO_LAYER),
                .at_rule => |a| try self.applyAtRule(build_arena, a.keyword, a.text, 0, NO_LAYER, null),
            }
        }
    }
}

/// Apply an at-rule that takes part in the cascade. Only `@media` and `@layer`
/// do here. Other at-rules (`@keyframes`, `@supports`, `@font-face`, …) don't
/// carry declarations relevant to the visibility filter and are skipped.
fn applyAtRule(self: *StyleManager, build_arena: Allocator, keyword: []const u8, text: []const u8, depth: u8, layer: u16, nest: ?[]const u8) Allocator.Error!void {
    if (std.ascii.eqlIgnoreCase(keyword, "media")) {
        return self.applyMediaAtRule(build_arena, text, depth, layer, nest);
    }
    if (std.ascii.eqlIgnoreCase(keyword, "layer")) {
        return self.applyLayerAtRule(build_arena, text, depth, layer, nest);
    }
}

/// Apply an `@media` at-rule by evaluating its query against the current
/// viewport and, if it matches, parsing the inner block as if its declarations
/// lived at the top level. Non-matching queries silently drop the inner
/// rules. Inline-only by design: external `<link rel="stylesheet">` is out
/// of scope for the headless engine.
///
/// `nest` is the selector of the style rule the at-rule is nested in (CSS
/// Nesting), whose block the inner block then is; null at the top level.
fn applyMediaAtRule(self: *StyleManager, build_arena: Allocator, text: []const u8, depth: u8, layer: u16, nest: ?[]const u8) Allocator.Error!void {
    if (depth >= MAX_AT_RULE_NESTING) {
        return;
    }

    const block = atRuleBlock(text, "@media") orelse return;
    const query = std.mem.trim(u8, block.prelude, &std.ascii.whitespace);

    if (MediaQuery.matches(query, self.frame.page.getViewport()) == false) {
        return;
    }

    try self.applyAtRuleBody(build_arena, block.body, depth + 1, layer, nest);
}

/// Apply an `@layer` rule (css-cascade-5). Layers have two forms:
/// 1 - Block form which may or may not have a name. We register the layer and
//      parse the inner block. This can recurse.
/// 2 - Statement form only registes the name for ordering.
///
/// The layer parameter is the enclosing layer, or NO_LAYER at the top level.
/// Priority is not assigned here, we need all the layers parsed to do that
/// (since a layer statement can alter the ordering). So we'll do one final pass
// in finalizerLayerRanks. `nest` is as for applyMediaAtRule.
fn applyLayerAtRule(self: *StyleManager, build_arena: Allocator, text: []const u8, depth: u8, layer: u16, nest: ?[]const u8) Allocator.Error!void {
    if (depth >= MAX_AT_RULE_NESTING) {
        return;
    }
    if (std.ascii.startsWithIgnoreCase(text, "@layer") == false) {
        return;
    }

    const block = atRuleBlock(text, "@layer") orelse {
        // Statement form: `@layer <name>, <name>;`. One invalid name
        // invalidates the whole statement. Validate everything before
        // registering anything.
        var names = text["@layer".len..];
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

    const prelude = std.mem.trim(u8, block.prelude, &std.ascii.whitespace);
    if (prelude.len != 0 and isValidLayerName(prelude) == false) {
        // An invalid layer name invalidates the whole rule.
        return;
    }

    const id = if (prelude.len == 0)
        try self.internAnonymousLayer(build_arena, layer)
    else
        try self.registerLayerPath(build_arena, layer, prelude);

    try self.applyAtRuleBody(build_arena, block.body, depth + 1, id, nest);
}

/// The block of an at-rule nested in a style rule is a block of that rule:
/// `.a { @media (…) { color: red } }` is `@media (…) { .a { color: red } }`.
fn applyAtRuleBody(self: *StyleManager, build_arena: Allocator, body: []const u8, depth: u8, layer: u16, nest: ?[]const u8) Allocator.Error!void {
    if (nest) |selector| {
        return self.addRawRule(build_arena, selector, body, depth, layer);
    }
    return self.applyInnerRules(build_arena, body, depth, layer);
}

/// Parse a conditional at-rule's inner block, adding style rules to the
/// cascade and recursing into nested `@media` / `@layer`. `layer` is the
/// enclosing cascade layer (NO_LAYER when unlayered); `depth` is the nesting
/// depth of the *nested* at-rules (callers pass their own depth + 1).
fn applyInnerRules(self: *StyleManager, build_arena: Allocator, inner: []const u8, depth: u8, layer: u16) Allocator.Error!void {
    var it = CssParser.parseStylesheet(inner);
    while (it.next()) |nested_rule| {
        switch (nested_rule) {
            .style => |s| try self.addRawRule(build_arena, s.selector, s.block, depth, layer),
            .at_rule => |nested| try self.applyAtRule(build_arena, nested.keyword, nested.text, depth, layer, null),
        }
    }
}

/// Split a block at-rule into its prelude and inner block: for
/// `@media <query> { <body> }` returns `.{ .prelude = "<query>", .body = "<body>" }`.
/// Returns `null` when `text` doesn't start with `keyword`, or when it carries
/// no block — notably the statement form (`@layer a, b;`), which declares
/// ordering only.
///
/// `CssParser.RulesIterator.consumeAtRule` always emits a span starting at `@`;
/// for unclosed blocks it runs to EOF, so the closing `}` is located explicitly
/// rather than assumed to be the final byte. The opening `{` is found with a
/// comment-aware scan so a `/* { */` in the prelude doesn't split the rule at
/// the wrong place; the block's own trivia is handled by the CssParser re-parse
/// in `applyInnerRules`, so only this outer boundary needs the special-case scan.
fn atRuleBlock(text: []const u8, keyword: []const u8) ?struct { prelude: []const u8, body: []const u8 } {
    if (std.ascii.startsWithIgnoreCase(text, keyword) == false) {
        return null;
    }

    const rest = text[keyword.len..];
    const open = indexOfOpenBraceSkippingComments(rest) orelse return null;

    // Search only past the opening brace — the matching `}` lives there, and
    // any returned position is naturally `> open` (since `rest[open] == '{'`).
    const close = open + (std.mem.findScalarLast(u8, rest[open..], '}') orelse return null);
    return .{ .prelude = rest[0..open], .body = rest[open + 1 .. close] };
}

/// Find the first `{` in `s` that is not inside a CSS `/* ... */` comment.
/// An unclosed comment returns `null` (treat the whole rule as malformed).
fn indexOfOpenBraceSkippingComments(s: []const u8) ?usize {
    var i: usize = 0;
    while (i < s.len) {
        if (i + 1 < s.len and s[i] == '/' and s[i + 1] == '*') {
            const close = std.mem.find(u8, s[i + 2 ..], "*/") orelse return null;
            i = i + 2 + close + 2;
            continue;
        }
        if (s[i] == '{') return i;
        i += 1;
    }
    return null;
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

    // Custom rules parse their selectors lazily, but the layer ranks are only
    // known now that every sheet has been read
    var custom_it = self.custom_rules.valueIterator();
    while (custom_it.next()) |property| {
        for (property.rules.items) |*rule| {
            rule.priority |= self.layerRank(rule.priority) << RANK_SHIFT;
        }
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

/// `depth` bounds the recursion through nested rules and at-rules, as
/// MAX_AT_RULE_NESTING does for at-rules alone.
fn addRawRule(self: *StyleManager, build_arena: Allocator, selector_text: []const u8, block_text: []const u8, depth: u8, layer: u16) Allocator.Error!void {
    if (selector_text.len == 0) {
        return;
    }
    var customs: CustomSink = .{ .allocator = build_arena };
    const folded = try foldDeclarations(Declarations, CssParser.parseStyleBlock(block_text), &customs);
    _ = try self.addSelectorRules(selector_text, folded.props(.normal), folded.props(.important), customs.map.values(), layer);

    // CSS Nesting: the rules nested in the block follow their parent in
    // cascade order. Most blocks have none, and every nested rule needs a `{`.
    if (depth >= MAX_AT_RULE_NESTING or std.mem.findScalar(u8, block_text, '{') == null) {
        return;
    }
    var it = CssParser.parseStyleBlock(block_text);
    while (it.nextItem()) |item| {
        switch (item) {
            .declaration => {},
            .rule => |nested| {
                // The arena, not build_arena: a custom property's rule keeps
                // its selector text past the rebuild.
                const selector = try CssParser.resolveNestedSelector(self.arena.allocator(), selector_text, nested.selector) orelse continue;
                try self.addRawRule(build_arena, selector, nested.block, depth + 1, layer);
            },
            .at_rule => |nested| try self.applyAtRule(build_arena, nested.keyword, nested.text, depth + 1, layer, selector_text),
        }
    }
}

// Tracked rules get one group Rule per selector (not per selector list)
// so each has correct specificity, bucketed by their rightmost selector part.
// Custom properties are keyed by name instead, and lazily parse the selector.
// Returns whether the rule set any tracked property.
fn addSelectorRules(
    self: *StyleManager,
    selector_text: []const u8,
    props: Declarations,
    important: Declarations,
    customs: []const CustomDeclaration,
    layer: u16,
) !bool {
    const relevant = props.isRelevant() or important.isRelevant();
    if (relevant == false and customs.len == 0) {
        return false;
    }

    const arena = self.arena.allocator();
    const before = self.next_doc_order;

    if (customs.len > 0) {
        const priority = try self.nextPriority(layer);
        for (customs) |custom| {
            const gop = try self.custom_rules.getOrPut(arena, custom.name);
            if (gop.found_existing == false) {
                gop.value_ptr.* = .{};
            }
            // An appended rule joins a property that may already be parsed
            gop.value_ptr.parsed = null;
            try gop.value_ptr.rules.append(arena, .{
                .value = custom.value,
                .priority = priority,
                .selector_text = selector_text,
            });
        }
    }

    if (relevant) {
        const selectors = SelectorParser.parseList(arena, selector_text) catch &.{};
        for (selectors) |selector| {
            try self.addTrackedRule(selector, props, important, layer);
        }
    }
    return self.next_doc_order != before;
}

// One priority per selector, shared by every group it lands in: doc_order
// indexes rule_layers. The !important declarations become a second rule in
// the tier above every normal one, where an unlayered rule packs rank 0.
fn addTrackedRule(self: *StyleManager, selector: Selector.Selector, props: Declarations, important: Declarations, layer: u16) !void {
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

fn isCustomProperty(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "--");
}

pub fn sheetModified(self: *StyleManager) void {
    self.dirty = true;
    self.cascadeChanged();
}

fn cascadeChanged(self: *StyleManager) void {
    self.frame.styleChanged();
    Frame.observers.scheduleResizeDelivery(self.frame);
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
    var caps: [group_fields.len]Capacities = undefined;
    inline for (group_fields, &caps) |field, *c| {
        c.* = @field(self, field).capacities();
    }
    const custom_rules_count = self.custom_rules.count();

    self.arena.resetRetain();
    self.widths = .{};

    self.next_doc_order = 1;
    self.rule_layers = .empty;
    self.last_rule_sheet = null;

    inline for (group_fields, caps) |field, c| {
        try @field(self, field).reset(self.arena.allocator(), c);
    }

    self.custom_rules = .empty;
    try self.custom_rules.ensureTotalCapacity(self.arena.allocator(), custom_rules_count);

    const sheets = self.frame.document._style_sheets orelse return;
    for (sheets._sheets.items) |sheet| {
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
        .collapse = switch (collapse) {
            .inherit, .collapse, .preserve_breaks => true,
            .preserve, .preserve_spaces, .break_spaces => false,
        },
        .newlines = switch (collapse) {
            .preserve, .preserve_breaks, .break_spaces => true,
            .inherit, .collapse, .preserve_spaces => false,
        },
        .wrap = wrap != .nowrap,
    };
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
    if (vis.box != .block_level or el.getTag().isReplacedOrControl()) {
        return .shrink;
    }
    const flow = self.flowProps(el);
    if (flow.position.outOfFlow() or flow.floated) {
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
    const viewport = self.frame.page.getViewport();
    var total: f64 = 0;
    for ([_]Length{ geometry.margin_left, geometry.margin_right }) |margin| {
        total += margin.resolve(viewport) orelse switch (margin.unit) {
            .percent => if (containing_width) |width| @as(f64, margin.value) / 100.0 * width else 0,
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
/// against. A plain inline box is skipped: a block inside a span sizes off
/// the block around the span.
pub fn containingBlock(self: *StyleManager, el: *Element) ?*Element {
    self.assertOwns(el);
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

/// The children lay out side by side: a flex row or a grid. Elsewhere block
/// children stack and only inline-level ones share a line.
pub fn laysOutInRow(self: *StyleManager, el: *Element) bool {
    self.assertOwns(el);
    self.rebuildIfDirty() catch return false;
    const vis = self.visibilityProps(el);
    return vis.display == .grid or (vis.display == .flex and vis.flex_column == false);
}

pub fn isBlockLevel(self: *StyleManager, el: *Element) bool {
    self.assertOwns(el);
    self.rebuildIfDirty() catch return false;
    switch (self.visibilityProps(el).box) {
        .block_level, .table => {},
        .inline_level, .atomic_inline, .contents => return false,
    }
    const flow = self.flowProps(el);
    return flow.position.outOfFlow() == false and flow.floated == false;
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

pub const WidthLimit = union(enum) {
    px: f64,
    percent: f64, // A fraction of the containing block
};

/// min-width and max-width. Null where they don't limit: auto, none, the
/// intrinsic keywords, and values that need layout (em, calc).
pub fn widthLimits(self: *StyleManager, el: *Element) struct { min: ?WidthLimit, max: ?WidthLimit } {
    self.assertOwns(el);
    self.rebuildIfDirty() catch return .{ .min = null, .max = null };
    const geometry = self.geometryProps(el);
    return .{ .min = self.widthLimit(geometry.min_width), .max = self.widthLimit(geometry.max_width) };
}

fn widthLimit(self: *StyleManager, length: Length) ?WidthLimit {
    return switch (length.unit) {
        .auto, .content => null,
        .percent => .{ .percent = @as(f64, length.value) / 100.0 },
        .px, .vw, .vh => .{ .px = length.resolve(self.frame.page.getViewport()).? },
    };
}

// row_shrink is a flex row's shrink ratio, not a width
pub const WidthKind = enum { box, content, full_content, row_shrink };

/// Element's computed widths (see layout.boxWidth), valid for one style
/// version and viewport. Each read otherwise walks up to the root and down
/// the subtree.
const WidthMemo = struct {
    version: usize = 0,
    viewport_width: u32 = 0,
    viewport_height: u32 = 0,
    map: std.AutoHashMapUnmanaged(*Element, Entry) = .empty,

    const Entry = struct {
        box: ?f64 = null,
        content: ?f64 = null,
        full_content: ?f64 = null,
        row_shrink: ?f64 = null,
    };
};

pub fn cachedWidth(self: *StyleManager, el: *Element, comptime kind: WidthKind) ?f64 {
    const memo = self.freshWidthMemo() orelse return null;
    const entry = memo.map.get(el) orelse return null;
    return @field(entry, @tagName(kind));
}

pub fn cacheWidth(self: *StyleManager, el: *Element, comptime kind: WidthKind, width: f64) void {
    const memo = self.freshWidthMemo() orelse return;
    const gop = memo.map.getOrPut(self.arena.allocator(), el) catch |err| {
        log.warn(.browser, "StyleManager width memo", .{ .err = err });
        return;
    };
    if (gop.found_existing == false) {
        gop.value_ptr.* = .{};
    }
    @field(gop.value_ptr, @tagName(kind)) = width;
}

// Rebuilding resets the arena the memo lives in, so it runs first.
fn freshWidthMemo(self: *StyleManager) ?*WidthMemo {
    self.rebuildIfDirty() catch return null;
    const memo = &self.widths;
    const version = self.frame.page.style_version;
    const viewport = self.frame.page.getViewport();
    if (memo.version != version or memo.viewport_width != viewport.width or memo.viewport_height != viewport.height) {
        memo.map.clearRetainingCapacity();
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
    memo: u32,
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
        // What we store in our memo
        const Computed = Spec.Computed;
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
        memo: std.AutoHashMapUnmanaged(*Element, Computed) = .empty,
        memo_version: usize = 0,

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
                .memo = self.memo.count(),
            };
        }

        fn reset(self: *Self, allocator: Allocator, caps: Capacities) !void {
            self.memo = .empty;
            self.path = .empty;
            try self.memo.ensureTotalCapacity(allocator, caps.memo);

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
            const gop = self.freshMemo(frame).getOrPut(allocator, el) catch |err| {
                log.warn(.browser, "StyleManager memo", .{ .err = err });
                return self.compute(el, frame);
            };
            if (gop.found_existing == false) {
                gop.value_ptr.* = self.compute(el, frame);
            }
            return gop.value_ptr.*;
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
                    above = cached;
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

            var it = std.mem.reverseIterator(self.path.items);
            while (it.next()) |step| {
                above = .resolve(step.own, above);
                memo.put(allocator, step.el, above) catch |err| {
                    log.warn(.browser, "StyleManager memo", .{ .err = err });
                };
            }
            return above;
        }

        fn freshMemo(self: *Self, frame: *Frame) *std.AutoHashMapUnmanaged(*Element, Computed) {
            const version = frame.page.style_version;
            if (self.memo_version != version) {
                self.memo.clearRetainingCapacity();
                self.memo_version = version;
            }
            return &self.memo;
        }

        fn compute(self: *const Self, el: *Element, frame: *Frame) Cascaded {
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
            if (parent.getTag() == .details and !parent.hasAttributeSafe(comptime .wrap("open"))) {
                return true;
            }
        }
    }

    return false;
}

/// The CSSOM twin of addRawRule; returns whether the rule set any tracked
/// property.
fn addRule(self: *StyleManager, style_rule: *CSSStyleRule) !bool {
    return self.addRuleAs(style_rule, style_rule._selector_text);
}

/// Add a style rule's declarations under `selector_text`: its own selector,
/// or for a nested rule, that selector resolved against its parent's.
fn addRuleAs(self: *StyleManager, style_rule: *CSSStyleRule, selector_text: []const u8) !bool {
    if (selector_text.len == 0) {
        return false;
    }
    const style = style_rule._style orelse return false;
    const folded = extractDeclared(Declarations, style);
    const customs = try self.extractCustomDeclarations(style);

    // A custom rule holds selector_text until the property is looked up, but it
    // doesn't need a copy: setSelectorText allocates the replacement from the
    // frame arena and never frees the old one. Worst case we match a stale
    // selector, which is what the rest of this file already does when a rule is
    // mutated without going through sheetModified().
    return self.addSelectorRules(selector_text, folded.props(.normal), folded.props(.important), customs, NO_LAYER);
}

/// The CSSOM counterpart to the nested rules addRawRule adds: a style rule
/// keeps the rules nested in its block in `_rules`. `parent_selector` is the
/// parent's selector, already resolved when the parent is itself nested.
fn addNestedCssomRules(self: *StyleManager, build_arena: Allocator, parent: *CSSStyleRule, parent_selector: []const u8, depth: u8) Allocator.Error!void {
    const nested_rules = parent._rules orelse return;
    if (depth >= MAX_AT_RULE_NESTING) {
        return;
    }
    for (nested_rules._rules.items) |rule| {
        switch (rule._type) {
            .style => |sr| {
                // The arena, as in addRawRule.
                const selector = try CssParser.resolveNestedSelector(self.arena.allocator(), parent_selector, sr._selector_text) orelse continue;
                _ = try self.addRuleAs(sr, selector);
                try self.addNestedCssomRules(build_arena, sr, selector, depth + 1);
            },
            .media => try self.applyMediaAtRule(build_arena, rule._text, depth + 1, NO_LAYER, parent_selector),
            .layer => try self.applyLayerAtRule(build_arena, rule._text, depth + 1, NO_LAYER, parent_selector),
            else => {},
        }
    }
}

/// A style rule appended at or after the sheet that emitted the last rule is
/// last in cascade order, so it joins the buckets directly. Anything else
/// takes the rebuild path.
pub fn ruleInserted(self: *StyleManager, sheet: *CSSStyleSheet, rule: *CSSRule) void {
    if (self.dirty) {
        // The pending rebuild reads the sheet's rules and picks it up.
        return;
    }
    const style_rule = switch (rule._type) {
        .style => |s| s,
        else => return self.sheetModified(),
    };
    // A rule with nested rules takes the rebuild path, which adds them.
    if (style_rule._rules != null or !self.appendable(sheet, rule)) {
        return self.sheetModified();
    }
    const added = self.addRule(style_rule) catch return self.sheetModified();
    if (!added) {
        // Nothing tracked changed, so every memoized answer still holds.
        return;
    }
    self.last_rule_sheet = sheet;
    self.cascadeChanged();
}

fn appendable(self: *const StyleManager, sheet: *CSSStyleSheet, rule: *CSSRule) bool {
    const rules = sheet._css_rules orelse return false;
    if (rules._rules.last() != rule) {
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

/// The CSSOM counterpart to foldDeclarations' `--*` branch. Names within one
/// declaration block are already unique, so there is nothing to dedup here.
///
/// Unlike the selector text, both strings have to be copied: they can point
/// into the Property itself (small string optimization), and setProperty /
/// removeProperty destroy it without going through sheetModified(). We'd be
/// left reading freed memory rather than something merely stale.
fn extractCustomDeclarations(self: *StyleManager, style: *CSSStyleProperties) ![]const CustomDeclaration {
    const arena = self.arena.allocator();

    var customs: std.ArrayList(CustomDeclaration) = .empty;
    var it = style.asCSSStyleDeclaration().iterator();
    while (it.next()) |property| {
        const name = property._name.str();
        if (isCustomProperty(name) == false) {
            continue;
        }
        try customs.append(arena, .{
            .name = try arena.dupe(u8, name),
            .value = try arena.dupe(u8, property._value.str()),
            .important = property._important,
        });
    }
    return customs.items;
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

/// Extracts the tracked properties from a style declaration. The object holds
/// one entry per name in first-declared order, so folding it in order gives a
/// shorthand and its longhands the same precedence as the source text.
fn extractDeclared(comptime Declared: type, style: *CSSStyleProperties) Slots(Declared) {
    var slots: Slots(Declared) = .{};
    var it = style.asCSSStyleDeclaration().iterator();
    while (it.next()) |property| {
        slots.apply(property._name.str(), property._value.str(), property._important);
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

    fn parse(value: []const u8) ?Box {
        const trimmed = std.mem.trim(u8, value, &std.ascii.whitespace);
        if (std.ascii.eqlIgnoreCase(trimmed, "contents")) {
            return .contents;
        }

        if (std.ascii.eqlIgnoreCase(trimmed, "table")) {
            return .table;
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
            .slot => .contents,
            .form, .li, .dd, .dt, .details, .summary, .menu, .dir, .hgroup, .legend, .html, .body, .optgroup, .option => .block_level,
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
};

/// text-wrap-mode
pub const WrapMode = enum(u2) {
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

        fn apply(self: *Declared, name: []const u8, value: []const u8) void {
            if (std.ascii.eqlIgnoreCase(name, "display")) {
                self.display = Display.parse(value);
                self.box = Box.parse(value);
            } else if (std.ascii.eqlIgnoreCase(name, "flex-direction")) {
                self.flex_column = isColumnDirection(value);
            } else if (std.ascii.eqlIgnoreCase(name, "flex-wrap")) {
                self.flex_wrap = isWrap(value);
            } else if (std.ascii.eqlIgnoreCase(name, "flex-flow")) {
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
            } else if (std.ascii.eqlIgnoreCase(name, "visibility")) {
                self.visibility_hidden = parseInheritedFlag(value, &.{ "hidden", "collapse" }, &.{ "visible", "initial" });
            } else if (std.ascii.eqlIgnoreCase(name, "opacity")) {
                self.opacity_zero = std.ascii.eqlIgnoreCase(value, "0");
            } else if (std.ascii.eqlIgnoreCase(name, "pointer-events")) {
                self.pointer_events_none = parseInheritedFlag(value, &.{"none"}, &.{
                    "auto",         "initial", "visiblePainted", "visibleFill", "visibleStroke",
                    "visible",      "painted", "fill",           "stroke",      "all",
                    "bounding-box",
                });
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
        const names = [_][]const u8{ "overflow-x", "overflow-y", "overscroll-behavior-x", "overscroll-behavior-y", "width", "height", "min-width", "max-width", "flex", "flex-grow", "flex-shrink", "margin", "margin-inline", "margin-left", "margin-right", "margin-inline-start", "margin-inline-end" };

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

        fn apply(self: *Declared, name: []const u8, value: []const u8) void {
            if (std.ascii.eqlIgnoreCase(name, "overflow-x")) {
                self.overflow_x_scrolls = overflowScrolls(value);
                self.overflow_x_clips = overflowClips(value);
            } else if (std.ascii.eqlIgnoreCase(name, "flex-grow")) {
                self.flex_grow = flexGrows(value);
            } else if (std.ascii.eqlIgnoreCase(name, "flex-shrink")) {
                if (flexFactor(value)) |factor| {
                    self.flex_no_shrink = factor == 0;
                }
            } else if (std.ascii.eqlIgnoreCase(name, "flex")) {
                self.flex_grow = flexShorthandGrows(value);
                self.flex_no_shrink = flexShorthandNoShrink(value);
            } else if (std.ascii.eqlIgnoreCase(name, "margin")) {
                var count: usize = 0;
                // margin: top [right [bottom [left]]]
                var tokens: [4][]const u8 = undefined;
                var it = std.mem.tokenizeAny(u8, value, &std.ascii.whitespace);
                while (it.next()) |token| : (count += 1) {
                    if (count == tokens.len) {
                        return;
                    }
                    tokens[count] = token;
                }
                if (count == 0) {
                    return;
                }
                const right = tokens[@min(count - 1, 1)];
                self.margin_right = Length.parseMargin(right);
                self.margin_left = Length.parseMargin(if (count == 4) tokens[3] else right);
            } else if (std.ascii.eqlIgnoreCase(name, "margin-inline")) {
                // margin-inline: start [end], in a left-to-right flow
                var it = std.mem.tokenizeAny(u8, value, &std.ascii.whitespace);
                const start = it.next() orelse return;
                self.margin_left = Length.parseMargin(start);
                self.margin_right = Length.parseMargin(it.next() orelse start);
            } else if (std.ascii.eqlIgnoreCase(name, "margin-left") or std.ascii.eqlIgnoreCase(name, "margin-inline-start")) {
                self.margin_left = Length.parseMargin(value);
            } else if (std.ascii.eqlIgnoreCase(name, "margin-right") or std.ascii.eqlIgnoreCase(name, "margin-inline-end")) {
                self.margin_right = Length.parseMargin(value);
            } else if (std.ascii.eqlIgnoreCase(name, "overflow-y")) {
                self.overflow_y_scrolls = overflowScrolls(value);
            } else if (std.ascii.eqlIgnoreCase(name, "overscroll-behavior-x")) {
                self.overscroll_x_contains = overscrollContains(value);
            } else if (std.ascii.eqlIgnoreCase(name, "overscroll-behavior-y")) {
                self.overscroll_y_contains = overscrollContains(value);
            } else if (std.ascii.eqlIgnoreCase(name, "width")) {
                self.width = Length.parse(value);
            } else if (std.ascii.eqlIgnoreCase(name, "height")) {
                self.height = Length.parse(value);
            } else if (std.ascii.eqlIgnoreCase(name, "min-width")) {
                self.min_width = Length.parse(value);
            } else if (std.ascii.eqlIgnoreCase(name, "max-width")) {
                self.max_width = Length.parse(value);
            }
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

    const Computed = packed struct(u217) {
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
    };
};

/// The axes a touch may not pan along: touch-action, intersected with the
/// ancestors' (an ancestor's `none` stops the pan too).
const TouchAction = struct {
    const Declared = struct {
        const names = [_][]const u8{"touch-action"};

        pan_x_blocked: ?bool = null,
        pan_y_blocked: ?bool = null,

        fn apply(self: *Declared, name: []const u8, value: []const u8) void {
            if (!std.ascii.eqlIgnoreCase(name, "touch-action")) return;
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

        fn apply(self: *Declared, name: []const u8, value: []const u8) void {
            if (std.ascii.eqlIgnoreCase(name, "text-transform")) {
                self.text_transform = TextTransform.parse(value);
            } else if (std.ascii.eqlIgnoreCase(name, "white-space")) {
                if (WhiteSpace.parse(value)) |white_space| {
                    self.white_space_collapse = white_space.collapse;
                    self.text_wrap_mode = white_space.wrap;
                }
            } else if (std.ascii.eqlIgnoreCase(name, "white-space-collapse")) {
                if (SpaceCollapse.parse(value)) |collapse| {
                    self.white_space_collapse = collapse;
                }
            } else if (std.ascii.eqlIgnoreCase(name, "text-wrap-mode")) {
                if (WrapMode.parse(value)) |mode| {
                    self.text_wrap_mode = mode;
                }
            } else if (std.ascii.eqlIgnoreCase(name, "text-wrap")) {
                if (WrapMode.parseTextWrap(value)) |mode| {
                    self.text_wrap_mode = mode;
                }
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

        fn apply(self: *Declared, name: []const u8, value: []const u8) void {
            if (std.ascii.eqlIgnoreCase(name, "position")) {
                self.position = Position.parse(value);
            } else if (std.ascii.eqlIgnoreCase(name, "float")) {
                self.floated = std.ascii.eqlIgnoreCase(value, "left") or std.ascii.eqlIgnoreCase(value, "right") or
                    std.ascii.eqlIgnoreCase(value, "inline-start") or std.ascii.eqlIgnoreCase(value, "inline-end");
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

    fn apply(self: *Declarations, name: []const u8, value: []const u8) void {
        inline for (group_fields) |field| {
            @field(self, field).apply(name, value);
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

// custom_rules map is property_name -> CustomProperty, loosely:
//    --color => [(:root, "#ff0"), (.card, "#000")]
// So when code says "getComputedStyle(el).getPropertyValue("--color")
// We end up with a relatively small number of rules
const CustomProperty = struct {
    rules: std.ArrayList(CustomRule) = .empty,
    parsed: ?[]const ParsedCustomRule = null, // lazily parsed
};

const CustomRule = struct {
    selector_text: []const u8,
    value: []const u8,
    priority: u64,
};

/// Some frameworks define hundreds+ of custom properties, 99% of which are
/// never accessed via JS. So we don't parse them until something asks for it.
const ParsedCustomRule = struct {
    selector: Selector.Selector,
    value: []const u8,
    priority: u64, // packed the same way as a group Rule.priority
};

/// A `--*` declaration on its way from a rule block into custom_rules.
const CustomDeclaration = struct {
    name: []const u8,
    value: []const u8,
    important: bool,
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
        return extractDeclared(Declared, style);
    }
    const attr = el.getAttributeInterned("style") orelse return .{};
    // Without a sink nothing allocates
    return foldDeclarations(Declared, CssParser.parseDeclarationsList(attr), null) catch unreachable;
}

/// `--*` declarations of one block, keyed by name so a block declaring the same
/// custom property twice keeps only the winner.
const CustomSink = struct {
    allocator: Allocator,
    map: std.StringArrayHashMapUnmanaged(CustomDeclaration) = .empty,
};

// Must agree with CSSStyleDeclaration.applyDeclarations, which is what the
// materialized object was built from: a normal declaration never overrides an
// earlier !important one, and an empty value removes the property. The tracked
// properties are matched case-insensitively; a custom property's name is
// case-sensitive and goes to `customs` when there is one.
fn foldDeclarations(comptime Declared: type, declarations: CssParser.DeclarationsIterator, customs: ?*CustomSink) !Slots(Declared) {
    var slots: Slots(Declared) = .{};
    var it = declarations;
    while (it.next()) |declaration| {
        if (isCustomProperty(declaration.name)) {
            const sink = customs orelse continue;
            const gop = try sink.map.getOrPut(sink.allocator, declaration.name);
            if (gop.found_existing and gop.value_ptr.important and !declaration.important) {
                continue;
            }
            gop.value_ptr.* = .{ .name = declaration.name, .value = declaration.value, .important = declaration.important };
            continue;
        }
        slots.apply(declaration.name, declaration.value, declaration.important);
    }
    return slots;
}

/// One block's winning value per property in `Declared.names`, folded in
/// declaration order.
fn Slots(comptime Declared: type) type {
    return struct {
        const Self = @This();

        slots: [Declared.names.len]Slot = @splat(.{}),

        fn apply(self: *Self, name: []const u8, value: []const u8, important: bool) void {
            if (CssParser.axisShorthand(name)) |shorthand| {
                const values = CssParser.splitAxisPair(value) orelse return;
                self.apply(shorthand.x, values.x, important);
                self.apply(shorthand.y, values.y, important);
                return;
            }
            for (Declared.names, &self.slots) |tracked, *slot| {
                if (std.ascii.eqlIgnoreCase(name, tracked)) {
                    slot.apply(value, important);
                    return;
                }
            }
        }

        fn props(self: Self, comptime importance: Importance) Declared {
            var p: Declared = .{};
            for (Declared.names, self.slots) |name, s| {
                const value = s.value orelse continue;
                switch (importance) {
                    .any => {},
                    .normal => if (s.important) continue,
                    .important => if (s.important == false) continue,
                }
                p.apply(name, value);
            }
            return p;
        }
    };
}

const Importance = enum { any, normal, important };

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

/// Resolved value of an element's inline `style=` declaration for `property_name`,
/// or null when the element has no such declaration. Reads the element's parsed
/// inline style (the same source `el.style` exposes), so `getComputedStyle` and
/// `el.style` agree on inline values instead of resolving them independently.
/// Null too when a tracked property's normal declaration loses to an
/// !important stylesheet rule.
pub fn inlineStyleValue(self: *StyleManager, el: *Element, property_name: String) ?[]const u8 {
    self.assertOwns(el);
    const style = el.inlineStyle(self.frame) orelse return null;
    const declaration = style.asCSSStyleDeclaration();
    const value = declaration.declaredValue(property_name, self.frame) orelse return null;
    if (declaration.declaredImportant(property_name) == false and self.importantRuleWins(el, property_name.str(), value)) {
        return null;
    }
    return value;
}

// Folds the one declaration the way the inline style is folded for layout, so
// a shorthand checks its longhands and a value we don't parse checks nothing.
fn importantRuleWins(self: *StyleManager, el: *Element, name: []const u8, value: []const u8) bool {
    self.rebuildIfDirty() catch return false;
    var slots: Slots(Declarations) = .{};
    slots.apply(name, value, false);
    const declared = slots.props(.any);
    inline for (group_fields) |field| {
        if (@field(self, field).importantRuleWins(@field(declared, field), el, self.frame)) {
            return true;
        }
    }
    return false;
}

/// Computed value of a custom property (`--x`) on `el`, or null when nothing
/// declares it. The value is returned as-is, no var substitution
pub fn customPropertyValue(self: *StyleManager, el: *Element, property_name: String) ?[]const u8 {
    self.assertOwns(el);
    self.rebuildIfDirty() catch return null;

    // Only the rules declaring this name; usually a handful, often none. An
    // element can still shadow them with an inline declaration, so a miss here
    // means walking for inline styles, not returning early.
    const rules = self.parsedCustomRules(property_name.str()) catch |err| blk: {
        log.err(.browser, "StyleManager customProperty", .{ .err = err });
        break :blk &.{};
    };

    var current: ?*Element = el;
    while (current) |elem| : (current = elem.asNode().flatTreeParentElement(self.frame)) {
        if (self.inlineStyleValue(elem, property_name)) |value| {
            return value;
        }

        var winner: ?[]const u8 = null;
        var priority: u64 = 0;
        for (rules) |rule| {
            if (rule.priority <= priority) {
                continue;
            }
            if (matchesSelector(elem, rule.selector, self.frame) == false) {
                continue;
            }
            winner = rule.value;
            priority = rule.priority;
        }

        if (winner) |value| {
            return value;
        }
    }

    return null;
}

/// Gets the parsed rule for a custom property name
fn parsedCustomRules(self: *StyleManager, name: []const u8) ![]const ParsedCustomRule {
    const property = self.custom_rules.getPtr(name) orelse return &.{};
    if (property.parsed) |parsed| {
        // the custom property exists, and we already parsed it.
        return parsed;
    }

    const arena = self.arena.allocator();
    var parsed: std.ArrayList(ParsedCustomRule) = .empty;

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

    if (self.inlineStyleValue(current, comptime .wrap("font-size"))) |raw| {
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
        const materialized = extractDeclared(Declarations, try el.getOrCreateStyle(frame)).props(.any);
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
        frame.styleChanged();
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

    frame.styleChanged();
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
