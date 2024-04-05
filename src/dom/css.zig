const std = @import("std");

const parser = @import("../netsurf.zig");

const css = @import("../css/css.zig");
const Node = @import("../css/libdom.zig").Node;
const NodeList = @import("nodelist.zig").NodeList;

const MatchFirst = struct {
    n: ?*parser.Node = null,

    pub fn match(m: *MatchFirst, n: Node) !void {
        m.n = n.node;
    }
};

pub fn querySelector(alloc: std.mem.Allocator, n: *parser.Node, selector: []const u8) !?*parser.Node {
    const ps = try css.parse(alloc, selector, .{ .accept_pseudo_elts = true });
    defer ps.deinit(alloc);

    var m = MatchFirst{};

    _ = try css.matchFirst(ps, Node{ .node = n }, &m);
    return m.n;
}

const MatchAll = struct {
    alloc: std.mem.Allocator,
    nl: NodeList,

    fn init(alloc: std.mem.Allocator) MatchAll {
        return .{
            .alloc = alloc,
            .nl = NodeList.init(),
        };
    }

    fn deinit(m: *MatchAll) void {
        m.nl.deinit(m.alloc);
    }

    pub fn match(m: *MatchAll, n: Node) !void {
        try m.nl.append(m.alloc, n.node);
    }

    fn toOwnedList(m: *MatchAll) NodeList {
        defer m.nl = NodeList.init();
        return m.nl;
    }
};

pub fn querySelectorAll(alloc: std.mem.Allocator, n: *parser.Node, selector: []const u8) !NodeList {
    const ps = try css.parse(alloc, selector, .{ .accept_pseudo_elts = true });
    defer ps.deinit(alloc);

    var m = MatchAll.init(alloc);
    defer m.deinit();

    try css.matchAll(ps, Node{ .node = n }, &m);
    return m.toOwnedList();
}
