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

// PDF output for the block model, behind `Page.printToPDF` and `--dump pdf`.
// The screenshot's DOM walk and parley layout (exported by the Rust side as
// positioned glyph runs), paginated at line boundaries and written as real
// text: glyph ids through a Type0/Identity-H font over an embedded subset of
// the bundled DejaVu faces, a ToUnicode map so the text selects, copies and
// searches, and a link annotation over every <a href>. The file is written
// by hand: the objects below are all a text-only page needs.

const std = @import("std");
const lp = @import("lightpanda");

const Base64Writer = @import("../Base64Writer.zig");

const Frame = @import("Frame.zig");
const screenshot = @import("screenshot.zig");

const Node = @import("webapi/Node.zig");

const log = lp.log;
const flate = std.compress.flate;
const Allocator = std.mem.Allocator;

/// Print options. Lengths are CSS px (96 per inch); the defaults are
/// Chrome's: US Letter with 0.4in margins.
pub const Opts = struct {
    paper_width: f32 = 8.5 * 96,
    paper_height: f32 = 11 * 96,
    margin_top: f32 = 0.4 * 96,
    margin_right: f32 = 0.4 * 96,
    margin_bottom: f32 = 0.4 * 96,
    margin_left: f32 = 0.4 * 96,
    /// Content scale, 0.1 to 2.
    scale: f32 = 1.0,
    print_background: bool = false,
    /// Pages to print; empty prints everything. Pages come out in document
    /// order, once each; pages past the end are ignored, and a selection
    /// that ends up empty is an error. `parsePageRanges` reads CDP's text
    /// form.
    page_ranges: []const PageRange = &.{},
};

/// 1-based, inclusive. `to = maxInt(u32)` for an open end ("5-").
pub const PageRange = struct {
    from: u32,
    to: u32,
};

/// CDP's `pageRanges` grammar ("1-5, 8, 11-13"): comma-separated pages or
/// spans, whitespace ignored around each number, either end of a span may
/// be left open. Same two failure classes as Chrome: unparsable text, or a
/// range that is empty by construction (page 0, start past end).
pub fn parsePageRanges(arena: Allocator, text: []const u8) error{ InvalidPageRangeSyntax, InvalidPageRange, OutOfMemory }![]const PageRange {
    var out: std.ArrayList(PageRange) = .empty;
    var it = std.mem.splitScalar(u8, text, ',');
    while (it.next()) |raw| {
        const part = std.mem.trim(u8, raw, &std.ascii.whitespace);
        if (part.len == 0) continue;
        var range: PageRange = undefined;
        if (std.mem.indexOfScalar(u8, part, '-')) |dash| {
            if (std.mem.indexOfScalarPos(u8, part, dash + 1, '-') != null) return error.InvalidPageRangeSyntax;
            const a = std.mem.trim(u8, part[0..dash], &std.ascii.whitespace);
            const b = std.mem.trim(u8, part[dash + 1 ..], &std.ascii.whitespace);
            range.from = if (a.len == 0) 1 else parsePageNumber(a) orelse return error.InvalidPageRangeSyntax;
            range.to = if (b.len == 0) std.math.maxInt(u32) else parsePageNumber(b) orelse return error.InvalidPageRangeSyntax;
        } else {
            range.from = parsePageNumber(part) orelse return error.InvalidPageRangeSyntax;
            range.to = range.from;
        }
        if (range.from == 0 or range.from > range.to) return error.InvalidPageRange;
        try out.append(arena, range);
    }
    return out.items;
}

fn parsePageNumber(s: []const u8) ?u32 {
    return std.fmt.parseInt(u32, s, 10) catch null;
}

/// Prints `node` as a paginated, text PDF.
pub fn print(arena: Allocator, node: *Node, opts: Opts, writer: *std.Io.Writer, frame: *Frame) !void {
    const prepared = try prepare(arena, node, opts, frame);
    return prepared.write(writer);
}

/// The PDF counterpart of `screenshot.preparePng`: same DOM walk, same block
/// model, so a print and a screenshot agree on the page's text. Everything
/// that can fail does so here, before any output: options, and a page
/// selection that hits no page (that one costs a layout pass, only paid
/// when ranges are given).
pub fn prepare(arena: Allocator, node: *Node, opts: Opts, frame: *Frame) !Prepared {
    const content_w = opts.paper_width - opts.margin_left - opts.margin_right;
    const content_h = opts.paper_height - opts.margin_top - opts.margin_bottom;
    if (!(opts.paper_width > 0 and opts.paper_height > 0) or
        !(opts.margin_top >= 0 and opts.margin_right >= 0 and opts.margin_bottom >= 0 and opts.margin_left >= 0) or
        !(content_w >= 1 and content_h >= 1) or
        !(opts.scale >= 0.1 and opts.scale <= 2))
    {
        return error.InvalidPdfOptions;
    }
    for (opts.page_ranges) |r| {
        if (r.from == 0 or r.from > r.to) return error.InvalidPdfOptions;
    }
    const prepared: Prepared = .{
        .arena = arena,
        .opts = opts,
        .blocks = try screenshot.collect(arena, node, frame),
        .renderer = try screenshot.rendererFor(frame),
    };
    if (opts.page_ranges.len > 0) {
        const count = try prepared.pageCount();
        for (opts.page_ranges) |r| {
            if (r.from <= count) break;
        } else return error.PageRangeExceedsPageCount;
    }
    return prepared;
}

pub const Prepared = struct {
    arena: Allocator,
    opts: Opts,
    blocks: []const screenshot.LpBlock,
    renderer: *screenshot.Renderer,

    pub fn write(self: *const Prepared, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        _ = try self.render(writer, false);
    }

    /// How many pages the document paginates to, without writing any.
    pub fn pageCount(self: *const Prepared) std.Io.Writer.Error!u32 {
        var discard: std.Io.Writer.Discarding = .init(&.{});
        return self.render(&discard.writer, true);
    }

    // Serializes as a base64 string, streamed, like `screenshot.Prepared`.
    pub fn jsonStringify(self: *const Prepared, jws: *std.json.Stringify) std.Io.Writer.Error!void {
        try jws.beginWriteRaw();
        try jws.writer.writeByte('"');
        var b64 = Base64Writer.init(jws.writer, .standard);
        try self.write(&b64.writer);
        try b64.finish();
        try jws.writer.writeByte('"');
        jws.endWriteRaw();
    }

    // WriteFailed is the only error jsonStringify's signature can carry,
    // hence the log line for everything else.
    fn render(self: *const Prepared, writer: *std.Io.Writer, measure_only: bool) std.Io.Writer.Error!u32 {
        return self.renderInner(writer, measure_only) catch |err| switch (err) {
            error.WriteFailed => return error.WriteFailed,
            else => {
                log.err(.browser, "pdf render", .{ .err = err });
                return error.WriteFailed;
            },
        };
    }

    fn renderInner(self: *const Prepared, writer: *std.Io.Writer, measure_only: bool) !u32 {
        const opts = self.opts;
        const content_w = opts.paper_width - opts.margin_left - opts.margin_right;
        const content_h = opts.paper_height - opts.margin_top - opts.margin_bottom;

        // Layout in content px: CSS px over the print scale, so the page
        // transform is one uniform scale and the text metrics stay the
        // screenshot's.
        var layout = try screenshot.layout(self.renderer, self.blocks, content_w / opts.scale, 0);
        defer layout.deinit();

        var doc: Document = try .init(self.arena, &layout, self.blocks, opts, content_h / opts.scale);
        const page_count: u32 = @intCast(doc.breaks.len);
        if (measure_only) {
            return page_count;
        }
        if (std.mem.indexOfScalar(bool, doc.selected, true) == null) {
            return error.NoPagesSelected;
        }
        try doc.draw();
        try doc.writeFile(writer);
        return page_count;
    }
};

/// CSS px to PDF points.
const PT: f32 = 0.75;
/// Prefix marking an embedded font as a subset.
const SUBSET_TAG = "LPSUBS";

const Document = struct {
    arena: Allocator,
    layout: *const screenshot.Layout,
    blocks: []const screenshot.LpBlock,
    opts: Opts,
    /// Column width in layout px.
    column_w: f32,
    /// Absolute y where each page starts.
    breaks: []const f32,
    selected: []const bool,
    /// Per page: content stream body and link annotation dictionaries.
    pages: []std.Io.Writer.Allocating,
    annots: []std.ArrayList([]const u8),
    /// One per layout font, filled in as glyphs are drawn.
    fonts: []FontUse,
    /// Per block: its span texts concatenated (what the clusters index).
    texts: [][]const u8,

    const Link = struct {
        start: u32,
        end: u32,
        href: []const u8,
    };

    fn init(arena: Allocator, layout: *const screenshot.Layout, blocks: []const screenshot.LpBlock, opts: Opts, page_h: f32) !Document {
        const breaks = try paginate(arena, layout, page_h);

        // Pages come out in document order, once each, whatever order or
        // overlap the ranges have; anything past the end is ignored.
        const selected = try arena.alloc(bool, breaks.len);
        for (selected, 1..) |*sel, n| {
            sel.* = opts.page_ranges.len == 0;
            for (opts.page_ranges) |r| {
                if (n >= r.from and n <= r.to) sel.* = true;
            }
        }

        const pages = try arena.alloc(std.Io.Writer.Allocating, breaks.len);
        const annots = try arena.alloc(std.ArrayList([]const u8), breaks.len);
        for (pages, annots) |*p, *a| {
            p.* = .init(arena);
            a.* = .empty;
        }

        const fonts = try arena.alloc(FontUse, layout.fonts().len);
        for (fonts, layout.fonts()) |*f, info| {
            f.* = try .init(info);
        }

        const texts = try arena.alloc([]const u8, blocks.len);
        for (texts, blocks) |*t, b| {
            var text: std.ArrayList(u8) = .empty;
            for (b.spans[0..b.spans_len]) |s| {
                try text.appendSlice(arena, s.text[0..s.len]);
            }
            t.* = text.items;
        }

        return .{
            .arena = arena,
            .layout = layout,
            .blocks = blocks,
            .opts = opts,
            .column_w = (opts.paper_width - opts.margin_left - opts.margin_right) / opts.scale,
            .breaks = breaks,
            .selected = selected,
            .pages = pages,
            .annots = annots,
            .fonts = fonts,
            .texts = texts,
        };
    }

    /// The page an absolute y lands on, and that y relative to the page.
    fn pageOf(self: *const Document, y: f32) struct { usize, f32 } {
        var lo: usize = 0;
        var hi: usize = self.breaks.len;
        while (hi - lo > 1) {
            const mid = lo + (hi - lo) / 2;
            if (self.breaks[mid] <= y) lo = mid else hi = mid;
        }
        return .{ lo, y - self.breaks[lo] };
    }

    fn draw(self: *Document) !void {
        const layout = self.layout;
        const lines = layout.lines();
        for (layout.blocks(), 0..) |b, bi| {
            if (b.kind == @intFromEnum(screenshot.LpBlock.Kind.rule)) {
                const pg, const py = self.pageOf(b.y);
                if (self.selected[pg]) {
                    try rect(&self.pages[pg].writer, layout.raw.rule_color, b.x, py, self.column_w - b.x, 1);
                }
                continue;
            }
            const block_lines = lines[b.lines..][0..b.lines_len];
            const boxes = try self.lineBoxes(b, block_lines);

            // Backgrounds and quote bars: one rect per page a block lands
            // on, so the lines it spans there never show a seam.
            var i: usize = 0;
            while (i < boxes.len) {
                const pg, const top = self.pageOf(boxes[i].top);
                var j = i;
                while (j + 1 < boxes.len and self.pageOf(boxes[j + 1].top)[0] == pg) j += 1;
                const h = boxes[j].bottom - boxes[i].top;
                if (self.selected[pg]) {
                    const w = &self.pages[pg].writer;
                    if (b.kind == @intFromEnum(screenshot.LpBlock.Kind.pre) and self.opts.print_background) {
                        const x0 = b.x - layout.raw.pre_pad;
                        try rect(w, layout.raw.pre_bg, x0, top, self.column_w - x0, h);
                    }
                    for (0..b.quote_bars) |q| {
                        const bx = b.quote_x + @as(f32, @floatFromInt(q)) * layout.raw.quote_indent;
                        try rect(w, layout.raw.rule_color, bx, top, 3, h);
                    }
                }
                i = j + 1;
            }

            const links = try self.linksOf(bi);
            for (block_lines, boxes, 0..) |line, box, li| {
                const pg, _ = self.pageOf(box.top);
                if (!self.selected[pg]) continue;
                const shift = self.breaks[pg];
                const w = &self.pages[pg].writer;
                if (li == 0 and b.marker_line != screenshot.LAYOUT_NONE) {
                    try self.drawLine(w, lines[b.marker_line], shift);
                }
                try self.drawLine(w, line, shift);
                if (links.len > 0) {
                    try self.linkAnnotations(pg, line, shift, links);
                }
                try self.mapUnicode(line, self.texts[bi]);
            }
            if (b.marker_line != screenshot.LAYOUT_NONE) {
                // The marker's own layout was built from the marker string.
                const block = self.blocks[bi];
                try self.mapUnicode(lines[b.marker_line], block.marker[0..block.marker_len]);
            }
        }
    }

    const Box = struct { top: f32, bottom: f32 };

    /// Each line's vertical extent. A <pre> grows its first and last line by
    /// the padding so the background stays with the text across a break.
    fn lineBoxes(self: *const Document, b: screenshot.LpLayoutBlock, block_lines: []const screenshot.LpLine) ![]const Box {
        const pad: f32 = if (b.kind == @intFromEnum(screenshot.LpBlock.Kind.pre)) self.layout.raw.pre_pad else 0;
        const boxes = try self.arena.alloc(Box, block_lines.len);
        for (boxes, block_lines, 0..) |*box, line, i| {
            box.* = .{
                .top = line.top - if (i == 0) pad else 0,
                .bottom = line.bottom + if (i + 1 == block_lines.len) pad else 0,
            };
        }
        return boxes;
    }

    /// Byte ranges of the block's text that are links, contiguous spans of
    /// the same href merged.
    fn linksOf(self: *const Document, bi: usize) ![]const Link {
        var links: std.ArrayList(Link) = .empty;
        var offset: u32 = 0;
        const block = self.blocks[bi];
        for (block.spans[0..block.spans_len]) |s| {
            const end = offset + @as(u32, @intCast(s.len));
            if (s.href_len > 0) {
                const href = s.href[0..s.href_len];
                if (links.items.len > 0 and links.items[links.items.len - 1].end == offset and std.mem.eql(u8, links.items[links.items.len - 1].href, href)) {
                    links.items[links.items.len - 1].end = end;
                } else {
                    try links.append(self.arena, .{ .start = offset, .end = end, .href = href });
                }
            }
            offset = end;
        }
        return links.items;
    }

    fn drawLine(self: *Document, w: *std.Io.Writer, line: screenshot.LpLine, shift: f32) !void {
        for (self.layout.runs()[line.runs..][0..line.runs_len]) |run| {
            try self.drawRun(w, run, line.x, shift);
        }
    }

    /// One glyph run as a TJ array: font size 1 with the size (and any
    /// synthetic italic skew) in the text matrix, glyph ids as 2-byte CIDs,
    /// and an adjustment wherever the layout's pen differs from the font's
    /// advance (kerning, marks, visual order). Same transform as the raster.
    fn drawRun(self: *Document, w: *std.Io.Writer, run: screenshot.LpRun, line_x: f32, shift: f32) !void {
        const font = &self.fonts[run.font];
        const size = run.size;
        const baseline = run.baseline - shift;
        try w.print("BT /F{d} 1 Tf ", .{run.font});
        try rgb(w, run.color);
        try w.writeAll(" rg\n");
        var pen = line_x + run.offset;
        var cur_y: ?f32 = null;
        var expected: f32 = 0;
        for (self.layout.glyphs()[run.glyphs..][0..run.glyphs_len]) |g| {
            const gx = pen + g.x;
            const gy = baseline - g.y;
            pen += g.advance;
            if (cur_y != gy) {
                if (cur_y != null) try w.writeAll(">] TJ\n");
                try w.print("{d:.3} 0 {d:.3} {d:.3} {d:.3} {d:.3} Tm [<", .{ size, run.skew * size, -size, gx, gy });
                cur_y = gy;
            } else {
                // Positive moves the pen left, in thousandths of the text
                // space unit (= 1/size px here).
                const adj = (expected - gx) * 1000 / size;
                if (@abs(adj) >= 0.5) try w.print("> {d:.1} <", .{adj});
            }
            const gid: u16 = @intCast(g.id);
            const width = try font.use(self.arena, gid);
            try w.print("{X:0>4}", .{gid});
            expected = gx + width * size / 1000;
        }
        if (cur_y != null) try w.writeAll(">] TJ\n");
        try w.writeAll("ET\n");

        const x0 = line_x + run.offset;
        for ([_]screenshot.LpDecoration{ run.underline, run.strike }) |d| {
            if (d.enabled == 0) continue;
            try rect(w, d.color, x0, baseline - d.offset, run.advance, d.size);
        }
    }

    /// One URI annotation per line per link: clusters in visual order,
    /// contiguous runs of the same link merged into a box.
    fn linkAnnotations(self: *Document, pg: usize, line: screenshot.LpLine, shift: f32, links: []const Link) !void {
        const top = line.top - shift;
        const bottom = line.bottom - shift;
        var open: ?struct { link: usize, x0: f32, x1: f32 } = null;
        for (self.layout.clusters()[line.clusters..][0..line.clusters_len]) |c| {
            const x = line.x + c.x;
            var hit: ?usize = null;
            for (links, 0..) |l, i| {
                if (c.text_start >= l.start and c.text_start < l.end) hit = i;
            }
            if (open != null and hit == open.?.link and @abs(open.?.x1 - x) < 0.01) {
                open.?.x1 = x + c.advance;
                continue;
            }
            if (open) |o| try self.annotate(pg, o.x0, top, o.x1, bottom, links[o.link].href);
            open = if (hit) |i| .{ .link = i, .x0 = x, .x1 = x + c.advance } else null;
        }
        if (open) |o| try self.annotate(pg, o.x0, top, o.x1, bottom, links[o.link].href);
    }

    /// A URI link annotation over a page-relative box (layout px, y down).
    /// The URL goes in as a hex string: nothing to escape.
    fn annotate(self: *Document, pg: usize, x0: f32, top: f32, x1: f32, bottom: f32, url: []const u8) !void {
        const opts = self.opts;
        const s = opts.scale;
        var aw: std.Io.Writer.Allocating = .init(self.arena);
        try aw.writer.print("<< /Type /Annot /Subtype /Link /Rect [{d:.3} {d:.3} {d:.3} {d:.3}] /Border [0 0 0] /A << /S /URI /URI <", .{
            (opts.margin_left + x0 * s) * PT,
            (opts.paper_height - opts.margin_top - bottom * s) * PT,
            (opts.margin_left + x1 * s) * PT,
            (opts.paper_height - opts.margin_top - top * s) * PT,
        });
        for (url) |b| try aw.writer.print("{X:0>2}", .{b});
        try aw.writer.writeAll("> >> >>\n");
        try self.annots[pg].append(self.arena, aw.written());
    }

    /// Maps each cluster's glyph to the text it came from: a base+mark
    /// cluster to its composed character, a ligature glyph to every letter
    /// it absorbed (glyphless continuation clusters follow the one carrying
    /// the glyph). First occurrence wins.
    fn mapUnicode(self: *Document, line: screenshot.LpLine, text: []const u8) !void {
        var ligature: ?struct { font: u32, gid: u16, text: std.ArrayList(u8) } = null;
        for (self.layout.clusters()[line.clusters..][0..line.clusters_len]) |c| {
            const t = if (c.text_start + c.text_len <= text.len) text[c.text_start..][0..c.text_len] else "";
            if (c.flags & screenshot.CLUSTER_LIGATURE_CONT != 0) {
                if (ligature) |*l| try l.text.appendSlice(self.arena, t);
                continue;
            }
            if (ligature) |l| {
                try self.fonts[l.font].mapText(self.arena, l.gid, l.text.items);
                ligature = null;
            }
            if (c.glyph == screenshot.LAYOUT_NONE or t.len == 0) continue;
            const gid: u16 = @intCast(c.glyph);
            if (c.flags & screenshot.CLUSTER_LIGATURE_START != 0) {
                var buf: std.ArrayList(u8) = .empty;
                try buf.appendSlice(self.arena, t);
                ligature = .{ .font = c.font, .gid = gid, .text = buf };
            } else {
                try self.fonts[c.font].mapText(self.arena, gid, t);
            }
        }
        if (ligature) |l| try self.fonts[l.font].mapText(self.arena, l.gid, l.text.items);
    }

    // File structure: header, catalog, then each page's annotations,
    // content and page object, then the fonts (subset by what the pages
    // used), the shared resources and the page tree, and finally the xref.
    fn writeFile(self: *Document, writer: *std.Io.Writer) !void {
        const opts = self.opts;
        var out: Out = .{ .writer = writer, .arena = self.arena };
        try out.write("%PDF-1.4\n%\xE2\xE3\xCF\xD3\n");
        const catalog = try out.alloc();
        const pages_id = try out.alloc();
        const resources = try out.alloc();
        try out.begin(catalog);
        try out.write("<< /Type /Catalog /Pages 2 0 R >>\n");
        try out.end();

        var kids: std.Io.Writer.Allocating = .init(self.arena);
        var count: usize = 0;
        for (self.pages, self.annots, 0..) |*page, annots, i| {
            if (!self.selected[i]) continue;
            var content: std.Io.Writer.Allocating = .init(self.arena);
            try content.writer.print("q {d:.4} 0 0 {d:.4} {d:.3} {d:.3} cm\n", .{
                PT * opts.scale,
                -PT * opts.scale,
                opts.margin_left * PT,
                (opts.paper_height - opts.margin_top) * PT,
            });
            try content.writer.writeAll(page.written());
            try content.writer.writeAll("Q\n");
            const contents = try out.stream("", content.written());

            var annot_refs: std.Io.Writer.Allocating = .init(self.arena);
            for (annots.items) |a| {
                const id = try out.alloc();
                try out.begin(id);
                try out.write(a);
                try out.end();
                try annot_refs.writer.print("{d} 0 R ", .{id});
            }
            const page_id = try out.alloc();
            try out.begin(page_id);
            try out.print("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {d:.3} {d:.3}] /Resources 3 0 R /Contents {d} 0 R", .{
                opts.paper_width * PT,
                opts.paper_height * PT,
                contents,
            });
            if (annot_refs.written().len > 0) {
                try out.print(" /Annots [ {s}]", .{annot_refs.written()});
            }
            try out.write(" >>\n");
            try out.end();
            try kids.writer.print("{d} 0 R ", .{page_id});
            count += 1;
        }

        var font_refs: std.Io.Writer.Allocating = .init(self.arena);
        for (self.fonts, 0..) |*font, i| {
            if (font.used.count() == 0) continue;
            const id = try font.writeObjects(self.arena, &out);
            try font_refs.writer.print("/F{d} {d} 0 R ", .{ i, id });
        }
        try out.begin(resources);
        try out.print("<< /Font << {s}>> >>\n", .{font_refs.written()});
        try out.end();
        try out.begin(pages_id);
        try out.print("<< /Type /Pages /Count {d} /Kids [ {s}] >>\n", .{ count, kids.written() });
        try out.end();

        const xref_at = out.offset;
        try out.print("xref\n0 {d}\n0000000000 65535 f \n", .{out.xref.items.len + 1});
        for (out.xref.items) |off| {
            try out.print("{d:0>10} 00000 n \n", .{off});
        }
        try out.print("trailer\n<< /Size {d} /Root 1 0 R >>\nstartxref\n{d}\n%%EOF\n", .{ out.xref.items.len + 1, xref_at });
    }
};

/// Absolute y (layout px) where each page starts. A line that would cross
/// the bottom of the page starts the next one; a line taller than a page
/// overflows it. Rules are one 1px line; a <pre>'s padding rides with its
/// first and last line.
fn paginate(arena: Allocator, layout: *const screenshot.Layout, page_h: f32) ![]const f32 {
    var breaks: std.ArrayList(f32) = .empty;
    try breaks.append(arena, 0);
    const lines = layout.lines();
    for (layout.blocks()) |b| {
        if (b.kind == @intFromEnum(screenshot.LpBlock.Kind.rule)) {
            try fit(arena, &breaks, b.y, b.y + 1, page_h);
            continue;
        }
        const pad: f32 = if (b.kind == @intFromEnum(screenshot.LpBlock.Kind.pre)) layout.raw.pre_pad else 0;
        for (lines[b.lines..][0..b.lines_len], 0..) |line, i| {
            const top = line.top - if (i == 0) pad else 0;
            const bottom = line.bottom + if (i + 1 == b.lines_len) pad else 0;
            try fit(arena, &breaks, top, bottom, page_h);
        }
    }
    return breaks.items;
}

fn fit(arena: Allocator, breaks: *std.ArrayList(f32), top: f32, bottom: f32, page_h: f32) !void {
    const start = breaks.items[breaks.items.len - 1];
    if (bottom - start > page_h and top > start) {
        try breaks.append(arena, top);
    }
}

// Content-stream helpers. User space is the content box in layout px, y
// down (the `cm` prefix in writeFile flips it), so positions are used as
// laid out.

fn rect(w: *std.Io.Writer, color: u32, x: f32, y: f32, width: f32, height: f32) !void {
    if (!(width > 0 and height > 0)) return;
    try rgb(w, color);
    try w.print(" rg {d:.3} {d:.3} {d:.3} {d:.3} re f\n", .{ x, y, width, height });
}

/// "r g b" in 0..1 for a 0xRRGGBB.
fn rgb(w: *std.Io.Writer, color: u32) !void {
    try w.print("{d:.3} {d:.3} {d:.3}", .{
        @as(f32, @floatFromInt((color >> 16) & 0xff)) / 255,
        @as(f32, @floatFromInt((color >> 8) & 0xff)) / 255,
        @as(f32, @floatFromInt(color & 0xff)) / 255,
    });
}

// ---------------------------------------------------------------------------
// Fonts: a face the layout used, the glyphs the pages drew with it (for the
// subset and the widths) and what text each glyph stood for (ToUnicode).

const FontUse = struct {
    info: screenshot.LpFont,
    ttf: TrueType,
    /// gid → advance in 1/1000 em, for every glyph drawn.
    used: std.AutoHashMapUnmanaged(u16, f32) = .empty,
    /// gid → the text it was shaped from.
    unicode: std.AutoHashMapUnmanaged(u16, []const u8) = .empty,

    fn init(info: screenshot.LpFont) !FontUse {
        return .{
            .info = info,
            .ttf = try TrueType.parse(info.data[0..info.data_len]),
        };
    }

    /// Records a drawn glyph and returns its advance in 1/1000 em.
    fn use(self: *FontUse, arena: Allocator, gid: u16) !f32 {
        const gop = try self.used.getOrPut(arena, gid);
        if (!gop.found_existing) {
            gop.value_ptr.* = @as(f32, @floatFromInt(self.ttf.advance(gid))) * 1000 / @as(f32, @floatFromInt(self.ttf.upem));
        }
        return gop.value_ptr.*;
    }

    fn mapText(self: *FontUse, arena: Allocator, gid: u16, text: []const u8) !void {
        const gop = try self.unicode.getOrPut(arena, gid);
        if (!gop.found_existing) {
            gop.value_ptr.* = try arena.dupe(u8, text);
        }
    }

    fn sortedGids(self: *const FontUse, arena: Allocator) ![]u16 {
        const gids = try arena.alloc(u16, self.used.count());
        var it = self.used.keyIterator();
        var i: usize = 0;
        while (it.next()) |k| : (i += 1) gids[i] = k.*;
        std.mem.sort(u16, gids, {}, std.sort.asc(u16));
        return gids;
    }

    /// Writes the five objects of one embedded font and returns the Type0 id.
    fn writeObjects(self: *const FontUse, arena: Allocator, out: *Out) !usize {
        const ttf = &self.ttf;
        const k = 1000 / @as(f32, @floatFromInt(ttf.upem));
        const gids = try self.sortedGids(arena);
        const name = try std.fmt.allocPrint(arena, "{s}+{s}", .{ SUBSET_TAG, self.info.name[0..self.info.name_len] });

        const file = ttf.subset(arena, gids) catch ttf.data;
        const file_id = try out.stream(try std.fmt.allocPrint(arena, "/Length1 {d}", .{file.len}), file);

        const descriptor = try out.alloc();
        try out.begin(descriptor);
        try out.print("<< /Type /FontDescriptor /FontName /{s} /Flags {d} /FontBBox [{d:.1} {d:.1} {d:.1} {d:.1}] /ItalicAngle 0 /Ascent {d:.1} /Descent {d:.1} /CapHeight {d:.1} /StemV 80 /FontFile2 {d} 0 R >>\n", .{
            name,
            @as(u32, 32) | @as(u32, if (self.info.mono != 0) 1 else 0),
            @as(f32, @floatFromInt(ttf.bbox[0])) * k,
            @as(f32, @floatFromInt(ttf.bbox[1])) * k,
            @as(f32, @floatFromInt(ttf.bbox[2])) * k,
            @as(f32, @floatFromInt(ttf.bbox[3])) * k,
            @as(f32, @floatFromInt(ttf.ascent)) * k,
            -@abs(@as(f32, @floatFromInt(ttf.descent))) * k,
            @as(f32, @floatFromInt(ttf.cap_height)) * k,
            file_id,
        });
        try out.end();

        // W: runs of consecutive gids as `first [w w w]`.
        var widths: std.Io.Writer.Allocating = .init(arena);
        var i: usize = 0;
        while (i < gids.len) {
            try widths.writer.print("{d} [{d:.1}", .{ gids[i], self.used.get(gids[i]).? });
            while (i + 1 < gids.len and gids[i + 1] == gids[i] + 1) : (i += 1) {
                try widths.writer.print(" {d:.1}", .{self.used.get(gids[i + 1]).?});
            }
            try widths.writer.writeAll("] ");
            i += 1;
        }
        const cid = try out.alloc();
        try out.begin(cid);
        try out.print("<< /Type /Font /Subtype /CIDFontType2 /BaseFont /{s} /CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >> /FontDescriptor {d} 0 R /DW 1000 /W [ {s}] /CIDToGIDMap /Identity >>\n", .{ name, descriptor, widths.written() });
        try out.end();

        const to_unicode = try out.stream("", try self.toUnicodeCMap(arena, gids));
        const type0 = try out.alloc();
        try out.begin(type0);
        try out.print("<< /Type /Font /Subtype /Type0 /BaseFont /{s} /Encoding /Identity-H /DescendantFonts [{d} 0 R] /ToUnicode {d} 0 R >>\n", .{ name, cid, to_unicode });
        try out.end();
        return type0;
    }

    fn toUnicodeCMap(self: *const FontUse, arena: Allocator, gids: []const u16) ![]const u8 {
        var aw: std.Io.Writer.Allocating = .init(arena);
        const w = &aw.writer;
        try w.writeAll(
            \\/CIDInit /ProcSet findresource begin
            \\12 dict begin
            \\begincmap
            \\/CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def
            \\/CMapName /Adobe-Identity-UCS def
            \\/CMapType 2 def
            \\1 begincodespacerange
            \\<0000> <FFFF>
            \\endcodespacerange
            \\
        );
        var mapped: std.ArrayList(u16) = .empty;
        for (gids) |gid| {
            if (self.unicode.contains(gid)) try mapped.append(arena, gid);
        }
        var rest = mapped.items;
        while (rest.len > 0) {
            const chunk = rest[0..@min(rest.len, 100)];
            rest = rest[chunk.len..];
            try w.print("{d} beginbfchar\n", .{chunk.len});
            for (chunk) |gid| {
                try w.print("<{X:0>4}> <", .{gid});
                // UTF-16BE.
                var it = std.unicode.Utf8View.initUnchecked(self.unicode.get(gid).?).iterator();
                while (it.nextCodepoint()) |cp| {
                    if (cp < 0x10000) {
                        try w.print("{X:0>4}", .{@as(u16, @intCast(cp))});
                    } else {
                        const c = cp - 0x10000;
                        try w.print("{X:0>4}{X:0>4}", .{ @as(u16, @intCast(0xD800 + (c >> 10))), @as(u16, @intCast(0xDC00 + (c & 0x3FF))) });
                    }
                }
                try w.writeAll(">\n");
            }
            try w.writeAll("endbfchar\n");
        }
        try w.writeAll("endcmap\nCMapName currentdict /CMap defineresource pop\nend\nend\n");
        return aw.written();
    }
};

// ---------------------------------------------------------------------------
// The TrueType tables the PDF needs: metrics for the descriptor, advances
// for the W array and TJ, and a sparse subset for embedding.

const TrueType = struct {
    data: []const u8,
    upem: u16,
    num_glyphs: u16,
    num_h_metrics: u16,
    ascent: i16,
    descent: i16,
    cap_height: i16,
    bbox: [4]i16,
    hmtx: []const u8,

    fn parse(data: []const u8) !TrueType {
        if (data.len < 12 or be32(data, 0) != 0x00010000) return error.NotTrueType;
        const head = table(data, "head") orelse return error.NotTrueType;
        const hhea = table(data, "hhea") orelse return error.NotTrueType;
        const maxp = table(data, "maxp") orelse return error.NotTrueType;
        const hmtx = table(data, "hmtx") orelse return error.NotTrueType;
        if (head.len < 54 or hhea.len < 36 or maxp.len < 6) return error.NotTrueType;
        const ascent: i16 = @bitCast(be16(hhea, 4));
        var cap_height = ascent;
        if (table(data, "OS/2")) |os2| {
            if (os2.len >= 90 and be16(os2, 0) >= 2) cap_height = @bitCast(be16(os2, 88));
        }
        return .{
            .data = data,
            .upem = be16(head, 18),
            .num_glyphs = be16(maxp, 4),
            .num_h_metrics = be16(hhea, 34),
            .ascent = ascent,
            .descent = @bitCast(be16(hhea, 6)),
            .cap_height = cap_height,
            .bbox = .{ @bitCast(be16(head, 36)), @bitCast(be16(head, 38)), @bitCast(be16(head, 40)), @bitCast(be16(head, 42)) },
            .hmtx = hmtx,
        };
    }

    fn table(data: []const u8, tag: *const [4]u8) ?[]const u8 {
        const count = be16(data, 4);
        for (0..count) |i| {
            const rec = 12 + i * 16;
            if (rec + 16 > data.len) return null;
            if (!std.mem.eql(u8, data[rec..][0..4], tag)) continue;
            const off = be32(data, rec + 8);
            const len = be32(data, rec + 12);
            if (off + len > data.len) return null;
            return data[off..][0..len];
        }
        return null;
    }

    fn advance(self: *const TrueType, gid: u16) u16 {
        const row = @min(gid, self.num_h_metrics -| 1);
        const o = @as(usize, row) * 4;
        if (o + 2 > self.hmtx.len) return 0;
        return be16(self.hmtx, o);
    }

    /// Rebuilds the font keeping only the outlines of `gids` (plus the
    /// components they reference). Glyph ids are unchanged: unused glyphs
    /// keep their slot with no outline, so nothing else needs remapping.
    fn subset(self: *const TrueType, arena: Allocator, gids: []const u16) ![]const u8 {
        const data = self.data;
        const head = table(data, "head") orelse return error.NotTrueType;
        const loca = table(data, "loca") orelse return error.NotTrueType;
        const glyf = table(data, "glyf") orelse return error.NotTrueType;
        const n: usize = self.num_glyphs;
        const long_loca = be16(head, 50) != 0;
        const offsets = try arena.alloc(usize, n + 1);
        for (offsets, 0..) |*o, i| {
            if (long_loca) {
                if (i * 4 + 4 > loca.len) return error.NotTrueType;
                o.* = be32(loca, i * 4);
            } else {
                if (i * 2 + 2 > loca.len) return error.NotTrueType;
                o.* = @as(usize, be16(loca, i * 2)) * 2;
            }
            if (o.* > glyf.len) return error.NotTrueType;
        }

        // Closure over composite components. .notdef always stays.
        const keep = try arena.alloc(bool, n);
        @memset(keep, false);
        var stack: std.ArrayList(usize) = .empty;
        try stack.append(arena, 0);
        for (gids) |g| {
            if (g < n) try stack.append(arena, g);
        }
        while (stack.pop()) |g| {
            if (keep[g]) continue;
            keep[g] = true;
            const start = offsets[g];
            const end = offsets[g + 1];
            if (end < start + 10) continue;
            const glyph = glyf[start..end];
            if (@as(i16, @bitCast(be16(glyph, 0))) >= 0) continue;
            var o: usize = 10;
            while (o + 4 <= glyph.len) {
                const flags = be16(glyph, o);
                const component = be16(glyph, o + 2);
                o += 4;
                if (component < n) try stack.append(arena, component);
                o += if (flags & 0x01 != 0) 4 else 2;
                o += if (flags & 0x08 != 0) @as(usize, 2) else if (flags & 0x40 != 0) 4 else if (flags & 0x80 != 0) 8 else 0;
                if (flags & 0x20 == 0) break;
            }
        }

        var new_glyf: std.ArrayList(u8) = .empty;
        var new_loca: std.ArrayList(u8) = .empty;
        for (0..n) |g| {
            try new_loca.appendSlice(arena, &std.mem.toBytes(std.mem.nativeToBig(u32, @intCast(new_glyf.items.len))));
            if (keep[g]) {
                try new_glyf.appendSlice(arena, glyf[offsets[g]..offsets[g + 1]]);
                while (new_glyf.items.len % 4 != 0) try new_glyf.append(arena, 0);
            }
        }
        try new_loca.appendSlice(arena, &std.mem.toBytes(std.mem.nativeToBig(u32, @intCast(new_glyf.items.len))));

        // Unused advances zeroed for compression; the last full row stays
        // because every glyph past it shares its advance.
        const new_hmtx = try arena.dupe(u8, self.hmtx);
        const num_h: usize = self.num_h_metrics;
        for (0..n) |g| {
            if (keep[g]) continue;
            const range: ?struct { usize, usize } = if (g + 1 < num_h) .{ g * 4, g * 4 + 4 } else if (g >= num_h) .{ num_h * 4 + (g - num_h) * 2, num_h * 4 + (g - num_h) * 2 + 2 } else null;
            if (range) |r| {
                if (r[1] <= new_hmtx.len) @memset(new_hmtx[r[0]..r[1]], 0);
            }
        }

        const new_head = try arena.dupe(u8, head);
        std.mem.writeInt(u16, new_head[50..52], 1, .big);
        @memset(new_head[8..12], 0);

        const Table = struct {
            tag: [4]u8,
            data: []const u8,

            fn lessThan(_: void, a: @This(), b: @This()) bool {
                return std.mem.order(u8, &a.tag, &b.tag) == .lt;
            }
        };
        var tables: std.ArrayList(Table) = .empty;
        for ([_]*const [4]u8{ "cvt ", "fpgm", "prep", "hhea", "maxp" }) |tag| {
            if (table(data, tag)) |t| try tables.append(arena, .{ .tag = tag.*, .data = t });
        }
        try tables.append(arena, .{ .tag = "glyf".*, .data = new_glyf.items });
        try tables.append(arena, .{ .tag = "head".*, .data = new_head });
        try tables.append(arena, .{ .tag = "hmtx".*, .data = new_hmtx });
        try tables.append(arena, .{ .tag = "loca".*, .data = new_loca.items });
        std.mem.sort(Table, tables.items, {}, Table.lessThan);

        const count = tables.items.len;
        const entry_selector: u4 = @intCast(std.math.log2_int(usize, count));
        const search_range: u16 = @as(u16, 1) << entry_selector;
        var out: std.Io.Writer.Allocating = .init(arena);
        const w = &out.writer;
        try w.writeInt(u32, 0x00010000, .big);
        try w.writeInt(u16, @intCast(count), .big);
        try w.writeInt(u16, search_range * 16, .big);
        try w.writeInt(u16, entry_selector, .big);
        try w.writeInt(u16, @as(u16, @intCast(count)) * 16 - search_range * 16, .big);

        const dir_len = 12 + 16 * count;
        var body: std.Io.Writer.Allocating = .init(arena);
        var head_at: usize = 0;
        for (tables.items) |t| {
            const at = dir_len + body.written().len;
            if (std.mem.eql(u8, &t.tag, "head")) head_at = at;
            try w.writeAll(&t.tag);
            try w.writeInt(u32, checksum(t.data), .big);
            try w.writeInt(u32, @intCast(at), .big);
            try w.writeInt(u32, @intCast(t.data.len), .big);
            try body.writer.writeAll(t.data);
            while (body.written().len % 4 != 0) try body.writer.writeByte(0);
        }
        try w.writeAll(body.written());
        const file = out.written();
        const adjust = 0xB1B0AFBA -% checksum(file);
        std.mem.writeInt(u32, file[head_at + 8 ..][0..4], adjust, .big);
        return file;
    }
};

fn be16(d: []const u8, o: usize) u16 {
    return std.mem.readInt(u16, d[o..][0..2], .big);
}

fn be32(d: []const u8, o: usize) u32 {
    return std.mem.readInt(u32, d[o..][0..4], .big);
}

fn checksum(d: []const u8) u32 {
    var sum: u32 = 0;
    var i: usize = 0;
    while (i < d.len) : (i += 4) {
        var word: [4]u8 = .{ 0, 0, 0, 0 };
        const n = @min(4, d.len - i);
        @memcpy(word[0..n], d[i..][0..n]);
        sum +%= std.mem.readInt(u32, &word, .big);
    }
    return sum;
}

// ---------------------------------------------------------------------------
// The file itself: objects written in order with their offsets kept for the
// xref. Ids come from `alloc` so an object can be referenced before it is
// written (catalog, pages, resources).

const Out = struct {
    writer: *std.Io.Writer,
    arena: Allocator,
    offset: usize = 0,
    xref: std.ArrayList(usize) = .empty,

    fn write(self: *Out, bytes: []const u8) !void {
        try self.writer.writeAll(bytes);
        self.offset += bytes.len;
    }

    fn print(self: *Out, comptime fmt: []const u8, args: anytype) !void {
        try self.write(try std.fmt.allocPrint(self.arena, fmt, args));
    }

    fn alloc(self: *Out) !usize {
        try self.xref.append(self.arena, 0);
        return self.xref.items.len;
    }

    fn begin(self: *Out, id: usize) !void {
        self.xref.items[id - 1] = self.offset;
        try self.print("{d} 0 obj\n", .{id});
    }

    fn end(self: *Out) !void {
        try self.write("endobj\n");
    }

    /// A FlateDecode stream object; `extra` goes into its dictionary.
    fn stream(self: *Out, extra: []const u8, data: []const u8) !usize {
        const z = try deflate(self.arena, data);
        const id = try self.alloc();
        try self.begin(id);
        try self.print("<< /Length {d} /Filter /FlateDecode {s} >>\nstream\n", .{ z.len, extra });
        try self.write(z);
        try self.write("\nendstream\n");
        try self.end();
        return id;
    }
};

fn deflate(arena: Allocator, data: []const u8) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    try aw.ensureUnusedCapacity(256);
    const window = try arena.alloc(u8, flate.max_window_len);
    var c = try flate.Compress.init(&aw.writer, window, .zlib, .default);
    try c.writer.writeAll(data);
    try c.finish();
    return aw.written();
}

const testing = @import("../testing.zig");
test "browser.pdf: structure, pagination and links" {
    defer testing.test_session.closeAllPages();
    const frame = try testing.createFrame();
    frame.url = "http://localhost/";
    const doc = frame.window._document;
    const div = try doc.createElement("div", null, frame);
    try Frame.parse.htmlAsChildren(frame, div.asNode(), "<h1>Title</h1><p>Hello <b>world</b> <a href='/x'>link</a></p><pre>code</pre>");

    var aw: std.Io.Writer.Allocating = .init(testing.arena_allocator);
    try print(testing.arena_allocator, div.asNode(), .{}, &aw.writer, frame);
    const out = aw.written();
    try testing.expectEqual("%PDF-1.4\n", out[0..9]);
    try testing.expectEqual("%%EOF\n", out[out.len - 6 ..]);
    try testing.expectEqual(1, std.mem.count(u8, out, "/Type /Page "));
    // Letter in points, and the three faces the text used, each embedded once.
    try testing.expectEqual(true, std.mem.indexOf(u8, out, "/MediaBox [0 0 612.000 792.000]") != null);
    try testing.expectEqual(3, std.mem.count(u8, out, "/Subtype /Type0"));
    try testing.expectEqual(3, std.mem.count(u8, out, "/FontFile2"));
    try testing.expectEqual(true, std.mem.indexOf(u8, out, "/Encoding /Identity-H") != null);
    // Well under the 2MB of bundled fonts: they were subset.
    try testing.expectEqual(true, out.len < 120_000);
    // The one link is a URI annotation on the page, resolved to absolute.
    try testing.expectEqual(1, std.mem.count(u8, out, "/Subtype /Link"));
    try testing.expectEqual(1, std.mem.count(u8, out, "/Annots ["));
    const uri = "/URI <" ++ std.fmt.bytesToHex("http://localhost/x", .upper) ++ ">";
    try testing.expectEqual(true, std.mem.indexOf(u8, out, uri) != null);

    // 200 paragraphs don't fit one Letter page; a range then picks pages.
    const long = try doc.createElement("div", null, frame);
    var html: std.ArrayList(u8) = .empty;
    for (0..200) |_| try html.appendSlice(testing.arena_allocator, "<p>A paragraph of text that takes up a line.</p>");
    try Frame.parse.htmlAsChildren(frame, long.asNode(), html.items);

    aw.clearRetainingCapacity();
    try print(testing.arena_allocator, long.asNode(), .{}, &aw.writer, frame);
    const pages = std.mem.count(u8, aw.written(), "/Type /Page ");
    try testing.expectEqual(true, pages >= 5 and pages <= 8);

    aw.clearRetainingCapacity();
    try print(testing.arena_allocator, long.asNode(), .{ .page_ranges = try parsePageRanges(testing.arena_allocator, "2-3, 5") }, &aw.writer, frame);
    try testing.expectEqual(3, std.mem.count(u8, aw.written(), "/Type /Page "));

    // Document order, once each, the tail past the end ignored.
    aw.clearRetainingCapacity();
    try print(testing.arena_allocator, long.asNode(), .{ .page_ranges = try parsePageRanges(testing.arena_allocator, "5, 2-3, 3, 4000-") }, &aw.writer, frame);
    try testing.expectEqual(3, std.mem.count(u8, aw.written(), "/Type /Page "));

    // Halving the scale roughly halves the pages; landscape is the caller's
    // swap, and margins shrink the content box.
    aw.clearRetainingCapacity();
    try print(testing.arena_allocator, long.asNode(), .{ .scale = 0.5 }, &aw.writer, frame);
    const half = std.mem.count(u8, aw.written(), "/Type /Page ");
    try testing.expectEqual(true, half < pages and half >= pages / 3);

    aw.clearRetainingCapacity();
    try print(testing.arena_allocator, long.asNode(), .{ .paper_width = 1056, .paper_height = 816, .margin_top = 300, .margin_bottom = 300 }, &aw.writer, frame);
    try testing.expectEqual(true, std.mem.indexOf(u8, aw.written(), "/MediaBox [0 0 792.000 612.000]") != null);
    try testing.expectEqual(true, std.mem.count(u8, aw.written(), "/Type /Page ") > pages);
}

test "browser.pdf: rejects bad options" {
    defer testing.test_session.closeAllPages();
    testing.silenceLog(&.{.browser});
    const frame = try testing.createFrame();
    frame.url = "http://localhost/";
    const doc = frame.window._document;
    const div = try doc.createElement("div", null, frame);
    try Frame.parse.htmlAsChildren(frame, div.asNode(), "<p>hello</p>");

    var discard: std.Io.Writer.Discarding = .init(&.{});
    const w = &discard.writer;
    const a = testing.arena_allocator;
    try testing.expectError(error.InvalidPdfOptions, print(a, div.asNode(), .{ .scale = 3 }, w, frame));
    try testing.expectError(error.InvalidPdfOptions, print(a, div.asNode(), .{ .paper_width = 0 }, w, frame));
    try testing.expectError(error.InvalidPdfOptions, print(a, div.asNode(), .{ .margin_left = 500, .margin_right = 500 }, w, frame));
    try testing.expectError(error.InvalidPdfOptions, print(a, div.asNode(), .{ .page_ranges = &.{.{ .from = 3, .to = 1 }} }, w, frame));
    // Well-formed, but this is a one-page document.
    try testing.expectError(error.PageRangeExceedsPageCount, print(a, div.asNode(), .{ .page_ranges = &.{.{ .from = 7, .to = 9 }} }, w, frame));

    // Far too small for the file, so the sink refuses partway through.
    var buf: [64]u8 = undefined;
    var fixed = std.Io.Writer.fixed(&buf);
    try testing.expectError(error.WriteFailed, print(a, div.asNode(), .{}, &fixed, frame));
}

test "browser.pdf: parsePageRanges follows the CDP grammar" {
    const a = testing.arena_allocator;
    const r = try parsePageRanges(a, "1-5, 8 ,11-13,,");
    try testing.expectEqual(3, r.len);
    try testing.expectEqual(PageRange{ .from = 1, .to = 5 }, r[0]);
    try testing.expectEqual(PageRange{ .from = 8, .to = 8 }, r[1]);
    try testing.expectEqual(PageRange{ .from = 11, .to = 13 }, r[2]);

    try testing.expectEqual(0, (try parsePageRanges(a, "")).len);
    try testing.expectEqual(0, (try parsePageRanges(a, " , ")).len);
    try testing.expectEqual(PageRange{ .from = 1, .to = 5 }, (try parsePageRanges(a, "1 - 5"))[0]);
    try testing.expectEqual(PageRange{ .from = 1, .to = 5 }, (try parsePageRanges(a, "-5"))[0]);
    try testing.expectEqual(PageRange{ .from = 5, .to = std.math.maxInt(u32) }, (try parsePageRanges(a, "5-"))[0]);
    try testing.expectEqual(PageRange{ .from = 1, .to = std.math.maxInt(u32) }, (try parsePageRanges(a, "-"))[0]);

    try testing.expectError(error.InvalidPageRangeSyntax, parsePageRanges(a, "x"));
    try testing.expectError(error.InvalidPageRangeSyntax, parsePageRanges(a, "1-2-3"));
    try testing.expectError(error.InvalidPageRangeSyntax, parsePageRanges(a, "1.5"));
    try testing.expectError(error.InvalidPageRangeSyntax, parsePageRanges(a, "99999999999"));
    try testing.expectError(error.InvalidPageRange, parsePageRanges(a, "0"));
    try testing.expectError(error.InvalidPageRange, parsePageRanges(a, "3-1"));
}
