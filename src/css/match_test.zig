const std = @import("std");
const css = @import("css.zig");

// Node mock implementation for test only.
pub const Node = struct {
    child: ?*const Node = null,
    sibling: ?*const Node = null,
    par: ?*const Node = null,

    name: []const u8 = "",
    att: ?[]const u8 = null,

    pub fn firstChild(n: *const Node) !?*const Node {
        return n.child;
    }

    pub fn nextSibling(n: *const Node) !?*const Node {
        return n.sibling;
    }

    pub fn parent(n: *const Node) !?*const Node {
        return n.par;
    }

    pub fn isElement(_: *const Node) bool {
        return true;
    }

    pub fn tag(n: *const Node) ![]const u8 {
        return n.name;
    }

    pub fn attr(n: *const Node, _: []const u8) !?[]const u8 {
        return n.att;
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
            .n = .{ .child = &.{ .name = "body", .child = &.{ .name = "address" } } },
            .exp = 1,
        },
        .{
            .q = "#foo",
            .n = .{ .child = &.{ .name = "p", .att = "foo", .child = &.{ .name = "p" } } },
            .exp = 1,
        },
        .{
            .q = ".t1",
            .n = .{ .child = &.{ .name = "p", .sibling = &.{ .name = "p", .att = "t1" } } },
            .exp = 1,
        },
        .{
            .q = ".t1",
            .n = .{ .child = &.{ .name = "p", .sibling = &.{ .name = "p", .att = "foo t1" } } },
            .exp = 1,
        },
        .{
            .q = "[foo]",
            .n = .{ .child = &.{ .name = "p", .sibling = &.{ .name = "p" } } },
            .exp = 0,
        },
        .{
            .q = "[foo]",
            .n = .{ .child = &.{ .name = "p", .sibling = &.{ .name = "p", .att = "bar" } } },
            .exp = 1,
        },
        .{
            .q = "[foo=bar]",
            .n = .{ .child = &.{ .name = "p", .sibling = &.{ .name = "p", .att = "bar" } } },
            .exp = 1,
        },
        .{
            .q = "[foo=baz]",
            .n = .{ .child = &.{ .name = "p", .sibling = &.{ .name = "p", .att = "bar" } } },
            .exp = 0,
        },
        .{
            .q = "[foo!=bar]",
            .n = .{ .child = &.{ .name = "p", .sibling = &.{ .name = "p", .att = "bar" } } },
            .exp = 1,
        },
        .{
            .q = "[foo!=baz]",
            .n = .{ .child = &.{ .name = "p", .sibling = &.{ .name = "p", .att = "bar" } } },
            .exp = 1,
        },
        .{
            .q = "[foo~=bar]",
            .n = .{ .child = &.{ .name = "p", .sibling = &.{ .name = "p", .att = "baz bar" } } },
            .exp = 1,
        },
        .{
            .q = "[foo~=bar]",
            .n = .{ .child = &.{ .name = "p", .sibling = &.{ .name = "p", .att = "barbaz" } } },
            .exp = 0,
        },
        .{
            .q = "[foo^=bar]",
            .n = .{ .child = &.{ .name = "p", .sibling = &.{ .name = "p", .att = "barbaz" } } },
            .exp = 1,
        },
        .{
            .q = "[foo$=baz]",
            .n = .{ .child = &.{ .name = "p", .sibling = &.{ .name = "p", .att = "barbaz" } } },
            .exp = 1,
        },
        .{
            .q = "[foo*=rb]",
            .n = .{ .child = &.{ .name = "p", .sibling = &.{ .name = "p", .att = "barbaz" } } },
            .exp = 1,
        },
        .{
            .q = "[foo|=bar]",
            .n = .{ .child = &.{ .name = "p", .sibling = &.{ .name = "p", .att = "bar" } } },
            .exp = 1,
        },
        .{
            .q = "[foo|=bar]",
            .n = .{ .child = &.{ .name = "p", .sibling = &.{ .name = "p", .att = "bar-baz" } } },
            .exp = 1,
        },
        .{
            .q = "[foo|=bar]",
            .n = .{ .child = &.{ .name = "p", .sibling = &.{ .name = "p", .att = "ba" } } },
            .exp = 0,
        },
        .{
            .q = "strong, a",
            .n = .{ .child = &.{ .name = "p", .child = &.{ .name = "a" }, .sibling = &.{ .name = "strong" } } },
            .exp = 1,
        },
        .{
            .q = "p a",
            .n = .{ .child = &.{ .name = "p", .child = &.{ .name = "a", .par = &.{ .name = "p" } }, .sibling = &.{ .name = "a" } } },
            .exp = 1,
        },
        .{
            .q = "p a",
            .n = .{ .child = &.{ .name = "p", .child = &.{ .name = "span", .child = &.{
                .name = "a",
                .par = &.{ .name = "span", .par = &.{ .name = "p" } },
            } } } },
            .exp = 1,
        },
    };

    for (testcases) |tc| {
        matcher.reset();

        const s = try css.parse(alloc, tc.q, .{});
        defer s.deinit(alloc);

        _ = css.matchFirst(s, &tc.n, &matcher) catch |e| {
            std.debug.print("query: {s}, parsed selector: {any}\n", .{ tc.q, s });
            return e;
        };

        std.testing.expectEqual(tc.exp, matcher.nodes.items.len) catch |e| {
            std.debug.print("query: {s}, parsed selector: {any}\n", .{ tc.q, s });
            return e;
        };
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
            .n = .{ .child = &.{ .name = "body", .child = &.{ .name = "address" } } },
            .exp = 1,
        },
        .{
            .q = "#foo",
            .n = .{ .child = &.{ .name = "p", .att = "foo", .child = &.{ .name = "p" } } },
            .exp = 1,
        },
        .{
            .q = ".t1",
            .n = .{ .child = &.{ .name = "p", .sibling = &.{ .name = "p", .att = "t1" } } },
            .exp = 1,
        },
        .{
            .q = ".t1",
            .n = .{ .child = &.{ .name = "p", .sibling = &.{ .name = "p", .att = "foo t1" } } },
            .exp = 1,
        },
        .{
            .q = "[foo]",
            .n = .{ .child = &.{ .name = "p", .sibling = &.{ .name = "p" } } },
            .exp = 0,
        },
        .{
            .q = "[foo]",
            .n = .{ .child = &.{ .name = "p", .sibling = &.{ .name = "p", .att = "bar" } } },
            .exp = 1,
        },
        .{
            .q = "[foo=bar]",
            .n = .{ .child = &.{ .name = "p", .sibling = &.{ .name = "p", .att = "bar" } } },
            .exp = 1,
        },
        .{
            .q = "[foo=baz]",
            .n = .{ .child = &.{ .name = "p", .sibling = &.{ .name = "p", .att = "bar" } } },
            .exp = 0,
        },
        .{
            .q = "[foo!=bar]",
            .n = .{ .child = &.{ .name = "p", .sibling = &.{ .name = "p", .att = "bar" } } },
            .exp = 1,
        },
        .{
            .q = "[foo!=baz]",
            .n = .{ .child = &.{ .name = "p", .sibling = &.{ .name = "p", .att = "bar" } } },
            .exp = 2,
        },
        .{
            .q = "[foo~=bar]",
            .n = .{ .child = &.{ .name = "p", .sibling = &.{ .name = "p", .att = "baz bar" } } },
            .exp = 1,
        },
        .{
            .q = "[foo~=bar]",
            .n = .{ .child = &.{ .name = "p", .sibling = &.{ .name = "p", .att = "barbaz" } } },
            .exp = 0,
        },
        .{
            .q = "[foo^=bar]",
            .n = .{ .child = &.{ .name = "p", .sibling = &.{ .name = "p", .att = "barbaz" } } },
            .exp = 1,
        },
        .{
            .q = "[foo$=baz]",
            .n = .{ .child = &.{ .name = "p", .sibling = &.{ .name = "p", .att = "barbaz" } } },
            .exp = 1,
        },
        .{
            .q = "[foo*=rb]",
            .n = .{ .child = &.{ .name = "p", .sibling = &.{ .name = "p", .att = "barbaz" } } },
            .exp = 1,
        },
        .{
            .q = "[foo|=bar]",
            .n = .{ .child = &.{ .name = "p", .sibling = &.{ .name = "p", .att = "bar" } } },
            .exp = 1,
        },
        .{
            .q = "[foo|=bar]",
            .n = .{ .child = &.{ .name = "p", .sibling = &.{ .name = "p", .att = "bar-baz" } } },
            .exp = 1,
        },
        .{
            .q = "[foo|=bar]",
            .n = .{ .child = &.{ .name = "p", .sibling = &.{ .name = "p", .att = "ba" } } },
            .exp = 0,
        },
        .{
            .q = "strong, a",
            .n = .{ .child = &.{ .name = "p", .child = &.{ .name = "a" }, .sibling = &.{ .name = "strong" } } },
            .exp = 2,
        },
        .{
            .q = "p a",
            .n = .{ .child = &.{ .name = "p", .child = &.{ .name = "a", .par = &.{ .name = "p" } }, .sibling = &.{ .name = "a" } } },
            .exp = 1,
        },
        .{
            .q = "p a",
            .n = .{ .child = &.{ .name = "p", .child = &.{ .name = "span", .child = &.{
                .name = "a",
                .par = &.{ .name = "span", .par = &.{ .name = "p" } },
            } } } },
            .exp = 1,
        },
    };

    for (testcases) |tc| {
        matcher.reset();

        const s = try css.parse(alloc, tc.q, .{});
        defer s.deinit(alloc);

        _ = css.matchAll(s, &tc.n, &matcher) catch |e| {
            std.debug.print("query: {s}, parsed selector: {any}\n", .{ tc.q, s });
            return e;
        };

        std.testing.expectEqual(tc.exp, matcher.nodes.items.len) catch |e| {
            std.debug.print("query: {s}, parsed selector: {any}\n", .{ tc.q, s });
            return e;
        };
    }
}
