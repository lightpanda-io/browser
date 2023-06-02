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
    pub const Self = parser.Node;
    pub const prototype = *EventTarget;
    pub const mem_guarantied = true;

    pub fn make_tree(self: *parser.Node) !void {
        try parser.nodeWalk(self, create_tree);
    }
};
