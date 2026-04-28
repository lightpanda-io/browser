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

//! WHATWG `XPathExpression` — a parsed XPath expression cached for
//! repeated evaluation. The parsed AST lives in this object's per-
//! instance arena (long-lived); each `evaluate()` call gets a fresh
//! arena for its own result data so multiple evaluations don't grow
//! the AST arena.

const std = @import("std");
const lp = @import("lightpanda");

const js = @import("../js/js.zig");
const Page = @import("../Page.zig");
const Frame = @import("../Frame.zig");

const Node = @import("Node.zig");
const XPathResult = @import("XPathResult.zig");

const xpath = struct {
    const Ast = @import("../xpath/Ast.zig");
    const Parser = @import("../xpath/Parser.zig");
    const Evaluator = @import("../xpath/Evaluator.zig");
};

const Allocator = std.mem.Allocator;

const XPathExpression = @This();

_rc: lp.RC(u8) = .{},
_arena: Allocator,
_expr: *const xpath.Ast.Expr,

pub fn init(expression: []const u8, frame: *Frame) !*XPathExpression {
    const arena = try frame.getArena(.tiny, "XPathExpression");
    errdefer frame.releaseArena(arena);

    const expr = try xpath.Parser.parse(arena, expression);
    const xe = try arena.create(XPathExpression);
    xe.* = .{ ._arena = arena, ._expr = expr };
    return xe;
}

pub fn evaluate(
    self: *XPathExpression,
    context_node: *Node,
    requested_type: u16,
    result: ?*XPathResult,
    frame: *Frame,
) !*XPathResult {
    // The `result` reuse parameter (WHATWG: optional XPathResult to
    // populate) is accepted-and-ignored: we always allocate fresh,
    // which matches every modern browser's effective behavior.
    _ = result;

    const arena = try frame.getArena(.medium, "XPathResult");
    errdefer frame.releaseArena(arena);

    const eval_result = try xpath.Evaluator.evaluate(arena, frame, self._expr, context_node);
    return XPathResult.fromResult(arena, requested_type, eval_result);
}

pub fn deinit(self: *XPathExpression, page: *Page) void {
    page.releaseArena(self._arena);
}

pub fn acquireRef(self: *XPathExpression) void {
    self._rc.acquire();
}

pub fn releaseRef(self: *XPathExpression, page: *Page) void {
    self._rc.release(self, page);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(XPathExpression);

    pub const Meta = struct {
        pub const name = "XPathExpression";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const evaluate = bridge.function(XPathExpression.evaluate, .{ .dom_exception = true });
};
