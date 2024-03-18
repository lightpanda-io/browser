const std = @import("std");
const css = @import("css.zig");

// Node mock implementation for test only.
pub const Node = struct {
    child: ?*const Node = null,
    sibling: ?*const Node = null,

    name: []const u8 = "",

    pub fn firstChild(n: *const Node) !?*const Node {
        return n.child;
    }

    pub fn nextSibling(n: *const Node) !?*const Node {
        return n.sibling;
    }

    pub fn tag(n: *const Node) ![]const u8 {
        return n.name;
    }
};

const Matcher = struct {
    const Nodes = std.ArrayList(*const Node);

    nodes: Nodes,

    fn init(alloc: std.mem.Allocator) Matcher {
        return .{ .nodes = Nodes.init(alloc) };
    }

    fn deinit(m: *Matcher) void {
        m.nodes.deinit();
    }

    fn reset(m: *Matcher) void {
        m.nodes.clearRetainingCapacity();
    }

    pub fn match(m: *Matcher, n: *const Node) !void {
        try m.nodes.append(n);
    }
};

test "matchFirst" {
    const alloc = std.testing.allocator;

    const s = try css.parse(alloc, "address", .{});
    defer s.deinit(alloc);

    var matcher = Matcher.init(alloc);
    defer matcher.deinit();

    const node: Node = .{
        .child = &.{ .name = "address" },
    };

    _ = try css.matchFirst(s, &node, &matcher);
    try std.testing.expect(1 == matcher.nodes.items.len);
    try std.testing.expect(matcher.nodes.items[0] == node.child);
}
