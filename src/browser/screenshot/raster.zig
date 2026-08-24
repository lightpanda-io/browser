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

//! Text-only page rasterizer behind `Page.captureScreenshot` and
//! `--dump png`. Lightpanda has no layout engine, so a "screenshot" is the
//! page's text content flowed into blocks — the same content the markdown
//! dump produces — word-wrapped here and rasterized with z2d (glyph outlines,
//! kerning, antialiased fills). Fonts are bundled so output doesn't depend on
//! the host.
//!
//! z2d does no shaping, bidi or line breaking; those come from the ICU that
//! ships inside V8: Arabic is shaped to presentation forms, lines break at
//! UAX #14 opportunities, and each line is reordered from the paragraph's
//! bidi levels. Combining marks are anchored with the fonts' GPOS tables.

const std = @import("std");
const z2d = @import("z2d");
const zlib = @import("zlib");

const icu = @import("../../sys/icu.zig");
const Gpos = @import("gpos.zig");

const Allocator = std.mem.Allocator;

pub const SPAN_BOLD: u32 = 1 << 0;
pub const SPAN_ITALIC: u32 = 1 << 1;
pub const SPAN_UNDERLINE: u32 = 1 << 2;
pub const SPAN_MONO: u32 = 1 << 3;
pub const SPAN_STRIKE: u32 = 1 << 4;
/// `color` holds 0xRRGGBB when set.
pub const SPAN_HAS_COLOR: u32 = 1 << 5;

/// List-like vertical spacing (standalone links, nav bars).
pub const BLOCK_TIGHT: u8 = 1 << 0;

pub const Span = struct {
    text: []const u8,
    flags: u32 = 0,
    color: u32 = 0,
};

pub const Block = struct {
    spans: []const Span,
    /// List marker ("•", "3.") drawn in the gutter of the first line; empty
    /// for none.
    marker: []const u8 = "",
    kind: Kind = .paragraph,
    /// 1..=6 for headings.
    level: u8 = 0,
    list_depth: u8 = 0,
    quote_depth: u8 = 0,
    flags: u8 = 0,

    pub const Kind = enum(u8) {
        paragraph,
        heading,
        /// Whitespace preserved, monospace.
        pre,
        /// Horizontal rule; no spans.
        rule,
    };
};

pub const Opts = struct {
    width: u32,
    /// Output height in CSS px; 0 renders the full content height.
    height: u32 = 0,
    clip: ?Clip = null,
    scale: f32 = 1.0,

    pub const Clip = struct {
        x: f64,
        y: f64,
        width: f64,
        height: f64,
    };
};

pub const Error = Allocator.Error || std.Io.Writer.Error || error{RenderFailed};

const BASE_SIZE: f64 = 16.0;
const PAGE_MARGIN: f64 = 16.0;
const LIST_INDENT: f64 = 24.0;
const QUOTE_INDENT: f64 = 20.0;
const PRE_PAD: f64 = 8.0;

const TEXT_COLOR: u32 = 0x1f1f1f;
const RULE_COLOR: u32 = 0xcccccc;
const PRE_BG: u32 = 0xf4f4f4;

/// Device pixels per side. Chrome's own full-page captures top out around here.
const MAX_RASTER_DIM: u64 = 16384;
/// Device pixels in total, 4 bytes each: a 256MB ceiling on the pixmap. A 4K
/// viewport captured full-page at 2x still fits.
const MAX_RASTER_PIXELS: u64 = 64 << 20;

// tan(14°): the usual synthesized-oblique angle for fonts with no italic face.
const ITALIC_SHEAR: f64 = 0.2493;

const FontId = enum(u2) { sans, bold, mono, mono_bold };

const font_data = [_][]const u8{
    @embedFile("fonts/DejaVuSans.ttf"),
    @embedFile("fonts/DejaVuSans-Bold.ttf"),
    @embedFile("fonts/DejaVuSansMono.ttf"),
    @embedFile("fonts/DejaVuSansMono-Bold.ttf"),
};

/// Renders `blocks` to a PNG streamed into `writer` and returns the full-page
/// content height in CSS px. With a null writer only the layout runs and the
/// height comes back.
pub fn run(arena: Allocator, blocks: []const Block, opts: Opts, writer: ?*std.Io.Writer) Error!u32 {
    return render(arena, blocks, opts, writer) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.WriteFailed => error.WriteFailed,
        else => error.RenderFailed,
    };
}

fn render(arena: Allocator, blocks: []const Block, opts: Opts, writer: ?*std.Io.Writer) !u32 {
    var r: Renderer = try .init(arena);
    return r.render(blocks, opts, writer);
}

const Style = struct {
    font: FontId,
    size: f64,
    color: u32,
    italic: bool = false,
    underline: bool = false,
    strike: bool = false,
};

// A glyph in a seg. An attached mark draws at its parent's pen position plus
// (dx, dy) in CSS px (dy up) and contributes no advance.
const Placed = struct {
    cp: u21,
    dx: f64 = 0,
    dy: f64 = 0,
    attached: bool = false,
};

// A run of same-style, same-direction text placed on a line, glyphs in
// visual order, x relative to the block's content origin, in CSS px.
const Seg = struct {
    glyphs: []const Placed,
    style: Style,
    x: f64,
    width: f64,
};

const PlacedBlock = struct {
    block: *const Block,
    /// Content origin in CSS px.
    x: f64,
    y: f64,
    /// Line box height in CSS px.
    line_box: f64 = 0,
    /// Ascent offset of the baseline within a line box.
    baseline: f64 = 0,
    lines: []const []const Seg = &.{},
    marker: ?Seg = null,

    fn textHeight(p: *const PlacedBlock) f64 {
        return @as(f64, @floatFromInt(p.lines.len)) * p.line_box;
    }
};

// A bundled face with the metrics the layout needs, as fractions of an em.
const Face = struct {
    font: z2d.Font,
    gpos: Gpos,
    ascent: f64,
    descent: f64,
    underline_position: f64,
    underline_thickness: f64,
    strikeout_position: f64,
    strikeout_size: f64,

    fn init(arena: Allocator, data: []const u8) !Face {
        const gpos: Gpos = try .init(arena, data);
        const m = try gpos.readMetrics();
        const upm: f64 = @floatFromInt(m.units_per_em);
        return .{
            .font = try z2d.Font.loadBuffer(data),
            .gpos = gpos,
            .ascent = @as(f64, @floatFromInt(m.ascent)) / upm,
            .descent = @as(f64, @floatFromInt(-m.descent)) / upm,
            .underline_position = @as(f64, @floatFromInt(m.underline_position)) / upm,
            .underline_thickness = @as(f64, @floatFromInt(m.underline_thickness)) / upm,
            .strikeout_position = @as(f64, @floatFromInt(m.strikeout_position)) / upm,
            .strikeout_size = @as(f64, @floatFromInt(m.strikeout_size)) / upm,
        };
    }

    /// Device px per font unit at `size` px.
    fn unitScale(f: *const Face, size: f64) f64 {
        return size / @as(f64, @floatFromInt(f.font.meta.units_per_em));
    }
};

// A mark's GPOS anchor offset (font units) to its parent: the cluster's
// base, or the previous attached mark when stacking.
const Attach = struct {
    parent: usize,
    root: usize,
    dx: i16,
    dy: i16,
};

// One block's text in logical order, as UTF-16 units with a style index each,
// plus everything the per-line pass needs.
const Para = struct {
    text: []const u16,
    style_of: []const u16,
    styles: []const Style,
    levels: []const u8 = &.{},
    attach: []const ?Attach = &.{},
    /// For a base unit, the index after the last mark that follows it.
    cluster_end: []const usize = &.{},
    rtl: bool = false,
    /// Scratch for visualLine, sized to the text: visual order of a line,
    /// and resolved offsets of emitted marks for stacking.
    index_map: []i32 = &.{},
    mark_dx: []f64 = &.{},
    mark_dy: []f64 = &.{},
};

const Renderer = struct {
    arena: Allocator,
    faces: [font_data.len]Face,
    // Glyph metrics, outlines and kern pairs are all backed by seek-and-read
    // parses of the font tables; page-lifetime caches keep the cost at one
    // parse per unique glyph instead of one per occurrence.
    glyphs: std.AutoHashMapUnmanaged(u32, z2d.Glyph) = .empty,
    outlines: std.AutoHashMapUnmanaged(u32, z2d.Glyph.Outline) = .empty,
    kerns: std.AutoHashMapUnmanaged(u64, i16) = .empty,
    masks: std.AutoHashMapUnmanaged(MaskKey, ?GlyphMask) = .empty,
    // Rasterization scratch: an alpha8 surface sized to the glyph.
    mask_scratch: []z2d.pixel.Alpha8 = &.{},

    fn init(arena: Allocator) !Renderer {
        var r: Renderer = .{ .arena = arena, .faces = undefined };
        for (font_data, 0..) |data, i| {
            r.faces[i] = try Face.init(arena, data);
        }
        return r;
    }

    fn face(self: *Renderer, id: FontId) *Face {
        return &self.faces[@intFromEnum(id)];
    }

    fn glyph(self: *Renderer, id: FontId, cp: u21) !z2d.Glyph {
        const key = (@as(u32, @intFromEnum(id)) << 21) | cp;
        if (self.glyphs.get(key)) |g| return g;
        const g = try z2d.Glyph.init(&self.face(id).font, cp);
        try self.glyphs.put(self.arena, key, g);
        return g;
    }

    fn outline(self: *Renderer, id: FontId, g: z2d.Glyph) !*z2d.Glyph.Outline {
        const key = (@as(u32, @intFromEnum(id)) << 24) | g.index;
        const gop = try self.outlines.getOrPut(self.arena, key);
        if (!gop.found_existing) {
            gop.value_ptr.* = try z2d.Glyph.Outline.init(self.arena, &self.face(id).font, g);
        }
        return gop.value_ptr;
    }

    /// Kern between `prev` and `g` in font units; 0 without a previous glyph.
    fn kern(self: *Renderer, id: FontId, prev: ?z2d.Glyph, g: z2d.Glyph) !f64 {
        const p = prev orelse return 0.0;
        const key = (@as(u64, @intFromEnum(id)) << 62) | (@as(u64, p.index) << 31) | g.index;
        const gop = try self.kerns.getOrPut(self.arena, key);
        if (!gop.found_existing) {
            gop.value_ptr.* = try z2d.Glyph.getKernAdvance(&self.face(id).font, p.index, g.index);
        }
        return @floatFromInt(gop.value_ptr.*);
    }

    /// Advance in font units.
    fn advance(self: *Renderer, id: FontId, g: z2d.Glyph) f64 {
        return @floatFromInt(if (g.advance > 0) g.advance else self.face(id).font.meta.advance_width_max);
    }

    // Widths here mirror the pen movement in drawSeg so wrap decisions and
    // drawn runs agree.
    fn cpsWidth(self: *Renderer, id: FontId, size: f64, glyphs: []const Placed) !f64 {
        const scale = self.face(id).unitScale(size);
        var width: f64 = 0.0;
        var prev: ?z2d.Glyph = null;
        for (glyphs) |pl| {
            if (pl.attached) continue;
            const g = try self.glyph(id, pl.cp);
            width += (try self.kern(id, prev, g) + self.advance(id, g)) * scale;
            prev = g;
        }
        return width;
    }

    // Width of logical units [a, b); kerning applies within a style run.
    fn unitsWidth(self: *Renderer, p: *const Para, a: usize, b: usize) !f64 {
        var width: f64 = 0.0;
        var i = a;
        var prev: ?z2d.Glyph = null;
        var prev_style: ?u16 = null;
        while (i < b) {
            const cp, const n = decodeUtf16(p.text[i..b]);
            const si = p.style_of[i];
            const st = p.styles[si];
            const g = try self.glyph(st.font, cp);
            const k = if (prev_style == si) try self.kern(st.font, prev, g) else 0.0;
            width += (k + self.advance(st.font, g)) * self.face(st.font).unitScale(st.size);
            prev = g;
            prev_style = si;
            i += n;
        }
        return width;
    }

    fn spanStyle(block: *const Block, span: *const Span, size: f64) Style {
        const flags = span.flags;
        const is_pre = block.kind == .pre;
        const mono = is_pre or flags & SPAN_MONO != 0;
        const bold = flags & SPAN_BOLD != 0 or block.kind == .heading;
        return .{
            .font = if (mono and bold) .mono_bold else if (mono) .mono else if (bold) .bold else .sans,
            .size = if (!is_pre and flags & SPAN_MONO != 0) size * 0.9 else size,
            .color = if (flags & SPAN_HAS_COLOR != 0) span.color else TEXT_COLOR,
            .italic = flags & SPAN_ITALIC != 0,
            .underline = flags & SPAN_UNDERLINE != 0,
            .strike = flags & SPAN_STRIKE != 0,
        };
    }

    /// (font_size, space_before, space_after, line_height_factor)
    fn blockMetrics(b: *const Block) struct { f64, f64, f64, f64 } {
        switch (b.kind) {
            .heading => {
                const s: f64 = switch (b.level) {
                    1 => 2.0,
                    2 => 1.5,
                    3 => 1.25,
                    4 => 1.1,
                    else => 1.0,
                };
                return .{ BASE_SIZE * s, 20.0, 10.0, 1.25 };
            },
            .pre => return .{ BASE_SIZE * 0.875, 12.0, 12.0, 1.4 },
            .rule => return .{ 0.0, 12.0, 12.0, 1.0 },
            .paragraph => {
                const tight = b.list_depth > 0 or b.flags & BLOCK_TIGHT != 0;
                const spacing: f64 = if (tight) 4.0 else 12.0;
                return .{ BASE_SIZE, spacing, spacing, 1.4 };
            },
        }
    }

    fn render(self: *Renderer, blocks: []const Block, opts: Opts, writer: ?*std.Io.Writer) !u32 {
        const arena = self.arena;
        const scale: f64 = opts.scale;
        const width: f64 = @floatFromInt(opts.width);
        const content_w = @max(width - 2.0 * PAGE_MARGIN, 1.0);
        const measure_only = writer == null;

        var placed: std.ArrayList(PlacedBlock) = .empty;
        var y: f64 = PAGE_MARGIN;
        var prev_after: ?f64 = null;

        for (blocks) |*block| {
            const size, const before, const after, const line_h = blockMetrics(block);
            y += if (prev_after) |pa| @max(pa, before) else 0.0;
            prev_after = after;

            const indent = @as(f64, @floatFromInt(block.list_depth)) * LIST_INDENT +
                @as(f64, @floatFromInt(block.quote_depth)) * QUOTE_INDENT;

            if (block.kind == .rule) {
                try placed.append(arena, .{ .block = block, .x = PAGE_MARGIN + indent, .y = y });
                y += 1.0;
                continue;
            }

            const pad: f64 = if (block.kind == .pre) PRE_PAD else 0.0;
            const avail = @max(content_w - indent - 2.0 * pad, 1.0);
            const lines = try self.layoutLines(block, size, avail, measure_only);

            // CSS-style half-leading; the block's font carries the metrics
            // (mono for pre, sans otherwise) and all faces share them.
            const f = self.face(if (block.kind == .pre) .mono else .sans);
            const line_box = size * line_h;
            const baseline = (line_box - (f.ascent + f.descent) * size) / 2.0 + f.ascent * size;

            var marker: ?Seg = null;
            if (block.marker.len > 0 and !measure_only) {
                const glyphs = try utf8ToPlaced(arena, block.marker);
                const mw = try self.cpsWidth(.sans, BASE_SIZE, glyphs);
                marker = .{
                    .glyphs = glyphs,
                    .style = .{ .font = .sans, .size = BASE_SIZE, .color = TEXT_COLOR },
                    // Absolute CSS x; segs are relative to the content origin.
                    .x = PAGE_MARGIN + indent - mw - 6.0,
                    .width = mw,
                };
            }

            try placed.append(arena, .{
                .block = block,
                .x = PAGE_MARGIN + indent + pad,
                .y = y + pad,
                .line_box = line_box,
                .baseline = baseline,
                .lines = lines,
                .marker = marker,
            });
            y += @as(f64, @floatFromInt(lines.len)) * line_box + 2.0 * pad;
        }
        y += PAGE_MARGIN;
        const content_h: u32 = @intFromFloat(@max(@ceil(y), 1.0));
        const out = writer orelse return content_h;

        // Rasterize the requested strip (viewport or full page), then crop.
        // A clip reaching past the strip extends it, but never past the
        // content.
        var out_h: u32 = if (opts.height == 0) content_h else opts.height;
        if (opts.clip) |clip| {
            var reach = @ceil(clip.y + clip.height);
            if (std.math.isNan(reach)) reach = 0.0;
            out_h = @max(out_h, @as(u32, @intFromFloat(std.math.clamp(reach, 0.0, @as(f64, @floatFromInt(content_h))))));
        }
        const pw_u: u64 = std.math.clamp(@as(u64, @intFromFloat(@ceil(width * scale))), 1, MAX_RASTER_DIM);
        const ph_u: u64 = @min(
            std.math.clamp(@as(u64, @intFromFloat(@ceil(@as(f64, @floatFromInt(out_h)) * scale))), 1, MAX_RASTER_DIM),
            @max(MAX_RASTER_PIXELS / pw_u, 1),
        );
        const pw: i32 = @intCast(pw_u);
        const ph: i32 = @intCast(ph_u);

        var sfc = try z2d.Surface.initPixel(pixel(0xffffff), arena, pw, ph);
        const dst = sfc.image_surface_rgb;

        // Rects (rules, pre backgrounds, quote bars, underlines) go through
        // z2d, batched per block and color; glyphs are blitted directly.
        for (placed.items) |*p| {
            const oy = p.y * scale;
            if (oy > @as(f64, @floatFromInt(ph))) break;
            const text_h = p.textHeight();
            var bg: ColorPaths = .{ .arena = arena };
            var fg: ColorPaths = .{ .arena = arena };
            switch (p.block.kind) {
                .rule => {
                    const x = p.x * scale;
                    try bg.addRect(RULE_COLOR, x, oy, (width - PAGE_MARGIN) * scale - x, 1.0 * scale);
                    try bg.fillAll(arena, &sfc);
                    continue;
                },
                .pre => {
                    const x0 = (p.x - PRE_PAD) * scale;
                    try bg.addRect(PRE_BG, x0, oy - PRE_PAD * scale, (width - PAGE_MARGIN) * scale - x0, (text_h + 2.0 * PRE_PAD) * scale);
                },
                else => {},
            }
            const quote_x = PAGE_MARGIN + @as(f64, @floatFromInt(p.block.list_depth)) * LIST_INDENT;
            for (0..p.block.quote_depth) |i| {
                const bx = (quote_x + @as(f64, @floatFromInt(i)) * QUOTE_INDENT) * scale;
                try bg.addRect(RULE_COLOR, bx, oy, 3.0 * scale, text_h * scale);
            }
            try bg.fillAll(arena, &sfc);
            if (p.marker) |*m| {
                try self.drawSeg(dst, &fg, m, m.x * scale, (p.y + p.baseline) * scale, scale);
            }
            for (p.lines, 0..) |segs, i| {
                const baseline_y = (p.y + @as(f64, @floatFromInt(i)) * p.line_box + p.baseline) * scale;
                for (segs) |*seg| {
                    try self.drawSeg(dst, &fg, seg, (p.x + seg.x) * scale, baseline_y, scale);
                }
            }
            try fg.fillAll(arena, &sfc);
        }

        var window: Window = .{ .buf = dst.buf, .stride = pw_u, .x = 0, .y = 0, .w = pw_u, .h = ph_u };
        if (opts.clip) |clip| {
            const cx: u64 = @intFromFloat(std.math.clamp(@floor(clip.x * scale), 0, @as(f64, @floatFromInt(pw - 1))));
            const cy: u64 = @intFromFloat(std.math.clamp(@floor(clip.y * scale), 0, @as(f64, @floatFromInt(ph - 1))));
            window = .{
                .buf = dst.buf,
                .stride = pw_u,
                .x = cx,
                .y = cy,
                .w = @min(@as(u64, @intFromFloat(@max(@ceil(clip.width * scale), 1.0))), pw_u - cx),
                .h = @min(@as(u64, @intFromFloat(@max(@ceil(clip.height * scale), 1.0))), ph_u - cy),
            };
        }
        try writePng(arena, window, out);
        return content_h;
    }

    // One block: spans concatenate into logical UTF-16 (Arabic shaped per
    // span), lines are filled greedily at UAX #14 opportunities ('\n' is a
    // hard break; a word wider than the line breaks anywhere), then each line
    // is reordered to visual order from the paragraph's bidi levels. Measuring
    // stops at the line count.
    fn layoutLines(self: *Renderer, block: *const Block, size: f64, avail: f64, measure_only: bool) ![]const []const Seg {
        const arena = self.arena;
        const is_pre = block.kind == .pre;

        var text: std.ArrayList(u16) = .empty;
        var style_of: std.ArrayList(u16) = .empty;
        var styles: std.ArrayList(Style) = .empty;
        var scratch: std.ArrayList(u16) = .empty;
        for (block.spans) |*span| {
            try styles.append(arena, spanStyle(block, span, size));
            const si: u16 = @intCast(styles.items.len - 1);
            // UTF-16 never needs more units than UTF-8 bytes.
            try scratch.resize(arena, span.text.len);
            scratch.items.len = std.unicode.utf8ToUtf16Le(scratch.items, span.text) catch return error.InvalidText;
            var units: []const u16 = scratch.items;
            if (hasArabic(units)) {
                const shaped = try arena.alloc(u16, units.len * 2);
                var err: c_int = 0;
                const n = icu.u_shapeArabic(units.ptr, @intCast(units.len), shaped.ptr, @intCast(shaped.len), icu.U_SHAPE_LETTERS_SHAPE_TASHKEEL_ISOLATED, &err);
                if (!icu.failed(err)) {
                    units = shaped[0..@intCast(n)];
                    // Tashkeel come back as FE70-block presentation forms,
                    // which are not GDEF marks and carry no anchors. ICU has
                    // no option that leaves them bare.
                    for (shaped[0..@intCast(n)]) |*u| u.* = bareTashkeel(u.*);
                }
            }
            try text.appendSlice(arena, units);
            try style_of.appendNTimes(arena, si, units.len);
        }
        const len = text.items.len;
        if (len == 0) return &.{};
        const n: i32 = @intCast(len);

        var para: Para = .{ .text = text.items, .style_of = style_of.items, .styles = styles.items };
        if (!measure_only) {
            try self.attachMarks(&para);

            const bidi = icu.ubidi_open() orelse return error.IcuFailed;
            defer icu.ubidi_close(bidi);
            var err: c_int = 0;
            icu.ubidi_setPara(bidi, para.text.ptr, n, icu.UBIDI_DEFAULT_LTR, null, &err);
            if (icu.failed(err)) return error.IcuFailed;
            para.levels = try arena.dupe(u8, (icu.ubidi_getLevels(bidi, &err) orelse return error.IcuFailed)[0..len]);
            if (icu.failed(err)) return error.IcuFailed;
            para.rtl = icu.ubidi_getParaLevel(bidi) & 1 == 1;
            para.index_map = try arena.alloc(i32, len);
            para.mark_dx = try arena.alloc(f64, len);
            para.mark_dy = try arena.alloc(f64, len);
        }

        var err: c_int = 0;
        const brk = icu.ubrk_open(icu.UBRK_LINE, null, para.text.ptr, n, &err) orelse return error.IcuFailed;
        if (icu.failed(err)) return error.IcuFailed;
        defer icu.ubrk_close(brk);

        var lines: std.ArrayList([]const Seg) = .empty;
        var line_start: usize = 0;
        var cur_w: f64 = 0.0;
        var tok_start: usize = 0;
        while (true) {
            const b = icu.ubrk_next(brk);
            if (b == icu.UBRK_DONE) break;
            const tok_end: usize = @intCast(b);
            const hard = icu.ubrk_getRuleStatus(brk) >= icu.UBRK_LINE_HARD;
            if (is_pre and !hard and tok_end != len) continue;

            var content_end = tok_end;
            while (content_end > tok_start and isBreakSpace(para.text[content_end - 1])) content_end -= 1;
            const w_trim = try self.unitsWidth(&para, tok_start, content_end);

            if (line_start < tok_start and cur_w + w_trim > avail) {
                try lines.append(arena, try self.visualLine(&para, line_start, tok_start, avail, measure_only));
                line_start = tok_start;
                cur_w = 0.0;
            }
            if (cur_w + w_trim > avail) {
                // Overflow: fill lines with as many units as fit, at least one.
                var pos = tok_start;
                while (pos < content_end) {
                    var fit_end = pos;
                    var fit_w: f64 = 0.0;
                    while (fit_end < content_end) {
                        var next = fit_end + 1;
                        if (std.unicode.utf16IsHighSurrogate(para.text[fit_end]) and next < content_end) next += 1;
                        const uw = try self.unitsWidth(&para, fit_end, next);
                        if (fit_end > pos and cur_w + fit_w + uw > avail) break;
                        fit_w += uw;
                        fit_end = next;
                    }
                    if (fit_end == content_end) {
                        cur_w += fit_w;
                        break;
                    }
                    try lines.append(arena, try self.visualLine(&para, line_start, fit_end, avail, measure_only));
                    line_start = fit_end;
                    pos = fit_end;
                    cur_w = 0.0;
                }
            } else {
                cur_w += w_trim;
            }
            cur_w += try self.unitsWidth(&para, content_end, tok_end);
            if (hard) {
                try lines.append(arena, try self.visualLine(&para, line_start, tok_end, avail, measure_only));
                line_start = tok_end;
                cur_w = 0.0;
            }
            tok_start = tok_end;
        }
        if (line_start < len) {
            try lines.append(arena, try self.visualLine(&para, line_start, len, avail, measure_only));
        }
        return lines.items;
    }

    // GPOS mark attachment, in logical order: a mark anchors to the preceding
    // base of the same style, or to the previous attached mark of its cluster
    // (stacking). Also records where each base's cluster of marks ends.
    fn attachMarks(self: *Renderer, p: *Para) !void {
        const len = p.text.len;
        const attach = try self.arena.alloc(?Attach, len);
        @memset(attach, null);
        const cluster_end = try self.arena.alloc(usize, len);

        var i: usize = 0;
        var base: ?usize = null;
        var last_mark: ?usize = null;
        while (i < len) {
            const cp, const cn = decodeUtf16(p.text[i..]);
            const si = p.style_of[i];
            const st = p.styles[si];
            const gp = &self.face(st.font).gpos;
            const g = try self.glyph(st.font, cp);
            if (g.index <= std.math.maxInt(u16) and gp.isMark(@intCast(g.index))) {
                if (base) |b| {
                    cluster_end[b] = i + cn;
                    if (p.style_of[b] == si) {
                        const gid: u16 = @intCast(g.index);
                        if (last_mark) |m| {
                            const mcp, _ = decodeUtf16(p.text[m..]);
                            const mg = try self.glyph(st.font, mcp);
                            if (gp.attachToMark(@intCast(mg.index), gid)) |o| {
                                attach[i] = .{ .parent = m, .root = b, .dx = o.dx, .dy = o.dy };
                            }
                        }
                        if (attach[i] == null) {
                            const bcp, _ = decodeUtf16(p.text[b..]);
                            const bg = try self.glyph(st.font, bcp);
                            if (gp.attachToBase(@intCast(bg.index), gid)) |o| {
                                attach[i] = .{ .parent = b, .root = b, .dx = o.dx, .dy = o.dy };
                            }
                        }
                        if (attach[i] != null) last_mark = i;
                    }
                }
            } else {
                base = i;
                last_mark = null;
                cluster_end[i] = i + cn;
            }
            i += cn;
        }
        p.attach = attach;
        p.cluster_end = cluster_end;
    }

    // Logical units [a, b) of one line into visual-order segs. Trailing
    // whitespace hangs; RTL paragraphs flush right. Attached marks are
    // emitted right after their cluster's base whatever the run direction
    // (ubidi reverses them to precede it in RTL runs), positioned relative
    // to the pen after the base.
    fn visualLine(self: *Renderer, p: *const Para, a: usize, b_: usize, avail: f64, measure_only: bool) ![]const Seg {
        if (measure_only) return &.{};
        const arena = self.arena;
        var b = b_;
        while (b > a and isBreakSpace(p.text[b - 1])) b -= 1;
        const len = b - a;
        if (len == 0) return &.{};

        const index_map = p.index_map[0..len];
        icu.ubidi_reorderVisual(p.levels[a..].ptr, @intCast(len), index_map.ptr);

        var segs: std.ArrayList(Seg) = .empty;
        var glyphs: std.ArrayList(Placed) = .empty;
        var cur_style: u16 = 0;
        var cur_odd: bool = false;
        var x: f64 = 0.0;

        const Flush = struct {
            fn run(r: *Renderer, s: *std.ArrayList(Seg), gl: *std.ArrayList(Placed), st: Style, pen_x: *f64) !void {
                if (gl.items.len == 0) return;
                const visual = try r.arena.dupe(Placed, gl.items);
                const w = try r.cpsWidth(st.font, st.size, visual);
                try s.append(r.arena, .{ .glyphs = visual, .style = st, .x = pen_x.*, .width = w });
                pen_x.* += w;
                gl.clearRetainingCapacity();
            }
        };

        var i: usize = 0;
        while (i < len) {
            const j = a + @as(usize, @intCast(index_map[i]));
            if (p.attach[j]) |at| if (at.root >= a) {
                // Drawn with its root.
                i += 1;
                continue;
            };
            var cp: u21 = p.text[j];
            var consumed: usize = 1;
            if (i + 1 < len) {
                const j2 = a + @as(usize, @intCast(index_map[i + 1]));
                // An RTL run reverses a surrogate pair's halves along with
                // everything else.
                if (std.unicode.utf16IsHighSurrogate(p.text[j]) and std.unicode.utf16IsLowSurrogate(p.text[j2])) {
                    cp = std.unicode.utf16DecodeSurrogatePair(&.{ p.text[j], p.text[j2] }) catch unreachable;
                    consumed = 2;
                } else if (std.unicode.utf16IsLowSurrogate(p.text[j]) and std.unicode.utf16IsHighSurrogate(p.text[j2])) {
                    cp = std.unicode.utf16DecodeSurrogatePair(&.{ p.text[j2], p.text[j] }) catch unreachable;
                    consumed = 2;
                }
            }
            const odd = p.levels[j] & 1 == 1;
            if (odd) cp = @intCast(icu.u_charMirror(cp));
            const si = p.style_of[j];
            if (si != cur_style or odd != cur_odd) {
                try Flush.run(self, &segs, &glyphs, p.styles[cur_style], &x);
            }
            cur_style = si;
            cur_odd = odd;
            try glyphs.append(arena, .{ .cp = cp });

            // The cluster's marks, in logical order.
            const st = p.styles[si];
            const f = self.face(st.font);
            const gscale = f.unitScale(st.size);
            const base_advance = self.advance(st.font, try self.glyph(st.font, cp)) * gscale;
            var k = j + consumed;
            const end = @min(p.cluster_end[j], b);
            while (k < end) {
                const mcp, const mn = decodeUtf16(p.text[k..]);
                defer k += mn;
                const at = p.attach[k] orelse continue;
                if (at.root != j) continue;
                var dx = @as(f64, @floatFromInt(at.dx)) * gscale;
                var dy = @as(f64, @floatFromInt(at.dy)) * gscale;
                if (at.parent == at.root) {
                    dx -= base_advance;
                } else {
                    dx += p.mark_dx[at.parent];
                    dy += p.mark_dy[at.parent];
                }
                p.mark_dx[k] = dx;
                p.mark_dy[k] = dy;
                try glyphs.append(arena, .{ .cp = mcp, .dx = dx, .dy = dy, .attached = true });
            }
            i += consumed;
        }
        try Flush.run(self, &segs, &glyphs, p.styles[cur_style], &x);
        if (p.rtl and x < avail) {
            for (segs.items) |*seg| seg.x += avail - x;
        }
        return segs.items;
    }

    // Each unique styled glyph is rasterized once into a coverage mask and
    // blitted per occurrence; rasterizing glyphs in place made fill cost
    // grow with whole line boxes instead of inked pixels.
    fn drawSeg(self: *Renderer, dst: z2d.surface.ImageSurface(z2d.pixel.RGB), paths: *ColorPaths, seg: *const Seg, x: f64, baseline_y: f64, scale: f64) !void {
        const st = seg.style;
        const size = st.size * scale;
        const f = self.face(st.font);
        const gscale = f.unitScale(size);
        const color = rgb(st.color);
        var pen: f64 = 0.0;
        var prev: ?z2d.Glyph = null;
        for (seg.glyphs) |pl| {
            const g = try self.glyph(st.font, pl.cp);
            if (!pl.attached) pen += try self.kern(st.font, prev, g) * gscale;
            if (g.outline != .none) {
                var dev_st = st;
                dev_st.size = size;
                // Masks are cached per quarter-pixel phase so letter spacing
                // keeps its fractional advances.
                const exact = x + pen + pl.dx * scale;
                const gx = @floor(exact);
                const phase: u2 = @intFromFloat(@min((exact - gx) * 4.0, 3.0));
                if (try self.mask(dev_st, pl.cp, g, phase)) |m| {
                    const gy: i32 = @intFromFloat(@round(baseline_y - pl.dy * scale));
                    blit(dst, m, @as(i32, @intFromFloat(gx)) + m.dx, gy + m.dy, color);
                }
            }
            if (!pl.attached) {
                pen += self.advance(st.font, g) * gscale;
                prev = g;
            }
        }

        const w = seg.width * scale;
        if (st.underline) {
            try paths.addRect(st.color, x, @round(baseline_y - f.underline_position * size), w, @max(@round(f.underline_thickness * size), 1.0));
        }
        if (st.strike) {
            try paths.addRect(st.color, x, @round(baseline_y - f.strikeout_position * size), w, @max(@round(f.strikeout_size * size), 1.0));
        }
    }

    fn mask(self: *Renderer, st: Style, cp: u21, g: z2d.Glyph, phase: u2) !?*GlyphMask {
        const key: MaskKey = .{
            .font = st.font,
            .cp = cp,
            // Quarter-pixel size buckets; sizes come from the fixed metric
            // table times the device scale, so collisions are theoretical.
            .size_q = @intFromFloat(st.size * 4.0),
            .italic = st.italic,
            .phase = phase,
        };
        const gop = try self.masks.getOrPut(self.arena, key);
        if (!gop.found_existing) {
            gop.value_ptr.* = try self.renderMask(st, g, phase);
        }
        return if (gop.value_ptr.*) |*m| m else null;
    }

    // st.size here is already in device px (the caller multiplied by scale).
    // The glyph is rasterized as coverage into a scratch surface sized from
    // its own bbox, then trimmed to the inked box.
    fn renderMask(self: *Renderer, st: Style, g: z2d.Glyph, phase: u2) !?GlyphMask {
        const size = st.size;
        const f = self.face(st.font);
        const gscale = f.unitScale(size);
        const o = try self.outline(st.font, g);
        const pp1: f64 = if (!f.font.meta.lsb_is_at_x_zero) @floatFromInt(o.x_min - g.lsb) else 0.0;

        // Device-space bbox relative to the pen at the baseline, y down.
        var x_lo = @as(f64, @floatFromInt(o.x_min)) * gscale + pp1;
        var x_hi = @as(f64, @floatFromInt(o.x_max)) * gscale + pp1;
        const y_top = -@as(f64, @floatFromInt(o.y_max)) * gscale;
        const y_bot = -@as(f64, @floatFromInt(o.y_min)) * gscale;
        if (st.italic) {
            x_hi += ITALIC_SHEAR * @max(0.0, -y_top);
            x_lo -= ITALIC_SHEAR * @max(0.0, y_bot);
        }
        const x0: i32 = @intFromFloat(@floor(x_lo) - 1);
        const x1: i32 = @intFromFloat(@ceil(x_hi) + 3);
        const y0: i32 = @intFromFloat(@floor(y_top) - 1);
        const y1: i32 = @intFromFloat(@ceil(y_bot) + 2);
        const box_w = x1 - x0;
        const box_h = y1 - y0;
        if (box_w <= 0 or box_h <= 0 or box_w > 4096 or box_h > 4096) return null;
        const ox_px: f64 = @floatFromInt(-x0);
        const ox = ox_px + @as(f64, @floatFromInt(phase)) / 4.0;
        const oy: f64 = @floatFromInt(-y0);

        const bw: usize = @intCast(box_w);
        const bh: usize = @intCast(box_h);
        if (self.mask_scratch.len < bw * bh) {
            self.mask_scratch = try self.arena.alloc(z2d.pixel.Alpha8, @max(bw * bh, 4096));
        }
        const buf = self.mask_scratch[0 .. bw * bh];
        var msfc = z2d.Surface.initBuffer(.image_surface_alpha8, null, buf, box_w, box_h);

        // Shear around the local baseline so the glyph origin stays put.
        const base: z2d.Transformation = if (st.italic)
            .{ .ax = 1, .by = -ITALIC_SHEAR, .cx = 0, .dy = 1, .tx = ITALIC_SHEAR * oy, .ty = 0 }
        else
            .identity;
        var path: z2d.Path = .empty;
        // z2d outlines are pre-flipped by translating -units_per_em, so the
        // draw origin is the top of the em box, one em above the baseline.
        path.transformation = base.translate(ox + pp1, oy - size).scale(gscale, gscale);
        try o.appendToPath(self.arena, &path);

        // An opaque source lets the fill write coverage straight into the
        // mask. painter.fill's allocations are call-scoped.
        const pattern: z2d.Pattern = .{ .opaque_pattern = .{ .pixel = .{ .alpha8 = .{ .a = 255 } } } };
        var sfa = std.heap.stackFallback(64 * 1024, self.arena);
        try z2d.painter.fill(sfa.get(), &msfc, &pattern, path.nodes.items, .default);

        var min_x: usize = bw;
        var min_y: usize = bh;
        var max_x: usize = 0;
        var max_y: usize = 0;
        for (0..bh) |y| {
            for (buf[y * bw ..][0..bw], 0..) |px, x| {
                if (px.a == 0) continue;
                min_x = @min(min_x, x);
                min_y = @min(min_y, y);
                max_x = @max(max_x, x);
                max_y = @max(max_y, y);
            }
        }
        if (min_x > max_x) {
            return null;
        }
        const tw = max_x - min_x + 1;
        const th = max_y - min_y + 1;
        const cov = try self.arena.alloc(u8, tw * th);
        for (0..th) |y| {
            for (buf[(min_y + y) * bw + min_x ..][0..tw], 0..) |px, x| cov[y * tw + x] = px.a;
        }
        return .{
            .w = tw,
            .h = th,
            .cov = cov,
            .dx = @as(i32, @intCast(min_x)) - @as(i32, @intFromFloat(ox_px)),
            .dy = @as(i32, @intCast(min_y)) - @as(i32, @intFromFloat(oy)),
        };
    }
};

// Source-over of a coverage mask in one color onto the RGB destination.
// Fully transparent and fully covered pixels skip the blend.
fn blit(dst: z2d.surface.ImageSurface(z2d.pixel.RGB), m: *const GlyphMask, x: i32, y: i32, color: z2d.pixel.RGB) void {
    const dst_w: usize = @intCast(dst.width);
    for (0..m.h) |r| {
        const yy = y + @as(i32, @intCast(r));
        if (yy < 0 or yy >= dst.height) continue;
        const row = dst.buf[@as(usize, @intCast(yy)) * dst_w ..][0..dst_w];
        for (m.cov[r * m.w ..][0..m.w], 0..) |a, c| {
            if (a == 0) continue;
            const xx = x + @as(i32, @intCast(c));
            if (xx < 0 or xx >= dst.width) continue;
            const px = &row[@intCast(xx)];
            if (a == 255) {
                px.* = color;
                continue;
            }
            const inv: u32 = 255 - a;
            px.r = @intCast((@as(u32, color.r) * a + @as(u32, px.r) * inv + 127) / 255);
            px.g = @intCast((@as(u32, color.g) * a + @as(u32, px.g) * inv + 127) / 255);
            px.b = @intCast((@as(u32, color.b) * a + @as(u32, px.b) * inv + 127) / 255);
        }
    }
}

const MaskKey = struct {
    font: FontId,
    cp: u21,
    size_q: u16,
    italic: bool,
    /// Horizontal subpixel phase, in quarter pixels.
    phase: u2,
};

const GlyphMask = struct {
    w: usize,
    h: usize,
    /// Coverage, row-major, trimmed to the inked box.
    cov: []const u8,
    // Offset of the trimmed mask's top-left relative to the (pen x, baseline)
    // the glyph is composited at.
    dx: i32,
    dy: i32,
};

const ColorPaths = struct {
    arena: Allocator,
    map: std.AutoArrayHashMapUnmanaged(u32, z2d.Path) = .empty,

    fn addRect(self: *ColorPaths, color: u32, x: f64, y: f64, w: f64, h: f64) !void {
        if (w <= 0 or h <= 0) return;
        const gop = try self.map.getOrPut(self.arena, color);
        if (!gop.found_existing) {
            gop.value_ptr.* = .empty;
        }
        const path = gop.value_ptr;
        try path.moveTo(self.arena, x, y);
        try path.lineTo(self.arena, x + w, y);
        try path.lineTo(self.arena, x + w, y + h);
        try path.lineTo(self.arena, x, y + h);
        try path.close(self.arena);
    }

    fn fillAll(self: *ColorPaths, arena: Allocator, sfc: *z2d.Surface) !void {
        var it = self.map.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.nodes.items.len == 0) continue;
            const pattern: z2d.Pattern = .{ .opaque_pattern = .{ .pixel = pixel(entry.key_ptr.*) } };
            try z2d.painter.fill(arena, sfc, &pattern, entry.value_ptr.nodes.items, .default);
        }
    }
};

/// A rectangle of an RGB raster to encode.
const Window = struct {
    buf: []const z2d.pixel.RGB,
    stride: u64,
    x: u64,
    y: u64,
    w: u64,
    h: u64,
};

// z2d's own PNG export converts pixel-by-pixel through the Surface
// interface and compresses with std.flate; encoding straight off the raw RGB
// buffer through the zlib the binary already links is an order of magnitude
// faster. Level 2: output is mostly base64'd over CDP so size matters, but
// higher levels are severalfold slower for a few percent smaller.
fn writePng(arena: Allocator, win: Window, writer: *std.Io.Writer) !void {
    const w: usize = @intCast(win.w);

    try writer.writeAll("\x89PNG\r\n\x1a\n");
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], @intCast(win.w), .big);
    std.mem.writeInt(u32, ihdr[4..8], @intCast(win.h), .big);
    ihdr[8] = 8; // bit depth
    ihdr[9] = 2; // truecolor
    ihdr[10] = 0; // deflate
    ihdr[11] = 0; // filter method
    ihdr[12] = 0; // no interlace
    try writeChunk(writer, "IHDR", &ihdr);

    // Streamed one scanline in, one IDAT chunk out per 64KB of deflate
    // output, so a capped-height capture never holds a second copy of the
    // raster.
    var zs: zlib.z_stream = std.mem.zeroes(zlib.z_stream);
    if (zlib.deflateInit_(&zs, 2, zlib.ZLIB_VERSION, @sizeOf(zlib.z_stream)) != zlib.Z_OK) {
        return error.EncodeFailed;
    }
    defer _ = zlib.deflateEnd(&zs);

    // Leading no-filter byte per scanline. Text pages are dominated by long
    // solid runs, which deflate handles well without filtering.
    const row = try arena.alloc(u8, w * 3 + 1);
    row[0] = 0;
    const out = try arena.alloc(u8, 1 << 16);
    zs.next_out = out.ptr;
    zs.avail_out = @intCast(out.len);

    for (0..@intCast(win.h)) |y| {
        const src = win.buf[@intCast((win.y + y) * win.stride + win.x)..][0..w];
        for (src, 0..) |px, x| {
            row[1 + x * 3] = px.r;
            row[2 + x * 3] = px.g;
            row[3 + x * 3] = px.b;
        }
        zs.next_in = row.ptr;
        zs.avail_in = @intCast(row.len);
        while (zs.avail_in > 0) {
            if (zlib.deflate(&zs, zlib.Z_NO_FLUSH) != zlib.Z_OK) {
                return error.EncodeFailed;
            }
            if (zs.avail_out == 0) {
                try writeChunk(writer, "IDAT", out);
                zs.next_out = out.ptr;
                zs.avail_out = @intCast(out.len);
            }
        }
    }
    while (true) {
        const rc = zlib.deflate(&zs, zlib.Z_FINISH);
        if (rc != zlib.Z_OK and rc != zlib.Z_STREAM_END) {
            return error.EncodeFailed;
        }
        const produced = out.len - zs.avail_out;
        if (produced > 0) {
            try writeChunk(writer, "IDAT", out[0..produced]);
            zs.next_out = out.ptr;
            zs.avail_out = @intCast(out.len);
        }
        if (rc == zlib.Z_STREAM_END) break;
    }
    try writeChunk(writer, "IEND", "");
}

fn writeChunk(writer: *std.Io.Writer, tag: *const [4]u8, data: []const u8) !void {
    var int_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &int_buf, @intCast(data.len), .big);
    try writer.writeAll(&int_buf);
    try writer.writeAll(tag);
    try writer.writeAll(data);
    var crc: std.hash.Crc32 = .init();
    crc.update(tag);
    crc.update(data);
    std.mem.writeInt(u32, &int_buf, crc.final(), .big);
    try writer.writeAll(&int_buf);
}

fn utf8ToPlaced(arena: Allocator, utf8: []const u8) ![]const Placed {
    var out: std.ArrayList(Placed) = .empty;
    var it = std.unicode.Utf8View.initUnchecked(utf8).iterator();
    while (it.nextCodepoint()) |cp| try out.append(arena, .{ .cp = cp });
    return out.items;
}

// (codepoint, units consumed) at the start of `units`; a lone surrogate
// half decodes as itself.
fn decodeUtf16(units: []const u16) struct { u21, usize } {
    if (units.len >= 2 and std.unicode.utf16IsHighSurrogate(units[0]) and std.unicode.utf16IsLowSurrogate(units[1])) {
        return .{ std.unicode.utf16DecodeSurrogatePair(units[0..2]) catch unreachable, 2 };
    }
    return .{ units[0], 1 };
}

fn isBreakSpace(u: u16) bool {
    return u == ' ' or u == '\n' or u == '\t' or u == '\r';
}

fn bareTashkeel(u: u16) u16 {
    return switch (u) {
        0xFE70, 0xFE71 => 0x064B,
        0xFE72 => 0x064C,
        0xFE74 => 0x064D,
        0xFE76, 0xFE77 => 0x064E,
        0xFE78, 0xFE79 => 0x064F,
        0xFE7A, 0xFE7B => 0x0650,
        0xFE7C, 0xFE7D => 0x0651,
        0xFE7E, 0xFE7F => 0x0652,
        else => u,
    };
}

fn hasArabic(units: []const u16) bool {
    for (units) |u| {
        if ((u >= 0x0600 and u <= 0x08FF) or (u >= 0xFB50 and u <= 0xFDFF) or (u >= 0xFE70 and u <= 0xFEFF)) return true;
    }
    return false;
}

fn rgb(color: u32) z2d.pixel.RGB {
    return .{
        .r = @intCast((color >> 16) & 0xff),
        .g = @intCast((color >> 8) & 0xff),
        .b = @intCast(color & 0xff),
    };
}

fn pixel(color: u32) z2d.Pixel {
    return .{ .rgb = rgb(color) };
}
