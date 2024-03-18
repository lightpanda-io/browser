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

    pub fn isElement(_: *const Node) bool {
        return true;
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

    var matcher = Matcher.init(alloc);
    defer matcher.deinit();

    const testcases = [_]struct {
        q: []const u8,
        n: Node,
        exp: usize,
    }{
        .{
            .q = "address",
            .n = .{ .name = "body", .child = &.{ .name = "address" } },
            .exp = 1,
        },
    };

    for (testcases) |tc| {
        matcher.reset();

        const s = try css.parse(alloc, tc.q, .{});
        defer s.deinit(alloc);

        _ = try css.matchFirst(s, &tc.n, &matcher);
        try std.testing.expectEqual(tc.exp, matcher.nodes.items.len);
    }
}

test "matchAll" {
    const alloc = std.testing.allocator;

    var matcher = Matcher.init(alloc);
    defer matcher.deinit();

    const testcases = [_]struct {
        q: []const u8,
        n: Node,
        exp: usize,
    }{
        .{
            .q = "address",
            .n = .{ .name = "body", .child = &.{ .name = "address" } },
            .exp = 1,
        },
    };

    for (testcases) |tc| {
        matcher.reset();

        const s = try css.parse(alloc, tc.q, .{});
        defer s.deinit(alloc);

        _ = try css.matchAll(s, &tc.n, &matcher);
        try std.testing.expectEqual(tc.exp, matcher.nodes.items.len);
    }
}
