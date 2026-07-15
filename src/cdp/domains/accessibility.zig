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
const lp = @import("lightpanda");

const id = @import("../id.zig");
const CDP = @import("../CDP.zig");

const dom = @import("dom.zig");

const log = lp.log;

pub fn processMessage(cmd: *CDP.Command) !void {
    const action = std.meta.stringToEnum(enum {
        enable,
        disable,
        getFullAXTree,
        getPartialAXTree,
        queryAXTree,
    }, cmd.input.action) orelse return error.UnknownMethod;

    switch (action) {
        .enable => return enable(cmd),
        .disable => return disable(cmd),
        .getFullAXTree => return getFullAXTree(cmd),
        .getPartialAXTree => return getPartialAXTree(cmd),
        .queryAXTree => return queryAXTree(cmd),
    }
}
fn enable(cmd: *CDP.Command) !void {
    return cmd.sendResult(null, .{});
}

fn disable(cmd: *CDP.Command) !void {
    return cmd.sendResult(null, .{});
}

fn getFullAXTree(cmd: *CDP.Command) !void {
    const params = (try cmd.params(struct {
        depth: ?i32 = null,
        frameId: ?[]const u8 = null,
    })) orelse return error.InvalidParams;

    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    const session = bc.session;

    const frame = blk: {
        const frame_id = params.frameId orelse {
            break :blk bc.mainFrame() orelse return error.FrameNotLoaded;
        };
        break :blk session.findFrameByFrameId(try id.parseFrameId(frame_id)) orelse {
            return cmd.sendError(-32000, "Frame with the given id does not belong to the target.", .{});
        };
    };

    const doc = frame.window._document.asNode();
    const node = try bc.node_registry.register(doc);

    const temp_arena = try frame.getArena(.medium, "AXNode");
    defer frame.releaseArena(temp_arena);

    return cmd.sendResult(.{ .nodes = try bc.axnodeWriter(temp_arena, node, .{}) }, .{});
}

fn queryAXTree(cmd: *CDP.Command) !void {
    const Params = struct {
        nodeId: ?u32 = null,
        backendNodeId: ?u32 = null,
        objectId: ?[]const u8 = null,
        accessibleName: ?[]const u8 = null,
        role: ?[]const u8 = null,
    };
    const params = (try cmd.params(Params)) orelse return error.InvalidParams;

    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    const node = try dom.getNode(cmd.arena, bc, params.nodeId, params.backendNodeId, params.objectId);

    const frame = bc.mainFrame() orelse return error.FrameNotLoaded;
    const temp_arena = try frame.getArena(.medium, "AXNode");
    defer frame.releaseArena(temp_arena);

    return cmd.sendResult(.{ .nodes = try bc.axnodeWriter(temp_arena, node, .{
        .filter = .{
            .accessible_name = params.accessibleName,
            .role = params.role,
        },
    }) }, .{});
}

fn getPartialAXTree(cmd: *CDP.Command) !void {
    const params = (try cmd.params(struct {
        nodeId: ?u32 = null,
        backendNodeId: ?u32 = null,
        objectId: ?[]const u8 = null,
        // Accepted for Chrome protocol compatibility. The ancestor chain is
        // not yet emitted; this returns the subtree rooted at the resolved
        // node, matching the scope of queryAXTree.
        fetchRelatives: ?bool = null,
    })) orelse return error.InvalidParams;

    if (params.fetchRelatives orelse true) {
        // orelse true, because that's what Chrome defaults too, and if people
        // aren't setting it, then they're expecting true.
        log.warn(.not_implemented, "getPartialAXTree", .{
            .cdp_cmd = "Accessibility.getPartialAXTree",
            .param = "fetchRelatives",
        });
    }

    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    const node = try dom.getNode(cmd.arena, bc, params.nodeId, params.backendNodeId, params.objectId);

    const frame = bc.mainFrame() orelse return error.FrameNotLoaded;
    const temp_arena = try frame.getArena(.medium, "AXNode");
    defer frame.releaseArena(temp_arena);

    // No filter: emit the full accessibility subtree rooted at the resolved
    // node, the same shape getFullAXTree produces for the document root.
    return cmd.sendResult(.{ .nodes = try bc.axnodeWriter(temp_arena, node, .{}) }, .{});
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
