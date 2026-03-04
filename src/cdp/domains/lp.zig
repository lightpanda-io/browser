// Copyright (C) 2023-2026  Lightpanda (Selecy SAS)
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
const markdown = lp.markdown;
const Node = @import("../Node.zig");
const Notification = @import("../../Notification.zig");

const Allocator = std.mem.Allocator;

pub const LpState = struct {
    pending_wait_for_network_idle: ?i64 = null,
};

pub fn processMessage(cmd: anytype) !void {
    const action = std.meta.stringToEnum(enum {
        getMarkdown,
        waitFor,
    }, cmd.input.action) orelse return error.UnknownMethod;

    switch (action) {
        .getMarkdown => return getMarkdown(cmd),
        .waitFor => return waitFor(cmd),
    }
}

fn getMarkdown(cmd: anytype) !void {
    const Params = struct {
        nodeId: ?Node.Id = null,
    };
    const params = (try cmd.params(Params)) orelse Params{};

    const bc = cmd.browser_context orelse return error.NoBrowserContext;
    const page = bc.session.currentPage() orelse return error.PageNotLoaded;

    const dom_node = if (params.nodeId) |nodeId|
        (bc.node_registry.lookup_by_id.get(nodeId) orelse return error.InvalidNodeId).dom
    else
        page.document.asNode();

    var aw = std.Io.Writer.Allocating.init(cmd.arena);
    defer aw.deinit();
    try markdown.dump(dom_node, .{}, &aw.writer, page);

    return cmd.sendResult(.{
        .markdown = aw.written(),
    }, .{});
}

fn waitFor(cmd: anytype) !void {
    const bc = cmd.browser_context orelse return error.NoBrowserContext;

    const Params = struct {
        condition: []const u8,
    };
    const params = (try cmd.params(Params)) orelse return error.InvalidParams;

    if (std.mem.eql(u8, params.condition, "networkIdle")) {
        // If network is already idle, we can return immediately
        const http_client = bc.cdp.browser.http_client;
        if (http_client.active == 0 and http_client.intercepted == 0) {
            return cmd.sendResult(null, .{});
        }

        // Otherwise, we store the ID and wait for the notification.
        bc.lp_state.pending_wait_for_network_idle = cmd.input.id;
    } else {
        return error.InvalidParams;
    }
}

pub fn onPageNetworkIdle(bc: anytype, _: *const Notification.PageNetworkIdle) !void {
    const id = bc.lp_state.pending_wait_for_network_idle orelse return;
    bc.lp_state.pending_wait_for_network_idle = null;

    try bc.cdp.client.sendJSON(.{
        .id = id,
        .result = struct {}{},
        .sessionId = bc.session_id,
    }, .{ .emit_null_optional_fields = false });
}

const testing = @import("../testing.zig");
test "cdp.lp: getMarkdown" {
    var ctx = testing.context();
    defer ctx.deinit();

    const bc = try ctx.loadBrowserContext(.{});
    _ = try bc.session.createPage();

    try ctx.processMessage(.{
        .id = 1,
        .method = "LP.getMarkdown",
    });

    const result = ctx.client.?.sent.items[0].object.get("result").?.object;
    try testing.expect(result.get("markdown") != null);
}

test "cdp.lp: waitFor" {
    var ctx = testing.context();
    defer ctx.deinit();

    const bc = try ctx.loadBrowserContext(.{});
    _ = try bc.session.createPage();

    // 1. Test immediate return when idle
    try ctx.processMessage(.{
        .id = 1,
        .method = "LP.waitFor",
        .params = .{ .condition = "networkIdle" },
    });
    try ctx.expectSentResult(null, .{ .id = 1 });

    // 2. Test waiting when not idle
    bc.lp_state.pending_wait_for_network_idle = 2;

    try onPageNetworkIdle(bc, &.{ .req_id = 0, .frame_id = 0, .timestamp = 0 });
    try ctx.expectSentResult(null, .{ .id = 2 });
}
