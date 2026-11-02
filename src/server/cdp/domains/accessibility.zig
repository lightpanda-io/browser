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

const id = @import("../id.zig");
const CDP = @import("../CDP.zig");

const AXNode = @import("../AXNode.zig");
const dom = @import("dom.zig");
const Frame = @import("../../../browser/Frame.zig");
const NodeRegistry = @import("../../../NodeRegistry.zig");

pub fn processMessage(cmd: *CDP.Command) !void {
    const action = std.meta.stringToEnum(enum {
        enable,
        disable,
        getFullAXTree,
        getPartialAXTree,
        queryAXTree,
        getRootAXNode,
        getAXNodeAndAncestors,
        getChildAXNodes,
    }, cmd.input.action) orelse return error.UnknownMethod;

    switch (action) {
        .enable => return enable(cmd),
        .disable => return disable(cmd),
        .getFullAXTree => return getFullAXTree(cmd),
        .getPartialAXTree => return getPartialAXTree(cmd),
        .queryAXTree => return queryAXTree(cmd),
        .getRootAXNode => return getRootAXNode(cmd),
        .getAXNodeAndAncestors => return getAXNodeAndAncestors(cmd),
        .getChildAXNodes => return getChildAXNodes(cmd),
    }
}

fn enable(cmd: *CDP.Command) !void {
    return cmd.sendResult(null, .{});
}

fn disable(cmd: *CDP.Command) !void {
    return cmd.sendResult(null, .{});
}

fn getFullAXTree(cmd: *CDP.Command) !void {
    const Params = struct {
        depth: ?i32 = null,
        frameId: ?[]const u8 = null,
    };
    const params: Params = (try cmd.params(Params)) orelse .{};

    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    const frame = try findFrame(cmd, bc, params.frameId) orelse return;

    const node = try bc.node_registry.register(frame.window._document.asNode());
    return sendAXNodes(cmd, bc, frame, node, .{
        .depth = params.depth orelse 0,
    });
}

fn getRootAXNode(cmd: *CDP.Command) !void {
    const Params = struct {
        frameId: ?[]const u8 = null,
    };
    const params: Params = (try cmd.params(Params)) orelse .{};

    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    const frame = try findFrame(cmd, bc, params.frameId) orelse return;

    const node = try bc.node_registry.register(frame.window._document.asNode());
    return sendAXNodes(cmd, bc, frame, node, .{
        .scope = .bare_node,
    });
}

fn getAXNodeAndAncestors(cmd: *CDP.Command) !void {
    const Params = struct {
        nodeId: ?u32 = null,
        backendNodeId: ?u32 = null,
        objectId: ?[]const u8 = null,
    };
    const params: Params = (try cmd.params(Params)) orelse .{};

    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    const node = try dom.getNode(cmd.arena, bc, cmd.input.session_id, params.nodeId, params.backendNodeId, params.objectId);

    return sendAXNodes(cmd, bc, bc.mainFrame() orelse return error.FrameNotLoaded, node, .{
        .scope = .ancestors,
    });
}

fn getChildAXNodes(cmd: *CDP.Command) !void {
    const Params = struct {
        id: []const u8,
        frameId: ?[]const u8 = null,
    };
    const params = (try cmd.params(Params)) orelse return error.InvalidParams;

    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    const frame = try findFrame(cmd, bc, params.frameId) orelse return;

    // The AXNodeId is our node registry id, unique across frames: a given
    // frame only has to own the node.
    const ax_id = std.fmt.parseInt(u32, params.id, 10) catch return error.InvalidParams;
    const owner_frame: ?*Frame = if (params.frameId != null) frame else null;

    // A ListMarker has no DOM node and no children. It's checked like its
    // <li>, and is gone once the <li> no longer has one.
    if (bc.node_registry.listMarkerOwner(ax_id)) |li| {
        if (!AXNode.hasListMarker(li.dom)) {
            return error.NodeNotFound;
        }
        try checkOwnerFrame(li, owner_frame);
        return cmd.sendResult(.{ .nodes = [0]u32{} }, .{});
    }

    const node = bc.node_registry.lookup_by_id.get(ax_id) orelse return error.NodeNotFound;
    try checkOwnerFrame(node, owner_frame);
    return sendAXNodes(cmd, bc, frame, node, .{
        .scope = .children,
    });
}

// Whether `frame`, when given, owns `node`. Without one, a frameless node
// fails later, in axnodeWriter, like in the other methods.
fn checkOwnerFrame(node: *const NodeRegistry.Node, frame: ?*Frame) !void {
    const f = frame orelse return;
    const owner = node.dom.ownerFrame(f) orelse return error.InvalidNodeId;
    if (owner != f) {
        return error.NodeNotFound;
    }
}

// Reply with the AX nodes `opts` selects around `node`: a `nodes` list, or a
// single `node` for the .bare_node scope.
fn sendAXNodes(cmd: *CDP.Command, bc: *CDP.BrowserContext, frame: *Frame, node: *const NodeRegistry.Node, opts: AXNode.Writer.Opts) !void {
    const temp_arena = try frame.getArena(.medium, "AXNode");
    defer temp_arena.release();

    const writer = try bc.axnodeWriter(temp_arena, node, opts);
    if (opts.scope == .bare_node) {
        return cmd.sendResult(.{ .node = writer }, .{});
    }
    return cmd.sendResult(.{ .nodes = writer }, .{});
}

// The frame `frame_id` names, or the main frame when null. Returns null after
// replying with an error when the frame isn't part of this target.
fn findFrame(cmd: *CDP.Command, bc: *CDP.BrowserContext, frame_id: ?[]const u8) !?*Frame {
    const frame_id_ = frame_id orelse {
        return bc.mainFrame() orelse return error.FrameNotLoaded;
    };
    return bc.session.findFrameByFrameId(try id.parseFrameId(frame_id_)) orelse {
        try cmd.sendError(-32000, "Frame with the given id does not belong to the target.", .{});
        return null;
    };
}

fn queryAXTree(cmd: *CDP.Command) !void {
    const Params = struct {
        nodeId: ?u32 = null,
        backendNodeId: ?u32 = null,
        objectId: ?[]const u8 = null,
        accessibleName: ?[]const u8 = null,
        role: ?[]const u8 = null,
    };
    const params: Params = (try cmd.params(Params)) orelse .{};

    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    const node = try dom.getNode(cmd.arena, bc, cmd.input.session_id, params.nodeId, params.backendNodeId, params.objectId);

    return sendAXNodes(cmd, bc, bc.mainFrame() orelse return error.FrameNotLoaded, node, .{
        .filter = .{
            .accessible_name = params.accessibleName,
            .role = params.role,
        },
    });
}

fn getPartialAXTree(cmd: *CDP.Command) !void {
    const Params = struct {
        nodeId: ?u32 = null,
        backendNodeId: ?u32 = null,
        objectId: ?[]const u8 = null,
        fetchRelatives: ?bool = null,
    };
    const params: Params = (try cmd.params(Params)) orelse .{};

    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    const node = try dom.getNode(cmd.arena, bc, cmd.input.session_id, params.nodeId, params.backendNodeId, params.objectId);

    return sendAXNodes(cmd, bc, bc.mainFrame() orelse return error.FrameNotLoaded, node, .{
        // Defaults to true, like Chrome.
        .scope = if (params.fetchRelatives orelse true) .relatives else .node,
    });
}

const testing = @import("../testing.zig");

test "cdp.accessibility: queryAXTree requires nodeId, backendNodeId or objectId" {
    var ctx = try testing.context();
    defer ctx.deinit();

    _ = try ctx.loadBrowserContext(.{ .id = "BID-A", .url = "cdp/ax_tree.html" });

    // Pass filters but no node identifier — dom.getNode returns MissingParams.
    try ctx.processMessage(.{
        .id = 1,
        .method = "Accessibility.queryAXTree",
        .params = .{ .role = "button" },
    });
    try ctx.expectSentError(-31998, "MissingParams", .{ .id = 1 });
}

test "cdp.accessibility: queryAXTree with unknown nodeId returns error" {
    var ctx = try testing.context();
    defer ctx.deinit();

    _ = try ctx.loadBrowserContext(.{ .id = "BID-A", .url = "cdp/ax_tree.html" });

    try ctx.processMessage(.{
        .id = 1,
        .method = "Accessibility.queryAXTree",
        .params = .{ .nodeId = 99999 },
    });
    try ctx.expectSentError(-31998, "NodeNotFound", .{ .id = 1 });
}

test "cdp.accessibility: getPartialAXTree requires nodeId, backendNodeId or objectId" {
    var ctx = try testing.context();
    defer ctx.deinit();

    _ = try ctx.loadBrowserContext(.{ .id = "BID-A", .url = "cdp/ax_tree.html" });

    // Params present but no node identifier — dom.getNode returns MissingParams.
    try ctx.processMessage(.{
        .id = 1,
        .method = "Accessibility.getPartialAXTree",
        .params = .{ .fetchRelatives = false },
    });
    try ctx.expectSentError(-31998, "MissingParams", .{ .id = 1 });
}

test "cdp.accessibility: getPartialAXTree with unknown nodeId returns error" {
    var ctx = try testing.context();
    defer ctx.deinit();

    _ = try ctx.loadBrowserContext(.{ .id = "BID-A", .url = "cdp/ax_tree.html" });

    try ctx.processMessage(.{
        .id = 1,
        .method = "Accessibility.getPartialAXTree",
        .params = .{ .nodeId = 99999, .fetchRelatives = false },
    });
    try ctx.expectSentError(-31998, "NodeNotFound", .{ .id = 1 });
}

test "cdp.accessibility: getPartialAXTree rejects a frameless node" {
    var ctx = try testing.context();
    defer ctx.deinit();

    _ = try ctx.loadBrowserContext(.{ .id = "BID-A", .url = "cdp/ax_tree.html" });

    try ctx.processMessage(.{ .id = 1, .method = "Runtime.evaluate", .params = .{
        .expression = "new DOMParser().parseFromString('<button>b</button>', 'text/html').body",
    } });
    const object_id = try evaluatedObjectId(&ctx, 1);

    try ctx.processMessage(.{
        .id = 2,
        .method = "Accessibility.getPartialAXTree",
        .params = .{ .objectId = object_id, .fetchRelatives = false },
    });
    try ctx.expectSentError(-31998, "InvalidNodeId", .{ .id = 2 });
}

test "cdp.accessibility: getRootAXNode returns the document node" {
    var ctx = try testing.context();
    defer ctx.deinit();

    _ = try ctx.loadBrowserContext(.{ .id = "BID-A", .url = "cdp/ax_tree.html" });

    try ctx.processMessage(.{ .id = 1, .method = "Accessibility.getRootAXNode" });
    const node = (try sentResult(&ctx, 1)).get("node").?.object;
    try testing.expectEqual("RootWebArea", axRole(node));
    try testing.expectEqual("AX Tree Fixture", node.get("name").?.object.get("value").?.string);
    try testing.expect(node.get("childIds").?.array.items.len > 0);
    try testing.expectEqual(null, node.get("parentId"));

    try ctx.processMessage(.{ .id = 2, .method = "Accessibility.getRootAXNode", .params = .{ .frameId = "FID-0000009999" } });
    try ctx.expectSentError(-32000, "Frame with the given id does not belong to the target.", .{ .id = 2 });
}

test "cdp.accessibility: getAXNodeAndAncestors returns the node then its ancestors" {
    var ctx = try testing.context();
    defer ctx.deinit();

    _ = try ctx.loadBrowserContext(.{ .id = "BID-A", .url = "cdp/ax_tree.html" });

    try ctx.processMessage(.{ .id = 1, .method = "Runtime.evaluate", .params = .{
        .expression = "document.getElementById('visible-para')",
    } });
    const object_id = try evaluatedObjectId(&ctx, 1);

    try ctx.processMessage(.{
        .id = 2,
        .method = "Accessibility.getAXNodeAndAncestors",
        .params = .{ .objectId = object_id },
    });
    const nodes = (try sentResult(&ctx, 2)).get("nodes").?.array.items;
    // p, main, body, html, document
    try testing.expectEqual(5, nodes.len);
    try testing.expectEqual("paragraph", axRole(nodes[0].object));
    try testing.expectEqual("main", axRole(nodes[1].object));
    try testing.expectEqual("RootWebArea", axRole(nodes[4].object));
    for (nodes[0 .. nodes.len - 1], nodes[1..]) |child, parent| {
        try testing.expectEqual(parent.object.get("nodeId").?.string, child.object.get("parentId").?.string);
    }
}

test "cdp.accessibility: getChildAXNodes follows ignored children" {
    var ctx = try testing.context();
    defer ctx.deinit();

    _ = try ctx.loadBrowserContext(.{ .id = "BID-A", .url = "cdp/ax_tree.html" });

    // <html> and <body> are ignored, so the root's children run down to
    // <main>, as in Chrome, though the root only lists <html>.
    try ctx.processMessage(.{ .id = 1, .method = "Accessibility.getRootAXNode" });
    const root = (try sentResult(&ctx, 1)).get("node").?.object;
    const root_id = root.get("nodeId").?.string;
    try testing.expectEqual(1, root.get("childIds").?.array.items.len);

    try ctx.processMessage(.{ .id = 2, .method = "Accessibility.getChildAXNodes", .params = .{ .id = root_id } });
    const top = (try sentResult(&ctx, 2)).get("nodes").?.array.items;
    try testing.expectEqual(3, top.len);
    try testing.expectEqual(true, top[0].object.get("ignored").?.bool);
    try testing.expectEqual(true, top[1].object.get("ignored").?.bool);
    try testing.expectEqual("main", axRole(top[2].object));
    try testing.expectEqual(root_id, top[0].object.get("parentId").?.string);
    for (top[1..], top[0..2]) |n, parent| {
        try testing.expectEqual(parent.object.get("nodeId").?.string, n.object.get("parentId").?.string);
    }

    try ctx.processMessage(.{ .id = 3, .method = "Runtime.evaluate", .params = .{
        .expression = "document.querySelector('main')",
    } });
    const object_id = try evaluatedObjectId(&ctx, 3);
    try ctx.processMessage(.{ .id = 4, .method = "Accessibility.getPartialAXTree", .params = .{
        .objectId = object_id,
        .fetchRelatives = false,
    } });
    const main = (try sentResult(&ctx, 4)).get("nodes").?.array.items[0].object;
    const main_id = main.get("nodeId").?.string;
    const child_ids = main.get("childIds").?.array.items;

    try ctx.processMessage(.{ .id = 5, .method = "Accessibility.getChildAXNodes", .params = .{ .id = main_id } });
    const nodes = (try sentResult(&ctx, 5)).get("nodes").?.array.items;
    // Every childId, in order, with nodes from under ignored children in
    // between: the link inside the visibility:hidden <div>.
    var listed: usize = 0;
    var saw_link = false;
    for (nodes) |n| {
        const node_id = n.object.get("nodeId").?.string;
        if (listed < child_ids.len and std.mem.eql(u8, node_id, child_ids[listed].string)) {
            listed += 1;
            try testing.expectEqual(main_id, n.object.get("parentId").?.string);
        } else if (std.mem.eql(u8, axRole(n.object), "link")) {
            try testing.expectEqual("visible-in-hidden", n.object.get("name").?.object.get("value").?.string);
            saw_link = true;
        }
    }
    try testing.expectEqual(child_ids.len, listed);
    try testing.expect(saw_link);

    try ctx.processMessage(.{ .id = 6, .method = "Accessibility.getChildAXNodes", .params = .{ .id = "99999" } });
    try ctx.expectSentError(-31998, "NodeNotFound", .{ .id = 6 });
}

test "cdp.accessibility: getPartialAXTree fetchRelatives" {
    var ctx = try testing.context();
    defer ctx.deinit();

    _ = try ctx.loadBrowserContext(.{ .id = "BID-A", .url = "cdp/ax_tree.html" });

    try ctx.processMessage(.{ .id = 1, .method = "Runtime.evaluate", .params = .{
        .expression = "document.getElementById('wrap-label')",
    } });
    const object_id = try evaluatedObjectId(&ctx, 1);

    // Without relatives, only the node itself.
    try ctx.processMessage(.{ .id = 2, .method = "Accessibility.getPartialAXTree", .params = .{
        .objectId = object_id,
        .fetchRelatives = false,
    } });
    const alone = (try sentResult(&ctx, 2)).get("nodes").?.array.items;
    try testing.expectEqual(1, alone.len);
    const label_id = alone[0].object.get("nodeId").?.string;

    // fetchRelatives defaults to true. Like Chrome: the node, its children,
    // then its ancestors up to the root, and no siblings.
    try ctx.processMessage(.{ .id = 3, .method = "Accessibility.getPartialAXTree", .params = .{
        .objectId = object_id,
    } });
    const nodes = (try sentResult(&ctx, 3)).get("nodes").?.array.items;
    try testing.expectEqual(label_id, nodes[0].object.get("nodeId").?.string);
    const main_at = for (nodes, 0..) |n, i| {
        if (std.mem.eql(u8, axRole(n.object), "main")) break i;
    } else return error.MainNotFound;

    var saw_textbox = false;
    for (nodes[1..main_at]) |n| {
        try testing.expectEqual(label_id, n.object.get("parentId").?.string);
        if (std.mem.eql(u8, axRole(n.object), "textbox")) saw_textbox = true;
    }
    try testing.expect(saw_textbox);
    try testing.expectEqual(nodes[main_at].object.get("nodeId").?.string, nodes[0].object.get("parentId").?.string);
    for (nodes[main_at .. nodes.len - 1], nodes[main_at + 1 ..]) |child, parent| {
        try testing.expectEqual(parent.object.get("nodeId").?.string, child.object.get("parentId").?.string);
    }
    try testing.expectEqual("RootWebArea", axRole(nodes[nodes.len - 1].object));

    // An ignored node comes without its children: <body>, <html>, the root.
    try ctx.processMessage(.{ .id = 4, .method = "Runtime.evaluate", .params = .{
        .expression = "document.body",
    } });
    const body = try evaluatedObjectId(&ctx, 4);
    try ctx.processMessage(.{ .id = 5, .method = "Accessibility.getPartialAXTree", .params = .{ .objectId = body } });
    const body_nodes = (try sentResult(&ctx, 5)).get("nodes").?.array.items;
    try testing.expectEqual(3, body_nodes.len);
    try testing.expectEqual(true, body_nodes[0].object.get("ignored").?.bool);
    try testing.expectEqual("RootWebArea", axRole(body_nodes[2].object));
}

test "cdp.accessibility: getChildAXNodes lists an li's ListMarker first" {
    var ctx = try testing.context();
    defer ctx.deinit();

    _ = try ctx.loadBrowserContext(.{ .id = "BID-A", .url = "cdp/ax_relatives.html" });

    const li_id = try axNodeIdOf(&ctx, 1, "document.getElementById('item')");

    try ctx.processMessage(.{ .id = 3, .method = "Accessibility.getChildAXNodes", .params = .{ .id = li_id } });
    const nodes = (try sentResult(&ctx, 3)).get("nodes").?.array.items;
    try testing.expectEqual(2, nodes.len);
    const marker = nodes[0].object;
    try testing.expectEqual("ListMarker", axRole(marker));
    try testing.expectEqual("1. ", marker.get("name").?.object.get("value").?.string);
    try testing.expectEqual(li_id, marker.get("parentId").?.string);
    try testing.expectEqual("StaticText", axRole(nodes[1].object));
    const marker_id = marker.get("nodeId").?.string;

    // The li lists the marker, and its id doesn't change.
    try ctx.processMessage(.{ .id = 5, .method = "Accessibility.getAXNodeAndAncestors", .params = .{ .nodeId = try std.fmt.parseInt(u32, li_id, 10) } });
    const li = (try sentResult(&ctx, 5)).get("nodes").?.array.items[0].object;
    try testing.expectEqual(marker_id, li.get("childIds").?.array.items[0].string);

    // A marker has no children.
    try ctx.processMessage(.{ .id = 6, .method = "Accessibility.getChildAXNodes", .params = .{ .id = marker_id } });
    try testing.expectEqual(0, (try sentResult(&ctx, 6)).get("nodes").?.array.items.len);

    // It belongs to its <li>'s frame, not the iframe's.
    try ctx.processMessage(.{ .id = 7, .method = "Accessibility.getChildAXNodes", .params = .{
        .id = marker_id,
        .frameId = "FID-0000000002",
    } });
    try ctx.expectSentError(-31998, "NodeNotFound", .{ .id = 7 });

    // Out of its list, the li has no marker.
    try ctx.processMessage(.{ .id = 8, .method = "Runtime.evaluate", .params = .{
        .expression = "document.body.append(document.getElementById('item'))",
    } });
    _ = try sentResult(&ctx, 8);
    try ctx.processMessage(.{ .id = 9, .method = "Accessibility.getChildAXNodes", .params = .{ .id = marker_id } });
    try ctx.expectSentError(-31998, "NodeNotFound", .{ .id = 9 });

    // The frame must own the node.
    try ctx.processMessage(.{ .id = 4, .method = "Accessibility.getChildAXNodes", .params = .{
        .id = li_id,
        .frameId = "FID-0000009999",
    } });
    try ctx.expectSentError(-32000, "Frame with the given id does not belong to the target.", .{ .id = 4 });
}

test "cdp.accessibility: getFullAXTree depth cuts off an li's ListMarker" {
    var ctx = try testing.context();
    defer ctx.deinit();

    _ = try ctx.loadBrowserContext(.{ .id = "BID-A", .url = "cdp/ax_relatives.html" });

    // document, html, body, ol, li (depth 4), then its marker and text.
    try ctx.processMessage(.{ .id = 1, .method = "Accessibility.getFullAXTree", .params = .{ .depth = 4 } });
    var saw_li = false;
    for ((try sentResult(&ctx, 1)).get("nodes").?.array.items) |n| {
        const role = axRole(n.object);
        try testing.expect(!std.mem.eql(u8, role, "ListMarker"));
        if (std.mem.eql(u8, role, "listitem")) saw_li = true;
    }
    try testing.expect(saw_li);

    // A negative depth is no limit, for the marker too.
    inline for (.{ 5, -1 }, 2..) |depth, msg_id| {
        try ctx.processMessage(.{ .id = msg_id, .method = "Accessibility.getFullAXTree", .params = .{ .depth = depth } });
        var saw_marker = false;
        for ((try sentResult(&ctx, msg_id)).get("nodes").?.array.items) |n| {
            if (std.mem.eql(u8, axRole(n.object), "ListMarker")) saw_marker = true;
        }
        try testing.expect(saw_marker);
    }
}

test "cdp.accessibility: a node outside the AX tree hangs off its nearest ancestor" {
    var ctx = try testing.context();
    defer ctx.deinit();

    _ = try ctx.loadBrowserContext(.{ .id = "BID-A", .url = "cdp/ax_relatives.html" });

    // Under display:none: the node, then <body> and up.
    try ctx.processMessage(.{ .id = 1, .method = "Runtime.evaluate", .params = .{
        .expression = "document.getElementById('in-gone')",
    } });
    const gone = try evaluatedObjectId(&ctx, 1);
    try ctx.processMessage(.{ .id = 2, .method = "Accessibility.getAXNodeAndAncestors", .params = .{ .objectId = gone } });
    const chain = (try sentResult(&ctx, 2)).get("nodes").?.array.items;
    try testing.expectEqual(4, chain.len);
    try expectNotRendered(chain[0].object);
    try expectChain(chain);
    const body_id = chain[1].object.get("nodeId").?.string;

    // Alone, it keeps its parent.
    try ctx.processMessage(.{ .id = 3, .method = "Accessibility.getPartialAXTree", .params = .{
        .objectId = gone,
        .fetchRelatives = false,
    } });
    const alone = (try sentResult(&ctx, 3)).get("nodes").?.array.items;
    try testing.expectEqual(1, alone.len);
    try testing.expectEqual(body_id, alone[0].object.get("parentId").?.string);

    // <title>: <head> exposes no children.
    try ctx.processMessage(.{ .id = 4, .method = "Runtime.evaluate", .params = .{
        .expression = "document.querySelector('title')",
    } });
    const title = try evaluatedObjectId(&ctx, 4);
    try ctx.processMessage(.{ .id = 5, .method = "Accessibility.getPartialAXTree", .params = .{ .objectId = title } });
    const nodes = (try sentResult(&ctx, 5)).get("nodes").?.array.items;
    try expectNotRendered(nodes[0].object);
    try expectChain(nodes);

    try ctx.processMessage(.{ .id = 6, .method = "Accessibility.getChildAXNodes", .params = .{
        .id = nodes[0].object.get("nodeId").?.string,
    } });
    try testing.expectEqual(0, (try sentResult(&ctx, 6)).get("nodes").?.array.items.len);
}

test "cdp.accessibility: a node under inert or aria-hidden" {
    var ctx = try testing.context();
    defer ctx.deinit();

    _ = try ctx.loadBrowserContext(.{ .id = "BID-A", .url = "cdp/ax_tree.html" });

    // As in Chrome: the node, then <main> (not the hiding <div>) and up.
    inline for (.{ "under-inert", "p-under-aria-hidden" }, 0..) |dom_id, i| {
        try ctx.processMessage(.{ .id = 2 * i + 1, .method = "Runtime.evaluate", .params = .{
            .expression = "document.getElementById('" ++ dom_id ++ "')",
        } });
        const object_id = try evaluatedObjectId(&ctx, 2 * i + 1);
        try ctx.processMessage(.{ .id = 2 * i + 2, .method = "Accessibility.getPartialAXTree", .params = .{ .objectId = object_id } });
        const nodes = (try sentResult(&ctx, 2 * i + 2)).get("nodes").?.array.items;
        try testing.expectEqual(5, nodes.len);
        try expectNotRendered(nodes[0].object);
        try testing.expectEqual("main", axRole(nodes[1].object));
        try expectChain(nodes);
    }
}

test "cdp.accessibility: ancestors with names computed from content" {
    var ctx = try testing.context();
    defer ctx.deinit();

    _ = try ctx.loadBrowserContext(.{ .id = "BID-A", .url = "cdp/ax_relatives.html" });

    try ctx.processMessage(.{ .id = 1, .method = "Runtime.evaluate", .params = .{
        .expression = "document.getElementById('deep')",
    } });
    const deep = try evaluatedObjectId(&ctx, 1);

    // b, a, h2, body, html, document: the link's long name is computed
    // while the ancestors are written.
    try ctx.processMessage(.{ .id = 2, .method = "Accessibility.getAXNodeAndAncestors", .params = .{ .objectId = deep } });
    const nodes = (try sentResult(&ctx, 2)).get("nodes").?.array.items;
    try testing.expectEqual(6, nodes.len);
    try testing.expectEqual("link", axRole(nodes[1].object));
    try testing.expectEqual("heading", axRole(nodes[2].object));
    try expectChain(nodes);

    try ctx.processMessage(.{ .id = 3, .method = "Accessibility.getPartialAXTree", .params = .{ .objectId = deep } });
    const relatives = (try sentResult(&ctx, 3)).get("nodes").?.array.items;
    try testing.expectEqual("RootWebArea", axRole(relatives[relatives.len - 1].object));
}

test "cdp.accessibility: an svg is listed in its parent's childIds" {
    var ctx = try testing.context();
    defer ctx.deinit();

    _ = try ctx.loadBrowserContext(.{ .id = "BID-A", .url = "cdp/ax_relatives.html" });

    const svg_id = try axNodeIdOf(&ctx, 1, "document.getElementById('pic')");
    try ctx.processMessage(.{ .id = 3, .method = "Accessibility.getAXNodeAndAncestors", .params = .{ .nodeId = try std.fmt.parseInt(u32, svg_id, 10) } });
    const nodes = (try sentResult(&ctx, 3)).get("nodes").?.array.items;
    try testing.expectEqual(svg_id, nodes[0].object.get("nodeId").?.string);
    const body = nodes[1].object;
    try testing.expectEqual(body.get("nodeId").?.string, nodes[0].object.get("parentId").?.string);

    var listed = false;
    for (body.get("childIds").?.array.items) |cid| {
        if (std.mem.eql(u8, cid.string, svg_id)) listed = true;
    }
    try testing.expect(listed);
}

test "cdp.accessibility: an iframe's tree is its own" {
    var ctx = try testing.context();
    defer ctx.deinit();

    _ = try ctx.loadBrowserContext(.{ .id = "BID-A", .url = "cdp/ax_relatives.html" });

    try ctx.processMessage(.{ .id = 1, .method = "Runtime.evaluate", .params = .{
        .expression = "document.getElementById('frame').contentDocument.getElementById('inner')",
    } });
    const object_id = try evaluatedObjectId(&ctx, 1);

    // The ancestors stop at the iframe's document, the root of its frame's
    // tree, as getFullAXTree for that frame has it.
    try ctx.processMessage(.{ .id = 2, .method = "Accessibility.getAXNodeAndAncestors", .params = .{ .objectId = object_id } });
    const nodes = (try sentResult(&ctx, 2)).get("nodes").?.array.items;
    // button, body, html, document
    try testing.expectEqual(4, nodes.len);
    try testing.expectEqual("button", axRole(nodes[0].object));
    try testing.expectEqual("RootWebArea", axRole(nodes[3].object));
    for (nodes[0 .. nodes.len - 1], nodes[1..]) |child, parent| {
        try testing.expectEqual(parent.object.get("nodeId").?.string, child.object.get("parentId").?.string);
    }
    try testing.expectEqual(null, nodes[3].object.get("parentId"));

    // The main frame doesn't own the iframe's nodes.
    try ctx.processMessage(.{ .id = 4, .method = "Accessibility.getChildAXNodes", .params = .{
        .id = nodes[1].object.get("nodeId").?.string,
        .frameId = "FID-0000000001",
    } });
    try ctx.expectSentError(-31998, "NodeNotFound", .{ .id = 4 });

    // And the <iframe> has no AX children in its parent's tree: every
    // childId getFullAXTree lists is in its response.
    try ctx.processMessage(.{ .id = 5, .method = "Accessibility.getFullAXTree" });
    const tree = (try sentResult(&ctx, 5)).get("nodes").?.array.items;
    var ids: std.StringHashMapUnmanaged(void) = .empty;
    defer ids.deinit(testing.allocator);
    for (tree) |n| {
        try ids.put(testing.allocator, n.object.get("nodeId").?.string, {});
    }
    for (tree) |n| {
        for (n.object.get("childIds").?.array.items) |cid| {
            try testing.expect(ids.contains(cid.string));
        }
    }
}

fn expectNotRendered(node: std.json.ObjectMap) !void {
    try testing.expectEqual("none", axRole(node));
    try testing.expectEqual(true, node.get("ignored").?.bool);
    try testing.expectEqual("notRendered", node.get("ignoredReasons").?.array.items[0].object.get("name").?.string);
    try testing.expectEqual(0, node.get("childIds").?.array.items.len);
}

// `nodes` is a node then each ancestor up to a root.
fn expectChain(nodes: []const std.json.Value) !void {
    for (nodes[0 .. nodes.len - 1], nodes[1..]) |child, parent| {
        try testing.expectEqual(parent.object.get("nodeId").?.string, child.object.get("parentId").?.string);
    }
    const root = nodes[nodes.len - 1].object;
    try testing.expectEqual("RootWebArea", axRole(root));
    try testing.expectEqual(null, root.get("parentId"));
}

// The AXNodeId of the node `expression` evaluates to. Uses message ids
// `msg_id` and `msg_id + 1`.
fn axNodeIdOf(ctx: *testing.TestContext, msg_id: i64, expression: []const u8) ![]const u8 {
    try ctx.processMessage(.{ .id = msg_id, .method = "Runtime.evaluate", .params = .{ .expression = expression } });
    const object_id = try evaluatedObjectId(ctx, msg_id);
    try ctx.processMessage(.{ .id = msg_id + 1, .method = "Accessibility.getPartialAXTree", .params = .{
        .objectId = object_id,
        .fetchRelatives = false,
    } });
    return (try sentResult(ctx, msg_id + 1)).get("nodes").?.array.items[0].object.get("nodeId").?.string;
}

fn axRole(node: std.json.ObjectMap) []const u8 {
    return node.get("role").?.object.get("value").?.string;
}

// The result of the response to `msg_id`.
fn sentResult(ctx: *testing.TestContext, msg_id: i64) !std.json.ObjectMap {
    var i: usize = 0;
    while (try ctx.getSentMessage(i)) |msg| : (i += 1) {
        const obj = switch (msg) {
            .object => |o| o,
            else => continue,
        };
        const id_value = obj.get("id") orelse continue;
        if (id_value != .integer or id_value.integer != msg_id) {
            continue;
        }
        const result = obj.get("result") orelse return error.NoResult;
        return result.object;
    }
    return error.MessageNotFound;
}

// The result.result.objectId of the Runtime.evaluate response to `msg_id`.
fn evaluatedObjectId(ctx: *testing.TestContext, msg_id: i64) ![]const u8 {
    const remote = (try sentResult(ctx, msg_id)).get("result") orelse return error.NoRemoteObject;
    const object_id = remote.object.get("objectId") orelse return error.NoObjectId;
    return object_id.string;
}
