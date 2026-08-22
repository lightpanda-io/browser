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

const Base64Writer = @import("../Base64Writer.zig");
const isAllWhitespace = @import("../string.zig").isAllWhitespace;

const Frame = @import("Frame.zig");
const markdown = @import("markdown.zig");

const Node = @import("webapi/Node.zig");
const Element = @import("webapi/Element.zig");
const Slot = @import("webapi/element/html/Slot.zig");

const log = lp.log;
const Allocator = std.mem.Allocator;

pub const Opts = struct {
    width: u32,
    height: u32 = 0,
    clip: ?Clip = null,
    scale: f32 = 1.0,

    pub const Clip = struct {
        x: f32,
        y: f32,
        width: f32,
        height: f32,
    };
};

pub fn png(arena: Allocator, node: *Node, opts: Opts, writer: *std.Io.Writer, frame: *Frame) !u32 {
    const prepared = try prepare(arena, node, opts, frame);
    return prepared.write(writer);
}

// get the height of the PNG if we were to render it.
pub fn contentHeight(arena: Allocator, node: *Node, width: u32, frame: *Frame) !u32 {
    const prepared = try prepare(arena, node, .{ .width = width }, frame);
    var discard: std.Io.Writer.Discarding = .init(&.{});
    return prepared.render(&discard.writer, RENDER_MEASURE_ONLY);
}

// The DOM walk, done up front so it can fail (allocation) before any output
// starts. Rasterizing is then a pure write: `Prepared` can be embedded in a
// std.json value and streams itself as a base64 string.
pub fn prepare(arena: Allocator, node: *Node, opts: Opts, frame: *Frame) !Prepared {
    if (opts.width == 0 or !(opts.scale > 0 and opts.scale <= 8)) {
        return error.InvalidScreenshotOptions;
    }
    var builder: Builder = .{
        .frame = frame,
        .arena = arena,
    };
    try builder.render(node);
    try builder.closeBlock();
    return .{ .blocks = builder.blocks.items, .opts = opts };
}

pub const Prepared = struct {
    opts: Opts,
    blocks: []const LpBlock,

    pub fn write(self: *const Prepared, writer: *std.Io.Writer) std.Io.Writer.Error!u32 {
        return self.render(writer, 0);
    }

    fn render(self: *const Prepared, writer: *std.Io.Writer, flags: u32) std.Io.Writer.Error!u32 {
        const opts = self.opts;
        const clip = opts.clip orelse Opts.Clip{ .x = 0, .y = 0, .width = 0, .height = 0 };
        var content_height: u32 = 0;
        var sink: Sink = .{ .writer = writer };
        const rc = lp_render_png(self.blocks.ptr, self.blocks.len, .{
            .width = opts.width,
            .height = opts.height,
            .clip_x = clip.x,
            .clip_y = clip.y,
            .clip_w = clip.width,
            .clip_h = clip.height,
            .scale = opts.scale,
            .flags = flags,
        }, &content_height, &sink, Sink.write);

        if (rc == RC_OK) {
            return content_height;
        }

        // Any non-zero rc means nothing usable was written, so this has to
        // fail rather than hand back a truncated PNG. WriteFailed is the only
        // error jsonStringify's signature can carry, hence the log line.
        log.err(.browser, "screenshot render", .{ .reason = switch (rc) {
            RC_WRITE_REFUSED => "write refused",
            RC_INVALID => "invalid options",
            RC_NO_RASTER => "raster allocation failed",
            RC_ENCODE_FAILED => "png encoding failed",
            RC_PANIC => "renderer panicked",
            else => "unknown",
        }, .rc = rc });
        return error.WriteFailed;
    }

    // Serializes as a base64 string, streamed: no PNG or base64 buffer.
    pub fn jsonStringify(self: *const Prepared, jws: *std.json.Stringify) std.Io.Writer.Error!void {
        try jws.beginWriteRaw();
        try jws.writer.writeByte('"');
        var b64 = Base64Writer.init(jws.writer, .standard);
        _ = try self.write(&b64.writer);
        try b64.finish();
        try jws.writer.writeByte('"');
        jws.endWriteRaw();
    }
};

const Sink = struct {
    writer: *std.Io.Writer,

    fn write(ctx: *anyopaque, data: [*]const u8, len: usize) callconv(.c) bool {
        const self: *Sink = @ptrCast(@alignCast(ctx));
        self.writer.writeAll(data[0..len]) catch return false;
        return true;
    }
};

// Mirrors the C ABI in src/rust/render/lib.rs.
const LpSpan = extern struct {
    text: [*]const u8,
    len: usize,
    flags: u32,
    color: u32,
};

const LpBlock = extern struct {
    spans: [*]const LpSpan,
    spans_len: usize,
    marker: [*]const u8,
    marker_len: usize,
    kind: Kind,
    level: u8,
    list_depth: u8,
    quote_depth: u8,
    flags: u8,

    const Kind = enum(u8) {
        paragraph = 0,
        heading = 1,
        pre = 2,
        rule = 3,
    };
};

const LpRenderOpts = extern struct {
    width: u32,
    height: u32,
    clip_x: f32,
    clip_y: f32,
    clip_w: f32,
    clip_h: f32,
    scale: f32,
    flags: u32,
};

const SPAN_BOLD: u32 = 1 << 0;
const SPAN_ITALIC: u32 = 1 << 1;
const SPAN_UNDERLINE: u32 = 1 << 2;
const SPAN_MONO: u32 = 1 << 3;
const SPAN_STRIKE: u32 = 1 << 4;
const SPAN_HAS_COLOR: u32 = 1 << 5;

const BLOCK_TIGHT: u8 = 1 << 0;

const RENDER_MEASURE_ONLY: u32 = 1 << 0;

const RC_OK: i32 = 0;
const RC_WRITE_REFUSED: i32 = 1;
const RC_INVALID: i32 = 2;
const RC_NO_RASTER: i32 = 3;
const RC_ENCODE_FAILED: i32 = 4;
const RC_PANIC: i32 = 5;

const LINK_COLOR: u32 = 0x1a0dab;
const MUTED_COLOR: u32 = 0x6b6b6b;

extern "c" fn lp_render_png(
    blocks: [*]const LpBlock,
    blocks_len: usize,
    opts: LpRenderOpts,
    content_height: *u32,
    ctx: *anyopaque,
    write: *const fn (ctx: *anyopaque, data: [*]const u8, len: usize) callconv(.c) bool,
) i32;

const Builder = struct {
    frame: *Frame,
    arena: Allocator,

    blocks: std.ArrayList(LpBlock) = .empty,

    // The block being built.
    block_open: bool = false,
    kind: LpBlock.Kind = .paragraph,
    level: u8 = 0,
    marker: []const u8 = "",
    spans: std.ArrayList(LpSpan) = .empty,
    // Text of the span being built, and the flags it was started with.
    text: std.ArrayList(u8) = .empty,
    text_flags: u32 = 0,
    text_color: u32 = 0,
    has_content: bool = false,
    pending_space: bool = false,
    // Nothing appended since an <a> closed. Adjacent links with no whitespace
    // between them (nav bars) would otherwise fuse into one word.
    after_anchor: bool = false,

    // Set by <li>; consumed by the first block it produces.
    pending_marker: []const u8 = "",

    // Inline style nesting.
    bold: u8 = 0,
    italic: u8 = 0,
    underline: u8 = 0,
    mono: u8 = 0,
    strike: u8 = 0,
    link: u8 = 0,
    muted: u8 = 0,
    // Nearest enclosing <pre>, for whitespace preservation.
    pre_node: ?*Node = null,

    quote_depth: u8 = 0,
    list_depth: u8 = 0,
    list_stack: [16]ListState = undefined,
    // Blocks closed while > 0 get list-like vertical spacing.
    tight: u8 = 0,

    // When there's a slot-attribute, we skip rendering, unless this flag has
    // been set to true.
    force_slot: bool = false,

    const ListState = struct {
        ordered: bool,
        index: u32,
    };

    const Error = Allocator.Error;

    fn currentFlags(self: *const Builder) u32 {
        var flags: u32 = 0;
        if (self.bold > 0) {
            flags |= SPAN_BOLD;
        }
        if (self.italic > 0) {
            flags |= SPAN_ITALIC;
        }
        if (self.underline > 0 or self.link > 0) {
            flags |= SPAN_UNDERLINE;
        }
        if (self.mono > 0) {
            flags |= SPAN_MONO;
        }
        if (self.strike > 0) {
            flags |= SPAN_STRIKE;
        }
        if (self.link > 0 or self.muted > 0) {
            flags |= SPAN_HAS_COLOR;
        }
        return flags;
    }

    fn currentColor(self: *const Builder) u32 {
        if (self.link > 0) {
            return LINK_COLOR;
        }
        if (self.muted > 0) {
            return MUTED_COLOR;
        }
        return 0;
    }

    fn openBlock(self: *Builder, kind: LpBlock.Kind, level: u8) Error!void {
        try self.closeBlock();
        self.block_open = true;
        self.kind = kind;
        self.level = level;
        self.marker = self.pending_marker;
        self.pending_marker = "";
    }

    fn ensureBlock(self: *Builder) Error!void {
        if (!self.block_open) {
            try self.openBlock(.paragraph, 0);
        }
    }

    fn flushSpan(self: *Builder) Error!void {
        if (self.text.items.len == 0) return;
        const copy = try self.arena.dupe(u8, self.text.items);
        try self.spans.append(self.arena, .{
            .text = copy.ptr,
            .len = copy.len,
            .flags = self.text_flags,
            .color = self.text_color,
        });
        self.text.clearRetainingCapacity();
    }

    fn closeBlock(self: *Builder) Error!void {
        if (!self.block_open) return;
        try self.flushSpan();
        if (self.spans.items.len > 0 or self.kind == .rule) {
            const spans = try self.arena.dupe(LpSpan, self.spans.items);
            try self.blocks.append(self.arena, .{
                .spans = spans.ptr,
                .spans_len = spans.len,
                .marker = self.marker.ptr,
                .marker_len = self.marker.len,
                .kind = self.kind,
                .level = self.level,
                .list_depth = self.list_depth,
                .quote_depth = self.quote_depth,
                .flags = if (self.tight > 0) BLOCK_TIGHT else 0,
            });
        } else if (self.marker.len > 0) {
            // Empty <li>: keep the marker for whatever block comes next.
            self.pending_marker = self.marker;
        }
        self.block_open = false;
        self.marker = "";
        self.spans.clearRetainingCapacity();
        self.has_content = false;
        self.pending_space = false;
        self.after_anchor = false;
    }

    // Appends already-collapsed text in the current inline style.
    fn append(self: *Builder, text: []const u8) Error!void {
        try self.ensureBlock();
        const flags = self.currentFlags();
        const color = self.currentColor();
        if (self.text.items.len > 0 and (flags != self.text_flags or color != self.text_color)) {
            try self.flushSpan();
        }
        self.text_flags = flags;
        self.text_color = color;
        try self.text.appendSlice(self.arena, text);
        self.has_content = true;
        self.after_anchor = false;
    }

    fn appendWord(self: *Builder, word: []const u8) Error!void {
        if (self.pending_space and self.has_content) {
            try self.appendSpace();
        }
        self.pending_space = false;
        try self.append(word);
    }

    // A collapsed space between two runs takes only the styling both sides
    // share, so an underline never spills onto the gap before a link.
    fn appendSpace(self: *Builder) Error!void {
        var flags = self.text_flags & self.currentFlags();
        var color = self.text_color;
        if (flags & SPAN_HAS_COLOR != 0 and color != self.currentColor()) {
            flags &= ~SPAN_HAS_COLOR;
        }
        if (flags & SPAN_HAS_COLOR == 0) color = 0;

        if (flags != self.text_flags or color != self.text_color) {
            try self.flushSpan();
            self.text_flags = flags;
            self.text_color = color;
        }
        try self.text.append(self.arena, ' ');
    }

    fn render(self: *Builder, node: *Node) Error!void {
        switch (node._type) {
            .document, .document_fragment => try self.renderChildren(node),
            .element => try self.renderElement(node.subtype(Node.Element)),
            .cdata => {
                if (node.is(Node.CData.Text)) |_| {
                    var text = node.subtype(Node.CData).getData().str();
                    if (self.pre_node) |pre| {
                        if (node.parentNode() == pre and node.nextSibling() == null) {
                            text = std.mem.trimEnd(u8, text, " \t\r\n");
                        }
                    }
                    try self.renderText(text);
                }
            },
            else => {},
        }
    }

    fn renderChildren(self: *Builder, parent: *Node) Error!void {
        var it = parent.childrenIterator();
        while (it.next()) |child| {
            try self.render(child);
        }
    }

    fn renderSlotContent(self: *Builder, slot: *Slot) Error!void {
        const assigned = slot.assignedNodes(null, self.frame) catch return;
        if (assigned.len == 0) {
            return self.renderChildren(slot.asNode());
        }
        for (assigned) |node| {
            self.force_slot = true;
            try self.render(node);
        }
        self.force_slot = false;
    }

    fn renderText(self: *Builder, text: []const u8) Error!void {
        if (text.len == 0) return;

        if (self.pre_node != null) {
            return self.append(text);
        }

        if (isAllWhitespace(text)) {
            self.pending_space = true;
            return;
        }

        if (std.ascii.isWhitespace(text[0])) {
            self.pending_space = true;
        }
        var it = std.mem.tokenizeAny(u8, text, " \t\n\r");
        while (it.next()) |word| {
            try self.appendWord(word);
            self.pending_space = true;
        }
        self.pending_space = std.ascii.isWhitespace(text[text.len - 1]);
    }

    fn renderElement(self: *Builder, el: *Element) Error!void {
        const force_slot = self.force_slot;
        self.force_slot = false;

        const tag = el.getTag();
        if (tag.isMetadata() or tag == .svg) {
            return;
        }

        if (!force_slot and el.getAttributeSafe(comptime .wrap("slot")) != null) {
            return;
        }

        switch (tag) {
            .h1, .h2, .h3, .h4, .h5, .h6 => {
                const level: u8 = switch (tag) {
                    .h1 => 1,
                    .h2 => 2,
                    .h3 => 3,
                    .h4 => 4,
                    .h5 => 5,
                    else => 6,
                };
                try self.openBlock(.heading, level);
                try self.renderContent(el);
                return self.closeBlock();
            },
            .pre => {
                try self.openBlock(.pre, 0);
                const prev = self.pre_node;
                self.pre_node = el.asNode();
                try self.renderContent(el);
                self.pre_node = prev;
                return self.closeBlock();
            },
            .hr => {
                try self.openBlock(.rule, 0);
                return self.closeBlock();
            },
            .br => {
                if (self.pre_node != null) return self.append("\n");
                if (!self.has_content) return;
                // A hard break within the block: parley honors '\n'.
                try self.append("\n");
                self.pending_space = false;
                return;
            },
            .ul, .ol => {
                try self.closeBlock();
                const pushed = self.list_depth < self.list_stack.len;
                if (pushed) {
                    self.list_stack[self.list_depth] = .{ .ordered = tag == .ol, .index = 1 };
                    self.list_depth += 1;
                }
                try self.renderContent(el);
                try self.closeBlock();
                if (pushed) self.list_depth -= 1;
                return;
            },
            .li => {
                try self.closeBlock();
                // A stray <li> outside any list still gets a bullet.
                const stray = self.list_depth == 0;
                if (stray) self.list_depth = 1;
                if (!stray and self.list_stack[self.list_depth - 1].ordered) {
                    const state = &self.list_stack[self.list_depth - 1];
                    self.pending_marker = try std.fmt.allocPrint(self.arena, "{d}.", .{state.index});
                    state.index += 1;
                } else {
                    self.pending_marker = "•";
                }
                try self.renderContent(el);
                try self.closeBlock();
                self.pending_marker = "";
                if (stray) self.list_depth = 0;
                return;
            },
            .blockquote => {
                try self.closeBlock();
                self.quote_depth +|= 1;
                try self.renderContent(el);
                try self.closeBlock();
                self.quote_depth -= 1;
                return;
            },
            .img => {
                const alt = el.getAttributeSafe(comptime .wrap("alt")) orelse return;
                if (isAllWhitespace(alt)) return;
                self.italic += 1;
                self.muted += 1;
                try self.renderText(alt);
                self.muted -= 1;
                self.italic -= 1;
                return;
            },
            .input => {
                const type_attr = el.getAttributeSafe(comptime .wrap("type")) orelse return;
                if (std.ascii.eqlIgnoreCase(type_attr, "checkbox")) {
                    const checked = el.getAttributeSafe(comptime .wrap("checked")) != null;
                    try self.appendWord(if (checked) "☑" else "☐");
                    self.pending_space = true;
                }
                return;
            },
            .anchor => {
                const href = el.getAttributeSafe(comptime .wrap("href"));
                const label = el.getAttributeSafe(comptime .wrap("aria-label")) orelse el.getAttributeSafe(comptime .wrap("title"));
                const info = markdown.analyzeContent(el.asNode());
                if (!info.has_visible and label == null) return;

                // Same split as markdown: an anchor wrapping blocks, or one
                // sitting among element-only siblings (nav bars, post lists),
                // gets its own tight block instead of flowing inline.
                const standalone = info.has_block or markdown.isStandaloneAnchor(el);
                if (standalone) {
                    try self.closeBlock();
                    self.tight += 1;
                }
                if (self.after_anchor) self.pending_space = true;
                if (href != null) self.link += 1;
                if (info.has_visible) {
                    try self.renderContent(el);
                } else {
                    try self.renderText(label.?);
                }
                if (href != null) self.link -= 1;
                if (standalone) {
                    try self.closeBlock();
                    self.tight -= 1;
                } else {
                    self.after_anchor = true;
                }
                return;
            },
            .slot => return self.renderSlotContent(el.as(Slot)),
            .td, .th => {
                if (self.has_content) {
                    self.pending_space = true;
                    self.muted += 1;
                    try self.appendWord("|");
                    self.muted -= 1;
                    self.pending_space = true;
                }
                if (tag == .th) self.bold += 1;
                try self.renderContent(el);
                if (tag == .th) self.bold -= 1;
                self.pending_space = true;
                return;
            },
            else => {},
        }

        const block = tag.isBlock() or switch (tag) {
            .tr, .dt, .dd, .details, .summary, .caption, .legend, .option, .textarea => true,
            else => false,
        };
        if (block) try self.closeBlock();

        switch (tag) {
            .b, .strong => self.bold += 1,
            .i, .em, .dfn => self.italic += 1,
            .ins => self.underline += 1,
            .s, .del => self.strike += 1,
            .code => self.mono += 1,
            else => {},
        }
        try self.renderContent(el);
        switch (tag) {
            .b, .strong => self.bold -= 1,
            .i, .em, .dfn => self.italic -= 1,
            .ins => self.underline -= 1,
            .s, .del => self.strike -= 1,
            .code => self.mono -= 1,
            else => {},
        }

        if (block) {
            try self.closeBlock();
        }
    }

    // Composed tree: a shadow host renders its shadow tree in place of its
    // light-DOM children (visible only through <slot>).
    fn renderContent(self: *Builder, el: *Element) Error!void {
        if (el.hostedShadowRoot(self.frame)) |shadow| {
            return self.renderChildren(shadow.asNode());
        }
        return self.renderChildren(el.asNode());
    }
};

const testing = @import("../testing.zig");
test "browser.screenshot: png signature and dimensions" {
    defer testing.test_session.closeAllPages();
    const out = try testPng("<h1>Title</h1><p>Hello <b>world</b> <a href='/x'>link</a></p>", 640);

    try testing.expectEqual(true, out.len > 100);
    try testing.expectEqual("\x89PNG\r\n\x1a\n", out[0..8]);
    // IHDR width/height are big-endian at offsets 16 and 20.
    try testing.expectEqual(640, std.mem.readInt(u32, out[16..20], .big));
    const height = std.mem.readInt(u32, out[20..24], .big);
    // Two blocks plus margins.
    try testing.expectEqual(true, height > 60 and height < 200);
}

test "browser.screenshot: fixed height, clip and scale" {
    defer testing.test_session.closeAllPages();
    const frame = try testing.createFrame();
    frame.url = "http://localhost/";
    const doc = frame.window._document;
    const div = try doc.createElement("div", null, frame);
    try Frame.parse.htmlAsChildren(frame, div.asNode(), "<p>one</p><p>two</p><p>three</p>");

    var aw: std.Io.Writer.Allocating = .init(testing.arena_allocator);
    const content_height = try png(testing.arena_allocator, div.asNode(), .{ .width = 300, .height = 50, .scale = 2.0 }, &aw.writer, frame);
    try testing.expectEqual(true, content_height > 50);
    try testing.expectEqual(600, std.mem.readInt(u32, aw.written()[16..20], .big));
    try testing.expectEqual(100, std.mem.readInt(u32, aw.written()[20..24], .big));

    try testing.expectEqual(content_height, try contentHeight(frame.call_arena, div.asNode(), 300, frame));

    aw.clearRetainingCapacity();
    _ = try png(frame.call_arena, div.asNode(), .{
        .width = 300,
        .clip = .{ .x = 10, .y = 10, .width = 100, .height = 40 },
    }, &aw.writer, frame);
    try testing.expectEqual(100, std.mem.readInt(u32, aw.written()[16..20], .big));
    try testing.expectEqual(40, std.mem.readInt(u32, aw.written()[20..24], .big));
}

test "browser.screenshot: a clip past the viewport extends the strip" {
    defer testing.test_session.closeAllPages();
    const frame = try testing.createFrame();
    frame.url = "http://localhost/";
    const doc = frame.window._document;
    const div = try doc.createElement("div", null, frame);
    try Frame.parse.htmlAsChildren(frame, div.asNode(), "<p>one</p><p>two</p><p>three</p><p>four</p><p>five</p><p>six</p>");

    const full = try contentHeight(testing.arena_allocator, div.asNode(), 300, frame);
    try testing.expectEqual(true, full > 100);

    var aw: std.Io.Writer.Allocating = .init(testing.arena_allocator);
    _ = try png(frame.call_arena, div.asNode(), .{
        .width = 300,
        .height = 100,
        .clip = .{ .x = 0, .y = 0, .width = 300, .height = @floatFromInt(full) },
    }, &aw.writer, frame);
    try testing.expectEqual(300, std.mem.readInt(u32, aw.written()[16..20], .big));
    try testing.expectEqual(full, std.mem.readInt(u32, aw.written()[20..24], .big));

    // Never past the content, so an absurd probe resolves to the full page
    // instead of a 1e8-tall raster.
    aw.clearRetainingCapacity();
    _ = try png(testing.arena_allocator, div.asNode(), .{
        .width = 300,
        .height = 100,
        .clip = .{ .x = 0, .y = 0, .width = 300, .height = 1e8 },
    }, &aw.writer, frame);
    try testing.expectEqual(full, std.mem.readInt(u32, aw.written()[20..24], .big));
}

test "browser.screenshot: raster is bounded" {
    defer testing.test_session.closeAllPages();
    const frame = try testing.createFrame();
    frame.url = "http://localhost/";
    const doc = frame.window._document;
    const div = try doc.createElement("div", null, frame);
    try Frame.parse.htmlAsChildren(frame, div.asNode(), "<p>hello</p>");

    var aw: std.Io.Writer.Allocating = .init(testing.arena_allocator);

    _ = try png(testing.arena_allocator, div.asNode(), .{ .width = 300000, .height = 8 }, &aw.writer, frame);
    try testing.expectEqual(16384, std.mem.readInt(u32, aw.written()[16..20], .big));
    try testing.expectEqual(8, std.mem.readInt(u32, aw.written()[20..24], .big));

    aw.clearRetainingCapacity();
    _ = try png(testing.arena_allocator, div.asNode(), .{ .width = 8, .height = 100000 }, &aw.writer, frame);
    try testing.expectEqual(8, std.mem.readInt(u32, aw.written()[16..20], .big));
    try testing.expectEqual(16384, std.mem.readInt(u32, aw.written()[20..24], .big));
}

test "browser.screenshot: a refused write fails the capture" {
    defer testing.test_session.closeAllPages();
    testing.silenceLog(&.{.browser});
    const frame = try testing.createFrame();
    frame.url = "http://localhost/";
    const doc = frame.window._document;
    const div = try doc.createElement("div", null, frame);
    try Frame.parse.htmlAsChildren(frame, div.asNode(), "<p>hello</p>");

    // Far too small for the PNG, so the sink refuses partway through. That
    // has to surface as an error and not as a truncated image.
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try testing.expectError(error.WriteFailed, png(testing.arena_allocator, div.asNode(), .{ .width = 300 }, &w, frame));
}

test "browser.screenshot: json streams base64" {
    defer testing.test_session.closeAllPages();
    const frame = try testing.createFrame();
    frame.url = "http://localhost/";
    const doc = frame.window._document;
    const div = try doc.createElement("div", null, frame);
    try Frame.parse.htmlAsChildren(frame, div.asNode(), "<p>hello</p>");

    const prepared = try prepare(testing.arena_allocator, div.asNode(), .{ .width = 200 }, frame);

    var raw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer raw.deinit();
    _ = try prepared.write(&raw.writer);

    var json: std.Io.Writer.Allocating = .init(testing.allocator);
    defer json.deinit();
    try std.json.Stringify.value(.{ .data = prepared }, .{}, &json.writer);

    const enc = std.base64.standard.Encoder;
    const expected = try testing.allocator.alloc(u8, enc.calcSize(raw.written().len) + 11);
    defer testing.allocator.free(expected);
    @memcpy(expected[0..9], "{\"data\":\"");
    _ = enc.encode(expected[9 .. expected.len - 2], raw.written());
    @memcpy(expected[expected.len - 2 ..], "\"}");
    try testing.expectString(expected, json.written());
}

test "browser.screenshot: block extraction" {
    defer testing.test_session.closeAllPages();
    const frame = try testing.createFrame();
    frame.url = "http://localhost/";
    const doc = frame.window._document;
    const div = try doc.createElement("div", null, frame);
    try Frame.parse.htmlAsChildren(frame, div.asNode(),
        \\<h2> Head  ing </h2>
        \\<p>Some <b>bold <i>both</i></b> text <a href="/l">a link</a><span> tail</span></p>
        \\<ul><li>one</li><li><p>two</p><ol><li>nested</li></ol></li></ul>
        \\<blockquote>quote</blockquote>
        \\<pre>  keep
        \\   this</pre>
        \\<hr>
        \\<div><img alt="a picture"><span></span></div>
        \\<table><tr><th>A</th><td>B</td></tr><tr><td>C</td></tr></table>
        \\<div>   </div>
    );

    var builder: Builder = .{ .arena = testing.arena_allocator, .frame = frame };
    try builder.render(div.asNode());
    try builder.closeBlock();

    const blocks = builder.blocks.items;
    try testing.expectEqual(11, blocks.len);

    const S = struct {
        fn text(b: LpBlock, arena: Allocator) ![]const u8 {
            var out: std.ArrayList(u8) = .empty;
            for (b.spans[0..b.spans_len]) |s| try out.appendSlice(arena, s.text[0..s.len]);
            return out.items;
        }
    };
    const arena = testing.arena_allocator;

    try testing.expectEqual(.heading, blocks[0].kind);
    try testing.expectEqual(2, blocks[0].level);
    try testing.expectEqual("Head ing", try S.text(blocks[0], arena));

    try testing.expectEqual(.paragraph, blocks[1].kind);
    try testing.expectEqual("Some bold both text a link tail", try S.text(blocks[1], arena));
    try testing.expectEqual(6, blocks[1].spans_len);
    try testing.expectEqual("Some ", blocks[1].spans[0].text[0..blocks[1].spans[0].len]);
    try testing.expectEqual(SPAN_BOLD, blocks[1].spans[1].flags);
    try testing.expectEqual("bold ", blocks[1].spans[1].text[0..blocks[1].spans[1].len]);
    try testing.expectEqual(SPAN_BOLD | SPAN_ITALIC, blocks[1].spans[2].flags);
    try testing.expectEqual("both", blocks[1].spans[2].text[0..blocks[1].spans[2].len]);
    try testing.expectEqual(0, blocks[1].spans[3].flags);
    try testing.expectEqual(" text ", blocks[1].spans[3].text[0..blocks[1].spans[3].len]);
    try testing.expectEqual(SPAN_UNDERLINE | SPAN_HAS_COLOR, blocks[1].spans[4].flags);
    try testing.expectEqual(LINK_COLOR, blocks[1].spans[4].color);
    try testing.expectEqual("a link", blocks[1].spans[4].text[0..blocks[1].spans[4].len]);
    try testing.expectEqual(" tail", blocks[1].spans[5].text[0..blocks[1].spans[5].len]);

    try testing.expectEqual("one", try S.text(blocks[2], arena));
    try testing.expectEqual(1, blocks[2].list_depth);
    try testing.expectEqual("•", blocks[2].marker[0..blocks[2].marker_len]);
    try testing.expectEqual("two", try S.text(blocks[3], arena));
    try testing.expectEqual("•", blocks[3].marker[0..blocks[3].marker_len]);
    try testing.expectEqual("nested", try S.text(blocks[4], arena));
    try testing.expectEqual(2, blocks[4].list_depth);
    try testing.expectEqual("1.", blocks[4].marker[0..blocks[4].marker_len]);

    try testing.expectEqual("quote", try S.text(blocks[5], arena));
    try testing.expectEqual(1, blocks[5].quote_depth);
    try testing.expectEqual(0, blocks[5].list_depth);

    try testing.expectEqual(.pre, blocks[6].kind);
    try testing.expectEqual("  keep\n   this", try S.text(blocks[6], arena));
    try testing.expectEqual(.rule, blocks[7].kind);
    try testing.expectEqual("a picture", try S.text(blocks[8], arena));
    try testing.expectEqual(SPAN_ITALIC | SPAN_HAS_COLOR, blocks[8].spans[0].flags);
    try testing.expectEqual("A | B", try S.text(blocks[9], arena));
    try testing.expectEqual(SPAN_BOLD, blocks[9].spans[0].flags);
    try testing.expectEqual("C", try S.text(blocks[10], arena));
}

test "browser.screenshot: adjacent anchors" {
    defer testing.test_session.closeAllPages();
    const frame = try testing.createFrame();
    frame.url = "http://localhost/";
    const doc = frame.window._document;
    const div = try doc.createElement("div", null, frame);
    // Inside <p> (not a layout block) so markdown's standalone rule doesn't
    // apply and the anchors flow inline.
    try Frame.parse.htmlAsChildren(frame, div.asNode(),
        \\<p><a href="/a">Log In</a><a href="/b">Sign Up</a><b>!</b> see <a href="/c">this</a>.</p>
    );

    var builder: Builder = .{ .arena = testing.arena_allocator, .frame = frame };
    try builder.render(div.asNode());
    try builder.closeBlock();
    const blocks = builder.blocks.items;
    try testing.expectEqual(1, blocks.len);
    var out: std.ArrayList(u8) = .empty;
    for (blocks[0].spans[0..blocks[0].spans_len]) |sp| try out.appendSlice(testing.arena_allocator, sp.text[0..sp.len]);
    try testing.expectString("Log In Sign Up! see this.", out.items);
}

test "browser.screenshot: standalone anchors get their own block" {
    defer testing.test_session.closeAllPages();
    const frame = try testing.createFrame();
    frame.url = "http://localhost/";
    const doc = frame.window._document;
    const div = try doc.createElement("div", null, frame);
    try Frame.parse.htmlAsChildren(frame, div.asNode(),
        \\<nav><a href="/a">bsky</a><a href="/b">rss</a></nav>
        \\<div><a href="/p"><h3>Post title</h3><span>Aug 04</span></a></div>
        \\<p>inline <a href="/x">link</a> here</p>
    );

    var builder: Builder = .{ .arena = testing.arena_allocator, .frame = frame };
    try builder.render(div.asNode());
    try builder.closeBlock();
    const blocks = builder.blocks.items;
    try testing.expectEqual(5, blocks.len);
    try testing.expectString("bsky", blocks[0].spans[0].text[0..blocks[0].spans[0].len]);
    try testing.expectEqual(BLOCK_TIGHT, blocks[0].flags);
    try testing.expectString("rss", blocks[1].spans[0].text[0..blocks[1].spans[0].len]);
    try testing.expectEqual(.heading, blocks[2].kind);
    try testing.expectString("Post title", blocks[2].spans[0].text[0..blocks[2].spans[0].len]);
    try testing.expectEqual(SPAN_UNDERLINE | SPAN_HAS_COLOR, blocks[2].spans[0].flags);
    try testing.expectString("Aug 04", blocks[3].spans[0].text[0..blocks[3].spans[0].len]);
    try testing.expectEqual(3, blocks[4].spans_len);
    try testing.expectEqual(0, blocks[4].flags);
}

test "browser.screenshot: shadow dom and slots" {
    defer testing.test_session.closeAllPages();
    const frame = try testing.createFrame();
    frame.url = "http://localhost/";
    const doc = frame.window._document;
    const div = try doc.createElement("div", null, frame);
    try div.setHTMLUnsafe(
        \\<x-host><template shadowrootmode="open"><p>shadow <slot></slot></p></template>light</x-host>
    , frame);

    var builder: Builder = .{ .arena = testing.arena_allocator, .frame = frame };
    try builder.render(div.asNode());
    try builder.closeBlock();
    const blocks = builder.blocks.items;
    try testing.expectEqual(1, blocks.len);
    try testing.expectEqual(1, blocks[0].spans_len);
    try testing.expectEqual("shadow light", blocks[0].spans[0].text[0..blocks[0].spans[0].len]);
}

fn testPng(html: []const u8, width: u32) ![]const u8 {
    const frame = try testing.createFrame();
    frame.url = "http://localhost/";

    const doc = frame.window._document;
    const div = try doc.createElement("div", null, frame);
    try Frame.parse.htmlAsChildren(frame, div.asNode(), html);

    var aw: std.Io.Writer.Allocating = .init(testing.arena_allocator);
    _ = try png(testing.arena_allocator, div.asNode(), .{ .width = width }, &aw.writer, frame);
    return aw.written();
}
