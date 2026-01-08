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

pub fn processMessage(cmd: anytype) !void {
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
fn enable(cmd: anytype) !void {
    return cmd.sendResult(null, .{});
}

fn disable(cmd: anytype) !void {
    return cmd.sendResult(null, .{});
}

fn getFullAXTree(cmd: anytype) !void {
    const params = (try cmd.params(struct {
        depth: ?i32 = null,
        frameId: ?[]const u8 = null,
    })) orelse return error.InvalidParams;

    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;

    if (params.frameId) |frameId| {
        const target_id = bc.target_id orelse return error.TargetNotLoaded;
        if (std.mem.eql(u8, target_id, frameId) == false) {
            return cmd.sendError(-32000, "Frame with the given id does not belong to the target.", .{});
        }
    }

    const page = bc.session.currentPage() orelse return error.PageNotLoaded;
    const doc = page.window._document.asNode();
    const node = try bc.node_registry.register(doc);

    return cmd.sendResult(.{ .nodes = try bc.axnodeWriter(node, .{}) }, .{});
}
