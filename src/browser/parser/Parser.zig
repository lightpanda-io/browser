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
    _ = public_id;
    _ = system_id;

    const self: *Parser = @ptrCast(@alignCast(ctx));
    self._appendDoctypeToDocument(name.slice()) catch |err| {
        self.err = .{ .err = err, .source = .append_doctype_to_document };
    };
}
fn _appendDoctypeToDocument(self: *Parser, name: []const u8) !void {
    _ = self;
    _ = name;
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
