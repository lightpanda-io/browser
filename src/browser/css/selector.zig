// Copyright (C) 2023-2024  Lightpanda (Selecy SAS)
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
const Allocator = std.mem.Allocator;
const css = @import("css.zig");

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
    modal,
    popover_open,
    visible,

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
        const longest_selector = "nth-last-of-type";
        if (s.len > longest_selector.len) {
            return Error.InvalidPseudoClass;
        }

        var buf: [longest_selector.len]u8 = undefined;
        const selector = std.ascii.lowerString(&buf, s);

        switch (selector.len) {
            3 => switch (@as(u24, @bitCast(selector[0..3].*))) {
                asUint(u24, "cue") => return .cue,
                asUint(u24, "has") => return .has,
                asUint(u24, "not") => return .not,
                else => {},
            },
            4 => switch (@as(u32, @bitCast(selector[0..4].*))) {
                asUint(u32, "lang") => return .lang,
                asUint(u32, "link") => return .link,
                asUint(u32, "root") => return .root,
                else => {},
            },
            5 => switch (@as(u40, @bitCast(selector[0..5].*))) {
                asUint(u40, "after") => return .after,
                asUint(u40, "empty") => return .empty,
                asUint(u40, "focus") => return .focus,
                asUint(u40, "hover") => return .hover,
                asUint(u40, "input") => return .input,
                asUint(u40, "modal") => return .modal,
                else => {},
            },
            6 => switch (@as(u48, @bitCast(selector[0..6].*))) {
                asUint(u48, "active") => return .active,
                asUint(u48, "before") => return .before,
                asUint(u48, "marker") => return .marker,
                asUint(u48, "target") => return .target,
                else => {},
            },
            7 => switch (@as(u56, @bitCast(selector[0..7].*))) {
                asUint(u56, "checked") => return .checked,
                asUint(u56, "enabled") => return .enabled,
                asUint(u56, "matches") => return .matches,
                asUint(u56, "visited") => return .visited,
                asUint(u56, "visible") => return .visible,
                else => {},
            },
            8 => switch (@as(u64, @bitCast(selector[0..8].*))) {
                asUint(u64, "backdrop") => return .backdrop,
                asUint(u64, "contains") => return .contains,
                asUint(u64, "disabled") => return .disabled,
                asUint(u64, "haschild") => return .haschild,
                else => {},
            },
            9 => switch (@as(u72, @bitCast(selector[0..9].*))) {
                asUint(u72, "nth-child") => return .nth_child,
                asUint(u72, "selection") => return .selection,
                else => {},
            },
            10 => switch (@as(u80, @bitCast(selector[0..10].*))) {
                asUint(u80, "first-line") => return .first_line,
                asUint(u80, "last-child") => return .last_child,
                asUint(u80, "matchesown") => return .matchesown,
                asUint(u80, "only-child") => return .only_child,
                else => {},
            },
            11 => switch (@as(u88, @bitCast(selector[0..11].*))) {
                asUint(u88, "containsown") => return .containsown,
                asUint(u88, "first-child") => return .first_child,
                asUint(u88, "nth-of-type") => return .nth_of_type,
                asUint(u88, "placeholder") => return .placeholder,
                else => {},
            },
            12 => switch (@as(u96, @bitCast(selector[0..12].*))) {
                asUint(u96, "first-letter") => return .first_letter,
                asUint(u96, "last-of-type") => return .last_of_type,
                asUint(u96, "only-of-type") => return .only_of_type,
                asUint(u96, "popover-open") => return .popover_open,
                else => {},
            },
            13 => switch (@as(u104, @bitCast(selector[0..13].*))) {
                asUint(u104, "first-of-type") => return .first_of_type,
                asUint(u104, "grammar-error") => return .grammar_error,
                else => {},
            },
            14 => switch (@as(u112, @bitCast(selector[0..14].*))) {
                asUint(u112, "nth-last-child") => return .nth_last_child,
                asUint(u112, "spelling-error") => return .spelling_error,
                else => {},
            },
            16 => switch (@as(u128, @bitCast(selector[0..16].*))) {
                asUint(u128, "nth-last-of-type") => return .nth_last_of_type,
                else => {},
            },
            else => {},
        }
        return Error.InvalidPseudoClass;
    }
};

fn asUint(comptime T: type, comptime string: []const u8) T {
    return @bitCast(string[0..string.len].*);
}

pub const Selector = union(enum) {
    pub const Error = error{
        UnknownCombinedCombinator,
        UnsupportedRelativePseudoClass,
        UnsupportedContainsPseudoClass,
        UnsupportedPseudoClass,
        UnsupportedPseudoElement,
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
    pub fn match(s: *const Selector, n: anytype) !bool {
        return switch (s.*) {
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
                    .child => {
                        const p = try n.parent();
                        if (p == null) return false;

                        return try v.second.match(n) and try v.first.match(p.?);
                    },
                    .next_sibling => {
                        if (!try v.second.match(n)) return false;
                        var c = try n.prevSibling();
                        while (c != null) {
                            if (c.?.isText() or c.?.isComment()) {
                                c = try c.?.prevSibling();
                                continue;
                            }
                            return try v.first.match(c.?);
                        }
                        return false;
                    },
                    .subsequent_sibling => {
                        if (!try v.second.match(n)) return false;

                        var c = try n.prevSibling();
                        while (c != null) {
                            if (try v.first.match(c.?)) return true;
                            c = try c.?.prevSibling();
                        }
                        return false;
                    },
                };
            },
            .attribute => |v| {
                var attr = try n.attr(v.key);

                if (v.op == null) return attr != null;
                if (v.val == null or v.val.?.len == 0) return false;

                const val = v.val.?;

                return switch (v.op.?) {
                    .eql => attr != null and eql(attr.?, val, v.ci),
                    .not_eql => attr == null or !eql(attr.?, val, v.ci),
                    .one_of => attr != null and word(attr.?, val, v.ci),
                    .prefix => {
                        if (attr == null) return false;
                        attr.? = std.mem.trim(u8, attr.?, &std.ascii.whitespace);

                        if (attr.?.len == 0) return false;

                        return starts(attr.?, val, v.ci);
                    },
                    .suffix => {
                        if (attr == null) return false;
                        attr.? = std.mem.trim(u8, attr.?, &std.ascii.whitespace);

                        if (attr.?.len == 0) return false;

                        return ends(attr.?, val, v.ci);
                    },
                    .contains => {
                        if (attr == null) return false;
                        attr.? = std.mem.trim(u8, attr.?, &std.ascii.whitespace);

                        if (attr.?.len == 0) return false;

                        return contains(attr.?, val, v.ci);
                    },
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
            .pseudo_class_contains => |v| {
                // Only containsOwn is implemented.
                if (v.own == false) return Error.UnsupportedContainsPseudoClass;

                var c = try n.firstChild();
                while (c != null) {
                    if (c.?.isText()) {
                        const text = try c.?.text();
                        if (text) |_text| {
                            if (contains(_text, v.val, false)) { // we are case sensitive. Is this correct behavior?
                                return true;
                            }
                        }
                    }

                    c = try c.?.nextSibling();
                }
                return false;
            },
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
                return switch (v) {
                    .input => {
                        if (!n.isElement()) return false;
                        const ntag = try n.tag();

                        return std.ascii.eqlIgnoreCase("input", ntag) or
                            std.ascii.eqlIgnoreCase("select", ntag) or
                            std.ascii.eqlIgnoreCase("button", ntag) or
                            std.ascii.eqlIgnoreCase("textarea", ntag);
                    },
                    .empty => {
                        if (!n.isElement()) return false;

                        var c = try n.firstChild();
                        while (c != null) {
                            if (c.?.isElement()) return false;

                            if (c.?.isText()) {
                                if (try c.?.isEmptyText()) continue;
                                return false;
                            }

                            c = try c.?.nextSibling();
                        }

                        return true;
                    },
                    .root => {
                        if (!n.isElement()) return false;

                        const p = try n.parent();
                        return (p != null and p.?.isDocument());
                    },
                    .link => {
                        const ntag = try n.tag();

                        return std.ascii.eqlIgnoreCase("a", ntag) or
                            std.ascii.eqlIgnoreCase("area", ntag) or
                            std.ascii.eqlIgnoreCase("link", ntag);
                    },
                    .enabled => {
                        if (!n.isElement()) return false;

                        const ntag = try n.tag();

                        if (std.ascii.eqlIgnoreCase("a", ntag) or
                            std.ascii.eqlIgnoreCase("area", ntag) or
                            std.ascii.eqlIgnoreCase("link", ntag))
                        {
                            return try n.attr("href") != null;
                        }

                        if (std.ascii.eqlIgnoreCase("optgroup", ntag) or
                            std.ascii.eqlIgnoreCase("menuitem", ntag) or
                            std.ascii.eqlIgnoreCase("fieldset", ntag))
                        {
                            return try n.attr("disabled") == null;
                        }

                        if (std.ascii.eqlIgnoreCase("input", ntag) or
                            std.ascii.eqlIgnoreCase("button", ntag) or
                            std.ascii.eqlIgnoreCase("select", ntag) or
                            std.ascii.eqlIgnoreCase("textarea", ntag) or
                            std.ascii.eqlIgnoreCase("option", ntag))
                        {
                            return try n.attr("disabled") == null and
                                !try inDisabledFieldset(n);
                        }

                        return false;
                    },
                    .disabled => {
                        if (!n.isElement()) return false;

                        const ntag = try n.tag();

                        if (std.ascii.eqlIgnoreCase("optgroup", ntag) or
                            std.ascii.eqlIgnoreCase("menuitem", ntag) or
                            std.ascii.eqlIgnoreCase("fieldset", ntag))
                        {
                            return try n.attr("disabled") != null;
                        }

                        if (std.ascii.eqlIgnoreCase("input", ntag) or
                            std.ascii.eqlIgnoreCase("button", ntag) or
                            std.ascii.eqlIgnoreCase("select", ntag) or
                            std.ascii.eqlIgnoreCase("textarea", ntag) or
                            std.ascii.eqlIgnoreCase("option", ntag))
                        {
                            return try n.attr("disabled") != null or
                                try inDisabledFieldset(n);
                        }

                        return false;
                    },
                    .checked => {
                        if (!n.isElement()) return false;

                        const ntag = try n.tag();

                        if (std.ascii.eqlIgnoreCase("intput", ntag)) {
                            const ntype = try n.attr("type");
                            if (ntype == null) return false;

                            if (std.mem.eql(u8, ntype.?, "checkbox") or
                                std.mem.eql(u8, ntype.?, "radio"))
                            {
                                return try n.attr("checked") != null;
                            }

                            return false;
                        }
                        if (std.ascii.eqlIgnoreCase("option", ntag)) {
                            return try n.attr("selected") != null;
                        }

                        return false;
                    },
                    .visited => return false,
                    .hover => return false,
                    .active => return false,
                    .focus => return false,
                    // TODO implement using the url fragment.
                    // see https://developer.mozilla.org/en-US/docs/Web/CSS/:target
                    .target => return false,
                    // visible always returns true.
                    .visible => return true,

                    // all others pseudo class are handled by specialized
                    // pseudo_class_X selectors.
                    else => return Error.UnsupportedPseudoClass,
                };
            },
            .pseudo_class_only_child => |v| onlyChildMatch(v, n),
            .pseudo_class_lang => |v| langMatch(v, n),

            // pseudo elements doesn't make sense in the matching process.
            // > A CSS pseudo-element is a keyword added to a selector that
            // > lets you style a specific part of the selected element(s).
            // https://developer.mozilla.org/en-US/docs/Web/CSS/Pseudo-elements
            .pseudo_element => return Error.UnsupportedPseudoElement,
        };
    }

    fn hasLegendInPreviousSiblings(n: anytype) anyerror!bool {
        var c = try n.prevSibling();
        while (c != null) {
            const ctag = try c.?.tag();
            if (std.ascii.eqlIgnoreCase("legend", ctag)) return true;
            c = try c.?.prevSibling();
        }
        return false;
    }

    fn inDisabledFieldset(n: anytype) anyerror!bool {
        const p = try n.parent();
        if (p == null) return false;

        const ntag = try n.tag();
        const ptag = try p.?.tag();

        if (std.ascii.eqlIgnoreCase("fieldset", ptag) and
            try p.?.attr("disabled") != null and
            (!std.ascii.eqlIgnoreCase("legend", ntag) or try hasLegendInPreviousSiblings(n)))
        {
            return true;
        }

        // TODO should we handle legend like cascadia does?
        // The implemention below looks suspicious, I didn't find a test case
        // in cascadia and I didn't find the reference about legend in the
        // specs. For now I do prefer ignoring this part.
        //
        // ```
        // (n.DataAtom != atom.Legend || hasLegendInPreviousSiblings(n)) {
        // ```
        // https://github.com/andybalholm/cascadia/blob/master/pseudo_classes.go#L434

        return try inDisabledFieldset(p.?);
    }

    fn langMatch(lang: []const u8, n: anytype) anyerror!bool {
        if (try n.attr("lang")) |own| {
            if (std.mem.eql(u8, own, lang)) return true;

            // check if the lang attr starts with lang+'-'
            if (std.mem.startsWith(u8, own, lang)) {
                if (own.len > lang.len and own[lang.len] == '-') return true;
            }
        }

        // if the tag doesn't match, try the parent.
        const p = try n.parent();
        if (p == null) return false;

        return langMatch(lang, p.?);
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

    pub fn deinit(sel: *const Selector, alloc: std.mem.Allocator) void {
        switch (sel.*) {
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

// NodeTest mock implementation for test only.
pub const NodeTest = struct {
    child: ?*const NodeTest = null,
    last: ?*const NodeTest = null,
    sibling: ?*const NodeTest = null,
    prev: ?*const NodeTest = null,
    par: ?*const NodeTest = null,

    name: []const u8 = "",
    att: ?[]const u8 = null,

    pub fn firstChild(n: *const NodeTest) !?*const NodeTest {
        return n.child;
    }

    pub fn lastChild(n: *const NodeTest) !?*const NodeTest {
        return n.last;
    }

    pub fn nextSibling(n: *const NodeTest) !?*const NodeTest {
        return n.sibling;
    }

    pub fn prevSibling(n: *const NodeTest) !?*const NodeTest {
        return n.prev;
    }

    pub fn parent(n: *const NodeTest) !?*const NodeTest {
        return n.par;
    }

    pub fn isElement(_: *const NodeTest) bool {
        return true;
    }

    pub fn isDocument(_: *const NodeTest) bool {
        return false;
    }

    pub fn isComment(_: *const NodeTest) bool {
        return false;
    }

    pub fn text(_: *const NodeTest) !?[]const u8 {
        return null;
    }

    pub fn isText(_: *const NodeTest) bool {
        return false;
    }

    pub fn isEmptyText(_: *const NodeTest) !bool {
        return false;
    }

    pub fn tag(n: *const NodeTest) ![]const u8 {
        return n.name;
    }

    pub fn attr(n: *const NodeTest, _: []const u8) !?[]const u8 {
        return n.att;
    }

    pub fn eql(a: *const NodeTest, b: *const NodeTest) bool {
        return a == b;
    }
};

const MatcherTest = struct {
    const NodeTests = std.ArrayListUnmanaged(*const NodeTest);

    nodes: NodeTests,
    allocator: Allocator,

    fn init(allocator: Allocator) MatcherTest {
        return .{
            .nodes = .empty,
            .allocator = allocator,
        };
    }

    fn deinit(m: *MatcherTest) void {
        m.nodes.deinit(m.allocator);
    }

    fn reset(m: *MatcherTest) void {
        m.nodes.clearRetainingCapacity();
    }

    pub fn match(m: *MatcherTest, n: *const NodeTest) !void {
        try m.nodes.append(m.allocator, n);
    }
};

test "Browser.CSS.Selector: matchFirst" {
    const alloc = std.testing.allocator;

    var matcher = MatcherTest.init(alloc);
    defer matcher.deinit();

    const testcases = [_]struct {
        q: []const u8,
        n: NodeTest,
        exp: usize,
    }{
        .{
            .q = "address",
            .n = .{ .child = &.{ .name = "body", .child = &.{ .name = "address" } } },
            .exp = 1,
        },
        .{
            .q = "#foo",
            .n = .{ .child = &.{ .name = "p", .att = "foo", .child = &.{ .name = "p" } } },
            .exp = 1,
        },
        .{
            .q = ".t1",
            .n = .{ .child = &.{ .name = "p", .sibling = &.{ .name = "p", .att = "t1" } } },
            .exp = 1,
        },
        .{
            .q = ".t1",
            .n = .{ .child = &.{ .name = "p", .sibling = &.{ .name = "p", .att = "foo t1" } } },
            .exp = 1,
        },
        .{
            .q = "[foo]",
            .n = .{ .child = &.{ .name = "p", .sibling = &.{ .name = "p" } } },
            .exp = 0,
        },
        .{
            .q = "[foo]",
            .n = .{ .child = &.{ .name = "p", .sibling = &.{ .name = "p", .att = "bar" } } },
            .exp = 1,
        },
        .{
            .q = "[foo=bar]",
            .n = .{ .child = &.{ .name = "p", .sibling = &.{ .name = "p", .att = "bar" } } },
            .exp = 1,
        },
        .{
            .q = "[foo=baz]",
            .n = .{ .child = &.{ .name = "p", .sibling = &.{ .name = "p", .att = "bar" } } },
            .exp = 0,
        },
        .{
            .q = "[foo!=bar]",
            .n = .{ .child = &.{ .name = "p", .sibling = &.{ .name = "p", .att = "bar" } } },
            .exp = 1,
        },
        .{
            .q = "[foo!=baz]",
            .n = .{ .child = &.{ .name = "p", .sibling = &.{ .name = "p", .att = "bar" } } },
            .exp = 1,
        },
        .{
            .q = "[foo~=bar]",
            .n = .{ .child = &.{ .name = "p", .sibling = &.{ .name = "p", .att = "baz bar" } } },
            .exp = 1,
        },
        .{
            .q = "[foo~=bar]",
            .n = .{ .child = &.{ .name = "p", .sibling = &.{ .name = "p", .att = "barbaz" } } },
            .exp = 0,
        },
        .{
            .q = "[foo^=bar]",
            .n = .{ .child = &.{ .name = "p", .sibling = &.{ .name = "p", .att = "barbaz" } } },
            .exp = 1,
        },
        .{
            .q = "[foo$=baz]",
            .n = .{ .child = &.{ .name = "p", .sibling = &.{ .name = "p", .att = "barbaz" } } },
            .exp = 1,
        },
        .{
            .q = "[foo*=rb]",
            .n = .{ .child = &.{ .name = "p", .sibling = &.{ .name = "p", .att = "barbaz" } } },
            .exp = 1,
        },
        .{
            .q = "[foo|=bar]",
            .n = .{ .child = &.{ .name = "p", .sibling = &.{ .name = "p", .att = "bar" } } },
            .exp = 1,
        },
        .{
            .q = "[foo|=bar]",
            .n = .{ .child = &.{ .name = "p", .sibling = &.{ .name = "p", .att = "bar-baz" } } },
            .exp = 1,
        },
        .{
            .q = "[foo|=bar]",
            .n = .{ .child = &.{ .name = "p", .sibling = &.{ .name = "p", .att = "ba" } } },
            .exp = 0,
        },
        .{
            .q = "strong, a",
            .n = .{ .child = &.{ .name = "p", .child = &.{ .name = "a" }, .sibling = &.{ .name = "strong" } } },
            .exp = 1,
        },
        .{
            .q = "p a",
            .n = .{ .child = &.{ .name = "p", .child = &.{ .name = "a", .par = &.{ .name = "p" } }, .sibling = &.{ .name = "a" } } },
            .exp = 1,
        },
        .{
            .q = "p a",
            .n = .{ .child = &.{ .name = "p", .child = &.{ .name = "span", .child = &.{
                .name = "a",
                .par = &.{ .name = "span", .par = &.{ .name = "p" } },
            } } } },
            .exp = 1,
        },
        .{
            .q = ":not(p)",
            .n = .{ .child = &.{ .name = "p", .child = &.{ .name = "a" }, .sibling = &.{ .name = "strong" } } },
            .exp = 1,
        },
        .{
            .q = "p:has(a)",
            .n = .{ .child = &.{ .name = "p", .child = &.{ .name = "a" }, .sibling = &.{ .name = "strong" } } },
            .exp = 1,
        },
        .{
            .q = "p:has(strong)",
            .n = .{ .child = &.{ .name = "p", .child = &.{ .name = "a" }, .sibling = &.{ .name = "strong" } } },
            .exp = 0,
        },
        .{
            .q = "p:haschild(a)",
            .n = .{ .child = &.{ .name = "p", .child = &.{ .name = "a" }, .sibling = &.{ .name = "strong" } } },
            .exp = 1,
        },
        .{
            .q = "p:haschild(strong)",
            .n = .{ .child = &.{ .name = "p", .child = &.{ .name = "a" }, .sibling = &.{ .name = "strong" } } },
            .exp = 0,
        },
        .{
            .q = "p:lang(en)",
            .n = .{ .child = &.{ .name = "p", .att = "en-US", .child = &.{ .name = "a" } } },
            .exp = 1,
        },
        .{
            .q = "a:lang(en)",
            .n = .{ .child = &.{ .name = "p", .child = &.{ .name = "a", .par = &.{ .att = "en-US" } } } },
            .exp = 1,
        },
    };

    for (testcases) |tc| {
        matcher.reset();

        const s = try css.parse(alloc, tc.q, .{});
        defer s.deinit(alloc);

        _ = css.matchFirst(&s, &tc.n, &matcher) catch |e| {
            std.debug.print("query: {s}, parsed selector: {any}\n", .{ tc.q, s });
            return e;
        };

        std.testing.expectEqual(tc.exp, matcher.nodes.items.len) catch |e| {
            std.debug.print("query: {s}, parsed selector: {any}\n", .{ tc.q, s });
            return e;
        };
    }
}

test "Browser.CSS.Selector: matchAll" {
    const alloc = std.testing.allocator;

    var matcher = MatcherTest.init(alloc);
    defer matcher.deinit();

    const testcases = [_]struct {
        q: []const u8,
        n: NodeTest,
        exp: usize,
    }{
        .{
            .q = "address",
            .n = .{ .child = &.{ .name = "body", .child = &.{ .name = "address" } } },
            .exp = 1,
        },
        .{
            .q = "#foo",
            .n = .{ .child = &.{ .name = "p", .att = "foo", .child = &.{ .name = "p" } } },
            .exp = 1,
        },
        .{
            .q = ".t1",
            .n = .{ .child = &.{ .name = "p", .sibling = &.{ .name = "p", .att = "t1" } } },
            .exp = 1,
        },
        .{
            .q = ".t1",
            .n = .{ .child = &.{ .name = "p", .sibling = &.{ .name = "p", .att = "foo t1" } } },
            .exp = 1,
        },
        .{
            .q = "[foo]",
            .n = .{ .child = &.{ .name = "p", .sibling = &.{ .name = "p" } } },
            .exp = 0,
        },
        .{
            .q = "[foo]",
            .n = .{ .child = &.{ .name = "p", .sibling = &.{ .name = "p", .att = "bar" } } },
            .exp = 1,
        },
        .{
            .q = "[foo=bar]",
            .n = .{ .child = &.{ .name = "p", .sibling = &.{ .name = "p", .att = "bar" } } },
            .exp = 1,
        },
        .{
            .q = "[foo=baz]",
            .n = .{ .child = &.{ .name = "p", .sibling = &.{ .name = "p", .att = "bar" } } },
            .exp = 0,
        },
        .{
            .q = "[foo!=bar]",
            .n = .{ .child = &.{ .name = "p", .sibling = &.{ .name = "p", .att = "bar" } } },
            .exp = 1,
        },
        .{
            .q = "[foo!=baz]",
            .n = .{ .child = &.{ .name = "p", .sibling = &.{ .name = "p", .att = "bar" } } },
            .exp = 2,
        },
        .{
            .q = "[foo~=bar]",
            .n = .{ .child = &.{ .name = "p", .sibling = &.{ .name = "p", .att = "baz bar" } } },
            .exp = 1,
        },
        .{
            .q = "[foo~=bar]",
            .n = .{ .child = &.{ .name = "p", .sibling = &.{ .name = "p", .att = "barbaz" } } },
            .exp = 0,
        },
        .{
            .q = "[foo^=bar]",
            .n = .{ .child = &.{ .name = "p", .sibling = &.{ .name = "p", .att = "barbaz" } } },
            .exp = 1,
        },
        .{
            .q = "[foo$=baz]",
            .n = .{ .child = &.{ .name = "p", .sibling = &.{ .name = "p", .att = "barbaz" } } },
            .exp = 1,
        },
        .{
            .q = "[foo*=rb]",
            .n = .{ .child = &.{ .name = "p", .sibling = &.{ .name = "p", .att = "barbaz" } } },
            .exp = 1,
        },
        .{
            .q = "[foo|=bar]",
            .n = .{ .child = &.{ .name = "p", .sibling = &.{ .name = "p", .att = "bar" } } },
            .exp = 1,
        },
        .{
            .q = "[foo|=bar]",
            .n = .{ .child = &.{ .name = "p", .sibling = &.{ .name = "p", .att = "bar-baz" } } },
            .exp = 1,
        },
        .{
            .q = "[foo|=bar]",
            .n = .{ .child = &.{ .name = "p", .sibling = &.{ .name = "p", .att = "ba" } } },
            .exp = 0,
        },
        .{
            .q = "strong, a",
            .n = .{ .child = &.{ .name = "p", .child = &.{ .name = "a" }, .sibling = &.{ .name = "strong" } } },
            .exp = 2,
        },
        .{
            .q = "p a",
            .n = .{ .child = &.{ .name = "p", .child = &.{ .name = "a", .par = &.{ .name = "p" } }, .sibling = &.{ .name = "a" } } },
            .exp = 1,
        },
        .{
            .q = "p a",
            .n = .{ .child = &.{ .name = "p", .child = &.{ .name = "span", .child = &.{
                .name = "a",
                .par = &.{ .name = "span", .par = &.{ .name = "p" } },
            } } } },
            .exp = 1,
        },
        .{
            .q = ":not(p)",
            .n = .{ .child = &.{ .name = "p", .child = &.{ .name = "a" }, .sibling = &.{ .name = "strong" } } },
            .exp = 2,
        },
        .{
            .q = "p:has(a)",
            .n = .{ .child = &.{ .name = "p", .child = &.{ .name = "a" }, .sibling = &.{ .name = "strong" } } },
            .exp = 1,
        },
        .{
            .q = "p:has(strong)",
            .n = .{ .child = &.{ .name = "p", .child = &.{ .name = "a" }, .sibling = &.{ .name = "strong" } } },
            .exp = 0,
        },
        .{
            .q = "p:haschild(a)",
            .n = .{ .child = &.{ .name = "p", .child = &.{ .name = "a" }, .sibling = &.{ .name = "strong" } } },
            .exp = 1,
        },
        .{
            .q = "p:haschild(strong)",
            .n = .{ .child = &.{ .name = "p", .child = &.{ .name = "a" }, .sibling = &.{ .name = "strong" } } },
            .exp = 0,
        },
        .{
            .q = "p:lang(en)",
            .n = .{ .child = &.{ .name = "p", .att = "en-US", .child = &.{ .name = "a" } } },
            .exp = 1,
        },
        .{
            .q = "a:lang(en)",
            .n = .{ .child = &.{ .name = "p", .child = &.{ .name = "a", .par = &.{ .att = "en-US" } } } },
            .exp = 1,
        },
    };

    for (testcases) |tc| {
        matcher.reset();

        const s = try css.parse(alloc, tc.q, .{});
        defer s.deinit(alloc);

        css.matchAll(&s, &tc.n, &matcher) catch |e| {
            std.debug.print("query: {s}, parsed selector: {any}\n", .{ tc.q, s });
            return e;
        };

        std.testing.expectEqual(tc.exp, matcher.nodes.items.len) catch |e| {
            std.debug.print("query: {s}, parsed selector: {any}\n", .{ tc.q, s });
            return e;
        };
    }
}

test "Browser.CSS.Selector: pseudo class" {
    const alloc = std.testing.allocator;

    var matcher = MatcherTest.init(alloc);
    defer matcher.deinit();

    var p1: NodeTest = .{ .name = "p" };
    var p2: NodeTest = .{ .name = "p" };
    var a1: NodeTest = .{ .name = "a" };

    p1.sibling = &p2;
    p2.prev = &p1;

    p2.sibling = &a1;
    a1.prev = &p2;

    var root: NodeTest = .{ .child = &p1, .last = &a1 };
    p1.par = &root;
    p2.par = &root;
    a1.par = &root;

    const testcases = [_]struct {
        q: []const u8,
        n: NodeTest,
        exp: ?*const NodeTest,
    }{
        .{ .q = "p:only-child", .n = root, .exp = null },
        .{ .q = "a:only-of-type", .n = root, .exp = &a1 },
    };

    for (testcases) |tc| {
        matcher.reset();

        const s = try css.parse(alloc, tc.q, .{});
        defer s.deinit(alloc);

        css.matchAll(&s, &tc.n, &matcher) catch |e| {
            std.debug.print("query: {s}, parsed selector: {any}\n", .{ tc.q, s });
            return e;
        };

        if (tc.exp) |exp_n| {
            const exp: usize = 1;
            std.testing.expectEqual(exp, matcher.nodes.items.len) catch |e| {
                std.debug.print("query: {s}, parsed selector: {any}\n", .{ tc.q, s });
                return e;
            };

            std.testing.expectEqual(exp_n, matcher.nodes.items[0]) catch |e| {
                std.debug.print("query: {s}, parsed selector: {any}\n", .{ tc.q, s });
                return e;
            };

            continue;
        }

        const exp: usize = 0;
        std.testing.expectEqual(exp, matcher.nodes.items.len) catch |e| {
            std.debug.print("query: {s}, parsed selector: {any}\n", .{ tc.q, s });
            return e;
        };
    }
}

test "Browser.CSS.Selector: nth pseudo class" {
    const alloc = std.testing.allocator;

    var matcher = MatcherTest.init(alloc);
    defer matcher.deinit();

    var p1: NodeTest = .{ .name = "p" };
    var p2: NodeTest = .{ .name = "p" };

    p1.sibling = &p2;
    p2.prev = &p1;

    var root: NodeTest = .{ .child = &p1, .last = &p2 };
    p1.par = &root;
    p2.par = &root;

    const testcases = [_]struct {
        q: []const u8,
        n: NodeTest,
        exp: ?*const NodeTest,
    }{
        .{ .q = "a:nth-of-type(1)", .n = root, .exp = null },
        .{ .q = "p:nth-of-type(1)", .n = root, .exp = &p1 },
        .{ .q = "p:nth-of-type(2)", .n = root, .exp = &p2 },
        .{ .q = "p:nth-of-type(0)", .n = root, .exp = null },
        .{ .q = "p:nth-of-type(2n)", .n = root, .exp = &p2 },
        .{ .q = "p:nth-last-child(1)", .n = root, .exp = &p2 },
        .{ .q = "p:nth-last-child(2)", .n = root, .exp = &p1 },
        .{ .q = "p:nth-child(1)", .n = root, .exp = &p1 },
        .{ .q = "p:nth-child(2)", .n = root, .exp = &p2 },
        .{ .q = "p:nth-child(odd)", .n = root, .exp = &p1 },
        .{ .q = "p:nth-child(even)", .n = root, .exp = &p2 },
        .{ .q = "p:nth-child(n+2)", .n = root, .exp = &p2 },
    };

    for (testcases) |tc| {
        matcher.reset();

        const s = try css.parse(alloc, tc.q, .{});
        defer s.deinit(alloc);

        css.matchAll(&s, &tc.n, &matcher) catch |e| {
            std.debug.print("query: {s}, parsed selector: {any}\n", .{ tc.q, s });
            return e;
        };

        if (tc.exp) |exp_n| {
            const exp: usize = 1;
            std.testing.expectEqual(exp, matcher.nodes.items.len) catch |e| {
                std.debug.print("query: {s}, parsed selector: {any}\n", .{ tc.q, s });
                return e;
            };

            std.testing.expectEqual(exp_n, matcher.nodes.items[0]) catch |e| {
                std.debug.print("query: {s}, parsed selector: {any}\n", .{ tc.q, s });
                return e;
            };

            continue;
        }

        const exp: usize = 0;
        std.testing.expectEqual(exp, matcher.nodes.items.len) catch |e| {
            std.debug.print("query: {s}, parsed selector: {any}\n", .{ tc.q, s });
            return e;
        };
    }
}
