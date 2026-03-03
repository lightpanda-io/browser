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

pub const LPState = struct {
    allocator: Allocator,
    pending_wait_for_network_idle: std.ArrayList(PendingCommand),

    pub fn init(allocator: Allocator) !LPState {
        return .{
            .allocator = allocator,
            .pending_wait_for_network_idle = .empty,
        };
    }

    pub fn deinit(self: *LPState) void {
        for (self.pending_wait_for_network_idle.items) |*cmd| {
            cmd.deinit(self.allocator);
        }
        self.pending_wait_for_network_idle.deinit(self.allocator);
    }
};

const PendingCommand = struct {
    id: ?i64,
    session_id: ?[]const u8,

    pub fn deinit(self: *PendingCommand, allocator: Allocator) void {
        if (self.session_id) |sid| allocator.free(sid);
    }
};

pub fn processMessage(cmd: anytype) !void {
    const action = std.meta.stringToEnum(enum {
        getMarkdown,
        waitForNetworkIdle,
    }, cmd.input.action) orelse return error.UnknownMethod;

    switch (action) {
        .getMarkdown => return getMarkdown(cmd),
        .waitForNetworkIdle => return waitForNetworkIdle(cmd),
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

fn waitForNetworkIdle(cmd: anytype) !void {
    const bc = cmd.browser_context orelse return error.NoBrowserContext;

    // If network is already idle, we can return immediately
    const http_client = bc.cdp.browser.http_client;
    if (http_client.active == 0 and http_client.intercepted == 0) {
        return cmd.sendResult(null, .{});
    }

    // Otherwise, we need to wait for the notification.
    // We need to persist the command information.
    const allocator = bc.lp_state.allocator;
    const session_id = if (cmd.input.session_id) |sid| try allocator.dupe(u8, sid) else null;
    errdefer if (session_id) |sid| allocator.free(sid);

    try bc.lp_state.pending_wait_for_network_idle.append(allocator, .{
        .id = cmd.input.id,
        .session_id = session_id,
    });
}

pub fn onPageNetworkIdle(bc: anytype, _: *const Notification.PageNetworkIdle) !void {
    const pending = &bc.lp_state.pending_wait_for_network_idle;
    for (pending.items) |*cmd| {
        try bc.cdp.client.sendJSON(.{
            .id = cmd.id,
            .result = struct {}{},
            .sessionId = cmd.session_id,
        }, .{ .emit_null_optional_fields = false });
        cmd.deinit(bc.lp_state.allocator);
    }
    pending.clearRetainingCapacity();
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

test "cdp.lp: waitForNetworkIdle" {
    var ctx = testing.context();
    defer ctx.deinit();

    const bc = try ctx.loadBrowserContext(.{});
    _ = try bc.session.createPage();

    // 1. Test immediate return when idle
    try ctx.processMessage(.{
        .id = 1,
        .method = "LP.waitForNetworkIdle",
    });
    try ctx.expectSentResult(null, .{ .id = 1 });

    // 2. Test waiting when not idle
    // We can't easily mock http_client.active here without more complexity,
    // but we can at least test the notification path by manually triggering it.
    try bc.lp_state.pending_wait_for_network_idle.append(bc.lp_state.allocator, .{
        .id = 2,
        .session_id = null,
    });

    try onPageNetworkIdle(bc, &.{ .req_id = 0, .frame_id = 0, .timestamp = 0 });
    try ctx.expectSentResult(null, .{ .id = 2 });
}
