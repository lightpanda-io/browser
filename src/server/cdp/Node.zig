// Copyright (C) 2023-2025  Lightpanda (Selecy SAS)

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

// The CDP-specific views over the NodeRegistry: DOM.performSearch state and
// the DOM.Node wire-format serializer.

const std = @import("std");
const lp = @import("lightpanda");

const Frame = @import("../../browser/Frame.zig");
const DOMNode = @import("../../browser/webapi/Node.zig");
const NodeRegistry = @import("../../NodeRegistry.zig");

const log = lp.log;
const Allocator = std.mem.Allocator;

// Searches are a 3 step process:
// 1 - Dom.performSearch
// 2 - Dom.getSearchResults
// 3 - Dom.discardSearchResults
//
// For a given browser context, we can have multiple active searches. I.e.
// performSearch could be called multiple times without getSearchResults or
// discardSearchResults being called. We keep these active searches in the
// browser context's node_search_list, which is a SearchList. Since we don't
// expect many active searches (mostly just 1), a list is fine to scan through.
pub const Search = struct {
    name: []const u8,
    node_ids: []const NodeRegistry.Id,

    pub const List = struct {
        search_id: u16 = 0,
        registry: *NodeRegistry,
        arena: std.heap.ArenaAllocator,
        searches: std.ArrayList(Search) = .empty,

        pub fn init(allocator: Allocator, registry: *NodeRegistry) List {
            return .{
                .registry = registry,
                .arena = std.heap.ArenaAllocator.init(allocator),
            };
        }

        pub fn deinit(self: *List) void {
            self.arena.deinit();
        }

        pub fn reset(self: *List) void {
            self.search_id = 0;
            self.searches = .empty;
            _ = self.arena.reset(.{ .retain_with_limit = 4096 });
        }

        pub fn create(self: *List, nodes: []const *DOMNode) !Search {
            const id = self.search_id;
            defer self.search_id = id +% 1;

            const arena = self.arena.allocator();

            const name = switch (id) {
                0 => "0",
                1 => "1",
                2 => "2",
                3 => "3",
                4 => "4",
                5 => "5",
                6 => "6",
                7 => "7",
                8 => "8",
                9 => "9",
                else => try std.fmt.allocPrint(arena, "{d}", .{id}),
            };

            var registry = self.registry;
            const node_ids = try arena.alloc(NodeRegistry.Id, nodes.len);
            for (nodes, node_ids) |node, *node_id| {
                node_id.* = (try registry.register(node)).id;
            }

            const search = Search{
                .name = name,
                .node_ids = node_ids,
            };
            try self.searches.append(arena, search);
            return search;
        }

        pub fn remove(self: *List, name: []const u8) void {
            for (self.searches.items, 0..) |search, i| {
                if (std.mem.eql(u8, name, search.name)) {
                    _ = self.searches.swapRemove(i);
                    return;
                }
            }
        }

        pub fn get(self: *const List, name: []const u8) ?Search {
            for (self.searches.items) |search| {
                if (std.mem.eql(u8, name, search.name)) {
                    return search;
                }
            }
            return null;
        }
    };
};

// Need a custom writer, because we can't just serialize the node as-is.
// Sometimes we want to serialize the node without children, sometimes with just
// its direct children, and sometimes the entire tree.
// (For now, we only support direct children)

pub const Writer = struct {
    depth: i32,
    exclude_root: bool,
    root: *const NodeRegistry.Node,
    registry: *NodeRegistry,

    pub const Opts = struct {
        depth: i32 = 0,
        exclude_root: bool = false,
    };

    pub fn jsonStringify(self: *const Writer, w: anytype) error{WriteFailed}!void {
        if (self.exclude_root) {
            _ = self.writeChildren(self.root, 1, w) catch |err| {
                log.err(.cdp, "node writeChildren", .{ .err = err });
                return error.WriteFailed;
            };
        } else {
            self.toJSON(self.root, 0, w) catch |err| {
                // The only error our jsonStringify method can return is
                // @TypeOf(w).Error. In other words, our code can't return its own
                // error, we can only return a writer error. Kinda sucks.
                log.err(.cdp, "node toJSON stringify", .{ .err = err });
                return error.WriteFailed;
            };
        }
    }

    fn toJSON(self: *const Writer, node: *const NodeRegistry.Node, depth: usize, w: anytype) !void {
        try w.beginObject();
        try self.writeCommon(node, false, w);

        try w.objectField("children");
        const child_count = try self.writeChildren(node, depth, w);
        try w.objectField("childNodeCount");
        try w.write(child_count);

        try w.endObject();
    }

    fn writeChildren(self: *const Writer, node: *const NodeRegistry.Node, depth: usize, w: anytype) anyerror!usize {
        var count: usize = 0;
        var it = node.dom.childrenIterator();

        var registry = self.registry;
        const full_child = self.depth < 0 or self.depth < depth;

        try w.beginArray();
        while (it.next()) |dom_child| {
            const child_node = try registry.register(dom_child);
            if (full_child) {
                try self.toJSON(child_node, depth + 1, w);
            } else {
                try w.beginObject();
                try self.writeCommon(child_node, true, w);
                try w.endObject();
            }
            count += 1;
        }
        try w.endArray();

        return count;
    }

    fn writeCommon(self: *const Writer, node: *const NodeRegistry.Node, include_child_count: bool, w: anytype) !void {
        try w.objectField("nodeId");
        try w.write(node.id);

        try w.objectField("backendNodeId");
        try w.write(node.id);

        const dom_node = node.dom;

        if (dom_node._parent) |dom_parent| {
            const parent_node = try self.registry.register(dom_parent);
            try w.objectField("parentId");
            try w.write(parent_node.id);
        }

        if (dom_node.is(DOMNode.Element)) |element| {
            if (element.hasAttributes()) {
                try w.objectField("attributes");
                try w.beginArray();
                for (element.attributeEntries()) |*attr| {
                    try w.write(attr.name());
                    try w.write(attr.value());
                }
                try w.endArray();
            }

            try w.objectField("localName");
            try w.write(element.getLocalName());
        } else {
            try w.objectField("localName");
            try w.write("");
        }

        try w.objectField("nodeType");
        try w.write(dom_node.getNodeType());

        try w.objectField("nodeName");
        var name_buf: [Frame.BUF_SIZE]u8 = undefined;
        try w.write(dom_node.getNodeName(&name_buf));

        try w.objectField("nodeValue");
        if (dom_node.getNodeValue()) |nv| {
            try w.write(nv.str());
        } else {
            try w.write("");
        }

        if (include_child_count) {
            try w.objectField("childNodeCount");
            try w.write(dom_node.getChildrenCount());
        }

        try w.objectField("documentURL");
        try w.write(null);

        try w.objectField("baseURL");
        try w.write(null);

        try w.objectField("xmlVersion");
        try w.write("");

        try w.objectField("compatibilityMode");
        try w.write("NoQuirksMode");

        try w.objectField("isScrollable");
        try w.write(false);
    }
};

const testing = @import("testing.zig");
test "cdp Node: search list" {
    var registry = NodeRegistry.init(testing.allocator);
    defer registry.deinit();

    var search_list = Search.List.init(testing.allocator, &registry);
    defer search_list.deinit();

    {
        // empty search list, noops
        search_list.remove("0");
        try testing.expectEqual(null, search_list.get("0"));
    }

    {
        // empty nodes
        const s1 = try search_list.create(&.{});
        try testing.expectEqual("0", s1.name);
        try testing.expectEqual(0, s1.node_ids.len);

        const s2 = search_list.get("0").?;
        try testing.expectEqual("0", s2.name);
        try testing.expectEqual(0, s2.node_ids.len);

        search_list.remove("0");
        try testing.expectEqual(null, search_list.get("0"));
    }

    {
        var page = try testing.pageTest("cdp/registry2.html", .{});
        defer page.close();

        const frame = page.frame().?;
        var doc = frame.window._document;

        {
            const l1 = try doc.querySelectorAll(.wrap("a"), frame);
            defer l1.deinit(frame._page);
            const s1 = try search_list.create(l1._nodes);
            try testing.expectEqual("1", s1.name);
            try testing.expectEqualSlices(u32, &.{ 1, 2 }, s1.node_ids);
        }

        try testing.expectEqual(2, registry.lookup_by_id.count());
        try testing.expectEqual(2, registry.lookup_by_node.count());

        {
            const l2 = try doc.querySelectorAll(.wrap("#a1"), frame);
            defer l2.deinit(frame._page);
            const s2 = try search_list.create(l2._nodes);
            try testing.expectEqual("2", s2.name);
            try testing.expectEqualSlices(u32, &.{1}, s2.node_ids);
        }

        {
            const l3 = try doc.querySelectorAll(.wrap("#a2"), frame);
            defer l3.deinit(frame._page);
            const s3 = try search_list.create(l3._nodes);
            try testing.expectEqual("3", s3.name);
            try testing.expectEqualSlices(u32, &.{2}, s3.node_ids);
        }

        try testing.expectEqual(2, registry.lookup_by_id.count());
        try testing.expectEqual(2, registry.lookup_by_node.count());
    }
}

test "cdp Node: Writer" {
    var registry = NodeRegistry.init(testing.allocator);
    defer registry.deinit();

    var page = try testing.pageTest("cdp/registry3.html", .{});
    defer page.close();

    const frame = page.frame().?;
    var doc = frame.window._document;

    {
        const node = try registry.register(doc.asNode());
        const json = try std.json.Stringify.valueAlloc(testing.allocator, Writer{
            .root = node,
            .depth = 0,
            .exclude_root = false,
            .registry = &registry,
        }, .{});
        defer testing.allocator.free(json);

        try testing.expectJson(.{
            .nodeId = 1,
            .backendNodeId = 1,
            .nodeType = 9,
            .nodeName = "#document",
            .localName = "",
            .nodeValue = "",
            .documentURL = null,
            .baseURL = null,
            .xmlVersion = "",
            .isScrollable = false,
            .compatibilityMode = "NoQuirksMode",
            .childNodeCount = 1,
            .children = &.{.{
                .nodeId = 2,
                .backendNodeId = 2,
                .nodeType = 1,
                .nodeName = "HTML",
                .localName = "html",
                .nodeValue = "",
                .childNodeCount = 2,
                .documentURL = null,
                .baseURL = null,
                .xmlVersion = "",
                .compatibilityMode = "NoQuirksMode",
                .isScrollable = false,
            }},
        }, json);
    }

    {
        const node = registry.lookup_by_id.get(2).?;
        const json = try std.json.Stringify.valueAlloc(testing.allocator, Writer{
            .root = node,
            .depth = 1,
            .exclude_root = false,
            .registry = &registry,
        }, .{});
        defer testing.allocator.free(json);

        try testing.expectJson(.{
            .nodeId = 2,
            .backendNodeId = 2,
            .nodeType = 1,
            .nodeName = "HTML",
            .localName = "html",
            .nodeValue = "",
            .childNodeCount = 2,
            .documentURL = null,
            .baseURL = null,
            .xmlVersion = "",
            .compatibilityMode = "NoQuirksMode",
            .isScrollable = false,
            .children = &.{ .{
                .nodeId = 3,
                .backendNodeId = 3,
                .nodeType = 1,
                .nodeName = "HEAD",
                .localName = "head",
                .nodeValue = "",
                .childNodeCount = 0,
                .documentURL = null,
                .baseURL = null,
                .xmlVersion = "",
                .compatibilityMode = "NoQuirksMode",
                .isScrollable = false,
                .parentId = 2,
            }, .{
                .nodeId = 4,
                .backendNodeId = 4,
                .nodeType = 1,
                .nodeName = "BODY",
                .localName = "body",
                .nodeValue = "",
                .childNodeCount = 3,
                .documentURL = null,
                .baseURL = null,
                .xmlVersion = "",
                .compatibilityMode = "NoQuirksMode",
                .isScrollable = false,
                .parentId = 2,
            } },
        }, json);
    }

    {
        const node = registry.lookup_by_id.get(2).?;
        const json = try std.json.Stringify.valueAlloc(testing.allocator, Writer{
            .root = node,
            .depth = -1,
            .exclude_root = true,
            .registry = &registry,
        }, .{});
        defer testing.allocator.free(json);

        try testing.expectJson(&.{ .{
            .nodeId = 3,
            .backendNodeId = 3,
            .nodeType = 1,
            .nodeName = "HEAD",
            .localName = "head",
            .nodeValue = "",
            .childNodeCount = 0,
            .documentURL = null,
            .baseURL = null,
            .xmlVersion = "",
            .compatibilityMode = "NoQuirksMode",
            .isScrollable = false,
            .parentId = 2,
        }, .{
            .nodeId = 4,
            .backendNodeId = 4,
            .nodeType = 1,
            .nodeName = "BODY",
            .localName = "body",
            .nodeValue = "",
            .childNodeCount = 3,
            .documentURL = null,
            .baseURL = null,
            .xmlVersion = "",
            .compatibilityMode = "NoQuirksMode",
            .isScrollable = false,
            .children = &.{ .{
                .nodeId = 5,
                .localName = "a",
                .childNodeCount = 0,
                .attributes = &.{ "id", "a1" },
                .parentId = 4,
            }, .{
                .nodeId = 6,
                .localName = "div",
                .childNodeCount = 1,
                .parentId = 4,
                .children = &.{.{
                    .nodeId = 7,
                    .localName = "a",
                    .childNodeCount = 0,
                    .parentId = 6,
                    .attributes = &.{ "id", "a2" },
                }},
            }, .{
                .nodeId = 8,
                .backendNodeId = 8,
                .nodeName = "#text",
                .localName = "",
                .childNodeCount = 0,
                .parentId = 4,
                .nodeValue = "\n",
            } },
        } }, json);
    }
}
