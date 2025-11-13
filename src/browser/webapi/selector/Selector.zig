const std = @import("std");

const Parser = @import("Parser.zig");
const Node = @import("../Node.zig");
const Page = @import("../../Page.zig");
pub const List = @import("List.zig");

pub fn querySelector(root: *Node, input: []const u8, page: *Page) !?*Node.Element {
    if (input.len == 0) {
        return error.SyntaxError;
    }

    const arena = page.call_arena;
    const selectors = try Parser.parseList(arena, input, page);

    for (selectors) |selector| {
        // Fast path: single compound with only an ID selector
        if (selector.segments.len == 0 and selector.first.parts.len == 1) {
            const first = selector.first.parts[0];
            if (first == .id) {
                const el = page.document._elements_by_id.get(first.id) orelse continue;
                // Check if the element is within the root subtree
                if (root.contains(el.asNode())) {
                    return el;
                }
                continue;
            }
        }

        if (List.initOne(root, selector, page)) |node| {
            if (node.is(Node.Element)) |el| {
                return el;
            }
        }
    }
    return null;
}

pub fn querySelectorAll(root: *Node, input: []const u8, page: *Page) !*List {
    if (input.len == 0) {
        return error.SyntaxError;
    }

    const arena = page.arena;
    var nodes: std.AutoArrayHashMapUnmanaged(*Node, void) = .empty;

    const selectors = try Parser.parseList(arena, input, page);
    for (selectors) |selector| {
        try List.collect(arena, root, selector, &nodes, page);
    }

    return page._factory.create(List{
        ._arena = arena,
        ._nodes = nodes.keys(),
    });
}

pub fn matches(el: *Node.Element, input: []const u8, page: *Page) !bool {
    if (input.len == 0) {
        return error.SyntaxError;
    }

    const arena = page.call_arena;
    const selectors = try Parser.parseList(arena, input, page);

    for (selectors) |selector| {
        if (List.matches(el.asNode(), selector, null)) {
            return true;
        }
    }
    return false;
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
    name: []const u8,
    matcher: AttributeMatcher,
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
    not: []const Selector, // :not() - CSS Level 4: supports full selectors and comma-separated lists
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
