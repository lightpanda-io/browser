// Copyright (C) 2023-2025  Lightpanda (Selecy SAS)
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

const Page = @import("../../Page.zig");

const Node = @import("../Node.zig");
const Part = @import("Selector.zig").Part;
const Selector = @import("Selector.zig");
const TreeWalker = @import("../TreeWalker.zig").Full;
const GenericIterator = @import("../collections/iterator.zig").Entry;

const Allocator = std.mem.Allocator;

const List = @This();

_nodes: []const *Node,
_arena: Allocator,
// For the [somewhat common] case where we just have an #id selector
// we can avoid allocating a slice and just use this.
_single_node: [1]*Node = undefined,

pub const EntryIterator = GenericIterator(Iterator, null);
pub const KeyIterator = GenericIterator(Iterator, "0");
pub const ValueIterator = GenericIterator(Iterator, "1");

pub fn deinit(self: *const List, page: *Page) void {
    page.releaseArena(self._arena);
}

pub fn collect(
    allocator: std.mem.Allocator,
    root: *Node,
    selector: Selector.Selector,
    nodes: *std.AutoArrayHashMapUnmanaged(*Node, void),
    page: *Page,
) !void {
    if (optimizeSelector(root, &selector, page)) |result| {
        var tw = TreeWalker.init(result.root, .{});
        if (result.exclude_root) {
            _ = tw.next();
        }

        while (tw.next()) |node| {
            if (matches(node, result.selector, root, page)) {
                try nodes.put(allocator, node, {});
            }
        }
    }
}

// used internally to find the first match
pub fn initOne(root: *Node, selector: Selector.Selector, page: *Page) ?*Node {
    const result = optimizeSelector(root, &selector, page) orelse return null;

    var tw = TreeWalker.init(result.root, .{});
    if (result.exclude_root) {
        _ = tw.next();
    }
    while (tw.next()) |node| {
        if (matches(node, result.selector, root, page)) {
            return node;
        }
    }
    return null;
}

const OptimizeResult = struct {
    root: *Node,
    exclude_root: bool,
    selector: Selector.Selector,
};

fn optimizeSelector(root: *Node, selector: *const Selector.Selector, page: *Page) ?OptimizeResult {
    const anchor = findIdSelector(selector) orelse return .{
        .root = root,
        .selector = selector.*,
        // Always exclude root - querySelector only returns descendants
        .exclude_root = true,
    };

    // If we have a selector with an #id, we can make a pretty easy and
    // powerful optimization. We can use the node for that id as the new
    // root, and only match the selectors after it. However, we'll need to
    // make sure that node matches the selectors before it (the prefix).
    const id = anchor.id;
    const segment_index = anchor.segment_index;

    // Look up the element by ID (O(1) hash map lookup)
    const id_element = page.getElementByIdFromNode(root, id) orelse return null;
    const id_node = id_element.asNode();

    if (!root.contains(id_node)) {
        return null;
    }

    // If the ID is in the first compound
    if (segment_index == null) {
        // Check if there are any segments after the ID
        if (selector.segments.len == 0) {
            // Just '#id', return the node itself
            return .{
                .root = id_node,
                .selector = .{
                    .first = selector.first,
                    .segments = selector.segments,
                },
                .exclude_root = false,
            };
        }

        // Check the combinator of the first segment
        const first_combinator = selector.segments[0].combinator;
        if (first_combinator == .next_sibling or first_combinator == .subsequent_sibling) {
            // Cannot optimize: matches are siblings, not descendants of the ID node
            // Fall back to searching the entire tree
            return .{
                .root = root,
                .selector = selector.*,
                .exclude_root = true,
            };
        }

        // Safe to optimize for descendant/child combinators
        return .{
            .root = id_node,
            .selector = .{
                .first = selector.first,
                .segments = selector.segments,
            },
            .exclude_root = true,
        };
    }

    // ID is in one of the segments
    const seg_idx = segment_index.?;

    // Check if there are segments after the ID
    if (seg_idx + 1 < selector.segments.len) {
        // Check the combinator of the segment after the ID
        const next_combinator = selector.segments[seg_idx + 1].combinator;
        if (next_combinator == .next_sibling or next_combinator == .subsequent_sibling) {
            // Cannot optimize: matches are siblings, not descendants
            return .{
                .root = root,
                .selector = selector.*,
                .exclude_root = true,
            };
        }
    }

    // If there's a prefix selector, we need to verify that the id_node's
    // ancestors match it. We construct a selector up to and including the ID segment.
    const prefix_selector = Selector.Selector{
        .first = selector.first,
        .segments = selector.segments[0 .. seg_idx + 1],
    };

    if (!matches(id_node, prefix_selector, id_node, page)) {
        return null;
    }

    // Return a selector starting from the segments after the ID
    return .{
        .root = id_node,
        .selector = .{
            .first = selector.segments[seg_idx].compound,
            .segments = selector.segments[seg_idx + 1 ..],
        },
        .exclude_root = false,
    };
}

pub fn getLength(self: *const List) usize {
    return self._nodes.len;
}

pub fn keys(self: *List, page: *Page) !*KeyIterator {
    return .init(.{ .list = self }, page);
}

pub fn values(self: *List, page: *Page) !*ValueIterator {
    return .init(.{ .list = self }, page);
}

pub fn entries(self: *List, page: *Page) !*EntryIterator {
    return .init(.{ .list = self }, page);
}

pub fn getAtIndex(self: *const List, index: usize) !?*Node {
    if (index >= self._nodes.len) {
        return null;
    }
    return self._nodes[index];
}

const NodeList = @import("../collections/NodeList.zig");
pub fn runtimeGenericWrap(self: *List, _: *const Page) !*NodeList {
    const nl = try self._arena.create(NodeList);
    nl.* = .{
        ._data = .{ .selector_list = self },
    };
    return nl;
}

const IdAnchor = struct {
    id: []const u8,
    segment_index: ?usize, // null if ID is in first compound
};

// Rightmost (last) is best because it minimizes the subtree we need to search
fn findIdSelector(selector: *const Selector.Selector) ?IdAnchor {
    // Check segments from right to left
    var i = selector.segments.len;
    while (i > 0) {
        i -= 1;
        const compound = selector.segments[i].compound.parts;
        if (compound.len != 1) {
            continue;
        }
        const part = compound[0];
        if (part == .id) {
            return .{ .id = part.id, .segment_index = i };
        }
    }

    // Check the first compound
    if (selector.first.parts.len == 1) {
        const part = selector.first.parts[0];
        if (part == .id) {
            return .{ .id = part.id, .segment_index = null };
        }
    }

    return null;
}

pub fn matches(node: *Node, selector: Selector.Selector, scope: *Node, page: *Page) bool {
    const el = node.is(Node.Element) orelse return false;

    if (selector.segments.len == 0) {
        return matchesCompound(el, selector.first, scope, page);
    }

    const last_segment = selector.segments[selector.segments.len - 1];
    if (!matchesCompound(el, last_segment.compound, scope, page)) {
        return false;
    }

    return matchSegments(node, selector, selector.segments.len - 1, null, scope, page);
}

// Match segments backward, with support for backtracking on subsequent_sibling
fn matchSegments(node: *Node, selector: Selector.Selector, segment_index: usize, root: ?*Node, scope: *Node, page: *Page) bool {
    const segment = selector.segments[segment_index];
    const target_compound = if (segment_index == 0)
        selector.first
    else
        selector.segments[segment_index - 1].compound;

    const matched: ?*Node = switch (segment.combinator) {
        .descendant => matchDescendant(node, target_compound, root, scope, page),
        .child => matchChild(node, target_compound, root, scope, page),
        .next_sibling => matchNextSibling(node, target_compound, scope, page),
        .subsequent_sibling => {
            // For subsequent_sibling, try all matching siblings with backtracking
            var sibling = node.previousSibling();
            while (sibling) |s| {
                const sibling_el = s.is(Node.Element) orelse {
                    sibling = s.previousSibling();
                    continue;
                };

                if (matchesCompound(sibling_el, target_compound, scope, page)) {
                    // If we're at the first segment, we found a match
                    if (segment_index == 0) {
                        return true;
                    }
                    // Try to match remaining segments from this sibling
                    if (matchSegments(s, selector, segment_index - 1, root, scope, page)) {
                        return true;
                    }
                    // This sibling didn't work, try the next one
                }
                sibling = s.previousSibling();
            }
            return false;
        },
    };

    // For non-subsequent_sibling combinators, matched is either the node or null
    if (segment.combinator != .subsequent_sibling) {
        const current = matched orelse return false;
        if (segment_index == 0) {
            return true;
        }
        return matchSegments(current, selector, segment_index - 1, root, scope, page);
    }

    // subsequent_sibling already handled its recursion above
    return false;
}

// Find an ancestor that matches the compound (any distance up the tree)
fn matchDescendant(node: *Node, compound: Selector.Compound, root: ?*Node, scope: *Node, page: *Page) ?*Node {
    var current = node._parent;

    while (current) |ancestor| {
        if (ancestor.is(Node.Element)) |ancestor_el| {
            if (matchesCompound(ancestor_el, compound, scope, page)) {
                return ancestor;
            }
        }

        // Stop if we've reached the boundary
        if (root) |boundary| {
            if (ancestor == boundary) {
                return null;
            }
        }

        current = ancestor._parent;
    }

    return null;
}

// Find the direct parent if it matches the compound
fn matchChild(node: *Node, compound: Selector.Compound, root: ?*Node, scope: *Node, page: *Page) ?*Node {
    const parent = node._parent orelse return null;

    // Don't match beyond the root boundary
    // If there's a boundary, check if parent is outside (an ancestor of) the boundary
    if (root) |boundary| {
        if (!boundary.contains(parent)) {
            return null;
        }
    }

    const parent_el = parent.is(Node.Element) orelse return null;

    if (matchesCompound(parent_el, compound, scope, page)) {
        return parent;
    }

    return null;
}

// Find the immediately preceding sibling if it matches the compound
fn matchNextSibling(node: *Node, compound: Selector.Compound, scope: *Node, page: *Page) ?*Node {
    var sibling = node.previousSibling();

    // For next_sibling (+), we need the immediately preceding element sibling
    while (sibling) |s| {
        const sibling_el = s.is(Node.Element) orelse {
            // Skip non-element nodes
            sibling = s.previousSibling();
            continue;
        };

        // Found an element - check if it matches
        if (matchesCompound(sibling_el, compound, scope, page)) {
            return s;
        }
        // we found an element, it wasn't a match, we're done
        return null;
    }

    return null;
}

// Find any preceding sibling that matches the compound
fn matchSubsequentSibling(node: *Node, compound: Selector.Compound, scope: *Node, page: *Page) ?*Node {
    var sibling = node.previousSibling();

    // For subsequent_sibling (~), check all preceding element siblings
    while (sibling) |s| {
        const sibling_el = s.is(Node.Element) orelse {
            // Skip non-element nodes
            sibling = s.previousSibling();
            continue;
        };

        if (matchesCompound(sibling_el, compound, scope, page)) {
            return s;
        }

        sibling = s.previousSibling();
    }

    return null;
}

fn matchesCompound(el: *Node.Element, compound: Selector.Compound, scope: *Node, page: *Page) bool {
    // For compound selectors, ALL parts must match
    for (compound.parts) |part| {
        if (!matchesPart(el, part, scope, page)) {
            return false;
        }
    }
    return true;
}

fn matchesPart(el: *Node.Element, part: Part, scope: *Node, page: *Page) bool {
    switch (part) {
        .id => |id| {
            const element_id = el.getAttributeSafe(comptime .wrap("id")) orelse return false;
            return std.mem.eql(u8, element_id, id);
        },
        .class => |cls| {
            const class_attr = el.getAttributeSafe(comptime .wrap("class")) orelse return false;
            return Selector.classAttributeContains(class_attr, cls);
        },
        .tag => |tag| {
            // Optimized: compare enum directly
            return el.getTag() == tag;
        },
        .tag_name => |tag_name| {
            // Fallback for custom/unknown tags
            // Both are lowercase, so we can use fast string comparison
            const element_tag = el.getTagNameLower();
            return std.mem.eql(u8, element_tag, tag_name);
        },
        .universal => return true,
        .pseudo_class => |pseudo| return matchesPseudoClass(el, pseudo, scope, page),
        .attribute => |attr| return matchesAttribute(el, attr),
    }
}

fn matchesAttribute(el: *Node.Element, attr: Selector.Attribute) bool {
    const value = el.getAttributeSafe(attr.name) orelse {
        return false;
    };

    switch (attr.matcher) {
        .presence => return true,
        .exact => |expected| {
            return if (attr.case_insensitive)
                std.ascii.eqlIgnoreCase(value, expected)
            else
                std.mem.eql(u8, value, expected);
        },
        .substring => |expected| {
            return if (attr.case_insensitive)
                std.ascii.indexOfIgnoreCase(value, expected) != null
            else
                std.mem.indexOf(u8, value, expected) != null;
        },
        .starts_with => |expected| {
            return if (attr.case_insensitive)
                std.ascii.startsWithIgnoreCase(value, expected)
            else
                std.mem.startsWith(u8, value, expected);
        },
        .ends_with => |expected| {
            return if (attr.case_insensitive)
                std.ascii.endsWithIgnoreCase(value, expected)
            else
                std.mem.endsWith(u8, value, expected);
        },
        .word => |expected| {
            // Space-separated word match (like class names)
            var it = std.mem.tokenizeAny(u8, value, &std.ascii.whitespace);
            while (it.next()) |word| {
                const same = if (attr.case_insensitive)
                    std.ascii.eqlIgnoreCase(word, expected)
                else
                    std.mem.eql(u8, word, expected);

                if (same) return true;
            }
            return false;
        },
        .prefix_dash => |expected| {
            // Matches value or value- prefix (for language codes like en, en-US)
            if (attr.case_insensitive) {
                if (std.ascii.eqlIgnoreCase(value, expected)) return true;
                if (value.len > expected.len and value[expected.len] == '-') {
                    return std.ascii.eqlIgnoreCase(value[0..expected.len], expected);
                }
            } else {
                if (std.mem.eql(u8, value, expected)) return true;
                if (value.len > expected.len and value[expected.len] == '-') {
                    return std.mem.eql(u8, value[0..expected.len], expected);
                }
            }
            return false;
        },
    }
}

fn attributeContainsWord(value: []const u8, word: []const u8) bool {
    var remaining = value;
    while (remaining.len > 0) {
        const trimmed = std.mem.trimLeft(u8, remaining, &std.ascii.whitespace);
        if (trimmed.len == 0) return false;

        const end = std.mem.indexOfAny(u8, trimmed, &std.ascii.whitespace) orelse trimmed.len;
        const current_word = trimmed[0..end];

        if (std.mem.eql(u8, current_word, word)) {
            return true;
        }

        if (end >= trimmed.len) break;
        remaining = trimmed[end..];
    }
    return false;
}

fn matchesPseudoClass(el: *Node.Element, pseudo: Selector.PseudoClass, scope: *Node, page: *Page) bool {
    const node = el.asNode();
    switch (pseudo) {
        // State pseudo-classes
        .modal => return false,
        .checked => {
            const input = el.is(Node.Element.Html.Input) orelse return false;
            return input.getChecked();
        },
        .disabled => {
            return el.getAttributeSafe(comptime .wrap("disabled")) != null;
        },
        .enabled => {
            return el.getAttributeSafe(comptime .wrap("disabled")) == null;
        },
        .indeterminate => {
            const input = el.is(Node.Element.Html.Input) orelse return false;
            return switch (input._input_type) {
                .checkbox => input.getIndeterminate(),
                else => false,
            };
        },

        // Form validation
        .valid => {
            if (el.is(Node.Element.Html.Input)) |input| {
                return switch (input._input_type) {
                    .hidden, .submit, .reset, .button => false,
                    else => !input.getRequired() or input.getValue().len > 0,
                };
            }
            if (el.is(Node.Element.Html.Select)) |select| {
                return !select.getRequired() or select.getValue(page).len > 0;
            }
            if (el.is(Node.Element.Html.Form) != null or el.is(Node.Element.Html.FieldSet) != null) {
                return !hasInvalidDescendant(node, page);
            }
            return false;
        },
        .invalid => {
            if (el.is(Node.Element.Html.Input)) |input| {
                return switch (input._input_type) {
                    .hidden, .submit, .reset, .button => false,
                    else => input.getRequired() and input.getValue().len == 0,
                };
            }
            if (el.is(Node.Element.Html.Select)) |select| {
                return select.getRequired() and select.getValue(page).len == 0;
            }
            if (el.is(Node.Element.Html.Form) != null or el.is(Node.Element.Html.FieldSet) != null) {
                return hasInvalidDescendant(node, page);
            }
            return false;
        },
        .required => {
            return el.getAttributeSafe(comptime .wrap("required")) != null;
        },
        .optional => {
            return el.getAttributeSafe(comptime .wrap("required")) == null;
        },
        .in_range => return false,
        .out_of_range => return false,
        .placeholder_shown => return false,
        .read_only => {
            return el.getAttributeSafe(comptime .wrap("readonly")) != null;
        },
        .read_write => {
            return el.getAttributeSafe(comptime .wrap("readonly")) == null;
        },
        .default => return false,

        // User interaction
        .hover => return false,
        .active => return false,
        .focus => {
            const active = page.document._active_element orelse return false;
            return active == el;
        },
        .focus_within => {
            const active = page.document._active_element orelse return false;
            return node.contains(active.asNode());
        },
        .focus_visible => return false,

        // Link states
        .link => return false,
        .visited => return false,
        .any_link => {
            if (el.getTag() != .anchor) return false;
            return el.getAttributeSafe(comptime .wrap("href")) != null;
        },
        .target => {
            const element_id = el.getAttributeSafe(comptime .wrap("id")) orelse return false;
            const location = page.document._location orelse return false;
            const hash = location.getHash();
            if (hash.len <= 1) return false;
            return std.mem.eql(u8, element_id, hash[1..]);
        },

        // Tree structural
        .root => {
            const parent = node.parentNode() orelse return false;
            return parent._type == .document;
        },
        .scope => {
            // :scope matches the reference element (querySelector root)
            return node == scope;
        },
        .empty => {
            return node.firstChild() == null;
        },
        .first_child => return isFirstChild(el),
        .last_child => return isLastChild(el),
        .only_child => return isFirstChild(el) and isLastChild(el),
        .first_of_type => return isFirstOfType(el),
        .last_of_type => return isLastOfType(el),
        .only_of_type => return isFirstOfType(el) and isLastOfType(el),
        .nth_child => |pattern| return matchesNthChild(el, pattern),
        .nth_last_child => |pattern| return matchesNthLastChild(el, pattern),
        .nth_of_type => |pattern| return matchesNthOfType(el, pattern),
        .nth_last_of_type => |pattern| return matchesNthLastOfType(el, pattern),

        // Custom elements
        .defined => {
            const tag_name = el.getTagNameLower();
            if (std.mem.indexOfScalar(u8, tag_name, '-') == null) return true;
            const registry = &page.window._custom_elements;
            return registry.get(tag_name) != null;
        },

        // Functional
        .lang => return false,
        .not => |selectors| {
            for (selectors) |selector| {
                if (matches(node, selector, scope, page)) {
                    return false;
                }
            }
            return true;
        },
        .is => |selectors| {
            for (selectors) |selector| {
                if (matches(node, selector, scope, page)) {
                    return true;
                }
            }
            return false;
        },
        .where => |selectors| {
            for (selectors) |selector| {
                if (matches(node, selector, scope, page)) {
                    return true;
                }
            }
            return false;
        },
        .has => |selectors| {
            for (selectors) |selector| {
                var child = node.firstChild();
                while (child) |c| {
                    const child_el = c.is(Node.Element) orelse {
                        child = c.nextSibling();
                        continue;
                    };

                    if (matches(child_el.asNode(), selector, scope, page)) {
                        return true;
                    }

                    if (matchesHasDescendant(child_el, selector, scope, page)) {
                        return true;
                    }

                    child = c.nextSibling();
                }
            }
            return false;
        },
    }
}

fn matchesHasDescendant(el: *Node.Element, selector: Selector.Selector, scope: *Node, page: *Page) bool {
    var child = el.asNode().firstChild();
    while (child) |c| {
        const child_el = c.is(Node.Element) orelse {
            child = c.nextSibling();
            continue;
        };

        if (matches(child_el.asNode(), selector, scope, page)) {
            return true;
        }

        if (matchesHasDescendant(child_el, selector, scope, page)) {
            return true;
        }

        child = c.nextSibling();
    }
    return false;
}

fn hasInvalidDescendant(parent: *Node, page: *Page) bool {
    var child = parent.firstChild();
    while (child) |c| {
        if (c.is(Node.Element)) |child_el| {
            if (child_el.is(Node.Element.Html.Input)) |input| {
                const invalid = switch (input._input_type) {
                    .hidden, .submit, .reset, .button => false,
                    else => input.getRequired() and input.getValue().len == 0,
                };
                if (invalid) return true;
            } else if (child_el.is(Node.Element.Html.Select)) |select| {
                if (select.getRequired() and select.getValue(page).len == 0) return true;
            }
        }
        if (hasInvalidDescendant(c, page)) return true;
        child = c.nextSibling();
    }
    return false;
}

fn isFirstChild(el: *Node.Element) bool {
    const node = el.asNode();
    var sibling = node.previousSibling();

    // Check if there are any element siblings before this one
    while (sibling) |s| {
        if (s.is(Node.Element)) |_| {
            return false;
        }
        sibling = s.previousSibling();
    }

    return true;
}

fn isLastChild(el: *Node.Element) bool {
    const node = el.asNode();
    var sibling = node.nextSibling();

    // Check if there are any element siblings after this one
    while (sibling) |s| {
        if (s.is(Node.Element)) |_| {
            return false;
        }
        sibling = s.nextSibling();
    }

    return true;
}

fn isFirstOfType(el: *Node.Element) bool {
    const tag = el.getTag();
    const node = el.asNode();
    var sibling = node.previousSibling();

    // Check if there are any element siblings of the same type before this one
    while (sibling) |s| {
        const sibling_el = s.is(Node.Element) orelse {
            sibling = s.previousSibling();
            continue;
        };

        if (sibling_el.getTag() == tag) {
            return false;
        }

        sibling = s.previousSibling();
    }

    return true;
}

fn isLastOfType(el: *Node.Element) bool {
    const tag = el.getTag();
    const node = el.asNode();
    var sibling = node.nextSibling();

    // Check if there are any element siblings of the same type after this one
    while (sibling) |s| {
        const sibling_el = s.is(Node.Element) orelse {
            sibling = s.nextSibling();
            continue;
        };

        if (sibling_el.getTag() == tag) {
            return false;
        }

        sibling = s.nextSibling();
    }

    return true;
}

fn matchesNthChild(el: *Node.Element, pattern: Selector.NthPattern) bool {
    const index = getChildIndex(el) orelse return false;
    return matchesNthPattern(index, pattern);
}

fn matchesNthLastChild(el: *Node.Element, pattern: Selector.NthPattern) bool {
    const index = getChildIndexFromEnd(el) orelse return false;
    return matchesNthPattern(index, pattern);
}

fn matchesNthOfType(el: *Node.Element, pattern: Selector.NthPattern) bool {
    const index = getTypeIndex(el) orelse return false;
    return matchesNthPattern(index, pattern);
}

fn matchesNthLastOfType(el: *Node.Element, pattern: Selector.NthPattern) bool {
    const index = getTypeIndexFromEnd(el) orelse return false;
    return matchesNthPattern(index, pattern);
}

fn getChildIndex(el: *Node.Element) ?usize {
    const node = el.asNode();
    var index: usize = 1;
    var sibling = node.previousSibling();

    while (sibling) |s| {
        if (s.is(Node.Element)) |_| {
            index += 1;
        }
        sibling = s.previousSibling();
    }

    return index;
}

fn getChildIndexFromEnd(el: *Node.Element) ?usize {
    const node = el.asNode();
    var index: usize = 1;
    var sibling = node.nextSibling();

    while (sibling) |s| {
        if (s.is(Node.Element)) |_| {
            index += 1;
        }
        sibling = s.nextSibling();
    }

    return index;
}

fn getTypeIndex(el: *Node.Element) ?usize {
    const tag = el.getTag();
    const node = el.asNode();

    var index: usize = 1;
    var sibling = node.previousSibling();

    while (sibling) |s| {
        const sibling_el = s.is(Node.Element) orelse {
            sibling = s.previousSibling();
            continue;
        };

        if (sibling_el.getTag() == tag) {
            index += 1;
        }

        sibling = s.previousSibling();
    }

    return index;
}

fn getTypeIndexFromEnd(el: *Node.Element) ?usize {
    const tag = el.getTag();
    const node = el.asNode();

    var index: usize = 1;
    var sibling = node.nextSibling();

    while (sibling) |s| {
        const sibling_el = s.is(Node.Element) orelse {
            sibling = s.nextSibling();
            continue;
        };

        if (sibling_el.getTag() == tag) {
            index += 1;
        }

        sibling = s.nextSibling();
    }

    return index;
}

fn matchesNthPattern(index: usize, pattern: Selector.NthPattern) bool {
    const a = pattern.a;
    const b = pattern.b;

    // Special case: a=0 means we're matching a specific index
    if (a == 0) {
        return @as(i32, @intCast(index)) == b;
    }

    // For an+b pattern, we need to find if there's an integer n >= 0
    // such that an + b = index
    // Rearranging: n = (index - b) / a
    const index_i = @as(i32, @intCast(index));
    const diff = index_i - b;

    // Check if (index - b) is divisible by a
    if (@rem(diff, a) != 0) {
        return false;
    }

    const n = @divTrunc(diff, a);

    // n must be non-negative
    return n >= 0;
}

const Iterator = struct {
    index: u32 = 0,
    list: *List,

    const Entry = struct { u32, *Node };

    pub fn next(self: *Iterator, _: *const Page) ?Entry {
        const index = self.index;
        if (index >= self.list._nodes.len) {
            return null;
        }
        self.index = index + 1;
        return .{ index, self.list._nodes[index] };
    }
};
