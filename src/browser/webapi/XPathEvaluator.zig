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

//! WHATWG `XPathEvaluator` — a stateless factory for XPath evaluation.
//! Mirrors `Document.evaluate` / `Document.createExpression` /
//! `Document.createNSResolver` so an explicit
//! `new XPathEvaluator()` instance can be used in place of the
//! document.

const std = @import("std");

const js = @import("../js/js.zig");
const Frame = @import("../Frame.zig");

const Node = @import("Node.zig");
const XPathResult = @import("XPathResult.zig");
const XPathExpression = @import("XPathExpression.zig");

const XPathEvaluator = @This();

// Padding to avoid zero-size struct identity_map collisions (matches
// the convention in ResizeObserver.zig).
_pad: bool = false,

pub fn init() XPathEvaluator {
    return .{};
}

pub fn evaluate(
    _: *const XPathEvaluator,
    expression: []const u8,
    context_node: *Node,
    resolver: ?js.Function,
    requested_type: u16,
    result: ?*XPathResult,
    frame: *Frame,
) !*XPathResult {
    // Namespace resolver is accepted-and-ignored (HTML mode — decision #2).
    // Result reuse is also a no-op; XPathResult.fromExpression always
    // allocates a fresh instance.
    _ = resolver;
    _ = result;
    return XPathResult.fromExpression(expression, context_node, requested_type, frame);
}

pub fn createExpression(
    _: *const XPathEvaluator,
    expression: []const u8,
    resolver: ?js.Function,
    frame: *Frame,
) !*XPathExpression {
    _ = resolver;
    return XPathExpression.init(expression, frame);
}

pub fn createNSResolver(_: *const XPathEvaluator, node: *Node) ?*Node {
    // HTML-mode passthrough — the WHATWG IDL accepts a Node and returns
    // an `XPathNSResolver`, but in practice the input node is reused.
    return node;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(XPathEvaluator);

    pub const Meta = struct {
        pub const name = "XPathEvaluator";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
        pub const empty_with_no_proto = true;
    };

    pub const constructor = bridge.constructor(XPathEvaluator.init, .{});
    pub const evaluate = bridge.function(XPathEvaluator.evaluate, .{ .dom_exception = true });
    pub const createExpression = bridge.function(XPathEvaluator.createExpression, .{ .dom_exception = true });
    pub const createNSResolver = bridge.function(XPathEvaluator.createNSResolver, .{});
};

const testing = @import("../../testing.zig");

test "WebApi: XPathEvaluator + XPathExpression" {
    try testing.htmlRunner("xpath/xpath_evaluator.html", .{});
}
