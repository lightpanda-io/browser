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

const Frame = @import("Frame.zig");
const StyleManager = @import("StyleManager.zig");

const Node = @import("webapi/Node.zig");
const Element = @import("webapi/Element.zig");
const TreeWalker = @import("webapi/TreeWalker.zig");
const Slot = @import("webapi/element/html/Slot.zig");

const dump_html = @import("dump.zig");
const isAllWhitespace = @import("../string.zig").isAllWhitespace;
pub const Strip = dump_html.Opts.Strip;

const RenderTree = @This();

frame: *Frame,
root: *Node,
strip: Strip = .{},

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
pub const Children = struct {
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

pub const ClassifyOpts = struct {
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
        if (el.asNode() != self.root) return null;
        return .other;
    };
    if (dump_html.shouldStripElement(el, self.strip, self.frame)) return null;
    if (!is_slotted and el.getAttributeSafe(comptime .wrap("slot")) != null) return null;
    return d;
}

/// The element's own display when it renders; null when it doesn't. Own
/// state only: ancestors are handled by not descending into them.
fn visibleDisplay(el: *Element, frame: *Frame) ?StyleManager.Display {
    const tag = el.getTag();
    if (tag.isMetadata() or tag == .svg) {
        return null;
    }
    const d = frame._style_manager.display(el, .scan);
    if (d == .none) {
        return null;
    }
    if (el.getAttributeSafe(comptime .wrap("aria-hidden"))) |v| {
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

pub const ContentInfo = struct {
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
