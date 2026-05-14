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

pub fn parseDeclarationsList(input: []const u8) DeclarationsIterator {
    return DeclarationsIterator.init(input);
}

pub const DeclarationsIterator = struct {
    input: []const u8,
    stream: TokenStream,

    pub fn init(input: []const u8) DeclarationsIterator {
        return .{
            .input = input,
            .stream = TokenStream.init(input),
        };
    }

    pub fn next(self: *DeclarationsIterator) ?Declaration {
        while (true) {
            self.skipTriviaAndSemicolons();
            const peeked = self.stream.peek() orelse return null;

            switch (peeked.token) {
                .at_keyword => {
                    _ = self.stream.next();
                    self.skipAtRule();
                },
                .ident => |name| {
                    _ = self.stream.next();
                    if (self.consumeDeclaration(name)) |declaration| {
                        return declaration;
                    }
                },
                else => {
                    _ = self.stream.next();
                    self.skipInvalidDeclaration();
                },
            }
        }

        return null;
    }

    fn consumeDeclaration(self: *DeclarationsIterator, name: []const u8) ?Declaration {
        self.skipTrivia();

        const colon = self.stream.next() orelse return null;
        if (!isColon(colon.token)) {
            self.skipInvalidDeclaration();
            return null;
        }

        const value = self.consumeValue() orelse return null;
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

    fn consumeValue(self: *DeclarationsIterator) ?ValueResult {
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

    fn skipAtRule(self: *DeclarationsIterator) void {
        var depth: usize = 0;
        var saw_block = false;

        while (true) {
            const peeked = self.stream.peek() orelse return;
            if (!saw_block and isSemicolon(peeked.token) and depth == 0) {
                _ = self.stream.next();
                return;
            }

            const span = self.stream.next() orelse return;
            if (isWhitespaceOrComment(span.token)) continue;

            if (isBlockStart(span.token)) {
                depth += 1;
                saw_block = true;
            } else if (isBlockEnd(span.token)) {
                if (depth > 0) depth -= 1;
                if (saw_block and depth == 0) return;
            }
        }
    }

    fn skipInvalidDeclaration(self: *DeclarationsIterator) void {
        var depth: usize = 0;

        while (self.stream.peek()) |peeked| {
            if (isSemicolon(peeked.token) and depth == 0) {
                _ = self.stream.next();
                return;
            }

            const span = self.stream.next() orelse return;
            if (isWhitespaceOrComment(span.token)) continue;
            updateDepth(span.token, &depth);
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

pub const StyleRule = struct {
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
pub const AtRule = struct {
    /// At-keyword without the leading `@` (e.g., `"keyframes"`, `"media"`,
    /// `"-webkit-keyframes"`). Borrowed from the input slice; copy if you
    /// need to outlive the input.
    keyword: []const u8,
    /// Full at-rule source span starting at `@` and ending after the closing
    /// brace (block at-rules) or semicolon (statement at-rules). Borrowed
    /// from the input slice.
    text: []const u8,
};

pub const Rule = union(enum) {
    style: StyleRule,
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
                const block_start = open_brace.end;
                var block_end = block_start;

                var depth: usize = 1;
                while (true) {
                    const span = self.stream.next() orelse {
                        block_end = self.input.len;
                        break;
                    };
                    if (span.token == .curly_bracket_block) {
                        depth += 1;
                    } else if (span.token == .close_curly_bracket) {
                        depth -= 1;
                        if (depth == 0) {
                            block_end = span.start;
                            break;
                        }
                    }
                }

                var selector = self.input[selector_start.?..selector_end.?];
                selector = std.mem.trim(u8, selector, &std.ascii.whitespace);

                return .{ .style = .{
                    .selector = selector,
                    .block = self.input[block_start..block_end],
                } };
            }

            if (peeked.token == .at_keyword) {
                return .{ .at_rule = self.consumeAtRule() };
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

    /// Consume a full at-rule (statement or block form) and return its
    /// keyword (without `@`) and full source span. Mirrors `skipAtRule`'s
    /// termination logic but records spans instead of discarding.
    fn consumeAtRule(self: *RulesIterator) AtRule {
        const at_span = self.stream.next() orelse unreachable; // caller peeked an at_keyword
        const start = at_span.start;
        const keyword = switch (at_span.token) {
            .at_keyword => |name| name,
            else => "",
        };
        var end = at_span.end;
        var depth: usize = 0;
        var saw_block = false;

        while (true) {
            const peeked = self.stream.peek() orelse break;
            if (!saw_block and isSemicolon(peeked.token) and depth == 0) {
                const semi = self.stream.next() orelse break;
                end = semi.end;
                break;
            }

            const span = self.stream.next() orelse break;
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
            .text = self.input[start..end],
        };
    }
};

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
