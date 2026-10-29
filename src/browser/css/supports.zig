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

//! `<supports-condition>` evaluation, for CSS.supports(). A declaration is
//! supported when we know its property; its value isn't validated, we don't
//! have a grammar for most properties.

const std = @import("std");

const SelectorParser = @import("../webapi/selector/Parser.zig");

const Tokenizer = @import("Tokenizer.zig");
const CssParser = @import("Parser.zig");
const properties = @import("properties.zig");

const Allocator = std.mem.Allocator;

/// CSS.supports(property, value)
pub fn declaration(name: []const u8, value: []const u8) bool {
    if (std.mem.trim(u8, value, &std.ascii.whitespace).len == 0) {
        return false;
    }
    if (std.mem.startsWith(u8, name, "--")) {
        return true;
    }
    var buf: [64]u8 = undefined;
    if (name.len > buf.len) {
        return false;
    }
    return properties.isKnown(std.ascii.lowerString(&buf, name));
}

/// CSS.supports(conditionText).
pub fn condition(arena: Allocator, text: []const u8) bool {
    if (evaluate(arena, text)) |result| {
        return result;
    }
    // retry wrapped in parentheses so that a bare declaration, e.g.
    // `display: grid`, works.
    const wrapped = std.mem.concat(arena, u8, &.{ "(", text, ")" }) catch return false;
    return evaluate(arena, wrapped) orelse false;
}

/// The condition's value, or null when `text` isn't a condition.
fn evaluate(arena: Allocator, text: []const u8) ?bool {
    var evaluator: Evaluator = .{ .arena = arena, .tokenizer = .{ .input = text } };
    const result = evaluator.condition() orelse return null;
    if (evaluator.nextToken() != null) {
        return null;
    }
    return result;
}

const Evaluator = struct {
    arena: Allocator,
    tokenizer: Tokenizer,

    // <supports-condition> = not <supports-in-parens>
    //   | <supports-in-parens> [ and <supports-in-parens> ]*
    //   | <supports-in-parens> [ or <supports-in-parens> ]*
    fn condition(self: *Evaluator) ?bool {
        const start = self.tokenizer.position;
        if (self.nextToken()) |token| {
            if (isIdent(token, "not")) {
                return !(self.inParens() orelse return null);
            }
        }
        self.tokenizer.position = start;

        var result = self.inParens() orelse return null;
        var operator: ?enum { @"and", @"or" } = null;
        while (true) {
            const before = self.tokenizer.position;
            const token = self.nextToken() orelse return result;
            const this: @TypeOf(operator) = if (isIdent(token, "and")) .@"and" else if (isIdent(token, "or")) .@"or" else {
                self.tokenizer.position = before;
                return result;
            };
            // Mixing `and` and `or` needs parentheses.
            if (operator != null and operator != this) {
                return null;
            }
            operator = this;
            const next = self.inParens() orelse return null;
            result = if (this == .@"and") result and next else result or next;
        }
    }

    // <supports-in-parens> = ( <supports-condition> ) | <supports-feature> | <general-enclosed>
    fn inParens(self: *Evaluator) ?bool {
        const token = self.nextToken() orelse return null;
        switch (token) {
            .parenthesis_block => {
                const inner = self.block() orelse return null;
                if (evaluate(self.arena, inner)) |result| {
                    return result;
                }
                return supportsDeclaration(inner);
            },
            .function => |name| {
                const args = std.mem.trim(u8, self.block() orelse return null, &std.ascii.whitespace);
                if (std.ascii.eqlIgnoreCase(name, "selector")) {
                    return self.supportsSelector(args);
                }
                if (std.ascii.eqlIgnoreCase(name, "font-format")) {
                    return font_formats.has(singleIdent(args) orelse return false);
                }
                if (std.ascii.eqlIgnoreCase(name, "font-tech")) {
                    return font_techs.has(singleIdent(args) orelse return false);
                }
                if (std.ascii.eqlIgnoreCase(name, "at-rule")) {
                    return at_rules.has(singleAtKeyword(args) orelse return false);
                }
                // <general-enclosed>: valid, but never supported.
                return false;
            },
            else => return null,
        }
    }

    /// The text up to the `)` closing the block just opened, which is
    /// consumed. Null when it is never closed.
    fn block(self: *Evaluator) ?[]const u8 {
        const start = self.tokenizer.position;
        var depth: usize = 1;
        while (self.tokenizer.next()) |token| {
            switch (token) {
                .parenthesis_block, .function => depth += 1,
                .close_parenthesis => {
                    depth -= 1;
                    if (depth == 0) {
                        return self.tokenizer.input[start .. self.tokenizer.position - 1];
                    }
                },
                else => {},
            }
        }
        return null;
    }

    fn supportsSelector(self: *Evaluator, text: []const u8) bool {
        const selectors = SelectorParser.parseList(self.arena, text) catch return false;
        // A single complex selector, not a list.
        return selectors.len == 1;
    }

    /// The next token that isn't whitespace or a comment.
    fn nextToken(self: *Evaluator) ?Tokenizer.Token {
        while (self.tokenizer.next()) |token| {
            switch (token) {
                .white_space, .comment => {},
                else => return token,
            }
        }
        return null;
    }
};

// <supports-decl> = ( <declaration> )
fn supportsDeclaration(text: []const u8) bool {
    var it = CssParser.parseDeclarationsList(text);
    const decl = it.next() orelse return false;
    if (it.next() != null) {
        return false;
    }
    return declaration(decl.name, decl.value);
}

fn isIdent(token: Tokenizer.Token, comptime word: []const u8) bool {
    return switch (token) {
        .ident => |name| std.ascii.eqlIgnoreCase(name, word),
        else => false,
    };
}

/// `text` when it is a single identifier; font-format() and font-tech() take
/// neither quoted strings nor lists.
fn singleIdent(text: []const u8) ?[]const u8 {
    var tokenizer: Tokenizer = .{ .input = text };
    const name = switch (tokenizer.next() orelse return null) {
        .ident => |name| name,
        else => return null,
    };
    if (tokenizer.next() != null) {
        return null;
    }
    return name;
}

/// The name in `text` when it is a single at-keyword (`@media`).
fn singleAtKeyword(text: []const u8) ?[]const u8 {
    var tokenizer: Tokenizer = .{ .input = text };
    const name = switch (tokenizer.next() orelse return null) {
        .at_keyword => |name| name,
        else => return null,
    };
    if (tokenizer.next() != null) {
        return null;
    }
    return name;
}

const KeywordSet = std.StaticStringMapWithEql(void, std.static_string_map.eqlAsciiIgnoreCase);

// The keyword lists match what Chrome 151 reports as supported.
const font_formats = KeywordSet.initComptime(.{
    .{ "collection", {} },
    .{ "opentype", {} },
    .{ "truetype", {} },
    .{ "woff", {} },
    .{ "woff2", {} },
});

const font_techs = KeywordSet.initComptime(.{
    .{ "features-opentype", {} },
    .{ "features-aat", {} },
    .{ "color-colrv0", {} },
    .{ "color-colrv1", {} },
    .{ "color-sbix", {} },
    .{ "color-cbdt", {} },
    .{ "variations", {} },
    .{ "palettes", {} },
});

// @charset isn't an at-rule, only a marker at the start of a stylesheet.
const at_rules = KeywordSet.initComptime(.{
    .{ "import", {} },
    .{ "namespace", {} },
    .{ "media", {} },
    .{ "supports", {} },
    .{ "font-face", {} },
    .{ "font-feature-values", {} },
    .{ "font-palette-values", {} },
    .{ "keyframes", {} },
    .{ "-webkit-keyframes", {} },
    .{ "page", {} },
    .{ "counter-style", {} },
    .{ "layer", {} },
    .{ "property", {} },
    .{ "container", {} },
    .{ "scope", {} },
    .{ "starting-style", {} },
    .{ "view-transition", {} },
    .{ "position-try", {} },
    .{ "function", {} },
    // @font-feature-values blocks
    .{ "swash", {} },
    .{ "annotation", {} },
    .{ "ornaments", {} },
    .{ "stylistic", {} },
    .{ "styleset", {} },
    .{ "character-variant", {} },
    // @page margin boxes
    .{ "top-left-corner", {} },
    .{ "top-left", {} },
    .{ "top-center", {} },
    .{ "top-right", {} },
    .{ "top-right-corner", {} },
    .{ "bottom-left-corner", {} },
    .{ "bottom-left", {} },
    .{ "bottom-center", {} },
    .{ "bottom-right", {} },
    .{ "bottom-right-corner", {} },
    .{ "left-top", {} },
    .{ "left-middle", {} },
    .{ "left-bottom", {} },
    .{ "right-top", {} },
    .{ "right-middle", {} },
    .{ "right-bottom", {} },
});

const testing = @import("../../testing.zig");

test "supports: condition" {
    defer testing.reset();
    const arena = testing.arena_allocator;
    const cases = [_]struct { []const u8, bool }{
        .{ "(color: red)", true },
        .{ "color: red", true },
        .{ "display: block", true },
        .{ "  display:block  ", true },
        .{ "(COLOR: red)", true },
        .{ "(--foo: blah)", true },
        .{ "--foo: blah", true },
        .{ "(color: red) and (color: blue)", true },
        .{ "(color: red) and (bogus: blue)", false },
        .{ "(color: red) or (bogus: blue)", true },
        .{ "(color: red) and (color: blue) or (color: red)", false },
        .{ "((color: red) and (color: blue)) or (bogus: red)", true },
        .{ "not (foobar)", true },
        .{ "not (color: red)", false },
        .{ "not(color: red)", false },
        .{ "(foobar)", false },
        .{ "unknownproperty: blah", false },
        .{ "unicode-range: U+0-7F", false },
        .{ "(color: red; display: block)", false },
        .{ "(color:)", false },
        .{ "func(x)", false },
        .{ "(color: red", false },
        .{ "", false },
        .{ "color", false },
        .{ "selector(div)", true },
        .{ "selector(div + .c)", true },
        .{ "selector(div, div)", false },
        .{ "selector(div | .c)", false },
        .{ "font-format(opentype)", true },
        .{ "font-format(OpenType)", true },
        .{ "font-format(xyzzy)", false },
        .{ "font-format(opentype, truetype)", false },
        .{ "font-format('opentype')", false },
        .{ "font-tech(features-opentype)", true },
        .{ "font-tech(color-COLRv0)", true },
        .{ "font-tech(feature-opentype)", false },
        .{ "(color: red) and selector(div)", true },
        .{ "font-tech(incremental)", false },
        .{ "font-format(svg)", false },
        .{ "at-rule(@supports)", true },
        .{ "at-rule( @MEDIA )", true },
        .{ "at-rule(@doesnotexist)", false },
        .{ "at-rule(@charset)", false },
        .{ "at-rule(supports)", false },
        .{ "at-rule(@counter-style; system: fixed)", false },
        .{ "not at-rule(@doesnotexist)", true },
        .{ "(doesnotexist: red) or at-rule(@doesnotexist)", false },
    };
    for (cases) |case| {
        testing.expectEqual(case[1], condition(arena, case[0])) catch |err| {
            std.debug.print("condition: {s}\n", .{case[0]});
            return err;
        };
    }
}
