// Copyright (C) 2023-2025  Lightpanda (Selecy SAS)
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
const h5e = @import("html5ever.zig");

const Page = @import("../Page.zig");
const Node = @import("../webapi/Node.zig");
const Element = @import("../webapi/Element.zig");
const Allocator = std.mem.Allocator;

pub const ParsedNode = struct {
    node: *Node,

    // Data associated with this element to be passed back to html5ever as needed
    // We only have this for Elements. For other types, like comments, it's null.
    // html5ever should never ask us for this data on a non-element, and we'll
    // assert that, with this opitonal, to make sure our assumption is correct.
    data: ?*anyopaque,
};

const Parser = @This();

page: *Page,
err: ?Error,
container: ParsedNode,
arena: Allocator,
strings: std.StringHashMapUnmanaged(void),

pub fn init(arena: Allocator, node: *Node, page: *Page) Parser {
    return .{
        .err = null,
        .page = page,
        .strings = .empty,
        .arena = arena,
        .container = ParsedNode{
            .data = null,
            .node = node,
        },
    };
}

const Error = struct {
    err: anyerror,
    source: Source,

    const Source = enum {
        pop,
        append,
        create_element,
        create_comment,
        append_doctype_to_document,
        add_attrs_if_missing,
        get_template_content,
        remove_from_parent,
        reparent_children,
    };
};

pub fn parse(self: *Parser, html: []const u8) void {
    h5e.html5ever_parse_document(
        html.ptr,
        html.len,
        &self.container,
        self,
        createElementCallback,
        getDataCallback,
        appendCallback,
        parseErrorCallback,
        popCallback,
        createCommentCallback,
        appendDoctypeToDocument,
        addAttrsIfMissingCallback,
        getTemplateContentsCallback,
        removeFromParentCallback,
        reparentChildrenCallback,
    );
}

pub fn parseFragment(self: *Parser, html: []const u8) void {
    h5e.html5ever_parse_fragment(
        html.ptr,
        html.len,
        &self.container,
        self,
        createElementCallback,
        getDataCallback,
        appendCallback,
        parseErrorCallback,
        popCallback,
        createCommentCallback,
        appendDoctypeToDocument,
        addAttrsIfMissingCallback,
        getTemplateContentsCallback,
        removeFromParentCallback,
        reparentChildrenCallback,
    );
}

pub const Streaming = struct {
    parser: Parser,
    handle: ?*anyopaque,

    pub fn init(arena: Allocator, node: *Node, page: *Page) Streaming {
        return .{
            .handle = null,
            .parser = Parser.init(arena, node, page),
        };
    }

    pub fn deinit(self: *Streaming) void {
        if (self.handle) |handle| {
            h5e.html5ever_streaming_parser_destroy(handle);
        }
    }

    pub fn start(self: *Streaming) !void {
        std.debug.assert(self.handle == null);

        self.handle = h5e.html5ever_streaming_parser_create(
            &self.parser.container,
            &self.parser,
            createElementCallback,
            getDataCallback,
            appendCallback,
            parseErrorCallback,
            popCallback,
            createCommentCallback,
            appendDoctypeToDocument,
            addAttrsIfMissingCallback,
            getTemplateContentsCallback,
            removeFromParentCallback,
            reparentChildrenCallback,
        ) orelse return error.ParserCreationFailed;
    }

    pub fn read(self: *Streaming, data: []const u8) void {
        h5e.html5ever_streaming_parser_feed(
            self.handle.?,
            data.ptr,
            data.len,
        );
    }

    pub fn done(self: *Streaming) void {
        h5e.html5ever_streaming_parser_finish(self.handle.?);
    }
};

fn parseErrorCallback(ctx: *anyopaque, err: h5e.StringSlice) callconv(.c) void {
    _ = ctx;
    _ = err;
    // std.debug.print("PEC: {s}\n", .{err.slice()});
}

fn popCallback(ctx: *anyopaque, node_ref: *anyopaque) callconv(.c) void {
    const self: *Parser = @ptrCast(@alignCast(ctx));
    self._popCallback(getNode(node_ref)) catch |err| {
        self.err = .{ .err = err, .source = .pop };
    };
}

fn _popCallback(self: *Parser, node: *Node) !void {
    try self.page.nodeComplete(node);
}

fn createElementCallback(ctx: *anyopaque, data: *anyopaque, qname: h5e.QualName, attributes: h5e.AttributeIterator) callconv(.c) ?*anyopaque {
    const self: *Parser = @ptrCast(@alignCast(ctx));
    return self._createElementCallback(data, qname, attributes) catch |err| {
        self.err = .{ .err = err, .source = .create_element };
        return null;
    };
}
fn _createElementCallback(self: *Parser, data: *anyopaque, qname: h5e.QualName, attributes: h5e.AttributeIterator) !*anyopaque {
    const page = self.page;
    const name = qname.local.slice();
    const namespace = qname.ns.slice();
    const node = try page.createElement(namespace, name, attributes);

    const pn = try self.arena.create(ParsedNode);
    pn.* = .{
        .data = data,
        .node = node,
    };
    return pn;
}

fn createCommentCallback(ctx: *anyopaque, str: h5e.StringSlice) callconv(.c) ?*anyopaque {
    const self: *Parser = @ptrCast(@alignCast(ctx));
    return self._createCommentCallback(str.slice()) catch |err| {
        self.err = .{ .err = err, .source = .create_comment };
        return null;
    };
}
fn _createCommentCallback(self: *Parser, str: []const u8) !*anyopaque {
    const page = self.page;
    const node = try page.createComment(str);
    const pn = try self.arena.create(ParsedNode);
    pn.* = .{
        .data = null,
        .node = node,
    };
    return pn;
}

fn appendDoctypeToDocument(ctx: *anyopaque, name: h5e.StringSlice, public_id: h5e.StringSlice, system_id: h5e.StringSlice) callconv(.c) void {
    const self: *Parser = @ptrCast(@alignCast(ctx));
    self._appendDoctypeToDocument(name.slice(), public_id.slice(), system_id.slice()) catch |err| {
        self.err = .{ .err = err, .source = .append_doctype_to_document };
    };
}
fn _appendDoctypeToDocument(self: *Parser, name: []const u8, public_id: []const u8, system_id: []const u8) !void {
    const page = self.page;

    // Create the DocumentType node
    const DocumentType = @import("../webapi/DocumentType.zig");
    const doctype = try page._factory.node(DocumentType{
        ._proto = undefined,
        ._name = try page.dupeString(name),
        ._public_id = try page.dupeString(public_id),
        ._system_id = try page.dupeString(system_id),
    });

    // Append it to the document
    try page.appendNew(self.container.node, .{ .node = doctype.asNode() });
}

fn addAttrsIfMissingCallback(ctx: *anyopaque, target_ref: *anyopaque, attributes: h5e.AttributeIterator) callconv(.c) void {
    const self: *Parser = @ptrCast(@alignCast(ctx));
    self._addAttrsIfMissingCallback(getNode(target_ref), attributes) catch |err| {
        self.err = .{ .err = err, .source = .add_attrs_if_missing };
    };
}
fn _addAttrsIfMissingCallback(self: *Parser, node: *Node, attributes: h5e.AttributeIterator) !void {
    const element = node.as(Element);
    const page = self.page;

    const attr_list = try element.getOrCreateAttributeList(page);
    while (attributes.next()) |attr| {
        const name = attr.name.local.slice();
        const value = attr.value.slice();
        // putNew only adds if the attribute doesn't already exist
        try attr_list.putNew(name, value, page);
    }
}

fn getTemplateContentsCallback(ctx: *anyopaque, target_ref: *anyopaque) callconv(.c) ?*anyopaque {
    const self: *Parser = @ptrCast(@alignCast(ctx));
    return self._getTemplateContentsCallback(getNode(target_ref)) catch |err| {
        self.err = .{ .err = err, .source = .get_template_content };
        return null;
    };
}

fn _getTemplateContentsCallback(self: *Parser, node: *Node) !*anyopaque {
    const element = node.as(Element);
    const template = element._type.html.is(Element.Html.Template) orelse unreachable;
    const content_node = template.getContent().asNode();

    // Create a ParsedNode wrapper for the content DocumentFragment
    const pn = try self.arena.create(ParsedNode);
    pn.* = .{
        .data = null,
        .node = content_node,
    };
    return pn;
}

fn getDataCallback(ctx: *anyopaque) callconv(.c) *anyopaque {
    const pn: *ParsedNode = @ptrCast(@alignCast(ctx));
    // For non-elements, data is null. But, we expect this to only ever
    // be called for elements.
    std.debug.assert(pn.data != null);
    return pn.data.?;
}

fn appendCallback(ctx: *anyopaque, parent_ref: *anyopaque, node_or_text: h5e.NodeOrText) callconv(.c) void {
    const self: *Parser = @ptrCast(@alignCast(ctx));
    self._appendCallback(getNode(parent_ref), node_or_text) catch |err| {
        self.err = .{ .err = err, .source = .append };
    };
}
fn _appendCallback(self: *Parser, parent: *Node, node_or_text: h5e.NodeOrText) !void {
    switch (node_or_text.toUnion()) {
        .node => |cpn| {
            const child = getNode(cpn);
            // child node is guaranteed not to belong to another parent
            try self.page.appendNew(parent, .{ .node = child });
        },
        .text => |txt| {
            try self.page.appendNew(parent, .{ .text = txt });
        },
    }
}

fn removeFromParentCallback(ctx: *anyopaque, target_ref: *anyopaque) callconv(.c) void {
    const self: *Parser = @ptrCast(@alignCast(ctx));
    self._removeFromParentCallback(getNode(target_ref)) catch |err| {
        self.err = .{ .err = err, .source = .remove_from_parent };
    };
}
fn _removeFromParentCallback(self: *Parser, node: *Node) !void {
    const parent = node.parentNode() orelse return;
    _ = try parent.removeChild(node, self.page);
}

fn reparentChildrenCallback(ctx: *anyopaque, node_ref: *anyopaque, new_parent_ref: *anyopaque) callconv(.c) void {
    const self: *Parser = @ptrCast(@alignCast(ctx));
    self._reparentChildrenCallback(getNode(node_ref), getNode(new_parent_ref)) catch |err| {
        self.err = .{ .err = err, .source = .reparent_children };
    };
}
fn _reparentChildrenCallback(self: *Parser, node: *Node, new_parent: *Node) !void {
    try self.page.appendAllChildren(node, new_parent);
}

fn getNode(ref: *anyopaque) *Node {
    const pn: *ParsedNode = @ptrCast(@alignCast(ref));
    return pn.node;
}

fn asUint(comptime string: anytype) std.meta.Int(
    .unsigned,
    @bitSizeOf(@TypeOf(string.*)) - 8, // (- 8) to exclude sentinel 0
) {
    const byteLength = @sizeOf(@TypeOf(string.*)) - 1;
    const expectedType = *const [byteLength:0]u8;
    if (@TypeOf(string) != expectedType) {
        @compileError("expected : " ++ @typeName(expectedType) ++ ", got: " ++ @typeName(@TypeOf(string)));
    }

    return @bitCast(@as(*const [byteLength]u8, string).*);
}
