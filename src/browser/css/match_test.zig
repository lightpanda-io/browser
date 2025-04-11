// Copyright (C) 2023-2024  Lightpanda (Selecy SAS)
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

const std = @import("std");
const css = @import("css.zig");

// Node mock implementation for test only.
pub const Node = struct {
    child: ?*const Node = null,
    last: ?*const Node = null,
    sibling: ?*const Node = null,
    prev: ?*const Node = null,
    par: ?*const Node = null,

    name: []const u8 = "",
    att: ?[]const u8 = null,

    pub fn firstChild(n: *const Node) !?*const Node {
        return n.child;
    }

    pub fn lastChild(n: *const Node) !?*const Node {
        return n.last;
    }

    pub fn nextSibling(n: *const Node) !?*const Node {
        return n.sibling;
    }

    pub fn prevSibling(n: *const Node) !?*const Node {
        return n.prev;
    }

    pub fn parent(n: *const Node) !?*const Node {
        return n.par;
    }

    pub fn isElement(_: *const Node) bool {
        return true;
    }

    pub fn isDocument(_: *const Node) bool {
        return false;
    }

    pub fn isComment(_: *const Node) bool {
        return false;
    }

    pub fn isText(_: *const Node) bool {
        return false;
    }

    pub fn isEmptyText(_: *const Node) !bool {
        return false;
    }

    pub fn tag(n: *const Node) ![]const u8 {
        return n.name;
    }

    pub fn attr(n: *const Node, _: []const u8) !?[]const u8 {
        return n.att;
    }

    pub fn eql(a: *const Node, b: *const Node) bool {
        return a == b;
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
        .{
            .q = ":not(p)",
            .n = .{ .child = &.{ .name = "p", .child = &.{ .name = "a" }, .sibling = &.{ .name = "strong" } } },
            .exp = 1,
        },
        .{
            .q = "p:has(a)",
            .n = .{ .child = &.{ .name = "p", .child = &.{ .name = "a" }, .sibling = &.{ .name = "strong" } } },
            .exp = 1,
        },
        .{
            .q = "p:has(strong)",
            .n = .{ .child = &.{ .name = "p", .child = &.{ .name = "a" }, .sibling = &.{ .name = "strong" } } },
            .exp = 0,
        },
        .{
            .q = "p:haschild(a)",
            .n = .{ .child = &.{ .name = "p", .child = &.{ .name = "a" }, .sibling = &.{ .name = "strong" } } },
            .exp = 1,
        },
        .{
            .q = "p:haschild(strong)",
            .n = .{ .child = &.{ .name = "p", .child = &.{ .name = "a" }, .sibling = &.{ .name = "strong" } } },
            .exp = 0,
        },
        .{
            .q = "p:lang(en)",
            .n = .{ .child = &.{ .name = "p", .att = "en-US", .child = &.{ .name = "a" } } },
            .exp = 1,
        },
        .{
            .q = "a:lang(en)",
            .n = .{ .child = &.{ .name = "p", .child = &.{ .name = "a", .par = &.{ .att = "en-US" } } } },
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
        .{
            .q = ":not(p)",
            .n = .{ .child = &.{ .name = "p", .child = &.{ .name = "a" }, .sibling = &.{ .name = "strong" } } },
            .exp = 2,
        },
        .{
            .q = "p:has(a)",
            .n = .{ .child = &.{ .name = "p", .child = &.{ .name = "a" }, .sibling = &.{ .name = "strong" } } },
            .exp = 1,
        },
        .{
            .q = "p:has(strong)",
            .n = .{ .child = &.{ .name = "p", .child = &.{ .name = "a" }, .sibling = &.{ .name = "strong" } } },
            .exp = 0,
        },
        .{
            .q = "p:haschild(a)",
            .n = .{ .child = &.{ .name = "p", .child = &.{ .name = "a" }, .sibling = &.{ .name = "strong" } } },
            .exp = 1,
        },
        .{
            .q = "p:haschild(strong)",
            .n = .{ .child = &.{ .name = "p", .child = &.{ .name = "a" }, .sibling = &.{ .name = "strong" } } },
            .exp = 0,
        },
        .{
            .q = "p:lang(en)",
            .n = .{ .child = &.{ .name = "p", .att = "en-US", .child = &.{ .name = "a" } } },
            .exp = 1,
        },
        .{
            .q = "a:lang(en)",
            .n = .{ .child = &.{ .name = "p", .child = &.{ .name = "a", .par = &.{ .att = "en-US" } } } },
            .exp = 1,
        },
    };

    for (testcases) |tc| {
        matcher.reset();

        const s = try css.parse(alloc, tc.q, .{});
        defer s.deinit(alloc);

        css.matchAll(s, &tc.n, &matcher) catch |e| {
            std.debug.print("query: {s}, parsed selector: {any}\n", .{ tc.q, s });
            return e;
        };

        std.testing.expectEqual(tc.exp, matcher.nodes.items.len) catch |e| {
            std.debug.print("query: {s}, parsed selector: {any}\n", .{ tc.q, s });
            return e;
        };
    }
}

test "pseudo class" {
    const alloc = std.testing.allocator;

    var matcher = Matcher.init(alloc);
    defer matcher.deinit();

    var p1: Node = .{ .name = "p" };
    var p2: Node = .{ .name = "p" };
    var a1: Node = .{ .name = "a" };

    p1.sibling = &p2;
    p2.prev = &p1;

    p2.sibling = &a1;
    a1.prev = &p2;

    var root: Node = .{ .child = &p1, .last = &a1 };
    p1.par = &root;
    p2.par = &root;
    a1.par = &root;

    const testcases = [_]struct {
        q: []const u8,
        n: Node,
        exp: ?*const Node,
    }{
        .{ .q = "p:only-child", .n = root, .exp = null },
        .{ .q = "a:only-of-type", .n = root, .exp = &a1 },
    };

    for (testcases) |tc| {
        matcher.reset();

        const s = try css.parse(alloc, tc.q, .{});
        defer s.deinit(alloc);

        css.matchAll(s, &tc.n, &matcher) catch |e| {
            std.debug.print("query: {s}, parsed selector: {any}\n", .{ tc.q, s });
            return e;
        };

        if (tc.exp) |exp_n| {
            const exp: usize = 1;
            std.testing.expectEqual(exp, matcher.nodes.items.len) catch |e| {
                std.debug.print("query: {s}, parsed selector: {any}\n", .{ tc.q, s });
                return e;
            };

            std.testing.expectEqual(exp_n, matcher.nodes.items[0]) catch |e| {
                std.debug.print("query: {s}, parsed selector: {any}\n", .{ tc.q, s });
                return e;
            };

            continue;
        }

        const exp: usize = 0;
        std.testing.expectEqual(exp, matcher.nodes.items.len) catch |e| {
            std.debug.print("query: {s}, parsed selector: {any}\n", .{ tc.q, s });
            return e;
        };
    }
}

test "nth pseudo class" {
    const alloc = std.testing.allocator;

    var matcher = Matcher.init(alloc);
    defer matcher.deinit();

    var p1: Node = .{ .name = "p" };
    var p2: Node = .{ .name = "p" };

    p1.sibling = &p2;
    p2.prev = &p1;

    var root: Node = .{ .child = &p1, .last = &p2 };
    p1.par = &root;
    p2.par = &root;

    const testcases = [_]struct {
        q: []const u8,
        n: Node,
        exp: ?*const Node,
    }{
        .{ .q = "a:nth-of-type(1)", .n = root, .exp = null },
        .{ .q = "p:nth-of-type(1)", .n = root, .exp = &p1 },
        .{ .q = "p:nth-of-type(2)", .n = root, .exp = &p2 },
        .{ .q = "p:nth-of-type(0)", .n = root, .exp = null },
        .{ .q = "p:nth-of-type(2n)", .n = root, .exp = &p2 },
        .{ .q = "p:nth-last-child(1)", .n = root, .exp = &p2 },
        .{ .q = "p:nth-last-child(2)", .n = root, .exp = &p1 },
        .{ .q = "p:nth-child(1)", .n = root, .exp = &p1 },
        .{ .q = "p:nth-child(2)", .n = root, .exp = &p2 },
        .{ .q = "p:nth-child(odd)", .n = root, .exp = &p1 },
        .{ .q = "p:nth-child(even)", .n = root, .exp = &p2 },
        .{ .q = "p:nth-child(n+2)", .n = root, .exp = &p2 },
    };

    for (testcases) |tc| {
        matcher.reset();

        const s = try css.parse(alloc, tc.q, .{});
        defer s.deinit(alloc);

        css.matchAll(s, &tc.n, &matcher) catch |e| {
            std.debug.print("query: {s}, parsed selector: {any}\n", .{ tc.q, s });
            return e;
        };

        if (tc.exp) |exp_n| {
            const exp: usize = 1;
            std.testing.expectEqual(exp, matcher.nodes.items.len) catch |e| {
                std.debug.print("query: {s}, parsed selector: {any}\n", .{ tc.q, s });
                return e;
            };

            std.testing.expectEqual(exp_n, matcher.nodes.items[0]) catch |e| {
                std.debug.print("query: {s}, parsed selector: {any}\n", .{ tc.q, s });
                return e;
            };

            continue;
        }

        const exp: usize = 0;
        std.testing.expectEqual(exp, matcher.nodes.items.len) catch |e| {
            std.debug.print("query: {s}, parsed selector: {any}\n", .{ tc.q, s });
            return e;
        };
    }
}
