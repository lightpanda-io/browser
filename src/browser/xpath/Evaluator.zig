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

//! XPath 1.0 evaluator — runs an `Ast.Expr` against a context node and
//! produces a `Result`. Mirrors the polyfill's `evaluate()` and
//! `evalStep()` (lib/capybara/lightpanda/javascripts/index.js, lines
//! 344–644). The evaluator allocates intermediate values (node-set
//! slices, formatted numbers, materialized attribute nodes) into the
//! caller's arena. The context `Frame` is needed for `getElementById`
//! and to materialize attributes (the attribute axis returns full
//! `Attribute` nodes so the result is `*Node`-uniform).
//!
//! Document-order sort happens once at the public boundary
//! (`evaluate()`); intermediate step results stay in axis order so
//! reverse-axis positional predicates evaluate against proximity.

const std = @import("std");
const Allocator = std.mem.Allocator;
const lp = @import("lightpanda");

const Ast = @import("Ast.zig");
const Parser = @import("Parser.zig");
const Result = @import("Result.zig");
const Functions = @import("Functions.zig");
const Node = @import("../webapi/Node.zig");
const Element = Node.Element;
const Document = Node.Document;
const Frame = lp.Frame;

const Evaluator = @This();

pub const Error = error{
    OutOfMemory,
    WriteFailed,
    // Surfaces from Attribute materialization (`Entry.toAttribute` →
    // `String.dupe` enforces a length limit). The polyfill never hits
    // this since JS strings are unbounded, but Lightpanda's `String`
    // type caps at u32::MAX bytes — propagate so callers can surface
    // a DOM exception.
    StringTooLarge,
    UnknownFunction,
    UnionRequiresNodeSets,
};

arena: Allocator,
frame: *Frame,

/// Public entry. Returns the AST's value; node-sets are sorted into
/// document order before return per XPath spec §3.3.
pub fn evaluate(arena: Allocator, frame: *Frame, expr: *const Ast.Expr, context_node: *Node) Error!Result.Result {
    var ev = Evaluator{ .arena = arena, .frame = frame };
    const result = try ev.evalExpr(expr, context_node, 1, 1);
    if (result == .node_set) {
        sortDocOrder(@constCast(result.node_set));
    }
    return result;
}

pub const SearchError = Error || Parser.Error;

/// Convenience for `DOM.performSearch` and capybara `xpathFind`: parse +
/// evaluate and unwrap the node-set. Top-level scalar expressions yield
/// an empty slice (decision #3 — these APIs are for finding nodes, not
/// arbitrary computation).
pub fn searchAll(arena: Allocator, frame: *Frame, root: *Node, expression: []const u8) SearchError![]const *Node {
    const expr = try Parser.parse(arena, expression);
    return switch (try evaluate(arena, frame, expr, root)) {
        .node_set => |ns| ns,
        else => &.{},
    };
}

// ----- AST evaluation -----

fn evalExpr(self: *Evaluator, expr: *const Ast.Expr, ctx: *Node, pos: usize, size: usize) Error!Result.Result {
    return switch (expr.*) {
        .number => |n| .{ .number = n },
        .literal => |s| .{ .string = s },
        .var_ref => .{ .string = "" }, // decision #3 stub
        .neg => |inner| blk: {
            const v = try self.evalExpr(inner, ctx, pos, size);
            const n = try Result.toNumber(self.arena, v);
            break :blk .{ .number = -n };
        },
        .binop => |bo| try self.evalBinop(bo, ctx, pos, size),
        .path => |p| try self.evalPath(p, ctx),
        .filter_path => |fp| try self.evalFilterPath(fp, ctx, pos, size),
        .filter => |f| try self.evalFilter(f, ctx, pos, size),
        .fn_call => |fc| try self.evalFnCall(fc, ctx, pos, size),
    };
}

fn evalPath(self: *Evaluator, path: Ast.Path, ctx: *Node) Error!Result.Result {
    const start: *Node = if (path.absolute) blk: {
        if (ctx._type == .document) break :blk ctx;
        const owner = ctx.ownerDocument(self.frame) orelse break :blk ctx;
        break :blk owner.asNode();
    } else ctx;

    var current = try self.arena.alloc(*Node, 1);
    current[0] = start;
    var current_set: []const *Node = current;

    for (path.steps) |step| {
        const r = try self.evalStep(current_set, step);
        current_set = r.node_set;
    }
    return .{ .node_set = current_set };
}

fn evalFilterPath(self: *Evaluator, fp: Ast.FilterPath, ctx: *Node, pos: usize, size: usize) Error!Result.Result {
    const base = try self.evalExpr(fp.filter, ctx, pos, size);
    if (base != .node_set) return base;

    var current: []const *Node = base.node_set;
    for (fp.steps) |step| {
        const r = try self.evalStep(current, step);
        current = r.node_set;
    }
    return .{ .node_set = current };
}

fn evalFilter(self: *Evaluator, f: Ast.Filter, ctx: *Node, pos: usize, size: usize) Error!Result.Result {
    const base = try self.evalExpr(f.expr, ctx, pos, size);
    if (base != .node_set) return base;

    var out: std.ArrayList(*Node) = .empty;
    const sz = base.node_set.len;
    for (base.node_set, 0..) |n, idx| {
        const k = idx + 1;
        const val = try self.evalExpr(f.predicate, n, k, sz);
        if (predicateMatches(val, k)) try out.append(self.arena, n);
    }
    return .{ .node_set = out.items };
}

// ----- step + axis -----

fn evalStep(self: *Evaluator, ctx_nodes: []const *Node, step: Ast.Step) Error!Result.Result {
    var dedup: std.AutoArrayHashMapUnmanaged(*Node, void) = .empty;

    // Pre-lowercase the name test once per step. matchNameTest does
    // case-insensitive matching (decision #2); without this hoist, every
    // axis node would pay the per-byte case-fold inside `eqlIgnoreCase`.
    const lowered_name: ?[]const u8 = switch (step.node_test) {
        .name => |n| if (std.mem.eql(u8, n, "*")) null else try std.ascii.allocLowerString(self.arena, n),
        .type_test => null,
    };

    for (ctx_nodes) |ctx| {
        const axis_nodes = try self.axisNodes(ctx, step.axis);

        var filtered: std.ArrayList(*Node) = .empty;
        for (axis_nodes) |n| {
            if (matchTest(n, step.node_test, step.axis, lowered_name)) {
                try filtered.append(self.arena, n);
            }
        }

        var current: []const *Node = filtered.items;
        for (step.predicates) |pred| {
            var next: std.ArrayList(*Node) = .empty;
            const sz = current.len;
            for (current, 0..) |n, idx| {
                const k = idx + 1;
                const val = try self.evalExpr(pred, n, k, sz);
                if (predicateMatches(val, k)) try next.append(self.arena, n);
            }
            current = next.items;
        }

        for (current) |n| try dedup.put(self.arena, n, {});
    }

    return .{ .node_set = dedup.keys() };
}

fn axisNodes(self: *Evaluator, node: *Node, axis: Ast.Axis) Error![]const *Node {
    var out: std.ArrayList(*Node) = .empty;
    switch (axis) {
        .child => {
            var it = node.childrenIterator();
            while (it.next()) |c| try out.append(self.arena, c);
        },
        .descendant => try self.appendDescendants(node, &out),
        .descendant_or_self => {
            try out.append(self.arena, node);
            try self.appendDescendants(node, &out);
        },
        .self => try out.append(self.arena, node),
        .parent => {
            if (node.parentNode()) |p| try out.append(self.arena, p);
        },
        // Reverse axes — proximity order (nearest first). Final node-set
        // is sorted to document order at the public boundary.
        .ancestor => {
            var p = node.parentNode();
            while (p) |n| : (p = n.parentNode()) try out.append(self.arena, n);
        },
        .ancestor_or_self => {
            try out.append(self.arena, node);
            var p = node.parentNode();
            while (p) |n| : (p = n.parentNode()) try out.append(self.arena, n);
        },
        .following_sibling => {
            var s = node.nextSibling();
            while (s) |n| : (s = n.nextSibling()) try out.append(self.arena, n);
        },
        .preceding_sibling => {
            var s = node.previousSibling();
            while (s) |n| : (s = n.previousSibling()) try out.append(self.arena, n);
        },
        .following => try self.appendFollowing(node, &out),
        .preceding => try self.appendPreceding(node, &out),
        .attribute => try self.appendAttributes(node, &out),
        .namespace, .unknown => {}, // decision #3 stubs
    }
    return out.items;
}

fn appendDescendants(self: *Evaluator, node: *Node, out: *std.ArrayList(*Node)) Error!void {
    var it = node.childrenIterator();
    while (it.next()) |c| {
        try out.append(self.arena, c);
        try self.appendDescendants(c, out);
    }
}

fn appendFollowing(self: *Evaluator, start: *Node, out: *std.ArrayList(*Node)) Error!void {
    var n: ?*Node = start;
    while (n) |cur| : (n = cur.parentNode()) {
        var s = cur.nextSibling();
        while (s) |sn| : (s = sn.nextSibling()) {
            try out.append(self.arena, sn);
            try self.appendDescendants(sn, out);
        }
    }
}

fn appendPrecedingSubtree(self: *Evaluator, n: *Node, out: *std.ArrayList(*Node)) Error!void {
    // Reverse document order: deepest-last children first, then self.
    var c = n.lastChild();
    while (c) |child| : (c = child.previousSibling()) {
        try self.appendPrecedingSubtree(child, out);
    }
    try out.append(self.arena, n);
}

fn appendPreceding(self: *Evaluator, start: *Node, out: *std.ArrayList(*Node)) Error!void {
    var n: ?*Node = start;
    while (n) |cur| {
        const parent = cur.parentNode() orelse break;
        var s = cur.previousSibling();
        while (s) |sn| : (s = sn.previousSibling()) {
            try self.appendPrecedingSubtree(sn, out);
        }
        n = parent;
    }
}

fn appendAttributes(self: *Evaluator, node: *Node, out: *std.ArrayList(*Node)) Error!void {
    const el = node.is(Element) orelse return;
    var it = el.attributeIterator();
    while (it.next()) |entry| {
        // Memoize via frame._attribute_lookup so repeated XPath queries
        // (Capybara/Selenium polling) reuse the same *Attribute instead
        // of leaking fresh ones into page-lifetime storage on every call.
        // Same pattern as Attribute.List.getAttribute / NamedNodeMap.getAtIndex.
        const gop = try self.frame._attribute_lookup.getOrPut(self.frame.arena, @intFromPtr(entry));
        if (!gop.found_existing) {
            gop.value_ptr.* = try entry.toAttribute(el, self.frame);
        }
        try out.append(self.arena, gop.value_ptr.*._proto);
    }
}

// ----- node test matching -----

fn matchTest(node: *Node, test_: Ast.NodeTest, axis: Ast.Axis, lowered_name: ?[]const u8) bool {
    return switch (test_) {
        .type_test => |kind| switch (kind) {
            .node => true,
            .text => node.getNodeType() == 3,
            .comment => node.getNodeType() == 8,
            .processing_instruction => node.getNodeType() == 7,
        },
        .name => |name| matchNameTest(node, name, axis, lowered_name),
    };
}

fn matchNameTest(node: *Node, name: []const u8, axis: Ast.Axis, lowered_name: ?[]const u8) bool {
    // `lowered_name` is non-null iff `name != "*"`. Element tag names
    // (`getTagNameLower`) and html5ever-stored attribute names are already
    // lowercase, so a plain `mem.eql` against the pre-lowered test name
    // replaces the per-call `eqlIgnoreCase`.
    if (axis == .attribute) {
        if (std.mem.eql(u8, name, "*")) return node._type == .attribute;
        const attr = switch (node._type) {
            .attribute => |a| a,
            else => return false,
        };
        return std.mem.eql(u8, attr._name.str(), lowered_name.?);
    }
    const el = node.is(Element) orelse return false;
    if (std.mem.eql(u8, name, "*")) return true;
    return std.mem.eql(u8, el.getTagNameLower(), lowered_name.?);
}

// ----- binop -----

fn evalBinop(self: *Evaluator, bo: Ast.BinOp, ctx: *Node, pos: usize, size: usize) Error!Result.Result {
    switch (bo.op) {
        .or_ => {
            const l = try self.evalExpr(bo.left, ctx, pos, size);
            if (Result.toBoolean(l)) return .{ .boolean = true };
            const r = try self.evalExpr(bo.right, ctx, pos, size);
            return .{ .boolean = Result.toBoolean(r) };
        },
        .and_ => {
            const l = try self.evalExpr(bo.left, ctx, pos, size);
            if (!Result.toBoolean(l)) return .{ .boolean = false };
            const r = try self.evalExpr(bo.right, ctx, pos, size);
            return .{ .boolean = Result.toBoolean(r) };
        },
        .eq, .neq, .lt, .gt, .lte, .gte => {
            const l = try self.evalExpr(bo.left, ctx, pos, size);
            const r = try self.evalExpr(bo.right, ctx, pos, size);
            return .{ .boolean = try self.xCmp(l, r, bo.op) };
        },
        .add, .sub, .mul, .div, .mod => {
            const l = try self.evalExpr(bo.left, ctx, pos, size);
            const r = try self.evalExpr(bo.right, ctx, pos, size);
            const ln = try Result.toNumber(self.arena, l);
            const rn = try Result.toNumber(self.arena, r);
            const v: f64 = switch (bo.op) {
                .add => ln + rn,
                .sub => ln - rn,
                .mul => ln * rn,
                .div => ln / rn,
                // JS `%` and Zig `@rem` agree on sign for finite values
                // and propagate NaN (XPath §3.5).
                .mod => @rem(ln, rn),
                else => unreachable,
            };
            return .{ .number = v };
        },
        .union_ => {
            const l = try self.evalExpr(bo.left, ctx, pos, size);
            const r = try self.evalExpr(bo.right, ctx, pos, size);
            if (l != .node_set or r != .node_set) return error.UnionRequiresNodeSets;
            var seen: std.AutoArrayHashMapUnmanaged(*Node, void) = .empty;
            for (l.node_set) |n| try seen.put(self.arena, n, {});
            for (r.node_set) |n| try seen.put(self.arena, n, {});
            const nodes = seen.keys();
            sortDocOrder(@constCast(nodes));
            return .{ .node_set = nodes };
        },
    }
}

// ----- comparison (XPath spec §3.4) -----

fn xCmp(self: *Evaluator, left: Result.Result, right: Result.Result, op: Ast.BinOpKind) Error!bool {
    const is_eq = (op == .eq or op == .neq);
    const l_is_set = (left == .node_set);
    const r_is_set = (right == .node_set);

    if (l_is_set and r_is_set) {
        // Cache right-side string-values once. Without this, each left node
        // would pay |right| allocations — O(N×M) for a set×set comparison
        // (e.g. `//foo = //bar` on a large page).
        const right_strings = try self.arena.alloc([]const u8, right.node_set.len);
        for (right.node_set, 0..) |r, i| {
            right_strings[i] = try Result.stringValueOf(self.arena, r);
        }
        for (left.node_set) |l| {
            const lv = try Result.stringValueOf(self.arena, l);
            for (right_strings) |rv| {
                const matched = if (is_eq)
                    cmpString(lv, rv, op)
                else
                    cmpNumber(Result.stringToNumber(lv), Result.stringToNumber(rv), op);
                if (matched) return true;
            }
        }
        return false;
    }

    if (l_is_set or r_is_set) {
        const ns = if (l_is_set) left.node_set else right.node_set;
        const other = if (l_is_set) right else left;
        const ns_left = l_is_set;

        if (other == .boolean) {
            const ns_b = ns.len > 0;
            const a, const b = if (ns_left) .{ ns_b, other.boolean } else .{ other.boolean, ns_b };
            return cmpBool(a, b, op);
        }

        for (ns) |n| {
            const sv = try Result.stringValueOf(self.arena, n);
            const matched = switch (other) {
                .number => |num| blk: {
                    const sv_num = Result.stringToNumber(sv);
                    const a, const b = if (ns_left) .{ sv_num, num } else .{ num, sv_num };
                    break :blk cmpNumber(a, b, op);
                },
                .string => |s| blk: {
                    if (is_eq) {
                        const a, const b = if (ns_left) .{ sv, s } else .{ s, sv };
                        break :blk cmpString(a, b, op);
                    }
                    const sv_num = Result.stringToNumber(sv);
                    const s_num = Result.stringToNumber(s);
                    const a, const b = if (ns_left) .{ sv_num, s_num } else .{ s_num, sv_num };
                    break :blk cmpNumber(a, b, op);
                },
                .boolean, .node_set => unreachable, // handled above
            };
            if (matched) return true;
        }
        return false;
    }

    // Neither is a node-set.
    if (is_eq) {
        if (left == .boolean or right == .boolean) {
            return cmpBool(Result.toBoolean(left), Result.toBoolean(right), op);
        }
        if (left == .number or right == .number) {
            const ln = try Result.toNumber(self.arena, left);
            const rn = try Result.toNumber(self.arena, right);
            return cmpNumber(ln, rn, op);
        }
        const ls = try Result.toString(self.arena, left);
        const rs = try Result.toString(self.arena, right);
        return cmpString(ls, rs, op);
    }
    // Non-eq with no node-set: both → number.
    const ln = try Result.toNumber(self.arena, left);
    const rn = try Result.toNumber(self.arena, right);
    return cmpNumber(ln, rn, op);
}

fn cmpString(a: []const u8, b: []const u8, op: Ast.BinOpKind) bool {
    const equal = std.mem.eql(u8, a, b);
    return switch (op) {
        .eq => equal,
        .neq => !equal,
        else => unreachable, // <, > etc. always coerce to number first
    };
}

fn cmpNumber(a: f64, b: f64, op: Ast.BinOpKind) bool {
    // Native f64 comparison gives correct NaN semantics:
    // NaN == X is false, NaN != X is true, NaN < X (etc.) is false.
    return switch (op) {
        .eq => a == b,
        .neq => a != b,
        .lt => a < b,
        .gt => a > b,
        .lte => a <= b,
        .gte => a >= b,
        else => unreachable,
    };
}

fn cmpBool(a: bool, b: bool, op: Ast.BinOpKind) bool {
    return switch (op) {
        .eq => a == b,
        .neq => a != b,
        else => unreachable,
    };
}

// ----- function calls -----

fn evalFnCall(self: *Evaluator, fc: Ast.FnCall, ctx: *Node, pos: usize, size: usize) Error!Result.Result {
    // position()/last() stay here — they need the (pos, size) closure
    // that Functions.call doesn't see. Keeping them inline avoids
    // pushing per-call context through Functions' signature.
    if (std.mem.eql(u8, fc.name, "position")) return .{ .number = @floatFromInt(pos) };
    if (std.mem.eql(u8, fc.name, "last")) return .{ .number = @floatFromInt(size) };

    // Eagerly evaluate args. Matches the polyfill's `evaluate(args[i], ...)`
    // pattern; lazy short-circuit isn't needed because `or`/`and` are
    // binops handled in evalBinop, not function calls.
    const eval_args = try self.arena.alloc(Result.Result, fc.args.len);
    for (fc.args, 0..) |a, i| eval_args[i] = try self.evalExpr(a, ctx, pos, size);

    return Functions.call(self.arena, self.frame, fc.name, eval_args, ctx);
}

// ----- helpers -----

fn predicateMatches(val: Result.Result, position: usize) bool {
    return switch (val) {
        // Numeric predicate value selects only the node at that position
        // (1-based). Non-integer numbers never match.
        .number => |n| n == @as(f64, @floatFromInt(position)),
        else => Result.toBoolean(val),
    };
}

pub fn sortDocOrder(nodes: []*Node) void {
    if (nodes.len <= 1) return;
    std.mem.sort(*Node, nodes, {}, lessThanDocOrder);
}

fn lessThanDocOrder(_: void, a: *Node, b: *Node) bool {
    if (a == b) return false;
    const pos = a.compareDocumentPosition(b);
    // FOLLOWING (0x04) — b comes after a in document order.
    return (pos & 0x04) != 0;
}

// ---------------------------------------------------------------------
// Tests — pure-logic only. DOM-dependent evaluation lands as HTML
// fixtures in Phase 9 (tests/xpath/*.html); Lightpanda has no in-Zig
// way to construct a Frame + Document tree without the JS runtime.
// ---------------------------------------------------------------------

const testing = std.testing;
const Tokenizer = @import("Tokenizer.zig");

test "Evaluator: cmpNumber NaN semantics" {
    const nan = std.math.nan(f64);
    try testing.expect(!cmpNumber(nan, nan, .eq));
    try testing.expect(cmpNumber(nan, nan, .neq));
    try testing.expect(!cmpNumber(nan, 0, .lt));
    try testing.expect(!cmpNumber(nan, 0, .gt));
    try testing.expect(!cmpNumber(nan, 0, .lte));
    try testing.expect(!cmpNumber(nan, 0, .gte));
    try testing.expect(cmpNumber(0, 0, .eq));
    try testing.expect(cmpNumber(1, 2, .lt));
    try testing.expect(cmpNumber(2, 1, .gt));
    try testing.expect(cmpNumber(1, 1, .lte));
    try testing.expect(cmpNumber(1, 1, .gte));
}

test "Evaluator: cmpString" {
    try testing.expect(cmpString("a", "a", .eq));
    try testing.expect(!cmpString("a", "b", .eq));
    try testing.expect(cmpString("a", "b", .neq));
    try testing.expect(!cmpString("a", "a", .neq));
}

test "Evaluator: cmpBool" {
    try testing.expect(cmpBool(true, true, .eq));
    try testing.expect(!cmpBool(true, false, .eq));
    try testing.expect(cmpBool(true, false, .neq));
}

test "Evaluator: predicateMatches numeric vs boolean" {
    try testing.expect(predicateMatches(.{ .number = 1 }, 1));
    try testing.expect(!predicateMatches(.{ .number = 2 }, 1));
    // Non-integer never matches.
    try testing.expect(!predicateMatches(.{ .number = 1.5 }, 1));
    // Boolean: any truthy value passes regardless of position.
    try testing.expect(predicateMatches(.{ .boolean = true }, 7));
    try testing.expect(!predicateMatches(.{ .boolean = false }, 1));
    // String: nonempty truthy.
    try testing.expect(predicateMatches(.{ .string = "x" }, 99));
    try testing.expect(!predicateMatches(.{ .string = "" }, 1));
    // Empty node-set: falsy.
    try testing.expect(!predicateMatches(.{ .node_set = &.{} }, 1));
}

test "Evaluator: scalar arithmetic via parsed expressions" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    inline for (.{
        .{ "1 + 2", 3 },
        .{ "5 - 3", 2 },
        .{ "4 * 2", 8 },
        .{ "10 div 4", 2.5 },
        .{ "10 mod 3", 1 },
        .{ "-5", -5 },
        .{ "1 + 2 * 3", 7 },
    }) |case| {
        const expr = try Parser.parse(a, case[0]);
        // Frame is unused for pure-arithmetic AST. The unsafe cast lets
        // us exercise binop / number paths without a real DOM. Any path
        // accessing the Frame would crash; the inputs above never do.
        var ev = Evaluator{ .arena = a, .frame = @ptrFromInt(0x1000) };
        const ctx_dummy: *Node = @ptrFromInt(0x2000);
        const r = try ev.evalExpr(expr, ctx_dummy, 1, 1);
        try testing.expect(r == .number);
        try testing.expectEqual(@as(f64, case[1]), r.number);
    }
}

test "Evaluator: scalar comparison via parsed expressions" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    inline for (.{
        .{ "1 = 1", true },
        .{ "1 = 2", false },
        .{ "1 != 2", true },
        .{ "1 < 2", true },
        .{ "2 < 1", false },
        .{ "1 <= 1", true },
        .{ "2 >= 2", true },
        .{ "'abc' = 'abc'", true },
        .{ "'abc' != 'abd'", true },
    }) |case| {
        const expr = try Parser.parse(a, case[0]);
        var ev = Evaluator{ .arena = a, .frame = @ptrFromInt(0x1000) };
        const ctx_dummy: *Node = @ptrFromInt(0x2000);
        const r = try ev.evalExpr(expr, ctx_dummy, 1, 1);
        try testing.expect(r == .boolean);
        try testing.expectEqual(case[1], r.boolean);
    }
}

test "Evaluator: position() and last() reflect context" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ctx_dummy: *Node = @ptrFromInt(0x2000);

    {
        const expr = try Parser.parse(a, "position()");
        var ev = Evaluator{ .arena = a, .frame = @ptrFromInt(0x1000) };
        const r = try ev.evalExpr(expr, ctx_dummy, 3, 5);
        try testing.expectEqual(@as(f64, 3), r.number);
    }
    {
        const expr = try Parser.parse(a, "last()");
        var ev = Evaluator{ .arena = a, .frame = @ptrFromInt(0x1000) };
        const r = try ev.evalExpr(expr, ctx_dummy, 3, 5);
        try testing.expectEqual(@as(f64, 5), r.number);
    }
    {
        // Logical short-circuit: last() never evaluates if first
        // operand is true.
        const expr = try Parser.parse(a, "1 = 1 or last() > 0");
        var ev = Evaluator{ .arena = a, .frame = @ptrFromInt(0x1000) };
        const r = try ev.evalExpr(expr, ctx_dummy, 1, 1);
        try testing.expect(r.boolean);
    }
}

test "Evaluator: short-circuit and/or" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ctx_dummy: *Node = @ptrFromInt(0x2000);

    inline for (.{
        .{ "1 = 2 or 1 = 1", true },
        .{ "1 = 1 and 1 = 2", false },
        .{ "1 = 1 and 2 = 2", true },
        .{ "1 = 2 and 1 = 1", false },
        .{ "1 = 2 or 2 = 1", false },
    }) |case| {
        const expr = try Parser.parse(a, case[0]);
        var ev = Evaluator{ .arena = a, .frame = @ptrFromInt(0x1000) };
        const r = try ev.evalExpr(expr, ctx_dummy, 1, 1);
        try testing.expect(r == .boolean);
        try testing.expectEqual(case[1], r.boolean);
    }
}

test "Evaluator: unary minus" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ctx_dummy: *Node = @ptrFromInt(0x2000);

    const expr = try Parser.parse(a, "-(3 + 2)");
    var ev = Evaluator{ .arena = a, .frame = @ptrFromInt(0x1000) };
    const r = try ev.evalExpr(expr, ctx_dummy, 1, 1);
    try testing.expectEqual(@as(f64, -5), r.number);
}

test "Evaluator: division by zero produces infinity / NaN per IEEE" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ctx_dummy: *Node = @ptrFromInt(0x2000);

    {
        const expr = try Parser.parse(a, "1 div 0");
        var ev = Evaluator{ .arena = a, .frame = @ptrFromInt(0x1000) };
        const r = try ev.evalExpr(expr, ctx_dummy, 1, 1);
        try testing.expect(std.math.isPositiveInf(r.number));
    }
    {
        const expr = try Parser.parse(a, "0 div 0");
        var ev = Evaluator{ .arena = a, .frame = @ptrFromInt(0x1000) };
        const r = try ev.evalExpr(expr, ctx_dummy, 1, 1);
        try testing.expect(std.math.isNan(r.number));
    }
}

test "Evaluator: searchAll on scalar expression returns empty (decision #3)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Synthetic frame/root pointers are safe here because pure-scalar
    // expressions (binop, literal, true(), comparison) never reach into
    // the Frame or the context node. Adding a DOM-touching expression
    // (e.g. `id('x')`) to this list would crash on dereference.
    inline for (.{ "1 + 2", "'hello'", "true()", "1 = 1" }) |expr| {
        const nodes = try searchAll(a, @ptrFromInt(0x1000), @ptrFromInt(0x2000), expr);
        try testing.expectEqual(@as(usize, 0), nodes.len);
    }
}
