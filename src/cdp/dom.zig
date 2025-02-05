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

const server = @import("../server.zig");
const Ctx = server.Ctx;
const cdp = @import("cdp.zig");
const result = cdp.result;
const IncomingMessage = @import("msg.zig").IncomingMessage;
const Input = @import("msg.zig").Input;

const parser = @import("netsurf");

const log = std.log.scoped(.cdp);

const Methods = enum {
    enable,
    getDocument,
};

pub fn dom(
    alloc: std.mem.Allocator,
    msg: *IncomingMessage,
    action: []const u8,
    ctx: *Ctx,
) ![]const u8 {
    const method = std.meta.stringToEnum(Methods, action) orelse
        return error.UnknownMethod;

    return switch (method) {
        .enable => enable(alloc, msg, ctx),
        .getDocument => getDocument(alloc, msg, ctx),
    };
}

fn enable(
    alloc: std.mem.Allocator,
    msg: *IncomingMessage,
    _: *Ctx,
) ![]const u8 {
    // input
    const input = try Input(void).get(alloc, msg);
    defer input.deinit();
    log.debug("Req > id {d}, method {s}", .{ input.id, "inspector.enable" });

    return result(alloc, input.id, null, null, input.sessionId);
}

const NodeId = u32;

const Node = struct {
    nodeId: NodeId,
    parentId: ?NodeId = null,
    backendNodeId: NodeId,
    nodeType: u32,
    nodeName: []const u8 = "",
    localName: []const u8 = "",
    nodeValue: []const u8 = "",
    childNodeCount: u32,
    children: ?[]const Node = null,
    documentURL: ?[]const u8 = null,
    baseURL: ?[]const u8 = null,
    xmlVersion: []const u8 = "",
    compatibilityMode: []const u8 = "NoQuirksMode",
    isScrollable: bool = false,

    fn init(n: *parser.Node) !Node {
        const children = try parser.nodeGetChildNodes(n);
        const ln = try parser.nodeListLength(children);

        return .{
            .nodeId = 1,
            .backendNodeId = 1,
            .nodeType = @intFromEnum(try parser.nodeType(n)),
            .nodeName = try parser.nodeName(n),
            .localName = try parser.nodeLocalName(n),
            .nodeValue = try parser.nodeValue(n) orelse "",
            .childNodeCount = ln,
        };
    }
};

// https://chromedevtools.github.io/devtools-protocol/tot/DOM/#method-getDocument
fn getDocument(
    alloc: std.mem.Allocator,
    msg: *IncomingMessage,
    ctx: *Ctx,
) ![]const u8 {
    // input
    const Params = struct {
        depth: ?u32 = null,
        pierce: ?bool = null,
    };
    const input = try Input(Params).get(alloc, msg);
    defer input.deinit();
    std.debug.assert(input.sessionId != null);
    log.debug("Req > id {d}, method {s}", .{ input.id, "DOM.getDocument" });

    // retrieve the root node
    const page = ctx.browser.currentPage() orelse return error.NoPage;

    if (page.doc == null) return error.NoDocument;

    const root = try parser.documentGetDocumentElement(page.doc.?) orelse {
        return error.NoRoot;
    };

    // output
    const Resp = struct {
        root: Node,
    };
    const resp: Resp = .{
        .root = try Node.init(parser.elementToNode(root)),
    };

    return result(alloc, input.id, Resp, resp, input.sessionId);
}
