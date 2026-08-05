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

const js = @import("../../js/js.zig");
const Frame = @import("../../Frame.zig");

const Node = @import("../Node.zig");
const Element = @import("../Element.zig");
const TreeWalker = @import("../TreeWalker.zig");
const Selector = @import("../selector/Selector.zig");
const Form = @import("../element/html/Form.zig");

const String = lp.String;

const Mode = enum {
    tag,
    tag_name,
    tag_name_ns,
    class_name,
    name,
    all_elements,
    child_elements,
    child_tag,
    cells,
    select_options,
    selected_options,
    links,
    anchors,
    form,
};

pub const ClassNameFilter = struct {
    names: [][]const u8,
    // getElementsByClassName matches class names ASCII case-insensitively
    // when the document is in quirks mode.
    case_insensitive: bool = false,
};

pub const TagNameNsFilter = struct {
    namespace: ?Element.Namespace, // null means wildcard "*"
    local_name: String,
};

const Filters = union(Mode) {
    tag: Element.Tag,
    tag_name: String,
    tag_name_ns: TagNameNsFilter,
    class_name: ClassNameFilter,
    name: []const u8,
    all_elements,
    child_elements,
    child_tag: Element.Tag,
    cells,
    select_options,
    selected_options,
    links,
    anchors,
    form: struct { form: *Form, form_id: ?[]const u8 },

    fn TypeOf(comptime mode: Mode) type {
        @setEvalBranchQuota(10_000);
        return std.meta.fieldInfo(Filters, mode).type;
    }
};

// Operations on the live DOM can be inefficient. Do we really have to walk
// through the entire tree, filtering out elements we don't care about, every
// time .length is called?
// To improve this, we track the "version" of the DOM (root.version). If the
// version changes between operations, than we have to restart and pay the full
// price.
// But, if the version hasn't changed, then we can leverage other stateful data
// to improve performance. For example, we cache the length property. So once
// we've walked the tree to figure the length, we can re-use the cached property
// if the DOM is unchanged (i.e. if our _cached_version == page.dom_version).
//
// We do something similar for indexed getter (e.g. coll[4]), by preserving the
// last node visited in the tree (implicitly by not resetting the TreeWalker).
// If the DOM version is unchanged and the new index >= the last one, we can do
// not have to reset our TreeWalker. This optimizes the common case of accessing
// the collection via incrementing indexes.
// The element that walk returned is kept alongside its index (see Cursor), so
// re-reading the same index - `coll[i].a` then `coll[i].b` - is free too.

pub fn NodeLive(comptime mode: Mode) type {
    const Filter = Filters.TypeOf(mode);
    const TW = switch (mode) {
        .tag, .tag_name, .tag_name_ns, .class_name, .name, .all_elements, .links, .anchors, .form => TreeWalker.FullExcludeSelf,
        .child_elements, .child_tag, .cells => TreeWalker.Children,
        // A select's options can sit one level down, inside an <optgroup>, so
        // these two walk the subtree and filter on the parent instead.
        .select_options, .selected_options => TreeWalker.FullExcludeSelf,
    };
    return struct {
        _tw: TW,
        _filter: Filter,
        _cursor: ?Cursor,
        _last_length: ?u32,
        _cached_version: usize,

        const Self = @This();

        // The last element we handed out, and the index it was handed out for.
        // The TreeWalker is parked immediately after it, so the next element it
        // yields is the one at `index + 1`. A null cursor means the TreeWalker
        // is back at its start position.
        const Cursor = struct {
            index: usize,
            element: *Element,
        };

        pub fn init(root: *Node, filter: Filter, frame: *Frame) Self {
            return .{
                ._cursor = null,
                ._last_length = null,
                ._filter = filter,
                ._tw = TW.init(root, .{}),
                ._cached_version = frame._page.dom_version,
            };
        }

        pub fn length(self: *Self, frame: *const Frame) u32 {
            if (self.versionCheck(frame)) {
                // the DOM version hasn't changed, use the cached version if
                // we have one
                if (self._last_length) |cached_length| {
                    return cached_length;
                }
                // not ideal, but this can happen if list[x] is called followed
                // by list.length.
                self._tw.reset();
                self._cursor = null;
            }
            // If we're here, it means it's either the first time we're called
            // or the DOM version has changed. Either way, the _tw should be
            // at the start position. It's important that self._cursor == null
            // (which it always should be in these cases), because we're going to
            // reset _tw at the end of this, the cursor should always be null when
            // _tw is reset. Again, this should always be the case, but we're
            // asserting to make sure, else we'll have weird behavior, namely
            // the wrong item being returned for the wrong index.
            lp.assert(self._cursor == null, "NodeLives.length", .{ .index = if (self._cursor) |c| c.index else 0 });

            var tw = &self._tw;
            defer tw.reset();

            var l: u32 = 0;
            while (self.nextTw(tw)) |_| {
                l += 1;
            }

            self._last_length = l;
            return l;
        }

        // This API supports indexing by both numeric index and id/name
        // i.e. a combination of getAtIndex and getByName
        pub fn getIndexed(self: *Self, value: js.Atom, frame: *Frame) !?*Element {
            if (value.isUint()) |n| {
                return self.getAtIndex(n, frame);
            }

            const name = value.toString();
            defer value.freeString(name);

            return self.getByName(name, frame) orelse return error.NotHandled;
        }

        pub fn getAtIndex(self: *Self, index: usize, frame: *const Frame) ?*Element {
            _ = self.versionCheck(frame);

            var current: usize = 0;
            if (self._cursor) |cursor| {
                if (index == cursor.index) {
                    // asking for the element we just handed out
                    return cursor.element;
                }
                if (index > cursor.index) {
                    // the walker is parked after cursor.element
                    current = cursor.index + 1;
                } else {
                    self._tw.reset();
                    self._cursor = null;
                }
            }

            const tw = &self._tw;
            while (self.nextTw(tw)) |el| {
                if (index == current) {
                    self._cursor = .{ .index = current, .element = el };
                    return el;
                }
                current += 1;
            }

            // Out of range, and the walker is now spent. Rewind, so that a
            // null cursor keeps meaning "the walker is at its start".
            tw.reset();
            self._cursor = null;
            return null;
        }

        pub fn getByName(self: *Self, name: []const u8, frame: *Frame) ?*Element {
            if (frame.getElementByIdFromNode(self._tw._root, name)) |element| {
                const node = element.asNode();
                if (self._tw.contains(node) and self.matches(node)) {
                    return element;
                }
            }

            // Element not found by id, fallback to search by name. This isn't
            // efficient!

            // Gives us a TreeWalker based on the original, but reset to the
            // root. Doing this preserves any cache data we have for other calls
            // (like length or getAtIndex)
            var tw = self._tw.clone();
            while (self.nextTw(&tw)) |element| {
                // Per spec, only HTML-namespace elements are exposed via
                // their name attribute (ids expose any element).
                if (element._namespace != .html) {
                    continue;
                }
                const element_name = element.getAttributeSafe(comptime .wrap("name")) orelse continue;
                if (std.mem.eql(u8, element_name, name)) {
                    return element;
                }
            }
            return null;
        }

        // Advances the shared TreeWalker, keeping the cursor in step with it so
        // that this can be mixed with getAtIndex.
        pub fn next(self: *Self) ?*Element {
            const el = self.nextTw(&self._tw) orelse return null;
            const index = if (self._cursor) |cursor| cursor.index + 1 else 0;
            self._cursor = .{ .index = index, .element = el };
            return el;
        }

        pub fn nextTw(self: *Self, tw: *TW) ?*Element {
            while (tw.next()) |node| {
                if (self.matches(node)) {
                    return node.as(Element);
                }
            }
            return null;
        }

        fn matches(self: *const Self, node: *Node) bool {
            switch (mode) {
                .tag => {
                    const el = node.is(Element) orelse return false;
                    // For HTML namespace elements, we can use the optimized tag comparison.
                    // For other namespaces (XML, SVG custom elements, etc.), fall back to string comparison.
                    if (el._namespace == .html) {
                        return el.getTag() == self._filter;
                    }
                    // For non-HTML elements, compare by tag name string
                    const element_tag = el.getTagNameLower();
                    return std.mem.eql(u8, element_tag, @tagName(self._filter));
                },
                .tag_name => {
                    // If we're in `tag_name` mode, then the tag_name isn't
                    // a known tag. It could be a custom element, heading, or
                    // any generic element. Compare against the element's tag name.
                    // Per spec, getElementsByTagName is case-insensitive for HTML
                    // namespace elements, case-sensitive for others.
                    const el = node.is(Element) orelse return false;
                    const element_tag = el.getTagNameLower();
                    if (el._namespace == .html) {
                        return std.ascii.eqlIgnoreCase(element_tag, self._filter.str());
                    }
                    return std.mem.eql(u8, element_tag, self._filter.str());
                },
                .tag_name_ns => {
                    const el = node.is(Element) orelse return false;
                    if (self._filter.namespace) |ns| {
                        if (el._namespace != ns) return false;
                    }
                    // ok, namespace matches, check local name
                    if (self._filter.local_name.eql(comptime .wrap("*"))) {
                        // wildcard, match-all
                        return true;
                    }
                    return self._filter.local_name.eqlSlice(el.getLocalName());
                },
                .class_name => {
                    if (self._filter.names.len == 0) {
                        return false;
                    }

                    const el = node.is(Element) orelse return false;
                    const class_attr = el.getAttributeSafe(comptime .wrap("class")) orelse return false;
                    for (self._filter.names) |class_name| {
                        if (!Selector.classAttributeContainsCase(class_attr, class_name, self._filter.case_insensitive)) {
                            return false;
                        }
                    }
                    return true;
                },
                .name => {
                    const el = node.is(Element) orelse return false;
                    // getElementsByName only considers HTML elements.
                    if (el._namespace != .html) return false;
                    const name_attr = el.getAttributeSafe(comptime .wrap("name")) orelse return false;
                    return std.mem.eql(u8, name_attr, self._filter);
                },
                .all_elements => return node._type == .element,
                .child_elements => return node._type == .element,
                .child_tag => {
                    const el = node.is(Element) orelse return false;
                    return el.getTag() == self._filter;
                },
                .cells => {
                    // HTMLTableRowElement.cells: td and th children.
                    const el = node.is(Element) orelse return false;
                    return el.is(Element.Html.TableCell) != null;
                },
                .select_options, .selected_options => {
                    const opt = node.is(Element.Html.Option) orelse return false;

                    // we have an option, but it's only a match IF
                    // 1 - this is a direct child of the root (i.e. the <select>)
                    // OR
                    // 2 - this is a direct child of an <optgroup> which, itself
                    //     is a direct child of the root (i.e. the <select>)

                    const parent = node.parentNode() orelse return false;
                    if (parent == self._tw._root) {
                        // case 1: it _is_ a direct child of the root
                    } else {
                        if (parent.is(Element.Html.OptGroup) == null or parent.parentNode() != self._tw._root) {
                            return false;
                        }
                        // the parent is an optgroup and its parent is the root
                    }

                    return if (comptime mode == .selected_options) opt.getSelected() else true;
                },
                .links => {
                    // Links are <a> elements with href attribute (TODO: also <area> when implemented)
                    const el = node.is(Element) orelse return false;
                    const Anchor = Element.Html.Anchor;
                    if (el.is(Anchor) == null) return false;
                    return el.hasAttributeSafe(comptime .wrap("href"));
                },
                .anchors => {
                    // Anchors are <a> elements with name attribute
                    const el = node.is(Element) orelse return false;
                    const Anchor = Element.Html.Anchor;
                    if (el.is(Anchor) == null) return false;
                    return el.hasAttributeSafe(comptime .wrap("name"));
                },
                .form => {
                    const el = node.is(Element) orelse return false;
                    if (!isFormControl(el)) {
                        return false;
                    }

                    if (self._filter.form_id) |form_id| {
                        if (el.getAttributeSafe(comptime .wrap("form"))) |element_form_attr| {
                            return std.mem.eql(u8, element_form_attr, form_id);
                        }
                    } else if (el.hasAttributeSafe(comptime .wrap("form"))) {
                        // Form has no id, element explicitly references another form
                        return false;
                    }

                    // No form attribute - match if descendant of our form
                    // This does an O(depth) ancestor walk for each control in the form.
                    //
                    // TODO: If profiling shows this is a bottleneck:
                    // When we first encounter the form element during tree walk, we could
                    // do a one-time reverse walk to find the LAST control that belongs to
                    // this form (checking both form controls and their form= attributes).
                    // Store that element in a new FormState. Then as we traverse
                    // forward:
                    //   - Set is_within_form = true when we enter the form element
                    //   - Return true immediately for any control while is_within_form
                    //   - Set is_within_form = false when we reach that last element
                    // This trades one O(form_size) reverse walk for N O(depth) ancestor
                    // checks, where N = number of controls. For forms with many nested
                    // controls, this could be significantly faster.
                    return self._filter.form.asNode().contains(node);
                },
            }
        }

        fn isFormControl(el: *Element) bool {
            if (el._type != .html) return false;
            const html = el.subtype(Element.Html);
            return switch (html._type) {
                .input, .button, .select, .textarea => true,
                else => false,
            };
        }

        fn versionCheck(self: *Self, frame: *const Frame) bool {
            const current = frame._page.dom_version;
            if (current == self._cached_version) {
                return true;
            }

            self._tw.reset();
            self._cursor = null;
            self._last_length = null;
            self._cached_version = current;
            return false;
        }

        const HTMLCollection = @import("HTMLCollection.zig");
        const NodeList = @import("NodeList.zig");

        pub fn runtimeGenericWrap(self: Self, frame: *Frame) !if (mode == .name) *NodeList else *HTMLCollection {
            if (comptime mode == .name) {
                return frame._factory.create(NodeList{ ._data = .{ .name = self } });
            }
            return frame._factory.create(self.htmlCollectionValue());
        }

        pub fn htmlCollectionValue(self: Self) HTMLCollection {
            return switch (mode) {
                .name => @compileError("name mode wraps as a NodeList"),
                .tag => .{ ._data = .{ .tag = self } },
                .tag_name => .{ ._data = .{ .tag_name = self } },
                .tag_name_ns => .{ ._data = .{ .tag_name_ns = self } },
                .class_name => .{ ._data = .{ .class_name = self } },
                .all_elements => .{ ._data = .{ .all_elements = self } },
                .child_elements => .{ ._data = .{ .child_elements = self } },
                .child_tag => .{ ._data = .{ .child_tag = self } },
                .cells => .{ ._data = .{ .cells = self } },
                .select_options => .{ ._data = .{ .select_options = self } },
                .selected_options => .{ ._data = .{ .selected_options = self } },
                .links => .{ ._data = .{ .links = self } },
                .anchors => .{ ._data = .{ .anchors = self } },
                .form => .{ ._data = .{ .form = self } },
            };
        }
    };
}

const testing = @import("../../../testing.zig");
test "WebApi: NodeLive" {
    try testing.htmlRunner("collections/live_collections.html", .{});
}

// Indexed access is linear when the cursor works and quadratic when it doesn't,
// which no assertion on the returned elements can tell apart. So scan two
// collections a factor of TIMES apart and compare: linear work grows by TIMES,
// quadratic by TIMES squared. Comparing two back-to-back measurements on the
// same machine keeps this out of reach of how fast that machine is.
test "NodeLive: indexed reads stay linear" {
    const frame = try testing.createFrame();
    defer testing.test_session.closeAllPages();

    const SMALL = 2000;
    const TIMES = 10;
    // well above TIMES, well below TIMES squared
    const LIMIT = TIMES * 3;

    const small = try buildSpans(frame, SMALL);
    const large = try buildSpans(frame, SMALL * TIMES);

    {
        const ratio = growth(frame, small, SMALL, large, SMALL * TIMES, ascendingScan);
        try testing.expect(ratio < LIMIT);
    }

    {
        const ratio = growth(frame, small, SMALL, large, SMALL * TIMES, repeatedScan);
        try testing.expect(ratio < LIMIT);
    }
}

fn buildSpans(frame: *Frame, count: usize) !*Node {
    const div = try frame.window._document.createElement("div", null, frame);
    const html = try frame.arena.alloc(u8, count * "<span></span>".len);
    var i: usize = 0;
    while (i < html.len) : (i += "<span></span>".len) {
        @memcpy(html[i..][0.."<span></span>".len], "<span></span>");
    }
    try Frame.parse.htmlAsChildren(frame, div.asNode(), html);
    return div.asNode();
}

fn ascendingScan(root: *Node, count: usize, frame: *Frame) void {
    var nodes = NodeLive(.tag).init(root, .span, frame);
    for (0..count) |i| {
        std.debug.assert(nodes.getAtIndex(i, frame) != null);
    }
}

fn repeatedScan(root: *Node, count: usize, frame: *Frame) void {
    // the shape of `list[i].foo; list[i].bar`
    var nodes = NodeLive(.tag).init(root, .span, frame);
    for (0..count) |i| {
        std.debug.assert(nodes.getAtIndex(i, frame) != null);
        std.debug.assert(nodes.getAtIndex(i, frame) != null);
    }
}

fn growth(
    frame: *Frame,
    small: *Node,
    small_count: usize,
    large: *Node,
    large_count: usize,
    scan: fn (*Node, usize, *Frame) void,
) f64 {
    const start_small = lp.datetime.microTimestamp(.awake);
    scan(small, small_count, frame);
    const small_us = lp.datetime.microTimestamp(.awake) - start_small;

    const start_large = lp.datetime.microTimestamp(.awake);
    scan(large, large_count, frame);
    const large_us = lp.datetime.microTimestamp(.awake) - start_large;

    return @as(f64, @floatFromInt(large_us)) / @as(f64, @floatFromInt(@max(small_us, 1)));
}
