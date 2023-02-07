const std = @import("std");

const parser = @import("../parser.zig");

const EventTarget = @import("event_target.zig").EventTarget;

pub fn create_tree(node: ?*parser.Node, _: ?*anyopaque) callconv(.C) parser.Action {
    if (node == null) {
        return parser.ActionStop;
    }
    const node_type = parser.nodeType(node.?);
    const node_name = parser.nodeName(node.?);
    std.debug.print("type: {any}, name: {s}\n", .{ node_type, node_name });
    if (node_type == parser.NodeType.element) {
        std.debug.print("yes\n", .{});
    }
    return parser.ActionOk;
}

pub const Node = struct {
    proto: EventTarget,
    base: ?*parser.Node = null,

    pub const prototype = *EventTarget;

    pub fn init(base: ?*parser.Node) Node {
        return .{ .proto = EventTarget.init(null), .base = base };
    }

    pub fn make_tree(self: Node) !void {
        if (self.base) |node| {
            try parser.nodeWalk(node, create_tree);
        }
        return error.NodeParserNull;
    }
};
