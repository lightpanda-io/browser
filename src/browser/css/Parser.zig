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
const Tokenizer = @import("Tokenizer.zig");

pub const Declaration = struct {
    name: []const u8,
    value: []const u8,
    important: bool,
};

pub const AxisPair = struct { x: []const u8, y: []const u8 };

pub const AxisShorthand = struct {
    name: []const u8,
    x: []const u8,
    y: []const u8,
};

// The `<x> [<y>]` shorthands whose longhands the style cascade tracks. Both the
// CSSOM object and the cascade store these expanded: setting one sets both
// longhands, reading or serializing it recombines them.
pub const axis_shorthands = [_]AxisShorthand{
    .{ .name = "overflow", .x = "overflow-x", .y = "overflow-y" },
    .{ .name = "overscroll-behavior", .x = "overscroll-behavior-x", .y = "overscroll-behavior-y" },
};

/// The axis shorthand `name` names, if it names one.
pub fn axisShorthand(name: []const u8) ?AxisShorthand {
    for (axis_shorthands) |shorthand| {
        if (std.ascii.eqlIgnoreCase(name, shorthand.name)) {
            return shorthand;
        }
    }
    return null;
}

pub const AxisLonghand = struct {
    shorthand: AxisShorthand,
    is_x: bool,

    /// The longhand on the other axis.
    pub fn partner(self: AxisLonghand) []const u8 {
        return if (self.is_x) self.shorthand.y else self.shorthand.x;
    }
};

/// The axis shorthand `name` is a longhand of, if it is one.
pub fn axisLonghand(name: []const u8) ?AxisLonghand {
    for (axis_shorthands) |shorthand| {
        if (std.ascii.eqlIgnoreCase(name, shorthand.x)) {
            return .{ .shorthand = shorthand, .is_x = true };
        }
        if (std.ascii.eqlIgnoreCase(name, shorthand.y)) {
            return .{ .shorthand = shorthand, .is_x = false };
        }
    }
    return null;
}

/// An `<x> [<y>]` axis shorthand such as `overflow` or `overscroll-behavior`;
/// a single value applies to both axes. More than two values is invalid and
/// null, as is an empty declaration.
pub fn splitAxisPair(value: []const u8) ?AxisPair {
    var it = std.mem.tokenizeAny(u8, value, &std.ascii.whitespace);
    const x = it.next() orelse return null;
    const y = it.next() orelse x;
    if (it.next() != null) {
        return null;
    }
    return .{ .x = x, .y = y };
}

const TokenSpan = struct {
    token: Tokenizer.Token,
    start: usize,
    end: usize,
};

const TokenStream = struct {
    tokenizer: Tokenizer,
    peeked: ?TokenSpan = null,

    fn init(input: []const u8) TokenStream {
        return .{ .tokenizer = .{ .input = input } };
    }

    fn nextRaw(self: *TokenStream) ?TokenSpan {
        const start = self.tokenizer.position;
        const token = self.tokenizer.next() orelse return null;
        const end = self.tokenizer.position;
        return .{ .token = token, .start = start, .end = end };
    }

    fn next(self: *TokenStream) ?TokenSpan {
        if (self.peeked) |token| {
            self.peeked = null;
            return token;
        }
        return self.nextRaw();
    }

    fn peek(self: *TokenStream) ?TokenSpan {
        if (self.peeked == null) {
            self.peeked = self.nextRaw();
        }
        return self.peeked;
    }
};

/// The declarations of a `style` attribute or of a `cssText` assignment, on an
/// element's style or a rule's. Browsers don't parse nested rules there: a
/// `&.x { … }` is an invalid declaration, skipped through the next top-level
/// `;` along with whatever follows it.
pub fn parseDeclarationsList(input: []const u8) DeclarationsIterator {
    return DeclarationsIterator.init(input, false);
}

/// The block of a style rule read from a stylesheet (`<style>`, `insertRule`,
/// `replace`). CSS Nesting applies: a nested rule ends at its own `}`, so the
/// declarations after it still parse.
pub fn parseStyleBlock(input: []const u8) DeclarationsIterator {
    return DeclarationsIterator.init(input, true);
}

pub const DeclarationsIterator = struct {
    input: []const u8,
    stream: TokenStream,
    nesting: bool,

    pub fn init(input: []const u8, nesting: bool) DeclarationsIterator {
        return .{
            .input = input,
            .stream = TokenStream.init(input),
            .nesting = nesting,
        };
    }

    /// The block's declarations, skipping the rules nested in it.
    pub fn next(self: *DeclarationsIterator) ?Declaration {
        while (self.nextItem()) |item| {
            switch (item) {
                .declaration => |declaration| return declaration,
                .rule, .at_rule => {},
            }
        }
        return null;
    }

    /// The block's contents (css-syntax-3 "consume a block's contents"): its
    /// declarations and at-rules and, from `parseStyleBlock`, the style rules
    /// nested in it (CSS Nesting).
    pub fn nextItem(self: *DeclarationsIterator) ?BlockItem {
        while (true) {
            self.skipTriviaAndSemicolons();
            const peeked = self.stream.peek() orelse return null;

            if (peeked.token == .at_keyword) {
                return .{ .at_rule = consumeAtRule(&self.stream, self.input) };
            }

            const mark = self.stream;
            if (peeked.token == .ident) {
                _ = self.stream.next();
                if (self.consumeDeclaration(peeked.token.ident)) |declaration| {
                    return .{ .declaration = declaration };
                }
            }

            // Not a declaration, e.g. `&.x { … }` or `div:hover { … }`:
            // consume it again, as a nested rule where nesting applies.
            self.stream = mark;
            if (!self.nesting) {
                skipInvalidDeclaration(&self.stream);
            } else if (consumeNestedRule(&self.stream, self.input)) |rule| {
                return .{ .rule = rule };
            }
        }
    }

    fn consumeDeclaration(self: *DeclarationsIterator, name: []const u8) ?Declaration {
        self.skipTrivia();

        const colon = self.stream.next() orelse return null;
        if (!isColon(colon.token)) {
            return null;
        }

        // Only a custom property's value may hold a `{}` block. Anywhere
        // else, the block makes this a nested rule or, without nesting, an
        // invalid declaration.
        const value = self.consumeValue(std.mem.startsWith(u8, name, "--")) orelse return null;
        return .{
            .name = name,
            .value = value.value,
            .important = value.important,
        };
    }

    const ValueResult = struct {
        value: []const u8,
        important: bool,
    };

    fn consumeValue(self: *DeclarationsIterator, allow_block: bool) ?ValueResult {
        self.skipTrivia();

        var depth: usize = 0;
        var start: ?usize = null;
        var last_sig: ?TokenSpan = null;
        var prev_sig: ?TokenSpan = null;

        while (true) {
            const peeked = self.stream.peek() orelse break;
            if (isSemicolon(peeked.token) and depth == 0) {
                _ = self.stream.next();
                break;
            }
            if (!allow_block and depth == 0 and peeked.token == .curly_bracket_block) {
                return null;
            }

            const span = self.stream.next() orelse break;
            if (isWhitespaceOrComment(span.token)) {
                continue;
            }

            if (start == null) start = span.start;
            prev_sig = last_sig;
            last_sig = span;
            updateDepth(span.token, &depth);
        }

        const value_start = start orelse return null;
        const last = last_sig orelse return null;

        var important = false;
        var end_pos = last.end;

        if (isImportantPair(prev_sig, last)) {
            important = true;
            const bang = prev_sig orelse return null;
            if (value_start >= bang.start) return null;
            end_pos = bang.start;
        }

        var value_slice = self.input[value_start..end_pos];
        value_slice = std.mem.trim(u8, value_slice, &std.ascii.whitespace);
        if (value_slice.len == 0) return null;

        return .{ .value = value_slice, .important = important };
    }

    fn skipTrivia(self: *DeclarationsIterator) void {
        while (self.stream.peek()) |peeked| {
            if (!isWhitespaceOrComment(peeked.token)) break;
            _ = self.stream.next();
        }
    }

    fn skipTriviaAndSemicolons(self: *DeclarationsIterator) void {
        while (self.stream.peek()) |peeked| {
            if (isWhitespaceOrComment(peeked.token) or isSemicolon(peeked.token)) {
                _ = self.stream.next();
            } else {
                break;
            }
        }
    }
};

fn isWhitespaceOrComment(token: Tokenizer.Token) bool {
    return switch (token) {
        .white_space, .comment => true,
        else => false,
    };
}

fn isSemicolon(token: Tokenizer.Token) bool {
    return switch (token) {
        .semicolon => true,
        else => false,
    };
}

fn isColon(token: Tokenizer.Token) bool {
    return switch (token) {
        .colon => true,
        else => false,
    };
}

fn isBlockStart(token: Tokenizer.Token) bool {
    return switch (token) {
        .curly_bracket_block, .square_bracket_block, .parenthesis_block, .function => true,
        else => false,
    };
}

fn isBlockEnd(token: Tokenizer.Token) bool {
    return switch (token) {
        .close_curly_bracket, .close_parenthesis, .close_square_bracket => true,
        else => false,
    };
}

fn updateDepth(token: Tokenizer.Token, depth: *usize) void {
    if (isBlockStart(token)) {
        depth.* += 1;
        return;
    }

    if (isBlockEnd(token)) {
        if (depth.* > 0) depth.* -= 1;
    }
}

fn isImportantPair(prev_sig: ?TokenSpan, last_sig: TokenSpan) bool {
    if (!isIdentImportant(last_sig.token)) return false;
    const prev = prev_sig orelse return false;
    return isBang(prev.token);
}

fn isIdentImportant(token: Tokenizer.Token) bool {
    return switch (token) {
        .ident => |name| std.ascii.eqlIgnoreCase(name, "important"),
        else => false,
    };
}

fn isBang(token: Tokenizer.Token) bool {
    return switch (token) {
        .delim => |c| c == '!',
        else => false,
    };
}

const StyleRule = struct {
    selector: []const u8,
    block: []const u8,
};

/// An at-rule (`@keyframes`, `@media`, `@supports`, `@font-face`, etc.).
///
/// We don't apply at-rules to the page (the CSS engine doesn't process them
/// yet), but we do surface them so that JS-side reads via `cssRules` see
/// what was inserted. CSS-in-JS libraries (styled-components, emotion,
/// Stitches, Mantine) deduplicate their stylesheets by reading back
/// `cssRules` after `insertRule` -- if the rule is missing they fall back to
/// per-render `<style>` element injection, which leaks unboundedly. See
/// lightpanda-io/browser#2459.
const AtRule = struct {
    /// At-keyword without the leading `@` (e.g., `"keyframes"`, `"media"`,
    /// `"-webkit-keyframes"`). Borrowed from the input slice; copy if you
    /// need to outlive the input.
    keyword: []const u8,
    /// Full at-rule source span starting at `@` and ending after the closing
    /// brace (block at-rules) or semicolon (statement at-rules). Borrowed
    /// from the input slice.
    text: []const u8,
};

const Rule = union(enum) {
    style: StyleRule,
    at_rule: AtRule,
};

/// An item of a style rule's block. With CSS Nesting, a block holds style
/// rules and at-rules next to its declarations. A nested style rule's
/// selector is its raw source (`&.active`, `> li`); `resolveNestedSelector`
/// resolves it against the enclosing rule's selector.
pub const BlockItem = union(enum) {
    declaration: Declaration,
    rule: StyleRule,
    at_rule: AtRule,
};

pub fn parseStylesheet(input: []const u8) RulesIterator {
    return RulesIterator.init(input);
}

pub const RulesIterator = struct {
    input: []const u8,
    stream: TokenStream,

    pub fn init(input: []const u8) RulesIterator {
        return .{
            .input = input,
            .stream = TokenStream.init(input),
        };
    }

    pub fn next(self: *RulesIterator) ?Rule {
        var selector_start: ?usize = null;
        var selector_end: ?usize = null;

        while (true) {
            const peeked = self.stream.peek() orelse return null;

            if (peeked.token == .curly_bracket_block) {
                if (selector_start == null) {
                    self.skipBlock();
                    continue;
                }

                const open_brace = self.stream.next() orelse return null;

                var selector = self.input[selector_start.?..selector_end.?];
                selector = std.mem.trim(u8, selector, &std.ascii.whitespace);

                return .{ .style = .{
                    .selector = selector,
                    .block = consumeBlockBody(&self.stream, self.input, open_brace.end),
                } };
            }

            if (peeked.token == .at_keyword) {
                return .{ .at_rule = consumeAtRule(&self.stream, self.input) };
            }

            if (selector_start == null and (isWhitespaceOrComment(peeked.token) or isSemicolon(peeked.token))) {
                _ = self.stream.next();
                continue;
            }

            const span = self.stream.next() orelse return null;
            if (!isWhitespaceOrComment(span.token)) {
                if (selector_start == null) selector_start = span.start;
                selector_end = span.end;
            }
        }
    }

    fn skipBlock(self: *RulesIterator) void {
        const span = self.stream.next() orelse return;
        if (span.token != .curly_bracket_block) return;

        var depth: usize = 1;
        while (true) {
            const next_span = self.stream.next() orelse return;
            if (next_span.token == .curly_bracket_block) {
                depth += 1;
            } else if (next_span.token == .close_curly_bracket) {
                depth -= 1;
                if (depth == 0) return;
            }
        }
    }
};

/// Consume a full at-rule (statement or block form) and return its keyword
/// (without `@`) and full source span. The caller peeked the `at_keyword`.
fn consumeAtRule(stream: *TokenStream, input: []const u8) AtRule {
    const at_span = stream.next() orelse unreachable; // caller peeked an at_keyword
    const start = at_span.start;
    const keyword = switch (at_span.token) {
        .at_keyword => |name| name,
        else => "",
    };
    var end = at_span.end;
    var depth: usize = 0;
    var saw_block = false;

    while (true) {
        const peeked = stream.peek() orelse break;
        if (!saw_block and isSemicolon(peeked.token) and depth == 0) {
            const semi = stream.next() orelse break;
            end = semi.end;
            break;
        }

        const span = stream.next() orelse break;
        if (isWhitespaceOrComment(span.token)) {
            end = span.end;
            continue;
        }

        end = span.end;
        if (span.token == .curly_bracket_block) {
            depth += 1;
            saw_block = true;
        } else if (span.token == .close_curly_bracket) {
            if (depth > 0) depth -= 1;
            if (saw_block and depth == 0) break;
        }
    }

    return .{
        .keyword = keyword,
        .text = input[start..end],
    };
}

/// Consume the rest of a `{}` block whose `{` was just consumed (it ended at
/// `block_start`), through its matching `}`, and return the body between the
/// braces. An unclosed block runs to the end of the input.
fn consumeBlockBody(stream: *TokenStream, input: []const u8, block_start: usize) []const u8 {
    var depth: usize = 1;
    while (stream.next()) |span| {
        if (span.token == .curly_bracket_block) {
            depth += 1;
        } else if (span.token == .close_curly_bracket) {
            depth -= 1;
            if (depth == 0) {
                return input[block_start..span.start];
            }
        }
    }
    return input[block_start..];
}

/// Consume an invalid declaration through the next top-level `;`. A `{}`
/// block in it is skipped whole, `;`s included.
fn skipInvalidDeclaration(stream: *TokenStream) void {
    var depth: usize = 0;
    while (stream.next()) |span| {
        if (depth == 0 and isSemicolon(span.token)) {
            return;
        }
        updateDepth(span.token, &depth);
    }
}

/// Consume a style rule nested in a block: a selector then a `{}` block.
/// Returns null, having consumed it, for anything that reaches a top-level
/// `;` before a block, or a block with no selector.
fn consumeNestedRule(stream: *TokenStream, input: []const u8) ?StyleRule {
    var start: ?usize = null;
    var end: usize = 0;
    var depth: usize = 0;

    while (stream.next()) |span| {
        if (depth == 0) {
            if (span.token == .curly_bracket_block) {
                const body = consumeBlockBody(stream, input, span.end);
                const selector_start = start orelse return null;
                return .{ .selector = input[selector_start..end], .block = body };
            }
            if (isSemicolon(span.token)) {
                return null;
            }
        }
        if (isWhitespaceOrComment(span.token)) {
            continue;
        }
        if (start == null) start = span.start;
        end = span.end;
        updateDepth(span.token, &depth);
    }
    return null;
}

/// Upper bound on a resolved nested selector, in bytes. Each `&` copies the
/// whole parent, so `& &` nested N deep doubles the text N times: a hostile
/// stylesheet would reach gigabytes well within MAX_AT_RULE_NESTING. A rule
/// whose selector would outgrow this is dropped instead.
pub const MAX_NESTED_SELECTOR_LEN: usize = 64 * 1024;

/// Resolve the selector list of a style rule nested in `parent` (CSS Nesting
/// §3): each `&` becomes `:is(<parent>)`, and a relative selector (one that
/// starts with a combinator, or has no `&`) is prefixed with `:is(<parent>) `.
/// Using `:is()` keeps the spec's specificity (the most specific parent
/// selector) and lets a parent selector list stand in for a single `&`.
/// Selectors are split on the commas outside parentheses and brackets; tokens
/// are copied verbatim. Returns null when the result would exceed
/// MAX_NESTED_SELECTOR_LEN.
pub fn resolveNestedSelector(allocator: std.mem.Allocator, parent: []const u8, nested: []const u8) !?[]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var stream = TokenStream.init(nested);

    // Start of the current complex selector in `out`, whether it holds an `&`
    // yet, and whether it starts with a combinator. Each selector is written
    // as it streams by, and the parent is inserted at `selector_start` when it
    // turns out to be relative.
    var selector_start: usize = 0;
    var has_nesting = false;
    var starts_with_combinator = false;
    var pending_space = false;
    // A comment with no whitespace on either side separates tokens without
    // being a descendant combinator: it is kept rather than turned into one.
    var pending_comment: ?[]const u8 = null;
    var depth: usize = 0;

    while (true) {
        if (out.items.len > MAX_NESTED_SELECTOR_LEN) {
            out.deinit(allocator);
            return null;
        }
        const span = stream.next();
        const at_comma = if (span) |sp| depth == 0 and sp.token == .comma else true;
        if (at_comma) {
            if (out.items.len > selector_start and (starts_with_combinator or !has_nesting)) {
                // Inserted back to front, to read `:is(<parent>) <selector>`.
                try out.insertSlice(allocator, selector_start, ") ");
                try out.insertSlice(allocator, selector_start, parent);
                try out.insertSlice(allocator, selector_start, ":is(");
            }
            if (span == null) {
                break;
            }
            if (out.items.len > selector_start) {
                try out.appendSlice(allocator, ", ");
            }
            selector_start = out.items.len;
            has_nesting = false;
            starts_with_combinator = false;
            pending_space = false;
            pending_comment = null;
            continue;
        }

        const sp = span.?;
        switch (sp.token) {
            .white_space => {
                pending_space = out.items.len > selector_start;
                pending_comment = null;
                continue;
            },
            .comment => {
                if (!pending_space and out.items.len > selector_start) {
                    pending_comment = nested[sp.start..sp.end];
                }
                continue;
            },
            else => {},
        }
        if (pending_space) {
            try out.append(allocator, ' ');
        } else if (pending_comment) |comment| {
            try out.appendSlice(allocator, comment);
        }
        pending_space = false;
        pending_comment = null;
        if (out.items.len == selector_start) {
            starts_with_combinator = switch (sp.token) {
                .delim => |c| c == '>' or c == '+' or c == '~',
                else => false,
            };
        }
        updateDepth(sp.token, &depth);
        switch (sp.token) {
            .delim => |c| if (c == '&') {
                try out.appendSlice(allocator, ":is(");
                try out.appendSlice(allocator, parent);
                try out.append(allocator, ')');
                has_nesting = true;
                continue;
            },
            else => {},
        }
        try out.appendSlice(allocator, nested[sp.start..sp.end]);
    }

    if (out.items.len > MAX_NESTED_SELECTOR_LEN) {
        out.deinit(allocator);
        return null;
    }
    return try out.toOwnedSlice(allocator);
}

const testing = std.testing;

test "RulesIterator: single rule" {
    var it = RulesIterator.init(".test { color: red; }");
    const rule = it.next() orelse return error.MissingRule;
    try testing.expectEqualStrings(".test", rule.style.selector);
    try testing.expectEqualStrings(" color: red; ", rule.style.block);
    try testing.expectEqual(@as(?Rule, null), it.next());
}

test "RulesIterator: multiple rules" {
    var it = RulesIterator.init("h1 { margin: 0; } p { padding: 10px; }");

    var rule = it.next() orelse return error.MissingRule;
    try testing.expectEqualStrings("h1", rule.style.selector);
    try testing.expectEqualStrings(" margin: 0; ", rule.style.block);

    rule = it.next() orelse return error.MissingRule;
    try testing.expectEqualStrings("p", rule.style.selector);
    try testing.expectEqualStrings(" padding: 10px; ", rule.style.block);

    try testing.expectEqual(@as(?Rule, null), it.next());
}

test "RulesIterator: surfaces statement at-rules" {
    var it = RulesIterator.init("@import url('style.css'); .test { color: red; }");

    const at = it.next() orelse return error.MissingRule;
    try testing.expectEqualStrings("import", at.at_rule.keyword);
    try testing.expectEqualStrings("@import url('style.css');", at.at_rule.text);

    const rule = it.next() orelse return error.MissingRule;
    try testing.expectEqualStrings(".test", rule.style.selector);
    try testing.expectEqualStrings(" color: red; ", rule.style.block);
    try testing.expectEqual(@as(?Rule, null), it.next());
}

test "RulesIterator: surfaces block at-rules" {
    var it = RulesIterator.init("@media screen { .test { color: blue; } } .test2 { color: green; }");

    const at = it.next() orelse return error.MissingRule;
    try testing.expectEqualStrings("media", at.at_rule.keyword);
    try testing.expectEqualStrings("@media screen { .test { color: blue; } }", at.at_rule.text);

    const rule = it.next() orelse return error.MissingRule;
    try testing.expectEqualStrings(".test2", rule.style.selector);
    try testing.expectEqualStrings(" color: green; ", rule.style.block);
    try testing.expectEqual(@as(?Rule, null), it.next());
}

test "RulesIterator: surfaces vendor-prefixed at-rules" {
    var it = RulesIterator.init("@-webkit-keyframes spin { from { transform: rotate(0deg); } to { transform: rotate(360deg); } }");

    const at = it.next() orelse return error.MissingRule;
    try testing.expectEqualStrings("-webkit-keyframes", at.at_rule.keyword);
    try testing.expectEqual(@as(?Rule, null), it.next());
}

test "RulesIterator: comments and whitespace" {
    var it = RulesIterator.init("  /* comment */  .test  /* comment */ { /* comment */ color: red; } \n\t");

    const rule = it.next() orelse return error.MissingRule;
    try testing.expectEqualStrings(".test", rule.style.selector);
    try testing.expectEqualStrings(" /* comment */ color: red; ", rule.style.block);
    try testing.expectEqual(@as(?Rule, null), it.next());
}

test "RulesIterator: top-level semicolons" {
    var it = RulesIterator.init("*{}; ; p{}");
    var rule = it.next() orelse return error.MissingRule;
    try testing.expectEqualStrings("*", rule.style.selector);

    rule = it.next() orelse return error.MissingRule;
    try testing.expectEqualStrings("p", rule.style.selector);
    try testing.expectEqual(@as(?Rule, null), it.next());
}

test "DeclarationsIterator: nested rules end at their own block" {
    var it = parseStyleBlock(
        \\ color: red;
        \\ &.active { color: blue; }
        \\ .child { display: none }
        \\ div:hover { color: green; }
        \\ margin: 0;
        \\ @media (min-width: 1px) { padding: 0 }
        \\ --custom: { a: b };
    );

    var item = it.nextItem() orelse return error.MissingItem;
    try testing.expectEqualStrings("color", item.declaration.name);

    item = it.nextItem() orelse return error.MissingItem;
    try testing.expectEqualStrings("&.active", item.rule.selector);
    try testing.expectEqualStrings(" color: blue; ", item.rule.block);

    item = it.nextItem() orelse return error.MissingItem;
    try testing.expectEqualStrings(".child", item.rule.selector);

    item = it.nextItem() orelse return error.MissingItem;
    try testing.expectEqualStrings("div:hover", item.rule.selector);
    try testing.expectEqualStrings(" color: green; ", item.rule.block);

    item = it.nextItem() orelse return error.MissingItem;
    try testing.expectEqualStrings("margin", item.declaration.name);
    try testing.expectEqualStrings("0", item.declaration.value);

    item = it.nextItem() orelse return error.MissingItem;
    try testing.expectEqualStrings("media", item.at_rule.keyword);
    try testing.expectEqualStrings("@media (min-width: 1px) { padding: 0 }", item.at_rule.text);

    item = it.nextItem() orelse return error.MissingItem;
    try testing.expectEqualStrings("--custom", item.declaration.name);
    try testing.expectEqualStrings("{ a: b }", item.declaration.value);

    try testing.expectEqual(null, it.nextItem());
}

test "DeclarationsIterator: next skips nested rules" {
    var it = parseStyleBlock("&.a { color: blue; } color: red; .b { x: y } invalid; margin: 0");
    var declaration = it.next() orelse return error.MissingDeclaration;
    try testing.expectEqualStrings("color", declaration.name);
    try testing.expectEqualStrings("red", declaration.value);
    declaration = it.next() orelse return error.MissingDeclaration;
    try testing.expectEqualStrings("margin", declaration.name);
    try testing.expectEqual(null, it.next());
}

test "DeclarationsIterator: a declarations list has no nested rules" {
    // `style=` and cssText: a nested rule is an invalid declaration, skipped
    // through the next top-level `;`, so `display: none` goes with it.
    var it = parseDeclarationsList("color: red; &.x { color: blue; } display: none; div:hover { color: green } opacity: 0; --custom: { a: b }; margin: 0");

    var item = it.nextItem() orelse return error.MissingItem;
    try testing.expectEqualStrings("color", item.declaration.name);

    item = it.nextItem() orelse return error.MissingItem;
    try testing.expectEqualStrings("--custom", item.declaration.name);
    try testing.expectEqualStrings("{ a: b }", item.declaration.value);

    item = it.nextItem() orelse return error.MissingItem;
    try testing.expectEqualStrings("margin", item.declaration.name);

    try testing.expectEqual(null, it.nextItem());
}

test "resolveNestedSelector" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const cases = [_]struct { parent: []const u8, nested: []const u8, want: []const u8 }{
        .{ .parent = ".a", .nested = "&.b", .want = ":is(.a).b" },
        .{ .parent = ".a", .nested = ".b", .want = ":is(.a) .b" },
        .{ .parent = ".a", .nested = "> li", .want = ":is(.a) > li" },
        .{ .parent = ".a", .nested = "& + &", .want = ":is(.a) + :is(.a)" },
        .{ .parent = ".a", .nested = ".x &", .want = ".x :is(.a)" },
        .{ .parent = ".a", .nested = ":not(&) .b", .want = ":not(:is(.a)) .b" },
        .{ .parent = ".a, .b", .nested = "&:hover", .want = ":is(.a, .b):hover" },
        .{ .parent = ".a", .nested = "&.b, .c ,  :is(.d, .e)", .want = ":is(.a).b, :is(.a) .c, :is(.a) :is(.d, .e)" },
        .{ .parent = ".a", .nested = "[data-x='&']", .want = ":is(.a) [data-x='&']" },
        .{ .parent = ".a", .nested = "  /* c */ &  .b  ", .want = ":is(.a) .b" },
        // A selector starting with a combinator is relative even with an `&`.
        .{ .parent = ".a", .nested = "> .x &", .want = ":is(.a) > .x :is(.a)" },
        // A comment between two tokens is not a descendant combinator.
        .{ .parent = ".a", .nested = "&/* c */.b", .want = ":is(.a)/* c */.b" },
        .{ .parent = ".a", .nested = "& /* c */.b", .want = ":is(.a) .b" },
    };
    for (cases) |c| {
        const got = try resolveNestedSelector(allocator, c.parent, c.nested) orelse return error.TooLong;
        try testing.expectEqualStrings(c.want, got);
    }
}

test "resolveNestedSelector: `& &` stops doubling at the cap" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Each level doubles the selector: without the cap, 32 levels would be
    // tens of gigabytes.
    var selector: []const u8 = ".a";
    var levels: usize = 0;
    while (try resolveNestedSelector(allocator, selector, "& &")) |resolved| {
        try testing.expect(resolved.len <= MAX_NESTED_SELECTOR_LEN);
        selector = resolved;
        levels += 1;
        try testing.expect(levels < 32);
    }
    try testing.expect(levels > 0);
}
