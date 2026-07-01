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
const lp = @import("lightpanda");

const Node = @import("../Node.zig");
const Frame = @import("../../Frame.zig");

const Parser = @import("Parser.zig");
pub const List = @import("List.zig");

const String = lp.String;
const Allocator = std.mem.Allocator;

// translate a Selector error to a DOMException known type.
pub fn mapErrorToDOM(err: anyerror) anyerror {
    return switch (err) {
        error.InvalidSelector,
        error.InvalidAttributeSelector,
        error.InvalidIDSelector,
        error.InvalidClassSelector,
        error.UnknownPseudoClass,
        error.InvalidTagSelector,
        error.InvalidPseudoClass,
        error.InvalidNthPattern,
        => error.SyntaxError,
        else => err,
    };
}

pub fn parseLeaky(arena: Allocator, input: []const u8) !Parsed {
    if (input.len == 0) {
        return error.SyntaxError;
    }
    return .{ .selectors = try Parser.parseList(arena, input) };
}

/// One-off synthesized selectors use the `*Uncached` variants instead.
fn cachedParse(frame: *Frame, input: []const u8) ![]const Selector {
    return frame._session.browser.selector_cache.parse(input);
}

/// On the Browser because a parsed selector references no Frame/Context, so
/// entries survive navigation. Per-entry arena so eviction can free one entry.
pub const Cache = struct {
    // Caps retained memory, not correctness; oldest entry evicted on overflow.
    const max_entries = 1024;

    allocator: Allocator,
    map: std.StringArrayHashMapUnmanaged(Entry) = .empty,

    const Entry = struct {
        arena: std.heap.ArenaAllocator,
        selectors: []const Selector,
    };

    pub fn init(allocator: Allocator) Cache {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Cache) void {
        for (self.map.values()) |*entry| {
            entry.arena.deinit();
        }
        self.map.deinit(self.allocator);
    }

    fn parse(self: *Cache, input: []const u8) ![]const Selector {
        if (input.len == 0) {
            return error.SyntaxError;
        }
        if (self.map.get(input)) |entry| {
            return entry.selectors;
        }

        // The AST borrows slices of its input, so dupe the key into the arena.
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const entry_arena = arena.allocator();
        const owned = try entry_arena.dupe(u8, input);
        const selectors = try Parser.parseList(entry_arena, owned);

        if (self.map.count() >= max_entries) {
            self.evictOldest();
        }
        try self.map.put(self.allocator, owned, .{ .arena = arena, .selectors = selectors });
        return selectors;
    }

    // Insertion order is preserved, so index 0 is the oldest.
    fn evictOldest(self: *Cache) void {
        const key = self.map.keys()[0];
        var arena = self.map.values()[0].arena;
        std.debug.assert(self.map.orderedRemove(key));
        arena.deinit();
    }
};

fn collectAll(arena: Allocator, selectors: []const Selector, root: *Node, frame: *Frame) !*List {
    var nodes: std.AutoArrayHashMapUnmanaged(*Node, void) = .empty;
    for (selectors) |selector| {
        try List.collect(arena, root, selector, &nodes, frame);
    }

    const list = try arena.create(List);
    list.* = .{
        ._arena = arena,
        ._nodes = nodes.keys(),
    };
    return list;
}

fn matchesAny(selectors: []const Selector, el: *Node.Element, scope: *Node, frame: *Frame) bool {
    for (selectors) |selector| {
        if (List.matches(el.asNode(), selector, scope, frame)) {
            return true;
        }
    }
    return false;
}

pub fn querySelector(root: *Node, input: []const u8, frame: *Frame) !?*Node.Element {
    const parsed = Parsed{ .selectors = try cachedParse(frame, input) };
    return parsed.query(root, frame);
}

pub fn querySelectorAll(root: *Node, input: []const u8, frame: *Frame) !*List {
    const arena = try frame.getArena(.small, "querySelectorAll");
    errdefer frame.releaseArena(arena);
    return collectAll(arena, try cachedParse(frame, input), root, frame);
}

pub fn matches(el: *Node.Element, input: []const u8, frame: *Frame) !bool {
    return matchesAny(try cachedParse(frame, input), el, el.asNode(), frame);
}

// Like matches, but allows the caller to specify a scope node distinct from el.
// Used by closest() so that :scope always refers to the original context element.
pub fn matchesWithScope(el: *Node.Element, input: []const u8, scope: *Node.Element, frame: *Frame) !bool {
    return matchesAny(try cachedParse(frame, input), el, scope.asNode(), frame);
}

/// Uncached counterparts for one-off selectors (SelectorPath): parse into
/// `arena` instead of caching. querySelectorAllUncached takes no arena — it uses
/// the pooled arena backing its List.
pub fn querySelectorUncached(arena: Allocator, root: *Node, input: []const u8, frame: *Frame) !?*Node.Element {
    if (input.len == 0) {
        return error.SyntaxError;
    }
    const parsed = Parsed{ .selectors = try Parser.parseList(arena, input) };
    return parsed.query(root, frame);
}

pub fn querySelectorAllUncached(root: *Node, input: []const u8, frame: *Frame) !*List {
    if (input.len == 0) {
        return error.SyntaxError;
    }
    const arena = try frame.getArena(.small, "querySelectorAllUncached");
    errdefer frame.releaseArena(arena);
    return collectAll(arena, try Parser.parseList(arena, input), root, frame);
}

pub fn matchesUncached(arena: Allocator, el: *Node.Element, input: []const u8, frame: *Frame) !bool {
    if (input.len == 0) {
        return error.SyntaxError;
    }
    return matchesAny(try Parser.parseList(arena, input), el, el.asNode(), frame);
}

pub fn classAttributeContains(class_attr: []const u8, class_name: []const u8) bool {
    if (class_name.len == 0 or class_name.len > class_attr.len) return false;

    var search = class_attr;
    while (std.mem.indexOf(u8, search, class_name)) |pos| {
        const is_start = pos == 0 or search[pos - 1] == ' ';
        const end = pos + class_name.len;
        const is_end = end == search.len or search[end] == ' ';

        if (is_start and is_end) return true;

        search = search[pos + 1 ..];
    }
    return false;
}

pub const Part = union(enum) {
    id: []const u8,
    class: []const u8,
    tag: Node.Element.Tag, // optimized, for known tags
    tag_name: []const u8, // fallback for custom/unknown tags
    universal, // '*' any element
    pseudo_class: PseudoClass,
    attribute: Attribute,
};

pub const Attribute = struct {
    name: String,
    matcher: AttributeMatcher,
    case_insensitive: bool,
};

pub const AttributeMatcher = union(enum) {
    presence,
    exact: []const u8,
    word: []const u8,
    prefix_dash: []const u8,
    starts_with: []const u8,
    ends_with: []const u8,
    substring: []const u8,
};

pub const PseudoClass = union(enum) {
    // State pseudo-classes
    modal,
    popover_open,
    checked,
    disabled,
    enabled,
    indeterminate,

    // Form validation
    valid,
    invalid,
    required,
    optional,
    in_range,
    out_of_range,
    placeholder_shown,
    read_only,
    read_write,
    default,

    // User interaction
    hover,
    active,
    focus,
    focus_within,
    focus_visible,

    // Link states
    link,
    visited,
    any_link,
    target,

    // Tree structural
    root,
    scope,
    empty,
    first_child,
    last_child,
    only_child,
    first_of_type,
    last_of_type,
    only_of_type,
    nth_child: NthPattern,
    nth_last_child: NthPattern,
    nth_of_type: NthPattern,
    nth_last_of_type: NthPattern,

    // Custom elements
    defined,

    // Functional
    lang: []const u8,
    not: []const Selector, // :not() - CSS Level 4: supports full selectors and comma-separated lists
    is: []const Selector, // :is() - matches any of the selectors
    where: []const Selector, // :where() - like :is() but with zero specificity
    has: []const Selector, // :has() - element containing descendants matching selector
};

pub const NthPattern = struct {
    a: i32, // coefficient (e.g., 2 in "2n+1")
    b: i32, // offset (e.g., 1 in "2n+1")

    // Common patterns:
    // odd: a=2, b=1
    // even: a=2, b=0
    // 3n+1: a=3, b=1
    // 5: a=0, b=5
};

// Combinator represents the relationship between two compound selectors
pub const Combinator = enum {
    descendant, // ' ' - any descendant
    child, // '>' - direct child
    next_sibling, // '+' - immediately following sibling
    subsequent_sibling, // '~' - any following sibling
};

// A compound selector is multiple parts that all match the same element
//   "div.class#id" -> [tag(div), class("class"), id("id")]
pub const Compound = struct {
    parts: []const Part,

    pub fn format(self: Compound, writer: *std.Io.Writer) !void {
        for (self.parts) |part| switch (part) {
            .id => |val| {
                try writer.writeByte('#');
                try writer.writeAll(val);
            },
            .class => |val| {
                try writer.writeByte('.');
                try writer.writeAll(val);
            },
            .tag => |val| try writer.writeAll(@tagName(val)),
            .tag_name => |val| try writer.writeAll(val),
            .universal => try writer.writeByte('*'),
            .pseudo_class => |val| {
                try writer.writeByte(':');
                try writer.writeAll(@tagName(val));
            },
            .attribute => {
                try writer.writeAll("TODO");
            },
        };
    }
};

// A segment represents a compound selector with the combinator that precedes it
pub const Segment = struct {
    compound: Compound,
    combinator: Combinator,

    pub fn format(self: Segment, writer: *std.Io.Writer) !void {
        switch (self.combinator) {
            .descendant => try writer.writeByte(' '),
            .child => try writer.writeAll(" > "),
            .next_sibling => try writer.writeAll(" + "),
            .subsequent_sibling => try writer.writeAll(" ~ "),
        }
        return self.compound.format(writer);
    }
};

// A full selector is the first compound plus subsequent segments
//   "div > p + span" -> { first: [tag(div)], segments: [{child, [tag(p)]}, {next_sibling, [tag(span)]}] }
pub const Selector = struct {
    first: Compound,
    segments: []const Segment,

    pub fn format(self: Selector, writer: *std.Io.Writer) !void {
        try self.first.format(writer);
        for (self.segments) |segment| {
            try segment.format(writer);
        }
    }
};

pub const Parsed = struct {
    selectors: []const Selector,

    pub fn query(self: Parsed, root: *Node, frame: *Frame) !?*Node.Element {
        for (self.selectors) |selector| {
            // Fast path: single compound with only an ID selector
            if (selector.segments.len == 0 and selector.first.parts.len == 1) {
                const first = selector.first.parts[0];
                if (first == .id) {
                    const el = frame.getElementByIdFromNode(root, first.id) orelse continue;
                    // Check if the element is within the root subtree
                    const node = el.asNode();
                    if (node != root and root.contains(node)) {
                        return el;
                    }
                    continue;
                }
            }

            if (List.initOne(root, selector, frame)) |node| {
                if (node.is(Node.Element)) |el| {
                    return el;
                }
            }
        }
        return null;
    }
};
