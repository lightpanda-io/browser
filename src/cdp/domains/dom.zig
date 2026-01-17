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
const log = @import("../../log.zig");
const Node = @import("../Node.zig");
const DOMNode = @import("../../browser/webapi/Node.zig");
const Selector = @import("../../browser/webapi/selector/Selector.zig");

const dump = @import("../../browser/dump.zig");
const js = @import("../../browser/js/js.zig");

const Allocator = std.mem.Allocator;

pub fn processMessage(cmd: anytype) !void {
    const action = std.meta.stringToEnum(enum {
        enable,
        getDocument,
        performSearch,
        getSearchResults,
        discardSearchResults,
        querySelector,
        querySelectorAll,
        resolveNode,
        describeNode,
        scrollIntoViewIfNeeded,
        getContentQuads,
        getBoxModel,
        requestChildNodes,
        getFrameOwner,
        getOuterHTML,
        requestNode,
    }, cmd.input.action) orelse return error.UnknownMethod;

    switch (action) {
        .enable => return cmd.sendResult(null, .{}),
        .getDocument => return getDocument(cmd),
        .performSearch => return performSearch(cmd),
        .getSearchResults => return getSearchResults(cmd),
        .discardSearchResults => return discardSearchResults(cmd),
        .querySelector => return querySelector(cmd),
        .querySelectorAll => return querySelectorAll(cmd),
        .resolveNode => return resolveNode(cmd),
        .describeNode => return describeNode(cmd),
        .scrollIntoViewIfNeeded => return scrollIntoViewIfNeeded(cmd),
        .getContentQuads => return getContentQuads(cmd),
        .getBoxModel => return getBoxModel(cmd),
        .requestChildNodes => return requestChildNodes(cmd),
        .getFrameOwner => return getFrameOwner(cmd),
        .getOuterHTML => return getOuterHTML(cmd),
        .requestNode => return requestNode(cmd),
    }
}

// https://chromedevtools.github.io/devtools-protocol/tot/DOM/#method-getDocument
fn getDocument(cmd: anytype) !void {
    const Params = struct {
        // CDP documentation implies that 0 isn't valid, but it _does_ work in Chrome
        depth: i32 = 3,
        pierce: bool = false,
    };
    const params = try cmd.params(Params) orelse Params{};

    if (params.pierce) {
        log.warn(.not_implemented, "DOM.getDocument", .{ .param = "pierce" });
    }

    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    const page = bc.session.currentPage() orelse return error.PageNotLoaded;

    const node = try bc.node_registry.register(page.window._document.asNode());
    return cmd.sendResult(.{ .root = bc.nodeWriter(node, .{ .depth = params.depth }) }, .{});
}

// https://chromedevtools.github.io/devtools-protocol/tot/DOM/#method-performSearch
fn performSearch(cmd: anytype) !void {
    const params = (try cmd.params(struct {
        query: []const u8,
        includeUserAgentShadowDOM: ?bool = null,
    })) orelse return error.InvalidParams;

    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    const page = bc.session.currentPage() orelse return error.PageNotLoaded;
    const list = try Selector.querySelectorAll(page.window._document.asNode(), params.query, page);
    const search = try bc.node_search_list.create(list._nodes);

    // dispatch setChildNodesEvents to inform the client of the subpart of node
    // tree covering the results.
    try dispatchSetChildNodes(cmd, list._nodes);

    return cmd.sendResult(.{
        .searchId = search.name,
        .resultCount = @as(u32, @intCast(search.node_ids.len)),
    }, .{});
}

// dispatchSetChildNodes send the setChildNodes event for the whole DOM tree
// hierarchy of each nodes.
// We dispatch event in the reverse order: from the top level to the direct parents.
// We should dispatch a node only if it has never been sent.
fn dispatchSetChildNodes(cmd: anytype, dom_nodes: []const *DOMNode) !void {
    const arena = cmd.arena;
    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    const session_id = bc.session_id orelse return error.SessionIdNotLoaded;

    var parents: std.ArrayList(*Node) = .empty;
    for (dom_nodes) |dom_node| {
        var current = dom_node;
        while (true) {
            const parent_node = current._parent orelse break;

            const node = try bc.node_registry.register(parent_node);
            if (node.set_child_nodes_event) {
                break;
            }
            try parents.append(arena, node);
            current = parent_node;
        }
    }

    const plen = parents.items.len;
    if (plen == 0) {
        return;
    }

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
        const dom_parent = node.dom._parent orelse continue;

        // Retrieve the parent from the registry.
        const parent_node = try bc.node_registry.register(dom_parent);

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

fn querySelector(cmd: anytype) !void {
    const params = (try cmd.params(struct {
        nodeId: Node.Id,
        selector: []const u8,
    })) orelse return error.InvalidParams;

    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    const page = bc.session.currentPage() orelse return error.PageNotLoaded;

    const node = bc.node_registry.lookup_by_id.get(params.nodeId) orelse {
        return cmd.sendError(-32000, "Could not find node with given id", .{});
    };

    const element = try Selector.querySelector(node.dom, params.selector, page) orelse return error.NodeNotFoundForGivenId;
    const dom_node = element.asNode();
    const registered_node = try bc.node_registry.register(dom_node);

    // Dispatch setChildNodesEvents to inform the client of the subpart of node tree covering the results.
    var array = [1]*DOMNode{dom_node};
    try dispatchSetChildNodes(cmd, array[0..]);

    return cmd.sendResult(.{
        .nodeId = registered_node.id,
    }, .{});
}

fn querySelectorAll(cmd: anytype) !void {
    const params = (try cmd.params(struct {
        nodeId: Node.Id,
        selector: []const u8,
    })) orelse return error.InvalidParams;

    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    const page = bc.session.currentPage() orelse return error.PageNotLoaded;

    const node = bc.node_registry.lookup_by_id.get(params.nodeId) orelse {
        return cmd.sendError(-32000, "Could not find node with given id", .{});
    };

    const selected_nodes = try Selector.querySelectorAll(node.dom, params.selector, page);
    const nodes = selected_nodes._nodes;

    const node_ids = try cmd.arena.alloc(Node.Id, nodes.len);
    for (nodes, node_ids) |selected_node, *node_id| {
        node_id.* = (try bc.node_registry.register(selected_node)).id;
    }

    // Dispatch setChildNodesEvents to inform the client of the subpart of node tree covering the results.
    try dispatchSetChildNodes(cmd, nodes);

    return cmd.sendResult(.{
        .nodeIds = node_ids,
    }, .{});
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

    var ls: ?js.Local.Scope = null;
    defer if (ls) |*_ls| {
        _ls.deinit();
    };

    if (params.executionContextId) |context_id| blk: {
        ls = undefined;
        page.js.localScope(&ls.?);
        if (ls.?.local.debugContextId() == context_id) {
            break :blk;
        }
        // not the default scope, check the other ones
        for (bc.isolated_worlds.items) |*isolated_world| {
            ls.?.deinit();
            ls = null;

            const ctx = &(isolated_world.executor.context orelse return error.ContextNotFound);
            ls = undefined;
            ctx.localScope(&ls.?);
            if (ls.?.local.debugContextId() == context_id) {
                break :blk;
            }
        } else return error.ContextNotFound;
    } else {
        ls = undefined;
        page.js.localScope(&ls.?);
    }

    const input_node_id = params.nodeId orelse params.backendNodeId orelse return error.InvalidParam;
    const node = bc.node_registry.lookup_by_id.get(input_node_id) orelse return error.UnknownNode;

    // node._node is a *DOMNode we need this to be able to find its most derived type e.g. Node -> Element -> HTMLElement
    // So we use the Node.Union when retrieve the value from the environment
    const remote_object = try bc.inspector.getRemoteObject(
        &ls.?.local,
        params.objectGroup orelse "",
        node.dom,
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
        depth: i32 = 1,
        pierce: bool = false,
    })) orelse return error.InvalidParams;

    if (params.pierce) {
        log.warn(.not_implemented, "DOM.describeNode", .{ .param = "pierce" });
    }
    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;

    const node = try getNode(cmd.arena, bc, params.nodeId, params.backendNodeId, params.objectId);

    return cmd.sendResult(.{ .node = bc.nodeWriter(node, .{ .depth = params.depth }) }, .{});
}

// An array of quad vertices, x immediately followed by y for each point, points clock-wise.
// Note Y points downward
// We are assuming the start/endpoint is not repeated.
const Quad = [8]f64;

const BoxModel = struct {
    content: Quad,
    padding: Quad,
    border: Quad,
    margin: Quad,
    width: i32,
    height: i32,
    // shapeOutside: ?ShapeOutsideInfo,
};

fn rectToQuad(rect: *const DOMNode.Element.DOMRect) Quad {
    return Quad{
        rect._x,
        rect._y,
        rect._x + rect._width,
        rect._y,
        rect._x + rect._width,
        rect._y + rect._height,
        rect._x,
        rect._y + rect._height,
    };
}

fn scrollIntoViewIfNeeded(cmd: anytype) !void {
    const params = (try cmd.params(struct {
        nodeId: ?Node.Id = null,
        backendNodeId: ?u32 = null,
        objectId: ?[]const u8 = null,
        rect: ?DOMNode.Element.DOMRect = null,
    })) orelse return error.InvalidParams;
    // Only 1 of nodeId, backendNodeId, objectId may be set, but chrome just takes the first non-null

    // We retrieve the node to at least check if it exists and is valid.
    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    const node = try getNode(cmd.arena, bc, params.nodeId, params.backendNodeId, params.objectId);

    switch (node.dom._type) {
        .element => {},
        .document => {},
        .cdata => {},
        else => return error.NodeDoesNotHaveGeometry,
    }

    return cmd.sendResult(null, .{});
}

fn getNode(arena: Allocator, browser_context: anytype, node_id: ?Node.Id, backend_node_id: ?Node.Id, object_id: ?[]const u8) !*Node {
    const input_node_id = node_id orelse backend_node_id;
    if (input_node_id) |input_node_id_| {
        return browser_context.node_registry.lookup_by_id.get(input_node_id_) orelse return error.NodeNotFound;
    }
    if (object_id) |object_id_| {
        // Retrieve the object from which ever context it is in.
        const parser_node = try browser_context.inspector.getNodePtr(arena, object_id_);
        return try browser_context.node_registry.register(@ptrCast(@alignCast(parser_node)));
    }
    return error.MissingParams;
}

// https://chromedevtools.github.io/devtools-protocol/tot/DOM/#method-getContentQuads
// Related to: https://drafts.csswg.org/cssom-view/#the-geometryutils-interface
fn getContentQuads(cmd: anytype) !void {
    const params = (try cmd.params(struct {
        nodeId: ?Node.Id = null,
        backendNodeId: ?Node.Id = null,
        objectId: ?[]const u8 = null,
    })) orelse return error.InvalidParams;

    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    const page = bc.session.currentPage() orelse return error.PageNotLoaded;

    const node = try getNode(cmd.arena, bc, params.nodeId, params.backendNodeId, params.objectId);

    // TODO likely if the following CSS properties are set the quads should be empty
    // visibility: hidden
    // display: none

    const element = node.dom.is(DOMNode.Element) orelse return error.NodeIsNotAnElement;
    // TODO implement for document or text
    // Most likely document would require some hierachgy in the renderer. It is left unimplemented till we have a good example.
    // Text may be tricky, multiple quads in case of multiple lines? empty quads of text  = ""?
    // Elements like SVGElement may have multiple quads.

    const rect = try element.getBoundingClientRect(page);
    const quad = rectToQuad(rect);

    return cmd.sendResult(.{ .quads = &.{quad} }, .{});
}

fn getBoxModel(cmd: anytype) !void {
    const params = (try cmd.params(struct {
        nodeId: ?Node.Id = null,
        backendNodeId: ?u32 = null,
        objectId: ?[]const u8 = null,
    })) orelse return error.InvalidParams;

    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    const page = bc.session.currentPage() orelse return error.PageNotLoaded;

    const node = try getNode(cmd.arena, bc, params.nodeId, params.backendNodeId, params.objectId);

    // TODO implement for document or text
    const element = node.dom.is(DOMNode.Element) orelse return error.NodeIsNotAnElement;

    const rect = try element.getBoundingClientRect(page);
    const quad = rectToQuad(rect);
    const zero = [_]f64{0.0} ** 8;

    return cmd.sendResult(.{ .model = BoxModel{
        .content = quad,
        .padding = zero,
        .border = zero,
        .margin = zero,
        .width = @intFromFloat(rect._width),
        .height = @intFromFloat(rect._height),
    } }, .{});
}

fn requestChildNodes(cmd: anytype) !void {
    const params = (try cmd.params(struct {
        nodeId: Node.Id,
        depth: i32 = 1,
        pierce: bool = false,
    })) orelse return error.InvalidParams;

    if (params.depth == 0) return error.InvalidParams;
    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    const session_id = bc.session_id orelse return error.SessionIdNotLoaded;
    const node = bc.node_registry.lookup_by_id.get(params.nodeId) orelse {
        return error.InvalidNode;
    };

    try cmd.sendEvent("DOM.setChildNodes", .{
        .parentId = node.id,
        .nodes = bc.nodeWriter(node, .{ .depth = params.depth, .exclude_root = true }),
    }, .{
        .session_id = session_id,
    });

    return cmd.sendResult(null, .{});
}

fn getFrameOwner(cmd: anytype) !void {
    const params = (try cmd.params(struct {
        frameId: []const u8,
    })) orelse return error.InvalidParams;

    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    const target_id = bc.target_id orelse return error.TargetNotLoaded;
    if (std.mem.eql(u8, target_id, params.frameId) == false) {
        return cmd.sendError(-32000, "Frame with the given id does not belong to the target.", .{});
    }

    const page = bc.session.currentPage() orelse return error.PageNotLoaded;

    const node = try bc.node_registry.register(page.window._document.asNode());
    return cmd.sendResult(.{ .nodeId = node.id, .backendNodeId = node.id }, .{});
}

fn getOuterHTML(cmd: anytype) !void {
    const params = (try cmd.params(struct {
        nodeId: ?Node.Id = null,
        backendNodeId: ?Node.Id = null,
        objectId: ?[]const u8 = null,
        includeShadowDOM: bool = false,
    })) orelse return error.InvalidParams;

    if (params.includeShadowDOM) {
        log.warn(.not_implemented, "DOM.getOuterHTML", .{ .param = "includeShadowDOM" });
    }
    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    const page = bc.session.currentPage() orelse return error.PageNotLoaded;

    const node = try getNode(cmd.arena, bc, params.nodeId, params.backendNodeId, params.objectId);

    var aw = std.Io.Writer.Allocating.init(cmd.arena);
    try dump.deep(node.dom, .{}, &aw.writer, page);

    return cmd.sendResult(.{ .outerHTML = aw.written() }, .{});
}

fn requestNode(cmd: anytype) !void {
    const params = (try cmd.params(struct {
        objectId: []const u8,
    })) orelse return error.InvalidParams;

    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    const node = try getNode(cmd.arena, bc, null, null, params.objectId);

    return cmd.sendResult(.{ .nodeId = node.id }, .{});
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

    _ = try ctx.loadBrowserContext(.{ .id = "BID-A", .url = "cdp/dom1.html" });

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
        try ctx.expectSentResult(.{ .nodeIds = &.{ 1, 2 } }, .{ .id = 13 });

        // different fromIndex
        try ctx.processMessage(.{
            .id = 14,
            .method = "DOM.getSearchResults",
            .params = .{ .searchId = "0", .fromIndex = 1, .toIndex = 2 },
        });
        try ctx.expectSentResult(.{ .nodeIds = &.{2} }, .{ .id = 14 });

        // different toIndex
        try ctx.processMessage(.{
            .id = 15,
            .method = "DOM.getSearchResults",
            .params = .{ .searchId = "0", .fromIndex = 0, .toIndex = 1 },
        });
        try ctx.expectSentResult(.{ .nodeIds = &.{1} }, .{ .id = 15 });
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

test "cdp.dom: querySelector unknown search id" {
    var ctx = testing.context();
    defer ctx.deinit();

    _ = try ctx.loadBrowserContext(.{ .id = "BID-A", .url = "cdp/dom1.html" });

    try ctx.processMessage(.{
        .id = 9,
        .method = "DOM.querySelector",
        .params = .{ .nodeId = 99, .selector = "" },
    });
    try ctx.expectSentError(-32000, "Could not find node with given id", .{});

    try ctx.processMessage(.{
        .id = 9,
        .method = "DOM.querySelectorAll",
        .params = .{ .nodeId = 99, .selector = "" },
    });
    try ctx.expectSentError(-32000, "Could not find node with given id", .{});
}

test "cdp.dom: querySelector Node not found" {
    var ctx = testing.context();
    defer ctx.deinit();

    _ = try ctx.loadBrowserContext(.{ .id = "BID-A", .url = "cdp/dom1.html" });

    try ctx.processMessage(.{ // Hacky way to make sure nodeId 1 exists in the registry
        .id = 3,
        .method = "DOM.performSearch",
        .params = .{ .query = "p" },
    });
    try ctx.expectSentResult(.{ .searchId = "0", .resultCount = 2 }, .{ .id = 3 });

    try testing.expectError(error.NodeNotFoundForGivenId, ctx.processMessage(.{
        .id = 4,
        .method = "DOM.querySelector",
        .params = .{ .nodeId = 1, .selector = "a" },
    }));

    try ctx.processMessage(.{
        .id = 5,
        .method = "DOM.querySelectorAll",
        .params = .{ .nodeId = 1, .selector = "a" },
    });
    try ctx.expectSentResult(.{ .nodeIds = &[_]u32{} }, .{ .id = 5 });
}

test "cdp.dom: querySelector Nodes found" {
    var ctx = testing.context();
    defer ctx.deinit();

    _ = try ctx.loadBrowserContext(.{ .id = "BID-A", .url = "cdp/dom2.html" });

    try ctx.processMessage(.{ // Hacky way to make sure nodeId 1 exists in the registry
        .id = 3,
        .method = "DOM.performSearch",
        .params = .{ .query = "div" },
    });
    try ctx.expectSentResult(.{ .searchId = "0", .resultCount = 1 }, .{ .id = 3 });

    try ctx.processMessage(.{
        .id = 4,
        .method = "DOM.querySelector",
        .params = .{ .nodeId = 1, .selector = "p" },
    });
    try ctx.expectSentEvent("DOM.setChildNodes", null, .{});
    try ctx.expectSentResult(.{ .nodeId = 7 }, .{ .id = 4 });

    try ctx.processMessage(.{
        .id = 5,
        .method = "DOM.querySelectorAll",
        .params = .{ .nodeId = 1, .selector = "p" },
    });
    try ctx.expectSentEvent("DOM.setChildNodes", null, .{});
    try ctx.expectSentResult(.{ .nodeIds = &.{7} }, .{ .id = 5 });
}

test "cdp.dom: getBoxModel" {
    var ctx = testing.context();
    defer ctx.deinit();

    _ = try ctx.loadBrowserContext(.{ .id = "BID-A", .url = "cdp/dom2.html" });

    try ctx.processMessage(.{ // Hacky way to make sure nodeId 1 exists in the registry
        .id = 3,
        .method = "DOM.getDocument",
    });

    try ctx.processMessage(.{
        .id = 4,
        .method = "DOM.querySelector",
        .params = .{ .nodeId = 1, .selector = "p" },
    });
    try ctx.expectSentResult(.{ .nodeId = 3 }, .{ .id = 4 });

    try ctx.processMessage(.{
        .id = 5,
        .method = "DOM.getBoxModel",
        .params = .{ .nodeId = 6 },
    });
    try ctx.expectSentResult(.{ .model = BoxModel{
        .content = Quad{ 10.0, 10.0, 15.0, 10.0, 15.0, 15.0, 10.0, 15.0 },
        .padding = Quad{ 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0 },
        .border = Quad{ 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0 },
        .margin = Quad{ 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0 },
        .width = 5,
        .height = 5,
    } }, .{ .id = 5 });
}
