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

const server = @import("../server.zig");
const Ctx = server.Ctx;
const cdp = @import("cdp.zig");
const result = cdp.result;
const IncomingMessage = @import("msg.zig").IncomingMessage;
const Input = @import("msg.zig").Input;
const css = @import("../dom/css.zig");

const parser = @import("netsurf");

const log = std.log.scoped(.cdp);

const Methods = enum {
    enable,
    getDocument,
    performSearch,
    getSearchResults,
    discardSearchResults,
};

pub fn dom(
    alloc: std.mem.Allocator,
    msg: *IncomingMessage,
    action: []const u8,
    ctx: *Ctx,
) ![]const u8 {
    const method = std.meta.stringToEnum(Methods, action) orelse
        return error.UnknownMethod;

    return switch (method) {
        .enable => enable(alloc, msg, ctx),
        .getDocument => getDocument(alloc, msg, ctx),
        .performSearch => performSearch(alloc, msg, ctx),
        .getSearchResults => getSearchResults(alloc, msg, ctx),
        .discardSearchResults => discardSearchResults(alloc, msg, ctx),
    };
}

fn enable(
    alloc: std.mem.Allocator,
    msg: *IncomingMessage,
    _: *Ctx,
) ![]const u8 {
    // input
    const input = try Input(void).get(alloc, msg);
    defer input.deinit();
    log.debug("Req > id {d}, method {s}", .{ input.id, "inspector.enable" });

    return result(alloc, input.id, null, null, input.sessionId);
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
        for (self.coll.items, 0..) |n, i| {
            if (n == node) return @intCast(i);
        }

        try self.coll.append(node);
        return @intCast(self.coll.items.len);
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
    childNodeCount: u32,
    children: ?[]const Node = null,
    documentURL: ?[]const u8 = null,
    baseURL: ?[]const u8 = null,
    xmlVersion: []const u8 = "",
    compatibilityMode: []const u8 = "NoQuirksMode",
    isScrollable: bool = false,

    fn init(n: *parser.Node, id: NodeId) !Node {
        const children = try parser.nodeGetChildNodes(n);
        const ln = try parser.nodeListLength(children);

        return .{
            .nodeId = id,
            .backendNodeId = id,
            .nodeType = @intFromEnum(try parser.nodeType(n)),
            .nodeName = try parser.nodeName(n),
            .localName = try parser.nodeLocalName(n),
            .nodeValue = try parser.nodeValue(n) orelse "",
            .childNodeCount = ln,
        };
    }
};

// https://chromedevtools.github.io/devtools-protocol/tot/DOM/#method-getDocument
fn getDocument(
    alloc: std.mem.Allocator,
    msg: *IncomingMessage,
    ctx: *Ctx,
) ![]const u8 {
    // input
    const Params = struct {
        depth: ?u32 = null,
        pierce: ?bool = null,
    };
    const input = try Input(Params).get(alloc, msg);
    defer input.deinit();
    std.debug.assert(input.sessionId != null);
    log.debug("Req > id {d}, method {s}", .{ input.id, "DOM.getDocument" });

    // retrieve the root node
    const page = ctx.browser.currentPage() orelse return error.NoPage;

    if (page.doc == null) return error.NoDocument;

    const node = parser.documentToNode(page.doc.?);
    const id = try ctx.state.nodelist.set(node);

    // output
    const Resp = struct {
        root: Node,
    };
    const resp: Resp = .{
        .root = try Node.init(node, id),
    };

    return result(alloc, input.id, Resp, resp, input.sessionId);
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
fn performSearch(
    alloc: std.mem.Allocator,
    msg: *IncomingMessage,
    ctx: *Ctx,
) ![]const u8 {
    // input
    const Params = struct {
        query: []const u8,
        includeUserAgentShadowDOM: ?bool = null,
    };
    const input = try Input(Params).get(alloc, msg);
    defer input.deinit();
    std.debug.assert(input.sessionId != null);
    log.debug("Req > id {d}, method {s}", .{ input.id, "DOM.performSearch" });

    // retrieve the root node
    const page = ctx.browser.currentPage() orelse return error.NoPage;

    if (page.doc == null) return error.NoDocument;

    const list = try css.querySelectorAll(alloc, parser.documentToNode(page.doc.?), input.params.query);
    const ln = list.nodes.items.len;
    var ns = try NodeSearch.initCapacity(alloc, ln);

    for (list.nodes.items) |n| {
        const id = try ctx.state.nodelist.set(n);
        try ns.append(id);
    }

    try ctx.state.nodesearchlist.append(ns);

    // output
    const Resp = struct {
        searchId: []const u8,
        resultCount: u32,
    };
    const resp: Resp = .{
        .searchId = ns.name,
        .resultCount = @intCast(ln),
    };

    return result(alloc, input.id, Resp, resp, input.sessionId);
}

// https://chromedevtools.github.io/devtools-protocol/tot/DOM/#method-discardSearchResults
fn discardSearchResults(
    alloc: std.mem.Allocator,
    msg: *IncomingMessage,
    ctx: *Ctx,
) ![]const u8 {
    // input
    const Params = struct {
        searchId: []const u8,
    };
    const input = try Input(Params).get(alloc, msg);
    defer input.deinit();
    std.debug.assert(input.sessionId != null);
    log.debug("Req > id {d}, method {s}", .{ input.id, "DOM.discardSearchResults" });

    // retrieve the search from context
    for (ctx.state.nodesearchlist.items, 0..) |*s, i| {
        if (!std.mem.eql(u8, s.name, input.params.searchId)) continue;

        s.deinit();
        _ = ctx.state.nodesearchlist.swapRemove(i);
        break;
    }

    return result(alloc, input.id, null, null, input.sessionId);
}

// https://chromedevtools.github.io/devtools-protocol/tot/DOM/#method-getSearchResults
fn getSearchResults(
    alloc: std.mem.Allocator,
    msg: *IncomingMessage,
    ctx: *Ctx,
) ![]const u8 {
    // input
    const Params = struct {
        searchId: []const u8,
        fromIndex: u32,
        toIndex: u32,
    };
    const input = try Input(Params).get(alloc, msg);
    defer input.deinit();
    std.debug.assert(input.sessionId != null);
    log.debug("Req > id {d}, method {s}", .{ input.id, "DOM.getSearchResults" });

    if (input.params.fromIndex >= input.params.toIndex) return error.BadIndices;

    // retrieve the search from context
    var ns: ?*const NodeSearch = undefined;
    for (ctx.state.nodesearchlist.items) |s| {
        if (!std.mem.eql(u8, s.name, input.params.searchId)) continue;

        ns = &s;
        break;
    }

    if (ns == null) return error.searchResultNotFound;
    const items = ns.?.coll.items;

    if (input.params.fromIndex >= items.len) return error.BadFromIndex;
    if (input.params.toIndex > items.len) return error.BadToIndex;

    // output
    const Resp = struct {
        nodeIds: []NodeId,
    };
    const resp: Resp = .{
        .nodeIds = ns.?.coll.items[input.params.fromIndex..input.params.toIndex],
    };

    return result(alloc, input.id, Resp, resp, input.sessionId);
}
