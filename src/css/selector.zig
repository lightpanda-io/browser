const std = @import("std");

pub const AttributeOP = enum {
    eql, // =
    not_eql, // !=
    one_of, // ~=
    prefix_hyphen, // |=
    prefix, // ^=
    suffix, // $=
    contains, // *=
    regexp, // #=

    pub fn len(op: AttributeOP) u2 {
        if (op == .eql) return 1;
        return 2;
    }
};

pub const PseudoClass = enum {
    not,
    has,
    haschild,
    contains,
    containsown,
    matches,
    matchesown,
    nth_child,
    nth_last_child,
    nth_of_type,
    nth_last_of_type,
    first_child,
    last_child,
    first_of_type,
    last_of_type,
    only_child,
    only_of_type,
    input,
    empty,
    root,
    link,
    lang,
    enabled,
    disabled,
    checked,
    visited,
    hover,
    active,
    focus,
    target,
    after,
    backdrop,
    before,
    cue,
    first_letter,
    first_line,
    grammar_error,
    marker,
    placeholder,
    selection,
    spelling_error,

    pub const Error = error{
        InvalidPseudoClass,
    };

    pub fn isPseudoElement(pc: PseudoClass) bool {
        return switch (pc) {
            .after, .backdrop, .before, .cue, .first_letter => true,
            .first_line, .grammar_error, .marker, .placeholder => true,
            .selection, .spelling_error => true,
            else => false,
        };
    }

    pub fn parse(s: []const u8) Error!PseudoClass {
        if (std.ascii.eqlIgnoreCase(s, "not")) return .not;
        if (std.ascii.eqlIgnoreCase(s, "has")) return .has;
        if (std.ascii.eqlIgnoreCase(s, "haschild")) return .haschild;
        if (std.ascii.eqlIgnoreCase(s, "contains")) return .contains;
        if (std.ascii.eqlIgnoreCase(s, "containsown")) return .containsown;
        if (std.ascii.eqlIgnoreCase(s, "matches")) return .matches;
        if (std.ascii.eqlIgnoreCase(s, "matchesown")) return .matchesown;
        if (std.ascii.eqlIgnoreCase(s, "nth-child")) return .nth_child;
        if (std.ascii.eqlIgnoreCase(s, "nth-last-child")) return .nth_last_child;
        if (std.ascii.eqlIgnoreCase(s, "nth-of-type")) return .nth_of_type;
        if (std.ascii.eqlIgnoreCase(s, "nth-last-of-type")) return .nth_last_of_type;
        if (std.ascii.eqlIgnoreCase(s, "first-child")) return .first_child;
        if (std.ascii.eqlIgnoreCase(s, "last-child")) return .last_child;
        if (std.ascii.eqlIgnoreCase(s, "first-of-type")) return .first_of_type;
        if (std.ascii.eqlIgnoreCase(s, "last-of-type")) return .last_of_type;
        if (std.ascii.eqlIgnoreCase(s, "only-child")) return .only_child;
        if (std.ascii.eqlIgnoreCase(s, "only-of-type")) return .only_of_type;
        if (std.ascii.eqlIgnoreCase(s, "input")) return .input;
        if (std.ascii.eqlIgnoreCase(s, "empty")) return .empty;
        if (std.ascii.eqlIgnoreCase(s, "root")) return .root;
        if (std.ascii.eqlIgnoreCase(s, "link")) return .link;
        if (std.ascii.eqlIgnoreCase(s, "lang")) return .lang;
        if (std.ascii.eqlIgnoreCase(s, "enabled")) return .enabled;
        if (std.ascii.eqlIgnoreCase(s, "disabled")) return .disabled;
        if (std.ascii.eqlIgnoreCase(s, "checked")) return .checked;
        if (std.ascii.eqlIgnoreCase(s, "visited")) return .visited;
        if (std.ascii.eqlIgnoreCase(s, "hover")) return .hover;
        if (std.ascii.eqlIgnoreCase(s, "active")) return .active;
        if (std.ascii.eqlIgnoreCase(s, "focus")) return .focus;
        if (std.ascii.eqlIgnoreCase(s, "target")) return .target;
        if (std.ascii.eqlIgnoreCase(s, "after")) return .after;
        if (std.ascii.eqlIgnoreCase(s, "backdrop")) return .backdrop;
        if (std.ascii.eqlIgnoreCase(s, "before")) return .before;
        if (std.ascii.eqlIgnoreCase(s, "cue")) return .cue;
        if (std.ascii.eqlIgnoreCase(s, "first-letter")) return .first_letter;
        if (std.ascii.eqlIgnoreCase(s, "first-line")) return .first_line;
        if (std.ascii.eqlIgnoreCase(s, "grammar-error")) return .grammar_error;
        if (std.ascii.eqlIgnoreCase(s, "marker")) return .marker;
        if (std.ascii.eqlIgnoreCase(s, "placeholder")) return .placeholder;
        if (std.ascii.eqlIgnoreCase(s, "selection")) return .selection;
        if (std.ascii.eqlIgnoreCase(s, "spelling-error")) return .spelling_error;
        return Error.InvalidPseudoClass;
    }
};

pub const Selector = union(enum) {
    compound: struct {
        selectors: []Selector,
        pseudo_elt: ?PseudoClass,
    },
    group: []Selector,
    tag: []const u8,
    id: []const u8,
    class: []const u8,
    attribute: struct {
        key: []const u8,
        val: ?[]const u8 = null,
        op: ?AttributeOP = null,
        regexp: ?[]const u8 = null,
        ci: bool = false,
    },
    combined: struct {
        first: *Selector,
        second: *Selector,
        combinator: u8,
    },

    never_match: PseudoClass,

    pseudo_class: PseudoClass,
    pseudo_class_only_child: bool,
    pseudo_class_lang: []const u8,
    pseudo_class_relative: struct {
        pseudo_class: PseudoClass,
        match: *Selector,
    },
    pseudo_class_contains: struct {
        own: bool,
        val: []const u8,
    },
    pseudo_class_regexp: struct {
        own: bool,
        regexp: []const u8,
    },
    pseudo_class_nth: struct {
        a: isize,
        b: isize,
        of_type: bool,
        last: bool,
    },
    pseudo_element: PseudoClass,

    pub fn match(s: Selector, n: anytype) !bool {
        return switch (s) {
            .tag => |v| n.isElement() and std.ascii.eqlIgnoreCase(v, try n.tag()),
            else => false,
        };
    }

    pub fn deinit(sel: Selector, alloc: std.mem.Allocator) void {
        switch (sel) {
            .group => |v| {
                for (v) |vv| vv.deinit(alloc);
                alloc.free(v);
            },
            .compound => |v| {
                for (v.selectors) |vv| vv.deinit(alloc);
                alloc.free(v.selectors);
            },
            .tag, .id, .class, .pseudo_class_lang => |v| alloc.free(v),
            .attribute => |att| {
                alloc.free(att.key);
                if (att.val) |v| alloc.free(v);
                if (att.regexp) |v| alloc.free(v);
            },
            .combined => |c| {
                c.first.deinit(alloc);
                alloc.destroy(c.first);
                c.second.deinit(alloc);
                alloc.destroy(c.second);
            },
            .pseudo_class_relative => |v| {
                v.match.deinit(alloc);
                alloc.destroy(v.match);
            },
            .pseudo_class_contains => |v| alloc.free(v.val),
            .pseudo_class_regexp => |v| alloc.free(v.regexp),
            .pseudo_class, .pseudo_element, .never_match => {},
            .pseudo_class_nth, .pseudo_class_only_child => {},
        }
    }
};
