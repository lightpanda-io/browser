// Copyright (C) 2023-2026  Lightpanda (Selecy SAS)

// Francis Bouvier <francis@lightpanda.io>
// Pierre Tachoire <pierre@lightpanda.io>

// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as
// published by the Free Software Foundation, either version 3 of the
// License, or (at your option) any later version.

// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.

// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

// Issues stable ids for DOM nodes exposed to a client (CDP node ids, the
// agent's backendNodeIds, ...) and maintains the two-way node <-> id lookup.

const std = @import("std");

const Frame = @import("browser/Frame.zig");
const DOMNode = @import("browser/webapi/Node.zig");

const Allocator = std.mem.Allocator;

const NodeRegistry = @This();

pub const Id = u32;

pub const Node = struct {
    id: Id,
    dom: *DOMNode,
};

node_id: Id,
allocator: Allocator,
node_pool: std.heap.MemoryPool(Node),
lookup_by_id: std.AutoHashMapUnmanaged(Id, *Node),
lookup_by_node: std.HashMapUnmanaged(*DOMNode, *Node, NodeContext, std.hash_map.default_max_load_percentage),

pub fn init(allocator: Allocator) NodeRegistry {
    return .{
        .node_id = 1,
        .node_pool = .empty,
        .lookup_by_id = .{},
        .lookup_by_node = .{},
        .allocator = allocator,
    };
}

pub fn deinit(self: *NodeRegistry) void {
    const allocator = self.allocator;
    self.lookup_by_id.deinit(allocator);
    self.lookup_by_node.deinit(allocator);
    self.node_pool.deinit(allocator);
}

pub fn reset(self: *NodeRegistry) void {
    self.lookup_by_id.clearRetainingCapacity();
    self.lookup_by_node.clearRetainingCapacity();
    _ = self.node_pool.reset(self.allocator, .{ .retain_with_limit = 1024 });
}

/// Evict only the nodes owned by `frame`'s page, leaving sibling pages' node
/// IDs valid. Must run before the page's arena is freed — attribution walks
/// each node's live parent chain.
pub fn resetFrame(self: *NodeRegistry, arena: Allocator, frame: *Frame) void {
    const page = frame._page;
    var doomed: std.ArrayListUnmanaged(*Node) = .empty;
    var it = self.lookup_by_id.valueIterator();
    while (it.next()) |node_ptr| {
        const node = node_ptr.*;
        if (node.dom.ownerFrame(frame)._page == page) {
            doomed.append(arena, node) catch return;
        }
    }
    for (doomed.items) |node| {
        _ = self.lookup_by_id.remove(node.id);
        _ = self.lookup_by_node.remove(node.dom);
        self.node_pool.destroy(node);
    }
}

pub fn register(self: *NodeRegistry, dom_node: *DOMNode) !*Node {
    const node_lookup_gop = try self.lookup_by_node.getOrPut(self.allocator, dom_node);
    if (node_lookup_gop.found_existing) {
        return node_lookup_gop.value_ptr.*;
    }

    // on error, we're probably going to abort the entire browser context
    // but, just in case, let's try to keep things tidy.
    errdefer _ = self.lookup_by_node.remove(dom_node);

    const node = try self.node_pool.create(self.allocator);
    errdefer self.node_pool.destroy(node);

    const id = self.node_id;
    self.node_id = id + 1;

    node.* = .{
        .id = id,
        .dom = dom_node,
    };

    node_lookup_gop.value_ptr.* = node;
    try self.lookup_by_id.putNoClobber(self.allocator, id, node);
    return node;
}

const NodeContext = struct {
    pub fn hash(_: NodeContext, dom_node: *DOMNode) u64 {
        return std.hash.Wyhash.hash(0, std.mem.asBytes(&@intFromPtr(dom_node)));
    }

    pub fn eql(_: NodeContext, a: *DOMNode, b: *DOMNode) bool {
        return @intFromPtr(a) == @intFromPtr(b);
    }
};

const testing = @import("testing.zig");
test "NodeRegistry: register" {
    var registry = NodeRegistry.init(testing.allocator);
    defer registry.deinit();

    try testing.expectEqual(0, registry.lookup_by_id.count());
    try testing.expectEqual(0, registry.lookup_by_node.count());

    var page = try testing.pageTest("cdp/registry1.html", .{});
    defer page.close();

    const frame = page.frame().?;
    var doc = frame.window._document;

    {
        const dom_node = (try doc.querySelector(.wrap("#a1"), frame)).?.asNode();
        const node = try registry.register(dom_node);
        const n1b = registry.lookup_by_id.get(1).?;
        const n1c = registry.lookup_by_node.get(node.dom).?;
        try testing.expectEqual(node, n1b);
        try testing.expectEqual(node, n1c);

        try testing.expectEqual(1, node.id);
        try testing.expectEqual(dom_node, node.dom);
    }

    {
        const dom_node = (try doc.querySelector(.wrap("p"), frame)).?.asNode();
        const node = try registry.register(dom_node);
        const n1b = registry.lookup_by_id.get(2).?;
        const n1c = registry.lookup_by_node.get(node.dom).?;
        try testing.expectEqual(node, n1b);
        try testing.expectEqual(node, n1c);

        try testing.expectEqual(2, node.id);
        try testing.expectEqual(dom_node, node.dom);
    }
}

test "NodeRegistry: resetFrame" {
    var registry = NodeRegistry.init(testing.allocator);
    defer registry.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var page_a = try testing.pageTest("cdp/registry1.html", .{});
    defer page_a.close();
    var page_b = try testing.pageTest("cdp/registry2.html", .{});
    defer page_b.close();

    const frame_a = page_a.frame().?;
    const frame_b = page_b.frame().?;

    const a_node = (try frame_a.window._document.querySelector(.wrap("#a1"), frame_a)).?.asNode();
    const b_node = (try frame_b.window._document.querySelector(.wrap("a"), frame_b)).?.asNode();
    const ra = try registry.register(a_node);
    const rb = try registry.register(b_node);
    try testing.expectEqual(2, registry.lookup_by_id.count());

    registry.resetFrame(arena.allocator(), frame_a);

    try testing.expectEqual(null, registry.lookup_by_id.get(ra.id));
    try testing.expectEqual(null, registry.lookup_by_node.get(a_node));
    try testing.expectEqual(1, registry.lookup_by_id.count());
    try testing.expectEqual(rb, registry.lookup_by_id.get(rb.id).?);
    try testing.expectEqual(b_node, registry.lookup_by_node.get(b_node).?.dom);
}
