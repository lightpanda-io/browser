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
const cdp = @import("cdp.zig");
const css = @import("../dom/css.zig");

const parser = @import("netsurf");

pub fn processMessage(cmd: anytype) !void {
    const action = std.meta.stringToEnum(enum {
        enable,
        getDocument,
        performSearch,
        getSearchResults,
        discardSearchResults,
    }, cmd.action) orelse return error.UnknownMethod;

    switch (action) {
        .enable => return cmd.sendResult(null, .{}),
        .getDocument => return getDocument(cmd),
        .performSearch => return performSearch(cmd),
        .getSearchResults => return getSearchResults(cmd),
        .discardSearchResults => return discardSearchResults(cmd),
    }
}

// NodeList references tree nodes with an array id.
pub const NodeList = struct {
    coll: List,

    const List = std.ArrayList(*parser.Node);

    pub fn init(alloc: std.mem.Allocator) NodeList {
        return .{
            .coll = List.init(alloc),
        };
    }

    pub fn deinit(self: *NodeList) void {
        self.coll.deinit();
    }

    pub fn reset(self: *NodeList) void {
        self.coll.clearAndFree();
    }

    pub fn set(self: *NodeList, node: *parser.Node) !NodeId {
        const coll = &self.coll;
        for (coll.items, 0..) |n, i| {
            if (n == node) {
                return @intCast(i);
            }
        }

        try coll.append(node);
        return @intCast(coll.items.len);
    }
};

const NodeId = u32;

const Node = struct {
    nodeId: NodeId,
    parentId: ?NodeId = null,
    backendNodeId: NodeId,
    nodeType: u32,
    nodeName: []const u8 = "",
    localName: []const u8 = "",
    nodeValue: []const u8 = "",
    childNodeCount: ?u32 = null,
    children: ?[]const Node = null,
    documentURL: ?[]const u8 = null,
    baseURL: ?[]const u8 = null,
    xmlVersion: []const u8 = "",
    compatibilityMode: []const u8 = "NoQuirksMode",
    isScrollable: bool = false,

    fn init(n: *parser.Node, nlist: *NodeList) !Node {
        const id = try nlist.set(n);
        return .{
            .nodeId = id,
            .backendNodeId = id,
            .nodeType = @intFromEnum(try parser.nodeType(n)),
            .nodeName = try parser.nodeName(n),
            .localName = try parser.nodeLocalName(n),
            .nodeValue = try parser.nodeValue(n) orelse "",
        };
    }

    fn initChildren(
        self: *Node,
        alloc: std.mem.Allocator,
        n: *parser.Node,
        nlist: *NodeList,
    ) !std.ArrayList(Node) {
        const children = try parser.nodeGetChildNodes(n);
        const ln = try parser.nodeListLength(children);
        self.childNodeCount = ln;

        var list = try std.ArrayList(Node).initCapacity(alloc, ln);

        for (0..ln) |i| {
            const child = try parser.nodeListItem(children, @intCast(i)) orelse continue;
            list.appendAssumeCapacity(try Node.init(child, nlist));
        }

        self.children = list.items;

        return list;
    }
};

// https://chromedevtools.github.io/devtools-protocol/tot/DOM/#method-getDocument
fn getDocument(cmd: anytype) !void {
    // const params = (try cmd.params(struct {
    //     depth: ?u32 = null,
    //     pierce: ?bool = null,
    // })) orelse return error.InvalidParams;

    // retrieve the root node
    const page = cmd.session.page orelse return error.NoPage;
    const doc = page.doc orelse return error.NoDocument;

    const state = cmd.cdp;
    const node = parser.documentToNode(doc);
    var n = try Node.init(node, &state.node_list);
    _ = try n.initChildren(cmd.arena, node, &state.node_list);

    return cmd.sendResult(.{
        .root = n,
    }, .{});
}

pub const NodeSearch = struct {
    coll: List,
    name: []u8,
    alloc: std.mem.Allocator,

    var count: u8 = 0;

    const List = std.ArrayListUnmanaged(NodeId);

    pub fn initCapacity(alloc: std.mem.Allocator, ln: usize) !NodeSearch {
        count += 1;

        return .{
            .alloc = alloc,
            .coll = try List.initCapacity(alloc, ln),
            .name = try std.fmt.allocPrint(alloc, "{d}", .{count}),
        };
    }

    pub fn deinit(self: *NodeSearch) void {
        self.coll.deinit(self.alloc);
        self.alloc.free(self.name);
    }

    pub fn append(self: *NodeSearch, id: NodeId) !void {
        try self.coll.append(self.alloc, id);
    }
};
pub const NodeSearchList = std.ArrayList(NodeSearch);

// https://chromedevtools.github.io/devtools-protocol/tot/DOM/#method-performSearch
fn performSearch(cmd: anytype) !void {
    const params = (try cmd.params(struct {
        query: []const u8,
        includeUserAgentShadowDOM: ?bool = null,
    })) orelse return error.InvalidParams;

    // retrieve the root node
    const page = cmd.session.page orelse return error.NoPage;
    const doc = page.doc orelse return error.NoDocument;

    const list = try css.querySelectorAll(cmd.cdp.allocator, parser.documentToNode(doc), params.query);
    const ln = list.nodes.items.len;
    var ns = try NodeSearch.initCapacity(cmd.cdp.allocator, ln);

    var state = cmd.cdp;
    for (list.nodes.items) |n| {
        const id = try state.node_list.set(n);
        try ns.append(id);
    }

    try state.node_search_list.append(ns);

    return cmd.sendResult(.{
        .searchId = ns.name,
        .resultCount = @as(u32, @intCast(ln)),
    }, .{});
}

// https://chromedevtools.github.io/devtools-protocol/tot/DOM/#method-discardSearchResults
fn discardSearchResults(cmd: anytype) !void {
    const params = (try cmd.params(struct {
        searchId: []const u8,
    })) orelse return error.InvalidParams;

    var state = cmd.cdp;
    // retrieve the search from context
    for (state.node_search_list.items, 0..) |*s, i| {
        if (!std.mem.eql(u8, s.name, params.searchId)) continue;

        s.deinit();
        _ = state.node_search_list.swapRemove(i);
        break;
    }

    return cmd.sendResult(null, .{});
}

// https://chromedevtools.github.io/devtools-protocol/tot/DOM/#method-getSearchResults
fn getSearchResults(cmd: anytype) !void {
    const params = (try cmd.params(struct {
        searchId: []const u8,
        fromIndex: u32,
        toIndex: u32,
    })) orelse return error.InvalidParams;

    if (params.fromIndex >= params.toIndex) {
        return error.BadIndices;
    }

    const state = cmd.cdp;
    // retrieve the search from context
    var ns: ?*const NodeSearch = undefined;
    for (state.node_search_list.items) |s| {
        if (!std.mem.eql(u8, s.name, params.searchId)) continue;
        ns = &s;
        break;
    }

    if (ns == null) {
        return error.searchResultNotFound;
    }

    const items = ns.?.coll.items;

    if (params.fromIndex >= items.len) return error.BadFromIndex;
    if (params.toIndex > items.len) return error.BadToIndex;

    return cmd.sendResult(.{ .nodeIds = ns.?.coll.items[params.fromIndex..params.toIndex] }, .{});
}
