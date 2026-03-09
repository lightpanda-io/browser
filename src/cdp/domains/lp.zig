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
const Node = @import("../Node.zig");
const DOMNode = @import("../../browser/webapi/Node.zig");

pub fn processMessage(cmd: anytype) !void {
    const action = std.meta.stringToEnum(enum {
        getMarkdown,
        getSemanticTree,
    }, cmd.input.action) orelse return error.UnknownMethod;

    switch (action) {
        .getMarkdown => return getMarkdown(cmd),
        .getSemanticTree => return getSemanticTree(cmd),
    }
}

fn getSemanticTree(cmd: anytype) !void {
    const Params = struct {
        format: ?[]const u8 = null,
        prune: ?bool = null,
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
    };

    if (params.format) |format| {
        if (std.mem.eql(u8, format, "text")) {
            st.prune = params.prune orelse true; // text format defaults to pruned
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
