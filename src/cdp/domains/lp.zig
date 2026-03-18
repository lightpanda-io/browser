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
const log = @import("../../log.zig");
const markdown = lp.markdown;
const SemanticTree = lp.SemanticTree;
const interactive = lp.interactive;
const structured_data = lp.structured_data;
const Node = @import("../Node.zig");
const DOMNode = @import("../../browser/webapi/Node.zig");

pub fn processMessage(cmd: anytype) !void {
    const action = std.meta.stringToEnum(enum {
        getMarkdown,
        getSemanticTree,
        getInteractiveElements,
        getStructuredData,
        clickNode,
        fillNode,
        scrollNode,
    }, cmd.input.action) orelse return error.UnknownMethod;

    switch (action) {
        .getMarkdown => return getMarkdown(cmd),
        .getSemanticTree => return getSemanticTree(cmd),
        .getInteractiveElements => return getInteractiveElements(cmd),
        .getStructuredData => return getStructuredData(cmd),
        .clickNode => return clickNode(cmd),
        .fillNode => return fillNode(cmd),
        .scrollNode => return scrollNode(cmd),
    }
}

fn getSemanticTree(cmd: anytype) !void {
    const Params = struct {
        format: ?enum { text } = null,
        prune: ?bool = null,
        interactiveOnly: ?bool = null,
    };
    const params = (try cmd.params(Params)) orelse Params{};

    const bc = cmd.browser_context orelse return error.NoBrowserContext;
    const page = bc.session.currentPage() orelse return error.PageNotLoaded;
    const dom_node = page.document.asNode();

    var st = SemanticTree{
        .dom_node = dom_node,
        .registry = &bc.node_registry,
        .page = page,
        .arena = cmd.arena,
        .prune = params.prune orelse false,
        .interactive_only = params.interactiveOnly orelse false,
    };

    if (params.format) |format| {
        if (format == .text) {
            st.prune = params.prune orelse true;
            var aw: std.Io.Writer.Allocating = .init(cmd.arena);
            defer aw.deinit();
            try st.textStringify(&aw.writer);

            return cmd.sendResult(.{
                .semanticTree = aw.written(),
            }, .{});
        }
    }

    return cmd.sendResult(.{
        .semanticTree = st,
    }, .{});
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

    var aw: std.Io.Writer.Allocating = .init(cmd.arena);
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

fn clickNode(cmd: anytype) !void {
    const Params = struct {
        nodeId: ?Node.Id = null,
        backendNodeId: ?Node.Id = null,
    };
    const params = (try cmd.params(Params)) orelse return error.InvalidParam;

    const bc = cmd.browser_context orelse return error.NoBrowserContext;
    const page = bc.session.currentPage() orelse return error.PageNotLoaded;

    const node_id = params.nodeId orelse params.backendNodeId orelse return error.InvalidParam;
    const node = bc.node_registry.lookup_by_id.get(node_id) orelse return error.InvalidNodeId;

    lp.actions.click(node.dom, page) catch |err| {
        if (err == error.InvalidNodeType) return error.InvalidParam;
        return error.InternalError;
    };

    return cmd.sendResult(.{}, .{});
}

fn fillNode(cmd: anytype) !void {
    const Params = struct {
        nodeId: ?Node.Id = null,
        backendNodeId: ?Node.Id = null,
        text: []const u8,
    };
    const params = (try cmd.params(Params)) orelse return error.InvalidParam;

    const bc = cmd.browser_context orelse return error.NoBrowserContext;
    const page = bc.session.currentPage() orelse return error.PageNotLoaded;

    const node_id = params.nodeId orelse params.backendNodeId orelse return error.InvalidParam;
    const node = bc.node_registry.lookup_by_id.get(node_id) orelse return error.InvalidNodeId;

    lp.actions.fill(node.dom, params.text, page) catch |err| {
        if (err == error.InvalidNodeType) return error.InvalidParam;
        return error.InternalError;
    };

    return cmd.sendResult(.{}, .{});
}

fn scrollNode(cmd: anytype) !void {
    const Params = struct {
        nodeId: ?Node.Id = null,
        backendNodeId: ?Node.Id = null,
        x: ?i32 = null,
        y: ?i32 = null,
    };
    const params = (try cmd.params(Params)) orelse return error.InvalidParam;

    const bc = cmd.browser_context orelse return error.NoBrowserContext;
    const page = bc.session.currentPage() orelse return error.PageNotLoaded;

    const maybe_node_id = params.nodeId orelse params.backendNodeId;

    var target_node: ?*DOMNode = null;
    if (maybe_node_id) |node_id| {
        const node = bc.node_registry.lookup_by_id.get(node_id) orelse return error.InvalidNodeId;
        target_node = node.dom;
    }

    lp.actions.scroll(target_node, params.x, params.y, page) catch |err| {
        if (err == error.InvalidNodeType) return error.InvalidParam;
        return error.InternalError;
    };

    return cmd.sendResult(.{}, .{});
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

test "cdp.lp: action tools" {
    var ctx = testing.context();
    defer ctx.deinit();

    const bc = try ctx.loadBrowserContext(.{});
    const page = try bc.session.createPage();
    const url = "http://localhost:9582/src/browser/tests/mcp_actions.html";
    try page.navigate(url, .{ .reason = .address_bar, .kind = .{ .push = null } });
    _ = bc.session.wait(5000);

    // Test Click
    const btn = page.document.getElementById("btn", page).?.asNode();
    const btn_id = (try bc.node_registry.register(btn)).id;
    try ctx.processMessage(.{
        .id = 1,
        .method = "LP.clickNode",
        .params = .{ .backendNodeId = btn_id },
    });

    // Test Fill Input
    const inp = page.document.getElementById("inp", page).?.asNode();
    const inp_id = (try bc.node_registry.register(inp)).id;
    try ctx.processMessage(.{
        .id = 2,
        .method = "LP.fillNode",
        .params = .{ .backendNodeId = inp_id, .text = "hello" },
    });

    // Test Fill Select
    const sel = page.document.getElementById("sel", page).?.asNode();
    const sel_id = (try bc.node_registry.register(sel)).id;
    try ctx.processMessage(.{
        .id = 3,
        .method = "LP.fillNode",
        .params = .{ .backendNodeId = sel_id, .text = "opt2" },
    });

    // Test Scroll
    const scrollbox = page.document.getElementById("scrollbox", page).?.asNode();
    const scrollbox_id = (try bc.node_registry.register(scrollbox)).id;
    try ctx.processMessage(.{
        .id = 4,
        .method = "LP.scrollNode",
        .params = .{ .backendNodeId = scrollbox_id, .y = 50 },
    });

    // Evaluate assertions
    var ls: lp.js.Local.Scope = undefined;
    page.js.localScope(&ls);
    defer ls.deinit();

    var try_catch: lp.js.TryCatch = undefined;
    try_catch.init(&ls.local);
    defer try_catch.deinit();

    const result = try ls.local.compileAndRun("window.clicked === true && window.inputVal === 'hello' && window.changed === true && window.selChanged === 'opt2' && window.scrolled === true", null);

    try testing.expect(result.isTrue());
}
