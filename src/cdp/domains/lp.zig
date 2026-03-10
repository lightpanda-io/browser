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
const interactive = lp.interactive;
const structured_data = lp.structured_data;
const Node = @import("../Node.zig");

pub fn processMessage(cmd: anytype) !void {
    const action = std.meta.stringToEnum(enum {
        getMarkdown,
        getInteractiveElements,
        getStructuredData,
    }, cmd.input.action) orelse return error.UnknownMethod;

    switch (action) {
        .getMarkdown => return getMarkdown(cmd),
        .getInteractiveElements => return getInteractiveElements(cmd),
        .getStructuredData => return getStructuredData(cmd),
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

fn getInteractiveElements(cmd: anytype) !void {
    const Params = struct {
        nodeId: ?Node.Id = null,
    };
    const params = (try cmd.params(Params)) orelse Params{};

    const bc = cmd.browser_context orelse return error.NoBrowserContext;
    const page = bc.session.currentPage() orelse return error.PageNotLoaded;

    const root = if (params.nodeId) |nodeId|
        (bc.node_registry.lookup_by_id.get(nodeId) orelse return error.InvalidNodeId).dom
    else
        page.document.asNode();

    const elements = try interactive.collectInteractiveElements(root, cmd.arena, page);

    // Register nodes so nodeIds are valid for subsequent CDP calls.
    var node_ids: std.ArrayList(Node.Id) = try .initCapacity(cmd.arena, elements.len);
    for (elements) |el| {
        const registered = try bc.node_registry.register(el.node);
        node_ids.appendAssumeCapacity(registered.id);
    }

    return cmd.sendResult(.{
        .elements = elements,
        .nodeIds = node_ids.items,
    }, .{});
}

fn getStructuredData(cmd: anytype) !void {
    const bc = cmd.browser_context orelse return error.NoBrowserContext;
    const page = bc.session.currentPage() orelse return error.PageNotLoaded;

    const data = try structured_data.collectStructuredData(
        page.document.asNode(),
        cmd.arena,
        page,
    );

    return cmd.sendResult(.{
        .structuredData = data,
    }, .{});
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

test "cdp.lp: getInteractiveElements" {
    var ctx = testing.context();
    defer ctx.deinit();

    const bc = try ctx.loadBrowserContext(.{});
    _ = try bc.session.createPage();

    try ctx.processMessage(.{
        .id = 1,
        .method = "LP.getInteractiveElements",
    });

    const result = ctx.client.?.sent.items[0].object.get("result").?.object;
    try testing.expect(result.get("elements") != null);
    try testing.expect(result.get("nodeIds") != null);
}

test "cdp.lp: getStructuredData" {
    var ctx = testing.context();
    defer ctx.deinit();

    const bc = try ctx.loadBrowserContext(.{});
    _ = try bc.session.createPage();

    try ctx.processMessage(.{
        .id = 1,
        .method = "LP.getStructuredData",
    });

    const result = ctx.client.?.sent.items[0].object.get("result").?.object;
    try testing.expect(result.get("structuredData") != null);
}
