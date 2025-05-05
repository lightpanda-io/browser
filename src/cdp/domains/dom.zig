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
const Node = @import("../Node.zig");
const css = @import("../../browser/dom/css.zig");
const parser = @import("../../browser/netsurf.zig");
const dom_node = @import("../../browser/dom/node.zig");

pub fn processMessage(cmd: anytype) !void {
    const action = std.meta.stringToEnum(enum {
        enable,
        getDocument,
        performSearch,
        getSearchResults,
        discardSearchResults,
        resolveNode,
        describeNode,
    }, cmd.input.action) orelse return error.UnknownMethod;

    switch (action) {
        .enable => return cmd.sendResult(null, .{}),
        .getDocument => return getDocument(cmd),
        .performSearch => return performSearch(cmd),
        .getSearchResults => return getSearchResults(cmd),
        .discardSearchResults => return discardSearchResults(cmd),
        .resolveNode => return resolveNode(cmd),
        .describeNode => return describeNode(cmd),
    }
}

// https://chromedevtools.github.io/devtools-protocol/tot/DOM/#method-getDocument
fn getDocument(cmd: anytype) !void {
    // const params = (try cmd.params(struct {
    //     depth: ?u32 = null,
    //     pierce: ?bool = null,
    // })) orelse return error.InvalidParams;

    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    const page = bc.session.currentPage() orelse return error.PageNotLoaded;
    const doc = page.doc orelse return error.DocumentNotLoaded;

    const node = try bc.node_registry.register(parser.documentToNode(doc));
    return cmd.sendResult(.{ .root = bc.nodeWriter(node, .{}) }, .{});
}

// https://chromedevtools.github.io/devtools-protocol/tot/DOM/#method-performSearch
fn performSearch(cmd: anytype) !void {
    const params = (try cmd.params(struct {
        query: []const u8,
        includeUserAgentShadowDOM: ?bool = null,
    })) orelse return error.InvalidParams;

    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    const page = bc.session.currentPage() orelse return error.PageNotLoaded;
    const doc = page.doc orelse return error.DocumentNotLoaded;

    const allocator = cmd.cdp.allocator;
    var list = try css.querySelectorAll(allocator, parser.documentToNode(doc), params.query);
    defer list.deinit(allocator);

    const search = try bc.node_search_list.create(list.nodes.items);

    // dispatch setChildNodesEvents to inform the client of the subpart of node
    // tree covering the results.
    try dispatchSetChildNodes(cmd, list.nodes.items);

    return cmd.sendResult(.{
        .searchId = search.name,
        .resultCount = @as(u32, @intCast(search.node_ids.len)),
    }, .{});
}

// dispatchSetChildNodes send the setChildNodes event for the whole DOM tree
// hierarchy of each nodes.
// We dispatch event in the reverse order: from the top level to the direct parents.
// We should dispatch a node only if it has never been sent.
fn dispatchSetChildNodes(cmd: anytype, nodes: []*parser.Node) !void {
    const arena = cmd.arena;
    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    const session_id = bc.session_id orelse return error.SessionIdNotLoaded;

    var parents: std.ArrayListUnmanaged(*Node) = .{};
    for (nodes) |_n| {
        var n = _n;
        while (true) {
            const p = try parser.nodeParentNode(n) orelse break;

            // Register the node.
            const node = try bc.node_registry.register(p);
            if (node.set_child_nodes_event) break;
            try parents.append(arena, node);
            n = p;
        }
    }

    const plen = parents.items.len;
    if (plen == 0) return;

    var i: usize = plen;
    // We're going to iterate in reverse order from how we added them.
    // This ensures that we're emitting the tree of nodes top-down.
    while (i > 0) {
        i -= 1;
        const node = parents.items[i];
        // Although our above loop won't add an already-sent node to `parents`
        // this can still be true because two nodes can share the same parent node
        // so we might have just sent the node a previous iteration of this loop
        if (node.set_child_nodes_event) continue;

        node.set_child_nodes_event = true;

        // If the node has no parent, it's the root node.
        // We don't dispatch event for it because we assume the root node is
        // dispatched via the DOM.getDocument command.
        const p = try parser.nodeParentNode(node._node) orelse {
            continue;
        };

        // Retrieve the parent from the registry.
        const parent_node = try bc.node_registry.register(p);

        try cmd.sendEvent("DOM.setChildNodes", .{
            .parentId = parent_node.id,
            .nodes = .{bc.nodeWriter(node, .{})},
        }, .{
            .session_id = session_id,
        });
    }
}

// https://chromedevtools.github.io/devtools-protocol/tot/DOM/#method-discardSearchResults
fn discardSearchResults(cmd: anytype) !void {
    const params = (try cmd.params(struct {
        searchId: []const u8,
    })) orelse return error.InvalidParams;

    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;

    bc.node_search_list.remove(params.searchId);
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

    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;

    const search = bc.node_search_list.get(params.searchId) orelse {
        return error.SearchResultNotFound;
    };

    const node_ids = search.node_ids;

    if (params.fromIndex >= node_ids.len) return error.BadFromIndex;
    if (params.toIndex > node_ids.len) return error.BadToIndex;

    return cmd.sendResult(.{ .nodeIds = node_ids[params.fromIndex..params.toIndex] }, .{});
}

fn resolveNode(cmd: anytype) !void {
    const params = (try cmd.params(struct {
        nodeId: ?Node.Id = null,
        backendNodeId: ?u32 = null,
        objectGroup: ?[]const u8 = null,
        executionContextId: ?u32 = null,
    })) orelse return error.InvalidParams;

    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    const page = bc.session.currentPage() orelse return error.PageNotLoaded;

    var scope = page.scope;
    if (params.executionContextId) |context_id| {
        if (scope.context.debugContextId() != context_id) {
            const isolated_world = bc.isolated_world orelse return error.ContextNotFound;
            scope = isolated_world.scope;

            if (scope.context.debugContextId() != context_id) return error.ContextNotFound;
        }
    }

    const input_node_id = params.nodeId orelse params.backendNodeId orelse return error.InvalidParam;
    const node = bc.node_registry.lookup_by_id.get(input_node_id) orelse return error.UnknownNode;

    // node._node is a *parser.Node we need this to be able to find its most derived type e.g. Node -> Element -> HTMLElement
    // So we use the Node.Union when retrieve the value from the environment
    const remote_object = try bc.inspector.getRemoteObject(
        scope,
        params.objectGroup orelse "",
        try dom_node.Node.toInterface(node._node),
    );
    defer remote_object.deinit();

    const arena = cmd.arena;
    return cmd.sendResult(.{ .object = .{
        .type = try remote_object.getType(arena),
        .subtype = try remote_object.getSubtype(arena),
        .className = try remote_object.getClassName(arena),
        .description = try remote_object.getDescription(arena),
        .objectId = try remote_object.getObjectId(arena),
    } }, .{});
}

fn describeNode(cmd: anytype) !void {
    const params = (try cmd.params(struct {
        nodeId: ?Node.Id = null,
        backendNodeId: ?Node.Id = null,
        objectId: ?[]const u8 = null,
        depth: u32 = 1,
        pierce: bool = false,
    })) orelse return error.InvalidParams;
    if (params.backendNodeId != null or params.depth != 1 or params.pierce) {
        return error.NotYetImplementedParams;
    }

    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;

    if (params.nodeId != null) {
        const node = bc.node_registry.lookup_by_id.get(params.nodeId.?) orelse return error.NodeNotFound;
        return cmd.sendResult(.{ .node = bc.nodeWriter(node, .{}) }, .{});
    }
    if (params.objectId != null) {
        // Retrieve the object from which ever context it is in.
        const parser_node = try bc.inspector.getNodePtr(cmd.arena, params.objectId.?);
        const node = try bc.node_registry.register(@ptrCast(parser_node));
        return cmd.sendResult(.{ .node = bc.nodeWriter(node, .{}) }, .{});
    }
    return error.MissingParams;
}

const testing = @import("../testing.zig");

test "cdp.dom: getSearchResults unknown search id" {
    var ctx = testing.context();
    defer ctx.deinit();

    try testing.expectError(error.BrowserContextNotLoaded, ctx.processMessage(.{
        .id = 8,
        .method = "DOM.getSearchResults",
        .params = .{ .searchId = "Nope", .fromIndex = 0, .toIndex = 10 },
    }));
}

test "cdp.dom: search flow" {
    var ctx = testing.context();
    defer ctx.deinit();

    _ = try ctx.loadBrowserContext(.{ .id = "BID-A", .html = "<p>1</p> <p>2</p>" });

    try ctx.processMessage(.{
        .id = 12,
        .method = "DOM.performSearch",
        .params = .{ .query = "p" },
    });
    try ctx.expectSentResult(.{ .searchId = "0", .resultCount = 2 }, .{ .id = 12 });

    {
        // getSearchResults
        try ctx.processMessage(.{
            .id = 13,
            .method = "DOM.getSearchResults",
            .params = .{ .searchId = "0", .fromIndex = 0, .toIndex = 2 },
        });
        try ctx.expectSentResult(.{ .nodeIds = &.{ 0, 1 } }, .{ .id = 13 });

        // different fromIndex
        try ctx.processMessage(.{
            .id = 14,
            .method = "DOM.getSearchResults",
            .params = .{ .searchId = "0", .fromIndex = 1, .toIndex = 2 },
        });
        try ctx.expectSentResult(.{ .nodeIds = &.{1} }, .{ .id = 14 });

        // different toIndex
        try ctx.processMessage(.{
            .id = 15,
            .method = "DOM.getSearchResults",
            .params = .{ .searchId = "0", .fromIndex = 0, .toIndex = 1 },
        });
        try ctx.expectSentResult(.{ .nodeIds = &.{0} }, .{ .id = 15 });
    }

    try ctx.processMessage(.{
        .id = 16,
        .method = "DOM.discardSearchResults",
        .params = .{ .searchId = "0" },
    });
    try ctx.expectSentResult(null, .{ .id = 16 });

    // make sure the delete actually did something
    try testing.expectError(error.SearchResultNotFound, ctx.processMessage(.{
        .id = 17,
        .method = "DOM.getSearchResults",
        .params = .{ .searchId = "0", .fromIndex = 0, .toIndex = 1 },
    }));
}
