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

//! WHATWG `XPathResult` (full surface, all 10 type constants — decision
//! #4). Wraps the evaluator's `Result.Result` for JS consumption:
//! coerces to the requested result type at construction, exposes the
//! type-tagged accessors, and serves the iterator/snapshot APIs.
//!
//! Lifetime model: each `XPathResult` owns a per-instance arena
//! (`getArena(.medium, ...)`) that holds both the struct and the result
//! data (node-set slice, formatted strings). The arena is released in
//! `deinit` once the JS wrapper's refcount hits zero.
//!
//! Type-mismatch accessor calls return `error.InvalidStateError` —
//! translated to a `DOMException` by `bridge.function(.., .{
//! .dom_exception = true })`. The WHATWG IDL technically specifies
//! `TypeError` for type mismatches, but `InvalidStateError` is what
//! decision #4 captures and what most legacy XPath consumers expect.

const std = @import("std");
const lp = @import("lightpanda");

const js = @import("../js/js.zig");
const Page = @import("../Page.zig");
const Frame = @import("../Frame.zig");

const Node = @import("Node.zig");

// XPath runtime helpers. Aliased to keep the cross-directory imports
// readable when both modules expose a `Result` type.
const xpath = struct {
    const Parser = @import("../xpath/Parser.zig");
    const Evaluator = @import("../xpath/Evaluator.zig");
    const Result = @import("../xpath/Result.zig");
};

const Allocator = std.mem.Allocator;

const XPathResult = @This();

// WHATWG type constants. ANY_TYPE is a request flag — at construction
// it resolves to one of the four concrete categories (NUMBER, STRING,
// BOOLEAN, UNORDERED_NODE_ITERATOR) depending on what the expression
// produced.
pub const ANY_TYPE: u16 = 0;
pub const NUMBER_TYPE: u16 = 1;
pub const STRING_TYPE: u16 = 2;
pub const BOOLEAN_TYPE: u16 = 3;
pub const UNORDERED_NODE_ITERATOR_TYPE: u16 = 4;
pub const ORDERED_NODE_ITERATOR_TYPE: u16 = 5;
pub const UNORDERED_NODE_SNAPSHOT_TYPE: u16 = 6;
pub const ORDERED_NODE_SNAPSHOT_TYPE: u16 = 7;
pub const ANY_UNORDERED_NODE_TYPE: u16 = 8;
pub const FIRST_ORDERED_NODE_TYPE: u16 = 9;

const Value = union(enum) {
    number: f64,
    string: []const u8,
    boolean: bool,
    nodes: []const *Node,
};

_rc: lp.RC(u8) = .{},
_arena: Allocator,
_type: u16,
_value: Value,
_iter_pos: usize = 0,

// ----- constructors -----

/// One-shot: parse + evaluate + wrap. Used by `Document.evaluate` and
/// `XPathEvaluator.evaluate`. Allocates a per-instance arena for the
/// AST + result data + the struct itself.
pub fn fromExpression(
    expression: []const u8,
    context_node: *Node,
    requested_type: u16,
    frame: *Frame,
) !*XPathResult {
    const arena = try frame.getArena(.medium, "XPathResult");
    errdefer frame.releaseArena(arena);

    // The AST borrows string slices from its input (literals, names,
    // var refs, function names). `expression` is materialized in the JS
    // call_arena and is reclaimed when the top-level call returns, so
    // dupe into our long-lived arena before parsing.
    const owned = try arena.dupe(u8, expression);
    const expr = try xpath.Parser.parse(arena, owned);
    const result = try xpath.Evaluator.evaluate(arena, frame, expr, context_node);
    return fromResult(arena, requested_type, result);
}

/// Wrap an already-evaluated `Result.Result` into an XPathResult. The
/// caller hands over ownership of `arena` — the XPathResult will release
/// it on deinit. Used by `XPathExpression.evaluate` (which has its own
/// AST cache and only allocates a fresh result arena).
pub fn fromResult(
    arena: Allocator,
    requested_type: u16,
    result: xpath.Result.Result,
) !*XPathResult {
    const value: Value = switch (requested_type) {
        ANY_TYPE => switch (result) {
            .number => |n| .{ .number = n },
            .string => |s| .{ .string = s },
            .boolean => |b| .{ .boolean = b },
            .node_set => |ns| .{ .nodes = ns },
        },
        NUMBER_TYPE => .{ .number = try xpath.Result.toNumber(arena, result) },
        STRING_TYPE => .{ .string = try xpath.Result.toString(arena, result) },
        BOOLEAN_TYPE => .{ .boolean = xpath.Result.toBoolean(result) },
        UNORDERED_NODE_ITERATOR_TYPE,
        ORDERED_NODE_ITERATOR_TYPE,
        UNORDERED_NODE_SNAPSHOT_TYPE,
        ORDERED_NODE_SNAPSHOT_TYPE,
        ANY_UNORDERED_NODE_TYPE,
        FIRST_ORDERED_NODE_TYPE,
        => switch (result) {
            .node_set => |ns| .{ .nodes = ns },
            // Requesting a node-set type for a non-node-set expression.
            // WHATWG specifies TypeError, but DOMException.fromError has
            // no TypeError mapping (would surface as a plain JS Error);
            // unify on InvalidStateError per the project plan.
            else => return error.InvalidStateError,
        },
        else => return error.InvalidStateError,
    };

    const final_type: u16 = if (requested_type == ANY_TYPE) switch (value) {
        .number => NUMBER_TYPE,
        .string => STRING_TYPE,
        .boolean => BOOLEAN_TYPE,
        .nodes => UNORDERED_NODE_ITERATOR_TYPE,
    } else requested_type;

    const xr = try arena.create(XPathResult);
    xr.* = .{
        ._arena = arena,
        ._type = final_type,
        ._value = value,
    };
    return xr;
}

// ----- lifecycle -----

pub fn deinit(self: *XPathResult, page: *Page) void {
    page.releaseArena(self._arena);
}

pub fn acquireRef(self: *XPathResult) void {
    self._rc.acquire();
}

pub fn releaseRef(self: *XPathResult, page: *Page) void {
    self._rc.release(self, page);
}

// ----- accessors -----

fn getResultType(self: *const XPathResult) u16 {
    return self._type;
}

fn getNumberValue(self: *const XPathResult) !f64 {
    if (self._type != NUMBER_TYPE) return error.InvalidStateError;
    return self._value.number;
}

fn getStringValue(self: *const XPathResult) ![]const u8 {
    if (self._type != STRING_TYPE) return error.InvalidStateError;
    return self._value.string;
}

fn getBooleanValue(self: *const XPathResult) !bool {
    if (self._type != BOOLEAN_TYPE) return error.InvalidStateError;
    return self._value.boolean;
}

fn getSingleNodeValue(self: *const XPathResult) !?*Node {
    if (self._type != ANY_UNORDERED_NODE_TYPE and self._type != FIRST_ORDERED_NODE_TYPE) {
        return error.InvalidStateError;
    }
    return if (self._value.nodes.len == 0) null else self._value.nodes[0];
}

fn getSnapshotLength(self: *const XPathResult) !u32 {
    if (self._type != UNORDERED_NODE_SNAPSHOT_TYPE and self._type != ORDERED_NODE_SNAPSHOT_TYPE) {
        return error.InvalidStateError;
    }
    return @intCast(self._value.nodes.len);
}

/// Live mutation tracking on the iterator isn't implemented — we hold a
/// frozen pointer slice, so the iterator is never "invalidated" by DOM
/// edits during traversal. Always returns false; matches the polyfill,
/// which is snapshot-only.
fn getInvalidIteratorState(_: *const XPathResult) bool {
    return false;
}

// ----- methods -----

pub fn iterateNext(self: *XPathResult) !?*Node {
    if (self._type != UNORDERED_NODE_ITERATOR_TYPE and self._type != ORDERED_NODE_ITERATOR_TYPE) {
        return error.InvalidStateError;
    }
    if (self._iter_pos >= self._value.nodes.len) return null;
    const node = self._value.nodes[self._iter_pos];
    self._iter_pos += 1;
    return node;
}

pub fn snapshotItem(self: *const XPathResult, index: u32) !?*Node {
    if (self._type != UNORDERED_NODE_SNAPSHOT_TYPE and self._type != ORDERED_NODE_SNAPSHOT_TYPE) {
        return error.InvalidStateError;
    }
    if (index >= self._value.nodes.len) return null;
    return self._value.nodes[index];
}

// ----- JS bridge -----

pub const JsApi = struct {
    pub const bridge = js.Bridge(XPathResult);

    pub const Meta = struct {
        pub const name = "XPathResult";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    // Type constants — both static (on the constructor) and instance
    // properties per the WHATWG IDL. `template = true` makes them
    // class-level so `XPathResult.ORDERED_NODE_SNAPSHOT_TYPE` works.
    pub const ANY_TYPE = bridge.property(XPathResult.ANY_TYPE, .{ .template = true });
    pub const NUMBER_TYPE = bridge.property(XPathResult.NUMBER_TYPE, .{ .template = true });
    pub const STRING_TYPE = bridge.property(XPathResult.STRING_TYPE, .{ .template = true });
    pub const BOOLEAN_TYPE = bridge.property(XPathResult.BOOLEAN_TYPE, .{ .template = true });
    pub const UNORDERED_NODE_ITERATOR_TYPE = bridge.property(XPathResult.UNORDERED_NODE_ITERATOR_TYPE, .{ .template = true });
    pub const ORDERED_NODE_ITERATOR_TYPE = bridge.property(XPathResult.ORDERED_NODE_ITERATOR_TYPE, .{ .template = true });
    pub const UNORDERED_NODE_SNAPSHOT_TYPE = bridge.property(XPathResult.UNORDERED_NODE_SNAPSHOT_TYPE, .{ .template = true });
    pub const ORDERED_NODE_SNAPSHOT_TYPE = bridge.property(XPathResult.ORDERED_NODE_SNAPSHOT_TYPE, .{ .template = true });
    pub const ANY_UNORDERED_NODE_TYPE = bridge.property(XPathResult.ANY_UNORDERED_NODE_TYPE, .{ .template = true });
    pub const FIRST_ORDERED_NODE_TYPE = bridge.property(XPathResult.FIRST_ORDERED_NODE_TYPE, .{ .template = true });

    pub const resultType = bridge.accessor(XPathResult.getResultType, null, .{});
    pub const numberValue = bridge.accessor(XPathResult.getNumberValue, null, .{ .dom_exception = true });
    pub const stringValue = bridge.accessor(XPathResult.getStringValue, null, .{ .dom_exception = true });
    pub const booleanValue = bridge.accessor(XPathResult.getBooleanValue, null, .{ .dom_exception = true });
    pub const singleNodeValue = bridge.accessor(XPathResult.getSingleNodeValue, null, .{ .dom_exception = true });
    pub const snapshotLength = bridge.accessor(XPathResult.getSnapshotLength, null, .{ .dom_exception = true });
    pub const invalidIteratorState = bridge.accessor(XPathResult.getInvalidIteratorState, null, .{});

    pub const iterateNext = bridge.function(XPathResult.iterateNext, .{ .dom_exception = true });
    pub const snapshotItem = bridge.function(XPathResult.snapshotItem, .{ .dom_exception = true });
};

const testing = @import("../../testing.zig");

test "WebApi: XPathResult" {
    try testing.htmlRunner("xpath/xpath_result.html", .{});
}

test "WebApi: XPath conformance" {
    try testing.htmlRunner("xpath/xpath_conformance.html", .{});
}
