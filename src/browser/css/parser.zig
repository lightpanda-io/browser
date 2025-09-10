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

// CSS Selector parser
// This file is a rewrite in Zig of Cascadia CSS Selector parser.
// see https://github.com/andybalholm/cascadia
// see https://github.com/andybalholm/cascadia/blob/master/parser.go
const std = @import("std");
const ascii = std.ascii;
const Allocator = std.mem.Allocator;

const selector = @import("selector.zig");
const Selector = selector.Selector;
const PseudoClass = selector.PseudoClass;
const AttributeOP = selector.AttributeOP;
const Combinator = selector.Combinator;

const REPLACEMENT_CHARACTER = &.{ 239, 191, 189 };

pub const ParseError = error{
    ExpectedSelector,
    ExpectedIdentifier,
    ExpectedName,
    ExpectedIDSelector,
    ExpectedClassSelector,
    ExpectedAttributeSelector,
    ExpectedString,
    ExpectedRegexp,
    ExpectedPseudoClassSelector,
    ExpectedParenthesis,
    ExpectedParenthesisClose,
    ExpectedNthExpression,
    ExpectedInteger,
    InvalidEscape,
    EscapeLineEndingOutsideString,
    InvalidUnicode,
    UnicodeIsNotHandled,
    WriteError,
    PseudoElementNotAtSelectorEnd,
    PseudoElementNotUnique,
    PseudoElementDisabled,
    InvalidAttributeOperator,
    InvalidAttributeSelector,
    InvalidString,
    InvalidRegexp,
    InvalidPseudoClassSelector,
    EmptyPseudoClassSelector,
    InvalidPseudoClass,
    InvalidPseudoElement,
    UnmatchParenthesis,
    NotHandled,
    UnknownPseudoSelector,
    InvalidNthExpression,
} || PseudoClass.Error || Combinator.Error || std.mem.Allocator.Error;

pub const ParseOptions = struct {
    accept_pseudo_elts: bool = true,
};

pub const Parser = struct {
    s: []const u8, // string to parse
    i: usize = 0, // current position

    opts: ParseOptions,

    pub fn parse(p: *Parser, allocator: Allocator) ParseError!Selector {
        return p.parseSelectorGroup(allocator);
    }

    // skipWhitespace consumes whitespace characters and comments.
    // It returns true if there was actually anything to skip.
    fn skipWhitespace(p: *Parser) bool {
        var i = p.i;
        while (i < p.s.len) {
            const c = p.s[i];
            // Whitespaces.
            if (ascii.isWhitespace(c)) {
                i += 1;
                continue;
            }

            // Comments.
            if (c == '/') {
                if (std.mem.startsWith(u8, p.s[i..], "/*")) {
                    if (std.mem.indexOf(u8, p.s[i..], "*/")) |end| {
                        i += end + "*/".len;
                        continue;
                    }
                }
            }
            break;
        }

        if (i > p.i) {
            p.i = i;
            return true;
        }

        return false;
    }

    // parseSimpleSelectorSequence parses a selector sequence that applies to
    // a single element.
    fn parseSimpleSelectorSequence(p: *Parser, allocator: Allocator) ParseError!Selector {
        if (p.i >= p.s.len) {
            return ParseError.ExpectedSelector;
        }

        var buf: std.ArrayListUnmanaged(Selector) = .empty;
        defer buf.deinit(allocator);

        switch (p.s[p.i]) {
            '*' => {
                // It's the universal selector. Just skip over it, since it
                // doesn't affect the meaning.
                p.i += 1;

                // other version of universal selector
                if (p.i + 2 < p.s.len and std.mem.eql(u8, "|*", p.s[p.i .. p.i + 2])) {
                    p.i += 2;
                }
            },
            '#', '.', '[', ':' => {
                // There's no type selector. Wait to process the other till the
                // main loop.
            },
            else => try buf.append(allocator, try p.parseTypeSelector(allocator)),
        }

        var pseudo_elt: ?PseudoClass = null;

        loop: while (p.i < p.s.len) {
            var ns: Selector = switch (p.s[p.i]) {
                '#' => try p.parseIDSelector(allocator),
                '.' => try p.parseClassSelector(allocator),
                '[' => try p.parseAttributeSelector(allocator),
                ':' => try p.parsePseudoclassSelector(allocator),
                else => break :loop,
            };
            errdefer ns.deinit(allocator);

            // From https://drafts.csswg.org/selectors-3/#pseudo-elements :
            // "Only one pseudo-element may appear per selector, and if present
            // it must appear after the sequence of simple selectors that
            // represents the subjects of the selector.""
            switch (ns) {
                .pseudo_element => |e| {
                    //  We found a pseudo-element.
                    //  Only one pseudo-element is accepted per selector.
                    if (pseudo_elt != null) return ParseError.PseudoElementNotUnique;
                    if (!p.opts.accept_pseudo_elts) return ParseError.PseudoElementDisabled;

                    pseudo_elt = e;
                    ns.deinit(allocator);
                },
                else => {
                    if (pseudo_elt != null) return ParseError.PseudoElementNotAtSelectorEnd;
                    try buf.append(allocator, ns);
                },
            }
        }

        // no need wrap the selectors in compoundSelector
        if (buf.items.len == 1 and pseudo_elt == null) {
            return buf.items[0];
        }

        return .{
            .compound = .{ .selectors = try buf.toOwnedSlice(allocator), .pseudo_elt = pseudo_elt },
        };
    }

    // parseTypeSelector parses a type selector (one that matches by tag name).
    fn parseTypeSelector(p: *Parser, allocator: Allocator) ParseError!Selector {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(allocator);
        try p.parseIdentifier(buf.writer(allocator));

        return .{ .tag = try buf.toOwnedSlice(allocator) };
    }

    // parseIdentifier parses an identifier.
    fn parseIdentifier(p: *Parser, w: anytype) ParseError!void {
        const prefix = '-';
        var numPrefix: usize = 0;

        while (p.s.len > p.i and p.s[p.i] == prefix) {
            p.i += 1;
            numPrefix += 1;
        }

        if (p.s.len <= p.i) {
            return ParseError.ExpectedSelector;
        }

        const c = p.s[p.i];
        if (!(nameStart(c) or c == '\\')) {
            return ParseError.ExpectedSelector;
        }

        var ii: usize = 0;
        while (ii < numPrefix) {
            w.writeByte(prefix) catch return ParseError.WriteError;
            ii += 1;
        }
        try parseName(p, w);
    }

    // parseName parses a name (which is like an identifier, but doesn't have
    // extra restrictions on the first character).
    fn parseName(p: *Parser, w: anytype) ParseError!void {
        const sel = p.s;
        const sel_len = sel.len;

        var i = p.i;
        var ok = false;

        while (i < sel_len) {
            const c = sel[i];

            if (nameChar(c)) {
                const start = i;
                while (i < sel_len and nameChar(sel[i])) i += 1;
                w.writeAll(sel[start..i]) catch return ParseError.WriteError;
                ok = true;
            } else if (c == '\\') {
                p.i = i;
                try p.parseEscape(w);
                i = p.i;
                ok = true;
            } else if (c == 0) {
                w.writeAll(REPLACEMENT_CHARACTER) catch return ParseError.WriteError;
                i += 1;
                if (i == sel_len) {
                    ok = true;
                }
            } else {
                // default:
                break;
            }
        }

        if (!ok) return ParseError.ExpectedName;
        p.i = i;
    }

    // parseEscape parses a backslash escape.
    // The returned string is owned by the caller.
    fn parseEscape(p: *Parser, w: anytype) ParseError!void {
        const sel = p.s;
        const sel_len = sel.len;

        if (sel_len < p.i + 2 or sel[p.i] != '\\') {
            p.i += 1;
            w.writeAll(REPLACEMENT_CHARACTER) catch return ParseError.WriteError;
            return;
        }

        const start = p.i + 1;
        const c = sel[start];

        // unicode escape (hex)
        if (ascii.isHex(c)) {
            var i: usize = start;
            while (i < start + 6 and i < sel_len and ascii.isHex(sel[i])) {
                i += 1;
            }

            const v = std.fmt.parseUnsigned(u21, sel[start..i], 16) catch {
                p.i = i;
                w.writeAll(REPLACEMENT_CHARACTER) catch return ParseError.WriteError;
                return;
            };

            if (sel_len >= i) {
                if (sel_len > i) {
                    switch (sel[i]) {
                        '\r' => {
                            i += 1;
                            if (sel_len > i and sel[i] == '\n') i += 1;
                        },
                        ' ', '\t', '\n', std.ascii.control_code.ff => i += 1,
                        else => {},
                    }
                }
                p.i = i;
                if (v == 0) {
                    w.writeAll(REPLACEMENT_CHARACTER) catch return ParseError.WriteError;
                    return;
                }
                var buf: [4]u8 = undefined;
                const ln = std.unicode.utf8Encode(v, &buf) catch {
                    w.writeAll(REPLACEMENT_CHARACTER) catch return ParseError.WriteError;
                    return;
                };
                w.writeAll(buf[0..ln]) catch return ParseError.WriteError;
                return;
            }
        }

        // Return the literal character after the backslash.
        p.i += 2;
        w.writeByte(sel[start]) catch return ParseError.WriteError;
    }

    // parseIDSelector parses a selector that matches by id attribute.
    fn parseIDSelector(p: *Parser, allocator: Allocator) ParseError!Selector {
        if (p.i >= p.s.len) return ParseError.ExpectedIDSelector;
        if (p.s[p.i] != '#') return ParseError.ExpectedIDSelector;

        p.i += 1;

        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(allocator);

        try p.parseName(buf.writer(allocator));
        return .{ .id = try buf.toOwnedSlice(allocator) };
    }

    // parseClassSelector parses a selector that matches by class attribute.
    fn parseClassSelector(p: *Parser, allocator: Allocator) ParseError!Selector {
        if (p.i >= p.s.len) return ParseError.ExpectedClassSelector;
        if (p.s[p.i] != '.') return ParseError.ExpectedClassSelector;

        p.i += 1;

        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(allocator);

        try p.parseIdentifier(buf.writer(allocator));
        return .{ .class = try buf.toOwnedSlice(allocator) };
    }

    // parseAttributeSelector parses a selector that matches by attribute value.
    fn parseAttributeSelector(p: *Parser, allocator: Allocator) ParseError!Selector {
        if (p.i >= p.s.len) return ParseError.ExpectedAttributeSelector;
        if (p.s[p.i] != '[') return ParseError.ExpectedAttributeSelector;

        p.i += 1;
        _ = p.skipWhitespace();

        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(allocator);

        try p.parseIdentifier(buf.writer(allocator));
        const key = try buf.toOwnedSlice(allocator);
        errdefer allocator.free(key);

        lowerstr(key);

        _ = p.skipWhitespace();
        if (p.i >= p.s.len) return ParseError.ExpectedAttributeSelector;
        if (p.s[p.i] == ']') {
            p.i += 1;
            return .{ .attribute = .{ .key = key } };
        }

        if (p.i + 2 >= p.s.len) return ParseError.ExpectedAttributeSelector;

        const op = try parseAttributeOP(p.s[p.i .. p.i + 2]);
        p.i += op.len();

        _ = p.skipWhitespace();
        if (p.i >= p.s.len) return ParseError.ExpectedAttributeSelector;

        buf.clearRetainingCapacity();
        var is_val: bool = undefined;
        if (op == .regexp) {
            is_val = false;
            try p.parseRegex(buf.writer(allocator));
        } else {
            is_val = true;
            switch (p.s[p.i]) {
                '\'', '"' => try p.parseString(buf.writer(allocator)),
                else => try p.parseIdentifier(buf.writer(allocator)),
            }
        }

        _ = p.skipWhitespace();
        if (p.i >= p.s.len) return ParseError.ExpectedAttributeSelector;

        // check if the attribute contains an ignore case flag
        var ci = false;
        if (p.s[p.i] == 'i' or p.s[p.i] == 'I') {
            ci = true;
            p.i += 1;
        }

        _ = p.skipWhitespace();
        if (p.i >= p.s.len) return ParseError.ExpectedAttributeSelector;

        if (p.s[p.i] != ']') return ParseError.InvalidAttributeSelector;
        p.i += 1;

        return .{ .attribute = .{
            .key = key,
            .val = if (is_val) try buf.toOwnedSlice(allocator) else null,
            .regexp = if (!is_val) try buf.toOwnedSlice(allocator) else null,
            .op = op,
            .ci = ci,
        } };
    }

    // parseString parses a single- or double-quoted string.
    fn parseString(p: *Parser, writer: anytype) ParseError!void {
        const sel = p.s;
        const sel_len = sel.len;

        var i = p.i;
        if (sel_len < i + 2) return ParseError.ExpectedString;

        const quote = sel[i];
        i += 1;

        loop: while (i < sel_len) {
            switch (sel[i]) {
                '\\' => {
                    if (sel_len > i + 1) {
                        const c = sel[i + 1];
                        switch (c) {
                            '\r' => {
                                if (sel_len > i + 2 and sel[i + 2] == '\n') {
                                    i += 3;
                                    continue :loop;
                                }
                                i += 2;
                                continue :loop;
                            },
                            '\n', std.ascii.control_code.ff => {
                                i += 2;
                                continue :loop;
                            },
                            else => {},
                        }
                    }
                    p.i = i;
                    try p.parseEscape(writer);
                    i = p.i;
                },
                '\r', '\n', std.ascii.control_code.ff => return ParseError.InvalidString,
                else => |c| {
                    if (c == quote) break :loop;
                    const start = i;
                    while (i < sel_len) {
                        const cc = sel[i];
                        if (cc == quote or cc == '\\' or c == '\r' or c == '\n' or c == std.ascii.control_code.ff) break;
                        i += 1;
                    }
                    writer.writeAll(sel[start..i]) catch return ParseError.WriteError;
                },
            }
        }

        if (i >= sel_len) return ParseError.InvalidString;

        // Consume the final quote.
        i += 1;
        p.i = i;
    }

    // parseRegex parses a regular expression; the end is defined by encountering an
    // unmatched closing ')' or ']' which is not consumed
    fn parseRegex(p: *Parser, writer: anytype) ParseError!void {
        var i = p.i;
        if (p.s.len < i + 2) return ParseError.ExpectedRegexp;

        // number of open parens or brackets;
        // when it becomes negative, finished parsing regex
        var open: isize = 0;

        loop: while (i < p.s.len) {
            switch (p.s[i]) {
                '(', '[' => open += 1,
                ')', ']' => {
                    open -= 1;
                    if (open < 0) break :loop;
                },
                else => {},
            }
            i += 1;
        }

        if (i >= p.s.len) return ParseError.InvalidRegexp;
        writer.writeAll(p.s[p.i..i]) catch return ParseError.WriteError;
        p.i = i;
    }

    // parsePseudoclassSelector parses a pseudoclass selector like :not(p) or a pseudo-element
    // For backwards compatibility, both ':' and '::' prefix are allowed for pseudo-elements.
    // https://drafts.csswg.org/selectors-3/#pseudo-elements
    fn parsePseudoclassSelector(p: *Parser, allocator: Allocator) ParseError!Selector {
        if (p.i >= p.s.len) return ParseError.ExpectedPseudoClassSelector;
        if (p.s[p.i] != ':') return ParseError.ExpectedPseudoClassSelector;

        p.i += 1;

        var must_pseudo_elt: bool = false;
        if (p.i >= p.s.len) return ParseError.EmptyPseudoClassSelector;
        if (p.s[p.i] == ':') { // we found a pseudo-element
            must_pseudo_elt = true;
            p.i += 1;
        }

        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(allocator);

        try p.parseIdentifier(buf.writer(allocator));

        const pseudo_class = try PseudoClass.parse(buf.items);

        // reset the buffer to reuse it.
        buf.clearRetainingCapacity();

        if (must_pseudo_elt and !pseudo_class.isPseudoElement()) return ParseError.InvalidPseudoElement;

        switch (pseudo_class) {
            .not, .has, .haschild => {
                if (!p.consumeParenthesis()) return ParseError.ExpectedParenthesis;

                const sel = try p.parseSelectorGroup(allocator);
                if (!p.consumeClosingParenthesis()) return ParseError.ExpectedParenthesisClose;

                const s = try allocator.create(Selector);
                errdefer allocator.destroy(s);
                s.* = sel;

                return .{ .pseudo_class_relative = .{ .pseudo_class = pseudo_class, .match = s } };
            },
            .contains, .containsown => {
                if (!p.consumeParenthesis()) return ParseError.ExpectedParenthesis;
                if (p.i == p.s.len) return ParseError.UnmatchParenthesis;

                switch (p.s[p.i]) {
                    '\'', '"' => try p.parseString(buf.writer(allocator)),
                    else => try p.parseString(buf.writer(allocator)),
                }

                _ = p.skipWhitespace();
                if (p.i >= p.s.len) return ParseError.InvalidPseudoClass;
                if (!p.consumeClosingParenthesis()) return ParseError.ExpectedParenthesisClose;

                const val = try buf.toOwnedSlice(allocator);
                errdefer allocator.free(val);

                return .{ .pseudo_class_contains = .{ .own = pseudo_class == .containsown, .val = val } };
            },
            .matches, .matchesown => {
                if (!p.consumeParenthesis()) return ParseError.ExpectedParenthesis;

                try p.parseRegex(buf.writer(allocator));
                if (p.i >= p.s.len) return ParseError.InvalidPseudoClassSelector;
                if (!p.consumeClosingParenthesis()) return ParseError.ExpectedParenthesisClose;

                return .{ .pseudo_class_regexp = .{ .own = pseudo_class == .matchesown, .regexp = try buf.toOwnedSlice(allocator) } };
            },
            .nth_child, .nth_last_child, .nth_of_type, .nth_last_of_type => {
                if (!p.consumeParenthesis()) return ParseError.ExpectedParenthesis;
                const nth = try p.parseNth(allocator);
                if (!p.consumeClosingParenthesis()) return ParseError.ExpectedParenthesisClose;

                const last = pseudo_class == .nth_last_child or pseudo_class == .nth_last_of_type;
                const of_type = pseudo_class == .nth_of_type or pseudo_class == .nth_last_of_type;
                return .{ .pseudo_class_nth = .{ .a = nth[0], .b = nth[1], .of_type = of_type, .last = last } };
            },
            .first_child => return .{ .pseudo_class_nth = .{ .a = 0, .b = 1, .of_type = false, .last = false } },
            .last_child => return .{ .pseudo_class_nth = .{ .a = 0, .b = 1, .of_type = false, .last = true } },
            .first_of_type => return .{ .pseudo_class_nth = .{ .a = 0, .b = 1, .of_type = true, .last = false } },
            .last_of_type => return .{ .pseudo_class_nth = .{ .a = 0, .b = 1, .of_type = true, .last = true } },
            .only_child => return .{ .pseudo_class_only_child = false },
            .only_of_type => return .{ .pseudo_class_only_child = true },
            .input, .empty, .root, .link => return .{ .pseudo_class = pseudo_class },
            .enabled, .disabled, .checked => return .{ .pseudo_class = pseudo_class },
            .visible => return .{ .pseudo_class = pseudo_class },
            .lang => {
                if (!p.consumeParenthesis()) return ParseError.ExpectedParenthesis;
                if (p.i == p.s.len) return ParseError.UnmatchParenthesis;

                try p.parseIdentifier(buf.writer(allocator));

                _ = p.skipWhitespace();
                if (p.i >= p.s.len) return ParseError.InvalidPseudoClass;
                if (!p.consumeClosingParenthesis()) return ParseError.ExpectedParenthesisClose;

                const val = try buf.toOwnedSlice(allocator);
                errdefer allocator.free(val);
                lowerstr(val);

                return .{ .pseudo_class_lang = val };
            },
            .visited, .hover, .active, .focus, .target => {
                // Not applicable in a static context: never match.
                return .{ .never_match = pseudo_class };
            },
            .after, .backdrop, .before, .cue, .first_letter => return .{ .pseudo_element = pseudo_class },
            .first_line, .grammar_error, .marker, .placeholder => return .{ .pseudo_element = pseudo_class },
            .selection, .spelling_error => return .{ .pseudo_element = pseudo_class },
            .modal, .popover_open => return .{ .pseudo_element = pseudo_class },
        }
    }

    // consumeParenthesis consumes an opening parenthesis and any following
    // whitespace. It returns true if there was actually a parenthesis to skip.
    fn consumeParenthesis(p: *Parser) bool {
        if (p.i < p.s.len and p.s[p.i] == '(') {
            p.i += 1;
            _ = p.skipWhitespace();
            return true;
        }
        return false;
    }

    // parseSelectorGroup parses a group of selectors, separated by commas.
    fn parseSelectorGroup(p: *Parser, allocator: Allocator) ParseError!Selector {
        const s = try p.parseSelector(allocator);

        var buf: std.ArrayListUnmanaged(Selector) = .empty;
        defer buf.deinit(allocator);

        try buf.append(allocator, s);

        while (p.i < p.s.len) {
            if (p.s[p.i] != ',') break;
            p.i += 1;
            const ss = try p.parseSelector(allocator);
            try buf.append(allocator, ss);
        }

        if (buf.items.len == 1) {
            return buf.items[0];
        }

        return .{ .group = try buf.toOwnedSlice(allocator) };
    }

    // parseSelector parses a selector that may include combinators.
    fn parseSelector(p: *Parser, allocator: Allocator) ParseError!Selector {
        _ = p.skipWhitespace();
        var s = try p.parseSimpleSelectorSequence(allocator);

        while (true) {
            var combinator: Combinator = .empty;
            if (p.skipWhitespace()) {
                combinator = .descendant;
            }
            if (p.i >= p.s.len) {
                return s;
            }

            switch (p.s[p.i]) {
                '+', '>', '~' => {
                    combinator = try Combinator.parse(p.s[p.i]);
                    p.i += 1;
                    _ = p.skipWhitespace();
                },
                // These characters can't begin a selector, but they can legally occur after one.
                ',', ')' => {
                    return s;
                },
                else => {},
            }

            if (combinator == .empty) {
                return s;
            }

            const c = try p.parseSimpleSelectorSequence(allocator);

            const first = try allocator.create(Selector);
            errdefer allocator.destroy(first);
            first.* = s;

            const second = try allocator.create(Selector);
            errdefer allocator.destroy(second);
            second.* = c;

            s = Selector{ .combined = .{
                .first = first,
                .second = second,
                .combinator = combinator,
            } };
        }

        return s;
    }

    // consumeClosingParenthesis consumes a closing parenthesis and any preceding
    // whitespace. It returns true if there was actually a parenthesis to skip.
    fn consumeClosingParenthesis(p: *Parser) bool {
        const i = p.i;
        _ = p.skipWhitespace();
        if (p.i < p.s.len and p.s[p.i] == ')') {
            p.i += 1;
            return true;
        }
        p.i = i;
        return false;
    }

    // parseInteger parses a  decimal integer.
    fn parseInteger(p: *Parser) ParseError!isize {
        var i = p.i;
        const start = i;
        while (i < p.s.len and '0' <= p.s[i] and p.s[i] <= '9') i += 1;
        if (i == start) return ParseError.ExpectedInteger;
        p.i = i;

        return std.fmt.parseUnsigned(isize, p.s[start..i], 10) catch ParseError.ExpectedInteger;
    }

    fn parseNthReadN(p: *Parser, a: isize) ParseError![2]isize {
        _ = p.skipWhitespace();
        if (p.i >= p.s.len) return ParseError.ExpectedNthExpression;

        return switch (p.s[p.i]) {
            '+' => {
                p.i += 1;
                _ = p.skipWhitespace();
                const b = try p.parseInteger();
                return .{ a, b };
            },
            '-' => {
                p.i += 1;
                _ = p.skipWhitespace();
                const b = try p.parseInteger();
                return .{ a, -b };
            },
            else => .{ a, 0 },
        };
    }

    fn parseNthReadA(p: *Parser, a: isize) ParseError![2]isize {
        if (p.i >= p.s.len) return ParseError.ExpectedNthExpression;
        return switch (p.s[p.i]) {
            'n', 'N' => {
                p.i += 1;
                return p.parseNthReadN(a);
            },
            else => .{ 0, a },
        };
    }

    fn parseNthNegativeA(p: *Parser) ParseError![2]isize {
        if (p.i >= p.s.len) return ParseError.ExpectedNthExpression;
        const c = p.s[p.i];
        if (std.ascii.isDigit(c)) {
            const a = try p.parseInteger() * -1;
            return p.parseNthReadA(a);
        }
        if (c == 'n' or c == 'N') {
            p.i += 1;
            return p.parseNthReadN(-1);
        }

        return ParseError.InvalidNthExpression;
    }

    fn parseNthPositiveA(p: *Parser) ParseError![2]isize {
        if (p.i >= p.s.len) return ParseError.ExpectedNthExpression;
        const c = p.s[p.i];
        if (std.ascii.isDigit(c)) {
            const a = try p.parseInteger();
            return p.parseNthReadA(a);
        }
        if (c == 'n' or c == 'N') {
            p.i += 1;
            return p.parseNthReadN(1);
        }

        return ParseError.InvalidNthExpression;
    }

    // parseNth parses the argument for :nth-child (normally of the form an+b).
    fn parseNth(p: *Parser, allocator: Allocator) ParseError![2]isize {
        // initial state
        if (p.i >= p.s.len) return ParseError.ExpectedNthExpression;
        return switch (p.s[p.i]) {
            '-' => {
                p.i += 1;
                return p.parseNthNegativeA();
            },
            '+' => {
                p.i += 1;
                return p.parseNthPositiveA();
            },
            '0', '1', '2', '3', '4', '5', '6', '7', '8', '9' => p.parseNthPositiveA(),
            'n', 'N' => {
                p.i += 1;
                return p.parseNthReadN(1);
            },
            'o', 'O', 'e', 'E' => {
                var buf: std.ArrayListUnmanaged(u8) = .empty;
                defer buf.deinit(allocator);

                try p.parseName(buf.writer(allocator));

                if (std.ascii.eqlIgnoreCase("odd", buf.items)) return .{ 2, 1 };
                if (std.ascii.eqlIgnoreCase("even", buf.items)) return .{ 2, 0 };

                return ParseError.InvalidNthExpression;
            },
            else => ParseError.InvalidNthExpression,
        };
    }
};

// nameStart returns whether c can be the first character of an identifier
// (not counting an initial hyphen, or an escape sequence).
fn nameStart(c: u8) bool {
    return 'a' <= c and c <= 'z' or 'A' <= c and c <= 'Z' or c == '_' or c > 127;
}

// nameChar returns whether c can be a character within an identifier
// (not counting an escape sequence).
fn nameChar(c: u8) bool {
    return 'a' <= c and c <= 'z' or 'A' <= c and c <= 'Z' or c == '_' or c > 127 or
        c == '-' or '0' <= c and c <= '9';
}

fn lowerstr(str: []u8) void {
    for (str, 0..) |c, i| {
        str[i] = std.ascii.toLower(c);
    }
}

// parseAttributeOP parses an AttributeOP from a string of 1 or 2 bytes.
fn parseAttributeOP(s: []const u8) ParseError!AttributeOP {
    if (s.len < 1 or s.len > 2) return ParseError.InvalidAttributeOperator;

    // if the first sign is equal, we don't check anything else.
    if (s[0] == '=') return .eql;

    if (s.len != 2 or s[1] != '=') return ParseError.InvalidAttributeOperator;

    return switch (s[0]) {
        '=' => .eql,
        '!' => .not_eql,
        '~' => .one_of,
        '|' => .prefix_hyphen,
        '^' => .prefix,
        '$' => .suffix,
        '*' => .contains,
        '#' => .regexp,
        else => ParseError.InvalidAttributeOperator,
    };
}

test "parser.skipWhitespace" {
    const testcases = [_]struct {
        s: []const u8,
        i: usize,
        r: bool,
    }{
        .{ .s = "", .i = 0, .r = false },
        .{ .s = "foo", .i = 0, .r = false },
        .{ .s = " ", .i = 1, .r = true },
        .{ .s = " foo", .i = 1, .r = true },
        .{ .s = "/* foo */ bar", .i = 10, .r = true },
        .{ .s = "/* foo", .i = 0, .r = false },
    };

    for (testcases) |tc| {
        var p = Parser{ .s = tc.s, .opts = .{} };
        const res = p.skipWhitespace();
        try std.testing.expectEqual(tc.r, res);
        try std.testing.expectEqual(tc.i, p.i);
    }
}

test "parser.parseIdentifier" {
    const allocator = std.testing.allocator;

    const testcases = [_]struct {
        s: []const u8, // given value
        exp: []const u8, // expected value
        err: bool = false,
    }{
        .{ .s = "x", .exp = "x" },
        .{ .s = "96", .exp = "", .err = true },
        .{ .s = "-x", .exp = "-x" },
        .{ .s = "r\\e9 sumé", .exp = "résumé" },
        .{ .s = "r\\0000e9 sumé", .exp = "résumé" },
        .{ .s = "r\\0000e9sumé", .exp = "résumé" },
        .{ .s = "a\\\"b", .exp = "a\"b" },
    };

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    for (testcases) |tc| {
        buf.clearRetainingCapacity();

        var p = Parser{ .s = tc.s, .opts = .{} };
        p.parseIdentifier(buf.writer(allocator)) catch |e| {
            // if error was expected, continue.
            if (tc.err) continue;

            std.debug.print("test case {s}\n", .{tc.s});
            return e;
        };
        std.testing.expectEqualDeep(tc.exp, buf.items) catch |e| {
            std.debug.print("test case {s} : {s}\n", .{ tc.s, buf.items });
            return e;
        };
    }
}

test "parser.parseString" {
    const allocator = std.testing.allocator;

    const testcases = [_]struct {
        s: []const u8, // given value
        exp: []const u8, // expected value
        err: bool = false,
    }{
        .{ .s = "\"x\"", .exp = "x" },
        .{ .s = "'x'", .exp = "x" },
        .{ .s = "'x", .exp = "", .err = true },
        .{ .s = "'x\\\r\nx'", .exp = "xx" },
        .{ .s = "\"r\\e9 sumé\"", .exp = "résumé" },
        .{ .s = "\"r\\0000e9 sumé\"", .exp = "résumé" },
        .{ .s = "\"r\\0000e9sumé\"", .exp = "résumé" },
        .{ .s = "\"a\\\"b\"", .exp = "a\"b" },
        .{ .s = "\"\\\n\"", .exp = "" },
        .{ .s = "\"hello world\"", .exp = "hello world" },
    };

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    for (testcases) |tc| {
        buf.clearRetainingCapacity();

        var p = Parser{ .s = tc.s, .opts = .{} };
        p.parseString(buf.writer(allocator)) catch |e| {
            // if error was expected, continue.
            if (tc.err) continue;

            std.debug.print("test case {s}\n", .{tc.s});
            return e;
        };
        std.testing.expectEqualDeep(tc.exp, buf.items) catch |e| {
            std.debug.print("test case {s} : {s}\n", .{ tc.s, buf.items });
            return e;
        };
    }
}

test "parser.parse" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const testcases = [_]struct {
        s: []const u8, // given value
        exp: Selector, // expected value
        err: bool = false,
    }{
        .{ .s = "root", .exp = .{ .tag = "root" } },
        .{ .s = ".root", .exp = .{ .class = "root" } },
        .{ .s = ":root", .exp = .{ .pseudo_class = .root } },
        .{ .s = ".\\:bar", .exp = .{ .class = ":bar" } },
        .{ .s = ".foo\\:bar", .exp = .{ .class = "foo:bar" } },
    };

    for (testcases) |tc| {
        var p = Parser{ .s = tc.s, .opts = .{} };
        const sel = p.parse(allocator) catch |e| {
            // if error was expected, continue.
            if (tc.err) continue;

            std.debug.print("test case {s}\n", .{tc.s});
            return e;
        };
        std.testing.expectEqualDeep(tc.exp, sel) catch |e| {
            std.debug.print("test case {s} : {}\n", .{ tc.s, sel });
            return e;
        };
    }
}
