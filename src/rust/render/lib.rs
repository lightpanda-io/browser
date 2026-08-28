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
//! dump produces — set with parley (line breaking, shaping, bidi), outlined
//! with skrifa and filled by tiny-skia. Fonts are bundled so output doesn't
//! depend on the host.

use std::borrow::Cow;
use std::collections::HashMap;
use std::os::raw::c_void;

use fontique::{Blob, Collection, CollectionOptions, GenericFamily, SourceCache};
use parley::{
    Alignment, AlignmentOptions, FontContext, FontFamily, FontStyle, FontWeight, GlyphRun, Layout,
    LayoutContext, LineHeight, OverflowWrap, PositionedLayoutItem, StyleProperty, TextStyle,
    WhiteSpaceCollapse,
};
use skrifa::instance::{LocationRef, Size};
use skrifa::outline::{DrawSettings, OutlinePen};
use skrifa::{GlyphId, MetadataProvider};
use tiny_skia::{Color, FillRule, IntRect, Paint, PathBuilder, Pixmap, Rect, Transform};

// ---------------------------------------------------------------------------
// C ABI — mirrored by src/browser/screenshot.zig.

pub const SPAN_BOLD: u32 = 1 << 0;
pub const SPAN_ITALIC: u32 = 1 << 1;
pub const SPAN_UNDERLINE: u32 = 1 << 2;
pub const SPAN_MONO: u32 = 1 << 3;
pub const SPAN_STRIKE: u32 = 1 << 4;
/// `color` holds 0xRRGGBB when set.
pub const SPAN_HAS_COLOR: u32 = 1 << 5;

/// Block kinds; 0 is a paragraph. `level` is 1..=6 for headings.
pub const BLOCK_HEADING: u8 = 1;
/// Whitespace preserved, monospace.
pub const BLOCK_PRE: u8 = 2;
/// Horizontal rule; no spans.
pub const BLOCK_RULE: u8 = 3;

/// List-like vertical spacing (standalone links, nav bars).
pub const BLOCK_TIGHT: u8 = 1 << 0;

pub const RENDER_MEASURE_ONLY: u32 = 1 << 0;

#[repr(C)]
pub struct LpSpan {
    pub text: *const u8,
    pub len: usize,
    pub flags: u32,
    pub color: u32,
}

#[repr(C)]
pub struct LpBlock {
    pub spans: *const LpSpan,
    pub spans_len: usize,
    /// List marker ("•", "3.") drawn in the gutter of the first line; empty
    /// for none.
    pub marker: *const u8,
    pub marker_len: usize,
    pub kind: u8,
    pub level: u8,
    pub list_depth: u8,
    pub quote_depth: u8,
    pub flags: u8,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct LpRenderOpts {
    /// Layout width in CSS px.
    pub width: u32,
    /// Output height in CSS px; 0 = content height (full page).
    pub height: u32,
    /// Crop rectangle in CSS px; clip_w == 0 means no crop.
    pub clip_x: f32,
    pub clip_y: f32,
    pub clip_w: f32,
    pub clip_h: f32,
    /// Device pixel ratio.
    pub scale: f32,
    pub flags: u32,
}

pub type LpWriteFn = extern "C" fn(ctx: *mut c_void, data: *const u8, len: usize) -> bool;

/// Return codes. Anything but OK means nothing usable reached `write`, so a
/// caller must not treat what it received as a PNG.
pub const RC_OK: i32 = 0;
pub const RC_WRITE_REFUSED: i32 = 1;
pub const RC_INVALID: i32 = 2;
/// The pixmap could not be allocated, even after the MAX_RASTER_* clamps.
pub const RC_NO_RASTER: i32 = 3;
pub const RC_ENCODE_FAILED: i32 = 4;
pub const RC_PANIC: i32 = 5;

/// Self-description of the ABI above, so screenshot.zig can check its
/// hand-written mirror. `size` is `size_of::<LpAbi>()` and is compared first:
/// it catches a field added to only one side of this struct itself.
#[repr(C)]
pub struct LpAbi {
    pub size: u32,

    pub span_size: u32,
    pub span_align: u32,
    pub span_text: u32,
    pub span_len: u32,
    pub span_flags: u32,
    pub span_color: u32,

    pub block_size: u32,
    pub block_align: u32,
    pub block_spans: u32,
    pub block_spans_len: u32,
    pub block_marker: u32,
    pub block_marker_len: u32,
    pub block_kind: u32,
    pub block_level: u32,
    pub block_list_depth: u32,
    pub block_quote_depth: u32,
    pub block_flags: u32,

    pub opts_size: u32,
    pub opts_align: u32,
    pub opts_width: u32,
    pub opts_height: u32,
    pub opts_clip_x: u32,
    pub opts_clip_y: u32,
    pub opts_clip_w: u32,
    pub opts_clip_h: u32,
    pub opts_scale: u32,
    pub opts_flags: u32,

    pub span_bold: u32,
    pub span_italic: u32,
    pub span_underline: u32,
    pub span_mono: u32,
    pub span_strike: u32,
    pub span_has_color: u32,

    pub block_heading: u32,
    pub block_pre: u32,
    pub block_rule: u32,
    pub block_tight: u32,

    pub render_measure_only: u32,

    pub rc_ok: u32,
    pub rc_write_refused: u32,
    pub rc_invalid: u32,
    pub rc_no_raster: u32,
    pub rc_encode_failed: u32,
    pub rc_panic: u32,
}

#[no_mangle]
pub unsafe extern "C" fn lp_render_abi(out: *mut LpAbi) {
    use std::mem::{align_of, offset_of, size_of};
    *out = LpAbi {
        size: size_of::<LpAbi>() as u32,

        span_size: size_of::<LpSpan>() as u32,
        span_align: align_of::<LpSpan>() as u32,
        span_text: offset_of!(LpSpan, text) as u32,
        span_len: offset_of!(LpSpan, len) as u32,
        span_flags: offset_of!(LpSpan, flags) as u32,
        span_color: offset_of!(LpSpan, color) as u32,

        block_size: size_of::<LpBlock>() as u32,
        block_align: align_of::<LpBlock>() as u32,
        block_spans: offset_of!(LpBlock, spans) as u32,
        block_spans_len: offset_of!(LpBlock, spans_len) as u32,
        block_marker: offset_of!(LpBlock, marker) as u32,
        block_marker_len: offset_of!(LpBlock, marker_len) as u32,
        block_kind: offset_of!(LpBlock, kind) as u32,
        block_level: offset_of!(LpBlock, level) as u32,
        block_list_depth: offset_of!(LpBlock, list_depth) as u32,
        block_quote_depth: offset_of!(LpBlock, quote_depth) as u32,
        block_flags: offset_of!(LpBlock, flags) as u32,

        opts_size: size_of::<LpRenderOpts>() as u32,
        opts_align: align_of::<LpRenderOpts>() as u32,
        opts_width: offset_of!(LpRenderOpts, width) as u32,
        opts_height: offset_of!(LpRenderOpts, height) as u32,
        opts_clip_x: offset_of!(LpRenderOpts, clip_x) as u32,
        opts_clip_y: offset_of!(LpRenderOpts, clip_y) as u32,
        opts_clip_w: offset_of!(LpRenderOpts, clip_w) as u32,
        opts_clip_h: offset_of!(LpRenderOpts, clip_h) as u32,
        opts_scale: offset_of!(LpRenderOpts, scale) as u32,
        opts_flags: offset_of!(LpRenderOpts, flags) as u32,

        span_bold: SPAN_BOLD,
        span_italic: SPAN_ITALIC,
        span_underline: SPAN_UNDERLINE,
        span_mono: SPAN_MONO,
        span_strike: SPAN_STRIKE,
        span_has_color: SPAN_HAS_COLOR,

        block_heading: BLOCK_HEADING as u32,
        block_pre: BLOCK_PRE as u32,
        block_rule: BLOCK_RULE as u32,
        block_tight: BLOCK_TIGHT as u32,

        render_measure_only: RENDER_MEASURE_ONLY,

        rc_ok: RC_OK as u32,
        rc_write_refused: RC_WRITE_REFUSED as u32,
        rc_invalid: RC_INVALID as u32,
        rc_no_raster: RC_NO_RASTER as u32,
        rc_encode_failed: RC_ENCODE_FAILED as u32,
        rc_panic: RC_PANIC as u32,
    };
}

/// A renderer: parsed fonts, shaping scratch and the glyph cache. Not
/// thread-safe; the caller drives each handle from one thread at a time.
/// Null on panic (font registration is the only thing in there that could).
#[no_mangle]
pub extern "C" fn lp_render_new() -> *mut Renderer {
    match std::panic::catch_unwind(Renderer::new) {
        Ok(r) => Box::into_raw(Box::new(r)),
        Err(_) => std::ptr::null_mut(),
    }
}

#[no_mangle]
pub unsafe extern "C" fn lp_render_free(r: *mut Renderer) {
    drop(Box::from_raw(r));
}

/// Renders `blocks` to PNG, streaming the encoded bytes to `write`.
/// `content_height` receives the full-page height in CSS px, and is filled in
/// even when rendering fails. Returns one of the RC_* codes above. The
/// renderer stays usable after RC_PANIC: layout state is scratch that the
/// next call resets.
#[no_mangle]
pub unsafe extern "C" fn lp_render_png(
    r: *mut Renderer,
    blocks: *const LpBlock,
    blocks_len: usize,
    opts: LpRenderOpts,
    content_height: *mut u32,
    ctx: *mut c_void,
    write: LpWriteFn,
) -> i32 {
    let caught = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        render_png(
            &mut *r,
            blocks,
            blocks_len,
            opts,
            content_height,
            ctx,
            write,
        )
    }));
    caught.unwrap_or(RC_PANIC)
}

unsafe fn render_png(
    r: &mut Renderer,
    blocks: *const LpBlock,
    blocks_len: usize,
    opts: LpRenderOpts,
    content_height: *mut u32,
    ctx: *mut c_void,
    write: LpWriteFn,
) -> i32 {
    if opts.width == 0 || !(opts.scale > 0.0) || opts.scale > 8.0 {
        return RC_INVALID;
    }
    let blocks = if blocks_len == 0 {
        &[][..]
    } else {
        std::slice::from_raw_parts(blocks, blocks_len)
    };
    let mut doc: Vec<Block> = Vec::with_capacity(blocks_len);
    for b in blocks {
        let spans = if b.spans_len == 0 {
            &[][..]
        } else {
            std::slice::from_raw_parts(b.spans, b.spans_len)
        };
        let mut out_spans = Vec::with_capacity(spans.len());
        for s in spans {
            let bytes = std::slice::from_raw_parts(s.text, s.len);
            let Ok(text) = std::str::from_utf8(bytes) else {
                return RC_INVALID;
            };
            out_spans.push(Span {
                text,
                flags: s.flags,
                color: s.color,
            });
        }
        let marker =
            std::str::from_utf8(std::slice::from_raw_parts(b.marker, b.marker_len)).unwrap_or("");
        doc.push(Block {
            kind: b.kind,
            level: b.level,
            list_depth: b.list_depth,
            quote_depth: b.quote_depth,
            flags: b.flags,
            marker,
            spans: out_spans,
        });
    }

    let mut sink = Sink {
        ctx,
        write,
        failed: false,
    };
    let (h, rc) = r.render(&doc, opts, &mut sink);
    if !content_height.is_null() {
        *content_height = h;
    }
    // A refused write surfaces as an encode failure too; report the cause.
    if sink.failed {
        RC_WRITE_REFUSED
    } else {
        rc
    }
}

struct Sink {
    ctx: *mut c_void,
    write: LpWriteFn,
    failed: bool,
}

impl std::io::Write for Sink {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        if self.failed || !(self.write)(self.ctx, buf.as_ptr(), buf.len()) {
            self.failed = true;
            return Err(std::io::ErrorKind::Other.into());
        }
        Ok(buf.len())
    }
    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

// ---------------------------------------------------------------------------

struct Span<'a> {
    text: &'a str,
    flags: u32,
    color: u32,
}

struct Block<'a> {
    kind: u8,
    level: u8,
    list_depth: u8,
    quote_depth: u8,
    flags: u8,
    marker: &'a str,
    spans: Vec<Span<'a>>,
}

#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug, Default)]
struct Rgb(u8, u8, u8);

const BASE_SIZE: f32 = 16.0;
const PAGE_MARGIN: f32 = 16.0;
const LIST_INDENT: f32 = 24.0;
const QUOTE_INDENT: f32 = 20.0;
const PRE_PAD: f32 = 8.0;
const TEXT_COLOR: Rgb = Rgb(0x1f, 0x1f, 0x1f);
const RULE_COLOR: Rgb = Rgb(0xcc, 0xcc, 0xcc);
const PRE_BG: Rgb = Rgb(0xf4, 0xf4, 0xf4);
/// Device pixels per side. Chrome's own full-page captures top out around here.
const MAX_RASTER_DIM: u64 = 16384;
/// Device pixels in total, 4 bytes each: a 256MB ceiling on the pixmap. A 4K
/// viewport captured full-page at 2x still fits.
const MAX_RASTER_PIXELS: u64 = 64 << 20;

/// (font, glyph id). Deliberately not the size — see draw_glyph_run.
type GlyphKey = (usize, u32);

pub struct Renderer {
    fcx: FontContext,
    lcx: LayoutContext<Rgb>,
    glyph_cache: HashMap<GlyphKey, Option<tiny_skia::Path>>,
}

struct Placed {
    layout: Layout<Rgb>,
    x: f32,
    y: f32,
    kind: u8,
    marker: Option<(Layout<Rgb>, f32)>,
    quote_bars: u8,
    quote_x: f32,
}

/// (font_size, weight, space_before, space_after, line_height)
fn block_metrics(b: &Block) -> (f32, FontWeight, f32, f32, f32) {
    match b.kind {
        BLOCK_HEADING => {
            let s = match b.level {
                1 => 2.0,
                2 => 1.5,
                3 => 1.25,
                4 => 1.1,
                _ => 1.0,
            };
            (BASE_SIZE * s, FontWeight::BOLD, 20.0, 10.0, 1.25)
        }
        BLOCK_PRE => (BASE_SIZE * 0.875, FontWeight::NORMAL, 12.0, 12.0, 1.4),
        BLOCK_RULE => (0.0, FontWeight::NORMAL, 12.0, 12.0, 1.0),
        _ => {
            let tight = b.list_depth > 0 || b.flags & BLOCK_TIGHT != 0;
            let (before, after) = if tight { (4.0, 4.0) } else { (12.0, 12.0) };
            (BASE_SIZE, FontWeight::NORMAL, before, after, 1.4)
        }
    }
}

impl Renderer {
    fn new() -> Self {
        let mut collection = Collection::new(CollectionOptions {
            shared: false,
            system_fonts: false,
        });
        let sans = Self::register(&mut collection, include_bytes!("fonts/DejaVuSans.ttf"));
        Self::register(&mut collection, include_bytes!("fonts/DejaVuSans-Bold.ttf"));
        let mono = Self::register(&mut collection, include_bytes!("fonts/DejaVuSansMono.ttf"));
        Self::register(
            &mut collection,
            include_bytes!("fonts/DejaVuSansMono-Bold.ttf"),
        );
        for generic in [
            GenericFamily::SansSerif,
            GenericFamily::Serif,
            GenericFamily::SystemUi,
            GenericFamily::Cursive,
            GenericFamily::Fantasy,
        ] {
            collection.set_generic_families(generic, [sans].into_iter());
        }
        collection.set_generic_families(GenericFamily::Monospace, [mono].into_iter());
        Self {
            fcx: FontContext {
                collection,
                source_cache: SourceCache::default(),
            },
            lcx: LayoutContext::new(),
            glyph_cache: HashMap::new(),
        }
    }

    fn register(collection: &mut Collection, bytes: &'static [u8]) -> fontique::FamilyId {
        let fams = collection.register_fonts(Blob::new(std::sync::Arc::new(bytes)), None);
        fams[0].0
    }

    /// Returns the content height in CSS px, and RC_OK only if a complete
    /// PNG reached `sink`.
    fn render(&mut self, blocks: &[Block], opts: LpRenderOpts, sink: &mut Sink) -> (u32, i32) {
        let scale = opts.scale;
        let content_w = (opts.width as f32 - 2.0 * PAGE_MARGIN).max(1.0);
        let mut y = PAGE_MARGIN;
        let mut placed: Vec<Placed> = Vec::with_capacity(blocks.len());
        let mut prev_after: Option<f32> = None;

        for block in blocks {
            let (size, weight, before, after, line_h) = block_metrics(block);
            y += match prev_after {
                None => 0.0,
                Some(pa) => pa.max(before),
            };
            prev_after = Some(after);

            let indent =
                block.list_depth as f32 * LIST_INDENT + block.quote_depth as f32 * QUOTE_INDENT;
            let quote_x = PAGE_MARGIN + block.list_depth as f32 * LIST_INDENT;

            if block.kind == BLOCK_RULE {
                placed.push(Placed {
                    layout: Layout::new(),
                    x: PAGE_MARGIN + indent,
                    y,
                    kind: BLOCK_RULE,
                    marker: None,
                    quote_bars: 0,
                    quote_x,
                });
                y += 1.0;
                continue;
            }

            let is_pre = block.kind == BLOCK_PRE;
            let root = TextStyle {
                font_family: FontFamily::Source(Cow::Borrowed(if is_pre {
                    "monospace"
                } else {
                    "sans-serif"
                })),
                font_size: size,
                font_weight: weight,
                brush: TEXT_COLOR,
                line_height: LineHeight::FontSizeRelative(line_h),
                overflow_wrap: OverflowWrap::Anywhere,
                ..Default::default()
            };
            let mut builder = self.lcx.tree_builder(&mut self.fcx, scale, true, &root);
            // The Zig walker already collapsed whitespace; preserving lets
            // "\n" (from <br> and <pre>) act as a hard break.
            builder.set_white_space_mode(WhiteSpaceCollapse::Preserve);
            let mut props: Vec<StyleProperty<Rgb>> = Vec::with_capacity(6);
            for span in &block.spans {
                props.clear();
                if span.flags & SPAN_BOLD != 0 {
                    props.push(StyleProperty::FontWeight(FontWeight::BOLD));
                }
                if span.flags & SPAN_ITALIC != 0 {
                    props.push(StyleProperty::FontStyle(FontStyle::Italic));
                }
                if span.flags & SPAN_UNDERLINE != 0 {
                    props.push(StyleProperty::Underline(true));
                }
                if span.flags & SPAN_STRIKE != 0 {
                    props.push(StyleProperty::Strikethrough(true));
                }
                if span.flags & SPAN_MONO != 0 && !is_pre {
                    props.push(StyleProperty::FontFamily(FontFamily::Source(
                        Cow::Borrowed("monospace"),
                    )));
                    props.push(StyleProperty::FontSize(size * 0.9));
                }
                if span.flags & SPAN_HAS_COLOR != 0 {
                    let c = Rgb(
                        (span.color >> 16) as u8,
                        (span.color >> 8) as u8,
                        span.color as u8,
                    );
                    props.push(StyleProperty::Brush(c));
                    props.push(StyleProperty::UnderlineBrush(Some(c)));
                    props.push(StyleProperty::StrikethroughBrush(Some(c)));
                }
                builder.push_style_modification_span(&props);
                builder.push_text(span.text);
                builder.pop_style_span();
            }
            let (mut layout, _) = builder.build();
            let pad = if is_pre { PRE_PAD } else { 0.0 };
            layout.break_all_lines(Some(((content_w - indent - 2.0 * pad) * scale).max(1.0)));
            layout.align(Alignment::Start, AlignmentOptions::default());

            let marker = if block.marker.is_empty() {
                None
            } else {
                let mut b = self
                    .lcx
                    .ranged_builder(&mut self.fcx, block.marker, scale, true);
                b.push_default(StyleProperty::FontSize(BASE_SIZE));
                b.push_default(StyleProperty::Brush(TEXT_COLOR));
                let mut ml = b.build(block.marker);
                ml.break_all_lines(None);
                let mx = (PAGE_MARGIN + indent) * scale - ml.width() - 6.0 * scale;
                Some((ml, mx))
            };

            let h = layout.height() / scale;
            placed.push(Placed {
                layout,
                x: PAGE_MARGIN + indent + pad,
                y: y + pad,
                kind: block.kind,
                marker,
                quote_bars: block.quote_depth,
                quote_x,
            });
            y += h + 2.0 * pad;
        }
        y += PAGE_MARGIN;
        let content_h = y.ceil().max(1.0) as u32;
        if opts.flags & RENDER_MEASURE_ONLY != 0 {
            return (content_h, RC_OK);
        }

        // Rasterize the requested strip (viewport or full page), then crop.
        // A clip reaching past the strip extends it, but never past the
        // content.
        let mut out_h = if opts.height == 0 {
            content_h
        } else {
            opts.height
        };
        if opts.clip_w > 0.0 {
            let reach = (opts.clip_y as f64 + opts.clip_h as f64).ceil();
            // A NaN reach clamps to NaN and casts to 0, leaving out_h alone.
            out_h = out_h.max(reach.clamp(0.0, content_h as f64) as u32);
        }
        let pw = ((opts.width as f64 * scale as f64).ceil() as u64).clamp(1, MAX_RASTER_DIM);
        let ph = ((out_h as f64 * scale as f64).ceil() as u64)
            .clamp(1, MAX_RASTER_DIM)
            .min((MAX_RASTER_PIXELS / pw).max(1));
        let (pw, ph) = (pw as u32, ph as u32);
        let Some(mut pixmap) = Pixmap::new(pw, ph) else {
            return (content_h, RC_NO_RASTER);
        };
        pixmap.fill(Color::WHITE);

        let mut paint = Paint::default();
        paint.anti_alias = true;
        for p in &placed {
            let oy = p.y * scale;
            if oy > ph as f32 {
                break;
            }
            match p.kind {
                BLOCK_RULE => {
                    paint.set_color_rgba8(RULE_COLOR.0, RULE_COLOR.1, RULE_COLOR.2, 255);
                    let w = (opts.width as f32 - PAGE_MARGIN) * scale - p.x * scale;
                    if let Some(r) = Rect::from_xywh(p.x * scale, oy, w, 1.0 * scale) {
                        pixmap.fill_rect(r, &paint, Transform::identity(), None);
                    }
                    continue;
                }
                BLOCK_PRE => {
                    paint.set_color_rgba8(PRE_BG.0, PRE_BG.1, PRE_BG.2, 255);
                    let x0 = (p.x - PRE_PAD) * scale;
                    let w = (opts.width as f32 - PAGE_MARGIN) * scale - x0;
                    if let Some(r) = Rect::from_xywh(
                        x0,
                        oy - PRE_PAD * scale,
                        w,
                        p.layout.height() + 2.0 * PRE_PAD * scale,
                    ) {
                        pixmap.fill_rect(r, &paint, Transform::identity(), None);
                    }
                }
                _ => {}
            }
            for i in 0..p.quote_bars {
                paint.set_color_rgba8(RULE_COLOR.0, RULE_COLOR.1, RULE_COLOR.2, 255);
                let bx = (p.quote_x + i as f32 * QUOTE_INDENT) * scale;
                if let Some(r) = Rect::from_xywh(bx, oy, 3.0 * scale, p.layout.height()) {
                    pixmap.fill_rect(r, &paint, Transform::identity(), None);
                }
            }
            if let Some((ml, mx)) = &p.marker {
                self.draw_layout(&mut pixmap, ml, *mx, oy);
            }
            self.draw_layout(&mut pixmap, &p.layout, p.x * scale, oy);
        }

        let cropped;
        let view = if opts.clip_w > 0.0 {
            let x = ((opts.clip_x * scale).floor().max(0.0) as u32).min(pw - 1);
            let y = ((opts.clip_y * scale).floor().max(0.0) as u32).min(ph - 1);
            let w = ((opts.clip_w * scale).ceil().max(1.0) as u32).min(pw - x);
            let h = ((opts.clip_h * scale).ceil().max(1.0) as u32).min(ph - y);
            match IntRect::from_xywh(x as i32, y as i32, w, h).and_then(|r| pixmap.clone_rect(r)) {
                Some(c) => {
                    cropped = c;
                    &cropped
                }
                None => &pixmap,
            }
        } else {
            &pixmap
        };

        // Everything is opaque on an opaque background, so the premultiplied
        // buffer is already straight RGBA (and RGB would save only ~3%).
        let mut enc = png::Encoder::new(&mut *sink, view.width(), view.height());
        enc.set_color(png::ColorType::Rgba);
        enc.set_depth(png::BitDepth::Eight);
        // Measured on text pages: fdeflate "Fast" is 3-8x larger than this,
        // level 6 is only ~5% smaller and 4x slower. Output is mostly
        // base64'd over CDP, so size matters.
        enc.set_deflate_compression(png::DeflateCompression::Level(2));
        enc.set_filter(png::Filter::Adaptive);
        let encoded = (|| -> Result<(), png::EncodingError> {
            let mut w = enc.write_header()?;
            w.write_image_data(view.data())?;
            w.finish()
        })();
        (
            content_h,
            if encoded.is_ok() {
                RC_OK
            } else {
                RC_ENCODE_FAILED
            },
        )
    }

    fn draw_layout(&mut self, pixmap: &mut Pixmap, layout: &Layout<Rgb>, ox: f32, oy: f32) {
        for line in layout.lines() {
            for item in line.items() {
                if let PositionedLayoutItem::GlyphRun(gr) = item {
                    self.draw_glyph_run(pixmap, &gr, ox, oy);
                }
            }
        }
    }

    fn draw_glyph_run(&mut self, pixmap: &mut Pixmap, gr: &GlyphRun<Rgb>, ox: f32, oy: f32) {
        let run = gr.run();
        let font = run.font();
        let font_size = run.font_size();
        let synth = run.synthesis();
        let Ok(font_ref) = skrifa::FontRef::from_index(font.data.as_ref(), font.index) else {
            return;
        };
        let outlines = font_ref.outline_glyphs();
        let font_key = font.data.as_ref().as_ptr() as usize ^ (font.index as usize);
        // Outlines are cached in font units, not at the drawn size: font_size
        // is the CSS size times a client-controlled scale, so keying on it let
        // a caller mint a fresh copy of every glyph on every call, retained
        // for the life of the process. Unhinted scaling is linear, so folding
        // it into the transform below is equivalent and bounds the cache at
        // (fonts x glyphs).
        let upem = font_ref
            .metrics(Size::unscaled(), LocationRef::default())
            .units_per_em as f32;
        if !(upem > 0.0) {
            return;
        }
        let scale = font_size / upem;

        let style = gr.style();
        let mut paint = Paint::default();
        paint.anti_alias = true;
        paint.set_color_rgba8(style.brush.0, style.brush.1, style.brush.2, 255);

        let baseline = oy + gr.baseline();
        let mut x = ox + gr.offset();
        let skew = synth
            .skew()
            .map(|deg| deg.to_radians().tan())
            .unwrap_or(0.0);
        for glyph in gr.glyphs() {
            let gx = x + glyph.x;
            let gy = baseline - glyph.y;
            x += glyph.advance;
            let path = self
                .glyph_cache
                .entry((font_key, glyph.id))
                .or_insert_with(|| {
                    let og = outlines.get(GlyphId::new(glyph.id))?;
                    let mut pen = TinyPen(PathBuilder::new());
                    og.draw(
                        DrawSettings::unhinted(Size::unscaled(), LocationRef::default()),
                        &mut pen,
                    )
                    .ok()?;
                    pen.0.finish()
                });
            if let Some(path) = path {
                // Outlines are y-up and in font units; scale and flip them
                // onto the pixmap.
                let t = Transform::from_row(scale, 0.0, skew * scale, -scale, gx, gy);
                pixmap.fill_path(path, &paint, FillRule::Winding, t, None);
            }
        }

        let m = run.metrics();
        let x0 = ox + gr.offset();
        for (deco, default_off, default_size) in [
            (&style.underline, m.underline_offset, m.underline_size),
            (
                &style.strikethrough,
                m.strikethrough_offset,
                m.strikethrough_size,
            ),
        ] {
            let Some(d) = deco else { continue };
            let off = d.offset.unwrap_or(default_off);
            let sz = d.size.unwrap_or(default_size).max(1.0);
            let mut p2 = Paint::default();
            p2.set_color_rgba8(d.brush.0, d.brush.1, d.brush.2, 255);
            if let Some(r) = Rect::from_xywh(x0, (baseline - off).round(), gr.advance(), sz.round())
            {
                pixmap.fill_rect(r, &p2, Transform::identity(), None);
            }
        }
    }
}

struct TinyPen(PathBuilder);

impl OutlinePen for TinyPen {
    fn move_to(&mut self, x: f32, y: f32) {
        self.0.move_to(x, y);
    }
    fn line_to(&mut self, x: f32, y: f32) {
        self.0.line_to(x, y);
    }
    fn quad_to(&mut self, cx0: f32, cy0: f32, x: f32, y: f32) {
        self.0.quad_to(cx0, cy0, x, y);
    }
    fn curve_to(&mut self, cx0: f32, cy0: f32, cx1: f32, cy1: f32, x: f32, y: f32) {
        self.0.cubic_to(cx0, cy0, cx1, cy1, x, y);
    }
    fn close(&mut self) {
        self.0.close();
    }
}
