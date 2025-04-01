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
const parser = @import("netsurf");
const Allocator = std.mem.Allocator;

pub const Id = u32;

const Node = @This();

id: Id,
parent_id: ?Id = null,
node_type: u32,
backend_node_id: Id,
node_name: []const u8,
local_name: []const u8,
node_value: []const u8,
child_node_count: u32,
children: []const *Node,
document_url: ?[]const u8,
base_url: ?[]const u8,
xml_version: []const u8,
compatibility_mode: CompatibilityMode,
is_scrollable: bool,
_node: *parser.Node,

const CompatibilityMode = enum {
    NoQuirksMode,
};

pub fn writer(self: *const Node, opts: Writer.Opts) Writer {
    return .{ .node = self, .opts = opts };
}

// Whenever we send a node to the client, we register it here for future lookup.
// We maintain a node -> id and id -> node lookup.
pub const Registry = struct {
    node_id: u32,
    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    node_pool: std.heap.MemoryPool(Node),
    lookup_by_id: std.AutoHashMapUnmanaged(Id, *Node),
    lookup_by_node: std.HashMapUnmanaged(*parser.Node, *Node, NodeContext, std.hash_map.default_max_load_percentage),

    pub fn init(allocator: Allocator) Registry {
        return .{
            .node_id = 0,
            .lookup_by_id = .{},
            .lookup_by_node = .{},
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .node_pool = std.heap.MemoryPool(Node).init(allocator),
        };
    }

    pub fn deinit(self: *Registry) void {
        const allocator = self.allocator;
        self.lookup_by_id.deinit(allocator);
        self.lookup_by_node.deinit(allocator);
        self.node_pool.deinit();
        self.arena.deinit();
    }

    pub fn reset(self: *Registry) void {
        self.lookup_by_id.clearRetainingCapacity();
        self.lookup_by_node.clearRetainingCapacity();
        _ = self.arena.reset(.{ .retain_with_limit = 1024 });
        _ = self.node_pool.reset(.{ .retain_with_limit = 1024 });
    }

    pub fn register(self: *Registry, n: *parser.Node) !*Node {
        const node_lookup_gop = try self.lookup_by_node.getOrPut(self.allocator, n);
        if (node_lookup_gop.found_existing) {
            return node_lookup_gop.value_ptr.*;
        }

        // on error, we're probably going to abort the entire browser context
        // but, just in case, let's try to keep things tidy.
        errdefer _ = self.lookup_by_node.remove(n);

        const id = self.node_id;
        self.node_id = id + 1;

        const child_nodes = try self.registerChildNodes(n);

        const node = try self.node_pool.create();
        errdefer self.node_pool.destroy(node);

        node.* = .{
            ._node = n,
            .id = id,
            .parent_id = null, // TODO
            .backend_node_id = id, // ??
            .node_name = parser.nodeName(n) catch return error.NodeNameError,
            .local_name = parser.nodeLocalName(n) catch return error.NodeLocalNameError,
            .node_value = (parser.nodeValue(n) catch return error.NameValueError) orelse "",
            .node_type = @intFromEnum(parser.nodeType(n) catch return error.NodeTypeError),
            .child_node_count = @intCast(child_nodes.len),
            .children = child_nodes,
            .document_url = null,
            .base_url = null,
            .xml_version = "",
            .compatibility_mode = .NoQuirksMode,
            .is_scrollable = false,
        };

        // if (try parser.nodeParentNode(n)) |pn| {
        //     _  = pn;
        //     // TODO
        // }

        node_lookup_gop.value_ptr.* = node;
        try self.lookup_by_id.putNoClobber(self.allocator, id, node);
        return node;
    }

    pub fn registerChildNodes(self: *Registry, n: *parser.Node) RegisterError![]*Node {
        const node_list = parser.nodeGetChildNodes(n) catch return error.GetChildNodeError;
        const count = parser.nodeListLength(node_list) catch return error.NodeListLengthError;

        var arr = try self.arena.allocator().alloc(*Node, count);
        var i: usize = 0;
        for (0..count) |_| {
            const child = (parser.nodeListItem(node_list, @intCast(i)) catch return error.NodeListItemError) orelse continue;
            arr[i] = try self.register(child);
            i += 1;
        }
        return arr[0..i];
    }
};

const RegisterError = error{
    OutOfMemory,
    GetChildNodeError,
    NodeListLengthError,
    NodeListItemError,
    NodeNameError,
    NodeLocalNameError,
    NameValueError,
    NodeTypeError,
};

const NodeContext = struct {
    pub fn hash(_: NodeContext, n: *parser.Node) u64 {
        return std.hash.Wyhash.hash(0, std.mem.asBytes(&@intFromPtr(n)));
    }

    pub fn eql(_: NodeContext, a: *parser.Node, b: *parser.Node) bool {
        return @intFromPtr(a) == @intFromPtr(b);
    }
};

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
    node_ids: []const Id,

    pub const List = struct {
        registry: *Registry,
        search_id: u16 = 0,
        arena: std.heap.ArenaAllocator,
        searches: std.ArrayListUnmanaged(Search) = .{},

        pub fn init(allocator: Allocator, registry: *Registry) List {
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
            self.searches = .{};
            _ = self.arena.reset(.{ .retain_with_limit = 4096 });
        }

        pub fn create(self: *List, nodes: []const *parser.Node) !Search {
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
            const node_ids = try arena.alloc(Id, nodes.len);
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
// Sometimes we want to serializ the node without chidren, sometimes with just
// its direct children, and sometimes the entire tree.
// (For now, we only support direct children)
pub const Writer = struct {
    opts: Opts,
    node: *const Node,

    pub const Opts = struct {};

    pub fn jsonStringify(self: *const Writer, w: anytype) !void {
        try w.beginObject();
        try writeCommon(self.node, w);
        try w.objectField("children");
        try w.beginArray();
        for (self.node.children) |node| {
            try w.beginObject();
            try writeCommon(node, w);
            try w.endObject();
        }
        try w.endArray();
        try w.endObject();
    }

    fn writeCommon(node: *const Node, w: anytype) !void {
        try w.objectField("nodeId");
        try w.write(node.id);

        if (node.parent_id) |pid| {
            try w.objectField("parentId");
            try w.write(pid);
        }

        try w.objectField("backendNodeId");
        try w.write(node.backend_node_id);

        try w.objectField("nodeType");
        try w.write(node.node_type);

        try w.objectField("nodeName");
        try w.write(node.node_name);

        try w.objectField("localName");
        try w.write(node.local_name);

        try w.objectField("nodeValue");
        try w.write(node.node_value);

        try w.objectField("childNodeCount");
        try w.write(node.child_node_count);

        try w.objectField("documentURL");
        try w.write(node.document_url);

        try w.objectField("baseURL");
        try w.write(node.base_url);

        try w.objectField("xmlVersion");
        try w.write(node.xml_version);

        try w.objectField("compatibilityMode");
        try w.write(node.compatibility_mode);

        try w.objectField("isScrollable");
        try w.write(node.is_scrollable);
    }
};

const testing = @import("testing.zig");
test "cdp Node: Registry register" {
    var registry = Registry.init(testing.allocator);
    defer registry.deinit();

    try testing.expectEqual(0, registry.lookup_by_id.count());
    try testing.expectEqual(0, registry.lookup_by_node.count());

    var doc = try testing.Document.init("<a id=a1>link1</a><div id=d2><p>other</p></div>");
    defer doc.deinit();

    {
        const n = (try doc.querySelector("#a1")).?;
        const node = try registry.register(n);
        const n1b = registry.lookup_by_id.get(0).?;
        const n1c = registry.lookup_by_node.get(node._node).?;
        try testing.expectEqual(node, n1b);
        try testing.expectEqual(node, n1c);

        try testing.expectEqual(0, node.id);
        try testing.expectEqual(null, node.parent_id);
        try testing.expectEqual(1, node.node_type);
        try testing.expectEqual(0, node.backend_node_id);
        try testing.expectEqual("A", node.node_name);
        try testing.expectEqual("a", node.local_name);
        try testing.expectEqual("", node.node_value);
        try testing.expectEqual(1, node.child_node_count);
        try testing.expectEqual(1, node.children.len);
        try testing.expectEqual(1, node.children[0].id);
        try testing.expectEqual(null, node.document_url);
        try testing.expectEqual(null, node.base_url);
        try testing.expectEqual("", node.xml_version);
        try testing.expectEqual(.NoQuirksMode, node.compatibility_mode);
        try testing.expectEqual(false, node.is_scrollable);
        try testing.expectEqual(n, node._node);
    }

    {
        const n = (try doc.querySelector("p")).?;
        const node = try registry.register(n);
        const n1b = registry.lookup_by_id.get(2).?;
        const n1c = registry.lookup_by_node.get(node._node).?;
        try testing.expectEqual(node, n1b);
        try testing.expectEqual(node, n1c);

        try testing.expectEqual(2, node.id);
        try testing.expectEqual(null, node.parent_id);
        try testing.expectEqual(1, node.node_type);
        try testing.expectEqual(2, node.backend_node_id);
        try testing.expectEqual("P", node.node_name);
        try testing.expectEqual("p", node.local_name);
        try testing.expectEqual("", node.node_value);
        try testing.expectEqual(1, node.child_node_count);
        try testing.expectEqual(1, node.children.len);
        try testing.expectEqual(3, node.children[0].id);
        try testing.expectEqual(null, node.document_url);
        try testing.expectEqual(null, node.base_url);
        try testing.expectEqual("", node.xml_version);
        try testing.expectEqual(.NoQuirksMode, node.compatibility_mode);
        try testing.expectEqual(false, node.is_scrollable);
        try testing.expectEqual(n, node._node);
    }
}

test "cdp Node: search list" {
    var registry = Registry.init(testing.allocator);
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
        var doc = try testing.Document.init("<a id=a1></a><a id=a2></a>");
        defer doc.deinit();

        const s1 = try search_list.create(try doc.querySelectorAll("a"));
        try testing.expectEqual("1", s1.name);
        try testing.expectEqualSlices(u32, &.{ 0, 1 }, s1.node_ids);

        try testing.expectEqual(2, registry.lookup_by_id.count());
        try testing.expectEqual(2, registry.lookup_by_node.count());

        const s2 = try search_list.create(try doc.querySelectorAll("#a1"));
        try testing.expectEqual("2", s2.name);
        try testing.expectEqualSlices(u32, &.{0}, s2.node_ids);

        const s3 = try search_list.create(try doc.querySelectorAll("#a2"));
        try testing.expectEqual("3", s3.name);
        try testing.expectEqualSlices(u32, &.{1}, s3.node_ids);

        try testing.expectEqual(2, registry.lookup_by_id.count());
        try testing.expectEqual(2, registry.lookup_by_node.count());
    }
}

test "cdp Node: Writer" {
    var registry = Registry.init(testing.allocator);
    defer registry.deinit();

    var doc = try testing.Document.init("<a id=a1></a><a id=a2></a>");
    defer doc.deinit();

    {
        const node = try registry.register(doc.asNode());
        const json = try std.json.stringifyAlloc(testing.allocator, node.writer(.{}), .{});
        defer testing.allocator.free(json);

        try testing.expectJson(.{ .nodeId = 0, .backendNodeId = 0, .nodeType = 9, .nodeName = "#document", .localName = "", .nodeValue = "", .documentURL = null, .baseURL = null, .xmlVersion = "", .isScrollable = false, .compatibilityMode = "NoQuirksMode", .childNodeCount = 1, .children = &.{.{ .nodeId = 1, .backendNodeId = 1, .nodeType = 1, .nodeName = "HTML", .localName = "html", .nodeValue = "", .childNodeCount = 2, .documentURL = null, .baseURL = null, .xmlVersion = "", .compatibilityMode = "NoQuirksMode", .isScrollable = false }} }, json);
    }

    {
        const node = registry.lookup_by_id.get(1).?;
        const json = try std.json.stringifyAlloc(testing.allocator, node.writer(.{}), .{});
        defer testing.allocator.free(json);

        try testing.expectJson(.{ .nodeId = 1, .backendNodeId = 1, .nodeType = 1, .nodeName = "HTML", .localName = "html", .nodeValue = "", .childNodeCount = 2, .documentURL = null, .baseURL = null, .xmlVersion = "", .compatibilityMode = "NoQuirksMode", .isScrollable = false, .children = &.{ .{ .nodeId = 2, .backendNodeId = 2, .nodeType = 1, .nodeName = "HEAD", .localName = "head", .nodeValue = "", .childNodeCount = 0, .documentURL = null, .baseURL = null, .xmlVersion = "", .compatibilityMode = "NoQuirksMode", .isScrollable = false }, .{ .nodeId = 3, .backendNodeId = 3, .nodeType = 1, .nodeName = "BODY", .localName = "body", .nodeValue = "", .childNodeCount = 2, .documentURL = null, .baseURL = null, .xmlVersion = "", .compatibilityMode = "NoQuirksMode", .isScrollable = false } } }, json);
    }
}
