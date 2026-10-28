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

    // The AXNodeId is our node registry id, unique across frames: the frame
    // only has to own the node.
    const ax_id = std.fmt.parseInt(u32, params.id, 10) catch return error.InvalidParams;
    const node = bc.node_registry.lookup_by_id.get(ax_id) orelse {
        return getListMarkerChildren(cmd, bc, frame, params.frameId != null, ax_id);
    };
    // A frameless node fails in axnodeWriter, like in the other methods.
    if (node.dom.ownerFrame(frame)) |owner| {
        if (params.frameId != null and owner != frame) {
            return error.NodeNotFound;
        }
    }

    return sendAXNodes(cmd, bc, frame, node, .{
        .scope = .children,
    });
}

// A ListMarker has no DOM node, and no children. It's checked like its <li>,
// and is gone once the <li> no longer has one.
fn getListMarkerChildren(cmd: *CDP.Command, bc: *CDP.BrowserContext, frame: *Frame, check_frame: bool, ax_id: u32) !void {
    const li = bc.node_registry.listMarkerOwner(ax_id) orelse return error.NodeNotFound;
    if (!AXNode.hasListMarker(li)) {
        return error.NodeNotFound;
    }
    const owner = li.ownerFrame(frame) orelse return error.InvalidNodeId;
    if (check_frame and owner != frame) {
        return error.NodeNotFound;
    }
    return cmd.sendResult(.{ .nodes = [0]u32{} }, .{});
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

test "cdp.accessibility: getChildAXNodes returns the direct children" {
    var ctx = try testing.context();
    defer ctx.deinit();

    _ = try ctx.loadBrowserContext(.{ .id = "BID-A", .url = "cdp/ax_tree.html" });

    try ctx.processMessage(.{ .id = 1, .method = "Runtime.evaluate", .params = .{
        .expression = "document.querySelector('main')",
    } });
    const object_id = try evaluatedObjectId(&ctx, 1);

    try ctx.processMessage(.{ .id = 2, .method = "Accessibility.getPartialAXTree", .params = .{
        .objectId = object_id,
        .fetchRelatives = false,
    } });
    const main = (try sentResult(&ctx, 2)).get("nodes").?.array.items[0].object;
    const main_id = main.get("nodeId").?.string;
    const child_ids = main.get("childIds").?.array.items;

    try ctx.processMessage(.{ .id = 3, .method = "Accessibility.getChildAXNodes", .params = .{ .id = main_id } });
    const nodes = (try sentResult(&ctx, 3)).get("nodes").?.array.items;
    try testing.expectEqual(child_ids.len, nodes.len);
    for (nodes, child_ids) |n, cid| {
        try testing.expectEqual(cid.string, n.object.get("nodeId").?.string);
        try testing.expectEqual(main_id, n.object.get("parentId").?.string);
    }
    // Whitespace text between the elements is exposed too.
    var saw_heading = false;
    var saw_text = false;
    for (nodes) |n| {
        const role = axRole(n.object);
        if (std.mem.eql(u8, role, "heading")) saw_heading = true;
        if (std.mem.eql(u8, role, "StaticText")) saw_text = true;
    }
    try testing.expect(saw_heading and saw_text);

    try ctx.processMessage(.{ .id = 4, .method = "Accessibility.getChildAXNodes", .params = .{ .id = "99999" } });
    try ctx.expectSentError(-31998, "NodeNotFound", .{ .id = 4 });
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

    // fetchRelatives defaults to true: the node, its ancestors, siblings and
    // children, but nothing deeper.
    try ctx.processMessage(.{ .id = 3, .method = "Accessibility.getPartialAXTree", .params = .{
        .objectId = object_id,
    } });
    const nodes = (try sentResult(&ctx, 3)).get("nodes").?.array.items;
    try testing.expectEqual(label_id, nodes[0].object.get("nodeId").?.string);

    var saw_root = false;
    var heading_id: ?[]const u8 = null;
    var saw_child = false;
    for (nodes) |n| {
        const role = axRole(n.object);
        if (std.mem.eql(u8, role, "RootWebArea")) saw_root = true;
        if (std.mem.eql(u8, role, "heading")) heading_id = n.object.get("nodeId").?.string;
        if (std.mem.eql(u8, role, "textbox")) saw_child = true;
    }
    try testing.expect(saw_root and saw_child);
    // A sibling is listed, but not its children.
    for (nodes) |n| {
        const parent_id = (n.object.get("parentId") orelse continue).string;
        try testing.expect(!std.mem.eql(u8, parent_id, heading_id.?));
    }
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

test "cdp.accessibility: a node outside the AX tree is a lone ignored node" {
    var ctx = try testing.context();
    defer ctx.deinit();

    _ = try ctx.loadBrowserContext(.{ .id = "BID-A", .url = "cdp/ax_relatives.html" });

    try ctx.processMessage(.{ .id = 1, .method = "Runtime.evaluate", .params = .{
        .expression = "document.getElementById('in-gone')",
    } });
    const gone = try evaluatedObjectId(&ctx, 1);
    try ctx.processMessage(.{ .id = 2, .method = "Accessibility.getAXNodeAndAncestors", .params = .{ .objectId = gone } });
    try expectNotRendered((try sentResult(&ctx, 2)).get("nodes").?.array.items);

    // <title>: <head> exposes no children.
    try ctx.processMessage(.{ .id = 3, .method = "Runtime.evaluate", .params = .{
        .expression = "document.querySelector('title')",
    } });
    const title = try evaluatedObjectId(&ctx, 3);
    try ctx.processMessage(.{ .id = 4, .method = "Accessibility.getPartialAXTree", .params = .{ .objectId = title } });
    const nodes = (try sentResult(&ctx, 4)).get("nodes").?.array.items;
    try expectNotRendered(nodes);

    try ctx.processMessage(.{ .id = 5, .method = "Accessibility.getChildAXNodes", .params = .{
        .id = nodes[0].object.get("nodeId").?.string,
    } });
    try testing.expectEqual(0, (try sentResult(&ctx, 5)).get("nodes").?.array.items.len);
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

fn expectNotRendered(nodes: []const std.json.Value) !void {
    try testing.expectEqual(1, nodes.len);
    const node = nodes[0].object;
    try testing.expectEqual("none", axRole(node));
    try testing.expectEqual(true, node.get("ignored").?.bool);
    try testing.expectEqual("notRendered", node.get("ignoredReasons").?.array.items[0].object.get("name").?.string);
    try testing.expectEqual(null, node.get("parentId"));
    try testing.expectEqual(null, node.get("childIds"));
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
