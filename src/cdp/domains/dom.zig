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
const parser = @import("netsurf");
const Node = @import("../Node.zig");
const css = @import("../../dom/css.zig");

pub fn processMessage(cmd: anytype) !void {
    const action = std.meta.stringToEnum(enum {
        enable,
        getDocument,
        performSearch,
        getSearchResults,
        discardSearchResults,
        resolveNode,
    }, cmd.input.action) orelse return error.UnknownMethod;

    switch (action) {
        .enable => return cmd.sendResult(null, .{}),
        .getDocument => return getDocument(cmd),
        .performSearch => return performSearch(cmd),
        .getSearchResults => return getSearchResults(cmd),
        .discardSearchResults => return discardSearchResults(cmd),
        .resolveNode => return resolveNode(cmd),
    }
}

// https://chromedevtools.github.io/devtools-protocol/tot/DOM/#method-getDocument
fn getDocument(cmd: anytype) !void {
    // const params = (try cmd.params(struct {
    //     depth: ?u32 = null,
    //     pierce: ?bool = null,
    // })) orelse return error.InvalidParams;

    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    const page = bc.session.currentPage() orelse return error.PageNotLoaded;
    const doc = page.doc orelse return error.DocumentNotLoaded;

    const node = try bc.node_registry.register(parser.documentToNode(doc));
    return cmd.sendResult(.{ .root = bc.nodeWriter(node, .{}) }, .{});
}

// https://chromedevtools.github.io/devtools-protocol/tot/DOM/#method-performSearch
fn performSearch(cmd: anytype) !void {
    const params = (try cmd.params(struct {
        query: []const u8,
        includeUserAgentShadowDOM: ?bool = null,
    })) orelse return error.InvalidParams;

    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    const page = bc.session.currentPage() orelse return error.PageNotLoaded;
    const doc = page.doc orelse return error.DocumentNotLoaded;

    const allocator = cmd.cdp.allocator;
    var list = try css.querySelectorAll(allocator, parser.documentToNode(doc), params.query);
    defer list.deinit(allocator);

    const search = try bc.node_search_list.create(list.nodes.items);

    return cmd.sendResult(.{
        .searchId = search.name,
        .resultCount = @as(u32, @intCast(search.node_ids.len)),
    }, .{});
}

// https://chromedevtools.github.io/devtools-protocol/tot/DOM/#method-discardSearchResults
fn discardSearchResults(cmd: anytype) !void {
    const params = (try cmd.params(struct {
        searchId: []const u8,
    })) orelse return error.InvalidParams;

    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;

    bc.node_search_list.remove(params.searchId);
    return cmd.sendResult(null, .{});
}

// https://chromedevtools.github.io/devtools-protocol/tot/DOM/#method-getSearchResults
fn getSearchResults(cmd: anytype) !void {
    const params = (try cmd.params(struct {
        searchId: []const u8,
        fromIndex: u32,
        toIndex: u32,
    })) orelse return error.InvalidParams;

    if (params.fromIndex >= params.toIndex) {
        return error.BadIndices;
    }

    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;

    const search = bc.node_search_list.get(params.searchId) orelse {
        return error.SearchResultNotFound;
    };

    const node_ids = search.node_ids;

    if (params.fromIndex >= node_ids.len) return error.BadFromIndex;
    if (params.toIndex > node_ids.len) return error.BadToIndex;

    return cmd.sendResult(.{ .nodeIds = node_ids[params.fromIndex..params.toIndex] }, .{});
}

fn resolveNode(cmd: anytype) !void {
    const params = (try cmd.params(struct {
        nodeId: ?Node.Id = null,
        backendNodeId: ?u32 = null,
        objectGroup: ?[]const u8 = null,
        executionContextId: ?u32 = null,
    })) orelse return error.InvalidParams;
    if (params.nodeId == null or params.backendNodeId != null or params.objectGroup != null or params.executionContextId != null) {
        return error.NotYetImplementedParams;
    }

    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    const node = bc.node_registry.lookup_by_id.get(params.nodeId.?).?;

    // How best to do this? Create a functions that takes a functions(wrapObject), does all the switching at every level and applies the given function to the leav object?
    const remote_object = try switch (try parser.nodeType(node._node)) {
        .element => blk: {
            const elem: *align(@alignOf(*parser.Element)) parser.Element = @alignCast(@as(*parser.Element, @ptrCast(node._node)));
            const tag = try parser.elementHTMLGetTagType(@as(*parser.ElementHTML, @ptrCast(elem)));
            break :blk switch (tag) {
                .abbr, .acronym, .address, .article, .aside, .b, .basefont, .bdi, .bdo, .bgsound, .big, .center, .cite, .code, .dd, .details, .dfn, .dt, .em, .figcaption, .figure, .footer, .header, .hgroup, .i, .isindex, .keygen, .kbd, .main, .mark, .marquee, .menu, .menuitem, .nav, .nobr, .noframes, .noscript, .rp, .rt, .ruby, .s, .samp, .section, .small, .spacer, .strike, .strong, .sub, .summary, .sup, .tt, .u, .wbr, ._var => bc.session.inspector.wrapObject(&bc.session.env, @as(*parser.ElementHTML, @ptrCast(elem))),
                .a => bc.session.inspector.wrapObject(&bc.session.env, @as(*parser.Anchor, @ptrCast(elem))),
                .applet => bc.session.inspector.wrapObject(&bc.session.env, @as(*parser.Applet, @ptrCast(elem))),
                .area => bc.session.inspector.wrapObject(&bc.session.env, @as(*parser.Area, @ptrCast(elem))),
                .audio => bc.session.inspector.wrapObject(&bc.session.env, @as(*parser.Audio, @ptrCast(elem))),
                .base => bc.session.inspector.wrapObject(&bc.session.env, @as(*parser.Base, @ptrCast(elem))),
                .body => bc.session.inspector.wrapObject(&bc.session.env, @as(*parser.Body, @ptrCast(elem))),
                .br => bc.session.inspector.wrapObject(&bc.session.env, @as(*parser.BR, @ptrCast(elem))),
                .button => bc.session.inspector.wrapObject(&bc.session.env, @as(*parser.Button, @ptrCast(elem))),
                .canvas => bc.session.inspector.wrapObject(&bc.session.env, @as(*parser.Canvas, @ptrCast(elem))),
                .dl => bc.session.inspector.wrapObject(&bc.session.env, @as(*parser.DList, @ptrCast(elem))),
                .data => bc.session.inspector.wrapObject(&bc.session.env, @as(*parser.Data, @ptrCast(elem))),
                .datalist => bc.session.inspector.wrapObject(&bc.session.env, @as(*parser.DataList, @ptrCast(elem))),
                .dialog => bc.session.inspector.wrapObject(&bc.session.env, @as(*parser.Dialog, @ptrCast(elem))),
                .dir => bc.session.inspector.wrapObject(&bc.session.env, @as(*parser.Directory, @ptrCast(elem))),
                .div => bc.session.inspector.wrapObject(&bc.session.env, @as(*parser.Div, @ptrCast(elem))),
                .embed => bc.session.inspector.wrapObject(&bc.session.env, @as(*parser.Embed, @ptrCast(elem))),
                .fieldset => bc.session.inspector.wrapObject(&bc.session.env, @as(*parser.FieldSet, @ptrCast(elem))),
                .font => bc.session.inspector.wrapObject(&bc.session.env, @as(*parser.Font, @ptrCast(elem))),
                .form => bc.session.inspector.wrapObject(&bc.session.env, @as(*parser.Form, @ptrCast(elem))),
                .frame => bc.session.inspector.wrapObject(&bc.session.env, @as(*parser.Frame, @ptrCast(elem))),
                .frameset => bc.session.inspector.wrapObject(&bc.session.env, @as(*parser.FrameSet, @ptrCast(elem))),
                .hr => bc.session.inspector.wrapObject(&bc.session.env, @as(*parser.HR, @ptrCast(elem))),
                .head => bc.session.inspector.wrapObject(&bc.session.env, @as(*parser.Head, @ptrCast(elem))),
                .h1, .h2, .h3, .h4, .h5, .h6 => bc.session.inspector.wrapObject(&bc.session.env, @as(*parser.Heading, @ptrCast(elem))),
                .html => bc.session.inspector.wrapObject(&bc.session.env, @as(*parser.Html, @ptrCast(elem))),
                .iframe => bc.session.inspector.wrapObject(&bc.session.env, @as(*parser.IFrame, @ptrCast(elem))),
                .img => bc.session.inspector.wrapObject(&bc.session.env, @as(*parser.Image, @ptrCast(elem))),
                .input => bc.session.inspector.wrapObject(&bc.session.env, @as(*parser.Input, @ptrCast(elem))),
                .li => bc.session.inspector.wrapObject(&bc.session.env, @as(*parser.LI, @ptrCast(elem))),
                .label => bc.session.inspector.wrapObject(&bc.session.env, @as(*parser.Label, @ptrCast(elem))),
                .legend => bc.session.inspector.wrapObject(&bc.session.env, @as(*parser.Legend, @ptrCast(elem))),
                .link => bc.session.inspector.wrapObject(&bc.session.env, @as(*parser.Link, @ptrCast(elem))),
                .map => bc.session.inspector.wrapObject(&bc.session.env, @as(*parser.Map, @ptrCast(elem))),
                .meta => bc.session.inspector.wrapObject(&bc.session.env, @as(*parser.Meta, @ptrCast(elem))),
                .meter => bc.session.inspector.wrapObject(&bc.session.env, @as(*parser.Meter, @ptrCast(elem))),
                .ins, .del => bc.session.inspector.wrapObject(&bc.session.env, @as(*parser.Mod, @ptrCast(elem))),
                .ol => bc.session.inspector.wrapObject(&bc.session.env, @as(*parser.OList, @ptrCast(elem))),
                .object => bc.session.inspector.wrapObject(&bc.session.env, @as(*parser.Object, @ptrCast(elem))),
                .optgroup => bc.session.inspector.wrapObject(&bc.session.env, @as(*parser.OptGroup, @ptrCast(elem))),
                .option => bc.session.inspector.wrapObject(&bc.session.env, @as(*parser.Option, @ptrCast(elem))),
                .output => bc.session.inspector.wrapObject(&bc.session.env, @as(*parser.Output, @ptrCast(elem))),
                .p => bc.session.inspector.wrapObject(&bc.session.env, @as(*parser.Paragraph, @ptrCast(elem))),
                .param => bc.session.inspector.wrapObject(&bc.session.env, @as(*parser.Param, @ptrCast(elem))),
                .picture => bc.session.inspector.wrapObject(&bc.session.env, @as(*parser.Picture, @ptrCast(elem))),
                .pre => bc.session.inspector.wrapObject(&bc.session.env, @as(*parser.Pre, @ptrCast(elem))),
                .progress => bc.session.inspector.wrapObject(&bc.session.env, @as(*parser.Progress, @ptrCast(elem))),
                .blockquote, .q => bc.session.inspector.wrapObject(&bc.session.env, @as(*parser.Quote, @ptrCast(elem))),
                .script => bc.session.inspector.wrapObject(&bc.session.env, @as(*parser.Script, @ptrCast(elem))),
                .select => bc.session.inspector.wrapObject(&bc.session.env, @as(*parser.Select, @ptrCast(elem))),
                .source => bc.session.inspector.wrapObject(&bc.session.env, @as(*parser.Source, @ptrCast(elem))),
                .span => bc.session.inspector.wrapObject(&bc.session.env, @as(*parser.Span, @ptrCast(elem))),
                .style => bc.session.inspector.wrapObject(&bc.session.env, @as(*parser.Style, @ptrCast(elem))),
                .table => bc.session.inspector.wrapObject(&bc.session.env, @as(*parser.Table, @ptrCast(elem))),
                .caption => bc.session.inspector.wrapObject(&bc.session.env, @as(*parser.TableCaption, @ptrCast(elem))),
                .th, .td => bc.session.inspector.wrapObject(&bc.session.env, @as(*parser.TableCell, @ptrCast(elem))),
                .col, .colgroup => bc.session.inspector.wrapObject(&bc.session.env, @as(*parser.TableCol, @ptrCast(elem))),
                .tr => bc.session.inspector.wrapObject(&bc.session.env, @as(*parser.TableRow, @ptrCast(elem))),
                .thead, .tbody, .tfoot => bc.session.inspector.wrapObject(&bc.session.env, @as(*parser.TableSection, @ptrCast(elem))),
                .template => bc.session.inspector.wrapObject(&bc.session.env, @as(*parser.Template, @ptrCast(elem))),
                .textarea => bc.session.inspector.wrapObject(&bc.session.env, @as(*parser.TextArea, @ptrCast(elem))),
                .time => bc.session.inspector.wrapObject(&bc.session.env, @as(*parser.Time, @ptrCast(elem))),
                .title => bc.session.inspector.wrapObject(&bc.session.env, @as(*parser.Title, @ptrCast(elem))),
                .track => bc.session.inspector.wrapObject(&bc.session.env, @as(*parser.Track, @ptrCast(elem))),
                .ul => bc.session.inspector.wrapObject(&bc.session.env, @as(*parser.UList, @ptrCast(elem))),
                .video => bc.session.inspector.wrapObject(&bc.session.env, @as(*parser.Video, @ptrCast(elem))),
                .undef => bc.session.inspector.wrapObject(&bc.session.env, @as(*parser.Unknown, @ptrCast(elem))),
            };
        },
        .comment => bc.session.inspector.wrapObject(&bc.session.env, @as(*parser.Comment, @ptrCast(node._node))), // TODO sub types
        .text => bc.session.inspector.wrapObject(&bc.session.env, @as(*parser.Text, @ptrCast(node._node))),
        .cdata_section => bc.session.inspector.wrapObject(&bc.session.env, @as(*parser.CDATASection, @ptrCast(node._node))),
        .processing_instruction => bc.session.inspector.wrapObject(&bc.session.env, @as(*parser.ProcessingInstruction, @ptrCast(node._node))),
        .document => bc.session.inspector.wrapObject(&bc.session.env, @as(*parser.DocumentHTML, @ptrCast(node._node))),
        .document_type => bc.session.inspector.wrapObject(&bc.session.env, @as(*parser.DocumentType, @ptrCast(node._node))),
        .attribute => bc.session.inspector.wrapObject(&bc.session.env, @as(*parser.Attribute, @ptrCast(node._node))),
        .document_fragment => bc.session.inspector.wrapObject(&bc.session.env, @as(*parser.DocumentFragment, @ptrCast(node._node))),
        else => @panic("node type not handled"),
    };
    defer remote_object.deinit();

    var arena = std.heap.ArenaAllocator.init(cmd.cdp.allocator);
    const alloc = arena.allocator();
    defer arena.deinit();
    return cmd.sendResult(.{ .object = .{ .type = try remote_object.getType(alloc), .subtype = try remote_object.getSubtype(alloc), .className = try remote_object.getClassName(alloc), .description = try remote_object.getDescription(alloc), .objectId = try remote_object.getObjectId(alloc) } }, .{});
}

const testing = @import("../testing.zig");

test "cdp.dom: getSearchResults unknown search id" {
    var ctx = testing.context();
    defer ctx.deinit();

    try testing.expectError(error.BrowserContextNotLoaded, ctx.processMessage(.{
        .id = 8,
        .method = "DOM.getSearchResults",
        .params = .{ .searchId = "Nope", .fromIndex = 0, .toIndex = 10 },
    }));
}

test "cdp.dom: search flow" {
    var ctx = testing.context();
    defer ctx.deinit();

    _ = try ctx.loadBrowserContext(.{ .id = "BID-A", .html = "<p>1</p> <p>2</p>" });

    try ctx.processMessage(.{
        .id = 12,
        .method = "DOM.performSearch",
        .params = .{ .query = "p" },
    });
    try ctx.expectSentResult(.{ .searchId = "0", .resultCount = 2 }, .{ .id = 12 });

    {
        // getSearchResults
        try ctx.processMessage(.{
            .id = 13,
            .method = "DOM.getSearchResults",
            .params = .{ .searchId = "0", .fromIndex = 0, .toIndex = 2 },
        });
        try ctx.expectSentResult(.{ .nodeIds = &.{ 0, 1 } }, .{ .id = 13 });

        // different fromIndex
        try ctx.processMessage(.{
            .id = 14,
            .method = "DOM.getSearchResults",
            .params = .{ .searchId = "0", .fromIndex = 1, .toIndex = 2 },
        });
        try ctx.expectSentResult(.{ .nodeIds = &.{1} }, .{ .id = 14 });

        // different toIndex
        try ctx.processMessage(.{
            .id = 15,
            .method = "DOM.getSearchResults",
            .params = .{ .searchId = "0", .fromIndex = 0, .toIndex = 1 },
        });
        try ctx.expectSentResult(.{ .nodeIds = &.{0} }, .{ .id = 15 });
    }

    try ctx.processMessage(.{
        .id = 16,
        .method = "DOM.discardSearchResults",
        .params = .{ .searchId = "0" },
    });
    try ctx.expectSentResult(null, .{ .id = 16 });

    // make sure the delete actually did something
    try testing.expectError(error.SearchResultNotFound, ctx.processMessage(.{
        .id = 17,
        .method = "DOM.getSearchResults",
        .params = .{ .searchId = "0", .fromIndex = 0, .toIndex = 1 },
    }));
}
