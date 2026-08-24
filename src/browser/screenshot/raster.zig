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
//! dump produces — word-wrapped here and rasterized by z2d (glyph outlines,
//! kerning, antialiased fills, PNG encode). Fonts are bundled so output
//! doesn't depend on the host.
//!
//! z2d does no shaping, bidi or line breaking; those come from the ICU that
//! ships inside V8: Arabic is shaped to presentation forms, lines break at
//! UAX #14 opportunities, and each line is reordered from the paragraph's
//! bidi levels. Combining marks are anchored with the fonts' GPOS tables.

const std = @import("std");
const z2d = @import("z2d");

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

// DejaVu Sans metrics per 2048 units; ascent and descent are shared by all
// four bundled faces.
const ASCENT: f64 = 1901.0 / 2048.0;
const DESCENT: f64 = 483.0 / 2048.0;
const UNDERLINE_OFFSET: f64 = -40.0 / 2048.0;
const UNDERLINE_SIZE: f64 = 90.0 / 2048.0;
const STRIKE_OFFSET: f64 = 530.0 / 2048.0;
const STRIKE_SIZE: f64 = 102.0 / 2048.0;

// tan(14°), parley's synthesized-oblique angle for fonts with no italic face.
const ITALIC_SHEAR: f64 = 0.2493;

const FontId = enum(u2) { sans, bold, mono, mono_bold };

const font_data = [_][]const u8{
    @embedFile("fonts/DejaVuSans.ttf"),
    @embedFile("fonts/DejaVuSans-Bold.ttf"),
    @embedFile("fonts/DejaVuSansMono.ttf"),
    @embedFile("fonts/DejaVuSansMono-Bold.ttf"),
};

// ICU from V8's archive; symbols carry its major version.
const icu_version = "77";
fn icu(comptime name: []const u8, comptime T: type) *const T {
    return @extern(*const T, .{ .name = name ++ "_" ++ icu_version });
}
const UBiDi = opaque {};
const UBreakIterator = opaque {};
const ubidi_open = icu("ubidi_open", fn () callconv(.c) ?*UBiDi);
const ubidi_close = icu("ubidi_close", fn (*UBiDi) callconv(.c) void);
const ubidi_setPara = icu("ubidi_setPara", fn (*UBiDi, [*]const u16, i32, u8, ?[*]u8, *c_int) callconv(.c) void);
const ubidi_getParaLevel = icu("ubidi_getParaLevel", fn (*const UBiDi) callconv(.c) u8);
const ubidi_getLevels = icu("ubidi_getLevels", fn (*UBiDi, *c_int) callconv(.c) ?[*]const u8);
const ubidi_reorderVisual = icu("ubidi_reorderVisual", fn ([*]const u8, i32, [*]i32) callconv(.c) void);
const u_shapeArabic = icu("u_shapeArabic", fn ([*]const u16, i32, [*]u16, i32, u32, *c_int) callconv(.c) i32);
const u_charMirror = icu("u_charMirror", fn (i32) callconv(.c) i32);
const ubrk_open = icu("ubrk_open", fn (c_int, ?[*:0]const u8, ?[*]const u16, i32, *c_int) callconv(.c) ?*UBreakIterator);
const ubrk_close = icu("ubrk_close", fn (*UBreakIterator) callconv(.c) void);
const ubrk_next = icu("ubrk_next", fn (*UBreakIterator) callconv(.c) i32);
const ubrk_getRuleStatus = icu("ubrk_getRuleStatus", fn (*UBreakIterator) callconv(.c) i32);

const UBIDI_DEFAULT_LTR: u8 = 0xfe;
const UBRK_LINE: c_int = 2;
const UBRK_DONE: i32 = -1;
const UBRK_LINE_HARD: i32 = 100;
const U_SHAPE_LETTERS_SHAPE_TASHKEEL_ISOLATED: u32 = 0x18;

/// Renders `blocks` to a PNG streamed into `writer` and returns the full-page
/// content height in CSS px. With `measure_only` nothing is rasterized or
/// written; only the height comes back.
pub fn run(arena: Allocator, blocks: []const Block, opts: Opts, writer: *std.Io.Writer, measure_only: bool) Error!u32 {
    var r: Renderer = .{ .arena = arena };
    for (font_data, 0..) |data, i| {
        r.fonts[i] = z2d.Font.loadBuffer(data) catch return error.RenderFailed;
        r.gpos[i] = Gpos.init(arena, data) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.MalformedFont => return error.RenderFailed,
        };
    }
    return r.render(blocks, opts, writer, measure_only) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.WriteFailed => error.WriteFailed,
        else => error.RenderFailed,
    };
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

const Line = struct {
    segs: []const Seg,
};

const PlacedBlock = struct {
    kind: Block.Kind,
    /// Content origin in CSS px.
    x: f64,
    y: f64,
    /// Line box height in CSS px.
    line_box: f64,
    /// Ascent offset of the baseline within a line box.
    baseline: f64,
    lines: []const Line,
    text_height: f64,
    marker: ?Seg,
    quote_bars: u8,
    quote_x: f64,
};

const Renderer = struct {
    arena: Allocator,
    fonts: [4]z2d.Font = undefined,
    gpos: [4]Gpos = undefined,
    // Glyph metrics, outlines and kern pairs are all backed by seek-and-read
    // parses of the font tables; page-lifetime caches keep the cost at one
    // parse per unique glyph instead of one per occurrence.
    glyphs: std.AutoHashMapUnmanaged(u32, z2d.Glyph) = .empty,
    outlines: std.AutoHashMapUnmanaged(u32, z2d.Glyph.Outline) = .empty,
    kerns: std.AutoHashMapUnmanaged(u64, i16) = .empty,
    masks: std.AutoHashMapUnmanaged(MaskKey, ?GlyphMask) = .empty,
    // Rasterization scratch: an alpha8 surface sized to the glyph, and the
    // call-scoped allocations painter.fill makes.
    mask_scratch: []z2d.pixel.Alpha8 = &.{},
    fill_scratch: []u8 = &.{},

    fn glyph(self: *Renderer, font: FontId, cp: u21) !z2d.Glyph {
        const key = (@as(u32, @intFromEnum(font)) << 21) | cp;
        if (self.glyphs.get(key)) |g| return g;
        const g = try z2d.Glyph.init(&self.fonts[@intFromEnum(font)], cp);
        try self.glyphs.put(self.arena, key, g);
        return g;
    }

    fn outline(self: *Renderer, font: FontId, g: z2d.Glyph) !*z2d.Glyph.Outline {
        const key = (@as(u32, @intFromEnum(font)) << 24) | g.index;
        const gop = try self.outlines.getOrPut(self.arena, key);
        if (!gop.found_existing) {
            gop.value_ptr.* = try z2d.Glyph.Outline.init(self.arena, &self.fonts[@intFromEnum(font)], g);
        }
        return gop.value_ptr;
    }

    fn kern(self: *Renderer, font: FontId, prev_index: u32, index: u32) !i16 {
        const key = (@as(u64, @intFromEnum(font)) << 62) | (@as(u64, prev_index) << 31) | index;
        const gop = try self.kerns.getOrPut(self.arena, key);
        if (!gop.found_existing) {
            gop.value_ptr.* = try z2d.Glyph.getKernAdvance(&self.fonts[@intFromEnum(font)], prev_index, index);
        }
        return gop.value_ptr.*;
    }

    // Mirrors the advance accumulation of the glyph pass in drawSeg so wrap
    // decisions and drawn runs agree on widths.
    fn cpsWidth(self: *Renderer, font: FontId, size: f64, glyphs: []const Placed) !f64 {
        const f = &self.fonts[@intFromEnum(font)];
        const scale = size / @as(f64, @floatFromInt(f.meta.units_per_em));
        var width: f64 = 0.0;
        var prev: ?z2d.Glyph = null;
        for (glyphs) |pl| {
            if (pl.attached) continue;
            const g = try self.glyph(font, pl.cp);
            if (prev) |p| {
                width += @as(f64, @floatFromInt(try self.kern(font, p.index, g.index))) * scale;
            }
            width += @as(f64, @floatFromInt(if (g.advance > 0) g.advance else f.meta.advance_width_max)) * scale;
            prev = g;
        }
        return width;
    }

    // Width of logical UTF-16 units [a, b), each styled by index.
    fn unitsWidth(self: *Renderer, text: []const u16, style_of: []const u16, styles: []const Style, a: usize, b: usize) !f64 {
        var width: f64 = 0.0;
        var i = a;
        var prev: ?z2d.Glyph = null;
        var prev_style: ?u16 = null;
        while (i < b) {
            const cp, const n = decodeUtf16(text[i..b]);
            const si = style_of[i];
            const st = styles[si];
            const f = &self.fonts[@intFromEnum(st.font)];
            const scale = st.size / @as(f64, @floatFromInt(f.meta.units_per_em));
            const g = try self.glyph(st.font, cp);
            if (prev) |p| {
                if (prev_style == si) {
                    width += @as(f64, @floatFromInt(try self.kern(st.font, p.index, g.index))) * scale;
                }
            }
            width += @as(f64, @floatFromInt(if (g.advance > 0) g.advance else f.meta.advance_width_max)) * scale;
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

    fn render(self: *Renderer, blocks: []const Block, opts: Opts, writer: *std.Io.Writer, measure_only: bool) !u32 {
        const arena = self.arena;
        const scale: f64 = opts.scale;
        const bidi = ubidi_open() orelse return error.IcuFailed;
        defer ubidi_close(bidi);
        const width: f64 = @floatFromInt(opts.width);
        const content_w = @max(width - 2.0 * PAGE_MARGIN, 1.0);

        var placed: std.ArrayList(PlacedBlock) = .empty;
        var y: f64 = PAGE_MARGIN;
        var prev_after: ?f64 = null;

        for (blocks) |*block| {
            const size, const before, const after, const line_h = blockMetrics(block);
            y += if (prev_after) |pa| @max(pa, before) else 0.0;
            prev_after = after;

            const indent = @as(f64, @floatFromInt(block.list_depth)) * LIST_INDENT +
                @as(f64, @floatFromInt(block.quote_depth)) * QUOTE_INDENT;
            const quote_x = PAGE_MARGIN + @as(f64, @floatFromInt(block.list_depth)) * LIST_INDENT;

            if (block.kind == .rule) {
                try placed.append(arena, .{
                    .kind = .rule,
                    .x = PAGE_MARGIN + indent,
                    .y = y,
                    .line_box = 0,
                    .baseline = 0,
                    .lines = &.{},
                    .text_height = 0,
                    .marker = null,
                    .quote_bars = 0,
                    .quote_x = quote_x,
                });
                y += 1.0;
                continue;
            }

            const pad: f64 = if (block.kind == .pre) PRE_PAD else 0.0;
            const avail = @max(content_w - indent - 2.0 * pad, 1.0);
            const lines = try self.layoutLines(bidi, block, size, avail);

            const line_box = size * line_h;
            // CSS-style half-leading around the shared DejaVu ascent/descent.
            const baseline = (line_box - (ASCENT + DESCENT) * size) / 2.0 + ASCENT * size;
            const text_height = @as(f64, @floatFromInt(lines.len)) * line_box;

            var marker: ?Seg = null;
            if (block.marker.len > 0) {
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
                .kind = block.kind,
                .x = PAGE_MARGIN + indent + pad,
                .y = y + pad,
                .line_box = line_box,
                .baseline = baseline,
                .lines = lines,
                .text_height = text_height,
                .marker = marker,
                .quote_bars = block.quote_depth,
                .quote_x = quote_x,
            });
            y += text_height + 2.0 * pad;
        }
        y += PAGE_MARGIN;
        const content_h: u32 = @intFromFloat(@max(@ceil(y), 1.0));
        if (measure_only) {
            return content_h;
        }

        // Rasterize the requested strip (viewport or full page), then crop.
        // A clip reaching past the strip extends it, but never past the
        // content.
        var out_h: u32 = if (opts.height == 0) content_h else opts.height;
        const clip = opts.clip orelse Opts.Clip{ .x = 0, .y = 0, .width = 0, .height = 0 };
        if (clip.width > 0) {
            var reach = @ceil(@as(f64, clip.y) + @as(f64, clip.height));
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

        // White is all-ones in every byte, padding included: fill in vector
        // stores rather than z2d's per-pixel init (a byte loop in Debug).
        const dst_px = @as(usize, @intCast(pw)) * @as(usize, @intCast(ph));
        const Lane = @Vector(64, u8);
        const dst_bytes = try arena.alignedAlloc(u8, .fromByteUnits(64), std.mem.alignForward(usize, dst_px * 4, 64));
        @memset(std.mem.bytesAsSlice(Lane, dst_bytes), @as(Lane, @splat(0xff)));
        const dst_buf = std.mem.bytesAsSlice(z2d.pixel.RGB, dst_bytes[0 .. dst_px * 4]);
        // Not initBuffer: that memsets the buffer again.
        var sfc: z2d.Surface = .{ .image_surface_rgb = .{ .width = pw, .height = ph, .buf = @alignCast(dst_buf) } };

        // Per block, everything is accumulated into one path per color —
        // backgrounds beneath, glyphs and decorations on top — so the
        // rasterizer runs a few block-sized fills instead of one per text
        // run. (One path per color for the whole page is worse: fill cost
        // grows with edge count times covered scanlines.)
        for (placed.items) |*p| {
            const oy = p.y * scale;
            if (oy > @as(f64, @floatFromInt(ph))) break;
            var bg: ColorPaths = .{ .arena = arena };
            var fg: ColorPaths = .{ .arena = arena };
            switch (p.kind) {
                .rule => {
                    const x = p.x * scale;
                    try bg.addRect(RULE_COLOR, x, oy, (width - PAGE_MARGIN) * scale - x, 1.0 * scale);
                    try bg.fillAll(arena, &sfc);
                    continue;
                },
                .pre => {
                    const x0 = (p.x - PRE_PAD) * scale;
                    try bg.addRect(PRE_BG, x0, oy - PRE_PAD * scale, (width - PAGE_MARGIN) * scale - x0, (p.text_height + 2.0 * PRE_PAD) * scale);
                },
                else => {},
            }
            for (0..p.quote_bars) |i| {
                const bx = (p.quote_x + @as(f64, @floatFromInt(i)) * QUOTE_INDENT) * scale;
                try bg.addRect(RULE_COLOR, bx, oy, 3.0 * scale, p.text_height * scale);
            }
            try bg.fillAll(arena, &sfc);
            if (p.marker) |*m| {
                try self.drawSeg(&sfc, &fg, m, m.x * scale, (p.y + p.baseline) * scale, scale);
            }
            for (p.lines, 0..) |line, i| {
                const baseline_y = (p.y + @as(f64, @floatFromInt(i)) * p.line_box + p.baseline) * scale;
                for (line.segs) |*seg| {
                    try self.drawSeg(&sfc, &fg, seg, (p.x + seg.x) * scale, baseline_y, scale);
                }
            }
            try fg.fillAll(arena, &sfc);
        }

        var view = &sfc;
        var cropped: z2d.Surface = undefined;
        if (clip.width > 0) {
            const cx: i32 = @intFromFloat(std.math.clamp(@floor(@as(f64, clip.x) * scale), 0, @as(f64, @floatFromInt(pw - 1))));
            const cy: i32 = @intFromFloat(std.math.clamp(@floor(@as(f64, clip.y) * scale), 0, @as(f64, @floatFromInt(ph - 1))));
            const cw: i32 = @min(@as(i32, @intFromFloat(@max(@ceil(@as(f64, clip.width) * scale), 1.0))), pw - cx);
            const chh: i32 = @min(@as(i32, @intFromFloat(@max(@ceil(@as(f64, clip.height) * scale), 1.0))), ph - cy);
            cropped = try z2d.Surface.init(.image_surface_rgb, arena, cw, chh);
            var row: i32 = 0;
            while (row < chh) : (row += 1) {
                var col: i32 = 0;
                while (col < cw) : (col += 1) {
                    cropped.putPixel(col, row, sfc.getPixel(cx + col, cy + row) orelse rgb(0xffffff));
                }
            }
            view = &cropped;
        }

        try writePng(arena, view, writer);
        return content_h;
    }

    // One block: spans concatenate into logical UTF-16 (Arabic shaped per
    // span), lines are filled greedily at UAX #14 opportunities ('\n' is a
    // hard break; a word wider than the line breaks anywhere), then each line
    // is reordered to visual order from the paragraph's bidi levels.
    fn layoutLines(self: *Renderer, bidi: *UBiDi, block: *const Block, size: f64, avail: f64) ![]const Line {
        const arena = self.arena;
        const is_pre = block.kind == .pre;

        var text: std.ArrayList(u16) = .empty;
        var style_of: std.ArrayList(u16) = .empty;
        var styles: std.ArrayList(Style) = .empty;
        var scratch: std.ArrayList(u16) = .empty;
        for (block.spans) |*span| {
            try styles.append(arena, spanStyle(block, span, size));
            const si: u16 = @intCast(styles.items.len - 1);
            scratch.clearRetainingCapacity();
            try appendUtf16(arena, &scratch, span.text);
            var units: []const u16 = scratch.items;
            if (hasArabic(units)) {
                const shaped = try arena.alloc(u16, units.len * 2);
                var err: c_int = 0;
                const n = u_shapeArabic(units.ptr, @intCast(units.len), shaped.ptr, @intCast(shaped.len), U_SHAPE_LETTERS_SHAPE_TASHKEEL_ISOLATED, &err);
                if (err <= 0) {
                    units = shaped[0..@intCast(n)];
                    // Tashkeel come back as FE70-block presentation forms,
                    // which are not GDEF marks and carry no anchors.
                    for (shaped[0..@intCast(n)]) |*u| u.* = bareTashkeel(u.*);
                }
            }
            try text.appendSlice(arena, units);
            try style_of.appendNTimes(arena, si, units.len);
        }
        const n: i32 = @intCast(text.items.len);
        if (n == 0) return &.{};

        // GPOS mark attachment, in logical order: a mark anchors to the
        // preceding base of the same style, or to the previous attached
        // mark of its cluster (stacking).
        const attach = try arena.alloc(?Attach, text.items.len);
        @memset(attach, null);
        {
            var i: usize = 0;
            var base: ?usize = null;
            var last_mark: ?usize = null;
            while (i < text.items.len) {
                const cp, const cn = decodeUtf16(text.items[i..]);
                const si = style_of.items[i];
                const st = styles.items[si];
                const gp = &self.gpos[@intFromEnum(st.font)];
                const g = try self.glyph(st.font, cp);
                if (g.index <= std.math.maxInt(u16) and gp.isMark(@intCast(g.index))) {
                    if (base) |b| if (style_of.items[b] == si) {
                        const gid: u16 = @intCast(g.index);
                        if (last_mark) |m| {
                            const mcp, _ = decodeUtf16(text.items[m..]);
                            const mg = try self.glyph(st.font, mcp);
                            if (gp.attachToMark(@intCast(mg.index), gid)) |o| {
                                attach[i] = .{ .parent = m, .root = b, .dx = o.dx, .dy = o.dy };
                            }
                        }
                        if (attach[i] == null) {
                            const bcp, _ = decodeUtf16(text.items[b..]);
                            const bg = try self.glyph(st.font, bcp);
                            if (gp.attachToBase(@intCast(bg.index), gid)) |o| {
                                attach[i] = .{ .parent = b, .root = b, .dx = o.dx, .dy = o.dy };
                            }
                        }
                        if (attach[i] != null) last_mark = i;
                    };
                } else {
                    base = i;
                    last_mark = null;
                }
                i += cn;
            }
        }

        var err: c_int = 0;
        ubidi_setPara(bidi, text.items.ptr, n, UBIDI_DEFAULT_LTR, null, &err);
        if (err > 0) return error.IcuFailed;
        const levels = try arena.dupe(u8, (ubidi_getLevels(bidi, &err) orelse return error.IcuFailed)[0..text.items.len]);
        if (err > 0) return error.IcuFailed;
        const rtl = ubidi_getParaLevel(bidi) & 1 == 1;

        const brk = ubrk_open(UBRK_LINE, null, text.items.ptr, n, &err) orelse return error.IcuFailed;
        if (err > 0) return error.IcuFailed;
        defer ubrk_close(brk);

        const L = struct {
            r: *Renderer,
            text: []const u16,
            style_of: []const u16,
            styles: []const Style,
            levels: []const u8,
            attach: []const ?Attach,
            rtl: bool,
            avail: f64,
            lines: std.ArrayList(Line) = .empty,

            fn width(l: *@This(), a: usize, b: usize) !f64 {
                return l.r.unitsWidth(l.text, l.style_of, l.styles, a, b);
            }

            fn emit(l: *@This(), a: usize, b: usize) !void {
                try l.lines.append(l.r.arena, try l.r.visualLine(l.text, l.style_of, l.styles, l.levels, l.attach, a, b, l.rtl, l.avail));
            }
        };
        var l: L = .{ .r = self, .text = text.items, .style_of = style_of.items, .styles = styles.items, .levels = levels, .attach = attach, .rtl = rtl, .avail = avail };

        var line_start: usize = 0;
        var cur_w: f64 = 0.0;
        var tok_start: usize = 0;
        while (true) {
            const b = ubrk_next(brk);
            if (b == UBRK_DONE) break;
            const tok_end: usize = @intCast(b);
            const hard = ubrk_getRuleStatus(brk) >= UBRK_LINE_HARD;
            if (is_pre and !hard and tok_end != text.items.len) continue;

            var content_end = tok_end;
            while (content_end > tok_start and isBreakSpace(text.items[content_end - 1])) content_end -= 1;
            const w_trim = try l.width(tok_start, content_end);

            if (line_start < tok_start and cur_w + w_trim > avail) {
                try l.emit(line_start, tok_start);
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
                        if (isHighSurrogate(text.items[fit_end]) and next < content_end) next += 1;
                        const uw = try l.width(fit_end, next);
                        if (fit_end > pos and cur_w + fit_w + uw > avail) break;
                        fit_w += uw;
                        fit_end = next;
                    }
                    if (fit_end == content_end) {
                        cur_w += fit_w;
                        break;
                    }
                    try l.emit(line_start, fit_end);
                    line_start = fit_end;
                    pos = fit_end;
                    cur_w = 0.0;
                }
                cur_w += try l.width(content_end, tok_end);
            } else {
                cur_w += try l.width(tok_start, tok_end);
            }
            if (hard) {
                try l.emit(line_start, tok_end);
                line_start = tok_end;
                cur_w = 0.0;
            }
            tok_start = tok_end;
        }
        if (line_start < text.items.len) {
            try l.emit(line_start, text.items.len);
        }
        return l.lines.items;
    }

    // Logical units [a, b) of one line into visual-order segs. Trailing
    // whitespace hangs; RTL paragraphs flush right. Attached marks are
    // emitted right after their cluster's base whatever the run direction
    // (ubidi reverses them to precede it in RTL runs), positioned relative
    // to the pen after the base.
    fn visualLine(self: *Renderer, text: []const u16, style_of: []const u16, styles: []const Style, levels: []const u8, attach: []const ?Attach, a: usize, b_: usize, rtl: bool, avail: f64) !Line {
        const arena = self.arena;
        var b = b_;
        while (b > a and isBreakSpace(text[b - 1])) b -= 1;
        const len = b - a;
        if (len == 0) return .{ .segs = &.{} };

        const index_map = try arena.alloc(i32, len);
        ubidi_reorderVisual(levels[a..].ptr, @intCast(len), index_map.ptr);

        // Per cluster root, its attached marks in logical order.
        const first_mark = try arena.alloc(?usize, len);
        const next_mark = try arena.alloc(?usize, len);
        const last_mark = try arena.alloc(?usize, len);
        @memset(first_mark, null);
        @memset(next_mark, null);
        @memset(last_mark, null);
        for (a..b) |j| {
            const at = attach[j] orelse continue;
            if (at.root < a) continue;
            const r = at.root - a;
            if (last_mark[r]) |lm| next_mark[lm - a] = j else first_mark[r] = j;
            last_mark[r] = j;
        }
        // Resolved offsets of emitted marks, for stacking.
        const mark_dx = try arena.alloc(f64, len);
        const mark_dy = try arena.alloc(f64, len);

        var segs: std.ArrayList(Seg) = .empty;
        var glyphs: std.ArrayList(Placed) = .empty;
        var cur_style: u16 = 0;
        var cur_odd: bool = false;
        var x: f64 = 0.0;
        var i: usize = 0;
        while (i < len) {
            const j = a + @as(usize, @intCast(index_map[i]));
            if (attach[j] != null and attach[j].?.root >= a) {
                // Drawn with its root.
                i += 1;
                continue;
            }
            var cp: u21 = text[j];
            var consumed: usize = 1;
            if (i + 1 < len) {
                const j2 = a + @as(usize, @intCast(index_map[i + 1]));
                // An RTL run reverses a surrogate pair's halves along with
                // everything else.
                if (isHighSurrogate(text[j]) and isLowSurrogate(text[j2])) {
                    cp = combineSurrogates(text[j], text[j2]);
                    consumed = 2;
                } else if (isLowSurrogate(text[j]) and isHighSurrogate(text[j2])) {
                    cp = combineSurrogates(text[j2], text[j]);
                    consumed = 2;
                }
            }
            const odd = levels[j] & 1 == 1;
            if (odd) cp = @intCast(u_charMirror(cp));
            const si = style_of[j];
            if (glyphs.items.len > 0 and (si != cur_style or odd != cur_odd)) {
                const st = styles[cur_style];
                const visual = try arena.dupe(Placed, glyphs.items);
                const w = try self.cpsWidth(st.font, st.size, visual);
                try segs.append(arena, .{ .glyphs = visual, .style = st, .x = x, .width = w });
                x += w;
                glyphs.clearRetainingCapacity();
            }
            cur_style = si;
            cur_odd = odd;
            try glyphs.append(arena, .{ .cp = cp });

            var m = first_mark[j - a];
            if (m != null) {
                const st = styles[si];
                const f = &self.fonts[@intFromEnum(st.font)];
                const gscale = st.size / @as(f64, @floatFromInt(f.meta.units_per_em));
                const bg = try self.glyph(st.font, cp);
                const base_advance = @as(f64, @floatFromInt(if (bg.advance > 0) bg.advance else f.meta.advance_width_max)) * gscale;
                while (m) |mj| : (m = next_mark[mj - a]) {
                    const at = attach[mj].?;
                    const mcp, _ = decodeUtf16(text[mj..]);
                    var dx = @as(f64, @floatFromInt(at.dx)) * gscale;
                    var dy = @as(f64, @floatFromInt(at.dy)) * gscale;
                    if (at.parent == at.root) {
                        dx -= base_advance;
                    } else {
                        dx += mark_dx[at.parent - a];
                        dy += mark_dy[at.parent - a];
                    }
                    mark_dx[mj - a] = dx;
                    mark_dy[mj - a] = dy;
                    try glyphs.append(arena, .{ .cp = mcp, .dx = dx, .dy = dy, .attached = true });
                }
            }
            i += consumed;
        }
        if (glyphs.items.len > 0) {
            const st = styles[cur_style];
            const visual = try arena.dupe(Placed, glyphs.items);
            const w = try self.cpsWidth(st.font, st.size, visual);
            try segs.append(arena, .{ .glyphs = visual, .style = st, .x = x, .width = w });
            x += w;
        }
        if (rtl and x < avail) {
            for (segs.items) |*seg| seg.x += avail - x;
        }
        return .{ .segs = segs.items };
    }

    // The manual glyph pass z2d's text.show would otherwise do per call.
    // Each unique styled glyph is rasterized once into a small RGBA mask and
    // composited per occurrence; rasterizing glyphs in place made fill cost
    // grow with whole line boxes instead of inked pixels.
    fn drawSeg(self: *Renderer, sfc: *z2d.Surface, paths: *ColorPaths, seg: *const Seg, x: f64, baseline_y: f64, scale: f64) !void {
        const st = seg.style;
        const size = st.size * scale;
        const f = &self.fonts[@intFromEnum(st.font)];
        const gscale = size / @as(f64, @floatFromInt(f.meta.units_per_em));
        var advance: f64 = 0.0;
        var prev: ?z2d.Glyph = null;
        for (seg.glyphs) |pl| {
            const g = try self.glyph(st.font, pl.cp);
            if (!pl.attached) {
                if (prev) |p| {
                    advance += @as(f64, @floatFromInt(try self.kern(st.font, p.index, g.index))) * gscale;
                }
            }
            if (g.outline != .none) {
                var dev_st = st;
                dev_st.size = size;
                // Masks are cached per quarter-pixel phase so letter spacing
                // keeps its fractional advances.
                const exact = x + advance + pl.dx * scale;
                const gx = @floor(exact);
                const phase: u2 = @intFromFloat(@min((exact - gx) * 4.0, 3.0));
                if (try self.mask(dev_st, pl.cp, g, phase)) |m| {
                    const gy: i32 = @intFromFloat(@round(baseline_y - pl.dy * scale));
                    blit(sfc.image_surface_rgb, m, @as(i32, @intFromFloat(gx)) + m.dx, gy + m.dy, st.color);
                }
            }
            if (!pl.attached) {
                advance += @as(f64, @floatFromInt(if (g.advance > 0) g.advance else f.meta.advance_width_max)) * gscale;
                prev = g;
            }
        }

        const w = seg.width * scale;
        if (st.underline) {
            const off = UNDERLINE_OFFSET * size;
            try paths.addRect(st.color, x, @round(baseline_y - off), w, @max(@round(UNDERLINE_SIZE * size), 1.0));
        }
        if (st.strike) {
            const off = STRIKE_OFFSET * size;
            try paths.addRect(st.color, x, @round(baseline_y - off), w, @max(@round(STRIKE_SIZE * size), 1.0));
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
        const f = &self.fonts[@intFromEnum(st.font)];
        const gscale = size / @as(f64, @floatFromInt(f.meta.units_per_em));
        const o = try self.outline(st.font, g);
        const pp1: f64 = if (!f.meta.lsb_is_at_x_zero) @floatFromInt(o.x_min - g.lsb) else 0.0;

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
        var msfc = z2d.Surface.initBuffer(.image_surface_alpha8, null, self.mask_scratch[0 .. bw * bh], box_w, box_h);

        // Shear around the local baseline so the glyph origin stays put.
        const base: z2d.Transformation = if (st.italic)
            .{ .ax = 1, .by = -ITALIC_SHEAR, .cx = 0, .dy = 1, .tx = ITALIC_SHEAR * oy, .ty = 0 }
        else
            .identity;
        var path: z2d.Path = .empty;
        defer path.deinit(self.arena);
        // z2d outlines are pre-flipped by translating -units_per_em, so the
        // draw origin is the top of the em box, one em above the baseline.
        path.transformation = base.translate(ox + pp1, oy - size).scale(gscale, gscale);
        try o.appendToPath(self.arena, &path);

        // An opaque source lets the fill write coverage straight into the
        // mask. painter.fill's allocations are call-scoped, so a fixed
        // buffer serves them; the arena only backs a glyph too big for it.
        const pattern: z2d.Pattern = .{ .opaque_pattern = .{ .pixel = .{ .alpha8 = .{ .a = 255 } } } };
        if (self.fill_scratch.len == 0) {
            self.fill_scratch = try self.arena.alloc(u8, 64 * 1024);
        }
        var fba: std.heap.FixedBufferAllocator = .init(self.fill_scratch);
        z2d.painter.fill(fba.allocator(), &msfc, &pattern, path.nodes.items, .default) catch |err| switch (err) {
            error.OutOfMemory => try z2d.painter.fill(self.arena, &msfc, &pattern, path.nodes.items, .default),
            else => return err,
        };

        const buf = self.mask_scratch[0 .. bw * bh];
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
fn blit(dst: z2d.surface.ImageSurface(z2d.pixel.RGB), m: *const GlyphMask, x: i32, y: i32, color: u32) void {
    const cr: u32 = (color >> 16) & 0xff;
    const cg: u32 = (color >> 8) & 0xff;
    const cb: u32 = color & 0xff;
    const solid: z2d.pixel.RGB = .{ .r = @intCast(cr), .g = @intCast(cg), .b = @intCast(cb) };
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
                px.* = solid;
                continue;
            }
            const inv: u32 = 255 - a;
            px.r = @intCast((cr * a + @as(u32, px.r) * inv + 127) / 255);
            px.g = @intCast((cg * a + @as(u32, px.g) * inv + 127) / 255);
            px.b = @intCast((cb * a + @as(u32, px.b) * inv + 127) / 255);
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

    fn get(self: *ColorPaths, color: u32) !*z2d.Path {
        const gop = try self.map.getOrPut(self.arena, color);
        if (!gop.found_existing) {
            gop.value_ptr.* = .empty;
        }
        return gop.value_ptr;
    }

    fn addRect(self: *ColorPaths, color: u32, x: f64, y: f64, w: f64, h: f64) !void {
        if (w <= 0 or h <= 0) return;
        const path = try self.get(color);
        path.transformation = .identity;
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
            const pattern: z2d.Pattern = .{ .opaque_pattern = .{ .pixel = rgb(entry.key_ptr.*) } };
            try z2d.painter.fill(arena, sfc, &pattern, entry.value_ptr.nodes.items, .default);
        }
    }
};

// z2d's own PNG export converts pixel-by-pixel through the Surface
// interface and compresses with std.flate; encoding straight off the raw RGB
// buffer through the zlib the binary already links (a curl dependency) is an
// order of magnitude faster. Level mirrors the size tradeoff the Rust
// renderer measured: output is mostly base64'd over CDP so size matters, but
// higher levels are severalfold slower for a few percent smaller.
const ZStream = extern struct {
    next_in: ?[*]const u8 = null,
    avail_in: c_uint = 0,
    total_in: c_ulong = 0,
    next_out: ?[*]u8 = null,
    avail_out: c_uint = 0,
    total_out: c_ulong = 0,
    msg: ?[*:0]const u8 = null,
    state: ?*anyopaque = null,
    zalloc: ?*const fn (?*anyopaque, c_uint, c_uint) callconv(.c) ?*anyopaque = null,
    zfree: ?*const fn (?*anyopaque, ?*anyopaque) callconv(.c) void = null,
    @"opaque": ?*anyopaque = null,
    data_type: c_int = 0,
    adler: c_ulong = 0,
    reserved: c_ulong = 0,
};

const Z_OK: c_int = 0;
const Z_STREAM_END: c_int = 1;
const Z_NO_FLUSH: c_int = 0;
const Z_FINISH: c_int = 4;

extern fn deflateInit_(strm: *ZStream, level: c_int, version: [*:0]const u8, stream_size: c_int) c_int;
extern fn deflate(strm: *ZStream, flush: c_int) c_int;
extern fn deflateEnd(strm: *ZStream) c_int;

fn writePng(arena: Allocator, sfc: *const z2d.Surface, writer: *std.Io.Writer) !void {
    const w: usize = @intCast(sfc.getWidth());
    const h: usize = @intCast(sfc.getHeight());
    const buf = sfc.image_surface_rgb.buf;

    try writer.writeAll("\x89PNG\r\n\x1a\n");
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], @intCast(w), .big);
    std.mem.writeInt(u32, ihdr[4..8], @intCast(h), .big);
    ihdr[8] = 8; // bit depth
    ihdr[9] = 2; // truecolor
    ihdr[10] = 0; // deflate
    ihdr[11] = 0; // filter method
    ihdr[12] = 0; // no interlace
    try writeChunk(writer, "IHDR", &ihdr);

    // Streamed one scanline in, one IDAT chunk out per 64KB of deflate
    // output, so a capped-height capture never holds a second copy of the
    // raster.
    var zs: ZStream = .{};
    if (deflateInit_(&zs, 2, "1", @sizeOf(ZStream)) != Z_OK) {
        return error.EncodeFailed;
    }
    defer _ = deflateEnd(&zs);

    // Leading no-filter byte per scanline. Text pages are dominated by long
    // solid runs, which deflate handles well without filtering.
    const row = try arena.alloc(u8, w * 3 + 1);
    row[0] = 0;
    const out = try arena.alloc(u8, 1 << 16);
    zs.next_out = out.ptr;
    zs.avail_out = @intCast(out.len);

    for (0..h) |y| {
        for (buf[y * w ..][0..w], 0..) |px, x| {
            row[1 + x * 3] = px.r;
            row[2 + x * 3] = px.g;
            row[3 + x * 3] = px.b;
        }
        zs.next_in = row.ptr;
        zs.avail_in = @intCast(row.len);
        while (zs.avail_in > 0) {
            if (deflate(&zs, Z_NO_FLUSH) != Z_OK) {
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
        const rc = deflate(&zs, Z_FINISH);
        if (rc != Z_OK and rc != Z_STREAM_END) {
            return error.EncodeFailed;
        }
        const produced = out.len - zs.avail_out;
        if (produced > 0) {
            try writeChunk(writer, "IDAT", out[0..produced]);
            zs.next_out = out.ptr;
            zs.avail_out = @intCast(out.len);
        }
        if (rc == Z_STREAM_END) break;
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

fn appendUtf16(arena: Allocator, out: *std.ArrayList(u16), utf8: []const u8) !void {
    var it = std.unicode.Utf8View.initUnchecked(utf8).iterator();
    while (it.nextCodepoint()) |cp| {
        if (cp < 0x10000) {
            try out.append(arena, @intCast(cp));
        } else {
            const v = cp - 0x10000;
            try out.append(arena, @intCast(0xD800 + (v >> 10)));
            try out.append(arena, @intCast(0xDC00 + (v & 0x3FF)));
        }
    }
}

// A mark's GPOS anchor offset (font units) to its parent: the cluster's
// base, or the previous attached mark when stacking.
const Attach = struct {
    parent: usize,
    root: usize,
    dx: i16,
    dy: i16,
};

fn utf8ToPlaced(arena: Allocator, utf8: []const u8) ![]const Placed {
    var out: std.ArrayList(Placed) = .empty;
    var it = std.unicode.Utf8View.initUnchecked(utf8).iterator();
    while (it.nextCodepoint()) |cp| try out.append(arena, .{ .cp = cp });
    return out.items;
}

fn isHighSurrogate(u: u16) bool {
    return u >= 0xD800 and u <= 0xDBFF;
}

fn isLowSurrogate(u: u16) bool {
    return u >= 0xDC00 and u <= 0xDFFF;
}

fn combineSurrogates(hi: u16, lo: u16) u21 {
    return 0x10000 + ((@as(u21, hi) - 0xD800) << 10) + (@as(u21, lo) - 0xDC00);
}

// (codepoint, units consumed) at the start of `units`.
fn decodeUtf16(units: []const u16) struct { u21, usize } {
    if (units.len >= 2 and isHighSurrogate(units[0]) and isLowSurrogate(units[1])) {
        return .{ combineSurrogates(units[0], units[1]), 2 };
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

fn rgb(color: u32) z2d.Pixel {
    return .{ .rgb = .{
        .r = @intCast((color >> 16) & 0xff),
        .g = @intCast((color >> 8) & 0xff),
        .b = @intCast(color & 0xff),
    } };
}
