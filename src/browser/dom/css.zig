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
            .nl = .{},
        };
    }

    fn deinit(m: *MatchAll) void {
        m.nl.deinit(m.alloc);
    }

    pub fn match(m: *MatchAll, n: Node) !void {
        try m.nl.append(m.alloc, n.node);
    }

    fn toOwnedList(m: *MatchAll) NodeList {
        // reset it.
        defer m.nl = .{};
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
