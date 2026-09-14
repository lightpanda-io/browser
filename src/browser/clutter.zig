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

//! Main-content selection, after readability.js's grabArticle: paragraphs
//! score their ancestors, the best-scoring ancestor (plus qualifying
//! siblings) becomes the render root, and clutter inside it is pruned by
//! link density, class names and element mix. Nothing is mutated and the
//! render root never moves: the result is the set of nodes to skip, which
//! holds everything beside the selection's path from the root as well as
//! the clutter pruned inside it. RenderTree.State carries it to the
//! renderers.
//!
//! Where readability returns its longest attempt no matter how poor, this
//! returns null and the caller falls back to the shell strip.

const std = @import("std");
const lp = @import("lightpanda");

const Frame = @import("Frame.zig");
const RenderTree = @import("RenderTree.zig");

const Node = @import("webapi/Node.zig");
const Element = @import("webapi/Element.zig");
const Slot = @import("webapi/element/html/Slot.zig");

const log = lp.log;
const Allocator = std.mem.Allocator;

/// Below this many characters of selected text an attempt is rejected.
const char_threshold = 500;

/// readability's retry ladder: each step drops one heuristic.
const Flags = struct {
    unlikelys: bool,
    weight_classes: bool,
    clean: bool,
};

const attempts = [_]Flags{
    .{ .unlikelys = true, .weight_classes = true, .clean = true },
    .{ .unlikelys = false, .weight_classes = true, .clean = true },
    .{ .unlikelys = false, .weight_classes = false, .clean = true },
    .{ .unlikelys = false, .weight_classes = false, .clean = false },
};

/// The nodes under `root` to skip so that only the main content renders,
/// or null when no attempt found enough content. The set is allocated in
/// `allocator`; the scratch is not.
pub fn select(allocator: Allocator, root: *Node, strip_: RenderTree.Strip, frame: *Frame) !?*const RenderTree.PruneSet {
    // The walk measures what the flags alone render.
    var strip = strip_;
    strip.clutter = false;

    var arena_state: std.heap.ArenaAllocator = .init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    for (attempts, 0..) |flags, i| {
        _ = arena_state.reset(.retain_capacity);
        var pass: Pass = .{
            .arena = arena,
            .frame = frame,
            .root = root,
            .flags = flags,
            .tree = .{ .frame = frame, .state = .{ .root = root, .strip = strip } },
        };
        const selected = try pass.run() orelse continue;
        const chars = pass.selectedText(selected);
        log.debug(.browser, "strip clutter", .{ .attempt = i, .chars = chars, .total = pass.total, .root = describe(selected) });
        if (chars < char_threshold) {
            continue;
        }
        try pass.pruneBeside(selected);
        const pruned = try allocator.create(RenderTree.PruneSet);
        pruned.* = try pass.pruned.clone(allocator);
        return pruned;
    }
    log.info(.browser, "strip clutter fallback", .{});
    return null;
}

const Rule = enum { unlikely, role, sibling, tag, header, share, weight, words, mix };

// For the debug log: "tag.class#id", truncated.
fn describe(node: *Node) []const u8 {
    const el = node.is(Element) orelse return @tagName(node._type);
    const S = struct {
        threadlocal var buf: [96]u8 = undefined;
    };
    return std.fmt.bufPrint(&S.buf, "{s}.{s}#{s}", .{ @tagName(el.getTag()), el.getClassName() orelse "", el.getId() orelse "" }) catch S.buf[0..];
}

const Stats = struct {
    // Rendered text, whitespace collapsed, and the part of it inside links,
    // headings and lists.
    text: usize = 0,
    link: usize = 0,
    heading: usize = 0,
    list: usize = 0,
    // Text inside readability's "textish" tags (span, li, td, p, div...).
    textish: usize = 0,
    commas: usize = 0,

    // Descendant counts.
    p: u32 = 0,
    img: u32 = 0,
    li: u32 = 0,
    input: u32 = 0,
    embeds: u32 = 0,
    rows: u32 = 0,
    cells: u32 = 0,
    th: u32 = 0,
    tables: u32 = 0,
    // A <caption>/<col>/<colgroup>/<thead>/<tfoot> descendant: markup only a
    // real data table carries.
    table_parts: bool = false,
    has_data_table: bool = false,

    // A direct child that keeps a <div> from reading as a paragraph.
    block_child: bool = false,
    data_table: bool = false,

    candidate: bool = false,
    score: f32 = 0,

    fn add(self: *Stats, other: *const Stats) void {
        self.text += other.text;
        self.link += other.link;
        self.heading += other.heading;
        self.list += other.list;
        self.textish += other.textish;
        self.commas += other.commas;
        self.p += other.p;
        self.img += other.img;
        self.li += other.li;
        self.input += other.input;
        self.embeds += other.embeds;
        self.rows += other.rows;
        self.cells += other.cells;
        self.th += other.th;
        self.tables += other.tables;
        self.table_parts = self.table_parts or other.table_parts;
        self.has_data_table = self.has_data_table or other.has_data_table;
    }

    fn sub(self: *Stats, other: *const Stats) void {
        self.text -= other.text;
        self.link -= other.link;
        self.heading -= other.heading;
        self.list -= other.list;
        self.textish -= other.textish;
        self.commas -= other.commas;
        self.p -= other.p;
        self.img -= other.img;
        self.li -= other.li;
        self.input -= other.input;
        self.embeds -= other.embeds;
        self.rows -= other.rows;
        self.cells -= other.cells;
        self.th -= other.th;
        self.tables -= other.tables;
    }

    // What the element itself contributes to its ancestors' counts.
    fn countSelf(self: *Stats, tag: Element.Tag, delta: i2) void {
        const field = switch (tag) {
            .p => &self.p,
            .img => &self.img,
            .li => &self.li,
            .input => &self.input,
            .iframe, .object, .embed, .video, .audio => &self.embeds,
            .tr => &self.rows,
            .td => &self.cells,
            .th => &self.th,
            .table => &self.tables,
            else => return,
        };
        if (delta > 0) field.* += 1 else field.* -= 1;
    }

    fn linkDensity(self: *const Stats) f32 {
        if (self.text == 0) return 0;
        return @as(f32, @floatFromInt(self.link)) / @as(f32, @floatFromInt(self.text));
    }

    fn ratio(part: usize, whole: usize) f32 {
        if (whole == 0) return 0;
        return @as(f32, @floatFromInt(part)) / @as(f32, @floatFromInt(whole));
    }
};

// Ancestor state that readability reads through hasAncestorTag.
const Ctx = struct {
    in_link: bool = false,
    hash_link: bool = false,
    in_heading: bool = false,
    in_list: bool = false,
    in_code: bool = false,
    in_table: bool = false,
    in_figure: bool = false,
    in_data_table: bool = false,
};

const Pass = struct {
    arena: Allocator,
    frame: *Frame,
    root: *Node,
    flags: Flags,
    tree: RenderTree,
    total: usize = 0,
    stats: std.AutoHashMapUnmanaged(*Element, *Stats) = .{},
    pruned: RenderTree.PruneSet = .{},
    candidates: std.ArrayListUnmanaged(*Element) = .empty,

    fn run(self: *Pass) !?*Node {
        var root_stats: Stats = .{};
        switch (self.root._type) {
            .document, .document_fragment => {
                var it = self.tree.children(self.root, false);
                while (it.next()) |child| {
                    try self.walkChild(child, .{}, &root_stats);
                }
            },
            else => if (self.tree.classify(self.root, .{})) |child| {
                try self.walkChild(child, .{}, &root_stats);
            },
        }
        self.total = root_stats.text;

        const top = self.topCandidate() orelse return null;
        const candidate = self.refine(top);
        log.debug(.browser, "clutter candidate", .{ .top = describe(top.asNode()), .score = self.score(top) });
        log.debug(.browser, "clutter refined", .{ .el = describe(candidate.asNode()) });
        const tag = candidate.getTag();
        if (tag == .body or tag == .html) {
            // readability wraps the whole body here; that is no selection.
            return null;
        }
        const selected = self.withSiblings(candidate);
        try self.clean(selected, .{});
        return selected;
    }

    // --- stats -------------------------------------------------------------

    fn walkChild(self: *Pass, child: RenderTree.Child, ctx: Ctx, parent: *Stats) !void {
        switch (child.what) {
            .text => |text| {
                const m = measureText(text);
                parent.text += m.len;
                parent.commas += m.commas;
                if (ctx.in_link) {
                    // In-page links count for less, as in readability.
                    parent.link += if (ctx.hash_link) m.len * 3 / 10 else m.len;
                }
                if (ctx.in_heading) parent.heading += m.len;
                if (ctx.in_list) parent.list += m.len;
            },
            .element => |d| {
                const el = child.node.subtype(Element);
                const tag = el.getTag();
                if (self.isUnlikely(el, tag, ctx)) |rule| {
                    try self.pruned.put(self.arena, el.asNode(), {});
                    log.debug(.browser, "clutter prune", .{ .rule = rule, .el = describe(el.asNode()) });
                    return;
                }

                const st = try self.arena.create(Stats);
                st.* = .{};
                try self.stats.put(self.arena, el, st);

                var inner = ctx;
                switch (tag) {
                    .anchor => {
                        inner.in_link = true;
                        const href = el.getAttributeSafe(comptime .wrap("href")) orelse "";
                        inner.hash_link = href.len > 0 and href[0] == '#';
                    },
                    .h1, .h2, .h3, .h4, .h5, .h6 => inner.in_heading = true,
                    .ul, .ol => inner.in_list = true,
                    .code, .pre => inner.in_code = true,
                    .table => inner.in_table = true,
                    .figure => inner.in_figure = true,
                    // readability's _markDataTables descendants: a header row
                    // built from <td> is still a header row.
                    .caption, .col, .colgroup, .tfoot, .thead => st.table_parts = true,
                    else => {},
                }

                if (el.is(Slot)) |slot| {
                    var it = self.tree.slotted(slot);
                    while (it.next()) |c| {
                        try self.walkChild(c, inner, st);
                    }
                } else {
                    const boxed = d == .flex or d == .grid;
                    var it = self.tree.content(el, boxed);
                    while (it.next()) |c| {
                        try self.walkChild(c, inner, st);
                    }
                }

                if (tag == .table) {
                    st.data_table = isDataTable(el, st);
                    st.has_data_table = st.has_data_table or st.data_table;
                }
                if (isParagraphLike(tag, st)) {
                    try self.scoreParagraph(el, st);
                }

                parent.add(st);
                parent.countSelf(countedAs(tag, st), 1);
                parent.textish += if (isTextish(tag)) st.text else st.textish;
                if (blocksParagraph(tag)) {
                    parent.block_child = true;
                }
            },
        }
    }

    fn isUnlikely(self: *const Pass, el: *Element, tag: Element.Tag, ctx: Ctx) ?Rule {
        if (self.flags.unlikelys == false) return null;
        if (tag != .body and tag != .anchor and !ctx.in_table and !ctx.in_code) {
            const names = self.classAndId(el);
            if (containsAny(names, &unlikely) and !containsAny(names, &maybe_candidate)) {
                return .unlikely;
            }
        }
        if (hasRole(el, &.{ "menu", "menubar", "complementary", "navigation", "alert", "alertdialog", "dialog" })) {
            return .role;
        }
        return null;
    }

    fn scoreParagraph(self: *Pass, el: *Element, st: *Stats) !void {
        if (st.text < 25) return;
        const points: f32 = 1 + @as(f32, @floatFromInt(st.commas)) + @min(@as(f32, @floatFromInt(st.text / 100)), 3);

        var level: usize = 0;
        var ancestor = self.parentElement(el);
        while (ancestor) |a| : (ancestor = self.parentElement(a)) {
            if (level == 5) break;
            const ast = self.stats.get(a) orelse break;
            if (ast.candidate == false) {
                ast.candidate = true;
                ast.score = tagScore(a.getTag()) + self.classWeight(a);
                try self.candidates.append(self.arena, a);
            }
            const divider: f32 = switch (level) {
                0 => 1,
                1 => 2,
                else => @floatFromInt(level * 3),
            };
            ast.score += points / divider;
            level += 1;
        }
    }

    // --- candidate ---------------------------------------------------------

    fn topCandidate(self: *Pass) ?*Element {
        var top: ?*Element = null;
        var top_score: f32 = 0;
        for (self.candidates.items) |el| {
            const st = self.stats.get(el).?;
            st.score *= 1 - st.linkDensity();
            if (top == null or st.score > top_score) {
                top = el;
                top_score = st.score;
            }
        }
        if (log.enabled(.browser, .debug)) {
            for (self.candidates.items) |el| {
                const st = self.stats.get(el).?;
                if (st.score >= top_score * 0.2) {
                    log.debug(.browser, "clutter score", .{ .el = describe(el.asNode()), .score = st.score });
                }
            }
        }
        return top;
    }

    fn score(self: *const Pass, el: *Element) f32 {
        const st = self.stats.get(el) orelse return 0;
        return if (st.candidate) st.score else 0;
    }

    /// readability's walk up from the top candidate: an ancestor shared by
    /// three strong alternatives, then better-scoring parents, then
    /// single-child wrappers.
    fn refine(self: *const Pass, top: *Element) *Element {
        var candidate = top;
        const top_score = self.score(top);

        var parent = self.parentElement(candidate);
        while (parent) |p| : (parent = self.parentElement(p)) {
            if (p.getTag() == .body) break;
            var shared: usize = 0;
            for (self.candidates.items) |alt| {
                if (alt == top or self.score(alt) < top_score * 0.75) continue;
                if (self.isAncestor(p, alt)) shared += 1;
            }
            if (shared >= 3) {
                candidate = p;
                break;
            }
        }

        var last = self.score(candidate);
        const threshold = last / 3;
        parent = self.parentElement(candidate);
        while (parent) |p| : (parent = self.parentElement(p)) {
            if (p.getTag() == .body) break;
            const ps = self.score(p);
            if (ps == 0) continue;
            if (ps < threshold) break;
            if (ps > last) {
                candidate = p;
                break;
            }
            last = ps;
        }

        parent = self.parentElement(candidate);
        while (parent) |p| : (parent = self.parentElement(p)) {
            if (p.getTag() == .body) break;
            if (self.renderedElementCount(p) != 1) break;
            candidate = p;
        }
        return candidate;
    }

    /// The candidate's parent when siblings qualify (the rest pruned), else
    /// the candidate itself.
    fn withSiblings(self: *Pass, candidate: *Element) *Node {
        const parent = self.parentElement(candidate) orelse return candidate.asNode();
        const top_score = self.score(candidate);
        const threshold = @max(10, top_score * 0.2);
        const class = candidate.getClassName() orelse "";

        var kept: usize = 0;
        // Raw children, as in pruneBeside: a node RenderTree never yields has
        // to enter the set too, or only the HTML dump keeps it.
        var kid = parent.asNode().firstChild();
        while (kid) |k| : (kid = k.nextSibling()) {
            const sibling = k.is(Element) orelse {
                // Loose text between siblings is not part of any of them.
                self.pruned.put(self.arena, k, {}) catch {};
                continue;
            };
            if (sibling == candidate) continue;
            // No stats: it never rendered, or the walk already pruned it as
            // unlikely. Neither is content.
            const st = self.stats.get(sibling) orelse {
                self.pruned.put(self.arena, k, {}) catch {};
                continue;
            };

            var keep = false;
            var bonus: f32 = 0;
            if (class.len > 0 and std.mem.eql(u8, class, sibling.getClassName() orelse "")) {
                bonus = top_score * 0.2;
            }
            if (self.score(sibling) + bonus >= threshold) {
                keep = true;
            } else if (countedAs(sibling.getTag(), st) == .p) {
                const density = st.linkDensity();
                if (st.text > 80 and density < 0.25) {
                    keep = true;
                } else if (st.text > 0 and st.text < 80 and density == 0 and self.endsSentence(sibling)) {
                    keep = true;
                }
            }
            if (keep) {
                kept += 1;
            } else {
                self.pruned.put(self.arena, sibling.asNode(), {}) catch {};
                log.debug(.browser, "clutter prune", .{ .rule = Rule.sibling, .el = describe(sibling.asNode()) });
            }
        }
        return if (kept > 0) parent.asNode() else candidate.asNode();
    }

    /// Everything beside the path from the dump root down to `selected`:
    /// each ancestor keeps only the child on the path.
    ///
    /// Raw siblings, not rendering ones: the HTML dump walks the DOM and
    /// leaves out only what this set holds, so a <script> or a [hidden]
    /// banner beside the path has to be in it to be left out of that dump
    /// too. The renderers that go through RenderTree never see those.
    fn pruneBeside(self: *Pass, selected: *Node) !void {
        var current = selected;
        while (current != self.root) {
            if (current.is(Node.ShadowRoot)) |shadow| {
                // A shadow tree renders in place of its host, and the host's
                // light children are not beside it: they render through its
                // slots, inside the selection.
                current = shadow.getHost().asNode();
                continue;
            }
            const parent = current.parentNode() orelse return;
            var child = parent.firstChild();
            while (child) |c| : (child = c.nextSibling()) {
                if (c == current) continue;
                // <head> sits beside <body> but holds no content of its own,
                // and the HTML dump still needs its title and base.
                if (c.is(Element)) |el| if (el.getTag() == .head) continue;
                try self.pruned.put(self.arena, c, {});
            }
            current = parent;
        }
    }

    // --- cleaning ----------------------------------------------------------

    /// Post-order so a pruned inner block no longer counts against its
    /// container, as readability's reverse-order removal achieves.
    fn clean(self: *Pass, node: *Node, ctx: Ctx) !void {
        var it = self.tree.children(node, false);
        while (it.next()) |child| {
            if (child.what != .element) continue;
            const el = child.node.subtype(Element);
            if (self.pruned.contains(child.node)) continue;
            const st = self.stats.get(el) orelse continue;
            const tag = el.getTag();

            var inner = ctx;
            switch (tag) {
                .code, .pre => inner.in_code = true,
                .figure => inner.in_figure = true,
                .table => inner.in_data_table = ctx.in_data_table or st.data_table,
                else => {},
            }
            const content = if (el.hostedShadowRoot(self.frame)) |shadow| shadow.asNode() else el.asNode();
            try self.clean(content, inner);

            if (self.shouldPrune(el, tag, st, inner)) |rule| {
                try self.prune(el, tag, st);
                log.debug(.browser, "clutter prune", .{ .rule = rule, .el = describe(el.asNode()) });
            }
        }
    }

    fn prune(self: *Pass, el: *Element, tag: Element.Tag, st: *const Stats) !void {
        try self.pruned.put(self.arena, el.asNode(), {});
        const textish: usize = if (isTextish(tag)) st.text else st.textish;
        var ancestor = self.parentElement(el);
        while (ancestor) |a| : (ancestor = self.parentElement(a)) {
            const ast = self.stats.get(a) orelse break;
            ast.sub(st);
            ast.countSelf(countedAs(tag, st), -1);
            ast.textish -= textish;
        }
    }

    fn shouldPrune(self: *const Pass, el: *Element, tag: Element.Tag, st: *const Stats, ctx: Ctx) ?Rule {
        switch (tag) {
            .aside, .footer, .object, .embed, .iframe, .input, .textarea, .select, .button => return .tag,
            .h1, .h2 => return if (self.classWeight(el) < 0) .header else null,
            else => {},
        }

        if (st.text < 500 and isShareElement(self.classAndId(el))) {
            return .share;
        }

        if (self.flags.clean == false) return null;
        switch (tag) {
            .form, .fieldset, .table, .ul, .ol => {},
            // A <div> without block children is a paragraph to readability.
            .div => if (st.block_child == false) return null,
            else => return null,
        }
        if (ctx.in_data_table or ctx.in_code or st.has_data_table) return null;

        const weight = self.classWeight(el);
        if (weight < 0) {
            return .weight;
        }
        if (st.commas >= 10) return null;
        if (st.text <= 24 and self.isAdOrLoading(el)) {
            return .words;
        }

        const is_list = tag == .ul or tag == .ol or Stats.ratio(st.list, st.text) > 0.9;
        const density = st.linkDensity();
        const heading_density = Stats.ratio(st.heading, st.text);
        const p: f32 = @floatFromInt(st.p);
        const img: f32 = @floatFromInt(st.img);

        const remove =
            (!ctx.in_figure and st.img > 1 and p / img < 0.5) or
            // readability subtracts 100 from the li count first.
            (!is_list and st.li > st.p + 100) or
            (st.input > st.p / 3) or
            (!is_list and !ctx.in_figure and heading_density < 0.9 and st.text < 25 and (st.img == 0 or st.img > 2) and density > 0) or
            (!is_list and weight < 25 and density > 0.2) or
            (weight >= 25 and density > 0.5) or
            (st.embeds == 1 and st.text < 75) or st.embeds > 1 or
            (st.img == 0 and st.textish == 0);

        if (remove and is_list and self.isImageList(el, st)) {
            return null;
        }
        return if (remove) .mix else null;
    }

    // A list whose every item is one image stays.
    fn isImageList(self: *const Pass, el: *Element, st: *const Stats) bool {
        var it = self.tree.content(el, false);
        while (it.next()) |child| {
            if (child.what != .element) continue;
            if (self.renderedElementCount(child.node.subtype(Element)) > 1) return false;
        }
        return st.img > 0 and st.img == st.li;
    }

    fn isAdOrLoading(self: *const Pass, el: *Element) bool {
        var buf: [32]u8 = undefined;
        var text = std.mem.trim(u8, self.gatherText(el, &buf), &std.ascii.whitespace);
        for ([_][]const u8{ "...", "\xE2\x80\xA6" }) |ellipsis| {
            if (std.mem.endsWith(u8, text, ellipsis)) text = text[0 .. text.len - ellipsis.len];
        }
        for (ad_words) |w| {
            if (std.ascii.eqlIgnoreCase(text, w)) return true;
        }
        return false;
    }

    fn gatherText(self: *const Pass, el: *Element, buf: []u8) []const u8 {
        var n: usize = 0;
        var it = self.tree.content(el, false);
        while (it.next()) |child| {
            switch (child.what) {
                .text => |text| {
                    for (text) |c| {
                        if (n == buf.len) return buf;
                        buf[n] = c;
                        n += 1;
                    }
                },
                .element => {
                    const inner = self.gatherText(child.node.subtype(Element), buf[n..]);
                    n += inner.len;
                    if (n == buf.len) return buf;
                },
            }
        }
        return buf[0..n];
    }

    // --- helpers -----------------------------------------------------------

    fn parentElement(self: *const Pass, el: *Element) ?*Element {
        const node = el.asNode();
        if (node == self.root) return null;
        const parent = node.parentNode() orelse return null;
        return parent.is(Element);
    }

    fn isAncestor(self: *const Pass, ancestor: *Element, el: *Element) bool {
        var parent = self.parentElement(el);
        while (parent) |p| : (parent = self.parentElement(p)) {
            if (p == ancestor) return true;
        }
        return false;
    }

    fn renderedElementCount(self: *const Pass, el: *Element) usize {
        var n: usize = 0;
        var it = self.tree.content(el, false);
        while (it.next()) |child| {
            if (child.what != .element) continue;
            if (self.pruned.contains(child.node)) continue;
            n += 1;
        }
        return n;
    }

    fn endsSentence(self: *const Pass, el: *Element) bool {
        var last: u8 = 0;
        var it = self.tree.content(el, false);
        while (it.next()) |child| {
            switch (child.what) {
                .text => |text| {
                    const trimmed = std.mem.trimEnd(u8, text, &std.ascii.whitespace);
                    if (trimmed.len > 0) last = trimmed[trimmed.len - 1];
                },
                .element => last = 0,
            }
        }
        return last == '.';
    }

    fn classWeight(self: *const Pass, el: *Element) f32 {
        if (self.flags.weight_classes == false) return 0;
        var weight: f32 = 0;
        inline for (.{ el.getClassName(), el.getId() }) |attr| {
            if (attr) |raw| {
                const name = std.ascii.allocLowerString(self.arena, raw) catch return weight;
                if (isNegative(name)) weight -= 25;
                if (containsAny(name, &positive)) weight += 25;
            }
        }
        return weight;
    }

    // Lowercased "class id", readability's matchString. Never truncated: a
    // framework's <html> class list runs to kilobytes and the escape word
    // can sit anywhere in it.
    fn classAndId(self: *const Pass, el: *Element) []const u8 {
        const class = el.getClassName() orelse "";
        const id = el.getId() orelse "";
        const buf = self.arena.alloc(u8, class.len + 1 + id.len) catch return "";
        _ = std.ascii.lowerString(buf[0..class.len], class);
        buf[class.len] = ' ';
        _ = std.ascii.lowerString(buf[class.len + 1 ..], id);
        return buf;
    }

    /// Text under `node` once the prune set is applied.
    fn selectedText(self: *const Pass, node: *Node) usize {
        var n: usize = 0;
        var it = self.tree.children(node, false);
        while (it.next()) |child| {
            switch (child.what) {
                .text => |text| {
                    if (self.pruned.contains(child.node)) continue;
                    n += measureText(text).len;
                },
                .element => {
                    const el = child.node.subtype(Element);
                    if (self.pruned.contains(child.node)) continue;
                    const content = if (el.hostedShadowRoot(self.frame)) |shadow| shadow.asNode() else el.asNode();
                    n += self.selectedText(content);
                },
            }
        }
        return n;
    }
};

// readability's DIV_TO_P_ELEMS: a <div> with none of these children is a
// paragraph for scoring.
fn blocksParagraph(tag: Element.Tag) bool {
    return switch (tag) {
        .blockquote, .dl, .div, .img, .ol, .p, .pre, .table, .ul => true,
        else => false,
    };
}

// readability's DEFAULT_TAGS_TO_SCORE, plus the <div>s it turns into <p>.
fn isParagraphLike(tag: Element.Tag, st: *const Stats) bool {
    return switch (tag) {
        .section, .h2, .h3, .h4, .h5, .h6, .p, .td, .pre => true,
        .div => st.block_child == false,
        else => false,
    };
}

fn countedAs(tag: Element.Tag, st: *const Stats) Element.Tag {
    return if (tag == .div and st.block_child == false) .p else tag;
}

// readability's textish tags: SPAN, LI, TD and DIV_TO_P_ELEMS.
fn isTextish(tag: Element.Tag) bool {
    return switch (tag) {
        .span, .li, .td, .blockquote, .dl, .div, .img, .ol, .p, .pre, .table, .ul => true,
        else => false,
    };
}

// readability's adWords and loadingWords, matched whole.
const ad_words = [_][]const u8{ "ad", "advertising", "advertisement", "pub", "publicit\xC3\xA9", "werb", "werbung", "\xE5\xB9\xBF\xE5\x91\x8A", "\xD0\xA0\xD0\xB5\xD0\xBA\xD0\xBB\xD0\xB0\xD0\xBC\xD0\xB0", "anuncio", "loading", "\xE6\xAD\xA3\xE5\x9C\xA8\xE5\x8A\xA0\xE8\xBD\xBD", "\xD0\x97\xD0\xB0\xD0\xB3\xD1\x80\xD1\x83\xD0\xB7\xD0\xBA\xD0\xB0", "chargement", "cargando" };

fn tagScore(tag: Element.Tag) f32 {
    return switch (tag) {
        .div => 5,
        .pre, .td, .blockquote => 3,
        .address, .ol, .ul, .dl, .dd, .dt, .li, .form => -3,
        .h1, .h2, .h3, .h4, .h5, .h6, .th => -5,
        else => 0,
    };
}

fn isDataTable(el: *Element, st: *const Stats) bool {
    if (hasRole(el, &.{"presentation"})) return false;
    if (el.getAttributeSafe(comptime .wrap("datatable"))) |v| {
        if (std.mem.eql(u8, v, "0")) return false;
    }
    if (el.getAttributeSafe(comptime .wrap("summary")) != null) return true;
    if (st.th > 0 or st.table_parts) return true;
    if (st.tables > 0) return false;
    const cols = if (st.rows == 0) st.cells else st.cells / st.rows;
    if (st.rows >= 10 or cols > 4) return true;
    return st.rows * cols > 10;
}

const TextMeasure = struct { len: usize, commas: usize };

/// Length as innerText would report it: whitespace runs collapse to one,
/// leading and trailing runs vanish.
fn measureText(text: []const u8) TextMeasure {
    var len: usize = 0;
    var commas: usize = 0;
    var pending_space = false;
    for (text, 0..) |c, i| {
        if (std.ascii.isWhitespace(c)) {
            pending_space = len > 0;
            continue;
        }
        if (pending_space) {
            len += 1;
            pending_space = false;
        }
        len += 1;
        if (c == ',') {
            commas += 1;
        } else if (c == 0xEF and i + 2 < text.len and text[i + 1] == 0xBC and text[i + 2] == 0x8C) {
            commas += 1; // U+FF0C fullwidth comma
        } else if (c == 0xE3 and i + 2 < text.len and text[i + 1] == 0x80 and text[i + 2] == 0x81) {
            commas += 1; // U+3001 ideographic comma
        }
    }
    return .{ .len = len, .commas = commas };
}

// readability's REGEXPS as substring lists, matched on the lowercased
// class and id.
const unlikely = [_][]const u8{ "-ad-", "ai2html", "banner", "breadcrumbs", "combx", "comment", "community", "cover-wrap", "disqus", "extra", "footer", "gdpr", "header", "legends", "menu", "related", "remark", "replies", "rss", "shoutbox", "sidebar", "skyscraper", "social", "sponsor", "supplemental", "ad-break", "agegate", "pagination", "pager", "popup", "yom-remote" };
const maybe_candidate = [_][]const u8{ "and", "article", "body", "column", "content", "main", "shadow" };
const positive = [_][]const u8{ "article", "body", "content", "entry", "hentry", "h-entry", "main", "page", "pagination", "post", "text", "blog", "story" };
const negative = [_][]const u8{ "-ad-", "hidden", "banner", "combx", "comment", "com-", "contact", "footer", "gdpr", "masthead", "media", "meta", "outbrain", "promo", "related", "scroll", "share", "shoutbox", "sidebar", "skyscraper", "sponsor", "shopping", "tags", "widget" };

fn containsAny(haystack: []const u8, needles: []const []const u8) bool {
    for (needles) |needle| {
        if (std.mem.indexOf(u8, haystack, needle) != null) return true;
    }
    return false;
}

fn isNegative(name: []const u8) bool {
    return containsAny(name, &negative) or hasWord(name, "hid");
}

// readability: /(\b|_)(share|sharedaddy)(\b|_)/
fn isShareElement(names: []const u8) bool {
    return hasWord(names, "share") or hasWord(names, "sharedaddy");
}

fn hasWord(haystack: []const u8, word: []const u8) bool {
    var start: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, start, word)) |i| : (start = i + 1) {
        const before = i == 0 or !std.ascii.isAlphanumeric(haystack[i - 1]);
        const end = i + word.len;
        const after = end == haystack.len or !std.ascii.isAlphanumeric(haystack[end]);
        if (before and after) return true;
    }
    return false;
}

// ARIA `role` is a space-separated fallback list; the first token wins.
fn hasRole(el: *Element, roles: []const []const u8) bool {
    const attr = el.getAttributeSafe(comptime .wrap("role")) orelse return false;
    var it = std.mem.tokenizeAny(u8, attr, " \t\n\r");
    const role = it.next() orelse return false;
    for (roles) |candidate| {
        if (std.ascii.eqlIgnoreCase(role, candidate)) return true;
    }
    return false;
}

const testing = @import("../testing.zig");
const markdown = @import("markdown.zig");
const dump = @import("dump.zig");

const prose = "Sourdough is a bread made by the fermentation of dough using wild lactobacillaceae and yeast, which give it a mildly sour taste. The lactic acid produced by the bacteria gives it a longer shelf life than breads made with baker's yeast. ";

test "clutter: keeps the article, drops the teaser list and share bar" {
    const html =
        "<div class=\"teasers\"><div><a href=\"/1\">Ten things to know</a></div><div><a href=\"/2\">What happened next</a></div><div><a href=\"/3\">More for you</a></div><div><a href=\"/4\">Trending now</a></div></div>" ++
        "<div class=\"article\"><h1>Sourdough</h1><div class=\"share\"><a href=\"/s\">Share on X</a> <a href=\"/f\">Share on Facebook</a></div>" ++
        "<p>" ++ prose ++ "</p><p>" ++ prose ++ "</p><p>" ++ prose ++ "</p></div>";
    const out = try extract(html);
    try testing.expectEqual(true, std.mem.indexOf(u8, out, "wild lactobacillaceae") != null);
    try testing.expectEqual(true, std.mem.indexOf(u8, out, "# Sourdough") != null);
    try testing.expectEqual(null, std.mem.indexOf(u8, out, "Trending now"));
    try testing.expectEqual(null, std.mem.indexOf(u8, out, "Share on"));
}

test "clutter: too little text falls back" {
    const out = try extract("<div><p>A short note.</p></div><div><a href=\"/1\">one</a> <a href=\"/2\">two</a></div>");
    try testing.expectEqual(true, std.mem.indexOf(u8, out, "A short note.") != null);
    try testing.expectEqual(true, std.mem.indexOf(u8, out, "two") != null);
}

test "clutter: retry ladder rescues content in an unlikely class" {
    const out = try extract("<div class=\"sidebar\"><p>" ++ prose ++ "</p><p>" ++ prose ++ "</p><p>" ++ prose ++ "</p></div><div><a href=\"/x\">elsewhere</a></div>");
    try testing.expectEqual(true, std.mem.indexOf(u8, out, "wild lactobacillaceae") != null);
    try testing.expectEqual(null, std.mem.indexOf(u8, out, "elsewhere"));
}

test "clutter: qualifying sibling paragraphs come along" {
    const out = try extract("<div id=\"wrap\"><div class=\"body\"><p>" ++ prose ++ "</p><p>" ++ prose ++ "</p></div><p>" ++ prose ++ "</p><div class=\"nav\"><a href=\"/a\">a</a> <a href=\"/b\">b</a> <a href=\"/c\">c</a></div></div>");
    try testing.expectEqual(3, std.mem.count(u8, out, "wild lactobacillaceae"));
    try testing.expectEqual(null, std.mem.indexOf(u8, out, "[a]"));
}

test "clutter: the prune set lives in the caller's allocator" {
    const frame = try testing.createFrame();
    defer testing.test_session.closeAllPages();
    const doc = frame.window._document;
    const div = try doc.createElement("div", null, frame);
    try Frame.parse.htmlAsChildren(frame, div.asNode(), "<div class=\"article\"><p>" ++ prose ++ "</p><p>" ++ prose ++ "</p><p>" ++ prose ++ "</p></div><div class=\"share\"><a href=\"/s\">Share</a></div>");

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const state = try RenderTree.resolve(arena.allocator(), div.asNode(), .{ .clutter = true }, frame);
    try testing.expectEqual(true, state.strip.clutter);
    try testing.expectEqual(true, state.pruned.?.contains(div.lastElementChild().?.asNode()));

    // A plain dump of the same tree is unaffected.
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try markdown.dump(.{ .root = div.asNode() }, .{}, &aw.writer, frame);
    try testing.expectEqual(true, std.mem.indexOf(u8, aw.written(), "Share") != null);

    // Too little text: no set, no clutter.
    const second = try RenderTree.resolve(arena.allocator(), div.lastElementChild().?.asNode(), .{ .clutter = true }, frame);
    try testing.expectEqual(false, second.strip.clutter);
    try testing.expectEqual(null, second.pruned);
}

test "clutter: the HTML dump leaves out what the markdown dump does" {
    const frame = try testing.createFrame();
    defer testing.test_session.closeAllPages();

    const doc = frame.window._document;
    const div = try doc.createElement("div", null, frame);
    try Frame.parse.htmlAsChildren(frame, div.asNode(), "<script>window.__DATA__ = 1;</script>" ++
        "<div hidden>Accept our cookies</div>" ++
        "<div class=\"teasers\"><div><a href=\"/1\">Ten things to know</a></div><div><a href=\"/2\">Trending now</a></div></div>" ++
        "<div class=\"article\"><p>" ++ prose ++ "</p><p>" ++ prose ++ "</p><p>" ++ prose ++ "</p></div>");

    const state = try RenderTree.resolve(testing.arena_allocator, div.asNode(), .{ .clutter = true }, frame);
    var aw: std.Io.Writer.Allocating = .init(testing.arena_allocator);
    try dump.render(state, .{}, &aw.writer, frame);
    const out = aw.written();

    try testing.expectEqual(true, std.mem.indexOf(u8, out, "wild lactobacillaceae") != null);
    // Neither node renders, so RenderTree never yields either one; the set
    // still has to hold them, because the HTML dump walks the DOM itself.
    try testing.expectEqual(null, std.mem.indexOf(u8, out, "__DATA__"));
    try testing.expectEqual(null, std.mem.indexOf(u8, out, "Accept our cookies"));
    try testing.expectEqual(null, std.mem.indexOf(u8, out, "Trending now"));
}

fn extract(html: []const u8) ![]const u8 {
    const frame = try testing.createFrame();
    defer testing.test_session.closeAllPages();

    const doc = frame.window._document;
    const div = try doc.createElement("div", null, frame);
    try Frame.parse.htmlAsChildren(frame, div.asNode(), html);

    const state = try RenderTree.resolve(testing.arena_allocator, div.asNode(), .{ .clutter = true }, frame);
    var aw: std.Io.Writer.Allocating = .init(testing.arena_allocator);
    try markdown.dump(state, .{}, &aw.writer, frame);
    return aw.written();
}
