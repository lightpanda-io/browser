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

//! XPath 1.0 runtime values.
//!
//! Mirrors the polyfill's untagged JS values (lib/capybara/lightpanda/
//! javascripts/index.js, the `evaluate()` return convention): a node-set
//! is a JS array of nodes, and the three scalar types are JS primitives.
//! In Zig we tag the union explicitly. Type coercion (`toString`,
//! `toNumber`, `toBoolean`) follows XPath 1.0 spec §3, with HTML-pragmatic
//! shortcuts inherited from the polyfill (decision #2).

const std = @import("std");

const Node = @import("../webapi/Node.zig");

const CData = Node.CData;
const Allocator = std.mem.Allocator;

pub const Result = union(enum) {
    /// Owned by the evaluator's arena. Order is significant only at the
    /// public boundary, where the evaluator sorts to document order.
    node_set: []const *Node,
    number: f64,
    string: []const u8,
    boolean: bool,
};

/// XPath spec §5: string-value of a node.
///
/// - Element / Document: concatenated text descendants (excluding
///   comments and processing-instructions; matches `Node.getTextContent`)
/// - Attribute: attribute value
/// - Text / Comment / CDATA / PI: the node's data
/// - DocumentType / DocumentFragment: empty (matches polyfill's
///   `nodeValue || textContent || ''` fallthrough)
///
/// The returned slice is borrowed from the node for cdata/attribute
/// (cheap, no allocation) and arena-allocated for element/document
/// (concatenation buffer).
pub fn stringValueOf(arena: Allocator, node: *Node) error{WriteFailed}![]const u8 {
    return switch (node._type) {
        .attribute => |attr| attr._value.str(),
        .cdata => |cd| cd._data.str(),
        .element, .document => blk: {
            var buf = std.Io.Writer.Allocating.init(arena);
            try node.getTextContent(&buf.writer);
            break :blk buf.written();
        },
        .document_type, .document_fragment => "",
    };
}

pub fn toBoolean(val: Result) bool {
    return switch (val) {
        .boolean => |b| b,
        .number => |n| n != 0 and !std.math.isNan(n),
        .string => |s| s.len > 0,
        .node_set => |ns| ns.len > 0,
    };
}

/// Numeric coercion. Empty / whitespace-only strings produce NaN
/// (XPath spec §4.4 — matches JS `Number(' ') === 0` *not* applying
/// because the polyfill calls `s.trim() === '' ? NaN : Number(s)`).
pub fn toNumber(arena: Allocator, val: Result) error{WriteFailed}!f64 {
    return switch (val) {
        .number => |n| n,
        .boolean => |b| if (b) 1 else 0,
        .string => |s| stringToNumber(s),
        .node_set => |ns| blk: {
            if (ns.len == 0) break :blk std.math.nan(f64);
            const sv = try stringValueOf(arena, ns[0]);
            break :blk stringToNumber(sv);
        },
    };
}

pub fn stringToNumber(s: []const u8) f64 {
    const trimmed = std.mem.trim(u8, s, &std.ascii.whitespace);
    if (trimmed.len == 0) return std.math.nan(f64);
    return std.fmt.parseFloat(f64, trimmed) catch std.math.nan(f64);
}

/// String coercion. Allocates only for `.number` (formatting) and for
/// `.node_set` whose first node is an Element/Document (text content
/// concatenation). Boolean → static string. String → borrowed.
pub fn toString(arena: Allocator, val: Result) error{ OutOfMemory, WriteFailed }![]const u8 {
    return switch (val) {
        .string => |s| s,
        .boolean => |b| if (b) "true" else "false",
        .number => |n| try numberToString(arena, n),
        .node_set => |ns| if (ns.len == 0) "" else try stringValueOf(arena, ns[0]),
    };
}

/// XPath spec §4.2: NaN, ±0, and ±Infinity have specific spellings;
/// integer-valued numbers print without trailing `.0`. Diverges from
/// Zig's default `{d}` which prints `nan`/`inf` and may emit `-0`.
pub fn numberToString(arena: Allocator, n: f64) error{OutOfMemory}![]const u8 {
    if (std.math.isNan(n)) return "NaN";
    if (std.math.isPositiveInf(n)) return "Infinity";
    if (std.math.isNegativeInf(n)) return "-Infinity";
    if (n == 0) return "0"; // covers +0 and -0
    if (@trunc(n) == n and n >= -9.007199254740992e15 and n <= 9.007199254740992e15) {
        return std.fmt.allocPrint(arena, "{d}", .{@as(i64, @intFromFloat(n))});
    }
    return std.fmt.allocPrint(arena, "{d}", .{n});
}

const testing = std.testing;

test "Result: toBoolean" {
    try testing.expect(toBoolean(.{ .boolean = true }));
    try testing.expect(!toBoolean(.{ .boolean = false }));
    try testing.expect(toBoolean(.{ .number = 1 }));
    try testing.expect(!toBoolean(.{ .number = 0 }));
    try testing.expect(!toBoolean(.{ .number = std.math.nan(f64) }));
    try testing.expect(toBoolean(.{ .string = "x" }));
    try testing.expect(!toBoolean(.{ .string = "" }));
    try testing.expect(!toBoolean(.{ .node_set = &.{} }));
}

test "Result: stringToNumber" {
    try testing.expectEqual(@as(f64, 42), stringToNumber("42"));
    try testing.expectEqual(@as(f64, 3.14), stringToNumber("3.14"));
    try testing.expectEqual(@as(f64, -1), stringToNumber("-1"));
    try testing.expectEqual(@as(f64, 5), stringToNumber("  5  "));
    try testing.expect(std.math.isNan(stringToNumber("")));
    try testing.expect(std.math.isNan(stringToNumber("   ")));
    try testing.expect(std.math.isNan(stringToNumber("abc")));
}

test "Result: numberToString — integers print without decimal" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("5", try numberToString(a, 5));
    try testing.expectEqualStrings("0", try numberToString(a, 0));
    try testing.expectEqualStrings("0", try numberToString(a, -0.0));
    try testing.expectEqualStrings("-1", try numberToString(a, -1));
    try testing.expectEqualStrings("42", try numberToString(a, 42.0));
}

test "Result: numberToString — special values" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("NaN", try numberToString(a, std.math.nan(f64)));
    try testing.expectEqualStrings("Infinity", try numberToString(a, std.math.inf(f64)));
    try testing.expectEqualStrings("-Infinity", try numberToString(a, -std.math.inf(f64)));
}

test "Result: numberToString — floats" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("3.14", try numberToString(a, 3.14));
    try testing.expectEqualStrings("0.5", try numberToString(a, 0.5));
}

test "Result: toString — boolean returns static string" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("true", try toString(arena.allocator(), .{ .boolean = true }));
    try testing.expectEqualStrings("false", try toString(arena.allocator(), .{ .boolean = false }));
}

test "Result: toString — node-set with empty arr is empty" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("", try toString(arena.allocator(), .{ .node_set = &.{} }));
}

test "Result: toNumber — empty node-set is NaN" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expect(std.math.isNan(try toNumber(arena.allocator(), .{ .node_set = &.{} })));
}

test "Result: toNumber — boolean coerces to 0/1" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqual(@as(f64, 1), try toNumber(arena.allocator(), .{ .boolean = true }));
    try testing.expectEqual(@as(f64, 0), try toNumber(arena.allocator(), .{ .boolean = false }));
}
