const std = @import("std");
const css = @import("css.zig");
const Node = @import("libdom.zig").Node;
const parser = @import("../netsurf.zig");

const Matcher = struct {
    const Nodes = std.ArrayList(Node);

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

    pub fn match(m: *Matcher, n: Node) !void {
        try m.nodes.append(n);
    }
};

test "matchFirst" {
    const alloc = std.testing.allocator;

    const s = try css.parse(alloc, "address", .{});
    defer s.deinit(alloc);

    var matcher = Matcher.init(alloc);
    defer matcher.deinit();

    const doc = try parser.documentHTMLParseFromStr("<body><address>This address...</address></body>");
    defer parser.documentHTMLClose(doc) catch {};

    const node = Node{ .node = parser.documentHTMLToNode(doc) };

    _ = try css.matchFirst(s, node, &matcher);
    try std.testing.expect(1 == matcher.nodes.items.len);
}
