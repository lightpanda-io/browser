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
const Frame = @import("Frame.zig");
const RenderTree = @import("RenderTree.zig");
const LimitedWriter = @import("../LimitedWriter.zig");
const Node = @import("webapi/Node.zig");
const Slot = @import("webapi/element/html/Slot.zig");
const IFrame = @import("webapi/element/html/IFrame.zig");

pub const Opts = struct {
    with_base: bool = false,
    with_frames: bool = false,
    strip: Opts.Strip = .{},
    shadow: Opts.Shadow = .rendered,

    /// Soft cap: output is cut at a UTF-8 boundary and a truncation marker
    /// appended.
    max_bytes: ?u32 = null,

    // Nodes to remove (clutter remove, from RenderTree.resolve)
    pruned: ?*const RenderTree.PruneSet = null,

    pub const Strip = packed struct(u6) {
        js: bool = false,
        ui: bool = false,
        css: bool = false,
        invisible: bool = false,
        shell: bool = false,
        clutter: bool = false,
    };

    pub const Shadow = union(enum) {
        // Skip shadow DOM entirely (innerHTML/outerHTML)
        skip,

        // Dump everything (like "view source")
        complete,

        // Resolve slot elements (like what actually gets rendered)
        rendered,

        // Element/ShadowRoot.getHTML can control how it handles shadow elements
        declarative: Declarative,

        pub const Declarative = struct {
            // Serialize shadow roots whose `serializable` flag is set
            serializable_shadow_roots: bool = false,
            // Serialize these roots regardless of their flags or mode
            shadow_roots: []const *Node.ShadowRoot = &.{},
        };
    };
};

pub fn root(doc: *Node.Document, opts: Opts, writer: *std.Io.Writer, frame: *Frame) !void {
    if (opts.max_bytes == null) return rootUncapped(doc, opts, writer, frame);

    var lw: LimitedWriter = .init(writer, opts.max_bytes);
    rootUncapped(doc, opts, &lw.writer, frame) catch |err| {
        if (!lw.truncated) return err;
        try writer.writeAll(LimitedWriter.truncation_marker);
    };
}

fn rootUncapped(doc: *Node.Document, opts: Opts, writer: *std.Io.Writer, frame: *Frame) !void {
    if (doc.is(Node.Document.HTMLDocument)) |html_doc| {
        blk: {
            // Ideally we just render the doctype which is part of the document
            if (doc.asNode().firstChild()) |first| {
                if (first._type == .document_type) {
                    break :blk;
                }
            }
            // But if the doc has no child, or the first child isn't a doctype
            // we'll force it.
            try writer.writeAll("<!DOCTYPE html>");
        }

        if (opts.with_base) {
            const parent = if (html_doc.getHead()) |head| head.asNode() else doc.asNode();
            const base = try doc.createElement("base", null, frame);
            try base.setAttributeSafe(comptime .wrap("href"), .wrap(frame.base()), frame);
            _ = try parent.insertBefore(base.asNode(), parent.firstChild(), frame);
        }
    }

    return _deep(doc.asNode(), opts, writer, frame);
}

pub fn deep(node: *Node, opts: Opts, writer: *std.Io.Writer, frame: *Frame) Error!void {
    if (opts.max_bytes == null) {
        return _deep(node, opts, writer, frame);
    }

    var lw: LimitedWriter = .init(writer, opts.max_bytes);
    _deep(node, opts, &lw.writer, frame) catch |err| {
        if (!lw.truncated) return err;
        try writer.writeAll(LimitedWriter.truncation_marker);
    };
}

fn _deep(node: *Node, opts: Opts, writer: *std.Io.Writer, frame: *Frame) Error!void {
    var walk: Walk = .init(opts, writer, frame);
    defer walk.deinit();
    try walk.visit(node, false);
    return walk.run();
}

pub fn render(state: RenderTree.State, opts: Opts, writer: *std.Io.Writer, frame: *Frame) !void {
    var o = opts;
    o.strip = state.strip;
    o.pruned = state.pruned;
    if (state.root.is(Node.Document)) |doc| return root(doc, o, writer, frame);
    return deep(state.root, o, writer, frame);
}

const Error = error{ WriteFailed, OutOfMemory };

// Very large trees can stackoverflow, hence we switch to an iterative walk
const Walk = struct {
    opts: Opts,
    writer: *std.Io.Writer,
    frame: *Frame,
    stack: std.ArrayList(Open) = .empty,

    // Content still to write, followed by the end tag
    const Open = struct {
        end_tag: ?[]const u8,
        rest: Rest,
    };

    const Rest = union(enum) {
        siblings: ?*Node,
        // Nodes assigned to a slot. Rendered despite their slot attribute.
        assigned: []const *Node,
        // An iframe's content document (opts.with_frames)
        document: ?*Node.Document,
    };

    fn init(opts: Opts, writer: *std.Io.Writer, frame: *Frame) Walk {
        return .{ .opts = opts, .writer = writer, .frame = frame };
    }

    // No JS runs during a walk, so nothing resets local_arena under the stack.
    // The stack is normally its latest allocation: it grows in place, and
    // freeing it here hands the bytes back even when no Caller ever resets
    // the arena (CDP, fetch).
    fn deinit(self: *Walk) void {
        self.stack.deinit(self.frame.local_arena);
    }

    fn run(self: *Walk) Error!void {
        while (self.stack.items.len > 0) {
            // Cursors advance before visit(), which can grow (move) the stack.
            const top = &self.stack.items[self.stack.items.len - 1];
            switch (top.rest) {
                .siblings => |*cursor| if (cursor.*) |n| {
                    cursor.* = n.nextSibling();
                    try self.visit(n, false);
                    continue;
                },
                .assigned => |*nodes| if (nodes.len > 0) {
                    const n = nodes.*[0];
                    nodes.* = nodes.*[1..];
                    try self.visit(n, true);
                    continue;
                },
                .document => |*doc| if (doc.*) |d| {
                    doc.* = null;
                    try self.contentDocument(d);
                    continue;
                },
            }
            const done = self.stack.pop().?;
            if (done.end_tag) |name| {
                try self.writeEndTag(name);
            }
        }
    }

    fn open(self: *Walk, end_tag: ?[]const u8, rest: Rest) !void {
        return self.stack.append(self.frame.local_arena, .{ .end_tag = end_tag, .rest = rest });
    }

    fn writeEndTag(self: *Walk, name: []const u8) !void {
        try self.writer.writeAll("</");
        try self.writer.writeAll(name);
        try self.writer.writeByte('>');
    }

    fn contentDocument(self: *Walk, doc: *Node.Document) !void {
        if (comptime lp.IS_DEBUG) {
            // A frame's document should always have a frame, but
            // I'm not willing to crash a release build on that assertion.
            std.debug.assert(doc._frame != null);
        }
        if (doc._frame) |f| {
            try self.writer.writeByte('\n');
            root(doc, self.opts, self.writer, f) catch return error.WriteFailed;
            try self.writer.writeByte('\n');
        }
    }

    // The spec's "attach a declarative shadow root" serialization: attribute order
    // is fixed, and boolean attributes serialize with an explicit ="".
    fn declarativeShadow(self: *Walk, shadow: *Node.ShadowRoot) !void {
        const writer = self.writer;
        try writer.writeAll("<template shadowrootmode=\"");
        try writer.writeAll(@tagName(shadow._mode));
        try writer.writeByte('"');
        if (shadow._delegates_focus) {
            try writer.writeAll(" shadowrootdelegatesfocus=\"\"");
        }
        if (shadow._serializable) {
            try writer.writeAll(" shadowrootserializable=\"\"");
        }
        if (shadow._clonable) {
            try writer.writeAll(" shadowrootclonable=\"\"");
        }
        try writer.writeByte('>');
        try self.open("template", .{ .siblings = shadow.asNode().firstChild() });
    }

    fn visit(self: *Walk, node: *Node, force_slot: bool) Error!void {
        const opts = self.opts;
        const writer = self.writer;
        const frame = self.frame;

        switch (node._type) {
            .cdata => {
                if (opts.pruned) |set| {
                    if (set.contains(node)) return;
                }
                const cd = node.subtype(Node.CData);
                if (node.is(Node.CData.Comment)) |_| {
                    try writer.writeAll("<!--");
                    try writer.writeAll(cd.getData().str());
                    try writer.writeAll("-->");
                } else if (node.is(Node.CData.ProcessingInstruction)) |pi| {
                    try writer.writeAll("<?");
                    try writer.writeAll(pi._target);
                    try writer.writeAll(" ");
                    try writer.writeAll(cd.getData().str());
                    try writer.writeAll("?>");
                } else {
                    if (shouldEscapeText(node._parent)) {
                        try writeEscapedText(cd.getData().str(), writer);
                    } else {
                        try writer.writeAll(cd.getData().str());
                    }
                }
            },
            .element => {
                const el = node.subtype(Node.Element);
                if (shouldStripElement(el, opts.strip, opts.pruned, frame)) {
                    return;
                }

                // When opts.shadow == .rendered, we normally skip any element with
                // a slot attribute. Only the "active" element will get rendered into
                // the <slot name="X">. force_slot is set when rendering that
                // "active" content, in which case we don't want to skip it.
                if (force_slot == false and opts.shadow == .rendered) {
                    if (el.getSlot()) |_| {
                        // Skip - will be rendered by the Slot if it's the active container
                        return;
                    }
                }

                try el.format(writer);

                if (opts.shadow == .rendered) {
                    if (el.is(Slot)) |slot| {
                        const assigned = slot.assignedNodes(null, frame) catch &.{};
                        if (assigned.len > 0) {
                            return self.open("slot", .{ .assigned = assigned });
                        }
                        return self.open("slot", .{ .siblings = node.firstChild() });
                    }
                }

                const end_tag: ?[]const u8 = if (isVoidElement(el)) null else el.getTagNameDump();

                const shadow = switch (opts.shadow) {
                    .skip => null,
                    .complete, .rendered, .declarative => el.hostedShadowRoot(frame),
                };

                const sr = shadow orelse {
                    if (opts.with_frames and el.is(IFrame) != null) {
                        return self.open(end_tag, .{ .document = el.as(IFrame).getContentDocument() });
                    }
                    if (node.firstChild()) |first| {
                        return self.open(end_tag, .{ .siblings = first });
                    }
                    // No children: skip the stack
                    if (end_tag) |name| {
                        try self.writeEndTag(name);
                    }
                    return;
                };

                switch (opts.shadow) {
                    .skip => unreachable,
                    // In rendered mode, light DOM is only shown through slots, not directly
                    .rendered => try self.open(end_tag, .{ .siblings = sr.asNode().firstChild() }),
                    // The stack is LIFO: the light DOM is opened first so that the
                    // shadow tree, opened after, is written before it.
                    .complete => {
                        try self.open(end_tag, .{ .siblings = node.firstChild() });
                        try self.open(null, .{ .siblings = sr.asNode().firstChild() });
                    },
                    .declarative => |declarative| {
                        try self.open(end_tag, .{ .siblings = node.firstChild() });
                        if (shouldSerializeShadow(sr, declarative)) {
                            try self.declarativeShadow(sr);
                        }
                    },
                }
            },
            .document, .document_fragment => try self.open(null, .{ .siblings = node.firstChild() }),
            .document_type => {
                const dt = node.subtype(Node.DocumentType);
                try writer.writeAll("<!DOCTYPE ");
                try writer.writeAll(dt.getName());

                const public_id = dt.getPublicId();
                const system_id = dt.getSystemId();
                if (public_id.len != 0 and system_id.len != 0) {
                    try writer.writeAll(" PUBLIC \"");
                    try writeEscapedText(public_id, writer);
                    try writer.writeAll("\" \"");
                    try writeEscapedText(system_id, writer);
                    try writer.writeByte('"');
                } else if (public_id.len != 0) {
                    try writer.writeAll(" PUBLIC \"");
                    try writeEscapedText(public_id, writer);
                    try writer.writeByte('"');
                } else if (system_id.len != 0) {
                    try writer.writeAll(" SYSTEM \"");
                    try writeEscapedText(system_id, writer);
                    try writer.writeByte('"');
                }
                try writer.writeAll(">\n");
            },
            .attribute => {
                // Not called normally, but can be called via XMLSerializer.serializeToString
                // in which case it should return an empty string
            },
        }
    }
};

// Element.getHTML / ShadowRoot.getHTML
pub fn getHTML(node: *Node, declarative: Opts.Shadow.Declarative, writer: *std.Io.Writer, frame: *Frame) Error!void {
    var walk: Walk = .init(.{ .shadow = .{ .declarative = declarative } }, writer, frame);
    defer walk.deinit();

    try walk.open(null, .{ .siblings = node.firstChild() });
    if (node.is(Node.Element)) |el| {
        if (el.hostedShadowRoot(frame)) |shadow| {
            if (shouldSerializeShadow(shadow, declarative)) {
                // the element's shadowroot tree is rendered before its children
                try walk.declarativeShadow(shadow);
            }
        }
    }
    return walk.run();
}

pub fn children(parent: *Node, opts: Opts, writer: *std.Io.Writer, frame: *Frame) Error!void {
    var walk: Walk = .init(opts, writer, frame);
    defer walk.deinit();
    try walk.open(null, .{ .siblings = parent.firstChild() });
    return walk.run();
}

pub fn toJSON(node: *Node, writer: *std.json.Stringify) !void {
    try writer.beginObject();

    try writer.objectField("type");
    switch (node._type) {
        .cdata => {
            try writer.write("cdata");
        },
        .document => {
            try writer.write("document");
        },
        .document_type => {
            try writer.write("document_type");
        },
        .element => {
            const el = node.subtype(Node.Element);
            try writer.write("element");
            try writer.objectField("tag");
            try writer.write(el.tagName());

            try writer.objectField("attributes");
            try writer.beginObject();
            var it = el.attributeIterator();
            while (it.next()) |attr| {
                try writer.objectField(attr.name);
                try writer.write(attr.value);
            }
            try writer.endObject();
        },
    }

    try writer.objectField("children");
    try writer.beginArray();
    var it = node.childrenIterator();
    while (it.next()) |child| {
        try toJSON(child, writer);
    }
    try writer.endArray();
    try writer.endObject();
}

fn shouldSerializeShadow(shadow: *const Node.ShadowRoot, declarative: Opts.Shadow.Declarative) bool {
    if (declarative.serializable_shadow_roots and shadow._serializable) {
        return true;
    }
    for (declarative.shadow_roots) |sr| {
        if (sr == shadow) {
            // if it's explictly requested, it's serialized even if _serialized == false
            return true;
        }
    }
    return false;
}

fn isVoidElement(el: *Node.Element) bool {
    if (el._namespace != .html) {
        // only html has void tags
        return false;
    }

    return switch (el.getTag()) {
        .area, .base, .br, .col, .embed, .hr, .img, .input, .link, .meta, .param, .source, .track => true,
        // <wbr> has no dedicated Tag, so it lands in Html.Unknown.
        .unknown => el.as(Node.Element.Html.Unknown)._tag_name.eql(comptime .wrap("wbr")),
        else => false,
    };
}

pub fn shouldStripElement(el: *Node.Element, strip: Opts.Strip, pruned: ?*const RenderTree.PruneSet, frame: *Frame) bool {
    // Fast path: with no strip flags set (every innerHTML/outerHTML call)
    if (@as(u6, @bitCast(strip)) == 0) {
        return false;
    }

    const tag_name = el.getTagNameDump();

    if (strip.js) {
        if (std.mem.eql(u8, tag_name, "script")) return true;
        if (std.mem.eql(u8, tag_name, "noscript")) return true;

        if (std.mem.eql(u8, tag_name, "link")) {
            if (el.getAttributeSafe(comptime .wrap("as"))) |as| {
                if (std.mem.eql(u8, as, "script")) return true;
            }
            if (el.getAttributeInterned("rel")) |rel| {
                if (std.mem.eql(u8, rel, "modulepreload") or std.mem.eql(u8, rel, "preload")) {
                    if (el.getAttributeSafe(comptime .wrap("as"))) |as| {
                        if (std.mem.eql(u8, as, "script")) return true;
                    }
                }
            }
        }
    }

    if (strip.css or strip.ui) {
        if (std.mem.eql(u8, tag_name, "style")) return true;

        if (std.mem.eql(u8, tag_name, "link")) {
            if (el.getAttributeInterned("rel")) |rel| {
                if (std.mem.eql(u8, rel, "stylesheet")) return true;
            }
        }
    }

    if (strip.ui) {
        if (std.mem.eql(u8, tag_name, "img")) return true;
        if (std.mem.eql(u8, tag_name, "picture")) return true;
        if (std.mem.eql(u8, tag_name, "video")) return true;
        if (std.mem.eql(u8, tag_name, "audio")) return true;
        if (std.mem.eql(u8, tag_name, "svg")) return true;
        if (std.mem.eql(u8, tag_name, "canvas")) return true;
        if (std.mem.eql(u8, tag_name, "iframe")) return true;
    }

    if (strip.invisible) {
        if (el.ownerFrame(frame)) |owner| {
            if (owner._style_manager.hasAuthorDisplayNone(el)) {
                return true;
            }
        }
    }

    if (strip.shell and isShellElement(el)) {
        return true;
    }

    if (pruned) |set| {
        if (set.contains(el.asNode())) {
            return true;
        }
    }

    return false;
}

/// Page chrome by markup alone. <header> and <footer> only count at the page
/// level: inside an article, section, main, nav or aside they belong to that
/// content, which is also how the banner/contentinfo roles are assigned.
pub fn isShellElement(el: *Node.Element) bool {
    const tag = el.getTag();
    switch (tag) {
        .nav, .aside, .dialog => return true,
        .header, .footer => return !hasSectioningAncestor(el),
        else => {},
    }
    if (hasRole(el, &.{ "banner", "complementary", "contentinfo", "navigation", "search", "dialog", "alertdialog", "menu", "menubar" })) {
        return true;
    }
    if (canHoldChrome(tag)) {
        if (hasShellToken(el.getClassName()) or hasShellToken(el.getId())) {
            return !hasSectioningAncestor(el);
        }
    }
    return false;
}

// `td` stays in because table-based layout will do things like
// <td class=sidebar>, but `tr`, `thead` and `li` because "header" is often used
// to mean something other than the header of the site
fn canHoldChrome(tag: Node.Element.Tag) bool {
    return switch (tag) {
        .div, .section, .ul, .ol, .form, .table, .td, .p => true,
        else => false,
    };
}

// Words that name page chrome and nothing else. "menu" is left out: it also
// names content.
const shell_tokens = [_][]const u8{ "header", "footer", "nav", "navbar", "navigation", "sidebar", "masthead" };

fn hasShellToken(value: ?[]const u8) bool {
    var it = std.mem.tokenizeAny(u8, value orelse return false, " \t\n\r");
    while (it.next()) |token| {
        for (shell_tokens) |shell_token| {
            if (std.ascii.eqlIgnoreCase(token, shell_token)) return true;
        }
    }
    return false;
}
fn hasSectioningAncestor(el: *Node.Element) bool {
    var node = renderParent(el.asNode());
    while (node) |n| : (node = renderParent(n)) {
        if (n.is(Node.Element)) |ancestor| {
            switch (ancestor.getTag()) {
                .article, .aside, .main, .nav, .section => return true,
                else => {},
            }
            if (hasRole(ancestor, &.{ "article", "complementary", "main", "navigation", "region" })) {
                return true;
            }
        }
    }
    return false;
}

// A shadow tree renders in place of its host, so the host continues the
// ancestor chain that a shadow root's null parent would otherwise end.
fn renderParent(node: *Node) ?*Node {
    if (node.parentNode()) |parent| {
        return parent;
    }
    const shadow = node.is(Node.ShadowRoot) orelse return null;
    return shadow.getHost().asNode();
}

// ARIA `role` is a space-separated fallback list; the first token wins.
fn hasRole(el: *Node.Element, roles: []const []const u8) bool {
    const attr = el.getAttributeSafe(comptime .wrap("role")) orelse return false;
    var it = std.mem.tokenizeAny(u8, attr, " \t\n\r");
    const role = it.next() orelse return false;
    for (roles) |candidate| {
        if (std.ascii.eqlIgnoreCase(role, candidate)) {
            return true;
        }
    }
    return false;
}

fn shouldEscapeText(node_: ?*Node) bool {
    // Raw text elements serialize their text content literally rather than
    // HTML-escaping it
    const node = node_ orelse return true;
    const element = node.is(Node.Element) orelse return true;
    const html_element = node.is(Node.Element.Html) orelse return true;

    switch (html_element._type) {
        .style, .script, .iframe => return false,
        else => {
            const tag = element.getTagNameLower();
            inline for (.{ "xmp", "noembed", "noframes", "plaintext", "noscript" }) |raw_text_tag| {
                if (std.mem.eql(u8, tag, raw_text_tag)) {
                    return false;
                }
            }
        },
    }
    return true;
}
fn writeEscapedText(text: []const u8, writer: *std.Io.Writer) !void {
    // Fast path: if no special characters, write directly
    const first_special = std.mem.indexOfAnyPos(u8, text, 0, &.{ '&', '<', '>', 194 }) orelse {
        return writer.writeAll(text);
    };

    try writer.writeAll(text[0..first_special]);
    var remaining = try writeEscapedByte(text, first_special, writer);

    while (std.mem.indexOfAnyPos(u8, remaining, 0, &.{ '&', '<', '>', 194 })) |offset| {
        try writer.writeAll(remaining[0..offset]);
        remaining = try writeEscapedByte(remaining, offset, writer);
    }

    if (remaining.len > 0) {
        try writer.writeAll(remaining);
    }
}

fn writeEscapedByte(input: []const u8, index: usize, writer: *std.Io.Writer) ![]const u8 {
    switch (input[index]) {
        '&' => try writer.writeAll("&amp;"),
        '<' => try writer.writeAll("&lt;"),
        '>' => try writer.writeAll("&gt;"),
        194 => {
            // non breaking space
            if (input.len > index + 1 and input[index + 1] == 160) {
                try writer.writeAll("&nbsp;");
                return input[index + 2 ..];
            }
            try writer.writeByte(194);
        },
        else => unreachable,
    }
    return input[index + 1 ..];
}

const testing = @import("../testing.zig");

// A fresh page per assertion: `with_base` mutates the document (it inserts a
// <base> element), so reusing one frame across opts would leak that mutation
// into later dumps.
fn expectDump(opts: Opts, expected: []const u8) !void {
    return expectPageDump("dump.html", opts, expected);
}

fn expectPageDump(comptime file: []const u8, opts: Opts, expected: []const u8) !void {
    var page = try testing.pageTest(file, .{});
    defer page.close();

    const frame = page.frame().?;

    var aw: std.Io.Writer.Allocating = .init(testing.arena_allocator);
    try root(frame.window._document, opts, &aw.writer, frame);
    try testing.expectString(expected, aw.written());
}

test "dump: default dumps the whole document" {
    try expectDump(.{},
        \\<!DOCTYPE html>
        \\<html><head><style>.hidden{display:none}</style><link rel="stylesheet" href="data:text/css,"><script>var a=1;</script></head><body><h1>Title</h1><p class="hidden">secret</p><img><svg></svg><noscript>nojs</noscript><p>visible &amp; well</p></body></html>
    );
}

test "dump: with_base injects a <base> element" {
    try expectDump(.{ .with_base = true },
        \\<!DOCTYPE html>
        \\<html><head><base href="http://127.0.0.1:9582/src/browser/tests/dump.html"><style>.hidden{display:none}</style><link rel="stylesheet" href="data:text/css,"><script>var a=1;</script></head><body><h1>Title</h1><p class="hidden">secret</p><img><svg></svg><noscript>nojs</noscript><p>visible &amp; well</p></body></html>
    );
}

test "dump: void elements have no end tag" {
    const frame = try testing.createFrame();
    defer testing.test_session.closeAllPages();

    const doc = frame.window._document;
    const div = try doc.createElement("div", null, frame);
    try Frame.parse.htmlAsChildren(frame, div.asNode(),
        \\<video><source src="a.mp4"><track kind="captions"></video><map><area shape="rect"></map><embed src="e.swf"><p>a<wbr>b</p><table><colgroup><col span="2"></colgroup></table>
    );

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try deep(div.asNode(), .{}, &aw.writer, frame);

    try testing.expectString(
        \\<div><video><source src="a.mp4"><track kind="captions"></video><map><area shape="rect"></map><embed src="e.swf"><p>a<wbr>b</p><table><colgroup><col span="2"></colgroup></table></div>
    , aw.written());
}

// There are no void SVG elements: every one gets an end tag, including those
// whose tag name is void in HTML, and those with no dedicated Element.Tag
// (which report .unknown, same as an unrecognized HTML element).
test "dump: no svg element is void" {
    const frame = try testing.createFrame();
    defer testing.test_session.closeAllPages();

    const doc = frame.window._document;
    const div = try doc.createElement("div", null, frame);
    try Frame.parse.htmlAsChildren(frame, div.asNode(),
        \\<svg><defs><clipPath id="c"><polygon points="0,0"></polygon></clipPath></defs><use href="#c"></use><text>a<tspan>b</tspan></text><source></source><track></track><input></input><link></link><a>after</a></svg>
    );

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try deep(div.asNode(), .{}, &aw.writer, frame);

    try testing.expectString(
        \\<div><svg><defs><clipPath id="c"><polygon points="0,0"></polygon></clipPath></defs><use href="#c"></use><text>a<tspan>b</tspan></text><source></source><track></track><input></input><link></link><a>after</a></svg></div>
    , aw.written());
}

test "dump: strip.js removes script and noscript" {
    try expectDump(.{ .strip = .{ .js = true } },
        \\<!DOCTYPE html>
        \\<html><head><style>.hidden{display:none}</style><link rel="stylesheet" href="data:text/css,"></head><body><h1>Title</h1><p class="hidden">secret</p><img><svg></svg><p>visible &amp; well</p></body></html>
    );
}

test "dump: strip.css removes style and stylesheet links" {
    try expectDump(.{ .strip = .{ .css = true } },
        \\<!DOCTYPE html>
        \\<html><head><script>var a=1;</script></head><body><h1>Title</h1><p class="hidden">secret</p><img><svg></svg><noscript>nojs</noscript><p>visible &amp; well</p></body></html>
    );
}

test "dump: strip.ui removes css plus visual elements" {
    try expectDump(.{ .strip = .{ .ui = true } },
        \\<!DOCTYPE html>
        \\<html><head><script>var a=1;</script></head><body><h1>Title</h1><p class="hidden">secret</p><noscript>nojs</noscript><p>visible &amp; well</p></body></html>
    );
}

test "dump: max_bytes truncates with a marker" {
    var page = try testing.pageTest("dump.html", .{});
    defer page.close();
    const frame = page.frame().?;

    var aw: std.Io.Writer.Allocating = .init(testing.arena_allocator);
    try root(frame.window._document, .{ .max_bytes = 24 }, &aw.writer, frame);
    try testing.expectString("<!DOCTYPE html>\n<html><h" ++ LimitedWriter.truncation_marker, aw.written());

    aw.clearRetainingCapacity();
    try deep(frame.window._document.asNode().lastChild().?, .{ .max_bytes = 6 }, &aw.writer, frame);
    try testing.expectString("<html>" ++ LimitedWriter.truncation_marker, aw.written());
}

test "dump: strip.invisible removes author display:none elements" {
    try expectDump(.{ .strip = .{ .invisible = true } },
        \\<!DOCTYPE html>
        \\<html><head><style>.hidden{display:none}</style><link rel="stylesheet" href="data:text/css,"><script>var a=1;</script></head><body><h1>Title</h1><img><svg></svg><noscript>nojs</noscript><p>visible &amp; well</p></body></html>
    );
}

test "dump: strip.shell removes page chrome but keeps sectioned header/footer" {
    try expectShellDump(
        \\<header>H</header><nav>N</nav><main><header>MH</header><p>body</p><footer>MF</footer></main><article><footer>AF</footer></article><aside>A</aside><dialog>D</dialog><footer>F</footer>
    ,
        \\<div><main><header>MH</header><p>body</p><footer>MF</footer></main><article><footer>AF</footer></article></div>
    );
}

test "dump: strip.shell honours chrome class and id tokens" {
    try expectShellDump(
        \\<div class="header">H</div><div id="Footer">F</div><div class="site navbar">N</div><div class="subheader">S</div><div class="post-footer">P</div><main><div class="header">MH</div><p>x</p></main><div class="menu">M</div>
    ,
        \\<div><div class="subheader">S</div><div class="post-footer">P</div><main><div class="header">MH</div><p>x</p></main><div class="menu">M</div></div>
    );
}

test "dump: strip.shell honours landmark roles" {
    try expectShellDump(
        \\<div role="navigation">N</div><div role="BANNER search">B</div><section><div role="contentinfo">C</div></section><p>x</p><div role="region"><header>RH</header></div><div role="main"><footer>MF</footer></div>
    ,
        \\<div><section></section><p>x</p><div role="region"><header>RH</header></div><div role="main"><footer>MF</footer></div></div>
    );
}

test "dump: strip.shell's token rule only applies to chrome containers" {
    try expectShellDump(
        \\<table><thead><tr class="header"><td>Plan</td></tr></thead><tbody><tr><td>Basic</td><td class="sidebar">Legacy</td></tr></tbody></table><ul><li class="header">Item</li></ul>
    ,
        \\<div><table><thead><tr class="header"><td>Plan</td></tr></thead><tbody><tr><td>Basic</td></tr></tbody></table><ul><li class="header">Item</li></ul></div>
    );
}

fn expectShellDump(html: []const u8, expected: []const u8) !void {
    const frame = try testing.createFrame();
    defer testing.test_session.closeAllPages();

    const doc = frame.window._document;
    const div = try doc.createElement("div", null, frame);
    try Frame.parse.htmlAsChildren(frame, div.asNode(), html);

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try deep(div.asNode(), .{ .strip = .{ .shell = true } }, &aw.writer, frame);
    try testing.expectString(expected, aw.written());
}

test "dump: deep nesting doesn't overflow the native stack" {
    const frame = try testing.createFrame();
    defer testing.test_session.closeAllPages();

    const depth = 50_000;
    const doc = frame.window._document;
    var top = (try doc.createElement("i", null, frame)).asNode();
    for (1..depth) |_| {
        const parent = (try doc.createElement("i", null, frame)).asNode();
        _ = try parent.appendChild(top, frame);
        top = parent;
    }

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try deep(top, .{}, &aw.writer, frame);
    try testing.expectEqual(depth * "<i></i>".len, aw.written().len);
    try testing.expectString("<i><i>", aw.written()[0..6]);
    try testing.expectString("</i></i>", aw.written()[aw.written().len - 8 ..]);
}

test "dump: shadow modes" {
    const frame = try testing.createFrame();
    defer testing.test_session.closeAllPages();

    const doc = frame.window._document;
    const host = try doc.createElement("div", null, frame);
    _ = try doc.asNode().appendChild(host.asNode(), frame);
    const shadow = try host.attachShadow(.{ .mode = .open }, frame);
    try Frame.parse.htmlAsChildren(frame, shadow.asNode(),
        \\<h2><slot name="t"><b>unused fallback</b></slot></h2><slot></slot><slot name="none"><i>fallback</i><br></slot>
    );
    try Frame.parse.htmlAsChildren(frame, host.asNode(),
        \\<span slot="t">T<em>e</em></span><p>one</p>text<span slot="zz">orphan</span><p>two</p>
    );

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    // Assigned nodes replace a slot's fallback; a node whose slot doesn't
    // exist isn't rendered at all.
    try deep(host.asNode(), .{ .shadow = .rendered }, &aw.writer, frame);
    try testing.expectString(
        \\<div><h2><slot name="t"><span slot="t">T<em>e</em></span></slot></h2><slot><p>one</p>text<p>two</p></slot><slot name="none"><i>fallback</i><br></slot></div>
    , aw.written());

    // The shadow tree as authored, then the light DOM
    aw.clearRetainingCapacity();
    try deep(host.asNode(), .{ .shadow = .complete }, &aw.writer, frame);
    try testing.expectString(
        \\<div><h2><slot name="t"><b>unused fallback</b></slot></h2><slot></slot><slot name="none"><i>fallback</i><br></slot><span slot="t">T<em>e</em></span><p>one</p>text<span slot="zz">orphan</span><p>two</p></div>
    , aw.written());

    aw.clearRetainingCapacity();
    try deep(host.asNode(), .{ .shadow = .skip }, &aw.writer, frame);
    try testing.expectString(
        \\<div><span slot="t">T<em>e</em></span><p>one</p>text<span slot="zz">orphan</span><p>two</p></div>
    , aw.written());
}

const frames_dump =
    \\<!DOCTYPE html>
    \\<html><head></head><body><p>before</p><iframe srcdoc="&lt;p&gt;inner&lt;/p&gt;&lt;iframe srcdoc='&lt;b&gt;deep&lt;/b&gt;'&gt;&lt;/iframe&gt;">
    \\<!DOCTYPE html><html><head></head><body><p>inner</p><iframe srcdoc="&lt;b&gt;deep&lt;/b&gt;">
    \\<!DOCTYPE html><html><head></head><body><b>deep</b></body></html>
    \\</iframe></body></html>
    \\</iframe><p>after</p></body></html>
;

test "dump: an iframe's own children are dumped without with_frames" {
    try expectPageDump("dump_frames.html", .{},
        \\<!DOCTYPE html>
        \\<html><head></head><body><p>before</p><iframe srcdoc="&lt;p&gt;inner&lt;/p&gt;&lt;iframe srcdoc='&lt;b&gt;deep&lt;/b&gt;'&gt;&lt;/iframe&gt;">ignored</iframe><p>after</p></body></html>
    );
}

test "dump: with_frames dumps nested content documents" {
    try expectPageDump("dump_frames.html", .{ .with_frames = true }, frames_dump);
}

test "dump: with_frames and with_base inject a <base> in every document" {
    try expectPageDump("dump_frames.html", .{ .with_frames = true, .with_base = true },
        \\<!DOCTYPE html>
        \\<html><head><base href="http://127.0.0.1:9582/src/browser/tests/dump_frames.html"></head><body><p>before</p><iframe srcdoc="&lt;p&gt;inner&lt;/p&gt;&lt;iframe srcdoc='&lt;b&gt;deep&lt;/b&gt;'&gt;&lt;/iframe&gt;">
        \\<!DOCTYPE html><html><head><base href="http://127.0.0.1:9582/src/browser/tests/dump_frames.html"></head><body><p>inner</p><iframe srcdoc="&lt;b&gt;deep&lt;/b&gt;">
        \\<!DOCTYPE html><html><head><base href="http://127.0.0.1:9582/src/browser/tests/dump_frames.html"></head><body><b>deep</b></body></html>
        \\</iframe></body></html>
        \\</iframe><p>after</p></body></html>
    );
}

// Each content document gets its own LimitedWriter; the cut must still happen
// once, with a single marker and no end tags after it.
test "dump: max_bytes cut inside a nested content document" {
    const cut = comptime std.mem.indexOf(u8, frames_dump, "<b>deep").? + 4;
    try expectPageDump(
        "dump_frames.html",
        .{ .with_frames = true, .max_bytes = cut },
        frames_dump[0..cut] ++ LimitedWriter.truncation_marker,
    );
}
