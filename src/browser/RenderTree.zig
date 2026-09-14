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

const Frame = @import("Frame.zig");
const StyleManager = @import("StyleManager.zig");

const Node = @import("webapi/Node.zig");
const Element = @import("webapi/Element.zig");
const TreeWalker = @import("webapi/TreeWalker.zig");
const Slot = @import("webapi/element/html/Slot.zig");

const dump_html = @import("dump.zig");
const clutter = @import("clutter.zig");
const isAllWhitespace = @import("../string.zig").isAllWhitespace;

const log = lp.log;
pub const Strip = dump_html.Opts.Strip;
pub const PruneSet = std.AutoHashMapUnmanaged(*Node, void);

const RenderTree = @This();

// What / how we're going to render.
pub const State = struct {
    root: *Node, // the not to start from
    strip: Strip = .{}, // the strip flag we'll use
    pruned: ?*const PruneSet = null, // the nodes that'll get pruned
};

state: State,
frame: *Frame,

pub const Child = struct {
    node: *Node,
    what: union(enum) {
        element: StyleManager.Display,
        text: []const u8,
    },
    // flex/grid items are separate boxes however inline their tags
    // are, and the whitespace between them doesn't render.
    separated: bool,
};

/// The rendering children of one parent, in tree order.
const Children = struct {
    boxed: bool,
    yielded: bool = false,
    next_node: ?*Node,
    tree: *const RenderTree,

    pub fn next(self: *Children) ?Child {
        while (self.next_node) |node| {
            self.next_node = node.nextSibling();
            var child = self.tree.classify(node, .{ .boxed = self.boxed }) orelse continue;
            child.separated = self.boxed and self.yielded;
            self.yielded = true;
            return child;
        }
        return null;
    }
};

/// A <slot>'s assigned light-DOM nodes, or its own children as fallback.
pub const Slotted = struct {
    tree: *const RenderTree,
    assigned: []const *Node,
    fallback: Children,

    pub fn next(self: *Slotted) ?Child {
        while (self.assigned.len > 0) {
            const node = self.assigned[0];
            self.assigned = self.assigned[1..];
            return self.tree.classify(node, .{ .slotted = true }) orelse continue;
        }
        return self.fallback.next();
    }
};

pub fn children(self: *const RenderTree, parent: *Node, boxed: bool) Children {
    return .{ .tree = self, .next_node = parent.firstChild(), .boxed = boxed };
}

/// An element's content in the composed tree: a shadow host renders its
/// shadow tree in place of its light-DOM children (those are visible only
/// through <slot>). Applies to open and closed roots alike.
pub fn content(self: *const RenderTree, el: *Element, boxed: bool) Children {
    const parent = if (el.hostedShadowRoot(self.frame)) |shadow| shadow.asNode() else el.asNode();
    return self.children(parent, boxed);
}

pub fn slotted(self: *const RenderTree, slot: *Slot) Slotted {
    const assigned = slot.assignedNodes(null, self.frame) catch &.{};
    return .{
        .tree = self,
        .assigned = assigned,
        // Only consulted when nothing is assigned.
        .fallback = self.children(slot.asNode(), false),
    };
}

const ClassifyOpts = struct {
    boxed: bool = false,
    // Reached through a <slot>'s assignment: the element's own `slot`
    // attribute then no longer excludes it.
    slotted: bool = false,
};

/// How `node` renders, or null when it doesn't.
pub fn classify(self: *const RenderTree, node: *Node, opts: ClassifyOpts) ?Child {
    if (node.is(Element)) |el| {
        const d = self.display(el, opts.slotted) orelse return null;
        return .{ .node = node, .what = .{ .element = d }, .separated = false };
    }
    const text_node = node.is(Node.CData.Text) orelse return null;
    if (self.state.pruned) |set| {
        if (set.contains(node)) {
            return null;
        }
    }
    var text = text_node.ownData();
    if (opts.boxed) {
        text = std.mem.trim(u8, text, &std.ascii.whitespace);
        if (text.len == 0) return null;
    } else if (node.nextSibling() == null) {
        // The newline before </pre> isn't content.
        if (node.parentNode()) |parent| {
            if (parent.is(Element)) |parent_el| {
                if (parent_el.getTag() == .pre) {
                    text = std.mem.trimEnd(u8, text, " \t\r\n");
                }
            }
        }
    }
    return .{ .node = node, .what = .{ .text = text }, .separated = false };
}

fn display(self: *const RenderTree, el: *Element, is_slotted: bool) ?StyleManager.Display {
    const d = visibleDisplay(el, self.frame) orelse {
        if (el.asNode() != self.state.root) {
            return null;
        }
        return .other;
    };
    if (dump_html.shouldStripElement(el, self.state.strip, self.state.pruned, self.frame)) {
        return null;
    }
    if (!is_slotted and el.getSlot() != null) return null;
    return d;
}

/// The element's own display when it renders; null when it doesn't. Own
/// state only: ancestors are handled by not descending into them.
fn visibleDisplay(el: *Element, frame: *Frame) ?StyleManager.Display {
    const tag = el.getTag();
    if (tag.isMetadata() or tag == .svg) {
        return null;
    }
    const d = frame._style_manager.display(el);
    if (d == .none) {
        return null;
    }
    if (el.getAttributeInterned("aria-hidden")) |v| {
        if (std.ascii.eqlIgnoreCase(v, "true")) return null;
    }
    return d;
}

fn isVisibleElement(el: *Element, frame: *Frame) bool {
    return visibleDisplay(el, frame) != null;
}

fn isSignificantText(node: *Node) bool {
    const text = node.is(Node.CData.Text) orelse return false;
    return !isAllWhitespace(text.ownData());
}

fn isLayoutBlock(tag: Element.Tag) bool {
    return switch (tag) {
        .main, .section, .article, .nav, .aside, .header, .footer, .div, .ul, .ol => true,
        else => false,
    };
}

/// An anchor sitting among element-only siblings of a layout block (nav
/// bars, post lists) reads as its own line rather than inline text.
pub fn isStandaloneAnchor(el: *Element, frame: *Frame) bool {
    const node = el.asNode();
    const parent = node.parentNode() orelse return false;
    const parent_el = parent.is(Element) orelse return false;

    if (!isLayoutBlock(parent_el.getTag())) {
        return false;
    }

    var prev = node.previousSibling();
    while (prev) |p| : (prev = p.previousSibling()) {
        if (isSignificantText(p)) {
            return false;
        }
        if (p.is(Element)) |pe| {
            if (isVisibleElement(pe, frame)) {
                break;
            }
        }
    }

    var next = node.nextSibling();
    while (next) |n| : (next = n.nextSibling()) {
        if (isSignificantText(n)) {
            return false;
        }
        if (n.is(Element)) |ne| {
            if (isVisibleElement(ne, frame)) {
                break;
            }
        }
    }

    return true;
}

/// Decides once, before rendering, what a dump of `root` renders: the strip
/// bits that survive their safeguards and, for clutter, the prune set.
/// Every dump entry point calls this and renders the result. The prune set
/// lives in `allocator` for as long as the dump.
pub fn resolve(allocator: std.mem.Allocator, root: *Node, requested_strip: Strip, frame: *Frame) !State {
    var strip = requested_strip;
    if (strip.clutter) {
        // The shell strip is the floor the selection stands on.
        strip.shell = true;
        strip.invisible = true;
    }
    strip = resolveShell(root, strip, frame);
    if (strip.clutter) {
        if (try clutter.select(allocator, root, strip, frame)) |pruned| {
            return .{ .root = root, .strip = strip, .pruned = pruned };
        }
        strip.clutter = false;
    }
    return .{ .root = root, .strip = strip };
}

/// Shell stripping is undone when it would remove most of the content. Better
/// to leave too much in than to strip too muchout. Non-link text is
/// the measure (nav and footer text is mostly links); a page with none is
/// judged on all of its text.
fn resolveShell(root: *Node, strip: Strip, frame: *Frame) Strip {
    if (strip.shell == false) {
        return strip;
    }

    var render_with_shell = strip;
    render_with_shell.shell = false;

    var m: Measure = .{};
    const tree: RenderTree = .{ .frame = frame, .state = .{ .root = root, .strip = render_with_shell } };
    tree.measure(root, .{}, &m);

    const total, const shell = if (m.prose > 0) .{ m.prose, m.shell_prose } else .{ m.all, m.shell_all };
    const kept = total - shell;
    if (kept * shell_undo_ratio < total) {
        log.info(.browser, "strip shell undone", .{ .kept = kept, .total = total });
        return render_with_shell;
    }
    return strip;
}

/// Undo when the shell holds more than this share of the text.
const shell_undo_ratio = 4;

const Measure = struct {
    all: usize = 0,
    prose: usize = 0,
    shell_all: usize = 0,
    shell_prose: usize = 0,

    const Where = struct {
        shell: bool = false,
        link: bool = false,
    };

    fn count(self: *Measure, text: []const u8, where: Where) void {
        var n: usize = 0;
        for (text) |c| {
            if (!std.ascii.isWhitespace(c)) {
                n += 1;
            }
        }
        self.all += n;
        if (where.shell) {
            self.shell_all += n;
        }
        if (!where.link) {
            self.prose += n;
            if (where.shell) {
                self.shell_prose += n;
            }
        }
    }
};

fn measure(self: *const RenderTree, node: *Node, where: Measure.Where, m: *Measure) void {
    switch (node._type) {
        .document, .document_fragment => {
            var it = self.children(node, false);
            while (it.next()) |child| {
                self.measureChild(child, where, m);
            }
        },
        else => if (self.classify(node, .{})) |child| {
            self.measureChild(child, where, m);
        },
    }
}

fn measureChild(self: *const RenderTree, child: Child, where: Measure.Where, m: *Measure) void {
    switch (child.what) {
        .text => |text| m.count(text, where),
        .element => |d| {
            const el = child.node.subtype(Element);
            const inner: Measure.Where = .{
                .shell = where.shell or dump_html.isShellElement(el),
                .link = where.link or el.getTag() == .anchor,
            };
            if (el.is(Slot)) |slot| {
                var it = self.slotted(slot);
                while (it.next()) |c| {
                    self.measureChild(c, inner, m);
                }
                return;
            }
            const boxed = d == .flex or d == .grid;
            var it = self.content(el, boxed);
            while (it.next()) |c| {
                self.measureChild(c, inner, m);
            }
        },
    }
}

const ContentInfo = struct {
    has_visible: bool,
    has_block: bool,
};

pub fn analyzeContent(root: *Node, frame: *Frame) ContentInfo {
    var result: ContentInfo = .{ .has_visible = false, .has_block = false };
    var tw = TreeWalker.FullExcludeSelf.init(root, .{});
    while (tw.next()) |node| {
        if (isSignificantText(node)) {
            result.has_visible = true;
            if (result.has_block) {
                return result;
            }
        } else if (node.is(Element)) |el| {
            if (!isVisibleElement(el, frame)) {
                tw.skipChildren();
            } else {
                const tag = el.getTag();
                if (tag == .img) {
                    result.has_visible = true;
                    if (result.has_block) {
                        return result;
                    }
                }
                if (tag.isBlock()) {
                    result.has_block = true;
                    if (result.has_visible) {
                        return result;
                    }
                }
            }
        }
    }
    return result;
}

const testing = @import("../testing.zig");

test "RenderTree: resolveStrip keeps shell when the content holds the text" {
    try testing.expectEqual(true, try shellSurvives(
        \\<nav><a href="/">Home</a><a href="/about">About us</a><a href="/blog">Blog</a></nav><main><p>Some article text.</p></main><footer>Copyright</footer>
    ));
}

test "RenderTree: resolveStrip undoes shell when the shell holds the text" {
    try testing.expectEqual(false, try shellSurvives(
        \\<nav><p>All of the text on this page lives inside a nav element.</p></nav><main>hi</main>
    ));
}

test "RenderTree: resolveStrip judges an all-link page on its links" {
    try testing.expectEqual(false, try shellSurvives(
        \\<nav><a href="/1">one</a><a href="/2">two</a><a href="/3">three</a></nav><p><a href="/x">x</a></p>
    ));
    try testing.expectEqual(true, try shellSurvives(
        \\<nav><a href="/1">one</a></nav><p><a href="/x">a longer list of links</a><a href="/y">and another</a></p>
    ));
}

test "RenderTree: resolveStrip ignores what other strip bits already drop" {
    // The script text is not content; without strip.js it would tip the
    // balance toward keeping the shell.
    try testing.expectEqual(false, try shellSurvives(
        \\<nav><p>All of the text on this page lives inside a nav element.</p></nav><main>hi<script>var a_very_long_script_body_that_is_not_content = 1;</script></main>
    ));
}

fn shellSurvives(html: []const u8) !bool {
    const frame = try testing.createFrame();
    defer testing.test_session.closeAllPages();

    const doc = frame.window._document;
    const div = try doc.createElement("div", null, frame);
    try Frame.parse.htmlAsChildren(frame, div.asNode(), html);

    const strip = resolveShell(div.asNode(), .{ .js = true, .shell = true }, frame);
    // Only the shell bit is ever undone.
    try testing.expectEqual(true, strip.js);
    return strip.shell;
}
