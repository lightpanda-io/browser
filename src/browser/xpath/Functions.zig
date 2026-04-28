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

//! XPath 1.0 core function library — 25 functions per polyfill parity
//! (lib/capybara/lightpanda/javascripts/index.js, `evalFunc` at lines
//! 646–770). `position()` and `last()` live in `Evaluator.evalFnCall`
//! because they need the `(pos, size)` closure that this module never
//! sees.
//!
//! Args are pre-evaluated by the caller (`Evaluator.evalFnCall`). Eager
//! evaluation matches the polyfill's `evaluate(args[i], ctx, pos, size)`
//! pattern — short-circuit operators (`or`/`and`) are binops, not
//! function calls, so laziness isn't required here. The pre-evaluation
//! contract also keeps Functions.zig free of a circular import on
//! Evaluator.zig.
//!
//! Stubs per decision #3 (XPATH_COMPLIANCE.md):
//!   - `lang(string)`         → always false
//!   - `namespace-uri(...)`   → always ""
//!   - `name`/`local-name`    → lowercased (HTML pragmatism)
//!
//! Allocations land in the caller's per-evaluation arena.

const std = @import("std");
const Allocator = std.mem.Allocator;
const lp = @import("lightpanda");

const Result = @import("Result.zig");
const Node = @import("../webapi/Node.zig");
const Element = Node.Element;
const Document = Node.Document;
const Frame = lp.Frame;

pub const Error = error{
    OutOfMemory,
    WriteFailed,
    StringTooLarge,
    UnknownFunction,
};

/// Dispatch a core-library function call. Returns `error.UnknownFunction`
/// if `name` doesn't match — the caller (Evaluator) handles
/// `position()` / `last()` inline before getting here, so this is the
/// last lookup stop.
pub fn call(
    arena: Allocator,
    frame: *Frame,
    name: []const u8,
    args: []const Result.Result,
    ctx: *Node,
) Error!Result.Result {
    // -- Node-set --
    if (eql(name, "count")) return .{ .number = countFn(args) };
    if (eql(name, "id")) return idFn(arena, frame, args, ctx);
    if (eql(name, "local-name")) return .{ .string = try localNameFn(arena, args, ctx) };
    if (eql(name, "name")) return .{ .string = try nameFn(arena, args, ctx) };
    if (eql(name, "namespace-uri")) return .{ .string = "" };

    // -- String --
    if (eql(name, "string")) return .{ .string = try stringFn(arena, args, ctx) };
    if (eql(name, "concat")) return .{ .string = try concatFn(arena, args) };
    if (eql(name, "starts-with")) return .{ .boolean = try startsWithFn(arena, args) };
    if (eql(name, "contains")) return .{ .boolean = try containsFn(arena, args) };
    if (eql(name, "substring-before")) return .{ .string = try substringBeforeFn(arena, args) };
    if (eql(name, "substring-after")) return .{ .string = try substringAfterFn(arena, args) };
    if (eql(name, "substring")) return .{ .string = try substringFn(arena, args) };
    if (eql(name, "string-length")) return .{ .number = try stringLengthFn(arena, args, ctx) };
    if (eql(name, "normalize-space")) return .{ .string = try normalizeSpaceFn(arena, args, ctx) };
    if (eql(name, "translate")) return .{ .string = try translateFn(arena, args) };

    // -- Boolean --
    if (eql(name, "boolean")) return .{ .boolean = if (args.len == 0) false else Result.toBoolean(args[0]) };
    if (eql(name, "not")) return .{ .boolean = if (args.len == 0) true else !Result.toBoolean(args[0]) };
    if (eql(name, "true")) return .{ .boolean = true };
    if (eql(name, "false")) return .{ .boolean = false };
    if (eql(name, "lang")) return .{ .boolean = false };

    // -- Number --
    if (eql(name, "number")) return .{ .number = try numberFn(arena, args, ctx) };
    if (eql(name, "sum")) return .{ .number = try sumFn(arena, args) };
    if (eql(name, "floor")) return .{ .number = if (args.len == 0) std.math.nan(f64) else std.math.floor(try Result.toNumber(arena, args[0])) };
    if (eql(name, "ceiling")) return .{ .number = if (args.len == 0) std.math.nan(f64) else std.math.ceil(try Result.toNumber(arena, args[0])) };
    if (eql(name, "round")) return .{ .number = if (args.len == 0) std.math.nan(f64) else roundHalfToPosInf(try Result.toNumber(arena, args[0])) };

    return error.UnknownFunction;
}

inline fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

// ----- node-set fns -----

fn countFn(args: []const Result.Result) f64 {
    if (args.len == 0 or args[0] != .node_set) return 0;
    return @floatFromInt(args[0].node_set.len);
}

fn idFn(arena: Allocator, frame: *Frame, args: []const Result.Result, ctx: *Node) Error!Result.Result {
    if (args.len == 0) return .{ .node_set = &.{} };

    // Polyfill: node-set arg → join `stringVal(n)` of each by ' '. Scalar
    // arg → `toStr`. Then split on whitespace and look up each token.
    const id_str: []const u8 = blk: {
        if (args[0] == .node_set) {
            var buf = std.Io.Writer.Allocating.init(arena);
            for (args[0].node_set, 0..) |n, i| {
                if (i > 0) try buf.writer.writeByte(' ');
                const sv = try Result.stringValueOf(arena, n);
                try buf.writer.writeAll(sv);
            }
            break :blk buf.written();
        }
        break :blk try Result.toString(arena, args[0]);
    };

    // `ctx.ownerDocument || ctx` — document nodes own themselves.
    const doc = ctx.ownerDocument(frame) orelse (ctx.is(Document) orelse return .{ .node_set = &.{} });

    var seen: std.AutoArrayHashMapUnmanaged(*Node, void) = .empty;
    var it = std.mem.tokenizeAny(u8, id_str, &std.ascii.whitespace);
    while (it.next()) |tok| {
        if (doc.getElementById(tok, frame)) |el| {
            try seen.put(arena, el.asNode(), {});
        }
    }
    return .{ .node_set = seen.keys() };
}

fn localNameFn(arena: Allocator, args: []const Result.Result, ctx: *Node) Error![]const u8 {
    const node = firstNodeOrCtx(args, ctx) orelse return "";
    // For Element, `getLocalName` returns a slice into `_tag_name`
    // (lowercase, namespace-prefix stripped) — lifetime exceeds the
    // per-evaluation arena, so we borrow instead of duping.
    if (node.is(Element)) |el| return el.getLocalName();
    var buf: [256]u8 = undefined;
    return std.ascii.allocLowerString(arena, node.getNodeName(&buf));
}

fn nameFn(arena: Allocator, args: []const Result.Result, ctx: *Node) Error![]const u8 {
    const node = firstNodeOrCtx(args, ctx) orelse return "";
    // Diverges from `local-name` only on namespaced elements: `name`
    // keeps the prefix (`ns:foo`), `local-name` strips it (`foo`).
    if (node.is(Element)) |el| return el.getTagNameLower();
    var buf: [256]u8 = undefined;
    return std.ascii.allocLowerString(arena, node.getNodeName(&buf));
}

fn firstNodeOrCtx(args: []const Result.Result, ctx: *Node) ?*Node {
    if (args.len == 0) return ctx;
    if (args[0] != .node_set) return null;
    if (args[0].node_set.len == 0) return null;
    return args[0].node_set[0];
}

// ----- string fns -----

fn stringFn(arena: Allocator, args: []const Result.Result, ctx: *Node) Error![]const u8 {
    if (args.len == 0) return try Result.stringValueOf(arena, ctx);
    return try Result.toString(arena, args[0]);
}

fn concatFn(arena: Allocator, args: []const Result.Result) Error![]const u8 {
    var buf = std.Io.Writer.Allocating.init(arena);
    for (args) |a| {
        const s = try Result.toString(arena, a);
        try buf.writer.writeAll(s);
    }
    return buf.written();
}

fn startsWithFn(arena: Allocator, args: []const Result.Result) Error!bool {
    if (args.len < 2) return false;
    const s1 = try Result.toString(arena, args[0]);
    const s2 = try Result.toString(arena, args[1]);
    return std.mem.startsWith(u8, s1, s2);
}

fn containsFn(arena: Allocator, args: []const Result.Result) Error!bool {
    if (args.len < 2) return false;
    const s1 = try Result.toString(arena, args[0]);
    const s2 = try Result.toString(arena, args[1]);
    return std.mem.indexOf(u8, s1, s2) != null;
}

fn substringBeforeFn(arena: Allocator, args: []const Result.Result) Error![]const u8 {
    if (args.len < 2) return "";
    const s1 = try Result.toString(arena, args[0]);
    const s2 = try Result.toString(arena, args[1]);
    if (std.mem.indexOf(u8, s1, s2)) |idx| {
        return s1[0..idx];
    }
    return "";
}

fn substringAfterFn(arena: Allocator, args: []const Result.Result) Error![]const u8 {
    if (args.len < 2) return "";
    const s1 = try Result.toString(arena, args[0]);
    const s2 = try Result.toString(arena, args[1]);
    if (std.mem.indexOf(u8, s1, s2)) |idx| {
        return s1[idx + s2.len ..];
    }
    return "";
}

fn substringFn(arena: Allocator, args: []const Result.Result) Error![]const u8 {
    if (args.len < 2) return "";
    const s = try Result.toString(arena, args[0]);
    const start_raw = try Result.toNumber(arena, args[1]);
    if (std.math.isNan(start_raw)) return "";
    const start = roundHalfToPosInf(start_raw);

    const s_len: f64 = @floatFromInt(s.len);
    if (args.len >= 3) {
        const len_raw = try Result.toNumber(arena, args[2]);
        if (std.math.isNan(len_raw)) return "";
        const len = roundHalfToPosInf(len_raw);
        const sum = start - 1 + len;
        // -inf + inf is NaN; @intFromFloat(NaN) is illegal behavior.
        if (std.math.isNan(sum)) return "";
        const si_f = @max(start - 1, 0);
        const ei_f = @min(sum, s_len);
        if (si_f >= ei_f) return "";
        const si: usize = @intFromFloat(si_f);
        const ei: usize = @intFromFloat(ei_f);
        return s[si..ei];
    }

    const si_f = @max(start - 1, 0);
    if (si_f >= s_len) return "";
    const si: usize = @intFromFloat(si_f);
    return s[si..];
}

fn stringLengthFn(arena: Allocator, args: []const Result.Result, ctx: *Node) Error!f64 {
    const s = if (args.len == 0)
        try Result.stringValueOf(arena, ctx)
    else
        try Result.toString(arena, args[0]);
    // Polyfill returns UTF-16 code units; we return UTF-8 bytes. They
    // agree on ASCII (the gem's 91-case battery is ASCII-only). See
    // .claude/skills/xpath-port/NOTES.md for the divergence rationale.
    return @floatFromInt(s.len);
}

fn normalizeSpaceFn(arena: Allocator, args: []const Result.Result, ctx: *Node) Error![]const u8 {
    const s = if (args.len == 0)
        try Result.stringValueOf(arena, ctx)
    else
        try Result.toString(arena, args[0]);

    const trimmed = std.mem.trim(u8, s, &std.ascii.whitespace);
    if (trimmed.len == 0) return "";

    var buf = std.Io.Writer.Allocating.init(arena);
    var prev_space = false;
    for (trimmed) |c| {
        if (std.ascii.isWhitespace(c)) {
            if (!prev_space) try buf.writer.writeByte(' ');
            prev_space = true;
        } else {
            try buf.writer.writeByte(c);
            prev_space = false;
        }
    }
    return buf.written();
}

fn translateFn(arena: Allocator, args: []const Result.Result) Error![]const u8 {
    if (args.len < 3) return "";
    const s = try Result.toString(arena, args[0]);
    const from = try Result.toString(arena, args[1]);
    const to = try Result.toString(arena, args[2]);

    var buf = std.Io.Writer.Allocating.init(arena);
    for (s) |c| {
        if (std.mem.indexOfScalar(u8, from, c)) |idx| {
            // Chars in `from` past `to.len` are deleted (no copy).
            if (idx < to.len) try buf.writer.writeByte(to[idx]);
        } else {
            try buf.writer.writeByte(c);
        }
    }
    return buf.written();
}

// ----- number fns -----

fn numberFn(arena: Allocator, args: []const Result.Result, ctx: *Node) Error!f64 {
    if (args.len == 0) {
        const sv = try Result.stringValueOf(arena, ctx);
        return Result.stringToNumber(sv);
    }
    return try Result.toNumber(arena, args[0]);
}

fn sumFn(arena: Allocator, args: []const Result.Result) Error!f64 {
    if (args.len == 0 or args[0] != .node_set) return std.math.nan(f64);
    var total: f64 = 0;
    for (args[0].node_set) |n| {
        const sv = try Result.stringValueOf(arena, n);
        total += Result.stringToNumber(sv);
    }
    return total;
}

/// Round half toward positive infinity. Matches JS `Math.round` (the
/// polyfill calls it for both `round()` and `substring()`):
///   round(0.5)  =  1   round(-0.5)  =  0
///   round(1.5)  =  2   round(-1.5)  = -1
/// Diverges from Zig's `@round` (away from zero): `@round(-0.5) = -1`.
fn roundHalfToPosInf(n: f64) f64 {
    if (std.math.isNan(n) or !std.math.isFinite(n)) return n;
    return std.math.floor(n + 0.5);
}

// ---------------------------------------------------------------------
// Tests — pure-logic only. Functions that need a real DOM (id, name,
// local-name, string with element ctx, sum, count of node-set, etc.)
// are exercised via Phase 9 HTML fixtures in tests/xpath/.
// ---------------------------------------------------------------------

const testing = std.testing;
const Tokenizer = @import("Tokenizer.zig");
const Parser = @import("Parser.zig");
const Evaluator = @import("Evaluator.zig");

fn evalScalar(a: Allocator, src: []const u8) !Result.Result {
    const expr = try Parser.parse(a, src);
    // Synthetic Frame/Node pointers — the public `evaluate` entry only
    // touches the Frame for path/axis evaluation. Pure-scalar expressions
    // (arithmetic, function calls returning scalars) never deref it.
    return Evaluator.evaluate(a, @ptrFromInt(0x1000), expr, @ptrFromInt(0x2000));
}

test "Functions: count() of non-node-set returns 0" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = try evalScalar(arena.allocator(), "count('hello')");
    try testing.expect(r == .number);
    try testing.expectEqual(@as(f64, 0), r.number);
}

test "Functions: string() on scalar coerces" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    inline for (.{
        .{ "string(42)", "42" },
        .{ "string(3.14)", "3.14" },
        .{ "string(true())", "true" },
        .{ "string(false())", "false" },
        .{ "string('hello')", "hello" },
        .{ "string(0)", "0" },
        .{ "string(-1)", "-1" },
    }) |case| {
        const r = try evalScalar(a, case[0]);
        try testing.expect(r == .string);
        try testing.expectEqualStrings(case[1], r.string);
    }
}

test "Functions: concat() variadic" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    inline for (.{
        .{ "concat('a', 'b')", "ab" },
        .{ "concat('a', 'b', 'c')", "abc" },
        .{ "concat('foo', '-', 'bar', '-', 'baz')", "foo-bar-baz" },
        .{ "concat('x', 1, 'y')", "x1y" },
    }) |case| {
        const r = try evalScalar(a, case[0]);
        try testing.expect(r == .string);
        try testing.expectEqualStrings(case[1], r.string);
    }
}

test "Functions: starts-with / contains" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    inline for (.{
        .{ "starts-with('hello', 'he')", true },
        .{ "starts-with('hello', 'el')", false },
        .{ "starts-with('hello', '')", true },
        .{ "contains('hello world', 'wor')", true },
        .{ "contains('hello', 'xyz')", false },
        .{ "contains('hello', '')", true },
    }) |case| {
        const r = try evalScalar(a, case[0]);
        try testing.expect(r == .boolean);
        try testing.expectEqual(case[1], r.boolean);
    }
}

test "Functions: substring-before / substring-after" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    inline for (.{
        .{ "substring-before('1999/04/01', '/')", "1999" },
        .{ "substring-before('hello', 'xyz')", "" },
        .{ "substring-after('1999/04/01', '/')", "04/01" },
        .{ "substring-after('hello', 'xyz')", "" },
        .{ "substring-after('hello', '')", "hello" },
    }) |case| {
        const r = try evalScalar(a, case[0]);
        try testing.expect(r == .string);
        try testing.expectEqualStrings(case[1], r.string);
    }
}

test "Functions: substring() — XPath 1-based, rounding, NaN handling" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    inline for (.{
        .{ "substring('12345', 2, 3)", "234" },
        .{ "substring('12345', 2)", "2345" },
        // XPath spec example: round(1.5) = 2 → start at pos 2, len 2.
        .{ "substring('12345', 1.5, 2.6)", "234" },
        // start = 0: si = max(-1, 0) = 0, ei = min(0 - 1 + 3, len) = 2.
        .{ "substring('12345', 0, 3)", "12" },
        // Negative start clamps to 0.
        .{ "substring('12345', -3, 7)", "123" },
        // NaN start.
        .{ "substring('12345', 'foo')", "" },
        // NaN length.
        .{ "substring('12345', 1, 'foo')", "" },
    }) |case| {
        const r = try evalScalar(a, case[0]);
        try testing.expect(r == .string);
        try testing.expectEqualStrings(case[1], r.string);
    }
}

test "Functions: string-length on scalar arg" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    inline for (.{
        .{ "string-length('hello')", 5 },
        .{ "string-length('')", 0 },
        .{ "string-length('a b c')", 5 },
    }) |case| {
        const r = try evalScalar(a, case[0]);
        try testing.expect(r == .number);
        try testing.expectEqual(@as(f64, case[1]), r.number);
    }
}

test "Functions: normalize-space" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    inline for (.{
        .{ "normalize-space('  hello   world  ')", "hello world" },
        .{ "normalize-space('hello')", "hello" },
        .{ "normalize-space('')", "" },
        .{ "normalize-space('   ')", "" },
        .{ "normalize-space('a\tb\nc')", "a b c" },
    }) |case| {
        const r = try evalScalar(a, case[0]);
        try testing.expect(r == .string);
        try testing.expectEqualStrings(case[1], r.string);
    }
}

test "Functions: translate" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    inline for (.{
        // Standard XPath spec example.
        .{ "translate('bar', 'abc', 'ABC')", "BAr" },
        // Char in `from` past `to.len` is deleted.
        .{ "translate('--aaa--', 'abc-', 'ABC')", "AAA" },
        .{ "translate('hello', '', '')", "hello" },
        // Identity.
        .{ "translate('abc', 'abc', 'abc')", "abc" },
    }) |case| {
        const r = try evalScalar(a, case[0]);
        try testing.expect(r == .string);
        try testing.expectEqualStrings(case[1], r.string);
    }
}

test "Functions: boolean / not / true / false / lang" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    inline for (.{
        .{ "true()", true },
        .{ "false()", false },
        .{ "not(true())", false },
        .{ "not(false())", true },
        .{ "boolean(1)", true },
        .{ "boolean(0)", false },
        .{ "boolean('')", false },
        .{ "boolean('x')", true },
        // lang is a stub — always false.
        .{ "lang('en')", false },
    }) |case| {
        const r = try evalScalar(a, case[0]);
        try testing.expect(r == .boolean);
        try testing.expectEqual(case[1], r.boolean);
    }
}

test "Functions: number() on scalar arg" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    {
        const r = try evalScalar(a, "number('42')");
        try testing.expectEqual(@as(f64, 42), r.number);
    }
    {
        const r = try evalScalar(a, "number(true())");
        try testing.expectEqual(@as(f64, 1), r.number);
    }
    {
        const r = try evalScalar(a, "number(false())");
        try testing.expectEqual(@as(f64, 0), r.number);
    }
    {
        const r = try evalScalar(a, "number('foo')");
        try testing.expect(std.math.isNan(r.number));
    }
}

test "Functions: floor / ceiling / round" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    inline for (.{
        .{ "floor(1.5)", 1 },
        .{ "floor(-1.5)", -2 },
        .{ "floor(0)", 0 },
        .{ "ceiling(1.5)", 2 },
        .{ "ceiling(-1.5)", -1 },
        .{ "ceiling(0)", 0 },
        // Half-toward-positive-infinity (JS Math.round behavior).
        .{ "round(0.5)", 1 },
        .{ "round(-0.5)", 0 },
        .{ "round(1.5)", 2 },
        .{ "round(-1.5)", -1 },
        .{ "round(2.5)", 3 },
    }) |case| {
        const r = try evalScalar(a, case[0]);
        try testing.expect(r == .number);
        try testing.expectEqual(@as(f64, case[1]), r.number);
    }
}

test "Functions: round/floor/ceiling propagate NaN and Infinity" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    {
        const r = try evalScalar(a, "round(1 div 0)"); // +Infinity
        try testing.expect(std.math.isPositiveInf(r.number));
    }
    {
        const r = try evalScalar(a, "round(0 div 0)"); // NaN
        try testing.expect(std.math.isNan(r.number));
    }
    {
        const r = try evalScalar(a, "floor(0 div 0)");
        try testing.expect(std.math.isNan(r.number));
    }
    {
        const r = try evalScalar(a, "ceiling(0 div 0)");
        try testing.expect(std.math.isNan(r.number));
    }
}

test "Functions: sum / count on non-node-set defaults" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    {
        const r = try evalScalar(a, "sum('hello')");
        try testing.expect(std.math.isNan(r.number));
    }
    {
        const r = try evalScalar(a, "count('hello')");
        try testing.expectEqual(@as(f64, 0), r.number);
    }
}

test "Functions: roundHalfToPosInf" {
    try testing.expectEqual(@as(f64, 1), roundHalfToPosInf(0.5));
    try testing.expectEqual(@as(f64, 0), roundHalfToPosInf(-0.5));
    try testing.expectEqual(@as(f64, 2), roundHalfToPosInf(1.5));
    try testing.expectEqual(@as(f64, -1), roundHalfToPosInf(-1.5));
    try testing.expectEqual(@as(f64, 3), roundHalfToPosInf(2.5));
    try testing.expect(std.math.isNan(roundHalfToPosInf(std.math.nan(f64))));
    try testing.expect(std.math.isPositiveInf(roundHalfToPosInf(std.math.inf(f64))));
    try testing.expect(std.math.isNegativeInf(roundHalfToPosInf(-std.math.inf(f64))));
}
