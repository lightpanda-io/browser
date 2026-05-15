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

pub fn processMessage(cmd: *CDP.Command) !void {
    const action = std.meta.stringToEnum(enum {
        enable,
        disable,
        getFullAXTree,
        queryAXTree,
    }, cmd.input.action) orelse return error.UnknownMethod;

    switch (action) {
        .enable => return enable(cmd),
        .disable => return disable(cmd),
        .getFullAXTree => return getFullAXTree(cmd),
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
            break :blk session.currentFrame() orelse return error.FrameNotLoaded;
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
    // Default-construct on missing params so we can return our specific
    // "node identifier required" error rather than a generic InvalidParams.
    const params = (try cmd.params(Params)) orelse Params{};

    // objectId requires the JS inspector and an attached runtime — defer to a
    // follow-up. Real clients (Capybara, Stagehand) usually have a nodeId from
    // a prior DOM.querySelector/DOM.getDocument call.
    if (params.objectId != null and params.nodeId == null and params.backendNodeId == null) {
        return cmd.sendError(-32000, "Accessibility.queryAXTree by objectId is not yet supported; use nodeId or backendNodeId", .{});
    }

    const input_id = params.nodeId orelse params.backendNodeId orelse {
        return cmd.sendError(-32000, "Either nodeId, backendNodeId or objectId must be specified", .{});
    };

    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    const node = bc.node_registry.lookup_by_id.get(input_id) orelse return error.NodeNotFound;

    const frame = bc.session.currentFrame() orelse return error.FrameNotLoaded;
    const temp_arena = try frame.getArena(.medium, "AXNode");
    defer frame.releaseArena(temp_arena);

    return cmd.sendResult(.{ .nodes = try bc.axnodeQueryWriter(temp_arena, node, .{
        .accessible_name = params.accessibleName,
        .role = params.role,
    }) }, .{});
}

const testing = @import("../testing.zig");

test "cdp.accessibility: queryAXTree requires nodeId or backendNodeId" {
    var ctx = try testing.context();
    defer ctx.deinit();

    _ = try ctx.loadBrowserContext(.{ .id = "BID-A", .url = "cdp/ax_tree.html" });

    // Pass filters but no node identifier — exercises the missing-id branch.
    try ctx.processMessage(.{
        .id = 1,
        .method = "Accessibility.queryAXTree",
        .params = .{ .role = "button" },
    });
    try ctx.expectSentError(-32000, "Either nodeId, backendNodeId or objectId must be specified", .{ .id = 1 });
}

test "cdp.accessibility: queryAXTree with objectId only is not yet supported" {
    var ctx = try testing.context();
    defer ctx.deinit();

    _ = try ctx.loadBrowserContext(.{ .id = "BID-A", .url = "cdp/ax_tree.html" });

    try ctx.processMessage(.{
        .id = 1,
        .method = "Accessibility.queryAXTree",
        .params = .{ .objectId = "OBJ-X" },
    });
    try ctx.expectSentError(-32000, "Accessibility.queryAXTree by objectId is not yet supported; use nodeId or backendNodeId", .{ .id = 1 });
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
