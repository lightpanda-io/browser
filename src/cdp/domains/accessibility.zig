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
    }, cmd.input.action) orelse return error.UnknownMethod;

    switch (action) {
        .enable => return enable(cmd),
        .disable => return disable(cmd),
        .getFullAXTree => return getFullAXTree(cmd),
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
