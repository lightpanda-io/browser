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

const log = @import("../log.zig");
const String = @import("../string.zig").String;

const Page = @import("Page.zig");

const CssParser = @import("css/Parser.zig");
const Element = @import("webapi/Element.zig");

const Selector = @import("webapi/selector/Selector.zig");
const SelectorParser = @import("webapi/selector/Parser.zig");
const SelectorList = @import("webapi/selector/List.zig");

const CSSStyleRule = @import("webapi/css/CSSStyleRule.zig");
const CSSStyleSheet = @import("webapi/css/CSSStyleSheet.zig");
const CSSStyleProperties = @import("webapi/css/CSSStyleProperties.zig");
const CSSStyleProperty = @import("webapi/css/CSSStyleDeclaration.zig").Property;

const Allocator = std.mem.Allocator;

pub const VisibilityCache = std.AutoHashMapUnmanaged(*Element, bool);
pub const PointerEventsCache = std.AutoHashMapUnmanaged(*Element, bool);

// Tracks visibility-relevant CSS rules from <style> elements.
// Rules are bucketed by their rightmost selector part for fast lookup.
const StyleManager = @This();

const Tag = Element.Tag;
const RuleList = std.ArrayList(VisibilityRule);

page: *Page,

arena: Allocator,

// Bucketed rules for fast lookup - keyed by rightmost selector part
id_rules: std.StringHashMapUnmanaged(RuleList) = .empty,
class_rules: std.StringHashMapUnmanaged(RuleList) = .empty,
tag_rules: std.AutoHashMapUnmanaged(Tag, RuleList) = .empty,
other_rules: RuleList = .empty, // universal, attribute, pseudo-class endings

// Document order counter for tie-breaking equal specificity
next_doc_order: u32 = 0,

// When true, rules need to be rebuilt
dirty: bool = false,

pub fn init(page: *Page) !StyleManager {
    return .{
        .page = page,
        .arena = try page.getArena(.{ .debug = "StyleManager" }),
    };
}

pub fn deinit(self: *StyleManager) void {
    self.page.releaseArena(self.arena);
}

pub fn sheetAdded(self: *StyleManager, sheet: *CSSStyleSheet) !void {
    const css_rules = sheet._css_rules orelse return;

    for (css_rules._rules.items) |rule| {
        const style_rule = rule.is(CSSStyleRule) orelse continue;
        try self.addRule(style_rule);
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

    self.dirty = false;
    errdefer self.dirty = true;

    self.page._session.arena_pool.resetRetain(self.arena);

    // Clear all buckets and reset document order
    self.id_rules = .empty;
    self.class_rules = .empty;
    self.tag_rules = .empty;
    self.other_rules = .empty;
    self.next_doc_order = 0;

    const sheets = self.page.document._style_sheets orelse return;
    for (sheets._sheets.items) |sheet| {
        self.sheetAdded(sheet) catch |err| {
            log.err(.browser, "StyleManager sheetAdded", .{ .err = err });
            return err;
        };
    }
}

// Check if an element is hidden based on options.
// By default only checks display:none.
// Walks up the tree to check ancestors.
pub fn isHidden(self: *StyleManager, el: *Element, cache: ?*VisibilityCache, options: CheckVisibilityOptions) bool {
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
            c.put(self.page.call_arena, elem, hidden) catch {};
        }

        if (hidden) {
            return true;
        }
        current = elem.parentElement();
    }

    return false;
}

/// Check if a single element (not ancestors) is hidden.
fn isElementHidden(self: *StyleManager, el: *Element, options: CheckVisibilityOptions) bool {
    // Track best match per property (value + specificity)
    // Initialize spec to INLINE_SPECIFICITY for properties we don't care about - this makes
    // the loop naturally skip them since no stylesheet rule can have specificity >= INLINE_SPECIFICITY
    var display_none: ?bool = null;
    var display_spec: u32 = 0;

    var visibility_hidden: ?bool = null;
    var visibility_spec: u32 = 0;

    var opacity_zero: ?bool = null;
    var opacity_spec: u32 = 0;

    // Check inline styles FIRST - they use INLINE_SPECIFICITY so no stylesheet can beat them
    if (getInlineStyleProperty(el, comptime .wrap("display"), self.page)) |property| {
        if (property._value.eql(comptime .wrap("none"))) {
            return true; // Early exit for hiding value
        }
        display_none = false;
        display_spec = INLINE_SPECIFICITY;
    }

    if (options.check_visibility) {
        if (getInlineStyleProperty(el, comptime .wrap("visibility"), self.page)) |property| {
            if (property._value.eql(comptime .wrap("hidden")) or property._value.eql(comptime .wrap("collapse"))) {
                return true;
            }
            visibility_hidden = false;
            visibility_spec = INLINE_SPECIFICITY;
        }
    } else {
        // This can't be beat. Setting this means that, when checking rules
        // we no longer have to check if options.check_visibility is enabled.
        // We can just compare the specificity.
        visibility_spec = INLINE_SPECIFICITY;
    }

    if (options.check_opacity) {
        if (getInlineStyleProperty(el, comptime .wrap("opacity"), self.page)) |property| {
            if (property._value.eql(comptime .wrap("0"))) {
                return true;
            }
            opacity_zero = false;
            opacity_spec = INLINE_SPECIFICITY;
        }
    } else {
        opacity_spec = INLINE_SPECIFICITY;
    }

    if (display_spec == INLINE_SPECIFICITY and visibility_spec == INLINE_SPECIFICITY and opacity_spec == INLINE_SPECIFICITY) {
        return false;
    }

    self.rebuildIfDirty() catch return false;

    // Track doc_order for tie-breaking (0 = inline style, which always wins)
    var display_doc_order: u32 = 0;
    var visibility_doc_order: u32 = 0;
    var opacity_doc_order: u32 = 0;

    // Helper to check a single rule
    const Ctx = struct {
        display_none: *?bool,
        display_spec: *u32,
        display_doc_order: *u32,
        visibility_hidden: *?bool,
        visibility_spec: *u32,
        visibility_doc_order: *u32,
        opacity_zero: *?bool,
        opacity_spec: *u32,
        opacity_doc_order: *u32,
        el: *Element,
        page: *Page,

        // Returns true if (spec, doc_order) beats (best_spec, best_doc_order)
        fn beats(spec: u32, doc_order: u32, best_spec: u32, best_doc_order: u32) bool {
            return spec > best_spec or (spec == best_spec and doc_order > best_doc_order);
        }

        fn checkRule(ctx: @This(), rule: VisibilityRule) void {
            // Skip rules that can't possibly beat current best for any property
            const dominated = (rule.props.display_none == null or !beats(rule.specificity, rule.doc_order, ctx.display_spec.*, ctx.display_doc_order.*)) and
                (rule.props.visibility_hidden == null or !beats(rule.specificity, rule.doc_order, ctx.visibility_spec.*, ctx.visibility_doc_order.*)) and
                (rule.props.opacity_zero == null or !beats(rule.specificity, rule.doc_order, ctx.opacity_spec.*, ctx.opacity_doc_order.*));
            if (dominated) return;

            if (matchesSelector(ctx.el, rule.selector, ctx.page)) {
                if (rule.props.display_none != null and beats(rule.specificity, rule.doc_order, ctx.display_spec.*, ctx.display_doc_order.*)) {
                    ctx.display_none.* = rule.props.display_none;
                    ctx.display_spec.* = rule.specificity;
                    ctx.display_doc_order.* = rule.doc_order;
                }
                if (rule.props.visibility_hidden != null and beats(rule.specificity, rule.doc_order, ctx.visibility_spec.*, ctx.visibility_doc_order.*)) {
                    ctx.visibility_hidden.* = rule.props.visibility_hidden;
                    ctx.visibility_spec.* = rule.specificity;
                    ctx.visibility_doc_order.* = rule.doc_order;
                }
                if (rule.props.opacity_zero != null and beats(rule.specificity, rule.doc_order, ctx.opacity_spec.*, ctx.opacity_doc_order.*)) {
                    ctx.opacity_zero.* = rule.props.opacity_zero;
                    ctx.opacity_spec.* = rule.specificity;
                    ctx.opacity_doc_order.* = rule.doc_order;
                }
            }
        }
    };
    const ctx = Ctx{
        .display_none = &display_none,
        .display_spec = &display_spec,
        .display_doc_order = &display_doc_order,
        .visibility_hidden = &visibility_hidden,
        .visibility_spec = &visibility_spec,
        .visibility_doc_order = &visibility_doc_order,
        .opacity_zero = &opacity_zero,
        .opacity_spec = &opacity_spec,
        .opacity_doc_order = &opacity_doc_order,
        .el = el,
        .page = self.page,
    };

    if (el.getAttributeSafe(comptime .wrap("id"))) |id| {
        if (self.id_rules.get(id)) |rules| {
            for (rules.items) |rule| {
                ctx.checkRule(rule);
            }
        }
    }

    if (el.getAttributeSafe(comptime .wrap("class"))) |class_attr| {
        var it = std.mem.tokenizeAny(u8, class_attr, &std.ascii.whitespace);
        while (it.next()) |class| {
            if (self.class_rules.get(class)) |rules| {
                for (rules.items) |rule| {
                    ctx.checkRule(rule);
                }
            }
        }
    }

    if (self.tag_rules.get(el.getTag())) |rules| {
        for (rules.items) |rule| {
            ctx.checkRule(rule);
        }
    }

    for (self.other_rules.items) |rule| {
        ctx.checkRule(rule);
    }

    return (display_none orelse false) or (visibility_hidden orelse false) or (opacity_zero orelse false);
}

/// Check if an element has pointer-events:none.
/// Checks inline style first - if set, skips stylesheet lookup.
/// Walks up the tree to check ancestors.
pub fn hasPointerEventsNone(self: *StyleManager, el: *Element, cache: ?*PointerEventsCache) bool {
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
            c.put(self.page.call_arena, elem, pe_none) catch {};
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
    const page = self.page;

    // Check inline style first
    if (getInlineStyleProperty(el, .wrap("pointer-events"), page)) |property| {
        if (property._value.eql(comptime .wrap("none"))) {
            return true;
        }
        return false;
    }

    // Check stylesheet rules
    self.rebuildIfDirty() catch return false;

    var result: ?bool = null;
    var best_spec: u32 = 0;
    var best_doc_order: u32 = 0;

    // Helper to check a single rule
    const checkRule = struct {
        fn beats(spec: u32, doc_order: u32, b_spec: u32, b_doc_order: u32) bool {
            return spec > b_spec or (spec == b_spec and doc_order > b_doc_order);
        }

        fn check(rule: VisibilityRule, res: *?bool, spec: *u32, doc_order: *u32, elem: *Element, p: *Page) void {
            if (rule.props.pointer_events_none == null or !beats(rule.specificity, rule.doc_order, spec.*, doc_order.*)) {
                return;
            }
            if (matchesSelector(elem, rule.selector, p)) {
                res.* = rule.props.pointer_events_none;
                spec.* = rule.specificity;
                doc_order.* = rule.doc_order;
            }
        }
    }.check;

    if (el.getAttributeSafe(comptime .wrap("id"))) |id| {
        if (self.id_rules.get(id)) |rules| {
            for (rules.items) |rule| {
                checkRule(rule, &result, &best_spec, &best_doc_order, el, page);
            }
        }
    }

    if (el.getAttributeSafe(comptime .wrap("class"))) |class_attr| {
        var it = std.mem.tokenizeAny(u8, class_attr, &std.ascii.whitespace);
        while (it.next()) |class| {
            if (self.class_rules.get(class)) |rules| {
                for (rules.items) |rule| {
                    checkRule(rule, &result, &best_spec, &best_doc_order, el, page);
                }
            }
        }
    }

    if (self.tag_rules.get(el.getTag())) |rules| {
        for (rules.items) |rule| {
            checkRule(rule, &result, &best_spec, &best_doc_order, el, page);
        }
    }

    for (self.other_rules.items) |rule| {
        checkRule(rule, &result, &best_spec, &best_doc_order, el, page);
    }

    return result orelse false;
}

// Extracts visibility-relevant rules from a CSS rule.
// Creates one VisibilityRule per selector (not per selector list) so each has correct specificity.
// Buckets rules by their rightmost selector part for fast lookup.
fn addRule(self: *StyleManager, style_rule: *CSSStyleRule) !void {
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
    const selectors = SelectorParser.parseList(self.arena, selector_text, self.page) catch return;
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
            .specificity = computeSpecificity(selector),
            .doc_order = self.next_doc_order,
        };
        self.next_doc_order += 1;

        // Add to appropriate bucket
        switch (bucket_key) {
            .id => |id| {
                const gop = try self.id_rules.getOrPut(self.arena, id);
                if (!gop.found_existing) gop.value_ptr.* = .empty;
                try gop.value_ptr.append(self.arena, rule);
            },
            .class => |class| {
                const gop = try self.class_rules.getOrPut(self.arena, class);
                if (!gop.found_existing) gop.value_ptr.* = .empty;
                try gop.value_ptr.append(self.arena, rule);
            },
            .tag => |tag| {
                const gop = try self.tag_rules.getOrPut(self.arena, tag);
                if (!gop.found_existing) gop.value_ptr.* = .empty;
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

/// Returns the bucket key for a compound selector, or null if the selector
/// ends with a dynamic pseudo-class that we should skip (hover, active, focus, etc.)
fn getBucketKey(compound: Selector.Compound) ?BucketKey {
    // Iterate parts in reverse to find the most specific bucketing key
    // Priority: id > class > tag > other
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

fn matchesSelector(el: *Element, selector: Selector.Selector, page: *Page) bool {
    const node = el.asNode();
    return SelectorList.matches(node, selector, node, page);
}

const VisibilityProperties = struct {
    display_none: ?bool = null,
    visibility_hidden: ?bool = null,
    opacity_zero: ?bool = null,
    pointer_events_none: ?bool = null,

    // returne true if any field in VisibilityProperties is not null
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

    // Packed specificity: (id_count << 20) | (class_count << 10) | element_count
    specificity: u32,

    // Document order for tie-breaking equal specificity (higher = later in document)
    doc_order: u32,
};

const CheckVisibilityOptions = struct {
    check_opacity: bool = false,
    check_visibility: bool = false,
};

// Inline styles always win over stylesheets - use max u32 as sentinel
const INLINE_SPECIFICITY: u32 = std.math.maxInt(u32);

fn getInlineStyleProperty(el: *Element, property_name: String, page: *Page) ?*CSSStyleProperty {
    const style = el.getOrCreateStyle(page) catch |err| {
        log.err(.browser, "StyleManager getOrCreateStyle", .{ .err = err });
        return null;
    };
    return style.asCSSStyleDeclaration().findProperty(property_name);
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
