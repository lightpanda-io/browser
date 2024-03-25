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

pub const Combinator = enum {
    empty,
    descendant, // space
    child, // >
    next_sibling, // +
    subsequent_sibling, // ~

    pub const Error = error{
        InvalidCombinator,
    };

    pub fn parse(c: u8) Error!Combinator {
        return switch (c) {
            ' ' => .descendant,
            '>' => .child,
            '+' => .next_sibling,
            '~' => .subsequent_sibling,
            else => Error.InvalidCombinator,
        };
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
    pub const Error = error{
        UnknownCombinedCombinator,
        UnsupportedRelativePseudoClass,
        UnsupportedContainsPseudoClass,
        UnsupportedPseudoClass,
        UnsupportedRegexpPseudoClass,
        UnsupportedAttrRegexpOperator,
    };

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
        combinator: Combinator,
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

    // returns true if s is a whitespace-separated list that includes val.
    fn word(haystack: []const u8, needle: []const u8, ci: bool) bool {
        if (haystack.len == 0) return false;
        var it = std.mem.splitAny(u8, haystack, " \t\r\n"); // TODO add \f
        while (it.next()) |part| {
            if (eql(part, needle, ci)) return true;
        }
        return false;
    }

    fn eql(a: []const u8, b: []const u8, ci: bool) bool {
        if (ci) return std.ascii.eqlIgnoreCase(a, b);
        return std.mem.eql(u8, a, b);
    }

    fn starts(haystack: []const u8, needle: []const u8, ci: bool) bool {
        if (ci) return std.ascii.startsWithIgnoreCase(haystack, needle);
        return std.mem.startsWith(u8, haystack, needle);
    }

    fn ends(haystack: []const u8, needle: []const u8, ci: bool) bool {
        if (ci) return std.ascii.endsWithIgnoreCase(haystack, needle);
        return std.mem.endsWith(u8, haystack, needle);
    }

    fn contains(haystack: []const u8, needle: []const u8, ci: bool) bool {
        if (ci) return std.ascii.indexOfIgnoreCase(haystack, needle) != null;
        return std.mem.indexOf(u8, haystack, needle) != null;
    }

    // match returns true if the node matches the selector query.
    pub fn match(s: Selector, n: anytype) !bool {
        return switch (s) {
            .tag => |v| n.isElement() and std.ascii.eqlIgnoreCase(v, try n.tag()),
            .id => |v| return n.isElement() and std.mem.eql(u8, v, try n.attr("id") orelse return false),
            .class => |v| return n.isElement() and word(try n.attr("class") orelse return false, v, false),
            .group => |v| {
                for (v) |sel| {
                    if (try sel.match(n)) return true;
                }
                return false;
            },
            .compound => |v| {
                if (v.selectors.len == 0) return n.isElement();

                for (v.selectors) |sel| {
                    if (!try sel.match(n)) return false;
                }
                return true;
            },
            .combined => |v| {
                return switch (v.combinator) {
                    .empty => try v.first.match(n),
                    .descendant => {
                        if (!try v.second.match(n)) return false;

                        // The first must match a ascendent.
                        var p = try n.parent();
                        while (p != null) {
                            if (try v.first.match(p.?)) {
                                return true;
                            }
                            p = try p.?.parent();
                        }

                        return false;
                    },
                    else => return Error.UnknownCombinedCombinator,
                };
            },
            .attribute => |v| {
                const attr = try n.attr(v.key);

                if (v.op == null) return attr != null;
                if (v.val == null or v.val.?.len == 0) return false;

                const val = v.val.?;

                return switch (v.op.?) {
                    .eql => attr != null and eql(attr.?, val, v.ci),
                    .not_eql => attr == null or !eql(attr.?, val, v.ci),
                    .one_of => attr != null and word(attr.?, val, v.ci),
                    .prefix => attr != null and starts(attr.?, val, v.ci),
                    .suffix => attr != null and ends(attr.?, val, v.ci),
                    .contains => attr != null and contains(attr.?, val, v.ci),
                    .prefix_hyphen => {
                        if (attr == null) return false;
                        if (eql(attr.?, val, v.ci)) return true;

                        if (attr.?.len <= val.len) return false;

                        if (!starts(attr.?, val, v.ci)) return false;

                        return attr.?[val.len] == '-';
                    },
                    .regexp => return Error.UnsupportedAttrRegexpOperator, // TODO handle regexp attribute operator.
                };
            },
            .never_match => return false,
            .pseudo_class_relative => |v| {
                if (!n.isElement()) return false;

                return switch (v.pseudo_class) {
                    .not => !try v.match.match(n),
                    .has => try hasDescendantMatch(v.match, n),
                    .haschild => try hasChildMatch(v.match, n),
                    else => Error.UnsupportedRelativePseudoClass,
                };
            },
            .pseudo_class_contains => return Error.UnsupportedContainsPseudoClass, // TODO, need mem allocation.
            .pseudo_class_regexp => return Error.UnsupportedRegexpPseudoClass, // TODO need mem allocation.
            .pseudo_class_nth => |v| {
                if (v.a == 0) {
                    if (v.last) {
                        return simpleNthLastChildMatch(v.b, v.of_type, n);
                    }
                    return simpleNthChildMatch(v.b, v.of_type, n);
                }
                return nthChildMatch(v.a, v.b, v.last, v.of_type, n);
            },
            .pseudo_class => |v| {
                switch (v) {
                    .input => return Error.UnsupportedPseudoClass,
                    .empty => return Error.UnsupportedPseudoClass,
                    .root => return Error.UnsupportedPseudoClass,
                    .link => return Error.UnsupportedPseudoClass,
                    .enabled => return Error.UnsupportedPseudoClass,
                    .disabled => return Error.UnsupportedPseudoClass,
                    .checked => return Error.UnsupportedPseudoClass,
                    .visited => return Error.UnsupportedPseudoClass,
                    .hover => return Error.UnsupportedPseudoClass,
                    .active => return Error.UnsupportedPseudoClass,
                    .focus => return Error.UnsupportedPseudoClass,
                    .target => return Error.UnsupportedPseudoClass,

                    // all others pseudo class are handled by specialized
                    // pseudo_class_X selectors.
                    else => return Error.UnsupportedPseudoClass,
                }
            },
            .pseudo_class_only_child => |v| onlyChildMatch(v, n),
            .pseudo_class_lang => return false,
            .pseudo_element => return false,
        };
    }

    // onlyChildMatch implements :only-child
    //  If `ofType` is true, it implements :only-of-type instead.
    fn onlyChildMatch(of_type: bool, n: anytype) anyerror!bool {
        if (!n.isElement()) return false;

        const p = try n.parent();
        if (p == null) return false;

        const ntag = try n.tag();

        var count: usize = 0;
        var c = try p.?.firstChild();
        // loop hover all n siblings.
        while (c != null) {
            // ignore non elements or others tags if of-type is true.
            if (!c.?.isElement() or (of_type and !std.mem.eql(u8, ntag, try c.?.tag()))) {
                c = try c.?.nextSibling();
                continue;
            }

            count += 1;
            if (count > 1) return false;

            c = try c.?.nextSibling();
        }

        return count == 1;
    }

    // simpleNthLastChildMatch implements :nth-last-child(b).
    // If ofType is true, implements :nth-last-of-type instead.
    fn simpleNthLastChildMatch(b: isize, of_type: bool, n: anytype) anyerror!bool {
        if (!n.isElement()) return false;

        const p = try n.parent();
        if (p == null) return false;

        const ntag = try n.tag();

        var count: isize = 0;
        var c = try p.?.lastChild();
        // loop hover all n siblings.
        while (c != null) {
            // ignore non elements or others tags if of-type is true.
            if (!c.?.isElement() or (of_type and !std.mem.eql(u8, ntag, try c.?.tag()))) {
                c = try c.?.prevSibling();
                continue;
            }

            count += 1;

            if (n.eql(c.?)) return count == b;
            if (count >= b) return false;

            c = try c.?.prevSibling();
        }

        return false;
    }

    // simpleNthChildMatch implements :nth-child(b).
    // If ofType is true, implements :nth-of-type instead.
    fn simpleNthChildMatch(b: isize, of_type: bool, n: anytype) anyerror!bool {
        if (!n.isElement()) return false;

        const p = try n.parent();
        if (p == null) return false;

        const ntag = try n.tag();

        var count: isize = 0;
        var c = try p.?.firstChild();
        // loop hover all n siblings.
        while (c != null) {
            // ignore non elements or others tags if of-type is true.
            if (!c.?.isElement() or (of_type and !std.mem.eql(u8, ntag, try c.?.tag()))) {
                c = try c.?.nextSibling();
                continue;
            }

            count += 1;

            if (n.eql(c.?)) return count == b;
            if (count >= b) return false;

            c = try c.?.nextSibling();
        }

        return false;
    }

    // nthChildMatch implements :nth-child(an+b).
    // If last is true, implements :nth-last-child instead.
    // If ofType is true, implements :nth-of-type instead.
    fn nthChildMatch(a: isize, b: isize, last: bool, of_type: bool, n: anytype) anyerror!bool {
        if (!n.isElement()) return false;

        const p = try n.parent();
        if (p == null) return false;

        const ntag = try n.tag();

        var i: isize = -1;
        var count: isize = 0;
        var c = try p.?.firstChild();
        // loop hover all n siblings.
        while (c != null) {
            // ignore non elements or others tags if of-type is true.
            if (!c.?.isElement() or (of_type and !std.mem.eql(u8, ntag, try c.?.tag()))) {
                c = try c.?.nextSibling();
                continue;
            }
            count += 1;

            if (n.eql(c.?)) {
                i = count;
                if (!last) break;
            }

            c = try c.?.nextSibling();
        }

        if (i == -1) return false;

        if (last) i = count - i + 1;

        i -= b;
        if (a == 0) return i == 0;
        return @mod(i, a) == 0 and @divTrunc(i, a) >= 0;
    }

    fn hasDescendantMatch(s: *const Selector, n: anytype) anyerror!bool {
        var c = try n.firstChild();
        while (c != null) {
            if (try s.match(c.?)) return true;
            if (c.?.isElement() and try hasDescendantMatch(s, c.?)) return true;
            c = try c.?.nextSibling();
        }

        return false;
    }

    fn hasChildMatch(s: *const Selector, n: anytype) anyerror!bool {
        var c = try n.firstChild();
        while (c != null) {
            if (try s.match(c.?)) return true;
            c = try c.?.nextSibling();
        }

        return false;
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
