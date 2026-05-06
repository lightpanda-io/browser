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

//! XPath 1.0 expression parser.
//!
//! Mirrors the polyfill `Parser.prototype.*` chain in capybara-lightpanda
//! (lib/capybara/lightpanda/javascripts/index.js): recursive descent over
//! a fully-tokenized stream, producing an `Ast.Expr` tree allocated on
//! the caller's arena. The AST borrows string/name slices from `input`
//! and is valid for as long as the arena and input outlive it.

const std = @import("std");

const Tokenizer = @import("Tokenizer.zig");
const Ast = @import("ast.zig");

const Token = Tokenizer.Token;
const Allocator = std.mem.Allocator;

const Parser = @This();

pub const Error = error{
    OutOfMemory,
    UnexpectedToken,
    ExpectedNodeTest,
    ExpectedPrimaryExpr,
    MaxDepthExceeded,
};

/// Cap recursive descent to keep adversarial input (e.g. `(((((...)))))`,
/// `------5`) from blowing the stack. Real XPath expressions never come
/// close to this; browsers typically allow several hundred.
const max_depth: u16 = 64;

arena: Allocator,
tokens: []const Token,
pos: usize = 0,
depth: u16 = 0,

pub fn parse(arena: Allocator, input: []const u8) Error!*Ast.Expr {
    var token_list: std.ArrayList(Token) = .empty;
    // Token count is bounded by input length; ¼-byte-per-token is
    // generous for typical XPath and skips ArrayList regrowth.
    try token_list.ensureTotalCapacity(arena, @max(8, input.len / 4));
    var tokenizer = Tokenizer{ .input = input };
    while (true) {
        const tok = tokenizer.next();
        try token_list.append(arena, tok);
        if (tok == .eof) break;
    }

    var parser = Parser{
        .arena = arena,
        .tokens = token_list.items,
    };
    const expr = try parser.parseExpr();
    if (parser.peek() != .eof) return error.UnexpectedToken;
    return expr;
}

// --- token cursor helpers ---

fn peek(self: *const Parser) Token {
    return self.tokens[self.pos];
}

fn lookahead(self: *const Parser, offset: usize) Token {
    const idx = self.pos + offset;
    if (idx >= self.tokens.len) return .eof;
    return self.tokens[idx];
}

fn advance(self: *Parser) Token {
    const tok = self.tokens[self.pos];
    self.pos += 1;
    return tok;
}

fn at(self: *const Parser, tag: std.meta.Tag(Token)) bool {
    return self.peek() == tag;
}

fn match(self: *Parser, tag: std.meta.Tag(Token)) bool {
    if (self.at(tag)) {
        _ = self.advance();
        return true;
    }
    return false;
}

fn expect(self: *Parser, tag: std.meta.Tag(Token)) Error!Token {
    if (!self.at(tag)) return error.UnexpectedToken;
    return self.advance();
}

fn matchKeyword(self: *Parser, keyword: []const u8) bool {
    const tok = self.peek();
    if (tok == .name and std.mem.eql(u8, tok.name, keyword)) {
        _ = self.advance();
        return true;
    }
    return false;
}

fn makeExpr(self: *Parser, value: Ast.Expr) Error!*Ast.Expr {
    const expr = try self.arena.create(Ast.Expr);
    expr.* = value;
    return expr;
}

fn makeBinop(self: *Parser, op: Ast.BinOpKind, left: *Ast.Expr, right: *Ast.Expr) Error!*Ast.Expr {
    return try self.makeExpr(.{ .binop = .{ .op = op, .left = left, .right = right } });
}

// --- operator-precedence chain ---
//
// Or → And → Equality → Relational → Additive → Mult → Unary → Union → Path

fn parseExpr(self: *Parser) Error!*Ast.Expr {
    if (self.depth >= max_depth) return error.MaxDepthExceeded;
    self.depth += 1;
    defer self.depth -= 1;
    return self.parseOrExpr();
}

fn parseOrExpr(self: *Parser) Error!*Ast.Expr {
    var left = try self.parseAndExpr();
    while (self.matchKeyword("or")) {
        const right = try self.parseAndExpr();
        left = try self.makeBinop(.or_, left, right);
    }
    return left;
}

fn parseAndExpr(self: *Parser) Error!*Ast.Expr {
    var left = try self.parseEqualityExpr();
    while (self.matchKeyword("and")) {
        const right = try self.parseEqualityExpr();
        left = try self.makeBinop(.and_, left, right);
    }
    return left;
}

fn parseEqualityExpr(self: *Parser) Error!*Ast.Expr {
    var left = try self.parseRelationalExpr();
    while (equalityOp(self.peek())) |op| {
        _ = self.advance();
        const right = try self.parseRelationalExpr();
        left = try self.makeBinop(op, left, right);
    }
    return left;
}

fn parseRelationalExpr(self: *Parser) Error!*Ast.Expr {
    var left = try self.parseAdditiveExpr();
    while (relationalOp(self.peek())) |op| {
        _ = self.advance();
        const right = try self.parseAdditiveExpr();
        left = try self.makeBinop(op, left, right);
    }
    return left;
}

fn parseAdditiveExpr(self: *Parser) Error!*Ast.Expr {
    var left = try self.parseMultExpr();
    while (additiveOp(self.peek())) |op| {
        _ = self.advance();
        const right = try self.parseMultExpr();
        left = try self.makeBinop(op, left, right);
    }
    return left;
}

// After a complete unary expression, `*` is multiply; `div`/`mod` are
// operator-position keywords (tokenized as Name).
fn parseMultExpr(self: *Parser) Error!*Ast.Expr {
    var left = try self.parseUnaryExpr();
    while (multOp(self.peek())) |op| {
        _ = self.advance();
        const right = try self.parseUnaryExpr();
        left = try self.makeBinop(op, left, right);
    }
    return left;
}

fn parseUnaryExpr(self: *Parser) Error!*Ast.Expr {
    if (self.match(.minus)) {
        if (self.depth >= max_depth) return error.MaxDepthExceeded;
        self.depth += 1;
        defer self.depth -= 1;
        const operand = try self.parseUnaryExpr();
        return try self.makeExpr(.{ .neg = operand });
    }
    return self.parseUnionExpr();
}

fn parseUnionExpr(self: *Parser) Error!*Ast.Expr {
    var left = try self.parsePathExpr();
    while (self.match(.pipe)) {
        const right = try self.parsePathExpr();
        left = try self.makeBinop(.union_, left, right);
    }
    return left;
}

// --- path expressions ---

fn parsePathExpr(self: *Parser) Error!*Ast.Expr {
    const t = self.peek();

    if (t == .slash or t == .double_slash) {
        return self.parseAbsPath();
    }

    // Filter-vs-relative-path disambiguation: a primary expression
    // starts with `(`, string, number, `$`, or a `name(` where the
    // name is *not* a node-type test (`node`/`text`/`comment`/`processing-instruction`).
    const is_filter = switch (t) {
        .lparen, .string, .number, .dollar => true,
        .name => |name| self.lookahead(1) == .lparen and !isNodeTypeName(name),
        else => false,
    };

    if (is_filter) {
        var primary = try self.parsePrimaryExpr();
        while (self.match(.lbracket)) {
            const pred = try self.parseExpr();
            _ = try self.expect(.rbracket);
            primary = try self.makeExpr(.{ .filter = .{ .expr = primary, .predicate = pred } });
        }
        if (self.peek() == .slash or self.peek() == .double_slash) {
            const dsl = self.advance() == .double_slash;
            var steps: std.ArrayList(Ast.Step) = .empty;
            if (dsl) try steps.append(self.arena, descendantOrSelfStep());
            try self.parseRelStepsInto(&steps);
            return try self.makeExpr(.{ .filter_path = .{
                .filter = primary,
                .steps = steps.items,
            } });
        }
        return primary;
    }

    return self.parseRelPath();
}

fn parseAbsPath(self: *Parser) Error!*Ast.Expr {
    var steps: std.ArrayList(Ast.Step) = .empty;
    if (self.match(.double_slash)) {
        try steps.append(self.arena, descendantOrSelfStep());
        try self.parseRelStepsInto(&steps);
    } else {
        _ = try self.expect(.slash);
        // `/` alone is the document root — no step required.
        if (self.canStartStep()) try self.parseRelStepsInto(&steps);
    }
    return try self.makeExpr(.{ .path = .{
        .absolute = true,
        .steps = steps.items,
    } });
}

fn parseRelPath(self: *Parser) Error!*Ast.Expr {
    var steps: std.ArrayList(Ast.Step) = .empty;
    try self.parseRelStepsInto(&steps);
    return try self.makeExpr(.{ .path = .{
        .absolute = false,
        .steps = steps.items,
    } });
}

fn parseRelStepsInto(self: *Parser, steps: *std.ArrayList(Ast.Step)) Error!void {
    try steps.append(self.arena, try self.parseStep());
    while (self.peek() == .slash or self.peek() == .double_slash) {
        if (self.advance() == .double_slash) {
            try steps.append(self.arena, descendantOrSelfStep());
        }
        try steps.append(self.arena, try self.parseStep());
    }
}

fn canStartStep(self: *const Parser) bool {
    return switch (self.peek()) {
        .name, .star, .dot, .double_dot, .at => true,
        else => false,
    };
}

fn parseStep(self: *Parser) Error!Ast.Step {
    // Abbreviated steps `.` and `..` carry no axis, node-test, or
    // predicates — predicates after `.` are a parse error per polyfill.
    if (self.match(.dot)) return abbreviatedStep(.self);
    if (self.match(.double_dot)) return abbreviatedStep(.parent);

    var axis: Ast.Axis = .child;
    if (self.match(.at)) {
        axis = .attribute;
    } else if (self.peek() == .name and self.lookahead(1) == .double_colon) {
        const axis_name = self.advance().name;
        _ = self.advance(); // `::`
        axis = parseAxisName(axis_name);
    }

    const node_test = try self.parseNodeTest();

    var preds: std.ArrayList(*Ast.Expr) = .empty;
    while (self.match(.lbracket)) {
        const pred = try self.parseExpr();
        _ = try self.expect(.rbracket);
        try preds.append(self.arena, pred);
    }

    return .{ .axis = axis, .node_test = node_test, .predicates = preds.items };
}

fn parseNodeTest(self: *Parser) Error!Ast.NodeTest {
    if (self.match(.star)) return .{ .name = "*" };
    if (self.peek() != .name) return error.ExpectedNodeTest;

    const name = self.peek().name;
    if (typeTestKind(name)) |type_test| {
        if (self.lookahead(1) == .lparen) {
            _ = self.advance(); // name
            _ = self.advance(); // `(`
            // `processing-instruction("target")` consumes the literal but ignores it (decision #3 stub).
            if (type_test == .processing_instruction and self.peek() == .string) {
                _ = self.advance();
            }
            _ = try self.expect(.rparen);
            return .{ .type_test = type_test };
        }
    }
    _ = self.advance();
    return .{ .name = name };
}

fn parsePrimaryExpr(self: *Parser) Error!*Ast.Expr {
    switch (self.peek()) {
        .string => |s| {
            _ = self.advance();
            return try self.makeExpr(.{ .literal = s });
        },
        .number => |n| {
            _ = self.advance();
            return try self.makeExpr(.{ .number = n });
        },
        .dollar => {
            _ = self.advance();
            const name_tok = try self.expect(.name);
            return try self.makeExpr(.{ .var_ref = name_tok.name });
        },
        .lparen => {
            _ = self.advance();
            const e = try self.parseExpr();
            _ = try self.expect(.rparen);
            return e;
        },
        .name => |name| {
            _ = self.advance();
            _ = try self.expect(.lparen);
            var args: std.ArrayList(*Ast.Expr) = .empty;
            if (self.peek() != .rparen) {
                try args.append(self.arena, try self.parseExpr());
                while (self.match(.comma)) {
                    try args.append(self.arena, try self.parseExpr());
                }
            }
            _ = try self.expect(.rparen);
            return try self.makeExpr(.{ .fn_call = .{ .name = name, .args = args.items } });
        },
        else => return error.ExpectedPrimaryExpr,
    }
}

// --- pure helpers ---

fn equalityOp(t: Token) ?Ast.BinOpKind {
    return switch (t) {
        .eq => .eq,
        .neq => .neq,
        else => null,
    };
}

fn relationalOp(t: Token) ?Ast.BinOpKind {
    return switch (t) {
        .lt => .lt,
        .gt => .gt,
        .lte => .lte,
        .gte => .gte,
        else => null,
    };
}

fn additiveOp(t: Token) ?Ast.BinOpKind {
    return switch (t) {
        .plus => .add,
        .minus => .sub,
        else => null,
    };
}

fn multOp(t: Token) ?Ast.BinOpKind {
    return switch (t) {
        .star => .mul,
        .name => |name| blk: {
            if (std.mem.eql(u8, name, "div")) break :blk .div;
            if (std.mem.eql(u8, name, "mod")) break :blk .mod;
            break :blk null;
        },
        else => null,
    };
}

fn descendantOrSelfStep() Ast.Step {
    return .{
        .axis = .descendant_or_self,
        .node_test = .{ .type_test = .node },
        .predicates = &.{},
    };
}

fn abbreviatedStep(axis: Ast.Axis) Ast.Step {
    return .{
        .axis = axis,
        .node_test = .{ .type_test = .node },
        .predicates = &.{},
    };
}

fn isNodeTypeName(name: []const u8) bool {
    return typeTestKind(name) != null;
}

const type_test_lookup = std.StaticStringMap(Ast.TypeTest).initComptime(.{
    .{ "node", .node },
    .{ "text", .text },
    .{ "comment", .comment },
    .{ "processing-instruction", .processing_instruction },
});

fn typeTestKind(name: []const u8) ?Ast.TypeTest {
    return type_test_lookup.get(name);
}

const axis_lookup = std.StaticStringMap(Ast.Axis).initComptime(.{
    .{ "child", .child },
    .{ "descendant", .descendant },
    .{ "descendant-or-self", .descendant_or_self },
    .{ "self", .self },
    .{ "parent", .parent },
    .{ "ancestor", .ancestor },
    .{ "ancestor-or-self", .ancestor_or_self },
    .{ "following-sibling", .following_sibling },
    .{ "preceding-sibling", .preceding_sibling },
    .{ "following", .following },
    .{ "preceding", .preceding },
    .{ "attribute", .attribute },
    .{ "namespace", .namespace },
});

fn parseAxisName(name: []const u8) Ast.Axis {
    return axis_lookup.get(name) orelse .unknown;
}

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

const testing = std.testing;

fn parseFixture(input: []const u8) !struct { arena: std.heap.ArenaAllocator, expr: *Ast.Expr } {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    errdefer arena.deinit();
    const expr = try parse(arena.allocator(), input);
    return .{ .arena = arena, .expr = expr };
}

test "XPath.Parser: number literal" {
    var fx = try parseFixture("42");
    defer fx.arena.deinit();
    try testing.expectEqual(@as(f64, 42), fx.expr.number);
}

test "XPath.Parser: string literal" {
    var fx = try parseFixture("'hello'");
    defer fx.arena.deinit();
    try testing.expectEqualStrings("hello", fx.expr.literal);
}

test "XPath.Parser: variable reference strips $" {
    var fx = try parseFixture("$x");
    defer fx.arena.deinit();
    try testing.expectEqualStrings("x", fx.expr.var_ref);
}

test "XPath.Parser: parenthesized expression unwraps" {
    var fx = try parseFixture("(42)");
    defer fx.arena.deinit();
    try testing.expectEqual(@as(f64, 42), fx.expr.number);
}

test "XPath.Parser: function call with no args" {
    var fx = try parseFixture("position()");
    defer fx.arena.deinit();
    try testing.expectEqualStrings("position", fx.expr.fn_call.name);
    try testing.expectEqual(@as(usize, 0), fx.expr.fn_call.args.len);
}

test "XPath.Parser: function call with args" {
    var fx = try parseFixture("substring('abc', 2, 1)");
    defer fx.arena.deinit();
    const fc = fx.expr.fn_call;
    try testing.expectEqualStrings("substring", fc.name);
    try testing.expectEqual(@as(usize, 3), fc.args.len);
    try testing.expectEqualStrings("abc", fc.args[0].literal);
    try testing.expectEqual(@as(f64, 2), fc.args[1].number);
    try testing.expectEqual(@as(f64, 1), fc.args[2].number);
}

test "XPath.Parser: arithmetic precedence — mul binds tighter than add" {
    var fx = try parseFixture("1 + 2 * 3");
    defer fx.arena.deinit();
    // Expected AST: add(1, mul(2, 3))
    const top = fx.expr.binop;
    try testing.expectEqual(Ast.BinOpKind.add, top.op);
    try testing.expectEqual(@as(f64, 1), top.left.number);
    const mul = top.right.binop;
    try testing.expectEqual(Ast.BinOpKind.mul, mul.op);
    try testing.expectEqual(@as(f64, 2), mul.left.number);
    try testing.expectEqual(@as(f64, 3), mul.right.number);
}

test "XPath.Parser: arithmetic left-associativity" {
    var fx = try parseFixture("1 - 2 - 3");
    defer fx.arena.deinit();
    // Expected AST: sub(sub(1, 2), 3)
    const top = fx.expr.binop;
    try testing.expectEqual(Ast.BinOpKind.sub, top.op);
    try testing.expectEqual(@as(f64, 3), top.right.number);
    const inner = top.left.binop;
    try testing.expectEqual(Ast.BinOpKind.sub, inner.op);
    try testing.expectEqual(@as(f64, 1), inner.left.number);
    try testing.expectEqual(@as(f64, 2), inner.right.number);
}

test "XPath.Parser: div and mod are operator-position keywords" {
    var fx = try parseFixture("7 div 2");
    defer fx.arena.deinit();
    try testing.expectEqual(Ast.BinOpKind.div, fx.expr.binop.op);

    var fx2 = try parseFixture("7 mod 2");
    defer fx2.arena.deinit();
    try testing.expectEqual(Ast.BinOpKind.mod, fx2.expr.binop.op);
}

test "XPath.Parser: comparison operators" {
    inline for (.{
        .{ "1 = 2", Ast.BinOpKind.eq },
        .{ "1 != 2", Ast.BinOpKind.neq },
        .{ "1 < 2", Ast.BinOpKind.lt },
        .{ "1 <= 2", Ast.BinOpKind.lte },
        .{ "1 > 2", Ast.BinOpKind.gt },
        .{ "1 >= 2", Ast.BinOpKind.gte },
    }) |case| {
        var fx = try parseFixture(case[0]);
        defer fx.arena.deinit();
        try testing.expectEqual(case[1], fx.expr.binop.op);
    }
}

test "XPath.Parser: logical or/and short-circuit chain" {
    var fx = try parseFixture("a or b and c");
    defer fx.arena.deinit();
    // Expected AST: or(path(a), and(path(b), path(c))) — and binds tighter
    const top = fx.expr.binop;
    try testing.expectEqual(Ast.BinOpKind.or_, top.op);
    try testing.expectEqual(Ast.BinOpKind.and_, top.right.binop.op);
}

test "XPath.Parser: unary minus" {
    var fx = try parseFixture("-1");
    defer fx.arena.deinit();
    try testing.expectEqual(@as(f64, 1), fx.expr.neg.number);
}

test "XPath.Parser: union" {
    var fx = try parseFixture("a | b");
    defer fx.arena.deinit();
    try testing.expectEqual(Ast.BinOpKind.union_, fx.expr.binop.op);
}

test "XPath.Parser: absolute path / alone is document root" {
    var fx = try parseFixture("/");
    defer fx.arena.deinit();
    const path = fx.expr.path;
    try testing.expect(path.absolute);
    try testing.expectEqual(@as(usize, 0), path.steps.len);
}

test "XPath.Parser: absolute path /foo" {
    var fx = try parseFixture("/foo");
    defer fx.arena.deinit();
    const path = fx.expr.path;
    try testing.expect(path.absolute);
    try testing.expectEqual(@as(usize, 1), path.steps.len);
    try testing.expectEqualStrings("foo", path.steps[0].node_test.name);
}

test "XPath.Parser: //foo expands to descendant-or-self::node()/foo" {
    var fx = try parseFixture("//foo");
    defer fx.arena.deinit();
    const path = fx.expr.path;
    try testing.expect(path.absolute);
    try testing.expectEqual(@as(usize, 2), path.steps.len);
    try testing.expectEqual(Ast.Axis.descendant_or_self, path.steps[0].axis);
    try testing.expectEqual(Ast.TypeTest.node, path.steps[0].node_test.type_test);
    try testing.expectEqualStrings("foo", path.steps[1].node_test.name);
}

test "XPath.Parser: relative path child::foo/bar" {
    var fx = try parseFixture("foo/bar");
    defer fx.arena.deinit();
    const path = fx.expr.path;
    try testing.expect(!path.absolute);
    try testing.expectEqual(@as(usize, 2), path.steps.len);
    try testing.expectEqual(Ast.Axis.child, path.steps[0].axis);
    try testing.expectEqualStrings("foo", path.steps[0].node_test.name);
    try testing.expectEqualStrings("bar", path.steps[1].node_test.name);
}

test "XPath.Parser: abbreviated steps . and .." {
    var fx = try parseFixture("./..");
    defer fx.arena.deinit();
    const path = fx.expr.path;
    try testing.expectEqual(@as(usize, 2), path.steps.len);
    try testing.expectEqual(Ast.Axis.self, path.steps[0].axis);
    try testing.expectEqual(Ast.Axis.parent, path.steps[1].axis);
}

test "XPath.Parser: attribute axis @class" {
    var fx = try parseFixture("@class");
    defer fx.arena.deinit();
    const step = fx.expr.path.steps[0];
    try testing.expectEqual(Ast.Axis.attribute, step.axis);
    try testing.expectEqualStrings("class", step.node_test.name);
}

test "XPath.Parser: all 12 named axes parse correctly" {
    inline for (.{
        .{ "child::a", Ast.Axis.child },
        .{ "descendant::a", Ast.Axis.descendant },
        .{ "descendant-or-self::a", Ast.Axis.descendant_or_self },
        .{ "self::a", Ast.Axis.self },
        .{ "parent::a", Ast.Axis.parent },
        .{ "ancestor::a", Ast.Axis.ancestor },
        .{ "ancestor-or-self::a", Ast.Axis.ancestor_or_self },
        .{ "following-sibling::a", Ast.Axis.following_sibling },
        .{ "preceding-sibling::a", Ast.Axis.preceding_sibling },
        .{ "following::a", Ast.Axis.following },
        .{ "preceding::a", Ast.Axis.preceding },
        .{ "namespace::a", Ast.Axis.namespace },
    }) |case| {
        var fx = try parseFixture(case[0]);
        defer fx.arena.deinit();
        try testing.expectEqual(case[1], fx.expr.path.steps[0].axis);
    }
}

test "XPath.Parser: unknown axis name maps to .unknown — polyfill parity" {
    var fx = try parseFixture("wibble::a");
    defer fx.arena.deinit();
    try testing.expectEqual(Ast.Axis.unknown, fx.expr.path.steps[0].axis);
}

test "XPath.Parser: wildcard *" {
    var fx = try parseFixture("*");
    defer fx.arena.deinit();
    try testing.expectEqualStrings("*", fx.expr.path.steps[0].node_test.name);
}

test "XPath.Parser: namespace-prefixed name and wildcard" {
    var fx = try parseFixture("svg:rect");
    defer fx.arena.deinit();
    try testing.expectEqualStrings("svg:rect", fx.expr.path.steps[0].node_test.name);

    var fx2 = try parseFixture("svg:*");
    defer fx2.arena.deinit();
    try testing.expectEqualStrings("svg:*", fx2.expr.path.steps[0].node_test.name);
}

test "XPath.Parser: node-type tests" {
    inline for (.{
        .{ "node()", Ast.TypeTest.node },
        .{ "text()", Ast.TypeTest.text },
        .{ "comment()", Ast.TypeTest.comment },
        .{ "processing-instruction()", Ast.TypeTest.processing_instruction },
    }) |case| {
        var fx = try parseFixture(case[0]);
        defer fx.arena.deinit();
        try testing.expectEqual(case[1], fx.expr.path.steps[0].node_test.type_test);
    }
}

test "XPath.Parser: processing-instruction with literal target — consumed but ignored" {
    var fx = try parseFixture("processing-instruction('xml-stylesheet')");
    defer fx.arena.deinit();
    try testing.expectEqual(Ast.TypeTest.processing_instruction, fx.expr.path.steps[0].node_test.type_test);
}

test "XPath.Parser: predicate on step" {
    var fx = try parseFixture("p[1]");
    defer fx.arena.deinit();
    const step = fx.expr.path.steps[0];
    try testing.expectEqual(@as(usize, 1), step.predicates.len);
    try testing.expectEqual(@as(f64, 1), step.predicates[0].number);
}

test "XPath.Parser: multi-predicate step" {
    var fx = try parseFixture("p[1][@x]");
    defer fx.arena.deinit();
    const step = fx.expr.path.steps[0];
    try testing.expectEqual(@as(usize, 2), step.predicates.len);
}

test "XPath.Parser: filter expression with predicate parses as Filter, not Step" {
    var fx = try parseFixture("(//a)[1]");
    defer fx.arena.deinit();
    // Top level is Filter wrapping a parenthesized path with one predicate.
    const filt = fx.expr.filter;
    try testing.expectEqual(@as(f64, 1), filt.predicate.number);
    try testing.expect(filt.expr.path.absolute);
}

test "XPath.Parser: filter with multi-predicate nests" {
    var fx = try parseFixture("(//a)[1][2]");
    defer fx.arena.deinit();
    const outer = fx.expr.filter;
    try testing.expectEqual(@as(f64, 2), outer.predicate.number);
    const inner = outer.expr.filter;
    try testing.expectEqual(@as(f64, 1), inner.predicate.number);
}

test "XPath.Parser: filter with location-path tail (filter_path)" {
    var fx = try parseFixture("(//a)/b");
    defer fx.arena.deinit();
    const fp = fx.expr.filter_path;
    try testing.expect(fp.filter.path.absolute);
    try testing.expectEqual(@as(usize, 1), fp.steps.len);
    try testing.expectEqualStrings("b", fp.steps[0].node_test.name);
}

test "XPath.Parser: filter with // tail prepends descendant-or-self" {
    var fx = try parseFixture("(//a)//b");
    defer fx.arena.deinit();
    const fp = fx.expr.filter_path;
    try testing.expectEqual(@as(usize, 2), fp.steps.len);
    try testing.expectEqual(Ast.Axis.descendant_or_self, fp.steps[0].axis);
    try testing.expectEqualStrings("b", fp.steps[1].node_test.name);
}

test "XPath.Parser: function call followed by predicate" {
    var fx = try parseFixture("id('x')[1]");
    defer fx.arena.deinit();
    const filt = fx.expr.filter;
    try testing.expectEqual(@as(f64, 1), filt.predicate.number);
    try testing.expectEqualStrings("id", filt.expr.fn_call.name);
}

test "XPath.Parser: complex representative expression" {
    var fx = try parseFixture("//div[@class='active']/p[position()<=last()-1]");
    defer fx.arena.deinit();
    const path = fx.expr.path;
    try testing.expect(path.absolute);
    try testing.expectEqual(@as(usize, 3), path.steps.len);
    try testing.expectEqual(Ast.Axis.descendant_or_self, path.steps[0].axis);
    try testing.expectEqualStrings("div", path.steps[1].node_test.name);
    try testing.expectEqual(@as(usize, 1), path.steps[1].predicates.len);
    try testing.expectEqualStrings("p", path.steps[2].node_test.name);
    try testing.expectEqual(@as(usize, 1), path.steps[2].predicates.len);
}

fn expectParseError(input: []const u8, expected: anyerror) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(expected, parse(arena.allocator(), input));
}

test "XPath.Parser: error on unbalanced paren" {
    try expectParseError("(1", error.UnexpectedToken);
}

test "XPath.Parser: error on unbalanced bracket" {
    try expectParseError("p[1", error.UnexpectedToken);
}

test "XPath.Parser: error on missing node test" {
    try expectParseError("child::", error.ExpectedNodeTest);
}

test "XPath.Parser: bare `+` falls through to step and reports missing node test" {
    // Matches polyfill: + isn't a path/primary start, so the parser
    // ends up in parseStep with no name to use as node test.
    try expectParseError("+", error.ExpectedNodeTest);
}

test "XPath.Parser: error on trailing tokens" {
    try expectParseError("1 2", error.UnexpectedToken);
}

test "XPath.Parser: empty string falls through to step and reports missing node test" {
    try expectParseError("", error.ExpectedNodeTest);
}

test "XPath.Parser: 91-case gem battery — every expression parses" {
    // Source: capybara-lightpanda spec/features/driver_spec.rb,
    // describe "XPath polyfill — XPath 1.0 conformance" battery.
    // Phase 2 acceptance criterion (references/phases.md).
    const battery = [_][]const u8{
        "/html",
        "/html/body",
        "/",
        "//h1",
        "//ul/li",
        "//ul//li",
        ".",
        ".//li",
        "//section/*",
        "//*[@id='heading']",
        "//li[1]/following-sibling::li",
        "//li[5]/preceding-sibling::li",
        "//li/parent::ul",
        "//li/ancestor::body",
        "//li/ancestor-or-self::body",
        "//li[3]/preceding::li",
        "//li[1]/following::li",
        "//ul/descendant::li",
        "//ul/descendant-or-self::li",
        "//section[1]/child::span",
        "//*[@id='heading']/self::h1",
        "//a[1]/attribute::href",
        "//a[1]/@*",
        "//li[1]",
        "//li[last()]",
        "//li[last() - 1]",
        "//li[position() = 1]",
        "//li[position() > 2]",
        "//li[position() mod 2 = 1]",
        "(//li)[1]",
        "(//section)[2]",
        "//li[3]/preceding-sibling::li[1]",
        "//li[5]/ancestor::*[1]",
        "//li[contains(concat(' ', @class, ' '), ' even ')][2]",
        "//*[@id='heading' and @class='primary']",
        "//*[@id='heading' or @id='p1']",
        "//section[a]",
        "//section[count(span) = 2]",
        "//ul[count(li) = 5]",
        "//tr[td[1]]",
        "//tr[td/text() = 'Bob']",
        "//*[starts-with(@id, 'link')]",
        "//*[normalize-space() = 'Hello World']",
        "//*[normalize-space(.) = 'Item 1']",
        "//*[concat(@id, '-x') = 'heading-x']",
        "//*[substring(@id, 1, 1) = 'p']",
        "//*[substring(@id, 2, 1) = '1' and starts-with(@id, 'p')]",
        "//p[translate(@id, 'p', 'q') = 'q1']",
        "//*[substring-before(@id, '1') = 'p']",
        "//*[substring-after(@id, 'lin') = 'k1']",
        "//tr[number(td[2]) > 28]",
        "//tr[floor(number(td[2]) div 10) = 3]",
        "//tr[ceiling(number(td[2]) div 10) = 3]",
        "//tr[round(number(td[2]) div 10) = 3]",
        "//ul[sum(li/@data-len) = 0]",
        "//p[boolean(@lang)]",
        "//*[false()]",
        "//*[name() = 'h1']",
        "//*[local-name() = 'h1']",
        "id('heading')",
        "id('heading p1')",
        "id(//em/parent::p/@id)",
        "//h1 | //title",
        "//h1 | //*[@id='p1']",
        "//*[@id='heading'] | //*[@id='heading']",
        "//li[position() + 1 = 3]",
        "//li[position() - 1 = 0]",
        "//li[position() * 2 = 4]",
        "//li[position() div 2 = 1]",
        "//li[(position() mod 2) = 0]",
        "//tr[number(td[2]) = 30]",
        "//tr[number(td[2]) != 30]",
        "//tr[number(td[2]) < 30]",
        "//tr[number(td[2]) <= 30]",
        "//tr[number(td[2]) > 30]",
        "//tr[number(td[2]) >= 30]",
        "//tr[td[2] = 30]",
        "//tr[td[2] = '30']",
        "//comment()",
        ".//a[contains(normalize-space(string(.)), 'Click me')]",
        ".//input[(./@type = 'text')]",
        ".//*[@id='heading']",
        ".//li[contains(concat(' ', @class, ' '), ' even ')]",
        "//*[@id='heading']/text()",
        "//em/parent::p",
        "//p[em]",
        "//p[not(em)]",
        "//section[a/@href = '/foo']",
        "//ul/li[last()][position() = last()]",
        "//ul[string(count(li)) = '5']",
        "//body[count(//*[contains(@class, 'item')]) = 5]",
    };
    try testing.expectEqual(@as(usize, 91), battery.len);

    for (battery) |expr| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        _ = parse(arena.allocator(), expr) catch |err| {
            std.debug.print("\n  failed to parse: {s}\n  error: {s}\n", .{ expr, @errorName(err) });
            return err;
        };
    }
}

test "XPath.Parser: deep parenthesization rejected past max_depth" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try buf.appendNTimes(testing.allocator, '(', max_depth + 1);
    try buf.append(testing.allocator, '1');
    try buf.appendNTimes(testing.allocator, ')', max_depth + 1);
    try testing.expectError(error.MaxDepthExceeded, parse(arena.allocator(), buf.items));
}

test "XPath.Parser: deep unary minus rejected past max_depth" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try buf.appendNTimes(testing.allocator, '-', max_depth + 1);
    try buf.append(testing.allocator, '1');
    try testing.expectError(error.MaxDepthExceeded, parse(arena.allocator(), buf.items));
}
