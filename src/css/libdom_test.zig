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

    var matcher = Matcher.init(alloc);
    defer matcher.deinit();

    const testcases = [_]struct {
        q: []const u8,
        html: []const u8,
        exp: usize,
    }{
        .{ .q = "address", .html = "<body><address>This address...</address></body>", .exp = 1 },
        .{ .q = "#foo", .html = "<p id=\"foo\"><p id=\"bar\">", .exp = 1 },
        .{ .q = ".t1", .html = "<ul><li class=\"t1\"><li class=\"t2\">", .exp = 1 },
        .{ .q = ".t3", .html = "<ul><li class=\"t1\"><li class=\"t2 t3\">", .exp = 1 },
    };

    for (testcases) |tc| {
        matcher.reset();

        const doc = try parser.documentHTMLParseFromStr(tc.html);
        defer parser.documentHTMLClose(doc) catch {};

        const s = try css.parse(alloc, tc.q, .{});
        defer s.deinit(alloc);

        const node = Node{ .node = parser.documentHTMLToNode(doc) };

        _ = try css.matchFirst(s, node, &matcher);
        try std.testing.expectEqual(tc.exp, matcher.nodes.items.len);
    }
}

test "matchAll" {
    const alloc = std.testing.allocator;

    var matcher = Matcher.init(alloc);
    defer matcher.deinit();

    const testcases = [_]struct {
        q: []const u8,
        html: []const u8,
        exp: usize,
    }{
        .{ .q = "address", .html = "<body><address>This address...</address></body>", .exp = 1 },
        .{ .q = "#foo", .html = "<p id=\"foo\"><p id=\"bar\">", .exp = 1 },
        .{ .q = ".t1", .html = "<ul><li class=\"t1\"><li class=\"t2\">", .exp = 1 },
        .{ .q = ".t3", .html = "<ul><li class=\"t1\"><li class=\"t2 t3\">", .exp = 1 },
    };

    for (testcases) |tc| {
        matcher.reset();

        const doc = try parser.documentHTMLParseFromStr(tc.html);
        defer parser.documentHTMLClose(doc) catch {};

        const s = try css.parse(alloc, tc.q, .{});
        defer s.deinit(alloc);

        const node = Node{ .node = parser.documentHTMLToNode(doc) };

        _ = try css.matchAll(s, node, &matcher);
        try std.testing.expectEqual(tc.exp, matcher.nodes.items.len);
    }
}
