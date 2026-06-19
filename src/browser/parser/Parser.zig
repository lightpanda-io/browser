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
const lp = @import("lightpanda");
const h5e = @import("html5ever.zig");

const Frame = @import("../Frame.zig");
const Node = @import("../webapi/Node.zig");
const Element = @import("../webapi/Element.zig");
const CData = @import("../webapi/CData.zig");

pub const AttributeIterator = h5e.AttributeIterator;

const Allocator = std.mem.Allocator;
const IS_DEBUG = @import("builtin").mode == .Debug;

pub const ParsedNode = struct {
    node: *Node,

    // Data associated with this element to be passed back to html5ever as needed
    // We only have this for Elements. For other types, like comments, it's null.
    // html5ever should never ask us for this data on a non-element, and we'll
    // assert that, with this optional, to make sure our assumption is correct.
    data: ?*anyopaque,
};

// html5ever's tokenizer flushes the script-data character buffer on every '<'
// (script-data-less-than-sign-state transition), which produces a separate
// AppendText callback per chunk. Merging via String.concat in the previous
// implementation was O(N^2/chunk_size) on the page-lifetime arena, blowing
// memory on inline JS that contains embedded HTML strings (issue #2397).
// Instead, we keep a single Parser-level buf and accumulate same-parent
// chunks into it, committing once on flush.
const PendingText = struct {
    parent: *Node,
    text_node: *CData,
};

const Parser = @This();

frame: *Frame,
err: ?Error,
container: ParsedNode,
arena: Allocator,
strings: std.StringHashMapUnmanaged(void),
pending_text: ?PendingText,
// One buffer reused across every text run in this parser. clearRetainingCapacity
// on flush keeps the largest capacity ever needed, so total dead memory on the
// parser arena is bounded to one peak-run-sized allocation regardless of how
// many text runs the parse contains. Matters for Streaming, whose arena is the
// page-lifetime frame.arena (individual frees are no-ops there).
//
// Single-chunk text runs leave this buf empty: the chunk lives only in
// CData._data via createTextNode. The buf is seeded from _data.str() on the
// second chunk of a run, so the common case stays at one copy.
buf: std.ArrayList(u8),

// Whether `<template shadowrootmode>` is parsed into a real shadow root.
// True for document navigation, document.write, and setHTMLUnsafe; false for
// innerHTML and DOMParser (per spec). Set from Options at init.
allow_declarative_shadow: bool = false,

pub const Options = struct {
    allow_declarative_shadow: bool = false,
};

pub fn init(arena: Allocator, node: *Node, frame: *Frame, opts: Options) Parser {
    return .{
        .err = null,
        .frame = frame,
        .strings = .empty,
        .arena = arena,
        .container = ParsedNode{
            .data = null,
            .node = node,
        },
        .pending_text = null,
        .buf = .empty,
        .allow_declarative_shadow = opts.allow_declarative_shadow,
    };
}

pub fn flushPendingText(self: *Parser) !void {
    const pt = self.pending_text orelse return;
    self.pending_text = null;
    // Single-chunk run: data already lives on _data via createTextNode.
    if (self.buf.items.len == 0) return;
    defer self.buf.clearRetainingCapacity();
    pt.text_node._data = try lp.String.init(
        self.frame.arena,
        self.buf.items,
        .{ .dupe = true },
    );
}

fn appendTextChunk(self: *Parser, parent: *Node, txt: []const u8) !void {
    if (self.pending_text) |pt| {
        if (pt.parent == parent and parent.lastChild() == pt.text_node.asNode()) {
            // Second+ chunk of the same run. If buf is still empty, promote
            // from the single-chunk fast path by seeding from _data first.
            if (self.buf.items.len == 0) {
                const existing = pt.text_node.getData().str();
                try self.buf.ensureTotalCapacity(self.arena, existing.len + txt.len);
                self.buf.appendSliceAssumeCapacity(existing);
            }
            try self.buf.appendSlice(self.arena, txt);
            return;
        }
        try self.flushPendingText();
    }

    if (parent.lastChild()) |sibling| {
        if (sibling.is(CData.Text)) |tn| {
            // Existing text sibling without a matching pending_text. Seed the
            // buf from its _data and register pending so subsequent chunks
            // accumulate cheaply.
            const cdata = tn._proto;
            const existing = cdata.getData().str();
            try self.buf.ensureTotalCapacity(self.arena, existing.len + txt.len);
            self.buf.appendSliceAssumeCapacity(existing);
            self.buf.appendSliceAssumeCapacity(txt);
            self.pending_text = .{ .parent = parent, .text_node = cdata };
            return;
        }
    }

    // Fresh text run: the first chunk lives on _data only. buf stays empty
    // until (and unless) a second chunk arrives.
    const new_text = try Frame.node_factory.createTextNode(self.frame, txt);
    try self.frame.appendNew(parent, new_text);
    self.pending_text = .{
        .parent = parent,
        .text_node = new_text.is(CData.Text).?._proto,
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
        create_processing_instruction,
        append_doctype_to_document,
        add_attrs_if_missing,
        get_template_content,
        remove_from_parent,
        reparent_children,
        append_before_sibling,
        append_based_on_parent_node,
        attach_declarative_shadow,
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
        createProcessingInstruction,
        appendDoctypeToDocument,
        addAttrsIfMissingCallback,
        getTemplateContentsCallback,
        removeFromParentCallback,
        reparentChildrenCallback,
        appendBeforeSiblingCallback,
        appendBasedOnParentNodeCallback,
        attachDeclarativeShadowCallback,
        self.allow_declarative_shadow,
    );
    self.flushPendingText() catch |err| {
        if (self.err == null) self.err = .{ .err = err, .source = .append };
    };
}

/// Parse HTML with encoding conversion. Converts from charset to UTF-8 before parsing.
pub fn parseWithEncoding(self: *Parser, html: []const u8, charset: []const u8) void {
    h5e.html5ever_parse_document_with_encoding(
        html.ptr,
        html.len,
        charset.ptr,
        charset.len,
        &self.container,
        self,
        createElementCallback,
        getDataCallback,
        appendCallback,
        parseErrorCallback,
        popCallback,
        createCommentCallback,
        createProcessingInstruction,
        appendDoctypeToDocument,
        addAttrsIfMissingCallback,
        getTemplateContentsCallback,
        removeFromParentCallback,
        reparentChildrenCallback,
        appendBeforeSiblingCallback,
        appendBasedOnParentNodeCallback,
        attachDeclarativeShadowCallback,
        self.allow_declarative_shadow,
    );
    self.flushPendingText() catch |err| {
        if (self.err == null) self.err = .{ .err = err, .source = .append };
    };
}

pub fn parseXML(self: *Parser, xml: []const u8) void {
    h5e.xml5ever_parse_document(
        xml.ptr,
        xml.len,
        &self.container,
        self,
        createXMLElementCallback,
        getDataCallback,
        appendCallback,
        parseErrorCallback,
        popCallback,
        createCommentCallback,
        createProcessingInstruction,
        appendDoctypeToDocument,
        addAttrsIfMissingCallback,
        getTemplateContentsCallback,
        removeFromParentCallback,
        reparentChildrenCallback,
        appendBeforeSiblingCallback,
        appendBasedOnParentNodeCallback,
        attachDeclarativeShadowCallback,
        false,
    );
    self.flushPendingText() catch |err| {
        if (self.err == null) self.err = .{ .err = err, .source = .append };
    };
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
        createProcessingInstruction,
        appendDoctypeToDocument,
        addAttrsIfMissingCallback,
        getTemplateContentsCallback,
        removeFromParentCallback,
        reparentChildrenCallback,
        appendBeforeSiblingCallback,
        appendBasedOnParentNodeCallback,
        attachDeclarativeShadowCallback,
        self.allow_declarative_shadow,
    );
    self.flushPendingText() catch |err| {
        if (self.err == null) self.err = .{ .err = err, .source = .append };
    };
}

pub const Streaming = struct {
    parser: Parser,
    handle: ?*anyopaque,

    // True while html5ever is inside a feed/finish call. A <script> popped by
    // the tokenizer runs synchronously during the feed and can call
    // document.write(), which re-enters read(). html5ever's streaming parser
    // is NOT re-entrant — feeding it while it's still inside
    // process_to_completion corrupts its tree-builder state and we get a panic.
    feeding: bool = false,

    // Bytes queued by document.write() calls that happened while `feeding`.
    // Drained by the active read() loop. Lives on the parser arena.
    pending_input: std.ArrayList(u8) = .empty,

    pub fn init(arena: Allocator, node: *Node, frame: *Frame, opts: Options) Streaming {
        return .{
            .handle = null,
            .parser = Parser.init(arena, node, frame, opts),
        };
    }

    pub fn deinit(self: *Streaming) void {
        if (self.handle) |handle| {
            h5e.html5ever_streaming_parser_destroy(handle);
        }
    }

    pub fn start(self: *Streaming) !void {
        lp.assert(self.handle == null, "Parser.start non-null handle", .{});

        self.handle = h5e.html5ever_streaming_parser_create(
            &self.parser.container,
            &self.parser,
            createElementCallback,
            getDataCallback,
            appendCallback,
            parseErrorCallback,
            popCallback,
            createCommentCallback,
            createProcessingInstruction,
            appendDoctypeToDocument,
            addAttrsIfMissingCallback,
            getTemplateContentsCallback,
            removeFromParentCallback,
            reparentChildrenCallback,
            appendBeforeSiblingCallback,
            appendBasedOnParentNodeCallback,
            attachDeclarativeShadowCallback,
            self.parser.allow_declarative_shadow,
        ) orelse return error.ParserCreationFailed;
    }

    pub fn read(self: *Streaming, data: []const u8) !void {
        if (self.feeding) {
            // Re-entrant document.write() from a script running inside the
            // current feed. Append at the insertion point; the active feed
            // loop below drains it rather than recursing into feed().
            return self.pending_input.appendSlice(self.parser.arena, data);
        }

        self.feeding = true;
        defer self.feeding = false;

        var input = data;
        while (true) {
            try self.feed(input);
            if (self.pending_input.items.len == 0) {
                return;
            }
            // Scripts that ran during the feed queued more markup via
            // re-entrant read(). This swaps the buffers, and ensures that
            // any new writes to pending_input don't invalidate the input
            input = try self.pending_input.toOwnedSlice(self.parser.arena);
        }
    }

    fn feed(self: *Streaming, data: []const u8) !void {
        const result = h5e.html5ever_streaming_parser_feed(
            self.handle.?,
            data.ptr,
            data.len,
        );

        if (result != 0) {
            // Parser panicked - clean up and return error
            // Note: deinit will destroy the handle if it exists
            if (self.handle) |handle| {
                h5e.html5ever_streaming_parser_destroy(handle);
                self.handle = null;
            }
            return error.ParserPanic;
        }
    }

    pub fn done(self: *Streaming) !void {
        // Null the handle before finish() so a flushPendingText failure can't
        // leave a finished-but-still-referenced handle behind for deinit to
        // double-free. flushPendingText doesn't touch the html5ever handle —
        // it only reads pending_text and writes to a text node's _data — so
        // running it after finish is safe.
        const handle = self.handle.?;
        self.handle = null;

        self.feeding = true;
        defer self.feeding = false;

        h5e.html5ever_streaming_parser_finish(handle);
        if (self.pending_input.items.len != 0) {
            lp.log.warn(.dom, "write during finish dropped", .{ .len = self.pending_input.items.len });
            self.pending_input.clearRetainingCapacity();
        }
        try self.parser.flushPendingText();
    }
};

fn parseErrorCallback(ctx: *anyopaque, err: h5e.StringSlice) callconv(.c) void {
    _ = ctx;
    _ = err;
    // std.debug.print("PEC: {s}\n", .{err.slice()});
}

fn popCallback(ctx: *anyopaque, node_ref: *anyopaque) callconv(.c) void {
    const self: *Parser = @ptrCast(@alignCast(ctx));
    const cp = self.frame._ce_reactions.push();
    defer self.frame._ce_reactions.popAndInvoke(cp, self.frame);
    self._popCallback(getNode(node_ref)) catch |err| {
        self.err = .{ .err = err, .source = .pop };
    };
}

fn _popCallback(self: *Parser, node: *Node) !void {
    // Flush before any nodeComplete so Build.complete (and any custom-element
    // callbacks reachable from it) observe the final text data.
    try self.flushPendingText();
    try self.frame.nodeComplete(node);
}

fn createElementCallback(ctx: *anyopaque, data: *anyopaque, qname: h5e.QualName, attributes: h5e.AttributeIterator) callconv(.c) ?*anyopaque {
    return _createElementCallbackWithDefaultnamespace(ctx, data, qname, attributes, .unknown);
}

fn createXMLElementCallback(ctx: *anyopaque, data: *anyopaque, qname: h5e.QualName, attributes: h5e.AttributeIterator) callconv(.c) ?*anyopaque {
    return _createElementCallbackWithDefaultnamespace(ctx, data, qname, attributes, .xml);
}

fn _createElementCallbackWithDefaultnamespace(ctx: *anyopaque, data: *anyopaque, qname: h5e.QualName, attributes: h5e.AttributeIterator, default_namespace: Element.Namespace) ?*anyopaque {
    const self: *Parser = @ptrCast(@alignCast(ctx));
    const cp = self.frame._ce_reactions.push();
    defer self.frame._ce_reactions.popAndInvoke(cp, self.frame);
    return self._createElementCallback(data, qname, attributes, default_namespace) catch |err| {
        self.err = .{ .err = err, .source = .create_element };
        return null;
    };
}
fn _createElementCallback(self: *Parser, data: *anyopaque, qname: h5e.QualName, attributes: h5e.AttributeIterator, default_namespace: Element.Namespace) !*anyopaque {
    const frame = self.frame;
    const name = qname.local.slice();
    const namespace_string = qname.ns.slice();
    const namespace = if (namespace_string.len == 0) default_namespace else Element.Namespace.parse(namespace_string);
    const node = try Frame.node_factory.createElementNS(frame, namespace, name, attributes);

    const pn = try self.arena.create(ParsedNode);
    pn.* = .{
        .data = data,
        .node = node,
    };
    return pn;
}

fn createCommentCallback(ctx: *anyopaque, str: h5e.StringSlice) callconv(.c) ?*anyopaque {
    const self: *Parser = @ptrCast(@alignCast(ctx));
    const cp = self.frame._ce_reactions.push();
    defer self.frame._ce_reactions.popAndInvoke(cp, self.frame);
    return self._createCommentCallback(str.slice()) catch |err| {
        self.err = .{ .err = err, .source = .create_comment };
        return null;
    };
}
fn _createCommentCallback(self: *Parser, str: []const u8) !*anyopaque {
    const frame = self.frame;
    const node = try Frame.node_factory.createComment(frame, str);
    const pn = try self.arena.create(ParsedNode);
    pn.* = .{
        .data = null,
        .node = node,
    };
    return pn;
}

fn createProcessingInstruction(ctx: *anyopaque, target: h5e.StringSlice, data: h5e.StringSlice) callconv(.c) ?*anyopaque {
    const self: *Parser = @ptrCast(@alignCast(ctx));
    const cp = self.frame._ce_reactions.push();
    defer self.frame._ce_reactions.popAndInvoke(cp, self.frame);
    return self._createProcessingInstruction(target.slice(), data.slice()) catch |err| {
        self.err = .{ .err = err, .source = .create_processing_instruction };
        return null;
    };
}
fn _createProcessingInstruction(self: *Parser, target: []const u8, data: []const u8) !*anyopaque {
    const frame = self.frame;
    const node = try Frame.node_factory.createProcessingInstruction(frame, target, data);
    const pn = try self.arena.create(ParsedNode);
    pn.* = .{
        .data = null,
        .node = node,
    };
    return pn;
}

fn appendDoctypeToDocument(ctx: *anyopaque, name: h5e.StringSlice, public_id: h5e.StringSlice, system_id: h5e.StringSlice) callconv(.c) void {
    const self: *Parser = @ptrCast(@alignCast(ctx));
    const cp = self.frame._ce_reactions.push();
    defer self.frame._ce_reactions.popAndInvoke(cp, self.frame);
    self._appendDoctypeToDocument(name.slice(), public_id.slice(), system_id.slice()) catch |err| {
        self.err = .{ .err = err, .source = .append_doctype_to_document };
    };
}
fn _appendDoctypeToDocument(self: *Parser, name: []const u8, public_id: []const u8, system_id: []const u8) !void {
    const frame = self.frame;

    // Create the DocumentType node
    const DocumentType = @import("../webapi/DocumentType.zig");
    const doctype = try frame._factory.node(DocumentType{
        ._proto = undefined,
        ._name = try frame.dupeString(name),
        ._public_id = try frame.dupeString(public_id),
        ._system_id = try frame.dupeString(system_id),
    });

    // Append it to the document
    try frame.appendNew(self.container.node, doctype.asNode());
}

fn addAttrsIfMissingCallback(ctx: *anyopaque, target_ref: *anyopaque, attributes: h5e.AttributeIterator) callconv(.c) void {
    const self: *Parser = @ptrCast(@alignCast(ctx));
    const cp = self.frame._ce_reactions.push();
    defer self.frame._ce_reactions.popAndInvoke(cp, self.frame);
    self._addAttrsIfMissingCallback(getNode(target_ref), attributes) catch |err| {
        self.err = .{ .err = err, .source = .add_attrs_if_missing };
    };
}
fn _addAttrsIfMissingCallback(self: *Parser, node: *Node, attributes: h5e.AttributeIterator) !void {
    const element = node.as(Element);
    const frame = self.frame;

    const attr_list = try element.getOrCreateAttributeList(frame);
    while (attributes.next()) |attr| {
        const name = attr.name.local.slice();
        const value = attr.value.slice();
        // putNew only adds if the attribute doesn't already exist
        try attr_list.putNew(name, value, frame);
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

// Called for `<template shadowrootmode>` when declarative shadow roots are
// allowed. Attaches a shadow root to `host` and redirects the (stack-only)
// template's contents into it, so html5ever parses the template's children
// straight into the shadow root. Returns 1 on success, 0 to tell html5ever to
// fall back to inserting the template as a normal light-DOM element.
fn attachDeclarativeShadowCallback(ctx: *anyopaque, host_ref: *anyopaque, template_ref: *anyopaque, mode_is_open: u8) callconv(.c) u8 {
    const self: *Parser = @ptrCast(@alignCast(ctx));
    return self._attachDeclarativeShadowCallback(getNode(host_ref), getNode(template_ref), mode_is_open != 0) catch |err| {
        self.err = .{ .err = err, .source = .attach_declarative_shadow };
        return 0;
    };
}

fn _attachDeclarativeShadowCallback(self: *Parser, host_node: *Node, template_node: *Node, mode_is_open: bool) !u8 {
    // guaranteed by html5ever
    const host = host_node.as(Element);
    const template_el = template_node.as(Element);
    const shadow = host.attachShadow(.{
        .declarative = true,
        .mode = if (mode_is_open) .open else .closed,
        .delegates_focus = template_el.hasAttributeSafe(.wrap("shadowrootdelegatesfocus")),
        .clonable = template_el.hasAttributeSafe(.wrap("shadowrootclonable")),
        .serializable = template_el.hasAttributeSafe(.wrap("shadowrootserializable")),
    }, self.frame) catch |err| switch (err) {
        error.NotSupported => return 0,
        else => return err,
    };

    const template = template_el.is(Element.Html.Template) orelse return 0;
    template._content = shadow.asDocumentFragment();
    return 1;
}

fn getDataCallback(ctx: *anyopaque) callconv(.c) *anyopaque {
    const pn: *ParsedNode = @ptrCast(@alignCast(ctx));
    // For non-elements, data is null. But, we expect this to only ever
    // be called for elements.
    lp.assert(pn.data != null, "Parser.getDataCallback null data", .{});
    return pn.data.?;
}

fn appendCallback(ctx: *anyopaque, parent_ref: *anyopaque, node_or_text: h5e.NodeOrText) callconv(.c) void {
    const self: *Parser = @ptrCast(@alignCast(ctx));
    const cp = self.frame._ce_reactions.push();
    defer self.frame._ce_reactions.popAndInvoke(cp, self.frame);
    self._appendCallback(getNode(parent_ref), node_or_text) catch |err| {
        self.err = .{ .err = err, .source = .append };
    };
}
fn _appendCallback(self: *Parser, parent: *Node, node_or_text: h5e.NodeOrText) !void {
    // child node is guaranteed not to belong to another parent
    switch (node_or_text.toUnion()) {
        .node => |cpn| {
            // Inserting a non-text child terminates any pending text run; flush
            // before the insertion so that connectedCallback (etc.) sees the
            // final data on the preceding text sibling.
            try self.flushPendingText();
            const child = getNode(cpn);
            if (child._parent) |previous_parent| {
                // html5ever says this can't happen, but we might be screwing up
                // the node on our side. We shouldn't be, but we're seeing this
                // in the wild, and I'm not sure why. In debug, let's crash so
                // we can try to figure it out. In release, let's disconnect
                // the child first.
                if (comptime IS_DEBUG) {
                    unreachable;
                }
                self.frame.removeNode(previous_parent, child, .{ .will_be_reconnected = parent.isConnected() });
            }
            try self.frame.appendNew(parent, child);
        },
        .text => |txt| try self.appendTextChunk(parent, txt),
    }
}

fn removeFromParentCallback(ctx: *anyopaque, target_ref: *anyopaque) callconv(.c) void {
    const self: *Parser = @ptrCast(@alignCast(ctx));
    const cp = self.frame._ce_reactions.push();
    defer self.frame._ce_reactions.popAndInvoke(cp, self.frame);
    self._removeFromParentCallback(getNode(target_ref)) catch |err| {
        self.err = .{ .err = err, .source = .remove_from_parent };
    };
}
fn _removeFromParentCallback(self: *Parser, node: *Node) !void {
    // Removing a node mid-parse can detach the pending text node or its
    // parent; either way the pending invariant breaks. Flush first so the
    // accumulated bytes land on a still-attached text node (and pending_text
    // is cleared before any subsequent chunk targets a fresh node).
    try self.flushPendingText();
    const parent = node.parentNode() orelse return;
    _ = try parent.removeChild(node, self.frame);
}

fn reparentChildrenCallback(ctx: *anyopaque, node_ref: *anyopaque, new_parent_ref: *anyopaque) callconv(.c) void {
    const self: *Parser = @ptrCast(@alignCast(ctx));
    const cp = self.frame._ce_reactions.push();
    defer self.frame._ce_reactions.popAndInvoke(cp, self.frame);
    self._reparentChildrenCallback(getNode(node_ref), getNode(new_parent_ref)) catch |err| {
        self.err = .{ .err = err, .source = .reparent_children };
    };
}
fn _reparentChildrenCallback(self: *Parser, node: *Node, new_parent: *Node) !void {
    // Reparenting can move the pending text node out from under us — the
    // node's _parent changes but pending_text.parent does not. Flush so the
    // accumulator commits before the tree is rearranged.
    try self.flushPendingText();
    try self.frame.appendAllChildren(node, new_parent);
}

fn appendBeforeSiblingCallback(ctx: *anyopaque, sibling_ref: *anyopaque, node_or_text: h5e.NodeOrText) callconv(.c) void {
    const self: *Parser = @ptrCast(@alignCast(ctx));
    const cp = self.frame._ce_reactions.push();
    defer self.frame._ce_reactions.popAndInvoke(cp, self.frame);
    self._appendBeforeSiblingCallback(getNode(sibling_ref), node_or_text) catch |err| {
        self.err = .{ .err = err, .source = .append_before_sibling };
    };
}
fn _appendBeforeSiblingCallback(self: *Parser, sibling: *Node, node_or_text: h5e.NodeOrText) !void {
    // Foster parenting / before-sibling insertions interrupt any pending text
    // run (the new node lands at a different position from the pending text's
    // tail). Flush before reading the parent's structure.
    try self.flushPendingText();
    const parent = sibling.parentNode() orelse return error.NoParent;
    const node: *Node = switch (node_or_text.toUnion()) {
        .node => |cpn| blk: {
            const child = getNode(cpn);
            if (child._parent) |previous_parent| {
                // A custom element constructor may have inserted the node into the
                // DOM before the parser officially places it (e.g. via foster
                // parenting). Detach it first so insertNodeRelative's assertion holds.
                self.frame.removeNode(previous_parent, child, .{ .will_be_reconnected = parent.isConnected() });
            }
            break :blk child;
        },
        .text => |txt| try Frame.node_factory.createTextNode(self.frame, txt),
    };
    try self.frame.insertNodeRelative(parent, node, .{ .before = sibling }, .{});
}

fn appendBasedOnParentNodeCallback(ctx: *anyopaque, element_ref: *anyopaque, prev_element_ref: *anyopaque, node_or_text: h5e.NodeOrText) callconv(.c) void {
    const self: *Parser = @ptrCast(@alignCast(ctx));
    const cp = self.frame._ce_reactions.push();
    defer self.frame._ce_reactions.popAndInvoke(cp, self.frame);
    self._appendBasedOnParentNodeCallback(getNode(element_ref), getNode(prev_element_ref), node_or_text) catch |err| {
        self.err = .{ .err = err, .source = .append_based_on_parent_node };
    };
}
fn _appendBasedOnParentNodeCallback(self: *Parser, element: *Node, prev_element: *Node, node_or_text: h5e.NodeOrText) !void {
    if (element.parentNode()) |_| {
        try self._appendBeforeSiblingCallback(element, node_or_text);
    } else {
        try self._appendCallback(prev_element, node_or_text);
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
