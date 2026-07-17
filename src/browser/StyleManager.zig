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
const builtin = @import("builtin");
const lp = @import("lightpanda");

const Frame = @import("Frame.zig");

const CssParser = @import("css/Parser.zig");
const MediaQuery = @import("css/MediaQuery.zig");
const Element = @import("webapi/Element.zig");

const Selector = @import("webapi/selector/Selector.zig");
const SelectorParser = @import("webapi/selector/Parser.zig");
const SelectorList = @import("webapi/selector/List.zig");

const CSSStyleRule = @import("webapi/css/CSSStyleRule.zig");
const CSSStyleSheet = @import("webapi/css/CSSStyleSheet.zig");
const CSSStyleProperties = @import("webapi/css/CSSStyleProperties.zig");
const CSSStyleProperty = @import("webapi/css/CSSStyleDeclaration.zig").Property;

const log = lp.log;
const String = lp.String;
const Allocator = std.mem.Allocator;

pub const VisibilityCache = std.AutoHashMapUnmanaged(*Element, bool);
pub const PointerEventsCache = std.AutoHashMapUnmanaged(*Element, bool);

// Tracks visibility-relevant CSS rules from <style> elements.
// Rules are bucketed by their rightmost selector part for fast lookup.
const StyleManager = @This();

const Tag = Element.Tag;
const Input = Element.Html.Input;
const RuleList = std.MultiArrayList(VisibilityRule);

frame: *Frame,

arena: Allocator,

// Bucketed rules for fast lookup - keyed by rightmost selector part
id_rules: std.StringHashMapUnmanaged(RuleList) = .empty,
class_rules: std.StringHashMapUnmanaged(RuleList) = .empty,
tag_rules: std.AutoHashMapUnmanaged(Tag, RuleList) = .empty,
other_rules: RuleList = .empty, // universal, attribute, pseudo-class endings

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

// Document order counter for tie-breaking equal specificity. Starts at 1, 0
// is used as a sentinel is isElementHidden()
next_doc_order: u32 = 1,

// When true, rules need to be rebuilt
dirty: bool = false,

pub fn init(frame: *Frame) !StyleManager {
    return .{
        .frame = frame,
        .arena = try frame.getArena(.medium, "StyleManager"),
    };
}

pub fn deinit(self: *StyleManager) void {
    self.frame.releaseArena(self.arena);
}

const IS_DEBUG = builtin.mode == .Debug;

/// Hard cap on `@media` / `@layer` nesting depth. CSS allows arbitrarily-deep
/// at-rule nesting; without a cap a hostile inline stylesheet could blow the
/// Zig stack via the mutually-recursive `applyMediaAtRule` / `applyLayerAtRule`
/// `applyInnerRules` frames. 32 is well past anything seen in the wild.
const MAX_AT_RULE_NESTING: u8 = 32;

fn parseSheet(self: *StyleManager, build_arena: Allocator, sheet: *CSSStyleSheet) !void {
    if (sheet._css_rules) |css_rules| {
        for (css_rules._rules.items) |rule| {
            switch (rule._type) {
                .style => |sr| try self.addRule(build_arena, sr),
                // Re-parse the stored source so an `@media` rule inserted via
                // `insertRule` / `replaceSync` participates in the cascade
                // when its query matches the viewport.
                .media => try self.applyMediaAtRule(build_arena, rule._text, 0, NO_LAYER),
                .layer => try self.applyLayerAtRule(build_arena, rule._text, 0, NO_LAYER),
                else => {},
            }
        }
        return;
    }

    const owner_node = sheet.getOwnerNode() orelse return;
    if (owner_node.is(Element.Html.Style)) |style| {
        const text = try style.asNode().getTextContentAlloc(self.arena);
        var it = CssParser.parseStylesheet(text);
        while (it.next()) |parsed_rule| {
            switch (parsed_rule) {
                .style => |s| try self.addRawRule(build_arena, s.selector, s.block, NO_LAYER),
                .at_rule => |a| {
                    // Only `@media` and `@layer` participate in the cascade
                    // here. Other at-rules (`@keyframes`, `@supports`,
                    // `@font-face`, …) don't carry top-level declarations
                    // relevant to the visibility filter and stay skipped as
                    // before.
                    if (std.ascii.eqlIgnoreCase(a.keyword, "media")) {
                        try self.applyMediaAtRule(build_arena, a.text, 0, NO_LAYER);
                    } else if (std.ascii.eqlIgnoreCase(a.keyword, "layer")) {
                        try self.applyLayerAtRule(build_arena, a.text, 0, NO_LAYER);
                    }
                },
            }
        }
    }
}

/// Apply an `@media` at-rule by evaluating its query against the current
/// viewport and, if it matches, parsing the inner block as if its declarations
/// lived at the top level. Non-matching queries silently drop the inner
/// rules. Inline-only by design: external `<link rel="stylesheet">` is out
/// of scope for the headless engine.
fn applyMediaAtRule(self: *StyleManager, build_arena: Allocator, text: []const u8, depth: u8, layer: u16) Allocator.Error!void {
    if (depth >= MAX_AT_RULE_NESTING) {
        return;
    }

    const block = atRuleBlock(text, "@media") orelse return;
    const query = std.mem.trim(u8, block.prelude, &std.ascii.whitespace);

    if (MediaQuery.matches(query, self.frame._page.getViewport()) == false) {
        return;
    }

    try self.applyInnerRules(build_arena, block.body, depth + 1, layer);
}

/// Apply an `@layer` rule (css-cascade-5). Layers have two forms:
/// 1 - Block form which may or may not have a name. We register the layer and
//      parse the inner block. This can recurse.
/// 2 - Statement form only registes the name for ordering.
///
/// The layer parameter is the enclosing layer, or NO_LAYER at the top level.
/// Priority is not assigned here, we need all the layers parsed to do that
/// (since a layer statement can alter the ordering). So we'll do one final pass
// in finalizerLayerRanks
fn applyLayerAtRule(self: *StyleManager, build_arena: Allocator, text: []const u8, depth: u8, layer: u16) Allocator.Error!void {
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
        if (std.mem.indexOfScalar(u8, names, ';')) |semi| {
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

    try self.applyInnerRules(build_arena, block.body, depth + 1, id);
}

/// Parse a conditional at-rule's inner block, adding style rules to the
/// cascade and recursing into nested `@media` / `@layer`. `layer` is the
/// enclosing cascade layer (NO_LAYER when unlayered); `depth` is the nesting
/// depth of the *nested* at-rules (callers pass their own depth + 1).
fn applyInnerRules(self: *StyleManager, build_arena: Allocator, inner: []const u8, depth: u8, layer: u16) Allocator.Error!void {
    var it = CssParser.parseStylesheet(inner);
    while (it.next()) |nested_rule| {
        switch (nested_rule) {
            .style => |s| try self.addRawRule(build_arena, s.selector, s.block, layer),
            .at_rule => |nested| {
                if (std.ascii.eqlIgnoreCase(nested.keyword, "media")) {
                    try self.applyMediaAtRule(build_arena, nested.text, depth, layer);
                } else if (std.ascii.eqlIgnoreCase(nested.keyword, "layer")) {
                    try self.applyLayerAtRule(build_arena, nested.text, depth, layer);
                }
            },
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
    const close = open + (std.mem.lastIndexOfScalar(u8, rest[open..], '}') orelse return null);
    return .{ .prelude = rest[0..open], .body = rest[open + 1 .. close] };
}

/// Find the first `{` in `s` that is not inside a CSS `/* ... */` comment.
/// An unclosed comment returns `null` (treat the whole rule as malformed).
fn indexOfOpenBraceSkippingComments(s: []const u8) ?usize {
    var i: usize = 0;
    while (i < s.len) {
        if (i + 1 < s.len and s[i] == '/' and s[i + 1] == '*') {
            const close = std.mem.indexOf(u8, s[i + 2 ..], "*/") orelse return null;
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
        if (comptime IS_DEBUG) {
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
    const name = try std.fmt.allocPrint(build_arena, "\x00{d}", .{id});
    self.next_anon_layer = id + 1;
    return self.internLayer(build_arena, parent, name);
}

fn internLayer(self: *StyleManager, build_arena: Allocator, parent: u16, name: []const u8) Allocator.Error!u16 {
    const path = if (parent == NO_LAYER)
        try build_arena.dupe(u8, name)
    else
        try std.fmt.allocPrint(build_arena, "{s}.{s}", .{ self.layers.items[parent].path, name });

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

/// Compute every layer's rank and apply it to every VisibilityRule we have.
/// We can only do this now that we've parsed every parsed every sheet since
/// @layer statement can change the ordering/
fn finalizeLayerRanks(self: *StyleManager, build_arena: Allocator) Allocator.Error!void {
    const layers = self.layers.items;

    if (layers.len == 0) {
        // No layers. Every VisibilityRule already has the correct layerless
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

    self.stampRuleList(&self.other_rules);

    var id_it = self.id_rules.valueIterator();
    while (id_it.next()) |rules| {
        self.stampRuleList(rules);
    }

    var class_it = self.class_rules.valueIterator();
    while (class_it.next()) |rules| {
        self.stampRuleList(rules);
    }

    var tag_it = self.tag_rules.valueIterator();
    while (tag_it.next()) |rules| {
        self.stampRuleList(rules);
    }
}

fn stampRuleList(self: *StyleManager, rules: *RuleList) void {
    const layers = self.layers.items;
    const rule_layers = self.rule_layers.items;
    for (rules.items(.priority)) |*priority| {
        const doc_order: u32 = @as(u22, @truncate(priority.*));
        const layer = rule_layers[doc_order - 1];
        const rank = if (layer == NO_LAYER) UNLAYERED_RANK else layers[layer].rank;
        priority.* |= @as(u64, rank) << RANK_SHIFT;
    }
}

fn addRawRule(self: *StyleManager, build_arena: Allocator, selector_text: []const u8, block_text: []const u8, layer: u16) !void {
    if (selector_text.len == 0) return;

    var props = VisibilityProperties{};
    var it = CssParser.parseDeclarationsList(block_text);
    while (it.next()) |decl| {
        const name = decl.name;
        const val = decl.value;
        if (std.ascii.eqlIgnoreCase(name, "display")) {
            props.display_none = std.ascii.eqlIgnoreCase(val, "none");
        } else if (std.ascii.eqlIgnoreCase(name, "visibility")) {
            props.visibility_hidden = std.ascii.eqlIgnoreCase(val, "hidden") or std.ascii.eqlIgnoreCase(val, "collapse");
        } else if (std.ascii.eqlIgnoreCase(name, "opacity")) {
            props.opacity_zero = std.ascii.eqlIgnoreCase(val, "0");
        } else if (std.ascii.eqlIgnoreCase(name, "pointer-events")) {
            props.pointer_events_none = std.ascii.eqlIgnoreCase(val, "none");
        }
    }

    if (!props.isRelevant()) return;

    const selectors = SelectorParser.parseList(self.arena, selector_text) catch return;
    for (selectors) |selector| {
        const rightmost = if (selector.segments.len > 0) selector.segments[selector.segments.len - 1].compound else selector.first;
        const bucket_key = getBucketKey(rightmost) orelse continue;
        const rule = VisibilityRule{
            .props = props,
            .selector = selector,
            .priority = (@as(u64, computeSpecificity(selector)) << SPEC_SHIFT) | @min(self.next_doc_order, MAX_DOC_ORDER),
        };
        self.next_doc_order += 1;
        try self.rule_layers.append(build_arena, layer);

        switch (bucket_key) {
            .id => |id| {
                const gop = try self.id_rules.getOrPut(self.arena, id);
                if (!gop.found_existing) gop.value_ptr.* = .{};
                try gop.value_ptr.append(self.arena, rule);
            },
            .class => |class| {
                const gop = try self.class_rules.getOrPut(self.arena, class);
                if (!gop.found_existing) gop.value_ptr.* = .{};
                try gop.value_ptr.append(self.arena, rule);
            },
            .tag => |tag| {
                const gop = try self.tag_rules.getOrPut(self.arena, tag);
                if (!gop.found_existing) gop.value_ptr.* = .{};
                try gop.value_ptr.append(self.arena, rule);
            },
            .other => {
                try self.other_rules.append(self.arena, rule);
            },
        }
    }
}

pub fn sheetRemoved(self: *StyleManager) void {
    self.dirty = true;
}

pub fn sheetModified(self: *StyleManager) void {
    self.dirty = true;
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
        self.rule_layers = .empty;
        self.frame.releaseArena(build_arena);
    }

    self.dirty = false;
    errdefer self.dirty = true;
    const id_rules_count = self.id_rules.count();
    const class_rules_count = self.class_rules.count();
    const tag_rules_count = self.tag_rules.count();
    const other_rules_count = self.other_rules.len;

    self.frame._session.arena_pool.resetRetain(self.arena);

    self.next_doc_order = 1;

    self.id_rules = .empty;
    try self.id_rules.ensureTotalCapacity(self.arena, id_rules_count);

    self.class_rules = .empty;
    try self.class_rules.ensureTotalCapacity(self.arena, class_rules_count);

    self.tag_rules = .empty;
    try self.tag_rules.ensureTotalCapacity(self.arena, tag_rules_count);

    self.other_rules = .{};
    try self.other_rules.ensureTotalCapacity(self.arena, other_rules_count);

    const sheets = self.frame.document._style_sheets orelse return;
    for (sheets._sheets.items) |sheet| {
        self.parseSheet(build_arena, sheet) catch |err| {
            log.err(.browser, "StyleManager parseSheet", .{ .err = err });
            return err;
        };
    }

    try self.finalizeLayerRanks(build_arena);
}

// Check if an element is hidden based on options.
// By default only checks display:none.
// Walks up the tree to check ancestors.
pub fn isHidden(self: *StyleManager, el: *Element, cache: ?*VisibilityCache, options: CheckVisibilityOptions) bool {
    self.rebuildIfDirty() catch return false;

    var current: ?*Element = el;

    while (current) |elem| {
        // Check cache first (only when checking all properties for caching consistency)
        if (cache) |c| {
            if (c.get(elem)) |hidden| {
                if (hidden) {
                    return true;
                }
                current = elem.parentElement();
                continue;
            }
        }

        const hidden = self.isElementHidden(elem, options);

        // Store in cache
        if (cache) |c| {
            c.put(self.frame.call_arena, elem, hidden) catch |err| {
                log.warn(.browser, "StyleManager cache", .{ .err = err, .src = "isHidden" });
            };
        }

        if (hidden) {
            return true;
        }
        current = elem.parentElement();
    }

    return false;
}

/// Computed display:none for a single element (own property, no ancestor walk).
/// Honors the UA stylesheet rules per HTML Rendering §15.3.1 "Hidden elements"
/// via `isElementHidden`.
pub fn hasDisplayNone(self: *StyleManager, el: *Element) bool {
    self.rebuildIfDirty() catch return false;
    return self.isElementHidden(el, .{});
}

/// Computed display:none coming only from inline style or an author stylesheet
/// rule — the UA stylesheet's hidden elements (<head>, <script>, [hidden], …)
/// are NOT counted, so document scaffolding is preserved. Used by the HTML
/// dump's "invisible" strip mode.
pub fn hasAuthorDisplayNone(self: *StyleManager, el: *Element) bool {
    self.rebuildIfDirty() catch return false;
    return self.isElementHidden(el, .{ .ua_display_none = false });
}

/// Centralizes UA-stylesheet display:none truth so `getComputedStyle().display`
/// (via `hasDisplayNone`) and `el.checkVisibility()` (via `isHidden`) agree.
/// Spec: HTML Rendering §15.3.1 "Hidden elements".
fn matchesUaDisplayNoneRule(el: *Element) bool {
    // Tag check first: O(1) switch, exits for the ~95% of elements with
    // ordinary tags before we touch the attribute list.
    const tag = el.getTag();
    if (tag.isHiddenByUaStylesheet()) return true;

    if (el.hasAttributeSafe(comptime .wrap("hidden"))) return true;

    // input[type="hidden" i] { display: none !important }
    // _input_type is parsed case-insensitively at attribute-set time.
    if (tag == .input) {
        if (el.is(Input)) |input| {
            if (input._input_type == .hidden) return true;
        }
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

/// Computed visibility:hidden for an element, considering only the `visibility`
/// chain (walks ancestors since `visibility` inherits by default). Ignores
/// display:none: an ancestor with display:none means the element isn't
/// rendered, but its computed `visibility` still reflects inherited visibility.
pub fn hasVisibilityHiddenInherited(self: *StyleManager, el: *Element) bool {
    self.rebuildIfDirty() catch return false;
    var current: ?*Element = el;
    while (current) |elem| {
        if (self.isElementHidden(elem, .{ .check_display = false, .check_visibility = true })) {
            return true;
        }
        current = elem.parentElement();
    }
    return false;
}

/// Check if a single element (not ancestors) is hidden.
fn isElementHidden(self: *StyleManager, el: *Element, options: CheckVisibilityOptions) bool {
    // Track best match per property (value + priority)
    // Initialize priority to INLINE_PRIORITY for properties we don't care about - this makes
    // the loop naturally skip them since no stylesheet rule can have priority >= INLINE_PRIORITY
    var display_none: ?bool = null;
    var display_priority: u64 = 0;

    var visibility_hidden: ?bool = null;
    var visibility_priority: u64 = 0;

    var opacity_zero: ?bool = null;
    var opacity_priority: u64 = 0;

    // Check inline styles FIRST - they use INLINE_PRIORITY so no stylesheet can beat them
    if (options.check_display) {
        if (getInlineStyleProperty(el, comptime .wrap("display"), self.frame)) |property| {
            if (property._value.eql(comptime .wrap("none"))) {
                return true; // Early exit for hiding value
            }
            display_none = false;
            display_priority = INLINE_PRIORITY;
        }
    } else {
        // Pin to INLINE_PRIORITY so rule-matching skips display entirely.
        display_priority = INLINE_PRIORITY;
    }

    if (options.check_visibility) {
        if (getInlineStyleProperty(el, comptime .wrap("visibility"), self.frame)) |property| {
            if (property._value.eql(comptime .wrap("hidden")) or property._value.eql(comptime .wrap("collapse"))) {
                return true;
            }
            visibility_hidden = false;
            visibility_priority = INLINE_PRIORITY;
        }
    } else {
        // This can't be beat. Setting this means that, when checking rules
        // we no longer have to check if options.check_visibility is enabled.
        // We can just compare the priority.
        visibility_priority = INLINE_PRIORITY;
    }

    if (options.check_opacity) {
        if (getInlineStyleProperty(el, comptime .wrap("opacity"), self.frame)) |property| {
            if (property._value.eql(comptime .wrap("0"))) {
                return true;
            }
            opacity_zero = false;
            opacity_priority = INLINE_PRIORITY;
        }
    } else {
        opacity_priority = INLINE_PRIORITY;
    }

    if (display_priority == INLINE_PRIORITY and visibility_priority == INLINE_PRIORITY and opacity_priority == INLINE_PRIORITY) {
        return false;
    }

    // Helper to check a single rule
    const Ctx = struct {
        display_none: *?bool,
        display_priority: *u64,
        visibility_hidden: *?bool,
        visibility_priority: *u64,
        opacity_zero: *?bool,
        opacity_priority: *u64,
        el: *Element,
        frame: *Frame,

        fn checkRules(ctx: @This(), rules: *const RuleList) void {
            if (ctx.display_priority.* == INLINE_PRIORITY and
                ctx.visibility_priority.* == INLINE_PRIORITY and
                ctx.opacity_priority.* == INLINE_PRIORITY)
            {
                return;
            }

            const priorities = rules.items(.priority);
            const props_list = rules.items(.props);
            const selectors = rules.items(.selector);

            for (priorities, props_list, selectors) |p, props, selector| {
                // Fast skip using packed priority
                if (p <= ctx.display_priority.* and p <= ctx.visibility_priority.* and p <= ctx.opacity_priority.*) {
                    continue;
                }

                // Logic for property dominance
                const dominated = (props.display_none == null or p <= ctx.display_priority.*) and
                    (props.visibility_hidden == null or p <= ctx.visibility_priority.*) and
                    (props.opacity_zero == null or p <= ctx.opacity_priority.*);

                if (dominated) continue;

                if (matchesSelector(ctx.el, selector, ctx.frame)) {
                    // Update best priorities
                    if (props.display_none != null and p > ctx.display_priority.*) {
                        ctx.display_none.* = props.display_none;
                        ctx.display_priority.* = p;
                    }
                    if (props.visibility_hidden != null and p > ctx.visibility_priority.*) {
                        ctx.visibility_hidden.* = props.visibility_hidden;
                        ctx.visibility_priority.* = p;
                    }
                    if (props.opacity_zero != null and p > ctx.opacity_priority.*) {
                        ctx.opacity_zero.* = props.opacity_zero;
                        ctx.opacity_priority.* = p;
                    }
                }
            }
        }
    };
    const ctx = Ctx{
        .display_none = &display_none,
        .display_priority = &display_priority,
        .visibility_hidden = &visibility_hidden,
        .visibility_priority = &visibility_priority,
        .opacity_zero = &opacity_zero,
        .opacity_priority = &opacity_priority,
        .el = el,
        .frame = self.frame,
    };

    if (el.getAttributeSafe(comptime .wrap("id"))) |id| {
        if (self.id_rules.get(id)) |rules| {
            ctx.checkRules(&rules);
        }
    }

    if (el.getAttributeSafe(comptime .wrap("class"))) |class_attr| {
        var it = std.mem.tokenizeAny(u8, class_attr, &std.ascii.whitespace);
        while (it.next()) |class| {
            if (self.class_rules.get(class)) |rules| {
                ctx.checkRules(&rules);
            }
        }
    }

    if (self.tag_rules.get(el.getTag())) |rules| {
        ctx.checkRules(&rules);
    }

    ctx.checkRules(&self.other_rules);

    // UA stylesheet display:none fallback (HTML Rendering §15.3.1 "Hidden
    // elements"). Applied only when no author rule for `display` matched the
    // element — per CSS Cascade §6.1 any normal-origin author rule beats UA
    // origin regardless of specificity, so `.x { display: flex }` on a
    // `<div class="x" hidden>` must report visible.
    if (options.check_display and options.ua_display_none and display_priority == 0) {
        if (matchesUaDisplayNoneRule(el)) {
            display_none = true;
        }
    }

    return (display_none orelse false) or (visibility_hidden orelse false) or (opacity_zero orelse false);
}

/// Check if an element has pointer-events:none.
/// Checks inline style first - if set, skips stylesheet lookup.
/// Walks up the tree to check ancestors.
pub fn hasPointerEventsNone(self: *StyleManager, el: *Element, cache: ?*PointerEventsCache) bool {
    self.rebuildIfDirty() catch return false;

    var current: ?*Element = el;

    while (current) |elem| {
        // Check cache first
        if (cache) |c| {
            if (c.get(elem)) |pe_none| {
                if (pe_none) return true;
                current = elem.parentElement();
                continue;
            }
        }

        const pe_none = self.elementHasPointerEventsNone(elem);

        if (cache) |c| {
            c.put(self.frame.call_arena, elem, pe_none) catch |err| {
                log.warn(.browser, "StyleManager cache", .{ .err = err, .src = "hasPointerEventsNone" });
            };
        }

        if (pe_none) {
            return true;
        }
        current = elem.parentElement();
    }

    return false;
}

/// Check if a single element (not ancestors) has pointer-events:none.
fn elementHasPointerEventsNone(self: *StyleManager, el: *Element) bool {
    const frame = self.frame;

    // Check inline style first
    if (getInlineStyleProperty(el, .wrap("pointer-events"), frame)) |property| {
        if (property._value.eql(comptime .wrap("none"))) {
            return true;
        }
        return false;
    }

    var result: ?bool = null;
    var best_priority: u64 = 0;

    // Helper to check a single rule
    const checkRules = struct {
        fn check(rules: *const RuleList, res: *?bool, current_priority: *u64, elem: *Element, p: *Frame) void {
            if (current_priority.* == INLINE_PRIORITY) return;

            const priorities = rules.items(.priority);
            const props_list = rules.items(.props);
            const selectors = rules.items(.selector);

            for (priorities, props_list, selectors) |priority, props, selector| {
                if (priority <= current_priority.*) continue;
                if (props.pointer_events_none == null) continue;

                if (matchesSelector(elem, selector, p)) {
                    res.* = props.pointer_events_none;
                    current_priority.* = priority;
                }
            }
        }
    }.check;

    if (el.getAttributeSafe(comptime .wrap("id"))) |id| {
        if (self.id_rules.get(id)) |rules| {
            checkRules(&rules, &result, &best_priority, el, frame);
        }
    }

    if (el.getAttributeSafe(comptime .wrap("class"))) |class_attr| {
        var it = std.mem.tokenizeAny(u8, class_attr, &std.ascii.whitespace);
        while (it.next()) |class| {
            if (self.class_rules.get(class)) |rules| {
                checkRules(&rules, &result, &best_priority, el, frame);
            }
        }
    }

    if (self.tag_rules.get(el.getTag())) |rules| {
        checkRules(&rules, &result, &best_priority, el, frame);
    }

    checkRules(&self.other_rules, &result, &best_priority, el, frame);

    return result orelse false;
}

// Extracts visibility-relevant rules from a CSS rule.
// Creates one VisibilityRule per selector (not per selector list) so each has correct specificity.
// Buckets rules by their rightmost selector part for fast lookup.
fn addRule(self: *StyleManager, build_arena: Allocator, style_rule: *CSSStyleRule) !void {
    const selector_text = style_rule._selector_text;
    if (selector_text.len == 0) {
        return;
    }

    // Check if the rule has visibility-relevant properties
    const style = style_rule._style orelse return;
    const props = extractVisibilityProperties(style);
    if (!props.isRelevant()) {
        return;
    }

    // Parse the selector list
    const selectors = SelectorParser.parseList(self.arena, selector_text) catch return;
    if (selectors.len == 0) {
        return;
    }

    // Create one rule per selector - each has its own specificity
    // e.g., "#id, .class { display: none }" becomes two rules with different specificities
    for (selectors) |selector| {
        // Get the rightmost compound (last segment, or first if no segments)
        const rightmost = if (selector.segments.len > 0)
            selector.segments[selector.segments.len - 1].compound
        else
            selector.first;

        // Find the bucketing key from rightmost compound
        const bucket_key = getBucketKey(rightmost) orelse continue; // skip if dynamic pseudo-class

        const rule = VisibilityRule{
            .props = props,
            .selector = selector,
            .priority = (@as(u64, computeSpecificity(selector)) << SPEC_SHIFT) | @min(self.next_doc_order, MAX_DOC_ORDER),
        };
        self.next_doc_order += 1;
        try self.rule_layers.append(build_arena, NO_LAYER);

        // Add to appropriate bucket
        switch (bucket_key) {
            .id => |id| {
                const gop = try self.id_rules.getOrPut(self.arena, id);
                if (!gop.found_existing) gop.value_ptr.* = .{};
                try gop.value_ptr.append(self.arena, rule);
            },
            .class => |class| {
                const gop = try self.class_rules.getOrPut(self.arena, class);
                if (!gop.found_existing) gop.value_ptr.* = .{};
                try gop.value_ptr.append(self.arena, rule);
            },
            .tag => |tag| {
                const gop = try self.tag_rules.getOrPut(self.arena, tag);
                if (!gop.found_existing) gop.value_ptr.* = .{};
                try gop.value_ptr.append(self.arena, rule);
            },
            .other => {
                try self.other_rules.append(self.arena, rule);
            },
        }
    }
}

const BucketKey = union(enum) {
    id: []const u8,
    class: []const u8,
    tag: Tag,
    other,
};

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
            .universal, .attribute => {},
        }
    }

    return best_key;
}

/// Extracts visibility-relevant properties from a style declaration.
fn extractVisibilityProperties(style: *CSSStyleProperties) VisibilityProperties {
    var props = VisibilityProperties{};
    const decl = style.asCSSStyleDeclaration();

    if (decl.findProperty(comptime .wrap("display"))) |property| {
        props.display_none = property._value.eql(comptime .wrap("none"));
    }

    if (decl.findProperty(comptime .wrap("visibility"))) |property| {
        props.visibility_hidden = property._value.eql(comptime .wrap("hidden")) or property._value.eql(comptime .wrap("collapse"));
    }

    if (decl.findProperty(comptime .wrap("opacity"))) |property| {
        props.opacity_zero = property._value.eql(comptime .wrap("0"));
    }

    if (decl.findProperty(.wrap("pointer-events"))) |property| {
        props.pointer_events_none = property._value.eql(comptime .wrap("none"));
    }

    return props;
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
            .tag, .tag_name => elements.* += 1,
            .universal => {}, // zero specificity
            .attribute => classes.* += 1,
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
                    // All other pseudo-classes count as class-level specificity
                    else => classes.* += 1,
                }
            },
        }
    }
}

fn matchesSelector(el: *Element, selector: Selector.Selector, frame: *Frame) bool {
    const node = el.asNode();
    return SelectorList.matches(node, selector, node, frame);
}

const VisibilityProperties = struct {
    display_none: ?bool = null,
    visibility_hidden: ?bool = null,
    opacity_zero: ?bool = null,
    pointer_events_none: ?bool = null,

    // return true if any field in VisibilityProperties is not null
    fn isRelevant(self: VisibilityProperties) bool {
        return self.display_none != null or
            self.visibility_hidden != null or
            self.opacity_zero != null or
            self.pointer_events_none != null;
    }
};

const VisibilityRule = struct {
    selector: Selector.Selector, // Single selector, not a list
    props: VisibilityProperties,

    // Packed priority: layer_rank:12 | specificity:30 | doc_order:22.
    // The rank bits are 0 until finalizeLayerRanks stamps them (the rank
    // isn't known until all sheets are parsed); the rule's layer lives in
    // the build-only rule_layers side array, indexed by doc_order - 1.
    priority: u64,
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

const UNLAYERED_RANK: u32 = std.math.maxInt(u12);

/// Protect against hostile input. Must be < UNLAYERED_RANK so that it fits in
// its 12 bits of VisibleRule.priority
const MAX_LAYERS: usize = 1024;

// VisibilityRule.priority field offsets (layer_rank:12 | spec:30 | doc:22).
const SPEC_SHIFT: u6 = 22;
const RANK_SHIFT: u6 = 52;

// - 1 since INLINE_PRIORITY is _always_ higher
const MAX_DOC_ORDER: u32 = std.math.maxInt(u22) - 1;

const CheckVisibilityOptions = struct {
    check_display: bool = true,
    check_visibility: bool = false,
    check_opacity: bool = false,
    ua_display_none: bool = true,
};

// Inline styles always win over stylesheets - use max u64 as sentinel.
// Strictly above any packed rule priority: doc_order saturates one below
// its field max, so a real rule can never pack to all-ones.
const INLINE_PRIORITY: u64 = std.math.maxInt(u64);

fn getInlineStyleProperty(el: *Element, property_name: String, frame: *Frame) ?*CSSStyleProperty {
    const style = frame._element_styles.get(el) orelse blk: {
        // No JS-set style object and no style attribute -> nothing inline to read.
        if (el.getAttributeSafe(comptime .wrap("style")) == null) return null;
        break :blk el.getOrCreateStyle(frame) catch |err| {
            log.err(.browser, "StyleManager getOrCreateStyle", .{ .err = err });
            return null;
        };
    };
    return style.asCSSStyleDeclaration().findProperty(property_name);
}

/// Resolved value of an element's inline `style=` declaration for `property_name`,
/// or null when the element has no such declaration. Reads the element's parsed
/// inline style (the same source `el.style` exposes), so `getComputedStyle` and
/// `el.style` agree on inline values instead of resolving them independently.
pub fn inlineStyleValue(self: *StyleManager, el: *Element, property_name: String) ?[]const u8 {
    const property = getInlineStyleProperty(el, property_name, self.frame) orelse return null;
    return property._value.str();
}

const testing = @import("../testing.zig");
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
    // The three fields fill the u64 exactly, without overlap.
    try testing.expectEqual(64, @as(u32, RANK_SHIFT) + 12);
    try testing.expectEqual(RANK_SHIFT, @as(u32, SPEC_SHIFT) + 30);

    // The maximum packable rule priority (unlayered rank, fully-clamped
    // specificity, saturated doc_order) stays below INLINE_PRIORITY.
    const max_packed = (@as(u64, UNLAYERED_RANK) << RANK_SHIFT) |
        (@as(u64, std.math.maxInt(u30)) << SPEC_SHIFT) |
        MAX_DOC_ORDER;
    try testing.expect(max_packed < INLINE_PRIORITY);

    // Real layer ranks fit the 12 rank bits below the unlayered sentinel.
    try testing.expect(MAX_LAYERS < UNLAYERED_RANK);
}
